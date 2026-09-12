# session — the conversation as data

`src/session.lua`. Not part of the `agent` surface: an agent file never writes
`agent.session`. The host and the turn loop use this module; a declaration cannot
see it.

## What it is for

A session is the append-only list of messages that make up one run — the standing
instruction, what the person asked, what the model said, every tool call and every
result that came back — held as plain Lua tables and nothing else. It serialises to
JSON and back byte-for-byte, so a run can be saved, listed and resumed on a later
process without the transcript changing under it. Because there is no JSON library
to lean on, this module owns the encoder and the decoder too, and their correctness
is part of its contract rather than someone else's problem.

## The shapes

### A message

One unit of the conversation, with a speaker and a body. Five speakers, and the
speaker decides which other fields are present:

| `speaker`  | fields                                     |
|------------|--------------------------------------------|
| `"system"` | `body` (string), `at` (number)             |
| `"user"`   | `body` (string), `at`                      |
| `"model"`  | `body` (string), `at`                      |
| `"call"`   | `tool` (string), `args` (table), `call_id` (string), `at` |
| `"result"` | `call_id` (string), `body` (string), `ok` (boolean), `refused` (boolean), `at` |

`at` is a number the caller supplies, taken from the clock port; session never reads
a clock itself. `body` may be the empty string — a model that says nothing still
took a turn, and erasing that would be a loss. `args` is always a table, `{}` when
the tool takes no arguments. `refused` carries the fourth rule of `DESIGN.md`: a
refusal is a result, with `ok = false` and `refused = true` and a body saying why,
and it is stored exactly like any other result.

No other field is read. A message carrying extra keys is refused at append rather
than quietly kept, because a field session does not round-trip is a field that
disappears on resume.

### A session

    {
      id       = string | nil,   -- set once, by the caller or by save
      agent    = string | nil,   -- the declared agent name, for listing
      model    = string | nil,   -- the model id, for listing
      started  = number | nil,
      messages = { message, ... },
    }

`messages` is append-only. Nothing in this module removes, reorders or edits an
entry once it is in.

### A record

What goes into the store: one JSON object per session.

    {"agent":…,"format":1,"id":…,"messages":[…],"model":…,"started":…}

`format` is an integer, currently 1. A record whose `format` is anything else is
refused on load, by number, rather than read as if the shape were understood.

## What session needs from port

Session takes its whole world through the port table, so its tests need no network,
no disk and no subprocess — an in-memory table satisfies every call below. These are
the members it uses and the only ones it may touch. If `spec/port.md` names them
differently, port wins and session is adjusted to match; this is the requirement
session places, not a second definition of port.

    port.store.write(id, text) -> true | nil, reason
    port.store.read(id)        -> text | nil, reason   -- reason is exactly
                                                        -- "missing" when absent
    port.store.list()          -> { id, ... } | nil, reason
    port.store.delete(id)      -> true | nil, reason
    port.clock.now()           -> number                -- seconds, may be fractional

`read` must distinguish absence from failure by returning the reason `"missing"` and
nothing else for a record that is not there. Session cannot tell a missing session
from a broken disk otherwise, and reporting one as the other is the kind of lie a
harness gets judged on.

Only `save`, `load`, `list` and `delete` take a port. Everything else is pure.

**Where port stands (settled while building this).** `spec/port.md` and `src/port.lua`
name six ports — model, fs, sh, clock, ask, log — and none of them is a store, so there
was nothing for port to win. `store` is therefore session's own member of the port
table, a seventh alongside the six, with exactly the five calls above; `spec/cli.md`
already writes to the same convention, saying its `world.read` returns `"missing"` for
absence "as `session`'s store does, so the two cannot drift". When port grows a store of
its own, that definition wins and this one is deleted.

Two consequences of living beside those six ports:

- A store's `reason` may be a plain string, as above, or a port error value —
  `{ port, call, code, message }` from `port.error`. Session reads a table reason
  through its `message` (falling back to its `code`), and treats `code = "not_found"`
  as the same absence `"missing"` names. Nothing else about a port error is read.
