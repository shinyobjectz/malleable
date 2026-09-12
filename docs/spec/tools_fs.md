# tools_fs — the filesystem tools

Status: specification. No implementation exists yet; `src/tools_fs.lua` is written to
this document, and this document is amended before the code diverges from it.

## 1. What it is for

A coding agent is useless until it can see and change a workspace, so this subsystem
declares the six tools that let it: read a file, write a file, edit a file by exact
string replacement, list a directory, match a glob, and search file contents. Each one
is declared through the ordinary `agent.tool` surface with typed arguments and an honest
`about`, so the model is told exactly as much about them as it is told about any other
tool. Every path an argument names is resolved against one workspace root and refused,
with a reason the model reads, if it would land outside it.

Nothing here touches a real disk. The tools take their world through the filesystem
slice of the port table (section 3), which the host supplies; a test supplies a table of
strings instead and the tools cannot tell the difference.

## 2. Where it sits

    declaration file  ->  agent.tool "read" { ... }        (src/spec.lua)
    tools_fs.install  ->  declares those six tools
    a tool body       ->  ctx.fs.read(rel)                 (spec/port.md)

`tools_fs` is a library the host or a declaration file calls. It adds no new verb to the
`agent` surface: it calls `agent.tool` the same way a hand-written declaration does, so
a reader who understands one understands the other.

    local agent    = require "agent"       -- the public prefix
    local tools_fs = require "tools_fs"

    agent.name  "reviewer"
    agent.model "openrouter:z-ai/glm-5.3"

    tools_fs.install(agent, { root = "/w/project", port = host_port })

Both options are optional. A declaration file with no port to hand over writes
`tools_fs.install(agent, {})`, and the tools take their filesystem from the context the
harness gives a tool body.

## 3. The port slice it requires

`spec/port.md` is the authority on the port table, and this section was rewritten to
agree with it on 2026-09-10 — the earlier draft, written before that file existed, asked
for absolute paths and for three calls the port does not have. What `tools_fs` uses, and
all it uses, is `port.fs` and (only when a deadline is configured) `port.clock`:

| call | returns on success | returns on failure |
| --- | --- | --- |
| `fs.read(rel)` | `string` (the whole file, bytes verbatim) | `nil, err` |
| `fs.write(rel, text)` | `true` | `nil, err` |
| `fs.list(dir)` | array of `{ name = string, kind = "file"|"dir", size = number|nil }` | `nil, err` |
| `fs.exists(rel)` | `boolean` — it cannot fail | — |
| `clock.mono()` *(only with `deadline_ms`)* | `number`, seconds, monotonic | — |

Rules that hold across all of them:

- **Paths are workspace-relative**, slash-separated, `""` for the workspace root in
  `list`. There is no absolute path anywhere in this subsystem: `resolve` normalises
  what the model asked for and the port is handed the relative form.
- Every call is synchronous and returns; no coroutine, no callback, no yield.
- `err` is the port's error table, `{ port, call, code, message }`. `tools_fs` reads
  `code` only to tell a missing file from a refusal from a broken host, and passes
  `message` through verbatim inside a failure result — it never parses it and never
  rewrites it. A port that answers with a bare string instead is read as the message.
- Sizes are byte counts. Text is bytes; there is no encoding layer and no newline
  translation anywhere in this subsystem.
- **There is no `stat`, no `mkdirp` and no `realpath`.** A directory is told from a file
  by whether it lists; a size comes from the parent's listing; parent directories are
  created by `fs.write`, which spec/port.md says does that itself.
- The clock is `clock.mono()`, in **seconds**; `deadline_ms` is milliseconds and the
  subsystem converts. `clock.now()` is used only when a port has no `mono`.
- A port call that raises instead of returning `nil, err` is a broken host. The tool
  body catches it with `pcall` and turns it into a `port_failed` result rather than
  letting it escape into the loop that called it.

**Which port.** A tool body prefers `ctx.fs`, the filesystem the harness put on the tool
context, and falls back to the one named in `opts.port` at install. A host that wires
one port and runs another therefore gets the running one, which is the only answer that
cannot be stale.


## 4. The public API

### `tools_fs.install(agent, opts) -> installed`

Declares the tools on `agent`. Called at declaration time; runs no tool body, opens no
file and makes no port call, so rule 2 still holds for a file that installs this
subsystem.

`agent` is the public prefix table. `tools_fs` uses exactly three fields of it —
`agent.tool`, and the argument constructors `agent.string`, `agent.string_opt`,
`agent.number_opt`, `agent.boolean_opt`. It reads nothing else and writes nothing else.

`opts` is a table:

