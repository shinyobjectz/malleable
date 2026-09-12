# subagent — subagents

`src/subagent.lua`. Status: specification. The file does not exist yet; this is the
contract it must meet.

## 1. What it is for

A tool body sometimes needs a whole agent rather than a function: a job with its own
instructions, its own small tool set and its own transcript, run to completion, whose
answer comes back as one tool result the parent model reads. `subagent` is that — it
takes a request to delegate, checks it against the limits that stop a tree of agents
from spawning forever, hands the child its own world, runs it through `turn.run`, and
returns a result whose child transcript the host can read line by line instead of
guessing what happened inside. It owns exactly two things nothing else in the tree owns:
the depth and step accounting that bounds a whole tree of runs, and the rendering that
turns a finished child into the sentence its parent is told.

## 2. Where it sits

    src/subagent.lua      this contract
    src/turn.lua          the only module it requires

It requires `turn` and nothing else. It never requires `spec`, `port`, `double`,
`approval`, `provider`, `compaction` or a tools module. The one visible cost of that is
in 4.1: the argument tables `subagent.tool` returns are the `{ __param = true, kind,
required, description }` shape `src/spec.lua` reads, written out here rather than built
with `spec.types`. Four table literals is a smaller price than a second require, and
`spec.add_tool` refuses anything that does not match, so the two cannot drift silently. It holds no module-level state:
two trees running through one loaded copy of the module cannot see each other, because
everything a tree knows lives in a ledger the caller holds.

### 2.1 The words

Six, used exactly this way below.

- **child** — one run started by `subagent`, with its own declaration, port, budget and
  transcript. A child is an ordinary `turn.run`; there is no second kind of run.
- **tree** — a root run and every child beneath it, however deep. Limits are the tree's,
  not any one run's.
- **ledger** — the one table that counts a tree: steps left in its pool, spawns left,
  and how deep it may go. Every descendant shares it by reference.
- **permit** — what a ledger issues for one child: its id, its depth, and the steps
  reserved for it. A permit is opened before the child runs and closed after, and the
  unspent reservation goes back to the pool.
- **frame** — the permit's travelling half. It rides on the child's port table under the
  key `subagent`, which is how a grandchild finds the ledger its grandparent made.
- **readout** — a flat list of strings describing a finished child, one line per message
  and per tool call, for a host or a session to store or print.

`step`, `budget`, `turn`, `port` and `transcript` keep the meanings `spec/turn.md` and
`spec/port.md` give them. `step` in particular is the repo's word and is used as the
ontology defines it: one call within a larger call, as the record of the run shows it.

## 3. The world it takes

`subagent` calls no port. It never reads a file, never asks a human, never looks at a
clock, never calls a model. Everything it does to the world it does by handing a port
table to `turn.run` and letting the turn loop do it.

That port does not come from the parent's tool context, and this is deliberate.
`spec/turn.md` withholds `model` and `ask` from the context a tool body receives, so that
a body cannot spend the budget or approve itself. A subagent tool obeys that rather than
routing around it: **the ability to spawn is a capability the host grants at declaration
time, not one a body takes from its context.** The host supplies `cfg.world`, either a
port table or a function that builds one from the parent context, and a declaration whose
host never supplied it can name a child agent all day and get a stated refusal.

Three consequences worth stating:

- `subagent` never learns the shape of the model port. It carries `port.model` through as
  opaque data. Where `spec/port.md` and `spec/turn.md` disagree about whether that field
  is a function or a table with a `call`, this file has no opinion and needs none.
- A child's world can be narrower than its parent's: a `world` function is where a host
  writes "the child gets read but not write". `subagent` does no narrowing of its own,
  because a narrowing rule buried here is a rule nobody reading the declaration can see.
- What `subagent` adds to that port is exactly one key, `subagent`, carrying the frame.
  `spec/turn.md` guarantees unknown port keys reach tool bodies untouched, which is the
  whole transport. The host's table is not mutated; the key is set on a shallow copy.

## 4. The public API

The module returns one table. Only `subagent.tool` and `subagent.ledger` raise for bad
input; `subagent.run` raises only for a caller shape bug and never for anything a model,
a person or a world can do.

### 4.1 `subagent.tool(cfg) -> decl`

Builds the table you hand to the declaration surface:

```lua
agent.tool "delegate" (subagent.tool {
  about  = "Hand a self-contained job to a fresh agent and read back its answer",
  agents = { reviewer = reviewer_agent, searcher = searcher_agent },
  world  = function (ctx) return host_world_for(ctx) end,
  budget = 12,
})
```

`cfg` is a table. Every field:

