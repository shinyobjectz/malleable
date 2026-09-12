# cli — the runner

`src/cli.lua`, with a fifteen-line entry script at `bin/malleable.lua`. Contract, not
implementation.

## What it is for

The runner is the thing a person types: it reads a command line, loads an agent
declaration file in a sandbox that cannot touch anything, checks that the declaration
could actually run, wires the ports the host supplies, hands agent, prompt and ports to
`turn.run`, and renders what came back to a terminal. It owns argument parsing, the
exit code, the transcript rendering and one flag — `--dry-run` — that swaps the real
world for the doubles so a person can see what a declaration would do before it does
it. It is the only file in the tree that has an opinion about how a run looks to a
human, and it is deliberately the file with the least logic in it: everything it prints
came from somewhere else.

## Where it sits

    bin/malleable.lua     builds the real world (the only file here that touches io and os)
    src/cli.lua    everything below: pure, world-through-an-argument, no globals

`cli.lua` requires `spec`, `turn`, `session`, `approval`, `port` and `double`, and
nothing outside the tree. It touches no global except the ones the standard library
puts there, and it never calls `io`, `os`, `print`, `os.exit` or `math.random`. The
world arrives as an argument, which is what makes every behaviour in this document
testable with no network, no disk and no subprocess — including the ones about the
terminal, because a terminal is two functions.

## The command line

    pi [options] <declaration.lua> [prompt words ...]

The first non-option argument is the path to the declaration file. Everything after it
is joined with single spaces and becomes the prompt, unless `--prompt` was given.

| option | argument | default | meaning |
| --- | --- | --- | --- |
| `-p`, `--prompt` | text | none | the prompt. Refuses if positional prompt words were also given. |
| `--prompt-file` | path | none | read the prompt from a file through `world.read`. |
| `--stdin` | — | off | read the prompt from `world.stdin()`. |
| `--budget` | integer ≥ 1 | the declaration's | `opts.budget` for `turn.run`. |
| `--calls-per-step` | integer ≥ 1 | 8 | `opts.calls_per_step`. |
| `--max-depth` | integer ≥ 0 | 3 | `opts.max_depth`. |
| `--model` | id | the declaration's | overrides `agent.model` for this run only. |
| `--root` | path | `.` | the workspace root handed to `world.ports`. |
| `--timeout` | seconds > 0 | none | passed to `world.ports`; cli enforces nothing itself. |
| `--trust` | `trusted`,`ask`,`none` | `ask` | passed to `approval.new`. |
| `--allow` | tool name | none | repeatable; appended to the policy as an allow entry. |
| `--deny` | tool name | none | repeatable; appended ahead of every allow entry. |
| `-y`, `--yes` | — | off | answer every approval question yes without asking a human. |
| `--no` | — | off | answer every approval question no without asking a human. |
| `--dry-run` | — | off | use the doubles, never the host's ports. |
| `--reply` | text | none | repeatable; a scripted model reply for `--dry-run`. |
| `--script` | path | none | a Lua data file of scripted replies for `--dry-run`. |
| `--check` | — | off | load, validate, report, run nothing. |
| `--tools` | — | off | print the tool schema the model would be sent, run nothing. |
| `--say` | — | off | print the declaration said back as the Background that would declare it, and what no line says; run nothing (`docs/spec/say.md`). |
| `--conforms` | path | none | load that path too and report every line only one of the two says; exit 0 when they say the same agent, 3 when not (`docs/spec/say.md`). |
| `--session` | path | none | save the transcript as one session record when the run ends. |
| `--json` | — | off | print one JSON object on stdout; all human text goes to stderr. |
| `--show-lines` | integer ≥ 0 | 12 | lines of a tool result to render. `0` shows none. |
| `-q`, `--quiet` | — | off | print the final answer and nothing else. |
| `-v`, `--verbose` | — | off | repeatable; 1 adds arguments and notes, 2 adds every message. |
| `--width` | integer ≥ 20 | `world.width()` or 80 | wrap width. |
| `--no-colour` | — | — | never emit an escape sequence. `--colour` forces them on. |
| `--` | — | — | ends options; every later argument is a positional. |
| `-h`, `--help` | — | — | print usage on stdout, exit 0. |
| `--version` | — | — | print the version on stdout, exit 0. |

Parse rules, exactly:

* Short options do not bundle. `-qv` is an unknown option, not `-q -v`. Bundling saves
  two keystrokes and costs a class of misparse that only shows up under stress.
* `--budget=5` and `--budget 5` are the same. `--budget` with no value is a usage error
  naming the option; a value that starts with `-` is taken literally, so
  `--prompt -x` sets the prompt to `-x` rather than guessing.
* An unknown option is a usage error naming it verbatim. No suggestion is offered: a
  runner that guesses what you meant is a runner that eventually runs the wrong thing.
* An option given twice is last-wins, except `--allow`, `--deny`, `--reply` and
  `--verbose`, which accumulate in the order given.
* `--yes` and `--no` together, `--quiet` and `--verbose` together, `--prompt` with
  positional prompt words, `--reply` or `--script` without `--dry-run`: each is a usage
  error stating the pair.
* No declaration path at all is a usage error, and so is a second positional path when
  `--prompt` was given and the first was already taken as the declaration.
* The empty prompt is legal and is passed through to `turn.run` as `""`. No prompt
  option at all is also the empty string; the model is allowed to decide what an empty
  prompt means, exactly as `turn` says.

## Exit codes

    0  the run ended "answered"; or --help, --version, --tools, --check or a dry-run
       plan completed with nothing to report
    1  usage: the command line could not be read
    2  the declaration could not be loaded
    3  the declaration loaded but is not runnable
    4  the run ended "budget"
    5  the run ended "refused"
    6  the run ended "error"
    7  the world could not be wired

