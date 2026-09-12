-- observe: a run, read back out as behaviour.
--
-- The test that matters is the ROUND TRIP, and it is the last one here: observing the
-- worked example's runs yields scenarios that pass when run back. If an observation is
-- not faithful enough to re-run, it is not behaviour, it is a summary -- and a summary
-- can be wrong in ways nothing catches.
--
-- The rest guard the direction: every string this module can emit is one a person writes,
-- none is diagnostic, and what it has no word for is recorded as a gap rather than
-- approximated.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local observe   = require "observe"
local behaviour = require "behaviour"
local gherkin   = require "gherkin"
local spec      = require "spec"
local turn      = require "turn"
local cli       = require "cli"

local T = {}

local function declared()
  local a = spec.new()
  a.name, a.model = "scribe", "test:scripted"
  spec.add_tool(a, "note", {
    about = "Write a note",
    args = { text = spec.types.string("what") },
    run = function (c) return c.fs.write("note.txt", c.args.text) and "written" or "no" end,
  })
  spec.add_tool(a, "file", {
    about = "File it",
    ask = true,
    args = { text = spec.types.string("what") },
    run = function () return "filed" end,
  })
  return a
end

local function drivers(a)
  return cli.drivers(a, function (prompt, port, opts) return turn.run(a, prompt, port, opts) end)
end

local function verify(a, text, opts)
  local pickles = assert(gherkin.pickle(text))
  return behaviour.run(pickles, drivers(a), opts)
end

local FEATURE = "Feature: f\n"

local function observed(a, text)
  local r = verify(a, text)
  local s = r.scenarios[1]
  assert(s.record, "the scenario recorded nothing to observe: " .. s.outcome)
  local pickle, why, gaps = observe.run(s.record)
  assert(pickle, tostring(why))
  return pickle, gaps, s
end

local function texts(pickle)
  local out = {}
  for i = 1, #pickle.steps do out[i] = pickle.steps[i].text end
  return out
end

local function has_line(pickle, want)
  for _, t in ipairs(texts(pickle)) do if t == want then return true end end
  return false
end

-- ------------------------------------------------------------------- the direction

