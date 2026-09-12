# approval — the approval gate

*Subsystem contract. Rule 4 of `DESIGN.md` lives here.*

## 1. What it is for

Permission belongs to the harness, never to the tool: before a tool body runs, the
harness decides whether it is allowed to, and a tool can never make that decision about
itself. `approval` is where that decision is made — it takes the call the model asked
for, weighs it against the declared policies, the workspace's trust level and whatever
the operator has already said this run, and asks the human through a port only when
nothing else has settled it. It answers with a decision and never with an exception, so
that a refusal reaches the model as an ordinary tool result it can read and work around,
rather than as a crash or a silent skip.

## 2. The public API

The module is `src/approval.lua`. It returns one table. It requires nothing, opens
nothing, and holds no module-level state — two gates in one process do not see each
other.

### 2.1 `approval.new(opts) -> gate`

Builds a gate. **This is the one entry point that raises.** A malformed policy is a bug
in a declaration file, and it must be caught when the file is loaded, not two minutes
into a run at the moment a tool is about to touch the disk.

`opts` is a table, or `nil` (equivalent to `{}`):

| field    | type                          | default  | meaning |
|----------|-------------------------------|----------|---------|
| `port`   | table or `nil`                | `nil`    | the approval port (§2.6). `nil` means there is no one to ask. |
| `policy` | array of policy entries (§2.2)| `{}`     | evaluated in order within each class. |
| `trust`  | string or `nil`               | `"ask"`  | one of `"trusted"`, `"ask"`, `"none"`. |

Raises (with `error(msg, 2)`, so the message points at the caller) when:

- `opts` is neither a table nor `nil` — `approval.new takes a table`
- `opts.trust` is present and is not one of the three strings — the message lists them
- `opts.policy` is present and is not a table
- `opts.policy` is not a dense array (a `nil` hole, or a non-integer key)
- any entry fails §2.2 — the message names the entry's index and the exact defect
- `opts.port` is present and is not a table, or is a table that carries no ask function
  in any of the three shapes below — `the approval port needs ask = function (request)`.
  A port wired up wrong is a wiring bug, and wiring bugs surface at construction.
- `opts` carries any key but `port`, `policy` and `trust`. A misspelt option is the same
  defect a misspelt policy key is (§2.2) and is worse in its consequence: the gate would
  build, hold no policies or no port, and quietly permit what the declaration meant to
  stop. `approval.new has an unknown option "polciy"; it takes port, policy and trust`.

The three shapes, all read, because the tree wires this slice both ways round (§2.6):
`{ ask = function (request) }`, `{ request = function (q) }` (spec/port.md's own `p.ask`
slice, handed over on its own), and a whole port table whose `ask` field is that slice
(`p.ask.request`). Nothing else counts as wired.

On success returns a gate: a table with the four methods below, carrying its own
policies, trust, port and (initially empty) run memory. Gates are independent.

### 2.2 A policy entry

A plain table. The whole of it:

```lua
{ allow = true,  tool = "read" }
{ deny  = true,  tool = "write", when = { path = "^%.git/" },
  reason = "the repository's own state is not the agent's to edit" }
{ deny  = true }                       -- every tool, every argument
{ allow = true, tool = { "read", "list" } }
{ allow = true, tool = "grep", when = { pattern = function (v) return #v < 200 end } }
```

- **`allow` / `deny`** — exactly one of the two must be present and `true`. Both, or
  neither, or `false`, is a construction error. There is no third class; a policy that
  wants to force an ask is simply absent, because absence *is* "ask".
- **`tool`** — a string, an array of strings, or absent. Absent means every tool. An
  empty array is a construction error (it reads like "no tools" but would silently mean
  the entry never fires).
- **`when`** — a table of argument name to matcher, or absent. Absent means every
  argument set. **All named arguments must match** for the entry to apply (AND, never
  OR). A matcher is either:
  - a **string**, read as a Lua pattern and matched with `string.find(tostring(v), p)`
    against a `string`, `number` or `boolean` argument. The pattern is not anchored for
    you — write `^` yourself. Against a `table` argument, or a missing argument, a
    string matcher **never matches** (it does not match the address `tostring` would
    print; addresses are not deterministic and a policy must be). A pattern Lua cannot
    compile — `"%"`, `"[a-"` — is a construction error, found by running it against the
    empty string when the gate is built rather than on the one call that reaches it.
  - a **function** `(value, args) -> truthy`, called with the one argument's value and
    the whole argument table. It must be pure and must treat both as read-only.
  Anything else is a construction error, and so is a `when` key that is not a string.
