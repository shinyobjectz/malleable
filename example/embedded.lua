-- An agent inside its own world. No host, no network, no disk, no clock, no subprocess.
--
--     lua example/embedded.lua
--
-- What this file demonstrates is the claim `bin/malleable.lua` makes true by being twenty
-- lines long: the harness is a pure function of its ports, not one of its modules names
-- `io` or `os`, and so it runs wherever a Lua does. The thing that was missing was never
-- portability -- it was a WORLD to hand it that did not come from outside. `agent.sandbox`
-- is that world: a shell of eighteen commands over a filesystem in memory, a frozen clock,
-- a gate, and a log.
--
-- Nothing below is scripted except what the MODEL says. The commands are really run: the
-- file the agent writes is a file, and the grep that finds it really searched.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. package.path

local agent = require "agent"

agent.name  "keeper"
agent.model "sandbox:scripted"
agent.budget(8)

agent.system [[
You keep a small workspace tidy. Look before you act, and say what you found.
]]

-- The shell is the only tool it has, and it is a real one.
agent.shell {
  root  = ".",
  about = "Run one command line in the workspace and report its output and exit code.",
}

local function is_main()
  local source = debug.getinfo(1, "S").source:sub(2)
  local named = type(arg) == "table" and arg[0] or nil
  return type(named) == "string" and (named == source or source:sub(-#named) == named)
end

if is_main() then
  -- The whole world, in one call, with nothing from the host.
  local world = agent.sandbox {
    fs = {
      ["notes/monday.md"]  = "ship the reader\nfix the escape\n",
      ["notes/tuesday.md"] = "ship the reader\n",
      ["README.md"]        = "# a workspace\n",
    },
    -- The gate says yes to the shell, in writing. A sandbox refuses by default.
    ask = { shell = true },
    -- The one thing a sandbox cannot invent.
    model = {
      { tool = "shell", args = { command = "ls notes" } },
      { tool = "shell", args = { command = "grep -rn 'ship the reader' notes" } },
      { tool = "shell", args = { command = "cat notes/monday.md notes/tuesday.md | sort -u > notes/all.md" } },
      { tool = "shell", args = { command = "wc -l notes/all.md" } },
      { text = "Both days repeat 'ship the reader'; I folded them into notes/all.md, which is two lines." },
    },
  }

  local result = agent.run("Tidy the notes.", world)

  print("stop:   " .. tostring(result.stop))
  print("steps:  " .. tostring(result.steps) .. " of " .. tostring(result.budget))
  for _, call in ipairs(result.calls) do
    print(string.format("  %-6s %s", call.ok and "ok" or "--", (call.output:match("^[^\n]*") or "")))
  end
  print("answer: " .. tostring(result.answer))

  -- The file is really there, written by a command the shell really ran.
  print("\nnotes/all.md:")
  io.write(tostring(world.fs.files["notes/all.md"]))

  -- And what it DID, in terms, without the command lines going anywhere near the trace.
  print("\nwhat it did:")
  for _, span in ipairs(result.spans) do
    if span.attrs["malleable.act"] then
      print("  " .. span.name .. " -> " .. span.attrs["malleable.act"])
    end
  end
end
