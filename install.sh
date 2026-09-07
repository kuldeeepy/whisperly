#!/bin/sh
# Builds the recorder, starts whisper, and hooks everything into Hammerspoon.
# Safe to run again after pulling changes.

set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
# Look in the usual places, or set WHISPERLY_WHISPER_DIR yourself.
find_whisper() {
  for dir in "$HOME/whisper.cpp" "$HOME/src/whisper.cpp" \
             "$HOME/.voicemode/services/whisper" "/opt/whisper.cpp"; do
    [ -x "$dir/build/bin/whisper-server" ] && { echo "$dir"; return; }
  done
  echo "$HOME/whisper.cpp"   # so the error message names something sensible
}
WHISPER_DIR=${WHISPERLY_WHISPER_DIR:-$(find_whisper)}
PORT=${WHISPERLY_PORT:-2032}
SCRATCH=${WHISPERLY_SCRATCH:-/tmp/whisperly}
LOG_DIR=$HOME/.local/state/whisperly
LABEL=com.whisperly.whisper
AGENT=$HOME/Library/LaunchAgents/$LABEL.plist
HS_DIR=$HOME/.hammerspoon

step() { printf '\033[1m==>\033[0m %s\n' "$1"; }

step "Checking what we need"
[ -x "$WHISPER_DIR/build/bin/whisper-server" ] || {
  echo "  can't find a whisper.cpp build (looked in $WHISPER_DIR)" >&2
  echo "  see 'Setting it up' in the README, or set WHISPERLY_WHISPER_DIR" >&2
  exit 1
}
[ -f "$WHISPER_DIR/models/ggml-large-v3-turbo.bin" ] || {
  echo "  can't find the model at $WHISPER_DIR/models/ggml-large-v3-turbo.bin" >&2
  echo "  get it with: $WHISPER_DIR/models/download-ggml-model.sh large-v3-turbo" >&2
  exit 1
}
command -v jq >/dev/null || { echo "  jq is missing: brew install jq" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "  swiftc is missing: xcode-select --install" >&2; exit 1; }

step "Building the recorder"
swiftc -O -o "$ROOT/bin/recorder" "$ROOT/src/recorder.swift"
chmod +x "$ROOT/bin/transcribe"

step "Starting whisper on port $PORT"
mkdir -p "$LOG_DIR" "$(dirname "$AGENT")"
sed -e "s|__WHISPER_DIR__|$WHISPER_DIR|g" \
    -e "s|__LOG_DIR__|$LOG_DIR|g" \
    -e "s|__PORT__|$PORT|g" \
    "$ROOT/launchd/$LABEL.plist" > "$AGENT"

# bootout returns before the job is really gone, so wait for it or the
# bootstrap below races it and fails with "Input/output error".
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
i=0
while launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 40 ] || { echo "  the old service would not stop" >&2; exit 1; }
  sleep 0.25
done
launchctl bootstrap "gui/$(id -u)" "$AGENT"

step "Waiting for the model to load"
i=0
until curl -sf --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { echo "  it never came up, see $LOG_DIR/whisper.err.log" >&2; exit 1; }
  sleep 0.5
done
echo "  ready on http://127.0.0.1:$PORT"

step "Hooking into Hammerspoon"
mkdir -p "$HS_DIR"
ln -sf "$ROOT/hammerspoon/whisperly.lua" "$HS_DIR/whisperly.lua"
ln -sf "$ROOT/hammerspoon/whisperly_hud.lua" "$HS_DIR/whisperly_hud.lua"

# Generated, not checked in, so the repo works from wherever you cloned it.
cat > "$HS_DIR/whisperly_paths.lua" <<EOF
-- Written by install.sh. Edit install.sh, not this.
return {
  root = "$ROOT",
  scratch = "$SCRATCH",
}
EOF

if ! grep -q 'require("whisperly")' "$HS_DIR/init.lua" 2>/dev/null; then
  printf '\n-- Whisperly: dictation\nrequire("whisperly")\n' >> "$HS_DIR/init.lua"
  echo "  added require(\"whisperly\") to init.lua"
else
  echo "  init.lua already loads it"
fi

cat <<EOF

Done. Two things left that only you can do:

  1. Hammerspoon menu bar icon -> Reload Config
  2. System Settings -> Privacy & Security, give Hammerspoon:
       Microphone
       Accessibility

The microphone one is easy to miss. Without it you get silence and no error,
because a helper started by Hammerspoon never raises its own prompt.
Run ./selftest.sh and it will tell you if that is what happened.

Then hold fn and talk.
EOF
