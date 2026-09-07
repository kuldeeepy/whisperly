#!/bin/sh
# Removes everything install.sh set up. Leaves the repo itself alone.

set -eu

LABEL=com.whisperly.whisper
HS_DIR=$HOME/.hammerspoon

echo "==> Stopping whisper"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> Unhooking from Hammerspoon"
rm -f "$HS_DIR/whisperly.lua" "$HS_DIR/whisperly_hud.lua" "$HS_DIR/whisperly_paths.lua"

echo "==> Clearing recordings and logs"
rm -rf "${WHISPERLY_SCRATCH:-/tmp/whisperly}" "$HOME/.local/state/whisperly"

cat <<EOF

Done. One line is left for you to delete by hand, so nothing else in your
config gets touched:

  require("whisperly")   in $HS_DIR/init.lua

Then reload Hammerspoon.
EOF
