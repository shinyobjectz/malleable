-- behaviour: a feature file, run against a declaration.
--
-- Rule 6 is the half worth reading: a Given line may only write the world, a Then line
-- may only read the result, and there is no arrangement of fields that crosses them.
-- The rest is the closed vocabulary, one test per group, and the four outcomes kept
-- apart -- because a report that conflates undefined with failed sends a person to the
-- wrong file.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local gherkin   = require "gherkin"
local behaviour = require "behaviour"
local spec      = require "spec"
local turn      = require "turn"
local cli       = require "cli"

local T = {}

-- A declaration with one tool that writes, and one that asks first.
local function declared()
  local a = spec.new()
  a.name, a.model = "scribe", "test:scripted"
  spec.add_tool(a, "note", {
    about = "Write a note",
    args = { text = spec.types.string("what to write") },
    run = function (c) return c.fs.write("note.txt", c.args.text) and "written" or "no" end,
  })
  spec.add_tool(a, "file", {
    about = "File it, once a human agrees",
    ask = true,
    args = { text = spec.types.string("what to file") },
    run = function (c) c.note("filed it"); return c.fs.write("filed.txt", c.args.text) and "filed" or "no" end,
  })
  return a
end

local function drivers(a)
  return cli.drivers(a, function (prompt, port, opts)
    return turn.run(a, prompt, port, opts)
  end)
end

local function verify(a, text, opts)
  local pickles, why = gherkin.pickle(text)
  assert(pickles, tostring(why))
  return behaviour.run(pickles, drivers(a), opts)
end

