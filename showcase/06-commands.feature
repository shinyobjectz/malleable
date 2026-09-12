Feature: commands
  A shell in one line, with its timeout. The scenario scripts what a command line answers,
  and the Then lines speak of what kind of thing the agent ran, never of the line itself:
  the reader turns a command into a term, so a feature can say "it never publishes".

  Background:
    Given the agent is called runner
    And its model is "test:model"
    And it runs commands
    And each command may run 30 seconds
    And the tool shell is for "Run one command line in the workspace."

  @verify-only
  Scenario: it runs the tests and reads the result
    Given the command "npm test" answers 0 and:
      """
      4 passed
      """
    And the human approves shell
    And the model calls shell with {"command": "npm test"}
    And the model answers "four tests pass"
    When the agent is asked "do the tests pass?"
    Then it runs a command that tests
    And it runs no command that publishes
    And it runs no command that escalates
    And it answers "four tests pass"

  @verify-only
  Scenario: a failing command is a result with its exit code, not an error
    Given the command "npm test" answers 1 and:
      """
      1 failed
      """
    And the human approves shell
    And the model calls shell with {"command": "npm test"}
    And the model answers "one test fails"
    When the agent is asked "do the tests pass?"
    Then it calls shell
    And it answers "one test fails"

  Scenario: the shell asks on its own account, and no means no
    Given the human refuses shell
    And the model calls shell with {"command": "git push origin main"}
    And the model answers "you refused the push"
    When the agent is asked "ship it"
    Then the human is asked about shell
    And the call to shell is refused
    And it runs no command that publishes

  Scenario: a command nobody scripted is unscripted, not silently fine
    Given the human approves shell
    And the model calls shell with {"command": "rm -rf build"}
    And the model answers "it did not run"
    When the agent is asked "clean up"
    Then the call to shell answers "nothing is scripted for"
