# subshell — a real shell, decided in writing

`bin/subshell.lua`. Status: implemented, `test/subshell_test.lua` passing under `luajit`
and `lua`. A host file: it names `os` and `io`, and nothing under `src/` requires it.

## What it is for

`bin/world.lua` runs no commands on purpose: a host that runs whatever a model writes is
a decision somebody should make in writing, not a default. This file is that decision,
made once, for one use: the long-task eval (`scripts/eval-long.lua`, `docs/spec/behaviour.md`,
"Evaluating"), which sends an agent out for hours to make a TypeScript program from
nothing, with `node` and `npm` on the path and the network open. Nothing else wires it.

## The port

    local subshell = require "subshell"
    local sh = subshell.port(root, { env = { PATH = "...", HOME = root }, log = fn })
    sh.run(argv, opts) -> result | nil, err

The shell port of `docs/spec/port.md`, exactly: `argv` a list of strings, `opts` nil or
`{ cwd, stdin, timeout }`, `result = { code, out, err, timed_out }`, `nil, err` only when
the command could not run at all. It differs from the doubles in one way only: the
command really runs, as a child process of this one.

What the host decides, and how:

* **Where.** The child runs in `root`, or in `opts.cwd` under it. A `cwd` that is absolute,
  holds `..`, or does not exist is `denied`. The child can still name any path on the
  machine; a shell is a shell, and this file does not pretend otherwise.
* **With what environment.** The child gets `cfg.env` and nothing else (`env -i`). The
  eval passes `PATH` and a `HOME` under `root`. `OPENROUTER_API_KEY` is in this process's
  environment and never in the child's, so a model that writes `curl` with `$OPENROUTER_API_KEY`
  sends an empty header. The test proves it with `HOME`, which every process has.
* **For how long.** `opts.timeout` seconds (default 30) through `perl -e 'alarm'` around
  an `exec`, because macOS has no `timeout`. On the deadline the child is killed and the
  call answers `nil, { code = "timeout" }`; its output is lost, as the contract says.
* **What comes back.** `out` and `err` whole, from files; the exit status from the child's
  own `$?`, so it is the same number under Lua 5.1, LuaJIT and 5.4. Exit 127 with nothing
  else is `not_found`.
* **What is kept.** `cfg.log(line)` is called once a command, with the argv as one line,
  the exit status and the seconds it took, before the result is returned. The command
  line is shown to a person in the eval's journal; it is not put in a span (rule 8 in
  `docs/spec/trace.md` keeps command lines out of traces, and the tool above this port
  already reduces one to its terms).

## What it must not do

* Run with the parent's environment, or pass any key through.
* Answer a non-zero exit as an error, or a timeout as a result.
* Change directory outside `root`.
* Be required by anything under `src/` or `console/`.
