# property — a scenario that holds for every world, not just the one it wrote down

`src/property.lua`. Contract, written before the code. Amend it before the code diverges.

## What it is for

A scenario is an example: one world, one run, one set of checks. Malleable's promises are
not examples. "A refusal is a result the model reads", "nothing is written without a
yes": those hold whatever the model says, and a feature can only ever state what one
scripted model said.

A property is a scenario tagged `@property` that states part of its world with `any`
instead of a value. This module turns each `any` line into concrete lines, runs the
scenario in each generated world, and checks the same Then lines every time. When a world
breaks it, the world is shrunk to the smallest one that still breaks it, and that world is
printed as an ordinary scenario.

## The design, in one sentence

**Expansion, not a new runner.** A generated world is a list of ordinary Given lines, in
the vocabulary `src/behaviour.lua` already reads, and each one runs through the unchanged
`behaviour.run`. So nothing about a run, a trace, an observation or a Then line differs
between a property and a scenario: a property is a scenario written many times over.

Three things follow, and each is a rule this module keeps:

* **No change to `src/behaviour.lua` or `src/gherkin.lua`.** Rule 7 (the reader knows no
  harness) and rule 6 (a feature states behaviour and cannot cause it) hold untouched,
  because every `any` line becomes Given lines, and a Given line only writes the world.
* **A counterexample is a scenario.** It prints in the vocabulary a feature already uses,
  so a person can paste it into a feature as it is, and it runs.
* **To any other reader a property is a normal scenario.** `bin/malleable.lua --verify`
  reads its `any` lines as steps nobody defined and reports the scenario *undefined*, not
  failed. Only a runner that knows `@property` expands it.

## The `any` lines

| line | expands into | generated from |
| --- | --- | --- |
| `the model says anything its tools allow` | zero or more `the model calls <tool> with <json>`, then usually `the model answers "<text>"` | the declaration's tools: each call picks a declared tool and an argument of each declared type |
| `the clock reads any date` | `the clock reads "<date>"` | a date between 2000-01-01 and 2099-12-28, at a whole minute |
| `the file {string} holds anything` | `the file "<path>" contains:` with a doc string | text of any length, including none |
| `the person presses any keys` | `the person presses "<keys>"` | the six buttons, by name, in a sequence of any length up to a bound |

`the person presses any keys` runs only where a runner has declared the step
`the person presses {string}`. Where none has, the property is **skipped**, with the
sentence saying why. It's not failed and it's not undefined, because the scenario is
written correctly and only the step is missing.

`any rows in the store {word}` is reserved for the store seam (`spec/programs.md`), and is
refused by name until the store exists.

### The model says anything

This line is the most important one. Malleable's rules are promises about what happens
whatever the model does. A real model is slow, expensive and polite, and a generated one
will call every tool in every order with every argument the types allow.

* **The number of calls** is between 0 and the declaration's budget (at most 16), weighted
  toward short sequences, because a short counterexample is the useful one.
* **Each call** names a tool from the declaration and gives it one argument per declared
  parameter. A required parameter is always present. An optional one is present half the
  time.
* **Arguments by type:**
  * `string` draws from a small pool that includes the empty string, a path in the world,
    a path that leaves the workspace (`../outside`) and an absolute one, or else random
    letters;
  * `number` draws from 0, 1, −1, a large number, a negative one, or a random integer;
  * `boolean` is true or false;
  * `object` is `{}` or `{"k": "v"}`;
  * `array` is `[]` or `["a", 1]`.

  Arguments are well typed. Checking what the harness does with a badly typed argument is
  a different property.
* **The answer:** most sequences end in `the model answers "<text>"`. The rest end with
  the script simply running out, which is also a thing a model does.

Every generated number is an integer and every key is emitted in sorted order, so `lua`
and `luajit` generate byte-identical worlds.

## Seeds

A pure-Lua generator: the minimal standard one (`x = 16807·x mod 2³¹−1`), whose products
stay under 2⁵³, so both halves of the tree's dialect compute the same sequence. A property
run takes `seed` (default 1). Run *i* draws its own seed from that, and a counterexample
prints both, so the failing world is reproducible from the report alone.

The run seeds come from a second generator with the other minimal-standard multiplier
(48271). Seeding each run with the next number of the *same* generator would make run
*i + 1* run *i* shifted by one draw, and the worlds would repeat each other.

## Shrinking

When a generated world fails, the module tries smaller worlds, and keeps the first one
that still fails, then starts over. It stops when no smaller world fails. The moves, in
this order:

1. drop a whole call from the model's script, or drop the answer;
2. drop an optional argument;
3. shrink an argument: a string to `""`, then to half its length; a number to 0, then
   halfway to 0; `true` to `false`; an array or object to one fewer element;
4. shrink the answer text, a file's text, and a press sequence the same way;
5. move a date toward 2000-01-01.

"Still fails" means it fails the same way: the same outcome (`failed` or `broken`), on
the same Then line. A smaller world that breaks a different line is a different bug, and
shrinking toward it would print a counterexample to something else. Shrinking is bounded
(at most 2,000 attempts), and the report says if it stopped there.

## What a report says

For each property:

    passed    whatever the model says, nothing is written without a yes   1000 of 1000

And for a failure, the counterexample, then how to reproduce it:

    failed    whatever the model says, nothing is written without a yes   run 3 of 1000

    Scenario: counterexample to "whatever the model says, nothing is written without a yes"
      Given the human refuses verdict
      And the model calls verdict with {"summary":""}
      When the agent is asked "Review the change."
      Then nothing is written
        # did not hold: it wrote "REVIEW.md"

    seed 1, run 3 (run seed 1622650073), shrunk from 7 generated lines to 1 in 24 attempts

## The surface

    property.expressions()                    -> the `any` lines, as { expr, about }
    property.is(pickle)                       -> true when the pickle is tagged @property
    property.split(pickles)                   -> the plain pickles, the properties
    property.tools_of(declaration)            -> { { name, args = { {name, kind, required} } } }
    property.run(pickles, drivers, opts)      -> report
    property.text(report)                     -> the report, as a person reads it
    property.generator(seed [, multiplier])   -> { next, int, chance, pick }, the one generator
    property.date_of(days, minute)            -> "2000-01-01T00:00:00Z" plus that many days

`opts`:
* `tools`, from `tools_of`, or `declaration` to have them read from it;
* `runs`, default 100;
* `seed`, default 1;
* `max_calls`, default the declaration's budget, capped at 16;
* `shrink_limit`, default 2000;
* `on_run(scenario, pickle)`, called once for every generated run with behaviour's report
  of that scenario and the concrete pickle it ran, so a host can check its invariants
  against every run from every cause. Shrinking attempts are not reported.

The report is
`{ ok, properties = { { name, line, outcome, runs, planned, passed, why, seed, run,
run_seed, counterexample, generated, shrunk_from, attempts, stopped_at_limit } } }`. The outcome is `passed`,
`failed`, `skipped` or `broken`, the last when a step raised or matched nothing in a world
that wasn't generated. `property.text(report)` renders it as above.

## What it must not do

* Name the console, a screen or a host. It takes drivers and a declaration, like
  `behaviour` does.
* Change a world after its When. Expansion only ever writes Given lines.
* Use `math.random`, a clock or anything outside the tree, so two runs of the same property
  with the same seed agree, byte for byte, under `lua` and `luajit`.
