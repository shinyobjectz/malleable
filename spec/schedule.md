# schedule — the beat

`src/schedule.lua`. Contract, not implementation.

## What it is for

Before this seam a run began in exactly two ways: a person typed, or another agent
delegated. A machine has a beat and an agent did not, so *"every evening, summarise what
changed"* was a sentence this harness could not hold at all — not awkwardly, not
partially: there was no name for it.

Two things were missing, and a beat needs both.

* **The declaration.** `agent.every` states the beat in the declaration file, next to
  the tools, under rule 2: this module decides what is *due* and never decides what time
  it is.
* **The ledger.** Without a durable record, *"never twice for the same day"* is not
  expressible. `session` is per conversation and dies with it; an in-process table
  forgets across a restart, which is precisely when a beat double-fires. So the ledger
  is a **port**.

## The declaration

    agent.every "digest" {
      about    = "the evening digest",
      day_at   = "18:00",        -- a wall clock time, or…
      every     = 3600,          -- …a whole number of seconds. Never both.
      runs     = "summarise what changed today",   -- a prompt, or a function
      once_per = "day",          -- "hour" | "day" | "week" | "ever"
      grace    = 7200,           -- skip it if it is more than this late (optional)
      tz       = -25200,         -- the local offset from UTC, in whole seconds
    }

`runs` as a string is a prompt and starts a run of this agent. `runs` as a function is
called with the port and the beat. Nothing here decides which a schedule should be: a
digest is a prompt, a vacuum is a function.

## The ledger

    get(key) -> value | nil          -- nil means NEVER; it does not mean failure
    put(key, value) -> true | nil, err

`value` is a table this module writes and only this module reads: `{ at = <when it
fired>, grain = <the key it fired under> }`. The key is `beat/<agent>/<beat>`.

**The ledger is written before the run, not after.** A run that crashed and a run that
never happened are indistinguishable to a beat, and the failure that costs a person
something is the one where a nightly digest goes out twelve times because each attempt
died before it could record that it had started. A host that prefers the other risk
passes `record = "after"` and has thereby said so.

## The calendar is arithmetic, not `os.date`

`schedule.civil` computes the civil date from a day count directly. Two reasons, which
are the same reason: a test must be able to stand at any instant of any year without
setting the machine's clock, and a run must mean the same thing on two machines in two
zones. A beat carries `tz`; with none, it is UTC.

## Due

`schedule.is_due(beat, now, last)` is pure and is the whole of the decision. It returns
`true`, or `false` and **the sentence saying why not** — because a beat that silently
does not fire is the hardest kind of schedule to debug, and a host should not have to
invent the reason itself. `schedule.due(a, port, opts)` reads the world once (the clock
once, the ledger once per beat) and answers the due list, the held list with its
reasons, and the instant it read.

A wall-clock beat is due once the clock has passed its time and not again until the
grain rolls over, so a host ticking every minute fires an 18:00 beat once and not sixty
times before 19:00.

## A beat whose time passed while nothing was running

Decided 2026-09-10, before the host was written, because the two answers are both
defensible and the difference is invisible from the declaration.

**A late beat fires, once, on the next tick.** `is_due` compares the clock to the
beat's time and the ledger to the grain; neither asks how the gap happened. So an app
shut at five and opened at nine runs the six o'clock digest at nine, and `once_per`
stops it running again that day. The reason is that the work is usually still wanted:
a digest of a day that has ended is a digest, and a person who opens the app the next
morning would rather read yesterday's than nothing.

**Unless the beat says how late is too late.** `grace = <seconds>` is the beat's own
statement that its work expires: a beat more than `grace` seconds past its time is
**skipped**, and the skip is recorded in the ledger under the grain it skipped, so it
does not fire later that same day when the clock comes round again. `schedule.due`
answers the skip with its own sentence — how late it was, and what the beat allowed —
rather than silently holding, because a beat that never fires and never says why is
the failure this whole module exists to make visible.

There is no third state. A beat is due, held with a reason, or skipped with a reason.

## A run the clock started is the same run

`tick` takes its runner as `opts.run`, defaulting to `turn.run`, and `agent.tick` passes
the prefix's own. Everything a host composes before a run — the skills briefing, the
servers' tools — therefore happens for a beat exactly as it happens for a person, and an
agent is not briefed differently depending on who started it. A beat that called the core
directly would differ in a way nobody finds by reading.

## Nothing in the tree calls tick

`schedule.tick` runs what is due. A host calls it — the app on its own beat, a cron
line, a test. The harness never starts a run by itself: an agent that begins running
without anybody asking is not the thing rule 2 describes.
