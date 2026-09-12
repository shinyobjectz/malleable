# declare — an agent written in Gherkin, and edited there

`src/declare.lua`, the toolkits it shares with the prefix in `src/kits.lua`, and the
authoring tools in `src/authoring.lua`. Contract, written before the code on 2026-09-11 and
amended the same day where building it showed the first draft wrong (each amendment is
said where it happened).

## What it is for

Until now an agent was two files: a Lua declaration of what it **is** and a Gherkin feature
of what it **does**. The feature was the half a person reads, argues about and approves;
the declaration was the half only someone who reads Lua could change. So the one thing an
agent could not do in the language it is judged in was change itself, and the one thing a
person could not do without Lua was give it a tool.

This spec makes the feature file the whole agent. What it is goes in the `Background:`, in
a closed vocabulary of its own, and compiles to exactly the table `agent.*` builds; what it
does stays in the scenarios. One file, one language, and the same file is what an agent
edits when it improves itself, writes when it builds another agent, and extends when it
needs a line it does not have.

    Feature: greeter
      Says hello to whoever it is asked to.

      Background:
        Given the agent is called greeter
        And its model is "openrouter:z-ai/glm-5.3"
        And it has a tool greet for "Say hello to someone.", which takes:
          | argument | type   | about        |
          | name     | string | who to greet |
        And the tool greet does:
          """lua
          return "hello, " .. c.args.name
          """

      Scenario: it greets
        Given the model calls greet with {"name": "ada"}
        And the model answers "I said hello to ada."
        When the agent is asked "greet ada"
        Then the call to greet answers "hello, ada"

The worked examples are `example/greeter.feature`, `example/counter.feature` (a store, a
body in Lua, a body that is a line, a call limit, a shorthand), `example/desk.feature` (an
agent that hands work to another) and `example/builder.feature` (an agent that builds and
edits agents, inside the wall below).

## Vocabulary

Checked with `monty onto check` before use. `declare`, `shorthand`, `reach`, `proposed`,
`authored`, `widen` and `narrow` were free.

* the **is phase** is the fourth phase, before given: a line that says what the agent is.
  The phase names stay lower case in prose (`spec/behaviour.md`).
* an **is line** is a step in that phase.
* a **shorthand** is a step that stands for other steps, written as a scenario tagged
  `@shorthand`. Not a *phrase*: this repository's rulings use phrase for literal prose, and a
  shorthand is a formal expression over a closed vocabulary.
* **reach** is what an edit does to what the agent can do: it **widens** (a new tool, a body,
  a server, a beat, a wider workspace), **narrows** (a gate added, a limit, a glob refused),
  or neither.
* **authored** and **proposed** are `spec/change.md`'s split, on scenarios: authored ones a
  person wrote or accepted, proposed ones an agent wrote and nobody has accepted yet.

## The is phase

Is lines live in the feature's `Background:` and nowhere else. An is line inside a
scenario, a rule's background or a shorthand is refused with its line number: what an agent
is, is said once, and a declaration that varied by scenario would make every scenario a test
of a different agent.

Is lines come before the Background's given lines. The phase order is is, given, when,
then, and the keyword does not decide the phase: the expression does, as it always has. In
a file that has is lines, a Background line that is neither an is line nor a line a scenario
can read is refused at load with its line number. (Amended: the first draft read such a line
as undefined, and building the delegate example showed a typo in a declaration then surfaces
as a tool that silently is not there.)

`declare.apply(text, a, opts)` applies the is lines to the agent table `a` — a fresh
`spec.new()`, or one a Lua declaration already wrote — and answers a table about the file,
or `nil` and a sentence; it never raises on a bad file. `declare.pickles(text, decl)`
answers the scenarios a runner walks, with the is lines taken out and the shorthands
expanded. `agent.declare(text)` is the same apply as a declaration statement on the prefix,
raising with the line as every other statement does.

