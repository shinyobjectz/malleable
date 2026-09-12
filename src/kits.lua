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
  return tools_fs.install(shim, opts)
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
  return spec.add_tool(a, name, decl)
end

--- The two plan tools, plan and mark, over one live plan.
function kits.plan(opts, surface)
  return work.install(surface, opts)
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
function kits.history(surface)
  local defs, order = kits.history_tools()
  for _, name in ipairs(order) do surface.tool(name)(defs[name]) end
end

--- A tool that runs another declared agent.
function kits.delegate(a, name, cfg)
  return spec.add_tool(a, name, subagent.tool(cfg))
end

return kits
