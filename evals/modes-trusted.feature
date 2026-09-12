Feature: modes under trust
  The mode tool asks first, and `its trust is trusted` answers every question yes without a
  person. So under trust a mode is a sentence the model reads, and the model moves itself.
  Deterministic; run with --verify. The point is to state the edge, not to hide it.

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

  Scenario: trusted, the model moves without a question and writes
    Given the human refuses mode
    And the model calls mode with {"to": "writing"}
    And the model calls write with {"path": "a.md", "text": "1"}
    And the model answers "moved and wrote"
    When the agent is asked "write 1 into a.md"
    Then it calls mode
    And it calls write
    And it is in the mode writing
    And the file "a.md" holds:
      """
      1
      """