- The clock is only ever read to mint an id. A clock that answers with something other
  than a finite number is a lying port, not a crash: `nil, "the clock returned string,
  expected the time"`.

## The public API

The line the whole module holds: **a wrong argument type raises; bad data returns
`nil, reason`.** Passing a number where a string belongs is a fault in the calling
code and should stop at the line that made it, so it raises with a sentence. A
transcript that will not decode, a store that will not answer, a tool result that
cannot be encoded — those are the world misbehaving, and they come back as a value
the caller must look at. Nothing in this module ever returns `false` for failure;
failure is always `nil` plus a reason string.

Every reason string is a lowercase sentence fragment naming the thing that was
wrong and, where there is one, its position: an index into `messages`, a byte
offset into the input, or a dotted path into a value.

### Building a transcript

**`session.new(t)` → session**

`t` is optional. Recognised keys: `id` (string), `agent` (string), `model`
(string), `started` (number). Any other key raises, naming it. Any recognised key
of the wrong type raises. Returns a fresh session with `messages = {}`. Two
sessions built in one process share nothing: no upvalue, no registry, no counter.

**`session.set_id(s, id)` → true | nil, reason**

Sets the id when there is none. Returns `nil, reason` when the session already has
a different id — an id is set once, and silently renaming a saved run would orphan
its record. Setting the same id again is a no-op that returns true.

**`session.append(s, msg)` → message | nil, reason**

The one mutation. Validates `msg` against the table above: speaker known, required
fields present and of the right type, no unknown keys. Returns `nil, reason` for
anything that fails, and appends nothing. On success it appends a private copy —
the caller's table is never retained, so a caller that keeps mutating its own table
cannot rewrite history after the fact — and returns a copy of what was stored.

Two data rules beyond field types:

- a `result` whose `call_id` matches no open call returns `nil, "no open call
  \"c3\""`. Several calls may be open at once; a result closes the one it names.
- a `result` for a call that already has one returns `nil, "call \"c3\" already
  has a result"`.

**`session.system(s, text, at)`**, **`session.user(s, text, at)`**,
**`session.model(s, text, at)`** → message | nil, reason

Sugar over `append`. `text` must be a string, `at` a number; both raise otherwise.

**`session.call(s, tool, args, call_id, at)` → message | nil, reason**

`args` may be `nil`, taken as `{}`. `call_id` must be a non-empty string, unique
within the session: a repeated id returns `nil, "call \"c3\" is already in this
session"`, because two calls sharing an id make `result` ambiguous. Emptiness is
checked as data, not as a type: a message reaching `append` with `call_id = ""` returns
`nil, "a call has an empty call_id"`, and one with `tool = ""` returns `nil, "a call
names no tool"`, since a record loaded from a store arrives that way too.

**`session.result(s, call_id, body, opts, at)` → message | nil, reason**

`opts` may be `nil`, taken as `{ ok = true, refused = false }`. It knows two keys and
two booleans: any other key, or a non-boolean, raises the way a wrong argument type
does, because `{ okay = false }` silently meaning success is exactly the misreading
this module exists to prevent. `refused = true` with `ok = true` returns `nil, "a
refused call did not succeed"`: a refusal did not succeed, and a record that claims
both is one the model will read wrongly.

### Reading a transcript

All four return copies. A message handed out is a fresh table with a fresh `args`
table, so no caller can edit the transcript through a value it was given.

**`session.count(s)` → integer** — how many messages. `0` for a new session.

**`session.at(s, i)` → message | nil** — the i-th message, 1-based. Negative `i`
counts from the end, so `-1` is the last. Out of range returns `nil` with no
reason: asking past the end is a normal question, not a failure. A non-number `i`
raises.

**`session.messages(s)` → { message, ... }** — the whole transcript as a new list
of copies. Empty list for an empty session, never `nil`.

**`session.last(s, speaker)` → message | nil** — the last message, or the last of
that speaker when `speaker` is given. An unknown speaker string raises, rather than
returning `nil` forever and looking like an empty transcript.

**`session.pending(s)` → { message, ... }** — the `call` messages with no matching
`result`, in the order they were made. This is what resume is for: a run that died
between a call and its result comes back with the open calls named, and the turn
loop decides whether to re-issue or to write a result saying the run was
interrupted. Session does not decide that.

