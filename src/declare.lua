-- declare -- an agent written in Gherkin: what it IS, in the feature's Background, in a
-- closed vocabulary of its own; what it DOES, in the scenarios, as before.
--
-- Each is line says one thing the `agent.*` surface says, and the file compiles to exactly
-- the table that surface would have built. Nothing runs (rule 2): the lines are applied
-- through `cli.surface` and `src/kits.lua`, and Lua in a doc string is compiled, never
-- called.
--
-- Two more things live here because they read the same file:
--
--   * SHORTHANDS: a scenario tagged @shorthand is a step that stands for other steps. It
--     extends the vocabulary in Gherkin, with no Lua, and is expanded before a runner sees
--     a pickle, so `behaviour.lua` never learns it exists.
--   * EDITS: one change to the file's text, classified by what it does to the agent's
--     REACH, which is the wall an agent editing itself meets (spec/declare.md).
--
-- Contract: spec/declare.md. Amend that before this diverges from it.

local gherkin   = require "gherkin"
local spec      = require "spec"
local cli       = require "cli"
local behaviour = require "behaviour"
local kits      = require "kits"

local declare = {}

--- Bumped when an is expression changes meaning.
declare.VOCABULARY = 1

-- small helpers

local function trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end
local function q(s) return string.format("%q", tostring(s)) end
local unpack = table.unpack or unpack

local function at(line, fmt, ...)
  return nil, string.format("line %d: " .. fmt, line, ...)
end

-- A refusal raised from inside a plan's apply; caught at the top and answered as
-- `nil, sentence`, so the loader never raises on a bad file.
local REFUSAL = {}
local function refuse(line, fmt, ...)
  error({ [REFUSAL] = true, why = string.format("line %d: " .. fmt, line, ...) }, 0)
end

local function split_list(text)
  local out = {}
  for part in (tostring(text) .. ","):gmatch("([^,]*),") do
    local t = trim(part)
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end

-- -------------------------------------------------------------------- Lua in a doc string
--
-- The environment a declaration gets from `cli.sandbox`, minus `agent`: a body reaches the
-- world only through the ports on `c`. A name it does not have raises, by name, when the
-- body runs; a global it tries to keep raises too, because a body that thinks it is keeping
-- state across calls has a bug.

local function library_copy(t, without)
  local out = {}
  for k, v in pairs(t) do
    if not (without and without[k]) then out[k] = v end
  end
  return out
end

local function body_env()
  local base = {
    pairs = pairs, ipairs = ipairs, next = next, select = select, type = type,
    tostring = tostring, tonumber = tonumber, error = error, assert = assert,
    pcall = pcall, xpcall = xpcall, unpack = unpack,
    math = library_copy(math), string = library_copy(string, { dump = true }),
    table = library_copy(table),
  }
  return setmetatable({}, {
    __index = function (_, k)
      local v = base[k]
      if v ~= nil then return v end
      error(string.format("%s is not here: a body reaches the world through c", tostring(k)), 2)
    end,
    __newindex = function (_, k)
      error(string.format("a body keeps no globals, and this one set %s: make it local", tostring(k)), 2)
    end,
    __metatable = "body",
  })
end

-- `text` is the body of a function of `param`. Compiled, never called. The body's lines
-- keep their numbers: the parameter is bound on the doc string's own first line.
local function compile_body(text, param, name)
  if type(text) ~= "string" or trim(text) == "" then return nil, "the doc string is empty" end
  if text:find("\27", 1, true) then return nil, "a body is text, and this holds an escape byte" end
  local src = "local " .. param .. " = ... " .. text
  local env = body_env()
  local chunk, err
  if type(setfenv) == "function" and type(loadstring) == "function" then
    chunk, err = loadstring(src, "=" .. name)
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(src, "=" .. name, "t", env)
  end
  if not chunk then return nil, tostring(err) end
  return chunk
end

-- ------------------------------------------------------------------ types, in words

local TYPE_WORDS = { string = true, number = true, boolean = true, table = true, list = true }

-- `string`, `optional number`, `one of near, far`, `optional one of a, b`.
local function param_of(cell, about, line)
  local t = trim(cell)
  local optional = false
  if t:sub(1, 9) == "optional " then optional, t = true, trim(t:sub(10)) end
  local choices = t:match("^one of (.+)$")
  if choices then
    local list = split_list(choices)
    if #list < 2 then refuse(line, "`one of` lists at least two values, like `one of near, far`") end
    return spec.types[optional and "one_of_opt" or "one_of"](about)(list)
  end
  if not TYPE_WORDS[t] then
    refuse(line, "%s is not a type; a type is string, number, boolean, table or list, or one of a, b, "
      .. "each optionally preceded by `optional`", q(cell))
  end
  return spec.types[t .. (optional and "_opt" or "")](about)
end

