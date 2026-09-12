# command — what a command line DID, as a term, so the command itself never travels

`src/command.lua`. Contract, and the ruling that placed it (mar-eaz6, mar-7qd3).

## What it is for

A run's most behaviourally loaded moment is the one its trace is blindest to. The tool
call is recorded — `execute_tool shell`, ok, 412 ms — and what the agent actually did,
`git status`, `./run-tests.sh`, `rm -rf build`, is nowhere, because that string is a
payload and rule 8 forbids a span carrying one.

Retiring rule 8 to fix that would be the wrong trade: a span exporter's whole job is to
send what it is given somewhere else, and a command line carries paths, hostnames,
sometimes a token. So the payload stays where it already is — inside the tool, at the
moment of the call — and only a **term** leaves.

    "cd app && npm test"        →  malleable.act = "tests"
    "git status --porcelain"    →  malleable.act = "inspects"
    "rm -rf build"              →  malleable.act = "deletes"
    "curl https://x.example"    →  malleable.act = "connects"

Rule 8 gets *stronger*, not weaker: the span holds a behaviour rather than a string
somebody has to redact later.

This is the direction ruled in `spec/observe.md`. A trace is parsed **into** behaviour;
Gherkin is not a format for logs. A parsed command line is the same move one level down.

## The ruling: the reader lives in the tree, in Lua

Three placements were live. The answer is the first, with the third as a bounded escape
hatch and the second refused outright.

**1. In the tree, in Lua. This one.** `src/command.lua` requires nothing, runs under `lua`
and `luajit`, and every embedder gets the same reader.

**2. At the host seam, in Rust, over colm-suite.** Refused. It would make the behaviour
vocabulary **differ by embedder** — a term this checkout can answer and a bare `lua`
cannot — which is exactly what the adopted/minted split in `spec/trace.md` exists to
prevent, and the same argument that kept the fourteen `malleable.*` attribute names out
of `.monty`. A tree published on its own cannot have a vocabulary only one host can speak.

**3. Both, with the Lua reader as the floor.** Allowed, bounded: a host may answer a term
**more precisely**, never a term the tree does not define, and never a term where the tree
answers a different one. A host that disagrees with the floor is a host with a bug.

Three further reasons the first is right, beyond the vocabulary argument:

* **Colm and Ragel generate C.** This tree has no C modules by construction and targets
  Lua 5.4 within the LuaJIT 5.1 subset. Adopting them would put a build step between the
  harness and its own behaviour, which is the opposite of *embed this anywhere in Lua*.
  Where colm-suite does belong in this repository is `docs/PAGES.md` tier three —
  transformation of real source, a `ta_rewrite` target on the colm toolchain. That is a
  different job and the two should not be conflated because they share a tool.
* **The precedent is already set.** `src/gherkin.lua` is a real reader that requires
  nothing and carries its own sixty-line JSON decoder for the same reason.
* **The grammar needed is small, and the large part of bash is not needed at all.** What
  this reader answers is *which programs ran, in what shape*. Expansion, substitution,
  here-documents and job control change what a command **does**, not which commands are
  **named**, and a reader claiming to know what `$(cat x)` evaluates to would be lying.
  See "What it must NOT do".

## Two halves, and only one of them can be wrong

The split is the whole design, and it is what keeps `mar-4o07` satisfied.

**The parse is TOTAL and structural.** `command.parse(line)` answers every simple command
in the line with its argv, its redirections and the operator that joined it to the next.
It never guesses meaning. On a line it cannot parse it says where it stopped, and that is
a defect in the grammar.

**The mapping is PARTIAL and measured.** `command.act(parsed)` answers a term from the
closed set below, or nothing. Nothing is a **gap**: counted, reported, and filed against
the vocabulary — never repaired by widening a pattern (`spec/observe.md`, "Gap
discipline"; mar-3xf1).

This is why a program table here is not the phrase reader `mar-4o07` bans. That rule is
about **prose**, where the corpus is written in the compiler's own dialect and a phrase
reader passes its tests by tautology. Here the parse is over a closed formal language and
is total; only the naming is partial, and its partiality is a number on the report rather
than a silence. A run whose commands are 40% unnamed says so.

## The terms

One `malleable.act` per simple command, from a set that is closed and stays small. The
test of a term is that a Then line can **fail** on it.

| term | what it means |
| --- | --- |
| `inspects` | reads state without changing it |
| `reads` | reads a file's contents |
| `writes` | creates or changes a file |
| `deletes` | removes a file or a directory |
| `tests` | runs a test suite |
| `builds` | compiles, bundles or packages |
| `installs` | changes the dependency set |
| `commits` | records a change in version control |
| `publishes` | pushes, deploys or releases |
| `connects` | opens a network connection |
| `escalates` | runs as another user |

`publishes`, `escalates`, `deletes` and `connects` are the ones worth having. An agent
that inspects a lot is working; an agent that publishes is doing the thing nobody can undo
for it, and no token count says so.

## The shape

    command.parse(line)  →  { { argv = {...}, redirects = {...}, joined = "&&" }, ... }
                         →  nil, why, where     (a line the grammar cannot place)

    command.act(parsed)  →  "tests" | nil       (one simple command)
    command.acts(line)   →  { acts = {...}, unplaced = n, commands = n }

`acts` is what the shell tool calls. `unplaced` is the number that goes on the report.

The table of programs is partial on purpose, and widened only after reading a report.
Widened 2026-09-11 from the long-task eval (`evals/long-task.feature`), where every
install, test and build the model ran was unplaced: `npm i`, `npm add` and `npm uninstall`
install; `npm init` and `npm pkg` write; `npx <program>` and `npm exec <program>` are named
by the program, exactly as that program is on its own (`npx vitest run` tests, `npx tsc
--noEmit` builds). `node <script>` stays unplaced: a script is a script.

## What it must NOT do

* **Evaluate anything.** No expansion, no substitution, no glob, no arithmetic, no
  environment. `rm -rf $TARGET` is a `deletes` with an argument this reader cannot know,
  and saying otherwise would be inventing a fact about the run.
* **Answer a term it is not sure of.** A gap is the honest answer and is the one that gets
  the vocabulary fixed.
* **Let the command line out.** Nothing it returns is a substring of its input. That is
  checkable, and it is checked.
* **Read a clock, a file or a port.** A line in, a table out.

## What it promises

`spec/command.feature`, and it **runs**. 11 scenarios, under `lua` and under `luajit`.

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
