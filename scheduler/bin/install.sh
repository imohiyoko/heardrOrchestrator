#!/bin/bash
# 使い方: install.sh {install|uninstall|status} <job>
set -eu
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cmd="${1:-}"; load_job "${2:-}"
LABEL="local.herdr-sched-$JOB"
SRC="$SCHED_ROOT/generated/$LABEL.plist"
DST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
case "$cmd" in
  install)
    [ -f "$SRC" ] || die "$SRC がない。先に bin/gen-plist.sh $JOB"
    cp "$SRC" "$DST"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true   # 再登録を許す
    launchctl bootstrap "$DOMAIN" "$DST"
    echo "installed: $LABEL" ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || echo "(未登録だった)"
    rm -f "$DST"
    echo "uninstalled: $LABEL" ;;
  status)
    launchctl print "$DOMAIN/$LABEL" 2>&1 | head -30 || true ;;
  *) die "使い方: install.sh {install|uninstall|status} <job>" ;;
esac
