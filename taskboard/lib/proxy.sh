# shellcheck shell=bash
# 代行依頼(判定と記録だけ。cmd は tb が実行しない)
# bin/tb から source される。単体では実行しない。

# ---------- 代行依頼(判定と記録だけ。cmd は実行しない) ----------
ALLOWLIST=${TB_ALLOWLIST:-$TB_ROOT/config/proxy-allowlist.txt}
EFFECTS="read-only write external"
valid_pid() { [[ $1 =~ ^[0-9]+$ ]] || usage "代行依頼の ID は数字: $1"; }
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

cmd_proxy-request() {
  [[ $# -ge 1 ]] || usage "proxy-request <task-id> --cmd C --why W --effect read-only|write|external [--expect E]"
  local tid=$1 c="" why="" effect="" expect=""; shift
  valid_id "$tid"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --cmd)    need_arg "$@"; c=$2; shift 2;;
      --why)    need_arg "$@"; why=$2; shift 2;;
      --effect) need_arg "$@"; effect=$2; shift 2;;
      --expect) need_arg "$@"; expect=$2; shift 2;;
      *) usage "proxy-request: 不明な引数 $1";;
    esac
  done
  c=$(trim "$c")
  blank "$c" && usage "proxy-request: --cmd が必要です"
  blank "$why" && usage "proxy-request: --why が必要です"
  [[ -n $effect ]] || usage "proxy-request: --effect が必須です(read-only|write|external。迷ったら write)"
  [[ " $EFFECTS " == *" $effect "* ]] || usage "proxy-request: --effect は $EFFECTS のどれか: $effect"
  require_task "$tid" >/dev/null
  local prior status=open result="" n id; n=$(now)
  prior=$(sql "SELECT id FROM proxy_requests WHERE cmd=$(q "$c") AND status='denied' ORDER BY id LIMIT 1;")
  if [[ -n $prior ]]; then
    status=denied; result="同一 cmd が人に拒否済み(依頼 $prior)。同じ依頼は出し直さず、別の方法を提案すること"
  fi
  id=$(sql "INSERT INTO proxy_requests (task_id, cmd, why, effect, expect, status, result, created_at, updated_at)
            VALUES ($(q "$tid"), $(q "$c"), $(q "$why"), $(q "$effect"), NULLIF($(q "$expect"),''), $(q "$status"),
                    NULLIF($(q "$result"),''), $(q "$n"), $(q "$n")); SELECT last_insert_rowid();")
  [[ $status == denied ]] && echo "tb: $result" >&2
  echo "$id $status"
}

cmd_proxy-list() {
  local status="" json=0 where="1=1"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --status) need_arg "$@"; status=$2; shift 2;;
      --json)   json=1; shift;;
      *) usage "proxy-list: 不明な引数 $1";;
    esac
  done
  if [[ -n $status ]]; then
    [[ $status =~ ^(open|done|pending-human|denied)$ ]] || usage "proxy-list: status は open|done|pending-human|denied: $status"
    where+=" AND status=$(q "$status")"
  fi
  if ((json)); then
    sql -json "SELECT * FROM proxy_requests WHERE $where ORDER BY id;" | jq -c '(. // [])[]'
  else
    sql -separator $'\t' "SELECT id, status, effect, task_id, replace(replace(cmd, char(10), ' '), char(9), ' ') FROM proxy_requests WHERE $where ORDER BY id;"
  fi
}

