-- shell: a shell in Lua over a filesystem in Lua.
--
-- The tests that matter are the last three: that `..` cannot climb out through anything,
-- that an unknown command is refused by name rather than approximated, and that the same
-- script twice is byte-identical -- which is the whole reason to have this rather than a
-- subprocess.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local shell  = require "shell"
local double = require "double"

local T = {}

local function workspace()
  return double.fs {
    ["README.md"]        = "# a workspace\nit is small\nand it is here\n",
    ["src/turn.lua"]     = "local turn = {}\nreturn turn\n",
    ["src/spec.lua"]     = "local spec = {}\nreturn spec\n",
    ["test/a_test.lua"]  = "-- a test\n",
    ["docs/"]            = true,
  }
end

local function run(fs, line)
  return shell.line(fs, line)
end

local function out_of(fs, line)
  return run(fs, line).out
end

-- ------------------------------------------------------------------- the commands

function T.listing_is_sorted_and_a_file_names_itself()
  local fs = workspace()
  assert(out_of(fs, "ls") == "README.md\ndocs\nsrc\ntest\n", out_of(fs, "ls"))
  assert(out_of(fs, "ls src") == "spec.lua\nturn.lua\n", out_of(fs, "ls src"))
  assert(out_of(fs, "ls README.md") == "README.md\n", out_of(fs, "ls README.md"))
  assert(out_of(fs, "ls -R src") == "src/spec.lua\nsrc/turn.lua\n", out_of(fs, "ls -R src"))
end

