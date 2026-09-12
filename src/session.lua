-- session -- the conversation as data.
--
-- An append-only list of messages as plain tables: the standing instruction, what the
-- person asked, what the model said, every tool call and result. It serialises to JSON and
-- back byte for byte, so a run can be saved and resumed in a later process. There is no
-- JSON library to lean on, so the encoder and decoder live here and are part of the
-- contract.
--
--   * a wrong argument type RAISES
--   * bad data RETURNS nil, reason -- a transcript that will not decode, a store that will
--     not answer, a tool result that cannot be encoded
--
-- Nothing here returns false for failure, keeps global state, reads the agent table, calls
-- a tool body, removes a message, or reaches the world except through the port table.

local session = {}

local fmt    = string.format
local sub    = string.sub
local find   = string.find
local gsub   = string.gsub
local byte   = string.byte
local char   = string.char
local concat = table.concat
local sort   = table.sort
local floor  = math.floor
local big    = math.huge
local numkind = math.type          -- 5.4 tells integer from float; 5.1 has no distinction

-- The nesting limit, both directions. Read-only by convention.
session.max_depth = 200

-- A unique table standing for JSON null. Lua cannot hold nil as a table value, so
-- without a sentinel {"a":null} would decode to {} and the key would vanish.
session.null = setmetatable({}, { __tostring = function () return "null" end })

-- raising

-- `level` counts the way error() does from inside `raise`: 1 this line, 2 the want_
-- helper, 3 the public function, 4 its caller. Raising through a helper passes 4, raising
-- directly passes 3; either way the blame lands on the caller.
local function raise(level, what, ...)
  error(fmt(what, ...), level)
end

local function want_session(where, s, level)
  if type(s) ~= "table" or type(s.messages) ~= "table" then
    raise(level, "%s: the first argument is a session from session.new, got %s", where, type(s))
  end
end

local function want_string(where, what, v, level)
  if type(v) ~= "string" then
    raise(level, "%s: `%s` is a string, got %s", where, what, type(v))
  end
end

local function want_number(where, what, v, level)
  if type(v) ~= "number" then
    raise(level, "%s: `%s` is a number, got %s", where, what, type(v))
  end
end

local function want_port(where, port, group, fn, level)
  if type(port) ~= "table" then
    raise(level, "%s: the port is a table of ports, got %s", where, type(port))
  end
  local g = port[group]
  if type(g) ~= "table" then
    raise(level, "%s: the port has no %s", where, group)
  end
  if type(g[fn]) ~= "function" then
    raise(level, "%s: the port has no %s.%s", where, group, fn)
  end
end

-- copying

-- A private copy, cycles and sharing kept, done with an explicit stack so a hostile
-- depth cannot overflow anything. The null sentinel is passed through by identity: a
-- copy of it would no longer be it.
local function deep_copy(v)
  if type(v) ~= "table" or v == session.null then return v end
  local root = {}
  local seen = { [v] = root }
  local stack = { { v, root } }
  local top = 1
  while top > 0 do
    local job = stack[top]
    stack[top] = nil
    top = top - 1
    local src, dst = job[1], job[2]
    for k, val in pairs(src) do
      if type(val) == "table" and val ~= session.null then
        local c = seen[val]
        if c == nil then
          c = {}
          seen[val] = c
          top = top + 1
          stack[top] = { val, c }
        end
        dst[k] = c
      else
        dst[k] = val
      end
    end
  end
  return root
end

-- the shapes

local SPEAKERS = { system = true, user = true, model = true, call = true, result = true }

-- speaker -> the fields it must have, and their types.
local SHAPE = {
  system = { { "body", "string" }, { "at", "number" } },
  user   = { { "body", "string" }, { "at", "number" } },
  model  = { { "body", "string" }, { "at", "number" } },
  call   = { { "tool", "string" }, { "args", "table" }, { "call_id", "string" }, { "at", "number" } },
  result = { { "call_id", "string" }, { "body", "string" }, { "ok", "boolean" },
             { "refused", "boolean" }, { "at", "number" } },
}

-- speaker -> the complete set of keys a message may carry. A field session does not
-- round-trip is a field that disappears on resume, so an extra key is refused.
local KNOWN = {}
for speaker, fields in pairs(SHAPE) do
  local k = { speaker = true }
  for i = 1, #fields do k[fields[i][1]] = true end
  KNOWN[speaker] = k
