# tools_shell — the shell tool

Status: implemented. Lives at `src/tools_shell.lua`; its tests at
`test/tools_shell_test.lua`. Where this file and the code disagreed, this file moved —
every such change is marked **(amended)** below.

## 1. What it is for

The shell tool runs one command line in the workspace and reports exactly what
happened: standard output, standard error, the exit code, and how long it took. It
takes its whole world — spawning, killing, the clock, the workspace root — through the
port, so it can be tested with no subprocess, no disk and no network. It is the most
dangerous tool in the harness, so everything it declines to do it declines out loud,
with a named reason the model can read and act on.

## 2. The port this needs

**(amended)** `spec/port.md` has since landed, and its shell port is a different shape:
`p.sh.run(argv, opts) -> result | nil, err`, argv-shaped, cwd workspace-relative, timeout
in seconds, no byte ceiling and no environment overlay. Both surfaces are kept, and the
reason is that they answer different questions. The `exec` contract below is the one this
tool is written against, because it carries the four things the tool exists to report —
a duration, a signal, a spawn failure told apart from an unsupported host, and a host-side
byte ceiling — none of which the argv port can express. `shell.exec_from_port(sh, root)`
turns the landed port into an `exec`, so a host that wired the standard port needs no glue
of its own, and `shell.run` uses it automatically when the context carries `sh` and no
`exec`. What the adapter cannot carry it drops out loud rather than faking: `env` and
`max_bytes` are ignored, `duration_ms` comes back nil, and a `not_found` or `denied` from
the port becomes `spawn_failed` while `unavailable` becomes `unsupported`. **(amended)**
What it must not drop is `code`: a port result carrying none travels on codeless, so the
tool's own F9 check names it as `port_contract`. Defaulting it to zero would report to
the model a clean success the port never claimed, which is the one guess this module
exists to refuse.

The context field `root` is a dependency on the host, not on another subsystem: `turn`
copies every port key onto a tool context, so a host wires `port.root = "/abs/path"` and
the tool sees `ctx.root`. Without it `shell.run` raises, because a shell tool that does
not know where the workspace is has nothing to run in.

The tool reads exactly four fields off the context table it is handed, and nothing
else:

    ctx.exec     function  required   -- run a command, described below
    ctx.root     string    required   -- absolute path of the workspace root
    ctx.resolve  function  optional   -- resolve a workspace-relative path
    ctx.args     table     required   -- the model's arguments for this call

`ctx.exec(request) -> outcome`

    request = {
      command    = string,            -- the command line, verbatim, never re-quoted
      cwd        = string,            -- absolute, always inside ctx.root
      timeout_ms = number,            -- whole number, > 0
      max_bytes  = number,            -- hard ceiling on what the host will buffer
      env        = table | nil,       -- string -> string overlay, not a replacement
      stdin      = string | nil,      -- nil means an empty, immediately closed stdin
    }

    outcome = {
      status      = "exited" | "timeout" | "spawn_failed" | "unsupported",
      code        = number | nil,     -- present if and only if status == "exited"
      signal      = string | nil,     -- e.g. "SIGKILL", when the host knows one
      stdout      = string,           -- "" when there was none, never nil
      stderr      = string,
      duration_ms = number,
      overflowed  = boolean | nil,    -- true if max_bytes was reached and output dropped
      message     = string | nil,     -- why, when status is spawn_failed or unsupported
    }

Three obligations on the port, which the tool cannot check and states here instead:

- **It does not raise.** Every real-world failure comes back as an outcome. The tool
  still calls it under `pcall`, because a port that breaks this must not take the turn
  down with it (failure mode F7).
- **It enforces the timeout itself, and kills the process group.** A timeout that only
  stops waiting leaves a runaway command alive. The tool has no way to kill anything.
- **It enforces `max_bytes` while the command is running.** Truncating in Lua is too
  late: a command that emits a gigabyte has already cost that gigabyte by the time the
  string reaches this tool.

