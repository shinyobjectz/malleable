-- agent — the one prefix.
--
--   local agent = require "agent"
--
--   agent.name  "reviewer"
--   agent.model "openrouter:inception/mercury-2.5"
--   agent.tool "read" {
--     about = "Read a file",
--     args  = { path = agent.string "workspace-relative path" },
--     run   = function (c) return c.fs.read(c.args.path) end,
--   }
--   local result = agent.run("look at src/turn.lua", port)
--
-- Everything the harness offers hangs off `agent`. There is no handle to thread, no
-- builder to close and no `return` at the end of a declaration file: the file is the
-- declaration, and requiring this module is what makes the names exist.
--
-- This file requires nothing outside the tree. It puts its own `src/` on package.path
-- first, so `require "agent"` works with only the tree root on the path, and so does
-- `dofile ".../agent.lua"` with nothing on it at all.
--
-- Both of those are conveniences for a tree ON DISK, and a host that EMBEDS this one has
-- neither a path nor a `debug` library to find itself with: it fills `package.preload`
-- and there is no directory to name. So the whole gesture is guarded rather than
-- required. Before this, loading the prefix in an embedded interpreter failed on line
-- one with `attempt to index a nil value (global 'debug')` — a library that cannot be
-- loaded without `debug` is a library that cannot be embedded, which is most of what a
-- harness is for.
if type(debug) == "table" and type(debug.getinfo) == "function" and type(package) == "table" then
  local info = debug.getinfo(1, "S")
  local here = info and info.source and info.source:match("^@(.*)[/\\][^/\\]*$")
  if here then package.path = here .. "/src/?.lua;" .. (package.path or "") end
end

-- A module may already be loaded under either name, depending on how the host set the
-- path up. Both are tried before the path is blamed.
local function part(name)
  local ok, m = pcall(require, name)
  if ok then return m end
  local ok2, m2 = pcall(require, "src." .. name)
  if ok2 then return m2 end
  error("agent: the module " .. name .. " is not on the path (" .. tostring(m) .. ")", 2)
end

local spec       = part "spec"
local turn       = part "turn"
local capport    = part "port"
local approval   = part "approval"
local double     = part "double"
local cli        = part "cli"
local tools_fs   = part "tools_fs"
local tools_sh   = part "tools_shell"
local work       = part "work"
local subagent   = part "subagent"
local session    = part "session"
local provider   = part "provider"
local config     = part "config"
local compaction = part "compaction"
local interpret  = part "interpret"
local skills     = part "skills"
local schedule   = part "schedule"
local mcp        = part "mcp"

-- ---------------------------------------------------------------- small helpers

local function fail(fmt, ...)
  error("agent: " .. string.format(fmt, ...), 3)
end

-- The names that take one value and answer with the prefix, so `agent.name "x"` reads
-- as a statement and a host that prefers a chain gets one. cli.surface's own setters
-- answer with nothing, which is what the sandbox wants; the wrapping happens here.
local SETTERS = { "name", "model", "system", "budget", "trust", "allow", "deny" }

-- Writes the declaration surface onto the prefix, bound to one agent table. Called
-- again by `agent.reset`, because those closures hold the agent table they were built
-- for and nothing can make them let go of it.
local function bind(s, a)
  local raw = cli.surface(a)
  for k, v in pairs(raw) do s[k] = v end
  for i = 1, #SETTERS do
    local set = raw[SETTERS[i]]
    s[SETTERS[i]] = function (v) set(v); return s end
  end
end

-- `run` is written two ways, because a host holds a declaration in a variable and a
-- declaration file does not. Both arrive as (declaration, prompt, port, opts).
local function run_args(bound, first, second, third, fourth)
  if type(first) == "table" and type(second) == "string" then
    return first, second, third, fourth      -- agent.run(other, prompt, port, opts)
  end
  return bound, first, second, third         -- agent.run(prompt, port, opts)
end

-- ------------------------------------------------------------------- the prefix

