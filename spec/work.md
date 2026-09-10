# work — plans, todos and checkpoints

`src/work.lua`. Contract, not implementation. No code exists yet; the module is written
to this document, and this document is amended before the code diverges from it.

## What it is for

A coding agent earns trust over a long run by saying what it is about to do and by being
undoable when it does the wrong thing, so this subsystem holds the two records that make
that possible: a **plan**, an ordered list of items the agent states before acting and
marks off as it goes, rendered as one plain block for the person and for the model; and a
**checkpoint**, the exact contents of the files a turn is about to touch, captured before
the edit so the turn can be taken back. Undo restores those files to their captured
bytes — it does not merge, diff or reconcile, and anything written to those paths after
the checkpoint is gone. Every function here is either pure or reaches the world through
the filesystem slice of the port table, so the whole subsystem runs in a test with no
network, no disk, no subprocess and no clock.

## Vocabulary

Checked against the repo ontology before use. `plan`, `todo`, `checkpoint`, `undo`,
`restore`, `snapshot` and `item` are unspoken for and are used as defined here. `step` is
**not** used for a plan entry: the repo defines `step` as one call within a machine call,
and `spec/turn.md` already uses it for one pass of the loop. A plan entry is an **item**.
`task` is not used either — the repo has claimed it for something else entirely.

## Where it sits

    declaration file ->  work.install(agent, { ... })      -- declares two tools
    a turn hook      ->  work.take(port, paths, { ... })   -- before a body writes
    the host         ->  work.undo(port, cp)               -- from outside the loop

`work` is a library the host and a declaration file call. It is not part of the `agent`
prefix: nobody writes `agent.plan`. `install` adds two ordinary tools through
`agent.tool`, exactly as a hand-written declaration would, so a reader who understands
one understands the other.

`work` requires nothing else in this tree — not `spec`, not `turn`, not `session`, not
`port`. It sits beside `port` at the bottom of the stack and everything above may use it.

## The world it takes through a port

`spec/port.md` is the authority. If it and this section disagree, port wins and this file
is amended rather than worked around in code. `work` uses four calls from `port.fs` and
nothing else — no clock, no shell, no model, no approval channel, no store:

    port.fs.read(path)         -> text | nil, err
    port.fs.write(path, text)  -> true | nil, err
    port.fs.remove(path)       -> true | nil, err
    port.fs.exists(path)       -> boolean

`err` is the port's error table, `{ port, call, code, message }`. `work` never parses a
message and never branches on the wording; it branches on `code` in exactly one place
(`not_found` on a read, which is a legal capture and not a failure) and otherwise carries
the table through untouched inside its own failure value.

Paths are workspace-relative strings, whatever the port says they are. `work` does not
normalise, join, resolve or validate a path beyond requiring a non-empty string: a path
that leaves the workspace is refused by the port with `denied`, which is a miss, and
duplicating that rule here would let the two drift apart.

## The convention this module holds

The same line `session` holds: **a wrong argument type raises; a bad world returns.**

* Passing a number where a path belongs, a state that is not one of the four, a `port`
  with no `fs` — these are faults in the calling code. They call `error()` with a
  sentence naming the argument, and they stop at the line that made them.
* A file that will not read, a path the port denies, a plan id that does not exist, a
  byte cap reached — these are the world and the model misbehaving, and they come back
  as `nil` plus a `reason` string the caller must look at.

Nothing here ever returns `false` for failure. `reason` is one lowercase sentence
fragment naming the thing that was wrong and, where there is one, the path or id it was
wrong about.

One function breaks the pattern deliberately, and it is the important one: **`work.undo`
always returns a report and never returns nil.** See its entry.

## The shapes

### An item

    { id = "3", text = "Write the failing test", state = "doing", note = nil }

`id` is a decimal string, minted by the plan, never reused within one plan's life. `text`
is a non-empty string, one line, at most `max_text` bytes. `state` is one of `"todo"`,
`"doing"`, `"done"`, `"dropped"`. `note` is a string or nil — a sentence attached when the
item was marked, which is where "dropped: the file already did this" lives.

At most one item in a plan is `"doing"`. That invariant is enforced by `mark` and `start`,
not merely documented, because a rendered plan showing two things in flight at once is a
plan nobody believes.

### A plan

    { items = { item, ... }, revision = 4, seq = 7 }

`items` is ordered and is the order it renders in. `revision` counts accepted changes and
lets a host cheaply notice one. `seq` is the id counter; it only ever goes up, so an id
the model read in an old render never comes to mean a different item later.

### A checkpoint

    {
      id      = "cp2" | nil,          -- minted by the trail on push, nil before that
      label   = "edit src/turn.lua",  -- one sentence, may be ""
      files   = { { path = "src/turn.lua", text = "…", existed = true }, ... },
      bytes   = 4210,                 -- sum of captured text lengths
      count   = 2,
    }

`files` is sorted by path and holds one entry per distinct path. `existed = false` means
the path was absent when the checkpoint was taken, and `text` is nil for it; undoing such
an entry removes whatever is there now. A checkpoint is plain data: it can be held,
passed, counted and serialised by the caller, and it carries no closure and no port.