`ctx.resolve(root, rel) -> abs | nil, reason` resolves a workspace-relative path against
the root and returns nil plus a one-line reason if the result escapes it. It is optional
so that a host with no path layer can still wire the shell tool up; see refusal
`cwd_unsupported`. **(amended)** Whether a path escapes is entirely `resolve`'s judgement.
The tool does not re-check the answer against the root, because the only check it could
make from here is the lexical prefix one, which accepts `/w/space` as being inside
`/w/spa`. If `resolve` itself raises, that is a broken port and comes back as
`reason = "port_error"`, not as a refusal. **(amended)** So does a `resolve` that
*returns* off-contract — anything that is neither nil/false nor a non-empty string — save
that it comes back as `port_contract`. Only nil is a judgement about the path, and only a
judgement about the path is the model's to read; a table where a path belongs is the
harness's bug, and reporting it as a directory the model chose badly sends the model off
to fix something it did not break.

## 3. The public API

The module returns one table. Everything on it is pure with respect to the process: no
module-level mutable state, so two calls in flight never see each other.

### `shell.options(t) -> opts`

Normalizes and validates a declaration-time options table. `t` may be `nil` (all
defaults) or a table. Returns a fresh normalized table; never mutates `t`. Idempotent:
`shell.options(shell.options(t))` returns a table equal to the first.

    about       string   default: a one-sentence description of the tool
    ask         boolean  default: TRUE. The shell tool asks before it runs.
    cwd         string   default: ".". Workspace-relative default directory.
    timeout_ms  number   default: 30000. The default when the model names none.
    timeout_max number   default: 600000. The largest the model may ask for.
    stdout_cap  number   default: 32768 bytes kept from stdout.
    stderr_cap  number   default: 8192 bytes kept from stderr.
    port_max    number   default: 4194304. Passed to the port as `max_bytes`.
    env         table    default: nil. string -> string, merged over the host's.
    stdin       string   default: nil.

**Raises** (`error`, not a returned failure) on: a non-table, non-nil `t`; any key not
in the list above, naming the offending key, because a silently ignored typo in a
declaration is how a harness ends up running with a 30-second timeout the author
believed was five minutes; a value of the wrong type; a non-whole or non-positive
number; `timeout_ms > timeout_max`; a cap below 256 bytes; an `env` whose keys or
values are not strings.

**(amended)** Three details the first draft left open. The 256-byte floor applies to
`stdout_cap`, `stderr_cap` and `port_max`; the timeouts floor at 1 ms. An infinite or
NaN number raises rather than passing the whole-number test. An empty `about` and an
empty `cwd` raise — `about = ""` is refused by `spec.add_tool` anyway, and `cwd = ""` is
a path that names nothing, where `"."` names the root. `env` is copied into the
normalized table, so a later edit to the caller's table cannot change what a run sends.

Declaration-time wrongness raises. Model-supplied wrongness never does. That line is the
whole error contract of this module and section 4 is organized around it.

### `shell.tool(t) -> decl`

Builds the declaration table to hand to `agent.tool`:

    agent.tool "shell" (shell.tool { timeout_ms = 120000 })

Returns a plain table with the four keys `spec.add_tool` reads — `about`, `args`, `ask`,
`run` — and no others. `args` is:

    command     agent.string      "the command line to run"
    cwd         agent.string_opt  "workspace-relative directory to run it in"
    timeout_ms  agent.number_opt  "how long to allow, in milliseconds"

Calling `shell.tool` runs nothing (rule 2). The returned `run` is a closure over the
normalized options; it is called only by `turn.run`. `shell.tool(t)` raises exactly what
`shell.options(t)` raises, at declaration time, which is where a wiring mistake is cheap.

**(amended)** The closure returns two values, `result.text` and `result`: the model reads
the rendered block, and a host that wants the structure takes the second. `turn` records
the first, which is a string, so the transcript never carries a stringified table.

