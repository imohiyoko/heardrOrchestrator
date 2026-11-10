#!/bin/bash
# 使い方: tick.sh <job>
#   NOW="YYYY-MM-DD HH:MM[:SS]"  時刻を差し替える(ジョブの TZ での現地時刻)。待たずに判定する
#                           秒まで書くとその 1 秒だけ、分までならその分(00〜59 秒)に入る回をすべて判定する
#   DRY_RUN=1               herdr を呼ばず、判定結果を stdout に JSON で出す(ログは書かない)
#   FAKE_STATE=<state>      DRY_RUN 時に TARGET の状態を仮定する(テスト用)
# launchd は毎分起動する。実行するかどうか(曜日・時間帯・間隔・一時停止)はここで判定するので、
# 間隔や時間帯を変えても plist を作り直す必要はない。対象外の回は(DRY_RUN 以外では)何も記録しない。
# 判定は秒単位。起動した分の中に刻みの回が複数ある(INTERVAL_SEC が 60 未満など)ときは、その時刻まで待って順に実行する。
set -u
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_job "${1:-}"

DRY_RUN="${DRY_RUN:-0}"
[ "$DRY_RUN" = 1 ] || mkdir -p "$LOG_DIR"
PANE=""; STATE=""; EXITC=""; OUT_S=""; ERR_S=""

# 時刻の変換(BSD date / GNU date の両方)
if date -d @0 +%s >/dev/null 2>&1; then
  to_epoch() { date -d "$1" +%s 2>/dev/null; }
  fmt_epoch() { date -d "@$1" "+$2"; }
else
  to_epoch() { date -j -f '%Y-%m-%d %H:%M:%S' "$1" +%s 2>/dev/null; }
  fmt_epoch() { date -r "$1" "+$2"; }
fi

# 判定する範囲 [SLOT_LO, SLOT_HI](epoch 秒)。通常は今の分の 00〜59 秒
FAKED=0
if [ -n "${NOW:-}" ]; then
  FAKED=1; n="${NOW/T/ }"
  if [[ "$n" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
    NOW_E=$(to_epoch "${BASH_REMATCH[1]}") || die "NOW を解釈できない: $NOW"
    SLOT_LO=$NOW_E; SLOT_HI=$NOW_E
  elif [[ "$n" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2})$ ]]; then
    NOW_E=$(to_epoch "${BASH_REMATCH[1]}:00") || die "NOW を解釈できない: $NOW"
    SLOT_LO=$NOW_E; SLOT_HI=$((NOW_E + 59))
  else
    die "NOW を解釈できない: $NOW (YYYY-MM-DD HH:MM[:SS])"
  fi
  [ -n "$NOW_E" ] || die "NOW を解釈できない: $NOW"
else
  NOW_E=$(date +%s)
  SLOT_LO=$((NOW_E - NOW_E % 60)); SLOT_HI=$((SLOT_LO + 59))
