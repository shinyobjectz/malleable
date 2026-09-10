-- observe -- a run, read back out as behaviour.
--
-- THE DIRECTION IS THE DESIGN, and it is the only thing to remember about this file:
-- Gherkin is not a format for logs. A trace and a transcript are what this module READS;
-- they are never what it SAYS. Every line it emits is an expression a person writes --
-- the same string, from the same closed vocabulary -- so that what an agent did and what
-- it was asked to do are the same kind of object and can be set against each other.
--
-- `span`, `trace` and `log` are the harness's nouns. A person watching an agent does not
-- think "the gate span closed refused"; they think "it asked before it filed, and was
-- told no". An observed scenario written in the harness's nouns describes the harness,
-- and describing the AGENT is this module's whole job.
--
-- What it has no word for is a GAP IN THE VOCABULARY, recorded and handed back. It is
-- never repaired by reaching for a telemetry noun: the moment that is allowed, the
-- observer emits it for everything it has no word for and the vocabulary stops growing on
-- the day it starts. (mar-4o07, one layer up.)
--
-- Contract: spec/observe.md. Amend that before this diverges from it.

local gherkin = require "gherkin"
-- What a command line did, in terms. Required here rather than handed in because this
-- file's job IS the vocabulary an observation is written in, and a renderer that could be
-- given a different reader would be a renderer whose output nobody could compare.
local command = require "command"

local observe = {}

-- ---------------------------------------------------------------------- small helpers

-- A quoted string the way a feature file holds one, and NOT Lua's `%q`: that escapes a
-- newline as a backslash followed by a real newline, which splits the step in half and
-- leaves the second half as a line nobody can parse. A step is one line.
local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r",
                  ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }

local function q(v)
  local text = tostring(v)
  text = text:gsub('[%c"\\]', function (c)
    return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
  end)
  return '"' .. text .. '"'
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out, function (a, b) return tostring(a) < tostring(b) end)
  return out
end

-- Canonical, because two runs that did the same thing must produce the SAME TEXT or the
-- repertoire cannot collapse them. Sorted keys, no spaces, no float drift.
local function encode(v)
  local kind = type(v)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return tostring(v) end
  if kind == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
    return string.format("%.14g", v)
  end
  if kind == "string" then return q(v) end
  if kind ~= "table" then return q(tostring(v)) end

  local n = 0
  for _ in pairs(v) do n = n + 1 end
  local list = #v == n and n > 0
  local out = {}
  if list then
    for i = 1, #v do out[i] = encode(v[i]) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = sorted_keys(v)
  for i = 1, #keys do
    out[i] = q(tostring(keys[i])) .. ":" .. encode(v[keys[i]])
  end
  return "{" .. table.concat(out, ",") .. "}"
end

-- Seconds since the epoch, written the way `the clock reads {string}` reads one. By
-- arithmetic: this tree touches no `os`, and a local zone would make a scenario mean
-- different things on different machines.
local function iso(at)
  local days = math.floor(at / 86400)
  local rest = at - days * 86400
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
                          - math.floor(doe / 146096)) / 365)
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  local y = yoe + era * 400 + (m <= 2 and 1 or 0)
  return string.format("%04d-%02d-%02dT%02d:%02d:%02dZ", y, m, d,
    math.floor(rest / 3600), math.floor(rest % 3600 / 60), math.floor(rest % 60))
end

-- ------------------------------------------------------------------------ the emitter
--
-- Every string this table can produce is an expression `behaviour.steps()` holds, and a
-- test asserts exactly that. Nothing else in this file writes a step.