function T.an_observer_speaks_only_the_authored_vocabulary()
  -- Every expression the observer can emit is one `behaviour.steps()` holds, and none is
  -- diagnostic. This is the rule the whole direction rests on: the moment the observer
  -- may say "the trace shows", it says that for everything it has no word for.
  local vocabulary, diagnostic = {}, {}
  for _, e in ipairs(behaviour.steps()) do
    vocabulary[#vocabulary + 1] = e.expr
    if e.diagnostic then diagnostic[e.expr] = true end
  end

  local compiled = {}
  for i = 1, #vocabulary do compiled[i] = { expr = assert(gherkin.expr(vocabulary[i])), text = vocabulary[i] } end

  -- A run that reaches as much of the observer as one run can.
  local a = declared()
  local pickle = observed(a, FEATURE .. [[
  Scenario: a lot at once
    Given the file "a.txt" contains:
      """
      hello
      """
    And the command "echo hi" answers 0 and:
      """
      hi
      """
    And the clock reads "2026-06-01T09:00:00Z"
    And the budget is 6
    And the human refuses file
    And the model calls note with {"text": "one"}
    And the model calls file with {"text": "two"}
    And the model answers "done"
    When the agent is asked "go"
    Then it stops with answered
]])

  for _, line in ipairs(texts(pickle)) do
    local matched = nil
    for i = 1, #compiled do
      if compiled[i].expr.match(line) then matched = compiled[i].text break end
    end
    assert(matched, "the observer emitted a line no expression reads: " .. line)
    assert(not diagnostic[matched],
           "the observer emitted a DIAGNOSTIC expression: " .. matched .. "  <- " .. line)
  end

  -- And the words that would mean it had gone the wrong way are absent entirely.
  local whole = table.concat(texts(pickle), "\n")
  for _, noun in ipairs({ "the trace", "the span", "the log records" }) do
    assert(not whole:find(noun, 1, true), "the observer said " .. noun)
  end
end

function T.what_it_has_no_word_for_is_a_gap_and_not_an_approximation()
  local a = declared()
  spec.add_skill(a, "triage", { about = "how we triage", does = "1. reproduce" })
  local r = verify(a, FEATURE .. [[
  Scenario: a world with a skill in it
    Given the workspace keeps a skill "deploy":
      """
      1. tag it
      """
    And the model answers "done"
    When the agent is asked "go"
    Then it stops with answered
]])
  local pickle, why, gaps = observe.run(r.scenarios[1].record)
  assert(pickle, tostring(why))
  assert(#gaps == 1, #gaps .. " gaps")
  assert(gaps[1].wanted:match("skill"), gaps[1].wanted)
  -- And nothing was invented to paper over it.
  for _, line in ipairs(texts(pickle)) do
    assert(not line:match("skill"), "the observer invented a line for a skill: " .. line)
  end

  local collapsed = observe.gaps({ gaps[1], gaps[1], { saw = "x", wanted = "another thing" } })
  assert(#collapsed == 2 and (collapsed[1].n == 2 or collapsed[2].n == 2), "gaps do not collapse")
end

-- ------------------------------------------------------------ what a scenario says

function T.every_call_is_a_line_rather_than_a_count()
  local a = declared()
  local pickle = observed(a, FEATURE .. [[
  Scenario: three notes
    Given the model calls note with {"text": "a"}
    And the model calls note with {"text": "b"}
    And the model calls note with {"text": "c"}
    And the model answers "done"
    When the agent is asked "go"
    Then it calls note 3 times
]])
  local n = 0
  for _, t in ipairs(texts(pickle)) do
    if t:match('^it calls note with') then n = n + 1 end
  end
  -- Summarising three calls into a count would lose the arguments, which are half of
  -- what happened.
  assert(n == 3, n .. " observed call lines for three calls")
  assert(has_line(pickle, 'it calls note with {"text":"a"}'), table.concat(texts(pickle), "\n"))
end

function T.a_refused_call_says_the_gate_was_asked_and_that_it_was_refused()
  local a = declared()
  local pickle = observed(a, FEATURE .. [[
  Scenario: refused
    Given the human refuses file
    And the model calls file with {"text": "x"}
    And the model answers "no"
    When the agent is asked "go"
    Then the call to file is refused
]])
  assert(has_line(pickle, "the human is asked about file"), table.concat(texts(pickle), "\n"))
  assert(has_line(pickle, "the call to file is refused"))
  assert(has_line(pickle, "nothing is written"))
end

function T.a_run_that_writes_says_what_the_file_holds()
  local a = declared()
  local pickle = observed(a, FEATURE .. [[
  Scenario: it writes
    Given the model calls note with {"text": "kept"}
    And the model answers "done"
    When the agent is asked "go"
    Then it stops with answered
]])
  assert(not has_line(pickle, "nothing is written"), "it wrote and said nothing was written")
  local said = nil
  for i = 1, #pickle.steps do
    if pickle.steps[i].text == 'the file "note.txt" holds:' then said = pickle.steps[i].doc end
  end
  assert(said == "kept", tostring(said))
end

function T.a_multi_line_value_stays_on_one_line()
  -- Lua's %q escapes a newline as a backslash and a real newline, which splits the step
  -- in half and leaves the rest as a line nobody can read. A step is one line.
  local a = declared()
  local pickle = observed(a, FEATURE .. [[
  Scenario: a newline in an argument
    Given the model calls note with {"text": "one\ntwo"}
    And the model answers "done"
    When the agent is asked "go"
    Then it stops with answered
]])
  assert(has_line(pickle, 'it calls note with {"text":"one\\ntwo"}'),
         table.concat(texts(pickle), "\n"))
end

function T.a_scenario_that_only_checks_is_observable_too()
  local a = declared()
  local pickle = observed(a, FEATURE .. [[
  Scenario: it loads
    When the declaration is loaded
    Then the declaration is sound
]])
  assert(has_line(pickle, "the declaration is sound"), table.concat(texts(pickle), "\n"))
end

-- --------------------------------------------------------------------- agreement

function T.a_run_that_does_what_was_stated_agrees_and_adds_nothing()
  local a = declared()
  local text = FEATURE .. [[
  Scenario: exactly as asked
    Given the model calls note with {"text": "one"}
    And the model answers "done"
    When the agent is asked "go"
    Then it stops with answered
    And it takes 2 steps
    And it calls note with {"text":"one"}
    And the file "note.txt" holds:
      """
      one
      """
    And it answers "done"
]]
  local stated = assert(gherkin.pickle(text))[1]
  local pickle = observed(a, text)
  local agreed = observe.agreement(stated, pickle)
  assert(#agreed.missing == 0, table.concat(agreed.missing, "; "))
  assert(#agreed.held == 5, #agreed.held .. " held")
end

function T.the_lines_the_run_did_that_nobody_stated_are_the_point()
  local a = declared()
  local text = FEATURE .. [[
  Scenario: it was asked about one thing and did two
    Given the human approves file
    And the model calls note with {"text": "one"}
    And the model calls file with {"text": "two"}
    And the model answers "done"
    When the agent is asked "go"
    Then it calls note with {"text":"one"}
]]
  local stated = assert(gherkin.pickle(text))[1]
  local pickle = observed(a, text)
  local agreed = observe.agreement(stated, pickle)

  assert(#agreed.missing == 0, table.concat(agreed.missing, "; "))
  assert(agreed.agreed == false, "a run that did more than was stated read as full agreement")

  local unstated = table.concat(agreed.unstated, "\n")
  -- The call nobody mentioned, and the gate question nobody mentioned either.
  assert(unstated:match('it calls file with'), unstated)
  assert(unstated:match("the human is asked about file"), unstated)

  local rendered = observe.agreement_text(agreed)
  assert(rendered:match("happened, and nobody said"), rendered)
end

function T.a_stated_line_that_did_not_happen_is_missing()
  local a = declared()
  local stated = assert(gherkin.pickle(FEATURE .. [[
  Scenario: it was asked to file
    Given the model answers "done"
    When the agent is asked "go"
    Then it calls file with {"text":"x"}
]]))[1]
  local pickle = observed(a, FEATURE .. [[
  Scenario: and it did not
    Given the model answers "done"
    When the agent is asked "go"
    Then it stops with answered
]])
  local agreed = observe.agreement(stated, pickle)
  assert(#agreed.missing == 1 and agreed.missing[1]:match("it calls file"),
         table.concat(agreed.missing, "; "))
end

-- -------------------------------------------------------------------- repertoire

function T.a_repertoire_is_the_distinct_behaviours_with_a_rate_each()
  local a = declared()
  local function run_with(text)
    local pickle = observed(a, FEATURE .. [[
  Scenario: s
    Given the model calls ]] .. text .. [[ with {"text": "x"}
    And the model answers "done"
    When the agent is asked "go"
    Then it stops with answered
]])
    return pickle
  end

  local always = {}
  for _ = 1, 4 do always[#always + 1] = run_with("note") end
  local one = observe.repertoire(always)
  assert(#one == 1 and one[1].n == 4 and one[1].rate == 1, #one .. " behaviours")

  local mixed = { run_with("note"), run_with("file"), run_with("note"), run_with("file") }
  local two = observe.repertoire(mixed)
  assert(#two == 2, #two .. " behaviours")
  assert(two[1].rate == 0.5 and two[2].rate == 0.5, "rates are not halves")
  -- Each one is a scenario that can be read and re-run, not a label.
  assert(type(two[1].scenario) == "table" and #two[1].scenario.steps > 0)

  local rendered = observe.repertoire_text(two, 4)
  assert(rendered:match("2 distinct behaviours in 4 runs"), rendered)
end

function T.two_runs_that_differ_only_in_the_models_wording_are_one_behaviour()
  local a = declared()
  local function with_answer(answer)
    -- One value, not three: `observed` also answers gaps and the scenario, and a call in
    -- a list constructor expands all of them.
    local pickle = observed(a, FEATURE .. [[
  Scenario: s
    Given the model calls note with {"text": "x"}
    And the model answers "]] .. answer .. [["
    When the agent is asked "go"
    Then it stops with answered
]])
    return pickle
  end
  -- The answer differs, and the answer IS observed -- so this is the honest test of what
  -- the collapsing is over. It is over the Then lines, and `it answers` is one of them,
  -- so these are two behaviours. Stated here rather than glossed, because the opposite
  -- would need a model to decide two wordings meant the same thing, and no model judges.
  local r = observe.repertoire({ with_answer("all done"), with_answer("finished") })
  assert(#r == 2, #r .. " behaviours for two different answers")

  -- What IS collapsed: the same run, twice.
  local same = observe.repertoire({ with_answer("done"), with_answer("done") })
  assert(#same == 1 and same[1].n == 2, #same .. " behaviours for one repeated run")
end

-- ------------------------------------------------------------------ the round trip

function T.the_worked_example_survives_being_observed_and_run_again()
  -- The acceptance. Observing every run of `example/reviewer.feature` yields scenarios
  -- that pass when run back through the verifier.
  local agent = require "agent"

  -- The prefix is one table for the whole process, and `example_test` has already
  -- declared this same agent onto it. Started over here, and again at the end, so this
  -- test neither inherits a declaration nor leaves one.
  agent.reset()

  -- The declaration, loaded without letting it run itself: `arg` is what its `is_main`
  -- reads, so an empty one makes the file declare and stop.
  local chunk = assert(loadfile(here .. "/fixtures/examples/reviewer.lua"))
  local saved = arg
  arg = {}
  local ok, why = pcall(chunk)
  arg = saved
  assert(ok, "the worked example does not load: " .. tostring(why))

  local f = assert(io.open(here .. "/fixtures/examples/reviewer.feature", "rb"))
  local stated_text = f:read("*a")
  f:close()

  local stated = assert(agent.verify(stated_text))
  assert(stated.ok and stated.failed == 0 and stated.undefined == 0,
         "the stated feature does not pass to begin with")

  local parts, gaps = {}, {}
  for _, s in ipairs(stated.scenarios) do
    assert(s.record, "no observation for: " .. s.name)
    local text, some = observe.scenario(s.record, "observed — " .. s.name)
    parts[#parts + 1] = text
    for _, g in ipairs(some) do gaps[#gaps + 1] = g end
  end

  local back = assert(agent.verify("Feature: observed\n\n" .. table.concat(parts, "\n")))
  local lost = string.format("the round trip lost something: %d passed, %d failed, %d undefined, %d broken\n%s",
    back.passed, back.failed, back.undefined, back.broken, behaviour.report(back))
  local kept = back.passed == #stated.scenarios and back.failed == 0
               and back.undefined == 0 and back.broken == 0
  local no_gaps = #gaps == 0
  agent.reset()
  assert(kept, lost)
  assert(no_gaps, "the worked example produced gaps: " .. #gaps)
end

-- A shell-first agent, observed. The acceptance for mar-ykcc.
--
-- What the run did with a shell is rendered as BEHAVIOUR -- `it runs a command that
-- publishes` -- beside the call that did it, and the whole thing passes when it is run
-- again. A command the vocabulary cannot name is a gap and is counted; it is never
-- rendered as a quoted string, which would put the command line into a file somebody
-- reads and check nothing.
function T.a_run_made_of_shell_commands_observes_as_behaviour_and_runs_again()
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "shipper"; agent.model "test:m"
  agent.shell { root = ".", about = "Run one command in the workspace." }

  local world = {
    clock = { at = 1757462400 },
    ask = { shell = true },
    sh = { ["sh -c lua run-tests.lua"]      = { code = 0, out = "602 passed\n" },
           ["sh -c git status --porcelain"] = { code = 0, out = "" },
           ["sh -c git push origin main"]   = { code = 0, out = "pushed\n" } },
    model = { { tool = "shell", args = { command = "git status --porcelain" } },
              { tool = "shell", args = { command = "lua run-tests.lua" } },
              { tool = "shell", args = { command = "git push origin main" } },
              { text = "green, and shipped" } },
  }

  local stated = assert(agent.verify([[
Feature: shipping

  Scenario: it does not ship what it has not tested
    Given the human approves shell
    And the model calls shell with { "command": "git status --porcelain" }
    And the model calls shell with { "command": "lua run-tests.lua" }
    And the model calls shell with { "command": "git push origin main" }
    And the model answers "green, and shipped"
    And the command "git status --porcelain" answers 0 and:
      """
      """
    And the command "lua run-tests.lua" answers 0 and:
      """
      602 passed
      """
    And the command "git push origin main" answers 0 and:
      """
      pushed
      """
    When the agent is asked "ship it"
    Then it runs a command that tests
    And it runs a command that publishes
    And it runs no command that deletes
    And it calls shell before shell
]]))
  assert(stated.ok and stated.failed == 0 and stated.undefined == 0,
         behaviour.report(stated))

  -- Observed: the same run, written back out.
  local s = stated.scenarios[1]
  assert(s.record, "no observation")
  local text, gaps = observe.scenario(s.record, "observed — shipping")
  assert(#gaps == 0, "a command the vocabulary could not name: " .. #gaps)
  assert(text:find("it runs a command that tests", 1, true), text)
  assert(text:find("it runs a command that publishes", 1, true), text)
  assert(text:find("it runs a command that inspects", 1, true), text)

  -- And it runs again. The round trip is the acceptance: an observation that cannot be
  -- re-run is a rendering, not a scenario.
  local back = assert(agent.verify("Feature: observed\n\n" .. text))
  assert(back.passed == 1 and back.failed == 0 and back.undefined == 0 and back.broken == 0,
         behaviour.report(back))
  agent.reset()
  local _ = world
end

function T.a_command_the_vocabulary_cannot_name_is_a_gap_not_a_quoted_string()
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "shipper"; agent.model "test:m"
  agent.shell { root = ".", about = "Run one command in the workspace." }

  local stated = assert(agent.verify([[
Feature: something nobody has a word for

  Scenario: it runs something unheard of
    Given the human approves shell
    And the model calls shell with { "command": "frobnicate --hard" }
    And the model answers "done"
    And the command "frobnicate --hard" answers 0 and:
      """
      ok
      """
    When the agent is asked "frobnicate"
    Then it calls shell
]]))
  assert(stated.ok, behaviour.report(stated))

  local text, gaps = observe.scenario(stated.scenarios[1].record, "observed")
  assert(#gaps == 1, #gaps .. " gaps, and there is exactly one unnameable command")
  assert(gaps[1].wanted:find("spec/command.md", 1, true), gaps[1].wanted)
  -- The command itself is NOT in the Then half. It is in the Given half, because that is
  -- the world the scenario replays; what it DID is what the vocabulary has no word for,
  -- and a quoted command line standing in for a term would check nothing.
  local then_half = text:match("Then.*$") or ""
  assert(not then_half:find("frobnicate", 1, true), then_half)
  agent.reset()
end

-- ------------------------------------------------- the repertoire, kept and compared
--
-- A repertoire is behavioural MEMORY: not text to retrieve, but what this agent actually
-- does, kept in a form that can be re-run and compared. It is the safety rail everything
-- self-editing depends on, because that class of system fails silently -- the pass rate
-- goes up while the repertoire shrinks, and nothing else here would notice.

local function two_behaviours()
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "keeper"; agent.model "test:m"
  agent.shell { root = ".", about = "Run one command." }
  local report = assert(agent.verify([[
Feature: tidying

  Scenario: it looks
    Given the human approves shell
    And the model calls shell with { "command": "ls notes" }
    And the model answers "looked"
    And the command "ls notes" answers 0 and:
      """
      a.md
      """
    When the agent is asked "tidy"
    Then it calls shell

  Scenario: it does not look
    Given the model answers "I did not need to"
    When the agent is asked "tidy"
    Then it never calls shell
]]))
  assert(report.ok and report.failed == 0, behaviour.report(report))
  local seen = {}
  for _, sc in ipairs(report.scenarios) do
    local pickle = select(1, observe.run(sc.record))
    if pickle then seen[#seen + 1] = pickle end
  end
  agent.reset()
  return observe.repertoire(seen)
end

function T.a_repertoire_is_kept_as_a_feature_file_and_reads_back_the_same()
  local r = two_behaviours()
  assert(#r == 2, #r .. " distinct behaviours")

  local text, total = observe.repertoire_feature(r, "keeper")
  assert(total == 2, total)
  assert(text:find("@seen-1-of-2", 1, true), text)
  -- A feature file, not a new format: the reader and the runner that already exist read
  -- it, a person reads it, and git diff says what changed.
  assert(text:find("Feature: keeper", 1, true))
  assert(text:find("\n    When the agent is asked", 1, true), "the phases were not rebuilt")
  assert(text:find("\n    Then ", 1, true), "the first Then reads as an And")

  local back, said = assert(observe.repertoire_read(text))
  assert(said == 2, said)
  assert(#back == #r, #back .. " read back from " .. #r)
  -- The same SHAPE, so a stored repertoire and a fresh one are the same kind of thing
  -- and the diff cannot tell them apart. That is what makes the memory usable.
  for i = 1, #r do
    assert(back[i].n == r[i].n, "count " .. i)
    assert(table.concat(back[i].did, "\n") == table.concat(r[i].did, "\n"), "behaviour " .. i)
    assert(math.abs(back[i].rate - r[i].rate) < 0.0001, "rate " .. i)
  end

  -- And it round trips again, byte for byte.
  assert(observe.repertoire_feature(back, "keeper") == text, "the second write differs")
end

function T.a_lost_behaviour_is_reported_as_loudly_as_a_failure()
  local r = two_behaviours()
  local fewer = { r[1] }

  local d = observe.repertoire_diff(r, fewer)
  assert(#d.lost == 1, #d.lost .. " lost")
  assert(#d.gained == 0 and #d.kept == 1)
  local text = observe.repertoire_diff_text(d)
  assert(text:find("1 LOST", 1, true), text)
  assert(text:find("no longer does", 1, true), text)

  -- The other direction is a gain, and gains are not shouted about.
  local back = observe.repertoire_diff(fewer, r)
  assert(#back.gained == 1 and #back.lost == 0)
  assert(not observe.repertoire_diff_text(back):find("LOST", 1, true))

  -- Nothing changed is said plainly, so a quiet diff is not mistaken for a broken one.
  local same = observe.repertoire_diff_text(observe.repertoire_diff(r, r))
  assert(same:find("nothing gained, nothing lost", 1, true), same)
end

function T.a_kept_behaviour_says_when_its_rate_moved()
  local r = two_behaviours()
  local shifted = {}
  for i = 1, #r do
    shifted[i] = { n = r[i].n, rate = r[i].rate, did = r[i].did, scenario = r[i].scenario }
  end
  shifted[1].rate = 0.9
  local text = observe.repertoire_diff_text(observe.repertoire_diff(r, shifted))
  assert(text:find("50%% %-> 90%%"), text)
end

function T.a_repertoire_that_does_not_parse_is_a_sentence_and_not_a_raise()
  local none, why = observe.repertoire_read("Feature: broken\n  Scenario: a\n    Given\n\x00")
  if none == nil then assert(why:match("does not parse"), why) end
  -- An empty file is an empty repertoire, not an error: an agent that did nothing has
  -- a repertoire of nothing, and that is a fact rather than a fault.
  local empty = assert(observe.repertoire_read("Feature: nothing\n"))
  assert(#empty == 0)
end

function T.wrong_shapes_raise()
  assert(not pcall(observe.scenario, 7))
  assert(not pcall(observe.scenario, {}))
  assert(not pcall(observe.repertoire, "no"))
  assert(not pcall(observe.repertoire_feature, 7))
  assert(not pcall(observe.repertoire_read, 7))
  assert(not pcall(observe.repertoire_diff, {}, 7))
  assert(not pcall(observe.repertoire_diff_text, {}))
  assert(not pcall(observe.pickle_text, 7))
  assert(not pcall(observe.agreement, {}, 7))
end

function T.a_run_still_going_is_observed_as_the_scenario_so_far()
  local record = { prompt = "what do my notes say?", result = { steps = 2, calls = {
    { id = "1", tool = "list", args = { dir = "notes" }, step = 1, ok = true },
    { id = "2", tool = "read", args = { path = "notes/a.md" }, step = 2 },
  } } }
  local text, gaps = observe.live(record, "j1 notebook: what do my notes say?")
  assert(#gaps == 0)
  assert(text:find("Scenario: j1 notebook: what do my notes say?", 1, true))
  assert(text:find('Given the model calls list with {"dir":"notes"}', 1, true), text)
  assert(text:find('And the model calls read with {"path":"notes/a.md"}', 1, true), text)
  assert(text:find('When the agent is asked "what do my notes say?"', 1, true), text)
  assert(text:find('Then it calls list with {"dir":"notes"}', 1, true), text)
  assert(not text:find("it stops with", 1, true), "a run still going has no stop")
  -- once it has stopped, the stop and the steps come first among the Then lines
  record.result.stop, record.result.answer = "answered", "two notes"
  record.log = { order = { "notes/b.md" }, files = { ["notes/b.md"] = { wrote = true, after = "hello\n" } } }
  text = observe.live(record)
  assert(text:find('And the model answers "two notes"', 1, true), text)
  assert(text:find("Then it stops with answered\n    And it takes 2 steps", 1, true), text)
  assert(text:find('And the file "notes/b.md" holds:\n      """\n      hello', 1, true), text)
  -- what it writes is real Gherkin
  local pickles, why = gherkin.pickle("Feature: observed\n" .. text)
  assert(pickles, why)
end

return T
