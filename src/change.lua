-- change -- what an agent may alter about itself, scored on a test it cannot edit.
--
-- The measurements already exist: `--eval` gives a rate, `observe` gives what happened as
-- Gherkin, `agreement` gives stated against observed, `gaps` give what the vocabulary
-- could not say, `scripts/rules-test.lua` gives eight invariants.
--
-- What this file adds is the WALL. Self-improving systems fail quietly in three ways, and
-- each has one thing that stops it:
--
--   * making the test easier          -- the authored feature file is text in, never out;
--   * relaxing what it asks about     -- `ask` is not an editable field, refused by name;
--   * losing behaviour as the rate rises -- the repertoire diff, and a loss halts the step.
--
-- It calls no model and writes no file. Where a proposal comes from is the host's
-- business; this file SCORES proposals and does not invent them.
--
-- Contract: spec/change.md.

local behaviour = require "behaviour"
local gherkin   = require "gherkin"
local observe   = require "observe"

local change = {}

--- Bumped when the editable set changes.
change.VOCABULARY = 1

-- What may change: a FIELD LIST, not a rule of thumb. Anything not here is refused by
-- name, and each entry is reversible by reading one diff.
--
-- `ask` is absent on purpose: it is the gate, and an agent that can edit its own gate has
-- no gate.

local EDITABLE = {
  system = "the briefing",
  budget = "how many passes the loop may take",
  about  = "what the model is told a tool is for",
}

--- The editable fields, as a fresh table on every read.
setmetatable(change, {
  __index = function (_, k)
    if k ~= "EDITABLE" then return nil end
    local out = {}
    for name, why in pairs(EDITABLE) do out[name] = why end
    return out
  end,
})

-- The refusals, spelled out. A field refused by NAME tells whoever proposed it what the
-- boundary is; a field refused by silence teaches them to try again the same way.
local WHY_NOT = {
  ask     = "`ask` is the gate, and an agent that can edit its own gate has no gate",
  run     = "`run` is a tool's body, which is code and not a declaration",
  name    = "an agent that renames itself is a different agent, and the comparison is lost",
  model   = "which model answers is the host's decision, not the agent's",
  tools   = "adding or removing a tool changes what it CAN do, not how well it does it",
  beats   = "a beat decides when a run happens, which nothing inside a run may decide",
  servers = "a server is another process, and reaching further is not an optimisation",
}

-- small helpers

