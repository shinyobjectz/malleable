# malleable — agent systems, behaviour first

Locked decisions. Change only with a written reason here.

## What this is

A framework for building agent systems behaviour first. You write what the agent should
do, in the language you would have used to ask a person; the framework runs it and holds
the agent to it. Everything else here serves that sentence.

Concretely, an agent is a pair of files, and neither one is a program in the ordinary
sense:

    triage.lua        what the agent IS      — its name, its model, its tools, its gate
    triage.feature    what it DOES           — its behaviour, in Gherkin, and executable

Or one file: since 2026-09-11 the feature may say what the agent is as well, in its
Background, and then it is the whole agent (below, "One file, and an agent that edits it").

The Lua half is a declaration: a surface that builds a table and runs nothing. The Gherkin
half is the behaviour, written in prose by the person who wanted it, and executed without
translation — the `Given` lines build the world, the `When` line runs the agent against it,
the `Then` lines judge what came back. A feature that passes is documentation that was true
this morning. `spec/gherkin.md` and `spec/behaviour.md` are the contract; the forty-three
built-in step expressions cover the harness's own surface, so a declaration is verifiable
with no glue code written at all.

A harness that can only be tested in Lua can only be reviewed by someone who reads Lua, and
the person who knows whether the agent should have asked before filing the verdict is very
often not that person. That is the whole argument for the second file.

### The same shape as typeaway, one layer down

This tree is vendored by typeaway, and it is not a coincidence that it looks like it.
Typeaway is a system where a person writes a page in prose and Build derives what runs from
it. Malleable is that idea at the size of one agent, with the derivation taken out: the
prose is Gherkin, it is executable as written, and nobody's model has to read it correctly
for the thing to work.

The two meet at the feature file. Typeaway *renders* one off a system page's ontology and
runs it; a person using malleable *writes* one by hand. The runner is the same runner and
the vocabulary is the same closed vocabulary, which is what keeps the two from drifting into
different products. What malleable does not have, and will not grow, is the map: no AMR
graph, no intent schema, no reading of ordinary English. A step in a feature matches an
expression or it is reported undefined. That line is the whole difference between the two
trees, and it is the reason this one can be handed to somebody who has never heard of
typeaway.

The surface, then, is a Lua declaration:

    agent.name  "reviewer"
    agent.model "openrouter:z-ai/glm-5.3"

    agent.tool "read" {
      about = "Read a file",
      args  = { path = agent.string "workspace-relative path" },
      run   = function (c) return c.fs.read(c.args.path) end,
    }

One prefix, `agent`, and nothing else to remember. No `m.` handle to thread through,
no builder to close, no `return` ceremony — the file *is* the declaration.

## What this is NOT

A port of Pi, or a coding agent at all. A coding agent is a product: a session store on
disk, a scheduler holding threads, telemetry, a package manager. None of that is here.
The one interface in the tree is `console/`, a host like any other: it lives beside the
harness, and nothing under `src/` may require it (`spec/home.md`). (`agent.every` is not a scheduler: it states a beat and
answers what is due. Nothing holds a thread, and no run starts unless a host asks.) What
is taken from Pi is the ARCHITECTURE it makes legible — an agent, its tools, a turn loop,
an approval gate, a session — in Lua, at the size Lua wants.

Nor is the Gherkin half a port of Cucumber. Cucumber is a framework a project builds a
step library on top of: everything is undefined until somebody writes the glue, and the
glue is where the bugs live. Here the vocabulary that matters is **closed and built in** —
forty-three expressions over the harness's own nouns, which are the only nouns a harness
has — so the common case needs no glue at all, and `agent.step` exists for a domain rather
than for the basics. There are no hooks, no tags that change execution, no world object a
project subclasses, no reporters, no parallel runner and no plugin system. A feature is
read, run against the doubles, and reported.

## The eight rules

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