### A trail

    { items = { checkpoint, ... }, cap = 8, max_bytes = 8388608, seq = 3, bytes = 12040 }

Newest last. Bounded in both count and bytes, because a long run that captured every edit
would hold the whole workspace in memory.

### An undo report

    { restored = 2, removed = 1, skipped = 0, failed = { { path = …, reason = … }, ... },
      complete = true }

`complete` is `true` exactly when `failed` is empty. Always populated, always a table.

## The public API

The module returns a table of functions and two frozen tables. It holds no module-level
mutable state: two plans and two trails in one process share nothing, no upvalue, no
counter, exactly as `spec.new` promises for agents.

### `work.states -> { "todo", "doing", "done", "dropped" }`

Frozen, in that order, so a caller can build an exhaustive branch and a test can assert
the set has not grown. A new key raises. Overwriting one of the four slots does not, and
cannot in this dialect — see the note below — but it changes nothing except the writer's
own view, because the module reads its own copy of the set.

### `work.defaults -> table`

Frozen. `{ max_items = 32, max_text = 400, max_files = 64, max_bytes = 4194304,
cap = 8 }`. Read to know a limit; overridden per call, never by writing into this table:
every write to it raises, including one to a key that is already there.

**What "frozen" can mean here.** `defaults` is read by key, so it is a proxy over hidden
values and nothing can be written into it. `states` is read with `#` and `ipairs`, and
LuaJIT 5.1 answers neither `__len` nor `__index` for those, so the same proxy would make
`#work.states` zero on one of the two interpreters this tree targets and a caller's
exhaustive branch would silently cover nothing. It is a real list with a `__newindex`
that raises instead, which is the strongest seal that shape allows in both dialects. The
module never reads either published table, so neither is load-bearing.

### `work.plan(items [, opts]) -> plan | nil, reason`

Builds a plan. `items` is a list; each entry is either a string (the text) or a table
`{ text = string, id = string|nil, state = string|nil, note = string|nil }`. Returns a
fresh plan with ids minted `"1"`, `"2"`, … in order for entries that carry none.

`opts` is nil or `{ max_items = n, max_text = n }`.

**An empty list is legal.** `work.plan {}` returns a plan with no items, revision 1. An
agent that states an empty plan has said "nothing to do", and that is a thing worth being
able to say and to render. It is not an error and it is not nil.

Returns `nil, reason` when: an entry is neither a string nor a table; `text` is missing,
not a string, empty, or over `max_text`; `text` contains a newline (a plan item is a line,
and one that wraps a paragraph is how a plan stops being scannable); `state` is not one of
the four; two entries carry the same `id`; more than one entry is `"doing"`; or the list
is longer than `max_items`. The reason names the offending index.

Raises when `items` is not a list, or `opts` is not a table or nil. A table that is not
a list raises rather than reading as empty: an object is the shape a decoded tool call
arrives in when a model got the argument wrong, and answering "no items" to a caller that
sent some is how a plan disappears without anyone being told. *(Amended after the build:
the first draft said only "not a table", and a table with string keys built an empty plan
in silence.)*

An entry may carry its own `id`, and a fresh plan honours it: the ids it was handed are
the ids it holds, minting is used only for the entries that carry none, and `seq` ends
past every id in the list so a later mint can never collide with one of them.

It copies. The caller's list and the tables inside it are not retained and not mutated.

### `work.set(plan, items [, opts]) -> plan | nil, reason`

Replaces the whole list, in place, and bumps `revision`. This is the operation the model
performs when it re-states its plan, so its merge rule is the one thing in this subsystem
a model can be surprised by, and it is deliberately mechanical:

* An entry carrying an `id` that the plan already knows **keeps that item's `state` and
  `note`** if its `text` is byte-identical to what that id currently holds.
* An entry carrying a known `id` whose `text` differs is a different item wearing an old
  label. It keeps the id and resets to `"todo"`, note cleared.
* An entry carrying no `id`, or an `id` the plan does not currently hold, is new and gets
  a fresh id from `seq` — never a recycled one, even if the item it replaces is gone. An
  id that was issued once and has since been dropped is in this case too: the item it
  named is gone, so there is no state left to keep, and honouring the id would let a
  stale render bring an item back from the dead.
* A `state` or a `note` stated in the entry itself is what the caller asked for and wins
  over both rules above. The keeping and the resetting decide only the fields the entry
  left out, which is what makes `{ id, text, state }` round-trip through a render.
* An item in the plan that no entry mentions is dropped from the list entirely.

There is no matching by text, by prefix or by similarity anywhere in this rule. The id is
the identity; it is why `render` prints ids at all.

Same validation and same `nil, reason` failures as `work.plan`. **On any failure the plan
is unchanged** — validation completes before a single field is written, so a model that
sends a bad replacement does not lose the plan it had. Raises on a `plan` that is not a
table, and on an `items` that is not a list, for the reason `work.plan` gives.

