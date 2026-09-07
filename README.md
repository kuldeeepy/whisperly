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
| Disk | 336 KB for Whisperly, 2.7 GB for the whisper model |
| Money | nothing |

## Setting it up

**You need:** a Mac with Apple silicon (M1, M2, M3 or M4 — check  → About
This Mac; if it says Intel, this will not work), about **5 GB of free disk
space**, and roughly **20 minutes**, most of it waiting on downloads.

**Opening Terminal:** press `⌘ Space`, type `terminal`, press Return. A window
with text appears. That is where everything below goes.

When you paste a password, nothing appears on screen. That is normal, keep
typing and press Return.

### What you are installing, and why

| | what it is |
|---|---|
| Xcode Command Line Tools | Apple's build tools. Whisperly is compiled on your machine |
| Homebrew | installs the rest. Standard on Macs |
| Hammerspoon | watches the `fn` key and pastes the text |
| jq, cmake | small helpers |
| whisper.cpp | the thing that actually turns speech into words |
| the model | 2.7 GB of speech recognition, runs on your Mac |

Nothing here needs an account, and nothing is uploaded.

### 1. Apple's build tools

```sh
xcode-select --install
```

A window pops up. Click **Install** and wait. If it says they are already
installed, good, move on.

### 2. Homebrew

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

It asks for your Mac password. At the end it may print two lines starting with
`echo` and ask you to run them — do exactly that if it does, then close
Terminal and open it again.

Already have Homebrew? Skip this.

### 3. The helpers

```sh
brew install --cask hammerspoon
brew install jq cmake
```

Now open Hammerspoon once (`⌘ Space`, type `hammerspoon`, Return) so it appears
in your menu bar. It may warn that it was downloaded from the internet — click
**Open**.

### 4. The speech engine

This is the part that does the real work. It gets built once and kept.

```sh
git clone https://github.com/ggerganov/whisper.cpp ~/whisper.cpp
cd ~/whisper.cpp
cmake -B build -DWHISPER_COREML=1
cmake --build build -j --config Release
```

The last line takes a few minutes and prints a lot of text. That is fine.
`-DWHISPER_COREML=1` is what lets it use your Mac's AI chip, which is most of
the speed.

### 5. The model

Two downloads, about 2.7 GB together. Slow connection, go make tea.

The first is the model itself. The second is its encoder again, rebuilt to run
on your Mac's Neural Engine — the same half of the model, in a form the AI chip
can execute. Measured here it takes the encoder from 1,117ms to 730ms, about
35% faster, which is roughly 0.4s off every sentence you dictate.

```sh
sh ./models/download-ggml-model.sh large-v3-turbo
sh ./models/download-coreml-model.sh large-v3-turbo
```

Skipping the second one still works — it quietly falls back to the GPU — but
everything gets noticeably slower. Check it works:

```sh
./build/bin/whisper-cli -m models/ggml-large-v3-turbo.bin -f samples/jfk.wav -nt
```

Among the output you should see *"And so, my fellow Americans..."*. If you do,
the hard part is done. The first run is slow while your Mac prepares the model;
it only happens once.

### 6. Whisperly

```sh
git clone https://github.com/kuldeeepy/whisperly ~/whisperly
cd ~/whisperly
./install.sh
```

It finds your whisper build on its own. If it cannot, tell it where:

```sh
WHISPERLY_WHISPER_DIR=~/whisper.cpp ./install.sh
```

### 7. Permissions

**This is the step people get wrong, and it fails silently.**

Open **System Settings** → **Privacy & Security**, then:

1. Click **Microphone**. Find **Hammerspoon** and switch it on.
   Not listed? Click **+**, pick Hammerspoon from Applications.
2. Go back, click **Accessibility**. Switch **Hammerspoon** on there too.

Then click the Hammerspoon icon in your menu bar (top right, looks like a
spoon) → **Reload Config**.

Without the microphone permission you get silence and no error message at all,
because a helper started by Hammerspoon never gets to ask you itself.

### 8. Try it

```sh
cd ~/whisperly
./selftest.sh
```

It plays a clip through your speakers, records it, and transcribes it. If the
last line says **PASS**, everything works. If a permission is missing, it says
so in plain words.

Now click into any text box — Notes, Messages, a browser — **hold `fn`, say
something, and let go**. A small dark pill appears at the bottom of your
screen while it listens.

Wait for the pill before you speak, or you will clip your first word.

### If something is wrong

| what happens | what to do |
|---|---|
| Nothing at all when you hold `fn` | Reload Hammerspoon from the menu bar |
| Pill appears but no text | Microphone permission. Run `./selftest.sh` |
| Text goes nowhere | Accessibility permission |
| It says `no whisper server` | Run `./install.sh` again |
| Double-tap ignored, holding works | System Settings → Keyboard → "Press fn key to" → set to **Do Nothing** |
| `command not found: brew` | Close Terminal, open it again |

### Removing it

```sh
cd ~/whisperly
./uninstall.sh
```

Then open `~/.hammerspoon/init.lua` and delete the line
`require("whisperly")`. To reclaim the disk space, delete the `~/whisper.cpp`
and `~/whisperly` folders.

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
