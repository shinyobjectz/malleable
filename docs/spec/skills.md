# skills — a procedure the workspace keeps

`src/skills.lua`. Contract, not implementation. The document is amended before the code
diverges from it.

## What it is for

Three things in this tree look alike and are not the same, and the confusion between
them is what this seam exists to end.

* A **tool** is a body in this process. The agent calls it; the model never reads it.
* A **plan** (`spec/work.md`) is this run's list, and the agent wrote it. It dies with
  the run, and the agent may rewrite it at any point — that is what a plan is for.
* A **skill** is a procedure a **person** wrote. It outlives every run, every agent that
  loads it reads the same words, and the agent may read it but not rewrite it.

Without the third, everything a workspace knows about how work is done here has to be
pasted into a system prompt or re-derived by the model on every run. Both fail the same
way: silently and by degrees.

## Vocabulary

Checked before use. `skill`, `briefing` and `catalogue` are used as defined here.
`procedure` is used in prose and is not a name in the code. A skill's one-sentence
summary is its **about**, the same word a tool uses, because it is the same thing:
what the model is told before it decides whether to look further.

## Progressive disclosure

**The briefing carries the name and the sentence. The body arrives only when asked
for.** `skills.briefing` renders one line per skill — the name and the author's own
sentence, never a summary this module wrote — and `turn.run` appends it to the system
message. The body is read by one tool, `skill`, taking one argument.

The reason is a failure mode, not a token count. Twelve procedures pasted into a system
prompt is twelve procedures the model half-remembers: it follows the shape of one and
the details of another, and nothing in the transcript says that is what happened. A
procedure that had to be asked for is a procedure that was read.

## Two sources, and what happens when they collide

A skill is declared in Lua

    agent.skill "triage" { about = "how this team triages an issue", does = "1. …" }
    agent.skill "deploy" { about = "the deploy checklist", file = "docs/deploy.md" }

or it comes from the world through the `skills` port, which owes

    list() -> { { name = string, about = string }, ... } | nil, err
    read(name) -> text | nil, err

Exactly one of `does` and `file` may be stated: two sources for one procedure is a
procedure nobody can be sure they are reading. A `file` skill is read through the fs
port at the moment the model asks, so editing the file changes the next run and not
this process.

**A name held by both is reported, not merged and not shadowed silently.** The declared
one is what `skill` returns, and the run carries a note saying the workspace holds
another under that name. Merging two procedures is nonsense; shadowing one in silence
means the person who wrote the second one thought the name was free.

## The catalogue

`skills.catalogue(a, where)` answers a list of `{ name, about, from }` — declared skills
first, in declaration order, then the world's, alphabetically — and, second, the list of
clashing names. It never raises: a world that cannot answer costs its skills and not the
run.

## Errors are sentences

`skills.body` answers `nil, sentence` rather than an error value, because what it
returns goes to the model and a model cannot act on a code. A skill that does not exist
is answered with **the list of skills that do** — never a near miss offered as a
correction, which is how a model comes to run a procedure believing it asked for
another.

## What it does not do

It does not summarise a skill (a summary of a procedure is a different procedure), does
not act on one, does not remember one between calls, and does not decide when one
applies. The tool answers with the author's words and the next step is the model's.
