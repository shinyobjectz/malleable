# config — configuration, profiles and secrets

Status: specification. `src/config.lua` does not exist yet; this is the contract it
must meet.

## 1. What it is for

Everything the harness needs to know before it can run — which model, at which endpoint,
with what budget, timeout and log level — arrives from four different places, and
`config` is the one module that decides which of them wins. It resolves built-in
defaults, then any number of configuration files, then the environment, then the
explicit overrides a host passes in, into a single set of values where **every value can
name the layer it came from**, because a configuration you cannot explain is one you
cannot debug. Secrets are the exception that shapes the whole module: they are read from
the environment and nowhere else, they never appear in a report, a log line, an error
message or the config table itself, and section 6 lists the tests that prove it.

`config` is not part of the `agent` declaration surface. A declaration file never writes
`agent.config`; the host loads a config before it builds a run and hands the pieces to
whoever needs them. A tool body never sees this module.

## 2. The world it takes (ports)

`config` reads two port fields and nothing else. It never calls `os.getenv`, `io.open`,
`os.time`, `os.clock`, `os.execute`, `math.random`, `load`, `loadstring`, `dofile` or a
global of any kind, so a full load runs in a test with no network, no disk and no
subprocess.

| field | shape | required |
| --- | --- | --- |
| `port.env.get(name)` | string → string or nil. An unset variable is nil. Must not raise. | only when the environment layer is consulted |
| `port.env.names()` | → a list of the variable names that exist, any order. Must not raise. | no — see the typo scan below |
| `port.fs.read(path)` | exactly `spec/port.md`'s filesystem port: `text` or `nil, err`. | only for a `files` entry given as a `path` |

`port.env` is an **addition to the six ports `spec/port.md` names**, made here because
the environment is a capability like any other and reading it directly would put
`os.getenv` inside a module whose whole job is to be testable. `port.md` remains the
authority on port names: when it adopts an environment port, this file follows it, and
if it names it something other than `env` this file is the one that is wrong. Until
then, `double.env(t)` — a table of name to value, plus `names()` over its keys — is what
a test wires in, and it is the only new double this subsystem needs.

Nothing else is touched. `config` never calls `port.model`, `port.sh`, `port.clock`,
`port.ask` or `port.log`. It has no clock, so it has no deadline of its own; it has no
log, so it cannot be the thing that writes a secret to a file.

If a required port field is missing or is not a function, `config.load` **raises**. A
host that wired no environment port and then asked for the environment layer has a
wiring bug, and returning that as a configuration problem would make it look like the
user's config file was at fault.

## 3. The shapes

### 3.1 A setting

A setting is declared once, in a schema, as a plain table:

```lua
{
  name     = "timeout",        -- required; lowercase, [a-z][a-z0-9_]*
  kind     = "number",         -- "string" | "number" | "boolean" | "list"
  default  = 60,               -- nil means "no value unless a layer supplies one"
  about    = "seconds per model call",   -- required; one sentence
  env      = "PI_TIMEOUT",     -- a name, or a list of names tried in order; nil means
                               -- this setting is not readable from the environment
  one_of   = nil,              -- list of allowed values, for kind "string"
  min      = 1, max = 600,     -- for kind "number"
  secret   = false,            -- section 3.4
  required = false,            -- load reports `missing` when nothing supplies it
  file     = true,             -- false forbids this setting in a configuration file
}
```

`name`, `kind` and `about` are required; everything else is optional. A definition may
carry **no key but these eleven**: an unknown one raises at `config.schema`, naming it,
for the same reason a misspelt `opts` key does. `one_of` belongs to kind `"string"` and
`min`/`max` to kind `"number"`; either one on another kind raises rather than being
quietly ignored. A normalised setting always exposes `env` as a list (empty when the
setting is not readable from the environment) and `file`/`secret`/`required` as
booleans, so a reader never has to test for nil.

`kind` decides both validation and how a string from the environment or a file is read
back into a Lua value:

| kind | Lua value | read from text |
| --- | --- | --- |
| `"string"` | string | verbatim |
| `"number"` | number | `tonumber`; a value `tonumber` refuses is `wrong_type` |
| `"boolean"` | boolean | `"true"`, `"false"`, `"1"`, `"0"`, case-insensitive; nothing else |
| `"list"` | list of strings | split on commas, each part trimmed; a quoted value is one element, never split |

There are four kinds and there will not be a fifth without a line in this file. A
configuration format that grows a type system grows a parser, and a parser is where the
`load()` gets in.

### 3.2 A schema

`config.schema(defs) -> schema` takes a list of setting definitions and returns a frozen
one. Order does not matter; the schema sorts by name so two reports agree. The schema
exposes four fields, all frozen: `settings` (the normalised definitions, sorted by
name), `by_name`, `by_env` (variable name to the setting that claims it) and `names`
(the setting names, sorted). It is identified by its metatable, so `config.load` can
tell a schema from a raw list of definitions and refuse the second.

### 3.3 The built-in settings

`config.settings` is the list the harness itself uses, exported as data so a host can
extend it (`config.schema(extend(config.settings, mine))`) rather than reproduce it.

