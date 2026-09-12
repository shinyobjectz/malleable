-- kits -- the toolkits, declared into one agent table.
--
-- One definition, two doors: `agent.files`, `agent.shell`, `agent.plan` and
-- `agent.delegate` on the prefix (agent.lua), and the is lines that say the same things in
-- a feature file (src/declare.lua). Lifted out of agent.lua so the two cannot drift, which
-- is the same reason `cli.surface` exists (DESIGN.md, reconciliation 1).
--
-- Nothing here runs a body (rule 2): each kit declares tools and returns. `surface` is the
-- table the kit declares through: the prefix, or `cli.surface(a)`.

local spec     = require "spec"
local tools_fs = require "tools_fs"
local tools_sh = require "tools_shell"
local command  = require "command"
local work     = require "work"
local subagent = require "subagent"

local kits = {}

local function fail(fmt, ...)
  error("agent: " .. string.format(fmt, ...), 4)
end

-- What a kit was told, and the tools it put on the agent, kept on `a.kits[name]` so the
-- declaration can be said back as is lines (src/say.lua, docs/spec/kit.md). `install`
-- runs the kit and records the tools that appeared, with the about and ask they had
-- before any feature line changed them.
local function record(a, name, told, install)
  local before, stores_before = {}, {}
  for i = 1, #a.order do before[a.order[i]] = true end
  for i = 1, #(a.store_order or {}) do stores_before[a.store_order[i]] = true end
  local function hook_count()
    local n = 0
    for _, list in pairs(a.hooks or {}) do n = n + #list end
    return n
  end
  local hooks_before = hook_count()
  local out = install()
  told.hooks = hook_count() - hooks_before     -- a kit's hooks are said by the kit's line
  -- a hook is a rail, and a rail ships with the scenarios it survives (docs/spec/kit.md)
  if told.hooks > 0 and type(told.kit) == "table" and told.kit.rails == nil then
    error("the kit " .. name .. " sets a hook and names no `rails`: the doubles scenarios its rail survives", 0)
  end
  local tools, stores = {}, {}
  for i = 1, #a.order do
    local t = a.order[i]
    if not before[t] then tools[t] = { about = a.tools[t].about, ask = a.tools[t].ask, always = a.tools[t].always } end
  end
  for i = 1, #(a.store_order or {}) do
    local st = a.store_order[i]
    if not stores_before[st] then stores[st] = true end
  end
  told.tools = tools
  told.stores = stores
  a.kits = a.kits or {}
  a.kits[name] = told
  return out
end
kits.record = record

-- ------------------------------------------------------------------ a workspace's own kits
--
-- A kit is one Lua table of the shape docs/spec/kit.md gives: its is lines with their
-- reach, what using it installs, the steps a scenario says its world with, and how it is
-- said back. `kits.define` checks the shape; `declare.kit` compiles its lines against the
-- vocabulary and registers it here, for the process, by name; `kits.use` installs it on one
-- agent with what its lines told it.

kits.registered = {}     -- name -> { def, from, is = { { expr, def } }, steps = { { expr, def } } }
kits.order = {}
kits.version = 0         -- bumped on every registration; declare recompiles its vocabulary on it

local REACH = { widens = true, narrows = true, neither = true }
local BUILT_IN_KITS = { files = true, shell = true, plan = true, history = true, authoring = true,
                        limits = true, delegates = true }
kits.BUILT_IN = BUILT_IN_KITS

