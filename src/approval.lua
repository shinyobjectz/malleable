-- The approval gate. Rule 4 of DESIGN.md lives here: permission belongs to the
-- harness, never to the tool, and a refusal is an ordinary answer the model reads
-- rather than an exception it cannot see.
--
-- The whole of the world arrives as arguments. This file opens nothing, names no
-- vendor, holds no module-level state, and never runs a tool body. Two gates in one
-- process cannot see each other, and neither survives the run.
--
-- Everything here fails closed: when the gate does not know, the answer is no.

local approval = {}

-- Caps. A tool name and a reason are both chosen by something outside the harness,
-- so every string copied into a decision is bounded before the model ever sees it.
local REASON_MAX        = 400
local POLICY_REASON_MAX = 200
local NAME_MAX          = 80

local TRUST      = { trusted = true, ask = true, none = true }
local TRUST_LIST = '"trusted", "ask" or "none"'

local ENTRY_KEYS = { allow = true, deny = true, tool = true, when = true, reason = true }
local OPT_KEYS   = { port = true, policy = true, trust = true }
local SCOPES     = { tool = true, args = true }

-- ------------------------------------------------------------------ small text

local function clip(s, n)
  if type(s) ~= "string" then s = tostring(s) end
  if #s <= n then return s end
  return s:sub(1, n - 3) .. "..."
end

-- A tool name inside a sentence. Bounded, and quoted so an empty or spacey name is
-- still visible in the transcript.
local function named(s)
  return '"' .. clip(s, NAME_MAX) .. '"'
end

local function text_of(v)
  if type(v) == "string" then return v end
  return clip(tostring(v), NAME_MAX)
end

-- How an unreadable answer is written back into a refusal. A table is rendered as
-- "a table" and never as its address: an address differs between runs, and a reason
-- that differs between runs cannot be asserted on or reasoned about.
local function render(v)
  local t = type(v)
  if t == "string"  then return named(v) end
  if t == "number"  then return string.format("%.17g", v) end
  if t == "boolean" then return tostring(v) end
  if t == "nil"     then return "nothing" end
  return "a " .. t
end

-- ------------------------------------------------------------------ the memory key

-- Only top-level strings, numbers and booleans take part. A table argument means no
-- key can be built, which is why a cyclic argument table cannot hang this: nothing
-- ever steps inside one.
--
-- Every piece is length-prefixed, so no two different argument sets can render to
-- one string however hostile their contents.
local function piece(s)
  return #s .. ":" .. s
end

local function render_value(v)
  local t = type(v)
  if t == "string"  then return "s" .. piece(v) end
  if t == "number"  then return "n" .. piece(string.format("%.17g", v)) end
  if t == "boolean" then return "b" .. piece(tostring(v)) end
  return nil
end

local function tool_key(tool)
  return "t" .. piece(tool) .. "|tool"
end

