Feature: kits
  A kit is a capability the workspace adds in one Lua file: the lines that say it, which way
  each moves reach, the tools it installs, and the lines a scenario says its world with.
  Loaded, its lines are vocabulary; the wall scores them by the reach the kit declared
  (docs/spec/kit.md). The kit here is showcase/kits/calendar.lua.

  Background:
    Given the agent is called planner
    And its model is "test:model"
    And it uses the kit "kits/calendar.lua"
    And it keeps a calendar
    And the calendar holds at most 2 events

  Scenario: the kit's tool books into the kit's store, and the kit's own line reads it back
    Given the calendar has "standup" at "2026-09-14 09:00"
    And the model calls book with {"title": "review", "at": "2026-09-14 11:00"}
    And the model calls agenda with {}
    And the model answers "standup at nine, review at eleven"
    When the agent is asked "book the review at 11:00 on 2026-09-14 and then show the day"
    Then the call to book answers "booked review"
    And the calendar holds "review"
    And the store events has 2 rows
    And the call to agenda answers "standup"

  Scenario: the narrowing line holds, and a third event is refused
    Given the calendar has "standup" at "2026-09-14 09:00"
    And the calendar has "lunch" at "2026-09-14 12:00"
    And the model calls book with {"title": "late", "at": "2026-09-14 18:00"}
    And the model answers "the calendar is full"
    When the agent is asked "book something late on 2026-09-14"
    Then the call to book fails
    And the store events has 2 rows
    And the answer says "full"
