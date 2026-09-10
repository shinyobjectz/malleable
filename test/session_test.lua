-- session -- the transcript, its codec and its store, proved against a table. No
-- network, no disk, no subprocess, no clock. Each test asserts with plain `assert`
-- and prints nothing on success.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local session = require("session")

local T = {}

-- ------------------------------------------------------------------- doubles

-- A store and a clock in a table. `cfg` scripts the ways a world misbehaves:
--   write_fails   = reason           every write returns nil, reason
--   read_fails    = { id = reason }  that id's read returns nil, reason
--   read_returns  = { id = value }   that id's read returns the value verbatim
--   list_fails    = reason           list returns nil, reason
--   list_returns  = { ... }          list returns that value verbatim
--   delete_fails  = reason           every delete returns nil, reason
--   now           = number | fn      what the clock says
local function world(cfg)
  cfg = cfg or {}
  local p = { data = {}, writes = 0, reads = 0, deletes = 0 }

  p.store = {
    write = function (id, text)
      p.writes = p.writes + 1
      if cfg.write_fails then return nil, cfg.write_fails end
      p.data[id] = text
      return true
    end,
    read = function (id)
      p.reads = p.reads + 1
      if cfg.read_fails and cfg.read_fails[id] ~= nil then return nil, cfg.read_fails[id] end
      if cfg.read_returns and cfg.read_returns[id] ~= nil then return cfg.read_returns[id] end
      local v = p.data[id]
      if v == nil then return nil, "missing" end
      return v
    end,
    list = function ()
      if cfg.list_fails then return nil, cfg.list_fails end
      if cfg.list_returns ~= nil then return cfg.list_returns end
      local out = {}
      for id in pairs(p.data) do out[#out + 1] = id end
      table.sort(out)
      return out
    end,
    delete = function (id)
      p.deletes = p.deletes + 1
      if cfg.delete_fails then return nil, cfg.delete_fails end
      if p.data[id] == nil then return nil, "missing" end
      p.data[id] = nil
      return true
    end,
  }

  p.clock = {
    now = function ()
      local v = cfg.now
      if v == nil then return 1757462400.5 end
      if type(v) == "function" then return v() end
      return v
    end,
  }

  return p
end

local function keys_of(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end

-- One transcript with a message of every speaker.
local function peopled()
  local s = session.new { agent = "reviewer", model = "a-model", started = 100 }
  assert(session.system(s, "be careful", 1))
  assert(session.user(s, "read the file", 2))
  assert(session.model(s, "reading it", 3))
  assert(session.call(s, "read", { path = "a.txt", depth = 2 }, "c1", 4))
  assert(session.result(s, "c1", "the text", nil, 5))
  return s
end

local function same_message(a, b)
  if a.speaker ~= b.speaker or a.at ~= b.at then return false end
  if a.body ~= b.body or a.tool ~= b.tool or a.call_id ~= b.call_id then return false end
  if a.ok ~= b.ok or a.refused ~= b.refused then return false end
  if (a.args == nil) ~= (b.args == nil) then return false end
  if a.args then
    if keys_of(a.args) ~= keys_of(b.args) then return false end
    for k, v in pairs(a.args) do
      if b.args[k] ~= v then return false end
    end
  end
  return true
end

-- ------------------------------------------------- round trip and the codec

function T.a_transcript_survives_a_round_trip()
  local s = peopled()
  local p = world()
  local id = assert(session.save(s, p))
  local back = assert(session.load(p, id))

  assert(session.count(back) == session.count(s), "the count changed")
  assert(back.agent == "reviewer" and back.model == "a-model" and back.started == 100)
  assert(back.id == id)
  for i = 1, session.count(s) do
    assert(same_message(session.at(s, i), session.at(back, i)), "message " .. i .. " changed")
  end
  local call = session.at(back, 4)
  assert(call.speaker == "call" and call.tool == "read")
  assert(call.args.path == "a.txt" and call.args.depth == 2)
  local result = session.at(back, 5)
  assert(result.ok == true and result.refused == false and result.body == "the text")
end

function T.the_record_is_what_the_encoder_would_write()
  -- save assembles the record from pre-encoded messages; it must land on exactly the
  -- bytes session.encode would give the same table, or the two would drift apart.
  local s = peopled()
  local p = world()
  local id = assert(session.save(s, p))
  local by_hand = assert(session.encode {
    agent = s.agent, format = 1, id = id, messages = session.messages(s),
    model = s.model, started = s.started,
  })
  assert(p.data[id] == by_hand, "the record is not what the encoder writes")
  assert(by_hand:sub(1, 1) == "{" and by_hand:find('"format":1', 1, true), "no format in the record")
end

function T.an_empty_session_saves_and_loads()
  local s = session.new()
  local p = world()
  assert(s.id == nil)
  local id = assert(session.save(s, p))
  assert(type(id) == "string" and id ~= "")
  assert(s.id == id, "save did not set the id it minted")
  assert(p.data[id]:find('"messages":[]', 1, true), "an empty transcript is not an empty array")
  local back = assert(session.load(p, id))
  assert(session.count(back) == 0)
  assert(#session.messages(back) == 0)
  assert(session.last(back) == nil)

  -- a record that names no id loads under the id it was read with, so a listing and a
  -- load agree about what to call it
  p.data.anonymous = '{"format":1,"messages":[]}'
  local nameless = assert(session.load(p, "anonymous"))
  assert(nameless.id == "anonymous", "a record with no id lost its name: " .. tostring(nameless.id))
  assert(session.header(nameless).id == "anonymous", "the header disagrees with the load")
  local seen = false
  for _, row in ipairs(assert(session.list(p))) do
    if row.id == "anonymous" then seen = true; assert(row.count == 0 and row.broken == nil) end
  end
  assert(seen, "the record with no id is not in the listing")
end

function T.every_escape_comes_back()
  local high = {}
  for b = 128, 255 do high[#high + 1] = string.char(b) end
  local body = "/" .. '"' .. "\\" .. "\t" .. "\n" .. "\r" .. "\f" .. "\b"
             .. "\0" .. string.char(31) .. string.char(127) .. table.concat(high)

  local text = assert(session.encode { body = body })
  assert(text:find('\\"', 1, true), "a quote was not escaped")
  assert(text:find("\\\\", 1, true), "a backslash was not escaped")
  assert(not text:find("\\/", 1, true), "a slash was escaped")
  assert(text:find("/", 1, true), "the slash went missing")
  assert(text:find("\\t", 1, true) and text:find("\\n", 1, true), "no short form for tab or newline")
  assert(text:find("\\r", 1, true) and text:find("\\f", 1, true) and text:find("\\b", 1, true),
         "no short form for return, feed or backspace")
  assert(text:find("\\u0000", 1, true), "a nul byte was not escaped")
  assert(text:find("\\u001f", 1, true), "byte 0x1f was not escaped")
  assert(text:find(string.char(127), 1, true), "byte 0x7f did not go out verbatim")
  assert(text:find(string.char(200), 1, true), "a high byte did not go out verbatim")

  local back = assert(session.decode(text))
  assert(back.body == body, "the body did not come back byte for byte")
  assert(#back.body == #body)
end

function T.an_embedded_nul_is_not_a_terminator()
  local body = "before\0after"
  local text = assert(session.encode { body = body })
  assert(text:find("\\u0000", 1, true), "the nul did not become six characters")
  assert(not text:find("before\0", 1, true), "a raw nul reached the output")
  local back = assert(session.decode(text))
  assert(back.body == body and #back.body == 12, "the nul cut the string short")
end

function T.a_float_stays_a_float_and_an_integer_stays_an_integer()
  local text = assert(session.encode { f = 1.0, i = 1 })
  local back = assert(session.decode(text))
  assert(back.f == 1.0 and back.i == 1, "the values changed")
  if math.type then
    assert(text:find('"f":1.0', 1, true), "a float lost its point: " .. text)
    assert(text:find('"i":1,', 1, true) or text:find('"i":1}', 1, true), "an integer grew a point")
    assert(math.type(back.f) == "float", "a float came back as an integer")
    assert(math.type(back.i) == "integer", "an integer came back as a float")
  end
end

function T.an_awkward_float_is_short_and_exact()
  local cases = { 0.1, 1 / 3, 1e308, 5e-324, -0.0 }
  for i = 1, #cases do
    local v = cases[i]
    local text = assert(session.encode(v))
    assert(tonumber(text) == v, "the float did not read back: " .. text)
    local longest = string.format("%.17g", v)
    if not longest:find("[%.eE]") then longest = longest .. ".0" end
    assert(#text <= #longest, "the float was written longer than it needs: " .. text)
    assert(text:find("[%.eE]"), "a float lost its point: " .. text)
    assert(session.decode(text) == v, "the float changed through decode: " .. text)
  end
  assert(session.encode(0.1) == "0.1", "0.1 is not written as 0.1")
  assert(1 / session.decode(session.encode(-0.0)) == -math.huge, "negative zero lost its sign")
end

function T.not_a_number_is_refused()
  local nan = 0 / 0
  for _, v in ipairs({ nan, math.huge, -math.huge }) do
    local text, why = session.encode { messages = { { args = { n = v } } } }
    assert(text == nil, "a number that is not a number encoded")
    assert(why:find("not a number", 1, true), why)
    assert(why:find(".messages[1].args.n", 1, true), "the path is missing: " .. why)
  end

  local s = session.new()
  assert(session.user(s, "hi", 1))
  assert(session.call(s, "count", { n = nan }, "c1", 2))
  local p = world()
  local id, why = session.save(s, p)
  assert(id == nil, "an unencodable session saved")
  assert(why:find("cannot encode message 2", 1, true), why)
  assert(why:find("not a number: nan at .args.n", 1, true), why)
  assert(p.writes == 0, "the store was written to")
end

function T.encoding_is_deterministic()
  local one = {}
  one.b, one.a, one.c = 1, 2, 3
  local two = {}
  two.c, two.a, two.b = 3, 2, 1
  local want = '{"a":2,"b":1,"c":3}'
  assert(session.encode(one) == want, session.encode(one))
  assert(session.encode(two) == want, session.encode(two))
  assert(session.encode(one) == session.encode(one), "two encodings of one table differ")
  assert(session.encode({}) == "{}", "an empty table is not an empty object")
end

function T.null_survives_both_ways()
  assert(session.encode(session.null) == "null")
  local back = assert(session.decode('{"a":null}'))
  assert(back.a == session.null, "null decoded to something else")
  assert(session.encode(back) == '{"a":null}', "null did not re-encode")
  local list = assert(session.decode("[1,null,2]"))
  assert(#list == 3 and list[2] == session.null, "null vanished from an array")
end

-- ------------------------------------------------------ the decoder under attack

function T.deep_nesting_is_refused_not_crashed()
  local hostile = string.rep("[", 100000)
  local ok, v, why = pcall(session.decode, hostile)
  assert(ok, "a hundred thousand brackets raised: " .. tostring(v))
  assert(v == nil, "a hundred thousand brackets decoded")
  assert(why:find("too deep", 1, true), why)
  assert(why:find("at byte 201", 1, true), "the offset is wrong: " .. why)

  -- the encoder has the same limit, and refuses with a path
  local deep = {}
  local tip = deep
  for _ = 1, 400 do
    tip.a = {}
    tip = tip.a
  end
  local text, why2 = session.encode(deep)
  assert(text == nil, "a table nested past the limit encoded")
  assert(why2:find("too deep", 1, true), why2)
end

function T.a_self_referential_table_is_refused()
  local t = {}
  t.self = t
  local text, why = session.encode(t)
  assert(text == nil, "a cycle encoded")
  assert(why == "cycle at .self", why)

  local inner = { n = 1 }
  local shared = { one = inner, two = inner }
  assert(session.encode(shared) == '{"one":{"n":1},"two":{"n":1}}', "a shared value was called a cycle")

  local list = {}
  list[1] = { deep = list }
  local text2, why2 = session.encode(list)
  assert(text2 == nil and why2 == "cycle at [1].deep", tostring(why2))
end

function T.sloppy_json_is_refused_with_a_position()
  local cases = {
    { '{"a":1,}', 8 },
    { '{a:1}', 2 },
    { "{'a':1}", 2 },
    { '[1 2]', 4 },
    { '01', 1 },
    { '.5', 1 },
    { '5.', 3 },
    { '0x10', 2 },
    { 'NaN', 1 },
    { 'Infinity', 1 },
    { 'undefined', 1 },
    { '//comment', 1 },
    { '{"a":1} trailing', 9 },
    { '"a\nb"', 3 },
    { '', 1 },
    { '[1,]', 4 },
    { '{"a"1}', 5 },
    { '+1', 1 },
    { '[1,2', 5 },
    { '"unclosed', 10 },
  }
  for i = 1, #cases do
    local text, offset = cases[i][1], cases[i][2]
    local ok, v, why = pcall(session.decode, text)
    assert(ok, "decode raised on " .. string.format("%q", text) .. ": " .. tostring(v))
    assert(v == nil, "sloppy input was accepted: " .. string.format("%q", text))
    assert(type(why) == "string" and why ~= "", "no reason for " .. string.format("%q", text))
    assert(why:find("at byte " .. offset, 1, true),
           string.format("%q wanted byte %d, got %q", text, offset, why))
  end
end

function T.a_lone_surrogate_is_refused()
  local text, why = session.decode('"\\ud800"')
  assert(text == nil and why:find("lone surrogate", 1, true), tostring(why))
  local text2, why2 = session.decode('"\\udc00"')
  assert(text2 == nil and why2:find("lone surrogate", 1, true), tostring(why2))
  local text3, why3 = session.decode('"\\ud800\\u0041"')
  assert(text3 == nil and why3:find("lone surrogate", 1, true), tostring(why3))

  local grin = assert(session.decode('"\\ud83d\\ude00"'))
  assert(#grin == 4, "a surrogate pair did not become one codepoint")
  assert(grin == string.char(240, 159, 152, 128), "the codepoint is not U+1F600")
  assert(session.decode('"\\u0041\\u00e9"') == "A" .. string.char(195, 169), "a plain escape lost its bytes")
end

function T.a_duplicate_key_is_refused()
  local v, why = session.decode('{"a":1,"a":2}')
  assert(v == nil, "a duplicate key was accepted")
  assert(why:find("a", 1, true) and why:find("at byte 8", 1, true), why)
  assert(session.decode('{"a":1,"b":2}').b == 2, "two different keys were refused")
end

function T.a_truncated_record_is_refused()
  local s = peopled()
  local p = world()
  local id = assert(session.save(s, p))
  local record = p.data[id]
  for cut = 0, #record - 1 do
    local prefix = record:sub(1, cut)
    local ok, v, why = pcall(session.decode, prefix)
    assert(ok, "a truncated record raised at " .. cut .. ": " .. tostring(v))
    assert(v == nil, "a truncated record decoded at " .. cut)
    assert(type(why) == "string" and why:find("at byte", 1, true), "no offset at " .. cut)
  end
  assert(session.decode(record) ~= nil, "the whole record does not decode")
end

function T.a_number_that_overflows_is_refused()
  local v, why = session.decode("1e400")
  assert(v == nil, "1e400 decoded")
  assert(why:find("out of range", 1, true) and why:find("at byte 1", 1, true), why)
  local v2, why2 = session.decode("[1,-1e400]")
  assert(v2 == nil and why2:find("out of range", 1, true), tostring(why2))
end

-- ------------------------------------------------------------------ the transcript

function T.messages_only_ever_append()
  local s = session.new()
  for i = 1, 20 do
    assert(session.user(s, "line " .. i, i))
  end
  assert(session.count(s) == 20)
  assert(session.at(s, 1).body == "line 1")
  assert(session.at(s, -1).body == "line 20")
  assert(session.at(s, 20).body == "line 20")
  assert(session.at(s, 21) == nil, "a message past the end")
  assert(session.at(s, 0) == nil, "a message at zero")
  assert(session.at(s, -21) == nil, "a message before the start")
  for name in pairs(session) do
    assert(not tostring(name):find("remove") and not tostring(name):find("delete_message")
           and not tostring(name):find("trim") and not tostring(name):find("compact"),
           "session offers " .. tostring(name))
  end
end

function T.a_returned_message_cannot_edit_history()
  local s = session.new()
  assert(session.call(s, "read", { path = "a.txt", opts = { deep = true } }, "c1", 1))

  local handed = assert(session.append(s, { speaker = "user", body = "keep me", at = 2 }))
  handed.body = "changed"
  handed.speaker = "model"
  assert(session.at(s, 2).body == "keep me", "append handed out the stored message")

  local one = assert(session.at(s, 1))
  one.tool = "write"
  one.args.path = "b.txt"
  one.args.opts.deep = false
  assert(session.at(s, 1).tool == "read", "at handed out the stored message")
  assert(session.at(s, 1).args.path == "a.txt", "at handed out the stored args")
  assert(session.at(s, 1).args.opts.deep == true, "at handed out a nested args table")

  local all = session.messages(s)
  all[1].args.path = "c.txt"
  all[2] = nil
  assert(session.at(s, 1).args.path == "a.txt", "messages handed out the stored args")
  assert(session.count(s) == 2, "messages handed out the live list")

  local mine = { speaker = "user", body = "mine", at = 3 }
  assert(session.append(s, mine))
  mine.body = "rewritten"
  assert(session.at(s, 3).body == "mine", "append kept the caller's table")

  local pend = session.pending(s)
  pend[1].call_id = "c9"
  assert(session.pending(s)[1].call_id == "c1", "pending handed out the stored message")
end

function T.an_unknown_field_is_refused()
  local s = session.new()
  local m, why = session.append(s, { speaker = "user", body = "hi", at = 1, colour = "red" })
  assert(m == nil, "a message with an extra field was kept")
  assert(why == 'message has an unknown field "colour"', why)
  assert(session.count(s) == 0, "the transcript changed")

  local _, why2 = session.append(s, { speaker = "shout", body = "hi", at = 1 })
  assert(why2 == 'unknown speaker "shout"', why2)

  local _, why3 = session.append(s, { speaker = "user", at = 1 })
  assert(why3:find("has no", 1, true) and why3:find("body", 1, true), why3)

  local _, why4 = session.append(s, { speaker = "user", body = 7, at = 1 })
  assert(why4:find("string", 1, true) and why4:find("number", 1, true), why4)

  local _, why5 = session.append(s, { speaker = "call", tool = "t", args = "no", call_id = "c", at = 1 })
  assert(why5:find("args", 1, true), why5)
  assert(session.count(s) == 0, "the transcript changed")
end

function T.a_result_needs_an_open_call()
  local s = session.new()
  local m, why = session.result(s, "c9", "output", nil, 1)
  assert(m == nil and why == 'no open call "c9"', tostring(why))

  assert(session.call(s, "read", nil, "c1", 2))
  assert(session.at(s, 1).args ~= nil and keys_of(session.at(s, 1).args) == 0, "no args is not an empty table")
  assert(session.call(s, "write", { path = "b" }, "c2", 3))

  local _, why2 = session.call(s, "read", nil, "c1", 4)
  assert(why2 == 'call "c1" is already in this session', tostring(why2))

  assert(session.result(s, "c2", "wrote", nil, 5), "the second open call could not be closed")
  assert(session.result(s, "c1", "read it", nil, 6), "the first open call could not be closed")

  local _, why3 = session.result(s, "c1", "again", nil, 7)
  assert(why3 == 'call "c1" already has a result', tostring(why3))
  assert(session.count(s) == 4, "a refused message was appended")
end

function T.a_refused_call_is_stored_as_a_result()
  local s = session.new()
  assert(session.call(s, "shell", { line = "rm -rf /" }, "c1", 1))
  assert(session.result(s, "c1", "the person said no", { ok = false, refused = true }, 2))

  local p = world()
  local id = assert(session.save(s, p))
  local back = assert(session.load(p, id))
  local m = session.at(back, 2)
  assert(m.speaker == "result" and m.ok == false and m.refused == true)
  assert(m.body == "the person said no", "the reason did not survive")

  local s2 = session.new()
  assert(session.call(s2, "shell", nil, "c1", 1))
  local bad, why = session.result(s2, "c1", "both", { ok = true, refused = true }, 2)
  assert(bad == nil and why == "a refused call did not succeed", tostring(why))
  assert(session.count(s2) == 1, "a contradictory result was appended")
end

function T.pending_names_what_resume_must_decide()
  local s = session.new()
  assert(session.user(s, "go", 1))
  assert(session.call(s, "read", { path = "a" }, "c1", 2))
  assert(session.call(s, "read", { path = "b" }, "c2", 3))
  assert(session.result(s, "c1", "a", nil, 4))
  assert(session.call(s, "read", { path = "c" }, "c3", 5))

  local p = world()
  local id = assert(session.save(s, p))
  local back = assert(session.load(p, id))

  local open = session.pending(back)
  assert(#open == 2, "pending named " .. #open .. " calls")
  assert(open[1].call_id == "c2" and open[2].call_id == "c3", "pending is out of order")
  assert(open[1].args.path == "b")
  assert(session.count(back) == 5, "loading changed the transcript")
  assert(#session.pending(session.new()) == 0, "an empty session has open calls")
end

function T.an_empty_body_is_kept()
  local s = session.new()
  assert(session.model(s, "", 1))
  local p = world()
  local id = assert(session.save(s, p))
  assert(p.data[id]:find('"body":""', 1, true), "the empty body was not written")
  local back = assert(session.load(p, id))
  assert(session.at(back, 1).body == "", "an empty body came back as " .. tostring(session.at(back, 1).body))
  assert(session.count(back) == 1)
end

-- -------------------------------------------------------- the store, through a port

function T.a_missing_session_is_not_a_broken_store()
  local gone = world { read_fails = { abc = "missing" } }
  local s, why = session.load(gone, "abc")
  assert(s == nil and why == 'no session "abc"', tostring(why))

  local broken = world { read_fails = { abc = "permission denied" } }
  local s2, why2 = session.load(broken, "abc")
  assert(s2 == nil and why2 == "store: permission denied", tostring(why2))
  assert(why ~= why2, "absence and failure read the same")

  local d, whyd = session.delete(world(), "abc")
  assert(d == nil and whyd == 'no session "abc"', tostring(whyd))

  local p = world()
  local s3 = session.new()
  assert(session.user(s3, "hi", 1))
  local id = assert(session.save(s3, p))
  assert(session.delete(p, id) == true, "a record that is there would not delete")
  assert(p.data[id] == nil, "the record is still in the store")
  local again, why3 = session.delete(p, id)
  assert(again == nil and why3 == 'no session "' .. id .. '"', tostring(why3))

  local fussy = world { delete_fails = "read-only" }
  local d2, why4 = session.delete(fussy, "abc")
  assert(d2 == nil and why4 == "store: read-only", tostring(why4))
end

function T.a_write_failure_writes_nothing_and_loses_nothing()
  local s = peopled()
  local before = session.count(s)
  local dead = world { write_fails = "timeout after 5s" }
  local id, why = session.save(s, dead)
  assert(id == nil and why == "store: timeout after 5s", tostring(why))
  assert(keys_of(dead.data) == 0, "the store gained a key")
  assert(s.id == nil, "a failed save spent an id")
  assert(session.count(s) == before, "the session changed")

  local live = world()
  local id2 = assert(session.save(s, live))
  assert(keys_of(live.data) == 1)
  local back = assert(session.load(live, id2))
  assert(session.count(back) == before, "the retry saved a different transcript")
  for i = 1, before do
    assert(same_message(session.at(s, i), session.at(back, i)), "message " .. i .. " changed")
  end
end

function T.an_unencodable_message_never_reaches_the_store()
  local s = session.new()
  assert(session.user(s, "go", 1))
  assert(session.model(s, "calling", 2))
  assert(session.call(s, "run", { fn = print }, "c1", 3))
  local p = world()
  local id, why = session.save(s, p)
  assert(id == nil, "a message holding a function saved")
  assert(why:find("cannot encode message 3", 1, true), why)
  assert(why:find("function", 1, true) and why:find(".args.fn", 1, true), why)
  assert(p.writes == 0, "the store was written to")
  assert(keys_of(p.data) == 0, "the store gained a key")

  local s2 = session.new()
  local loop = {}
  loop.self = loop
  assert(session.call(s2, "run", { self = loop }, "c1", 1))
  local id2, why2 = session.save(s2, p)
  assert(id2 == nil and why2:find("cycle at .args.self", 1, true), tostring(why2))
  assert(p.writes == 0, "the store was written to")
end

function T.one_broken_record_does_not_hide_the_others()
  local p = world { read_fails = { b2 = "permission denied" } }
  local function record(id, started)
    local s = session.new { id = id, agent = "a", model = "m", started = started }
    assert(session.user(s, "hi", started))
    assert(session.save(s, p))
  end
  record("a1", 3)
  record("a2", 1)
  record("a3", 2)
  p.data.b1 = "not json at all"
  p.data.b2 = "unreadable"

  local out = assert(session.list(p))
  assert(#out == 5, "list returned " .. #out .. " headers")
  assert(out[1].id == "a2" and out[2].id == "a3" and out[3].id == "a1", "list is out of order")
  for i = 1, 3 do
    assert(out[i].broken == nil and out[i].count == 1 and out[i].agent == "a" and out[i].model == "m")
  end
  assert(out[4].id == "b1" and out[4].broken:find("not a session record", 1, true), tostring(out[4].broken))
  assert(out[5].id == "b2" and out[5].broken == "store: permission denied", tostring(out[5].broken))

  assert(#session.list(world()) == 0, "an empty store did not give an empty list")
  local none, why = session.list(world { list_fails = "disk gone" })
  assert(none == nil and why == "store: disk gone", tostring(why))
end

function T.a_lying_port_is_data_not_a_crash()
  for _, answer in ipairs({ 7, true, { 1, 2 } }) do
    local p = world { read_returns = { abc = answer } }
    local ok, s, why = pcall(session.load, p, "abc")
    assert(ok, "a lying port raised: " .. tostring(s))
    assert(s == nil, "a lying port was believed")
    assert(why:find("store returned a " .. type(answer), 1, true), tostring(why))
  end

  local listy = world { list_returns = 7 }
  local out, why2 = session.list(listy)
  assert(out == nil and why2:find("expected a list of ids", 1, true), tostring(why2))

  local mixed = world { list_returns = { 7 } }
  local out2 = assert(session.list(mixed))
  assert(#out2 == 1 and out2[1].broken:find("not an id", 1, true), tostring(out2[1].broken))

  local clockless = world { now = "soon" }
  local id, why3 = session.save(session.new(), clockless)
  assert(id == nil and why3:find("the clock returned string", 1, true), tostring(why3))

  local silent = world { read_fails = { abc = 42 } }
  local s2, why4 = session.load(silent, "abc")
  assert(s2 == nil and why4:find("store:", 1, true), tostring(why4))
end

function T.a_future_record_is_refused_by_number()
  local p = world()
  p.data.later = '{"format":2,"id":"later","messages":[]}'
  local s, why = session.load(p, "later")
  assert(s == nil, "a record from a future build loaded")
  assert(why == "session record format 2, this build reads 1", why)

  p.data.old = '{"id":"old","messages":[]}'
  local s2, why2 = session.load(p, "old")
  assert(s2 == nil and why2:find("format", 1, true), tostring(why2))

  p.data.headless = '{"format":1,"id":"headless"}'
  local s3, why3 = session.load(p, "headless")
  assert(s3 == nil and why3 == "not a session record: no messages array", tostring(why3))

  p.data.junk = "not json at all"
  local s4, why4 = session.load(p, "junk")
  assert(s4 == nil and why4:find("not a session record: ", 1, true) and why4:find("at byte", 1, true), tostring(why4))

  p.data.wrong = '{"format":1,"messages":[{"speaker":"shout","body":"x","at":1}]}'
  local s5, why5 = session.load(p, "wrong")
  assert(s5 == nil and why5 == 'message 1: unknown speaker "shout"', tostring(why5))

  p.data.orphan = '{"format":1,"messages":[{"speaker":"result","call_id":"c3","body":"x","ok":true,"refused":false,"at":1}]}'
  local s6, why6 = session.load(p, "orphan")
  assert(s6 == nil and why6 == 'message 1: no open call "c3"', tostring(why6))
end

function T.saving_twice_keeps_one_record()
  local p = world()
  local s = session.new()
  assert(session.user(s, "one", 1))
  local id = assert(session.save(s, p))
  assert(session.model(s, "two", 2))
  assert(session.user(s, "three", 3))
  local id2 = assert(session.save(s, p))
  assert(id2 == id, "a second save minted a second id")
  assert(keys_of(p.data) == 1, "the store holds " .. keys_of(p.data) .. " records")
  local back = assert(session.load(p, id))
  assert(session.count(back) == 3, "the longer transcript did not overwrite the shorter")

  local named = session.new { id = "chosen" }
  assert(session.save(named, p) == "chosen", "a session with an id minted another")
  assert(p.data.chosen ~= nil)

  assert(session.set_id(named, "chosen") == true, "setting the same id twice failed")
  local ok, why = session.set_id(named, "other")
  assert(ok == nil and why == 'this session is already "chosen"', tostring(why))
  local fresh = session.new()
  assert(session.set_id(fresh, "mine") == true)
  assert(fresh.id == "mine")
end

function T.a_minted_id_does_not_collide()
  local p = world { now = 1.5 }
  local one = session.new()
  assert(session.user(one, "first", 1))
  local id = assert(session.save(one, p))
  assert(id == "1500", "the id is not the millisecond count: " .. id)

  local two = session.new()
  assert(session.user(two, "second", 2))
  local id2 = assert(session.save(two, p))
  assert(id2 == "1500-2", "the second id is " .. id2)

  local three = session.new()
  local id3 = assert(session.save(three, p))
  assert(id3 == "1500-3", "the third id is " .. id3)

  assert(keys_of(p.data) == 3, "records were lost to the collision")
  assert(session.at(assert(session.load(p, "1500")), 1).body == "first")
  assert(session.at(assert(session.load(p, "1500-2")), 1).body == "second")
end

function T.session_names_no_vendor()
  local f = assert(io.open(here .. "/../src/session.lua", "r"))
  local text = f:read("*a")
  f:close()
  local banned = { "%f[%w]io%.", "%f[%w]os%.", "require", "loadstring", "dofile", "socket" }
  local lower = text:lower()
  for i = 1, #banned do
    assert(not lower:find(banned[i]), "src/session.lua names " .. banned[i])
  end

  -- `session.load` is the module's own verb, so the pattern is a bare `load(`: one not
  -- reached through a dot. This test carries both cases so the check cannot pass by
  -- being blind.
  local bare = "[^%w_%.]load%s*%("
  assert(not lower:find(bare) and not lower:find("^load%s*%("),
         "src/session.lua calls load(")
  assert(not ("local s = session.load(port, id)"):find(bare), "the check refuses session.load(")
  assert(("local c = load(chunk)"):find(bare), "the check would miss a bare load(")
end

function T.two_sessions_share_nothing()
  local one, two = session.new(), session.new()
  assert(session.user(one, "only mine", 1))
  assert(session.count(one) == 1 and session.count(two) == 0, "the second session saw the first")
  assert(session.last(two) == nil)
  assert(one.messages ~= two.messages, "two sessions share one list")

  local p = world { now = 2 }
  local id = assert(session.save(one, p))
  assert(session.user(two, "only theirs", 1))
  local id2 = assert(session.save(two, p))
  assert(id ~= id2, "two sessions were saved as one record")
  assert(keys_of(p.data) == 2, "the store holds " .. keys_of(p.data) .. " records")
  assert(session.at(assert(session.load(p, id)), 1).body == "only mine")
  assert(session.at(assert(session.load(p, id2)), 1).body == "only theirs")

  assert(session.new().messages ~= session.new().messages)
  assert(session.header(one).count == 1 and session.header(two).count == 1)
  local h = session.header(one)
  assert(h.id == id and h.agent == nil and h.model == nil)
end

function T.a_wrong_argument_type_raises()
  local s = session.new()
  local function raises(fn, ...)
    local ok, why = pcall(fn, ...)
    assert(not ok, "a wrong argument type was accepted")
    assert(type(why) == "string" and why ~= "", "the raise carries no sentence")
    return why
  end
  raises(session.new, 7)
  raises(session.new, { colour = "red" })
  raises(session.new, { id = 7 })
  raises(session.user, s, 7, 1)
  raises(session.user, s, "hi", "now")
  raises(session.call, s, "read", "not a table", "c1", 1)
  raises(session.result, s, "c1", "body", { colour = true }, 1)
  raises(session.result, s, "c1", "body", { ok = "yes" }, 1)
  raises(session.at, s, "first")
  raises(session.last, s, "shout")
  raises(session.count, 7)
  raises(session.append, s, 7)
  raises(session.decode, 7)
  raises(session.save, s, {})
  raises(session.load, world(), 7)
  assert(session.encode(print) == nil, "a function encoded")
end

function T.a_raise_names_the_line_that_called()
  -- The line the module holds is that a wrong argument type stops at the line that
  -- made it. A raise blamed on src/session.lua sends the reader to the wrong file.
  local me = debug.getinfo(1, "S").short_src
  local function blames(fn)
    local ok, why = pcall(fn)
    assert(not ok, "a wrong argument type was accepted")
    assert(type(why) == "string", "the raise carries no sentence")
    assert(why:sub(1, #me + 1) == me .. ":",
           "the raise blames the module, not the caller: " .. why)
  end
  local s = session.new()
  blames(function () session.new(7) end)
  blames(function () session.set_id(s, 7) end)
  blames(function () session.append(s, 7) end)
  blames(function () session.user(s, 7, 1) end)
  blames(function () session.call(s, "read", "not a table", "c1", 1) end)
  blames(function () session.result(s, "c1", "body", { ok = "yes" }, 1) end)
  blames(function () session.count(7) end)
  blames(function () session.at(s, "first") end)
  blames(function () session.last(s, "shout") end)
  blames(function () session.messages(7) end)
  blames(function () session.pending(7) end)
  blames(function () session.header(7) end)
  blames(function () session.decode(7) end)
  blames(function () session.save(s, {}) end)
  blames(function () session.load(world(), 7) end)
  blames(function () session.list({}) end)
  blames(function () session.delete(world(), 7) end)
end

function T.a_speaker_narrows_the_last_message()
  local s = session.new()
  assert(session.system(s, "be careful", 1))
  assert(session.user(s, "first", 2))
  assert(session.model(s, "thinking", 3))
  assert(session.call(s, "read", { path = "a" }, "c1", 4))
  assert(session.result(s, "c1", "the text", nil, 5))
  assert(session.user(s, "second", 6))
  assert(session.model(s, "answering", 7))

  assert(session.last(s).body == "answering", "last() is not the last message")
  assert(session.last(s, "user").body == "second", "the last user is not the second one")
  assert(session.last(s, "model").body == "answering", "the last model is wrong")
  assert(session.last(s, "system").body == "be careful", "the last system is wrong")
  assert(session.last(s, "call").call_id == "c1", "the last call is wrong")
  assert(session.last(s, "call").args.path == "a", "the last call lost its args")
  assert(session.last(s, "result").body == "the text", "the last result is wrong")

  local quiet = session.new()
  assert(session.user(quiet, "only me", 1))
  assert(session.last(quiet, "model") == nil, "a speaker that never spoke has a last message")
  assert(session.last(quiet, "result") == nil, "a speaker that never spoke has a last message")

  local handed = session.last(s, "user")
  handed.body = "changed"
  handed.speaker = "model"
  assert(session.last(s, "user").body == "second", "last handed out the stored message")
end

function T.a_table_that_is_neither_an_array_nor_an_object_is_refused()
  local mixed, why = session.encode { 1, a = 2 }
  assert(mixed == nil, "a mixed table encoded")
  assert(why:find("mixed", 1, true) and why:find('"a"', 1, true), why)

  local sparse, why2 = session.encode { [1] = 1, [3] = 3 }
  assert(sparse == nil, "a sparse array encoded")
  assert(why2:find("sparse", 1, true) and why2:find("2", 1, true), why2)

  for _, bad in ipairs({ { [true] = 1 }, { [{}] = 1 }, { [0] = 1 }, { [-1] = 1 }, { [1.5] = 1 } }) do
    local text, why3 = session.encode(bad)
    assert(text == nil, "a table with a key JSON has no room for encoded")
    assert(why3:find("neither a string nor an index", 1, true), tostring(why3))
  end

  -- an array of the right shape still encodes, and the refusal names its path
  assert(session.encode { 1, 2, 3 } == "[1,2,3]", "a plain array was refused")
  local s = session.new()
  assert(session.call(s, "run", { rows = { 1, name = "x" } }, "c1", 1))
  local p = world()
  local id, why4 = session.save(s, p)
  assert(id == nil, "a message holding a mixed table saved")
  assert(why4:find("cannot encode message 1", 1, true), why4)
  assert(why4:find(".args.rows", 1, true), "the path is missing: " .. why4)
  assert(p.writes == 0, "the store was written to")
end

function T.a_port_error_reads_as_a_reason()
  -- A store beside the six ports may answer with a port error value rather than a
  -- string. Absence must still be absence, and nothing else about it is read.
  local function err(code, message)
    return { port = "store", call = "read", code = code, message = message }
  end
  local p = world { read_fails = {
    gone   = err("not_found", "not_found"),
    denied = err("denied", "the disk said no"),
    mute   = { port = "store", call = "read", code = "timeout" },
    empty  = {},
  } }
  local s, why = session.load(p, "gone")
  assert(s == nil and why == 'no session "gone"', tostring(why))
  local s2, why2 = session.load(p, "denied")
  assert(s2 == nil and why2 == "store: the disk said no", tostring(why2))
  local s3, why3 = session.load(p, "mute")
  assert(s3 == nil and why3 == "store: timeout", tostring(why3))
  local s4, why4 = session.load(p, "empty")
  assert(s4 == nil and why4:find("store:", 1, true) and why4 ~= "store: ", tostring(why4))
  assert(why ~= why2, "absence and failure read the same")

  local d = world { delete_fails = err("not_found", "not_found") }
  local ok, why5 = session.delete(d, "gone")
  assert(ok == nil and why5 == 'no session "gone"', tostring(why5))

  local listing = world { read_fails = { b = err("denied", "the disk said no") } }
  listing.data.a = '{"format":1,"id":"a","messages":[],"started":1}'
  listing.data.b = "unreadable"
  local rows = assert(session.list(listing))
  assert(#rows == 2 and rows[1].id == "a" and rows[1].broken == nil)
  assert(rows[2].id == "b" and rows[2].broken == "store: the disk said no", tostring(rows[2].broken))
end

function T.a_record_too_deep_to_read_is_never_written()
  -- save encodes a message where the record will hold it -- the record object, its
  -- messages array, then the message -- so it can never write a record that load then
  -- refuses as too deep. Without that offset there is a band of nesting that saves and
  -- will not come back, which is the one thing a transcript may not do.
  local function attempt(levels)
    local args, tip = {}, nil
    tip = args
    for _ = 1, levels do tip.a = {}; tip = tip.a end
    local s = session.new()
    assert(session.call(s, "run", args, "c1", 1))
    local p = world()
    local id, why = session.save(s, p)
    return p, id, why
  end

  local p, id = attempt(196)
  assert(id ~= nil, "a message inside the limit would not save")
  local back = assert(session.load(p, id), "a record inside the limit would not load")
  assert(session.count(back) == 1, "the deep message did not come back")

  local p2, id2, why2 = attempt(197)
  assert(id2 == nil, "a message the record cannot hold was written")
  assert(why2:find("cannot encode message 1", 1, true) and why2:find("too deep", 1, true), tostring(why2))
  assert(p2.writes == 0, "the store was written to")
  assert(keys_of(p2.data) == 0, "the store gained a key")

  -- and the record save writes is still exactly what the encoder would write
  local whole = assert(session.encode {
    format = 1, id = id, messages = session.messages(back),
  })
  assert(whole:find('"messages":', 1, true), "no messages in the record")
  assert(session.decode(whole) ~= nil, "the encoder wrote a record it cannot read")
end

function T.minting_gives_up_rather_than_looping()
  local p = world()
  p.store.read = function () return "already taken" end
  local id, why = session.save(session.new(), p)
  assert(id == nil, "an id was minted from a store that holds every id")
  assert(why:find("a thousand records", 1, true), tostring(why))
  assert(p.writes == 0, "the store was written to")

  local nan = world { now = function () return 0 / 0 end }
  local id2, why2 = session.save(session.new(), nan)
  assert(id2 == nil and why2:find("the clock returned", 1, true), tostring(why2))
end

return T