| key | type | default | meaning |
| --- | --- | --- | --- |
| `root` | string | `""` | the workspace root, as the host names it. Used only to recognise an absolute path that in fact sits inside the workspace, and to report back in `installed.root`; the port is never given it. Trailing separators are stripped. |
| `port` | table | nil | when given, must carry `fs` with the calls in section 3, and is the filesystem a tool body uses when the context has none. |
| `max_bytes` | number | `1048576` | largest file `read` will return whole. |
| `max_entries` | number | `1000` | largest number of entries `list` and `glob` will return. What `search` returns is capped by `max_hits` instead, since it returns hits and not entries. |
| `max_scan` | number | `20000` | largest number of directory entries any one call will *visit*. |
| `max_depth` | number | `8` | deepest recursion below the named directory. |
| `max_hits` | number | `200` | largest number of `search` hits returned. |
| `deadline_ms` | number or nil | `nil` | wall budget for one tool call, in milliseconds. Needs a clock: when `port` is given without `clock`, `install` raises; when no `port` is given at all, a call that finds no `ctx.clock` refuses with `port_failed` rather than pretending the budget is being kept. |
| `deny` | array of glob patterns | `{}` | paths refused to every tool, read included. |
| `read_only` | boolean | `false` | `write` and `edit` are still declared, but every call refuses with `read_only`; the model is told so in the `about`. |
| `ask` | table | `{ write = true, edit = true }` | per-tool `ask` flag passed straight to `agent.tool`. |
| `names` | table | `{}` | rename a tool, e.g. `{ read = "fs_read" }`. |

Returns `installed`, a plain table
`{ root = string, tools = { [logical] = declared_name }, notes = { string, ... } }`,
for a host that wants to know what it just declared. `notes` states what this install
cannot do — that it has no port of its own, that a link is listed and never followed,
that the workspace is read-only. Nothing in it is live state.

`install` **raises** (`error`) — it does not return a failure — when `opts` is wrong:
a non-string `root`, a `port` that is not a table or whose `fs` is missing one of the
calls in section 3, a numeric option that is not a positive whole number, a `deny` entry
that is not a string or is not a pattern the matcher takes, a `names` entry that is not
a non-empty string, or `deadline_ms` on a port with no `clock`. That is a bug in the host's own file, caught at
declaration, and it must stop the process rather than become a result a model reads.
This is the only place in the subsystem that raises.

`install` is idempotent in nothing: calling it twice on one agent declares the tools
twice, and `spec.add_tool` refuses the second with "the tool ... is declared twice".
That refusal is the right one and is not caught here.

### The result shape every tool body returns

One table, always, never a bare string and never a raised error:

    { ok = true,  ... }                          -- fields per tool, section 4.1
    { ok = false, code = "<slug>", reason = "<one sentence, no trailing newline>" }

A failure result may carry extra fields naming the evidence (`count`, `lines`, `size`,
`near`, `suggest`) — section 5 says which code carries which. `ok` is always a boolean,
`code` always one of the slugs in section 5, `reason` always a non-empty string.

A refusal is a result, not an error. Rule 4 already says a permission refusal is
something the model reads; the same holds for every refusal here, because a model that
gets an exception learns nothing and a model that gets "the path leaves the workspace"
tries a different path.

### 4.1 The six tools

Argument tables below are the literal `args` given to `agent.tool`. A `_opt` type is
absent-or-of-that-type; a missing required argument is caught before the body runs by
whatever validates the call, and if it reaches the body anyway the body refuses with
`bad_args` rather than indexing a nil.

**`read`** — *Read a file from the workspace. Returns its bytes; use offset and limit to
read part of a long file.*

    args = {
      path   = agent.string     "workspace-relative path to the file",
      offset = agent.number_opt "first line to return, 1-based",
      limit  = agent.number_opt "how many lines to return",
    }

Success: `{ ok = true, path, text, bytes, lines, from_line, to_line, eof }`.
`path` is the normalised workspace-relative path, which is what every other tool wants
back. `text` is verbatim: no line numbers are interleaved, no newline is added or
removed, no tab is expanded, because `edit` matches on exactly these bytes and any
decoration would poison the copy the model makes. `lines` is the line count of the
returned text, `from_line`/`to_line` its position in the file, `eof` true when
`to_line` is the last line. With neither `offset` nor `limit`, the whole file is
returned and `from_line` is 1.

`bytes` is the length of the text returned, not of the file. A file over `max_bytes`
read whole is `too_large`; read with `offset` or `limit` it is allowed, and the refusal
falls on the slice instead when even that is over the limit — otherwise the advice the
refusal gives would be advice that cannot work.

`offset` beyond the last line is not an error: it returns `text = ""`, `lines = 0`,
`eof = true`. An empty file read whole returns `text = ""`, `lines = 0`, `eof = true`.
A non-integer or non-positive `offset` or `limit` is `bad_args`.

**`write`** — *Write a whole file, creating it or replacing what is there. To change
part of a file, use edit instead.* `ask = true` by default.

    args = {
      path = agent.string "workspace-relative path to the file",
      text = agent.string "the entire new contents of the file",
    }