- **`reason`** — an optional string, quoted back to the model when a deny fires. Capped
  at 200 characters at construction; longer raises.
- Any other key is a construction error. A typo (`tools = `, `args = `) that silently
  widened a policy to every tool would be the worst possible failure in this file.

**A missing argument never matches**, whichever kind of matcher is written.
`{ deny = true, tool = "write", when = { path = "^/" } }` does not deny a `write` call
that carries no `path` at all, and a **function** matcher is not even called for an
absent argument — absence is decided before the matcher, so a matcher never has to
handle `nil` and cannot accidentally read one as a match. If you want the tool stopped
outright, write the entry with no `when`.

### 2.3 `gate:check(call) -> decision`

The whole of the subsystem's runtime behaviour. **It never raises and never returns
`nil`** — every path out of it is a decision table. It never calls the tool body.

`call` is a table:

| field      | type            | meaning |
|------------|-----------------|---------|
| `tool`     | string          | required, non-empty. |
| `args`     | table or `nil`  | the arguments the model supplied. `nil` reads as `{}`. |
| `ask`      | boolean or `nil`| the tool's declared `ask` flag. `nil` reads as `false`. |
| `always`   | boolean or `nil`| the tool declared `ask = "always"`: its question cannot be waived (amended 2026-09-12, below). `nil` reads as `false`. |
| `reason`   | string or `nil` | why the model says it wants this. Passed to the port verbatim, truncated to 400 characters. |
| `deadline` | number or `nil` | passed to the port untouched. The gate has no clock and enforces nothing (§3.9). |

**Resolution order.** Fixed, total, and the same on every run:

1. **Re-entry.** If this gate is already inside a port call, deny at once
   (`source = "reentry"`). §3.7.
2. **The call is malformed.** No table, no `tool`, `tool` not a non-empty string, or
   `args` present and not a table: deny (`source = "malformed"`). §3.8.
3. **Deny policies**, in declaration order. First match wins; the port is not called
   (`source = "policy"`). **Deny beats everything below it, including trust and the
   operator's own memory** — a deny policy is the one thing in the system nobody can
   talk their way past during a run.
4. **Run memory.** A `"never"` answer already given this run for this key denies; an
   `"always"` answer allows (`source = "memory"`). §2.5.
5. **Allow policies**, in declaration order. First match allows without asking
   (`source = "policy"`).
6. **Trust `"trusted"`.** Allow (`source = "trust"`). The operator has vouched for this
   workspace, so `ask = true` stops meaning anything — but step 3 already ran.
7. **The `ask` flag.** If `call.ask` is false *and* trust is not `"none"`, allow
   (`source = "flag"`). This is the ordinary path for the ordinary tool. The flag is
   read for truthiness, not for `== true`: `ask` is documented as a boolean, so anything
   else is a harness bug, and a harness bug must lean towards the port and never past
   it. An `ask` of `1` or `"false"` therefore asks.
8. **Ask the port** (§2.6). Trust `"none"` reaches this step for *every* tool, whatever
   its flag. No port here means a denial (§3.1).