### `work.mark(plan, id, state [, note [, opts]]) -> item | nil, reason`

Sets one item's state. Returns the item as it now stands (the live table in the plan, not
a copy — reading it is fine, writing into it is a caller bug this module cannot see).
Bumps `revision`.

`opts` is nil or `{ max_text = n }`, and exists so a host that raised `max_text` at
`install` time does not then have its notes refused by `mark`'s default. A `note` of nil
clears whatever note the item carried: a note records the mark it came with, and leaving
the old sentence attached to a new state is how a plan starts lying.

Every transition is allowed, `"done"` back to `"todo"` included; a coding agent reopens
work it thought it had finished, and refusing that would only teach it to restate the
whole plan to say so. The one rule enforced is the single `"doing"`: marking an item
`"doing"` while another is `"doing"` returns `nil, reason` naming the item already in
flight. Use `work.start` when displacement is what you meant.

Returns `nil, reason` when `id` is not an id this plan holds, or when `note` is over
`max_text`. Raises when `state` is not one of `work.states`, or when `id` is not a string:
a caller passing the item's index instead of its id is a bug, and quietly accepting a
number here would make ids and positions interchangeable, which they are not.

### `work.start(plan, id) -> item, displaced | nil, reason`

Marks `id` as `"doing"`. If another item was `"doing"`, it is put back to `"todo"` and its
id is the second return; otherwise the second return is nil. This is the only place the
single-doing invariant is resolved by moving something rather than refusing, and it is
separate from `mark` so that displacing is always something the caller asked for by name.

Returns `nil, reason` for an unknown id. Starting an item that is already `"doing"` is a
no-op returning it with a nil second value, not an error. Raises on an `id` that is not a
string, for the reason `mark` does. The displaced item keeps its note: it was put back by
someone else's decision, and the sentence recording its own last mark is still true.

### `work.next(plan) -> item | nil`

The item in flight if there is one, otherwise the first `"todo"` item in order, otherwise
nil. `nil` means there is nothing left to do — a finished plan and an empty plan both
answer nil, and neither is a failure. Pure, no allocation beyond the return.

### `work.progress(plan) -> done, total, doing`

`done` counts `"done"` items. `total` counts every item that is not `"dropped"`, so a
dropped item does not sit forever in the denominator making a finished plan look
unfinished. `doing` is the id of the item in flight, or nil. Three plain values, so a
caller can format them any way it likes without reaching into the plan.

### `work.render(plan [, opts]) -> string`

One plain-text block, always a string, never nil, ending without a trailing newline.

    Plan (2/5)
      1. [x] Read the turn loop
      2. [x] Find where a call is dispatched
      3. [>] Write the failing test
      4. [ ] Make it pass
      5. [-] Update the changelog -- not needed, it is generated

Markers are `[ ]` todo, `[>]` doing, `[x]` done, `[-]` dropped. A note follows its item
after ` -- `, two hyphens rather than an em dash, because the block promises bytes below
128 and an em dash is three of them. An empty plan renders as exactly `Plan (0/0)` and a
second line `  (no items)`. Bytes only: no colour, no escape sequence, no character above
127, so the block survives any transport a host puts it through and two runs agree byte
for byte. **The text and the note come from a model, so `render` is where that promise is
kept**: any byte outside printable ASCII is rendered as `?`. The item keeps the bytes it
was given; only the block is narrowed.

**The heading's denominator counts every item in the block, dropped ones included** — it
is 5 above, not 4 — because a reader can count the lines underneath it and a number that
disagrees with them is a number nobody trusts. `work.progress` answers the other question
and leaves a dropped item out of its total, so a finished plan reads as finished there.
The two numbers are deliberately different and each is right about its own question.

`opts` is nil or `{ ids = false }` to drop the numbers, `{ heading = "…" }` to replace the
word `Plan`. Nothing in `opts` can make the output depend on a clock, a locale or table
iteration order.

`render` is pure and total: it does not fail, and it renders a plan with a state it does
not recognise as `[?]` rather than raising, because a render is the thing a person is
looking at when something has already gone wrong.

### `work.take(port, paths [, opts]) -> checkpoint | nil, reason, misses`

Captures the current contents of every path in `paths`, before whatever is about to
change them. `paths` is a list of non-empty strings; duplicates are collapsed and the
result is sorted by path, so two takes of the same set are identical tables.

`opts` is nil or `{ label = string, max_files = n, max_bytes = n }`.

For each path in sorted order: `port.fs.read(path)`. Text comes back — capture it with
`existed = true`. `not_found` comes back — capture `existed = false`, `text = nil`, and
carry on; a checkpoint whose job is to make a new file undoable is the commonest case
there is, and treating a missing file as a failure would leave exactly that case
unprotected.

**Any other failure refuses the whole take.** The remaining paths are still read, so
`misses` is a list of every one that failed — `{ path = …, err = <the port's error
table> }` — rather than only the first: a caller deciding whether to proceed unprotected
wants the whole list in one look, not one per attempt. `reason` names the count and the
first path. This is the central judgement in the subsystem: a
checkpoint that captured four files out of five cannot restore the fifth, so an undo built
on it would half-restore and report success. A partial checkpoint is not a checkpoint. A
caller that gets nil must decide whether to proceed unprotected or to stop, and it must
decide visibly.