| name | kind | default | env | notes |
| --- | --- | --- | --- | --- |
| `model` | string | nil | `PI_MODEL` | the id `agent.model` would otherwise carry |
| `base_url` | string | nil | `PI_BASE_URL` | nil means "the adapter's own default"; `config` names no vendor host, ever |
| `profile` | string | nil | `PI_PROFILE` | the bootstrap setting, section 4.2 |
| `budget` | number | 24 | `PI_BUDGET` | min 1 |
| `timeout` | number | 60 | `PI_TIMEOUT` | seconds, min 1 |
| `attempts` | number | 3 | `PI_ATTEMPTS` | min 1, max 10 |
| `workspace` | string | `"."` | `PI_WORKSPACE` | |
| `approve` | string | `"ask"` | `PI_APPROVE` | `one_of { "ask", "allow", "deny" }` |
| `log_level` | string | `"info"` | `PI_LOG_LEVEL` | `one_of { "debug", "info", "warn", "error" }` |
| `key` | string | — | `PI_API_KEY`, `OPENROUTER_API_KEY` | **secret**; `file = false` |

`timeout` carries `min = 1` and no maximum: 3.1's `max = 600` is an example of a
different schema, not this one. With this schema six settings carry a default, so a
load with nothing else wired reports `{ name = "builtin", where = "", n = 6 }`.

Nothing here is `required`. `model` in particular is not, because a declaration file may
supply it and a config that refused to load without one would break every agent that
already says `agent.model`.

### 3.4 A secret

`secret = true` changes five things, and a schema that breaks any of them raises at
`config.schema` rather than at load:

1. Its `kind` must be `"string"`.
2. It must name at least one `env` variable, and `file` is forced to `false`.
3. It may not have a `default`, a `one_of`, a `min` or a `max`. A default credential is
   not a thing, and `one_of` on a secret would put candidate values in a schema.
4. It may be supplied by the environment layer and by no other layer. A file that names
   it is a problem; an override that names it raises (section 5, F7).
5. Its value never leaves except through `config.secret`, which is the only function in
   this module that can return one.

### 3.5 A config

`config.load` returns `c`, and `c` **does not contain the values**. It is a plain table
with exactly four fields:

```lua
{
  profile  = "review" | nil,     -- the profile that was selected, or nil
  layers   = { { name = "builtin", where = "", n = 9 }, ... },  -- lowest first
  warnings = { "PI_MODEL was set but empty; ignored", ... },    -- strings, may be empty
  schema   = schema,             -- the frozen schema it was resolved against
}
```

The resolved values live in a module-level store keyed by `c`, weak in its keys so a
dropped config is collectable. This is not decoration: it means `pairs(c)`, a JSON
encoder walking `c`, a debug print, a deep copy into a session file and a crash dump all
see the four fields above and no credential. `c` also carries `__tostring`, returning
`config(profile=review, layers=4)` -- and `config(profile=nil, layers=1)` when no
profile was selected -- so `string.format("%s", c)` and an accidental print of `c`
cannot spill either. Note that `profile` is a nil field when nothing selected one, so
`pairs(c)` yields three keys rather than four; the shape is the same either way. `__newindex` raises: a config is read-only after load,
and a host that wants a different one calls `config.with`.

## 4. The public API

Ten functions. Wrong Lua types raise; a wrong *world* — a bad file, a missing variable,
an unreadable value — comes back as a problem list. That is `port.md`'s convention, and
it holds here in both directions.

### `config.schema(defs) -> schema`

`defs` is a list of setting definitions, or nil for `config.settings`. Returns a fresh
frozen schema. **Raises**, naming the offending definition, on: a non-list; a definition
that is not a table; a missing or malformed `name`; a duplicate `name`; a missing or
empty `about`; an unknown `kind`; a `default` whose type does not match `kind`; a
`default` outside `one_of`/`min`/`max`; an `env` that is not a string or list of
strings; two settings claiming the same environment variable; a key that is not one of
the eleven a setting has; a `one_of` on a kind other than string or a `min`/`max` on a
kind other than number; and each of the five secret rules in 3.4. A schema is written by a programmer, so every one of these is a
programmer's mistake and raises rather than returning.

`config.schema(config.schema(x))` returns an equal schema. Idempotent, never mutates
`defs`.

### `config.load(opts) -> c | nil, problems`

The whole of resolution. `opts` is a table or nil (nil means: built-in schema, no files,
no environment, no overrides — the defaults alone, which is a legal and useful config).

| field | type | meaning |
| --- | --- | --- |
| `schema` | schema or nil | from `config.schema`; nil means the built-ins. A raw list of definitions raises: run it through `config.schema` where a reader can see it happen |
| `files` | list or nil | ordered lowest-priority first; each entry `{ where = string, text = string }` or `{ where = string, path = string, required = boolean }` |
| `text` | string or nil | shorthand for one `files` entry with `where = "(text)"` |
| `path` | string or nil | shorthand for one `files` entry read through `port.fs` |
| `env` | boolean | default `true` when `opts.port.env` exists, `false` otherwise |
| `env_prefix` | string or nil | default `"PI_"`; the prefix scanned for typos, section 4.3 |
| `profile` | string or nil | forces the profile, above every other source |
| `override` | table or nil | setting name to value, the top layer |
| `port` | table or nil | `{ env = …, fs = … }`; required if `files` uses `path`, or if the environment layer is on |