| field | type | default | meaning |
| --- | --- | --- | --- |
| `about` | string, non-empty | required | rule 3: what the model is told this is |
| `agents` | table, name to agent table | one of these | the roster the model may name |
| `pick` | function `(name, ctx) -> agent` or `nil, why` | one of these | a roster computed at call time |
| `world` | table, or function `(ctx, req) -> port` or `nil, why` | required | the child's world |
| `budget` | number, whole, at least 1 | 12 | steps a child gets when it asks for none |
| `max_budget` | number, whole, at least `budget` | 24, or `budget` when that is larger | most a child may be given |
| `depth` | number, whole, at least 0 | 3 | how deep the tree may go, read only at the root |
| `children` | number, whole, at least 1 | 8 | total children in the tree, read only at the root |
| `steps` | number, whole, at least 1 | 64 | the tree's whole step pool, read only at the root |
| `include` | `"answer"`, `"readout"`, `"none"` | `"answer"` | what the parent's transcript gets |
| `max_chars` | number, at least 200 | 4000 | cap on the rendered text |
| `ask` | boolean | `true` | copied onto the declaration; spawning is worth a gate |
| `watch` | function `(result) -> ignored` | nil | called with the whole result after every child |
| `id` | string | the parent agent's name | the root of every child id in this tree |
| `ledger` | a ledger, or a function `(ctx) -> ledger` | nil | the tree to charge |

**Where the tree's ledger comes from.** A frame on the context always wins: a child
spawned from any declaration charges the pool its ancestor opened, which is what makes
`depth`, `children` and `steps` limits of the *tree* rather than of one declaration.
With no frame — a spawn from a top-level run — the declaration uses `cfg.ledger` when
it was given one, and otherwise opens one ledger of its own on its first spawn and
keeps it. That is deliberate and is the only state this module holds anywhere: without
it, nine sibling spawns from one parent reply would each open a fresh pool and the
fanout limit would never bite. It is per declaration, not per module, so two
declarations cannot see each other; a host that wants a fresh pool per run passes
`ledger = function (ctx) ... end`.

Exactly one of `agents` and `pick` must be present. An `agents` table with no entries is
a construction error, because it reads like a roster and would refuse every call.

The returned `decl` declares four arguments, and nothing else, so `spec.schema` shows the
model a signature it can satisfy:

- `agent` — a string naming one of the roster. Declared required, except when `agents`
  holds exactly one entry, in which case it is declared optional and defaults to that
  one.
- `prompt` — a string, required. The whole of what the child is told.
- `budget` — an optional number. Clamped to `max_budget` and to what the pool can afford.
- `label` — an optional string, carried onto the result and into the rendered first line
  so a host can tell two children of one parent apart.

The note goes to `ctx.note`, not `ctx.log`: `spec/turn.md` is explicit that a body's
`c.log` is the host's log port and `c.note` is the run's notes channel. When a host
built a context with a `log` port and no `note`, the line is written there instead.

The body does four things and no more: it calls `subagent.run(ctx, ctx.args)`, calls
`cfg.watch` with the result under `pcall`, appends one line to `ctx.note`, and returns
`subagent.render(result, cfg)` — a string. It returns a string on every path, including
every failure, because the parent's turn loop is going to put it in a transcript.

**Raises** for: `cfg` not a table; a missing or empty `about`; neither or both of
`agents` and `pick`; an `agents` value that is not a table; a `world` that is neither a
table nor a function; any numeric field of the wrong type, not whole, or out of range;
`max_budget` below `budget`; an `include` outside the three strings; a `watch` that is
not a function; an unknown key. An unknown key is refused rather than ignored: a
mistyped `childs = 2` that silently left the fanout at 8 is precisely the bug this
subsystem exists to prevent.

### 4.2 `subagent.run(ctx, req) -> result`

One child, start to finish. Returns a populated result table on every path. It never
returns nil, never returns a `false, err` pair, and never lets an error out of a child
reach the parent as a raise.

**`ctx`** — the parent tool body's context, as `spec/turn.md` defines it. `subagent`
reads exactly three things from it: `ctx.subagent` (the inherited frame, absent at the
root), `ctx.depth`, and `ctx.agent` — which `spec/turn.md` makes the agent's *name*, a
string, not the declaration table, so there is no `ctx.agent.name` to read. (A table
carrying a `name` is read too, for a host that built a context by hand.) Every read is
guarded, so a context whose metatable raises on an index cannot end a run. Everything
else on the context is ignored, including every port key: the child's world comes from `cfg.world`, never from
the parent's context. `ctx` may also be a plain table a host built by hand, which is how
`subagent.run` is callable outside a tool body.

**`req`** — a table:

| field | type | meaning |
| --- | --- | --- |
| `agent` | string or a resolved agent table | which child. A table is legal only from a host, never from a model, and `subagent.tool` never passes one through |
| `prompt` | string, non-empty after trimming | what the child is told |
| `budget` | number or nil | steps asked for |
| `label` | string or nil | a name for this child, carried through |
| `world` | table, function, or nil | overrides `cfg.world` for this one call |
| `ledger` | ledger or nil | the tree to charge. Absent means: the frame's ledger, or a fresh root ledger |
| `depth` | number or nil | overrides the inherited depth. Present only for hosts |
| `agents` | table or nil | the roster to resolve `agent` against |
| `pick` | function or nil | a roster computed at call time; used instead of `agents` |
| `max_budget` | number or nil | the ceiling to clamp `budget` to; 24 when absent |
| `tree` | table or nil | limits for the fresh root ledger, when no ledger and no frame |
| `id` | string or nil | the tree's id prefix; `ctx.agent` when absent |

