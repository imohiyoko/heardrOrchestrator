# shellcheck shell=bash
# 部品(taskboard / scheduler / setup)で共通の既定値。source して使う。何も export しない。
# 環境変数で上書きされていればそちらが優先(各部品が ${TB_DB:-$HERDR_DEFAULT_TB_DB} のように使う)。
# Python 側の同じ定義は lib/herdr_env.py。片方を変えたらもう片方も変える(tests/test_env.sh が突き合わせる)。
HERDR_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HERDR_DEFAULT_BIN=herdr                                   # PATH から探す(scheduler は PATH に /opt/homebrew/bin を足す)
HERDR_DEFAULT_TB_DB=$HERDR_ROOT/taskboard/data/tasks.db   # tb / webui / setup が読み書きする DB
HERDR_SCHEMA_DIR=$HERDR_ROOT/taskboard/schema             # NNN_*.sql。PRAGMA user_version で順に流す
