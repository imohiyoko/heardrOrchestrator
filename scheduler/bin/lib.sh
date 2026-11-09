# shellcheck shell=bash
# 共通処理。tick.sh / gen-plist.sh / install.sh から source される。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCHED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS_DIR="${JOBS_DIR:-$SCHED_ROOT/jobs}"
LOG_DIR="${LOG_DIR:-$SCHED_ROOT/logs}"
# Web UI などが書く上書き設定(<job>.settings)の置き場
SETTINGS_DIR="${SCHED_SETTINGS_DIR:-$SCHED_ROOT/settings}"
HERDR="${HERDR_BIN:-/opt/homebrew/bin/herdr}"
export HERDR_BIN_PATH="${HERDR_BIN_PATH:-$HERDR}"

die() { echo "error: $*" >&2; exit 2; }

# "09:00" -> 540
hm_to_min() {
  [[ "$1" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || die "時刻の形式が不正: $1 (HH:MM)"
  local h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
  ((h < 24 && m < 60)) || die "時刻が範囲外: $1"
  echo $((h * 60 + m))
}

# 上書き設定 $SETTINGS_DIR/<job>.settings を読む。bash として実行せず、決まったキーと値の形だけを受け付ける。
# キー: INTERVAL_MIN / START / END / DAYS / ENABLED(0 で一時停止)。結果は S_<キー> に入る
load_settings() {
  local f="$SETTINGS_DIR/$JOB.settings" line k v
  S_INTERVAL_MIN=""; S_START=""; S_END=""; S_DAYS=""; S_ENABLED=""
  [ -e "$f" ] || return 0
  [ -f "$f" ] && [ ! -L "$f" ] || die "$JOB: settings が通常ファイルではない: $f"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "$JOB: settings の行が不正: $f"
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    case "$k" in
      INTERVAL_MIN) [[ "$v" =~ ^[0-9]{1,4}$ ]] || die "$JOB: settings の INTERVAL_MIN が不正"; S_INTERVAL_MIN=$v ;;
      START) [[ "$v" =~ ^[0-9]{2}:[0-9]{2}$ ]] || die "$JOB: settings の START が不正"; S_START=$v ;;
      END) [[ "$v" =~ ^[0-9]{2}:[0-9]{2}$ ]] || die "$JOB: settings の END が不正"; S_END=$v ;;
      DAYS) [[ "$v" =~ ^[A-Za-z][A-Za-z\ ,]{0,39}$ ]] || die "$JOB: settings の DAYS が不正"; S_DAYS=$v ;;
      ENABLED) [[ "$v" =~ ^[01]$ ]] || die "$JOB: settings の ENABLED は 0 か 1"; S_ENABLED=$v ;;
      *) die "$JOB: settings に使えないキー: $k" ;;
    esac
  done <"$f"
  if [ -n "$S_START$S_END" ] && { [ -z "$S_START" ] || [ -z "$S_END" ]; }; then
    die "$JOB: settings の START と END は両方書く"
  fi
}

