# shellcheck shell=bash
# 共通処理。tick.sh / gen-plist.sh / install.sh から source される。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCHED_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS_DIR="${JOBS_DIR:-$SCHED_ROOT/jobs}"
LOG_DIR="${LOG_DIR:-$SCHED_ROOT/logs}"
# Web UI などが書く上書き設定(<job>.settings)の置き場
SETTINGS_DIR="${SCHED_SETTINGS_DIR:-$SCHED_ROOT/settings}"
# shellcheck source=../../lib/herdr-env.sh
source "$SCHED_ROOT/../lib/herdr-env.sh"
HERDR="${HERDR_BIN:-$HERDR_DEFAULT_BIN}"   # 上の PATH で /opt/homebrew/bin/herdr が先に見つかる
export HERDR_BIN_PATH="${HERDR_BIN_PATH:-$HERDR}"

die() { echo "error: $*" >&2; exit 2; }

# 時刻 -> その日の 0 時からの秒数。"09:00" -> 32400、"09:00:30" -> 32430。
# 第 2 引数が end のとき、秒を省いた "HH:MM" はその分の 59 秒までを含む("21:00" -> 21:00:59)。
# 秒に対応する前は分単位で判定していたので、"21:00" を終端に書いた窓は 21:00 台を丸ごと含んでいた。その意味を変えないため
hms_to_sec() {
  [[ "$1" =~ ^([0-9]{1,2}):([0-9]{2})(:([0-9]{2}))?$ ]] || die "時刻の形式が不正: $1 (HH:MM か HH:MM:SS)"
  local h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]})) s
  if [ -n "${BASH_REMATCH[3]}" ]; then s=$((10#${BASH_REMATCH[4]})); elif [ "${2:-}" = end ]; then s=59; else s=0; fi
  ((h < 24 && m < 60 && s < 60)) || die "時刻が範囲外: $1"
  echo $((h * 3600 + m * 60 + s))
}

# 間隔(秒)を表示用に。60 で割り切れれば分で出す
interval_label() { if ((INTERVAL_SEC % 60 == 0)); then echo "$((INTERVAL_SEC / 60)) 分"; else echo "$INTERVAL_SEC 秒"; fi; }

# INTERVAL_MIN / INTERVAL_SEC のどちらか一方から秒を得る。<場所> <分> <秒>。両方空なら空
interval_of() {
  [ -n "$2" ] && [ -n "$3" ] && die "$JOB: $1 に INTERVAL_MIN と INTERVAL_SEC を同時に書かない"
  if [ -n "$2" ]; then
    [[ "$2" =~ ^[0-9]+$ ]] && ((10#$2 > 0)) || die "$JOB: INTERVAL_MIN は正の整数"
    echo $((10#$2 * 60))
  elif [ -n "$3" ]; then
    [[ "$3" =~ ^[0-9]+$ ]] && ((10#$3 > 0)) || die "$JOB: INTERVAL_SEC は正の整数"
    echo $((10#$3))
  fi
}

# 上書き設定 $SETTINGS_DIR/<job>.settings を読む。bash として実行せず、決まったキーと値の形だけを受け付ける。
# キー: INTERVAL_MIN か INTERVAL_SEC / START / END / DAYS / ENABLED(0 で一時停止)。結果は S_<キー> に入る
load_settings() {
  local f="$SETTINGS_DIR/$JOB.settings" line k v
  S_INTERVAL_MIN=""; S_INTERVAL_SEC=""; S_START=""; S_END=""; S_DAYS=""; S_ENABLED=""
  [ -e "$f" ] || return 0
  [ -f "$f" ] && [ ! -L "$f" ] || die "$JOB: settings が通常ファイルではない: $f"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "$JOB: settings の行が不正: $f"
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    case "$k" in
      INTERVAL_MIN) [[ "$v" =~ ^[0-9]{1,4}$ ]] || die "$JOB: settings の INTERVAL_MIN が不正"; S_INTERVAL_MIN=$v ;;
      INTERVAL_SEC) [[ "$v" =~ ^[0-9]{1,5}$ ]] || die "$JOB: settings の INTERVAL_SEC が不正"; S_INTERVAL_SEC=$v ;;
      START) [[ "$v" =~ ^[0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]] || die "$JOB: settings の START が不正"; S_START=$v ;;
      END) [[ "$v" =~ ^[0-9]{2}:[0-9]{2}(:[0-9]{2})?$ ]] || die "$JOB: settings の END が不正"; S_END=$v ;;
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
  unset TARGET PROMPT PROMPT_FILE COMMAND COMMAND_TIMEOUT WINDOW START END INTERVAL_MIN INTERVAL_SEC DAYS SKIP_IF TZ ENABLED
  # shellcheck disable=SC1090
  source "$JOB_CONF"
  # WINDOW(HH:MM[:SS]-HH:MM[:SS]) を START/END に分解。conf が START/END を直接持つならそちらを優先
  if [ -n "${WINDOW:-}" ] && [ -z "${START:-}${END:-}" ]; then
    [[ "$WINDOW" =~ ^([0-9:]+)-([0-9:]+)$ ]] || die "$JOB: WINDOW は HH:MM-HH:MM"
    START=${BASH_REMATCH[1]}; END=${BASH_REMATCH[2]}
  fi
  load_settings
  if [ -n "$S_START" ]; then START=$S_START; END=$S_END; fi
  # 間隔は秒で持つ。conf / settings / SCHED_* の各層で INTERVAL_MIN か INTERVAL_SEC のどちらかを書け、上の層が勝つ
  INTERVAL_SEC=$(interval_of conf "${INTERVAL_MIN:-}" "${INTERVAL_SEC:-}") || exit 2
  local iv
  iv=$(interval_of settings "$S_INTERVAL_MIN" "$S_INTERVAL_SEC") || exit 2
  INTERVAL_SEC=${iv:-$INTERVAL_SEC}
  DAYS=${S_DAYS:-${DAYS:-}}
  ENABLED=${S_ENABLED:-${ENABLED:-1}}
  [[ "$ENABLED" =~ ^[01]$ ]] || die "$JOB: ENABLED は 0 か 1"
  # 一時的な上書き: SCHED_WINDOW / SCHED_START / SCHED_END / SCHED_INTERVAL_MIN / SCHED_INTERVAL_SEC
  if [ -n "${SCHED_WINDOW:-}" ]; then
    [[ "$SCHED_WINDOW" =~ ^([0-9:]+)-([0-9:]+)$ ]] || die "SCHED_WINDOW は HH:MM-HH:MM"
    START=${BASH_REMATCH[1]}; END=${BASH_REMATCH[2]}
  fi
  START=${SCHED_START:-${START:-}}; END=${SCHED_END:-${END:-}}
  iv=$(interval_of "SCHED_*" "${SCHED_INTERVAL_MIN:-}" "${SCHED_INTERVAL_SEC:-}") || exit 2
  INTERVAL_SEC=${iv:-$INTERVAL_SEC}
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
  [ -n "$INTERVAL_SEC" ] || die "$JOB: 間隔が未設定(INTERVAL_MIN か INTERVAL_SEC)"
  # 分で割り切れるときだけ INTERVAL_MIN も入れる(表示・互換用)
  if ((INTERVAL_SEC % 60 == 0)); then INTERVAL_MIN=$((INTERVAL_SEC / 60)); else INTERVAL_MIN=""; fi
  [[ "$WINDOW" =~ ^([0-9:]+)-([0-9:]+)$ ]] || die "$JOB: WINDOW は HH:MM-HH:MM"
  # 窓はその日の 0 時からの秒(両端を含む)
  WIN_START=$(hms_to_sec "${BASH_REMATCH[1]}") || exit 2
  WIN_END=$(hms_to_sec "${BASH_REMATCH[2]}" end) || exit 2
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