-- A table's rows under the header it must have, as a list of { cell = value } maps.
local function rows_under(step, header)
  local rows = step.rows
  if not rows or #rows < 1 then refuse(step.line, "this line takes a table: | %s |", table.concat(header, " | ")) end
  for i = 1, #header do
    if trim(rows[1][i] or ""):lower() ~= header[i] or #rows[1] ~= #header then
      refuse(step.line, "the table's header is | %s |", table.concat(header, " | "))
    end
  end
  local out = {}
  for r = 2, #rows do
    local row = {}
    for i = 1, #header do row[header[i]] = rows[r][i] end
    out[#out + 1] = row
  end
  return out
end

local function params_of(step, first)
  local out, order = {}, {}
  for _, row in ipairs(rows_under(step, { first, "type", "about" })) do
    local name = trim(row[first])
    if not name:match("^[%a_][%w_]*$") then
      refuse(step.line, "%s is not a name: letters, digits and _", q(name))
    end
    if out[name] then refuse(step.line, "%s is listed twice", q(name)) end
    out[name] = param_of(row.type, trim(row.about), step.line)
    order[#order + 1] = name
  end
  return out, order
end

-- ------------------------------------------------------------------ the plan
--
-- Is lines write into a PLAN, which is built into the agent table once every line is read.
-- That makes the lines order-free where order means nothing -- `the tool verdict asks first`
-- may come before or after the line that declares verdict -- and it makes one place where
-- the surface is called, in the order the surface wants.

local function new_plan()
  return {
    set = {}, tools = {}, tool_order = {}, mods = {}, mod_order = {},
    stores = {}, store_order = {}, skills = {}, skill_order = {},
    beats = {}, beat_order = {}, servers = {}, server_order = {},
    steps = {}, delegates = {}, allow = {}, deny = {}, never = {},
    kits = {}, kit_order = {}, kit_files = {},
  }
end

local function once(plan, key, value, line, what)
  if plan.set[key] then
    refuse(line, "%s is said twice, here and at line %d", what, plan.set[key].line)
  end
  plan.set[key] = { value = value, line = line }
end

local function mod(plan, tool, line)
  local m = plan.mods[tool]
  if not m then
    m = { line = line, requires = {} }
    plan.mods[tool] = m
    plan.mod_order[#plan.mod_order + 1] = tool
  end
  return m
end

local function body(plan, tool, b, line)
  local m = mod(plan, tool, line)
  if m.body then refuse(line, "the tool %s already has a body, at line %d", tool, m.body.line) end
  b.line = line
  m.body = b
end

local function beat(plan, name, line)
  local b = plan.beats[name]
  if not b then
    b = { line = line }
    plan.beats[name] = b
    plan.beat_order[#plan.beat_order + 1] = name
  end
  return b
end

-- ------------------------------------------------------------------ the is vocabulary
--
-- `reach` is which way the line moves what the agent can do: "widens", "narrows" or
-- "neither". `same` is the reach of a replace that keeps the expression and every name it
-- takes, only the text changing -- a tool's `for`, a briefing. `gate` marks the lines an
-- agent may add and never remove.

local IS = {
  -- who it is
  { expr = "the agent is called {word}", covers = "name", about = "its name", reach = "widens", same = "widens",
    apply = function (p, s, name) once(p, "name", name, s.line, "the agent's name") end },
  { expr = "its model is {string}", covers = "model", about = "the model that answers for it", reach = "widens",
    apply = function (p, s, id) once(p, "model", id, s.line, "the model") end },
  { expr = "its reasoning is {word}", covers = "reasoning", about = "none, low, medium or high", reach = "neither",
    apply = function (p, s, v) once(p, "reasoning", v, s.line, "the reasoning") end },
  { expr = "it may take {int} step(s)", covers = "budget", about = "its budget: passes of the loop", reach = "neither",
    apply = function (p, s, n) once(p, "budget", n, s.line, "the budget") end },
  { expr = "it is briefed:", covers = "system", about = "what it is told first, as a doc string", reach = "neither", doc = true,
    apply = function (p, s) once(p, "system", s.doc, s.line, "the briefing") end },
  { expr = "its trust is {word}", covers = "trust", about = "trusted, ask or none", reach = "widens",
    apply = function (p, s, v) once(p, "trust", v, s.line, "the trust") end },
  { expr = "it may always call {word}", covers = "allow", about = "a tool the policy allows", reach = "widens",
    apply = function (p, s, t) p.allow[#p.allow + 1] = { tool = t, line = s.line } end },
  { expr = "it may never call {word}", covers = "deny", about = "a tool the policy refuses", reach = "narrows",
    apply = function (p, s, t) p.deny[#p.deny + 1] = { tool = t, line = s.line } end },

  -- what it can reach
  { expr = "it reads the workspace", covers = "files", about = "the files tools, read only", reach = "widens",
    apply = function (p, s) once(p, "files", { read_only = true }, s.line, "the workspace") end },
  { expr = "it reads and writes the workspace", covers = "files", about = "the files tools", reach = "widens",
    apply = function (p, s) once(p, "files", { read_only = false }, s.line, "the workspace") end },
  { expr = "it never touches {string}", covers = "files", about = "a glob the files tools refuse", reach = "narrows",
    apply = function (p, s, glob) p.never[#p.never + 1] = { glob = glob, line = s.line } end },
  { expr = "it runs commands", covers = "shell", about = "the shell tool, which asks on its own account", reach = "widens",
    apply = function (p, s) once(p, "shell", true, s.line, "the shell") end },
  { expr = "each command may run {int} second(s)", covers = "shell", about = "the shell's timeout", reach = "neither",
    apply = function (p, s, n)
      if n < 1 then refuse(s.line, "a command runs at least one second") end
      once(p, "timeout", n, s.line, "the shell's timeout")
    end },
  { expr = "it keeps a plan", covers = "plan", about = "the plan and mark tools", reach = "widens",
    apply = function (p, s) once(p, "plan", true, s.line, "the plan") end },
  { expr = "it can read its history", covers = "history", about = "the history, recall and evidence tools, which read past runs",
    reach = "widens",
    apply = function (p, s) once(p, "history", true, s.line, "its history") end },
  { expr = "it hands work to the agent in {string} as {word}", covers = "delegate", about = "a tool that runs the agent that file declares",
    reach = "widens",
    apply = function (p, s, path, tool)
      if p.delegates[tool] then refuse(s.line, "the delegate %s is declared twice", tool) end
      p.delegates[tool] = { path = path, line = s.line }
      p.tool_order[#p.tool_order + 1] = tool
    end },
  { expr = "it uses the server {word} with:", covers = "uses", about = "a server whose tools live in another process; | key | value |",
    reach = "widens", rows = true,
    apply = function (p, s, name)
      if p.servers[name] then refuse(s.line, "the server %s is declared twice", name) end
      local cfg = {}
      for _, row in ipairs(rows_under(s, { "key", "value" })) do
        local k, v = trim(row.key), trim(row.value)
        if k == "tools" then cfg.tools = split_list(v)
        elseif k == "ask" then cfg.ask = v == "true"
        else cfg[k] = v end
      end
      p.servers[name] = { cfg = cfg, line = s.line }
      p.server_order[#p.server_order + 1] = name
    end },

  -- its tools
  { expr = "it has a tool {word} for {string}", covers = "tool", about = "a tool with no arguments", reach = "widens",
    same = "neither",
    apply = function (p, s, name, about)
      if p.tools[name] then refuse(s.line, "the tool %s is declared twice, here and at line %d", name, p.tools[name].line) end
      p.tools[name] = { about = about, args = {}, line = s.line }
      p.tool_order[#p.tool_order + 1] = name
    end },
  { expr = "it has a tool {word} for {string}, which takes:", covers = "tool", about = "a tool and its arguments; | argument | type | about |",
    reach = "widens", same = "rows", rows = true,
    apply = function (p, s, name, about)
      if p.tools[name] then refuse(s.line, "the tool %s is declared twice, here and at line %d", name, p.tools[name].line) end
      local args = params_of(s, "argument")
      p.tools[name] = { about = about, args = args, line = s.line }
      p.tool_order[#p.tool_order + 1] = name
    end },
  { expr = "the tool {word} asks first", covers = "tool", about = "the person is asked before it runs", reach = "narrows", gate = true,
    apply = function (p, s, tool)
      local m = mod(p, tool, s.line)
      -- `always asks first` says it asks too; the two lines are order-free (spec/declare.md)
      if m.ask and m.ask ~= m.always then refuse(s.line, "the tool %s already asks first, at line %d", tool, m.ask) end
      m.ask = m.ask or s.line
    end },
  { expr = "the tool {word} always asks first", covers = "tool",
    about = "the person is asked whatever the trust and whatever a policy allows", reach = "narrows", gate = true,
    apply = function (p, s, tool)
      local m = mod(p, tool, s.line)
      if m.always then refuse(s.line, "the tool %s already always asks first, at line %d", tool, m.always) end
      m.always = s.line
      m.ask = m.ask or s.line
    end },
  { expr = "the tool {word} asks first, letting the person change {word}", covers = "tool",
    about = "and the person may change that argument at the gate", reach = "narrows", gate = true,
    apply = function (p, s, tool, arg)
      local m = mod(p, tool, s.line)
      m.ask = m.ask or s.line
      m.edit = m.edit or {}
      m.edit[#m.edit + 1] = arg
    end },
  { expr = "the tool {word} is for {string}", covers = "tool", about = "what the model is told a tool is for",
    reach = "neither",
    apply = function (p, s, tool, about)
      local m = mod(p, tool, s.line)
      if m.about then refuse(s.line, "what %s is for is said twice, here and at line %d", tool, m.about.line) end
      m.about = { text = about, line = s.line }
    end },
  { expr = "the tool {word} shows its call before it runs", covers = "tool", about = "a host may draw the call first", reach = "neither",
    apply = function (p, s, tool) mod(p, tool, s.line).preview = true end },
  { expr = "the tool {word} requires {string}, checked by:", covers = "tool", about = "a requirement; the doc string is its check, in Lua",
    reach = "narrows", doc = true, same = "widens",
    apply = function (p, s, tool, says)
      local m = mod(p, tool, s.line)
      m.requires[#m.requires + 1] = { says = says, doc = s.doc, line = s.line }
    end },
  { expr = "the tool {word} may be called at most {int} time(s)", covers = "on", about = "a call past this is refused", reach = "narrows",
    apply = function (p, s, tool, n)
      if n < 1 then refuse(s.line, "at most 0 times is no tool: remove it instead") end
      local m = mod(p, tool, s.line)
      if m.limit then refuse(s.line, "the tool %s already has a limit, at line %d", tool, m.limit.line) end
      m.limit = { n = n, line = s.line }
    end },
  { expr = "the tool {word} does:", covers = "tool", about = "its body, in Lua, as a doc string", reach = "widens", doc = true,
    apply = function (p, s, tool) body(p, tool, { kind = "lua", doc = s.doc }, s.line) end },
  { expr = "the tool {word} answers {string}", covers = "tool", about = "a body that answers this", reach = "neither",
    apply = function (p, s, tool, text) body(p, tool, { kind = "answers", text = text }, s.line) end },
  { expr = "the tool {word} adds a row to {word}", covers = "tool", about = "a body that adds its arguments as a row", reach = "widens",
    apply = function (p, s, tool, st) body(p, tool, { kind = "adds", store = st }, s.line) end },
  { expr = "the tool {word} lists {word}", covers = "tool", about = "a body that answers every row, one per line", reach = "neither",
    apply = function (p, s, tool, st) body(p, tool, { kind = "lists", store = st }, s.line) end },

  -- what it keeps
  { expr = "it keeps a store {word} of {string}:", covers = "store", about = "a store; | column | type | about |",
    reach = "widens", same = "rows", rows = true,
    apply = function (p, s, name, about)
      if p.stores[name] then refuse(s.line, "the store %s is declared twice", name) end
      local columns = params_of(s, "column")
      p.stores[name] = { about = about, columns = columns, line = s.line, sort = {} }
      p.store_order[#p.store_order + 1] = name
    end },
  { expr = "the store {word} is sorted by {word}", covers = "store", about = "the column a listing is sorted by, in order", reach = "neither",
    apply = function (p, s, name, col)
      p.sorts = p.sorts or {}
      p.sorts[#p.sorts + 1] = { store = name, column = col, line = s.line }
    end },
  { expr = "it keeps a skill {word} for {string}:", covers = "skill", about = "a procedure a person wrote, as a doc string",
    reach = "neither", doc = true,
    apply = function (p, s, name, about)
      if p.skills[name] then refuse(s.line, "the skill %s is declared twice", name) end
      p.skills[name] = { about = about, does = s.doc, line = s.line }
      p.skill_order[#p.skill_order + 1] = name
    end },
  { expr = "it keeps a skill {word} for {string}, in {string}", covers = "skill", about = "a procedure read from that path",
    reach = "neither",
    apply = function (p, s, name, about, file)
      if p.skills[name] then refuse(s.line, "the skill %s is declared twice", name) end
      p.skills[name] = { about = about, file = file, line = s.line }
      p.skill_order[#p.skill_order + 1] = name
    end },

  -- when it runs by itself
  { expr = "the beat {word} comes every {int} second(s) and asks {string}", covers = "every", about = "a beat, by the second",
    reach = "widens", same = "neither",
    apply = function (p, s, name, n, prompt)
      local b = beat(p, name, s.line)
      if b.runs then refuse(s.line, "the beat %s is declared twice", name) end
      b.every, b.runs = n, prompt
    end },
  { expr = "the beat {word} comes every day at {string} and asks {string}", covers = "every", about = "a beat, at a clock time",
    reach = "widens", same = "neither",
    apply = function (p, s, name, time, prompt)
      local b = beat(p, name, s.line)
      if b.runs then refuse(s.line, "the beat %s is declared twice", name) end
      b.day_at, b.runs = time, prompt
    end },
  { expr = "the beat {word} runs once per {word}", covers = "every", about = "hour, day, week or ever", reach = "narrows",
    apply = function (p, s, name, grain) beat(p, name, s.line).once_per = grain end },

  -- its own steps
  { expr = "the step {string} sets up:", covers = "step", about = "a step whose body writes the world, in Lua", reach = "neither",
    doc = true,
    apply = function (p, s, expr) p.steps[#p.steps + 1] = { expr = expr, phase = "given", doc = s.doc, line = s.line } end },
  { expr = "the step {string} checks:", covers = "step", about = "a step whose body reads the result, in Lua", reach = "neither",
    doc = true,
    apply = function (p, s, expr) p.steps[#p.steps + 1] = { expr = expr, phase = "then", doc = s.doc, line = s.line } end },

  -- the authoring tools (src/authoring.lua)
  { expr = "it edits agents in {string}", covers = "authoring", about = "the six authoring tools, over the feature files in that folder",
    reach = "widens",
    apply = function (p, s, folder) once(p, "authoring", folder, s.line, "the authoring folder") end },

  -- a workspace's own kit (docs/spec/kit.md): loaded before the other lines are read, so
  -- its lines are vocabulary whatever their order in the Background
  { expr = "it uses the kit {string}", covers = "kit", about = "loads a kit file beside this one; its lines join the vocabulary",
    reach = "widens",
    apply = function (p, s, path) p.kit_files[#p.kit_files + 1] = { path = path, line = s.line } end },
}
local KIT_LINE = "it uses the kit {string}"

-- A registered kit's line, as an is line: applying it records what it told the kit on the
-- plan, and the text, so the kit is installed once at build and said back verbatim.
local function kit_entry(name, e)
  return { expr = e.expr, covers = "kit", about = e.about .. " (the kit " .. name .. ")", reach = e.reach, kit = name,
    gate = e.gate == true or nil,     -- a line an agent may add and never remove or replace, like `asks first`
    narrower = e.narrower,            -- (old args, new args) -> true when the new line narrows further
    apply = function (p, s, ...)
      local k = p.kits[name]
      if not k then
        k = { told = {}, lines = {}, line = s.line }
        p.kits[name] = k
        p.kit_order[#p.kit_order + 1] = name
      end
      k.lines[#k.lines + 1] = s.text
      local ok, err = pcall(e.tells, k.told, ...)
      if not ok then refuse(s.line, "the kit %s: %s", name, tostring(err)) end
    end }
end

-- Compiled once. An is expression that does not compile, or that could be read as a
-- built-in step, is a bug in this file and raises here rather than in someone's feature.
local COMPILED, BUILT_INS, COMPILED_AT
local function compiled()
  if COMPILED and COMPILED_AT == kits.version then return COMPILED, BUILT_INS end
  COMPILED, BUILT_INS, COMPILED_AT = {}, {}, kits.version
  local skeletons = behaviour.skeletons()
  for i = 1, #IS do
    local e, why = gherkin.expr(IS[i].expr)
    if not e then error("declare: an is expression does not compile: " .. tostring(why)) end
    if skeletons[e.skeleton()] then
      error("declare: the is expression " .. q(IS[i].expr) .. " collides with the built-in " .. q(skeletons[e.skeleton()]))
    end
    COMPILED[i] = { expr = e, def = IS[i] }
  end
  -- the loaded kits' lines, after the built-in ones, in the order they were loaded
  for _, name in ipairs(kits.order) do
    local k = kits.registered[name]
    for i = 1, #k.is do COMPILED[#COMPILED + 1] = { expr = k.is[i].expr, def = kit_entry(name, k.is[i].def) } end
  end
  local steps = behaviour.steps()
  for i = 1, #steps do
    BUILT_INS[i] = { expr = assert(gherkin.expr(steps[i].expr)), def = steps[i] }
  end
  return COMPILED, BUILT_INS
end

-- The is expression this text matches, its arguments, and the compiled expression (whose
-- segments say which argument was a name). Two is the vocabulary's bug.
local function match_is(text)
  local list = compiled()
  local hit, args, e
  for i = 1, #list do
    local got = list[i].expr.match(text)
    if got then
      if hit then return nil, nil, "two is expressions match this line: " .. q(hit.expr) .. " and " .. q(list[i].def.expr) end
      hit, args, e = list[i].def, got, list[i].expr
    end
  end
  return hit, args, nil, e
end

local function match_built_in(text)
  local _, list = compiled()
  for i = 1, #list do
    if list[i].expr.match(text) then return list[i].def end
  end
  return nil
end

-- The is expression a line that matches nothing most looks like: the one whose leading words
-- the line shares most of, a parameter standing for any word. A hint in a refusal, never a
-- reading -- the line is refused either way.
local function closest(text)
  local words = {}
  for w in tostring(text):gmatch("%S+") do words[#words + 1] = w end
  local best, best_n = nil, 1
  for i = 1, #IS do
    local n = 0
    local k = 0
    for w in IS[i].expr:gmatch("%S+") do
      k = k + 1
      if not words[k] then break end
      if w:match("^{%a+}") or w == words[k] then n = n + 1 else break end
    end
    if n > best_n then best, best_n = IS[i].expr, n end
  end
  return best
end

local function nothing_matches(line, text)
  local near = closest(text)
  return at(line, "%s matches no line of the vocabulary%s. {word} is a name, bare; {string} is text, "
    .. "in quotes (`lua bin/malleable.lua --steps` lists every line)", q(text),
    near and (": the nearest is line is `" .. near .. "`") or "")
end

--- The is vocabulary, as a list of `{ expr, about, reach, covers }`, for `--steps`, an
--- editor and the authoring tools. `covers` is the `agent.*` entry point the line says.
function declare.vocabulary()
  local out = {}
  for i = 1, #IS do
    out[i] = { expr = IS[i].expr, phase = "is", about = IS[i].about, reach = IS[i].reach,
               gate = IS[i].gate or nil, covers = IS[i].covers }
  end
  for _, name in ipairs(kits.order) do
    for _, e in ipairs(kits.registered[name].is) do
      out[#out + 1] = { expr = e.def.expr, phase = "is", about = e.def.about .. " (the kit " .. name .. ")",
                        reach = e.def.reach, covers = "kit", kit = name, gate = e.def.gate == true or nil }
    end
  end
  return out
end

-- ------------------------------------------------------------------ kits (docs/spec/kit.md)

--- Load a kit for the process: check its shape, compile its lines against the vocabulary,
--- refuse a collision by name, and register it. Answers the kit's name, or `nil, sentence`.
--- `from` is the file it came from, when it did; loading the same file again is nothing.
function declare.kit(def, from, text)
  local ok, why = kits.define(def)
  if not ok then return nil, why end
  local have = kits.registered[def.name]
  if have then
    -- the same table, the same file, or the same text under another path: nothing to do.
    -- Two agents in one folder both say `it uses the kit "modes.lua"`, and an eval's author
    -- reads the tree's copy while the file it edits reads the workspace's (2026-09-12).
    local function plain(t) return type(t) == "string" and (t:gsub("\r\n", "\n"):gsub("%s+$", "")) or nil end
    if have.def == def or (from ~= nil and have.from == from) or (text ~= nil and plain(have.text) == plain(text)) then
      return def.name
    end
    return nil, string.format("the kit %s is already loaded from %s, and this is another, from %s",
      def.name, have.from and q(have.from) or "Lua", from and q(from) or "Lua")
  end
  local list = compiled()
  local skeletons = behaviour.skeletons()
  local is = {}
  for i = 1, #def.is do
    local e = def.is[i]
    local ex, bad = gherkin.expr(e.expr)
    if not ex then return nil, string.format("the kit %s: the line %s does not compile: %s", def.name, q(e.expr), tostring(bad)) end
    local sk = ex.skeleton()
    if skeletons[sk] then
      return nil, string.format("the kit %s: the line %s reads as the built-in step %s", def.name, q(e.expr), q(skeletons[sk]))
    end
    for _, c in ipairs(list) do
      if c.expr.skeleton() == sk then
        return nil, string.format("the kit %s: the line %s reads as the is line %s%s", def.name, q(e.expr), q(c.def.expr),
          c.def.kit and (" of the kit " .. c.def.kit) or "")
      end
    end
    for j = 1, i - 1 do
      if is[j].expr.skeleton() == sk then
        return nil, string.format("the kit %s: the lines %s and %s read the same", def.name, q(def.is[j].expr), q(e.expr))
      end
    end
    is[i] = { expr = ex, def = e }
  end
  local steps = {}
  for i = 1, #(def.steps or {}) do
    local st = def.steps[i]
    local ex, bad = gherkin.expr(st.expr)
    if not ex then return nil, string.format("the kit %s: the step %s does not compile: %s", def.name, q(st.expr), tostring(bad)) end
    local sk = ex.skeleton()
    if skeletons[sk] then
      return nil, string.format("the kit %s: the step %s collides with the built-in %s", def.name, q(st.expr), q(skeletons[sk]))
    end
    steps[i] = { expr = ex, def = st }
  end
  kits.registered[def.name] = { def = def, from = from, text = text, is = is, steps = steps }
  kits.order[#kits.order + 1] = def.name
  kits.version = kits.version + 1
  return def.name
end

-- A kit file, compiled with what a body gets and called for its table. This is the one
-- thing `declare` runs at load, and it runs to read a table (docs/spec/kit.md).
local function compile_kit(text, name)
  if type(text) ~= "string" or trim(text) == "" then return nil, "the file is empty" end
  if text:find("\27", 1, true) then return nil, "a kit is text, and this holds an escape byte" end
  local env = body_env()
  local chunk, err
  if type(setfenv) == "function" and type(loadstring) == "function" then
    chunk, err = loadstring(text, "=" .. name)
    if chunk then setfenv(chunk, env) end
  else
    chunk, err = load(text, "=" .. name, "t", env)
  end
  if not chunk then return nil, tostring(err) end
  local ok, def = pcall(chunk)
  if not ok then return nil, tostring(def) end
  return def
end

-- Every `it uses the kit` line of the Background, loaded before the other lines are read.
local KIT_EXPR = nil
local function load_kits(doc, opts)
  if not doc.background then return true end
  KIT_EXPR = KIT_EXPR or assert(gherkin.expr(KIT_LINE))
  for _, st in ipairs(doc.background.steps) do
    local args = KIT_EXPR.match(st.text)
    if args then
      local path = args[1]
      if type(opts.read) ~= "function" then
        return at(st.line, "this host gives the loader no way to read %s", q(path))
      end
      local text, why = opts.read(path)
      if not text then return at(st.line, "cannot read %s: %s", q(path), tostring(why)) end
      local def, bad = compile_kit(text, path)
      if def == nil then return at(st.line, "%s: %s", q(path), tostring(bad)) end
      local name, bad2 = declare.kit(def, path, text)
      if not name then return at(st.line, "%s: %s", q(path), tostring(bad2)) end
    end
  end
  return true
end

--- What the Gherkin cannot say, and why. Every entry point of the surface is either named
--- by an is expression's `covers` or listed here, and a test holds the two together.
declare.UNSAID = {
  on = "a hook is code that watches a run; the one thing a hook does to a run, refusing a call, "
    .. "is `the tool {word} may be called at most {int} time(s)`",
}

--- The phase an expression gives this text -- "is", "given", "when" or "then" -- or nil
--- when none reads it. For a tool that puts back a keyword a writer left off.
function declare.phase_of(text)
  if match_is(text) then return "is" end
  local def = match_built_in(text)
  return def and def.phase or nil
end

--- The is expression a line of text is, or nil. For an editor, and for the edit wall.
function declare.is_line(text)
  local def, args = match_is(text)
  if not def then return nil end
  return { expr = def.expr, reach = def.reach, same = def.same, gate = def.gate, args = args }
end

-- ------------------------------------------------------------------ reading the file

-- Every block of the document that is not the feature's background: where an is line may
-- not be.
local function other_blocks(doc)
  local out = {}
  for i = 1, #doc.scenarios do out[#out + 1] = doc.scenarios[i] end
  for r = 1, #doc.rules do
    local rule = doc.rules[r]
    if rule.background then out[#out + 1] = rule.background end
    for i = 1, #rule.scenarios do out[#out + 1] = rule.scenarios[i] end
  end
  return out
end

local function is_shorthand_block(b)
  for i = 1, #(b.tags or {}) do
    if b.tags[i] == "@shorthand" then return true end
  end
  return false
end

-- The is lines of a document, in order, each with its definition and arguments; or nil and
-- the sentence for the first thing wrong with where they are.
local function is_lines(doc)
  local lines = {}
  local bg = doc.background
  if bg then
    local first_other = nil
    for i = 1, #bg.steps do
      local s = bg.steps[i]
      local def, args, two = match_is(s.text)
      if two then return at(s.line, "%s", two) end
      if def then
        if match_built_in(s.text) then
          return at(s.line, "this line reads as an is line and as a built-in step")
        end
        if first_other then
          return at(s.line, "what the agent is comes before the Background's other lines, and line %d is before it",
                    first_other)
        end
        lines[#lines + 1] = { step = s, def = def, args = args }
      elseif not first_other then
        -- A line that reads as nothing at all is the mistake to name, not the order.
        if not match_built_in(s.text) then
          local later = false
          for j = i + 1, #bg.steps do
            if match_is(bg.steps[j].text) then later = true; break end
          end
          if later then return nothing_matches(s.line, s.text) end
        end
        first_other = s.line
      end
    end
  end
  for _, b in ipairs(other_blocks(doc)) do
    for i = 1, #b.steps do
      if match_is(b.steps[i].text) then
        return at(b.steps[i].line, "what the agent is, is said once, in the feature's Background, "
          .. "and this line is in %s", b.kind == "background" and "a rule's background" or q(b.name))
      end
    end
  end
  return lines
end

local shorthands_of   -- below, with the shorthands

-- ------------------------------------------------------------------ building

-- The context a child agent runs in, when an agent written here hands work to it. A child
-- runs in the world its parent was given -- the same files, the same gate, the same model
-- -- which is what "hand work to a helper in the same workspace" means. The stack is set by
-- whoever starts a run (`declare.enter`), never by a tool body: a body is handed a context
-- without the model or the gate (rule 4), and nothing here gives either back to it.
local worlds = {}

--- Around a run: the world a delegate's child gets while it lasts.
function declare.enter(port) worlds[#worlds + 1] = port; return #worlds end
function declare.leave(depth) while #worlds >= depth do worlds[#worlds] = nil end end

--- Puts `stack` in place as the stack of worlds and answers the one it replaced. A host
--- that interleaves runs in coroutines swaps each run's own stack in around every resume
--- (spec/speech.md, "The delegate world is per run"), so no run reads another's world.
function declare.swap(stack)
  local was = worlds
  worlds = stack or {}
  return was
end

local function child_world()
  local w = worlds[#worlds]
  if w == nil then return nil, "no run is in progress, so there is no world to hand a child" end
  return w
end

local function run_body(chunk)
  return function (c) return chunk(c) end
end

local function render_row(d, row)
  local parts = {}
  for i = 1, #d.column_order do
    local k = d.column_order[i]
    if row[k] ~= nil then parts[#parts + 1] = k .. "=" .. tostring(row[k]) end
  end
  return table.concat(parts, ", ")
end

local function build(plan, a, opts, title)
  local s = cli.surface(a)
  local set = plan.set
  local function v(k) return set[k] and set[k].value end
  local function guarded(line, f, ...)
    local ok, err = pcall(f, ...)
    if not ok then
      if type(err) == "table" and err[REFUSAL] then error(err, 0) end
      local msg = tostring(err):gsub("^[^\n]-:%d+: ", ""):gsub("^agent: ", "")
      refuse(line, "%s", msg)
    end
    return err
  end

  if set.name then guarded(set.name.line, s.name, v "name") end
  if set.model then guarded(set.model.line, s.model, v "model") end
  if set.reasoning then guarded(set.reasoning.line, s.reasoning, v "reasoning") end
  if set.budget then guarded(set.budget.line, s.budget, v "budget") end
  if set.system then guarded(set.system.line, s.system, v "system") end
  if set.trust then guarded(set.trust.line, s.trust, v "trust") end

  -- the kits
  if set.files then
    local deny = {}
    for i = 1, #plan.never do deny[i] = plan.never[i].glob end
    guarded(set.files.line, kits.files, a, { root = "", read_only = v("files").read_only,
                                             deny = #deny > 0 and deny or nil }, s)
  elseif #plan.never > 0 then
    refuse(plan.never[1].line, "`it never touches` is about the workspace, and this agent does not read it: "
      .. "say `it reads the workspace` first")
  end
  if set.shell then
    guarded(set.shell.line, kits.shell, a, { root = ".", timeout_ms = set.timeout and v("timeout") * 1000 or nil })
  elseif set.timeout then
    refuse(set.timeout.line, "a command's timeout needs `it runs commands`")
  end
  if set.plan then guarded(set.plan.line, kits.plan, {}, s, a) end
  if set.history then guarded(set.history.line, kits.history, s, a) end
  if set.authoring then
    local authoring = require "authoring"
    guarded(set.authoring.line, authoring.install, a, s, { folder = v "authoring" })
  end
  -- the workspace's kits: each installed once, with everything its lines told it
  a.kit_files = nil
  for _, f in ipairs(plan.kit_files) do
    a.kit_files = a.kit_files or {}
    a.kit_files[#a.kit_files + 1] = f.path
  end
  for _, name in ipairs(plan.kit_order) do
    local k = plan.kits[name]
    guarded(k.line, kits.use, a, name, k.told, s, k.lines)
  end

  -- stores, before the tools that write them
  for _, name in ipairs(plan.store_order) do
    local st = plan.stores[name]
    local sort = {}
    for _, so in ipairs(plan.sorts or {}) do
      if so.store == name then sort[#sort + 1] = so.column end
    end
    guarded(st.line, s.store(name), { about = st.about, columns = st.columns, sort = #sort > 0 and sort or nil })
  end
  for _, so in ipairs(plan.sorts or {}) do
    if not plan.stores[so.store] then refuse(so.line, "there is no store %s", so.store) end
  end

  -- tools declared here: modifiers folded in before `spec.add_tool` checks the whole
  local function body_of(name, m, line)
    local b = m and m.body
    if not b then refuse(line, "the tool %s has no body: say what it does (`the tool %s does:`, `answers`, "
      .. "`adds a row to` or `lists`)", name, name) end
    if b.kind == "lua" then
      local chunk, why = compile_body(b.doc, "c", (title or "feature") .. ": the tool " .. name
                                      .. ", at line " .. b.line)
      if not chunk then refuse(b.line, "the body of %s does not compile: %s", name, why) end
      return run_body(chunk), { kind = "lua", doc = b.doc }
    elseif b.kind == "answers" then
      local text = b.text
      return function () return text end, { kind = "answers", text = text }
    elseif b.kind == "adds" then
      local st = a.stores[b.store]
      if not st then refuse(b.line, "there is no store %s", b.store) end
      local tool = plan.tools[name]
      for k in pairs(tool and tool.args or {}) do
        if not st.columns[k] then refuse(b.line, "%s adds a row to %s, and %s is not one of its columns", name, b.store, k) end
      end
      for k, col in pairs(st.columns) do
        if col.required and not (tool and tool.args[k]) then
          refuse(b.line, "%s adds a row to %s, which needs %s, and the tool does not take it", name, b.store, k)
        end
      end
      local store_name = b.store
      return function (c)
        local row = {}
        for k, val in pairs(c.args) do row[k] = val end
        local ok, why = c.store.add(store_name, row)
        if not ok then return nil, why end
        return "added a row to " .. store_name
      end, { kind = "adds", store = store_name }
    elseif b.kind == "lists" then
      local st = a.stores[b.store]
      if not st then refuse(b.line, "there is no store %s", b.store) end
      local store_name = b.store
      return function (c)
        local rows = c.store.rows(store_name)
        if #rows == 0 then return store_name .. " holds no rows" end
        local out = {}
        for i = 1, #rows do out[i] = render_row(st, rows[i]) end
        return table.concat(out, "\n")
      end, { kind = "lists", store = store_name }
    end
  end

  local function requires_of(name, m)
    local out = {}
    for i = 1, #(m and m.requires or {}) do
      local r = m.requires[i]
      local chunk, why = compile_body(r.doc, "c", (title or "feature") .. ": a requirement of " .. name
                                      .. ", at line " .. r.line)
      if not chunk then refuse(r.line, "the check of %s does not compile: %s", name, why) end
      out[#out + 1] = { says = r.says, check = run_body(chunk), source = r.doc }
    end
    return #out > 0 and out or nil
  end

  for _, name in ipairs(plan.tool_order) do
    local t = plan.tools[name]
    if t then
      local m = plan.mods[name]
      if m and m.about then
        refuse(m.about.line, "the tool %s says what it is for where it is declared, at line %d", name, t.line)
      end
      local ask = m and m.ask and true or nil
      if m and m.always then ask = "always" end
      if m and m.edit then ask = { edit = m.edit, always = m and m.always and true or nil } end
      local run, said = body_of(name, m, t.line)
      guarded(t.line, s.tool(name), {
        about = t.about, args = t.args, ask = ask, preview = m and m.preview or nil,
        requires = requires_of(name, m), run = run, said = said,
      })
    else
      -- a delegate: the agent in another feature file
      local d = plan.delegates[name]
      if type(opts.read) ~= "function" then
        refuse(d.line, "this host gives the loader no way to read %s", q(d.path))
      end
      local loading = opts.loading or {}
      if loading[d.path] then refuse(d.line, "%s hands work to itself, through %s", q(d.path), q(loading[d.path])) end
      local text, why = opts.read(d.path)
      if not text then refuse(d.line, "cannot read %s: %s", q(d.path), tostring(why)) end
      local child = spec.new()
      local nested = {}
      for k, val in pairs(loading) do nested[k] = val end
      nested[d.path] = title or "this feature"
      local ok, bad = declare.apply(text, child, { read = opts.read, loading = nested, model = opts.model })
      if not ok then refuse(d.line, "%s: %s", d.path, bad) end
      if not child.name then refuse(d.line, "%s declares no name, so it cannot be handed work", q(d.path)) end
      guarded(d.line, kits.delegate, a, name, {
        about = "Hand work to " .. child.name .. ", the agent in " .. d.path
          .. (ok.title and (": " .. ok.title) or "") .. ". Say what you want done in the prompt.",
        agents = { [child.name] = child },
        world = function () return child_world() end,
      })
      a.kits = a.kits or {}
      a.kits.delegates = a.kits.delegates or {}
      a.kits.delegates[name] = { path = d.path }
    end
  end

  -- modifiers on tools this file did not declare: a kit's, or a Lua declaration's
  for _, name in ipairs(plan.mod_order) do
    if not plan.tools[name] then
      local m = plan.mods[name]
      local tool = a.tools[name]
      if not tool then
        local have = {}
        for i = 1, #a.order do have[i] = a.order[i] end
        refuse(m.line, "there is no tool %s; this agent has %s", name, #have > 0 and table.concat(have, ", ") or "none")
      end
      if m.body then refuse(m.body.line, "the tool %s has its body already, from where it was declared", name) end
      if m.ask then tool.ask = true end
      if m.always then tool.ask = true; tool.always = true end
      if m.about then tool.about = m.about.text end
      if m.edit then
        for _, arg in ipairs(m.edit) do
          local p = tool.args[arg]
          if not p then refuse(m.line, "the tool %s has no argument %s", name, arg) end
          if not (p.choices or p.kind == "boolean" or p.kind == "number") then
            refuse(m.line, "the person can change a one of, a boolean or a number at the gate, and %s is %s", arg, p.kind)
          end
        end
        tool.edit = m.edit
      end
      if m.preview then tool.preview = true end
      local req = requires_of(name, m)
      if req then
        tool.requires = tool.requires or {}
        for i = 1, #req do tool.requires[#tool.requires + 1] = req[i] end
      end
    end
  end

  -- limits: a call hook that refuses the call past the number
  for _, name in ipairs(plan.mod_order) do
    local m = plan.mods[name]
    if m.limit then
      if not a.tools[name] then refuse(m.limit.line, "there is no tool %s", name) end
      -- Counted per run: a run's id is its agent's name, so two runs in a row share one,
      -- and the count starts again when a run does.
      local n, by_id = m.limit.n, {}
      a.kits = a.kits or {}
      a.kits.limits = a.kits.limits or {}
      a.kits.limits[name] = n
      guarded(m.limit.line, s.on("start"), function (e) by_id[tostring(e.id)] = 0 end)
      guarded(m.limit.line, s.on("call"), function (e)
        if e.tool ~= name then return nil end
        local id = tostring(e.id)
        by_id[id] = (by_id[id] or 0) + 1
        if by_id[id] > n then
          return { allow = false, why = string.format("%s may be called at most %d time%s", name, n, n == 1 and "" or "s") }
        end
        return nil
      end)
    end
  end

  for _, name in ipairs(plan.skill_order) do
    local sk = plan.skills[name]
    guarded(sk.line, s.skill(name), { about = sk.about, does = sk.does, file = sk.file })
  end
  for _, name in ipairs(plan.beat_order) do
    local b = plan.beats[name]
    if not b.runs then refuse(b.line, "the beat %s says how often and not what it asks: "
      .. "`the beat %s comes every ... and asks \"...\"`", name, name) end
    guarded(b.line, s.every(name), { every = b.every, day_at = b.day_at, runs = b.runs, once_per = b.once_per })
  end
  for _, name in ipairs(plan.server_order) do
    local sv = plan.servers[name]
    guarded(sv.line, s.uses(name), sv.cfg)
  end
  for _, st in ipairs(plan.steps) do
    local chunk, why = compile_body(st.doc, "c", (title or "feature") .. ": the step at line " .. st.line)
    if not chunk then refuse(st.line, "the step's body does not compile: %s", why) end
    local d = { source = st.doc }
    if st.phase == "given" then d.given = run_body(chunk) else d.then_ = run_body(chunk) end
    guarded(st.line, s.step(st.expr), d)
  end
  for _, al in ipairs(plan.allow) do guarded(al.line, s.allow, al.tool) end
  for _, de in ipairs(plan.deny) do guarded(de.line, s.deny, de.tool) end
end

--- Apply the is lines of `text` to the agent table `a` -- a fresh `spec.new()`, or one a Lua
--- declaration already wrote. Answers a table about the file, or `nil, sentence`; never
--- raises on a bad file, and runs nothing.
---
--- opts: `read(path) -> text` for the files a line names; `loading`, the files already
--- being loaded above this one, so an agent that hands work to itself is refused.
function declare.apply(text, a, opts)
  if type(text) ~= "string" then
    error("declare.apply(text, a): text is the feature file, and arrived as " .. type(text), 2)
  end
  if type(a) ~= "table" or type(a.tools) ~= "table" then
    error("declare.apply(text, a): a is an agent table (spec.new()), and arrived as " .. type(a), 2)
  end
  opts = opts or {}
  local doc, why = gherkin.document(text)
  if not doc then return nil, why end
  -- the kits first, so their lines are vocabulary when the rest of the Background is read
  local loaded, kbad = load_kits(doc, opts)
  if not loaded then return nil, kbad end
  local lines, bad = is_lines(doc)
  if not lines then return nil, bad end

  -- Every line-level problem at once, so one reply can fix them all: a doc string or a table
  -- missing or not wanted.
  local problems = {}
  for _, l in ipairs(lines) do
    local e = "`" .. l.def.expr .. "`"
    if l.def.doc and not l.step.doc then
      problems[#problems + 1] = string.format('line %d: %s takes a doc string, in """ on the lines under it', l.step.line, e)
    elseif l.def.rows and not l.step.rows then
      problems[#problems + 1] = string.format("line %d: %s takes a table on the lines under it", l.step.line, e)
    elseif not l.def.doc and l.step.doc then
      problems[#problems + 1] = string.format("line %d: %s takes no doc string", l.step.line, e)
    elseif not l.def.rows and l.step.rows then
      problems[#problems + 1] = string.format("line %d: %s takes no table", l.step.line, e)
    end
  end
  if #problems > 0 then return nil, table.concat(problems, "\n") end

  local plan = new_plan()
  local ok, err = pcall(function ()
    for _, l in ipairs(lines) do
      l.def.apply(plan, l.step, unpack(l.args, 1, l.args.n or #l.args))
    end
    build(plan, a, opts, doc.name)
  end)
  if not ok then
    if type(err) == "table" and err[REFUSAL] then return nil, err.why end
    return nil, tostring(err)
  end
  -- In a file that says what the agent is, a Background line that is neither an is line nor
  -- a line the runner can read is a typo in the declaration, and saying so now beats a
  -- scenario reported undefined for a reason three screens away.
  if #lines > 0 and doc.background then
    local list = shorthands_of(doc, a) or {}
    for _, st in ipairs(doc.background.steps) do
      if not match_is(st.text) and not match_built_in(st.text) then
        local known = false
        for i = 1, #a.step_order do
          local d = a.steps[a.step_order[i]]
          if d.compiled and d.compiled.match(st.text) then known = true end
        end
        for _, sh in ipairs(list) do
          if sh.expr.match(st.text) then known = true end
        end
        if not known then return nothing_matches(st.line, st.text) end
      end
    end
  end
  local seen = {}
  for i = 1, #lines do seen[lines[i].step.line] = true end
  -- `opts.model` puts one model in place of the file's, and of every delegate's under it:
  -- how an eval runs a file written for the doubles against the real model unchanged.
  if type(opts.model) == "string" then a.model = opts.model end
  return { title = doc.name, lines = seen, count = #lines }
end

--- Whether a feature says what an agent is at all.
function declare.declares(text)
  local doc = gherkin.document(text)
  if not doc or not doc.background then return false end
  for i = 1, #doc.background.steps do
    if match_is(doc.background.steps[i].text) then return true end
  end
  return false
end

-- ------------------------------------------------------------------ shorthands

local MAX_DEPTH = 8

-- `it files a <verdict> verdict` -> `it files a {word} verdict`, and the names in order.
local function shorthand_expr(title, line)
  if title:find("/", 1, true) then
    return at(line, "a shorthand's name may not hold `/`, which an expression reads as a choice")
  end
  local names, out = {}, {}
  local i = 1
  while i <= #title do
    local quoted = title:match('^"<([%w_][%w_%-%.]*)>"', i)
    local bare = not quoted and title:match("^<([%w_][%w_%-%.]*)>", i)
    if quoted then
      names[#names + 1] = quoted
      out[#out + 1] = "{string}"
      i = i + #quoted + 4
    elseif bare then
      names[#names + 1] = bare
      out[#out + 1] = "{word}"
      i = i + #bare + 2
    else
      local c = title:sub(i, i)
      -- `(s)` is optional text, as in every expression; a brace is only ever text here.
      if c == "{" or c == "\\" then out[#out + 1] = "\\" .. c else out[#out + 1] = c end
      i = i + 1
    end
  end
  local seen = {}
  for _, n in ipairs(names) do
    if seen[n] then return at(line, "the shorthand names <%s> twice", n) end
    seen[n] = true
  end
  return table.concat(out), names
end

local function sub(text, values)
  if text == nil then return nil end
  return (text:gsub("<([^<>]+)>", function (n)
    local v = values[n]
    if v == nil then return "<" .. n .. ">" end
    return v
  end))
end

-- Every shorthand the document defines, checked; or nil and why. `decl` is the agent, for
-- its declared steps.
shorthands_of = function (doc, decl)
  local list = {}
  local blocks = {}
  for i = 1, #doc.scenarios do blocks[#blocks + 1] = doc.scenarios[i] end
  for r = 1, #doc.rules do
    for i = 1, #doc.rules[r].scenarios do blocks[#blocks + 1] = doc.rules[r].scenarios[i] end
  end
  local skeletons = behaviour.skeletons()
  local is_list = compiled()
  local is_skel = {}
  for i = 1, #is_list do is_skel[is_list[i].expr.skeleton()] = is_list[i].def.expr end
  local decl_steps = {}
  for i = 1, #((decl and decl.step_order) or {}) do
    local st = decl.steps[decl.step_order[i]]
    if st.compiled then decl_steps[#decl_steps + 1] = st end
  end

  for _, b in ipairs(blocks) do
    if is_shorthand_block(b) then
      if b.kind == "outline" then return at(b.line, "a shorthand is a Scenario, not an outline") end
      local text, names = shorthand_expr(b.name, b.line)
      if not text then return nil, names end
      local e, why = gherkin.expr(text)
      if not e then return at(b.line, "the shorthand %s: %s", q(b.name), why) end
      local sk = e.skeleton()
      if skeletons[sk] then return at(b.line, "the shorthand %s reads the same lines as the built-in %s", q(b.name), q(skeletons[sk])) end
      if is_skel[sk] then return at(b.line, "the shorthand %s reads the same lines as the is line %s", q(b.name), q(is_skel[sk])) end
      for _, st in ipairs(decl_steps) do
        if st.compiled.skeleton() == sk then return at(b.line, "the shorthand %s reads the same lines as the step %s", q(b.name), q(st.expr)) end
      end
      for _, other in ipairs(list) do
        if other.expr.skeleton() == sk then return at(b.line, "the shorthand %s reads the same lines as the one at line %d", q(b.name), other.line) end
      end
      if #b.steps == 0 then return at(b.line, "the shorthand %s stands for nothing: it has no lines", q(b.name)) end
      local known = {}
      for _, n in ipairs(names) do known[n] = true end
      for _, s in ipairs(b.steps) do
        for _, field in ipairs({ s.text, s.doc or "" }) do
          for n in field:gmatch("<([%w_][%w_%-%.]*)>") do
            if not known[n] then return at(s.line, "this shorthand has no <%s>; its name has %s", n,
              #names > 0 and ("<" .. table.concat(names, ">, <") .. ">") or "none") end
          end
        end
      end
      list[#list + 1] = { name = b.name, expr = e, names = names, steps = b.steps, line = b.line }
    end
  end

  -- Phases, now every shorthand is known: each line is a built-in, a declared step or
  -- another shorthand, and every line of one shorthand is in one phase.
  local by_index = {}
  local function phase_of_line(text, visiting)
    local def = match_built_in(text)
    if def then return def.phase end
    for _, st in ipairs(decl_steps) do
      if st.compiled.match(text) then return st.phase end
    end
    for _, sh in ipairs(list) do
      if sh.expr.match(text) then
        if visiting[sh] then return nil, "loop", sh end
        if by_index[sh] then return by_index[sh] end
        visiting[sh] = true
        local p, kind, who = nil, nil, nil
        for _, s in ipairs(sh.steps) do
          local lp, k, w = phase_of_line(s.text, visiting)
          if not lp then p, kind, who = nil, k or "unmatched", w or s; break end
          if p and lp ~= p then p, kind, who = nil, "mixed", sh; break end
          p = lp
        end
        visiting[sh] = nil
        if p then by_index[sh] = p end
        return p, kind, who
      end
    end
    return nil, "unmatched"
  end
  for _, sh in ipairs(list) do
    local p
    for _, s in ipairs(sh.steps) do
      local lp, kind, who = phase_of_line(s.text, { [sh] = true })
      if not lp then
        if kind == "loop" then return at(s.line, "the shorthand %s reaches itself, through %s", q(sh.name), q(who.name)) end
        if kind == "mixed" then return at(s.line, "the shorthand %s mixes phases", q(who.name)) end
        return at(s.line, "this line of the shorthand %s matches no step", q(sh.name))
      end
      if lp == "when" then
        return at(s.line, "a shorthand is given lines or then lines; the three ways a run starts are the harness's")
      end
      if p and lp ~= p then return at(s.line, "every line of the shorthand %s is in one phase, and this is %s after %s", q(sh.name), lp, p) end
      p = lp
    end
    sh.phase = p
  end
  return list
end

-- One pickle's steps with every shorthand expanded, or nil and why.
local function expand(steps, list, depth)
  if depth > MAX_DEPTH then return nil, "shorthands nest more than " .. MAX_DEPTH .. " deep" end
  local out = {}
  for _, s in ipairs(steps) do
    local hit, args
    for _, sh in ipairs(list) do
      local got = sh.expr.match(s.text)
      if got then
        if hit then return at(s.line, "two shorthands match this line: %s and %s", q(hit.name), q(sh.name)) end
        hit, args = sh, got
      end
    end
    if hit and match_built_in(s.text) then
      return at(s.line, "this line reads as the shorthand %s and as a built-in step", q(hit.name))
    end
    if not hit then
      out[#out + 1] = s
    else
      local values = {}
      for i, n in ipairs(hit.names) do values[n] = tostring(args[i]) end
      local inner = {}
      for _, t in ipairs(hit.steps) do
        local rows = nil
        if t.rows then
          rows = {}
          for r = 1, #t.rows do
            local row = {}
            for c = 1, #t.rows[r] do row[c] = sub(t.rows[r][c], values) end
            rows[r] = row
          end
        end
        inner[#inner + 1] = { keyword = t.keyword, text = sub(t.text, values), line = s.line,
                              doc = sub(t.doc, values), doc_type = t.doc_type, rows = rows,
                              from = t.line }
      end
      local more, why = expand(inner, list, depth + 1)
      if not more then return nil, why end
      for _, m in ipairs(more) do out[#out + 1] = m end
    end
  end
  return out
end

--- The scenarios of `text` a runner walks: the is lines taken out, the shorthands taken out
--- and expanded where they are used. `decl` is the agent the file is run against, for its
--- declared steps. Answers the pickles and the shorthands, or `nil, sentence`.
function declare.pickles(text, decl)
  local doc, why = gherkin.document(text)
  if not doc then return nil, why end
  local lines, bad = is_lines(doc)
  if not lines then return nil, bad end
  local strip = {}
  for i = 1, #lines do strip[lines[i].step.line] = true end

  local list, why2 = shorthands_of(doc, decl)
  if not list then return nil, why2 end
  local skip = {}
  for _, sh in ipairs(list) do skip[sh.line] = true end

  local pickles, why3 = gherkin.pickle(text)
  if not pickles then return nil, why3 end
  local out = {}
  for _, p in ipairs(pickles) do
    if not skip[p.line] then
      local kept = {}
      for _, s in ipairs(p.steps) do
        if not strip[s.line] then kept[#kept + 1] = s end
      end
      local steps, bad2 = expand(kept, list, 1)
      if not steps then return nil, bad2 end
      out[#out + 1] = { name = p.name, line = p.line, tags = p.tags, steps = steps }
    end
  end
  return out, list
end

-- ------------------------------------------------------------------ editing
--
-- One change to a feature file's TEXT, which comes back byte for byte everywhere the edit
-- did not touch. Each edit is classified by what it does to the agent's reach, and that is
-- the wall an agent editing itself meets (spec/declare.md, "Reach, and the wall").

local RANK = { neither = 0, narrows = 1, widens = 2 }
local INVERSE = { widens = "narrows", narrows = "widens", neither = "neither" }
local function most(x, y) return RANK[x] >= RANK[y] and x or y end

local GATE_WHY = "an `asks first` line is the gate: an agent may add one and never take one away, "
  .. "and a person who wants a tool to stop asking edits the file themselves"

local function lines_of(text)
  local out = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = l end
  return out
end

local function splice(lines, from, to, with)
  local out = {}
  for i = 1, from - 1 do out[#out + 1] = lines[i] end
  for i = 1, #with do out[#out + 1] = with[i] end
  for i = to + 1, #lines do out[#out + 1] = lines[i] end
  return out
end

local function cell(v)
  return (tostring(v):gsub("\\", "\\\\"):gsub("|", "\\|"):gsub("\n", "\\n"))
end

-- A step as lines: the keyword line, then its doc string or its table, indented under it.
local function render_step(indent, keyword, text, doc, doc_type, rows)
  local out = { indent .. keyword .. " " .. text }
  local inner = indent .. "  "
  if doc then
    out[#out + 1] = inner .. '"""' .. (doc_type or "")
    for l in (doc .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = l == "" and "" or inner .. l end
    out[#out + 1] = inner .. '"""'
  elseif rows then
    local width = {}
    for r = 1, #rows do
      for c = 1, #rows[r] do width[c] = math.max(width[c] or 0, #cell(rows[r][c])) end
    end
    for r = 1, #rows do
      local cells = {}
      for c = 1, #rows[r] do
        local v = cell(rows[r][c])
        cells[c] = v .. string.rep(" ", width[c] - #v)
      end
      out[#out + 1] = inner .. "| " .. table.concat(cells, " | ") .. " |"
    end
  end
  return out
end

local function indent_of(line) return line:match("^(%s*)") or "" end

-- What a change of one is line to another does to reach: the gate never opens, a replace
-- that keeps the expression and its names takes the line's `same`, anything else is the
-- larger of taking the old line away and adding the new one.
local function reach_of_replace(old, new)
  if old.def.gate then
    if new.def.gate and tostring(old.args[1]) == tostring(new.args[1]) and new.def.expr == old.def.expr then
      return "neither"
    end
    return nil, GATE_WHY
  end
  if old.def.expr == new.def.expr then
    -- a kit's narrowing line may say when another value of it is narrower still: a mode's
    -- tool list shortened is a narrowing, where a glob or a limit changed is not (docs/spec/kit.md)
    if old.def.reach == "narrows" and type(old.def.narrower) == "function" then
      local ok, is_narrower = pcall(old.def.narrower, old.args, new.args)
      if ok and is_narrower == true then return "narrows" end
    end
    local names_same, i = true, 0
    for _, seg in ipairs(old.e.segs) do
      if seg.kind == "param" then
        i = i + 1
        -- a name, or on a narrowing line anything at all: a different glob or limit is the
        -- old narrowing taken away and another added, which is a widening
        if (seg.type == "word" or old.def.reach == "narrows") and tostring(old.args[i]) ~= tostring(new.args[i]) then
          names_same = false
        end
      end
    end
    if names_same then
      local same = old.def.same or old.def.reach
      if same == "rows" then
        local a, b = old.step.rows or {}, new.rows or old.step.rows or {}
        local equal = #a == #b
        for r = 1, #a do
          for c = 1, math.max(#a[r], #(b[r] or {})) do
            if tostring(a[r][c]) ~= tostring((b[r] or {})[c]) then equal = false end
          end
        end
        return equal and "neither" or "widens"
      end
      return same
    end
  end
  return most(INVERSE[old.def.reach], new.def.reach)
end

local function find_is(doc, text)
  local bg = doc.background
  if not bg then return nil end
  -- Coerced at the edge (2026-09-12, from the refusal list at nine samples): a line that
  -- takes a doc string is named without its colon as often as with it (`it is briefed`).
  local want = trim(text)
  for i = 1, #bg.steps do
    local s = bg.steps[i]
    if s.text == text or trim(s.text) == want or (s.text:sub(-1) == ":" and trim(s.text:sub(1, -2)) == want) then
      local def, args, _, e = match_is(s.text)
      if def then return { step = s, def = def, args = args, e = e, index = i } end
    end
  end
  return nil
end

local function block_start(lines, line)
  local first = line
  while first > 1 and trim(lines[first - 1]):sub(1, 1) == "@" do first = first - 1 end
  return first
end

-- Every line where a block starts (its first tag line), in order: where one block ends.
local function starts(doc, lines)
  local out = {}
  for _, b in ipairs(other_blocks(doc)) do out[#out + 1] = block_start(lines, b.line) end
  for _, r in ipairs(doc.rules) do out[#out + 1] = block_start(lines, r.line) end
  table.sort(out)
  return out
end

-- A scenario written by the agent, normalised: its own indentation removed and the
-- file's put back, under the tag that says who wrote it.
local function scenario_lines(text, tag)
  local raw = lines_of(tostring(text))
  while #raw > 0 and trim(raw[#raw]) == "" do raw[#raw] = nil end
  while #raw > 0 and trim(raw[1]) == "" do table.remove(raw, 1) end
  if #raw == 0 then return nil, "the scenario is empty" end
  -- the tag is the tool's to put on; one already written is taken off, on its own line or
  -- ahead of the keyword, so a model that writes what it will see is not refused for it
  if trim(raw[1]) == tag then table.remove(raw, 1) end
  if #raw == 0 then return nil, "the scenario is empty" end
  if trim(raw[1]):sub(1, #tag + 1) == tag .. " " then raw[1] = indent_of(raw[1]) .. trim(raw[1]):sub(#tag + 2) end
  local head = trim(raw[1])
  if not (head:sub(1, 9) == "Scenario:" or head:sub(1, 8) == "Example:") then
    return nil, "a scenario starts with `Scenario:`, and this starts " .. q(head:sub(1, 30))
  end
  local cut = #indent_of(raw[1])
  local out = { "", "  " .. tag }
  for i = 1, #raw do
    local l = raw[i]
    local strip = math.min(cut, #indent_of(l))
    out[#out + 1] = l == "" and "" or ("  " .. l:sub(strip + 1))
  end
  return out
end

local EDIT_OPS = { "add", "remove", "replace", "scenario", "shorthand", "withdraw" }

--- One edit to a feature's text. Answers the new text and `{ reach = ..., why = ... }`, or
--- `nil, sentence`; the third return is `"wall"` when the edit crossed the wall rather than
--- being malformed. It never raises on a bad edit and never writes anything.
---
---   { add = "the tool verdict asks first" }            an is line, after the others
---   { add = "...", doc = "...", doc_type = "lua" }     with its doc string
---   { add = "...", rows = { { "argument", ... }, ... } }  or its table
---   { remove = "it runs commands" }
---   { replace = "it may take 12 steps", with = "it may take 16 steps" }
---   { scenario = "Scenario: ...\n  Given ..." }         a new scenario, tagged @proposed
---   { shorthand = "Scenario: <name> ...\n  Then ..." }   a new shorthand, tagged @shorthand
---   { withdraw = "the name of a @proposed scenario" }
function declare.edit(text, op)
  if type(text) ~= "string" then error("declare.edit(text, op): text is a feature file", 2) end
  if type(op) ~= "table" then error("declare.edit(text, op): op is a table", 2) end
  local kind
  for _, k in ipairs(EDIT_OPS) do
    if op[k] ~= nil then
      if kind then return nil, "an edit makes one change, and this names " .. kind .. " and " .. k end
      kind = k
    end
  end
  if not kind then return nil, "an edit names one of " .. table.concat(EDIT_OPS, ", ") end
  local doc, why = gherkin.document(text)
  if not doc then return nil, why end
  local lines = lines_of(text)
  local bg = doc.background
  local reach, because

  if kind == "add" then
    local def, _, two = match_is(op.add)
    if two then return nil, two end
    if not def then return nil, q(op.add) .. " is not an is line; `vocabulary` lists every one there is" end
    local is_now = {}
    if bg then
      for i = 1, #bg.steps do
        if bg.steps[i].text == op.add then
          return nil, "the Background already says " .. q(op.add) .. "; there is nothing to add"
        end
        if match_is(bg.steps[i].text) then is_now[#is_now + 1] = bg.steps[i] end
      end
    end
    local doc_text = op.doc
    local rows = op.rows
    if def.doc and not doc_text then return nil, "this line takes a doc string: give it as `doc`" end
    if def.rows and not rows then return nil, "this line takes a table: give it as `rows`, a list of rows" end
    local indent, keyword, at_line, patch = "    ", "And", nil, nil
    if #is_now > 0 then
      local last = is_now[#is_now]
      indent = indent_of(lines[last.line])
      at_line = last.last + 1
    elseif bg then
      keyword = "Given"
      at_line = bg.line + 1
      local first = bg.steps[1]
      if first then
        indent = indent_of(lines[first.line])
        if first.keyword == "Given" then patch = first.line end
      end
    end
    local new = render_step(indent, keyword, op.add, def.doc and doc_text or nil,
                            def.doc and (op.doc_type or (def.expr:find("does:", 1, true) and "lua") or nil) or nil,
                            def.rows and rows or nil)
    if at_line then
      if patch then lines[patch] = lines[patch]:gsub("Given ", "And ", 1) end
      lines = splice(lines, at_line, at_line - 1, new)
    else
      -- No Background yet: one goes before the first scenario, or at the end.
      local first_block = starts(doc, lines)[1]
      local head = { "  Background:" }
      new[1] = new[1]:gsub("^%s*And ", "    Given ")
      for i = 1, #new do head[#head + 1] = new[i] end
      if first_block then
        head[#head + 1] = ""
        lines = splice(lines, first_block, first_block - 1, head)
      else
        while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
        lines[#lines + 1] = ""
        for i = 1, #head do lines[#lines + 1] = head[i] end
        lines[#lines + 1] = ""
      end
    end
    reach = def.reach
    because = "adds " .. q(op.add)

  elseif kind == "remove" then
    local found = find_is(doc, op.remove)
    if not found then return nil, "the Background has no is line " .. q(op.remove) end
    if found.def.gate then return nil, "refused: " .. GATE_WHY, "wall" end
    -- Removing a tool is one change: the lines that say more about it go with it, its gate
    -- included, because a gate on a tool that is not there guards nothing.
    local tool = nil
    if found.def.covers == "tool" and found.def.expr:sub(1, 13) == "it has a tool" then tool = found.args[1]
    elseif found.def.covers == "delegate" then tool = found.args[2] end
    local gone = { found }
    if tool then
      for i = 1, #bg.steps do
        local st = bg.steps[i]
        local def, args = match_is(st.text)
        if def and st ~= found.step and def.expr:sub(1, 15) == "the tool {word}" and args[1] == tool then
          gone[#gone + 1] = { step = st, index = i }
        end
      end
    end
    table.sort(gone, function (x, y) return x.step.line > y.step.line end)
    local first = gone[#gone]
    local after = nil
    for i = first.index + 1, #bg.steps do
      local taken = false
      for _, g in ipairs(gone) do if g.step == bg.steps[i] then taken = true end end
      if not taken then after = bg.steps[i]; break end
    end
    if first.step.keyword == "Given" and after and after.keyword == "And" then
      lines[after.line] = lines[after.line]:gsub("And ", "Given ", 1)
    end
    for _, g in ipairs(gone) do lines = splice(lines, g.step.line, g.step.last, {}) end
    reach = INVERSE[found.def.reach]
    because = "removes " .. q(op.remove) .. (#gone > 1 and string.format(" and the %d line(s) about %s", #gone - 1, tool) or "")

  elseif kind == "replace" then
    local found = find_is(doc, op.replace)
    if type(op.with) ~= "string" then
      if found and found.def.doc then
        return nil, "a replace says what goes in, as `with`; for " .. q(found.step.text)
          .. ", whose text is a doc string, send with = the same line and doc = the new text"
      end
      return nil, "a replace says what goes in, as `with`: the old line as `line`, the new one as `with`"
    end
    if not found then return nil, "the Background has no is line " .. q(op.replace) end
    local def, args, two, e = match_is(op.with)
    if two then return nil, two end
    if not def then return nil, q(op.with) .. " is not an is line; `vocabulary` lists every one there is" end
    local r, wall = reach_of_replace(found, { def = def, args = args, e = e, rows = op.rows })
    if not r then return nil, "refused: " .. wall, "wall" end
    local indent = indent_of(lines[found.step.line])
    local new
    local keep_doc = def.doc and not op.doc and found.step.doc ~= nil
    local keep_rows = def.rows and not op.rows and found.step.rows ~= nil
    if keep_doc or keep_rows then
      new = { indent .. found.step.keyword .. " " .. op.with }
      for i = found.step.line + 1, found.step.last do new[#new + 1] = lines[i] end
    else
      if def.doc and not op.doc then return nil, "this line takes a doc string: give it as `doc`" end
      if def.rows and not op.rows then return nil, "this line takes a table: give it as `rows`" end
      new = render_step(indent, found.step.keyword, op.with, def.doc and op.doc or nil,
                        def.doc and (op.doc_type or found.step.doc_type) or nil, def.rows and op.rows or nil)
    end
    lines = splice(lines, found.step.line, found.step.last, new)
    reach = r
    because = "changes " .. q(op.replace) .. " to " .. q(op.with)

  elseif kind == "scenario" or kind == "shorthand" then
    local new, bad = scenario_lines(op[kind], kind == "scenario" and "@proposed" or "@shorthand")
    if not new then return nil, bad end
    while #lines > 0 and lines[#lines] == "" do lines[#lines] = nil end
    for i = 1, #new do lines[#lines + 1] = new[i] end
    lines[#lines + 1] = ""
    reach = "neither"
    because = kind == "scenario" and "proposes a scenario, which is not scored until a person accepts it"
      or "adds a shorthand"

  elseif kind == "withdraw" then
    local target
    for _, b in ipairs(other_blocks(doc)) do
      if b.kind ~= "background" and b.name == op.withdraw then target = b; break end
    end
    if not target then return nil, "there is no scenario " .. q(op.withdraw) end
    local proposed = false
    for _, t in ipairs(target.tags) do if t == "@proposed" then proposed = true end end
    if not proposed then
      return nil, "refused: " .. q(op.withdraw) .. " is authored -- a person wrote or accepted it -- and an agent "
        .. "may withdraw only a scenario it proposed", "wall"
    end
    local first = block_start(lines, target.line)
    local last = #lines
    for _, st in ipairs(starts(doc, lines)) do
      if st > target.line then last = st - 1; break end
    end
    while last > first and trim(lines[last]) == "" do last = last - 1 end
    if first > 1 and trim(lines[first - 1]) == "" then first = first - 1 end
    lines = splice(lines, first, last, {})
    reach = "neither"
    because = "withdraws the proposed scenario " .. q(op.withdraw)
  end

  local out = table.concat(lines, "\n")
  -- What comes back must still be a file this tree reads, with its is lines in their place.
  local doc2, bad = gherkin.document(out)
  if not doc2 then return nil, "the edit would leave a file that does not read: " .. bad end
  local ok, bad2 = is_lines(doc2)
  if not ok then return nil, "the edit would leave " .. bad2 end
  if kind == "scenario" or kind == "shorthand" then
    local added = #other_blocks(doc2) - #other_blocks(doc)
    if added ~= 1 then
      return nil, string.format("a %s edit adds one scenario, and this adds %d", kind, added)
    end
    -- A name says which scenario a report, a withdraw and a person mean; two by one name
    -- make all three ambiguous.
    local function counts(d)
      local out = {}
      for _, b in ipairs(other_blocks(d)) do
        if b.kind ~= "background" then out[b.name] = (out[b.name] or 0) + 1 end
      end
      return out
    end
    local was, now = counts(doc), counts(doc2)
    for name, n in pairs(now) do
      if n > 1 and n > (was[name] or 0) then
        return nil, "there is a scenario called " .. q(name) .. " already; give this one its own name"
      end
    end
  end
  -- THE WALL, as an invariant rather than a list: every line of every authored scenario
  -- means after the edit exactly what it meant before. That is what "the test is the
  -- person's" is -- not only its text, but which expression reads each line, and what a
  -- shorthand it uses says -- so a scenario slipped in untagged, a shorthand that gives an
  -- authored line a meaning, or a step body written to define one, are all refused here.
  local before, after = declare.meanings(text), declare.meanings(out)
  for key, meant in pairs(before) do
    if after[key] ~= meant then
      return nil, "refused: this would change what the authored line " .. key .. " says, and what an "
        .. "authored line says is the person's", "wall"
    end
  end
  for key in pairs(after) do
    if before[key] == nil then
      return nil, "refused: this would add the authored line " .. key .. "; a scenario an agent writes is "
        .. "@proposed until a person accepts it", "wall"
    end
  end
  return out, { reach = reach, why = because, kind = kind }
end

--- What each line of each authored scenario means: a map from `"name" line N: text` to the
--- expression that reads it (a built-in, a step the file declares, or a shorthand and what
--- its lines say), or to "nothing" when none does. Two files whose maps are equal state the
--- same test.
function declare.meanings(text)
  local doc = gherkin.document(text)
  if not doc then return {} end
  -- the file's own steps and shorthands, by what they would read
  local steps = {}
  if doc.background then
    for _, st in ipairs(doc.background.steps) do
      local def, args = match_is(st.text)
      if def and def.covers == "step" then
        local e = gherkin.expr(args[1])
        if e then steps[#steps + 1] = { expr = e, says = def.expr .. " " .. args[1] .. "\n" .. tostring(st.doc) } end
      end
    end
  end
  local shorthands = {}
  for _, b in ipairs(other_blocks(doc)) do
    if b.kind ~= "background" and is_shorthand_block(b) then
      local text_e = shorthand_expr(b.name, b.line)
      local e = text_e and gherkin.expr(text_e)
      if e then
        local says = {}
        for _, st in ipairs(b.steps) do says[#says + 1] = st.text .. "|" .. tostring(st.doc) .. "|" .. tostring(st.rows and #st.rows) end
        shorthands[#shorthands + 1] = { expr = e, says = "shorthand " .. b.name .. ": " .. table.concat(says, "; ") }
      end
    end
  end
  local out = {}
  for _, b in ipairs(other_blocks(doc)) do
    if b.kind ~= "background" and declare.authored(b.tags) then
      local seen = {}
      for _, st in ipairs(b.steps) do
        local meant
        local def = match_built_in(st.text)
        if def then meant = "built-in " .. def.expr end
        for _, x in ipairs(steps) do if x.expr.match(st.text) then meant = (meant and meant .. " + " or "") .. x.says end end
        for _, x in ipairs(shorthands) do if x.expr.match(st.text) then meant = (meant and meant .. " + " or "") .. x.says end end
        local key = string.format("%s: %s", q(b.name), st.text)
        seen[key] = (seen[key] or 0) + 1
        if seen[key] > 1 then key = key .. " (" .. seen[key] .. ")" end
        out[key] = (meant or "nothing") .. " | doc " .. tostring(st.doc) .. " | rows " .. tostring(st.rows and #st.rows)
      end
      out[string.format("%s (the scenario)", q(b.name))] = tostring(#b.steps)
    end
  end
  return out
end

--- Whether a scenario is authored: a person wrote it or accepted it, so it is scored and an
--- agent may not touch it. `pickle.tags` or a block's.
function declare.authored(tags)
  for _, t in ipairs(tags or {}) do
    if t == "@proposed" or t == "@shorthand" then return false end
  end
  return true
end

return declare
