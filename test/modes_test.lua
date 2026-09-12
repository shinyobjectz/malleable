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

return T