**A question trust cannot waive** (amended 2026-09-12). A call with `always = true` skips
steps 5, 6 and 7 and goes from step 4 to step 8: an allow policy does not answer it, a
trusted workspace does not answer it, and it is asked whatever `ask` says. Steps 1 to 4
still run, so a deny policy still wins and a `never` the person gave this run still
holds. What *does* answer it is a person: the port, a `--yes` or `--no` on the command
line (those are the person's standing word, handed to the port), and an `always` the
person answered earlier this run, which is step 4. The decision is the port's, exactly
as at step 8, with the same sources. The mode tool of the modes kit
(`docs/spec/modes.md`) is the first tool that declares it: a state machine the person
moves is a sentence if `its trust is trusted` moves it.

**The decision.** A fresh table each call, safe for the caller to keep:

```lua
{
  allowed    = boolean,          -- never nil
  source     = string,           -- "policy" | "memory" | "trust" | "flag"
                                 -- | "port" | "malformed" | "reentry"
  reason     = string,           -- one sentence, model-readable, never empty
  asked      = boolean,          -- whether the port was consulted
  remembered = boolean,          -- whether this answer was stored for the run
  scope      = string or nil,    -- "tool" | "args", only when remembered
  policy     = number or nil,    -- the entry's index, only when source == "policy"
  args       = table or nil,     -- the person's own values for what they may change,
                                 -- as the port answered them (spec/turn.md, "Edits at
                                 -- the gate"); only when source == "port"
}
```

`reason` is capped at 400 characters, including any text that came from the port, the
model or a tool name. A hostile tool name must not become a hostile-sized refusal in the
model's context.

The exact `reason` strings, so tests can assert on them:

| situation | reason |
|---|---|
| flag allow | `the tool "<t>" does not ask` |
| policy allow | `allowed by policy <i>` |
| policy deny, no `reason` | `refused by policy <i>` |
| policy deny, with `reason` | `refused by policy <i>: <text>` |
| trust allow | `the workspace is trusted` |
| memory allow | `allowed for the rest of this run` |
| memory deny | `refused for the rest of this run` |
| port yes | `allowed by the operator` (or `allowed by the operator: <text>`) |
| port no | `refused by the operator` (or `refused by the operator: <text>`) |
| no port | `there is no one to ask for permission` |
| port raised | `the approval port failed: <message>` |
| port answered nonsense | `the approval port answered <v>, which is not yes, no, always or never` |
| re-entry | `an approval cannot ask for approval` |
| malformed call | `an approval request needs a tool name` |
| an answer that could not be kept (§3.4) | `<the port's own sentence> -- this call only, because <why>` |
| the last resort (below) | `the approval gate could not read this request: <message>` |

A tool name inside a reason is quoted and clipped to 80 characters; `<i>` is the entry's
index; the whole sentence is then clipped to 400.

**The last resort.** `check` runs its own resolution under `pcall`. Nothing it does
should raise, but an argument table that misbehaves when it is read — a metatable, a
proxy, a host object — must not become an exception in the middle of a permission
check. Such a raise is a denial with `source = "malformed"`, and the in-flight flag is
cleared on the way out. It is `"malformed"` rather than a source of its own because it
means exactly what that flag means: the harness handed the gate something it could not
read, and a session log should shout about it.

The gate does **not** build the tool result the model reads. It hands `allowed` and
`reason` to `turn`, which wraps a refusal in the same result shape a tool body would
have produced. That is the boundary rule 4 turns on: the model must not be able to tell
a refusal from an ordinary unwelcome answer by its *shape*, only by its text.

The `args` field is the one thing the gate carries from the port untouched: a decision
that dropped it made every `letting the person change` line a dead letter through
`cli.bind`, while the doubles' direct path honoured it (found by `showcase/03-gates.feature`,
2026-09-12).

### 2.4 `gate:remember(tool, allowed, scope, args) -> boolean, string`

Stores an answer for the rest of the run without going through the port — for a host
that already knows what the operator said, or for a test. `tool` is a non-empty string;
`allowed` is a boolean; `scope` is `"tool"` (default) or `"args"`, and `"args"` scope
additionally requires a fourth argument, the argument table to key on. Returns `true`,
or `false` plus a sentence when the arguments are wrong or the key cannot be built
(§3.5). It does not raise: it is reachable from a port implementation at run time.

`gate:forget(tool)` drops every memory for that tool and returns the number dropped;
`gate:forget()` drops all of them and returns the same count. It never raises either: a
`tool` that is not a string matches nothing and drops nothing. `gate:remembered()`
returns a fresh array of fresh `{ tool, allowed, scope }` tables, in the order the
memories were made, for a session log to render. Neither mutating the array nor writing
into one of its entries changes the gate.

Remembering the same key twice overwrites the answer in place and keeps its original
position in that order, so a log reads as a list of decisions, not of keystrokes.

Memory lives on the gate. It dies when the gate does. **It is never written anywhere and
never survives a run** — an "always" is always "always, until this run ends".

### 2.5 The memory key

An `"always"` or `"never"` answer is stored under one of:

- **`"tool"` scope** (the default) — the key is the tool name. This is the plain reading
  of "allow this tool for the rest of the run", and it is broad on purpose: an operator
  who says always to `write` has said yes to every later `write`. The refusal text and
  the request both say so, so nobody is surprised by it.
