# mcp — tools that live in another process

`src/mcp.lua`. Contract, not implementation.

## What it is for

A tool in this tree is a Lua body. A tool on a server is a name, a sentence and a schema
that arrived over a wire. The only honest thing to do with the second is to make it the
first before the model ever sees it: by the time `agent.schema` is read there is no way
to tell which tools were declared here and which were fetched, **because the model's job
is not to know**.

## The declaration names; it does not reach

    agent.uses "github" {
      command = { "npx", "-y", "@modelcontextprotocol/server-github" },
      tools   = { "list_issues", "create_issue" },   -- everything, if absent
      ask     = true,
    }

Rule 2 holds for a declaration that names a network as firmly as for one that names a
file: nothing here connects. `mcp.connect(a, port)` asks, at run time, through the `mcp`
port

    list(server, config) -> { descriptor, ... } | nil, err
    call(server, tool, args) -> text | { content = { … } } | nil, err

which knows what a transport is so that this module does not. **Everything else the
declaration states is passed to the port untouched** — a command line, a URL, a header
table. This module neither reads it nor validates it, because the day it does is the day
adding a transport means editing two files.

## Descriptors, in two shapes

A descriptor carries either `args` (already the harness's shape) or the JSON Schema a
server actually sends, as `input_schema` or `inputSchema`. Both are accepted, because
the first is what a test writes and the second is what a server sends, and a module that
accepts only the first has tests that pass against a world that does not exist.

`mcp.params` maps JSON Schema onto the five kinds, keeping each property's description
and its required-ness. Anything richer — `oneOf`, nested objects, enums — becomes the
nearest kind: an argument the model can still fill imperfectly beats a tool that could
not be offered at all. What it never does is invent a constraint the server did not
state; an unknown type becomes a string carrying the schema's own words.

## Names

A server's tool name is unique on that server and nowhere else, so the local name is
`<server><join><tool>`, joined with `_` unless the declaration says otherwise. Without
this, two servers offering `search` collide — and the collision is **silent**, because
`spec.add_tool` refuses the second and the run is simply missing a tool nobody notices
is gone.

## Asking

A fetched tool asks by default. Rule 4 decides who approves; this module decides only
that another process is not this one, and a declaration that has thought about it says
`ask = false`.

## A server that is down is a problem, not an error

`connect` answers `added, problems`, both lists of sentences, both always tables. An
unreachable server, an unreadable answer, a name collision and a tool the declaration
asked for that the server does not offer are all **problems**: named, carried onto the
run's notes, and the run continues with the tools it does have. One server being down
must not stop an agent that also reads files. `connect` is idempotent — a host that
calls it on every run does not add twice.
