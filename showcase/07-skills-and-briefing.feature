Feature: skills and briefing
  A skill is a procedure a person wrote, kept in the file or read from a path, and read by
  the model through one tool when it needs it. The workspace may keep skills too. What the
  model is told about a tool is itself something a feature can state. The Then lines about
  a skill at a path say what the answer says, not which tool was called: a real model that
  can read the workspace opens the file the briefing names rather than calling `skill`,
  and that is not wrong.

  Background:
    Given the agent is called deployer
    And its model is "test:model"
    And it reads the workspace
    And it keeps a skill release for "How to cut a release.":
      """
      1. run the tests
      2. tag the commit
      3. push the tag
      """
    And it keeps a skill rollback for "How to roll back.", in "docs/rollback.md"
    And the tool read is for "Read one file of the workspace, whole."

  Scenario: the model reads a skill kept in the file
    Given the model calls skill with {"name": "release"}
    And the model answers "three steps"
    When the agent is asked "how do I release?"
    Then it calls skill with {"name": "release"}
    And the call to skill answers "tag the commit"

  Scenario: a skill kept at a path is read from the workspace
    Given the file "docs/rollback.md" contains:
      """
      revert the tag, redeploy the last one
      """
    And the model calls skill with {"name": "rollback"}
    And the model answers "revert the tag, redeploy the last one"
    When the agent is asked "how do I roll back?"
    Then the answer says "redeploy"

  Scenario: a skill the workspace keeps is there too
    Given the workspace keeps a skill "hotfix":
      """
      branch from the tag, fix, tag again
      """
    And the model calls skill with {"name": "hotfix"}
    And the model answers "branch from the tag"
    When the agent is asked "how do I hotfix?"
    Then the answer says "branch from the tag"

  Scenario: a skill that is not there is a sentence
    Given the model calls skill with {"name": "teleport"}
    And the model answers "there is no such skill"
    When the agent is asked "read your skill called teleport and tell me what it says"
    Then the call to skill answers "there is no skill \"teleport\". The skills are:"

  Scenario: what the model is told about a tool is stated
    When the declaration is loaded
    Then the tool read tells the model "whole"
