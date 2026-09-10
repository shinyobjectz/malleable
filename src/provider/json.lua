-- The json port: the tree's own pure-Lua encoder and decoder.
--
--   json.encode(v) -> string | nil, err
--   json.decode(s) -> value  | nil, err
--
-- It is a port in `spec/provider.md`'s sense: a wrong argument type raises, and
-- anything the input can do to it comes back as `nil, err` with a code from
-- `port.codes` -- `malformed` for text it cannot read or a value it cannot write,
-- `too_big` for input over `json.cap`.
--
-- Two deliberate properties, both of which the provider leans on:
--
--   * Object keys are emitted in sorted order, so encoding the same table twice gives
--     the same bytes. A body that is deterministic as a table is then deterministic as
--     a string, and a test can assert on the string.
--   * An empty table encodes as `{}`, an object. The ambiguity is real and unfixable
--     in Lua, which is why the provider's rule is that no body it builds ever contains
--     one -- see `spec/provider.md` §3. Nothing here has to guess.
--
-- JSON null decodes to `json.null`, a unique sentinel, rather than to nil: a nil in
-- the middle of a decoded array would put a hole in it and `#` would start lying. The
-- provider type-checks every field it reads, so the sentinel falls out on its own.

local port = require "port"

local json = {}

-- Roughly eight megabytes. Big enough for any completion, small enough that a proxy
-- streaming an infinite error page cannot exhaust the process.
json.cap = 8 * 1024 * 1024

json.null = setmetatable({}, { __tostring = function () return "null" end })

local function fail(call, code, message)
  return nil, port.error("json", call, code, message)
end

-- ------------------------------------------------------------------------- encoding

