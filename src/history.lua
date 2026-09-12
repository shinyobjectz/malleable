-- history -- every run, kept as a story and its evidence, under an id that says where and
-- when it happened, and as a hypervector of its circumstances (docs/spec/history.md).
--
--     local id = history.claim(p.history, p.history.where(), p.clock.now(), "notebook", "job")
--     local tapped, log = history.tap(port)          -- the run goes through `tapped`
--     ...
--     history.keep(p.history, { id = id, cause = "job", decl = decl, prompt = prompt,
--                               result = result, log = log, started = t0, ended = t1 })
--
--     local h = history.open(p.history)
--     history.find(h, { git_branch = "main", wrote = "notes/todo.md" })
--     history.recall(h, id)                          -- the story
--     history.evidence(h, id, "diff", "notes/todo.md")
--
-- Pure: every file goes through the history port, the clock through its caller. Nothing
-- here reads a model's words to decide where an entry goes or how it is found.

local hdc      = require "hdc"
local observe  = require "observe"
local gherkin  = require "gherkin"
local json     = require("provider").json

local history = {}

history.LINES, history.BYTES = 20, 2000      -- a file text past either is kept apart
history.CUT = 6000                           -- what a reading tool answers at most
history.CAUSES = { cli = true, talk = true, job = true, beat = true, edit = true, run = true }

-- ------------------------------------------------------------------ the id

--- The civil date and time of `epoch` seconds, `offset` seconds from UTC.
function history.civil(epoch, offset)
  local t = math.floor((epoch or 0) + (offset or 0))
  local days = math.floor(t / 86400)
  local secs = t - days * 86400
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  local y = yoe + era * 400 + (m <= 2 and 1 or 0)
  return { year = y, month = m, day = d, hour = math.floor(secs / 3600),
           min = math.floor(secs % 3600 / 60), sec = secs % 60, days = days }
end

local function day_of(c) return string.format("%04d-%02d-%02d", c.year, c.month, c.day) end

-- A part of an id: letters, digits, dot, dash and underscore; anything else is a dash.
local function part(s)
  s = tostring(s or ""):gsub("[^%w%._~%-]", "-")
  return s ~= "" and s or "-"
end

--- The id a run would have, before any `-2`: worktree@git_branch/day/time-agent-cause.
function history.id(where, at, agent, cause)
  where = where or {}
  local place = part(where.worktree or "workspace")
  if type(where.git_branch) == "string" and where.git_branch ~= "" then
    place = place .. "@" .. part((where.git_branch:gsub("/", "~")))
  end
  local c = history.civil(at, where.offset)
  return string.format("%s/%s/%02d-%02d-%02d-%s-%s", place, day_of(c), c.hour, c.min, c.sec,
    part(agent), part(cause))
end

--- Claims an id for a run starting now. Answers the id, or nil and why.
function history.claim(hp, where, at, agent, cause)
  local base = history.id(where, at, agent, cause)
  for n = 1, 1000 do
    local id = n == 1 and base or (base .. "-" .. n)
    if hp.claim(id) then return id end
  end
  return nil, "a thousand runs already claimed " .. base
end

-- ------------------------------------------------------------------ the tap

local function copy(v, seen)
  if type(v) ~= "table" then
    if type(v) == "function" or type(v) == "userdata" or type(v) == "thread" then return nil end
    return v
  end
  seen = seen or {}
  if seen[v] then return nil end
  seen[v] = true
  local out = {}
  for k, x in pairs(v) do
    if type(k) == "string" or type(k) == "number" then out[k] = copy(x, seen) end
  end
  seen[v] = nil
  return out
end