fi
read -r DAY dow HH MM SS <<<"$(fmt_epoch "$SLOT_LO" '%Y-%m-%d %u %H %M %S')"
SOD_LO=$((10#$HH * 3600 + 10#$MM * 60 + 10#$SS)); SOD_HI=$((SOD_LO + SLOT_HI - SLOT_LO))
AT="$DAY $HH:$MM:$SS"
sod_label() { printf '%02d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }

emit() { # action reason
  local line
  line=$(jq -nc --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" --arg job "$JOB" --arg action "$1" \
    --arg reason "$2" --arg at "$AT" --arg target "$TARGET" --arg pane "$PANE" --arg state "$STATE" \
    --arg exitc "$EXITC" --arg out "$OUT_S" --arg err "$ERR_S" \
    --argjson dry "$([ "$DRY_RUN" = 1 ] && echo true || echo false)" \
    '{ts:$ts,job:$job,action:$action,reason:$reason,at:$at}
     + (if $target!="" then {target:$target} else {} end)
     + (if $pane!="" then {pane:$pane} else {} end)
     + (if $state!="" then {state:$state} else {} end)
     + (if $exitc!="" then {exit:($exitc|tonumber),stdout:$out,stderr:$err} else {} end)
     + (if $dry then {dry_run:true} else {} end)')
  if [ "$DRY_RUN" = 1 ]; then echo "$line"; else echo "$line" >>"$LOG_DIR/$JOB.log"; fi
}
fail() { emit failed "$1"; return 1; }

# 対象外の回: DRY_RUN では理由を出し、通常は記録せずに終わる(毎分起動のためログを埋めない)
quiet_skip() { [ "$DRY_RUN" = 1 ] && emit "$1" "$2"; exit 0; }

# 1. 曜日・時間帯・間隔 -> この範囲で実行する回(その日の 0 時からの秒)
case " $(days_to_nums) " in *" $dow "*) ;; *) quiet_skip skipped_window "day $dow not in DAYS ($DAYS)" ;; esac
lo=$SOD_LO; hi=$SOD_HI
((lo < WIN_START)) && lo=$WIN_START
((hi > WIN_END)) && hi=$WIN_END
if ((lo > hi)); then
  quiet_skip skipped_window "$(sod_label "$SOD_LO") outside $WINDOW"
fi
DUE=()
first=$((WIN_START + (lo - WIN_START + INTERVAL_SEC - 1) / INTERVAL_SEC * INTERVAL_SEC))
for ((p = first; p <= hi; p += INTERVAL_SEC)); do DUE+=($((SLOT_LO + p - SOD_LO))); done
((${#DUE[@]})) || quiet_skip skipped_interval "$(sod_label "$SOD_LO") not on the $(interval_label)-grid from $START"
[ "$ENABLED" = 1 ] || { AT=$(fmt_epoch "${DUE[0]}" '%Y-%m-%d %H:%M:%S'); emit skipped_disabled "paused (ENABLED=0)"; exit 0; }

# 実際に起動された回: 過ぎてしまった回は最後の 1 回にまとめる(launchd の起動遅れ・スリープ復帰で取りこぼさず、まとめて何度も送らない)
if ((!FAKED)); then
  past=""; future=()
  for p in "${DUE[@]}"; do if ((p <= NOW_E)); then past=$p; else future+=("$p"); fi; done
  DUE=(${past:+"$past"} ${future[@]+"${future[@]}"})   # macOS の bash 3.2 + set -u では空配列の展開に +"" が要る
fi

kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill -KILL "$1" 2>/dev/null; }
LOCK="$LOG_DIR/$JOB.lock.d"; OUTF=""; ERRF=""; HAVE_LOCK=0
cleanup() { ((HAVE_LOCK)) && rm -rf "$LOCK"; rm -f "$OUTF" "$ERRF"; HAVE_LOCK=0; }
trap cleanup EXIT

# COMMAND 型: agent の状態を見ずにコマンドを実行する
run_command() {
  if [ "$DRY_RUN" = 1 ]; then emit ran "dry-run: would run command (timeout ${COMMAND_TIMEOUT}s)"; return 0; fi
  if ! mkdir "$LOCK" 2>/dev/null; then
    local lpid; lpid=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then emit skipped_locked "previous run still active (pid $lpid)"; return 0; fi
    rm -rf "$LOCK"   # 異常終了で残った stale lock
    mkdir "$LOCK" 2>/dev/null || { emit skipped_locked "lock race"; return 0; }
  fi
  HAVE_LOCK=1
  echo $$ >"$LOCK/pid"
  OUTF=$(mktemp); ERRF=$(mktemp)
  /bin/bash -c "$COMMAND" >"$OUTF" 2>"$ERRF" </dev/null &
  local cpid=$! waited=0 timed_out=0 rc=0
  while kill -0 "$cpid" 2>/dev/null; do
    if ((waited >= COMMAND_TIMEOUT * 10)); then timed_out=1; kill_tree "$cpid"; break; fi
    sleep 0.1; waited=$((waited + 1))
  done
  wait "$cpid" 2>/dev/null; EXITC=$?
  OUT_S=$(head -c 500 "$OUTF" | tr -d '\000'); ERR_S=$(head -c 500 "$ERRF" | tr -d '\000')
  cleanup
  if ((timed_out)); then EXITC=124; emit failed "timeout after ${COMMAND_TIMEOUT}s"; return 1; fi
  if [ "$EXITC" = 0 ]; then emit ran "exit 0"; else emit failed "exit $EXITC"; rc=1; fi
  return $rc
}

# プロンプト型: agent が idle / done のときだけ本文を送る
run_prompt() {
  local TEXT out sel s rc
  # 本文(送信前に検証)
  if [ -n "${PROMPT_FILE:-}" ]; then
    [ -r "$PROMPT_FILE" ] || { fail "PROMPT_FILE を読めない: $PROMPT_FILE"; return 1; }
    TEXT="$(cat "$PROMPT_FILE")"
  else
    TEXT="$PROMPT"
  fi
  [ -n "$TEXT" ] || { fail "本文が空"; return 1; }
  case "$TEXT" in /* | -*) fail "本文の先頭が / か - (スラッシュコマンド/オプションと解釈される)"; return 1 ;; esac

  # 状態取得
  if [ "$DRY_RUN" = 1 ]; then
    STATE="${FAKE_STATE:-}"
  else
    out=$("$HERDR" agent list 2>&1) || { fail "herdr agent list 失敗: ${out:0:300}"; return 1; }
    sel=$(jq -r --arg n "$TARGET" '[.result.agents[]? | select(.name==$n)]
          | if length==1 then "\(.[0].pane_id) \(.[0].agent_status)" else "count=\(length)" end' <<<"$out" 2>&1) \
      || { fail "agent list の解析失敗: ${sel:0:300}"; return 1; }
    case "$sel" in count=*) fail "TARGET '$TARGET' が一意に解決できない ($sel)"; return 1 ;; esac
    PANE="${sel%% *}"; STATE="${sel#* }"
  fi

  for s in $SKIP_IF; do
    [ "$STATE" = "$s" ] && { emit skipped_state "state=$STATE matches SKIP_IF"; return 0; }
  done

  # idle / done のときだけ送る
  if [ "$DRY_RUN" = 1 ] && [ -z "$STATE" ]; then
    emit sent "dry-run: state not checked, would send"; return 0
  fi
  case "$STATE" in
    idle | done) ;;
    *) emit skipped_state "state=$STATE is not idle/done"; return 0 ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then emit sent "dry-run: would send to $TARGET"; return 0; fi

  # 送信は tb を通す(送ったものは taskboard の messages に kind=scheduler で残る)
  TB="${TB_BIN:-$SCHED_ROOT/../taskboard/bin/tb}"
  out=$(env -u HERDR_PANE_ID HERDR_BIN="$HERDR" bash "$TB" system-send "$TARGET" --text "$TEXT" --job "$JOB" 2>&1); rc=$?
  case $rc in
    0) emit sent "prompt submitted (via tb)" ;;
    10) emit skipped_state "target became busy before sending (tb)" ;;
    *) fail "tb system-send 失敗(exit $rc): ${out:0:300}"; return 1 ;;
  esac
}

# 2. 刻みの回ごとに実行(未来の回はその時刻まで待つ)
RC=0; n=0
for p in "${DUE[@]}"; do
  if ((!FAKED)); then
    cur=$(date +%s)
    ((n > 0 && cur > SLOT_HI)) && break   # 前の回が長引いて分をまたいだら、残りは次の起動に任せる
    ((p > cur)) && sleep $((p - cur))
  fi
  n=$((n + 1))
  AT=$(fmt_epoch "$p" '%Y-%m-%d %H:%M:%S'); PANE=""; STATE=""; EXITC=""; OUT_S=""; ERR_S=""
  if [ -n "${COMMAND:-}" ]; then run_command || RC=1; else run_prompt || RC=1; fi
done
exit $RC
