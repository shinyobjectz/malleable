-- compaction — context budget and compaction.
--
-- Three questions about one list of messages: how big is it, is that too big, and
-- which stretch of it can be folded into one short note so the run continues.
--
-- Rule 1 holds as in turn.lua: no provider, transport, clock or filesystem is named. The
-- one thing it needs from the world is a model, from the port table the host hands in.

local compaction = {}

-- The estimator's constants. An estimate is not a token count; it is a deterministic
-- approximation, and these three numbers are the whole of its tuning.
local FRAME     = 4        -- flat units for a message's role framing
local MAX_DEPTH = 12       -- deeper than this and the walk stops, reporting a floor
local MAX_NODES = 100000   -- likewise for sheer size

local function fail(fmt, ...)
  error(string.format(fmt, ...), 3)
end

-- The estimate

local function walk(v, depth, st)
  st.nodes = st.nodes + 1
  if st.nodes > MAX_NODES then
    st.truncated = true
    return 0
  end

  if v == nil then return 0 end
  local t = type(v)
  if t == "string" then return math.ceil(#v / 4) + 1 end
  if t == "number" or t == "boolean" then return 2 end
  if t ~= "table" then return 1 end   -- a function, a userdata, a thread: a host may hang one on a message

  if st.open[v] then
    -- already counted on this path: a cycle. Contributes nothing, and the caller is
    -- told the number it got back is a floor.
    st.truncated = true
    return 0
  end
  if depth >= MAX_DEPTH then
    st.truncated = true
    return 0
  end
  if depth > st.depth then st.depth = depth end

  st.open[v] = true
  local n = 0
  for k, val in pairs(v) do
    n = n + 2 + walk(k, depth + 1, st) + walk(val, depth + 1, st)
    if st.nodes > MAX_NODES then break end
  end
  st.open[v] = nil
  return n
end

function compaction.estimate(value)
  local st = { open = {}, nodes = 0, depth = 0, truncated = false }
  local n = walk(value, 0, st)
  return n, { truncated = st.truncated, depth = st.depth, nodes = st.nodes }
end

-- A message costs its fields plus a flat frame for the role.
local function message_estimate(m)
  local n, info = compaction.estimate(m)
  return n + FRAME, info.truncated
end

-- Limits

compaction.defaults = { window = 128000, headroom = 0.75, target = 0.5, keep_recent = 6, attempts = 2 }

-- `model` is not a budget, so it is not a default; it is the model id the digest call
-- carries, because spec/port.md's model port requires one on every request.
local KNOWN = {
  window = true, headroom = true, target = true, keep_recent = true, attempts = true,
  model = true,
}

local function whole(v)
  return type(v) == "number" and v == math.floor(v) and v == v and v ~= math.huge and v ~= -math.huge
end

local function resolve(limits)
  local d = compaction.defaults
  local out = {
    window = d.window, headroom = d.headroom, target = d.target,
    keep_recent = d.keep_recent, attempts = d.attempts, model = nil,
  }
  if limits ~= nil then
    if type(limits) ~= "table" then
      fail("limits is a table of window / headroom / target / keep_recent / attempts, got %s", type(limits))
    end
    for k, v in pairs(limits) do
      if not KNOWN[k] then fail("limits has no key %q", tostring(k)) end
      out[k] = v
    end
  end

  if type(out.window) ~= "number" or out.window <= 0 then
    fail("limits.window is a number above zero, got %s", tostring(out.window))
  end
  if type(out.headroom) ~= "number" or out.headroom <= 0 or out.headroom > 1 then
    fail("limits.headroom is a number in (0, 1], got %s", tostring(out.headroom))
  end
  if type(out.target) ~= "number" or out.target <= 0 or out.target > 1 then
    fail("limits.target is a number in (0, 1], got %s", tostring(out.target))
  end
  if out.target > out.headroom then
    fail("limits.target (%s) must be at or below limits.headroom (%s)", tostring(out.target), tostring(out.headroom))
  end
  if not whole(out.keep_recent) or out.keep_recent < 0 then
    fail("limits.keep_recent is a whole number at or above zero, got %s", tostring(out.keep_recent))
  end
  if not whole(out.attempts) or out.attempts < 1 then
    fail("limits.attempts is a whole number at or above one, got %s", tostring(out.attempts))
  end
  if out.model ~= nil and type(out.model) ~= "string" then
    fail("limits.model is the model id, a string, got %s", type(out.model))
  end

  out.limit = math.floor(out.window * out.headroom)
  out.goal  = math.floor(out.window * out.target)
  return out
end

-- The history and its protections

-- Both vocabularies for the model's own turn are read: spec/port.md calls it "agent",
-- the wider world calls it "assistant". A harness that used one and a compaction that
-- knew only the other would quietly never fold anything.
local function is_model_turn(m)
  return m.role == "assistant" or m.role == "agent"
end

local function is_tool_result(m)
  return m.role == "tool"
end

-- The call a tool result answers: `call_id` here, `id` in spec/port.md's message shape.
local function answers(m)
  local v = m.call_id
  if v == nil then v = m.id end
  if type(v) == "string" then return v end
  return nil
end

local function check_history(h)
  if type(h) ~= "table" then
    fail("history is a list of messages, got %s", type(h))
  end
  local count = 0
  for k in pairs(h) do
    if not whole(k) or k < 1 then
      fail("history is a list indexed from 1; it has the key %s", tostring(k))
    end
    count = count + 1
  end
  for i = 1, count do
    if h[i] == nil then fail("history has a hole at index %d", i) end
    if type(h[i]) ~= "table" then fail("history entry %d is a %s, not a message", i, type(h[i])) end
  end
  return count
end

-- The four protections, in the order the contract states them.
local function protections(h, n, keep_recent)
  local last_turn = 0
  for i = n, 1, -1 do
    if is_model_turn(h[i]) then last_turn = i; break end
  end

  local prot = {}
  for i = 1, n do
    local m = h[i]
    local p = false
    if m.role == "system" then p = true
    elseif m.pin == true then p = true
    elseif i > n - keep_recent then p = true
    elseif last_turn == 0 or i >= last_turn then p = true   -- nothing since the last model turn has been seen
    end
    prot[i] = p
  end
  return prot, last_turn
end

-- check

local function measure(h, lim)
  local n = check_history(h)
  local prot = protections(h, n, lim.keep_recent)

  local each, total, floor, truncated, biggest = {}, 0, 0, false, 0
  for i = 1, n do
    local e, cut = message_estimate(h[i])
    each[i] = e
    total = total + e
    if cut then truncated = true end
    if e > biggest then biggest = e end
    if prot[i] then floor = floor + e end
  end

  local protected_count = 0
  for i = 1, n do
    if prot[i] then protected_count = protected_count + 1 end
  end

  local report = {
    messages  = n,
    estimate  = total,
    window    = lim.window,
    limit     = lim.limit,
    goal      = lim.goal,
    over      = total > lim.limit,
    protected = protected_count,
    foldable  = n - protected_count,
    floor     = floor,
    truncated = truncated,
  }
  return report, prot, each, biggest
end

function compaction.check(history, limits)
  local lim = resolve(limits)
  local report = measure(history, lim)
  return report
end

-- plan

-- The message a fold leaves behind, with the digest text it will carry.
local function digest_message(text, count)
  return { role = "user", digest = true, text = text, folded = count }
end

-- Would folding from..to leave a tool result behind whose call went with it?
local function orphans(h, n, from, to)
  local ids = {}
  for i = from, to do
    local calls = h[i].calls
    if type(calls) == "table" then
      for j = 1, #calls do
        local c = calls[j]
        if type(c) == "table" and type(c.id) == "string" then ids[c.id] = true end
      end
    end
  end
  if next(ids) == nil then return false end
  for j = to + 1, n do
    local m = h[j]
    if is_tool_result(m) then
      local a = answers(m)
      if a ~= nil and ids[a] then return true end
    end
  end
  return false
end

local function span_of(h, n, each, total, goal, from, run_end)
  local to = from
  local removed = each[from]
  while true do
    local placeholder = message_estimate(digest_message("", to - from + 1))
    local after = total - removed + placeholder
    if after <= goal then break end
    if to + 1 > run_end then break end
    to = to + 1
    removed = removed + each[to]
  end

  -- The boundary rule: never split a call from its result.
  while to > from and orphans(h, n, from, to) do
    removed = removed - each[to]
    to = to - 1
  end
  if orphans(h, n, from, to) then return nil end   -- even alone it would orphan

  local count = to - from + 1
  local placeholder = message_estimate(digest_message("", count))
  return {
    from = from, to = to, count = count,
    removed = removed,
    after = total - removed + placeholder,
  }
end

local function plan_from(h, lim)
  local report, prot, each, biggest = measure(h, lim)
  if not report.over then return nil, "not over budget", report end
  if biggest > lim.window then
    return nil, "a single message is larger than the window", report
  end
  if report.foldable == 0 then return nil, "nothing to fold", report end

  local n = report.messages
  local i = 1
  while i <= n do
    if prot[i] then
      i = i + 1
    else
      local run_end = i
      while run_end + 1 <= n and not prot[run_end + 1] do run_end = run_end + 1 end
      local s = span_of(h, n, each, report.estimate, lim.goal, i, run_end)
      if s and s.count >= 2 then
        local messages = {}
        for j = s.from, s.to do messages[#messages + 1] = h[j] end
        s.messages = messages
        s.report = report
        s.total = n
        return s, nil, report
      end
      i = run_end + 1
    end
  end

  -- Something was foldable, but no contiguous run of two survived the boundary rule.
  return nil, "one message to fold", report
end

function compaction.plan(history, limits)
  local lim = resolve(limits)
  local p, why = plan_from(history, lim)
  if p then return p end
  return nil, why
end

-- prompt

local function check_plan(p)
  if type(p) ~= "table" then fail("plan is the table compaction.plan returned, got %s", type(p)) end
  if not whole(p.from) or not whole(p.to) or not whole(p.count) then
    fail("plan needs whole from / to / count")
  end
  if type(p.messages) ~= "table" or #p.messages ~= p.count then
    fail("plan.messages is the span, %d messages long", p.count)
  end
  if type(p.removed) ~= "number" or type(p.after) ~= "number" then
    fail("plan needs numeric removed and after")
  end
end

-- A string renders as itself; anything else renders as its type in angle brackets, so
-- no address ever reaches the model and no function is ever handled.
local function show(v)
  if type(v) == "string" then return v end
  if v == nil then return "" end
  return "<" .. type(v) .. ">"
end

-- How many words the digest may run to: what is left of the goal once the folded
-- history is accounted for, never more than half of what the digest replaces, and
-- never so few that the instruction is impossible to obey. Monotone in the goal — a
-- tighter goal never asks for more words.
local function word_cap(plan, goal)
  local allowance = goal - plan.after
  if allowance < 0 then allowance = 0 end
  local room = math.floor(plan.removed / 2)
  if allowance < room then room = allowance end
  local words = math.floor(room / 1.5)
  if words < 20 then words = 20 end
  if words > 800 then words = 800 end
  return words
end

local function render(plan)
  local out = {}
  for i = 1, plan.count do
    local m = plan.messages[i]
    local head = show(m.role)
    if head == "" then head = "<nil>" end
    out[#out + 1] = "[" .. head .. "]"
    local body = show(m.text)
    if body ~= "" then out[#out + 1] = body end
    local calls = m.calls
    if type(calls) == "table" then
      for j = 1, #calls do
        local c = calls[j]
        if type(c) == "table" then
          out[#out + 1] = "  called " .. show(c.tool) .. " (" .. show(c.id) .. ")"
        else
          out[#out + 1] = "  called " .. show(c)
        end
      end
    end
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

local INSTRUCTION =
  "You are summarising part of a conversation so the rest of it can continue in a " ..
  "smaller context. Write one factual digest of the messages below. Keep three " ..
  "things and drop everything else: the decisions that were made, the files and " ..
  "identifiers that were touched, and the work still outstanding. Write plain prose " ..
  "in the past tense, no headings, no preamble, no offer to help. Do not invent " ..
  "anything that is not in the messages. Stay under %d words."

function compaction.prompt(plan, limits)
  check_plan(plan)
  local goal
  if limits ~= nil then
    goal = resolve(limits).goal
  elseif type(plan.report) == "table" and type(plan.report.goal) == "number" then
    goal = plan.report.goal
  else
    goal = resolve(nil).goal
  end
  local words = word_cap(plan, goal)
  return {
    { role = "system", text = string.format(INSTRUCTION, words) },
    { role = "user",   text = render(plan) },
  }, words
end

-- apply

function compaction.apply(history, plan, digest)
  local n = check_history(history)
  check_plan(plan)
  if type(digest) ~= "string" then
    fail("apply takes the digest as a string, got %s", type(digest))
  end
  if plan.total ~= nil and plan.total ~= n then
    fail("this plan was made from a history of %d messages, not %d", plan.total, n)
  end
  if history[plan.from] ~= plan.messages[1] or history[plan.to] ~= plan.messages[plan.count] then
    fail("this plan was made from a different history: the span at %d..%d has moved", plan.from, plan.to)
  end

  if digest:match("^%s*$") then return nil, "the digest is empty" end

  local m = digest_message(digest, plan.count)
  if message_estimate(m) >= plan.removed then
    return nil, "the digest is not smaller than what it replaces"
  end

  local out = {}
  for i = 1, plan.from - 1 do out[#out + 1] = history[i] end
  out[#out + 1] = m
  for i = plan.to + 1, n do out[#out + 1] = history[i] end
  return out
end

-- compact

local function port_call(port)
  if type(port) ~= "table" then
    fail("compact needs a port with model.call, got %s", type(port))
  end
  local model = port.model
  if type(model) ~= "table" then
    fail("compact needs a port with model.call; port.model is %s", type(model))
  end
  if type(model.call) == "function" then return model.call, true end
  if type(model.complete) == "function" then return model.complete, false end
  fail("compact needs a port with model.call")
end

-- What a raise says, with Lua's own location off the front: `error("x")` prepends
-- "<chunk>:<line>: " and the chunk is a host absolute path, which port.md forbids showing
-- a model. Only a prefix that looks like a source location is trimmed, so a message that
-- merely contains a colon survives whole.
local function raised_message(v)
  if type(v) ~= "string" then return show(v) end
  local where, rest = v:match("^(.-):%d+: (.*)$")
  if where ~= nil and rest ~= "" and
     (where:find("/", 1, true) or where:find("\\", 1, true) or where:sub(-4) == ".lua") then
    return rest
  end
  return v
end

local function failed(report, why)
  local out = {}
  for k, v in pairs(report) do out[k] = v end
  out.compacted = false
  out.why = why
  return out
end

function compaction.compact(port, history, limits)
  local call, needs_id = port_call(port)
  local lim = resolve(limits)

  local id = lim.model
  if id == nil and type(port.model.id) == "string" then id = port.model.id end
  if needs_id and id == nil then
    fail("compact needs the model id: pass limits.model or set port.model.id")
  end

  local plan, why, report = plan_from(history, lim)
  if not plan then return history, failed(report, why) end

  local messages, words = compaction.prompt(plan, limits)
  local request = { model = id, messages = messages, max_output = words * 2 }
  -- spec/port.md carries the system prompt beside the messages rather than inside them.
  if messages[1].role == "system" then
    request.system = messages[1].text
    request.messages = { messages[2] }
  end

  local last = "the model could not be reached: no reply"
  for _ = 1, lim.attempts do
    local ok, reply, err = pcall(call, request)
    if not ok then
      -- A port that raises is still the world failing from here; the run keeps going.
      last = "the model could not be reached: " .. raised_message(reply)
      if last == "the model could not be reached: " then
        last = "the model could not be reached: the call raised"
      end
    elseif reply == nil then
      local code, message
      if type(err) == "table" then
        code = err.code or err.kind
        message = err.message
      end
      if code == "timeout" then
        last = "the digest timed out"
      elseif code == "refused" then
        return history, failed(report, "the model would not write the digest")
      else
        last = "the model could not be reached: " .. (type(message) == "string" and message or "the call failed")
      end
    elseif type(reply) ~= "table" then
      last = "the model could not be reached: the port answered with a " .. type(reply)
    elseif reply.stop == "refused" then
      return history, failed(report, "the model would not write the digest")
    else
      local text = reply.text
      if type(text) ~= "string" then text = "" end
      local folded, refusal = compaction.apply(history, plan, text)
      if folded then
        local after = measure(folded, lim)
        after.compacted = true
        after.folded = plan.count
        return folded, after
      end
      if refusal == "the digest is not smaller than what it replaces" then
        return history, failed(report, refusal)   -- a model that ignored the ceiling once will ignore it again
      end
      last = refusal
    end
  end

  return history, failed(report, last)
end

return compaction