`files`, `text` and `path` are not exclusive: the effective list is `files` in the order
given, then the `text` entry, then the `path` entry. Normally only one of the three is
used, and the order is stated so that using two is not a surprise. A `path` entry whose
`where` is omitted takes the path as its `where`; a `text` entry must name one, since
there is nothing else to call it.

`opts.profile` is applied as a value of the `profile` setting in the `override` layer,
which is what makes `config.explain(c, "profile")` name the layer that chose it. Two
consequences: passing `opts.profile` creates the `override` layer even when
`opts.override` is nil, and passing the profile twice -- once as `opts.profile` and once
as `override.profile` -- raises rather than picking one silently. `opts.profile` against
a schema with no `profile` setting raises too. And because the two are the same statement
made two ways, `override.profile` on its own selects the profile exactly as `opts.profile`
does -- otherwise `explain` would name the override as the layer that chose a profile that
was never selected, and a typo in it would run the defaults in silence.

Returns `c` when every layer resolved cleanly. Returns `nil, problems` when any layer did
not — **never a partial config**. A half-resolved configuration is exactly the thing
this module exists to prevent: the caller would run with a default it never chose and no
way to see that it had happened.

`problems` is a list, in the order found, of

```lua
{ code = "wrong_type", setting = "timeout", layer = "file:.malleable/agent.conf",
  where = "line 12", message = "timeout wants a number; got \"soon\"" }
```

`code` is from the closed set in section 5. `setting` and `where` may be nil (a file that
would not parse has no setting). `message` is one sentence, safe to show a person or a
model, and **never contains the value of a secret**, in any layer, for any code.

`opts` **raises** on: a non-table; an unknown key, naming it — a misspelt `overrides`
that silently does nothing is the failure mode this whole module is against; a `files`
entry that is neither `text` nor `path`; an `override` that is not a table; an `override`
naming a setting the schema does not have; an `override` whose value does not match the
setting's `kind`; and an `override` naming a secret (F7).

### `config.get(c, name) -> value`

The value that won, already coerced to the setting's `kind`. Returns the setting's
`default` when no layer supplied one, and `nil` when there is no default either — which
is why `get` returning nil is a legitimate answer and not an error.

**Raises** when `name` is not a string, when the schema has no such setting, and — this
is the one that matters — **when the setting is a secret**. Not "returns a redacted
string": raises, with `use config.secret to read a secret`. A general getter that can
return a credential is a general getter that will eventually put one in a log line, and
there is no call site where the author does not know which of the two they meant.

### `config.secret(c, name) -> value | nil`

The only way a credential leaves this module. Returns the string, or nil when the
environment did not supply one (including when the variable was set but empty, 5/F4).
**Raises** when `name` is not a string, when there is no such setting, and when the
setting is not declared `secret` — the check runs in both directions, so a host cannot
launder an ordinary setting through the secret accessor to dodge a redaction elsewhere.

`config.secret` does not log, does not cache, and does not memoise. Each call re-reads
from the resolved store; it does not re-read the port.

### `config.explain(c, name) -> record`

Why this value. The reason the module exists.

```lua
{ name = "timeout", kind = "number", value = 120,
  layer = "profile:review@.malleable/agent.conf", where = "line 18",
  raw = "120", secret = false, redacted = false,
  shadowed = { { layer = "file:.malleable/agent.conf", where = "line 4", raw = "60" },
               { layer = "builtin", where = "", raw = "60" } } }
```

`layer` is the winning layer's name; `where` locates it inside that layer (`"line 18"`,
the variable name for `env`, `""` for `builtin` and `override`). `raw` is the text the
layer carried, before coercion, or nil for `builtin` and `override`, which carry Lua
values. `shadowed` lists the layers that also had a value, highest first, so "why is it
60 and not 120" is one call to answer. A `set` boolean says whether any layer supplied
a value at all; when none did, `value`, `layer`, `where` and `raw` are all nil and
`shadowed` is empty.

For a secret: `value` and `raw` are nil, `redacted` is true, and `layer` is `"env"` with
`where` naming **which** variable was found — `"OPENROUTER_API_KEY"` — because knowing
which of two aliases won is the whole debugging value, and the name of a variable is not
its contents. `shadowed` for a secret lists the other aliases that were also set, by
name only.

**Raises** on an unknown name. Never raises for a secret: `explain` is safe on every
setting, which is what lets `report` be built out of it.

### `config.report(c) -> lines`

A list of strings, one per setting, sorted by name, for a person:

```
approve    ask                        builtin
budget     24                         builtin
key        (secret, set)              env PI_API_KEY
log_level  debug                      env PI_LOG_LEVEL
model      openrouter:z-ai/glm-5.3   file:.malleable/agent.conf line 3
timeout    120                        profile:review@.malleable/agent.conf line 18
```

A setting no layer supplied is rendered `(unset)` with `-` in the layer column, which
is also what a secret nothing supplied gets. A secret is rendered as `(secret, set)` or
`(secret, unset)` and never as anything else
— not a prefix, not a length, not a hash, not a run of asterisks whose count is the
length. Whether a credential is present is operationally necessary; how long it is, is
not. `report` cannot raise and cannot fail.

### `config.public(c) -> table`

