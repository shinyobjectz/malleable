-- The declaration surface. Rule 2: this builds a table and runs nothing.
--
-- Every entry point is a setter that returns the agent table, so a file reads as a
-- list of statements rather than a builder chain that has to be closed.

local spec = {}



local function fail(fmt, ...)
  error(string.format(fmt, ...), 3)
end

-- The granularities a beat may dedup on. "ever" is the one that never repeats, which
-- is how a one-shot is said without a second word for it.
local GRAINS = { hour = 3600, day = 86400, week = 604800, ever = "ever" }
spec.grains = GRAINS

local function is_param(v)
  return type(v) == "table" and v.__param == true
end

-- Argument types. `agent.string "why"` reads as a type and its description on one
-- line, which keeps a tool signature legible at a glance.
local function param(kind, required)
  return function (description)
    if description ~= nil and type(description) ~= "string" then
      fail("an argument's description is a string, got %s", type(description))
    end
    return { __param = true, kind = kind, required = required, description = description or "" }
  end
end

-- A string limited to a closed list, which the model is told as a list and the person
-- can step through at the gate. `agent.one_of "where the lamp goes" { "near", "far" }`,
-- or `agent.one_of { "near", "far" }` with no description.
local function one_of(required)
  local function make(choices, description)
    if type(choices) ~= "table" or #choices < 2 then
      fail("agent.one_of takes a list of at least two values, like { \"near\", \"far\" }")
    end
    local seen = {}
    for i = 1, #choices do
      if type(choices[i]) ~= "string" or choices[i] == "" then
        fail("agent.one_of: value %d is %s, and each value is a non-empty string", i, type(choices[i]))
      end
      if seen[choices[i]] then fail("agent.one_of: %q is listed twice", choices[i]) end
      seen[choices[i]] = true
    end
    local copy = {}
    for i = 1, #choices do copy[i] = choices[i] end
    return { __param = true, kind = "string", required = required, description = description or "",
             choices = copy }
  end
  return function (x)
    if type(x) == "table" then return make(x, nil) end
    if x ~= nil and type(x) ~= "string" then
      fail("agent.one_of takes a description and then the list: agent.one_of \"why\" { \"a\", \"b\" }")
    end
    return function (choices) return make(choices, x) end
  end
end

spec.types = {
  one_of      = one_of(true),
  one_of_opt  = one_of(false),
  string      = param("string",  true),
  string_opt  = param("string",  false),
  number      = param("number",  true),
  number_opt  = param("number",  false),
  boolean     = param("boolean", true),
  boolean_opt = param("boolean", false),
  table       = param("object",  true),
  table_opt   = param("object",  false),
  list        = param("array",   true),
  list_opt    = param("array",   false),
}

-- A fresh, empty agent. Held in a table rather than a module upvalue so two agents
-- can be declared in one process without leaking into each other.
function spec.new()
  return {
    name = nil, model = nil, system = nil,
    budget = 24,             -- rule 5: every run ends
    tools = {},              -- name -> tool
    order = {},              -- declaration order, so the model sees a stable list
    hooks = {},              -- event -> { fn, ... }
    skills = {},             -- name -> skill        (src/skills.lua)
    skill_order = {},
    beats = {},              -- name -> beat         (src/schedule.lua)
    beat_order = {},
    servers = {},            -- name -> mcp server   (src/mcp.lua)
    server_order = {},
    stores = {},             -- name -> store        (src/store.lua)
    store_order = {},
    steps = {},              -- expression -> step   (src/behaviour.lua)
    step_order = {},
  }
end

function spec.set_name(a, v)
  if type(v) ~= "string" or v == "" then fail("agent.name takes a non-empty string") end
  a.name = v
end

function spec.set_model(a, v)
  if type(v) ~= "string" or v == "" then fail("agent.model takes a model id, like \"openrouter:z-ai/glm-5.3\"") end
  a.model = v
end

function spec.set_system(a, v)
  if type(v) ~= "string" then fail("agent.system takes a string") end
  a.system = v
end

-- How hard the model thinks before it answers, where the model can be told: a room a
-- person waits on wants "low", a review wants "high". Unset, the model's own default.
spec.REASONING = { none = true, low = true, medium = true, high = true }