`cli.codes` is a frozen table mapping each name to its number and each of `turn.stops`
to the code it produces, so a caller can branch exhaustively and a test can prove the
mapping is total. Nothing here ever returns a code above 7: a shell reports a signalled
process as 128 plus the signal, and a runner that returned 130 for its own reasons
would make a real interrupt unreadable.

`--check` exits 3 when the declaration has problems and 0 when it does not, and so does
`--conforms` when the two declarations differ. `--json` does not change any exit code.

## The world it takes

`cli.main(argv, world)` reads exactly these fields of `world` and no others. Each is
checked at entry; a missing required field **raises**, because a host that wired the
runner wrong is a defect in the program, not something a user typed.

| field | shape | required | notes |
| --- | --- | --- | --- |
| `world.out(text)` | returns nothing | yes | stdout. Cannot fail; a closed pipe is the host's problem to swallow. |
| `world.err(text)` | returns nothing | yes | stderr. Everything human goes here under `--json`. |
| `world.read(path)` | `text` or `nil, reason` | yes | reads the declaration, `--script`, `--prompt-file`. `reason` is exactly `"missing"` for absence, as `session`'s store does, so the two cannot drift. |
| `world.ports(cfg)` | `p` or `nil, reason` | no | builds the real world. `cfg` is `{ root, model, timeout, trust, session }`. Absent means every real run exits 7. |
| `world.doubles(script, cfg)` | `p` | no | defaults to `double.world`. `script` is a `double.world` config carrying the scripted model; `cfg` is the same table `world.ports` gets, and `double.world` ignores it. Injectable so a test drives `--dry-run` with its own script. |
| `world.stdin()` | `text` or `nil, reason` | no | absent means `--stdin` is a usage error saying this host has no standard input. |
| `world.env(name)` | `string` or `nil` | no | read only for `NO_COLOR`. There is no environment override for anything else: the command line and the declaration are the whole input. |
| `world.width()` | number | no | terminal columns. |
| `world.colour` | boolean | no | whether the sink is a terminal. |
| `world.now()` | number | no | wall seconds. Absent means no timing line is printed — cli never invents a clock. |

`bin/malleable.lua` is the only place these are built from `io`, `os` and the environment. It
does nothing else: build the world, call `cli.main(arg, world)`, `os.exit(code, true)`.

## The public API

Everything below is pure with respect to the process: no state survives a call, two
runners in one process share nothing, and none of these functions ends the program.

### `cli.main(argv, world) -> code`

The whole runner. `argv` is a list of strings with no program name in it — `nil` reads
as an empty list, which prints usage on stderr and returns 1. Returns an integer from
the table above and **never returns nil, never raises for anything in `argv`, and never
calls `os.exit`**. It raises only for a malformed `world`, naming the field.

The sequence, in order, so a test can stop it anywhere: parse, then `--help` /
`--version`, then load, then validate, then `--tools` / `--check`, then wire, then
`turn.check`, then run, then render, then save, then return the code.

### `cli.parse(argv) -> opts | nil, problem`

Pure, touches nothing, and is the whole of the command line's meaning. `problem` is one
sentence naming the offending argument. `opts` is a table with every field above
resolved to its default and these three besides: `opts.path` (the declaration),
`opts.prompt_source` (`"words"`, `"option"`, `"file"`, `"stdin"` or `"none"`) and
`opts.argv` (a copy of what was parsed, for the record). Unknown keys never appear;
`opts` is a closed shape and `cli.run` refuses one carrying a key it does not know, on
the same reasoning `turn` refuses an unknown `opts` key.

### `cli.load(path, world, limits) -> agent | nil, err`

Loads a declaration file into a fresh agent table, inside the sandbox described below.
`limits` may be nil: `{ max_bytes = 262144, max_steps = 10000000 }`.

Returns the agent table `spec.new()` produced, filled in by the file. On failure
returns `nil, err`, where `err` is
`{ code = string, message = string, line = number | nil }`. The codes are closed:

| code | means |
| --- | --- |
| `missing` | `world.read` said `"missing"` |
| `unreadable` | `world.read` failed some other way; its reason is quoted |
| `empty` | the file is zero bytes, or is only whitespace and comments |
| `too_big` | over `limits.max_bytes` |
| `binary` | the first byte is `0x1b` (precompiled chunk) or the text holds a zero byte |
| `syntax` | `load` refused it; `line` is set and the message is Lua's, unedited |
| `blocked` | the file read a global the sandbox does not provide; the name is in the message |
| `raised` | the file ran and called `error`; `line` is set where Lua gave one |
| `too_long` | the chunk ran past `limits.max_steps` VM instructions |
| *(there is no `no_hook`)* | there is no `--limit-steps`; where `debug.sethook` is unavailable `cli.load` succeeds and returns the one-line warning described below |

`load` never raises for anything a file can contain. A file is data.

### `cli.sandbox(cfg) -> env, a, wrote`

Builds the environment a declaration runs in, and the fresh agent table it writes into.
Exposed separately because the sandbox is the security boundary of the whole runner and
a boundary you cannot construct in a test is a boundary nobody checks.

`env` contains exactly:

* `agent` — the public prefix, bound to `a`. `agent.name`, `agent.model`,
  `agent.system`, `agent.budget`, `agent.reasoning`, `agent.tool`, `agent.on`, `agent.trust`,
  `agent.allow`, `agent.deny`, and the argument types `agent.string`,
  `agent.string_opt`, `agent.number`, `agent.number_opt`, `agent.boolean`,
  `agent.boolean_opt`, `agent.table`, `agent.table_opt`, `agent.list`,
  `agent.list_opt`. Each setter forwards to the `spec` function of the same meaning and
  returns nothing, so a declaration reads as statements. `agent` is read-only:
  assigning to `agent`, or to any field of it, raises from the sandbox with the name.
