# An agent's history: the plan

Written 2026-09-11. A plan, not a contract. Its decisions were made the same day, and the
contract is now `spec/history.md`; where the two differ, the spec is right.

Every run an agent makes is kept, as Gherkin a person can read, under an id. The id opens
everything behind the story: the model's replies, each call's arguments and output, the
errors, the files before and after, and the diff between them. People read it, and the
agent can read it too, through tools that can look and never change anything.

This is the first of three steps. The second is how that history and the files that exist
now are managed and parsed: versions of the declaration, a file's timeline, and what the
agent does and has stopped doing. The third is how it is shown. This plan does the first
and leaves room for the other two.

## What exists, and what does not

Most of the pieces are already in the tree.

- **`observe.scenario`** turns a finished run into a scenario that can be run again: the
  world it saw as Given lines, the model's replies as a script, the prompt as the When,
  and every call, note, file written and answer as Then lines. It speaks only the
  vocabulary people write in, and what it has no words for comes back as a gap.
- **The trace** (`src/trace.lua`): spans with names, counts, durations and decisions, and
  no payload (rule 8). Safe to send to a collector.
- **The console's record** (`console/lib/record.lua`, `console/lib/steps.lua`) already has
  the two tiers this needs, a trace and a local log with payload, and reads the log back
  as Gherkin. But it covers programs on the console's doubles only.
- **Run results** hold the transcript, every call and the errors, in memory.

What does not exist:

- **Nothing is written down.** A run's result, its observed scenario, its repertoire and
  its session are all thrown away when the process ends. `bin/world.lua` has no store, so
  even `session.save` has nowhere to go.
- **No lasting id.** A run's id is its agent's name; a job's is `j1` within one
  conversation.
- **Real runs are not observed.** The observer reads a double's world, which remembers what
  was written. The real world (`bin/world.lua`) remembers nothing, so there is nothing to
  read files, commands or changes back from.

## The shape: an id, a story, and the evidence

Each run leaves three things.

**An id** that says where and when: `notes@main/2026-09-11/14-32-07-notebook-job`, the
worktree and git branch, the day, the local time it started, the agent and the cause. A job
names the talker reply it came from as its parent. Ids are never reused. (Decided
2026-09-11; spec/history.md has the details, and adds a hypervector to every entry.)

**The story, in Gherkin.** One scenario per run, appended to the agent's feature file for
that day. It is the observed scenario with the id as a tag, what caused it as a tag, and
the run it came from:

    # Kept by the harness, not written by a person: every line is a thing that happened.
    Feature: notebook, 2026-09-11

      @notes@main/2026-09-11/14-32-07-notebook-job @job @from-notes@main/2026-09-11/14-32-05-talker-talk
      Scenario: write a new note at notes/shopping.md saying buy oat milk
        Given the human approves write
        And the model calls write with {"path":"notes/shopping.md","text":"buy oat milk"}
        And the model answers "Created notes/shopping.md."
        When the agent is asked "write a new note at notes/shopping.md saying buy oat milk"
        Then it stops with answered
        And it takes 2 steps
        And the human is asked about write
        And it calls write with {"path":"notes/shopping.md","text":"buy oat milk"}
        And the file "notes/shopping.md" holds:
          """
          buy oat milk
          """

It reads as what happened. It is also a test: the history of a day runs again on the
doubles with `--verify`, and a scenario from it that stops passing is a behaviour the agent
has lost. That is `kept.feature` for every run, not only the ones a person keeps.

A long file or output does not go into the story whole. Past a limit (twenty lines, say),
the story names it by reference, and the reference opens it:

    And the file "notes/budget.md" holds the text kept as notes@main/2026-09-11/14-32-07-notebook-job#1

That needs one new Given line and one new Then line in the vocabulary, and the runner
resolves the reference from the history when the scenario runs again.

**The evidence.** Everything else about the run, as one record, opened by the id:

