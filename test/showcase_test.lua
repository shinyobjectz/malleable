-- docs/showcase.md: every showcase feature verifies, and the two that are wrong on purpose
-- are refused with the sentence their first line expects.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local cli = require "cli"

local T = {}

local dir = here .. "/../showcase"

local function read(path)
  local f, why = io.open(path, "rb")
  if not f then return nil, (tostring(why):find("No such file") and "missing" or tostring(why)) end
  local t = f:read("*a"); f:close(); return t
end

local function verify(name)
  local out, err = {}, {}
  local code = cli.main({ "--verify", "--feature", dir .. "/" .. name, dir .. "/" .. name }, {
    out = function (t) out[#out + 1] = t end, err = function (t) err[#err + 1] = t end,
    read = read, env = function () return nil end, now = function () return 0 end,
  })
  return code, table.concat(out) .. table.concat(err)
end

local function names()
  local out = {}
  local p = io.popen("ls '" .. dir .. "'")
  for line in p:lines() do
    if line:match("^%d%d%-.*%.feature$") then out[#out + 1] = line end
  end
  p:close()
  table.sort(out)
  return out
end

function T.every_showcase_verifies_or_is_refused_as_its_first_line_says()
  local list = names()
  assert(#list >= 19, #list .. " showcase features")
  for _, name in ipairs(list) do
    local source = assert(read(dir .. "/" .. name))
    local expect = source:match('^# expect: refused "([^"]*)"')
    local code, text = verify(name)
    if expect then
      assert(code ~= 0 and text:find(expect, 1, true), name .. ": expected a refusal saying " .. expect .. "\n" .. text)
    else
      assert(code == 0, name .. " exited " .. tostring(code) .. "\n" .. text)
      assert(text:find(" 0 failed, 0 undefined, 0 broken", 1, true), name .. ":\n" .. text)
    end
  end
end

return T
