Feature: helper
  The agent showcase/11-delegates.feature hands work to.

  Background:
    Given the agent is called helper
    And its model is "test:model"
    And it may take 4 steps
    And it is briefed:
      """
      You do one small thing you are handed and answer in a line.
      """
    And it reads the workspace
