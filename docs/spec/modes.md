# modes — a state machine over what an agent may call, moved only by the person

`library/modes.lua`, a kit (`docs/spec/kit.md`) the tree ships. Contract, written
2026-09-12 before the code, from the comparison with the rules a coding harness keeps
(`docs/authoring-context.md`).

## What it is for

A harness like Claude Code keeps an agent honest with a few small mechanisms: a permission
mode that says which tools run unasked (default, accept edits, plan, bypass), rules that
allow or deny a tool by name and argument pattern, hooks that run before a tool and may
block it with a sentence the model reads, and standing instructions loaded every session.
This tree has all of those but one: trust, policy with `when`, `agent.on "call"`, the
briefing and the skills. What it lacks is **plan mode**: a named state in which the agent
may read and check but not write, which it leaves only when the person says so, and
which the agent cannot talk itself out of.

For an agent that authors agents, that state is the whole discipline: read the file, read
the vocabulary, verify, and only then ask to edit. The author eval showed a model that
skips the reading and pays for it in refused edits. A mode makes the order a wall rather
than a sentence in the briefing.

A mode is a set of tools the agent may call, a start, and the moves the person may
approve between modes. It is declared in is lines, so the wall scores it: adding a mode's
tool list narrows, adding a move widens, and an agent editing itself may narrow its own
modes and never widen them.

## Vocabulary

Checked with `monty onto check`: `mode` and `modes` were free.

* a **mode** is a named state of a run, with the tools it may call.
* the **start** is the mode every run begins in.
* a **move** is a transition the person may approve, from one mode to another.

## The lines

| | tells the kit | reach |
| --- | --- | --- |
| `it starts in the mode {word}` | the start | neither, and a **gate**: never removed or replaced by an agent |
| `in the mode {word} it may call {string}` | that mode's tools, a comma list | narrows |
| `the mode {word} moves to {word} when the person says so` | one move | widens |

Rules, each refused at install by name: a start is said once and names a declared mode;
a mode is declared once; a move names two declared modes; with any mode line there is a
start. A tool named in a mode that the agent does not have is not refused: the mode says
what *may* be called, and a tool the agent lacks is never called anyway.

## What using it installs

* one tool, `mode`, taking `to` (one of the declared modes), **asking first**. Its body
  refuses a move the lines do not declare, in a sentence naming the moves from the current
  mode, and otherwise makes the move and answers with the new mode's tools;
* a hook on `start` that puts every run in the start mode;
* a hook on `call` that refuses a call to a tool the current mode does not list, with the
  sentence `first move out of the mode reading: call mode with to = editing, which asks
  the person; in the mode reading you may call only features, feature, vocabulary,
  verify, not edit` (reworded 2026-09-12 to lead with the action: at nine samples the
  reading-mode refusal was the sentence models drew most, 60 calls in 30 samples). The `mode`
  tool itself is always callable. A refusal is a result the model reads, and the run goes
  on, exactly as a policy deny is.

The model is told in the `mode` tool's `about` which moves exist and that the person is
asked; nothing else is added to the briefing. What the mode allows is in the refusal,
where the model reads it at the moment it matters.

## The steps

| | reads or writes |
| --- | --- |
| `it is in the mode {word}` (then) | the mode the run ended in |
| `the run begins in the mode {word}` (given) | the mode the next run starts in, instead of the start |

The mode a run is in is the kit's own state for the run, kept in the kit and reset by the
`start` hook; a Then line reads it after the run, as it reads the result. The given line
puts `mode` on the scenario's world, and the `start` hook reads it from `e.given`, the
plain values a run's port carries (amended 2026-09-12: the first draft kept the asked-for
start in the kit, and a scenario that asked and then ran nothing, `the declaration is
loaded`, leaked it into the next scenario's run; `turn` now hands a hook the world's data).

## Why the person, and only the person

A move is a gated call, so `--yes` approves it, `--no` refuses it and `its trust is
none` puts every move to the person. The `mode` tool declares `ask = "always"`
(`docs/spec/approval.md` §2.3, amended 2026-09-12): `its trust is trusted` and `it may
always call mode` do not answer its question, because a mode that trust moves is a
sentence, and a person who sets trust for convenience would lose the rail without being
told. `it may never call mode` still pins the run in its start; a deny is the one thing
nothing talks past. A mode is not a second gate but a way of saying which tools exist
before the gate is reached. There is no move on a fact
(after a verify passes, say): a hook cannot see a call's result, and a mode that moved
itself would be a mode the model could move.

## What it must NOT do

* Move on the model's word. Every move is a gated call.
* Refuse the `mode` tool itself, or the run would be stuck in its start.
* Add to the briefing. The tool's `about` and the refusal say everything.
* Keep state across runs. Every run starts in the start.

## The tests that prove it

`test/modes_test.lua`, under `lua` and `luajit`:

* each rule of the lines is refused at install by name;
* a run in the start mode has a call outside it refused with the sentence, and the run
  goes on; a call inside it goes through;
* an approved move changes what is refused; a refused move changes nothing; a move the
  lines do not declare is refused by the tool naming the moves there are;
* `the run begins in the mode` puts a run elsewhere for one run only;
* the lines are said back, and the kit's reach is what the lines say;
* `showcase/21-modes.feature` verifies.

## Corrections, made while building it

* The start line is a gate (`docs/spec/kit.md`): replacing `reading` with `editing` was a
  "neither" edit by the reach words and a widening in fact.
* `the run begins in the mode` leaked across scenarios (above); fixed through `e.given`.
* Under `its trust is trusted`, or `it may always call mode`, the model moved itself: the
  mode was a sentence. Closed 2026-09-12 by `ask = "always"` on the `mode` tool;
  `evals/modes-trusted.feature` and `modes-policy.feature` now state the rail. Under
  `it may never call mode` the run is pinned in its start, which stands. A delegate does
  not inherit the parent's mode, stated under `evals/modes-edges.feature`.
* The mode was one variable for the whole kit, so a `verify` the author ran on the
  notebook, which uses the same kit, put the author back in reading (found by the
  real-model attack run: an approved move undone by the next verify). The state is now
  per use, in the install's closure.
* A Then line then read the use whose run started last, which in a nested verify is the
  notebook's, not the author's (found by `evals/modes-rails.feature` on the doubles,
  2026-09-12, the first fault the doubles found before a model did). The kit keeps a stack
  of the uses whose runs are open, pushed on `start` and popped on `stop`, and a Then line
  reads the outermost. The kit names its rails (`docs/spec/kit.md`) and says a delegate
  starts fresh.
