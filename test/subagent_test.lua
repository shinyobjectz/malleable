-- subagent — proved against scripted ports. No network, no disk, no subprocess, no
-- clock. Each test asserts with plain `assert` and prints nothing on success.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local spec     = require("spec")
local turn     = require("turn")
local double   = require("double")
local subagent = require("subagent")

local T = {}

-- ------------------------------------------------------------------- builders

local function echo_tool()
  return {
    about = "Say a line back",
    args = { line = spec.types.string "what to say" },
    run = function (c) return "echo " .. c.args.line end,
  }
end

-- An agent with a name, a model and whatever tools were asked for.
local function agent(name, tools)
  local a = spec.new()
  spec.set_name(a, name)
  spec.set_model(a, "test:model")
  tools = tools or { { name = "echo", tool = echo_tool() } }
  for i = 1, #tools do
    spec.add_tool(a, tools[i].name, tools[i].tool)
  end
  return a
end

local function world(replies, extra)
  local cfg = { model = { replies = replies, after = (extra and extra.after) or "error" } }
  if extra then
    for k, v in pairs(extra) do
      if k ~= "after" then cfg[k] = v end
    end
  end
  return double.world(cfg)
end

local ANSWER = { "the child is done" }

local function ctx_of(name, depth)
  return { agent = name or "reviewer", depth = depth or 0, step = 1, call = "1:1" }
end

-- One spawn, with everything the caller did not say filled in.
local function spawn(req, ctx)
  local r = {}
  for k, v in pairs(req) do r[k] = v end
  if r.prompt == nil then r.prompt = "do the job" end
  if r.agents == nil and r.pick == nil then
    r.agents = { reviewer = agent("reviewer") }
  end
  if r.world == nil then r.world = world(ANSWER) end
  if r.agent == nil and r.agents and r.agents.reviewer then r.agent = "reviewer" end
  return subagent.run(ctx or ctx_of(), r)
end

local function contains(haystack, needle)
  return haystack:find(needle, 1, true) ~= nil
end

-- ------------------------------------------------------------ 1, 2, 3: a child ran

