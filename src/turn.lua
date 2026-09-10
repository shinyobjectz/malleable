-- turn — the turn loop. Rules 1 and 5 of DESIGN.md live here.
--
-- Rule 1: this file knows no vendor. It reaches the world only through the `port`
-- table it was handed, so a whole run drives in a test with nothing real behind it.
-- Rule 5: every run ends, and says which of four things ended it.
--
-- The only module it may require is the declaration surface.

local spec = (function ()
  local ok, m = pcall(require, "spec")
  if ok then return m end
  return require("src.spec")
end)()

local turn = {}

-- ---------------------------------------------------------------- small helpers

local STOPS = { "answered", "budget", "refused", "error" }

-- The four outcomes, forever. A caller branches on `result.stop`, never on `reason`.
--
-- `turn.stops` is not a stored table but a fresh one on every read, carrying a
-- metatable that raises on a new key. Growing the list is loud; overwriting one of the
-- four is silent but lands in a copy nobody else will ever see. A stored table cannot
-- do both: `__newindex` does not fire for a key that is already there, and the proxy
-- that would fix that needs `__len`, which LuaJIT does not honour on a table. So the
-- list is rebuilt instead, and one caller can no longer corrupt the constant that every
-- other caller reads. `#`, `ipairs` and `table.concat` all work on it as they look.
setmetatable(turn, {
  __index = function (_, k)
    if k ~= "stops" then return nil end
    local out = {}
    for i = 1, #STOPS do out[i] = STOPS[i] end
    return setmetatable(out, {
      __newindex = function () error("turn.stops is fixed: the stop reasons are the four listed", 2) end,
      __metatable = "fixed",
    })
  end,
})

local function q(s)
  return '"' .. tostring(s) .. '"'
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function is_list(v)
  if type(v) ~= "table" then return false end
  if next(v) == nil then return true end
  return #v == count(v)
end

-- One line of prose for a value that arrived from the world: a port's error table,
-- a raised string, whatever a broken port hands back. Deterministic on every input,
-- because a run must read the same twice — so no address of a table ever appears.
local function text_of(v)
  local t = type(v)
  if t == "string" then return v end
  if v == nil then return "" end
  if t == "table" then
    if type(v.message) == "string" and v.message ~= "" then return v.message end
    if type(v.code) == "string" and v.code ~= "" then return v.code end
    return "a table of " .. count(v) .. " entries"
  end
  if t == "number" or t == "boolean" then return tostring(v) end
  return "a " .. t
end

local function code_of(v)
  if type(v) == "table" and type(v.code) == "string" and v.code ~= "" then return v.code end
  return nil
end

-- What a tool's return value looks like in the transcript. Always a string, always
-- the same string for the same value.
local function output_of(v)
  local t = type(v)
  if v == nil then return "(no output)" end
  if t == "string" then return v end
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "table" then return "(the tool returned a table of " .. count(v) .. " entries, not text)" end
  return "(the tool returned a " .. t .. ", not text)"
end

-- A copy of anything handed outward — to a hook, to the gate, to a tool body, to the
-- model port. Nothing done to a copy can reach the run's own record, which is what
-- makes "hooks observe" and "args as validated" true rather than promised. Cycle-safe.
-- Metatables are dropped: a copy that inherited __index would hand the original back.
local function copy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, x in pairs(v) do out[k] = copy(x, seen) end
  return out
end

-- pcall that also reports how many values came back, without table.pack, which the
-- dialect note does not promise on both interpreters.
local function call_counted(f, a)
  local function collect(ok, ...)
    return ok, select("#", ...), ...
  end
  return collect(pcall(f, a))
end

local KIND_TEXT = {
  string = "a string", number = "a number", boolean = "a boolean",
  object = "a table", array = "a list",
}

