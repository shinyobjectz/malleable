-- example/reviewer.lua, driven end to end against the doubles.
--
-- The example is the tree's one worked declaration, so it is also the one place every
-- seam is crossed at once: the prefix, the filesystem toolkit, the shell toolkit, a
-- hand-written tool with `ask`, a hook, and the turn loop over a scripted world. If
-- the twelve subsystems stop agreeing, this file is where it shows.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local agent = require "agent"

local T = {}

-- Loading the example declares into the module's own prefix, so every test here starts
-- by clearing it and loading the file again. `dofile`, not `require`: a required file
-- is loaded once and these tests want it fresh.
local function declared()
  agent.reset()
  dofile(here .. "/../example/reviewer.lua")
  return agent.spec()
end

local function workspace()
  return {
    ["src/turn.lua"]       = "-- the turn loop\nlocal turn = {}\nreturn turn\n",
    ["test/turn_test.lua"] = "local T = {}\nreturn T\n",
    ["README.md"]          = "# a workspace\n",
  }
end

-- The script the reviewer's model follows in the happy case.
local function script()
  return {
    { tool = "list",    args = { path = "src" } },
    { tool = "read",    args = { path = "src/turn.lua" } },
    { tool = "shell",   args = { command = "lua run-tests.lua" } },
    { tool = "verdict", args = { summary = "The loop is small and the suite is green.", block = false } },
    { text = "I read the file, ran the suite, and filed an approval." },
  }
end

local function world(ask)
  return agent.world {
    fs    = workspace(),
    sh    = { ["sh -c lua run-tests.lua"] = { code = 0, out = "602 passed\n" } },
    ask   = ask,
    model = script(),
  }
end

local function has(text, needle)
  return type(text) == "string" and text:find(needle, 1, true) ~= nil
end

local function call_named(result, name)
  for i = 1, #result.calls do
    if result.calls[i].tool == name then return result.calls[i] end
  end
end

-- ---------------------------------------------------------------------------

function T.the_example_declares_what_it_says_it_does()
  local a = declared()
  assert(a.name == "reviewer", tostring(a.name))
  assert(type(a.model) == "string" and a.model ~= "")
  assert(#agent.problems() == 0, table.concat(agent.problems(), "; "))

  local want = { "read", "write", "edit", "list", "glob", "search", "shell", "verdict" }
  for i = 1, #want do
    assert(a.tools[want[i]], "the example declares no tool " .. want[i])
  end
end

function T.the_tools_that_ask_are_the_ones_that_should()
  local a = declared()
  assert(a.tools.verdict.ask == true, "the verdict is put to a human")
  assert(a.tools.shell.ask == true, "the shell asks")
  assert(a.tools.read.ask == false, "reading does not ask")
  assert(a.tools.write.ask == true, "writing asks")
end

-- Rule 2, in the example: loading it declares and runs nothing.
function T.loading_the_example_runs_nothing()
  local w = agent.world { fs = workspace() }
  declared()
  assert(w.fs.wrote[1] == nil, "loading the example wrote a file")
  assert(w.sh.ran[1] == nil, "loading the example ran a command")
end

function T.it_runs_end_to_end_against_the_doubles()
  declared()
  local w = world { verdict = true, shell = true }
  local r = agent.run("Review the change to src/turn.lua.", w)

  assert(r.stop == "answered", tostring(r.stop) .. ": " .. tostring(r.reason))
  assert(r.steps == 5, tostring(r.steps))
  assert(has(r.answer, "filed an approval"), tostring(r.answer))

  -- Every call landed, and every one answered with text the model can read.
  assert(#r.calls == 4, tostring(#r.calls))
  for i = 1, #r.calls do
    local c = r.calls[i]
    assert(c.ok, c.tool .. " failed: " .. tostring(c.output))
    assert(type(c.output) == "string" and c.output ~= "")
    assert(not has(c.output, "not text"), c.tool .. " answered with a table: " .. c.output)
  end

  assert(has(call_named(r, "read").output, "local turn = {}"), "the read did not reach the model")
  assert(has(call_named(r, "list").output, "turn.lua"), "the listing did not reach the model")
  assert(has(call_named(r, "shell").output, "602 passed"), "the command output did not reach the model")

  assert(w.fs.files["REVIEW.md"] ~= nil, "the verdict was not filed")
  assert(has(w.fs.files["REVIEW.md"], "APPROVED"))
end

-- Rule 4, in the example: the human says no, and the run carries on with the refusal
-- as an ordinary result.
function T.a_refused_verdict_is_a_result_and_not_an_end()
  declared()
  local w = world { verdict = false, shell = true }
  local r = agent.run("Review the change to src/turn.lua.", w)

  assert(r.stop == "answered", tostring(r.stop))
  local v = call_named(r, "verdict")
  assert(v.refused == true, "the refusal was not recorded")
  assert(v.ok == false, "a refused call did not run, so it did not succeed")
  assert(has(v.output, "refused"), tostring(v.output))
  assert(w.fs.files["REVIEW.md"] == nil, "a refused verdict was filed anyway")

  -- The model saw it: the refusal is in the transcript as a tool result.
  local seen = false
  for i = 1, #r.transcript do
    local m = r.transcript[i]
    if m.role == "tool" and m.tool == "verdict" and has(m.text, "refused") then seen = true end
  end
  assert(seen, "the refusal never reached the transcript the model reads")
end

-- The workspace is open for reading only, and the tools say so rather than write.
function T.the_reviewer_cannot_edit_what_it_judges()
  declared()
  local w = agent.world {
    fs    = workspace(),
    ask   = { write = true },
    model = {
      { tool = "write", args = { path = "src/turn.lua", text = "gone" } },
      { text = "I could not change it." },
    },
  }
  local r = agent.run("Fix it yourself.", w)
  local c = call_named(r, "write")
  assert(has(c.output, "reading only"), tostring(c.output))
  assert(w.fs.files["src/turn.lua"]:find("local turn", 1, true), "the file was changed")
end

return T
