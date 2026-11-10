#!/bin/bash
# 使い方: gen-plist.sh <job>   -> generated/local.herdr-sched-<job>.plist
# plist は毎分起動するだけ(StartCalendarInterval の空 dict = 毎分)。時間帯・間隔は tick.sh が実行時に判定するので、
# conf や settings を変えても作り直さなくてよい。
set -eu
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_job "${1:-}"
OUT_DIR="${OUT_DIR:-$SCHED_ROOT/generated}"

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
  <dict/>
HDR
cat <<FTR
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd-$JOB.out</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd-$JOB.err</string>
</dict>
</plist>
FTR
} >"$OUT"
if command -v plutil >/dev/null; then plutil -lint "$OUT" >/dev/null; fi   # macOS 以外(テスト)では lint を省く
echo "$OUT (毎分起動。間隔 $(interval_label) / $WINDOW / $DAYS は tick.sh が判定)"
