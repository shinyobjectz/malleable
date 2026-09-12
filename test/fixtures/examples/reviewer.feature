# The behaviour half of example/reviewer.lua, and the acceptance target for
# spec/behaviour.md: when src/gherkin.lua and src/behaviour.lua exist,
#
#     lua bin/malleable.lua --verify example/reviewer.lua
#
# runs this file against that declaration on the doubles and prints a green tally.
# Until then it is the contract in the form the contract is about.

Feature: the reviewer reads before it judges, and asks before it files

  It is a review agent with six read-only filesystem tools, one shell tool that asks on
  its own account, and exactly one tool that leaves a mark. Everything below is stated
  about the harness itself, so none of it needs a step of its own.

  Background:
    Given the file "src/turn.lua" contains:
      """
      -- the turn loop
      local turn = {}
      return turn
      """
    And the command "lua run-tests.lua" answers 0 and:
      """
      608 passed
      """

  Scenario: it runs the suite and files an approval a human agreed to
    Given the human approves verdict
    And the human approves shell
    And the model calls read with {"path": "src/turn.lua"}
    And the model calls shell with {"command": "lua run-tests.lua"}
    And the model calls verdict with {"summary": "The loop is small and the suite is green."}
    And the model answers "I read the file, ran the suite, and filed an approval."
    When the agent is asked "Review the change to src/turn.lua."
    Then it stops with answered
    And it calls read with {"path": "src/turn.lua"}
    And it calls verdict 1 time
    And the file "REVIEW.md" holds:
      """
      APPROVED

      The loop is small and the suite is green.
      """
    And it notes "the verdict was filed"

  Scenario: a refusal at the gate is a result the model reads, not an error
    Given the human refuses verdict
    And the model calls verdict with {"summary": "ship it"}
    And the model answers "I was not allowed to file that."
    When the agent is asked "Review the change to src/turn.lua."
    Then the human is asked about verdict
    And the call to verdict is refused
    And it stops with answered
    And nothing is written

  # Two scenarios rather than one, because the first draft of this said "it cannot write"
  # and passed for a reason it did not name: with nobody at the gate, EVERY mutating call
  # is refused, so it would have gone on passing after the read-only flag came off. Each
  # of these pins one cause, and each of them goes red when its own cause is removed.

  Scenario: with nobody at the gate, a write is refused rather than quietly made
    Given the model calls write with {"path": "src/turn.lua", "text": "-- fixed\n"}
    And the model answers "I could not write to it."
    When the agent is asked "Fix src/turn.lua."
    Then the call to write is refused
    And nothing is written

  Scenario: it is a reviewer, so even an approved write is not a tool it has
    Given the human approves write
    And the model calls write with {"path": "src/turn.lua", "text": "-- fixed\n"}
    And the model answers "There is no such tool."
    When the agent is asked "Fix src/turn.lua."
    Then the file "src/turn.lua" holds:
      """
      -- the turn loop
      local turn = {}
      return turn
      """
    And nothing is written

  Scenario: the loop always ends, and says why
    Given the budget is 3
    And the model calls read with {"path": "src/turn.lua"}
    And the model calls read with {"path": "src/turn.lua"}
    And the model calls read with {"path": "src/turn.lua"}
    And the model calls read with {"path": "src/turn.lua"}
    When the agent is asked "Read that file forever."
    Then it stops with budget
    And it takes 3 steps
    And nothing is written

  # What the run DID, not only what it answered. The two things this agent is actually for
  # -- that it reads before it judges, and that it never files without asking -- are
  # sayable here rather than only in a code review.
  #
  # These two scenarios were written first in `the trace shows "execute_tool" 3 times` and
  # `the span "malleable.gate verdict" says ...`, and rewriting them is what retired those
  # expressions: everything they were for is said better below, in the agent's own nouns
  # rather than the harness's.

  Scenario: it reads before it judges
    Given the human approves verdict
    And the human approves shell
    And the model calls read with {"path": "src/turn.lua"}
    And the model calls shell with {"command": "lua run-tests.lua"}
    And the model calls verdict with {"summary": "The loop is small and the suite is green."}
    And the model answers "done"
    When the agent is asked "Review the change to src/turn.lua."
    Then it calls read before verdict
    And it calls shell before verdict
    And it calls verdict 1 time
    And it stops with answered

  Scenario: nothing is filed without a human
    Given the human refuses verdict
    And the model calls verdict with {"summary": "ship it"}
    And the model answers "I was not allowed."
    When the agent is asked "Review the change."
    Then the human is asked about verdict
    And the call to verdict is refused
    And nothing is written

  Scenario: the declaration itself is sound
    When the declaration is loaded
    Then the declaration is sound
