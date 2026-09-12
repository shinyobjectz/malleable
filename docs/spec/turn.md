# turn — the turn loop

`src/turn.lua`. Contract, not implementation. Rules 1 and 5 of DESIGN.md live here.

Written before `spec/port.md` existed and reconciled against it afterwards, in the
places marked below. Where the two disagreed, `spec/port.md` won, because it is the
contract every other subsystem calls too. The one thing it does not carry is a way for
the person at the gate to stop the whole run, so this file adds `decision.stop`, and
that addition belongs in `spec/port.md`'s approval section as well.

## What it is for

Given an agent declaration, a prompt from the user and a port table, `turn` calls the
model, reads back either a final answer or a list of tool calls, runs each call through
the agent's tools, appends the results to the transcript and goes round again. It stops
when the model answers, when the step budget is spent, when the person at the port
refuses to continue, or when something breaks in a way the model cannot repair — and it
says which of those happened in a field the caller can branch on. It is the only part of
the harness that executes anything, and it reaches the world exclusively through the port
it was handed, so a whole run can be driven in a test with no network, no disk, no clock
and no subprocess.

## Vocabulary

Checked against the repo ontology before use. `step` is the repo's word for one call
within a larger call, as the trace records it, and that is exactly its meaning here: one
step is one model call plus the dispatch of whatever that call asked for. `call` is Lua's
word, adopted: to invoke a function. `turn`, `budget`, `port`, `transcript`, `stop`,
`tool` and `harness` are unclaimed and are used as defined below.

## The public API

The module returns a table with three functions and no state. Requiring it twice yields
the same table; running two agents through it at once is safe, because everything a run
needs lives in that run's own locals.

### `turn.run(agent, prompt, port [, opts]) -> result`

The whole subsystem. Runs the loop to completion and returns a result table. It never
returns nil, and it never returns a bare `false, err` pair — every outcome of a run,
including a total failure, is a populated result table.

**`agent`** — the table `spec.new()` built and the declaration file filled in. Read-only
to `turn`: fields `name`, `model`, `system`, `budget`, `tools`, `order`, `hooks`. `turn`
reads it through `spec.schema(agent)` and `spec.problems(agent)` and by indexing
`agent.tools[name]`; it writes nothing back, so the same declaration can drive many runs.

**`prompt`** — a string, the person's opening message. The empty string is legal and is
sent as an empty user message; the model gets to decide what an empty prompt means.
`nil` is not legal.

**`port`** — the world. Its full contract is `spec/port.md`, which is authoritative; the
part `turn` requires is:

- `port.model.call(request) -> reply | nil, err` — required. `request` is
  `{ model = string, system = string|nil, messages = <messages>, tools = <schema>,
  reasoning = string|nil }`, where `reasoning` is `agent.reasoning` when one is declared.
  On success it returns a `reply` table and no second value. On failure it returns `nil`
  plus an `err`. A reply is
  `{ text = string|nil, calls = { call, ... }, stop = string|nil }`, where each `call` is
  `{ id = string|nil, tool = string, args = table|nil }`, and `stop` is `"done"`,
  `"calls"`, `"cut"` or `"refused"`. `calls` non-empty is a request to act, and any
  `text` alongside it is kept in the transcript as the model's narration. A reply with
  no calls is a final answer when it carries text, or when `stop` says the model
  finished (`"done"`, `"cut"`, `"refused"`) even with empty text — `"cut"` and
  `"refused"` each leave a note. Neither, and no `stop`, is a malformed reply (see
  failure modes). A reply whose `calls` is present but is not a list is malformed too.
- `port.ask.request(q) -> decision` — required only if some declared tool sets
  `ask = true`; `turn` checks for it at the start of a run and refuses to start without
  it, rather than discovering the gap three steps in. `q` is
  `{ agent = string, tool = string, about = string, args = table, step = number,
  call = string }` — a superset of what `spec/port.md` requires, so a gate that reads
  only `tool`, `about` and `args` works unchanged. `decision` is
  `{ allow = boolean, why = string|nil, stop = boolean|nil }`. `allow = false` refuses
  this one call; `stop = true` ends the whole run. `why` is shown to the model on a
  refusal and recorded on a stop. Any other return value — a raise, a `nil`, a table
  with no `allow` — is treated as a refusal, with a note saying what the gate actually
  did.
