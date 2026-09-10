-- schedule -- the beat. What lets an agent be started by time rather than by a person.
--
-- Before this seam a run began in exactly two ways: someone typed, or another agent
-- delegated. A machine has a beat and an agent did not, so "every evening, summarise
-- what changed" was a sentence the harness could not hold at all.
--
-- Two things were missing and both are here.
--
--   THE DECLARATION. `agent.every "digest" { day_at = "18:00", runs = "...", once_per
--   = "day" }` states the beat next to the tools, in the same file, under rule 2: this
--   module decides what is due and never decides what time it is.
--
--   THE LEDGER. Without a durable record, "never twice for the same day" is not
--   expressible -- `session` is per conversation and dies with it, and an in-process
--   table forgets across a restart, which is exactly when a beat double-fires. The
--   ledger is therefore a PORT, owing
--
--       get(key) -> value | nil          (nil means never; it does not mean failure)
--       put(key, value) -> true | nil, err
--
--   with `value` a table this module writes and only this module reads.
--
-- The calendar is arithmetic here rather than `os.date`, for two reasons that are the
-- same reason: a test must be able to stand at any instant of any year without setting
-- the machine's clock, and a run must mean the same thing on two machines in different
-- zones. A beat carries `tz`, the local offset in whole seconds; with none it is UTC.

local turn = require "turn"

local schedule = {}

local DAY = 86400

local function fail(fmt, ...)
  error("agent: " .. string.format(fmt, ...), 3)
end

-- Civil date from a count of days since 1970-01-01, by the shift-to-March algorithm:
-- moving the year's start to March puts the leap day last, so the month lengths
-- become a straight line and no table of 12 numbers is needed. Correct for any day
-- the era arithmetic can hold, which is far outside any clock this will ever read.
function schedule.civil(days)
  local z = days + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097                                  -- [0, 146096]
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524)
                          - math.floor(doe / 146096)) / 365)    -- [0, 399]
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp + (mp < 10 and 3 or -9)
  return { year = y + (m <= 2 and 1 or 0), month = m, day = d }
end

-- The instant a wall clock in this zone read midnight, for the day `t` falls in.
function schedule.midnight(t, tz)
  local local_t = t + (tz or 0)
  return math.floor(local_t / DAY) * DAY - (tz or 0)
end

-- The clock time as the whole world would read it off a wall: 2026-09-10 18:00.
function schedule.reads(t, tz)
  local local_t = t + (tz or 0)
  local days = math.floor(local_t / DAY)
  local secs = local_t - days * DAY
  local c = schedule.civil(days)
  return string.format("%04d-%02d-%02d %02d:%02d", c.year, c.month, c.day,
                       math.floor(secs / 3600), math.floor((secs % 3600) / 60))
end

-- The dedup key for a grain. Two firings that produce the same key are the same
-- firing, whatever the beat's period says, and the ledger is what remembers.
function schedule.grain_key(beat, t)
  local grain = beat.once_per
  if grain == nil then return nil end
  if grain == "ever" then return "ever" end
  local tz = beat.tz or 0
  local local_t = t + tz
  if grain == "hour" then return "h" .. math.floor(local_t / 3600) end
  if grain == "day" then return "d" .. math.floor(local_t / DAY) end
  if grain == "week" then return "w" .. math.floor((local_t + 4 * DAY) / (7 * DAY)) end
  return nil
end

function schedule.key(a, beat)
  return "beat/" .. (a.name or "agent") .. "/" .. beat.name
end

-- When this beat was owed, at or before `now`: the instant a host should compare
-- against when it asks how late it is. An interval beat is owed one period after it
-- last ran; a wall-clock beat is owed at its time today.
function schedule.owed_at(beat, now, last)
  if beat.every then
    if not last or not last.at then return nil end
    return last.at + beat.every
  end
  return schedule.midnight(now, beat.tz) + beat.hour * 3600 + beat.minute * 60
end

-- Is this beat due at `now`, given what the ledger remembers? Pure: the whole of the
-- decision, with the world already read.
--
--   last = { at = <when it last fired>, grain = <the key it fired under> } or nil
--
-- Three answers, never two: `true`; `false` and the sentence saying why it is HELD; or
-- `false, sentence, "skip"` for a beat so far past its time that its own `grace` says
-- the work has expired. The sentence exists because a beat that silently does not fire
-- is the hardest kind of schedule to debug, and the caller should not have to invent
-- the reason. The third answer exists because an app that was shut through six o'clock
-- is the ordinary case, not the exceptional one (spec/schedule.md).
function schedule.is_due(beat, now, last)
  local grain = schedule.grain_key(beat, now)
  if grain and last and last.grain == grain then
    return false, ("already ran for this %s"):format(beat.once_per)
  end
  if beat.every then
    if not last then return true end
    local waited = now - (last.at or 0)
    if waited < beat.every then
      return false, ("%d of %d seconds since the last run"):format(math.floor(waited), beat.every)
    end
    return true
  end
  -- A wall-clock beat. Due once the clock has passed the stated time today, and not
  -- again until the grain rolls over -- so a host whose beat runs every minute fires
  -- it once at 18:00 and not sixty times before 19:00.
  local at = schedule.midnight(now, beat.tz) + beat.hour * 3600 + beat.minute * 60
  if now < at then
    return false, ("not yet %s"):format(beat.day_at)
  end
  if last and last.at and last.at >= at then
    return false, ("already ran at %s"):format(schedule.reads(last.at, beat.tz))
  end
  -- Without `once_per` and without a record, a wall-clock beat fires on the first tick
  -- after its time and then holds until tomorrow, which is the reading of the words.
  if not last and not beat.once_per then return true end
  return true
