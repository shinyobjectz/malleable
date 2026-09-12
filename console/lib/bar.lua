-- bar — the strip along the foot of the home screen, which is all the agent shows of itself.
--
--     local bar = require "console.lib.bar"
--     local b = bar.new()
--     local items = b:draw { x = 0, y = 560, w = 800, h = 36, now = t, state = "hearing",
--                            level = 0.4, still = { { 300, 500 } }, dim = 0 }
--     b:pour(0.8, 1)                 -- a pulse four fifths of the way along (a key typed there)
--
-- It is a grid of dots. Quiet, the grid is dark. While the person is heard the dots are grey
-- and white; while the agent speaks they are in colour, their hues moving along the bar.
-- Either way each dot's size and light is a field that the speaker's level is poured into,
-- a few places at a time, and that spreads to the neighbouring dots and fades (a diffusion).
-- Under text (`still`, spans of the bar in pixels) the dots rest and do not light, so the
-- text can be read, and the light moves at either side of it. Its size never changes; one
-- state fades into the next. `dim` (0 to 1) lowers every dot. Nothing here names the host:
-- the items are drawn by console/main.lua.

local bar = {}

bar.GROUND = { 0.07, 0.07, 0.08 }
-- The hues the agent's dots move through.
bar.HUES = {
  { 0.00, 0.64, 1.00 },
  { 0.62, 0.48, 1.00 },
  { 1.00, 0.52, 0.78 },
  { 1.00, 0.45, 0.20 },
  { 1.00, 0.80, 0.10 },
  { 0.22, 0.80, 0.52 },
}
bar.PITCH = 8          -- pixels between dots
bar.FADE = 0.2         -- seconds one state takes to fade into the next
bar.REST = 0.16        -- how much of its light a dot at rest shows

local STEP = 1 / 60    -- the field is stepped at a fixed rate, whatever the frame rate
local SPREAD = 0.08    -- how much of the difference with its neighbours a dot takes each step
local LOSS = 0.02      -- how much of its light a dot loses each step

local B = {}
B.__index = B

function bar.new()
  return setmetatable({ on = 0, tone = 0, cols = 0, rows = 0, u = {}, v = {}, still = {},
                        pending = {}, left = 0, at = nil }, B)
end

--- A colour along the hues: `p` goes round them once from 0 to 1, eased between each.
function bar.hue(p)
  local n = #bar.HUES
  local q = (p % 1) * n
  local i = math.min(n - 1, math.floor(q))    -- a tiny negative p comes round as 1
  local f = q - i
  f = f * f * (3 - 2 * f)
  local a, b = bar.HUES[i + 1], bar.HUES[(i + 1) % n + 1]
  return { a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, a[3] + (b[3] - a[3]) * f }
end

