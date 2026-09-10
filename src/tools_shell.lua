-- tools_shell — the shell tool.
--
-- One command line, run in the workspace, reported exactly: standard output, standard
-- error, the exit code and how long it took. The whole world arrives on the context
-- table the harness hands a tool body, so every path in this file is reachable in a
-- test with no subprocess, no disk and no clock.
--
-- The line the file is organized around: declaration-time wrongness raises, and
-- model-supplied wrongness never does. A model naming a directory outside the
-- workspace reads a refusal and tries again; a harness wired with no shell port is a
-- bug in the harness and stops there.
--
-- Nothing here holds state. The tables below are constants and are never written to.

local shell = {}

local COMMAND_MAX = 8192     -- bytes of command line this tool will pass on
local CAP_MIN     = 256      -- the smallest retained-output cap that means anything
local CONT_MAX    = 3        -- the longest run of continuation bytes a character has

-- Every reason code, with the sentence a model reads. Closed set: a code that is not a
-- key here is a code with no English, and the tests fail on it.
shell.reasons = {
  no_command       = "This tool needs `command`, a string.",
  empty_command    = "The command was empty.",
  command_too_long = "The command was longer than this tool will pass to a shell.",
  command_has_nul  = "The command contained a zero byte, which cannot be passed to a shell.",
  bad_cwd          = "`cwd` is a workspace-relative path, given as a string.",
  cwd_escapes_root = "That directory resolves outside the workspace root.",
  cwd_unsupported  = "This harness cannot change directory; omit `cwd`.",
  bad_timeout      = "`timeout_ms` is a whole number of milliseconds, greater than zero.",
  timeout_too_long = "The timeout asked for is longer than this tool allows.",
  timed_out        = "The command was still running when its time ran out, and was killed.",
  spawn_failed     = "The command could not be started.",
  no_shell         = "This harness cannot run shell commands, so rephrasing will not help.",
  killed_by_signal = "The command was killed by a signal.",
  port_error       = "The shell port raised instead of returning an outcome.",
  port_contract    = "The shell port answered with something this tool cannot read.",
}

local function fail(fmt, ...)
  error(string.format(fmt, ...), 3)
end

-- Numbers in sentences. A whole float and a whole integer must read the same, or two
-- harnesses that agree on the timeout appear to disagree in the text a model reads.
local function num(v)
  if type(v) ~= "number" then return tostring(v) end
  if v ~= v then return "nan" end
  if v == math.huge then return "inf" end
  if v == -math.huge then return "-inf" end
  if v == math.floor(v) and v < 1e15 and v > -1e15 then return string.format("%.0f", v) end
  return tostring(v)
end

local function q(s)
  return string.format("%q", tostring(s))
end

-- ---------------------------------------------------------------------------
-- truncate

local function is_continuation(b)
  -- The dialect note: no bitwise operators, so the UTF-8 continuation test is a range.
  return b ~= nil and b >= 128 and b < 192
end

