-- docs/spec/kit.md: a capability a workspace adds, said in the vocabulary and scored by
-- the wall.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local agent   = require "agent"
local spec    = require "spec"
local declare = require "declare"
local kits    = require "kits"
local say     = require "say"
local cli     = require "cli"

local T = {}

local dir = here .. "/../showcase"

local function read(path)
  local f, why = io.open(path, "rb")
  if not f then return nil, (tostring(why):find("No such file") and "missing" or tostring(why)) end
  local t = f:read("*a"); f:close(); return t
end

local function has(s, needle) return tostring(s):find(needle, 1, true) ~= nil end

local function apply(text, files)
  local a = spec.new()
  local info, why = declare.apply(text, a, { read = function (p)
    if files and files[p] then return files[p] end
    return read(dir .. "/" .. p)
  end })
  return info and a or nil, why
end

local CALENDAR = assert(read(dir .. "/kits/calendar.lua"))

-- a kit table with one field changed, as text, so a bad shape is loaded through the file door
local function kit_text(patch)
  return CALENDAR:gsub("\n%s*says = function", "\n" .. patch .. "\n  says = function", 1)
end

-- ------------------------------------------------------------------ the shape

function T.a_kit_with_each_rule_broken_is_refused_naming_the_rule()
  local cases = {
    { "return 1", "a kit is a table" },
    { 'return { name = "bad name", about = "x", is = {}, install = function () end }', "`name` is a word" },
    { 'return { name = "files", about = "x", is = {}, install = function () end }', "the name of a built-in kit" },
    { 'return { name = "k", is = {}, install = function () end }', "needs `about`" },
    { 'return { name = "k", about = "x", is = {}, install = function () end }', "needs `is`: at least one line" },
    { 'return { name = "k", about = "x", is = { { expr = "it keeps a thing", about = "y", tells = function () end } }, install = function () end }', "needs `reach`" },
    { 'return { name = "k", about = "x", is = { { expr = "it keeps a thing", reach = "widens", about = "y" } }, install = function () end }', "needs `tells" },
    { 'return { name = "k", about = "x", is = { { expr = "it keeps a thing", reach = "widens", about = "y", tells = function () end } } }', "needs `install" },
    { 'return { name = "k", about = "x", is = { { expr = "it keeps a thing", reach = "widens", about = "y", tells = function () end } }, install = function () end, steps = { { expr = "it did", given = function () end, then_ = function () end } } }', "one of them" },
    { 'return { name = "k", about = "x", is = { { expr = "the agent is called {word}", reach = "widens", about = "y", tells = function () end } }, install = function () end }', "reads as the is line" },
    { 'return { name = "k", about = "x", is = { { expr = "it keeps a thing", reach = "widens", about = "y", tells = function () end } }, install = function () end, steps = { { expr = "it calls {word}", then_ = function () end } } }', "collides with the built-in" },
    { 'local x = io.open("/dev/null") return {}', "io is not here" },
  }
  for i, c in ipairs(cases) do
    local a, why = apply([[
Feature: t
  Background:
    Given the agent is called t
    And its model is "test:model"
    And it uses the kit "bad.lua"
    And it has a tool ping for "Pong."
    And the tool ping answers "pong"
]], { ["bad.lua"] = c[1] })
    assert(a == nil, "case " .. i .. " loaded")
    assert(has(why, c[2]) and has(why, "bad.lua"), "case " .. i .. ": " .. tostring(why))
  end
end

-- ------------------------------------------------------------------ loading and using