| part | what it holds |
| --- | --- |
| `calls` | each call: tool, arguments, whole output, ok or refused, what the gate asked and was told, how long it took |
| `transcript` | every message, in order, with the model's usage for each reply |
| `errors` | the run's error, a tool that raised (with its traceback), a provider's failure and its retries |
| `files` | each file the run read (as it was) and wrote (before and after), so any change can be shown as a diff |
| `commands` | each command line, its exit code, and what it printed |
| `spans` | the trace, with timings |
| `declaration` | the declaration the run was made under, as text, so a change to the agent can be set beside a change in what it did |
| `model` | which model, the reasoning level, tokens, and the time each call took |
| `where` | the workspace, and its git commit if it is a repository (read from `.git`, not by running git) |

A diff is not stored; it is made from the before and after when asked for.

## Where it lives

    <workspace>/.malleable/history/<agent>/
      2026-09-11.feature        the day's stories, appended, one scenario a run
      runs/2026-09-11-0007.1    the evidence for one run, as JSON
      runs/2026-09-11-0007.1/3  a kept text: a file's contents, a long output
      index                     one line a run: id, parent, time, cause, stop, steps, files touched
      next                      the day's next number

In the workspace, because the history is about the work done there, and it moves with it.
The index can always be rebuilt from `runs/`; it is there so a search does not open every
record.

## How a run is recorded

1. **The world is tapped.** Before a run, its ports are wrapped: the filesystem remembers
   what was read and written (with the contents before), the shell what ran and what it
   printed, the model each reply and how long it took, the gate each question and answer.
   This is what lets the observer read a real run as it reads a double's.
2. **The run happens**, as now.
3. **The record is written** through a new `history` port: the story appended to the day's
   file, the evidence written whole under its id, a line added to the index. It is written
   whole or not at all, like a session.

