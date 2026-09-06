-- Flow — push-to-talk dictation.
--
--   hold Right ⌘ · speak · release  ->  text is pasted at the cursor
--
--   mic -> flowrec (16 kHz mono WAV) -> whisper-server (warm) -> paste
--
-- Any other keypress while the key is held cancels the take, so Right ⌘ still
-- works as a normal modifier for shortcuts.

local flow = {}

local ROOT = os.getenv("HOME") .. "/Others/flow"

local config = {
  recorder = ROOT .. "/bin/flowrec",
  transcriber = ROOT .. "/bin/flow-stt",
  scratch = "/tmp/flow",

  key = 54,            -- Right ⌘ (see hs.keycodes.map); 61 = Right ⌥
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
local recorder = nil     -- hs.task while recording
local wavPath = nil
local startedAt = nil
local guardTap = nil     -- keyDown watcher, live only while recording
local maxTimer = nil

-- HUD -----------------------------------------------------------------------

local hud = nil

local function buildHud()
  local screen = hs.screen.mainScreen():frame()
  local w, h = 190, 40
  local canvas = hs.canvas.new({
    x = screen.x + (screen.w - w) / 2,
    y = screen.y + screen.h - h - 90,
    w = w, h = h,
  })

  canvas:appendElements(
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 20, yRadius = 20 },
      fillColor = { red = 0.08, green = 0.08, blue = 0.09, alpha = 0.92 } },
    { type = "circle", action = "fill", center = { x = 24, y = 20 }, radius = 5,
      fillColor = { red = 0.98, green = 0.32, blue = 0.32, alpha = 1 } },
    { type = "text", text = "listening", textSize = 13,
      textColor = { white = 0.95 }, textFont = hs.styledtext.defaultFonts.system.name,
      frame = { x = 40, y = 11, w = 100, h = 20 } },
    -- Level meter: width is driven by mic RMS.
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 2, yRadius = 2 },
      fillColor = { white = 0.6, alpha = 0.8 },
      frame = { x = 140, y = 18, w = 0, h = 4 } }
  )

  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
  return canvas
end

local function showHud(label, dotColor)
  local ok, err = pcall(function()
    hud = hud or buildHud()
    hud[2].fillColor = dotColor
    hud[3].text = label
    hud[4].frame.w = 0
    hud:show()
  end)
  if not ok then print("[flow] hud: " .. tostring(err)) end
end

local function hideHud()
  if hud then hud:hide() end
end

-- RMS is roughly 0.0-0.3 for speech; scale it into a 34 px bar.
local function updateMeter(rms)
  if not hud then return end
  hud[4].frame.w = math.min(34, rms * 170)
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

local function reset()
  if guardTap then guardTap:stop() guardTap = nil end
  if maxTimer then maxTimer:stop() maxTimer = nil end
  recorder, wavPath, startedAt = nil, nil, nil
  state = "idle"
end

local function fail(message)
  hideHud()
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
  showHud("transcribing", { red = 0.4, green = 0.7, blue = 1.0, alpha = 1 })

  hs.task.new(config.transcriber, function(code, stdout, stderr)
    hideHud()
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

local function startRecording()
  hs.fs.mkdir(config.scratch)
  wavPath = string.format("%s/%d.wav", config.scratch, hs.timer.absoluteTime())
  startedAt = hs.timer.secondsSinceEpoch()
  state = "recording"

  recorder = hs.task.new(config.recorder,
    function(code, _, stderr)                 -- process exited
      local path, cancelled = wavPath, (state == "cancelling")
      if cancelled then
        print("[flow] cancelled")
        hideHud()
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
        hideHud()
        os.remove(path)
        reset()
        return
      end
      transcribe(path)
    end,
    function(_, stdout)                        -- one RMS line per ~66 ms
      if state ~= "recording" then return true end
      -- The first line is proof the mic is actually live, not just requested.
      if not hud or not hud:isShowing() then
        showHud("listening", { red = 0.98, green = 0.32, blue = 0.32, alpha = 1 })
      end
      local last = stdout:match("([%d%.]+)%s*$")
      if last then updateMeter(tonumber(last) or 0) end
      return true
    end,
    { wavPath })

  if not recorder:start() then
    fail("Flow: could not start the recorder")
    return
  end

  -- Any other keypress means Right ⌘ is being used as a modifier, not to talk.
  guardTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function()
    stopRecording(true)
    return false
  end)
  guardTap:start()

  maxTimer = hs.timer.doAfter(config.maxSeconds, function() stopRecording(false) end)
end

-- Trigger -------------------------------------------------------------------
-- flagsChanged fires on both press and release of the same keycode; the cmd
-- flag tells the two apart.

local trigger = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
  if event:getKeyCode() ~= config.key then return false end

  if event:getFlags().cmd then
    if state == "idle" then startRecording() end
  else
    stopRecording(false)
  end
  return false
end)

trigger:start()

flow.config = config
flow.trigger = trigger
flow.start = startRecording   -- exposed so other triggers (and tests) can drive it
flow.stop = stopRecording
return flow