6. **A feature states behaviour and cannot cause it.** A `Given` line may only write the
   world; a `Then` line gets a read-only world and may only read the result; there is no
   `when` slot a workspace can declare. A scenario that could act on what it observes is a
   test that passes because it tested itself, which is the failure mode that makes a green
   suite worthless. Structural, not conventional: the two phases are handed different
   context tables and there is no arrangement of fields that crosses them.
   *Test: `a_feature_cannot_cause_what_it_states`.*

7. **The reader knows no harness.** `src/gherkin.lua` may not name an agent, a tool, a
   port, a world, a result or a run. Text in, pickles out. It is rule 1 pointing the other
   way, and it is what lets the reader be measured against four hundred real feature files
   with no harness present. *Test: `the_reader_knows_no_harness`, which reads the file.*

8. **No span attribute carries a payload.** A trace carries names, counts, sizes,
   durations, decisions and codes — never a prompt, a model's text, a file's contents, a
   tool's arguments or its output. A trace exporter's whole job is to send what it is given
   somewhere else, and an agent's arguments are the most sensitive bytes in the process.
   Enforced by construction, since attributes come from a closed vocabulary, and by a test
   that walks every span the suite produces. *Test: `a_span_carries_no_payload`.*

## Dialect

Targets Lua 5.4 (the host embeds mlua with `lua54`) and stays inside the subset LuaJIT
5.1 also accepts: no integer-division operator, no goto, no bitwise operators, no
`<close>`. Tests run under whichever of `lua` or `luajit` is on PATH.

## The five later seams

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

* **`agent.step`, and the feature file beside the declaration** — the fourth, and the one
  the other three were building toward. A declaration said what an agent was and nothing
  said what it did, so *"it reads the file, runs the suite, and asks before it files"* was
  a sentence this tree could only hold as a comment. It needs three things and all three
  are specified: a **reader** over the Gherkin subset (`spec/gherkin.md`), a **closed
  vocabulary** of forty-three step expressions over the harness's own nouns, and a
  **runner** that builds the world out of the `Given` lines and judges the `Then` lines on
  the result (`spec/behaviour.md`). No new port: the world a feature builds is
  `agent.world`, the doubles that were already there, which is why a scenario reaches no
  network, no disk, no subprocess and no clock.

  `agent.step` is the extension point, curried like `agent.tool`, and it is deliberately
  narrower than cucumber's: a step declares its phase by which body it gives, `given` or
  `then_`, and there is no `when` a workspace can write. The three ways a run starts belong
  to the harness.

* **`result.spans`** — the trace, and the fifth seam is the only one with no declaration at
  all, because a run does not have to opt into having happened. The turn loop records its
  own tree — a turn holds steps, a step holds a model call and the tool calls it asked for,
  a tool call may hold a question put to a human and may hold a whole child run — and the
  record is a **fact about the result**, not a favour from a sink. Spec: `spec/trace.md`.

  No new port, and that was the decision: the log port already takes flat events, cannot
  fail and may not be read back, so reconstructing a tree from it would mean depending on
  the one thing in this tree that is allowed to drop what it is given. So the tree is in
  the result, complete, and the *same* records also go out through the log port as they
  happen for a host that wants a live view. Two consumers, one vocabulary, and the lossy
  one is now harmless.

  **This tree does not know that OpenTelemetry exists.** `src/turn.lua` records spans in
  its own vocabulary and rule 1 holds unchanged. `src/trace.lua` renders them — to OTLP/JSON
  as a string, or to indented text for a person — and opens no socket, exactly as
  `spec/provider.md` settled for the model. In this repository `ta-harness` surfaces the
  tree as plain Rust and exports none of it — the crate that embeds this tree names no
  vendor either — and the app above it walks the tree into the live OpenTelemetry pipeline
  it already runs behind its `otel` feature, minting the ids and supplying the parent,
  which are the two things only a host can know.

  Where OpenTelemetry's GenAI semantic conventions have a name, it is used verbatim
  (`invoke_agent`, `chat`, `execute_tool`, `gen_ai.*`), pinned to the document and date
  named in `spec/trace.md`; everything the harness has that they do not is prefixed
  `malleable.`. What keeps that table and the code together is `trace.allowed` and the
  rule 8 test, not a database — this tree is published on its own, and a vocabulary only
  one embedder can consult is not one the tree can be checked against. The most valuable of
  the minted ones is the gate: **how often an agent asks, and what it is told**, which is a
  better measure of whether it is safe to leave running than any token count.

  **The deepest thing rule 8 buys is `malleable.act`.** A tool call's span used to say
  `execute_tool shell`, ok, 412 ms — so the run's most behaviourally loaded moment was the
  one its trace was blindest to, because what the agent actually ran is a payload and the
  rule keeps payloads out. The fix was not to relax the rule but to move the **parse** to
  where the payload already is: `src/command.lua` reads the command line inside the tool
  and answers a term from a closed set — `tests`, `deletes`, `publishes`, `escalates` — and
  the term is what travels. The rule got stronger, not weaker: a span now holds a behaviour
  instead of a string somebody has to redact later.

  Two halves, and only one can be wrong. The **parse is total**: a line it cannot place is
  a defect in the grammar. The **naming is partial**: a command it cannot name is a gap,
  counted on the report, and never repaired by widening a pattern. That is what keeps this
  from being the phrase reader mar-4o07 bans — that rule is about prose, where a word list
  passes its tests by tautology; here the language is closed and formal, the parse is
  total, and the partiality is a number instead of a silence. The ruling that placed the
  reader in the tree rather than behind a C toolchain is `spec/command.md`.

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

