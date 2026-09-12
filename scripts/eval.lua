-- Runs a feature file against a real model, k times a scenario, and prints the rates
-- (docs/spec/behaviour.md, "Evaluating"). The world stays the doubles; only the model is
-- real, built by bin/world.lua from OPENROUTER_API_KEY in the environment.
--
--     luajit scripts/eval.lua evals/notebook.feature --samples 5 [--only "it reads"] [--out report.lua]
--            [--model openrouter:z-ai/glm-5.3]
--
-- `--model` puts a real model in place of the one the feature names, so a file written
-- for the doubles (`its model is "test:model"`, as every showcase is) runs against the
-- real one unchanged.
--
-- Every Then line is the same deterministic check as under --verify; nothing here judges
-- an answer with a model. The report is the runner's own, followed by one line a scenario
-- with its rate and, for every failing sample, the step that failed and why, and what
-- the run did (its calls and stop), so a failure is diagnosable and not merely counted.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. here .. "/../bin/?.lua;" .. package.path

local spec      = require "spec"
local declare   = require "declare"
local behaviour = require "behaviour"
local cli       = require "cli"
local store     = require "store"
local turn      = require "turn"
local world     = require "world"

local args = { samples = 3 }
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--samples" then args.samples = tonumber(arg[i + 1]); i = i + 2
  elseif a == "--only" then args.only = arg[i + 1]; i = i + 2
  elseif a == "--out" then args.out = arg[i + 1]; i = i + 2
  elseif a == "--model" then args.model = arg[i + 1]; i = i + 2
  elseif a == "--seed" then args.seed = tonumber(arg[i + 1]) or arg[i + 1]; i = i + 2
  else args.path = a; i = i + 1 end
end
if not args.path then io.stderr:write("usage: luajit scripts/eval.lua FEATURE [--samples N] [--only NAME] [--out FILE] [--model ID] [--seed N]\n"); os.exit(2) end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local t = f:read("*a"); f:close(); return t
end

