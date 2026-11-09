#!/usr/bin/env bash
# すべての部品のテストを順に流す。どれかが失敗したら終了コード 1
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
failed=()
for t in tests/test_env.sh tests/test_webui_queries.py taskboard/test/run.sh webui/tests/run.sh scheduler/tests/run.sh setup/tests/run.sh; do
  echo "=== $t"
  case $t in *.py) run=python3;; *) run=bash;; esac
  if ! $run "$ROOT/$t" >"${TMPDIR:-/tmp}/herdr-test.$$" 2>&1; then
    failed+=("$t"); grep -E 'FAIL|Error|Traceback' "${TMPDIR:-/tmp}/herdr-test.$$" | head -40
  fi
  tail -n 1 "${TMPDIR:-/tmp}/herdr-test.$$"
done
rm -f "${TMPDIR:-/tmp}/herdr-test.$$"
if ((${#failed[@]})); then echo; echo "失敗: ${failed[*]}"; exit 1; fi
echo; echo "all passed"