* `assert`, `error`, `ipairs`, `pairs`, `next`, `select`, `tonumber`, `tostring`,
  `type`, `unpack` (`table.unpack` under 5.4, aliased so one file loads under both),
  `pcall`, `xpcall`, and the `math`, `string` and `table` tables as the interpreter
  supplies them.
* `print`, rebound to write one line to `world.err`, prefixed with the file name. A
  declaration that narrates itself must not be able to corrupt `--json` on stdout.
* `_G`, pointing at `env` itself.

It contains no `os`, no `io`, no `require`, no `dofile`, `loadfile`, `load`,
`loadstring`, `rawset`, `rawget`, `setmetatable`, `getmetatable`, `collectgarbage`,
`coroutine` or `debug`. Rule 2 says a declaration cannot run anything; this is the
mechanical half of it. A tool body still closes over nothing but `env`, so a body that
wants the world uses the context it is handed at call time — which is the point.

**Reading an undefined global raises**, at the line that did it, with the name:
`unknown name "reqire" — the declaration surface is agent.*`. A silent nil is how a
misspelt `agent.toool` becomes a declaration with no tools and a confusing run three
minutes later. **Writing a new global is allowed** and lands in `env`, where it dies
when the load returns; the name is recorded and reported under `--verbose`, because a
declaration that thinks it is keeping state across a run is a declaration with a bug.

### `cli.problems(agent, opts) -> { string, ... }`

`spec.problems(agent)` plus what the runner itself requires: a `--model` override that
is not a string, a tool named in `--allow` or `--deny` that the declaration does not
declare (a policy on a tool that does not exist is a typo, and it is the kind of typo
that reads as safety while providing none), and an agent whose `budget` and the
`--budget` override disagree in a way worth naming. Returns an empty list when a run
would start. Never raises.

### `cli.wire(opts, world, agent) -> p, gate, warnings, asked | nil, reason`

The one place that turns options into a world. For a real run it calls
`world.ports(cfg)`, then `port.check(p)`, and returns `nil, reason` when either fails,
listing every missing port in one sentence rather than one at a time. For `--dry-run`
it calls `world.doubles(script, cfg)` and never touches `world.ports`, even if it is there.

It also builds the approval gate: `approval.new { port = p, trust = …,
policy = … }`, where the policy is the declaration's entries followed by the command
line's `--deny` entries followed by its `--allow` entries — denies first, because
`approval` resolves denies before allows and the file must read the way it runs. With
`--yes` the gate is built with a port that answers `"yes"` to everything and with
`--no` one that answers `"no"`; **neither replaces the deny policies**, which still
fire first, and neither is available under `--dry-run` unless asked for, so a dry run
shows the questions it would have asked.

When no approval port exists, no `--yes` and no `--no` were given, and some declared
tool sets `ask = true`, the run still starts and every ask refuses. The header says so
in one line before the first model call: `approvals: no one to ask — every ask will
refuse`. Refusing to start would be defensible; starting silently would not.

### `cli.bind(p, gate, opts) -> tport, notes`

The adapter between the port table `spec/port.md` describes and the two functions
`spec/turn.md` requires. `spec/port.md` gives a model port as `p.model.call(request)`
returning `reply | nil, err` with `err` a table; `spec/turn.md` wants `port.model` to
be a function returning `reply | nil, message` with a string. `cli.bind` returns a new
table that has `model` as a function calling `p.model.call` and stringifying the error
as `code .. ": " .. message`, `ask` as a function calling `gate:check` and mapping its
decision, and every other key of `p` copied across untouched so a tool body still sees
`c.fs` and `c.sh`. It mutates neither `p` nor `gate`.

This is the only file in the tree that knows both shapes, and it exists so the mismatch
lives in one named function with its own tests instead of being smeared across the
harness. If the two documents are reconciled, `cli.bind` becomes a copy and nothing
else in the tree moves.

The approval mapping, exhaustively:

| what the gate answered | what `turn` is told |
| --- | --- |
| `allowed = true` | `"allow"` |
| `allowed = false` | `"deny"`, with `decision.reason` as `why` |
| the operator's answer carried `answer = "stop"` | `"stop"`, with the words as `why` |
| the gate raised (it is documented not to) | `"deny"`, and a note |

There is no path from any answer, any port failure or any missing port to `"allow"`
that a human did not take. That sentence is the security property of the runner and
test 24 is its test.

### `cli.run(opts, world) -> code, result | nil, reason`

Everything after parsing: load, validate, wire, `turn.check`, `turn.run`, render, save.
Returns the exit code and the `turn` result. Returns `nil, reason` only when the run
never started — a bad declaration, an unwireable world — in which case `cli.main` has
already been told which code to use by the reason's own code field.

### `cli.render(result, opts, info) -> string`

Pure. Takes a `turn` result and returns the text a run prints, with no escape sequences
in it at all; colour is applied by `cli.paint(text, on)` afterwards, so every test
asserts against the uncoloured string and colour cannot change what a run says. Never
raises, for any result, including one hand-built with fields of the wrong type — a
renderer that raises turns a failed run into no output at all, which is the worst
possible moment to have nothing to read.

Shape, ASCII only, one blank line between steps:

    pi  reviewer  openrouter:z-ai/glm-5.3  budget 8  root .
    approvals: ask

    > review src/turn.lua

    . I will read it first.
    -> read { path = "src/turn.lua" }
       -- 4210 bytes
       local spec = require "spec"
       …
       (7 more lines)

    x write { path = ".git/config" }
       refused: refused by policy 1: the repository's own state is not the agent's to edit

    = The loop terminates on the budget and on malformed replies both.

    answered in 3 steps of 8, 2 calls, 1 refused, 4.1s

Prefixes are fixed and are part of the contract: `>` a user message, `.` model
narration, `->` a call that ran, `x` a call that did not, `!` an error, `=` the final
answer, three spaces for anything a call produced. `--quiet` prints the final answer
alone with no prefix and no summary. `--verbose` adds each call's full arguments and
the result's `notes`; twice adds every transcript message including the system prompt.