# ジョブ定義を読み込み、既定値を埋めて検証する。
# 優先順: jobs/<job>.conf < settings/<job>.settings < 環境変数 SCHED_*
load_job() {
  JOB="${1:-}"
  [[ "$JOB" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "ジョブ名が不正: '$JOB'"
  JOB_CONF="$JOBS_DIR/$JOB.conf"
  [ -f "$JOB_CONF" ] || die "ジョブ定義がない: $JOB_CONF"
  unset TARGET PROMPT PROMPT_FILE COMMAND COMMAND_TIMEOUT WINDOW START END INTERVAL_MIN DAYS SKIP_IF TZ ENABLED
  # shellcheck disable=SC1090
  source "$JOB_CONF"
  # WINDOW(HH:MM-HH:MM) を START/END に分解。conf が START/END を直接持つならそちらを優先
  if [ -n "${WINDOW:-}" ] && [ -z "${START:-}${END:-}" ]; then
    [[ "$WINDOW" =~ ^([0-9:]+)-([0-9:]+)$ ]] || die "$JOB: WINDOW は HH:MM-HH:MM"
    START=${BASH_REMATCH[1]}; END=${BASH_REMATCH[2]}
  fi
  load_settings
  if [ -n "$S_START" ]; then START=$S_START; END=$S_END; fi
  INTERVAL_MIN=${S_INTERVAL_MIN:-${INTERVAL_MIN:-}}
  DAYS=${S_DAYS:-${DAYS:-}}
  ENABLED=${S_ENABLED:-${ENABLED:-1}}
  [[ "$ENABLED" =~ ^[01]$ ]] || die "$JOB: ENABLED は 0 か 1"
  # 一時的な上書き: SCHED_WINDOW / SCHED_START / SCHED_END / SCHED_INTERVAL_MIN
  if [ -n "${SCHED_WINDOW:-}" ]; then
    [[ "$SCHED_WINDOW" =~ ^([0-9:]+)-([0-9:]+)$ ]] || die "SCHED_WINDOW は HH:MM-HH:MM"
    START=${BASH_REMATCH[1]}; END=${BASH_REMATCH[2]}
  fi
  START=${SCHED_START:-${START:-}}; END=${SCHED_END:-${END:-}}
  INTERVAL_MIN=${SCHED_INTERVAL_MIN:-${INTERVAL_MIN:-}}
  [ -n "$START" ] && [ -n "$END" ] || die "$JOB: 開始・終了時刻が未設定(WINDOW または START と END)"
  WINDOW="$START-$END"
  : "${DAYS:=daily}" "${SKIP_IF:=working blocked}" "${TZ:=Asia/Tokyo}"
  export TZ
  : "${COMMAND_TIMEOUT:=60}"
  [[ "$COMMAND_TIMEOUT" =~ ^[0-9]+$ ]] && ((COMMAND_TIMEOUT > 0)) || die "$JOB: COMMAND_TIMEOUT は正の整数(秒)"
  if [ -n "${COMMAND:-}" ]; then
    [ -z "${TARGET:-}${PROMPT:-}${PROMPT_FILE:-}" ] || die "$JOB: COMMAND は TARGET/PROMPT/PROMPT_FILE と同時に指定できない"
    TARGET=""   # COMMAND 型は agent を使わない
  else
    [ -n "${TARGET:-}" ] || die "$JOB: TARGET が未設定(または COMMAND を指定)"
  fi
  [ -n "${WINDOW:-}" ] || die "$JOB: WINDOW が未設定"
  [ -n "${COMMAND:-}${PROMPT:-}${PROMPT_FILE:-}" ] || die "$JOB: PROMPT か PROMPT_FILE が必要"
  [[ "${INTERVAL_MIN:-}" =~ ^[0-9]+$ ]] && ((INTERVAL_MIN > 0)) || die "$JOB: INTERVAL_MIN は正の整数"
  [[ "$WINDOW" =~ ^([0-9:]+)-([0-9:]+)$ ]] || die "$JOB: WINDOW は HH:MM-HH:MM"
  WIN_START=$(hm_to_min "${BASH_REMATCH[1]}")
  WIN_END=$(hm_to_min "${BASH_REMATCH[2]}")
  ((WIN_START <= WIN_END)) || die "$JOB: 日をまたぐ WINDOW は未対応"
}

# DAYS を ISO 曜日番号(1=Mon..7=Sun)の空白区切りに展開
days_to_nums() {
  local out="" t
  for t in $(echo "$DAYS" | tr ',A-Z' ' a-z'); do
    case "$t" in
      daily|everyday) out+=" 1 2 3 4 5 6 7" ;;
      weekdays) out+=" 1 2 3 4 5" ;;
      weekends) out+=" 6 7" ;;
      mon*) out+=" 1" ;; tue*) out+=" 2" ;; wed*) out+=" 3" ;; thu*) out+=" 4" ;;
      fri*) out+=" 5" ;; sat*) out+=" 6" ;; sun*) out+=" 7" ;;
      *) die "$JOB: DAYS の指定が不正: $t" ;;
    esac
  done
  echo "$out"
}
