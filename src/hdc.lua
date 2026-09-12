-- hdc -- hypervectors: 8192 random bits standing for a thing, and the arithmetic that
-- combines them (spec/history.md, "Hypervectors").
--
--     local hdc = require "hdc"
--     local v = hdc.bundle { hdc.bind(hdc.atom "role:agent", hdc.atom "notebook"),
--                            hdc.bind(hdc.atom "role:hour", hdc.level("hour", 14, 24)) }
--     hdc.similarity(v, hdc.bind(hdc.atom "role:agent", hdc.atom "notebook"))   -- well above 0.5
--
-- A vector is a list of 1024 bytes (numbers 0 to 255). Nothing here reads a model's words:
-- a name's vector is made from the name by a fixed generator, so the same name is the same
-- vector on every machine and in every interpreter, and no codebook is kept.
--
-- Plain Lua with no bit operators, so it runs the same on LuaJIT, Lua 5.4 and 5.5: exclusive
-- or and counting bits are tables built once.

local hdc = {}

hdc.BITS = 8192
local B = hdc.BITS / 8          -- bytes a vector
local TWO32 = 4294967296

-- The tables: XOR[a * 256 + b + 1] = a xor b, DIFF[...] = the bits in which a and b differ,
-- BIT[a * 8 + k + 1] = bit k of a.
local XOR, DIFF, BIT = {}, {}, {}
do
  local pop = {}
  for a = 0, 255 do
    local n, x = 0, a
    for k = 0, 7 do
      local bit = x % 2
      BIT[a * 8 + k + 1] = bit
      n = n + bit
      x = (x - bit) / 2
    end
    pop[a] = n
  end
  for a = 0, 255 do
    for b = 0, 255 do
      local x, y, out, place = a, b, 0, 1
      for _ = 0, 7 do
        local p, q = x % 2, y % 2
        if p ~= q then out = out + place end
        x, y, place = (x - p) / 2, (y - q) / 2, place * 2
      end
      XOR[a * 256 + b + 1] = out
      DIFF[a * 256 + b + 1] = pop[out]
    end
  end
end

-- A generator of 32-bit numbers. The product stays under 2^53, so it is exact as a double
-- (LuaJIT) and as an integer (Lua 5.4 and 5.5).
local function step(x)
  return (1664525 * x + 1013904223) % TWO32
end

-- A name's seed: a rolling hash of its bytes, then the generator run a while so two names
-- that differ in one byte are not near.
local function seed_of(name)
  local h = 2166136261
  for i = 1, #name do h = (h * 31 + name:byte(i) + 1) % TWO32 end
  h = (h + #name * 2654435) % TWO32
  for _ = 1, 16 do h = step(h) end
  return h
end

-- The top byte of each number the generator makes, `n` of them from `name`.
local function stream(name, n)
  local x, out = seed_of(name), {}
  for i = 1, n do
    x = step(x)
    local y = step((x + i * 40503) % TWO32)
    out[i] = math.floor(y / 16777216)
  end
  return out
end

local atoms = {}

--- The vector for a name. The same name is always the same vector.
function hdc.atom(name)
  name = tostring(name)
  local v = atoms[name]
  if not v then
    v = stream("atom:" .. name, B)
    atoms[name] = v
  end
  return v
end

--- The bits where `a` and `b` differ, set: binding. Binding with the same vector again undoes it.
function hdc.bind(a, b)
  local out = {}
  for i = 1, B do out[i] = XOR[a[i] * 256 + b[i] + 1] end
  return out
end

-- Ties in a bundle of an even number are broken by this vector's bits.
local TIE = stream("tie", B)

--- The majority of each bit across `list`: a vector near every member. `weights`, if
--- given, counts a member that many times.
function hdc.bundle(list, weights)
  local count, total = {}, 0
  for i = 1, hdc.BITS do count[i] = 0 end
  for m = 1, #list do
    local v, w = list[m], weights and weights[m] or 1
    total = total + w
    for i = 1, B do
      local byte, at = v[i] * 8, (i - 1) * 8
      for k = 1, 8 do
        if BIT[byte + k] == 1 then count[at + k] = count[at + k] + w end
      end
    end
  end
  local out = {}
  for i = 1, B do
    local byte, at, place, tie = 0, (i - 1) * 8, 1, TIE[i] * 8
    for k = 1, 8 do
      local c = count[at + k] * 2
      if c > total or (c == total and BIT[tie + k] == 1) then byte = byte + place end
      place = place * 2
    end
    out[i] = byte
  end
  return out
end

--- The share of bits `a` and `b` agree on: 1 the same, 0.5 unrelated, 0 opposite.
function hdc.similarity(a, b)
  local d = 0
  for i = 1, B do d = d + DIFF[a[i] * 256 + b[i] + 1] end
  return 1 - d / hdc.BITS
end

-- The order a level family flips its bits in: a shuffle of every bit, from the name.
local orders = {}
local function order_of(name)
  local o = orders[name]
  if o then return o end
  o = {}
  for i = 1, hdc.BITS do o[i] = i - 1 end
  local x = seed_of("order:" .. name)
  for i = hdc.BITS, 2, -1 do
    x = step(x)
    local j = math.floor(x / TWO32 * i) + 1
    o[i], o[j] = o[j], o[i]
  end
  orders[name] = o
  return o
end

local levels = {}

--- The vector for value `i` of `n` on a circle: neighbours share most of their bits, and
--- values a quarter of the circle or more apart are unrelated. Used for an hour of the day
--- (24) and a day (64), so 23:00 is near 00:00.
function hdc.level(name, i, n)
  i = math.floor(i) % n
  local key = name .. "#" .. n .. "#" .. i
  if levels[key] then return levels[key] end
  local base, o = hdc.atom("level:" .. name), order_of(name)
  local v = {}
  for k = 1, B do v[k] = base[k] end
  local start = math.floor(i * hdc.BITS / n)
  for j = 0, hdc.BITS / 4 - 1 do
    local p = o[(start + j) % hdc.BITS + 1]
    local at = math.floor(p / 8) + 1
    local k = p % 8
    local byte = v[at]
    local bit = BIT[byte * 8 + k + 1]
    local place = 2 ^ k
    v[at] = bit == 1 and byte - place or byte + place
  end
  for k = 1, B do v[k] = math.floor(v[k]) end
  levels[key] = v
  return v
end

local HEX = {}
for b = 0, 255 do HEX[b] = string.format("%02x", b) end

--- The vector as 2048 hex digits, for a file.
function hdc.hex(v)
  local parts = {}
  for i = 1, B do parts[i] = HEX[v[i]] end
  return table.concat(parts)
end

--- A vector from its hex, or nil and why.
function hdc.from_hex(s)
  if type(s) ~= "string" or #s ~= B * 2 or s:find("[^0-9a-f]") then
    return nil, "a hypervector is " .. (B * 2) .. " hex digits"
  end
  local v = {}
  for i = 1, B do v[i] = tonumber(s:sub(i * 2 - 1, i * 2), 16) end
  return v
end

return hdc
