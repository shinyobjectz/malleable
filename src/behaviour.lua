-- behaviour -- a feature file is what the agent does, and the test that it does it.
--
-- The vocabulary is CLOSED and BUILT IN: thirty-one expressions over the harness's own
-- nouns -- the six ports, the three seams, the model's script, the gate, the four stops,
-- the calls, the notes and the budget -- which are the only nouns a harness has. A
-- declaration is therefore verifiable with no glue code written at all, and `agent.step`
-- exists for a DOMAIN rather than for the basics.
--
-- Rule 6 of DESIGN.md lives here, and it is structural rather than conventional:
--
--     A `Given` line may only write the world. A `Then` line may only read the result.
--
-- A given body is handed a context with a `world` and no `result`; a then body is handed
-- one with a `result` and a world that is a read-only proxy, so a write raises by name.
-- Neither carries a port, a model, a file handle or a clock. There is no arrangement of
-- fields that crosses them, because a scenario that could act on what it claims to be
-- observing is a test that passes because it tested itself.
--
-- This module requires `gherkin` and `double` and nothing else. It reaches a declaration
-- only through the drivers table it is handed -- run, tick, check -- so a feature cannot
-- test an internal that a host would not be allowed to depend on.
--
-- Contract: spec/behaviour.md. Amend that before this diverges from it.

local gherkin = require "gherkin"
local double  = require "double"
local observe = require "observe"
local command = require "command"

local behaviour = {}

--- Bumped when an expression changes meaning.
behaviour.VOCABULARY = 1

-- ---------------------------------------------------------------------- small helpers

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local function chomp(s) return (tostring(s):gsub("%s+$", "")) end
local function q(s) return string.format("%q", tostring(s)) end

-- A then body answers `false, sentence`. This is the sentence.
local function no(fmt, ...) return false, string.format(fmt, ...) end

local function contains(haystack, needle)
  return type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
end

local function same(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function show(v)
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local out = {}
  for i = 1, #keys do out[i] = keys[i] .. "=" .. tostring(v[keys[i]]) end
  return "{" .. table.concat(out, ", ") .. "}"
end

-- The read-only world a then body sees.
--
-- A DEEP COPY with a raising `__newindex` on every table, rather than an index proxy. A
-- proxy would need `__pairs` and `__len` to be transparent, and those are 5.2 and later:
-- under the LuaJIT half of this tree's dialect a proxied world iterates as empty, so a
-- Then line that counted anything silently counted nothing and its scenario failed for a
-- reason that was not true. Copying is transparent in both.
--
-- Every FUNCTION becomes a stub that raises. A then body has no business calling into the
-- world -- it reads what the run recorded -- and leaving the ports callable would leave
-- `c.world.fs.write(...)` open, which is rule 6 with a door in it.
--
-- WHAT THE GUARANTEE ACTUALLY IS, stated plainly because half of it is a diagnostic and
-- the other half is the rule. The RULE is isolation: this is a fresh copy, built for each
-- Then line, so nothing a Then line does to it reaches the run, the next line, or the
-- world the next assertion reads. That holds for every write, including `world.fs = nil`,
-- which lands on a copy about to be discarded. The DIAGNOSTIC is `__newindex`, which
-- fires on a key the world does not have -- the common typo -- and names it. Lua does not
-- run `__newindex` for a key that is already present, and buying that back would need an
-- index proxy, which cannot be iterated under 5.1. Isolation is the stronger of the two
-- and it is the one that does not depend on the dialect.
local function frozen(t, path, seen)
  if type(t) ~= "table" then return t end
  seen = seen or {}
  if seen[t] then return seen[t] end

  local copy = {}
  seen[t] = copy
  for k, v in pairs(t) do
    local at = path .. "." .. tostring(k)
    if type(v) == "table" then
      copy[k] = frozen(v, at, seen)
    elseif type(v) == "function" then
      copy[k] = function ()
        error(string.format("a Then line may only read: %s cannot be called", at), 2)
      end
    else
      copy[k] = v
    end
  end

  return setmetatable(copy, {
    __newindex = function (_, k)
      error(string.format("a Then line may only read: %s.%s cannot be written", path, tostring(k)), 2)
    end,
    __metatable = "read-only",
  })
end

-- Seconds since the epoch for `2026-06-01T09:00:00Z`, by arithmetic. `os.time` is not
-- reachable from this tree, and would be wrong anyway: it reads a local zone, and a
-- scenario must mean the same thing on every machine that runs it.
local function epoch(text)
  local y, m, d, hh, mm, ss = tostring(text):match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):?(%d*)")
  if not y then
    y, m, d = tostring(text):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    hh, mm, ss = "0", "0", "0"
  end
  if not y then return nil end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  hh, mm, ss = tonumber(hh) or 0, tonumber(mm) or 0, tonumber(ss ~= "" and ss or 0) or 0
  -- days_from_civil, Howard Hinnant's, which is exact and has no table in it.
  local yy = y - (m <= 2 and 1 or 0)
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468
  return days * 86400 + hh * 3600 + mm * 60 + ss
end

-- ------------------------------------------------------------------- the world, built
--
-- A given line writes into a CONFIG, and the config becomes a world at the `When`. That
-- ordering is what makes "a given may only write the world" enforceable: there is no
-- world yet to act on.

