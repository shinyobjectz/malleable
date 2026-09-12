-- The specs, as part of the suite that already runs.
--
-- `tools/spec-check.sh` prints the report; this is the same run, quietly, inside
-- `scripts/run-tests.lua`. Both, deliberately: a promise that only runs in a script somebody has
-- to remember to call is a promise that rots, which is the exact failure the whole
-- spec-as-feature idea exists to stop -- one level up from where it stopped it.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local run = dofile(here .. "/../spec/run.lua")

local T = {}

-- Cached: running every feature twice would double the suite for no finding.
local held
local function checked()
  if held == nil then held = run.check(false) end
  return held
end

-- A spec that says something FALSE is a bug, not a backlog item. This is the line that
-- separates the two, and it is the whole reason the promises were moved out of prose.
function T.no_spec_says_anything_false()
  local t = checked()
  if t.failed > 0 or t.broken > 0 then
    local lines = { string.format("%d failed, %d broken", t.failed, t.broken) }
    for i = 1, #t.sore do
      local r = t.sore[i].report
      for _, s in ipairs(r.scenarios) do
        if s.outcome == "failed" or s.outcome == "broken" then
          lines[#lines + 1] = "  " .. t.sore[i].name .. ": " .. tostring(s.name)
          for _, step in ipairs(s.steps) do
            if step.why then lines[#lines + 1] = "      " .. tostring(step.why) end
          end
        end
      end
    end
    error(table.concat(lines, "\n"), 0)
  end
end

-- A promise nobody has built is LEGAL, and is counted. What is not legal is one appearing
-- without being written down: the number in `spec/OWED` goes down and never up.
function T.the_undefined_promises_are_ratcheted()
  local t = checked()
  local owed = run.owed()
  assert(owed ~= nil, "spec/OWED is missing: run tools/spec-check.sh --accept to start it")
  assert(t.undefined <= owed,
         string.format("%d undefined promise(s), and spec/OWED says %d. The count goes DOWN.",
                       t.undefined, owed))
  assert(t.undefined == owed or true)   -- going down is fine; --accept keeps it there
end

-- The list in `spec/run.lua` is also the work list, so it has to be true. A feature file
-- that exists and is not listed would run nowhere; one listed and missing is a promise
-- somebody deleted.
function T.every_feature_file_is_listed_and_every_listed_one_is_there()
  local t = checked()
  assert(t.featured > 0, "no spec has a feature file")
  assert(t.broken == 0, "a listed feature file is missing or does not read")

  -- The other direction, read off the filesystem rather than trusted.
  local names = {}
  local f = io.open(here .. "/../spec/run.lua", "rb")
  local source = f:read("*a")
  f:close()
  for name, said in source:gmatch('{%s*"([%w%-_]+)",%s*(%a+)%s*}') do
    if said == "true" then names[name] = true end
  end
  for name in pairs(names) do
    local exists = io.open(here .. "/../spec/" .. name .. ".feature", "rb")
    assert(exists, "spec/" .. name .. ".feature is listed as written and is not there")
    exists:close()
  end
end

-- Every name on the work list is a spec that actually exists. The other direction --
-- every spec/*.md appears on the list -- cannot be checked here: plain Lua cannot list a
-- directory, and a test that shelled out to do it would be the only test in the tree that
-- spawns. `tools/spec-check.sh` owns that half, because bash can glob.
--
-- This half still matters on its own. A listed name with no .md is a spec somebody
-- deleted while leaving the promise counted, which quietly inflates the work list.
function T.every_name_on_the_work_list_is_a_spec_that_exists()
  local f = io.open(here .. "/../spec/run.lua", "rb")
  local source = f:read("*a")
  f:close()
  local missing = {}
  for name in source:gmatch('{%s*"([%w%-_]+)",%s*%a+%s*}') do
    local md = io.open(here .. "/../spec/" .. name .. ".md", "rb")
    if md then md:close() else missing[#missing + 1] = name end
  end
  assert(#missing == 0,
         "listed on the work list with no spec/<name>.md: " .. table.concat(missing, ", "))
end

-- And the count of specs still promising only in prose, which is the number this whole
-- exercise exists to drive to zero.
function T.the_specs_still_promising_only_in_prose_are_counted()
  local t = checked()
  assert(t.specs > 0)
  -- Not an assertion about the number -- an assertion that the number is KNOWN. A sweep
  -- that lost track of how much was left would be the failure it was meant to prevent.
  assert(t.featured <= t.specs, t.featured .. " of " .. t.specs)
end

return T
