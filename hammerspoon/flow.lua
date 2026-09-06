-- Flow — push-to-talk dictation.
--
--   hold fn · speak · release        -> text is pasted at the cursor
--   double-tap fn · speak · tap fn   -> same, but hands-free
--
--   mic -> flowrec (16 kHz mono WAV) -> whisper-server (warm) -> paste
--
-- One threshold separates the two: release before `tapSeconds` and it was a
-- tap, still down at `tapSeconds` and hold-to-talk begins. Esc cancels.
-- Pressing any other key while fn is down cancels the take and marks it a
-- chord, so fn+Space, fn+arrows and the F-key row keep working.

local flow = {}

local ROOT = os.getenv("HOME") .. "/Others/flow"

local config = {
  recorder = ROOT .. "/bin/flowrec",
  transcriber = ROOT .. "/bin/flow-stt",
  scratch = "/tmp/flow",

  key = 63,            -- fn (see hs.keycodes.map)
  tapSeconds = 0.4,    -- release before this = tap; still down = hold-to-talk
  doubleTapGap = 0.6,  -- two taps inside this window arm recording
  debug = false,       -- log every fn press duration and inter-tap gap

  -- The fn/globe key reports 63 in flagsChanged but emits its own keyDown as
  -- 179. Neither is a chord partner, so neither may disqualify a tap.
  selfKeys = { [63] = true, [179] = true },
  minSeconds = 0.4,    -- shorter takes are treated as an accidental tap
  maxSeconds = 120,    -- hard stop, so a stuck key cannot record forever
  trailingSpace = true,

  -- Whisper reliably emits one of these when it is handed near-silence.
  hallucinations = {
    ["you"] = true, ["thank you"] = true, ["thanks for watching"] = true,
    ["thank you."] = true, ["you."] = true, ["[blank_audio]"] = true,
    ["(upbeat music)"] = true, ["bye"] = true, ["."] = true,
  },
}

-- State ---------------------------------------------------------------------
-- idle -> recording -> transcribing -> idle

local state = "idle"
local mode = nil         -- "hold" (fn is down) or "toggle" (double-tapped)
local recorder = nil     -- hs.task while recording
local wavPath = nil
local startedAt = nil
local guardTap = nil     -- keyDown watcher, live only while recording
local shown = false      -- has the pill appeared for this take?
local maxTimer = nil

-- HUD -----------------------------------------------------------------------
-- Drawing lives in flow_hud.lua. Every call is wrapped: the pill is cosmetic
-- and must never be able to take down the dictation path -- it did once, when
-- an invalid font name threw before whisper was ever called.

local ui = require("flow_hud")