function T.the_showcase_kit_loads_and_its_lines_are_vocabulary_after_and_not_before()
  -- before the kit line, its line is nothing (in a fresh process it would be; here the
  -- suite may have loaded it already, so the check is that the loader names the file)
  local a, why = apply([[
Feature: t
  Background:
    Given the agent is called t
    And its model is "test:model"
    And it uses the kit "kits/gone.lua"
    And it keeps a calendar
]])
  assert(a == nil and has(why, "kits/gone.lua"), tostring(why))

  a = assert(apply([[
Feature: t
  Background:
    Given the agent is called t
    And its model is "test:model"
    And it keeps a calendar
    And the calendar holds at most 3 events
    And it uses the kit "kits/calendar.lua"
]]))
  -- order-free: the kit line came last and its lines were still read
  assert(a.tools.book and a.tools.agenda and a.stores.events, "the kit installed nothing")
  assert(a.kits.calendar.told.limit == 3 and a.kits.calendar.told.keeps == true, "the lines told the kit nothing")
  assert(a.kits.calendar.tools.book and a.kits.calendar.stores.events, "the kit did not record what it put on the agent")
  assert(a.steps["the calendar has {string} at {string}"].kit == "calendar", "the kit's steps are not marked as its")
  assert(has(a.tools.book.about, "at most 3"), a.tools.book.about)

  local line = declare.is_line("the calendar holds at most 3 events")
  assert(line and line.reach == "narrows", "the wall does not read the kit's reach")
  assert(declare.is_line("it keeps a calendar").reach == "widens")
  assert(declare.is_line('it uses the kit "x.lua"').reach == "widens")

  local words = {}
  for _, v in ipairs(declare.vocabulary()) do if v.kit == "calendar" then words[#words + 1] = v.expr end end
  assert(#words == 2, "the vocabulary lists " .. #words .. " kit lines")
end

function T.the_same_file_twice_is_nothing_and_another_file_with_the_name_is_refused()
  local a = assert(apply([[
Feature: t
  Background:
    Given the agent is called t
    And its model is "test:model"
    And it uses the kit "kits/calendar.lua"
    And it uses the kit "kits/calendar.lua"
    And it keeps a calendar
]]))
  assert(a.tools.book, "not installed")
  local b, why = apply([[
Feature: t
  Background:
    Given the agent is called t
    And its model is "test:model"
    And it uses the kit "other/calendar.lua"
    And it keeps a calendar
]], { ["other/calendar.lua"] = CALENDAR })
  assert(b == nil and has(why, "already loaded from") and has(why, "kits/calendar.lua") and has(why, "other/calendar.lua"), tostring(why))
end

function T.a_scenario_says_the_world_with_the_kits_step_and_reads_it_with_the_other()
  local w = { outs = {}, errs = {} }
  w.out = function (t) w.outs[#w.outs + 1] = t end
  w.err = function (t) w.errs[#w.errs + 1] = t end
  w.read = read
  w.env = function () return nil end
  w.now = function () return 0 end
  local f = dir .. "/20-kits.feature"
  local code = cli.main({ "--verify", "--feature", f, f }, w)
  assert(code == 0, table.concat(w.outs) .. table.concat(w.errs))
  assert(has(table.concat(w.outs), "2 passed, 0 failed"), table.concat(w.outs))

  -- --check is silent about a kit's step nobody used
  w.outs, w.errs = {}, {}
  code = cli.main({ "--check", f }, w)
  assert(code == 0 and not has(table.concat(w.outs), "no scenario in this feature uses it"), table.concat(w.outs) .. table.concat(w.errs))
end

-- ------------------------------------------------------------------ said back

function T.a_feature_that_uses_a_kit_is_said_back_verbatim_and_applies_again()
  local text = assert(read(dir .. "/20-kits.feature"))
  local a = assert(apply(text))
  local said, unsaid = say.render(a)
  assert(#unsaid == 0, table.concat(unsaid, "; "))
  for _, l in ipairs { 'And it uses the kit "kits/calendar.lua"', "And it keeps a calendar",
                       "And the calendar holds at most 2 events" } do
    assert(has(said, l), "missing " .. l .. "\n" .. said)
  end
  assert(not has(said, "it keeps a store events") and not has(said, "it has a tool book"), "a kit's store and tools are said by its line\n" .. said)
  local b, why = apply(said)
  assert(b, tostring(why) .. "\n" .. said)
  assert(say.render(b) == said)
end

function T.used_from_lua_a_kit_says_itself_back_and_one_without_says_is_unsaid()
  -- the same kit under another name: a copy of a loaded file is another kit, and the
  -- registry refuses two kits of one name, so the Lua door gets its own
  local text = CALENDAR:gsub("calendar", "diary")
  local chunk = assert((load or loadstring)(text, "=diary"))
  local def = chunk()
  local ag = agent.new()
  ag.name "planner"
  ag.model "test:model"
  ag.kit(def, { keeps = true, limit = 2 })
  assert(ag.spec().tools.book and ag.spec().stores.events)
  local said, unsaid = say.render(ag.spec())
  assert(#unsaid == 0, table.concat(unsaid, "; "))
  assert(has(said, "And it keeps a diary") and has(said, "And the diary holds at most 2 events"), said)
  assert(not has(said, "it uses the kit"), "a kit from Lua names no file\n" .. said)

  local mute = {
    name = "mute", about = "a kit with nothing to say",
    is = { { expr = "it keeps quiet", reach = "neither", about = "nothing", tells = function () end } },
    install = function (_, s) s.tool "hush" { about = "Hush.", run = function () return "..." end } end,
  }
  local ag2 = agent.new()
  ag2.name "q"
  ag2.model "test:model"
  ag2.kit(mute, {})
  local _, unsaid2 = say.render(ag2.spec())
  assert(#unsaid2 == 1 and has(unsaid2[1], "the kit mute was used from Lua"), table.concat(unsaid2, "; "))

  -- and a contract that says the kit's lines, which the process now knows, says the same agent
  local contract = assert(apply([[
Feature: planner
  Background:
    Given the agent is called planner
    And its model is "test:model"
    And it keeps a diary
    And the diary holds at most 2 events
]]))
  local r = say.conforms(ag.spec(), contract)
  assert(r.ok, say.report(r))
end

return T