Every non-secret setting as a fresh plain `name = value` table, safe to serialise, log,
put in a session file or hand to a subprocess. Secret settings are **absent**, not
present-and-nil, so a caller iterating the table cannot find a key it might try to fill.
A fresh table each call; mutating it changes nothing.

### `config.redact(c, v) -> v`

Scrubs every secret value known to `c` out of `v`, replacing each occurrence with
`"[redacted]"`.

- A string: every occurrence of every non-empty secret value is replaced. Plain text
  matching, never a pattern — a credential containing `%` or `-` must not become a Lua
  pattern.
- A table: a fresh deep copy with every string scrubbed, keys as well as values.
  Cycles are handled by identity, so a self-referential table terminates and keeps its
  shape. Depth is capped at 16; below the cap the value is replaced with `"<deep>"`.
  Non-string, non-table values pass through. Functions, userdata and coroutines become
  `"<function>"` / `"<userdata>"` / `"<thread>"`, because a closure can hold an upvalue
  nobody can scrub. "Capped at 16" means sixteen levels of table are copied and the
  seventeenth is replaced, so a table nested 20 deep yields `"<deep>"` after sixteen
  steps down.
- Anything else: returned as-is.

This is a comparison against the configured secrets, not a search for anything that
looks like a credential — the same rule `spec/provider.md` states for its own key, and
the reason a host can call `config.redact` on a provider failure before logging it.
A secret that is the empty string is skipped (it would match everywhere).

### `config.with(c, override) -> c2`

A derived config with one more explicit layer on top, for a nested run that wants a
smaller budget or a different model. `override` is a table of name to value, validated
exactly as `opts.override` is, and **raises** on a secret, an unknown setting, a wrong
type or a value outside the setting's `min`, `max` or `one_of`. An override is a Lua
literal at a call site the author can see, so it raises in `config.load` too; a value
out of range in a *file* or a *variable* is still the `out_of_range` problem of F10. Returns a fresh `c2`; `c` is unchanged, and neither can see the other's values.
`c2.layers` gains an entry named `override:2`, `override:3`, and so on, so `explain`
stays truthful on a config three derivations deep.

### `config.parse(text) -> tree | nil, problems`

The file format, exposed on its own so it is testable without a schema and usable by a
host that reads its own file. `tree` is

```lua
{ base = { { key = "model", raw = "…", line = 3 }, … },
  profiles = { review = { { key = "timeout", raw = "120", line = 18 }, … } } }
```

Each entry also carries `quoted = true|false`, because a quoted value is one element of
a list and a bare one is split on commas, and only the parser knows which it saw.
Entries in declaration order, `raw` unconverted. `parse` knows nothing about settings,
so an unknown key is not its problem; it reports only what is not a well-formed file.

### `config.profiles(c) -> names`

The profile names any file declared, sorted, as a fresh list. For a `--profile` flag
that wants to say what the valid answers were. Empty list when there are none.

## 4.1 The file format

Deliberately smaller than TOML and not a subset of anything. It is **text that is parsed,
never code that is run**: there is no expression, no interpolation, no include, no
environment substitution and no arithmetic, so a hostile config file has nothing to be
hostile with.

```
-- a comment runs to the end of the line
model   = openrouter:z-ai/glm-5.3
budget  = 12
tools   = read, write, shell
message = "  leading space kept, \"quoted\", and a literal \n"

[profile.review]
budget  = 4
timeout = 120
```

- A line whose first non-space characters are `--` is a comment. A comment is a whole
  line; there is no trailing comment, so a value may contain `--` without quoting.
- A blank line is nothing.
- `key = value`. `key` matches `[a-z][a-z0-9_]*`. Space around `=` is optional.
- A **bare value** is everything after the first `=`, with leading and trailing
  whitespace trimmed. Interior spaces are kept. No escape is interpreted; `\n` is a
  backslash and an `n`, and `${HOME}` is six characters of text.
- A **quoted value** is a double-quoted string with exactly four escapes — `\\`, `\"`,
  `\n`, `\t`. Anything else after a backslash is a problem, not a silently kept
  backslash. A quoted value keeps its whitespace and is never split on commas.
- `[profile.<name>]` opens a profile section; `<name>` matches `[a-z][a-z0-9_-]*`.
  Everything before the first section header is the file's base. Any other section
  header is `unknown_section`.
- A key repeated in the same section is `duplicate`, at the second line. Last-one-wins is
  how a config file develops two contradictory truths that both look right in a diff.
- Line endings LF or CRLF. A file over 4096 lines is `too_big`; nothing legitimate is
  near that, and it bounds the parser's work without a clock.
- A file that is not valid text — a NUL byte outside a quoted value — is `malformed`.

The format is not extensible from a config file. There is no directive that changes how
the rest of the file is read.

## 4.2 The layers, and how the profile is chosen

Layers, lowest priority first, and this order is the contract:

1. `builtin` — every setting's `default`.
2. For each entry of `files`, in the order given, **two** layers: `file:<where>`, then
   `profile:<name>@<where>` when a profile is selected and that file declares it.
3. `env`.
4. `override`, then any `override:n` added by `config.with`.