end

-- The same decision with `grace` applied. This is the one a host calls; `is_due` stays
-- as it was so a caller that does not care about lateness reads a shorter function.
function schedule.verdict(beat, now, last)
  local yes, why = schedule.is_due(beat, now, last)
  if not yes then return false, why end
  if beat.grace == nil then return true end
  local owed = schedule.owed_at(beat, now, last)
  if owed == nil then return true end
  local late = now - owed
  if late > beat.grace then
    return false, ("%d seconds late, and it allows %d"):format(math.floor(late), beat.grace), "skip"
  end
  return true
end

local function ledger_of(p)
  local l = p and p.ledger
  if type(l) == "table" and type(l.get) == "function" and type(l.put) == "function" then return l end
  return nil
end

-- What is due right now, in declaration order, without running any of it. The whole
-- read of the world happens here: the clock once, the ledger once per beat.
--
-- Returns two lists: the due beats, and { beat, why } for every one that is not, so a
-- host can print a whole tick and a test can assert on the reasons.
function schedule.due(a, p, opts)
  opts = opts or {}
  local now = opts.now
  if now == nil then
    if type(p) ~= "table" or type(p.clock) ~= "table" or type(p.clock.now) ~= "function" then
      fail("schedule.due needs a port with a clock, or opts.now")
    end
    now = p.clock.now()
  end
  local l = ledger_of(p)
  local due, held = {}, {}
  for i = 1, #a.beat_order do
    local beat = a.beats[a.beat_order[i]]
    local last = l and l.get(schedule.key(a, beat)) or nil
    if type(last) ~= "table" then last = nil end
    local yes, why, verdict = schedule.verdict(beat, now, last)
    if yes then due[#due + 1] = beat
    else held[#held + 1] = { beat = beat, why = why, skip = verdict == "skip" } end
  end
  return due, held, now
end

-- Run one tick: everything due, in order, each recorded before the next begins.
--
-- The ledger is written BEFORE the run, not after. A run that crashes and a run that
-- never happened are indistinguishable to a beat, and the failure that costs a person
-- something is the one where a nightly digest goes out twelve times because each
-- attempt died before it could say it had started. A host that would rather retry
-- passes `record = "after"` and states that it prefers the other risk.
--
-- `runs` as a string is a prompt and starts a run. `runs` as a function is called with
-- the port and the beat, and whatever it answers is the result. Nothing here decides
-- which of those a schedule should be: a digest is a prompt, a vacuum is a function.
function schedule.tick(a, p, opts)
  opts = opts or {}
  local due, held, now = schedule.due(a, p, opts)
  local l = ledger_of(p)
  local after = opts.record == "after"
  -- A skipped beat is written down under the grain it skipped. Without this the beat
  -- comes round again the moment the clock is inside `grace` of the NEXT period, and a
  -- beat that expired at nine fires at six the following morning as though it had been
  -- waiting -- which is the behaviour `grace` was added to prevent.
  for i = 1, #held do
    if held[i].skip and l then
      local beat = held[i].beat
      local grain = schedule.grain_key(beat, now)
      if grain then l.put(schedule.key(a, beat), { at = now, grain = grain, skipped = held[i].why }) end
    end
  end

  local ran = {}
  for i = 1, #due do
    local beat = due[i]
    local mark = { at = now, grain = schedule.grain_key(beat, now) }
    if l and not after then l.put(schedule.key(a, beat), mark) end
    local row = { beat = beat.name, at = now, reads = schedule.reads(now, beat.tz) }
    if type(beat.runs) == "function" then
      local ok, v = pcall(beat.runs, p, beat)
      row.ok, row.result = ok, v
      if not ok then row.error = tostring(v) end
    else
      local runner = type(opts.run) == "function" and opts.run or turn.run
      local ok, v = pcall(runner, a, beat.runs, p, opts.run_opts)
      row.ok, row.result = ok, v
      if not ok then row.error = tostring(v) end
    end
    if l and after and row.ok then l.put(schedule.key(a, beat), mark) end
    ran[#ran + 1] = row
  end
  return ran, held, now
end

-- The line a host prints for a tick it did not run: what would have fired, and when
-- the rest will. Never raises.
function schedule.plan(a, p, opts)
  local due, held, now = schedule.due(a, p, opts)
  local lines = { "at " .. schedule.reads(now, 0) .. " UTC" }
  for i = 1, #due do
    lines[#lines + 1] = "  due   " .. due[i].name .. " -- " ..
      (due[i].about or (type(due[i].runs) == "string" and due[i].runs) or "a function")
  end
  for i = 1, #held do
    lines[#lines + 1] = "  " .. (held[i].skip and "skip " or "held ") .. " " .. held[i].beat.name .. " -- " .. held[i].why
  end
  return table.concat(lines, "\n"), due, held
end

return schedule