- **`"args"` scope** — the key is the tool name plus a canonical rendering of the
  arguments: keys sorted, each value type-tagged (`s:`, `n:`, `b:`), joined. **Only
  top-level `string`, `number` and `boolean` arguments participate.** If any argument is
  a table or a function, or any argument *name* is not a string, no `"args"` key can be
  built; the answer then applies once and is not remembered, and the decision says so
  with `remembered = false`. The gate never walks into a nested table, so a cyclic
  argument table cannot hang it.

Numbers are rendered with `%.17g` so that `1` and `1.0` do not silently become different
keys on one host and the same key on another. Every piece of the key — the tool name,
each argument name, each rendered value — is length-prefixed before it is joined, so no
two different argument sets can render to one key however hostile their contents.

**Both keys are consulted, and a refusal wins.** A call may match a `"tool"`-scope
memory and an `"args"`-scope one at the same time. If either says no, the answer is no;
only when neither says no and at least one says yes is it a memory allow. Nothing in the
memory may widen what another part of it closed, and the answer does not depend on which
was stored first.

### 2.6 The port slice

The gate takes its whole world through one function. `spec/port.md` landed after this
document was written and names that function `p.ask.request(q)`; that document wins on
the name, so the gate reads the slice in any of the shapes the tree wires it in:

```lua
{ ask     = function (request) -> answer }   -- this document's shape
{ request = function (q)       -> answer }   -- spec/port.md's p.ask, handed over alone
{ ask = { request = function (q) -> answer } }   -- a whole port table
```

`request`, built fresh by the gate:

```lua
{ tool = string, args = table, reason = string or nil,
  trust = string, deadline = number or nil, can_remember = boolean }
```

`args` is the caller's own table, passed through, not copied — a port must treat it as
read-only. `can_remember` is `false` when the request's arguments cannot be keyed for
`"args"` scope, so a UI can decline to offer the narrower "always" button.

`answer` is any of:

- `"yes"` or `true` — allow, this once
- `"no"`, `false`, or `nil` — refuse, this once
- `"always"` — allow, and remember for the run (`"tool"` scope)
- `"never"` — refuse, and remember for the run (`"tool"` scope)
- a table `{ answer = <one of the four strings>, reason = string or nil,
  scope = "tool" or "args" or nil }` — the same, with the operator's words quoted back
  to the model, and an optional narrower scope. A `scope` that is neither `"tool"` nor
  `"args"` is nonsense, not a default: honouring an unreadable scope is the widening
  direction, so the call is refused and the bad scope is named (§3.3).
- a table `{ allow = boolean, why = string or nil, remember = string or nil }` —
  **spec/port.md's decision**, read here so the real port needs no adapter. `why` is
  quoted back exactly as `reason` is. `remember` is a hint: `"once"` or absent remembers
  nothing, `"tool"` and `"session"` remember for the run at `"tool"` scope — a session
  *is* a run here, because the memory dies with the gate — and `"args"` narrows to the
  argument key. **An unreadable hint is ignored rather than honoured**, because ignoring
  it is the narrow direction. A table carrying both `answer` and `allow` is read by
  `answer`; a table with neither is nonsense.

Anything else is a refusal (§3.3). Answer strings are compared case-insensitively after
trimming surrounding whitespace, because a port that reads a terminal will hand over
`"Yes\n"` and that is not the operator's mistake.

### 2.7 What the declaration file needs

`src/spec.lua` is owned by another lane and is not rewritten here. To reach the surface
it needs two additions, whose contract is:

```lua
agent.trust "trusted"                          -- one of the three strings
agent.allow "read"                             -- a whole tool
agent.allow "write" { path = "^notes/" }       -- a tool, narrowed
agent.deny  "write" { path = "^%.git/" }
agent.deny  "shell"
```

`spec.set_trust(a, v)` validates against the three strings and raises otherwise.
`spec.add_policy(a, kind, name)` records the entry **immediately** and returns a
one-shot function that, called with a table, attaches it as the entry's `when` and
returns nothing. That is what makes both `agent.allow "read"` and
`agent.allow "write" { ... }` legal statements. The returned function raises if called
twice or with a non-table. Entries keep declaration order across allow and deny alike,
and `approval.new` reads them straight from `a.policy`.

One dialect hazard, worth a comment in the file: because the statement's value is a
function, a following line that begins with `(` is parsed as a call on it. That is Lua's
usual ambiguity and Lua's usual repair — start such a line with a semicolon.

## 3. The failure modes

This is the section the subsystem is judged on. **The whole of it fails closed: when the
gate does not know, the answer is no.** An agent that runs a tool because its permission
machinery broke is worse than an agent that stops.

