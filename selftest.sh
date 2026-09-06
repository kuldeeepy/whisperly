#!/bin/sh
# selftest.sh — exercises the whole chain without touching the keyboard, by
# playing a known sample through the speakers for the mic to pick up.
#
# Diagnoses the common failure (no Microphone grant for Hammerspoon) directly,
# instead of leaving you with a silent no-op.

set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
SAMPLE=${FLOW_SAMPLE:-$HOME/.voicemode/services/whisper/samples/jfk.wav}
WAV=/tmp/flow/selftest.wav
PORT=${FLOW_PORT:-2032}

# `hs -c` can block forever when the message port is busy; never wait on it.
hs_run() { ( hs -c "$1" >/dev/null 2>&1 ) & sleep "${2:-2}"; pkill -f "hs -c" 2>/dev/null || true; }

printf '==> whisper server\n'
curl -sf --max-time 2 "http://127.0.0.1:$PORT/" >/dev/null \
  && echo "    up on port $PORT" \
  || { echo "    DOWN — run ./install.sh" >&2; exit 1; }

printf '==> transcription (warm latency)\n'
START=$(python3 -c 'import time;print(time.time())')
TEXT=$("$ROOT/bin/flow-stt" "$SAMPLE")
python3 -c "import time;print(f'    {time.time()-$START:.2f}s')"
echo "    \"$(echo "$TEXT" | cut -c1-60)...\""

printf '==> microphone via Hammerspoon\n'
mkdir -p /tmp/flow; rm -f "$WAV"
VOL=$(osascript -e 'output volume of (get volume settings)')
osascript -e 'set volume output volume 55' >/dev/null

hs_run "SELFTEST = hs.task.new('$ROOT/bin/flowrec', nil, {'$WAV'}); SELFTEST:start()" 1
afplay "$SAMPLE"
hs_run "SELFTEST:terminate()" 2
osascript -e "set volume output volume $VOL" >/dev/null

python3 - "$WAV" <<'EOF'
import struct, sys, wave, os
path = sys.argv[1]
if not os.path.exists(path):
    sys.exit("    FAIL: recorder wrote no file")
with wave.open(path) as w:
    frames = w.getnframes()
    samples = struct.unpack(f"<{frames}h", w.readframes(frames)) if frames else ()
rms = (sum(s * s for s in samples) / len(samples)) ** 0.5 if samples else 0
print(f"    {frames / 16000:.2f}s captured, rms={rms:.0f}")
if rms < 30:
    sys.exit("    FAIL: silent — grant Hammerspoon Microphone access in "
             "System Settings > Privacy & Security, then Reload Config")
print("    OK")
EOF

printf '==> end-to-end\n'
echo "    \"$("$ROOT/bin/flow-stt" "$WAV" | cut -c1-70)\""
rm -f "$WAV"
echo "PASS"