- Every other key of the port — `port.fs`, `port.sh`, `port.clock`, `port.log`,
  whatever the host supplies — is passed through to tool bodies untouched and unread.
  `turn` neither knows nor cares what they are.

**Both callable shapes are read.** `spec/port.md` puts the model behind
`port.model.call` and the gate behind `port.ask.request`; an earlier draft of this file
wrote them as bare functions, and a host that hands `turn` a plain
`port.model(request)` or `port.ask(request)` still runs. The table form is the one to
write. Likewise a gate may answer with the strings `"allow"`, `"deny"` or `"stop"`
instead of a decision table; the table is the one to write.

**An `err` is a table.** `spec/port.md` defines it as
`{ port, call, code, message }`. `turn` reads `message` for its prose and `code` for
`result.err.code`, and copes with a port that hands back a bare string instead.

**`opts`** — optional table, `nil` means all defaults:

| field | type | default | meaning |
| --- | --- | --- | --- |
| `budget` | whole number ≥ 1 | `agent.budget` | steps this run may spend |
| `calls_per_step` | number ≥ 1 | 8 | most tool calls honoured from one reply |
| `malformed_limit` | number ≥ 1 | 3 | consecutive unusable replies before the run ends |
| `depth` | number ≥ 0 | 0 | nesting depth, set by a parent run |
| `max_depth` | number ≥ 0 | 3 | deepest nested run allowed |
| `id` | string | `agent.name` | a label copied into the result and into hook payloads |
| `history` | list of messages | none | the conversation so far, placed after the system message and before the prompt |

**`history`** is how a conversation continues across runs (spec/speech.md): the messages
of earlier runs, in the transcript's own shapes, `user`, `agent` (with its `calls`) and
`tool`. They go into the transcript as they are, copied, and they reach the model like
any other message. A list whose entries are not messages is refused like any other bad
option: an entry that is not a table, a role outside those three, or a `text` that is not
a string. The run does not check that a tool message answers a call. A history that
breaks that pairing is the caller's, and the model's far side will say so.

Unknown keys in `opts` are an error, not a shrug: a misspelt `budgets` that silently
does nothing is the worst kind of bug in a thing whose job is to always terminate.

**Returns** a `result`:

```
{
  id      = string,           -- opts.id, or the agent's name
  stop    = "answered" | "budget" | "refused" | "error",
  reason  = string,           -- one plain sentence, always present, never empty
  answer  = string | nil,     -- the model's final text; nil unless stop == "answered"
  steps   = number,           -- model calls actually made, 0 or more
  budget  = number,           -- the budget this run was given
  transcript = { message, ... },  -- every message, in order, including the system one
  calls   = { record, ... },  -- flat, in dispatch order, across all steps
  err     = { where = string, message = string } | nil,  -- set iff stop == "error"
  notes   = { string, ... },  -- non-fatal oddities: hook errors, out-of-contract ports
}
```

`stop` is the field to branch on and it is one of exactly four strings, forever. `reason`
is for a human and may be reworded between versions; do not match on it.

A `message` is one of:

- `{ role = "system", text = string }` — present iff `agent.system` is a string.
- `{ role = "user",   text = string }`
- `{ role = "agent", text = string, calls = { {id, tool, args}, ... } | nil }`
- `{ role = "tool", id = string, tool = string, ok = boolean, text = string,
   refused = boolean|nil }`

The roles and the field names are `spec/port.md`'s, not this file's earlier
`"assistant"` and `output`: the transcript is what goes to the model, and there is no
second vocabulary for it.

**The system message is in the transcript and not in `messages`.** `spec/port.md` says
a request carries `system` in its own field and that a message is one of `user`, `agent`
or `tool`. So `result.transcript` opens with the system message — it is the run's
record — and the `messages` list handed to `port.model.call` is the transcript from the
user message on, rebuilt and shallow-copied fresh at every step, so a port that keeps
what it was sent keeps what it was sent.

A `record` is `{ step = number, id = string, tool = string, args = table, ok = boolean,
output = string, refused = boolean|nil, asked = boolean }`. `args` is the table as
validated, not as the model sent it — declared names only, and the record's own copy of
them, so a tool body that edits `c.args` does not edit the run's account of what it was
called with. `tool` is `"(unnamed)"` when the call named no tool, including when it
named the empty string.