local function new_config()
  return { fs = {}, sh = {}, ask = {}, clock = nil, model = {},
           skills = nil, ledger = nil, mcp = nil, budget = nil }
end

local KNOWN = { fs = true, sh = true, ask = true, clock = true, model = true,
                skills = true, ledger = true, mcp = true, budget = true, shell = true }

local function materialise(cfg)
  local w = { fs = cfg.fs, sh = cfg.sh, ask = cfg.ask, model = { replies = cfg.model } }
  -- Before the world is built, not after: an unknown key rides onto the finished world,
  -- and by then the shell port already exists and swapping it would be a second one.
  if cfg.shell ~= nil then w.shell = cfg.shell end
  if cfg.clock then w.clock = cfg.clock end
  if cfg.skills then w.skills = cfg.skills end
  if cfg.ledger then w.ledger = cfg.ledger end
  if cfg.mcp then w.mcp = cfg.mcp end
  local world = double.world(w)
  -- Whatever a declared given line put in the config that is not one of the nine ports
  -- rides along onto the world, so a workspace's own state survives to its Then lines.
  -- Without this, `c.world.queue` is written in the given phase and gone by the then --
  -- which reads as a failing assertion rather than as a harness that dropped it.
  for k, v in pairs(cfg) do
    if not KNOWN[k] then world[k] = v end
  end
  return world
end

-- --------------------------------------------------------------------- the vocabulary

local BUILT_IN = {}

