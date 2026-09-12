# store — what a program keeps

## What it is for

A program remembers things between runs: a count, a list of habits, the room a maze is
in. The rows are the host's, never the program's: a program declares the *shape* of what
it keeps, a tool body reads and changes rows through `c.store`, and the host decides where
they live — in memory in a test, in `~/.malleable/data/<program>/` on the console. Because
the host holds them, a store survives the program being rewritten, and a feature can say
what it holds before and after a run in a data table, one row a line.

The module is `src/store.lua`. It requires nothing (rule 1).

## Declaring one

    agent.store "room" {
      about   = "the room, one row of cells a line",
      columns = { y = agent.number "which row, from the top", cells = agent.string "the cells" },
      sort    = "y",
    }

`about` is required: what one row is. `columns` names each column with an argument type —
`agent.string`, `agent.number`, `agent.boolean`, `agent.one_of`, or an `_opt` form, which
may be missing from a row. A list or a table is not a column: a row is flat so that it
reads back as one line of a data table. `sort` is a column, or a list of them, that rows
are listed by first; the other columns follow by name. Every listing is in that order, so
the same rows always print the same bytes.

A declaration with a store is checked when it loads: a store with no columns, a column of
a type a row cannot hold, or a `sort` that names no column raises, with the store's name.

## The view a tool body has

    c.store.rows("room")                                every row, sorted, as copies
    c.store.add("room", { y = 1, cells = "#M.L#" })     -> true
    c.store.change("room", { y = 1 }, { cells = "#.ML#" })   -> how many changed
    c.store.remove("room", { y = 1 })                   -> how many removed; {} is every row

The port convention holds. A wrong shape raises: a store the program does not declare, a
column the store does not have, a value of the wrong type, a required column missing from
an added row. A wrong world answers `nil` and a reason: the stores together would pass
`store.LIMIT` (65536 bytes, counted as the rows' text), or the host could not write them.
A change or remove that matches nothing writes nothing and answers 0.

Rows come back as copies; changing one changes nothing held.

## The port a host provides

    port.store.read(name)                -> the rows, or nil when there are none
    port.store.write(name, rows, change) -> true, or nil and why

`rows` is the store's whole table, sorted. `change` is what happened —
`{ op = "add", row }`, `{ op = "change", where, set }` or `{ op = "remove", where }` — for
a host that shows it: the console hands it to the UI as a `change` event. `store.memory
(tables)` is the port in memory, and the double: it keeps what it holds in `tables`, as
plain data, and every write in `changes`, so a Then line can read both from a frozen world.

`store.bind(declaration, port)` hands a run the view in place of the raw port. The run
entry points bind (`agent.run`, and every run a feature drives through `cli.drivers`); a
world with no store gets one in memory.

## In a feature

    Given the store room contains:
      | y | cells |
      | 1 | ##### |
    ...
    Then the store room holds:
      | y | cells |
      | 1 | #M.L# |
    And the store room has 1 row

A cell is typed by its column: `2` in a number column is the number 2, `true` in a
boolean column is true, and an empty cell is a missing value. `holds:` is the whole store
after the run, in its listing order; a failure prints what it holds. `observe` writes a
`contains:` line for every store the world started with, and a `holds:` line for every
store the run changed, so a run reads back with its data and runs again.

## Failure modes

| what happens | what the caller sees |
| --- | --- |
| a store, column or type the declaration does not have | raises, naming the store, the column and what it does have |
| the stores would pass `store.LIMIT` | `nil, "the stores would hold N bytes, past the limit of 65536"`, and nothing is written |
| the host's write fails | `nil` and the host's reason, and nothing is changed |
| a data table names a column the store lacks, or a cell its column cannot hold | the Given or Then line is broken or failed, with the column |

## What it must not do

- Hand a program the rows as its own table. A program that holds rows can lose them in a
  rewrite; the host that holds them cannot.
- List rows in the order they were written. A store that prints differently for the same
  rows cannot be compared, and `observe` could not collapse two runs that did one thing.
- Reach the disk from `src/`. Where rows live is the host's decision.

## The tests that would prove it

`test/store_test.lua`: sorting whatever the order of adds; copies; change and remove
counts; every wrong shape; the limit; a failing host; typed data-table cells; the
declaration's checks; a feature that writes and reads a store back; a run observed and
run again; a cell with a bar in it.