local text = assert(read_file(args.path), "no feature at " .. args.path)
local dir = args.path:match("^(.*)/[^/]*$") or "."
local decl = spec.new()
local info, why = declare.apply(text, decl, { read = function (p) return read_file(dir .. "/" .. p) end, model = args.model })
if not info then io.stderr:write("the feature will not load: " .. tostring(why) .. "\n"); os.exit(1) end
local pickles, bad = declare.pickles(text, decl)
if not pickles then io.stderr:write(tostring(bad) .. "\n"); os.exit(1) end
if args.only then
  local kept = {}
  for _, p in ipairs(pickles) do if tostring(p.name):find(args.only, 1, true) then kept[#kept + 1] = p end end
  pickles = kept
end

-- the real model, and nothing else real: a scratch root with no history
local scratch = os.tmpname()
os.remove(scratch); os.execute("mkdir -p '" .. scratch .. "'")
local ports, pwhy = world.ports { root = scratch, history = false }
if not ports or not ports.model then io.stderr:write("no real model: " .. tostring(pwhy) .. "\n"); os.exit(1) end

local drivers = cli.drivers(decl, function (prompt, port, ropts)
  local bound = store.bind(decl, port)
  local depth = declare.enter(bound)
  local ok, result = pcall(turn.run, decl, prompt, bound, { budget = ropts and ropts.budget, id = decl.name })
  declare.leave(depth)
  if not ok then error(result, 0) end
  return result
end)

local t0 = os.time()
local report = behaviour.run(pickles, drivers, { eval = { samples = args.samples, model = ports.model } })
local took = os.time() - t0

io.write(behaviour.report(report))
io.write("\n")

-- what each sample did, from the result the runner kept: calls and the stop, never words
local function did(result)
  if type(result) ~= "table" then return "?" end
  local parts = {}
  for _, c in ipairs(result.calls or {}) do
    local why = (c.refused or c.ok == false) and type(c.output) == "string"
      and (" " .. c.output:gsub("%s+", " "):sub(1, 90)) or ""
    parts[#parts + 1] = c.tool .. (c.refused and " (refused" .. why .. ")" or (c.ok == false and " (failed" .. why .. ")" or ""))
  end
  return string.format("stop=%s steps=%d calls=[%s]%s", tostring(result.stop), result.steps or 0, table.concat(parts, ", "),
    result.stop ~= "answered" and result.reason and ("  " .. tostring(result.reason):gsub("%s+", " "):sub(1, 200)) or "")
end

local summary = { feature = args.path, samples = args.samples, seconds = took, scenarios = {},
                  model = args.model or (decl.model and tostring(decl.model)) or nil, seed = args.seed,
                  date = os.date("!%Y-%m-%d %H:%M UTC") }
for _, sc in ipairs(report.scenarios) do
  local rate = sc.outcome
  if sc.rate then
    local lo, hi = behaviour.interval(sc.passes or 0, sc.samples or 0)
    rate = string.format("%d/%d (%.2f-%.2f)", sc.passes or 0, sc.samples or 0, lo, hi)
  end
  local line = string.format("%-56s %s", sc.name, rate)
  if sc.taken and #sc.taken > 0 then
    local parts = {}
    for k = 1, #sc.taken do parts[k] = tostring(sc.taken[k] or "?") end
    line = line .. "  steps " .. table.concat(parts, " ")
  end
  if sc.usage and (sc.usage.sent or 0) > 0 then
    line = line .. string.format("  tokens %d sent, %d back, %d%% cached", sc.usage.sent, sc.usage.back,
      math.floor(100 * sc.usage.cached / sc.usage.sent + 0.5))
  end
  io.write(line, "\n")
  -- the Then lines whose passing needs the script this eval dropped (docs/spec/behaviour.md)
  for _, r in ipairs(sc.reads_script or {}) do
    io.write(string.format("    ~ line %d reads the script: %s\n", r.line, r.why))
  end
  -- every refused or failed call across the samples, grouped by tool and sentence
  local groups, gorder = {}, {}
  for _, r in ipairs(sc.refusals or {}) do
    local key = r.tool .. (r.op and (" " .. r.op) or "") .. " | " .. r.why
    if not groups[key] then groups[key] = { tool = r.tool, op = r.op, why = r.why, failed = r.failed, count = 0, samples = {} }; gorder[#gorder + 1] = key end
    groups[key].count = groups[key].count + 1
    groups[key].samples[r.sample] = true
  end
  local refusals = {}
  for _, key in ipairs(gorder) do
    local g = groups[key]
    local n = 0
    for _ in pairs(g.samples) do n = n + 1 end
    io.write(string.format("    ! %s%s x%d in %d sample(s): %s\n", g.tool, g.op and (" " .. g.op) or "", g.count, n, g.why:sub(1, 160)))
    refusals[#refusals + 1] = { tool = g.tool, op = g.op, why = g.why, failed = g.failed, count = g.count, in_samples = n }
  end
  local entry = { name = sc.name, passes = sc.passes, samples = sc.samples, outcome = sc.outcome, failures = {}, steps = sc.taken, refusals = refusals, usage = sc.usage }
  for _, f in ipairs(sc.failures or {}) do
    local step
    for _, st in ipairs(f.steps or {}) do if st.why and st.outcome ~= "skipped" then step = st; break end end
    local reason = step and (step.text .. " -- " .. step.why) or "?"
    local what = did(f.result or (f.record and f.record.result))
    io.write("    x ", reason, "\n      ", what, "\n")
    entry.failures[#entry.failures + 1] = { why = reason, did = what }
  end
  summary.scenarios[#summary.scenarios + 1] = entry
end
io.write(string.format("%d scenario(s), %d sample(s) each, %d s%s%s\n", #report.scenarios, args.samples, took,
  summary.model and ("  model " .. summary.model) or "", args.seed and ("  seed " .. tostring(args.seed)) or ""))

if args.out then
  local f = assert(io.open(args.out, "wb"))
  local function dump(v, ind)
    ind = ind or ""
    if type(v) == "table" then
      local out = { "{\n" }
      for k, x in pairs(v) do
        out[#out + 1] = ind .. "  [" .. (type(k) == "number" and k or string.format("%q", k)) .. "] = " .. dump(x, ind .. "  ") .. ",\n"
      end
      out[#out + 1] = ind .. "}"
      return table.concat(out)
    elseif type(v) == "string" then return string.format("%q", v)
    else return tostring(v) end
  end
  f:write("return ", dump(summary), "\n")
  f:close()
end
os.execute("rm -rf '" .. scratch .. "'")