`src/` stays pure: the tap, the record, the story and the index are Lua over ports. Only
`bin/world.lua` (and the console's host) touch the disk, through the port. The doubles get a
history port in memory, so every part is tested without a disk.

**What causes a record.** Every run, whatever started it:
- a `malleable` command line;
- each talker reply in a conversation (`@talk`), and each job it starts (`@job`, from the reply);
- a beat (`@beat`);
- an edit an agent makes to its own feature file (`@edit`, with its reach and the diff);
- a scenario or an eval sample (`@scenario`, `@eval`), optional, because tests run thousands.

A conversation's turns are one scenario each (a scenario has one When):
`When the person says "..."`, with what the talker said and did as Then lines. That is one
more line for the vocabulary.

## How the agent looks back

An is-line, `it can read its history`, gives an agent three tools. None of them writes.

- **`history`**: finds runs by date, cause, how they stopped, a tool they called, or a file
  they touched, and answers one line per run: the id, when, the prompt, how it stopped.
  It filters by fields; the model does the reading.
- **`recall`**: one run's story, by id.
- **`evidence`**: one part of one run, by id: `calls`, one call's whole output, `errors`,
  `transcript`, `commands`, or `diff` for a file.

The history itself is outside the files kit's reach: `.malleable/**` is never touched by an
agent's file tools, the same way `secrets/**` can be walled off. An agent that could rewrite
its own record would have no record.

People get the same through the command line:

    malleable --history [--since 2026-09-10] [--file notes/todo.md] [--stopped refused]
    malleable --recall 2026-09-11-0007.1
    malleable --evidence 2026-09-11-0007.1 diff notes/shopping.md

## What it must not do

- **Let an agent write its own history**, or read it except through the three tools.
- **Hold the key.** The model key never reaches a record. Anything that looks like the key
  is refused at write time, as `record.clean` already does for the console's trace.
- **Leave the machine.** The story and the evidence stay local. Only the spans, which carry
  no payload, may go to a collector.
- **Summarise.** Every call is a line in the story, as the observer already insists. A long
  text is referenced, never cut.
- **Slow a run down.** A record is written once, when the run ends, and a failed write is a
  note on the result, never a failed run.

## Decisions to make

Each has a recommendation; the plan above assumes it.

1. **Where history lives.** In the workspace, under `.malleable/history/` (recommended), or
   in `~/.malleable/`, apart from the work.
2. **The id.** Decided 2026-09-11: not day and count, but where and when, as a path:
   `notes@main/2026-09-11/14-32-07-notebook-job` (worktree and git branch, day, local time,
   agent, cause). And every entry is also kept as a hypervector of its circumstances, so
   runs are found by where, when, by whom and doing what, with no model. spec/history.md.
3. **Long texts.** Referenced past a limit (recommended), or always whole in the story. Whole
   is simpler, and a day file with a few read notes in it grows fast.
4. **Kept texts: stored once, or once per run.** Once per run first (recommended), because it
   needs no hash function and the files are small. Storing by content, the way git does,
   waits until the size says it is needed.
5. **Test runs.** Scenarios and evals are recorded only when asked (recommended), because a
   test suite would bury the real history.
6. **The talker.** Whether the talker, not only its jobs, gets `history`, so "what did you do
   this morning?" is answered at once instead of by a job. Recommended yes, the listing only.

## The order of the work

Each step ends on a test that proves it.

1. **`spec/history.md`**, from this plan and its decisions.
2. **The tapped world.** A real run's file reads, writes, commands and replies are
   remembered. Test: the observer reads a tapped double exactly as it reads the double.
3. **The record and the port.** The evidence written whole under an id; the id counter; the
   in-memory double and the disk port in `bin/world.lua`. Test: write, read back, ids unique
   across days, a failed write leaves nothing.
4. **The story.** The day's feature file, appended; references for long texts; the new
   vocabulary lines. Test: every recorded day parses and runs again on the doubles, and
   passes (the observer's round trip, over history).
5. **Every cause.** The command line, the talker, jobs, beats, edits. Test: one conversation
   with a job leaves a turn and a job, linked by `@from`.
6. **Looking back.** The three tools and the three command-line flags; the wall around
   `.malleable/`. Test: an agent finds yesterday's run by a file it touched and reads its
   diff; its file tools cannot open the history.
7. **Measured.** A day of real use through the home screen: how big the history gets, how
   long a write takes, and whether a job asked "what did you change yesterday?" answers from
   the evidence.

Then the second step: the declaration's versions, a file's timeline across runs, and the
repertoire over the history, which is what the display will draw from.

## Where it stands (2026-09-11)

Built to `spec/history.md`, steps 1 to 6, with step 7 measured on a short session, not yet
a day.

- **Kept.** `history.keeper(run)` (src/history.lua) is the one place a run is kept:
  `agent.run`, a command-line run (`cli`), a talker's reply and its jobs (`talk`, `job`, the
  job tagged `@from-` its reply), and a beat (`beat`). The `edit` cause is named and not yet
  used: nothing edits a feature file through a run today.
- **The port.** In memory (`double.history`) and on disk (`bin/world.lua`, under
  `<root>/.malleable/history`, git read from its files, claims by `mkdir`, the key written
  `[key]`). `bin/world_check.lua` holds the disk side.
- **Looking back.** `it can read its history` / `agent.history` gives history, recall and
  evidence; the notebook agent has it. The talker gets the listing alone when its world
  keeps a history. `--history`, `--recall`, `--evidence` on the command line. The files kit
  refuses `.malleable/` whatever a declaration says.
- **Tests.** `test/history_test.lua` (25) and `test/hdc_test.lua` (7), passing on LuaJIT and
  Lua 5.5; the whole suite is 1241 passed, and its 34 failures are the tests that still
  read `example/`, `programs/` and `spec/` from before the move.

Measured through the home screen and the command line, with GLM 5.3:

- **Size.** 13 entries were 93 KB of evidence, about 7 KB an entry, and 2 KB of vector hex
  each. The day's story file is the smallest part.
- **Time.** Keeping a run costs 14 ms on the disk port (27 ms before folders were
  remembered), against a model call of about a second; opening 30 entries takes 2 ms, and a
  search 0.3 ms.
- **Looking back works, and the first try showed why the tools changed.** Asked "what did
  you change in my notes earlier today?", the talker answered from the listing in one step.
  Asked for the change line by line, the job first took 8 steps: it shortened ids from the
  front (`12-21-29-notebook-job`), which found nothing, and the talker guessed the date
  (`2025-05-08`). Now any part of an id no other id holds finds the entry, the listing
  begins with the date and time, a `file` ending in `/` is a folder, and an exact question
  lists what matched and newest first. The same question then took the job 4 steps, the
  third reading the diff.
- **Still open.** The talker still guesses a day before it has seen the listing; the `day`
  argument now says not to. A reply the person cuts is not kept (its run is abandoned); its
  jobs are.
