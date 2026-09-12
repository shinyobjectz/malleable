# port — capability ports and their test doubles

## What it is for

The harness needs six things from the world: a model it can call, a filesystem, a
shell, a clock, somewhere to ask a human for permission, and somewhere to write a log
line. `port` defines each of those as a plain Lua table of functions and nothing else,
so `src/turn.lua` can obey rule 1 — the core knows no vendor — by calling a table it was
handed instead of naming a provider. `double` supplies a complete in-memory
implementation of all six, so the whole harness runs in a test with no network, no disk
and no subprocess.

## Where it lives

    src/port.lua     the contract: error values, the validator, the shapes
    src/double.lua   the fakes: an in-memory world, deterministic and inspectable

Neither is part of the `agent` declaration prefix. A declaration file never mentions
`port` or `double`; the host wires the ports and passes them to `turn.run`. Inside a
tool body the ports arrive on the context — `c.fs` **is** the `fs` port table, not a
wrapper around it — so everything below describes exactly what a tool body sees.

## The one convention

Every port function is total in the sense that matters: it does not raise for anything
the world can do to it.

* **A wrong shape raises.** Passing a number where a path string belongs is a bug in the
  caller, so the function calls `error()` with a sentence. Raising is for programmer
  mistakes only.
* **A wrong world returns.** Missing file, denied permission, dead network, non-zero
  exit, blown deadline — all of these return `nil, err`, where `err` is a table. The
  caller is expected to read it, not to be surprised by it.

A function that can only succeed (`exists`, `log.write`) says so below and returns no
error at all.

### The error table

    { port = "fs", call = "read", code = "not_found", message = "no such file: notes.md" }

`port` and `call` say who failed. `message` is one sentence, safe to show a model, and
never contains a stack trace or a host absolute path unless the caller supplied one.
`code` is drawn from a closed set, so a caller can branch on it:

| code | means |
| --- | --- |
| `not_found` | the named thing does not exist |
| `denied` | the world refused: permission, a sandbox rule, a path leaving the workspace |
| `exists` | it is already there and the call refused to clobber it |
| `too_big` | over a limit the port enforces |
| `timeout` | a deadline passed before the call finished |
| `unavailable` | the capability is not wired up here, or the far side is down |
| `malformed` | the far side answered with something this port cannot read |
| `exhausted` | a budget or a script ran out |
| `cancelled` | the caller's own cancel signal fired |
| `unscripted` | **doubles only**: a double was asked for something no test scripted |

Anything else is a bug in a port implementation. The set is closed at construction
rather than at the call: `port.error` refuses an unknown code, so a typo cannot become
a world failure a caller then branches on. `port.check` cannot police this, because it
calls nothing.

Helpers:

* `port.error(which, call, code, message) -> err` builds one. Raises if `code` is not in
  the set above — a typo'd code must not reach a caller as a silent unknown. A missing
  `message` becomes the code itself, so `err.message` always reads as something and
  `is_error` holds.
* `port.is_error(v) -> boolean` is true for a table carrying all four fields.
* `port.codes` is the set itself, `{ not_found = true, ... }`, for a test to iterate.
* `port.path_ok(path) -> boolean` is the textual path rule below, shared so a double and
  a real disk cannot drift apart. False for the empty string, an absolute path, a drive
  letter, a backslash anywhere, a doubled or trailing slash, and any `..` segment. The
  empty string is not a path; `fs.list` takes it as the workspace root and says so
  itself rather than asking here.
* `port.shape.*` is the raising half of the convention, so every port states a caller's
  mistake in the same sentence: `path(where, v)`, `text(where, v)`, `secs(where, v)`,
  `argv(where, v)`, `opts(where, v)`, `request(where, v)`, `query(where, v)`. `where` is
  the call, as in `"fs.read"`, and the message names the argument that was wrong.

## The public API

### port.check(p) -> problems

`p` is the composite table with fields `model`, `fs`, `sh`, `clock`, `ask`, `log`.
Returns a list of strings, empty when `p` is complete and well shaped. Checks structure
only — that each field is a table, that each function named below is a function. It
calls nothing, so it is safe on a port wired to a live world.

A missing port reads `"no model port"`; a field that is a table but owes a function
reads `"model.call is not a function"`. The order is fixed — model, fs, sh, clock, ask,
log — so two runs report the same list.