Three rules the renderer holds and has tests for:

1. **Nothing a model or a tool produced can move the cursor.** Every byte below `0x20`
   other than tab and newline, and every `0x7f`, is written as `\xNN` before it reaches
   `world.out`. A tool result carrying `\27[2J` clears no screen.
2. **Nothing it prints is unbounded.** A tool result is cut to `--show-lines` lines and
   4096 bytes, whichever comes first, and the cut is stated exactly:
   `(7 more lines)` or `(… 918233 bytes elided)`. Arguments render with keys sorted,
   each value capped at 120 bytes, tables to depth 2 with `{…}` beyond, and a table
   that contains itself renders as `{…}` at the point it repeats — the renderer holds a
   seen-set and never recurses on identity.
3. **The same result renders to the same bytes.** No clock is read except
   `world.now()`, and when the host has none the timing clause is absent rather than
   zero. No table is iterated with `pairs` into output without sorting the keys first.

### `cli.plan(agent, opts, p, gate) -> plan` and `cli.render_plan(plan, opts) -> string`

`--dry-run` with no `--reply` and no `--script` runs no model at all and prints the
plan: the resolved options, the agent's name, model and budget, every tool with its
`about` and its arguments as the model would be sent them, what the gate would answer
for each tool with empty arguments and where that answer comes from, which ports are
wired and which are the doubles, and the first request that would have been sent —
model id, whether there is a system prompt, the message count, the tool names. It
returns 0. `plan` is a plain table so a test asserts on it without parsing text.

`--dry-run` **with** a script runs the loop for real against `double.world`, renders it
exactly as a live run, and marks every line of the header with `DRY`. The word appears
in the header, in the summary and in the `--json` output as `dry = true`; there is no
mode in which a person can read the output of a dry run and think a file was written.

### `cli.usage() -> string`, `cli.version -> string`, `cli.codes -> table`

Pure, constant, and `codes` is frozen: `cli.codes.answered == 0` and so on, plus
`cli.codes.of(stop)` returning the code for one of `turn.stops`.

## `--json`

One object, on stdout, encoded with `session.encode` — the tree's own encoder, so there
is exactly one JSON implementation here and its edge cases are already tested:

    { agent, model, dry, stop, reason, answer, steps, budget, calls, notes,
      transcript, err, session, code }

`calls` is `result.calls` with each `value` dropped (a raw Lua value is not JSON and
guessing at one is how a machine-readable mode starts lying); `output` stays whole and
untruncated. When the encode fails — a tool put something unencodable into the
transcript — stdout gets `{"stop":"error","reason":"…","code":6}` and the reason names
what would not encode. Under `--json` every human line, including the header, the
progress and any warning, goes to `world.err`, so a caller can pipe stdout into a
parser with nothing else in it.

## Failure modes

Each row is what the person sees, on which stream, and the code that comes back.

**No arguments at all.** Usage on stderr, code 1. An empty `argv` is not an error to
raise; it is the commonest thing a new user types.

**The declaration file is missing.** `pi: cannot read agents/review.lua: no such file`
on stderr, code 2. The path is quoted exactly as typed, never resolved to an absolute
one, so the sentence matches what the person wrote.

**The declaration is a directory, a socket, or unreadable.** `unreadable`, quoting the
host's own reason behind a `read:` prefix, code 2. Distinct from missing, always.

**The declaration is precompiled bytecode.** Refused as `binary` before `load` is
called, code 2. Lua's bytecode loader is not a sandbox in 5.1 and is a memory-safety
hazard in 5.4; the runner loads text and only text.

**The declaration has a syntax error.** Lua's own message, unedited, with the file and
line, code 2. The runner does not reformat a compiler's message; a person who knows
Lua's phrasing should recognise it.

**The declaration reads a global that is not there.** `blocked`, naming the global and
the line: `agents/review.lua:4: unknown name "os" — the declaration surface is agent.*`.
Code 2. This is what a file trying to open a socket at load time hits, and it hits it
before anything happens.

**The declaration raises.** `raised`, with the message and line, code 2. A file that
calls `error "no key set"` deliberately gets its own words shown, not a wrapper around
them.

**The declaration loops forever at load time.** With `debug.sethook` available, the
chunk is run inside a coroutine with an instruction-count hook and stops at
`limits.max_steps` with `too_long`, code 2. Where the interpreter has no `debug`
library, the runner says so once, in one line on stderr, and the load can hang — this
is a stated limit, exactly as `turn` states that it cannot stop a tool body. A limit
that is announced is not a lie; a limit that is assumed is.

**The declaration declares nothing.** `spec.problems` returns `no agent.name`,
`no agent.model`, `no tools: …`; each is one line on stderr under
`pi: agents/review.lua cannot run:`, code 3. Nothing is wired and no model is called.

**A tool asks and no gate can be built.** Not a failure: the run starts, the header
says every ask will refuse, and the refusals arrive as tool results the model reads.
Code follows the run.

**The host has no ports and this is not a dry run.** `pi: no ports wired — this build
can only --dry-run`, code 7. It is reported after the declaration has been loaded and
validated, not before, so a broken declaration is still the first thing a person is
told about: one failure at a time, in the order they would fix them.

**A required port is missing.** `port.check`'s problems, one sentence listing all of
them, code 7. The runner never substitutes a double for a missing real port. A run
that half-happened against a fake filesystem is the single worst outcome available to
this program, and `--dry-run` is the only door to the doubles.

**The prompt cannot be read.** `--prompt-file` missing, or `--stdin` on a host with no
standard input: code 1, because it is the command line that was wrong.

**The prompt is empty.** Not a failure. Sent as `""`.

**The model fails.** `turn` returns `stop = "error"`, `err.where = "model"`. The
runner prints `! model: timeout after 30s` and the transcript up to that point, and
returns 6. It does not retry: retry belongs to the port, which is the only layer that
knows what a retry costs.

