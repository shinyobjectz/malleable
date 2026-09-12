Feature: tools
  A tool is declared in a table and given a body in one line: a Lua doc string, a fixed
  answer, or a store operation. Typed arguments are checked at the edge, a requirement is a
  check in Lua, a call limit is a hook, and every refusal is an answer the model reads.

  Background:
    Given the agent is called clerk
    And its model is "test:model"
    And it has a tool add for "Add two numbers.", which takes:
      | argument | type   | about            |
      | a        | number | the first        |
      | b        | number | the second       |
    And the tool add does:
      """lua
      return tostring(c.args.a + c.args.b)
      """
    And it has a tool colour for "Pick a colour.", which takes:
      | argument | type                        | about       |
      | which    | one of red, green, blue     | the colour  |
      | shade    | optional string             | a shade     |
    And the tool colour does:
      """lua
      return c.args.which .. (c.args.shade and (" " .. c.args.shade) or "")
      """
    And it has a tool ping for "Answer pong."
    And the tool ping answers "pong"
    And the tool ping may be called at most 2 times
    And it has a tool open for "Open a file by path.", which takes:
      | argument | type   | about    |
      | path     | string | the path |
    And the tool open requires "a path under src", checked by:
      """lua
      return c.args.path:sub(1, 4) == "src/", "only paths under src/ open"
      """
    And the tool open does:
      """lua
      return "opened " .. c.args.path
      """

  Scenario: a Lua body sees typed arguments
    Given the model calls add with {"a": 2, "b": 40}
    And the model answers "42"
    When the agent is asked "use the add tool to add 2 and 40"
    Then the call to add answers "42"
    And the answer says "42"

  @verify-only
  Scenario: a choice argument refuses what is not on the list, and the run goes on
    Given the model calls colour with {"which": "purple"}
    And the model calls colour with {"which": "red", "shade": "dark"}
    And the model answers "dark red"
    When the agent is asked "a colour"
    Then the call to colour fails
    And it calls colour 2 times
    And it answers "dark red"

  Scenario: a fixed answer, and a call past the limit is refused
    Given the model calls ping with {}
    And the model calls ping with {}
    And the model calls ping with {}
    And the model answers "three pings"
    When the agent is asked "ping thrice"
    Then it calls ping 3 times
    And the call to ping answers "pong"
    And the call to ping is refused
    And it stops with answered

  @verify-only
  Scenario: a requirement is checked before the body runs
    Given the model calls open with {"path": "etc/passwd"}
    And the model calls open with {"path": "src/turn.lua"}
    And the model answers "opened one"
    When the agent is asked "open things"
    Then the call to open fails
    And the call to open answers "opened src/turn.lua"
    And it calls open 2 times

  Scenario: a tool with no body is refused at load, by name
    Given the declaration is loaded
    Then the declaration is sound