**(amended)** The three `args` entries are built as the plain tables `spec.lua`'s
constructors build — `{ __param = true, kind, required, description }` — rather than by
requiring `spec`, because section 5 forbids this file naming a sibling. The two shapes
are held together by a test that hands this declaration to `spec.add_tool` and reads the
schema back.

### `shell.run(ctx, opts) -> result`

The body. `ctx` is the context table described in section 2; `opts` may be a normalized
options table, a raw one, or nil.

**Raises** only on a harness wiring bug, never on anything the model or the command did:

- `ctx` is not a table
- `ctx.exec` is not a function
- `ctx.root` is not a non-empty string
- `ctx.args` is not a table
- `opts` fails `shell.options`

**Returns**, in every other case including every failure, a table:

    {
      status      = "exited" | "timeout" | "failed" | "refused" | "unavailable",
      ok          = boolean,        -- derived: status == "exited". See the note below.
      code        = number | nil,   -- present iff status == "exited"
      signal      = string | nil,
      command     = string | nil,   -- as given; nil if the command was unreadable
      cwd         = string | nil,   -- absolute, as it was actually used
      duration_ms = number | nil,   -- nil unless the command actually ran
      stdout      = string,         -- "" when there was none or none was reached
      stderr      = string,
      dropped     = { stdout = number, stderr = number },  -- bytes elided, 0 if none
      bytes       = { stdout = number, stderr = number },  -- true size before truncation
      overflowed  = boolean,        -- the host's buffer ceiling was hit
      reason      = string | nil,   -- a reason code; present iff ok is false
      detail      = string | nil,   -- one sentence of English; present iff reason is
      text        = string,         -- the rendered block the model reads
    }

Every field is always present with the stated type or an explicit `nil` — the caller
never has to distinguish "absent" from "nil". `stdout`, `stderr`, `dropped`, `bytes`,
`overflowed` and `text` are never nil, on any path, including a refusal.

**(amended)** `bytes` was not in the first draft and the rendering cannot be written
without it: a header that says "32768 of 918233 bytes" needs the true total, and the
truncated string plus `dropped` does not give it back once a marker has been spliced in.
On a refusal both counts are 0.

**`ok` is not "the command succeeded".** `ok` means the command ran to completion and
the harness has a real exit code to show. `status == "exited", code = 1` is `ok = true`.
A failing test suite is a successful tool call; the model reads the code and the output
and decides. Anything else conflates "the harness worked" with "the build passed", and a
model that cannot tell those apart will start trying to fix the harness.

### `shell.render(result) -> string`

The rendering, exposed separately so it can be tested against a hand-built result and so
a host can re-render one. Pure; does not mutate. Shape:

    $ npm test
    exit 1 after 4210ms in /w/space/ui
    --- stdout (2048 bytes) ---
    <output>
    --- stderr (empty) ---

**(amended)** The directory printed is `result.cwd`, which is absolute, because that is
the field the result carries and a rendering that invented a relative form would be
guessing at a root it was not given. The second line is `exit N [after Dms] [in CWD]` for
an exit, `timed out [after Dms] [in CWD]` for a timeout, and `<status>: <reason>` for
everything else, with the `detail` sentence on the line beneath. Stream blocks are
printed when the command ran — an exit, a timeout, or a kill by signal — or when there
is output to show, and never for a refusal or an unavailable host. An overflowed stream
prints `--- stdout (N bytes, total unknown: the host stopped buffering) ---`.
**(amended)** `overflowed` is one flag for both streams, so it is applied only to a
stream that actually has bytes in it; an empty one still prints `(empty)`. A header
reading `--- stderr (0 bytes, total unknown) ---` claims a loss that did not happen and
throws away the distinction test 6 exists to protect.

A truncated stream carries its marker inline and names the loss in the header:

    --- stdout (32768 of 918233 bytes, 885465 elided) ---
    <head>
    ... 885465 bytes elided ...
    <tail>

