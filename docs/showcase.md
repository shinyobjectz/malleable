# The Gherkin agent DSL, shown one dimension at a time

`showcase/` holds one feature file a dimension of the language an agent is written in
(and `showcase/kits/`, the kit the twentieth loads).
Each file is a complete agent and the scenarios that prove the dimension does what the
spec says, on the doubles (`luajit scripts/showcase.lua`, and `test/showcase_test.lua`
keeps them honest in the suite). Nine of them are also run against the real model
(`scripts/eval.lua showcase/NN-*.feature --samples 3 --model openrouter:z-ai/glm-5.3`),
where the scripted model lines are dropped, the real model stands in for `test:model`, and
the same Then lines are the checks. Ticket mar-nbpt.

## The catalogue

| file | what it shows | proves |
| --- | --- | --- |
| 01 who it is | name, model, reasoning, budget, briefing; the run as a transcript the scenario wrote | a run is exactly the calls and the answer the scenario scripted; the budget is a stop of its own |
| 02 tools | a tool in a table with typed arguments; a Lua body over `c.args`; a fixed answer; `one of` and `optional`; a requirement checked in Lua; a call limit | a bad argument, a failed requirement and a call past the limit are answers the model reads, and the run goes on |
| 03 gates | `asks first`; approve, refuse; `letting the person change` a choice at the gate | a refusal is final and writes nothing; the tool runs with the person's value, not the model's |
| 04 stores | a typed store in three columns, sorted; `adds a row to`, `lists`; rows given and rows stated | rows are typed at the edge, listed in the declared order, and a broken row leaves the store untouched |
| 05 files | read only or not; `never touches` a glob; a file stated after; `nothing is written` | a missing file, a kept path and a climbing path are each one sentence, never a crash |
| 06 commands | `runs commands` with a timeout; what a command answers; commands as terms | `it runs a command that tests`, `runs no command that publishes`; a refused push is not a publish; an unscripted command is named, not silently fine |
| 07 skills and briefing | a skill in the file, one at a path, one the workspace keeps; what a tool tells the model | the model reads a skill through one tool; a missing skill is a sentence listing the ones there are |
| 08 beats | a beat by the second and one at a clock time, `runs once per day`, the ledger, the clock struck | a beat runs when due, two due at once are two runs, one that ran today is held, and before its time nothing is due |
| 09 own steps | a given step and a then step in Lua, with `c.args`, `c.world`, `c.result`, and `(s)` | a workspace says its own domain lines and they read and write the same world |
| 10 shorthands | `@shorthand` scenarios with word and string parameters, one using another | the vocabulary grows in Gherkin with no Lua |
| 11 delegates | `hands work to the agent in` another file; the gate on the delegate | the child answers in the parent's world; the scripted model speaks for both in order; the person's no holds |
| 12 servers | `uses the server` in a table; what the server offers at run time; `server_tool` names | a fetched tool asks by default, answers through the port, and refuses like any other |
| 13 policy | `may always call`, `may never call` | an always-allowed gated tool asks nothing; a denied tool is refused whatever the person says |
| 14 outlines | `Scenario Outline` with `Examples` | plain Gherkin substitution into a prompt, a call and an answer |
| 15, 18 refused at load | a tool with no body; a budget of zero | a wrong Background is refused before any scenario, with the line and the sentence |
| 16 trust none, 17 trust trusted | `its trust is` | none puts every gated tool to the person; trusted asks nothing; a deny holds either way |
| 19 sandbox | a Lua body that reaches for `io` | it fails by name when it runs, as a result, and the run goes on |
| 20 kits | `it uses the kit "kits/calendar.lua"`: a kit of the workspace's own, its two lines (one widening, one narrowing), its store and tools, its own given and then steps | the kit's lines are vocabulary once loaded, whatever their order; its tool writes its store; its own line reads it back; the narrowing line holds (`docs/spec/kit.md`) |
| 21 modes | `library/modes.lua`, plan mode as a kit: a start, a tool list a mode, a move the person approves | a call outside the mode is refused with the sentence and the run goes on; an approved move opens the tools; a refused move changes nothing; an undeclared move is refused naming the moves there are (`docs/spec/modes.md`) |

