-- The agent file (console/lib/agent_file.lua): the agent's own feature laid out on the
-- stage, at any window size, the same items every time (docs/spec/agent-file.md).

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local agent_file = require "console.lib.agent_file"

local T = {}

local function measure(s, size) return #s * (size or 12) * 0.55 end

local function notebook()
  local f = assert(io.open(here .. "/../console/agents/notebook.feature", "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

local RICH = [[
@kept
Feature: greeter
  Says hello to whoever it is asked to, and keeps a list of who it has greeted, which is
  a description long enough to need more than one line at a narrow window.

  Background:
    Given the agent is called greeter
    And it has a tool greet for "Say hello to someone.", which takes:
      | argument | type   | about        |
      | name     | string | who to greet |
    And the tool greet does:
      """lua
      return "hello, " .. c.args.name
      """

  @proposed
  Scenario: it greets
    Given the model calls greet with {"name": "ada"}
    When the agent is asked "greet ada"
    Then the call to greet answers "hello, ada"

  Rule: it is polite
    Scenario: it never shouts
      Given the model answers "hello"
      When the agent is asked "GREET"
      Then the answer says "hello"
]]

local function texts_of(items)
  local out = {}
  for _, it in ipairs(items) do if it.kind == "text" then out[#out + 1] = it end end
  return out
end

function T.every_size_lays_the_file_out_inside_the_rectangle_with_a_clip()
  for _, text in ipairs { notebook(), RICH } do
    for _, s in ipairs { { 320, 240 }, { 560, 665 }, { 1400, 860 }, { 2400, 900 } } do
      local f = agent_file.new()
      assert(f:set(text))
      local rect = { x = 0, y = 0, w = s[1], h = s[2] - 40 }
      local items, wanted = f:draw(rect, measure, 14)
      assert(items[1].kind == "clip" and items[#items].kind == "unclip", "no clip around the file")
      assert(wanted > 0)
      for _, it in ipairs(texts_of(items)) do
        assert(it.x >= rect.x, "'" .. it.text .. "' is past the left at " .. s[1])
        assert(it.x + measure(it.text, it.size) <= rect.x + rect.w + 1, "'" .. it.text .. "' is past the right at " .. s[1])
      end
    end
  end
end

function T.the_same_text_and_rectangle_give_the_same_items()
  local f = agent_file.new()
  assert(f:set(RICH))
  local rect = { x = 0, y = 0, w = 700, h = 500 }
  local a = f:draw(rect, measure, 14)
  local b = f:draw(rect, measure, 14)
  assert(#a == #b)
  for i = 1, #a do
    for k, v in pairs(a[i]) do
      if type(v) ~= "table" then assert(b[i][k] == v, "item " .. i .. " differs in " .. k) end
    end
  end
end

function T.the_rows_come_in_the_files_order_with_keys_tones_and_shared_columns()
  local f = agent_file.new()
  assert(f:set(RICH))
  local rows = f:rows()
  assert(rows[1].kind == "tag" and rows[1].parts[1].text == "@kept", "the feature's tags come first")
  assert(rows[2].kind == "feature" and rows[2].parts[1].text == "greeter" and rows[2].key == "feature:greeter")
  assert(rows[3].kind == "description" and rows[3].parts[1].text:find("^Says hello"))
  local kinds, order = {}, {}
  for _, r in ipairs(rows) do
    kinds[r.kind] = (kinds[r.kind] or 0) + 1
    if r.kind == "step" or r.kind == "block" then order[#order + 1] = r.parts[2].text end
    if r.kind == "step" then
      assert(r.parts[1].tone == "quiet" and r.parts[2].tone == "ink", "a step's keyword is not quiet")
      assert(not r.parts[1].text:find("%s$"), "the keyword keeps its space")
    end
  end
  assert(kinds.block == 4 and kinds.step == 9 and kinds.doc == 1 and kinds.cells == 2 and kinds.tag == 2,
    "wrong counts: " .. kinds.block .. " " .. kinds.step .. " " .. tostring(kinds.doc) .. " " .. tostring(kinds.cells) .. " " .. tostring(kinds.tag))
  assert(order[1] == "" and order[2] == "the agent is called greeter" and order[#order] == 'the answer says "hello"', "out of order")
  -- the rule's scenario is one level in, and a step's key says what it says
  local rule_step
  for _, r in ipairs(rows) do if r.key == 'step:Given the model answers "hello"' then rule_step = r end end
  assert(rule_step and rule_step.indent == 2, "the rule's step is not indented")
  -- a table's cells share column positions across its rows
  local items = f:draw({ x = 0, y = 0, w = 900, h = 2000 }, measure, 14)
  local at = {}
  for _, it in ipairs(texts_of(items)) do
    if it.text == "argument" or it.text == "name" then at[it.text] = it.x end
    if it.text == "type" or it.text == "string" then at[it.text] = it.x end
  end
  assert(at.argument == at.name and at.type == at.string, "the columns do not line up")
  assert(at.type > at.argument)
end

function T.the_wheel_scrolls_no_further_than_the_file()
  local f = agent_file.new()
  assert(f:set(RICH))
  local rect = { x = 0, y = 0, w = 500, h = 200 }
  local _, wanted = f:draw(rect, measure, 14)
  assert(wanted > rect.h)
  for _ = 1, 100 do f:wheel(-1) end
  f:draw(rect, measure, 14)
  assert(f.scroll == wanted - rect.h, f.scroll)
  for _ = 1, 100 do f:wheel(1) end
  f:draw(rect, measure, 14)
  assert(f.scroll == 0)
  -- a taller rectangle needs no scroll at all
  f:wheel(-1)
  f:draw({ x = 0, y = 0, w = 500, h = 5000 }, measure, 14)
  assert(f.scroll == 0)
end

function T.a_text_the_reader_refuses_leaves_the_last_file_and_says_why()
  local f = agent_file.new()
  assert(f:set(RICH))
  local ok, why = f:set("Scenario: no feature line\n  Given nothing\n")
  assert(ok == nil and type(why) == "string" and #why > 0)
  assert(f:rows()[2].parts[1].text == "greeter")
end

function T.the_file_reaches_nothing()
  local f = assert(io.open(here .. "/../console/lib/agent_file.lua", "rb"))
  local code = f:read("*a"):gsub("%-%-[^\n]*", "")
  f:close()
  for _, word in ipairs { "love", "io", "os" } do
    assert(not code:find("%f[%w_]" .. word .. "%f[^%w_]"), "agent_file.lua names " .. word)
  end
end

local SMALL = "Feature: notebook\n  Keeps notes.\n\n  Scenario: it reads\n    When the agent is asked \"hi\"\n    Then it calls read\n"

local function observed_text(calls, stop)
  local lines = { "  Scenario: j1 notebook: what do my notes say?" }
  for i, tool in ipairs(calls) do
    lines[#lines + 1] = "    " .. (i == 1 and "Given " or "And ") .. "the model calls " .. tool .. " with {}"
  end
  lines[#lines + 1] = '    When the agent is asked "what do my notes say?"'
  local first = true
  if stop then lines[#lines + 1] = "    Then it stops with " .. stop; first = false end
  for _, tool in ipairs(calls) do
    lines[#lines + 1] = "    " .. (first and "Then " or "And ") .. "it calls " .. tool .. " with {}"
    first = false
  end
  return table.concat(lines, "\n") .. "\n"
end

local function keys_of(f)
  local out = {}
  for _, r in ipairs(f:rows()) do out[#out + 1] = r.key end
  return out
end

function T.observed_runs_come_after_the_file_with_their_state_and_fold_to_one_line()
  local f = agent_file.new()
  assert(f:set(SMALL))
  local before = #f:rows()
  f:observed { { id = "j1", text = observed_text { "list" }, state = "running" } }
  local rows = f:rows()
  assert(#rows > before, "nothing was added")
  local block
  for _, r in ipairs(rows) do if r.kind == "block" and r.key:find("^j1:") then block = r end end
  assert(block and block.state == "running" and block.parts[2].text:find("^j1 notebook"), "the run's block is missing")
  local steps = 0
  for _, r in ipairs(rows) do if r.key:find("^j1:step:") then steps = steps + 1 end end
  assert(steps == 3, steps)
  -- one more call: one more Given and one more Then, the rest the same keys
  f:observed { { id = "j1", text = observed_text { "list", "read" }, state = "running" } }
  steps = 0
  for _, r in ipairs(f:rows()) do if r.key:find("^j1:step:") then steps = steps + 1 end end
  assert(steps == 5, steps)
  -- done, then folded to one line with its note
  f:observed { { id = "j1", text = observed_text({ "list", "read" }, "answered"), state = "passed" } }
  for _, r in ipairs(f:rows()) do if r.kind == "block" and r.key:find("^j1:") then assert(r.state == "passed") end end
  f:observed { { id = "j1", text = observed_text({ "list", "read" }, "answered"), state = "folded", note = "done after 2 steps" } }
  rows = f:rows()
  local last = rows[#rows]
  assert(last.kind == "block" and last.state == "folded" and last.parts[3].text == "done after 2 steps", "not folded")
  assert(#rows == before + 2, "a folded run is one line and its gap")
  -- a text the reader refuses is one line naming the run
  f:observed { { id = "j2", text = "not gherkin at all", state = "failed" } }
  rows = f:rows()
  assert(rows[#rows].parts[2].text == "j2" and rows[#rows].state == "failed")
end

function T.a_line_that_lands_slides_in_and_the_lines_below_shift_and_a_line_that_goes_fades()
  local f = agent_file.new()
  assert(f:set(SMALL))
  local rect = { x = 0, y = 0, w = 600, h = 800 }
  local function texts(items)
    local out = {}
    for _, it in ipairs(items) do if it.kind == "text" then out[it.text] = it end end
    return out
  end
  -- the first frame is settled, whatever the clock says
  local a = texts(f:draw(rect, measure, 14, 10))
  assert(a["it reads"].alpha == 1)
  f:observed { { id = "j1", text = observed_text { "list" }, state = "running" } }
  local b = texts(f:draw(rect, measure, 14, 10))
  local landed = b["the model calls list with {}"]
  assert(landed and landed.alpha < 0.05, "the new line did not start transparent")
  local mid = texts(f:draw(rect, measure, 14, 10.1))["the model calls list with {}"]
  assert(mid.alpha > 0.5 and mid.alpha < 1 and mid.y < landed.y, "the new line is not sliding in")
  local done = texts(f:draw(rect, measure, 14, 10.3))["the model calls list with {}"]
  assert(done.alpha == 1 and done.y < mid.y)
  -- a line more: the lines below it shift, eased, and the one above stays
  local when_y = texts(f:draw(rect, measure, 14, 11))['the agent is asked "what do my notes say?"'].y
  f:observed { { id = "j1", text = observed_text { "list", "read" }, state = "running" } }
  local c = texts(f:draw(rect, measure, 14, 11))
  assert(c['the agent is asked "what do my notes say?"'].y == when_y, "the shifted line jumped")
  local c2 = texts(f:draw(rect, measure, 14, 11.1))
  assert(c2['the agent is asked "what do my notes say?"'].y > when_y, "the line below did not shift")
  local c3 = texts(f:draw(rect, measure, 14, 11.5))
  assert(c3['the agent is asked "what do my notes say?"'].y == when_y + math.floor(14 * agent_file.LINE), "the shift did not land")
  assert(c3["the model calls list with {}"].y == done.y, "a line that did not change moved")
  -- folding takes lines away: they fade where they were, struck through, then go
  f:observed { { id = "j1", text = observed_text({ "list", "read" }, "answered"), state = "folded", note = "done" } }
  local d = f:draw(rect, measure, 14, 12)
  local ghost, strike = nil, 0
  for _, it in ipairs(d) do
    if it.kind == "text" and it.text == "the model calls list with {}" then ghost = it end
    if it.kind == "rect" and it.h == 1 then strike = strike + 1 end
  end
  assert(ghost and ghost.alpha > 0 and ghost.alpha < 1 and strike > 0, "the gone line is not fading")
  local e = texts(f:draw(rect, measure, 14, 12.5))
  assert(e["the model calls list with {}"] == nil, "the gone line stayed")
  -- a state change colours the block's name
  f:observed { { id = "j2", text = observed_text { "list" }, state = "running" } }
  f:draw(rect, measure, 14, 13)
  f:observed { { id = "j2", text = observed_text({ "list" }, "answered"), state = "passed" } }
  local g0 = texts(f:draw(rect, measure, 14, 13.5))["j1 notebook: what do my notes say?"]
  assert(g0 and g0.rgb[1] == agent_file.HUES.running[1], "the colour did not start from the state before")
  local g = texts(f:draw(rect, measure, 14, 14))["j1 notebook: what do my notes say?"]
  assert(g and g.rgb[2] == agent_file.HUES.passed[2], "the block did not take its state's colour")
end

function T.results_mark_the_files_scenarios_passed_or_failed_and_a_proposed_one_not_at_all()
  local f = agent_file.new()
  assert(f:set(RICH))
  f:results { { name = "it greets", outcome = "passed", authored = true },
              { name = "it never shouts", outcome = "failed", authored = true } }
  local seen = {}
  for _, r in ipairs(f:rows()) do if r.kind == "block" then seen[r.parts[2].text] = r.state or "none" end end
  assert(seen["it greets"] == "passed" and seen["it never shouts"] == "failed" and seen[""] == "none" and seen["it is polite"] == "none",
    "wrong states")
  f:results { { name = "it greets", outcome = "failed", authored = false } }
  for _, r in ipairs(f:rows()) do if r.kind == "block" then assert(r.state == nil, "a proposed scenario took a state") end end
end

function T.an_edit_to_the_file_lands_as_a_difference()
  local f = agent_file.new()
  assert(f:set(SMALL))
  local rect = { x = 0, y = 0, w = 600, h = 800 }
  f:draw(rect, measure, 14, 1)
  assert(f:set("Feature: notebook\n  Keeps notes.\n\n  Scenario: it reads\n    Given the model answers \"ok\"\n    When the agent is asked \"hi\"\n    Then it calls read\n"))
  local items = f:draw(rect, measure, 14, 1)
  local came
  for _, it in ipairs(items) do if it.kind == "text" and it.text == 'the model answers "ok"' then came = it end end
  assert(came and came.alpha < 0.05, "the new line did not slide in")
  assert(f:set(SMALL))
  local gone
  for _, it in ipairs(f:draw(rect, measure, 14, 2)) do if it.kind == "text" and it.text == 'the model answers "ok"' then gone = it end end
  assert(gone and gone.alpha < 1, "the removed line did not fade")
end

function T.a_delegated_run_nests_one_level_under_the_run_that_handed_it_work()
  local f = agent_file.new()
  assert(f:set(SMALL))
  f:observed {
    { id = "j1", text = observed_text { "helper" }, state = "running" },
    { id = "j1/4", parent = "j1", text = "  Scenario: helper, handed helper\n    Then it calls mark\n", state = "running" },
    { id = "j1/4/9", parent = "j1/4", text = "  Scenario: deeper, handed dig\n    Then it stops with answered\n", state = "passed" },
    { id = "j2", text = observed_text { "list" }, state = "running" },
  }
  local indent = {}
  for _, r in ipairs(f:rows()) do if r.kind == "block" then indent[r.parts[2].text] = r.indent end end
  assert(indent["helper, handed helper"] == 1 and indent["deeper, handed dig"] == 2 and indent["j1 notebook: what do my notes say?"] == 0, "wrong nesting")
  local step
  for _, r in ipairs(f:rows()) do if r.key:find("^j1/4:step:") then step = r end end
  assert(step and step.indent == 2, "the nested run's steps are not one level in from it")
end

return T