`req` carries the roster and the world because `subagent.run` holds no configuration of
its own: `subagent.tool` merges what it was declared with what the model asked for and
hands the whole of it over in one table. That is also why `req.budget` always means
*steps asked for* — the declaration's default (`cfg.budget`) is applied by the tool
body before it calls, never here. When `req.budget` is absent entirely, 12 is used.

A key `req` does not list is a `blocked = "malformed"` result naming the key, on the
same reasoning as 4.1: a mistyped limit that silently keeps its default is the bug this
subsystem exists to prevent.

**Returns** a `result`:

```
{
  id      = string,          -- "reviewer/s3": stable, derived, never random
  agent   = string,          -- the name asked for, even when it did not resolve
  label   = string | nil,
  depth   = number,          -- the child's depth, root children are 1
  ok      = boolean,         -- true only when stop == "answered"
  stop    = "answered" | "budget" | "refused" | "error" | "blocked",
  blocked = string | nil,    -- set iff stop == "blocked"; see 4.7
  reason  = string,          -- one plain sentence, always present, never empty
  answer  = string | nil,    -- the child's final text; nil unless stop == "answered"
  prompt  = string | nil,    -- what the child was told; nil when it was not a string
  steps   = number,          -- steps the child actually spent; 0 when blocked
  budget  = number,          -- steps it was given; 0 when blocked
  clamped = boolean,         -- true when the budget asked for was cut down
  transcript = { message, ... } | nil,   -- the child's, verbatim, nil when blocked
  calls   = { record, ... } | nil,       -- the child's tool records
  notes   = { string, ... }, -- the child's notes, plus this module's own
  err     = { where = string, message = string } | nil,
  pool    = ledger:snapshot(),   -- steps_left, children_left, spawned, max_depth
}
```

`prompt` is on the result because 4.6 has to read out what was asked for on a child
that never ran, and a readout that reaches back into a request the caller may have
discarded is not a readout. `pool` is exactly `ledger:snapshot()` — one shape, one set
of names, so a snapshot and a result's pool cannot drift apart.

`stop` is the field to branch on and is one of exactly five strings, forever. Four of
them are `turn`'s own and mean what `spec/turn.md` says they mean; the child ran and this
is how it ended. The fifth, `"blocked"`, means the child never started, and `blocked`
says why. `reason` is for a human and may be reworded between versions; do not match on
it. `pool` is a snapshot taken after the permit closed, so a test can assert a refund.

**Raises** only when `ctx` is not a table, or `req` is not a table. Everything else — an
unknown agent name, an empty prompt, a world that refuses, a declaration with problems, a
depth limit, an exhausted pool, a child that errored, a child that was refused — is a
returned result. A raise from inside `turn.run` or from a child's own port is caught and
becomes `stop = "error"`, `err.where = "spawn"` or `"turn"`, with the raised value
stringified.

### 4.3 `subagent.ledger(cfg) -> ledger`

The accountant for one tree. `cfg` is `{ depth = 3, children = 8, steps = 64 }`, any
field may be absent, and the defaults are the ones in 4.1. Raises for a non-table, an
unknown key, or a field that is not a whole number in range.

Both call forms work throughout — `ledger:open(want)` and `ledger.open(want)` — because
this module holds a ledger in a plain field and a caller cannot see which it is.

A ledger is a table with three methods and four readable fields — `steps_left`,
`children_left`, `spawned`, `max_depth` — which a caller may read and must not write.

`ledger:open(want) -> permit` or `nil, block, why`

`want` is `{ depth = number, budget = number, id = string }`. In order:

1. `want.depth` greater than `max_depth` — `nil, "depth", why`.
2. `children_left` at zero — `nil, "children", why`.
3. `steps_left` at zero — `nil, "steps", why`.

Otherwise it reserves `math.min(want.budget, steps_left)` steps, decrements
`children_left` by one, increments `spawned`, and returns
`{ id = string, depth = number, budget = number, clamped = boolean, ledger = ledger,
open = boolean }`. `open` is how a second close is recognised.

**The reservation is the point.** Steps are taken from the pool *before* the child runs,
not after, so eight siblings cannot each be promised a budget the tree cannot pay. The
id is minted as `"s"` followed by the new value of `spawned` — deterministic, and unique
within the tree without a clock or a random source.

`ledger:close(permit, spent) -> refunded`

