# The built-in step vocabulary

GENERATED from `src/behaviour.lua` by `lua bin/malleable.lua --steps --heading > docs/STEPS.md`. Never hand-edited: an expression is added in one place, and this is a rendering of it.

```
The built-in vocabulary: 35 expressions, version 1.

given -- the world
  the file {string} contains:                                a file the agent can read
  the file {string} is missing                               a file that is not there
  the command {string} answers {int} and:                    what one command line answers
  the human approves {word}                                  the gate says yes to this tool
  the human refuses {word}                                   the gate says no to this tool
  the clock reads {string}                                   the moment the run happens at
  the model calls {word} with {value}                        the next thing the model says  (dropped in an eval)
  the model answers {string}                                 the model's last word  (dropped in an eval)
  the workspace keeps a skill {string}:                      a procedure a person wrote
  {word} last ran on {string}                                what the ledger remembers about a beat
  the server {word} offers {word}, which answers {value}     a tool that lives in another process
  the budget is {int}                                        how many passes the loop may take

when -- the run
  the agent is asked {string}                                somebody asks the agent for something
  the clock strikes {string}                                 the beat comes round
  the declaration is loaded                                  nothing runs; the declaration is checked

then -- the result
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
  nothing is written                                         no file was written or removed
  it notes {string}                                          the run made this note
  the declaration is sound                                   it has no problems that would stop a run
  the declaration is refused because {string}                and this is why
  the call to {word} fails                                   it was called, and the call did not go through
  it calls {word} before {word}                              and in that order
```
