-- Whisperly — local dictation for macOS.
--
--   hold fn, speak, let go            -> text lands at your cursor
--   double-tap fn, speak, tap fn      -> same thing, hands free
--
--   mic -> recorder -> whisper (kept warm) -> paste
--
-- One number decides which mode you meant: let go before `tapSeconds` and it
-- was a tap, keep holding and recording starts. Press any other key while fn
-- is down and the take is dropped, so fn+Space and the F-keys still work.

local whisperly = {}

-- install.sh writes this file with the paths for this machine.
local ok, paths = pcall(require, "whisperly_paths")
if not ok then paths = {} end

local ROOT = paths.root or (os.getenv("HOME") .. "/Others/whisperly")

local config = {
  recorder = ROOT .. "/bin/recorder",
  transcriber = ROOT .. "/bin/transcribe",
  scratch = paths.scratch or "/tmp/whisperly",

  key = 63,             -- fn
  tapSeconds = 0.4,     -- let go before this = tap, keep holding = record
  doubleTapGap = 0.6,   -- two taps this close together start a take
  minSeconds = 0.4,     -- anything shorter was a slip, not speech
  maxSeconds = 120,     -- so a stuck key cannot record all day
  trailingSpace = true, -- so you can dictate twice in a row
  debug = false,        -- log fn press timings when a trigger misbehaves

  -- The fn key reports 63 when held but sends its own keypress as 179.
  -- Neither means "you pressed something else", so neither cancels a tap.
  selfKeys = { [63] = true, [179] = true },

  -- What whisper tends to invent when handed near-silence.
  hallucinations = {
    ["you"] = true, ["you."] = true, ["thank you"] = true, ["thank you."] = true,
    ["thanks for watching"] = true, ["[blank_audio]"] = true,
    ["(upbeat music)"] = true, ["bye"] = true, ["."] = true,
  },
}

-- State ----------------------------------------------------------------------
-- idle -> recording -> transcribing -> idle

local state = "idle"
local mode = nil        -- "hold" while fn is down, "toggle" after a double-tap
local recorder = nil    -- the running recorder process
local wavPath = nil
local startedAt = nil
local escapeWatch = nil -- listens for Esc, only while recording
local pillShown = false -- has the pill appeared for this take yet
local maxTimer = nil

-- Drawing lives in whisperly_hud.lua. Every call is wrapped, because the pill
-- is decoration and must never be able to break dictation. It did once, when a
-- bad font name threw before whisper was ever called.
local ui = require("whisperly_hud")

