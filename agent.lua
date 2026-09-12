-- agent — the one prefix.
--
--   local agent = require "agent"
--
--   agent.name  "reviewer"
--   agent.model "openrouter:z-ai/glm-5.3"
--   agent.tool "read" {
--     about = "Read a file",
--     args  = { path = agent.string "workspace-relative path" },
--     run   = function (c) return c.fs.read(c.args.path) end,
--   }
--   local result = agent.run("look at src/turn.lua", port)
--
-- Everything hangs off `agent`: no handle to thread, no builder to close, no `return` at
-- the end of a declaration file. Requiring this module is what makes the names exist.
--
-- The package.path gesture below is a convenience for a tree on disk and is guarded, not
-- required: an embedding host fills `package.preload` and has neither a path nor `debug`.
if type(debug) == "table" and type(debug.getinfo) == "function" and type(package) == "table" then
  local info = debug.getinfo(1, "S")
  local here = info and info.source and info.source:match("^@(.*)[/\\][^/\\]*$")
  if here then package.path = here .. "/src/?.lua;" .. (package.path or "") end
end

-- Either name may already be loaded, depending on how the host set the path up.
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
local command    = part "command"
local work       = part "work"
local subagent   = part "subagent"
local session    = part "session"
local gherkin    = part "gherkin"
local behaviour  = part "behaviour"
local observe    = part "observe"
local change     = part "change"
local trace      = part "trace"
local provider   = part "provider"
local config     = part "config"
local compaction = part "compaction"
local interpret  = part "interpret"
local skills     = part "skills"
local schedule   = part "schedule"
local mcp        = part "mcp"
local store      = part "store"
local kits       = part "kits"
local declare    = part "declare"
local speech     = part "speech"
local history    = part "history"
local wait       = part "wait"

-- small helpers

local function fail(fmt, ...)
  error("agent: " .. string.format(fmt, ...), 3)
end

-- The one-value setters, wrapped to answer with the prefix so a host may chain.
-- cli.surface's own setters answer with nothing, which is what the sandbox wants.
local SETTERS = { "name", "model", "system", "budget", "reasoning", "trust", "allow", "deny" }

-- Writes the declaration surface onto the prefix, bound to one agent table. `agent.reset`
-- calls it again: these closures hold the agent table they were built for.
local function bind(s, a)
  local raw = cli.surface(a)
  for k, v in pairs(raw) do s[k] = v end
  for i = 1, #SETTERS do
    local set = raw[SETTERS[i]]
    s[SETTERS[i]] = function (v) set(v); return s end
  end
end

-- One run, kept when its world has a history (src/history.lua). A declared store is reached
-- through its view (src/store.lua), and the world a delegate declared in a feature file
-- hands its child is entered around the loop (src/declare.lua).
local kept_run = history.keeper(function (decl, prompt, p, opts)
  local bound = store.bind(decl, p)
  local depth = declare.enter(bound)
  local ok, result = pcall(turn.run, decl, prompt, bound, opts)
  declare.leave(depth)
  if not ok then error(result, 0) end
  return result
end)

-- `run` takes both shapes; both arrive as (declaration, prompt, port, opts).
local function run_args(bound, first, second, third, fourth)
  if type(first) == "table" and type(second) == "string" then
    return first, second, third, fourth      -- agent.run(other, prompt, port, opts)
  end
  return bound, first, second, third         -- agent.run(prompt, port, opts)
end

-- the prefix

-- Builds one prefix bound to one agent table. `agent.new()` mints another, so two agents
-- can be declared in one process without either seeing the other's tools.
-- A feature is pickled once, here, so both verbs read the same flat list.
-- The is lines are taken out (they were applied to the declaration, not run) and the
-- shorthands expanded, so a feature that says what the agent is and one that only says
-- what it does are walked the same way.
local function behaviour_pickles(feature, a)
  if type(feature) ~= "string" then
    error("a feature is the text of a .feature file, and arrived as " .. type(feature), 3)
  end
  return declare.pickles(feature, a)
end