local function hud(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then print("[flow] hud: " .. tostring(err)) end
end

-- Output --------------------------------------------------------------------

local function paste(text)
  local previous = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  -- Give the target app time to read the pasteboard before restoring it.
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

-- Pipeline ------------------------------------------------------------------

-- Recordings are transient: each is deleted the moment it has been
-- transcribed. Any WAV still present at load was orphaned by a reload or crash
-- that killed the recorder before its cleanup ran -- nothing is recording yet,
-- so sweep the lot. 0700 keeps takes unreadable by other accounts.
local function prepareScratch()
  -- A recorder orphaned by a reload keeps the mic open; flowrec now exits on
  -- its own when reparented, but clear any predating this build.
  os.execute(string.format("pkill -f %q 2>/dev/null", config.recorder))
  hs.fs.mkdir(config.scratch)
  -- hs.fs has no chmod; one shell call at load is cheaper than the alternatives.
  os.execute(string.format("chmod 700 %q 2>/dev/null", config.scratch))
  -- hs.fs.dir returns an iterator *and* a state object; the generic for needs
  -- both, so pcall the whole loop rather than capturing the first return.
  pcall(function()
    for entry in hs.fs.dir(config.scratch) do
      if entry:match("%.wav$") then os.remove(config.scratch .. "/" .. entry) end
    end
  end)
end

local function reset()
  if guardTap then guardTap:stop() guardTap = nil end
  if maxTimer then maxTimer:stop() maxTimer = nil end
  recorder, wavPath, startedAt = nil, nil, nil
  state = "idle"
end

local function fail(message)
  hud(ui.hide)
  hs.alert.show(message, 1.2)
  reset()
end

-- Duration straight from the WAV size: 16-bit mono @ 16 kHz, 44-byte header.
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
      print("[flow] stt failed: " .. tostring(stderr))
      hs.alert.show("Flow: " .. (stderr or "transcription failed"), 2)
    else
      local raw = stdout or ""
      local text = clean(raw)
      if text then
        paste(text)
        print(string.format("[flow] %.2fs -> %d chars", hs.timer.secondsSinceEpoch() - startedAt, #text))
      else
        print(string.format("[flow] discarded: %q", raw:sub(1, 80)))
      end
    end
    os.remove(path)
    reset()
  end, { path }):start()
end

local function stopRecording(discard)
  if state ~= "recording" then return end
  state = discard and "cancelling" or "transcribing"
  if guardTap then guardTap:stop() guardTap = nil end
  if maxTimer then maxTimer:stop() maxTimer = nil end
  if recorder then recorder:terminate() end   -- SIGTERM; flowrec flushes the header
end

local function startRecording(recordMode)
  mode = recordMode or "toggle"
  shown = false
  wavPath = string.format("%s/%d.wav", config.scratch, hs.timer.absoluteTime())
  startedAt = hs.timer.secondsSinceEpoch()
  state = "recording"

  recorder = hs.task.new(config.recorder,
    function(code, _, stderr)                 -- process exited
      local path, cancelled = wavPath, (state == "cancelling")
      if cancelled then
        print("[flow] cancelled")
        hud(ui.hide)
        os.remove(path)
        reset()
        return
      end
      if code ~= 0 then
        fail("Flow: recorder failed — " .. (stderr or ""):gsub("%s+$", ""))
        os.remove(path)
        return
      end
      if wavSeconds(path) < config.minSeconds then
        print(string.format("[flow] too short: %.2fs", wavSeconds(path)))
        hud(ui.hide)
        os.remove(path)
        reset()
        return
      end
      transcribe(path)
    end,
    function(_, stdout)                        -- RMS lines, ~30 per second
      if state ~= "recording" then return true end
      -- The first line is proof the mic is live, not merely requested, so the
      -- pill only ever appears once audio is genuinely arriving.
      if not shown then shown = true; hud(ui.listening) end
      -- A chunk often carries several samples. Taking only the last one threw
      -- the rest away and made the waveform lag and stutter.
      for value in stdout:gmatch("[%d%.]+") do
        hud(ui.level, tonumber(value) or 0)
      end
      return true
    end,
    { wavPath })

  if not recorder:start() then
    fail("Flow: could not start the recorder")
    return
  end

  -- Recording is hands-free, so only Esc aborts it; everything else passes through.
  guardTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    if event:getKeyCode() == hs.keycodes.map.escape then stopRecording(true) end
    return false
  end)
  guardTap:start()

  maxTimer = hs.timer.doAfter(config.maxSeconds, function() stopRecording(false) end)
end

-- Trigger -------------------------------------------------------------------
-- fn emits flagsChanged on both press and release; the fn flag separates them.

local pressedAt = nil     -- when fn went down, or nil if fn is up
local heldAsModifier = false
local lastTapAt = 0
local modifierWatch = nil
local holdTimer = nil

-- A tap either stops a toggle-mode take, or pairs with the previous tap to
-- start one. A lone tap is deliberately inert.
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

-- Built once and merely started/stopped. Creating a CGEventTap on every fn
-- press would mean building one for every fn+arrow and F-key you touch.
modifierWatch = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
  if config.selfKeys[e:getKeyCode()] then return false end
  if config.debug then print("[flow] chordkey=" .. tostring(e:getKeyCode())) end
  heldAsModifier = true
  cancelHoldTimer()
  -- fn turned out to be a chord: drop anything hold-to-talk already started.
  if state == "recording" and mode == "hold" then stopRecording(true) end
  return false
end)

local function onFnDown()
  pressedAt = hs.timer.secondsSinceEpoch()
  heldAsModifier = false
  modifierWatch:start()   -- runs only while fn is physically down

  -- Still down at tapSeconds and not part of a chord: this is hold-to-talk.
  holdTimer = hs.timer.doAfter(config.tapSeconds, function()
    holdTimer = nil
    if state == "idle" and not heldAsModifier then
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
    print(string.format("[flow] fn held=%.2fs gap=%.2fs chord=%s state=%s",
      held, lastTapAt > 0 and (hs.timer.secondsSinceEpoch() - lastTapAt) or -1,
      tostring(heldAsModifier), state))
  end

  if state == "recording" and mode == "hold" then
    stopRecording(false)                       -- released: transcribe
  elseif not heldAsModifier and held <= config.tapSeconds then
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

flow.config = config
flow.trigger = trigger
flow.start = startRecording   -- exposed so other triggers (and tests) can drive it
flow.stop = stopRecording
return flow
