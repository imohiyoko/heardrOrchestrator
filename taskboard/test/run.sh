#!/usr/bin/env bash
# tb のテスト。本物の herdr は一切呼ばない(HERDR_BIN を疑似 herdr に固定)。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export TB_DB=$TMP/tasks.db TB_CONFIG=$TMP/projects.conf TB_LIMITS=$TMP/limits-default.conf
unset HERDR_SOCKET_PATH   # 実行する pane の socket に左右されない(HSESS は HERDR_SOCKET_PATH を HERDR_SESSION より優先する)
export HERDR_BIN=$HERE/fake-herdr FAKE_LOG=$TMP/herdr.log
TB=$HERE/../bin/tb
# 起動直後の準備待ちは既定では短く、送信確認は切る(98_ready で個別に有効化)
export TB_PROMPT_VERIFY_SEC=0 TB_SPAWN_POLL_SEC=0.05 TB_SPAWN_READY_SEC=0.2 TB_VERIFY_POLL_SEC=0.05
: >"$FAKE_LOG"
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "ok   $1"; }
ng()   { fail=$((fail+1)); echo "FAIL $1"; }
eq()   { [[ "$2" == "$3" ]] && ok "$1" || { ng "$1"; echo "   expected: $3"; echo "   actual:   $2"; }; }
rc()   { "$@" >/dev/null 2>&1; echo $?; }
prompts() { grep -c '^prompt' "$FAKE_LOG"; }

# 各機能のテストは cases/NN_*.sh(taskboard/lib/ のファイルにおおむね対応)。番号順に同じシェルで流す
for c in "$HERE"/cases/[0-9][0-9]_*.sh; do
  # shellcheck source=/dev/null
  source "$c"
done

echo; echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