local function prefix()
  local a = spec.new()
  local s = {}
  local declared_text = nil             -- the feature file this agent was declared from
  bind(s, a)

  -- The same table `agent.run` runs and `turn.run` reads, handed out rather than copied.
  function s.spec() return a end

  -- Start over on a fresh agent table; every closure below reads `a` as it stands.
  function s.reset()
    a = spec.new()
    declared_text = nil
    bind(s, a)
    return s
  end

  function s.new() return prefix() end

  -- Toolkits. Each declares through this same prefix, so a toolkit's tool and a
  -- hand-written one are the same kind of thing by the time the model sees them.

  -- read, write, edit, list, glob, search; the shell tool, which asks by default (rule 4);
  -- and the two plan tools, plan and mark. Declared through src/kits.lua, which the is lines
  -- of a feature file declare through too, so the two doors cannot drift.
  function s.files(opts) return kits.files(a, opts, s) end
  function s.shell(opts) return kits.shell(a, opts) end
  function s.plan(opts) return kits.plan(opts, s) end
  -- history, recall and evidence: the three tools that read the runs this agent's world has
  -- kept (docs/spec/history.md). None writes.
  function s.history() return kits.history(s) end

  -- One tool plus the briefing that says what it can ask for. Declared skills and
  -- whatever the `skills` port lists arrive the same way. Callable and a module at once,
  -- so `agent.skills()` installs and `agent.skills.body` reads.
  s.skills = setmetatable({}, {
    __index    = skills,
    __call     = function (_, opts) return skills.install(s, opts) end,
    __metatable = "agent.skills",
  })

  -- the seams

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
    if o.run == nil then
      o.run = function (d, prompt, port, ropts, beat)
        -- A recorder per beat, not per tick: `result.spans` on each row is then that
        -- beat's own tree and nothing else's, which is what a caller reading one row
        -- expects. The beat's span is the root and the run hangs under it, so a trace in
        -- a collector says which scheduled thing produced it -- the same join
        -- `malleable.scenario` makes for a feature file.
        local tracer = turn.recorder(port and port.clock, port and port.log, 0)
        local name = type(beat) == "table" and beat.name or nil
        local span = tracer.open_span("malleable.beat " .. tostring(name or "beat"), nil, {})
        local ro = {}
        if ropts then for k, v in pairs(ropts) do ro[k] = v end end
        ro.tracer, ro.parent = tracer, span
        if ro.entry == nil then ro.entry = { cause = "beat" } end   -- kept as a beat (docs/spec/history.md)
        local ok, result = pcall(s.run, d, prompt, port, ro)
        if not ok then
          tracer.close_span(span, {}, false)
          tracer.close_all()
          error(result, 0)
        end
        tracer.close_span(span, {
          ["malleable.stop"] = type(result) == "table" and result.stop or "error",
        }, type(result) == "table" and result.stop ~= "error")
        return result
      end
    end
    return schedule.tick(decl, p, o)
  end

  -- A tool that runs another declared agent. Curried like `agent.tool`.
  function s.delegate(name, cfg)
    local function declare(c) return kits.delegate(a, name, c) end
    if cfg == nil then return declare end
    return declare(cfg)
  end

  -- running

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

    -- The run's own tree starts HERE, not in the loop: catalogueing skills and connecting
    -- servers is part of invoking this agent, and a recorder built inside `turn.run` would
    -- not exist yet.
    --
    -- A run started through another prefix -- `agent.tick` firing a beat, a delegate
    -- calling back in -- hands its own recorder and parent down, so a tick is one tree.
    local o = {}
    if opts then for k, v in pairs(opts) do o[k] = v end end
    opts = o
    local tracer = opts.tracer
    local parent = opts.parent
    opts.parent = nil
    if not tracer then
      tracer = turn.recorder(p and p.clock, p and p.log, opts.depth or 0)
      opts.tracer = tracer
    end
    if not opts.run_span then
      opts.run_span = tracer.open_span(
        "invoke_agent " .. tostring(decl and decl.name or "agent"), parent, {
          ["gen_ai.operation.name"] = "invoke_agent",
          ["gen_ai.agent.name"] = tostring(decl and decl.name or "agent"),
          ["gen_ai.request.model"] = tostring(decl and decl.model or ""),
          ["malleable.budget"] = opts.budget or (decl and decl.budget) or 0,
          ["malleable.depth"] = opts.depth or 0,
        })
    end

    pcall(skills.ensure, decl, p)
    if type(decl) == "table" and type(decl.server_order) == "table" and #decl.server_order > 0 then
      -- One span per server reached, timed around the call that reaches it -- a server
      -- that hangs is the failure this span exists for, and a single span around the
      -- whole loop would hide which one hung.
      local watch = function (name)
        local span = tracer.open_span("malleable.server " .. tostring(name), opts.run_span, {})
        return function (reached, tools)
          tracer.close_span(span, { ["malleable.tools"] = tools or 0 }, reached == true)
        end
      end
      local _, said = mcp.connect(decl, p, { watch = watch })
      for i = 1, #(said or {}) do problems[#problems + 1] = said[i] end
    end

    -- One span for the catalogue and the briefing composed from it. A skill BODY is read
    -- by the skill tool during a step, and is already an `execute_tool skill` span there;
    -- what has never been visible is how many procedures this run was briefed on at all,
    -- which is the number that says whether the agent had anything to follow.
    local skill_span = tracer.open_span("malleable.skill", opts.run_span, {})
    local ok_system, system, clashes = pcall(skills.system, decl, p)
    local catalogued = 0
    do
      local ok_count, have = pcall(skills.catalogue, decl, p)
      if ok_count and type(have) == "table" then catalogued = #have end
    end
    tracer.close_span(skill_span, { ["malleable.skills"] = catalogued }, ok_system)
    if ok_system and system then
      if opts.system == nil then opts.system = system end
      for i = 1, #(clashes or {}) do
        problems[#problems + 1] = "the workspace and this declaration both hold a skill called "
          .. string.format("%q", clashes[i]) .. "; the declared one is the one that will be read"
      end
    end

    -- The problems go in as notes the run STARTS with rather than being spliced on after
    -- it: a server that was never reached is a fact about the whole run and not about the
    -- step that noticed, and going in this way is what makes `malleable.notes` count them.
    if #problems > 0 then opts.notes = problems end
    -- Kept (docs/spec/history.md): a world with a history keeps every run, as a story and
    -- its evidence, under an id claimed before the run, with this agent's feature text when
    -- it was declared in one.
    if decl == a and declared_text and opts.entry ~= false then
      local e = {}
      for k, v in pairs(type(opts.entry) == "table" and opts.entry or {}) do e[k] = v end
      if e.declaration == nil then e.declaration = declared_text end
      opts.entry = e
    end
    local ok, result = pcall(kept_run, decl, prompt, p, opts)
    if not ok then error(result, 0) end
    return result
  end

  -- What the agent IS, from a feature file: the is lines of its Background applied to this
  -- agent, as if each were the `agent.*` statement it names. A statement like the others,
  -- so a Lua declaration may hold `agent.declare(text)` and a feature may say the rest.
  -- Raises with the sentence and the line on a file it will not read, as every other
  -- declaration statement does. `opts.read(path)` reads a file a line names.
  function s.declare(text, opts)
    local info, why = declare.apply(text, a, opts)
    if not info then error("agent.declare: " .. tostring(why), 2) end
    declared_text = text                -- kept with each run's evidence (docs/spec/history.md)
    return s
  end

  -- A conversation with a talker in front and this agent behind it, doing the work as
  -- background jobs (spec/speech.md). `cfg` is speech.new's; with no `workers`, this agent
  -- is the one worker, and every run goes through this prefix's own `run`, so a worker's
  -- stores, skills and servers are bound as they are for any run. Callable and a module at
  -- once, like `agent.skills`: `agent.speech { world = port }` starts one, and
  -- `agent.speech.talker { model = ... }` builds a talker to give it.
  s.speech = setmetatable({}, {
    __index = speech,
    __call = function (_, cfg)
      if cfg ~= nil and type(cfg) ~= "table" then
        fail("agent.speech takes a table of options, got %s", type(cfg))
      end
      local o = {}
      for k, v in pairs(cfg or {}) do o[k] = v end
      if o.workers == nil then
        if not a.name then fail("agent.speech: the agent needs a name to be a worker") end
        o.workers = { [a.name] = a }
      end
      -- s.run keeps each run itself, with the feature text (src/history.lua)
      if o.run == nil then o.run = history.keeps(function (d, prompt, port, ro) return s.run(d, prompt, port, ro) end) end
      return speech.new(o)
    end,
    __metatable = "agent.speech",
  })

  -- The embed door: a whole world with nothing from the host -- a working shell over a
  -- filesystem in memory, a frozen clock, a gate, a log, and a model that says plainly it
  -- is not there.
  --
  -- Distinct from `agent.world`, which is the TEST double: its defaults are a test's, so
  -- nothing runs that was not scripted. An embedder wants the opposite default.
  --
  -- The gate DEFAULTS TO REFUSING; a host that wants otherwise says `ask = true`.
  function s.sandbox(cfg)
    if cfg ~= nil and type(cfg) ~= "table" then
      fail("agent.sandbox takes a table of options or nothing, got %s", type(cfg))
    end
    local o = {}
    if cfg then for k, v in pairs(cfg) do o[k] = v end end
    o.shell = o.shell ~= false
    if o.clock == nil then o.clock = { at = 0 } end
    if o.ask == nil then o.ask = false end
    return double.world(o)
  end

  -- the behaviour half
  --
  -- A declaration says what the agent IS. A feature file says what it DOES, in the
  -- language somebody would have used to ask for it, and these two verbs run it.
  -- `spec/behaviour.md` is the contract; the built-in vocabulary covers the harness
  -- itself, so the common case needs no `agent.step` at all.

  -- The declaration as `behaviour` sees it: three verbs and four facts, and nothing
  -- that would let a feature reach past the surface a host has.
  local function drivers()
    local d = {
      run = function (prompt, world, opts) return s.run(prompt, world, opts) end,
      check = function (world, opts)
        local ok, reasons = s.check(world, opts)
        return ok, reasons
      end,
      steps = {}, tools = {}, asks = {}, beats = {},
      -- The same two facts `cli.drivers` gives: a store's Then lines read its declared
      -- shape, and `the tool {word} tells the model` reads the schema.
      stores = a.stores, schema = function () return spec.schema(a) end,
    }
    for i = 1, #a.order do
      local name = a.order[i]
      d.tools[name] = true
      if a.tools[name] and a.tools[name].ask then d.asks[name] = true end
    end
    for i = 1, #a.step_order do d.steps[#d.steps + 1] = a.steps[a.step_order[i]] end
    if #a.beat_order > 0 then
      for i = 1, #a.beat_order do d.beats[a.beat_order[i]] = true end
      d.tick = function (world, opts)
        local ran = s.tick(world, opts)
        -- A tick answers a list of what fired; a scenario asks about ONE run, so the
        -- last one is the one its Then lines are about. A tick that fired nothing
        -- answers nothing, and the Then lines say so rather than reading a stale run.
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

  -- The built-in vocabulary, as a list. `docs/STEPS.md` is rendered from this.
  function s.steps() return behaviour.steps() end

  -- Run a feature against this declaration on the doubles. Answers the report table;
  -- `behaviour.report` renders it, because this tree has no idea what stdout is.
  function s.verify(feature, opts)
    local pickles, why = behaviour_pickles(feature, a)
    if not pickles then return nil, why end
    return behaviour.run(pickles, drivers(), opts)
  end

  -- The SAME feature file, against a real model, k times per scenario, answering a rate.
  --
  -- The world stays doubled and only the model is real. The two given lines that script a
  -- model are dropped, and a scenario whose expectations only made sense against a scripted
  -- one is reported not evaluable rather than scored.
  --
  -- No model judges anything: the Then lines are the same deterministic comparisons in both
  -- modes. What is nondeterministic is the system under test.
  ---@param feature string
  ---@param model table   the host's model port -- the one thing that is real
  ---@param opts table|nil  { samples = 20 }
  function s.evaluate(feature, model, opts)
    local pickles, why = behaviour_pickles(feature, a)
    if not pickles then return nil, why end
    if type(model) ~= "table" and type(model) ~= "function" then
      return nil, "an eval needs the host's model port; the rest of the world stays doubled"
    end
    local o = {}
    if opts then for k, v in pairs(opts) do o[k] = v end end
    o.eval = { model = model, samples = (opts and opts.samples) or 20 }
    return behaviour.run(pickles, drivers(), o)
  end

  -- The problems a run would hit, as sentences, reaching no port at all. This is what an
  -- editor runs on every keystroke and what `--check` prints.
  function s.check_feature(feature)
    local pickles, why = behaviour_pickles(feature, a)
    if not pickles then return { why } end
    return behaviour.check(pickles, drivers())
  end

  -- the rest of the tree
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
  s.store      = store          -- a program's declared tables of rows, and the view a tool body reaches
  s.interpret  = interpret
  s.port       = capport
  s.provider   = provider
  s.session    = session
  s.behaviour  = behaviour
  s.observe    = observe        -- a run read back as a scenario, and the repertoire kept
  s.change     = change         -- what a declaration may alter about itself, and what it may not
  s.trace      = trace
  s.gherkin    = gherkin
  s.declared   = declare        -- an agent written in Gherkin, and the edits it may make to itself
  s.subagent   = subagent
  s.tools_fs   = tools_fs
  s.tools_sh   = tools_sh
  s.turn       = turn
  s.work       = work
  s.cli        = cli
  s.wait       = wait           -- the table a port yields: host, sleep, person (spec/speech.md)

  return s
end

return prefix()
