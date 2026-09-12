-- A kit (docs/spec/kit.md): a calendar the agent keeps. Loaded by the line
-- `it uses the kit "kits/calendar.lua"` in showcase/20-kits.feature, and usable from Lua
-- with `agent.kit(require_this_table, { keeps = true, limit = 2 })`.
--
-- Two lines say it, one widening and one narrowing; using it installs a store and two
-- tools over it; two steps let a scenario seed the calendar and read it back; `says`
-- gives the lines back when it was used from Lua.
return {
  name  = "calendar",
  about = "events the agent keeps in a store, and two tools over them",

  is = {
    { expr = "it keeps a calendar", reach = "widens",
      about = "the book and agenda tools over a store of events",
      tells = function (told) told.keeps = true end },
    { expr = "the calendar holds at most {int} events", reach = "narrows",
      about = "book refuses an event past this many",
      tells = function (told, n)
        if n < 1 then error("a calendar holds at least one event", 0) end
        told.limit = n
      end },
  },

  install = function (told, agent)
    agent.store "events" {
      about = "one event a row",
      columns = { title = agent.string "what", at = agent.string "when, as YYYY-MM-DD HH:MM" },
      sort = "at",
    }
    agent.tool "book" {
      about = "Book an event." .. (told.limit and (" The calendar holds at most " .. told.limit .. " events.") or ""),
      args = { title = agent.string "what", at = agent.string "when, as YYYY-MM-DD HH:MM" },
      run = function (c)
        if told.limit and #c.store.rows("events") >= told.limit then
          return nil, "the calendar is full: it holds at most " .. told.limit .. " events"
        end
        local ok, why = c.store.add("events", { title = c.args.title, at = c.args.at })
        if not ok then return nil, why end
        return "booked " .. c.args.title .. " at " .. c.args.at
      end,
    }
    agent.tool "agenda" {
      about = "Every event, in order.",
      run = function (c)
        local rows = c.store.rows("events")
        if #rows == 0 then return "nothing is booked" end
        local out = {}
        for i = 1, #rows do out[i] = rows[i].at .. "  " .. rows[i].title end
        return table.concat(out, "\n")
      end,
    }
  end,

  steps = {
    { expr = "the calendar has {string} at {string}",
      given = function (c)
        c.world.store = c.world.store or {}
        c.world.store.events = c.world.store.events or {}
        local rows = c.world.store.events
        rows[#rows + 1] = { title = c.args[1], at = c.args[2] }
      end },
    { expr = "the calendar holds {string}",
      then_ = function (c)
        local held = c.world and c.world.store and c.world.store.tables and c.world.store.tables.events or {}
        for i = 1, #held do if held[i].title == c.args[1] then return true end end
        return false, "the calendar holds " .. #held .. " event(s), and " .. c.args[1] .. " is not one"
      end },
  },

  says = function (told)
    local out = { "it keeps a calendar" }
    if told.limit then out[#out + 1] = "the calendar holds at most " .. told.limit .. " events" end
    return out
  end,
}
