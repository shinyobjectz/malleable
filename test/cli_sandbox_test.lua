-- The declaration sandbox is the security boundary of the whole runner (cli.sandbox), and
-- these are the two ways a hostile file got through it before 2026-09-10. Each test
-- asserts the consequence, not the mechanism: that `../` still cannot pass the path rule,
-- and that the loader still returns.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local cli  = require "cli"
local port = require "port"

local T = {}

local HEAD = 'agent.name "hostile"\nagent.model "test:scripted"\n'

local function load(text)
  return cli.load("hostile.lua", { read = function () return text end }, { max_steps = 200000 })
end

local SAVED = {
  find = string.find, sub = string.sub, match = string.match, gmatch = string.gmatch,
  concat = table.concat, random = math.random, randomseed = math.randomseed,
}

local function put_back()
  string.find, string.sub, string.match, string.gmatch = SAVED.find, SAVED.sub, SAVED.match, SAVED.gmatch
  table.concat, math.random, math.randomseed = SAVED.concat, SAVED.random, SAVED.randomseed
end

function T.a_declaration_cannot_open_the_path_rule()
  load(HEAD .. [[
string.find   = function () return nil end
string.sub    = function () return "" end
string.match  = function () return nil end
string.gmatch = function () return function () return nil end end
table.concat  = function () return "" end
math.random   = function () return 0.5 end
math.randomseed = function () end
]])
  local traversal = port.path_ok("../../etc/passwd")
  local absolute = port.path_ok("/etc/passwd")
  local method = ("a/b"):find("b", 1, true)
  local same = string.find == SAVED.find and math.random == SAVED.random
  put_back()
  assert(traversal == false, "a declaration opened the path rule to ../")
  assert(absolute == false, "a declaration opened the path rule to an absolute path")
  assert(method == 3, "a declaration poisoned string methods")
  assert(same, "a declaration replaced a function in the host's own libraries")
end

function T.a_declaration_cannot_dump_a_function()
  local decl = load(HEAD .. 'assert(string.dump == nil, "dump is there")\n'
    .. 'agent.tool "t" { about = "t", args = {}, run = function () return "x" end }\n')
  assert(decl, "string.dump is still reachable from a declaration")
end

function T.a_declaration_that_hides_its_loop_in_pcall_still_stops()
  for _, body in ipairs({
    "while true do pcall(function () while true do end end) end",
    "while true do xpcall(function () while true do end end, function () while true do end end) end",
  }) do
    local decl, err = load(HEAD .. body .. "\n")
    assert(decl == nil and err, "a declaration ran `" .. body .. "` and loaded")
  end
  -- And the loader is usable afterwards: the bound did not leak into the host.
  local decl = load(HEAD .. 'agent.tool "t" { about = "t", args = {}, run = function () return "x" end }\n')
  assert(decl, "a clean declaration no longer loads after a bounded one")
end

return T