--- The shape, checked. Answers true, or nil and the rule broken, by name.
function kits.define(def)
  if type(def) ~= "table" then return nil, "a kit is a table, and this is " .. type(def) end
  if type(def.name) ~= "string" or not def.name:match("^[%a_][%w_]*$") then
    return nil, "a kit's `name` is a word of letters, digits and _"
  end
  local name = def.name
  if BUILT_IN_KITS[name] then return nil, "the kit " .. name .. " takes the name of a built-in kit" end
  if type(def.about) ~= "string" or def.about == "" then return nil, "the kit " .. name .. " needs `about`: a sentence" end
  if type(def.is) ~= "table" or #def.is == 0 then return nil, "the kit " .. name .. " needs `is`: at least one line" end
  for i = 1, #def.is do
    local e = def.is[i]
    if type(e) ~= "table" or type(e.expr) ~= "string" or e.expr == "" then
      return nil, string.format("the kit %s: is line %d needs `expr`, the line as an expression", name, i)
    end
    if not REACH[e.reach] then
      return nil, string.format("the kit %s: the line %q needs `reach`: widens, narrows or neither", name, e.expr)
    end
    if type(e.about) ~= "string" or e.about == "" then
      return nil, string.format("the kit %s: the line %q needs `about`: a sentence", name, e.expr)
    end
    if type(e.tells) ~= "function" then
      return nil, string.format("the kit %s: the line %q needs `tells = function (told, ...) end`", name, e.expr)
    end
    if e.narrower ~= nil and type(e.narrower) ~= "function" then
      return nil, string.format("the kit %s: the line %q: `narrower` is a function of the old and the new arguments", name, e.expr)
    end
    if e.gate ~= nil and type(e.gate) ~= "boolean" then
      return nil, string.format("the kit %s: the line %q: `gate` is true or false", name, e.expr)
    end
  end
  if type(def.install) ~= "function" then
    return nil, "the kit " .. name .. " needs `install = function (told, agent) ... end`"
  end
  if def.steps ~= nil and type(def.steps) ~= "table" then return nil, "the kit " .. name .. ": `steps` is a list" end
  for i = 1, #(def.steps or {}) do
    local st = def.steps[i]
    if type(st) ~= "table" or type(st.expr) ~= "string" or st.expr == "" then
      return nil, string.format("the kit %s: step %d needs `expr`", name, i)
    end
    local g, t = type(st.given) == "function", type(st.then_) == "function"
    if st.when ~= nil or st.when_ ~= nil then
      return nil, string.format("the kit %s: the step %q gives a `when`, and there is no such slot", name, st.expr)
    end
    if g == t then
      return nil, string.format("the kit %s: the step %q needs `given` or `then_`, one of them", name, st.expr)
    end
  end
  if def.says ~= nil and type(def.says) ~= "function" then
    return nil, "the kit " .. name .. ": `says` is a function of what it was told"
  end
  -- A kit that carries a rail (a hook) names the doubles scenarios the rail survives and
  -- says what a delegate under it gets (docs/spec/kit.md, "What a rail must survive").
  if def.rails ~= nil then
    if type(def.rails) ~= "table" or #def.rails == 0 then
      return nil, "the kit " .. name .. ": `rails` is a list of feature paths, beside the kit file"
    end
    for i = 1, #def.rails do
      if type(def.rails[i]) ~= "string" then return nil, "the kit " .. name .. ": rails entry " .. i .. " is not a path" end
    end
  end
  if def.delegate ~= nil and def.delegate ~= "fresh" and def.delegate ~= "inherit" then
    return nil, "the kit " .. name .. ": `delegate` is \"fresh\" or \"inherit\": what a delegate under it starts with"
  end
  if def.rails ~= nil and def.delegate == nil then
    return nil, "the kit " .. name .. " names rails and must say `delegate`: what a delegate under it starts with"
  end
  return true
end

