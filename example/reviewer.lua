-- A reviewer: reads the workspace, runs the test suite, and files a verdict.
--
-- The file is the declaration. There is one prefix, `agent`, and no return at the
-- end; requiring this file is what declares the agent.
--
-- Run it against the doubles, with no network, no disk and no subprocess:
--
--     lua example/reviewer.lua
--
-- This is the library form: the file requires the prefix into existence. A file written
-- for the runner (bin/malleable.lua) drops the three lines below and starts at agent.name --
-- there, `agent` is the only name the sandbox has, and `require` is not one of them.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local agent = require "agent"

-- ------------------------------------------------------------------ who it is

agent.name  "reviewer"
agent.model "openrouter:inception/mercury-2.5"
agent.budget(12)

agent.system [[
You review a change in a Lua workspace.

Read what you need, search for anything the change touches, and run the test suite
before you conclude anything. When you know what you think, call verdict once: it is
put to a human, and it is the only thing that leaves a mark. Then answer in one
paragraph.
]]

-- --------------------------------------------------------------- what it can do

-- read, list, glob and search. The workspace is open for reading only, so a reviewer
-- cannot quietly fix what it was asked to judge.
agent.files {
  root      = "",
  read_only = true,
  deny      = { ".git/**", "**/*.key" },
}

-- One command line at a time. tools_shell marks this one `ask` on its own, because a
-- shell is the tool with the least idea of what it is about to do.
agent.shell {
  root       = ".",
  about      = "Run one command in the workspace -- the test suite, a linter, git -- and report its output and exit code.",
  timeout_ms = 60000,
}

-- The one thing this agent writes. `ask = true` puts it to the port before the body
-- runs, and a refusal comes back to the model as an ordinary result: rule 4.
agent.tool "verdict" {
  about = "File the review. Call this once, when you have read the change and run the tests.",
  ask   = true,
  args  = {
    summary = agent.string      "the review, in one paragraph",
    block   = agent.boolean_opt "true to hold the change, false to let it through",
  },
  run = function (c)
    local held = c.args.block == true
    local text = (held and "BLOCKED\n\n" or "APPROVED\n\n") .. c.args.summary .. "\n"
    local ok, why = c.fs.write("REVIEW.md", text)
    if not ok then
      return nil, why
    end
    c.note("the verdict was filed: " .. (held and "blocked" or "approved"))
    return "filed to REVIEW.md: " .. (held and "blocked" or "approved")
  end,
}

-- ------------------------------------------------------------------- watching it

-- What the run refused, kept for the report at the bottom. A hook observes a run; it
-- cannot change one, and it must not be the thing that fails a call.
local refused = {}

agent.on "result" (function (e)
  if e.refused then refused[#refused + 1] = e.tool end
end)

-- ------------------------------------------------------- running it, against doubles
--
-- Only when this file is the script a person typed. Required from a test, or loaded by
-- the runner, it declares and stops there.

local function is_main()
  local source = debug.getinfo(1, "S").source:sub(2)
  local named = type(arg) == "table" and arg[0] or nil
  return type(named) == "string" and (named == source or source:sub(-#named) == named)
end

if is_main() then
  local world = agent.world {
    -- The workspace, in memory.
    fs = {
      ["src/turn.lua"]      = "-- the turn loop\nlocal turn = {}\nreturn turn\n",
      ["test/turn_test.lua"] = "local T = {}\nreturn T\n",
      ["README.md"]         = "# a workspace\n",
    },
    -- The one command this reviewer is allowed to discover it can run.
    sh = {
      ["sh -c lua run-tests.lua"] = { code = 0, out = "602 passed\n" },
    },
    -- The human at the gate: verdict is put to them, and they say yes.
    ask = { verdict = true, shell = true },
    -- What the model says, in order.
    model = {
      { tool = "list", args = { path = "src" } },
      { tool = "read", args = { path = "src/turn.lua" } },
      { tool = "shell", args = { command = "lua run-tests.lua" } },
      { tool = "verdict", args = { summary = "The loop is small and the suite is green.", block = false } },
      { text = "I read src/turn.lua, ran the suite, and filed an approval." },
    },
  }

  local result = agent.run("Review the change to src/turn.lua.", world)

  print("stop:   " .. tostring(result.stop))
  print("reason: " .. tostring(result.reason))
  print("steps:  " .. tostring(result.steps) .. " of " .. tostring(result.budget))
  for _, call in ipairs(result.calls) do
    local head = call.output:match("^[^\n]*") or ""
    print(string.format("  %-8s %-4s %s", call.tool, call.ok and "ok" or "--", head))
  end
  for _, note in ipairs(result.notes) do print("  note: " .. note) end
  for _, tool in ipairs(refused) do print("  refused: " .. tool) end
  print("answer: " .. tostring(result.answer))
  print("REVIEW.md:\n" .. tostring(world.fs.files["REVIEW.md"]))
end