-- Check a model's arguments against what the tool declared. Returns the validated
-- table (declared names only) and a list of faults; the body runs only when the
-- fault list is empty.
local function check_args(tool, raw)
  local faults, out = {}, {}
  if raw == nil then raw = {} end
  if type(raw) ~= "table" then
    return out, { "the arguments must be a table, and arrived as " .. type(raw) }
  end
  for i = 1, #tool.arg_order do
    local k = tool.arg_order[i]
    local p = tool.args[k]
    local v = raw[k]
    if v == nil then
      if p.required then
        faults[#faults + 1] = "the argument " .. q(k) .. " is required and was not given"
      end
    else
      local good
      if p.kind == "array" then good = is_list(v)
      elseif p.kind == "object" then good = type(v) == "table"
      else good = type(v) == p.kind end
      if good then
        out[k] = v
      else
        faults[#faults + 1] = "the argument " .. q(k) .. " must be "
          .. (KIND_TEXT[p.kind] or p.kind) .. ", and arrived as " .. type(v)
      end
    end
  end
  local extra = {}
  for k in pairs(raw) do
    if type(k) ~= "string" or tool.args[k] == nil then extra[#extra + 1] = tostring(k) end
  end
  table.sort(extra)
  for i = 1, #extra do
    faults[#faults + 1] = "the argument " .. q(extra[i]) .. " was not declared by this tool"
  end
  if #faults > 0 then
    if #tool.arg_order == 0 then
      faults[#faults + 1] = "this tool takes no arguments"
    else
      faults[#faults + 1] = "this tool takes: " .. table.concat(tool.arg_order, ", ")
    end
  end
  return out, faults
end

-- The approval gate answers in one of two shapes, and this reads both. spec/port.md
-- says a decision is { allow = boolean, why = string|nil }; spec/turn.md wrote it as
-- one of three strings. A stop — end the whole run, not just this call — is
-- decision.stop == true in the table form and "stop" in the string form.
-- Anything else is a deny, because a gate that misbehaves must fail closed.
local function read_decision(v)
  local t = type(v)
  if t == "string" then
    if v == "allow" or v == "deny" or v == "stop" then return v, nil, nil end
    return nil, nil, "the gate answered " .. q(v) .. ", which is not a decision"
  end
  if t == "table" then
    local why = type(v.why) == "string" and v.why or nil
    if v.stop == true or v.decision == "stop" then return "stop", why, nil end
    if v.allow == true or v.decision == "allow" then return "allow", why, nil end
    if v.allow == false or v.decision == "deny" then return "deny", why, nil end
    return nil, why, "the gate answered a table with no allow boolean"
  end
  return nil, nil, "the gate answered " .. (v == nil and "nothing" or ("a " .. t))
end

-- The port may be wired either way round: spec/port.md has port.model.call(request)
-- and port.ask.request(q); spec/turn.md wrote them as bare functions. Both are read.
local function model_fn(port)
  if type(port) ~= "table" then return nil end
  local m = port.model
  if type(m) == "function" then return m end
  if type(m) == "table" and type(m.call) == "function" then
    return function (request) return m.call(request) end
  end
  return nil
end

local function ask_fn(port)
  if type(port) ~= "table" then return nil end
  local a = port.ask
  if type(a) == "function" then return a end
  if type(a) == "table" and type(a.request) == "function" then
    return function (request) return a.request(request) end
  end
  return nil
end

-- The names a tool body always sees on its context, whatever the port carries.
local RESERVED = { args = true, step = true, call = true, agent = true, depth = true,
                   note = true, nested = true, acted = true }

-- ------------------------------------------------------------------ validation

local OPT_NUMBERS = {
  budget = 1, calls_per_step = 1, malformed_limit = 1, depth = 0, max_depth = 0,
}

-- The same checks run does, without running. Never raises, for any input at all.
function turn.check(agent, port, opts)
  local p = {}

  local wants_ask = false
  if type(agent) ~= "table" then
    p[#p + 1] = "agent is a declaration table, and arrived as " .. type(agent)
  else
    -- Every read of the declaration is inside this pcall, so even a table that
    -- raises when it is indexed comes back as a problem rather than as a raise.
    local read = pcall(function ()
      local problems = spec.problems(agent)
      for i = 1, #problems do
        p[#p + 1] = "the declaration cannot run: " .. problems[i]
      end
      if type(agent.tools) == "table" and type(agent.order) == "table" then
        for i = 1, #agent.order do
          local t = agent.tools[agent.order[i]]
          if type(t) == "table" and t.ask then wants_ask = true end
        end
      end
      local b = agent.budget
      local overridden = type(opts) == "table" and type(opts.budget) == "number"
      if not (type(b) == "number" and b >= 1 and b == b - b % 1) and not overridden then
        p[#p + 1] = "the declaration's budget is a whole number of steps, at least 1"
      end
    end)
    if not read then
      p[#p + 1] = "agent is not a declaration this harness can read"
    end
  end

  if type(port) ~= "table" then
    p[#p + 1] = "port is a table of capabilities, and arrived as " .. type(port)
  else
    if not model_fn(port) then
      p[#p + 1] = "the port has no model: port.model.call must be a function"
    end
    if wants_ask and not ask_fn(port) then
      p[#p + 1] = "a tool asks before it runs, and the port has no approval gate: "
        .. "port.ask.request must be a function"
    end
  end

  if opts ~= nil then
    if type(opts) ~= "table" then
      p[#p + 1] = "opts is a table or nil, and arrived as " .. type(opts)
    else
      local unknown = {}
      for k in pairs(opts) do
        if not (OPT_NUMBERS[k] or k == "id" or k == "system" or k == "tracer"
                or k == "run_span" or k == "notes") then unknown[#unknown + 1] = tostring(k) end
      end
      table.sort(unknown)
      for i = 1, #unknown do
        p[#p + 1] = "opts has no field " .. q(unknown[i])
      end
      for k, low in pairs(OPT_NUMBERS) do
        local v = opts[k]
        if v ~= nil then
          if type(v) ~= "number" then
            p[#p + 1] = "opts." .. k .. " is a number, and arrived as " .. type(v)
          elseif v < low or v ~= (v - v % 1) then
            p[#p + 1] = "opts." .. k .. " is a whole number, at least " .. low
          end
        end
      end
      if opts.id ~= nil and type(opts.id) ~= "string" then
        p[#p + 1] = "opts.id is a string, and arrived as " .. type(opts.id)
      end
      if opts.system ~= nil and type(opts.system) ~= "string" then
        p[#p + 1] = "opts.system is a string, and arrived as " .. type(opts.system)
      end
      -- A caller that started the run before the loop did: it holds the recorder, it
      -- opened the run's own span, and it may already have made notes about the run.
      -- All three are checked for shape here rather than trusted, because a half-built
      -- recorder would fail in the middle of a run instead of before one.
      if opts.tracer ~= nil then
        if type(opts.tracer) ~= "table" then
          p[#p + 1] = "opts.tracer is a recorder from turn.recorder, and arrived as " .. type(opts.tracer)
        else
          local missing = {}
          for _, fn in ipairs({ "open_span", "close_span", "close_all" }) do
            if type(opts.tracer[fn]) ~= "function" then missing[#missing + 1] = fn end
          end
          for i = 1, #missing do
            p[#p + 1] = "opts.tracer has no " .. missing[i] .. ": it is a recorder from turn.recorder"
          end
        end
      end
      if opts.run_span ~= nil then
        if type(opts.run_span) ~= "string" then
          p[#p + 1] = "opts.run_span is a span id, and arrived as " .. type(opts.run_span)
        elseif opts.tracer == nil then
          p[#p + 1] = "opts.run_span names a span in a recorder, and opts.tracer is missing"
        end
      end
      if opts.notes ~= nil then
        if type(opts.notes) ~= "table" then
          p[#p + 1] = "opts.notes is a list of strings, and arrived as " .. type(opts.notes)
        else
          for i = 1, #opts.notes do
            if type(opts.notes[i]) ~= "string" then
              p[#p + 1] = "opts.notes[" .. i .. "] is a string, and arrived as " .. type(opts.notes[i])
            end
          end
        end
      end
    end
  end

  -- Sorted, so two hosts reading the same broken wiring read the same list.
  table.sort(p)
  return #p == 0, p
end

-- ------------------------------------------------------------------- the run

-- ------------------------------------------------------------------------ the trace
--
-- A run records its own tree -- a turn holds steps, a step holds a model call and the tool
-- calls it asked for, a tool call may hold a question put to a human -- and the record is
-- a FACT ABOUT THE RESULT, not a favour from a sink. `result.spans` is complete and
-- nothing drops it; the same records also go out through the log port as they happen, for
-- a host that wants a live view, and that half stays lossy exactly as `spec/port.md` says.
--
-- The recorder is HERE rather than in `src/trace.lua` because this file's own header says
-- the only module it may require is the declaration surface, and a trace is not worth
-- weakening that for. `trace.lua` renders what this produces -- to a wire format as a
-- string, or to a tree for a person -- and knows nothing about a run. Which format, and
-- whose, is that file's business: naming one here is what rule 1 forbids.
--
-- Rule 8 lives here too, by construction: every value written below is a name, a count, a
-- duration or a term from a closed set. Never a prompt, a model's text, a file's contents,
-- a tool's arguments or its output. A trace exporter's whole job is to send what it is
-- given somewhere else.
--
-- Contract: spec/trace.md.
local function recorder(clock, log, depth)
  local r = { spans = {}, open = {}, n = 0 }

  local function now()
    if type(clock) == "table" and type(clock.now) == "function" then
      local ok, t = pcall(clock.now)
      if ok and type(t) == "number" then return math.floor(t * 1000) end
    end
    return 0
  end

  -- A span still open when the run ends is closed by the run and marked, because a span
  -- that never closes is the one bug in a tracer that hides every other one.
  function r.open_span(name, parent, attrs)
    r.n = r.n + 1
    local id = tostring(r.n)
    local span = { id = id, parent = parent, name = name, at = now(), ms = 0,
                   ok = true, attrs = attrs or {} }
    r.spans[#r.spans + 1] = span
    r.open[id] = span
    if type(log) == "table" and type(log.write) == "function" then
      pcall(log.write, "debug", "span.open", { span = id, parent = parent, name = name, depth = depth })
    end
    return id
  end

  function r.close_span(id, attrs, ok)
    local span = r.open[id]
    if not span then return end
    r.open[id] = nil
    span.ms = now() - span.at
    if ok == false then span.ok = false end
    for k, v in pairs(attrs or {}) do span.attrs[k] = v end
    if type(log) == "table" and type(log.write) == "function" then
      pcall(log.write, "debug", "span.close", { span = id, name = span.name, ms = span.ms, ok = span.ok })
    end
  end

  -- A finished tree from somewhere else, hung under a span of this one.
  --
  -- Copies. The ids are re-stamped from this recorder's own counter and the parents
  -- remapped with them, so two runs that both numbered their spans `"1"` cannot collide
  -- and a child cannot name a parent it was never given. Times are taken verbatim: the
  -- child read the same clock port, so its `at` is comparable with this run's without
  -- being re-derived.
  function r.adopt(spans, parent)
    if type(spans) ~= "table" then return end
    local mapped = {}
    for i = 1, #spans do
      local from = spans[i]
      if type(from) == "table" and type(from.name) == "string" then
        r.n = r.n + 1
        local id = tostring(r.n)
        mapped[tostring(from.id)] = id
        local attrs = {}
        for k, v in pairs(type(from.attrs) == "table" and from.attrs or {}) do attrs[k] = v end
        r.spans[#r.spans + 1] = {
          id = id,
          parent = (from.parent ~= nil and mapped[tostring(from.parent)]) or parent,
          name = from.name,
          at = tonumber(from.at) or 0,
          ms = tonumber(from.ms) or 0,
          ok = from.ok ~= false,
          attrs = attrs,
        }
      end
    end
  end

  -- Sweep what is still open, and mark it. `from` bounds the sweep to spans opened at or
  -- after that id, so a caller that opened a span BEFORE handing the recorder over --
  -- `agent.tick` around a beat, a delegating turn around a child run -- still holds its
  -- own and closes it itself. Without the bound, the first run to finish would mark every
  -- span above it unclosed, which is the tracer reporting its own bookkeeping as a fault
  -- in the run.
  function r.close_all(from)
    local floor = tonumber(from) or 0
    for id, span in pairs(r.open) do
      if (tonumber(id) or 0) >= floor then
        span.ms = now() - span.at
        span.ok = false
        span.attrs["malleable.unclosed"] = true
        r.open[id] = nil
      end
    end
  end

  return r
end

--- A recorder, for a caller that starts a run and wants what happens BEFORE the loop on
--- the same tree — a skill catalogued, a server connected, a beat firing.
---
--- Handed out rather than kept private, and handed out from HERE rather than from
--- `src/trace.lua`, for the reason this file's header gives: the only module it may
--- require is the declaration surface, and a recorder in another file would make it
--- require that one too. `turn.run` still makes its own when nobody hands it one, so a
--- host that calls the loop directly is unchanged and is still handed a whole tree.
---
--- What a caller gets is three functions and a list. It is not a capability a tool body
--- may hold: rule 8 is enforced by `trace.allowed` over the attributes, and a body that
--- could open a span could write a name the vocabulary never agreed to. `agent.lua` holds
--- one; nothing reachable from a tool does.
turn.recorder = recorder

function turn.run(agent, prompt, port, opts)
  local ok, problems = turn.check(agent, port, opts)
  if not ok then
    error("turn.run: " .. table.concat(problems, "; "), 2)
  end
  if type(prompt) ~= "string" then
    error("turn.run: prompt is a string, and arrived as " .. type(prompt), 2)
  end
  opts = opts or {}

  local budget = opts.budget or agent.budget
  local per_step = opts.calls_per_step or 8
  local malformed_limit = opts.malformed_limit or 3
  local depth = opts.depth or 0
  local max_depth = opts.max_depth or 3
  local ask = ask_fn(port)
  local model = model_fn(port)

  local result = {
    id = opts.id or agent.name,
    stop = nil,
    reason = nil,
    answer = nil,
    steps = 0,
    budget = budget,
    transcript = {},
    calls = {},
    err = nil,
    notes = {},
  }

  local function note(s)
    result.notes[#result.notes + 1] = s
  end

  -- Notes the caller already made about this run, in front of the ones the run makes. A
  -- server that was never reached is a fact about the whole run and not about the step
  -- that noticed, and arriving here rather than being spliced on afterwards is what makes
  -- `malleable.notes` count them.
  for i = 1, #(opts.notes or {}) do result.notes[i] = opts.notes[i] end

  -- The recorder is the caller's when the caller started the run before the loop did.
  -- `agent.run` does: it catalogues skills and connects servers first, and those are part
  -- of invoking this agent rather than a separate tree beside it. The span the loop hangs
  -- its steps under is then the caller's too, and the loop still CLOSES it, because what
  -- a run amounts to — how it stopped, how many steps, how many calls — is only known
  -- here (spec/trace.md, "The spans").
  local tracer = opts.tracer or recorder(port.clock, port.log, depth)
  result.spans = tracer.spans
  local run_span = opts.run_span or tracer.open_span(
    "invoke_agent " .. tostring(agent.name or "agent"), nil, {
      ["gen_ai.operation.name"] = "invoke_agent",
      ["gen_ai.agent.name"] = tostring(agent.name or "agent"),
      ["gen_ai.request.model"] = tostring(agent.model or ""),
      ["malleable.budget"] = budget,
      ["malleable.depth"] = depth,
    })
  local step_span = nil

  -- A hook may say NO. It may not say "yes, but different".
  --
  -- The copy handed to a hook is what makes "hooks observe" mechanical: an observer cannot
  -- swap an approved path for another between validation and the gate. A VETO breaks none
  -- of that — it removes a call rather than rewriting one — so a hook that returns a
  -- refusal is honoured, and the refusal becomes a result the model reads, exactly as the
  -- approval gate's does (rule 4).
  --
  -- Anything else a hook returns is REFUSED LOUDLY. Before this, every return was silently
  -- discarded, so `return { stop = "never more than three" }` read as a declared limit and
  -- was not one — the highest-severity kind of failure, because it looks like success
  -- (mar-43fv).
  local function veto_of(event, v)
    if v == nil then return nil end
    if type(v) == "table" then
      local why = v.why or v.reason or v.stop
      if v.allow == false or v.deny == true or v.stop ~= nil or v.refuse ~= nil then
        return { why = type(why) == "string" and why or nil, halt = v.stop ~= nil and v.stop ~= false }
      end
    end
    note(("the %s hook returned %s, which is not a refusal and was not applied. A hook observes; "
      .. "to refuse a call return { allow = false, why = ... }, and to change one use the approval "
      .. "channel"):format(event, type(v) == "table" and "a table with no refusal in it" or ("a " .. type(v))))
    return nil
  end

  local function fire(event, payload)
    local hs = type(agent.hooks) == "table" and agent.hooks[event] or nil
    if not hs then return nil end
    payload.event = event
    payload.id = result.id
    local veto
    for i = 1, #hs do
      local fired, err = pcall(hs[i], payload)
      if not fired then
        note("the " .. event .. " hook raised: " .. text_of(err))
      elseif veto == nil then
        veto = veto_of(event, err)
      end
    end
    return veto
  end

  local function say(m)
    result.transcript[#result.transcript + 1] = m
    return m
  end

  -- What goes to the model: the transcript without the system message, which the
  -- request carries in its own field, and each message copied so a port that keeps
  -- what it was sent keeps what it was sent.
  local function wire()
    local out = {}
    for i = 1, #result.transcript do
      local m = result.transcript[i]
      if m.role ~= "system" then
        -- Copied all the way down: an assistant message carries a `calls` list, and a
        -- port that edited it in place would be editing the run's own record.
        out[#out + 1] = copy(m)
      end
    end
    return out
  end

  -- The system message. `opts.system` replaces the declaration's, and is how anything
  -- composed at run time reaches the model without this file learning what it is: the
  -- skills briefing is the first such thing (spec/skills.md), and the alternative was a
  -- dependency from the core onto a subsystem, which rule 1 does not allow.
  local system_text = type(agent.system) == "string" and agent.system or nil
  if opts and type(opts.system) == "string" then system_text = opts.system end

  local function finish(stop, reason, err)
    result.stop = stop
    result.reason = reason
    result.err = err
    if step_span then tracer.close_span(step_span); step_span = nil end
    tracer.close_span(run_span, {
      ["malleable.stop"] = stop,
      ["malleable.steps"] = result.steps,
      ["malleable.calls"] = #result.calls,
      ["malleable.notes"] = #result.notes,
    }, stop ~= "error")
    tracer.close_all(run_span)
    fire("stop", {
      stop = stop, reason = reason, steps = result.steps,
      answer = result.answer, depth = depth,
    })
    return result
  end

  -- The context a tool body is handed. Rule 4 made mechanical: the model and the
  -- gate are withheld, so a tool can neither approve itself nor spend the budget.
  -- Worked out once for the whole run: `model` and `ask` withheld, because rule 4 says
  -- a tool body cannot approve itself or spend the budget, and the six names the context
  -- reserves withheld too. A clash is one note per run, not one per call.
  local passthrough, clash = {}, {}
  for k, v in pairs(port) do
    if k ~= "model" and k ~= "ask" then
      if RESERVED[k] then clash[#clash + 1] = tostring(k) else passthrough[k] = v end
    end
  end
  table.sort(clash)

  -- Where a tool body leaves a FINISHED tree it ran: `agent.delegate` puts the child
  -- run's spans here, and the call's own span adopts them (mar-gogg).
  --
  -- A list, not a tracer. Rule 4 withholds `model` and `ask` from a body because those
  -- are AUTHORITY -- a body holding them could approve itself or spend the budget. A
  -- recorder is authority of the same kind: it reaches across the whole run, and a body
  -- with one could open a span anywhere in the tree or leave one open forever. A list of
  -- spans that have already closed is not: it is data, this file re-stamps every id and
  -- every parent before adopting it, and the worst a body can do with it is describe
  -- itself inaccurately -- which a body can already do by returning any string it likes.
  local nested = nil

  -- What a call DID, as terms, for its own span. The shell tool parses its own command
  -- line and leaves the terms here; the command line itself never moves, which is rule 8
  -- getting stronger rather than being relaxed for it (spec/command.md).
  --
  -- This file does not hold the closed set and does not check against it: rule 1 lets it
  -- require the declaration surface and nothing else, and eleven terms copied here would
  -- be a fourth place for the vocabulary to drift. The gate is `trace.allowed`, in the
  -- file that owns what an attribute may say, and the rule 8 test walks every span of the
  -- whole suite through it.
  local acted = nil

  local function context(args, step, call_id)
    local c = {}
    for k, v in pairs(passthrough) do c[k] = v end
    c.args = copy(args)
    c.step = step
    c.call = call_id
    c.agent = agent.name
    c.depth = depth
    c.note = function (s) note(text_of(s)) end
    -- Fresh per call, so one call cannot read or extend what another left.
    nested = {}
    acted = {}
    c.nested = nested
    c.acted = acted
    return c
  end

  if depth > max_depth then
    if system_text then say { role = "system", text = system_text } end
    say { role = "user", text = prompt }
    fire("start", { prompt = prompt, budget = budget, depth = depth })
    return finish("error",
      "this run is nested " .. depth .. " deep, past the limit of " .. max_depth .. ".",
      { where = "depth", message = "a run at depth " .. depth .. " is past max_depth " .. max_depth })
  end

  if system_text then say { role = "system", text = system_text } end
  say { role = "user", text = prompt }
  fire("start", { prompt = prompt, budget = budget, depth = depth })
  for i = 1, #clash do
    note("the port key " .. q(clash[i]) .. " is a name the tool context reserves, and was not passed through")
  end

  -- One tool call, start to finish. Returns the record; the caller turns it into a
  -- message. `blocked` is a sentence when an earlier call in this reply stopped the
  -- run, or when this call is past the per-step limit.
  -- The tool span is a WRAPPER around dispatch rather than a line inside it, because the
  -- body has a dozen return paths -- refused, malformed, no such tool, raised, stopped --
  -- and a span opened in one place and closed in twelve is a span that leaks in one of
  -- them. `tool_span` is the parent a gate question hangs off.
  local tool_span = nil
  local dispatch_body

  local function dispatch(call, step, call_id, blocked)
    local name = type(call) == "table" and call.tool or nil
    local named = (type(name) == "string" and name ~= "") and name or "(unnamed)"
    local span = tracer.open_span("execute_tool " .. named, step_span, {
      ["gen_ai.operation.name"] = "execute_tool",
      ["gen_ai.tool.name"] = named,
      ["gen_ai.tool.call.id"] = tostring(call_id),
    })
    local outer, outer_nested, outer_acted = tool_span, nested, acted
    tool_span = span
    nested, acted = nil, nil
    local ok, record = pcall(dispatch_body, call, step, call_id, blocked)
    -- Whatever the body ran, under the call that ran it. Done before the branch below,
    -- so a delegate whose child failed and whose own body then raised still hands back
    -- what the child did -- which is the trace somebody will want.
    local left = nested
    if type(left) == "table" then
      for i = 1, #left do
        if type(left[i]) == "table" then tracer.adopt(left[i].spans, span) end
      end
    end
    local did = acted
    tool_span, nested, acted = outer, outer_nested, outer_acted
    if not ok then
      tracer.close_span(span, { ["malleable.refused_by"] = "error" }, false)
      error(record, 0)
    end
    local attrs = {}
    if record.refused then
      attrs["malleable.refused_by"] = record.vetoed and "hook" or "gate"
    end
    -- Sorted and joined, so the same call reads the same twice and two runs compare.
    -- `unplaced` is what the body could not name: the number that says how much of this
    -- call the vocabulary is blind to, and the one that has to go DOWN.
    if type(did) == "table" then
      local terms, seen, unplaced = {}, {}, 0
      for i = 1, #did do
        local e = did[i]
        if type(e) == "table" then
          for j = 1, #(e.acts or {}) do
            local t = e.acts[j]
            if type(t) == "string" and not seen[t] then seen[t] = true; terms[#terms + 1] = t end
          end
          if type(e.unplaced) == "number" then unplaced = unplaced + e.unplaced end
        end
      end
      table.sort(terms)
      if #terms > 0 then attrs["malleable.act"] = table.concat(terms, ", ") end
      if unplaced > 0 then attrs["malleable.unplaced"] = unplaced end
    end
    tracer.close_span(span, attrs, record.ok == true)
    return record
  end

  function dispatch_body(call, step, call_id, blocked)
    local name = type(call) == "table" and call.tool or nil
    local rec = {
      -- An empty string is not a name: a call that named nothing must not be recorded
      -- as a call to a tool called "".
      step = step, id = call_id, tool = (type(name) == "string" and name ~= "") and name or "(unnamed)",
      args = {}, ok = false, output = "", asked = false,
    }

    if blocked then
      rec.output = blocked.output
      rec.refused = blocked.refused
      return rec
    end

    if type(call) ~= "table" or type(name) ~= "string" or name == "" then
      rec.output = "a tool call names a tool: it needs a `tool` field holding the name of one."
      return rec
    end

    local tool = agent.tools[name]
    if not tool then
      local have = #agent.order > 0 and table.concat(agent.order, ", ") or "none"
      rec.output = "there is no tool named " .. q(name) .. ". The tools that exist are: " .. have .. "."
      return rec
    end

    local args, faults = check_args(tool, call.args)
    rec.args = args
    if #faults > 0 then
      rec.output = "the call to " .. q(name) .. " was not made: " .. table.concat(faults, "; ") .. "."
      return rec
    end

    -- A copy, not the table: a hook observes a run, it does not edit one. Handing the
    -- live table over would let an observer swap an approved path for another after
    -- validation and before the gate.
    local vetoed = fire("call", { step = step, call = call_id, tool = name, args = copy(args), ask = tool.ask, depth = depth })
    if vetoed then
      rec.refused = true
      rec.vetoed = true
      rec.output = "the call was refused" .. (vetoed.why and (": " .. vetoed.why .. ".") or " by a hook.")
      if vetoed.halt then rec.stopped = true end
      return rec
    end

    if tool.ask then
      rec.asked = true
      local gate_span = tracer.open_span("malleable.gate " .. tostring(name), tool_span, {
        ["gen_ai.tool.name"] = tostring(name),
      })
      local asked, n, a, b = call_counted(ask, {
        agent = agent.name, tool = name, about = tool.about,
        args = copy(args), step = step, call = call_id,
      })
      local decision, why, complaint
      if not asked then
        complaint = "the gate raised: " .. text_of(a)
      else
        decision, why, complaint = read_decision(a)
        if n > 1 and b ~= nil then
          note("the gate answered with more than one value; only the first was read")
        end
      end
      if complaint then
        note("the call " .. q(name) .. " was refused because " .. complaint)
        decision = "deny"
        why = why or complaint
      end
      -- How often an agent asks, and what it is told, is the number nobody else's
      -- telemetry has, and it says more about whether an agent is safe to leave running
      -- than any token count. The WHY is a term from a closed set, never the sentence:
      -- a gate's reason is a person's words about this call (rule 8).
      tracer.close_span(gate_span, {
        ["malleable.gate.answer"] = (complaint and "absent")
          or (decision == "allow" and "allowed")
          or (decision == "stop" and "stopped")
          or "refused",
      }, complaint == nil)
      if decision == "stop" then
        rec.refused = true
        rec.output = "the run was stopped at the approval gate"
          .. (why and (": " .. why .. ".") or ".")
        rec.stopped = true
        return rec
      end
      if decision == "deny" then
        rec.refused = true
        rec.output = "the call was refused" .. (why and (": " .. why .. ".") or ".")
        return rec
      end
    end

    local ran, n, v, second = call_counted(tool.run, context(args, step, call_id))
    if not ran then
      rec.output = "the tool " .. q(name) .. " raised: " .. text_of(v)
      note("the tool " .. q(name) .. " raised: " .. text_of(v))
      return rec
    end
    if v == nil and n >= 2 and second ~= nil then
      -- The Lua convention the ports keep: nothing, and a reason.
      local code = code_of(second)
      rec.output = "the tool " .. q(name) .. " failed: " .. text_of(second)
        .. (code and (" (" .. code .. ")") or "")
      rec.value = second
      return rec
    end
    if n > 1 then
      note("the tool " .. q(name) .. " returned " .. n .. " values; only the first was kept")
    end
    rec.ok = true
    rec.output = output_of(v)
    if type(v) ~= "string" and v ~= nil then rec.value = v end
    return rec
  end

  local malformed_run = 0

  while true do
    if result.steps >= budget then
      return finish("budget",
        "the budget of " .. budget .. " steps was spent without a final answer.")
    end

    result.steps = result.steps + 1
    local step = result.steps
    if step_span then tracer.close_span(step_span) end
    step_span = tracer.open_span("malleable.step", run_span, { ["malleable.steps"] = step })
    fire("step", { step = step, budget = budget, depth = depth })

    local request = {
      model = agent.model,
      system = system_text,
      messages = wire(),
      tools = spec.schema(agent),  -- fresh, so a port that edits it cannot poison step two
    }
    -- `gen_ai.provider.name` is the declaration's own prefix and nothing else. A model id
    -- with no prefix means the declaration named no provider, and the attribute is then
    -- absent rather than guessed: which provider a bare id belongs to is the host's
    -- question, and answering it here would be rule 1 broken by a default.
    local chat_attrs = {
      ["gen_ai.operation.name"] = "chat",
      ["gen_ai.request.model"] = tostring(agent.model or ""),
    }
    local provider = tostring(agent.model or ""):match("^([%w_%-%.]+):")
    if provider then chat_attrs["gen_ai.provider.name"] = provider end
    local chat_span = tracer.open_span("chat " .. tostring(agent.model or "model"), step_span, chat_attrs)
    local reached, n, reply, err = call_counted(model, request)
    do
      local attrs = {}
      if type(reply) == "table" and type(reply.usage) == "table" then
        if type(reply.usage.input) == "number" then attrs["gen_ai.usage.input_tokens"] = reply.usage.input end
        if type(reply.usage.output) == "number" then attrs["gen_ai.usage.output_tokens"] = reply.usage.output end
      end
      if type(reply) == "table" and type(reply.calls) == "table" then
        attrs["malleable.calls"] = #reply.calls
      end
      tracer.close_span(chat_span, attrs, reached and reply ~= nil)
    end

    if not reached then
      local message = "the model call raised: " .. text_of(reply)
      return finish("error", message, { where = "model", message = message })
    end
    if reply == nil then
      local message = text_of(err)
      if message == "" then
        message = "the model call failed and the port gave no reason"
        note("the port returned nothing and no reason for it")
      end
      return finish("error", "the model call failed: " .. message,
        { where = "model", message = message, code = code_of(err) })
    end
    if n > 2 then
      note("the port answered with more than a reply and a reason; the rest was dropped")
    end

    -- What kind of reply is this?
    local calls, answer
    if type(reply) ~= "table" then
      calls, answer = nil, nil
    elseif reply.calls ~= nil and not is_list(reply.calls) then
      calls, answer = nil, nil
    elseif type(reply.calls) == "table" and #reply.calls > 0 then
      calls = reply.calls
    elseif reply.stop == "done" or reply.stop == "cut" or reply.stop == "refused" then
      answer = type(reply.text) == "string" and reply.text or ""
      if reply.stop == "cut" then
        note("the reply was cut short by a limit on the far side")
      elseif reply.stop == "refused" then
        note("the model declined to answer")
      end
    elseif type(reply.text) == "string" and reply.text ~= "" then
      answer = reply.text
    end

    if answer ~= nil then
      malformed_run = 0
      say { role = "agent", text = answer }
      result.answer = answer
      return finish("answered", "the model answered after " .. step .. " steps.")
    end

    if calls == nil then
      malformed_run = malformed_run + 1
      say {
        role = "user",
        text = "that reply could not be read. Answer with text when you are done, or ask "
          .. "for tools with a list of calls, each naming a tool and its arguments.",
      }
      if malformed_run >= malformed_limit then
        local message = "the model sent " .. malformed_run
          .. " replies in a row that could not be read"
        return finish("error", message .. ".", { where = "model", message = message })
      end
      -- Not a fifth stop reason: the budget or the limit above will end this.
    else
      malformed_run = 0

      -- Ids first, so the assistant message and the tool messages agree, and so a
      -- recorded transcript replays identically.
      local ids, taken = {}, {}
      for i = 1, #calls do
        local c = calls[i]
        local given = type(c) == "table" and c.id or nil
        local id
        if type(given) == "string" and given ~= "" and not taken[given] then
          id = given
        else
          if type(given) == "string" and given ~= "" then
            note("the reply used the call id " .. q(given) .. " twice; the second was renamed")
          end
          -- Minted; and minted again if the model already spent that exact name on an
          -- earlier call in this same reply. Two calls may never share an id, or the
          -- model cannot tell the two results apart.
          id = step .. ":" .. i
          local nth = 0
          while taken[id] do
            nth = nth + 1
            id = step .. ":" .. i .. "." .. nth
          end
        end
        taken[id] = true
        ids[i] = id
      end

      local shown = {}
      for i = 1, #calls do
        local c = calls[i]
        shown[i] = {
          id = ids[i],
          tool = (type(c) == "table" and type(c.tool) == "string" and c.tool ~= "")
                 and c.tool or "(unnamed)",
          args = type(c) == "table" and type(c.args) == "table" and c.args or {},
        }
      end
      say {
        role = "agent",
        text = type(reply.text) == "string" and reply.text or "",
        calls = shown,
      }

      local stopped_why
      for i = 1, #calls do
        local blocked
        if stopped_why ~= nil then
          blocked = { output = "the run was stopped before this call ran.", refused = true }
        elseif i > per_step then
          blocked = {
            output = "this reply asked for " .. #calls .. " tool calls, and at most "
              .. per_step .. " are honoured in one step. Ask again with fewer.",
          }
        end
        local rec = dispatch(calls[i], step, ids[i], blocked)
        if rec.stopped then
          stopped_why = rec.output
          rec.stopped = nil
        end
        result.calls[#result.calls + 1] = rec
        say {
          role = "tool", id = rec.id, tool = rec.tool,
          ok = rec.ok, text = rec.output, refused = rec.refused,
        }
        fire("result", {
          step = step, call = rec.id, tool = rec.tool, ok = rec.ok,
          output = rec.output, refused = rec.refused, asked = rec.asked, depth = depth,
        })
      end

      if stopped_why then
        return finish("refused", stopped_why)
      end
    end
  end
end

return turn