A refusal renders as the command that was asked for and why it was declined, and no
stream headers at all, because nothing ran and empty output blocks would imply it did:

    $ make deploy
    refused: cwd_escapes_root
    "../../etc" resolves outside the workspace root.

### `shell.truncate(s, cap) -> kept, dropped`

Exposed because it is the part most likely to be wrong. Returns the retained string and
the number of bytes elided (0 when `s` fit). Middle-out: the head names what ran, the
tail carries the error, and the middle is what a runaway loop fills. Exactly:

- `#s <= cap` returns `s, 0`.
- otherwise `head = math.floor(cap * 0.4)` bytes from the front, `tail = cap - head`
  bytes from the back, joined by `"\n... N bytes elided ...\n"`.
- both cut points are then moved *inward* while the byte just outside the cut is a UTF-8
  continuation byte (value 128 to 191), so the tool never emits half a codepoint. The
  retained bytes are therefore always at most `cap`; the marker is additional and adds
  at most 40 bytes.
- **(amended)** that walk is bounded at three bytes per cut, which is the longest run of
  continuation bytes a valid character carries. Past three there is no character left to
  protect, and unbounded the walk is a real loss rather than a theoretical one: 300 bytes
  of a stream that is not UTF-8 walk both cuts to zero and the tool keeps *none* of the
  output, which is the exact opposite of what F10 promises. The retained payload is
  therefore always at least `cap - 6`.
- `cap < 256` raises; `s` not a string raises. Both are caller bugs.

### `shell.reasons`

A table mapping every reason code to its English sentence, so a host can list the
refusals without provoking them. The codes are closed; adding one is a change to this
file. See section 4.

## 4. The failure modes

Two kinds, and the difference is who made the mistake.

**A refusal is a result.** Anything the model got wrong comes back as
`status = "refused"` with a `reason` code and a `detail` sentence, and the model reads it
on the next step and tries again. Rule 4: a refusal is not an error and not a silent
skip. None of these ever reach `ctx.exec`.

| reason | what happened | what the model reads |
|---|---|---|
| `no_command` | `command` absent or not a string | "This tool needs `command`, a string." |
| `empty_command` | command is empty or only whitespace | "The command was empty." |
| `command_too_long` | over 8192 bytes | "The command was N bytes; the limit is 8192." |
| `command_has_nul` | contains a zero byte | "The command contained a zero byte, which cannot be passed to a shell." |
| `bad_cwd` | `cwd` present but not a string | "`cwd` is a workspace-relative path, given as a string." |
| `cwd_escapes_root` | resolves outside `ctx.root` | "\"X\" resolves outside the workspace root." |
| `cwd_unsupported` | `cwd` given but no `ctx.resolve`, or no `ctx.resolve` and a declared `cwd` other than `"."` | "This harness cannot change directory; omit `cwd`." |
| `bad_timeout` | not a whole positive number, including infinite and NaN | "`timeout_ms` is a whole number of milliseconds, greater than zero." |
| `timeout_too_long` | above `timeout_max` | "Asked for N ms; the limit is M." |

Two refusals are deliberately absent, and their absence is the design.

- **There is no denylist of dangerous command text.** The tool does not scan the command
  for `rm`, `curl`, `sudo`, a redirect or anything else. Substring matching on a shell
  command line is security theatre — it refuses `rm -rf /` and waves through
  `$HOME/bin/x` or a base64 pipe — and its real cost is that it teaches whoever wired
  the harness up that a check happened. Judging what a command means is the approval
  gate's job (rule 4), and the gate has a human or a policy behind it. This tool checks
  structure and nothing else.
- **There is no allowlist of programs either**, for the same reason and one more: a
  shell tool that can only run seven binaries is a worse version of seven tools.

**A fault is also a result, but a different one.** Something outside the model's control
went wrong.

