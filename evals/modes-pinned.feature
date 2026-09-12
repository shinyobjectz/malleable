Feature: modes pinned by a policy
  `it may never call mode` leaves the agent in its start for good: the rail with no door.

  Background:
    Given the agent is called drafter
    And its model is "test:model"
    And it uses the kit "../library/modes.lua"
    And it reads and writes the workspace
    And it starts in the mode reading
    And in the mode reading it may call "read, list"
    And in the mode writing it may call "read, list, write"
    And the mode reading moves to writing when the person says so
    And it may never call mode

  Scenario: never allowed, the move is refused whatever the person says
    Given the human approves mode
    And the model calls mode with {"to": "writing"}
    And the model calls write with {"path": "a.md", "text": "1"}
    And the model answers "stuck"
    When the agent is asked "write 1 into a.md"
    Then the call to mode is refused
    And the call to write is refused
    And nothing is written
    And it is in the mode reading
