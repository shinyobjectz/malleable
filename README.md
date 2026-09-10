# malleable

A framework for building agent systems behaviour first. An agent is two files: a Lua
declaration of what it **is**, and a Gherkin feature of what it **does** — written in the
language you would have used to ask a person, and executed as written.

    triage.lua        its name, its model, its tools, when it must ask permission
    triage.feature    its behaviour, as scenarios, which are also its test suite

The declaration builds a table and runs nothing. The feature builds the world out of its
`Given` lines, runs the agent against it, and judges the `Then` lines on what came back —
no network, no disk, no subprocess, no clock. A feature that passes is documentation that
was true this morning.

    lua bin/malleable.lua --verify triage.lua

## The declaration

You write what the agent is, what tools it has and when it must ask permission; the
harness runs the loop.

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

## Based on Pi

Pi's architecture, in Lua: an agent, its tools, a turn loop, an approval gate, a session,
a context budget. Those parts, at the size Lua wants — twelve subsystems, no C modules,
no network client, and a file that declares rather than runs.

Not a coding agent. A coding agent is a product — a session store on disk, a scheduler
holding threads, telemetry, a package manager — and none of that is here. What it does have
is a face: `console/` is a fantasy console where the carts are agents (`spec/console.md`).
`agent.every` is not a scheduler: it states a beat and answers what is due, holds no
thread, and starts no run unless a host asks. `DESIGN.md` locks the decisions and is the
file to read first.

## The eight rules

`DESIGN.md` locks eight architectural rules, and each one names a test in
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
6. **A feature states behaviour and cannot cause it.** A `Given` line may only write the
   world, a `Then` line gets a read-only world and may only read the result, and there is
   no `when` a workspace can declare.
7. **The reader knows no harness.** `src/gherkin.lua` is text in, pickles out. It may not
   name an agent, a tool, a port or a run.
8. **No span attribute carries a payload.** A trace carries names, counts, sizes, durations
   and decisions — never a prompt, a model's text, a file's contents or a tool's arguments.

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

## The behaviour

The same reviewer, said in the language somebody would have used to ask for it.
`example/reviewer.feature`:

    Feature: the reviewer reads before it judges, and asks before it files

      Background:
        Given the file "src/turn.lua" contains:
          """
          -- the turn loop
          local turn = {}
          return turn
          """
        And the command "lua run-tests.lua" answers 0 and:
          """
          608 passed
          """

      Scenario: it runs the suite and files an approval a human agreed to
        Given the human approves verdict
        And the model calls read with {"path": "src/turn.lua"}
        And the model calls shell with {"command": "lua run-tests.lua"}
        And the model calls verdict with {"summary": "The loop is small and the suite is green."}
        And the model answers "I read the file, ran the suite, and filed an approval."
        When the agent is asked "Review the change to src/turn.lua."
        Then it stops with answered
        And it calls read
        And the file "REVIEW.md" holds:
          """
          APPROVED

          The loop is small and the suite is green.
          """

      Scenario: a refusal at the gate is a result the model reads, not an error
        Given the human refuses verdict
        And the model calls verdict with {"summary": "ship it"}
        And the model answers "I was not allowed to file that."
        When the agent is asked "Review the change."
        Then the call to verdict is refused
        And it stops with answered
        And nothing is written

Thirty-three step expressions are built in and cover the harness itself — the six ports,
the model's script, the gate, the four stops, the calls, the notes, the budget — so a
declaration is verifiable with no glue code at all. `agent.steps()` lists them, and
`docs/STEPS.md` is the same list rendered.

They are the agent's nouns, never the harness's. There is no `the trace shows …` and no
`the span … says …`: a scenario written in those describes the harness rather than the
agent, and the eight that once did were retired the day the observer landed. What a person
actually wanted from them turned out to be two things the vocabulary had no word for, and
now has:

    Then it calls read before verdict
    And the call to shell fails

*"It reads before it judges"*, *"the verdict is always put to a human"* — that is the half
of an agent's behaviour that has never had a language, and it is checked in the same file
and the same words as everything else.

## Behaviour comes back out again