**An empty list is legal.** `work.take(port, {})` returns a checkpoint with no files,
zero bytes, which undoes to a report of all zeros. The caller does not need a special case
for a tool that touched nothing.

Caps are checked as the bytes arrive, in path order: more than `max_files` paths refuses
before any read; passing `max_bytes` in total refuses at the path that crossed it, naming
it and the running total. Both are `nil, reason` with an empty `misses`. There is no
truncation and no partial capture at a cap, for the reason above.

Raises when `port` is not a table or `port.fs` lacks `read`, `write`, `remove` or
`exists`; when `paths` is not a list; when an entry is not a non-empty string; when `opts`
is not a table or nil, or carries a `label` that is not a string or a bound that is not a
whole number of at least 1. A port call that raises instead of returning is caught here
and becomes a miss, with the raised value stringified into the miss's `err.message` and
its `code` set to `malformed`, which is the code for a far side that answered with
something this port cannot read — `take` does not let a broken host escape into the
middle of a turn. A `read` that answers with something that is neither a string nor nil
is a miss for the same reason.

### `work.undo(port, cp) -> report`

Restores the checkpoint. For each file entry, in path order:

* `existed = true` — `port.fs.write(path, text)`. Unconditionally. `undo` does not read
  the file first, does not compare it to the capture, does not skip a file that looks
  unchanged and does not merge anything. `restored` increases.
* `existed = false` and `port.fs.exists(path)` — `port.fs.remove(path)`. `removed`
  increases.
* `existed = false` and the path is absent — nothing. `skipped` increases.

**`undo` always returns a report and never returns nil.** It attempts every entry even
after one fails, because stopping halfway through a restore leaves the workspace in a
state neither the checkpoint nor the turn describes, which is worse than either. A failure
appends `{ path = …, reason = <the port's message, or the raised value stringified> }` to
`report.failed` and sets `complete = false`. A port call that raises is caught per file
and recorded the same way. This is a deliberate divergence from `spec/port.md`'s rule that
a raising port should stop the caller: here, letting a shape bug in a host's `fs.write`
abandon a half-finished restore would trade a loud test failure for a corrupted workspace.

`undo` is idempotent. Running it twice produces the same report values (the second run's
`restored` count is the same, because it writes the same bytes again) and leaves the same
bytes on the port. It is safe to retry after a partial failure.

Raises when `port` is malformed as above, or when `cp` is not a table with a `files` list,
or when an entry of that list is not a table carrying a non-empty `path`. **Every entry is
checked before the first byte is written**, so a checkpoint this module cannot read stops
the caller where it stands instead of half-way through a restore -- the one state undo
exists to prevent. `work.changed` and `work.push` check the same thing, in the same place.
*(Amended after the build: the first draft raised from inside the restore loop, having
already written the files ahead of the bad row.)*

### `work.changed(port, cp) -> changed, unknown`

Reads each captured path now and compares it byte for byte with the capture. Returns two
lists of paths: `changed` (differs, or existed then and is absent now, or was absent then
and is present now) and `unknown` (the port would not answer, so it cannot be compared).
**A path that cannot be read is `unknown`, never `unchanged`** — an undo preview that
quietly counts an unreadable file as clean would understate exactly the damage a person is
about to authorise.

Exists so a host can tell someone what an undo will actually touch before asking for it.
`work` itself never calls it and never gates undo on it.

### `work.describe(cp) -> string`

One plain line: `cp2 "edit src/turn.lua" -- 2 files, 4210 bytes`, with the same two
hyphens and the same ASCII rule as `render`. An unfiled checkpoint renders its id as
`(unfiled)`; an empty label is omitted with its quotes. Both counts are pluralised, so
one file reads `1 file, 210 bytes`. Pure, total, byte-stable; it raises only on a `cp`
that is not a table.

### `work.trail([opts]) -> trail`

A fresh bounded trail. `opts` is nil or `{ cap = n, max_bytes = n }`. Raises on a
non-positive or non-integer bound.

The defaults are `cap = 8` and `max_bytes = 8388608`. That byte bound is twice
`work.defaults.max_bytes`, which is the cap on a single `take`: a trail that could not
hold two full-sized checkpoints would evict the turn before last every time a large edit
was captured. It is stated here rather than in `defaults` because it bounds a trail, not
a take, and one `max_bytes` meaning two different limits is how a host sets the wrong
one.

### `work.push(trail, cp) -> trail, evicted`

Appends `cp`, minting `cp.id` as `"cp" .. trail.seq` when it has none, then evicts from
the **oldest** end until the trail is within both bounds. `evicted` is the list of
checkpoints dropped, in the order they were dropped, so a host can say which turns are no
longer undoable rather than discovering it later.

