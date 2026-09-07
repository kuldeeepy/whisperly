# Whisperly

Dictation for macOS that runs entirely on your own machine.

Hold `fn`, talk, let go. The text appears wherever your cursor is, about half a
second later. Nothing is uploaded, there is no account, and nothing to pay for.

Built because I was paying for Wispr Flow and my laptop was already
sitting on a model that could do the same job.

```
hold fn, speak, let go           text lands at your cursor
double-tap fn, speak, tap fn     same thing, hands free
Esc                              throw the take away
```

## Setup

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

The first is the model. The second is half of it again, rebuilt to run on your
Mac's AI chip — that is what makes it fast.

```sh
sh ./models/download-ggml-model.sh large-v3-turbo
sh ./models/download-coreml-model.sh large-v3-turbo
```

Skip the second and it still works, just slower. Check it works:

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
something, and let go**.

A small dark pill appears at the bottom of the screen. Wait for it before you
speak, or you will clip your first word.

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

## Using it

- Hold `fn` for a quick line. Double-tap it for a long one, tap again to stop.
- `Esc` throws a take away.
- A single tap does nothing. It takes two, close together.
- Using `fn` in a shortcut never starts a recording, so `fn`+Space, `fn`+arrows
  and the F-keys all still work.
- A recording stops on its own after two minutes.

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

## How it works

```
  you hold fn
      │
      ▼
  a recorder writes what you say to a temporary file
      │
      ▼
  whisper turns that file into text          ← the slow bit, ~0.6s
      │
      ▼
  the text is pasted where your cursor is
```

The file is deleted straight after. Your clipboard is borrowed for the paste
and given back.

**Whisper is kept running in the background.** Starting it up takes about a
second, which is longer than transcribing usually takes, so it stays loaded.
That costs 1.6 GB of memory and it is the reason this feels instant.

Speaking for longer barely costs more, because whisper works in fixed chunks:

| you spoke for | it took |
|---|---|
| 2 seconds | 0.55s |
| 5 seconds | 0.56s |
| 11 seconds | 0.63s |

So say the whole thought in one go. Five short takes cost five times as much
as one long one.

On an M4 MacBook Air it uses 1.6 GB of memory, and almost no CPU except while
you are actually speaking. The first take after a long gap takes about 1.4s
while whisper wakes up.

## What it keeps

Nothing. Your words are never written to a file or a log, by Whisperly or by
whisper itself.

Recordings are kept in a private folder only your account can read, and deleted
the moment they are transcribed. Anything left behind by a crash is cleared the
next time it starts.

The one exposure: your text sits on the clipboard for about a sixth of a second
while it is pasted, so a clipboard manager could catch it. Nothing is stored,
which also means there is no undo.

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
