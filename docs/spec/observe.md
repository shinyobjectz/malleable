# observe — a run, read back out as behaviour

`src/observe.lua`. Contract, not implementation. No code exists yet; the module is written
to this document, and this document is amended before the code diverges from it.

## What it is for

A feature file says what an agent should do. Nothing said what it *did*, in the same words,
and that asymmetry is the whole problem: a passing test tells you the agent did what was
asked and tells you nothing about what else it did on the way.

So a run is read back out as a scenario. Text in one direction, text in the other, and the
same closed vocabulary at both ends:

    triage.feature              what it was asked to do   — stated, by a person
    the observed scenario       what it did               — read out of the run

## The direction is the design

**Gherkin is not a format for logs.** The tempting shape is a query language over
telemetry — *the trace shows execute_tool 3 times* — and eight expressions in this tree do
exactly that. They are marked diagnostic and this module may not emit one, ever.

What is wrong with them is not that they fail. It is that `span`, `trace` and `log` are the
*harness's* nouns. A person watching an agent does not think *the gate span closed refused*;
they think *it asked before it filed, and was told no*. An observed scenario written in the
harness's nouns describes the harness. This module's whole job is to describe the agent.

The trace and the transcript are what it **reads**. They are not what it **says**.

## What an observed scenario is

A complete, re-runnable scenario — not a summary, not a report. Given lines that state the
world the run actually had, one When, and Then lines that state what happened.

    Scenario: observed — Review the change to src/turn.lua.
      Given the file "src/turn.lua" contains:
        """
        -- the turn loop
        """
      And the human refuses verdict
      And the model calls read with {"path": "src/turn.lua"}
      And the model calls verdict with {"summary": "ship it"}
      And the model answers "I was not allowed to file that."
      When the agent is asked "Review the change to src/turn.lua."
      Then it stops with answered
      And it takes 3 steps
      And it calls read with {"path": "src/turn.lua"}
      And the human is asked about verdict
      And the call to verdict is refused
      And nothing is written
      And it answers "I was not allowed to file that."

Two things follow from re-runnable, and both are worth having:

1. **The model's replies are part of the world, so they are stated.** They are Given lines,
   which is also why an eval drops them: they are an input, not a behaviour.
2. **An eval sample's observed scenario is a deterministic replay of what a real model
   actually did.** Take the one sample in twenty that went wrong, and you have it forever,
   without the model, as a file a person can read and a suite can run.

## The rule this module carries

**Every expression it emits is one a person writes.** Not similar to one — the same string,
from the same closed vocabulary. A test enumerates what the observer can emit and fails on
anything that is not in `behaviour.steps()`, and fails again on anything marked diagnostic.

*Test: `an_observer_speaks_only_the_authored_vocabulary`.*

## Acceptance: the round trip

For every scenario in `example/reviewer.feature`, observing its run yields a scenario
which, run back through the verifier, **passes**.

That is the strongest check available for this, and it is the reason to prefer it to
anything softer: if an observation is not faithful enough to re-run, it is not behaviour, it
is a summary. A summary can be wrong in ways nothing catches.

## What it must NOT do

* Emit a diagnostic expression, or any string that is not in the authored vocabulary.
* Invent an expression. See the gap discipline below.
* Judge. It states what happened; whether that was wanted is `agreement`'s business and a
  person's.
* Reach a port, a clock or a model. It reads a result and a world it was handed.
* Summarise, round, or elide. Every call the run made is a line; a scenario with nine calls
  has nine lines.

## When it has no word for something

**A gap in the behavioural vocabulary is filed against the vocabulary.** It is never
repaired by reaching for a telemetry noun, and this is the discipline the whole direction
rests on: the moment the observer may emit *the trace shows*, it will emit that for
everything it has no word for, and the vocabulary stops growing on the day it starts. (The
same rule as mar-4o07, one layer up: a reading that cannot come from the map is a map gap,
not a wider regex.)

A gap is recorded as `{ saw = "...", wanted = "..." }` — what the run did, and the shape of
the sentence that would have said it — and comes back beside the scenario rather than being
dropped. `observe.gaps(runs)` collects them over many runs, and that list is the work list
for growing the vocabulary. The count goes down; a new *kind* of gap is a finding.

## Agreement

`observe.agreement(stated, observed)` sets one against the other and answers three groups:

* **held** — a line the person stated and the run did;
* **missing** — a line the person stated and the run did not;
* **unstated** — **a line the run did that nobody stated.**

The third is why this exists. A passing test says the agent did what was asked; only the
agreement says what else it did on the way. `agreement` is the repo's word, widened on
2026-09-10 to cover behaviour as well as the map: what a reading kept, changed, added and
introduced, set against what was meant.

An unstated line is not a failure. Most of them are ordinary. The point is that they are
*visible* and countable, so a change in them across a version is a fact rather than a
surprise.

## The repertoire

`observe.repertoire(observations)` collapses many observed scenarios into the distinct
behaviours they exhibit, each with the rate at which it occurred:

    17/20  it read, then asked, then filed
     3/20  it filed without reading

Collapsing is over the observed **Then** lines and nothing else, so two runs that differ
only in a model's wording are one behaviour, and two that differ in what they called are
two. Deterministic, and **no model judges the clustering** (ruled 2026-09-07).

This is what an eval reports instead of a pass rate. A rate stays — it is still the rate at
which an agent does what its documentation says — but it stops being the only thing the
eval knows, and the interesting number moves from *how often did it pass* to *how many
different things does it do, and which*.

## The tests that would prove it

* the round trip, over all eight scenarios of the worked example;
* every string the observer can emit is in `behaviour.steps()` and none is diagnostic;
* a run that calls one tool three times yields three lines, not one with a count;
* a refused call yields `the call to {word} is refused` and the gate line beside it;
* a run that writes nothing yields `nothing is written`; one that writes yields the file;
* an observation of a run whose world had a skill, a beat or a server records a **gap**
  rather than inventing a line for it;
* agreement over a run that did exactly what was stated: everything held, nothing unstated;
* agreement over a run that reached one extra tool: that call is the one unstated line;
* a repertoire over a model that always does one thing is one behaviour at rate 1; over one
  that alternates, two at 0.5, each re-runnable;
* everything above under `lua` and under `luajit`.

## A run still going (amended 2026-09-11, docs/spec/agent-file.md)

`observe.live(record, name)` writes the scenario of a run so far, in the same lines as
`observe.scenario` and from the same writers, so a live observation and a finished one
agree line for line. The record carries `result`, with the calls made so far and `stop`
nil while it runs, `prompt`, and `log`, the history's log of the files it wrote
(spec/history.md), whose texts are the Then lines about files. The world it was given is
not said: a live run's world is the real one. Once `stop` is set, the stop and the steps
come first among the Then lines, as they do in a finished scenario. Answers the text and
the gaps.
