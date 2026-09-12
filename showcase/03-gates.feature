Feature: gates
  A gate is one line, and a person's no is final: a refused call is a result the model
  reads, never an exception. A gate may let the person change an argument (a choice, a
  number or a boolean, never free text), and the tool then runs with what the person
  chose, not what the model proposed.

  Background:
    Given the agent is called sender
    And its model is "test:model"
    And it keeps a store outbox of "one message a row":
      | column | type   | about          |
      | to     | string | the recipient  |
      | text   | string | the message    |
    And it has a tool send for "Send a message.", which takes:
      | argument | type   | about          |
      | to       | one of ana, bo | the recipient  |
      | text     | string | the message    |
    And the tool send adds a row to outbox
    And the tool send asks first, letting the person change to
    And it has a tool peek for "Look at the outbox."
    And the tool peek lists outbox

  Scenario: the person approves, and the message goes
    Given the human approves send
    And the model calls send with {"to": "ana", "text": "hi"}
    And the model answers "sent"
    When the agent is asked "tell ana hi"
    Then the human is asked about send
    And it calls send
    And the store outbox holds:
      | to  | text |
      | ana | hi   |

  Scenario: the person refuses, and nothing goes
    Given the human refuses send
    And the model calls send with {"to": "ana", "text": "hi"}
    And the model answers "you said no, so I did not send it"
    When the agent is asked "tell ana hi"
    Then the human is asked about send
    And the call to send is refused
    And the store outbox has 0 rows
    And it stops with answered

  Scenario: the person changes the recipient at the gate
    Given the human approves send with {"to": "bo"}
    And the model calls send with {"to": "ana", "text": "hi"}
    And the model answers "sent to bo"
    When the agent is asked "tell ana hi"
    Then the store outbox holds:
      | to | text |
      | bo | hi   |

  Scenario: a tool that does not ask runs without a question
    Given the model calls peek with {}
    And the model answers "empty"
    When the agent is asked "anything out?"
    Then it calls peek
    And it stops with answered
