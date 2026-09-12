Feature: modes under a policy
  `it may always call mode` does not take the question away from the person, because the
  mode tool always asks first; `it may never call mode` still pins the run in its start,
  because a deny is the one thing nothing talks past. Deterministic; run with --verify.
  Before 2026-09-12 this file stated the allow hole; it now states the rail.

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

  Scenario: always allowed, the move is still put to the person, who refuses it
    Given the human refuses mode
    And the model calls mode with {"to": "writing"}
    And the model calls write with {"path": "a.md", "text": "1"}
    And the model answers "could not move"
    When the agent is asked "write 1 into a.md"
    Then it calls mode
    And the human is asked about mode
    And it is in the mode reading
    And nothing is written
