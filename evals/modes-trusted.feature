Feature: modes under trust
  The mode tool always asks first, so `its trust is trusted` answers every question but
  its own: trust does not move a mode, and the person does. Deterministic; run with
  --verify. Before 2026-09-12 this file stated the hole; it now states the rail.

  Background:
    Given the agent is called drafter
    And its model is "test:model"
    And its trust is trusted
    And it uses the kit "../library/modes.lua"
    And it reads and writes the workspace
    And it starts in the mode reading
    And in the mode reading it may call "read, list"
    And in the mode writing it may call "read, list, write"
    And the mode reading moves to writing when the person says so

  Scenario: trusted, the move is still put to the person, who refuses it
    Given the human refuses mode
    And the model calls mode with {"to": "writing"}
    And the model calls write with {"path": "a.md", "text": "1"}
    And the model answers "could not move"
    When the agent is asked "write 1 into a.md"
    Then it calls mode
    And the human is asked about mode
    And it is in the mode reading
    And nothing is written

  Scenario: trusted, the person approves the move and the write runs unasked
    Given the human approves mode
    And the model calls mode with {"to": "writing"}
    And the model calls write with {"path": "a.md", "text": "1"}
    And the model answers "moved and wrote"
    When the agent is asked "write 1 into a.md"
    Then the human is asked about mode
    And it is in the mode writing
    And it calls write
    And the file "a.md" holds:
      """
      1
      """
