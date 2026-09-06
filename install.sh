#!/bin/sh
# install.sh — build the recorder, install the warm whisper agent, wire up Hammerspoon.
# Idempotent: safe to re-run after pulling changes.

set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
WHISPER_DIR=${FLOW_WHISPER_DIR:-$HOME/.voicemode/services/whisper}
PORT=${FLOW_PORT:-2032}
LOG_DIR=$HOME/.local/state/flow
AGENT=$HOME/Library/LaunchAgents/cc.kuldeep.flow.whisper.plist
HS_DIR=$HOME/.hammerspoon

step() { printf '\033[1m==>\033[0m %s\n' "$1"; }

step "Checking prerequisites"
[ -x "$WHISPER_DIR/build/bin/whisper-server" ] || {
  echo "  missing: $WHISPER_DIR/build/bin/whisper-server" >&2
  echo "  set FLOW_WHISPER_DIR to your whisper.cpp build" >&2
  exit 1
}
[ -f "$WHISPER_DIR/models/ggml-large-v3-turbo.bin" ] || {
  echo "  missing model: $WHISPER_DIR/models/ggml-large-v3-turbo.bin" >&2
  exit 1
}
command -v jq >/dev/null || { echo "  missing: jq" >&2; exit 1; }

step "Building flowrec"
swiftc -O -o "$ROOT/bin/flowrec" "$ROOT/src/flowrec.swift"
chmod +x "$ROOT/bin/flow-stt"

step "Installing whisper agent on port $PORT"
mkdir -p "$LOG_DIR" "$(dirname "$AGENT")"
sed -e "s|__WHISPER_DIR__|$WHISPER_DIR|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    -e "s|__PORT__|$PORT|g" \
    "$ROOT/launchd/cc.kuldeep.flow.whisper.plist" > "$AGENT"

launchctl bootout "gui/$(id -u)/cc.kuldeep.flow.whisper" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"

step "Waiting for the model to load"
i=0
until curl -sf --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { echo "  server did not come up; see $LOG_DIR/whisper.err.log" >&2; exit 1; }
  sleep 0.5
done
echo "  ready on http://127.0.0.1:$PORT"

step "Wiring up Hammerspoon"
mkdir -p "$HS_DIR"
ln -sf "$ROOT/hammerspoon/flow.lua" "$HS_DIR/flow.lua"
ln -sf "$ROOT/hammerspoon/flow_hud.lua" "$HS_DIR/flow_hud.lua"
if ! grep -q 'require("flow")' "$HS_DIR/init.lua" 2>/dev/null; then
  printf '\n-- Flow: push-to-talk dictation (~/Others/flow)\nrequire("flow")\n' >> "$HS_DIR/init.lua"
  echo "  added require(\"flow\") to init.lua"
else
  echo "  init.lua already requires flow"
fi

cat <<EOF

Done. Two things left, both manual:

  1. Reload Hammerspoon (menu bar icon -> Reload Config).
  2. Grant System Settings -> Privacy & Security:
       Microphone    -> Hammerspoon
       Accessibility -> Hammerspoon

Then hold Right Command, speak, release.
EOF