A checkpoint that arrives already carrying an id keeps it, and the trail's `seq` moves
past it when it reads as `cp<n>`, so one trail can never mint a name a checkpoint it
already holds is wearing. *(Amended after the build: without that, one checkpoint pushed
into two trails left the second able to mint the same name twice, and `describe` would
then name two turns alike.)*

Minting writes `cp.id` into the checkpoint the caller handed over. It is the one place
this module writes into a value it was given, and it is why `describe` can name a turn at
all: an id that lived only in the trail would be lost the moment the checkpoint was
passed anywhere else.

`push` never refuses. A single checkpoint larger than `max_bytes` on its own leaves the
trail holding exactly that one checkpoint, over its byte bound, rather than being dropped
on the floor: a turn that is about to rewrite a large file is precisely the turn most
worth being able to undo. That over-bound state is visible in `trail.bytes` and is not
hidden.

### `work.last(trail) -> cp | nil`

The newest checkpoint, or nil for an empty trail. Does not remove it.

### `work.pop(trail) -> cp | nil`

Removes and returns the newest, adjusting `trail.bytes`. Nil for an empty trail — an
empty trail is a normal state, not a failure.

### `work.undo_last(port, trail) -> report | nil, reason`

`pop` then `undo`. Returns `nil, "the trail is empty"` when there is nothing to undo. The
checkpoint is popped **before** the restore is attempted and is not put back if the
restore partly fails: the report says what failed, and re-applying a checkpoint whose
restore already half-ran would not improve on it. A caller that wants to retry holds the
report and the checkpoint it was handed.

**Only the newest checkpoint is undoable through a trail.** Undoing an older one while
newer ones stand would restore files the newer checkpoints captured mid-edit, producing a
workspace that matches no turn that ever happened. `work.undo` will happily take any
checkpoint you hand it, because a checkpoint is just data — the ordering discipline lives
in the trail, where the ordering is known.

### `work.install(agent, opts) -> installed`

Declares the plan tools on an agent. Runs no body, makes no port call, reads no file:
rule 2 still holds for a declaration file that installs this subsystem.

`agent` is the public prefix table. `install` uses exactly `agent.tool` and the argument
constructors `agent.list`, `agent.string` and `agent.string_opt`, and touches nothing
else on it.

`opts` is nil or:

| key | type | default | meaning |
| --- | --- | --- | --- |
| `plan` | plan | a fresh empty plan | the live plan the tools mutate |
| `names` | table | `{}` | rename a tool: `{ plan = "todo_write" }` |
| `on_change` | function or nil | nil | called as `f(plan)` after any accepted change |
| `max_items` | number | from `work.defaults` | passed to `set` |
| `max_text` | number | from `work.defaults` | passed to `set` |

Two tools are declared, and only two:

* **`plan`** — `about`: states or replaces the whole plan. Args: `items`, a list, each
  entry a string or `{ id, text, state, note }`. The body calls `work.set` and returns
  `work.render` of the result, so the model reads back the plan it now has, with its ids.
  A rejected replacement returns the reason as an ordinary tool output; the model fixes it
  and tries again.
* **`mark`** — `about`: marks one item. Args: `id` (string), `state` (string), `note`
  (optional string). Calls `work.mark`, or `work.start` when `state` is `"doing"`, and
  returns the render. An unknown id returns the reason and the current render, so the
  model can see which ids exist instead of guessing again. `start` takes no note, so on
  the `"doing"` path the body attaches the note to the item it started, after checking
  it against `max_text`, and bumping `revision` itself when that note is the only thing
  that changed — which is why a model can say why it picked something up, and why a host
  watching the revision does not miss the line it is about to render.

Both bodies check what the model sent before calling in, and answer a bad argument with
a sentence and the current render -- an `items` that is not a list included, which is why
the library is free to raise on one. Nothing a model can put in a tool call raises out of
a body: an id that is not a string, a state that is not one of the four and a note that
is not a string are all ordinary tool output, because a raise here would end the turn
over a typo.

Neither tool sets `ask = true`. A plan is a statement, not an action, and putting a human
in front of it would teach the agent to stop writing one.

`on_change` is called after `set`, `mark` and `start` succeed, inside the tool body, and
its return value and any error it raises are discarded — a host's renderer must not be
able to fail a tool call. It is not called for a rejected change.

Returns `installed`, `{ plan = <the live plan>, tools = { plan = "…", mark = "…" } }`.
`installed.plan` is the one piece of live state this module ever hands out, and it is
named so the host can render it between turns.

`install` **raises** on a bad `opts`: an unknown key, a `names` entry that is not a
non-empty string, an `on_change` that is not a function, a `plan` that is not a plan
table. That is a bug in the host's own file, caught at declaration time, and it must stop
the process rather than become a sentence a model reads.

**There is no undo tool, and there will not be one.** See below.

## The failure modes

Every row below is a value the caller receives. Nothing here raises except a wrong
argument shape.

**The plan is empty.** Legal everywhere. `next` is nil, `progress` is `0, 0, nil`,
`render` says so in two lines, `set` on it works normally.

