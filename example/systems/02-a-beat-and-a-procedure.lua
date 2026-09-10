-- ARCHITECTURE 2: a beat that starts a run, and a procedure a person wrote.
--
-- THE PROSE a person writes on a system page:
--
--     Every evening at six, @scribe writes the day's digest: what changed, what is still
--     open, and anything that has been open for a week. It follows the digest procedure
--     the team keeps, and it never writes two digests for one day.
--
-- Three sentences, and before these two seams existed the harness could hold none of
-- them. "Every evening at six" needs a BEAT: a run that nobody typed. "It follows the
-- digest procedure the team keeps" needs a SKILL: a procedure the workspace holds, that
-- the agent reads and may not rewrite. "Never two for one day" needs a LEDGER: a record
-- that survives the process, because the restart is exactly when a beat double-fires.
--
--     lua example/systems/02-a-beat-and-a-procedure.lua
--
-- runs the whole thing against the doubles: no network, no disk, no clock.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../../?.lua;" .. package.path
local agent = require "agent"

-- ------------------------------------------------------------------ who it is

agent.name "scribe"
agent.model "openrouter:inception/mercury-2.5"
agent.budget(8)

agent.system [[
You write the evening digest for this workspace. Read the digest procedure before you
write anything, and follow it as written.
]]

-- --------------------------------------------------------------- the procedure
--
-- Stated here because this file is the whole example. In a workspace it is a file the
-- team edits, reached through the skills port, and the declaration says nothing at all.
--
-- The model is told the NAME and the SENTENCE. The body arrives only when it asks. That
-- is not a token saving: twelve procedures pasted into a system prompt is twelve
-- procedures the model half-remembers, and it fails by following the shape of one and
-- the details of another, with nothing in the transcript to say so.

agent.skill "digest" {
  about = "how this team writes the evening digest",
  does  = [[
1. Open the changes since the last digest.
2. Three sections, in this order: what changed, what is still open, what has been open
   for a week or more.
3. One line per item, and the item's own words. Never characterise a person's work.
4. If nothing changed, say that in one line and stop. Do not pad a quiet day.
]],
}

agent.skills()                        -- the tool that reads them

-- ------------------------------------------------------------------ what it can do

agent.tool "changes" {
  about = "What changed today, as one line per change",
  run   = function (c) return c.world.changes() end,
}

agent.tool "file_digest" {
  about = "File the digest for the day",
  args  = { text = agent.string "the digest, as the procedure describes it" },
  run   = function (c) return c.world.file(c.args.text) end,
}

-- ---------------------------------------------------------------------- the beat
--
-- The declaration states the beat; it does not start anything. `agent.tick(port)` is
-- what a host calls -- the app on its own beat, a cron line, a test -- and the harness
-- never starts a run by itself.

agent.every "digest" {
  about    = "the evening digest",
  day_at   = "18:00",
  tz       = -25200,                  -- the zone this team keeps, in seconds from UTC
  runs     = "Write today's digest.",
  once_per = "day",                   -- and the ledger is what makes this true
}

-- ------------------------------------------------------- running it, against doubles

local function is_main()
  local source = debug.getinfo(1, "S").source:sub(2)
  local named = type(arg) == "table" and arg[0] or nil
  return type(named) == "string" and (named == source or source:sub(-#named) == named)
end

if is_main() then
  local filed = {}
  local world = agent.world {
    ledger = {},                      -- empty: this workspace has never run a digest
    model = {
      { tool = "skill",   args = { name = "digest" } },
      { tool = "changes", args = {} },
      { tool = "file_digest", args = { text = "changed: the turn loop takes a veto\nopen: the corpus sweep\nweek: nothing" } },
      { text = "Filed the digest." },
    },
  }
  -- The workspace this agent acts on, hung on the port under one name, the way
  -- example/systems/01 does: everything on the port that is not a capability arrives on
  -- the tool context untouched.
  world.world = {
    changes = function () return "the turn loop takes a veto\nthe corpus sweep is paused" end,
    file    = function (text) filed[#filed + 1] = text return "filed" end,
  }

  -- Six in the evening where this team lives, on a Friday in September 2026.
  local six = 1789779600
  local schedule = agent.schedule

  print("at " .. schedule.reads(six - 3600, -25200) .. " local")
  print((select(1, schedule.plan(agent.spec(), world, { now = six - 3600 }))))

  print("\nat " .. schedule.reads(six, -25200) .. " local")
  local ran = agent.tick(world, { now = six })
  for _, row in ipairs(ran) do
    print(("  ran %s -> %s"):format(row.beat, row.ok and row.result.stop or row.error))
    for _, call in ipairs(row.ok and row.result.calls or {}) do
      print(("    %-12s %s"):format(call.tool, (call.output:match("^[^\n]*") or "")))
    end
  end

  -- The process dies here and a new one starts, with only what was written down.
  print("\nafter a restart, at " .. schedule.reads(six + 600, -25200) .. " local")
  local restarted = agent.world { ledger = world.ledger.held, model = { { text = "should not run" } } }
  local ran2, held = agent.tick(restarted, { now = six + 600 })
  print(("  ran %d, held: %s"):format(#ran2, held[1] and held[1].why or ""))

  print("\ndigests filed: " .. #filed)
end