**`session.header(s)` → table** — `{ id, agent, model, started, count }`, the same
shape `session.list` returns per record, so a listing and a loaded session describe
themselves identically.

### JSON

**`session.null`** — a unique table standing for JSON `null`. Encoding it emits
`null`; decoding `null` yields it. Lua cannot hold `nil` as a table value, so
without a sentinel `{"a":null}` would decode to `{}` and the key would vanish. A
Lua `nil` as a table value is simply absence and encodes to nothing at all.

**`session.max_depth`** — the nesting limit, 200, for both directions. Read-only by
convention; nothing in the module writes it.

**`session.encode(v)` → string | nil, reason**

Deterministic: the same value encodes to the same bytes every time, because object
keys are emitted in byte order. No whitespace between tokens.

- **strings** are byte strings. `"` becomes `\"`, `\` becomes `\\`, and the five
  named controls become `\b \t \n \f \r`. Every other byte below `0x20` becomes
  `\u00xx` with lowercase hex. `/` is never escaped. `0x7f` is emitted verbatim.
  Bytes at `0x80` and above are emitted verbatim, unexamined — a tool that read a
  binary file must survive being written into a transcript, and re-encoding its
  bytes as codepoints would corrupt them. The stated limit is that a record
  containing invalid UTF-8 is not valid JSON for a strict foreign reader; it is
  exact through this codec, which is what resume needs.
- **numbers**: an integer is written with no decimal point. A float always carries
  a `.` or an `e`, so the Lua 5.4 integer/float distinction survives a round trip
  (under LuaJIT 5.1 there is no distinction to lose). A float is written at the
  shortest precision that reads back identically — `%.14g`, then `%.15g`, `%.16g`,
  `%.17g`, first one that survives `tonumber` — so `0.1` is `0.1` and not
  `0.10000000000000001`, and the value is still exact. NaN and infinity are not
  JSON: `nil, "not a number: nan at .messages[3].args.n"`.
- **booleans** are `true` and `false`.
- **tables**: a table whose keys are exactly the integers 1..n is an array; a table
  whose keys are all strings is an object; an empty table is an object, `{}`.
  Anything else is refused with the offending key and its path — a mixed table
  (`{1, a = 2}`), a sparse array (`{[1]=1,[3]=3}`), a key that is a boolean or a
  table. Guessing at any of these loses data silently, which is worse than a
  refusal the caller can read.
- **cycles** are refused by identity, not by running out of depth:
  `nil, "cycle at .args.self"`. Depth beyond `max_depth` is refused separately,
  `nil, "too deep at .a.b.c…"`. A shared value reached twice by different paths is
  fine and is written twice; only a value containing itself is a cycle.
- functions, userdata and threads are refused by type and path.

The one documented loss through a round trip: an empty array and an empty object
are the same Lua table, and both come back as an empty table encoding as `{}`.

**`session.decode(text)` → value | nil, reason**

`text` must be a string; anything else raises. Every failure names a byte offset:
`nil, "unexpected end of input at byte 12"`.

Strict. It accepts JSON and only JSON, and refuses, each with its offset: a
trailing comma; a comment; a single-quoted string; an unquoted key; a leading `+`
or a leading zero (`01`); `.5` or `5.`; hex; `NaN`, `Infinity`, `undefined`; a raw
byte below `0x20` inside a string; anything at all after the top-level value except
whitespace. Whitespace is space, tab, carriage return and newline, nothing else.

- `\uXXXX` decodes to UTF-8 bytes. A high surrogate followed by a low surrogate
  becomes one codepoint. A lone surrogate is refused at its offset rather than
  turned into a replacement character, because a silent replacement is a
  transcript that no longer says what happened.
- a number whose value overflows to infinity is refused, `"number out of range at
  byte 40"`, rather than becoming `inf` and then failing to encode later.
- a duplicate key in an object is refused, naming the key and offset. Last-wins
  would mean two decoders disagree about the same file.
