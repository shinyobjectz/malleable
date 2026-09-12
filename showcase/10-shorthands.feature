Feature: shorthands
  The vocabulary extended in Gherkin, with no Lua: a scenario tagged @shorthand whose name
  is the new line and whose lines are what it means. A bare <name> reads a word, a quoted
  one a string, and shorthands nest. A shorthand is of then lines or of given lines, never
  of a When (the three ways a run starts are the harness's).

  Background:
    Given the agent is called counter
    And its model is "test:model"
    And it keeps a store counts of "one thing counted a row":
      | column | type   | about    |
      | name   | string | the thing |
      | n      | number | how many |
    And it has a tool count for "Count a thing.", which takes:
      | argument | type   | about     |
      | name     | string | the thing |
      | n        | number | how many  |
    And the tool count adds a row to counts

  @shorthand
  Scenario: it has counted <thing> <times> time(s)
    Then the store counts holds:
      | name    | n       |
      | <thing> | <times> |

  @shorthand
  Scenario: it says "<words>" and stops
    Then the answer says "<words>"
    And it stops with answered

  @shorthand
  Scenario: it counted <thing> <times> time(s) and said "<words>"
    Then it has counted <thing> <times> times
    And it says "<words>" and stops

  @verify-only
  Scenario: two teas are two
    Given the model calls count with {"name": "tea", "n": 2}
    And the model answers "two teas"
    When the agent is asked "count the teas"
    Then it has counted tea 2 times
    And it says "two" and stops

  @verify-only
  Scenario: a shorthand may use another
    Given the model calls count with {"name": "ale", "n": 1}
    And the model answers "one ale"
    When the agent is asked "count the ale"
    Then it counted ale 1 time and said "one ale"
