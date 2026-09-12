-- cli -- the runner. The thing a person types.
--
-- Everything here is pure with respect to the process. The world arrives as an
-- argument, so every behaviour in this file drives in a test with no network, no
-- disk and no subprocess -- including the ones about the terminal, because a
-- terminal is two functions.
--
-- This file has the least logic in the tree and the strongest opinion about how a
-- run reads. It does not step the loop, does not decide permission, does not read
-- the model's words, and never substitutes a double for a real port.

local function need_module(name, required)
  local ok, m = pcall(require, name)
  if ok then return m end
  local ok2, m2 = pcall(require, "src." .. name)
  if ok2 then return m2 end
  if required then
    error("cli: the module " .. name .. " is not on the path", 2)
  end
  return nil
end

local spec     = need_module("spec", true)
local turn     = need_module("turn", true)
local approval = need_module("approval", true)
local capport  = need_module("port", true)
local double   = need_module("double", true)
local store    = need_module("store", true)
-- Not required: the runner works without them, and an agent that declares no skill and
-- no server never notices they are missing.
local skills   = need_module("skills")
local mcp      = need_module("mcp")
local schedule = need_module("schedule")
local gherkin  = need_module("gherkin")
local behaviour = need_module("behaviour")

local cli = {}

cli.version = "0.1.0"

local MARK_BLOCKED = "\1pi-blocked\1"
local MARK_STEPS   = "\1pi-steps\1"

local RESULT_BYTES = 4096
local ARG_BYTES    = 120

-- tiny text

local fmt = string.format

-- Nothing a model or a tool produced can move the cursor. Tab and newline live;
-- every other control byte, and DEL, is written as an escape before it is printed.
local function safe(s)
  if type(s) ~= "string" then s = tostring(s) end
  return (s:gsub("%c", function (c)
    if c == "\n" or c == "\t" then return c end
    return fmt("\\x%02x", c:byte())
  end))
end

local function num(v)
  if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
  if v == math.floor(v) and v < 1e15 and v > -1e15 then return fmt("%d", v) end
  return fmt("%.14g", v)
end