**3.1 There is no port and something must be asked.** Deny, `source = "port"`,
`asked = false`, reason `there is no one to ask for permission`. The model reads a
refusal and can try another route. A headless run with `ask = true` tools and no port is
therefore a run in which those tools never fire — which is correct, and which the
session log makes obvious rather than mysterious.

**3.2 The port raises.** The gate calls it under `pcall`. The error is turned into a
denial, `source = "port"`, with the message `tostring`'d and truncated into the reason.
A port that throws does not unwind the turn and does not lose the run.

**3.3 The port answers something the gate does not understand** — a number, a table with
no `answer`, a misspelt `"allow"`, or nothing at all. Denial, with the offending value
rendered into the reason so the host's bug is visible in the transcript instead of
looking like the operator said no. `nil` is the one exception that is *not* called
nonsense: `nil` reads as a plain refusal, because a port that returns nothing on a
cancelled prompt is the common case and should read as "the human closed the box".

**3.4 The port answers `"always"` but the arguments cannot be keyed.** The call is
allowed once, `remembered = false`, and the reason says the answer applied to this call
only — `allowed by the operator -- this call only, because these arguments cannot be
keyed: only string, number and boolean arguments are remembered`, which is the sentence
`gate:remember` itself refused with (§3.5), quoted rather than reinvented. The operator is not silently given a narrower promise than they made, nor a wider
one than the gate can honour.

**3.5 `gate:remember` is called with a bad tool name, a bad scope, or unkeyable
arguments.** Returns `false` and a sentence. It does not raise, because a port
implementation may call it while an ask is in flight and an error there would unwind
through the `pcall` in §3.2 and be reported as a port failure — which would be a true
statement that hid the real cause.

**3.6 A policy matcher raises.** The matcher is called under `pcall`. **An erroring
matcher denies the call**, whichever class its entry belongs to, with
`source = "policy"`, the entry's index and the error text. Treating it as "did not
match" would let a crash in a deny entry open a door. A buggy matcher in an allow entry
therefore blocks a tool that might have been fine — the right way round: a broken
permission check is a stopped agent, never a permitted one.

**3.7 Re-entry.** A port implementation that asks the model, or otherwise loops back
into the turn, can re-enter `gate:check` while an ask is outstanding. The gate holds an
in-flight flag and denies immediately, `source = "reentry"`. The flag is cleared in
every exit path from the port call, including the error path, so one raising port does
not wedge the gate for the rest of the run.

**3.8 A malformed call.** `nil`, a string, a table with no `tool`, `args` that are not a
table. This is a harness bug rather than a model bug, but it is still a denial rather
than an error, so that a broken call can never become a run tool. `source = "malformed"`
is the flag a session log should shout about.

**3.9 A port that never returns.** The gate has **no clock and no timer**. If a port
blocks forever the run blocks forever, and the turn's step budget cannot preempt it,
because a step budget counts steps and this is one step that has not finished. The
timeout belongs to the port implementation: it is handed `deadline` and is expected to
answer `"no"` (or raise) when it passes. This is a stated limit, not an oversight — a
timer inside the gate would mean a clock inside the core, and rule 1 says the core knows
no clock.

**3.10 Huge or hostile text.** A tool name, a model-supplied reason or a port's reason
can be arbitrarily long, and the model chooses the first two. Every string the gate
copies into a decision is truncated (400 characters for a reason, 200 for a policy's own
text, 80 for a tool name inside a message), with an ellipsis, so no refusal can be used
to flood the context window or to smuggle a wall of text past the model's attention.

**3.11 Contradictory policies.** An allow and a deny that both match is not an error and
is not a warning: the deny wins, by §2.3 step 3. Ordering between the two classes is
never consulted, so re-ordering a declaration file cannot quietly change what is
permitted.

**3.12 Trust `"trusted"` with a deny policy** is exactly the case the ordering exists
for: trust is checked at step 6 and the deny at step 3, so a trusted workspace still
cannot touch a denied tool. The reverse — trust `"none"` — forces step 8 for every call,
so on an untrusted workspace even a tool that never declared `ask` is put to the human.

**3.13 An `"always"` answer under trust `"none"`.** It is honoured, and later calls to
that tool stop being asked about. The alternative — asking again every time, on the
grounds that the workspace is not trusted — trains an operator to hammer yes without
reading, which is a worse security posture than one deliberate decision. Stated here
because it is the one place where a reader might expect the stricter behaviour.

