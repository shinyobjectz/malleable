-- The host wait table (src/wait.lua): one dialect for speech and the console's turn clock.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local wait = require "wait"

local T = {}

function T.kind_names_host_sleep_and_person()
  assert(wait.kind { wait = "host" } == "host")
  assert(wait.kind { wait = "sleep", seconds = 1 } == "sleep")
  assert(wait.kind { wait = "person", question = {} } == "person")
end

function T.kind_reads_gate_as_person()
  assert(wait.kind { wait = "gate", tool = "file" } == "person")
end

function T.kind_keeps_model_and_tool_for_the_console()
  assert(wait.kind { wait = "model", frames = 12 } == "model")
  assert(wait.kind { wait = "tool", frames = 6 } == "tool")
end

function T.kind_refuses_an_unknown_or_empty_yield()
  assert(wait.kind { wait = "first" } == nil)
  assert(wait.kind "host" == nil)
  assert(wait.kind(nil) == nil)
end

function T.frames_prefers_seconds()
  assert(wait.frames({ wait = "sleep", seconds = 1, frames = 99 }, 30) == 30)
  assert(wait.frames({ wait = "sleep", seconds = 0.1 }, 10) == 1)
end

function T.frames_uses_frames_when_there_are_no_seconds()
  assert(wait.frames({ wait = "model", frames = 12 }, 30) == 12)
  assert(wait.frames({ wait = "sleep" }, 30) == 1)
end

function T.ready_waits_on_host_until_poll_is_true()
  local left = 2
  local w = wait.host(function ()
    left = left - 1
    if left <= 0 then return true, { "ok" } end
    return false
  end)
  assert(wait.ready(w) == "waiting")
  local status, value = wait.ready(w)
  assert(status == "ready" and value[1] == "ok")
end

function T.ready_raises_when_the_host_poll_raises()
  local status, err = wait.ready(wait.host(function () error("boom", 0) end))
  assert(status == "raised")
  assert(tostring(err):find("boom", 1, true), tostring(err))
end

function T.ready_refuses_a_host_wait_with_nothing_to_poll()
  local status, err = wait.ready { wait = "host" }
  assert(status == "raised")
  assert(tostring(err):find("nothing to poll", 1, true), tostring(err))
end

function T.ready_waits_on_sleep_until_the_clock()
  local w = wait.sleep(2)
  assert(wait.ready(w, { now = 1, wake = 3 }) == "waiting")
  assert(wait.ready(w, { now = 3, wake = 3 }) == "ready")
  assert(wait.ready(w, {}) == "ready")
end

function T.ready_waits_on_person_until_a_decision()
  local w = wait.person { tool = "file" }
  assert(wait.ready(w, {}) == "waiting")
  local status, value = wait.ready(w, { decision = { allow = true } })
  assert(status == "ready" and value.allow == true)
end

function T.ready_treats_gate_as_person()
  local status, value = wait.ready({ wait = "gate" }, { decision = { allow = false } })
  assert(status == "ready" and value.allow == false)
end

function T.wake_is_now_plus_seconds()
  assert(wait.wake(wait.sleep(1.5), 10) == 11.5)
  assert(wait.wake(wait.sleep(1), nil) == nil)
end

function T.cancel_calls_the_host_cancel()
  local n = 0
  wait.cancel(wait.host(function () return false end, function () n = n + 1 end))
  assert(n == 1)
  wait.cancel { wait = "sleep", seconds = 1 }
end

function T.wait_names_no_vendor()
  local f = assert(io.open(here .. "/../src/wait.lua", "rb"))
  local text = f:read("*a"); f:close()
  local code = text:gsub("%-%-[^\n]*", "")
  for _, bad in ipairs { "io%.", "os%.", "require \"console", "love", "curl", "lanes", "luv" } do
    assert(not code:find(bad), "src/wait.lua mentions " .. bad)
  end
end

function T.host_sleep_and_person_build_the_table()
  local h = wait.host(function () return true end)
  assert(h.wait == "host" and type(h.poll) == "function")
  local s = wait.sleep(0.5)
  assert(s.wait == "sleep" and s.seconds == 0.5)
  local p = wait.person { tool = "file" }
  assert(p.wait == "person" and p.question.tool == "file")
end

return T