cmd_proxy-resolve() {
  [[ $# -ge 1 ]] || usage "proxy-resolve <id> --status done|pending-human|denied [--result <本文かファイルパス>]"
  local id=$1 status="" result=""; shift
  valid_pid "$id"
  while [[ $# -gt 0 ]]; do
    case $1 in
      --status) need_arg "$@"; status=$2; shift 2;;
      --result) need_arg "$@"; result=$2; shift 2;;
      *) usage "proxy-resolve: 不明な引数 $1";;
    esac
  done
  [[ $status =~ ^(done|pending-human|denied)$ ]] || usage "proxy-resolve: --status は done|pending-human|denied のどれか"
  local cur; cur=$(sql "SELECT status FROM proxy_requests WHERE id=$id;")
  [[ -n $cur ]] || die "代行依頼が見つかりません: $id"
  [[ $cur == open || $cur == pending-human ]] || die "解決済み($cur)の依頼は変更できません: $id"
  sql "UPDATE proxy_requests SET status=$(q "$status"), result=NULLIF($(q "$result"),''), updated_at=$(q "$(now)") WHERE id=$id;"
  echo "$id $status"
}

# cmd に含まれる「副作用・連鎖・展開」の兆候を META に入れる(クォート内でも拾う。安全側に倒す)
detect_meta() {
  local c=$1; META=()
  [[ $c == *'>'* ]] && META+=("リダイレクト(>)")
  [[ $c == *'<'* ]] && META+=("リダイレクト(<)")
  [[ $c == *'|'* ]] && META+=("パイプ/||")
  [[ $c == *';'* ]] && META+=("連結(;)")
  [[ $c == *'&'* ]] && META+=("連結/バックグラウンド(&, &&)")
  [[ $c == *'$'* ]] && META+=("展開(\$, \$())")
  [[ $c == *'`'* ]] && META+=("バッククォート")
  [[ $c == *$'\n'* || $c == *$'\r'* ]] && META+=("改行")
  grep -Eiq -- '(^|[[:space:]])(-X|--request|--method)[[:space:]=]*(POST|PUT|DELETE|PATCH)' <<<"$c" && META+=("書き込み系の HTTP メソッド")
  grep -Eq -- '(^|[[:space:]])--(approve|merge|body|add)' <<<"$c" && META+=("書き込み系のフラグ(--approve/--merge/--body/--add)")
  grep -Eq -- '(^|[[:space:]])--output' <<<"$c" && META+=("ファイル出力(--output)")
  return 0
}

cmd_proxy-check() {
  [[ $# -eq 1 ]] || usage "proxy-check <id>"
  valid_pid "$1"
  local row c effect status
  row=$(sql -json "SELECT * FROM proxy_requests WHERE id=$1;" | jq -c '.[0] // empty')
  [[ -n $row ]] || die "代行依頼が見つかりません: $1"
  c=$(jq -r .cmd <<<"$row"); effect=$(jq -r .effect <<<"$row"); status=$(jq -r .status <<<"$row")

  local reasons=() mismatch="" META=()
  detect_meta "$c"
  if [[ ${#META[@]} -gt 0 ]]; then
    local metas; metas=$(IFS=、; echo "${META[*]}")
    reasons+=("危険な構文を含む: $metas")
    [[ $effect == read-only ]] && mismatch="申告は read-only だが、コマンドに $metas を含む"
  fi
  [[ $status == denied ]] && reasons+=("すでに denied")
  [[ $effect != read-only ]] && reasons+=("申告 effect が $effect")

  # 許可リスト(先頭一致。語の境界で比較: "git log" は "git log -5" に一致、"git logx" には一致しない)
  local matched="" line
  if [[ -r $ALLOWLIST ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      line=$(trim "$line")
      [[ -z $line || $line == \#* ]] && continue
      if [[ $c == "$line" || $c == "$line "* || $c == "$line"$'\t'* ]]; then matched=$line; break; fi
    done <"$ALLOWLIST"
    [[ -n $matched ]] || reasons+=("許可リストにない")
  else
    reasons+=("許可リストを読めない($ALLOWLIST)。安全側で human")
  fi

  if [[ ${#reasons[@]} -eq 0 ]]; then
    echo allow
    echo "match: $matched"
  else
    echo human
    local r; for r in "${reasons[@]}"; do echo "reason: $r"; done
  fi
  [[ -z $mismatch ]] || echo "mismatch: $mismatch"
  return 0
}