### Four divergences, on purpose

A vendored harness with its own rules gets its own nouns. Each of these collides with the
repository's vocabulary, each is recorded rather than changed, and the reason is the same
in all three: the alternative is a tree whose error messages disagree with the file the
person is looking at.

**`run`.** This repository's vocabulary retires it in favour of *call*. This tree keeps it:
it is in the locked example at the top of this file, in `turn.run`, in `shell.run`, and in
the `run = function (c)` of every tool in twelve subsystems and 676 tests.

**`step`.** The repo defines a step as one call within a machine call; `spec/turn.md` has
taken it for one pass of the loop; Gherkin prints it on every line of every feature file in
the world. Inside `gherkin.lua` and `behaviour.lua` a step is the Gherkin line, and turn's
step stays turn's. The two never appear in one sentence — the runner's report says *line*
where it would have to say both — and the one built-in expression that means turn's step
says so: `Then it takes {int} steps`.

**`declaration`.** The repo has claimed it for how a page introduces what a thing is. This
tree has used it for the agent file since the first commit and every spec in `spec/` says
it. Cucumber's own word for a step's body is *definition*, which would have collided
harder, so a step's Lua function is its **body**, exactly as a tool's is.

**`span`.** The repo's span is a candidate phrase with its bytes on a page — what the map
rows and a citation anchors. OpenTelemetry's is a timed node in a trace. Unrelated, and
neither can be renamed: one is on a wire format, the other is the map's whole vocabulary.
Inside this tree span means OpenTelemetry's; the ontology carries the other meaning as
`otel-span` so anything outside can still name it, and repo code that touches both
qualifies — `trace::Span`, never a bare `Span`. `trace` itself did **not** need a
divergence: the repo's definition was the same concept with a different subject and was
widened to cover both, which is what the ledger is for.

## The definition file, and why it is tested

`library/agent.def.lua` is a LuaLS `---@meta` file: one `---@class` per entry point on the
`agent` and `interpret` prefixes, with the argument types and the return shapes, plus a
`.luarc.json` that points at it. It is what makes the declaration surface complete in an
editor — the twenty-odd entry points, the five argument types, the six ports, the four
stops — for a person who has not read `spec/`.

There is no SDK, no constructor and no loader (ruled 2026-09-04): a declaration is plain
annotated Lua and the definition file is annotation only. It cannot be required, cannot run,
and is not on `package.path`.

**A definition file that is not tested is a lie with autocomplete.** So one test enumerates
the keys of the real `agent` table and fails if the meta file omits one or names one that
does not exist, and the same test covers `interpret`. The file is checked in rather than
generated, because a generated one would document what the code happens to do rather than
what it promised, and the promise is `spec/`.