Nothing is run. Rule 2 holds for a feature file as it holds for a Lua one: the is lines are
applied through `cli.surface` and `src/kits.lua`, and a Lua body in a doc string is
compiled, never called. The lines are gathered into a plan before anything is declared, so
they are order-free where order means nothing: `the tool verdict asks first` may come before
or after the line that declares verdict.

## The is vocabulary

Closed, versioned as `declare.VOCABULARY = 1`, rendered into `docs/STEPS.md` with the other
three phases, and each line marked with which way it moves reach. `{word}` is a name, bare;
`{string}` is text, quoted. A `{word}` reads a run of non-space characters, so no line puts
punctuation straight after one. (Amended: `it hands work to {word}, the agent in ...` read
the comma as part of the name.)

### who it is

| | declares |
| --- | --- |
| `the agent is called {word}` | `agent.name` |
| `its model is {string}` | `agent.model` |
| `its reasoning is {word}` | `agent.reasoning`: none, low, medium, high |
| `it may take {int} step(s)` | `agent.budget` |
| `it is briefed:` + doc string | `agent.system` |
| `its trust is {word}` | `agent.trust`: trusted, ask, none |
| `it may always call {word}` | `agent.allow` |
| `it may never call {word}` | `agent.deny` |

### what it can reach

| | declares |
| --- | --- |
| `it reads the workspace` | `agent.files`, read only |
| `it reads and writes the workspace` | `agent.files` |
| `it never touches {string}` | a glob the files tools refuse |
| `it runs commands` | `agent.shell`, which asks on its own account |
| `each command may run {int} second(s)` | the shell's timeout |
| `it keeps a plan` | `agent.plan` |
| `it can read its history` | `agent.history`: history, recall and evidence (spec/history.md) |
| `it hands work to the agent in {string} as {word}` | `agent.delegate`, over the agent that file declares |
| `it uses the server {word} with:` + table | `agent.uses`, one `key | value` row per field |
| `it edits agents in {string}` | the authoring tools, below |

A delegate's file is read at load through the `read` a host passes (the runner reads it
beside the feature), and one that hands work to itself, however far round, is refused.
`declare.apply(text, a, { model = id })` puts one model in place of the file's and of every
delegate's under it, which is how `scripts/eval.lua --model` runs a file written for the
doubles against the real model unchanged (2026-09-12). Its
child runs in **the world its parent was given**: the same files, the same gate, the same
model. `declare.enter` and `declare.leave` hold that world for the length of a run, and they
are called by whoever starts a run — `agent.run`, the runner — never by a tool body, which is
handed a context without the model or the gate (rule 4). In a scenario the one scripted
model therefore speaks for parent and child in order, which is what `example/desk.feature`
states.

### its tools

| | declares |
| --- | --- |
| `it has a tool {word} for {string}` | a tool with no arguments |
| `it has a tool {word} for {string}, which takes:` + table | and its arguments |
| `the tool {word} is for {string}` | the `about` of a tool declared elsewhere: a kit's, or the Lua's |
| `the tool {word} asks first` | `ask = true` |
| `the tool {word} asks first, letting the person change {word}` | `ask = { edit = ... }` |
| `the tool {word} always asks first` | `ask = "always"`: trust and an allow policy do not waive the question; a gate line (2026-09-12) |
| `the tool {word} shows its call before it runs` | `preview = true` |
| `the tool {word} requires {string}, checked by:` + doc string | a requirement; the doc string is its check |
| `the tool {word} may be called at most {int} time(s)` | a call hook that refuses the call past it, counted per run |
| `the tool {word} does:` + doc string | the body, in Lua |
| `the tool {word} answers {string}` | a body that answers this |
| `the tool {word} adds a row to {word}` | a body that adds its arguments as a row |
| `the tool {word} lists {word}` | a body that answers every row, one per line |

An argument table has three columns, `argument`, `type` and `about`. A type is `string`,
`number`, `boolean`, `table` or `list`, or `one of a, b, c`, each optionally preceded by
`optional`. That is `spec.types`, in words. A tool declared here has exactly one body line;
one with none is refused at load, naming the tool. A tool declared elsewhere keeps its body,
and the lines above other than a body may still be said of it.