So a later file beats an earlier one, and within one file the selected profile beats that
file's own base. A user file under a project file therefore behaves the way a reader
expects: the project's plain settings beat the user's profile, because the project file
is later. Every layer that exists appears in `c.layers` with the number of settings it
actually won, including zero, so an empty layer is visibly empty rather than absent. A
file that was **not there** is not a layer: an optional `path` whose read came back
`not_found` contributes a warning and no entry, because there is nothing for an entry to
name. A file that failed to parse contributes none either, and the load fails anyway.

The profile itself has to be chosen before the profile layers can be applied, so it is
resolved first, from — highest first — `opts.profile` (or `override.profile`, which is
the same statement: section 4 says why), `PI_PROFILE` in the environment,
and the `profile` key in each file's **base** section (last file wins). Two consequences,
both deliberate:

- A profile section **may not set `profile`**. Doing so is `not_allowed`, at that line,
  **whether or not that profile is the one selected** -- the file that never settles
  should not be writable at all, not merely unreachable today. Otherwise selecting a
  profile could select another profile. There is no recursion here because the format
  has no way to express one.
- `config.explain(c, "profile")` works like any other setting and names the layer that
  chose it. The bootstrap is explainable too.

`opts.profile` naming a profile no file declares is `no_such_profile`, listing the names
that were declared. A profile named in the environment or a file that no file declares is
the same problem — a typo'd profile silently running the defaults is precisely the bug
class this module is against.

## 4.3 The environment layer

For each setting with an `env` name, the names are tried in order and the first one that
is **set and non-empty** wins. `explain` names which one. Every value is text and is
coerced by the setting's `kind`; a value that will not coerce is `wrong_type`, naming the
variable — with the raw text in the message, unless the setting is a secret, in which
case the message names the variable and says only that its value was not usable.

Then the **typo scan**: every variable whose name begins with `env_prefix` and which no
setting claims is `unknown_env`, listing the closest declared name. `PI_MODLE` doing
nothing at all, silently, forever, is the reason this scan exists. Variables claimed by a
secret are declared names and are exempt; a secret alias like `OPENROUTER_API_KEY` does
not begin with the prefix and is not scanned for either way.

The scan needs `port.env.names()`. When the port does not provide it, when the call
raises, or when `env_prefix` is the empty string (which would name every variable in the
process), the scan is skipped and `c.warnings` says so in one sentence. A missing
capability degrades to a stated gap, never to a silent one and never to a failure.

Each variable is read **at most once per load**, so the read the profile bootstrap makes
and the read the environment layer makes are the same read, and a warning about an empty
variable is said once rather than twice. Across loads nothing is cached: two loads read
the port again.

A value that will not coerce is reported wherever it was found, even when a higher layer
went on to win. A configuration that is right by accident -- because the broken line
happened to be shadowed -- is not one anyone should keep.

## 5. The failure modes

The important section. Every code below is one of `code` in a problem record; the set is
closed, and a code outside it is a bug in the implementation.

| code | when | what the caller sees |
| --- | --- | --- |
| `unreadable` | a `files` entry with `path` came back `nil, err` from `port.fs`, and the entry is `required`, or the error is anything other than `not_found` | the path, the port's code (`denied`, `too_big`, `timeout`, `unavailable`), and the port's sentence |
| `malformed` | `config.parse` could not read the file | the line number and what was expected |
| `duplicate` | the same key twice in one section | both line numbers |
| `unknown_section` | a section header that is not `[profile.<name>]` | the header and the line |
| `unknown_setting` | a file key no setting declares | the key, the line, and the closest declared name |
| `unknown_env` | a prefixed variable no setting claims | the variable and the closest declared name |
| `wrong_type` | text that will not coerce to the setting's `kind` | the setting, the layer, and the text — never for a secret |
| `out_of_range` | outside `min`, `max` or `one_of` | the setting, the value, and the allowed values |
| `not_allowed` | a secret in a file; `profile` inside a profile section; a setting with `file = false` in a file | the setting and the line, and for a secret **not the value** |
| `no_such_profile` | a profile was selected that no file declares | the name asked for and the names available |
| `missing` | a `required` setting no layer supplied | the setting and every environment variable that would have supplied it |
| `too_big` | a file over 4096 lines | the path and the count |

**F1 — no configuration file at all.** Not a failure. A `files` entry given as a `path`
whose read returns `not_found`, and which is not `required`, contributes nothing, adds a
one-line warning to `c.warnings`, and the load succeeds on defaults. A fresh checkout
with no config must start. This is the one filesystem error that is tolerated, and it is
tolerated only because `not_found` is unambiguous — `denied` and `too_big` mean a file is
there and something is wrong with reading it, which is a different thing entirely and is
`unreadable`.

**F2 — the file is there and unreadable.** `unreadable`, load returns `nil, problems`.
The harness does not fall back to defaults. Running with a default budget because a
config file could not be opened is how an agent quietly runs 24 steps when its author
wrote 4.

**F3 — the file will not parse.** `malformed`, with a line number, and **no settings from
that file are applied** — not even the ones on lines that parsed. Later files are still
parsed, so the caller sees every problem in one go rather than one per run.

**F4 — a variable is set but empty.** This is a rule about the *environment*. An empty
bare value in a file is a value: the empty string for kind `string`, an empty list for
kind `list`, and `wrong_type` for `number` and `boolean`. A variable is different because
nothing in a shell distinguishes "exported empty" from "meant to be unset".
Treated as unset, at every layer, for every kind,
and a warning names the variable. `PI_API_KEY=` exported by a shell script that failed
halfway is the single most common way a credential goes missing, and the honest answer is
"nothing supplied a key", not an empty bearer token and a confusing 401 from the far side.

