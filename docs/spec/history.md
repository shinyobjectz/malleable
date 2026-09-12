# history — every run, kept as a story and its evidence

`src/history.lua` and `src/hdc.lua`. Contract, not implementation: written 2026-09-11,
before the code, from docs/history-plan.md and the decisions made on it the same day. It is
amended before the code diverges from it.

## What it is for

An agent's runs vanish when the process ends. Nothing an agent did yesterday can be read
today, by a person or by the agent, and nothing over time can be shown. This keeps every
run: as a scenario a person can read and run again (the **story**), and as a record of
everything behind it (the **evidence**), both under an **id** that says where and when the
run happened. Each run is also kept as a **hypervector**, so runs can be found by the
circumstances they happened in, with no model.

## The words

Checked with `monty onto check` on 2026-09-11; each was free. "branch" is taken (a wire's
control in typeaway), so the field is `git_branch` and prose says "the git branch".

- **history** — everything kept for one workspace: every entry, its stories and an index.
- **entry** — one run, kept: its id, its story, its evidence and its hypervector.
- **story** — an entry's scenario, in the day's feature file.
- **evidence** — everything else about the run, opened by the id.
- **kept text** — a long text an entry holds apart, named `<id>#<n>`.
- **hypervector** — 8192 bits standing for an entry's circumstances (`src/hdc.lua`).
- **tap** — a port wrapped so it remembers what passed through it.

## The id

    notes@main/2026-09-11/14-32-07-notebook-job