--- A pulse into the field at `x` (0 to 1 along the bar), of `amount` (1 is a full dot).
function B:pour(x, amount)
  self.pending[#self.pending + 1] = { x = x, amount = amount or 1 }
end

-- The field sized to the bar; a new size starts it dark.
function B:fit(cols, rows)
  if cols == self.cols and rows == self.rows then return end
  self.cols, self.rows, self.u, self.v, self.still = cols, rows, {}, {}, {}
  for i = 1, cols * rows do self.u[i], self.v[i] = 0, 0 end
  for c = 1, cols do self.still[c] = 0 end
end

local function put(self, c, row, amount)
  local i = (row - 1) * self.cols + math.max(1, math.min(self.cols, c))
  self.u[i] = self.u[i] + amount
end

-- One step: the level is poured in at a few places that wander among the free columns
-- (`free`, in order), then every dot takes some of its neighbours' light and loses a
-- little of its own.
function B:step(t, level, free)
  local cols, rows = self.cols, self.rows
  if level > 0.02 and #free > 0 then
    local places = math.max(2, math.floor(#free / 10))
    for k = 1, places do
      local p = (k - 0.5) / places + math.sin(t * (0.6 + k * 0.23) + k * 1.7) * 0.5 / places
      local c = free[math.max(1, math.min(#free, 1 + math.floor(p * #free)))]
      local row = 1 + math.floor((math.sin(t * (1.3 + k * 0.41) + k) * 0.5 + 0.5) * rows * 0.999)
      put(self, c, row, level * 0.9 * (0.6 + 0.4 * math.sin(t * 7 + k * 2.3)))
    end
  end
  local u, v = self.u, self.v
  for r = 1, rows do
    for c = 1, cols do
      local i = (r - 1) * cols + c
      local here = u[i]
      local l = c > 1 and u[i - 1] or here
      local rt = c < cols and u[i + 1] or here
      local up = r > 1 and u[i - cols] or here
      local dn = r < rows and u[i + cols] or here
      v[i] = (here + SPREAD * (l + rt + up + dn - 4 * here)) * (1 - LOSS)
    end
  end
  self.u, self.v = v, u
end

local function ease(a, want, dt, seconds)
  return a + (want - a) * (1 - math.exp(-dt / ((seconds or bar.FADE) / 3)))
end

--- The bar at `f.x, f.y, f.w, f.h`, at time `f.now`, in state "hearing", "speaking" or
--- "quiet", with the level (0 to 1) of whoever is speaking, dots at rest under the spans in
--- `f.still`. Answers the items to draw.
function B:draw(f)
  local now = f.now or 0
  local dt = self.at and math.max(0, math.min(0.25, now - self.at)) or 0
  self.at = now
  self.on = ease(self.on, f.state == "quiet" and 0 or 1, dt)
  if f.state ~= "quiet" then self.tone = ease(self.tone, f.state == "speaking" and 1 or 0, dt) end
  local pitch = bar.PITCH
  self:fit(math.max(2, math.floor(f.w / pitch)), math.max(1, math.floor(f.h / pitch)))
  local gx = f.x + (f.w - (self.cols - 1) * pitch) / 2
  local gy = f.y + (f.h - (self.rows - 1) * pitch) / 2

  -- which columns rest: those under a span, eased so that text arriving settles them
  local free = {}
  for c = 1, self.cols do
    local x, want = gx + (c - 1) * pitch, 0
    for _, s in ipairs(f.still or {}) do
      if x >= s[1] and x <= s[2] then want = 1; break end
    end
    self.still[c] = ease(self.still[c], want, dt, 0.15)
    if want == 0 then free[#free + 1] = c end
  end

  for _, p in ipairs(self.pending) do
    put(self, 1 + math.floor(math.max(0, math.min(1, p.x)) * (self.cols - 1) + 0.5), 1 + math.floor(self.rows / 2), p.amount)
  end
  self.pending = {}
  -- the field runs only while it can be seen, and it catches up at most a quarter second
  self.left = self.left + dt
  while self.left >= STEP do
    self.left = self.left - STEP
    if self.on > 0.01 then self:step(now - self.left, f.state ~= "quiet" and (f.level or 0) or 0, free) end
  end

  local items = { { kind = "rect", x = f.x, y = f.y, w = f.w, h = f.h, rgb = bar.GROUND, alpha = 1 } }
  local seen = self.on * (1 - 0.6 * (f.dim or 0))
  if seen > 0.01 then
    local tone = self.tone
    for c = 1, self.cols do
      local x = gx + (c - 1) * pitch
      local hc = bar.hue(x / math.max(1, f.w) * 0.8 - now * 0.06)
      local moving = 1 - self.still[c]
      for r = 1, self.rows do
        local s = math.min(1, self.u[(r - 1) * self.cols + c]) * moving
        local g = 0.62 + 0.38 * s
        items[#items + 1] = { kind = "circle", x = x, y = gy + (r - 1) * pitch, segments = 12,
                              r = pitch * (0.13 + 0.25 * s),
                              rgb = { g + (hc[1] - g) * tone, g + (hc[2] - g) * tone, g + (hc[3] - g) * tone },
                              alpha = seen * (bar.REST + (1 - bar.REST) * s) }
      end
    end
  end
  return items
end

return bar