function spec.set_reasoning(a, v)
  if not spec.REASONING[v] then
    fail("agent.reasoning takes \"none\", \"low\", \"medium\" or \"high\", got %s", tostring(v))
  end
  a.reasoning = v
end

function spec.set_budget(a, v)
  if type(v) ~= "number" or v < 1 or v ~= math.floor(v) then
    fail("agent.budget takes a whole number of steps, at least 1")
  end
  a.budget = v
end

-- Rule 3: a tool is a name, a why, typed arguments and a body.
spec.EFFECTS = { reads = true, writes = true, recalls = true, runs = true, starts = true }

function spec.add_tool(a, name, t)
  if type(name) ~= "string" or name == "" then fail("a tool needs a name") end
  if a.tools[name] then fail("the tool %q is declared twice", name) end
  if type(t) ~= "table" then fail("agent.tool %q takes a table, got %s", name, type(t)) end
  if type(t.about) ~= "string" or t.about == "" then
    fail("the tool %q needs `about`: a tool the model cannot understand is one it will misuse", name)
  end
  if type(t.run) ~= "function" then fail("the tool %q needs `run = function (c) ... end`", name) end

  local args, order = {}, {}
  if t.args ~= nil then
    if type(t.args) ~= "table" then fail("the tool %q: `args` is a table of name = agent.<type> \"why\"", name) end
    for k, v in pairs(t.args) do
      if type(k) ~= "string" then fail("the tool %q: an argument name is a string", name) end
      if not is_param(v) then
        fail("the tool %q: argument %q must be one of agent.string / number / boolean / table / list (or its _opt form)", name, k)
      end
      args[k] = v
      order[#order + 1] = k
    end
    table.sort(order)
  end

  -- `ask = { edit = "where" }` asks the person, who may change the named arguments
  -- before approving: a one_of steps through its list, a boolean flips, a number steps
  -- by one. The tool gets what the person approved (spec/turn.md, "Edits at the gate").
  local ask, edit = t.ask, nil
  if type(ask) == "table" then
    local names = ask.edit
    if type(names) == "string" then names = { names } end
    if type(names) ~= "table" or #names == 0 then
      fail("the tool %q: `ask` is true, false, or { edit = \"<argument>\" }", name)
    end
    edit = {}
    for i = 1, #names do
      local p = args[names[i]]
      if not p then fail("the tool %q: `ask.edit` names %q, which is not one of its arguments", name, tostring(names[i])) end
      if not (p.choices or p.kind == "boolean" or p.kind == "number") then
        fail("the tool %q: the person can edit a one_of, a boolean or a number at the gate, and %q is %s",
          name, names[i], p.kind)
      end
      edit[#edit + 1] = names[i]
    end
    ask = true
  elseif ask ~= nil and type(ask) ~= "boolean" then
    fail("the tool %q: `ask` is true, false, or { edit = \"<argument>\" }", name)
  end

  -- Requirements: what a call must meet before it runs. `says` is told to the model with
  -- the tool's about unless `check_only`; `check(c)` reads the call and the world and
  -- answers true, or false and why. A call that fails one is not made, and the model is
  -- told which, so it repairs the call inside its budget (spec/turn.md, "Requirements").
  local requires = {}
  if t.requires ~= nil then
    if type(t.requires) ~= "table" then
      fail("the tool %q: `requires` is a list of { says = \"...\", check = function (c) ... end }", name)
    end
    for i = 1, #t.requires do
      local r = t.requires[i]
      if type(r) ~= "table" or type(r.says) ~= "string" or r.says == "" or type(r.check) ~= "function" then
        fail("the tool %q: requirement %d needs `says` (a sentence) and `check = function (c) ... end`", name, i)
      end
      if r.check_only ~= nil and type(r.check_only) ~= "boolean" then
        fail("the tool %q: requirement %d: `check_only` is true or false", name, i)
      end
      requires[i] = { says = r.says, check = r.check, check_only = r.check_only == true }
    end
  end

  -- `preview = true`: a host may show the call's arguments before the tool runs, so a
  -- screen can draw what is about to change. Off by default: a host shows a person a
  -- tool's name and nothing a model wrote unless the tool says it may.
  if t.preview ~= nil and type(t.preview) ~= "boolean" then
    fail("the tool %q: `preview` is true or false", name)
  end

  -- `ends = true`: a reply whose calls are all to tools like this, and all ran, is the
  -- last step of its run; spec/turn.md, "Tools that end a run". Handing work off is one.
  if t.ends ~= nil and type(t.ends) ~= "boolean" then
    fail("the tool %q: `ends` is true or false", name)
  end

  -- `effect`: what the tool does to the world, for a screen that draws what happened (spec/home.md):
  -- it reads the workspace, writes it, recalls the history, runs a command, or starts a job.
  if t.effect ~= nil and not spec.EFFECTS[t.effect] then
    fail("the tool %q: `effect` is one of reads, writes, recalls, runs or starts", name)
  end

  -- A tool that uses none of the options has the shape it always had (scripts/rules-test.lua,
  -- rule 3): the keys are there only when the declaration says them.
  local tool = { name = name, about = t.about, args = args, arg_order = order, run = t.run, ask = ask or false,
                 edit = edit, requires = #requires > 0 and requires or nil, preview = t.preview or nil,
                 ends = t.ends or nil, effect = t.effect }
  a.tools[name] = tool
  a.order[#a.order + 1] = name
  return tool
end

function spec.add_hook(a, event, fn)
  if type(event) ~= "string" or event == "" then fail("agent.on takes an event name") end
  if type(fn) ~= "function" then fail("agent.on %q takes a function", event) end
  a.hooks[event] = a.hooks[event] or {}
  local h = a.hooks[event]
  h[#h + 1] = fn
end

-- A step of a feature file, bound to a body. Narrower than cucumber's: a step declares
-- its PHASE by which body it gives, and there is no `when` slot -- a `when` a workspace
-- could write is how a scenario starts causing what it observes (rule 6).
--
-- The SHAPE is checked here; the expression is compiled and its collisions refused in
-- `behaviour.declare`. The split keeps this file requiring nothing and calling nothing,
-- so loading a declaration stays safe on an untrusted file (rule 2).
function spec.add_step(a, expr, d, compiled)
  if type(expr) ~= "string" or expr == "" then fail("a step needs an expression") end
  if a.steps[expr] then fail("the step %q is declared twice", expr) end
  if type(d) ~= "table" then fail("agent.step %q takes a table, got %s", expr, type(d)) end

  local has_given, has_then = type(d.given) == "function", type(d.then_) == "function"
  if d.given ~= nil and not has_given then fail("the step %q: `given` is a function", expr) end
  if d.then_ ~= nil and not has_then then fail("the step %q: `then_` is a function", expr) end
  if d.when ~= nil or d.when_ ~= nil then
    fail("the step %q gives a `when`, and there is no such slot: the three ways a run starts are the harness's", expr)
  end
  if has_given and has_then then
    fail("the step %q gives both `given` and `then_`; a step is in one phase", expr)
  end
  if not has_given and not has_then then
    fail("the step %q needs `given` (it writes the world) or `then_` (it reads the result)", expr)
  end

  local step = { expr = expr, compiled = compiled, given = d.given, then_ = d.then_,
                 phase = has_given and "given" or "then" }
  a.steps[expr] = step
  a.step_order[#a.step_order + 1] = expr
  return step
end

-- Rule 3, for a procedure rather than a tool: a skill is a name, a why and a body a PERSON
-- wrote; it outlives the run and the agent may not edit it.
--
-- The body is either `does` (the text) or `file` (a workspace path read through the fs port
-- when the model asks). Never both.
function spec.add_skill(a, name, s)
  if type(name) ~= "string" or name == "" then fail("a skill needs a name") end
  if a.skills[name] then fail("the skill %q is declared twice", name) end
  if type(s) ~= "table" then fail("agent.skill %q takes a table, got %s", name, type(s)) end
  if type(s.about) ~= "string" or s.about == "" then
    fail("the skill %q needs `about`: one sentence, and it is all the model reads until it asks for the body", name)
  end
  local has_does, has_file = type(s.does) == "string", type(s.file) == "string"
  if s.does ~= nil and not has_does then fail("the skill %q: `does` is the procedure, as text", name) end
  if s.file ~= nil and not has_file then fail("the skill %q: `file` is a workspace-relative path, as a string", name) end
  if has_does and has_file then
    fail("the skill %q states both `does` and `file`; a procedure has one source", name)
  end
  if not has_does and not has_file then
    fail("the skill %q needs `does` (the text) or `file` (a path the fs port reads)", name)
  end
  local skill = { name = name, about = s.about, does = s.does, file = s.file, from = "declared" }
  a.skills[name] = skill
  a.skill_order[#a.skill_order + 1] = name
  return skill
end

-- A beat. `every` is a whole number of seconds, or `day_at` is a wall-clock time; a
-- beat states exactly one of them, because a beat that is both is two beats.
--
-- `once_per` is what makes "never twice for the same day" mean anything: it names the
-- granularity a durable ledger dedups on. Without a ledger there is no such sentence
-- to write, which is why the ledger is a port and not a table in this process.
function spec.add_beat(a, name, b)
  if type(name) ~= "string" or name == "" then fail("a beat needs a name") end
  if a.beats[name] then fail("the beat %q is declared twice", name) end
  if type(b) ~= "table" then fail("agent.every %q takes a table, got %s", name, type(b)) end
  local has_secs, has_at = b.every ~= nil, b.day_at ~= nil
  if has_secs and has_at then
    fail("the beat %q states both `every` and `day_at`; a beat has one period", name)
  end
  if not has_secs and not has_at then
    fail("the beat %q needs `every = <seconds>` or `day_at = \"18:00\"`", name)
  end
  if has_secs and (type(b.every) ~= "number" or b.every < 1 or b.every ~= math.floor(b.every)) then
    fail("the beat %q: `every` is a whole number of seconds, at least 1", name)
  end
  local hour, minute
  if has_at then
    if type(b.day_at) ~= "string" then fail("the beat %q: `day_at` is a clock time, like \"18:00\"", name) end
    local h, m = b.day_at:match("^(%d%d?):(%d%d)$")
    hour, minute = tonumber(h), tonumber(m)
    if not hour or hour > 23 or minute > 59 then
      fail("the beat %q: `day_at` is a 24-hour clock time, like \"18:00\", and arrived as %q", name, b.day_at)
    end
  end
  if type(b.runs) ~= "string" and type(b.runs) ~= "function" then
    fail("the beat %q needs `runs`: the prompt this beat starts a run with, or a function", name)
  end
  if type(b.runs) == "string" and b.runs == "" then
    fail("the beat %q: `runs` is a non-empty prompt", name)
  end
  if b.once_per ~= nil and not GRAINS[b.once_per] then
    fail("the beat %q: `once_per` is \"hour\", \"day\", \"week\" or \"ever\", and arrived as %s", name, tostring(b.once_per))
  end
  if b.about ~= nil and type(b.about) ~= "string" then fail("the beat %q: `about` is a sentence", name) end
  if b.tz ~= nil and (type(b.tz) ~= "number" or b.tz ~= math.floor(b.tz)) then
    fail("the beat %q: `tz` is the local offset in whole seconds from UTC", name)
  end
  -- How late is too late. Absent means the work does not expire, which is the common
  -- case and the reason it is not required: a digest of a day that has ended is still a
  -- digest (spec/schedule.md, "A beat whose time passed while nothing was running").
  if b.grace ~= nil and (type(b.grace) ~= "number" or b.grace < 0) then
    fail("the beat %q: `grace` is how many seconds late it may still run, as a number", name)
  end
  local beat = {
    name = name, about = b.about, every = b.every, day_at = b.day_at,
    hour = hour, minute = minute, runs = b.runs, once_per = b.once_per, tz = b.tz,
    grace = b.grace,
  }
  a.beats[name] = beat
  a.beat_order[#a.beat_order + 1] = name
  return beat
end

-- A server whose tools live in another process. Nothing here reaches it: rule 2 holds
-- for a declaration that names a network as firmly as for one that names a file.
-- `mcp.connect` is what asks, at run time, through the port.
function spec.add_server(a, name, m)
  if type(name) ~= "string" or name == "" then fail("a server needs a name") end
  if a.servers[name] then fail("the server %q is declared twice", name) end
  if type(m) ~= "table" then fail("agent.uses %q takes a table, got %s", name, type(m)) end
  if m.tools ~= nil then
    if type(m.tools) ~= "table" then
      fail("the server %q: `tools` is the list of tool names to take from it", name)
    end
    for i = 1, #m.tools do
      if type(m.tools[i]) ~= "string" or m.tools[i] == "" then
        fail("the server %q: `tools` holds tool names, and entry %d is %s", name, i, type(m.tools[i]))
      end
    end
  end
  if m.ask ~= nil and type(m.ask) ~= "boolean" then fail("the server %q: `ask` is true or false", name) end
  if m.join ~= nil and (type(m.join) ~= "string") then
    fail("the server %q: `join` is what goes between the server name and the tool name", name)
  end
  if m.about ~= nil and type(m.about) ~= "string" then fail("the server %q: `about` is a sentence", name) end
  local server = {
    name = name, about = m.about, tools = m.tools, ask = m.ask, join = m.join or "_",
    -- Anything else stated is the host's business: a command line, a URL, a header
    -- table. This module neither reads it nor knows what a transport is; the port does.
    config = m,
  }
  a.servers[name] = server
  a.server_order[#a.server_order + 1] = name
  return server
end

-- A store: a declared table of typed rows the console holds (src/store.lua). The
-- columns use the argument types, so what a program stores and what a tool takes are
-- described in one vocabulary.
function spec.add_store(a, name, s)
  if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
    fail("a store needs a name of letters, digits and _, like \"habits\"")
  end
  if a.stores[name] then fail("the store %q is declared twice", name) end
  if type(s) ~= "table" then fail("agent.store %q takes a table, got %s", name, type(s)) end
  if type(s.about) ~= "string" or s.about == "" then
    fail("the store %q needs `about`: what one row is", name)
  end
  if type(s.columns) ~= "table" then
    fail("the store %q needs `columns = { name = agent.string \"why\", ... }`", name)
  end
  local columns, order = {}, {}
  for k, v in pairs(s.columns) do
    if type(k) ~= "string" or not k:match("^[%a_][%w_]*$") then
      fail("the store %q: a column name is letters, digits and _", name)
    end
    if not is_param(v) or v.kind == "object" or v.kind == "array" then
      fail("the store %q: column %q is agent.string, number, boolean or one_of (or its _opt form)", name, k)
    end
    columns[k] = v
    order[#order + 1] = k
  end
  if #order == 0 then fail("the store %q has no columns", name) end
  table.sort(order)
  -- The columns a listing is sorted by first; the rest follow by name. A room's rows are
  -- listed top to bottom only if the store says `sort = "y"`.
  local sort = s.sort
  if type(sort) == "string" then sort = { sort } end
  if sort ~= nil and type(sort) ~= "table" then fail("the store %q: `sort` is a column or a list of them", name) end
  for i = 1, #(sort or {}) do
    if columns[sort[i]] == nil then fail("the store %q: `sort` names %q, which is not a column", name, tostring(sort[i])) end
  end
  local store = { name = name, about = s.about, columns = columns, column_order = order, sort = sort }
  a.stores[name] = store
  a.store_order[#a.store_order + 1] = name
  return store
end

-- What the model is told a tool is. Deliberately the whole of it: a name, a sentence,
-- what a call must meet, and the arguments. If something is not here the model cannot
-- use it.
function spec.schema(a)
  local out = {}
  for i = 1, #a.order do
    local t = a.tools[a.order[i]]
    local args = {}
    for j = 1, #t.arg_order do
      local k = t.arg_order[j]
      local p = t.args[k]
      args[#args + 1] = { name = k, kind = p.kind, required = p.required, description = p.description,
                          choices = p.choices }
    end
    local about, told = t.about, {}
    for j = 1, #(t.requires or {}) do
      if not t.requires[j].check_only then told[#told + 1] = t.requires[j].says end
    end
    if #told > 0 then about = about .. " It requires: " .. table.concat(told, "; ") .. "." end
    out[#out + 1] = { name = t.name, about = about, args = args, ask = t.ask }
  end
  return out
end

-- Refuse an agent that cannot be run, with the reason, before anything is started.
function spec.problems(a)
  local out = {}
  if not a.name then out[#out + 1] = "no agent.name" end
  if not a.model then out[#out + 1] = "no agent.model" end
  if #a.order == 0 then out[#out + 1] = "no tools: an agent with no tools can only answer, never act" end
  return out
end

return spec