**The run spends its budget.** The full transcript, a summary saying
`budget spent: 8 steps of 8, no answer`, and code 4. This is not an error message and
is not printed as one — the harness worked, and a script that treats 4 as a crash is
reading the code table.

**A person refuses a call.** The refusal renders as an `x` line with the reason, the
run continues, and the exit code is whatever the run finally does. A refusal is not a
failure of the runner.

**A person stops the run.** `stop = "refused"`, the transcript renders whole including
the calls that never ran, and the code is 5.

**A call times out.** The runner has no clock and no timeout of its own; `--timeout`
goes to the port and comes back as a model or tool failure with the port's own words,
rendered like any other. The runner never claims a timeout it did not observe.

**A tool result is enormous, or is binary.** Truncated to the cap with the elision
stated, control bytes escaped, and the whole of it still present in `--session` and
`--json`. The terminal sees a summary; the record keeps everything.

**A tool result tries to repaint the terminal.** Escaped. Test 22.

**The declaration recurses.** A tool body that calls `turn.run` again is bounded by
`max_depth`, which the runner passes through and prints in the header when it is not
the default. A declaration file that tries to load another declaration file cannot: the
sandbox has no `dofile`, no `loadfile` and no `require`.

**Rendering fails.** It cannot; `cli.render` is total. If a result is so malformed that
a field is missing, the renderer prints what it has and one `!` line naming the field it
could not read, and the exit code still comes from `result.stop` when that is one of the
four strings and 6 when it is not.

**The session cannot be saved.** One warning on stderr quoting `session.save`'s reason,
`saved = false` in `--json`, and **the exit code does not change**. The run happened;
the answer is already on the screen; turning an answered run into a failure because a
log file would not write would be the runner lying about the run.

**The output stream is closed** — the person piped into `head`. `world.out` swallows
it. Nothing in `cli.lua` checks a write for failure, because there is nothing useful it
could do about one.

## What it must NOT do

* **It must not run the loop.** No stepping, no dispatch, no transcript building, no
  budget arithmetic. `turn.run` is called once. If the runner ever needs to know what a
  step is, that is a sign a feature belongs in `turn`.
* **It must not reach into another subsystem's internals.** `spec.new`, `spec.schema`,
  `spec.problems` and the documented setters; `turn.run`, `turn.check`, `turn.stops`;
  `session`'s public functions; `approval.new` and `gate:check`; `port.check` and
  `port.error`; `double.world`. Nothing else, and no field of an agent, a result or a
  gate that its own document does not name.
* **It must not touch the world.** No `io`, no `os`, no `print`, no `os.exit`, no
  `math.random`, no `os.time`, no `os.getenv`, no socket. Everything through `world`.
  The same test that guards rule 1 for `turn.lua` reads `src/cli.lua` for these names.
* **It must not substitute doubles for a real port.** Ever, for any reason, with any
  flag except `--dry-run`, and never partially.
* **It must not decide permission.** It builds a gate and reports what the gate said.
  It has no allow-list of its own, no "safe tool" list, and it never infers approval
  from a tool's name.
* **It must not read the model's words to decide anything.** No parsing an answer for a
  status, no scanning a tool result for the word "error", no exit code drawn from
  anything but `result.stop`. The model's text is rendered; it is never interpreted.
* **It must not invent a resume.** `turn.run` takes a prompt, not a transcript, so
  `--session` writes and nothing reads it back. When `turn` grows a way to resume, this
  file changes before `src/cli.lua` does.
* **It must not persist anything else.** No config file, no history file, no cache, no
  dotfile in the workspace. The command line and the declaration are the whole input.
* **It must not stream.** `port.model` returns a whole reply; a runner that pretended
  to stream would be printing its own guesses about a reply it already has.
* **It must not colour by default when the sink is not a terminal**, and must not
  colour at all when `world.env("NO_COLOR")` is set or `--no-colour` is given. Colour
  never carries meaning that the text does not also carry.
* **It must not raise for anything a user can type.** A file, a flag, a prompt, a
  hostile declaration: all of them are data. It raises only for a malformed `world`,
  which is a host bug.

## The tests that would prove it

All of them run with `world` as a table of closures: `out` and `err` append to lists,
`read` indexes a table of strings, `ports` is `nil` or a `double.world`, and there is no
clock unless the test supplies one. No network, no disk, no subprocess anywhere.
Adversarial ones are marked.

1. `a_plain_run_answers_and_returns_zero` — a one-reply script, an agent with one tool:
   stdout holds the answer, the summary names one step, the code is 0.
2. `the_parse_of_a_full_command_line_is_exact` — every option above, given once, lands
   in the documented field of `opts` with the documented type.
3. `an_option_and_its_value_may_be_joined_or_split` — `--budget=5` and `--budget 5`
   parse identically, and `--prompt -x` gives the prompt `-x`.
4. `positional_words_become_the_prompt` — three trailing words join with single spaces;
   `--` before them keeps a word starting with a dash.
5. `help_and_version_print_and_stop` — code 0, nothing wired, `world.ports` never
   called, and usage names every option in the table above.
6. `check_validates_without_running` — `--check` on a good file returns 0 and the
   model double records no call; on a file with no tools it returns 3 and prints the
   three problems.
7. `tools_prints_the_schema_the_model_would_see` — the output lists exactly what
   `spec.schema` returned, in declaration order, with the `ask` flag visible.
8. `the_exit_code_matches_the_stop` — four runs, one per member of `turn.stops`,
   producing 0, 4, 5 and 6, and `cli.codes.of` agrees with each.
9. `a_dry_run_with_no_script_calls_no_model` — the plan prints, the doubles' `seen`
   list is empty, the code is 0, and the word DRY is in the output.
10. `a_dry_run_with_a_script_renders_like_a_live_run` — same renderer, same prefixes,
    plus DRY in the header, the summary and the JSON.
