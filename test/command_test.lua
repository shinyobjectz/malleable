-- command: what a command line did, as a term, so the command itself never travels.
--
-- Two halves, and the tests are split the same way. The parse is TOTAL and a line it
-- cannot place is a defect here; the naming is PARTIAL and a command it cannot name is a
-- gap that gets counted. The test that matters most is the last one: nothing this module
-- answers is a substring of what it was given.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local command = require "command"
local trace   = require "trace"

local T = {}

local function acts_of(line)
  return table.concat(command.acts(line).acts, ", ")
end

-- ------------------------------------------------------------------ the grammar

function T.the_parse_is_total_over_real_command_lines()
  local lines = {
    "ls",
    "ls -la /tmp",
    "cd app && npm test",
    "make || echo failed",
    "git add . ; git commit -m 'a message with spaces'",
    'grep -r "a phrase" src/ | wc -l',
    "cat a.txt > b.txt",
    "python -c \"print('hi')\" 2>&1",
    "FOO=bar BAZ=1 ./script.sh --flag",
    "( cd app && npm run build )",
    "rsync -a --delete demo/ ~/Documents/demo/",
    "find . -name '*.tmp' -exec rm {} \\;",
    "curl -s https://x.example/a?b=c | jq '.data[]'",
    "tools/cargo.sh app test --lib",
  }
  for i = 1, #lines do
    local parsed, why, where = command.parse(lines[i])
    assert(parsed, "the grammar could not place " .. lines[i]
      .. ": " .. tostring(why) .. " at " .. tostring(where))
    assert(#parsed > 0, "nothing was found in " .. lines[i])
  end
end

function T.the_operators_join_and_the_quotes_hold()
  local p = command.parse("cd app && npm test")
  assert(#p == 2, #p)
  assert(p[1].argv[1] == "cd" and p[1].joined == "&&", p[1].joined)
  assert(p[2].argv[1] == "npm" and p[2].argv[2] == "test")

  -- A quoted argument is ONE word, whatever is inside it, and the quotes are gone.
  local q = command.parse("git commit -m 'two words'")
  assert(#q[1].argv == 4, #q[1].argv)
  assert(q[1].argv[4] == "two words", q[1].argv[4])

  -- A redirection is not an argument, and its target is not a command.
  local r = command.parse("cat a.txt > b.txt")
  assert(#r == 1 and #r[1].argv == 2, "the redirect leaked into argv")
  assert(r[1].redirects[1].op == ">" and r[1].redirects[1].target == "b.txt")
end

function T.a_line_the_grammar_cannot_place_says_where_it_stopped()
  local p, why, where = command.parse("echo 'unterminated")
  assert(p == nil, "an unclosed quote parsed anyway")
  assert(why:match("unclosed single quote"), why)
  assert(type(where) == "number", "the failure says no position")
  -- And it is a gap on the report, not a raise.
  local read = command.acts("echo 'unterminated")
  assert(read.unplaced == 1 and #read.acts == 0)
end

-- ------------------------------------------------------------------- the naming

function T.each_term_is_reachable_and_the_obvious_lines_read_right()
  local cases = {
    { "git status --porcelain",          "inspects" },
    { "cat README.md",                   "reads" },
    { "mkdir -p build",                  "writes" },
    { "rm -rf build",                    "deletes" },
    { "pytest -q",                       "tests" },
    { "make -j8",                        "builds" },
    { "pip install requests",            "installs" },
    { "git commit -m 'done'",            "commits" },
    { "git push origin main",            "publishes" },
    { "curl https://x.example",          "connects" },
    { "sudo systemctl restart nginx",    "escalates" },
  }
  local reached = {}
  for i = 1, #cases do
    local got = acts_of(cases[i][1])
    assert(got == cases[i][2], cases[i][1] .. " reads as " .. got .. ", not " .. cases[i][2])
    reached[cases[i][2]] = true
  end
  -- Every term in the closed set is reachable from a real line. A term nothing can reach
  -- is vocabulary nobody can measure.
  local all = command.ACTS
  for i = 1, #all do
    assert(reached[all[i]], "no line in this test reaches " .. all[i])
  end
end

-- The other half of the promise, and the half that is easy to skip: not only that every
-- term is reachable, but that no term is reachable from a line that plainly means another.
-- A vocabulary where `git push` reads as `inspects` is worse than one with a gap in it,
-- because a gap is counted and a wrong term is believed.
-- Found by the long-task eval: the model's every install, test and build went unplaced.
function T.npm_aliases_and_npx_are_named_by_what_they_run()
  local function acts(line) local a = command.acts(line).acts; table.sort(a); return table.concat(a, ",") end
  assert(acts("npm init -y && npm i -D typescript vitest") == "installs,writes", acts("npm init -y && npm i -D typescript vitest"))
  assert(acts("npx vitest run") == "tests")
  assert(acts("npx --yes tsc --noEmit") == "builds")
  assert(acts("npm exec vitest") == "tests")
  assert(acts("npm pkg set scripts.test=vitest") == "writes")
  assert(command.acts("npx some-unknown-thing").unplaced == 1)
  assert(command.acts("node dist/cli.js add x").unplaced == 1)
end

function T.no_term_is_reachable_from_a_line_that_plainly_means_another()
  local wrong = {
    { "git push origin main",        must_not = { "inspects", "reads", "tests" } },
    { "rm -rf build",                must_not = { "writes", "builds", "inspects" } },
    { "sudo ls",                     must_not = { "inspects" } },
    { "curl https://x.example",      must_not = { "reads", "installs" } },
    { "cat README.md",               must_not = { "writes", "deletes" } },
    { "git status",                  must_not = { "commits", "publishes", "writes" } },
    { "pytest -q",                   must_not = { "builds", "publishes" } },
    { "npm install",                 must_not = { "tests", "builds" } },
  }
  for i = 1, #wrong do
    local read = command.acts(wrong[i][1])
    for _, banned in ipairs(wrong[i].must_not) do
      for j = 1, #read.acts do
        assert(read.acts[j] ~= banned,
               wrong[i][1] .. " reads as " .. banned .. ", which is not what it does")
      end
    end
  end
end

function T.a_line_that_does_several_things_says_several()
  assert(acts_of("curl -s https://x.example | jq .name") == "connects, reads")
  assert(acts_of("make && ./deploy.sh") == "builds, publishes")
  -- Sorted, so the same line reads the same twice and two runs can be compared.
  assert(acts_of("./deploy.sh && make") == "builds, publishes")
end

function T.a_redirection_into_a_file_writes_whatever_ran()
  -- Structural, not a table entry: `>` has meant the same thing after every program
  -- there has ever been, so no list can be missing an entry for it.
  assert(acts_of("echo hi > out.txt") == "writes")
  assert(acts_of("cat a.txt >> b.txt") == "writes")
  assert(acts_of("frobnicate --x > out.txt") == "writes")
end

function T.escalation_is_what_the_command_is_whatever_it_went_on_to_run()
  assert(acts_of("sudo ls") == "escalates")
  assert(acts_of("sudo -u nobody rm -rf /") == "escalates")
end

function T.plumbing_is_placed_and_is_nothing_rather_than_a_gap()
  local read = command.acts("cd app && npm test")
  assert(read.commands == 2 and read.unplaced == 0, "cd was counted as a gap")
  assert(#read.acts == 1 and read.acts[1] == "tests")
  local _, plain = command.act(command.parse("cd app")[1])
  assert(plain == "plain", tostring(plain))
end

function T.a_command_it_cannot_name_is_a_gap_and_is_counted()
  local read = command.acts("frobnicate --x")
  assert(#read.acts == 0 and read.unplaced == 1 and read.commands == 1)
  -- A wrapper script this reader has never heard of is a gap too, and that is CORRECT:
  -- `tools/cargo.sh app test` does run tests, and nothing here can know that. Guessing
  -- from the arguments is how a reader starts passing by tautology (mar-4o07).
  local wrapper = command.acts("tools/cargo.sh app test --lib")
  assert(wrapper.unplaced == 1, "the reader guessed at a wrapper it cannot know")
end

-- ------------------------------------------------------------- rule 8, up close

function T.nothing_it_answers_is_a_substring_of_what_it_was_given()
  local lines = {
    "curl -H 'Authorization: Bearer sk-secret' https://api.example/v1",
    "rm -rf /Users/someone/Documents/private",
    "git commit -m 'the message a person wrote'",
    "psql postgres://user:password@host/db -c 'select 1'",
  }
  for i = 1, #lines do
    local read = command.acts(lines[i])
    for j = 1, #read.acts do
      assert(not lines[i]:find(read.acts[j], 1, true),
        "the term " .. read.acts[j] .. " is a substring of the line it came from")
      assert(command.known(read.acts[j]), read.acts[j] .. " is not in the closed set")
    end
  end
end

function T.the_vocabulary_here_and_the_one_the_trace_gates_are_the_same()
  -- `src/trace.lua` writes this set out rather than requiring this file, because it
  -- reaches nothing and that is asserted. Two lists kept apart by a rule need a test
  -- keeping them together, or the rule quietly becomes a drift.
  local gated = trace.MINTED["malleable.act"]
  assert(type(gated) == "table" and type(gated.set) == "table", "malleable.act is not a set")
  local here_set, there_set = {}, {}
  local mine = command.ACTS
  for i = 1, #mine do here_set[mine[i]] = true end
  for i = 1, #gated.set do there_set[gated.set[i]] = true end
  for term in pairs(here_set) do
    assert(there_set[term], term .. " is a term here and the trace would refuse it")
  end
  for term in pairs(there_set) do
    assert(here_set[term], term .. " is gated by the trace and nothing here produces it")
  end
  -- And the gate does its job on a joined value.
  assert(trace.allowed("malleable.act", "connects, reads"))
  assert(not trace.allowed("malleable.act", "reads, frobnicates"))
end

function T.the_closed_set_is_a_fresh_list_and_cannot_be_grown_from_outside()
  local a, b = command.ACTS, command.ACTS
  assert(a ~= b, "two reads answered the same table")
  a[#a + 1] = "invents"
  assert(#command.ACTS == #b, "the set grew")
  assert(not command.known("invents"))
end

function T.wrong_shapes_raise()
  local ok = pcall(command.parse, 7)
  assert(not ok, "a number parsed as a command line")
  assert(command.act(nil) == nil)
  assert(command.act({}) == nil)
end

return T
