Feature: outlines
  Plain Gherkin still works: a Scenario Outline with Examples is one scenario a row, and a
  table cell substitutes into a prompt, a call and an answer alike.

  Background:
    Given the agent is called echo
    And its model is "test:model"
    And it has a tool shout for "Shout a word.", which takes:
      | argument | type   | about    |
      | word     | string | the word |
    And the tool shout does:
      """lua
      return string.upper(c.args.word) .. "!"
      """

  Scenario Outline: every word is shouted back
    Given the model calls shout with {"word": "<word>"}
    And the model answers "<loud>"
    When the agent is asked "shout <word>"
    Then the call to shout answers "<loud>"
    And it answers "<loud>"

    Examples:
      | word  | loud   |
      | hi    | HI!    |
      | bye   | BYE!   |
      | later | LATER! |