-- Drive a real parent turn loop with a spawn tool on it.
local function parent_run(cfg, parent_replies, opts)
  local seen = {}
  cfg.about = cfg.about or "Hand a job to a fresh agent"
  local watch = cfg.watch
  cfg.watch = function (r)
    seen[#seen + 1] = r
    if watch then watch(r) end
  end
  local decl = subagent.tool(cfg)
  local boss = spec.new()
  spec.set_name(boss, "boss")
  spec.set_model(boss, "test:model")
  spec.add_tool(boss, "delegate", decl)
  local port = world(parent_replies, { ask = true, after = (opts and opts.after) or "error" })
  local result = turn.run(boss, "go", port, opts and opts.turn or nil)
  return result, seen, port
end

function T.a_child_answers_and_the_parent_reads_it()
  local child = world { "I read it and it is fine" }
  local result, seen = parent_run(
    { agents = { reviewer = agent("reviewer") }, world = child },
    { { tool = "delegate", args = { agent = "reviewer", prompt = "check the file" } },
      "the reviewer says it is fine" })

  assert(result.stop == "answered", result.stop)
  assert(#seen == 1)
  assert(seen[1].ok == true)
  assert(seen[1].stop == "answered")
  assert(seen[1].answer == "I read it and it is fine")

  local told
  for i = 1, #result.transcript do
    local m = result.transcript[i]
    if m.role == "tool" and m.tool == "delegate" then told = m.text end
  end
  assert(told ~= nil, "the parent never saw a tool result")
  assert(contains(told, "I read it and it is fine"), told)
end

function T.the_child_runs_its_own_tools()
  local child = world { { tool = "echo", args = { line = "hi" } }, "said it" }
  local result, seen = parent_run(
    { agents = { reviewer = agent("reviewer") }, world = child },
    { { tool = "delegate", args = { agent = "reviewer", prompt = "say hi" } }, "done" })

  assert(#seen[1].calls == 1)
  assert(seen[1].calls[1].tool == "echo")
  assert(seen[1].calls[1].output == "echo hi")

  for i = 1, #result.calls do
    assert(result.calls[i].tool == "delegate", "a child's call reached the parent")
  end
  assert(#result.calls == 1)
end

function T.the_childs_transcript_comes_back_whole()
  local child = world { { tool = "echo", args = { line = "hi" } }, "said it" }
  local result, seen = parent_run(
    { agents = { reviewer = agent("reviewer") }, world = child },
    { { tool = "delegate", args = { agent = "reviewer", prompt = "say hi" } }, "done" })

  local t = seen[1].transcript
  assert(#t == 4, #t)                       -- user, agent+calls, tool, agent
  assert(t[1].role == "user" and t[1].text == "say hi")
  assert(t[2].role == "agent" and #t[2].calls == 1)
  assert(t[3].role == "tool" and t[3].text == "echo hi")
  assert(t[4].role == "agent" and t[4].text == "said it")

  for i = 1, #result.transcript do
    local m = result.transcript[i]
    assert(m.text ~= "echo hi", "the child's tool output reached the parent's transcript")
  end
end

-- ---------------------------------------------------------------- 4: the readout

function T.a_readout_describes_a_child_line_by_line()
  local r = spawn { world = world { { tool = "echo", args = { line = "hi" } }, "said it" } }
  local lines = subagent.readout(r)
  assert(#lines == 6, #lines)               -- 4 messages, 1 record, 1 stop
  assert(contains(lines[1], 'user: "do the job"'), lines[1])
  assert(contains(lines[2], "calls: echo"), lines[2])
  assert(contains(lines[3], 'tool echo'), lines[3])
  assert(contains(lines[3], "ok"), lines[3])
  assert(contains(lines[5], "call "), lines[5])
  assert(contains(lines[6], "stop: answered"), lines[6])

  local again = subagent.readout(r)
  for i = 1, #lines do assert(lines[i] == again[i], lines[i]) end
end

function T.a_blocked_child_reads_out_in_two_lines()
  local r = spawn { agent = "nobody" }
  local lines = subagent.readout(r)
  assert(#lines == 2, #lines)
  assert(contains(lines[1], "asked:"), lines[1])
  assert(contains(lines[1], "do the job"), lines[1])
  assert(contains(lines[2], "blocked: unknown"), lines[2])
end

-- ------------------------------------------------------------------- 5: the ids

function T.an_id_is_derived_and_stable()
  local function tree()
    local l = subagent.ledger()
    local a = spawn { ledger = l }
    local b = spawn { ledger = l }
    return a.id, b.id
  end
  local a1, b1 = tree()
  local a2, b2 = tree()
  assert(a1 == "reviewer/s1", a1)
  assert(b1 == "reviewer/s2", b1)
  assert(a1 == a2 and b1 == b2)
end

-- -------------------------------------------------------- 6, 7, 17: the budget

function T.a_budget_the_model_asks_for_is_honoured_up_to_the_ceiling()
  local five = spawn { budget = 5 }
  assert(five.budget == 5, five.budget)
  assert(five.clamped == false)

  local lots = spawn { budget = 100, max_budget = 24 }
  assert(lots.budget == 24, lots.budget)
  assert(lots.clamped == true)
end

function T.the_pool_is_refunded()
  local l = subagent.ledger { steps = 64 }
  local r = spawn {
    ledger = l, budget = 12,
    world = world { { tool = "echo", args = { line = "a" } },
                    { tool = "echo", args = { line = "b" } }, "done" },
  }
  assert(r.steps == 3, r.steps)
  assert(r.budget == 12)
  assert(r.pool.steps_left == 61, r.pool.steps_left)   -- 64 - 12 + 9
  assert(l.steps_left == 61)
end

function T.siblings_cannot_each_promise_the_whole_pool()
  local l = subagent.ledger { steps = 10 }
  local w = world({ "ok" }, { after = "repeat" })
  local a = spawn { ledger = l, world = w, budget = 10 }
  local b = spawn { ledger = l, world = w, budget = 10 }
  local c = spawn { ledger = l, world = w, budget = 10 }
  assert(a.budget == 10 and a.clamped == false, a.budget)
  assert(b.budget == 9 and b.clamped == true, b.budget)
  assert(c.budget == 8 and c.clamped == true, c.budget)
  assert(a.steps == 1 and b.steps == 1 and c.steps == 1)
  assert(l.steps_left == 7, l.steps_left)
end

-- ------------------------------------------------------- 8, 9: what is rendered

function T.a_label_reaches_the_rendered_line()
  local r = spawn { label = "pass one" }
  local text = subagent.render(r)
  local head = text:match("^[^\n]*")
  assert(contains(head, "(s1, pass one)"), head)
  assert(contains(head, "subagent reviewer"), head)
  assert(r.label == "pass one")
end

function T.include_none_shows_only_the_first_line()
  local r = spawn {}
  local only = subagent.render(r, { include = "none" })
  assert(not contains(only, "\n"), only)
  assert(contains(only, "answered in 1 of 12 steps."), only)

  local full = subagent.render(r, { include = "answer" })
  assert(contains(full, "the child is done"), full)

  local out = subagent.render(r, { include = "readout" })
  assert(contains(out, "stop: answered"), out)
  assert(contains(out, 'user: "do the job"'), out)
end

-- ------------------------------------------------------------- 10: the frame

function T.the_frame_travels_to_a_grandchild()
  local found
  local leaf = agent("leaf", { { name = "mark", tool = {
    about = "Record the frame this run was handed",
    run = function (c) found = subagent.frame(c); return "marked" end,
  } } })

  local leaf_world = world { { tool = "mark" }, "leaf done" }
  local mid = agent("mid", { { name = "delegate", tool = subagent.tool {
    about = "Hand a job on",
    agents = { leaf = leaf },
    world = leaf_world,
  } } })

  local l = subagent.ledger()
  local r = spawn {
    ledger = l,
    agents = { mid = mid },
    agent = "mid",
    world = world({ { tool = "delegate", args = { agent = "leaf", prompt = "go deeper" } }, "mid done" },
                  { ask = true }),
  }

  assert(r.stop == "answered", r.reason)
  assert(found ~= nil, "the grandchild never saw a frame")
  assert(found.ledger == l, "the grandchild charged a different pool")
  assert(found.depth == 2, found.depth)
  assert(l.spawned == 2, l.spawned)
end

-- ---------------------------------------------------- 11, 12, 36: bad requests

function T.an_unknown_agent_lists_the_roster()
  local m = world(ANSWER)
  local r = spawn {
    agent = "nobody",
    agents = { reviewer = agent("reviewer"), searcher = agent("searcher") },
    world = m,
  }
  assert(r.stop == "blocked" and r.blocked == "unknown", r.blocked)
  assert(r.steps == 0 and r.budget == 0)
  assert(contains(r.reason, "reviewer, searcher"), r.reason)
  assert(#m.model.seen == 0, "a model was called for an agent that does not exist")
  assert(r.pool.spawned == 0)
end

function T.an_empty_prompt_is_refused()
  local l = subagent.ledger()
  local before = l.steps_left
  for _, bad in ipairs { "", "   ", "\n", 7, true } do
    local r = spawn { prompt = bad, ledger = l }
    assert(r.stop == "blocked", tostring(bad))
    assert(r.blocked == "malformed", tostring(bad) .. " -> " .. tostring(r.blocked))
    assert(r.steps == 0 and r.budget == 0)
    assert(l.steps_left == before, "an empty prompt cost the pool something")
    assert(l.spawned == 0)
    local text = subagent.render(r)
    assert(contains(text, "did not run"), text)
  end
  -- A missing prompt says which way it was wrong.
  local none = subagent.run(ctx_of(), { agent = "x", agents = { x = agent("x") }, world = world(ANSWER) })
  assert(none.blocked == "malformed" and contains(none.reason, "gave none"), none.reason)
end

function T.bad_arguments_to_run_are_a_result_not_a_raise()
  local cases = {
    { agent = 7 },
    { agent = "reviewer", budget = "twelve" },
    { agent = "reviewer", childs = 2 },
    { agent = "reviewer", world = nil, agents = { reviewer = agent("reviewer") } },
  }
  cases[4].world = false
  for i = 1, #cases do
    local r = subagent.run(ctx_of(), (function ()
      local t = { prompt = "go", agents = { reviewer = agent("reviewer") }, world = world(ANSWER) }
      for k, v in pairs(cases[i]) do t[k] = v end
      if cases[i].world == false then t.world = nil end
      return t
    end)())
    assert(r.stop == "blocked", i .. " -> " .. tostring(r.stop))
    assert(type(r.reason) == "string" and r.reason ~= "")
  end
  assert(not pcall(subagent.run, "not a table", {}))
  assert(not pcall(subagent.run, {}, "not a table"))
end

-- ----------------------------------------------------------- 13, 27: bad news

function T.a_missing_file_inside_a_child_is_the_childs_news()
  local reader = agent("reader", { { name = "read", tool = {
    about = "Read a file",
    args = { path = spec.types.string "workspace-relative path" },
    run = function (c)
      local text, err = c.fs.read(c.args.path)
      if text == nil then return "could not read it: " .. err.message end
      return text
    end,
  } } })

  local w = world({ { tool = "read", args = { path = "gone.txt" } },
                    "there is no such file, so I stopped" },
                  { fs = { ["here.txt"] = "hello" } })
  local r = spawn { agents = { reader = reader }, agent = "reader", world = w }

  assert(r.stop == "answered", r.stop)
  assert(r.ok == true)
  assert(contains(r.answer, "no such file"), r.answer)
  assert(contains(r.calls[1].output, "no such file: gone.txt"), r.calls[1].output)
end

function T.a_timeout_is_reachable_without_a_clock()
  local slow = spawn { world = world { { code = "timeout", message = "timeout after 30s" } } }
  assert(slow.stop == "error", slow.stop)
  assert(slow.err.where == "model")
  local text = subagent.render(slow)
  assert(contains(text, "timeout after 30s"), text)

  local runner = agent("runner", { { name = "run", tool = {
    about = "Run a command",
    run = function (c)
      local r = c.sh.run { "sleep", "9" }
      if r == nil then return "the shell refused" end
      return "timed out: " .. tostring(r.timed_out)
    end,
  } } })
  local w = world({ { tool = "run" }, "it timed out, so I stopped" },
                  { sh = { ["sleep 9"] = { code = 124, timed_out = true } } })
  local r = spawn { agents = { runner = runner }, agent = "runner", world = w }
  assert(r.stop == "answered", r.stop)
  assert(contains(r.calls[1].output, "timed out: true"), r.calls[1].output)
end

-- --------------------------------------------------- 14, 15, 16: the limits bite

-- An agent whose every reply spawns another copy of itself.
local function forker(children, depth, steps, watch)
  local roster = {}
  local self_world
  local digger = agent("digger", { { name = "delegate", tool = subagent.tool {
    about = "Spawn another copy",
    pick = function (name) return roster[name], "there is only one agent here" end,
    world = function () return self_world end,
    children = children, depth = depth, steps = steps,
    budget = 4, watch = watch,
  } } })
  roster.digger = digger
  -- One reply forever: ask for another copy, unless a tool has already answered.
  self_world = world({ function (request)
    local msgs = request.messages
    for i = 1, #msgs do
      if msgs[i].role == "tool" then return { text = "deep enough", stop = "done" } end
    end
    return { calls = { { tool = "delegate", args = { agent = "digger", prompt = "go on" } } } }
  end }, { after = "repeat", ask = true })
  return digger, self_world
end

function T.a_fork_bomb_stops_at_the_fanout()
  local seen = {}
  local kid = agent("kid")
  local kid_world = world({ "kid done" }, { after = "repeat" })
  local result = parent_run(
    { agents = { kid = kid }, world = kid_world, children = 8, steps = 200,
      watch = function (r) seen[#seen + 1] = r end },
    { { tool = "delegate", args = { agent = "kid", prompt = "go" } } },
    { after = "repeat", turn = { budget = 10 } })

  assert(result.stop == "budget", result.stop)
  assert(#seen == 10, #seen)
  local ran, blocked = 0, 0
  for i = 1, #seen do
    if seen[i].stop == "answered" then ran = ran + 1
    else
      blocked = blocked + 1
      assert(seen[i].blocked == "children", seen[i].blocked)
      assert(seen[i].steps == 0)
    end
  end
  assert(ran == 8, ran)
  assert(blocked == 2, blocked)
  assert(seen[9].pool.children_left == 0)
end

function T.a_deep_chain_stops_at_the_depth()
  local seen = {}
  local digger, digger_world = forker(50, 3, 200, function (r) seen[#seen + 1] = r end)
  local l = subagent.ledger { depth = 3, children = 50, steps = 200 }
  local before = l.steps_left

  local r = subagent.run(ctx_of("digger", 0), {
    agent = "digger", agents = { digger = digger }, prompt = "start digging",
    world = digger_world, ledger = l, budget = 4,
  })

  assert(r.stop == "answered", r.reason)
  assert(l.spawned == 3, l.spawned)          -- depths 1, 2 and 3 ran; 4 never started
  assert(l.max_depth == 3)
  assert(#seen == 3, #seen)                  -- the root's own spawn is not watched

  -- The innermost spawn finishes first, so the blocked one is watched first.
  local blocked, spent_by_children = nil, 0
  for i = 1, #seen do
    if seen[i].stop == "blocked" then blocked = seen[i] else spent_by_children = spent_by_children + seen[i].steps end
  end
  assert(blocked ~= nil, "no run was blocked on depth")
  assert(blocked.blocked == "depth", blocked.blocked)
  assert(blocked.depth == 4, blocked.depth)
  assert(blocked.steps == 0 and blocked.budget == 0)
  assert(contains(blocked.reason, "deep"), blocked.reason)

  -- No reservation was taken for the run that never started: the pool at the end is
  -- exactly what the three chained children spent, and nothing more.
  local spent = before - l.steps_left
  assert(spent == spent_by_children + r.steps, spent)
  assert(spent > 0)

end

function T.an_empty_pool_blocks_before_any_model_call()
  local l = subagent.ledger { steps = 1 }
  local first = spawn { ledger = l, budget = 4 }
  assert(first.stop == "answered", first.stop)    -- one step was all it needed
  assert(first.budget == 1, first.budget)
  assert(l.steps_left == 0, l.steps_left)

  local untouched = world(ANSWER)
  local second = spawn { ledger = l, world = untouched }
  assert(second.stop == "blocked" and second.blocked == "steps", second.blocked)
  assert(#untouched.model.seen == 0, "a model was called with an empty pool")
  assert(second.steps == 0 and second.budget == 0)
  assert(contains(second.reason, "spent"), second.reason)
end

-- ------------------------------------------------ 18, 19, 20, 21, 22: cleanup

function T.a_child_that_errors_still_refunds()
  local l = subagent.ledger { steps = 64 }
  local r = spawn { ledger = l, budget = 12,
    world = world { { code = "timeout", message = "timeout after 30s" } } }
  assert(r.stop == "error", r.stop)
  assert(r.err.where == "model", r.err.where)
  assert(r.steps == 1, r.steps)
  assert(l.steps_left == 63, l.steps_left)
  assert(r.pool.steps_left == 63)
end

function T.a_raising_turn_does_not_leak_the_pool()
  local l = subagent.ledger { steps = 64 }
  local saved = turn.run
  turn.run = function () error("the loop fell over") end
  local ok, r = pcall(spawn, { ledger = l, budget = 12 })
  turn.run = saved
  assert(ok, "a raising turn escaped subagent.run")
  assert(r.stop == "error", r.stop)
  assert(r.err.where == "spawn", r.err.where)
  assert(contains(r.err.message, "the loop fell over"), r.err.message)
  assert(l.steps_left == 64, l.steps_left)
  assert(r.pool.steps_left == 64)
end

function T.a_permit_closed_twice_refunds_once()
  local l = subagent.ledger { steps = 20 }
  local permit = l:open { depth = 1, budget = 10 }
  assert(permit.budget == 10)
  assert(l.steps_left == 10)
  assert(l:close(permit, 4) == 6)
  assert(l.steps_left == 16)
  assert(l:close(permit, 4) == 0, "a second close conjured steps")
  assert(l.steps_left == 16)
  -- An overspend refunds nothing and is not an error; a negative spend reads as zero.
  local two = l:open { depth = 1, budget = 5 }
  assert(l:close(two, 99) == 0)
  local three = l:open { depth = 1, budget = 5 }
  assert(l:close(three, -3) == 5)
end

function T.a_broken_child_declaration_costs_nothing()
  local toolless = spec.new()
  spec.set_name(toolless, "toolless")
  spec.set_model(toolless, "test:model")
  assert(#spec.problems(toolless) > 0)

  local l = subagent.ledger()
  local m = world(ANSWER)
  local r = spawn { ledger = l, agents = { toolless = toolless }, agent = "toolless", world = m }
  assert(r.stop == "blocked" and r.blocked == "declaration", r.blocked)
  assert(contains(r.reason, "no tools"), r.reason)
  assert(l.steps_left == 64 and l.spawned == 0)
  assert(#m.model.seen == 0, "a broken declaration reached the model")
end

function T.a_tool_that_wants_a_gate_needs_one_in_the_childs_world()
  local gated = agent("gated", { { name = "danger", tool = {
    about = "Something worth asking about",
    ask = true,
    run = function () return "did it" end,
  } } })
  local w = world(ANSWER)
  w.ask = nil
  local r = spawn { agents = { gated = gated }, agent = "gated", world = w }
  assert(r.stop == "blocked" and r.blocked == "declaration", r.blocked)
  assert(contains(r.reason, "approval gate"), r.reason)
  assert(#w.model.seen == 0)
end

-- ------------------------------------------------- 23, 24, 25, 26: the world

function T.no_world_is_a_stated_refusal()
  local said = spawn { world = function () return nil, "not in this sandbox" end }
  assert(said.blocked == "ungranted", said.blocked)
  assert(contains(said.reason, '"not in this sandbox"'), said.reason)

  local raised = spawn { world = function () error("the wiring is wrong") end }
  assert(raised.blocked == "ungranted", raised.blocked)
  assert(contains(raised.reason, "the wiring is wrong"), raised.reason)
  local found = false
  for i = 1, #raised.notes do
    if contains(raised.notes[i], "world function raised") then found = true end
  end
  assert(found, "the raise left no note")

  local none = subagent.run(ctx_of(), {
    agent = "reviewer", prompt = "go", agents = { reviewer = agent("reviewer") } })
  assert(none.blocked == "ungranted", none.blocked)
end

function T.the_body_never_sees_the_model_port()
  local saw = {}
  local decl = subagent.tool {
    about = "Hand a job on",
    agents = { reviewer = agent("reviewer") },
    world = world { "the child answered" },
  }
  local watched = {
    about = decl.about, args = decl.args, ask = decl.ask,
    run = function (ctx)
      saw.model = ctx.model
      saw.ask = ctx.ask
      saw.fs = ctx.fs
      return decl.run(ctx)
    end,
  }
  local boss = spec.new()
  spec.set_name(boss, "boss")
  spec.set_model(boss, "test:model")
  spec.add_tool(boss, "delegate", watched)

  local result = turn.run(boss, "go", world({
    { tool = "delegate", args = { agent = "reviewer", prompt = "check it" } }, "done" },
    { ask = true }))

  assert(result.stop == "answered", result.stop)
  assert(saw.model == nil, "the body was handed a model port")
  assert(saw.ask == nil, "the body was handed the gate")
  assert(saw.fs ~= nil, "the body lost the rest of its context")
  local told
  for i = 1, #result.transcript do
    if result.transcript[i].role == "tool" then told = result.transcript[i].text end
  end
  assert(contains(told, "the child answered"), told)
end

function T.subagent_never_asks()
  local a = double.ask(true)
  local r = spawn { world = world(ANSWER, { ask = a }) }
  assert(r.stop == "answered", r.stop)
  assert(#a.asked == 0, "subagent put a spawn to a person")
end

function T.a_refusal_inside_a_child_is_the_childs_result()
  local gated = agent("gated", { { name = "danger", tool = {
    about = "Something worth asking about",
    ask = true,
    run = function () return "did it" end,
  } } })

  local denied = spawn {
    agents = { gated = gated }, agent = "gated",
    world = world({ { tool = "danger" }, "I was not allowed, so I stopped" },
                  { ask = { danger = false } }),
  }
  assert(denied.stop == "answered", denied.stop)
  assert(denied.calls[1].refused == true)

  local stopper = { request = function () return { allow = false, stop = true, why = "not that file" } end }
  local halted = spawn {
    agents = { gated = gated }, agent = "gated",
    world = world({ { tool = "danger" }, "never reached" }, { ask = stopper }),
  }
  assert(halted.stop == "refused", halted.stop)
  assert(contains(halted.reason, "not that file"), halted.reason)
  local text = subagent.render(halted)
  assert(contains(text, "stopped by the person"), text)
  assert(contains(text, "not that file"), text)
end

-- ----------------------------------------------- 28, 29, 30: what is rendered

function T.a_child_that_runs_out_of_budget_says_so()
  local r = spawn { budget = 2, world = world({
    { text = "thinking about it", calls = { { tool = "echo", args = { line = "a" } } } },
    { text = "still thinking", calls = { { tool = "echo", args = { line = "b" } } } },
  }, { after = "repeat" }) }

  assert(r.stop == "budget", r.stop)
  assert(r.answer == nil)
  assert(r.ok == false)
  local text = subagent.render(r)
  assert(contains(text, "spent its budget of 2 steps"), text)
  assert(contains(text, "did not finish"), text)
  assert(contains(text, "still thinking"), text)
end

function T.an_empty_answer_is_said_not_shown()
  local r = spawn { world = world { { text = "", stop = "done" } } }
  assert(r.stop == "answered", r.stop)
  assert(r.answer == "")
  local text = subagent.render(r)
  assert(contains(text, "answered with no text"), text)
  local body = text:gsub("^[^\n]*\n", "")
  assert(body:match("%S") ~= nil, "the rendered body was blank")
end

function T.a_long_answer_keeps_both_ends()
  local long = "START" .. string.rep("x", 19992) .. "END"
  assert(#long == 20000)
  local r = spawn { world = world { long } }
  local text = subagent.render(r, { max_chars = 4000 })
  local body = text:gsub("^[^\n]*\n\n", "")
  assert(contains(body, "16000 characters dropped"), body:sub(1, 80))
  assert(body:sub(1, 5) == "START", body:sub(1, 10))
  assert(body:sub(-3) == "END", body:sub(-10))
  local marker = "\n[... 16000 characters dropped ...]\n"
  assert(#body - #marker == 4000, #body - #marker)
end

-- -------------------------------------------------- 31, 32, 33, 34: behaviour

function T.watch_cannot_break_a_run()
  local raised = {}
  local result = parent_run(
    { agents = { kid = agent("kid") }, world = world { "kid done" },
      watch = function () error("the observer fell over") end },
    { { tool = "delegate", args = { agent = "kid", prompt = "go" } }, "done" })
  assert(result.stop == "answered", result.stop)

  local told
  for i = 1, #result.transcript do
    if result.transcript[i].role == "tool" then told = result.transcript[i].text end
  end
  assert(contains(told, "kid done"), told)

  -- The raise is on the child's notes, and the run is otherwise unchanged.
  local seen
  parent_run(
    { agents = { kid = agent("kid") }, world = world { "kid done" },
      watch = function (r) seen = r; error("again") end },
    { { tool = "delegate", args = { agent = "kid", prompt = "go" } }, "done" })
  local found = false
  for i = 1, #seen.notes do
    if contains(seen.notes[i], "the observer fell over") or contains(seen.notes[i], "again") then
      found = true
    end
  end
  assert(found, "the watch's raise left no note")
  assert(raised ~= nil)

  -- A watch that answers false changes nothing either.
  local plain = parent_run(
    { agents = { kid = agent("kid") }, world = world { "kid done" },
      watch = function () return false end },
    { { tool = "delegate", args = { agent = "kid", prompt = "go" } }, "done" })
  assert(plain.stop == "answered")
end

function T.nothing_given_is_mutated()
  local host_port = world(ANSWER)
  local child = agent("reviewer")
  local before_tools = #child.order
  local req = {
    agent = "reviewer", prompt = "go", budget = 6, label = "one",
    agents = { reviewer = child }, world = host_port,
  }
  local keys = {}
  for k, v in pairs(req) do keys[k] = v end

  local parent_ctx = ctx_of()
  local ctx_keys = {}
  for k in pairs(parent_ctx) do ctx_keys[k] = true end

  local r = subagent.run(parent_ctx, req)
  assert(r.stop == "answered", r.stop)

  assert(host_port.subagent == nil, "the host's port table gained a key")
  for k, v in pairs(req) do assert(keys[k] == v, "req." .. tostring(k) .. " changed") end
  for k in pairs(keys) do assert(req[k] ~= nil, "req lost " .. tostring(k)) end
  assert(#child.order == before_tools, "the child declaration changed")
  for k in pairs(parent_ctx) do assert(ctx_keys[k], "the parent context gained " .. tostring(k)) end
  assert(parent_ctx.subagent == nil)
end

function T.two_trees_do_not_leak()
  local one, two = subagent.ledger { steps = 20 }, subagent.ledger { steps = 20 }
  local a1 = spawn { ledger = one, budget = 4 }
  local b1 = spawn { ledger = two, budget = 4 }
  local a2 = spawn { ledger = one, budget = 4 }
  local b2 = spawn { ledger = two, budget = 4 }

  assert(a1.id == "reviewer/s1" and a2.id == "reviewer/s2")
  assert(b1.id == "reviewer/s1" and b2.id == "reviewer/s2")
  assert(one.spawned == 2 and two.spawned == 2)
  assert(one.steps_left == two.steps_left)
  assert(one.steps_left == 18, one.steps_left)

  -- A shared ledger starves: documented behaviour, not a bug.
  local shared = subagent.ledger { steps = 2, children = 4 }
  local x = spawn { ledger = shared, budget = 2 }
  local y = spawn { ledger = shared, budget = 2 }
  assert(x.stop ~= "blocked")
  assert(y.budget < 2 or y.blocked == "steps", y.budget)
end

function T.a_run_is_reproducible()
  local function once()
    local l = subagent.ledger()
    local r = spawn { ledger = l, label = "run",
      world = world { { tool = "echo", args = { line = "hi" } }, "said it" } }
    return r, subagent.render(r), subagent.readout(r)
  end
  local r1, text1, lines1 = once()
  local r2, text2, lines2 = once()
  assert(r1.id == r2.id and r1.stop == r2.stop and r1.steps == r2.steps)
  assert(r1.answer == r2.answer)
  assert(r1.reason == r2.reason)
  assert(text1 == text2, text1)
  assert(#lines1 == #lines2)
  for i = 1, #lines1 do assert(lines1[i] == lines2[i], lines1[i]) end
end

-- --------------------------------------------------- 35: refused at declaration

function T.bad_config_is_refused_at_declaration()
  local good = {
    about = "Hand a job on",
    agents = { reviewer = agent("reviewer") },
    world = world(ANSWER),
  }
  local function with(change)
    local c = {}
    for k, v in pairs(good) do c[k] = v end
    for k, v in pairs(change) do
      if v == "!nil" then c[k] = nil else c[k] = v end
    end
    return c
  end
  local function refused(change, word)
    local ok, err = pcall(subagent.tool, with(change))
    assert(not ok, "a bad config was accepted: " .. word)
    assert(contains(tostring(err), word), tostring(err) .. " (wanted " .. word .. ")")
  end

  refused({ childs = 2 }, "childs")
  refused({ agents = "!nil" }, "agents")
  refused({ pick = function () end }, "agents")
  refused({ agents = {} }, "empty")
  refused({ budget = 12, max_budget = 4 }, "max_budget")
  refused({ depth = -1 }, "depth")
  refused({ include = "everything" }, "include")
  refused({ about = "!nil" }, "about")
  refused({ world = "!nil" }, "world")
  refused({ max_chars = 10 }, "max_chars")
  refused({ watch = "loud" }, "watch")
  refused({ children = 0 }, "children")
  refused({ steps = 1.5 }, "steps")
  assert(not pcall(subagent.tool, "not a table"))

  -- And the good one builds a declaration a spec can hold.
  local decl = subagent.tool(good)
  local a = spec.new()
  spec.set_name(a, "boss")
  spec.set_model(a, "test:model")
  spec.add_tool(a, "delegate", decl)
  local schema = spec.schema(a)[1]
  assert(schema.name == "delegate")
  assert(#schema.args == 4, #schema.args)
  assert(schema.ask == true)

  -- The ledger refuses the same way.
  assert(not pcall(subagent.ledger, { childs = 2 }))
  assert(not pcall(subagent.ledger, 7))
  assert(not pcall(subagent.ledger, { steps = 0 }))
end

function T.one_agent_in_the_roster_needs_no_naming()
  local decl = subagent.tool {
    about = "Hand a job on",
    agents = { only = agent("only") },
    world = world { "the only one answered" },
  }
  assert(decl.args.agent.required == false)
  local a = spec.new()
  spec.set_name(a, "boss")
  spec.set_model(a, "test:model")
  spec.add_tool(a, "delegate", decl)
  local out = turn.run(a, "go", world({
    { tool = "delegate", args = { prompt = "just go" } }, "done" }, { ask = true }))
  assert(out.stop == "answered", out.stop)
  assert(out.calls[1].ok == true, out.calls[1].output)
  assert(contains(out.calls[1].output, "the only one answered"), out.calls[1].output)
end

-- ------------------------------------- what the first pass got wrong, pinned here

-- 4.6: "every line is a string with no embedded newline beyond those in quoted text".
-- A truncated line used to carry the rendered body's marker, newlines and all, so one
-- long message read out as three lines and a host splitting on "\n" got fragments.
function T.a_readout_line_is_one_line()
  local long = string.rep("z", 500)
  local r = spawn { world = world { long } }
  local lines = subagent.readout(r)
  assert(#lines == 3, #lines)                    -- user, agent, stop

  for i = 1, #lines do
    assert(not contains(lines[i], "\n"), "readout line " .. i .. " carries a newline")
  end
  local said = lines[2]
  assert(contains(said, "characters dropped"), said)
  assert(said:sub(1, 9) == 'agent: "z', said:sub(1, 20))
  assert(said:sub(-2) == 'z"', said:sub(-20))

  -- And a readout rendered into the parent's transcript splits back into exactly the
  -- lines the readout had, which is the whole point of the rule.
  local text = subagent.render(r, { include = "readout", max_chars = 4000 })
  local body = text:gsub("^[^\n]*\n\n", "")
  local n = 1
  for _ in body:gmatch("\n") do n = n + 1 end
  assert(n == #lines, n .. " lines in the rendered readout, " .. #lines .. " in the readout")

  -- The rendered body still keeps the marker on its own line: a paragraph is not a line.
  local wide = spawn { world = world { "START" .. string.rep("x", 19992) .. "END" } }
  assert(contains(subagent.render(wide, { max_chars = 4000 }),
    "\n[... 16000 characters dropped ...]\n"))
end

-- 4.4: the fourth child of a tree is root/s4 whether it was spawned at depth 1 or 3.
-- A mid-tree declaration naming its own `id` used to re-root every id beneath it, so
-- one pool minted ids under two prefixes.
function T.a_root_stays_the_trees_root_at_every_depth()
  local found
  local leaf = agent("leaf", { { name = "mark", tool = {
    about = "Record the frame this run was handed",
    run = function (c) found = subagent.frame(c); return "marked" end,
  } } })
  local mid = agent("mid", { { name = "delegate", tool = subagent.tool {
    about = "Hand a job on",
    agents = { leaf = leaf },
    world = world { { tool = "mark" }, "leaf done" },
    id = "somewhere-else",
  } } })

  local l = subagent.ledger()
  local r = subagent.run(ctx_of("root", 0), {
    agent = "mid", agents = { mid = mid }, prompt = "go", ledger = l,
    world = world({ { tool = "delegate", args = { agent = "leaf", prompt = "deeper" } }, "mid done" },
                  { ask = true }),
  })

  assert(r.stop == "answered", r.reason)
  assert(r.id == "root/s1", r.id)
  assert(found ~= nil, "the grandchild never saw a frame")
  assert(found.root == "root", found.root)
  assert(found.id == "root/s2", found.id)
end

-- 4.2: subagent.run raises for a non-table ctx and a non-table req, and for nothing
-- else. A ledger that came off a caller's hand or off a port is neither.
function T.a_broken_ledger_is_a_note_not_a_raise()
  local hostile = {
    open     = function () error("open fell over") end,
    close    = function () error("close fell over") end,
    snapshot = function () error("snapshot fell over") end,
  }

  local ok, r = pcall(spawn, { ledger = hostile })
  assert(ok, "a broken ledger escaped subagent.run as a raise")
  assert(r.stop == "answered", r.stop)
  assert(type(r.pool.steps_left) == "number", "the result lost its pool")
  local said = false
  for i = 1, #r.notes do if contains(r.notes[i], "not one") then said = true end end
  assert(said, "a fresh tree was opened and nothing said so")

  -- The same table arriving on a port, which is where a frame's ledger comes from.
  local w = world(ANSWER)
  w.subagent = { ledger = hostile, depth = 1, id = "x/s1", root = "x" }
  local ok2, r2 = pcall(subagent.run, ctx_of(), {
    agent = "reviewer", agents = { reviewer = agent("reviewer") }, prompt = "go", world = w })
  assert(ok2, "a broken ledger on a port escaped as a raise")
  assert(r2.stop == "answered", r2.stop)
end

-- The child's own notes are the parent's news too, and nothing else in the tree
-- carries them across.
function T.a_childs_own_notes_reach_the_result()
  local noter = agent("noter", { { name = "n", tool = {
    about = "Leave a note",
    run = function (c) c.note("the child wrote this down"); return "ok" end,
  } } })
  local r = spawn { agents = { noter = noter }, agent = "noter",
    world = world { { tool = "n" }, "done" } }
  assert(r.stop == "answered", r.stop)
  local found = false
  for i = 1, #r.notes do if contains(r.notes[i], "the child wrote this down") then found = true end end
  assert(found, "the child's note did not reach the result")
end

-- 4.2 and 5: a budget that is not a number at all is malformed, and the tool body must
-- not read a `false` as "none given" and quietly hand back its own default.
function T.a_budget_that_is_not_a_number_is_a_stated_result()
  local decl = subagent.tool {
    about = "Hand a job on",
    agents = { reviewer = agent("reviewer") },
    world = world({ "the child answered" }, { after = "repeat" }),
    budget = 7,
  }
  local said = decl.run { agent = "boss", depth = 0,
    args = { agent = "reviewer", prompt = "go", budget = false } }
  assert(contains(said, "did not run"), said)
  assert(contains(said, "boolean"), said)

  -- And an absent budget is still the declaration's own default.
  local plain = decl.run { agent = "boss", depth = 0, args = { agent = "reviewer", prompt = "go" } }
  assert(contains(plain, "of 7 steps"), plain)
end

-- ------------------------------------------------------ 37, 38: the file itself

function T.stops_and_blocks_are_exactly_the_documented_sets()
  local stops = { "answered", "budget", "refused", "error", "blocked" }
  assert(#subagent.stops == #stops)
  for i = 1, #stops do assert(subagent.stops[i] == stops[i], subagent.stops[i]) end

  local blocks = { "malformed", "unknown", "declaration", "ungranted", "depth", "children", "steps" }
  assert(#subagent.blocks == #blocks)
  for i = 1, #blocks do assert(subagent.blocks[i] == blocks[i], subagent.blocks[i]) end

  assert(not pcall(function () subagent.stops.extra = "more" end))
  assert(not pcall(function () subagent.blocks.extra = "more" end))

  -- Every one of the twelve is reachable, and this sweep reaches it.
  local reached = {}
  local l = subagent.ledger { depth = 0, children = 2, steps = 3 }
  reached[spawn({ world = world(ANSWER) }).stop] = true
  reached[spawn({ budget = 1, world = world({ { text = "on it",
    calls = { { tool = "echo", args = { line = "a" } } } } }, { after = "repeat" }) }).stop] = true
  reached[spawn({ world = world { { code = "unavailable", message = "down" } } }).stop] = true
  local gated = agent("gated", { { name = "danger", tool = {
    about = "Worth asking about", ask = true, run = function () return "did it" end } } })
  reached[spawn({ agents = { gated = gated }, agent = "gated",
    world = world({ { tool = "danger" } },
      { ask = { request = function () return { allow = false, stop = true, why = "no" } end } }) }).stop] = true

  local blocked = {}
  blocked[spawn({ prompt = "" }).blocked] = true
  blocked[spawn({ agent = "nobody" }).blocked] = true
  local toolless = spec.new()
  spec.set_name(toolless, "t")
  spec.set_model(toolless, "test:model")
  blocked[spawn({ agents = { t = toolless }, agent = "t" }).blocked] = true
  blocked[spawn({ world = function () return nil, "no" end }).blocked] = true
  blocked[spawn({ ledger = l, world = world(ANSWER) }).blocked] = true       -- depth 1 > 0
  local l2 = subagent.ledger { children = 1, steps = 30 }
  spawn { ledger = l2, world = world(ANSWER) }
  blocked[spawn({ ledger = l2, world = world(ANSWER) }).blocked] = true      -- fanout
  local l3 = subagent.ledger { steps = 1, children = 9 }
  spawn { ledger = l3, budget = 1, world = world(ANSWER) }
  blocked[spawn({ ledger = l3, world = world(ANSWER) }).blocked] = true      -- pool

  for i = 1, #stops do
    assert(reached[stops[i]] or stops[i] == "blocked", "no test reaches " .. stops[i])
  end
  reached["blocked"] = true
  for i = 1, #blocks do
    assert(blocked[blocks[i]], "no test reaches " .. blocks[i])
  end
  for k in pairs(blocked) do
    local known = false
    for i = 1, #blocks do if blocks[i] == k then known = true end end
    assert(known, "a child was blocked with " .. tostring(k))
  end
end

function T.the_module_requires_only_turn()
  local path = here .. "/../src/subagent.lua"
  local f = assert(io.open(path, "r"))
  local source = f:read("*a")
  f:close()

  for name in source:gmatch('require%s*%(?%s*["\']([%w%._%-]+)["\']') do
    assert(name == "turn" or name == "src.turn", "subagent requires " .. name)
  end

  local banned = {
    "%f[%w]io%.", "%f[%w]os%.", "math%.random", "%f[%w]print%s*%(",
    "://", "%f[%w]dofile%s*%(", "%f[%w]loadfile%s*%(",
  }
  for i = 1, #banned do
    assert(source:find(banned[i]) == nil, "src/subagent.lua reaches for " .. banned[i])
  end
  for _, vendor in ipairs { "openai", "anthropic", "http", "socket", "curl" } do
    assert(source:lower():find(vendor, 1, true) == nil, "src/subagent.lua names " .. vendor)
  end
end

return T
