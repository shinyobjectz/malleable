-- ARCHITECTURE 3: tools that live in another process, and a hook that says no.
--
-- THE PROSE a person writes on a system page:
--
--     @triager works the issue tracker through the team's github server and reads the
--     deploy log through the ops server. It labels and comments; it never closes an
--     issue, and it never touches anything under the production repository.
--
-- Two seams. The tracker's tools are not this process's tools and never will be: they
-- are a name, a sentence and a schema that arrived over a wire, and the honest thing to
-- do is make them ordinary tools before the model ever sees one -- by the time the
-- schema is read there is no way to tell which were declared here and which were
-- fetched, because the model's job is not to know.
--
-- The second sentence is a LIMIT, and a limit in a system prompt is a request. Two of
-- the three ways to make it a fact are here:
--
--   * `tools = { ... }` -- the tool is never fetched, so it is not in the schema and
--     the model cannot ask for it. This is the strongest form: an absent tool cannot be
--     argued with.
--   * a `call` hook that refuses -- for the limit that is about the ARGUMENTS rather
--     than about the tool, which no allow-list can express.
--
-- The third is `ask`, which is rule 4 and puts the call to a person.
--
--     lua example/systems/03-borrowed-tools.lua

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../../?.lua;" .. package.path
local agent = require "agent"

agent.name "triager"
agent.model "openrouter:inception/mercury-2.5"
agent.budget(10)

agent.system [[
You triage what comes into the tracker: label it, and comment when the label needs
saying out loud. You do not close anything.
]]

-- ---------------------------------------------------------------- borrowed tools
--
-- Nothing here connects. A declaration that names a network is under the same rule as
-- one that names a file: it states, and the run reaches. Everything stated that this
-- harness does not know -- the command line, the URL, the headers -- is handed to the
-- mcp port untouched, so adding a transport is a change to one port and to nothing else.

agent.uses "github" {
  command = { "npx", "-y", "@modelcontextprotocol/server-github" },
  tools   = { "list_issues", "label_issue", "comment" },   -- close_issue is not fetched
  ask     = false,
}

agent.uses "ops" {
  url  = "https://ops.internal/mcp",
  tools = { "deploy_log" },
  ask  = false,
}

-- THE LIMIT THE ALLOW-LIST CANNOT STATE. It is about an argument, not about a tool: the
-- same label_issue is fine on one repository and not on another. A hook may refuse a
-- call -- it may not rewrite one -- and the refusal comes back to the model as an
-- ordinary tool result, which is rule 4 in the same shape as the approval gate's.
agent.on "call" (function (p)
  local repo = p.args and p.args.repo
  if type(repo) == "string" and repo:match("^production/") then
    return { allow = false, why = "the production repositories are not this agent's to touch" }
  end
end)

-- ------------------------------------------------------- running it, against doubles

local function is_main()
  local source = debug.getinfo(1, "S").source:sub(2)
  local named = type(arg) == "table" and arg[0] or nil
  return type(named) == "string" and (named == source or source:sub(-#named) == named)
end

if is_main() then
  local function tool(name, about, props, required)
    return { name = name, description = about,
             inputSchema = { type = "object", properties = props, required = required } }
  end
  local REPO = { type = "string", description = "owner/name" }

  local world = agent.world {
    mcp = {
      github = {
        tools = {
          tool("list_issues",  "List the open issues",  { repo = REPO }, { "repo" }),
          tool("label_issue",  "Put a label on one",    { repo = REPO, number = { type = "integer" },
                                                          label = { type = "string" } }, { "repo", "number", "label" }),
          tool("comment",      "Comment on one",        { repo = REPO, number = { type = "integer" },
                                                          body = { type = "string" } }, { "repo", "number", "body" }),
          tool("close_issue",  "Close one",             { repo = REPO, number = { type = "integer" } }, { "repo", "number" }),
        },
        answers = {
          list_issues  = function (a) return { content = { { type = "text", text = "#41 flaky test in " .. a.repo } } } end,
          label_issue  = function (a) return "labelled #" .. a.number .. " " .. a.label end,
          comment      = "commented",
        },
      },
      -- The second server is not running. One server being down must not stop an agent
      -- that can still do the rest of its job.
      ops = { down = "the endpoint refused the connection" },
    },
    model = {
      { tool = "github_list_issues", args = { repo = "team/app" } },
      { tool = "github_label_issue", args = { repo = "team/app", number = 41, label = "flaky" } },
      { tool = "github_label_issue", args = { repo = "production/secrets", number = 1, label = "flaky" } },
      { text = "Labelled #41 flaky. The production repository is not mine to touch, and the deploy log was unreachable." },
    },
  }

  local result = agent.run("Triage what came in today.", world)

  print("the tools the model was shown:")
  for _, t in ipairs(agent.schema()) do
    print(("  %-22s ask=%-5s %s"):format(t.name, tostring(t.ask), t.about))
  end
  print("\nthe run:")
  for _, call in ipairs(result.calls) do
    print(("  %-22s %-4s %s"):format(call.tool, call.ok and "ok" or "--", (call.output:match("^[^\n]*") or "")))
  end
  for _, note in ipairs(result.notes) do print("  note: " .. note) end
  print("\nstop: " .. tostring(result.stop))
end
