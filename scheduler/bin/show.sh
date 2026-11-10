#!/bin/bash
# 使い方: show.sh <job>   実際に効く設定(conf + settings + SCHED_*)を JSON 1 行で出す。Web UI が使う
# interval_sec は間隔(秒)。interval_min は 60 で割り切れるときだけ数値で、そうでなければ null
set -eu
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_job "${1:-}"
days_to_nums >/dev/null
jq -nc --arg job "$JOB" --arg kind "$([ -n "${COMMAND:-}" ] && echo command || echo prompt)" --arg target "${TARGET:-}" \
  --argjson interval "${INTERVAL_MIN:-null}" --argjson interval_sec "$INTERVAL_SEC" --arg start "$START" --arg end "$END" --arg days "$DAYS" \
  --argjson enabled "$ENABLED" --arg tz "$TZ" \
  --argjson overridden "$([ -e "$SETTINGS_DIR/$JOB.settings" ] && echo true || echo false)" \
  '{job:$job,kind:$kind,target:$target,interval_min:$interval,interval_sec:$interval_sec,start:$start,end:$end,days:$days,enabled:($enabled==1),tz:$tz,overridden:$overridden}'