A run is read back out **as a scenario**, in the same vocabulary. Not a summary — a
complete, re-runnable one:

    Scenario: observed — Review the change to src/turn.lua.
      Given the file "src/turn.lua" contains:
        """
        -- the turn loop
        """
      And the human refuses verdict
      And the model calls read with {"path":"src/turn.lua"}
      And the model answers "I was not allowed to file that."
      When the agent is asked "Review the change to src/turn.lua."
      Then it stops with answered
      And it calls read with {"path":"src/turn.lua"}
      And the human is asked about verdict
      And the call to verdict is refused
      And nothing is written

So what an agent **did** and what it was **asked** to do are the same kind of object. Set
one against the other and you get an **agreement**: the lines that held, the lines that did
not, and — the part worth having — *the lines the run did that nobody stated*. A passing
test says an agent did what was asked. Only the agreement says what else it did on the way.

Observe every sample of an eval and collapse the ones that say the same thing, and you get
a **repertoire**:

    67%  it notes before it files  4/6
            2 distinct behaviours:
              4/6  it calls note with {"text":"x"}
              2/6  the human is asked about file
                     it calls file with {"text":"x"}

Not *4 of 6 passed*, but *in 4 it noted, in 2 it went straight to filing, and here is the
scenario those 2 ran* — each one re-runnable, without the model.

What the observer has no word for is a **gap in the vocabulary**, printed by every
`--verify` rather than hidden behind a flag, and never closed by reaching for a telemetry
noun. `spec/observe.md` is the contract.

## It brings its own world

`bin/malleable.lua` is twenty lines and is the only file here that touches the real world.
Not one of the modules names `io` or `os`. So the harness has always been a pure function
of its ports — what was missing was never portability, it was a **world** to hand it that
did not come from outside.

    local world = agent.sandbox { fs = { ["notes/a.md"] = "one\n" } }
    local result = agent.run("Tidy the notes.", world)

That world is complete: a filesystem in memory, a **shell of eighteen commands** that
really runs them (`ls`, `cat`, `grep -rn`, `find -name`, pipes, `&&`, `>` and `>>`), a
frozen clock, a gate that refuses until told otherwise, and a log. No host, no subprocess,
no network, no disk. `example/embedded.lua` is a whole agent inside one.

It is called `shell` and never `bash`: eighteen commands, and every refusal names all
eighteen. What that buys beyond isolation is **determinism** — the same script over the
same filesystem produces the same bytes every time, which is the only way two evals are
comparable and the only way a change can be attributed to a cause. `spec/shell.md`.

## It can be asked to improve, within a wall

A repertoire is kept as a **feature file** — one scenario per distinct behaviour, tagged
with how often it happened — so behavioural memory is re-runnable, readable, and diffable
by `git`. Diff two and you get what was **lost**, which is the thing a pass rate cannot
see: an agent can score better while quietly doing less.

That makes a small optimisation loop safe enough to run. It edits three fields — `system`,
`budget`, and a tool's `about` — and it is refused **by name** on everything else, `ask`
first among them, because an agent that can edit its own gate has no gate. It is scored
only on scenarios a person authored, in text it is given and never answers, and a proposal
is kept only if the rules still hold, nothing new fails, and no behaviour was lost.

`spec/change.md` is the ruling, and it was written before the code.

## The surface

Everything hangs off `agent`.

