# behaviour — a feature file is what the agent does, and the test that it does it

`src/behaviour.lua`. Contract, not implementation. No code exists yet; the module is
written to this document, and this document is amended before the code diverges from it.

## What it is for

An agent declaration says what an agent *is*: its name, its model, its tools, when it must
ask. Nothing in it says what the agent *does*, and that is the half a person actually
argues about, reviews, and gets wrong.

So a declaration comes in a pair:

    triage.lua        what the agent is        — the declaration, in Lua
    triage.feature    what it does             — the behaviour, in Gherkin

and the second one is executable. Not a document that describes the first and rots beside
it: the runner builds the world out of the `Given` lines, runs the declaration against it,
and judges the `Then` lines on what came back. A feature that passes is documentation that
was true this morning.

This is the whole bet, and it is worth stating plainly because it is the reason this
subsystem exists rather than a `test/` directory: **the behaviour of an agent is written
in natural language by the person who wanted it, and executed without translation.** A
harness that can only be tested in Lua can only be reviewed by someone who reads Lua, and
the person who knows whether the agent should have asked before filing the verdict is very
often not that person.

## Vocabulary

`feature`, `scenario`, `pickle`, `expression` and `vocabulary` are defined in
`spec/gherkin.md`, along with the recorded divergence on **step**. Two more here:

* a **phase** is one of the three parts of a scenario — given, when, then. Not a *stage*,
  not a *section*. The three phase names are lower case in this tree's own prose and
  capitalised only when quoting a file.
* the **world** is what `agent.world` already means: the six ports and the three seam
  ports, in memory, deterministic. A `Given` line does not "set up", "arrange", "mock" or
  "stub" anything. It states one fact about the world, and the world is built out of the
  facts stated.

## Where it sits

    a feature file  ->  gherkin.pickle(text)         -- spec/gherkin.md, no harness in it
                    ->  behaviour.run(decl, pickles) -- here
                    ->  a report                     -- here

`behaviour` requires `gherkin` and `double`, and nothing else in this tree. It reaches the
declaration through the public surface only — `agent.run`, `agent.tick`, `agent.check` —
so it cannot see anything a host could not see, and a feature therefore cannot test an
internal that a host is not allowed to depend on.

## The three phases, and the one rule that makes them safe

**A `Given` line may only write the world. A `Then` line may only read the result.**

That sentence is the whole design. It is what separates this from a scripting language
that happens to be shaped like English, and it is enforced structurally rather than by
convention, in the way `spec/interpret-marks.md` makes a regex unrepresentable rather than
discouraged:

* a given body is called with a context that has a **`world`** and no `result`;
* a then body is called with a context that has a **`result`** and a `world` that is a
  read-only proxy — the same proxy `cli.sandbox` uses — so a write raises by name;
* neither context carries a port, a model, a file handle or a clock. A step body cannot
  reach the world except through the world table it was handed.

The consequence is worth spelling out: **a scenario cannot cause the behaviour it claims to
observe.** A `Then` line that quietly wrote a file, or called a tool to check that the tool
works, would be a test that passes because it tested itself, and this is the failure mode
that makes a green suite worthless. There is no way to write one here.

`When` is the seam between them, and there is exactly one per scenario. Two are refused by
name at load, and none is refused at load: a scenario with `Given` and `Then` and no `When`
is a scenario nobody finished, and it is more useful to say so than to run it.

## The vocabulary

Thirty-three expressions, closed, versioned. `behaviour.VOCABULARY = 1`, bumped when an
expression changes meaning. A step that matches none of them is **undefined**, and an
undefined step is reported with the expression a person would have to write to define it —
never dropped, never guessed at, and never a failure (see below).

Each expression is assigned to exactly one phase, and the phase decides when it runs; the
Gherkin keyword on the line does not (`spec/gherkin.md`, "The pickle").

**`{word}` is a name in the system and is written bare; `{string}` is text a person typed
and is written in quotes.** A tool, a server, a beat and a stop reason are names —
`Then it calls verdict` — and a path, a command line, a prompt and an answer are text.
The rule is worth having because the alternative is a reader guessing whether the quotes
were part of the name.

