-- The real world, for the runner: `world.ports(cfg)` answers the six ports of
-- spec/port.md wired to this machine. A host file, like bin/malleable.lua and bin/curl.lua.
--
--     model   a real API through src/provider.lua over curl. OPENROUTER_API_KEY for
--             "openrouter:…" models, OPENAI_API_KEY for "openai:…"
--     fs      the disk, rooted at --root (default: the working directory)
--     sh      none: this host runs no commands, and says so to the model
--     ask     a yes/no on the terminal, read from /dev/tty so a piped prompt is untouched
--     clock   the machine's
--     log     warnings and errors to stderr; everything with MALLEABLE_LOG=debug
--     history every run kept under <root>/.malleable/history (docs/spec/history.md);
--             `history = false` keeps none
--
-- With `yielding = true`, a run inside a coroutine does not wait on the network: its model
-- request is a curl in the background and its sleep a pause, each yielded as a wait for
-- whoever resumes it (spec/speech.md). A run outside one blocks, as without the option.
--
-- There is no shell on purpose. A command line is the tool with the least idea of what it
-- is about to do, and a host that runs whatever a model writes is a decision somebody
-- should make in writing, not a default. A declaration that asks for `agent.shell` still
-- loads, and every call comes back `denied`: a result the model reads, not a crash.

local port     = require "port"
local provider = require "provider"
local curl     = require "curl"
local wait     = require "wait"
local fetch    = curl.fetch

local world = {}

