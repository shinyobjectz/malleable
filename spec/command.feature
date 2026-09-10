# What src/command.lua promises. The .md carries the argument -- why the parse is total
# and the naming partial, why that is not the phrase reader mar-4o07 bans, where the
# reader lives and why. This carries what must be true.

Feature: command -- what a command line DID, as a term

  # ------------------------------------------------------------------ the grammar

  Scenario: the parse is total over real command lines
    When the declaration is loaded
    Then the command line "ls -la /tmp" is unplaced 0 times
    And the command line "cd app && npm test" is unplaced 0 times
    And the command line "git add . ; git commit -m 'a message with spaces'" is unplaced 0 times
    And the command line "grep -r \"a phrase\" src/ | wc -l" is unplaced 0 times
    And the command line "python -c \"print('hi')\" 2>&1" is unplaced 1 time
    And the command line "FOO=bar BAZ=1 ./deploy.sh --flag" is unplaced 0 times
    And the command line "( cd app && npm run build )" is unplaced 0 times
    And the command line "curl -s https://x.example/a?b=c | jq '.data[]'" is unplaced 0 times

  Scenario: a here-document is refused rather than misread
    When the declaration is loaded
    Then the command line "cat <<EOF" is unplaced 1 time

  # ------------------------------------------------------------------- the naming

  Scenario: every term is reachable from a real line
    When the declaration is loaded
    Then every act is reachable from a real line:
      | line                          |
      | git status --porcelain        |
      | cat README.md                 |
      | mkdir -p build                |
      | rm -rf build                  |
      | pytest -q                     |
      | make -j8                      |
      | pip install requests          |
      | git commit -m 'done'          |
      | git push origin main          |
      | curl https://x.example        |
      | sudo systemctl restart nginx  |

  Scenario: the obvious lines read the way they plainly mean
    When the declaration is loaded
    Then the command line "git status --porcelain" did:
      """
      inspects
      """
    And the command line "rm -rf build" did:
      """
      deletes
      """
    And the command line "git push origin main" did:
      """
      publishes
      """
    And the command line "sudo -u nobody rm -rf /" did:
      """
      escalates
      """
    And the command line "curl https://x.example" did:
      """
      connects
      """

  Scenario: a line that does several things says several, sorted
    When the declaration is loaded
    Then the command line "curl -s https://x.example | jq .name" did:
      """
      connects, reads
      """
    And the command line "make && ./deploy.sh" did:
      """
      builds, publishes
      """
    And the command line "./deploy.sh && make" did:
      """
      builds, publishes
      """

  Scenario: the structural rules hold after every program there has ever been
    When the declaration is loaded
    Then the command line "echo hi > out.txt" did:
      """
      writes
      """
    And the command line "frobnicate --x > out.txt" did:
      """
      writes
      """
    And the command line "lua run-tests.lua" did:
      """
      tests
      """
    And the command line "bash ./deploy.sh" did:
      """
      publishes
      """

  Scenario: plumbing is placed and is nothing, rather than a gap
    When the declaration is loaded
    Then the command line "cd app && npm test" is unplaced 0 times
    And the command line "cd app && npm test" did:
      """
      tests
      """

  Scenario: a command it cannot name is a gap, counted, and never guessed at
    When the declaration is loaded
    Then the command line "frobnicate --x" is unplaced 1 time
    And the command line "frobnicate --x" did:
      """
      """
    And the command line "tools/cargo.sh app test --lib" is unplaced 1 time

  # ------------------------------------------------------------- rule 8, up close

  Scenario: nothing it answers is a substring of what it was given
    When the declaration is loaded
    Then nothing it answers is inside "curl -H 'Authorization: Bearer sk-secret' https://api.example/v1"
    And nothing it answers is inside "rm -rf /Users/someone/Documents/private"
    And nothing it answers is inside "git commit -m 'the message a person wrote'"
    And nothing it answers is inside "psql postgres://user:password@host/db -c 'select 1'"

  Scenario: the set of terms is closed and cannot be grown from outside
    When the declaration is loaded
    Then the vocabulary acts is closed

  # ---------------------------------------------------------- and on a run's spans

  Scenario: a shell call says what it did, and never what it ran
    Given the shell really runs
    And the file "notes/a.md" contains:
      """
      one
      """
    And the human approves shell
    And the model calls shell with { "command": "grep -c one notes/a.md" }
    And the model answers "counted"
    When the agent is asked "count them"
    Then it calls shell
    And it runs a command that inspects
    And it runs no command that publishes
    And it runs no command that deletes
