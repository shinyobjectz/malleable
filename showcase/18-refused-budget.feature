# expect: refused "agent.budget takes a whole number of steps, at least 1"
Feature: refused at load, a budget of zero
  A budget is at least one step. This file is wrong on purpose and is refused at load;
  scripts/showcase.lua expects the sentence in the first line above.

  Background:
    Given the agent is called broken
    And its model is "test:model"
    And it may take 0 steps
    And it has a tool ok for "Fine."
    And the tool ok answers "fine"

  Scenario: never reached
    When the declaration is loaded
    Then the declaration is sound