local function words(s)
  local out = {}
  for w in tostring(s):gmatch("%S+") do out[#out + 1] = w end
  return out
end

-- Wrap one paragraph to a width, under a prefix, with continuation aligned to it.
local function wrapped(text, width, prefix)
  local cont = string.rep(" ", #prefix)
  local out = {}
  local first = true
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    local head = first and prefix or cont
    local ws = words(line)
    if #ws == 0 then
      out[#out + 1] = head == prefix and (prefix .. line) or cont
    else
      local at = 1
      while at <= #ws do
        local acc = head
        local put = 0
        while at <= #ws do
          local piece = (put == 0 and "" or " ") .. ws[at]
          if put > 0 and #acc + #piece > width then break end
          acc = acc .. piece
          put = put + 1
          at = at + 1
        end
        out[#out + 1] = acc
        head = cont
      end
    end
    first = false
  end
  -- The trailing empty line the gmatch guard added.
  if #out > 1 and out[#out]:match("^%s*$") then out[#out] = nil end
  return out
end

local function clip(s, n)
  if #s <= n then return s end
  if n <= 3 then return s:sub(1, n) end
  return s:sub(1, n - 3) .. "..."
end

-- the codes

local STOP_CODE = { answered = 0, budget = 4, refused = 5, error = 6 }

local codes = {
  answered    = 0,
  usage       = 1,
  load        = 2,
  declaration = 3,
  budget      = 4,
  refused     = 5,
  error       = 6,
  world       = 7,
}

function codes.of(stop)
  return STOP_CODE[stop]
end

cli.codes = setmetatable({}, {
  __index    = codes,
  __newindex = function () error("cli.codes is frozen", 2) end,
  __pairs    = function () return pairs(codes) end,
  __metatable = "frozen",
})

-- Under 5.1 there is no __pairs, so a caller that wants to walk the table walks the
-- names it already knows. This list is that walk, and is part of the contract.
cli.code_names = { "answered", "usage", "load", "declaration", "budget", "refused", "error", "world" }

-- the parser

local TRUSTS = { trusted = true, ask = true, none = true }

local LONG = {
  ["--prompt"]         = { field = "prompt",         kind = "string" },
  ["--prompt-file"]    = { field = "prompt_file",    kind = "string" },
  ["--stdin"]          = { field = "stdin",          kind = "flag" },
  ["--budget"]         = { field = "budget",         kind = "int",   low = 1 },
  ["--calls-per-step"] = { field = "calls_per_step", kind = "int",   low = 1 },
  ["--max-depth"]      = { field = "max_depth",      kind = "int",   low = 0 },
  ["--model"]          = { field = "model",          kind = "string" },
  ["--root"]           = { field = "root",           kind = "string" },
  ["--timeout"]        = { field = "timeout",        kind = "above", low = 0 },
  ["--trust"]          = { field = "trust",          kind = "enum",  values = TRUSTS },
  ["--allow"]          = { field = "allow",          kind = "list" },
  ["--deny"]           = { field = "deny",           kind = "list" },
  ["--yes"]            = { field = "yes",            kind = "flag" },
  ["--no"]             = { field = "no",             kind = "flag" },
  ["--dry-run"]        = { field = "dry_run",        kind = "flag" },
  ["--reply"]          = { field = "reply",          kind = "list" },
  ["--script"]         = { field = "script",         kind = "string" },
  ["--check"]          = { field = "check",          kind = "flag" },
  ["--verify"]         = { field = "verify",         kind = "flag" },
  ["--talk"]           = { field = "talk",           kind = "flag" },
  ["--steps"]          = { field = "show_steps",     kind = "flag" },
  ["--heading"]        = { field = "heading",        kind = "flag" },
  ["--feature"]        = { field = "feature",        kind = "string" },
  ["--tools"]          = { field = "show_tools",     kind = "flag" },
  ["--session"]        = { field = "session",        kind = "string" },
  ["--json"]           = { field = "json",           kind = "flag" },
  ["--show-lines"]     = { field = "show_lines",     kind = "int",   low = 0 },
  ["--quiet"]          = { field = "quiet",          kind = "flag" },
  ["--verbose"]        = { field = "verbose",        kind = "count" },
  ["--width"]          = { field = "width",          kind = "int",   low = 20 },
  ["--no-colour"]      = { field = "colour",         kind = "const", value = false },
  ["--colour"]         = { field = "colour",         kind = "const", value = true },
  ["--history"]        = { field = "history",        kind = "flag" },
  ["--recall"]         = { field = "recall",         kind = "string" },
  ["--evidence"]       = { field = "evidence",       kind = "string" },
  ["--day"]            = { field = "day",            kind = "string" },
  ["--since"]          = { field = "since",          kind = "string" },
  ["--file"]           = { field = "file",           kind = "string" },
  ["--stop"]           = { field = "stop",           kind = "string" },
  ["--cause"]          = { field = "cause",          kind = "string" },
  ["--agent"]          = { field = "agent",          kind = "string" },
  ["--limit"]          = { field = "limit",          kind = "int",   low = 1 },
  ["--like"]           = { field = "like",           kind = "string" },
  ["--help"]           = { field = "help",           kind = "flag" },
  ["--version"]        = { field = "version",        kind = "flag" },
}

-- Short options do not bundle. `-qv` is an unknown option, not `-q -v`: bundling
-- saves two keystrokes and costs a class of misparse that shows up under stress.
local SHORT = {
  ["-p"] = "--prompt", ["-y"] = "--yes", ["-q"] = "--quiet",
  ["-v"] = "--verbose", ["-h"] = "--help",
}

local KNOWN = {
  prompt = true, prompt_file = true, stdin = true, budget = true,
  calls_per_step = true, max_depth = true, model = true, root = true,
  timeout = true, trust = true, allow = true, deny = true, yes = true,
  no = true, dry_run = true, reply = true, script = true, check = true,
  verify = true, feature = true, show_steps = true, talk = true,
  show_tools = true, session = true, json = true, show_lines = true,
  quiet = true, verbose = true, width = true, colour = true, help = true,
  version = true, path = true, prompt_source = true, argv = true, words = true,
  history = true, recall = true, evidence = true, day = true, since = true, file = true,
  stop = true, cause = true, like = true, agent = true, limit = true,
}

-- The questions --history asks, each a field of history.find (docs/spec/history.md).
local HISTORY_FIELDS = { "day", "since", "file", "stop", "cause", "agent", "like", "limit" }

local function defaults()
  return {
    prompt = nil, prompt_file = nil, stdin = false,
    budget = nil, calls_per_step = 8, max_depth = 3,
    model = nil, root = ".", timeout = nil, trust = nil,
    allow = {}, deny = {}, yes = false, no = false,
    dry_run = false, reply = {}, script = nil,
    check = false, verify = false, feature = nil, show_steps = false, show_tools = false, session = nil, json = false,
    talk = false,
    show_lines = 12, quiet = false, verbose = 0, width = nil, colour = nil,
    help = false, version = false,
    path = nil, prompt_source = "none", words = {}, argv = {},
  }
end

function cli.parse(argv)
  if argv == nil then argv = {} end
  if type(argv) ~= "table" then
    return nil, "the command line is a list of strings"
  end

  local o = defaults()
  for i = 1, #argv do
    if type(argv[i]) ~= "string" then
      return nil, "argument " .. i .. " is not a string"
    end
    o.argv[i] = argv[i]
  end

  local positional = {}
  local ended = false
  local i = 1

  local function take(d, name, joined, has_joined)
    local value = joined
    if not has_joined then
      value = argv[i + 1]
      if value == nil then
        return "the option " .. name .. " needs a value"
      end
      i = i + 1
    end
    if d.kind == "string" then
      o[d.field] = value
    elseif d.kind == "list" then
      local l = o[d.field]
      l[#l + 1] = value
    elseif d.kind == "enum" then
      if not d.values[value] then
        return "the option " .. name .. ' does not take "' .. safe(value) .. '"'
      end
      o[d.field] = value
    else
      local n = tonumber(value)
      if n == nil or n ~= n then
        return "the option " .. name .. " takes a number, and was given " .. '"' .. safe(value) .. '"'
      end
      if d.kind == "int" then
        if n ~= math.floor(n) or n < d.low then
          return "the option " .. name .. " takes a whole number, at least " .. d.low
        end
      elseif d.kind == "above" then
        if n <= d.low then
          return "the option " .. name .. " takes a number above " .. d.low
        end
      end
      o[d.field] = n
    end
    return nil
  end

  while i <= #argv do
    local a = argv[i]
    if ended then
      positional[#positional + 1] = a
    elseif a == "--" then
      ended = true
    elseif a:sub(1, 2) == "--" then
      local name, joined = a:match("^(%-%-[^=]*)=(.*)$")
      local has_joined = name ~= nil
      if not has_joined then name = a end
      local d = LONG[name]
      if not d then
        return nil, 'unknown option "' .. safe(name) .. '"'
      end
      if d.kind == "flag" or d.kind == "count" or d.kind == "const" then
        if has_joined then
          return nil, "the option " .. name .. " takes no value"
        end
        if d.kind == "flag" then o[d.field] = true
        elseif d.kind == "count" then o[d.field] = o[d.field] + 1
        else o[d.field] = d.value end
      else
        local problem = take(d, name, joined, has_joined)
        if problem then return nil, problem end
      end
    elseif a:sub(1, 1) == "-" and #a > 1 then
      local name = SHORT[a]
      if not name then
        return nil, 'unknown option "' .. safe(a) .. '"'
      end
      local d = LONG[name]
      if d.kind == "flag" then o[d.field] = true
      elseif d.kind == "count" then o[d.field] = o[d.field] + 1
      else
        local problem = take(d, a, nil, false)
        if problem then return nil, problem end
      end
    else
      positional[#positional + 1] = a
    end
    i = i + 1
  end

  -- Help and version answer before anything else is required of the line.
  if o.help or o.version then return o end

  if o.yes and o.no then
    return nil, "--yes and --no cannot both be given"
  end
  if o.quiet and o.verbose > 0 then
    return nil, "--quiet and --verbose cannot both be given"
  end
  if (#o.reply > 0 or o.script) and not o.dry_run then
    local which = #o.reply > 0 and "--reply" or "--script"
    return nil, which .. " is a scripted answer, and needs --dry-run"
  end

  -- --history, --recall and --evidence read what the workspace kept, and need no
  -- declaration: what follows --evidence's id is the part and which one.
  local reading = o.history or o.recall ~= nil or o.evidence ~= nil
  if (o.history and 1 or 0) + (o.recall and 1 or 0) + (o.evidence and 1 or 0) > 1 then
    return nil, "--history, --recall and --evidence are three questions; ask one"
  end
  if not o.history then
    for _, k in ipairs(HISTORY_FIELDS) do
      if o[k] ~= nil then return nil, "--" .. k .. " narrows --history, which was not given" end
    end
  end
  if reading then
    if o.evidence == nil and #positional > 0 then
      return nil, "--history and --recall take no file: " .. safe(positional[1])
    end
    if o.evidence ~= nil and #positional > 2 then
      return nil, "--evidence takes an id, a part and at most one more word"
    end
    o.words = positional
    return o
  end

  -- `--steps` asks what the words are, which is a question about the harness and not
  -- about any declaration. Like `--help` and `--version`, it needs no file.
  if positional[1] == nil and not o.show_steps then
    return nil, "no declaration file given"
  end
  o.path = positional[1]
  for n = 2, #positional do o.words[#o.words + 1] = positional[n] end

  if o.prompt ~= nil and #o.words > 0 then
    return nil, "--prompt was given and so were prompt words; use one or the other"
  end

  if o.prompt ~= nil then
    o.prompt_source = "option"
  elseif o.prompt_file ~= nil then
    o.prompt_source = "file"
  elseif o.stdin then
    o.prompt_source = "stdin"
  elseif #o.words > 0 then
    o.prompt_source = "words"
    o.prompt = table.concat(o.words, " ")
  else
    o.prompt_source = "none"
  end

  return o
end

-- the sandbox

local function blocked(name)
  error(MARK_BLOCKED .. 'unknown name "' .. tostring(name)
    .. '" -- the declaration surface is agent.*', 3)
end

local function blocked_write(name)
  error(MARK_BLOCKED .. 'cannot assign to "' .. tostring(name)
    .. '" -- the declaration surface is read-only', 3)
end

local function policy_entry(a, allow, v)
  local e
  if type(v) == "string" then
    e = { tool = v }
  elseif type(v) == "table" then
    e = {}
    for k, x in pairs(v) do e[k] = x end
  else
    error("agent." .. (allow and "allow" or "deny")
      .. " takes a tool name or a policy entry, got " .. type(v), 3)
  end
  if allow then e.allow = true else e.deny = true end
  a.policy = a.policy or {}
  a.policy[#a.policy + 1] = e
end

-- The built-in vocabulary, rendered. `src/behaviour.lua` holds the one table; three
-- renderings read it: this, `agent.steps()`, and the stub `behaviour.check` prints.
function cli.steps_text(opts)
  local steps = behaviour.steps()
  local out = {}
  -- The heading, when this is written to a file rather than read at a terminal. It lives
  -- here rather than at the top of `docs/STEPS.md`, because a generated file with a
  -- hand-written header loses it on the next regeneration.
  if opts ~= nil and opts.heading then
    out[#out + 1] = "# The built-in step vocabulary\n\n"
    out[#out + 1] = "GENERATED from `src/behaviour.lua` by "
      .. "`lua bin/malleable.lua --steps --heading > docs/STEPS.md`. Never hand-edited: "
      .. "an expression is added in one place, and this is a rendering of it.\n\n"
    out[#out + 1] = "```\n"
  end
  -- The is phase first: what the agent is, said in a feature's Background (spec/declare.md).
  local declare = need_module("declare")
  local is = declare and declare.vocabulary() or {}
  for i = 1, #is do steps[#steps + 1] = is[i] end
  out[#out + 1] = fmt("The built-in vocabulary: %d expressions, version %d; the is phase, version %d.\n",
                      #steps, behaviour.VOCABULARY, declare and declare.VOCABULARY or 0)
  local phases = { { "is", "the agent, in the Background" }, { "given", "the world" },
                   { "when", "the run" }, { "then", "the result" } }
  for p = 1, #phases do
    out[#out + 1] = fmt("\n%s -- %s\n", phases[p][1], phases[p][2])
    for i = 1, #steps do
      if steps[i].phase == phases[p][1] then
        local tail = steps[i].scripts_model and "  (dropped in an eval)"
          or (steps[i].reach and steps[i].reach ~= "neither" and ("  (" .. steps[i].reach
              .. (steps[i].gate and "; a gate, never removed by an agent" or "") .. ")"))
          or ""
        out[#out + 1] = fmt("  %-58s %s%s\n", steps[i].expr, steps[i].about, tail)
      end
    end
  end
  if opts ~= nil and opts.heading then out[#out + 1] = "```\n" end
  return table.concat(out)
end

-- The declaration as `behaviour` sees it: three verbs and four facts, and nothing that
-- would let a feature reach past the surface a host has. Defined once, here, because
-- `agent.verify` and `--verify` are two doors onto one thing.
--- What the model is told each tool is, for a host that has only the prefix.
function cli.spec_schema(a) return spec.schema(a) end

function cli.drivers(a, run, opts)
  -- Every run a feature drives gets the declaration's stores as a view, whoever wrote
  -- `run`: binding twice is harmless, and forgetting once would hand a tool the raw port.
  -- The gate, as the live run builds it (cli.wire): the declaration's own policy and
  -- trust over the world's ask port, so `it may never call`, `it may always call` and
  -- `its trust is` hold in a scenario exactly as they hold in a run. Found missing by
  -- showcase/13-policy.feature, 2026-09-12: before this, a feature could state a policy
  -- and verify nothing about it.
  if approval then
    local plain = run
    run = function (prompt, port, ropts)
      local policy = {}
      for i = 1, #(a.policy or {}) do policy[#policy + 1] = a.policy[i] end
      local ok, gate = pcall(approval.new, { port = port, trust = a.trust or "ask", policy = policy })
      if not ok then error("the approval policy is not usable: " .. tostring(gate), 0) end
      local bound = cli.bind(port, gate, {})
      return plain(prompt, bound, ropts)
    end
  end
  if store then
    local plain = run
    run = function (prompt, port, ropts) return plain(prompt, store.bind(a, port), ropts) end
  end
  -- The servers, as the live run connects them: the world's mcp port says what each
  -- offers, and the tools are in the schema before the first model call.
  if mcp then
    local plain = run
    run = function (prompt, port, ropts)
      if type(a.server_order) == "table" and #a.server_order > 0 then pcall(mcp.connect, a, port) end
      return plain(prompt, port, ropts)
    end
  end
  -- The skill tool and the skills briefing, as the live run has them (cli.main, "the two
  -- seams"): a feature that says `it keeps a skill` can then verify the model reading it.
  -- Declared skills are reachable before any world; a workspace's only with the port.
  if skills then
    pcall(skills.ensure, a, nil)
    local inner = run
    run = function (prompt, port, ropts)
      pcall(skills.ensure, a, port)
      local ok, system = pcall(skills.system, a, port)
      if ok and system then
        local o = {}
        for k, v in pairs(ropts or {}) do o[k] = v end
        o.system = system
        ropts = o
      end
      return inner(prompt, port, ropts)
    end
  end
  local d = {
    run = run,
    check = function (world, o) return turn.check(a, world, o) end,
    steps = {}, tools = {}, asks = {}, beats = {},
    stores = a.stores, schema = function () return spec.schema(a) end,
  }
  for i = 1, #a.order do
    d.tools[a.order[i]] = true
    if a.tools[a.order[i]] and a.tools[a.order[i]].ask then d.asks[a.order[i]] = true end
  end
  for i = 1, #a.step_order do d.steps[#d.steps + 1] = a.steps[a.step_order[i]] end
  if #a.beat_order > 0 and schedule then
    for i = 1, #a.beat_order do d.beats[a.beat_order[i]] = true end
    d.tick = function (world, o)
      local wants = {}
      if o then for k, v in pairs(o) do wants[k] = v end end
      wants.run = wants.run or function (decl, prompt, port, ropts)
        return run(prompt, port, ropts)
      end
      local ran = schedule.tick(a, world, wants)
      -- A tick answers a list of what fired; a scenario asks about ONE run, so the last
      -- is the one its Then lines are about. A tick that fired nothing answers nothing,
      -- and the Then lines say so rather than reading a stale run.
      return type(ran) == "table" and ran[#ran] and ran[#ran].result or nil
    end
    d.mark = function (name, at)
      local beat = a.beats[name]
      if not beat then return nil end
      return schedule.key(a, beat), { at = at, grain = schedule.grain_key(beat, at) }
    end
  end
  return d
end

-- The declaration surface: the `agent.*` names a file writes through, bound to one agent
-- table. Exposed rather than kept inside the sandbox, because agent.lua binds the same
-- names for a file that is plain `require`d and one surface should have one definition.
--
-- `tool` and `on` take the curried form (`agent.tool "read" { ... }`) and the two-argument
-- form. Nothing here runs a body (rule 2).
function cli.surface(a)
  local surface = {
    name   = function (v) spec.set_name(a, v) end,
    model  = function (v) spec.set_model(a, v) end,
    system = function (v) spec.set_system(a, v) end,
    budget = function (v) spec.set_budget(a, v) end,
    reasoning = function (v) spec.set_reasoning(a, v) end,
    tool   = function (n, t)
      if t == nil then return function (d) return spec.add_tool(a, n, d) end end
      return spec.add_tool(a, n, t)
    end,
    on     = function (e, f)
      if f == nil then return function (g) return spec.add_hook(a, e, g) end end
      return spec.add_hook(a, e, f)
    end,
    -- The three later seams, declared the same way and running nothing: a procedure a
    -- person wrote, a beat, and a server whose tools live in another process.
    skill  = function (n, d)
      if d == nil then return function (x) return spec.add_skill(a, n, x) end end
      return spec.add_skill(a, n, d)
    end,
    every  = function (n, d)
      if d == nil then return function (x) return spec.add_beat(a, n, x) end end
      return spec.add_beat(a, n, d)
    end,
    uses   = function (n, d)
      if d == nil then return function (x) return spec.add_server(a, n, x) end end
      return spec.add_server(a, n, d)
    end,
    -- A store: the shape of what the program keeps. The rows are the host's (src/store.lua).
    store  = function (n, d)
      if d == nil then return function (x) return spec.add_store(a, n, x) end end
      return spec.add_store(a, n, d)
    end,
    -- A step of a feature file. On the surface rather than beside it, so a declaration
    -- loaded in the sandbox can declare one: a feature is not a thing only a host gets.
    step   = function (e, d)
      if behaviour == nil then error("agent.step: this build has no feature reader", 2) end
      if d == nil then return function (x) return behaviour.declare(spec, a, e, x) end end
      return behaviour.declare(spec, a, e, d)
    end,
    trust  = function (v)
      if type(v) ~= "string" or not TRUSTS[v] then
        error('agent.trust is "trusted", "ask" or "none"', 2)
      end
      a.trust = v
    end,
    allow  = function (v) policy_entry(a, true, v) end,
    deny   = function (v) policy_entry(a, false, v) end,
  }
  for k, v in pairs(spec.types) do surface[k] = v end
  return surface
end

-- A declaration gets its own copy of each library table. Handing it the real ones let a
-- file replace string.find for the whole process, and port.path_ok is built from string
-- functions, so poisoning them let `../` through every real filesystem port. A method call
-- on a string still reaches the real table through the string metatable, which nothing in
-- the sandbox can name.
local function library_copy(t, without)
  local out = {}
  for k, v in pairs(t) do
    if not (without and without[k]) then out[k] = v end
  end
  return out
end

-- A declaration's pcall and xpcall catch everything except the step bound, which they
-- hand straight back up. And xpcall runs its handler as an ordinary call once the error
-- has unwound, rather than inside the error machinery, where a handler that never
-- returned was out of the bound's reach. A declaration has no `debug`, so the stack the
-- handler sees is not something it can tell apart.
local function packed(...) return { n = select("#", ...), ... } end
local unpacked = table.unpack or unpack

local function is_bound(e)
  return type(e) == "string" and e:find(MARK_STEPS, 1, true) ~= nil
end

local function bounded_pcall(f, ...)
  local r = packed(pcall(f, ...))
  if not r[1] and is_bound(r[2]) then error(r[2], 0) end
  return unpacked(r, 1, r.n)
end

local function bounded_xpcall(f, handler, ...)
  local r = packed(pcall(f, ...))
  if r[1] then return unpacked(r, 1, r.n) end
  if is_bound(r[2]) then error(r[2], 0) end
  return false, handler(r[2])
end

-- The environment a declaration runs in, and the fresh agent table it writes into.
-- Exposed because the sandbox is the security boundary of the whole runner, and a
-- boundary you cannot construct in a test is a boundary nobody checks.
function cli.sandbox(cfg)
  cfg = cfg or {}
  local say  = type(cfg.say) == "function" and cfg.say or function () end
  local file = type(cfg.file) == "string" and cfg.file or "declaration"

  local a = spec.new()
  local wrote = {}

  local surface = cli.surface(a)

  -- `agent` is read-only: assigning to it, or to any field of it, raises with the
  -- name. A silent nil is how a misspelt agent.toool becomes a declaration with no
  -- tools and a confusing run three minutes later.
  local agent_proxy = setmetatable({}, {
    __index = function (_, k)
      local v = surface[k]
      if v == nil then blocked("agent." .. tostring(k)) end
      return v
    end,
    __newindex = function (_, k) blocked_write("agent." .. tostring(k)) end,
    __metatable = "agent",
  })

  local base = {
    agent    = agent_proxy,
    assert   = assert, error = error, ipairs = ipairs, pairs = pairs, next = next,
    select   = select, tonumber = tonumber, tostring = tostring, type = type,
    unpack   = table.unpack or unpack,
    pcall    = bounded_pcall, xpcall = bounded_xpcall,
    math     = library_copy(math),
    string   = library_copy(string, { dump = true }),
    table    = library_copy(table),
  }

  -- A declaration that narrates itself writes to the error stream, never to the
  -- stream a machine is parsing.
  base["print"] = function (...)
    local n = select("#", ...)
    local parts = {}
    for k = 1, n do parts[k] = tostring((select(k, ...))) end
    say(file .. ": " .. table.concat(parts, "\t"))
  end

  local env = setmetatable({}, {
    __index = function (_, k)
      local v = base[k]
      if v ~= nil then return v end
      blocked(k)
    end,
    __newindex = function (t, k, v)
      if base[k] ~= nil then blocked_write(k) end
      wrote[#wrote + 1] = tostring(k)
      rawset(t, k, v)
    end,
  })
  base._G = env

  return env, a, wrote
end

-- the load

local DEFAULT_LIMITS = { max_bytes = 262144, max_steps = 10000000 }

local function line_of(message)
  local n = tostring(message):match("^[^\n]-:(%d+):")
  return n and tonumber(n) or nil
end

local function strip_marker(message)
  local at = tostring(message):find(MARK_BLOCKED, 1, true)
  if not at then return nil end
  local head = message:sub(1, at - 1)
  local tail = message:sub(at + #MARK_BLOCKED)
  return head .. tail
end

-- Compiles text into the sandbox under both dialects: 5.4 and 5.5 take an
-- environment on load; 5.1 sets it on the compiled chunk.
local function compile(text, chunkname, env)
  if type(setfenv) == "function" and type(loadstring) == "function" then
    local chunk, err = loadstring(text, chunkname)
    if not chunk then return nil, err end
    setfenv(chunk, env)
    return chunk
  end
  return load(text, chunkname, "t", env)
end

-- Runs a compiled chunk under an instruction bound and answers in pcall's shape.
-- Nothing a person can name on the command line -- a declaration or a --script data
-- file -- gets to loop forever without the runner saying so. The third return is the
-- one-line warning owed to an interpreter that cannot enforce the bound at all.
local function run_bounded(chunk, max_steps)
  local hookable = type(debug) == "table" and type(debug.sethook) == "function"
    and type(coroutine) == "table"
  if not hookable then
    local ok, e = pcall(chunk)
    return ok, e, "this interpreter has no debug.sethook, so a declaration that never "
      .. "returns cannot be stopped"
  end
  -- A compiling interpreter checks a count hook only in the interpreter, so the chunk
  -- is held out of the compiler for the length of its run and handed back afterwards.
  -- Without this a `while true do end` compiles into a trace and is never counted.
  local compiler = type(jit) == "table" and type(jit.off) == "function" and jit
  if compiler then compiler.off(chunk, true) end
  local co = coroutine.create(chunk)
  -- The bound is sticky. Once it trips, every later instruction raises too, so a
  -- declaration's own `pcall` can catch the first error but cannot keep the loop alive:
  -- `while true do pcall(function () while true do end end) end` raises again the moment
  -- control is back outside the pcall.
  -- LuaJIT's hooks are global rather than per coroutine, so each one raises only while
  -- the declaration is the thread running, never in the loader that resumed it.
  local function every_step()
    if coroutine.running() == co then error(MARK_STEPS, 2) end
  end
  debug.sethook(co, function ()
    if coroutine.running() ~= co then return end
    debug.sethook(co, every_step, "", 1)
    error(MARK_STEPS, 2)
  end, "", max_steps)
  local ok, e = coroutine.resume(co)
  debug.sethook(co)
  if compiler and type(compiler.on) == "function" then compiler.on(chunk, true) end
  if ok and coroutine.status(co) ~= "dead" then
    ok, e = false, "the declaration stopped part way through"
  end
  return ok, e, nil
end

local function looks_empty(text)
  local stripped = text:gsub("%-%-%[%[.-%]%]", " "):gsub("%-%-%[=%[.-%]=%]", " "):gsub("%-%-[^\n]*", " ")
  return stripped:match("^%s*$") ~= nil
end

-- Loads a declaration into a fresh agent table. Never raises for anything a file can
-- contain: a file is data.
--
-- Returns `agent, warning` on success (warning may be nil) and `nil, err` on failure,
-- with err = { code, message, line }.
function cli.load(path, world, limits)
  limits = limits or DEFAULT_LIMITS
  local max_bytes = limits.max_bytes or DEFAULT_LIMITS.max_bytes
  local max_steps = limits.max_steps or DEFAULT_LIMITS.max_steps

  if type(path) ~= "string" or path == "" then
    return nil, { code = "missing", message = "no declaration file given" }
  end

  local text, why = world.read(path)
  if text == nil then
    if why == "missing" then
      return nil, { code = "missing", message = "no such file" }
    end
    return nil, { code = "unreadable", message = "read: " .. tostring(why) }
  end
  if type(text) ~= "string" then
    return nil, { code = "unreadable",
      message = "read: the host answered with a " .. type(text) }
  end
  if #text > max_bytes then
    return nil, { code = "too_big",
      message = #text .. " bytes, over the limit of " .. max_bytes }
  end
  -- Bytecode is refused before `load` is reached. Lua's bytecode loader is not a
  -- sandbox in 5.1 and is a memory-safety hazard in 5.4: this runner loads text.
  if text:sub(1, 1) == "\27" then
    return nil, { code = "binary", message = "this is a precompiled chunk, not text" }
  end
  if text:find("\0", 1, true) then
    return nil, { code = "binary", message = "this holds a zero byte, so it is not text" }
  end
  if looks_empty(text) then
    return nil, { code = "empty", message = "the file declares nothing" }
  end

  -- A feature file whose Background says what the agent is: the whole agent, in Gherkin
  -- (spec/declare.md). Nothing runs; a file a line names is read through the host, beside
  -- this one.
  if path:match("%.feature$") then
    local declare = need_module("declare", true)
    local dir = path:match("^(.*)[/\\][^/\\]*$")
    local a = spec.new()
    local info, why = declare.apply(text, a, {
      read = function (named)
        if dir and not named:match("^/") then named = dir .. "/" .. named end
        return world.read(named)
      end,
    })
    if not info then
      return nil, { code = "syntax", message = path .. ": " .. tostring(why), line = tonumber(tostring(why):match("^line (%d+)")) }
    end
    if info.count == 0 then
      return nil, { code = "empty", message = "this feature says what the agent does and not what it is: "
        .. "name the declaration, or say what it is in the Background (spec/declare.md)" }
    end
    a.load_notes, a.load_wrote = {}, {}
    return a
  end

  local notes = {}
  local env, a, wrote = cli.sandbox {
    file = path,
    say = function (line) notes[#notes + 1] = line end,
  }

  local chunk, err = compile(text, "@" .. path, env)
  if not chunk then
    return nil, { code = "syntax", message = tostring(err), line = line_of(err) }
  end

  local ok, e, warning = run_bounded(chunk, max_steps)

  if not ok then
    local message = tostring(e)
    if message:find(MARK_STEPS, 1, true) then
      return nil, { code = "too_long",
        message = path .. ": the declaration ran past " .. max_steps .. " steps without returning",
        line = line_of(message) }
    end
    local unmarked = strip_marker(message)
    if unmarked then
      return nil, { code = "blocked", message = unmarked, line = line_of(unmarked) }
    end
    return nil, { code = "raised", message = message, line = line_of(message) }
  end

  a.load_notes = notes
  -- A declaration that thinks it is keeping state across a run is a declaration with
  -- a bug, so the globals it created are carried out and reported under --verbose.
  a.load_wrote = wrote
  return a, warning
end

-- the problems

-- What spec says, plus what the runner itself requires. Never raises.
function cli.problems(agent, opts)
  local out = {}
  opts = opts or {}
  pcall(function ()
    local from_spec = spec.problems(agent)
    for i = 1, #from_spec do out[#out + 1] = from_spec[i] end

    if opts.model ~= nil and type(opts.model) ~= "string" then
      out[#out + 1] = "--model is a model id, and arrived as " .. type(opts.model)
    end

    -- A policy on a tool that does not exist is a typo, and it is the kind of typo
    -- that reads as safety while providing none.
    local declared = type(agent) == "table" and type(agent.tools) == "table" and agent.tools or {}
    local function check_named(list, flag)
      for i = 1, #list do
        local name = list[i]
        if declared[name] == nil then
          out[#out + 1] = flag .. ' names the tool "' .. safe(tostring(name))
            .. '", which this declaration does not declare'
        end
      end
    end
    check_named(opts.deny or {}, "--deny")
    check_named(opts.allow or {}, "--allow")
  end)
  return out
end

-- wiring

local function yes_port(record)
  return { request = function (q)
    record[#record + 1] = q.tool
    return { allow = true }
  end }
end

local function no_port(record)
  return { request = function (q)
    record[#record + 1] = q.tool
    return { allow = false, why = "refused, because --no was given" }
  end }
end

local function replies_of(opts, world)
  local list = {}
  if opts.script then
    local text, why = world.read(opts.script)
    if text == nil then
      return nil, "cannot read the script " .. opts.script .. ": "
        .. (why == "missing" and "no such file" or ("read: " .. tostring(why)))
    end
    if type(text) ~= "string" or text:sub(1, 1) == "\27" then
      return nil, "the script " .. opts.script .. " is not text"
    end
    local env = setmetatable({}, {
      __index = function (_, k)
        error('the script read the name "' .. tostring(k) .. '"', 2)
      end,
    })
    local chunk, err = compile(text, "@" .. opts.script, env)
    if not chunk then return nil, "the script " .. opts.script .. ": " .. tostring(err) end
    -- Bounded exactly as a declaration is: a data file a person named on the command
    -- line must not be able to hang the runner when the declaration beside it cannot.
    local ok, v = run_bounded(chunk, DEFAULT_LIMITS.max_steps)
    if not ok then
      local message = tostring(v)
      if message:find(MARK_STEPS, 1, true) then
        message = "it ran past " .. DEFAULT_LIMITS.max_steps .. " steps without returning"
      end
      return nil, "the script " .. opts.script .. ": " .. message
    end
    if type(v) ~= "table" then
      return nil, "the script " .. opts.script .. " must return a list of replies"
    end
    for i = 1, #v do list[#list + 1] = v[i] end
  end
  for i = 1, #opts.reply do list[#list + 1] = opts.reply[i] end
  return list
end

-- The one place that turns options into a world. It never substitutes a double for a
-- real port, and `--dry-run` is the only door to the doubles.
--
-- Returns `p, gate, warnings, asked` -- `asked` is the list of tool names --yes or
-- --no answered without a human, and is empty for every other run -- or `nil, reason`.
function cli.wire(opts, world, agent)
  local cfg = {
    root = opts.root, model = opts.model, timeout = opts.timeout,
    trust = opts.trust, session = opts.session,
    -- A conversation runs its talker and its jobs in coroutines: ports that yield their
    -- waits let a job's model call sit in the background (spec/speech.md, "Waits").
    yielding = opts.talk or nil,
  }

  local p
  if opts.dry_run then
    local list, why = replies_of(opts, world)
    if list == nil then return nil, why end
    local script = { model = { replies = list, after = #list > 0 and "repeat" or "error" } }
    local make = world.doubles or double.world
    local ok, made = pcall(make, script, cfg)
    if not ok or type(made) ~= "table" then
      return nil, "the doubles could not be built: " .. tostring(made)
    end
    p = made
  else
    if type(world.ports) ~= "function" then
      return nil, "no ports wired -- this build can only --dry-run"
    end
    local made, why = world.ports(cfg)
    if made == nil then
      return nil, "the world could not be wired: " .. tostring(why)
    end
    local missing = capport.check(made)
    if #missing > 0 then
      return nil, "the world is missing " .. table.concat(missing, ", ")
    end
    p = made
  end

  local warnings = {}

  -- The declaration's entries, then the command line's denies, then its allows.
  -- Denies first, because approval resolves denies before allows and the file must
  -- read the way it runs.
  local policy = {}
  if type(agent) == "table" and type(agent.policy) == "table" then
    for i = 1, #agent.policy do policy[#policy + 1] = agent.policy[i] end
  end
  for i = 1, #opts.deny do policy[#policy + 1] = { deny = true, tool = opts.deny[i] } end
  for i = 1, #opts.allow do policy[#policy + 1] = { allow = true, tool = opts.allow[i] } end

  local trust = opts.trust
    or (type(agent) == "table" and type(agent.trust) == "string" and agent.trust)
    or "ask"

  local asked = {}
  local aport = p
  if opts.yes then aport = yes_port(asked) end
  if opts.no  then aport = no_port(asked) end

  -- Which tools reach the gate at all. turn puts a call to the gate only when the
  -- tool declared `ask`; everything else runs with no policy and no trust setting
  -- consulted, and a person who typed --deny or --trust none is owed that fact.
  local asking, ungated = {}, {}
  if type(agent) == "table" and type(agent.order) == "table" then
    for i = 1, #agent.order do
      local name = agent.order[i]
      local t = agent.tools[name]
      if type(t) == "table" and t.ask then
        asking[#asking + 1] = name
      else
        ungated[#ungated + 1] = name
      end
    end
  end

  local can_ask = opts.yes or opts.no
    or (type(p.ask) == "table" and type(p.ask.request) == "function")
    or type(p.ask) == "function"
  if not can_ask then
    aport = nil
    -- Refusing to start would be defensible; starting silently would not. On a
    -- trusted workspace nothing is ever put to a human, so warning that every ask
    -- refuses would be a header that contradicts its own run.
    if #asking > 0 and trust ~= "trusted" then
      warnings[#warnings + 1] =
        "approvals: no one to ask -- any call that reaches the question refuses"
    end
  end

  -- A policy on a tool that never asks reads as safety and provides none, exactly as
  -- a policy on a tool that does not exist does. cli.problems refuses that one; this
  -- entry is well formed and cannot be refused, so it is said out loud instead.
  local named = {}
  local function name_from(e)
    if type(e) ~= "table" then return end
    if type(e.tool) == "string" then named[e.tool] = true end
    if type(e.tools) == "table" then
      for i = 1, #e.tools do
        if type(e.tools[i]) == "string" then named[e.tools[i]] = true end
      end
    end
  end
  for i = 1, #policy do name_from(policy[i]) end

  local inert = {}
  for i = 1, #ungated do
    if named[ungated[i]] or trust == "none" then inert[#inert + 1] = ungated[i] end
  end
  if #inert > 0 then
    warnings[#warnings + 1] = "policy: " .. table.concat(inert, ", ")
      .. (#inert == 1
        and " does not ask, so no policy and no trust setting is consulted before it runs"
        or " do not ask, so no policy and no trust setting is consulted before they run")
  end

  local ok, gate = pcall(approval.new, { port = aport, trust = trust, policy = policy })
  if not ok then
    return nil, "the approval policy is not usable: " .. tostring(gate)
  end
  return p, gate, warnings, asked
end

-- the bind

-- The adapter between the port table spec/port.md describes and the two functions
-- spec/turn.md wants -- the only file that knows both shapes, so the mismatch lives in one
-- named function with its own tests.
--
-- It carries the one fact neither document states: turn asks only for tools that declared
-- `ask`, so the request it forwards is marked `ask = true`. A gate that did not know would
-- let every asking tool through on the flag rule.
function cli.bind(p, gate, opts)
  local notes = {}
  local t = {}
  for k, v in pairs(p) do t[k] = v end

  local call
  if type(p.model) == "table" and type(p.model.call) == "function" then
    call = p.model.call
  elseif type(p.model) == "function" then
    call = p.model
  end

  t.model = function (request)
    if not call then return nil, "unavailable: no model port is wired" end
    local reply, err = call(request)
    if reply ~= nil then return reply end
    if type(err) == "table" then
      local code = type(err.code) == "string" and err.code or "error"
      local message = type(err.message) == "string" and err.message or code
      return nil, code .. ": " .. message
    end
    if err == nil then return nil, "the model port gave no reason" end
    return nil, tostring(err)
  end

  t.ask = function (q)
    local tool = type(q) == "table" and tostring(q.tool) or "(unnamed)"
    local ok, d = pcall(gate.check, gate, {
      tool   = type(q) == "table" and q.tool or nil,
      args   = type(q) == "table" and q.args or nil,
      ask    = true,
      reason = type(q) == "table" and q.about or nil,
    })
    if not ok or type(d) ~= "table" then
      notes[#notes + 1] = "the approval gate failed on " .. tool .. ": " .. tostring(d)
      return { allow = false, why = "the approval gate failed" }
    end
    if d.stop == true then
      notes[#notes + 1] = "the run was stopped at the gate on " .. tool
      return { stop = true, why = d.reason }
    end
    if d.allowed == true then
      return { allow = true, why = d.reason, args = d.args }
    end
    -- There is no path from any answer, any port failure or any missing port to an
    -- allow that a human did not take.
    notes[#notes + 1] = "the call to " .. tool .. " was refused ("
      .. tostring(d.source) .. "): " .. tostring(d.reason)
    return { allow = false, why = d.reason }
  end

  return t, notes
end

-- the renderer

local function sorted_keys(t)
  local nums, strs, other = {}, {}, {}
  for k in pairs(t) do
    if type(k) == "number" then nums[#nums + 1] = k
    elseif type(k) == "string" then strs[#strs + 1] = k
    else other[#other + 1] = tostring(k) end
  end
  table.sort(nums)
  table.sort(strs)
  table.sort(other)
  return nums, strs, other
end

local function render_value(v, depth, max_depth, seen, cap)
  local t = type(v)
  if t == "string" then
    local body = v:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. clip(body, cap) .. '"'
  end
  if t == "number" then return num(v) end
  if t == "boolean" or t == "nil" then return tostring(v) end
  if t ~= "table" then return "<" .. t .. ">" end
  -- The renderer holds a seen-set and never recurses on identity, so a table that
  -- contains itself renders as {...} at the point it repeats.
  if seen[v] then return "{...}" end
  if depth > max_depth then return "{...}" end
  seen[v] = true
  local nums, strs, other = sorted_keys(v)
  local parts = {}
  for i = 1, #nums do
    parts[#parts + 1] = render_value(v[nums[i]], depth + 1, max_depth, seen, cap)
  end
  for i = 1, #strs do
    parts[#parts + 1] = strs[i] .. " = "
      .. render_value(v[strs[i]], depth + 1, max_depth, seen, cap)
  end
  for i = 1, #other do parts[#parts + 1] = other[i] .. " = ?" end
  seen[v] = nil
  if #parts == 0 then return "{}" end
  return "{ " .. table.concat(parts, ", ") .. " }"
end

local function render_args(args, verbose)
  if type(args) ~= "table" then return "<" .. type(args) .. ">" end
  local cap = verbose > 0 and 100000 or ARG_BYTES
  local depth = verbose > 0 and 6 or 2
  return render_value(args, 1, depth, {}, cap)
end

-- Nothing it prints is unbounded, and the cut is stated exactly.
local function body_lines(text, show_lines)
  if type(text) ~= "string" then text = tostring(text) end
  local elided = 0
  local body = text
  if #body > RESULT_BYTES then
    elided = #body - RESULT_BYTES
    body = body:sub(1, RESULT_BYTES)
  end
  local all = {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do all[#all + 1] = line end
  if #all > 0 and all[#all] == "" then all[#all] = nil end

  local kept, note = {}, nil
  local n = math.min(#all, show_lines)
  for i = 1, n do kept[i] = all[i] end
  if elided > 0 then
    note = "(... " .. elided .. " bytes elided)"
  elseif #all > n then
    note = "(" .. (#all - n) .. " more lines)"
  end
  return kept, note
end

local function steps_phrase(steps, budget)
  return steps .. (steps == 1 and " step of " or " steps of ") .. budget
end

local function summary_of(result, info)
  local calls = type(result.calls) == "table" and result.calls or {}
  local n, refused = 0, 0
  for i = 1, #calls do
    local c = calls[i]
    if type(c) == "table" then
      n = n + 1
      if c.refused then refused = refused + 1 end
    else
      n = n + 1
    end
  end
  local steps = type(result.steps) == "number" and result.steps or 0
  local budget = type(result.budget) == "number" and result.budget or 0

  local line
  if result.stop == "budget" then
    line = "budget spent: " .. steps_phrase(steps, budget) .. ", no answer"
  else
    local head = result.stop == "answered" and "answered in "
      or (result.stop == "refused" and "refused after "
      or (result.stop == "error" and "error after " or "ended after "))
    line = head .. steps_phrase(steps, budget) .. ", " .. n
      .. (n == 1 and " call" or " calls")
    if refused > 0 then line = line .. ", " .. refused .. " refused" end
  end
  if info.elapsed then line = line .. ", " .. fmt("%.1fs", info.elapsed) end
  if info.dry then line = line .. ", DRY" end
  if type(result.entry) == "string" then line = line .. ", kept as " .. result.entry end
  return line
end

local function render_body(result, opts, info)
  local width = info.width or 80
  local verbose = opts.verbose or 0
  local blocks = {}

  local function block(lines)
    if #lines > 0 then blocks[#blocks + 1] = lines end
  end

  -- The header. Everything it names came from the options and the declaration.
  local head = {}
  local h = "pi  " .. (info.agent or "(unnamed)") .. "  " .. (info.model or "(no model)")
    .. "  budget " .. tostring(result.budget or info.budget or "?")
    .. "  root " .. (info.root or ".")
  if info.max_depth and info.max_depth ~= 3 then h = h .. "  depth " .. info.max_depth end
  head[#head + 1] = h
  head[#head + 1] = "approvals: " .. (info.approvals or "ask")
  for i = 1, #(info.warnings or {}) do head[#head + 1] = info.warnings[i] end
  if info.dry then
    for i = 1, #head do head[i] = "DRY " .. head[i] end
  end
  block(head)

  local transcript = type(result.transcript) == "table" and result.transcript or {}
  local by_id = {}
  for i = 1, #transcript do
    local m = transcript[i]
    if type(m) == "table" and m.role == "tool" and m.id ~= nil then by_id[m.id] = m end
  end

  local answer = type(result.answer) == "string" and result.answer or nil

  for i = 1, #transcript do
    local m = transcript[i]
    if type(m) ~= "table" then
      block { "! render: transcript entry " .. i .. " is a " .. type(m) }
    elseif m.role == "system" then
      if verbose >= 2 then
        block(wrapped("(system) " .. tostring(m.text), width, "> "))
      end
    elseif m.role == "user" then
      block(wrapped(tostring(m.text), width, "> "))
    elseif m.role == "agent" then
      local lines = {}
      local is_final = answer ~= nil and m.text == answer
        and (type(m.calls) ~= "table" or #m.calls == 0) and i == #transcript
      if not is_final then
        if type(m.text) == "string" and m.text ~= "" then
          local narration = wrapped(m.text, width, ". ")
          for k = 1, #narration do lines[#lines + 1] = narration[k] end
        end
        local calls = type(m.calls) == "table" and m.calls or {}
        for k = 1, #calls do
          local c = calls[k]
          if type(c) ~= "table" then
            lines[#lines + 1] = "! render: call " .. k .. " is a " .. type(c)
          else
            local tm = by_id[c.id]
            local refused = tm ~= nil and tm.refused == true
            local mark = refused and "x " or "-> "
            lines[#lines + 1] = mark .. tostring(c.tool) .. " " .. render_args(c.args, verbose)
            if tm ~= nil then
              local kept, note = body_lines(tm.text, opts.show_lines or 12)
              for j = 1, #kept do lines[#lines + 1] = "   " .. kept[j] end
              if note then lines[#lines + 1] = "   " .. note end
            end
          end
        end
      end
      block(lines)
    end
  end

  if type(result.err) == "table" then
    local where = type(result.err.where) == "string" and result.err.where or "run"
    local message = type(result.err.message) == "string" and result.err.message
      or (type(result.reason) == "string" and result.reason or "no reason given")
    block(wrapped(where .. ": " .. message, width, "! "))
  elseif result.stop == "error" then
    block(wrapped(type(result.reason) == "string" and result.reason or "the run failed",
      width, "! "))
  end

  if answer ~= nil then
    block(wrapped(answer, width, "= "))
  end

  if verbose >= 1 then
    local notes = {}
    local rn = type(result.notes) == "table" and result.notes or {}
    for i = 1, #rn do notes[#notes + 1] = "   note: " .. tostring(rn[i]) end
    for i = 1, #(info.notes or {}) do
      notes[#notes + 1] = "   note: " .. tostring(info.notes[i])
    end
    block(notes)
  end

  block { summary_of(result, info) }

  local out = {}
  for i = 1, #blocks do
    if i > 1 then out[#out + 1] = "" end
    for k = 1, #blocks[i] do out[#out + 1] = blocks[i][k] end
  end
  return table.concat(out, "\n") .. "\n"
end

-- Pure. Returns the text a run prints, with no escape sequence in it at all. Never
-- raises, for any result at all: a renderer that raises turns a failed run into no
-- output, which is the worst possible moment to have nothing to read.
function cli.render(result, opts, info)
  opts = opts or defaults()
  info = info or {}
  if type(result) ~= "table" then
    return safe("! render: the result is a " .. type(result)) .. "\n"
  end
  if opts.quiet then
    local answer = type(result.answer) == "string" and result.answer or ""
    return safe(answer) .. "\n"
  end
  local ok, text = pcall(render_body, result, opts, info)
  if not ok then
    return safe("! render: this result could not be rendered: " .. tostring(text)) .. "\n"
  end
  return safe(text)
end

-- Colour is applied after the text is settled, so every test asserts against the
-- uncoloured string and colour cannot change what a run says.
local PAINT = {
  ["! "] = "31", ["= "] = "32", ["x "] = "33", ["-> "] = "36", ["> "] = "34",
}

function cli.paint(text, on)
  if not on then return text end
  local out = {}
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do
    local painted = line
    for prefix, sgr in pairs(PAINT) do
      if line:sub(1, #prefix) == prefix then
        painted = "\27[" .. sgr .. "m" .. line:sub(1, #prefix - 1) .. "\27[0m" .. line:sub(#prefix)
        break
      end
    end
    out[#out + 1] = painted
  end
  if #out > 0 and out[#out] == "" then out[#out] = nil end
  return table.concat(out, "\n") .. "\n"
end

function cli.colour_on(opts, world)
  if opts.colour == false then return false end
  if type(world.env) == "function" and world.env("NO_COLOR") then return false end
  if opts.colour == true then return true end
  return world.colour == true
end

-- the plan

-- --dry-run with no script runs no model at all and prints what would happen.
function cli.plan(agent, opts, p, gate)
  local plan = {
    dry     = true,
    agent   = agent.name,
    model   = opts.model or agent.model,
    budget  = opts.budget or agent.budget,
    root    = opts.root,
    trust   = opts.trust or agent.trust or "ask",
    prompt  = opts.prompt or "",
    options = {},
    tools   = {},
    gate    = {},
    ports   = {},
    request = {},
  }

  local names = {}
  for k in pairs(KNOWN) do names[#names + 1] = k end
  table.sort(names)
  for i = 1, #names do
    local v = opts[names[i]]
    if v ~= nil and names[i] ~= "argv" then
      plan.options[#plan.options + 1] = { name = names[i], value = render_value(v, 1, 2, {}, ARG_BYTES) }
    end
  end

  local schema = spec.schema(agent)
  for i = 1, #schema do
    plan.tools[i] = schema[i]
    -- A tool that did not declare `ask` is never put to the gate by turn, so asking
    -- the gate about one and printing the answer would be a plan that says the
    -- opposite of the run. What is reported is what will happen: it runs, ungated,
    -- and no policy and no trust setting is consulted before it does.
    if schema[i].ask ~= true then
      plan.gate[i] = {
        tool      = schema[i].name,
        asks      = false,
        consulted = false,
        allowed   = true,
        source    = "declaration",
        reason    = "the tool does not ask, so the gate is not consulted",
      }
    else
      local ok, d = pcall(gate.check, gate, {
        tool = schema[i].name, args = {}, ask = true, reason = schema[i].about,
      })
      plan.gate[i] = {
        tool      = schema[i].name,
        asks      = true,
        consulted = true,
        allowed   = ok and d.allowed == true or false,
        source    = ok and tostring(d.source) or "gate",
        reason    = ok and tostring(d.reason) or tostring(d),
      }
    end
  end

  local wanted = { "model", "fs", "sh", "clock", "ask", "log", "store" }
  for i = 1, #wanted do
    plan.ports[i] = { name = wanted[i], wired = p[wanted[i]] ~= nil, kind = "double" }
  end

  local tool_names = {}
  for i = 1, #schema do tool_names[i] = schema[i].name end
  plan.request = {
    model    = plan.model,
    system   = type(agent.system) == "string",
    messages = 1,
    tools    = tool_names,
  }
  return plan
end

function cli.render_plan(plan, opts)
  opts = opts or defaults()
  local out = {}
  local function put(s) out[#out + 1] = s end

  put("DRY pi  " .. tostring(plan.agent) .. "  " .. tostring(plan.model)
    .. "  budget " .. tostring(plan.budget) .. "  root " .. tostring(plan.root))
  put("DRY approvals: " .. tostring(plan.trust) .. "  -- no model will be called")
  put("")
  put("options")
  for i = 1, #plan.options do
    put("   " .. plan.options[i].name .. " = " .. plan.options[i].value)
  end
  put("")
  put("tools")
  for i = 1, #plan.tools do
    local t = plan.tools[i]
    put("   " .. t.name .. (t.ask and "  (asks)" or "") .. "  -- " .. t.about)
    for k = 1, #t.args do
      local a = t.args[k]
      put("      " .. a.name .. "  " .. a.kind
        .. (a.required and "  required" or "  optional")
        .. (a.description ~= "" and ("  -- " .. a.description) or ""))
    end
  end
  put("")
  put("the gate, asked with no arguments")
  for i = 1, #plan.gate do
    local g = plan.gate[i]
    put("   " .. g.tool .. "  " .. (g.allowed and "allow" or "deny")
      .. "  (" .. g.source .. ") " .. g.reason)
  end
  put("")
  put("ports")
  for i = 1, #plan.ports do
    local pr = plan.ports[i]
    put("   " .. pr.name .. "  " .. (pr.wired and pr.kind or "not wired"))
  end
  put("")
  put("the first request")
  put("   model     " .. tostring(plan.request.model))
  put("   system    " .. (plan.request.system and "yes" or "no"))
  put("   messages  " .. tostring(plan.request.messages))
  put("   tools     " .. (#plan.request.tools > 0
    and table.concat(plan.request.tools, ", ") or "none"))
  put("")
  put("DRY nothing ran.")
  return safe(table.concat(out, "\n") .. "\n")
end

-- usage, tools

local USAGE = [[
pi [options] <declaration.lua> [prompt words ...]

  -p, --prompt TEXT       the prompt; refuses if prompt words were also given
      --prompt-file PATH  read the prompt from a file
      --stdin             read the prompt from standard input
      --budget N          steps this run may spend (default: the declaration's)
      --calls-per-step N  tool calls honoured in one reply (default 8)
      --max-depth N       how deep a nested run may go (default 3)
      --model ID          override agent.model for this run only
      --root PATH         the workspace root (default .)
      --timeout SECS      passed to the ports; the runner enforces nothing
      --trust WHICH       trusted, ask or none (default ask)
      --allow TOOL        append an allow entry to the policy; repeatable
      --deny TOOL         append a deny entry ahead of every allow; repeatable
  -y, --yes               answer every approval question yes
      --no                answer every approval question no
      --dry-run           use the doubles, never the host's ports
      --reply TEXT        a scripted model reply for --dry-run; repeatable
      --script PATH       a Lua data file of scripted replies for --dry-run
      --check             load, validate, report, run nothing
      --tools             print the tool schema the model would be sent
      --session PATH      save the transcript as one session record
      --verify           run the feature beside the declaration, against the doubles
      --talk             a conversation: a fast talker answers each line typed, and hands
                         work to this agent as background jobs; an empty line waits for
                         the jobs (spec/speech.md)
      --steps            print the built-in step vocabulary and exit
      --heading          with --steps, write it as the whole of docs/STEPS.md
      --feature PATH     run that feature file instead of the sibling one
      --history          the runs kept at --root, best first; narrowed by --day D,
                         --since D, --file PATH (a folder ends in /), --stop S,
                         --cause C, --agent NAME, --like ID; --limit N lines (10)
      --recall ID        one kept run's story (any part of the id that names one will do)
      --evidence ID PART [WHICH]
                         one part of its evidence: calls, call N, transcript, errors,
                         commands, files, diff PATH, kept N, model or all
                         (docs/spec/history.md)
      --json              print one JSON object on stdout; human text to stderr
      --show-lines N      lines of a tool result to render (default 12)
  -q, --quiet             print the final answer and nothing else
  -v, --verbose           repeatable; 1 adds arguments and notes, 2 every message
      --width N           wrap width (default: the terminal's, or 80)
      --no-colour         never emit an escape sequence
      --colour            force escape sequences on
      --                  ends options; every later argument is a positional
  -h, --help              print this and stop
      --version           print the version and stop
]]

function cli.usage()
  return USAGE
end

local function tools_text(agent)
  local out = { "pi  " .. tostring(agent.name) .. "  " .. tostring(agent.model) }
  local schema = spec.schema(agent)
  for i = 1, #schema do
    local t = schema[i]
    out[#out + 1] = "  " .. t.name .. (t.ask and "  (asks)" or "") .. "  -- " .. t.about
    for k = 1, #t.args do
      local a = t.args[k]
      out[#out + 1] = "     " .. a.name .. "  " .. a.kind
        .. (a.required and "  required" or "  optional")
        .. (a.description ~= "" and ("  -- " .. a.description) or "")
    end
  end
  return safe(table.concat(out, "\n") .. "\n")
end

local function check_text(agent, opts)
  local names = {}
  for i = 1, #agent.order do names[i] = agent.order[i] end
  local out = {
    "pi  " .. opts.path .. "  ok",
    "  agent   " .. tostring(agent.name),
    "  model   " .. tostring(opts.model or agent.model),
    "  budget  " .. tostring(opts.budget or agent.budget),
    "  tools   " .. (#names > 0 and table.concat(names, ", ") or "none"),
  }
  return safe(table.concat(out, "\n") .. "\n")
end

-- the JSON

local function json_string(s)
  local body = tostring(s):gsub('[%c"\\]', function (c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\t" then return "\\t" end
    if c == "\r" then return "\\r" end
    return fmt("\\u%04x", c:byte())
  end)
  return '"' .. body .. '"'
end

-- calls without their raw Lua `value`: a raw Lua value is not JSON, and guessing at
-- one is how a machine-readable mode starts lying.
local function calls_for_json(calls)
  local out = {}
  if type(calls) ~= "table" then return out end
  for i = 1, #calls do
    local c = calls[i]
    if type(c) == "table" then
      local copy = {}
      for k, v in pairs(c) do if k ~= "value" then copy[k] = v end end
      out[i] = copy
    else
      out[i] = { note = tostring(c) }
    end
  end
  return out
end

-- One object, encoded with the tree's own encoder, so there is one JSON implementation
-- and its edge cases are already tested. On an encode failure the fallback carries the
-- run's own code: the object and the exit status must never disagree.
local function json_object(object, code)
  local sessions = need_module("session", false)
  local text, why
  if sessions == nil then
    why = "this build has no session module, so there is no encoder"
  else
    text, why = sessions.encode(object)
  end
  if text == nil then
    return '{"stop":"error","reason":' .. json_string(why) .. ',"code":' .. code .. "}\n"
  end
  return text .. "\n"
end

-- the prompt

local function resolve_prompt(opts, world)
  local src = opts.prompt_source
  if src == "option" or src == "words" then return opts.prompt end
  if src == "file" then
    local text, why = world.read(opts.prompt_file)
    if text == nil then
      return nil, "cannot read the prompt file " .. opts.prompt_file .. ": "
        .. (why == "missing" and "no such file" or ("read: " .. tostring(why)))
    end
    if type(text) ~= "string" then
      return nil, "cannot read the prompt file " .. opts.prompt_file
        .. ": the host answered with a " .. type(text)
    end
    return text
  end
  if src == "stdin" then
    if type(world.stdin) ~= "function" then
      return nil, "--stdin was given, and this host has no standard input"
    end
    local text, why = world.stdin()
    if text == nil then
      return nil, "--stdin could not be read: " .. tostring(why)
    end
    return tostring(text)
  end
  return ""
end

-- the session

local ROLE_AT = 0

local function save_session(opts, world, p, agent, result)
  if not opts.session then return nil, nil end
  local sessions = need_module("session", false)
  if sessions == nil then
    return false, "this build has no session module"
  end
  if type(p.store) ~= "table" or type(p.store.write) ~= "function" then
    return false, "no store port is wired"
  end

  local at = type(world.now) == "function" and world.now() or ROLE_AT
  if type(at) ~= "number" then at = ROLE_AT end

  local ok, s = pcall(sessions.new, {
    id = opts.session, agent = agent.name, model = agent.model, started = at,
  })
  if not ok then return false, tostring(s) end

  local transcript = type(result.transcript) == "table" and result.transcript or {}
  for i = 1, #transcript do
    local m = transcript[i]
    if type(m) == "table" then
      local added, why
      if m.role == "system" then
        added, why = sessions.system(s, tostring(m.text or ""), at)
      elseif m.role == "user" then
        added, why = sessions.user(s, tostring(m.text or ""), at)
      elseif m.role == "agent" then
        added, why = sessions.model(s, tostring(m.text or ""), at)
        if added then
          local calls = type(m.calls) == "table" and m.calls or {}
          for k = 1, #calls do
            local c = calls[k]
            added, why = sessions.call(s, tostring(c.tool), c.args, tostring(c.id), at)
            if not added then break end
          end
        end
      elseif m.role == "tool" then
        added, why = sessions.result(s, tostring(m.id), tostring(m.text or ""),
          { ok = m.ok == true, refused = m.refused == true }, at)
      else
        added = true
      end
      if not added then
        return false, "message " .. i .. ": " .. tostring(why)
      end
    end
  end

  local id, why = sessions.save(s, p)
  if id == nil then return false, tostring(why) end
  return true, nil
end

-- the run

-- Everything after parsing. Returns `code, result`, or `nil, err` when the run never
-- started, with err.code the exit code cli.main should use.
function cli.run(opts, world)
  if type(opts) ~= "table" then
    return nil, { code = codes.usage, message = "opts is a table" }
  end
  for k in pairs(opts) do
    if not KNOWN[k] then
      return nil, { code = codes.usage, message = 'opts has no field "' .. tostring(k) .. '"' }
    end
  end

  local agent, err = cli.load(opts.path, world, nil)
  if agent == nil then
    local head
    if err.code == "syntax" or err.code == "blocked"
      or err.code == "raised" or err.code == "too_long" then
      head = err.message
    else
      head = "cannot read " .. tostring(opts.path) .. ": " .. err.message
    end
    return nil, { code = codes.load, message = head, why = err.code }
  end
  if err then world.err("pi: " .. safe(err) .. "\n") end
  local notes = agent.load_notes or {}
  agent.load_notes = nil
  for i = 1, #notes do world.err(safe(notes[i]) .. "\n") end
  local wrote = agent.load_wrote or {}
  agent.load_wrote = nil
  if (opts.verbose or 0) >= 1 then
    for i = 1, #wrote do
      world.err("pi: the declaration set the global " .. safe(wrote[i])
        .. ", which does not survive the load\n")
    end
  end

  local problems = cli.problems(agent, opts)
  if #problems > 0 then
    return nil, {
      code = codes.declaration,
      message = tostring(opts.path) .. " cannot run:",
      lines = problems,
    }
  end

  if type(opts.model) == "string" then agent.model = opts.model end

  -- Under --json stdout carries one object and nothing else, whatever was asked for,
  -- so a caller can pipe it into a parser. The human reading goes to the other stream.
  local function report(text, object)
    if opts.json then
      world.err(text)
      world.out(json_object(object, codes.answered))
    else
      world.out(text)
    end
    return codes.answered
  end

  if opts.show_tools then
    return report(tools_text(agent), {
      agent = agent.name, model = agent.model, code = codes.answered,
      tools = spec.schema(agent),
    })
  end
  -- `--check` on its own looks at the declaration; with a feature named it looks at the
  -- feature, which is the branch below. One flag, one meaning: look before you run.
  -- A declaration written as a feature is checked as one: its scenarios with it.
  local whole = type(opts.path) == "string" and opts.path:match("%.feature$") ~= nil
  if opts.check and not (opts.verify or opts.feature or whole) then
    return report(check_text(agent, opts), {
      agent = agent.name, model = agent.model, code = codes.answered,
      budget = opts.budget or agent.budget, tools = spec.schema(agent),
      problems = {},
    })
  end

  -- A feature file: what the agent DOES, run against the doubles. No prompt is resolved,
  -- because the scenario's `When` line is the prompt, and no real port is reached --
  -- `--verify` has no door to one.
  if opts.verify or opts.feature or (opts.check and whole) then
    if not (gherkin and behaviour) then
      return nil, { code = codes.world, message = "this build has no feature reader" }
    end
    -- A declaration written as a feature is its own feature file.
    local at = opts.feature
      or (tostring(opts.path):match("%.feature$") and opts.path)
      or (tostring(opts.path):gsub("%.lua$", "") .. ".feature")
    local text, why_read = world.read(at)
    if text == nil then
      return nil, { code = codes.usage,
        message = at .. ": " .. (why_read == "missing" and "no such feature file" or tostring(why_read)) }
    end
    -- The is lines come out and the shorthands are expanded (spec/declare.md). A feature
    -- that says what the agent is, beside a Lua declaration, is two declarations of one
    -- agent, and the runner will not guess which one wins.
    local declare = need_module("declare", true)
    if at ~= opts.path and declare.declares(text) then
      return nil, { code = codes.usage, message = at .. " says what the agent is, so it is the declaration: "
        .. "run it as one, --verify " .. at }
    end
    local pickles, bad = declare.pickles(text, agent)
    if not pickles then
      return nil, { code = codes.declaration, message = at .. " cannot be read:", lines = { bad } }
    end
    local drivers = cli.drivers(agent, function (prompt, port, ropts)
      local topts = { calls_per_step = opts.calls_per_step, max_depth = opts.max_depth }
      if ropts and ropts.budget then topts.budget = ropts.budget end
      if opts.budget then topts.budget = opts.budget end
      if type(agent.name) == "string" then topts.id = agent.name end
      local bound = store.bind(agent, port)
      local depth = declare.enter(bound)
      local ok, result = pcall(turn.run, agent, prompt, bound, topts)
      declare.leave(depth)
      if not ok then error(result, 0) end
      return result
    end)

    if opts.check then
      local problems = behaviour.check(pickles, drivers)
      if #problems == 0 then
        world.out(at .. ": " .. #pickles .. " scenario(s), nothing to report\n")
        return codes.answered
      end
      for i = 1, #problems do world.out(at .. ":" .. problems[i] .. "\n") end
      return codes.declaration
    end

    local report = behaviour.run(pickles, drivers, { eval = false })
    world.out(behaviour.report(report, { verbose = (opts.verbose or 0) >= 1 }))
    return report.ok and codes.answered or codes.declaration
  end

  if opts.talk then return cli.talk(opts, world, agent) end

  local prompt, why = resolve_prompt(opts, world)
  if prompt == nil then
    return nil, { code = codes.usage, message = why }
  end

  local p, gate, warnings = cli.wire(opts, world, agent)
  if p == nil then
    return nil, { code = codes.world, message = gate }
  end

  -- The header says so before the first model call. It cannot be printed with the
  -- rest of the header, which is rendered from a run that has not happened yet.
  for i = 1, #warnings do world.err("pi: " .. safe(warnings[i]) .. "\n") end

  if opts.dry_run and #opts.reply == 0 and opts.script == nil then
    world.out(cli.render_plan(cli.plan(agent, opts, p, gate), opts))
    return codes.answered
  end

  local tport, notes_from_bind = cli.bind(p, gate, opts)

  local topts = { calls_per_step = opts.calls_per_step, max_depth = opts.max_depth }
  if opts.budget then topts.budget = opts.budget end
  if type(agent.name) == "string" then topts.id = agent.name end

  -- The two seams a declaration NAMES and a run REACHES: the skill tool, so a briefed
  -- procedure can actually be opened, and the servers, whose tools have to be in the
  -- schema before the first model call. Both run here rather than at declaration time,
  -- which is rule 2, and a server that is down is a warning rather than a dead run.
  do
    if skills then
      local ok_ensure, err_ensure = pcall(skills.ensure, agent, tport)
      if not ok_ensure then world.err("pi: " .. safe(tostring(err_ensure)) .. "\n") end
      local ok_system, system, clashes = pcall(skills.system, agent, tport)
      if ok_system and system then
        topts.system = system
        for i = 1, #(clashes or {}) do
          world.err("pi: the workspace and this declaration both hold a skill called "
            .. safe(clashes[i]) .. "; the declared one is the one that will be read\n")
        end
      end
    end
    if mcp and type(agent.server_order) == "table" and #agent.server_order > 0 then
      local _, mcp_problems = mcp.connect(agent, tport)
      for i = 1, #(mcp_problems or {}) do world.err("pi: " .. safe(mcp_problems[i]) .. "\n") end
    end
  end

  local ok, problems2 = turn.check(agent, tport, topts)
  if not ok then
    return nil, { code = codes.world, message = "this run cannot start:", lines = problems2 }
  end

  -- cli never invents a clock, and never lets one it was handed cost a run its
  -- answer: a host whose now() raises or answers with something that is not a number
  -- gets no timing clause, exactly as a host with no clock at all does.
  local function tick()
    if type(world.now) ~= "function" then return nil end
    local ok, at = pcall(world.now)
    if ok and type(at) == "number" and at == at then return at end
    return nil
  end

  local t0 = tick()
  -- The world a delegate declared in a feature file hands its child, for this run.
  local declare = need_module("declare")
  local depth = declare and declare.enter(tport)
  -- Kept as a `cli` entry when the world has a history (docs/spec/history.md), with the
  -- feature text it was declared from.
  local run = turn.run
  local history = need_module("history")
  if history then
    run = history.keeper(turn.run)
    local feature = type(opts.path) == "string" and opts.path:match("%.feature$") and world.read(opts.path) or nil
    topts.entry = { cause = "cli", declaration = type(feature) == "string" and feature or nil }
  end
  local ran, result = pcall(run, agent, prompt, tport, topts)
  if declare then declare.leave(depth) end
  if not ran then
    return nil, { code = codes.error, message = "the run could not start: " .. tostring(result) }
  end
  local t1 = tick()

  local code = codes.of(result.stop) or codes.error

  local saved, save_why = save_session(opts, world, p, agent, result)
  if save_why then
    world.err("pi: the session was not saved: " .. safe(save_why) .. "\n")
  end

  local approvals = opts.yes and "yes to everything (--yes)"
    or (opts.no and "no to everything (--no)"
    or (opts.trust or agent.trust or "ask"))

  local function terminal_width()
    if type(world.width) ~= "function" then return nil end
    local ok, w = pcall(world.width)
    return ok and tonumber(w) or nil
  end

  local width = opts.width or terminal_width() or 80
  if width < 20 then width = 20 end

  local info = {
    agent = agent.name, model = agent.model, root = opts.root,
    budget = result.budget, approvals = approvals, dry = opts.dry_run,
    max_depth = opts.max_depth, width = width, warnings = warnings,
    notes = notes_from_bind,
    elapsed = (t0 and t1) and (t1 - t0) or nil,
  }

  local human = cli.paint(cli.render(result, opts, info), cli.colour_on(opts, world))

  if opts.json then
    world.out(json_object({
      agent = agent.name, model = agent.model, dry = opts.dry_run == true,
      stop = result.stop, reason = result.reason, answer = result.answer,
      steps = result.steps, budget = result.budget,
      calls = calls_for_json(result.calls), notes = result.notes,
      transcript = result.transcript, err = result.err,
      session = opts.session, saved = saved == true, code = code, entry = result.entry,
    }, code))
    world.err(human)
  else
    world.out(human)
  end

  return code, result
end

-- --talk: a conversation, turn by turn (spec/speech.md, "The doors"). Each line typed is a
-- turn; the talker answers it; work it hands off runs in the background while the next
-- line is answered. An empty line waits for the jobs and hears their reports, and so does
-- the end of the input, so a piped script of lines runs to its end.
function cli.talk(opts, world, agent)
  local speech = need_module("speech")
  if not speech then return nil, { code = codes.world, message = "this build has no speech module" } end
  if type(world.line) ~= "function" then
    return nil, { code = codes.world, message = "--talk needs a host that reads a line at a time" }
  end
  local p, gate, warnings = cli.wire(opts, world, agent)
  if p == nil then return nil, { code = codes.world, message = gate } end
  for i = 1, #warnings do world.err("pi: " .. safe(warnings[i]) .. "\n") end
  local tport = cli.bind(p, gate, opts)
  local declare = need_module("declare")

  local run = function (d, prompt, port, ropts)
    local o = { calls_per_step = opts.calls_per_step, max_depth = opts.max_depth }
    for k, v in pairs(ropts or {}) do o[k] = v end
    local bound = store.bind(d, port)
    local depth = declare and declare.enter(bound)
    local ok, result = pcall(turn.run, d, prompt, bound, o)
    if declare then declare.leave(depth) end
    if not ok then error(result, 0) end
    return result
  end
  local ok, c = pcall(speech.new, {
    workers = { [agent.name] = agent }, world = tport, run = run,
    job_budget = opts.budget, proactive = false,
    -- --yes and --no answer the jobs' questions here; otherwise the person does, by talking
    relay = not (opts.yes or opts.no),
  })
  if not ok then return nil, { code = codes.declaration, message = tostring(c) } end

  local out = world.out
  local function sleep()
    if type(world.sleep) == "function" then pcall(world.sleep, 0.03) end
  end
  c.on = function (event, data)
    if event == "job" then
      if data.state == "running" and data.steps == 0 then
        out("  (" .. data.id .. " started: " .. data.worker .. ")\n")
      elseif data.state ~= "running" and data.state ~= "asking" and data.state ~= "starting" then
        out("  (" .. data.id .. " " .. data.state .. ", " .. data.steps .. " steps)\n")
      end
    elseif event == "question" then
      out("  (" .. data.id .. " asks to run " .. safe(data.tool) .. ")\n")
    elseif event == "failed" then
      out("  (the talker failed: " .. safe(tostring(data.reason)) .. ")\n")
    end
  end
  local function running()
    local n = 0
    for _, j in ipairs(c:jobs()) do
      if j.state == "running" or j.state == "starting" or j.state == "asking" then n = n + 1 end
    end
    return n
  end
  local function say_all()
    local s = c:take()
    local any = false
    while s do out("  " .. c.talker.name .. ": " .. s .. "\n"); c:said(); any = true; s = c:take() end
    return any
  end
  local function drive(done)
    for _ = 1, 100000 do
      c:update()
      local said = say_all()
      if done() then return end
      if not said then sleep() end
    end
  end
  local function wait_for_reports()
    drive(function () return #c.reports > 0 or running() == 0 end)
    if #c.reports > 0 then
      c:deliver()
      drive(function () return not c:busy() end)
      return true
    end
    return false
  end

  out("talking to " .. agent.name .. " (" .. tostring(agent.model) .. ") through "
    .. c.talker.name .. " (" .. tostring(c.talker.model) .. "). An empty line waits for the jobs.\n")
  local first = opts.prompt
  while true do
    local line = first
    first = nil
    if line ~= nil then
      out("> " .. line .. "\n")
    else
      out("> ")
      line = world.line()
    end
    if line == nil then break end
    if line:match("%S") then
      c:heard(line)
      drive(function () return not c:busy() end)
    elseif not wait_for_reports() then
      out("  (no job is running)\n")
    end
  end
  -- the end of the input: every job finishes and is heard
  while running() > 0 or #c.reports > 0 do
    if not wait_for_reports() then break end
  end
  out("\n")
  return codes.answered
end

-- the main

local REQUIRED_WORLD = { "out", "err", "read" }
local OPTIONAL_WORLD = { "ports", "doubles", "stdin", "env", "width", "now", "line", "sleep" }

local function check_world(world)
  if type(world) ~= "table" then
    error("cli.main: `world` is a table of host functions, and arrived as "
      .. type(world), 3)
  end
  for i = 1, #REQUIRED_WORLD do
    local name = REQUIRED_WORLD[i]
    if type(world[name]) ~= "function" then
      error("cli.main: `world." .. name .. "` is a function, and arrived as "
        .. type(world[name]), 3)
    end
  end
  for i = 1, #OPTIONAL_WORLD do
    local name = OPTIONAL_WORLD[i]
    if world[name] ~= nil and type(world[name]) ~= "function" then
      error("cli.main: `world." .. name .. "` is a function or nil, and arrived as "
        .. type(world[name]), 3)
    end
  end
  if world.colour ~= nil and type(world.colour) ~= "boolean" then
    error("cli.main: `world.colour` is a boolean or nil, and arrived as "
      .. type(world.colour), 3)
  end
end

local function main_body(argv, world)
  local opts, problem = cli.parse(argv)
  if opts == nil then
    world.err("pi: " .. safe(problem) .. "\n")
    world.err(cli.usage())
    return codes.usage
  end
  if opts.help then
    world.out(cli.usage())
    return codes.answered
  end
  if opts.version then
    world.out("pi " .. cli.version .. "\n")
    return codes.answered
  end
  -- The built-in step vocabulary. No declaration is needed to ask what the words are,
  -- and `docs/STEPS.md` is rendered from exactly this and never hand-edited.
  if opts.show_steps then
    if behaviour == nil then
      world.err("pi: this build has no feature reader\n")
      return codes.world
    end
    world.out(cli.steps_text({ heading = opts.heading == true }))
    return codes.answered
  end

  if opts.history or opts.recall or opts.evidence then return cli.look_back(opts, world) end

  local code, second = cli.run(opts, world)
  if code ~= nil then return code end

  local e = second
  world.err("pi: " .. safe(e.message) .. "\n")
  for i = 1, #(e.lines or {}) do
    world.err("  " .. safe(e.lines[i]) .. "\n")
  end
  return e.code
end

-- --history, --recall, --evidence: what the workspace at --root kept (docs/spec/history.md),
-- read through the host's history port. Nothing runs and nothing is kept.
function cli.look_back(opts, world)
  local history = need_module("history")
  if not history or type(world.ports) ~= "function" then
    world.err("pi: this build keeps no history\n")
    return codes.world
  end
  local ok, made, why = pcall(world.ports, { root = opts.root, only = "history" })
  local hp = ok and type(made) == "table" and made.history or nil
  if not hp then
    world.err("pi: this host keeps no history" .. ((why or not ok) and (": " .. safe(tostring(why or made))) or "") .. "\n")
    return codes.world
  end
  local h = history.open(hp)
  local text, problem
  if opts.recall then
    text, problem = history.recall(h, opts.recall)
  elseif opts.evidence then
    text, problem = history.evidence(h, opts.evidence, opts.words[1], opts.words[2], true)
  else
    local q = {}
    for _, k in ipairs(HISTORY_FIELDS) do q[k] = opts[k] end
    local found
    found, problem = history.find(h, q)
    if found then
      local lines = {}
      for i, r in ipairs(found) do lines[i] = history.line(r) end
      text = #lines > 0 and table.concat(lines, "\n")
        or (#h.rows > 0 and "no kept run matches that" or ("no runs are kept at " .. tostring(opts.root)))
    end
  end
  if not text then
    world.err("pi: " .. safe(tostring(problem)) .. "\n")
    return codes.usage
  end
  world.out((safe(text):gsub("\n?$", "\n")))
  return codes.answered
end

-- The whole runner. Never returns nil, never raises for anything in argv, and never
-- ends the program. It raises only for a malformed world, naming the field, because
-- a host that wired the runner wrong is a defect in the program.
function cli.main(argv, world)
  check_world(world)
  local ok, code = pcall(main_body, argv or {}, world)
  if ok and type(code) == "number" then return code end
  world.err("pi: internal fault: " .. safe(tostring(code)) .. "\n")
  return codes.error
end

return cli
