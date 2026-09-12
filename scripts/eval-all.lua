-- Runs every eval file that names a real model, at one sample count, on one or more
-- models, in parallel batches of scripts/eval.lua processes, and merges the reports into
-- one dated file (docs/spec/behaviour.md, "The report"; docs/confidence-plan.md, item 1).
--
--     luajit scripts/eval-all.lua [--samples 10] [--batches 3] [--seed 1] [--models a,b]
--                                 [--only author,notebook] [--out docs/evals/2026-09-12.md]
--
-- A batch is one eval.lua process running samples/batches samples of every scenario of one
-- file on one model; the batches of one (file, model) run at once, since the API allows it
-- and the doubles make samples independent. The merged report has, per file and model, one
-- row a scenario with passes/samples, the Wilson interval and the steps, then every
-- failure's reason and what the run did, so a rate is diagnosable and not only counted.
-- The .lua beside the .md is the merged table, for a script that compares two runs.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
local root = here .. "/.."
package.path = root .. "/?.lua;" .. root .. "/src/?.lua;" .. package.path
local behaviour = require "behaviour"

local args = { samples = 10, batches = 3, seed = 1, models = {}, only = nil }
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--samples" then args.samples = tonumber(arg[i + 1]); i = i + 2
  elseif a == "--batches" then args.batches = tonumber(arg[i + 1]); i = i + 2
  elseif a == "--seed" then args.seed = tonumber(arg[i + 1]) or arg[i + 1]; i = i + 2
  elseif a == "--models" then for m in arg[i + 1]:gmatch("[^,]+") do args.models[#args.models + 1] = m end; i = i + 2
  elseif a == "--only" then args.only = {}; for m in arg[i + 1]:gmatch("[^,]+") do args.only[#args.only + 1] = m end; i = i + 2
  elseif a == "--out" then args.out = arg[i + 1]; i = i + 2
  else io.stderr:write("unknown option " .. a .. "\n"); os.exit(2) end
end
if #args.models == 0 then args.models[1] = "" end   -- the model each file names
local day = os.date("!%Y-%m-%d")
args.out = args.out or (root .. "/docs/evals/" .. day .. ".md")

local function read(p) local f = io.open(p, "rb"); if not f then return nil end local t = f:read("*a"); f:close(); return t end
local function sh(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

-- the files: every evals/*.feature whose Background names a real model
local files = {}
do
  local p = io.popen("ls " .. sh(root .. "/evals"))
  for name in p:lines() do
    if name:match("%.feature$") then
      local text = read(root .. "/evals/" .. name) or ""
      local model = text:match('its model is "([^"]+)"')
      local wanted = true
      if args.only then
        wanted = false
        for _, o in ipairs(args.only) do if name:find(o, 1, true) then wanted = true end end
      end
      if wanted and model and not model:match("^test:") then files[#files + 1] = name end
    end
  end
  p:close()
end
if #files == 0 then io.stderr:write("no eval file names a real model\n"); os.exit(1) end

-- the batches, all at once, each into its own part file
local scratch = os.tmpname(); os.remove(scratch); os.execute("mkdir -p " .. sh(scratch))
local per = math.max(1, math.floor(args.samples / args.batches))
local parts, cmds = {}, {}
for _, name in ipairs(files) do
  for _, model in ipairs(args.models) do
    for b = 1, args.batches do
      local n = (b == args.batches) and (args.samples - per * (args.batches - 1)) or per
      if n > 0 then
        local part = string.format("%s/%s.%d.%d.lua", scratch, name, (model == "" and 0 or #model), b)
        local log = part .. ".log"
        parts[#parts + 1] = { file = name, model = model, part = part, log = log }
        cmds[#cmds + 1] = string.format("luajit %s %s --samples %d --seed %s --out %s%s > %s 2>&1 &",
          sh(root .. "/scripts/eval.lua"), sh(root .. "/evals/" .. name), n, tostring(args.seed), sh(part),
          model ~= "" and (" --model " .. sh(model)) or "", sh(log))
      end
    end
  end
end
io.write(string.format("%d file(s) x %d model(s) x %d batch(es): %d process(es), %d sample(s) a scenario\n",
  #files, #args.models, args.batches, #cmds, args.samples))
local t0 = os.time()
os.execute(table.concat(cmds, "\n") .. "\nwait")
local took = os.time() - t0

-- merge: per (file, model) per scenario
local merged, order = {}, {}
for _, p in ipairs(parts) do
  local key = p.file .. "|" .. p.model
  local chunk = loadfile(p.part)
  local ok, summary = pcall(chunk or function () error("no report: " .. (read(p.log) or "no log"):sub(1, 300)) end)
  if not merged[key] then
    merged[key] = { file = p.file, model = p.model, scenarios = {}, names = {}, faults = {} }
    order[#order + 1] = key
  end
  local m = merged[key]
  if not ok or type(summary) ~= "table" then
    m.faults[#m.faults + 1] = tostring(summary)
  else
    m.model = (m.model ~= "" and m.model) or summary.model or ""
    for _, sc in ipairs(summary.scenarios or {}) do
      local s = m.scenarios[sc.name]
      if not s then
        s = { name = sc.name, passes = 0, samples = 0, steps = {}, failures = {}, outcome = sc.outcome }
        m.scenarios[sc.name] = s
        m.names[#m.names + 1] = sc.name
      end
      s.passes = s.passes + (sc.passes or 0)
      s.samples = s.samples + (sc.samples or 0)
      for _, st in ipairs(sc.steps or {}) do s.steps[#s.steps + 1] = st end
      for _, f in ipairs(sc.failures or {}) do s.failures[#s.failures + 1] = f end
      s.refusals = s.refusals or {}
      for _, r in ipairs(sc.refusals or {}) do
        local key = r.tool .. (r.op and (" " .. r.op) or "") .. " | " .. r.why
        local g = s.refusals[key]
        if not g then g = { tool = r.tool, op = r.op, why = r.why, failed = r.failed, count = 0, in_samples = 0 }; s.refusals[key] = g end
        g.count = g.count + (r.count or 0)
        g.in_samples = g.in_samples + (r.in_samples or 0)
      end
    end
  end
end

-- the report
local out = {}
local function w(fmt, ...) out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end
w("# Eval run %s", day)
w("")
w("Generated by `scripts/eval-all.lua` (docs/spec/behaviour.md, \"The report\"). %d sample(s) a scenario in %d batch(es); seed %s; %d s wall clock. The interval is the 95%% Wilson interval of the rate; two rates differ only when their intervals do not overlap.",
  args.samples, args.batches, tostring(args.seed), took)
w("")
local table_out = { day = day, samples = args.samples, batches = args.batches, seed = args.seed, seconds = took, runs = {} }
for _, key in ipairs(order) do
  local m = merged[key]
  w("## `evals/%s` on `%s`", m.file, m.model ~= "" and m.model or "the model the file names")
  w("")
  for _, fault in ipairs(m.faults) do w("A batch gave no report: %s", fault); w("") end
  w("| scenario | passes | interval | steps |")
  w("| --- | --- | --- | --- |")
  local run = { file = m.file, model = m.model, scenarios = {} }
  for _, name in ipairs(m.names) do
    local s = m.scenarios[name]
    local lo, hi = behaviour.interval(s.passes, s.samples)
    local steps = {}
    for k = 1, #s.steps do steps[k] = tostring(s.steps[k]) end
    w("| %s | %d/%d | %.2f-%.2f | %s |", name, s.passes, s.samples, lo, hi, table.concat(steps, " "))
    run.scenarios[#run.scenarios + 1] = { name = name, passes = s.passes, samples = s.samples, lo = lo, hi = hi, steps = s.steps, failures = s.failures }
  end
  w("")
  for _, name in ipairs(m.names) do
    local s = m.scenarios[name]
    if #s.failures > 0 then
      w("**%s**, %d failure(s):", name, #s.failures)
      w("")
      for _, f in ipairs(s.failures) do w("* %s  \n  `%s`", f.why, f.did) end
      w("")
    end
  end
  table_out.runs[#table_out.runs + 1] = run
end

-- the refusals across every file and model: the sentences the models read most, with the
-- calls that drew them (docs/confidence-plan.md, item 4: a sentence drawn in more than one
-- sample wants a tolerance or a rewrite)
local all, aorder = {}, {}
for _, key in ipairs(order) do
  local m = merged[key]
  for _, name in ipairs(m.names) do
    for rkey, g in pairs(m.scenarios[name].refusals or {}) do
      local a = all[rkey]
      if not a then a = { tool = g.tool, op = g.op, why = g.why, failed = g.failed, count = 0, in_samples = 0, where = {} }; all[rkey] = a; aorder[#aorder + 1] = rkey end
      a.count = a.count + g.count
      a.in_samples = a.in_samples + g.in_samples
      a.where[#a.where + 1] = m.file .. ": " .. name
    end
  end
end
table.sort(aorder, function (x, y) return all[x].in_samples > all[y].in_samples or (all[x].in_samples == all[y].in_samples and x < y) end)
if #aorder > 0 then
  w("## Refusals, most drawn first")
  w("")
  w("| samples | calls | tool | the sentence the model read |")
  w("| --- | --- | --- | --- |")
  for _, rkey in ipairs(aorder) do
    local a = all[rkey]
    w("| %d | %d | %s%s%s | %s |", a.in_samples, a.count, a.tool, a.op and (" " .. a.op) or "", a.failed and " (failed)" or "", (a.why:gsub("|", "\\|")))
  end
  w("")
  table_out.refusals = {}
  for _, rkey in ipairs(aorder) do table_out.refusals[#table_out.refusals + 1] = all[rkey] end
end

os.execute("mkdir -p " .. sh(args.out:match("^(.*)/[^/]*$") or "."))
local f = assert(io.open(args.out, "wb")); f:write(table.concat(out, "\n"), "\n"); f:close()
local function dump(v, ind)
  ind = ind or ""
  if type(v) == "table" then
    local o = { "{\n" }
    for k, x in pairs(v) do
      o[#o + 1] = ind .. "  [" .. (type(k) == "number" and k or string.format("%q", k)) .. "] = " .. dump(x, ind .. "  ") .. ",\n"
    end
    o[#o + 1] = ind .. "}"
    return table.concat(o)
  elseif type(v) == "string" then return string.format("%q", v)
  else return tostring(v) end
end
local lua_path = args.out:gsub("%.md$", "") .. ".lua"
f = assert(io.open(lua_path, "wb")); f:write("return ", dump(table_out), "\n"); f:close()
os.execute("rm -rf " .. sh(scratch))
io.write(table.concat(out, "\n"), "\n")
io.write("written to " .. args.out .. " and " .. lua_path .. "\n")
