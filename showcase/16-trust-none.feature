Feature: trust none
  With no trust, a gated tool is put to the person every time, and nothing the policy does
  not name outright runs on its own; a tool that never asks is outside the gate whatever
  the trust says.

  Background:
    Given the agent is called clerk
    And its model is "test:model"
    And its trust is none
    And it has a tool stamp for "Stamp it."
    And the tool stamp answers "stamped"
    And the tool stamp asks first

  Scenario: the person is asked, and refuses
    Given the human refuses stamp
    And the model calls stamp with {}
    And the model answers "not allowed"
    When the agent is asked "stamp"
    Then the human is asked about stamp
    And the call to stamp is refused

  Scenario: the person is asked, and approves
    Given the human approves stamp
    And the model calls stamp with {}
    And the model answers "stamped"
    When the agent is asked "stamp"
    Then the human is asked about stamp
    And the call to stamp answers "stamped"