- nesting deeper than `max_depth` is refused at its offset. This is a counter, not
  recursion running out: a file of a hundred thousand `[` must produce a reason,
  never a stack overflow, and never an abort under LuaJIT where the overflow is not
  catchable.

Bytes at `0x80` and above pass through inside strings unexamined, matching the
encoder.

### Saving and resuming

**`session.save(s, port)` → id | nil, reason**

Encodes the whole record first and writes only if the encoding succeeded, so a
failure never leaves a truncated record in the store. When the session has no id,
save mints one from `port.clock.now()` — the millisecond count as a decimal string
— and, if the store already holds that id, appends `-2`, `-3` and so on until one
is free. The id is set on the session and returned once the write has succeeded — not
before, so a failed save spends no id — and a second save then overwrites the same
record rather than making a second one. Minting gives up after a thousand collisions
on one millisecond, with a reason rather than a loop. A record is written
whole; there is no partial or incremental write.

Each message is encoded at the depth the record will hold it at — the record object
is one, its `messages` array two, a message three — so `max_depth` means the same
thing to `save` as it does to `decode`. Encoding a message as though it stood alone
would give it a full 200 levels of its own and leave a band of nesting that saves and
then will not load, which is the one thing a transcript may not do. `save`'s limit is
therefore the record's, not the message's: args nested past 196 are refused before
anything is written, because a record holding them is a record `load` would refuse.

Failures: `nil, "cannot encode message 3: cycle at .args.self"` when a tool result
will not serialise; `nil, "store: timeout after 5s"` — the port's reason verbatim
behind a `store:` prefix, so the caller can see which layer failed. On any failure
the in-memory session is untouched and can be saved again.

**`session.load(port, id)` → session | nil, reason**

Reads, decodes, validates every message, and returns a session that
`session.count` and `session.pending` work on directly. All or nothing: one bad
message means no session, not a session missing its middle.

Failures, in the order they are checked: `nil, "no session \"abc\""` for a store
that answered `"missing"`; `nil, "store: <reason>"` for any other store failure;
`nil, "store returned a number, expected the record text"` for a port that answered
with the wrong type; `nil, "not a session record: <decode reason>"`; `nil, "not a
session record: no messages array"`; `nil, "session record format 2, this build
reads 1"`; `nil, "message 7: unknown speaker \"shout\""`.

The same order carries five refusals the first draft of this spec left unsaid, each of
them a record that is shaped wrongly rather than a session that is merely old:
`"not a session record: the record is a number"` when the top level is not an object;
`"not a session record: messages is not an array"` when `messages` decoded to an object;
`"not a session record: no format number"` and `"not a session record: format is a
string, not a number"` before the format number can be compared; and `"not a session
record: id is a number, not a string"` for `id`, `agent`, `model` or `started` of the
wrong type. A record whose `id` is absent loads under the id it was read with, so a
listing and a load agree about what to call it.

**`session.list(port)` → { header, ... } | nil, reason**

One header per record the store lists, sorted by `started` ascending and then by
id, so two listings of the same store agree. A record with no `started` — every broken
one included, since a record that will not decode has no fields — sorts after every
record that has one, and those tie-break by id. A store that answers `list` with
something that is not a list gives `nil, "store returned a number, expected a list of
ids"`; a single entry in the list that is not a string is one `broken` row, not the end
of the listing. A record that will not read or will
not decode appears as `{ id = id, broken = reason }` rather than sinking the whole
listing — one corrupt record must not hide the other forty. `nil, "store: <reason>"`
only when the store's own `list` fails. An empty store gives an empty list, never
`nil`.

**`session.delete(port, id)` → true | nil, reason**

Passes the port's failure through with the `store:` prefix. Deleting an id that is
not there returns `nil, "no session \"abc\""`. Nothing else in the module removes a
record, and nothing removes a message.

## The failure modes

