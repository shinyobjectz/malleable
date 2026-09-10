# malleable

An agent harness you declare in Lua. You write what the agent is, what tools it has and
when it must ask permission; the harness runs the loop.

One prefix, `agent`, and nothing else to remember. No handle to thread through, no
builder to close, no `return` at the end of the file. The file *is* the declaration.

    local agent = require "agent"

    agent.name  "reviewer"
    agent.model "openrouter:inception/mercury-2.5"

    agent.tool "read" {
      about = "Read a file",
      args  = { path = agent.string "workspace-relative path" },
      run   = function (c) return c.fs.read(c.args.path) end,
    }

    local result = agent.run("what does src/turn.lua do?", port)

Native Lua, standard library only. No C modules, no LuaRocks, no network client of its
own. It targets Lua 5.4 and stays inside the subset LuaJIT 5.1 also accepts, so the same
tree runs embedded in a host through `mlua` and on the `luajit` on your path.

## Designed after Pi

Pi is the agent harness this is shaped by: an agent, its tools, a turn loop, an approval
gate, a session, a context budget. Those are the parts, and their arrangement is the good
idea worth keeping — a harness where the declaration is inert and the host owns every
capability is a harness you can reason about.

What is here is that architecture in Lua, at the size Lua wants: twelve subsystems, no C
modules, no network client, and a file that declares rather than runs. It is not a port
and does not try to be one — a full coding agent is a product, with a terminal interface,
a session store on disk, a scheduler holding threads, telemetry and a package manager, and
none of that is here. `agent.every` is not a scheduler: it states a beat and answers what
is due, holds no thread, and starts no run unless a host asks for one. A smaller honest
implementation is the point, not a shortfall.

`DESIGN.md` locks the decisions and is the file to read first.

## The five rules

`DESIGN.md` locks five architectural rules, and each one names a test in
`rules-test.lua` that fails the moment the rule stops holding.

1. **The core knows no vendor.** `src/turn.lua` may not name a provider, an HTTP
   library, a filesystem or a clock. It takes a port table and calls it.
2. **A declaration cannot run anything.** Loading an agent file is safe on an untrusted
   file; only `turn.run` executes.
3. **A tool is a name, a why, typed arguments and a body.** A tool with no `about` is
   refused at declaration.
4. **Permission is the harness's, never the tool's.** A refusal is a normal result the
   model reads, not an error and not a silent skip.
5. **The loop always ends.** Every run has a step budget, and reaching it ends the turn
   with a stated reason.

## A worked example

