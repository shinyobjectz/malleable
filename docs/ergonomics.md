# Authoring an agent: the Gherkin, the Lua, and how they check each other

What it is like to write an agent in this tree today, in the feature language and in the
Lua prefix; what the agents that authored (the console's author, the long-task builder,
the showcase's author) ran into; what is confusing, what could be easier, and what could
be more open than it is. Written 2026-09-12 from the evals (`docs/eval-report.md`), the
showcase (`docs/showcase.md`) and the day's fixes. Ticket mar-nbpt.

## The two surfaces, side by side

| | the feature file | the Lua prefix (`agent.*`) |
| --- | --- | --- |
| who it is | `the agent is called`, `its model is`, briefing, budget, reasoning, trust | `agent.name`, `.model`, `.system`, `.budget`, `.reasoning`, `.trust` |
| reach | `it reads the workspace`, `never touches`, `runs commands`, `keeps a plan`, `can read its history`, `hands work to`, `uses the server`, `edits agents in` | `agent.files { deny = ... }`, `.shell { timeout_ms }`, `.plan`, `.history`, `.delegate`, `.uses`, the authoring kit |
| tools | a table of arguments; one body line: Lua doc string, `answers`, `adds a row to`, `lists`; `asks first`, `requires`, `may be called at most`, `shows its call` | `agent.tool "x" { about, args, run, ask, preview, requires }` |
| stores, skills, beats, steps | one line each, tables and doc strings | `.store`, `.skill`, `.every`, `.step` |
| hooks on the run | not sayable (`declare.UNSAID`) | `agent.on "call" (fn)` |
| policy | `may always call`, `may never call` | `.allow`, `.deny` |
| extending the vocabulary | `the step "..." sets up:` in Lua; `@shorthand` in Gherkin | `agent.step` |
| checking | scenarios in the same file, `--verify` | scenarios in a feature file run against the program (`--feature x.feature agent.lua`) |
| self-edit | `edit`, `propose`, `verify`, walled by reach | none |
| mixing | | `agent.declare(text)` applies a feature's Background onto the prefix |

The two compile to the same declaration (`test/declare_test.lua`,
`a_feature_and_the_lua_it_replaces_compile_to_the_same_declaration`), and every tool body
is Lua in both. So the honest description is: **the feature file is Lua with a vocabulary
around it**, where the vocabulary is closed, versioned, reach-scored and readable by the
runner, and the Lua is the part that does things. What the feature buys is that the
runner can read, verify, score and wall every line; what the Lua buys is hooks, host
configuration and being plain code.

## What the authoring agents ran into

Every item here is from a run, not a guess.

**The author (self-edit, GLM 5.3), from `evals/author.feature`.**

* It wrote `@proposed` above the scenario it sent, because that is what the file shows;
  the tool refused the text for not starting with `Scenario:`. Now tolerated.
* Asked to add a narrowing line, its first move was `add` with the *existing* line as
  `line` and the new one as `with`: the shape of `replace`, sent to `add`. The tool added a
  duplicate and ignored `with`. Now refused with the right op named.
* Having made a duplicate narrowing line, it could not remove it: removing a narrowing
  line widens. Duplicate adds are now refused, so the trap is closed, but the rule that
  produced it is real and worth knowing: **an author can narrow freely and can never
  widen back without a person**, even to undo itself.
* It wrote `Given the file "x" contains "text"` inline, where the vocabulary has only the
  doc-string form. `verify` said so and it rewrote. Two to four steps a sample went on
  learning shapes like this before the first edit that applied; after the tolerances,
  from 9 to 19 steps down to 4 to 8.
* After a person refused a widening through `propose`, in one sample of five it tried
  the same line through `edit`. The wall turned it back. The behaviour is the model's;
  the wall's job is to make it harmless, and it did.

**The builder (a real shell, from `evals/long-task.feature`).** Nothing about the language:
it never touched the feature file. It was told once what it was, in eight lines, and
built a 2 000-line program. The one thing it did against its briefing was `cd /tmp` to
try the CLI, which the shell allowed. The lesson is for the Given side: a briefing is
prose and a `never touches` is a wall, and only the second holds.

**The showcase's author (me, nineteen files), from `docs/showcase.md`.** Ten of nineteen
files failed on the first run. Sorted by what they were:

| kind | count | examples |
| --- | --- | --- |
| harness holes (fixed) | 7 | skill tool, gate, servers and edited-at-the-gate arguments absent from verify runs; a server line that could never match; refused commands counted as run; no line for an empty strike |
| rules I did not know | 6 | an is line only in the Background; one When a scenario; no tools means no run; the gate is reached only by a tool that asks; edits at the gate are choices, numbers and booleans; a wrong Background is fatal to the file |
| phrasing | 4 | `it never runs a command that` is not a line (`runs no command that` is); `the call to X fails` is not how a files or shell refusal reads (they answer sentences, so `the call to X answers "..."`); an exact `it answers` where `the answer says` was meant; `{value}` in a shorthand with a `<param>` in a number's place |
| script and reality | many | a scenario whose Then lines describe the scripted transcript rather than the agent cannot pass against a real model, and nothing said which kind I was writing |

## Where the feature language is confusing, and what would make it easier

1. **Two kinds of scenario wear the same clothes.** A scenario with `the model calls read
   with {...}` is a unit test of the declaration: the transcript is the point. A scenario
   with only `When the agent is asked` and behavioural Then lines is an expectation of
   the agent. The runner drops the script in an eval and keeps the Then lines, so a
   script-shaped scenario fails against a real model for reasons that are the scenario's.
   `@verify-only` exists for exactly this and nothing tells an author about it; I found
   it in `behaviour.lua`. Better: the runner infers it, and says so: a scenario whose Then
   lines name a call the script made (`it calls colour 2 times`, `the call to open
   fails` after a scripted bad path, `the file holds:` a scripted text) is script-shaped,
   and the eval reports it as "not evaluable: its Then lines read the script" rather
   than 0 of 3. The showcase now tags eleven scenarios by hand; the rule could be the
   runner's.
2. **Refusals read three ways.** The gate refuses (`the call to X is refused`), a files or
   shell tool answers a sentence (`the call to X answers "out of reach"`), a body raises
   (`the call to X fails`), and the authoring tools answer `not applied:` or `refused:`.
   Each is right on its own terms (the model must read every one of them), but an author
   has to know which tool refuses how. One line that reads all of them, `the call to X
   does not go through`, with the report saying which way, would take the guessing out.
3. **`{word}` reads to the next space**, so a line cannot put a comma after a name. Two
   built-in lines were unmatchable until someone tried them (the delegate line, then the
   server line). A `{word}` that stops at punctuation would close the class; today the
   rule is a note in the spec.
4. **What is fatal and what is a result is not visible from the file.** A wrong
   Background stops the whole file at load with exit 2; a wrong Given line is a failed
   step; a tool with no body is fatal; a body that reaches for `io` is a failed call at
   run time. `the declaration is refused because` suggests a wrong Background could be a
   scenario, and it cannot. A `# expect: refused "..."` first line (what
   `scripts/showcase.lua` now honours) is a small fix; a `Scenario:` that may state its
   own Background's refusal would be the proper one.
5. **The gate is reached only by a tool that asks**, so `it may never call shred` on a
   tool that does not ask is inert, and the live runner warns while the verify runner
   was silent (and applied no policy at all until today). Either a deny should make a
   tool ask, or a deny on an unasking tool should be refused at load, by name. The
   warning is the weakest of the three.
6. **The vocabulary is the runner's, and the runner's alone.** `it runs a command that
   tests` reads the command through a table of programs that is partial on purpose; an
   author whose model runs `npx vitest` learns that from a failing line. The table is
   the right design (a term is checkable, a regex is not), and it wants a line an author
   can read: `the runner names the command "npx vitest run" as tests`, so a feature can
   state, and be refused on, what its own commands mean.
7. **An agent with no tools cannot run**, which is right for a run and wrong for a beat
   or a server file, where the tools come from the world. The showcase carries a spare
   tool in two files to get past it.
8. **A shorthand cannot carry the model script**, because `{value}` is read as JSON at
   definition and `<times>` is not a number. Shorthands of Then lines are the useful
   ones anyway; the refusal message could say why.
9. **Prompts in a scenario must give a real model a reason.** "what is the venue?" made a
   delegating agent read the file itself, which is the better answer; "hand this to your
   helper" made it delegate. The doubles do not care what the prompt says; the eval does.
   That is a rule for authors, and it belongs in the spec beside `@verify-only`.

## Where the Lua prefix is confusing, and what would make it easier

* **There is no runner for a Lua-only agent's tests but a feature file.** That is a
  strength in disguise: it means every Lua agent gets the same vocabulary and the same
  report. But an author who wants a scenario against a Lua tool has to write Gherkin,
  and the feature has to name the program (`--feature x.feature agent.lua`).
* **`agent.on` is the one thing Gherkin cannot say**, and it is the widest thing there is:
  a hook sees every call. That is the right line to draw, and it means an agent with a
  hook can never be fully rendered as a feature, so its self-edit surface is smaller.
* **The surface is closed** (`cli.surface`, fifteen names) and a body sees a fixed
  sandbox. Anything else is a kit in `src/` (files, shell, plan, history, delegate,
  authoring, mcp), and adding a kit means editing `declare.lua`'s is table, `kits.lua`,
  the reach scoring and the spec. That is the extensibility ceiling today.
* **Errors are sentences, and the good ones name the fix** (`a tool with no body: say
  what it does (does:, answers, adds a row to or lists)`). The Lua side raises with the
  same sentences. This is the part that already works.

## More extensible than today: three moves

1. **Kits as a contract, not a file.** A kit is what `files`, `shell`, `plan`, `history`
   and `mcp` already are informally: a table of is lines (expression, what it covers,
   which way it moves reach), the tools they install, the Given lines that script its
   world, the Then lines that read it, and the doubles for it. Write that contract down
   (`docs/spec/kit.md`), make `declare` and `behaviour` load kits from a list, and a
   workspace can add `it keeps a calendar` with its own tools, doubles and reach scoring
   without touching `src/`. The reach scoring is the part that must stay the harness's:
   a kit says which way each of its lines moves reach, and the wall reads that.
2. **Shorthands and steps as the first extension, kits as the second, Lua as the last.**
   Today the ladder is real but unnamed: a domain line in Gherkin (`@shorthand`), a
   domain line in Lua (`the step ... sets up:`), a whole capability (a kit), a hook
   (`agent.on`). Naming the ladder in the docs, with the rule that each rung is scored
   by reach and the last rung is not sayable, tells an author where a change goes.
3. **MCP as the open door for tools, already.** `it uses the server X with:` reaches
   another process and asks by default. For tools, this is the extension point that
   needs no code in the tree; it wants only the doubles line to be usable (it was not,
   until the comma went).

## Both at once, and each checking the other

You will want both, and they already meet in four places; two more would make them
check each other on purpose.

**What exists.**

* **Gherkin gates Lua.** A feature file's scenarios run against a Lua program
  (`--feature x.feature agent.lua`), on the doubles, in CI. The Lua is the
  implementation; the feature is the contract a person reads.
* **Lua hosts Gherkin.** `agent.declare(text)` applies a feature's Background onto a Lua
  prefix, so a Lua file can hold the hook and the host configuration, and say the rest in
  the vocabulary, where the wall can score it.
* **Runs become Gherkin.** `observe` writes a feature from a run (the store, the edit,
  the unmet requirement), so a Lua-authored agent's behaviour comes back as a file the
  runner can replay.
* **The same declaration.** The equivalence test proves a feature and the Lua it replaces
  compile to one declaration, so nothing is lost in either direction for what the
  vocabulary covers.

**What to build.**

1. **`--say`: render a declaration as Gherkin.** For a Lua agent, print the Background
   its declaration amounts to, line for line in the is vocabulary, and after it the list
   of what could not be said (`agent.on`, a `requires` function, a port-specific
   option). Then the author agent can edit that rendering under the wall, the runner can
   verify it, and the Lua keeps the bodies. A Lua change that changes the rendering is,
   by definition, a change of reach, and the same scoring applies. This is the concrete
   way the Gherkin gates the Lua: **no Lua edit lands whose rendered is lines widened
   without a proposal.**
2. **`--conforms a.lua a.feature`: the drift check.** Load both, compare the declarations
   (`spec.schema` and the is lines), and report the difference in vocabulary words:
   "the Lua declares a tool `verdict` that asks first; the feature says it does not."
   Run it in CI beside `--verify`. The feature is then the reviewed contract, the Lua the
   implementation, and drift between them is a failing check with a sentence, not a
   surprise in production.

With those two, the machine is: write bodies and hooks in Lua; say what the agent is in
Gherkin; let the author agent propose changes to the Gherkin under the wall; let the
runner verify the Gherkin against the Lua on every change; and let a real-model eval of
the same file, with its script-shaped scenarios set aside, be the number.

## What the real model said about the showcase

Nine of the nineteen files, three samples a scenario, GLM 5.3 standing in for
`test:model` (`--model`). Script-shaped scenarios are tagged `@verify-only` and reported as
not evaluable rather than failed.

| file | scenarios evaluated | at 3/3 | below | why |
| --- | --- | --- | --- | --- |
| 02 tools | 3 | 3 | | |
| 03 gates | 4 | 4 | | |
| 04 stores | 2 | 1 | 1 | the model gave ale a tag the ask did not; an exact rows table is a script-shaped check |
| 05 files | 1 | 1 | | |
| 06 commands | 2 | 2 | | the two that need one scripted command line are verify-only |
| 07 skills | 5 | 3 | 2 | with the skill's `about` in the briefing and the workspace readable, it answered from the catalogue or opened the file rather than calling `skill`; not wrong |
| 10 shorthands | 0 | | | both script-shaped |
| 11 delegates | 2 | 2 | | after `--model` reached the delegate too |
| 13 policy | 2 | 2 | | |

The lesson those numbers carry is item 1 above: the same file runs both ways only when
its Then lines say what must hold whatever the model does.
