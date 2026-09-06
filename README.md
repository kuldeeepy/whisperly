# flow

Local dictation, two ways:

- **Hold fn**, speak, **release** — for a quick line.
- **Double-tap fn**, speak, **tap fn** — hands-free, for anything longer.

Text is pasted at the cursor. Runs entirely on this machine.

    mic -> flowrec (16 kHz mono WAV) -> whisper-server (warm) -> paste

## Install

    ./install.sh

Then, both manual and required:

1. Hammerspoon menu bar icon -> **Reload Config**
2. System Settings -> Privacy & Security:
   - **Microphone** -> add/enable **Hammerspoon**
   - **Accessibility** -> add/enable **Hammerspoon**

The microphone grant is the one that bites: a CLI child of Hammerspoon does not
raise its own prompt, so if the toggle is off the recorder silently produces a
0-frame file and nothing is pasted. `./selftest.sh` reports exactly this case.

## Measured on this machine (M4 Air, 16 GB)

| stage | cost |
|---|---|
| recorder startup (audio lost at head) | ~0.11 s |
| whisper `large-v3-turbo`, 11 s of audio, warm | **0.65 s** |
| whisper cold (model load + Core ML compile) | +1.0 s |

The warm server is the whole design. A cold start costs more than the
transcription itself, which is why `install.sh` installs a `KeepAlive` agent.

**Why not ffmpeg for capture:** `ffmpeg -f avfoundation` drops ~10% of the
stream continuously here — 0.41 s lost of 3 s, 1.50 s lost of 12 s — which
corrupts speech throughout the take. `flowrec` loses ~0.11 s at startup and
then nothing. That measurement is why `src/flowrec.swift` exists.

## Layout

    src/flowrec.swift      mic -> 16 kHz mono WAV; RMS on stdout for the meter
    bin/flow-stt           WAV -> transcript, via the whisper server
    hammerspoon/flow.lua   hotkey, state machine, HUD, paste
    launchd/*.plist        the warm whisper server (port 2032)
    selftest.sh            end-to-end check without touching the keyboard

## Behaviour

- **Hold fn past `tapSeconds`** and recording starts; releasing transcribes.
- **Double-tap fn** starts a hands-free take; **a single tap** ends it.
- **Esc** cancels a take without transcribing.
- A **lone fn tap does nothing** — it takes two, inside `doubleTapGap`.
- **fn held as a modifier is never a tap**, so fn+Space, fn+arrows and the
  F-key row all behave normally. The existing fn+Space quick-capture binding is
  untouched. If a chord starts mid-hold, the take is dropped.
- The fn/globe key reports **63** in `flagsChanged` but emits its own keyDown as
  **179**. Both are in `config.selfKeys` and neither counts as a chord partner —
  without that, every tap looks like a chord and double-tap never fires.
- **Takes under 0.4 s are discarded** as accidental taps.
- The HUD only appears once the mic is genuinely delivering samples, so it is
  real feedback rather than an optimistic guess.
- Whisper's stock near-silence outputs ("Thank you.", "[BLANK_AUDIO]", …) are
  filtered in `config.hallucinations`.
- The clipboard is saved before pasting and restored 150 ms later.

## What is kept

Nothing. No transcript is ever written to disk — not by flow, and not by the
whisper server, which logs only the filename, sample count and duration. The
Hammerspoon console records a character count, never the text.

Each recording lives in `/tmp/flow` (mode 0700) and is deleted as soon as it has
been transcribed. Any WAV still there at load was orphaned by a reload or crash
and is swept on startup.

The one moment the text is exposed is the ~150 ms it sits on the pasteboard for
the ⌘V. A clipboard manager would capture it in that window; none is running
here. There is no history, so there is also no undo and no way to recover a
take you have lost.

## Config

Top of `hammerspoon/flow.lua`:

- `key = 63` — fn. `54` is Right ⌘, `61` is Right ⌥.
- `tapSeconds = 0.4` — release sooner and it is a tap; hold longer and
  recording starts. Measured taps here run 0.09-0.13s, so there is plenty
  of headroom.
- `doubleTapGap = 0.6` — raise it if double-tap feels too strict.
- `debug = true` — logs every fn press duration, gap and chord key. This is
  what to reach for when a trigger misbehaves.

This relies on the fn key doing nothing system-wide
(`defaults read com.apple.HIToolbox AppleFnUsageType` -> `0`). If it is set to
show the emoji picker or start Apple's dictation, change it in
System Settings -> Keyboard -> "Press fn key to".

To save ~1.6 GB of RAM by reusing voicemode's whisper instead of flow's own:

    launchctl bootout gui/$(id -u)/cc.kuldeep.flow.whisper
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.voicemode.whisper.plist
    # then set FLOW_WHISPER_URL=http://127.0.0.1:2022 in bin/flow-stt

## Status

Phase 1: raw transcription pasted at the cursor. The LLM cleanup pass
(punctuation, fillers, app-aware tone, personal dictionary) is Phase 2 and
slots in between `flow-stt` and `paste`.

## Uninstall

    launchctl bootout gui/$(id -u)/cc.kuldeep.flow.whisper
    rm ~/Library/LaunchAgents/cc.kuldeep.flow.whisper.plist ~/.hammerspoon/flow.lua
    # remove the require("flow") line from ~/.hammerspoon/init.lua