**3.14 A matcher that mutates the arguments** it is handed. The gate passes `call.args`
by reference to both the matchers and the port; it does not copy and it does not defend.
A matcher that writes to `args` changes what the tool body later receives. This is the
author's bug, and it is documented rather than guarded because a defensive deep copy on
every call would cost more than it saves and would hide the bug rather than remove it.

## 4. What it must not do

- **No I/O of any kind.** No `io`, no `os.execute`, no `os.getenv`, no `os.time`, no
  `os.clock`, no `require` of anything. The whole world arrives as `opts` and `call`.
  Rule 1 is written for `turn.lua`, but this file sits in the same core and obeys it.
- **Never run a tool body**, never call anything named on the tool, never `pcall` a
  `run` field. It weighs a call; something else performs it.
- **Never read the agent table.** It does not `require "spec"` and never sees `a.tools`.
  Everything a decision needs about the tool — its name, its `ask` flag — is copied into
  the call by `turn`. This is what makes the gate testable without an agent.
- **Never build the model-facing tool result.** That shape belongs to `turn` and `tool`.
  The gate produces `allowed` and one sentence.
- **Never fire a hook.** `agent.on "approval"` is dispatched by `turn` with the decision
  the gate returned. The gate does not know hooks exist.
- **Never talk to the model.** Not to summarise a request, not to judge a path, not to
  decide anything. The port asks a human; if a host wires a model behind that port, that
  is the host's decision and §3.7 keeps it from recursing.
- **Never interpret a path.** It does not join, normalise, resolve, or canonicalise. A
  pattern policy matches the literal argument text, so `^src/` does not stop `./src/x`
  or `notes/../src/x`. **A pattern policy is a convenience, not a sandbox.** Path safety
  belongs to the filesystem port, which is the only thing in the system that knows what
  a path is. This is the most important sentence in the section, because the opposite
  belief is the one that gets a workspace deleted.
- **Never persist.** No file, no cache, no module-level table, nothing shared between
  gates or between runs. Two agents in one process each have their own memory, and both
  forget everything when the process moves on.
- **Never widen.** No path in the code turns a `no` into a `yes`. The only sources of a
  `yes` are the six listed in §2.3, and every unhandled case falls to `no`.

## 5. The tests that would prove it

Adversarial tests are marked **(A)**. They are the ones worth writing first: happy-path
approval is easy and is not what the subsystem is for.

1. `a_tool_that_does_not_ask_just_runs` — `ask = false`, no policies, no port: allowed,
   `source = "flag"`, `asked = false`, and the port (a spy) was never touched.
2. `a_tool_that_asks_reaches_the_port` — `ask = true` with a port that records its
   request: allowed, `asked = true`, and the request carried the tool name, the
   arguments and the trust level.
3. `a_refused_call_is_a_result_the_model_reads` — the port answers `"no"`: `check`
   returns normally, `allowed = false`, a non-empty reason, and no error is raised
   anywhere in the call. This is rule 4's named test; `turn` owns the other half, that
   the refusal reaches the model in the ordinary result shape.
4. `an_empty_gate_allows_nothing_it_was_not_asked_about` — `approval.new()` with no
   arguments at all, then a call with `ask = true`: denied for want of a port, not
   allowed by default. **(A)** — the empty-input case, and the one where a wrong answer
   is silent.
5. `a_deny_policy_stops_a_tool_that_never_asked` — `ask = false` plus a matching deny:
   denied. Proves policies are consulted for every call, not only asking ones.
6. `deny_beats_allow_in_either_order` — the same pair of entries declared both ways
   round; denied both times, and each decision reports the index of *its own* deny
   entry (2 when the allow is written first, 1 when the deny is). Ordering between the
   two classes is never consulted, so the reported number moves with the file and the
   answer does not.
7. `deny_beats_trust` — `trust = "trusted"` plus a matching deny: denied. **(A)**
8. `deny_beats_an_always_the_operator_already_gave` — remember an allow, then add a
   matching deny: denied. **(A)** — the "talk your way past it" case.
9. `an_untrusted_workspace_asks_about_everything` — `trust = "none"`, `ask = false`,
   no policies: the port is consulted.
