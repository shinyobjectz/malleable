-- property -- a scenario that holds for every world, not just the one it wrote down.
--
-- A scenario tagged @property may state part of its world with `any`. Each `any` line is
-- expanded into ordinary Given lines in the vocabulary `behaviour` already reads, and every
-- generated world runs through the unchanged `behaviour.run`. A world that breaks the
-- scenario is shrunk to the smallest one that still breaks it, and printed as a scenario a
-- person can paste into a feature. spec/property.md is the contract.
--
-- Expansion, not a new runner: nothing about a run, a trace or a Then line differs between
-- a property and a scenario. It names no console and no host, and uses no clock and no
-- `math.random`, so one seed generates the same worlds under `lua` and `luajit`.

local gherkin   = require "gherkin"
local behaviour = require "behaviour"

local property = {}

local MAX_CALLS = 16
local SHRINK_LIMIT = 2000

-- the generator

-- The minimal standard generator. Its products stay under 2^53, so a double and a 64-bit
-- integer compute the same sequence, and `%` on two non-negative integers agrees in both.
local MOD = 2147483647

local function generator(seed, multiplier)
  local a = multiplier or 16807
  local s = math.floor(tonumber(seed) or 1) % MOD
  if s <= 0 then s = s + MOD - 1 end
  local g = {}
  function g.next()
    s = (a * s) % MOD
    return s
  end
  function g.int(lo, hi)
    if hi <= lo then return lo end
    return lo + g.next() % (hi - lo + 1)
  end
  function g.chance(n, d) return g.int(1, d) <= n end
  function g.pick(list) return list[g.int(1, #list)] end
  return g
end
property.generator = generator

-- the `any` lines

local ANY = {
  { expr = "the model says anything its tools allow", kind = "model",
    about = "calls the declared tools, with arguments of the declared types, then answers" },
  { expr = "the clock reads any date", kind = "clock",
    about = "a date between 2000-01-01 and 2099-12-28, at a whole minute" },
  { expr = "the file {string} holds anything", kind = "file",
    about = "text of any length, including none" },
  { expr = "the person presses any keys", kind = "keys",
    about = "the six buttons, by name, in a sequence of any length up to a bound" },
  { expr = "any rows in the store {word}", kind = "store",
    about = "reserved for the store" },
}
for i = 1, #ANY do ANY[i].compiled = assert(gherkin.expr(ANY[i].expr)) end

local FILE_LINE = assert(gherkin.expr("the file {string} contains:"))
local PRESSES = "the person presses {string}"

--- The `any` lines, as { expr, about }.
function property.expressions()
  local out = {}
  for i = 1, #ANY do out[i] = { expr = ANY[i].expr, about = ANY[i].about } end
  return out
end

local function any_of(text)
  for i = 1, #ANY do
    local args = ANY[i].compiled.match(text)
    if args then return ANY[i], args end
  end
  return nil
end

--- True when the pickle is tagged @property.
function property.is(pickle)
  for i = 1, #(pickle.tags or {}) do
    if pickle.tags[i] == "@property" then return true end
  end
  return false
end

--- The pickles split into the plain ones and the properties, each in its original order.
function property.split(pickles)
  local plain, props = {}, {}
  for i = 1, #pickles do
    if property.is(pickles[i]) then props[#props + 1] = pickles[i]
    else plain[#plain + 1] = pickles[i] end
  end
  return plain, props
end

--- The declaration's tools, as the generator reads them: in declaration order, and each
--- tool's parameters sorted by name so every VM walks them the same way.
function property.tools_of(declaration)
  local out = {}
  if type(declaration) ~= "table" then return out end
  for i = 1, #(declaration.order or {}) do
    local name = declaration.order[i]
    local tool = declaration.tools and declaration.tools[name]
    local args = {}
    for arg, p in pairs(type(tool) == "table" and tool.args or {}) do
      if type(p) == "table" then
        args[#args + 1] = { name = arg, kind = p.kind or "string", required = p.required ~= false,
                            choices = p.choices }
      end
    end
    table.sort(args, function (a, b) return a.name < b.name end)
    out[#out + 1] = { name = name, args = args }
  end
  return out
end

-- values

-- A generated value keeps its type, so it renders to JSON exactly and shrinks by type.
--   { k = "string", v }  { k = "number", v }  { k = "boolean", v }
--   { k = "array", items = { value } }  { k = "object", fields = { { name, value } } }

local LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,-_/:"

local function random_text(g, max)
  local n = g.int(0, max)
  local out = {}
  for i = 1, n do
    local at = g.int(1, #LETTERS)
    out[i] = LETTERS:sub(at, at)
  end
  return table.concat(out)
end

-- The cells of a row of text: what a grid, a board or a room is written in.
local CELLS = "#.  MLab"

local function gen_value(g, kind, paths, choices)
  -- One of a closed list: mostly a value from it, and sometimes one that is not, because a
  -- model can send anything and the declaration is what refuses it.
  if choices then
    if g.chance(1, 5) then return { k = "string", v = random_text(g, 6) } end
    return { k = "string", v = g.pick(choices) }
  end
  if kind == "number" or kind == "integer" then
    local pool = { 0, 1, -1, 1000000, -1000 }
    if g.chance(1, 2) then return { k = "number", v = g.pick(pool) } end
    return { k = "number", v = g.int(0, 2000) - 1000 }
  elseif kind == "boolean" then
    return { k = "boolean", v = g.chance(1, 2) }
  elseif kind == "object" then
    if g.chance(1, 2) then return { k = "object", fields = {} } end
    return { k = "object", fields = { { name = "k", value = { k = "string", v = "v" } } } }
  elseif kind == "array" then
    if g.chance(1, 2) then return { k = "array", items = {} } end
    if g.chance(1, 2) then return { k = "array", items = { { k = "string", v = "a" }, { k = "number", v = 1 } } } end
    -- Rows of text, all one width or not.
    local items, width = {}, g.int(0, 8)
    for i = 1, g.int(1, 6) do
      local row = {}
      for j = 1, (g.chance(1, 4) and g.int(0, 8) or width) do
        local at = g.int(1, #CELLS)
        row[j] = CELLS:sub(at, at)
      end
      items[i] = { k = "string", v = table.concat(row) }
    end
    return { k = "array", items = items }
  end
  -- A string: the empty one, a path the world has, one that leaves the workspace, one
  -- that is absolute, or letters.
  local roll = g.int(1, 8)
  if roll == 1 then return { k = "string", v = "" } end
  if roll == 2 and #paths > 0 then return { k = "string", v = g.pick(paths) } end
  if roll == 3 then return { k = "string", v = "../outside" } end
  if roll == 4 then return { k = "string", v = "/etc/passwd" } end
  return { k = "string", v = random_text(g, 12) }
end

local function json_string(s)
  return '"' .. s:gsub('[%c"\\]', function (c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    if c == "\n" then return "\\n" end
    if c == "\t" then return "\\t" end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function json(v)
  if v.k == "string" then return json_string(v.v) end
  if v.k == "number" then return tostring(v.v) end
  if v.k == "boolean" then return v.v and "true" or "false" end
  if v.k == "array" then
    local out = {}
    for i = 1, #v.items do out[i] = json(v.items[i]) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local out = {}
  for i = 1, #v.fields do
    out[i] = json_string(v.fields[i].name) .. ":" .. json(v.fields[i].value)
  end
  return "{" .. table.concat(out, ",") .. "}"
end

-- A call's arguments as one JSON object, keys in sorted order.
local function args_json(args)
  local out = {}
  for i = 1, #args do out[i] = json_string(args[i].name) .. ":" .. json(args[i].value) end
  return "{" .. table.concat(out, ",") .. "}"
end

-- one generated slot

-- Dates are days after 2000-01-01, rendered with Howard Hinnant's civil_from_days, which
-- has no table in it and is exact in both dialects.
local EPOCH_DAYS = 10957          -- 1970-01-01 to 2000-01-01
local LAST_DAY = 36521            -- 2099-12-28

local function date_of(days, minute)
  local z = days + EPOCH_DAYS + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
    - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  if m <= 2 then y = y + 1 end
  return string.format("%04d-%02d-%02dT%02d:%02d:00Z", y, m, d,
    math.floor(minute / 60), minute % 60)
end
property.date_of = date_of

local KEYS = { "left", "right", "up", "down", "A", "B" }
local MAX_KEYS = 40

local function gen_slot(g, any, args, ctx)
  if any.kind == "model" then
    local calls = {}
    local n = g.int(0, g.int(0, ctx.max_calls))
    if #ctx.tools > 0 then
      for c = 1, n do
        local tool = g.pick(ctx.tools)
        local got = {}
        for a = 1, #tool.args do
          local p = tool.args[a]
          if p.required or g.chance(1, 2) then
            got[#got + 1] = { name = p.name, required = p.required,
                              value = gen_value(g, p.kind, ctx.paths, p.choices) }
          end
        end
        calls[c] = { tool = tool.name, args = got }
      end
    end
    local answer = nil
    if g.chance(7, 8) then answer = random_text(g, 40) end
    return { kind = "model", calls = calls, answer = answer }
  elseif any.kind == "clock" then
    return { kind = "clock", days = g.int(0, LAST_DAY), minute = g.int(0, 1439) }
  elseif any.kind == "file" then
    return { kind = "file", path = args[1], text = random_text(g, 80) }
  elseif any.kind == "keys" then
    local keys = {}
    for i = 1, g.int(0, MAX_KEYS) do keys[i] = g.pick(KEYS) end
    return { kind = "keys", keys = keys }
  end
  return { kind = any.kind }
end

-- The lines a slot says. The first keeps the keyword the `any` line was written with.
local function render_slot(slot, step)
  local lines = {}
  local function add(text, doc)
    lines[#lines + 1] = { keyword = #lines == 0 and step.keyword or "And", text = text,
                          line = step.line, doc = doc, generated = true }
  end
  if slot.kind == "model" then
    for i = 1, #slot.calls do
      add("the model calls " .. slot.calls[i].tool .. " with " .. args_json(slot.calls[i].args))
    end
    if slot.answer then add("the model answers " .. json_string(slot.answer)) end
  elseif slot.kind == "clock" then
    add("the clock reads " .. json_string(date_of(slot.days, slot.minute)))
  elseif slot.kind == "file" then
    add("the file " .. json_string(slot.path) .. " contains:", slot.text)
  elseif slot.kind == "keys" then
    add("the person presses " .. json_string(table.concat(slot.keys, " ")))
  end
  return lines
end

local function render(pickle, world)
  local steps, generated, at = {}, 0, 0
  for i = 1, #pickle.steps do
    local s = pickle.steps[i]
    if any_of(s.text) then
      at = at + 1
      local lines = render_slot(world[at], s)
      for k = 1, #lines do steps[#steps + 1] = lines[k] end
      generated = generated + #lines
    else
      steps[#steps + 1] = { keyword = s.keyword, text = s.text, line = s.line,
                            doc = s.doc, rows = s.rows }
    end
  end
  return { name = pickle.name, line = pickle.line, tags = pickle.tags, steps = steps },
         generated
end

-- shrinking

local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

local function half_int(v)
  if v > 0 then return math.floor(v / 2) end
  return -math.floor(-v / 2)
end

local function text_moves(s)
  local out = {}
  if s ~= "" then
    out[#out + 1] = ""
    local half = s:sub(1, math.floor(#s / 2))
    if half ~= "" then out[#out + 1] = half end
  end
  return out
end

-- Every value one move smaller than `v`.
local function value_moves(v)
  local out = {}
  if v.k == "string" then
    local t = text_moves(v.v)
    for i = 1, #t do out[#out + 1] = { k = "string", v = t[i] } end
  elseif v.k == "number" then
    if v.v ~= 0 then
      out[#out + 1] = { k = "number", v = 0 }
      local h = half_int(v.v)
      if h ~= 0 then out[#out + 1] = { k = "number", v = h } end
    end
  elseif v.k == "boolean" then
    if v.v then out[#out + 1] = { k = "boolean", v = false } end
  elseif v.k == "array" then
    for i = 1, #v.items do
      local c = copy(v); table.remove(c.items, i); out[#out + 1] = c
    end
    for i = 1, #v.items do
      local inner = value_moves(v.items[i])
      for m = 1, #inner do local c = copy(v); c.items[i] = inner[m]; out[#out + 1] = c end
    end
  elseif v.k == "object" then
    for i = 1, #v.fields do
      local c = copy(v); table.remove(c.fields, i); out[#out + 1] = c
    end
    for i = 1, #v.fields do
      local inner = value_moves(v.fields[i].value)
      for m = 1, #inner do local c = copy(v); c.fields[i].value = inner[m]; out[#out + 1] = c end
    end
  end
  return out
end

-- Every world one move smaller, in the order spec/property.md gives.
local function candidates(world)
  local out = {}
  local function with(i, change)
    local w = copy(world)
    change(w[i])
    out[#out + 1] = w
  end
  -- 1. whole lines: a call, the answer, a key
  for i = 1, #world do
    local s = world[i]
    if s.kind == "model" then
      for c = 1, #s.calls do with(i, function (x) table.remove(x.calls, c) end) end
      if s.answer then with(i, function (x) x.answer = nil end) end
    elseif s.kind == "keys" then
      for k = 1, #s.keys do with(i, function (x) table.remove(x.keys, k) end) end
    end
  end
  -- 2. optional arguments
  for i = 1, #world do
    local s = world[i]
    if s.kind == "model" then
      for c = 1, #s.calls do
        for a = 1, #s.calls[c].args do
          if not s.calls[c].args[a].required then
            with(i, function (x) table.remove(x.calls[c].args, a) end)
          end
        end
      end
    end
  end
  -- 3. argument values
  for i = 1, #world do
    local s = world[i]
    if s.kind == "model" then
      for c = 1, #s.calls do
        for a = 1, #s.calls[c].args do
          local moves = value_moves(s.calls[c].args[a].value)
          for m = 1, #moves do
            with(i, function (x) x.calls[c].args[a].value = moves[m] end)
          end
        end
      end
    end
  end
  -- 4. text: the answer, a file
  for i = 1, #world do
    local s = world[i]
    if s.kind == "model" and s.answer then
      local t = text_moves(s.answer)
      for m = 1, #t do with(i, function (x) x.answer = t[m] end) end
    elseif s.kind == "file" then
      local t = text_moves(s.text)
      for m = 1, #t do with(i, function (x) x.text = t[m] end) end
    end
  end
  -- 5. dates, toward 2000-01-01 at midnight
  for i = 1, #world do
    local s = world[i]
    if s.kind == "clock" then
      if s.days ~= 0 then
        with(i, function (x) x.days = 0 end)
        if half_int(s.days) ~= 0 then with(i, function (x) x.days = half_int(s.days) end) end
      end
      if s.minute ~= 0 then with(i, function (x) x.minute = 0 end) end
    end
  end
  return out
end

-- running

local function has_step(drivers, expr)
  local built = behaviour.steps()
  for i = 1, #built do if built[i].expr == expr then return true end end
  for i = 1, #((drivers and drivers.steps) or {}) do
    local s = drivers.steps[i]
    if type(s) == "table" and s.expr == expr then return true end
  end
  return false
end

-- The first step that did not hold, as { line, text, outcome, why }.
local function first_bad(scenario)
  for i = 1, #(scenario.steps or {}) do
    local s = scenario.steps[i]
    if s.outcome == "failed" or s.outcome == "broken" or s.outcome == "undefined" then
      return s
    end
  end
  return nil
end

-- Paths the scenario's own world has, read through the expression, so a generated string
-- names a file that is there as often as one that is not.
local function paths_of(pickle)
  local out, seen = {}, {}
  for i = 1, #pickle.steps do
    local got = FILE_LINE.match(pickle.steps[i].text)
    if got and type(got[1]) == "string" and not seen[got[1]] then
      seen[got[1]] = true
      out[#out + 1] = got[1]
    end
  end
  return out
end

local function one(pickle, drivers, on_run)
  local report = behaviour.run({ pickle }, drivers, {})
  local s = report.scenarios[1]
  if on_run then on_run(s, pickle) end
  return s
end

-- A scenario's steps as the text of a scenario, the failing line marked.
local function scenario_text(pickle, scenario, title)
  local out = { "Scenario: " .. title }
  local bad = first_bad(scenario)
  for i = 1, #pickle.steps do
    local s = pickle.steps[i]
    out[#out + 1] = "  " .. s.keyword .. " " .. s.text
    if s.doc then
      out[#out + 1] = '    """'
      for line in (s.doc .. "\n"):gmatch("(.-)\n") do out[#out + 1] = "    " .. line end
      out[#out + 1] = '    """'
    end
    local said = scenario.steps and scenario.steps[i]
    if bad and said == bad then
      out[#out + 1] = "    # did not hold: " .. tostring(bad.why or bad.outcome)
    end
  end
  return table.concat(out, "\n")
end

local function run_property(pickle, drivers, opts)
  local entry = { name = pickle.name, line = pickle.line, runs = 0, passed = 0 }
  local slots, store = {}, false
  for i = 1, #pickle.steps do
    local any, args = any_of(pickle.steps[i].text)
    if any then
      slots[#slots + 1] = { any = any, args = args }
      if any.kind == "store" then store = true end
      if any.kind == "keys" and not has_step(drivers, PRESSES) then
        entry.outcome = "skipped"
        entry.why = "\"the person presses any keys\" needs the step \"" .. PRESSES
          .. "\", and nothing running this property declares it"
        return entry
      end
    end
  end
  if store then
    entry.outcome = "broken"
    entry.why = "\"any rows in the store\" is reserved for the store, which does not exist yet"
    return entry
  end

  local ctx = { tools = opts.tools, max_calls = opts.max_calls, paths = paths_of(pickle) }
  local runs = #slots == 0 and 1 or (opts.runs or 100)
  entry.planned = runs
  -- The other multiplier: seeded from the runs' own generator, run r + 1 would be run r
  -- shifted by one draw.
  local master = generator(opts.seed or 1, 48271)

  for r = 1, runs do
    local run_seed = master.next()
    local g = generator(run_seed)
    local world = {}
    for i = 1, #slots do world[i] = gen_slot(g, slots[i].any, slots[i].args, ctx) end
    local concrete, generated = render(pickle, world)
    local s = one(concrete, drivers, opts.on_run)
    entry.runs = r
    if s.outcome == "passed" then
      entry.passed = entry.passed + 1
    elseif s.outcome == "undefined" then
      entry.outcome = "broken"
      local bad = first_bad(s)
      entry.why = "a line matches no step: " .. tostring(bad and bad.text)
      return entry
    else
      -- Shrink: keep the first smaller world that fails on the same line, and start over.
      local bad = first_bad(s)
      local want_line, want_outcome = bad and bad.line, s.outcome
      local best, best_pickle, best_s, best_generated = world, concrete, s, generated
      local attempts, limit = 0, opts.shrink_limit or SHRINK_LIMIT
      local improved = true
      while improved and attempts < limit do
        improved = false
        local list = candidates(best)
        for c = 1, #list do
          attempts = attempts + 1
          local p, n = render(pickle, list[c])
          local got = one(p, drivers, nil)
          local gb = first_bad(got)
          if got.outcome == want_outcome and gb and gb.line == want_line
            and gb.text == (bad and bad.text) then
            best, best_pickle, best_s, best_generated = list[c], p, got, n
            improved = true
            break
          end
          if attempts >= limit then break end
        end
      end
      entry.outcome = "failed"
      entry.seed = opts.seed or 1
      entry.run = r
      entry.run_seed = run_seed
      entry.generated = best_generated
      entry.shrunk_from = generated
      entry.attempts = attempts
      entry.stopped_at_limit = attempts >= limit
      local why = first_bad(best_s)
      entry.why = why and why.why or "it did not hold"
      entry.counterexample = scenario_text(best_pickle, best_s,
        "counterexample to " .. json_string(pickle.name))
      return entry
    end
  end
  entry.outcome = "passed"
  return entry
end

--- Runs every @property pickle among `pickles`; the others are left to `behaviour.run`.
function property.run(pickles, drivers, opts)
  opts = opts or {}
  if type(pickles) ~= "table" then
    error("property.run: pickles are a list, and arrived as " .. type(pickles), 2)
  end
  local o = {}
  for k, v in pairs(opts) do o[k] = v end
  o.tools = o.tools or property.tools_of(o.declaration)
  local cap = MAX_CALLS
  if type(o.declaration) == "table" and type(o.declaration.budget) == "number" then
    cap = math.min(cap, o.declaration.budget)
  end
  o.max_calls = math.min(o.max_calls or cap, MAX_CALLS)

  local report = { ok = true, properties = {} }
  for i = 1, #pickles do
    if property.is(pickles[i]) then
      local e = run_property(pickles[i], drivers, o)
      report.properties[#report.properties + 1] = e
      if e.outcome == "failed" or e.outcome == "broken" then report.ok = false end
    end
  end
  return report
end

--- The report, as a person reads it.
function property.text(report)
  local out = {}
  for i = 1, #report.properties do
    local e = report.properties[i]
    if e.outcome == "passed" then
      out[#out + 1] = string.format("passed    %s   %d of %d", e.name, e.passed, e.runs)
    elseif e.outcome == "failed" then
      out[#out + 1] = string.format("failed    %s   run %d of %d", e.name, e.run, e.planned)
      out[#out + 1] = ""
      for line in (e.counterexample .. "\n"):gmatch("(.-)\n") do out[#out + 1] = "  " .. line end
      out[#out + 1] = ""
      out[#out + 1] = string.format(
        "  seed %s, run %d (run seed %d), shrunk from %d generated line%s to %d in %d attempt%s%s",
        tostring(e.seed), e.run, e.run_seed, e.shrunk_from, e.shrunk_from == 1 and "" or "s",
        e.generated, e.attempts, e.attempts == 1 and "" or "s",
        e.stopped_at_limit and " (stopped at the limit)" or "")
    else
      out[#out + 1] = string.format("%-9s %s   %s", e.outcome, e.name, tostring(e.why))
    end
  end
  return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

return property