**Everything handed outward is a copy.** The `args` on a hook payload, the `args` on the
gate's query and the `args` on a tool context are three copies of the validated table,
made all the way down; the messages in `request.messages` are copies of the transcript's,
their `calls` lists included; and `request.tools` is built fresh at every step. Nothing a
hook, a gate, a body or a port does to what it was given can reach the transcript, the
records or the next step. This is what makes "hooks observe" and "`args` as validated"
mechanical rather than a promise — a `call` hook fires after validation and before the
gate, which is exactly where a swapped path would do the most damage.

**The `start` payload carries `given`** (amended 2026-09-12): the plain values on the
port, strings, numbers and booleans, copied, and never a port. It is what a feature's
given lines put on the world for the run, which is the one thing a hook that keeps state
for a run has to be handed at the start rather than remember from a scenario that ran
nothing (`docs/spec/modes.md`, the kit's corrections).

**A hook may say no. It may not say "yes, but different".** The invariant above is about
MUTATION: a hook cannot rewrite an approved call, because it never holds the table the
call will be made with. A VETO removes a call rather than rewriting one, and breaks
nothing — so a `call` hook that returns `{ allow = false, why = "…" }` (or `deny = true`,
or `stop = "…"`) refuses the call, and the refusal becomes a tool message the model
reads, exactly as the approval gate's denial does. The record carries `refused = true`
and `vetoed = true`; with `stop` the run itself ends, `result.stop` is `"refused"` and
the hook's sentence is the reason.
Anything else a hook returns is not applied, and is reported as a note naming what came
back. Before this, every hook return was discarded in silence, so
`return { stop = "never more than three" }` read as a declared limit and was not one:
the failure looked exactly like success. `output` is always a string
and is the same string as the tool message's `text`; a body that returns a non-string
has its value described for the transcript (never `tostring` of a table, whose address
would break reproducibility) and the record keeps the raw value under `value`.

**Wrong input raises.** `turn.run` calls `error()` — with a message naming the offending
argument — before any model call, when: `agent` is not a table, `spec.problems(agent)`
is non-empty, or `agent.budget` is not a whole number of at least 1 and `opts.budget`
does not override it — the declaration is held to the same budget rule as `opts`, because
a host that builds an agent table itself must not get a loop that ends on a fraction; `prompt` is not a string; `port` is not a table or has no callable model;
a tool declares `ask = true` and the port has no callable gate; `opts` is not a
table or nil, carries an unknown key, or carries a field of the wrong type or out of
range. `run` raises with every problem `check` found, joined, so one raise names every
fault rather than one at a time. These are caller bugs: deterministic, detectable with nothing running, and not
recoverable by retrying. Everything the world does — a model that fails, a body that
raises, a person who refuses — is a returned result, never a raise.

The one exception in the other direction: exceeding `max_depth` is the model's doing,
not the caller's, so it returns `stop = "error"` with `steps = 0` rather than raising.

### `turn.check(agent, port [, opts]) -> ok, problems`

The same validation `run` does, without running. Returns `true, {}` when a run would
start, or `false, { "…", … }` with one sentence per problem, sorted, so two hosts
reading the same broken wiring read the same list. Never raises for any input — pass it
a number and it tells you `agent` is not a table, pass it a table that raises when it is
indexed and it says it cannot read the declaration. Exists so a host can
diagnose a declaration at load time and so `run`'s raise path has a testable twin.

### `turn.stops -> { answered, budget, refused, error }`

A frozen list of the four stop reasons, in the order above, so a caller can build an
exhaustive branch and a test can assert the set has not grown. `#`, `ipairs` and
`table.concat` read it as they look.

Frozen by rebuilding: every read of `turn.stops` hands back a fresh list carrying a
metatable that raises on a new key. Growing the list is loud; overwriting one of the
four is silent, but it lands in a copy nobody else will ever see, so one caller can
never corrupt the constant that every other caller reads. A single stored table cannot
do both, because `__newindex` does not fire for a key that is already there and the
proxy that would fix that needs `__len`, which LuaJIT does not honour on a table — and
the dialect note says both interpreters must agree.

## How a step goes

1. Validate, build the transcript (`system` if declared, then `user`), fire `start`.
2. If `steps` equals the budget, stop with `budget`.
3. Call the model. This is one step; `steps` increases whether the call succeeds or
   not.
4. A reply with `calls` — validate each call, dispatch it, append one tool message per
   call, fire `call` and `result` around each, then go to 2. When every call ran, none
   was refused, and each named a tool declared with `ends = true`, stop with `answered`
   instead: the reply's own text, possibly empty, is the answer.
5. A reply with text and no calls — stop with `answered`.
6. A reply with neither — append a corrective user message saying what was expected, and
   go to 2, counting the malformed reply.
7. Whatever ends the loop, fire `stop` and return.

Dispatching one call means: look the tool up; check the arguments against the declared
parameters; if the tool sets `ask = true`, ask the gate and honour the decision; then
call the body inside `pcall` with a context. A tool that sets `ask = "always"` asks too,
and the gate's question carries `always = true`, which is how the approval gate knows
that neither trust nor an allow policy may answer it (`docs/spec/approval.md` §2.3,
amended 2026-09-12); on the declaration the tool has `ask = true` and `always = true`. Order matters — arguments are validated
before the person is asked, so nobody is asked to approve a call that was never going to
run.

A body may answer `false, why` (added 2026-09-12): it **declined** the call rather than
failing it. The sentence is the result the model reads, unprefixed, exactly as a string
answer would be; the call's record carries `declined = true`, so an eval counts it among
the refusals (`docs/spec/behaviour.md`, "The report") where a `nil, why` answer reads as
`the tool "x" failed: why`. The authoring `edit` and `propose` tools decline an edit that
scored as not applicable, so the shape a model learns by refusal is counted, not hidden.

The context handed to a body is
`{ args, step, call, agent, depth, note }` plus every key of the port except `model` and
`ask`, shallow-copied in, which is what makes `c.fs.read(c.args.path)` read the way
DESIGN.md writes it. The six reserved names win a collision, and a port key that
collides is reported in `result.notes` — once for the run, at its start, not once per
call. `model` and `ask` are withheld deliberately:
rule 4 says a tool body cannot approve itself, and here that is mechanical rather than
a promise. `c.note(s)` appends a string to `result.notes`, prefixed with nothing but the
string itself; it returns nothing and cannot fail.

The note function is `c.note`, not the `c.log` an earlier draft named: `spec/port.md`
gives the host a `log` port, and a tool body's `c.log` must be that port. `c.agent` is
the agent's *name*, a string — handing a body the declaration table would let a tool
reach the hooks and the other tools, and rewrite them.

Call ids: `turn` uses the model's `id` when it is a non-empty string, and otherwise mints
`step .. ":" .. index` — deterministic, so a recorded transcript replays identically. A
duplicate id inside one reply gets the minted form and a note; if the model has already
spent that exact name on an earlier call in the same reply, the minted form gains a
`.1`, `.2` and so on until it is free. Two calls in one reply never share an id, or the
model cannot tell the two results apart.

## Tools that end a run

A tool declared with `ends = true` is an action whose result nobody needs to read before
the run is over. Handing work to a background job is one example: the reply already said
what the person needs to hear, and a second model call would only say it again. When
every call in a reply is to such a tool, and every one ran without being refused, the
run stops `answered`. The reply's text is the answer, and it may be empty. A refused or
failed call does not end the run, so the model reads what went wrong and goes on. The
stops stay the four they were. `ends` is a boolean on the declaration (`src/spec.lua`
refuses anything else), and a tool that does not say it has the shape it always had.

## Requirements

A tool may state what a call must meet before it runs:

    requires = {
      { says = "the lamp can be reached from the moth", check = reachable },
      { says = "no row is empty", check = rows_full, check_only = true },
    }

Each `check` gets the same context the body would, and answers `true` to let the call on,
or anything else — `false`, `nil`, `false` and a reason — to stop it. They run in order,
after the arguments are checked and before the gate: a person is never asked to approve a
call that cannot be made. The first unmet one ends the call, which is not a refusal but a
failure the model reads:

    the call to "set_room" was not made: it requires that the lamp can be reached from the moth (a wall is between them).

The reason in brackets is the check's second value, when it gives one; a check that raises
is unmet, and its error is the reason. The model sees the requirement and repairs its call
on the next step, inside the budget, instead of starting over — Mellea's
instruct–validate–repair, with the harness doing the validating.

`says` is also part of what the model is told the tool is (`spec.schema`: the tool's
`about`, then " It requires: …"), so a model meets the requirement before it ever calls.
`check_only = true` keeps a requirement out of the description: some things are better
checked than said, because naming what you do not want invites it.

The record carries `unmet = says` on the call; the result event carries it too; the span
gets `malleable.requirement = "unmet"` (a closed value, never the sentence, rule 8). A
feature says it with `the first call to set_room fails because "…"`, and `observe` writes
that line for a call whose requirement was unmet.

## Edits at the gate

A tool that asks may let the person change what the model proposed:

    ask = { edit = "where" },            -- or { edit = { "where", "how_far" } }

The named arguments must be `one_of`, `boolean` or `number` — values a person can step
through on six buttons; a string cannot be edited at the gate, and the declaration raises.
The gate's request gains `edit` (the names) and `choices` (for each, its list, or its
kind), beside the model's `args`.

