-- subagent — a tool that runs a whole agent and hands back one result.
--
-- A tool body sometimes needs an agent rather than a function: a job with its own
-- instructions, its own small tool set and its own transcript, run to completion,
-- whose answer comes back as one tool result the parent model reads.
--
-- Two things live here and nowhere else in the tree:
--
--   * the depth and step accounting that bounds a whole tree of runs, held in a
--     ledger the caller owns, so two trees through one loaded copy of this module
--     cannot see each other;
--   * the rendering that turns a finished child into the sentence its parent reads.
--
-- What does NOT live here: a port call of any kind. This file never reads a file,
-- never asks a person, never reads a clock and never calls a model. It hands a port
-- table to turn.run and reads the result. The one module it requires is turn.

local turn = (function ()
  local ok, m = pcall(require, "turn")
  if ok then return m end
  return require("src.turn")
end)()

local subagent = {}

-- ------------------------------------------------------------------- constants

local DEFAULTS = {
  budget     = 12,
  max_budget = 24,
  depth      = 3,
  children   = 8,
  steps      = 64,
  include    = "answer",
  max_chars  = 4000,
  line_chars = 200,
}

local function fixed(t)
  return setmetatable(t, {
    __newindex = function () error("this list is fixed: it is the whole documented set", 2) end,
    __metatable = "fixed",
  })
end

-- The five outcomes, forever. Four are turn's own and mean what turn says they mean;
-- the fifth means the child never started.
subagent.stops = fixed { "answered", "budget", "refused", "error", "blocked" }

-- The seven reasons a child never started.
subagent.blocks = fixed {
  "malformed", "unknown", "declaration", "ungranted", "depth", "children", "steps",
}

local INCLUDES = { answer = true, readout = true, none = true }

-- ---------------------------------------------------------------- small helpers

local function fail(level, what, ...)
  error(string.format(what, ...), level + 1)
end

local function copy(t)
  local out = {}
  if type(t) == "table" then
    for k, v in pairs(t) do out[k] = v end
  end
  return out
end

local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

local function q(s)
  return '"' .. tostring(s) .. '"'
end

-- One line of prose for a value that arrived from the world: a raised string, a port's
-- error table, whatever a broken host hands back. Deterministic on every input, so a
-- run reads the same twice -- no address of a table ever appears.
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

-- A short, sorted, deterministic rendering of one argument value, for a readout line.
local function brief(v)
  local t = type(v)
  if t == "string" then return q(v) end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "nil" then return "nothing" end
  if t == "table" then return "a table of " .. count(v) .. " entries" end
  return "a " .. t
end

-- Reading a field off a table a host built, without a raising metatable being able to
-- end a run that was otherwise going fine.
local function peek(t, k)
  if type(t) ~= "table" then return nil end
  local ok, v = pcall(function () return t[k] end)
  if ok then return v end
  return nil
end

