-- Verifies every showcase feature (showcase/*.feature) on the doubles and prints one line
-- a file: what it shows and whether every scenario passed. Exit 1 if any did not.
--
--     luajit scripts/showcase.lua [--verbose]

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. here .. "/../bin/?.lua;" .. package.path

local cli = require "cli"

local verbose = arg[1] == "--verbose"
local dir = here .. "/../showcase"

local function read(path)
  local f, why = io.open(path, "rb")
  if not f then return nil, (tostring(why):find("No such file") and "missing" or tostring(why)) end
  local t = f:read("*a"); f:close(); return t
end

local names = {}
local p = io.popen("ls '" .. dir .. "'")
for line in p:lines() do
  if line:match("^%d%d%-.*%.feature$") then names[#names + 1] = line end
end
p:close()
table.sort(names)

local bad = 0
for _, name in ipairs(names) do
  local out, err = {}, {}
  local code = cli.main({ "--verify", "--feature", dir .. "/" .. name, dir .. "/" .. name }, {
    out = function (t) out[#out + 1] = t end, err = function (t) err[#err + 1] = t end,
    read = read, env = function () return nil end, now = function () return 0 end,
  })
  local text = table.concat(out) .. table.concat(err)
  local source = read(dir .. "/" .. name) or ""
  local passed, failed, undefined, broken = text:match("(%d+) passed, (%d+) failed, (%d+) undefined, (%d+) broken")
  local title = source:match("Feature:%s*([^\n]*)") or name
  -- a file wrong on purpose says what refusal it expects in its first line
  local expect = source:match('^# expect: refused "([^"]*)"')
  local ok, summary
  if expect then
    ok = code ~= 0 and text:find(expect, 1, true) ~= nil
    summary = ok and ("refused as expected: " .. expect) or ("expected a refusal saying " .. expect)
  else
    ok = code == 0 and failed == "0" and undefined == "0" and broken == "0"
    summary = passed and string.format("%s passed, %s failed, %s undefined, %s broken", passed, failed, undefined, broken) or ("exit " .. tostring(code))
  end
  if not ok then bad = bad + 1 end
  io.write(string.format("%-4s %-28s %-24s %s\n", ok and "ok" or "FAIL", name, title, summary))
  if verbose or not ok then io.write(text, "\n") end
end
io.write(string.format("%d showcase(s), %d with a problem\n", #names, bad))
os.exit(bad == 0 and 0 or 1)
