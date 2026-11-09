#!/usr/bin/env bash
# lib/herdr-env.sh と lib/herdr_env.py が同じ既定値を返すか突き合わせる
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
pass=0; fail=0
eq() { if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; echo "   bash:   $2"; echo "   python: $3"; fi; }
sh_val() { env -u TB_DB -u HERDR_BIN bash -c "source '$HERE/../lib/herdr-env.sh'; echo \"\$$1\""; }
py_val() { env -u TB_DB -u HERDR_BIN python3 -c "import sys; sys.path.insert(0, '$HERE/../lib'); import herdr_env; print($1)"; }
eq "root"      "$(sh_val HERDR_ROOT)"          "$(py_val herdr_env.HERDR_ROOT)"
eq "herdr bin" "$(sh_val HERDR_DEFAULT_BIN)"   "$(py_val 'herdr_env.herdr_bin()')"
eq "tb db"     "$(sh_val HERDR_DEFAULT_TB_DB)" "$(py_val 'herdr_env.tb_db()')"
eq "schema"    "$(sh_val HERDR_SCHEMA_DIR)"    "$(py_val herdr_env.SCHEMA_DIR)"
eq "schema version" "$(env -u TB_DB bash -c "source '$HERE/../lib/herdr-env.sh'; source '$HERE/../taskboard/lib/db.sh'; schema_latest")" "$(py_val 'herdr_env.schema_version()')"
eq "TB_DB override (python)" "$(TB_DB=/x/y.db python3 -c "import sys; sys.path.insert(0, '$HERE/../lib'); import herdr_env; print(herdr_env.tb_db())")" "/x/y.db"
echo "pass=$pass fail=$fail"; [[ $fail -eq 0 ]]
