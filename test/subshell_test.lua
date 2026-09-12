-- docs/spec/subshell.md: the one host shell, and what it keeps out of the child.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. here .. "/../bin/?.lua;" .. package.path

local subshell = require "subshell"

local T = {}

local function scratch()
  local d = os.tmpname()
  os.remove(d)
  os.execute("mkdir -p '" .. d .. "/inner'")
  return d
end

function T.a_command_runs_under_the_root_with_only_the_given_environment()
  local root = scratch()
  local lines = {}
  local sh = subshell.port(root, { env = { PATH = "/usr/bin:/bin" }, log = function (l) lines[#lines + 1] = l end })
  local r = assert(sh.run { "sh", "-c", "pwd; echo ${HOME:-none}; echo ${OPENROUTER_API_KEY:-none}" })
  assert(r.code == 0 and r.timed_out == false, tostring(r.code))
  local pwd, home, key = r.out:match("^(.-)\n(.-)\n(.-)\n$")
  assert(pwd and pwd:sub(-#root) == root or pwd == root, "ran in " .. tostring(pwd))
  assert(home == "none", "HOME leaked: " .. tostring(home))
  assert(key == "none", "the key leaked")
  assert(#lines == 1 and lines[1]:match("^exit 0 in %d+s: sh %-c"), tostring(lines[1]))
  os.execute("rm -rf '" .. root .. "'")
end

function T.a_non_zero_exit_is_a_result_and_stderr_comes_back()
  local root = scratch()
  local sh = subshell.port(root, { env = { PATH = "/usr/bin:/bin" } })
  local r = assert(sh.run { "sh", "-c", "echo bad >&2; exit 3" })
  assert(r.code == 3 and r.err == "bad\n" and r.out == "", r.err)
  os.execute("rm -rf '" .. root .. "'")
end

function T.cwd_is_under_the_root_and_cannot_leave_it()
  local root = scratch()
  local sh = subshell.port(root, { env = { PATH = "/usr/bin:/bin" } })
  local r = assert(sh.run({ "sh", "-c", "pwd" }, { cwd = "inner" }))
  assert(r.out:match("/inner\n$"), r.out)
  local nothing, err = sh.run({ "sh", "-c", "pwd" }, { cwd = "../elsewhere" })
  assert(nothing == nil and err.code == "denied", tostring(err and err.code))
  nothing, err = sh.run({ "sh", "-c", "pwd" }, { cwd = "missing" })
  assert(nothing == nil and err.code == "denied", tostring(err and err.code))
  os.execute("rm -rf '" .. root .. "'")
end

function T.the_deadline_kills_the_command_and_answers_timeout()
  local root = scratch()
  local lines = {}
  local sh = subshell.port(root, { env = { PATH = "/usr/bin:/bin" }, log = function (l) lines[#lines + 1] = l end })
  local nothing, err = sh.run({ "sh", "-c", "sleep 5; echo late" }, { timeout = 1 })
  assert(nothing == nil and err.code == "timeout", tostring(err and err.code))
  assert(lines[1]:match("^timeout after 1s"), tostring(lines[1]))
  os.execute("rm -rf '" .. root .. "'")
end

function T.a_missing_program_is_not_found_and_stdin_reaches_the_child()
  local root = scratch()
  local sh = subshell.port(root, { env = { PATH = "/usr/bin:/bin" } })
  local nothing, err = sh.run { "no-such-program-here" }
  assert(nothing == nil and err.code == "not_found", tostring(err and err.code))
  local r = assert(sh.run({ "sh", "-c", "cat" }, { stdin = "fed\n" }))
  assert(r.out == "fed\n", r.out)
  os.execute("rm -rf '" .. root .. "'")
end

return T
