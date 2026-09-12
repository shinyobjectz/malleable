-- The tree vocabulary: what a spec can say about the harness itself.
--
-- `spec/*.feature` states what this tree PROMISES, in scenarios that run. Most promises
-- are behavioural and the built-in vocabulary already says them -- `it calls read`, `it
-- stops with answered`, `the call to file is refused`. Some are STRUCTURAL and it cannot:
-- "src/shell.lua names no io", "trace.lua requires nothing", "the same script twice is
-- byte-identical". Those are facts about the source, not about a run.
--
-- They do not belong in the built-in vocabulary: rule 7 keeps the reader from knowing a
-- harness exists, and the built-in expressions are about an AGENT's behaviour. So this is a
-- second, small vocabulary, declared through the same `agent.step` door any workspace has
-- and run by the same runner -- so an unbuilt promise reads as UNDEFINED and prints its own
-- skeleton.
--
-- A promise in prose is a bullet nobody checks; a promise here is passed, failed or
-- undefined, and the last two are the difference between a spec that LIES and one that is
-- AHEAD OF THE CODE.
--
-- This file reads real files, so it names `io`. That is why it is here and not in `src/`:
-- nothing under `src/` may, and the rule test that says so reads those files.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
local root = here .. "/../.."     -- docs/spec/ is two down from the tree

package.path = root .. "/?.lua;" .. root .. "/src/?.lua;" .. package.path

local agent   = require "agent"
local shell   = require "shell"
local command = require "command"
local double  = require "double"
local behaviour = require "behaviour"
local gherkin = require "gherkin"
local trace   = require "trace"
local change  = require "change"
local observe = require "observe"

local tree = {}

-- reading the tree

