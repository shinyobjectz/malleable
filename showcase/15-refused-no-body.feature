# expect: refused "the tool nothing has no body"
Feature: refused at load, a tool with no body
  A Background that is wrong is refused before any scenario runs, with the line and the
  reason, and the runner exits 2. This file is wrong on purpose; scripts/showcase.lua
  expects the refusal in the first line above. (The Then line `the declaration is refused
  because` is for problems the check finds that loading does not, and for a host that
  builds a declaration by hand; a wrong is line never gets that far.)

  Background:
    Given the agent is called broken
    And its model is "test:model"
    And it has a tool nothing for "Does nothing."

  Scenario: never reached
    When the declaration is loaded
    Then the declaration is sound
