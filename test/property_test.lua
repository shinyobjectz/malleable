-- src/property.lua: a scenario that holds for every world (spec/property.md).

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local agent    = require "agent"
local property = require "property"

local T = {}

-- A declaration and the drivers `behaviour` needs for it, the way `--verify` builds them.
local function declared(src)
  local decl = assert(agent.cli.load("agent.lua", { read = function () return src end }))
  local drivers = agent.cli.drivers(decl, function (prompt, port, ropts)
    return agent.run(decl, prompt, port, { budget = ropts and ropts.budget or decl.budget })
  end)
  return decl, drivers
end

-- A tool that writes and asks, and one that writes without asking: the planted bug.
local function notes(gated)
  return table.concat({
    'agent.name "notes"',
    'agent.model "test:scripted"',
    "agent.budget(6)",
    'agent.tool "look" { about = "Read the notes.", args = { path = agent.string "a path" },',
    '  run = function (c) return c.fs.read(c.args.path) or "" end }',
    'agent.tool "note" { about = "Add a note.",' .. (gated and " ask = true," or ""),
    '  args = { text = agent.string "the note", n = agent.number "how many", loud = agent.boolean_opt "shout" },',
    '  run = function (c) c.fs.write("notes.md", c.args.text); return "ok" end }',
  }, "\n")
end

local FEATURE = [[
Feature: notes
  Background:
    Given the file "notes.md" contains:
      """
      one
      """

  @property
  Scenario: whatever the model says, nothing is written without a yes
    Given the human refuses note
    And the model says anything its tools allow
    When the agent is asked "Take a note."
    Then nothing is written

  Scenario: a plain one
    Given the model answers "fine"
    When the agent is asked "hello"
    Then it stops with answered
]]

local function pickles(text)
  return assert(agent.gherkin.pickle(text or FEATURE))
end

function T.the_generator_is_the_minimal_standard_one()
  local g = property.generator(1)
  local want = { 16807, 282475249, 1622650073, 984943658, 1144108930 }
  for i = 1, #want do assert(g.next() == want[i], "draw " .. i .. " differs") end
  local a, b = property.generator(7), property.generator(7)
  for _ = 1, 100 do assert(a.int(-5, 5) == b.int(-5, 5)) end
  local h = property.generator(3)
  for _ = 1, 1000 do
    local n = h.int(2, 4)
    assert(n >= 2 and n <= 4 and n == math.floor(n))
  end
end

function T.dates_cover_the_century()
  assert(property.date_of(0, 0) == "2000-01-01T00:00:00Z")
  assert(property.date_of(59, 0) == "2000-02-29T00:00:00Z")
  assert(property.date_of(36521, 1439) == "2099-12-28T23:59:00Z")
end