Returns `spent` steps as spent and the rest of the reservation to the pool; returns the
number refunded. A permit closed a second time refunds nothing and returns 0 — a double
close must not be able to conjure steps. A `spent` above the reservation refunds nothing
and is not an error, because a child that somehow overspent is a bug to record, not a
reason to raise inside a cleanup path. A `spent` below zero is read as zero.

`ledger:snapshot() -> table`

A fresh flat copy of the four fields. Never the ledger itself, so a caller cannot write
the pool by writing what it read.

### 4.4 `subagent.frame(ctx) -> frame` or `nil`

Reads the inherited frame off a context: `ctx.subagent`, when it is a table carrying a
`ledger` and a `depth`. Returns nil for anything else, including a context that is not a
table, so a host can ask without guarding. It never raises.

A frame is `{ ledger = ledger, depth = number, id = string, root = string }`. `id` is
the full id of the run the frame belongs to (`"reviewer/s3"`); `root` is the tree's id
prefix (`"reviewer"`), which is what makes ids flat and stable at every depth — the
fourth child of a tree is `root/s4` whether it was spawned at depth 1 or depth 3. It is what
`subagent.run` writes onto the shallow copy of the child's port under the key
`subagent`, and it is what makes recursion accounted rather than merely deep: a
grandchild's spawn charges the same pool its grandparent opened.

### 4.5 `subagent.render(result [, opts]) -> string`

The sentence the parent model reads. Deterministic, capped, and never empty.

`opts` may be nil or carry `include` and `max_chars`, with the meanings in 4.1 — which
is why `cfg` itself can be passed straight in. The parenthetical carries the permit's
own short id (`s3`), not the whole path, and a blocked child has no permit and so no
parenthetical at all. `max_chars` caps the body; the first line is never truncated,
because a truncated sentence about what happened is worse than none. The result is
always at least one line naming what happened, and the shape of that first line is
pinned so a test can hold it:

```
subagent reviewer (s3) answered in 3 of 12 steps.
subagent reviewer (s3) spent its budget of 12 steps without answering.
subagent reviewer (s3) was stopped by the person after 2 steps: <result.reason>
subagent reviewer (s3) failed after 2 steps: the model port said "timeout after 30s".
subagent reviewer did not run: the tree's spawn limit of 8 is already spent.
```

A `label` appears in the parentheses after the id. Under `include = "answer"` the child's
answer follows, after one blank line. Under `include = "readout"` the readout of 4.6
follows instead, which is how a parent that must audit its child gets the whole thing.
Under `include = "none"` there is only the first line.

Two rules that are easy to get wrong and are therefore stated:

- **An empty answer is said, not shown.** A child that stopped `answered` with `""`
  renders as `… answered with no text.` A blank body would read to the parent model as a
  successful empty result and it is not one.
- **Truncation is stated and keeps both ends.** Over `max_chars`, the text keeps the
  first `math.ceil(max_chars * 0.6)` characters and the last of the remainder, joined by
  a line naming exactly how many characters were dropped. A conclusion usually sits at
  the end of an answer, and a silently head-truncated answer loses it.

`render` raises for a `result` that is not a table. It tolerates a result missing any
field — a host that built one by hand gets a sentence, not a crash.

### 4.6 `subagent.readout(result [, opts]) -> lines`

A flat list of strings: one for the child's system message if it had one, one per
message, one per tool record, and a last line repeating the stop and the reason. Every
line is a string with no embedded newline beyond those in quoted text, and the list is
in the child's own order. `opts` may carry `max_chars` per line, default 200, applied
with the same stated truncation as 4.5.

This is the whole of "the child's transcript is inspectable rather than opaque". It reads
the result and nothing else — it does not reach back into a ledger, a port or an agent —
so a host can store a readout long after the tree has finished. A blocked result reads
out as two lines: what was asked for, and why it did not run.

### 4.7 `subagent.stops` and `subagent.blocks`

Frozen lists, in a fixed order, so a caller can build an exhaustive branch and a test can
assert neither set has grown.

`subagent.stops` is `{ "answered", "budget", "refused", "error", "blocked" }`.

`subagent.blocks` is the seven reasons a child never started:

| block | means |
| --- | --- |
| `malformed` | the request itself was unusable: no prompt, an empty prompt, a non-string agent name |
| `unknown` | the name is not in the roster, or `pick` refused it |
| `declaration` | the child agent is not runnable — `turn.check` had problems |
| `ungranted` | `world` was absent, or the world function returned nil |
| `depth` | the tree is already as deep as it may go |
| `children` | the tree has spawned all the children it may |
| `steps` | the tree's step pool is empty |

## 5. The failure modes

Every row is a returned result read by the parent model. Nothing here raises.

**The model names an agent that is not in the roster.** `blocked = "unknown"`. The reason
lists the names that do exist, sorted, so the next step can be right. The roster is
listed and not merely counted, because a model told only "no such agent" will guess
again, and guessing costs a step from the pool.