Success: `{ ok = true, path, bytes, created, bytes_before }`. `created` is true when
the file did not exist; `bytes_before` is the previous size, taken from the parent's
listing, or nil when the file was created or the port reports no size. Parent
directories are created by `fs.write` itself (spec/port.md), so this subsystem never
makes a directory of its own. `text = ""` is legal and writes an empty file. Writing a
path that names an existing directory is `not_a_file`.

**`edit`** — *Replace an exact piece of text in a file. The old text must appear
exactly once, or the edit is refused rather than guessed at.* `ask = true` by default.

    args = {
      path   = agent.string     "workspace-relative path to the file",
      old    = agent.string     "the exact text to replace, copied from the file",
      new    = agent.string     "the text to put in its place",
      expect = agent.number_opt "replace this many occurrences instead of exactly one",
    }

Matching is plain and literal: `string.find(text, old, i, true)`. No pattern magic, no
whitespace tolerance, no case folding, no newline normalisation — a file with CRLF line
endings needs CRLF in `old`, and this is stated in the refusal when it happens.
Occurrences are counted left to right and do not overlap.

With `expect` absent, exactly one occurrence is required. With `expect = n`, exactly
`n` are required and all `n` are replaced. Success:
`{ ok = true, path, replaced, bytes, line }` — `line` is the 1-based line of the first
replacement, so the model can read back around it.

A file over `max_bytes` is `too_large` for `edit` too: the whole file is held in memory
to do the replacement, so the same cap has to hold.

`edit` never creates a file, never appends, never deletes the file when `new` is empty
(it writes the shortened contents), and never touches a file whose bytes it did not
just read in the same call.

**`list`** — *List what is in a directory. Directories are marked; symbolic links are
listed but never followed.*

    args = {
      path  = agent.string_opt "workspace-relative directory, default the workspace root",
      depth = agent.number_opt "how many levels to descend, default 1",
    }

Success: `{ ok = true, path, entries, count, truncated, scanned }`. `entries` is an
array of `{ path = workspace-relative, kind, size = number|nil }`, where `kind` is
whatever the port called it — `"file"` or `"dir"` from a port that keeps to
spec/port.md, `"link"` or `"other"` passed through from a richer one — sorted by `path`
byte order so two runs on one tree agree exactly. `size` is nil for
anything that is not a file. `truncated` is true when `max_entries` cut the list, and
then the list is still the first `max_entries` in sort order rather than an arbitrary
prefix of the walk.

An empty directory is a success with `entries = {}` and `count = 0`, not a failure.
`depth` above `max_depth` is clamped, silently in the result but stated in a `note`
field (`{ note = "depth clamped to 8" }`), because a refusal there would help nobody.

**`glob`** — *Find files whose path matches a pattern, like `src/**/*.lua`.*

    args = {
      pattern = agent.string     "glob pattern, workspace-relative",
      path    = agent.string_opt "directory to search under, default the workspace root",
    }

Supported syntax, and nothing else: `*` (any run of characters except the separator),
`**` (any run including separators, and as a whole segment it also matches zero
segments, so `src/**/*.lua` matches `src/a.lua`), `?` (one character except the
separator), and a character class `[abc]`, `[a-z]`, `[!a-z]` or `[^a-z]`. Because `**` matches zero segments, a pattern
ending in `/**` also matches the directory itself, which is what a deny rule such as
`.git/**` should mean; inside a segment, `**` is read as `*`. Brace
alternation `{a,b}` is **not** supported and a pattern containing `{` or `}` is refused
with `unsupported_pattern` rather than being matched literally, because a literal match
would silently return the wrong set. Matching is on the whole workspace-relative path,
byte by byte, case-sensitively, and a leading `./` in the pattern is stripped first.
Directories are not returned, only files and links.

Success: `{ ok = true, pattern, paths, count, truncated, scanned }`, `paths` sorted by
byte order. No match is a success with `paths = {}`, never a failure: "no file matches"
is an answer.

**`search`** — *Search file contents for a pattern and return the matching lines.*

    args = {
      pattern = agent.string      "a Lua pattern, or a literal string when fixed is true",
      path    = agent.string_opt  "directory to search under, default the workspace root",
      glob    = agent.string_opt  "only search files whose path matches this glob",
      fixed   = agent.boolean_opt "treat the pattern as literal text, default false",
      max     = agent.number_opt  "stop after this many hits",
    }

The `about` says *Lua pattern* and means it: `%d`, `%s`, `-`, `+`, anchors and captures
behave as Lua's, and PCRE syntax such as `\d`, `\b`, `|` or `(?:...)` does not work.
The tool does not translate one into the other, because a half-translation would find
the wrong lines and say nothing about it. A malformed pattern is caught with `pcall`
— once before the walk and again around every line, because a pattern such as `x%`
raises only on a line that reaches its trailing `%` — and returned as `bad_pattern` with
Lua's own message. Note that `%(` is a *valid* Lua pattern for a literal bracket and not
a malformed one.

