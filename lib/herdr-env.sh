# shellcheck shell=bash
# 部品(taskboard / scheduler / setup)で共通の既定値。source して使う。何も export しない。
# 環境変数で上書きされていればそちらが優先(各部品が ${TB_DB:-$HERDR_DEFAULT_TB_DB} のように使う)。
# Python 側の同じ定義は lib/herdr_env.py。片方を変えたらもう片方も変える(tests/test_env.sh が突き合わせる)。
HERDR_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HERDR_DEFAULT_BIN=herdr                                   # PATH から探す(scheduler は PATH に /opt/homebrew/bin を足す)
HERDR_DEFAULT_TB_DB=$HERDR_ROOT/taskboard/data/tasks.db   # tb / webui / setup が読み書きする DB
HERDR_SCHEMA_DIR=$HERDR_ROOT/taskboard/schema             # NNN_*.sql。PRAGMA user_version で順に流す

# herdr のセッション名。herdr の CLI と同じ優先順で、HERDR_SOCKET_PATH > HERDR_SESSION > default。
# socket の配置は <config>/herdr/sessions/<名前>/herdr.sock(default は <config>/herdr/herdr.sock)。
# パスから名前を導けない(配置が違う・使えない文字を含む)ときは HERDR_SESSION に落とす。herdr は呼ばない。
herdr_session_name() {
  local p=${HERDR_SOCKET_PATH:-} named='/sessions/([A-Za-z0-9_][A-Za-z0-9._-]*)/herdr\.sock$' dflt='/herdr/herdr\.sock$'
  if [[ $p =~ $named ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; return 0; fi
  if [[ $p =~ $dflt ]]; then echo default; return 0; fi
  echo "${HERDR_SESSION:-default}"
}

# launchd ラベルの接頭辞。TB_INSTANCE 未設定(空)なら従来の "local.herdr-"、設定すれば "local.herdr-<instance>-"。
# instance は英数字で始まり、英数字と . _ - だけ(64 字以内)。違反は何も出さず 2 を返す。
herdr_label_prefix() {
  local inst=${TB_INSTANCE:-} re='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
  if [[ -z $inst ]]; then echo "local.herdr-"; return 0; fi
  [[ $inst =~ $re ]] || { echo "error: TB_INSTANCE は英数字で始まり、英数字と . _ - の 64 字以内: $inst" >&2; return 2; }
  echo "local.herdr-$inst-"
}

# plist の環境変数に渡す値(HERDR_SESSION など)の検査。XML や launchd にそのまま入れてよい文字だけを通す
herdr_plist_value_ok() { [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$ ]]; }
