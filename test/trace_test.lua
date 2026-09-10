-- trace: the run's own tree, and the two renderings of it.
--
-- The tests that matter here are the ones about a span that does NOT close, and about
-- determinism: a tracer whose spans differ between two identical runs is a tracer whose
-- numbers cannot be compared, which is the only reason to have one.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local trace  = require "trace"
local turn   = require "turn"
local spec   = require "spec"
local double = require "double"

local T = {}

local function an_agent()
  local a = spec.new()
  a.name, a.model = "tracer", "test:scripted"
  spec.add_tool(a, "read", {
    about = "Read a file",
    args = { path = spec.types.string("the path") },
    run = function (c) return tostring(c.fs.read(c.args.path)) end,
  })
  spec.add_tool(a, "file", {
    about = "File it",
    ask = true,
    args = { text = spec.types.string("what") },
    run = function () return "filed" end,
  })
  spec.add_tool(a, "boom", {
    about = "Raise",
    run = function () error("a tool that raises") end,
  })
  return a
end

local function world(cfg)
  cfg = cfg or {}
  cfg.clock = cfg.clock or { at = 1757462400 }
  return double.world(cfg)
end

local function named(spans, name)
  local out = {}
  for i = 1, #spans do
    if spans[i].name == name or spans[i].name:sub(1, #name) == name then out[#out + 1] = spans[i] end
  end
  return out
end

local function by_id(spans)
  local out = {}
  for i = 1, #spans do out[spans[i].id] = spans[i] end
  return out
end

function T.a_run_records_a_tree_and_the_tree_is_on_the_result()
  local r = turn.run(an_agent(), "go", world {
    fs = { ["a.md"] = "text" },
    model = { { tool = "read", args = { path = "a.md" } }, { text = "done" } },
  })
  assert(type(r.spans) == "table" and #r.spans > 0)

  local root = r.spans[1]
  assert(root.name == "invoke_agent tracer", root.name)
  assert(root.parent == nil, "the root has a parent")
  assert(root.attrs["malleable.stop"] == "answered")

  -- A tool call hangs off the step that asked for it, and the step off the run.
  local index = by_id(r.spans)
  local tool = named(r.spans, "execute_tool")[1]
  assert(tool, "no tool span")
  local step = index[tool.parent]
  assert(step and step.name == "malleable.step", tostring(step and step.name))
  assert(index[step.parent] == root, "a step is not under the run")
end

-- The provider is what the declaration said, and nothing is invented when it said nothing.
--
-- `gen_ai.provider.name` replaced `gen_ai.system` in the conventions, so this is also the
-- test that says which document this tree is pinned to: it fails if the old name comes
-- back, and it fails if the loop starts guessing a provider for a bare model id -- which
-- would be rule 1 broken by a default rather than by a require.
function T.the_chat_span_names_the_provider_the_declaration_named()
  local r = turn.run(an_agent(), "go", world { model = { { text = "done" } } })
  local chat = named(r.spans, "chat")[1]
  assert(chat, "no chat span")
  assert(chat.attrs["gen_ai.provider.name"] == "test", tostring(chat.attrs["gen_ai.provider.name"]))
  assert(chat.attrs["gen_ai.request.model"] == "test:scripted")
  assert(chat.attrs["gen_ai.system"] == nil, "the retired name is being written")

  local bare = an_agent()
  bare.model = "scripted"
  local r2 = turn.run(bare, "go", world { model = { { text = "done" } } })
  local chat2 = named(r2.spans, "chat")[1]
  assert(chat2, "no chat span")
  assert(chat2.attrs["gen_ai.provider.name"] == nil, "a bare model id got a provider anyway")
end

function T.the_gate_is_a_span_of_its_own_under_the_call_it_is_about()
  local r = turn.run(an_agent(), "go", world {
    ask = { file = false },
    model = { { tool = "file", args = { text = "x" } }, { text = "done" } },
  })
  local gate = named(r.spans, "malleable.gate")[1]
  assert(gate, "no gate span")
  assert(gate.attrs["malleable.gate.answer"] == "refused", tostring(gate.attrs["malleable.gate.answer"]))
  local parent = by_id(r.spans)[gate.parent]
  assert(parent and parent.name == "execute_tool file", tostring(parent and parent.name))
  -- The refused call is marked, and says who refused it.
  assert(parent.ok == false, "a refused call is recorded as ok")
  assert(parent.attrs["malleable.refused_by"] == "gate")

  -- And when the human says yes.
  r = turn.run(an_agent(), "go", world {
    ask = { file = true },
    model = { { tool = "file", args = { text = "x" } }, { text = "done" } },
  })
  assert(named(r.spans, "malleable.gate")[1].attrs["malleable.gate.answer"] == "allowed")
end

function T.a_tool_that_raises_closes_its_span_and_the_turn_goes_on()
  local r = turn.run(an_agent(), "go", world {
    model = { { tool = "boom", args = {} }, { text = "I could not." } },
  })
  local tool = named(r.spans, "execute_tool boom")[1]
  assert(tool, "no span for the tool that raised")
  assert(tool.ok == false, "a raising tool closed ok")
  assert(tool.attrs["malleable.unclosed"] == nil, "its span was left open")
  assert(r.stop == "answered", r.stop)
end

function T.a_run_that_stops_on_budget_still_closes_every_span()
  local r = turn.run(an_agent(), "go", world {
    fs = { ["a.md"] = "text" },
    model = { after = "repeat", replies = { { tool = "read", args = { path = "a.md" } } } },
  }, { budget = 3 })
  assert(r.stop == "budget", r.stop)
  for i = 1, #r.spans do
    assert(r.spans[i].attrs["malleable.unclosed"] == nil,
           "the span " .. r.spans[i].name .. " was left open by a budget stop")
  end
  assert(r.spans[1].attrs["malleable.steps"] == 3, tostring(r.spans[1].attrs["malleable.steps"]))
end

-- A span left open is MARKED, and that is the one bug in a tracer that hides every other
-- one: a span that never closes makes its whole subtree unattributable.
--
-- Tested at the recorder rather than through a run, and the distinction is worth stating.
-- The loop closes everything it opens on every path it has -- a raise, a refusal, a
-- budget stop, a depth stop -- so there is no run that leaves one open, and the tests
-- above assert exactly that. What this covers is the mechanism that catches the case
-- nobody wrote: a caller above the loop, or a path added later, that does not close.
function T.a_span_left_open_is_closed_by_the_sweep_and_marked()
  local r = turn.recorder({ now = function () return 1757462400 end }, nil, 0)
  local root = r.open_span("invoke_agent x", nil, {})
  local left = r.open_span("execute_tool slow", root, {})
  local shut = r.open_span("malleable.gate slow", left, {})
  r.close_span(shut, {}, true)
  r.close_span(root, {}, true)
  r.close_all(root)

  local by = by_id(r.spans)
  assert(by[left].attrs["malleable.unclosed"] == true, "an open span was not marked")
  assert(by[left].ok == false, "an unclosed span passed")
  assert(by[shut].attrs["malleable.unclosed"] == nil, "a closed span was marked")
  assert(by[root].attrs["malleable.unclosed"] == nil, "the run was marked")

  -- And the sweep respects its floor: a span opened BEFORE the run is the caller's.
  local r2 = turn.recorder({ now = function () return 1757462400 end }, nil, 0)
  local beat = r2.open_span("malleable.beat digest", nil, {})
  local run = r2.open_span("invoke_agent x", beat, {})
  r2.close_span(run, {}, true)
  r2.close_all(run)
  local index = by_id(r2.spans)
  assert(index[beat].attrs["malleable.unclosed"] == nil,
         "the loop swept a span its caller still held")
end

function T.the_same_run_traced_twice_on_the_same_doubles_is_the_same_trace()
  local function once()
    local r = turn.run(an_agent(), "go", world {
      fs = { ["a.md"] = "text" },
      ask = { file = true },
      model = { { tool = "read", args = { path = "a.md" } },
                { tool = "file", args = { text = "x" } }, { text = "done" } },
    })
    return trace.otlp(r.spans, { trace = "abc", service = "test" })
  end
  -- A tracer whose spans differ between two identical runs is a tracer whose numbers
  -- cannot be compared, which is the only reason to have one.
  assert(once() == once(), "two identical runs produced different traces")
end

function T.time_comes_from_the_clock_port_and_nowhere_else()
  local r = turn.run(an_agent(), "go", world {
    clock = { at = 1757462400 },
    model = { { text = "done" } },
  })
  -- Milliseconds from the frozen double, exactly, so a test can assert a number.
  assert(r.spans[1].at == 1757462400000, tostring(r.spans[1].at))
  assert(r.spans[1].ms == 0, tostring(r.spans[1].ms))
end

-- ------------------------------------------------- what happens before the loop
--
-- These four ran BEFORE anything could record them, because the recorder was built inside
-- `turn.run` and died with it. One cause, four missing span kinds (mar-qghy). What follows
-- is the proof that the hoist took: the run's tree now starts where the run starts.

local function prefix()
  return dofile(here .. "/../agent.lua")
end

function T.the_skills_a_run_was_briefed_on_are_a_span_of_the_run()
  local agent = prefix()
  agent.reset(); agent.name "keeper"; agent.model "test:m"
  local w = agent.double.world {
    clock = { at = 1757462400 },
    skills = { review = "read the diff twice", triage = "reproduce it first" },
    model = { { text = "done" } },
  }
  local r = agent.run("look", w)
  assert(r.stop == "answered", r.stop)

  local index = by_id(r.spans)
  local root = r.spans[1]
  assert(root.name == "invoke_agent keeper", root.name)
  assert(root.parent == nil, "the run is not the root of its own tree")

  local skill = named(r.spans, "malleable.skill")[1]
  assert(skill, "a run briefed on two skills recorded nothing about them")
  assert(index[skill.parent] == root, "the briefing is not under the run")
  assert(skill.attrs["malleable.skills"] == 2, tostring(skill.attrs["malleable.skills"]))
  -- A count, never the procedure. The words a person wrote are the payload rule 8 exists
  -- for, and they reach the model through the system message, not through a span.
  for _, v in pairs(skill.attrs) do
    assert(type(v) ~= "string" or not v:match("diff"), "the briefing leaked into the trace")
  end
end

function T.each_server_a_run_reaches_is_a_span_and_the_one_that_is_down_fails_its_own()
  local agent = prefix()
  agent.reset(); agent.name "keeper"; agent.model "test:m"
  agent.uses "github" { command = { "npx", "x" }, ask = false }
  agent.uses "docs" {}
  local w = agent.double.world {
    clock = { at = 1757462400 },
    model = { { text = "done" } },
    mcp = { github = { tools = { { name = "list_issues", description = "List them",
                                   inputSchema = { type = "object", properties = {} } } },
                       answers = { list_issues = "3 open" } },
            docs   = { down = "no such command" } },
  }
  local r = agent.run("look", w)

  local index = by_id(r.spans)
  local root = r.spans[1]
  local servers = named(r.spans, "malleable.server")
  assert(#servers == 2, "two servers were reached and " .. #servers .. " were recorded")

  local ok_one, down_one
  for i = 1, #servers do
    assert(index[servers[i].parent] == root, servers[i].name .. " is not under the run")
    if servers[i].ok then ok_one = servers[i] else down_one = servers[i] end
  end
  assert(ok_one and ok_one.name == "malleable.server github", tostring(ok_one and ok_one.name))
  assert(ok_one.attrs["malleable.tools"] == 1, tostring(ok_one.attrs["malleable.tools"]))
  -- The server that did not answer FAILS ITS OWN SPAN. Before this it was a note on the
  -- run and nothing else, so a collector saw a healthy run with a sentence in it.
  assert(down_one and down_one.name == "malleable.server docs", tostring(down_one and down_one.name))
  assert(down_one.attrs["malleable.tools"] == 0, tostring(down_one.attrs["malleable.tools"]))
  -- And it is still a note, in front of the run's own, and now counted as one.
  assert(r.notes[1]:match("docs"), tostring(r.notes[1]))
  assert(root.attrs["malleable.notes"] >= 1, tostring(root.attrs["malleable.notes"]))
end

function T.a_beat_that_fires_wraps_the_run_it_started()
  local agent = prefix()
  agent.reset(); agent.name "keeper"; agent.model "test:m"
  agent.tool "write" { about = "Write it", run = function () return "written" end }
  agent.every "digest" { every = 1, runs = "write the digest" }
  local w = agent.double.world {
    clock = { at = 1757462400 },
    model = { { text = "written" } },
  }
  local ran = agent.tick(w)
  assert(#ran == 1 and ran[1].beat == "digest", "the beat did not fire")
  local result = ran[1].result
  assert(type(result) == "table" and result.stop == "answered", tostring(result and result.stop))

  -- One tree per beat, rooted at the beat, with the whole run under it: a trace in a
  -- collector says which scheduled thing produced it.
  local index = by_id(result.spans)
  local root = result.spans[1]
  assert(root.name == "malleable.beat digest", root.name)
  assert(root.parent == nil, "the beat is not the root of its own tree")
  assert(root.attrs["malleable.stop"] == "answered", tostring(root.attrs["malleable.stop"]))
  local run = named(result.spans, "invoke_agent")[1]
  assert(run, "the beat recorded no run")
  assert(index[run.parent] == root, "the run is not under the beat that started it")
end

function T.a_recorder_handed_in_is_checked_before_a_run_starts_with_it()
  local a = an_agent()
  local w = world { model = { { text = "done" } } }
  local ok, why = turn.check(a, w, { tracer = 7 })
  assert(not ok and table.concat(why, "; "):match("opts.tracer is a recorder"), table.concat(why, "; "))
  ok, why = turn.check(a, w, { tracer = { open_span = function () end } })
  assert(not ok and table.concat(why, "; "):match("close_span"), table.concat(why, "; "))
  -- A span id names a span in a recorder, so it cannot arrive without one.
  ok, why = turn.check(a, w, { run_span = "1" })
  assert(not ok and table.concat(why, "; "):match("opts.tracer is missing"), table.concat(why, "; "))
  ok, why = turn.check(a, w, { notes = { "fine", 7 } })
  assert(not ok and table.concat(why, "; "):match("opts.notes%[2%] is a string"), table.concat(why, "; "))
end

-- What the agent DID with a shell, without the shell command going anywhere.
--
-- The run's most behaviourally loaded moment used to be the one its trace was blindest
-- to: `execute_tool shell`, ok, a duration, and nothing about `rm -rf build` (mar-7qd3).
function T.a_shell_call_says_what_it_did_and_never_what_it_ran()
  local agent = prefix()
  agent.reset(); agent.name "runner"; agent.model "test:m"
  agent.shell { root = ".", about = "Run one command." }
  local secret = "curl -H 'Authorization: Bearer sk-do-not-log' https://api.example/v1"
  local w = agent.double.world {
    clock = { at = 1757462400 },
    ask = { shell = true },
    sh = { ["sh -c git status"] = { code = 0, out = "clean\n" },
           ["sh -c " .. secret] = { code = 0, out = "{}\n" },
           ["sh -c frobnicate --x"] = { code = 0, out = "?\n" } },
    model = { { tool = "shell", args = { command = "git status" } },
              { tool = "shell", args = { command = secret } },
              { tool = "shell", args = { command = "frobnicate --x" } },
              { text = "done" } },
  }
  local r = agent.run("go", w)
  assert(r.stop == "answered", r.stop)

  local calls = named(r.spans, "execute_tool")
  assert(#calls == 3, #calls)
  assert(calls[1].attrs["malleable.act"] == "inspects", tostring(calls[1].attrs["malleable.act"]))
  assert(calls[2].attrs["malleable.act"] == "connects", tostring(calls[2].attrs["malleable.act"]))
  -- A command nothing can name is a GAP, counted, and never guessed at.
  assert(calls[3].attrs["malleable.act"] == nil, tostring(calls[3].attrs["malleable.act"]))
  assert(calls[3].attrs["malleable.unplaced"] == 1, tostring(calls[3].attrs["malleable.unplaced"]))

  -- Two attributes and no more. `spec/command.md` promises that a shell call's span
  -- carries `malleable.act` "and no other new attribute" -- so a reader that grew a third
  -- one quietly would be caught here rather than in a collector.
  local base = { ["gen_ai.operation.name"] = true, ["gen_ai.tool.name"] = true,
                 ["gen_ai.tool.call.id"] = true, ["malleable.act"] = true,
                 ["malleable.unplaced"] = true, ["malleable.refused_by"] = true }
  for i = 1, #calls do
    for key in pairs(calls[i].attrs) do
      assert(base[key], "a shell call's span grew " .. key)
    end
  end

  -- Rule 8, on the run that most tempts somebody to relax it. Not one span anywhere in
  -- this tree carries any part of what was typed.
  for i = 1, #r.spans do
    for key, value in pairs(r.spans[i].attrs) do
      if type(value) == "string" then
        assert(not value:find("sk-do-not-log", 1, true), key .. " carries the token")
        assert(not value:find("api.example", 1, true), key .. " carries the host")
        assert(not value:find("frobnicate", 1, true), key .. " carries the command")
      end
    end
  end
end

function T.the_vocabulary_is_closed_and_says_what_a_value_may_be()
  assert(trace.allowed("gen_ai.tool.name", "read"))
  assert(trace.allowed("malleable.steps", 3))
  assert(trace.allowed("malleable.stop", "answered"))

  local fine, why = trace.allowed("malleable.stop", "finished")
  assert(not fine and why:match("one of"), tostring(why))
  fine, why = trace.allowed("malleable.steps", "three")
  assert(not fine and why:match("is a number"), tostring(why))
  fine, why = trace.allowed("something.invented", "x")
  assert(not fine and why:match("not in the vocabulary"), tostring(why))
end

-- The contract and the vocabulary say the same thing, in both directions.
--
-- `spec/trace.md` carries the attribute table a person reads; `trace.ADOPTED` and
-- `trace.MINTED` are what the code enforces. Nothing but a habit kept them together, and
-- a habit had already let them drift: the spec listed a `malleable.gate.why` that is not
-- written and omitted the `malleable.unclosed` that is. So this reads the spec as text and
-- fails on either half of the disagreement. It is the check the ontology was going to be,
-- moved into the tree that is published, where every embedder gets it.
function T.the_spec_and_the_vocabulary_name_the_same_attributes()
  local f = assert(io.open(here .. "/../spec/trace.md", "rb"), "spec/trace.md is missing")
  local text = f:read("*a")
  f:close()

  -- Only "The attributes". The section above it tables the SPAN NAMES, which are
  -- `malleable.`-prefixed too and are a different vocabulary.
  local section = text:match("\n## The attributes\n(.-)\n## ")
  assert(section, "spec/trace.md no longer has a section called The attributes")

  -- Minted: one table row each, `| `malleable.x` | ... |`.
  local in_spec, in_code = {}, {}
  for name in section:gmatch("|%s*`(malleable%.[%w%._]+)`%s*|") do in_spec[name] = true end
  for name in pairs(trace.MINTED) do in_code[name] = true end
  for name in pairs(in_code) do
    assert(in_spec[name], name .. " is written by the code and is not in spec/trace.md")
  end
  for name in pairs(in_spec) do
    assert(in_code[name], name .. " is promised by spec/trace.md and is not in trace.MINTED")
  end

  -- Adopted: named in the prose of "The attributes", one backticked `gen_ai.` each.
  local adopted = section:match("%*%*Adopted%.%*%*(.-)%*%*The pin%.%*%*")
  assert(adopted, "spec/trace.md no longer states what it adopts, or no longer pins it")
  local said, have = {}, {}
  for name in adopted:gmatch("`(gen_ai%.[%w%._]+)`") do said[name] = true end
  for i = 1, #trace.ADOPTED do have[trace.ADOPTED[i]] = true end
  for name in pairs(have) do
    assert(said[name], name .. " is adopted by the code and is not in spec/trace.md")
  end
  for name in pairs(said) do
    assert(have[name], name .. " is promised by spec/trace.md and is not in trace.ADOPTED")
  end
end

function T.the_wire_format_is_a_string_and_this_file_opens_no_socket()
  local r = turn.run(an_agent(), "go", world { model = { { text = "done" } } })
  local doc = trace.otlp(r.spans, { trace = string.rep("a", 32), service = "typeaway" })
  assert(type(doc) == "string")
  assert(doc:match('"resourceSpans"') and doc:match('"scopeSpans"'), doc:sub(1, 120))
  assert(doc:match('"traceId":"' .. string.rep("a", 32) .. '"'), "the host's trace id is not used")
  assert(doc:match('"startTimeUnixNano":"1757462400000000000"'), "the time is not in nanoseconds")

  -- Pure: a table in, a string out. It reaches nothing.
  --
  -- Read with the comments stripped. A file is allowed to SAY "require" while explaining
  -- why it does not call it, and a check that cannot tell the two apart is a check that
  -- makes the code harder to explain -- which is the failure mode mar-4o07 is about, in
  -- miniature and in our own tests.
  local text = io.open(here .. "/../src/trace.lua", "rb"):read("*a")
  local code = text:gsub("%-%-%[%[.-%]%]", " "):gsub("%-%-[^\n]*", " ")
  assert(not code:find("%f[%w]io%."), "trace.lua names io")
  assert(not code:find("%f[%w]os%."), "trace.lua names os")
  assert(not code:find("%f[%w]require%f[%W]"), "trace.lua requires something")
end

function T.the_tree_renders_for_a_person_with_the_failures_marked()
  local r = turn.run(an_agent(), "go", world {
    ask = { file = false },
    model = { { tool = "file", args = { text = "x" } }, { text = "done" } },
  })
  local text = trace.render(r.spans)
  assert(text:match("invoke_agent tracer"), text)
  assert(text:match("!%s*execute_tool file"), text)     -- the refused call, marked
  assert(text:match("gate%.answer=refused"), text)
  assert(trace.render({}) == "(no spans)\n")
end

function T.wrong_shapes_raise()
  assert(not pcall(trace.otlp, 7))
  assert(not pcall(trace.render, "spans"))
end

return T
