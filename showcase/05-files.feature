Feature: files
  The workspace in one line, read only or not, and a glob it never touches. The scenario
  gives the files, states what a file holds after, and swears nothing was written. A file
  that is not there, a path the glob keeps, a path that climbs out: each is a sentence the
  model reads, so a run never dies on a path.

  Background:
    Given the agent is called scribe
    And its model is "test:model"
    And it reads and writes the workspace
    And it never touches "secrets/**"

  Scenario: it reads before it writes
    Given the file "notes/todo.md" contains:
      """
      call the venue
      """
    And the human approves write
    And the human approves edit
    And the model calls read with {"path": "notes/todo.md"}
    And the model calls write with {"path": "notes/done.md", "text": "called the venue\n"}
    And the model answers "done"
    When the agent is asked "read notes/todo.md, then write a new file notes/done.md saying the venue was called"
    Then it calls read before write
    And the answer says "done"

  @verify-only
  Scenario: it reads what is there and writes what it is asked, byte for byte
    Given the file "notes/todo.md" contains:
      """
      call the venue
      """
    And the human approves write
    And the human approves edit
    And the model calls read with {"path": "notes/todo.md"}
    And the model calls write with {"path": "notes/done.md", "text": "called the venue\n"}
    And the model answers "done"
    When the agent is asked "read notes/todo.md, then write a new file notes/done.md saying the venue was called"
    Then it calls read before write
    And the file "notes/done.md" holds:
      """
      called the venue
      """

  @verify-only
  Scenario: a missing file is an answer, not a crash
    Given the file "notes/gone.md" is missing
    And the model calls read with {"path": "notes/gone.md"}
    And the model answers "there is no such note"
    When the agent is asked "read gone"
    Then the call to read answers "there is no notes/gone.md"
    And it stops with answered
    And nothing is written

  @verify-only
  Scenario: the glob holds against reading and writing alike
    Given the file "secrets/key.txt" contains:
      """
      sk-0000
      """
    And the human approves write
    And the model calls read with {"path": "secrets/key.txt"}
    And the model calls write with {"path": "secrets/new.txt", "text": "x"}
    And the model answers "I cannot reach secrets"
    When the agent is asked "what is the key?"
    Then the call to read answers "out of reach, by the rule secrets/**"
    And the call to write answers "out of reach"
    And nothing is written

  @verify-only
  Scenario: a path that leaves the workspace goes nowhere
    Given the model calls read with {"path": "../../etc/passwd"}
    And the model answers "no"
    When the agent is asked "read passwd"
    Then the call to read answers "climbs above the workspace"
    And nothing is written