### what it keeps

| | declares |
| --- | --- |
| `it keeps a store {word} of {string}:` + table | `agent.store`; columns as `column | type | about` |
| `the store {word} is sorted by {word}` | its sort, in the order the lines come |
| `it keeps a skill {word} for {string}:` + doc string | `agent.skill`, the procedure as text |
| `it keeps a skill {word} for {string}, in {string}` | `agent.skill`, read from that path |

### when it runs by itself

| | declares |
| --- | --- |
| `the beat {word} comes every {int} second(s) and asks {string}` | `agent.every` |
| `the beat {word} comes every day at {string} and asks {string}` | `agent.every`, at a clock time |
| `the beat {word} runs once per {word}` | `once_per`: hour, day, week, ever |

### its own kits

| | declares |
| --- | --- |
| `it uses the kit {string}` | loads the kit file at that path; its lines join the is vocabulary for the process (`docs/spec/kit.md`) |

A kit's own lines are read after every kit line in the Background, whatever their order,
and carry the reach the kit gave them. Added 2026-09-12.

### its own steps

| | declares |
| --- | --- |
| `the step {string} sets up:` + doc string | `agent.step` with a `given` body in Lua |
| `the step {string} checks:` + doc string | `agent.step` with a `then_` body in Lua |

and shorthands, below, which need no Lua at all.

### What the Gherkin cannot say, and why

`declare.UNSAID` lists it, and today it holds one entry: `agent.on`. The other direction,
a declaration said back as its Background with the unsaid named, is `docs/spec/say.md`. A hook is code that
watches a run, and the one thing a hook does to a run, refusing a call, is
`the tool {word} may be called at most {int} time(s)`. Every is expression names the entry
point it `covers`, and `test/declare_test.lua` fails when a key of `cli.surface` or a
toolkit on the prefix is neither covered nor listed.

## Lua in a doc string

A body, a requirement's check and a step's body may be Lua, in a doc string whose fence may
say `lua`. The text is the body of a function of `c`, the context `spec/turn.md` describes.
It is compiled with what a declaration gets from `cli.sandbox`, minus `agent`: `pairs`,
`ipairs`, `next`, `select`, `type`, `tostring`, `tonumber`, `error`, `assert`, `pcall`,
`xpcall`, `unpack`, and copies of `math`, `string` (without `dump`) and `table`. Any other
name raises when the body runs, by name (`io is not here: a body reaches the world through
c`), and so does setting a global, because a body that thinks it is keeping state across
calls has a bug. A doc string that does not compile is refused at load with its line and
Lua's message; one holding an escape byte is refused before it is compiled.

This is still code, and the harness treats it as code: adding or changing a body widens
reach.

## Shorthands: the vocabulary in Gherkin

`agent.step` extends the vocabulary with a Lua body. A shorthand extends it with Gherkin: a
scenario tagged `@shorthand` whose name is the new line and whose lines are what it means.

    @shorthand
    Scenario: it has counted <thing> <times> time(s)
      Then the store counts holds:
        | name    | n       |
        | <thing> | <times> |

    Scenario: two teas are two
      ...
      Then it has counted tea 2 times

A `<name>` in the title is a parameter. Written bare it reads a `{word}`; written inside
quotes, `"<name>"`, it reads a `{string}`. `(s)` is optional text, as in every expression.
Each use substitutes what it read wherever `<name>` appears in the lines, doc strings and
tables included, exactly as a `Scenario Outline:` substitutes a row.

Refused at load, each with a line number:

* a shorthand of when lines: the three ways a run starts are the harness's (rule 6);
* one whose lines are in more than one phase, or match nothing;
* one that reads the same lines as a built-in, an is line, a declared step or another
  shorthand;