The Gherkin half of the same job is not a second file. The forty-three expressions live in
`src/behaviour.lua` and nowhere else; `agent.steps()` answers them, `docs/STEPS.md` is
rendered from them and never hand-edited, and `behaviour.check` is what an editor runs to
tell a person that the step they just typed matches nothing and here is the stub for it.
One source, three renderings.

## The direction: a trace is parsed INTO behaviour

Ruled 2026-09-10, and it is a ruling about direction rather than about features, so it is
worth stating before the thing it governs exists.

**Gherkin is not a format for logs.** It is tempting to read it as a query language over
telemetry — `the trace shows "execute_tool" 3 times` — and eight expressions in this tree
did exactly that for a day. They are **retired**. What was wrong with them was not that
they failed; it is that a scenario written in them describes the harness rather than the
agent. `span`, `trace` and `log` are the harness's nouns. A person watching an agent does
not think *the gate span closed refused*; they think *it asked before it filed, and was
told no*.

Retiring them cost nothing and **gained two words**. Rewriting the two scenarios in
`example/reviewer.feature` that used them showed six of the eight were already covered by
`it calls`, `it never calls`, `the call to … is refused` and `it takes {int} steps` — and
that two things a person genuinely wanted to say had no expression at all: **`the call to
{word} fails`** (allowed, and it did not work, which a refusal is not) and **`it calls
{word} before {word}`**. *It reads before it judges* is the whole point of a reviewer, and
the vocabulary could not say it. That is the gap discipline below, working the first time
it was asked to.

So the direction runs the other way. **A run is read back out as a scenario**, in the same
closed vocabulary a person authors in, and the two objects are then the same kind of
thing:

    triage.feature              what it was asked to do   — stated, by a person
    the observed scenario       what it did               — read out of the run

Set one against the other and you get an **agreement**: the lines that held, the lines that
did not, and — the part worth having — **the lines the run did that nobody stated**. A
passing test says an agent did what was asked. Only the agreement says what else it did on
the way.

Observe every sample of an eval and collapse the ones that say the same thing, and what
comes back is a **repertoire**: not *17 of 20 passed*, but *in 17 it asked before filing,
in 3 it went straight to it, and here is the scenario those 3 ran*. That is what it means
for a behavioural indicator to be measured in terms of parsable behaviour. Nothing here
reads a weight and none of this is interpretability in that sense; what it borrows is the
ambition — recover the repertoire from observation rather than assert one, and make the
unit of measurement a behaviour a person can read.

**The discipline that keeps it honest** is `mar-4o07` one layer up. What an observer cannot
say is a **gap in the behavioural vocabulary**, filed against the vocabulary. It is never
repaired by reaching for a telemetry noun, because the moment the observer is allowed to
emit *the trace shows* it will emit that for everything it has no word for, and the
vocabulary stops growing on the day it starts.

Contract: `spec/observe.md`.

## What an eval is here, and what it is not

The two seams above were written in one epic because each is half of one thing.

`--verify` runs a feature against the doubles: deterministic, one sample, pass or fail, and
it belongs in CI. `--eval` runs **the same file** against a real model, k times per
scenario, and answers a rate. The claim, stated as a claim: **an agent's effectiveness is
the rate at which it does what its own documentation says it does.** The yardstick was
written in prose by the person who wanted the behaviour, before the agent existed, and it
is the same text that documents it — so nothing was written to be an eval, and nothing was
written to be passed.

**No model judges anything.** The `Then` lines are the same deterministic assertions in
both modes. This repository does not run checking standards and does not judge an output
with a model (ruled 2026-09-07); what is nondeterministic here is the system under test,
and the scoring is a comparison and a count that would give the same answer if a person did
it by hand.

Three things fall out, and each is in `spec/behaviour.md` rather than here because each is
a contract:

* the world stays doubled in both modes and only the model is real, because a real model
  driving real tools against real files is not an eval, it is production;