-- Middle-out. The head names what ran, the tail carries the error, and the middle is
-- what a runaway loop fills.
function shell.truncate(s, cap)
  if type(s) ~= "string" then
    error("shell.truncate takes a string, got " .. type(s), 2)
  end
  if type(cap) ~= "number" or cap ~= math.floor(cap) or cap < CAP_MIN then
    error("shell.truncate takes a whole cap of at least " .. CAP_MIN .. " bytes, got " .. num(cap), 2)
  end
  if #s <= cap then return s, 0 end

  local head = math.floor(cap * 0.4)
  local tail = cap - head
  -- Move both cuts inward off a codepoint boundary, so neither retained piece begins
  -- or ends inside a character. Bounded at three bytes, which is the longest run of
  -- continuation bytes a valid character carries: a longer run is not a character at
  -- all, so there is nothing there to protect. Unbounded, a stream of high bytes that
  -- is not UTF-8 walks both cuts to zero and the tool keeps none of the output it was
  -- asked to keep, which is the exact opposite of F10.
  local moved = 0
  while head > 0 and moved < CONT_MAX and is_continuation(string.byte(s, head + 1)) do
    head = head - 1
    moved = moved + 1
  end
  moved = 0
  while tail > 0 and moved < CONT_MAX and is_continuation(string.byte(s, #s - tail + 1)) do
    tail = tail - 1
    moved = moved + 1
  end

  local dropped = #s - head - tail
  local kept = string.sub(s, 1, head)
    .. "\n... " .. num(dropped) .. " bytes elided ...\n"
    .. string.sub(s, #s - tail + 1)
  return kept, dropped
end

-- ---------------------------------------------------------------------------
-- options

-- `acts` is a function (command line) -> { acts = {...}, unplaced = n }: what this tool's
-- OWN input did, in terms, so the trace can say it without the command line itself ever
-- leaving this file. It is handed IN rather than required, because this file reaches into
-- no sibling and that is asserted; `agent.shell` wires `src/command.lua` in, and a host
-- calling `shell.tool` directly may wire a reader of its own -- the bounded escape hatch
-- `spec/command.md` allows, where a host may answer more precisely and never differently.
local OPTION_TYPE = {
  about = "string", ask = "boolean", cwd = "string",
  timeout_ms = "number", timeout_max = "number",
  stdout_cap = "number", stderr_cap = "number", port_max = "number",
  env = "table", stdin = "string", acts = "function",
}

local OPTION_LIST = "about, ask, cwd, timeout_ms, timeout_max, stdout_cap, stderr_cap, port_max, env, stdin, acts"

-- Ordered, so the same wrong table always fails on the same key.
local NUMBERS = {
  { "timeout_ms",  1,       "milliseconds" },
  { "timeout_max", 1,       "milliseconds" },
  { "stdout_cap",  CAP_MIN, "bytes" },
  { "stderr_cap",  CAP_MIN, "bytes" },
  { "port_max",    CAP_MIN, "bytes" },
}

local DEFAULT_ABOUT =
  "Run one command line in the workspace and report its output, exit code and duration."

function shell.options(t)
  if t ~= nil and type(t) ~= "table" then
    fail("shell.options takes a table or nothing, got %s", type(t))
  end

  local o = {
    about       = DEFAULT_ABOUT,
    ask         = true,          -- the shell tool asks. Rule 4 decides what that means.
    cwd         = ".",
    timeout_ms  = 30000,
    timeout_max = 600000,
    stdout_cap  = 32768,
    stderr_cap  = 8192,
    port_max    = 4194304,
    env         = nil,
    stdin       = nil,
  }

  if t ~= nil then
    for k, v in pairs(t) do
      local want = OPTION_TYPE[k]
      if want == nil then
        fail("shell.options: %s is not one of this tool's options (%s)", q(k), OPTION_LIST)
      end
      if type(v) ~= want then
        fail("shell.options: %s is a %s, got %s", k, want, type(v))
      end
      o[k] = v
    end
  end

  if o.about == "" then
    fail("shell.options: about is the sentence the model reads, and cannot be empty")
  end
  if o.cwd == "" then
    fail("shell.options: cwd is a workspace-relative path; %s means the root", q("."))
  end

  for i = 1, #NUMBERS do
    local k, floor, unit = NUMBERS[i][1], NUMBERS[i][2], NUMBERS[i][3]
    local v = o[k]
    if v ~= v or v == math.huge or v ~= math.floor(v) or v < floor then
      fail("shell.options: %s is a whole number of %s, at least %s, got %s", k, unit, num(floor), num(v))
    end
  end

  if o.timeout_ms > o.timeout_max then
    fail("shell.options: timeout_ms (%s) is above timeout_max (%s)", num(o.timeout_ms), num(o.timeout_max))
  end

  if o.env ~= nil then
    local copy = {}
    for k, v in pairs(o.env) do
      if type(k) ~= "string" or k == "" then
        fail("shell.options: an env name is a non-empty string, got %s", type(k))
      end
      if type(v) ~= "string" then
        fail("shell.options: env %s is a string, got %s", q(k), type(v))
      end
      copy[k] = v
    end
    o.env = copy
  end

  return o
end

-- ---------------------------------------------------------------------------
-- render

local function block(lines, label, s, dropped, total, overflowed)
  s = (type(s) == "string") and s or ""
  dropped = (type(dropped) == "number" and dropped > 0) and dropped or 0
  local header
  if overflowed and #s > 0 then
    -- The host stopped buffering, so the true total is not knowable from here and this
    -- tool does not invent one. A stream with no bytes in it did not overflow, whatever
    -- the other stream did, and saying its total is unknown when it is plainly zero is
    -- a worse answer than the empty header.
    header = string.format("--- %s (%s bytes, total unknown: the host stopped buffering) ---",
      label, num(#s))
  elseif dropped > 0 then
    if type(total) == "number" and total > dropped then
      header = string.format("--- %s (%s of %s bytes, %s elided) ---",
        label, num(total - dropped), num(total), num(dropped))
    else
      header = string.format("--- %s (%s bytes shown, %s elided) ---", label, num(#s), num(dropped))
    end
  elseif #s == 0 then
    header = string.format("--- %s (empty) ---", label)
  else
    header = string.format("--- %s (%s bytes) ---", label, num(#s))
  end
  lines[#lines + 1] = header
  if #s > 0 then lines[#lines + 1] = s end
end

-- Pure, and tolerant of a hand-built result: a host may re-render one it stored.
function shell.render(result)
  if type(result) ~= "table" then
    error("shell.render takes a result table, got " .. type(result), 2)
  end

  local lines = {}
  local status = result.status
  local reason = result.reason

  if type(result.command) == "string" then
    lines[#lines + 1] = "$ " .. result.command
  end

  local where = ""
  if type(result.cwd) == "string" and result.cwd ~= "" then where = " in " .. result.cwd end
  local took = ""
  if type(result.duration_ms) == "number" then took = " after " .. num(result.duration_ms) .. "ms" end

  if status == "exited" then
    lines[#lines + 1] = "exit " .. num(result.code) .. took .. where
  elseif status == "timeout" then
    lines[#lines + 1] = "timed out" .. took .. where
  else
    lines[#lines + 1] = tostring(status or "failed") .. ": " .. tostring(reason or "unknown")
  end

  if type(result.detail) == "string" and result.detail ~= "" then
    lines[#lines + 1] = result.detail
  end

  local out = (type(result.stdout) == "string") and result.stdout or ""
  local err = (type(result.stderr) == "string") and result.stderr or ""
  local dropped = (type(result.dropped) == "table") and result.dropped or {}
  local bytes = (type(result.bytes) == "table") and result.bytes or {}

  -- Stream blocks are shown when something ran. A refusal shows none, because an empty
  -- stdout header would say a command ran that never did.
  local ran = status == "exited" or status == "timeout" or reason == "killed_by_signal"
  local show = status ~= "refused" and status ~= "unavailable"
    and (ran or #out > 0 or #err > 0)

  if show then
    block(lines, "stdout", out, dropped.stdout, bytes.stdout, result.overflowed)
    block(lines, "stderr", err, dropped.stderr, bytes.stderr, result.overflowed)
  end

  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- the outcome contract

local STATUSES = { exited = true, timeout = true, spawn_failed = true, unsupported = true }

local OUTCOME_FIELDS = {
  { "stdout", "string" }, { "stderr", "string" }, { "signal", "string" },
  { "message", "string" }, { "duration_ms", "number" }, { "overflowed", "boolean" },
  { "code", "number" },
}

-- Returns a sentence naming what is wrong, or nil when the outcome can be read.
local function contract_fault(v)
  if type(v) ~= "table" then
    return "The shell port answered with a " .. type(v) .. " where an outcome table belongs."
  end
  if type(v.status) ~= "string" or not STATUSES[v.status] then
    return "The shell port answered with a status this tool does not know: " .. q(v.status) .. "."
  end
  for i = 1, #OUTCOME_FIELDS do
    local k, want = OUTCOME_FIELDS[i][1], OUTCOME_FIELDS[i][2]
    if v[k] ~= nil and type(v[k]) ~= want then
      return "The shell port's `" .. k .. "` is a " .. type(v[k]) .. " where a " .. want .. " belongs."
    end
  end
  -- An outcome that claims a clean exit and cannot say with what is worse than an
  -- honest failure. A kill names a signal instead, and that is a different story.
  if v.status == "exited" and v.code == nil
    and not (type(v.signal) == "string" and v.signal ~= "") then
    return "The shell port said the command exited but did not say with what code."
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- run

-- Fill every field the contract names, derive `ok`, and render. One door out of `run`,
-- so no path can return a result missing a field.
local function complete(r)
  r.ok = r.status == "exited"
  r.stdout = (type(r.stdout) == "string") and r.stdout or ""
  r.stderr = (type(r.stderr) == "string") and r.stderr or ""
  r.dropped = r.dropped or { stdout = 0, stderr = 0 }
  r.bytes = r.bytes or { stdout = #r.stdout, stderr = #r.stderr }
  r.overflowed = r.overflowed and true or false
  r.text = shell.render(r)
  return r
end

-- The argv-shaped shell port of spec/port.md turned into the `exec` this tool needs, so
-- a host that wired the standard port needs no glue of its own. Two things that port
-- cannot carry are dropped here, and said out loud rather than faked: an environment
-- overlay and a byte ceiling. See spec/tools_shell.md, section 2.
function shell.exec_from_port(sh, root)
  if type(sh) ~= "table" or type(sh.run) ~= "function" then
    error("shell.exec_from_port takes the shell port, a table with a run function", 2)
  end
  if type(root) ~= "string" or root == "" then
    error("shell.exec_from_port takes the workspace root as a non-empty string", 2)
  end

  local base = root
  if #base > 1 and string.sub(base, -1) == "/" then base = string.sub(base, 1, #base - 1) end

  return function (request)
    local rel = ""
    local cwd = request.cwd
    if type(cwd) == "string" and cwd ~= "" and cwd ~= base then
      if string.sub(cwd, 1, #base + 1) == base .. "/" then
        rel = string.sub(cwd, #base + 2)
      else
        rel = cwd
      end
    end

    local opts = { timeout = request.timeout_ms / 1000 }
    if rel ~= "" then opts.cwd = rel end
    if request.stdin ~= nil then opts.stdin = request.stdin end

    local res, e = sh.run({ "sh", "-c", request.command }, opts)
    if res == nil then
      local code = (type(e) == "table") and e.code or nil
      local message = (type(e) == "table") and e.message or nil
      if code == "timeout" then
        return { status = "timeout", stdout = "", stderr = "", message = message }
      elseif code == "unavailable" then
        return { status = "unsupported", stdout = "", stderr = "", message = message }
      end
      return { status = "spawn_failed", stdout = "", stderr = "", message = message }
    end
    -- A malformed answer travels on unchanged, so the tool names it rather than this
    -- adapter guessing what the port meant.
    if type(res) ~= "table" then return res end
    if res.timed_out then
      return { status = "timeout", stdout = res.out or "", stderr = res.err or "" }
    end
    -- `code` travels as it came. A missing one is not filled in with zero: that would
    -- report a clean success the port never claimed, and the tool's own F9 check is
    -- there to name it instead.
    return { status = "exited", code = res.code, stdout = res.out or "", stderr = res.err or "" }
  end
end

function shell.run(ctx, opts)
  if type(ctx) ~= "table" then
    error("shell.run takes the tool context table, got " .. type(ctx), 2)
  end
  if type(ctx.root) ~= "string" or ctx.root == "" then
    error("shell.run needs ctx.root, the absolute path of the workspace root", 2)
  end
  if type(ctx.args) ~= "table" then
    error("shell.run needs ctx.args, the table of arguments the model sent", 2)
  end

  local exec = ctx.exec
  if type(exec) ~= "function" then
    if type(ctx.sh) == "table" and type(ctx.sh.run) == "function" then
      exec = shell.exec_from_port(ctx.sh, ctx.root)
    else
      error("shell.run needs ctx.exec, a function, or a shell port at ctx.sh", 2)
    end
  end

  local o = shell.options(opts)

  -- ----- what the model sent. None of this reaches the port.

  local command = ctx.args.command
  if type(command) ~= "string" then
    return complete {
      status = "refused", reason = "no_command", detail = shell.reasons.no_command,
    }
  end
  if not string.find(command, "%S") then
    return complete {
      status = "refused", command = command,
      reason = "empty_command", detail = shell.reasons.empty_command,
    }
  end
  if #command > COMMAND_MAX then
    return complete {
      status = "refused", command = command, reason = "command_too_long",
      detail = string.format("The command was %s bytes; the limit is %s.",
        num(#command), num(COMMAND_MAX)),
    }
  end
  if string.find(command, "\0", 1, true) then
    return complete {
      status = "refused", command = command,
      reason = "command_has_nul", detail = shell.reasons.command_has_nul,
    }
  end

  local asked_cwd = ctx.args.cwd
  if asked_cwd ~= nil and type(asked_cwd) ~= "string" then
    return complete {
      status = "refused", command = command,
      reason = "bad_cwd", detail = shell.reasons.bad_cwd,
    }
  end

  local rel = asked_cwd
  if rel == nil then rel = o.cwd end

  local cwd
  if type(ctx.resolve) == "function" then
    local safe, abs, why = pcall(ctx.resolve, ctx.root, rel)
    if not safe then
      return complete {
        status = "failed", command = command, reason = "port_error",
        detail = "The path port raised instead of returning: " .. tostring(abs) .. ".",
      }
    end
    if abs == nil or abs == false then
      -- Whether a path escapes is the path layer's judgement, not this tool's. A
      -- lexical re-check here would be the prefix bug, added on purpose.
      local detail = string.format("%s resolves outside the workspace root.", q(rel))
      if type(why) == "string" and why ~= "" then detail = detail .. " " .. why end
      return complete {
        status = "refused", command = command, reason = "cwd_escapes_root", detail = detail,
      }
    end
    if type(abs) ~= "string" or abs == "" then
      -- Not a judgement about the path, so not the model's mistake to read. A resolved
      -- path is an absolute, non-empty string or it is nothing.
      return complete {
        status = "failed", command = command, reason = "port_contract",
        detail = "The path port answered with a " .. type(abs)
          .. " where a resolved path belongs.",
      }
    end
    cwd = abs
  elseif asked_cwd ~= nil then
    return complete {
      status = "refused", command = command,
      reason = "cwd_unsupported", detail = shell.reasons.cwd_unsupported,
    }
  elseif rel ~= "." then
    return complete {
      status = "refused", command = command, reason = "cwd_unsupported",
      detail = "This harness cannot change directory, and this tool is declared to run in "
        .. q(rel) .. ".",
    }
  else
    cwd = ctx.root
  end

  local timeout = ctx.args.timeout_ms
  if timeout == nil then
    timeout = o.timeout_ms
  else
    if type(timeout) ~= "number" or timeout ~= timeout or timeout == math.huge
      or timeout ~= math.floor(timeout) or timeout <= 0 then
      return complete {
        status = "refused", command = command, cwd = cwd,
        reason = "bad_timeout", detail = shell.reasons.bad_timeout,
      }
    end
    if timeout > o.timeout_max then
      -- Never clamped. A shortened timeout is a lie the model cannot see.
      return complete {
        status = "refused", command = command, cwd = cwd, reason = "timeout_too_long",
        detail = string.format("Asked for %s ms; the limit is %s.", num(timeout), num(o.timeout_max)),
      }
    end
  end

  -- ----- the world

  local request = {
    command    = command,      -- verbatim. Never re-quoted, never edited.
    cwd        = cwd,
    timeout_ms = timeout,
    max_bytes  = o.port_max,
    env        = o.env,
    stdin      = o.stdin,
  }

  local safe, outcome = pcall(exec, request)
  if not safe then
    return complete {
      status = "failed", command = command, cwd = cwd, reason = "port_error",
      detail = "The shell port raised instead of returning: " .. tostring(outcome) .. ".",
    }
  end

  local fault = contract_fault(outcome)
  if fault then
    return complete {
      status = "failed", command = command, cwd = cwd,
      reason = "port_contract", detail = fault,
    }
  end

  local raw_out = outcome.stdout or ""
  local raw_err = outcome.stderr or ""
  local kept_out, dropped_out = shell.truncate(raw_out, o.stdout_cap)
  local kept_err, dropped_err = shell.truncate(raw_err, o.stderr_cap)

  local r = {
    command     = command,
    cwd         = cwd,
    duration_ms = outcome.duration_ms,
    signal      = outcome.signal,
    stdout      = kept_out,
    stderr      = kept_err,
    dropped     = { stdout = dropped_out, stderr = dropped_err },
    bytes       = { stdout = #raw_out, stderr = #raw_err },
    overflowed  = outcome.overflowed and true or false,
  }

  if outcome.status == "exited" then
    if outcome.code == nil then
      -- A kill, named as one. contract_fault has already refused the codeless,
      -- signalless case, so there is a signal here.
      r.status = "failed"
      r.reason = "killed_by_signal"
      r.detail = "The command was killed by " .. outcome.signal .. "."
    else
      r.status = "exited"
      r.code = outcome.code
    end
  elseif outcome.status == "timeout" then
    r.status = "timeout"
    r.reason = "timed_out"
    r.detail = string.format("The command was still running after %s ms and was killed.", num(timeout))
  elseif outcome.status == "spawn_failed" then
    r.status = "failed"
    r.reason = "spawn_failed"
    if type(outcome.message) == "string" and outcome.message ~= "" then
      r.detail = outcome.message
    else
      r.detail = shell.reasons.spawn_failed
    end
  else
    r.status = "unavailable"
    r.reason = "no_shell"
    r.detail = shell.reasons.no_shell
    if type(outcome.message) == "string" and outcome.message ~= "" then
      r.detail = r.detail .. " The host said: " .. outcome.message
    end
  end

  return complete(r)
end

-- ---------------------------------------------------------------------------
-- the declaration

-- The shape spec.lua's argument constructors build. Written out rather than borrowed,
-- because this file names no sibling module; the test proves the two agree by handing
-- this declaration to spec.add_tool.
local function param(kind, needed, description)
  return { __param = true, kind = kind, required = needed, description = description }
end

-- Rule 2: this builds a table and runs nothing.
function shell.tool(t)
  local o = shell.options(t)
  return {
    about = o.about,
    ask   = o.ask,
    args  = {
      command    = param("string", true,  "the command line to run"),
      cwd        = param("string", false, "workspace-relative directory to run it in"),
      timeout_ms = param("number", false, "how long to allow, in milliseconds"),
    },
    -- The model reads the rendered block; a host that wants the structure takes the
    -- second value.
    run = function (c)
      -- Read BEFORE the command runs, so a command that hangs or is killed still says
      -- what it was going to do. The line goes no further than this call: what is left
      -- for the trace is terms and a count, and `c.acted` is a plain list the loop reads.
      local said = type(c.args) == "table" and c.args.command or nil
      if type(o.acts) == "function" and type(said) == "string" and said ~= ""
         and type(c.acted) == "table" then
        local ok, read = pcall(o.acts, said)
        if ok and type(read) == "table" and type(read.acts) == "table" then
          c.acted[#c.acted + 1] = { acts = read.acts, unplaced = read.unplaced }
        end
      end
      local r = shell.run(c, o)
      return r.text, r
    end,
  }
end

return shell