`port.check(nil)` returns one problem, `"no port table"`, and so does any other
non-table. It never raises.

There is deliberately no `port.fill(p)` that quietly substitutes doubles for missing
ports. A real run with half a fake world is worse than a run that refuses to start.
A full fake world is built explicitly, by name, with `double.world()`.

### The model port

    p.model.call(request) -> reply | nil, err

The single most important contract in the tree.

`request` is a table:

| field | type | meaning |
| --- | --- | --- |
| `model` | string, required | the id from `agent.model`, e.g. `"openrouter:z-ai/glm-5.3"` |
| `system` | string or nil | the system prompt |
| `messages` | list, required, may be empty | the transcript so far, oldest first |
| `tools` | list or nil | exactly what `spec.schema(a)` returned |
| `reasoning` | string or nil | from `agent.reasoning`: `"none"`, `"low"`, `"medium"` or `"high"`; a port that can tell its model how hard to think does, and one that cannot ignores it |
| `timeout` | number or nil | seconds; advisory, see failure modes |

A message is one of three shapes, discriminated by `role`:

    { role = "user",  text = "review src/turn.lua" }
    { role = "agent", text = "I will read it first.", calls = { call, ... } }   -- calls optional
    { role = "tool",  id = "c1", ok = true, text = "…file contents…" }