--- A port that remembers what passes through it, and what it remembered. Everything goes
--- through unchanged: answers, errors and yields.
function history.tap(port, now)
  local log = { files = {}, order = {}, commands = {}, model = {}, asks = {} }
  local mono = now or (port.clock and (port.clock.mono or port.clock.now)) or function () return 0 end
  local function file(path)
    local f = log.files[path]
    if not f then
      f = { path = path, reads = 0 }
      log.files[path] = f
      log.order[#log.order + 1] = path
    end
    return f
  end
  local t = {}
  for k, v in pairs(port) do t[k] = v end

  if type(port.fs) == "table" then
    local fs, w = port.fs, {}
    for k, v in pairs(fs) do w[k] = v end
    w.read = function (path)
      local text, err = fs.read(path)
      if type(path) == "string" then
        local f = file(path)
        f.reads = f.reads + 1
        if f.first == nil and not f.wrote and type(text) == "string" then f.first = text end
      end
      return text, err
    end
    local function before(f, path)
      if f.wrote then return end
      f.wrote = true
      if f.first ~= nil then f.before = f.first
      elseif fs.exists and fs.exists(path) then
        local text = fs.read(path)
        if type(text) == "string" then f.before = text end
      end
    end
    w.write = function (path, text)
      local f = type(path) == "string" and file(path) or nil
      if f then before(f, path) end
      local ok, err = fs.write(path, text)
      if f and ok then f.after, f.removed = text, nil end
      return ok, err
    end
    if fs.remove then
      w.remove = function (path)
        local f = type(path) == "string" and file(path) or nil
        if f then before(f, path) end
        local ok, err = fs.remove(path)
        if f and ok then f.after, f.removed = nil, true end
        return ok, err
      end
    end
    t.fs = w
  end

  if type(port.sh) == "table" and port.sh.run then
    local sh, w = port.sh, {}
    for k, v in pairs(port.sh) do w[k] = v end
    w.run = function (argv, opts)
      local t0 = mono()
      local r, err = sh.run(argv, opts)
      log.commands[#log.commands + 1] = {
        argv = copy(argv), cwd = type(opts) == "table" and opts.cwd or nil,
        code = type(r) == "table" and r.code or nil, out = type(r) == "table" and r.out or nil,
        err = type(r) == "table" and r.err or (err and (type(err) == "table" and err.message or tostring(err))) or nil,
        timed_out = type(r) == "table" and r.timed_out or nil, ms = math.floor((mono() - t0) * 1000 + 0.5),
      }
      return r, err
    end
    t.sh = w
  end

  -- A model and a gate come as a table with a call (the ports) or as a function (a port
  -- cli.bind has wrapped); each is remembered the same way.
  local function model_call(call)
    return function (request)
      local t0 = mono()
      local reply, err = call(request)
      log.model[#log.model + 1] = {
        ms = math.floor((mono() - t0) * 1000 + 0.5),
        stop = type(reply) == "table" and reply.stop or nil,
        usage = type(reply) == "table" and copy(reply.usage) or nil,
        text = type(reply) == "table" and reply.text or nil,
        calls = type(reply) == "table" and copy(reply.calls) or nil,
        err = err ~= nil and copy(type(err) == "table" and err or { message = tostring(err) }) or nil,
      }
      return reply, err
    end
  end
  if type(port.model) == "table" and port.model.call then
    local w = {}
    for k, v in pairs(port.model) do w[k] = v end
    w.call = model_call(port.model.call)
    t.model = w
  elseif type(port.model) == "function" then
    t.model = model_call(port.model)
  end

  local function ask_request(request)
    return function (q)
      local d = request(q)
      log.asks[#log.asks + 1] = {
        tool = type(q) == "table" and q.tool or nil, args = type(q) == "table" and copy(q.args) or nil,
        allow = type(d) == "table" and d.allow or false, why = type(d) == "table" and d.why or nil,
        edited = type(d) == "table" and copy(d.args) or nil,
      }
      return d
    end
  end
  if type(port.ask) == "table" and port.ask.request then
    local w = {}
    for k, v in pairs(port.ask) do w[k] = v end
    w.request = ask_request(port.ask.request)
    t.ask = w
  elseif type(port.ask) == "function" then
    t.ask = ask_request(port.ask)
  end
  return t, log
end

-- ------------------------------------------------------------------ moments

-- What a call's declared effect is, as a moment's code (spec/home.md).
history.EFFECT_CODES = { reads = "r", writes = "w", recalls = "h", runs = "x", starts = "s" }
local FROM_CODES = { person = "P", talker = "T", jobs = "J", clock = "C" }
local END_CODES = { answered = "A", budget = "B", refused = "R" }

-- Who asked, from what the entry says, or else from its cause.
local function asked_code(e)
  if FROM_CODES[e.from] then return FROM_CODES[e.from] end
  if e.cause == "job" then return "T" elseif e.cause == "beat" then return "C" end
  return "P"
end

-- The moments of an entry-shaped table. `live` leaves out the end, and a call still
-- waiting at the gate is `q`.
local function moments_of(e, live)
  local out = {}
  local function add(code, m)
    m = m or {}
    m.code = code
    out[#out + 1] = m
  end
  add(asked_code(e), { what = "asked" })
  for i, c in ipairs(e.calls or {}) do
    local tool = tostring(c.tool)
    if c.pending then
      add("q", { what = "waiting", call = i, tool = tool })
    elseif c.refused then
      add("n", { what = "refused", call = i, tool = tool, asked = c.asked or nil })
    else
      if c.asked then add("y", { what = "allowed", call = i, tool = tool }) end
      if c.ok == false then add("f", { what = "failed", call = i, tool = tool })
      else add(history.EFFECT_CODES[c.effect] or "c", { what = "call", call = i, tool = tool, effect = c.effect }) end
    end
  end
  for _, f in ipairs(e.files or {}) do
    if f.wrote then add("F", { what = "changed", path = f.path, removed = f.removed or nil }) end
  end
  for _, x in ipairs(e.errors or {}) do
    if x.model_call then add("E", { what = "model failed", model_call = x.model_call }) end
  end
  if not live then add(END_CODES[e.stop] or "X", { what = "ended", stop = e.stop }) end
  local codes = {}
  for i, m in ipairs(out) do codes[i] = m.code end
  return out, table.concat(codes)
end

--- A kept entry's moments, in order (spec/home.md): what it was asked and by whom, each
--- call as its declared effect, the gate's answers, the files it changed, the model's
--- errors and how it ended. Answers the list and its codes as one string.
function history.moments(e)
  return moments_of(e or {}, false)
end

--- The moments of a run still going, from its tap's log: the same codes, with a call the
--- gate has not yet answered as `q`. `decl` says which tools ask and what each does.
function history.live(log, decl, prompt, from, cause)
  log = log or {}
  local tools = decl and decl.tools or {}
  local answers = {}
  for _, a in ipairs(log.asks or {}) do
    if a.tool then
      answers[a.tool] = answers[a.tool] or {}
      table.insert(answers[a.tool], a)
    end
  end
  local e = { prompt = prompt, from = from, cause = cause, calls = {}, files = {} }
  local replies = log.model or {}
  for r, m in ipairs(replies) do
    for _, call in ipairs(type(m.calls) == "table" and m.calls or {}) do
      local t = tools[call.tool]
      local rec = { tool = call.tool, effect = t and t.effect }
      if t and t.ask then
        local a = answers[call.tool] and table.remove(answers[call.tool], 1)
        if a then rec.asked, rec.refused = true, not a.allow
        elseif r == #replies then rec.pending = true end
      end
      e.calls[#e.calls + 1] = rec
    end
  end
  for _, path in ipairs(log.order or {}) do
    local f = log.files[path]
    if f and f.wrote then e.files[#e.files + 1] = { path = path, wrote = true, removed = f.removed } end
  end
  return moments_of(e, true)
end

-- ------------------------------------------------------------------ keeping

local function lines_in(s) local n = 1; for _ in s:gmatch("\n") do n = n + 1 end; return n end

local function long(s)
  return type(s) == "string" and (#s > history.BYTES or lines_in(s) > history.LINES)
end

local function plain(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

local function first_line(s)
  s = tostring(s or ""):match("^%s*([^\n]*)") or ""
  if #s > 120 then s = s:sub(1, 117) .. "..." end
  return s
end

local function join(list) return table.concat(list, ",") end

-- The Then lines of a story, for the hypervector.
local function then_lines(story)
  local out, in_then = {}, false
  for line in story:gmatch("[^\n]+") do
    local kw, rest = line:match("^%s*(%a+) (.*)$")
    if kw == "Then" then in_then = true end
    if kw == "Given" or kw == "When" then in_then = false end
    if in_then and rest and (kw == "Then" or kw == "And" or kw == "But") then out[#out + 1] = rest end
  end
  return out
end

-- The pairs an entry's hypervector bundles, from its index row.
local function pairs_of(row)
  local p = {}
  local function add(role, value)
    if value ~= nil and value ~= "" then p[#p + 1] = hdc.bind(hdc.atom("role:" .. role), hdc.atom(role .. ":" .. value)) end
  end
  add("worktree", row.worktree); add("git_branch", row.git_branch); add("agent", row.agent)
  add("cause", row.cause); add("stop", row.stop); add("parent", row.parent); add("day", row.day)
  if row.days then p[#p + 1] = hdc.bind(hdc.atom "role:days", hdc.level("day", row.days, 64)) end
  if row.hour then p[#p + 1] = hdc.bind(hdc.atom "role:hour", hdc.level("hour", row.hour, 24)) end
  for _, v in ipairs(row.tools or {}) do add("tool", v) end
  for _, v in ipairs(row.read or {}) do add("read", v) end
  for _, v in ipairs(row.wrote or {}) do add("wrote", v) end
  for _, v in ipairs(row.asked or {}) do add("asked", v) end
  for _, v in ipairs(row.refused or {}) do add("refused", v) end
  for _, v in ipairs(row.errors or {}) do add("error", v) end
  for _, v in ipairs(row.then_ or {}) do add("then", v) end
  return p
end

--- An index row's hypervector.
function history.vector(row)
  local p = pairs_of(row)
  if #p == 0 then return hdc.atom "empty" end
  return hdc.bundle(p)
end

local INDEX_FIELDS = { "id", "started", "day", "hour", "days", "worktree", "git_branch", "agent",
                       "cause", "parent", "stop", "steps", "tools", "read", "wrote", "asked",
                       "refused", "errors", "prompt", "moments" }

local function index_line(row)
  local out = {}
  for i, k in ipairs(INDEX_FIELDS) do
    local v = row[k]
    if type(v) == "table" then v = join(v) end
    out[i] = tostring(v == nil and "" or v):gsub("[\t\n\r]", " ")
  end
  return table.concat(out, "\t")
end

local function split(s, sep)
  local out, at = {}, 1
  while true do
    local j = s:find(sep, at, true)
    if not j then out[#out + 1] = s:sub(at); break end
    out[#out + 1] = s:sub(at, j - 1)
    at = j + 1
  end
  return out
end

local LISTS = { tools = true, read = true, wrote = true, asked = true, refused = true, errors = true }
local NUMBERS = { started = true, hour = true, days = true, steps = true }

local function read_index_line(line)
  local cells, row = split(line, "\t"), {}
  for i, k in ipairs(INDEX_FIELDS) do
    local v = cells[i] or ""
    if LISTS[k] then row[k] = v == "" and {} or split(v, ",")
    elseif NUMBERS[k] then row[k] = tonumber(v)
    else row[k] = v ~= "" and v or nil end
  end
  return row
end

local function sorted_set(list)
  local seen, out = {}, {}
  for _, v in ipairs(list) do if not seen[v] then seen[v] = true; out[#out + 1] = v end end
  table.sort(out)
  return out
end

--- Keeps one run. `o`: id, parent, cause, decl, declaration (text), prompt, result, log,
--- started, ended, secret (a text to keep out of every file). Answers the id, or nil and why.
function history.keep(hp, o)
  local result, log = o.result or {}, o.log or { files = {}, order = {}, commands = {}, model = {}, asks = {} }
  local where = o.where or (hp.where and hp.where()) or {}
  local id = o.id
  local kept, kept_by_text = {}, {}

  -- A long text is written apart, once per run, and named `<id>#<n>`.
  local function keep_text(text, what)
    if kept_by_text[text] then return kept_by_text[text] end
    kept[#kept + 1] = { text = text, what = what }
    local name = id .. "#" .. #kept
    kept_by_text[text] = name
    return name
  end
  local function held(text, what)
    if long(text) then return { kept = keep_text(text, what) } end
    return text
  end

  -- the story
  local cfg_fs, wrote, files, removed = {}, {}, {}, {}
  for _, path in ipairs(log.order) do
    local f = log.files[path]
    if f.first ~= nil and (not f.wrote or f.before == f.first) then cfg_fs[path] = f.first end
    if f.wrote then
      if f.removed then removed[#removed + 1] = path
      elseif f.after ~= nil then wrote[#wrote + 1] = { path = path, text = f.after }; files[path] = f.after end
    end
  end
  local asks = {}
  for _, a in ipairs(log.asks) do
    if a.tool then asks[a.tool] = { allow = a.allow, args = a.edited } end
  end
  local sh = {}
  for _, c in ipairs(log.commands) do
    if type(c.argv) == "table" and c.code then sh[table.concat(c.argv, " ")] = { code = c.code, out = c.out or "" } end
  end
  local record = {
    result = result, prompt = o.prompt,
    cfg = { fs = cfg_fs, ask = next(asks) and asks or nil, sh = next(sh) and sh or nil,
            budget = type(result.budget) == "number" and result.budget or nil },
    world = { fs = { files = files, wrote = wrote, removed = removed } },
  }
  local ok_story, story = pcall(observe.scenario, record, first_line(o.prompt), {
    keep = function (text) if long(text) then return keep_text(text, "a file's text") end end,
  })
  if not ok_story then story = "  Scenario: " .. first_line(o.prompt) .. "\n    # the run could not be told: " .. tostring(story) .. "\n" end
  local tags = { "@" .. id, "@" .. (o.cause or "run") }
  if o.parent then tags[#tags + 1] = "@from-" .. o.parent end
  story = "  " .. table.concat(tags, " ") .. "\n" .. story

  -- the evidence
  local calls, errors = {}, {}
  local declared = type(o.decl) == "table" and type(o.decl.tools) == "table" and o.decl.tools or {}
  for i, c in ipairs(result.calls or {}) do
    local rec = copy(c) or {}
    if type(rec.output) == "string" then rec.output = held(rec.output, "call " .. i .. "'s output") end
    local t = declared[c.tool]
    if t and t.effect then rec.effect = t.effect end
    calls[i] = rec
    if c.ok == false and not c.refused then errors[#errors + 1] = { call = i, tool = c.tool, output = rec.output } end
  end
  local model_calls = {}
  for i, m in ipairs(log.model) do
    model_calls[i] = copy(m)
    if m.err then errors[#errors + 1] = { model_call = i, err = copy(m.err) } end
  end
  if result.err then table.insert(errors, 1, { run = copy(result.err) }) end
  local file_list = {}
  for _, path in ipairs(log.order) do
    local f = log.files[path]
    file_list[#file_list + 1] = { path = path, reads = f.reads, wrote = f.wrote or nil, removed = f.removed or nil,
      first = f.first and held(f.first, path .. " as first read") or nil,
      before = f.before and held(f.before, path .. " before the run wrote it") or nil,
      after = f.after and held(f.after, path .. " after the run") or nil }
  end
  local commands = {}
  for i, c in ipairs(log.commands) do
    local rec = copy(c)
    if rec.out then rec.out = held(rec.out, "command " .. i .. "'s output") end
    commands[i] = rec
  end
  local decl = o.decl or {}
  local c = history.civil(o.started or 0, where.offset)
  local evidence = {
    id = id, parent = o.parent, cause = o.cause or "run", from = o.from, agent = decl.name,
    where = copy(where), started = o.started, ended = o.ended,
    prompt = o.prompt, stop = result.stop, reason = result.reason, steps = result.steps,
    budget = result.budget, answer = result.answer,
    calls = calls, transcript = copy(result.transcript) or {},
    model = { name = decl.model, reasoning = decl.reasoning, calls = model_calls },
    errors = errors, files = file_list, commands = commands, notes = copy(result.notes) or {},
    declaration = o.declaration and { text = held(o.declaration, "the declaration"), length = #o.declaration } or nil,
    spans = copy(result.spans), kept = {},
  }
  for i, k in ipairs(kept) do evidence.kept[i] = k.what end

  -- the index row and the hypervector
  local tools, read, written, asked, refused, errs = {}, {}, {}, {}, {}, {}
  for _, call in ipairs(result.calls or {}) do
    tools[#tools + 1] = tostring(call.tool)
    if call.asked then asked[#asked + 1] = tostring(call.tool) end
    if call.refused then refused[#refused + 1] = tostring(call.tool) end
  end
  for _, path in ipairs(log.order) do
    local f = log.files[path]
    if f.reads > 0 then read[#read + 1] = path end
    if f.wrote then written[#written + 1] = path end
  end
  for _, e in ipairs(errors) do
    errs[#errs + 1] = e.run and ("run:" .. tostring(e.run.where or "error")) or e.model_call and "model" or ("call:" .. tostring(e.tool))
  end
  local row = {
    id = id, started = math.floor(o.started or 0), day = day_of(c), hour = c.hour, days = c.days,
    worktree = where.worktree, git_branch = where.git_branch, agent = decl.name, cause = o.cause or "run",
    parent = o.parent, stop = result.stop, steps = result.steps, tools = sorted_set(tools),
    read = sorted_set(read), wrote = sorted_set(written), asked = sorted_set(asked),
    refused = sorted_set(refused), errors = sorted_set(errs), prompt = first_line(o.prompt),
  }
  row.moments = select(2, history.moments(evidence))
  row.then_ = then_lines(story)
  local vec = history.vector(row)

  -- write it: the evidence and its kept texts, the story, the index and the vector
  local body, why = json.encode(evidence)
  if not body then return nil, "the evidence could not be written as JSON: " .. tostring(type(why) == "table" and why.message or why) end
  local function scrub(s)
    if type(o.secret) == "string" and #o.secret >= 8 then return (s:gsub(plain(o.secret), "[key]")) end
    return s
  end
  local writes = { { "runs/" .. id .. "/entry.json", scrub(body) }, { "runs/" .. id .. "/story", scrub(story) } }
  for i, k in ipairs(kept) do writes[#writes + 1] = { "runs/" .. id .. "/" .. i, scrub(k.text) } end
  for _, w in ipairs(writes) do
    local ok, err = hp.write(w[1], w[2])
    if not ok then return nil, "could not write " .. w[1] .. ": " .. tostring(err) end
  end
  local day_path = "stories/" .. part(decl.name) .. "/" .. row.day .. ".feature"
  if not hp.read(day_path) then
    local ok, err = hp.write(day_path, "# Kept by the harness, not written by a person: every line is a thing that happened.\n"
      .. "Feature: " .. tostring(decl.name or "agent") .. ", " .. row.day .. "\n")
    if not ok then return nil, "could not start " .. day_path .. ": " .. tostring(err) end
  end
  local ok, err = hp.append(day_path, "\n" .. scrub(story))
  if not ok then return nil, "could not add to " .. day_path .. ": " .. tostring(err) end
  ok, err = hp.append("index", scrub(index_line(row)) .. "\n")
  if not ok then return nil, "could not add to the index: " .. tostring(err) end
  ok, err = hp.append("vectors", hdc.hex(vec) .. "\n")
  if not ok then return nil, "could not add to the vectors: " .. tostring(err) end
  return id
end

-- ------------------------------------------------------------------ reading

-- Every entry.json under runs/, as ids, by walking the folders.
local function walk_runs(hp)
  local ids = {}
  local function walk(dir, rel)
    local names = hp.list(dir) or {}
    for _, n in ipairs(names) do
      if n == "entry.json" then ids[#ids + 1] = rel
      elseif not n:match("^%d+$") and n ~= "story" then
        walk(dir .. "/" .. n, rel == "" and n or (rel .. "/" .. n))
      end
    end
  end
  walk("runs", "")
  table.sort(ids)
  return ids
end

local function row_from_evidence(e, story)
  local c = history.civil(e.started or 0, e.where and e.where.offset)
  local tools, asked, refused, read, wrote, errs = {}, {}, {}, {}, {}, {}
  for _, call in ipairs(e.calls or {}) do
    tools[#tools + 1] = tostring(call.tool)
    if call.asked then asked[#asked + 1] = tostring(call.tool) end
    if call.refused then refused[#refused + 1] = tostring(call.tool) end
  end
  for _, f in ipairs(e.files or {}) do
    if (f.reads or 0) > 0 then read[#read + 1] = f.path end
    if f.wrote then wrote[#wrote + 1] = f.path end
  end
  for _, x in ipairs(e.errors or {}) do
    errs[#errs + 1] = x.run and ("run:" .. tostring(x.run.where or "error")) or x.model_call and "model" or ("call:" .. tostring(x.tool))
  end
  local row = {
    id = e.id, started = math.floor(e.started or 0), day = day_of(c), hour = c.hour, days = c.days,
    worktree = e.where and e.where.worktree, git_branch = e.where and e.where.git_branch, agent = e.agent,
    cause = e.cause, parent = e.parent, stop = e.stop, steps = e.steps, tools = sorted_set(tools),
    read = sorted_set(read), wrote = sorted_set(wrote), asked = sorted_set(asked),
    refused = sorted_set(refused), errors = sorted_set(errs), prompt = first_line(e.prompt),
  }
  row.moments = select(2, history.moments(e))
  row.then_ = then_lines(story or "")
  return row
end

--- Rebuilds the index and the vectors from runs/. Answers the number of entries.
function history.rebuild(hp)
  local lines, vecs = {}, {}
  for _, id in ipairs(walk_runs(hp)) do
    local body = hp.read("runs/" .. id .. "/entry.json")
    local e = body and json.decode(body)
    if type(e) == "table" and e.id then
      local row = row_from_evidence(e, hp.read("runs/" .. id .. "/story"))
      lines[#lines + 1] = index_line(row)
      vecs[#vecs + 1] = hdc.hex(history.vector(row))
    end
  end
  hp.write("index", #lines > 0 and (table.concat(lines, "\n") .. "\n") or "")
  hp.write("vectors", #vecs > 0 and (table.concat(vecs, "\n") .. "\n") or "")
  return #lines
end

--- The history, read: its rows and their vectors. The index and the vectors are rebuilt
--- when they disagree in length.
function history.open(hp, opts)
  local function load()
    local rows, vecs = {}, {}
    for line in (hp.read("index") or ""):gmatch("[^\n]+") do rows[#rows + 1] = read_index_line(line) end
    for line in (hp.read("vectors") or ""):gmatch("[^\n]+") do vecs[#vecs + 1] = line end
    return rows, vecs
  end
  local rows, vecs = load()
  -- An index written before a field it now keeps (`moments`) is rebuilt like one that
  -- disagrees: both are derived from runs/.
  local stale = #rows > 0 and rows[#rows].moments == nil
  if #rows ~= #vecs or stale then history.rebuild(hp); rows, vecs = load() end
  local h = { hp = hp, rows = rows, vectors = {}, by_id = {} }
  local want = not (opts and opts.vectors == false)
  for i, r in ipairs(rows) do
    if want then h.vectors[i] = hdc.from_hex(vecs[i]) or history.vector(r) end
    h.by_id[r.id] = i
  end
  return h
end

--- The entry an id names: the whole id, a unique leading part of one, or else any part of
--- one that no other id holds (`12-21-29-notebook-job`). Answers the id, or nil and why.
function history.resolve(h, id)
  if type(id) ~= "string" or id == "" then return nil, "name an entry by its id" end
  if h.by_id[id] then return id end
  local function unique(holds, how)
    local found
    for _, r in ipairs(h.rows) do
      if holds(r.id) then
        if found then return nil, "more than one entry " .. how .. " " .. id .. ": " .. found .. " and " .. r.id end
        found = r.id
      end
    end
    return found
  end
  local lead, why = unique(function (x) return x:sub(1, #id) == id end, "begins")
  if lead or why then return lead, why end
  local part
  part, why = unique(function (x) return x:find(id, 1, true) ~= nil end, "holds")
  if part or why then return part, why end
  return nil, "no entry's id holds " .. id
end

local QUERY = { worktree = true, git_branch = true, agent = true, cause = true, stop = true, parent = true,
                day = true, hour = true, tool = true, file = true, read = true, wrote = true, asked = true,
                refused = true, since = true, like = true, limit = true }

local function days_of_date(s)
  local y, m, d = tostring(s):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = m > 2 and m - 3 or m + 9
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function has(list, v) for _, x in ipairs(list or {}) do if x == v then return true end end return false end

-- A path in the list, or, for a folder written with a trailing `/`, any path under it.
local function touched(list, path)
  if path:sub(-1) ~= "/" then return has(list, path) end
  for _, x in ipairs(list or {}) do if x:sub(1, #path) == path then return true end end
  return false
end

--- Entries ranked by how near their circumstances are to `q`, best first. Each answers
--- { id, score, matched = { field, ... }, row }.
function history.find(h, q)
  q = q or {}
  for k in pairs(q) do if not QUERY[k] then return nil, "no field called " .. tostring(k) end end
  local qrow = { worktree = q.worktree, git_branch = q.git_branch, agent = q.agent, cause = q.cause,
                 stop = q.stop, parent = q.parent, day = q.day, hour = q.hour,
                 tools = q.tool and { q.tool } or nil, asked = q.asked and { q.asked } or nil,
                 refused = q.refused and { q.refused } or nil, read = {}, wrote = {} }
  if q.day then qrow.days = days_of_date(q.day) end
  if q.read then qrow.read[#qrow.read + 1] = q.read end
  if q.wrote then qrow.wrote[#qrow.wrote + 1] = q.wrote end
  if q.file then qrow.read[#qrow.read + 1] = q.file; qrow.wrote[#qrow.wrote + 1] = q.file end
  local qv, like
  if q.like then
    local id, why = history.resolve(h, q.like)
    if not id then return nil, why end
    like = id
    local p = pairs_of(qrow)
    if #p > 0 then qv = hdc.bundle({ h.vectors[h.by_id[id]], hdc.bundle(p) }) else qv = h.vectors[h.by_id[id]] end
  else
    local p = pairs_of(qrow)
    qv = #p > 0 and hdc.bundle(p) or nil
  end
  local since = q.since and days_of_date(q.since)
  local out = {}
  for i, r in ipairs(h.rows) do
    if not (since and (r.days or 0) < since) and r.id ~= like then
      local matched = {}
      for _, k in ipairs { "worktree", "git_branch", "agent", "cause", "stop", "parent", "day" } do
        if q[k] ~= nil and tostring(r[k]) == tostring(q[k]) then matched[#matched + 1] = k end
      end
      if q.hour ~= nil and r.hour == q.hour then matched[#matched + 1] = "hour" end
      if q.tool and has(r.tools, q.tool) then matched[#matched + 1] = "tool" end
      if q.asked and has(r.asked, q.asked) then matched[#matched + 1] = "asked" end
      if q.refused and has(r.refused, q.refused) then matched[#matched + 1] = "refused" end
      if q.read and has(r.read, q.read) then matched[#matched + 1] = "read" end
      if q.wrote and has(r.wrote, q.wrote) then matched[#matched + 1] = "wrote" end
      if q.file and (touched(r.read, q.file) or touched(r.wrote, q.file)) then matched[#matched + 1] = "file" end
      local score = qv and hdc.similarity(qv, h.vectors[i]) or 0.5
      out[#out + 1] = { id = r.id, score = score, matched = matched, row = r }
    end
  end
  -- What matched exactly comes first. Then, when the question is one of nearness (a day, an
  -- hour, an entry it is like), the vectors' nearness, so a nearer day ranks higher; then the
  -- newer. Between entries that matched the same fields of an exact question, the vectors
  -- differ only by the noise of every other field, and that is no order.
  local near = q.day ~= nil or q.hour ~= nil or q.like ~= nil
  table.sort(out, function (a, b)
    if #a.matched ~= #b.matched then return #a.matched > #b.matched end
    if near and a.score ~= b.score then return a.score > b.score end
    return (a.row.started or 0) > (b.row.started or 0)
  end)
  -- An exact question is answered by what matched it; an entry that matched none of its
  -- fields is only a newer run, and no answer.
  local asked = false
  for k in pairs(q) do if k ~= "limit" and k ~= "since" then asked = true end end
  if asked and not near then
    local kept = {}
    for _, r in ipairs(out) do if #r.matched > 0 then kept[#kept + 1] = r end end
    out = kept
  end
  local limit = tonumber(q.limit) or 10
  while #out > limit do out[#out] = nil end
  return out
end

--- One line a result, for a person or a model.
function history.line(r)
  local row = r.row
  return string.format("%s  %s, %s in %s step%s%s: %s", row.id, tostring(row.cause), tostring(row.stop or "?"),
    tostring(row.steps or 0), row.steps == 1 and "" or "s",
    #r.matched > 0 and ("  [matched " .. table.concat(r.matched, ", ") .. "]") or "",
    tostring(row.prompt or ""))
end

--- An entry's story, by its id or a unique leading part.
function history.recall(h, id)
  local found, why = history.resolve(h, id)
  if not found then return nil, why end
  local story = h.hp.read("runs/" .. found .. "/story")
  if not story then return nil, "the story of " .. found .. " is missing" end
  return story
end

local function evidence_of(h, id)
  local found, why = history.resolve(h, id)
  if not found then return nil, why end
  local body = h.hp.read("runs/" .. found .. "/entry.json")
  if not body then return nil, "the evidence of " .. found .. " is missing" end
  local e = json.decode(body)
  if type(e) ~= "table" then return nil, "the evidence of " .. found .. " does not parse" end
  return e, found
end

--- An entry's evidence as a table, by its id or any part of it that names one; nil and why.
function history.entry(h, id)
  return evidence_of(h, id)
end

-- A text that may be kept apart, read.
local function text_of(h, v)
  if type(v) == "table" and v.kept then
    local id, n = v.kept:match("^(.*)#(%d+)$")
    local t = id and h.hp.read("runs/" .. id .. "/" .. n)
    return t or ("(kept as " .. v.kept .. ", and missing)")
  end
  return v
end

--- The text a story names as kept, or nil.
function history.kept(h, name)
  local id, n = tostring(name):match("^(.*)#(%d+)$")
  if not id then return nil end
  return (h.hp.read("runs/" .. id .. "/" .. n))
end

local function lines_of(s)
  local out = {}
  if s == nil or s == "" then return out end
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
  if out[#out] == "" then out[#out] = nil end
  return out
end

--- A line diff of two texts, unified, with three lines around each change.
function history.diff(a, b, name)
  local x, y = lines_of(a or ""), lines_of(b or "")
  local n, m = #x, #y
  if n * m > 4000000 then
    return string.format("--- %s\n+++ %s\n(the file went from %d lines to %d, too long to set side by side here)\n", name, name, n, m)
  end
  -- the longest common subsequence, from the end
  local L = {}
  for i = n + 1, 1, -1 do
    L[i] = {}
    for j = m + 1, 1, -1 do
      if i > n or j > m then L[i][j] = 0
      elseif x[i] == y[j] then L[i][j] = L[i + 1][j + 1] + 1
      else L[i][j] = math.max(L[i + 1][j], L[i][j + 1]) end
    end
  end
  local ops, i, j = {}, 1, 1
  while i <= n or j <= m do
    if i <= n and j <= m and x[i] == y[j] then ops[#ops + 1] = { " ", x[i], i, j }; i, j = i + 1, j + 1
    elseif i <= n and (j > m or L[i + 1][j] >= L[i][j + 1]) then ops[#ops + 1] = { "-", x[i], i, j }; i = i + 1
    else ops[#ops + 1] = { "+", y[j], i, j }; j = j + 1 end
  end
  local out = { "--- " .. name .. " (before)", "+++ " .. name .. " (after)" }
  local hunks = {}
  for k, op in ipairs(ops) do
    if op[1] ~= " " then
      local from, to = math.max(1, k - 3), math.min(#ops, k + 3)
      local last = hunks[#hunks]
      if last and from <= last.to + 1 then last.to = math.max(last.to, to)
      else hunks[#hunks + 1] = { from = from, to = to } end
    end
  end
  for _, hk in ipairs(hunks) do
    local old_n, new_n = 0, 0
    for t = hk.from, hk.to do
      if ops[t][1] ~= "+" then old_n = old_n + 1 end
      if ops[t][1] ~= "-" then new_n = new_n + 1 end
    end
    -- An empty side names the line before it, as unified diffs do: a new file is -0,0.
    local a, b = ops[hk.from][3], ops[hk.from][4]
    out[#out + 1] = string.format("@@ -%d,%d +%d,%d @@", old_n == 0 and a - 1 or a, old_n,
      new_n == 0 and b - 1 or b, new_n)
    for t = hk.from, hk.to do out[#out + 1] = ops[t][1] .. ops[t][2] end
  end
  if #out == 2 then out[#out + 1] = "(no change)" end
  return table.concat(out, "\n") .. "\n"
end

local function cut(s)
  if #s <= history.CUT then return s end
  return s:sub(1, history.CUT) .. string.format("\n... %d more characters, not shown here.", #s - history.CUT)
end

local function show(v)
  if type(v) == "table" then return (json.encode(v)) or "?" end
  return tostring(v)
end

--- One part of an entry's evidence, as text: calls, call (which = n), transcript, errors,
--- commands, files, diff (which = a path), kept (which = n), model, or all.
function history.evidence(h, id, part_name, which, whole)
  local e, found = evidence_of(h, id)
  if not e then return nil, found end
  local out = {}
  local function say(s) out[#out + 1] = s end
  part_name = part_name or "calls"
  if part_name == "calls" then
    if #(e.calls or {}) == 0 then say("no calls") end
    for i, c in ipairs(e.calls or {}) do
      local how = c.refused and "refused" or (c.ok == false and "failed" or "ok")
      local out1 = tostring(text_of(h, c.output) or ""):match("^[^\n]*") or ""
      say(string.format("%d. %s %s -> %s%s: %s", i, tostring(c.tool), show(c.args or {}), how,
        c.asked and " (asked)" or "", out1))
    end
  elseif part_name == "call" then
    local c = (e.calls or {})[tonumber(which) or 0]
    if not c then return nil, "no call " .. tostring(which) .. " in " .. found end
    say("tool: " .. tostring(c.tool)); say("args: " .. show(c.args or {}))
    say("ok: " .. tostring(c.ok ~= false) .. (c.refused and ", refused" or "") .. (c.asked and ", asked" or ""))
    say("output:"); say(tostring(text_of(h, c.output) or ""))
  elseif part_name == "transcript" then
    for _, msg in ipairs(e.transcript or {}) do
      local calls = ""
      if type(msg.calls) == "table" and #msg.calls > 0 then
        local names = {}
        for _, c in ipairs(msg.calls) do names[#names + 1] = tostring(c.tool) .. show(c.args or {}) end
        calls = " [calls " .. table.concat(names, ", ") .. "]"
      end
      say(string.format("%s: %s%s", tostring(msg.role), tostring(msg.text or ""), calls))
    end
  elseif part_name == "errors" then
    if #(e.errors or {}) == 0 then say("no errors") end
    for _, x in ipairs(e.errors or {}) do say(show(x)) end
  elseif part_name == "commands" then
    if #(e.commands or {}) == 0 then say("no commands") end
    for _, c in ipairs(e.commands or {}) do
      say(string.format("$ %s  (exit %s, %s ms)", table.concat(c.argv or {}, " "), tostring(c.code), tostring(c.ms)))
      if c.out then say(tostring(text_of(h, c.out))) end
      if c.err and c.err ~= "" then say("stderr: " .. tostring(c.err)) end
    end
  elseif part_name == "files" then
    if #(e.files or {}) == 0 then say("no files") end
    for _, f in ipairs(e.files or {}) do
      local what = {}
      if (f.reads or 0) > 0 then what[#what + 1] = "read " .. f.reads .. (f.reads == 1 and " time" or " times") end
      if f.removed then what[#what + 1] = "removed" elseif f.wrote then what[#what + 1] = f.before and "changed" or "created" end
      say(f.path .. ": " .. table.concat(what, ", "))
    end
  elseif part_name == "diff" then
    for _, f in ipairs(e.files or {}) do
      if f.path == which then
        if not f.wrote then return nil, found .. " read " .. which .. " and did not change it" end
        return history.diff(text_of(h, f.before) or "", f.removed and "" or (text_of(h, f.after) or ""), which)
      end
    end
    return nil, found .. " did not touch " .. tostring(which)
  elseif part_name == "kept" then
    local t = h.hp.read("runs/" .. found .. "/" .. tostring(which))
    if not t then return nil, "no kept text " .. tostring(which) .. " in " .. found end
    say(t)
  elseif part_name == "model" then
    say("model: " .. tostring(e.model and e.model.name) .. ", reasoning " .. tostring(e.model and e.model.reasoning))
    for i, m in ipairs(e.model and e.model.calls or {}) do
      say(string.format("%d. %s ms, stop %s%s%s", i, tostring(m.ms), tostring(m.stop),
        m.usage and (", usage " .. show(m.usage)) or "", m.err and (", error " .. show(m.err)) or ""))
    end
  elseif part_name == "all" then
    return show(e)
  else
    return nil, "no part called " .. tostring(part_name) .. ": calls, call, transcript, errors, commands, files, diff, kept, model"
  end
  local s = table.concat(out, "\n")
  return whole and s or cut(s)
end

--- A view of the history that can read and cannot write, for tools.
function history.reader(hp, hooks)
  local view = {}
  local function fresh() return history.open(hp) end
  -- `hooks.found(q, ids)` hears every search's results: a screen lights what a run found.
  function view.find(q)
    local found, why = history.find(fresh(), q)
    if found and hooks and type(hooks.found) == "function" then
      local ids = {}
      for i, r in ipairs(found) do ids[i] = r.id end
      pcall(hooks.found, q, ids)
    end
    return found, why
  end
  function view.recall(id) return history.recall(fresh(), id) end
  function view.evidence(id, part_name, which, whole) return history.evidence(fresh(), id, part_name, which, whole) end
  function view.kept(name) return history.kept(fresh(), name) end
  function view.line(r) return history.line(r) end
  -- The day and time `now` is where the history is kept, as the ids write them.
  function view.today(now)
    local w = type(hp.where) == "function" and hp.where() or {}
    local c = history.civil(now, w.offset)
    return string.format("%04d-%02d-%02d, %02d:%02d", c.year, c.month, c.day, c.hour, c.min)
  end
  return view
end

--- A run function that keeps each run it makes (docs/spec/history.md, "How a run is kept").
--- `run` is (decl, prompt, port, opts) -> result, as turn.run is, and so is the answer.
---
--- `opts.entry` is taken out before `run` sees it: false keeps nothing, and a table may say
--- `cause`, `parent`, `declaration` (the feature text) and `claimed(id)`, called as soon as
--- the id is claimed so a job can name the reply it came from before that reply has ended.
--- A port with no history runs as it was. One that has one runs with a view that reads in
--- the history's place, kept or not: the port that writes never reaches a tool body.
local keepers = setmetatable({}, { __mode = "k" })

--- Marks `run` as one that keeps its own runs and honours `opts.entry`, as `agent.run` does;
--- `history.keeper` hands it back unchanged, so a run is never kept twice.
function history.keeps(run)
  keepers[run] = true
  return run
end

function history.keeper(run)
  if keepers[run] then return run end
  return history.keeps(function (decl, prompt, p, opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    local entry = o.entry
    o.entry = nil
    if type(p) ~= "table" or type(p.history) ~= "table" or type(p.history.claim) ~= "function" then
      return run(decl, prompt, p, o)
    end
    local writer = p.history
    local now = function () return p.clock and p.clock.now and p.clock.now() or 0 end
    local keeping = nil
    if entry ~= false then
      local e = type(entry) == "table" and entry or {}
      local where = type(writer.where) == "function" and writer.where() or {}
      local started = now()
      local id, why = history.claim(writer, where, started, decl and decl.name or "agent", e.cause or "run")
      if id then
        local tapped, log = history.tap(p)
        if type(e.claimed) == "function" then pcall(e.claimed, id, log, started) end
        p = tapped
        keeping = { id = id, where = where, log = log, started = started, e = e }
      else
        local notes = {}
        for i, n in ipairs(o.notes or {}) do notes[i] = n end
        notes[#notes + 1] = "the history could not be kept: " .. tostring(why)
        o.notes = notes
      end
    end
    local q = {}
    for k, v in pairs(p) do q[k] = v end
    q.history = history.reader(writer, { found = type(entry) == "table" and entry.found or nil })

    local result = run(decl, prompt, q, o)
    if keeping and type(result) == "table" then
      result.entry = keeping.id
      local e = keeping.e
      local ok, kept, why = pcall(history.keep, writer, {
        id = keeping.id, parent = e.parent, cause = e.cause or "run", from = e.from, decl = decl,
        declaration = e.declaration, prompt = prompt, result = result, log = keeping.log,
        started = keeping.started, where = keeping.where, ended = now(),
      })
      if not ok or not kept then
        result.notes = result.notes or {}
        result.notes[#result.notes + 1] = "the history could not be kept: " .. tostring(ok and why or kept)
      end
    end
    return result
  end)
end

--- Runs a story again on the doubles, with its kept texts found in this history. `drivers`
--- are behaviour's. Answers the report.
function history.replay(h, text, drivers, behaviour)
  local pickles, why = gherkin.pickle(text)
  if not pickles then return nil, why end
  local d = {}
  for k, v in pairs(drivers) do d[k] = v end
  d.kept = function (name) return history.kept(h, name) end
  return behaviour.run(pickles, d)
end

return history