- **F1 — the command timed out.** Port returns `status = "timeout"`. Result:
  `status = "timeout"`, `ok = false`, `code = nil`, `reason = "timed_out"`, detail naming
  the limit, `duration_ms` set, and **whatever output arrived before the kill is kept and
  truncated normally**. Partial output from a hung build is usually the whole diagnosis;
  discarding it because the command misbehaved is the harness misbehaving too.
- **F2 — the command could not be started.** Port returns `spawn_failed`. Result:
  `status = "failed"`, `reason = "spawn_failed"`, `detail` = the port's `message` if it
  gave one, otherwise "The command could not be started." `duration_ms` may be nil.
- **F3 — the host has no subprocess capability.** Port returns `unsupported`. Result:
  `status = "unavailable"`, `reason = "no_shell"`. Distinct from F2 because the model
  should stop trying to shell out entirely rather than rephrase the command.
- **F4 — the command was killed by a signal, not a timeout.** Outcome has a `signal` and
  no `code`. Result: `status = "failed"`, `reason = "killed_by_signal"`, `signal` carried
  through, output kept.
- **F5 — the command produced more output than the host would buffer.** Outcome has
  `overflowed = true`. Result carries `overflowed = true`; the rendered header says so in
  place of the elided-bytes count, because in that case the true total is unknown. Not a
  failure on its own: an `exited` outcome with `overflowed` is still `ok = true`.
- **F6 — the output is enormous but did fit.** Not a failure. Truncated to the caps,
  `dropped` counts the bytes, the header names the true total. The context is bounded
  whatever the command does; that is the entire point of the caps.
- **F7 — the port raised instead of returning.** Caught by `pcall`. Result:
  `status = "failed"`, `reason = "port_error"`, `detail` = the message, coerced with
  `tostring` because a raise can carry any value. A broken port must not end the turn.
- **F8 — the port returned something malformed.** Not a table, or a `status` not in the
  four listed, or a field of the wrong type. Result: `status = "failed"`,
  `reason = "port_contract"`, detail naming the field. Missing optional fields are
  filled with their defaults rather than refused: `stdout` and `stderr` nil become `""`,
  a nil `duration_ms` stays nil. **(amended)** A field that is *present and of the wrong
  type* is refused rather than coerced, for all of `stdout`, `stderr`, `signal`,
  `message`, `duration_ms`, `overflowed` and `code`. Filling in a missing field is
  generosity; reinterpreting a wrong one is a guess.
- **F9 — the outcome says `exited` but has no `code`.** Treated as F8, because a result
  that claims a clean exit and cannot say with what is worse than an honest failure.
  **(amended)** F4 and F9 overlap and the order between them is now stated: an `exited`
  outcome with no `code` **and** a non-empty `signal` is F4, `killed_by_signal`; with no
  `code` and no signal it is F9, `port_contract`. A signal alongside a code is carried
  through on an ordinary `exited` result. Without this rule the two paragraphs describe
  the same outcome and disagree about what it means.
- **F10 — output that is not valid UTF-8**, or contains control bytes, or is a binary
  blob. Passed through byte for byte. This tool does not sanitize; it only refuses to cut
  a codepoint in half. Whoever hands the bytes to a model encodes them; that is not a
  decision this file gets to make on their behalf.

**What never happens.** The tool never retries. It never falls back to a different
command, never strips a flag, never rewrites a path, never writes to the real filesystem
to make a `cwd` exist. Every one of those is a silent divergence between what the model
asked for and what ran, and a coding agent that cannot trust the echo of its own command
is worse than one with no shell at all.

## 5. What it must NOT do

- **Must not touch the world directly.** No `os.execute`, `io.popen`, `io.open`,
  `os.remove`, `os.rename`, `os.getenv`, `os.time`, `os.clock`, `os.exit`, `require` of
  anything outside this module, `print`, or any write to `io.stdout`. Everything comes
  through `ctx`. Test 1 reads the source and proves it.
- **Must not ask for permission.** It never calls an approval port, never reads an
  approval decision, never checks whether it was approved. `ask = true` on the
  declaration means `turn.run` asks before the body is entered (rule 4). A tool that can
  approve itself is not gated.
