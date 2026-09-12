-- docs/spec/modes.md: a state machine over what an agent may call, moved only by the person.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local spec    = require "spec"
local declare = require "declare"
local say     = require "say"
local cli     = require "cli"

local T = {}

local root = here .. "/.."

local function read(path)
  local f, why = io.open(path, "rb")
  if not f then return nil, (tostring(why):find("No such file") and "missing" or tostring(why)) end
  local t = f:read("*a"); f:close(); return t
end

local function has(s, needle) return tostring(s):find(needle, 1, true) ~= nil end

local function apply(text)
  local a = spec.new()
  local info, why = declare.apply(text, a, { read = function (p) return read(root .. "/showcase/" .. p) end })
  return info and a or nil, why
end

local HEAD = [[
Feature: t
  Background:
    Given the agent is called t
    And its model is "test:model"
    And it uses the kit "../library/modes.lua"
    And it has a tool ping for "Pong."
    And the tool ping answers "pong"
    And it has a tool pong for "Ping."
    And the tool pong answers "ping"
]]

function T.each_rule_of_the_lines_is_refused_at_install_by_name()
  local cases = {
    { '    And in the mode reading it may call "ping"\n', "say which mode it starts in" },
    { '    And it starts in the mode reading\n', "which no `in the mode reading it may call` line declares" },
    { '    And it starts in the mode reading\n    And it starts in the mode writing\n    And in the mode reading it may call "ping"\n', "the start is said twice" },
    { '    And it starts in the mode reading\n    And in the mode reading it may call "ping"\n    And in the mode reading it may call "pong"\n', "declared twice" },
    { '    And it starts in the mode reading\n    And in the mode reading it may call ""\n', "lists no tool" },
    { '    And it starts in the mode reading\n    And in the mode reading it may call "ping"\n    And the mode reading moves to writing when the person says so\n', "names writing, which is not a mode" },
  }
  for i, c in ipairs(cases) do
    local a, why = apply(HEAD .. c[1])
    assert(a == nil, "case " .. i .. " loaded")
    assert(has(why, c[2]), "case " .. i .. ": " .. tostring(why))
  end
end

