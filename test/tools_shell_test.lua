-- tools_shell — the shell tool. Tests.
--
-- Every one of these runs with no subprocess, no disk and no clock: the shell port is
-- a table literal whose exec returns whatever the test says, including nothing at all.
-- The fake records what it was asked, so a refusal can prove the port was never
-- reached, which is the whole point of a refusal.

local function module(name)
  local ok, m = pcall(require, name)
  if ok then return m end
  return require("src." .. name)
end

local shell = module("tools_shell")

local T = {}

-- ---------------------------------------------------------------------------
-- helpers

local ROOT = "/w/space"

-- A real segment-wise resolver, not a prefix check. Whether a path escapes is the path
-- layer's judgement; these tests hand the tool one that judges correctly and one that
-- refuses, and assert the tool obeys either way.
local function resolve(root, rel)
  if type(rel) ~= "string" or rel == "" then return nil, "an empty path names nothing." end
  if string.sub(rel, 1, 1) == "/" then return nil, "an absolute path is not workspace-relative." end
  local parts = {}
  for seg in string.gmatch(rel, "[^/]+") do
    if seg == "." then
      parts = parts
    elseif seg == ".." then
      if #parts == 0 then return nil, "that climbs out of the workspace." end
      parts[#parts] = nil
    else
      parts[#parts + 1] = seg
    end
  end
  if #parts == 0 then return root end
  return root .. "/" .. table.concat(parts, "/")
end

local function spy(answer)
  local f = { calls = {} }
  f.exec = function (request)
    f.calls[#f.calls + 1] = request
    if type(answer) == "function" then return answer(request) end
    return answer
  end
  return f
end

local function ctx_of(f, args)
  return { exec = f.exec, root = ROOT, resolve = resolve, args = args or {} }
end

local function exited(code, out, err)
  return { status = "exited", code = code, stdout = out or "", stderr = err or "", duration_ms = 12 }
end

local function has(s, want)
  return string.find(s, want, 1, true) ~= nil
end

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[deep_copy(k)] = deep_copy(x) end
  return out
end

local function deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- Whole UTF-8 characters only: no leading continuation byte, no sequence cut short.
local function utf8_whole(s)
  local i = 1
  while i <= #s do
    local b = string.byte(s, i)
    local need
    if b < 128 then need = 0
    elseif b < 192 then return false          -- a continuation byte cannot start one
    elseif b < 224 then need = 1
    elseif b < 240 then need = 2
    elseif b < 248 then need = 3
    else return false end
    if i + need > #s then return false end
    for j = i + 1, i + need do
      local c = string.byte(s, j)
      if c == nil or c < 128 or c > 191 then return false end
    end
    i = i + need + 1
  end
  return true
end

local function marker_of(dropped)
  return "\n... " .. tostring(dropped) .. " bytes elided ...\n"
end

local function source_text()
  local tried = { "src/tools_shell.lua", "../src/tools_shell.lua", "vendor/malleable/src/tools_shell.lua" }
  if package.searchpath then
    local p = package.searchpath("tools_shell", package.path)
    if p then table.insert(tried, 1, p) end
    local q = package.searchpath("src.tools_shell", package.path)
    if q then table.insert(tried, 1, q) end
  end
  for i = 1, #tried do
    local fh = io.open(tried[i], "rb")
    if fh then
      local s = fh:read("*a")
      fh:close()
      if s and #s > 0 then return s end
    end
  end
  return nil
end

-- "require" as a call, not as the word `required` in a parameter shape.
local function calls_require(src)
  local at = 1
  while true do
    local i = string.find(src, "require", at, true)
    if not i then return false end
    local after = string.sub(src, i + 7, i + 7)
    if not string.find(after, "^%a") then return true end
    at = i + 7
  end
end

local function statuses_of(result)
  return result.status .. "/" .. tostring(result.reason)
end

-- ---------------------------------------------------------------------------
-- 1. the file touches nothing

function T.shell_names_no_vendor()
  local src = source_text()
  assert(src, "could not find src/tools_shell.lua to scan")
  local forbidden = { "os.", "io.", "print", "dofile", "loadstring", "string.pack", "coroutine." }
  for i = 1, #forbidden do
    assert(not has(src, forbidden[i]),
      "the shell tool names " .. forbidden[i] .. ", and it may not touch the world directly")
  end
  assert(not calls_require(src), "the shell tool calls require, and it may not reach into a sibling")
end

-- ---------------------------------------------------------------------------
-- 2-3. declaring runs nothing

function T.declaring_runs_nothing()
  local ran = 0
  local exploding = { exec = function () ran = ran + 1 error("a declaration ran a body") end }
  local decl = shell.tool { timeout_ms = 120000 }
  assert(ran == 0)
  assert(type(decl.about) == "string" and decl.about ~= "")
  assert(decl.ask == true, "the shell tool asks before it runs")
  assert(type(decl.run) == "function")
  assert(decl.args.command.required == true)
  assert(decl.args.cwd.required == false)
  assert(decl.args.timeout_ms.required == false)
  -- and no fifth key
  local keys = {}
  for k in pairs(decl) do keys[#keys + 1] = k end
  table.sort(keys)
  assert(table.concat(keys, ",") == "about,args,ask,run", table.concat(keys, ","))
  assert(exploding.exec ~= nil and ran == 0)
end

-- The declaration this tool builds is one the declaration surface accepts. The module
-- names no sibling, so this is where the two shapes are checked against each other.
function T.the_declaration_is_one_spec_accepts()
  local ok, spec = pcall(module, "spec")
  if not ok then return end          -- the surface is another agent's file; skip if absent
  local a = spec.new()
  spec.add_tool(a, "shell", shell.tool {})
  local schema = spec.schema(a)
  assert(#schema == 1)
  assert(schema[1].name == "shell")
  assert(schema[1].ask == true)
  assert(#schema[1].args == 3)
  for i = 1, 3 do
    assert(type(schema[1].args[i].description) == "string" and schema[1].args[i].description ~= "")
  end
end

-- ---------------------------------------------------------------------------
-- 3-6. the happy paths

function T.a_command_that_exits_zero()
  local f = spy(exited(0, "hello\n", ""))
  local r = shell.run(ctx_of(f, { command = "echo hello" }))
  assert(r.status == "exited")
  assert(r.ok == true)
  assert(r.code == 0)
  assert(r.stdout == "hello\n")
  assert(r.reason == nil and r.detail == nil)
  assert(r.command == "echo hello")
  assert(r.cwd == ROOT)
  assert(#f.calls == 1)
  assert(f.calls[1].command == "echo hello", "the command is passed verbatim")
  assert(has(r.text, "$ echo hello"))
  assert(has(r.text, "hello\n"))
  assert(has(r.text, "exit 0"))
end

function T.a_failing_command_is_a_successful_call()
  local f = spy(exited(1, "1 failing\n", "AssertionError\n"))
  local r = shell.run(ctx_of(f, { command = "npm test" }))
  assert(r.ok == true, "a non-zero exit is a successful tool call")
  assert(r.status == "exited")
  assert(r.code == 1)
  assert(r.reason == nil)
  assert(r.detail == nil)
end

function T.stderr_is_kept_separate()
  local f = spy(exited(2, "out here\n", "err there\n"))
  local r = shell.run(ctx_of(f, { command = "make" }))
  assert(r.stdout == "out here\n")
  assert(r.stderr == "err there\n")
  assert(not has(r.stdout, "err there"))
  assert(not has(r.stderr, "out here"))
  local at_out = string.find(r.text, "--- stdout", 1, true)
  local at_err = string.find(r.text, "--- stderr", 1, true)
  assert(at_out and at_err and at_out < at_err)
  assert(has(r.text, "out here"))
  assert(has(r.text, "err there"))
end

function T.no_output_renders_as_empty_not_missing()
  local f = spy(exited(0, "", ""))
  local r = shell.run(ctx_of(f, { command = "true" }))
  assert(r.stdout == "", "empty output is the empty string, never nil")
  assert(r.stderr == "")
  assert(has(r.text, "--- stdout (empty) ---"))
  assert(has(r.text, "--- stderr (empty) ---"))
end

-- ---------------------------------------------------------------------------
-- 7-13. the refusals. None of these reaches the port.

function T.an_empty_command_is_refused()
  for _, cmd in ipairs { "", "   ", "\t\n " } do
    local f = spy(exited(0))
    local r = shell.run(ctx_of(f, { command = cmd }))
    assert(r.status == "refused")
    assert(r.reason == "empty_command", statuses_of(r))
    assert(r.ok == false)
    assert(#f.calls == 0, "a refusal never reaches the port")
  end
end

function T.a_missing_command_is_refused_not_raised()
  local f = spy(exited(0))
  local ok, r = pcall(shell.run, ctx_of(f, {}))
  assert(ok, "a missing argument is a refusal, not a raise")
  assert(r.reason == "no_command")
  assert(r.command == nil)
  assert(#f.calls == 0)

  -- a command of the wrong type is the same refusal
  local ok2, r2 = pcall(shell.run, ctx_of(f, { command = 42 }))
  assert(ok2 and r2.reason == "no_command")
end

function T.a_command_with_a_zero_byte_is_refused()
  local f = spy(exited(0))
  local r = shell.run(ctx_of(f, { command = "ls\0-la" }))
  assert(r.status == "refused")
  assert(r.reason == "command_has_nul", statuses_of(r))
  assert(#f.calls == 0)
end

function T.a_command_over_the_length_cap_is_refused()
  local f = spy(exited(0))
  local long = string.rep("x", 8193)
  local r = shell.run(ctx_of(f, { command = long }))
  assert(r.reason == "command_too_long", statuses_of(r))
  assert(has(r.detail, "8193"))
  assert(has(r.detail, "8192"))
  assert(#f.calls == 0)
  -- and exactly at the cap it is not refused
  local g = spy(exited(0))
  local r2 = shell.run(ctx_of(g, { command = string.rep("x", 8192) }))
  assert(r2.status == "exited")
  assert(#g.calls == 1)
end

function T.a_cwd_outside_the_root_is_refused()
  for _, rel in ipairs { "..", "../..", "/etc", "a/../../b" } do
    local f = spy(exited(0))
    local r = shell.run(ctx_of(f, { command = "ls", cwd = rel }))
    assert(r.status == "refused", rel)
    assert(r.reason == "cwd_escapes_root", rel .. " gave " .. statuses_of(r))
    assert(#f.calls == 0, "a refused directory never reaches the port")
    assert(has(r.text, rel))
  end

  -- The bug a lexical prefix check always has: "/w/space" is not inside "/w/spa".
  local f = spy(exited(0))
  local c = { exec = f.exec, root = "/w/spa", resolve = resolve, args = { command = "ls", cwd = "../space" } }
  local r = shell.run(c)
  assert(r.status == "refused")
  assert(r.reason == "cwd_escapes_root", statuses_of(r))
  assert(#f.calls == 0)
end

function T.a_cwd_with_no_resolve_port_is_refused()
  local f = spy(exited(0))
  local r = shell.run { exec = f.exec, root = ROOT, args = { command = "ls", cwd = "ui" } }
  assert(r.status == "refused")
  assert(r.reason == "cwd_unsupported", statuses_of(r))
  assert(#f.calls == 0)

  -- the same context with no cwd argument works, and runs in the root
  local g = spy(exited(0))
  local r2 = shell.run { exec = g.exec, root = ROOT, args = { command = "ls" } }
  assert(r2.status == "exited", statuses_of(r2))
  assert(r2.cwd == ROOT)
  assert(g.calls[1].cwd == ROOT)

  -- a non-string cwd is its own refusal, before any resolving
  local h = spy(exited(0))
  local r3 = shell.run(ctx_of(h, { command = "ls", cwd = 7 }))
  assert(r3.reason == "bad_cwd", statuses_of(r3))
  assert(#h.calls == 0)
end

function T.a_bad_timeout_is_refused()
  for _, bad in ipairs { 0, -1, 1.5, "30s", true } do
    local f = spy(exited(0))
    local r = shell.run(ctx_of(f, { command = "sleep 1", timeout_ms = bad }))
    assert(r.status == "refused", tostring(bad))
    assert(r.reason == "bad_timeout", tostring(bad) .. " gave " .. statuses_of(r))
    assert(#f.calls == 0, "a refused timeout is never quietly clamped and run anyway")
  end

  local f = spy(exited(0))
  local r = shell.run(ctx_of(f, { command = "sleep 1", timeout_ms = 600001 }))
  assert(r.reason == "timeout_too_long", statuses_of(r))
  assert(has(r.detail, "600001"))
  assert(has(r.detail, "600000"))
  assert(#f.calls == 0, "the timeout is never clamped: a shortened one is a lie")

  -- and a legal one reaches the port unchanged
  local g = spy(exited(0))
  shell.run(ctx_of(g, { command = "sleep 1", timeout_ms = 5000 }))
  assert(g.calls[1].timeout_ms == 5000)
end

-- ---------------------------------------------------------------------------
-- 14-20. the faults

function T.a_timeout_keeps_the_partial_output()
  local partial = string.rep("y", 400)
  local f = spy { status = "timeout", stdout = partial, stderr = "", duration_ms = 30000 }
  local r = shell.run(ctx_of(f, { command = "sleep 99" }))
  assert(r.status == "timeout")
  assert(r.ok == false)
  assert(r.code == nil)
  assert(r.reason == "timed_out")
  assert(r.stdout == partial, "partial output from a hung command is the diagnosis")
  assert(has(r.text, partial))
  assert(r.duration_ms == 30000)
end

function T.a_timeout_states_the_limit_it_hit()
  local f = spy { status = "timeout", stdout = "", stderr = "" }
  local r = shell.run(ctx_of(f, { command = "sleep 99" }))
  assert(has(r.detail, "30000"), r.detail)      -- the default, not an argument
  assert(f.calls[1].timeout_ms == 30000)

  local g = spy { status = "timeout", stdout = "", stderr = "" }
  local r2 = shell.run(ctx_of(g, { command = "sleep 99", timeout_ms = 4321 }))
  assert(has(r2.detail, "4321"), r2.detail)
end

function T.spawn_failure_is_distinct_from_a_nonzero_exit()
  local f = spy { status = "spawn_failed", stdout = "", stderr = "", message = "no such file: frobnicate" }
  local r = shell.run(ctx_of(f, { command = "frobnicate" }))
  assert(r.status == "failed")
  assert(r.ok == false)
  assert(r.code == nil, "a program that never started has no exit code")
  assert(r.reason == "spawn_failed")
  assert(has(r.detail, "frobnicate"))

  local g = spy(exited(127))
  local r2 = shell.run(ctx_of(g, { command = "frobnicate" }))
  assert(r2.ok == true and r2.code == 127, "127 from a shell is a result, not a spawn failure")

  -- with no message from the port there is still a sentence
  local h = spy { status = "spawn_failed", stdout = "", stderr = "" }
  local r3 = shell.run(ctx_of(h, { command = "x" }))
  assert(r3.detail == shell.reasons.spawn_failed)
end

function T.an_unsupported_host_says_so_once()
  local f = spy { status = "unsupported", stdout = "", stderr = "", message = "built with no subprocess support" }
  local r = shell.run(ctx_of(f, { command = "ls" }))
  assert(r.status == "unavailable")
  assert(r.reason == "no_shell")
  assert(r.ok == false)
  assert(has(r.detail, "rephrasing"), "the model is told to stop, not to try another wording")
  assert(has(r.detail, "built with no subprocess support"))
  assert(not has(r.text, "--- stdout"), "nothing ran, so no stream headers")
end

function T.a_signal_kill_is_reported_as_one()
  local f = spy { status = "exited", signal = "SIGKILL", stdout = "half a line", stderr = "", duration_ms = 90 }
  local r = shell.run(ctx_of(f, { command = "big-build" }))
  assert(r.status == "failed")
  assert(r.reason == "killed_by_signal", statuses_of(r))
  assert(r.signal == "SIGKILL")
  assert(r.code == nil)
  assert(r.stdout == "half a line", "output before the kill is kept")
  assert(has(r.text, "SIGKILL"))
  assert(has(r.text, "half a line"))
end

function T.a_port_that_raises_does_not_end_the_turn()
  local raises = { "boom", { why = "a table" }, nil }
  for i = 1, 3 do
    local v = raises[i]
    local f = { calls = {}, exec = function () error(v) end }
    local ok, r = pcall(shell.run, ctx_of(f, { command = "ls" }))
    assert(ok, "a broken port must not take the turn down with it")
    assert(r.status == "failed")
    assert(r.reason == "port_error", statuses_of(r))
    assert(type(r.detail) == "string" and r.detail ~= "")
  end

  local f = { exec = function () error("boom") end }
  local r = shell.run(ctx_of(f, { command = "ls" }))
  assert(has(r.detail, "boom"))
end

function T.a_malformed_outcome_is_a_failure_not_a_crash()
  local cases = {
    { answer = nil,                                        names = "nil" },
    { answer = 42,                                         names = "number" },
    { answer = { status = "weird" },                       names = "weird" },
    { answer = { status = "exited" },                      names = "code" },
    { answer = { status = "exited", code = 0, stdout = 12 }, names = "stdout" },
    { answer = { status = "exited", code = "0" },          names = "code" },
    { answer = { status = "timeout", duration_ms = "fast" }, names = "duration_ms" },
  }
  for i = 1, #cases do
    local f = spy(function () return cases[i].answer end)
    local ok, r = pcall(shell.run, ctx_of(f, { command = "ls" }))
    assert(ok, "case " .. i .. " raised")
    assert(r.status == "failed", "case " .. i .. ": " .. statuses_of(r))
    assert(r.reason == "port_contract", "case " .. i .. ": " .. statuses_of(r))
    assert(has(r.detail, cases[i].names), "case " .. i .. " detail: " .. r.detail)
    assert(r.stdout == "" and r.stderr == "" and r.text ~= "")
  end
end

-- ---------------------------------------------------------------------------
-- 21-25. truncation and overflow

function T.output_is_truncated_to_the_cap()
  local total = 1048576
  local big = string.rep("z", total)
  local f = spy(exited(0, big, ""))
  local r = shell.run(ctx_of(f, { command = "cat big" }), { stdout_cap = 1024 })
  local marker = marker_of(r.dropped.stdout)
  assert(has(r.stdout, marker), "the loss is named inline")
  local retained = #r.stdout - #marker
  assert(retained <= 1024, retained)
  assert(r.dropped.stdout == total - retained)
  assert(r.bytes.stdout == total)
  assert(has(r.text, "of " .. total .. " bytes"), r.text:sub(1, 200))
  assert(r.ok == true, "a big but complete output is not a failure")
end

function T.truncation_keeps_the_head_and_the_tail()
  local lines = {}
  for i = 1, 500 do lines[i] = "line " .. i end
  local s = table.concat(lines, "\n")
  local kept, dropped = shell.truncate(s, 300)
  assert(dropped > 0)
  local marker = marker_of(dropped)
  local at = string.find(kept, marker, 1, true)
  assert(at, "the marker sits between the two pieces")
  local head = string.sub(kept, 1, at - 1)
  local tail = string.sub(kept, at + #marker)
  assert(string.sub(head, 1, 6) == "line 1")
  assert(string.sub(tail, -8) == "line 500", "the error is almost always at the end")
  assert(#head + #tail <= 300)
end

function T.truncation_never_splits_a_codepoint()
  local chars = { "\195\169", "\226\130\172", "\240\157\132\158" }   -- 2, 3 and 4 bytes
  for c = 1, #chars do
    local ch = chars[c]
    for pad = 0, #ch - 1 do
      local s = string.rep("a", pad) .. string.rep(ch, 400)
      local kept, dropped = shell.truncate(s, 256)
      assert(dropped > 0)
      local marker = marker_of(dropped)
      local at = string.find(kept, marker, 1, true)
      assert(at, "no marker for pad " .. pad)
      local head = string.sub(kept, 1, at - 1)
      local tail = string.sub(kept, at + #marker)
      assert(utf8_whole(head), "head split a codepoint, char " .. c .. " pad " .. pad)
      assert(utf8_whole(tail), "tail split a codepoint, char " .. c .. " pad " .. pad)
      assert(#head + #tail <= 256)
      assert(#head + #tail + dropped == #s)
    end
  end
end

function T.truncation_is_exact_at_the_boundary()
  local cap = 256
  local kept, dropped = shell.truncate(string.rep("a", cap), cap)
  assert(dropped == 0 and #kept == cap)
  kept, dropped = shell.truncate(string.rep("a", cap - 1), cap)
  assert(dropped == 0 and #kept == cap - 1)
  kept, dropped = shell.truncate(string.rep("a", cap + 1), cap)
  assert(dropped == 1, dropped)
  assert(#kept - #marker_of(dropped) == cap)

  -- caller bugs raise
  assert(not pcall(shell.truncate, "x", 255))
  assert(not pcall(shell.truncate, 12, 1024))
  assert(not pcall(shell.truncate, "x", 1024.5))
end

function T.overflow_is_reported_when_the_host_capped_first()
  local f = spy { status = "exited", code = 0, stdout = string.rep("q", 100), stderr = "",
                  overflowed = true, duration_ms = 5 }
  local r = shell.run(ctx_of(f, { command = "yes" }))
  assert(r.overflowed == true)
  assert(r.ok == true, "the host capping its buffer is not a failure on its own")
  assert(has(r.text, "total unknown"), r.text)
  assert(not has(r.text, "of 100 bytes"))
end

-- ---------------------------------------------------------------------------
-- 26-30. defaults, options, and what is not touched

function T.the_default_timeout_and_cwd_are_used_when_the_model_names_none()
  local f = spy(exited(0))
  shell.run(ctx_of(f, { command = "ls" }))
  assert(#f.calls == 1)
  local req = f.calls[1]
  assert(req.timeout_ms == 30000)
  assert(req.cwd == resolve(ROOT, "."))
  assert(req.cwd == ROOT)
  assert(req.max_bytes == 4194304)
  assert(req.env == nil and req.stdin == nil)

  -- a declared default cwd is resolved the same way
  local g = spy(exited(0))
  shell.run(ctx_of(g, { command = "ls" }), { cwd = "ui" })
  assert(g.calls[1].cwd == ROOT .. "/ui")

  -- a declared environment and stdin travel to the port, and the port cannot reach back
  -- into the options table through them
  local env = { PATH = "/bin" }
  local h = spy(exited(0))
  shell.run(ctx_of(h, { command = "ls" }), { env = env, stdin = "yes\n", port_max = 4096 })
  assert(h.calls[1].env.PATH == "/bin")
  assert(h.calls[1].env ~= env, "the port is handed a copy, not the declaration's table")
  assert(h.calls[1].stdin == "yes\n")
  assert(h.calls[1].max_bytes == 4096)
end

function T.options_reject_an_unknown_key()
  local ok, e = pcall(shell.options, { timout_ms = 5 })
  assert(not ok)
  assert(has(tostring(e), "timout_ms"), tostring(e))

  assert(not pcall(shell.options, 7))
  assert(not pcall(shell.options, { timeout_ms = "30s" }))
  assert(not pcall(shell.options, { timeout_ms = 0 }))
  assert(not pcall(shell.options, { timeout_ms = 1.5 }))
  assert(not pcall(shell.options, { stdout_cap = 255 }))
  assert(not pcall(shell.options, { timeout_ms = 700000 }))          -- above timeout_max
  assert(not pcall(shell.options, { env = { PATH = 7 } }))
  assert(not pcall(shell.options, { env = { [1] = "x" } }))
  assert(not pcall(shell.tool, { timout_ms = 5 }), "the same check runs at declaration time")

  assert(pcall(shell.options, { timeout_ms = 700000, timeout_max = 900000 }))
end

function T.options_are_idempotent_and_do_not_mutate()
  local given = { timeout_ms = 5000, env = { PATH = "/bin" }, ask = false }
  local before = deep_copy(given)
  local once = shell.options(given)
  local twice = shell.options(once)
  assert(deep_equal(once, twice))
  assert(deep_equal(given, before), "the given table gained a default")
  assert(given.cwd == nil and given.timeout_max == nil)
  assert(once.ask == false, "an explicit false survives the default")
  assert(once.env ~= given.env, "the env is copied, not aliased")
  assert(deep_equal(shell.options(nil), shell.options {}))
end

function T.run_raises_only_on_a_wiring_bug()
  local f = spy(exited(0))
  assert(not pcall(shell.run, "a string"))
  assert(not pcall(shell.run, nil))
  assert(not pcall(shell.run, { root = ROOT, args = {} }))                    -- no exec
  assert(not pcall(shell.run, { exec = f.exec, args = {} }))                  -- no root
  assert(not pcall(shell.run, { exec = f.exec, root = "", args = {} }))       -- empty root
  assert(not pcall(shell.run, { exec = f.exec, root = ROOT }))                -- no args
  assert(not pcall(shell.run, ctx_of(f, { command = "ls" }), { nope = 1 }))   -- bad options

  -- and everything the model can do returns
  local model_wrongs = {
    {}, { command = "" }, { command = 42 }, { command = "ls\0" },
    { command = string.rep("x", 9000) }, { command = "ls", cwd = ".." },
    { command = "ls", cwd = 7 }, { command = "ls", timeout_ms = -1 },
    { command = "ls", timeout_ms = 10 ^ 9 },
  }
  for i = 1, #model_wrongs do
    local g = spy(exited(0))
    local ok, r = pcall(shell.run, ctx_of(g, model_wrongs[i]))
    assert(ok, "case " .. i .. " raised on the model's mistake")
    assert(r.status == "refused", "case " .. i .. ": " .. statuses_of(r))
  end
end

function T.nothing_is_mutated()
  local f = spy(exited(0, "out", "err"))
  local args = { command = "ls -la", cwd = "ui", timeout_ms = 1000 }
  local c = ctx_of(f, args)
  local opts = { stdout_cap = 512, env = { PATH = "/bin" } }
  local before_ctx, before_args, before_opts = deep_copy(c), deep_copy(args), deep_copy(opts)
  shell.run(c, opts)
  assert(deep_equal(c, before_ctx), "the context was written to")
  assert(deep_equal(args, before_args), "the arguments were written to")
  assert(deep_equal(opts, before_opts), "the options table was written to")
end

function T.two_runs_share_nothing()
  local inner_calls = 0
  local outer = {
    exec = function (request)
      -- A body that shells out again, with a different world entirely.
      inner_calls = inner_calls + 1
      local inner_port = spy(exited(3, "inner out", ""))
      local inner = shell.run({
        exec = inner_port.exec, root = "/other", resolve = resolve,
        args = { command = "inner " .. request.command },
      }, { stdout_cap = 256 })
      assert(inner.ok == true and inner.code == 3)
      assert(inner.cwd == "/other")
      assert(inner.stdout == "inner out")
      return exited(0, "outer out", "")
    end,
  }
  local r = shell.run(ctx_of(outer, { command = "ls" }))
  assert(inner_calls == 1)
  assert(r.ok == true and r.code == 0)
  assert(r.cwd == ROOT, "the nested run did not corrupt the outer one")
  assert(r.stdout == "outer out")
  assert(r.command == "ls")
end

-- ---------------------------------------------------------------------------
-- 32-34. what the model reads

function T.a_refusal_renders_as_a_refusal()
  local cases = {
    { args = {},                                    reason = "no_command" },
    { args = { command = "  " },                    reason = "empty_command" },
    { args = { command = "ls\0" },                  reason = "command_has_nul" },
    { args = { command = string.rep("x", 9000) },   reason = "command_too_long" },
    { args = { command = "ls", cwd = 7 },           reason = "bad_cwd" },
    { args = { command = "make deploy", cwd = "../../etc" }, reason = "cwd_escapes_root" },
    { args = { command = "ls", timeout_ms = 0 },    reason = "bad_timeout" },
    { args = { command = "ls", timeout_ms = 10 ^ 7 }, reason = "timeout_too_long" },
  }
  for i = 1, #cases do
    local f = spy(exited(0))
    local r = shell.run(ctx_of(f, cases[i].args))
    assert(r.reason == cases[i].reason, "case " .. i .. ": " .. statuses_of(r))
    assert(has(r.text, "refused: " .. cases[i].reason), r.text)
    assert(has(r.text, r.detail), "the sentence the model acts on is in the text")
    assert(not has(r.text, "--- stdout"), "nothing ran, so no stream headers: " .. r.text)
    assert(not has(r.text, "--- stderr"))
  end

  local f = spy(exited(0))
  local r = shell.run(ctx_of(f, { command = "make deploy", cwd = "../../etc" }))
  assert(has(r.text, "$ make deploy"), r.text)
end

function T.every_reason_code_has_a_sentence()
  for code, sentence in pairs(shell.reasons) do
    assert(type(code) == "string" and code ~= "")
    assert(type(sentence) == "string" and sentence ~= "", code)
    assert(string.sub(sentence, -1) == ".", code .. ": " .. sentence)
  end

  -- Every code the tool can actually produce, produced, and looked up.
  local produced = {}
  local function note(r) if r.reason then produced[r.reason] = true end end

  local paths = {
    { args = {} }, { args = { command = "" } }, { args = { command = "ls\0" } },
    { args = { command = string.rep("x", 9000) } }, { args = { command = "ls", cwd = 7 } },
    { args = { command = "ls", cwd = ".." } }, { args = { command = "ls", timeout_ms = 0 } },
    { args = { command = "ls", timeout_ms = 10 ^ 7 } },
    { args = { command = "ls" }, answer = { status = "timeout", stdout = "", stderr = "" } },
    { args = { command = "ls" }, answer = { status = "spawn_failed", stdout = "", stderr = "" } },
    { args = { command = "ls" }, answer = { status = "unsupported", stdout = "", stderr = "" } },
    { args = { command = "ls" }, answer = { status = "exited", signal = "SIGTERM", stdout = "", stderr = "" } },
    { args = { command = "ls" }, answer = { status = "nonsense" } },
  }
  for i = 1, #paths do
    local f = spy(paths[i].answer or exited(0))
    note(shell.run(ctx_of(f, paths[i].args)))
  end
  local raiser = { exec = function () error("boom") end }
  note(shell.run(ctx_of(raiser, { command = "ls" })))
  local noresolve = spy(exited(0))
  note(shell.run { exec = noresolve.exec, root = ROOT, args = { command = "ls", cwd = "x" } })

  local n = 0
  for code in pairs(produced) do
    assert(shell.reasons[code], "the code " .. code .. " has no sentence")
    n = n + 1
  end
  assert(n == 15, "produced " .. n .. " of the 15 codes")
  for code in pairs(shell.reasons) do
    assert(produced[code], "no test reaches the code " .. code)
  end
end

function T.the_result_shape_is_total()
  local examples = {
    exited      = spy(exited(0, "a", "b")),
    timeout     = spy { status = "timeout", stdout = "", stderr = "" },
    failed      = spy { status = "spawn_failed", stdout = "", stderr = "" },
    unavailable = spy { status = "unsupported", stdout = "", stderr = "" },
  }
  local results = {}
  for _, f in pairs(examples) do
    results[#results + 1] = shell.run(ctx_of(f, { command = "ls" }))
  end
  local refused = spy(exited(0))
  results[#results + 1] = shell.run(ctx_of(refused, { command = "" }))

  local seen = {}
  for i = 1, #results do
    local r = results[i]
    seen[r.status] = true
    assert(type(r.status) == "string")
    assert(type(r.ok) == "boolean")
    assert(r.ok == (r.status == "exited"))
    assert(r.code == nil or type(r.code) == "number")
    assert((r.code ~= nil) == (r.status == "exited"), r.status)
    assert(r.signal == nil or type(r.signal) == "string")
    assert(r.command == nil or type(r.command) == "string")
    assert(r.cwd == nil or type(r.cwd) == "string")
    assert(r.duration_ms == nil or type(r.duration_ms) == "number")
    assert(type(r.stdout) == "string", r.status)
    assert(type(r.stderr) == "string", r.status)
    assert(type(r.dropped) == "table" and type(r.dropped.stdout) == "number"
      and type(r.dropped.stderr) == "number", r.status)
    assert(type(r.bytes) == "table")
    assert(type(r.overflowed) == "boolean", r.status)
    assert((r.reason ~= nil) == (r.ok == false), r.status)
    assert((r.detail ~= nil) == (r.reason ~= nil), r.status)
    assert(type(r.text) == "string" and r.text ~= "", r.status)
  end
  for _, want in ipairs { "exited", "timeout", "failed", "unavailable", "refused" } do
    assert(seen[want], "no example of " .. want)
  end
end

-- ---------------------------------------------------------------------------
-- 35-36. dialect, and the standard port

function T.it_runs_under_both_interpreters()
  local src = source_text()
  assert(src, "could not find src/tools_shell.lua to scan")
  assert(not has(src, "//"), "integer division is outside the dialect")
  assert(not string.find(src, "%f[%w]goto%f[%W]"), "goto is outside the dialect")
  assert(not has(src, "<close>"), "a to-be-closed variable is outside the dialect")
  assert(not has(src, "string.pack"))
  assert(not string.find(src, "~[^=]"), "a bitwise operator is outside the dialect")
  assert(not has(src, "|"), "a bitwise operator is outside the dialect")
  assert(not has(src, "&"), "a bitwise operator is outside the dialect")
  -- and the suite itself is run under both by the runner
  assert(type(_VERSION) == "string")
end

-- The argv-shaped shell port of spec/port.md, driven through the adapter. This is the
-- wiring a host actually has, so it gets a test rather than a paragraph.
function T.the_standard_shell_port_can_drive_this_tool()
  local seen = {}
  local sh = {
    run = function (argv, opts)
      seen[#seen + 1] = { argv = argv, opts = opts }
      return { code = 2, out = "built\n", err = "warning\n", timed_out = false }
    end,
  }
  local r = shell.run { sh = sh, root = ROOT, resolve = resolve,
                        args = { command = "make -j2", cwd = "ui", timeout_ms = 4000 } }
  assert(r.ok == true and r.code == 2, statuses_of(r))
  assert(r.stdout == "built\n" and r.stderr == "warning\n")
  assert(#seen == 1)
  assert(seen[1].argv[1] == "sh" and seen[1].argv[2] == "-c" and seen[1].argv[3] == "make -j2",
    "the decision to invoke a shell is visible at the call site")
  assert(seen[1].opts.cwd == "ui", "the port takes a workspace-relative directory")
  assert(seen[1].opts.timeout == 4, "the port counts seconds")

  local dead = { run = function () return nil, { port = "sh", call = "run", code = "unavailable", message = "no subprocess here" } end }
  local r2 = shell.run { sh = dead, root = ROOT, args = { command = "ls" } }
  assert(r2.status == "unavailable" and r2.reason == "no_shell", statuses_of(r2))

  local missing = { run = function () return nil, { port = "sh", call = "run", code = "not_found", message = "no such program: frob" } end }
  local r3 = shell.run { sh = missing, root = ROOT, args = { command = "frob" } }
  assert(r3.reason == "spawn_failed", statuses_of(r3))
  assert(has(r3.detail, "frob"))

  local slow = { run = function () return nil, { port = "sh", call = "run", code = "timeout", message = "deadline" } end }
  local r4 = shell.run { sh = slow, root = ROOT, args = { command = "sleep 99" } }
  assert(r4.status == "timeout" and r4.reason == "timed_out", statuses_of(r4))

  local partial = { run = function () return { code = 0, out = "half", err = "", timed_out = true } end }
  local r5 = shell.run { sh = partial, root = ROOT, args = { command = "sleep 99" } }
  assert(r5.status == "timeout" and r5.stdout == "half", "a port that kept partial output keeps it")

  local broken = { run = function () return 42 end }
  local r6 = shell.run { sh = broken, root = ROOT, args = { command = "ls" } }
  assert(r6.reason == "port_contract", statuses_of(r6))
end

-- ---------------------------------------------------------------------------
-- 38-41. what the first pass got wrong

-- F10 says bytes that are not UTF-8 travel through byte for byte, and that the only
-- thing truncation refuses to do is cut a character in half. An unbounded walk off the
-- cut point does far more than that: a run of high bytes that is not UTF-8 walks both
-- cuts all the way to zero and the tool keeps nothing at all. Adversarial: the payload
-- is what is asserted, not the absence of a crash.
function T.truncation_keeps_output_that_is_not_utf8()
  local cap = 256
  local cases = {
    string.rep("\191", 300),                                 -- a bare continuation run
    "hello" .. string.rep("\191", 300) .. "world",            -- valid text around one
    string.rep("\128\129\130\131\132", 80),                 -- and a longer one
  }
  for i = 1, #cases do
    local s = cases[i]
    local kept, dropped = shell.truncate(s, cap)
    local retained = #kept - #marker_of(dropped)
    assert(retained <= cap, "case " .. i .. " kept " .. retained .. " of " .. cap)
    assert(retained >= cap - 6, "case " .. i .. " kept only " .. retained .. " of " .. cap)
    assert(retained + dropped == #s, "case " .. i .. " lost bytes: " .. retained .. "+" .. dropped)
    local at = string.find(kept, marker_of(dropped), 1, true)
    assert(at and at > 1, "case " .. i .. " kept no head at all")
    assert(#kept > at + #marker_of(dropped) - 1, "case " .. i .. " kept no tail at all")
  end

  -- and the bound is still wide enough for the widest real character
  local wide = string.rep("\240\157\132\158", 200)
  local kept = shell.truncate(wide, cap)
  local at = string.find(kept, "bytes elided", 1, true)
  assert(at)
  assert(utf8_whole(string.sub(kept, 1, at - 5)))
end

-- The overflow flag is one boolean for both streams. Saying "total unknown" over a
-- stream with nothing in it claims a loss that did not happen, and throws away the
-- empty header that test 6 exists to protect.
function T.an_empty_stream_did_not_overflow()
  local f = spy { status = "exited", code = 0, stdout = string.rep("q", 100), stderr = "",
                  overflowed = true, duration_ms = 5 }
  local r = shell.run(ctx_of(f, { command = "yes" }))
  assert(r.overflowed == true)
  assert(has(r.text, "--- stdout (100 bytes, total unknown"), r.text)
  assert(has(r.text, "--- stderr (empty) ---"), r.text)
  assert(not has(r.text, "--- stderr (0 bytes, total unknown"), r.text)
end

-- A shell port that answers without an exit code has not said the command succeeded.
-- Adversarial: filling the gap with a zero reports a clean success nobody claimed, and
-- it is the tool's own F9 check that the adapter would be defeating.
function T.the_standard_port_cannot_invent_an_exit_code()
  local mute = { run = function () return { out = "x", err = "" } end }
  local r = shell.run { sh = mute, root = ROOT, args = { command = "ls" } }
  assert(r.status == "failed", statuses_of(r))
  assert(r.reason == "port_contract", statuses_of(r))
  assert(r.ok == false, "a port that named no exit code did not report a success")
  assert(has(r.detail, "code"), r.detail)

  -- a zero the port actually sent is still a zero
  local real = { run = function () return { code = 0, out = "x", err = "" } end }
  local r2 = shell.run { sh = real, root = ROOT, args = { command = "ls" } }
  assert(r2.ok == true and r2.code == 0, statuses_of(r2))
end

-- Three different things a path port can do, and only one of them is the model's
-- mistake to read.
function T.a_broken_resolve_is_not_the_models_mistake()
  local f = spy(exited(0))
  local judged = shell.run { exec = f.exec, root = ROOT, resolve = resolve,
                             args = { command = "ls", cwd = ".." } }
  assert(judged.status == "refused" and judged.reason == "cwd_escapes_root", statuses_of(judged))

  for _, answer in ipairs { {}, 7, true } do
    local g = spy(exited(0))
    local ok, r = pcall(shell.run, { exec = g.exec, root = ROOT,
      resolve = function () return answer end, args = { command = "ls", cwd = "ui" } })
    assert(ok, "a broken path port must not raise")
    assert(r.status == "failed", statuses_of(r))
    assert(r.reason == "port_contract", statuses_of(r))
    assert(#g.calls == 0, "a directory that was never resolved never reaches the shell")
  end

  local h = spy(exited(0))
  local ok, r = pcall(shell.run, { exec = h.exec, root = ROOT,
    resolve = function () error("path layer is down") end, args = { command = "ls", cwd = "ui" } })
  assert(ok)
  assert(r.reason == "port_error", statuses_of(r))
  assert(has(r.detail, "path layer is down"))
end

return T
