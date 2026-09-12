Feature: helper that writes
  A delegate for evals/modes-edges.feature: it writes what it is told to, in the world the
  parent hands it, and knows nothing of the parent's mode.

  Background:
    Given the agent is called writer
    And its model is "test:model"
    And it reads and writes the workspace