end

local function copy_message(m)
  local out = { speaker = m.speaker, at = m.at }
  local fields = SHAPE[m.speaker]
  for i = 1, #fields do
    local name = fields[i][1]
    if name == "args" then
      out.args = deep_copy(m.args)
    elseif name ~= "at" then
      out[name] = m[name]
    end
  end
  return out
end

-- Field validation alone: no history, no linkage. Returns a private copy.
local function check_message(msg)
  if type(msg) ~= "table" then
    return nil, "a message is a table, not a " .. type(msg)
  end
  local speaker = msg.speaker
  if speaker == nil then return nil, "a message has no speaker" end
  if type(speaker) ~= "string" then
    return nil, "a speaker is a string, not a " .. type(speaker)
  end
  if not SPEAKERS[speaker] then
    return nil, fmt("unknown speaker %q", speaker)
  end

  local fields = SHAPE[speaker]
  for i = 1, #fields do
    local name, want = fields[i][1], fields[i][2]
    local v = msg[name]
    if v == nil then
      return nil, fmt("a %s message has no %q", speaker, name)
    end
    if type(v) ~= want then
      return nil, fmt("%q is a %s, not a %s", name, want, type(v))
    end
  end

  local known = KNOWN[speaker]
  for k in pairs(msg) do
    if not known[k] then
      return nil, fmt("message has an unknown field %q", tostring(k))
    end
  end

  if speaker == "call" then
    if msg.tool == "" then return nil, "a call names no tool" end
    if msg.call_id == "" then return nil, "a call has an empty call_id" end
  elseif speaker == "result" then
    if msg.call_id == "" then return nil, "a result has an empty call_id" end
    if msg.refused and msg.ok then return nil, "a refused call did not succeed" end
  end

  return copy_message(msg)
end

-- Which calls have been made and which of them have been answered. Held in a value the
-- caller passes along rather than anywhere in this module, so two sessions in one
-- process see nothing of each other.
local function new_links()
  return { made = {}, answered = {} }
end

local function check_link(m, links)
  if m.speaker == "call" then
    if links.made[m.call_id] then
      return nil, fmt("call %q is already in this session", m.call_id)
    end
  elseif m.speaker == "result" then
    if not links.made[m.call_id] then
      return nil, fmt("no open call %q", m.call_id)
    end
    if links.answered[m.call_id] then
      return nil, fmt("call %q already has a result", m.call_id)
    end
  end
  return true
end

local function apply_link(m, links)
  if m.speaker == "call" then
    links.made[m.call_id] = true
  elseif m.speaker == "result" then
    links.answered[m.call_id] = true
  end
end

local function links_of(s)
  local links = new_links()
  local ms = s.messages
  for i = 1, #ms do apply_link(ms[i], links) end
  return links
end

-- building

function session.new(t)
  local s = { id = nil, agent = nil, model = nil, started = nil, messages = {} }
  if t ~= nil then
    if type(t) ~= "table" then
      raise(3, "session.new takes a table of id, agent, model and started, got %s", type(t))
    end
    for k, v in pairs(t) do
      if k == "id" or k == "agent" or k == "model" then
        if type(v) ~= "string" then
          raise(3, "session.new: `%s` is a string, got %s", k, type(v))
        end
        s[k] = v
      elseif k == "started" then
        if type(v) ~= "number" then
          raise(3, "session.new: `started` is a number, got %s", type(v))
        end
        s.started = v
      else
        raise(3, "session.new does not know the field %q", tostring(k))
      end
    end
  end
  return s
end

function session.set_id(s, id)
  want_session("session.set_id", s, 4)
  want_string("session.set_id", "id", id, 4)
  if id == "" then raise(3, "session.set_id: an id is a non-empty string") end
  if s.id ~= nil and s.id ~= id then
    return nil, fmt("this session is already %q", s.id)
  end
  s.id = id
  return true
end