- **Must not reach into another subsystem.** Not `src/turn.lua`, not `src/spec.lua`,
  not the session store, not the model client, not the filesystem tool. **(amended)** It
  calls `require` at all: the argument-type tables are written out literally, in the
  shape `spec.lua` builds, and a test proves the two agree by declaring the tool through
  `spec.add_tool`. If it needs something from the world it goes on the port contract in
  section 2, in the open.
- **Must not hold state.** No module-level table it writes to, no cache of the last
  command, no counter. Two `shell.run` calls, nested or sequential, share nothing.
- **Must not mutate what it is given.** `ctx`, `ctx.args` and the options table come back
  from a call byte-identical.
- **Must not re-quote, re-escape or otherwise edit the command.** The string the model
  wrote is the string in `request.command`. A harness that quietly quotes is a harness
  whose failures cannot be reproduced by hand.
- **Must not decide the meaning of an exit code.** It reports; it does not interpret.
- **Must not enforce the timeout itself.** It has no clock and no way to kill anything.
  It states the limit in the request and reports what came back.
- **Must not use anything outside the DESIGN.md dialect**: no integer division, no
  `goto`, no bitwise operators, no `<close>`, no `string.pack`. The UTF-8 continuation
  check is `b >= 128 and b < 192` for that reason.

## 6. The tests that would prove it

Adversarial ones are marked. They are the ones worth writing first: the happy path is
one branch and the refusals are nine.

1. `shell_names_no_vendor` — read `src/tools_shell.lua` as text and assert none of the
   forbidden identifiers in section 5 appears. The same discipline as
   `core_names_no_vendor`. **Adversarial**: also assert the file contains no `os.` and no
   `io.` at all, so a later well-meaning edit cannot slip one in.
2. `declaring_runs_nothing` — `shell.tool {}` with a `ctx` that would explode if touched;
   nothing is called. Rule 2.
3. `a_command_that_exits_zero` — fake port returns exited/0 with output; result is
   `ok = true`, `code = 0`, stdout carried verbatim, `text` contains it.
4. `a_failing_command_is_a_successful_call` — exited/1 gives `ok = true`, `code = 1`,
   `reason = nil`. **Adversarial**: this is the one everyone gets wrong.
5. `stderr_is_kept_separate` — a command writing to both streams; neither is merged into
   the other and both appear in `text` under their own header.
6. `no_output_renders_as_empty_not_missing` — exited/0 with `stdout = ""`; `text` says
   `--- stdout (empty) ---` and `result.stdout` is `""`, not nil.
7. `an_empty_command_is_refused` — `command = ""` and `command = "   "` both give
   `status = "refused"`, `reason = "empty_command"`, and **the port is never called**
   (the fake records its calls and the test asserts zero).
8. `a_missing_command_is_refused_not_raised` — `args = {}` gives `reason = "no_command"`.
   **Adversarial**: the model omitting a required argument must not raise.
9. `a_command_with_a_zero_byte_is_refused` — `"ls\0-la"` gives `command_has_nul`.
   **Adversarial**.
10. `a_command_over_the_length_cap_is_refused` — 8193 bytes; `command_too_long`, and the
    detail names both numbers.
11. `a_cwd_outside_the_root_is_refused` — fake `resolve` returns nil for `"../.."`;
    `cwd_escapes_root`, port never called. **Adversarial**: try `".."`, an absolute path,
    `"a/../../b"`, and a path whose *prefix* matches the root as a string but whose
    directory does not (`/w/space` against root `/w/spa`). That last one is the bug a
    lexical prefix check always has. **(amended)** The fake is a real segment-wise
    resolver rather than a stub, and the assertion is that the tool refuses whenever the
    resolver does and never second-guesses it — the prefix bug is one this tool avoids by
    not owning the decision, so what is tested here is that it asks and obeys.
