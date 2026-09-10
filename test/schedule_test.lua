-- schedule: the beat, and the ledger that keeps it from firing twice.
--
-- Every test stands at a stated instant. Nothing here reads a real clock, which is the
-- point of the arithmetic calendar: a test can stand at any second of any year.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local schedule = require "schedule"
local spec     = require "spec"
local double   = require "double"

local T = {}

local DAY = 86400
local PDT = -25200                        -- seven hours behind UTC

local function raised(fn, ...)
  local ok, message = pcall(fn, ...)
  return (not ok), tostring(message)
end

local function keeper()
  local a = spec.new()
  a.name, a.model = "keeper", "m"
  return a
end

function T.the_calendar_is_arithmetic_and_agrees_with_the_one_on_the_wall()
  assert(schedule.reads(0, 0) == "1970-01-01 00:00")
  -- A leap day, the century that is not a leap year, and the one that is.
  assert(schedule.reads(951782400, 0) == "2000-02-29 00:00", schedule.reads(951782400, 0))
  local c = schedule.civil(math.floor(4107542400 / DAY))
  assert(c.year == 2100 and c.month == 3 and c.day == 1, c.year .. "-" .. c.month .. "-" .. c.day)
  -- The offset moves the wall clock and not the instant.
  local t = 1757552400                                   -- 2025-09-11 01:00 UTC
  assert(schedule.reads(t, 0) == "2025-09-11 01:00")
  assert(schedule.reads(t, PDT) == "2025-09-10 18:00")
  -- Before the epoch, where floor and truncate disagree and a naive division is wrong.
  assert(schedule.reads(-1, 0) == "1969-12-31 23:59", schedule.reads(-1, 0))
end

function T.a_beat_states_one_period_and_something_to_run()
  local a = keeper()
  local no, why = raised(spec.add_beat, a, "b", { runs = "x" })
  assert(no and why:match("needs `every"), why)
  no, why = raised(spec.add_beat, a, "b", { every = 60, day_at = "18:00", runs = "x" })
  assert(no and why:match("one period"), why)
  no, why = raised(spec.add_beat, a, "b", { every = 1.5, runs = "x" })
  assert(no and why:match("whole number"), why)
  no, why = raised(spec.add_beat, a, "b", { day_at = "6pm", runs = "x" })
  assert(no and why:match("24%-hour"), why)
  no, why = raised(spec.add_beat, a, "b", { day_at = "24:00", runs = "x" })
  assert(no, "an hour that does not exist is refused")
  no, why = raised(spec.add_beat, a, "b", { every = 60 })
  assert(no and why:match("needs `runs`"), why)
  no, why = raised(spec.add_beat, a, "b", { every = 60, runs = "x", once_per = "fortnight" })
  assert(no and why:match("once_per"), why)
  -- And the one that holds.
  local b = spec.add_beat(a, "b", { every = 60, runs = "x", once_per = "day", tz = PDT })
  assert(b.every == 60 and b.once_per == "day" and b.tz == PDT)
end

function T.an_interval_beat_waits_out_its_interval()
  local b = { name = "vacuum", every = 3600, runs = function () end }
  assert(schedule.is_due(b, 0, nil), "with no record it is due at once")
  local yes, why = schedule.is_due(b, 100, { at = 0 })
  assert(not yes and why:match("100 of 3600"), why)
  assert(schedule.is_due(b, 3600, { at = 0 }))
end

function T.a_wall_clock_beat_fires_once_when_the_clock_passes_it()
  local a = keeper()
  local b = spec.add_beat(a, "digest", { day_at = "18:00", runs = "summarise", once_per = "day", tz = PDT })
  local six = 1757552400                                  -- 18:00 local
  local yes, why = schedule.is_due(b, six - 60, nil)
  assert(not yes and why:match("not yet 18:00"), why)
  assert(schedule.is_due(b, six, nil))

  -- The failure this replaces: a host ticking every minute firing it sixty times.
  local fired = { at = six, grain = schedule.grain_key(b, six) }
  for minute = 1, 60 do
    local due = schedule.is_due(b, six + minute * 60, fired)
    assert(not due, "it fired again " .. minute .. " minutes later")
  end
  -- And tomorrow it is due again.
  assert(schedule.is_due(b, six + DAY, fired))
end

function T.the_grain_is_read_in_the_beats_own_zone()
  local a = keeper()
  local utc = spec.add_beat(a, "u", { every = 1, runs = "x", once_per = "day" })
  local pdt = spec.add_beat(a, "p", { every = 1, runs = "x", once_per = "day", tz = PDT })
  -- 2025-09-11 01:00 UTC is still the 10th where the beat lives, so the two disagree
  -- about which day it is, which is the whole reason `tz` is on the beat.
  local t = 1757552400
  assert(schedule.grain_key(utc, t) ~= schedule.grain_key(pdt, t))
  assert(schedule.grain_key(pdt, t) == schedule.grain_key(pdt, t + 3600 * 5))
  -- "ever" is the one that never comes round again.
  local once = { name = "o", every = 1, once_per = "ever", runs = "x" }
  assert(schedule.grain_key(once, 0) == schedule.grain_key(once, 10 ^ 9))
