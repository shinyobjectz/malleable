-- skills -- a procedure the WORKSPACE holds, and the agent may read but not rewrite.
--
-- Distinct from `agent.plan` (this run's list, authored by the agent, dies with the run)
-- and from a tool (a body in this process): a person wrote a skill, it outlives every run.
--
-- Two rules shape the surface:
--
--   1. PROGRESSIVE DISCLOSURE. The briefing carries a name and one sentence per skill;
--      the body arrives only when the model asks for it.
--   2. THE WORLD SUPPLIES THE BODIES. A skill declared in Lua carries its own text; a
--      skill the workspace holds arrives through the `skills` port, which owes
--
--          list() -> { { name = ..., about = ... }, ... } | nil, err
--          read(name) -> text | nil, err
--
--      A host wires the port to the filesystem; a test wires it to a table (rule 1).
--
-- A declared skill and a port skill sharing a name is neither merged nor shadowed: it is
-- reported.

local spec = require "spec"

local skills = {}

local function fail(fmt, ...)
  error("agent: " .. string.format(fmt, ...), 3)
end

local function port_of(where)
  local p = where and (where.skills or (where.port and where.port.skills))
  if type(p) == "table" and type(p.list) == "function" and type(p.read) == "function" then
    return p
  end
  return nil
end

-- Every skill this agent can reach, declared first and in declaration order, then
-- whatever the world lists, alphabetically. Never raises: a world that cannot answer
-- costs the port's skills, not the run.
function skills.catalogue(a, where)
  local out, seen, clashes = {}, {}, {}
  for i = 1, #a.skill_order do
    local s = a.skills[a.skill_order[i]]
    seen[s.name] = true
    out[#out + 1] = { name = s.name, about = s.about, from = "declared" }
  end
  local p = port_of(where)
  if p then
    local listed = p.list()
    if type(listed) == "table" then
      local rows = {}
      for i = 1, #listed do
        local e = listed[i]
        if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
          rows[#rows + 1] = { name = e.name, about = type(e.about) == "string" and e.about or "", from = "workspace" }
        elseif type(e) == "string" then
          rows[#rows + 1] = { name = e, about = "", from = "workspace" }
        end
      end
      table.sort(rows, function (x, y) return x.name < y.name end)
      for i = 1, #rows do
        if seen[rows[i].name] then
          clashes[#clashes + 1] = rows[i].name
        else
          seen[rows[i].name] = true
          out[#out + 1] = rows[i]
        end
      end
    end
  end
  return out, clashes
end

-- The body, as text. `nil, sentence` when there is no such skill or the world could not
-- produce it -- a sentence rather than an error value, because this is what the model
-- reads next and a model cannot act on a code.
function skills.body(a, where, name)
  if type(name) ~= "string" or name == "" then
    return nil, "a skill is asked for by name."
  end
  local s = a.skills[name]
  if s then
    if s.does then return s.does end
    local fs = where and (where.fs or (where.port and where.port.fs))
    if type(fs) ~= "table" or type(fs.read) ~= "function" then
      return nil, ("the skill %q lives in the file %q, and this run has no filesystem to read it with."):format(name, s.file)
    end
    local text, err = fs.read(s.file)
    if text == nil then
      return nil, ("the skill %q lives in the file %q, which did not read: %s."):format(
        name, s.file, type(err) == "table" and (err.message or err.code) or tostring(err))
    end
    return text
  end
  local p = port_of(where)
  if p then
    local text, err = p.read(name)
    if type(text) == "string" then return text end
    -- `not_found` falls through to the list below. A world that says "no such skill"
    -- and a world that says nothing are the same answer to the model, and the useful
    -- reply to both is the names it could have asked for.
    local code = type(err) == "table" and err.code or nil
    if err ~= nil and code ~= "not_found" then
      return nil, ("the skill %q did not read: %s."):format(
        name, type(err) == "table" and (err.message or err.code) or tostring(err))
    end
  end
  -- The list, not a guess. A near miss offered as a correction is a skill the model
  -- runs believing it asked for it.
  local have = skills.catalogue(a, where)
  if #have == 0 then return nil, ("there is no skill %q, and no skills are loaded."):format(name) end
  local names = {}
  for i = 1, #have do names[i] = have[i].name end
  return nil, ("there is no skill %q. The skills are: %s."):format(name, table.concat(names, ", "))
end

-- The paragraph that goes to the model, or nil when there is nothing to say. One line
-- per skill, and the line is the sentence its author wrote -- this module never
-- summarises a skill, because a summary of a procedure is a different procedure.
function skills.briefing(a, where, opts)
  local have, clashes = skills.catalogue(a, where)
  if #have == 0 then return nil, clashes end
  -- The name the tool was actually installed under. A briefing that names `skill` while
  -- the run holds `procedure` sends the model to a tool that is not there.
  local tool = (opts and opts.tool) or a.skill_tool or "skill"
  local lines = {
    "Skills are procedures this workspace keeps. Read one with the " .. tool
    .. " tool before doing work it covers, and follow it as written:",
  }
  for i = 1, #have do
    lines[#lines + 1] = "  " .. have[i].name .. " -- " .. (have[i].about ~= "" and have[i].about or "no description")
  end
  return table.concat(lines, "\n"), clashes
end

-- Install the one tool. Curried through the same surface a hand-written tool uses, so
-- a skill tool and any other tool are the same kind of thing by the time the model
-- reads the schema.
--
-- The tool answers with the body verbatim: it does not paraphrase, act on or remember it.
-- The next step is the model's, holding the words a person wrote.
function skills.install(surface, opts)
  opts = opts or {}
  if type(surface) ~= "table" or type(surface.tool) ~= "function" or type(surface.spec) ~= "function" then
    fail("agent.skills installs onto the prefix, and needs its `tool` and `spec`")
  end
  local a = surface.spec()
  local name = opts.name or "skill"
  a.skill_tool = name
  local t = surface.tool(name) {
    about = opts.about or "Read a skill: a procedure this workspace keeps, in the words of the person who wrote it.",
    args  = { name = spec.types.string("the name of the skill, as the briefing lists it") },
    run   = function (c)
      local text, why = skills.body(a, c, c.args.name)
      if text == nil then return why end
      return text
    end,
  }
  return t
end

-- The system message this run should be given: the declaration's, with the briefing
-- under it. `nil` when there is nothing to add, so a caller passes it straight through
-- and an agent with no skills is a run with exactly the system message it declared.
--
-- It is composed HERE and handed to `turn.run` as `opts.system`, rather than turn
-- reaching for this module: the core depends on the declaration surface and on nothing
-- else, which is rule 1, and a subsystem that makes the core depend on it has broken
-- the shape of the tree to save one line at the call site.
function skills.system(a, where, opts)
  local brief, clashes = skills.briefing(a, where, opts)
  if not brief then return nil, clashes end
  local system = type(a.system) == "string" and a.system or nil
  return system and (system .. "\n\n" .. brief) or brief, clashes
end

-- Install the tool if the agent has skills to read and nothing to read them with.
--
-- Called at RUN time, next to `mcp.connect`: a declaration that states a skill and never
-- installs the tool briefs the model on procedures it cannot open. A declaration that
-- installed the tool itself, under any name, is left alone.
--
-- Returns the tool it added, or nil when there was nothing to do.
function skills.ensure(surface, p, opts)
  opts = opts or {}
  local a = type(surface) == "table" and type(surface.spec) == "function" and surface.spec() or surface
  if type(a) ~= "table" or type(a.skill_order) ~= "table" then return nil end
  if a.skill_tool then return nil end
  local reachable = #a.skill_order > 0 or port_of(p) ~= nil
  if not reachable then return nil end
  local name = opts.name or "skill"
  if a.tools[name] then a.skill_tool = name return nil end
  local install = surface
  if type(surface) ~= "table" or type(surface.tool) ~= "function" then
    -- A bare declaration table, which is what the runner holds. The smallest surface
    -- `skills.install` needs, rather than requiring the whole prefix here.
    install = { tool = function (n) return function (d) return spec.add_tool(a, n, d) end end,
                spec = function () return a end }
  end
  local t = skills.install(install, opts)
  a.skill_tool = name
  return t
end

return skills
