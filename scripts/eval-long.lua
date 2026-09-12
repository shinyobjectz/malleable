-- The long-task eval: one scenario of a feature run against the real model with a REAL
-- shell (bin/subshell.lua), a real folder, and the network open, for as long as its budget
-- and a wall-clock cap allow (docs/spec/behaviour.md, "Evaluating"; docs/spec/subshell.md).
--
--     luajit scripts/eval-long.lua evals/long-task.feature --only "scaffolds" [--root DIR]
--            [--hours 4] [--journal FILE] [--out FILE]
--
-- `--only` may match several scenarios; they run in order into the same folder, each a
-- fresh transcript over what the earlier ones left. That is how a day's work is written:
-- the runner gives a scenario one When, so one scenario a milestone, in one folder.
--
-- Three things are recorded. The JOURNAL is one line an event, appended as it happens,
-- so a person can follow a run that takes hours: each model call with the step, the
-- seconds it took, the estimated size of the transcript sent, and the tools it asked for;
-- each command with its exit status and seconds; each gate approved. The RUNNER'S REPORT
-- is the feature's own Then lines, checked on the result as under --verify. The
-- ACCEPTANCE is what this script does afterwards to what was made: it runs the program's
-- own `npm test`, `npm run build` and `npm run lint`, counts the sources, and measures the
-- folder. Nothing here judges words; every number is a thing that happened.
--
-- Host decisions, in writing: the shell is bin/subshell.lua under `--root` with only PATH
-- and a HOME under the root in the child's environment, so the key never reaches a
-- command; every gate is approved and journalled, because nobody is there; the deadline
-- ends the run by answering the next model call with `unavailable`, which the loop
-- reports as an error stop. The folder is kept for a person to read.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. here .. "/../bin/?.lua;" .. package.path

local spec       = require "spec"
local declare    = require "declare"
local behaviour  = require "behaviour"
local cli        = require "cli"
local store      = require "store"
local turn       = require "turn"
local world      = require "world"
local subshell   = require "subshell"
local compaction = require "compaction"

local args = { hours = 4 }
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--only" then args.only = arg[i + 1]; i = i + 2
  elseif a == "--root" then args.root = arg[i + 1]; i = i + 2
  elseif a == "--hours" then args.hours = tonumber(arg[i + 1]); i = i + 2
  elseif a == "--journal" then args.journal = arg[i + 1]; i = i + 2
  elseif a == "--out" then args.out = arg[i + 1]; i = i + 2
  else args.path = a; i = i + 1 end
end
if not args.path then
  io.stderr:write("usage: luajit scripts/eval-long.lua FEATURE [--only NAME] [--root DIR] [--hours H] [--journal FILE] [--out FILE]\n")
  os.exit(2)
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local t = f:read("*a"); f:close(); return t
end

-- the journal: one line an event, flushed at once
local journal_f = args.journal and assert(io.open(args.journal, "ab")) or nil
local t_start = os.time()
local function journal(line)
  local stamp = string.format("[%s +%5ds] ", os.date("%H:%M:%S"), os.time() - t_start)
  if journal_f then journal_f:write(stamp, line, "\n"); journal_f:flush() end
  io.stdout:write(stamp, line, "\n"); io.stdout:flush()
end

