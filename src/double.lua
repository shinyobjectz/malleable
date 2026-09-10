-- The doubles: a complete in-memory world, so the whole harness runs in a test with no
-- network, no disk and no subprocess.
--
-- Three rules bind every double here.
--
--   1. Deterministic. Nothing in this file reads a real clock, a real file, a real
--      process or a random number. Two runs of the same test agree byte for byte,
--      including the order of a directory listing.
--   2. Fresh. Every constructor returns new state; two doubles in one process cannot
--      see each other.
--   3. Inspectable. Each double records what it was asked on a plain list field a test
--      reads directly -- m.seen, f.wrote, s.ran, c.slept, a.asked, l.lines.
--
-- Nothing here answers a question it was not taught. An unscripted command, an
-- exhausted script and an unlisted tool are all stated failures, never a benign
-- default: a double that agrees with everything turns a broken agent into a green test.

local port = require "port"

local double = {}

local function copy(t)
  local out = {}
  if t ~= nil then
    for k, v in pairs(t) do out[k] = v end
  end
  return out
end

local function copy_list(t)
  local out = {}
  if t ~= nil then
    for i = 1, #t do out[i] = t[i] end
  end
  return out
end

-- ---------------------------------------------------------------- the scripted model

local stops = { done = true, calls = true, cut = true, refused = true }

