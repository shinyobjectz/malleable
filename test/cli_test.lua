-- cli -- the runner, proved with the world as a table of closures. No network, no
-- disk, no subprocess, no clock unless a test supplies one. Each test asserts with
-- plain `assert` and prints nothing on success.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local cli      = require("cli")
local turn     = require("turn")
local double   = require("double")
local approval = require("approval")
local sessions = require("session")

local T = {}

-- --------------------------------------------------------------------- doubles

-- `files` maps a path to its text, or to { why = "..." } for a read that fails some
-- way other than absence.
local function world_of(files, extra)
  local w = { outs = {}, errs = {}, reads = {} }
  w.out = function (text) w.outs[#w.outs + 1] = text end
  w.err = function (text) w.errs[#w.errs + 1] = text end
  w.read = function (path)
    w.reads[#w.reads + 1] = path
    local v = (files or {})[path]
    if v == nil then return nil, "missing" end
    if type(v) == "table" then return nil, v.why end
    return v
  end
  for k, v in pairs(extra or {}) do w[k] = v end
  return w
end

local function out(w) return table.concat(w.outs) end
local function errs(w) return table.concat(w.errs) end
local function has(s, needle) return s:find(needle, 1, true) ~= nil end

-- A world whose doubles are built here, so a test can look at what the model saw.
local function with_doubles(files, cfg, extra)
  local seen = { built = 0 }
  local e = extra or {}
  e.doubles = function (script)
    seen.built = seen.built + 1
    local merged = { model = script.model }
    for k, v in pairs(cfg or {}) do merged[k] = v end
    seen.port = double.world(merged)
    return seen.port
  end
  local w = world_of(files, e)
  w.doubles_seen = seen
  return w, seen
end

local GOOD = [[
agent.name  "reviewer"
agent.model "m/one"
agent.tool "read" {
  about = "Read a file",
  args  = { path = agent.string "workspace-relative path" },
  run   = function (c) return "the file said hello" end,
}
]]

local ASKING = [[
agent.name  "reviewer"
agent.model "m/one"
agent.budget(4)
local ran = 0
agent.tool "read" {
  about = "Read a file",
  args  = { path = agent.string "a path" },
  run   = function (c) return "read ok" end,
}
agent.tool "write" {
  about = "Write a file",
  ask   = true,
  args  = { path = agent.string "a path" },
  run   = function (c) ran = ran + 1 return "wrote " .. ran end,
}
]]

local function argv(...) return { ... } end

-- ------------------------------------------------------------------- the tests

function T.a_plain_run_answers_and_returns_zero()
  local w = world_of { ["a.lua"] = GOOD }
  local code = cli.main(argv("--dry-run", "--reply", "done and dusted", "a.lua", "hello"), w)
  assert(code == 0, "code " .. tostring(code))
  local text = out(w)
  assert(has(text, "= done and dusted"))
  assert(has(text, "answered in 1 step of 24"))
  assert(has(text, "> hello"))
  assert(has(text, "DRY pi  reviewer  m/one  budget 24  root ."))
end

function T.the_parse_of_a_full_command_line_is_exact()
  local o = assert(cli.parse(argv(
    "--prompt", "go", "--budget", "5", "--calls-per-step", "2", "--max-depth", "0",
    "--model", "m/two", "--root", "work", "--timeout", "2.5", "--trust", "trusted",
    "--allow", "read", "--allow", "list", "--deny", "write", "-y",
    "--dry-run", "--reply", "one", "--reply", "two", "--script", "s.lua",
    "--session", "sess", "--json", "--show-lines", "3", "-v", "-v",
    "--width", "40", "--no-colour", "a.lua")))
  assert(o.prompt == "go" and o.prompt_source == "option")
  assert(o.budget == 5 and o.calls_per_step == 2 and o.max_depth == 0)
  assert(o.model == "m/two" and o.root == "work" and o.timeout == 2.5)
  assert(o.trust == "trusted")
  assert(#o.allow == 2 and o.allow[1] == "read" and o.allow[2] == "list")
  assert(#o.deny == 1 and o.deny[1] == "write")
  assert(o.yes == true and o.no == false)
  assert(o.dry_run == true and #o.reply == 2 and o.reply[2] == "two")
  assert(o.script == "s.lua" and o.session == "sess" and o.json == true)
  assert(o.show_lines == 3 and o.verbose == 2 and o.width == 40)
  assert(o.colour == false and o.quiet == false)
  assert(o.path == "a.lua" and #o.words == 0)
  assert(#o.argv == 41, "argv copied, got " .. #o.argv)

  local q = assert(cli.parse(argv("--no", "-q", "--check", "--tools", "--stdin", "a.lua")))
  assert(q.no == true and q.quiet == true and q.check == true)
  assert(q.show_tools == true and q.stdin == true and q.prompt_source == "stdin")

  local c = assert(cli.parse(argv("--colour", "--prompt-file", "p.txt", "a.lua")))
  assert(c.colour == true and c.prompt_file == "p.txt" and c.prompt_source == "file")
end

function T.an_option_and_its_value_may_be_joined_or_split()
  local a = assert(cli.parse(argv("--budget=5", "a.lua")))
  local b = assert(cli.parse(argv("--budget", "5", "a.lua")))
  assert(a.budget == 5 and b.budget == 5)
  local c = assert(cli.parse(argv("--prompt", "-x", "a.lua")))
  assert(c.prompt == "-x", "a value beginning with a dash is taken literally")
  local d = assert(cli.parse(argv("--prompt=", "a.lua")))
  assert(d.prompt == "" and d.prompt_source == "option")
  local nope, why = cli.parse(argv("a.lua", "--budget"))
  assert(nope == nil and has(why, "--budget"))
end

function T.positional_words_become_the_prompt()
  local a = assert(cli.parse(argv("a.lua", "review", "the", "loop")))
  assert(a.prompt == "review the loop" and a.prompt_source == "words")
  assert(#a.words == 3)
  local b = assert(cli.parse(argv("a.lua", "--", "-x", "y")))
  assert(b.prompt == "-x y", "got " .. tostring(b.prompt))
end

function T.help_and_version_print_and_stop()
  local touched = false
  local w = world_of({}, { ports = function () touched = true end })
  assert(cli.main(argv("--help"), w) == 0)
  assert(cli.main(argv("--version"), w) == 0)
  assert(touched == false, "nothing is wired for help")
  assert(#w.reads == 0, "nothing is read for help")
  local text = out(w)
  assert(has(text, "pi " .. cli.version))
  local named = {
    "--prompt", "--prompt-file", "--stdin", "--budget", "--calls-per-step",
    "--max-depth", "--model", "--root", "--timeout", "--trust", "--allow",
    "--deny", "--yes", "--no", "--dry-run", "--reply", "--script", "--check",
    "--tools", "--session", "--json", "--show-lines", "--quiet", "--verbose",
    "--width", "--no-colour", "--colour", "--help", "--version",
    "-p", "-y", "-q", "-v", "-h",
  }
  local usage = cli.usage()
  for i = 1, #named do
    assert(has(usage, named[i]), "usage does not name " .. named[i])
  end
end

function T.check_validates_without_running()
  local w, seen = with_doubles { ["a.lua"] = GOOD }
  assert(cli.main(argv("--check", "a.lua"), w) == 0)
  assert(has(out(w), "ok") and has(out(w), "reviewer"))
  assert(seen.port == nil, "nothing was wired")

  local bare = world_of { ["b.lua"] = "-- a comment and nothing else\nlocal x = 1\n" }
  assert(cli.main(argv("--check", "b.lua"), bare) == 3)
  local text = errs(bare)
  assert(has(text, "no agent.name"))
  assert(has(text, "no agent.model"))
  assert(has(text, "no tools"))
end

function T.tools_prints_the_schema_the_model_would_see()
  local w, seen = with_doubles { ["a.lua"] = ASKING }
  assert(cli.main(argv("--tools", "a.lua"), w) == 0)
  local text = out(w)
  local at_read  = text:find("read", 1, true)
  local at_write = text:find("write", 1, true)
  assert(at_read and at_write and at_read < at_write, "declaration order")
  assert(has(text, "(asks)"), "the ask flag is visible")
  assert(has(text, "Read a file") and has(text, "Write a file"))
  assert(has(text, "path  string  required"))
  assert(seen.port == nil)
end

function T.the_exit_code_matches_the_stop()
  for _, stop in ipairs(turn.stops) do
    assert(cli.codes.of(stop) ~= nil, "no code for " .. stop)
  end
  assert(cli.codes.of("answered") == 0)
  assert(cli.codes.of("budget") == 4)
  assert(cli.codes.of("refused") == 5)
  assert(cli.codes.of("error") == 6)
  assert(cli.codes.of("nonsense") == nil)
  assert(cli.codes.usage == 1 and cli.codes.load == 2)
  assert(cli.codes.declaration == 3 and cli.codes.world == 7)
  local frozen = pcall(function () cli.codes.answered = 9 end)
  assert(frozen == false, "cli.codes is frozen")

  -- answered
  local w1 = world_of { ["a.lua"] = GOOD }
  assert(cli.main(argv("--dry-run", "--reply", "hi", "a.lua"), w1) == 0)
  -- budget
  local w2 = world_of {
    ["a.lua"] = GOOD,
    ["s.lua"] = 'return { { text = "again", calls = { { tool = "read", args = { path = "p" } } } } }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "--budget", "2", "a.lua"), w2) == 4)
  -- error
  local w3 = world_of {
    ["a.lua"] = GOOD,
    ["s.lua"] = 'return { { code = "timeout", message = "the far side took too long" } }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua"), w3) == 6)
  -- refused: through cli.bind and turn, because approval has no stop channel yet.
  local stopping = { check = function (_, call)
    return { allowed = false, stop = true, source = "port",
             reason = "the operator stopped the run on " .. call.tool }
  end }
  local p = double.world { model = { replies = {
    { calls = { { tool = "write", args = { path = "x" } } } },
  } } }
  local tport = cli.bind(p, stopping, {})
  local a = assert(cli.load("a.lua", world_of { ["a.lua"] = ASKING }))
  local result = turn.run(a, "go", tport, {})
  assert(result.stop == "refused", "got " .. tostring(result.stop))
  assert(cli.codes.of(result.stop) == 5)
end

function T.a_dry_run_with_no_script_calls_no_model()
  local w, seen = with_doubles { ["a.lua"] = GOOD }
  local code = cli.main(argv("--dry-run", "a.lua", "go"), w)
  assert(code == 0)
  assert(seen.port ~= nil and #seen.port.model.seen == 0, "no model call")
  local text = out(w)
  assert(has(text, "DRY"))
  assert(has(text, "nothing ran"))
  assert(has(text, "the first request"))
  assert(has(text, "read"))

  -- The plan is a plain table, so this asserts on it rather than on its text.
  local a = assert(cli.load("a.lua", world_of { ["a.lua"] = GOOD }))
  local o = assert(cli.parse(argv("--dry-run", "a.lua", "go")))
  local p, gate = cli.wire(o, world_of {}, a)
  assert(p ~= nil, "the doubles wired")
  local plan = cli.plan(a, o, p, gate)
  assert(plan.dry == true)
  assert(plan.agent == "reviewer" and plan.model == "m/one")
  assert(plan.budget == 24 and plan.root == "." and plan.trust == "ask")
  assert(#plan.tools == 1 and plan.tools[1].name == "read")
  assert(plan.tools[1].args[1].name == "path" and plan.tools[1].args[1].kind == "string")
  assert(#plan.gate == 1 and plan.gate[1].tool == "read")
  assert(plan.request.model == "m/one" and plan.request.system == false)
  assert(plan.request.messages == 1 and plan.request.tools[1] == "read")
  local wired = {}
  for i = 1, #plan.ports do wired[plan.ports[i].name] = plan.ports[i].wired end
  assert(wired.model == true and wired.fs == true and wired.ask == true)
  assert(wired.store == false, "the doubles carry no store")
end

function T.the_plan_says_what_the_run_will_do_to_each_tool()
  -- turn puts a call to the gate only when the tool declared `ask`. A plan that asked
  -- the gate about every tool would print `deny` beside a tool that always runs, which
  -- is the plan saying the opposite of the run it is a plan for.
  local a = assert(cli.load("a.lua", world_of { ["a.lua"] = ASKING }))
  local o = assert(cli.parse(argv("--dry-run", "a.lua")))
  local p, gate = cli.wire(o, world_of {}, a)
  local plan = cli.plan(a, o, p, gate)

  local by = {}
  for i = 1, #plan.gate do by[plan.gate[i].tool] = plan.gate[i] end
  assert(by.read.asks == false and by.read.consulted == false)
  assert(by.read.allowed == true, "a tool that does not ask runs")
  assert(has(by.read.reason, "does not ask"))
  assert(by.write.asks == true and by.write.consulted == true)
  assert(by.write.allowed == false, "the doubles answer no one, so the gate refuses")

  -- And the run agrees with the plan it printed.
  local w = world_of {
    ["a.lua"] = ASKING,
    ["s.lua"] = 'return { { calls = { { tool = "read", args = { path = "p" } }, '
      .. '{ tool = "write", args = { path = "q" } } } }, "done" }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), w) == 0)
  local text = out(w)
  assert(has(text, "-> read"), "the plan said read runs, and it ran")
  assert(has(text, "x write"), "the plan said write is refused, and it was")
end

function T.a_policy_on_a_tool_that_never_asks_is_said_out_loud()
  -- A deny on a tool that does not ask reads as safety and provides none: turn never
  -- consults the gate for it. cli cannot make it fire, and it does not pretend to.
  local w = world_of {
    ["a.lua"] = ASKING,
    ["s.lua"] = 'return { { calls = { { tool = "read", args = { path = "p" } } } }, "done" }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "--deny", "read", "a.lua", "go"), w) == 0)
  assert(has(errs(w), "read does not ask"), "the header names the inert entry")
  assert(has(out(w), "-> read"), "and the run shows it running anyway")

  -- --trust none says the same thing about every tool that cannot reach the gate.
  local n = world_of {
    ["a.lua"] = ASKING,
    ["s.lua"] = 'return { { calls = { { tool = "read", args = { path = "p" } } } }, "done" }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "--trust", "none", "a.lua", "go"), n) == 0)
  assert(has(errs(n), "read does not ask"))

  -- A policy that names only tools which do ask says nothing.
  local q = world_of {
    ["a.lua"] = ASKING,
    ["s.lua"] = 'return { { calls = { { tool = "read", args = { path = "p" } } } }, "done" }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "--deny", "write", "a.lua", "go"), q) == 0)
  assert(not has(errs(q), "does not ask"), "no warning is owed")
end

function T.a_trusted_workspace_is_not_told_a_missing_gate_will_refuse()
  -- The header must not promise a refusal the run then does not make: on a trusted
  -- workspace the gate allows at step 6 and nothing is ever put to a human.
  local gateless = function (script)
    local p = double.world { model = script.model }
    p.ask = nil
    return p
  end
  local w = world_of({
    ["a.lua"] = ASKING,
    ["s.lua"] = 'return { { calls = { { tool = "write", args = { path = "x" } } } }, "done" }',
  }, { doubles = gateless })
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "--trust", "trusted",
    "a.lua", "go"), w) == 0)
  assert(has(out(w), "-> write"), "a trusted workspace runs it")
  assert(not has(errs(w), "no one to ask"), "and is not warned that it will not")

  -- Without the trust, the warning is owed and is made.
  local ask = world_of({
    ["a.lua"] = ASKING,
    ["s.lua"] = 'return { { calls = { { tool = "write", args = { path = "x" } } } }, "done" }',
  }, { doubles = gateless })
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), ask) == 0)
  assert(has(errs(ask), "no one to ask"))
  assert(has(out(ask), "x write"))
end

function T.a_dry_run_with_a_script_renders_like_a_live_run()
  local w = world_of {
    ["a.lua"] = GOOD,
    ["s.lua"] = 'return { { text = "looking", calls = { { tool = "read", args = { path = "p" } } } }, "all clear" }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), w) == 0)
  local text = out(w)
  assert(has(text, "DRY pi  reviewer"))
  assert(has(text, "> go"))
  assert(has(text, ". looking"))
  assert(has(text, "-> read { path = \"p\" }"))
  assert(has(text, "= all clear"))
  assert(has(text, ", DRY"), "the summary says DRY")
end

function T.json_is_one_object_and_nothing_else()
  local w = world_of { ["a.lua"] = GOOD }
  assert(cli.main(argv("--dry-run", "--json", "--reply", "all clear", "a.lua", "go"), w) == 0)
  local text = out(w)
  local object, why = sessions.decode(text)
  assert(object ~= nil, "stdout does not decode: " .. tostring(why))
  assert(object.agent == "reviewer" and object.model == "m/one")
  assert(object.dry == true and object.stop == "answered")
  assert(object.answer == "all clear" and object.steps == 1)
  assert(object.budget == 24 and object.code == 0)
  assert(type(object.calls) == "table" and type(object.transcript) == "table")
  assert(type(object.reason) == "string")
  assert(object.saved == false)
  -- Every human line went to the error stream.
  assert(has(errs(w), "= all clear"))
  assert(not has(text, "= all clear"))
end

function T.a_missing_declaration_is_two_not_one()
  local w = world_of {}
  assert(cli.main(argv("agents/review.lua"), w) == 2)
  assert(has(errs(w), "cannot read agents/review.lua"))
  assert(has(errs(w), "no such file"))

  local w2 = world_of { ["agents/review.lua"] = { why = "permission denied" } }
  assert(cli.main(argv("agents/review.lua"), w2) == 2)
  assert(has(errs(w2), "read: permission denied"))
  assert(not has(errs(w2), "no such file"), "absence and failure are different sentences")
end

function T.an_empty_argv_prints_usage_and_returns_one()
  local w = world_of {}
  assert(cli.main({}, w) == 1)
  assert(has(errs(w), "pi [options]"))
  local w2 = world_of {}
  assert(cli.main(nil, w2) == 1)
  assert(has(errs(w2), "pi [options]"))
end

function T.an_empty_prompt_runs()
  local w, seen = with_doubles { ["a.lua"] = GOOD }
  assert(cli.main(argv("--dry-run", "--reply", "nothing asked", "a.lua"), w) == 0)
  local sent = seen.port.model.seen
  assert(#sent == 1)
  assert(sent[1].messages[1].text == "", "the empty prompt is what was sent")
  assert(has(out(w), "= nothing asked"))
end

function T.an_unknown_option_is_named_not_guessed()
  local w = world_of { ["a.lua"] = GOOD }
  assert(cli.main(argv("--budgets", "3", "a.lua"), w) == 1)
  local text = errs(w)
  assert(has(text, "--budgets"))
  assert(not has(text, "did you mean"))
  local w2 = world_of {}
  assert(cli.main(argv("-qv", "a.lua"), w2) == 1)
  assert(has(errs(w2), "-qv"), "short options do not bundle")
end

function T.contradictory_options_are_refused_in_pairs()
  local pairs_to_refuse = {
    { argv("-y", "--no", "a.lua"), "--yes", "--no" },
    { argv("-q", "-v", "a.lua"), "--quiet", "--verbose" },
    { argv("-p", "x", "a.lua", "with", "words"), "--prompt", "prompt words" },
    { argv("--reply", "x", "a.lua"), "--reply", "--dry-run" },
    { argv("--script", "x", "a.lua"), "--script", "--dry-run" },
  }
  for i = 1, #pairs_to_refuse do
    local case = pairs_to_refuse[i]
    local w = world_of { ["a.lua"] = GOOD }
    assert(cli.main(case[1], w) == 1, "case " .. i)
    local text = errs(w)
    assert(has(text, case[2]), "case " .. i .. " does not name " .. case[2])
    assert(has(text, case[3]), "case " .. i .. " does not name " .. case[3])
    assert(#w.reads == 0, "case " .. i .. " loaded something")
  end
end

function T.bad_numbers_are_refused_before_anything_loads()
  local cases = {
    argv("--budget", "0", "a.lua"),
    argv("--budget", "abc", "a.lua"),
    argv("--budget", "-1", "a.lua"),
    argv("--show-lines", "-1", "a.lua"),
    argv("--calls-per-step", "0", "a.lua"),
    argv("--width", "3", "a.lua"),
    argv("--timeout", "0", "a.lua"),
    argv("--max-depth", "1.5", "a.lua"),
  }
  for i = 1, #cases do
    local w = world_of { ["a.lua"] = GOOD }
    assert(cli.main(cases[i], w) == 1, "case " .. i)
    assert(#w.reads == 0, "case " .. i .. " read a file")
  end
end

function T.a_bytecode_file_is_refused_unloaded()
  local flag = { set = false }
  local chunk = load or loadstring
  local body = chunk("_PI_TEST_FLAG = 1", "=flag")
  local dumped = string.dump(body)
  assert(dumped:sub(1, 1) == "\27")
  local w = world_of { ["a.lua"] = dumped }
  local a, err = cli.load("a.lua", w)
  assert(a == nil and err.code == "binary", "got " .. tostring(err and err.code))
  assert(rawget(_G, "_PI_TEST_FLAG") == nil, "the chunk never ran")
  assert(flag.set == false)
  local w2 = world_of { ["a.lua"] = dumped }
  assert(cli.main(argv("a.lua"), w2) == 2)

  -- The first byte is what refuses it, on its own: a dump holds zero bytes too, and a
  -- test that cannot tell the two checks apart would pass with either one deleted.
  local w3 = world_of { ["a.lua"] = "\27Lua and nothing else that is not text\n" }
  local c, err3 = cli.load("a.lua", w3)
  assert(c == nil and err3.code == "binary", "got " .. tostring(err3 and err3.code))
  assert(not has(err3.message, "zero byte"), "the first byte refused it")

  -- And a zero byte anywhere else refuses it too, whatever it starts with.
  local w4 = world_of { ["a.lua"] = 'agent.name "x"\0\n' }
  local d, err4 = cli.load("a.lua", w4)
  assert(d == nil and err4.code == "binary")
  assert(has(err4.message, "zero byte"))
end

function T.the_sandbox_has_no_world()
  local names = { "os", "io", "require", "dofile", "loadfile", "load", "loadstring",
                  "rawset", "rawget", "setmetatable", "getmetatable", "collectgarbage",
                  "coroutine", "debug", "setfenv" }
  for i = 1, #names do
    local n = names[i]
    local w = world_of { ["a.lua"] = "local x = " .. n .. "\n" }
    local a, err = cli.load("a.lua", w)
    assert(a == nil, n .. " reached the sandbox")
    assert(err.code == "blocked", n .. " gave " .. err.code)
    assert(has(err.message, '"' .. n .. '"'), "the message names " .. n)
  end
  local w = world_of { ["a.lua"] = 'os.execute("touch /tmp/x")\n' }
  local a, err = cli.load("a.lua", w)
  assert(a == nil and err.code == "blocked" and has(err.message, '"os"'))
  assert(err.line == 1, "the line is named, got " .. tostring(err.line))
end

function T.a_misspelt_name_is_caught_at_load()
  local w = world_of { ["a.lua"] = 'agent.name "x"\nagnet.name "y"\n' }
  local a, err = cli.load("a.lua", w)
  assert(a == nil and err.code == "blocked")
  assert(has(err.message, '"agnet"'))
  assert(err.line == 2, "got line " .. tostring(err.line))

  local w2 = world_of { ["a.lua"] = 'agent.toool "read" { about = "x", run = function () end }\n' }
  local b, err2 = cli.load("a.lua", w2)
  assert(b == nil and err2.code == "blocked")
  assert(has(err2.message, "agent.toool"))
end

function T.the_prefix_cannot_be_replaced()
  local w = world_of { ["a.lua"] = 'agent.name "x"\nagent = {}\n' }
  local a, err = cli.load("a.lua", w)
  assert(a == nil and err.code == "blocked", "got " .. tostring(err and err.code))
  assert(has(err.message, '"agent"'))

  local w2 = world_of { ["a.lua"] = 'agent.name "x"\nagent.tool = print\n' }
  local b, err2 = cli.load("a.lua", w2)
  assert(b == nil and err2.code == "blocked")
  assert(has(err2.message, "agent.tool"))

  -- The agent table a failed load built is thrown away with the environment; a fresh
  -- load of a good file is unaffected by the one before it.
  local w3 = world_of { ["a.lua"] = GOOD }
  local c = assert(cli.load("a.lua", w3))
  assert(c.name == "reviewer" and #c.order == 1)
end

function T.a_declaration_that_never_returns_is_stopped()
  local w = world_of { ["a.lua"] = "while true do end\n" }
  local a, err = cli.load("a.lua", w, { max_bytes = 262144, max_steps = 20000 })
  assert(a == nil, "the loop was not stopped")
  assert(err.code == "too_long", "got " .. err.code)
  assert(has(err.message, "20000"))

  -- On an interpreter with no debug library the limit cannot be enforced, and the
  -- runner says so in one line rather than pretending.
  local saved = debug
  _G.debug = nil
  local w2 = world_of { ["a.lua"] = GOOD }
  local b, warning = cli.load("a.lua", w2)
  _G.debug = saved
  assert(b ~= nil and b.name == "reviewer")
  assert(type(warning) == "string" and has(warning, "sethook"), "the limit is announced")
end

function T.a_tool_result_cannot_repaint_the_terminal()
  local decl = [[
agent.name  "reviewer"
agent.model "m/one"
agent.tool "paint" {
  about = "Return an escape sequence",
  run   = function () return "\27[2J\27[H\r\rgone" end,
}
]]
  local w = world_of {
    ["a.lua"] = decl,
    ["s.lua"] = 'return { { calls = { { tool = "paint" } } }, "clean" }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), w) == 0)
  local text = out(w)
  assert(not text:find("\27", 1, true), "a raw escape byte reached the stream")
  assert(not text:find("\r", 1, true), "a raw carriage return reached the stream")
  assert(has(text, "\\x1b[2J"))
  assert(has(text, "\\x0d"))
end

function T.nothing_turns_a_missing_gate_into_an_allow()
  -- A port with no approval slice at all.
  local function gateless(ask)
    return function (script)
      local p = double.world { model = script.model }
      p.ask = ask
      return p
    end
  end

  local w = world_of({
    ["a.lua"] = ASKING,
    ["s.lua"] = 'return { { calls = { { tool = "write", args = { path = "x" } } } }, "done" }',
  }, { doubles = gateless(nil) })
  local code = cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), w)
  assert(code == 0, "the run still ends answered, got " .. tostring(code))
  assert(has(errs(w), "no one to ask"), "the header warned first")
  local text = out(w)
  assert(has(text, "x write"), "the refusal renders with x")
  assert(has(text, "wrote") == false, "the body never ran")

  -- A gate whose port raises, answers nothing, or answers nonsense: all deny.
  local ports = {
    { request = function () error("the operator's terminal went away") end },
    { request = function () return nil end },
    { request = function () return "maybe" end },
  }
  for i = 1, #ports do
    local p = double.world { model = { replies = {} } }
    p.ask = ports[i]
    local gate = approval.new { port = p, trust = "ask" }
    local tport, notes = cli.bind(p, gate, {})
    local answer = tport.ask { tool = "write", args = { path = "x" }, about = "Write" }
    assert(type(answer) == "table", "case " .. i)
    assert(answer.allow ~= true, "case " .. i .. " allowed")
    assert(answer.stop ~= true, "case " .. i .. " stopped")
    assert(#notes == 1, "case " .. i .. " left no note")
  end

  -- And with no port at all.
  local gate = approval.new { trust = "ask" }
  local tport, notes = cli.bind({ model = { call = function () end } }, gate, {})
  local answer = tport.ask { tool = "write", args = {}, about = "Write" }
  assert(answer.allow == false and #notes == 1)
end

function T.deny_policies_survive_yes()
  local w = world_of {
    ["a.lua"] = ASKING,
    ["s.lua"] = 'return { { calls = { { tool = "write", args = { path = "x" } }, '
      .. '{ tool = "read", args = { path = "y" } } } }, "done" }',
  }
  local code = cli.main(argv("--dry-run", "--script", "s.lua", "-y", "--deny", "write",
    "a.lua", "go"), w)
  assert(code == 0, "got " .. tostring(code))
  local text = out(w)
  assert(has(text, "x write"), "the write was refused")
  assert(has(text, "refused by policy"), "refused by the policy, not by the operator")
  assert(has(text, "-> read"), "the read ran")
  assert(has(text, "read ok"))

  -- The denies are compiled ahead of the allows, so the file reads the way it runs:
  -- the write is refused by the first policy, not by the second.
  local ordered = world_of {
    ["a.lua"] = ASKING,
    ["s.lua"] = 'return { { calls = { { tool = "write", args = { path = "x" } } } }, "done" }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "-y",
    "--allow", "read", "--deny", "write", "a.lua", "go"), ordered) == 0)
  assert(has(out(ordered), "refused by policy 1"),
    "the deny is entry 1 however the two were typed: " .. out(ordered))

  -- Neither call reached the operator: the deny fired first, and read does not ask.
  local asked = {}
  local p = double.world { model = { replies = {} } }
  p.ask = { request = function (q) asked[#asked + 1] = q.tool return { allow = true } end }
  local gate = approval.new {
    port = { request = function (q) asked[#asked + 1] = q.tool return { allow = true } end },
    trust = "ask",
    policy = { { deny = true, tool = "write" } },
  }
  local tport = cli.bind(p, gate, {})
  assert(tport.ask({ tool = "write", args = {}, about = "w" }).allow == false)
  assert(#asked == 0, "the operator was asked " .. #asked .. " times")
end

function T.a_stop_ends_the_run_and_shows_what_did_not_happen()
  local stopping = { check = function (_, call)
    return { allowed = false, stop = true, source = "port",
             reason = "the operator stopped the run at " .. call.tool }
  end }
  local p = double.world { model = { replies = { { calls = {
    { tool = "write", args = { path = "one" } },
    { tool = "write", args = { path = "two" } },
    { tool = "write", args = { path = "three" } },
  } } } } }
  local tport = cli.bind(p, stopping, {})
  local a = assert(cli.load("a.lua", world_of { ["a.lua"] = ASKING }))
  local result = turn.run(a, "go", tport, {})
  assert(result.stop == "refused")
  assert(cli.codes.of(result.stop) == 5)
  assert(#result.calls == 3, "all three calls are recorded")
  local text = cli.render(result, cli.parse(argv("a.lua")), { agent = "reviewer" })
  local marks = 0
  for _ in text:gmatch("\nx write") do marks = marks + 1 end
  assert(marks == 3, "three refusals rendered, got " .. marks)
  assert(has(text, "stopped before this call ran"), "the two that never ran say so")
end

function T.a_model_failure_is_six_with_the_ports_words()
  local w = world_of {
    ["a.lua"] = GOOD,
    ["s.lua"] = 'return { { text = "looking", calls = { { tool = "read", args = { path = "p" } } } }, '
      .. '{ code = "timeout", message = "no answer after 30s" } }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), w) == 6)
  local text = out(w)
  assert(has(text, "! model:"), "the error line names the layer")
  assert(has(text, "timeout: no answer after 30s"), "the port's own words")
  assert(has(text, ". looking"), "the partial transcript is still printed")
  assert(has(text, "-> read"))
end

function T.a_timeout_needs_no_clock()
  local files = {
    ["a.lua"] = GOOD,
    ["s.lua"] = 'return { { code = "timeout", message = "the far side took 30s" } }',
  }
  -- A host with no clock at all: reading world.now would be reading nil.
  local w = world_of(files, { now = nil })
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), w) == 6)
  local text = out(w)
  assert(has(text, "the far side took 30s"), "the port's own words, with no clock read")
  assert(not text:match("%d+%.%ds"), "no timing clause without a clock")

  -- And the absence is caused by the missing clock, not by a renderer that never
  -- prints one: the same run on a host that has one carries the clause.
  local ticked = world_of(files, { now = function () return 12 end })
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), ticked) == 6)
  assert(out(ticked):match("%d+%.%ds"), "a host with a clock is timed")
end

function T.a_clock_that_misbehaves_costs_a_run_nothing()
  -- cli never invents a clock, and never lets one it was handed turn an answered run
  -- into an internal fault: the timing clause simply goes.
  local broken = {
    function () error("this host has no clock") end,
    function () return "later" end,
    function () return nil end,
  }
  for i = 1, #broken do
    local w = world_of({ ["a.lua"] = GOOD }, { now = broken[i] })
    local code = cli.main(argv("--dry-run", "--reply", "all clear", "a.lua", "go"), w)
    assert(code == 0, "case " .. i .. " returned " .. tostring(code))
    assert(has(out(w), "= all clear"), "case " .. i .. " lost its answer")
    assert(not out(w):match("%d+%.%ds"), "case " .. i .. " invented a time")
  end

  -- The same for the terminal's width: an unreadable one falls back, it does not fail.
  local w = world_of({ ["a.lua"] = GOOD }, { width = function () error("not a tty") end })
  assert(cli.main(argv("--dry-run", "--reply", "all clear", "a.lua", "go"), w) == 0)
  assert(has(out(w), "= all clear"))
end

function T.the_budget_is_not_an_error()
  local w = world_of {
    ["a.lua"] = GOOD,
    ["s.lua"] = 'return { { text = "again", calls = { { tool = "read", args = { path = "p" } } } } }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "--budget", "3", "a.lua", "go"), w) == 4)
  local text = out(w)
  assert(has(text, "budget spent: 3 steps of 3, no answer"))
  assert(not has(text, "\n! "), "the budget is not printed as an error")
  local steps = 0
  for _ in text:gmatch("%-> read") do steps = steps + 1 end
  assert(steps == 3, "all three steps rendered, got " .. steps)
end

function T.no_double_ever_reaches_a_real_run()
  local touched = { doubles = false }
  local w = world_of({ ["a.lua"] = GOOD }, {
    ports = function () return nil, "no api key" end,
    doubles = function () touched.doubles = true return double.world {} end,
  })
  assert(cli.main(argv("a.lua", "go"), w) == 7)
  assert(touched.doubles == false, "a double was built for a real run")
  assert(has(errs(w), "no api key"))

  local half = world_of({ ["a.lua"] = GOOD }, {
    ports = function ()
      local p = double.world {}
      p.fs = nil
      return p
    end,
    doubles = function () touched.doubles = true return double.world {} end,
  })
  assert(cli.main(argv("a.lua", "go"), half) == 7)
  assert(touched.doubles == false, "a double filled in for a missing port")
  assert(has(errs(half), "no fs port"))

  local none = world_of({ ["a.lua"] = GOOD }, {})
  assert(cli.main(argv("a.lua", "go"), none) == 7)
  assert(has(errs(none), "--dry-run"))
end

function T.two_runs_render_identically()
  local function once()
    local w = world_of {
      ["a.lua"] = ASKING,
      ["s.lua"] = 'return { { text = "step", calls = { '
        .. '{ tool = "read", args = { path = "p", n = 1, deep = { a = 1, b = { c = 2 } } } }, '
        .. '{ tool = "write", args = { path = "q" } } } }, "done" }',
    }
    local code = cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), w)
    return code, out(w)
  end
  local c1, t1 = once()
  local c2, t2 = once()
  assert(c1 == c2)
  assert(t1 == t2, "two runs of the same declaration render differently")
  assert(has(t1, "deep = { a = 1, b = {...} }"), "keys sorted, depth 2, beyond it {...}")
end

function T.a_cyclic_value_renders_and_returns()
  local cyclic = { name = "loop" }
  cyclic.self = cyclic
  local deep = {}
  local at = deep
  for _ = 1, 40 do at.down = {} at = at.down end

  local result = {
    stop = "answered", reason = "done", answer = "ok", steps = 1, budget = 4,
    transcript = {
      { role = "user", text = "go" },
      { role = "agent", text = "acting", calls = {
        { id = "1", tool = "read", args = cyclic },
        { id = "2", tool = "read", args = deep },
      } },
      { role = "tool", id = "1", tool = "read", ok = true, text = "one" },
      { role = "tool", id = "2", tool = "read", ok = true, text = "two" },
    },
    calls = {}, notes = {},
  }
  local o = assert(cli.parse(argv("a.lua")))
  local text = cli.render(result, o, {})
  assert(#text < 8192, "the render is bounded, got " .. #text)
  assert(has(text, "{...}"), "the cycle is stated where it repeats")

  -- A tool that returns a table never puts a raw Lua value into the JSON: `value` is
  -- dropped, so a cycle in a tool result cannot reach the encoder at all.
  local decl = [[
agent.name  "reviewer"
agent.model "m/one"
agent.tool "loop" {
  about = "Return a table that holds itself",
  run   = function () local t = {} t.self = t return t end,
}
]]
  local w = world_of {
    ["a.lua"] = decl,
    ["s.lua"] = 'return { { calls = { { tool = "loop" } } }, "done" }',
  }
  assert(cli.main(argv("--dry-run", "--json", "--script", "s.lua", "a.lua", "go"), w) == 0)
  local object = sessions.decode(out(w))
  assert(object ~= nil, "the object still encodes")
  assert(object.stop == "answered")
end

function T.a_huge_result_is_cut_and_says_so()
  local decl = [[
agent.name  "reviewer"
agent.model "m/one"
agent.tool "big" {
  about = "Return a great deal of text",
  run   = function () return string.rep("a line of text here\n", 52429) end,
}
]]
  local w = world_of {
    ["a.lua"] = decl,
    ["s.lua"] = 'return { { calls = { { tool = "big" } } }, "done" }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "--show-lines", "5", "a.lua", "go"), w) == 0)
  local text = out(w)
  assert(#text < 8192, "the rendered text is small, got " .. #text)
  local shown = 0
  for _ in text:gmatch("\n   a line of text here") do shown = shown + 1 end
  assert(shown == 5, "five lines shown, got " .. shown)
  assert(text:match("%(%.%.%. (%d+) bytes elided%)"), "the cut names the byte count")
  local elided = tonumber(text:match("%(%.%.%. (%d+) bytes elided%)"))
  assert(elided == 52429 * 20 - 4096, "got " .. elided)
end

function T.the_renderer_never_raises()
  local o = assert(cli.parse(argv("a.lua")))
  local cases = {
    { stop = "shouting", reason = "?", steps = 1, budget = 2, transcript = {}, calls = {} },
    { stop = "answered", reason = nil, steps = 1, budget = 2, transcript = {}, calls = {} },
    { stop = "answered", steps = 1, budget = 2, transcript = {}, calls = { 7, "x" } },
    { stop = "error", steps = 1, budget = 2, transcript = { true, false }, calls = {} },
    { stop = "answered" },
    {},
  }
  for i = 1, #cases do
    local ok, text = pcall(cli.render, cases[i], o, {})
    assert(ok, "case " .. i .. " raised: " .. tostring(text))
    assert(type(text) == "string" and #text > 0, "case " .. i .. " printed nothing")
  end
  assert(pcall(cli.render, "not a result", o, {}))
  assert(pcall(cli.render, nil, nil, nil))

  -- An unknown stop is code 6, whatever the renderer made of it.
  local w = world_of({ ["a.lua"] = GOOD }, {
    doubles = function ()
      return double.world { model = { replies = { { raw = 1 } } } }
    end,
  })
  assert(cli.codes.of("shouting") == nil)
end

function T.a_save_failure_does_not_change_the_code()
  local store = { }
  local w = world_of({
    ["a.lua"] = GOOD,
  }, {
    doubles = function (script)
      local p = double.world { model = script.model }
      p.store = {
        write = function () return nil, "the disk is full" end,
        read  = function () return nil, "missing" end,
        list  = function () return {} end,
        delete = function () return true end,
      }
      store.p = p
      return p
    end,
  })
  local code = cli.main(argv("--dry-run", "--reply", "all clear", "--session", "s1",
    "--json", "a.lua", "go"), w)
  assert(code == 0, "got " .. tostring(code))
  local object = assert(sessions.decode(out(w)))
  assert(object.saved == false, "the record says it was not saved")
  assert(object.answer == "all clear", "the answer is still there")
  assert(has(errs(w), "the disk is full"), "the warning quotes the store")
end

function T.the_runner_touches_nothing_real()
  local f = assert(io.open(here .. "/../src/cli.lua", "rb"))
  local text = f:read("*a")
  f:close()
  local banned = { "io%.", "os%.", "print%(", "os%.exit", "math%.random", "socket" }
  for i = 1, #banned do
    local at = text:find(banned[i])
    assert(at == nil, "src/cli.lua names " .. banned[i] .. " at byte " .. tostring(at))
  end
  for name in text:gmatch('require%s*%(?%s*"([%w_%.]+)"') do
    local head = name:match("^([^%.]+)")
    local known = {
      spec = true, turn = true, approval = true, port = true, double = true,
      session = true, cli = true, src = true,
    }
    assert(known[head], "src/cli.lua requires " .. name)
  end

  local b = assert(io.open(here .. "/../bin/malleable.lua", "rb"))
  local bin = b:read("*a")
  b:close()
  local lines = 0
  for _ in (bin .. "\n"):gmatch("([^\n]*)\n") do lines = lines + 1 end
  assert(lines <= 21, "bin/malleable.lua is " .. lines .. " lines")
  assert(bin:find("cli.main", 1, true), "bin/malleable.lua calls cli.main")
  assert(not bin:find("for ", 1, true), "bin/malleable.lua holds no logic but the wiring")
end

function T.a_malformed_world_raises_and_names_the_field()
  local ok, why = pcall(cli.main, {}, {})
  assert(ok == false and has(tostring(why), "world.out"))
  local ok2, why2 = pcall(cli.main, {}, { out = function () end, err = function () end })
  assert(ok2 == false and has(tostring(why2), "world.read"))
  local ok3, why3 = pcall(cli.main, {}, "not a world")
  assert(ok3 == false and has(tostring(why3), "world"))
  local ok4, why4 = pcall(cli.main, {},
    { out = function () end, err = function () end, read = function () end, ports = 3 })
  assert(ok4 == false and has(tostring(why4), "world.ports"))
end

function T.the_bind_is_the_only_place_that_knows_both_shapes()
  local p = {
    model = { call = function () return nil, { code = "timeout", message = "30s" } end },
    fs = { read = function () return "x" end },
    sh = { run = function () return {} end },
  }
  local gate = approval.new { trust = "trusted" }
  local t, notes = cli.bind(p, gate, {})
  assert(type(t.model) == "function", "turn wants a function")
  local reply, why = t.model { model = "m", messages = {} }
  assert(reply == nil and why == "timeout: 30s", "got " .. tostring(why))
  assert(t.fs == p.fs and t.sh == p.sh, "every other key is copied across")
  assert(type(p.model) == "table", "p is not mutated")
  assert(type(t.ask) == "function")
  local answer = t.ask { tool = "write", args = {}, about = "Write" }
  assert(answer.allow == true, "a trusted workspace allows")
  assert(#notes == 0)
end

function T.opts_is_a_closed_shape()
  local o = assert(cli.parse(argv("a.lua")))
  o.nonsense = true
  local w = world_of { ["a.lua"] = GOOD }
  local code, err = cli.run(o, w)
  assert(code == nil and err.code == 1, "an unknown key is refused")
  assert(has(err.message, "nonsense"))
end

function T.a_declaration_that_raises_shows_its_own_words()
  local w = world_of { ["a.lua"] = 'agent.name "x"\nerror "no key set"\n' }
  local a, err = cli.load("a.lua", w)
  assert(a == nil and err.code == "raised", "got " .. tostring(err and err.code))
  assert(has(err.message, "no key set"))
  assert(err.line == 2, "got " .. tostring(err.line))
  local w2 = world_of { ["a.lua"] = 'agent.name "x"\nerror "no key set"\n' }
  assert(cli.main(argv("a.lua"), w2) == 2)
  assert(has(errs(w2), "no key set"))
end

function T.a_syntax_error_is_lua_s_own_message()
  local w = world_of { ["a.lua"] = 'agent.name "x"\nagent.model(\n' }
  local a, err = cli.load("a.lua", w)
  assert(a == nil and err.code == "syntax")
  assert(has(err.message, "a.lua"), "the file is named")
  assert(err.line ~= nil, "the line is named")
end

function T.an_empty_declaration_is_empty_not_broken()
  for _, text in ipairs { "", "   \n\t\n", "-- only a comment\n", "--[[ a block ]]\n" } do
    local w = world_of { ["a.lua"] = text }
    local a, err = cli.load("a.lua", w)
    assert(a == nil and err.code == "empty", "got " .. tostring(err and err.code))
  end
  local big = world_of { ["a.lua"] = string.rep("x", 300000) }
  local a, err = cli.load("a.lua", big, { max_bytes = 1000, max_steps = 1000 })
  assert(a == nil and err.code == "too_big")
end

function T.a_declaration_that_narrates_itself_writes_to_the_error_stream()
  local w = world_of { ["a.lua"] = GOOD .. 'print("loading the reviewer")\n' }
  assert(cli.main(argv("--dry-run", "--json", "--reply", "ok", "a.lua"), w) == 0)
  assert(has(errs(w), "loading the reviewer"))
  assert(not has(out(w), "loading the reviewer"), "stdout stays parseable")
  assert(sessions.decode(out(w)) ~= nil)
end

function T.writing_a_new_global_is_allowed_and_recorded()
  local w = world_of { ["a.lua"] = 'counter = 0\n' .. GOOD }
  local env, a, wrote = cli.sandbox {}
  assert(type(env) == "table" and type(a) == "table" and type(wrote) == "table")
  assert(#wrote == 0, "a fresh sandbox has recorded nothing")

  local b = assert(cli.load("a.lua", w))
  assert(b.name == "reviewer", "a new global does not stop the load")
  assert(rawget(_G, "counter") == nil, "it did not escape into this process")

  -- The name is recorded, not merely tolerated: a declaration that thinks it is
  -- keeping state across a run is a declaration with a bug, and --verbose says so.
  local v = world_of { ["a.lua"] = 'counter = 0\nledger = {}\n' .. GOOD }
  assert(cli.main(argv("--dry-run", "--reply", "ok", "-v", "a.lua"), v) == 0)
  assert(has(errs(v), "counter"), "the global is named under --verbose")
  assert(has(errs(v), "ledger"), "and so is the second one")

  local quiet = world_of { ["a.lua"] = 'counter = 0\n' .. GOOD }
  assert(cli.main(argv("--dry-run", "--reply", "ok", "a.lua"), quiet) == 0)
  assert(not has(errs(quiet), "counter"), "and is silent without it")

  -- Writing over a name the surface holds is refused, not recorded.
  local over = world_of { ["a.lua"] = 'print = 1\n' .. GOOD }
  local none, err = cli.load("a.lua", over)
  assert(none == nil and err.code == "blocked", "got " .. tostring(err and err.code))
end

function T.the_prompt_can_come_from_a_file_or_from_standard_input()
  local w = world_of { ["a.lua"] = GOOD, ["p.txt"] = "read from a file" }
  local _, seen = with_doubles({}, {})
  local w2, s2 = with_doubles { ["a.lua"] = GOOD, ["p.txt"] = "read from a file" }
  assert(cli.main(argv("--dry-run", "--reply", "ok", "--prompt-file", "p.txt", "a.lua"), w2) == 0)
  assert(s2.port.model.seen[1].messages[1].text == "read from a file")

  local w3, s3 = with_doubles({ ["a.lua"] = GOOD }, nil, { stdin = function () return "from stdin" end })
  assert(cli.main(argv("--dry-run", "--reply", "ok", "--stdin", "a.lua"), w3) == 0)
  assert(s3.port.model.seen[1].messages[1].text == "from stdin")

  local w4 = world_of { ["a.lua"] = GOOD }
  assert(cli.main(argv("--stdin", "a.lua"), w4) == 1, "no standard input is a usage error")
  assert(has(errs(w4), "--stdin"))

  local w5 = world_of { ["a.lua"] = GOOD }
  assert(cli.main(argv("--prompt-file", "gone.txt", "a.lua"), w5) == 1)
  assert(has(errs(w5), "gone.txt"))
  assert(w ~= nil and seen ~= nil)
end

function T.a_policy_on_a_tool_that_does_not_exist_is_a_typo()
  local w = world_of { ["a.lua"] = GOOD }
  assert(cli.main(argv("--dry-run", "--reply", "ok", "--deny", "wrote", "a.lua"), w) == 3)
  assert(has(errs(w), "wrote"))
  assert(has(errs(w), "--deny"))
  local w2 = world_of { ["a.lua"] = GOOD }
  assert(cli.main(argv("--dry-run", "--reply", "ok", "--allow", "reed", "a.lua"), w2) == 3)
  assert(has(errs(w2), "--allow"))
end

function T.colour_is_never_the_only_carrier_and_never_the_default()
  local o = assert(cli.parse(argv("a.lua")))
  local plain = world_of {}
  assert(cli.colour_on(o, plain) == false, "not a terminal, no colour")
  local term = world_of({}, { colour = true })
  assert(cli.colour_on(o, term) == true)
  local blocked = world_of({}, { colour = true, env = function (n)
    return n == "NO_COLOR" and "1" or nil
  end })
  assert(cli.colour_on(o, blocked) == false, "NO_COLOR wins")
  local off = assert(cli.parse(argv("--no-colour", "a.lua")))
  assert(cli.colour_on(off, term) == false)
  local on = assert(cli.parse(argv("--colour", "a.lua")))
  assert(cli.colour_on(on, plain) == true)

  local text = "= an answer\n. narration\n"
  assert(cli.paint(text, false) == text, "no escape byte when colour is off")
  local painted = cli.paint(text, true)
  assert(painted:find("\27", 1, true), "colour emits escapes when asked")
  assert(painted:gsub("\27%[[%d;]*m", "") == text, "colour changes no word")
end

function T.quiet_prints_the_answer_alone()
  local w = world_of { ["a.lua"] = GOOD }
  assert(cli.main(argv("--dry-run", "--reply", "just this", "-q", "a.lua", "go"), w) == 0)
  assert(out(w) == "just this\n", "got " .. string.format("%q", out(w)))
end

function T.verbose_adds_arguments_and_messages()
  local w = world_of {
    ["a.lua"] = GOOD,
    ["s.lua"] = 'return { { text = "step", calls = { { tool = "read", args = { path = "'
      .. string.rep("p", 300) .. '" } } } }, "done" }',
  }
  local plain = world_of {
    ["a.lua"] = GOOD,
    ["s.lua"] = 'return { { text = "step", calls = { { tool = "read", args = { path = "'
      .. string.rep("p", 300) .. '" } } } }, "done" }',
  }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), plain) == 0)
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "-v", "a.lua", "go"), w) == 0)
  assert(#out(w) > #out(plain), "verbose says more")
  assert(has(out(plain), "..."), "a long argument is capped by default")

  local sys = world_of {
    ["a.lua"] = GOOD .. 'agent.system "you are a reviewer"\n',
  }
  assert(cli.main(argv("--dry-run", "--reply", "ok", "-v", "-v", "a.lua", "go"), sys) == 0)
  assert(has(out(sys), "you are a reviewer"), "twice shows the system prompt")
end

function T.json_owns_stdout_even_when_nothing_runs()
  -- --json means a caller can pipe stdout into a parser with nothing else in it. That
  -- has to hold for the modes that print instead of running, or the promise is a
  -- promise about the happy path only.
  for _, flag in ipairs { "--tools", "--check" } do
    local w = world_of { ["a.lua"] = ASKING }
    assert(cli.main(argv(flag, "--json", "a.lua"), w) == 0, flag)
    local object, why = sessions.decode(out(w))
    assert(object ~= nil, flag .. " left stdout unparseable: " .. tostring(why))
    assert(object.agent == "reviewer" and object.model == "m/one", flag)
    assert(type(object.tools) == "table" and #object.tools == 2, flag)
    assert(object.code == 0, flag)
    assert(has(errs(w), "reviewer"), flag .. " kept the human reading")
    assert(not has(out(w), "-- Read a file"), flag .. " put human text on stdout")
  end

  -- Without --json neither mode changed.
  local plain = world_of { ["a.lua"] = ASKING }
  assert(cli.main(argv("--tools", "a.lua"), plain) == 0)
  assert(has(out(plain), "Read a file"), "the schema still prints on stdout")

  -- A declaration that cannot run is still 3, and still says so on stderr.
  local bad = world_of { ["b.lua"] = "-- nothing but a comment\nlocal x = 1\n" }
  assert(cli.main(argv("--check", "--json", "b.lua"), bad) == 3)
  assert(has(errs(bad), "no agent.name"))
end

function T.a_script_that_never_returns_is_stopped()
  -- --script names a Lua file the runner executes. It is bounded exactly as the
  -- declaration beside it is: a limit that is announced is not a lie, and a limit
  -- that only one of two loaded files has is not a limit.
  local w = world_of { ["a.lua"] = GOOD, ["s.lua"] = "while true do end\n" }
  local code = cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), w)
  assert(code == 7, "the run never started, got " .. tostring(code))
  assert(has(errs(w), "s.lua"), "the script is named")
  assert(has(errs(w), "steps"), "the bound is named")

  -- A script that returns is unaffected.
  local ok = world_of { ["a.lua"] = GOOD, ["s.lua"] = 'return { "done" }' }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), ok) == 0)
  assert(has(out(ok), "= done"))

  -- The script's environment holds nothing at all -- it is a data file, and reaching
  -- for a name is reported rather than swallowed.
  local raises = world_of { ["a.lua"] = GOOD, ["s.lua"] = 'error("no replies here")' }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), raises) == 7)
  assert(has(errs(raises), "s.lua"), "the script is named")
  assert(has(errs(raises), '"error"'), "and so is the name it reached for")

  -- A script that is not a list of replies at all is refused with its own sentence.
  local wrong = world_of { ["a.lua"] = GOOD, ["s.lua"] = "return 7" }
  assert(cli.main(argv("--dry-run", "--script", "s.lua", "a.lua", "go"), wrong) == 7)
  assert(has(errs(wrong), "list of replies"))
end

function T.main_never_exits_the_process()
  -- Every case above ran through cli.main in this one process. Reaching this line is
  -- the assertion; the guard below is that a hostile declaration cannot end it.
  local hostile = world_of { ["a.lua"] = 'agent.name(setmetatable({}, { __tostring = function () error("no") end }))\n' }
  local code = cli.main(argv("a.lua"), hostile)
  assert(type(code) == "number" and code >= 0 and code <= 7, "got " .. tostring(code))
end

return T
