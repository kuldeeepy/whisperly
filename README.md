# flow

Push-to-talk dictation. Hold **Right ⌘**, speak, release — the text is pasted at
the cursor. Runs entirely on this machine.

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

- **Takes under 0.4 s are discarded** as accidental taps.
- **Any other keypress while Right ⌘ is held cancels the take**, so Right ⌘
  still works normally as a modifier for shortcuts.
- The HUD only appears once the mic is genuinely delivering samples, so it is
  real feedback rather than an optimistic guess.
- Whisper's stock near-silence outputs ("Thank you.", "[BLANK_AUDIO]", …) are
  filtered in `config.hallucinations`.
- The clipboard is saved before pasting and restored 150 ms later.

## Config

Top of `hammerspoon/flow.lua`. `key = 54` is Right ⌘; `61` is Right ⌥.

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