local function quoted(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- os.execute answers a number in 5.1 and LuaJIT, and true/nil in 5.2 onwards.
local function succeeded(cmd)
  local r = os.execute(cmd)
  return r == true or r == 0
end

local READ_CAP = 4 * 1024 * 1024

-- The real path of something that exists, links resolved; nil when it does not exist.
local function physical(p)
  local pipe = io.popen("realpath " .. quoted(p) .. " 2>/dev/null")
  if not pipe then return nil end
  local out = pipe:read("*l")
  pipe:close()
  if out == nil or out == "" then return nil end
  return out
end

local function fs_port(root)
  local function full(path) return path == "" and root or (root .. "/" .. path) end
  local function is_dir(path) return succeeded("test -d " .. quoted(full(path))) end
  local function is_file(path) return succeeded("test -f " .. quoted(full(path))) end
  local function refuse(call, path)
    return nil, port.error("fs", call, "denied", "not a workspace path: " .. string.format("%q", path))
  end

  -- The path rule is textual, and a link is not text: `notes -> /etc` passes it. So every
  -- call also resolves where the path really lands, and anything outside the root is
  -- refused the same way `../` is. A link that points nowhere is refused outright, since
  -- writing through it would create its target wherever it points.
  local real_root = physical(root)
  local function lands_inside(path)
    if not real_root then return false end
    local target = full(path)
    local real = physical(target)
    if not real then
      if succeeded("test -L " .. quoted(target)) then return false end
      local parent = path:match("^(.*)/[^/]*$")
      while parent and not physical(full(parent)) do parent = parent:match("^(.*)/[^/]*$") end
      real = physical(parent and full(parent) or root)
      if not real then return false end
    end
    return real == real_root or real:sub(1, #real_root + 1) == real_root .. "/"
  end
  local function allowed(path) return port.path_ok(path) and lands_inside(path) end

  local fs = {}

  function fs.read(path)
    port.shape.path("fs.read", path)
    if not allowed(path) then return refuse("read", path) end
    if not is_file(path) then
      return nil, port.error("fs", "read", "not_found", "no such file: " .. path)
    end
    local f, why = io.open(full(path), "rb")
    if not f then return nil, port.error("fs", "read", "denied", tostring(why)) end
    local size = f:seek("end")
    if size and size > READ_CAP then
      f:close()
      return nil, port.error("fs", "read", "too_big", path .. " is " .. size .. " bytes, over the "
        .. READ_CAP .. " this host reads")
    end
    f:seek("set")
    local text = f:read("*a") or ""
    f:close()
    return text
  end

  function fs.write(path, text)
    port.shape.path("fs.write", path)
    port.shape.text("fs.write", text)
    if not allowed(path) then return refuse("write", path) end
    if is_dir(path) then
      return nil, port.error("fs", "write", "exists", path .. " is a directory")
    end
    local parent = path:match("^(.*)/[^/]*$")
    if parent and not is_dir(parent) and not succeeded("mkdir -p " .. quoted(full(parent))) then
      return nil, port.error("fs", "write", "denied", "could not make the directory " .. parent)
    end
    local f, why = io.open(full(path), "wb")
    if not f then return nil, port.error("fs", "write", "denied", tostring(why)) end
    f:write(text)
    f:close()
    return true
  end

  function fs.list(dir)
    port.shape.path("fs.list", dir)
    if dir ~= "" and not allowed(dir) then return refuse("list", dir) end
    if not is_dir(dir) then
      return nil, port.error("fs", "list", "not_found", "no such directory: " .. dir)
    end
    local pipe = io.popen("ls -1Ap " .. quoted(full(dir)) .. " 2>/dev/null")
    if not pipe then return nil, port.error("fs", "list", "unavailable", "ls could not be started") end
    local entries = {}
    for line in pipe:lines() do
      local name = line:match("^(.-)/$")
      if name then
        entries[#entries + 1] = { name = name, kind = "dir", size = 0 }
      else
        local at = dir == "" and line or (dir .. "/" .. line)
        local f = io.open(full(at), "rb")
        local size = f and f:seek("end") or 0
        if f then f:close() end
        entries[#entries + 1] = { name = line, kind = "file", size = size }
      end
    end
    pipe:close()
    table.sort(entries, function (a, b) return a.name < b.name end)
    return entries
  end

  function fs.remove(path)
    port.shape.path("fs.remove", path)
    if not allowed(path) then return refuse("remove", path) end
    if is_dir(path) then
      return nil, port.error("fs", "remove", "denied", path .. " is a directory, and remove does not recurse")
    end
    if not is_file(path) then
      return nil, port.error("fs", "remove", "not_found", "no such file: " .. path)
    end
    local ok, why = os.remove(full(path))
    if not ok then return nil, port.error("fs", "remove", "denied", tostring(why)) end
    return true
  end

  function fs.exists(path)
    if type(path) ~= "string" or not allowed(path) then return false end
    return is_file(path) or is_dir(path)
  end

  return fs
end

local sh = {
  run = function (argv)
    port.shape.argv("sh.run", argv)
    return nil, port.error("sh", "run", "denied",
      "this host runs no commands: it has a model, a disk and a gate, and no shell")
  end,
}

local clock = {
  now   = function () return os.time() end,
  mono  = function () return os.time() end,
  sleep = function (secs)
    if type(secs) ~= "number" or secs < 0 then error("clock.sleep takes a non-negative number", 2) end
    succeeded("sleep " .. string.format("%.3f", secs))
    return true
  end,
}

-- Inside a run that may pause (spec/speech.md, "Waits"): a request is a curl in the
-- background whose poll the run yields, and a sleep is a wait, so the rest of the
-- conversation goes on meanwhile. Outside one, they block as they always did.
local function yieldable()
  return coroutine.isyieldable ~= nil and coroutine.isyieldable()
end

local function yielding_fetch(req)
  if not yieldable() then return fetch(req) end
  local h = curl.start(req)
  local got = coroutine.yield(wait.host(h.poll, h.cancel))
  return got[1], got[2]
end

local yielding_clock = {
  now   = clock.now,
  mono  = clock.mono,
  sleep = function (secs)
    if type(secs) ~= "number" or secs < 0 then error("clock.sleep takes a non-negative number", 2) end
    if not yieldable() then return clock.sleep(secs) end
    coroutine.yield(wait.sleep(secs))
    return true
  end,
}

local function log_port(everything)
  return {
    write = function (level, event, fields)
      if not everything and level ~= "warn" and level ~= "error" then return end
      local parts = {}
      for k, v in pairs(type(fields) == "table" and fields or {}) do
        parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
      end
      table.sort(parts)
      io.stderr:write(string.format("[%s] %s %s\n", tostring(level), tostring(event), table.concat(parts, " ")))
    end,
  }
end

-- The person at this terminal. An unanswerable question is a refusal (spec/port.md).
local ask = {
  request = function (q)
    if type(q) ~= "table" or type(q.tool) ~= "string" or q.tool == "" then
      error("ask.request takes { tool = name, ... }", 2)
    end
    local tty = io.open("/dev/tty", "r+")
    if not tty then return { allow = false, why = "no answer: there is no terminal to ask" } end
    local ok, args = pcall(provider.json.encode, q.args or {})
    tty:write(string.format("\n  %s wants to run: %s\n", q.tool, tostring(q.about or "")))
    if ok then tty:write("  with " .. tostring(args) .. "\n") end
    tty:write("  allow? [y/N] ")
    tty:flush()
    local line = tty:read("*l") or ""
    tty:close()
    if line:match("^%s*[yY]") then return { allow = true, remember = "once" } end
    return { allow = false, why = "the person at the terminal said no" }
  end,
}

-- The whole of a small file, or nil.
local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

-- Where the workspace sits in git: its git branch (or a detached head's commit) and the
-- commit, read from the files git keeps rather than by running git. A `.git` that is a
-- file is a worktree's, and names the folder that holds its HEAD.
local function git_at(dir)
  while dir and dir ~= "" do
    local dot = dir .. "/.git"
    local gitdir = nil
    if succeeded("test -d " .. quoted(dot)) then gitdir = dot
    else
      local pointer = slurp(dot)
      local named = pointer and pointer:match("^gitdir:%s*(%S+)")
      if named then gitdir = named:sub(1, 1) == "/" and named or (dir .. "/" .. named) end
    end
    if gitdir then
      local head = (slurp(gitdir .. "/HEAD") or ""):gsub("%s+$", "")
      local common = (slurp(gitdir .. "/commondir") or ""):gsub("%s+$", "")
      if common == "" then common = gitdir
      elseif common:sub(1, 1) ~= "/" then common = gitdir .. "/" .. common end
      local ref = head:match("^ref:%s*(%S+)")
      if not ref then return { git_branch = head:sub(1, 7), commit = head:sub(1, 7) } end
      local sha = slurp(gitdir .. "/" .. ref) or slurp(common .. "/" .. ref)
      if not sha then
        for line in (slurp(common .. "/packed-refs") or ""):gmatch("[^\n]+") do
          local s, r = line:match("^(%x+)%s+(%S+)$")
          if r == ref then sha = s end
        end
      end
      return { git_branch = ref:gsub("^refs/heads/", ""), commit = sha and sha:sub(1, 7) or nil }
    end
    if dir == "/" then return {} end
    dir = dir:match("^(.*)/[^/]*$") or ""
    if dir == "" then dir = "/" end
  end
  return {}
end

-- The local time's offset from UTC, in seconds, from the date's own `%z` (-0700).
local function utc_offset()
  local z = os.date("%z")
  local sign, hh, mm = tostring(z):match("^([+-])(%d%d)(%d%d)$")
  if not sign then return 0 end
  local secs = tonumber(hh) * 3600 + tonumber(mm) * 60
  return sign == "-" and -secs or secs
end

--- The history port (docs/spec/history.md, "The port"), kept under `<root>/.malleable/history`.
--- `secrets` are texts no file may hold: each is written `[key]`. The port is authority, and
--- the harness never hands it to a tool body.
function world.history(root, secrets)
  local real = physical(root) or root
  local base = real .. "/.malleable/history"
  local function ok_path(p)
    return type(p) == "string" and p ~= "" and p:sub(1, 1) ~= "/" and not p:find("%.%.")
  end
  local function scrub(text)
    for _, s in ipairs(secrets or {}) do
      if type(s) == "string" and #s >= 8 then
        text = text:gsub(s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"), "[key]")
      end
    end
    return text
  end
  -- Each folder is looked for once: a shell per write is most of what keeping costs.
  local made = {}
  local function parent_made(p)
    local parent = p:match("^(.*)/[^/]*$")
    local dir = parent and (base .. "/" .. parent) or base
    if made[dir] then return true end
    if succeeded("test -d " .. quoted(dir)) or succeeded("mkdir -p " .. quoted(dir)) then
      made[dir] = true
      return true
    end
    return false
  end

  local h = {}

  function h.where()
    local w = git_at(real)
    w.worktree = real:match("([^/]+)$") or "workspace"
    w.offset = utc_offset()
    return w
  end

  -- `mkdir` without -p fails when the folder is there, which is what makes a claim atomic
  -- between two processes.
  function h.claim(id)
    if not ok_path(id) or not parent_made("runs/" .. id) then return false end
    if not succeeded("mkdir " .. quoted(base .. "/runs/" .. id) .. " 2>/dev/null") then return false end
    made[base .. "/runs/" .. id] = true
    return true
  end

  -- Written beside and renamed over, so a reader never sees half an index.
  function h.write(p, text)
    if not ok_path(p) or type(text) ~= "string" then return nil, "a path in the history and a text" end
    if not parent_made(p) then return nil, "could not make the folder for " .. p end
    local full = base .. "/" .. p
    local f, why = io.open(full .. ".part", "wb")
    if not f then return nil, tostring(why) end
    f:write(scrub(text))
    f:close()
    local moved, err = os.rename(full .. ".part", full)
    if not moved then return nil, tostring(err) end
    return true
  end

  function h.append(p, text)
    if not ok_path(p) or type(text) ~= "string" then return nil, "a path in the history and a text" end
    if not parent_made(p) then return nil, "could not make the folder for " .. p end
    local f, why = io.open(base .. "/" .. p, "ab")
    if not f then return nil, tostring(why) end
    f:write(scrub(text))
    f:close()
    return true
  end

  function h.read(p)
    if not ok_path(p) then return nil, "a path in the history" end
    local text = slurp(base .. "/" .. p)
    if text == nil then return nil, "no such file: " .. p end
    return text
  end

  function h.list(dir)
    local at = (dir == nil or dir == "") and base or (ok_path(dir) and (base .. "/" .. dir:gsub("/+$", "")))
    if not at then return nil, "a path in the history" end
    if not succeeded("test -d " .. quoted(at)) then return {} end
    local pipe = io.popen("ls -1A " .. quoted(at) .. " 2>/dev/null")
    if not pipe then return nil, "ls could not be started" end
    local names = {}
    for line in pipe:lines() do
      if not line:match("%.part$") then names[#names + 1] = line end
    end
    pipe:close()
    table.sort(names)
    return names
  end

  return h
end

-- The disk port on its own, for bin/world_check.lua.
world.fs = fs_port

-- A line at a time, for --talk. A line that did not come from a terminal is written back,
-- so a piped conversation reads as one.
local from_terminal = nil
function world.line()
  if from_terminal == nil then from_terminal = succeeded("test -t 0") end
  local l = io.read("*l")
  if l and not from_terminal then io.stdout:write(l .. "\n") end
  return l
end

function world.sleep(secs) succeeded("sleep " .. string.format("%.3f", tonumber(secs) or 0)) end

function world.ports(cfg)
  cfg = cfg or {}
  -- --history, --recall and --evidence read what was kept, and need no model key.
  if cfg.only == "history" then
    local root = type(cfg.root) == "string" and cfg.root ~= "" and cfg.root or "."
    return { history = world.history(root, {}) }
  end
  local keys = {
    openrouter = os.getenv("OPENROUTER_API_KEY"),
    openai     = os.getenv("OPENAI_API_KEY"),
  }
  if not keys.openrouter and not keys.openai then
    return nil, "no model key: set OPENROUTER_API_KEY (or OPENAI_API_KEY), or run with --dry-run"
  end

  local root = cfg.root
  if type(root) ~= "string" or root == "" then root = "." end
  root = root:gsub("/+$", "")
  if root == "" then root = "/" end

  local log = log_port(os.getenv("MALLEABLE_LOG") == "debug")
  local schemes, secrets = {}, {}
  for scheme, key in pairs(keys) do
    if key and key ~= "" then schemes[scheme] = { key = key }; secrets[#secrets + 1] = key end
  end

  local net_fetch, the_clock = fetch, clock
  if cfg.yielding then net_fetch, the_clock = yielding_fetch, yielding_clock end
  local model, why = provider.model({
    schemes = schemes,
    timeout = tonumber(cfg.timeout) or 60,
  }, { net = { fetch = net_fetch }, json = provider.json, clock = the_clock, log = log })
  if not model then return nil, why and why.message or "the model port could not be built" end

  return {
    model   = model,
    fs      = fs_port(root),
    sh      = sh,
    clock   = the_clock,
    ask     = ask,
    log     = log,
    history = cfg.history ~= false and world.history(root, secrets) or nil,
  }
end

return world
