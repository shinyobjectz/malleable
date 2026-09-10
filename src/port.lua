-- The capability ports: the six tables the harness needs from the world, stated as a
-- contract and nothing else. `src/turn.lua` calls a table it was handed rather than
-- naming a provider, which is how rule 1 holds.
--
-- The one convention, in both directions:
--
--   * a wrong shape RAISES  -- a number where a path belongs is a bug in the caller
--   * a wrong world RETURNS -- nil, err for anything the world can do to a call
--
-- The six ports and every function each one owes:
--
--   model  call(request) -> reply | nil, err
--   fs     read(path) -> text | nil, err        write(path, text) -> true | nil, err
--          list(dir) -> entries | nil, err      remove(path) -> true | nil, err
--          exists(path) -> boolean              (cannot fail, cannot raise)
--   sh     run(argv, opts) -> result | nil, err (a non-zero exit is a result)
--   clock  now() -> seconds  mono() -> seconds  sleep(secs) -> true | nil, err
--   ask    request(q) -> decision               (no error channel; refusal is the failure)
--   log    write(level, event, fields) -> nil   (cannot fail)
--
-- Three more ports arrived with the later seams. They are OPTIONAL: an agent that
-- declares no skill, no beat and no server never calls them, and `port.check` does not
-- ask for them, because a world that must be complete before it can be partial is a
-- world nobody wires up by hand.
--
--   skills list() -> { { name, about }, ... } | nil, err   read(name) -> text | nil, err
--   ledger get(key) -> value | nil                         put(key, value) -> true | nil, err
--          (nil from get means NEVER, not failure: a beat that has not run has no row)
--   mcp    list(server, config) -> { descriptor, ... } | nil, err
--          call(server, tool, args) -> text | { content = { ... } } | nil, err
--
-- The mcp port is the only one that knows what a transport is. `src/mcp.lua` hands it
-- the declaration's own table untouched -- a command line, a URL, headers -- so adding
-- a transport is a change to one port and to nothing else in the tree.
--
-- This module is the bottom of the stack: it depends on nothing, reads no agent table,
-- knows what a tool is only as opaque data, runs no policy and names no vendor.

local port = {}

-- The closed set of codes a port may return. Anything else is a bug in a port.
port.codes = {
  not_found   = true,  -- the named thing does not exist
  denied      = true,  -- permission, a sandbox rule, a path leaving the workspace
  exists      = true,  -- already there, and the call refused to clobber it
  too_big     = true,  -- over a limit the port enforces
  timeout     = true,  -- a deadline passed before the call finished
  unavailable = true,  -- not wired up here, or the far side is down
  malformed   = true,  -- the far side answered with something this port cannot read
  exhausted   = true,  -- a budget or a script ran out
  cancelled   = true,  -- the caller's own cancel signal fired
  unscripted  = true,  -- doubles only: asked for something no test scripted
}

-- Build an error value. Raises on a code outside the set, so a typo cannot reach a
-- caller disguised as a world failure.
function port.error(which, call, code, message)
  if type(which) ~= "string" or which == "" then
    error("port.error: `which` names the port, as a non-empty string", 2)
  end
  if type(call) ~= "string" or call == "" then
    error("port.error: `call` names the function, as a non-empty string", 2)
  end
  if type(code) ~= "string" or not port.codes[code] then
    error(string.format("port.error: %s is not one of the codes a port may return", tostring(code)), 2)
  end
  if message ~= nil and type(message) ~= "string" then
    error("port.error: `message` is one sentence, as a string", 2)
  end
  return { port = which, call = call, code = code, message = message or code }
end

function port.is_error(v)
  return type(v) == "table"
     and type(v.port) == "string"
     and type(v.call) == "string"
     and type(v.code) == "string"
     and type(v.message) == "string"
end

-- The textual path rule, shared so a double and a real disk cannot drift apart. It is
-- decided on the text alone, before any lookup, so a link cannot be the difference.
-- The empty string is not a path; `fs.list` takes it as the workspace root and says so
-- itself rather than asking here.
function port.path_ok(path)
  if type(path) ~= "string" or path == "" then return false end
  if path:sub(1, 1) == "/" then return false end
  if path:find("\\", 1, true) then return false end
  if path:match("^%a:") then return false end
  if path:find("//", 1, true) then return false end
  if path:sub(-1) == "/" then return false end
  for segment in path:gmatch("[^/]+") do
    if segment == ".." then return false end
  end
  return true
end

-- The raising half of the convention. Every one of these is a caller bug, so they
-- error rather than return, and the sentence names the argument.
port.shape = {}

local function raise(where, what, ...)
  error(where .. ": " .. string.format(what, ...), 4)
end

function port.shape.path(where, path)
  if type(path) ~= "string" then
    raise(where, "`path` is a workspace-relative string, got %s", type(path))
  end
end