**The model asks for an empty prompt.** `blocked = "malformed"`. This is a deliberate
divergence from `spec/turn.md`, which makes an empty prompt legal for a top-level run and
lets the model decide what it means. It is not legal here. A child with nothing to do
still costs a model call, a reservation and a place in the fanout, and a parent that has
started looping will produce empty prompts by the dozen. The reason says so plainly.
Whitespace only is empty. A prompt that is not a string is also `malformed`.

**The model asks for a budget that is not a whole number, or is below 1.** Not a
failure either: it is clamped the same way, with `clamped = true`. Only a `budget` that
is not a number at all is `blocked = "malformed"` — a model that sends `2.5` meant
something, and a model that sends `"twelve"` did not.

**The model asks for a budget larger than the ceiling, or than the pool.** Not a failure.
The budget is clamped, `clamped = true`, the child runs, and the rendered first line names
the budget it actually got. A child told it may have 12 steps and given 3 without being
told would report failures the parent cannot interpret.

**The pool is empty.** `blocked = "steps"`, naming the pool's size and that it is spent.
The child never starts; no model call is made. This is the limit that actually stops a
fork bomb: depth alone bounds a chain and does nothing about a parent that asks for fifty
siblings.

**The fanout is spent.** `blocked = "children"`, naming the limit. Distinct from `steps`
because the two are fixed by different mistakes and a host reading the result deserves to
know which one it made.

**The tree is at its depth limit.** `blocked = "depth"`, naming the depth. `steps == 0`
and no reservation is taken, so a recursion that hammers the limit does not drain the
pool. `subagent` also passes `depth` and `max_depth` to `turn.run`, so `turn`'s own depth
guard is a second, independent belt; the two cannot disagree because both numbers come
from the ledger.

**The host granted no world.** `blocked = "ungranted"`, with the world function's `why`
quoted when it gave one. The parent model is told the capability is not available here,
which is the truth and is something it can work around; it is never told the child
answered nothing.

**The world function raises.** Caught. `blocked = "ungranted"`, the raised value
stringified into the reason, and a note. A host's wiring bug must not take down a run
that was otherwise going fine.

**The child declaration cannot run.** `turn.check` reports problems — no model, no tools,
a tool wanting a gate the child's port does not have. `blocked = "declaration"`, with the
problems joined into the reason, one sentence each. Checked before the permit is opened,
so a broken child costs the tree nothing.

**`turn.run` raises anyway.** Caught by `pcall`. `stop = "error"`,
`err.where = "turn"`, the raised value stringified. The permit is still closed and the
reservation still refunded — a cleanup that only runs on the happy path is how a pool
leaks until every later spawn is blocked for no visible reason.

**The child's model call fails, or times out.** `turn` returns `stop = "error"` with
`err.where = "model"`; `subagent` passes it through unchanged, refunds the unspent steps,
and renders the port's own words. `subagent` does not retry, does not sleep, and has no
clock: a wall-clock deadline belongs to the ports the world function handed the child,
which are the only things here that can block.

**The child spends its budget without answering.** `stop = "budget"`, `answer = nil`,
`ok = false`. Not an error — it is the harness working. The rendered text says how many
steps were spent, and under `include = "answer"` the child's last assistant text is shown
under a line saying it is unfinished, because half an answer honestly labelled is worth
more to the parent than a blank.

**The person refuses a call inside the child.** That is the child's business and its turn
loop handles it: the child sees a refusal as a tool result and usually still answers, so
the parent sees `stop = "answered"`. Only a `"stop"` decision ends the child, and then
`stop = "refused"` reaches the parent with the `why`. `subagent` itself never calls an
approval port, so there is no second place a spawn can be approved and no chance of the
two disagreeing.

**A child raises out of a tool body.** `turn` already catches that and turns it into a
tool result. Nothing reaches `subagent`. If a future `turn` ever lets one through, the
`pcall` in the row above catches it.

**`watch` raises.** Caught, appended to `result.notes` with the child's id, and otherwise
ignored. An observer cannot change, veto or end a run, and it cannot break the tool
result the parent is waiting for.

**A permit is closed twice.** The second close refunds nothing and returns 0. Stated
because the alternative — a refund per close — would let a buggy caller mint steps and
turn the one real limit in this file into a suggestion.

**A ledger is shared by two trees.** Legal, and it means what it says: they share a pool
and can starve each other. `subagent` does not prevent it, because a host that passed the
same ledger twice may have meant exactly that. `result.pool` makes it visible on every
single result.

## 6. What it must NOT do

- **It must not call a port.** No model call, no filesystem, no shell, no approval, no
  clock, no log sink. It hands a port to `turn.run` and reads the result. A test proves
  this by reading `src/subagent.lua` for `io`, `os.time`, `os.date`, `os.clock`,
  `os.getenv`, `os.execute`, `math.random`, `print` and a URL.
- **It must not ask.** Permission is the harness's, never a tool's (rule 4), and a spawn
  is an ordinary tool call that the harness's gate already governs. `subagent` never
  builds an approval request, never reads a policy, and never consults `src/approval.lua`.
  A spawn tool that should be gated sets `ask = true` and that is the whole mechanism.