11. `json_is_one_object_and_nothing_else` — stdout decodes with `session.decode` in one
    call with no trailing bytes, every documented field is present, and every human
    line went to stderr.
12. `a_missing_declaration_is_two_not_one` **(adversarial, missing file)** — `read`
    answers `nil, "missing"`; the code is 2, the message quotes the path as typed, and
    a permission failure from `read` gives a different sentence with the same code.
13. `an_empty_argv_prints_usage_and_returns_one` **(adversarial, empty input)** — and
    so does `argv = nil`, without raising.
14. `an_empty_prompt_runs` **(adversarial, empty input)** — a declaration and no prompt
    at all sends `""` to `turn.run` and behaves normally; the empty string is visible in
    the recorded request.
15. `an_unknown_option_is_named_not_guessed` — `--budgets 3` returns 1 and the message
    contains `--budgets` and no suggestion.
16. `contradictory_options_are_refused_in_pairs` — `-y --no`, `-q -v`,
    `-p x with words`, `--reply x` without `--dry-run`: each returns 1 with both names
    in the sentence.
17. `bad_numbers_are_refused_before_anything_loads` — `--budget 0`, `--budget abc`,
    `--budget -1`, `--show-lines -1`: code 1, and `world.read` was never called.
18. `a_bytecode_file_is_refused_unloaded` **(adversarial)** — a string beginning with
    `\27Lua` returns `binary` and `load` was never reached, proven by a declaration that
    would have set a flag.
19. `the_sandbox_has_no_world` **(adversarial)** — a declaration whose body is
    `os.execute("touch /tmp/x")` returns `blocked` naming `os`; the same for `io`,
    `require`, `dofile`, `loadstring`, `load` and `debug`, one case each.
20. `a_misspelt_name_is_caught_at_load` **(adversarial)** — `agnet.name "x"` returns
    `blocked` naming `agnet` and the line, rather than a declaration with no name.
21. `the_prefix_cannot_be_replaced` **(adversarial)** — `agent = {}` and
    `agent.tool = print` both raise out of the sandbox as `blocked`, and the agent table
    is unchanged.
22. `a_declaration_that_never_returns_is_stopped` **(adversarial, recursion/hang)** —
    `while true do end` returns `too_long` in bounded time where `debug.sethook` exists,
    and on an interpreter without `debug` the runner has printed its one-line warning
    about the limit. Run under both interpreters on PATH.
23. `a_tool_result_cannot_repaint_the_terminal` **(adversarial)** — a body returning
    `"\27[2J\27[H"` and `"\r\rgone"` renders as `\x1b[2J…` with no raw escape byte
    anywhere in what reached `world.out`.
24. `nothing_turns_a_missing_gate_into_an_allow` **(adversarial, refusal)** — a tool
    with `ask = true`, no approval port, no `--yes`: `cli.bind`'s ask returns `"deny"`,
    the body's counter stays at zero, the tool message carries `refused = true`, the run
    still ends `answered`, and the header warned first. Then the same with a port that
    raises, one that returns `nil`, and one that returns `"maybe"`: all deny, none
    allow, each leaves a note. This is the runner's security test.
25. `deny_policies_survive_yes` **(adversarial, refusal)** — `--yes` with
    `--deny write`: the write is refused by policy, the read is allowed without asking,
    and the gate's `asked` count is zero for both.
26. `a_stop_ends_the_run_and_shows_what_did_not_happen` — a port answering stop on the
    first of three calls: code 5, all three calls rendered, two of them with `x`.
27. `a_model_failure_is_six_with_the_ports_words` — the double scripted with
    `{ code = "timeout", message = "…" }`: code 6, the message quotes the port, the
    partial transcript is still printed.
28. `a_timeout_needs_no_clock` **(adversarial, timeout)** — the same, plus a shell
    double returning `timed_out = true`, both rendered, the whole test running in
    milliseconds and asserting `world.now` was never required.
29. `the_budget_is_not_an_error` — a repeating script with `--budget 3`: code 4, the
    summary says budget, stderr holds no `!` line, and the transcript shows all three
    steps.
30. `no_double_ever_reaches_a_real_run` **(adversarial)** — a world whose `ports`
    returns `nil, "no api key"` and whose `doubles` sets a flag: the code is 7, the flag
    is false, and the message names the missing port. Repeated with a `ports` that
    returns a table missing `fs`: `port.check`'s problems, code 7, flag still false.
31. `two_runs_render_identically` **(adversarial)** — the same declaration, script and
    argv twice in one process: byte-identical stdout, including call ids and the order
    of every rendered argument table. Catches an accidental `pairs` in the renderer.
32. `a_cyclic_value_renders_and_returns` **(adversarial, recursion)** — a tool body
    returning a table containing itself, and one nested forty deep: the renderer
    produces bounded output and returns, and `--json` reports the encode failure rather
    than hanging.
33. `a_huge_result_is_cut_and_says_so` — a megabyte of output with `--show-lines 5`:
    five lines plus one elision line naming the byte count, the whole megabyte present
    in the session record, and the rendered text under a few kilobytes.
34. `the_renderer_never_raises` **(adversarial)** — hand-built results with `stop` of a
    fifth string, a nil `reason`, a `calls` list holding a number, and a transcript of
    booleans: each renders something and returns, and the code is 6 for the unknown
    stop.
35. `a_save_failure_does_not_change_the_code` — a store whose `write` fails: the answer
    is on stdout, the warning on stderr, the code is 0, and `--json` says
    `saved = false`.
36. `the_runner_touches_nothing_real` **(adversarial)** — read `src/cli.lua` as text and
    fail on `io.`, `os.`, `print(`, `os.exit`, `math.random`, `socket`, or a `require`
    of anything outside the tree. The companion assertion is that `bin/malleable.lua` is under
    twenty lines and contains no logic but the wiring.