* one that reaches itself, however far round; nesting stops at eight deep;
* a `<name>` its title does not have, and a name with `/`, which an expression reads as a
  choice.

Shorthands are expanded before the runner sees a pickle, so `behaviour.lua` is unchanged: a
line that used one reports its own line number.

## Editing the file

An agent changes itself, builds another agent and extends its vocabulary by the same act:
an **edit** to a feature file. `declare.edit(text, op)` applies one and answers the new text
and `{ reach, why }`, or `nil` and a sentence — with a third return, `"wall"`, when the edit
crossed the wall rather than being malformed. It edits the file as written: comments,
spacing and every line it was not asked to touch come back byte for byte, and an add
followed by its remove gives the file back exactly.

    { add = "the tool verdict asks first" }              an is line, after the last one
    { add = "...", doc = "...", rows = { ... } }         with its doc string or its table
    { remove = "it runs commands" }                      an is line, by its text
    { replace = "it may take 12 steps", with = "it may take 16 steps" }
    { scenario = "Scenario: ...\n  Given ..." }          a new scenario, tagged @proposed
    { shorthand = "Scenario: ...\n  Then ..." }          a new shorthand, tagged @shorthand
    { withdraw = "a scenario's name" }                   a proposed scenario, removed

An edit makes one change, so every change can be attributed to one cause, and what it
answers must still read with its is lines in their place. A replace that gives no doc string
or table keeps the old line's.

Three tolerances, each found by `evals/author.feature` (2026-09-11), where the model wrote
what it would see rather than what the tool asks for: an add of a line the Background
already says is refused as nothing to add (the model had added the line it meant to
replace, and a duplicate narrowing line can then not be removed without widening); an add
sent with `with` is told the op is replace, rather than adding `line` and dropping `with`
unread; and a scenario written with its own `@proposed` or `@shorthand` tag, on a line of
its own or ahead of the keyword, has the tag taken off, because the tag is the tool's to put
on and a model that copies the file's shape is not wrong to.

### Reach, and the wall

`spec/change.md` let an agent change three fields and refused the rest by name. That wall was
right about the danger and too narrow to build with: an agent could tune its briefing and
never give itself a tool. The wall now follows **reach**. Each is expression says which way
it moves reach; an add takes its line's direction, a remove the opposite, and a replace the
larger of the two — except a replace that keeps the expression and every name in it, which
takes the line's own `same` (a tool's `for`, a briefing, a budget and an answer change
nothing; a body, a model and a tool's arguments widen). On a narrowing line every argument
counts as a name: `it never touches "secrets/**"` replaced by `it never touches "nothing/**"`
is the old narrowing taken away and another added, which widens and goes through `propose`
(found by evals/wall.feature, 2026-09-11).

| an edit that | for example | an agent may |
| --- | --- | --- |
| changes neither way | the briefing, a tool's `for`, the budget, a shorthand, a proposed scenario | make it with `edit` |
| narrows | a tool asks first, a glob never touched, a limit, a tool removed with the lines about it | make it with `edit` |
| widens | a tool added, a body written or changed, commands, a delegate, a server, a beat, the model, a new agent | make it with `propose`, which asks the person first |
| crosses the wall | an `asks first` taken away; an authored scenario withdrawn | never; refused by name |

Three things about this are decisions.

**A gate only closes.** An agent may add `asks first` to any of its tools and may never
remove one, whoever is at the gate and whichever tool carries the edit. A person who wants a
tool to stop asking edits the file themselves. This is `spec/change.md`'s `ask` rule, kept
exactly: an agent that can edit its own gate has no gate.

A line that takes a doc string is found with or without its colon (`it is briefed` names
`it is briefed:`), and a replace of it sent without `with` is told to send the same line
as `with` and the new text as `doc` (both added 2026-09-12 from the refusal list at nine
samples, `docs/evals/2026-09-12-briefing.md`).