10. `an_argument_pattern_narrows_a_policy` — allow `write` when `path` matches
    `^notes/`; a call under `notes/` is allowed by policy, one under `src/` is not and
    falls through to the port.
11. `a_missing_argument_never_matches` — a `when` on `path` against a call that carries
    no `path`: the entry does not fire, for allow and for deny alike, and a function
    matcher is never called at all. **(A)**
12. `a_table_argument_never_matches_a_string_matcher` — the matcher must not match a
    `tostring` address; two runs with two different tables give the same decision.
    **(A)** — the determinism case.
13. `always_is_remembered_for_the_run_and_only_the_run` — one `"always"`, then a second
    call that does not reach the port; a fresh gate with the same policies asks again.
14. `never_is_remembered_the_same_way` — a session-wide refusal, symmetric to 13.
15. `always_with_a_table_argument_applies_once` — `{ answer = "always", scope = "args" }`
    where an argument is a table: allowed, `remembered = false`, and the next identical
    call reaches the port again. **(A)** — §3.4.
16. `cyclic_arguments_do_not_hang_the_gate` — `args.self = args`, an `"args"`-scoped
    always: returns, does not remember, does not recurse. **(A)**
17. `a_port_that_raises_denies` — the port `error()`s: denied, `source = "port"`, the
    message appears in the reason, and no error escapes `check`. **(A)**
18. `a_port_that_answers_nonsense_denies` — `42`, `"allow"`, `{}`: all denied, each
    naming what came back. **(A)**
19. `a_port_that_answers_nothing_reads_as_no` — `nil` returned: denied, and the reason
    is the plain refusal, not the nonsense one. **(A)** — §3.3's exception.
20. `a_port_answer_survives_whitespace_and_case` — `"  YES\n"` allows.
21. `an_approval_cannot_ask_for_approval` — a port whose `ask` calls `gate:check` again:
    the inner call is denied with `source = "reentry"`, the outer one completes, and a
    third, later call still reaches the port. **(A)** — recursion, plus the proof that
    the in-flight flag is cleared.
22. `a_raising_port_clears_the_in_flight_flag` — after test 17's port raises, the next
    call reaches a working port. **(A)**
23. `a_matcher_that_raises_denies` — a `when` function that `error()`s, in an *allow*
    entry: denied, not allowed, and the entry's index is in the reason. **(A)** — §3.6,
    the fail-closed direction that costs something.
24. `a_malformed_call_is_a_denial_not_an_error` — `check(nil)`, `check("read")`,
    `check{}`, `check{ tool = "" }`, `check{ tool = "read", args = 7 }`: five denials,
    `source = "malformed"`, no raise. **(A)**
25. `a_hostile_tool_name_does_not_flood_the_reason` — a 100 kB tool name and a 100 kB
    port reason: the decision's reason is at most 400 characters. **(A)**
26. `a_malformed_policy_is_caught_at_construction` — a table with both `allow` and
    `deny`, one with neither, one with `tools = "read"`, one with `when = { path = 7 }`,
    an array with a hole: each raises from `approval.new`, and each message names the
    index. **(A)** — the one place raising is correct, and the typo case that would
    otherwise widen a policy silently.
27. `a_port_wired_wrong_is_caught_at_construction` — `port = { ask = "yes" }` raises.
28. `the_gate_holds_no_shared_state` — two gates built from the same policy table; an
    `"always"` on one is invisible to the other, and neither mutates the table it was
    given.
29. `forget_undoes_a_remembered_answer` — remember, forget, and the next call reaches
    the port again; `gate:remembered()` returns a copy whose mutation changes nothing.
30. `the_gate_never_runs_a_body` — a tool-shaped table whose `run` sets a flag is passed
    inside the call: whatever the decision, the flag is never set. **(A)** — rule 4
    stated as an executable claim.
31. `no_vendor_and_no_world_in_the_source` — reads `src/approval.lua` as text and fails
    on `io.`, `os.`, `require`, `load`, or a provider's name, the same way rule 1's test
    reads `turn.lua`. **(A)** — the test that keeps §4 true as the file changes.

Nine more the implementation added, because writing it found the holes:

32. `remember_refuses_bad_arguments_without_raising` — every wrong call to
    `gate:remember` returns `false` and a sentence, and an `"args"` scope that *can* be
    keyed answers that exact call and no other. **(A)** — §3.5, which nothing else
    reaches directly.
33. `the_ask_flag_is_the_only_thing_trust_ask_reads` — `ask` nil, false and true under
    the default trust, and the port consulted exactly once.