Twenty-one files, sixty-one scenarios, all passing on the doubles.

## What writing them found

Nine things were wrong or missing in the harness, each found because a scenario that
should have passed did not. All fixed, each with a test or a spec line:

1. **The skill tool was not in a verify run.** `it keeps a skill` declared a skill the
   scenario's model could not open: `cli.main` installed the `skill` tool and the skills
   briefing, `cli.drivers` did not. Now both do (`src/cli.lua`, `cli.drivers`).
2. **Neither was the gate.** Policy and trust lines (`may never call`, `its trust is`) were
   applied by the live run's `cli.wire` and by nothing in a scenario, so a feature could
   state a policy and verify nothing about it. `cli.drivers` now builds the same gate.
3. **Neither were the servers.** `it uses the server` connected only in the live run.
4. **The gate dropped the person's edits.** `letting the person change to` worked on the
   doubles' direct path and never through `approval` and `cli.bind`, which read the port's
   `{ allow, args }` and kept only `allow`. The decision now carries `args`
   (`docs/spec/approval.md`).
5. **A server line could never match.** `the server {word} offers {word}, which answers
   {value}` had a comma straight after a `{word}`, which reads to the next space; the same
   amendment the delegate line had. It is now `offers {word} and it answers {value}`.
6. **A refused command counted as run.** `it runs no command that publishes` failed on a
   `git push` the person refused. A refused call ran nothing (`docs/spec/behaviour.md`).
7. **Nothing could say a strike fired nothing.** A beat held by its ledger left the
   scenario no Then line that could pass. `no beat is due` is the forty-sixth expression.
8. **npm and npx were unplaced** (found a day earlier by the long-task eval, in the same
   reader).
9. **The `add` edit took `with` unread**, and two more tolerances in `declare.edit` (found
   by the author eval).

## What the language will not say, and why

These are not bugs; the showcases ran into them and the files now state them:

* **What an agent is, is said once, in the Background.** An is line inside a scenario is
  refused, so a feature is one agent, and trust and policy variants are separate files.
* **A scenario has one When.** A long conversation is one scenario a turn (the long-task
  eval's milestones), never a chain of Whens.
* **A wrong Background is fatal to the file**, with the line and the reason, before any
  scenario. `the declaration is refused because` is for what the check finds that loading
  does not, and for a host that builds a declaration by hand.
* **An agent with no tools cannot run** (beats and servers files carry a small tool).
* **The gate is reached only by a tool that asks.** A policy or a trust setting on a tool
  that never asks is inert, and the live runner says so; the showcases put the policy on
  gated tools.
* **Edits at the gate are choices, numbers and booleans**, never free text.
* **A shorthand is of then lines or of given lines**, never of a When, and a given
  shorthand cannot hold a model script whose JSON has a `<parameter>` in a number's place.
* **A `{word}` reads to the next space**, so no expression puts punctuation straight
  after one.

## Against the real model

Nine files, three samples a scenario, GLM 5.3 in place of `test:model`. The table and
what it means are in `docs/ergonomics.md`, "What the real model said about the showcase":
in short, every behavioural scenario holds at 3 of 3 except two where the model took a
legitimate other route (a tag it added on its own; a skill it read from the file the
briefing named instead of calling `skill`), and the eleven scenarios whose Then lines
describe the scripted transcript are tagged `@verify-only` and reported as not evaluable.

## Running

    luajit scripts/showcase.lua                       -- every file, one line each
    luajit scripts/showcase.lua --verbose             -- with the runner's report
    luajit bin/malleable.lua --verify --feature showcase/04-stores.feature showcase/04-stores.feature
    luajit scripts/eval.lua showcase/04-stores.feature --samples 3 --model openrouter:z-ai/glm-5.3
                                                      -- the real model in place of test:model