**The model replaces the plan and loses its marks.** Only for items whose text it changed
under an existing id, or which it re-sent with no id. Both are stated in `work.set` and
both are visible in the render the tool body hands straight back, in the same turn, which
is the cheapest possible feedback loop for a model that is misusing the tool.

**The model sends a bad plan.** `nil, reason` naming the index and the fault; the plan is
untouched; the tool body returns the reason as output. A model that sends fifty items
against `max_items = 32` is told the limit and the count, not silently truncated.

**The model marks an id that does not exist.** `nil, reason`. The tool body returns the
reason together with the current render, so the ids that do exist are in front of it.
Never an error, never a silently created item — a `mark` that invented the item it was
told to mark would let a model believe it had finished work it never listed.

**Two items in flight.** `mark(…, "doing")` refuses and names the item already doing;
`start` displaces it and says which. There is no path through this module that leaves two
`"doing"` items in a plan, including through `plan` and `set`, which both refuse an input
carrying two.

**A checkpoint path is missing.** Captured as `existed = false`. Not a failure. Undo
removes the file, which is the correct inverse of "the turn created it".

**A checkpoint path cannot be read** — `denied`, `too_big`, `timeout`, `unavailable`, or
anything else the port says. The whole take is refused: `nil, reason, misses`. The caller
is left with a live decision to make and no illusion of protection.

**A checkpoint would be enormous.** Refused at `max_files` or `max_bytes` with the path
and running total named, before the rest is read. No truncation, no partial capture.

**A port call raises during `take`.** Caught, turned into a miss, so the take is refused
in the ordinary way. A broken host cannot escape into the middle of a turn from here.

**A restore fails on one file.** Recorded in `report.failed`, the remaining files are
still attempted, `complete = false`. The caller sees a report that is honest about a
half-restored workspace instead of an exception thrown from an unknown position.

**A port call raises during `undo`.** Caught per file, recorded as a failure with the
raised value stringified. Deliberate, and the one place this tree catches what
`spec/port.md` says should stop the caller; the reason is written into `work.undo` above.

**Undo is run twice.** Same report, same bytes. Idempotent by construction, because a
restore is a whole-file write of a fixed string and a removal of a path that is checked
first.

**Undo throws away work.** It always might. Anything written to a captured path after the
checkpoint was taken is replaced by the captured bytes with no comparison and no warning
from this module. `work.changed` exists so a host can find out first, and the decision to
undo belongs above this module, with the person. This is a property of the design, stated
plainly, not a bug to be softened later with a merge.

**The trail is full.** The oldest checkpoints are evicted, returned from `push`, and can
no longer be undone. A host that says nothing about that will eventually tell someone
"nothing to undo" about a turn they watched happen.

**The trail is empty.** `pop` and `last` return nil; `undo_last` returns
`nil, "the trail is empty"`. Not a failure state, just the beginning of a run.

**The process dies.** The trail was in memory and is gone; the workspace keeps whatever
the last turn wrote. `work` does not persist and does not pretend to survive a crash. A
host that needs durable undo serialises checkpoints itself through the store port, which
is `session`'s business, not this module's.

**A timeout.** `work` has no clock and no deadline of its own, so a timeout reaches it
only as an error code from `port.fs.read`, where it is a miss like any other and refuses
the take. This is stated rather than left implicit: a subsystem with no clock cannot
promise a time bound, and its bounds are the file count and the byte cap instead.

**Re-entry.** `work` holds no module-level mutable state, so a `take` running while
another `take` is in flight — a hook that fires inside a tool body that is itself running
a nested turn — cannot corrupt either. `undo` declares no hook, fires no event and calls
no tool, so it cannot re-enter the turn loop from inside itself.

## What it must NOT do

* **It must not decide when a checkpoint is taken, or of what.** It captures the paths it
  is handed. It does not read a tool's arguments, does not know which tools write, does
  not guess a path from a shell command line. That policy belongs to the host wiring, in
  a hook, where a reader is looking for it.
* **It must not give the model an undo tool.** `install` declares `plan` and `mark` and
  nothing else, ever. An agent that can restore the files it just changed can erase the
  evidence of a bad turn between the turn and the person reading about it; undo is reached
  from outside the loop, by the host, on a person's word.
* **It must not ask.** There is no `port.ask` in its slice and no approval logic in it.
  Undo is destructive and gating it is `spec/approval.md`'s job. A module that both
  performs a destructive act and decides whether it is allowed has no gate at all.
* **It must not merge, patch or three-way anything.** No diff, no hunks, no conflict
  markers, no "restore only the lines the turn changed". Undo is a whole-file write of
  captured bytes. The moment this module tries to be clever about what to keep, its
  promise stops being checkable.
* **It must not persist.** No store port, no serialiser, no file of its own. The trail is
  memory. `session` owns storage.
* **It must not require a sibling.** `src/work.lua` contains no `require` of `spec`,
  `turn`, `session`, `port`, `provider`, `compaction`, `tools_fs` or `tools_shell`. A test
  reads the file for it.
