# change — what an agent may alter about itself, and what it may not

`src/change.lua`. Contract, and the ruling that bounds it. Written before the code,
because this file is a **wall** and a wall drawn afterwards is a wall drawn around
whatever was built.

## What it is for

The harness now measures itself well enough to improve itself. `--eval` gives a rate over
k samples; `observe` gives what actually happened, as Gherkin; `agreement` gives stated
against observed; `gaps` give what the vocabulary could not say, as a count that only goes
down; `scripts/rules-test.lua` gives eight invariants. Those are a fitness function and a
constraint set, and both already exist.

So the loop is small:

> run → observe → find the disagreement or the gap → propose an edit → re-verify →
> keep it if the rate went **up** and 8 of 8 rules still hold and no behaviour was lost.

What makes this worth doing carefully is that self-improving systems fail *quietly*. The
three ways, and what stops each:

| it goes wrong by | what stops it |
| --- | --- |
| making the test easier | the authored feature file is not editable |
| relaxing what it asks permission for | the gate is not editable |
| losing behaviour while the rate rises | the repertoire diff, and a loss halts the step |

## The five layers, and where the wall is

| layer | may an agent change it | why |
| --- | --- | --- |
| the eight rules (`DESIGN.md`) | **never** | they are what makes everything else checkable |
| the gate and its policy | **never** | an agent that can edit its own gate has no gate |
| the modules — the harness itself | **never here** | a loop that rewrites `turn.lua` is not an optimiser, it is a different program each time |
| **the declaration** | **yes** | its briefing, its tools' descriptions, its budget |
| **the vocabulary** | **yes, as gaps** | the ratchet already produces the work list |

The middle row is the one worth arguing about, because it is the one the ambition wants.
Rewriting the DSL is a great deal of risk for a layer where the behaviour does not live: an
agent's behaviour lives in what it is told, what it may reach for, and when it must ask.
All three are in the declaration. If a change to the harness turns out to be needed, that
is a finding for a person, and it should arrive as a **gap** — the same shape every other
thing this tree cannot yet say arrives in.

## The field list, and the wall that followed it

The field list below is `change.propose`'s, on a declaration table, and it stands. An agent
written in Gherkin meets a wider wall, drawn by **reach** rather than by field, in
`spec/declare.md`: an edit that widens nothing it may make, one that widens reach goes to the
person, and the two things this file refuses by name — an agent's own gate, and the authored
feature file — are refused there by name too.

## What is editable, exactly

A **field list**, not a rule of thumb. Anything not named here is refused by name.

| | |
| --- | --- |
| `system` | the briefing |
| `budget` | how many passes the loop may take |
| a tool's `about` | what the model is told a tool is for |

That is all, for now, and the list being short is the point: each one is a thing a person
would also have tried, and each is reversible by reading one diff.

**Not** editable, and each refused by name rather than by silence: `ask` on any tool (that
is the gate), `run` on any tool (that is the code), `name`, `model`, tools added or
removed, beats, servers, and every field the declaration does not have.

## Goodhart, and the split that answers it

An optimiser scored on a test it can edit will edit the test. The split is already drawn
in this tree and only has to be enforced:

* **authored** scenarios — written by a person, in a file the loop is given and may not
  write to. These are the fitness function.
* **observed** scenarios — written by `observe`, from runs. These are memory, not score.

A proposal is scored **only** on authored scenarios. If the authored set is empty the loop
refuses to run at all, because an optimiser with no fitness function will happily report
that everything improved.

## The three gates on a proposal

A proposal is kept only if **all three** hold. Each is a measurement, not a review:

1. **the rules still hold** — passed in as `opts.rules`, a function the host supplies.
   Not run here, and that is the same seam as the model rather than a dodge:
   `scripts/rules-test.lua` is a *script*, running it means loading a file, and this module reads
   no file and writes none, which is what lets it be tested without either. A rules check
   that **raises** is a refusal, not a pass — a gate that cannot run is not a gate that
   held. With no `opts.rules` at all every decision says so in its own sentence, because
   a gate nobody can see was skipped is a gate that has already stopped working;
2. **the authored feature file passes at least as well** — more passing, no new failure,
   no new undefined;
3. **no behaviour was lost** — `observe.repertoire_diff(before, after).lost` is empty.

The third is the one that does not exist anywhere else and is the reason this is safe to
run unattended. A rate can rise while an agent quietly stops doing half of what it did; a
pass count cannot see that and a repertoire diff can.

## The shape

    change.EDITABLE                          → the field list, a fresh copy each read
    change.propose(decl, edit)               → a copy with the edit applied, or nil, why
    change.score(decl, feature, drivers)     → passes, and the repertoire of what passed
    change.better(before, after, opts)       → the three gates: keep, why, and the diff
    change.step(decl, feature, edit, …)      → one round: propose, measure, keep or refuse
    change.loop(decl, feature, edits, …)     → each in order, carrying the declaration on
    change.report(run)                       → the lines a person reads

`opts` on `better`, `step` and `loop`: `rules` (the gate-one function) and `allow_loss`
(a host that means to drop a behaviour, saying so in writing).

`change.propose` never mutates what it is given. Every step answers **why** it kept or
refused, in a sentence, and the sentence names which of the three gates decided.

## What it must NOT do

* Write a file. It answers a declaration and a report; a host applies them, or does not.
* Call a model. Where the proposal comes from is the host's business — a person, a model,
  a sweep over a list. This file scores proposals; it does not invent them.
* Score a proposal on anything it could have written.
* Accept an edit to a field not in `change.EDITABLE`, however it is spelled.
* Run without an authored feature file.

## What it promises

`spec/change.feature`, and it **runs**. 10 scenarios, under `lua` and under `luajit`.

The list that used to be here was prose: a set of bullets saying what a test would show,
enforced by nobody. A hundred and four of them sat across these files and an audit of five
found eight that were not true — including a gate this spec described in detail that the
code simply did not have. A promise you cannot run is a promise you find out about later.

The distinction the feature file buys, which prose cannot:

* a scenario that **fails** means this spec says something FALSE. A bug, and never allowed.
* a scenario that is **undefined** means this spec is AHEAD OF THE CODE. Legal, counted in
  `spec/OWED`, and ratcheted so the number goes down and never up.

`tools/spec-check.sh` runs them all and prints the counts; `test/spec_test.lua` runs them
inside the ordinary suite, because a promise that only runs in a script somebody has to
remember to call is the same failure one level up.

What stays in this file is everything that explains a **decision** — why the reader lives
where it does, what was refused and on what argument, which surprises were kept. A feature
file cannot carry an argument, and a repository that deletes its arguments relitigates them
every six months.
