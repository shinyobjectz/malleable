-- ARCHITECTURE 1: a law that gates, and an agent that repairs what it caught.
--
-- THE PROSE a person writes on a system page:
--
--     Every debt must state its clearing. A debt without one is a complaint, not a plan.
--     When the ledger law catches a debt with no clearing, @debt-clerk drafts one from
--     the debt's own sentence and files it for review. It never files more than three at
--     a time, and it never edits a debt somebody has already answered.
--
-- WHAT THE INTERPRETIVE LAYER READS from it, and WHAT THE MACHINE LAYER RUNS after.
-- The seam between them is the interesting part: the law is a fact about the store, and
-- the agent is a process that reads the law's findings. They are declared in one file and
-- they run at different layers, at different times.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../../?.lua;" .. package.path
local agent = require "agent"
local interpret = agent.interpret

-- ---------------------------------------------------------------- the interpretive layer

interpret.law "debt-has-clearing" {
  is = "Every debt must state its clearing.",
  select = [[SELECT ?s WHERE {
  ?s a type:debt .
  FILTER NOT EXISTS { ?s field:clearing ?what }
}]],
  message = "a debt without a stated clearing is a complaint, not a plan",
  repair = "add clearing: one sentence of what done looks like",
}

-- ------------------------------------------------------------------- the machine layer

agent.name "debt-clerk"
agent.model "openrouter:inception/mercury-2.5"
agent.budget(8)

agent.system [[
You draft a clearing for a debt that has none. A clearing is ONE sentence saying what done
looks like, in the debt's own words. You never invent scope the debt does not state.
]]

agent.tool "offenders" {
  about = "The debts the ledger law caught, as slugs",
  run = function (c) return c.world.law_findings("debt-has-clearing") end,
}

agent.tool "read_debt" {
  about = "The sentence a debt states about itself",
  args = { slug = agent.string "the debt's slug" },
  run = function (c) return c.world.thing(c.args.slug) end,
}

agent.tool "file_clearing" {
  about = "File a drafted clearing for review",
  args = {
    slug = agent.string "the debt this clears",
    clearing = agent.string "one sentence of what done looks like",
  },
  ask = true,                        -- the harness asks; the tool cannot approve itself
  run = function (c) return c.world.file(c.args.slug, c.args.clearing) end,
}

-- THE TWO LIMITS THE PROSE STATED, as declarations rather than as prompt text. A limit in a
-- system prompt is a request; a limit in a hook is a fact.
local filed = 0
agent.on "call" (function (p)
  if p.tool == "file_clearing" then
    if filed >= 3 then return { stop = "it never files more than three at a time" } end
    filed = filed + 1
  end
end)

return { law = "debt-has-clearing", agent = "debt-clerk" }
