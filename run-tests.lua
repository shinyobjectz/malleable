-- The test runner. No framework: it finds every test/*_test.lua, requires it for the
-- table of named functions it returns, calls each one, and prints a line per test.
--
-- A test is a function on that table. It asserts and returns nothing; anything it
-- raises is the failure, printed with its message. Order is alphabetical by file and
-- then by name, so two runs of an unchanged tree print the same lines.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/src/?.lua;" .. here .. "/?.lua;" .. package.path

-- The file list. `io.popen` is the only way a stock Lua sees a directory, and a run
-- with no `ls` should say so rather than report zero failures out of zero tests.
local function test_files(dir)
  local names = {}
  local pipe = io.popen('ls "' .. dir .. '" 2>/dev/null')
  if pipe then
    for line in pipe:lines() do
      if line:match("_test%.lua$") then names[#names + 1] = line end
    end
    pipe:close()
  end
  table.sort(names)
  return names
end

local function sorted_keys(t)
  local keys = {}
  for k, v in pairs(t) do
    if type(v) == "function" then keys[#keys + 1] = k end
  end
  table.sort(keys)
  return keys
end

local only = arg and arg[1]        -- run one file, or the tests whose name contains this

local files = test_files(here .. "/test")
if #files == 0 then
  io.stderr:write("no test files found under " .. here .. "/test\n")
  os.exit(1)
end

local passed, failed, failures = 0, 0, {}

for _, file in ipairs(files) do
  local module = file:gsub("%.lua$", "")
  if only and not (file:find(only, 1, true) or module:find(only, 1, true)) then
    module = nil
  end
  if module then
    local loaded, T = pcall(dofile, here .. "/test/" .. file)
    if not loaded or type(T) ~= "table" then
      failed = failed + 1
      local why = loaded and ("returned " .. type(T) .. ", not a table of tests") or tostring(T)
      print(string.format("FAIL  %s  <the file itself>  %s", module, why))
      failures[#failures + 1] = module .. ": " .. why
    else
      for _, name in ipairs(sorted_keys(T)) do
        local ok, err = pcall(T[name])
        if ok then
          passed = passed + 1
          print(string.format("ok    %s  %s", module, name))
        else
          failed = failed + 1
          print(string.format("FAIL  %s  %s", module, name))
          print("        " .. tostring(err):gsub("\n", "\n        "))
          failures[#failures + 1] = module .. "  " .. name
        end
      end
    end
  end
end

print("")
if failed == 0 then
  print(string.format("%d passed", passed))
  os.exit(0)
end
print(string.format("%d passed, %d failed", passed, failed))
for _, f in ipairs(failures) do print("  " .. f) end
os.exit(1)
