# Whisperly

Dictation for macOS that runs entirely on your own machine.

Hold `fn`, talk, let go. The text appears wherever your cursor is, about
0.6 seconds later. Nothing is uploaded, there is no account, and there is
nothing to pay for.

I built this because I was paying for Wispr Flow and my laptop was already
sitting on a whisper model that could do the same job.

```
hold fn, speak, let go           text lands at your cursor
double-tap fn, speak, tap fn     same thing, hands free
Esc                              throw the take away
```

## How it works

Four small pieces, each doing one thing:

```
  fn key
    │
    ▼
  whisperly.lua ── watches the key, runs everything, pastes the result
    │
    ├──▶ recorder ────────▶ /tmp/whisperly/123.wav
    │      (Swift, 16 kHz mono, also reports how loud you are)
    │                                    │
    │                                    ▼
    │                          whisperly_hud.lua draws the waveform
    │
    └──▶ transcribe ──▶ whisper-server ──▶ "hello how are you"
           (curl)        (large-v3-turbo, kept running)
```

Then the text goes on the clipboard, `⌘V` is pressed for you, your old
clipboard is put back, and the recording is deleted.

The one thing that matters: **whisper is kept running.** Starting it costs
about a second, which is longer than transcribing usually takes. That is worth
1.7 GB of memory and it is the reason this feels instant.

## Speed

Measured on an M4 MacBook Air:

| you spoke for | transcription |
|---|---|
| 2s | 0.55s |
| 5s | 0.56s |
| 11s | 0.63s |

Nearly flat, because whisper always pads its input to a 30-second window. The
practical upshot: **say the whole thought in one go.** Five short takes cost
five times as much as one long one.

Full path from letting go of the key to seeing text is about **0.6s**. The
first take after a long idle is slower, around 1.4s, while the model is paged
back in.

## What it costs to run

| | |
|---|---|
| Memory | 1.7 GB, held so transcription stays fast |
| CPU, idle | 0.1% of one core |
| CPU, while you speak | 5.5% of one core |
| Disk | 336 KB, plus a model you likely already have |
| Money | nothing |

## Installing

You need macOS on Apple silicon, [Hammerspoon](https://www.hammerspoon.org),
`jq`, and a [whisper.cpp](https://github.com/ggerganov/whisper.cpp) build with
the `large-v3-turbo` model.

```sh
git clone https://github.com/kuldeeepy/whisperly
cd whisperly
./install.sh
```

Then two things the installer cannot do for you:

1. Hammerspoon menu bar icon → **Reload Config**
2. System Settings → Privacy & Security → give Hammerspoon **Microphone** and
   **Accessibility**

That microphone permission is the one that bites. Without it you get silence
and no error at all, because a helper started by Hammerspoon never raises its
own prompt. `./selftest.sh` checks for exactly this and says so plainly.

If your whisper build lives somewhere else:

```sh
WHISPERLY_WHISPER_DIR=/path/to/whisper.cpp ./install.sh
```

## Behaviour

- Takes under 0.4s are ignored, so a stray key press does nothing.
- A single `fn` tap does nothing. It takes two, close together.
- Holding `fn` as part of a shortcut never starts a take, so `fn`+Space,
  `fn`+arrows and the F-key row all still work.
- The pill only appears once the mic is really sending audio, so it is honest
  feedback rather than a guess. Wait for it before you speak.
- Whisper's usual inventions on silence ("Thank you.", "[BLANK_AUDIO]") are
  filtered out.
- A take stops on its own after two minutes.

## What is kept

Nothing. No transcript is written to disk, not by Whisperly and not by the
whisper server, which logs only file names and durations. The Hammerspoon
console shows a character count, never your words.

Recordings live in `/tmp/whisperly` (mode 0700) and are deleted the moment they
are transcribed. Anything left there by a crash is cleared at startup.

The one exposure is the ~150ms your text spends on the clipboard during the
paste. A clipboard manager would catch it in that window. There is no history,
so there is also no undo.

## Layout

```
src/recorder.swift          the recorder, source
bin/recorder                the recorder, built (not checked in)
bin/transcribe              sends a wav to whisper, prints the text
hammerspoon/whisperly.lua      key handling, state, pasting
hammerspoon/whisperly_hud.lua  the pill
launchd/                    keeps whisper running across reboots
install.sh / uninstall.sh
selftest.sh                 checks the whole chain, no keyboard needed
```

## Settings

Top of `hammerspoon/whisperly.lua`:

- `tapSeconds` (0.4) — let go before this and it counts as a tap; keep holding
  and recording starts
- `doubleTapGap` (0.6) — raise it if your second tap keeps getting missed
- `key` (63) — `fn`. Use 54 for right `⌘`, 61 for right `⌥`
- `debug` — logs every `fn` press timing. Reach for this first when a trigger
  misbehaves

The pill's size, position and colours are at the top of `whisperly_hud.lua`.

This assumes `fn` does nothing on its own
(`defaults read com.apple.HIToolbox AppleFnUsageType` → `0`). If yours opens
the emoji picker or Apple's dictation, change it under System Settings →
Keyboard → "Press fn key to".

## Notes from building it

Things that cost real time to work out, kept here so they are not
rediscovered:

**ffmpeg cannot record this.** `ffmpeg -f avfoundation` drops about 10% of the
audio continuously — 0.41s lost from 3s, 1.50s from 12s. Not just at the edges;
it mangles words all the way through. That is the whole reason there is a Swift
recorder.

**The `fn` key has two identities.** It reports keycode 63 when held, but sends
its own key press as **179**. Anything watching for "did you press another
key?" sees fn itself and gets confused. Double-tap silently never worked until
this was found, and synthetic test events do not reproduce it — only a real
finger does.

**A recorder can outlive its parent.** If Hammerspoon reloads mid-take the
recorder gets adopted by launchd, and without a watchdog it holds the mic open
forever and grows the file at 32 KB/s. It now exits when orphaned.

**One filled shape is slower than 18 rectangles.** Drawing the waveform as a
single path seemed obviously cheaper. Measured, it was worse — 0.47s of CPU
against 0.28s — because rebuilding the path every frame costs more than moving
the bars.

## Not done yet

The text is raw transcription. No filler removal, no reflowing, no personal
vocabulary. That is the next piece, and it slots in between `transcribe` and
the paste.

## Licence

MIT.