local function args_key(tool, args)
  local names = {}
  for k, v in pairs(args) do
    if type(k) ~= "string" then return nil end
    if render_value(v) == nil then return nil end
    names[#names + 1] = k
  end
  table.sort(names)
  local out = { "t" .. piece(tool) .. "|args" }
  for i = 1, #names do
    local k = names[i]
    out[#out + 1] = piece(k) .. "=" .. render_value(args[k])
  end
  return table.concat(out, "|")
end

-- ------------------------------------------------------------------ construction

-- Every check returns a sentence rather than raising, so approval.new can raise once,
-- at level 2, and point the message at the declaration file that got it wrong.

local function array_fault(t, what)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return what .. " is an array, and has a key that is not an array index"
    end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then return what .. " is an array with a hole at " .. i end
  end
  return nil
end

local function compile_tools(v, i)
  if v == nil then return nil, nil end
  local where = "policy entry " .. i
  if type(v) == "string" then
    if v == "" then return nil, where .. ": `tool` is a non-empty tool name" end
    return { [v] = true }, nil
  end
  if type(v) ~= "table" then
    return nil, where .. ": `tool` is a tool name, a list of tool names, or absent, got " .. type(v)
  end
  local fault = array_fault(v, where .. ": `tool`")
  if fault then return nil, fault end
  if #v == 0 then
    return nil, where .. ": `tool` is an empty list, which would read as no tools and mean every tool"
  end
  local set = {}
  for j = 1, #v do
    if type(v[j]) ~= "string" or v[j] == "" then
      return nil, where .. ": `tool` element " .. j .. " is a non-empty tool name, got " .. render(v[j])
    end
    set[v[j]] = true
  end
  return set, nil
end

local function compile_when(v, i)
  if v == nil then return nil, nil end
  local where = "policy entry " .. i
  if type(v) ~= "table" then
    return nil, where .. ": `when` is a table of argument name to matcher, got " .. type(v)
  end
  local names = {}
  for k, m in pairs(v) do
    if type(k) ~= "string" then
      return nil, where .. ": `when` keys are argument names, and one is a " .. type(k)
    end
    local t = type(m)
    if t == "string" then
      -- A malformed pattern is a defect in the declaration, so it is found now and
      -- not on the one call that happens to reach this entry.
      local ok, err = pcall(string.find, "", m)
      if not ok then
        return nil, where .. ": the pattern for " .. named(k) .. " is malformed: " .. text_of(err)
      end
    elseif t ~= "function" then
      return nil, where .. ": the matcher for " .. named(k) ..
        " is a pattern string or a function (value, args), got " .. t
    end
    names[#names + 1] = k
  end
  if #names == 0 then return nil, nil end
  table.sort(names)
  local out = {}
  for j = 1, #names do
    local k = names[j]
    local m = v[k]
    if type(m) == "string" then
      out[j] = { name = k, pattern = m }
    else
      out[j] = { name = k, fn = m }
    end
  end
  return out, nil
end

local function compile_entry(e, i)
  local where = "policy entry " .. i
  if type(e) ~= "table" then return nil, where .. " is a table, got " .. type(e) end

  for k in pairs(e) do
    if type(k) ~= "string" or not ENTRY_KEYS[k] then
      return nil, where .. " has an unknown key " .. render(k) ..
        "; a policy entry is allow or deny, with tool, when and reason"
    end
  end

  local allow, deny = e.allow == true, e.deny == true
  if allow and deny then
    return nil, where .. " is both allow and deny; exactly one of them is true"
  end
  if not allow and not deny then
    return nil, where .. " is neither allow nor deny; exactly one of them is true"
  end

  local tools, fault = compile_tools(e.tool, i)
  if fault then return nil, fault end

  local when
  when, fault = compile_when(e.when, i)
  if fault then return nil, fault end

  local reason = e.reason
  if reason ~= nil then
    if type(reason) ~= "string" then
      return nil, where .. ": `reason` is a string, got " .. type(reason)
    end
    if #reason > POLICY_REASON_MAX then
      return nil, where .. ": `reason` is longer than " .. POLICY_REASON_MAX .. " characters"
    end
  end

  return { index = i, allow = allow, tools = tools, when = when, reason = reason }, nil
end

-- The port slice, read in any of the shapes the tree wires it in. spec/port.md owns
-- the name: it calls this p.ask with request(q). The gate accepts that, a table with
-- ask = function, and a whole port table carrying either.
local function ask_of(p)
  if type(p) ~= "table" then
    return nil, "the approval port is a table, got " .. type(p)
  end
  if type(p.ask) == "function" then return p.ask, nil end
  if type(p.request) == "function" then return p.request, nil end
  if type(p.ask) == "table" and type(p.ask.request) == "function" then
    local slice = p.ask
    return function (q) return slice.request(q) end, nil
  end
  return nil, "the approval port needs ask = function (request)"
end

-- ------------------------------------------------------------------ decisions

local Gate = {}
Gate.__index = Gate

local function decide(allowed, source, reason, extra)
  if type(reason) ~= "string" or reason == "" then
    reason = allowed and "allowed" or "refused"
  end
  local d = {
    allowed    = allowed and true or false,
    source     = source,
    reason     = clip(reason, REASON_MAX),
    asked      = false,
    remembered = false,
  }
  if extra then
    for k, v in pairs(extra) do d[k] = v end
  end
  return d
end

-- true / false, plus a sentence when a matcher raised. An erroring matcher is never
-- read as "did not match": a crash inside a deny entry would open a door.
local function entry_matches(entry, tool, args)
  if entry.tools and not entry.tools[tool] then return false, nil end
  local w = entry.when
  if not w then return true, nil end
  for i = 1, #w do
    local m = w[i]
    local v = args[m.name]
    local t = type(v)
    if v == nil then return false, nil end          -- a missing argument never matches
    if m.pattern then
      if t ~= "string" and t ~= "number" and t ~= "boolean" then return false, nil end
      local ok, found = pcall(string.find, tostring(v), m.pattern)
      if not ok then return false, "its matcher raised: " .. text_of(found) end
      if not found then return false, nil end
    else
      local ok, res = pcall(m.fn, v, args)
      if not ok then return false, "its matcher raised: " .. text_of(res) end
      if not res then return false, nil end
    end
  end
  return true, nil
end

local function policy_denial(entry, extra_text)
  local why = "refused by policy " .. entry.index
  local tail = extra_text or entry.reason
  if tail then why = why .. ": " .. tail end
  return decide(false, "policy", why, { policy = entry.index })
end

-- ------------------------------------------------------------------ the memory

local function recall(gate, tool, args)
  if gate.count == 0 then return nil end
  local hit
  local keys = { tool_key(tool) }
  local ak = args_key(tool, args)
  if ak then keys[#keys + 1] = ak end
  for i = 1, #keys do
    local m = gate.memory[keys[i]]
    if m then
      -- A refusal already given beats an allow already given, whichever is narrower.
      -- Nothing in the memory may widen what another part of it closed.
      if not m.allowed then return false end
      hit = true
    end
  end
  if hit then return true end
  return nil
end

local function store(gate, key, tool, allowed, scope)
  local m = gate.memory[key]
  if m then
    m.allowed = allowed
    m.scope   = scope
    return
  end
  m = { tool = tool, allowed = allowed, scope = scope }
  gate.memory[key] = m
  gate.count = gate.count + 1
  gate.made[#gate.made + 1] = key
end

-- Reachable from a port implementation while an ask is in flight, so it answers with
-- false and a sentence and never raises: an error here would unwind through the
-- pcall around the port and be reported as a port failure, hiding the real cause.
function Gate:remember(tool, allowed, scope, args)
  if type(tool) ~= "string" or tool == "" then
    return false, "a remembered answer needs a tool name"
  end
  if type(allowed) ~= "boolean" then
    return false, "a remembered answer is true or false, got " .. type(allowed)
  end
  scope = scope or "tool"
  if not SCOPES[scope] then
    return false, "a remembered answer is scoped " .. render("tool") .. " or " .. render("args") ..
      ", got " .. render(scope)
  end
  if scope == "args" then
    if type(args) ~= "table" then
      return false, "an args-scoped answer needs the argument table to key on"
    end
    local key = args_key(tool, args)
    if not key then
      return false, "these arguments cannot be keyed: only string, number and boolean arguments are remembered"
    end
    store(self, key, tool, allowed, scope)
    return true
  end
  store(self, tool_key(tool), tool, allowed, scope)
  return true
end

function Gate:forget(tool)
  local dropped = 0
  local kept = {}
  for i = 1, #self.made do
    local key = self.made[i]
    local m = self.memory[key]
    if m and (tool == nil or m.tool == tool) then
      self.memory[key] = nil
      dropped = dropped + 1
    elseif m then
      kept[#kept + 1] = key
    end
  end
  self.made = kept
  self.count = self.count - dropped
  return dropped
end

-- A copy, entries included, so a session log can render it and a caller mutating it
-- changes nothing here.
function Gate:remembered()
  local out = {}
  for i = 1, #self.made do
    local m = self.memory[self.made[i]]
    if m then
      out[#out + 1] = { tool = m.tool, allowed = m.allowed, scope = m.scope }
    end
  end
  return out
end

-- ------------------------------------------------------------------ the answer

-- Reads every shape a port may answer in: the four words, a boolean, nil, this
-- document's { answer = ..., reason = ..., scope = ... }, and spec/port.md's
-- { allow = boolean, why = ..., remember = ... }. Returns what was said, as a table,
-- or nil and a sentence naming what came back instead.
local WORDS = { yes = true, no = false, always = true, never = false }
local KEEPS = { always = true, never = true }
local REMEMBER_AS = { once = false, tool = "tool", session = "tool", args = "args" }

local function is_word(s)
  local w = s:gsub("^%s+", ""):gsub("%s+$", ""):lower()
  if WORDS[w] ~= nil then return w end
  return nil
end

local function read_answer(v)
  local t = type(v)
  if t == "nil" then
    -- The one value that is not called nonsense: a port that answers nothing on a
    -- closed prompt is the human closing the box, and that is a plain refusal.
    return { allowed = false }
  end
  if t == "boolean" then
    return { allowed = v }
  end
  if t == "string" then
    local w = is_word(v)
    if not w then return nil, render(v) end
    return { allowed = WORDS[w], keep = KEEPS[w] or false, scope = "tool" }
  end
  if t == "table" then
    local reason = type(v.reason) == "string" and v.reason
      or (type(v.why) == "string" and v.why or nil)
    if v.answer ~= nil then
      if type(v.answer) ~= "string" then return nil, "a table whose answer is " .. render(v.answer) end
      local w = is_word(v.answer)
      if not w then return nil, "a table whose answer is " .. render(v.answer) end
      local scope = "tool"
      if v.scope ~= nil then
        if type(v.scope) ~= "string" or not SCOPES[v.scope] then
          return nil, "a table scoped " .. render(v.scope)
        end
        scope = v.scope
      end
      return { allowed = WORDS[w], keep = KEEPS[w] or false, scope = scope, reason = reason }
    end
    if type(v.allow) == "boolean" then
      -- spec/port.md's decision. `remember` is a hint, and an unreadable hint is
      -- ignored rather than honoured, because honouring it is the widening direction.
      local scope = "tool"
      local keep = false
      if type(v.remember) == "string" then
        local as = REMEMBER_AS[v.remember:lower()]
        if as then keep, scope = true, as end
      end
      return { allowed = v.allow, keep = keep, scope = scope, reason = reason }
    end
    return nil, "a table with no answer in it"
  end
  return nil, render(v)
end

-- ------------------------------------------------------------------ check

local function ask_port(gate, tool, args, call)
  if not gate.ask_fn then
    return decide(false, "port", "there is no one to ask for permission")
  end

  local keyable = args_key(tool, args) ~= nil
  local request = {
    tool         = tool,
    args         = args,
    reason       = type(call.reason) == "string" and clip(call.reason, REASON_MAX) or nil,
    trust        = gate.trust,
    deadline     = type(call.deadline) == "number" and call.deadline or nil,
    can_remember = keyable,
  }

  -- The flag is set and cleared around this one call, on both exits, so a raising
  -- port cannot wedge the gate for the rest of the run.
  gate.in_flight = true
  local ok, raw = pcall(gate.ask_fn, request)
  gate.in_flight = false

  if not ok then
    return decide(false, "port", "the approval port failed: " .. text_of(raw), { asked = true })
  end

  local answer, offending = read_answer(raw)
  if not answer then
    return decide(false, "port",
      "the approval port answered " .. offending .. ", which is not yes, no, always or never",
      { asked = true })
  end

  local why = (answer.allowed and "allowed by the operator" or "refused by the operator")
  if answer.reason then why = why .. ": " .. answer.reason end

  if not answer.keep then
    return decide(answer.allowed, "port", why, { asked = true })
  end

  local kept, fault = gate:remember(tool, answer.allowed, answer.scope, args)
  if not kept then
    -- The operator is given neither a narrower promise than they made nor a wider
    -- one than the gate can honour: the answer applies to this call and says so.
    return decide(answer.allowed, "port",
      why .. " -- this call only, because " .. fault, { asked = true })
  end
  return decide(answer.allowed, "port", why,
    { asked = true, remembered = true, scope = answer.scope })
end

local function resolve(gate, call)
  -- 1. Re-entry. A port that loops back into the gate is answered before anything
  --    else is read, and is answered no.
  if gate.in_flight then
    return decide(false, "reentry", "an approval cannot ask for approval")
  end

  -- 2. A malformed call is a harness bug, and is still a denial rather than an
  --    error, so that a broken call can never become a run tool.
  if type(call) ~= "table"
     or type(call.tool) ~= "string" or call.tool == ""
     or (call.args ~= nil and type(call.args) ~= "table") then
    return decide(false, "malformed", "an approval request needs a tool name")
  end

  local tool = call.tool
  local args = call.args or {}
  local policy = gate.policy

  -- 3. Deny policies. Nothing below this line can talk its way past one.
  for i = 1, #policy do
    local e = policy[i]
    if not e.allow then
      local hit, fault = entry_matches(e, tool, args)
      if fault then return policy_denial(e, fault) end
      if hit then return policy_denial(e) end
    end
  end

  -- 4. What the operator already said this run.
  local remembered = recall(gate, tool, args)
  if remembered == false then
    return decide(false, "memory", "refused for the rest of this run")
  elseif remembered == true then
    return decide(true, "memory", "allowed for the rest of this run")
  end

  -- 5. Allow policies.
  for i = 1, #policy do
    local e = policy[i]
    if e.allow then
      local hit, fault = entry_matches(e, tool, args)
      if fault then return policy_denial(e, fault) end
      if hit then
        return decide(true, "policy", "allowed by policy " .. e.index, { policy = e.index })
      end
    end
  end

  -- 6. A vouched-for workspace. Step 3 has already run, so a deny still holds.
  if gate.trust == "trusted" then
    return decide(true, "trust", "the workspace is trusted")
  end

  -- 7. The ordinary path for the ordinary tool. Read as truthiness rather than as
  --    `== true`, so that a host handing over an `ask` that is not a boolean at all
  --    falls to the ask and not past it. Every unhandled shape leans towards asking.
  if not call.ask and gate.trust ~= "none" then
    return decide(true, "flag", "the tool " .. named(tool) .. " does not ask")
  end

  -- 8. Put it to the human.
  return ask_port(gate, tool, args, call)
end

-- Never raises, never returns nil: every path out is a decision table, and the
-- pcall is the last resort that keeps that true even for an argument table that
-- misbehaves when it is read.
function Gate:check(call)
  local ok, d = pcall(resolve, self, call)
  if ok and type(d) == "table" then return d end
  self.in_flight = false
  return decide(false, "malformed",
    "the approval gate could not read this request: " .. text_of(d))
end

-- ------------------------------------------------------------------ new

-- The one entry point that raises. A malformed policy is a defect in a declaration
-- file, and it belongs to the moment that file is loaded, not to the moment two
-- minutes later when a tool is about to touch the disk.
function approval.new(opts)
  if opts == nil then opts = {} end
  if type(opts) ~= "table" then error("approval.new takes a table", 2) end

  -- A misspelt option is the same class of defect a misspelt policy key is: the
  -- gate would build, hold no policies or no port, and quietly permit what the
  -- declaration meant to stop. It is refused here rather than discovered later.
  for k in pairs(opts) do
    if type(k) ~= "string" or not OPT_KEYS[k] then
      error("approval.new has an unknown option " .. render(k) ..
        "; it takes port, policy and trust", 2)
    end
  end

  local trust = opts.trust
  if trust == nil then
    trust = "ask"
  elseif type(trust) ~= "string" or not TRUST[trust] then
    error("the workspace's trust is " .. TRUST_LIST .. ", got " .. render(trust), 2)
  end

  local given = opts.policy
  local policy = {}
  if given ~= nil then
    if type(given) ~= "table" then
      error("`policy` is an array of policy entries, got " .. type(given), 2)
    end
    local fault = array_fault(given, "`policy`")
    if fault then error(fault, 2) end
    for i = 1, #given do
      local entry
      entry, fault = compile_entry(given[i], i)
      if fault then error(fault, 2) end
      policy[i] = entry
    end
  end

  local ask
  if opts.port ~= nil then
    local fault
    ask, fault = ask_of(opts.port)
    if fault then error(fault, 2) end
  end

  -- The port function is held under a name no method shares, so `gate:ask(...)` is a
  -- mistake that cannot silently reach the operator with the gate as its request.
  return setmetatable({
    ask_fn    = ask,
    trust     = trust,
    policy    = policy,
    memory    = {},
    made      = {},
    count     = 0,
    in_flight = false,
  }, Gate)
end

approval.REASON_MAX        = REASON_MAX
approval.POLICY_REASON_MAX = POLICY_REASON_MAX

return approval
