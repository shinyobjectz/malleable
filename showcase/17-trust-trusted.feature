Feature: trust trusted
  A trusted workspace asks nothing, even of a tool that asks first; a deny still holds.

  Background:
    Given the agent is called clerk
    And its model is "test:model"
    And its trust is trusted
    And it has a tool stamp for "Stamp it."
    And the tool stamp answers "stamped"
    And the tool stamp asks first
    And it has a tool shred for "Shred it."
    And the tool shred answers "shredded"
    And the tool shred asks first
    And it may never call shred

  Scenario: a gated tool runs without a question
    Given the model calls stamp with {}
    And the model answers "stamped"
    When the agent is asked "stamp"
    Then it calls stamp
    And the call to stamp answers "stamped"

  Scenario: a deny is a deny, trusted or not
    Given the model calls shred with {}
    And the model answers "no"
    When the agent is asked "shred"
    Then the call to shred is refused
