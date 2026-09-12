Feature: own steps
  The forty-odd built-in lines cover the harness; a workspace adds its own in Lua, one body
  a step: a given writes the world, a then reads the result. A then body answers true, or
  false and a sentence, and a body that raises is a broken step, reported apart.

  Background:
    Given the agent is called triage
    And its model is "test:model"
    And it reads the workspace
    And the step "the queue holds {int} ticket(s) from {string}" sets up:
      """lua
      local lines = {}
      for i = 1, c.args[1] do lines[i] = c.args[2] .. " #" .. i end
      c.world.fs["queue.txt"] = table.concat(lines, "\n") .. "\n"
      """
    And the step "it read the queue" checks:
      """lua
      for _, call in ipairs(c.result.calls) do
        if call.tool == "read" and call.args.path == "queue.txt" then return true end
      end
      return false, "no call read queue.txt"
      """
    And the step "the answer counts {int}" checks:
      """lua
      return tostring(c.result.answer):find(tostring(c.args[1]), 1, true) ~= nil,
             "the answer does not say " .. c.args[1]
      """

  Scenario: a domain step sets the world up and another reads the result
    Given the queue holds 3 tickets from "ops"
    And the model calls read with {"path": "queue.txt"}
    And the model answers "3 tickets from ops"
    When the agent is asked "how many tickets?"
    Then it read the queue
    And the answer counts 3

  Scenario: the optional (s) and a one-ticket queue
    Given the queue holds 1 ticket from "ops"
    And the model calls read with {"path": "queue.txt"}
    And the model answers "1 ticket from ops"
    When the agent is asked "how many tickets?"
    Then it read the queue
    And the answer counts 1