Success: `{ ok = true, pattern, hits, count, truncated, files_scanned, files_skipped }`.
A hit is `{ path, line, col, text, trimmed }`: `line` and `col` are 1-based, `text` is
the whole matching line without its newline (and without the carriage return before it,
in a file with CRLF endings), cut to 400 bytes with `trimmed = true`
when it is longer. At most one hit per line, the leftmost. Files whose first 8000 bytes
contain a zero byte are skipped and counted in `files_skipped`, never returned as
mojibake. No hit is a success with `hits = {}`.

### 4.2 The pure helpers

Public because they are the whole of the subsystem's judgement and they must be
testable on their own, with no port at all:

- `tools_fs.resolve(root, path) -> abs, rel` on success, or `nil, code, reason, extra`
  on refusal, where `extra` carries the evidence the code owes — `{ suggest = ... }` for
  an absolute path that does sit under the root. `rel` is what the port is given, and is
  `""` for the workspace root itself. Purely lexical: it never calls the port and never
  touches a disk. Section 5 gives its refusals.
- `tools_fs.glob_match(pattern, path) -> true|false` for a valid pattern, or
  `nil, reason` for one it will not accept.
- `tools_fs.find_all(text, needle) -> array of byte offsets`, plain, non-overlapping,
  left to right. Empty `needle` returns an empty array rather than looping forever.
- `tools_fs.line_of(text, offset) -> line, col`, 1-based, counting `\n`.

These four are the units the awkward tests in section 7 aim at.

## 5. The failure modes

Every one of these is a returned table, never a raised error, and every one carries a
`reason` a model can act on. The reason names what was wrong and, where there is one, the
thing to try instead. It never says "internal error", never includes a Lua traceback, and
never includes the absolute path — the model works in workspace-relative paths and telling
it where the workspace lives on the host's disk teaches it a path it must not use.

| code | when | what the caller sees besides `code` and `reason` |
| --- | --- | --- |
| `bad_args` | a required argument is nil or of the wrong type; `offset`/`limit`/`expect`/`max` not a positive whole number; `old` empty in `edit` | `field` — which argument |
| `outside_workspace` | the resolved path leaves the root: `..` climbing above it, an absolute path, a Windows drive prefix, a zero byte in the path | `suggest` — the workspace-relative form, when the path was absolute and did in fact sit under the root |
| `denied` | the path matches a `deny` pattern, or the port itself refused it — a backslash, a doubled slash, a read-only workspace | `pattern` — which rule, when it was a rule here; `path` |
| `read_only` | `write` or `edit` while `opts.read_only` | — |
| `not_found` | the port reports the file or directory absent | `path` |
| `not_a_file` | `read`, `write` or `edit` on a directory | `kind` |
| `not_a_dir` | `list`, `glob` or `search` on a file | `kind` |
| `too_large` | file over `max_bytes` in `read` or `edit`, or the port's own cap | `size`, `limit` |
| `binary` | `read` on a file with a zero byte in its first 8000 | `size` |
| `no_match` | `edit` where `old` does not occur | `near` — `{ line = n, hint = "..." }` when a whitespace-insensitive comparison finds exactly one near miss, and `crlf = true` when the file has CRLF endings and `old` does not |
| `ambiguous` | `edit` where `old` occurs more than once and `expect` is absent, or occurs a number of times other than `expect` | `count`, `lines` — the first ten line numbers |
| `unchanged` | `edit` where `old == new` | — |
| `unsupported_pattern` | a glob containing `{` or `}`, or an empty pattern | `pattern` |
| `bad_pattern` | `search` given a malformed Lua pattern, caught before the walk or on the line that raises | `detail` — Lua's own message |
| `budget` | `max_scan` entries visited before the walk finished | `scanned` — and the partial result is still returned in `paths`/`entries`/`hits` alongside `ok = false`, because half an answer beats none |
| `deadline` | `deadline_ms` elapsed mid-walk | `elapsed_ms`, and the partial result, as above |
| `port_failed` | a port call failed for a reason that is none of the above, or raised, or there is no filesystem port at all, or a deadline is set with no clock to keep it | `reason` is the port's own words, prefixed with which call failed |

A port error is read by its `code` and nothing else: `not_found` becomes `not_found`,
`too_big` becomes `too_large`, `denied` becomes `denied`, and every other code becomes
`port_failed` carrying the port's message. `search` does not fail on a file it cannot
read or that is over the cap — it counts it in `files_skipped` and goes on.

Two failures deserve their own paragraph.

