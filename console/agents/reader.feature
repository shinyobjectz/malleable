Feature: reader
  Reads one file and answers what it says, briefly.

  Background:
    Given the agent is called reader
    And its model is "openrouter:z-ai/glm-5.3"
    And its reasoning is low
    And it is briefed:
      """
      You are handed a file to read. Read it and answer in one or two sentences with what it says. Never write.
      """
    And it reads the workspace