function T.a_property_is_a_scenario_tagged_property()
  local all = pickles()
  local plain, props = property.split(all)
  assert(#plain == 1 and #props == 1)
  assert(property.is(props[1]) and not property.is(plain[1]))
end

function T.to_any_other_reader_a_property_is_undefined_not_failed()
  local _, drivers = declared(notes(true))
  local _, props = property.split(pickles())
  local report = agent.behaviour.run(props, drivers, {})
  assert(report.undefined == 1 and report.failed == 0, agent.behaviour.report(report))
end

function T.tools_are_read_from_the_declaration_in_order()
  local decl = declared(notes(true))
  local tools = property.tools_of(decl)
  assert(#tools == 2 and tools[1].name == "look" and tools[2].name == "note")
  local args = tools[2].args
  assert(args[1].name == "loud" and args[1].kind == "boolean" and args[1].required == false)
  assert(args[2].name == "n" and args[2].kind == "number" and args[2].required == true)
  assert(args[3].name == "text" and args[3].kind == "string")
end

function T.a_gated_tool_holds_across_many_worlds()
  local decl, drivers = declared(notes(true))
  local _, props = property.split(pickles())
  local seen, calls = 0, 0
  local report = property.run(props, drivers, { declaration = decl, runs = 300, seed = 5,
    on_run = function (s)
      seen = seen + 1
      calls = calls + #(s.result and s.result.calls or {})
    end })
  local e = report.properties[1]
  assert(report.ok and e.outcome == "passed" and e.passed == 300, property.text(report))
  assert(seen == 300, "on_run heard " .. seen)
  assert(calls > 300, "the generated models called only " .. calls .. " tools in 300 runs")
end

function T.an_ungated_tool_fails_and_shrinks_to_one_call()
  local decl, drivers = declared(notes(false))
  local _, props = property.split(pickles())
  local report = property.run(props, drivers, { declaration = decl, runs = 300, seed = 1 })
  local e = report.properties[1]
  assert(not report.ok and e.outcome == "failed", property.text(report))
  assert(e.generated == 1, "shrunk to " .. tostring(e.generated) .. " lines:\n" .. e.counterexample)
  assert(e.counterexample:find('And the model calls note with {"n":0,"text":""}', 1, true), e.counterexample)
  assert(e.counterexample:find("Scenario: counterexample to", 1, true))
  assert(e.counterexample:find("Then nothing is written\n    # did not hold:", 1, true), e.counterexample)
  local text = property.text(report)
  assert(text:find("seed 1, run " .. e.run, 1, true), text)
end

function T.the_counterexample_runs_as_a_plain_scenario()
  local decl, drivers = declared(notes(false))
  local _, props = property.split(pickles())
  local e = property.run(props, drivers, { declaration = decl, runs = 300 }).properties[1]
  local body = e.counterexample:gsub("\n%s*# did not hold:[^\n]*", "")
  local again = assert(agent.gherkin.pickle("Feature: pasted\n\n" .. body:gsub("\n", "\n  "):gsub("^", "  ")))
  local report = agent.behaviour.run(again, drivers, {})
  assert(report.failed == 1, agent.behaviour.report(report))
end

function T.the_same_seed_finds_the_same_counterexample()
  local decl, drivers = declared(notes(false))
  local _, props = property.split(pickles())
  local a = property.run(props, drivers, { declaration = decl, runs = 200, seed = 9 }).properties[1]
  local b = property.run(props, drivers, { declaration = decl, runs = 200, seed = 9 }).properties[1]
  -- Everything but the reason behaviour gives, which for "nothing is written" names a
  -- table by its address today (src/behaviour.lua quotes fs.wrote[1], a { path, text }).
  local function lines(e) return (e.counterexample:gsub("# did not hold:[^\n]*", "")) end
  assert(a.run == b.run and a.run_seed == b.run_seed and lines(a) == lines(b), lines(a) .. "\n--\n" .. lines(b))
end

function T.keys_need_the_press_step_and_are_skipped_without_it()
  local decl, drivers = declared(notes(true))
  local _, props = property.split(pickles([[
Feature: keys
  @property
  Scenario: pressing anything
    Given the person presses any keys
    When the agent is asked "x"
    Then it stops with answered
]]))
  local e = property.run(props, drivers, { declaration = decl }).properties[1]
  assert(e.outcome == "skipped" and e.why:find("the person presses {string}", 1, true), e.why)
end

function T.the_store_is_reserved()
  local decl, drivers = declared(notes(true))
  local _, props = property.split(pickles([[
Feature: rows
  @property
  Scenario: rows
    Given any rows in the store "habits"
    When the agent is asked "x"
    Then it stops with answered
]]))
  local report = property.run(props, drivers, { declaration = decl })
  assert(not report.ok and report.properties[1].outcome == "broken")
end

function T.dates_and_files_expand_into_given_lines()
  local decl, drivers = declared(notes(true))
  local _, props = property.split(pickles([[
Feature: world
  @property
  Scenario: any date, any file
    Given the clock reads any date
    And the file "a.txt" holds anything
    And the model answers "fine"
    When the agent is asked "x"
    Then it stops with answered
]]))
  local steps = {}
  local report = property.run(props, drivers, { declaration = decl, runs = 20,
    on_run = function (_, p) if #steps == 0 then steps = p.steps end end })
  assert(report.ok, property.text(report))
  assert(steps[1].text:match('^the clock reads "%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:00Z"$'), steps[1].text)
  assert(steps[2].text == 'the file "a.txt" contains:' and type(steps[2].doc) == "string")
end

function T.a_property_with_no_any_runs_once()
  local decl, drivers = declared(notes(true))
  local _, props = property.split(pickles([[
Feature: once
  @property
  Scenario: once
    Given the model answers "fine"
    When the agent is asked "x"
    Then it stops with answered
]]))
  local e = property.run(props, drivers, { declaration = decl, runs = 50 }).properties[1]
  assert(e.outcome == "passed" and e.runs == 1)
end

return T
