# gherkin — reading a feature file, and nothing else

`src/gherkin.lua`. Contract, not implementation. No code exists yet; the module is
written to this document, and this document is amended before the code diverges from it.

## What it is for

A feature file is the only artefact in this tree a person writes in prose and a machine
executes. This module is the half that reads one: text in, pickles out. It knows what a
`Feature:` is and what a `{string}` captures, and it knows nothing whatsoever about an
agent, a tool, a port or a run — that is `spec/behaviour.md`'s half, and the seam between
them is the point of splitting the subsystem in two.

The split buys the same thing rule 1 buys: this file can be tested against forty thousand
real feature files with no harness present, and the harness can be tested against a
handful of pickles with no parser present.

## Vocabulary

Checked against the repo ontology before use. `feature`, `scenario`, `pickle`,
`expression` and `vocabulary` were unspoken for and are defined by this document.

**`step` is a divergence, recorded rather than resolved.** The repo defines `step` as one
call within a machine call. `spec/turn.md` has already taken it for one pass of the loop.
Gherkin's own name for a `Given`/`When`/`Then` line is *step*, it is printed on every line
of every feature file in the world, and renaming it here would mean this tree's error
messages disagreed with the file the person is looking at. So inside `gherkin.lua` and
`behaviour.lua`, **step means the Gherkin line**, and turn's step stays turn's. The two
never appear in one sentence: the runner's report says *line* where it must say both.
This is the same kind of divergence DESIGN.md already records for `run`.

The Lua function a step is bound to is its **body**, exactly as a tool's is. Not its
*binding* — the repo has claimed that word for the map layer — and not its *definition*,
which is what cucumber calls it and which collides with `declaration` in this tree.

## The subset

This tree reads the subset below and refuses the rest by name. The subset is not a guess:
it is what `canvas::scenarios::pickles` reads on the typeaway side, which was in turn
measured against 413 real feature files (`vendor/rgpair`).

Read:

* a `@tag @tag` line, at feature, rule or scenario level, inherited downward;
* `Feature:` and its free description lines;
* `Background:`, at feature level and inside a `Rule:`;
* `Rule:` with its own tags, description, background and scenarios;
* `Scenario:` and `Example:` (the same thing);
* `Scenario Outline:` / `Scenario Template:` with `Examples:` / `Scenarios:`, expanded one
  pickle per row, `<column>` substituted everywhere in a step including inside a doc
  string and a data table;
* the six step keywords: `Given `, `When `, `Then `, `And `, `But `, `* `;
* a doc string, `"""` or ` ``` `, with its indentation stripped to the opening fence's
  column and an optional content type on the fence line;
* a data table, `| a | b |`, with `\|` and `\n` unescaped in a cell;
* `#` comments and blank lines, anywhere.

Read but not structural, and each of the four is here because a real feature file in
`vendor/rgpair` needed it:

* a **UTF-8 byte order mark** before `Feature:`, stripped as real Gherkin strips it;
* a **description line that opens with a step keyword** — before any `Scenario:` or
  `Background:` there is no container, so `And a snapshot is taken afterwards.` is
  description. Real Gherkin raises here. This is the same divergence
  `canvas::scenarios` already records on the Rust side, and it is the reason the two
  readers agree rather than a convenience;
* `<` and `>` around anything that is **not placeholder-shaped** — a placeholder holds no
  whitespace and no punctuation beyond `_ - .`, so `$lhs <= $rhs AS lte` inside a doc
  string of Cypher is text. A `<who>` the `Examples:` genuinely lacks is still refused;
* a **trailing fragment after the last bar** of a data table row, which is whitespace in
  a well-formed row and never a cell.

Refused, each with the line number and a sentence:

* `Feature:` twice in one file, or anything at all before the first `Feature:`;
* `Examples:` under a `Scenario:` that is not an outline;
* a placeholder-shaped `<column>` an outline's `Examples:` does not have;
* a data table whose rows differ in width;
* a doc string that is never closed;
* any keyword this list does not name — including the localised ones. **Only English is
  read.** A `Fonctionnalité:` is refused by name with the sentence *this tree reads English
  Gherkin only*, rather than being read as a description line. Silence there is the failure
  mode that costs a day.

## The pickle

Compiling is what Cucumber calls it: a feature is *pickled* into the flat list a runner
walks, with backgrounds merged in front, outlines expanded, and tags inherited.

    { name = "...", tags = { "@wip" }, line = 12,
      steps = { { keyword = "Given", text = "the file \"a\" contains", line = 13,
                  doc = "...", rows = { { "a", "b" }, ... } }, ... } }

Four things this shape commits to:

1. **`keyword` is kept and `And` is not resolved.** A runner needs to know a line said
   `And` to print it back the way it was written; it must not need to know, to decide what
   the line means. Which is the rule below.
2. **`text` excludes the keyword and the trailing whitespace, and is otherwise the line
   as written.** No normalisation, no case folding, no punctuation stripping.
3. **`line` is on every node.** Every error this tree raises about a feature names a line
   number, because a person is going to open the file.
