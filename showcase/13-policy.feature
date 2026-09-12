Feature: policy
  The two policy lines: a tool the person need never be asked about, and a tool that may
  never run whatever the person says. Policy is read at the gate, and the gate is reached
  only by a tool that asks first, so both lines are said of gated tools; a policy on a
  tool that does not ask is inert, and the runner says so. Trust is a third line, shown in
  the next two files, because what an agent is, is said once, in one Background.

  Background:
    Given the agent is called clerk
    And its model is "test:model"
    And it has a tool stamp for "Stamp it."
    And the tool stamp answers "stamped"
    And the tool stamp asks first
    And it may always call stamp
    And it has a tool shred for "Shred it."
    And the tool shred answers "shredded"
    And the tool shred asks first
    And it may never call shred

  Scenario: a tool the policy always allows runs without a question, gate or no gate
    Given the model calls stamp with {}
    And the model answers "stamped"
    When the agent is asked "stamp"
    Then it calls stamp
    And the call to stamp answers "stamped"

  Scenario: a tool the policy never allows is refused whatever the person says
    Given the human approves shred
    And the model calls shred with {}
    And the model answers "I may not shred"
    When the agent is asked "shred"
    Then the call to shred is refused
    And it stops with answered
