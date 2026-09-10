# What src/change.lua promises. The .md carries the argument -- the five layers, where the
# wall goes and why, the Goodhart split. This carries what must be true, and every scenario
# below is a way the loop could go wrong that it does not.

Feature: change -- what an agent may alter about itself

  # ------------------------------------------------------------------ the field list

  Scenario: the three editable fields are editable, on a copy
    When the declaration is loaded
    Then changing system to "a new briefing" is allowed
    And changing budget to 9 is allowed
    And changing about to "Record one line" is allowed

  Scenario: the set of editable fields is closed and cannot be grown from outside
    When the declaration is loaded
    Then the vocabulary editable is closed

  # -------------------------------------------------------------------- the refusals

  Scenario: the gate is refused by name, and that is the point
    When the declaration is loaded
    Then changing ask to true is refused because "an agent that can edit its own gate has no gate"

  Scenario: every field that is not editable is refused by its own name
    When the declaration is loaded
    Then changing run to "anything" is refused because "code and not a declaration"
    And changing name to "someone else" is refused because "renames itself"
    And changing model to "another:model" is refused because "which model answers"
    And changing tools to {} is refused because "adding or removing a tool"
    And changing beats to {} is refused because "when a run happens"
    And changing servers to {} is refused because "another process"
    And changing frobnicate to 1 is refused because "no editable field"

  # ----------------------------------------------------------------------- the gates

  Scenario: a proposal that helps is kept
    When the declaration is loaded
    Then a proposal that helps is kept

  Scenario: a proposal that raises the rate by LOSING a behaviour is refused
    When the declaration is loaded
    Then a proposal that loses is refused

  Scenario: a proposal that breaks a rule is refused even when the rate went up
    When the declaration is loaded
    Then a proposal that breaks is refused

  Scenario: a proposal that adds a failure is refused before anything else is weighed
    When the declaration is loaded
    Then a proposal that fails is refused

  Scenario: a proposal that changes nothing measurable is not kept
    When the declaration is loaded
    Then a proposal that stands is refused

  Scenario: a rules gate that was not run, or could not run, says so
    When the declaration is loaded
    Then an unchecked rules gate says so