local function one(a, text, opts)
  local r = verify(a, text, opts)
  assert(#r.scenarios == 1, #r.scenarios .. " scenarios")
  return r.scenarios[1], r
end

local function why_of(s)
  for i = 1, #s.steps do if s.steps[i].why then return s.steps[i].why end end
  return "(no reason given)"
end

local FEATURE = "Feature: f\n"

-- ---------------------------------------------------------------------- the phases

function T.a_given_writes_the_world_and_a_when_runs_it_and_a_then_reads_the_result()
  local s = one(declared(), FEATURE .. [[
  Scenario: the whole shape
    Given the file "a.txt" contains:
      """
      hello
      """
    And the model calls note with {"text": "one"}
    And the model answers "done"
    When the agent is asked "note something"
    Then it stops with answered
    And it calls note with {"text": "one"}
    And the file "note.txt" holds:
      """
      one
      """
]])
  assert(s.outcome == "passed", why_of(s))
end

function T.a_then_line_cannot_write_and_says_so_by_name()
  local a = declared()
  spec.add_step(a, "the world is quietly changed", {
    then_ = function (c) c.world.fs.files["sneak"] = "x" end,
  }, gherkin.expr("the world is quietly changed"))
  local s = one(a, FEATURE .. [[
  Scenario: it tries
    Given the model answers "done"
    When the agent is asked "go"
    Then the world is quietly changed
]])
  assert(s.outcome == "broken", s.outcome)
  assert(why_of(s):match("may only read"), why_of(s))
  assert(why_of(s):match("world%.fs%.files%.sneak"), why_of(s))
end

function T.a_given_body_has_no_result_and_a_then_body_has_one()
  local a = declared()
  local saw = {}
  spec.add_step(a, "the given phase looks around", {
    given = function (c) saw.given = { result = c.result, world = type(c.world) } end,
  }, gherkin.expr("the given phase looks around"))
  spec.add_step(a, "the then phase looks around", {
    then_ = function (c) saw.then_ = { result = type(c.result), world = type(c.world) } end,
  }, gherkin.expr("the then phase looks around"))
  one(a, FEATURE .. [[
  Scenario: looking
    Given the given phase looks around
    And the model answers "done"
    When the agent is asked "go"
    Then the then phase looks around
]])
  assert(saw.given.result == nil, "a given body can see a result")
  assert(saw.given.world == "table")
  assert(saw.then_.result == "table", "a then body cannot see the result")
end

function T.a_given_after_a_when_and_two_whens_and_no_when_are_each_broken()
  local a = declared()
  local s = one(a, FEATURE .. [[
  Scenario: a given too late
    Given the model answers "x"
    When the agent is asked "go"
    Given the file "a" is missing
    Then it stops with answered
]])
  assert(s.outcome == "broken" and why_of(s):match("cannot follow a When"), why_of(s))

  s = one(a, FEATURE .. [[
  Scenario: two whens
    Given the model answers "x"
    When the agent is asked "a"
    When the agent is asked "b"
    Then it stops with answered
]])
  assert(s.outcome == "broken" and why_of(s):match("one When"), why_of(s))
  assert(s.steps[1].outcome == "skipped", "a refused scenario ran a step")

  s = one(a, FEATURE .. [[
  Scenario: no when
    Given the model answers "x"
    Then it stops with answered
]])
  assert(s.outcome == "broken" and why_of(s):match("nobody finished"), why_of(s))
end

-- ------------------------------------------------------------------ the vocabulary

function T.the_vocabulary_is_closed_and_every_expression_compiles_once()
  local steps = behaviour.steps()
  assert(#steps == 47, #steps .. " expressions")   -- 47 since `the file holds the line` (2026-09-12)
  local skeletons, n = behaviour.skeletons(), 0
  for _ in pairs(skeletons) do n = n + 1 end
  -- One skeleton each: two built-ins that read the same line would make every scenario
  -- that used it ambiguous.
  assert(n == #steps, n .. " skeletons for " .. #steps .. " expressions")
  local phases = { given = 0, when = 0, ["then"] = 0 }
  for i = 1, #steps do phases[steps[i].phase] = phases[steps[i].phase] + 1 end
  assert(phases.given == 16 and phases.when == 3 and phases["then"] == 28,
         string.format("%d/%d/%d", phases.given, phases.when, phases["then"]))
end

function T.the_gate_the_shell_the_clock_and_the_budget_are_all_sayable()
  local s = one(declared(), FEATURE .. [[
  Scenario: everything at once
    Given the clock reads "2026-06-01T09:00:00Z"
    And the command "echo hi" answers 0 and:
      """
      hi
      """
    And the human approves file
    And the model calls file with {"text": "x"}
    And the model answers "filed"
    When the agent is asked "file it"
    Then the human is asked about file
    And it calls file 1 time
    And it never calls note
    And it notes "filed it"
    And it takes at most 4 steps
]])
  assert(s.outcome == "passed", why_of(s))
end

function T.a_refusal_at_the_gate_is_a_result_and_not_an_error()
  local s = one(declared(), FEATURE .. [[
  Scenario: the human says no
    Given the human refuses file
    And the model calls file with {"text": "x"}
    And the model answers "I was not allowed."
    When the agent is asked "file it"
    Then the call to file is refused
    And it stops with answered
    And nothing is written
]])
  assert(s.outcome == "passed", why_of(s))
end

function T.the_budget_is_stated_and_the_loop_always_ends()
  local s = one(declared(), FEATURE .. [[
  Scenario: a runaway
    Given the budget is 2
    And the model calls note with {"text": "a"}
    And the model calls note with {"text": "a"}
    And the model calls note with {"text": "a"}
    When the agent is asked "keep going"
    Then it stops with budget
    And it takes 2 steps
]])
  assert(s.outcome == "passed", why_of(s))
end

function T.the_declaration_is_loaded_reaches_no_port_and_reads_the_check()
  local s = one(declared(), FEATURE .. [[
  Scenario: it is sound
    When the declaration is loaded
    Then the declaration is sound
]])
  assert(s.outcome == "passed", why_of(s))
  assert(s.result == nil, "a check made a run")

  local a = spec.new()
  a.name = "unnamed model"
  s = one(a, FEATURE .. [[
  Scenario: it is not
    When the declaration is loaded
    Then the declaration is refused because "model"
]])
  assert(s.outcome == "passed", why_of(s))
end

function T.a_time_that_is_not_a_time_is_a_failure_with_the_shape_in_it()
  local s = one(declared(), FEATURE .. [[
  Scenario: a bad clock
    Given the clock reads "yesterday"
    And the model answers "x"
    When the agent is asked "go"
    Then it stops with answered
]])
  assert(s.outcome == "failed" and why_of(s):match("2026%-06%-01"), why_of(s))
end

-- --------------------------------------------------------------- the four outcomes

function T.undefined_is_not_failed_and_it_carries_the_stub()
  local s, r = one(declared(), FEATURE .. [[
  Scenario: nobody wrote this one
    Given the queue holds a ticket from "ops"
    When the agent is asked "go"
    Then it stops with answered
]])
  assert(s.outcome == "undefined", s.outcome)
  assert(r.undefined == 1 and r.failed == 0)
  local stub
  for i = 1, #s.steps do if s.steps[i].stub then stub = s.steps[i].stub end end
  assert(stub and stub:match('agent%.step "the queue holds a ticket from {string}"'), tostring(stub))
  -- And what follows it is skipped, not run.
  assert(s.steps[2].outcome == "skipped", s.steps[2].outcome)
  assert(s.steps[3].outcome == "skipped")
end

function T.a_step_that_raises_is_broken_and_a_failed_expectation_is_failed()
  local a = declared()
  spec.add_step(a, "the step explodes", {
    then_ = function () error("boom") end,
  }, gherkin.expr("the step explodes"))

  local s = one(a, FEATURE .. [[
  Scenario: it raises
    Given the model answers "x"
    When the agent is asked "go"
    Then the step explodes
]])
  assert(s.outcome == "broken" and why_of(s):match("boom"), why_of(s))

  s = one(a, FEATURE .. [[
  Scenario: it merely does not hold
    Given the model answers "x"
    When the agent is asked "go"
    Then it answers "something else"
]])
  assert(s.outcome == "failed", s.outcome)
end

function T.a_scenario_with_no_steps_is_undefined_and_an_all_undefined_feature_is_not_ok()
  local r = verify(declared(), FEATURE .. "  Scenario: named and not written\n")
  assert(r.scenarios[1].outcome == "undefined", r.scenarios[1].outcome)
  assert(r.ok == false, "a feature nobody wired up must not look green")

  -- But one undefined scenario beside a passing one does not sink the feature.
  r = verify(declared(), FEATURE .. [[
  Scenario: named and not written
  Scenario: written
    Given the model answers "x"
    When the agent is asked "go"
    Then it stops with answered
]])
  assert(r.ok == true, "one undefined scenario sank a passing feature")
end

-- ---------------------------------------------------------------------- declaring

function T.a_declared_step_states_its_phase_by_which_body_it_gives()
  local a = spec.new()
  local function raised(fn, ...)
    local ok, m = pcall(fn, ...); return (not ok), tostring(m)
  end
  local no, why = raised(behaviour.declare, spec, a, "x", { given = print, then_ = print })
  assert(no and why:match("one phase"), why)

  no, why = raised(behaviour.declare, spec, a, "x", {})
  assert(no and why:match("needs `given`"), why)

  -- There is no `when` a workspace can write, and asking for one says why.
  no, why = raised(behaviour.declare, spec, a, "x", { when = print })
  assert(no and why:match("no such slot"), why)
end

function T.a_declared_step_cannot_redefine_a_built_in_or_another_declared_one()
  local a = spec.new()
  local function raised(fn, ...)
    local ok, m = pcall(fn, ...); return (not ok), tostring(m)
  end
  local no, why = raised(behaviour.declare, spec, a, "it calls {word}", { then_ = print })
  assert(no and why:match("collides with the built%-in"), why)

  behaviour.declare(spec, a, "the queue holds {string}", { given = print })
  no, why = raised(behaviour.declare, spec, a, "the queue holds {word}", { given = print })
  assert(no and why:match("collides with"), why)

  -- And an expression this tree will not read fails on the line that wrote it.
  no, why = raised(behaviour.declare, spec, a, "the {bogus} thing", { given = print })
  assert(no and why:match("not a parameter type"), why)
end

function T.a_workspace_given_survives_to_its_own_then()
  local a = declared()
  behaviour.declare(spec, a, "the queue holds a ticket from {string}", {
    given = function (c)
      c.world.queue = c.world.queue or {}
      c.world.queue[#c.world.queue + 1] = c.args[1]
    end,
  })
  behaviour.declare(spec, a, "the queue held {int} ticket(s)", {
    then_ = function (c)
      local n = #(c.world.queue or {})
      if n ~= c.args[1] then return false, "the queue held " .. n end
    end,
  })
  local s = one(a, FEATURE .. [[
  Scenario: state crosses the When
    Given the queue holds a ticket from "ops"
    And the queue holds a ticket from "sales"
    And the model answers "x"
    When the agent is asked "go"
    Then the queue held 2 tickets
]])
  assert(s.outcome == "passed", why_of(s))
end

-- ------------------------------------------------------------------------ checking

function T.check_finds_its_problems_with_a_line_number_and_reaches_no_port()
  local a = declared()
  local pickles = assert(gherkin.pickle(FEATURE .. [[
  Scenario: stale
    Given the human approves note
    When the agent is asked "go"
    Then it calls salute
  Scenario: two whens
    When the agent is asked "a"
    When the agent is asked "b"
    Then it stops with answered
  Scenario: none
    Given the model answers "x"
    Then it stops with answered
  Scenario: undefined
    Given the moon is full
    When the agent is asked "go"
    Then it stops with answered
]]))
  local problems = behaviour.check(pickles, drivers(a))
  local all = table.concat(problems, "\n")
  assert(all:match('"note" does not ask'), all)
  assert(all:match('no tool called "salute"'), all)
  assert(all:match("2 When lines"), all)
  assert(all:match("has no When"), all)
  assert(all:match("no expression matches"), all)
  for i = 1, #problems do
    assert(problems[i]:match("^line %d+:") or problems[i]:match("^the step"),
           "a problem with no line: " .. problems[i])
  end
end

function T.check_reports_a_declared_step_no_scenario_uses()
  local a = declared()
  behaviour.declare(spec, a, "the moon is full", { given = function () end })
  local pickles = assert(gherkin.pickle(FEATURE .. [[
  Scenario: it does not use it
    Given the model answers "x"
    When the agent is asked "go"
    Then it stops with answered
]]))
  local problems = behaviour.check(pickles, drivers(a))
  assert(#problems == 1 and problems[1]:match("no scenario in this feature uses it"),
         table.concat(problems, "; "))
end

-- ------------------------------------------------------------------------ reporting

function T.the_report_is_a_table_and_the_renderer_is_pure()
  local r = verify(declared(), FEATURE .. [[
  Scenario: one
    Given the model answers "x"
    When the agent is asked "go"
    Then it answers "not this"
]])
  assert(r.passed == 0 and r.failed == 1)
  local text = behaviour.report(r)
  assert(type(text) == "string")
  assert(text:match("FAIL"), text)
  assert(text:match("line 5"), text)          -- the failing line, by number
  assert(text:match("1 passed") == nil)
end

-- --------------------------------------------------- the calls that did not go through

function T.a_call_that_was_allowed_and_did_not_work_is_a_failure_not_a_refusal()
  local a = declared()
  spec.add_tool(a, "boom", { about = "raises", run = function () error("no") end })
  local s = one(a, FEATURE .. [[
  Scenario: it tried and it did not work
    Given the model calls boom with {}
    And the model answers "it did not work"
    When the agent is asked "go"
    Then it calls boom
    And the call to boom fails
]])
  assert(s.outcome == "passed", why_of(s))

  -- A refusal is a decision, not a failure, and the two do not stand in for each other.
  s = one(a, FEATURE .. [[
  Scenario: refused is not failed
    Given the human refuses file
    And the model calls file with {"text": "x"}
    And the model answers "no"
    When the agent is asked "go"
    Then the call to file fails
]])
  assert(s.outcome == "failed", s.outcome)
  assert(why_of(s):match("never called") or why_of(s):match("went through"), why_of(s))
end

function T.order_is_sayable_because_reading_before_judging_is_the_whole_point()
  local a = declared()
  local s = one(a, FEATURE .. [[
  Scenario: it notes before it files
    Given the human approves file
    And the model calls note with {"text": "one"}
    And the model calls file with {"text": "two"}
    And the model answers "done"
    When the agent is asked "go"
    Then it calls note before file
]])
  assert(s.outcome == "passed", why_of(s))

  s = one(a, FEATURE .. [[
  Scenario: and when it does not
    Given the human approves file
    And the model calls file with {"text": "two"}
    And the model calls note with {"text": "one"}
    And the model answers "done"
    When the agent is asked "go"
    Then it calls note before file
]])
  assert(s.outcome == "failed" and why_of(s):match("called .file. first"), why_of(s))
end

-- --------------------------------------------------------------------------- eval

-- A model that is real as far as the harness is concerned: it answers on its own rather
-- than from the scenario's script, and it is wrong a stated fraction of the time.
local function a_model(right_every)
  local n = 0
  return { call = function ()
    n = n + 1
    local turn_of = math.ceil(n / 2)
    if n % 2 == 1 then
      local text = (turn_of % right_every == 0) and "note" or "file"
      return { text = "", calls = { { id = "c" .. n, tool = text, args = { text = "x" } } }, stop = "calls" }
    end
    return { text = "done", calls = {}, stop = "done" }
  end }
end

function T.an_eval_drops_the_model_script_and_scores_a_rate()
  local a = declared()
  local pickles = assert(gherkin.pickle(FEATURE .. [[
  Scenario: it writes a note
    Given the model calls note with {"text": "one"}
    And the model answers "done"
    When the agent is asked "note something"
    Then it calls note
]]))
  -- Against the doubles the scripted model does exactly as it is told: a rate of 1.
  local r = behaviour.run(pickles, drivers(a), { eval = { model = a_model(1), samples = 5 } })
  local s = r.scenarios[1]
  assert(s.samples == 5 and s.rate == 1, tostring(s.rate))

  -- And a model that never calls `note` scores 0, with its failing samples kept whole.
  r = behaviour.run(pickles, drivers(a), { eval = { model = a_model(1e9), samples = 4 } })
  s = r.scenarios[1]
  assert(s.rate == 0, tostring(s.rate))
  assert(#s.failures > 0, "a failing sample kept nothing")
  assert(s.failures[1].result ~= nil, "a failing sample kept no result")
  assert(type(s.failures[1].spans) == "table", "a failing sample kept no trace")
end

function T.a_scenario_that_only_scripts_a_model_is_not_evaluable_and_is_not_scored()
  local a = declared()
  local pickles = assert(gherkin.pickle(FEATURE .. [[
  Scenario: nothing but a script
    Given the model calls note with {"text": "one"}
    And the model answers "done"
    When the agent is asked "go"
]]))
  local r = behaviour.run(pickles, drivers(a), { eval = { model = a_model(1), samples = 3 } })
  assert(r.not_evaluable == 1, tostring(r.not_evaluable))
  local s = r.scenarios[1]
  assert(s.outcome == "skipped" and s.rate == nil, s.outcome)
  assert(s.why:match("scripts the model"), s.why)
  -- And it says so in the report rather than quietly leaving it out.
  assert(behaviour.report(r):match("could not be evaluated"), behaviour.report(r))
end

function T.verify_only_is_skipped_by_an_eval_and_run_by_a_verify()
  local a = declared()
  local text = FEATURE .. [[
  @verify-only
  Scenario: pinned to a scripted model
    Given the model calls note with {"text": "one"}
    And the model answers "done"
    When the agent is asked "go"
    Then it calls note with {"text": "one"}
]]
  local pickles = assert(gherkin.pickle(text))
  local r = behaviour.run(pickles, drivers(a), { eval = { model = a_model(1), samples = 3 } })
  assert(r.not_evaluable == 1 and r.scenarios[1].why:match("@verify%-only"), r.scenarios[1].why)

  r = behaviour.run(pickles, drivers(a))
  assert(r.scenarios[1].outcome == "passed", why_of(r.scenarios[1]))
end

function T.an_eval_leaves_the_world_doubled_and_only_the_model_real()
  local a = declared()
  local pickles = assert(gherkin.pickle(FEATURE .. [[
  Scenario: the world is still made of the Given lines
    Given the file "a.txt" contains:
      """
      hello
      """
    And the model answers "done"
    When the agent is asked "go"
    Then the file "a.txt" holds:
      """
      hello
      """
    And nothing is written
]]))
  local r = behaviour.run(pickles, drivers(a), { eval = { model = a_model(1e9), samples = 2 } })
  -- The file the Given line stated is there under an eval exactly as under a verify: a
  -- real model driving real tools against real files is not an eval, it is production.
  assert(r.scenarios[1].world.fs.files["a.txt"] == "hello", "the world was not doubled")
end

function T.an_eval_answers_a_repertoire_and_not_only_a_rate()
  local a = declared()
  -- A model that notes in two runs of every three and files in the third.
  local n = 0
  local model = { call = function ()
    n = n + 1
    local turn_in_run = (n - 1) % 2 + 1
    local which = math.floor((n - 1) / 2) + 1
    if turn_in_run == 1 then
      local tool = (which % 3 == 0) and "file" or "note"
      return { text = "", calls = { { id = "c" .. n, tool = tool, args = { text = "x" } } }, stop = "calls" }
    end
    return { text = "done", calls = {}, stop = "done" }
  end }

  local pickles = assert(gherkin.pickle(FEATURE .. [[
  Scenario: it notes before it files
    Given the human approves file
    When the agent is asked "handle it"
    Then it calls note with {"text":"x"}
]]))
  local r = behaviour.run(pickles, drivers(a), { eval = { model = model, samples = 6 } })
  local s = r.scenarios[1]

  -- The rate still exists and still means what it meant.
  assert(s.samples == 6 and s.passes == 4, tostring(s.passes) .. " of " .. tostring(s.samples))

  -- And beside it, the thing a rate cannot say: how many different things it does.
  assert(s.repertoire and #s.repertoire == 2, tostring(s.repertoire and #s.repertoire))
  assert(s.repertoire[1].n == 4 and s.repertoire[2].n == 2, "the repertoire is not 4 and 2")
  local rare = table.concat(s.repertoire[2].did, "\n")
  assert(rare:match("it calls file"), rare)
  -- Each one is a scenario, not a label: it can be read and run again.
  assert(#s.repertoire[2].scenario.steps > 0)

  local text = behaviour.report(r)
  assert(text:match("2 distinct behaviours"), text)
  assert(text:match("4/6") and text:match("2/6"), text)
end

function T.one_behaviour_reports_what_nobody_stated()
  local a = declared()
  local model = { call = function (request)
    for _, m in ipairs(request.messages or {}) do
      if m.role == "tool" then return { text = "done", calls = {}, stop = "done" } end
    end
    return { text = "", calls = { { id = "c", tool = "note", args = { text = "x" } } }, stop = "calls" }
  end }
  local pickles = assert(gherkin.pickle(FEATURE .. [[
  Scenario: it notes
    When the agent is asked "handle it"
    Then it calls note with {"text":"x"}
]]))
  local r = behaviour.run(pickles, drivers(a), { eval = { model = model, samples = 3 } })
  local s = r.scenarios[1]
  assert(#s.repertoire == 1, tostring(#s.repertoire))
  assert(#s.agreement.unstated > 0, "nothing was unstated, which cannot be right")
  local text = behaviour.report(r)
  assert(text:match("happened, and nobody said"), text)
end

function T.a_scenario_opens_a_span_and_the_whole_run_hangs_under_it()
  local a = declared()
  local s = one(a, FEATURE .. [[
  Scenario: the join
    Given the human refuses file
    And the model calls file with {"text": "x"}
    And the model answers "no"
    When the agent is asked "go"
    Then the call to file is refused
]])
  assert(type(s.spans) == "table" and #s.spans > 1, "no spans on the scenario")

  -- The scenario is the root, and it names itself, so a trace in a collector is
  -- attributable to the sentence in the feature file that asked for it.
  local root = s.spans[1]
  assert(root.parent == nil and root.name == "malleable.scenario the join", root.name)
  assert(root.attrs["malleable.outcome"] == "passed", tostring(root.attrs["malleable.outcome"]))

  -- Exactly one root, and everything else under it.
  local roots = 0
  for i = 1, #s.spans do if s.spans[i].parent == nil then roots = roots + 1 end end
  assert(roots == 1, roots .. " roots")

  local run = nil
  for i = 1, #s.spans do
    if s.spans[i].name:match("^invoke_agent") then run = s.spans[i] end
  end
  assert(run and run.parent == root.id, "the run does not hang under the scenario")

  -- And a scenario that makes no run carries no spans rather than an empty tree.
  local none = one(a, FEATURE .. [[
  Scenario: nothing runs
    When the declaration is loaded
    Then the declaration is sound
]])
  assert(none.spans == nil, "a check-only scenario recorded a trace")
end

function T.wrong_shapes_raise()
  assert(not pcall(behaviour.run, 7, {}))
end

function T.a_then_line_that_reads_only_the_script_is_labelled_and_the_scenario_is_still_scored()
  local a = declared()
  local pickles = assert(gherkin.pickle(FEATURE .. [[
  Scenario: one line reads the script, one reads the world
    Given the file "brief.md" contains:
      """
      The answer is forty-two.
      """
    And the model calls note with {"text": "one"}
    And the model calls note with {"text": "two"}
    And the model answers "dark red"
    When the agent is asked "note something"
    Then it calls note 2 times
    And it answers "dark red"
    And the answer says "forty-two"
    And it calls note

  Scenario: every line reads the script
    Given the model calls note with {"text": "one"}
    And the model answers "dark red"
    When the agent is asked "go"
    Then it answers "dark red"
]]))
  local r = behaviour.run(pickles, drivers(a), { eval = { model = a_model(1), samples = 2 } })
  local s = r.scenarios[1]
  assert(s.rate ~= nil, "the first scenario is still scored")
  local reads = assert(s.reads_script, "no reads_script on the scored scenario")
  assert(#reads == 2, "expected two labelled lines, got " .. #reads)
  assert(reads[1].text == "it calls note 2 times" and reads[1].why:match("how many times"), reads[1].why)
  assert(reads[2].text == 'it answers "dark red"' and reads[2].from ~= nil, reads[2].why)
  assert(behaviour.report(r):match("reads the script:"), behaviour.report(r))
  -- The line whose value a world Given says, and the line that names only a tool, are not labelled.
  -- A scenario every one of whose Then lines reads the script is still scored, and says so.
  local second = r.scenarios[2]
  assert(second.rate ~= nil and second.reads_all == true, tostring(second.outcome))
  assert(r.not_evaluable == 0, tostring(r.not_evaluable))
end


function T.a_rate_carries_its_interval_and_the_report_prints_it()
  local lo, hi = behaviour.interval(3, 3)
  assert(lo > 0.43 and lo < 0.45 and hi == 1, lo .. " " .. hi)
  lo, hi = behaviour.interval(9, 10)
  assert(lo > 0.59 and lo < 0.61 and hi > 0.97 and hi < 0.99, lo .. " " .. hi)
  lo, hi = behaviour.interval(0, 3)
  assert(lo == 0 and hi > 0.55 and hi < 0.57, lo .. " " .. hi)
  lo, hi = behaviour.interval(0, 0)
  assert(lo == 0 and hi == 1)
  local text = behaviour.report({ passed = 1, failed = 0, undefined = 0, broken = 0, skipped = 0, scenarios = { { name = "x", line = 1, outcome = "passed", samples = 10, passes = 9, rate = 0.9, steps = {} } } })
  assert(text:find("9/10 (0.60-0.98)", 1, true), text)
end

return T