4. **A scenario with no steps pickles with no steps at all** — an empty `steps` list, not
   the background's — as Cucumber's own compiler does. It is not an error. It is a
   scenario somebody has named and not yet written, and the runner reports it as
   *undefined*.

**The keyword does not decide what a step means.** `Given`, `When` and `Then` are prose:
they tell a *reader* which phase a line belongs to, and a writer who opens a scenario with
`* the file exists` has written valid Gherkin. What decides is the expression the text
matches, and the vocabulary in `spec/behaviour.md` assigns each expression to exactly one
phase. A line whose expression belongs to the Given phase runs in the Given phase whatever
keyword introduced it, and a scenario whose phases are out of order — a Given after a
Then — is refused with a sentence naming both lines. This is the one place this reader is
stricter than Cucumber, and it is deliberate: the alternative is a world that is half
built when the run starts.

## Expressions

A **cucumber expression** is the pattern a step's text is matched against. It is compiled
to one anchored matcher and nothing else in this tree compiles a pattern.

Five parameter types, closed:

| | captures | yields |
| --- | --- | --- |
| `{string}` | a run in `"` or `'`, escapes honoured | the inner text |
| `{word}` | one run of non-space | the text |
| `{int}` | an optional sign and digits | a Lua integer |
| `{float}` | the same with a decimal point | a Lua number |
| `{value}` | JSON, or a bare number, or a bare word, or a quoted string | the decoded value |

`{value}` is the only one that is not standard Cucumber, and it exists because half of what
a step says about an agent is an argument table. It decodes with the tree's own JSON
reader; anything that fails to decode is the text.

Also read: `(s)` optional text, `a/an` alternation, and `\{` `\(` escapes. **Not** read: a
custom parameter type, a regular expression in place of an expression, or an anchor. There
is no field anywhere in this surface that accepts a regex, for the same reason
`spec/interpret-marks.md` has none: a string field that quietly compiles is a hole every
future author falls into.

Two expressions may not both match one step's text, and the guarantee is complete rather
than heuristic: **every expression is tried against every step**, and two matches raise
naming both. There are a few dozen expressions and a few dozen steps, so the cost of being
sure is nothing, and the alternative — matching in declaration order and taking the first —
is a bug that appears on the eleventh scenario.

Two forms of collision are also refused earlier, at declaration, where the message can name
the file that did it: an expression whose *skeleton* — every parameter erased to its type —
equals another's is the same expression written twice, and a workspace expression colliding
with a built-in is refused by `agent.step`. `behaviour.check` runs the full match over a
whole feature without running anything, which is what makes "before it runs" true in
practice.

## The rule this module carries

**The reader knows no harness.** `src/gherkin.lua` may not name an agent, a tool, a port,
a world, a result or a run, and may not require another module in this tree except the
JSON reader. It takes text and answers with tables.

*Test: `the_reader_knows_no_harness`, which reads the file, in `rules-test.lua` beside the
other five.*

## Two readers, one subset

There is a second reader of this subset in this repository — `canvas::scenarios::pickles`,
in Rust — and there will go on being one. Malleable's promise is that the whole tree is
native Lua with no C modules and runs on the `luajit` on your path; a harness that shelled
out to a Rust binary to read its own feature file would not be that harness. So the
duplication is bought on purpose, and the price is paid by a test rather than by hope:

**Acceptance: the two readers agree on all 413 feature files in `vendor/rgpair`** — same
pickle count, same names, same tags, same step texts, byte for byte. `tools/gherkin-diff.sh`
runs both and prints every disagreement. The number goes to zero and stays there; a
disagreement is a defect in whichever reader is younger, which is this one.

`vendor/gherkin-en` is **not** the acceptance corpus. It is forty thousand synthetic files,
and this repository does not fit readers to generated text (ruled 2026-09-06). It is useful
for one thing only — finding a keyword or a shape the subset above does not name — and a
finding from it is a question about the subset, never a patch to a matcher.

## Errors are sentences

Every refusal is `nil, "…"` where the string is a sentence a person can act on, carrying
the line number and what was expected. No error codes, no exception classes. A parse
failure never raises; a programmer error — calling `pickle` with a number — does.

## What it must NOT do

* Read a file. It takes text. The caller opened the file and the caller knows what a path
  means here.
* Require anything. Not even a JSON reader: this tree has none, so `{value}` decodes JSON
  in sixty lines here rather than making rule 7 conditional.
* Know that `Given` is about setup. Phases belong to the vocabulary, one layer up.
* Normalise, stem, lowercase or otherwise "help" a step's text before matching.
* Accept a regex, in any field, under any name.
* Read a language other than English without being told to.

## The tests that would prove it

* every shape in **The subset** parses, one test each, from a two-line file to a rule with
  a background and an outline;
* each of the four read-but-not-structural cases, one test each;
* every refusal in **The subset** refuses, with the line number in the sentence;
* an outline with three rows pickles three scenarios and substitutes inside a doc string;
* a scenario with no steps pickles with no steps;
* `{value}` decodes an object, an array, a bare number, a bare word and a quoted string;
* two expressions that both match one text raise, naming both;
* the 413 RGPair files pickle identically to the Rust reader;
* the file names no harness word (the rule test);
* everything above passes under `lua` and under `luajit`.