-- Builds one prefix table bound to one agent table. The module's own `agent` is the
-- first of these; `agent.new()` mints another, so two agents can be declared in one
-- process without either seeing the other's tools.
local function prefix()
  local a = spec.new()
  local s = {}
  bind(s, a)

  -- What has been declared so far. The same table `agent.run` runs and `turn.run`
  -- reads; handed out rather than copied, because a host that wants to inspect a
  -- declaration wants the one that will run.
  function s.spec() return a end

  -- Start over on a fresh agent table. Everything on this prefix follows, because
  -- every closure below reads `a` as it stands now.
  function s.reset()
    a = spec.new()
    bind(s, a)
    return s
  end

  function s.new() return prefix() end

  -- ------------------------------------------------------------------ toolkits
  --
  -- Each of these declares through this same prefix, so a toolkit's tool and a
  -- hand-written one are the same kind of thing by the time the model sees them.

  -- The filesystem tools: read, write, edit, list, glob, search. With no `opts.port`
  -- they read the filesystem the harness hands the tool body, which is the usual way:
  -- the port that runs the turn is the port the tools see.
  --
  -- Installed through a shim, because the bodies answer with a result table and a
  -- transcript holds text. `tools_fs.render` turns one into the other; without it the
  -- model reads "the tool returned a table of 8 entries" and never sees the file.
  function s.files(opts)
    local shim = {}
    for k, v in pairs(s) do shim[k] = v end
    shim.tool = function (name, def)
      local function declare(d)
        local body = d.run
        d.run = function (c) return tools_fs.render(body(c)) end
        return spec.add_tool(a, name, d)
      end
      if def == nil then return declare end
      return declare(def)
    end
    return tools_fs.install(shim, opts)
  end

  -- The shell tool. It asks by default, which is rule 4 and not this file's decision.
  --
  -- `name` and `root` are lifted out first: shell.options refuses an option it does
  -- not know, and neither of those is one of its options. `root` is the workspace root
  -- the tool reports and resolves a cwd against; tools_shell wants it on the tool
  -- context, and a port table has no such field, so it is filled in here for a run
  -- that does not carry one.
  function s.shell(opts)
    if opts ~= nil and type(opts) ~= "table" then
      fail("agent.shell takes a table of options or nothing, got %s", type(opts))
    end
    local name, root, rest = "shell", ".", nil
    if opts ~= nil then
      rest = {}
      for k, v in pairs(opts) do
        if k == "name" then name = v
        elseif k == "root" then root = v
        else rest[k] = v end
      end
    end
    if type(name) ~= "string" or name == "" then
      fail("agent.shell: `name` is the tool's name, as a non-empty string")
    end
    if type(root) ~= "string" or root == "" then
      fail("agent.shell: `root` is the workspace root, as a non-empty string")
    end

    local decl = tools_sh.tool(rest)
    local body = decl.run
    decl.run = function (c)
      if c.root == nil then c.root = root end
      -- One value out. tools_shell answers with the rendered block and the result
      -- table behind it, and a second return through the harness is dropped with a
      -- note on every call; a host that wants the structure calls shell.run itself.
      return (body(c))
    end
    return spec.add_tool(a, name, decl)
  end

  -- The two plan tools, plan and mark, over one live plan.
  function s.plan(opts) return work.install(s, opts) end

  -- The skill tool: one tool, and the briefing that tells the model what it can ask
  -- for. Declared skills and whatever the `skills` port lists arrive the same way.
  --
  -- Callable and a module at once, so `agent.skills()` installs and `agent.skills.body`
  -- reads. Two names for one seam is how a tree grows a second, drifting surface.
  s.skills = setmetatable({}, {
    __index    = skills,
    __call     = function (_, opts) return skills.install(s, opts) end,
    __metatable = "agent.skills",
  })

  -- ------------------------------------------------------------------ the seams

  -- Ask every declared server for its tools and add them. Run time, not declaration
  -- time: rule 2. `agent.run` does this itself when a server is declared, so a host
  -- calls it only to see what came back before running.
  function s.connect(p, opts) return mcp.connect(a, p, opts) end

  -- `tick` and `due` take a declaration the way `run` does, because a host that LOADED
  -- one — through `cli.load`, which is the only safe door for a file a person edited —
  -- holds a table this prefix has never seen. Without this, an embedded host could run
  -- a loaded declaration and could not tick it, which is the same agent behaving
  -- differently depending on who started it.
  local function beat_args(first, second, third)
    if type(first) == "table" and type(first.beats) == "table" then return first, second, third end
    return a, first, second
  end

  -- What the beats would do right now, without doing any of it.
  function s.due(first, second, third)
    local decl, p, opts = beat_args(first, second, third)
    return schedule.due(decl, p, opts)
  end

  -- NOT `s.plan`: that name is the two plan tools (`work.install`), declared above. The
  -- line a person reads about the beats is `agent.schedule.plan(declaration, port)`,
  -- which takes the declaration already. One prefix means one name per thing, and the
  -- collision this avoided would have silently replaced a toolkit with a report.

  -- One tick. Everything due runs, in declaration order, each recorded in the ledger
  -- before it starts. A host with a beat calls this; nothing in the tree calls it for
  -- you, because a harness that starts runs on its own is a harness rule 2 does not
  -- describe any more.
  function s.tick(first, second, third)
    local decl, p, opts = beat_args(first, second, third)
    -- Through this prefix's own `run`, so a run the clock started is briefed exactly as
    -- one a person typed is: same skills, same servers, same composition.
    local o = {}
    if opts then for k, v in pairs(opts) do o[k] = v end end
    if o.run == nil then o.run = function (d, prompt, port, ropts) return s.run(d, prompt, port, ropts) end end
    return schedule.tick(decl, p, o)
  end

  -- A tool that runs another declared agent. Curried like `agent.tool`.
  function s.delegate(name, cfg)
    local function declare(c) return spec.add_tool(a, name, subagent.tool(c)) end
    if cfg == nil then return declare end
    return declare(cfg)
  end

  -- ------------------------------------------------------------------- running

  -- What the model will be told these tools are.
  function s.schema() return spec.schema(a) end

  -- Why this declaration cannot run, as a list of sentences. Empty means it can.
  function s.problems() return spec.problems(a) end

  -- The same checks `run` does, without running: true, or false and the reasons.
  function s.check(port, opts) return turn.check(a, port, opts) end

  -- Run against a port table. The port is the world: model, fs, sh, clock, ask, log.
  -- A gate built by `agent.gate` is bound in with `agent.bind` first.
  function s.run(first, second, third, fourth)
    local decl, prompt, p, opts = run_args(a, first, second, third, fourth)
    -- A declared server is reached HERE and not at declaration time, and the problems
    -- it reports become notes on the run rather than a raised error: an agent that also
    -- reads files should not fail to start because one server is down.
    -- The three things a declaration NAMES and a run REACHES, in the order they have to
    -- happen: the skill tool must exist before the briefing names it, the briefing must
    -- be composed before the first model call, and a server's tools must be in the
    -- schema before the model is shown one.
    local problems = {}
    pcall(skills.ensure, decl, p)
    if type(decl) == "table" and type(decl.server_order) == "table" and #decl.server_order > 0 then
      local _, said = mcp.connect(decl, p, opts)
      for i = 1, #(said or {}) do problems[#problems + 1] = said[i] end
    end
    local ok_system, system, clashes = pcall(skills.system, decl, p)
    if ok_system and system then
      opts = opts and (function () local o = {} for k, v in pairs(opts) do o[k] = v end return o end)() or {}
      if opts.system == nil then opts.system = system end
      for i = 1, #(clashes or {}) do
        problems[#problems + 1] = "the workspace and this declaration both hold a skill called "
          .. string.format("%q", clashes[i]) .. "; the declared one is the one that will be read"
      end
    end
    local result = turn.run(decl, prompt, p, opts)
    -- On the run's own notes, where a person reading the run will find them, and in
    -- front of the notes the run made: a server that was never reached is a fact about
    -- the whole run and not about the step that noticed.
    if #problems > 0 and type(result) == "table" and type(result.notes) == "table" then
      for i = #problems, 1, -1 do table.insert(result.notes, 1, problems[i]) end
    end
    return result
  end

  -- ------------------------------------------------------- the rest of the tree
  --
  -- Named on the prefix so there is still one thing to remember. These are the
  -- modules, not more declaration surface: a host reaches for them, a declaration
  -- file rarely does.

  s.mcp        = mcp
  s.schedule   = schedule
  s.gate       = approval.new       -- (opts) -> a gate, for agent.bind
  s.bind       = cli.bind           -- (port, gate, opts) -> the port turn reads
  s.world      = double.world       -- (cfg) -> a whole world in memory, for tests
  s.stops      = turn.stops         -- the four ways a run ends
  s.approval   = approval
  s.compaction = compaction
  s.config     = config
  s.double     = double
  s.interpret  = interpret
  s.port       = capport
  s.provider   = provider
  s.session    = session
  s.subagent   = subagent
  s.tools_fs   = tools_fs
  s.tools_sh   = tools_sh
  s.turn       = turn
  s.work       = work
  s.cli        = cli

  return s
end

return prefix()