37. `main_never_exits_the_process` **(adversarial)** — every case in this list is called
    through `cli.main` inside one process, in sequence; the test file itself reaching its
    last line is the assertion.

---

## Corrections, made while building it

Everything below supersedes the text above where the two disagree. Each one is a
place the specification was wrong or silent, found by writing `src/cli.lua` and
`test/cli_test.lua` against it. A spec that disagrees with the code is worse than no
spec, so the disagreements are named rather than smoothed over.

### Signatures

* **`cli.render(result, opts, info)`.** The header names the agent, the model, the
  root and the approval mode, and a `turn` result carries none of those. `info` is a
  plain table — `{ agent, model, root, budget, approvals, dry, max_depth, width,
  warnings, notes, elapsed }` — and every field is optional, because the renderer is
  total. Keeping the extras out of `opts` is what lets `opts` stay a closed shape.
* **`cli.wire(opts, world, agent)`** returns `p, gate, warnings, asked`. It needs the
  agent because the policy it compiles starts with the declaration's own entries, and
  because the declaration's `agent.trust` applies when `--trust` was not given.
  `warnings` is the list of lines the header carries and `cli.run` prints on stderr
  before the first model call; `asked` is the list of tool names `--yes` or `--no`
  answered without a human, and is empty for every other run.
* **`cli.plan(agent, opts, p, gate)`.** The plan states what the gate would answer,
  so it needs the gate.
* **`cli.sandbox(cfg) -> env, a, wrote`,** with `cfg = { say = function (line), file =
  string }`. `limits` never belonged here: it is `cli.load` that counts bytes and
  steps. `say` receives the lines a declaration's `print` produced and `file` is the
  name they are prefixed with; both are optional. `wrote` is the list of global names
  the declaration created, reported under `--verbose`.
* **`cli.paint(text, on)`,** with `on` a boolean, plus **`cli.colour_on(opts, world)`**
  which resolves it: `--no-colour` and `NO_COLOR` beat everything, then `--colour`,
  then `world.colour`.
* **`cli.load(path, world, limits)` returns `agent, warning` on success.** The warning
  is `nil` on an interpreter that has `debug.sethook`, and one sentence saying the
  load cannot be bounded on one that does not. `cli.run` prints it on stderr. There is
  no `--limit-steps` option and so no `no_hook` code: the closed set is `missing`,
  `unreadable`, `empty`, `too_big`, `binary`, `syntax`, `blocked`, `raised`,
  `too_long`.
* **`opts.trust` is `nil` when `--trust` was not given,** not `"ask"`. It resolves at
  wire time to the declaration's `agent.trust`, and to `"ask"` when there is none.
  Defaulting it in the parser would have made a declaration's own trust unreachable.

### `cli.bind`

* **It stamps `ask = true` on every request it forwards to the gate.** `turn` asks
  only for tools that declared `ask`, and `approval`'s ordinary path allows a tool
  that did not ask. Without the stamp, every asking tool would be allowed on the flag
  rule and no human would ever see a question. This is the single most load-bearing
  line in the file, and it is exactly the kind of fact that only exists between two
  documents, which is why `cli.bind` exists.
* **It answers in `spec/port.md`'s table form, not `spec/turn.md`'s strings.**
  `turn.read_decision` reads both, but the string form has nowhere to put a reason,
  and the reason is what the model reads when a call is refused. The mapping is:

  | what the gate answered | what `turn` is told |
  | --- | --- |
  | `allowed = true` | `{ allow = true, why = decision.reason }` |
  | `allowed = false` | `{ allow = false, why = decision.reason }`, and a note |
  | `decision.stop == true` | `{ stop = true, why = decision.reason }`, and a note |
  | the gate raised | `{ allow = false, why = "the approval gate failed" }`, and a note |

  Nothing but `allowed == true` produces an allow. That is still the security
  property, and `nothing_turns_a_missing_gate_into_an_allow` is still its test.
* **The approval port is `p`, not `p.approval`.** `spec/port.md`'s six ports name it
  `p.ask` with `request(q)`, and `approval.new`'s `ask_of` accepts a whole port table.
  There is no `p.approval` anywhere in the tree.
* **`stop` is unreachable from the command line today.** `approval`'s `read_answer`
  knows `yes`, `no`, `always` and `never`, and has no stop channel, so no flag and no
  operator answer can end a run with `stop = "refused"` through `cli.main`. `cli.bind`
  maps a stopping decision the moment a gate produces one, and its test drives that
  path with a gate double. When `approval` grows a stop, nothing here changes.

### The renderer

* **ASCII means ASCII.** The elision reads `(... 918233 bytes elided)` and a table cut
  off by depth or by identity reads `{...}`. The examples above used `…` and an em
  dash, which contradicted the rule three lines below them.
* **A tool result renders verbatim under its call line, indented three spaces.** There
  is no added `refused:` prefix: the `x` already says the call did not run, and the
  text `turn` produced already says why. Adding a second prefix would have read
  `refused: the call was refused: …`.
* **`->` and `x` are decided by `refused`, and by nothing else.** A tool that ran and
  failed gets `->`, because it ran. Deciding otherwise would mean reading the result
  text, which this file may not do.
* **There is no `-- 4210 bytes` line on an untruncated result.** The byte count appears
  only in the elision, where it is load-bearing.
* **The summary reads** `answered in 3 steps of 8, 2 calls, 1 refused, 4.1s`,
  `budget spent: 8 steps of 8, no answer`, `refused after …`, `error after …`, and
  `ended after …` for a stop that is none of the four. The timing clause is absent
  when the host has no clock, `, DRY` is appended on a dry run, and `steps`/`calls`
  are singular at one.
* **Under `--quiet` the answer is the whole of stdout** — no `!` line, no summary. An
  error is reported by the exit code alone.

### `--json`

