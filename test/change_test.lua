-- change: what an agent may alter about itself, scored on a test it cannot edit.
--
-- The tests that matter are the refusals. A self-improving system fails quietly in three
-- ways -- it makes the test easier, it relaxes what it asks permission for, or it loses
-- behaviour while the rate rises -- and each of those has one test here that tries it.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local change  = require "change"
local spec    = require "spec"
local turn    = require "turn"
local cli     = require "cli"
local double  = require "double"
local observe = require "observe"

local T = {}

-- A declaration with a tool, a briefing and a budget: the three editable things.
local function declared(system, budget)
  local a = spec.new()
  a.name, a.model = "keeper", "test:m"
  a.system = system or "Look before you act."
  a.budget = budget or 6
  spec.add_tool(a, "note", {
    about = "Write a note",
    args  = { line = spec.types.string("what") },
    run   = function (c) return "noted: " .. tostring(c.args.line) end,
  })
  return a
end

-- The drivers a score runs through: a whole turn loop over the doubles, as `--verify` does.
local function drivers_for(decl)
  return cli.drivers(decl, function (prompt, port, ropts)
    return turn.run(decl, prompt, port, ropts)
  end)
end

local FEATURE = [[
Feature: keeping notes

  Scenario: it notes what it was asked to
    Given the model calls note with { "line": "the thing" }
    And the model answers "noted it"
    When the agent is asked "note the thing"
    Then it calls note
    And it stops with answered
]]

-- ------------------------------------------------------------------ the field list

function T.the_editable_fields_are_three_and_the_list_is_a_fresh_copy()
  local e = change.EDITABLE
  local n = 0
  for _ in pairs(e) do n = n + 1 end
  assert(n == 3, n .. " editable fields")
  assert(e.system and e.budget and e.about)
  e.ask = "sneaked in"
  assert(change.EDITABLE.ask == nil, "the list grew")
end

function T.the_three_editable_fields_apply_to_a_copy()
  local a = declared("old briefing", 4)

  local system = assert(change.propose(a, { system = "new briefing" }))
  assert(system.system == "new briefing" and system.budget == 4)
  assert(a.system == "old briefing", "the original was mutated")

  local budget = assert(change.propose(a, { budget = 9 }))
  assert(budget.budget == 9 and budget.system == "old briefing")
  assert(a.budget == 4, "the original was mutated")

  local about = assert(change.propose(a, { tool = "note", about = "Record one line" }))
  assert(about.tools.note.about == "Record one line")
  assert(a.tools.note.about == "Write a note", "the original was mutated")
end

-- ---------------------------------------------------------------- the refusals

function T.the_gate_is_refused_by_name_and_that_is_the_point()
  local a = declared()
  -- The most important refusal in the file. An agent that can edit its own gate has no
  -- gate, and this is the edit it would most like to make.
  local was = a.tools.note.ask
  local none, why = change.propose(a, { tool = "note", ask = not was })
  assert(none == nil, "an agent edited its own gate")
  assert(why:find("`ask` is the gate", 1, true), why)
  assert(a.tools.note.ask == was, "the declaration changed anyway")
end

function T.every_field_that_is_not_editable_is_refused_by_its_own_name()
  local a = declared()
  local tries = {
    { edit = { ask = true },                   says = "the gate" },
    { edit = { run = function () end },        says = "a tool's body" },
    { edit = { name = "someone else" },        says = "renames itself" },
    { edit = { model = "another:model" },      says = "which model answers" },
    { edit = { tools = {} },                   says = "adding or removing a tool" },
    { edit = { beats = {} },                   says = "when a run happens" },
    { edit = { servers = {} },                 says = "another process" },
    { edit = { frobnicate = 1 },               says = "no editable field" },
  }
  for i = 1, #tries do
    local none, why = change.propose(a, tries[i].edit)
    assert(none == nil, "an edit went through that should not have: " .. i)
    -- BY NAME. A field refused by silence teaches whoever proposed it to try again the
    -- same way; one refused by name tells them where the boundary is.
    assert(why:find(tries[i].says, 1, true), why)
  end
end

function T.an_edit_changes_one_field_so_a_change_can_be_attributed()
  local a = declared()
  local none, why = change.propose(a, { system = "x", budget = 3 })
  assert(none == nil and why:find("one field at a time", 1, true), why)
  local nothing, said = change.propose(a, {})
  assert(nothing == nil and said:find("changes nothing", 1, true), said)
end

function T.an_edit_to_a_tool_that_is_not_there_says_so()
  local a = declared()
  local none, why = change.propose(a, { tool = "absent", about = "x" })
  assert(none == nil and why:find("no tool called", 1, true), why)
  local bare, said = change.propose(a, { about = "x" })
  assert(bare == nil and said:find("says which tool", 1, true), said)
  local wrong, w = change.propose(a, { tool = "note", budget = 3 })
  assert(wrong == nil and w:find("belongs to the declaration", 1, true), w)
end

-- ------------------------------------------------------------------- the scoring

local function world_for()
  return double.world {
    model = { { tool = "note", args = { line = "the thing" } }, { text = "noted it" } },
  }