**The escaping path.** `resolve` is lexical and runs before any port call, so a path that
escapes is refused without ever being handed to the host. It splits on `/`, drops empty
segments and `.`, and pops on `..`; a `..` that would pop past the root is
`outside_workspace`. Backslash is an ordinary character in a segment, not a separator, so
`..\..\etc` is one harmless filename and not an escape. A path beginning `/`, or matching
a drive letter and colon, is refused rather than joined. `~` is never expanded, an
environment variable is never substituted, and a glob character in a `path` argument is
never expanded — `read` on `src/*.lua` is a file that is probably not found, not a
wildcard.

**The symlink that escapes.** Lexical resolution cannot see a link that points outside the
root, so a walk reports a link as `kind = "link"` and never descends into it. Reading
*through* one is the port's business and not this subsystem's: spec/port.md has no
`realpath`, and decides every path on its text before any lookup, "so a symlink cannot be
the difference". `tools_fs` therefore says what it cannot do — a line in
`installed.notes` — rather than pretending to a safety it does not have. A host whose
filesystem has links and whose port follows them has made that decision itself, and this
file will not paper over it. (The earlier draft of this section described a
`port.fs.realpath` second gate. There is no such call; the paragraph was rewritten on
2026-09-10 rather than left to describe a check nothing performs.)

**Nothing partial is written.** `edit` reads, computes the new text in memory, and writes
once. A failed write leaves the file as it was, since the port's `write` is the only
mutation and it either happened or did not. There is no temp file, no backup, no journal,
and no retry: a `port_failed` on write is reported, not worked around.

## 6. What it must NOT do

- **It must not reach into another subsystem.** No `require` of `turn`, of a session, of
  a model or provider, of an approval module. Its only imports are Lua's standard
  `string`, `table` and `math`, and the `agent` table handed to `install`.
- **It must not touch the world directly.** No `io`, no `os`, no `require` at runtime, no
  `load`/`loadstring`, no `os.getenv`, `os.time`, `os.clock`, `os.execute`, `io.popen`.
  Time comes from `port.clock` and files come from `port.fs`, or they do not come. *A
  test greps the source for these names.*
- **It must not ask permission.** Rule 4: permission is the harness's. `tools_fs` sets
  `ask` on a declaration and stops there. It does not call an approval port, does not
  read a decision, and cannot approve itself.
- **It must not decide the turn's shape.** It returns a table. How a result is rendered
  to the model, truncated for a context window, or logged is `turn`'s business.
- **It must not keep state.** No cache of file contents, no memo of a previous listing,
  no counter that survives a call. Two identical calls against one port state return
  equal results. The only thing held across calls is the config from `install`.
- **It must not print, log, or write to stderr.**
- **It must not delete, move, copy, chmod, or create a directory on its own.** There is no
  delete tool and no rename tool in this subsystem, deliberately: a coding agent that can
  destroy work needs a gate designed for that, and it is not this one. `mkdirp` happens
  only as a consequence of `write`.
- **It must not mutate its arguments** or the `agent` table beyond calling `agent.tool`,
  and it must not mutate `opts` — it copies what it keeps.
- **It must not repair the model's mistake.** No fuzzy matching in `edit`, no
  "did you mean" that is applied, no trimming of the model's `old`, no auto-created
  parent for `edit`, no glob expansion in a path. It reports and refuses; the model
  tries again with better input.
- **It must not translate a pattern dialect.** A Lua pattern is what `search` takes; a
  PCRE is refused or finds nothing, and is never silently rewritten.

## 7. The tests that would prove it

Every one runs against a fake port: a table mapping absolute path to string, plus a set
of directory paths, plus an optional injected failure. No disk, no network, no
subprocess, no clock — the deadline tests drive a fake `port.clock.now` by hand. Names
below are the test names.

**Declaration**

1. `install_declares_six_tools` — after `install`, `spec.schema` lists exactly read,
   write, edit, list, glob, search, in that order, each with a non-empty `about`.
2. `install_runs_nothing` — a port whose every function raises is installed cleanly;
   rule 2 holds.
3. `install_refuses_a_bad_root` — a `root` that is not a string raises at install and
   the message names `root`. `root` absent is legal and means the port's own workspace;
   there is nothing here for an absolute root to be joined to.
4. `install_refuses_a_port_missing_a_call` — a `port.fs` without `write` raises and
   names `write`. `install_refuses_a_bad_deny_pattern` is its sibling: a `deny` entry the
   matcher will not take raises at declaration rather than silently matching nothing.
5. `renamed_tools_keep_their_contract` — `names = { read = "fs_read" }` declares
   `fs_read`, and `installed.tools.read == "fs_read"`.
6. `write_and_edit_ask_by_default` — `schema` shows `ask = true` for write and edit,
   `false` for the other four.

**Reading**

7. `read_returns_bytes_verbatim` — a file with tabs, CRLF and no trailing newline comes
   back byte-identical, with no line numbers interleaved.