local escape = {
  ['"']  = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function escape_char(c)
  local e = escape[c]
  if e then return e end
  return string.format("\\u%04x", string.byte(c))
end

local function quote(s)
  -- Control characters and the two structural characters only. Everything else,
  -- including UTF-8, travels as itself.
  return '"' .. s:gsub('[%c"\\]', escape_char) .. '"'
end

local function number_text(v)
  if v ~= v then return nil, "a not-a-number cannot be written as JSON" end
  if v == math.huge or v == -math.huge then
    return nil, "an infinity cannot be written as JSON"
  end
  if v == math.floor(v) and v < 1e15 and v > -1e15 then
    return string.format("%d", v)
  end
  return string.format("%.14g", v)
end

-- Which of the two JSON shapes a table is. A table with no keys at all is an object,
-- stated once here rather than guessed at each call site.
local function shape_of(t)
  local n, keys = 0, 0
  for k in pairs(t) do
    keys = keys + 1
    if type(k) == "number" then
      if k ~= math.floor(k) or k < 1 then
        return nil, "a table with the numeric key " .. tostring(k) .. " is neither an object nor an array"
      end
      if k > n then n = k end
    elseif type(k) ~= "string" then
      return nil, "a table keyed by a " .. type(k) .. " cannot be written as JSON"
    end
  end
  if keys == 0 then return "object" end
  if n == 0 then return "object" end
  if n == keys then return "array" end
  return nil, "a table with both string and number keys is neither an object nor an array"
end

local write

local function write_array(t, out, seen)
  out[#out + 1] = "["
  for i = 1, #t do
    if i > 1 then out[#out + 1] = "," end
    local ok, why = write(t[i], out, seen)
    if not ok then return nil, why end
  end
  out[#out + 1] = "]"
  return true
end

local function write_object(t, out, seen)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  out[#out + 1] = "{"
  for i = 1, #keys do
    if i > 1 then out[#out + 1] = "," end
    out[#out + 1] = quote(keys[i])
    out[#out + 1] = ":"
    local v = t[keys[i]]
    if v == nil then v = t[tonumber(keys[i])] end
    local ok, why = write(v, out, seen)
    if not ok then return nil, why end
  end
  out[#out + 1] = "}"
  return true
end

write = function (v, out, seen)
  if v == json.null then
    out[#out + 1] = "null"
    return true
  end
  local t = type(v)
  if t == "string" then
    out[#out + 1] = quote(v)
    return true
  elseif t == "number" then
    local text, why = number_text(v)
    if not text then return nil, why end
    out[#out + 1] = text
    return true
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
    return true
  elseif t == "table" then
    if seen[v] then return nil, "a table that contains itself cannot be written as JSON" end
    seen[v] = true
    local shape, why = shape_of(v)
    if not shape then
      seen[v] = nil
      return nil, why
    end
    local ok
    if shape == "array" then
      ok, why = write_array(v, out, seen)
    else
      ok, why = write_object(v, out, seen)
    end
    seen[v] = nil
    if not ok then return nil, why end
    return true
  end
  return nil, "a " .. t .. " cannot be written as JSON"
end

function json.encode(v)
  local out = {}
  local ok, why = write(v, out, {})
  if not ok then return fail("encode", "malformed", why) end
  local s = table.concat(out)
  if #s > json.cap then
    return fail("encode", "too_big", string.format("the encoded value is over the %d byte limit", json.cap))
  end
  return s
end

-- ------------------------------------------------------------------------- decoding

local space = { [" "] = true, ["\t"] = true, ["\n"] = true, ["\r"] = true }

local literals = { ["true"] = true, ["false"] = false, ["null"] = json.null }

local function skip(s, i)
  while i <= #s and space[s:sub(i, i)] do i = i + 1 end
  return i
end

-- A code point as UTF-8, by arithmetic rather than by bit operations: LuaJIT is in the
-- dialect and has no operators for them.
local function utf8_char(c)
  if c < 0x80 then
    return string.char(c)
  elseif c < 0x800 then
    return string.char(0xC0 + math.floor(c / 64), 0x80 + (c % 64))
  elseif c < 0x10000 then
    return string.char(0xE0 + math.floor(c / 4096),
                       0x80 + (math.floor(c / 64) % 64),
                       0x80 + (c % 64))
  end
  return string.char(0xF0 + math.floor(c / 262144),
                     0x80 + (math.floor(c / 4096) % 64),
                     0x80 + (math.floor(c / 64) % 64),
                     0x80 + (c % 64))
end

local unescape = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function read_string(s, i)
  -- i is at the opening quote.
  local out, at = {}, i + 1
  while true do
    if at > #s then return nil, nil, "a string was not closed" end
    local c = s:sub(at, at)
    if c == '"' then
      return table.concat(out), at + 1
    elseif c == "\\" then
      local e = s:sub(at + 1, at + 1)
      if e == "" then return nil, nil, "a string ended in a backslash" end
      if e == "u" then
        local hex = s:sub(at + 2, at + 5)
        if not hex:match("^%x%x%x%x$") then
          return nil, nil, string.format("a \\u escape at byte %d is not four hex digits", at)
        end
        local c1 = tonumber(hex, 16)
        at = at + 6
        -- A surrogate pair is two escapes; a lone high surrogate is written through as
        -- the replacement character rather than refused, because a model that emits one
        -- has still said something the harness can act on.
        if c1 >= 0xD800 and c1 <= 0xDBFF then
          local hex2 = s:sub(at + 2, at + 5)
          if s:sub(at, at + 1) == "\\u" and hex2:match("^%x%x%x%x$") then
            local c2 = tonumber(hex2, 16)
            if c2 >= 0xDC00 and c2 <= 0xDFFF then
              c1 = 0x10000 + (c1 - 0xD800) * 1024 + (c2 - 0xDC00)
              at = at + 6
            else
              c1 = 0xFFFD
            end
          else
            c1 = 0xFFFD
          end
        elseif c1 >= 0xDC00 and c1 <= 0xDFFF then
          c1 = 0xFFFD
        end
        out[#out + 1] = utf8_char(c1)
      else
        local u = unescape[e]
        if not u then
          return nil, nil, string.format("\\%s at byte %d is not an escape JSON knows", e, at)
        end
        out[#out + 1] = u
        at = at + 2
      end
    elseif c < " " then
      return nil, nil, string.format("a raw control character at byte %d is not allowed in a string", at)
    else
      -- Take the whole run of ordinary bytes at once; a character-at-a-time loop makes
      -- a long completion quadratic.
      local stop = s:find('["\\%c]', at)
      if not stop then return nil, nil, "a string was not closed" end
      out[#out + 1] = s:sub(at, stop - 1)
      at = stop
    end
  end
end

local read_value

local function read_array(s, i, depth)
  local out, at = {}, skip(s, i + 1)
  if s:sub(at, at) == "]" then return out, at + 1 end
  while true do
    local v, next_at, why = read_value(s, at, depth + 1)
    if next_at == nil then return nil, nil, why end
    out[#out + 1] = v
    at = skip(s, next_at)
    local c = s:sub(at, at)
    if c == "," then
      at = skip(s, at + 1)
    elseif c == "]" then
      return out, at + 1
    else
      return nil, nil, string.format("byte %d: an array wants a comma or a closing bracket", at)
    end
  end
end

local function read_object(s, i, depth)
  local out, at = {}, skip(s, i + 1)
  if s:sub(at, at) == "}" then return out, at + 1 end
  while true do
    if s:sub(at, at) ~= '"' then
      return nil, nil, string.format("byte %d: an object key is a quoted string", at)
    end
    local key, next_at, why = read_string(s, at)
    if next_at == nil then return nil, nil, why end
    at = skip(s, next_at)
    if s:sub(at, at) ~= ":" then
      return nil, nil, string.format("byte %d: an object key wants a colon after it", at)
    end
    local v
    v, next_at, why = read_value(s, skip(s, at + 1), depth + 1)
    if next_at == nil then return nil, nil, why end
    out[key] = v
    at = skip(s, next_at)
    local c = s:sub(at, at)
    if c == "," then
      at = skip(s, at + 1)
    elseif c == "}" then
      return out, at + 1
    else
      return nil, nil, string.format("byte %d: an object wants a comma or a closing brace", at)
    end
  end
end

read_value = function (s, i, depth)
  if depth > 200 then
    return nil, nil, "the value is nested deeper than this decoder will go"
  end
  local c = s:sub(i, i)
  if c == "" then return nil, nil, "the text ended where a value was expected" end
  if c == '"' then return read_string(s, i) end
  if c == "{" then return read_object(s, i, depth) end
  if c == "[" then return read_array(s, i, depth) end
  if c == "-" or c:match("%d") then
    local text = s:match("^%-?%d+%.?%d*[eE]?[-+]?%d*", i)
    local n = text and tonumber(text)
    if not n then
      return nil, nil, string.format("byte %d: that is not a number JSON can read", i)
    end
    return n, i + #text
  end
  for word, v in pairs(literals) do
    if s:sub(i, i + #word - 1) == word then return v, i + #word end
  end
  return nil, nil, string.format("byte %d: %q begins no value JSON knows", i, c)
end

function json.decode(s)
  if type(s) ~= "string" then
    error("json.decode: `s` is a string, got " .. type(s), 2)
  end
  if #s > json.cap then
    return fail("decode", "too_big", string.format("the text is over the %d byte limit", json.cap))
  end
  local at = skip(s, 1)
  if at > #s then
    return fail("decode", "malformed", "there was nothing to decode")
  end
  local v, next_at, why = read_value(s, at, 1)
  if next_at == nil then
    return fail("decode", "malformed", why)
  end
  next_at = skip(s, next_at)
  if next_at <= #s then
    return fail("decode", "malformed",
      string.format("byte %d: there is more text after the value ended", next_at))
  end
  if v == nil then return json.null end
  return v
end

return json
