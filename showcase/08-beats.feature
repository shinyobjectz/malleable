Feature: beats
  An agent that runs by itself: a beat comes every so many seconds or at a clock time,
  asks its question, and a ledger stops it running twice in one grain. The scenario turns
  the clock and strikes it.

  Background:
    Given the agent is called digest
    And its model is "test:model"
    And the beat nightly comes every day at "18:00" and asks "summarise the day"
    And the beat nightly runs once per day
    And the beat pulse comes every 60 seconds and asks "anything new?"
    And it has a tool note for "Keep a note."
    And the tool note answers "noted"

  Scenario: the clock strikes and the beat runs
    Given the clock reads "2026-06-01T18:05:00Z"
    And pulse last ran on "2026-06-01T18:04:30Z"
    And the model answers "the day, summarised"
    When the clock strikes "2026-06-01T18:05:00Z"
    Then it stops with answered
    And it answers "the day, summarised"

  Scenario: two beats due at once are two runs, and the Then lines read the last
    Given the clock reads "2026-06-01T18:05:00Z"
    And the model answers "the day, summarised"
    And the model answers "nothing new"
    When the clock strikes "2026-06-01T18:05:00Z"
    Then it stops with answered
    And it answers "nothing new"

  Scenario: a beat that already ran today is held
    Given nightly last ran on "2026-06-01T18:01:00Z"
    And pulse last ran on "2026-06-01T18:04:30Z"
    And the clock reads "2026-06-01T18:05:00Z"
    When the clock strikes "2026-06-01T18:05:00Z"
    Then no beat is due

  Scenario: before its time, nothing is due
    Given the clock reads "2026-06-01T09:00:00Z"
    And pulse last ran on "2026-06-01T08:59:30Z"
    When the clock strikes "2026-06-01T09:00:00Z"
    Then no beat is due
