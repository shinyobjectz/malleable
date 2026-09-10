-- port: the capability contract and its doubles.
--
-- Happy paths first, then the awkward ones. Every test asserts with plain `assert` and
-- prints nothing when it holds.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local port = require "port"
local double = require "double"

local T = {}

-- A request that satisfies the shape, so a test can say what it is actually about.
local function ask_of(model, messages, tools)
  return { model = model or "openrouter:inception/mercury-2.5", messages = messages or {}, tools = tools }
end

local function raised(fn, ...)
  local ok, message = pcall(fn, ...)
  return (not ok), tostring(message)
end

-- Helpers used by the file-reading tests. They open a file, which is why they live in
-- the test and not in a port.
local function read_file(path)
  local handle = assert(io.open(path, "rb"))
  local body = handle:read("*a")
  handle:close()
  return body
end

-- A mention that is not part of a longer word: "ratio." is not a reach for io.
local function mentions(body, needle)
  local at = 1
  while true do
    local from = body:find(needle, at, true)
    if not from then return false end
    local before = from > 1 and body:sub(from - 1, from - 1) or " "
    if not before:match("[%w_.]") then return true end
    at = from + 1
  end
end

-- One fresh filesystem per probe, so a refused call cannot be excused by an earlier one.
local function f_read_of(path) return double.fs().read(path) end
local function f_write_of(path) return double.fs().write(path, "x") end
local function f_remove_of(path) return double.fs().remove(path) end

local function names(list)
  local seen = {}
  for i = 1, #list do seen[list[i]] = true end
  return seen
end

-- ----------------------------------------------------------------- the happy paths

