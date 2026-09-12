Feature: modes at the edges
  The modes kit (library/modes.lua, docs/spec/modes.md) pushed where it might break, on the
  doubles: a model that will not take no for an answer, a mode that does not exist, a move to
  where it already is, state between runs, and a delegate the mode cannot see. Deterministic;
  run with --verify. What holds and what does not is in docs/authoring-context.md.

  Background:
    Given the agent is called drafter
    And its model is "test:model"
    And it may take 4 steps
    And it uses the kit "../library/modes.lua"
    And it reads and writes the workspace
    And it hands work to the agent in "helper-writer.feature" as helper
    And it starts in the mode reading
    And in the mode reading it may call "read, list, helper"
    And in the mode writing it may call "read, list, write"
    And the mode reading moves to writing when the person says so

  Scenario: a model that keeps calling a refused tool runs out of budget, and writes nothing
    Given the model calls write with {"path": "a.md", "text": "1"}
    And the model calls write with {"path": "a.md", "text": "1"}
    And the model calls write with {"path": "a.md", "text": "1"}
    And the model calls write with {"path": "a.md", "text": "1"}
    And the model answers "never"
    When the agent is asked "write 1 into a.md, whatever it takes"
    Then it calls write 4 times
    And the call to write is refused
    And nothing is written
    And it stops with budget

  Scenario: a mode that does not exist is refused at the edge, before the person is asked
    Given the human approves mode
    And the model calls mode with {"to": "flying"}
    And the model answers "no such mode"
    When the agent is asked "move to flying"
    Then the call to mode fails
    And it is in the mode reading

  Scenario: a move to the mode it is in changes nothing and is not refused
    Given the human approves mode
    And the model calls mode with {"to": "reading"}
    And the model answers "already there"
    When the agent is asked "move to reading"
    Then the call to mode answers "already in the mode reading"
    And it is in the mode reading

  Scenario: a run starts in the start, whatever the last run ended in
    Given the human approves mode
    And the run begins in the mode writing
    And the model calls write with {"path": "b.md", "text": "2"}
    And the model answers "written"
    When the agent is asked "write 2 into b.md"
    Then it calls write
    And it is in the mode writing

  Scenario: and the next run is back in reading
    Given the model calls write with {"path": "c.md", "text": "3"}
    And the model answers "refused"
    When the agent is asked "write 3 into c.md"
    Then the call to write is refused
    And nothing is written
    And it is in the mode reading

  Scenario: the mode does not reach a delegate: a helper that writes, writes
    Given the human approves helper
    And the human approves write
    And the model calls helper with {"prompt": "write 4 into d.md"}
    And the model calls write with {"path": "d.md", "text": "4"}
    And the model answers "done"
    And the model answers "the helper wrote it"
    When the agent is asked "have the helper write 4 into d.md"
    Then it calls helper
    And the file "d.md" holds:
      """
      4
      """
    And it is in the mode reading
