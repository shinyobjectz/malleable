-- docs/spec/say.md: a declaration said back as its Background, and two declarations held
-- to each other.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local agent   = require "agent"
local spec    = require "spec"
local declare = require "declare"
local say     = require "say"
local cli     = require "cli"

local T = {}

local function read(path)
  local f, why = io.open(path, "rb")
  if not f then return nil, (tostring(why):find("No such file") and "missing" or tostring(why)) end
  local t = f:read("*a"); f:close(); return t
end

local dir = here .. "/../showcase"

local function apply(text, base)
  local a = spec.new()
  local info, why = declare.apply(text, a, { read = function (p) return read((base or dir) .. "/" .. p) end })
  return info and a or nil, why
end

local function has(s, needle) return tostring(s):find(needle, 1, true) ~= nil end

local function same_list(x, y)
  if #x ~= #y then return false end
  for i = 1, #x do if x[i] ~= y[i] then return false end end
  return true
end

-- ------------------------------------------------------------------ the identity

function T.every_showcase_said_back_and_applied_again_is_the_same_declaration()
  local p = io.popen("ls '" .. dir .. "'")
  local names = {}
  for line in p:lines() do if line:match("^%d%d%-.*%.feature$") then names[#names + 1] = line end end
  p:close()
  assert(#names >= 19, "expected the showcase files, found " .. #names)
  local checked = 0
  for _, name in ipairs(names) do
    local text = assert(read(dir .. "/" .. name))
    local a = apply(text)
    if a then
      local said, unsaid = say.render(a)
      assert(#unsaid == 0, name .. ": a feature-declared agent has nothing unsaid, got " .. table.concat(unsaid, "; "))
      local b, why = apply(said)
      assert(b, name .. ": the rendering will not load: " .. tostring(why) .. "\n" .. said)
      local again = say.render(b)
      assert(again == said, name .. ": saying it back twice differs:\n" .. said .. "\n---\n" .. again)
      local sa, sb = spec.schema(a), spec.schema(b)
      assert(#sa == #sb, name .. ": the schemas differ in length")
      for i = 1, #sa do
        assert(sa[i].name == sb[i].name and sa[i].about == sb[i].about and sa[i].ask == sb[i].ask, name .. ": " .. sa[i].name)
      end
      checked = checked + 1
    end
  end
  assert(checked >= 17, "checked only " .. checked)
end

-- ------------------------------------------------------------------ a Lua program

function T.a_lua_program_is_said_back_with_its_kits_and_its_unsaid_named()
  local ag = agent.new()
  ag.name "lead"
  ag.model "test:model"
  ag.files { deny = { "secrets/**" } }
  ag.shell { timeout_ms = 20000 }
  ag.tool "verdict" {
    about = "File a verdict.",
    ask = true,
    args = { summary = ag.string "one line", ok = ag.boolean "approved?" },
    run = function (c) return "filed " .. c.args.summary end,
  }
  ag.on "call" (function () return nil end)
  ag.deny "shell"
  local text, unsaid = say.render(ag.spec())
  for _, line in ipairs {
    "Given the agent is called lead",
    'And its model is "test:model"',
    "And it may take 24 steps",
    "And it reads and writes the workspace",
    'And it never touches "secrets/**"',
    "And it runs commands",
    "And each command may run 20 seconds",
    'And it has a tool verdict for "File a verdict.", which takes:',
    "| ok       | boolean | approved? |",
    "| summary  | string  | one line  |",
    "And the tool verdict asks first",
    "And it may never call shell",
  } do assert(has(text, line), "missing: " .. line .. "\n" .. text) end
  assert(not has(text, "it has a tool read"), "a kit's tool is said by the kit's line\n" .. text)
  assert(#unsaid == 2, table.concat(unsaid, "; "))
  assert(has(unsaid[1], "the body of verdict is Lua"), unsaid[1])
  assert(has(unsaid[2], "1 hook (agent.on)"), unsaid[2])
  assert(has(text, "# unsaid, and kept in the program:"), text)
end

function T.a_kits_tool_the_feature_changed_is_one_line_and_the_rest_are_none()
  local a = assert(apply([[
Feature: t
  Background:
    Given the agent is called t
    And its model is "test:model"
    And it reads the workspace
    And the tool read is for "Read one file, carefully."
    And it has a tool ping for "Pong."
    And the tool ping answers "pong"
]]))
  local text = say.render(a)
  assert(has(text, 'And the tool read is for "Read one file, carefully."'), text)
  assert(not has(text, "the tool list"), text)
end

function T.each_kind_of_line_is_said_back()
  local text = [[
Feature: all
  Background:
    Given the agent is called all
    And its model is "test:model"
    And its reasoning is low
    And it may take 9 steps
    And it is briefed:
      """
      Be brief.
      """
    And its trust is ask
    And it keeps a plan
    And it can read its history
    And it keeps a store notes of "one note a row":
      | column | type                      | about    |
      | text   | string                    | the note |
      | tag    | optional one of red, blue | a colour |
    And the store notes is sorted by text
    And it has a tool note for "Keep a note.", which takes:
      | argument | type                      | about    |
      | text     | string                    | the note |
      | tag      | optional one of red, blue | a colour |
    And the tool note adds a row to notes
    And the tool note asks first, letting the person change tag
    And the tool note shows its call before it runs
    And the tool note may be called at most 3 times
    And it has a tool notes for "Every note."
    And the tool notes lists notes
    And the tool notes requires "a quiet hour", checked by:
      """lua
      return true
      """
    And it keeps a skill tidy for "How to tidy.":
      """
      Tidy it.
      """
    And it keeps a skill ship for "How to ship.", in "docs/ship.md"
    And the beat nightly comes every day at "18:00" and asks "summarise the day"
    And the beat nightly runs once per day
    And the beat pulse comes every 60 seconds and asks "anything new?"
    And the step "the queue holds {int} tickets" sets up:
      """lua
      c.world.queue = c.args[1]
      """
    And it uses the server books with:
      | key   | value        |
      | tools | search, open |
      | ask   | true         |
    And it may always call notes
    And it may never call note
]]
  local a = assert(apply(text))
  local said, unsaid = say.render(a)
  assert(#unsaid == 0, table.concat(unsaid, "; "))
  local b, why = apply(said)
  assert(b, tostring(why) .. "\n" .. said)
  assert(say.render(b) == said, said)
  for _, line in ipairs {
    "And its reasoning is low", "And it may take 9 steps", "And it is briefed:", "Be brief.",
    "And it keeps a plan", "And it can read its history", "And the store notes is sorted by text",
    "And the tool note asks first, letting the person change tag", "And the tool note shows its call before it runs",
    "And the tool note may be called at most 3 times", 'And the tool notes requires "a quiet hour", checked by:',
    'And it keeps a skill ship for "How to ship.", in "docs/ship.md"',
    'And the beat nightly comes every day at "18:00" and asks "summarise the day"',
    "And the beat nightly runs once per day", 'And the beat pulse comes every 60 seconds and asks "anything new?"',
    'And the step "the queue holds {int} tickets" sets up:', "And it uses the server books with:",
    "| tools | search, open |", "And it may always call notes", "And it may never call note",
  } do assert(has(said, line), "missing: " .. line .. "\n" .. said) end
end

-- ------------------------------------------------------------------ conformance

local FEATURE = [[
Feature: t
  Background:
    Given the agent is called t
    And its model is "test:model"
    And it has a tool verdict for "File a verdict.", which takes:
      | argument | type   | about    |
      | summary  | string | one line |
    And the tool verdict answers "filed"
    And the tool verdict asks first
    And it may never call verdict
]]

function T.conforms_names_the_line_only_one_side_says()
  local a = assert(apply(FEATURE))
  local r = say.conforms(a, a)
  assert(r.ok, "a file conforms to itself")
  local b = assert(apply((FEATURE:gsub("    And it may never call verdict\n", ""))))
  r = say.conforms(a, b)
  assert(not r.ok)
  assert(#r.only_program == 1 and r.only_program[1] == "it may never call verdict", tostring(r.only_program[1]))
  assert(#r.only_contract == 0)
  local text = say.report(r, { program = "a.feature", contract = "b.feature" })
  assert(has(text, "a.feature says `it may never call verdict`, and b.feature does not"), text)
  r = say.conforms(b, a)
  assert(#r.only_contract == 1 and #r.only_program == 0)
end

function T.a_hook_on_the_program_side_is_reported_and_does_not_fail_the_check()
  local ag = agent.new()
  ag.name "t"
  ag.model "test:model"
  ag.tool "verdict" {
    about = "File a verdict.", ask = true,
    args = { summary = ag.string "one line" },
    run = function () return "filed" end,
  }
  ag.deny "verdict"
  ag.on "call" (function () return nil end)
  local contract = assert(apply(FEATURE))
  local r = say.conforms(ag.spec(), contract)
  -- the body: the contract says `answers "filed"`, the program's is a function
  assert(#r.only_contract == 1 and has(r.only_contract[1], 'answers "filed"'), tostring(r.only_contract[1]))
  assert(#r.only_program == 0, tostring(r.only_program[1]))
  assert(#r.unsaid_program == 2, table.concat(r.unsaid_program, "; "))
  local text = say.report(r, { program = "t.lua", contract = "t.feature" })
  assert(has(text, "t.lua keeps something no line says: 1 hook"), text)
end

-- ------------------------------------------------------------------ the command line

local function world_of(files)
  local w = { outs = {}, errs = {} }
  w.out = function (t) w.outs[#w.outs + 1] = t end
  w.err = function (t) w.errs[#w.errs + 1] = t end
  w.read = function (p)
    local v = files[p]
    if v == nil then return nil, "missing" end
    return v
  end
  w.env = function () return nil end
  w.now = function () return 0 end
  return w
end

local LUA = [[
agent.name "t"
agent.model "test:model"
agent.tool "verdict" {
  about = "File a verdict.", ask = true,
  args = { summary = agent.string "one line" },
  run = function () return "filed" end,
}
agent.deny "verdict"
]]

function T.say_prints_the_rendering_and_conforms_exits_by_the_answer()
  local w = world_of({ ["t.lua"] = LUA, ["t.feature"] = FEATURE, ["u.feature"] = FEATURE:gsub("    And it may never call verdict\n", "") })
  local code = cli.main({ "--say", "t.lua" }, w)
  local out = table.concat(w.outs)
  assert(code == 0, code .. " " .. table.concat(w.errs))
  assert(has(out, "Given the agent is called t") and has(out, "And the tool verdict asks first"), out)
  assert(has(out, "the body of verdict is Lua in the program"), out)

  w = world_of({ ["t.lua"] = LUA, ["t.feature"] = FEATURE, ["u.feature"] = FEATURE:gsub("    And it may never call verdict\n", "") })
  code = cli.main({ "--conforms", "t.feature", "t.lua" }, w)
  out = table.concat(w.outs)
  -- the contract says the body; the program keeps it in Lua: drift
  assert(code == 3, code .. " " .. out .. table.concat(w.errs))
  assert(has(out, 't.feature says `the tool verdict answers "filed"`, and t.lua does not'), out)

  w = world_of({ ["t.feature"] = FEATURE, ["u.feature"] = FEATURE:gsub("    And it may never call verdict\n", "") })
  code = cli.main({ "--conforms", "t.feature", "t.feature" }, w)
  assert(code == 0 and has(table.concat(w.outs), "say the same agent"), table.concat(w.outs))

  w = world_of({ ["t.feature"] = FEATURE, ["u.feature"] = FEATURE:gsub("    And it may never call verdict\n", "") })
  code = cli.main({ "--conforms", "u.feature", "t.feature" }, w)
  assert(code == 3 and has(table.concat(w.outs), "t.feature says `it may never call verdict`, and u.feature does not"), table.concat(w.outs))

  w = world_of({ ["t.feature"] = FEATURE })
  code = cli.main({ "--conforms", "gone.feature", "t.feature" }, w)
  assert(code == 2 and has(table.concat(w.errs), "gone.feature"), code .. table.concat(w.errs))
end

return T