* the two given lines that script a model are dropped in an eval, so a scenario whose
  expectations only made sense against a scripted model is reported **not evaluable** — the
  feature file telling a person which of their expectations were about the agent and which
  were about a transcript they had imagined;
* every scenario opens a span, so a trace in a collector is attributable to the sentence
  that asked for it. Without the feature there is nothing to attribute a trace to; without
  the trace a falling rate says a thing is broken without saying where.

There is no threshold in this tree, no pass mark and no grade. What rate is good enough is
a decision about a product, and a harness that picked one for you would be making it
silently.

## It brings its own world, and it can be asked to improve within a wall

`bin/malleable.lua` is twenty lines and is the **only** file in this tree that touches the
real world. Not one of the modules names `io` or `os`. That was true before anybody set
out to make it true — it falls out of rule 1 applied consistently — and it means the
harness has always been a pure function of its ports. What was missing was never
portability. It was a **world** to hand it that did not come from outside.

`agent.sandbox` is that world: a filesystem in memory, a shell of eighteen commands that
really runs them, a frozen clock, a gate, and a log. `example/embedded.lua` is a whole
agent inside one, and it needs nothing but a Lua.

Three things about it are decisions rather than details.

**It is `shell`, never `bash`.** Eighteen commands, and every refusal names all eighteen. A
thing that is ninety per cent of bash is wrong in ways nobody can predict, which is worse
than a thing that is obviously small and says so. Where the honest small thing differs from
the real one it is stated: `grep` takes a fixed string, and there is no environment.

**Determinism is the point, not isolation.** The same script over the same filesystem
produces the same bytes every time — every listing sorted, no clock, no randomness, no
host. Two evals are comparable only if the world was identical, and a change can be
attributed to a cause only if nothing else moved. `spec/shell.md`.

**`agent.world` and `agent.sandbox` are two doors on purpose.** `world` is the test double
and its defaults are a test's: nothing runs that was not scripted, because *nothing is
scripted for that* is the most useful sentence a double ever says. An embedder wants the
opposite default, and two names is how both get to be honest. The sandbox's gate **refuses
by default**, because a sandbox is where an agent is allowed to try things, which is exactly
where a gate saying yes by default would be worst.

### The wall

The harness now measures itself well enough to improve itself: a rate, an agreement, a gap
count that only goes down, and eight rules. That is a fitness function and a constraint
set, and both already existed. So the loop is small — propose, measure, keep or refuse —
and all the difficulty is in the wall around it, because self-improving systems fail
**quietly**. Three ways, and one thing stops each:

| it goes wrong by | what stops it |
| --- | --- |
| making the test easier | the authored feature file is text in, never out |
| relaxing what it asks about | `ask` is not an editable field, and is refused by name |
| losing behaviour as the rate rises | the repertoire diff, and a loss halts the step |

Three fields are editable — `system`, `budget`, and a tool's `about` — and the list being
short is the point: each is a thing a person would also have tried, and each is reversible
by reading one diff. Everything else is refused **by name**, because a field refused by
silence teaches whoever proposed it to try again the same way.

`ask` is the one that matters. **An agent that can edit its own gate has no gate**, and it
is the edit such a loop would most like to make.

The third gate is the one that exists nowhere else. A **repertoire** is kept as a feature
file — one scenario per distinct behaviour, tagged with how often it happened — so
behavioural memory is re-runnable, readable and diffable by `git`, and needed no new
format, writer or reader. Diff two and you get what was *lost*. A rate can rise while an
agent quietly stops doing half of what it did; a pass count cannot see that.

One correction the first loop made to its own design, which is worth keeping: the
repertoire that guards against loss is built from **passing** scenarios only. A declaration
whose budget was too small stopped with `budget`, so *it stops with budget* was in its
repertoire, and raising the budget was refused for losing it. The gate was right about the
mechanism and wrong about the set — a behaviour exhibited while failing is not something to
protect, because stopping it is what fixing means.

