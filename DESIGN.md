# malleable — an agent harness you declare in Lua

Locked decisions. Change only with a written reason here.

## What this is

A coding-agent harness whose whole surface is a Lua declaration. You write what the
agent is, what tools it has and when to ask permission; the harness runs the loop.

    agent.name  "reviewer"
    agent.model "openrouter:inception/mercury-2.5"

    agent.tool "read" {
      about = "Read a file",
      args  = { path = agent.string "workspace-relative path" },
      run   = function (c) return c.fs.read(c.args.path) end,
    }

One prefix, `agent`, and nothing else to remember. No `m.` handle to thread through,
no builder to close, no `return` ceremony — the file *is* the declaration.

## What this is NOT

A port of Pi, or a coding agent at all. A coding agent is a product: a terminal
interface, a session store on disk, a scheduler holding threads, telemetry, a package
manager. None of that is here. (`agent.every` is not a scheduler: it states a beat and
answers what is due. Nothing holds a thread, and no run starts unless a host asks.) What
is taken from Pi is the ARCHITECTURE it makes legible — an agent, its tools, a turn loop,
an approval gate, a session — in Lua, at the size Lua wants.

## The five rules

Each rule names the file it lives in and has a test that fails when it stops holding.

1. **The core knows no vendor.** `src/turn.lua` may not name a provider, an HTTP
   library, a filesystem or a clock. It takes a `port` table and calls it. Anything
   real is supplied by the host. *Test: `core_names_no_vendor`, which reads the file.*

2. **A declaration cannot run anything.** `src/spec.lua` builds a plain table and
   never calls a tool body, a model or a hook. Loading an agent file is safe on an
   untrusted file; only `turn.run` executes. *Test: `loading_runs_no_body`.*

3. **A tool is a name, a why, typed arguments and a body.** Nothing else is required
   and nothing else is read. A tool with no `about` is refused at declaration, because
   a tool the model cannot understand is a tool it will misuse.
   *Test: `a_tool_states_what_it_is_for`.*

4. **Permission is the harness's, never the tool's.** `ask = true` on a tool means the
   port is asked before the body runs, and a refusal is a normal result the model sees
   — not an error and not a silent skip. A tool body cannot approve itself.
   *Test: `a_refused_call_is_a_result_the_model_reads`.*

5. **The loop always ends.** Every run has a step budget. Reaching it ends the turn
   with a stated reason, never a hang. *Test: `a_runaway_loop_stops_and_says_so`.*

## Dialect

Targets Lua 5.4 (the host embeds mlua with `lua54`) and stays inside the subset LuaJIT
5.1 also accepts: no integer-division operator, no goto, no bitwise operators, no
`<close>`. Tests run under whichever of `lua` or `luajit` is on PATH.

## The three later seams

Written after the twelve, when an agent had to be reachable by a workspace rather than
only by a person. Each is a declaration plus **an optional port with a double** — the
same shape as the six, and for the same reason: the declaration says what, the world says
how, and both halves drive in a test with nothing real attached.

* **`agent.skill`** — a procedure a *person* wrote. A tool is a body in this process; a
  plan is this run's and the agent authored it; a skill outlives every run and the agent
  may read it but not rewrite it. Briefed by name and one sentence, read only when the
  model asks, because twelve procedures in a system prompt is twelve procedures the model
  half-remembers. Port: `skills`. Spec: `spec/skills.md`.

* **`agent.every`** — a beat. Before it, a run began only when a person typed or another
  agent delegated; a machine has a beat and an agent did not, so *"every evening,
  summarise what changed"* was a sentence this harness could not hold. It needs two
  things and both are here: the declaration, and a **durable ledger** — without one,
  *"never twice for the same day"* is not expressible, since a session dies with the
  conversation and an in-process table forgets across exactly the restart that
  double-fires a beat. Port: `ledger`. Spec: `spec/schedule.md`.

* **`agent.uses`** — a server whose tools live in another process. They become ordinary
  tools before the model sees a schema, because the model's job is not to know which
  arrived over a wire. Port: `mcp`, which is the only thing in the tree that knows what a
  transport is. Spec: `spec/mcp.md`.

And one repair, not a seam: **a `call` hook may refuse a call.** "Hooks observe" is about
mutation — a hook never holds the table the call will be made with — and a veto removes a
call rather than rewriting one, so it breaks nothing. Every hook return used to be
discarded in silence, which meant `return { stop = "never more than three" }` read as a
declared limit and was not one: a failure that looked exactly like success. Now a refusal
is honoured and anything else is a note naming what came back.

## Reconciliations

The twelve subsystems were written in parallel, each to its own file in `spec/`. These
are the places their edges did not meet, what was decided, and why. Recorded here
because the next person to change one of these files needs to know the other end exists.

1. **The declaration surface has one definition, in `cli.surface`.** It lived inside
   `cli.sandbox`, where only a file loaded by the runner could reach it, so
   `require`ing the tree gave you a dozen modules and no `agent`. It is lifted out
   unchanged; the sandbox calls it, and so does `agent.lua`. Two definitions of one
   surface is two surfaces that drift.

2. **`agent.tool` and `agent.on` take both forms.** The curried one the surface reads
   in — `agent.tool "read" { ... }` — and a two-argument one, because a host building a
   declaration in code has no syntax for the first. `tools_fs.install` probes for the
   curried form and `work.install` assumes it; both now hold.

3. **The filesystem tools' results are rendered where their words are.**
   `spec/tools_fs.md` says a body answers with a table and that rendering it "is
   `turn`'s business". `turn` cannot do it: `entries`, `hits` and `from_line` are
   `tools_fs`'s vocabulary, and rule 1 says the core knows no vendor. `tools_shell`
   had already settled the question for itself by rendering its own result, so
   `tools_fs.render` was added to match — pure, additive, no body changed — and
   `agent.files` installs through a shim that applies it. Without it every read
   reached the model as `(the tool returned a table of 8 entries, not text)`, which is
   a harness that silently cannot read a file.

4. **The shell tool's workspace root is filled in at the seam.** `tools_shell.run`
   wants `ctx.root`, an absolute workspace root. `turn` builds a tool context from the
   port's own keys plus six reserved names, and `spec/port.md` has no root among its
   six ports. Rather than add a seventh field to the port contract for one tool,
   `agent.shell { root = ... }` supplies it, and only when the run does not carry one
   already.

5. **A tool body answers with one value.** `tools_shell.tool` returns the rendered
   block *and* the result table behind it; `turn` keeps the first and adds a note about
   the rest to every single call. The second value cannot reach a caller through the
   harness anyway, so `agent.shell` drops it. A host that wants the structure calls
   `shell.run` itself, which is what that return was for.

6. **Setters answer with the prefix.** `src/spec.lua`'s own header says every entry
   point returns the agent table; its setters return nothing. Wrapped in `agent.lua`
   rather than changed in `spec.lua`, because the sandbox's read-only proxy wants the
   plain form and one of the two had to give.

7. **`test/interpret_test.lua` finds its module by path, not by working directory.**
   It alone used `dofile("src/interpret.lua")`, which passes from the tree root and
   fails from anywhere else. It now uses the `package.path` header the other twelve
   use.

Two things worth saying did *not* need reconciling: every module loads on the first
try under both interpreters, and no file requires a module nobody wrote.

### One divergence, on purpose

This repository's vocabulary retires the word **run** in favour of *call*. This tree
keeps `run`: it is in the locked example at the top of this file, in `turn.run`, in
`shell.run`, and in the `run = function (c)` of every tool in twelve subsystems and
676 tests. A vendored harness with its own five rules gets its own noun.
Recorded rather than changed.
