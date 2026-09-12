-- authoring -- the tools an agent uses to change itself and to build other agents, over
-- the feature files in one folder.
--
-- `it edits agents in "agents"` gives an agent six tools, and the wall is in their shape:
--
--   features    list the feature files                                    reads
--   feature     read one, with line numbers                               reads
--   vocabulary  every line it may write, by phase, and a file's shorthands reads
--   verify      run one file's scenarios on the doubles                   reads
--   edit        one edit that widens nothing                              scored
--   propose     one edit that widens reach, or a new agent                ASKS the person
--
-- `propose` is an ordinary tool with `ask = true`, so a widening edit meets the harness's
-- own gate before its body runs (rule 4), and a refusal is a result the model reads. An
-- edit that crosses the wall -- an `asks first` taken away, an authored scenario touched --
-- is refused by `declare.edit` whichever tool carries it.
--
-- Every edit is scored before it is written: the file must still load, and its AUTHORED
-- scenarios must pass at least as well as before on the doubles. A proposed scenario is not
-- scored, because an agent that writes both the code and the test will make them agree.
--
-- The tools reach files only through `c.fs`, the world's filesystem port. Contract:
-- spec/declare.md, "The authoring tools".

local spec      = require "spec"
local turn      = require "turn"
local store     = require "store"
local cli       = require "cli"
local gherkin   = require "gherkin"
local behaviour = require "behaviour"
local declare   = require "declare"

local authoring = {}

local function q(s) return string.format("%q", tostring(s)) end
local function trim(s) return (tostring(s):gsub("^%s+", ""):gsub("%s+$", "")) end

-- ------------------------------------------------------------------ paths

local function join(dir, path)
  if dir == nil or dir == "" then return path end
  if path == "" then return dir end
  return dir .. "/" .. path
end

local function dir_of(path) return path:match("^(.*)/[^/]*$") or "" end