**Widening goes to the person, not to a score.** A better rate is not a reason to reach
further. `propose` is an ordinary tool with `ask = "always"` (amended 2026-09-12: it was
`ask = true`, and under `its trust is trusted` the gate answered its question itself, so
every widening the person had refused was written; found by the trusted attack run and
stated in `evals/wall-trusted.feature`), so the harness's own gate is put the question
before the body runs (rule 4), trust and an allow policy do not answer it
(`docs/spec/approval.md` §2.3), and a refusal is a result the agent reads.

**The test is the person's.** An agent's scenarios are tagged `@proposed` and are not
scored; a new file's scenarios are tagged on the way in. A person accepts one by removing the
tag. There is no edit that changes an untagged scenario or an existing shorthand — changing
what a line means is changing the test — and `withdraw` refuses an authored scenario by name.

### The scoring gate

Every edit is scored before it is written, and this is what the builder example found on its
first run: adding a gate is a narrowing edit, and it was refused, because the person's own
scenario greeted with nobody at the gate. An edit is written only if the file still loads and
its **authored** scenarios pass at least as well on the doubles as they did — no new failure,
no new undefined line, no fewer passing. That is gate two of `spec/change.md`, applied to a
file. Gate one (the rules) and gate three (no behaviour lost from an eval's repertoire) stay
the change loop's, because they need a host's script and a real model.

## The authoring tools

`it edits agents in {string}` gives an agent six tools over the feature files under one
folder, reached through its `fs` port (`src/authoring.lua`):

| tool | does | asks |
| --- | --- | --- |
| `features` | lists the feature files under the folder | no |
| `feature` | reads one, with line numbers | no |
| `vocabulary` | every line a file may hold, by phase and reach, and one file's shorthands; with `phase` (is, given, when, then), only that phase's lines (added 2026-09-12: a model choosing an is line reads about half of the whole, 4.9 KB of 9.8) | no |
| `verify` | runs one file's scenarios on the doubles; authored and proposed counted apart | no |
| `edit` | one edit that widens nothing, scored, then written | no |
| `propose` | one edit that widens reach, or `create`, a new agent, scored, then written | **yes** |

(Amended: the first draft had one `edit` tool that would put a widening edit to the person
itself. A tool body cannot reach the gate — rule 4 withholds it — and a second tool with
`ask = true` is how the harness already asks.)

`authoring.verify(text, fs, dir)` is the same run as the `verify` tool, answered as data:
one entry a scenario with its name, outcome, the first reason it did not pass, and whether
it is authored; a host marks an agent's file with it (docs/spec/agent-file.md, amended
2026-09-11).

`create` writes a new file and tags every scenario in it that says nothing `@proposed`. A
path is relative to the folder, a `.feature`, never `..`, never `features/kept.feature` and
never a path the host locks. An agent editing its own file changes the next load, never the
run it is in.

What a model sends is taken as it meant it, at the edge and nowhere deeper: a path with the
folder's own name in front, a line pasted from the numbered view or with its keyword still on,
an is line sent as `text`, and — in text it writes whole — a line an expression reads but that
was left without `Given`, `When`, `Then` or `And`, which gets the keyword its phase calls for.
A new file that says nothing about what an agent is, or describes one that could not run, is
refused with the least file there is. A line that matches nothing is refused naming the is
line it most looks like, as a hint; the line is refused either way.

### The invariant under the wall

"The test is the person's" is checked as an invariant, not a list of refusals: after any edit,
every line of every authored scenario must mean exactly what it meant before — the same text,
read by the same expression, and, where that is a shorthand or a declared step, one that says
the same thing. So a second scenario slipped into a `scenario` edit without its tag, a
shorthand that gives an authored line a meaning it did not have, and a step body written to
define one are all refused with `"wall"`. A scenario an agent adds takes a name no other
scenario has.

## With a real model

Measured 2026-09-11 with `example/builder.feature` run live (`--yes` standing for the person),
in a scratch folder, asked to build a notes agent with a store, an add tool, a list tool and a
scenario, and to fix it until the scenario passed.