An approval may carry `args`: `{ allow = true, args = { where = "near" } }`. Only the
editable arguments are read from it; every other argument is the model's. The changed
arguments are checked like the model's were, and a value the tool does not take is a
refusal, never a call with arguments nobody approved. A call that went through with an
edit has `edited = { where = "near" }` on its record and its result event, its `args` are
what ran, and its output ends with the line the model reads so what it says next is true:

    moved near
    (the person chose near for where)

An approval whose values equal the model's is a plain approval, not an edit. The span's
`malleable.gate.answer` is `edited` for an edit. `Given the human approves move_lamp with
{"where": "near"}` scripts one, and `observe` writes it back.

The approval gate in `src/approval.lua`, which the CLI puts in front of its port, reads
allow and deny only: under the CLI a tool that allows edits is approved as the model
proposed it. The console's gate carries edits.

## Failure modes

Every row is a returned result. Nothing here raises.

**The model call fails.** The model port returns `nil, err`. The run stops with
`stop = "error"`, `err = { where = "model", message = err.message, code = err.code }`,
and a reason that quotes the port's sentence. `turn` does not retry and does not sleep: retry policy, backoff and
timeouts belong to the port, which is the only thing that knows what a timeout costs.
A port that returns `nil` and no message gets a message supplied for it, and a note.