**F5 — the environment holds a secret and a file holds the same setting.** `not_allowed`,
naming the setting and the line in the file. The file's value is **not** read into the
returned tree, is not in the problem record, and is not in the message. `config.parse`
alone will still return it — it has no schema and cannot know — which is why `load` is the
only function that reads a parse tree against a schema, and why a host that parses its own
file and hands the tree around is outside this module's guarantee. Said plainly because
Lua strings are interned and immutable: this module can decline to carry a secret, and it
cannot erase one from a process. It will not pretend otherwise.

**F6 — a secret's value will not coerce, or violates a rule.** The message names the
variable and says the value was not usable. No length, no prefix, no first character.

**F7 — an override supplies a secret.** `config.load { override = { key = "…" } }` and
`config.with(c, { key = "…" })` **raise**, and the raised message names the setting and
not the value. This is a programmer's mistake, not a world condition: the call site is in
Lua, the author can see it, and the fix is to name an environment variable in the schema.
Raising here also means the value never reaches a resolved store from which some later
`report` might be tempted to print it.

**F8 — a secret asked for by the ordinary getter.** `config.get(c, "key")` raises. See
section 4; it is worth two mentions.

**F9 — nothing supplied a required setting.** `missing`, and the message lists the
variables that would have supplied it, so a person can act on it without reading the
schema. For a secret this is the normal first-run experience and the message is the only
help they get: `no key: set PI_API_KEY or OPENROUTER_API_KEY`.

**F10 — a value is out of range.** From a file or a variable: `out_of_range`, listing the
allowed values in full for `one_of` and the bound for `min`/`max`. From an `override`, in
`config.load` or `config.with`: **raises**, for F7's reason -- the value is a Lua literal
at a call site whose author can see it. Never clamped. A budget of 0 silently becoming 1
is a lie about what is running.

**F11 — an unknown key.** In a file: `unknown_setting`, with the closest declared name by
simple edit distance, and the load fails. In the environment under the prefix:
`unknown_env`, same treatment. In `opts` or `override`: raises. Three different channels
for the same mistake, each matching where the mistake was made.

**F12 — a port raises.** Every call to `port.env.get`, `port.env.names` and `port.fs.read`
is made under `pcall`. A port that raises becomes `unreadable` (fs) or a warning naming
the variable and skipping that layer's read (env). A broken port must not take a load
down with a stack trace, because the load is the thing that runs before anything else and
its failure has to be reportable.

**F13 — a timeout.** `config` has no clock and no deadline. The only deadline it can meet
is the filesystem port's, which arrives as `err.code == "timeout"` from a read and
becomes `unreadable`, carrying that code so a caller can tell a slow disk from a denied
path. `config` never sleeps and never retries: a retry policy is a decision with a visible
consequence and it belongs where a reader is looking for it, which is not here.

**F14 — recursion.** The format has none: no include, no interpolation, no profile
selecting a profile. `config.redact` is the only recursive function in the module, and it
terminates on a cyclic table by identity and on a deep one at depth 16. A config file
cannot cause unbounded work in this module, which is what lets a host load an untrusted
one.

**F15 — an empty everything.** `config.load()` with no argument returns a valid `c` of
pure defaults, `c.layers` holding one entry, `c.profile` nil. An empty file text parses
to an empty tree and is not a problem. An empty schema (`config.schema {}`) loads, and
every `get` on it raises for an unknown name. Empty is a state, not an error.

## 6. What it must NOT do

- **It must not touch the world.** No `os.getenv`, `io`, `os.execute`, `os.time`,
  `os.date`, `os.clock`, `os.remove`, `os.rename`, `math.random`. A test reads
  `src/config.lua` and fails on any of them. `os.getenv` in particular: the environment
  arrives through a port or the environment layer is off.
- **It must not execute a configuration file.** No `load`, `loadstring`, `dofile`,
  `loadfile`, `require` of a path, no `setfenv`. The format has no expression to
  evaluate. A test reads the file for these names too, because this is the boundary
  where a config module becomes a code-execution vector.
- **It must not write anything.** No file is created, no default config is scaffolded,
  no cache is saved. A module that writes configuration is a module that can lose it.
- **It must not log.** It does not call `port.log` and does not `print`. Its output is
  the returned `c`, `c.warnings` and the problem list; the caller logs what it chooses,
  after passing it through `config.redact` if it likes. This is not fastidiousness: a
  module that both holds secrets and writes lines is one bad `%s` from disclosing one,
  and removing the line-writing removes the class.
- **It must not reach into another subsystem.** `src/config.lua` requires `src/port.lua`
  and nothing else in the tree — not `spec`, not `turn`, not `session`, not `provider`,
  not `approval`, not `compaction`, not either `tools_` module. A test proves it by
  reading the file for a `require` of a sibling.
- **It must not know what a provider is.** No table of vendor base URLs, no mapping from
  a model id to an endpoint, no header names, no wire shapes. `base_url` defaults to nil
  and the adapter supplies its own. A host wires the two together in one visible line —
  `provider.new(config.get(c, "model"), { key = config.secret(c, "key"), timeout =
  config.get(c, "timeout") })` — and that line is the only place the two shapes meet.