- **It must not reach into `turn`'s internals.** `turn.run`, `turn.check` and
  `turn.stops`, nothing else. It does not read a transcript mid-run, does not install a
  hook on the child, does not re-implement a step, and does not validate a child's tool
  arguments — the child's own turn loop does all of that.
- **It must not name a vendor, a provider or a wire format.** It carries `port.model`
  through as opaque data and never looks inside it. Rule 1 reaches here too.
- **It must not persist.** No session file, no cache of results, no module-level registry
  of agents or ledgers. The child's transcript is returned and forgotten; whether it is
  stored is the session subsystem's decision, and `result.id` is stable and derived so
  that a session can file it without a clock or a counter of its own.
- **It must not mutate what it was given.** Not the parent context, not the parent's
  ports, not the child's agent declaration, not the caller's `req`, and not a host's port
  table — the frame goes onto a shallow copy. A test proves the host's port table has no
  `subagent` key after a run.
- **It must not let a child's failure become the parent's raise.** Every path out of
  `subagent.run` that a model or a world can reach is a result table.
- **It must not narrow a world, or widen one.** It adds one key to a port and removes
  none. A host that wants the child to have less writes that in its `world` function,
  where a reader of the declaration can see it.
- **It must not infer a budget from the parent's remaining steps.** It cannot see them:
  `spec/turn.md` gives a tool body no view of its own run's budget. The tree's pool is the
  only accounting here, and it counts only steps spent by children `subagent` itself
  started. Stated as a limit rather than papered over — a parent's own runaway is rule
  5's business and `turn`'s budget already ends it.
