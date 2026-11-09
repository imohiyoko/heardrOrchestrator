#!/bin/bash
# 使い方: gen-plist.sh <job>   -> generated/local.herdr-sched-<job>.plist
set -eu
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_job "${1:-}"
OUT_DIR="${OUT_DIR:-$SCHED_ROOT/generated}"

# StartCalendarInterval は OS のローカル時刻で動く。ジョブの TZ と違うと窓がずれるので拒否する。
[ "$(date +%z)" = "$(TZ="$TZ" date +%z)" ] || die "$JOB: TZ=$TZ がシステムのタイムゾーンと異なる(plist は OS 時刻基準)"

mkdir -p "$OUT_DIR" "$LOG_DIR"
OUT="$OUT_DIR/local.herdr-sched-$JOB.plist"
{
cat <<HDR
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.herdr-sched-$JOB</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCHED_ROOT/bin/tick.sh</string>
    <string>$JOB</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <array>
HDR
for ((m = WIN_START; m <= WIN_END; m += INTERVAL_MIN)); do
  printf '    <dict><key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer></dict>\n' $((m / 60)) $((m % 60))
done
cat <<FTR
  </array>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd-$JOB.out</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd-$JOB.err</string>
</dict>
</plist>
FTR
} >"$OUT"
plutil -lint "$OUT" >/dev/null
echo "$OUT ($(grep -c '<key>Hour</key>' "$OUT") entries)"