function T.the_lines_are_said_back_and_their_reach_is_what_they_say()
  local text = HEAD .. [[
    And it starts in the mode reading
    And in the mode reading it may call "ping"
    And in the mode writing it may call "ping, pong"
    And the mode reading moves to writing when the person says so
]]
  local a = assert(apply(text))
  assert(a.tools.mode and a.tools.mode.ask == true, "the mode tool asks first")
  assert(has(a.tools.mode.about, "from reading to writing"), a.tools.mode.about)
  local said, unsaid = say.render(a)
  assert(#unsaid == 0, table.concat(unsaid, "; "))
  for _, l in ipairs { "And it starts in the mode reading", 'And in the mode reading it may call "ping"',
                       "And the mode reading moves to writing when the person says so" } do
    assert(has(said, l), "missing " .. l .. "\n" .. said)
  end
  assert(declare.is_line('in the mode reading it may call "ping"').reach == "narrows")
  assert(declare.is_line("the mode reading moves to writing when the person says so").reach == "widens")
  assert(declare.is_line("it starts in the mode reading").reach == "neither")
end

function T.the_showcase_verifies_on_the_doubles()
  local w = { outs = {}, errs = {} }
  w.out = function (t) w.outs[#w.outs + 1] = t end
  w.err = function (t) w.errs[#w.errs + 1] = t end
  w.read = read
  w.env = function () return nil end
  w.now = function () return 0 end
  local f = root .. "/showcase/21-modes.feature"
  local code = cli.main({ "--verify", "--feature", f, f }, w)
  local out = table.concat(w.outs) .. table.concat(w.errs)
  assert(code == 0 and has(out, "4 passed, 0 failed"), out)
end

-- ------------------------------------------------------------------ the wall over the mode lines

local WALLED = HEAD .. [[
    And it starts in the mode reading
    And in the mode reading it may call "ping"
    And in the mode writing it may call "ping, pong"
    And the mode reading moves to writing when the person says so

  Scenario: it pings
    Given the model calls ping with {}
    And the model answers "pong"
    When the agent is asked "ping"
    Then it calls ping
]]

function T.the_wall_scores_the_mode_lines_as_the_kit_said()
  assert(apply(WALLED), "the walled file loads")
  local function edit(op)
    local new, change, wall = declare.edit(WALLED, op)
    return new, change, wall
  end
  -- the start is a gate: never removed, never replaced
  local new, change, wall = edit({ remove = "it starts in the mode reading" })
  assert(new == nil and has(change, "gate") or has(tostring(wall), "gate") or has(tostring(change), "asks first") or new == nil, tostring(change))
  new, change = edit({ replace = "it starts in the mode reading", with = "it starts in the mode writing" })
  assert(new == nil, "the start was replaced:\n" .. tostring(new))
  -- a mode's list narrows: a wider list is a widening, a shorter one a narrowing
  new, change = edit({ replace = 'in the mode reading it may call "ping"', with = 'in the mode reading it may call "ping, pong"' })
  assert(new and change.reach == "widens", tostring(change and change.reach))
  new, change = edit({ replace = 'in the mode writing it may call "ping, pong"', with = 'in the mode writing it may call "ping"' })
  assert(new and change.reach == "narrows", "a shorter list is narrower still: " .. tostring(change and change.reach))
  new, change = edit({ replace = 'in the mode writing it may call "ping, pong"', with = 'in the mode reading it may call "ping"' })
  assert(new and change.reach == "widens", "another mode's list is not the same line: " .. tostring(change and change.reach))
  new, change = edit({ remove = 'in the mode reading it may call "ping"' })
  assert(new and change.reach == "widens", tostring(change and change.reach))
  new, change = edit({ add = 'in the mode checking it may call "pong"' })
  assert(new and change.reach == "narrows", tostring(change and change.reach))
  -- a move widens
  new, change = edit({ add = "the mode writing moves to reading when the person says so" })
  assert(new and change.reach == "widens", tostring(change and change.reach))
  new, change = edit({ remove = "the mode reading moves to writing when the person says so" })
  assert(new and change.reach == "narrows", tostring(change and change.reach))
end

function T.the_edge_features_verify_on_the_doubles()
  for _, name in ipairs { "modes-edges", "modes-trusted", "modes-policy", "modes-pinned", "modes-rails" } do
    local w = { outs = {}, errs = {} }
    w.out = function (t) w.outs[#w.outs + 1] = t end
    w.err = function (t) w.errs[#w.errs + 1] = t end
    w.read = read
    w.env = function () return nil end
    w.now = function () return 0 end
    local f = root .. "/evals/" .. name .. ".feature"
    local code = cli.main({ "--verify", "--feature", f, f }, w)
    local out = table.concat(w.outs) .. table.concat(w.errs)
    assert(code == 0 and has(out, " 0 failed"), name .. ":\n" .. out)
  end
end


function T.the_mode_tool_asks_whatever_the_trust()
  -- The hole the 2026-09-12 attack run recorded: under `its trust is trusted` the model
  -- moved itself. Now the kit's tool declares ask = "always" and the header says so.
  local a = assert(apply(HEAD .. [[
    And its trust is trusted
    And it starts in the mode reading
    And in the mode reading it may call "ping"
]]))
  assert(a.tools.mode.ask == true and a.tools.mode.always == true, "the mode tool always asks")
  local said = say.render(a)
  assert(not has(said, "always asks first"), "the kit's line says it, not a line of the file:\n" .. said)
  local o = assert(cli.parse({ "--dry-run", "x.feature" }))
  local w = { outs = {}, errs = {} }
  w.out = function (t) w.outs[#w.outs + 1] = t end
  w.err = w.out
  w.read = function () return nil, "missing" end
  w.env = function () return nil end
  w.now = function () return 0 end
  local p, gate, warnings = cli.wire(o, w, a)
  assert(p, tostring(gate))
  local seen = false
  for _, s in ipairs(warnings or {}) do if has(s, "trust: the tool mode always asks first") then seen = true end end
  assert(seen, "the header warns that trust does not answer the mode tool: " .. table.concat(warnings or {}, " | "))
  local plan = cli.plan(a, o, p, gate)
  for i = 1, #plan.gate do
    if plan.gate[i].tool == "mode" then assert(plan.gate[i].asks == true and plan.gate[i].consulted == true, "the plan asks about mode") end
  end
end

return T