local function lines_of(text)
  local out = {}
  for line in (tostring(text) .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
  if out[#out] == "" then out[#out] = nil end
  return out
end

local Steps = {}
Steps.__index = Steps

local function steps()
  return setmetatable({ said = {}, gaps = {} }, Steps)
end

function Steps:say(text, doc)
  self.said[#self.said + 1] = { text = text, doc = doc }
end

-- What was seen, and the shape of the sentence that would have said it. Recorded rather
-- than approximated: an approximation is how a vocabulary stops growing.
function Steps:gap(saw, wanted)
  self.gaps[#self.gaps + 1] = { saw = saw, wanted = wanted }
end

-- ------------------------------------------------------------------- the given half

local function say_world(s, cfg)
  cfg = cfg or {}

  local paths = sorted_keys(cfg.fs or {})
  for i = 1, #paths do
    s:say(string.format("the file %s contains:", q(paths[i])), cfg.fs[paths[i]])
  end

  local commands = sorted_keys(cfg.sh or {})
  for i = 1, #commands do
    local r = cfg.sh[commands[i]]
    s:say(string.format("the command %s answers %d and:", q(commands[i]),
                        (type(r) == "table" and r.code) or 0),
          (type(r) == "table" and r.out) or "")
  end

  if type(cfg.ask) == "table" then
    local tools = sorted_keys(cfg.ask)
    for i = 1, #tools do
      s:say(string.format("the human %s %s",
                          cfg.ask[tools[i]] and "approves" or "refuses", tools[i]))
    end
  end

  if type(cfg.clock) == "table" and type(cfg.clock.at) == "number" then
    s:say(string.format("the clock reads %s", q(iso(cfg.clock.at))))
  end

  if type(cfg.budget) == "number" then
    s:say(string.format("the budget is %d", cfg.budget))
  end

  -- The three later seams have no `Given` of their own yet. Recorded as gaps, named, and
  -- NOT approximated with something that reads nearly right.
  if cfg.skills then s:gap("the world held a skill", "a Given line for a workspace skill's presence") end
  if cfg.ledger then s:gap("the world held a ledger row", "a Given line for what a beat last did") end
  if cfg.mcp then s:gap("the world held a server", "a Given line for a declared server's tools") end
end

-- The model's replies, in the order it made them, reconstructed from what the run
-- recorded. They are part of the WORLD -- an input, not a behaviour -- which is why they
-- are Given lines and why an eval drops them.
--
-- The consequence worth having: an eval sample's observed scenario is a deterministic
-- replay of what a real model actually did. Take the one sample in twenty that went
-- wrong, and you have it forever, without the model.
local function say_script(s, result)
  local by_step = {}
  for i = 1, #(result.calls or {}) do
    local c = result.calls[i]
    by_step[c.step] = by_step[c.step] or {}
    table.insert(by_step[c.step], c)
  end
  for step = 1, (result.steps or 0) do
    for _, c in ipairs(by_step[step] or {}) do
      s:say(string.format("the model calls %s with %s", c.tool, encode(c.args or {})))
    end
  end
  if type(result.answer) == "string" and result.answer ~= "" then
    s:say(string.format("the model answers %s", q(result.answer)))
  end
end

-- --------------------------------------------------------------------- the then half

-- What a call to a shell AMOUNTED TO, in the vocabulary, beside the call itself.
--
-- Both lines, not one instead of the other. `it calls shell with {"command":"rm -rf x"}`
-- pins the fact and is what makes the scenario replayable; `it runs a command that
-- deletes` pins the meaning and is the only half somebody writing a feature file up front
-- could have written. A command the vocabulary cannot name is a GAP -- counted, filed
-- against the vocabulary, and never rendered as a quoted string somebody would then have
-- to read (mar-ykcc, spec/command.md).
-- Answers true when it took the line over, so the caller writes the behaviour instead of
-- the arguments. A command line is the one tool argument that must not appear in a Then:
-- it is the thing rule 8 keeps out of a span, and a feature file is read by more people
-- than a trace is. It is still in the GIVEN half, where it belongs -- that half is the
-- world the scenario replays, and the run is not reproducible without it.
local function say_acts(s, call)
  local said = type(call.args) == "table" and call.args.command or nil
  if type(said) ~= "string" or said == "" then return false end
  local ok, read = pcall(command.acts, said)
  if not ok or type(read) ~= "table" then return false end
  s:say(string.format("it calls %s", call.tool))
  for i = 1, #(read.acts or {}) do
    s:say(string.format("it runs a command that %s", read.acts[i]))
  end
  for _ = 1, (read.unplaced or 0) do
    s:gap("it ran a command the vocabulary cannot name",
          "a term for what that command did, in spec/command.md")
  end
  return true
end

local function say_behaviour(s, result, world)
  s:say(string.format("it stops with %s", tostring(result.stop)))
  s:say(string.format("it takes %d step%s", result.steps or 0,
                      (result.steps == 1) and "" or "s"))

  for i = 1, #(result.calls or {}) do
    local c = result.calls[i]
    if c.asked then
      s:say(string.format("the human is asked about %s", c.tool))
    end
    if c.refused then
      s:say(string.format("the call to %s is refused", c.tool))
    elseif c.ok == false then
      -- A refusal is a decision; this is the call that was allowed and did not work.
      if not say_acts(s, c) then
        s:say(string.format("it calls %s with %s", c.tool, encode(c.args or {})))
      end
      s:say(string.format("the call to %s fails", c.tool))
    else
      -- Every call is a line. A scenario with nine calls has nine lines: summarising
      -- them into a count would lose the arguments, which are half of what happened.
      if not say_acts(s, c) then
        s:say(string.format("it calls %s with %s", c.tool, encode(c.args or {})))
      end
    end
  end

  for i = 1, #(result.notes or {}) do
    s:say(string.format("it notes %s", q(result.notes[i])))
  end

  local fs = world and world.fs
  local wrote = (fs and fs.wrote) or {}
  if #wrote == 0 and #((fs and fs.removed) or {}) == 0 then
    s:say("nothing is written")
  else
    -- `wrote` is a list of { path, text }, not of paths: the last write to a path is the
    -- one the file holds, so the walk goes backwards and takes the first it sees.
    local seen, order = {}, {}
    for i = #wrote, 1, -1 do
      local path = type(wrote[i]) == "table" and wrote[i].path or wrote[i]
      if type(path) == "string" and not seen[path] then
        seen[path] = true
        order[#order + 1] = path
      end
    end
    table.sort(order)
    for i = 1, #order do
      s:say(string.format("the file %s holds:", q(order[i])), fs.files[order[i]])
    end
    for i = 1, #((fs and fs.removed) or {}) do
      s:gap("a file was removed", "a Then line for a file the run deleted")
    end
  end

  if type(result.answer) == "string" and result.answer ~= "" then
    s:say(string.format("it answers %s", q(result.answer)))
  end
end

-- --------------------------------------------------------------------------- writing

local function doc_block(text, indent)
  local fence = tostring(text):find('"""', 1, true) and "```" or '"""'
  local out = { indent .. fence }
  local body = lines_of(text)
  for i = 1, #body do out[#out + 1] = indent .. body[i] end
  out[#out + 1] = indent .. fence
  return table.concat(out, "\n")
end

--- One run, as the text of a scenario.
function observe.scenario(record, name)
  if type(record) ~= "table" or (type(record.result) ~= "table" and record.checked == nil) then
    error("observe.scenario: a record carries a result or a check", 2)
  end
  local result, world, cfg = record.result, record.world, record.cfg

  local given, when, then_ = steps(), steps(), steps()
  say_world(given, cfg)

  if result == nil then
    -- A run is not the only behaviour a declaration has. "It loads, and it is sound" is
    -- one, it is stated in the vocabulary already, and leaving it unobservable would mean
    -- a whole kind of scenario had no observed form.
    when:say("the declaration is loaded")
    if record.checked.ok then
      then_:say("the declaration is sound")
    else
      local reasons = record.checked.reasons or {}
      if #reasons == 0 then
        then_:gap("the declaration was refused and said nothing",
                  "a Then line for a refusal with no reason")
      end
      for i = 1, #reasons do
        then_:say(string.format("the declaration is refused because %s", q(reasons[i])))
      end
    end
  else
    say_script(given, result)
    when:say(string.format("the agent is asked %s", q(record.prompt or "")))
    say_behaviour(then_, result, world)
  end

  local out = { "  Scenario: " .. (name or ("observed — " .. tostring(record.prompt or ""))) }
  local function write(list, first)
    for i = 1, #list.said do
      out[#out + 1] = "    " .. ((i == 1) and first or "And ") .. list.said[i].text
      if list.said[i].doc ~= nil then
        out[#out + 1] = doc_block(list.said[i].doc, "      ")
      end
    end
  end
  write(given, "Given ")
  write(when, "When ")
  write(then_, "Then ")

  local gaps = {}
  for _, list in ipairs({ given, when, then_ }) do
    for i = 1, #list.gaps do gaps[#gaps + 1] = list.gaps[i] end
  end
  return table.concat(out, "\n") .. "\n", gaps
end

--- One run, as a pickle a runner can walk. Built by writing the scenario and reading it
--- back with the ordinary reader, so an observation that is not real Gherkin cannot get
--- out of this function.
function observe.run(record, name)
  local text, gaps = observe.scenario(record, name)
  local pickles, why = gherkin.pickle("Feature: observed\n" .. text)
  if not pickles then
    return nil, "the observation does not parse: " .. tostring(why), gaps
  end
  return pickles[1], nil, gaps
end

--- Many runs, as one feature file.
function observe.feature(records, title)
  local out = { "# Observed, not written. Every line below is a thing that happened." }
  out[#out + 1] = "Feature: " .. (title or "observed behaviour")
  local gaps = {}
  for i = 1, #records do
    out[#out + 1] = ""
    local text, some = observe.scenario(records[i], records[i].name)
    out[#out + 1] = (text:gsub("\n$", ""))
    for k = 1, #some do gaps[#gaps + 1] = some[k] end
  end
  return table.concat(out, "\n") .. "\n", gaps
end

--- Every gap a set of observations produced, collapsed by what was wanted, with a count.
--- This is the work list for growing the vocabulary: the count goes down, and a new KIND
--- of gap is a finding rather than a defect.
function observe.gaps(list)
  local held, order = {}, {}
  for i = 1, #list do
    local g = list[i]
    if held[g.wanted] == nil then
      held[g.wanted] = { wanted = g.wanted, saw = g.saw, n = 0 }
      order[#order + 1] = g.wanted
    end
    held[g.wanted].n = held[g.wanted].n + 1
  end
  table.sort(order)
  local out = {}
  for i = 1, #order do out[i] = held[order[i]] end
  return out
end

-- ------------------------------------------------------------------------- agreement

local function then_texts(pickle)
  -- The behaviour half. A pickle carries no phase, so this is the part after the When --
  -- which is exactly what "what it did" means.
  local out, seen_when = {}, false
  for i = 1, #pickle.steps do
    local text = pickle.steps[i].text
    if seen_when then
      out[#out + 1] = text
    elseif text:match("^the agent is asked ") or text:match("^the clock strikes ")
        or text == "the declaration is loaded" then
      seen_when = true
    end
  end
  return out
end

--- What was stated, set against what was observed. Three groups, and the third is why
--- this exists: a passing test says the agent did what was asked; only the agreement says
--- what else it did on the way.
function observe.agreement(stated, observed)
  if type(stated) ~= "table" or type(observed) ~= "table" then
    error("observe.agreement: two pickles", 2)
  end
  local want, got = then_texts(stated), then_texts(observed)
  local have = {}
  for i = 1, #got do have[got[i]] = (have[got[i]] or 0) + 1 end

  local held, missing = {}, {}
  for i = 1, #want do
    if (have[want[i]] or 0) > 0 then
      have[want[i]] = have[want[i]] - 1
      held[#held + 1] = want[i]
    else
      missing[#missing + 1] = want[i]
    end
  end

  local unstated = {}
  for i = 1, #got do
    if (have[got[i]] or 0) > 0 then
      have[got[i]] = have[got[i]] - 1
      unstated[#unstated + 1] = got[i]
    end
  end

  return { held = held, missing = missing, unstated = unstated,
           agreed = #missing == 0 and #unstated == 0 }
end

--- The agreement, rendered. An unstated line is not a failure -- most are ordinary -- and
--- it is printed as what it is: a thing the run did that nobody had written down.
function observe.agreement_text(a)
  local out = {}
  out[#out + 1] = string.format("%d held, %d missing, %d unstated",
                                #a.held, #a.missing, #a.unstated)
  for i = 1, #a.missing do out[#out + 1] = "  stated, and did not happen:  " .. a.missing[i] end
  for i = 1, #a.unstated do out[#out + 1] = "  happened, and nobody said:   " .. a.unstated[i] end
  return table.concat(out, "\n") .. "\n"
end

-- ------------------------------------------------------------------------ repertoire

--- Many observed scenarios, collapsed into the distinct behaviours they exhibit, each
--- with the rate at which it occurred.
---
--- Over the Then lines and nothing else, so two runs that differ only in a model's
--- wording are one behaviour and two that differ in what they called are two.
--- Deterministic: no model judges the clustering.
function observe.repertoire(observations)
  if type(observations) ~= "table" then
    error("observe.repertoire: a list of pickles", 2)
  end
  local held, order = {}, {}
  for i = 1, #observations do
    local key = table.concat(then_texts(observations[i]), "\n")
    if held[key] == nil then
      held[key] = { n = 0, first = observations[i], did = then_texts(observations[i]) }
      order[#order + 1] = key
    end
    held[key].n = held[key].n + 1
  end

  local out = {}
  for i = 1, #order do
    local e = held[order[i]]
    out[#out + 1] = { n = e.n, rate = e.n / #observations, scenario = e.first, did = e.did }
  end
  -- Commonest first, and ties broken by the text so two runs of the same suite print the
  -- same order.
  table.sort(out, function (a, b)
    if a.n ~= b.n then return a.n > b.n end
    return table.concat(a.did, "\n") < table.concat(b.did, "\n")
  end)
  return out
end

-- ---------------------------------------------------------- the repertoire, kept
--
-- A repertoire is BEHAVIOURAL MEMORY: not text to retrieve, but a record of what this
-- agent actually does, in a form that can be re-run and compared. It is the safety rail
-- everything self-editing depends on, because the way that class of system fails is
-- silent -- a pass rate goes UP while the repertoire quietly SHRINKS, and nothing else
-- in the harness would notice.
--
-- It is kept as a FEATURE FILE, and that is the whole design. A new format would need a
-- new writer, a new reader and a new set of bugs; a feature file is read by `gherkin.lua`
-- and run by `behaviour.lua`, both of which already exist and are already measured. So
-- the memory is re-runnable, a person can read it, and `git diff` says what changed.
--
-- Each distinct behaviour is one scenario, carrying `@seen-n-of-total` -- how often the
-- agent did this, out of how many runs. The scenario's own Then half is its identity,
-- which is exactly the identity `observe.repertoire` already collapses on.

local function tag_counts(tags)
  for i = 1, #(tags or {}) do
    local n, total = tags[i]:match("^@seen%-(%d+)%-of%-(%d+)$")
    if n then return tonumber(n), tonumber(total) end
  end
  return nil
end

--- A repertoire, as a feature file: re-runnable, readable, and diffable by anything.
function observe.repertoire_feature(r, title, total)
  if type(r) ~= "table" then
    error("observe.repertoire_feature: a repertoire, and arrived as " .. type(r), 2)
  end
  total = total or (function ()
    local n = 0
    for i = 1, #r do n = n + r[i].n end
    return n
  end)()

  local out = {
    "# The repertoire: what this agent was observed to do, and how often.",
    "# GENERATED. Every scenario below is a thing that happened, kept so the next version",
    "# can be asked whether it still does it.",
    "Feature: " .. (title or "repertoire"),
  }
  for i = 1, #r do
    out[#out + 1] = ""
    out[#out + 1] = string.format("  @seen-%d-of-%d", r[i].n, total)
    -- The stored scenario, whole: its Given and When are what make it re-runnable, and a
    -- memory that cannot be re-run is a note rather than a test.
    local body = observe.pickle_text(r[i].scenario, string.format("behaviour %d", i))
    out[#out + 1] = (body:gsub("\n$", ""))
  end
  return table.concat(out, "\n") .. "\n", total
end

--- One pickle, written back out as the scenario it came from.
---
--- `observe.scenario` writes a RUN; this writes a PICKLE, which is what a repertoire
--- holds. Doc strings come back as doc strings, so a scenario that stated a file's
--- contents states them again and the round trip holds.
function observe.pickle_text(pickle, name)
  if type(pickle) ~= "table" or type(pickle.steps) ~= "table" then
    error("observe.pickle_text: a pickle, and arrived as " .. type(pickle), 2)
  end
  local out = { "  Scenario: " .. (pickle.name or name or "observed") }
  -- A pickle carries no phase, so the keyword is rebuilt the one way that reads: the
  -- first line is Given, the line that starts the run is When, the rest are Then. This is
  -- the same rule `then_texts` reads by, and they must not drift.
  local phase, opened = "Given", nil
  for i = 1, #pickle.steps do
    local text = pickle.steps[i].text
    if text:match("^the agent is asked ") or text:match("^the clock strikes ")
       or text == "the declaration is loaded" then
      phase = "When"
    end
    -- The first line of a phase carries its keyword and the rest carry `And`. Writing
    -- `And` for the first Then would still PARSE -- a pickle has no phase -- and would
    -- read to a person as another When, which is a memory that misinforms the one
    -- audience it was written for.
    out[#out + 1] = "    " .. ((opened == phase) and "And " or (phase .. " ")) .. text
    opened = phase
    if phase == "When" then phase = "Then" end
    if pickle.steps[i].doc ~= nil then
      out[#out + 1] = doc_block(pickle.steps[i].doc, "      ")
    end
  end
  return table.concat(out, "\n") .. "\n"
end

--- A repertoire read back from what `repertoire_feature` wrote.
---
--- Answers the same shape `observe.repertoire` does, so a stored repertoire and a fresh
--- one are the same kind of thing and `repertoire_diff` cannot tell them apart. That is
--- the property that makes the memory useful rather than merely written down.
function observe.repertoire_read(text)
  if type(text) ~= "string" then
    error("observe.repertoire_read: the text of a feature file, and arrived as " .. type(text), 2)
  end
  local pickles, why = gherkin.pickle(text)
  if not pickles then return nil, "the repertoire does not parse: " .. tostring(why) end
  local out, total = {}, 0
  for i = 1, #pickles do
    local n, said = tag_counts(pickles[i].tags)
    n = n or 1
    total = math.max(total, said or 0)
    out[#out + 1] = { n = n, scenario = pickles[i], did = then_texts(pickles[i]) }
  end
  if total == 0 then
    for i = 1, #out do total = total + out[i].n end
  end
  for i = 1, #out do out[i].rate = (total > 0) and (out[i].n / total) or 0 end
  return out, total
end

--- Two repertoires, set against each other.
---
--- `lost` is the one that matters and is why this exists. A behaviour the agent used to
--- have and no longer has is invisible to a pass rate -- the rate can RISE while the
--- agent quietly stops doing half of what it did -- and that is precisely how a
--- self-editing loop goes wrong without anybody noticing.
function observe.repertoire_diff(before, after)
  if type(before) ~= "table" or type(after) ~= "table" then
    error("observe.repertoire_diff: two repertoires", 2)
  end
  local function keyed(r)
    local by = {}
    for i = 1, #r do by[table.concat(r[i].did or {}, "\n")] = r[i] end
    return by
  end
  local was, now = keyed(before), keyed(after)

  local lost, gained, kept = {}, {}, {}
  local keys = {}
  for k in pairs(was) do keys[#keys + 1] = k end
  for k in pairs(now) do if was[k] == nil then keys[#keys + 1] = k end end
  table.sort(keys)

  for i = 1, #keys do
    local k = keys[i]
    if now[k] == nil then
      lost[#lost + 1] = was[k]
    elseif was[k] == nil then
      gained[#gained + 1] = now[k]
    else
      kept[#kept + 1] = { did = now[k].did, was = was[k].rate or 0, now = now[k].rate or 0,
                          scenario = now[k].scenario }
    end
  end
  return { lost = lost, gained = gained, kept = kept,
           before = #before, after = #after }
end

--- The diff, as the lines a person reads. A loss is stated first and stated as a loss.
function observe.repertoire_diff_text(d)
  if type(d) ~= "table" or type(d.lost) ~= "table" then
    error("observe.repertoire_diff_text: a diff from observe.repertoire_diff", 2)
  end
  local out = {}
  local function line(fmt, ...) out[#out + 1] = string.format(fmt, ...) end
  line("%d behaviour%s before, %d after", d.before, d.before == 1 and "" or "s", d.after)

  if #d.lost > 0 then
    line("\n%d LOST -- the agent no longer does %s:", #d.lost,
         #d.lost == 1 and "this" or "these")
    for i = 1, #d.lost do
      line("  was %d×  %s", d.lost[i].n, d.lost[i].did[1] or "(did nothing)")
      for k = 2, #d.lost[i].did do line("         %s", d.lost[i].did[k]) end
    end
  end
  if #d.gained > 0 then
    line("\n%d gained:", #d.gained)
    for i = 1, #d.gained do
      line("  now %d×  %s", d.gained[i].n, d.gained[i].did[1] or "(did nothing)")
    end
  end
  if #d.kept > 0 then
    line("\n%d kept:", #d.kept)
    for i = 1, #d.kept do
      local k = d.kept[i]
      local moved = ""
      if math.abs(k.now - k.was) > 0.0001 then
        moved = string.format("  (%.0f%% -> %.0f%%)", k.was * 100, k.now * 100)
      end
      line("  %s%s", k.did[1] or "(did nothing)", moved)
    end
  end
  if #d.lost == 0 and #d.gained == 0 then line("\nnothing gained, nothing lost") end
  return table.concat(out, "\n") .. "\n"
end

--- The repertoire, rendered: how many different things this agent does, and which.
function observe.repertoire_text(r, total)
  total = total or (function ()
    local n = 0
    for i = 1, #r do n = n + r[i].n end
    return n
  end)()
  local out = {}
  out[#out + 1] = string.format("%d distinct behaviour%s in %d run%s",
                                #r, #r == 1 and "" or "s", total, total == 1 and "" or "s")
  for i = 1, #r do
    out[#out + 1] = string.format("\n  %d/%d  %s", r[i].n, total, r[i].did[1] or "(did nothing)")
    for k = 2, #r[i].did do out[#out + 1] = "         " .. r[i].did[k] end
  end
  return table.concat(out, "\n") .. "\n"
end

return observe
