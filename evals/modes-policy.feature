Feature: modes under a policy
  `it may always call mode` takes the question away from the person, and the model moves
  itself; `it may never call mode` pins the run in its start. Deterministic; run with --verify.

  Background:
    Given the agent is called drafter
    And its model is "test:model"
    And it uses the kit "../library/modes.lua"
    And it reads and writes the workspace
    And it starts in the mode reading
    And in the mode reading it may call "read, list"
    And in the mode writing it may call "read, list, write"
    And the mode reading moves to writing when the person says so
    And it may always call mode

  Scenario: always allowed, the model moves without a question
    Given the human refuses mode
    And the model calls mode with {"to": "writing"}
    And the model calls write with {"path": "a.md", "text": "1"}
    And the model answers "moved and wrote"
    When the agent is asked "write 1 into a.md"
    Then it calls mode
    And it is in the mode writing
    And it calls write