`spec/change.md` is the ruling, and it was written before the code, because a wall drawn
afterwards is a wall drawn around whatever was built.

## One file, and an agent that edits it

Ruled 2026-09-11, and it changes two decisions above, so the reason is written here.

**An agent may be one feature file.** The pair put what an agent is in the one language only
someone who reads Lua could change, so an agent could not change itself in the language it is
judged in, and a person could not give it a tool without Lua. Now the Background may say what
the agent is, in a closed vocabulary — `the agent is called reviewer`, `it runs commands`,
`the tool verdict asks first` — that compiles to exactly the table `agent.*` builds. The
pair stays: a host building in code, and a body too long for a doc string, still want Lua,
and `agent.declare(text)` joins the two halves in one declaration.

`spec/behaviour.md` had said a feature must never write a declaration, because a generator
that turned prose into one would make the test as reliable as the model. That argument is
kept, and it is why this is safe: nothing reads the Background as English. Each is line
matches one expression or the file is refused at load, the same line always builds the same
table, and a test holds the vocabulary to the surface, entry point by entry point.

**The wall follows reach, not a field list.** `spec/change.md` let an agent edit three
fields. That was right about the danger — an agent that can edit its own gate has no gate,
and one that can edit its test will pass it — and too narrow to build with. The two refusals
it existed for stand, by name: an `asks first` line may be added and never removed, and an
authored scenario is the person's. Everything between is sorted by what it does to reach: an
edit that widens nothing the agent makes itself, scored against the authored scenarios; one
that widens reach — a tool, a body, commands, another agent — goes to the person through the
harness's own gate, as a tool with `ask = true`. So an agent can extend itself and build
other agents, and every step past what it could already do is one a person said yes to.

None of the eight rules moved. Rule 2 holds for a feature as for a Lua file: a doc string is
compiled, never called. Rule 4 is how widening reaches the person. Rule 6 is why a shorthand —
a line that stands for other lines, the vocabulary extended in Gherkin — may be given or then
and never when. `spec/declare.md` is the contract.

## A talker in front, jobs behind

Added 2026-09-11, so that a developer can put a person in conversation with an agent,
typed or spoken, without the agent's work setting the pace of the conversation.

A spoken conversation has a budget a coding agent cannot meet: a person expects the first
word within a second or so, and an agent that reads files, asks at its gate and checks its
own work takes tens of seconds. One model cannot be both, so there are two layers. The
**talker** is built for speed: a small brief, three steps, reasoning low, four tools, and
no reach into the world at all. The **jobs** are built for the task: ordinary runs of the
declared agents, under the same gates, budgets and worlds as any other run. The talker
never does work, and a job never speaks. What a job found reaches the person only as the
talker's words, from a report the talker is given with its facts exact.

The rules that make this work are taken from the published two-layer designs (DeepMind's
talker and reasoner, OpenAI's chat supervisor, LiveKit's asynchronous tools), and each was
checked against a live run rather than taken on faith. The talker says something before it
hands work off, because silence while a job starts reads as a failure. A person talking
over the talker cuts the talker, never a job. A report waits for the floor to be free, and
two reports that end together are one reply. A job's question is relayed, and `decide` is
refused until the person has spoken since the question was put, so the talker cannot
approve its own job's call.

The transport is the harness's own. Each run is a coroutine, and a port that would block
yields a wait instead: `host` with a poll, `sleep`, or `person` (`src/wait.lua`). That is
the console's turn clock, so one conversation drives the talker and several jobs on one
thread, and the same code runs turn-based in a terminal or realtime inside a 30-frame loop. Interruption is a
coroutine that is no longer resumed, which is Hugging Face's `CancelScope` with nothing to
check. The one new thing a run needed was a tool that **ends** it (spec/turn.md), so a reply
that hands off stops at the hand-off rather than spending another call to say so.

What was left out is written in `spec/speech.md`, "Where it came from": the Realtime
server, direct audio into an audio model, and speculative turns, the last of which is the
next thing to measure, because most of a spoken turn's time is the talker's call.
