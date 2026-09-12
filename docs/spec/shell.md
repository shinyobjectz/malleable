# shell — a shell, in Lua, over a filesystem in Lua

`src/shell.lua`. Contract. Amend this before the code diverges from it.

## What it is for

`bin/malleable.lua` is twenty lines and is the only file in this tree that touches the
real world; not one of the modules names `io` or `os`. So the harness is already a pure
function of its ports, and what stops it running inside any embedded Lua is not the
harness — it is that somebody has to supply a **world**.

`double.fs` already supplies half of one: a real in-memory filesystem with files,
directories, a write log, a removal log, read-only mode and the same path rule the real
port applies. `double.sh` is the other half and is a **lookup table** — every command has
to be scripted in advance, which is right for a test and useless for an agent that is
supposed to work something out.

This is the executor that closes it. `command.parse` already answers the simple commands
in a line with their argv, redirections and connectors; this runs them.

## It is called `shell`, and never `bash`

Eighteen commands, and every refusal names all eighteen.

A thing that is ninety per cent of bash is wrong in ways nobody can predict, which is
worse than a thing that is obviously small and says so. A command this does not have
comes back as **exit 127 with the list**, because a refusal a model can read is a fact it
can act on and a silent approximation is not (rule 4, one layer down).

Two places where the honest small thing differs from the real one, stated rather than
hidden:

* **`grep` takes a fixed string, not a regular expression.** Lua patterns are not POSIX
  ones, and a `grep` that accepted `\d` and matched a literal `d` would be lying about
  what it did.
* **There is no environment.** `FOO=bar cmd` parses and has no effect, because pretending
  it set something is a lie a script could come to depend on.
* **A here-document is refused, by name.** Its body is on the lines *after* the command
  and this reads one line; taking `<<EOF` as a redirect to a file called `EOF` and the
  body as further commands would be a wrong answer dressed as a right one.
* **Three flags are accepted and change nothing**, and that is a fact about this
  filesystem rather than a shrug: `ls -a` (nothing here is hidden), `ls -1` (the output is
  already one name per line) and `find -type` (everything here is a file). Named here so
  they are a promise rather than a coincidence somebody later relies on.

## Determinism is the point, not isolation

Isolation is what a sandbox is usually for. The reason this one matters is that the same
script over the same filesystem produces **the same bytes every time**: every listing
sorted, no clock, no randomness, no environment, no host.

That is the precondition for everything downstream. Two evals are comparable only if the
world was identical, and a change can be attributed to a cause only if nothing else moved.

## The commands

| | |
| --- | --- |
| `ls [-l] [-R] [path]` | sorted; a file names itself |
| `cat [path…]` | or standard input |
| `echo …` | joined with single spaces |
| `pwd`, `cd [dir]` | the working directory, for the rest of the line |
| `mkdir [-p] path…`, `touch path…` | |
| `rm [-r] [-f] path…` | a directory needs `-r`, and says so without it |
| `cp [-r] src dst`, `mv src dst` | a destination that is a directory takes the basename; a directory without `-r` is refused |
| `wc [-l] [-w] [-c] [path…]` | |
| `head [-n N]`, `tail [-n N]` | |
| `sort [-r] [-u]` | |
| `grep [-i] [-n] [-r] [-l] [-v] [-c] pattern [path…]` | fixed string; exit 1 when nothing matched |
| `find [path] [-name glob]` | `*` and `?`, and neither crosses a `/` |
| `true`, `false` | |

Connectors: `|`, `&&`, `||`, `;`. Redirections: `<`, `>`, `>>`.

**An unknown flag is an error, never ignored.** A shell that quietly drops `-r` is a shell
that tells you it deleted a tree when it did not — and the first version of this one did
exactly that in `cp`, accepting `-r`, copying nothing, and reporting success. A flag that
is accepted must either do its job or be in the list of three above.

## The shape

    shell.line(fs, text, cwd)  →  { code, out, err, cwd }
    shell.port(fs, opts)       →  a `p.sh` of spec/port.md
    shell.commands()           →  the eighteen, sorted, a fresh list each read
    shell.has(name)            →  boolean

`shell.port` accepts `{ "sh", "-c", line }` and runs the line; any other argv is one
simple command. A direct argv is **quoted back into a line** rather than executed
separately, so `{ "grep", "a b", "f" }` and `sh -c 'grep "a b" f'` cannot come apart —
one grammar reads every path in.

`opts.strict` makes a missing command a port error instead of exit 127. Off by default,
because `spec/port.md` is explicit that a non-zero exit is a **result**.

## What it must NOT do

* Name `io` or `os`, spawn anything, open a socket, or read a clock or an environment.
* Approximate a command it does not have.
* Resolve a path any way but the filesystem port's rule. `..` is resolved textually and
  the result is checked, so a path that climbs out of the workspace is refused by the
  same rule rather than by a second one that could drift from it.
* Raise on a malformed line. A bad command is a thing that happened and comes back as a
  result with a code and a sentence.

## What it promises

`spec/shell.feature`, and it **runs**. 18 scenarios, under `lua` and under `luajit`.

The list that used to be here was prose: a set of bullets saying what a test would show,
enforced by nobody. A hundred and four of them sat across these files and an audit of five
found eight that were not true — including a gate this spec described in detail that the
code simply did not have. A promise you cannot run is a promise you find out about later.

The distinction the feature file buys, which prose cannot:

* a scenario that **fails** means this spec says something FALSE. A bug, and never allowed.
* a scenario that is **undefined** means this spec is AHEAD OF THE CODE. Legal, counted in
  `spec/OWED`, and ratcheted so the number goes down and never up.

`tools/spec-check.sh` runs them all and prints the counts; `test/spec_test.lua` runs them
inside the ordinary suite, because a promise that only runs in a script somebody has to
remember to call is the same failure one level up.

What stays in this file is everything that explains a **decision** — why the reader lives
where it does, what was refused and on what argument, which surprises were kept. A feature
file cannot carry an argument, and a repository that deletes its arguments relitigates them
every six months.