local function slurp(path)
  local f = io.open(root .. "/" .. path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

-- Source with the comments taken out: a file may SAY "require" while explaining why it
-- does not call one, and a check that cannot tell those apart penalises explanation.
local function code_of(path)
  local text = slurp(path)
  if text == nil then return nil end
  return (text:gsub("%-%-%[%[.-%]%]", " "):gsub("%-%-[^\n]*", " "))
end

local function no(fmt, ...) return false, string.format(fmt, ...) end

-- A doc string and a stream of bytes, compared.
--
-- A doc string has no trailing newline; a command's output almost always has one. ONE
-- trailing newline is allowed on the output side and no other difference: `"a\n"` matches
-- the doc `a`, `"a\n\n"` does not, nor does `"a"` match `a\n`. Stated rather than trimmed,
-- so "wrote nothing" stays distinguishable from "wrote a blank line".
local function same_text(out, doc)
  doc = doc or ""
  return out == doc or out == (doc .. "\n")
end

-- A filesystem to run a command against, built from the one the scenario stated.
--
-- A Then line is handed a FROZEN world (rule 6), so the port's own functions raise if
-- called. What comes through readable is `fs.files`, the plain path-to-text map; a fresh
-- filesystem is built from that, and the commands really run somewhere the scenario cannot
-- see.
local function staged(c)
  local files = {}
  local held = c.world and c.world.fs and c.world.fs.files
  if type(held) == "table" then
    for path, text in pairs(held) do
      if type(path) == "string" and type(text) == "string" then files[path] = text end
    end
  end
  return double.fs(files)
end

-- the vocabulary
--
-- Twelve expressions, and they stay few. This vocabulary is for what a spec PROMISES
-- about the tree, not for anything a person might want to assert about source; a bigger
-- one would start to be a testing framework, and the tree already has a test suite.

--- Declare the tree vocabulary onto the prefix. Called once, by whatever runs the specs.
function tree.declare()
  -- what a file touches

  agent.step "the module {string} names no {word}" {
    then_ = function (c)
      local path, banned = c.args[1], c.args[2]
      local text = code_of(path)
      if text == nil then return no("there is no file %s", path) end
      local at = text:find("%f[%w]" .. banned:gsub("%p", "%%%0") .. "%f[%W]")
      if at then return no("%s names %s at byte %d", path, banned, at) end
    end,
  }

  agent.step "the module {string} requires nothing" {
    then_ = function (c)
      local text = code_of(c.args[1])
      if text == nil then return no("there is no file %s", c.args[1]) end
      for name in text:gmatch("require%s*%(?%s*[\"']([%w%._%-]+)[\"']") do
        return no("%s requires %s", c.args[1], name)
      end
    end,
  }

  agent.step "the module {string} requires only {word}" {
    then_ = function (c)
      local path, allowed = c.args[1], c.args[2]
      local text = code_of(path)
      if text == nil then return no("there is no file %s", path) end
      for name in text:gmatch("require%s*%(?%s*[\"']([%w%._%-]+)[\"']") do
        local bare = name:gsub("^src%.", "")
        if bare ~= allowed then return no("%s requires %s", path, name) end
      end
    end,
  }

  -- a shell, run

  -- No `a workspace holding {string}:` here: the built-in vocabulary already says that,
  -- as `the file {string} contains:`. A second expression for a thing the harness can
  -- already state would be two ways to say one sentence, which is the collision
  -- `behaviour.declare` refuses between a step and a built-in and should refuse between
  -- a step and good sense.

  agent.step "running {string} answers {int} and:" {
    then_ = function (c)
      local fs = staged(c)
      local r = shell.line(fs, c.args[1])
      if r.code ~= c.args[2] then
        return no("%q exited %d, not %d (%s)", c.args[1], r.code, c.args[2],
                  (r.err ~= "" and r.err:gsub("\n$", "")) or "no error output")
      end
      if not same_text(r.out, c.doc) then
        return no("%q wrote %q, not %q", c.args[1], r.out, c.doc or "")
      end
    end,
  }

  agent.step "running {string} leaves {string}:" {
    then_ = function (c)
      local fs = staged(c)
      shell.line(fs, c.args[1])
      local got = fs.files[c.args[2]]
      if got == nil then return no("%q left no %s", c.args[1], c.args[2]) end
      if not same_text(got, c.doc) then
        return no("%s holds %q, not %q", c.args[2], got, c.doc or "")
      end
    end,
  }

  agent.step "running {string} twice is the same" {
    then_ = function (c)
      local function once()
        local fs = staged(c)
        local out = {}
        for line in (c.args[1] .. ";"):gmatch("([^;]+);") do
          local r = shell.line(fs, line)
          out[#out + 1] = string.format("%d|%s|%s", r.code, r.out, r.err)
        end
        local paths = {}
        for p, text in pairs(fs.files) do paths[#paths + 1] = p .. "=" .. text end
        table.sort(paths)
        out[#out + 1] = table.concat(paths, "\n")
        return table.concat(out, "\n--\n")
      end
      local a, b = once(), once()
      if a ~= b then return no("two identical runs of %q differed", c.args[1]) end
    end,
  }

  agent.step "no command reaches outside the workspace:" {
    then_ = function (c)
      local rows = c.rows or {}
      if #rows == 0 then return no("no lines were given to try") end
      for i = 1, #rows do
        local line = rows[i][1]
        local fs = staged(c)
        local r = shell.line(fs, line)
        if r.code == 0 then return no("%q succeeded", line) end
        for path in pairs(fs.files) do
          if path:find("%.%.") then return no("%q made %s", line, path) end
        end
      end
    end,
  }

  -- a command, read

  agent.step "the command line {string} did:" {
    then_ = function (c)
      local read = command.acts(c.args[1])
      local got = table.concat(read.acts, ", ")
      if not same_text(got, c.doc) then
        return no("%q reads as %q, not %q", c.args[1], got, c.doc or "")
      end
    end,
  }

  agent.step "the command line {string} is unplaced {int} time(s)" {
    then_ = function (c)
      local read = command.acts(c.args[1])
      if read.unplaced ~= c.args[2] then
        return no("%q was unplaced %d time(s), not %d", c.args[1], read.unplaced, c.args[2])
      end
    end,
  }

  agent.step "nothing it answers is inside {string}" {
    then_ = function (c)
      local line = c.args[1]
      local read = command.acts(line)
      for i = 1, #read.acts do
        if line:find(read.acts[i], 1, true) then
          return no("the term %q is a substring of the line it came from", read.acts[i])
        end
        if not command.known(read.acts[i]) then
          return no("%q is not in the closed set", read.acts[i])
        end
      end
    end,
  }

  -- a vocabulary, closed

  agent.step "the vocabulary {word} is closed" {
    then_ = function (c)
      local which = c.args[1]
      local holders = {
        acts = function () return command.ACTS end,
        commands = function () return shell.commands() end,
        editable = function ()
          local out = {}
          for name in pairs(change.EDITABLE) do out[#out + 1] = name end
          table.sort(out)
          return out
        end,
        stops = function () return agent.stops end,
      }
      local get = holders[which]
      if not get then
        return no("there is no vocabulary called %q; there is %s", which,
                  "acts, commands, editable, stops")
      end
      -- Closed means a caller cannot grow it: two reads are different tables, and what
      -- one caller adds the next cannot see.
      local a, b = get(), get()
      if a == b then return no("two reads of %s answered the same table", which) end
      a[#a + 1] = "invented"
      local after = get()
      if #after ~= #b then return no("%s grew from outside", which) end
    end,
  }

  agent.step "every {word} is reachable from a real line:" {
    then_ = function (c)
      local which = c.args[1]
      if which ~= "act" then return no("only `act` is reachable from a line, not %q", which) end
      local rows = c.rows or {}
      if #rows == 0 then return no("no lines were given") end
      local reached = {}
      for i = 1, #rows do
        local read = command.acts(rows[i][1])
        for j = 1, #read.acts do reached[read.acts[j]] = true end
      end
      local all = command.ACTS
      local missing = {}
      for i = 1, #all do
        if not reached[all[i]] then missing[#missing + 1] = all[i] end
      end
      if #missing > 0 then
        return no("no line here reaches %s", table.concat(missing, ", "))
      end
    end,
  }

  -- a declaration, changed

  agent.step "changing {word} to {value} is refused because {string}" {
    then_ = function (c)
      local field, value, said = c.args[1], c.args[2], c.args[3]
      local decl = tree.subject()
      local edit = {}
      if field == "about" or field == "ask" or field == "run" then edit.tool = "note" end
      edit[field] = value
      local made, why = change.propose(decl, edit)
      if made ~= nil then return no("changing %s went through", field) end
      if not why:find(said, 1, true) then
        return no("it was refused, and said %q rather than naming %q", why, said)
      end
    end,
  }

  agent.step "changing {word} to {value} is allowed" {
    then_ = function (c)
      local field, value = c.args[1], c.args[2]
      local decl = tree.subject()
      local edit = {}
      if field == "about" then edit.tool = "note" end
      edit[field] = value
      local made, why = change.propose(decl, edit)
      if made == nil then return no("changing %s was refused: %s", field, tostring(why)) end
      if field == "about" then
        if made.tools.note.about ~= value then return no("the tool's `about` did not change") end
        if decl.tools.note.about == value then return no("the original was changed too") end
      else
        if made[field] ~= value then return no("%s did not change", field) end
        if decl[field] == value then return no("the original was changed too") end
      end
    end,
  }

  agent.step "a proposal that {word} is {word}" {
    then_ = function (c)
      local what, expected = c.args[1], c.args[2]
      local function score(passed, failed, undefined, broken, did)
        local rep = {}
        for i = 1, #did do
          rep[i] = { n = 1, rate = 1 / #did, did = did[i], scenario = { name = "s", steps = {} } }
        end
        return { passed = passed, failed = failed, undefined = undefined,
                 broken = broken, repertoire = rep }
      end
      local was = score(0, 1, 0, 0, { { "a" }, { "b" } })
      local cases = {
        helps        = { after = score(1, 0, 0, 0, { { "a" }, { "b" } }), opts = { rules = function () return true end } },
        ["loses"]    = { after = score(2, 0, 0, 0, { { "a" } }),          opts = { rules = function () return true end } },
        ["breaks"]   = { after = score(2, 0, 0, 0, { { "a" }, { "b" } }), opts = { rules = function () return false, "rule 4" end } },
        ["fails"]    = { after = score(1, 2, 0, 0, { { "a" }, { "b" } }), opts = { rules = function () return true end } },
        ["stands"]   = { after = was,                                     opts = { rules = function () return true end } },
      }
      local case = cases[what]
      if not case then
        return no("there is no proposal that %q; there is helps, loses, breaks, fails, stands", what)
      end
      local kept, why = change.better(was, case.after, case.opts)
      local want = (expected == "kept")
      if want ~= (kept == true) then
        return no("a proposal that %s was %s: %s", what, kept and "kept" or "refused", why)
      end
    end,
  }

  agent.step "an unchecked rules gate says so" {
    then_ = function ()
      local function score(passed, failed)
        return { passed = passed, failed = failed, undefined = 0, broken = 0,
                 repertoire = { { n = 1, rate = 1, did = { "a" }, scenario = { name = "s", steps = {} } } } }
      end
      local kept, why = change.better(score(0, 1), score(1, 0))
      if not kept then return no("it refused an improvement: %s", why) end
      if not why:find("the rules were not checked", 1, true) then
        return no("it kept a change without saying the rules were unchecked: %q", why)
      end
      local ran, said = change.better(score(0, 1), score(1, 0),
                                      { rules = function () error("no such file") end })
      if ran then return no("a rules check that raised was treated as a pass") end
      if not said:find("could not be run", 1, true) then
        return no("a raising rules check said %q", said)
      end
    end,
  }

  -- the two runtimes

  agent.step "this holds under {word}" {
    then_ = function (c)
      -- A statement about how the suite is RUN, not about the tree. It passes under the
      -- interpreter it names and is skipped under the other, so a feature can say "and
      -- under luajit" without a scenario failing on the interpreter that is not it.
      local want = c.args[1]
      local is_jit = type(rawget(_G, "jit")) == "table"
      local running = is_jit and "luajit" or "lua"
      if want ~= running and want ~= "both" then
        return no("this ran under %s, not %s", running, want)
      end
    end,
  }
end

--- The declaration a `change` scenario proposes against: one tool, a briefing, a budget.
--- Built fresh each time, so a scenario that edited it cannot reach the next one.
function tree.subject()
  local spec = require "spec"
  local a = spec.new()
  a.name, a.model = "subject", "test:m"
  a.system = "Look before you act."
  a.budget = 6
  spec.add_tool(a, "note", {
    about = "Write a note",
    args  = { line = spec.types.string("what") },
    run   = function (c) return "noted: " .. tostring(c.args.line) end,
  })
  return a
end

local _ = { behaviour, gherkin, trace, observe }

return tree
