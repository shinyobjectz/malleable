-- Every spec/*.feature, run against the tree vocabulary.
--
-- One declaration holds every step: the forty-three built-in expressions, which say what an
-- AGENT does, and the tree vocabulary in `spec/tree.lua`, which says what this TREE is.
-- Two subjects, two vocabularies, one runner -- and one report, in which a promise nobody
-- has built reads as UNDEFINED and prints the `agent.step` skeleton that would define it.
--
-- `undefined` is not `failed`, which `behaviour.lua` already encodes. Pointing it at the
-- specs is what makes an unmet promise a number on every run rather than a bullet.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
local root = here .. "/../.."     -- docs/spec/ is two down from the tree
package.path = root .. "/?.lua;" .. root .. "/src/?.lua;" .. package.path

local agent     = require "agent"
local behaviour = require "behaviour"
local tree      = dofile(here .. "/tree.lua")

local run = {}

-- Which features, and the honest state of each. Named rather than globbed: plain Lua
-- cannot list a directory, and shelling out to do it would make this the one file in the
-- tree that spawns. `false` is a spec whose promises are still prose in the .md, enforced
-- by nothing -- so this list is also the work list.
local FEATURES = {
  { "shell",   true },
  { "command", true },
  { "change",  true },
  { "gherkin",   false }, { "behaviour", false }, { "trace",    false },
  { "observe",   false }, { "cli",       false }, { "session",  false },
  { "approval",  false }, { "config",    false }, { "mcp",      false },
  { "port",      false }, { "provider",  false }, { "schedule", false },
  { "skills",    false }, { "subagent",  false }, { "tools_fs", false },
  { "tools_shell", false }, { "turn",    false }, { "work",     false },
  { "compaction",  false }, { "interpret-marks", false }, { "store", false },
  { "ml",          false }, { "declare", false }, { "speech", false }, { "history", false },
}

-- A spec/*.md that is not on that list is a promise nothing counts. `tools/spec-check.sh`
-- globs the directory and fails when it finds one, because plain Lua cannot list a
-- directory and a test that shelled out to do it would be the only test here that spawns.
-- So adding a spec means adding its line, in the same commit. console and apps are in the
-- working tree unlisted right now, and the script says so, which is the rule working.

--- Is this file the script a person typed, or was it required by the test suite?
---
--- Both. `tools/spec-check.sh` runs it for the report; the suite requires it so the
--- promises cannot rot in a script nobody remembers to call.
local function is_main()
  local source = debug.getinfo(1, "S").source:sub(2)
  local named = type(arg) == "table" and arg[0] or nil
  return type(named) == "string" and (named == source or source:sub(-#named) == named)
end

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

-- The declaration every spec runs against. It has a shell and a tool, because a scenario
-- that watches a run needs something to call; the tree steps use neither.
local function subject()
  agent.reset()
  agent.name "specs"
  agent.model "spec:scripted"
  agent.budget(6)
  agent.shell { root = ".", about = "Run one command line in the workspace." }
  agent.tool "note" {
    about = "Write a note",
    args  = { line = agent.string "what" },
    run   = function (c) return "noted: " .. tostring(c.args.line) end,
  }
  tree.declare()
end

--- Run every listed feature. Answers the totals, the sore ones, and how many specs have
--- a feature file at all. Prints only when asked, so the suite can call it quietly.
function run.check(loud)
local total = { passed = 0, failed = 0, undefined = 0, broken = 0, skipped = 0 }
local promised, written = 0, 0
local sore = {}
local function say(...) if loud then io.write(...) end end

for i = 1, #FEATURES do
  local name, has = FEATURES[i][1], FEATURES[i][2]
  promised = promised + 1
  if has then
    written = written + 1
    local text = slurp(here .. "/" .. name .. ".feature")
    if text == nil then
      say(string.format("  %-14s spec/%s.feature is listed and is not there\n", name, name))
      total.broken = total.broken + 1
    else
      subject()
      local report, why = agent.verify(text)
      if not report then
        say(string.format("  %-14s does not read: %s\n", name, tostring(why)))
        total.broken = total.broken + 1
      else
        for _, k in ipairs({ "passed", "failed", "undefined", "broken", "skipped" }) do
          total[k] = total[k] + (report[k] or 0)
        end
        say(string.format("  %-14s %3d passed  %3d failed  %3d undefined  %3d broken\n",
                          name, report.passed, report.failed, report.undefined, report.broken))
        if report.failed > 0 or report.broken > 0 or report.undefined > 0 then
          sore[#sore + 1] = { name = name, report = report }
        end
      end
    end
  end
end

agent.reset()

say(string.format("\n%d of %d specs have a feature file\n", written, promised))
say(string.format("%d passed, %d failed, %d undefined, %d broken\n",
                  total.passed, total.failed, total.undefined, total.broken))

for i = 1, #sore do
  say("\n---- " .. sore[i].name .. "\n")
  say(behaviour.report(sore[i].report))
end

total.specs, total.featured = promised, written
total.sore = sore
return total
end

--- The number of undefined promises this tree admits to owing.
function run.owed()
  return tonumber((slurp(here .. "/OWED") or ""):match("%d+") or "")
end

if not is_main() then return run end

local accept = (type(arg) == "table" and arg[1] == "--accept") or false
local total = run.check(true)

-- The ratchet. A promise you have not built is legal; one that appears without being
-- written down is not, and neither is a spec that quietly stops promising something.
if accept then
  local f = assert(io.open(here .. "/OWED", "wb"))
  f:write(tostring(total.undefined) .. "\n")
  f:close()
  io.write(string.format("\nspec/OWED := %d\n", total.undefined))
  os.exit(0)
end

local owed = run.owed()
if owed == nil then
  io.write("\nspec/OWED is missing: run tools/spec-check.sh --accept once to start the ratchet\n")
  os.exit(1)
end
if total.undefined > owed then
  io.write(string.format("\n%d undefined promise(s), and spec/OWED says %d. The count goes DOWN.\n",
                         total.undefined, owed))
  os.exit(1)
end
if total.undefined < owed then
  io.write(string.format("\n%d undefined promise(s), down from %d. Run --accept to keep it there.\n",
                         total.undefined, owed))
end

-- A spec that says something FALSE is a bug, not a backlog item.
if total.failed > 0 or total.broken > 0 then os.exit(1) end
os.exit(0)