34. `a_trusted_workspace_still_reads_its_policies` — an allow policy is reported as
    `"policy"`, not swallowed by `"trust"`, so the session log says which one settled it.
35. `an_always_under_no_trust_is_honoured` — §3.13 stated as a test: the second call is
    `source = "memory"` and the port saw one request.
36. `the_port_document_decision_shape_is_read` — `{ allow = true, why = ... }` and the
    `remember` hints `"once"` and `"session"`, so the real port needs no adapter. **(A)**
37. `a_function_matcher_sees_the_value_and_the_arguments` — both parameters arrive, and
    a call the matcher rejects falls through to the port.
38. `a_policy_with_no_tool_covers_every_tool` — `{ deny = true }` alone, against three
    different tool names.
39. `a_tool_list_narrows_a_policy` — `tool = { "read", "list" }` allows both and not a
    third.
40. `numbers_and_booleans_key_the_same_way_every_time` — `1` and `1.0` are one memory
    key, `2` is another. **(A)** — the `%.17g` claim in §2.5, which is otherwise a
    sentence nothing checks.

Twelve more from the verify pass, each found by mutating the implementation and
watching the forty above stay green. A claim the specification makes and no test reads
is a claim the next edit can delete for free.

41. `a_non_boolean_ask_flag_still_asks` — `ask` of `1`, `"true"`, `"false"`, `0` and a
    table all reach the port; `false` and an absent flag still allow. **(A)** — the
    fail-open the pass found: reading only `== true` as "asks" turned a host's stray
    value into a silent allow.
42. `the_memory_is_read_before_the_allow_policies` — a `"never"` the operator gave is
    not reopened by an allow entry further down the file. **(A)** — §2.3's step 4 above
    step 5, which nothing else ordered.
43. `a_refusal_in_the_memory_wins_over_an_allow_in_it` — a tool-scope allow and an
    args-scope refusal, stored both ways round: refused both times, and the wide allow
    still covers every other argument set. **(A)** — §2.5's "a refusal wins".
44. `two_argument_sets_never_share_a_memory_key` — an argument *name* carrying the key's
    own separators does not inherit another set's answer. **(A)** — the length-prefix
    claim in §2.5.
45. `a_whole_port_table_is_read_as_well_as_its_slice` — `{ ask = { request = fn } }`
    answers and is handed the request; `{ ask = {} }` raises at construction. §2.6's
    third shape.
46. `arguments_that_raise_when_read_are_a_denial_not_a_crash` — an `args` table whose
    `__index` errors: `source = "malformed"`, no raise escapes, and the next call still
    reaches the port. **(A)** — §2.3's last resort.
47. `the_request_carries_the_deadline_and_a_bounded_reason` — `deadline` passed through
    untouched, a non-number dropped, and the model's own reason clipped to 400 before
    the port ever sees it. §2.3 and §2.6.
48. `remembering_the_same_key_twice_keeps_its_place` — a changed answer overwrites in
    place; `remembered()` is a list of decisions, not of keystrokes, and `forget` drops
    one memory rather than two. §2.4.
49. `an_unreadable_scope_is_a_refusal_not_a_default` — `{ answer = "always",
    scope = "everything" }` is refused and the scope is named; nothing is stored.
    **(A)** — §2.6, the widening direction.
50. `forget_with_a_bad_tool_name_drops_nothing` — `forget(7)`, `forget(true)` and a name
    nothing was stored under each return 0 without raising. §2.4.
51. `a_nonsense_answer_names_no_address` — two different tables, and a function, are all
    rendered by type; two runs give one reason and no `0x` reaches the transcript.
    **(A)** — determinism, and the host's memory layout staying out of the context.
52. `an_unknown_option_is_caught_at_construction` — `{ policies = ... }` raises and names
    the typo. **(A)** — §2.1's last clause.
53. `always_is_asked_under_trust_and_under_an_allow_policy` — `always = true` with
    `trust = "trusted"`, and again with a matching allow policy: the port is asked and
    its answer is the decision; with `always` absent the same calls are allowed without
    a question. **(A)** — the 2026-09-12 amendment to §2.3.
54. `always_still_loses_to_a_deny_and_to_a_never` — `always = true` with a matching deny
    policy is denied without asking; after a `never` for its key it is denied from
    memory. **(A)** — steps 3 and 4 run before the question.