- **It must not read or mutate an agent declaration.** It never sees the table
  `spec.new()` built, never reads `agent.tools` or `agent.budget`, and never writes into
  one. Deciding that a config `budget` beats a declared `agent.budget` is the host's
  decision, made at the call to `turn.run` where a reader can see both.
- **It must not decide policy.** No retry, no fallback model, no "if the key is missing,
  try the other provider", no interactive prompt for a missing value. It reports what is
  there and what is not.
- **It must not carry state between loads.** Two configs in one process cannot see each
  other; the only module-level table is the weak-keyed value store, and it is keyed by
  identity. `config.with` derives without touching its parent.
- **It must not mutate what it was given.** `defs`, `opts`, `opts.override`, `files` and
  every table reachable from them are treated as read-only, including on the derivation
  path. What it returns is fresh.
- **It must not put a secret anywhere a reader could find it.** Not in `c`, not in
  `report`, not in `public`, not in `explain`, not in a problem, not in a raised message,
  not in `tostring`. The tests below are the proof, and they are the ones to write first.

## 7. The tests that would prove it

Happy paths, then the awkward ones. Names are the test names.

1. `defaults_alone_are_a_valid_config` — `config.load()` returns `c`, `get(c, "budget")`
   is 24, `explain(c, "budget").layer` is `"builtin"`, and that one layer says it won
   the six settings that carry a default.
2. `a_file_beats_a_default` — one file setting `budget = 12`; `get` is 12 and `explain`
   names the file and the line.
3. `the_environment_beats_a_file` — the same setting in both; `env` wins and `explain`
   names the variable, with the file in `shadowed`.
4. `an_override_beats_the_environment` — and `explain` puts both lower layers in
   `shadowed`, highest first.
5. `a_later_file_beats_an_earlier_one` — two `files` entries, same key; the second wins
   and both layers appear in `c.layers`.
6. `a_profile_beats_its_own_files_base` — `[profile.review]` overrides the base of the
   same file, and does not touch the other file.
7. `the_profile_is_chosen_from_the_environment` — `PI_PROFILE=review` selects it, and
   `explain(c, "profile").layer` is `"env"`.
8. `every_kind_reads_back_from_text` — string, number, boolean (`true`/`FALSE`/`1`/`0`)
   and list (`a, b ,c` → three trimmed elements) from both a file and the environment.
9. `a_quoted_value_keeps_its_spaces_and_is_never_split` — `"a, b"` is one list element,
   and leading whitespace survives.
10. `parse_returns_declaration_order_and_line_numbers` — on a file with two sections.
11. `report_has_a_line_per_setting_sorted_by_name` — and cannot raise on any config.
12. `profiles_lists_what_the_files_declared` — sorted, fresh, empty when none.
13. `with_derives_without_touching_its_parent` — `config.with(c, { budget = 2 })`; the
    parent still reads 24, the child reads 2, and `c2.layers` ends `override:2`.

Adversarial from here down. These are the ones worth writing first.

14. `a_secret_is_never_in_the_config_table` **(adversarial, secrets)** — load with
    `PI_API_KEY` set, then walk `c` recursively to any depth, concatenating every string
    key and value found, and assert the credential does not appear. Also assert it does
    not appear in `tostring(c)`, in `config.public(c)` serialised the same way, in any
    line of `config.report(c)`, or in `explain(c, "key")` walked the same way.
15. `the_ordinary_getter_refuses_a_secret` **(adversarial, secrets)** —
    `config.get(c, "key")` raises, the message names the setting and `config.secret`, and
    the message does not contain the value.
16. `a_secret_in_a_file_is_refused_and_not_echoed` **(adversarial, secrets)** — a file
    line `key = sk-live-abcdef` gives `not_allowed`; the problem's `message`, `where` and
    every other field are searched for `sk-live-abcdef` and it is in none of them, and
    `config.get`/`config.secret` both report nothing was supplied.
17. `an_override_that_supplies_a_secret_raises_without_echoing_it` **(adversarial,
    secrets)** — F7, for both `load` and `with`, and the raised message is searched for
    the value.
18. `redact_removes_a_secret_from_a_string_a_table_and_a_key`
    **(adversarial, secrets)** — including a credential used as a table key, and a
    credential containing `%`, `-` and `.`, which proves the match is plain and not a Lua
    pattern.
19. `redact_terminates_on_a_cycle_and_a_deep_table` **(adversarial, recursion)** — a
    self-referential table returns in bounded time with its shape intact; a table nested
    20 deep yields `"<deep>"` sixteen levels down; a function value becomes
    `"<function>"` and a coroutine `"<thread>"`.
20. `an_empty_secret_variable_is_unset` **(adversarial, empty input)** — `PI_API_KEY=""`
    gives `config.secret(c, "key") == nil`, a warning naming the variable, `report`
    showing `(secret, unset)`, and no bearer token of `""` anywhere.
21. `a_secret_alias_says_which_one_won` **(adversarial, secrets)** — both `PI_API_KEY`
    and `OPENROUTER_API_KEY` set; `explain(c, "key").where` names the first, `shadowed`
    names the second by name only, and neither value appears.