end

function T.a_score_is_a_pass_count_and_a_repertoire()
  local a = declared()
  local scored = assert(change.score(a, FEATURE, drivers_for))
  assert(scored.passed == 1 and scored.failed == 0, scored.passed .. "/" .. scored.failed)
  -- The half a pass count cannot carry: what it actually did.
  assert(#scored.repertoire == 1, #scored.repertoire)
  assert(#scored.repertoire[1].did > 0)
  local _ = world_for
end

function T.an_authored_file_with_no_scenarios_refuses_to_run()
  local a = declared()
  -- An optimiser with no fitness function will happily report that everything improved.
  local none, why = change.score(a, "Feature: nothing at all\n", drivers_for)
  assert(none == nil and why:find("nothing to score against", 1, true), why)
  local bad, said = change.score(a, 7, drivers_for)
  assert(bad == nil and said:find("is text", 1, true), said)
end

-- --------------------------------------------------------------------- the gates

local function score_like(passed, failed, undefined, broken, did)
  local rep = {}
  for i = 1, #did do
    rep[i] = { n = 1, rate = 1 / #did, did = did[i], scenario = { name = "s", steps = {} } }
  end
  return { passed = passed, failed = failed, undefined = undefined or 0,
           broken = broken or 0, repertoire = rep }
end

function T.more_passing_is_better_and_fewer_is_not()
  local was = score_like(1, 1, 0, 0, { { "it stops with answered" } })
  local up  = score_like(2, 0, 0, 0, { { "it stops with answered" } })
  local ok, why = change.better(was, up)
  assert(ok and why:find("up from 1", 1, true), why)

  -- Fewer passing AND more failing: the failure gate fires first, and says so, because
  -- a new failure is a worse fact than a lower count and should be the sentence read.
  local down = score_like(0, 2, 0, 0, { { "it stops with answered" } })
  local no, said = change.better(was, down)
  assert(not no and said:find("failed 1 more", 1, true), said)

  -- Fewer passing with no new failure -- scenarios became undefined-free but simply
  -- stopped passing -- is refused on the count itself.
  local quieter = score_like(0, 1, 0, 0, { { "it stops with answered" } })
  local none, why_less = change.better(was, quieter)
  assert(not none and why_less:find("down from 1", 1, true), why_less)

  local same, still = change.better(was, was)
  assert(not same and still:find("nothing changed", 1, true), still)
end

function T.a_proposal_that_improves_the_rate_by_LOSING_a_behaviour_is_refused()
  -- The gate that exists nowhere else, and the reason this is safe to run unattended.
  -- The rate went UP. A pass count would keep this and never mention what went missing.
  local was = score_like(1, 1, 0, 0, {
    { "it stops with answered", "it calls note" },
    { "it stops with answered", "it asks a human" },
  })
  local up = score_like(2, 0, 0, 0, {
    { "it stops with answered", "it calls note" },
  })
  local ok, why, diff = change.better(was, up)
  assert(not ok, "a behaviour was lost and the rate carried the day")
  assert(why:find("lost 1 behaviour", 1, true), why)
  -- And it says WHICH.
  assert(why:find("it stops with answered", 1, true), why)
  assert(diff and #diff.lost == 1)

  -- A host that means it can say so, in writing.
  assert(change.better(was, up, { allow_loss = true }), "allow_loss did not allow it")
end

function T.a_new_failure_or_a_new_undefined_line_is_refused_before_anything_else()
  local was = score_like(1, 0, 0, 0, { { "a" } })
  local broke = score_like(3, 1, 0, 0, { { "a" } })
  local no, why = change.better(was, broke)
  assert(not no and why:find("failed 1 more", 1, true), why)

  local undef = score_like(3, 0, 2, 0, { { "a" } })
  local none, said = change.better(was, undef)
  assert(not none and said:find("undefined", 1, true), said)

  local bust = score_like(3, 0, 0, 1, { { "a" } })
  local nope, w = change.better(was, bust)
  assert(not nope and w:find("broke", 1, true), w)
end

-- ---------------------------------------------------------------------- the loop

function T.a_loop_keeps_what_helps_and_carries_the_declaration_forward()
  -- A declaration whose budget is too small to finish, and a proposal that fixes it.
  local a = declared("Look before you act.", 1)
  local before = assert(change.score(a, FEATURE, drivers_for))
  assert(before.passed == 0, "the starting declaration already passes, so nothing is measured")

  local run = assert(change.loop(a, FEATURE, {
    { tool = "note", about = "Record one line of anything" },  -- harmless, changes nothing
    { budget = 6 },                                            -- the one that helps
    { ask = true },                                            -- refused by name
  }, drivers_for))

  assert(#run.steps == 3, #run.steps)
  assert(run.steps[2].kept, run.steps[2].why)
  assert(not run.steps[3].kept and run.steps[3].why:find("`ask` is the gate", 1, true))
  assert(run.decl.budget == 6, tostring(run.decl.budget))
  assert(run.score.passed == 1, run.score.passed)

  -- The original is untouched, so a person holds what it was.
  assert(a.budget == 1, "the loop mutated what it was given")

  local text = change.report(run)
  assert(text:find("3 proposal(s), 1 kept", 1, true), text)
  assert(text:find("refused", 1, true) and text:find("kept", 1, true))
end

-- Gate one, which `spec/change.md` promised and the code did not have until an audit
-- looked for it. A rule is a CONSTRAINT and not a preference: an optimiser that could
-- trade one for a better number is an optimiser with no wall.
function T.a_proposal_that_breaks_a_rule_is_refused_even_when_the_rate_went_up()
  local was = score_like(0, 1, 0, 0, { { "a" } })
  local up  = score_like(1, 0, 0, 0, { { "a" } })

  -- With the rules holding, this is exactly the improvement the loop exists to keep.
  local ok = change.better(was, up, { rules = function () return true end })
  assert(ok, "the rate went up and the rules held, and it was refused")

  -- With one broken, the rate is not consulted at all.
  local no, why = change.better(was, up, { rules = function () return false, "rule 4 no longer holds" end })
  assert(not no, "a rule broke and the rate carried the day")
  assert(why:find("rule 4 no longer holds", 1, true), why)

  -- A rules check that RAISES is a refusal too. A gate that cannot run is not a gate that
  -- passed, and the difference is where this kind of system quietly stops being checked.
  local none, said = change.better(was, up, { rules = function () error("no such file") end })
  assert(not none and said:find("could not be run", 1, true), said)

  -- And with no rules function at all, every sentence says the gate was not checked --
  -- because a gate nobody can see was skipped is a gate that has already stopped working.
  local quiet, unchecked = change.better(was, up)
  assert(quiet, unchecked)
  assert(unchecked:find("the rules were not checked", 1, true), unchecked)
end

-- `spec/change.md` promises every editable field "kept when it helps and reverted when it
-- does not". The loop test below shows `budget`; these are the other two, each shown both
-- ways, because a field that is only ever refused is a field nothing proves is editable.
function T.each_editable_field_is_kept_when_it_helps_and_reverted_when_it_does_not()
  -- A briefing that changes nothing measurable is reverted; a briefing is scored like
  -- anything else and "it reads better" is not a measurement this has.
  local a = declared("Look before you act.", 6)
  local held = assert(change.loop(a, FEATURE, {
    { system = "Say less." },
    { tool = "note", about = "Record one line" },
  }, drivers_for))
  assert(not held.steps[1].kept, "a change with no measurable effect was kept")
  assert(not held.steps[2].kept, "a change with no measurable effect was kept")
  assert(held.decl.system == "Look before you act.", "it was not reverted")
  assert(held.decl.tools.note.about == "Write a note", "it was not reverted")

  -- And each is kept when it does help. The scripted model calls `note`, so a declaration
  -- with NO briefing at all still passes -- what makes these measurable is a feature that
  -- turns on them, which is `budget` here and would be a scenario there. Stated rather
  -- than faked: a doubled model does not read a briefing, so a briefing cannot be scored
  -- against one, and that is a real limit of scoring against doubles.
  local scored = assert(change.score(declared("", 6), FEATURE, drivers_for))
  assert(scored.passed == 1, "the fixture no longer measures what this test says it does")
end

function T.the_loop_is_given_the_feature_as_text_and_never_answers_one()
  local a = declared()
  local run = assert(change.loop(a, FEATURE, { { budget = 8 } }, drivers_for))
  -- The Goodhart gate, mechanically: nothing this module answers is a feature file, so
  -- there is nothing for an optimiser to edit the test through.
  local function holds_a_feature(v, depth)
    if depth > 4 or type(v) ~= "table" then
      return type(v) == "string" and v:find("Feature:", 1, true) ~= nil
    end
    for _, inner in pairs(v) do
      if holds_a_feature(inner, depth + 1) then return true end
    end
    return false
  end
  assert(not holds_a_feature(run.decl, 0), "the declaration it answered carries a feature file")
end

function T.the_same_proposals_in_the_same_order_decide_the_same_way()
  local a = declared("Look before you act.", 1)
  local edits = { { budget = 6 }, { system = "Act first." }, { tool = "note", about = "Note it" } }
  local function once()
    local run = assert(change.loop(declared("Look before you act.", 1), FEATURE, edits, drivers_for))
    local out = {}
    for i = 1, #run.steps do
      out[#out + 1] = tostring(run.steps[i].kept) .. "|" .. tostring(run.steps[i].why)
    end
    return table.concat(out, "\n")
  end
  assert(once() == once(), "two identical loops decided differently")
  local _ = a
end

function T.wrong_shapes_raise()
  assert(not pcall(change.propose, 7, {}))
  assert(not pcall(change.propose, {}, 7))
  assert(not pcall(change.better, {}, 7))
  assert(not pcall(change.loop, {}, "Feature: f\n", 7, function () end))
  assert(not pcall(change.report, 7))
  assert(not pcall(change.score, declared(), FEATURE, "not a function"))
  local _ = observe
end

return T