function T.a_complete_world_passes_check()
  local problems = port.check(double.world())
  assert(type(problems) == "table")
  assert(#problems == 0, problems[1])
end

function T.a_missing_port_is_named()
  local problems = port.check { fs = double.fs() }
  assert(#problems == 5, "five ports are absent, got " .. #problems)
  local named = names(problems)
  assert(named["no model port"])
  assert(named["no sh port"])
  assert(named["no clock port"])
  assert(named["no ask port"])
  assert(named["no log port"])
  -- A port whose functions are not functions is named function by function.
  local half = port.check { model = {}, fs = double.fs(), sh = { run = 3 }, clock = double.clock(),
                            ask = double.ask(true), log = double.log() }
  local named2 = names(half)
  assert(named2["model.call is not a function"])
  assert(named2["sh.run is not a function"])
end

function T.check_of_nil_is_one_problem()
  local problems = port.check(nil)
  assert(#problems == 1 and problems[1] == "no port table")
  assert(#port.check("a port, honest") == 1)
end

function T.a_scripted_model_replays_in_order()
  local m = double.model { replies = {
    "first",
    { text = "second", calls = { { tool = "read", args = { path = "a.txt" } } } },
    { text = "third", stop = "cut" },
  } }
  local one = m.call(ask_of())
  assert(one.text == "first" and one.stop == "done" and #one.calls == 0)
  local two = m.call(ask_of())
  assert(two.text == "second" and two.stop == "calls" and #two.calls == 1)
  assert(two.calls[1].tool == "read" and two.calls[1].args.path == "a.txt")
  local three = m.call(ask_of())
  assert(three.text == "third" and three.stop == "cut" and type(three.calls) == "table" and #three.calls == 0)
end

function T.a_scripted_call_gets_a_predictable_id()
  local m = double.model { replies = {
    { tool = "read", args = { path = "a.txt" } },
    { tool = "read", args = { path = "b.txt" } },
  } }
  local one = m.call(ask_of())
  assert(one.calls[1].id == "c1", one.calls[1].id)
  assert(one.stop == "calls")
  local two = m.call(ask_of())
  assert(two.calls[1].id == "c2", two.calls[1].id)
  -- Fresh: a second double starts its ids again.
  local other = double.model { replies = { { tool = "read" } } }
  assert(other.call(ask_of()).calls[1].id == "c1")
end

function T.the_model_double_records_what_it_was_sent()
  local schema = { { name = "read", about = "Read a file", args = {}, ask = false } }
  local m = double.model { replies = { { tool = "read", args = { path = "a.txt" } }, "done" } }

  local first = ask_of("m", { { role = "user", text = "read a.txt" } }, schema)
  local reply = m.call(first)
  assert(m.seen[1].tools == schema, "the schema goes through as the table it was")
  assert(m.seen[1].messages[1].role == "user")

  local answer = { role = "tool", id = reply.calls[1].id, ok = true, text = "hello" }
  local second = ask_of("m", { first.messages[1], { role = "agent", text = "", calls = reply.calls }, answer }, schema)
  m.call(second)
  local sent = m.seen[2].messages
  assert(#sent == 3)
  assert(sent[#sent].role == "tool" and sent[#sent].id == "c1" and sent[#sent].ok == true)
end

function T.an_error_entry_in_the_script_is_returned_not_raised()
  local m = double.model { replies = { { code = "timeout", message = "the far side took too long" } } }
  local reply, err = m.call(ask_of())
  assert(reply == nil)
  assert(port.is_error(err))
  assert(err.code == "timeout" and err.port == "model" and err.call == "call")
  assert(err.message == "the far side took too long")
end

function T.a_reply_is_never_missing_its_lists()
  local m = double.model { replies = { { text = "hi" } } }
  local reply = m.call(ask_of())
  assert(type(reply.calls) == "table" and #reply.calls == 0)
  assert(reply.stop == "done")
  assert(reply.text == "hi")
  assert(reply.usage == nil, "nothing in the harness may require usage")
end

function T.reading_a_file_that_is_there_returns_it_whole()
  local body = "one\0two"
  local f = double.fs { ["src/a.lua"] = body, ["notes.md"] = "no trailing newline", ["empty.txt"] = "" }
  assert(f.read("src/a.lua") == body)
  assert(#f.read("src/a.lua") == 7)
  assert(f.read("notes.md") == "no trailing newline")
  assert(f.read("empty.txt") == "")
  assert(f.exists("src/a.lua") and f.exists("src") and not f.exists("src/b.lua"))
end

function T.writing_creates_the_directories()
  local f = double.fs()
  assert(f.write("a/b/c.txt", "x") == true)
  local entries = f.list("a/b")
  assert(#entries == 1 and entries[1].name == "c.txt" and entries[1].kind == "file" and entries[1].size == 1)
  assert(f.exists("a/b") and f.exists("a"))
  assert(f.list("a")[1].kind == "dir")
  assert(#f.wrote == 1 and f.wrote[1].path == "a/b/c.txt" and f.wrote[1].text == "x")
end

function T.a_listing_is_sorted_and_stable()
  local one = double.fs { ["s/z.lua"] = "z", ["s/a.lua"] = "a", ["s/m/deep.lua"] = "d", ["top.md"] = "t" }
  local two = double.fs { ["top.md"] = "t", ["s/m/deep.lua"] = "d", ["s/a.lua"] = "a", ["s/z.lua"] = "z" }
  local function shape(entries)
    local out = {}
    for i = 1, #entries do out[i] = entries[i].kind .. ":" .. entries[i].name end
    return table.concat(out, ",")
  end
  local want = "file:a.lua,dir:m,file:z.lua"
  assert(shape(one.list("s")) == want, shape(one.list("s")))
  assert(shape(two.list("s")) == want, shape(two.list("s")))
  assert(shape(one.list("s")) == shape(one.list("s")))
  assert(shape(one.list("")) == "dir:s,file:top.md")
end

function T.an_empty_directory_lists_empty_and_is_not_an_error()
  local f = double.fs()
  local entries, err = f.list("")
  assert(entries ~= nil and err == nil and #entries == 0)
  local g = double.fs { ["tmp/"] = true, ["a.txt"] = "a" }
  local inner = g.list("tmp")
  assert(inner ~= nil and #inner == 0)
  assert(g.exists("tmp"))
end

function T.sleep_on_the_double_clock_moves_time_and_returns_at_once()
  local c = double.clock { at = 1700000000, mono = 5 }
  assert(c.now() == 1700000000 and c.mono() == 5)
  assert(c.sleep(2.5) == true)
  assert(c.now() == 1700000002.5)
  assert(c.mono() == 7.5)
  c.sleep(1)
  assert(#c.slept == 2 and c.slept[1] == 2.5 and c.slept[2] == 1)
  c.advance(10)
  assert(c.now() == 1700000013.5 and #c.slept == 2)
end

function T.a_non_zero_exit_is_a_result()
  local s = double.sh { ["git commit"] = { code = 2, err = "nothing to commit" } }
  local result, err = s.run { "git", "commit" }
  assert(err == nil, "a non-zero exit is a result, not an error")
  assert(result.code == 2 and result.err == "nothing to commit" and result.out == "")
  assert(result.timed_out == false)
  assert(#s.ran == 1 and s.ran[1].argv[1] == "git" and s.ran[1].argv[2] == "commit")
end

function T.an_approved_call_returns_allow_true_and_is_recorded()
  local a = double.ask(true)
  local args = { path = "notes.md" }
  local d = a.request { tool = "write", about = "Write a file", args = args }
  assert(d.allow == true)
  assert(#a.asked == 1)
  assert(a.asked[1].tool == "write")
  assert(a.asked[1].args == args and a.asked[1].args.path == "notes.md")
end

function T.a_log_line_records_level_event_and_fields()
  local l = double.log()
  local nothing = l.write("info", "tool.start", { tool = "read", ms = 4, ok = true })
  assert(nothing == nil)
  assert(#l.lines == 1)
  local line = l.lines[1]
  assert(line.level == "info" and line.event == "tool.start")
  assert(line.fields.tool == "read" and line.fields.ms == 4 and line.fields.ok == true)
end

-- ------------------------------------------------------------------- the adversarial

function T.a_missing_file_is_not_an_empty_string()
  local f = double.fs { ["there.md"] = "" }
  local text, err = f.read("nope.md")
  assert(text == nil, "a missing file must not read as empty")
  assert(text ~= "")
  assert(err.code == "not_found" and err.port == "fs" and err.call == "read")
  assert(err.message:find("nope.md", 1, true))
  -- And the file that is really empty still reads as the empty string.
  local empty, none = f.read("there.md")
  assert(empty == "" and none == nil)
end

function T.a_path_that_climbs_out_is_denied()
  local out = { "../etc/passwd", "a/../../b", "/etc/passwd", "" }
  for i = 1, #out do
    local path = out[i]
    local a, ea = f_read_of(path)
    assert(a == nil and ea.code == "denied", path)
    local b, eb = f_write_of(path)
    assert(b == nil and eb.code == "denied", path)
    local c, ec = f_remove_of(path)
    assert(c == nil and ec.code == "denied", path)
    assert(double.fs().exists(path) == false, path)
  end
  -- The empty string is the workspace root for a listing, and only there.
  local f = double.fs { ["a.txt"] = "a" }
  for i = 1, 3 do
    local entries, err = f.list(out[i])
    assert(entries == nil and err.code == "denied", out[i])
  end
  local root = f.list("")
  assert(root ~= nil and #root == 1 and root[1].name == "a.txt")
end

function T.a_path_that_climbs_out_is_denied_as_a_shell_cwd()
  local s = double.sh { ["ls"] = { code = 0 } }
  -- The same four the filesystem refuses, so the two ports cannot drift apart: the
  -- empty string is a directory to `list` and to nothing else, this call included.
  local out = { "../etc", "a/../../b", "/etc", "" }
  for i = 1, #out do
    local result, err = s.run({ "ls" }, { cwd = out[i] })
    assert(result == nil and err.code == "denied" and err.port == "sh" and err.call == "run", out[i])
  end
  -- The workspace root is an omitted cwd; a plain subdirectory is legal as it stands.
  assert(s.run({ "ls" }) ~= nil)
  assert(s.run({ "ls" }, {}) ~= nil)
  assert(s.run({ "ls" }, { cwd = "src" }) ~= nil)
  assert(#s.ran == 7, "every attempt is recorded, refused or not")
  assert(s.ran[1].opts.cwd == "../etc", "what the harness tried is what the test reads")
end

function T.a_read_over_the_cap_returns_no_content()
  local f = double.fs { ["big.txt"] = "123456789012" }
  f.cap = 8
  local text, err = f.read("big.txt")
  assert(text == nil, "a capped read returns no prefix")
  assert(err.code == "too_big")
  assert(err.message:find("12", 1, true), err.message)
  f.cap = 12
  assert(f.read("big.txt") == "123456789012")
end

function T.a_read_only_filesystem_still_reads()
  local f = double.fs { ["a.txt"] = "a", ["src/b.lua"] = "b" }
  f.readonly = true
  local wrote, we = f.write("c.txt", "c")
  assert(wrote == nil and we.code == "denied")
  local gone, ge = f.remove("a.txt")
  assert(gone == nil and ge.code == "denied")
  assert(f.read("a.txt") == "a")
  assert(#f.list("") == 2)
  assert(#f.wrote == 0 and #f.removed == 0)
  assert(f.files["a.txt"] == "a", "a refused remove leaves the file alone")
end

function T.an_unscripted_command_is_not_a_success()
  local s = double.sh()
  local result, err = s.run { "rm", "-rf", "." }
  assert(result == nil, "an unscripted command is never a success")
  assert(err.code == "unscripted")
  assert(err.message:find("rm -rf .", 1, true), err.message)
  assert(#s.ran == 1 and #s.ran[1].argv == 3)
end

function T.an_exhausted_model_script_says_so()
  local m = double.model { replies = { "only one" } }
  assert(m.call(ask_of()).text == "only one")
  local reply, err = m.call(ask_of())
  assert(reply == nil, "the first reply must not come round again")
  assert(err.code == "exhausted" and err.message:find("1", 1, true))
  local stopper = double.model { replies = {}, after = "stop" }
  local done = stopper.call(ask_of())
  assert(done.stop == "done" and done.text == "" and #done.calls == 0)
end

function T.a_repeating_script_never_ends_the_loop_itself()
  local m = double.model { replies = { { tool = "read", args = { path = "a.txt" } } }, after = "repeat" }
  local last
  for i = 1, 1000 do
    local reply, err = m.call(ask_of())
    assert(err == nil and reply.stop == "calls" and #reply.calls == 1, "turn " .. i)
    assert(reply.calls[1].id == "c" .. i)
    last = reply
  end
  assert(last.calls[1].tool == "read")
  assert(#m.replies == 1, "the script itself does not grow")
  assert(#m.seen == 1000, "what grows is the record of what was asked, and only that")
end

function T.a_refusal_is_a_decision_not_an_error()
  local a = double.ask(false)
  local d, second = a.request { tool = "write", args = {} }
  assert(second == nil, "a refusal has no second return value")
  assert(type(d) == "table" and d.allow == false)
  assert(port.is_error(d) == false)
  assert(#a.asked == 1)
end

function T.an_unreachable_human_refuses()
  local ran_out = double.ask { { allow = true } }
  assert(ran_out.request({ tool = "write", args = {} }).allow == true)
  local d = ran_out.request { tool = "write", args = {} }
  assert(d.allow == false and d.why == "no answer")

  local broken = double.ask(function () error("the channel is gone") end)
  local e = broken.request { tool = "write", args = {} }
  assert(e.allow == false and e.why == "no answer")

  local nonsense = double.ask(function () return "sure" end)
  local n = nonsense.request { tool = "write", args = {} }
  assert(n.allow == false and n.why == "no answer")
  assert(#broken.asked == 1, "a broken channel still records what was put to it")
end

function T.an_unlisted_tool_is_refused_by_the_by_tool_form()
  local a = double.ask { read = true }
  assert(a.request({ tool = "read", args = {} }).allow == true)
  local d = a.request { tool = "write", args = {} }
  assert(d.allow == false, "a permission table is a whitelist, never a blacklist")
  assert(type(d.why) == "string" and d.why:find("write", 1, true))
  local explicit = double.ask { read = true, write = false }
  assert(explicit.request({ tool = "write", args = {} }).allow == false)
end

function T.a_timeout_is_reachable_without_a_network()
  local m = double.model { replies = { { code = "timeout", message = "no answer in 30s" } } }
  local reply, err = m.call { model = "m", messages = {}, timeout = 30 }
  assert(reply == nil and err.code == "timeout")

  local killed = double.sh { ["sleep 100"] = { code = "timeout", message = "killed at 30s" } }
  local result, se = killed.run { "sleep", "100" }
  assert(result == nil and se.code == "timeout" and se.port == "sh")

  -- The other legal shape: a port that kept what it had when the deadline passed.
  local kept = double.sh { ["sleep 100"] = { code = 124, out = "half of it", timed_out = true } }
  local partial, none = kept.run { "sleep", "100" }
  assert(none == nil and partial.timed_out == true and partial.out == "half of it")
end

function T.a_malformed_call_does_not_become_an_empty_args_table()
  local m = double.model { replies = { { tool = "read", args = "path=a.txt" } } }
  local reply, err = m.call(ask_of())
  assert(reply == nil, "a call whose arguments did not decode is not a reply")
  assert(err.code == "malformed", err.code)
  assert(err.message:find("read", 1, true))

  local inner = double.model { replies = { { text = "", calls = { { tool = "read", args = 7 } } } } }
  local r2, e2 = inner.call(ask_of())
  assert(r2 == nil and e2.code == "malformed")

  local nameless = double.model { replies = { { text = "", calls = { { args = {} } } } } }
  local r3, e3 = nameless.call(ask_of())
  assert(r3 == nil and e3.code == "malformed")

  -- A call the model made up is carried through: judging it is the turn's job.
  local made_up = double.model { replies = { { tool = "no_such_tool", args = {} } } }
  local ok = made_up.call(ask_of())
  assert(ok.calls[1].tool == "no_such_tool")
end

function T.an_unknown_error_code_is_refused_at_construction()
  assert(raised(port.error, "fs", "read", "oops", "a typo"))
  assert(raised(port.error, "fs", "read", nil, "no code at all"))
  assert(raised(port.error, "", "read", "not_found", "no port named"))
  local err = port.error("fs", "read", "not_found")
  assert(err.message == "not_found", "a message always reads as something")
  assert(port.is_error(err))
  for code in pairs(port.codes) do
    assert(port.is_error(port.error("fs", "read", code, "fine")))
  end
end

function T.the_log_port_cannot_end_a_turn()
  local l = double.log()
  assert(not raised(l.write, nil, nil))
  assert(not raised(l.write, "shout", "e", { t = {} }))
  assert(not raised(l.write, "info", "e", "not a table"))
  assert(not raised(l.write, "info", "e", { f = print }))
  assert(#l.lines == 4)
  assert(l.lines[1].level == "info" and l.lines[1].event == "?")
  assert(l.lines[2].level == "info", "an unknown level is coerced")
  assert(l.lines[2].fields.t == "<table>", "a nested table is rendered, never walked")
  assert(type(l.lines[3].fields) == "table")
  assert(l.lines[4].fields.f == "<function>")
end

function T.a_double_touches_nothing_real()
  local body = read_file(here .. "/../src/double.lua")
  -- Wider than the four names the contract calls out: a deterministic double has no
  -- business in any of these tables, so the whole prefix is what the test reads for.
  local banned = { "io.", "os.", "math.", "debug.", "socket", "dofile", "loadfile" }
  for i = 1, #banned do
    assert(not mentions(body, banned[i]), "src/double.lua reaches for " .. banned[i])
  end
end

function T.the_port_module_requires_no_sibling()
  local siblings = { "spec", "turn", "session", "approval", "provider", "compaction", "tools_fs", "tools_shell" }
  local port_body = read_file(here .. "/../src/port.lua")
  assert(not port_body:find("require%s*[%(\"']"), "port is the bottom of the stack")
  local double_body = read_file(here .. "/../src/double.lua")
  for i = 1, #siblings do
    assert(not double_body:find('require "' .. siblings[i] .. '"', 1, true), "double reaches for " .. siblings[i])
    assert(not double_body:find("require%s*%(?%s*['\"]" .. siblings[i] .. "['\"]"), "double reaches for " .. siblings[i])
  end
end

function T.a_recorded_request_survives_the_caller_mutating_it()
  local m = double.model { replies = { "one", "two" } }
  local request = ask_of("m", { { role = "user", text = "hello" } })
  m.call(request)
  request.messages[#request.messages + 1] = { role = "user", text = "and another thing" }
  request.model = "some other model"
  assert(#m.seen[1].messages == 1, "the record is what was sent, not what the table became")
  assert(m.seen[1].model == "m")
  assert(m.seen[1].messages[1].text == "hello")

  local s = double.sh { ["ls a"] = { code = 0 } }
  local argv = { "ls", "a" }
  s.run(argv)
  argv[3] = "b"
  assert(#s.ran[1].argv == 2)
end

function T.an_empty_transcript_is_legal()
  local m = double.model { replies = { "hello" } }
  local reply = m.call { model = "m", messages = {} }
  assert(reply.text == "hello")
  assert(#m.seen == 1)
  assert(type(m.seen[1].messages) == "table" and #m.seen[1].messages == 0)
  assert(m.seen[1].system == nil)
end

function T.a_wrong_shape_raises_rather_than_returning()
  local f = double.fs()
  local bad, message = raised(f.read, nil)
  assert(bad and message:find("path", 1, true), message)
  bad, message = raised(f.write, "a.txt", 12)
  assert(bad and message:find("text", 1, true), message)

  local s = double.sh()
  bad, message = raised(s.run, "git status")
  assert(bad and message:find("argv", 1, true), message)
  assert(raised(s.run, {}))
  assert(raised(s.run, { "git", 7 }))

  local c = double.clock()
  bad, message = raised(c.sleep, "2")
  assert(bad and message:find("secs", 1, true), message)
  assert(raised(c.sleep, -1))

  local m = double.model()
  bad, message = raised(m.call, nil)
  assert(bad and message:find("request", 1, true), message)
  assert(raised(m.call, { messages = {} }), "a request with no model is a caller bug")
  assert(raised(m.call, { model = "m" }), "a request with no messages is a caller bug")

  local a = double.ask(true)
  bad, message = raised(a.request, { about = "no tool named" })
  assert(bad and message:find("tool", 1, true), message)
  assert(raised(a.request, nil))

  -- And the one probe that never raises, whatever it is handed.
  assert(f.exists(nil) == false)
  assert(f.exists(12) == false)
end

function T.the_problems_read_in_a_fixed_order()
  -- The order is part of the contract: two runs of a broken wiring report the same list,
  -- so a diff of two reports is about the wiring and never about a hash.
  local want = { "no model port", "no fs port", "no sh port", "no clock port",
                 "no ask port", "no log port" }
  for _ = 1, 3 do
    local problems = port.check {}
    assert(#problems == #want, #problems)
    for i = 1, #want do assert(problems[i] == want[i], i .. ": " .. problems[i]) end
  end
  -- A port present but owing its functions is named in the same place in the order.
  local mixed = port.check { model = double.model(), fs = {}, sh = double.sh(),
                             clock = double.clock(), ask = double.ask(true), log = double.log() }
  assert(#mixed == 5)
  assert(mixed[1] == "fs.read is not a function")
  assert(mixed[5] == "fs.exists is not a function")
end

function T.a_malformed_fixture_is_refused_when_the_double_is_built()
  -- A fixture that could not exist is a bug in the test, and it should say so at once
  -- rather than at the call that trips over it.
  assert(raised(double.fs, { ["../secrets"] = "x" }))
  assert(raised(double.fs, { ["/etc/passwd"] = "x" }))
  assert(raised(double.fs, { ["a//b"] = "x" }))
  assert(raised(double.fs, { ["a\\b"] = "x" }))
  assert(raised(double.fs, { ["a.txt"] = 12 }))
  assert(raised(double.fs, { [3] = "x" }))
  assert(raised(double.fs, { ["/"] = true }))
  assert(raised(double.model, { after = "carry on" }))
  assert(raised(double.model, { replies = "one" }))
  assert(raised(double.sh, { [3] = { code = 0 } }))
  assert(raised(double.clock, { at = "noon" }))
  assert(raised(double.ask, 7))
  assert(raised(double.world, "a world"))
end

function T.a_directory_is_not_a_file_and_says_so()
  local f = double.fs { ["src/turn.lua"] = "-- ...", ["tmp/"] = true }
  -- Neither call recurses and neither pretends to have done something.
  local listed, le = f.list("src/turn.lua")
  assert(listed == nil and le.code == "not_found", "listing a file is not a listing")
  local wrote, we = f.write("src", "clobbered")
  assert(wrote == nil and we.code == "exists", "a directory is already there")
  local gone, ge = f.remove("src")
  assert(gone == nil and ge.code == "denied", "removing a directory is refused, not done")
  local gone2, ge2 = f.remove("tmp")
  assert(gone2 == nil and ge2.code == "denied")
  local text, te = f.read("src")
  assert(text == nil and te.code == "not_found" and text ~= "")
  -- And nothing above quietly happened anyway.
  assert(f.read("src/turn.lua") == "-- ...")
  assert(#f.wrote == 0 and #f.removed == 0)
  assert(f.exists("src") and f.exists("tmp"))
end

function T.a_world_nobody_configured_answers_for_nothing()
  -- An empty double refuses rather than agrees, so a world nobody wired cannot quietly
  -- answer for the world and turn a broken agent into a green test.
  local p = double.world()
  assert(#port.check(p) == 0)

  local reply, me = p.model.call { model = "m", messages = {} }
  assert(reply == nil and me.code == "exhausted")
  local text, fe = p.fs.read("a.txt")
  assert(text == nil and fe.code == "not_found" and text ~= "")
  assert(p.fs.exists("a.txt") == false)
  local result, se = p.sh.run { "rm", "-rf", "/" }
  assert(result == nil and se.code == "unscripted")
  assert(p.ask.request({ tool = "write", args = {} }).allow == false, "an empty world approves nothing")
  assert(p.clock.now() == 0 and p.clock.mono() == 0)
  assert(p.log.write("info", "e") == nil and #p.log.lines == 1)
end

function T.a_built_double_is_taken_as_it_stands()
  -- One filesystem handed to two worlds on purpose: the second sees the first's write.
  local f = double.fs { ["a.txt"] = "a" }
  local one, two = double.world { fs = f }, double.world { fs = f }
  assert(one.fs == f and two.fs == f)
  assert(one.fs.write("b.txt", "b") == true)
  assert(two.fs.read("b.txt") == "b")
  assert(one.model ~= two.model, "what was not handed over is still fresh per world")

  local m = double.model { replies = { "held" } }
  assert(double.world { model = m }.model == m)
  local c, a, l = double.clock { at = 7 }, double.ask(true), double.log()
  local w = double.world { clock = c, ask = a, log = l, sh = double.sh { ["ls"] = { code = 0 } } }
  assert(w.clock == c and w.ask == a and w.log == l and w.clock.now() == 7)

  -- A bare list is the common case: a model configured with nothing but its replies.
  local bare = double.world { model = { "one", "two" } }
  assert(bare.model.call(ask_of()).text == "one")
  assert(bare.model.call(ask_of()).text == "two")
  assert(#bare.model.seen == 2)
end

function T.every_double_is_fresh()
  -- Two doubles in one process cannot see each other, exactly as spec.new does.
  local one, two = double.fs { ["a.txt"] = "a" }, double.fs { ["a.txt"] = "a" }
  one.write("b.txt", "b")
  one.cap = 0
  assert(two.exists("b.txt") == false and #two.wrote == 0 and two.cap == nil)
  assert(two.read("a.txt") == "a", "a cap set on one filesystem is not set on the other")

  local first, second = double.ask { { allow = true } }, double.ask { { allow = true } }
  assert(first.request({ tool = "w", args = {} }).allow == true)
  assert(first.request({ tool = "w", args = {} }).allow == false, "the script ran out")
  assert(second.request({ tool = "w", args = {} }).allow == true, "and not on the other one")
  assert(#first.asked == 2 and #second.asked == 1)

  local la, lb = double.log(), double.log()
  la.write("info", "e")
  assert(#la.lines == 1 and #lb.lines == 0)

  local sa, sb = double.sh { ["ls"] = { code = 0 } }, double.sh { ["ls"] = { code = 0 } }
  sa.run { "ls" }
  assert(#sa.ran == 1 and #sb.ran == 0)
end

function T.a_reply_the_far_side_got_wrong_is_malformed_not_raised()
  -- The double answers as a bad far side would. Every one of these is a reply the port
  -- cannot read, and not one of them may reach the turn as a repaired reply.
  local function malformed(entry, why)
    local m = double.model { replies = { entry } }
    local reply, err = m.call(ask_of())
    assert(reply == nil, why)
    assert(port.is_error(err) and err.code == "malformed" and err.port == "model", why)
    return err
  end
  malformed({ text = "done", stop = "finish_reason" }, "a stop outside the four")
  malformed({ text = "done", stop = 7 }, "a stop that is not even a string")
  malformed({ text = { "a", "part" } }, "text is one string, never an array of parts")
  malformed({ text = "", calls = "read(a.txt)" }, "calls is a list")
  malformed({ text = "", calls = { "read" } }, "a call is a table")
  malformed({ text = "", calls = { { tool = "read", id = 3 } } }, "an id is a string")
  -- And the four it does know still go through.
  for stop in pairs { done = true, calls = true, cut = true, refused = true } do
    local m = double.model { replies = { { text = "x", stop = stop } } }
    assert(m.call(ask_of()).stop == stop)
  end
end

function T.a_decision_carries_nothing_but_the_decision()
  -- Whatever a scripted channel answers with, the harness reads a decision and only a
  -- decision: no field it did not ask for rides along to the gate.
  -- allow is required; why and remember are a string or nil. Nothing else is a field.
  local known = { allow = true, why = true, remember = true }
  local function only_a_decision(d)
    assert(type(d) == "table" and type(d.allow) == "boolean")
    for k in pairs(d) do assert(known[k], "a decision has no field called " .. tostring(k)) end
  end
  local a = double.ask(function ()
    return { allow = true, why = "fine", remember = "session",
             token = "sk-live-not-yours", allow_all = true }
  end)
  local d = a.request { tool = "write", args = {} }
  only_a_decision(d)
  assert(d.allow == true and d.why == "fine" and d.remember == "session")
  assert(d.token == nil and d.allow_all == nil, "a decision is not a place to smuggle a field")

  local by_tool = double.ask { write = { allow = false, why = "not outside src/", remember = "tool", note = {} } }
  local e = by_tool.request { tool = "write", args = {} }
  only_a_decision(e)
  assert(e.allow == false and e.remember == "tool")

  -- A refusal a person reads always carries a reason.
  local blanket = double.ask(false).request { tool = "write", args = {} }
  assert(blanket.allow == false and type(blanket.why) == "string" and #blanket.why > 0)
  only_a_decision(double.ask(true).request { tool = "read", args = {} })
end

function T.an_error_is_a_table_carrying_all_four_fields()
  -- is_error is what a caller branches on, so a table missing any one of the four is
  -- not an error and must not read as one.
  local whole = { port = "fs", call = "read", code = "not_found", message = "no such file: a" }
  assert(port.is_error(whole))
  for _, field in ipairs { "port", "call", "code", "message" } do
    local partial = {}
    for k, v in pairs(whole) do partial[k] = v end
    partial[field] = nil
    assert(port.is_error(partial) == false, "a table with no " .. field .. " is not an error")
    partial[field] = 7
    assert(port.is_error(partial) == false, field .. " is a string or it is not an error")
  end
  assert(port.is_error(nil) == false)
  assert(port.is_error("not_found") == false)
  assert(port.is_error({ allow = false, why = "no answer" }) == false, "a refusal is not an error")
end

return T