local function copy(t, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end
  local out = {}
  seen[t] = out
  for k, v in pairs(t) do out[k] = copy(v, seen) end
  return setmetatable(out, getmetatable(t))
end

local function q(s) return string.format("%q", tostring(s)) end

local function whole(v, low)
  return type(v) == "number" and v == math.floor(v) and v >= low
end

-- proposing

--- One edit, applied to a copy of a declaration.
---
--- `edit` is `{ system = "..." }`, `{ budget = 8 }`, or `{ tool = "shell", about = "..." }`.
--- Never mutates what it is given, so a revert is exact.
---
--- Answers the new declaration, or nil and one sentence saying why not.
function change.propose(decl, edit)
  if type(decl) ~= "table" then
    error("change.propose(decl, edit): decl is a declaration table, and arrived as " .. type(decl), 2)
  end
  if type(edit) ~= "table" then
    error("change.propose(decl, edit): edit is a table, and arrived as " .. type(edit), 2)
  end

  local which = edit.tool
  local fields = {}
  for k in pairs(edit) do
    if k ~= "tool" then fields[#fields + 1] = k end
  end
  table.sort(fields)
  if #fields == 0 then return nil, "the edit changes nothing" end
  if #fields > 1 then
    return nil, "an edit changes one field at a time, and this changes " .. #fields
      .. ": a change that cannot be attributed to one cause is not a measurement"
  end

  local field = fields[1]
  if EDITABLE[field] == nil then
    local why = WHY_NOT[field]
    if why then return nil, "refused: " .. why end
    return nil, "refused: there is no editable field " .. q(field)
      .. "; the editable ones are about, budget, system"
  end

  local out = copy(decl)

  if field == "about" then
    if type(which) ~= "string" or which == "" then
      return nil, "an edit to `about` says which tool, as `tool = \"...\"`"
    end
    if type(out.tools) ~= "table" or out.tools[which] == nil then
      return nil, "there is no tool called " .. q(which) .. " on this declaration"
    end
    if type(edit.about) ~= "string" or edit.about == "" then
      return nil, "`about` is the sentence the model reads, and cannot be empty"
    end
    out.tools[which].about = edit.about
    return out
  end

  if which ~= nil then
    return nil, "only `about` belongs to a tool; " .. q(field) .. " belongs to the declaration"
  end

  if field == "system" then
    if type(edit.system) ~= "string" then
      return nil, "`system` is the briefing, as a string"
    end
    out.system = edit.system
    return out
  end

  -- budget
  if not whole(edit.budget, 1) then
    return nil, "`budget` is a whole number of steps, at least 1"
  end
  out.budget = edit.budget
  return out
end

-- Scoring, ONLY on authored scenarios -- written by a person, in text this module is given
-- and never answers. An optimiser scored on a test it can edit will edit the test:
-- authored is the fitness function, observed is memory.

local function pickles_of(feature)
  if type(feature) ~= "string" then
    return nil, "the authored feature file is text, and arrived as " .. type(feature)
  end
  local pickles, why = gherkin.pickle(feature)
  if not pickles then return nil, "the authored feature file does not read: " .. tostring(why) end
  if #pickles == 0 then
    -- An optimiser with no fitness function will happily report that everything improved.
    return nil, "the authored feature file states no scenario, so there is nothing to score against"
  end
  return pickles
end

--- What a declaration scores, and what it does.
---
--- Answers `{ passed, failed, undefined, broken, repertoire, report }`. The repertoire is
--- what a pass count cannot carry: what the agent did, collapsed into distinct behaviours.
function change.score(decl, feature, drivers)
  local pickles, why = pickles_of(feature)
  if not pickles then return nil, why end
  if type(drivers) ~= "function" then
    error("change.score(decl, feature, drivers): drivers is a function (decl) -> drivers", 2)
  end

  local made = drivers(decl)
  local report = behaviour.run(pickles, made)

  -- The repertoire is built from the scenarios that PASSED, and only those.
  --
  -- A behaviour exhibited while FAILING is not something to protect -- stopping it is what
  -- fixing means. The gate is for behaviour the agent had while it was WORKING, which a
  -- rising pass count can hide the loss of.
  local seen = {}
  for i = 1, #report.scenarios do
    local record = report.scenarios[i].record
    if record and report.scenarios[i].outcome == "passed" then
      local pickle = select(1, observe.run(record))
      if pickle then seen[#seen + 1] = pickle end
    end
  end

  return {
    passed = report.passed, failed = report.failed,
    undefined = report.undefined, broken = report.broken,
    repertoire = observe.repertoire(seen),
    report = report,
  }
end

--- Is `after` better than `before`, and is it safe?
---
--- Three gates, all of which must hold, each a measurement rather than a review. The
--- third is the one that does not exist anywhere else and is why this is safe to run
--- unattended: a rate can rise while an agent quietly stops doing half of what it did,
--- and a pass count cannot see that.
function change.better(before, after, opts)
  opts = opts or {}
  if type(before) ~= "table" or type(after) ~= "table" then
    error("change.better(before, after): two scores", 2)
  end

  -- Gate one: the rules still hold.
  --
  -- Supplied by the host, the same seam as the model: `scripts/rules-test.lua` is a script,
  -- and this module writes no file and reads none. The host that knows where the rules live
  -- passes a function.
  --
  -- Skipping it silently is NOT allowed. With no `opts.rules` every decision says so in its
  -- own sentence.
  local unchecked = ""
  if opts.rules ~= nil then
    if type(opts.rules) ~= "function" then
      error("change.better: opts.rules is a function () -> ok, why", 2)
    end
    local ran, held, said = pcall(opts.rules)
    if not ran then
      return false, "the rules could not be run: " .. tostring(held)
    end
    if not held then
      -- Even when the rate went up. A rule is a constraint and not a preference, and an
      -- optimiser that could trade one for a better number is an optimiser with no wall.
      return false, "a rule no longer holds: " .. tostring(said or "the rules did not say why")
    end
  else
    unchecked = " (the rules were not checked: no opts.rules was given)"
  end

  if after.broken > before.broken then
    return false, string.format("it broke %d scenario(s) that were not broken", after.broken - before.broken) .. unchecked
  end
  if after.failed > before.failed then
    return false, string.format("it failed %d more scenario(s)", after.failed - before.failed) .. unchecked
  end
  if after.undefined > before.undefined then
    return false, string.format("it left %d more line(s) undefined", after.undefined - before.undefined) .. unchecked
  end

  local diff = observe.repertoire_diff(before.repertoire, after.repertoire)
  if #diff.lost > 0 and opts.allow_loss ~= true then
    return false, string.format("it lost %d behaviour(s), starting with %q",
                                #diff.lost, diff.lost[1].did[1] or "(did nothing)") .. unchecked, diff
  end

  if after.passed > before.passed then
    return true, string.format("%d scenario(s) passed, up from %d", after.passed, before.passed)
      .. unchecked, diff
  end
  if after.passed < before.passed then
    return false, string.format("%d scenario(s) passed, down from %d", after.passed, before.passed)
      .. unchecked, diff
  end
  return false, "nothing changed that this can measure" .. unchecked, diff
end

-- the loop

--- One round: propose, score, keep or refuse -- and say which gate decided.
---
--- Answers `{ kept, why, decl, before, after, diff }`. `decl` is the declaration to carry
--- forward, which is the proposal when it was kept and the original when it was not.
function change.step(decl, feature, edit, drivers, opts)
  opts = opts or {}
  local before = opts.before
  if before == nil then
    local scored, why = change.score(decl, feature, drivers)
    if not scored then return { kept = false, why = why, decl = decl } end
    before = scored
  end

  local proposed, refused = change.propose(decl, edit)
  if not proposed then
    return { kept = false, why = refused, decl = decl, before = before }
  end

  local after, why = change.score(proposed, feature, drivers)
  if not after then return { kept = false, why = why, decl = decl, before = before } end

  local keep, said, diff = change.better(before, after, opts)
  if keep then
    return { kept = true, why = said, decl = proposed, before = before, after = after, diff = diff }
  end
  return { kept = false, why = said, decl = decl, before = before, after = after, diff = diff }
end

--- Steps until nothing improves, or the proposals run out.
---
--- `edits` is a list, in order. This module does not invent them: where a proposal comes
--- from -- a person, a model, a sweep -- is the host's business, and a scorer that also
--- proposed would be a scorer nobody could test without a model.
function change.loop(decl, feature, edits, drivers, opts)
  if type(edits) ~= "table" then
    error("change.loop(decl, feature, edits, drivers): edits is a list", 2)
  end
  opts = opts or {}
  local held, why = change.score(decl, feature, drivers)
  if not held then return nil, why end

  local steps = {}
  local current = decl
  for i = 1, #edits do
    local step = change.step(current, feature, edits[i], drivers,
                             { before = held, allow_loss = opts.allow_loss, rules = opts.rules })
    step.edit = edits[i]
    steps[#steps + 1] = step
    if step.kept then
      current = step.decl
      held = step.after
    end
  end
  return { decl = current, steps = steps, score = held, from = decl }
end

--- The loop, as the lines a person reads. Each step says which gate decided.
function change.report(run)
  if type(run) ~= "table" or type(run.steps) ~= "table" then
    error("change.report: a run from change.loop", 2)
  end
  local out = {}
  local function line(fmt, ...) out[#out + 1] = string.format(fmt, ...) end

  local kept = 0
  for i = 1, #run.steps do if run.steps[i].kept then kept = kept + 1 end end
  line("%d proposal(s), %d kept", #run.steps, kept)

  for i = 1, #run.steps do
    local s = run.steps[i]
    local named = {}
    for k, v in pairs(s.edit or {}) do
      named[#named + 1] = k .. "=" .. (type(v) == "string" and q(v) or tostring(v))
    end
    table.sort(named)
    line("\n  %s  %s", s.kept and "kept   " or "refused", table.concat(named, " "))
    line("           %s", s.why or "")
    if s.diff and #s.diff.lost > 0 then
      for k = 1, #s.diff.lost do
        line("           lost: %s", s.diff.lost[k].did[1] or "(did nothing)")
      end
    end
  end
  return table.concat(out, "\n") .. "\n"
end

return change
