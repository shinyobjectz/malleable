Feature: stores
  A store is a typed table the agent keeps, declared in three columns. Two body lines
  need no Lua at all: one adds the tool's arguments as a row, one lists every row. A
  scenario seeds rows in a table and states the rows after, in order.

  Background:
    Given the agent is called counter
    And its model is "test:model"
    And it keeps a store tallies of "one thing counted a row":
      | column | type                     | about              |
      | name   | string                   | what was counted   |
      | n      | number                   | how many           |
      | tag    | optional one of hot, cold | a temperature     |
    And the store tallies is sorted by name
    And it has a tool count for "Count a thing.", which takes:
      | argument | type                      | about            |
      | name     | string                    | what             |
      | n        | number                    | how many         |
      | tag      | optional one of hot, cold | a temperature    |
    And the tool count adds a row to tallies
    And it has a tool show for "Show every tally."
    And the tool show lists tallies

  Scenario: rows are added, typed, and listed in the declared order
    Given the model calls count with {"name": "tea", "n": 2, "tag": "hot"}
    And the model calls count with {"name": "ale", "n": 1}
    And the model calls show with {}
    And the model answers "two things"
    When the agent is asked "count tea and ale"
    Then the store tallies has 2 rows
    And the store tallies holds:
      | name | n | tag |
      | ale  | 1 |     |
      | tea  | 2 | hot |
    And the call to show answers "ale"

  @verify-only
  Scenario: a row that breaks the type is refused, and the store is untouched
    Given the model calls count with {"name": "ice", "n": "many"}
    And the model calls count with {"name": "ice", "n": 3, "tag": "warm"}
    And the model answers "could not count"
    When the agent is asked "count ice"
    Then the call to count fails
    And the store tallies has 0 rows

  Scenario: a store may start with rows the scenario gives
    Given the store tallies contains:
      | name | n | tag  |
      | tea  | 5 | hot  |
    And the model calls count with {"name": "tea", "n": 1}
    And the model answers "six"
    When the agent is asked "one more tea"
    Then the store tallies has 2 rows
