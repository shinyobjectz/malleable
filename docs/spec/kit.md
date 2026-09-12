# kit — a capability a workspace adds, said in the vocabulary and scored by the wall

`src/kits.lua` (the registry and the install), `src/declare.lua` (the lines), `agent.kit`
on the prefix. Contract, written 2026-09-12 from `docs/ergonomics.md` ("More extensible
than today"), before the code; amendments are said where they happened.

## What it is for

The is vocabulary is closed, and that is right: a line the runner cannot read is a line
the wall cannot score. But the vocabulary's reach lines are the harness's own — the files
tools, the shell, the plan, the history, the authoring folder — and a workspace that wants
its agent to keep a calendar, or a queue, or a ledger of its own has today two doors, both
wrong for the job: declare the tools one by one in the feature with Lua bodies in doc
strings, which is a kit nobody named; or edit `src/` to add the lines, the tools, the
doubles and the reach scoring, which is a change to the harness for one workspace's noun.

A **kit** is the thing `files`, `shell`, `plan`, `history` and `authoring` already are
informally, written down as a contract a workspace can meet: the lines that say it, which
way each moves reach, the tools it installs, the lines a scenario says its world and reads
its result with, and how it is said back. A kit is one Lua file. Loading it puts its lines
in the vocabulary for the declarations of that process; using it puts its tools on one
agent; the wall scores its lines by the reach the kit declared, because reach is the one
thing a kit says about itself that the harness enforces rather than trusts.

## Vocabulary

Checked with `monty onto check`: `kit` was free. `told` is the kit's word for what its
lines told it, and is a plain table.

* a **kit** is a table of the shape below, from a file or handed to the prefix.
* **to load** a kit is to put its lines in the vocabulary; **to use** it is to install its
  tools on an agent, with what its lines told it.
* **the registry** is the process's table of loaded kits, by name, like the built-in
  vocabulary and beside it.

## The shape

    return {
      name  = "calendar",
      about = "events the agent keeps, and two tools over them",

      -- the is lines: each says what one line tells the kit, and which way it moves reach
      is = {
        { expr = "it keeps a calendar", reach = "widens",
          about = "the book and agenda tools over a store of events",
          tells = function (told) told.keeps = true end },
        { expr = "the calendar holds at most {int} events", reach = "narrows",
          about = "book refuses an event past this many",
          tells = function (told, n) told.limit = n end },
      },

      -- what using it declares: through the surface, running nothing (rule 2)
      install = function (told, agent)
        agent.store "events" { about = "one event a row",
          columns = { title = agent.string "what", at = agent.string "when, as YYYY-MM-DD HH:MM" },
          sort = "at" }
        agent.tool "book" { about = "Book an event.", args = { ... }, run = function (c) ... end }
        agent.tool "agenda" { about = "Every event, in order.", run = function (c) ... end }
      end,

      -- the lines a scenario says its world and reads its result with
      steps = {
        { expr = "the calendar has {string} at {string}", given = function (c) ... end },
        { expr = "the calendar holds {string}",           then_ = function (c) ... end },
      },

      -- how it is said back when it was used from Lua (from a feature, its lines are kept)
      says = function (told) return { "it keeps a calendar", told.limit and ("the calendar holds at most " .. told.limit .. " events") or nil } end,
    }

Rules of the shape, each refused by name at load:

* `name` is a word; `about` is a sentence.
* `is` holds at least one entry; each has an `expr` that compiles (`docs/spec/gherkin.md`),
  a `reach` of widens, narrows or neither, an `about`, a `tells` function, and may say
  `gate = true`: a line an agent may add and never remove or replace, as `asks first` is
  (added 2026-09-12 for the modes kit's start line, whose replacement is a widening the
  reach words cannot score). A narrowing line may also give `narrower(old, new)`, a
  function of the two lines' arguments answering true when the new line narrows further:
  the wall otherwise scores any replacement of a narrowing line as a widening, which is
  right for a glob or a limit and wrong for a list a mode shortens (found by the real-model
  attack run, 2026-09-12: the author could not take one tool out of a mode). An
  expression that reads as a built-in line, an is line, or a line of another loaded kit
  is refused, naming both.
* `install` is a function of `(told, agent)`, where `agent` is the declaration surface
  (`cli.surface`: `tool`, `store`, `skill`, `every`, `uses`, `step`, the argument types).
  It declares and returns; a tool's body runs when the model calls it, as every body does.
* `steps` is a list, possibly empty, of `{ expr, given }` or `{ expr, then_ }`, the shape
  `agent.step` takes, and each is checked as `agent.step` checks it (one phase, no when).
* `says` is optional, a function of `told` answering a list of line texts.
* `rails` (added 2026-09-12) is optional, a list of feature paths beside the kit file: the
  doubles scenarios its rail survives, below. A kit whose `install` sets a hook and names
  no `rails` is refused at use, by name. `delegate` says what a delegate under the kit
  starts with, `"fresh"` or `"inherit"`, and a kit that names `rails` must say it.

Nothing else is read. A kit file is compiled with what a body gets (`docs/spec/declare.md`,
"Lua in a doc string"): `pairs`, `string`, `table`, `math` and the rest, no `io`, no `os`,
no `require`, no globals. It returns the table. This is code from the workspace, and it is
trusted exactly as a Lua declaration in the same workspace is: it runs at declaration
time to declare, under the same sandbox the declaration runs under.

## The lines

Two is lines belong to the harness:

| | declares |
| --- | --- |
| `it uses the kit {string}` | loads the kit file at that path (through the loader's `read`, beside the feature, as a delegate's file is read) and puts its lines in the vocabulary; **widens** |

and each kit's own lines join the is phase for the process once the kit is loaded, with
the reach the kit gave them. `--steps` lists them after the built-in is lines, each marked
with its kit's name.

A kit's lines are read only after the kit line that loads it, whatever their order in the
Background: the loader reads every `it uses the kit` line first, then the rest. (Chosen
while designing it: the alternative, requiring the kit line to come first, would make a
file's meaning depend on line order, which the plan the lines are gathered into exists to
avoid.)

A loaded kit stays loaded for the process, by name. Loading a second kit with the same name
from a different file is refused, naming both files: two workspaces that each call their
kit `calendar` are two processes. Loading the same file again is nothing, and so is loading
the same text from another path (amended 2026-09-12: two agents in one folder say the same
kit by the same relative path, and an eval's author reads the tree's copy while the file it
edits reads the workspace's; the text is what makes a kit the same, trailing whitespace and line endings aside: a doc string drops the final newline the file has).

## Using one

From a feature, the kit's lines in the Background use it: `it keeps a calendar` records
`told.keeps = true` and, at build, the kit is installed once with everything its lines
told it. From Lua, `agent.kit(def, told)` loads the table and installs it with `told`.
Either way the agent records the kit on `a.kits[name]` as every built-in kit records
itself (`docs/spec/say.md`): what it was told, the lines that told it, and the tools it
put on the agent.

A kit's steps are declared on the agent as `agent.step` would declare them, marked as the
kit's, so a scenario may say `Given the calendar has "standup" at "2026-09-14 09:00"`. A
`--check` does not report a kit's step nobody used: a kit's steps are its vocabulary, not
the file's promises.

The world a kit's steps and tools share is the one every step and tool has: a given step
writes the scenario's world (a store's rows, a file), a tool body reaches the same through
`c` (`c.store`, `c.fs`), a then step reads what the run left. A kit that keeps its state in
a declared store gets the store's own lines for free (`the store events holds:`).

## Reach, and the wall

The wall (`docs/spec/declare.md`, "Reach, and the wall") reads a kit's line as it reads
any is line: `declare.is_line` answers the reach the kit gave it. `it uses the kit` widens,
so an agent editing itself cannot load a kit without a proposal, and a kit's widening line
needs one too. What the wall cannot check is whether the kit told the truth about a line's
reach; that is the kit author's word, which is the same word the harness takes from a Lua
body. The line the wall holds is that reach is declared per line and never inferred.

## What a rail must survive

A hook is a rail: a `call` hook that refuses, a `start` hook that sets state. Every fault
the modes kit had on 2026-09-12 was found by a real-model run and none by the doubles,
because the doubles ran one agent per scenario and the faults needed two users of the kit
in one process, a nested run, or a scenario that ran nothing. So a kit that carries a
rail ships the scenarios that would have found them, named in `rails`, verified on the
doubles by `test/kit_test.lua`, and each is a scenario, not a sentence:

| the rail survives | the scenario |
| --- | --- |
| two users of the kit in one process, one running inside the other | an author in the kit verifies a notebook in the kit, then acts on its own state |
| a nested run | the same: the Then line reads the outer agent, not the nested one |
| a check-only scenario | a given that asks for state, `When the declaration is loaded`, then a run that starts clean |
| a delegate | a helper under the kit does what its own file says, and `delegate` states which |
| trust trusted | `its trust is trusted`, and the rail holds |
| an always-allow policy | `it may always call <tool>`, and the rail holds |
| a deny policy | `it may never call <tool>`, and what that pins is stated |
| a beat | a run a beat starts is a run, and starts as one (for a kit with `every`) |

The rule that goes with the list, in `docs/spec/behaviour.md`: every fault a real run
finds becomes a doubles scenario first, and the fix second. The first draft of the modes
kit is kept as `test/fixtures/modes-v1.lua` and fails `evals/modes-rails.feature` on
the two-users case and the check-only case, which is the proof the scenarios find what
the run found.

## Said back

`say.render` says a used kit back as the lines that used it, verbatim, when it came from a
feature; from Lua, as what `says(told)` answers, or as one unsaid sentence naming the kit
when the kit has no `says`. `it uses the kit "path"` is said first when the kit came from a
file.

## What it must NOT do

* Run a tool body, a step body or a `tells` at load. Loading compiles the file and reads
  the table; using runs `install`, which declares.
* Let a kit reach `io`, `os`, `require` or a global.
* Let a kit redefine a built-in line, an is line, or another kit's line.
* Infer a line's reach. A kit says it, per line.
* Let a kit's step write the result or read the ports: the same context rule as every step.

## The tests that prove it

`test/kit_test.lua`, under `lua` and `luajit`:

* a kit file with each rule broken is refused at load, naming the rule;
* the showcase kit loads; its two lines match after loading and not before; using it puts
  its store and tools on the agent, with what the lines told it;
* a scenario says the world with the kit's given step, runs the kit's tool, and reads the
  result with the kit's then step, on the doubles;
* the line's reach is what the kit said, through `declare.is_line`;
* `--check` is silent about a kit's unused step;
* the same file loaded twice is nothing; a second kit with the same name from another
  file is refused naming both;
* said back, a feature that uses a kit gives its lines verbatim and applies again to the
  same declaration; used from Lua, `says` gives the lines and a kit without `says` is one
  unsaid sentence;
* `showcase/20-kits.feature` verifies (`test/showcase_test.lua` already holds every
  showcase);
* every kit under `library/` and `showcase/kits/` loads; one that names `rails` says
  `delegate`, and each rail feature verifies on the doubles; a kit that sets a hook and
  names no rails is refused by name, and one that names rails without `delegate` is too;
* the first draft of the modes kit, swapped in for the real one, fails the rails feature
  on the two-users scenario and the check-only pair;
* every copy of a library kit embedded in an eval matches the library file
  (`scripts/embed-kits.lua` rewrites them).

## Corrections, made while building it

* A kit embedded in an eval as a doc string (the notebook an author verifies is read
  through the doubles' filesystem) drifts from the library file, and the registry then
  refuses the nested load as a second kit of one name: every nested verify fails. Found
  by the first run of `evals/modes-rails.feature`, 2026-09-12; `scripts/embed-kits.lua`
  rewrites the copies and `test/kit_test.lua` holds them equal.

* A kit records its stores and its steps on the agent as well as its tools: the first
  rendering said a kit's store back as `it keeps a store`, which applied again declared it
  twice. What a kit installed is said by the kit's line, all of it.
* A kit handed to `agent.kit` whose name a loaded file already holds is refused as another
  kit, even when it is that file's table read again: the registry compares tables and
  paths, not contents. Two kits of one name in one process is the thing refused.
