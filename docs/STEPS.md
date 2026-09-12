# The built-in step vocabulary

GENERATED from `src/behaviour.lua` by `lua bin/malleable.lua --steps --heading > docs/STEPS.md`. Never hand-edited: an expression is added in one place, and this is a rendering of it.

```
The built-in vocabulary: 87 expressions, version 1; the is phase, version 1.

is -- the agent, in the Background
  the agent is called {word}                                 its name  (widens)
  its model is {string}                                      the model that answers for it  (widens)
  its reasoning is {word}                                    none, low, medium or high
  it may take {int} step(s)                                  its budget: passes of the loop
  it is briefed:                                             what it is told first, as a doc string
  its trust is {word}                                        trusted, ask or none  (widens)
  it may always call {word}                                  a tool the policy allows  (widens)
  it may never call {word}                                   a tool the policy refuses  (narrows)
  it reads the workspace                                     the files tools, read only  (widens)
  it reads and writes the workspace                          the files tools  (widens)
  it never touches {string}                                  a glob the files tools refuse  (narrows)
  it runs commands                                           the shell tool, which asks on its own account  (widens)
  each command may run {int} second(s)                       the shell's timeout
  it keeps a plan                                            the plan and mark tools  (widens)
  it can read its history                                    the history, recall and evidence tools, which read past runs  (widens)
  it hands work to the agent in {string} as {word}           a tool that runs the agent that file declares  (widens)
  it uses the server {word} with:                            a server whose tools live in another process; | key | value |  (widens)
  it has a tool {word} for {string}                          a tool with no arguments  (widens)
  it has a tool {word} for {string}, which takes:            a tool and its arguments; | argument | type | about |  (widens)
  the tool {word} asks first                                 the person is asked before it runs  (narrows; a gate, never removed by an agent)
  the tool {word} asks first, letting the person change {word} and the person may change that argument at the gate  (narrows; a gate, never removed by an agent)
  the tool {word} is for {string}                            what the model is told a tool is for
  the tool {word} shows its call before it runs              a host may draw the call first
  the tool {word} requires {string}, checked by:             a requirement; the doc string is its check, in Lua  (narrows)
  the tool {word} may be called at most {int} time(s)        a call past this is refused  (narrows)
  the tool {word} does:                                      its body, in Lua, as a doc string  (widens)
  the tool {word} answers {string}                           a body that answers this
  the tool {word} adds a row to {word}                       a body that adds its arguments as a row  (widens)
  the tool {word} lists {word}                               a body that answers every row, one per line
  it keeps a store {word} of {string}:                       a store; | column | type | about |  (widens)
  the store {word} is sorted by {word}                       the column a listing is sorted by, in order
  it keeps a skill {word} for {string}:                      a procedure a person wrote, as a doc string
  it keeps a skill {word} for {string}, in {string}          a procedure read from that path
  the beat {word} comes every {int} second(s) and asks {string} a beat, by the second  (widens)
  the beat {word} comes every day at {string} and asks {string} a beat, at a clock time  (widens)
  the beat {word} runs once per {word}                       hour, day, week or ever  (narrows)
  the step {string} sets up:                                 a step whose body writes the world, in Lua
  the step {string} checks:                                  a step whose body reads the result, in Lua
  it edits agents in {string}                                the six authoring tools, over the feature files in that folder  (widens)
  it uses the kit {string}                                   loads a kit file beside this one; its lines join the vocabulary  (widens)

given -- the world
  the file {string} contains:                                a file the agent can read
  the file {string} contains the text kept as {word}         a file the agent can read, whose text a history keeps
  the file {string} is missing                               a file that is not there
  the command {string} answers {int} and:                    what one command line answers
  the shell really runs                                      the world's shell executes, over its own files
  the human approves {word}                                  the gate says yes to this tool
  the human refuses {word}                                   the gate says no to this tool
  the human approves {word} with {value}                     the gate says yes, with the person's own values for what they may change
  the store {word} contains:                                 the rows a program's store starts with
  the clock reads {string}                                   the moment the run happens at
  the model calls {word} with {value}                        the next thing the model says  (dropped in an eval)
  the model answers {string}                                 the model's last word  (dropped in an eval)
  the workspace keeps a skill {string}:                      a procedure a person wrote
  {word} last ran on {string}                                what the ledger remembers about a beat
  the server {word} offers {word} and it answers {value}     a tool that lives in another process
  the budget is {int}                                        how many passes the loop may take

when -- the run
  the agent is asked {string}                                somebody asks the agent for something
  the clock strikes {string}                                 the beat comes round
  the declaration is loaded                                  nothing runs; the declaration is checked

then -- the result
  no beat is due                                             the strike made no run: every beat was held or not yet due
  it stops with {word}                                       one of answered, budget, refused, error
  it answers {string}                                        the answer, exactly
  the answer says {string}                                   the answer, containing
  it calls {word}                                            the tool was called at least once
  it calls {word} with {value}                               called with exactly these arguments
  it calls {word} {int} time(s)                              called exactly this many times
  it runs a command that {word}                              a shell call that did this
  it runs no command that {word}                             no shell call did this
  it never calls {word}                                      the tool was not called at all
  the call to {word} is refused                              the gate or a hook said no
  the human is asked about {word}                            the gate was put the question
  it takes {int} step(s)                                     exactly this many passes of the loop
  it takes at most {int} step(s)                             no more passes than this
  the file {string} holds:                                   what the file holds after the run
  the file {string} holds the line {string}                  one line of the file after the run, trimmed, exactly
  the file {string} holds the text kept as {word}            what the file holds after the run, as a text a history keeps
  the store {word} holds:                                    every row of the store after the run, in its order
  the store {word} has {int} row(s)                          how many rows the store holds after the run
  the call to {word} answers {string}                        a call to the tool went through and said this
  the {word} call to {word} fails because {string}           that call did not go through, and this is why
  the tool {word} tells the model {string}                   what the model reads about this tool, containing
  nothing is written                                         no file was written or removed
  it notes {string}                                          the run made this note
  the declaration is sound                                   it has no problems that would stop a run
  the declaration is refused because {string}                and this is why
  the call to {word} fails                                   it was called, and the call did not go through
  it calls {word} before {word}                              and in that order
```
