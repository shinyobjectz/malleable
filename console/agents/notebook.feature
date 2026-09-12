# The home screen's agent: it reads and keeps the person's notes. Talk to it with
#
#     love console                                        (the home screen)
#     lua bin/malleable.lua --talk console/agents/notebook.feature --root <a folder of notes>
#
# and a talker answers each turn at once, handing the work to this agent as background
# jobs (docs/spec/speech.md). It writes only after the person says yes, which the talker asks.

Feature: notebook
  Reads and keeps the person's notes, as markdown files under notes/.

  Background:
    Given the agent is called notebook
    And its model is "openrouter:z-ai/glm-5.3"
    And its reasoning is low
    And it is briefed:
      """
      You read and keep the person's notes, as markdown files under notes/. Look at what is there before you answer. Answer briefly, with what you found or did, naming the files.
      """
    And it reads and writes the workspace
    And it never touches "secrets/**"
    And it can read its history
    And it hands work to the agent in "reader.feature" as reader
    And the tool write asks first

  Scenario: it reads a note
    Given the file "notes/budget.md" contains:
      """
      The venue costs 1200. Catering is 800.
      """
    And the model calls read with {"path": "notes/budget.md"}
    And the model answers "notes/budget.md: the venue is 1200 and catering 800."
    When the agent is asked "what does my budget note say?"
    Then it calls read
    And the answer says "1200"

  Scenario: it asks before it writes
    Given the human refuses write
    And the model calls write with {"path": "notes/todo.md", "text": "call the venue"}
    And the model answers "I did not write it: you said no."
    When the agent is asked "note that I must call the venue"
    Then the call to write is refused
