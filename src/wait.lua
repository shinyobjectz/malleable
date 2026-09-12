-- wait — the table a port yields when it must not block (spec/speech.md, "Waits").
--
--     coroutine.yield(wait.host(poll, cancel))
--     coroutine.yield(wait.sleep(seconds))
--     coroutine.yield(wait.person(question))
--
-- Speech and the console's turn clock both read this file, so the dialect cannot drift.
-- `gate` is `person` (a person at the console). `model` and `tool` are the console's
-- simulated latency, counted in frames. Sleep prefers `seconds`; a frame clock converts.

local wait = {}

wait.HOST   = "host"
wait.SLEEP  = "sleep"
wait.PERSON = "person"
wait.MODEL  = "model"
wait.TOOL   = "tool"

local KINDS = {
  host = true, sleep = true, person = true, gate = true, model = true, tool = true,
}

--- The kind of wait, or nil. `gate` is `person`.
function wait.kind(got)
  if type(got) ~= "table" then return nil end
  local k = got.wait
  if k == "gate" then return wait.PERSON end
  if KINDS[k] then return k end
  return nil
end

--- How many frames a wait lasts on a frame clock. Seconds win when both are present.
function wait.frames(got, fps)
  fps = tonumber(fps) or 30
  if type(got) ~= "table" then return 1 end
  if got.seconds ~= nil then
    return math.max(1, math.floor((tonumber(got.seconds) or 0) * fps + 0.5))
  end
  return math.max(1, tonumber(got.frames) or 1)
end

--- When a sleep started at `now` should wake, or nil when there is no clock.
function wait.wake(got, now)
  if type(now) ~= "number" then return nil end
  local secs = 0
  if type(got) == "table" then
    if got.seconds ~= nil then
      secs = tonumber(got.seconds) or 0
    elseif got.frames ~= nil then
      secs = (tonumber(got.frames) or 0) / 30
    end
  end
  return now + secs
end

--- Is this wait over? Answers "ready" and a value, "waiting", or "raised" and a sentence.
--- ctx: { now, wake, decision } — sleep reads the clock, person reads the decision.
function wait.ready(got, ctx)
  ctx = ctx or {}
  local kind = wait.kind(got)
  if kind == wait.HOST then
    if type(got.poll) ~= "function" then
      return "raised", "the host yielded a wait with nothing to poll"
    end
    local ok, done, v = pcall(got.poll)
    if not ok then return "raised", "its wait raised: " .. tostring(done) end
    if not done then return "waiting" end
    return "ready", v
  end
  if kind == wait.SLEEP then
    if ctx.now and ctx.wake and ctx.now < ctx.wake then return "waiting" end
    return "ready"
  end
  if kind == wait.PERSON then
    if ctx.decision == nil then return "waiting" end
    return "ready", ctx.decision
  end
  return "ready"
end

--- Stop a host wait. `cancel` is called under pcall, the way speech abandons a run.
function wait.cancel(got)
  if type(got) == "table" and type(got.cancel) == "function" then pcall(got.cancel) end
end

function wait.host(poll, cancel)
  return { wait = wait.HOST, poll = poll, cancel = cancel }
end

function wait.sleep(seconds)
  return { wait = wait.SLEEP, seconds = seconds }
end

function wait.person(question)
  return { wait = wait.PERSON, question = question }
end

return wait
