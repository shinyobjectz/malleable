Feature: modes
  A mode is a named state of a run with the tools it may call; the person, and only the
  person, moves the run between modes. The kit is library/modes.lua (docs/spec/modes.md),
  and this is plan mode for an agent that edits files: read and check first, and write
  only once the person has said so.

  Background:
    Given the agent is called drafter
    And its model is "test:model"
    And it uses the kit "../library/modes.lua"
    And it reads and writes the workspace
    And it starts in the mode reading
    And in the mode reading it may call "read, list"
    And in the mode writing it may call "read, list, write"
    And the mode reading moves to writing when the person says so

  Scenario: in the start mode a write is refused with the sentence, and the run goes on
    Given the file "notes/a.md" contains:
      """
      one
      """
    And the model calls read with {"path": "notes/a.md"}
    And the model calls write with {"path": "notes/b.md", "text": "two"}
    And the model answers "I read a.md; I may not write in the mode reading"
    When the agent is asked "read notes/a.md and then write two into notes/b.md"
    Then the call to read answers "one"
    And the call to write is refused
    And nothing is written
    And it is in the mode reading
    And it stops with answered

  Scenario: the person approves the move, and the write goes through
    Given the human approves mode
    And the human approves write
    And the model calls mode with {"to": "writing"}
    And the model calls write with {"path": "notes/b.md", "text": "two"}
    And the model answers "written"
    When the agent is asked "move to writing and write two into notes/b.md"
    Then the human is asked about mode
    And the call to mode answers "in the mode writing"
    And it calls write
    And the file "notes/b.md" holds:
      """
      two
      """
    And it is in the mode writing

  Scenario: the person refuses the move, and nothing changes
    Given the human refuses mode
    And the model calls mode with {"to": "writing"}
    And the model calls write with {"path": "notes/b.md", "text": "two"}
    And the model answers "you said no"
    When the agent is asked "move to writing and write"
    Then the call to mode is refused
    And the call to write is refused
    And nothing is written
    And it is in the mode reading

  Scenario: a move the lines do not declare is refused by the tool, naming the moves there are
    Given the human approves mode
    And the run begins in the mode writing
    And the model calls mode with {"to": "reading"}
    And the model answers "there is no way back"
    When the agent is asked "go back to reading"
    Then the call to mode fails
    And it is in the mode writing