`text` is always a string, possibly empty; never nil. A tool message's `id` matches the
`id` of the call it answers, and `ok` is a boolean — a failed tool call is still a
message the model reads (rule 4's shape, applied to every failure, not just refusals).

A call is `{ id = string, tool = string, args = table }`. `args` is a decoded Lua table
keyed by argument name, not a JSON string; converting the far side's encoding is the
port implementation's job, not the harness's.

`reply` is:

    { text = "…", calls = { call, ... }, stop = "done", usage = { sent = 812, back = 44 } }

`calls` is always a list, empty when the model asked for nothing. `stop` is one of
`"done"` (it finished), `"calls"` (it wants tools run), `"cut"` (it hit the far side's
length limit) or `"refused"` (the model itself declined). `usage` is optional and may be
nil; nothing in the harness may require it.

Raises if `request` is not a table, if `model` is missing or empty, or if `messages` is
not a list. Returns `nil, err` for everything the far side does.

### The filesystem port

Five functions. Every `path` is a workspace-relative slash-separated string:
`"src/turn.lua"`. An absolute path, a path containing a `..` segment, or the empty
string returns `denied` — it does not raise, because these arrive from a model and a
model probing outside the workspace is a normal event, not a crash. The one exception
is `list`, for which the empty string is the workspace root and a success; every other
refused path is refused there too.

    p.fs.read(path)          -> text | nil, err
    p.fs.write(path, text)   -> true | nil, err
    p.fs.list(dir)           -> entries | nil, err
    p.fs.remove(path)        -> true | nil, err
    p.fs.exists(path)        -> boolean

`read` returns the whole file as one Lua string, binary-safe, no streaming. Over the
port's size cap it returns `too_big` rather than a truncated string — a silently
truncated file read is how an agent confidently edits the wrong thing.

`write` creates parent directories as needed and replaces an existing file. It returns
`true`, not the byte count, so a caller cannot accidentally treat `0` as failure.

`list(dir)` takes `""` for the workspace root — the empty string is a directory here
and nowhere else, and `exists("")` is still false, because the root is not a thing a
tool reads or writes. Entries are
`{ name = "turn.lua", kind = "file", size = 4210 }` with `kind` either `"file"` or
`"dir"`, sorted by name so two runs agree. Listing a file, not a directory, is
`not_found`; a real empty directory is an empty list and not an error.

Writing to a path that is already a directory is `exists`, and removing a directory is
`denied`: neither call recurses, and neither pretends to have done something.

`exists` never fails and never raises on a bad path — a path that would be denied simply
does not exist, and neither does a path that is not a string. It is the one probe a tool
can make without handling an error.

`read`, `write` and `remove` raise if `path` is not a string, and `write` raises if
`text` is not a string.

### The shell port

    p.sh.run(argv, opts) -> result | nil, err

`argv` is a list of strings, first element the program: `{ "git", "status", "--short" }`.
A plain command string is refused — it raises, as a shape error. To use a shell you
write `{ "sh", "-c", line }` yourself, which makes the decision to invoke a shell visible
at the call site instead of hidden in a quoting rule.

`opts` may be nil, or `{ cwd = "src", stdin = "…", timeout = 30 }`. `cwd` is
workspace-relative and obeys the same path rules as the filesystem port.

`result` is `{ code = 1, out = "…", err = "…", timed_out = false }`.

**A non-zero exit is a result, not an error.** `sh.run` returns `nil, err` only when the
command could not be run at all (`not_found` for a missing program, `denied` for one the
sandbox refuses), or when it was killed on the deadline (`timeout`, and the result is
lost). A test that treats every failure as an exception will get this wrong; the
distinction is the point.

Raises if `argv` is not a list of strings or is empty.

### The clock port

    p.clock.now()        -> seconds        -- epoch, UTC, may be fractional
    p.clock.mono()       -> seconds        -- monotonic; only differences mean anything
    p.clock.sleep(secs)  -> true | nil, err

`now` and `mono` cannot fail. `sleep` returns `unavailable` when the host has no way to
wait — plain Lua has none, so a host that does not supply one gets an honest refusal
rather than a busy loop burning a core.

`sleep` raises if `secs` is not a non-negative number.

### The approval port

    p.ask.request(q) -> decision

`q` is `{ tool = "write", about = "Write a file", args = { path = "notes.md" } }`. A tool
that lets the person edit (`ask = { edit = ... }`, spec/turn.md, "Edits at the gate") adds
`edit`, the names they may change, and `choices`, each one's list or kind; an approval
may then carry `args`, the person's values for those names.

`decision` is `{ allow = false, why = "not outside src/", remember = "once" }`. `allow`
is a boolean and is required. `why` is a string or nil. `remember` is `"once"`,
`"tool"`, `"session"` or nil, and is a hint the harness may honour or ignore; the port
does no caching of its own, because a cache that outlives what the user thought they
agreed to is the worst bug this subsystem could have.

`request` cannot return `nil, err`, and cannot raise on anything the human does. If the
channel is broken, or nobody answers before its own deadline, it returns
`{ allow = false, why = "no answer" }` — **an unavailable approval channel is a
refusal**, never an open gate and never an exception. Rule 4 then carries that refusal
to the model as an ordinary result.

Raises if `q` is not a table or `q.tool` is not a non-empty string.

### The store port

    p.store.read(name) -> rows | nil
    p.store.write(name, rows, change) -> true | nil, why

Where a program's rows live. The host holds them; a tool body reaches them through the
view `store.bind` puts in their place, never raw. The whole contract is spec/store.md.

### The log port

    p.log.write(level, event, fields) -> nil

`level` is `"debug"`, `"info"`, `"warn"` or `"error"`. `event` is a short stable
identifier like `"tool.start"`, not a sentence — the sentence, if any, goes in
`fields.message`. `fields` is nil or a flat table whose values are strings, numbers or
booleans; nested tables are rendered as `"<table>"` rather than walked.

It returns nothing and it cannot fail. A log sink that cannot write drops the line. An
unknown level is coerced to `"info"`. Logging must never be able to end a turn, so this
is the one port with no error path at all — and the reason it may not be used for
anything the harness needs to read back.

## The doubles

`double.world(cfg) -> p` builds all six at once. `cfg` may be nil; each field configures
one double, and any field left out gets an empty one — and an empty one refuses rather
than agrees, so a world nobody configured cannot quietly answer for the world. A field
that is already a built double is taken as it stands, which is how one filesystem is
handed to two worlds on purpose; `model` also accepts a bare list of replies, since a
model configured with nothing else is the common case:

    local p = double.world {
      model = { replies = { … } },
      fs    = { ["src/turn.lua"] = "-- …" },
      sh    = { ["git status"] = { code = 0, out = "clean" } },
      clock = { at = 1700000000 },
      ask   = true,                    -- allow everything
    }

Three rules bind every double:

1. **Deterministic.** No double calls `os.time`, `os.clock`, `os.date`, `io`, `os.execute`
   or `math.random`. Two runs of the same test produce byte-identical results, including
   the order of a directory listing.
2. **Fresh.** Every constructor returns new state. Two doubles in one process cannot see
   each other, exactly as `spec.new` does for agents.
3. **Inspectable.** Each double records what it was asked, on a plain list field a test
   can read directly. No accessor ceremony.

### double.model — the scripted model

    double.model { replies = { … }, after = "error" } -> m

`m` is a model port: `m.call(request)` works as above. `m.seen` is the list of requests
it received, in order, so a test can assert what the harness actually sent — that the
tool schema went along, that the tool result came back with the right id.

Each entry in `replies` is one of:

* **a reply table**, `{ text = "…", calls = { … }, stop = "done" }`, filled in for you:
  a missing `calls` becomes `{}`, and a missing `stop` becomes `"calls"` when there are
  calls and `"done"` when there are not.
* **a shorthand string**, `"all done"`, meaning `{ text = "all done", stop = "done" }`.
* **a shorthand call**, `{ tool = "read", args = { path = "a.txt" } }`, meaning a reply
  with that single call. Ids are assigned as `"c1"`, `"c2"`, … in order, so a test can
  predict them, counting from one per double. An omitted `args` is a call with no
  arguments and becomes `{}`; an `args` that is present and is not a table is the decode
  failure of the failure modes below, and yields `malformed`. A reply whose `text` is
  not a string, whose `calls` is not a list, or whose `stop` is not one of the four is
  `malformed` too — the double answers as a bad far side would, rather than raising.
* **an error table**, `{ code = "timeout", message = "…" }`, meaning that turn returns
  `nil, err` — this is how a test reaches every model failure path without a network.
* **a function** `f(request) -> reply | nil, err`, for the rare conditional script. It is
  called with the request and must not mutate it.

`after` says what happens once the script runs out: `"error"` (the default) returns
`exhausted`, naming the count it reached; `"repeat"` replays the last reply forever,
which is how the runaway-loop test feeds rule 5 — the script itself does not grow, and
the only thing that does is `m.seen`, one entry per call, which is the record the test
is there to read; `"stop"` returns a plain `{ text = "", calls = {}, stop = "done" }`.
A `"repeat"` replay is a fresh reply each time, so its calls get fresh ids rather than
handing the same id to the turn twice.

The default `after = "error"` is chosen so that a harness that silently takes one more
turn than the test expected fails loudly instead of drifting.

### double.fs — the in-memory filesystem

    double.fs { ["src/a.lua"] = "…", ["notes.md"] = "" } -> f

A flat map of path to contents. Directories are implied by the paths, so `list("src")`
works with no directory entries declared; a key ending in a slash, `["tmp/"] = true`,
declares a directory with nothing in it, which is the only way a fake can hold one.
Contents are strings and paths obey `port.path_ok`, both checked when the double is
built, because a malformed fixture is a bug in the test and should say so at once.
`f.wrote` is a list of `{ path = …, text = … }` in write order, `f.removed` a list of
paths, `f.files` the map itself, and `f.cap` is the size limit for `too_big` (nil for
none, read on each call, so a test can set it after building). Setting `f.readonly = true` makes every `write` and `remove` return
`denied`, which is how a test proves the harness does not assume it can write.

Path rules are enforced exactly as the real port states them, including the `..` and
absolute-path refusals — otherwise a test would pass against a fake that is more
permissive than the disk.

### double.sh — the scripted shell

    double.sh { ["git status --short"] = { code = 0, out = "" } } -> s

Keyed by the argv joined with single spaces. A value may be a result table, an error
table (`{ code = "not_found", … }`), or a function `f(argv, opts) -> result | nil, err`.
The two tables are told apart by `code`: a string is an error code, a number or nothing
at all is an exit status. Missing fields fill in: no `code` means `0`, no `out` or `err`
means `""`, no `timed_out` means `false`.

An **unscripted command returns `unscripted`**, naming the command in the message. It
does not return an empty success. A shell double that answers "fine, exit 0" to anything
it was never taught turns a broken agent into a green test.

`s.ran` is the list of `{ argv = { … }, opts = { … } }` actually attempted — including
one refused for its `cwd`, because what the harness tried is what the test is asserting.
Both are copies, so a caller that reuses its argv table cannot rewrite the record.

### double.clock — the frozen clock

    double.clock { at = 1700000000, mono = 0 } -> c

`now` and `mono` return the stored numbers and never move on their own. `c.advance(secs)`
moves both. `sleep(secs)` calls `advance(secs)` and returns `true` immediately, so a test
of a retry-with-backoff runs in no time and still asserts the delays: `c.slept` is the
list of requested durations.

### double.ask — the scripted approval channel

    double.ask(true)                              -- allow everything
    double.ask(false)                             -- refuse everything
    double.ask { read = true, write = false }     -- by tool name; unlisted refuses
    double.ask { { allow = true }, { allow = false, why = "no" } }   -- in order
    double.ask(function (q) return { allow = q.args.path ~= "secrets" } end)

`a.asked` is the list of requests, so a test can prove a tool without `ask = true` was
never put to a human, and that one with it was; each is a shallow copy, so `q.args` is
the very table the caller passed and the rest cannot be rewritten afterwards. A list
script that runs out refuses, with `why = "no answer"` — the same shape as a broken
channel, because from the harness's side there is no difference, and so does a scripted
function that raises or answers with something that is not a decision. Every decision
that does come back is normalised to `{ allow, why, remember }` and nothing else; a
blanket `double.ask(false)` refuses with a `why` that says so, because a refusal a
person reads with no reason attached is the one that gets argued with.

### double.log — the recording sink

    double.log() -> l

`l.lines` is a list of `{ level = "info", event = "tool.start", fields = { … } }`.
`fields` is always a table, empty when the caller passed none or passed something that
is not one, so a test never has to guard the read. A value that is not a string, number
or boolean is rendered rather than walked: a table is `"<table>"`, anything else is its
type in the same brackets. It also honours the contract that it cannot fail:
`l.write(nil, nil)` records a line at `"info"` with event `"?"` rather than raising,
because a log call inside an error path must never be the thing that ends the turn.

## Failure modes

What can go wrong, and exactly what the caller sees.

**The model is unreachable.** `call` returns `nil, err` with `unavailable`. The harness
decides whether to retry; the port never retries on its own, because a retry the caller
did not ask for hides latency, doubles a bill, and can re-run a side effect.

**The model answers with something unreadable** — a truncated body, a tool call whose
arguments are not a table, a tool name that is not a string. The port returns
`malformed` and does not guess. It specifically does not invent an empty `args = {}` for
a call whose arguments failed to decode: running a tool with silently empty arguments is
a worse outcome than a stated failure.

**The model names a tool that does not exist.** The port passes it through as a call.
Validating a call against the schema is the turn's job, not the port's — the port must
not read `agent.tools`, and a port that filtered calls would hide the model's mistake
from the very loop that has to report it.

**The model deadline passes.** `timeout`. `request.timeout` is advisory: a pure-Lua port
cannot preempt a blocked call, so a port that cannot enforce a deadline must state that
by returning `unavailable` from `clock.sleep`. `port.check` cannot see this — it calls
nothing, and whether a clock can wait is only knowable by asking it — so the pairing is
the host's to get right and the turn's to notice. The double simulates a deadline by
scripting a `timeout` error, so every timeout path is testable even though nothing here
can really block.

**A file is missing.** `not_found`, with the path in the message. Never an empty string:
a read that returns `""` for a missing file makes an agent believe it has seen an empty
file and write over it.

**A path escapes the workspace.** `denied`, from `read`, `write`, `remove`, `list` and
`sh.run`'s `cwd` alike. Checked on the textual path before any lookup, so it holds
identically on the double and on disk, and so a symlink cannot be the difference.

**A file is enormous.** `too_big`, and no partial content. The cap belongs to the port
implementation, not to the tool, so one tool cannot opt out of it.

**The filesystem is read-only.** `denied` on write and remove; reads keep working. Half a
world is a normal state, not a reason to stop.

**A command does not exist.** `not_found` from `sh.run`, distinct from the command
running and exiting non-zero, which is a `result` with `code ~= 0` and no error at all.

**A command hangs.** `timeout`, `timed_out` is moot because there is no result — the
output up to the kill is lost. A port that can preserve partial output may return a
`result` with `timed_out = true` instead; both are legal and a caller must handle both,
which is why `result.timed_out` exists.

**Nobody is there to approve.** `{ allow = false, why = "no answer" }`. Stated once more
because it is the failure most likely to be got wrong: the approval port has no error
channel, and its failure value is a refusal. There is no configuration that turns an
unreachable human into an allow.

**A double is asked for something unscripted.** `unscripted`, naming what was asked.
Never a benign default. This is the difference between a test suite that proves
behaviour and one that proves the double is agreeable.

**A double's script runs out.** `exhausted` for the model, refusal for approvals,
`unscripted` for the shell. Each names the count it reached.

**A port function raises.** Only from a shape bug. The harness does not catch these into
tool results: a `nil` where a path belongs is a defect in the harness or a tool body, and
it should stop the test, not become a sentence the model reads and tries to work around.

## What it must NOT do

* **It must not require anything else in the tree.** `src/port.lua` requires nothing at
  all. `src/double.lua` requires `port` and nothing else — it is the contract's own
  fake, and building it on the contract is what keeps the two from drifting. Neither
  requires `spec`, `turn`, the session, the approval gate or the tool registry. `port`
  is the bottom of the stack; every other subsystem may depend on it and it depends on
  none of them. A test proves this by reading the files for a `require` of a sibling.
* **It must not know what a tool is.** It never reads `agent.tools`, never validates a
  call against a schema, never decides whether `ask = true`. It carries a tool schema
  through as opaque data and carries a call back the same way.
* **It must not run a policy.** No retries, no backoff, no rate limiting, no approval
  cache, no fallback model. Each of those is a decision with a visible consequence and
  belongs where a reader is looking for it, which is the turn loop.
* **It must not name a vendor in a shape.** No `messages[i].content` array-of-parts
  because one provider wants that; no `tool_calls`; no `finish_reason`. Translation to
  and from any wire format happens inside a real port implementation the host supplies,
  behind these names. If a second provider forces a change to the shapes above, the
  change is written into this file first.
* **It must not touch the world from a double.** No `io`, no `os.execute`, no
  `os.time`, no sockets, ever, in `src/double.lua`. A test proves this by reading the
  file.
* **It must not log for the harness.** `port` does not write log lines from inside its
  own functions. The caller logs what it did; a port that narrates itself produces two
  accounts of every action that then disagree.
* **It must not mutate what it was given.** `call(request)` does not write into
  `request` or into `request.messages`; `sh.run` does not write into `argv`. A double
  that stores what it saw stores the table it was handed, so a caller that mutates a
  request after the call corrupts the test's record — the doubles therefore shallow-copy
  each recorded request before storing it.

## The tests that would prove it

Happy paths first, then the awkward ones. Names are the test names.

1. `a_complete_world_passes_check` — `port.check(double.world())` returns an empty list.
2. `a_missing_port_is_named` — `port.check { fs = double.fs() }` names the five absent
   ports, one problem each, and does not raise.
3. `check_of_nil_is_one_problem` — `port.check(nil)` returns `{ "no port table" }`.
4. `a_scripted_model_replays_in_order` — three scripted replies come back in order, with
   `stop` filled in and `calls` always a list.
5. `a_scripted_call_gets_a_predictable_id` — the shorthand call form yields `id = "c1"`
   on the first turn and `"c2"` on the second.
6. `the_model_double_records_what_it_was_sent` — `m.seen[1].tools` is the schema table
   the caller passed, and `m.seen[2].messages` ends with the tool message answering
   `"c1"`.
7. `an_error_entry_in_the_script_is_returned_not_raised` — a `{ code = "timeout" }` entry
   comes back as `nil, err`, `err.code == "timeout"`, `err.port == "model"`.
8. `a_reply_is_never_missing_its_lists` — a bare `{ text = "hi" }` script entry yields
   `calls == {}` and `stop == "done"`.
9. `reading_a_file_that_is_there_returns_it_whole` — including a file with an embedded
   zero byte and one with no trailing newline.
10. `writing_creates_the_directories` — `write("a/b/c.txt", "x")` then `list("a/b")` has
    one entry, and `exists("a/b")` is true.
11. `a_listing_is_sorted_and_stable` — the same map inserted in a different order lists
    identically, twice in a row.
12. `an_empty_directory_lists_empty_and_is_not_an_error` — the empty list is a success.
13. `sleep_on_the_double_clock_moves_time_and_returns_at_once` — `now()` advances by the
    requested amount and `c.slept` records it.
14. `a_non_zero_exit_is_a_result` — `sh.run` returns `result.code == 2` with `err` set and
    a nil second return.
15. `an_approved_call_returns_allow_true_and_is_recorded` — `a.asked[1].tool` is the tool
    name and `args` is the decoded table.
16. `a_log_line_records_level_event_and_fields` — and returns nothing.

Adversarial from here down. These are the ones worth writing first.

17. `a_missing_file_is_not_an_empty_string` **(adversarial)** — `read("nope.md")` returns
    `nil` and `not_found`, and the first return is not `""`. Guards the single most
    dangerous confusion in the filesystem port.
18. `a_path_that_climbs_out_is_denied` **(adversarial)** — `"../etc/passwd"`,
    `"a/../../b"`, `"/etc/passwd"` and `""` each return `denied` from `read`, `write`
    and `remove`, and `exists` returns false for all four without raising. The three
    that climb out are `denied` from `list` as well; the empty string is not, because
    there it names the workspace root, and the test asserts that root listing works.
19. `a_path_that_climbs_out_is_denied_as_a_shell_cwd` **(adversarial)** — the same list
    through `sh.run(argv, { cwd = … })`, so the two ports cannot drift apart.
20. `a_read_over_the_cap_returns_no_content` **(adversarial)** — with `f.cap = 8`, a
    twelve-byte file returns `too_big` and the first return is nil, not a prefix.
21. `a_read_only_filesystem_still_reads` **(adversarial)** — `readonly = true` gives
    `denied` on write and remove while read and list keep working.
22. `an_unscripted_command_is_not_a_success` **(adversarial)** — `sh.run { "rm", "-rf" }`
    against an empty `double.sh` returns `unscripted`, and the message contains the
    command. Fails if any default success is ever introduced.
23. `an_exhausted_model_script_says_so` **(adversarial)** — a one-entry script called
    twice returns `exhausted` on the second call, not the first reply again.
24. `a_repeating_script_never_ends_the_loop_itself` **(adversarial, recursion)** — with
    `after = "repeat"` and a reply that calls the same tool, one thousand calls all
    succeed with rising call ids, the script itself does not grow, the only state that
    does is the one-per-call record in `m.seen`, and it is the harness's budget — not
    the port — that stops the loop. This is the port half of rule 5.
25. `a_refusal_is_a_decision_not_an_error` **(adversarial)** — `double.ask(false)` returns
    a decision with `allow = false` and no second return value, and `port.is_error` is
    false for it.
26. `an_unreachable_human_refuses` **(adversarial)** — an approval script that has run
    out, and one whose function raises internally, both yield
    `{ allow = false, why = "no answer" }`, and neither raises out of `request`.
27. `an_unlisted_tool_is_refused_by_the_by_tool_form` **(adversarial)** — `double.ask
    { read = true }` refuses `"write"`, because a permission table must be a whitelist and
    never a blacklist.
28. `a_timeout_is_reachable_without_a_network` **(adversarial)** — a scripted
    `{ code = "timeout" }` and a scripted `sh` result with `timed_out = true` both flow
    through, proving every timeout branch has a test that runs in milliseconds.
29. `a_malformed_call_does_not_become_an_empty_args_table` **(adversarial)** — a script
    entry whose `args` is a string yields `malformed` from `call`, and no reply.
30. `an_unknown_error_code_is_refused_at_construction` **(adversarial)** —
    `port.error("fs", "read", "oops", "…")` raises, so a typo cannot reach a caller
    disguised as a world failure.
31. `the_log_port_cannot_end_a_turn` **(adversarial)** — `log.write(nil, nil)`,
    `log.write("shout", "e", { t = {} })` and `log.write("info", "e", "not a table")` all
    return without raising, and the nested value is recorded as `"<table>"`.
32. `a_double_touches_nothing_real` **(adversarial)** — read `src/double.lua` and fail on
    any of `io.`, `os.execute`, `os.time`, `os.date`, `os.clock`, `math.random`,
    `require "socket"`.
33. `the_port_module_requires_no_sibling` **(adversarial)** — read `src/port.lua` and
    fail on any `require` at all, then read `src/double.lua` and fail on a `require` of
    `spec`, `turn`, `session`, `approval`, `provider`, `compaction` or either tool
    module. `double` requiring `port` is the one edge allowed, and is the point.
34. `a_recorded_request_survives_the_caller_mutating_it` **(adversarial)** — call the
    model double, then push a message onto the request table afterwards; `m.seen[1]` is
    unchanged.
35. `an_empty_transcript_is_legal` **(adversarial, empty input)** — `messages = {}` with
    no system prompt reaches the double and is recorded; nothing in the port requires a
    first user message.
36. `a_wrong_shape_raises_rather_than_returning` **(adversarial)** — `fs.read(nil)`,
    `sh.run("git status")`, `clock.sleep("2")` and `model.call(nil)` each raise, and the
    message names the argument. This is the test that keeps the two-channel convention
    honest in both directions.
