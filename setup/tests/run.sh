#!/usr/bin/env bash
# setup/check.sh のテスト。疑似のリポジトリ・HOME・LaunchAgents と疑似コマンドだけを使う。
# 本物の herdr / launchd / Claude Code の settings には触らない。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../check.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0 failn=0

# PATH に置く実コマンド(check.sh が使うもの)。sqlite3 / jq は has_* で出し入れする
CORE="bash sh sed grep wc tr head basename dirname stat id cat"

# fresh: 全部そろった状態の疑似環境を $TMP/c<n> に作る
n=0
fresh() {
  n=$((n + 1)); W="$TMP/c$n"
  R="$W/repo"; H="$W/home"; LA="$W/LaunchAgents"; B="$W/bin"; P="$W/proj"
  mkdir -p "$R/taskboard/bin" "$R/scheduler/jobs" "$R/scheduler/generated" "$R/webui/run" "$R/webui/generated" \
    "$R/presets" "$H/.claude" "$LA" "$B" "$P/.claude"
  : >"$R/taskboard/bin/tb-hook"
  printf 'COMMAND=x\n' >"$R/scheduler/jobs/taskboard-digest.conf.example"
  printf 'COMMAND=x\n' >"$R/scheduler/jobs/watch.conf.example"
  printf "COMMAND='cd %s/taskboard && bin/tb digest'\n" "$R" >"$R/scheduler/jobs/taskboard-digest.conf"
  echo 'conductor|1||~/x' >"$R/presets/example.conf"
  echo 'setup|1|x' >"$R/presets/setup.conf"
  printf 'conductor|1|hi|%s\n' "$P" >"$R/presets/mine.conf"
  hook_json UserPromptSubmit Stop >"$P/.claude/settings.local.json"
  echo '<plist><dict/></plist>' >"$LA/local.herdr-sched-taskboard-digest.plist"
  echo '<plist><dict/></plist>' >"$LA/local.herdr-webui.plist"
  echo '{}' >"$R/webui/run/auth.json"; chmod 600 "$R/webui/run/auth.json"
  for c in $CORE jq; do ln -s "$(command -v "$c")" "$B/$c"; done
  for c in sqlite3 python3 claude plutil; do ln -s "$HERE/fake/stub" "$B/$c"; done
  ln -s "$HERE/fake/herdr" "$B/herdr"; ln -s "$HERE/fake/launchctl" "$B/launchctl"
  export FAKE_LOADED="local.herdr-sched-taskboard-digest local.herdr-webui" FAKE_HERDR_DOWN=0 FAKE_LOG="$W/calls.log"
  OSNAME=Darwin
}
# hook_json <event>... [-- <hook のパス>]: settings.json を出す
hook_json() {
  local path="$R/taskboard/bin/tb-hook" evs=() e
  while [ $# -gt 0 ]; do [ "$1" = -- ] && { path=$2; break; }; evs+=("$1"); shift; done
  for e in "${evs[@]}"; do printf '%s\n' "$e"; done |
    jq -R --arg c "bash $path" '{key: ., value: [{hooks: [{type: "command", command: $c, timeout: 5}]}]}' |
    jq -s '{hooks: from_entries}'
}
run() {
  OUT=$(env -i PATH="$B" HOME="$H" SETUP_ROOT="$R" LAUNCH_AGENTS_DIR="$LA" SETUP_UNAME="$OSNAME" \
    FAKE_LOADED="$FAKE_LOADED" FAKE_HERDR_DOWN="$FAKE_HERDR_DOWN" FAKE_LOG="$FAKE_LOG" \
    "$B/bash" "$CHECK" "$@" 2>&1)
  RC=$?
}
ok() { pass=$((pass + 1)); echo "ok   $1"; }
ng() { failn=$((failn + 1)); echo "FAIL $1"; printf '%s\n' "$OUT" | sed 's/^/     | /'; }
# has <説明> <状態> <項目> [説明の一部]
has() {
  if printf '%s\n' "$OUT" | grep -E "^$2 +$3 " | grep -qF -- "${4:-}"; then ok "$1"; else ng "$1 (want: $2 $3 ${4:-})"; fi
}
hasnt() { if printf '%s\n' "$OUT" | grep -qE "^$2 +$3 "; then ng "$1 (unexpected: $2 $3)"; else ok "$1"; fi; }
rc_is() { if [ "$RC" = "$2" ]; then ok "$1"; else ng "$1 (rc want=$2 got=$RC)"; fi; }

# --- すべてそろっている ---
fresh; run
rc_is "全部そろえば終了コード 0" 0
printf '%s\n' "$OUT" | grep -q '^summary: .* warn=0 missing=0 ' && ok "summary に warn=0 missing=0" || ng "summary"
has "プロジェクトの hook を検出"      ok hook:proj "登録あり"
has "digest の launchd が読み込み済み" ok launchd:taskboard-digest
has "webui の launchd が読み込み済み"  ok launchd:webui
has "auth.json 600 は ok"            ok webui:auth
has "watch は任意なので info"         info job:watch
grep -v '^launchctl print gui/[0-9]*/local\.herdr-' "$FAKE_LOG" | grep -q launchctl \
  && ng "launchctl は print 以外を呼ばない" || ok "launchctl は print 以外を呼ばない"
grep -q '^herdr workspace list$' "$FAKE_LOG" && ! grep -v '^herdr workspace list$' "$FAKE_LOG" | grep -q '^herdr' \
  && ok "herdr は workspace list だけ呼ぶ" || ng "herdr の呼び出し"
grep -q '^fake .*sqlite3' "$FAKE_LOG" && ng "sqlite3 を実行しない" || ok "sqlite3 を実行しない"

# --- 読み取りのみ(ファイルが増えない・変わらない) ---
fresh
FAKE_LOG="$TMP/calls-$n.log"; : >"$TMP/marker-$n"; sleep 1
before=$(cd "$W" && find . | sort)
run; run --project "$P"; FAKE_HERDR_DOWN=1; run; OSNAME=Linux; run
after=$(cd "$W" && find . | sort)
[ "$before" = "$after" ] && ok "ファイルを作らない・消さない" || ng "ファイルを作らない・消さない"
[ -z "$(find "$W" -newer "$TMP/marker-$n")" ] && ok "ファイルを書き換えない" || ng "ファイルを書き換えない"

# --- コマンド ---
fresh; rm "$B/sqlite3"; run
has "sqlite3 がない" missing cmd:sqlite3; rc_is "missing があれば終了コード 1" 1
fresh; rm "$B/jq"; run
has "jq がないと hook は skip" skip hook; has "jq がない" missing cmd:jq
fresh; rm "$B/herdr"; run
has "herdr がない" missing cmd:herdr; has "herdr がないと server は skip" skip herdr:server
fresh; FAKE_HERDR_DOWN=1; run
has "server が止まっている" warn herdr:server; rc_is "warn だけでも終了コード 1" 1
fresh; rm "$B/plutil"; run; has "macOS で plutil がない" warn cmd:plutil
fresh; rm "$B/plutil"; OSNAME=Linux; run; hasnt "macOS 以外は plutil を見ない" warn cmd:plutil

# --- tb-hook ---
fresh; rm "$P/.claude/settings.local.json"; run
has "hook が未登録" missing hook:proj "未登録"
fresh; rm "$P/.claude/settings.local.json"; hook_json UserPromptSubmit Stop >"$P/.claude/settings.json"; run
has "settings.json の登録も検出" ok hook:proj
fresh; hook_json UserPromptSubmit >"$P/.claude/settings.local.json"; run
has "片方だけの登録は warn" warn hook:proj "片方だけ"
fresh; hook_json UserPromptSubmit Stop -- /nope/tb-hook >"$P/.claude/settings.local.json"; run
has "存在しないパスは missing" missing hook:proj "/nope/tb-hook"
fresh; : >"$W/other-tb-hook"; hook_json UserPromptSubmit Stop -- "$W/other-tb-hook" >"$P/.claude/settings.local.json"; run
has "別の場所の tb-hook は warn" warn hook:proj "別の場所"
fresh; jq '.hooks.Stop += .hooks.Stop' "$P/.claude/settings.local.json" >"$W/d.json"; mv "$W/d.json" "$P/.claude/settings.local.json"; run
has "同じ event に 2 つは warn" warn hook:proj "2 つ以上"
fresh; echo '{ broken' >"$P/.claude/settings.local.json"; run
has "壊れた JSON は warn" warn hook:proj "JSON"; has "壊れた JSON は未登録扱い" missing hook:proj "未登録"
fresh; rm "$P/.claude/settings.local.json"; hook_json UserPromptSubmit Stop >"$H/.claude/settings.json"; run
has "グローバルの登録は warn(全プロジェクトが対象)" warn hook:global "全プロジェクト"
has "グローバルだけでもプロジェクトは記録される" ok hook:proj "グローバル"
fresh; hook_json UserPromptSubmit Stop >"$H/.claude/settings.json"; run
has "グローバルとプロジェクトの二重登録は warn" warn hook:proj "二重"
fresh; mkdir -p "$W/p2"; run --project "$W/p2"
has "--project で対象を指定" missing hook:p2; hasnt "--project 指定時は presets を見ない" ok hook:proj
fresh; run --project "$W/none"; has "存在しないプロジェクト" missing hook:none "ディレクトリがない"
fresh; rm "$R/presets/mine.conf"; run
has "プリセットがなければ hook の対象もない" missing hook "確認するプロジェクトがない"
has "自分用のプリセットがない" missing presets
fresh; printf 'w|1||~/proj\n' >"$R/presets/mine.conf"; mv "$P" "$H/proj"; P="$H/proj"; run
has "プリセットの ~ を HOME に展開" ok hook:proj

# --- scheduler ---
fresh; rm "$R/scheduler/jobs/taskboard-digest.conf"; run
has "digest の conf がないと missing" missing job:taskboard-digest
fresh; echo "COMMAND='cd /path/to/taskboard && bin/tb digest'" >"$R/scheduler/jobs/taskboard-digest.conf"; run
has "/path/to/ が残っていると missing" missing job:taskboard-digest "/path/to/"
fresh; FAKE_LOADED="local.herdr-webui"; run
has "plist はあるが読み込まれていない" warn launchd:taskboard-digest "読み込まれていない"
fresh; rm "$LA/local.herdr-sched-taskboard-digest.plist"; run
has "plist が未生成・未登録" missing launchd:taskboard-digest "未生成"
fresh; rm "$LA/local.herdr-sched-taskboard-digest.plist"; : >"$R/scheduler/generated/local.herdr-sched-taskboard-digest.plist"; run
has "plist は生成済みだが未登録" missing launchd:taskboard-digest "生成済み"
fresh; echo '<key>Hour</key>' >"$LA/local.herdr-sched-taskboard-digest.plist"; run
has "時刻を焼き込んだ古い plist は warn" warn launchd:taskboard-digest "古い形式"
fresh; echo 'TARGET=x' >"$R/scheduler/jobs/mine.conf"; run
has "独自のジョブも出す" info job:mine; has "独自のジョブの launchd も見る" missing launchd:mine
fresh; OSNAME=Linux; run
has "macOS 以外は launchd を skip" skip launchd:webui
rc_is "skip だけなら終了コード 0" 0
fresh; rm "$B/launchctl"; run; has "launchctl がなければ skip" skip launchd:webui

# --- Web UI ---
fresh; rm "$R/webui/run/auth.json"; run
has "auth.json がない" missing webui:auth "ログイン未設定"
printf '%s\n' "$OUT" | grep -A1 "^missing *webui:auth" | grep -q "/setup" && ok "next: で /setup を案内" || ng "next: で /setup を案内"
fresh; chmod 644 "$R/webui/run/auth.json"; run
has "auth.json の権限が 600 でない" warn webui:auth "644"
fresh; echo '{"password_hash":"SECRET-HASH"}' >"$R/webui/run/auth.json"; chmod 600 "$R/webui/run/auth.json"; run
printf '%s\n' "$OUT" | grep -q SECRET && ng "auth.json の中身を出さない" || ok "auth.json の中身を出さない"
fresh; : >"$R/webui/run/token"; run; has "廃止された token" warn webui:token
fresh; echo 8803 >"$R/webui/run/port"; run; has "起動中のポート" info webui:port "8803"

# --- 引数 ---
fresh; run --bogus; rc_is "不明なオプションは 2" 2

echo "passed=$pass failed=$failn"
[ "$failn" -eq 0 ]