It says, in order: the **worktree** (the workspace folder's name) and its **git branch**; the
**day** and the **time** it started, in local time; the **agent**; and the **cause**. With no
git repository, the first part is the worktree alone. On a detached head, the git branch is
the commit's first seven characters. A git branch's `/` is written `~`, which git never
allows in a branch name, so the id stays one path: `notes@feature~voice/...`.

Two entries that would get the same id (two jobs of one agent starting in the same second)
are told apart with `-2`, `-3`: `...-notebook-job-2`. An id is claimed when its run
**starts**, so a job can name the talker reply it came from before that reply has ended, and
it is never reused.

An id is also a path: the entry's evidence is kept under it. Any unique leading part of an
id finds the entry: `--recall notes@main/2026-09-11/14-32`; failing that, any part no other
id holds does (`2026-09-11/14-32-07`, `14-32-07-notebook-job`), because a model shortens an
id from the front as often as from the back.

The causes: `cli` (a command line), `talk` (a talker's reply), `job` (a job a talker started),
`beat` (the clock), `edit` (an agent changing its own feature file), `run` (anything else
that ran an agent with a history).

## What an entry holds

**The story** is the observed scenario (spec/observe.md), tagged with the id, the cause, and
the entry it came from:

    @notes@main/2026-09-11/14-32-07-notebook-job @job @from-notes@main/2026-09-11/14-32-05-talker-talk
    Scenario: write a new note at notes/shopping.md saying buy oat milk
      Given the human approves write
      And the model calls write with {"path":"notes/shopping.md","text":"buy oat milk"}
      ...

It is appended to `stories/<agent>/<day>.feature`, one feature a day. Every line is one the
observer can say. A text longer than 20 lines, or 2000 bytes, is not written into the story;
the story names it, and the name opens it:

    Given the file "notes/budget.md" contains the text kept as notes@main/.../14-32-07-notebook-job#1
    Then the file "notes/budget.md" holds the text kept as notes@main/.../14-32-07-notebook-job#2

Those two lines are new to the vocabulary (spec/behaviour.md). When the story runs again,
the runner finds the kept text in the history it is given, and a missing one is a failed
step that says which.

**The evidence** is one record, JSON, written whole:

| field | holds |
| --- | --- |
| `id`, `parent` | the entry, and the entry that started it (a job's talker reply) |
| `cause`, `agent` | why it ran, and which declaration ran |
| `where` | `worktree`, `git_branch`, `commit` (read from `.git`, never by running git) |
| `started`, `ended` | epoch seconds, UTC |
| `prompt`, `stop`, `reason`, `steps`, `budget`, `answer` | the run, as `turn.run` answered it |
| `calls` | each call: step, tool, args, output, ok, refused, asked, edited, the gate's answer, ms |
| `transcript` | every message, in order |
| `model` | the model and reasoning level, and each call to it: ms, usage, error |
| `errors` | the run's error, each call that raised, each model call that failed |
| `files` | each path read or written: its text when first read, before its first write, and after its last |
| `commands` | each command: argv, code, out, err, timed out |
| `notes` | the run's notes |
| `declaration` | the declaration's text, when it came from a feature file, and its length |
| `spans` | the run's spans (spec/trace.md) |
| `kept` | the kept texts' numbers, and what each is |

A diff is never kept; it is made from `files` when asked for.

**The hypervector** is below.

## Where it is kept

    <workspace>/.malleable/history/
      runs/<id>/entry.json         the evidence
      runs/<id>/<n>                a kept text
      stories/<agent>/<day>.feature
      index                        one line an entry: id, then the fields a search reads
      vectors                      one hypervector an entry, in the index's order

The index and the vectors are rebuilt from `runs/` when they are missing or disagree with it.

## The port

    p.history.where()            -> { worktree, git_branch, commit, offset }
    p.history.claim(id)          -> true | false          -- false: taken
    p.history.write(path, text)  -> true | nil, why
    p.history.append(path, text) -> true | nil, why
    p.history.read(path)         -> text | nil, why
    p.history.list(dir)          -> names | nil, why

Paths are relative to the history's folder. `offset` is the local time's offset from UTC, in
seconds. `claim` makes `runs/<id>/` and answers false if it was there, so two processes
cannot take one id. `bin/world.lua` keeps it under the workspace; `double.history()` keeps it
in memory, and every test here uses that.

`bin/world.lua`'s port reads where the workspace sits from the files git keeps, never by
running git: the nearest `.git` above the workspace, a `.git` file naming a worktree's folder
(and its `commondir`), `HEAD`, the ref's file or else `packed-refs`. It claims with a `mkdir`
that fails when the folder is there, writes a file beside its place and renames it over, and
replaces the model keys it was given with `[key]` in every text it writes.
`world.ports { only = "history" }` answers the history alone, with no model key, for the
command line's reading flags; `history = false` keeps none.

**The port is authority.** Like `model` and `ask`, it is never handed to a tool body. A tool
reaches the history only through the three reading tools below, which hold a view that reads
and cannot write.

## How a run is kept

`agent.run` keeps an entry when the port has a `history` and `opts.entry` is not `false`.
`opts.entry` may name the cause and the parent: `{ cause = "job", parent = "<id>" }`, the
feature text (`declaration`), and `claimed(id)`, called the moment the id is claimed.

One function does it: `history.keeper(run)` wraps any run function of the shape `turn.run`
has, and answers one. `agent.run` goes through it (with the feature text it was declared
from), and so do a command-line run (`cli`), a talker's reply and its jobs (`talk`, `job`),
and a beat (`beat`). `history.keeps(run)` marks a run function that keeps on its own, such as
one that calls `agent.run`, and `keeper` hands it back unchanged, so a run is never kept twice.

1. **Claim the id**, from `where()`, the clock, the agent and the cause.
2. **Tap the ports.** `history.tap(port)` answers a port whose `fs` remembers every read
   (the text) and every write and removal (the text before), whose `sh` remembers each
   command and its result, whose `model` remembers each reply, its time and its error, and
   whose `ask` remembers each question and answer. The tap passes everything through
   unchanged, errors and yields included.
3. **Run.**
4. **Write the entry**: the evidence and the kept texts under the id, the story appended to
   the day, a line in the index and a vector in the vectors. A failed write is a note on the
   result (`the history could not be kept: ...`), never a failed run.

The result carries `result.entry`, the id. A talker's reply is kept as `talk`, and each job
it starts as `job` with the reply as its parent (src/speech.lua).

## Hypervectors

An entry's hypervector is a bundle of **role–filler pairs**, each the binding of a role's
vector and a value's vector:

    worktree ⊗ "notes"   git_branch ⊗ "main"   agent ⊗ "notebook"   cause ⊗ "job"
    day ⊗ level(day)     hour ⊗ level(hour)    stop ⊗ "answered"    parent ⊗ <parent id>
    tool ⊗ "write"       read ⊗ "notes/budget.md"   wrote ⊗ "notes/shopping.md"
    asked ⊗ "write"      refused ⊗ ...         error ⊗ <kind>      then ⊗ <each Then line>

`src/hdc.lua` has the arithmetic, and nothing else:

- **8192 bits**, kept as a 1024-byte string and written as hex.
- **A value's vector** comes from its name, by a fixed generator seeded from the name, so the
  same name is the same vector on every machine and no codebook is kept.
- **Bind** is exclusive or; **bundle** is the majority of each bit (ties broken by a fixed
  vector); **similarity** is the share of bits that agree, 0.5 for unrelated vectors.
- **Levels** make near values similar: an hour of the day is one of 24 vectors on a circle,
  so 23:00 is near 00:00; a day is one of 64 on a circle. Two hours apart shares more bits
  than ten hours apart.

**Finding** an entry is building a vector from what is known and ranking the entries by
similarity to it:

    history.find(h, { git_branch = "main", wrote = "notes/todo.md", day = "2026-09-10", hour = 15 })
    history.find(h, { like = "notes@main/2026-09-11/14-32-07-notebook-job" })

Each result says which of the asked fields it matched exactly (from the index, not the
vector), so a ranking is always explained. A field that matches no entry exactly still ranks
its neighbours: the day before, the hour after, a run with the same tools. A `file` that ends
in `/` is a folder, and matches every path under it.

The order: what matched more of the asked fields comes first. Then, for a question of
nearness (`day`, `hour` or `like`), the more similar; then the newer. Between entries that
matched the same fields of an exact question, the vectors differ only by the noise of every
other field (about 0.006 at 8192 bits), which is no order, so the newer comes first; and an
entry that matched none of an exact question's fields is left out, since it is only a newer
run.

This is not semantic search. Two runs are near when they happened in the same place, at a
near time, by the same agent, touching the same files, doing the same things, and never
because their words are alike. No model reads anything.

## How an agent looks back

`it can read its history`, an is-line, and `agent.history` on the prefix, give an agent three
tools. None writes.

| tool | args | answers |
| --- | --- | --- |
| `history` | any of: `day`, `since`, `hour`, `agent`, `cause`, `stop`, `tool`, `file`, `wrote`, `like`, `limit` | the date and time now, then one line an entry, best first: id, cause, how it stopped, the prompt's first line, and what matched |
| `recall` | `id` (or a unique leading part), `from` | the entry's story |
| `evidence` | `id`, `part`, `which` and `from` | one part of the evidence: `calls`, `call` (which = its number), `transcript`, `errors`, `commands`, `files`, `diff` (which = a path), `kept` (which = its number), `model` |

An answer over the tool's limit (`history.CUT`, 6000 characters) is cut with a line saying
how many more there are and the `from` to ask again with; the history is never changed by
reading it. A world with no history answers "this world keeps no history".

**The wall.** The files kit refuses any path under `.malleable/`, whatever its declaration
says, so an agent reaches its history only through these three tools. An agent with a shell
can still reach it; a shell is already the widest reach there is, and the gate says so.

## The command line

    malleable --history [--day D] [--since D] [--file P] [--stop S] [--cause C] [--agent A] [--like ID] [--limit N]
    malleable --recall ID
    malleable --evidence ID PART [WHICH]

Each reads the workspace at `--root`, and none runs an agent or needs a key. A run the
command line makes is kept as `cli`, and its summary line ends `kept as <id>` (`entry` in
`--json`).

## Failure modes

- **No `history` port.** Nothing is kept, and nothing says so: tests and doubles have none.
- **The claim fails a thousand times.** The run goes on unkept, with a note.
- **A write fails.** The run's result is unchanged but for a note; what was written is left,
  and the index is rebuilt from `runs/` next time it disagrees.
- **An entry does not parse.** It is skipped by `find`, and `recall` says so.
- **A kept text is missing.** `evidence` says which; a story that names it fails that step.
- **A reply the person cut.** Its run is abandoned where it stood and is not kept; the folder
  its id claimed stays empty, and `find` passes over it. A job it started is kept.
- **The key.** Every text is checked for the model key's value before it is written, and a
  match is replaced with `[key]`. The key is never in a request the tap sees (the provider
  adds it), so this is a second wall.

## What it must not do

- Hand the port to a tool body, or let the files kit reach `.malleable/`.
- Reach `io`, `os`, a clock or a random number except through ports. The generator behind a
  value's vector is seeded from the name.
- Summarise or cut the evidence. A story references a long text, and never shortens it.
- Fail a run because its entry could not be kept.
- Read a model's words to decide where an entry goes or how it is found.

## The tests that would prove it

`test/hdc_test.lua`, `test/history_test.lua`:

1. Two values' vectors agree on about half their bits; a vector is the same on LuaJIT and Lua
   5.5 (a fixed value's hex is pinned).
2. Binding twice undoes it; a bundle is nearer each of its members than a stranger.
3. Hours two apart are nearer than hours ten apart, and 23 is near 0.
4. The id: every part, a branch with `/`, a detached head, no git, and `-2` for a clash.
5. The tap passes reads, writes, commands, replies, errors and yields through unchanged, and
   remembers each.
6. A run kept on the doubles: the evidence holds every call's output, the files before and
   after, and the model's replies; the story parses and runs again, and passes.
7. A long file becomes a kept text, and the story that names it runs again.
8. A failed write is a note and the run's result is otherwise the same.
9. `find` by git branch and file ranks the matching entries first and says what matched; a
   day with no entries still ranks the day before above a month before.
10. `history`, `recall` and `evidence` answer from a kept history; `evidence ... diff` is a
    line diff of the file before and after.
11. The files kit refuses `.malleable/history/index`, and list, glob and search never show
    it; a tool body is never handed the port. `bin/world_check.lua` holds the disk port: git
    read from its files (a branch with `/`, packed-refs, a detached head, a worktree, no git),
    a claim won once, the key never written.
12. A conversation keeps its talker reply and the job it started, the job naming the reply.
13. The file reaches nothing: no `io`, `os` or `math.random` in either file.