12. `a_cwd_with_no_resolve_port_is_refused` — `ctx.resolve = nil` and a `cwd` argument
    gives `cwd_unsupported`; with no `cwd` argument the same ctx works fine and runs in
    `ctx.root`.
13. `a_bad_timeout_is_refused` — `timeout_ms` of `0`, `-1`, `1.5`, `"30s"`, and one above
    `timeout_max`; the last gives `timeout_too_long` and the rest `bad_timeout`. Assert
    it is **never clamped**: a silently shortened timeout is a lie the model cannot see.
14. `a_timeout_keeps_the_partial_output` — port returns timeout with 400 bytes of stdout;
    `status = "timeout"`, `ok = false`, `code = nil`, and those 400 bytes are in the
    result and in `text`. **Adversarial**: the tempting implementation throws them away.
15. `a_timeout_states_the_limit_it_hit` — the detail contains the milliseconds actually
    sent to the port, including when the default was used rather than an argument.
16. `spawn_failure_is_distinct_from_a_nonzero_exit` — `spawn_failed` gives `ok = false`,
    `reason = "spawn_failed"`, `code = nil`; asserts a caller can tell "the program does
    not exist" from "the program ran and failed".
17. `an_unsupported_host_says_so_once` — `unsupported` gives `status = "unavailable"`,
    and the detail tells the model to stop rather than rephrase.
18. `a_signal_kill_is_reported_as_one` — outcome with `signal = "SIGKILL"` and no code
    gives `killed_by_signal` with the signal in the result.
19. `a_port_that_raises_does_not_end_the_turn` — fake `exec` calls `error("boom")`;
    result is `status = "failed"`, `reason = "port_error"`, detail contains "boom".
    **Adversarial**: also raise a table rather than a string, and a nil, and assert
    `tostring` coercion rather than a second raise.
20. `a_malformed_outcome_is_a_failure_not_a_crash` — port returns `nil`, then `42`, then
    `{ status = "weird" }`, then `{ status = "exited" }` with no code, then
    `{ status = "exited", code = 0, stdout = 12 }`, `{ status = "exited", code = "0" }`
    and a `timeout` whose `duration_ms` is a string. Each gives `status = "failed"` with
    `reason = "port_contract"` and a detail naming the offending field, and none raises.
    **Adversarial**.
21. `output_is_truncated_to_the_cap` — 1 MiB of stdout with `stdout_cap = 1024`; retained
    bytes are at most 1024, `dropped` is the exact difference, and the header names the
    true total.
22. `truncation_keeps_the_head_and_the_tail` — output of numbered lines; both the first
    line and the last line survive and the marker sits between them. **Adversarial**: the
    error is almost always at the end and a head-only truncation hides it.
23. `truncation_never_splits_a_codepoint` — a stream of a multi-byte character sized so
    the cut lands mid-character, for a cut landing at each of the character's byte offsets
    in turn, and for two-, three- and four-byte characters. **(amended)** The assertion is
    that each retained piece is *whole* UTF-8 — no piece begins with a continuation byte,
    and no piece stops inside a sequence — checked by decoding it. The first draft asked
    that no byte in 128..191 end a piece, which is wrong: a valid multi-byte character
    ends in a continuation byte, so that assertion fails on correct output.
    **Adversarial**.
24. `truncation_is_exact_at_the_boundary` — `#s == cap`, `cap - 1`, `cap + 1`. The first
    two return the input and `0` dropped; the third truncates.
25. `overflow_is_reported_when_the_host_capped_first` — outcome with `overflowed = true`;
    result carries it and the header says the total is unknown rather than printing a
    wrong one.
26. `the_default_timeout_and_cwd_are_used_when_the_model_names_none` — assert the exact
    values reaching the port: `timeout_ms = 30000`, `cwd` = resolve of `"."`.
27. `options_reject_an_unknown_key` — `shell.options { timout_ms = 5 }` raises and the
    message names `timout_ms`. **Adversarial**: the typo is the realistic bug.