| What went wrong | What the caller sees |
|---|---|
| A string where a number belongs, or the reverse | raises, at the calling line, with a sentence saying which argument and what was given |
| An unknown speaker on append | `nil, "unknown speaker \"shout\""` |
| A message with an extra key | `nil, "message has an unknown field \"colour\""` |
| A `result` naming no open call | `nil, "no open call \"c3\""` |
| A second `result` for one call | `nil, "call \"c3\" already has a result"` |
| A repeated `call_id` | `nil, "call \"c3\" is already in this session"` |
| A result that is both `ok` and `refused` | `nil, "a refused call did not succeed"` |
| Tool args containing a function, a cycle, NaN, a mixed table | `nil, "cannot encode message 3: <what and where>"` from save; nothing is written |
| Tool args nested past the record's room | `nil, "cannot encode message 3: too deep at …"`; nothing is written, and no record is left that `load` would refuse |
| The store cannot be written — full, read-only, timed out | `nil, "store: <the port's reason>"`; the session is unchanged and re-savable |
| The store hangs | session waits, because session owns no clock and no timeout. It never retries and never wraps the call in a loop. Timeouts belong to the port; whatever reason it eventually returns is surfaced verbatim |
| A record that is not there | `nil, "no session \"abc\""` — never confused with a store failure |
| A record that is not JSON | `nil, "not a session record: unexpected character 'x' at byte 4"` |
| A record from a future build | `nil, "session record format 2, this build reads 1"` |
| A record with one bad message | `nil, "message 7: …"`; no session is returned |
| One bad record among many, in `list` | that id alone carries `broken`; the rest list normally |
| A port that answers with the wrong type | `nil, "store returned a number, expected the record text"` — a bad port is data, not a crash |
| A hostile record: a hundred thousand open brackets | `nil, "too deep at byte 201"`; no stack overflow, no abort |
| An empty transcript | not a failure. Saves as `"messages":[]`, loads to a session with count 0 |

## What it must NOT do

- **No world of its own.** No `io`, no `os`, no `require` of anything outside this
  module. The file must not contain `io.`, `os.`, `require`, `loadstring`,
  `dofile`, a bare `load(` or a socket name. `session.load` is the module's own verb,
  and `function session.load(port, id)` contains the four letters and the bracket, so
  the pattern is a `load(` **not reached through a dot** — `[^%w_.]load%s*%(`, plus the
  same at the start of the file. `io.` and `os.` are matched on a word boundary for the
  same reason: a sentence ending "…the ratio." is not a vendor. Every clock reading and
  every byte in or out comes through the port argument. Tested by reading the file, the
  way rule 1 is tested.
- **One file.** `src/session.lua` and nothing beside it. Splitting the codec out would
  take a `require`, which the rule above forbids, so the module stays whole however
  long it gets.
- **No global state.** No module upvalue holding "the current session", no counter,
  no cache. Two sessions in one process see nothing of each other.
- **It does not reach into other subsystems.** It never reads the agent table built
  by `src/spec.lua`, never imports `src/turn.lua`, never calls a tool body, a model
  or a hook. It takes strings, numbers and tables, and gives them back.
- **It does not make anything happen.** Recording a call does not issue it.
  Recording a refusal does not perform one. Loading a session with an open call
  does not re-issue it — `pending` reports, the turn loop decides.
- **It does not have an opinion about permission.** Rule 4 puts the gate in the
  harness. A refusal reaches session as an ordinary result and is stored as one.
- **It does not trim, summarise, compact or reorder.** Fitting a transcript into a
  context window is the turn loop's problem, and even there the session is read,
  not rewritten. Nothing here deletes a message.
- **It does not own the budget.** Rule 5's step count belongs to the loop. Session
  will hold a transcript of any length and has no opinion about when to stop.
- **It does not guess.** No lenient JSON, no last-key-wins, no replacement
  character for a bad escape, no `[1,2,null]` for a sparse array. Every ambiguity
  is a refusal with a position.
- **It does not hand out its insides.** Every message it returns is a copy. There
  is no accessor that yields the live `messages` list.

## The tests that would prove it

Pure Lua, no network, no disk, no subprocess: the store is a table of strings and
the clock is a closure returning a number the test chose.

**Round trip and the codec**

1. `a_transcript_survives_a_round_trip` — build a session with one message of every
   speaker, encode, decode, and compare message by message: same count, same
   speakers, same bodies, same `args`, same `at`.
2. `an_empty_session_saves_and_loads` — no messages, no id set. Saves, mints an id,
   loads back with count 0.