**The model call raises.** A port that throws instead of returning is caught by `pcall`
and treated exactly as the row above, with `where = "model"` and the raised value
stringified. A broken port cannot take the harness down with it.

**The reply is malformed** — no text, no calls and no `stop`; or `calls` that is not a
list; or a reply that is not a table. `turn` appends a user message stating plainly what a reply
must contain and spends another step. Recoverable, and models do recover. After
`malformed_limit` consecutive malformed replies the run stops with `stop = "error"` and
`where = "model"`. One good reply resets the counter. This is a second, independent
guarantee of termination: the run ends on malformed replies even if the budget were
infinite.

**A call names no tool.** A single entry in `calls` that is not a table, or whose
`tool` is not a non-empty string, is not enough to condemn the whole reply: it is one
tool message with `ok = false` saying a call names a tool, under a minted id, and the
other calls in that reply run normally.

**The model names a tool that does not exist.** Not an error. One tool message with
`ok = false` whose output names the unknown tool and lists the tools that do exist, then
the loop continues. The model usually fixes it on the next step, and if it does not, the
budget ends the run.

**The arguments are wrong** — a missing required parameter, a parameter of the wrong
type, or a name that was never declared. Not an error, and the body is not called. One
tool message with `ok = false` naming each fault: what was expected, what arrived. Extra
undeclared arguments are refused rather than ignored, because a model that invents an
argument has misunderstood the tool and needs to be told. `args` that is `nil` is read as
an empty table, so a tool with no required parameters can be called bare.

**The person refuses one call.** The gate answers `{ allow = false }`. The body does not run. One
tool message with `ok = false`, `refused = true`, and an output that says the call was
refused and includes `why` when given. The run continues, the model reads it, and the run
can still end `answered`. Rule 4: a refusal is a result, not an error and not a silent
skip.

**The person stops the run.** The gate answers `{ stop = true }`. The remaining calls in
that reply are not dispatched; each is recorded with `ok = false, refused = true` and an
output saying the run was stopped first — including any call that was already past
`calls_per_step`, because "the run was stopped" is the truer sentence of the two. The run ends with `stop = "refused"`, a reason
carrying `why`, and a complete transcript.

**The gate fails** — raises, or answers with something that is neither a decision table
nor one of the three strings. Treated as
`"deny"` for that call, with a note recording what it actually did. An approval gate that
misbehaves must fail closed; a harness that guessed `"allow"` here would be a security
bug.