28. `options_are_idempotent_and_do_not_mutate` — normalize twice, compare; and assert the
    input table is unchanged, including that it did not gain defaults.
29. `run_raises_only_on_a_wiring_bug` — a ctx with no `exec`, a ctx that is a string, a
    nil `args`: each raises. Then every case in tests 7 through 20 asserts no raise. The
    pair is the error contract.
30. `nothing_is_mutated` — deep-compare `ctx`, `ctx.args` and the options table before and
    after a run.
31. `two_runs_share_nothing` — a fake `exec` that itself calls `shell.run` with a second
    ctx; both results are correct and independent. **Adversarial, recursion**: proves
    there is no module-level state and that a nested call cannot corrupt the outer one.
    Note that this tool does **not** bound recursion — an agent shelling out to itself is
    stopped by the step budget in `turn.run` (rule 5), not here, and this test documents
    that division rather than adding a second guard.
32. `a_refusal_renders_as_a_refusal` — `text` for each refusal contains `refused: <code>`
    and the result's own `detail` sentence, and no stream header at all, since no command
    ran. **(amended)** It is `detail` that is asserted, not the generic sentence in
    `shell.reasons`: several refusals name numbers or a path, and the specific sentence is
    the one the model acts on.
33. `every_reason_code_has_a_sentence` — iterate `shell.reasons`, assert each value is a
    non-empty string ending in a period, and assert every code produced anywhere in tests
    7 through 20 is a key of it. **Adversarial**: catches a reason code invented at a
    call site and never given English.
34. `the_result_shape_is_total` — for one example of each of the five statuses, assert
    every field named in section 3 is present with the stated type, and that `stdout`,
    `stderr`, `dropped`, `overflowed` and `text` are non-nil on all five.
35. `it_runs_under_both_interpreters` — the suite passes under `lua` and under `luajit`.
    Dialect, per DESIGN.md. **(amended)** In-process the test reads the source and fails
    on `//`, `goto`, `<close>`, `string.pack` and a bitwise operator, since a Lua file
    cannot run a second interpreter without touching the world; running the suite under
    both is the runner's job and was done.
36. `the_declaration_is_one_spec_accepts` **(added)** — hand `shell.tool {}` to
    `spec.add_tool` and read `spec.schema` back: one tool, `ask` true, three described
    arguments. This is what keeps the literal argument tables in step with `spec.lua`
    while this file names no sibling.
37. `the_standard_shell_port_can_drive_this_tool` **(added)** — drive the whole tool
    through `shell.exec_from_port` against an argv-shaped `sh` port: the argv is
    `{ "sh", "-c", command }`, the cwd reaching the port is workspace-relative, the
    timeout is in seconds, `unavailable` becomes `no_shell`, `not_found` becomes
    `spawn_failed`, a result with `timed_out` keeps its partial output, and a port that
    answers with a number still comes back as `port_contract`.
38. `truncation_keeps_output_that_is_not_utf8` **(added)** — a bare run of continuation
    bytes, valid text wrapped around one, and a longer run: each keeps at least `cap - 6`
    bytes and loses none of them off the ledger, and a four-byte character is still never
    cut. **Adversarial**: the unbounded walk this replaces kept zero bytes of the first
    case while every other test in this file passed.
39. `an_empty_stream_did_not_overflow` **(added)** — an overflowed outcome with an empty
    stderr renders `--- stderr (empty) ---`, not a total it cannot know.
40. `the_standard_port_cannot_invent_an_exit_code` **(added)** — an `sh` port answering
    `{ out = "x" }` with no `code` comes back `port_contract` and `ok = false`, and a
    `code = 0` the port really sent still comes back `ok = true`.
41. `a_broken_resolve_is_not_the_models_mistake` **(added)** — a `resolve` returning nil
    is `cwd_escapes_root`, one returning a table, a number or `true` is `port_contract`,
    and one that raises is `port_error`. The shell port is reached in none of the three.