* **A cycle cannot reach the encoder.** `calls` drops each entry's `value`, which is
  the only place a raw Lua value from a tool body ever lands; the transcript holds
  strings and the model's own decoded arguments. So the fallback object is a guard
  against an encoder failure this shape cannot currently produce, rather than
  something a hostile tool can trigger. Test 32 asserts the encode succeeds.
* **The fallback object carries the run's own code,** not a hard `6`:
  `{"stop":"error","reason":"…","code":<the run's code>}`. Printing `6` while the
  process exits `0` would have made the object and the exit status disagree, which is
  the one thing a machine-readable mode must never do.
* **`saved` is a field of the object**, `true` or `false`, alongside `session`.

### The order of a run

Prompt resolution sits between validate and wire: `--prompt-file` and `--stdin` are
usage errors (code 1), and a usage error should beat a wiring error, but reading a
prompt needs the world and so cannot happen in `cli.parse`. The full order is parse,
help/version, load, validate, `--tools`/`--check`, prompt, wire, `turn.check`, run,
render, save, return.

When several prompt sources are given, precedence is `--prompt`, then `--prompt-file`,
then `--stdin`, then positional words. Only `--prompt` with positional words is an
error; the rest simply order.

### `cli.problems`

The budget clause is gone. A `--budget` override cannot disagree with the declaration
in a way this file can judge — a value below 1 is already a parse error, and anything
else is the operator deciding — so the override simply wins and `turn` validates it.
What remains is `spec.problems`, a non-string `--model`, and an `--allow` or `--deny`
naming a tool the declaration does not declare.

### The sandbox

* **`agent.trust`, `agent.allow` and `agent.deny` write `a.trust` and `a.policy`,**
  two fields `spec.new` does not create and `spec.lua` knows nothing about. `cli`
  owns them until `spec.lua` grows setters of its own, at which point `cli.sandbox`
  should forward to them like every other member of the surface.
* **A number needs its parentheses.** `agent.budget 4` is not Lua — only a string or a
  table constructor may be a bare call argument — so a declaration writes
  `agent.budget(4)`. The prose form works for `agent.name "x"` and
  `agent.tool "read" { … }` and stops there.
* **A compiling interpreter must be held off the chunk.** Under LuaJIT a count hook is
  checked only in the interpreter, so `while true do end` compiles into a trace and is
  never counted. `cli.load` calls `jit.off(chunk, true)` around the load and
  `jit.on(chunk, true)` after it, when a `jit` table is present. Without this the
  `too_long` limit silently does not exist on one of the two interpreters the tree
  targets, which is precisely the assumed limit this document says is a lie.

### `cli.codes`

Frozen, and `__pairs` is not a metamethod in 5.4 or in 5.1, so walking the table is
not portable. `cli.code_names` is the list, in order, for a caller that wants to
branch exhaustively. `cli.codes.of(stop)` returns `nil` for a string that is not one
of `turn.stops`, and `cli.run` treats that as 6.

### `cli.main`

It wraps everything after the world check in a `pcall` and returns 6 with one
`internal fault` line on stderr if anything under it raises. The promise is that it
never raises for anything in `argv`; the guard is what makes that true even for a
defect in this file.

### Corrections, made while verifying it

Found by reading `src/cli.lua` against this document rather than by writing it, so
each one is a place the code and the contract had already drifted.

* **A tool that does not declare `ask` never reaches the gate at all.** `turn`
  consults `port.ask` only for a tool whose declaration set `ask`, so a `--deny`, an
  `--allow` or a `--trust none` aimed at any other tool is inert. This is the same
  defect `cli.problems` already refuses when the named tool does not exist — a policy
  that reads as safety while providing none — but the entry here is well formed and
  cannot be refused, so `cli.wire` says it out loud instead: one header warning naming
  the tools, on the precedent of the `no one to ask` line.
* **`cli.plan` asks the gate only about the tools the run will ask about.** Stamping
  `ask = true` on every probe made the plan print `deny` beside a tool that always
  runs, which is the plan saying the opposite of the run it is a plan for. A tool that
  does not ask gets the row it has earned: `allowed`, source `declaration`, reason
  "the tool does not ask, so the gate is not consulted". Each row carries `asks` and
  `consulted` so a test asserts on the table rather than on its text.
* **The `no one to ask` warning is not printed on a trusted workspace.** `approval`
  allows at step 6, before anything is put to a human, so the header would have
  promised a refusal the very next line then failed to make. The wording is now
  "any call that reaches the question refuses", which stays true when an allow policy
  answers first.
* **`--json` owns stdout in every mode, `--tools` and `--check` included.** They were
  writing their human text to stdout, so a caller piping stdout into a parser got
  neither JSON nor an error. Both now put the reading on stderr and one encoded object
  on stdout, and neither changes its exit code.
* **The `--script` data file is bounded exactly as the declaration is.** It was run
  through a bare `pcall`, so `--script s.lua` holding `while true do end` hung a runner
  that stops the identical declaration at `too_long`. Both now go through one
  `run_bounded`, which is also the one place that holds a compiling interpreter off
  the chunk.
* **A host clock that misbehaves costs a run nothing.** `world.now()` raising, or
  answering with something that is not a number, turned an answered run into
  `internal fault` and code 6. The timing clause is now simply absent, exactly as it
  is for a host with no clock, and `world.width()` falls back the same way.
* **`cli.load` carries the written global names out.** `cli.sandbox` recorded them and
  `cli.load` dropped them, so the report this document promises under `--verbose` did
  not exist. They ride out on the agent as `load_wrote`, which `cli.run` consumes and
  clears beside `load_notes`.

### `bin/malleable.lua`

It wires `out`, `err`, `read`, `stdin`, `env` and `now`, and deliberately does **not**
wire `ports`. Building the real six is a separate integration — it means choosing a
provider and a filesystem and a shell — and until that lands this build reports
`no ports wired -- this build can only --dry-run` and exits 7, which is a stated
outcome of this document rather than a hole in it.