**A tool body raises.** Caught. One tool message with `ok = false` and the error value
stringified, prefixed so the model can tell a tool failure from a tool that merely
reported bad news. The run continues; a failing tool is information. The raise is also
appended to `result.notes` with the tool name, so a host can see it without parsing the
transcript.

**A tool body hangs, or loops forever.** `turn` cannot stop it and does not pretend to:
Lua has no preemption available inside the dialect this tree allows, and installing a
debug hook would break the promise that the core touches nothing but the port. This is a
stated limit, not a silent one. Time limits belong to the port, which does the blocking
work; a body that only computes is the declaration's problem.

**A tool body returns nothing and a reason.** `return nil, err` is the convention every
port in `spec/port.md` keeps, and `return c.fs.read(c.args.path)` — the body DESIGN.md
opens with — passes it straight through. So a first value of `nil` with a second value
present is a **failure**, not an empty success: one tool message with `ok = false`, an
output carrying the reason's `message` and its `code`, and the raw reason in
`record.value`. Reading that as `(no output)` would tell a model a missing file was an
empty one, which is how an agent confidently overwrites the wrong thing.

**A tool body returns nothing, or a non-string.** `nil` becomes the output string
`(no output)`. A boolean, number or table is stringified for the transcript and kept raw
in `record.value`. A body returning multiple values keeps the first and notes the rest.

**The reply asks for more calls than `calls_per_step`.** The first `calls_per_step` are
dispatched normally. Each one beyond is recorded and answered with `ok = false` and an
output saying the reply exceeded the per-step limit and to try again with fewer. The
model gets a truthful account of every call it asked for and none of them ran silently.

**The budget is spent.** The loop ends with `stop = "budget"`, a reason naming the number
of steps, and `answer = nil`. This is not an error — it is the harness working. A budget
of 1 means exactly one model call, and if that reply asks for tools, its calls are
dispatched and then the run ends with `budget`, so the caller still sees what was done.

**The run is nested too deep.** `opts.depth > opts.max_depth` ends the run immediately
with `stop = "error"`, `where = "depth"`, `steps = 0`, and a transcript holding only the
messages that were built. A tool body that runs a sub-agent must pass
`depth = c.depth + 1`; a body that forgets gets a run that is correct but unguarded, and
that is the declaration's bug.

**A hook raises.** Caught, appended to `result.notes` with the event name, and otherwise
ignored. Every payload carries `event` and `id`; `start` adds `prompt`, `budget` and
`depth`, `step` adds `step`, `call` adds `step`, `call`, `tool`, `args` and `ask`,
`result` adds `ok`, `output`, `refused` and `asked`, and `stop` adds `stop`, `reason`,
`steps` and `answer`. `call` fires only for a call that got as far as the gate or the
body — a call refused for an unknown tool, bad arguments or the per-step limit fires
`result` alone, because there was nothing to announce. A run that ends on `max_depth`
still fires `start` and `stop`, so a hook never sees a run begin without seeing it end. Hooks observe; their return values are discarded and they cannot alter, veto or
end a run. An event with no hooks registered fires nothing. An event name nobody fires is
never called — `spec.add_hook` accepts any string, and `turn` fires exactly `start`,
`step`, `call`, `result` and `stop`.

## What it must not do

- **Name no vendor.** No provider, no model family, no HTTP library, no wire format.
  `src/turn.lua` may not contain `require` of anything but `spec` (under either the
  `spec` or the `src.spec` path, since a host may put `src/` on `package.path` either
  way), and may not mention `io`, `os`, `socket`, `json` or a URL. Rule 1, and a test
  reads the file for it.
- **Touch no world but the port.** No `io.*`, no `os.time`, `os.date`, `os.clock`,
  `os.getenv` or `os.exit`, no `math.random`, no `print`. A run given the same port
  answering the same way produces byte-identical results twice.
- **Do no I/O of its own, including logging.** `notes` and hooks are how a run reports;
  writing a line somewhere is the host's business.
- **Not persist.** The session subsystem owns storage. `turn` returns a transcript and
  forgets it; it never reads or writes a session file, and it holds no module-level
  state between runs.
- **Not approve.** Permission is the port's answer to `port.ask`. `turn` never infers
  approval from a tool's name, an argument's shape or a previous allow. There is no
  "remember this choice" — if a host wants that, its `port.ask` remembers.
- **Not reach into `spec`'s internals.** `spec.schema`, `spec.problems` and the
  documented agent fields, nothing else. `turn` must not re-validate a declaration's
  types, mutate `agent`, or add fields to it.
