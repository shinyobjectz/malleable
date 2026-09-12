Feature: servers
  A server whose tools live in another process is named in a table, and the declaration
  reaches nothing: at run time the world says what the server offers. Its tools are named
  server_tool so two servers offering the same name never collide, and they ask by default.
  The doubles' server offers a tool with no arguments, so the calls here carry none; a real
  server's schema gives its tools theirs.

  Background:
    Given the agent is called librarian
    And its model is "test:model"
    And it uses the server books with:
      | key     | value                                |
      | command | npx -y some-books-server             |
      | tools   | search, lend                         |
    And it has a tool shelve for "Put a book back."
    And the tool shelve answers "shelved"

  Scenario: a fetched tool is offered and answers through the port
    Given the server books offers search and it answers "Dune, Emma"
    And the server books offers lend and it answers "lent"
    And the human approves books_search
    And the model calls books_search with {}
    And the model answers "Dune and Emma"
    When the agent is asked "what novels are there?"
    Then the human is asked about books_search
    And the call to books_search answers "Dune"
    And it answers "Dune and Emma"

  Scenario: a fetched tool refused at the gate is a result
    Given the server books offers lend and it answers "lent"
    And the human refuses books_lend
    And the model calls books_lend with {}
    And the model answers "you did not allow the loan"
    When the agent is asked "lend me Dune"
    Then the call to books_lend is refused
