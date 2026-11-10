#!/usr/bin/env bash
# セットアップの診断(読み取りのみ)。何が入っていて何が足りないかを 1 項目 1 行で出す。
# usage: setup/check.sh [--project DIR]...
#   --project DIR  tb-hook を確認するプロジェクト(worker の cwd)。省略時は presets/*.conf の作業ディレクトリ
#                  (example.conf と setup.conf を除く)
# 出力: "<状態> <項目> <説明>" と、必要なら次の行に "      next: <次にやること>"。最後に summary 行。
#   状態: ok / warn(動くが要確認) / missing(未設定) / skip(この環境では確認できない) / info
# 終了コード: warn も missing もなければ 0、あれば 1。
#
# このスクリプトはファイルを作らず、書き換えず、launchctl は print だけを使う。
# 環境変数(テスト用の差し替え): SETUP_ROOT(リポジトリ) HOME HERDR_BIN LAUNCHCTL_BIN LAUNCH_AGENTS_DIR
#   SETUP_UNAME(uname -s の結果)
set -u

ROOT="${SETUP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HERDR="${HERDR_BIN:-herdr}"
LAUNCHCTL="${LAUNCHCTL_BIN:-launchctl}"
LA_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
OS="${SETUP_UNAME:-$(uname -s)}"

projects=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || { echo "usage: check.sh [--project DIR]..." >&2; exit 2; }
               projects+=("$2"); shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

n_ok=0 n_warn=0 n_missing=0 n_skip=0
# report <状態> <項目> <説明> [次にやること]
report() {
  printf '%-7s %-28s %s\n' "$1" "$2" "$3"
  [ -n "${4:-}" ] && printf '        next: %s\n' "$4"
  case "$1" in
    ok) n_ok=$((n_ok + 1)) ;; warn) n_warn=$((n_warn + 1)) ;;
    missing) n_missing=$((n_missing + 1)) ;; skip) n_skip=$((n_skip + 1)) ;;
  esac
}
have() { command -v "$1" >/dev/null 2>&1; }
# ファイルの権限(8 進数)。macOS と Linux の stat の違いを吸収する
perm_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
is_mac() { [ "$OS" = Darwin ]; }

# --- 1. コマンド ---------------------------------------------------------------
for c in bash jq sqlite3 python3 claude; do
  if have "$c"; then report ok "cmd:$c" "$(command -v "$c")"
  else
    case $c in
      claude) report missing "cmd:$c" "Claude Code が PATH にない" "Claude Code をインストールする" ;;
      *) report missing "cmd:$c" "PATH にない" "brew install $c" ;;
    esac
  fi
done
if have "$HERDR"; then
  report ok "cmd:herdr" "$(command -v "$HERDR")"
  if "$HERDR" workspace list >/dev/null 2>&1; then report ok "herdr:server" "応答あり"
  else report warn "herdr:server" "server が応答しない(止まっている)" "herdr-up.sh <preset> を実行すると headless で起動する"; fi
else
  report missing "cmd:herdr" "PATH にない" "herdr をインストールする"
  report skip "herdr:server" "herdr がないので確認できない"
fi
if is_mac; then
  if have plutil; then report ok "cmd:plutil" "$(command -v plutil)"
  else report warn "cmd:plutil" "PATH にない(plist の lint に使う)"; fi
fi

# --- 2. tb-hook(Claude Code の settings) ----------------------------------------
HOOK="$ROOT/taskboard/bin/tb-hook"

# settings ファイル 1 つについて、event に tb-hook を呼ぶ command があれば 1 行ずつ出す
hook_cmds() { jq -r --arg e "$2" '.hooks[$e][]?.hooks[]? | select(.type == "command") | .command // empty | select(test("tb-hook"))' "$1" 2>/dev/null; }

# scan_settings <ファイル>: 登録を調べ、"found" または "<状態>|<説明>|<次>" を 1 行ずつ出す(report はしない)
scan_settings() {
  local f=$1 e cmds path n=0
  [ -f "$f" ] || return 0
  if ! jq -e . "$f" >/dev/null 2>&1; then echo "warn|JSON として読めない: $f|書式を直す"; return 0; fi
  for e in UserPromptSubmit Stop; do
    cmds=$(hook_cmds "$f" "$e")
    if [ -z "$cmds" ]; then continue; fi
    n=$((n + 1))
    if [ "$(printf '%s\n' "$cmds" | wc -l | tr -d ' ')" -gt 1 ]; then
      echo "warn|$e に tb-hook が 2 つ以上: $f|1 つにする(turn ごとに 2 回記録される)"
    fi
    path=$(printf '%s\n' "$cmds" | head -1 | sed -E 's/^(bash|sh)[[:space:]]+//; s/[[:space:]].*$//')
    if [ "$path" = "$HOOK" ]; then :
    elif [ -f "$path" ]; then echo "warn|$e の tb-hook が別の場所を指す: $path|このリポジトリの $HOOK に揃える"
    else echo "missing|$e の tb-hook が存在しないパス: $path|パスを $HOOK に直す"; fi
  done
  [ $n = 0 ] && return 0
  echo found
  [ $n = 1 ] && echo "warn|UserPromptSubmit と Stop の片方だけに登録: $f|両方に入れる"
  return 0
}

