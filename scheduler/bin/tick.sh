#!/bin/bash
# 使い方: tick.sh <job>
#   NOW="YYYY-MM-DD HH:MM"  時刻を差し替える(ジョブの TZ での現地時刻)
#   DRY_RUN=1               herdr を呼ばず、判定結果を stdout に JSON で出す(ログは書かない)
#   FAKE_STATE=<state>      DRY_RUN 時に TARGET の状態を仮定する(テスト用)
# launchd は毎分起動する。実行するかどうか(曜日・時間帯・間隔・一時停止)はここで判定するので、
# 間隔や時間帯を変えても plist を作り直す必要はない。対象外の回は(DRY_RUN 以外では)何も記録しない。
set -u
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_job "${1:-}"

DRY_RUN="${DRY_RUN:-0}"
[ "$DRY_RUN" = 1 ] || mkdir -p "$LOG_DIR"
PANE=""; STATE=""; EXITC=""; OUT_S=""; ERR_S=""

# 現地時刻(判定用)
if [ -n "${NOW:-}" ]; then
  AT="${NOW/T/ }"; AT="${AT:0:16}"
else
  AT="$(date '+%Y-%m-%d %H:%M')"
fi
dow=$(date -j -f '%Y-%m-%d %H:%M' "$AT" '+%u' 2>/dev/null || date -d "$AT" '+%u' 2>/dev/null) || die "NOW を解釈できない: ${NOW:-}"
cur_min=$(hm_to_min "${AT:11:5}")

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
fail() { emit failed "$1"; exit 1; }

# 対象外の回: DRY_RUN では理由を出し、通常は記録せずに終わる(毎分起動のためログを埋めない)
quiet_skip() { [ "$DRY_RUN" = 1 ] && emit "$1" "$2"; exit 0; }

# 1. 曜日・時間帯・間隔・一時停止
case " $(days_to_nums) " in *" $dow "*) ;; *) quiet_skip skipped_window "day $dow not in DAYS ($DAYS)" ;; esac
if ((cur_min < WIN_START || cur_min > WIN_END)); then
  quiet_skip skipped_window "${AT:11:5} outside $WINDOW"
fi
(((cur_min - WIN_START) % INTERVAL_MIN == 0)) || quiet_skip skipped_interval "${AT:11:5} not on the ${INTERVAL_MIN}-min grid from $START"
[ "$ENABLED" = 1 ] || { emit skipped_disabled "paused (ENABLED=0)"; exit 0; }

# COMMAND 型: agent の状態を見ずにコマンドを実行する
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill -KILL "$1" 2>/dev/null; }
if [ -n "${COMMAND:-}" ]; then
  if [ "$DRY_RUN" = 1 ]; then emit ran "dry-run: would run command (timeout ${COMMAND_TIMEOUT}s)"; exit 0; fi
  LOCK="$LOG_DIR/$JOB.lock.d"
  if ! mkdir "$LOCK" 2>/dev/null; then
    lpid=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$lpid" ] && kill -0 "$lpid" 2>/dev/null; then emit skipped_locked "previous run still active (pid $lpid)"; exit 0; fi
    rm -rf "$LOCK"   # 異常終了で残った stale lock
    mkdir "$LOCK" 2>/dev/null || { emit skipped_locked "lock race"; exit 0; }
  fi
  echo $$ >"$LOCK/pid"
  OUTF=$(mktemp); ERRF=$(mktemp)
  trap 'rm -rf "$LOCK" "$OUTF" "$ERRF"' EXIT
  /bin/bash -c "$COMMAND" >"$OUTF" 2>"$ERRF" </dev/null &
  cpid=$!; waited=0; timed_out=0
  while kill -0 "$cpid" 2>/dev/null; do
    if ((waited >= COMMAND_TIMEOUT * 10)); then timed_out=1; kill_tree "$cpid"; break; fi
    sleep 0.1; waited=$((waited + 1))
  done
  wait "$cpid" 2>/dev/null; EXITC=$?
  OUT_S=$(head -c 500 "$OUTF" | tr -d '\000'); ERR_S=$(head -c 500 "$ERRF" | tr -d '\000')
  if ((timed_out)); then EXITC=124; emit failed "timeout after ${COMMAND_TIMEOUT}s"; exit 1; fi
  if [ "$EXITC" = 0 ]; then emit ran "exit 0"; else emit failed "exit $EXITC"; exit 1; fi
  exit 0
fi

# 本文(送信前に検証)
if [ -n "${PROMPT_FILE:-}" ]; then
  [ -r "$PROMPT_FILE" ] || fail "PROMPT_FILE を読めない: $PROMPT_FILE"
  TEXT="$(cat "$PROMPT_FILE")"
else
  TEXT="$PROMPT"
fi
[ -n "$TEXT" ] || fail "本文が空"
case "$TEXT" in /* | -*) fail "本文の先頭が / か - (スラッシュコマンド/オプションと解釈される)" ;; esac

# 2. 状態取得
if [ "$DRY_RUN" = 1 ]; then
  STATE="${FAKE_STATE:-}"
else
  out=$("$HERDR" agent list 2>&1) || fail "herdr agent list 失敗: ${out:0:300}"
  sel=$(jq -r --arg n "$TARGET" '[.result.agents[]? | select(.name==$n)]
        | if length==1 then "\(.[0].pane_id) \(.[0].agent_status)" else "count=\(length)" end' <<<"$out" 2>&1) \
    || fail "agent list の解析失敗: ${sel:0:300}"
  case "$sel" in count=*) fail "TARGET '$TARGET' が一意に解決できない ($sel)" ;; esac
  PANE="${sel%% *}"; STATE="${sel#* }"
fi

for s in $SKIP_IF; do
  [ "$STATE" = "$s" ] && { emit skipped_state "state=$STATE matches SKIP_IF"; exit 0; }
done

# 3. idle / done のときだけ送る
if [ "$DRY_RUN" = 1 ] && [ -z "$STATE" ]; then
  emit sent "dry-run: state not checked, would send"; exit 0
fi
case "$STATE" in
  idle | done) ;;
  *) emit skipped_state "state=$STATE is not idle/done"; exit 0 ;;
esac
if [ "$DRY_RUN" = 1 ]; then emit sent "dry-run: would send to $TARGET"; exit 0; fi

out=$("$HERDR" agent prompt "$PANE" "$TEXT" 2>&1) || fail "herdr agent prompt 失敗: ${out:0:300}"
emit sent "prompt submitted"