-- the feature
local text = assert(read_file(args.path), "no feature at " .. args.path)
local dir = args.path:match("^(.*)/[^/]*$") or "."
local decl = spec.new()
local info, why = declare.apply(text, decl, { read = function (p) return read_file(dir .. "/" .. p) end })
if not info then io.stderr:write("the feature will not load: " .. tostring(why) .. "\n"); os.exit(1) end
local pickles, bad = declare.pickles(text, decl)
if not pickles then io.stderr:write(tostring(bad) .. "\n"); os.exit(1) end
if args.only then
  local kept = {}
  for _, p in ipairs(pickles) do if tostring(p.name):find(args.only, 1, true) then kept[#kept + 1] = p end end
  pickles = kept
end
if #pickles == 0 then io.stderr:write("no scenario matches --only " .. tostring(args.only) .. "\n"); os.exit(2) end

-- the folder
local root = args.root
if not root then
  root = os.tmpname(); os.remove(root)
end
os.execute("mkdir -p '" .. root .. "/.home'")
local real = io.popen("cd '" .. root .. "' && pwd -P"):read("*l")
root = real or root

-- the ports: the real world's, with this host's shell and an approval that says yes
local ports, pwhy = world.ports { root = root, history = true }
if not ports or not ports.model then io.stderr:write("no real model: " .. tostring(pwhy) .. "\n"); os.exit(1) end
local counts = { commands = 0, timeouts = 0, model_calls = 0, model_failures = 0, approvals = 0, largest = 0, seconds_in_model = 0, seconds_in_commands = 0 }
ports.sh = subshell.port(root, {
  env = { PATH = os.getenv("PATH") or "/usr/bin:/bin", HOME = root .. "/.home", LANG = "C.UTF-8", CI = "1" },
  log = function (line)
    counts.commands = counts.commands + 1
    if line:sub(1, 7) == "timeout" then counts.timeouts = counts.timeouts + 1 end
    local secs = tonumber(line:match(" in (%d+)s:")) or 0
    counts.seconds_in_commands = counts.seconds_in_commands + secs
    journal("sh    " .. line)
  end,
})
ports.ask = {
  request = function (q)
    counts.approvals = counts.approvals + 1
    local what = type(q.args) == "table" and (q.args.command or q.args.path or "") or ""
    journal("gate  " .. tostring(q.tool) .. " approved: " .. tostring(what):sub(1, 120))
    return { allow = true, why = "the eval approves every gate; nobody is there" }
  end,
}

-- the model, journalled and under the deadline
local deadline = t_start + math.floor(args.hours * 3600)
local real_model = ports.model
local step = 0
ports.model = {
  call = function (request)
    if os.time() > deadline then
      counts.model_failures = counts.model_failures + 1
      journal("model the deadline of " .. args.hours .. " hours passed; the call is refused")
      return nil, { port = "model", call = "call", code = "unavailable", message = "the eval's " .. args.hours .. " hours are up" }
    end
    step = step + 1
    local size = compaction.estimate(request.messages or {})
    if size > counts.largest then counts.largest = size end
    local t0 = os.time()
    local reply, err = real_model.call(request)
    local took = os.time() - t0
    counts.model_calls = counts.model_calls + 1
    counts.seconds_in_model = counts.seconds_in_model + took
    if not reply then
      counts.model_failures = counts.model_failures + 1
      journal(string.format("model #%d failed after %ds (%s): %s", step, took, tostring(err and err.code), tostring(err and err.message)))
      return nil, err
    end
    local names = {}
    for _, c in ipairs(reply.calls or {}) do names[#names + 1] = tostring(c.name or c.tool) end
    journal(string.format("model #%d %ds, sent ~%d units, stop=%s, calls=[%s]%s", step, took, size, tostring(reply.stop),
      table.concat(names, ", "), (reply.text and reply.text ~= "") and ("  " .. reply.text:gsub("%s+", " "):sub(1, 100)) or ""))
    return reply, err
  end,
}

journal(string.format("run   %d scenario(s) in %s, up to %s hours", #pickles, root, tostring(args.hours)))

local drivers = cli.drivers(decl, function (prompt, given, ropts)
  -- what the scenario's Given lines put in the doubles' files goes into the real folder
  -- first, so a backlog or a fixture reaches the agent
  if type(given) == "table" and type(given.fs) == "table" and type(given.fs.files) == "table" then
    for path, text in pairs(given.fs.files) do
      local ok, why = ports.fs.write(path, text)
      journal("given " .. path .. (ok and "" or (" not written: " .. tostring(why and why.message or why))))
    end
  end
  local bound = store.bind(decl, ports)
  local depth = declare.enter(bound)
  local ok, result = pcall(turn.run, decl, prompt, bound, { budget = ropts and ropts.budget, id = decl.name })
  declare.leave(depth)
  if not ok then error(result, 0) end
  journal(string.format("stop  %s after %d steps: %s", tostring(result.stop), result.steps or 0, tostring(result.reason or result.answer or ""):gsub("%s+", " "):sub(1, 300)))
  return result
end)

local scenarios = {}
for _, pickle in ipairs(pickles) do
  journal("begin " .. pickle.name)
  local t1 = os.time()
  local report = behaviour.run({ pickle }, drivers, { eval = { samples = 1, model = ports.model } })
  io.write(behaviour.report(report), "\n")
  local sc = report.scenarios[1]
  sc.seconds = os.time() - t1
  scenarios[#scenarios + 1] = sc
  journal(string.format("end   %s: %s in %ds", sc.name, sc.outcome, sc.seconds))
  for _, st in ipairs(sc.steps or {}) do
    if st.why then journal("      failed: " .. st.text .. " -- " .. st.why) end
  end
end

-- acceptance: what was made, by its own tests, build and lint
local function run_in_root(line)
  local r, err = ports.sh.run({ "sh", "-c", line }, { timeout = 600 })
  if not r then return { code = -1, out = "", err = tostring(err and err.code) } end
  return r
end
local accept = {}
local has_package = read_file(root .. "/package.json") ~= nil
accept.package_json = has_package
if has_package then
  for _, name in ipairs { "test", "build", "lint" } do
    local r = run_in_root("npm run " .. name .. " --silent 2>&1")
    r.out = (r.out or ""):sub(-4000)
    accept[name] = r.code
    journal(string.format("check npm run %s -> exit %d", name, r.code))
    if r.code ~= 0 then journal("      " .. (r.out or ""):gsub("\n", "\n      "):sub(1, 1500)) end
  end
end
local files = run_in_root("find . -path ./node_modules -prune -o -path ./.malleable -prune -o -path ./.home -prune -o -type f -print | sort")
accept.files = {}
for l in (files.out or ""):gmatch("[^\n]+") do accept.files[#accept.files + 1] = l end
local loc = run_in_root("find . -path ./node_modules -prune -o -path ./.malleable -prune -o -path ./.home -prune -o \\( -name '*.ts' -o -name '*.tsx' \\) -type f -print0 | xargs -0 cat 2>/dev/null | wc -l")
accept.ts_lines = tonumber((loc.out or ""):match("%d+")) or 0
local size = run_in_root("du -sh . | cut -f1")
accept.size = (size.out or ""):gsub("%s+$", "")

local took = os.time() - t_start
local passed = 0
for _, sc in ipairs(scenarios) do if sc.outcome == "passed" then passed = passed + 1 end end
journal(string.format("done  %d of %d scenario(s) passed in %ds; %d model calls (%ds, %d failed, largest ~%d units), %d commands (%ds, %d timed out), %d gates; %d files, %d lines of TypeScript, %s on disk",
  passed, #scenarios, took, counts.model_calls, counts.seconds_in_model, counts.model_failures, counts.largest,
  counts.commands, counts.seconds_in_commands, counts.timeouts, counts.approvals, #accept.files, accept.ts_lines, accept.size))
journal(string.format("      package.json %s; npm test %s; build %s; lint %s", tostring(accept.package_json),
  tostring(accept.test), tostring(accept.build), tostring(accept.lint)))

if args.out then
  local f = assert(io.open(args.out, "wb"))
  f:write("return {\n")
  f:write(string.format("  seconds = %d, root = %q,\n  scenarios = {\n", took, root))
  for _, sc in ipairs(scenarios) do
    f:write(string.format("    { name = %q, outcome = %q, seconds = %d },\n", sc.name, sc.outcome, sc.seconds or 0))
  end
  f:write("  },\n")
  f:write("  counts = {")
  for k, v in pairs(counts) do f:write(string.format(" %s = %s,", k, tostring(v))) end
  f:write(" },\n")
  f:write(string.format("  accept = { package_json = %s, test = %s, build = %s, lint = %s, files = %d, ts_lines = %d, size = %q },\n",
    tostring(accept.package_json), tostring(accept.test), tostring(accept.build), tostring(accept.lint), #accept.files, accept.ts_lines, accept.size))
  f:write("  files = {\n")
  for _, l in ipairs(accept.files) do f:write(string.format("    %q,\n", l)) end
  f:write("  },\n}\n")
  f:close()
end
if journal_f then journal_f:close() end