function port.shape.text(where, text)
  if type(text) ~= "string" then
    raise(where, "`text` is a string, got %s", type(text))
  end
end

function port.shape.secs(where, secs)
  if type(secs) ~= "number" or secs < 0 or secs ~= secs then
    raise(where, "`secs` is a number of seconds, at least zero, got %s", tostring(secs))
  end
end

function port.shape.argv(where, argv)
  if type(argv) ~= "table" then
    raise(where, "`argv` is a list of strings, got %s -- to use a shell, write { \"sh\", \"-c\", line }", type(argv))
  end
  if #argv == 0 then
    raise(where, "`argv` is empty; its first element is the program to run")
  end
  for i = 1, #argv do
    if type(argv[i]) ~= "string" then
      raise(where, "`argv` element %d is a string, got %s", i, type(argv[i]))
    end
  end
end

function port.shape.opts(where, opts)
  if opts == nil then return end
  if type(opts) ~= "table" then
    raise(where, "`opts` is nil or a table, got %s", type(opts))
  end
  if opts.cwd ~= nil and type(opts.cwd) ~= "string" then
    raise(where, "`opts.cwd` is a workspace-relative string, got %s", type(opts.cwd))
  end
  if opts.stdin ~= nil and type(opts.stdin) ~= "string" then
    raise(where, "`opts.stdin` is a string, got %s", type(opts.stdin))
  end
  if opts.timeout ~= nil and type(opts.timeout) ~= "number" then
    raise(where, "`opts.timeout` is a number of seconds, got %s", type(opts.timeout))
  end
end

function port.shape.request(where, request)
  if type(request) ~= "table" then
    raise(where, "`request` is a table, got %s", type(request))
  end
  if type(request.model) ~= "string" or request.model == "" then
    raise(where, "`request.model` is a non-empty model id, got %s", tostring(request.model))
  end
  if type(request.messages) ~= "table" then
    raise(where, "`request.messages` is a list, got %s", type(request.messages))
  end
  if request.system ~= nil and type(request.system) ~= "string" then
    raise(where, "`request.system` is a string or nil, got %s", type(request.system))
  end
  if request.tools ~= nil and type(request.tools) ~= "table" then
    raise(where, "`request.tools` is a list or nil, got %s", type(request.tools))
  end
  if request.timeout ~= nil and type(request.timeout) ~= "number" then
    raise(where, "`request.timeout` is a number of seconds or nil, got %s", type(request.timeout))
  end
end

function port.shape.query(where, q)
  if type(q) ~= "table" then
    raise(where, "`q` is a table, got %s", type(q))
  end
  if type(q.tool) ~= "string" or q.tool == "" then
    raise(where, "`q.tool` is a non-empty tool name, got %s", tostring(q.tool))
  end
end

-- What a complete port table owes, in a fixed order so the problems read the same way
-- every time.
local wanted = {
  { name = "model", fns = { "call" } },
  { name = "fs",    fns = { "read", "write", "list", "remove", "exists" } },
  { name = "sh",    fns = { "run" } },
  { name = "clock", fns = { "now", "mono", "sleep" } },
  { name = "ask",   fns = { "request" } },
  { name = "log",   fns = { "write" } },
}

-- The optional ports, checked the same way but only when a run needs one. Answers the
-- same shape as `port.check`: a list of sentences, empty when the wiring is sound.
function port.check_extra(p, names)
  local problems = {}
  local extra = {
    skills = { "list", "read" },
    ledger = { "get", "put" },
    mcp    = { "list", "call" },
  }
  for i = 1, #(names or {}) do
    local name = names[i]
    local fns = extra[name]
    if not fns then
      problems[#problems + 1] = string.format("%s is not one of the ports", tostring(name))
    else
      local t = type(p) == "table" and p[name] or nil
      if type(t) ~= "table" then
        problems[#problems + 1] = string.format("no %s port", name)
      else
        for j = 1, #fns do
          if type(t[fns[j]]) ~= "function" then
            problems[#problems + 1] = string.format("%s.%s is not a function", name, fns[j])
          end
        end
      end
    end
  end
  return problems
end

-- Structure only: that each field is a table and each function is a function. It calls
-- nothing, so it is safe on a port wired to a live world. There is deliberately no
-- port.fill: a real run with half a fake world is worse than one that refuses to start.
function port.check(p)
  local problems = {}
  if type(p) ~= "table" then
    problems[1] = "no port table"
    return problems
  end
  for i = 1, #wanted do
    local w = wanted[i]
    local t = p[w.name]
    if type(t) ~= "table" then
      problems[#problems + 1] = string.format("no %s port", w.name)
    else
      for j = 1, #w.fns do
        if type(t[w.fns[j]]) ~= "function" then
          problems[#problems + 1] = string.format("%s.%s is not a function", w.name, w.fns[j])
        end
      end
    end
  end
  return problems
end

return port
