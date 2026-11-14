#!/usr/bin/env bash
# 複数 herdr セッションの切り分け: セッション名の導出、launchd ラベルの instance、plist への HERDR_SESSION
# plist は一時ディレクトリに書き出して中身を見るだけ(launchctl は呼ばない)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; echo "   expected: $3"; echo "   actual:   $2"; fi; }
clean() { env -u HERDR_SESSION -u HERDR_SOCKET_PATH -u TB_INSTANCE -u TB_UI_PORT "$@"; }
unset HERDR_SESSION HERDR_SOCKET_PATH TB_INSTANCE TB_UI_PORT   # 呼び出し側の環境に左右されない
fn() { bash -c "source '$ROOT/lib/herdr-env.sh'; $1"; }

# --- herdr_session_name: HERDR_SOCKET_PATH > HERDR_SESSION > default
eq "session: nothing set -> default" "$(fn herdr_session_name)" "default"
eq "session: HERDR_SESSION only" "$(HERDR_SESSION=staging fn herdr_session_name)" "staging"
eq "session: socket of a named session" "$(HERDR_SOCKET_PATH=/tmp/h/.config/herdr/sessions/training/herdr.sock fn herdr_session_name)" "training"
eq "session: socket wins over HERDR_SESSION" "$(HERDR_SESSION=staging HERDR_SOCKET_PATH=/tmp/h/.config/herdr/sessions/training/herdr.sock fn herdr_session_name)" "training"
eq "session: default socket" "$(HERDR_SESSION=staging HERDR_SOCKET_PATH=/tmp/h/.config/herdr/herdr.sock fn herdr_session_name)" "default"
eq "session: unknown socket layout falls back to HERDR_SESSION" "$(HERDR_SESSION=staging HERDR_SOCKET_PATH=/tmp/x/other.sock fn herdr_session_name)" "staging"
eq "session: unknown socket layout, nothing else -> default" "$(HERDR_SOCKET_PATH=/tmp/x/other.sock fn herdr_session_name)" "default"
eq "session: unsafe name in socket path falls back" "$(HERDR_SESSION=staging HERDR_SOCKET_PATH='/h/sessions/a b/herdr.sock' fn herdr_session_name)" "staging"

# --- herdr_label_prefix: TB_INSTANCE 未設定なら従来のまま
eq "prefix: unset -> legacy" "$(fn herdr_label_prefix)" "local.herdr-"
eq "prefix: empty -> legacy" "$(TB_INSTANCE= fn herdr_label_prefix)" "local.herdr-"
eq "prefix: instance" "$(TB_INSTANCE=staging fn herdr_label_prefix)" "local.herdr-staging-"
eq "prefix: allowed chars" "$(TB_INSTANCE=a_b-c.1 fn herdr_label_prefix)" "local.herdr-a_b-c.1-"
for bad in 'a b' 'a/b' 'a;b' '-x' '.x' 'a"b' 'a<b' "$(printf 'a\nb')"; do
  eq "prefix: rejected [$(printf %q "$bad")]" "$(TB_INSTANCE=$bad fn herdr_label_prefix >/dev/null 2>&1; echo $?)" "2"
done

# --- plist
JOBS=$TMP/jobs; mkdir -p "$JOBS"
printf "TARGET=dummy\nPROMPT='x'\nWINDOW=09:00-21:00\nINTERVAL_MIN=5\n" >"$JOBS/t.conf"
sched() { clean env JOBS_DIR="$JOBS" LOG_DIR="$TMP/logs" OUT_DIR="$TMP/gen-$1" "${@:2}" bash "$ROOT/scheduler/bin/gen-plist.sh" t >/dev/null 2>&1; }
web() { clean env OUT_DIR="$TMP/gen-$1" "${@:2}" bash "$ROOT/webui/bin/gen-plist.sh" >/dev/null 2>&1; }
label_of() { grep -A1 '<key>Label</key>' "$1" | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p'; }

sched a; eq "sched plist: legacy file name" "$(ls "$TMP/gen-a")" "local.herdr-sched-t.plist"
eq "sched plist: legacy label" "$(label_of "$TMP/gen-a/local.herdr-sched-t.plist")" "local.herdr-sched-t"
eq "sched plist: no HERDR_SESSION by default" "$(grep -c HERDR_SESSION "$TMP/gen-a"/*.plist)" "0"
sched b TB_INSTANCE=staging HERDR_SESSION=staging
eq "sched plist: instance file name" "$(ls "$TMP/gen-b")" "local.herdr-staging-sched-t.plist"
eq "sched plist: instance label" "$(label_of "$TMP/gen-b/local.herdr-staging-sched-t.plist")" "local.herdr-staging-sched-t"
eq "sched plist: HERDR_SESSION passed" "$(grep -A1 '<key>HERDR_SESSION</key>' "$TMP/gen-b"/*.plist | grep -c '<string>staging</string>')" "1"
eq "sched plist: PATH kept" "$(grep -c '<key>PATH</key>' "$TMP/gen-b"/*.plist)" "1"
sched c TB_INSTANCE='a b'; eq "sched plist: bad instance writes nothing" "$(ls "$TMP/gen-c" 2>/dev/null | wc -l | tr -d ' ')" "0"
sched d HERDR_SESSION='a<b'; eq "sched plist: bad HERDR_SESSION writes nothing" "$(ls "$TMP/gen-d" 2>/dev/null | wc -l | tr -d ' ')" "0"

web a; eq "webui plist: legacy file name" "$(ls "$TMP/gen-a" 2>/dev/null | grep -c '^local.herdr-webui.plist$')" "1"
eq "webui plist: legacy label" "$(label_of "$TMP/gen-a/local.herdr-webui.plist")" "local.herdr-webui"
eq "webui plist: no HERDR_SESSION by default" "$(grep -c -e HERDR_SESSION -e TB_UI_PORT "$TMP/gen-a/local.herdr-webui.plist")" "0"
web b TB_INSTANCE=training HERDR_SESSION=training TB_UI_PORT=8811
eq "webui plist: instance label" "$(label_of "$TMP/gen-b/local.herdr-training-webui.plist")" "local.herdr-training-webui"
eq "webui plist: HERDR_SESSION passed" "$(grep -A1 '<key>HERDR_SESSION</key>' "$TMP/gen-b"/*.plist | grep -c '<string>training</string>')" "1"
eq "webui plist: TB_UI_PORT passed" "$(grep -A1 '<key>TB_UI_PORT</key>' "$TMP/gen-b"/*.plist | grep -c '<string>8811</string>')" "1"
web c TB_INSTANCE='a/b'; eq "webui plist: bad instance writes nothing" "$(ls "$TMP/gen-c" 2>/dev/null | wc -l | tr -d ' ')" "0"
web d TB_UI_PORT=80x; eq "webui plist: bad port writes nothing" "$(ls "$TMP/gen-d" 2>/dev/null | wc -l | tr -d ' ')" "0"

# --- tb の HSESS は socket パスを見る(tb 本体を source せず、定義行だけ評価)
eq "tb HSESS follows the socket" "$(HERDR_SESSION=staging HERDR_SOCKET_PATH=/h/.config/herdr/sessions/training/herdr.sock clean env HERDR_SESSION=staging HERDR_SOCKET_PATH=/h/.config/herdr/sessions/training/herdr.sock bash -c "source '$ROOT/lib/herdr-env.sh'; $(grep '^HSESS=' "$ROOT/taskboard/lib/agents.sh" | sed 's/ *#.*//'); echo \$HSESS")" "training"

echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