function session.append(s, msg)
  want_session("session.append", s, 4)
  if type(msg) ~= "table" then
    raise(3, "session.append: a message is a table, got %s", type(msg))
  end
  local m, why = check_message(msg)
  if m == nil then return nil, why end
  local links = links_of(s)
  local ok, why2 = check_link(m, links)
  if ok == nil then return nil, why2 end
  s.messages[#s.messages + 1] = m
  return copy_message(m)
end

local function said(where, s, speaker, text, at)
  want_session(where, s, 4)
  want_string(where, "text", text, 4)
  want_number(where, "at", at, 4)
  return session.append(s, { speaker = speaker, body = text, at = at })
end

function session.system(s, text, at) return said("session.system", s, "system", text, at) end
function session.user(s, text, at)   return said("session.user",   s, "user",   text, at) end
function session.model(s, text, at)  return said("session.model",  s, "model",  text, at) end

function session.call(s, tool, args, call_id, at)
  want_session("session.call", s, 4)
  want_string("session.call", "tool", tool, 4)
  if args ~= nil and type(args) ~= "table" then
    raise(3, "session.call: `args` is a table or nil, got %s", type(args))
  end
  want_string("session.call", "call_id", call_id, 4)
  want_number("session.call", "at", at, 4)
  return session.append(s, {
    speaker = "call", tool = tool, args = args or {}, call_id = call_id, at = at,
  })
end

function session.result(s, call_id, body, opts, at)
  want_session("session.result", s, 4)
  want_string("session.result", "call_id", call_id, 4)
  want_string("session.result", "body", body, 4)
  local ok, refused = true, false
  if opts ~= nil then
    if type(opts) ~= "table" then
      raise(3, "session.result: `opts` is a table of ok and refused, or nil, got %s", type(opts))
    end
    for k, v in pairs(opts) do
      if k ~= "ok" and k ~= "refused" then
        raise(3, "session.result does not know the option %q", tostring(k))
      end
      if type(v) ~= "boolean" then
        raise(3, "session.result: `%s` is true or false, got %s", k, type(v))
      end
    end
    if opts.ok ~= nil then ok = opts.ok end
    if opts.refused ~= nil then refused = opts.refused end
  end
  want_number("session.result", "at", at, 4)
  return session.append(s, {
    speaker = "result", call_id = call_id, body = body, ok = ok, refused = refused, at = at,
  })
end

-- reading

function session.count(s)
  want_session("session.count", s, 4)
  return #s.messages
end

function session.at(s, i)
  want_session("session.at", s, 4)
  want_number("session.at", "i", i, 4)
  local n = #s.messages
  if i < 0 then i = n + 1 + i end
  if i ~= floor(i) or i < 1 or i > n then return nil end
  return copy_message(s.messages[i])
end

function session.messages(s)
  want_session("session.messages", s, 4)
  local out = {}
  for i = 1, #s.messages do out[i] = copy_message(s.messages[i]) end
  return out
end

function session.last(s, speaker)
  want_session("session.last", s, 4)
  if speaker ~= nil then
    if type(speaker) ~= "string" then
      raise(3, "session.last: `speaker` is a speaker name or nil, got %s", type(speaker))
    end
    if not SPEAKERS[speaker] then
      raise(3, "session.last: %q is not one of system, user, model, call, result", speaker)
    end
  end
  local ms = s.messages
  for i = #ms, 1, -1 do
    if speaker == nil or ms[i].speaker == speaker then return copy_message(ms[i]) end
  end
  return nil
end

-- The calls with no matching result, in the order they were made. What resume is for:
-- the loop decides whether to re-issue or to write a result saying the run was cut off.
-- Reporting is all this does.
function session.pending(s)
  want_session("session.pending", s, 4)
  local links = links_of(s)
  local out = {}
  local ms = s.messages
  for i = 1, #ms do
    local m = ms[i]
    if m.speaker == "call" and not links.answered[m.call_id] then
      out[#out + 1] = copy_message(m)
    end
  end
  return out
end

function session.header(s)
  want_session("session.header", s, 4)
  return { id = s.id, agent = s.agent, model = s.model, started = s.started, count = #s.messages }
end

-- encoding

local ESCAPE = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\t'] = '\\t',
  ['\n'] = '\\n', ['\f'] = '\\f', ['\r'] = '\\r',
}

-- `/` is never escaped. 0x7f is a byte like any other. Bytes at 0x80 and above go out
-- verbatim, unexamined: a tool that read a binary file must survive being written into
-- a transcript, and re-reading its bytes as codepoints would corrupt them.
local function escape_byte(c)
  local e = ESCAPE[c]
  if e then return e end
  local b = byte(c)
  if b < 32 then return fmt("\\u%04x", b) end
  return c
end

local function encode_string(v)
  return '"' .. gsub(v, '[%c\\"]', escape_byte) .. '"'
end

local function where(path)
  if path == "" then return "the top level" end
  return path
end

local WIDTHS = { "%.14g", "%.15g", "%.16g", "%.17g" }

-- An integer goes out bare; a float always carries a `.` or an `e`, so the 5.4
-- integer/float distinction survives the round trip. The shortest width that reads back
-- identically wins, so 0.1 is 0.1 and still exact.
local function encode_number(v, path)
  if v ~= v then return nil, "not a number: nan at " .. where(path) end
  if v == big then return nil, "not a number: inf at " .. where(path) end
  if v == -big then return nil, "not a number: -inf at " .. where(path) end
  local whole
  if numkind then
    whole = (numkind(v) == "integer")
  else
    -- 5.1 has one number type, so an integral value is an integer -- except negative
    -- zero, which is a float whose sign a bare 0 would throw away.
    whole = (v == floor(v) and v >= -1e15 and v <= 1e15 and not (v == 0 and 1 / v < 0))
  end
  if whole then return fmt("%d", v) end
  for i = 1, #WIDTHS do
    local text = fmt(WIDTHS[i], v)
    if tonumber(text) == v then
      if not find(text, "[%.eE]") then text = text .. ".0" end
      return text
    end
  end
  return fmt("%.17g", v)
end

local function show_key(k)
  if type(k) == "string" then return fmt("%q", k) end
  return tostring(k)
end

-- What kind of table this is, or why it is neither. An empty table is an object, which
-- is the one documented loss through a round trip.
local function classify(t, path)
  local strings, indexes, top = 0, 0, 0
  local low_string, low_index
  for k in pairs(t) do
    local kt = type(k)
    if kt == "string" then
      strings = strings + 1
      if low_string == nil or k < low_string then low_string = k end
    elseif kt == "number" and k == floor(k) and k >= 1 and k < 2147483648 then
      indexes = indexes + 1
      if k > top then top = k end
      if low_index == nil or k < low_index then low_index = k end
    else
      return nil, fmt("the key %s at %s is neither a string nor an index", show_key(k), where(path))
    end
  end
  if strings > 0 and indexes > 0 then
    return nil, fmt("a mixed table at %s: the key %s alongside the item %s",
                    where(path), show_key(low_string), tostring(low_index))
  end
  if indexes > 0 then
    if top ~= indexes then
      for i = 1, top do
        if t[i] == nil then
          return nil, fmt("a sparse array at %s: no item %d", where(path), i)
        end
      end
    end
    return "array", indexes
  end
  return "object", strings
end

local function encode_value(v, out, path, depth, active)
  if v == session.null then
    out[#out + 1] = "null"
    return true
  end
  local t = type(v)
  if t == "string" then
    out[#out + 1] = encode_string(v)
    return true
  elseif t == "number" then
    local text, why = encode_number(v, path)
    if text == nil then return nil, why end
    out[#out + 1] = text
    return true
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
    return true
  elseif t ~= "table" then
    return nil, fmt("cannot encode a %s at %s", t, where(path))
  end

  -- A value containing itself is a cycle, refused by identity. A value reached twice by
  -- two paths is not, and is written twice.
  if active[v] then return nil, "cycle at " .. where(path) end
  if depth > session.max_depth then return nil, "too deep at " .. where(path) end

  local kind, count = classify(v, path)
  if kind == nil then return nil, count end

  active[v] = true
  if kind == "array" then
    out[#out + 1] = "["
    for i = 1, count do
      if i > 1 then out[#out + 1] = "," end
      local ok, why = encode_value(v[i], out, path .. "[" .. i .. "]", depth + 1, active)
      if ok == nil then active[v] = nil; return nil, why end
    end
    out[#out + 1] = "]"
  else
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    sort(keys)
    out[#out + 1] = "{"
    for i = 1, #keys do
      if i > 1 then out[#out + 1] = "," end
      out[#out + 1] = encode_string(keys[i])
      out[#out + 1] = ":"
      local ok, why = encode_value(v[keys[i]], out, path .. "." .. keys[i], depth + 1, active)
      if ok == nil then active[v] = nil; return nil, why end
    end
    out[#out + 1] = "}"
  end
  active[v] = nil
  return true
end

-- The one entry point. `depth` says where the value sits in the document being
-- written, so a value encoded on its own and the same value encoded inside a record
-- reach the nesting limit at exactly the same place. Without it, save would happily
-- write a record that decode then refuses as too deep.
local function encode_at(v, depth)
  local out = {}
  local ok, why = encode_value(v, out, "", depth, {})
  if ok == nil then return nil, why end
  return concat(out)
end

-- Deterministic: the same value encodes to the same bytes every time, because object
-- keys go out in byte order. No whitespace between tokens.
function session.encode(v)
  return encode_at(v, 1)
end

-- decoding

local SIMPLE = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
  b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function utf8_bytes(cp)
  if cp < 0x80 then return char(cp) end
  if cp < 0x800 then
    return char(192 + floor(cp / 64), 128 + cp % 64)
  end
  if cp < 0x10000 then
    return char(224 + floor(cp / 4096), 128 + floor(cp / 64) % 64, 128 + cp % 64)
  end
  return char(240 + floor(cp / 262144), 128 + floor(cp / 4096) % 64,
              128 + floor(cp / 64) % 64, 128 + cp % 64)
end

local function show_byte(c)
  local b = byte(c)
  if b == nil or b < 32 or b > 126 then return fmt("\\x%02x", b or 0) end
  return c
end

-- Strict: JSON and only JSON, every refusal carrying a byte offset. Nesting is a
-- counter over an explicit stack, not recursion, so a file of a hundred thousand
-- open brackets produces a reason rather than a stack overflow.
function session.decode(text)
  if type(text) ~= "string" then
    error(fmt("session.decode takes the record text as a string, got %s", type(text)), 2)
  end

  local n = #text
  local i = 1

  local function at(pos, what, ...)
    return nil, fmt(what, ...) .. " at byte " .. pos
  end

  local function skip_ws()
    while i <= n do
      local c = byte(text, i)
      if c == 32 or c == 9 or c == 10 or c == 13 then i = i + 1 else break end
    end
  end

  local function read_hex(from)
    local hex = sub(text, from, from + 3)
    if #hex < 4 or find(hex, "%X") then return nil end
    return tonumber(hex, 16)
  end

  local function read_string()
    i = i + 1                                  -- the opening quote
    local buf, bn = {}, 0
    while true do
      local j = find(text, '[%c"\\]', i)
      if j == nil then return at(n + 1, "unexpected end of input") end
      if j > i then
        bn = bn + 1
        buf[bn] = sub(text, i, j - 1)
      end
      local c = byte(text, j)
      if c == 34 then
        i = j + 1
        return concat(buf)
      elseif c == 92 then
        local e = sub(text, j + 1, j + 1)
        if e == "" then return at(j + 1, "unexpected end of input") end
        if e == "u" then
          local cp = read_hex(j + 2)
          if cp == nil then return at(j, "a broken \\u escape") end
          i = j + 6
          if cp >= 0xD800 and cp <= 0xDBFF then
            if sub(text, i, i + 1) ~= "\\u" then return at(j, "a lone surrogate") end
            local lo = read_hex(i + 2)
            if lo == nil then return at(i, "a broken \\u escape") end
            if lo < 0xDC00 or lo > 0xDFFF then return at(j, "a lone surrogate") end
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          elseif cp >= 0xDC00 and cp <= 0xDFFF then
            return at(j, "a lone surrogate")
          end
          bn = bn + 1
          buf[bn] = utf8_bytes(cp)
        else
          local lit = SIMPLE[e]
          if lit == nil then return at(j, "an unknown escape \\%s", show_byte(e)) end
          bn = bn + 1
          buf[bn] = lit
          i = j + 2
        end
      elseif c < 32 then
        return at(j, "a control byte in a string")
      else
        bn = bn + 1                            -- 0x7f, a byte like any other
        buf[bn] = sub(text, j, j)
        i = j + 1
      end
    end
  end

  local function digits()
    local c = byte(text, i)
    while c ~= nil and c >= 48 and c <= 57 do
      i = i + 1
      c = byte(text, i)
    end
  end

  local function read_number()
    local start = i
    if byte(text, i) == 45 then i = i + 1 end
    local c = byte(text, i)
    if c == nil then return at(i, "unexpected end of input") end
    if c == 48 then
      local zero = i
      i = i + 1
      local d = byte(text, i)
      if d ~= nil and d >= 48 and d <= 57 then return at(zero, "a leading zero") end
    elseif c >= 49 and c <= 57 then
      digits()
    else
      return at(i, "unexpected character '%s'", show_byte(sub(text, i, i)))
    end
    if byte(text, i) == 46 then
      i = i + 1
      local d = byte(text, i)
      if d == nil or d < 48 or d > 57 then
        return at(i, "a number needs a digit after the decimal point")
      end
      digits()
    end
    local e = byte(text, i)
    if e == 101 or e == 69 then
      i = i + 1
      local s = byte(text, i)
      if s == 43 or s == 45 then i = i + 1 end
      local d = byte(text, i)
      if d == nil or d < 48 or d > 57 then
        return at(i, "a number needs a digit in the exponent")
      end
      digits()
    end
    local v = tonumber(sub(text, start, i - 1))
    if v == nil then return at(start, "not a number") end
    if v == big or v == -big then return at(start, "number out of range") end
    return v
  end

  local stack, top = {}, 0
  local state = "value"
  local result

  local function finish(v)
    if top == 0 then
      result = v
      state = "done"
      return
    end
    local frame = stack[top]
    if frame.array then
      frame.n = frame.n + 1
      frame.value[frame.n] = v
      state = "after_item"
    else
      frame.value[frame.key] = v
      state = "after_member"
    end
  end

  local function close()
    local frame = stack[top]
    stack[top] = nil
    top = top - 1
    finish(frame.value)
  end

  while state ~= "done" do
    skip_ws()
    local c = sub(text, i, i)

    if state == "value" or state == "first_item" then
      if c == "" then
        return at(i, "unexpected end of input")
      elseif state == "first_item" and c == "]" then
        i = i + 1
        close()
      elseif c == "{" then
        if top >= session.max_depth then return at(i, "too deep") end
        i = i + 1
        top = top + 1
        stack[top] = { value = {}, array = false }
        state = "first_member"
      elseif c == "[" then
        if top >= session.max_depth then return at(i, "too deep") end
        i = i + 1
        top = top + 1
        stack[top] = { value = {}, array = true, n = 0 }
        state = "first_item"
      elseif c == '"' then
        local v, why = read_string()
        if v == nil then return nil, why end
        finish(v)
      elseif c == "t" then
        if sub(text, i, i + 3) ~= "true" then
          return at(i, "unexpected character '%s'", show_byte(c))
        end
        i = i + 4
        finish(true)
      elseif c == "f" then
        if sub(text, i, i + 4) ~= "false" then
          return at(i, "unexpected character '%s'", show_byte(c))
        end
        i = i + 5
        finish(false)
      elseif c == "n" then
        if sub(text, i, i + 3) ~= "null" then
          return at(i, "unexpected character '%s'", show_byte(c))
        end
        i = i + 4
        finish(session.null)
      elseif c == "-" or (c >= "0" and c <= "9") then
        local v, why = read_number()
        if v == nil then return nil, why end
        finish(v)
      else
        return at(i, "unexpected character '%s'", show_byte(c))
      end

    elseif state == "first_member" or state == "member" then
      if c == "" then
        return at(i, "unexpected end of input")
      elseif state == "first_member" and c == "}" then
        i = i + 1
        close()
      elseif c == '"' then
        local key_at = i
        local key, why = read_string()
        if key == nil then return nil, why end
        local frame = stack[top]
        if frame.value[key] ~= nil then
          return at(key_at, "the key %q twice in one object", key)
        end
        frame.key = key
        state = "colon"
      else
        return at(i, "expected a key")
      end

    elseif state == "colon" then
      if c ~= ":" then return at(i, "expected ':' after the key") end
      i = i + 1
      state = "value"

    elseif state == "after_item" then
      if c == "," then
        i = i + 1
        state = "value"
      elseif c == "]" then
        i = i + 1
        close()
      else
        return at(i, "expected ',' or ']'")
      end

    elseif state == "after_member" then
      if c == "," then
        i = i + 1
        state = "member"
      elseif c == "}" then
        i = i + 1
        close()
      else
        return at(i, "expected ',' or '}'")
      end
    end
  end

  skip_ws()
  if i <= n then
    return at(i, "unexpected character '%s'", show_byte(sub(text, i, i)))
  end
  return result
end

-- the record

local FORMAT = 1

-- A store may answer with a plain reason or with a port error value. Absence has one
-- meaning either way, and session must never report a missing record as a broken store.
local function reason_text(why)
  if type(why) == "string" then return why end
  if type(why) == "table" then
    if type(why.message) == "string" then return why.message end
    if type(why.code) == "string" then return why.code end
    return "the store gave a table with no reason"
  end
  if why == nil then return "the store gave no reason" end
  return "the store gave a " .. type(why) .. " as its reason"
end

local function is_missing(why)
  if why == "missing" then return true end
  if type(why) == "table" and why.code == "not_found" then return true end
  return false
end

-- Where a message sits in the record: the record object is 1, its messages array is 2,
-- a message is 3. Encoding a message at that depth is what keeps save and load
-- agreeing about the nesting limit.
local MESSAGE_DEPTH = 3

local function encode_messages(s)
  local parts = { "[" }
  local ms = s.messages
  for i = 1, #ms do
    local text, why = encode_at(ms[i], MESSAGE_DEPTH)
    if text == nil then
      return nil, fmt("cannot encode message %d: %s", i, why)
    end
    if i > 1 then parts[#parts + 1] = "," end
    parts[#parts + 1] = text
  end
  parts[#parts + 1] = "]"
  return concat(parts)
end

-- The record, keys in byte order, exactly as session.encode would lay the same table
-- out: agent, format, id, messages, model, started.
local function build_record(s, id, messages)
  local parts, first = {}, true
  local function put(key, encoded)
    if not first then parts[#parts + 1] = "," end
    first = false
    parts[#parts + 1] = encode_string(key)
    parts[#parts + 1] = ":"
    parts[#parts + 1] = encoded
  end
  local function put_string(key, v)
    if v == nil then return true end
    if type(v) ~= "string" then
      return nil, fmt("%s is a %s, not a string", key, type(v))
    end
    put(key, encode_string(v))
    return true
  end

  local ok, why = put_string("agent", s.agent)
  if ok == nil then return nil, why end
  put("format", fmt("%d", FORMAT))
  ok, why = put_string("id", id)
  if ok == nil then return nil, why end
  put("messages", messages)
  ok, why = put_string("model", s.model)
  if ok == nil then return nil, why end
  if s.started ~= nil then
    if type(s.started) ~= "number" then
      return nil, fmt("started is a %s, not a number", type(s.started))
    end
    local text, why2 = encode_number(s.started, ".started")
    if text == nil then return nil, "cannot encode started: " .. why2 end
    put("started", text)
  end
  return "{" .. concat(parts) .. "}"
end

local function read_record(text, id)
  local rec, why = session.decode(text)
  if rec == nil then return nil, "not a session record: " .. why end
  if type(rec) ~= "table" or rec == session.null then
    return nil, fmt("not a session record: the record is a %s",
                    rec == session.null and "null" or type(rec))
  end
  local ms = rec.messages
  if type(ms) ~= "table" or ms == session.null then
    return nil, "not a session record: no messages array"
  end
  local keys = 0
  for _ in pairs(ms) do keys = keys + 1 end
  if keys ~= #ms then return nil, "not a session record: messages is not an array" end

  if rec.format == nil then return nil, "not a session record: no format number" end
  if type(rec.format) ~= "number" then
    return nil, fmt("not a session record: format is a %s, not a number", type(rec.format))
  end
  if rec.format ~= FORMAT then
    return nil, fmt("session record format %s, this build reads %d", tostring(rec.format), FORMAT)
  end

  local named = { "id", "agent", "model" }
  for k = 1, #named do
    local field = named[k]
    local v = rec[field]
    if v ~= nil and type(v) ~= "string" then
      return nil, fmt("not a session record: %s is a %s, not a string", field, type(v))
    end
  end
  if rec.started ~= nil and type(rec.started) ~= "number" then
    return nil, fmt("not a session record: started is a %s, not a number", type(rec.started))
  end

  local s = {
    id = rec.id or id, agent = rec.agent, model = rec.model,
    started = rec.started, messages = {},
  }
  local links = new_links()
  for k = 1, #ms do
    local m, why2 = check_message(ms[k])
    if m == nil then return nil, fmt("message %d: %s", k, why2) end
    local ok, why3 = check_link(m, links)
    if ok == nil then return nil, fmt("message %d: %s", k, why3) end
    apply_link(m, links)
    s.messages[k] = m
  end
  return s
end

-- the store

-- The millisecond count as a decimal string, with -2, -3 and so on until one is free.
local function mint(port)
  local now = port.clock.now()
  if type(now) ~= "number" or now ~= now or now == big or now == -big then
    return nil, fmt("the clock returned %s, expected the time",
                    type(now) == "number" and tostring(now) or type(now))
  end
  local base = fmt("%.0f", floor(now * 1000))
  local candidate, tries = base, 1
  while tries <= 1000 do
    local text, why = port.store.read(candidate)
    if text == nil then
      if is_missing(why) then return candidate end
      return nil, "store: " .. reason_text(why)
    end
    tries = tries + 1
    candidate = base .. "-" .. tries
  end
  return nil, "cannot mint an id: a thousand records already share " .. base
end

function session.save(s, port)
  want_session("session.save", s, 4)
  want_port("session.save", port, "store", "write", 4)
  want_port("session.save", port, "store", "read", 4)

  -- Encode first, and write only if the encoding succeeded, so a failure never leaves
  -- a truncated record in the store and never spends an id.
  local messages, why = encode_messages(s)
  if messages == nil then return nil, why end

  local id = s.id
  if id == nil then
    want_port("session.save", port, "clock", "now", 4)
    local minted, why2 = mint(port)
    if minted == nil then return nil, why2 end
    id = minted
  end

  local text, why3 = build_record(s, id, messages)
  if text == nil then return nil, why3 end

  local ok, why4 = port.store.write(id, text)
  if not ok then return nil, "store: " .. reason_text(why4) end
  s.id = id
  return id
end

function session.load(port, id)
  want_port("session.load", port, "store", "read", 4)
  want_string("session.load", "id", id, 4)
  local text, why = port.store.read(id)
  if text == nil then
    if is_missing(why) then return nil, fmt("no session %q", id) end
    return nil, "store: " .. reason_text(why)
  end
  if type(text) ~= "string" then
    return nil, fmt("store returned a %s, expected the record text", type(text))
  end
  return read_record(text, id)
end

local function earlier(a, b)
  local x, y = a.started, b.started
  if x ~= nil and y ~= nil then
    if x ~= y then return x < y end
  elseif x ~= nil then
    return true
  elseif y ~= nil then
    return false
  end
  return tostring(a.id) < tostring(b.id)
end

function session.list(port)
  want_port("session.list", port, "store", "list", 4)
  want_port("session.list", port, "store", "read", 4)
  local ids, why = port.store.list()
  if ids == nil then return nil, "store: " .. reason_text(why) end
  if type(ids) ~= "table" then
    return nil, fmt("store returned a %s, expected a list of ids", type(ids))
  end

  local out = {}
  for k = 1, #ids do
    local id = ids[k]
    if type(id) ~= "string" then
      out[#out + 1] = { id = tostring(id), broken = fmt("the store listed a %s, not an id", type(id)) }
    else
      local text, why2 = port.store.read(id)
      if text == nil then
        if is_missing(why2) then
          out[#out + 1] = { id = id, broken = fmt("no session %q", id) }
        else
          out[#out + 1] = { id = id, broken = "store: " .. reason_text(why2) }
        end
      elseif type(text) ~= "string" then
        out[#out + 1] = { id = id, broken = fmt("store returned a %s, expected the record text", type(text)) }
      else
        local s, why3 = read_record(text, id)
        if s == nil then
          out[#out + 1] = { id = id, broken = why3 }
        else
          out[#out + 1] = session.header(s)
        end
      end
    end
  end
  sort(out, earlier)
  return out
end

function session.delete(port, id)
  want_port("session.delete", port, "store", "delete", 4)
  want_string("session.delete", "id", id, 4)
  local ok, why = port.store.delete(id)
  if not ok then
    if is_missing(why) then return nil, fmt("no session %q", id) end
    return nil, "store: " .. reason_text(why)
  end
  return true
end

return session