function double.model(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then
    error("double.model takes a table, got " .. type(cfg), 2)
  end
  if cfg.replies ~= nil and type(cfg.replies) ~= "table" then
    error("double.model: `replies` is a list of script entries", 2)
  end
  local after = cfg.after or "error"
  if after ~= "error" and after ~= "repeat" and after ~= "stop" then
    error('double.model: `after` is "error", "repeat" or "stop", got ' .. tostring(cfg.after), 2)
  end

  local m = { replies = cfg.replies or {}, after = after, seen = {} }

  local at, ids = 0, 0

  local function next_id()
    ids = ids + 1
    return "c" .. ids
  end

  local function fail(code, message)
    return nil, port.error("model", "call", code, message)
  end

  -- Fill a reply in without guessing: a missing list becomes empty, a missing stop is
  -- read off the calls, and anything the far side got wrong is malformed rather than
  -- repaired. Arguments that did not decode to a table are the case that matters: an
  -- invented empty args table would run a tool with nothing in its hands.
  local function fill(reply)
    if reply.text ~= nil and type(reply.text) ~= "string" then
      return fail("malformed", "the reply carried a `text` that is not a string")
    end
    local given = reply.calls
    if given ~= nil and type(given) ~= "table" then
      return fail("malformed", "the reply carried a `calls` that is not a list")
    end
    local calls = {}
    if given ~= nil then
      for i = 1, #given do
        local c = given[i]
        if type(c) ~= "table" then
          return fail("malformed", string.format("call %d is not a table", i))
        end
        if type(c.tool) ~= "string" or c.tool == "" then
          return fail("malformed", string.format("call %d names no tool", i))
        end
        if c.args ~= nil and type(c.args) ~= "table" then
          return fail("malformed", string.format("the arguments of call %d, to %s, did not decode to a table", i, c.tool))
        end
        if c.id ~= nil and type(c.id) ~= "string" then
          return fail("malformed", string.format("the id of call %d is not a string", i))
        end
        calls[i] = { id = c.id or next_id(), tool = c.tool, args = c.args or {} }
      end
    end
    local stop = reply.stop
    if stop == nil then
      stop = (#calls > 0) and "calls" or "done"
    end
    if not stops[stop] then
      return fail("malformed", string.format("%s is not a stop this port knows", tostring(stop)))
    end
    return { text = reply.text or "", calls = calls, stop = stop, usage = reply.usage }
  end

  local function as_error(e)
    if port.is_error(e) then return nil, e end
    if type(e) == "table" and type(e.code) == "string" then
      return fail(e.code, e.message)
    end
    return fail("malformed", "the scripted function returned neither a reply nor an error")
  end

  local function answer(entry, request)
    local kind = type(entry)
    if kind == "string" then
      return { text = entry, calls = {}, stop = "done" }
    end
    if kind == "function" then
      local reply, e = entry(request)
      if reply == nil then return as_error(e) end
      if type(reply) ~= "table" then
        error("double.model: a scripted function returns a reply table, got " .. type(reply), 2)
      end
      return fill(reply)
    end
    if kind ~= "table" then
      error("double.model: a script entry is a reply, a string, a call, an error or a function; got " .. kind, 2)
    end
    if type(entry.code) == "string" then          -- an error entry
      return fail(entry.code, entry.message)
    end
    if entry.tool ~= nil then                     -- the shorthand call
      return fill { calls = { { tool = entry.tool, args = entry.args, id = entry.id } } }
    end
    return fill(entry)
  end

  function m.call(request)
    port.shape.request("model.call", request)
    -- Record a copy, so a caller that pushes onto its own request after the call
    -- cannot rewrite what the test says was sent.
    local seen = copy(request)
    seen.messages = copy_list(request.messages)
    m.seen[#m.seen + 1] = seen

    local entry
    if at < #m.replies then
      at = at + 1
      entry = m.replies[at]
    elseif m.after == "stop" then
      return { text = "", calls = {}, stop = "done" }
    elseif m.after == "repeat" then
      entry = m.replies[#m.replies]
      if entry == nil then
        return fail("exhausted", "the script is empty, so there is nothing to repeat")
      end
    else
      return fail("exhausted", string.format("the script ran out after %d of them", #m.replies))
    end
    return answer(entry, request)
  end

  return m
end

-- ------------------------------------------------------- the in-memory filesystem

function double.fs(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then
    error("double.fs takes a map of path to contents, got " .. type(cfg), 2)
  end

  local f = { files = {}, dirs = {}, wrote = {}, removed = {}, cap = nil, readonly = false }

  for k, v in pairs(cfg) do
    if type(k) ~= "string" then
      error("double.fs: a path is a string", 2)
    end
    if k:sub(-1) == "/" then                       -- a directory with nothing in it
      local d = k:sub(1, #k - 1)
      if not port.path_ok(d) then
        error(string.format("double.fs: %s is not a workspace-relative path", k), 2)
      end
      f.dirs[d] = true
    else
      if not port.path_ok(k) then
        error(string.format("double.fs: %s is not a workspace-relative path", k), 2)
      end
      if type(v) ~= "string" then
        error(string.format("double.fs: the contents of %s are a string, got %s", k, type(v)), 2)
      end
      f.files[k] = v
    end
  end

  local function fail(call, code, message)
    return nil, port.error("fs", call, code, message)
  end

  local function denied(call, path)
    return fail(call, "denied", string.format("that path leaves the workspace: %s", path))
  end

  local function is_dir(path)
    if path == "" then return true end
    if f.dirs[path] then return true end
    local prefix = path .. "/"
    for p in pairs(f.files) do
      if p:sub(1, #prefix) == prefix then return true end
    end
    for d in pairs(f.dirs) do
      if d:sub(1, #prefix) == prefix then return true end
    end
    return false
  end

  function f.read(path)
    port.shape.path("fs.read", path)
    if not port.path_ok(path) then return denied("read", path) end
    local text = f.files[path]
    if text == nil then
      if is_dir(path) then return fail("read", "not_found", string.format("not a file: %s", path)) end
      return fail("read", "not_found", string.format("no such file: %s", path))
    end
    if f.cap ~= nil and #text > f.cap then
      return fail("read", "too_big", string.format("%s is %d bytes, over the cap of %d", path, #text, f.cap))
    end
    return text
  end

  function f.write(path, text)
    port.shape.path("fs.write", path)
    port.shape.text("fs.write", text)
    if not port.path_ok(path) then return denied("write", path) end
    if f.readonly then
      return fail("write", "denied", string.format("the filesystem is read-only: %s", path))
    end
    if f.files[path] == nil and is_dir(path) then
      return fail("write", "exists", string.format("a directory is already there: %s", path))
    end
    f.files[path] = text
    f.wrote[#f.wrote + 1] = { path = path, text = text }
    return true
  end

  function f.list(dir)
    port.shape.path("fs.list", dir)
    if dir ~= "" and not port.path_ok(dir) then return denied("list", dir) end
    if not is_dir(dir) then
      if f.files[dir] ~= nil then
        return fail("list", "not_found", string.format("not a directory: %s", dir))
      end
      return fail("list", "not_found", string.format("no such directory: %s", dir))
    end

    local prefix = (dir == "") and "" or (dir .. "/")
    local by_name = {}

    -- A name that is both is a directory: something lives under it.
    local function note(entry)
      local was = by_name[entry.name]
      if was == nil or (was.kind == "file" and entry.kind == "dir") then
        by_name[entry.name] = entry
      end
    end

    for p, text in pairs(f.files) do
      if #p > #prefix and p:sub(1, #prefix) == prefix then
        local rest = p:sub(#prefix + 1)
        local cut = rest:find("/", 1, true)
        if cut then
          note { name = rest:sub(1, cut - 1), kind = "dir" }
        else
          note { name = rest, kind = "file", size = #text }
        end
      end
    end
    for d in pairs(f.dirs) do
      if #d > #prefix and d:sub(1, #prefix) == prefix then
        local rest = d:sub(#prefix + 1)
        local cut = rest:find("/", 1, true)
        note { name = cut and rest:sub(1, cut - 1) or rest, kind = "dir" }
      end
    end

    local out = {}
    for _, entry in pairs(by_name) do out[#out + 1] = entry end
    table.sort(out, function (a, b) return a.name < b.name end)
    return out
  end

  function f.remove(path)
    port.shape.path("fs.remove", path)
    if not port.path_ok(path) then return denied("remove", path) end
    if f.readonly then
      return fail("remove", "denied", string.format("the filesystem is read-only: %s", path))
    end
    if f.files[path] == nil then
      if is_dir(path) then
        return fail("remove", "denied", string.format("that is a directory: %s", path))
      end
      return fail("remove", "not_found", string.format("no such file: %s", path))
    end
    f.files[path] = nil
    f.removed[#f.removed + 1] = path
    return true
  end

  -- The one probe a tool can make without handling an error: a path that would be
  -- denied simply does not exist.
  function f.exists(path)
    if not port.path_ok(path) then return false end
    return f.files[path] ~= nil or is_dir(path)
  end

  return f
end

-- ---------------------------------------------------------------- the scripted shell

function double.sh(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then
    error("double.sh takes a map of command to result, got " .. type(cfg), 2)
  end

  local s = { script = {}, ran = {} }
  for k, v in pairs(cfg) do
    if type(k) ~= "string" then
      error("double.sh: a command is the argv joined with single spaces, as a string", 2)
    end
    s.script[k] = v
  end

  local function fail(code, message)
    return nil, port.error("sh", "run", code, message)
  end

  local function result_of(v, command)
    if type(v) ~= "table" then
      error(string.format("double.sh: %s is scripted as a %s, not a result, an error or a function", command, type(v)), 3)
    end
    if type(v.code) == "string" then                 -- an error entry
      return fail(v.code, v.message)
    end
    if v.code ~= nil and type(v.code) ~= "number" then
      error(string.format("double.sh: the exit code of %s is a number", command), 3)
    end
    if v.out ~= nil and type(v.out) ~= "string" then
      error(string.format("double.sh: the output of %s is a string", command), 3)
    end
    if v.err ~= nil and type(v.err) ~= "string" then
      error(string.format("double.sh: the error output of %s is a string", command), 3)
    end
    return { code = v.code or 0, out = v.out or "", err = v.err or "", timed_out = v.timed_out or false }
  end

  function s.run(argv, opts)
    port.shape.argv("sh.run", argv)
    port.shape.opts("sh.run", opts)

    local attempt = { argv = copy_list(argv), opts = opts and copy(opts) or nil }
    s.ran[#s.ran + 1] = attempt

    -- The same textual rule the filesystem port applies, so the two cannot drift apart.
    -- The workspace root is an omitted `cwd`, not an empty string: `list` is the one
    -- call anywhere that reads "" as a directory.
    if opts ~= nil and opts.cwd ~= nil and not port.path_ok(opts.cwd) then
      if opts.cwd == "" then
        return fail("denied", "the working directory is the empty string; omit `cwd` for the workspace root")
      end
      return fail("denied", string.format("that working directory leaves the workspace: %s", opts.cwd))
    end

    local command = table.concat(argv, " ")
    local v = s.script[command]
    if v == nil then
      return fail("unscripted", string.format("nothing is scripted for: %s", command))
    end
    if type(v) == "function" then
      local r, e = v(copy_list(argv), attempt.opts)
      if r == nil then
        if port.is_error(e) then return nil, e end
        if type(e) == "table" and type(e.code) == "string" then return fail(e.code, e.message) end
        return fail("unavailable", string.format("the scripted function for %s returned neither a result nor an error", command))
      end
      return result_of(r, command)
    end
    return result_of(v, command)
  end

  return s
end

-- ------------------------------------------------------------------ the frozen clock

function double.clock(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then
    error("double.clock takes a table, got " .. type(cfg), 2)
  end
  if cfg.at ~= nil and type(cfg.at) ~= "number" then
    error("double.clock: `at` is a number of seconds", 2)
  end
  if cfg.mono ~= nil and type(cfg.mono) ~= "number" then
    error("double.clock: `mono` is a number of seconds", 2)
  end

  local c = { at = cfg.at or 0, mono_at = cfg.mono or 0, slept = {} }

  function c.now() return c.at end
  function c.mono() return c.mono_at end

  function c.advance(secs)
    port.shape.secs("clock.advance", secs)
    c.at = c.at + secs
    c.mono_at = c.mono_at + secs
    return true
  end

  -- A slept second is a recorded second and no wait at all, so a test of backoff runs
  -- in no time and can still assert the delays.
  function c.sleep(secs)
    port.shape.secs("clock.sleep", secs)
    c.slept[#c.slept + 1] = secs
    c.advance(secs)
    return true
  end

  return c
end

-- ----------------------------------------------------- the scripted approval channel

function double.ask(cfg)
  local a = { asked = {} }

  local mode, script
  if cfg == nil or cfg == false then
    mode = "none"
  elseif cfg == true then
    mode = "all"
  elseif type(cfg) == "function" then
    mode, script = "one_by_one", cfg
  elseif type(cfg) == "table" then
    mode, script = (#cfg > 0) and "in_order" or "by_tool", cfg
  else
    error("double.ask takes true, false, a table or a function; got " .. type(cfg), 2)
  end

  local at = 0

  -- An unreachable human is a refusal, never an open gate and never an exception.
  local function no_answer()
    return { allow = false, why = "no answer" }
  end

  function a.request(q)
    port.shape.query("ask.request", q)
    a.asked[#a.asked + 1] = copy(q)

    local d
    if mode == "all" then
      d = { allow = true }
    elseif mode == "none" then
      d = { allow = false, why = "refused" }
    elseif mode == "by_tool" then
      local v = script[q.tool]
      if v == true then
        d = { allow = true }
      elseif v == false or v == nil then
        -- A permission table is a whitelist: what is not listed is refused.
        d = { allow = false, why = string.format("%s is not allowed here", q.tool) }
      else
        d = v
      end
    elseif mode == "in_order" then
      at = at + 1
      d = script[at]
      if d == nil then return no_answer() end
    else
      local ok, answered = pcall(script, q)
      if not ok then return no_answer() end
      d = answered
    end

    if type(d) ~= "table" or type(d.allow) ~= "boolean" then return no_answer() end
    return { allow = d.allow, why = d.why, remember = d.remember }
  end

  return a
end

-- --------------------------------------------------------------- the recording sink

local levels = { debug = true, info = true, warn = true, error = true }

local function flat(v)
  local t = type(v)
  if t == "string" or t == "number" or t == "boolean" then return v end
  if t == "table" then return "<table>" end
  return "<" .. t .. ">"
end

function double.log()
  local l = { lines = {} }

  -- The one port with no error path at all: a log call inside an error path must never
  -- be the thing that ends the turn, so everything wrong is coerced, not raised.
  function l.write(level, event, fields)
    if type(level) ~= "string" or not levels[level] then level = "info" end
    if type(event) ~= "string" or event == "" then event = "?" end
    local kept = {}
    if type(fields) == "table" then
      for k, v in pairs(fields) do
        kept[type(k) == "string" and k or tostring(k)] = flat(v)
      end
    end
    l.lines[#l.lines + 1] = { level = level, event = event, fields = kept }
    return
  end

  return l
end

-- ------------------------------------------------------------------- the whole world

-- Each field builds one double; a field left out gets an empty one, and an empty one
-- refuses rather than agrees. A field that is already a built double is taken as is,
-- so a test can hand one double to two worlds on purpose.
-- --------------------------------------------------------------- the three seams
--
-- The world the newer seams need. Each is the smallest thing that can stand where a
-- real one will: a table of procedures, a table that remembers across a restart it
-- never has, and a server that is a table of functions.

-- The workspace's skills. `cfg` is name -> text, or name -> { about, does }.
function double.skills(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then error("double.skills takes a table, got " .. type(cfg), 2) end
  local held, names = {}, {}
  for k, v in pairs(cfg) do
    if type(k) == "string" then
      if type(v) == "string" then held[k] = { about = "", does = v }
      elseif type(v) == "table" then held[k] = { about = v.about or "", does = v.does or "" }
      else error("double.skills: the skill " .. k .. " is text, or a table of about and does", 2) end
      names[#names + 1] = k
    end
  end
  table.sort(names)
  local d = { reads = {} }
  function d.list()
    local out = {}
    for i = 1, #names do out[i] = { name = names[i], about = held[names[i]].about } end
    return out
  end
  function d.read(name)
    d.reads[#d.reads + 1] = name
    local s = held[name]
    if not s then return nil, port.error("skills", "read", "not_found", "there is no skill " .. tostring(name)) end
    return s.does
  end
  return d
end

-- The durable record, without the durability. It survives nothing, which is exactly
-- what makes it useful in a test: a run's whole memory is visible as a table, and
-- `double.ledger(previous.held)` is a restart.
function double.ledger(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then error("double.ledger takes a table, got " .. type(cfg), 2) end
  local d = { held = copy(cfg), puts = {} }
  function d.get(key)
    if type(key) ~= "string" or key == "" then error("ledger.get: `key` is a non-empty string", 2) end
    return d.held[key]
  end
  function d.put(key, value)
    if type(key) ~= "string" or key == "" then error("ledger.put: `key` is a non-empty string", 2) end
    if type(value) ~= "table" then error("ledger.put: `value` is a table", 2) end
    d.held[key] = copy(value)
    d.puts[#d.puts + 1] = key
    return true
  end
  return d
end

-- Servers, in this process. `cfg` is server name -> { tools = { descriptor, ... },
-- answers = { [tool] = text | function (args) }, down = "why" }.
function double.mcp(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then error("double.mcp takes a table, got " .. type(cfg), 2) end
  local d = { listed = {}, calls = {} }
  function d.list(name, config)
    d.listed[#d.listed + 1] = { server = name, config = config }
    local s = cfg[name]
    if not s then return nil, port.error("mcp", "list", "unavailable", "no server called " .. tostring(name) .. " is running") end
    if s.down then return nil, port.error("mcp", "list", "unavailable", s.down) end
    local out = {}
    for i = 1, #(s.tools or {}) do out[i] = copy(s.tools[i]) end
    return out
  end
  function d.call(name, tool, args)
    d.calls[#d.calls + 1] = { server = name, tool = tool, args = copy(args) }
    local s = cfg[name]
    if not s then return nil, port.error("mcp", "call", "unavailable", "no server called " .. tostring(name) .. " is running") end
    if s.down then return nil, port.error("mcp", "call", "unavailable", s.down) end
    local answer = (s.answers or {})[tool]
    if answer == nil then
      return nil, port.error("mcp", "call", "unscripted", "the server " .. name .. " has no scripted answer for " .. tostring(tool))
    end
    if type(answer) == "function" then return answer(args) end
    return answer
  end
  return d
end

local function built(v, fn)
  return type(v) == "table" and type(v[fn]) == "function"
end

function double.world(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then
    error("double.world takes a table, got " .. type(cfg), 2)
  end

  local model = cfg.model
  if built(model, "call") then
    -- already a model port
  else
    if type(model) == "table" and model.replies == nil and #model > 0 then
      model = { replies = model }
    end
    model = double.model(model)
  end

  return {
    model = model,
    fs    = built(cfg.fs, "read")       and cfg.fs    or double.fs(cfg.fs),
    sh    = built(cfg.sh, "run")        and cfg.sh    or double.sh(cfg.sh),
    clock = built(cfg.clock, "now")     and cfg.clock or double.clock(cfg.clock),
    ask   = built(cfg.ask, "request")   and cfg.ask   or double.ask(cfg.ask),
    log   = built(cfg.log, "write")     and cfg.log   or double.log(),
    -- The three later ports are OPTIONAL, and a world builds one only when the test
    -- asks for it. `port.check` does not require them, and an agent that declares no
    -- skill, no beat and no server must not be handed three doubles it will never
    -- call -- a world with more in it than the run uses is a world whose tests pass
    -- for reasons the test did not state.
    skills = cfg.skills ~= nil and (built(cfg.skills, "read") and cfg.skills or double.skills(cfg.skills)) or nil,
    ledger = cfg.ledger ~= nil and (built(cfg.ledger, "get")  and cfg.ledger or double.ledger(cfg.ledger)) or nil,
    mcp    = cfg.mcp    ~= nil and (built(cfg.mcp, "call")    and cfg.mcp    or double.mcp(cfg.mcp))    or nil,
  }
end

return double
