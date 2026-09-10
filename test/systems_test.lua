-- The system examples, driven end to end.
--
-- example/systems/*.lua are the worked architectures: the prose a person writes, and
-- the declarations that hold it. They are tests as much as documentation -- if a seam
-- stops meaning what the prose says, it shows here first, in a file somebody reads.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local agent = require "agent"

local T = {}

local function load_example(name)
  agent.reset()
  dofile(here .. "/../example/systems/" .. name)
  return agent.spec()
end

function T.the_gate_and_repair_example_declares_a_law_and_a_limit()
  local a = load_example("01-gate-and-repair.lua")
  assert(a.name == "debt-clerk")
  assert(a.tools.offenders and a.tools.file_clearing.ask == true)
  -- The limit the prose stated is a hook, not a sentence in the system message: a limit
  -- in a system prompt is a request, and this one is a fact.
  assert(#a.hooks.call == 1)
  local world = agent.world { model = {
    { tool = "file_clearing", args = { slug = "d1", clearing = "one" } },
    { tool = "file_clearing", args = { slug = "d2", clearing = "two" } },
    { tool = "file_clearing", args = { slug = "d3", clearing = "three" } },
    { tool = "file_clearing", args = { slug = "d4", clearing = "four" } },
    { text = "done" },
  }, ask = true }
  world.world = { law_findings = function () return "d1 d2 d3 d4" end,
                  thing = function () return "a sentence" end,
                  file = function (slug) return "filed " .. slug end }
  local r = agent.run("repair what the law caught", world)
  local filed = 0
  for i = 1, #r.calls do if r.calls[i].ok then filed = filed + 1 end end
  assert(filed == 3, "it filed " .. filed .. ", and the prose says three")
  assert(r.stop == "refused", r.stop)
  assert(r.reason:match("never files more than three"), r.reason)
end

function T.the_beat_example_writes_one_digest_a_day_across_a_restart()
  local a = load_example("02-a-beat-and-a-procedure.lua")
  assert(a.beats.digest.hour == 18 and a.beats.digest.once_per == "day")
  assert(a.skills.digest.about:match("evening digest"))
  assert(a.tools.skill, "the tool that reads a procedure is installed")

  local filed = {}
  local function world_at()
    local w = agent.world { ledger = {}, model = {
      { tool = "skill", args = { name = "digest" } },
      { tool = "file_digest", args = { text = "changed: one thing" } },
      { text = "filed" },
    } }
    w.world = { changes = function () return "one thing" end,
                file = function (t) filed[#filed + 1] = t return "filed" end }
    return w
  end

  local six = 1789779600
  local w = world_at()
  assert(#agent.tick(w, { now = six - 60 }) == 0, "it wrote before six")
  local ran = agent.tick(w, { now = six })
  assert(#ran == 1 and ran[1].ok and ran[1].result.stop == "answered", ran[1].error)
  assert(#filed == 1)

  -- The body of the procedure reached the model only because it asked for it, and the
  -- briefing that told it to ask did not carry the body.
  local system = ran[1].result.transcript[1].text
  assert(system:match("digest %-%- how this team writes"), system)
  assert(not system:match("Do not pad a quiet day"), "the body was inlined into the briefing")
  assert(ran[1].result.calls[1].output:match("Do not pad a quiet day"), "the body is what the tool answered")

  -- A new process, holding only what was written down.
  local after = agent.world { ledger = w.ledger.held, model = { { text = "should not run" } } }
  local ran2, held = agent.tick(after, { now = six + 600 })
  assert(#ran2 == 0 and held[1].why:match("already ran for this day"), held[1].why)
  assert(#filed == 1)
end

function T.the_borrowed_tools_example_never_offers_what_it_did_not_ask_for()
  local a = load_example("03-borrowed-tools.lua")
  assert(#a.server_order == 2 and a.servers.github.ask == false)
  assert(next(a.tools) == nil, "declaring a server declared a tool")

  local function tool(name, props, required)
    return { name = name, description = name, inputSchema = { type = "object", properties = props, required = required } }
  end
  local REPO = { type = "string" }
  local world = agent.world {
    mcp = { github = { tools = { tool("list_issues", { repo = REPO }, { "repo" }),
                                 tool("label_issue", { repo = REPO, label = { type = "string" } }, { "repo", "label" }),
                                 tool("comment", { repo = REPO, body = { type = "string" } }, { "repo", "body" }),
                                 tool("close_issue", { repo = REPO }, { "repo" }) },
                       answers = { list_issues = "one issue", label_issue = "labelled" } },
            ops = { down = "the endpoint refused the connection" } },
    model = { { tool = "github_label_issue", args = { repo = "team/app", label = "flaky" } },
              { tool = "github_label_issue", args = { repo = "production/secrets", label = "flaky" } },
              { tool = "github_close_issue", args = { repo = "team/app" } },
              { text = "done" } },
  }
  local r = agent.run("triage", world)

  -- The tool the declaration did not ask for is not in the schema, and a tool that is
  -- not in the schema cannot be argued with.
  local names = {}
  for _, t in ipairs(agent.schema()) do names[t.name] = true end
  assert(names.github_label_issue and not names.github_close_issue)

  assert(r.calls[1].ok, r.calls[1].output)
  assert(r.calls[2].refused and r.calls[2].output:match("production repositories"), r.calls[2].output)
  -- And the model asking anyway for the tool that was never fetched is an ordinary
  -- unknown-tool result, not a call.
  assert(r.calls[3].ok == false)
  assert(r.notes[1]:match("ops") and r.notes[1]:match("refused the connection"), r.notes[1])
end

return T