-- A path under the folder, or nil and why. Relative, no `..`, a .feature, not locked.
local function resolve(folder, path, locked)
  if type(path) ~= "string" or path == "" then return nil, "a path is a feature file under " .. q(folder) end
  -- Coerced at the edge: a path given with the folder's own name in front, as a person
  -- would say it ("agents/notes.feature"), means the same file.
  path = path:gsub("^%./", "")
  if folder ~= "" and path:sub(1, #folder + 1) == folder .. "/" then path = path:sub(#folder + 2) end
  if path:sub(1, 1) == "/" or path:match("^%a:") then return nil, "a path is relative to " .. q(folder) end
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then return nil, "a path may not leave " .. q(folder) end
  end
  if not path:match("%.feature$") then return nil, "these tools edit feature files, and " .. q(path) .. " is not one" end
  if path:match("^features/kept%.feature$") or path:match("/features/kept%.feature$") then
    return nil, q(path) .. " is what a person kept while playing, and it is theirs"
  end
  for _, l in ipairs(locked or {}) do
    if l == path then return nil, q(path) .. " is locked" end
  end
  return join(folder, path)
end

local function walk(fs, folder, rel, out, depth)
  if depth > 6 then return end
  local entries = fs.list(join(folder, rel))
  if type(entries) ~= "table" then return end
  for _, e in ipairs(entries) do
    local path = rel == "" and e.name or (rel .. "/" .. e.name)
    if e.kind == "dir" then walk(fs, folder, path, out, depth + 1)
    elseif e.name:match("%.feature$") then out[#out + 1] = path end
  end
end

local function numbered(text)
  local out, n = {}, 0
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    out[#out + 1] = string.format("%4d  %s", n, l)
  end
  if out[#out] == string.format("%4d  ", n) then out[#out] = nil end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------------ loading and scoring

local function load(text, fs, dir)
  local decl = spec.new()
  local info, why = declare.apply(text, decl, {
    read = function (p) return fs.read(join(dir, p)) end,
  })
  if not info then return nil, why end
  return decl, info
end

-- The authored scenarios of a file, run on the doubles: counts, and the first that did
-- not pass. A file that says what no agent is has nothing to score.
local function score(text, fs, dir)
  local decl, why = load(text, fs, dir)
  if not decl then return nil, why end
  local pickles, bad = declare.pickles(text, decl)
  if not pickles then return nil, bad end
  local authored, proposed = {}, 0
  for _, p in ipairs(pickles) do
    if declare.authored(p.tags) then authored[#authored + 1] = p else proposed = proposed + 1 end
  end
  local out = { passed = 0, failed = 0, broken = 0, undefined = 0, total = #authored, proposed = proposed }
  if #authored == 0 then return out end
  local drivers = cli.drivers(decl, function (prompt, port, ropts)
    local bound = store.bind(decl, port)
    local depth = declare.enter(bound)
    local ok, result = pcall(turn.run, decl, prompt, bound,
                             { budget = ropts and ropts.budget, id = decl.name })
    declare.leave(depth)
    if not ok then error(result, 0) end
    return result
  end)
  local report = behaviour.run(authored, drivers, { eval = false })
  out.passed, out.failed, out.broken, out.undefined = report.passed, report.failed, report.broken, report.undefined
  for _, sc in ipairs(report.scenarios) do
    if sc.outcome ~= "passed" and not out.first then
      out.first = sc.name
      for _, st in ipairs(sc.steps) do
        if st.why then out.first_why = st.why; break end
      end
    end
  end
  out.report = report
  return out
end

--- Every scenario of a feature file run on the doubles, one entry each: `name`, `outcome`
--- (passed, failed, broken, undefined), `why` (the first step's reason when it did not
--- pass) and `authored` (false for a @proposed scenario, which is never scored). A file
--- that says what no agent is answers nil and why. This is what a host shows beside each
--- scenario of an agent's file (docs/spec/agent-file.md).
function authoring.verify(text, fs, dir)
  local decl, why = load(text, fs, dir)
  if not decl then return nil, why end
  local pickles, bad = declare.pickles(text, decl)
  if not pickles then return nil, bad end
  if #pickles == 0 then return {} end
  local drivers = cli.drivers(decl, function (prompt, port, ropts)
    local bound = store.bind(decl, port)
    local depth = declare.enter(bound)
    local ok, result = pcall(turn.run, decl, prompt, bound, { budget = ropts and ropts.budget, id = decl.name })
    declare.leave(depth)
    if not ok then error(result, 0) end
    return result
  end)
  local report = behaviour.run(pickles, drivers, { eval = false })
  local out = {}
  for i, sc in ipairs(report.scenarios) do
    local e = { name = sc.name, outcome = sc.outcome, authored = declare.authored(pickles[i] and pickles[i].tags or {}) }
    for _, st in ipairs(sc.steps or {}) do
      if st.why then e.why = st.why; break end
    end
    out[i] = e
  end
  return out
end

local function worse(before, after)
  if not before then return nil end
  if after.failed + after.broken > before.failed + before.broken
     or after.undefined > before.undefined or after.passed < before.passed then
    return string.format("it would leave %d of %d authored scenario(s) passing, where %d passed: %s%s",
      after.passed, after.total, before.passed, q(after.first or "?"),
      after.first_why and (" -- " .. after.first_why) or "")
  end
  return nil
end

-- A new file's scenarios are proposed until a person accepts them: every scenario that does
-- not say otherwise gets the tag.
local function propose_all(text)
  local doc = gherkin.document(text)
  if not doc then return text end
  local lines = {}
  for l in (text .. "\n"):gmatch("([^\n]*)\n") do lines[#lines + 1] = l end
  local marks = {}
  local function visit(b)
    if b.kind ~= "background" and declare.authored(b.tags) then marks[#marks + 1] = b.line end
  end
  for _, b in ipairs(doc.scenarios) do visit(b) end
  for _, r in ipairs(doc.rules) do for _, b in ipairs(r.scenarios) do visit(b) end end
  table.sort(marks, function (a, b) return a > b end)
  for _, line in ipairs(marks) do
    local indent = lines[line]:match("^(%s*)")
    table.insert(lines, line, indent .. "@proposed")
  end
  return table.concat(lines, "\n")
end

-- The least a new agent's file holds, shown when a new file says nothing about what it is.
local SKELETON = [==[
Feature: notes
  Keeps notes.

  Background:
    Given the agent is called notes
    And its model is "openrouter:z-ai/glm-5.3"
    And its reasoning is low
    And it has a tool note for "Keep one note.", which takes:
      | argument | type   | about    |
      | text     | string | the note |
    And the tool note answers "kept"

  Scenario: it keeps a note
    Given the model calls note with {"text": "milk"}
    And the model answers "noted"
    When the agent is asked "note milk"
    Then the call to note answers "kept"
]==]

-- What `--check` would say of a file, as a tail for a tool's answer: the lines no expression
-- reads, and the rest, so the next edit can fix them. Five at most.
local function problems_of(text, fs, dir)
  local decl = load(text, fs, dir)
  if not decl then return "" end
  local pickles = declare.pickles(text, decl)
  if not pickles then return "" end
  local found = behaviour.check(pickles, cli.drivers(decl, function () end))
  if #found == 0 then return "" end
  local out = { string.format("\n%d problem(s) --check finds:", #found) }
  for i = 1, math.min(#found, 5) do
    out[#out + 1] = "  " .. (found[i]:gsub("\n.*", ""))
  end
  return table.concat(out, "\n")
end

-- A line as a model sends it, made the line it meant: the number and gap the `feature` view
-- puts in front, and a Gherkin keyword, are not part of an is line.
local KEYWORDS = { "Given ", "When ", "Then ", "And ", "But ", "* " }
local function a_line(text)
  if type(text) ~= "string" then return text end
  local t = trim(text):gsub("^%d+%s%s+", "")
  t = trim(t)
  for _, k in ipairs(KEYWORDS) do
    if t:sub(1, #k) == k then t = trim(t:sub(#k + 1)); break end
  end
  return t
end

-- Text an agent wrote, with the keyword put back on a line that an expression reads and that
-- the writer left bare -- the vocabulary lists lines without one, and a bare line reads as
-- description, which then leaves its table or doc string belonging to nothing. Only a line
-- inside a Background or a scenario, only one an expression reads, and never inside a doc
-- string: anything else is left as written for the reader to refuse.
local BLOCK_HEADS = { "Feature:", "Background:", "Rule:", "Scenario:", "Scenario Outline:", "Scenario Template:",
                      "Example:", "Examples:", "Scenarios:" }
local FIRST = { is = "Given ", given = "Given ", when = "When ", ["then"] = "Then " }
local function keyworded(text)
  if type(text) ~= "string" then return text end
  local out, in_block, in_doc, fence, last = {}, false, false, nil, nil
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw               -- a loop's own variable is constant in Lua 5.5
    local t = trim(line)
    if in_doc then
      if t == fence then in_doc = false end
    elseif t:sub(1, 3) == '"""' or t:sub(1, 3) == "```" then
      in_doc, fence = true, t:sub(1, 3)
    else
      local head = false
      for _, h in ipairs(BLOCK_HEADS) do
        if t:sub(1, #h) == h then head = true; in_block = h ~= "Feature:" and h ~= "Rule:"; last = nil end
      end
      local keyword = false
      for _, k in ipairs(KEYWORDS) do if t:sub(1, #k) == k then keyword = true end end
      if keyword then
        last = declare.phase_of(a_line(t)) or last
      elseif not head and in_block and t ~= "" and not t:match("^[|@#]") then
        local phase = declare.phase_of(t)
        if phase then
          local k = (last and (last == phase or (last == "is" and phase == "given"))) and "And " or FIRST[phase]
          line = line:match("^(%s*)") .. k .. t
          last = phase
        end
      end
    end
    out[#out + 1] = line
  end
  if out[#out] == "" and text:sub(-1) ~= "\n" then out[#out] = nil end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------------ the one edit

local OPS = { "add", "remove", "replace", "scenario", "shorthand", "withdraw", "create" }

local function op_of(args)
  local kind = args.op
  if (kind == "add" or kind == "replace") and args.line == nil and type(args.text) == "string" then
    args.line = args.text
  end
  args.line, args.with = a_line(args.line), a_line(args.with)
  if kind == "withdraw" and type(args.line) == "string" then
    args.line = trim(args.line:gsub("^Scenario:%s*", ""):gsub("^Example:%s*", ""))
  end
  if kind == "add" or kind == "remove" or kind == "replace" or kind == "withdraw" then
    if type(args.line) ~= "string" then return nil, "this edit names the line, as `line`" end
  end
  if kind == "scenario" or kind == "shorthand" or kind == "create" then
    if type(args.text) ~= "string" then return nil, "this edit gives the text, as `text`" end
  end
  if kind == "add" and type(args.with) == "string" then
    return nil, "add takes one line and puts it in; to change " .. q(args.line) .. " into " .. q(args.with) .. ", the op is replace"
  end
  if kind == "add" then return { add = args.line, doc = args.doc, rows = args.rows } end
  if kind == "remove" then return { remove = args.line } end
  if kind == "replace" then return { replace = args.line, with = args.with, doc = args.doc, rows = args.rows } end
  if kind == "scenario" then return { scenario = keyworded(args.text) } end
  if kind == "shorthand" then return { shorthand = keyworded(args.text) } end
  if kind == "withdraw" then return { withdraw = args.line } end
  return nil, "the op is one of " .. table.concat(OPS, ", ")
end

local function apply(folder, locked, c, gated)
  local args = c.args
  local full, why = resolve(folder, args.path, locked)
  if not full then return false, "not applied: " .. why end
  local fs = c.fs
  local dir = dir_of(full)

  if args.op == "create" then
    if fs.exists(full) then return false, "not applied: " .. q(args.path) .. " exists; edit it instead" end
    if not gated then
      return false, "not applied: a new agent widens what exists. Make it with propose, which asks the person first."
    end
    local text = propose_all(keyworded(args.text))
    local doc, bad = gherkin.document(text)
    if not doc then return false, "not applied: the file does not read: " .. bad end
    if not declare.declares(text) then
      return false, "not applied: a new agent says what it is, in its Background, and this file does not. "
        .. "The least there is:\n\n" .. SKELETON .. "\nCall vocabulary for every line."
    end
    local ok, bad2 = load(text, fs, dir)
    if not ok then return false, "not applied: the new agent does not load:\n" .. bad2 end
    local cannot = spec.problems(ok)
    if #cannot > 0 then
      return false, "not applied: the new agent could not run: " .. table.concat(cannot, "; ")
        .. ". The least there is:\n\n" .. SKELETON
    end
    local wrote, werr = fs.write(full, text)
    if not wrote then return nil, "could not write " .. args.path .. ": " .. tostring(werr) end
    c.note("created " .. args.path)
    return "applied: created " .. args.path .. ". Its scenarios are @proposed until a person accepts them."
      .. problems_of(text, fs, dir)
  end

  local op, bad = op_of(args)
  if not op then return false, "not applied: " .. bad end
  local text, rerr = fs.read(full)
  if not text then return false, "not applied: cannot read " .. args.path .. ": " .. tostring(rerr) end
  local new, change, wall = declare.edit(text, op)
  if not new then return false, (wall and "" or "not applied: ") .. change end
  if change.reach == "widens" and not gated then
    return false, "not applied: this " .. change.why .. ", which widens what the agent can reach. "
      .. "Make it with propose, which asks the person first."
  end
  if declare.declares(new) or declare.declares(text) then
    local ok, bad2 = load(new, fs, dir)
    if not ok then return false, "not applied: the agent would not load: " .. bad2 end
  end
  local before = declare.declares(text) and score(text, fs, dir) or nil
  local after = declare.declares(new) and score(new, fs, dir) or nil
  local lost = before and after and worse(before, after)
  if lost then return false, "not applied: " .. lost end
  local wrote, werr = fs.write(full, new)
  if not wrote then return nil, "could not write " .. args.path .. ": " .. tostring(werr) end
  c.note(string.format("%s %s: %s", args.path, change.reach, change.why))
  local tail = ""
  if after and after.total > 0 then
    tail = string.format(" %d of %d authored scenario(s) pass.", after.passed, after.total)
  end
  local said = change.reach == "neither" and "" or (" It " .. change.reach .. " what the agent can reach.")
  return "applied: " .. change.why .. "." .. said .. tail .. problems_of(new, fs, dir)
end

-- ------------------------------------------------------------------ the tools

local VOCAB_HEADS = {
  { "is", "what the agent is: lines of the Background" },
  { "given", "the world a scenario starts from" },
  { "when", "the one way the scenario's run starts" },
  { "then", "what must hold of the result" },
}

local VOCAB_PHASES = { is = true, given = true, when = true, ["then"] = true }

local function vocabulary_text(shorthands, phase)
  local out = {}
  local by = { is = declare.vocabulary() }
  for _, st in ipairs(behaviour.steps()) do
    by[st.phase] = by[st.phase] or {}
    local list = by[st.phase]
    list[#list + 1] = st
  end
  for _, h in ipairs(VOCAB_HEADS) do
    -- one phase on request: a model choosing an is line reads half of the whole
    -- (docs/confidence-plan.md, item 4)
    if phase and h[1] ~= phase then goto skip end
    out[#out + 1] = h[1] .. " -- " .. h[2]
    for _, st in ipairs(by[h[1]] or {}) do
      local tag = st.reach and st.reach ~= "neither" and ("  [" .. st.reach .. (st.gate and ", a gate" or "") .. "]") or ""
      out[#out + 1] = string.format("  %-62s %s%s", st.expr, st.about or "", tag)
    end
    ::skip::
  end
  if shorthands and #shorthands > 0 then
    out[#out + 1] = "shorthands -- this file's own"
    for _, sh in ipairs(shorthands) do
      out[#out + 1] = string.format("  %-62s (%s)", sh.expr.text, sh.phase or "?")
    end
  end
  out[#out + 1] = ""
  out[#out + 1] = "Every line of a Background or a scenario starts with Given, When, Then, And or *. "
    .. "{word} is a name, bare; {string} is text, in quotes. An argument table has the header "
    .. "| argument | type | about |; a type is string, number, boolean, table or list, or one of a, b, "
    .. "each optionally preceded by `optional`. A shorthand is a scenario tagged @shorthand whose name is "
    .. "the new line, with <name> for a word and \"<name>\" for a string."
  return table.concat(out, "\n")
end

local EDIT_ARGS = function (s)
  return {
    path = s.string "the feature file, under the folder",
    op   = s.one_of "which edit" (OPS),
    line = s.string_opt "the is line to add, remove or replace; for withdraw, the scenario's name",
    with = s.string_opt "for replace: the line that goes in",
    doc  = s.string_opt "a doc string the line takes: a briefing, or a body in Lua",
    rows = s.list_opt "a table the line takes, as a list of rows, the header first",
    text = s.string_opt "for scenario, shorthand or create: the whole scenario, shorthand or file",
  }
end

--- Declare the six tools on the agent table `a`, through `s` (a surface). `opts.folder` is
--- the folder under the workspace; `opts.locked` lists paths no edit may touch.
function authoring.install(a, s, opts)
  opts = opts or {}
  local folder = trim(opts.folder or ""):gsub("/+$", "")
  if folder:sub(1, 1) == "/" or folder:find("..", 1, true) then
    error("agent: the authoring folder is a path under the workspace, and " .. q(folder) .. " is not", 2)
  end
  local locked = opts.locked

  local before = {}
  for i = 1, #a.order do before[a.order[i]] = true end
  local function recorded()
    local tools = {}
    for i = 1, #a.order do
      local t = a.order[i]
      if not before[t] then tools[t] = { about = a.tools[t].about, ask = a.tools[t].ask } end
    end
    a.kits = a.kits or {}
    a.kits.authoring = { folder = folder, tools = tools }
  end

  s.tool "features" {
    about = "List the feature files under " .. (folder == "" and "the workspace" or q(folder))
      .. ". Each is one agent: what it is in its Background, what it does in its scenarios.",
    run = function (c)
      local out = {}
      walk(c.fs, folder, "", out, 1)
      table.sort(out)
      if #out == 0 then return "no feature files under " .. (folder == "" and "the workspace" or folder) end
      return table.concat(out, "\n")
    end,
  }

  s.tool "feature" {
    about = "Read one feature file, with line numbers.",
    args = { path = s.string "the feature file, under the folder" },
    run = function (c)
      local full, why = resolve(folder, c.args.path, nil)
      if not full then return nil, why end
      local text, err = c.fs.read(full)
      if not text then return nil, err end
      return numbered(text)
    end,
  }

  s.tool "vocabulary" {
    about = "Every line a feature file may hold, by phase, and which way each is line moves what the "
      .. "agent can reach. With a path, that file's shorthands too. With a phase (is, given, when, "
      .. "then), only that phase's lines.",
    args = { path = s.string_opt "a feature file whose shorthands to list",
             phase = s.string_opt "one of is, given, when, then: list only that phase" },
    run = function (c)
      local shorthands = nil
      local phase = c.args.phase
      if phase ~= nil and not VOCAB_PHASES[phase] then
        return nil, "phase is one of is, given, when, then; not " .. tostring(phase)
      end
      if c.args.path then
        local full, why = resolve(folder, c.args.path, nil)
        if not full then return nil, why end
        local text = c.fs.read(full)
        if text then
          local decl = load(text, c.fs, dir_of(full)) or spec.new()
          local _, list = declare.pickles(text, decl)
          shorthands = list
        end
      end
      return vocabulary_text(shorthands, phase)
    end,
  }

  s.tool "verify" {
    about = "Run one feature file's scenarios on the doubles and report each. Authored scenarios are the "
      .. "score; @proposed ones are yours and are reported apart.",
    args = { path = s.string "the feature file, under the folder" },
    run = function (c)
      local full, why = resolve(folder, c.args.path, nil)
      if not full then return nil, why end
      local text, err = c.fs.read(full)
      if not text then return nil, err end
      local decl, bad = load(text, c.fs, dir_of(full))
      if not decl then return nil, bad end
      local pickles, bad2 = declare.pickles(text, decl)
      if not pickles then return nil, bad2 end
      local sc = score(text, c.fs, dir_of(full))
      local drivers = cli.drivers(decl, function (prompt, port, ropts)
        local bound = store.bind(decl, port)
        local depth = declare.enter(bound)
        local ok, result = pcall(turn.run, decl, prompt, bound, { budget = ropts and ropts.budget, id = decl.name })
        declare.leave(depth)
        if not ok then error(result, 0) end
        return result
      end)
      local report = behaviour.run(pickles, drivers, { eval = false })
      return behaviour.report(report) .. string.format("authored: %d of %d passed; proposed: %d",
        sc and sc.passed or 0, sc and sc.total or 0, sc and sc.proposed or 0)
    end,
  }

  s.tool "edit" {
    about = "Make one edit to a feature file that widens nothing: a briefing, a budget, a tool's `for`, a "
      .. "gate added, a line that narrows, a shorthand, a proposed scenario. It is written only if the "
      .. "file still loads and its authored scenarios pass at least as well. `line` is an is line's text, "
      .. "as `vocabulary` lists it, with no keyword: {\"path\": \"greeter.feature\", \"op\": \"add\", "
      .. "\"line\": \"the tool greet asks first\"}.",
    args = EDIT_ARGS(s),
    run = function (c) return apply(folder, locked, c, false) end,
  }

  s.tool "propose" {
    about = "Make one edit that widens what an agent can reach -- a tool, a body, commands, a delegate, a "
      .. "server, a beat, the model -- or create a new agent (op create, the whole file as `text`, what "
      .. "it is in its Background). The person is asked first.",
    -- a widening is the person's to approve whatever the trust: under `trusted` the gate
    -- answered for them (evals/wall-trusted.feature, 2026-09-12; spec/declare.md)
    ask = "always",
    args = EDIT_ARGS(s),
    run = function (c) return apply(folder, locked, c, true) end,
  }
  recorded()
end

return authoring