--- Install the registered kit `name` on `a` through `surface`, with `told` (what its lines
--- said) and `lines` (their text, for saying it back). Its steps are declared on the
--- agent as the kit's, so a check does not count them as promises the file made.
function kits.use(a, name, told, surface, lines)
  local k = kits.registered[name]
  if not k then
    local have = {}
    for i = 1, #kits.order do have[i] = kits.order[i] end
    fail("there is no kit called %s; loaded: %s", tostring(name), #have > 0 and table.concat(have, ", ") or "none")
  end
  told = told or {}
  return record(a, name, { told = told, lines = lines, kit = k.def, from = k.from }, function ()
    k.def.install(told, surface)
    for i = 1, #k.steps do
      local st = k.steps[i].def
      local d = { kit = name }
      if st.given then d.given = st.given else d.then_ = st.then_ end
      surface.step(st.expr, d)
    end
  end)
end

--- read, write, edit, list, glob, search. With no `opts.port` they read the filesystem the
--- harness hands the tool body. The shim is `tools_fs.render`: bodies answer with a result
--- table and a transcript holds text.
function kits.files(a, opts, surface)
  local shim = {}
  for k, v in pairs(surface) do shim[k] = v end
  shim.tool = function (name, def)
    local function declare(d)
      local body = d.run
      d.run = function (c) return tools_fs.render(body(c)) end
      return spec.add_tool(a, name, d)
    end
    if def == nil then return declare end
    return declare(def)
  end
  local told = { read_only = opts and opts.read_only or false, deny = opts and opts.deny or nil }
  return record(a, "files", told, function () return tools_fs.install(shim, opts) end)
end

--- The shell tool. It asks by default (rule 4).
---
--- `name` and `root` are lifted out first: shell.options refuses an option it does not
--- know. `root` is the workspace root a cwd resolves against, filled in here because a
--- port table has no such field.
function kits.shell(a, opts)
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

  -- What a command line did, in terms. Wired here because `tools_shell.lua` reaches into
  -- no sibling. A declaration naming its own reader keeps it (spec/command.md).
  rest = rest or {}
  if rest.acts == nil then rest.acts = command.acts end

  local decl = tools_sh.tool(rest)
  local body = decl.run
  decl.run = function (c)
    if c.root == nil then c.root = root end
    -- One value out: a second return through the harness is dropped with a note on every
    -- call. A host wanting the structure calls shell.run itself.
    return (body(c))
  end
  return record(a, "shell", { timeout_ms = rest.timeout_ms }, function () return spec.add_tool(a, name, decl) end)
end

--- The two plan tools, plan and mark, over one live plan.
function kits.plan(opts, surface, a)
  if a == nil then return work.install(surface, opts) end
  return record(a, "plan", {}, function () return work.install(surface, opts) end)
end

-- A reading tool's answer, from `from` (a character, 1 by default), cut at the limit with a
-- line that says where the rest begins.
local function page(s, from)
  local limit = require("history").CUT
  from = math.max(1, math.floor(tonumber(from) or 1))
  local rest = s:sub(from)
  if #rest <= limit then return rest end
  return rest:sub(1, limit) .. string.format("\n... %d more characters; ask again with from = %d for the rest.",
    #rest - limit, from + limit)
end

--- The three tools that read the history (docs/spec/history.md, "How an agent looks back"),
--- as name to definition, in order. None writes: each body reads `c.history`, the view the
--- run hands tools, never the port. The talker takes `history` alone (src/speech.lua).
function kits.history_tools()
  local T = spec.types
  local none = "this world keeps no history"
  local function view(c)
    local h = c.history
    if type(h) ~= "table" or type(h.find) ~= "function" then return nil end
    return h
  end
  local defs = {}
  defs.history = {
    effect = "recalls",
    about = "Find past runs kept in this workspace, best first. Each line is an entry's id, its cause, how it "
         .. "stopped, the first line of what it was asked, and which of your fields it matched. "
         .. "Every field is optional and they combine; with none, the latest runs come first.",
    args = {
      day   = T.string_opt("a day, as YYYY-MM-DD, only one the person named: you do not know today's "
                        .. "date, and the answer begins with it; nearer days rank higher"),
      since = T.string_opt("only runs on or after this day, as YYYY-MM-DD; the same care as day"),
      hour  = T.number_opt("an hour of the day, 0 to 23; nearer hours rank higher"),
      agent = T.string_opt("the agent that ran, as it is named in an id"),
      cause = T.string_opt("what started the run: cli, talk, job, beat, edit or run"),
      stop  = T.string_opt("how the run ended, as a result's stop reason, such as answered"),
      tool  = T.string_opt("a tool the run called"),
      file  = T.string_opt("a workspace path the run read or wrote"),
      wrote = T.string_opt("a workspace path the run wrote"),
      like  = T.string_opt("an entry's id: find the runs whose circumstances are most like it"),
      limit = T.number_opt("how many lines at most; 10 by default"),
    },
    run = function (c)
      local h = view(c)
      if not h then return none end
      local q = {}
      for k, v in pairs(c.args or {}) do q[k] = v end
      local found, why = h.find(q)
      if not found then return why end
      if #found == 0 then
        local any = h.find({ limit = 1 })
        return (any and #any > 0) and "no kept run matches that" or "no runs are kept yet"
      end
      local out = {}
      -- A model does not know the date; the ids are read against it.
      local ok, now = pcall(function () return c.clock and c.clock.now and c.clock.now() end)
      if ok and type(now) == "number" and h.today then out[1] = "It is now " .. h.today(now) .. "." end
      for _, r in ipairs(found) do out[#out + 1] = h.line(r) end
      return page(table.concat(out, "\n"))
    end,
  }
  defs.recall = {
    effect = "recalls",
    about = "The story of one past run: what it was given, what it was asked, and what was so after, "
         .. "as a Gherkin scenario tagged with its id.",
    args = {
      id   = T.string("the entry's id, or a leading part of it that names only one"),
      from = T.number_opt("the character to start from, for a story longer than one answer"),
    },
    run = function (c)
      local h = view(c)
      if not h then return none end
      local args = c.args or {}
      local story, why = h.recall(args.id)
      if not story then return why end
      return page(story, args.from)
    end,
  }
  defs.evidence = {
    effect = "recalls",
    about = "One part of a past run's evidence. part is calls (the list), call (which = its number), "
         .. "transcript, errors, commands, files, diff (which = a path: the file before and after), "
         .. "kept (which = the number after # in a story), or model.",
    args = {
      id    = T.string("the entry's id, or a leading part of it that names only one"),
      part  = T.string_opt("which part; calls by default"),
      which = T.string_opt("for call and kept, a number; for diff, a workspace path"),
      from  = T.number_opt("the character to start from, for a part longer than one answer"),
    },
    run = function (c)
      local h = view(c)
      if not h then return none end
      local args = c.args or {}
      local text, why = h.evidence(args.id, args.part, args.which, true)
      if not text then return why end
      return page(text, args.from)
    end,
  }
  return defs, { "history", "recall", "evidence" }
end

--- The three history tools, declared through `surface`.
function kits.history(surface, a)
  local function install()
    local defs, order = kits.history_tools()
    for _, name in ipairs(order) do surface.tool(name)(defs[name]) end
  end
  if a == nil then return install() end
  return record(a, "history", {}, install)
end

--- A tool that runs another declared agent.
function kits.delegate(a, name, cfg)
  return spec.add_tool(a, name, subagent.tool(cfg))
end

return kits