### given — the world

| | builds |
| --- | --- |
| `the file {string} contains:` + doc string | `fs` |
| `the file {string} is missing` | `fs` |
| `the command {string} answers {int} and:` + doc string | `sh` |
| `the human approves {word}` | `ask` |
| `the human refuses {word}` | `ask` |
| `the clock reads {string}` | `clock` |
| `the model calls {word} with {value}` | `model`, appended in order |
| `the model answers {string}` | `model`, appended in order |
| `the workspace keeps a skill {string}:` + doc string | `skills` |
| `{word} last ran on {string}` | `ledger` |
| `the server {word} offers {word} and it answers {value}` | `mcp` (said without a comma after the name: a `{word}` reads to the next space) |
| `the budget is {int}` | the run's options |

The model's script is *ordered*, and the order is the order the lines appear in the file.
This is the one piece of state a given line accumulates rather than sets, and it is the
reason a scenario reads like a transcript:

    Given the model calls read with {"path": "src/turn.lua"}
    And the model calls verdict with {"summary": "the loop is small"}
    And the model answers "I read it and filed an approval."

### when — the run

| | does |
| --- | --- |
| `the agent is asked {string}` | `agent.run(prompt, world)` |
| `the clock strikes {string}` | `agent.tick` — what the beat is owed at that time |
| `the declaration is loaded` | `agent.check` only; nothing runs |

`the declaration is loaded` is how a feature states something about the declaration itself
rather than about a run — that a tool with no `about` is refused, that a budget of zero is
refused. It is the one `When` that reaches no port at all.

### then — the result

| | reads |
| --- | --- |
| `it stops with {word}` | `result.stop`, one of the four |
| `it answers {string}` | `result.answer`, exactly |
| `the answer says {string}` | `result.answer`, containing |
| `it calls {word}` | `result.calls` |
| `it calls {word} with {value}` | `result.calls`, arguments compared as decoded values |
| `it calls {word} {int} time(s)` | `result.calls` |
| `it never calls {word}` | `result.calls` |
| `the call to {word} is refused` | `result.calls`, the refusal flag |
| `the human is asked about {word}` | the gate's record |
| `it takes {int} step(s)` | `result.steps` |
| `it takes at most {int} step(s)` | `result.steps` |
| `no beat is due` | after `the clock strikes`: nothing ran, every beat held or not yet due |
| `the file {string} holds:` + doc string | the world's `fs`, after |
| `the file {string} holds the line {string}` | the world's `fs`, after: one line of it, trimmed, exactly (added 2026-09-12 for a file an author edited, too long to state whole) |
| `nothing is written` | the world's `fs`, after |
| `it notes {string}` | `result.notes`, containing |
| `the declaration is sound` | `agent.check` answered true |
| `the declaration is refused because {string}` | `agent.check`'s reasons, containing |

### then — the calls that did not go through

| | reads |
| --- | --- |
| `the call to {word} fails` | it was called, was not refused, and did not work |
| `it calls {word} before {word}` | and in that order |

### then — what a command line amounted to

| | reads |
| --- | --- |
| `it runs a command that {word}` | a shell call whose command line did this |
| `it runs no command that {word}` | and no shell call did |

`{word}` is one of the eleven terms in `spec/command.md`, and a line naming anything else
**fails with the list**, rather than passing vacuously because nothing matched. A call the
gate or a hook refused ran nothing, and neither line counts it: a refused `git push` is the
gate working, and `it runs no command that publishes` holds (found by `showcase/06-commands.feature`,
2026-09-12).

These two are the only place in the vocabulary that reaches inside a tool's arguments, and
they are the reason a shell-first agent is sayable at all. `it calls shell` says a tool was
used; `it never runs a command that publishes` says the thing a person actually cares
about, and it is a line somebody could have written **before** the agent existed — which is
the test of whether a vocabulary is behavioural or is a log format with Gherkin punctuation.