local function hud(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then print("[whisperly] hud: " .. tostring(err)) end
end

-- Output ---------------------------------------------------------------------

local function paste(text)
  local previous = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  -- Wait for the app to actually read the clipboard before putting yours back.
  hs.timer.doAfter(0.15, function()
    if previous then hs.pasteboard.setContents(previous) end
  end)
end

local function clean(text)
  text = text:gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  if text == "" then return nil end
  if config.hallucinations[text:lower()] then return nil end
  if config.trailingSpace then text = text .. " " end
  return text
end

-- Pipeline -------------------------------------------------------------------

-- Recordings are temporary and deleted as soon as they are transcribed.
-- Anything still here at startup was left behind by a crash or reload.
local function prepareScratch()
  os.execute(string.format("pkill -f %q 2>/dev/null", config.recorder))
  hs.fs.mkdir(config.scratch)
  -- hs.fs has no chmod, and 0700 keeps takes private to this account.
  os.execute(string.format("chmod 700 %q 2>/dev/null", config.scratch))
  -- hs.fs.dir hands back an iterator and a state object, and the loop needs
  -- both, so wrap the whole thing rather than capturing the first value.
  pcall(function()
    for entry in hs.fs.dir(config.scratch) do
      if entry:match("%.wav$") then os.remove(config.scratch .. "/" .. entry) end
    end
  end)
end

local function reset()
  if escapeWatch then escapeWatch:stop() escapeWatch = nil end
  if maxTimer then maxTimer:stop() maxTimer = nil end
  recorder, wavPath, startedAt = nil, nil, nil
  state = "idle"
end

local function fail(message)
  hud(ui.hide)
  hs.alert.show(message, 1.2)
  reset()
end

-- Length straight from the file size: 16-bit mono at 16 kHz, 44-byte header.
local function wavSeconds(path)
  local size = hs.fs.attributes(path, "size")
  if not size or size <= 44 then return 0 end
  return (size - 44) / 32000
end

local function transcribe(path)
  hud(ui.transcribing)

  hs.task.new(config.transcriber, function(code, stdout, stderr)
    hud(ui.hide)
    if code ~= 0 then
      print("[whisperly] transcribe failed: " .. tostring(stderr))
      hs.alert.show("Whisperly: " .. (stderr or "transcription failed"), 2)
    else
      local text = clean(stdout or "")
      if text then
        paste(text)
        print(string.format("[whisperly] %.2fs -> %d chars",
          hs.timer.secondsSinceEpoch() - startedAt, #text))
      else
        print(string.format("[whisperly] nothing usable: %q", (stdout or ""):sub(1, 80)))
      end
    end
    os.remove(path)
    reset()
  end, { path }):start()
end

local function stopRecording(discard)
  if state ~= "recording" then return end
  state = discard and "cancelling" or "transcribing"
  if escapeWatch then escapeWatch:stop() escapeWatch = nil end
  if maxTimer then maxTimer:stop() maxTimer = nil end
  if recorder then recorder:terminate() end   -- the recorder closes the file
end

local function startRecording(recordMode)
  mode = recordMode or "toggle"
  pillShown = false
  wavPath = string.format("%s/%d.wav", config.scratch, hs.timer.absoluteTime())
  startedAt = hs.timer.secondsSinceEpoch()
  state = "recording"

  recorder = hs.task.new(config.recorder,
    -- Called once the recorder has exited and the file is closed.
    function(code, _, stderr)
      local path = wavPath
      if state == "cancelling" then
        print("[whisperly] cancelled")
        hud(ui.hide) os.remove(path) reset()
        return
      end
      if code ~= 0 then
        fail("Whisperly: recorder failed — " .. (stderr or ""):gsub("%s+$", ""))
        os.remove(path)
        return
      end
      if wavSeconds(path) < config.minSeconds then
        print(string.format("[whisperly] too short: %.2fs", wavSeconds(path)))
        hud(ui.hide) os.remove(path) reset()
        return
      end
      transcribe(path)
    end,
    -- Loudness readings, about 30 a second.
    function(_, stdout)
      if state ~= "recording" then return true end
      -- The first reading proves the mic is really running, so the pill only
      -- shows up once audio is genuinely arriving.
      if not pillShown then pillShown = true; hud(ui.listening) end
      -- One chunk often holds several readings. Using only the last one made
      -- the waveform lag and stutter.
      for value in stdout:gmatch("[%d%.]+") do
        hud(ui.level, tonumber(value) or 0)
      end
      return true
    end,
    { wavPath })

  if not recorder:start() then
    fail("Whisperly: could not start the recorder")
    return
  end

  -- Recording is hands free, so typing must not cancel it. Only Esc does.
  escapeWatch = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if event:getKeyCode() == hs.keycodes.map.escape then stopRecording(true) end
    return false
  end)
  escapeWatch:start()

  maxTimer = hs.timer.doAfter(config.maxSeconds, function() stopRecording(false) end)
end

-- Trigger ---------------------------------------------------------------------
-- fn reports itself on press and on release; the fn flag tells them apart.

local pressedAt = nil
local usedAsModifier = false
local lastTapAt = 0
local holdTimer = nil

-- A tap either ends a hands-free take, or pairs with the last tap to start one.
-- A single tap on its own does nothing on purpose.
local function onTap()
  if state == "recording" then
    stopRecording(false)
    lastTapAt = 0
    return
  end
  if state ~= "idle" then return end

  local now = hs.timer.secondsSinceEpoch()
  if now - lastTapAt <= config.doubleTapGap then
    lastTapAt = 0
    startRecording("toggle")
  else
    lastTapAt = now
  end
end

local function cancelHoldTimer()
  if holdTimer then holdTimer:stop() holdTimer = nil end
end

-- Built once and just started and stopped. Building a new event tap on every
-- fn press would mean building one for every fn+arrow and F-key too.
local modifierWatch = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
  if config.selfKeys[event:getKeyCode()] then return false end
  if config.debug then print("[whisperly] chord key " .. event:getKeyCode()) end
  usedAsModifier = true
  cancelHoldTimer()
  -- fn turned out to be a shortcut, so drop anything already recording.
  if state == "recording" and mode == "hold" then stopRecording(true) end
  return false
end)

local function onFnDown()
  pressedAt = hs.timer.secondsSinceEpoch()
  usedAsModifier = false
  modifierWatch:start()   -- only while fn is actually held

  -- Still holding and not part of a shortcut, so you meant hold-to-talk.
  holdTimer = hs.timer.doAfter(config.tapSeconds, function()
    holdTimer = nil
    if state == "idle" and not usedAsModifier then
      lastTapAt = 0
      startRecording("hold")
    end
  end)
end

local function onFnUp()
  cancelHoldTimer()
  modifierWatch:stop()

  local held = pressedAt and (hs.timer.secondsSinceEpoch() - pressedAt) or math.huge
  pressedAt = nil

  if config.debug then
    print(string.format("[whisperly] fn held %.2fs, shortcut %s, state %s",
      held, tostring(usedAsModifier), state))
  end

  if state == "recording" and mode == "hold" then
    stopRecording(false)                       -- let go, so transcribe it
  elseif not usedAsModifier and held <= config.tapSeconds then
    onTap()
  end
end

local trigger = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
  if event:getKeyCode() ~= config.key then return false end
  if event:getFlags().fn then onFnDown() else onFnUp() end
  return false
end)

prepareScratch()
trigger:start()

whisperly.config = config
whisperly.trigger = trigger
whisperly.start = startRecording   -- so other triggers and tests can drive it
whisperly.stop = stopRecording
return whisperly
