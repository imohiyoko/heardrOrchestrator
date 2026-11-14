#!/bin/bash
# 使い方: bin/gen-plist.sh   -> generated/local.herdr-webui.plist を生成して lint する。
# TB_INSTANCE があれば local.herdr-<instance>-webui(複数セッションを別 checkout で動かすとき)。
# HERDR_SESSION / TB_UI_PORT が設定されていれば plist の環境変数に渡す(未設定なら何も足さない)。
# launchctl への登録はしない(人が行う。README 参照)。
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../../lib/herdr-env.sh
source "$ROOT/../lib/herdr-env.sh"
LABEL="$(herdr_label_prefix)webui" || exit 2
EXTRA_ENV=""
for v in HERDR_SESSION TB_UI_PORT; do
  [ -n "${!v:-}" ] || continue
  herdr_plist_value_ok "${!v}" || { echo "error: $v は英数字と . _ - だけ: ${!v}" >&2; exit 2; }
  [ "$v" != TB_UI_PORT ] || [[ ${!v} =~ ^[0-9]{1,5}$ ]] || { echo "error: TB_UI_PORT は数字: ${!v}" >&2; exit 2; }
  EXTRA_ENV="$EXTRA_ENV    <key>$v</key>
    <string>${!v}</string>
"
done
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
$EXTRA_ENV  </dict>
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