local function sorted_keys(t)
  local out = {}
  if type(t) == "table" then
    for k in pairs(t) do out[#out + 1] = tostring(k) end
  end
  table.sort(out)
  return out
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function whole(v, low)
  return type(v) == "number" and v == math.floor(v) and v >= low
end

local function sentence(s)
  s = trim(tostring(s))
  if s == "" then return "" end
  local last = s:sub(-1)
  if last == "." or last == "!" or last == "?" then return s end
  return s .. "."
end

-- Truncation is stated and keeps both ends: a conclusion usually sits at the end of an
-- answer, and a silently head-truncated answer loses it. `join` is what the marker sits
-- on: a rendered body puts it on its own line, and a readout line cannot, because 4.6
-- promises one line per message and a marker with newlines in it would make three.
local function clip(s, max, join)
  if type(s) ~= "string" then return "" end
  if max == nil or max < 1 then max = DEFAULTS.max_chars end
  if #s <= max then return s end
  if join == nil then join = "\n" end
  local head = math.ceil(max * 0.6)
  local tail = max - head
  local dropped = #s - max
  local kept_tail = tail > 0 and s:sub(#s - tail + 1) or ""
  return s:sub(1, head)
    .. join .. "[... " .. dropped .. " characters dropped ...]" .. join
    .. kept_tail
end

-- One readout line, truncated the same way and by the same numbers, but never broken
-- into more than the one line it is.
local function clip_line(s, max)
  return clip(s, max, " ")
end

-- ------------------------------------------------------------------- the ledger

local function ledger_why(kind, depth, children, steps, want_depth)
  if kind == "depth" then
    return "the tree is already " .. depth .. " deep, which is as deep as it may go, and this child would be "
      .. want_depth .. " deep."
  end
  if kind == "children" then
    return "the tree's spawn limit of " .. children .. " is already spent."
  end
  return "the tree's step pool of " .. steps .. " is spent."
end

function subagent.ledger(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then
    fail(2, "subagent.ledger takes a table, got %s", type(cfg))
  end
  local unknown = {}
  for k in pairs(cfg) do
    if k ~= "depth" and k ~= "children" and k ~= "steps" then unknown[#unknown + 1] = tostring(k) end
  end
  table.sort(unknown)
  if #unknown > 0 then
    fail(2, "subagent.ledger has no field %s", q(unknown[1]))
  end
  if cfg.depth ~= nil and not whole(cfg.depth, 0) then
    fail(2, "subagent.ledger: `depth` is a whole number of levels, at least 0")
  end
  if cfg.children ~= nil and not whole(cfg.children, 1) then
    fail(2, "subagent.ledger: `children` is a whole number of children, at least 1")
  end
  if cfg.steps ~= nil and not whole(cfg.steps, 1) then
    fail(2, "subagent.ledger: `steps` is a whole number of steps, at least 1")
  end

  local max_depth = cfg.depth or DEFAULTS.depth
  local children  = cfg.children or DEFAULTS.children
  local steps     = cfg.steps or DEFAULTS.steps

  local L = {
    steps_left    = steps,
    children_left = children,
    spawned       = 0,
    max_depth     = max_depth,
  }

  -- Both call forms work: ledger:open(want) and ledger.open(want).
  local function only(a, b, c)
    if a == L then return b, c end
    return a, b
  end

  -- The reservation is the point. Steps leave the pool BEFORE the child runs, so
  -- eight siblings cannot each be promised a budget the tree cannot pay.
  function L.open(a, b)
    local want = only(a, b)
    if type(want) ~= "table" then
      fail(2, "ledger:open takes { depth = n, budget = n, id = s }, got %s", type(want))
    end
    local d = type(want.depth) == "number" and want.depth or 1
    local b_want = type(want.budget) == "number" and math.floor(want.budget) or 1
    if b_want < 1 then b_want = 1 end

    if d > L.max_depth then
      return nil, "depth", ledger_why("depth", L.max_depth, children, steps, d)
    end
    if L.children_left <= 0 then
      return nil, "children", ledger_why("children", L.max_depth, children, steps, d)
    end
    if L.steps_left <= 0 then
      return nil, "steps", ledger_why("steps", L.max_depth, children, steps, d)
    end

    local reserve = math.min(b_want, L.steps_left)
    L.steps_left = L.steps_left - reserve
    L.children_left = L.children_left - 1
    L.spawned = L.spawned + 1

    return {
      id      = "s" .. L.spawned,
      depth   = d,
      budget  = reserve,
      clamped = reserve < b_want,
      ledger  = L,
      open    = true,
    }
  end

  -- A double close refunds nothing: the alternative would let a buggy caller mint
  -- steps and turn the one real limit in this file into a suggestion.
  function L.close(a, b, c)
    local permit, spent = only(a, b, c)
    if type(permit) ~= "table" then return 0 end
    if permit.open ~= true then return 0 end
    permit.open = false
    local held = type(permit.budget) == "number" and permit.budget or 0
    if type(spent) ~= "number" then spent = 0 end
    if spent < 0 then spent = 0 end
    if spent > held then spent = held end
    local refunded = held - spent
    L.steps_left = L.steps_left + refunded
    return refunded
  end

  -- A fresh flat copy, never the ledger itself, so a caller cannot write the pool by
  -- writing what it read.
  function L.snapshot()
    return {
      steps_left    = L.steps_left,
      children_left = L.children_left,
      spawned       = L.spawned,
      max_depth     = L.max_depth,
    }
  end

  return L
end

local function is_ledger(v)
  return type(v) == "table"
     and type(v.open) == "function"
     and type(v.close) == "function"
     and type(v.snapshot) == "function"
end

-- The shape test above is all a declaration may do (rule 2: a declaration runs nothing).
-- A run may do more, and must: a ledger reached this module from a caller's hand or from
-- a port, and 4.2 promises subagent.run raises for nothing but a non-table ctx or req.
-- Reading a snapshot is the cheapest proof that charging this table will not raise.
local function usable_ledger(v)
  if not is_ledger(v) then return false end
  local ok, s = pcall(v.snapshot)
  return ok and type(s) == "table"
end

-- -------------------------------------------------------------------- the frame

-- The permit's travelling half: what a grandchild finds on its port, and what makes
-- recursion accounted rather than merely deep.
function subagent.frame(ctx)
  local f = peek(ctx, "subagent")
  if type(f) ~= "table" then return nil end
  if not is_ledger(peek(f, "ledger")) then return nil end
  if type(peek(f, "depth")) ~= "number" then return nil end
  return f
end

-- ------------------------------------------------------------------ the readout

local function role_line(m)
  local role = type(m.role) == "string" and m.role or "?"
  local text = type(m.text) == "string" and m.text or ""
  if role == "tool" then
    local how = m.ok and "ok" or (m.refused and "refused" or "failed")
    return "tool " .. tostring(m.tool) .. " (" .. tostring(m.id) .. ") " .. how .. ": " .. q(text)
  end
  local line = role .. ": " .. q(text)
  if type(m.calls) == "table" and #m.calls > 0 then
    local names = {}
    for i = 1, #m.calls do
      local c = m.calls[i]
      names[i] = type(c) == "table" and tostring(c.tool) or "?"
    end
    line = line .. " calls: " .. table.concat(names, ", ")
  end
  return line
end

local function record_line(rec)
  local args = {}
  local keys = sorted_keys(rec.args)
  for i = 1, #keys do
    args[i] = keys[i] .. " = " .. brief(peek(rec.args, keys[i]))
  end
  local how = rec.ok and "ok" or (rec.refused and "refused" or "failed")
  return "call " .. tostring(rec.id) .. " " .. tostring(rec.tool)
    .. "(" .. table.concat(args, ", ") .. ") -> " .. how
end

function subagent.readout(result, opts)
  if type(result) ~= "table" then
    fail(2, "subagent.readout: result is a table, and arrived as %s", type(result))
  end
  local max = DEFAULTS.line_chars
  if type(opts) == "table" and type(opts.max_chars) == "number" and opts.max_chars >= 1 then
    max = math.floor(opts.max_chars)
  end

  local out = {}
  local function line(s)
    out[#out + 1] = clip_line(s, max)
  end

  local who = tostring(peek(result, "agent") or "(none)")
  local label = peek(result, "label")
  if type(label) == "string" and label ~= "" then who = who .. " (" .. label .. ")" end

  if peek(result, "stop") == "blocked" then
    local prompt = peek(result, "prompt")
    line("asked: " .. who .. " at depth " .. tostring(peek(result, "depth") or 0)
      .. (type(prompt) == "string" and (" -- " .. q(prompt)) or ""))
    line("blocked: " .. tostring(peek(result, "blocked") or "?")
      .. " - " .. tostring(peek(result, "reason") or ""))
    return out
  end

  local t = peek(result, "transcript")
  if type(t) == "table" then
    for i = 1, #t do
      local m = t[i]
      if type(m) == "table" then line(role_line(m)) end
    end
  end
  local calls = peek(result, "calls")
  if type(calls) == "table" then
    for i = 1, #calls do
      local rec = calls[i]
      if type(rec) == "table" then line(record_line(rec)) end
    end
  end
  line("stop: " .. tostring(peek(result, "stop") or "?")
    .. " - " .. tostring(peek(result, "reason") or ""))
  return out
end

-- ---------------------------------------------------------------- the rendering

local function last_words(result)
  local t = peek(result, "transcript")
  if type(t) ~= "table" then return nil end
  for i = #t, 1, -1 do
    local m = t[i]
    if type(m) == "table" and m.role == "agent" and type(m.text) == "string" and m.text ~= "" then
      return m.text
    end
  end
  return nil
end

-- The id a rendered line carries: the permit's own short id, not the whole path.
local function short_id(id)
  if type(id) ~= "string" or id == "" then return nil end
  local tail = id:match("([^/]+)$")
  return tail
end

local function first_line(result)
  local name = tostring(peek(result, "agent") or "(none)")
  local stop = peek(result, "stop")
  local label = peek(result, "label")
  local steps = peek(result, "steps") or 0
  local budget = peek(result, "budget") or 0
  local reason = tostring(peek(result, "reason") or "")

  local inside = {}
  if stop ~= "blocked" then
    local sid = short_id(peek(result, "id"))
    if sid then inside[#inside + 1] = sid end
  end
  if type(label) == "string" and label ~= "" then inside[#inside + 1] = label end

  local head = "subagent " .. name
  if #inside > 0 then head = head .. " (" .. table.concat(inside, ", ") .. ")" end

  if stop == "answered" then
    return head .. " answered in " .. steps .. " of " .. budget .. " steps."
  end
  if stop == "budget" then
    return head .. " spent its budget of " .. budget .. " steps without answering."
  end
  if stop == "refused" then
    return sentence(head .. " was stopped by the person after " .. steps .. " steps: " .. reason)
  end
  if stop == "error" then
    local err = peek(result, "err")
    local detail
    if type(err) == "table" and err.where == "model" then
      detail = "the model port said " .. q(text_of(err.message))
    elseif type(err) == "table" and type(err.message) == "string" and err.message ~= "" then
      detail = err.message
    else
      detail = reason
    end
    return sentence(head .. " failed after " .. steps .. " steps: " .. detail)
  end
  if stop == "blocked" then
    return sentence(head .. " did not run: " .. reason)
  end
  if reason == "" then return head .. " ended, and said nothing about why." end
  return sentence(head .. " ended: " .. reason)
end

function subagent.render(result, opts)
  if type(result) ~= "table" then
    fail(2, "subagent.render: result is a table, and arrived as %s", type(result))
  end
  local include, max_chars = DEFAULTS.include, DEFAULTS.max_chars
  if type(opts) == "table" then
    if INCLUDES[opts.include] then include = opts.include end
    if type(opts.max_chars) == "number" and opts.max_chars >= 200 then
      max_chars = math.floor(opts.max_chars)
    end
  end

  local head = first_line(result)
  if include == "none" then return head end

  if include == "readout" then
    local lines = subagent.readout(result)
    if #lines == 0 then return head end
    return head .. "\n\n" .. clip(table.concat(lines, "\n"), max_chars)
  end

  local stop = peek(result, "stop")
  if stop == "answered" then
    local answer = peek(result, "answer")
    -- An empty answer is said, not shown: a blank body would read to the parent
    -- model as a successful empty result, and it is not one.
    if type(answer) ~= "string" or trim(answer) == "" then
      return head .. "\nIt answered with no text."
    end
    return head .. "\n\n" .. clip(answer, max_chars)
  end

  if stop == "budget" then
    local words = last_words(result)
    if words then
      return head .. "\n\nIt did not finish. Its last words were:\n\n" .. clip(words, max_chars)
    end
    return head .. "\nIt said nothing before the budget ran out."
  end

  return head
end

-- --------------------------------------------------------------------- the run

local RUN_KEYS = {
  agent = true, prompt = true, budget = true, label = true, world = true,
  ledger = true, depth = true, agents = true, pick = true, max_budget = true,
  tree = true, id = true,
}

-- 4.4: the root is what keeps ids flat and stable at every depth, so the fourth child
-- of a tree is root/s4 whether it was spawned at depth 1 or depth 3. A frame therefore
-- outranks a declaration's own `id`, exactly as its ledger outranks cfg.ledger: the two
-- halves of a permit must not come from different trees.
local function root_of(req, frame, ctx)
  if frame then
    local r = peek(frame, "root")
    if type(r) == "string" and r ~= "" then return r end
  end
  local given = peek(req, "id")
  if type(given) == "string" and given ~= "" then return given end
  local a = peek(ctx, "agent")
  if type(a) == "string" and a ~= "" then return a end
  if type(a) == "table" then
    local n = peek(a, "name")
    if type(n) == "string" and n ~= "" then return n end
  end
  return "agent"
end

function subagent.run(ctx, req)
  if type(ctx) ~= "table" then
    fail(2, "subagent.run: ctx is the tool body's context table, and arrived as %s", type(ctx))
  end
  if type(req) ~= "table" then
    fail(2, "subagent.run: req is a table, and arrived as %s", type(req))
  end

  local notes = {}
  local frame = subagent.frame(ctx)
  local root = root_of(req, frame, ctx)

  -- A frame on the context wins: a grandchild charges the pool its grandparent
  -- opened, whichever declaration it was spawned from.
  local ledger = frame and frame.ledger or peek(req, "ledger")
  if ledger ~= nil and not usable_ledger(ledger) then
    notes[#notes + 1] = "the ledger handed to this spawn is not one; a fresh tree was opened instead"
    ledger = nil
  end
  if ledger == nil then
    local built, made = pcall(subagent.ledger, peek(req, "tree"))
    if not built then
      notes[#notes + 1] = "the tree limits given are not usable: " .. text_of(made)
      made = subagent.ledger()
    end
    ledger = made
  end

  local depth_given = peek(req, "depth")
  local parent_depth
  if type(depth_given) == "number" then
    parent_depth = depth_given
  elseif frame then
    parent_depth = frame.depth
  elseif type(peek(ctx, "depth")) == "number" then
    parent_depth = peek(ctx, "depth")
  else
    parent_depth = 0
  end
  local child_depth = parent_depth + 1

  local label = peek(req, "label")
  if type(label) ~= "string" or label == "" then label = nil end

  local name_given = peek(req, "agent")
  local prompt = peek(req, "prompt")

  local function named()
    if type(name_given) == "string" and name_given ~= "" then return name_given end
    if type(name_given) == "table" then
      local n = peek(name_given, "name")
      if type(n) == "string" and n ~= "" then return n end
      return "(a declaration)"
    end
    return "(none)"
  end

  local function blocked(kind, why)
    return {
      id      = root,
      agent   = named(),
      label   = label,
      depth   = child_depth,
      ok      = false,
      stop    = "blocked",
      blocked = kind,
      reason  = sentence(why),
      answer  = nil,
      prompt  = type(prompt) == "string" and prompt or nil,
      steps   = 0,
      budget  = 0,
      clamped = false,
      transcript = nil,
      calls   = nil,
      notes   = notes,
      err     = nil,
      pool    = ledger.snapshot(),
    }
  end

  -- A mistyped key is refused rather than ignored: silently leaving a limit at its
  -- default is precisely the bug this subsystem exists to prevent.
  local unknown = {}
  for k in pairs(req) do
    if not RUN_KEYS[k] then unknown[#unknown + 1] = tostring(k) end
  end
  table.sort(unknown)
  if #unknown > 0 then
    return blocked("malformed", "a spawn request has no field " .. q(unknown[1])
      .. ". It takes: agent, prompt, budget, label")
  end

  -- The request itself.
  if type(prompt) ~= "string" then
    return blocked("malformed", "a subagent is given its prompt as a string, and this call gave "
      .. (prompt == nil and "none" or ("a " .. type(prompt))))
  end
  if trim(prompt) == "" then
    return blocked("malformed", "the prompt was empty, and a child with nothing to do still costs "
      .. "a model call, a reservation and a place in the fanout. Say what the child is to do")
  end

  -- Which child.
  local roster, pick = peek(req, "agents"), peek(req, "pick")
  local decl
  if type(name_given) == "table" then
    decl = name_given
  else
    if name_given == nil and type(roster) == "table" then
      local only_one = sorted_keys(roster)
      if #only_one == 1 then name_given = only_one[1] end
    end
    if type(name_given) ~= "string" or name_given == "" then
      return blocked("malformed", "a spawn names its agent as a string, and this call gave "
        .. (name_given == nil and "none" or ("a " .. type(name_given))))
    end
    if type(pick) == "function" then
      local ok, chosen, why = pcall(pick, name_given, ctx)
      if not ok then
        notes[#notes + 1] = "the roster function raised: " .. text_of(chosen)
        return blocked("unknown", "the agent " .. q(name_given) .. " could not be chosen: " .. text_of(chosen))
      end
      if chosen == nil then
        return blocked("unknown", "there is no agent named " .. q(name_given) .. " here"
          .. (type(why) == "string" and why ~= "" and (": " .. why) or ""))
      end
      decl = chosen
    elseif type(roster) == "table" then
      decl = peek(roster, name_given)
      if decl == nil then
        local have = sorted_keys(roster)
        return blocked("unknown", "there is no agent named " .. q(name_given)
          .. " here. The agents that exist are: "
          .. (#have > 0 and table.concat(have, ", ") or "none"))
      end
    else
      return blocked("unknown", "no roster was given, so there is no agent named "
        .. q(name_given) .. " to run")
    end
  end

  -- What it may spend. A budget over the ceiling is clamped, never refused: a child
  -- told it may have 12 steps and given 3 without being told would report failures
  -- the parent cannot interpret.
  local asked = peek(req, "budget")
  if asked ~= nil and type(asked) ~= "number" then
    return blocked("malformed", "a budget is a whole number of steps, and arrived as a " .. type(asked))
  end
  local ceiling = peek(req, "max_budget")
  if not whole(ceiling, 1) then ceiling = DEFAULTS.max_budget end
  local want = asked or DEFAULTS.budget
  local clamped = false
  if want ~= math.floor(want) then clamped = true end
  want = math.floor(want)
  if want < 1 then want, clamped = 1, true end
  if want > ceiling then want, clamped = ceiling, true end

  -- The world. The ability to spawn is a capability the host grants at declaration
  -- time, never one a body takes from its own context.
  local granted = peek(req, "world")
  local world
  if type(granted) == "function" then
    local ok, made, why = pcall(granted, ctx, {
      agent = named(), prompt = prompt, budget = want, label = label, depth = child_depth,
    })
    if not ok then
      notes[#notes + 1] = "the world function raised: " .. text_of(made)
      return blocked("ungranted", "no world was granted for this child: the host's world function raised: "
        .. text_of(made))
    end
    if made == nil then
      return blocked("ungranted", "no world was granted for this child"
        .. (type(why) == "string" and why ~= "" and (": " .. q(why)) or ""))
    end
    if type(made) ~= "table" then
      return blocked("ungranted", "a world is a port table, and the host's world function answered a "
        .. type(made))
    end
    world = made
  elseif type(granted) == "table" then
    world = granted
  else
    return blocked("ungranted", "this declaration was granted no world, so it cannot start a child here")
  end

  -- Can the child run at all? Checked before the permit is opened, so a broken child
  -- costs the tree nothing.
  local runnable, problems = turn.check(decl, world, {
    budget = want, depth = child_depth, max_depth = ledger.max_depth,
  })
  if not runnable then
    return blocked("declaration", "the child agent cannot run: " .. table.concat(problems, "; "))
  end

  local permit, kind, why = ledger.open { depth = child_depth, budget = want, id = root }
  if not permit then
    return blocked(kind, why)
  end
  if permit.clamped then clamped = true end

  local child_id = root .. "/" .. permit.id

  -- Exactly one key is added, on a shallow copy: the host's own port table is not
  -- mutated, and nothing is taken away.
  local child_port = copy(world)
  child_port.subagent = {
    ledger = ledger,
    depth  = child_depth,
    id     = child_id,
    root   = root,
  }

  local ran, r = pcall(turn.run, decl, prompt, child_port, {
    budget = permit.budget,
    depth = child_depth,
    max_depth = ledger.max_depth,
    id = child_id,
  })

  if not ran or type(r) ~= "table" then
    local message = ran and ("the turn loop answered a " .. type(r) .. ", not a result") or text_of(r)
    ledger.close(permit, 0)
    return {
      id = child_id, agent = named(), label = label, depth = child_depth,
      ok = false, stop = "error", blocked = nil,
      reason = sentence("the child could not be run: " .. message),
      answer = nil, prompt = prompt,
      steps = 0, budget = permit.budget, clamped = clamped,
      transcript = {}, calls = {}, notes = notes,
      err = { where = "spawn", message = message },
      pool = ledger.snapshot(),
    }
  end

  local spent = type(r.steps) == "number" and r.steps or 0
  ledger.close(permit, spent)

  local out = {
    id      = child_id,
    agent   = named(),
    label   = label,
    depth   = child_depth,
    ok      = r.stop == "answered",
    stop    = r.stop,
    blocked = nil,
    reason  = sentence(type(r.reason) == "string" and r.reason ~= "" and r.reason
      or ("the child ended with " .. tostring(r.stop))),
    answer  = r.stop == "answered" and r.answer or nil,
    prompt  = prompt,
    steps   = spent,
    budget  = permit.budget,
    clamped = clamped,
    transcript = r.transcript,
    calls   = r.calls,
    notes   = notes,
    err     = r.err,
    pool    = ledger.snapshot(),
  }
  if type(r.notes) == "table" then
    for i = 1, #r.notes do notes[#notes + 1] = r.notes[i] end
  end
  return out
end

-- ---------------------------------------------------------------- the tool decl

-- The parameter shape src/spec.lua reads. Written out rather than required, because
-- this module requires turn and nothing else; spec.add_tool checks these fields.
local function param(kind, required, description)
  return { __param = true, kind = kind, required = required, description = description }
end

local TOOL_KEYS = {
  about = true, agents = true, pick = true, world = true, budget = true,
  max_budget = true, depth = true, children = true, steps = true,
  include = true, max_chars = true, ask = true, watch = true, id = true,
  ledger = true,
}

local function note_to(ctx, line)
  local n = peek(ctx, "note")
  if type(n) == "function" then
    pcall(n, line)
    return
  end
  local log = peek(ctx, "log")
  if type(log) == "table" and type(log.write) == "function" then
    pcall(log.write, "info", "subagent", { line = line })
  end
end

function subagent.tool(cfg)
  if type(cfg) ~= "table" then
    fail(2, "subagent.tool takes a table, got %s", type(cfg))
  end
  local unknown = {}
  for k in pairs(cfg) do
    if not TOOL_KEYS[k] then unknown[#unknown + 1] = tostring(k) end
  end
  table.sort(unknown)
  if #unknown > 0 then
    fail(2, "subagent.tool has no field %s: a mistyped limit that silently kept its default "
      .. "is the bug this tool exists to prevent", q(unknown[1]))
  end

  if type(cfg.about) ~= "string" or cfg.about == "" then
    fail(2, "subagent.tool needs `about`: what the model is told this tool is for")
  end
  if (cfg.agents == nil) == (cfg.pick == nil) then
    fail(2, "subagent.tool takes exactly one of `agents` (a roster) and `pick` (a function)")
  end
  if cfg.agents ~= nil then
    if type(cfg.agents) ~= "table" then
      fail(2, "subagent.tool: `agents` is a table of name to agent, got %s", type(cfg.agents))
    end
    local n = 0
    for k, v in pairs(cfg.agents) do
      if type(k) ~= "string" or k == "" then
        fail(2, "subagent.tool: an entry in `agents` is named by a non-empty string")
      end
      if type(v) ~= "table" then
        fail(2, "subagent.tool: the agent %s is a declaration table, got %s", q(k), type(v))
      end
      n = n + 1
    end
    if n == 0 then
      fail(2, "subagent.tool: `agents` is empty, and an empty roster would refuse every call")
    end
  end
  if cfg.pick ~= nil and type(cfg.pick) ~= "function" then
    fail(2, "subagent.tool: `pick` is a function (name, ctx) -> agent, got %s", type(cfg.pick))
  end
  if type(cfg.world) ~= "table" and type(cfg.world) ~= "function" then
    fail(2, "subagent.tool: `world` is the child's port table, or a function that builds one, got %s",
      type(cfg.world))
  end
  if cfg.budget ~= nil and not whole(cfg.budget, 1) then
    fail(2, "subagent.tool: `budget` is a whole number of steps, at least 1")
  end
  local budget = cfg.budget or DEFAULTS.budget
  if cfg.max_budget ~= nil and not whole(cfg.max_budget, 1) then
    fail(2, "subagent.tool: `max_budget` is a whole number of steps, at least 1")
  end
  local max_budget = cfg.max_budget or math.max(DEFAULTS.max_budget, budget)
  if max_budget < budget then
    fail(2, "subagent.tool: `max_budget` (%d) is below `budget` (%d)", max_budget, budget)
  end
  if cfg.depth ~= nil and not whole(cfg.depth, 0) then
    fail(2, "subagent.tool: `depth` is a whole number of levels, at least 0")
  end
  if cfg.children ~= nil and not whole(cfg.children, 1) then
    fail(2, "subagent.tool: `children` is a whole number of children, at least 1")
  end
  if cfg.steps ~= nil and not whole(cfg.steps, 1) then
    fail(2, "subagent.tool: `steps` is a whole number of steps, at least 1")
  end
  if cfg.include ~= nil and not INCLUDES[cfg.include] then
    fail(2, "subagent.tool: `include` is \"answer\", \"readout\" or \"none\", got %s", tostring(cfg.include))
  end
  if cfg.max_chars ~= nil and not (type(cfg.max_chars) == "number" and cfg.max_chars >= 200) then
    fail(2, "subagent.tool: `max_chars` is a number, at least 200")
  end
  if cfg.ask ~= nil and type(cfg.ask) ~= "boolean" then
    fail(2, "subagent.tool: `ask` is true or false")
  end
  if cfg.watch ~= nil and type(cfg.watch) ~= "function" then
    fail(2, "subagent.tool: `watch` is a function (result), got %s", type(cfg.watch))
  end
  if cfg.id ~= nil and (type(cfg.id) ~= "string" or cfg.id == "") then
    fail(2, "subagent.tool: `id` is a non-empty string")
  end
  if cfg.ledger ~= nil and not (is_ledger(cfg.ledger) or type(cfg.ledger) == "function") then
    fail(2, "subagent.tool: `ledger` is a ledger, or a function (ctx) -> ledger")
  end

  local held = {
    agents = cfg.agents, pick = cfg.pick, world = cfg.world,
    budget = budget, max_budget = max_budget, id = cfg.id,
    include = cfg.include or DEFAULTS.include,
    max_chars = cfg.max_chars or DEFAULTS.max_chars,
    watch = cfg.watch,
    tree = { depth = cfg.depth or DEFAULTS.depth,
             children = cfg.children or DEFAULTS.children,
             steps = cfg.steps or DEFAULTS.steps },
  }

  -- One tree per declaration, opened on the first spawn. A frame on the context
  -- always wins over it, so a child spawned from another declaration still charges
  -- the pool its tree opened.
  local mine
  local function tree_for(ctx)
    if type(cfg.ledger) == "function" then
      local ok, made = pcall(cfg.ledger, ctx)
      if ok and is_ledger(made) then return made end
    elseif is_ledger(cfg.ledger) then
      return cfg.ledger
    end
    if mine == nil then mine = subagent.ledger(held.tree) end
    return mine
  end

  local roster_names = sorted_keys(held.agents)
  local one = (held.pick == nil and #roster_names == 1) and roster_names[1] or nil

  local which
  if one then
    which = param("string", false, "which agent to run; the only one here is " .. one)
  elseif held.pick then
    which = param("string", true, "which agent to run")
  else
    which = param("string", true, "which agent to run, one of: " .. table.concat(roster_names, ", "))
  end

  return {
    about = cfg.about,
    ask = cfg.ask ~= false,
    args = {
      agent  = which,
      prompt = param("string", true, "the whole of what the child is told; it sees nothing else"),
      budget = param("number", false, "steps the child may spend, at most " .. held.max_budget),
      label  = param("string", false, "a name for this child, so two of them can be told apart"),
    },
    run = function (ctx)
      local args = peek(ctx, "args")
      if type(args) ~= "table" then args = {} end

      -- Written long, not as `args.budget ~= nil and args.budget or held.budget`: that
      -- reads a `budget = false` as "none given" and quietly hands back the default,
      -- where 4.2 wants a budget that is not a number to be a stated malformed result.
      local asked = held.budget
      if args.budget ~= nil then asked = args.budget end

      local req = {
        agent      = args.agent,
        prompt     = args.prompt,
        budget     = asked,
        label      = args.label,
        agents     = held.agents,
        pick       = held.pick,
        world      = held.world,
        max_budget = held.max_budget,
        id         = held.id,
      }
      if subagent.frame(ctx) == nil then
        req.ledger = tree_for(ctx)
      end

      local result = subagent.run(ctx, req)

      if held.watch then
        local ok, e = pcall(held.watch, result)
        if not ok then
          result.notes[#result.notes + 1] = "the watch for " .. tostring(result.id)
            .. " raised: " .. text_of(e)
        end
      end

      note_to(ctx, "subagent " .. tostring(result.agent) .. " (" .. tostring(result.id) .. ") "
        .. (result.blocked and ("did not run: " .. result.blocked) or tostring(result.stop))
        .. " in " .. tostring(result.steps) .. " of " .. tostring(result.budget) .. " steps")

      return subagent.render(result, held)
    end,
  }
end

return subagent