`example/reviewer.lua`, complete. It reads a workspace, runs a command, and files a
verdict that a human has to approve first. Run it — `lua example/reviewer.lua` — and it
drives itself end to end against the doubles, with no network, no disk and no
subprocess.

    local agent = require "agent"

    agent.name  "reviewer"
    agent.model "openrouter:inception/mercury-2.5"
    agent.budget(12)

    agent.system [[
    You review a change in a Lua workspace. Read what you need, run the test suite, and
    then call verdict once: it is put to a human, and it is the only thing that leaves a
    mark.
    ]]

    -- read, write, edit, list, glob and search, over the port the run supplies.
    -- Read-only, so a reviewer cannot quietly fix what it was asked to judge.
    agent.files {
      root      = "",
      read_only = true,
      deny      = { ".git/**", "**/*.key" },
    }

    -- One command line at a time. This one asks before it runs, on its own account:
    -- a shell is the tool with the least idea of what it is about to do.
    agent.shell {
      root       = ".",
      about      = "Run one command in the workspace and report its output and exit code.",
      timeout_ms = 60000,
    }

    -- The one thing this agent writes. `ask = true` puts it to the port before the
    -- body runs, and a refusal comes back to the model as an ordinary result.
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
        if not ok then return nil, why end
        c.note("the verdict was filed")
        return "filed to REVIEW.md: " .. (held and "blocked" or "approved")
      end,
    }

    local refused = {}
    agent.on "result" (function (e)
      if e.refused then refused[#refused + 1] = e.tool end
    end)

And the world it runs against. In a test that is `agent.world`, the in-memory doubles; in
production it is the same six ports wired to a real disk, a real subprocess and a real
model.

    local world = agent.world {
      fs    = { ["src/turn.lua"] = "-- the turn loop\nlocal turn = {}\nreturn turn\n" },
      sh    = { ["sh -c lua run-tests.lua"] = { code = 0, out = "608 passed\n" } },
      ask   = { verdict = true, shell = true },       -- the human at the gate
      model = {                                        -- what the model says, in order
        { tool = "read",    args = { path = "src/turn.lua" } },
        { tool = "shell",   args = { command = "lua run-tests.lua" } },
        { tool = "verdict", args = { summary = "The loop is small and the suite is green." } },
        { text = "I read the file, ran the suite, and filed an approval." },
      },
    }

    local result = agent.run("Review the change to src/turn.lua.", world)
    print(result.stop, result.steps, result.answer)

`result` carries `stop` (one of `answered`, `budget`, `refused`, `error`), `reason`,
`answer`, `steps`, `transcript`, `calls` and `notes`.

## The surface

Everything hangs off `agent`.

| | |
| --- | --- |
| `agent.name` `agent.model` `agent.system` `agent.budget` | what the agent is |
| `agent.trust` `agent.allow` `agent.deny` | its standing permission policy |
| `agent.tool "x" { ... }` `agent.on "event" (fn)` | a tool, a hook |
| `agent.skill "x" { ... }` `agent.every "x" { ... }` `agent.uses "x" { ... }` | a procedure a person wrote, a beat, a server |
| `agent.string` `agent.number` `agent.boolean` `agent.table` `agent.list` (and each with `_opt`) | argument types |
| `agent.files` `agent.shell` `agent.plan` `agent.skills` `agent.delegate` | the toolkits: filesystem, shell, a plan, the skill reader, a child agent |
| `agent.tick` `agent.due` `agent.connect` | run what the clock is owed; look first; reach the declared servers |
| `agent.run` `agent.check` `agent.schema` `agent.problems` `agent.spec` | running it, and looking at it first |
| `agent.gate` `agent.bind` `agent.world` | an approval gate, the port it binds into, the doubles |
| `agent.new` `agent.reset` | a second agent in one process; start this one over |

The hooks are `start`, `step`, `call`, `result` and `stop`. A hook observes a run and
cannot change one; anything it raises becomes a note on the result. A `call` hook may
**refuse** a call — `return { allow = false, why = "…" }`, or `{ stop = "…" }` to end the
run — because a veto removes a call rather than rewriting one. Anything else it returns
is reported as a note and not obeyed.

The three later seams are declarations too, and each reaches the world through an
optional port with a double: a **skill** is a procedure the workspace keeps, briefed by
name and read only when the model asks (`skills`); a **beat** is a run the clock starts,
deduped by a record that survives a restart (`ledger`); a **server** is a process whose
tools become ordinary tools before the model sees a schema (`mcp`).

## Two ways to load a declaration, and the one line between them

As a library, the file requires the prefix into existence:

    local agent = require "agent"
    agent.name "hello"
    ...

Under the runner, `bin/malleable.lua`, it does not — and cannot. The runner compiles a
declaration file in a sandbox where `agent` is the only name that exists: no `require`,
no `io`, no `os`, no `load`, no globals of its own. That is what makes rule 2's "safe on
an untrusted file" mean anything, so a file written for the runner drops the first line
and starts at `agent.name`:

    -- hello.lua
    agent.name "hello"
    agent.model "test:scripted"
    agent.tool "greet" {
      about = "Say hello to someone",
      args  = { who = agent.string "their name" },
      run   = function (c) return "hello, " .. c.args.who end,
    }

    $ lua bin/malleable.lua --dry-run --reply 'hello, world' hello.lua "say hi"

`--dry-run` is the only door to the doubles; without it the runner asks the host for
real ports and refuses to start if it has none.

## The parts

| | |
| --- | --- |
| `src/spec.lua` | the declaration surface: builds a table, runs nothing |
| `src/turn.lua` | the turn loop, the budget, the four stops |
| `src/port.lua` | the six capability ports, as a contract |
| `src/double.lua` | all six, in memory, deterministic |
| `src/approval.lua` | the gate: policy, trust, memory of an answer |
| `src/tools_fs.lua` | read, write, edit, list, glob, search |
| `src/tools_shell.lua` | one command line, with a timeout and a cap |
| `src/work.lua` | a plan, and a checkpoint that can be undone |
| `src/subagent.lua` | a tool that runs another declared agent |
| `src/session.lua` | the transcript, its codec and its store |
| `src/compaction.lua` | the context budget, and what to drop first |
| `src/provider.lua` | a model port over a real API, transport supplied |
| `src/config.lua` | settings, profiles and secrets |
| `src/cli.lua` | the runner, with the world as an argument |
| `src/skills.lua` | procedures the workspace keeps, briefed and read on request |
| `src/schedule.lua` | the beat, and the ledger that keeps it from firing twice |
| `src/mcp.lua` | tools that live in another process, made into tools that do not |
| `src/interpret.lua` | the forcing function for reading marks |

## Running the tests

    lua run-tests.lua          # every test/*_test.lua
    lua rules-test.lua         # the five rules of DESIGN.md
    lua example/reviewer.lua   # the worked example, end to end
    lua example/systems/02-a-beat-and-a-procedure.lua   # a beat, a skill, a ledger
    lua example/systems/03-borrowed-tools.lua           # servers, and a hook that says no

`run-tests.lua` discovers every `test/*_test.lua`, calls each named function on the table
it returns, prints a line per test and a tally, and exits non-zero on any failure. Pass a
fragment of a filename to run one file: `lua run-tests.lua turn`.

No test touches the network, the disk (beyond reading the tree's own source), a
subprocess or a real clock. Both suites pass under `lua` and under `luajit`.

## What is not here

### Embedding it

The tree touches nothing — no `io`, no `os`, no search path — so a host fills
`package.preload` and hands over tables of functions. `app/src-tauri/crates/ta-harness`
in this repo is a worked example: 21 modules compiled in with `include_str!`, the three
seams over a real workspace, and the model left to the host because rule 1 says the loop
names no vendor.

Two things an embedded interpreter must do that a `lua` on a path does for free:

* **`agent.lua` finds its own `src/` with `debug.getinfo` when it can.** That is guarded,
  so a host with no `debug` and no directory loads the prefix anyway.
* **`cli.load` bounds a declaration with `debug.sethook`.** A host that withholds `debug`
  — which it should — must enforce that bound itself, or a declaration that never returns
  hangs the host. `cli.load` says so in its third return value rather than pretending.

No TUI, no telemetry, no package manager, no daemon. There is no scheduler either:
`agent.every` states a beat and `agent.tick` runs what is due, but nothing here has a
thread, and no run starts unless a host asks for one. The harness is the loop, the tools
and the gate; a host supplies the world and decides what to do with the result.