- **Not construct tools.** A tool the declaration did not declare does not exist, and
  `turn` never synthesises one (no built-in `finish`, no implicit `think`). The model
  ends a turn by answering.
- **Not rewrite the model's words.** Assistant text goes into the transcript as it
  arrived. `turn` appends its own corrective messages as `user` messages, plainly
  distinguishable, and never edits an existing one.
- **Not retry, sleep or schedule.** One model call per step, in order.

## The tests that would prove it

The adversarial ones are marked. All run against a scripted port: a table whose `model`
pops replies from a list and whose `ask` returns whatever the test says. No network, no
disk, no subprocess, no clock.

1. `a_plain_answer_ends_the_turn` — one reply with text and no calls gives
   `stop == "answered"`, `steps == 1`, `answer` equal to the text, and a transcript of
   system, user, assistant.
2. `a_tool_call_runs_and_comes_back` — reply one calls a tool, reply two answers.
   `steps == 2`, one record with `ok == true`, and the tool message sits between the two
   assistant messages in order.
3. `the_body_sees_its_arguments_and_the_port` — the body asserts `c.args.path`,
   `c.step`, `c.call`, `c.agent`, `c.depth` and that `c.fs` is the port's `fs` table.
4. `the_body_cannot_reach_the_model_or_the_gate` (adversarial) — a body asserts
   `c.model == nil` and `c.ask == nil`. Rule 4 made mechanical: a tool cannot approve
   itself or spend the budget.
5. `a_runaway_loop_stops_and_says_so` — a port that always asks for the same tool. With
   `budget = 5`: `stop == "budget"`, `steps == 5`, `answer == nil`, and the reason names
   5. This is rule 5's test.
6. `a_budget_of_one_still_reports_its_calls` — a single reply full of tool calls ends
   `budget` with the records present, not an empty result.
7. `a_refused_call_is_a_result_the_model_reads` — `ask` returns `"deny"`; the body never
   runs (a flag it would set stays false), the tool message has `refused == true` and the
   `why`, and the next reply answers, so `stop == "answered"`. Rule 4's test.
8. `a_stop_ends_the_run_and_skips_the_rest` (adversarial) — a reply with three calls,
   `ask` says `"stop"` on the first. The second and third bodies never run, all three are
   recorded, and `stop == "refused"`.
9. `a_gate_that_lies_fails_closed` (adversarial) — `ask` returns `"maybe"`, then `nil`,
   then raises. Each is a deny, the body never runs, and each leaves a note.
10. `a_tool_that_asks_needs_a_gate` — a declaration with `ask = true` and a port with no
    `ask` raises from `run`, before any model call, and `turn.check` reports the same
    problem as a sentence.
11. `an_unknown_tool_is_told_so_not_thrown` — the model calls `wrte`; the result is a
    tool message with `ok == false` naming the tools that exist, and the run continues.
12. `bad_arguments_never_reach_the_body` (adversarial) — missing required, wrong type,
    and an invented extra argument. Each is one `ok == false` message naming the fault;
    the body's call counter stays at zero.
13. `an_empty_prompt_is_legal` — `run(a, "", port)` sends an empty user message and
    behaves normally. `nil` raises.
14. `a_declaration_with_no_tools_is_refused_before_anything_runs` —
    `spec.problems` is non-empty, `run` raises, the port's `model` was never called.
15. `a_model_failure_stops_with_the_ports_words` — `model` returns `nil, "timeout after
    30s"`; `stop == "error"`, `err.where == "model"`, the message quotes the port, and
    `steps == 1`.
16. `a_port_that_raises_is_caught` (adversarial) — `model` raises a table, not a string.
    Still `stop == "error"`, still a populated result, no raise escapes `run`.
17. `nonsense_replies_end_the_run_on_their_own` (adversarial) — a port that returns
    `{}` forever with `budget = 1000`. The run ends at `malformed_limit` with
    `stop == "error"`, proving termination without leaning on the budget.
18. `one_good_reply_forgives_the_malformed_ones` — malformed, malformed, answer, with
    `malformed_limit = 3`, ends `answered`.
19. `a_body_that_raises_is_information` — the body errors; the tool message says so, the
    run continues, the next reply answers, and the raise appears in `notes`.
20. `a_body_that_returns_nothing_still_reports` — `nil` becomes a stated no-output
    string; a table body's raw value survives in `record.value`, and its output string
    holds no table address.
