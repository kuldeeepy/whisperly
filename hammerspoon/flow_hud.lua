-- flow_hud.lua — the dictation pill.
--
-- Bottom-centre, dark, compact. A scrolling waveform while listening, a
-- travelling pulse while transcribing.
--
-- Cost, by construction:
--   listening    — no timer at all. Driven entirely by the RMS lines flowrec
--                  already emits (~15/s), which the pipeline pays for anyway.
--   transcribing — one 25 fps timer, alive for the ~0.7s a transcription takes,
--                  stopped the instant it ends.
--   idle         — canvas hidden, nothing scheduled, no observers, no threads.
--
-- The canvas is built once and reused; showing it never reallocates.

local hud = {}

local BARS      = 16
local BAR_W     = 2
local BAR_GAP   = 3
local W, H      = 120, 32
local MARGIN    = 22      -- gap from the bottom of the screen
local MAX_HALF  = 9       -- tallest half-bar, in points
local MIN_HALF  = 1       -- a resting bar is a dot, never nothing
local FULL_RMS  = 0.10    -- mic RMS that fills a bar
local CURVE     = 0.55    -- <1 lifts quiet speech into visible range
local SMOOTHING = 0.55    -- how much of a new sample survives, 0..1
local PULSE_FPS = 25

local LISTEN = { white = 0.96, alpha = 0.92 }
local WORK   = { red = 0.45, green = 0.72, blue = 1.0, alpha = 0.95 }

local canvas, screenFrame, pulseTimer
local levels, lastLevel = {}, 0
local mode, pulseAt = nil, 0

-- Layout --------------------------------------------------------------------

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
    -- A hairline rim keeps the pill readable on a dark wallpaper.
    { type = "rectangle", action = "stroke", strokeWidth = 1,
      roundedRectRadii = { xRadius = H / 2, yRadius = H / 2 },
      strokeColor = { white = 1, alpha = 0.12 },
      frame = { x = 0.5, y = 0.5, w = W - 1, h = H - 1 } }
  )

  -- Discrete bars, not one filled `segments` shape. That was tried on the
  -- assumption N element writes meant N redraws; measured over a 6s window it
  -- was worse -- 0.47s of CPU against 0.28s for bars -- because rebuilding a
  -- 32-point coordinate table each frame costs more crossing the Lua/ObjC
  -- bridge than 16 frame writes do.
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

-- Only moves when the screen actually changed, so showing costs nothing.
local function position()
  local f = hs.screen.mainScreen():frame()
  if screenFrame and f.x == screenFrame.x and f.y == screenFrame.y
     and f.w == screenFrame.w and f.h == screenFrame.h then return end
  screenFrame = f
  canvas:frame({ x = f.x + (f.w - W) / 2, y = f.y + f.h - H - MARGIN, w = W, h = H })
end

-- Bars are elements 3..N+2; 1 and 2 are the pill and its rim.
local function render(color)
  for i = 1, BARS do
    local half = halfAt(i)
    local bar = canvas[i + 2]
    bar.frame = { x = barX(i), y = H / 2 - half, w = BAR_W, h = half * 2 }
    if color then bar.fillColor = color end
  end
end

local function stopPulse()
  if pulseTimer then pulseTimer:stop() pulseTimer = nil end
end

local function clear()
  for i = 1, BARS do levels[i] = 0 end
  lastLevel = 0
end

-- States --------------------------------------------------------------------

function hud.listening()
  if not canvas then build() end
  stopPulse()
  position()
  mode = "listening"
  clear()
  render(LISTEN)
  canvas:show(0.12)
end

-- Called from flowrec's stdout, so the waveform costs no timer of its own.
function hud.level(rms)
  if mode ~= "listening" then return end
  local target = math.min(1, (rms or 0) / FULL_RMS) ^ CURVE
  lastLevel = lastLevel + (target - lastLevel) * SMOOTHING

  table.remove(levels, 1)       -- scroll left, newest on the right
  levels[BARS] = lastLevel
  render()
end

function hud.transcribing()
  if not canvas then build() end
  position()
  mode = "transcribing"
  render(WORK)
  canvas:show(0.1)

  -- A soft bump travelling left to right: enough motion to read as "working"
  -- without the busy spin of a spinner.
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