local function step(expr, phase, about, run)
  BUILT_IN[#BUILT_IN + 1] = { expr = expr, phase = phase, about = about, run = run, built_in = true }
end

-- given: the world -------------------------------------------------------------------

step("the file {string} contains:", "given", "a file the agent can read", function (c)
  if c.doc == nil then return no("this line needs a doc string under it") end
  c.world.fs[c.args[1]] = c.doc
end)

step("the file {string} is missing", "given", "a file that is not there", function (c)
  c.world.fs[c.args[1]] = nil
end)

step("the command {string} answers {int} and:", "given", "what one command line answers",
function (c)
  if c.doc == nil then return no("this line needs a doc string under it") end
  c.world.sh[c.args[1]] = { code = c.args[2], out = c.doc }
end)

-- The other kind of shell a world can have. `the command {string} answers {int} and:`
-- scripts one; this one really runs it, over the world's own filesystem, so `echo x >
-- a.txt` is a file the next line finds.
--
-- Added when `spec/shell.feature` needed to state a sandboxed agent's world and found it
-- could not: `agent.sandbox` was a first-class door with nothing in the vocabulary that
-- could say a feature used it. A gap of exactly the kind the ratchet is for.
step("the shell really runs", "given", "the world's shell executes, over its own files",
function (c)
  c.world.shell = true
end)

step("the human approves {word}", "given", "the gate says yes to this tool", function (c)
  c.world.ask[c.args[1]] = true
end)

step("the human refuses {word}", "given", "the gate says no to this tool", function (c)
  c.world.ask[c.args[1]] = false
end)

step("the clock reads {string}", "given", "the moment the run happens at", function (c)
  local at = epoch(c.args[1])
  if not at then return no("%s is not a time; write one as 2026-06-01T09:00:00Z", q(c.args[1])) end
  c.world.clock = { at = at }
end)

step("the model calls {word} with {value}", "given", "the next thing the model says",
function (c)
  if type(c.args[2]) ~= "table" then
    return no("a call's arguments are a table, and this is %s", show(c.args[2]))
  end
  c.world.model[#c.world.model + 1] = { tool = c.args[1], args = c.args[2] }
end, true)

step("the model answers {string}", "given", "the model's last word", function (c)
  c.world.model[#c.world.model + 1] = { text = c.args[1] }
end, true)

step("the workspace keeps a skill {string}:", "given", "a procedure a person wrote",
function (c)
  if c.doc == nil then return no("this line needs a doc string under it") end
  c.world.skills = c.world.skills or {}
  c.world.skills[c.args[1]] = { about = "", does = c.doc }
end)

step("{word} last ran on {string}", "given", "what the ledger remembers about a beat",
function (c)
  local at = epoch(c.args[2])
  if not at then return no("%s is not a time; write one as 2026-06-01T09:00:00Z", q(c.args[2])) end
  if not c.mark then return no("this run has no beats, so nothing can have last run") end
  local key, value = c.mark(c.args[1], at)
  if not key then return no("there is no beat called %s", q(c.args[1])) end
  c.world.ledger = c.world.ledger or {}
  c.world.ledger[key] = value
end)

step("the server {word} offers {word}, which answers {value}", "given",
     "a tool that lives in another process", function (c)
  c.world.mcp = c.world.mcp or {}
  local s = c.world.mcp[c.args[1]] or { tools = {}, answers = {} }
  s.tools[#s.tools + 1] = { name = c.args[2], about = "offered by " .. c.args[1] }
  s.answers[c.args[2]] = type(c.args[3]) == "string" and c.args[3] or show(c.args[3])
  c.world.mcp[c.args[1]] = s
end)

step("the budget is {int}", "given", "how many passes the loop may take", function (c)
  if c.args[1] < 1 then return no("a budget is at least 1") end
  c.world.budget = c.args[1]
end)

-- when: the run ----------------------------------------------------------------------

step("the agent is asked {string}", "when", "somebody asks the agent for something",
function (c)
  return c.drive.run(c.args[1])
end)

step("the clock strikes {string}", "when", "the beat comes round", function (c)
  local at = epoch(c.args[1])
  if not at then return no("%s is not a time; write one as 2026-06-01T09:00:00Z", q(c.args[1])) end
  return c.drive.tick(at)
end)

step("the declaration is loaded", "when", "nothing runs; the declaration is checked",
function (c)
  return c.drive.check()
end)

-- then: the result -------------------------------------------------------------------

local function ran(c)
  if not c.result then
    return nil, "this line reads a run, and this scenario's When did not make one"
  end
  return c.result
end

local function calls_to(c, tool)
  local out = {}
  local r = c.result
  for i = 1, #((r and r.calls) or {}) do
    if r.calls[i].tool == tool then out[#out + 1] = r.calls[i] end
  end
  return out
end

step("it stops with {word}", "then", "one of answered, budget, refused, error", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  local want = c.args[1]
  local known = { answered = true, budget = true, refused = true, error = true }
  if not known[want] then
    return no("%s is not a stop; the four are answered, budget, refused and error", q(want))
  end
  if r.stop ~= want then return no("it stopped with %s: %s", q(r.stop), tostring(r.reason)) end
end)

step("it answers {string}", "then", "the answer, exactly", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  if chomp(r.answer or "") ~= chomp(c.args[1]) then
    return no("it answered %s", q(r.answer))
  end
end)

step("the answer says {string}", "then", "the answer, containing", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  if not contains(r.answer, c.args[1]) then return no("it answered %s", q(r.answer)) end
end)

step("it calls {word}", "then", "the tool was called at least once", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  if #calls_to(c, c.args[1]) == 0 then
    return no("it called %s", #r.calls == 0 and "nothing" or q(r.calls[1].tool))
  end
end)

step("it calls {word} with {value}", "then", "called with exactly these arguments",
function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  local made = calls_to(c, c.args[1])
  if #made == 0 then return no("it never called %s", q(c.args[1])) end
  for i = 1, #made do if same(made[i].args, c.args[2]) then return true end end
  return no("it called %s with %s", q(c.args[1]), show(made[1].args))
end)

step("it calls {word} {int} time(s)", "then", "called exactly this many times", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  local n = #calls_to(c, c.args[1])
  if n ~= c.args[2] then return no("it called %s %d time(s)", q(c.args[1]), n) end
end)

-- What the agent did with a shell, in the language somebody would have used to ask for
-- it. The call line above says a tool was used; these say what using it AMOUNTED TO, which
-- is the only half a person writing a feature file up front can state.
--
-- `it never runs a command that publishes` is the one that earns the vocabulary. An agent
-- that inspects a lot is working; an agent that publishes has done the thing nobody can
-- undo for it, and no tool name or token count says so (spec/command.md).
local function acted(c, term)
  local r = c.result
  local found, unplaced = false, 0
  for i = 1, #((r and r.calls) or {}) do
    local said = type(r.calls[i].args) == "table" and r.calls[i].args.command or nil
    if type(said) == "string" and said ~= "" then
      local read = command.acts(said)
      unplaced = unplaced + (read.unplaced or 0)
      for j = 1, #read.acts do
        if read.acts[j] == term then found = true end
      end
    end
  end
  return found, unplaced
end

step("it runs a command that {word}", "then", "a shell call that did this", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  local term = c.args[1]
  if not command.known(term) then
    return no("%s is not one of %s", q(term), table.concat(command.ACTS, ", "))
  end
  local found, unplaced = acted(c, term)
  if not found then
    if unplaced > 0 then
      return no("no command it ran %s, and %d could not be named at all", term, unplaced)
    end
    return no("no command it ran %s", term)
  end
end)

step("it runs no command that {word}", "then", "no shell call did this", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  local term = c.args[1]
  if not command.known(term) then
    return no("%s is not one of %s", q(term), table.concat(command.ACTS, ", "))
  end
  if acted(c, term) then return no("a command it ran %s", term) end
end)

step("it never calls {word}", "then", "the tool was not called at all", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  local n = #calls_to(c, c.args[1])
  if n > 0 then return no("it called %s %d time(s)", q(c.args[1]), n) end
end)

step("the call to {word} is refused", "then", "the gate or a hook said no", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  local made = calls_to(c, c.args[1])
  if #made == 0 then return no("it never called %s", q(c.args[1])) end
  for i = 1, #made do if made[i].refused then return true end end
  return no("the call to %s went through", q(c.args[1]))
end)

step("the human is asked about {word}", "then", "the gate was put the question", function (c)
  local asked = c.world and c.world.ask and c.world.ask.asked
  if not asked then return no("this world has no gate to ask") end
  for i = 1, #asked do if asked[i].tool == c.args[1] then return true end end
  return no("the human was asked about nothing" ..
            (#asked > 0 and (" but " .. q(asked[1].tool)) or ""))
end)

step("it takes {int} step(s)", "then", "exactly this many passes of the loop", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  if r.steps ~= c.args[1] then return no("it took %d", r.steps) end
end)

step("it takes at most {int} step(s)", "then", "no more passes than this", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  if r.steps > c.args[1] then return no("it took %d", r.steps) end
end)

-- Spelled apart from the given form on purpose: the expression decides the phase, so two
-- phases cannot share one expression. "holds" is the outcome word, "contains" the setup one.
step("the file {string} holds:", "then", "what the file holds after the run", function (c)
  if c.doc == nil then return no("this line needs a doc string under it") end
  local files = c.world and c.world.fs and c.world.fs.files
  if not files then return no("this world has no filesystem") end
  local got = files[c.args[1]]
  if got == nil then return no("there is no file at %s", q(c.args[1])) end
  if chomp(got) ~= chomp(c.doc) then return no("it holds %s", q(got)) end
end)

step("nothing is written", "then", "no file was written or removed", function (c)
  local fs = c.world and c.world.fs
  if not fs then return no("this world has no filesystem") end
  if #(fs.wrote or {}) > 0 then return no("it wrote %s", q(fs.wrote[1])) end
  if #(fs.removed or {}) > 0 then return no("it removed %s", q(fs.removed[1])) end
end)

step("it notes {string}", "then", "the run made this note", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  for i = 1, #(r.notes or {}) do if contains(r.notes[i], c.args[1]) then return true end end
  return no("it noted %s", #(r.notes or {}) == 0 and "nothing" or q(r.notes[1]))
end)

step("the declaration is sound", "then", "it has no problems that would stop a run",
function (c)
  if c.checked == nil then return no("this line reads a check, and this scenario ran instead") end
  if not c.checked.ok then
    return no("it is refused: %s", table.concat(c.checked.reasons or {}, "; "))
  end
end)

step("the declaration is refused because {string}", "then", "and this is why", function (c)
  if c.checked == nil then return no("this line reads a check, and this scenario ran instead") end
  if c.checked.ok then return no("the declaration is sound") end
  for i = 1, #(c.checked.reasons or {}) do
    if contains(c.checked.reasons[i], c.args[1]) then return true end
  end
  return no("it is refused because: %s", table.concat(c.checked.reasons or {}, "; "))
end)

-- then: the calls that did not go through ----------------------------------------------
--
-- These two came out of RETIRING the eight telemetry expressions that stood here first
-- (`the trace shows`, `the span ... says ...`). Trying to say the same things
-- behaviourally showed that six of the eight were already covered by `it calls`,
-- `it never calls`, `the call to ... is refused` and `it takes N steps` -- and that two
-- things a person genuinely wanted to state had no word at all. That is the discipline
-- working: a gap in the vocabulary is filled with a behavioural word, never with a
-- telemetry noun (DESIGN.md, "The direction").

step("the call to {word} fails", "then", "it was called, and the call did not go through",
function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  local made = calls_to(c, c.args[1])
  if #made == 0 then return no("it never called %s", q(c.args[1])) end
  for i = 1, #made do
    -- A refusal is not a failure: the gate said no, which is a decision. This is the
    -- call that was allowed and then did not work.
    if made[i].ok == false and not made[i].refused then return true end
  end
  return no("every call to %s went through", q(c.args[1]))
end)

step("it calls {word} before {word}", "then", "and in that order", function (c)
  local r, why = ran(c); if not r then return no("%s", why) end
  local first, second = nil, nil
  for i = 1, #(r.calls or {}) do
    if first == nil and r.calls[i].tool == c.args[1] then first = i end
    if second == nil and r.calls[i].tool == c.args[2] then second = i end
  end
  if first == nil then return no("it never called %s", q(c.args[1])) end
  if second == nil then return no("it never called %s", q(c.args[2])) end
  if first > second then return no("it called %s first", q(c.args[2])) end
end)

-- The two that script a model, named so an eval can drop them.
local MODEL_SCRIPT = {
  ["the model calls {word} with {value}"] = true,
  ["the model answers {string}"] = true,
}

--- The built-in vocabulary, as a list of `{ expr, phase, about }`. `docs/STEPS.md` is
--- rendered from this and never hand-edited.
function behaviour.steps()
  local out = {}
  for i = 1, #BUILT_IN do
    out[i] = { expr = BUILT_IN[i].expr, phase = BUILT_IN[i].phase,
               about = BUILT_IN[i].about,
               scripts_model = MODEL_SCRIPT[BUILT_IN[i].expr] or false }
  end
  return out
end

-- --------------------------------------------------------------------- the registry

-- Compiled once, at load. A built-in that does not compile is a bug in this file and
-- raises here rather than on the eleventh scenario.
local COMPILED = nil
local function compiled()
  if COMPILED then return COMPILED end
  COMPILED = {}
  for i = 1, #BUILT_IN do
    local e, why = gherkin.expr(BUILT_IN[i].expr)
    if not e then error("behaviour: a built-in expression does not compile: " .. tostring(why)) end
    COMPILED[i] = { expr = e, def = BUILT_IN[i] }
  end
  return COMPILED
end

--- The skeleton of every built-in, for `agent.step` to refuse a collision against.
function behaviour.skeletons()
  local out = {}
  local list = compiled()
  for i = 1, #list do out[list[i].expr.skeleton()] = list[i].def.expr end
  return out
end

-- Always the whole vocabulary, in both modes. An eval DROPS the two lines that script a
-- model rather than un-defining them: removing them from the registry made them match
-- nothing, and "no expression matches this line" is a true sentence about a false problem
-- -- the expression exists, it just has nothing to do when a real model is answering.
local function registry(drivers)
  local out = {}
  local list = compiled()
  for i = 1, #list do
    out[#out + 1] = { expr = list[i].expr, def = list[i].def }
  end
  for i = 1, #(drivers.steps or {}) do
    local s = drivers.steps[i]
    out[#out + 1] = { expr = s.compiled, def = s }
  end
  return out
end

-- Every expression is tried against every step, and two matches raise naming both. There
-- are a few dozen of each, so the cost of being sure is nothing, and matching in
-- declaration order and taking the first is a bug that appears on the eleventh scenario.
local function match(reg, text)
  local hit, args, second = nil, nil, nil
  for i = 1, #reg do
    local got = reg[i].expr.match(text)
    if got then
      if hit then second = reg[i].def.expr; break end
      hit, args = reg[i].def, got
    end
  end
  if second then
    return nil, nil, string.format("two expressions match this line: %s and %s",
                                   q(hit.expr), q(second))
  end
  return hit, args
end

--- Declare a step on `a`. The compile and the collision refusals live here rather than
--- in `spec.lua`, which requires nothing and must go on requiring nothing (rule 2).
---
--- A workspace does not get to redefine what a built-in means, so a colliding expression
--- is refused at declaration naming both, rather than becoming an ambiguity that surfaces
--- on whichever scenario happens to use it first.
function behaviour.declare(spec, a, expr, d)
  if type(expr) == "string" and expr ~= "" then
    local e, why = gherkin.expr(expr)
    if not e then
      error(string.format("agent: the step %q: %s", expr, why), 3)
    end
    local built_in = behaviour.skeletons()[e.skeleton()]
    if built_in then
      error(string.format("agent: the step %q collides with the built-in %q; they read the same lines",
                          expr, built_in), 3)
    end
    for i = 1, #a.step_order do
      local other = a.steps[a.step_order[i]]
      if other.compiled and other.compiled.skeleton() == e.skeleton() then
        error(string.format("agent: the step %q collides with %q; they read the same lines",
                            expr, other.expr), 3)
      end
    end
    return spec.add_step(a, expr, d, e)
  end
  return spec.add_step(a, expr, d)
end

-- ------------------------------------------------------------------------- one scenario

local OUTCOMES = { passed = true, failed = true, undefined = true, broken = true, skipped = true }

-- What a person would have to paste to define a step that matched nothing. Parameters are
-- guessed from the shape of what is there, which is a suggestion and is marked as one.
local function stub(text)
  local expr = text:gsub('"[^"]*"', "{string}"):gsub("%f[%w]%-?%d+%f[%W]", "{int}")
  return string.format('agent.step %q {\n  given = function (c) ... end,   -- or then_\n}', expr)
end

-- A scenario is NOT EVALUABLE when every one of its steps but the When is a line that
-- scripts the model. Such a scenario states nothing about the world and nothing about the
-- outcome beyond what it put in the model's mouth, so with a real model answering there
-- is nothing left of it to score. Computed rather than declared, so nobody has to
-- remember a tag; `@verify-only` is the one tag this runner reads, and it opts out.
local function evaluable(pickle, reg)
  if #pickle.steps == 0 then return false, "it has no steps" end
  for i = 1, #pickle.tags do
    if pickle.tags[i] == "@verify-only" then return false, "it is @verify-only" end
  end
  local said_something = false
  for i = 1, #pickle.steps do
    local def = match(reg, pickle.steps[i].text)
    if not def then
      said_something = true          -- undefined; the verify pass is the place to say so
    elseif def.phase ~= "when" and not MODEL_SCRIPT[def.expr] then
      said_something = true
    end
  end
  if not said_something then
    return false, "every line but the When scripts the model, so a real one leaves nothing to score"
  end
  return true
end

local function run_scenario(pickle, drivers, opts)
  local cfg = new_config()
  local state = { world = nil, result = nil, checked = nil, when_line = nil, prompt = nil }
  local steps, outcome = {}, "passed"

  -- Under an eval the world stays DOUBLED and only the model is real. A real model
  -- driving real tools against real files is not an eval, it is production.
  local eval = opts and opts.eval
  local function build()
    local w = materialise(cfg)
    if eval and eval.model then w.model = eval.model end
    return w
  end

  local drive = {}
  function drive.run(prompt)
    state.prompt = prompt
    state.world = build()
    state.result = drivers.run(prompt, state.world, { budget = cfg.budget })
    return true
  end
  function drive.tick(at)
    cfg.clock = { at = at }
    state.world = build()
    if not drivers.tick then return no("this declaration has no beat to strike") end
    state.result = drivers.tick(state.world, { budget = cfg.budget })
    return true
  end
  function drive.check()
    state.world = build()
    local ok, reasons = drivers.check(state.world, { budget = cfg.budget })
    state.checked = { ok = ok and true or false, reasons = reasons or {} }
    return true
  end

  local reg = registry(drivers)

  -- A dry pass first, because "this scenario has no When" is a fact about the FILE and
  -- not about a run. Before this it surfaced as the first Then line failing with "this
  -- line reads a run and there is none", which sends a person to the wrong line: the
  -- Then line is fine, and the scenario is the thing nobody finished.
  --
  -- An unmatched step suspends the judgement. A scenario whose When is a step nobody has
  -- defined yet is UNDEFINED, not unfinished, and those mean different things.
  do
    local whens, unmatched = 0, false
    for i = 1, #pickle.steps do
      local def, _, ambiguous = match(reg, pickle.steps[i].text)
      if ambiguous or not def then unmatched = true
      elseif def.phase == "when" then whens = whens + 1 end
    end
    if not unmatched and #pickle.steps > 0 and whens ~= 1 then
      local why = whens == 0
        and "a scenario with a Given and a Then and no When is one nobody finished"
        or string.format("a scenario has one When, and this one has %d", whens)
      local said = {}
      for i = 1, #pickle.steps do
        said[i] = { text = pickle.steps[i].text, keyword = pickle.steps[i].keyword,
                    line = pickle.steps[i].line, outcome = "skipped" }
      end
      said[#said + 1] = { text = "(the scenario)", line = pickle.line,
                          outcome = "broken", why = why }
      return { name = pickle.name, line = pickle.line, tags = pickle.tags,
               outcome = "broken", steps = said }
    end
  end

  for i = 1, #pickle.steps do
    local s = pickle.steps[i]
    local record = { text = s.text, keyword = s.keyword, line = s.line }

    if outcome == "undefined" or outcome == "broken" or outcome == "failed" then
      record.outcome = "skipped"
    else
      local def, args, ambiguous = match(reg, s.text)
      if ambiguous then
        record.outcome, record.why = "broken", ambiguous
        outcome = "broken"
      elseif not def then
        record.outcome, record.why, record.stub = "undefined", "no expression matches this line", stub(s.text)
        outcome = "undefined"
      elseif eval and MODEL_SCRIPT[def.expr] then
        -- Not applicable, and said so rather than counted against the scenario: a real
        -- model is answering, so there is nothing for this line to do.
        record.outcome = "skipped"
        record.why = "a real model is answering, so this line has nothing to do"
      elseif def.phase == "given" and state.result ~= nil then
        record.outcome = "broken"
        record.why = "a Given line cannot follow a When: the world is already built"
        outcome = "broken"
      else
        local ctx = { args = args, doc = s.doc, rows = s.rows, drive = drive,
                      mark = drivers.mark }
        if def.phase == "then" then
          ctx.result = state.result
          ctx.checked = state.checked
          ctx.world = state.world and frozen(state.world, "world") or nil
        else
          ctx.world = def.phase == "given" and cfg or nil
        end
        local body = def.run or (def.phase == "given" and def.given) or def.then_
        local ok, got, why = pcall(body, ctx)
        if not ok then
          record.outcome, record.why = "broken", "the step raised: " .. tostring(got)
          outcome = "broken"
        elseif got == false then
          record.outcome, record.why = "failed", why or "it did not hold"
          outcome = "failed"
        else
          record.outcome = "passed"
          if def.phase == "when" then state.when_line = s.line end
        end
      end
    end
    steps[#steps + 1] = record
  end

  if #pickle.steps == 0 then outcome = "undefined" end

  -- The scenario span, and everything the run did under it. THE JOIN: a trace in a
  -- collector is attributable to the sentence in the feature file that asked for it, and
  -- without that a falling rate says a thing is broken without saying where.
  --
  -- Built here rather than inside the loop because a scenario is not a run -- it may make
  -- no run at all, or one, and it is this file that knows which. The run's own root is
  -- re-parented under it; ids are unique within a scenario, and "0" is not one the
  -- recorder mints.
  local spans = nil
  if state.result and type(state.result.spans) == "table" then
    local ms, at = 0, nil
    for i = 1, #state.result.spans do
      local sp = state.result.spans[i]
      if sp.parent == nil then
        sp.parent = "0"
        at = at or sp.at
        ms = math.max(ms, sp.ms or 0)
      end
    end
    spans = { { id = "0", parent = nil, name = "malleable.scenario " .. tostring(pickle.name),
                at = at or 0, ms = ms, ok = outcome == "passed",
                attrs = { ["malleable.outcome"] = outcome,
                          ["malleable.undefined"] = (function ()
                            local n = 0
                            for i = 1, #steps do
                              if steps[i].outcome == "undefined" then n = n + 1 end
                            end
                            return n
                          end)() } } }
    for i = 1, #state.result.spans do spans[#spans + 1] = state.result.spans[i] end
    state.result.spans = spans
  end

  return { name = pickle.name, line = pickle.line, tags = pickle.tags,
           outcome = outcome, steps = steps,
           result = state.result, world = state.world, spans = spans,
           -- What `observe` needs to read this run back out as behaviour: the world it
           -- actually had, the prompt, and what came back. Kept on every scenario so an
           -- eval can observe every sample without running anything twice.
           record = (state.result or state.checked) and
                    { result = state.result, world = state.world, cfg = cfg,
                      prompt = state.prompt, checked = state.checked } or nil }
end

--- One scenario's run, read back out as behaviour. `nil` when nothing ran.
function behaviour.observe(scenario, name)
  if type(scenario) ~= "table" or scenario.record == nil then return nil end
  return observe.run(scenario.record, name or ("observed — " .. tostring(scenario.name)))
end

-- ---------------------------------------------------------------------------- running

--- Every scenario against the doubles. Answers a table and prints nothing.
function behaviour.run(pickles, drivers, opts)
  if type(pickles) ~= "table" then
    error("behaviour.run: pickles are a list, and arrived as " .. type(pickles), 2)
  end
  opts = opts or {}
  local report = { passed = 0, failed = 0, undefined = 0, broken = 0, skipped = 0,
                   not_evaluable = 0, scenarios = {}, vocabulary = behaviour.VOCABULARY,
                   eval = opts.eval ~= nil, raw_gaps = {} }
  local eval = opts.eval
  local samples = (eval and eval.samples) or 1
  local reg = eval and registry(drivers) or nil

  for i = 1, #pickles do
    local pickle = pickles[i]

    local can, why = true, nil
    if eval then can, why = evaluable(pickle, reg) end

    if not can then
      -- Named with the reason, and NOT scored. A rate over a scenario that could not be
      -- evaluated would be a number about nothing.
      report.scenarios[#report.scenarios + 1] = {
        name = pickle.name, line = pickle.line, tags = pickle.tags,
        outcome = "skipped", steps = {}, why = why,
      }
      report.not_evaluable = (report.not_evaluable or 0) + 1
    else
      local passes, last, kept, seen = 0, nil, {}, {}
      for k = 1, samples do
        local one = run_scenario(pickle, drivers, opts)
        last = one
        if one.outcome == "passed" then
          passes = passes + 1
        elseif #kept < 3 then
          -- Every failing sample keeps its result and its trace, because that is the
          -- difference between a number that says a thing is broken and one that says
          -- where. Three of them: a person reads the first and the rest are the same.
          kept[#kept + 1] = one
        end
        -- EVERY sample is observed, passing or not. A pass rate says how often the agent
        -- did what its documentation says; the repertoire says how many different things
        -- it does and which, which is the question a rate cannot answer.
        -- Only under an eval. A verify runs one sample against a scripted model, where a
        -- "repertoire" of one behaviour and a list of four lines nobody stated is noise
        -- rather than news. The gaps below are collected in both modes, because those
        -- are news either way.
        if eval and one.record then
          local seen_one = observe.run(one.record, "observed — " .. tostring(pickle.name))
          if seen_one then seen[#seen + 1] = seen_one end
        end
      end
      last.samples = samples
      last.passes = passes
      last.rate = passes / samples
      last.failures = kept
      last.observations = seen
      if #seen > 0 then
        last.repertoire = observe.repertoire(seen)
        -- What the run did that nobody stated, from the commonest behaviour. An unstated
        -- line is not a failure; it is a thing that happened and was never written down,
        -- and it is the half of an eval a pass rate has never carried.
        last.agreement = observe.agreement(pickle, last.repertoire[1].scenario)
      end
      if samples > 1 then last.outcome = passes == samples and "passed" or "failed" end
      report.scenarios[#report.scenarios + 1] = last
      report[last.outcome] = (report[last.outcome] or 0) + 1
      -- Every run is observed, in both modes, and what the vocabulary could not say comes
      -- back here. Not behind a flag: a gap is a finding, and a finding nobody sees is a
      -- finding nobody acts on. This is the ratchet -- the count goes down, and a new
      -- KIND of gap is a question about the vocabulary rather than a defect.
      if last.record then
        local _, _, some = observe.run(last.record)
        for g = 1, #(some or {}) do report.raw_gaps[#report.raw_gaps + 1] = some[g] end
      end
      for s = 1, #last.steps do
        if last.steps[s].outcome == "skipped" then report.skipped = report.skipped + 1 end
      end
    end
  end
  report.gaps = observe.gaps(report.raw_gaps)
  report.raw_gaps = nil

  -- A feature nobody wired up must not sit in a suite looking green.
  report.ok = report.failed == 0 and report.broken == 0
              and not (report.undefined > 0 and report.passed == 0)
  return report
end

-- ----------------------------------------------------------------------------- checking

--- The problems a run would hit, as sentences, reaching no port at all.
function behaviour.check(pickles, drivers)
  local problems = {}
  local function say(line, fmt, ...)
    problems[#problems + 1] = string.format("line %d: " .. fmt, line, ...)
  end
  local reg = registry(drivers)
  local used = {}

  for p = 1, #pickles do
    local pickle = pickles[p]
    local whens, phase_seen = 0, nil
    for i = 1, #pickle.steps do
      local s = pickle.steps[i]
      local def, _, ambiguous = match(reg, s.text)
      if ambiguous then
        say(s.line, "%s", ambiguous)
      elseif not def then
        say(s.line, "no expression matches %s. To define it:\n    %s", q(s.text), stub(s.text))
      else
        used[def.expr] = true
        if def.phase == "when" then whens = whens + 1 end
        if def.phase == "given" and phase_seen == "then" then
          say(s.line, "a Given line cannot follow a Then")
        end
        if def.phase == "given" and phase_seen == "when" then
          say(s.line, "a Given line cannot follow a When: the world is already built")
        end
        phase_seen = def.phase

        -- The one that catches most stale features: renaming a tool cannot break a file
        -- the compiler never reads.
        local tool = nil
        if def.expr:find("it calls {word}", 1, true)
           or def.expr == "it never calls {word}"
           or def.expr == "the call to {word} is refused"
           or def.expr == "the human is asked about {word}"
           or def.expr == "the model calls {word} with {value}" then
          tool = (s.text:match("^it calls (%S+)")
               or s.text:match("^it never calls (%S+)")
               or s.text:match("^the call to (%S+) is refused")
               or s.text:match("^the human is asked about (%S+)")
               or s.text:match("^the model calls (%S+) with"))
        end
        if tool and drivers.tools and not drivers.tools[tool] then
          say(s.line, "this declaration has no tool called %s", q(tool))
        end
        if (def.expr == "the human approves {word}" or def.expr == "the human refuses {word}")
           and drivers.asks then
          local named = s.text:match("approves (%S+)$") or s.text:match("refuses (%S+)$")
          if named and drivers.tools and not drivers.tools[named] then
            say(s.line, "this declaration has no tool called %s", q(named))
          elseif named and not drivers.asks[named] then
            say(s.line, "%s does not ask, so this gate will never open", q(named))
          end
        end
      end
    end
    if whens == 0 then
      say(pickle.line, "this scenario has no When: %s", q(pickle.name))
    elseif whens > 1 then
      say(pickle.line, "this scenario has %d When lines, and a scenario has one", whens)
    end
  end

  for i = 1, #(drivers.steps or {}) do
    local s = drivers.steps[i]
    if not used[s.expr] then
      problems[#problems + 1] = string.format(
        "the step %s is declared and no scenario in this feature uses it", q(s.expr))
    end
  end
  return problems
end

-- ---------------------------------------------------------------------------- reporting

--- The report as text. Pure: the caller decides where it goes, because this tree has no
--- idea what stdout is.
function behaviour.report(t, opts)
  opts = opts or {}
  local out = {}
  local function line(fmt, ...) out[#out + 1] = select("#", ...) > 0 and string.format(fmt, ...) or fmt end

  for i = 1, #t.scenarios do
    local s = t.scenarios[i]
    local mark = s.outcome == "passed" and "ok  " or (s.outcome == "skipped" and "--  " or "FAIL")
    if s.outcome == "undefined" then mark = "????" end
    if s.samples and s.samples > 1 then
      mark = string.format("%3d%%", math.floor(s.rate * 100 + 0.5))
    end
    line("%s  %s  (line %d)%s", mark, s.name, s.line,
         (s.samples and s.samples > 1) and string.format("  %d/%d", s.passes, s.samples) or "")
    if s.why then line("        not evaluable: %s", s.why) end
    if s.repertoire and #s.repertoire > 0 then
      line("        %d distinct behaviour%s:", #s.repertoire, #s.repertoire == 1 and "" or "s")
      for b = 1, #s.repertoire do
        local did = s.repertoire[b].did
        line("          %d/%d  %s", s.repertoire[b].n, s.samples, did[1] or "(nothing)")
        for k = 2, #did do line("                 %s", did[k]) end
      end
    end
    -- Only when there is ONE behaviour. With more than one, the listing above already
    -- shows what differs, and printing both drowns the signal in the four lines every
    -- observation carries (it stops with, it takes N steps, nothing is written, it
    -- answers). With one, this is the useful half: your agent consistently does these
    -- things and nobody ever wrote them down.
    if s.agreement and s.repertoire and #s.repertoire == 1 and #s.agreement.unstated > 0 then
      line("        happened, and nobody said:")
      for u = 1, #s.agreement.unstated do line("          %s", s.agreement.unstated[u]) end
    end
    if s.agreement and #s.agreement.missing > 0 and #(s.repertoire or {}) == 1 then
      line("        stated, and did not happen:")
      for m = 1, #s.agreement.missing do line("          %s", s.agreement.missing[m]) end
    end
    for k = 1, #s.steps do
      local st = s.steps[k]
      if st.outcome ~= "passed" or opts.verbose then
        line("        %s %s  (line %d)", st.keyword or "", st.text, st.line or 0)
        if st.why then line("          %s", st.why) end
        if st.stub then line("          %s", (st.stub:gsub("\n", "\n          "))) end
      end
    end
  end
  line("")
  line("%d passed, %d failed, %d undefined, %d broken, %d step(s) skipped",
       t.passed, t.failed, t.undefined, t.broken, t.skipped)
  if (t.not_evaluable or 0) > 0 then
    line("%d scenario(s) could not be evaluated against a real model", t.not_evaluable)
  end
  if t.undefined > 0 and t.passed == 0 then
    line("every scenario is undefined: this feature is not wired to anything")
  end
  -- What the runs did that the vocabulary has no sentence for. NOT a failure and not
  -- counted against anything: it is the work list for growing the vocabulary, and the
  -- rule is that it is never closed by reaching for a telemetry noun (DESIGN.md, "The
  -- direction").
  if t.gaps and #t.gaps > 0 then
    line("")
    line("%d gap%s in the behavioural vocabulary:", #t.gaps, #t.gaps == 1 and "" or "s")
    for i = 1, #t.gaps do
      line("  %d×  saw: %s", t.gaps[i].n, t.gaps[i].saw)
      line("      wanted: %s", t.gaps[i].wanted)
    end
  end
  return table.concat(out, "\n") .. "\n"
end

return behaviour