8. `read_of_an_empty_file_succeeds` — `text = ""`, `lines = 0`, `eof = true`, `ok = true`.
   *(Empty input.)*
9. `read_offset_past_the_end_is_empty_not_an_error` — `offset = 999` on a three-line file
   is `ok = true`, `text = ""`, `eof = true`. *(Adversarial.)*
10. `read_of_a_missing_file_says_not_found` — `code = "not_found"`, the reason names the
    workspace-relative path and not the absolute one. *(Missing file.)*
11. `read_of_a_directory_says_not_a_file`.
12. `read_over_max_bytes_refuses_with_the_size` — `too_large`, `size` and `limit` present,
    and the reason suggests `offset`/`limit`.
13. `read_of_a_binary_file_refuses` — a file with a zero byte at offset 3 is `binary`,
    and no bytes of it appear in the result. *(Adversarial.)*

**Path safety**

14. `a_climbing_path_is_refused` — `../secrets`, `a/../../secrets`, `./../x` are each
    `outside_workspace`, and no port call was made. *(Adversarial.)*
15. `an_absolute_path_is_refused_with_a_suggestion` — a path under the root comes back
    `outside_workspace` with `suggest` holding the relative form; one outside comes back
    with no `suggest`. *(Adversarial.)*
16. `a_backslash_is_not_a_separator` — `..\..\etc\passwd` resolves, lexically, to that
    one filename inside the root: `resolve` returns it whole and the refusal that comes
    back is not `outside_workspace`. The port refuses a backslash in a path of its own
    accord (spec/port.md's `path_ok`), so the tool result is `denied` and not
    `not_found` — either way, one filename was never read as an escape. *(Adversarial.)*
17. `a_zero_byte_in_a_path_is_refused` — `"a\0b"` is `outside_workspace` and reaches no
    port call. *(Adversarial.)*
18. `a_tilde_is_a_filename` — `~/x` and `~` are ordinary segments, never a home
    directory. *(Adversarial.)*
19. `a_deny_pattern_refuses_every_tool` — with `deny = { ".git/**" }`, read, write, edit,
    list, glob and search each refuse `.git/config` with `denied`, `list ".git"` is
    refused too (a `**` that matches zero segments covers the directory itself), and
    `glob "**/*"` returns no path under `.git`.
20. `a_link_is_never_followed` — a walk over a tree containing a link reports
    `kind = "link"` and does not descend into it. There is no `realpath` half to this
    test: see the symlink paragraph in section 5. *(Adversarial.)*
21. `resolve_is_pure` — `tools_fs.resolve` returns the same answers with no port in
    scope at all.

**Editing**

22. `edit_replaces_one_occurrence` — `replaced = 1`, the port saw exactly one `write`,
    and the written text is the expected bytes.
23. `edit_refuses_two_occurrences` — `ambiguous`, `count = 2`, `lines` holds both line
    numbers, and **no write happened**. *(Adversarial — the whole reason this tool
    exists.)*
24. `edit_with_expect_replaces_them_all` — `expect = 3` on three occurrences writes once
    with all three replaced; `expect = 2` on three refuses `ambiguous` with `count = 3`
    and writes nothing.
25. `edit_refuses_an_absent_old` — `no_match`, no write, and where a whitespace-only
    difference makes a single near miss, `near.line` points at it and the text was still
    not changed. *(Adversarial.)*
26. `edit_treats_magic_characters_literally` — `old = "a.b[c]%d"` matches only that exact
    text and not a pattern-expanded one. *(Adversarial.)*
27. `edit_refuses_an_empty_old` — `bad_args`, naming `old`, and the reason points at
    `write`. *(Empty input, adversarial.)*
28. `edit_refuses_when_old_equals_new` — `unchanged`, no write.
29. `edit_names_crlf_when_that_is_the_difference` — a CRLF file with an LF `old` refuses
    `no_match` with `crlf = true`. *(Adversarial.)*
30. `edit_does_not_create_a_file` — on a missing path it is `not_found`, and the port saw
    no write.
31. `a_failed_write_leaves_the_file_alone` — a port whose `write` returns
    `nil, "disk full"` gives `port_failed` carrying "disk full", and a subsequent read
    returns the original bytes. *(Adversarial.)*
32. `a_raising_port_becomes_a_result` — a port whose `read` raises produces
    `code = "port_failed"`, and the error does not escape the tool body. *(Adversarial.)*

**Writing**

33. `write_creates_a_file_and_says_so` — `created = true`, `bytes_before` nil, and the
    port saw exactly one write, at the full path. Creating the parent directory is
    `fs.write`'s own job (spec/port.md), so there is no `mkdirp` to assert.
34. `write_reports_what_it_replaced` — over an existing file, `created = false` and
    `bytes_before` is the old size.
35. `write_of_empty_text_is_legal` — a zero-byte file, `ok = true`. *(Empty input.)*
36. `read_only_refuses_write_and_edit_but_not_read` — `read_only` gives `code =
    "read_only"` for both, while `read` still succeeds, and the `about` of write says so.

**Listing, globbing, searching**

37. `list_of_an_empty_directory_succeeds` — `entries = {}`, `count = 0`, `ok = true`.
    *(Empty input.)*
38. `list_is_sorted_and_stable` — two runs over a port that returns its entries in
    different orders give byte-identical results.
39. `list_depth_defaults_to_one` — nested files appear only with `depth` above 1, and a
    `depth` above `max_depth` is clamped with a `note`.
40. `list_truncates_at_max_entries_deterministically` — with `max_entries = 3`, the three
    returned are the first three in sort order and `truncated = true`.
41. `a_walk_stops_at_max_scan` — a fake tree of 50000 entries with `max_scan = 100`
    returns `ok = false`, `code = "budget"`, `scanned = 100`, and a non-empty partial
    list. *(Recursion, adversarial.)*
42. `a_cyclic_tree_terminates` — a port whose `list` of `a/b` returns `a` again finishes
    within `max_depth` and `max_scan` rather than hanging, and reports what it hit.
    *(Recursion, adversarial.)*
43. `a_deadline_ends_a_walk` — with `deadline_ms = 50` and a fake clock that jumps 60ms
    on the second `list`, the result is `code = "deadline"` with `elapsed_ms` and a
    partial list. *(Timeout.)*
44. `glob_star_does_not_cross_a_separator` — `src/*.lua` matches `src/a.lua` and not
    `src/x/a.lua`.
45. `glob_double_star_matches_zero_segments` — `src/**/*.lua` matches both `src/a.lua`
    and `src/x/y/a.lua`.
46. `glob_character_classes_and_negation` — `[a-c]*.lua`, `[!a-c]*.lua` behave, and `]`
    first in a class is literal.
47. `glob_refuses_brace_alternation` — `src/{a,b}.lua` is `unsupported_pattern` and is
    not matched literally. *(Adversarial — the silent-wrong-answer case.)*
48. `glob_with_no_match_is_a_success` — `paths = {}`, `ok = true`.
49. `search_finds_a_line_with_position` — `line` and `col` are 1-based and point at the
    match; the returned text has no newline.
50. `search_reports_only_the_first_hit_per_line`.
51. `search_trims_a_long_line` — a 10000-byte line comes back 400 bytes with
    `trimmed = true`.
52. `search_skips_binary_files` — counted in `files_skipped`, no bytes returned.
53. `search_refuses_a_malformed_lua_pattern` — `"[a"` and `"("` give `bad_pattern`
    carrying Lua's message; so does `"x%"`, which raises only on the line that reaches
    it; and `"%("`, which is a valid pattern for a literal bracket, succeeds. Nothing
    raised. *(Adversarial.)*
54. `search_does_not_understand_pcre` — `"\\d+"` finds the literal text and not digits,
    which is the documented behaviour and is asserted so a future translation layer
    cannot land silently. *(Adversarial.)*
55. `search_honours_its_glob_filter` — only files matching `glob` are scanned, and
    `files_scanned` proves it.

**Boundaries**

56. `tools_fs_names_no_vendor` — reads `src/tools_fs.lua` and fails on `io.`, `os.`,
    `require` *anywhere* (the file has none at all, which is the strongest form of "it
    must not reach into another subsystem"), `load(`, `loadstring`, `dofile`, `popen` or
    `print(`. The sibling of rule 1's `core_names_no_vendor`.
57. `no_state_survives_a_call` — the same call twice against an unchanged port gives
    deeply equal results, and installing two agents in one process gives two independent
    configs. `opts_are_copied_not_held` is its sibling: editing the `opts` table after
    `install` changes nothing about what the tools do.
58. `every_failure_is_a_table_not_an_error` — a driver that calls every tool with every
    malformed argument shape it can build (nil, number, table, a very long string, a
    string of zero bytes) asserts that no call raises and every result has `ok`, `code`
    and a non-empty `reason`. *(Adversarial, and the one that catches the next bug.)*

**A world that answers nothing**

59. `a_run_with_no_filesystem_is_a_result_not_a_raise` — `install(agent, {})` with no
    port, then every tool called with a path and again at the workspace root: none
    raises, and every one is `port_failed`. Section 4 makes `port` optional, so this is
    a shape a declaration file can reach without doing anything wrong.
    *(Adversarial — the one that caught `write` and the three walking tools raising.)*
60. `a_port_that_cannot_list_is_not_an_empty_workspace` — the same sweep with `ctx.fs`
    a table that owes every call. `list`, `glob` and `search` at the root must refuse,
    not answer `ok = true, count = 0`: a wrong answer is worse than a refused one.
    *(Adversarial.)*
61. `a_deadline_with_no_clock_at_call_time_is_refused` — `deadline_ms` with no port to
    check at install, then a call whose context has no clock: `port_failed` naming the
    clock, and the same call with a clock on the context succeeds.
62. `the_context_port_beats_the_one_named_at_install` — a read goes to `ctx.fs`, and
    the port named at install is never called.
63. `list_glob_and_search_on_a_file_say_not_a_dir` — each carries `kind = "file"`; a
    missing directory is `not_found` and not confused with it.
64. `read_over_max_bytes_still_allows_a_slice` — the whole file and an unbounded
    `offset` are both `too_large`, and `offset` with a `limit` inside the cap succeeds.
    Otherwise the advice the refusal gives is advice that cannot work.
65. `edit_judges_the_path_before_it_judges_the_text` — `old == new` on a denied path is
    `denied` and on a climbing path is `outside_workspace`, never `unchanged`.
    `unchanged` is an opinion about a file, and neither of those is a file this tool
    may hold an opinion about. *(Adversarial.)*
66. `a_glob_of_many_stars_answers_in_time` — `a*a*a*a*a*a*a*a*b` against a 200-byte
    name, under a counted instruction budget. A pattern is something a model asks for
    and a deny rule is matched against every path a walk visits, so the matcher's cost
    is the harness's cost, and it is spent where neither `max_scan` nor `deadline_ms`
    can see it. *(Adversarial, and rule 5 applied to the matcher.)*

## 8. What the code taught this file

Amendments made on 2026-09-10, while `src/tools_fs.lua` was written to it. Each is in
place above; they are listed here so a reader of the original can see what moved.

1. **The port slice (section 3) was rewritten against `spec/port.md`.** That file, which
   did not exist when this one was drafted, gives the filesystem port five calls over
   *workspace-relative* paths, answering `nil, err` with an error *table*. The draft's
   `stat`, `mkdirp` and `realpath` do not exist and are gone; absolute paths are gone.
2. **`root` and `port` became optional.** With relative paths there is nothing for a
   host's absolute root to be joined to — it survives only to recognise an absolute path
   the model offers, and to be reported back. And a declaration file has no port to give:
   the harness puts one on the tool context, which is where a body now looks first.
3. **The clock is `clock.mono()`, in seconds.** The draft asked for `clock.now()` in
   milliseconds; port.md's `now` is epoch seconds and its monotonic clock is `mono`.
4. **A trailing `/**` covers the directory itself**, which follows from `**` matching zero
   segments and is what a deny rule wants.
5. **`%(` is a valid Lua pattern**, so it could not be the malformed-pattern example; and
   a pattern such as `x%` raises only on a line that reaches it, so the `pcall` around
   the per-line `find` reports `bad_pattern` too, rather than quietly finding nothing.
6. **`read` and `edit` state how `max_bytes` applies** to a slice and to an edit, which
   the draft left to be guessed.
7. **The result of a port failure is mapped by the port's `code`**, so `not_found`,
   `too_big` and `denied` keep their meaning instead of all becoming `port_failed`.

Amendments made on 2026-09-10 by the verification pass, after four defects were found
in the code written above and repaired in place.

8. **A missing filesystem is a result, not a raise.** Section 4's `port` is optional and
   section 5 lists `port_failed` for "there is no filesystem port at all", but `write`
   reached the parent listing through a nil table, and `list`, `glob` and `search` at
   the workspace root were waved past the port check and raised inside the walk. All
   four now refuse. Tests 59 and 60.
9. **A port that cannot list is not an empty workspace.** The same short-circuit meant a
   context whose `fs` owed every call answered `ok = true` with no entries. A wrong
   answer a model will act on is worse than a refusal it can read, so the port is
   checked before the root is taken on trust.
10. **The glob matcher is polynomial, not exponential.** `*` was a recursive branch at
    every star, so `a*a*a*a*a*a*a*a*b` against a forty-byte filename took twelve
    seconds and each further byte doubled it — inside the matcher, where no budget in
    section 4 can reach. A segment is now compiled once and matched with a single
    backtrack point, and `**` across segments is memoised on the pair it is deciding.
    The two forms were compared on 200,000 random pattern/path pairs and disagree
    nowhere. Test 66.
11. **`edit` resolves the path before it judges the text.** `old == new` was answered
    with `unchanged` before `resolve` and the deny list had run, so the tool gave a
    verdict about a file outside the workspace. Order is now: argument shapes, then the
    path, then the text. Test 65.

Known and not repaired: a `too_large` that comes from the *port's* own cap carries
neither `size` nor `limit`, because the port reports neither and inventing them would be
worse than their absence. And a `deny` pattern is not applied to the workspace root
itself, so `deny = { "**" }` leaves `list ""` a success over an empty list rather than a
refusal; every path under it is still filtered, and a host that means "no filesystem"
should not install these tools.
