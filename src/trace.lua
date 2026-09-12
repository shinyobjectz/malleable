-- trace -- what the run did, rendered. A table in, a string out.
--
-- `turn.lua` records the tree; this file has never heard of a run. It knows what a span
-- is, what the closed attribute vocabulary is, and how to write both down -- once for a
-- collector, once for a person at a terminal.
--
-- It opens no socket, holds no queue, batches nothing and samples nothing. A tracer that
-- drops spans under load drops the interesting ones; the host owns that decision and has
-- a real SDK to make it with. `spec/provider.md` settled the same question for the model,
-- and the answer is the same one: the format is here, the transport is the host's.
--
-- Contract: spec/trace.md. Amend that before this diverges from it.

local trace = {}

--- Bumped when a span name or an attribute changes meaning.
trace.VOCABULARY = 1

-- The vocabulary, in two kinds.
--
-- ADOPTED: where OpenTelemetry's GenAI semantic conventions have a name, it is used
-- verbatim -- never paraphrased, re-cased or extended. Those conventions are EXPERIMENTAL,
-- so the version read is pinned below and a drift amends `spec/trace.md`, renaming nothing.
--
-- MINTED: what the harness has and they do not, under one prefix, each naming a closed set
-- or a number. No free-text attribute appears in this table, which is what makes rule 8
-- checkable.

--- The GenAI semantic conventions this tree adopts, as of the version named.
---
--- Pinned to `open-telemetry/semantic-conventions-genai` @ main, read 2026-09-10; the last
--- versioned document is v1.42.0 (June 2026) and the dedicated repository has cut none
--- since. Status: Development. `spec/trace.md` carries the pin; a drift amends that file
--- rather than renaming anything here.
---
--- A name not in this list is not written; a name in it is written exactly as it appears.
trace.ADOPTED = {
  "gen_ai.operation.name", "gen_ai.provider.name", "gen_ai.agent.name",
  "gen_ai.request.model", "gen_ai.response.model",
  "gen_ai.usage.input_tokens", "gen_ai.usage.output_tokens",
  "gen_ai.tool.name", "gen_ai.tool.call.id",
}

--- What the harness has that the conventions do not. Each is a count, a duration, a
--- boolean, or a term from the closed set beside it.
trace.MINTED = {
  ["malleable.stop"]        = { "answered", "budget", "refused", "error" },
  ["malleable.steps"]       = "number",
  ["malleable.budget"]      = "number",
  ["malleable.calls"]       = "number",
  ["malleable.tools"]       = "number",
  ["malleable.skills"]      = "number",
  -- A SET: one or more terms, sorted and comma-joined. A shell call that pipes `curl`
  -- into `jq` reached out and read, and answering only one of them would be picking which
  -- half of the truth to send.
  --
  -- Written out rather than required from `src/command.lua`, which is where these terms
  -- are produced. This file reaches nothing -- no `io`, no `os`, no `require` -- and that
  -- is asserted, because a renderer that pulls a module in is a renderer that can be
  -- given something to do. The two lists are kept together by a test instead, the same
  -- way the spec's table and this one are (`test/trace_test.lua`).
  ["malleable.act"]         = { set = { "builds", "commits", "connects", "deletes",
                                        "escalates", "inspects", "installs", "publishes",
                                        "reads", "tests", "writes" } },
  ["malleable.unplaced"]    = "number",
  ["malleable.notes"]       = "number",
  ["malleable.depth"]       = "number",
  ["malleable.gate.answer"] = { "allowed", "edited", "refused", "stopped", "absent" },
  ["malleable.refused_by"]  = { "gate", "hook", "error" },
  ["malleable.requirement"] = { "unmet" },
  ["malleable.unclosed"]    = "boolean",
  ["malleable.dropped"]     = "number",
  ["malleable.outcome"]     = { "passed", "failed", "undefined", "broken", "skipped" },
  ["malleable.undefined"]   = "number",
  ["malleable.samples"]     = "number",
  ["malleable.rate"]        = "number",
}

--- Every attribute name this tree may write, as a set. `scripts/rules-test.lua` walks every span
--- the whole suite produces and fails on anything outside it, which is rule 8 enforced
--- rather than promised.
function trace.attributes()
  local out = {}
  for i = 1, #trace.ADOPTED do out[trace.ADOPTED[i]] = true end
  for k in pairs(trace.MINTED) do out[k] = true end
  return out
end

