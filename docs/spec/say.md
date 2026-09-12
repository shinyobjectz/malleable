# say — a declaration said back as its Background, and two declarations held to each other

`src/say.lua`, `--say` and `--conforms` in `src/cli.lua`. Contract, written 2026-09-12 from
`docs/ergonomics.md` ("Both at once, and each checking the other"), the day the code was
written; where building it showed the first draft wrong the amendment is said where it
happened.

## What it is for

An agent is written in one of two surfaces that compile to one table: a feature file's
Background in the is vocabulary (`docs/spec/declare.md`), or the Lua prefix `agent.*`. The
first can be read, verified, reach-scored and walled by the runner; the second can hold a
hook, a body as a function, a host's own options. A workspace will have both, and today
nothing holds them together: a Lua program can widen its reach with a line nobody reviewed
in the vocabulary, and a feature file kept beside a Lua program as its contract can drift
from it without a check failing.

This module is the other direction of `declare`: **from the table, the lines.** With it,

* `--say agent.lua` prints the Background that would declare what the Lua declares, and
  after it the list of what no line can say, so a person reads a Lua program in the
  vocabulary and the author agent may propose edits to that rendering under the wall;
* `--conforms a.feature a.lua` renders both and reports every line only one of them says,
  in the vocabulary's own words, so a feature file is a contract a CI check holds a Lua
  program to.

A Lua change that changes the rendering is, by definition, a change of reach, and the same
scoring applies to the rendering as to any Background.

## Vocabulary

Checked with `monty onto check`: `say` and `conforms` were free. `unsaid` is
`declare.UNSAID`'s word and keeps its meaning: what the Gherkin cannot say.

* **said back**: a declaration rendered as is lines.
* **the unsaid**: the sentences that name what a declaration holds that no is line says.
* **program** and **contract**: in `--conforms`, the positional path and the `--conforms`
  path. Either may be a `.lua` or a `.feature`; the words say which side is being held to
  which.

## What a rendering is

`say.render(a) -> text, unsaid` answers a whole feature file: `Feature: <name>`, a
`Background:` whose lines are is lines in the vocabulary's order (who it is, what it can
reach, what it keeps, its tools, its servers, its skills, its beats, its own steps, its
policy), each with the doc string or table the line takes, and after the Background one
comment line per unsaid sentence:

    Feature: lead

      Background:
        Given the agent is called lead
        And its model is "test:model"
        And it may take 24 steps
        And it reads and writes the workspace
        And it never touches "secrets/**"
        And it runs commands
        And each command may run 20 seconds
        And it has a tool verdict for "File a verdict.", which takes:
          | argument | type    | about     |
          | ok       | boolean | approved? |
          | summary  | string  | one line  |
        And the tool verdict asks first
        And it may never call shell

      # unsaid, and kept in the program:
      #   the body of verdict is Lua in the program, not a doc string
      #   1 hook (agent.on) watches the run, and a hook is not sayable

Rules the rendering keeps:

* **the budget is always said**, default or not. A rendering that hid the default would
  hide the fact a reviewer asks about first.
* **arguments and columns come in the table's order**, which `spec` sorts by name. A file
  that listed them another way is said back sorted; the lines mean the same.
* **a kit's tools are said by the kit's line.** `it reads the workspace` stands for the six
  files tools; a tool a kit installed is not listed as `it has a tool`. What a feature
  changed about a kit's tool (`the tool read is for`, `the tool shell asks first`) is a line
  of its own, and what it did not change is not.
* **a body from a feature is said back as it was written** (`does:` with its Lua, `answers`,
  `adds a row to`, `lists`); a body that is a Lua function has no text and is unsaid, by
  the tool's name. The same for a requirement's check and a step's body.
* **the unsaid is named, never dropped.** A hook, a beat that runs a function, a beat's
  `tz`, `grace` or `about`, a tool's `ends`, a delegate declared in Lua, a policy entry
  with `when` or `reason`, a server option that is a table, a shell timeout that is not a
  whole number of seconds: each is one sentence, with the name it belongs to.

For this the table has to remember what it was told. Every kit records itself on
`a.kits[name]` (what it was told, and the tools it installed with the about and ask they
had before any line changed them); a feature-declared body, requirement and step keep
their text on the tool (`said`, `source`); a limit records its number under
`a.kits.limits`; a delegate its path under `a.kits.delegates`. These are records, not
behaviour: nothing reads them but `say`.

### The identity

For an agent written in a feature, saying it back and applying the rendering gives the
same declaration: the same schema, and the same lines when said back again. `--say` is
the identity on a feature file up to order and spelling, and a test holds that over every
showcase file.

## Conformance

`say.conforms(program, contract)` renders both to lines (each line one string with its doc
string or table folded in) and answers the lines only the program says, the lines only the
contract says, and the unsaid of each:

    { ok, only_program, only_contract, unsaid_program, unsaid_contract }

`ok` is true when every sayable line is on both sides. `say.report` says it as sentences:

    a.lua says `the tool verdict asks first`, and a.feature does not
    a.feature says `it may never call shell`, and a.lua does not
    a.lua keeps something no line says: 1 hook (agent.on) watches the run, and a hook is not sayable

What the unsaid means for a check is a decision the check does not make: a hook on the
program side is reported and does not fail the check, because a contract cannot say it
either way. Drift is a sayable line on one side only.

## The command line

| option | argument | meaning |
| --- | --- | --- |
| `--say` | — | load the declaration, print it said back, run nothing. With `--json`, the object carries `said` and `unsaid`. |
| `--conforms` | path | load the positional declaration as the program and this path as the contract; print the report; exit 0 when they say the same agent, 3 when they do not. With `--json`, `conforms`, `only_program` and `only_contract`. |

Both load through `cli.load`, so a `.lua` runs in the sandbox and a `.feature` through
`declare.apply`, and neither runs a body. A file that will not load is the usual exit 2
with its reason, naming which of the two it was.

## What it must NOT do

* Run anything. A rendering reads the table.
* Guess at a body. A function has no text; it is unsaid, by name.
* Drop the unsaid, or fold it into a line that means less than the Lua does.
* Read the program's source text. The rendering is of the declaration, not of the file:
  two Lua files that declare the same agent say the same lines.

## The tests that prove it

`test/say_test.lua`, under `lua` and `luajit`:

* every showcase feature, said back and applied again, gives the same schema and the same
  lines (the identity);
* a Lua program with a files kit, a deny glob, a shell with a timeout, a gated tool with a
  Lua body, a hook and a policy is said back with the lines above and exactly those
  unsaid sentences;
* a rendering of a feature with a limit, a requirement, a store body, a skill at a path,
  two beats, a step and a server says each line back;
* `conforms` of a file with itself is ok; of a feature and the same feature with one line
  removed names that line on the right side; of a Lua program and its contract names the
  hook as unsaid without failing;
* `--say` prints the rendering and exits 0; `--conforms` exits 0 on the same agent and 3
  on drift, with the sentences on stdout; a contract that will not load exits 2 naming it.

## Corrections, made while building it

* The sandboxed surface `cli.load` gives a Lua program has no kit: `agent.files`,
  `agent.shell`, `agent.plan` and `agent.history` are on the prefix only (`agent.lua`), so a
  program run from the command line reaches the workspace through a feature's is lines or
  not at all. The rendering handles both; the gap is filed in `docs/ergonomics.md`.
