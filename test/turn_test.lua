-- turn — the turn loop, proved against a scripted port. No network, no disk, no
-- subprocess, no clock. Each test asserts with plain `assert` and prints nothing.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local spec = require("spec")
local turn = require("turn")

local T = {}

-- ------------------------------------------------------------------- doubles

-- A scripted model port. Each entry is one reply, in order:
--   { text = "…", stop = "done" }            a final answer
--   { calls = { { tool = "read", args = … } } }   a request to act
--   { fail = { code = …, message = … } }     the port returns nil, err
--   { raise = v }                            the port raises v
--   { raw = v }                              the port returns v verbatim
--   a function (request) -> reply | nil, err
-- `loop` replays the last entry forever, which is how the runaway test feeds rule 5.
local function scripted(replies, extra)
  local p = { seen = {}, asked = {} }
  local i = 0
  p.model = {
    call = function (request)
      i = i + 1
      p.seen[#p.seen + 1] = request
      local r = replies[i]
      if r == nil and extra and extra.loop then r = replies[#replies] end
      if r == nil then
        return nil, { port = "model", call = "call", code = "exhausted",
                      message = "the script ran out after " .. #replies .. " replies" }
      end
      if type(r) == "function" then return r(request) end
      if r.raise ~= nil then error(r.raise) end
      if r.fail ~= nil then return nil, r.fail end
      if r.raw ~= nil then return r.raw end
      if r.nothing then return nil end
      local reply = { text = r.text, calls = r.calls or {}, stop = r.stop }
      if reply.stop == nil then
        reply.stop = (#reply.calls > 0) and "calls" or "done"
      end
      return reply
    end,
  }
  if extra then
    for k, v in pairs(extra) do
      if k ~= "loop" then p[k] = v end
    end
  end
  return p
end

-- A scripted approval gate in spec/port.md's shape.
local function gate(script)
  local i = 0
  local seen = {}
  return {
    request = function (request)
      i = i + 1
      seen[#seen + 1] = request
      local d = script
      if type(script) == "table" and script[1] ~= nil then d = script[i] end
      if type(d) == "function" then return d(request) end
      if d == nil then return { allow = false, why = "no answer" } end
      return d
    end,
    seen = seen,
  }
end

local function base(system)
  local a = spec.new()
  spec.set_name(a, "tester")
  spec.set_model(a, "test:model")
  if system ~= false then spec.set_system(a, system or "you test things") end
  return a
end

local function echo_tool(a, name, extra)
  local t = { about = "Echo a line back", args = { line = spec.types.string("what to echo") },
              run = function (c) return "echo " .. c.args.line end }
  for k, v in pairs(extra or {}) do t[k] = v end
  spec.add_tool(a, name or "echo", t)
  return a
end

local function roles(result)
  local out = {}
  for i = 1, #result.transcript do out[i] = result.transcript[i].role end
  return table.concat(out, ",")
end

local function same(x, y)
  if type(x) ~= type(y) then return false end
  if type(x) ~= "table" then return x == y end
  for k, v in pairs(x) do if not same(v, y[k]) then return false end end
  for k in pairs(y) do if x[k] == nil then return false end end
  return true
end

local function has(s, needle)
  return type(s) == "string" and s:find(needle, 1, true) ~= nil
end

local function raises(f, ...)
  local ok, err = pcall(f, ...)
  return (not ok), tostring(err)
end

-- --------------------------------------------------------------- the tests

function T.a_plain_answer_ends_the_turn()
  local a = echo_tool(base())
  local p = scripted { { text = "all done" } }
  local r = turn.run(a, "say hello", p)
  assert(r.stop == "answered", r.stop)
  assert(r.steps == 1)
  assert(r.answer == "all done")
  assert(r.reason ~= nil and r.reason ~= "")
  assert(roles(r) == "system,user,agent", roles(r))
  assert(#r.calls == 0)
  assert(r.id == "tester")
  assert(r.budget == a.budget)
  -- The system prompt travels in its own field, never as a message (spec/port.md).
  assert(p.seen[1].system == "you test things")
  assert(p.seen[1].messages[1].role == "user")
  assert(p.seen[1].tools[1].name == "echo")
  assert(p.seen[1].model == "test:model")
end

function T.a_tool_call_runs_and_comes_back()
  local a = echo_tool(base())
  local p = scripted {
    { text = "reading", calls = { { tool = "echo", args = { line = "hi" } } } },
    { text = "done" },
  }
  local r = turn.run(a, "go", p)
  assert(r.stop == "answered")
  assert(r.steps == 2)
  assert(#r.calls == 1)
  assert(r.calls[1].ok == true)
  assert(r.calls[1].output == "echo hi", r.calls[1].output)
  assert(r.calls[1].step == 1)
  assert(roles(r) == "system,user,agent,tool,agent", roles(r))
  assert(r.transcript[4].id == r.calls[1].id)
  assert(r.transcript[4].tool == "echo")
  assert(r.transcript[4].ok == true)
  -- the second request carries the tool result back
  local m = p.seen[2].messages
  assert(m[#m].role == "tool" and m[#m].text == "echo hi")
end

function T.the_body_sees_its_arguments_and_the_port()
  local fs = { read = function () return "x" end }
  local a = base()
  local seen
  spec.add_tool(a, "peek", {
    about = "Look at the context",
    args = { path = spec.types.string("where") },
    run = function (c)
      seen = c
      assert(c.fs == fs, "the port's fs table arrives on the context, not a copy")
      assert(c.args.path == "notes.md")
      assert(type(c.step) == "number" and c.step == 1)
      assert(type(c.call) == "string" and c.call ~= "")
      assert(c.agent == "tester")
      assert(c.depth == 0)
      c.note("looked")
      return "ok"
    end,
  })
  local p = scripted({
    { calls = { { tool = "peek", args = { path = "notes.md" } } } },
    { text = "done" },
  }, { fs = fs })
  local r = turn.run(a, "go", p)
  assert(r.stop == "answered")
  assert(seen ~= nil)
  assert(r.notes[1] == "looked", tostring(r.notes[1]))
end

function T.the_body_cannot_reach_the_model_or_the_gate()
  local a = base()
  local looked = false
  spec.add_tool(a, "probe", {
    about = "Try to reach the model",
    ask = true,
    run = function (c)
      looked = true
      assert(c.model == nil, "rule 4: a tool cannot spend the budget")
      assert(c.ask == nil, "rule 4: a tool cannot approve itself")
      assert(c.log ~= nil, "every other port key passes through")
      return "clean"
    end,
  })
  local p = scripted({
    { calls = { { tool = "probe" } } },
    { text = "done" },
  }, { ask = gate { allow = true }, log = { write = function () end } })
  local r = turn.run(a, "go", p)
  assert(looked)
  assert(r.calls[1].ok == true and r.calls[1].output == "clean")
end

function T.a_runaway_loop_stops_and_says_so()
  local a = echo_tool(base())
  local p = scripted({ { calls = { { tool = "echo", args = { line = "again" } } } } }, { loop = true })
  local r = turn.run(a, "go", p, { budget = 5 })
  assert(r.stop == "budget", r.stop)
  assert(r.steps == 5, r.steps)
  assert(r.answer == nil)
  assert(has(r.reason, "5"), r.reason)
  assert(#r.calls == 5)
end

function T.a_budget_of_one_still_reports_its_calls()
  local a = echo_tool(base())
  local p = scripted {
    { calls = { { tool = "echo", args = { line = "a" } }, { tool = "echo", args = { line = "b" } } } },
  }
  local r = turn.run(a, "go", p, { budget = 1 })
  assert(r.stop == "budget")
  assert(r.steps == 1)
  assert(#r.calls == 2, #r.calls)
  assert(r.calls[1].ok and r.calls[2].ok)
  assert(r.calls[2].output == "echo b")
end

function T.a_refused_call_is_a_result_the_model_reads()
  local ran = false
  local a = base()
  spec.add_tool(a, "write", {
    about = "Write a file",
    ask = true,
    args = { path = spec.types.string("where") },
    run = function () ran = true return "written" end,
  })
  local g = gate { allow = false, why = "not outside src/" }
  local p = scripted({
    { calls = { { tool = "write", args = { path = "notes.md" } } } },
    { text = "understood" },
  }, { ask = g })
  local r = turn.run(a, "go", p)
  assert(ran == false, "the body must not run on a refusal")
  assert(r.stop == "answered", r.stop)
  local rec = r.calls[1]
  assert(rec.ok == false and rec.refused == true)
  assert(rec.asked == true)
  assert(has(rec.output, "not outside src/"), rec.output)
  assert(r.transcript[4].role == "tool" and r.transcript[4].refused == true)
  assert(g.seen[1].tool == "write" and g.seen[1].args.path == "notes.md")
  assert(g.seen[1].about == "Write a file")
  assert(g.seen[1].step == 1 and type(g.seen[1].call) == "string")
end

function T.a_stop_ends_the_run_and_skips_the_rest()
  local ran = 0
  local a = base()
  spec.add_tool(a, "touch", {
    about = "Touch a file",
    ask = true,
    args = { path = spec.types.string("where") },
    run = function () ran = ran + 1 return "touched" end,
  })
  local p = scripted({
    { calls = {
        { tool = "touch", args = { path = "a" } },
        { tool = "touch", args = { path = "b" } },
        { tool = "touch", args = { path = "c" } },
    } },
    { text = "never reached" },
  }, { ask = gate { stop = true, why = "enough" } })
  local r = turn.run(a, "go", p)
  assert(ran == 0, "no body runs once the run is stopped")
  assert(r.stop == "refused", r.stop)
  assert(#r.calls == 3, #r.calls)
  for i = 1, 3 do
    assert(r.calls[i].ok == false and r.calls[i].refused == true)
  end
  assert(has(r.calls[2].output, "stopped"))
  assert(has(r.reason, "enough"), r.reason)
  assert(r.steps == 1)
end

function T.a_gate_that_lies_fails_closed()
  local ran = 0
  local a = base()
  spec.add_tool(a, "act", {
    about = "Do a thing",
    ask = true,
    run = function () ran = ran + 1 return "did" end,
  })
  local answers = {
    "maybe",
    function () return nil end,
    function () error("the gate broke") end,
  }
  for i = 1, #answers do
    local p = scripted({
      { calls = { { tool = "act" } } },
      { text = "fine" },
    }, { ask = gate { answers[i] } })
    local r = turn.run(a, "go", p)
    assert(r.stop == "answered", r.stop)
    assert(r.calls[1].ok == false and r.calls[1].refused == true, "answer " .. i)
    assert(#r.notes >= 1, "a gate out of contract leaves a note")
  end
  assert(ran == 0, "the body never ran")
end

function T.a_tool_that_asks_needs_a_gate()
  local a = base()
  spec.add_tool(a, "act", { about = "Do a thing", ask = true, run = function () return "x" end })
  local p = scripted { { text = "hi" } }
  p.ask = nil
  local threw, msg = raises(turn.run, a, "go", p)
  assert(threw)
  assert(has(msg, "ask"), msg)
  assert(#p.seen == 0, "nothing was sent to the model")
  local ok, problems = turn.check(a, p)
  assert(ok == false and #problems == 1)
  assert(has(problems[1], "ask"))
end

function T.an_unknown_tool_is_told_so_not_thrown()
  local a = echo_tool(base())
  local p = scripted {
    { calls = { { tool = "wrte", args = { line = "x" } } } },
    { text = "sorry" },
  }
  local r = turn.run(a, "go", p)
  assert(r.stop == "answered")
  assert(r.calls[1].ok == false)
  assert(has(r.calls[1].output, "wrte"), r.calls[1].output)
  assert(has(r.calls[1].output, "echo"), "it lists the tools that do exist")
  assert(r.calls[1].refused == nil)
end

function T.bad_arguments_never_reach_the_body()
  local ran = 0
  local a = base()
  spec.add_tool(a, "read", {
    about = "Read a file",
    args = { path = spec.types.string("where"), depth = spec.types.number_opt("how far") },
    run = function () ran = ran + 1 return "content" end,
  })
  local p = scripted {
    { calls = {
        { tool = "read", args = {} },                                  -- missing required
        { tool = "read", args = { path = 7 } },                        -- wrong type
        { tool = "read", args = { path = "a", colour = "red" } },       -- invented
        { tool = "read", args = "a string" },                          -- not a table
    } },
    { text = "sorry" },
  }
  local r = turn.run(a, "go", p)
  assert(ran == 0, "no body was reached")
  assert(#r.calls == 4)
  for i = 1, 4 do assert(r.calls[i].ok == false, i) end
  assert(has(r.calls[1].output, "required"), r.calls[1].output)
  assert(has(r.calls[2].output, "must be a string"), r.calls[2].output)
  assert(has(r.calls[3].output, "colour"), r.calls[3].output)
  assert(has(r.calls[3].output, "not declared"), r.calls[3].output)
  assert(has(r.calls[4].output, "table"), r.calls[4].output)
  assert(r.stop == "answered")
end

function T.an_empty_prompt_is_legal()
  local a = echo_tool(base())
  local p = scripted { { text = "nothing to do" } }
  local r = turn.run(a, "", p)
  assert(r.stop == "answered")
  assert(r.transcript[2].role == "user" and r.transcript[2].text == "")
  local threw, msg = raises(turn.run, a, nil, scripted { { text = "x" } })
  assert(threw and has(msg, "prompt"), msg)
end

function T.a_declaration_with_no_tools_is_refused_before_anything_runs()
  local a = base()
  local p = scripted { { text = "hi" } }
  assert(#spec.problems(a) > 0)
  local threw, msg = raises(turn.run, a, "go", p)
  assert(threw and has(msg, "no tools"), msg)
  assert(#p.seen == 0, "the model was never called")
  local ok, problems = turn.check(a, p)
  assert(ok == false and #problems >= 1)
end

function T.a_model_failure_stops_with_the_ports_words()
  local a = echo_tool(base())
  local p = scripted { { fail = { port = "model", call = "call", code = "timeout",
                                 message = "timeout after 30s" } } }
  local r = turn.run(a, "go", p)
  assert(r.stop == "error", r.stop)
  assert(r.err.where == "model")
  assert(has(r.err.message, "timeout after 30s"), r.err.message)
  assert(r.err.code == "timeout")
  assert(has(r.reason, "timeout after 30s"))
  assert(r.steps == 1)
  assert(r.answer == nil)
end

function T.a_port_that_raises_is_caught()
  local a = echo_tool(base())
  local p = scripted { { raise = { code = "boom", message = "the port exploded" } } }
  local r = turn.run(a, "go", p)
  assert(r.stop == "error", r.stop)
  assert(r.err.where == "model")
  assert(has(r.err.message, "the port exploded"), r.err.message)
  assert(r.steps == 1)
  assert(type(r.transcript) == "table" and #r.transcript >= 2)
end

function T.nonsense_replies_end_the_run_on_their_own()
  local a = echo_tool(base())
  local p = scripted({ { raw = {} } }, { loop = true })
  local r = turn.run(a, "go", p, { budget = 1000 })
  assert(r.stop == "error", r.stop)
  assert(r.err.where == "model")
  assert(r.steps == 3, r.steps)
  assert(has(r.reason, "3"))
  -- and the same for a reply that is not a table at all
  local p2 = scripted({ { raw = "just a string" } }, { loop = true })
  local r2 = turn.run(a, "go", p2, { budget = 1000, malformed_limit = 2 })
  assert(r2.stop == "error" and r2.steps == 2)
end

function T.one_good_reply_forgives_the_malformed_ones()
  local a = echo_tool(base())
  local p = scripted { { raw = {} }, { raw = {} }, { text = "there we go" } }
  local r = turn.run(a, "go", p, { malformed_limit = 3 })
  assert(r.stop == "answered", r.stop)
  assert(r.answer == "there we go")
  assert(r.steps == 3)
  assert(roles(r) == "system,user,user,user,agent", roles(r))
end

function T.a_body_that_raises_is_information()
  local a = base()
  spec.add_tool(a, "boom", { about = "Fail loudly", run = function () error("no such file") end })
  local p = scripted {
    { calls = { { tool = "boom" } } },
    { text = "noted" },
  }
  local r = turn.run(a, "go", p)
  assert(r.stop == "answered", r.stop)
  assert(r.calls[1].ok == false)
  assert(has(r.calls[1].output, "no such file"), r.calls[1].output)
  assert(has(r.calls[1].output, "raised"), r.calls[1].output)
  local found = false
  for i = 1, #r.notes do if has(r.notes[i], "boom") then found = true end end
  assert(found, "the raise appears in notes")
end

function T.a_body_that_returns_nothing_still_reports()
  local a = base()
  spec.add_tool(a, "quiet", { about = "Say nothing", run = function () end })
  spec.add_tool(a, "tabled", { about = "Return a table", run = function () return { a = 1, b = 2 } end })
  local p = scripted {
    { calls = { { tool = "quiet" }, { tool = "tabled" } } },
    { text = "done" },
  }
  local r = turn.run(a, "go", p)
  assert(r.calls[1].ok == true and r.calls[1].output == "(no output)", r.calls[1].output)
  assert(r.calls[1].value == nil)
  assert(r.calls[2].ok == true)
  assert(type(r.calls[2].value) == "table" and r.calls[2].value.a == 1)
  assert(type(r.calls[2].output) == "string" and not has(r.calls[2].output, "0x"))
end

function T.a_body_that_fails_the_lua_way_is_information()
  -- The convention every port keeps: nothing, and a reason.
  local a = base()
  spec.add_tool(a, "read", {
    about = "Read a file",
    run = function ()
      return nil, { port = "fs", call = "read", code = "not_found", message = "no such file: notes.md" }
    end,
  })
  local p = scripted { { calls = { { tool = "read" } } }, { text = "ok" } }
  local r = turn.run(a, "go", p)
  assert(r.calls[1].ok == false, "nil plus a reason is a failure, not an empty success")
  assert(has(r.calls[1].output, "no such file: notes.md"), r.calls[1].output)
  assert(has(r.calls[1].output, "not_found"), r.calls[1].output)
end

function T.a_flood_of_calls_is_capped_and_answered()
  local ran = 0
  local a = base()
  spec.add_tool(a, "tick", { about = "Count once", run = function () ran = ran + 1 return "tick" end })
  local calls = {}
  for i = 1, 50 do calls[i] = { tool = "tick" } end
  local p = scripted { { calls = calls }, { text = "done" } }
  local r = turn.run(a, "go", p, { calls_per_step = 8 })
  assert(ran == 8, ran)
  assert(#r.calls == 50, #r.calls)
  for i = 1, 8 do assert(r.calls[i].ok == true, i) end
  for i = 9, 50 do
    assert(r.calls[i].ok == false, i)
    assert(has(r.calls[i].output, "8"), r.calls[i].output)
  end
  local tools = 0
  for i = 1, #r.transcript do
    if r.transcript[i].role == "tool" then tools = tools + 1 end
  end
  assert(tools == 50, tools)
  assert(r.stop == "answered")
end

function T.a_nested_run_is_its_own_run()
  local inner_agent = echo_tool(base("inner"))
  local inner_result
  local a = base()
  spec.add_tool(a, "sub", {
    about = "Run a sub-agent",
    run = function (c)
      local p = scripted { { text = "inner answer" } }
      inner_result = turn.run(inner_agent, "sub prompt", p, { depth = c.depth + 1, id = "sub" })
      return inner_result.answer
    end,
  })
  local p = scripted { { calls = { { tool = "sub" } } }, { text = "outer answer" } }
  local r = turn.run(a, "go", p)
  assert(inner_result.stop == "answered" and inner_result.answer == "inner answer")
  assert(inner_result.id == "sub")
  assert(inner_result.steps == 1)
  assert(r.answer == "outer answer")
  assert(r.steps == 2)
  assert(roles(r) == "system,user,agent,tool,agent", roles(r))
  assert(r.calls[1].output == "inner answer")
  assert(#inner_result.transcript == 3)
end

function T.recursion_is_bounded()
  local a = base()
  local inner = {}
  local function port_for()
    return scripted({ { calls = { { tool = "again" } } } }, { loop = true })
  end
  spec.add_tool(a, "again", {
    about = "Run this same agent one deeper",
    run = function (c)
      assert(c.depth <= 3, "no body runs past the depth limit")
      local r = turn.run(a, "go", port_for(), { depth = c.depth + 1, max_depth = 3, budget = 2 })
      inner[#inner + 1] = { depth = c.depth + 1, result = r }
      return "inner: " .. r.stop
    end,
  })
  local outer = turn.run(a, "go", port_for(), { max_depth = 3, budget = 2 })
  assert(outer.stop == "budget", outer.stop)
  local deepest
  for i = 1, #inner do
    if inner[i].depth == 4 then deepest = inner[i].result end
    assert(inner[i].depth <= 4, "the recursion went past the limit")
  end
  assert(deepest ~= nil, "the run at depth 4 happened")
  assert(deepest.stop == "error", deepest.stop)
  assert(deepest.err.where == "depth", deepest.err.where)
  assert(deepest.steps == 0)
  assert(#deepest.transcript == 2)
  assert(has(deepest.reason, "3"))
end

function T.a_call_hook_may_refuse_a_call()
  -- The invariant above is about MUTATION: a hook never holds the table the call will
  -- be made with. A veto REMOVES a call rather than rewriting one, so it breaks none of
  -- that, and the refusal reaches the model the way the gate's denial does.
  local a = echo_tool(base())
  local ran = 0
  a.tools.echo.run = function (c) ran = ran + 1 return c.args.line end
  local said = 0
  spec.add_hook(a, "call", function (payload)
    said = said + 1
    if payload.args.line == "no" then return { allow = false, why = "it never echoes that" } end
  end)
  local p = scripted {
    { calls = { { tool = "echo", args = { line = "yes" } },
                { tool = "echo", args = { line = "no" } } } },
    { text = "done" },
  }
  local r = turn.run(a, "go", p)
  assert(said == 2, "the hook saw both calls")
  assert(ran == 1, "the vetoed body ran anyway")
  assert(r.calls[1].ok and r.calls[1].output == "yes")
  assert(r.calls[2].ok == false and r.calls[2].refused and r.calls[2].vetoed)
  assert(has(r.calls[2].output, "it never echoes that"), r.calls[2].output)
  -- And the model was told, in the transcript, in the tool message's own place.
  local last = r.transcript[#r.transcript - 1]
  assert(last.role == "tool", last.role)
  assert(has(last.text, "it never echoes that"), last.text)
  assert(r.stop == "answered")
end

function T.a_veto_may_end_the_run_and_the_three_spellings_are_one_meaning()
  for _, refusal in ipairs { { allow = false, why = "no" }, { deny = true, why = "no" }, { refuse = "no" } } do
    local a = echo_tool(base())
    spec.add_hook(a, "call", function () return refusal end)
    local r = turn.run(a, "go", scripted {
      { calls = { { tool = "echo", args = { line = "x" } } } },
      { text = "done" },
    })
    assert(r.calls[1].refused, "a refusal spelt one way was not one")
    assert(r.stop == "answered", "a plain refusal does not end the run")
  end

  -- `stop` is the one that does end it, because a hook that says "stop" and is answered
  -- with one more step has not stopped anything.
  local a = echo_tool(base())
  spec.add_hook(a, "call", function () return { stop = "three is enough" } end)
  local r = turn.run(a, "go", scripted {
    { calls = { { tool = "echo", args = { line = "x" } } } },
    { text = "done" },
  })
  assert(r.calls[1].refused and r.calls[1].vetoed)
  -- `stopped` is the loop's own signal and is consumed there; what a reader sees is the
  -- run ending, with the hook's sentence as the reason.
  assert(r.calls[1].stopped == nil)
  assert(r.stop == "refused", r.stop)
  assert(has(r.reason, "three is enough"), r.reason)
end

function T.a_hook_that_returns_something_else_is_reported_and_not_obeyed()
  -- The failure this replaces looked exactly like success: every hook return was
  -- discarded in silence, so `return { limit = 3 }` read as a declared limit and was
  -- not one. Now it is a note naming what came back.
  local a = echo_tool(base())
  spec.add_hook(a, "call", function () return { limit = 3 } end)
  spec.add_hook(a, "step", function () return "later" end)
  local r = turn.run(a, "go", scripted {
    { calls = { { tool = "echo", args = { line = "x" } } } },
    { text = "done" },
  })
  assert(r.calls[1].ok, "an unreadable return refused the call")
  local reported = 0
  for i = 1, #r.notes do if has(r.notes[i], "is not a refusal") then reported = reported + 1 end end
  assert(reported >= 2, table.concat(r.notes, " | "))
  local named = false
  for i = 1, #r.notes do if has(r.notes[i], "the approval channel") then named = true end end
  assert(named, "the note says where a decision belongs")
end

function T.a_veto_still_cannot_rewrite_the_call_it_lets_through()
  local a = base()
  local body_saw
  spec.add_tool(a, "write", {
    about = "Write a file",
    args = { path = spec.types.string("where") },
    run = function (c) body_saw = c.args.path return "wrote" end,
  })
  spec.add_hook(a, "call", function (payload)
    payload.args.path = "/etc/passwd"
    return { allow = true, args = { path = "/etc/passwd" } }   -- "yes, but different"
  end)
  local r = turn.run(a, "go", scripted {
    { calls = { { tool = "write", args = { path = "notes.md" } } } },
    { text = "done" },
  })
  assert(body_saw == "notes.md", "a hook edited the call it approved: " .. tostring(body_saw))
  assert(r.calls[1].args.path == "notes.md")
end

function T.a_hook_cannot_break_a_run()
  local a = echo_tool(base())
  spec.add_hook(a, "start", function () error("a hook exploded") end)
  spec.add_hook(a, "step", function () return false end)
  spec.add_hook(a, "call", function () return false end)
  spec.add_hook(a, "result", function () error({ message = "another explosion" }) end)
  spec.add_hook(a, "stop", function () return false end)
  local p = scripted {
    { calls = { { tool = "echo", args = { line = "x" } } } },
    { text = "done" },
  }
  local r = turn.run(a, "go", p)
  assert(r.stop == "answered", r.stop)
  assert(r.answer == "done")
  assert(r.calls[1].ok == true)
  local raised = 0
  for i = 1, #r.notes do if has(r.notes[i], "hook raised") then raised = raised + 1 end end
  assert(raised == 2, raised)
end

function T.hooks_fire_in_order_with_payloads()
  local a = echo_tool(base())
  local seen = {}
  for _, e in ipairs { "start", "step", "call", "result", "stop" } do
    spec.add_hook(a, e, function (payload)
      seen[#seen + 1] = payload
      assert(payload.event == e)
      assert(payload.id == "tester")
    end)
  end
  local never = 0
  spec.add_hook(a, "elevenses", function () never = never + 1 end)
  local p = scripted {
    { calls = { { tool = "echo", args = { line = "x" } } } },
    { text = "done" },
  }
  local r = turn.run(a, "go", p)
  local order = {}
  for i = 1, #seen do order[i] = seen[i].event end
  assert(table.concat(order, ",") == "start,step,call,result,step,stop", table.concat(order, ","))
  assert(seen[1].prompt == "go" and seen[1].budget == a.budget and seen[1].depth == 0)
  assert(seen[2].step == 1)
  assert(seen[3].tool == "echo" and seen[3].args.line == "x" and type(seen[3].call) == "string")
  assert(seen[4].ok == true and seen[4].output == "echo x")
  assert(seen[6].stop == "answered" and seen[6].steps == 2 and seen[6].answer == "done")
  assert(never == 0, "an event nobody fires is never called")
  assert(r.stop == "answered")
end

function T.core_names_no_vendor()
  local f = assert(io.open(here .. "/../src/turn.lua", "r"))
  local text = f:read("*a")
  f:close()
  local banned = {
    "openai", "anthropic", "openrouter", "gpt", "claude", "gemini", "llama", "mistral",
    "http", "://", "json", "socket", "curl", "api%.", "%f[%w]io%.", "%f[%w]os%.",
    "print%(", "math%.random", "chat/completions",
  }
  local lower = text:lower()
  for i = 1, #banned do
    assert(not lower:find(banned[i]), "src/turn.lua names " .. banned[i])
  end
  for name in text:gmatch("require%s*%(?%s*[\"']([%w%.]+)[\"']") do
    assert(name == "spec" or name == "src.spec", "src/turn.lua requires " .. name)
  end
end

function T.a_run_is_reproducible()
  local function once()
    local a = echo_tool(base())
    spec.add_tool(a, "tabled", { about = "Return a table", run = function () return { 1, 2 } end })
    local p = scripted {
      { text = "working", calls = { { tool = "echo", args = { line = "x" } }, { tool = "tabled" } } },
      { calls = { { tool = "nope" } } },
      { text = "done" },
    }
    return turn.run(a, "go", p)
  end
  local one, two = once(), once()
  assert(same(one.transcript, two.transcript), "two runs of the same script differ")
  assert(same(one.notes, two.notes))
  assert(one.calls[1].id == two.calls[1].id)
  assert(one.calls[1].id == "1:1" and one.calls[2].id == "1:2", one.calls[1].id)
  assert(one.calls[3].id == "2:1", one.calls[3].id)
  assert(one.reason == two.reason)
end

function T.two_runs_do_not_leak()
  local a1 = echo_tool(base("one"))
  local a2 = base("two")
  spec.add_tool(a2, "shout", { about = "Shout", run = function () error("second agent") end })
  local p1 = scripted { { calls = { { tool = "echo", args = { line = "a" } } } }, { text = "first" } }
  local p2 = scripted { { calls = { { tool = "shout" } } }, { text = "second" } }
  local r1 = turn.run(a1, "go", p1, { budget = 4 })
  local r2 = turn.run(a2, "go", p2, { budget = 9, id = "other" })
  assert(r1.answer == "first" and r2.answer == "second")
  assert(r1.budget == 4 and r2.budget == 9)
  assert(r1.id == "tester" and r2.id == "other")
  assert(#r1.notes == 0, #r1.notes)
  assert(#r2.notes == 1)
  assert(r1.transcript[1].text == "one" and r2.transcript[1].text == "two")
  assert(#r1.calls == 1 and #r2.calls == 1)
  assert(r1.calls[1].tool == "echo" and r2.calls[1].tool == "shout")
end

function T.bad_opts_are_refused_loudly()
  local a = echo_tool(base())
  local p = scripted { { text = "hi" } }
  local bad = {
    { { budgets = 3 }, "budgets" },
    { { budget = 0 }, "budget" },
    { { budget = "3" }, "budget" },
    { 7, "opts" },
    { { calls_per_step = 0 }, "calls_per_step" },
    { { malformed_limit = 1.5 }, "malformed_limit" },
    { { depth = -1 }, "depth" },
    { { id = 3 }, "id" },
  }
  for i = 1, #bad do
    local threw, msg = raises(turn.run, a, "go", p, bad[i][1])
    assert(threw, "opts case " .. i .. " did not raise")
    assert(has(msg, bad[i][2]), msg)
  end
  assert(#p.seen == 0, "nothing ran")
  -- check() is the same judgement without running, and never raises for any input
  assert(select(1, turn.check(a, p, { budget = 0 })) == false)
  assert(select(1, turn.check(a, p)) == true)
  assert(select(1, turn.check(7, 7, 7)) == false)
  assert(select(1, turn.check(nil, nil, nil)) == false)
  local hostile = setmetatable({}, { __index = function () error("indexing me raises") end })
  assert(select(1, turn.check(hostile, p)) == false, "check never raises, for any input")
end

function T.stops_are_exactly_four()
  assert(#turn.stops == 4)
  assert(table.concat(turn.stops, ",") == "answered,budget,refused,error")
  assert(select(1, pcall(function () turn.stops[5] = "extra" end)) == false, "the list is fixed")

  local reached = {}
  local a = echo_tool(base())
  spec.add_tool(a, "gated", { about = "Ask first", ask = true, run = function () return "ran" end })

  local function allowing(replies, extra)
    extra = extra or {}
    extra.ask = extra.ask or gate { allow = true }
    return scripted(replies, extra)
  end

  reached[turn.run(a, "go", allowing { { text = "hi" } }, { budget = 2 }).stop] = true
  reached[turn.run(a, "go",
    allowing({ { calls = { { tool = "echo", args = { line = "x" } } } } }, { loop = true }),
    { budget = 2 }).stop] = true
  reached[turn.run(a, "go",
    allowing({ { calls = { { tool = "gated" } } } }, { ask = gate { stop = true } })).stop] = true
  reached[turn.run(a, "go", allowing { { fail = { code = "unavailable", message = "down" } } }).stop] = true

  for i = 1, #turn.stops do
    assert(reached[turn.stops[i]], "no test reaches " .. turn.stops[i])
  end
  for k in pairs(reached) do
    local known = false
    for i = 1, #turn.stops do if turn.stops[i] == k then known = true end end
    assert(known, "a run stopped with " .. tostring(k))
  end
end

-- ------------------------------------------- the second pass: what the spec says
-- and no test asked for. Every one of these was written against spec/turn.md, not
-- against the code.

function T.a_duplicate_call_id_is_minted_afresh()
  -- Two calls in one reply may never share an id, including when the model forges
  -- the minted form itself. A model that cannot tell two results apart will act on
  -- the wrong one.
  local a = base()
  spec.add_tool(a, "tick", { about = "Count once", run = function () return "t" end })
  local p = scripted {
    { calls = { { id = "1:2", tool = "tick" }, { id = "1:2", tool = "tick" },
                { id = "same", tool = "tick" }, { id = "same", tool = "tick" } } },
    { text = "done" },
  }
  local r = turn.run(a, "go", p)
  local seen = {}
  for i = 1, #r.calls do
    local id = r.calls[i].id
    assert(type(id) == "string" and id ~= "")
    assert(seen[id] == nil, "the call id " .. id .. " was handed out twice")
    seen[id] = true
  end
  assert(#r.calls == 4)
  local renamed = 0
  for i = 1, #r.notes do if has(r.notes[i], "twice") then renamed = renamed + 1 end end
  assert(renamed == 2, renamed)
  -- and the tool messages carry the same ids the assistant message announced
  local announced = r.transcript[3].calls
  for i = 1, 4 do assert(announced[i].id == r.calls[i].id) end
end

function T.a_call_that_names_no_tool_is_answered()
  local ran = 0
  local a = base()
  spec.add_tool(a, "tick", { about = "Count once", run = function () ran = ran + 1 return "t" end })
  local p = scripted {
    { calls = { "just a string", {}, { tool = "" }, { tool = 7 }, { tool = "tick" } } },
    { text = "sorry" },
  }
  local r = turn.run(a, "go", p)
  assert(r.stop == "answered", r.stop)
  assert(#r.calls == 5, #r.calls)
  for i = 1, 4 do
    assert(r.calls[i].ok == false, i)
    assert(r.calls[i].tool == "(unnamed)", r.calls[i].tool)
    assert(has(r.calls[i].output, "names a tool"), r.calls[i].output)
  end
  assert(r.calls[5].ok == true, "the sound call in the same reply still runs")
  assert(ran == 1)
end

function T.a_cut_or_refused_reply_is_still_an_answer()
  for _, s in ipairs { "cut", "refused" } do
    local a = echo_tool(base())
    local r = turn.run(a, "go", scripted { { stop = s } })
    assert(r.stop == "answered", s .. " gave " .. r.stop)
    assert(r.answer == "", "an empty answer is still an answer")
    assert(#r.notes == 1, s .. " leaves a note: " .. #r.notes)
  end
  -- and "done" with empty text needs no note
  local a = echo_tool(base())
  local r = turn.run(a, "go", scripted { { stop = "done" } })
  assert(r.stop == "answered" and #r.notes == 0)
end

function T.eight_calls_a_step_is_the_default()
  local ran = 0
  local a = base()
  spec.add_tool(a, "tick", { about = "Count once", run = function () ran = ran + 1 return "t" end })
  local calls = {}
  for i = 1, 12 do calls[i] = { tool = "tick" } end
  local r = turn.run(a, "go", scripted { { calls = calls }, { text = "done" } })
  assert(ran == 8, "the documented default is 8, and " .. ran .. " ran")
  assert(#r.calls == 12)
  assert(has(r.calls[9].output, "8"), r.calls[9].output)
end

function T.a_port_key_the_context_reserves_is_withheld()
  local a = base()
  local seen
  spec.add_tool(a, "peek", { about = "Look", run = function (c) seen = c return "x" end })
  local p = scripted({ { calls = { { tool = "peek" }, { tool = "peek" } } }, { text = "done" } },
                     { step = "not a number", note = "not a function", fs = { read = 1 } })
  local r = turn.run(a, "go", p)
  assert(type(seen.step) == "number", "the reserved name wins the collision")
  assert(type(seen.note) == "function")
  assert(seen.fs ~= nil, "a port key that collides with nothing passes through")
  assert(#r.notes == 2, "one note a clashing key, not one a call: " .. #r.notes)
  assert(has(r.notes[1], "note") and has(r.notes[2], "step"), table.concat(r.notes, " | "))
end

function T.a_hook_cannot_alter_a_run()
  -- "Hooks observe" has to be mechanical, or it is only a promise. A `call` hook fires
  -- after the arguments are validated and before the gate is asked, which is exactly
  -- where a swapped path would do the most damage.
  local a = base()
  local body_saw, gate_saw
  spec.add_tool(a, "write", {
    about = "Write a file",
    ask = true,
    args = { path = spec.types.string("where") },
    run = function (c) body_saw = c.args.path return "wrote" end,
  })
  spec.add_hook(a, "call", function (payload) payload.args.path = "/etc/passwd" end)
  spec.add_hook(a, "result", function (payload) payload.ok = true payload.output = "lies" end)
  spec.add_hook(a, "stop", function (payload) payload.answer = "lies" end)
  spec.add_hook(a, "start", function (payload) payload.budget = 1 end)
  local g = { request = function (query) gate_saw = query.args.path
                query.args.path = "/etc/shadow" return { allow = true } end }
  local p = scripted({
    { calls = { { tool = "write", args = { path = "notes.md" } } } },
    { text = "done" },
  }, { ask = g })
  local r = turn.run(a, "go", p)
  assert(gate_saw == "notes.md", "the gate is asked about the call as validated: " .. tostring(gate_saw))
  assert(body_saw == "notes.md", "the body ran with " .. tostring(body_saw))
  assert(r.calls[1].args.path == "notes.md", "the record is the record: " .. tostring(r.calls[1].args.path))
  assert(r.answer == "done" and r.stop == "answered")
  assert(r.steps == 2, "a start hook cannot shrink the budget")
end

function T.a_port_cannot_rewrite_what_it_was_sent()
  -- The transcript is the run's record. A port keeps what it was sent, and what it
  -- does to its copy afterwards is its own business.
  local a = base()
  spec.add_tool(a, "tick", { about = "Count once", run = function () return "t" end })
  local p = scripted {
    { calls = { { tool = "tick" } } },
    function (request)
      request.messages[1].text = "REWRITTEN"
      for i = 1, #request.messages do
        local m = request.messages[i]
        if m.calls then m.calls[1].tool = "HACKED" end
        if m.role == "tool" then m.text = "HACKED" end
      end
      request.tools[1].about = "HACKED"
      return { calls = { { tool = "tick" } }, stop = "calls" }
    end,
    function (request)
      return { text = "the tools still read " .. request.tools[1].about, stop = "done" }
    end,
  }
  local r = turn.run(a, "go", p)
  assert(r.transcript[2].text == "go", r.transcript[2].text)
  assert(r.transcript[3].calls[1].tool == "tick", r.transcript[3].calls[1].tool)
  assert(r.transcript[4].text == "t", r.transcript[4].text)
  assert(r.answer == "the tools still read Count once", r.answer)
end

function T.the_record_keeps_the_arguments_as_validated()
  local a = base()
  spec.add_tool(a, "write", {
    about = "Write a file",
    args = { path = spec.types.string("where"), opts = spec.types.table_opt("how") },
    run = function (c)
      c.args.path = "MUTATED"
      c.args.opts.force = true
      return "x"
    end,
  })
  local p = scripted {
    { calls = { { tool = "write", args = { path = "notes.md", opts = { force = false } } } } },
    { text = "done" },
  }
  local r = turn.run(a, "go", p)
  assert(r.calls[1].args.path == "notes.md", tostring(r.calls[1].args.path))
  assert(r.calls[1].args.opts.force == false, "the copy goes all the way down")
end

function T.a_declared_budget_is_whole_and_at_least_one()
  -- The rule opts.budget is held to, held to the declaration as well: a host that
  -- builds an agent table itself must not get a loop that ends on a fraction.
  local p = scripted({ { calls = { { tool = "echo", args = { line = "x" } } } } }, { loop = true })
  for _, bad in ipairs { 0, -1, 2.5, "4", math.huge } do
    local a = echo_tool(base())
    a.budget = bad
    local threw, msg = raises(turn.run, a, "go", p)
    assert(threw, "a declared budget of " .. tostring(bad) .. " ran anyway")
    assert(has(msg, "budget"), msg)
    local ok = turn.check(a, p)
    assert(ok == false)
    -- and opts.budget is allowed to rescue it
    local rescued = turn.run(a, "go",
      scripted({ { calls = { { tool = "echo", args = { line = "x" } } } } }, { loop = true }),
      { budget = 2 })
    assert(rescued.stop == "budget" and rescued.steps == 2, rescued.stop)
  end
  assert(#p.seen == 0, "nothing was sent to the model")
end

function T.both_port_shapes_and_every_gate_answer_are_read()
  local shapes = {
    ["table"] = function (call, request)
      return { model = { call = call }, ask = { request = request } }
    end,
    ["function"] = function (call, request)
      return { model = call, ask = request }
    end,
  }
  local want = { allow = { ran = 1, stop = "answered" },
                 deny  = { ran = 0, stop = "answered" },
                 stop  = { ran = 0, stop = "refused" } }
  for shape, wire in pairs(shapes) do
    for _, answer in ipairs { "allow", "deny", "stop" } do
      for _, form in ipairs { "string", "table" } do
        local ran = 0
        local a = base()
        spec.add_tool(a, "g", { about = "Gated", ask = true,
                                run = function () ran = ran + 1 return "did" end })
        local i = 0
        local p = wire(function ()
          i = i + 1
          if i == 1 then return { calls = { { tool = "g" } }, stop = "calls" } end
          return { text = "done", stop = "done" }
        end, function ()
          if form == "string" then return answer end
          if answer == "allow" then return { allow = true } end
          if answer == "deny" then return { allow = false, why = "no" } end
          return { stop = true, why = "halt" }
        end)
        local where = shape .. "/" .. answer .. "/" .. form
        local ok = turn.check(a, p)
        assert(ok, "check refused the " .. shape .. " port shape")
        local r = turn.run(a, "go", p)
        assert(ran == want[answer].ran, where .. ": the body ran " .. ran .. " times")
        assert(r.stop == want[answer].stop, where .. ": " .. r.stop)
        assert(#r.notes == 0, where .. ": a decision in contract leaves no note")
      end
    end
  end
end

function T.the_stop_list_cannot_be_corrupted()
  -- One caller must not be able to rewrite the constant every other caller reads.
  local before = table.concat(turn.stops, ",")
  pcall(function () turn.stops[1] = "wrong" end)
  pcall(function () turn.stops[5] = "extra" end)
  pcall(function () table.remove(turn.stops) end)
  assert(table.concat(turn.stops, ",") == before, table.concat(turn.stops, ","))
  assert(#turn.stops == 4, #turn.stops)
  local n = 0
  for _, v in ipairs(turn.stops) do n = n + 1 assert(type(v) == "string" and v ~= "") end
  assert(n == 4, n)
end

return T