- **It must not run two children at once.** Lua here is single-threaded and there is no
  scheduler in this tree. A child runs to completion before its caller continues. Hosts
  overlap I/O through the wait table (`src/wait.lua`, spec/speech.md): a port yields
  `host`, `sleep` or `person`, and a pump resumes it. That is not two children at once.
  Any future fan-out of children is a change to this file first, then to an isolated
  child world (the host's `world` function), never to parallel tools that share one `fs`.

## 7. The tests that would prove it

All run against scripted ports built with `double.world` — no network, no disk, no
subprocess, no clock. The adversarial ones are marked, and they are the ones worth
writing first.

1. `a_child_answers_and_the_parent_reads_it` — a parent whose reply calls the spawn tool,
   a child scripted to answer, then a parent reply that answers. The parent's tool message
   contains the child's answer, `result.ok` is true, `stop == "answered"`.
2. `the_child_runs_its_own_tools` — the child's declaration has a tool the parent does not
   have; the child calls it, and the record appears on the child's `calls` and nowhere on
   the parent's.
3. `the_childs_transcript_comes_back_whole` — every message the child exchanged is on
   `result.transcript`, in order, and the parent's transcript contains none of them.
4. `a_readout_describes_a_child_line_by_line` — one line per message and per record, the
   last line names the stop, and the same result read out twice is identical. A child
   that called one tool reads out in six lines: four messages, one record, one stop.
   `a_blocked_child_reads_out_in_two_lines` covers the other half of 4.6.
5. `an_id_is_derived_and_stable` — two identical trees produce identical child ids
   (`"reviewer/s1"`, `"reviewer/s2"`), with no clock and no random source.
6. `a_budget_the_model_asks_for_is_honoured_up_to_the_ceiling` — asking for 5 gets 5;
   asking for 100 with `max_budget = 24` gets 24 and `clamped == true`.
7. `the_pool_is_refunded` — a child given 12 that answers in 3 leaves the pool 9 higher
   than a naive spend-it-all would; `result.pool.steps_left` proves it.
8. `a_label_reaches_the_rendered_line` — the first line carries the id and the label.
9. `include_none_shows_only_the_first_line` — and `include = "readout"` shows the readout.
10. `the_frame_travels_to_a_grandchild` — a child whose own declaration has a spawn tool
    spawns a grandchild; `subagent.frame` on the grandchild's context finds the same
    ledger table the root created.
11. `an_unknown_agent_lists_the_roster` — `blocked == "unknown"`, `steps == 0`, the reason
    names both roster entries in sorted order, and no model call was made against the
    child's port (`m.seen` is empty).
12. `an_empty_prompt_is_refused` **(adversarial, empty input)** — `""`, `"   "`, `"\n"`
    and a non-string prompt each give `blocked == "malformed"`, `steps == 0`, an untouched
    pool, and a rendered line that says why. The divergence from `turn`'s "an empty prompt
    is legal" is deliberate and this test pins it.
13. `a_missing_file_inside_a_child_is_the_childs_news` **(adversarial, missing file)** —
    the child's `fs` double has no such path, its read tool returns `not_found`, the child
    answers about it, and the parent gets `stop == "answered"` with that answer. A child's
    ordinary bad news must not surface as a parent-level failure.
14. `a_fork_bomb_stops_at_the_fanout` **(adversarial, recursion)** — an agent whose every
    reply spawns another copy of itself, with `children = 8`. Exactly 8 children run; the
    ninth is `blocked == "children"`; the process finishes; the stack survives.
15. `a_deep_chain_stops_at_the_depth` **(adversarial, recursion)** — the same agent with
    `depth = 3`. The run at depth 4 is `blocked == "depth"` with `steps == 0`, and no
    reservation was taken for it, so the pool at the end equals the pool a three-deep
    chain would leave.
16. `an_empty_pool_blocks_before_any_model_call` **(adversarial)** — `steps = 1` with two
    spawns: the first is clamped to one step and answers inside it, spending the pool;
    the second is `blocked == "steps"`, and the second child's scripted model double
    recorded nothing at all.
17. `siblings_cannot_each_promise_the_whole_pool` **(adversarial)** — `steps = 10`, three
    children each asking for 10. The first gets 10, and the second is blocked or clamped
    according to what the first actually spent — never three children each believing they
    hold 10. This is the reservation's test.
18. `a_child_that_errors_still_refunds` **(adversarial)** — the child's model double is
    scripted to a `timeout` error. `stop == "error"`, `err.where == "model"`, and the pool
    is back to what it was minus the one step spent.
19. `a_raising_turn_does_not_leak_the_pool` **(adversarial)** — a stub `turn.run` that
    raises. The result is `stop == "error"` with `where == "turn"`, and the pool is whole
    again. A cleanup that runs only on the happy path fails this.
20. `a_permit_closed_twice_refunds_once` **(adversarial)** — the second close returns 0,
    and the pool did not grow.
21. `a_broken_child_declaration_costs_nothing` **(adversarial)** — a child agent with no
    tools (`spec.problems` is non-empty). `blocked == "declaration"`, the reason names the
    problem, the pool is untouched, `turn.run` was never entered.
22. `a_tool_that_wants_a_gate_needs_one_in_the_childs_world` — a child tool with
    `ask = true` and a world with no approval channel is `blocked == "declaration"`,
    reported before anything runs, exactly as `turn.check` reports it.
23. `no_world_is_a_stated_refusal` **(adversarial)** — a world function returning
    `nil, "not in this sandbox"` gives `blocked == "ungranted"` with those words quoted.
    A world function that raises gives the same block and a note, and the raise does not
    escape.
24. `the_body_never_sees_the_model_port` **(adversarial)** — the parent's spawn body
    asserts `ctx.model == nil` and `ctx.ask == nil`, and the child still runs, proving the
    world came from the grant and not from the context. Rule 4, extended to spawning.
25. `subagent_never_asks` **(adversarial)** — a `double.ask` wired into the child's world;
    after a run with no gated tools, `a.asked` is empty. `subagent` must not have put the
    spawn itself to a human, because the parent's own gate already did.
26. `a_refusal_inside_a_child_is_the_childs_result` — the child's gate denies one call;
    the child reads the refusal and answers; the parent sees `stop == "answered"`. With a
    `"stop"` decision instead, the parent sees `stop == "refused"` and the `why`.
27. `a_timeout_is_reachable_without_a_clock` **(adversarial, timeout)** — a scripted
    `{ code = "timeout" }` on the child's model, and a scripted shell result with
    `timed_out = true` inside a child tool, both flow to the parent as text it can read,
    in milliseconds.
28. `a_child_that_runs_out_of_budget_says_so` — `stop == "budget"`, `answer == nil`,
    `ok == false`, and the rendered text names the number of steps and shows the child's
    last text under a line calling it unfinished.
29. `an_empty_answer_is_said_not_shown` **(adversarial)** — a child answering `""` renders
    as a sentence saying there was no text, and the rendered string is never just a first
    line plus blank space that a model would read as success.
30. `a_long_answer_keeps_both_ends` **(adversarial)** — an answer of 20000 characters with
    `max_chars = 4000` yields exactly 4000 characters of answer plus a stated marker; the
    first characters and the last characters of the original are both present, and the
    marker names the exact number dropped.
31. `watch_cannot_break_a_run` **(adversarial)** — a `watch` that raises, and one that
    returns false. Both runs complete unchanged, the parent still receives its string, and
    the raise appears in `notes`.
32. `nothing_given_is_mutated` **(adversarial)** — after a run, the host's port table has
    no `subagent` key, the `req` table is field-for-field what it was, the child's agent
    declaration is unchanged, and the parent's context has gained nothing.
33. `two_trees_do_not_leak` — two ledgers driven alternately through one loaded module;
    neither pool, id sequence nor readout crosses over. A third run with a shared ledger
    shows them starving each other, which is the documented behaviour, not a bug.
34. `a_run_is_reproducible` **(adversarial)** — the same declarations and the same scripts
    run twice produce equal results, including every id, every readout line and every
    rendered string. Catches any accidental clock, address or table-order dependency.
34a. `one_agent_in_the_roster_needs_no_naming` — a roster of one declares `agent`
    optional, and a model that omits it still gets that agent, driven through a real
    parent turn loop.

35. `bad_config_is_refused_at_declaration` **(adversarial)** — `subagent.tool` with an
    unknown key, with neither `agents` nor `pick`, with both, with an empty roster, with
    `max_budget` below `budget`, with `depth = -1`, and with `include = "everything"` each
    raise, and each message names the field.
36. `bad_arguments_to_run_are_a_result_not_a_raise` **(adversarial)** — every wrong `req`
    a model could produce comes back as a `blocked` result; only a non-table `ctx` and a
    non-table `req` raise. This is the line between a caller bug and the world, and it is
    the test that keeps it honest.
37. `stops_and_blocks_are_exactly_the_documented_sets` — `subagent.stops` has the five
    strings and `subagent.blocks` the seven, and a sweep of the tests above reaches every
    one of the twelve at least once.
38. `the_module_requires_only_turn` **(adversarial)** — read `src/subagent.lua` and fail
    on a `require` of anything but `turn`, and on any mention of a provider, a URL, `io`,
    `os` or `math.random`.

## 8. What changed while this was implemented

Written against the code that now exists in `src/subagent.lua`, which passes all forty
tests in `test/subagent_test.lua` under both `lua` and `luajit`. Each row is a place
where the specification above was wrong or silent and has been corrected in place; they
are collected here so a reader of an earlier draft can see what moved.

| where | was | is |
| --- | --- | --- |
| 4.2 | `ctx.agent.name` | `ctx.agent` is the agent's *name*, a string — `spec/turn.md` is explicit, and a body handed the declaration table could rewrite its own tools |
| 4.1 | the body "appends one line to `ctx.log`" | to `ctx.note`; `c.log` is the host's log port, and `c.note` is the notes channel |
| 4.2 | `req` listed seven fields | it also carries `agents`, `pick`, `max_budget`, `tree` and `id`, because `run` holds no configuration of its own and `tool` must hand the whole of it over |
| 4.2 | `req.budget` meant two things | it always means *steps asked for*; the declaration's default is applied by the tool body |
| 4.2 | `pool` had a `depth` field | `pool` is exactly `ledger:snapshot()`, whose fourth field is `max_depth`. One shape, one set of names |
| 4.2 | no `prompt` on the result | there is one, because 4.6 must read out what a blocked child was asked for |
| 4.4 | frame was `{ ledger, depth, id }` | it also carries `root`, the tree's id prefix, which is what keeps ids flat and stable at every depth |
| 4.1 | silent on where a root ledger comes from | stated: a frame always wins, then `cfg.ledger`, then one ledger per declaration opened on first spawn. Without the last of those, nine sibling spawns from one reply each open a fresh pool and the fanout limit never bites |
| 4.3 | `ledger:open` only | both call forms, since a caller cannot see which a field holds |
| 5 | silent on a fractional or zero budget | clamped like any other out-of-range budget; only a non-number is `malformed` |
| 4.5 | first line showed `(s3)` without saying so | stated: the parenthetical is the permit's short id, a blocked child has none, and `max_chars` caps the body while the first line is never truncated |
| 2 | "requires `turn` and nothing else" | unchanged, and the cost is now named: the four argument tables are written out in the shape `src/spec.lua` reads rather than built with `spec.types` |

Two things the implementation deliberately did **not** change:

- **`spec/port.md` and `spec/turn.md` still disagree** about whether the model port is
  `port.model(request)` or `port.model.call(request)`. This module never looks inside a
  model port, so it survives either resolution, exactly as §3 promised. `turn` reads
  both.
- **The empty prompt is still refused here** and still legal in `spec/turn.md` for a
  top-level run. Test 12 pins it, and §5 states it as a divergence rather than hiding it.

Two limits worth naming that no test can close.

**`stops` and `blocks` are frozen against growth, not against overwrite.** 4.7 calls
them frozen lists, and the guard on them is a `__newindex` that refuses a key the list
does not already have — which is what "assert neither set has grown" needs. Lua fires
`__newindex` only for an absent key, so `subagent.stops[1] = "elsewhere"` and
`table.remove(subagent.stops)` still land. The usual repair is a proxy table with
`__index` and `__len`, and it is not available here: LuaJIT 2.1 does not honour `__len`
on a table without its 5.2 compatibility build, so `#subagent.stops` would read 0 in
half the dialect this tree targets. The lists are therefore read-only by contract in one
direction and by convention in the other. Nothing a model, a person or a world can reach
writes to them; only the host's own code can, and only deliberately.

The other: a ledger is only as good as the spawns
that go through it. A host that calls `turn.run` directly for a child, rather than
`subagent.run`, charges nothing to any pool. This module bounds the tree it is given,
not every run in the process.