3. `every_escape_comes_back` — *adversarial*. A body holding `"` `\` `/` a tab, a
   newline, a carriage return, a form feed, a backspace, byte `0x00`, byte `0x1f`,
   byte `0x7f`, and a run of bytes `0x80`–`0xff` that is not valid UTF-8. Encoded,
   decoded, and compared with `==` for byte equality. Also asserts `/` was not
   escaped and that the controls used their short forms.
4. `an_embedded_nul_is_not_a_terminator` — *adversarial*. A body of
   `"before\0after"` round-trips at full length, and the encoder emitted the six
   characters `\u0000` rather than stopping at the byte.
5. `a_float_stays_a_float_and_an_integer_stays_an_integer` — under 5.4, `1.0`
   encodes with a decimal point and decodes as a float; `1` encodes bare and
   decodes as an integer. Under 5.1 the test asserts only that the values are equal.
6. `an_awkward_float_is_short_and_exact` — `0.1`, `1/3`, `1e308`, `5e-324`,
   `-0.0`: each encodes to the shortest form that reads back bit-identical. Negative
   zero is the one value 5.1 must still treat as a float: there is no integer subtype
   to lose, but writing it as a bare `0` would throw the sign away, so the encoder
   checks for it by hand.
7. `not_a_number_is_refused` — NaN and both infinities return `nil` and a reason
   naming the path, from `encode` and from `save`.
8. `encoding_is_deterministic` — a table with keys declared in a scrambled order
   encodes to the same bytes twice, and to the byte-ordered form.
9. `null_survives_both_ways` — `session.null` encodes to `null`; `{"a":null}`
   decodes to a table whose `a` is `session.null`, and re-encodes identically.

**The decoder under attack**

10. `deep_nesting_is_refused_not_crashed` — *adversarial*. A string of 100,000 `[`
    returns `nil` and a reason with a byte offset, in bounded time, with no stack
    overflow and no abort. Run under both interpreters on PATH.
11. `a_self_referential_table_is_refused` — *adversarial*. `t.self = t` given to
    `encode` returns `nil, "cycle at .self"` instead of running forever. A value
    reached twice by two different paths is not a cycle and encodes twice.
12. `sloppy_json_is_refused_with_a_position` — *adversarial*. A table of inputs,
    each with the byte offset expected: `{"a":1,}`, `{a:1}`, `{'a':1}`, `[1 2]`,
    `01`, `.5`, `5.`, `0x10`, `NaN`, `Infinity`, `undefined`, `//comment`,
    `{"a":1} trailing`, a raw newline inside a string, and the empty string.
13. `a_lone_surrogate_is_refused` — *adversarial*. `"\ud800"` alone returns a
    reason; a proper pair `"😀"` decodes to the four UTF-8 bytes of that
    codepoint.
14. `a_duplicate_key_is_refused` — `{"a":1,"a":2}` returns a reason naming `a`.
15. `a_truncated_record_is_refused` — *adversarial*. Every prefix of a valid
    encoded session, cut at each byte, is fed to `decode`; every one returns `nil`
    and a reason, and none raises.
16. `a_number_that_overflows_is_refused` — `1e400` returns a reason rather than
    infinity.

**The transcript**

17. `messages_only_ever_append` — after twenty appends, message 1 is still message
    1 and count is 20. There is no public way to remove one.
18. `a_returned_message_cannot_edit_history` — *adversarial*. Mutate the table
    handed back by `append`, by `at` and by `messages`, including its `args`, then
    read the transcript again and find it unchanged.
19. `an_unknown_field_is_refused` — a message with `colour = "red"` is refused,
    naming the field, and the transcript is unchanged.
20. `a_result_needs_an_open_call` — a result for `c9` with no call is refused; a
    second result for `c1` is refused; two calls open at once are each closed by
    the result naming them.
21. `a_refused_call_is_stored_as_a_result` — a result with `refused = true`,
    `ok = false` and a body survives a round trip with all three intact, and
    `ok = true` with `refused = true` is refused at append.
22. `pending_names_what_resume_must_decide` — a session saved between a call and
    its result loads with that call in `pending`, in order, and nothing has been
    re-issued.
23. `an_empty_body_is_kept` — a model message with `body = ""` round-trips as an
    empty string and not as absent.

**The store, through a fake port**

24. `a_missing_session_is_not_a_broken_store` — a port answering `nil, "missing"`
    gives `no session "abc"`; a port answering `nil, "permission denied"` gives
    `store: permission denied`. The two reasons are different strings.
25. `a_write_failure_writes_nothing_and_loses_nothing` — *adversarial*. A port
    whose `write` returns `nil, "timeout after 5s"` leaves the store with no new
    key, the session unchanged, and a second save against a working port succeeds
    with the same content.
26. `an_unencodable_message_never_reaches_the_store` — *adversarial*. A session
    holding a tool result with a function inside `args`: save returns a reason
    naming message 3, and the port's `write` was never called — asserted by a
    counter on the fake port.
27. `one_broken_record_does_not_hide_the_others` — *adversarial*. A store of five
    records, one of them the text `not json at all` and one whose read fails:
    `list` returns five headers, three good and two carrying `broken`, in the
    stated order.
28. `a_lying_port_is_data_not_a_crash` — *adversarial*. A port whose `read` returns
    a number, a boolean, or a table instead of text; each gives `nil` and a reason,
    and none raises.
29. `a_future_record_is_refused_by_number` — a record with `"format":2` refuses
    with both numbers in the reason.
30. `saving_twice_keeps_one_record` — save, append two messages, save again: the
    store holds one key, the id is unchanged, and loading gives the longer
    transcript.
31. `a_minted_id_does_not_collide` — a clock returning the same number twice mints
    `…` then `…-2`, and both records survive.
32. `session_names_no_vendor` — reads `src/session.lua` and fails on `io.`, `os.`,
    `require`, `loadstring`, `dofile`, `load(` or a socket name, the way rule 1 is
    tested. The test carries its own name as the case that must not false-positive.
33. `two_sessions_share_nothing` — build two sessions, append to one, and find the
    other still empty; save both and find two records.

Two more the list wanted and did not name, both written:

34. `the_record_is_what_the_encoder_would_write` — `save` assembles a record out of
    messages it encoded one at a time, so that it can name message 3 when message 3 is
    what will not serialise. That assembly must land on exactly the bytes
    `session.encode` gives the same table, or the record and the codec drift apart and
    only one of them is tested.
35. `a_wrong_argument_type_raises` — the line the whole module holds needs a test of its
    own: a table where a number belongs, an unknown field to `session.new`, an unknown
    option to `session.result`, a non-string to `decode`, a port with no store. Each
    raises with a sentence; none returns `nil, reason`.

Six more the verification pass added, each because a stated behaviour had no test that
would notice it going away:

36. `a_raise_names_the_line_that_called` — the raise lands on the caller's line and not
    on a line of `src/session.lua`. Test 35 asserted only that a sentence came back, so
    every raise reached through a `want_` helper was blaming the module itself and no
    test could tell.
37. `a_speaker_narrows_the_last_message` — `session.last(s, speaker)` returns the last
    message of *that* speaker, and `nil` for a speaker who never spoke. Without it the
    filter could be deleted and every test would still pass.
38. `a_table_that_is_neither_an_array_nor_an_object_is_refused` — a mixed table, a
    sparse array, and a key that is a boolean, a table, `0`, `-1` or a fraction: each
    refused with its path, and the refusal reaches `save` as `cannot encode message 1`
    with nothing written.
39. `a_port_error_reads_as_a_reason` — a store answering with `{ port, call, code,
    message }` rather than a string: `not_found` is the same absence `"missing"` names,
    any other code surfaces its `message`, a table with no `message` falls back to its
    `code`, and a listing carries the same reason on the row that is broken.
40. `a_record_too_deep_to_read_is_never_written` — args nested 196 deep save and load;
    197 deep are refused, and the store is left untouched. This is the band that used to
    save and then fail to load.
41. `minting_gives_up_rather_than_looping` — a store that holds every id gives a reason
    naming the thousand, not a hang; a clock answering NaN is a lying port, not a crash.