The observer writes them, and stops writing the command line when it does: a Then line
carrying `{"command":"curl -H 'Authorization: Bearer …'"}` would put in a file people read
exactly what rule 8 keeps out of a span. The command stays in the **Given** half, which is
the world the scenario replays and cannot be reproduced without.

These two are what came out of **retiring** the eight telemetry expressions that once stood
here — `the trace shows {string}`, `the span {string} says {word} is {value}` and the six
beside them. Rewriting the two scenarios in `example/reviewer.feature` that used them
showed that six of the eight were already covered by `it calls`, `it never calls`, `the
call to … is refused` and `it takes {int} steps`, and that two things a person genuinely
wanted to state had no word at all: *a call that was allowed and did not work*, and *the
order it did things in*. "It reads before it judges" is the whole point of a reviewer, and
the vocabulary could not say it.

That is the discipline working rather than a tidy-up. A gap is filled with a **behavioural**
word; the harness's own nouns — `span`, `trace`, `log` — are not available, because a
scenario written in them describes the harness rather than the agent (DESIGN.md, "The
direction"; `spec/observe.md`).

**On `says`, `notes` and `because`, which compare text.** This repository rules that no
reader may key off a phrase, an exact word or a character position (mar-4o07, 2026-09-09).
That rule binds the readers that derive meaning from a person's prose — the map, the
interpretive layer, Build. It does not bind an assertion in a test, and the distinction is
not a loophole: a `Then` line is a person stating, in this file, the exact words they
expect back. There is no inference to get wrong. A test that says *the answer says
"blocked"* is not reading language; it is comparing a string to a string that a human
wrote three lines above it, on purpose, in this file.

## agent.step — the workspace's own vocabulary

The forty-three cover the harness. They cannot cover a domain, and a feature about a
triage agent wants to say `Given the queue holds a ticket from "ops"`. So a declaration may
add steps, curried exactly like a tool, because a reader who understands one understands
the other:

    agent.step "the queue holds a ticket from {string}" {
      given = function (c) c.world.queue[#c.world.queue + 1] = { from = c.args[1] } end,
    }

    agent.step "the ticket from {string} is closed" {
      then_ = function (c) return c.world.queue[c.args[1]].closed == true end,
    }

Four things this shape commits to:

1. **A step declares its phase by which body it gives**, `given` or `then_`, and it may
   give only one. This is why the phase is structural rather than a field: a body in the
   `given` slot receives a given context, and there is no arrangement of fields that gives
   a then body a writable world. (`then` is a Lua keyword; `then_` is the cost of the
   language and is spelled that way in the error message too.)
2. **A step has no `when` slot.** The three `When` expressions are the harness's and are
   closed. A workspace that wants a different way to start a run is asking for a different
   harness, and a `when` a workspace could write is the door through which a scenario
   starts causing what it observes.
3. **`c.args` is positional**, in the order the parameters appear in the expression, typed
   as `spec/gherkin.md` says. `c.doc` is the doc string if the line had one, `c.rows` the
   data table.
4. **A then body answers `true`, or `false` and a sentence.** Not an assert, not an error.
   A failed expectation is a result the report prints, and a raised error in a step body is
   a *broken step*, reported apart from a failing one — the two mean different things and a
   report that conflated them would send a person to the wrong file.

A declared step whose expression collides with a built-in is refused at declaration, naming
both. The workspace does not get to redefine what `it calls {word}` means.

## Undefined is not failed

A scenario whose steps are all defined and all pass is **passed**. One that fails an
expectation is **failed**. One that contains a step matching nothing is **undefined**, and
its later steps are **skipped**.

Keeping those apart is the point of having them:

* *undefined* means this behaviour is stated and not yet modelled. It is a to-do with a
  sentence attached, and the report prints the `agent.step` stub a person would paste.
* *failed* means this behaviour is modelled and the agent does not do it.

A run that is all-undefined exits non-zero and says so, so a feature nobody wired up cannot
sit in a suite looking green.

## The report

`behaviour.run` answers a table, never printing:

    { passed = 4, failed = 1, undefined = 2, skipped = 3, broken = 0,
      scenarios = { { name = "...", line = 12, outcome = "failed",
                      steps = { { text = "...", line = 14, outcome = "failed",
                                  why = "it answered \"approved\", not \"blocked\"" } } } } }

`behaviour.report(t)` renders it: one line per scenario, the failing line quoted with its
number and the sentence beside it, and a tally. The renderer is pure and the caller decides
where the text goes, because this tree has no idea what stdout is.

## Checking a feature without running it

`behaviour.check(decl, pickles)` answers the problems a run would hit, as sentences, and
runs nothing. It is what the `--check` flag and the editor call, and it finds:

* a step matching no expression, with the stub to define it;
* two expressions matching one step;
* a scenario with no `When`, or with two;
* phases out of order;
* a step naming a tool the declaration does not declare — `Then it calls verdict` when
  there is no `verdict` — which is the single most common way a feature goes stale, because
  renaming a tool cannot break a file the compiler never reads;
* `Given the human approves {word}` naming a tool that does not have `ask = true`, which is
  a scenario asserting a gate that will never open;
* a declared step never used by any scenario in the feature.

Every one of those is a sentence with a line number. None of them requires a model, a port
or a clock, which is what makes this the thing an editor can run on every keystroke.

## The runner

    lua bin/malleable.lua --verify triage.lua triage.feature
    lua bin/malleable.lua --check  triage.lua triage.feature

`--verify` loads the declaration in the sandbox exactly as a run does — rule 2 holds, and a
feature file cannot cause a declaration to execute — pickles the feature, runs every
scenario against the doubles, renders the report and exits non-zero on a failure, a break
or an all-undefined file. It reaches no network, no disk beyond the two files it was given,
no subprocess and no clock.

With no feature named, it looks for `<declaration basename>.feature` beside the
declaration, which is the convention this pair is meant to make ordinary.

## Evaluating: the same file, against a real model

`--verify` runs a feature against the doubles: one sample, deterministic, pass or fail,
and it belongs in CI. `--eval` runs **the same file** against a real model through a port
the host supplies, k times per scenario, and answers a **rate**.

    lua bin/malleable.lua --verify triage.lua              -- deterministic, no world
    luajit scripts/eval.lua evals/notebook.feature --samples 5   -- a real model, a rate

There is no `--eval` flag on the runner; `scripts/eval.lua` is the eval (`--model ID` puts
the real model in place of the one the feature names, so a file written for the doubles
runs unchanged), built from the same pieces (`declare.apply`, `cli.drivers`, `behaviour.run` with `eval = { samples, model }`),
with the real model from `OPENROUTER_API_KEY` and a scratch root with no history. The evals
the console's agents are measured by live in `evals/`, the talker's in `scripts/eval-talk.lua`,
and the findings in `docs/eval-report.md`.

**Every fault a real run finds becomes a doubles scenario first, and the fix second**
(ruled 2026-09-12, `docs/confidence-plan.md`). A real-model run is where a fault is
noticed; the doubles are where it is kept from coming back, and a fix that lands without
the scenario that fails before it is a fix nobody can tell from luck. The scenario goes
in the eval file the run came from, or in a kit's `rails` (`docs/spec/kit.md`).

### The long task: a real shell, a real folder, hours

`scripts/eval-long.lua FEATURE --only NAME [--root DIR] [--hours H] [--journal FILE] [--out FILE]`
runs one scenario with the world real all the way down: the real model, a real folder,
and a real shell (`bin/subshell.lua`, `docs/spec/subshell.md`), with the network open. It
is the one place the harness runs commands a model wrote, and the decisions that makes are
the script's, in writing at its head: the child gets `PATH` and a `HOME` under the root and
no key; every gate is approved and journalled, because nobody is there; a wall-clock cap
ends the run by answering the next model call `unavailable`; the folder is kept.

The scenario's Then lines are the same checks as anywhere else, on the result: the stop,
the kinds of command it ran (`it runs a command that tests`), and the kinds it never ran
(`publishes`, `escalates`). What it made is judged afterwards by the thing itself, never by
a model: the script runs `npm test`, `npm run build` and `npm run lint` in the folder and
records the exit codes, the files, the lines of TypeScript and the size on disk. A journal
line an event (each model call with the seconds it took, the estimated size of the
transcript sent and the tools it asked for; each command with its exit and seconds; each
gate) is what a person follows during the hours, and what says where a run went wrong.
`evals/long-task.feature` is the feature: a short scenario that proves the pipe in minutes,
and one that asks for a whole program.

This is the standard this subsystem exists to make possible, and it is worth stating as a
claim rather than a feature: **an agent's effectiveness is the rate at which it does what
its own documentation says it does.** The yardstick was written in prose by the person who
wanted the behaviour, before the agent existed, and it is the same text that documents it.
Nothing was written to be an eval, so nothing was written to be passed.

### No model judges anything

The `Then` lines are the same deterministic assertions in both modes. This repository does
not run checking standards and does not judge an output with a model (ruled 2026-09-07),
and an eval that scored a run by asking a model whether it went well would be exactly that.
What is nondeterministic here is the system under test; the scoring is a string comparison
and a count, and it would give the same answer if a person did it by hand.

### What changes between the two modes, and what cannot

The world half of the given phase — `fs`, `sh`, `clock`, `ask`, `skills`, `ledger`, `mcp`,
the budget — **applies in both**. An eval that let the agent touch a real disk would not be
repeatable and would not be safe, and a real model driving real tools against real files is
not an eval, it is production.

The two given expressions that script the model — `the model calls {word} with {value}` and
`the model answers {string}` — **are dropped in eval**, because a real model is answering.
Which has a consequence a person has to be told about rather than discover:

* a scenario whose expectations only make sense against a scripted model is **not
  evaluable**, and the runner says so with the line that made it so, rather than scoring it;
* the assertions that survive contact with a real model are the ones about *outcome* —
  `it stops with`, `the file {string} holds:`, `nothing is written`, `the call to {word} is
  refused`, `the human is asked about {word}` — and the ones about an exact call
  sequence generally do not. That is not a defect in the vocabulary. It is the feature file
  telling a person which of their expectations were about the agent and which were about
  the transcript they imagined.

Evaluability is computed, not declared, so nobody has to remember a tag. A scenario may opt
out with `@verify-only`, and that is the only tag this runner reads.

### Then lines that read the script

(Amended 2026-09-12, from the showcase run against a real model, `docs/ergonomics.md`.)
A scenario may be evaluable and still be about its transcript: `it calls colour 2 times`
after two scripted calls, `it answers "dark red"` after `the model answers "dark red"`,
a `the store {word} holds:` table whose cells the scripted arguments put there. Against
a real model such a line fails for a reason that is the scenario's, not the agent's, and
the eleven showcase scenarios of that kind had to be tagged by hand. The runner now says
which lines those are, as a fact about the file rather than a judgement about the agent:

* a Then line **reads the script** when a value it checks — a quoted string, a bare word
  that is not a tool's or a store's name, a cell of its table, its doc string — appears
  in the scenario only in a dropped model line, and nowhere in the When, in a world
  Given, or in the declaration's names; or when it counts calls to a tool and the count
  is exactly the number the script made;
* the scenario is still scored. Its report carries `reads_script`, one entry a line with
  the line number and the model line it reads, and the rendering says `reads the script:`
  under the rate, so a 0 of 3 comes with its diagnosis on the same screen;
* a scenario every one of whose Then lines reads the script is still scored, and the
  report says every line does: `the call to add answers "42"` after `the model answers
  "42"` reads the script by this rule and holds against a real model that adds, so a
  scenario is never set aside on a label. (Amended while building it: the first draft made
  such a scenario not evaluable, and the showcase's `add` and `shout` scenarios showed
  the label is a fact about the file and the pass is a fact about the agent.)

The rule is computed from the lines, the declaration's names (tools, arguments, stores,
columns, beats) and the declaration rendered as its own Background (`src/say.lua`, so a
tool's fixed answer is said by the declaration and not only by the script), never from
the text of a prompt read as English. It labels; `@verify-only` decides. An author who meant the exact
answer keeps the line and tags the scenario; one who meant the behaviour writes `the
answer says` and drops the tag.

### The report

Per scenario: samples, passes, the rate, and every failing sample kept whole — its result
and its trace (`spec/trace.md`), which is what makes a failure diagnosable instead of
merely counted. Per feature: the rates, and the scenarios that could not be evaluated.

Beside every rate, its 95% Wilson interval (`behaviour.interval(passes, samples)`, kept on
the scenario as `interval`; added 2026-09-12, `docs/confidence-plan.md` item 1): `3/3`
prints as `3/3 (0.44-1.00)` and `9/10` as `9/10 (0.60-0.98)`, so a reader sees what three
samples cannot say. Two rates are different only when their intervals do not overlap.
`scripts/eval.lua` takes `--seed N`, written into its report and its `--out` file as the
run's label (the model port sends no seed today: OpenRouter's answer for one is not a
promise, and the label is what lets two runs a week apart be told apart), and
`scripts/eval-all.lua` runs every eval file that names a real model at one sample count,
in parallel batches of `scripts/eval.lua` processes, and merges the reports into one dated
file under `docs/evals/`, with the date, the models, the seed, the intervals per scenario
and per model, and every failure's reason.

A rate is reported as a fraction of the samples that ran and never rounded up to a
sentence. There is no threshold in this tree, no pass mark and no grade: what rate is good
enough is a decision about a product, and a harness that picked one for you would be making
it silently.

### The trace is the join

Every scenario opens a `malleable.scenario {name}` span and everything the run did hangs
under it, so a trace in a collector is attributable to the sentence in the feature file
that asked for it. That is the whole reason the two specs were written in one epic: without
the feature there is nothing to attribute a trace to, and without the trace a failing rate
says a thing is broken without saying where.

## What it must NOT do

* Put a model between a feature and the declaration it states. Since 2026-09-11 a feature
  may say what the agent is (`spec/declare.md`), and it says it in a closed vocabulary that
  compiles deterministically to the table `agent.*` builds; the argument this bullet carried
  -- that a generator turning prose into a declaration would make the test as reliable as the
  model -- is kept, and is why the is lines are expressions and never read as English.
* Reach a real port under `--verify`. There is no door to one. `--eval` reaches exactly
  one — the model — and reaches it through the host, which is the only thing that has a
  model to give; the filesystem, the shell, the clock and the gate stay doubles in both
  modes, and no flag opens them.
* Let a `Then` line mutate anything.
* Guess at an undefined step, fuzzily match one, or drop one.
* Print. The module answers with a table and a renderer.

## The tests that would prove it

* each of the forty-three expressions, once, matching and building or reading what it says;
* a given context has no `result`; a then context's world raises on a write, by name;
* a declared step in the `given` slot cannot see a result, and one in `then_` cannot write;
* a declared step colliding with a built-in is refused, naming both;
* a scenario with two `When` lines is refused at load; with none, refused at load;
* a Given after a Then is refused, naming both lines;
* an undefined step yields `undefined` and skips what follows, and the report carries the
  stub;
* a step body that raises is `broken`, not `failed`, and the report keeps them apart;
* an all-undefined feature exits non-zero;
* `check` finds each of its seven problems, with a line number, and touches no port;
* `example/reviewer.feature` drives `example/reviewer.lua` end to end and passes — the
  worked example, stated in prose, executed;
* an eval drops the two model-script given lines and keeps the other ten;
* a scenario that is not evaluable is reported as such, naming the line, and is not scored;
* a rate over a scripted model that always does the right thing is 1, and over one that
  never does is 0, with every failing sample's result and trace kept;
* `@verify-only` is skipped by an eval and run by a verify;
* a Then line whose value only a dropped model line says is labelled `reads_script` with
  both line numbers; one whose value the When, a world Given or the declaration says is
  not; a count is labelled only when it is the script's; and a labelled scenario is scored;
* everything above under `lua` and under `luajit`.
