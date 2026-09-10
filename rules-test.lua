-- The eight rules of DESIGN.md, each with the test it names.
--
--     lua rules-test.lua
--
-- These are not the subsystem tests. test/ proves that each part does what its own
-- specification says; this file proves the eight things the whole tree promises, and each
-- test here is written to FAIL the moment its rule stops holding.
--
-- Rules 1, 2 and 7 are checked by reading a source file as text, because they are claims
-- about what a file does not contain and no run can prove an absence. The rest are
-- checked by running the harness.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. here .. "/src/?.lua;" .. package.path

local agent = require "agent"
local spec  = require "spec"
local turn  = require "turn"
local cli   = require "cli"

local T, ORDER = {}, {}

local function rule(n, name, fn)
  T[name] = fn
  ORDER[#ORDER + 1] = { n = n, name = name }
end

local function source(path)
  local f = assert(io.open(here .. "/" .. path, "rb"), "cannot read " .. path)
  local text = f:read("*a")
  f:close()
  return text
end

local function has(text, needle)
  return type(text) == "string" and text:find(needle, 1, true) ~= nil
end

-- A declaration good enough to run, with whatever tools a test hangs on it.
local function an_agent()
  local a = spec.new()
  spec.set_name(a, "subject")
  spec.set_model(a, "test:scripted")
  return a
end

-- ===========================================================================
-- Rule 1. The core knows no vendor.
--
--   src/turn.lua may not name a provider, an HTTP library, a filesystem or a clock.
--   It takes a port table and calls it. Anything real is supplied by the host.

rule(1, "core_names_no_vendor", function ()
  local text = source("src/turn.lua")
  local lower = text:lower()

  -- A vendor, a wire, or a way to reach the world without going through the port.
  local banned = {
    "openai", "anthropic", "openrouter", "mercury", "gpt", "claude", "gemini",
    "llama", "mistral", "bedrock", "ollama",
    "http", "://", "socket", "curl", "json", "api%.", "chat/completions",
    "%f[%w]io%.", "%f[%w]os%.", "dofile", "loadstring", "%f[%w]load%s*%(",
    "popen", "math%.random", "print%s*%(",
  }
  for i = 1, #banned do
    local at = lower:find(banned[i])
    assert(at == nil, "src/turn.lua names " .. banned[i] .. " at byte " .. tostring(at))
  end

  -- One import, and it is the declaration surface. Anything else is a dependency the
  -- core is not allowed to have.
  for name in text:gmatch("require%s*%(?%s*[\"']([%w%._%-]+)[\"']") do
    assert(name == "spec" or name == "src.spec", "src/turn.lua requires " .. name)
  end

  -- And the other half of the rule, run rather than read: a whole turn drives on a
  -- port made of nothing but closures written here. No fs, no sh, no clock, no log --
  -- if turn reached for any of them this would raise rather than answer.
  local a = an_agent()
  spec.add_tool(a, "double_it", {
    about = "Double a number",
    args  = { n = spec.types.number "the number" },
    run   = function (c) return tostring(c.args.n * 2) end,
  })
  local step = 0
  local port = {
    model = { call = function ()
      step = step + 1
      if step == 1 then return { calls = { { id = "a", tool = "double_it", args = { n = 21 } } } } end
      return { text = "42", stop = "done" }
    end },
  }
  local result = turn.run(a, "go", port)
  assert(result.stop == "answered", tostring(result.stop))
  assert(result.answer == "42", tostring(result.answer))
  assert(result.calls[1].output == "42", tostring(result.calls[1].output))
end)

-- ===========================================================================
-- Rule 2. A declaration cannot run anything.
--
--   src/spec.lua builds a plain table and never calls a tool body, a model or a hook.
--   Loading an agent file is safe on an untrusted file; only turn.run executes.

rule(2, "loading_runs_no_body", function ()
  local text = source("src/spec.lua")

  -- It cannot reach the world at all, and it cannot compile anything.
  local banned = {
    "%f[%w]io%.", "%f[%w]os%.", "%f[%w]require%f[%W]", "dofile", "loadstring",
    "%f[%w]load%s*%(", "popen", "coroutine", "print%s*%(",
  }
  for i = 1, #banned do
    local at = text:find(banned[i])
    assert(at == nil, "src/spec.lua names " .. banned[i] .. " at byte " .. tostring(at))
  end

  -- And it never calls what it was handed. `t.run` is checked for its type and stored;
  -- a `(` after it, or a pcall anywhere in the file, would mean a declaration executes.
  assert(not text:find("run%s*%("), "src/spec.lua calls a `run`")
  assert(not text:find("%f[%w]pcall%f[%W]"), "src/spec.lua pcalls something")
  assert(not text:find("%f[%w]xpcall%f[%W]"), "src/spec.lua xpcalls something")

  -- Run rather than read: a hostile declaration file, loaded. Its tool body, its hook
  -- and its argument descriptions all try to fire, and none of them may.
  local fired = {}
  local text_of_file = [[
    agent.name "hostile"
    agent.model "test:scripted"
    agent.tool "wipe" {
      about = "Delete everything",
      args  = { path = agent.string "what to delete" },
      run   = function () fired[#fired + 1] = "body"; return "gone" end,
    }
    agent.on "start" (function () fired[#fired + 1] = "hook" end)
  ]]
  local world = { read = function () return text_of_file end }
  local a, err = cli.load("hostile.lua", world)
  assert(a ~= nil, "the declaration did not load: " .. tostring(err and err.message))
  assert(#fired == 0, "loading the file ran " .. table.concat(fired, ", "))
  assert(a.tools.wipe ~= nil, "the tool was not declared")
  assert(type(a.tools.wipe.run) == "function", "the body was not kept")
  assert(#a.hooks.start == 1, "the hook was not kept")

  -- The same file could not have reached the world even if it had tried at the top
  -- level: the sandbox is what makes "safe on an untrusted file" true.
  local blocked = cli.load("reach.lua", { read = function ()
    return 'agent.name "x"\nlocal f = io.open("/etc/passwd")\n'
  end })
  assert(blocked == nil, "a declaration reached io")
end)

-- ===========================================================================
-- Rule 3. A tool is a name, a why, typed arguments and a body.
--
--   Nothing else is required and nothing else is read. A tool with no `about` is
--   refused at declaration, because a tool the model cannot understand is a tool it
--   will misuse.

rule(3, "a_tool_states_what_it_is_for", function ()
  local a = an_agent()

  -- No `about`: refused, and the refusal says why rather than naming a field.
  local ok, why = pcall(spec.add_tool, a, "nameless", { run = function () end })
  assert(not ok, "a tool with no `about` was accepted")
  assert(has(why, "about"), tostring(why))
  assert(has(why, "misuse"), "the refusal does not say why it matters: " .. tostring(why))
  assert(a.tools.nameless == nil, "the refused tool was declared anyway")

  -- An empty `about` is no `about`.
  assert(not pcall(spec.add_tool, a, "empty", { about = "", run = function () end }),
    "an empty `about` was accepted")

  -- No body: refused too. A name and a why with nothing behind them is not a tool.
  assert(not pcall(spec.add_tool, a, "bodiless", { about = "Do a thing" }),
    "a tool with no body was accepted")

  -- Those four things and no more. `mood` is not read, not stored, and not refused --
  -- the rule is that nothing else is READ, so an extra key simply does not exist.
  spec.add_tool(a, "grep", {
    about = "Search the workspace",
    args  = { pattern = spec.types.string "what to look for",
              fixed   = spec.types.boolean_opt "literal text" },
    run   = function () return "no hits" end,
    ask   = false,
    mood  = "cheerful",
  })
  local t = a.tools.grep
  assert(t.mood == nil, "a fifth key was read")
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  assert(table.concat(keys, ",") == "about,arg_order,args,ask,name,run",
    "a tool is more than a name, a why, typed arguments and a body: " .. table.concat(keys, ","))
  assert(t.name == "grep" and t.about == "Search the workspace")
  assert(type(t.run) == "function" and t.ask == false)

  -- And the why reaches the model, with every argument's type and description.
  local schema
  for _, entry in ipairs(spec.schema(a)) do
    if entry.name == "grep" then schema = entry end
  end
  assert(schema ~= nil, "the tool is not in the schema the model is sent")
  assert(schema.about == "Search the workspace")
  assert(#schema.args == 2, tostring(#schema.args))
  for i = 1, #schema.args do
    local arg = schema.args[i]
    assert(type(arg.kind) == "string" and arg.kind ~= "")
    assert(type(arg.description) == "string" and arg.description ~= "",
      "the argument " .. tostring(arg.name) .. " reaches the model with no description")
  end
end)

-- ===========================================================================
-- Rule 4. Permission is the harness's, never the tool's.
--
--   `ask = true` means the port is asked before the body runs, and a refusal is a
--   normal result the model sees -- not an error and not a silent skip. A tool body
--   cannot approve itself.

rule(4, "a_refused_call_is_a_result_the_model_reads", function ()
  local ran, saw = 0, {}
  local a = an_agent()
  spec.add_tool(a, "deploy", {
    about = "Ship it",
    args  = { where = spec.types.string "which environment" },
    ask   = true,
    run   = function (c)
      ran = ran + 1
      saw.context = c
      return "shipped"
    end,
  })

  local step = 0
  local asked = {}
  local port = {
    model = { call = function (request)
      step = step + 1
      if step == 1 then
        return { calls = { { id = "d1", tool = "deploy", args = { where = "prod" } } } }
      end
      -- What the model was told about the refused call, on the step after it.
      for i = 1, #request.messages do
        local m = request.messages[i]
        if m.role == "tool" then saw.message = m end
      end
      return { text = "understood", stop = "done" }
    end },
    ask = { request = function (q)
      asked[#asked + 1] = q
      return { allow = false, why = "not on a Friday" }
    end },
  }

  local result = turn.run(a, "ship to prod", port)

  -- The gate was asked, before the body, about this call and its arguments.
  assert(#asked == 1, "the gate was asked " .. #asked .. " times")
  assert(asked[1].tool == "deploy", tostring(asked[1].tool))
  assert(asked[1].args.where == "prod", "the gate was not told what it was approving")
  assert(ran == 0, "the body ran despite the refusal")

  -- The refusal is a result, not an error and not a silent skip.
  assert(result.stop == "answered", "a refusal ended the run: " .. tostring(result.stop))
  assert(result.err == nil, "a refusal was reported as an error")
  local rec = result.calls[1]
  assert(rec ~= nil, "the refused call was not recorded")
  assert(rec.asked == true and rec.refused == true, "the record does not say it was refused")
  assert(rec.ok == false, "a call that never ran was recorded as a success")
  assert(has(rec.output, "refused") and has(rec.output, "not on a Friday"), tostring(rec.output))

  -- And the model read it: it arrived as a tool message on the following request.
  assert(saw.message ~= nil, "the model was never told")
  assert(saw.message.tool == "deploy" and has(saw.message.text, "not on a Friday"),
    "the model was told something other than the refusal")

  -- A body cannot approve itself: the gate and the model are withheld from the
  -- context a tool is handed, so there is nothing there to call.
  local allowed = {
    model = port.model,
    ask   = { request = function () return { allow = true } end },
  }
  step = 0
  turn.run(a, "ship to prod", allowed)
  assert(ran == 1, "the body did not run when the gate allowed it")
  assert(saw.context ~= nil)
  assert(saw.context.ask == nil, "a tool body can reach the approval gate")
  assert(saw.context.model == nil, "a tool body can reach the model")
end)

-- ===========================================================================
-- Rule 5. The loop always ends.
--
--   Every run has a step budget. Reaching it ends the turn with a stated reason,
--   never a hang.

rule(5, "a_runaway_loop_stops_and_says_so", function ()
  local a = an_agent()
  spec.set_budget(a, 4)
  local ran = 0
  spec.add_tool(a, "again", {
    about = "Do it once more",
    run   = function () ran = ran + 1; return "again" end,
  })

  -- A model that never answers. Without a budget this call does not return.
  local calls = 0
  local port = { model = { call = function ()
    calls = calls + 1
    assert(calls < 1000, "the loop did not end")
    return { calls = { { tool = "again" } } }
  end } }

  local result = turn.run(a, "go", port)

  assert(result.stop == "budget", tostring(result.stop))
  assert(result.steps == 4, "the run spent " .. result.steps .. " steps of a budget of 4")
  assert(calls == 4, "the model was called " .. calls .. " times for a budget of 4")
  assert(ran == 4, "the tool ran " .. ran .. " times")
  assert(has(result.reason, "budget") and has(result.reason, "4"),
    "the stop does not state its reason: " .. tostring(result.reason))
  assert(result.answer == nil, "a run that never answered reported an answer")

  -- The caller's budget overrides the declaration's, and still ends.
  local shorter = turn.run(a, "go", port, { budget = 1 })
  assert(shorter.stop == "budget" and shorter.steps == 1, tostring(shorter.steps))

  -- Nesting is bounded too, or a tool that starts a run is a loop with extra steps.
  local nested = turn.run(a, "go", port, { depth = 9, max_depth = 3 })
  assert(nested.stop == "error", tostring(nested.stop))
  assert(has(nested.reason, "deep"), tostring(nested.reason))

  -- The four stops are the four stops, and the list cannot be grown.
  local stops = turn.stops
  assert(#stops == 4 and table.concat(stops, ",") == "answered,budget,refused,error",
    table.concat(stops, ","))
  assert(not pcall(function () stops[5] = "hung" end), "a fifth stop was accepted")
end)

-- Rule 6. A feature states behaviour and cannot cause it.
--
--   A Given line may only write the world; a Then line gets a read-only world and may
--   only read the result; there is no `when` slot a workspace can declare.

rule(6, "a_feature_cannot_cause_what_it_states", function ()
  local behaviour = require "behaviour"
  local gherkin   = require "gherkin"

  -- (a) A then body's world is read-only, all the way down, and the refusal names the
  -- path. A scenario that could act on what it observes is a test that tested itself.
  local a = an_agent()
  spec.add_tool(a, "noop", { about = "does nothing", run = function () return "ok" end })
  behaviour.declare(spec, a, "the world is quietly changed", {
    then_ = function (c) c.world.fs.files["sneak"] = "gotcha" end,
  })
  local escaped = nil
  behaviour.declare(spec, a, "the world is quietly replaced", {
    then_ = function (c)
      c.world.fs = nil                       -- lands on a copy about to be discarded
      c.world.nothing_here = "x"             -- a key the world lacks: raises by name
    end,
  })
  behaviour.declare(spec, a, "the world is quietly called", {
    then_ = function (c) c.world.fs.write("sneak", "gotcha") end,
  })
  behaviour.declare(spec, a, "the world is looked at twice", {
    then_ = function (c)
      -- Isolation, from inside: what an earlier Then line did to its copy is not here.
      escaped = c.world.fs ~= nil and c.world.nothing_here == nil
    end,
  })

  local drivers = cli.drivers(a, function (prompt, port, opts)
    return turn.run(a, prompt, port, opts)
  end)

  local function outcome(line)
    local pickles = assert(gherkin.pickle(
      "Feature: f\n  Scenario: s\n    Given the model answers \"x\"\n"
      .. "    When the agent is asked \"go\"\n    Then " .. line .. "\n"))
    local report = behaviour.run(pickles, drivers)
    local s = report.scenarios[1]
    local why = ""
    for i = 1, #s.steps do why = why .. tostring(s.steps[i].why or "") end
    return s.outcome, why
  end

  local got, why = outcome("the world is quietly changed")
  assert(got == "broken", "a Then line wrote a nested table and was not stopped: " .. got)
  assert(has(why, "may only read"), why)
  assert(has(why, "world.fs.files.sneak"), "the refusal does not name what was written: " .. why)

  -- Writing a key the world does not have raises and names it.
  got, why = outcome("the world is quietly replaced")
  assert(got == "broken", "a Then line wrote a new key and was not stopped: " .. got)
  assert(has(why, "world.nothing_here"), why)

  -- And a Then line cannot CALL into the world either: the ports are stubs that raise.
  got, why = outcome("the world is quietly called")
  assert(got == "broken", "a Then line called a port and was not stopped: " .. got)
  assert(has(why, "cannot be called"), why)

  -- The guarantee under all of it is isolation: each Then line gets a fresh copy, so
  -- nothing an earlier one did to its own is visible to a later one, whatever Lua's
  -- __newindex does or does not fire on.
  local pickles_iso = assert(gherkin.pickle(
    "Feature: f\n  Scenario: s\n    Given the model answers \"x\"\n"
    .. "    When the agent is asked \"go\"\n"
    .. "    Then the world is looked at twice\n"))
  behaviour.run(pickles_iso, cli.drivers(a, function (prompt, port, opts)
    return turn.run(a, prompt, port, opts)
  end))
  assert(escaped == true, "a Then line's world is not a fresh copy")

  -- (b) A given body cannot see a result, so it cannot assert and then act on it.
  local saw = {}
  behaviour.declare(spec, a, "the given phase looks for a result", {
    given = function (c) saw.result = c.result; saw.checked = c.checked end,
  })
  local pickles = assert(gherkin.pickle(
    "Feature: f\n  Scenario: s\n    Given the given phase looks for a result\n"
    .. "    And the model answers \"x\"\n    When the agent is asked \"go\"\n"
    .. "    Then it stops with answered\n"))
  -- Rebuilt, because the step above was declared after the first drivers table was
  -- taken and a drivers table is a snapshot of the declaration.
  local report = behaviour.run(pickles, cli.drivers(a, function (prompt, port, opts)
    return turn.run(a, prompt, port, opts)
  end))
  local ran = report.scenarios[1]
  assert(ran.outcome == "passed", "the scenario did not run: " .. ran.outcome
         .. " " .. tostring(ran.steps[1] and ran.steps[1].why))
  assert(saw.result == nil, "a Given body can see a result")
  assert(saw.checked == nil, "a Given body can see a check")

  -- (c) There is no `when` a workspace can declare. Not discouraged: unrepresentable,
  -- and asking for one says why.
  local ok, message = pcall(behaviour.declare, spec, spec.new(), "x", { when = print })
  assert(not ok and has(tostring(message), "no such slot"), tostring(message))
  ok, message = pcall(behaviour.declare, spec, spec.new(), "x", { when_ = print })
  assert(not ok, "a `when_` slot was accepted")

  -- (d) And the three ways a run starts are the harness's, all three of them.
  local whens = 0
  local steps = behaviour.steps()
  for i = 1, #steps do if steps[i].phase == "when" then whens = whens + 1 end end
  assert(whens == 3, whens .. " when expressions, and the harness has three")
end)

-- Rule 7. The reader knows no harness.
--
--   src/gherkin.lua may not name an agent, a tool, a port, a world, a result or a run.
--   Text in, pickles out. It is rule 1 pointing the other way, and it is what lets the
--   reader be measured against four hundred real feature files with no harness present.

rule(7, "the_reader_knows_no_harness", function ()
  local text = source("src/gherkin.lua")

  -- Not the words in prose -- the words as code would use them. A comment may explain
  -- what a harness is; a line of code may not reach one.
  local banned = {
    "%f[%w]require%f[%W]", "%f[%w]io%.", "%f[%w]os%.", "dofile", "loadstring",
    "%f[%w]agent%.", "%f[%w]turn%.", "%f[%w]port%.", "%f[%w]spec%.", "%f[%w]double%.",
    "%f[%w]behaviour%.", "%f[%w]world%.", "%f[%w]result%.",
  }
  for i = 1, #banned do
    local at = text:find(banned[i])
    assert(at == nil, "src/gherkin.lua names " .. banned[i] .. " at byte " .. tostring(at))
  end

  -- And it really does load with nothing else present: a fresh state, this one file,
  -- no package.path at all. If it reached for anything, this raises.
  local chunk = assert(load(text, "@gherkin", "t", {
    string = string, table = table, math = math, type = type, tonumber = tonumber,
    tostring = tostring, pairs = pairs, ipairs = ipairs, error = error, setmetatable = setmetatable,
    select = select, next = next, assert = assert, rawget = rawget,
  }))
  local reader = chunk()
  assert(type(reader.pickle) == "function", "the reader has no pickle")
  local pickles = assert(reader.pickle("Feature: a\n  Scenario: b\n    Given c\n"))
  assert(#pickles == 1 and pickles[1].steps[1].text == "c")
end)

-- Rule 8. No span attribute carries a payload.
--
--   A trace carries names, counts, sizes, durations, decisions and codes -- never a
--   prompt, a model's text, a file's contents, a tool's arguments or its output. A trace
--   exporter's whole job is to send what it is given somewhere else, and an agent's
--   arguments are the most sensitive bytes in the process.

rule(8, "a_span_carries_no_payload", function ()
  local trace  = require "trace"
  local double = require "double"

  -- A run that reaches every span this tree opens, and whose prompt, tool arguments,
  -- file contents and model text are all distinctive strings. If any of them appears in
  -- any attribute of any span, this fails.
  local SECRET_PROMPT  = "PAYLOAD-PROMPT-do-not-export"
  local SECRET_ARG     = "PAYLOAD-ARG-do-not-export"
  local SECRET_FILE    = "PAYLOAD-FILE-do-not-export"
  local SECRET_ANSWER  = "PAYLOAD-ANSWER-do-not-export"
  local SECRET_OUTPUT  = "PAYLOAD-OUTPUT-do-not-export"

  local a = an_agent()
  spec.add_tool(a, "read", {
    about = "Read the file",
    args = { path = spec.types.string("the path") },
    run = function (c) return SECRET_OUTPUT .. " " .. tostring(c.fs.read(c.args.path)) end,
  })
  spec.add_tool(a, "file", {
    about = "File it, once a human agrees",
    ask = true,
    args = { text = spec.types.string("what to file") },
    run = function () return "filed" end,
  })

  local world = double.world {
    clock = { at = 1757462400 },
    fs = { ["notes.md"] = SECRET_FILE },
    ask = { file = false },                       -- refused, so the gate span is reached
    model = {
      { tool = "read", args = { path = "notes.md" } },
      { tool = "file", args = { text = SECRET_ARG } },
      { tool = "nope", args = {} },               -- no such tool
      { text = SECRET_ANSWER },
    },
  }
  local result = turn.run(a, SECRET_PROMPT, world)

  assert(type(result.spans) == "table" and #result.spans > 0, "the run recorded no spans")

  local secrets = { SECRET_PROMPT, SECRET_ARG, SECRET_FILE, SECRET_ANSWER, SECRET_OUTPUT }
  local vocabulary = trace.attributes()
  local seen = {}

  for i = 1, #result.spans do
    local span = result.spans[i]
    assert(type(span.name) == "string" and span.name ~= "", "a span with no name")
    assert(type(span.at) == "number" and type(span.ms) == "number", span.name .. " has no timing")
    assert(span.attrs["malleable.unclosed"] == nil,
           "the span " .. span.name .. " was never closed")

    for _, secret in ipairs(secrets) do
      assert(not has(span.name, secret), "a span NAME carries a payload: " .. span.name)
    end

    for key, value in pairs(span.attrs) do
      seen[key] = true
      assert(vocabulary[key], "the attribute " .. tostring(key) .. " is not in the vocabulary")
      local fine, why = trace.allowed(key, value)
      assert(fine, tostring(why))
      -- Names, counts, durations and terms. Nothing long enough to be a payload.
      if type(value) == "string" then
        assert(#value <= 200, "the attribute " .. key .. " carries " .. #value .. " characters")
        for _, secret in ipairs(secrets) do
          assert(not has(value, secret),
                 "the attribute " .. key .. " carries a payload: " .. value)
        end
      end
    end
  end

  -- And the whole rendered document, which is the thing that actually leaves the machine.
  local document = trace.otlp(result.spans, { service = "test" })
  for _, secret in ipairs(secrets) do
    assert(not has(document, secret), "the rendered trace carries " .. secret)
  end

  -- The run really did reach the spans this rule is about, rather than passing because
  -- nothing happened.
  assert(seen["malleable.gate.answer"], "the gate span was never reached")
  assert(seen["gen_ai.tool.name"], "no tool span was recorded")
  assert(seen["malleable.stop"], "the run span was never closed")
end)

-- ===========================================================================

local passed, failed = 0, 0
for _, entry in ipairs(ORDER) do
  local ok, err = pcall(T[entry.name])
  if ok then
    passed = passed + 1
    print(string.format("ok    rule %d  %s", entry.n, entry.name))
  else
    failed = failed + 1
    print(string.format("FAIL  rule %d  %s", entry.n, entry.name))
    print("        " .. tostring(err):gsub("\n", "\n        "))
  end
end

print("")
if failed == 0 then
  print(string.format("%d of the eight rules hold", passed))
  os.exit(0)
end
print(string.format("%d hold, %d broken", passed, failed))
os.exit(1)
