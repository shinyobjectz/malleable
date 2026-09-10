-- compaction — context budget and compaction. Tests.
--
-- Every one of these runs with no network, no disk and no subprocess: the model is a
-- table literal whose call returns whatever the test says, including nothing.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local compaction = require("compaction")

local T = {}

-- ---------------------------------------------------------------------------
-- helpers

local function body(n)
  return string.rep("word ", math.floor(n / 5))
end

-- A window small enough that a handful of messages crosses it, so no test builds a
-- hundred thousand characters to prove a threshold.
local SMALL = { window = 2000 }

local function conversation(n, chars)
  local h = { { role = "system", text = "answer carefully and cite the file you read" } }
  for i = 1, n do
    if i % 2 == 1 then
      h[#h + 1] = { role = "user", text = body(chars) }
    else
      h[#h + 1] = { role = "assistant", text = body(chars) }
    end
  end
  return h
end

local function port_of(fn)
  local p = { model = { id = "test:model", call = fn } }
  return p
end

local function saying(text)
  return port_of(function () return { text = text, calls = {}, stop = "done" } end)
end

local function raises(fn, ...)
  local ok, err = pcall(fn, ...)
  return (not ok), tostring(err)
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, val in pairs(v) do out[deep_copy(k)] = deep_copy(val) end
  return out
end

local function same(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not same(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function count_digests(h)
  local n = 0
  for i = 1, #h do
    if h[i].digest == true then n = n + 1 end
  end
  return n
end

-- Every tool result in `h` is answered by a call that is still in `h`.
local function no_orphans(h)
  local ids = {}
  for i = 1, #h do
    local calls = h[i].calls
    if type(calls) == "table" then
      for j = 1, #calls do ids[calls[j].id] = true end
    end
  end
  for i = 1, #h do
    local m = h[i]
    if m.role == "tool" then
      local a = m.call_id or m.id
      if a ~= nil and not ids[a] then return false, i end
    end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- the estimate

function T.an_empty_history_is_not_over_budget()
  local r = compaction.check({})
  assert(r.messages == 0)
  assert(r.estimate == 0)
  assert(r.over == false)
  assert(r.protected == 0 and r.foldable == 0 and r.floor == 0)
  assert(r.window == compaction.defaults.window)
end

function T.the_estimate_is_deterministic()
  local h = conversation(8, 200)
  local a = compaction.check(h).estimate
  local b = compaction.check(h).estimate
  assert(a == b, "the same history estimated twice differed")
  assert(a > 0)
  assert(a == math.floor(a), "the estimate is a whole number")

  local twice = conversation(16, 200)
  local c = compaction.check(twice).estimate
  assert(c >= a * 1.5, "twice the history estimated less than 1.5 times as much")
end

function T.the_estimate_is_monotone()
  local h = {}
  local last = compaction.check(h).estimate
  for i = 1, 12 do
    h[#h + 1] = { role = "user", text = body(50 * i) }
    local now = compaction.check(h).estimate
    assert(now >= last, "appending a message lowered the estimate")
    last = now
  end
end

function T.a_cyclic_message_estimates_and_returns()
  local m = { role = "user", text = "look at me" }
  m.self = m
  m.nested = { back = m, deeper = { m } }
  local n, info = compaction.estimate(m)
  assert(type(n) == "number")
  assert(n == n and n ~= math.huge, "a cyclic message estimated to a non-number")
  assert(info.truncated == true, "a cycle did not set truncated")

  local h = { m, { role = "assistant", text = "fine" } }
  local r = compaction.check(h)
  assert(r.truncated == true)
  assert(r.estimate > 0)
end

function T.a_function_on_a_message_does_not_raise()
  local m = { role = "user", text = "hello", on_done = function () return 1 end }
  local n = compaction.estimate(m)
  assert(n > 0)
  local r = compaction.check({ m })
  assert(r.messages == 1 and r.estimate > 0)
end

function T.the_estimate_reads_every_lua_value()
  assert(compaction.estimate(nil) == 0)
  assert(compaction.estimate(true) == 2)
  assert(compaction.estimate(7) == 2)
  assert(compaction.estimate("") == 1)
  assert(compaction.estimate("abcd") == 2)
  assert(compaction.estimate(print) == 1)
  assert(compaction.estimate({}) == 0)

  -- a table is the sum of its keys and values plus 2 an entry: "a" is 2, 1 is 2, plus 2
  assert(compaction.estimate({ a = 1 }) == 6, tostring(compaction.estimate({ a = 1 })))
  assert(compaction.estimate({ a = 1, b = 2 }) == 12)
  assert(compaction.estimate({ "abcd" }) == 6)     -- key 1 is 2, "abcd" is 2, plus 2

  -- and a message in a history costs its fields plus a flat 4 for the role framing
  local m = { role = "user", text = "abcd" }
  local bare = compaction.estimate(m)
  assert(bare == 12, tostring(bare))
  assert(compaction.check({ m }).estimate == bare + 4,
    "a message in a history did not cost its fields plus the frame")
end

function T.a_very_deep_table_is_truncated_not_overflowed()
  local root = {}
  local at = root
  for _ = 1, 400 do
    local next_one = {}
    at.down = next_one
    at = next_one
  end
  local n, info = compaction.estimate(root)
  assert(type(n) == "number")
  assert(info.truncated == true)
  assert(info.depth <= 12)
end

-- ---------------------------------------------------------------------------
-- plan

function T.a_history_under_headroom_plans_nothing()
  local h = conversation(6, 40)
  local r = compaction.check(h, SMALL)
  assert(r.over == false, "the fixture was already over budget")
  local p, why = compaction.plan(h, SMALL)
  assert(p == nil)
  assert(why == "not over budget", why)
end

function T.the_oldest_span_is_the_one_folded()
  local h = conversation(24, 300)
  local r = compaction.check(h, SMALL)
  assert(r.over == true, "the fixture was not over budget")
  local p = compaction.plan(h, SMALL)
  assert(p, "no plan for an over-budget history")
  assert(p.from == 2, "the span did not start at the first foldable message: " .. tostring(p.from))
  assert(p.to > p.from)
  assert(p.count == p.to - p.from + 1)
  assert(p.removed > 0 and p.after < r.estimate)
  assert(#p.messages == p.count)
  assert(p.messages[1] == h[p.from], "plan.messages holds copies, not the same tables")
end

function T.a_single_message_over_the_window_is_named()
  local h = conversation(10, 300)
  h[4] = { role = "user", text = body(12000) }
  local p, why = compaction.plan(h, { window = 500 })
  assert(p == nil)
  assert(why == "a single message is larger than the window", tostring(why))
  assert(#h[4].text == #body(12000), "the oversized message was truncated")
end

function T.a_span_of_one_is_not_folded()
  local h = {
    { role = "system", text = "be brief" },
    { role = "user", text = body(1200) },
    { role = "user", text = body(1200), pin = true },
    { role = "assistant", text = body(1200) },
    { role = "user", text = body(400) },
    { role = "user", text = body(400) },
    { role = "user", text = body(400) },
    { role = "user", text = body(400) },
    { role = "user", text = body(400) },
    { role = "user", text = body(400) },
  }
  local r = compaction.check(h, SMALL)
  assert(r.over == true)
  assert(r.foldable == 1, "the fixture should leave exactly one foldable message, left " .. r.foldable)
  local p, why = compaction.plan(h, SMALL)
  assert(p == nil)
  assert(why == "one message to fold", tostring(why))
end

function T.a_history_with_no_assistant_message_folds_nothing()
  local h = {}
  for _ = 1, 30 do h[#h + 1] = { role = "user", text = body(200) } end
  local r = compaction.check(h, SMALL)
  assert(r.over == true)
  assert(r.foldable == 0)
  local p, why = compaction.plan(h, SMALL)
  assert(p == nil)
  assert(why == "nothing to fold", tostring(why))
end

function T.the_floor_is_reported_when_nothing_helps()
  local h = conversation(24, 300)
  local lim = { window = 2000, keep_recent = 40 }
  local new_h, r = compaction.compact(saying("a digest"), h, lim)
  assert(new_h == h)
  assert(r.compacted == false)
  assert(r.why == "nothing to fold", tostring(r.why))
  assert(r.floor > r.limit, "the floor did not show the protections cost more than the limit")
end

-- ---------------------------------------------------------------------------
-- the protections

function T.the_system_prompt_survives_every_fold()
  local h = conversation(24, 300)
  local system = h[1]
  local new_h, r = compaction.compact(saying("earlier: the agent read two files."), h, SMALL)
  assert(r.compacted == true, tostring(r.why))
  assert(new_h[1] == system, "the system prompt is not at index 1 by identity")
end

function T.a_system_prompt_in_the_middle_survives()
  local h = conversation(24, 300)
  local system = { role = "system", text = "and always name the file" }
  table.insert(h, 9, system)
  local new_h, r = compaction.compact(saying("earlier: two files were read."), h, SMALL)
  assert(r.compacted == true, tostring(r.why))
  local found = false
  for i = 1, #new_h do
    if new_h[i] == system then found = true end
  end
  assert(found, "a system prompt away from index 1 was folded away")
end

function T.a_pinned_message_survives()
  local h = conversation(24, 300)
  h[5].pin = true
  local pinned = h[5]
  local new_h, r = compaction.compact(saying("earlier: work happened."), h, SMALL)
  assert(r.compacted == true, tostring(r.why))
  local found = false
  for i = 1, #new_h do
    if new_h[i] == pinned then found = true end
  end
  assert(found, "a pinned message was folded")
end

function T.the_recent_tail_survives()
  local h = conversation(24, 300)
  local n = #h
  local tail = {}
  for i = n - 5, n do tail[#tail + 1] = h[i] end
  local new_h, r = compaction.compact(saying("earlier: work happened."), h, SMALL)
  assert(r.compacted == true, tostring(r.why))
  local m = #new_h
  for i = 1, 6 do
    assert(new_h[m - 6 + i] == tail[i], "the recent tail moved or was folded at " .. i)
  end
end

function T.an_unseen_tool_result_is_never_folded()
  local h = conversation(20, 300)
  h[#h + 1] = { role = "assistant", text = "reading both", calls = { { id = "c1", tool = "read" }, { id = "c2", tool = "read" } } }
  local r1 = { role = "tool", call_id = "c1", text = body(300) }
  local r2 = { role = "tool", call_id = "c2", text = body(300) }
  h[#h + 1] = r1
  h[#h + 1] = r2

  local new_h, r = compaction.compact(saying("earlier: files were read."), h, SMALL)
  assert(r.compacted == true, tostring(r.why))
  local seen1, seen2 = false, false
  for i = 1, #new_h do
    if new_h[i] == r1 then seen1 = true end
    if new_h[i] == r2 then seen2 = true end
  end
  assert(seen1 and seen2, "an unseen tool result was folded away")
  assert(no_orphans(new_h))
end

function T.a_fold_never_orphans_a_tool_result()
  -- A fixed list of shapes, so a failure reproduces exactly.
  local shapes = {
    { turns = 4,  fanout = 1, chars = 300 },
    { turns = 6,  fanout = 2, chars = 200 },
    { turns = 8,  fanout = 3, chars = 150 },
    { turns = 10, fanout = 1, chars = 250 },
    { turns = 12, fanout = 2, chars = 120 },
    { turns = 5,  fanout = 4, chars = 180 },
    { turns = 9,  fanout = 2, chars = 400 },
  }
  local tested = 0
  for s = 1, #shapes do
    local shape = shapes[s]
    for _, keep in ipairs({ 0, 2, 6 }) do
      local h = { { role = "system", text = "use the tools" } }
      local id = 0
      for t = 1, shape.turns do
        h[#h + 1] = { role = "user", text = body(shape.chars) }
        local calls = {}
        for k = 1, shape.fanout do
          id = id + 1
          calls[k] = { id = "c" .. id, tool = "read", args = {} }
        end
        h[#h + 1] = { role = "assistant", text = "calling " .. t, calls = calls }
        for k = 1, shape.fanout do
          h[#h + 1] = { role = "tool", call_id = calls[k].id, text = body(shape.chars) }
        end
      end
      assert(no_orphans(h), "the fixture itself orphaned a result")

      local lim = { window = 2000, keep_recent = keep }
      local new_h, r = compaction.compact(saying("earlier: the agent read files and reported."), h, lim)
      local ok, at = no_orphans(new_h)
      assert(ok, string.format("shape %d keep %d orphaned the result at %s", s, keep, tostring(at)))
      if r.compacted then tested = tested + 1 end
      -- and the surviving pinned protections still hold
      assert(new_h[1] == h[1], "the system prompt moved")
    end
  end
  assert(tested > 0, "no shape actually compacted, so the property proved nothing")
end

-- ---------------------------------------------------------------------------
-- the fold

function T.the_fold_replaces_with_one_message()
  local h = conversation(24, 300)
  local p = compaction.plan(h, SMALL)
  assert(p)
  local new_h, r = compaction.compact(saying("earlier: the agent read two files and edited one."), h, SMALL)
  assert(r.compacted == true, tostring(r.why))
  assert(#new_h == #h - (p.count - 1), string.format("expected %d messages, got %d", #h - (p.count - 1), #new_h))
  assert(new_h[p.from].digest == true)
  assert(new_h[p.from].folded == p.count)
  assert(new_h[p.from].role == "user")
  assert(r.folded == p.count)
end

function T.surviving_messages_are_the_same_tables()
  local h = conversation(24, 300)
  local p = compaction.plan(h, SMALL)
  local new_h = compaction.compact(saying("earlier: work happened, files were read."), h, SMALL)
  for i = 1, p.from - 1 do
    assert(new_h[i] == h[i], "a message before the span was copied")
  end
  for i = p.to + 1, #h do
    assert(new_h[i - (p.count - 1)] == h[i], "a message after the span was copied")
  end
end

function T.a_digest_is_foldable_again()
  local h = conversation(60, 300)
  local port = saying("earlier: the agent read files, edited one, and left tests failing.")
  local one, r1 = compaction.compact(port, h, SMALL)
  assert(r1.compacted == true, tostring(r1.why))
  assert(count_digests(one) == 1)

  -- the run carries on until it is over budget again
  for i = 1, 30 do
    one[#one + 1] = { role = (i % 2 == 1) and "user" or "assistant", text = body(300) }
  end
  assert(compaction.check(one, SMALL).over == true, "the fixture did not go over budget again")

  local p = compaction.plan(one, SMALL)
  assert(p and p.from == 2, "the second fold did not start at the old digest")
  assert(one[2].digest == true)

  local two, r2 = compaction.compact(port, one, SMALL)
  assert(r2.compacted == true, tostring(r2.why))
  assert(count_digests(two) == 1, "compacting twice left " .. count_digests(two) .. " digests")
end

function T.still_over_budget_is_reported_as_success_and_over()
  -- Far above the window, and with keep_recent holding a lot back, one fold cannot
  -- reach the goal. That is success and insufficiency at once, and both are reported.
  local h = conversation(40, 600)
  local lim = { window = 2000, keep_recent = 12 }
  local new_h, r = compaction.compact(saying("earlier: a long stretch of work."), h, lim)
  assert(r.compacted == true, tostring(r.why))
  assert(r.over == true, "a still-too-large history reported as under budget")
  assert(#new_h < #h)
end

-- ---------------------------------------------------------------------------
-- the digest the model writes

function T.an_empty_digest_is_refused()
  local h = conversation(24, 300)
  local new_h, r = compaction.compact(saying(""), h, SMALL)
  assert(new_h == h, "the history was not returned by identity")
  assert(r.compacted == false)
  assert(r.why == "the digest is empty", tostring(r.why))

  -- an empty digest is weather, so it is retried the stated number of times
  local calls = 0
  local port = port_of(function () calls = calls + 1; return { text = "", calls = {}, stop = "done" } end)
  local again, r2 = compaction.compact(port, h, { window = 2000, attempts = 3 })
  assert(again == h)
  assert(calls == 3, "an empty digest was tried " .. calls .. " times, expected 3")
  assert(r2.why == "the digest is empty", tostring(r2.why))
end

function T.a_whitespace_digest_is_refused()
  local h = conversation(24, 300)
  local new_h, r = compaction.compact(saying("\n\n\n"), h, SMALL)
  assert(new_h == h)
  assert(r.why == "the digest is empty", tostring(r.why))

  local tabs = compaction.compact(saying("  \t  \r\n "), h, SMALL)
  assert(tabs == h)
end

function T.a_digest_bigger_than_the_span_is_refused()
  local h = conversation(24, 300)
  local wall = body(200000)
  local calls = 0
  local port = port_of(function () calls = calls + 1; return { text = wall, calls = {}, stop = "done" } end)
  local new_h, r = compaction.compact(port, h, { window = 2000, attempts = 4 })
  assert(new_h == h)
  assert(r.compacted == false)
  assert(r.why == "the digest is not smaller than what it replaces", tostring(r.why))
  assert(calls == 1, "a model that ignored the ceiling was asked again, " .. calls .. " times")
end

function T.a_non_string_digest_is_treated_as_empty()
  local h = conversation(24, 300)
  local port = port_of(function () return { text = 42, calls = {}, stop = "done" } end)
  local new_h, r = compaction.compact(port, h, SMALL)
  assert(new_h == h)
  assert(r.why == "the digest is empty", tostring(r.why))
  for i = 1, #new_h do
    assert(new_h[i].text ~= "42", "a number was turned into digest text")
  end
end

function T.a_refusal_is_reported_and_not_retried()
  local h = conversation(24, 300)
  local calls = 0
  local port = port_of(function ()
    calls = calls + 1
    return nil, { port = "model", call = "call", code = "refused", message = "the model declined" }
  end)
  local new_h, r = compaction.compact(port, h, { window = 2000, attempts = 4 })
  assert(new_h == h)
  assert(calls == 1, "a refusal was retried " .. calls .. " times")
  assert(r.why == "the model would not write the digest", tostring(r.why))

  -- and the same when the refusal arrives as a reply rather than an error
  local said = 0
  local port2 = port_of(function ()
    said = said + 1
    return { text = "", calls = {}, stop = "refused" }
  end)
  local h2, r2 = compaction.compact(port2, h, { window = 2000, attempts = 4 })
  assert(h2 == h)
  assert(said == 1, "a refused reply was retried")
  assert(r2.why == "the model would not write the digest", tostring(r2.why))
end

function T.a_timeout_is_retried_then_reported()
  local h = conversation(24, 300)
  local calls = 0
  local port = port_of(function ()
    calls = calls + 1
    return nil, { port = "model", call = "call", code = "timeout", message = "deadline passed" }
  end)
  local new_h, r = compaction.compact(port, h, { window = 2000, attempts = 2 })
  assert(new_h == h)
  assert(calls == 2, "a timeout was tried " .. calls .. " times, expected 2")
  assert(r.why == "the digest timed out", tostring(r.why))
end

function T.an_unreachable_model_is_reported_after_every_attempt()
  local h = conversation(24, 300)
  local calls = 0
  local port = port_of(function ()
    calls = calls + 1
    return nil, { port = "model", call = "call", code = "unavailable", message = "nothing is listening" }
  end)
  local new_h, r = compaction.compact(port, h, { window = 2000, attempts = 3 })
  assert(new_h == h)
  assert(calls == 3)
  assert(r.why == "the model could not be reached: nothing is listening", tostring(r.why))
end

function T.a_port_that_raises_is_a_failure_not_a_crash()
  local h = conversation(24, 300)
  local port = port_of(function () error("the transport blew up") end)
  local new_h, r = compaction.compact(port, h, { window = 2000, attempts = 2 })
  assert(new_h == h)
  assert(r.compacted == false)
  assert(r.why:find("the model could not be reached") == 1, tostring(r.why))
end

function T.a_transient_failure_then_success_compacts()
  local h = conversation(24, 300)
  local calls = 0
  local port = port_of(function ()
    calls = calls + 1
    if calls == 1 then
      return nil, { port = "model", call = "call", code = "unavailable", message = "flaky" }
    end
    return { text = "earlier: the agent read two files and edited one.", calls = {}, stop = "done" }
  end)
  local new_h, r = compaction.compact(port, h, { window = 2000, attempts = 2 })
  assert(calls == 2)
  assert(r.compacted == true, tostring(r.why))
  assert(new_h ~= h)
  assert(#new_h < #h)
end

-- The vocabulary spec/port.md actually uses: the model's turn is "agent", and a tool
-- message carries the call it answers as `id`. A compaction that knew only "assistant"
-- and only `call_id` would fold nothing at all here, and would orphan results if it did.
function T.the_port_vocabulary_is_read_as_the_same_thing()
  local h = { { role = "system", text = "use the tools" } }
  local id = 0
  for t = 1, 10 do
    h[#h + 1] = { role = "user", text = body(400) }
    id = id + 1
    local call = { id = "c" .. id, tool = "read", args = { path = "src/turn.lua" } }
    h[#h + 1] = { role = "agent", text = "reading, turn " .. t, calls = { call } }
    h[#h + 1] = { role = "tool", id = call.id, ok = true, text = body(400) }
  end
  assert(no_orphans(h), "the fixture itself orphaned a result")

  local r = compaction.check(h, SMALL)
  assert(r.over == true, "the fixture was not over budget")
  assert(r.foldable > 0, 'an "agent" turn was not read as the model having spoken')

  -- the tail after the last agent turn is unseen and is held back, exactly as with
  -- "assistant": the last agent message and the tool result after it both survive
  local last_agent, last_result = h[#h - 1], h[#h]
  local new_h, rc = compaction.compact(saying("earlier: the agent read files."), h, SMALL)
  assert(rc.compacted == true, tostring(rc.why))
  assert(no_orphans(new_h), 'a fold with port.md\'s own vocabulary orphaned a tool result')
  local seen_agent, seen_result = false, false
  for i = 1, #new_h do
    if new_h[i] == last_agent then seen_agent = true end
    if new_h[i] == last_result then seen_result = true end
  end
  assert(seen_agent and seen_result, "the unseen tail was folded away")
end

-- The two accommodations for a host wired to the earlier draft of the model port.
function T.the_earlier_port_shape_still_works()
  local h = conversation(24, 300)

  -- `complete` where `call` is absent, and no model id is demanded of it
  local seen = {}
  local port = { model = { complete = function (request)
    seen[#seen + 1] = request
    return { text = "earlier: work happened and files were read.", calls = {}, stop = "done" }
  end } }
  local new_h, r = compaction.compact(port, h, SMALL)
  assert(r.compacted == true, tostring(r.why))
  assert(#seen == 1 and #new_h < #h, "the complete fallback did not carry the digest")
  assert(type(seen[1].system) == "string" and #seen[1].messages == 1)

  -- `err.kind` where `err.code` is absent: still a timeout, still retried
  local calls = 0
  local timing_out = port_of(function ()
    calls = calls + 1
    return nil, { kind = "timeout", message = "deadline passed" }
  end)
  local same_h, r2 = compaction.compact(timing_out, h, { window = 2000, attempts = 2 })
  assert(same_h == h)
  assert(calls == 2, "an err.kind timeout was tried " .. calls .. " times")
  assert(r2.why == "the digest timed out", tostring(r2.why))

  -- and a refusal read off `kind` is still not retried
  local said = 0
  local refusing = port_of(function ()
    said = said + 1
    return nil, { kind = "refused", message = "no" }
  end)
  local _, r3 = compaction.compact(refusing, h, { window = 2000, attempts = 4 })
  assert(said == 1, "an err.kind refusal was retried")
  assert(r3.why == "the model would not write the digest", tostring(r3.why))
end

function T.a_reply_that_is_not_a_table_is_a_failed_call()
  local h = conversation(24, 300)
  for _, answer in ipairs({ "a digest, but bare", 42, true }) do
    local port = port_of(function () return answer end)
    local new_h, r = compaction.compact(port, h, { window = 2000, attempts = 1 })
    assert(new_h == h, "a malformed reply changed the history")
    assert(r.compacted == false)
    assert(r.why:find("the model could not be reached") == 1, tostring(r.why))
  end
end

-- port.md promises a message safe to show a model and free of host absolute paths. A
-- raise escapes that promise, because Lua prepends "<chunk>:<line>: " and the chunk is
-- the host's own path. The reason compaction reports must not carry it onward.
function T.a_raise_does_not_carry_a_host_path_into_the_report()
  local h = conversation(24, 300)
  local port = port_of(function () error("the transport refused the connection") end)
  local new_h, r = compaction.compact(port, h, { window = 2000, attempts = 1 })
  assert(new_h == h)
  assert(r.why == "the model could not be reached: the transport refused the connection",
    tostring(r.why))
  assert(not r.why:find("compaction_test", 1, true), "the reason names a host file")
  assert(not r.why:find("%.lua:%d"), "the reason carries a source location: " .. r.why)

  -- a raise with no message at all is still a stated failure and still no path
  local silent = port_of(function () error() end)
  local _, r2 = compaction.compact(silent, h, { window = 2000, attempts = 1 })
  assert(r2.compacted == false)
  assert(r2.why:find("the model could not be reached") == 1, tostring(r2.why))
  assert(not r2.why:find("%.lua:%d"), tostring(r2.why))

  -- a message that merely contains a colon is not trimmed
  local colonic = port_of(function () error("http://host:80 is down", 0) end)
  local _, r3 = compaction.compact(colonic, h, { window = 2000, attempts = 1 })
  assert(r3.why == "the model could not be reached: http://host:80 is down", tostring(r3.why))
end

-- ---------------------------------------------------------------------------
-- bad arguments raise

function T.a_missing_port_raises()
  local h = conversation(24, 300)
  local bad, msg = raises(compaction.compact, nil, h, SMALL)
  assert(bad, "a nil port did not raise")
  assert(msg:find("model%.call"), msg)

  bad, msg = raises(compaction.compact, {}, h, SMALL)
  assert(bad, "a port with no model did not raise")
  assert(msg:find("model%.call"), msg)

  bad, msg = raises(compaction.compact, { model = {} }, h, SMALL)
  assert(bad, "a model port with no call did not raise")
  assert(msg:find("model%.call"), msg)
end

function T.a_model_port_without_an_id_raises()
  local h = conversation(24, 300)
  local port = { model = { call = function () return { text = "x" } end } }
  local bad, msg = raises(compaction.compact, port, h, SMALL)
  assert(bad, "a call port with no model id did not raise")
  assert(msg:find("model id"), msg)

  -- naming it in limits is enough, and the id it names is the id the request carries
  local seen = {}
  local port2 = { model = { call = function (request)
    seen[#seen + 1] = request
    return { text = "earlier: work happened and files were read.", calls = {}, stop = "done" }
  end } }
  local new_h, r = compaction.compact(port2, h, { window = 2000, model = "test:model" })
  assert(r.compacted == true, tostring(r.why))
  assert(new_h ~= h and #new_h < #h, "naming the model in limits did not let the fold happen")
  assert(#seen == 1, "the digest took " .. #seen .. " calls")
  assert(seen[1].model == "test:model", "the request carried " .. tostring(seen[1].model))

  -- and port.model.id is the other place it may come from
  local seen2 = {}
  local port3 = { model = { id = "wired:model", call = function (request)
    seen2[#seen2 + 1] = request
    return { text = "earlier: work happened and files were read.", calls = {}, stop = "done" }
  end } }
  local _, r3 = compaction.compact(port3, h, SMALL)
  assert(r3.compacted == true, tostring(r3.why))
  assert(seen2[1].model == "wired:model", "the request carried " .. tostring(seen2[1].model))
end

function T.a_plan_applied_to_a_different_history_raises()
  local h = conversation(24, 300)
  local p = compaction.plan(h, SMALL)
  assert(p)
  h[#h + 1] = { role = "user", text = "one more thing" }
  local bad, msg = raises(compaction.apply, h, p, "earlier: things happened.")
  assert(bad, "applying a stale plan did not raise")
  assert(msg:find("history"), msg)

  local other = conversation(24, 300)
  local bad2 = raises(compaction.apply, other, p, "earlier: things happened.")
  assert(bad2, "applying a plan to a different history of the same length did not raise")
end

function T.an_unknown_limit_key_raises()
  local h = conversation(4, 40)
  local bad, msg = raises(compaction.check, h, { keep_recents = 4 })
  assert(bad, "a misspelt limit key did not raise")
  assert(msg:find("keep_recents"), msg)

  bad, msg = raises(compaction.plan, h, { windows = 10 })
  assert(bad and msg:find("windows"), msg)
end

function T.bad_limit_values_raise()
  local h = conversation(4, 40)
  local bad_ones = {
    { headroom = 0 },
    { headroom = 2 },
    { headroom = 0.4, target = 0.9 },
    { keep_recent = -1 },
    { keep_recent = 1.5 },
    { attempts = 0 },
    { window = 0 },
    { window = -1 },
    { window = "big" },
    { model = 7 },
  }
  for i = 1, #bad_ones do
    local bad = raises(compaction.check, h, bad_ones[i])
    assert(bad, "limits case " .. i .. " did not raise")
  end
  assert(raises(compaction.check, h, "limits"), "a non-table limits did not raise")
end

function T.a_malformed_history_raises()
  assert(raises(compaction.check, "history"), "a string history did not raise")
  assert(raises(compaction.check, { { role = "user" }, 7 }), "a non-table entry did not raise")
  local holed = { { role = "user", text = "a" } }
  holed[3] = { role = "user", text = "c" }
  assert(raises(compaction.check, holed), "a history with a hole did not raise")
  assert(raises(compaction.check, { named = { role = "user" } }), "a keyed history did not raise")
end

function T.apply_refuses_a_digest_that_is_not_a_string()
  local h = conversation(24, 300)
  local p = compaction.plan(h, SMALL)
  assert(raises(compaction.apply, h, p, 42), "a number digest did not raise")
  assert(raises(compaction.prompt, "not a plan"), "prompt on a non-plan did not raise")
end

-- ---------------------------------------------------------------------------
-- what compaction leaves alone

function T.the_unchanged_history_is_returned_by_identity()
  local h = conversation(24, 300)
  local small = conversation(4, 40)
  local cases = {
    { port = saying("x-y"),                  history = small, limits = SMALL },      -- not over budget
    { port = saying(""),                     history = h,     limits = SMALL },      -- empty digest
    { port = saying(body(200000)),           history = h,     limits = SMALL },      -- digest too big
    { port = port_of(function () return nil, { code = "timeout", message = "slow" } end),
      history = h, limits = { window = 2000, attempts = 1 } },
    { port = port_of(function () return nil, { code = "refused", message = "no" } end),
      history = h, limits = SMALL },
    { port = saying("fine"), history = h, limits = { window = 2000, keep_recent = 100 } }, -- nothing to fold
  }
  for i = 1, #cases do
    local c = cases[i]
    local new_h, r = compaction.compact(c.port, c.history, c.limits)
    assert(new_h == c.history, "case " .. i .. " did not return the history by identity")
    assert(r.compacted == false, "case " .. i .. " claimed to have compacted")
    assert(type(r.why) == "string" and r.why ~= "", "case " .. i .. " gave no reason")
  end
end

function T.nothing_is_mutated()
  local runs = {
    { port = saying("earlier: two files were read and one was edited."), limits = { window = 2000 } },
    { port = saying(""), limits = { window = 2000 } },
    { port = port_of(function () return nil, { code = "timeout", message = "slow" } end), limits = { window = 2000, attempts = 2 } },
  }
  for i = 1, #runs do
    local h = conversation(24, 300)
    local before = deep_copy(h)
    local limits = runs[i].limits
    local limits_before = deep_copy(limits)
    local defaults_before = deep_copy(compaction.defaults)

    compaction.compact(runs[i].port, h, limits)

    assert(same(before, h), "run " .. i .. " mutated the history")
    assert(same(limits_before, limits), "run " .. i .. " mutated limits")
    assert(same(defaults_before, compaction.defaults), "run " .. i .. " mutated defaults")
  end
end

function T.compact_calls_the_model_once_per_attempt_and_no_tool()
  local h = conversation(24, 300)
  local calls = 0
  local forbidden = setmetatable({}, { __index = function (_, k)
    error("compaction reached for " .. tostring(k))
  end })
  local port = {
    model = { id = "test:model", call = function () calls = calls + 1; return { text = "earlier: work happened, files were read.", stop = "done" } end },
    fs = forbidden, sh = forbidden, clock = forbidden, ask = forbidden, log = forbidden,
  }
  local new_h, r = compaction.compact(port, h, SMALL)
  assert(r.compacted == true, tostring(r.why))
  assert(calls == 1, "one successful compaction made " .. calls .. " model calls")
  assert(#new_h < #h)
end

function T.compact_does_not_re_enter()
  local h = conversation(24, 300)
  local depth, inner_ran = 0, false
  local port
  port = port_of(function ()
    depth = depth + 1
    if depth == 1 then
      local other = conversation(24, 300)
      compaction.compact(port, other, SMALL)
      inner_ran = true
    end
    return { text = "earlier: work happened and files were read.", stop = "done" }
  end)
  local new_h, r = compaction.compact(port, h, SMALL)
  assert(inner_ran, "the inner compaction never ran")
  assert(r.compacted == true, tostring(r.why))
  assert(#new_h < #h)
end

-- ---------------------------------------------------------------------------
-- the prompt

function T.the_prompt_is_buildable_with_no_model()
  local h = conversation(24, 300)
  h[4] = { role = "assistant", text = body(120), calls = { { id = "c1", tool = "read", args = { path = "src/turn.lua" } } } }
  h[5] = { role = "tool", call_id = "c1", text = body(120) }
  h[6] = { role = "user", text = { not_a_string = true } }
  local p = compaction.plan(h, SMALL)
  assert(p)
  local messages = compaction.prompt(p, SMALL)
  assert(#messages == 2)
  assert(messages[1].role == "system")
  assert(messages[2].role == "user")
  assert(type(messages[1].text) == "string" and #messages[1].text > 0)
  assert(type(messages[2].text) == "string" and #messages[2].text > 0)
  assert(messages[1].text:find("%d+ words"), "the instruction states no length ceiling")
  assert(messages[2].text:find("%[user%]"), "the rendering does not label the roles")
  assert(messages[2].text:find("%[assistant%]"), "the rendering does not label the roles")
  assert(messages[2].text:find("<table>"), "a non-string field did not render as its type")
  assert(not messages[2].text:find("table: 0x"), "an address reached the prompt")
  assert(not messages[2].text:find("function: "), "a function reached the prompt")
  for i = 1, 2 do
    for _, v in pairs(messages[i]) do
      assert(type(v) ~= "function", "the prompt carries a function value")
    end
  end
end

function T.the_prompt_names_a_smaller_ceiling_for_a_tighter_goal()
  local h = conversation(24, 300)
  local p = compaction.plan(h, SMALL)
  local wide = compaction.prompt(p, SMALL)
  local tight = compaction.prompt(p, { window = 2000, target = 0.05, headroom = 0.75 })
  local function words_in(m)
    return tonumber(m[1].text:match("(%d+) words"))
  end
  assert(words_in(tight) ~= nil and words_in(wide) ~= nil, "the instruction states no ceiling")
  -- strictly smaller, so the assertion cannot be satisfied by both landing on the floor
  assert(words_in(wide) > words_in(tight),
    string.format("a tighter goal did not tighten the ceiling: %d then %d", words_in(wide), words_in(tight)))

  -- and the floor holds: a goal already blown still asks for a writable digest
  local none = compaction.prompt(p, { window = 2000, target = 0.01, headroom = 0.02 })
  assert(words_in(none) == 20, "the ceiling fell below its floor: " .. tostring(words_in(none)))
end

-- ---------------------------------------------------------------------------
-- against the real port double

function T.the_scripted_model_double_folds_a_history()
  local loaded, double = pcall(require, "double")
  assert(loaded, "src/double.lua did not load: " .. tostring(double))
  local m = double.model { replies = { "earlier: the agent read two files and edited one." }, after = "repeat" }
  local h = conversation(24, 300)
  local new_h, r = compaction.compact({ model = m }, h, { window = 2000, model = "test:model" })
  assert(r.compacted == true, tostring(r.why))
  assert(#new_h < #h)
  assert(#m.seen == 1, "the digest took " .. #m.seen .. " calls")
  assert(m.seen[1].model == "test:model", "the request did not carry the model id")
  assert(type(m.seen[1].system) == "string" and #m.seen[1].system > 0,
    "the instruction did not travel as the request's system prompt")
  assert(#m.seen[1].messages == 1, "the span went as " .. #m.seen[1].messages .. " messages")
  assert(m.seen[1].tools == nil, "compaction offered the model a tool")
end

-- ---------------------------------------------------------------------------
-- rule 1, applied here

function T.the_module_names_no_vendor()
  local where = debug.getinfo(compaction.estimate, "S").source
  assert(where:sub(1, 1) == "@", "cannot locate the module source")
  local f = assert(loadfile and io.open(where:sub(2), "r"))
  local text = f:read("*a")
  f:close()
  local banned = { "io%.", "os%.", "socket", "http", 'require "', "require%(" }
  for i = 1, #banned do
    assert(not text:find(banned[i]), "the module names " .. banned[i])
  end
  assert(not text:find("print%("), "the module prints")
end

return T
