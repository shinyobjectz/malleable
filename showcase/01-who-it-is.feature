Feature: who it is
  The lines that say who an agent is, and the one When that runs nothing: the declaration
  itself is checked, and a feature can state what is refused and why before any model is
  involved.

  Background:
    Given the agent is called greeter
    And its model is "test:model"
    And its reasoning is low
    And it may take 3 steps
    And it is briefed:
      """
      You greet people by name, in one line.
      """
    And it has a tool greet for "Say hello.", which takes:
      | argument | type   | about        |
      | name     | string | who to greet |
    And the tool greet does:
      """lua
      return "hello, " .. c.args.name
      """

  Scenario: the declaration is sound as written
    When the declaration is loaded
    Then the declaration is sound

  Scenario: a run is a transcript the scenario wrote
    Given the model calls greet with {"name": "ana"}
    And the model answers "Hello, Ana."
    When the agent is asked "say hi to ana"
    Then it calls greet with {"name": "ana"}
    And the call to greet answers "hello, ana"
    And it answers "Hello, Ana."
    And it stops with answered
    And it takes 2 steps

  Scenario: the budget is the ceiling, and running out is a stop of its own
    Given the budget is 1
    And the model calls greet with {"name": "bo"}
    And the model answers "never reached"
    When the agent is asked "say hi to bo"
    Then it stops with budget
    And it takes 1 step

  Scenario: the model's last word is the answer, exactly
    Given the model answers "Good morning."
    When the agent is asked "morning"
    Then it answers "Good morning."
    And the answer says "morning"
    And it never calls greet
