-- observe -- a run, read back out as behaviour.
--
-- THE DIRECTION IS THE DESIGN: a trace and a transcript are what this module READS, never
-- what it SAYS. Every line it emits is an expression a person writes, from the same closed
-- vocabulary, so what an agent did and what it was asked to do can be set against each other.
--
-- It emits no harness noun. `span`, `trace` and `log` describe the harness; describing the
-- AGENT is this module's job.
--
-- What it has no word for is a GAP IN THE VOCABULARY, recorded and handed back -- never
-- repaired by reaching for a telemetry noun, which would stop the vocabulary growing.
--
-- Contract: spec/observe.md. Amend that before this diverges from it.

local gherkin = require "gherkin"
-- What a command line did, in terms. Required here rather than handed in because this
-- file's job IS the vocabulary an observation is written in, and a renderer that could be
-- given a different reader would be a renderer whose output nobody could compare.
local command = require "command"

local observe = {}

-- small helpers

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
observe.encode = encode

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

-- The emitter. Every string this table can produce is an expression `behaviour.steps()`
-- holds, and a test asserts it. Nothing else in this file writes a step.

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

function Steps:say(text, doc, rows)
  self.said[#self.said + 1] = { text = text, doc = doc, rows = rows }
end

-- A store's rows as a data table: the header, then one list of cells a row. The columns
-- come from the declaration when the record has it, in the order the store lists them;
-- without it, every column any row has, by name. `rows` is sorted by the store already.
local function store_table(decl, rows)
  local cols = {}
  if type(decl) == "table" and type(decl.column_order) == "table" then
    local seen = {}
    for _, k in ipairs(decl.sort or {}) do cols[#cols + 1] = k; seen[k] = true end
    for _, k in ipairs(decl.column_order) do if not seen[k] then cols[#cols + 1] = k end end
  else
    local seen = {}
    for i = 1, #rows do for k in pairs(rows[i]) do seen[k] = true end end
    cols = sorted_keys(seen)
  end
  local out = { cols }
  for i = 1, #rows do
    local cells = {}
    for j = 1, #cols do
      local v = rows[i][cols[j]]
      cells[j] = v == nil and "" or tostring(v)
    end
    out[#out + 1] = cells
  end
  return out
end

-- What was seen, and the shape of the sentence that would have said it. Recorded rather
-- than approximated: an approximation is how a vocabulary stops growing.
function Steps:gap(saw, wanted)
  self.gaps[#self.gaps + 1] = { saw = saw, wanted = wanted }
end

-- the given half

local function say_world(s, cfg, stores, keep)
  cfg = cfg or {}

  local paths = sorted_keys(cfg.fs or {})
  for i = 1, #paths do
    local ref = keep and keep(cfg.fs[paths[i]])
    if ref then
      s:say(string.format("the file %s contains the text kept as %s", q(paths[i]), ref))
    else
      s:say(string.format("the file %s contains:", q(paths[i])), cfg.fs[paths[i]])
    end
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
      local a = cfg.ask[tools[i]]
      if type(a) == "table" and a.allow ~= false and type(a.args) == "table" then
        -- The person changed what the model proposed, and this is what they chose.
        s:say(string.format("the human approves %s with %s", tools[i], encode(a.args)))
      else
        local yes = a and not (type(a) == "table" and a.allow == false)
        s:say(string.format("the human %s %s", yes and "approves" or "refuses", tools[i]))
      end
    end
  end

  if type(cfg.store) == "table" then
    local names = sorted_keys(cfg.store)
    for i = 1, #names do
      local rows = cfg.store[names[i]]
      if type(rows) == "table" and #rows > 0 then
        s:say(string.format("the store %s contains:", names[i]), nil,
              store_table(stores and stores[names[i]], rows))
      end
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

-- The model's replies in order, reconstructed from what the run recorded. They are part of
-- the WORLD -- an input, not a behaviour -- so they are Given lines and an eval drops them.
--
-- The consequence: an eval sample's observed scenario is a deterministic replay of what a
-- real model did, so the one sample in twenty that went wrong is keepable without the model.
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
  -- An empty answer is still a reply the model gave: a run that stopped on one needs it in
  -- the script, or the scenario runs out a step early when it runs again.
  if type(result.answer) == "string" and (result.answer ~= "" or result.stop == "answered") then
    s:say(string.format("the model answers %s", q(result.answer)))
  end
end

-- the then half

-- What a call to a shell AMOUNTED TO, in the vocabulary, beside the call itself.
--
-- Both lines, not one instead of the other: `it calls shell with {"command":"rm -rf x"}`
-- pins the fact and makes the scenario replayable, `it runs a command that deletes` pins
-- the meaning. A command the vocabulary cannot name is a GAP, counted against the
-- vocabulary and never rendered as a quoted string (spec/command.md).
--
-- Answers true when it took the line over. A command line is the one tool argument that
-- must not appear in a Then (rule 8); it stays in the GIVEN half, which is the world the
-- scenario replays.
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

local ORDINAL = { "first", "second", "third", "fourth", "fifth" }

-- One line a call, as say_behaviour writes them: the ones a run still going has made so
-- far are the same lines, so a live observation and a finished one agree.
local function say_calls(s, calls)
  local nth = {}
  for i = 1, #(calls or {}) do
    local c = calls[i]
    nth[c.tool] = (nth[c.tool] or 0) + 1
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
      if type(c.unmet) == "string" and ORDINAL[nth[c.tool]] then
        -- A requirement it did not meet is the reason, in the tool's own words.
        s:say(string.format("the %s call to %s fails because %s", ORDINAL[nth[c.tool]], c.tool, q(c.unmet)))
      else
        s:say(string.format("the call to %s fails", c.tool))
      end
    else
      -- Every call is a line. A scenario with nine calls has nine lines: summarising
      -- them into a count would lose the arguments, which are half of what happened.
      if not say_acts(s, c) then
        s:say(string.format("it calls %s with %s", c.tool, encode(c.args or {})))
      end
    end
  end
end

local function say_behaviour(s, result, world, stores, keep)
  s:say(string.format("it stops with %s", tostring(result.stop)))
  s:say(string.format("it takes %d step%s", result.steps or 0,
                      (result.steps == 1) and "" or "s"))
  say_calls(s, result.calls)

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
      local ref = keep and keep(fs.files[order[i]])
      if ref then
        s:say(string.format("the file %s holds the text kept as %s", q(order[i]), ref))
      else
        s:say(string.format("the file %s holds:", q(order[i])), fs.files[order[i]])
      end
    end
    for i = 1, #((fs and fs.removed) or {}) do
      s:gap("a file was removed", "a Then line for a file the run deleted")
    end
  end

  -- Every store the run changed, as it stands after: the whole table, because a store is
  -- small and a row that moved is as much a behaviour as a row that was added.
  local held = world and world.store
  if type(held) == "table" and type(held.changes) == "table" and type(held.tables) == "table" then
    local changed = {}
    for i = 1, #held.changes do
      local name = held.changes[i].store
      if type(name) == "string" then changed[name] = true end
    end
    local names = sorted_keys(changed)
    for i = 1, #names do
      local rows = held.tables[names[i]] or {}
      if #rows == 0 then
        s:say(string.format("the store %s has 0 rows", names[i]))
      else
        s:say(string.format("the store %s holds:", names[i]), nil,
              store_table(stores and stores[names[i]], rows))
      end
    end
  end

  if type(result.answer) == "string" and result.answer ~= "" then
    s:say(string.format("it answers %s", q(result.answer)))
  end
end

-- writing

local function doc_block(text, indent)
  local fence = tostring(text):find('"""', 1, true) and "```" or '"""'
  local out = { indent .. fence }
  local body = lines_of(text)
  for i = 1, #body do out[#out + 1] = indent .. body[i] end
  out[#out + 1] = indent .. fence
  return table.concat(out, "\n")
end

-- A data table, its columns padded to line up. A bar, a backslash or a newline in a cell
-- is escaped the way the reader reads it back.
local function table_block(rows, indent)
  local escaped, width = {}, {}
  for r = 1, #rows do
    escaped[r] = {}
    for c = 1, #rows[r] do
      local cell = tostring(rows[r][c]):gsub("\\", "\\\\"):gsub("|", "\\|"):gsub("\n", "\\n")
      escaped[r][c] = cell
      width[c] = math.max(width[c] or 0, #cell)
    end
  end
  local out = {}
  for r = 1, #escaped do
    local cells = {}
    for c = 1, #escaped[r] do cells[c] = escaped[r][c] .. string.rep(" ", width[c] - #escaped[r][c]) end
    out[#out + 1] = indent .. "| " .. table.concat(cells, " | ") .. " |"
  end
  return table.concat(out, "\n")
end

--- One run, as the text of a scenario. `opts.keep(text)`, if given, answers the name of a
--- text a history keeps apart, or nil to write the text into the scenario (spec/history.md).
function observe.scenario(record, name, opts)
  local keep = opts and opts.keep
  if type(record) ~= "table" or (type(record.result) ~= "table" and record.checked == nil) then
    error("observe.scenario: a record carries a result or a check", 2)
  end
  local result, world, cfg = record.result, record.world, record.cfg

  local given, when, then_ = steps(), steps(), steps()
  say_world(given, cfg, record.stores, keep)

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
    say_behaviour(then_, result, world, record.stores, keep)
  end

  local out = { "  Scenario: " .. (name or ("observed — " .. tostring(record.prompt or ""))) }
  local function write(list, first)
    for i = 1, #list.said do
      out[#out + 1] = "    " .. ((i == 1) and first or "And ") .. list.said[i].text
      if list.said[i].doc ~= nil then
        out[#out + 1] = doc_block(list.said[i].doc, "      ")
      end
      if list.said[i].rows ~= nil then
        out[#out + 1] = table_block(list.said[i].rows, "      ")
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

--- A run as it goes, as the text of a scenario so far (docs/spec/agent-file.md). The
--- record carries `result` with the calls made so far (`stop` nil while it runs), `prompt`,
--- and `log`, the history's log of the files it wrote (spec/history.md), whose texts are
--- the Then lines about files. What the world was given is not said: a live run's world is
--- the real one. Answers the text and the gaps.
function observe.live(record, name)
  if type(record) ~= "table" or type(record.result) ~= "table" then
    error("observe.live: a record carries a result", 2)
  end
  local result = record.result
  local given, when, then_ = steps(), steps(), steps()
  say_script(given, result)
  when:say(string.format("the agent is asked %s", q(record.prompt or "")))
  if result.stop ~= nil then
    then_:say(string.format("it stops with %s", tostring(result.stop)))
    then_:say(string.format("it takes %d step%s", result.steps or 0, (result.steps == 1) and "" or "s"))
  end
  say_calls(then_, result.calls)
  for i = 1, #(result.notes or {}) do then_:say(string.format("it notes %s", q(result.notes[i]))) end
  local log = record.log
  for _, path in ipairs((log and log.order) or {}) do
    local f = log.files[path]
    if f and f.wrote and not f.removed and type(f.after) == "string" then
      then_:say(string.format("the file %s holds:", q(path)), f.after)
    elseif f and f.removed then
      then_:gap("a file was removed", "a Then line for a file the run deleted")
    end
  end
  local out = { "  Scenario: " .. (name or ("observed — " .. tostring(record.prompt or ""))) }
  local function write(list, first)
    for i = 1, #list.said do
      out[#out + 1] = "    " .. ((i == 1) and first or "And ") .. list.said[i].text
      if list.said[i].doc ~= nil then out[#out + 1] = doc_block(list.said[i].doc, "      ") end
      if list.said[i].rows ~= nil then out[#out + 1] = table_block(list.said[i].rows, "      ") end
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

-- agreement

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

-- repertoire

--- Many observed scenarios, collapsed into the distinct behaviours they exhibit, each
--- with the rate at which it occurred.
---
--- Over the Then lines and nothing else, so two runs differing only in a model's wording
--- are one behaviour. Deterministic: no model judges the clustering.
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

-- The repertoire: behavioural memory. A record of what this agent actually does, in a
-- form that can be re-run and compared. Self-editing depends on it, because that class of
-- system fails silently -- a pass rate rises while the repertoire shrinks.
--
-- Kept as a FEATURE FILE, so it is re-runnable by `behaviour.lua`, readable by a person,
-- and diffable by git, with no new writer, reader or format.
--
-- Each distinct behaviour is one scenario carrying `@seen-n-of-total`. The scenario's Then
-- half is its identity, which is what `observe.repertoire` already collapses on.

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
--- `observe.scenario` writes a RUN; this writes a PICKLE, which is what a repertoire holds.
--- Doc strings come back as doc strings, so the round trip holds.
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
    -- The first line of a phase carries its keyword, the rest carry `And`. Writing `And`
    -- for the first Then would still parse -- a pickle has no phase -- but reads to a
    -- person as another When.
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
--- Answers the same shape `observe.repertoire` does, so a stored repertoire and a fresh one
--- are the same kind of thing and `repertoire_diff` cannot tell them apart.
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
--- `lost` is why this exists: a behaviour the agent no longer has is invisible to a pass
--- rate, which can RISE while the agent quietly stops doing half of what it did.
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
