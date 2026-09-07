-- The pill that appears while you dictate.
--
-- Bottom of the screen, small and dark. A waveform that scrolls while it
-- listens, and a soft pulse while it thinks.
--
-- It is cheap on purpose:
--   listening    no timer at all, it rides the loudness readings the recorder
--                already sends
--   transcribing one timer at 25 fps, for the ~0.7s a transcription takes
--   idle         hidden, nothing scheduled, nothing running
--
-- Measured: 0.1% of a core idle, 5.5% while a waveform is moving.

local hud = {}

local BARS      = 18
local BAR_W     = 2
local BAR_GAP   = 2.6
local W, H      = 120, 32
local MARGIN    = 22      -- distance from the bottom of the screen
local MAX_HALF  = 9       -- tallest a bar gets, measured from the middle
local MIN_HALF  = 1       -- a quiet bar is a dot, never nothing
local CURVE     = 0.65    -- below 1 lifts quiet speech into view
local ATTACK    = 0.70    -- rise quickly, so hard consonants show
local RELEASE   = 0.22    -- fall slowly, so the shape stays readable
local NOISE     = 0.006   -- below this is room noise, not you
local MIN_PEAK  = 0.030   -- floor on the reference, so a whisper is not
                          -- stretched to full height
local PEAK_FALL = 0.995   -- per reading, so the reference forgets over ~3s
local PULSE_FPS = 25

local LISTEN = { white = 0.96, alpha = 0.92 }
local WORK   = { red = 0.45, green = 0.72, blue = 1.0, alpha = 0.95 }

local canvas, screenFrame, pulseTimer
local levels, lastLevel, peak = {}, 0, MIN_PEAK
local drawn = {}          -- last height drawn per bar, to skip pointless writes
local mode, pulseAt = nil, 0

-- Layout ----------------------------------------------------------------------

local function halfAt(i)
  return MIN_HALF + (MAX_HALF - MIN_HALF) * levels[i]
end

local function barX(i)
  local span = BARS * BAR_W + (BARS - 1) * BAR_GAP
  return (W - span) / 2 + (i - 1) * (BAR_W + BAR_GAP)
end

local function build()
  canvas = hs.canvas.new({ x = 0, y = 0, w = W, h = H })

  canvas:appendElements(
    { type = "rectangle", action = "fill",
      roundedRectRadii = { xRadius = H / 2, yRadius = H / 2 },
      fillColor = { white = 0.07, alpha = 0.94 },
      frame = { x = 0, y = 0, w = W, h = H } },
    -- A faint rim so the pill still reads on a dark wallpaper.
    { type = "rectangle", action = "stroke", strokeWidth = 1,
      roundedRectRadii = { xRadius = H / 2, yRadius = H / 2 },
      strokeColor = { white = 1, alpha = 0.12 },
      frame = { x = 0.5, y = 0.5, w = W - 1, h = H - 1 } }
  )

  -- Separate bars, not one filled shape. The single-shape version was tried
  -- and measured worse: 0.47s of CPU against 0.28s, because rebuilding a
  -- 32-point path every frame costs more than moving 18 rectangles.
  for i = 1, BARS do
    canvas:appendElements({
      type = "rectangle", action = "fill",
      roundedRectRadii = { xRadius = BAR_W / 2, yRadius = BAR_W / 2 },
      fillColor = LISTEN,
      frame = { x = barX(i), y = H / 2 - MIN_HALF, w = BAR_W, h = MIN_HALF * 2 },
    })
    levels[i] = 0
  end

  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
end

-- Only moves when the screen actually changed, so showing it is free.
local function position()
  local f = hs.screen.mainScreen():frame()
  if screenFrame and f.x == screenFrame.x and f.y == screenFrame.y
     and f.w == screenFrame.w and f.h == screenFrame.h then return end
  screenFrame = f
  canvas:frame({ x = f.x + (f.w - W) / 2, y = f.y + f.h - H - MARGIN, w = W, h = H })
end

-- Bars are elements 3 onwards; 1 and 2 are the pill and its rim.
-- Bars that have not visibly moved are left alone, which makes pauses cheap.
local function render(color)
  for i = 1, BARS do
    local half = halfAt(i)
    if color or math.abs(half - (drawn[i] or -1)) > 0.2 then
      local bar = canvas[i + 2]
      bar.frame = { x = barX(i), y = H / 2 - half, w = BAR_W, h = half * 2 }
      if color then bar.fillColor = color end
      drawn[i] = half
    end
  end
end

local function stopPulse()
  if pulseTimer then pulseTimer:stop() pulseTimer = nil end
end

local function clear()
  for i = 1, BARS do levels[i] = 0; drawn[i] = nil end
  lastLevel = 0
  peak = MIN_PEAK
end

-- States -----------------------------------------------------------------------

function hud.listening()
  if not canvas then build() end
  stopPulse()
  position()
  mode = "listening"
  clear()
  render(LISTEN)
  canvas:show(0.12)
end

-- Fed by the recorder's own output, so the waveform needs no timer.
--
-- The scale follows a fading peak rather than a fixed number. A fixed number
-- is wrong for every voice, mic and room, and being wrong either flattens the
-- bars or pins them at the top.
function hud.level(rms)
  if mode ~= "listening" then return end
  rms = rms or 0

  peak = math.max(rms, peak * PEAK_FALL, MIN_PEAK)
  local span = peak - NOISE
  local target = span > 0 and math.min(1, math.max(0, rms - NOISE) / span) ^ CURVE or 0

  -- Rise fast, fall slow. That difference is what makes it look like it is
  -- following speech instead of smearing it.
  lastLevel = lastLevel + (target - lastLevel) * (target > lastLevel and ATTACK or RELEASE)

  table.remove(levels, 1)   -- scroll left, newest on the right
  levels[BARS] = lastLevel
  render()
end

function hud.transcribing()
  if not canvas then build() end
  position()
  mode = "transcribing"
  render(WORK)
  canvas:show(0.1)

  -- A soft bump travelling across: enough movement to read as "working"
  -- without a spinner's fuss.
  pulseAt = -0.25
  pulseTimer = hs.timer.doEvery(1 / PULSE_FPS, function()
    pulseAt = pulseAt + 0.05
    if pulseAt > 1.25 then pulseAt = -0.25 end
    local centre = pulseAt * BARS
    for i = 1, BARS do
      local d = i - centre
      levels[i] = math.exp(-(d * d) / 5) * 0.8
    end
    render()
  end)
end

function hud.hide()
  stopPulse()
  mode = nil
  if canvas then canvas:hide(0.18) end
end

return hud
