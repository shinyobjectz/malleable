Feature: delegates
  One line hands work to the agent another file declares. The child runs in the world the
  parent was given, behind the same gate, and in a scenario the one scripted model speaks
  for parent and child in order.

  Background:
    Given the agent is called lead
    And its model is "test:model"
    And it reads the workspace
    And it hands work to the agent in "helper.feature" as helper

  Scenario: the parent delegates, the child answers, the parent relays
    Given the file "notes/budget.md" contains:
      """
      The venue costs 1200.
      """
    And the human approves helper
    And the model calls helper with {"prompt": "read notes/budget.md and say the number"}
    And the model calls read with {"path": "notes/budget.md"}
    And the model answers "1200"
    And the model answers "the helper says 1200"
    When the agent is asked "hand this to your helper: read notes/budget.md and tell me the number"
    Then the human is asked about helper
    And it calls helper
    And the call to helper answers "1200"
    And the answer says "1200"

  Scenario: the gate on the delegate is the person's
    Given the human refuses helper
    And the model calls helper with {"prompt": "anything"}
    And the model answers "you did not let me delegate"
    When the agent is asked "hand this to your helper: say anything"
    Then the call to helper is refused
    And it stops with answered
