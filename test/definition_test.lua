-- The definition file, against the real surface.
--
-- A definition file that is not tested is a lie with autocomplete. This enumerates the
-- keys of the real `agent` and `interpret` tables and fails if `library/agent.def.lua`
-- omits one or names one that does not exist -- in both directions, because a stale name
-- in an editor's completion list is as bad as a missing one and lasts longer.
--
-- It reads the file as TEXT rather than loading it. `---@meta` is not a module: loading
-- it would define an `agent` that runs nothing, and a test that passed against that would
-- be testing the wrong table.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local agent = require "agent"

local T = {}

local function source()
  local f = assert(io.open(here .. "/../library/agent.def.lua", "rb"),
                   "library/agent.def.lua is missing")
  local text = f:read("*a")
  f:close()
  return text
end

-- Every name the file states about a prefix, however it states it: `function p.x()`,
-- `p.x = {}`, or a field on the class table.
local function named(text, prefix)
  local out = {}
  for name in text:gmatch("function%s+" .. prefix .. "%.([%w_]+)%s*%(") do out[name] = true end
  for name in text:gmatch("\n" .. prefix .. "%.([%w_]+)%s*=") do out[name] = true end
  return out
end

local function keys(t)
  local out = {}
  for k in pairs(t) do if type(k) == "string" then out[k] = true end end
  return out
end

local function missing(real, stated)
  local out = {}
  for k in pairs(real) do if not stated[k] then out[#out + 1] = k end end
  table.sort(out)
  return out
end

function T.the_definition_file_states_every_name_the_agent_prefix_has()
  local stated = named(source(), "agent")
  local gaps = missing(keys(agent), stated)
  assert(#gaps == 0,
    "library/agent.def.lua does not state: " .. table.concat(gaps, ", "))
end

function T.the_definition_file_states_no_name_the_agent_prefix_does_not_have()
  local stated = named(source(), "agent")
  local invented = missing(stated, keys(agent))
  assert(#invented == 0,
    "library/agent.def.lua states names that do not exist: " .. table.concat(invented, ", "))
end

function T.the_definition_file_states_every_name_the_interpret_prefix_has()
  local stated = named(source(), "interpret")
  local gaps = missing(keys(agent.interpret), stated)
  assert(#gaps == 0,
    "library/agent.def.lua does not state interpret: " .. table.concat(gaps, ", "))
end

function T.the_definition_file_states_no_interpret_name_that_does_not_exist()
  local stated = named(source(), "interpret")
  local invented = missing(stated, keys(agent.interpret))
  assert(#invented == 0,
    "library/agent.def.lua states interpret names that do not exist: " .. table.concat(invented, ", "))
end

function T.the_definition_file_is_annotation_and_cannot_run()
  local text = source()
  assert(text:match("^%-%-%-@meta"), "it does not open with ---@meta")
  -- No `require`, no body: every function in it is empty, which is what `---@meta` means.
  assert(not text:find("%f[%w]require%f[%W]"), "the definition file requires something")
  assert(not text:find("%f[%w]io%."), "the definition file names io")
  assert(not text:find("%f[%w]os%."), "the definition file names os")
  -- It parses, so an editor can read it.
  assert(loadfile(here .. "/../library/agent.def.lua"), "it does not parse")
end

return T
