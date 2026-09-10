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
local RESERVED = { args = true, step = true, call = true, agent = true, depth = true, note = true }

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
        if not (OPT_NUMBERS[k] or k == "id" or k == "system") then unknown[#unknown + 1] = tostring(k) end
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
    end
  end

  -- Sorted, so two hosts reading the same broken wiring read the same list.
  table.sort(p)
  return #p == 0, p
end

-- ------------------------------------------------------------------- the run

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

  local function context(args, step, call_id)
    local c = {}
    for k, v in pairs(passthrough) do c[k] = v end
    c.args = copy(args)
    c.step = step
    c.call = call_id
    c.agent = agent.name
    c.depth = depth
    c.note = function (s) note(text_of(s)) end
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
  local function dispatch(call, step, call_id, blocked)
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
    fire("step", { step = step, budget = budget, depth = depth })

    local request = {
      model = agent.model,
      system = system_text,
      messages = wire(),
      tools = spec.schema(agent),  -- fresh, so a port that edits it cannot poison step two
    }
    local reached, n, reply, err = call_counted(model, request)

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