22. `a_missing_optional_file_is_not_a_failure` **(adversarial, missing file)** — the fs
    double returns `not_found`; load succeeds on defaults with one warning.
23. `a_denied_file_is_a_failure` **(adversarial, missing file)** — the same read
    returning `denied`, `too_big` or `timeout` gives `unreadable` carrying that code, and
    `load` returns nil. Paired with 22 in the same test file, because the pair is the
    contract.
24. `a_required_missing_file_is_a_failure` — `{ path = …, required = true }` and
    `not_found` gives `unreadable`.
25. `a_file_that_will_not_parse_applies_none_of_itself` **(adversarial)** — a file whose
    line 5 is garbage and whose line 1 sets `budget = 12`; `load` fails and, on a second
    load without that file, `budget` is 24 — proving nothing leaked through.
26. `a_typo_in_a_file_key_is_not_silence` **(adversarial)** — `budgt = 4` gives
    `unknown_setting` naming `budget` as the closest.
27. `a_typo_in_a_prefixed_variable_is_not_silence` **(adversarial)** — `PI_MODLE` gives
    `unknown_env` naming `model`; `PI_API_KEY` and an unprefixed variable do not.
28. `the_typo_scan_degrades_to_a_warning` **(adversarial)** — an env port with `get` but
    no `names` loads cleanly, with one warning saying the scan was skipped, and does not
    raise.
29. `a_duplicate_key_is_a_problem_not_last_wins` **(adversarial)** — two `budget` lines in
    one section give `duplicate` with both line numbers; the same key in the base and in a
    profile is legal and is not a duplicate.
30. `an_out_of_range_value_is_never_clamped` **(adversarial)** — `budget = 0` gives
    `out_of_range`; `approve = maybe` lists all three allowed values; neither load
    returns a config.
31. `a_profile_cannot_select_a_profile` **(adversarial, recursion)** — `profile = other`
    inside `[profile.review]` gives `not_allowed` at that line, and no profile switching
    occurs.
32. `a_profile_nobody_declared_is_named_and_refused` **(adversarial)** —
    `opts.profile = "revew"` gives `no_such_profile` listing `review`, and the same from
    `PI_PROFILE`.
33. `a_config_file_is_text_and_never_code` **(adversarial)** — there is no shell port in
    this module's world, so the filesystem double is the only one there is to check: it
    must record the one read and no write. A file containing
    `model = os.execute("touch /tmp/x")`, `budget = 2 + 2` and
    `workspace = ${HOME}/etc` loads with those exact strings as values (and `budget` as
    `wrong_type`), nothing is executed, and the fs and shell doubles record nothing.
34. `a_hostile_file_cannot_cost_unbounded_work` **(adversarial)** — 5000 lines gives
    `too_big`; a 4000-line file of comments parses to an empty tree; a line 100 kB long is
    parsed or refused but does not hang.
35. `a_port_that_raises_becomes_a_problem_not_a_stack_trace` **(adversarial)** — an
    `env.get` and an `fs.read` that both `error()` give a warning and `unreadable`
    respectively, and `load` returns normally.
36. `a_missing_port_raises_but_a_missing_value_does_not` **(adversarial)** — asking for
    the environment layer with no `port.env` raises, naming the field; a config with the
    layer wired and every variable unset loads on defaults. The two-channel convention,
    checked in both directions.
37. `wrong_shapes_raise_and_name_the_argument` **(adversarial)** — `config.load(7)`,
    `config.load { overrides = {} }`, `config.get(c, nil)`, `config.get(c, "nope")`,
    `config.secret(c, "budget")`, `config.schema { { name = "x" } }` and a schema with two
    settings claiming `PI_MODEL` each raise, and each message names what was wrong.
38. `a_secret_schema_that_breaks_a_rule_raises` **(adversarial, secrets)** — a secret with
    a `default`, one with `kind = "number"`, one with no `env`, and one with `one_of` each
    raise at `config.schema`, before any value exists to leak.
39. `two_configs_in_one_process_cannot_see_each_other` **(adversarial)** — two loads with
    different environments and different schemas; each `get` and `secret` answers from its
    own, and dropping one does not disturb the other.
40. `nothing_it_was_given_is_mutated` **(adversarial)** — deep-compare `defs`, `opts`,
    `opts.override` and each `files` entry before and after `load`, `with`, `public` and
    `redact`.
41. `the_module_touches_nothing_real` **(adversarial)** — read `src/config.lua` and fail
    on `os.getenv`, `io.`, `os.execute`, `os.time`, `os.date`, `os.clock`, `math.random`,
    `load(`, `loadstring`, `dofile`, `loadfile`, `print(`.
42. `the_module_requires_no_sibling` **(adversarial)** — read `src/config.lua` and fail on
    a `require` of anything in the tree but `port`.

## 8. Where the tests live

`src/config.lua` is the whole module and `test/config_test.lua` the whole suite: 42
functions, named as section 7 names them, returned as a table for a plain runner, all
passing under both `lua` and `luajit`. The suite wires its own environment and
filesystem doubles rather than taking them from `src/double.lua`, because
`src/double.lua` has no environment port yet -- see section 2. When `spec/port.md`
adopts one, the two doubles at the top of the test file are what `double.env` and a
one-call `double.fs` owe, and the suite should take them from there instead.