| model | steps, time | what came back |
| --- | --- | --- |
| Mercury 2.5, first three runs | 16 of 16, no answer | nothing that loaded; each run found a fix, below |
| Mercury 2.5, fourth run | 9, 10 s | a working agent; its scenario seeded the store and counted a row, calling neither tool |
| GLM 5.3, reasoning low | 17, 28 s | a working agent; its scenario calls `add` and checks the store |
| GLM 5.3, after the keyword fix | 6, 6 s | the same, first time |

What the runs found, and what changed: paths given with the folder's name; lines pasted with
their numbers; `create` accepting a file with no is lines; an unquoted `{string}` reported as
a problem of order rather than as the line that matched nothing; two scenarios in one
`scenario` edit, the second untagged and so authored (closed by the invariant above); lines
written without keywords. Each is now a test in `test/declare_test.lua`. The rates of the
console's three agents against the same model, five samples a scenario, and what those runs
found, are in `docs/eval-report.md`.

Asked to improve itself (its own file inside its folder), Mercury gave itself a plan through
`propose`, raised its own budget through `edit`, and could not make its `edit` tool ask first:
the scoring gate refused, because the person's scenarios say `edit` runs unasked. It then
proposed copies of those scenarios with an approval added, which count for nothing; the wall
held. It named the copies after the originals, which is why a proposed scenario now takes a
name of its own.

**The default model is `openrouter:z-ai/glm-5.3`, with reasoning low** — in the examples, the
programs, the bench solutions, the skeleton a new agent is shown, and the console's builder
(`loop.MODEL`, `loop.REASONING`). GLM reasons on every call, and unset, a reply can be all
reasoning and no answer.

## Running one file

    lua bin/malleable.lua --verify triage.feature
    lua bin/malleable.lua --check triage.feature
    lua bin/malleable.lua triage.feature "what is in the queue?"

`cli.load` reads a `.feature` path as the declaration, and a file a line names beside it. A
`.feature` is its own feature under `--verify`, and `--check` checks its scenarios as well as
its declaration. A `.lua` whose feature beside it says what the agent is is refused under
`--verify`: two declarations of one agent, and the runner will not guess which wins. The
Lua door for the pair is `agent.declare(text)` inside the declaration.

## What it must not do

* Run anything at load. Compiling a doc string is not calling it.
* Read a file at load except through the `read` a host passes.
* Let an is line appear anywhere but the feature's Background.
* Let an edit widen reach without the person, remove an `asks first`, or touch an authored
  scenario.
* Grow a when phase. A shorthand is given or then.
* Read a Background line that matches nothing as anything but a mistake.

## The tests that prove it

`test/declare_test.lua`, 27 tests, under `lua` and `luajit`:

* every is line, in one feature, declaring what its table says;
* `example/reviewer.lua` said in Gherkin compiles to the same name, model, budget,
  briefing, tool order and schema, and the bodies answer and write the same;
* every surface entry point is covered or listed in `declare.UNSAID`;
* an is line in a scenario, an is line after a given line, a Background line that matches
  nothing, a tool with no body and a body that does not compile are each refused with a line;
* a body that names `io` or sets a global raises by name; loading runs no body or check;
* a delegate reads its file and one that hands work to itself is refused;
* a shorthand expands, substitutes a word and a string, nests, and is refused when it
  reaches itself, holds a when line, or reads a built-in's lines;
* each edit keeps every line it did not touch, and an add and its remove give the file back;
* reach follows the lines; removing a tool takes the lines about it and narrows; a gate
  never opens; an authored scenario is the person's; a scenario edit cannot slip in an
  authored one; nothing an agent adds may give an authored line a meaning; a proposed
  scenario takes a name of its own; every line-level problem comes back at once;
* the authoring tools take what a model sends and refuse a file that is no agent;
* the runner verifies `example/counter`, `greeter`, `desk` and `builder`.

`example/builder.feature` is the authoring tools' own test, stated as behaviour: ten
scenarios, one per side of the wall.