end

function T.the_ledger_is_what_survives_a_restart()
  local a = keeper()
  spec.add_beat(a, "digest", { day_at = "18:00", runs = function () return "ran" end, once_per = "day", tz = PDT })
  local six = 1757552400
  local first = double.world { ledger = {} }
  local ran = schedule.tick(a, first, { now = six })
  assert(#ran == 1 and ran[1].ok and ran[1].result == "ran")

  -- The process dies. A new one starts, with only what was written down.
  local second = double.world { ledger = first.ledger.held }
  local ran2, held = schedule.tick(a, second, { now = six + 120 })
  assert(#ran2 == 0, "it fired again across the restart")
  assert(held[1].why:match("already ran for this day"), held[1].why)

  -- Without the ledger there is no such sentence to write, and it fires twice. This is
  -- the measurement that says why the ledger is a port and not a table in this process.
  local forgetful = double.world {}
  assert(#schedule.tick(a, forgetful, { now = six }) == 1)
  assert(#schedule.tick(a, forgetful, { now = six + 120 }) == 1)
end

function T.the_ledger_is_written_before_the_run_not_after()
  local a = keeper()
  spec.add_beat(a, "digest", { every = 60, runs = function () error("the run died") end, once_per = "day" })
  local w = double.world { ledger = {} }
  local ran = schedule.tick(a, w, { now = 0 })
  assert(#ran == 1 and ran[1].ok == false and ran[1].error:match("the run died"))
  -- A crashed run and a run that never happened look the same to a beat, and the
  -- expensive mistake is the digest that goes out twelve times.
  local ran2 = schedule.tick(a, w, { now = 120 })
  assert(#ran2 == 0, "a crash re-armed the beat")

  -- A host that would rather retry says so, and gets the other risk on purpose.
  local w2 = double.world { ledger = {} }
  assert(#schedule.tick(a, w2, { now = 0, record = "after" }) == 1)
  assert(#schedule.tick(a, w2, { now = 120, record = "after" }) == 1)
end

function T.a_prompt_beat_starts_a_run_of_this_agent()
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "keeper"; agent.model "m"
  agent.tool "noop" { about = "does nothing", run = function () return "" end }
  agent.every "digest" { every = 60, runs = "summarise what changed" }
  local w = agent.double.world { model = { { stop = "done", text = "here is the digest" } }, ledger = {} }
  local ran = agent.tick(w, { now = 0 })
  assert(#ran == 1 and ran[1].ok)
  assert(ran[1].result.answer == "here is the digest", "the beat's prompt is what the run was given")
  assert(w.model.seen[1].messages[1].text == "summarise what changed")
end

function T.due_reads_the_world_once_and_says_why_each_held_beat_is_held()
  local a = keeper()
  spec.add_beat(a, "soon", { every = 60, runs = "x" })
  spec.add_beat(a, "later", { day_at = "23:00", runs = "y" })
  local w = double.world { clock = { at = 0 }, ledger = { ["beat/keeper/soon"] = { at = -30 } } }
  local due, held, now = schedule.due(a, w)
  assert(now == 0 and #due == 0 and #held == 2)
  assert(held[1].why:match("30 of 60"), held[1].why)
  assert(held[2].why:match("not yet 23:00"), held[2].why)
  -- Declaration order, both lists, so two ticks of an unchanged agent read the same.
  assert(held[1].beat.name == "soon" and held[2].beat.name == "later")

  local text = schedule.plan(a, w)
  assert(text:match("1970%-01%-01 00:00 UTC") and text:match("held  soon"), text)
end

function T.a_beat_whose_time_passed_while_nothing_ran_fires_once()
  -- The ordinary case, not the exceptional one: the app was shut at five and opened at
  -- nine. The work is usually still wanted, so it runs, and `once_per` stops it running
  -- twice (spec/schedule.md, "A beat whose time passed while nothing was running").
  local a = keeper()
  spec.add_beat(a, "digest", { day_at = "18:00", runs = "x", once_per = "day", tz = PDT })
  local six = 1757552400
  local nine = six + 3 * 3600
  assert(schedule.verdict(a.beats.digest, nine, nil), "a late beat did not fire")
  local w = double.world { ledger = {} }
  assert(#schedule.tick(a, w, { now = nine, run = function () return "ran" end }) == 1)
  assert(#schedule.tick(a, w, { now = nine + 60, run = function () return "ran" end }) == 0)
end

function T.a_beat_that_says_how_late_is_too_late_is_skipped_and_says_so()
  local a = keeper()
  spec.add_beat(a, "standup", { day_at = "09:00", runs = "x", once_per = "day", grace = 3600 })
  local nine = schedule.midnight(1757552400, 0) + 9 * 3600
  assert(schedule.verdict(a.beats.standup, nine + 600, nil), "inside its grace it runs")
  local yes, why, verdict = schedule.verdict(a.beats.standup, nine + 7200, nil)
  assert(not yes and verdict == "skip", tostring(verdict))
  assert(why:match("7200 seconds late") and why:match("allows 3600"), why)

  -- A skip is written down under the grain it skipped, or the beat fires the next
  -- morning as though it had been waiting all night.
  local w = double.world { ledger = {} }
  local ran, held = schedule.tick(a, w, { now = nine + 7200, run = function () return "ran" end })
  assert(#ran == 0 and held[1].skip)
  assert(w.ledger.held["beat/keeper/standup"].skipped:match("late"))
  local ran2 = schedule.tick(a, w, { now = nine + 7200 + 600, run = function () return "ran" end })
  assert(#ran2 == 0, "the skipped beat came back inside the same day")
  -- And tomorrow, on time, it runs.
  assert(#schedule.tick(a, w, { now = nine + 86400 + 60, run = function () return "ran" end }) == 1)
end

function T.an_interval_beat_measures_lateness_from_when_it_was_owed()
  local a = keeper()
  spec.add_beat(a, "poll", { every = 60, runs = "x", grace = 120 })
  local b = a.beats.poll
  -- Owed one period after the last run, so a process asleep for an hour is late by the
  -- hour minus the period, and not by the hour.
  assert(schedule.owed_at(b, 3600, { at = 0 }) == 60)
  assert(schedule.verdict(b, 120, { at = 0 }), "one period late is inside its grace")
  local yes, why, verdict = schedule.verdict(b, 3600, { at = 0 })
  assert(not yes and verdict == "skip" and why:match("3540 seconds late"), why)
  -- With no record at all there is nothing to be late against: it runs.
  assert(schedule.verdict(b, 3600, nil))
end

function T.a_beat_runs_through_the_hosts_own_runner()
  -- A run the clock started must be the run a person would have started: same briefing,
  -- same tools. `tick` therefore takes the runner rather than reaching for the core.
  local a = keeper()
  spec.add_beat(a, "digest", { every = 60, runs = "write it" })
  local seen
  local ran = schedule.tick(a, double.world { ledger = {} }, {
    now = 0,
    run = function (decl, prompt, p, ropts) seen = { decl = decl, prompt = prompt, opts = ropts } return "ran" end,
    run_opts = { system = "the briefing the host composed" },
  })
  assert(#ran == 1 and ran[1].result == "ran")
  assert(seen.decl == a and seen.prompt == "write it")
  assert(seen.opts.system == "the briefing the host composed")

  -- And the prefix's tick passes its own, so an agent started by the clock is briefed.
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "scribe"; agent.model "m"
  agent.skill "digest" { about = "how we write it", does = "THE BODY" }
  agent.every "nightly" { every = 60, runs = "write it" }
  local w = agent.double.world { ledger = {}, model = { { stop = "done", text = "ok" } } }
  local rows = agent.tick(w, { now = 0 })
  assert(rows[1].ok, rows[1].error)
  local system = rows[1].result.transcript[1].text
  assert(system:match("digest %-%- how we write it"), system)
  assert(not system:match("THE BODY"))
end

function T.tick_and_due_take_a_declaration_the_way_run_does()
  -- A host that LOADED a declaration through the sandbox holds a table the prefix has
  -- never seen. Without this it could run that agent and not tick it, which is the same
  -- agent behaving differently depending on who started it.
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "prefix-agent"; agent.model "m"
  agent.tool "noop" { about = "does nothing", run = function () return "" end }

  local loaded = spec.new()
  loaded.name, loaded.model = "loaded", "m"
  spec.add_tool(loaded, "noop", { about = "does nothing", run = function () return "" end })
  spec.add_beat(loaded, "digest", { every = 60, runs = "write it" })

  local w = agent.double.world { ledger = {}, model = { { stop = "done", text = "ok" } } }
  assert(#agent.due(w, { now = 0 }) == 0, "the prefix's own agent has no beats")
  local due = agent.due(loaded, w, { now = 0 })
  assert(#due == 1 and due[1].name == "digest")

  local ran = agent.tick(loaded, w, { now = 0 })
  assert(#ran == 1 and ran[1].ok, ran[1] and ran[1].error)
  assert(w.ledger.held["beat/loaded/digest"], "the ledger row is the loaded agent's")

  -- And `agent.plan` is still the two plan tools, not a report about beats.
  agent.reset(); agent.name "x"; agent.model "m"
  agent.plan()
  assert(agent.spec().tools.plan and agent.spec().tools.mark, "agent.plan stopped installing the plan tools")
end

function T.a_beat_needs_no_ledger_and_no_clock_to_be_asked_about()
  local a = keeper()
  spec.add_beat(a, "soon", { every = 60, runs = "x" })
  local due = schedule.due(a, {}, { now = 0 })
  assert(#due == 1, "with no ledger it is due, because nothing says it ran")
  local no, why = raised(schedule.due, a, {}, {})
  assert(no and why:match("clock"), why)
end

return T
