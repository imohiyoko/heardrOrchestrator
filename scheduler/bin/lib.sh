# shellcheck shell=bash
# 共通処理。tick.sh / gen-plist.sh / install.sh から source される。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCHED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS_DIR="${JOBS_DIR:-$SCHED_ROOT/jobs}"
LOG_DIR="${LOG_DIR:-$SCHED_ROOT/logs}"
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

# ジョブ定義を読み込み、既定値を埋めて検証する。
load_job() {
  JOB="${1:-}"
  [[ "$JOB" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "ジョブ名が不正: '$JOB'"
  JOB_CONF="$JOBS_DIR/$JOB.conf"
  [ -f "$JOB_CONF" ] || die "ジョブ定義がない: $JOB_CONF"
  unset TARGET PROMPT PROMPT_FILE COMMAND COMMAND_TIMEOUT WINDOW START END INTERVAL_MIN DAYS SKIP_IF TZ
  # shellcheck disable=SC1090
  source "$JOB_CONF"
  # WINDOW(HH:MM-HH:MM) を START/END に分解。conf が START/END を直接持つならそちらを優先
  if [ -n "${WINDOW:-}" ] && [ -z "${START:-}${END:-}" ]; then
    [[ "$WINDOW" =~ ^([0-9:]+)-([0-9:]+)$ ]] || die "$JOB: WINDOW は HH:MM-HH:MM"
    START=${BASH_REMATCH[1]}; END=${BASH_REMATCH[2]}
  fi
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