--- Is this attribute a value the vocabulary allows? Answers false and a sentence.
function trace.allowed(name, value)
  local closed = trace.MINTED[name]
  if closed == nil then
    for i = 1, #trace.ADOPTED do
      if trace.ADOPTED[i] == name then return true end
    end
    return false, string.format("%q is not in the vocabulary", name)
  end
  if closed == "number" then
    if type(value) == "number" then return true end
    return false, string.format("%s is a number, and this is a %s", name, type(value))
  end
  if closed == "boolean" then
    if type(value) == "boolean" then return true end
    return false, string.format("%s is a boolean, and this is a %s", name, type(value))
  end
  if type(closed.set) == "table" then
    if type(value) ~= "string" or value == "" then
      return false, string.format("%s is a comma-joined set of terms, and this is a %s",
                                  name, type(value))
    end
    local known = {}
    for i = 1, #closed.set do known[closed.set[i]] = true end
    for term in (value .. ", "):gmatch("(.-), ") do
      if not known[term] then
        return false, string.format("%s draws from %s, and this says %q",
                                    name, table.concat(closed.set, ", "), term)
      end
    end
    return true
  end
  for i = 1, #closed do
    if value == closed[i] then return true end
  end
  return false, string.format("%s is one of %s, and this is %q",
                              name, table.concat(closed, ", "), tostring(value))
end

-- rendering

local function esc(s)
  s = tostring(s)
  s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
  s = s:gsub("[%z\1-\31]", function (c) return string.format("\\u%04x", string.byte(c)) end)
  return s
end

local function attr_value(v)
  if type(v) == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
      return string.format('{"intValue":"%d"}', v)
    end
    return string.format('{"doubleValue":%.17g}', v)
  end
  if type(v) == "boolean" then return string.format('{"boolValue":%s}', tostring(v)) end
  return string.format('{"stringValue":"%s"}', esc(v))
end

local function sorted_keys(t)
  local out = {}
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

--- The trace, as one document a collector accepts. `ids` supplies the identifiers, and
--- that is deliberate: a 16-byte trace id and an 8-byte span id are the HOST's to mint,
--- because the host is the only thing that knows whether this run is already a child of
--- something being traced.
---
---     trace.otlp(result.spans, { trace = "4bf9...", span = function (id) ... end,
---                                service = "typeaway" })
function trace.otlp(spans, ids)
  if type(spans) ~= "table" then
    error("trace.otlp: spans are a list, and arrived as " .. type(spans), 2)
  end
  ids = ids or {}
  local trace_id = ids.trace or string.rep("0", 32)
  local span_id = ids.span or function (id) return string.format("%016x", tonumber(id) or 0) end
  local service = ids.service or "malleable"

  local out = {}
  for i = 1, #spans do
    local s = spans[i]
    local attrs = {}
    local keys = sorted_keys(s.attrs or {})
    for k = 1, #keys do
      attrs[#attrs + 1] = string.format('{"key":"%s","value":%s}', esc(keys[k]), attr_value(s.attrs[keys[k]]))
    end
    -- Nanoseconds, as a string, which is what the format asks for. `at` and `ms` are
    -- milliseconds from the clock port and nowhere else.
    local start_ns = string.format("%d000000", s.at or 0)
    local end_ns = string.format("%d000000", (s.at or 0) + (s.ms or 0))
    out[#out + 1] = string.format(
      '{"traceId":"%s","spanId":"%s",%s"name":"%s","kind":1,' ..
      '"startTimeUnixNano":"%s","endTimeUnixNano":"%s","attributes":[%s],"status":{"code":%d}}',
      trace_id, span_id(s.id),
      s.parent and string.format('"parentSpanId":"%s",', span_id(s.parent)) or "",
      esc(s.name), start_ns, end_ns, table.concat(attrs, ","),
      s.ok == false and 2 or 1)
  end

  return string.format(
    '{"resourceSpans":[{"resource":{"attributes":[' ..
    '{"key":"service.name","value":{"stringValue":"%s"}}]},' ..
    '"scopeSpans":[{"scope":{"name":"malleable","version":"%d"},"spans":[%s]}]}]}',
    esc(service), trace.VOCABULARY, table.concat(out, ","))
end

--- The trace as an indented tree, for a person at a terminal.
function trace.render(spans, opts)
  if type(spans) ~= "table" then
    error("trace.render: spans are a list, and arrived as " .. type(spans), 2)
  end
  opts = opts or {}
  local kids, roots = {}, {}
  for i = 1, #spans do
    local s = spans[i]
    if s.parent then
      kids[s.parent] = kids[s.parent] or {}
      table.insert(kids[s.parent], s)
    else
      roots[#roots + 1] = s
    end
  end

  local out = {}
  local function walk(s, depth)
    local marks = {}
    local keys = sorted_keys(s.attrs or {})
    for k = 1, #keys do
      local key = keys[k]
      -- The names carry their prefix in the vocabulary and would carry it four times a
      -- line here; a person reading a tree already knows which tree it is.
      local short = key:gsub("^malleable%.", ""):gsub("^gen_ai%.", "")
      marks[#marks + 1] = short .. "=" .. tostring(s.attrs[key])
    end
    out[#out + 1] = string.format("%s%s%s  %dms%s",
      string.rep("  ", depth), s.ok == false and "! " or "", s.name, s.ms or 0,
      #marks > 0 and ("  " .. table.concat(marks, " ")) or "")
    local children = kids[s.id] or {}
    for i = 1, #children do walk(children[i], depth + 1) end
  end
  for i = 1, #roots do walk(roots[i], 0) end
  if #out == 0 then return "(no spans)\n" end
  return table.concat(out, "\n") .. "\n"
end

return trace
