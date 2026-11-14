# shellcheck shell=bash
# 外部への通知(notify / pr-watch)。bin/tb から source される。単体では実行しない。
#
# - 何を・いつ・どの形で外へ出すかは tb(決定的なコード)が決める。LLM は本文を作らない。agent は tb comment などで内部に書くだけ
# - 流れ: イベント(hook / pr-watch / 定期)→ notify_events に積む → 整形・秘匿フィルタ・伏せ字 → sink(file / stdout / slack)
# - 秘密らしい値を含むイベントは、外の sink(slack・webhook)に出さない。伏せた形を file にだけ残す(設定では変えられない)
# - 設定の優先: 環境変数 TB_NOTIFY_<キー大文字> > config/notify.conf(人だけが編集。無ければ既定。.example は読まない) > 既定
# - 既定は off(enabled)。off のあいだは何も積まず、何も出さない。hook の失敗は元のコマンドの結果に影響しない(notify_emit)
# - slack の経路: slack_via=agent(既定)は notifier agent に整形済みの本文を渡して投稿させ、tb notify ack で結果を受ける。
#   slack_via=webhook は、0600 のファイルに書いた URL へ curl で POST する(URL は設定にも記録にも書かない)

NOTIFY_CONF=${TB_NOTIFY_CONF:-$TB_ROOT/config/notify.conf}
NOTIFY_DIR=${TB_NOTIFY_DIR:-$TB_ROOT/data/notify}
NOTIFY_TYPES="alert_raised alert_result pr_opened pr_approved pr_changes pr_merged question blocked done incident_opened incident_closed approvals_pending summary test warning digest"
NOTIFY_BOOL_KEYS="enabled hash_check mask_ip mask_repo mask_account mask_host mask_email strip_raw_logs"
NOTIFY_INT_KEYS="rate_per_min rate_per_hour max_len dedupe_sec ack_timeout_min ack_retries summary_interval_min"
NOTIFY_STR_KEYS="slack_via slack_target notifier_agent webhook_file"
NOTIFY_KEYS="$NOTIFY_BOOL_KEYS $NOTIFY_INT_KEYS $NOTIFY_STR_KEYS sinks_default"
NOTIFY_ERR=""; NOTIFY_NORM=""; NOTIFY_LOADED=0

notify_default() {  # $1=キー
  case $1 in
    enabled) echo off;;
    hash_check|mask_email|strip_raw_logs) echo on;;
    mask_ip|mask_repo|mask_account|mask_host) echo off;;   # 人の決定: リポジトリ名・IP・アカウント ID・ホスト名は伏せない
    rate_per_min) echo 6;;
    rate_per_hour) echo 60;;
    max_len) echo 600;;
    dedupe_sec) echo 600;;
    ack_timeout_min) echo 5;;
    ack_retries) echo 3;;
    summary_interval_min) echo 30;;
    slack_via) echo agent;;
    slack_target|webhook_file) echo "";;
    notifier_agent) echo notifier;;
    sinks_default) echo "file stdout slack";;
    sinks_warning) echo "file stdout";;
    sinks_*) echo "";;   # 種別ごとの指定が無ければ sinks_default
  esac
}

notify_key_ok() {  # sinks_<種別> も許す
  [[ " $NOTIFY_KEYS " == *" $1 "* ]] && return 0
  [[ $1 == sinks_* && " $NOTIFY_TYPES " == *" ${1#sinks_} "* ]]
}