| | |
| --- | --- |
| `agent.name` `agent.model` `agent.system` `agent.budget` | what the agent is |
| `agent.trust` `agent.allow` `agent.deny` | its standing permission policy |
| `agent.tool "x" { ... }` `agent.on "event" (fn)` | a tool, a hook |
| `agent.step "the queue holds {string}" { ... }` | a step of your own, for a feature |
| `agent.skill "x" { ... }` `agent.every "x" { ... }` `agent.uses "x" { ... }` | a procedure a person wrote, a beat, a server |
| `agent.string` `agent.number` `agent.boolean` `agent.table` `agent.list` (and each with `_opt`) | argument types |
| `agent.files` `agent.shell` `agent.plan` `agent.skills` `agent.delegate` | the toolkits: filesystem, shell, a plan, the skill reader, a child agent |
| `agent.tick` `agent.due` `agent.connect` | run what the clock is owed; look first; reach the declared servers |
| `agent.run` `agent.check` `agent.schema` `agent.problems` `agent.spec` | running it, and looking at it first |
| `agent.verify` `agent.evaluate` `agent.check_feature` `agent.steps` | run a feature on the doubles; against a real model; check it without running; the vocabulary |
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
| `src/gherkin.lua` | a feature file, read: the subset, the expressions, the pickles |
| `src/behaviour.lua` | the thirty-six step expressions, and the runner over a declaration |
| `src/trace.lua` | the run's spans, rendered — to OTLP/JSON, or to a tree for a person |
| `src/observe.lua` | a run, read back out as a scenario: the agreement and the repertoire |
| `src/command.lua` | what a command line did, as a term, so the command itself never travels |
| `src/shell.lua` | a shell, in Lua, over a filesystem in Lua: eighteen commands, no host |
| `src/change.lua` | what a declaration may alter about itself, scored on a test it cannot edit |

## Running the tests

    lua run-tests.lua          # every test/*_test.lua
    lua rules-test.lua         # the eight rules of DESIGN.md
    lua spec/run.lua           # every spec/*.feature, against the tree itself
    lua example/reviewer.lua   # the worked example, end to end
    lua example/systems/02-a-beat-and-a-procedure.lua   # a beat, a skill, a ledger
    lua example/systems/03-borrowed-tools.lua           # servers, and a hook that says no
    lua bin/malleable.lua --verify hello.lua            # a declaration, from hello.feature
    lua bin/malleable.lua --steps                       # the built-in vocabulary

`run-tests.lua` discovers every `test/*_test.lua`, calls each named function on the table
it returns, prints a line per test and a tally, and exits non-zero on any failure. Pass a
fragment of a filename to run one file: `lua run-tests.lua turn`.

No test touches the network, the disk (beyond reading the tree's own source), a
subprocess or a real clock. Both suites pass under `lua` and under `luajit`.

`spec/run.lua` is the third suite, and it is the one that keeps this file honest. Each
`spec/*.md` argues for a decision; each `spec/*.feature` beside it states what the code
must actually do, in the harness's own step vocabulary (`spec/tree.lua`), run against the
tree itself. Three outcomes matter and they are not the same:

* **failed** -- a spec says something that is not true. A bug, and never allowed.
* **undefined** -- a spec is ahead of the code. Legal, counted in `spec/OWED`, and
  ratcheted: `test/spec_test.lua` fails if the number goes up.
* **passed** -- a promise you can run.

Prose cannot make that distinction, which is why the promises moved out of the `.md`
files. An audit of five of them found eight claims that were false, including a gate one
spec described in detail that the code did not have. Twenty-one of the twenty-four specs
still promise only in prose; the list in `spec/run.lua` names them, and it is the work
list.

## What is not here

### Embedding it

The tree touches nothing — no `io`, no `os`, no search path — so a host fills
`package.preload` and hands over tables of functions. `app/src-tauri/crates/ta-harness`
in this repo is a worked example: 28 modules compiled in with `include_str!`, the three
seams over a real workspace, and the model left to the host because rule 1 says the loop
names no vendor.

Two things an embedded interpreter must do that a `lua` on a path does for free:

* **`agent.lua` finds its own `src/` with `debug.getinfo` when it can.** That is guarded,
  so a host with no `debug` and no directory loads the prefix anyway.
* **`cli.load` bounds a declaration with `debug.sethook`.** A host that withholds `debug`
  — which it should — must enforce that bound itself, or a declaration that never returns
  hangs the host. `cli.load` says so in its third return value rather than pretending.

No telemetry, no package manager, no daemon. There is no scheduler either:
`agent.every` states a beat and `agent.tick` runs what is due, but nothing here has a
thread, and no run starts unless a host asks for one. The harness is the loop, the tools
and the gate; a host supplies the world and decides what to do with the result. The
console (`console/`, `spec/console.md`) is one such host, shipped in the tree.