20a. `a_body_that_fails_the_lua_way_is_information` — a body returning `nil` and a port
    error table is `ok == false`, and the output carries the reason and its code.
21. `a_flood_of_calls_is_capped_and_answered` (adversarial) — one reply with 50 calls and
    `calls_per_step = 8`: eight run, 42 are recorded refused-by-limit, every one gets a
    tool message, and the transcript's tool messages match the call count exactly.
22. `a_nested_run_is_its_own_run` — a body calls `turn.run` with `depth = c.depth + 1`
    and its own scripted port; the inner result is independent and the outer transcript
    is unaffected.
23. `recursion_is_bounded` (adversarial) — a body that runs the same agent again, always.
    With `max_depth = 3` the deepest run returns `stop == "error"`, `where == "depth"`,
    `steps == 0`, and the stack survives.
24. `a_hook_cannot_break_a_run` (adversarial) — hooks on all five events, one of which
    raises and one of which returns `false`. The run completes unchanged and the raise is
    a note.
25. `hooks_fire_in_order_with_payloads` — the five events arrive in the documented order
    with the documented fields, and an event with no hooks fires nothing.
26. `core_names_no_vendor` — read `src/turn.lua` as text and assert it names no provider,
    no `io`, no `os`, no `require` beyond `spec`, and no URL. Rule 1's test.
27. `a_run_is_reproducible` (adversarial) — the same agent and the same scripted replies,
    run twice, produce equal transcripts including every call id. Catches any accidental
    clock, random or table-order dependency.
28. `two_runs_do_not_leak` — two agents run alternately through one module instance;
    neither transcript, budget nor notes cross over.
29. `bad_opts_are_refused_loudly` — `{ budgets = 3 }`, `{ budget = 0 }`,
    `{ budget = "3" }` and `opts = 7` each raise with a message naming the field.
30. `stops_are_exactly_four` — `turn.stops` has the four documented strings, and a sweep
    of the failure-mode tests reaches every one of them at least once.

A second pass, written against this file rather than against the code, after the first
thirty were all passing:

31. `a_duplicate_call_id_is_minted_afresh` (adversarial) — a reply whose calls forge the
    minted form (`"1:2"` twice) and repeat a name of their own. No two records share an
    id, and the assistant message announces the ids the tool messages answer.
32. `a_call_that_names_no_tool_is_answered` — a string, an empty table, `tool = ""` and
    `tool = 7` in one reply alongside a sound call. Four `ok == false` messages under the
    name `"(unnamed)"`, and the sound call still runs.
33. `a_cut_or_refused_reply_is_still_an_answer` — `stop = "cut"` and `stop = "refused"`
    with empty text each end `answered` with `answer == ""` and one note; `"done"` needs
    no note.
34. `eight_calls_a_step_is_the_default` — twelve calls with no `calls_per_step` given:
    eight run.
35. `a_port_key_the_context_reserves_is_withheld` (adversarial) — a port carrying `step`
    and `note`. The reserved names win, and the clash is one note a key for the whole
    run, not one a call.
36. `a_hook_cannot_alter_a_run` (adversarial) — a `call` hook rewrites `payload.args.path`
    between validation and the gate, a gate rewrites `query.args.path`, and `result`,
    `stop` and `start` hooks rewrite their payloads. The gate is asked about the real
    path, the body runs with the real path, the record keeps it, and the budget is the
    one the run was given.
37. `a_port_cannot_rewrite_what_it_was_sent` (adversarial) — a port edits the messages,
    their `calls` lists and the tool schema it was handed. The transcript is unchanged
    and step three still sees the declared `about`.
38. `the_record_keeps_the_arguments_as_validated` — a body edits `c.args` and a nested
    table inside it; `record.args` is untouched, all the way down.
39. `a_declared_budget_is_whole_and_at_least_one` — `0`, `-1`, `2.5`, `"4"` and
    `math.huge` on `agent.budget` each raise, `turn.check` agrees, and `opts.budget`
    rescues the run.
40. `both_port_shapes_and_every_gate_answer_are_read` — the table port and the bare
    function port, crossed with `allow` / `deny` / `stop` in both the string and the
    table form: twelve runs, each with the documented body count and stop, and no note.
41. `the_stop_list_cannot_be_corrupted` (adversarial) — writing to slot 1, growing to
    slot 5 and `table.remove` all leave `turn.stops` reading as the same four.
