# agent file — the agent's own feature file on the stage

`console/lib/agent_file.lua`, drawn on the home screen's stage (docs/spec/home.md) by
`console/lib/home.lua`. Contract written 2026-09-11 before the code, from the plan in
docs/agent-file-plan.md (epic mar-1vnp), for slice 1, the file at rest (mar-6rtz), and
amended the same day for slice 2, live work (mar-22m8), slice 3, self-edits (mar-12a7),
and slice 4, delegated runs (mar-tn67); the sections below say where.

## What it is for

An agent is one Gherkin file (docs/spec/declare.md): its `Background:` says what it is and
its scenarios say what it does, and that file is what the agent edits when it improves
itself. The console shows that file on the stage, laid out and readable, so the person
sees the agent as it stands, and later (slices 2 to 4) sees its state land on the lines.
It is not the log, not prose, and not editable in the window: the agent owns it.

## The render

The file is read with `gherkin.document`, so what is shown is what the agent's own reader
reads, and the free lines under the Feature line are its description. From that the module
makes **rows**, and from the rows, items. A row is one line on the stage:

| kind | what | how it is drawn |
| --- | --- | --- |
| `feature` | the Feature line | the name, larger |
| `description` | one line of the description | ink, at the margin |
| `tag` | the feature's or a block's tags, on one line | quiet |
| `block` | `Background:`, `Scenario: name`, `Rule: name` | the keyword quiet and the name in ink; a blank row before it |
| `step` | one step | its keyword quiet, its text in ink, wrapped with a hanging indent, one level in from its block |
| `doc` | one line of a step's doc string | as written, two levels in, with a rule at its left |
| `cells` | one row of a step's table | its cells at shared column positions, two levels in |
| `blank` | a gap between blocks | nothing |

Every row has a `key` that names it by what it says, not where it is (`step:Given the
agent is called greeter`, and `#2` for the second row saying the same), so a line above it
can come or go and it is still the same line to the next frame (amended in slice 2: keys
were line numbers, and a line landing above renamed everything below it); a `state`, nil
for a line of the file itself; and its `parts`, the texts it is made of with a tone each,
`ink` or `quiet`. Keywords are set apart by tone, never by colour: colour is kept for
state.

A rule's background and scenarios are one level in from the rule. Doc strings wrap like a
step's text (amended in slice 2: a brief cut with "..." was unreadable); tables keep their
cells as written. Nothing in either is read.

## The drawing

`f:draw(rect, measure, size)` answers the items for the rows inside `rect`, in window
pixels, and the height the whole file wants:

- everything is placed from `rect` on every frame, so any window from 320 by 240 up is
  laid out at once; the margin is the larger of two text sizes and six per cent of the
  width, and one level of indent is 1.6 text sizes;
- a step's text and a doc line wrap inside the width and never leave it; a cell too wide
  is cut with "...";
- the file scrolls with the wheel (`f:wheel(dy)`), three rows a tick, clamped to the file,
  and the items are clipped to `rect`; a line that lands below the foot scrolls the file
  to show it;
- the same text, runs and rectangle give the same items every time; `now` (below) moves
  only what changed since the last frame.

`f:set(text)` parses; a text the reader refuses answers nil and the reason, and the last
good file stays drawn. `f:rows()` answers the rows of the last good file.

## On the home screen

The home screen holds one agent file (`h:set_file(text)`) and draws it on the stage
whenever the transcript is closed; Tab shows the transcript in its place, and the wheel
scrolls whichever is showing. The host gives it the text of the agent it opened, when that
agent is a feature file; a Lua declaration has no file to show, and the stage stays plain.

## Live work (slice 2)

A job is an observed scenario at the foot of the file, `f:observed(blocks)`, each block
`{ id, text, state, note }`: `text` the scenario as `observe.live` writes it
(docs/spec/observe.md), `state` one of `running`, `waiting` (it asks the person),
`passed` (it stopped answered), `failed` (any other stop) and `folded`, and `note` the
words a folded run keeps by its name. Its rows are keyed under the job's id. A block the
reader refuses is one line naming the run.

The home screen builds the blocks every frame from the conversation's `jobs()`: while a
job runs, the calls it has made so far (`calls`, read off the transcript it sends its
model, in the shape a result holds them); once it ended, its result; and `home.FOLD`
seconds (6) after it ended, the folded line with how it ended and in how many steps. The
text is written again only when the job's state, its calls or its stop changed.

