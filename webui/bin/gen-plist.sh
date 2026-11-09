#!/bin/bash
# 使い方: bin/gen-plist.sh   -> generated/local.herdr-webui.plist を生成して lint する。
# launchctl への登録はしない(人が行う。README 参照)。
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="local.herdr-webui"
OUT_DIR="${OUT_DIR:-$ROOT/generated}"
LOG_DIR="$ROOT/logs"
PY="${PYTHON3:-$(command -v python3)}"
mkdir -p "$OUT_DIR" "$LOG_DIR"
OUT="$OUT_DIR/$LABEL.plist"
cat >"$OUT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$ROOT/server.py</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$ROOT</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/launchd-webui.out</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/launchd-webui.err</string>
</dict>
</plist>
PLIST
plutil -lint "$OUT" >/dev/null
echo "$OUT"
echo "登録は人が行う(このスクリプトは行わない)。手順は README の「常駐」を参照"