# 値の検査と正規化。通れば NOTIFY_NORM に入れて 0
notify_norm() {  # $1=キー $2=値
  local k=$1 v=$2 t out=""
  NOTIFY_ERR=""; NOTIFY_NORM=""
  if [[ " $NOTIFY_BOOL_KEYS " == *" $k "* ]]; then
    case $v in on|true|yes|1) NOTIFY_NORM=on;; off|false|no|0) NOTIFY_NORM=off;; *) NOTIFY_ERR="$k は on|off: $v"; return 1;; esac
  elif [[ " $NOTIFY_INT_KEYS " == *" $k "* ]]; then
    [[ $v =~ ^[0-9]{1,6}$ ]] || { NOTIFY_ERR="$k は 0 以上の整数: $v"; return 1; }
    NOTIFY_NORM=$((10#$v))
    if [[ $k == max_len ]]; then ((NOTIFY_NORM >= 40)) || { NOTIFY_ERR="max_len は 40 以上"; return 1; }; fi
  elif [[ $k == slack_via ]]; then
    [[ $v == agent || $v == webhook ]] || { NOTIFY_ERR="slack_via は agent|webhook: $v"; return 1; }
    NOTIFY_NORM=$v
  elif [[ $k == sinks_* ]]; then
    v=${v//,/ }
    for t in $v; do
      [[ $t == file || $t == stdout || $t == slack ]] || { NOTIFY_ERR="$k に使えない sink: $t(file stdout slack)"; return 1; }
      [[ " $out " == *" $t "* ]] || out+="${out:+ }$t"
    done
    NOTIFY_NORM=$out
  elif [[ $k == slack_target ]]; then
    [[ -z $v || $v =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || { NOTIFY_ERR="slack_target は英数字と _ . - の 64 字まで"; return 1; }
    NOTIFY_NORM=$v
  elif [[ $k == notifier_agent ]]; then
    [[ $v =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { NOTIFY_ERR="notifier_agent は agent 名"; return 1; }
    NOTIFY_NORM=$v
  elif [[ $k == webhook_file ]]; then
    [[ $v != *$'\n'* && ${#v} -le 512 ]] || { NOTIFY_ERR="webhook_file が不正"; return 1; }
    NOTIFY_NORM=$v
  else NOTIFY_ERR="不明なキー: $k"; return 1; fi
}

notify_load() {
  ((NOTIFY_LOADED)) && return 0
  local line k v
  if [[ -f $NOTIFY_CONF ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=$(trim "${line%%#*}"); [[ $line == *=* ]] || continue
      k=$(trim "${line%%=*}"); v=$(trim "${line#*=}")
      notify_key_ok "$k" || continue
      notify_norm "$k" "$v" || continue
      printf -v "NC_$k" '%s' "$NOTIFY_NORM"; printf -v "NC_SET_$k" '%s' 1
    done <"$NOTIFY_CONF"
  fi
  NOTIFY_LOADED=1
}

# 設定値(env > notify.conf > 既定)。出どころは notify_source
ncfg() {  # $1=キー
  notify_load
  local ev sv="NC_SET_$1" cv="NC_$1"
  ev="TB_NOTIFY_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if [[ -n ${!ev+x} ]] && notify_norm "$1" "${!ev}"; then printf '%s' "$NOTIFY_NORM"; return 0; fi
  if [[ -n ${!sv:-} ]]; then printf '%s' "${!cv}"; return 0; fi
  notify_default "$1"
}
notify_source() {
  notify_load
  local ev sv="NC_SET_$1"
  ev="TB_NOTIFY_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
  if [[ -n ${!ev+x} ]] && notify_norm "$1" "${!ev}"; then echo env; elif [[ -n ${!sv:-} ]]; then echo conf; else echo default; fi
}
notify_on() { [[ $(ncfg enabled) == on ]]; }
nflag() { [[ $(ncfg "$1") == on ]]; }

notify_sinks_of() {  # $1=種別 → 空白区切り
  local s; s=$(ncfg "sinks_$1")
  [[ -n $s ]] || s=$(ncfg sinks_default)
  if [[ $1 == warning && -z $(ncfg sinks_warning) ]]; then s="file stdout"; fi
  printf '%s' "$s"
}

# ---------- 秘匿フィルタ(設定では変えられない) ----------
# <名前>|<ERE>(ERE の中の | は選択)。grep -oEi で見つかった文字列が「秘密らしい値」
NOTIFY_SECRET_PATTERNS=$(cat <<'P'
AWS アクセスキー ID|(AKIA|ASIA)[0-9A-Z]{16}
秘密鍵のヘッダ|-----BEGIN [A-Z ]*PRIVATE KEY-----
トークン(API キーなどの形式)|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}|hooks\.slack\.com/services/[A-Za-z0-9/]{8,}
Bearer トークン|bearer +[A-Za-z0-9._~+/=-]{16,}
キー=値の形の秘密|(token|secret|passw(or)?d|api[_-]?key|access[_-]?key|private[_-]?key|credential)[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*[A-Za-z0-9_+/=.@:!#$%^&*-]{6,}
P
)

# 長い base64 / 16 進の連なり。パスや識別子を誤検出しにくいよう、大文字・小文字・数字の混在(16 進は 32 字以上)を条件にする
notify_long_runs() {  # $1=本文 → 見つけた文字列を 1 行ずつ
  local c
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    if [[ $c =~ ^[0-9a-fA-F]{32,}$ ]]; then printf '%s\n' "$c"; continue; fi
    if [[ $c =~ [0-9] && $c =~ [a-z] && $c =~ [A-Z] ]]; then printf '%s\n' "$c"; fi
  done < <(printf '%s' "$1" | grep -oE '[A-Za-z0-9+=]{32,}|[A-Za-z0-9_-]{40,}' 2>/dev/null || true)
}

NOTIFY_HITS=""        # 見つけた文字列(改行区切り)
NOTIFY_HIT_KINDS=""   # 見つけた種類の名前
notify_secret_scan() {  # $1=本文。見つかれば 0
  local name pat h kinds="" hits=""
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    name=${line%%|*}; pat=${line#*|}
    h=$(printf '%s' "$1" | grep -oEi -- "$pat" 2>/dev/null || true)
    if [[ -n $h ]]; then kinds+="${kinds:+, }$name"; hits+="$h"$'\n'; fi
  done <<<"$NOTIFY_SECRET_PATTERNS"
  h=$(notify_long_runs "$1")
  if [[ -n $h ]]; then kinds+="${kinds:+, }長い英数字の連なり"; hits+="$h"$'\n'; fi
  NOTIFY_HITS=$hits; NOTIFY_HIT_KINDS=$kinds
  [[ -n $kinds ]]
}

notify_redact() {  # $1=本文(notify_secret_scan の直後に呼ぶ)→ 伏せた本文
  local t=$1 h
  while IFS= read -r h; do
    [[ -n $h ]] || continue
    t=${t//"$h"/[伏せた秘密]}
  done < <(printf '%s' "$NOTIFY_HITS" | awk 'NF {print length($0) "\t" $0}' | sort -rn | cut -f2-)
  printf '%s' "$t"
}

# ---------- 整形 ----------
# 生ログ・コードを落とす(strip_raw_logs)。複数行の本文を、先頭の 2 行(空行を除く)にする
notify_lines() {  # $1=本文
  local t=$1
  if nflag strip_raw_logs; then
    t=$(printf '%s\n' "$t" | awk '
      /^[[:space:]]*```/ { if (!f) print "(コードは省略)"; f = !f; next }
      f { next }
      /^[[:space:]]*\[?[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]/ { next }
      /^[[:space:]]*\[?[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ { next }
      { print }')
  fi
  printf '%s\n' "$t" | tr -d '\000-\010\013\014\016-\037\177' | tr '\r\t' '  ' \
    | awk 'NF { gsub(/^ +| +$/, ""); if (n++) printf " / "; printf "%s", $0; if (n >= 2) exit }'
}
nclip() {  # $1=本文 $2=最大字数
  printf '%s' "$1" | jq -Rrs --argjson n "$2" '.[0:$n]'
}
# 1 項目: 行の整理 → 先頭 N 字(Slack の @ や < は notify_finish で一括して無効化する)
nfield() { nclip "$(notify_lines "$1")" "$2"; }

# 外へ出る形にする: 制御文字の除去 → 伏せ字 → メンションと <...> の無効化 → 長さの上限
notify_finish() {  # $1=本文
  local t=$1 r
  t=$(printf '%s' "$t" | tr -d '\000-\010\013\014\016-\037\177' | tr '\r\n\t' '   ' | tr -s ' ')
  if nflag mask_email; then t=$(printf '%s' "$t" | sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/a***@***/g'); fi
  if nflag mask_ip; then t=$(printf '%s' "$t" | sed -E 's/([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/\1.*.*.*/g'); fi
  if nflag mask_account; then t=$(printf '%s' "$t" | sed -E 's/(^|[^0-9])[0-9]{8}([0-9]{4})($|[^0-9])/\1********\2\3/g'); fi
  if nflag mask_host; then t=$(printf '%s' "$t" | sed -E 's/[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.(internal|local|lan|corp|amazonaws\.com)/[host]/g'); fi
  if nflag mask_repo; then
    while IFS= read -r r; do [[ -n $r ]] && t=${t//"$r"/[repo]}; done < <(notify_repos)
  fi
  # Slack のメンション(@here / @channel / @everyone)と <@U..> <!..> <url|text> を無効化。リンクはただの文字列として残す
  t=$(printf '%s' "$t" | sed -E 's/@(here|channel|everyone)/＠\1/g; s/</‹/g; s/>/›/g')
  nclip "$(trim "$t")" "$(ncfg max_len)"
}

NOTIFY_REPOS_FILE=${TB_REPOS_FILE:-$TB_ROOT/config/repos.md}   # 許可リスト。人が書く。git 管理外
notify_repos() {  # 許可リストの <org>/<repo> を 1 行ずつ
  local line
  [[ -f $NOTIFY_REPOS_FILE ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=$(trim "$line")
    [[ $line == -* ]] || continue
    line=$(trim "${line#-}")
    if [[ $line =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then printf '%s\n' "$line"; fi
  done <"$NOTIFY_REPOS_FILE"
  return 0
}

notify_hash() { printf '%s' "$1" | sha256 | cut -c1-12; }

# 種別ごとの本文。引数は整形済みの項目。メンション等の無効化は notify_finish
notify_compose() {  # $1=種別 $2=ref $3=重大度 $4.. 項目
  local type=$1 ref=$2 sev=$3 a=${4:-} b=${5:-} c=${6:-} d=${7:-}
  case $type in
    alert_raised)  echo "[アラート] ${ref} 検出(緊急度は調査中) / 検出元: ${b:--} / ${a}${c:+ — ${c}}";;
    alert_result)  echo "[調査結果] ${ref} ${sev:-?}: ${a} — ${b}${c:+ (報告: ${c})}";;
    pr_opened)     echo "[PR] ${ref} を出した${b:+(${b})}: ${a}${c:+ / 作成: ${c}}${d:+ / ${d}}";;
    pr_approved)   echo "[PR] ${ref} approve${c:+(レビュー: ${c})}: ${a} / マージは人";;
    pr_changes)    echo "[PR] ${ref} 変更依頼${c:+(レビュー: ${c})}: ${a}";;
    pr_merged)     echo "[PR] ${ref} マージ済み${c:+(${c})}: ${a}";;
    question)      echo "[質問] ${a}${sev:+ ${sev}} / ${b}: ${c}";;
    blocked)       echo "[詰まり] ${a}${sev:+ ${sev}} / ${b}: ${c}";;
    done)          echo "[完了] ${a}${sev:+ ${sev}}: ${b}${c:+ / 成果物: ${c}}";;
    incident_opened) echo "[障害] ${ref} 開始${sev:+ ${sev}}: ${a}";;
    incident_closed) echo "[障害] ${ref} 終了${sev:+ ${sev}}: ${a}";;
    approvals_pending) echo "[承認待ち] ${a}(承認は人の端末)";;
    summary)       echo "[まとめ] ${a}";;
    test)          echo "[テスト] tb notify test: 疎通確認の固定文です。返信や操作は要りません";;
    warning)       echo "[通知の警告] ${a}";;
    digest)        echo "[まとめ] ${a}";;
  esac
}

# ---------- キュー ----------
NOTIFY_LAST_ID=""
# notify_enqueue <種別> <ref> <重大度> <項目a> [b c d]  → NOTIFY_LAST_ID。off・重複のときは何もせず 0
# NOTIFY_FORCE=1 のときは off でも積む(tb notify test / まとめ用)
notify_enqueue() {
  local type=$1 ref=$2 sev=$3 ra=${4:-} rb=${5:-} rc=${6:-} rd=${7:-}
  NOTIFY_LAST_ID=""
  [[ " $NOTIFY_TYPES " == *" $type "* ]] || return 1
  [[ ${NOTIFY_FORCE:-0} == 1 ]] || notify_on || return 0
  local key="$type:$ref" win dup
  win=$(ncfg dedupe_sec)
  if [[ -n $ref ]] && ((win > 0)); then
    dup=$(sql "SELECT 1 FROM notify_events WHERE dedupe_key=$(q "$key") AND (julianday('now') - julianday(created_at)) * 86400 < $win LIMIT 1;")
    [[ -z $dup ]] || return 0
  fi
  local all blocked=0 reason="" a b c d text hash sinks slack=none
  all="$ref"$'\n'"$sev"$'\n'"$ra"$'\n'"$rb"$'\n'"$rc"$'\n'"$rd"
  if [[ $type != test ]] && notify_secret_scan "$all"; then
    blocked=1; reason=$NOTIFY_HIT_KINDS
    ra=$(notify_redact "$ra"); rb=$(notify_redact "$rb"); rc=$(notify_redact "$rc"); rd=$(notify_redact "$rd")
    ref=$(notify_redact "$ref")
  fi
  a=$(nfield "$ra" 120); b=$(nfield "$rb" 200); c=$(nfield "$rc" 200); d=$(nfield "$rd" 120)
  text=$(notify_finish "$(notify_compose "$type" "$ref" "$sev" "$a" "$b" "$c" "$d")")
  # 整形後にも念のためもう一度確かめる
  if ((! blocked)) && [[ $type != test ]] && notify_secret_scan "$text"; then
    blocked=1; reason=$NOTIFY_HIT_KINDS; text=$(notify_redact "$text")
  fi
  hash=$(notify_hash "$text")
  sinks=$(notify_sinks_of "$type")
  if ((blocked)); then
    sinks=$(printf '%s' "$sinks" | tr ' ' '\n' | grep -vx slack | paste -sd' ' - || true)
    [[ -n $sinks ]] || sinks=file
  fi
  if [[ " $sinks " == *" slack "* ]]; then slack=pending; fi
  NOTIFY_LAST_ID=$(sql "INSERT INTO notify_events (type, ref, severity, text, hash, blocked, blocked_reason, sinks, dedupe_key, slack_status, created_at)
    VALUES ($(q "$type"), NULLIF($(q "$ref"),''), NULLIF($(q "$sev"),''), $(q "$text"), $(q "$hash"), $blocked, NULLIF($(q "$reason"),''),
            $(q "$sinks"), $(q "$key"), $(q "$slack"), $(q "$(now)"));
    SELECT last_insert_rowid();")
  notify_local_sinks "$NOTIFY_LAST_ID"
  if ((blocked)) && [[ $type != warning ]]; then
    local bid=$NOTIFY_LAST_ID
    notify_enqueue warning "N-$bid" "" \
      "N-${bid}(${type})は秘密らしい値(${reason})を含むため、外へ出していません。file には伏せて残しました" >/dev/null || true
    NOTIFY_LAST_ID=$bid
  fi
  return 0
}

# hook 用の入口。どんな失敗でも、呼んだ元のコマンドを止めず、出力も出さない(set -e の中でも安全)
notify_emit() { ( notify_enqueue "$@" ) >/dev/null 2>&1 || true; return 0; }

notify_day() { date +%F; }
notify_ensure_dir() { mkdir -p "$NOTIFY_DIR" && chmod 700 "$NOTIFY_DIR" 2>/dev/null || true; }

notify_local_sinks() {  # $1=event id。file と stdout だけ(外には出ない)
  local id=$1 row sinks text ts type blocked mark=""
  row=$(sql -json "SELECT * FROM notify_events WHERE id=$id;" | jq -c '.[0] // empty'); [[ -n $row ]] || return 0
  sinks=$(jq -r .sinks <<<"$row"); text=$(jq -r .text <<<"$row"); type=$(jq -r .type <<<"$row"); blocked=$(jq -r .blocked <<<"$row")
  [[ $blocked == 1 ]] && mark=" [外へは出していない: 秘密を検出]"
  ts=$(now); notify_ensure_dir
  if [[ " $sinks " == *" file "* ]]; then
    printf -- '- %s N-%s [%s]%s %s\n' "$ts" "$id" "$type" "$mark" "$text" >>"$NOTIFY_DIR/$(notify_day).md"
    sql "UPDATE notify_events SET file_at=$(q "$ts") WHERE id=$id;"
  fi
  if [[ " $sinks " == *" stdout "* ]]; then
    printf '%s N-%s %s%s\n' "$ts" "$id" "$text" "$mark" >>"$NOTIFY_DIR/stdout.log"
  fi
}

# ---------- slack への送り出し ----------
notify_sent_log() {  # $1=id $2=経路 $3=hash $4=本文
  notify_ensure_dir
  printf '%s\tN-%s\t%s\t%s\t%s\n' "$(now)" "$1" "$2" "$3" "$4" >>"$NOTIFY_DIR/sent.log"
}
notify_record_send() { sql "INSERT INTO notify_sends (event_id, via, at) VALUES ($1, $(q "$2"), $(q "$(now)"));"; }

# 1 分・1 時間の残りの枠(小さいほう)
notify_budget() {
  local pm ph um uh b1 b2
  pm=$(ncfg rate_per_min); ph=$(ncfg rate_per_hour)
  um=$(sql "SELECT COUNT(*) FROM notify_sends WHERE (julianday('now') - julianday(at)) * 86400 < 60;")
  uh=$(sql "SELECT COUNT(*) FROM notify_sends WHERE (julianday('now') - julianday(at)) * 86400 < 3600;")
  b1=$((pm - um)); b2=$((ph - uh))
  if ((b1 < b2)); then echo "$b1"; else echo "$b2"; fi
}

notify_fail() {  # $1=id $2=理由
  sql "UPDATE notify_events SET slack_status='failed', note=$(q "$2") WHERE id=$1;"
  notify_enqueue warning "N-$1-failed" "" "N-$1 を slack へ送れませんでした(${2})。情報は file と webapp に残っています" >/dev/null 2>&1 || true
}

# webhook: URL は 0600 のファイルから読み、引数・ログ・記録には出さない
notify_webhook_post() {  # $1=本文 → 0 成功 / 1 失敗(NOTIFY_ERR に理由。URL は含めない)
  local f url body cfg code rc=0 curl_bin=${TB_CURL:-curl} mode
  f=$(ncfg webhook_file)
  [[ -n $f && -f $f && ! -L $f ]] || { NOTIFY_ERR="webhook_file が無い(通常ファイルのみ)"; return 1; }
  mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || true)   # GNU を先に(GNU の stat -f は別の意味で、失敗しても何か出力する)
  [[ $mode == 600 ]] || { NOTIFY_ERR="webhook_file の権限が 0600 ではない"; return 1; }
  url=$(head -n 1 "$f" | tr -d '\r\n ')
  if [[ $url != https://* && ! ( -n ${TB_NOTIFY_ALLOW_HTTP:-} && $url == http://127.0.0.1* ) ]]; then NOTIFY_ERR="webhook の URL が https ではない"; return 1; fi
  body=$(mktemp "${TMPDIR:-/tmp}/tb-notify.XXXXXX"); cfg=$(mktemp "${TMPDIR:-/tmp}/tb-notify.XXXXXX")
  chmod 600 "$body" "$cfg"
  jq -nc --arg t "$1" '{text:$t}' >"$body"
  printf 'url = "%s"\n' "$url" >"$cfg"
  code=$("$curl_bin" -sS --max-time 10 -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary "@$body" -K "$cfg" 2>/dev/null) || rc=$?
  rm -f "$body" "$cfg"
  if ((rc != 0)) || [[ ! $code =~ ^2[0-9][0-9]$ ]]; then NOTIFY_ERR="webhook の POST に失敗(curl=${rc}, http=${code:-なし})"; return 1; fi
  return 0
}

# 1 件を slack へ出す。0 送った / 10 宛先が使用中(未送信) / 1 失敗(記録済み)
notify_slack_send() {  # $1=event id
  local id=$1 row text hash att via target agent msg rc=0 retries
  row=$(sql -json "SELECT * FROM notify_events WHERE id=$id;" | jq -c '.[0] // empty'); [[ -n $row ]] || return 1
  [[ $(jq -r .blocked <<<"$row") == 0 ]] || return 1   # 防御: blocked は外へ出さない
  text=$(jq -r .text <<<"$row"); hash=$(jq -r .hash <<<"$row"); att=$(jq -r .slack_attempts <<<"$row")
  via=$(ncfg slack_via); retries=$(ncfg ack_retries)
  if [[ $via == webhook ]]; then
    if notify_webhook_post "$text"; then
      sql "UPDATE notify_events SET slack_status='sent', slack_attempts=slack_attempts+1, slack_sent_at=$(q "$(now)"), note=NULL WHERE id=$id;"
      notify_record_send "$id" webhook; notify_sent_log "$id" webhook "$hash" "$text"; return 0
    fi
    sql "UPDATE notify_events SET slack_attempts=slack_attempts+1, note=$(q "$NOTIFY_ERR") WHERE id=$id;"
    if ((att + 1 >= retries)); then notify_fail "$id" "$NOTIFY_ERR"; fi
    return 1
  fi
  target=$(ncfg slack_target); agent=$(ncfg notifier_agent)
  [[ -n $target ]] || { notify_fail "$id" "slack_target が未設定"; return 1; }
  msg="[from: tb / notify / N-${id} / info] POST channel=${target} hash=${hash} text=<<<${text}>>> (本文をそのまま 1 通だけ投稿し、投稿した本文で tb notify hash を出して tb notify ack N-${id} <hash> を実行)"
  herdr_send "$agent" "$msg" "N-$id" notify >/dev/null 2>&1 || rc=$?
  case $rc in
    0) sql "UPDATE notify_events SET slack_status='awaiting-ack', slack_attempts=slack_attempts+1, slack_sent_at=$(q "$(now)"), note=NULL WHERE id=$id;"
       notify_record_send "$id" agent; notify_sent_log "$id" agent "$hash" "$text"; return 0;;
    10) return 10;;
    *) sql "UPDATE notify_events SET slack_attempts=slack_attempts+1, note='notifier に送れない' WHERE id=$id;"
       if ((att + 1 >= retries)); then notify_fail "$id" "notifier に送れない"; fi
       return 1;;
  esac
}

# まとめ 1 通(枠が足りないとき、残りの pending を 1 通にする)。NOTIFY_LAST_ID に digest の event id
notify_make_digest() {  # $@=event id
  local ids=("$@") n=$# line="" t i s did
  for i in "${ids[@]}"; do
    t=$(sql "SELECT text FROM notify_events WHERE id=$i;")
    s="N-$i $(nclip "$t" 50)"
    line+="${line:+ | }$s"
    if ((${#line} > $(ncfg max_len) - 100)); then line+=" ..."; break; fi
  done
  NOTIFY_FORCE=1 notify_enqueue digest "batch-$(date +%s)-$$" "" "頻度の上限のため ${n} 件をまとめました: ${line} (全文: tb notify events)"
  did=$NOTIFY_LAST_ID
  [[ -n $did ]] || return 1
  for i in "${ids[@]}"; do sql "UPDATE notify_events SET slack_status='batched', batch_id=$did WHERE id=$i;"; done
  return 0
}

notify_flush_slack() {
  local budget id rc ids=() n att timeout retries
  budget=$(notify_budget)
  timeout=$(ncfg ack_timeout_min); retries=$(ncfg ack_retries)
  # 1. 返事が無い送信の再送(回数の上限に達したら failed)
  while IFS=$'\t' read -r id att; do
    [[ -n $id ]] || continue
    if ((att >= retries)); then notify_fail "$id" "ack が来ない(${att} 回送った)"; continue; fi
    ((budget > 0)) || continue
    rc=0; notify_slack_send "$id" || rc=$?
    if ((rc == 0)); then budget=$((budget - 1)); fi
  done < <(sql -separator $'\t' "SELECT id, slack_attempts FROM notify_events WHERE slack_status='awaiting-ack' AND blocked=0
           AND (julianday('now') - julianday(slack_sent_at)) * 1440 >= $timeout ORDER BY id;")
  # 2. 新しいもの。枠が足りなければ、残りを 1 通にまとめる
  while IFS= read -r id; do [[ -n $id ]] && ids+=("$id"); done < <(sql "SELECT id FROM notify_events WHERE slack_status='pending' AND blocked=0 ORDER BY id;")
  n=${#ids[@]}
  ((n > 0 && budget > 0)) || return 0
  if ((n <= budget)); then
    for id in "${ids[@]}"; do notify_slack_send "$id" >/dev/null 2>&1 || true; done
  else
    local single=$((budget - 1)) k=0 rest=()
    for id in "${ids[@]}"; do
      if ((k < single)); then notify_slack_send "$id" >/dev/null 2>&1 || true
      else rest+=("$id"); fi
      k=$((k + 1))
    done
    if notify_make_digest "${rest[@]}"; then notify_slack_send "$NOTIFY_LAST_ID" >/dev/null 2>&1 || true; fi
  fi
}

# ---------- 定期のイベント(承認待ち・まとめ) ----------
notify_seen_get() { sql "SELECT value FROM notify_seen WHERE key=$(q "$1");"; }
notify_seen_set() { sql "INSERT INTO notify_seen (key, value, updated_at) VALUES ($(q "$1"), $(q "$2"), $(q "$(now)"))
                         ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at;"; }

notify_periodic() {
  local ids o l cur last n iv age run al hu tk
  # 承認待ち(L-/O- の番号と件数だけ)。L- は現在の herdr セッションの agent 宛て(まだ台帳に無い新規作成を含む)
  o=$(sql "SELECT 'O-'||id FROM outbox WHERE status='pending' ORDER BY id;" | paste -sd' ' -)
  l=$(sql "SELECT 'L-'||id FROM agent_ops WHERE status='pending'
           AND (target NOT IN (SELECT name FROM agents) OR target IN (SELECT name FROM agents WHERE herdr_session=$(q "$HSESS"))) ORDER BY id;" | paste -sd' ' -)
  ids=$(printf '%s %s' "$o" "$l" | tr -s ' ' | sed 's/^ //; s/ $//')
  last=$(notify_seen_get approvals-last)
  if [[ $ids != "$last" ]]; then
    notify_seen_set approvals-last "$ids"
    if [[ -n $ids ]]; then
      n=$(wc -w <<<"$ids" | tr -d ' ')
      notify_enqueue approvals_pending "$(printf '%s' "$ids" | sha256 | cut -c1-8)" "" "承認待ち ${n} 件: ${ids}"
    fi
  fi
  # 定期まとめ: 間隔がたち、かつ件数が前回から変わったときだけ
  iv=$(ncfg summary_interval_min)
  ((iv > 0)) || return 0
  age=$(sql "SELECT CAST((julianday('now') - julianday(updated_at)) * 1440 AS INTEGER) FROM notify_seen WHERE key='summary-at';")
  [[ -z $age || $age -ge $iv ]] || return 0
  run=$(sql "SELECT COUNT(*) FROM agents WHERE state='running' AND herdr_session=$(q "$HSESS");")
  al=$(sql "SELECT COUNT(*) FROM alerts WHERE status NOT IN ('closed');")
  hu=$(sql "SELECT COUNT(*) FROM comments WHERE kind IN ('question','blocked') AND resolved_at IS NULL;")
  tk=$(sql "SELECT COUNT(*) FROM tasks WHERE status IN ('in_progress','review');")
  cur="動作中 agent ${run} / 進行中タスク ${tk} / 未クローズのアラート ${al} / 人の対応待ち ${hu}"
  notify_seen_set summary-at "$(now)"
  if [[ $cur != "$(notify_seen_get summary-last)" ]]; then
    notify_seen_set summary-last "$cur"
    notify_enqueue summary "$(date +%s)" "" "$cur"
  fi
}

# ---------- hook(既存の経路から呼ぶ。失敗しても元のコマンドは変わらない) ----------
notify_hook_comment() {  # $1=comments.id
  local row kind
  row=$(sql -json "SELECT c.* FROM comments c WHERE c.id=$1;" | jq -c '.[0] // empty')
  [[ -n $row ]] || return 0
  kind=$(jq -r .kind <<<"$row")
  case $kind in
    question|blocked) notify_enqueue "$kind" "C-$1" "" "$(jq -r .task_id <<<"$row")" "$(jq -r .from_name <<<"$row")" "$(jq -r .text <<<"$row")";;
    done) notify_enqueue done "$(jq -r .task_id <<<"$row")" "" "$(jq -r .task_id <<<"$row")" "$(jq -r .text <<<"$row")" "$(jq -r '.deliverables | fromjson | join(", ")' <<<"$row")";;
  esac
}
notify_hook_alert_raised() {  # $1=alerts.id
  local row; row=$(sql -json "SELECT * FROM alerts WHERE id=$1;" | jq -c '.[0] // empty'); [[ -n $row ]] || return 0
  notify_enqueue alert_raised "A-$1" "" "$(jq -r .title <<<"$row")" "$(jq -r .source <<<"$row")" "$(jq -r '.body // ""' <<<"$row")"
}
notify_hook_alert_result() {  # $1=alerts.id
  local row; row=$(sql -json "SELECT * FROM alerts WHERE id=$1;" | jq -c '.[0] // empty'); [[ -n $row ]] || return 0
  notify_enqueue alert_result "A-$1" "$(jq -r '.severity // ""' <<<"$row")" "$(jq -r .title <<<"$row")" "$(jq -r '.result_summary // ""' <<<"$row")" "$(jq -r '.result_path // ""' <<<"$row")"
}
notify_hook_task_done() {  # $1=task id
  local row; row=$(task_row "$1"); [[ -n $row ]] || return 0
  notify_enqueue done "$1" "" "$1" "$(jq -r '.summary // ""' <<<"$row")" "$(jq -r '.deliverables | fromjson | join(", ")' <<<"$row")"
}
# 失敗・終了(die を含む)しても呼び出し元を止めない入口
notify_hook() { ( "$@" ) >/dev/null 2>&1 || true; return 0; }

# ---------- tb pr-watch(読み取りだけ。scheduler の COMMAND ジョブから) ----------
# 許可リスト(taskboard/config/repos.md の "- <org>/<repo>"。TB_REPOS_FILE で変更可)のリポジトリの PR を gh で読み、前回との差から作成・approve・変更依頼・マージを積む。
# PR の題・本文・レビューのコメントはデータ: 題(短く)と状態だけを本文に使う。差分は読まない。
# 初めて見るリポジトリは基準線として記録するだけ(既存の PR を全部「新規」にしない)。許可リストが無い・空なら何もせず 0
cmd_pr-watch() {
  [[ $# -eq 0 ]] || usage "pr-watch(引数なし)"
  local repos r gh=${TB_GH_BIN:-gh} out row num title state dec draft author merger seen prev tid pstate pdec
  repos=$(notify_repos); [[ -n $repos ]] || return 0
  notify_on || return 0
  command -v "$gh" >/dev/null 2>&1 || return 0
  while IFS= read -r r; do
    [[ -n $r ]] || continue
    out=$("$gh" pr list --repo "$r" --state all --limit 30 --json number,title,state,isDraft,reviewDecision,author,mergedBy 2>/dev/null) || continue
    jq -e 'type=="array"' <<<"$out" >/dev/null 2>&1 || continue
    seen=$(notify_seen_get "prbase:$r")
    while IFS= read -r row; do
      [[ -n $row ]] || continue
      num=$(jq -r .number <<<"$row"); [[ $num =~ ^[0-9]+$ ]] || continue
      title=$(jq -r '.title // ""' <<<"$row"); state=$(jq -r '.state // ""' <<<"$row")
      dec=$(jq -r '.reviewDecision // ""' <<<"$row"); draft=$(jq -r 'if .isDraft then "draft" else "" end' <<<"$row")
      author=$(jq -r '.author.login // ""' <<<"$row"); merger=$(jq -r '.mergedBy.login // ""' <<<"$row")
      [[ $author =~ ^[A-Za-z0-9._-]{1,64}$ ]] || author=""
      [[ $merger =~ ^[A-Za-z0-9._-]{1,64}$ ]] || merger=""
      prev=$(notify_seen_get "pr:$r#$num")
      tid=$(printf '%s' "$title" | grep -oE 'T-[A-Za-z0-9_]+-[0-9]{3,}' | head -n 1 || true)
      if [[ -n $seen ]]; then
        if [[ -z $prev ]]; then
          if [[ $state == MERGED ]]; then notify_emit pr_merged "$r#$num" "" "$title" "" "$merger"
          elif [[ $state == OPEN ]]; then notify_emit pr_opened "$r#$num" "" "$title" "$draft" "$author" "${tid:+タスク ${tid}}"; fi
        else
          pstate=${prev%%|*}; pdec=${prev#*|}
          if [[ $state == MERGED && $pstate != MERGED ]]; then notify_emit pr_merged "$r#$num" "" "$title" "" "$merger"
          elif [[ $state == OPEN && $dec != "$pdec" ]]; then
            case $dec in
              APPROVED) notify_emit pr_approved "$r#$num" "" "$title" "" "";;
              CHANGES_REQUESTED) notify_emit pr_changes "$r#$num" "" "$title" "" "";;
            esac
          fi
        fi
      fi
      notify_seen_set "pr:$r#$num" "$state|$dec"
    done < <(jq -c '.[]' <<<"$out")
    notify_seen_set "prbase:$r" "$(now)"
  done <<<"$repos"
  return 0
}

# ---------- tb notify ----------
notify_write_conf() {  # $1=キー $2=値(人だけが呼ぶ)
  local k=$1 v=$2 tmp line found=0
  mkdir -p "$(dirname "$NOTIFY_CONF")"; [[ ! -L $NOTIFY_CONF ]] || die "notify.conf がシンボリックリンクです"
  touch "$NOTIFY_CONF"; tmp=$(mktemp "$NOTIFY_CONF.XXXXXX")
  {
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line != \#* && $line == *=* && $(trim "${line%%=*}") == "$k" ]]; then
        if ((! found)); then printf '%s = %s\n' "$k" "$v"; found=1; fi
      else printf '%s\n' "$line"; fi
    done <"$NOTIFY_CONF"
    if ((! found)); then printf '%s = %s\n' "$k" "$v"; fi
  } >"$tmp"
  mv "$tmp" "$NOTIFY_CONF"; NOTIFY_LOADED=0
}

notify_event_ref() {  # "N-12" か "12" → 数字
  local r=${1#N-}; [[ $r =~ ^[0-9]+$ ]] || usage "イベント ID は N-<数字>: $1"; printf '%s' "$r"
}

notify_webhook_state() {
  local f mode; f=$(ncfg webhook_file)
  if [[ -z $f ]]; then echo "未設定"; return 0; fi
  if [[ ! -f $f ]]; then echo "ファイルが無い"; return 0; fi
  mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null || true)   # GNU を先に(GNU の stat -f は別の意味で、失敗しても何か出力する)
  if [[ $mode == 600 ]]; then echo "ok(0600)"; else echo "権限が 0600 ではない"; fi
}

cmd_notify() {
  local sub=${1:-status}; shift || true
  case $sub in
    status) notify_status "$@";;
    on|off)
      [[ $# -eq 0 ]] || usage "notify $sub(引数なし)"
      require_human "tb notify $sub"
      notify_write_conf enabled "$sub"; echo "notify: enabled = $sub"
      if [[ $sub == on ]]; then echo "(外へ出る前に tb notify status と tb notify test で確かめてください)"; fi
      return 0;;
    test)
      [[ $# -eq 0 ]] || usage "notify test(引数なし)"
      require_human "tb notify test"
      NOTIFY_FORCE=1 notify_enqueue test "test-$(date +%s)-$$" "" || true
      local id=$NOTIFY_LAST_ID
      [[ -n $id ]] || die "test: イベントを作れませんでした"
      if [[ $(sql "SELECT slack_status FROM notify_events WHERE id=$id;") == pending ]]; then notify_slack_send "$id" >/dev/null 2>&1 || true; fi
      echo "N-$id $(sql "SELECT slack_status FROM notify_events WHERE id=$id;") $(sql "SELECT text FROM notify_events WHERE id=$id;")"
      return 0;;
    dry-run) notify_dry_run "$@";;
    tail) notify_tail "$@";;
    ack) notify_ack "$@";;
    flush)
      [[ $# -eq 0 ]] || usage "notify flush(引数なし)"
      require_human "tb notify flush"
      notify_on || { echo "notify: off(何もしません)"; return 0; }
      notify_periodic || true
      notify_flush_slack || true
      echo "notify: flushed"; return 0;;
    events) notify_events "$@";;
    hash) [[ $# -eq 1 ]] || usage "notify hash <本文>"; notify_hash "$1"; echo;;
    event) notify_event_cmd "$@";;
    *) usage "notify: 不明なサブコマンド $sub(status|on|off|test|dry-run|tail|ack|flush|events)";;
  esac
}

# 人だけ: 手で通知イベントを積む(障害対応の workspace を開く・閉じるスクリプトから使う)。種別は incident_opened / incident_closed
notify_event_cmd() {
  [[ $# -ge 2 ]] || usage "notify event incident_opened|incident_closed <ID> [--title T] [--severity S]"
  local type=$1 ref=$2 title="" sev=""; shift 2
  [[ $type == incident_opened || $type == incident_closed ]] || usage "notify event: 種別は incident_opened|incident_closed"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --title) need_arg "$@"; title=$2; shift 2;;
      --severity) need_arg "$@"; sev=$2; shift 2;;
      *) usage "notify event: 不明な引数 $1";;
    esac
  done
  require_human "tb notify event"
  notify_emit "$type" "$ref" "$sev" "$title"
  echo "notify: $type $ref"
}

notify_status() {
  local json=0 t sinks counts
  [[ ${1:-} == --json ]] && json=1
  counts=$(sql -separator ' ' "SELECT slack_status, COUNT(*) FROM notify_events GROUP BY slack_status ORDER BY 1;" | paste -sd, -)
  if ((json)); then
    jq -nc --arg en "$(ncfg enabled)" --arg via "$(ncfg slack_via)" --arg tgt "$([[ -n $(ncfg slack_target) ]] && echo set || echo unset)" \
      --arg agent "$(ncfg notifier_agent)" --arg wh "$(notify_webhook_state)" --arg sinks "$(ncfg sinks_default)" \
      --argjson pm "$(ncfg rate_per_min)" --argjson ph "$(ncfg rate_per_hour)" --argjson ml "$(ncfg max_len)" \
      --arg counts "$counts" '{enabled:$en, slack_via:$via, slack_target:$tgt, notifier_agent:$agent, webhook_file:$wh, default_sinks:$sinks, rate_per_min:$pm, rate_per_hour:$ph, max_len:$ml, slack_status_counts:$counts}'
    return 0
  fi
  echo "enabled: $(ncfg enabled) ($(notify_source enabled))"
  echo "default_sinks = $(ncfg sinks_default)"
  for t in $NOTIFY_TYPES; do
    sinks=$(notify_sinks_of "$t")
    if [[ $sinks != "$(ncfg sinks_default)" && $t != digest ]]; then echo "  sinks[$t]: $sinks"; fi
  done
  echo "slack_via: $(ncfg slack_via)"
  echo "slack_target: $([[ -n $(ncfg slack_target) ]] && echo 設定あり || echo 未設定)(値は表示しません)"
  echo "notifier_agent: $(ncfg notifier_agent)"
  echo "webhook_file: $(notify_webhook_state)"
  echo "rate: $(ncfg rate_per_min)/min, $(ncfg rate_per_hour)/hour(超えた分は 1 通にまとめる)  max_len: $(ncfg max_len)  dedupe_sec: $(ncfg dedupe_sec)"
  echo "hash_check: $(ncfg hash_check)  ack_timeout_min: $(ncfg ack_timeout_min)  ack_retries: $(ncfg ack_retries)"
  echo "mask: email=$(ncfg mask_email) ip=$(ncfg mask_ip) repo=$(ncfg mask_repo) account=$(ncfg mask_account) host=$(ncfg mask_host)  strip_raw_logs: $(ncfg strip_raw_logs)"
  echo "secret filter: 常に有効(秘密らしい値を含むイベントは外へ出さず、file にだけ伏せて残す)"
  echo "events: ${counts:-なし}"
}

notify_dry_run() {
  [[ $# -eq 0 ]] || usage "notify dry-run(引数なし)"
  local id text hash n=0 via target budget
  via=$(ncfg slack_via); target=$([[ -n $(ncfg slack_target) ]] && echo 設定あり || echo 未設定)
  if ! notify_on; then echo "(enabled=off: 今は何も積まれず、何も送られません。下は、積まれているものを送るとしたときの内容)"; fi
  budget=$(notify_budget)
  echo "# dry-run: 何も送りません。経路 slack_via=${via} / 宛先 ${target} / 今回の枠 ${budget} 通"
  while IFS=$'\t' read -r id hash text; do
    [[ -n $id ]] || continue
    n=$((n + 1)); echo "would send N-$id [$hash] $text"
  done < <(sql -separator $'\t' "SELECT id, hash, text FROM notify_events WHERE slack_status='pending' AND blocked=0 ORDER BY id;")
  if ((n > budget)); then echo "# 枠を超える分は 1 通にまとめます(個別に送るのは最大 $((budget > 0 ? budget - 1 : 0)) 件)"; fi
  while IFS=$'\t' read -r id text; do
    [[ -n $id ]] || continue; echo "blocked N-$id(外へは送りません) $text"
  done < <(sql -separator $'\t' "SELECT id, text FROM notify_events WHERE blocked=1 ORDER BY id DESC LIMIT 20;")
  if ((n == 0)); then echo "(送るものはありません)"; fi
  return 0
}

notify_tail() {
  local n=20 follow=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      -n) need_arg "$@"; [[ $2 =~ ^[0-9]+$ ]] || usage "tail: -n は整数"; n=$2; shift 2;;
      -f|--follow) follow=1; shift;;
      *) usage "notify tail [-n N] [-f]";;
    esac
  done
  notify_ensure_dir; touch "$NOTIFY_DIR/stdout.log"
  if ((follow)); then tail -n "$n" -f "$NOTIFY_DIR/stdout.log"; else tail -n "$n" "$NOTIFY_DIR/stdout.log"; fi
}

notify_events() {
  local json=0 st="" lim=50 where="1=1"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --json) json=1; shift;;
      --status) need_arg "$@"; st=$2; shift 2;;
      --limit) need_arg "$@"; [[ $2 =~ ^[0-9]{1,4}$ ]] || usage "events: --limit は整数"; lim=$2; shift 2;;
      *) usage "notify events [--status S] [--limit N] [--json]";;
    esac
  done
  if [[ -n $st ]]; then [[ $st =~ ^[a-z-]+$ ]] || usage "events: --status が不正"; where="slack_status=$(q "$st")"; fi
  if ((json)); then sql -json "SELECT * FROM notify_events WHERE $where ORDER BY id DESC LIMIT $lim;" | jq -c '(. // [])[] | .id = "N-\(.id)"'
  else sql -nullvalue - -separator $'\t' "SELECT 'N-'||id, type, slack_status, CASE WHEN blocked=1 THEN 'blocked' ELSE '-' END, created_at, text FROM notify_events WHERE $where ORDER BY id DESC LIMIT $lim;"; fi
}

# notifier agent(または人)が、投稿の結果を返す。本文の hash が合わなければ警告
notify_ack() {
  [[ $# -ge 2 ]] || usage "notify ack N-<n> <hash> [--id <投稿の ID>]"
  local id hash=$2 mid="" row st exp; id=$(notify_event_ref "$1"); shift 2
  while [[ $# -gt 0 ]]; do
    case $1 in
      --id) need_arg "$@"; mid=$2; shift 2;;
      *) usage "notify ack: 不明な引数 $1";;
    esac
  done
  [[ $hash =~ ^[0-9a-f]{12}$ ]] || usage "ack: hash は 12 桁の 16 進(tb notify hash で出す)"
  [[ -z $mid || $mid =~ ^[A-Za-z0-9._:/-]{1,80}$ ]] || usage "ack: --id は英数字と . _ : / - の 80 字まで"
  if [[ -n ${HERDR_PANE_ID:-} ]]; then
    resolve_label || return 3
    [[ $LABEL_NAME == "$(ncfg notifier_agent)" ]] || die "ack は notifier agent($(ncfg notifier_agent))か人だけが使えます($LABEL_NAME)"
  fi
  row=$(sql -json "SELECT * FROM notify_events WHERE id=$id;" | jq -c '.[0] // empty'); [[ -n $row ]] || die "イベントが見つかりません: N-$id"
  st=$(jq -r .slack_status <<<"$row"); exp=$(jq -r .hash <<<"$row")
  [[ $st == awaiting-ack || $st == failed || $st == acked || $st == mismatch ]] || die "N-$id は ack を待っていません($st)"
  if nflag hash_check && [[ $hash != "$exp" ]]; then
    sql "UPDATE notify_events SET slack_status='mismatch', note='投稿された本文の hash が一致しない' WHERE id=$id;"
    notify_emit warning "N-$id-mismatch" "" "N-$id の投稿内容が送った本文と一致しません。Slack 側を確かめてください"
    echo "N-$id mismatch" >&2; return 1
  fi
  sql "UPDATE notify_events SET slack_status='acked', slack_msg_id=NULLIF($(q "$mid"),''), note=NULL WHERE id=$id;"
  echo "N-$id acked"
}
