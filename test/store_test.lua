-- store, requirements and edits at the gate: what a program keeps, what a tool requires
-- before it runs, and what a person may change before they approve.
--
-- The three are one test file because they meet in one place: a tool that writes the
-- store is the tool whose call a requirement stops and whose arguments a person edits,
-- and a feature reads all three back (spec/store.md; spec/turn.md, "Requirements" and
-- "Edits at the gate").

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local spec      = require "spec"
local turn      = require "turn"
local store     = require "store"
local gherkin   = require "gherkin"
local behaviour = require "behaviour"
local cli       = require "cli"
local trace     = require "trace"

local T = {}

local function has(s, needle) return type(s) == "string" and s:find(needle, 1, true) ~= nil end

local function raises(f, ...)
  local ok, err = pcall(f, ...)
  return (not ok), tostring(err)
end

-- A scripted model: each entry is { calls = {...} } or { text = "..." }.
local function scripted(replies, gate)
  local i, p = 0, { seen = {} }
  p.model = {
    call = function (request)
      i = i + 1
      p.seen[#p.seen + 1] = request
      local r = replies[i]
      if r == nil then return nil, { port = "model", call = "call", code = "exhausted", message = "done" } end
      return { text = r.text, calls = r.calls or {}, stop = r.calls and "calls" or "done" }
    end,
  }
  if gate ~= nil then
    p.ask = { seen = {}, request = function (q) p.ask.seen[#p.ask.seen + 1] = q; return gate end }
  end
  return p
end

-- A small maze: a store of rows, a tool with a requirement, and a tool the person edits.
local function maze(opts)
  opts = opts or {}
  local a = spec.new()
  spec.set_name(a, "maze")
  spec.set_model(a, "test:model")
  spec.add_store(a, "room", {
    about = "the room, one row of cells a line",
    columns = { y = spec.types.number("which row, from the top"), cells = spec.types.string("the cells") },
    sort = { "y" },
  })
  local ran = { set_room = 0, move_lamp = 0 }
  spec.add_tool(a, "set_room", {
    about = "Replace the room",
    args = { rows = spec.types.list("the rows, top to bottom") },
    requires = {
      { says = "the lamp can be reached from the moth",
        check = function (c)
          if table.concat(c.args.rows, "\n"):find("M#L", 1, true) then return false, "a wall is between them" end
          return true
        end },
      { says = "no row is empty", check_only = opts.check_only,
        check = function (c)
          for _, r in ipairs(c.args.rows) do if r == "" then return false end end
          return true
        end },
    },
    run = function (c)
      ran.set_room = ran.set_room + 1
      c.store.remove("room", {})
      for i, r in ipairs(c.args.rows) do c.store.add("room", { y = i, cells = r }) end
      return "set"
    end,
  })
  spec.add_tool(a, "move_lamp", {
    about = "Move the lamp",
    ask = { edit = "where" },
    args = { where = spec.types.one_of { "near", "far" }, note = spec.types.string_opt("why") },
    run = function (c) ran.move_lamp = ran.move_lamp + 1; return "moved " .. c.args.where end,
  })
  return a, ran
end

-- ------------------------------------------------------------------------ the store

function T.a_store_lists_its_rows_sorted_whatever_order_they_were_added()
  local a = maze()
  local raw = store.memory()
  local v = store.view(raw, a.stores)
  assert(v.add("room", { y = 3, cells = "###" }))
  assert(v.add("room", { y = 1, cells = "#M#" }))
  assert(v.add("room", { y = 2, cells = "#L#" }))
  local rows = v.rows("room")
  assert(#rows == 3 and rows[1].y == 1 and rows[2].y == 2 and rows[3].y == 3)
  -- Copies: changing what came back changes nothing held.
  rows[1].cells = "changed"
  assert(v.rows("room")[1].cells == "#M#")
  -- What the host holds is sorted too, so the same rows are the same bytes.
  assert(raw.tables.room[1].y == 1)
  assert(#raw.changes == 3 and raw.changes[1].change.op == "add")
end

function T.change_and_remove_answer_how_many_and_record_what_happened()
  local a = maze()
  local raw = store.memory { room = { { y = 1, cells = "a" }, { y = 2, cells = "a" }, { y = 3, cells = "b" } } }
  local v = store.view(raw, a.stores)
  assert(v.change("room", { cells = "a" }, { cells = "c" }) == 2)
  assert(v.change("room", { cells = "zzz" }, { cells = "c" }) == 0)
  assert(#raw.changes == 1, "a change that matched nothing wrote nothing")
  assert(raw.changes[1].change.op == "change" and raw.changes[1].change.set.cells == "c")
  assert(v.remove("room", { y = 3 }) == 1)
  assert(#v.rows("room") == 2)
  assert(v.remove("room", {}) == 2, "{} is every row")
  assert(#v.rows("room") == 0)
end

function T.a_wrong_shape_raises_and_says_what_is_wrong()
  local a = maze()
  local v = store.view(store.memory(), a.stores)
  local bad, why = raises(v.add, "rooms", { y = 1, cells = "#" })
  assert(bad and has(why, 'no store "rooms"') and has(why, "room"), why)
  bad, why = raises(v.add, "room", { y = 1, cells = "#", colour = "red" })
  assert(bad and has(why, 'no column "colour"'), why)
  bad, why = raises(v.add, "room", { y = "one", cells = "#" })
  assert(bad and has(why, "must be a number"), why)
  bad, why = raises(v.add, "room", { cells = "#" })
  assert(bad and has(why, 'needs "y"'), why)
  bad, why = raises(v.change, "room", "y", { cells = "#" })
  assert(bad, "a where that is not a table raises")
end

function T.a_full_store_is_a_wrong_world_and_answers_nil_and_why()
  local a = maze()
  local v = store.view(store.memory(), a.stores)
  local big = string.rep("#", store.LIMIT)
  local ok, why = v.add("room", { y = 1, cells = big })
  assert(ok == nil and has(why, "past the limit"), tostring(why))
  assert(#v.rows("room") == 0, "a refused add wrote nothing")
end

function T.a_host_that_cannot_write_is_a_reason_not_a_raise()
  local a = maze()
  local v = store.view({ read = function () return {} end, write = function () return nil, "the disk is full" end }, a.stores)
  local ok, why = v.add("room", { y = 1, cells = "#" })
  assert(ok == nil and why == "the disk is full", tostring(why))
end

function T.a_data_table_row_is_typed_by_its_column()
  local a = maze()
  local row = assert(store.from_text(a.stores.room, { y = "2", cells = "#.#" }))
  assert(row.y == 2 and row.cells == "#.#")
  local no, why = store.from_text(a.stores.room, { y = "two", cells = "#" })
  assert(no == nil and has(why, "is a number"), why)
  no, why = store.from_text(a.stores.room, { z = "1" })
  assert(no == nil and has(why, 'no column "z"'), why)
  assert(table.concat(store.columns(a.stores.room), ",") == "y,cells")
end

function T.a_store_is_declared_with_columns_of_types_it_can_hold()
  local a = spec.new()
  local bad, why = raises(spec.add_store, a, "x", { about = "x", columns = { f = spec.types.list("no") } })
  assert(bad and has(why, "string, number, boolean or one_of"), why)
  bad, why = raises(spec.add_store, a, "x", { about = "x", columns = {} })
  assert(bad and has(why, "no columns"), why)
  bad, why = raises(spec.add_store, a, "x", { about = "x", columns = { n = spec.types.number("n") }, sort = { "m" } })
  assert(bad and has(why, '"m", which is not a column'), why)
  bad, why = raises(spec.add_store, a, "x", { columns = { n = spec.types.number("n") } })
  assert(bad and has(why, "needs `about`"), why)
end

-- --------------------------------------------------------------------- requirements

function T.a_requirement_that_fails_stops_the_call_before_run_and_the_model_reads_why()
  local a, ran = maze()
  local p = scripted({
    { calls = { { tool = "set_room", args = { rows = { "#####", "#M#L#", "#####" } } } } },
    { calls = { { tool = "set_room", args = { rows = { "#####", "#M.L#", "#####" } } } } },
    { text = "fixed" },
  }, { allow = false })
  local r = turn.run(a, "a room", store.bind(a, p))
  assert(r.stop == "answered", r.stop)
  assert(ran.set_room == 1, "the body ran " .. ran.set_room .. " times")
  local first = r.calls[1]
  assert(first.ok == false and first.unmet == "the lamp can be reached from the moth")
  assert(has(first.output, "was not made: it requires that the lamp can be reached from the moth"), first.output)
  assert(has(first.output, "a wall is between them"), first.output)
  -- The repair is the next step, with the reason in front of the model.
  local told = false
  for _, m in ipairs(p.seen[2].messages) do
    if m.role == "tool" and has(m.text, "requires that the lamp can be reached") then told = true end
  end
  assert(told, "the model's second request does not carry the reason")
  assert(#r.calls == 2 and r.calls[2].ok == true)
  assert(#p.store.tables.room == 3 and p.store.tables.room[2].cells == "#M.L#")
end

function T.a_requirement_is_in_the_description_unless_it_is_check_only()
  local a = maze()
  local about
  for _, t in ipairs(spec.schema(a)) do if t.name == "set_room" then about = t.description or t.about end end
  assert(has(about, "It requires: the lamp can be reached from the moth; no row is empty."), about)
  local b = maze { check_only = true }
  for _, t in ipairs(spec.schema(b)) do if t.name == "set_room" then about = t.description or t.about end end
  assert(has(about, "the lamp can be reached") and not has(about, "no row is empty"), about)
end

function T.a_requirement_whose_check_raises_is_unmet_and_the_run_goes_on()
  local a = spec.new()
  spec.set_name(a, "x"); spec.set_model(a, "test:model")
  spec.add_tool(a, "t", { about = "t", args = {},
    requires = { { says = "it is sound", check = function () error("boom") end } },
    run = function () return "ran" end })
  local r = turn.run(a, "go", scripted({ { calls = { { tool = "t", args = {} } } }, { text = "ok" } }))
  assert(r.stop == "answered" and r.calls[1].unmet == "it is sound")
  assert(has(r.calls[1].output, "its check raised"), r.calls[1].output)
end

function T.a_requirement_is_declared_with_words_and_a_check()
  local a = spec.new()
  local bad, why = raises(spec.add_tool, a, "t", { about = "t", args = {}, run = function () end,
    requires = { { check = function () return true end } } })
  assert(bad, "a requirement with no words must raise")
  bad, why = raises(spec.add_tool, a, "t", { about = "t", args = {}, run = function () end,
    requires = { { says = "x" } } })
  assert(bad, "a requirement with no check must raise")
end

function T.a_requirement_failure_is_a_span_attribute_and_not_the_sentence()
  assert(trace.MINTED["malleable.requirement"], "the attribute is not minted")
  local vals = trace.MINTED["malleable.requirement"]
  assert(#vals == 1 and vals[1] == "unmet")
end

-- ------------------------------------------------------------------- edits at the gate

function T.a_person_changes_what_the_model_proposed_and_the_tool_gets_it()
  local a, ran = maze()
  local p = scripted({
    { calls = { { tool = "move_lamp", args = { where = "far" } } } },
    { text = "near it is" },
  }, { allow = true, args = { where = "near" } })
  local r = turn.run(a, "move", p)
  assert(ran.move_lamp == 1)
  local rec = r.calls[1]
  assert(rec.ok and rec.args.where == "near" and rec.edited.where == "near")
  assert(has(rec.output, "moved near"), rec.output)
  assert(has(rec.output, "(the person chose near for where)"), rec.output)
  -- The gate was shown what the model proposed, which argument may change, and to what.
  local q = p.ask.seen[1]
  assert(q.args.where == "far" and q.edit[1] == "where")
  assert(q.choices.where[1] == "near" and q.choices.where[2] == "far")
end

function T.an_approval_that_changes_nothing_is_not_an_edit()
  local a = maze()
  local p = scripted({ { calls = { { tool = "move_lamp", args = { where = "far" } } } }, { text = "ok" } },
    { allow = true, args = { where = "far" } })
  local r = turn.run(a, "move", p)
  assert(r.calls[1].ok and r.calls[1].edited == nil)
  assert(not has(r.calls[1].output, "the person chose"), r.calls[1].output)
end

function T.an_edit_outside_the_choices_is_a_refusal_never_a_call()
  local a, ran = maze()
  local p = scripted({ { calls = { { tool = "move_lamp", args = { where = "far" } } } }, { text = "ok" } },
    { allow = true, args = { where = "moon" } })
  local r = turn.run(a, "move", p)
  assert(ran.move_lamp == 0)
  assert(r.calls[1].refused and has(r.calls[1].output, "not a value this tool takes"), r.calls[1].output)
end

function T.an_edit_to_an_argument_the_tool_does_not_offer_is_ignored()
  local a = maze()
  local p = scripted({ { calls = { { tool = "move_lamp", args = { where = "far", note = "model" } } } }, { text = "ok" } },
    { allow = true, args = { note = "person" } })
  local r = turn.run(a, "move", p)
  assert(r.calls[1].ok and r.calls[1].args.note == "model" and r.calls[1].edited == nil)
end

function T.only_a_one_of_a_boolean_or_a_number_can_be_edited()
  local a = spec.new()
  local bad, why = raises(spec.add_tool, a, "t", { about = "t", ask = { edit = "text" },
    args = { text = spec.types.string("x") }, run = function () end })
  assert(bad and has(why, "one_of, a boolean or a number"), why)
  bad, why = raises(spec.add_tool, a, "t", { about = "t", ask = { edit = "nope" },
    args = { text = spec.types.string("x") }, run = function () end })
  assert(bad and has(why, "not one of its arguments"), why)
  assert(spec.add_tool(a, "u", { about = "u", ask = { edit = { "n", "b" } },
    args = { n = spec.types.number("n"), b = spec.types.boolean("b") }, run = function () end }) ~= false)
  assert(a.tools.u.ask == true and #a.tools.u.edit == 2)
end

function T.a_one_of_refuses_a_value_outside_it_and_the_schema_lists_its_choices()
  local a, ran = maze()
  local r = turn.run(a, "move", scripted({ { calls = { { tool = "move_lamp", args = { where = "moon" } } } }, { text = "ok" } },
    { allow = true }))
  assert(ran.move_lamp == 0 and r.calls[1].ok == false)
  assert(has(r.calls[1].output, "near") and has(r.calls[1].output, "far"), r.calls[1].output)
  local provider = require "provider.openai_chat"
  local body = assert(provider.body({ messages = {}, tools = spec.schema(a) }, "m", {}, { io = {} }))
  local where = nil
  for _, t in ipairs(body.tools) do
    if t["function"].name == "move_lamp" then where = t["function"].parameters.properties.where end
  end
  assert(where and where.enum and where.enum[1] == "near" and where.enum[2] == "far", "the schema has no enum")
end

-- -------------------------------------------------------------------- as a feature

local FEATURE = [[
Feature: the maze keeps its room

  Scenario: a sealed room is refused, and the next one lands
    Given the store room contains:
      | y | cells |
      | 1 | ##### |
    And the model calls set_room with {"rows": ["#M#L#"]}
    And the model calls set_room with {"rows": ["#M.L#"]}
    And the model answers "done"
    When the agent is asked "a room"
    Then it calls set_room 2 times
    And the first call to set_room fails because "the lamp can be reached from the moth"
    And the store room holds:
      | y | cells |
      | 1 | #M.L# |
    And the store room has 1 row
    And the tool set_room tells the model "the lamp can be reached from the moth"
    And it stops with answered

  Scenario: the person makes it near
    Given the human approves move_lamp with {"where": "near"}
    And the model calls move_lamp with {"where": "far"}
    And the model answers "near"
    When the agent is asked "move"
    Then it calls move_lamp with {"where": "near"}
    And the call to move_lamp answers "the person chose near"
]]

local function run_feature(a, text)
  local d = cli.drivers(a, function (prompt, port, o) return turn.run(a, prompt, port, o) end)
  return behaviour.run(assert(gherkin.pickle(text)), d, {})
end

function T.a_feature_writes_the_store_reads_it_back_and_states_the_edit()
  local r = run_feature(maze(), FEATURE)
  for _, s in ipairs(r.scenarios) do
    local why = ""
    for _, st in ipairs(s.steps) do if st.why then why = st.text .. ": " .. st.why end end
    assert(s.outcome == "passed", s.name .. ": " .. why)
  end
end

function T.a_store_line_that_is_wrong_fails_with_what_it_holds()
  local text = FEATURE:gsub("| 1 | #M%.L# |", "| 1 | #M..# |")
  local r = run_feature(maze(), text)
  local s = r.scenarios[1]
  assert(s.outcome == "failed", s.outcome)
  local why
  for _, st in ipairs(s.steps) do if st.why then why = st.why end end
  assert(has(why, "#M.L#"), tostring(why))
end

function T.a_store_the_program_does_not_declare_is_named_in_the_failure()
  local r = run_feature(maze(), [[
Feature: f
  Scenario: s
    Given the store rooms contains:
      | y |
      | 1 |
    And the model answers "x"
    When the agent is asked "go"
    Then it stops with answered
]])
  local s = r.scenarios[1]
  assert(s.outcome ~= "passed")
  local why
  for _, st in ipairs(s.steps) do if st.why then why = st.why end end
  assert(has(why, 'no store called "rooms"'), tostring(why))
end

function T.an_observed_run_says_the_store_the_edit_and_the_unmet_requirement_and_runs_again()
  local a = maze()
  local r = run_feature(a, FEATURE)
  local texts = {}
  for _, s in ipairs(r.scenarios) do
    local text, gaps = require("observe").scenario(s.record, "again — " .. s.name)
    assert(#gaps == 0, "a gap: " .. tostring(gaps[1] and gaps[1].saw))
    texts[#texts + 1] = text
  end
  local both = table.concat(texts, "\n")
  assert(has(both, "Given the store room contains:\n      | y | cells |\n      | 1 | ##### |"), both)
  assert(has(both, 'the first call to set_room fails because "the lamp can be reached from the moth"'), both)
  assert(has(both, "the store room holds:\n      | y | cells |\n      | 1 | #M.L# |"), both)
  assert(has(both, 'Given the human approves move_lamp with {"where":"near"}'), both)
  assert(has(both, 'it calls move_lamp with {"where":"near"}'), both)
  -- And it is a feature that holds when it runs again.
  local again = run_feature(a, "Feature: observed\n" .. both)
  assert(#again.scenarios == 2)
  for _, s in ipairs(again.scenarios) do
    local why = ""
    for _, st in ipairs(s.steps) do if st.why then why = st.text .. ": " .. st.why end end
    assert(s.outcome == "passed", s.name .. ": " .. why .. "\n" .. both)
  end
end

function T.a_cell_with_a_bar_reads_back_as_itself()
  local a = spec.new()
  spec.set_name(a, "notes"); spec.set_model(a, "test:model")
  spec.add_store(a, "notes", { about = "a note", columns = { text = spec.types.string("t") } })
  spec.add_tool(a, "note", { about = "note", args = { text = spec.types.string("t") },
    run = function (c) c.store.add("notes", { text = c.args.text }); return "ok" end })
  local r = run_feature(a, [[
Feature: f
  Scenario: s
    Given the model calls note with {"text": "a | b \\ c"}
    And the model answers "ok"
    When the agent is asked "go"
    Then it stops with answered
]])
  local text = require("observe").scenario(r.scenarios[1].record, "again")
  assert(has(text, "| a \\| b \\\\ c |"), text)
  local again = run_feature(a, "Feature: o\n" .. text)
  assert(again.scenarios[1].outcome == "passed", text)
end

return T