# report_scan <項目> <scan_settings の出力>: 問題を report し、登録があれば 0 を返す
report_scan() {
  local name=$1 line st msg nx rc=1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$line" = found ]; then rc=0; continue; fi
    st=${line%%|*}; line=${line#*|}; msg=${line%%|*}; nx=${line#*|}
    report "$st" "$name" "$msg" "$nx"
  done <<<"$2"
  return $rc
}

if ! have jq; then
  report skip "hook" "jq がないので settings を読めない"
else
  # グローバル(全セッションが対象になる。docs/hook-install.md のリスク参照)
  global=0
  if report_scan "hook:global" "$(scan_settings "$HOME/.claude/settings.json")"; then
    global=1
    report warn "hook:global" "$HOME/.claude/settings.json に登録がある(全プロジェクトが対象)" \
      "意図したものか確認する。project 単位を推奨(taskboard/docs/hook-install.md)"
  fi

  if [ ${#projects[@]} -eq 0 ]; then
    for p in "$ROOT"/presets/*.conf; do
      [ -f "$p" ] || continue
      case "$(basename "$p")" in example.conf|setup.conf) continue ;; esac
      while IFS='|' read -r label _ _ dir _; do
        [[ -z ${label// } || $label == \#* || -z ${dir// } ]] && continue
        projects+=("${dir/#\~/$HOME}")
      done <"$p"
    done
  fi
  if [ ${#projects[@]} -eq 0 ] && [ $global = 0 ]; then
    report missing "hook" "確認するプロジェクトがない(presets/*.conf に作業ディレクトリがない)" \
      "worker 用のプリセットを作るか、--project <dir> を付けて再実行する"
  fi
  seen=" "
  for d in ${projects[@]+"${projects[@]}"}; do
    case "$seen" in *" $d "*) continue ;; esac
    seen="$seen$d "
    name="hook:$(basename "$d")"
    if [ ! -d "$d" ]; then report missing "$name" "ディレクトリがない: $d" "プリセットの作業ディレクトリを直す"; continue; fi
    if report_scan "$name" "$(scan_settings "$d/.claude/settings.json"; scan_settings "$d/.claude/settings.local.json")"; then
      if [ $global = 1 ]; then report warn "$name" "グローバルとプロジェクトの両方に登録(二重記録)" "どちらか一方にする"
      else report ok "$name" "登録あり: $d/.claude/"; fi
    elif [ $global = 1 ]; then report ok "$name" "グローバルの登録で記録される"
    else report missing "$name" "tb-hook が未登録: $d" "$d/.claude/settings.local.json に hook を足す(taskboard/docs/hook-install.md)"; fi
  done
fi

# --- 3. taskboard ----------------------------------------------------------------
db="${TB_DB:-$ROOT/taskboard/data/tasks.db}"
if [ -f "$db" ]; then
  # スキーマの版(taskboard/schema/NNN_*.sql の最大番号)と DB の PRAGMA user_version を比べる。読むだけ
  latest=0
  for f in "$ROOT"/taskboard/schema/[0-9][0-9][0-9]_*.sql; do [ -f "$f" ] && latest=$((10#$(basename "$f" | cut -c1-3))); done
  ver=""; have sqlite3 && ver=$(sqlite3 -readonly "$db" "PRAGMA user_version;" 2>/dev/null)
  if [[ $ver =~ ^[0-9]+$ ]] && [ "$latest" -gt 0 ] && [ "$ver" -lt "$latest" ]; then
    report info "taskboard:db" "$db(スキーマ v${ver}、最新は v${latest}。次に tb を実行したとき移行される)"
  else report ok "taskboard:db" "$db${ver:+(スキーマ v$ver)}"; fi
else report info "taskboard:db" "まだない(最初の tb add で作られる): $db"; fi

# --- 4. launchd の共通処理 ------------------------------------------------------
# launchd_check <項目> <ラベル> <生成元 plist>
launchd_check() {
  local name=$1 label=$2 gen=$3 dst="$LA_DIR/$2.plist"
  if ! is_mac; then report skip "$name" "macOS ではないので launchd は確認しない"; return; fi
  if [ ! -f "$dst" ]; then
    if [ -f "$gen" ]; then report missing "$name" "plist は生成済みだが未登録: $label" "登録する(人の承認が要る。setup/CLAUDE.md の手順)"
    else report missing "$name" "plist が未生成・未登録: $label" "plist を生成して登録する(setup/CLAUDE.md の手順)"; fi
    return
  fi
  if ! have "$LAUNCHCTL"; then report skip "$name" "launchctl がない"; return; fi
  if "$LAUNCHCTL" print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    if grep -q '<key>Hour</key>' "$dst" 2>/dev/null; then
      report warn "$name" "古い形式の plist(時刻を焼き込んでいる): $dst" "gen-plist.sh で作り直して再登録する"
    else report ok "$name" "登録済み・読み込み済み: $label"; fi
  else
    report warn "$name" "$dst はあるが launchd に読み込まれていない" "launchctl bootstrap し直す(人の承認が要る)"
  fi
}

# --- 5. scheduler のジョブ ------------------------------------------------------
JOBS="$ROOT/scheduler/jobs"
for ex in "$JOBS"/*.conf.example; do
  [ -f "$ex" ] || continue
  job=$(basename "$ex" .conf.example)
  conf="$JOBS/$job.conf"
  # taskboard-digest は worker の報告を指揮官に届けるのに要る。ほかは任意
  required=0; [ "$job" = taskboard-digest ] && required=1
  if [ ! -f "$conf" ]; then
    if [ $required = 1 ]; then report missing "job:$job" "$job.conf がない" "$job.conf.example をコピーしてパスを直す"
    else report info "job:$job" "未使用(任意。使うなら $job.conf.example をコピー)"; fi
    continue
  fi
  if grep -q '/path/to/' "$conf"; then
    report missing "job:$job" "$job.conf に /path/to/ が残っている" "実際のパスに書き換える"
  else report ok "job:$job" "$conf"; fi
  launchd_check "launchd:$job" "local.herdr-sched-$job" "$ROOT/scheduler/generated/local.herdr-sched-$job.plist"
done
# .example のない独自ジョブ
for conf in "$JOBS"/*.conf; do
  [ -f "$conf" ] || continue
  job=$(basename "$conf" .conf)
  [ -f "$JOBS/$job.conf.example" ] && continue
  report info "job:$job" "独自のジョブ: $conf"
  launchd_check "launchd:$job" "local.herdr-sched-$job" "$ROOT/scheduler/generated/local.herdr-sched-$job.plist"
done

# --- 6. Web UI --------------------------------------------------------------------
RUN="$ROOT/webui/run"
if [ -f "$RUN/auth.json" ]; then
  mode=$(perm_of "$RUN/auth.json")
  if [ "$mode" = 600 ]; then report ok "webui:auth" "ログイン設定済み(内容は表示しない)"
  else report warn "webui:auth" "run/auth.json の権限が $mode(600 であるべき)" "chmod 600 webui/run/auth.json"; fi
else
  report missing "webui:auth" "ログイン未設定(run/auth.json がない)" "Web UI を起動し、本人がブラウザで /setup を開いてユーザー名とパスワードを作る"
fi
[ -e "$RUN/token" ] && report warn "webui:token" "廃止された run/token が残っている" "rm webui/run/token(もう使わない)"
if [ -f "$RUN/port" ]; then report info "webui:port" "起動中の可能性: http://127.0.0.1:$(head -c 6 "$RUN/port" | tr -cd 0-9)/"; fi
launchd_check "launchd:webui" "local.herdr-webui" "$ROOT/webui/generated/local.herdr-webui.plist"

# --- 7. プリセット ---------------------------------------------------------------
n_presets=0
for p in "$ROOT"/presets/*.conf; do
  [ -f "$p" ] || continue
  case "$(basename "$p")" in example.conf|setup.conf) continue ;; esac
  n_presets=$((n_presets + 1))
done
if [ $n_presets -gt 0 ]; then report ok "presets" "$n_presets 個(example/setup 以外)"
else report missing "presets" "自分用のプリセットがない" "presets/example.conf を元に presets/<名前>.conf を作る"; fi

echo "summary: ok=$n_ok warn=$n_warn missing=$n_missing skip=$n_skip"
[ $n_warn -eq 0 ] && [ $n_missing -eq 0 ]