function T.reading_writing_and_removing_go_through_the_filesystem_port()
  local fs = workspace()
  assert(out_of(fs, "cat README.md"):match("^# a workspace"))

  assert(run(fs, "echo hello > greeting.txt").code == 0)
  assert(fs.files["greeting.txt"] == "hello\n", tostring(fs.files["greeting.txt"]))
  -- Through the PORT, so the write log sees it. A shell that reached into `fs.files`
  -- would work and would be invisible to everything that watches a run.
  assert(#fs.wrote > 0 and fs.wrote[#fs.wrote].path == "greeting.txt")

  run(fs, "echo again >> greeting.txt")
  assert(fs.files["greeting.txt"] == "hello\nagain\n", tostring(fs.files["greeting.txt"]))

  assert(run(fs, "rm greeting.txt").code == 0)
  assert(fs.files["greeting.txt"] == nil)
  assert(fs.removed[#fs.removed] == "greeting.txt")
end

function T.a_directory_needs_r_and_says_so_without_it()
  local fs = workspace()
  local r = run(fs, "rm src")
  assert(r.code == 1 and r.err:match("is a directory"), r.err)
  assert(fs.files["src/turn.lua"] ~= nil, "it removed the tree anyway")

  assert(run(fs, "rm -rf src").code == 0)
  assert(fs.files["src/turn.lua"] == nil and fs.files["src/spec.lua"] == nil)
  assert(fs.files["README.md"] ~= nil, "it removed more than it was asked to")
end

function T.grep_is_a_fixed_string_and_its_exit_code_is_its_answer()
  local fs = workspace()
  assert(out_of(fs, "grep small README.md") == "it is small\n", out_of(fs, "grep small README.md"))
  assert(out_of(fs, "grep -n small README.md") == "2:it is small\n")
  assert(run(fs, "grep nothing README.md").code == 1, "grep found nothing and said 0")
  assert(run(fs, "grep small README.md").code == 0)

  -- A walk always names the file, even when it found one: a directory holding one file
  -- must not read differently from one holding two.
  -- `turn` is inside `return`, and a fixed-string grep says so. The expectation here was
  -- wrong first and the shell was right, which is the correct direction for that surprise.
  assert(out_of(fs, "grep -r turn src") ==
         "src/spec.lua:return spec\nsrc/turn.lua:local turn = {}\nsrc/turn.lua:return turn\n",
         out_of(fs, "grep -r turn src"))
  assert(out_of(fs, "grep -r 'local turn' src") == "src/turn.lua:local turn = {}\n",
         out_of(fs, "grep -r 'local turn' src"))
  assert(out_of(fs, "grep -rl return src") == "src/spec.lua\nsrc/turn.lua\n", out_of(fs, "grep -rl return src"))

  -- Fixed, not a pattern. `%w` is four characters and matches nothing here, and this
  -- shell says so rather than quietly being a Lua pattern engine.
  assert(run(fs, "grep %w README.md").code == 1, "a Lua pattern matched")
end

function T.find_globs_and_a_star_does_not_cross_a_slash()
  local fs = workspace()
  assert(out_of(fs, "find . -name '*_test.lua'") == "test/a_test.lua\n")
  assert(out_of(fs, "find src -name '*.lua'") == "src/spec.lua\nsrc/turn.lua\n")
  assert(out_of(fs, "find . -name 'src*'") == "", "a * crossed a /")
end

function T.the_counting_and_slicing_commands()
  local fs = workspace()
  assert(out_of(fs, "wc -l README.md") == "3 README.md\n", out_of(fs, "wc -l README.md"))
  assert(out_of(fs, "head -n 1 README.md") == "# a workspace\n")
  assert(out_of(fs, "tail -n 1 README.md") == "and it is here\n")
  assert(out_of(fs, "cat README.md | sort | head -n 1") == "# a workspace\n",
         out_of(fs, "cat README.md | sort | head -n 1"))
end

function T.copying_moving_and_making_directories()
  local fs = workspace()
  assert(run(fs, "cp README.md COPY.md").code == 0)
  assert(fs.files["COPY.md"] == fs.files["README.md"])

  assert(run(fs, "mv COPY.md docs").code == 0, "a destination that is a directory")
  assert(fs.files["docs/COPY.md"] ~= nil and fs.files["COPY.md"] == nil)

  assert(run(fs, "mkdir build").code == 0)
  assert(fs.exists("build"))
  assert(run(fs, "mkdir build").code == 1, "making a directory twice was silent")
  assert(run(fs, "mkdir -p build").code == 0)
end

-- The commands and flags the tests above do not reach. `spec/shell.md` promises "every
-- command in the table, its flags" and an audit found five commands and six flags with
-- nothing on them at all -- which is how a shell grows a command that never worked.
function T.the_rest_of_the_commands_and_every_flag()
  local fs = workspace()

  assert(run(fs, "true").code == 0)
  assert(run(fs, "false").code == 1)
  assert(out_of(fs, "pwd") == "/\n")

  assert(run(fs, "touch new.txt").code == 0)
  assert(fs.files["new.txt"] == "", "touch made no file")
  run(fs, "echo kept > new.txt")
  assert(run(fs, "touch new.txt").code == 0)
  assert(fs.files["new.txt"] == "kept\n", "touch emptied a file that was already there")

  -- sort
  fs.write("s.txt", "b\na\nb\n")
  assert(out_of(fs, "sort s.txt") == "a\nb\nb\n", out_of(fs, "sort s.txt"))
  assert(out_of(fs, "sort -r s.txt") == "b\nb\na\n", out_of(fs, "sort -r s.txt"))
  assert(out_of(fs, "sort -u s.txt") == "a\nb\n", out_of(fs, "sort -u s.txt"))

  -- wc, all three counts and the default
  fs.write("w.txt", "one two\nthree\n")
  assert(out_of(fs, "wc -w w.txt") == "3 w.txt\n", out_of(fs, "wc -w w.txt"))
  assert(out_of(fs, "wc -c w.txt") == "14 w.txt\n", out_of(fs, "wc -c w.txt"))
  assert(out_of(fs, "wc w.txt") == "2 3 14 w.txt\n", out_of(fs, "wc w.txt"))

  -- grep -i and -v
  assert(out_of(fs, "grep -i SMALL README.md") == "it is small\n", out_of(fs, "grep -i SMALL README.md"))
  assert(run(fs, "grep SMALL README.md").code == 1, "grep was case-blind without -i")
  assert(out_of(fs, "grep -v is README.md") == "# a workspace\n", out_of(fs, "grep -v is README.md"))
  assert(out_of(fs, "grep -c is README.md") == "2\n", out_of(fs, "grep -c is README.md"))

  -- ls -l, and the two that are honest no-ops HERE
  assert(out_of(fs, "ls -l src"):match("^%-%s+%d+ spec%.lua"), out_of(fs, "ls -l src"))
  assert(out_of(fs, "ls -a src") == out_of(fs, "ls src"), "-a changed something")
  assert(out_of(fs, "ls -1 src") == out_of(fs, "ls src"), "-1 changed something")

  -- head and tail take -N as well as -n N
  assert(out_of(fs, "head -1 README.md") == "# a workspace\n", out_of(fs, "head -1 README.md"))
  assert(out_of(fs, "tail -1 README.md") == "and it is here\n")

  -- find -type is accepted and ignored, because everything here is a file
  assert(out_of(fs, "find src -type f") == out_of(fs, "find src"))
end

-- `cp -r` used to accept the flag and copy nothing, reporting success. That is the exact
-- failure this shell's contract bans and is worse than not having the flag, because a
-- caller reads exit 0 and believes it.
function T.cp_copies_a_tree_with_r_and_refuses_one_without()
  local fs = workspace()
  local no, why = run(fs, "cp src copy"), nil
  assert(no.code ~= 0 and no.err:match("is a directory"), no.err)
  assert(fs.files["copy/turn.lua"] == nil, "it copied without -r")

  assert(run(fs, "cp -r src copy").code == 0)
  assert(fs.files["copy/turn.lua"] == fs.files["src/turn.lua"], "the tree did not arrive")
  assert(fs.files["copy/spec.lua"] == fs.files["src/spec.lua"])
  local _ = why
end

function T.a_here_document_is_refused_rather_than_misread()
  local fs = workspace()
  -- The body of a here-document is on the lines AFTER the command, and this reads one.
  -- Reading `<<EOF` as a redirect to a file called EOF and the body as further commands
  -- would be a wrong answer dressed as a right one.
  local r = run(fs, "cat <<EOF")
  assert(r.code ~= 0 and r.err:match("here%-document"), r.err)
  assert(fs.files["EOF"] == nil, "it made a file called EOF")
end

function T.an_unknown_flag_is_an_error_and_is_never_ignored()
  local fs = workspace()
  local r = run(fs, "ls -z")
  assert(r.code ~= 0 and r.err:match("unknown option"), r.err)
  -- The one that matters: a shell that quietly drops `-r` tells you it deleted a tree
  -- when it did not.
  local rm = run(fs, "rm -q src")
  assert(rm.code ~= 0 and rm.err:match("unknown option"), rm.err)
  assert(fs.files["src/turn.lua"] ~= nil, "it acted on a line it did not understand")
end

-- --------------------------------------------------------------------- the joins

function T.the_connectors_join_and_short_circuit()
  local fs = workspace()
  assert(out_of(fs, "cat nope.txt || echo fallback") == "fallback\n")
  assert(out_of(fs, "echo one && echo two") == "one\ntwo\n")
  assert(out_of(fs, "echo one ; echo two") == "one\ntwo\n")
  -- `&&` skips the REST of its chain, not just the next one.
  assert(out_of(fs, "cat nope.txt && echo a && echo b") == "", out_of(fs, "cat nope.txt && echo a && echo b"))
  -- A pipeline's exit code is the last command's.
  assert(out_of(fs, "cat README.md | grep is | wc -l") == "2\n", out_of(fs, "cat README.md | grep is | wc -l"))
end

function T.a_redirection_reads_and_writes_and_cd_lasts_for_the_line()
  local fs = workspace()
  assert(out_of(fs, "wc -l < README.md") == "3\n", out_of(fs, "wc -l < README.md"))
  assert(out_of(fs, "cd src && ls") == "spec.lua\nturn.lua\n")
  assert(out_of(fs, "cd src && pwd") == "/src\n")
  -- And it does not last past it.
  assert(out_of(fs, "pwd") == "/\n", out_of(fs, "pwd"))
end

-- ------------------------------------------------------------ what it must not do

function T.dot_dot_cannot_climb_out_through_anything()
  local fs = workspace()
  local ways = {
    "cat ../../etc/passwd",
    "ls ../..",
    "echo x > ../escape.txt",
    "cp README.md ../escape.md",
    "rm ../../thing",
    "find .. -name '*'",
    "grep x ../../etc/passwd",
    "cd ..",
  }
  for i = 1, #ways do
    local r = run(fs, ways[i])
    assert(r.code ~= 0, ways[i] .. " succeeded")
  end
  -- And nothing was written anywhere by any of them.
  for path in pairs(fs.files) do
    assert(not path:find("%.%."), "a file called " .. path .. " exists")
  end
  assert(fs.files["escape.txt"] == nil and fs.files["escape.md"] == nil)
end

function T.an_unknown_command_is_refused_by_name_with_the_list()
  local fs = workspace()
  local r = run(fs, "frobnicate --hard")
  assert(r.code == 127, r.code)
  assert(r.err:match("no such command: frobnicate"), r.err)
  -- The list, because a refusal a model can read is a fact it can act on.
  local commands = shell.commands()
  for i = 1, #commands do
    assert(r.err:find(commands[i], 1, true), commands[i] .. " is missing from the refusal")
  end
  assert(shell.has("grep") and not shell.has("frobnicate"))
end

function T.a_line_the_grammar_cannot_place_is_a_result_and_not_a_raise()
  local fs = workspace()
  local r = run(fs, "echo 'unterminated")
  assert(r.code ~= 0 and r.err:match("unclosed single quote"), r.err)
end

function T.the_same_script_twice_is_byte_identical()
  local script = {
    "mkdir -p build",
    "cat README.md > build/copy.md",
    "echo done >> build/copy.md",
    "grep -rn is .",
    "find . -name '*.lua'",
    "ls -R .",
    "wc -c build/copy.md",
  }
  local function once()
    local fs = workspace()
    local out = {}
    for i = 1, #script do
      local r = shell.line(fs, script[i])
      out[#out + 1] = string.format("%d|%s|%s", r.code, r.out, r.err)
    end
    local paths = {}
    for p, text in pairs(fs.files) do paths[#paths + 1] = p .. "=" .. text end
    table.sort(paths)
    out[#out + 1] = table.concat(paths, "\n")
    return table.concat(out, "\n--\n")
  end
  local a, b = once(), once()
  assert(a == b, "two identical runs produced different bytes")
  -- Not vacuous: the script did something.
  assert(a:find("build/copy.md", 1, true), a)
end

function T.this_file_touches_nothing()
  local f = assert(io.open(here .. "/../src/shell.lua", "rb"))
  local text = f:read("*a")
  f:close()
  local code = text:gsub("%-%-%[%[.-%]%]", " "):gsub("%-%-[^\n]*", " ")
  assert(not code:find("%f[%w]io%."), "shell.lua names io")
  assert(not code:find("%f[%w]os%."), "shell.lua names os")
  assert(not code:find("popen"), "shell.lua spawns")
end

-- ----------------------------------------------------------------------- the port

function T.the_port_runs_a_line_and_a_bare_argv_the_same_way()
  local fs = workspace()
  local sh = shell.port(fs)

  local r = assert(sh.run({ "sh", "-c", "grep -n small README.md" }))
  assert(r.code == 0 and r.out == "2:it is small\n", r.out)

  -- A direct argv is quoted back into a line, so an argument with a space cannot come
  -- apart from the same command written as a shell line.
  local direct = assert(sh.run({ "grep", "it is small", "README.md" }))
  assert(direct.code == 0 and direct.out == "it is small\n", direct.out)
  local quoted = assert(sh.run({ "sh", "-c", 'grep "it is small" README.md' }))
  assert(direct.out == quoted.out and direct.code == quoted.code)

  -- A non-zero exit is a RESULT, exactly as spec/port.md says.
  local missing = assert(sh.run({ "frobnicate" }))
  assert(missing.code == 127 and missing.err:match("no such command"))

  -- Unless a host asks otherwise.
  local strict = shell.port(fs, { strict = true })
  local none, why = strict.run({ "frobnicate" })
  assert(none == nil and type(why) == "table" and why.code == "not_found", tostring(why))

  -- cwd obeys the filesystem's path rule, and the empty string is named.
  local _, denied = sh.run({ "ls" }, { cwd = ".." })
  assert(denied ~= nil and denied.code == "denied", tostring(denied))
  local _, empty = sh.run({ "ls" }, { cwd = "" })
  assert(empty ~= nil and empty.message:match("omit `cwd`"), tostring(empty))
end

-- ------------------------------------------------------------- the embed door

-- A whole agent, running inside its own world, with nothing from the host.
--
-- This is the claim `bin/malleable.lua` makes true by being twenty lines long: not one
-- module names `io` or `os`, so the harness runs wherever a Lua does. What was missing
-- was never portability -- it was a world to hand it that did not come from outside.
function T.an_agent_runs_to_completion_with_no_host_ports_at_all()
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "keeper"; agent.model "sandbox:scripted"
  agent.shell { root = ".", about = "Run one command." }

  local world = agent.sandbox {
    fs  = { ["notes/a.md"] = "one\ntwo\n", ["notes/b.md"] = "two\n" },
    ask = { shell = true },
    model = {
      { tool = "shell", args = { command = "ls notes" } },
      { tool = "shell", args = { command = "cat notes/a.md notes/b.md | sort -u > notes/all.md" } },
      { text = "folded" },
    },
  }

  -- Every port is there and none of them came from outside.
  for _, name in ipairs({ "model", "fs", "sh", "clock", "ask", "log" }) do
    assert(type(world[name]) == "table", "the sandbox has no " .. name)
  end

  local r = agent.run("tidy", world)
  assert(r.stop == "answered", r.stop .. ": " .. tostring(r.reason))
  assert(r.calls[1].output:find("a.md", 1, true), r.calls[1].output)

  -- The commands were REALLY RUN: this file was written by one of them, not scripted.
  assert(world.fs.files["notes/all.md"] == "one\ntwo\n", tostring(world.fs.files["notes/all.md"]))
  agent.reset()
end

function T.a_sandbox_refuses_by_default_and_a_test_world_still_scripts_its_shell()
  local agent = dofile(here .. "/../agent.lua")

  -- A sandbox is where an agent is allowed to try things, which is exactly where a gate
  -- saying yes by default would be worst. A host that wants otherwise says so in writing.
  local shut = agent.sandbox { fs = { ["a.md"] = "x\n" } }
  local answer = shut.ask.request({ tool = "shell", args = {} })
  assert(type(answer) == "table" and answer.allow == false, "the sandbox approved by default")

  -- And `agent.world` is unchanged: a test double still refuses what it was not given,
  -- because "nothing is scripted for that" is the most useful sentence a double says.
  local test_world = agent.world { fs = { ["a.md"] = "x\n" } }
  local none, why = test_world.sh.run({ "sh", "-c", "cat a.md" })
  assert(none == nil and why.code == "unscripted", tostring(why and why.code))

  -- Opt in and the same world runs it.
  local live = agent.world { fs = { ["a.md"] = "x\n" }, shell = true }
  local r = assert(live.sh.run({ "sh", "-c", "cat a.md" }))
  assert(r.out == "x\n", r.out)
  agent.reset()
end

function T.the_shell_and_the_filesystem_in_a_sandbox_are_the_same_one()
  -- The bug this catches is the obvious one: an executor over a DIFFERENT filesystem
  -- from the one the fs tools read, so a file the agent wrote is a file it cannot find.
  local agent = dofile(here .. "/../agent.lua")
  local world = agent.sandbox {}
  assert(world.sh.run({ "sh", "-c", "echo hi > made.txt" }))
  assert(world.fs.read("made.txt") == "hi\n", tostring(world.fs.read("made.txt")))
  assert(world.fs.files["made.txt"] == "hi\n")
  -- And it went through the port, so anything watching the run saw it.
  assert(#world.fs.wrote == 1 and world.fs.wrote[1].path == "made.txt")
  agent.reset()
end

function T.wrong_shapes_raise()
  local fs = workspace()
  assert(not pcall(shell.line, fs, 7))
  assert(not pcall(shell.port, 7))
  assert(not pcall(shell.port, {}))
  local sh = shell.port(fs)
  assert(not pcall(sh.run, "ls"), "a command string was accepted where argv belongs")
end

return T