**Animation.** `f:draw(rect, measure, size, now)` remembers where every line was and
what its state was. Between one frame and the next: a line that arrived slides in over
`EASE` (a fifth of a second), from a little below and from transparent, and keeps a
mark in the added hue at the margin for `ADDED` seconds (2); a line that went stays where
it was for `EASE`, struck through and fading; a line whose place changed eases from where
it was to where it goes; a line whose state changed takes the new state's colour from the
old over `EASE`; a line that did not change does not move. The first frame is settled
whatever the clock says, and with no `now` nothing moves. A state colours the block's
name and a dot at the margin: blue running, yellow waiting, green passed, orange failed;
a folded line is all quiet.

## Self-edits (slice 3)

The agent's file lives in the workspace, `agents/<name>.feature` (the host puts the
notebook there from console/agents/ the first time), and the notebook says `it edits
agents in "agents"`, so a job can change it with the authoring tools (docs/spec/declare.md)
and a person can ask for the change in a sentence. The host reads the file once a second;
when its text changed, `h:set_file` lands the difference on the stage through the same
animation as everything else (a line that came slides in, one that went fades struck
through), and `h:verify(fs, dir)` runs every scenario of the file on the doubles
(`authoring.verify`) and marks each authored one on its Scenario line, green passed or
orange failed; a proposed one, never scored, takes no state. The results are cleared when
the file changes and land again when the run is done, so an edit is seen to validate. An
edit that widens reach goes through `propose`, which asks: the job is `waiting` on its own
line at the foot until the person answers through the bar.

## Delegated runs (slice 4)

A job that hands work to another agent (`it hands work to the agent in "reader.feature"
as reader`) has that run nested under its own scenario, one level in, as a block
`{ id, parent, text, state }` whose `parent` is the job's id. Its lines come from the
job's trace, which is the job's own and live (`jobs()[i].spans`, src/speech.lua gives
each job a recorder and `turn.run` hangs the delegated run's spans under it when it
ends): one `invoke_agent` span under the job's is one nested scenario, named for the agent
and the tool it was handed through, with `it calls <tool>`, `the call to <tool> is
refused`, `the call to <tool> fails`, `it stops with <stop>` and `it takes N steps` for
the spans under it. The trace carries names, counts and terms and never a word of what
was said (docs/spec/trace.md, rule 8), so a nested run says what it did and not with what;
its prompt and its answer are the parent's call line and result. A run nested under a
nested run nests one level further. A folded job folds what it delegated with it.

The plan said the worker's own file would unfold under the hand-off; what unfolds is the
delegated run's observed scenario, which is what the file's own runs are too. The file
of a delegate is one more agent file, and showing it whole is a later slice if it is
wanted.

## Later slices

- Nothing planned past slice 5 (the embeddable host).

## The tests that prove it

- The notebook agent and a feature with tags, a rule, a doc string and a table lay out at
  every size from 320 by 240 to 2400 by 900 with no text past the rectangle's sides, and
  a clip around the items.
- The same text and rectangle give identical items twice.
- The rows come in the file's order, each with its key; keywords are quiet and text is
  ink; a table's cells share column positions across its rows.
- The wheel scrolls no further than the file and no higher than its top.
- A text the reader refuses leaves the last file drawn and says why.
- The home screen draws the file at rest and the transcript in its place with Tab.
- Observed runs come after the file with their state, grow a line at a time as calls land
  under the same keys, and fold to one line with a note; a refused text is one line.
- A line that lands starts transparent and a little low and is in place after `EASE`; the
  lines below shift by its height, eased, and the ones above do not move; a line that
  goes fades struck through and is gone after `EASE`; a state change eases its colour.
- On the home screen a scripted job's scenario shows while it runs, its call lands, its
  stop lands when it ends, and it folds after `home.FOLD`.
- A job's calls so far are listed by the conversation while it runs, and its result and
  when it ended once it has.
- `authoring.verify` answers one entry a scenario with its outcome and whether it is
  authored; the home screen marks the file's scenarios from them, and a proposed one takes
  no state; a new text lands as a difference: the line that came slides in, the line that
  went fades.
- A delegated run nests one level under its job with its calls and stop, from the trace,
  and folds with it; a run under it nests one further.
- The module names neither `love`, `io` nor `os`.
