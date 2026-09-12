# The agent file — the plan

Written 2026-09-11, the same day the stage plan (docs/stage-plan.md) was set aside. The
ruling that replaced it: Typeaway is the interface; this agent is for editing itself and
running long coding tasks; the console is a UI layer that renders an agent and can be
embedded, not a product; nothing here is about programs, carts or generated apps. What the
console shows of an agent is one thing, **the agent's own file with its state showing**,
and the bar along the foot stays as it is. Tickets are under epic mar-1vnp. The contract
goes to `docs/spec/agent-file.md` before the code of slice 1.

## The idea

An agent is already one Gherkin file (docs/spec/declare.md): the `Background:` says what it
is, the scenarios say what it does, and the file is what it edits when it improves itself.
The console shows that file, laid out and readable, and lays the agent's state over it:

- **at rest**, the whole file, as it stands;
- **when it edits itself**, the diff landing on the text, then the authored scenarios
  re-running and each one taking its result, so an edit is seen to validate;
- **when it works**, a job as an observed scenario at the foot, whose lines land as its
  calls land (src/observe.lua's vocabulary, never words), collapsing to one line with its
  result when it ends;
- **when it hands off**, the worker's own file nested under the line that handed off,
  drawn the same way, so a tree of sub-agents reads as one document.

It is not the log, and it is not editable in the window: the agent owns it. It is not
prose either; everything on it is Gherkin, a line the agent's own reader could take back.

The one mechanism under all four: **the document is a render of the feature text plus the
runs observed so far, and the screen animates the diff between one render and the next.** A
self-edit, a job's new line, a scenario turning green and a worker unfolding are all the
same thing to the screen, a line added, removed or re-marked, so there is one animation,
one test of it, and nothing bespoke per state.

Name: **agent file** (`monty onto check`: free; "document" is Typeaway's page, "soul" is
coined). In prose, "the file".

## What is here already

- **The file** is parsed by `gherkin.document` and compiled by `src/declare.lua`; edits go
  through `src/authoring.lua`, walled by reach, and are scored on the authored scenarios.
- **A run read back as Gherkin** is `src/observe.lua`: a trace becomes a scenario in the
  closed vocabulary, with gaps recorded rather than filled with harness nouns.
- **Scenarios run without a model** through `src/behaviour.lua` on the doubles.
- **The conversation** (src/speech.lua) emits `job`, `done`, `question`, `report`,
  `found`, `cut`, `reply`, `failed`; the history keeps every run.
- **The home screen** (console/lib/home.lua) and **the bar** (console/lib/bar.lua): the
  dot grid, captions, hints, typing, the transcript, Esc. The stage above the bar is a
  rectangle the home screen hands to whatever draws there.
- **The host** (console/main.lua): LÖVE window, keys, mouse, the network thread, the voice
  pipeline (console/ml), script verbs for headless checks and screenshots.

## What goes, and why

The user's words: eliminate the console in the capacity that it is about apps; get rid of
the AG-UI stuff and the console app rendering structure for the most part; LÖVE stays as
the base. So the rule for removal is **the home screen and what it reaches**: a file
`console/main.lua` does not need to open the home screen with a voice goes. By that rule:

| goes | lines | what it was |
| --- | --- | --- |
| console/lib/{stage,sketch,views}.lua, src/view.lua, the show/try/update/views tools, kits.views, `it can show views`, the three stage phrases, their tests, docs/spec/stage.md, docs/stage-plan.md | 2 379 + ~450 in speech/kits/behaviour | the stage work of 2026-09-11 (slices 1–4 and the unfinished 5) |
| console/lib/{console,screen,ui,program,palette,font,prompt,record,playback,turn_clock,steps,suite,tests,mutate,walk,world,desk,brow,cursors}.lua | ~6 000 | the program machine: the 128×128 framebuffer, the cart sandbox, the traces, the busted dialect, mutation, the walk, the world map, the brow |
| console/lib/{agui,viz,chat}.lua, console/agui.lua | ~700 | the AG-UI stream and the chat thread |
| console/{bind,build,candidates,folder,frames,render,pack,ship,verify,live,lip}.lua | ~1 700 | the builder, the headless renderers, packing and shipping carts, the window rim |
| console/builder, console/bench, console/vendor, console/captures, console/parity, programs/ | 1 313 + 15 553 + 2 222 | the builder loop, the bench of programs, luassert for the busted dialect |
| test/console_*.lua except home and net | ~2 900 | their tests |
| docs/spec/{console,programs}.md, docs/{plan-develop.md,plan-develop.feature,plan-develop-owed.lua,seeing-an-agent.md} | ~2 000 | their contracts and the plans they came from |

Kept: `console/main.lua`, `conf.lua`, `lib/{bar,home}.lua`, `ml/` whole, `agents/`,
`test/{console_home,ml_*}_test.lua`, docs/spec/{home,ml,speech}.md. (`net_thread.lua`,
`lib/net.lua` and `storage.lua` turned out to be the programs' network and store; the home
screen's world is bin/world.lua's, so they went too.)
`src/` is the harness and is untouched apart from taking the stage tools back out.

Console Lua goes from 14 043 lines to about 5 200 before slice 5, and the tree loses about
28 000 lines counting the bench. Removal is by editing and deleting, never by checkout,
because other sessions share the tree; the stage tools come out of `src/speech.lua` by
editing them out, and STEPS.md is regenerated.

## The document, in enough detail to test

**Layout.** The file is laid out from `gherkin.document`, not from its text, so what is
shown is what the agent reads: the Feature line, its description, the Background with its
is lines, each scenario with its steps, doc strings and tables in their own blocks.
Keywords are set apart by weight, not colour; colour is kept for state. The file scrolls
with the wheel, fits any window from 320 by 240 up, and lays out to the same items every
frame for the same input.

**State marks.** A line carries at most one mark: `added` and `removed` (a diff landing),
`running` (a step in flight), `passed` and `failed` (a scenario's last result, with when),
`waiting` (a question or a propose the person has not decided), `folded` (a run or a
worker collapsed to one line). Marks are read from the trace, the run's stop and the
scenario results, never from any words in the file or the transcript.

**Observed scenarios.** A job appears at the foot as `@observed` scenario with the title
observe gives it, and its lines land as the trace grows: this needs observe to read a
partial trace, which is slice 2's one piece of harness work. When the job ends the block
folds to its one line and result; the history keeps the whole.

**Animation.** Between two renders, lines that are in both stay; a line only in the new
render slides in over a fifth of a second from a little below and from transparent, marked
`added` for two seconds; a line only in the old strikes and fades; a line whose mark
changed takes its new colour over the same fifth. Nothing bounces, nothing moves that did
not change, and the whole page never re-flows for one line landing (lines below shift by
the height of what landed, eased).

**Sub-agents.** A hand-off's observed line unfolds into the worker's file, indented one
level and drawn by the same renderer, with its own marks; a worker's subagents nest one
level deeper. A finished worker folds to its Feature line and result. Depth is bounded by
the harness's own bound on delegation.

**What it never does.** It does not take edits from the person (they talk or type; the
agent edits). It does not show the transcript (Tab does, as now). It does not read a word
of the file or of any turn to decide a mark.

## The slices

Each one: contract amended in `docs/spec/agent-file.md`, tests without a model on both
Luas, then a measurement on a real run when there is something a real model changes.

0. **mar-ufjf, removal.** The table above, measured before and after: lines, tests,
   the eight rules, the app opening to the home screen with a spoken and a typed turn.
1. **mar-6rtz, the file at rest.** The contract, then `console/lib/file.lua` (name checked
   before it is written): layout from `gherkin.document` for every agent under `example/`
   and `console/agents/` at every window size; the home screen shows it whenever nothing
   is running.
2. **mar-22m8, live work.** Observe over a partial trace; observed scenarios at the foot
   landing line by line and folding on done; the diff animation, tested as items over
   time; a question marked `waiting` at its line while the bar takes the answer.
3. **mar-12a7, self-edits.** An `edit` or `propose` on the agent's own file lands as a
   diff; the authored scenarios re-run on the doubles and each takes its result; a
   propose is `waiting` until the person decides.
4. **mar-tn67, sub-agents.** The worker's file nested under the hand-off, recursive;
   then the real measurement on GLM 5.3: one conversation with a self-edit and a
   hand-off, screenshots kept under docs/, what was unreadable listed here.
5. **mar-8wi4, the embeddable host.** `console/main.lua` down to a window, the bar, the
   file, the voice, the network thread and the script verbs; the program-era chrome out;
   shipped as a `.love` that opens to an agent named on the command line, measured in
   lines.

Slices 1 to 3 are in a line; 4 needs 2; 5 needs 3.

## Decisions taken here, to be overturned by saying so

- At rest the file is shown whole: the agent readable when it is doing nothing is the
  point of the screen, and the last few folded runs stay under it.
- Observed runs go at the foot, not inside the scenario that resembles them; matching a
  run to an authored scenario is observe's agreement, and it can mark the scenario later
  (slice 3 or after) without moving anything.
- Answers stay in the bar: no buttons on the file. A question is a mark at its line.
- LÖVE stays as the host, so what is built here embeds in Typeaway later as it is.

## Measurements

**Slice 0, 2026-09-11.** Console Lua 14 043 → 3 961 lines (main.lua 1 514 → 435, and what
is left is main, conf, lib/{bar,home}, ml/). Tests 26 146 → 21 208 lines; the suite went from
1 004 passing and 34 failing to 1 053 passing and 15 failing on both Luas, and every failure
left is the folder move (example/, spec/ paths) that predates this work; the eight rules
hold. The stage tools came out of src/speech.lua, kits, declare, behaviour (three phrases;
STEPS.md regenerated) and agent.lua. The app opened on the slimmed host and a typed turn
went through the real talker and a job ("You don't have any notes yet").

**Slice 1, 2026-09-11.** `console/lib/agent_file.lua` (270 lines) draws the notebook agent
at 320 by 240, 560 by 665 and 1400 by 860 (screenshots kept in the session's scratchpad,
slice1/): keywords quiet, text ink, doc strings ruled, tables in columns, the transcript in
its place on Tab. 6 tests on both Luas, plus one on the home screen. Seen and left for
later: a long doc line (the brief) is cut with "..." rather than wrapped, as the contract
says; a brief reads better wrapped, and slice 2 can change that when it touches rows.
Nothing time-based is in the render yet, so slice 2's animation starts from a render that
is a pure function of text and rectangle.

**Slice 2, 2026-09-11.** A job is an observed scenario at the foot of the file. The live
source is the transcript a job sends its model (`jobs()[i].calls`, src/speech.lua), read
into the shape a result holds, and `observe.live` writes the scenario so far from the same
writers as a finished one. The render keys rows by what they say, so a line landing above
does not rename the lines below (the first cut keyed by line number and every line below a
new one jumped). Animation is one mechanism in `agent_file.draw`: arrive, go, shift, and
colour, each eased over a fifth of a second; 8 tests on the file, 25 on the home screen, 26
on speech, both Luas; the whole suite 1 066 passing, the 14 folder-move failures left; the
eight rules hold. Real run on GLM 5.3 ("what notes do I have, and how many words are in
them?"): the job's scenario landed under the file with the When line while it ran (blue),
then its two calls and its answer, then the Then lines with the stop (green); screenshots
in the scratchpad, slice2/. Seen and fixed from the screenshots: the state dot was drawn
once per wrapped line of a long scenario name. Seen and left: a job's title is its whole
task and wraps to two lines; the fold waits home.FOLD seconds after the job ends, which is
right, but the script's shot came before it.

**Slice 3, 2026-09-11.** The agent's file lives in the workspace (`agents/notebook.feature`,
seeded from console/agents/ the first time) and an `author` agent beside it holds the
authoring tools, because a notebook that both reads and writes the workspace and edits
agents declares `edit` twice (the fs kit's and authoring's), which declare refuses; the
talker hands editing to the author. The host reads the file once a second and, when it
changed, lands it as a difference and runs its scenarios on the doubles
(`authoring.verify`, new). Real run on GLM 5.3 ("have the author add a proposed scenario
to agents/notebook.feature that says: when asked what notes there are, the notebook calls
list on notes/ and answers with their names"): the author read the file and the vocabulary,
made the edit, and verified; the host saw the file change three times (0.00–0.01 s to run
2–3 scenarios each time); the @proposed scenario landed under the authored ones, which
stayed green, and the author's job folded to "done after 9 steps". Screenshots in the
scratchpad, slice3/. 10 tests on the file, 26 on the home screen, both Luas. Seen and
left: the host lists the agents it loads by name (notebook, author), not by reading the
folder; a folded job's title is the task's first words, cut.

**Slice 4, 2026-09-11.** Each job has its own recorder (`jobs()[i].spans`), and a run it
delegates hangs its spans under the job's when it ends, so the home screen reads the
delegated runs off the trace and nests each under its job one level in, with `it calls
<tool>`, refusals, failures, the stop and the steps, and never a word of what was said
(the trace carries none). A `reader` agent was seeded beside the notebook and the notebook
says `it hands work to the agent in "reader.feature" as reader`; the talker's workers are
the notebook and the author, and the reader is only the notebook's delegate (the first
cut listed every seed as a worker, and the talker handed straight to the reader). Real
runs on GLM 5.3: the first asked the notebook to use its reader and the notebook read the
file itself in 2 steps; the second named the reader tool and went the whole way: the
delegate's gate asked, the talker relayed it in a sentence, the person's "yes" through the
bar let it run, the reader ran nested, and the notebook reported in 4 steps. The
first screenshots came after the fold (the reader answered within the 12 s the script
waited); a third run with shots two seconds apart caught it (scratchpad, slice4/n2.png):
the notebook's scenario with its `the human is asked about reader` line, and under it,
one level in and green, `Scenario: reader, handed reader`. The doubles test proves the same
(27 on the home screen, 11 on the file). Seen and left: what unfolds is the delegated
run's observed scenario, not the delegate's file, and the spec says so.

**Slice 5, 2026-09-11.** The host was already down to 480 lines after slice 0 (the
program-era chrome went with the program machine), so this slice is the shipping:
`scripts/ship.sh` packs the tree's Lua into `build/malleable.love` (65 files, 370 KB)
with console/main.lua at the archive's root; the host tells the archive from the tree by
whether `src/speech.lua` is inside it, and sets LÖVE's require path to the harness and
the real ports. `love build/malleable.love --no-voice --root <scratch>` seeded the three
agents into the scratch workspace, drew the notebook's file, and took a typed turn through
the real talker and a job (screenshot in the scratchpad, slice5/). The voice's engine
loads a native library relative to console/ml on disk, so a shipped console speaks only
with the tree beside it; the models (4.7 GB) were never going in the archive. Console Lua
in all: 1 754 lines (main 480, agent_file 380, home 560, bar 165).