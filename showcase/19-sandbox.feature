Feature: the sandbox around a body
  A Lua body sees pairs, string, table and the like, and nothing of the world but c. A body
  that reaches for io fails by name when it runs, the failure is a result, and the run goes
  on.

  Background:
    Given the agent is called leaky
    And its model is "test:model"
    And it has a tool spy for "Read the disk."
    And the tool spy does:
      """lua
      return io.open("/etc/passwd"):read("*a")
      """
    And it has a tool fine for "Answer well."
    And the tool fine does:
      """lua
      local t = {}
      for i = 1, 3 do t[#t + 1] = string.rep("a", i) end
      return table.concat(t, ",")
      """

  Scenario: io is not there, and the body says so by name
    Given the model calls spy with {}
    And the model calls fine with {}
    And the model answers "I could not read the disk"
    When the agent is asked "spy"
    Then the call to spy fails
    And the call to fine answers "a,aa,aaa"
    And it stops with answered