* **It must not touch the world except through the port.** No `io`, no `os.time`,
  `os.date`, `os.clock`, `os.getenv`, `os.execute`, `os.exit`, no `math.random`, no
  `print`. Checkpoint ids come from a counter, not a clock; two runs of the same test are
  byte-identical, ids included.
* **It must not mutate what it was given.** `work.plan` and `work.set` copy their input
  entries; `work.take` copies the path list before sorting it; `work.undo` writes nothing
  into the checkpoint it was handed, so the same checkpoint can be undone again.
* **It must not match text to identify an item.** Ids are identity. No prefix matching, no
  similarity, no "the item that starts with the same three words".
* **It must not render for one UI.** One plain block of bytes below 128. No ANSI, no
  markdown that only one renderer understands, no width that assumes a terminal.
* **It must not log.** It returns values. A host that wants a line writes one.

## The tests that would prove it

All run against `double.fs` from `spec/port.md` and pure tables. No network, no disk, no
subprocess, no clock. Adversarial ones are marked **(adv)**; those are the ones worth
writing first.

1. `a_plan_renders_in_order` — five items, two done, one doing, one dropped with a note;
   the render matches the documented block exactly, byte for byte.
2. `an_empty_plan_is_a_plan` — `work.plan {}` succeeds, `next` is nil, `progress` is
   `0, 0, nil`, and the render is the two documented lines.
3. `ids_are_minted_in_order_and_are_strings` — a plan of three has ids `"1"`, `"2"`, `"3"`.
4. `marking_moves_one_item_and_bumps_the_revision` — `mark` returns the item, `progress`
   moves, `revision` increases by exactly one.
5. `next_prefers_the_item_in_flight` — with one doing and two todo, `next` is the doing
   item; after it is done, `next` is the first todo; when all are done, `next` is nil.
6. `progress_ignores_dropped_items` — three items, one dropped, two done gives `2, 2`.
7. `replacing_keeps_the_state_of_an_unchanged_item` — `set` with the same ids and the same
   texts leaves every state and note intact and bumps `revision`.
8. `taking_a_checkpoint_captures_bytes_verbatim` — a file with an embedded zero byte and
   no trailing newline round-trips through `take` and `undo` unchanged.
9. `undo_restores_a_changed_file` — capture, write something else through the port, undo,
   read: the captured bytes are back and `report.restored` is 1.
10. `undo_removes_a_file_the_turn_created` — capture an absent path, write it, undo:
    `exists` is false and `report.removed` is 1.
11. `a_trail_mints_ids_and_reports_evictions` — push nine into a trail of cap eight; the
    first is returned from `push` as evicted and `last` is the ninth.
12. `describe_is_one_stable_line` — the documented format, and `(unfiled)` before a push.

Adversarial from here down.

13. `a_partial_capture_is_no_capture` **(adv)** — three paths, the middle one denied by the
    port. `take` returns nil, `misses` names that path, and no checkpoint is produced. The
    single most important test in the subsystem: it fails the moment anyone "improves"
    take by skipping what it could not read.
14. `a_missing_file_is_captured_not_refused` **(adv)** — a path the port answers
    `not_found` for yields `existed = false` and a successful take, distinguishing the one
    error code that is not a miss from every code that is.
15. `an_empty_path_list_is_a_valid_checkpoint` **(adv, empty input)** — `take(port, {})`
    succeeds, and undoing it returns a report of all zeros with `complete = true`.
16. `duplicate_paths_are_captured_once` **(adv)** — the same path three times, in three
    orders, produces one entry and identical checkpoints.
17. `undo_does_not_merge` **(adv)** — capture, then append a line the port would call a
    perfectly good edit, then undo. The appended line is gone. This test asserts the
    documented loss, so that any future merge behaviour breaks it loudly rather than
    quietly changing what undo means.
18. `undo_continues_past_a_failure_and_says_so` **(adv)** — three files, `readonly` set on
    the double after capture so every write is denied: the report names all three in
    `failed`, `complete` is false, and the call returns a table rather than nil or a raise.
19. `undo_is_idempotent` **(adv)** — run it twice against the same checkpoint; the second
    report equals the first and the bytes are unchanged.
20. `a_port_that_raises_during_undo_becomes_a_failed_row` **(adv)** — an `fs.write` that
    calls `error()` on the second of three files: the first and third are restored, the
    second is in `failed`, nothing escapes.
21. `the_byte_cap_refuses_before_it_captures_everything` **(adv)** — `max_bytes` crossed at
    the third of five paths: nil with a reason naming that path and the running total, and
    the port was never asked for the fourth and fifth.
22. `the_file_cap_refuses_before_any_read` **(adv)** — more paths than `max_files`, against
    an `fs` whose `read` is wrapped in a counter: the counter is still zero. A cap that
    only bites after doing all the work is not a cap.
23. `a_rejected_replacement_leaves_the_plan_alone` **(adv)** — `set` with a bad entry at
    index four: the plan's items, states, notes, revision and seq are all exactly as
    before.
24. `ids_are_never_recycled` **(adv)** — `set` that drops item `"2"`, then `set` that adds
    an item: the new item is `"4"`, not `"2"`. Proves a stale id in an old render can
    never come to mean a different item.
25. `an_unknown_id_is_told_not_thrown` **(adv, refusal)** — `mark(plan, "99", "done")`
    returns nil and a reason, the plan is untouched, and the declared `mark` tool's body
    returns that reason plus the current render rather than failing the call.
26. `two_items_cannot_be_in_flight` **(adv)** — `mark` to `"doing"` while another is doing
    refuses and names it; `start` displaces it and returns its id; and `work.plan` with two
    `"doing"` entries is refused at construction.
27. `text_is_never_used_to_match_an_item` **(adv)** — a `set` where two items have the same
    text but different ids keeps both, with their own states, and neither takes the
    other's note.
28. `a_timeout_from_the_port_refuses_the_take` **(adv, timeout)** — a scripted
    `{ code = "timeout" }` on one read: the take is refused, the miss carries the code, and
    the test runs in milliseconds with no clock anywhere.
29. `nested_takes_do_not_share_state` **(adv, recursion)** — a `take` whose port `read`
    itself calls `work.take` on another set of paths through a second port. Both
    checkpoints are complete and correct, proving there is no module-level buffer being
    reused; and `work.undo` is shown to fire no hook and call no tool, so it cannot
    re-enter a turn.
30. `two_plans_in_one_process_do_not_leak` **(adv)** — two plans and two trails built and
    mutated alternately; ids, revisions, seqs and bytes never cross over.
31. `install_declares_two_tools_and_no_undo` **(adv)** — the declared tool list is exactly
    the two names, `spec.schema` shows no undo tool under any name, and a `names` table
    trying to add one is refused. Guards the boundary that keeps a model from erasing its
    own turn.
32. `installing_runs_nothing` — `install` on an agent makes no port call and mutates no
    plan; rule 2's test, applied here.
33. `an_on_change_that_raises_cannot_fail_a_tool_call` **(adv)** — a renderer that errors
    is called, its error is discarded, the tool still returns the render, and the plan
    still changed.
34. `wrong_shapes_raise_and_bad_worlds_return` **(adv)** — `work.plan(7)`,
    `work.mark(plan, 3, "done")`, `work.take({}, {"a"})`, `work.undo(port, "cp")` each
    raise with a message naming the argument; while a denied read, an unknown id and an
    empty trail each return nil and a reason. The test that keeps the two-channel
    convention honest in both directions.
35. `work_touches_nothing_real` **(adv)** — read `src/work.lua` as text and fail on `io.`,
    `os.time`, `os.date`, `os.clock`, `os.execute`, `os.getenv`, `math.random` or `print`.
36. `work_requires_no_sibling` **(adv)** — read `src/work.lua` and fail on a `require` of
    any other module in this tree.
37. `a_render_is_reproducible` **(adv)** — build the same plan twice from lists inserted in
    different orders and render both; the strings are equal, and every byte is below 128.

Added by the verification pass, which found each of these unexercised.

38. `changed_says_what_an_undo_would_touch` **(adv)** — `work.changed` had no test at all.
    A file with the captured bytes, one edited, one absent then and present now, one the
    port refuses to read: the first is in neither list, the next two are `changed`, the
    last is `unknown`, and the preview writes nothing.
39. `undo_last_restores_the_newest_and_keeps_it_popped` **(adv)** — only the empty trail
    was tested. Two turns deep: the newest comes back, the older stands, and a restore
    that fails leaves the checkpoint popped all the same.
40. `a_trail_is_bounded_by_bytes_as_well_as_by_count` **(adv)** — eviction by bytes, in
    oldest-first order, and the single over-bound checkpoint that is kept anyway. Also
    that one checkpoint pushed into two trails cannot make one trail mint its name twice.
41. `a_render_narrows_a_byte_the_model_wrote` **(adv)** — text, note and heading each
    carrying a byte above 127: the block is all ASCII and the item keeps its own bytes.
    Nothing tested the promise `render` exists to keep.
42. `a_fresh_plan_honours_the_ids_it_was_handed` **(adv)** — given ids are kept, `seq`
    ends past them, the next mint therefore cannot collide with one, and two entries
    wearing the same id are refused.
43. `a_plan_sent_as_an_object_is_refused_not_obeyed` **(adv, refusal)** — the tool answers
    an `items` that is not a list with a sentence and the plan it still has, and the
    library raises on one. Guards the amendment above.
44. `a_malformed_checkpoint_stops_before_it_half_restores` **(adv)** — a file entry with no
    path in the middle of three: nothing is written before it raises, and the same check
    guards `changed` and `push`.
45. `a_note_on_the_item_in_flight_moves_the_revision` **(adv)** — the note attached on the
    `"doing"` path moves `revision` even when `start` was a no-op, and saying the same
    thing twice does not; a displaced item keeps its own note.
46. `what_it_was_given_is_not_mutated` **(adv)** — the entry tables, the path list and the
    checkpoint handed to `undo` all come back untouched. "It must not mutate what it was
    given" had no test.
