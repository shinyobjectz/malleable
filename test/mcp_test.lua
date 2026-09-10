-- mcp: tools that live in another process, made into tools that do not.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local mcp    = require "mcp"
local spec   = require "spec"
local double = require "double"

local T = {}

local function raised(fn, ...)
  local ok, message = pcall(fn, ...)
  return (not ok), tostring(message)
end

local ISSUES = {
  name = "list_issues",
  description = "List the open issues",
  inputSchema = {
    type = "object",
    properties = {
      repo  = { type = "string",  description = "owner/name" },
      limit = { type = "integer", description = "how many" },
      open  = { type = "boolean" },
      tags  = { type = "array" },
    },
    required = { "repo" },
  },
}

local function keeper()
  local a = spec.new()
  a.name, a.model = "keeper", "m"
  return a
end

local function world(cfg)
  return double.world { mcp = cfg }
end

function T.a_declaration_reaches_nothing()
  local a = keeper()
  local reached = false
  local w = { mcp = { list = function () reached = true end, call = function () end } }
  spec.add_server(a, "github", { command = { "npx", "x" } })
  assert(not reached, "declaring a server connected to it")
  assert(a.tools["github_list_issues"] == nil)
  local _ = w
end

function T.a_fetched_tool_is_the_same_kind_of_thing_as_a_declared_one()
  local a = keeper()
  spec.add_server(a, "github", { command = { "npx", "x" } })
  local w = world { github = { tools = { ISSUES }, answers = { list_issues = "3 open" } } }
  local added, problems = mcp.connect(a, w)
  assert(#problems == 0, problems[1])
  assert(#added == 1 and added[1] == "github_list_issues", added[1])

  -- It reads, in the schema, exactly like a tool written here.
  local schema = spec.schema(a)
  assert(#schema == 1)
  assert(schema[1].name == "github_list_issues")
  assert(schema[1].about == "List the open issues")
  assert(schema[1].ask == true, "another process is not this one")
  local args = {}
  for i = 1, #schema[1].args do args[schema[1].args[i].name] = schema[1].args[i] end
  assert(args.repo.kind == "string" and args.repo.required)
  assert(args.limit.kind == "number" and not args.limit.required, "integer is a number, and optional")
  assert(args.open.kind == "boolean" and args.tags.kind == "array")
  assert(args.repo.description == "owner/name", "the server's own words survive")
end

function T.the_call_goes_through_the_port_and_the_content_list_is_read()
  local a = keeper()
  spec.add_server(a, "github", {})
  local w = world { github = { tools = { ISSUES }, answers = {
    list_issues = function (args) return { content = { { type = "text", text = "3 open in " .. args.repo },
                                                       { type = "image" },
                                                       { type = "text", text = "one is stale" } } } end } } }
  mcp.connect(a, w)
  local out = a.tools["github_list_issues"].run { args = { repo = "team/app" } }
  assert(out == "3 open in team/app\n[image]\none is stale", out)
  assert(w.mcp.calls[1].server == "github" and w.mcp.calls[1].tool == "list_issues")
  assert(w.mcp.calls[1].args.repo == "team/app")
end

function T.a_server_that_is_down_is_a_problem_and_the_rest_of_the_run_stands()
  local a = keeper()
  spec.add_tool(a, "read", { about = "read a file", run = function () return "" end })
  spec.add_server(a, "github", {})
  spec.add_server(a, "docs", {})
  local w = world { github = { tools = { ISSUES }, answers = { list_issues = "ok" } },
                    docs   = { down = "the process did not start" } }
  local added, problems = mcp.connect(a, w)
  assert(#added == 1 and added[1] == "github_list_issues")
  assert(#problems == 1 and problems[1]:match("docs") and problems[1]:match("did not start"), problems[1])
  assert(a.tools.read, "the agent still reads files")
end

function T.a_failing_call_is_a_sentence_the_model_reads()
  local a = keeper()
  spec.add_server(a, "github", {})
  local w = world { github = { tools = { ISSUES } } }             -- no scripted answer
  mcp.connect(a, w)
  local out = a.tools["github_list_issues"].run { args = { repo = "x/y" } }
  assert(type(out) == "string" and out:match("could not run list_issues"), out)
end

function T.the_declaration_says_which_tools_and_a_missing_one_is_named()
  local a = keeper()
  spec.add_server(a, "github", { tools = { "list_issues", "create_issue" } })
  local w = world { github = { tools = { ISSUES, { name = "delete_repo", description = "…" } },
                               answers = {} } }
  local added, problems = mcp.connect(a, w)
  assert(#added == 1, "delete_repo was not asked for and did not arrive")
  assert(a.tools["github_delete_repo"] == nil)
  -- A tool the declaration asked for and the server does not have is a typo or a
  -- version drift, and both otherwise read as an agent that quietly cannot do its job.
  assert(#problems == 1 and problems[1]:match("does not offer: create_issue"), problems[1])
end

function T.two_servers_with_one_tool_name_do_not_collide()
  local a = keeper()
  spec.add_server(a, "github", {})
  spec.add_server(a, "jira", { join = "." })
  local search = { name = "search", description = "search", inputSchema = { type = "object", properties = {} } }
  local w = world { github = { tools = { search }, answers = { search = "from github" } },
                    jira   = { tools = { search }, answers = { search = "from jira" } } }
  local added, problems = mcp.connect(a, w)
  assert(#problems == 0, problems[1])
  assert(#added == 2 and a.tools["github_search"] and a.tools["jira.search"])
  assert(a.tools["github_search"].run { args = {} } == "from github")
  assert(a.tools["jira.search"].run { args = {} } == "from jira")
end

function T.connect_is_idempotent_and_says_so_when_there_is_no_port()
  local a = keeper()
  spec.add_server(a, "github", {})
  local w = world { github = { tools = { ISSUES }, answers = { list_issues = "ok" } } }
  assert(#mcp.connect(a, w) == 1)
  local again, problems = mcp.connect(a, w)
  assert(#again == 0 and #problems == 0, "a second connect added a second copy")
  assert(#w.mcp.listed == 1, "and it did not even ask twice")

  local b = keeper()
  spec.add_server(b, "github", {})
  local added, why = mcp.connect(b, double.world {})
  assert(#added == 0 and #why == 1 and why[1]:match("no mcp port"), why[1])
end

function T.a_descriptor_may_arrive_in_the_harnesss_own_shape()
  local a = keeper()
  spec.add_server(a, "local", { ask = false })
  local w = world { ["local"] = { tools = { { name = "ping", about = "say hello",
                                              args = { who = spec.types.string("whom") } } },
                                  answers = { ping = "hello" } } }
  local added, problems = mcp.connect(a, w)
  assert(#problems == 0 and #added == 1)
  local t = a.tools["local_ping"]
  assert(t.about == "say hello" and t.ask == false and t.args.who.kind == "string")
end

function T.an_unreadable_schema_still_produces_a_usable_tool()
  local a = keeper()
  spec.add_server(a, "odd", {})
  local w = world { odd = { tools = {
    { name = "one" },                                                   -- no schema at all
    { name = "two", inputSchema = { type = "object", properties = { x = { type = "geometry", description = "a shape" },
                                                                    y = { type = { "string", "null" } } } } },
    { description = "no name" },
  }, answers = { one = "1", two = "2" } } }
  local added, problems = mcp.connect(a, w)
  assert(#added == 2, "the two named tools arrived")
  assert(#problems == 1 and problems[1]:match("no name"), problems[1])
  assert(a.tools.odd_one.about:match("the one tool on odd"), "a tool with no sentence gets one that is true")
  -- An unknown type becomes a string carrying the schema's own words, and never a
  -- constraint the server did not state.
  assert(a.tools.odd_two.args.x.kind == "string" and a.tools.odd_two.args.x.description == "a shape")
  assert(a.tools.odd_two.args.y.kind == "string" and not a.tools.odd_two.args.y.required)
end

function T.a_server_is_reached_when_the_run_starts_and_its_problems_are_on_the_run()
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "keeper"; agent.model "m"
  agent.uses "github" { command = { "npx", "x" }, ask = false }
  agent.uses "docs" {}
  local w = agent.double.world {
    model = { { stop = "calls", calls = { { id = "c1", tool = "github_list_issues", args = { repo = "team/app" } } } },
              { stop = "done", text = "done" } },
    mcp = { github = { tools = { ISSUES }, answers = { list_issues = "3 open" } },
            docs   = { down = "no such command" } },
  }
  local r = agent.run("look", w)
  assert(r.stop == "answered", r.stop)
  assert(r.calls[1].ok and r.calls[1].output == "3 open")
  -- The server that was never reached is a fact about the whole run, and is in front of
  -- the notes the run itself made.
  assert(r.notes[1]:match("docs") and r.notes[1]:match("no such command"), r.notes[1])
end

function T.a_server_declaration_is_checked_and_its_rest_is_the_hosts_business()
  local a = keeper()
  local no, why = raised(spec.add_server, a, "x", { tools = "list_issues" })
  assert(no and why:match("`tools` is the list"), why)
  no, why = raised(spec.add_server, a, "x", { tools = { 7 } })
  assert(no and why:match("entry 1 is number"), why)
  no, why = raised(spec.add_server, a, "x", { ask = "yes" })
  assert(no and why:match("`ask` is true or false"), why)
  -- Anything else it states is handed to the port untouched: this module does not know
  -- what a transport is, and the day it does, adding one means editing two files.
  local s = spec.add_server(a, "x", { url = "https://example/mcp", headers = { auth = "…" } })
  assert(s.config.url == "https://example/mcp" and s.config.headers.auth == "…")
  local seen
  local w = { mcp = { list = function (_, cfg) seen = cfg; return {} end, call = function () end } }
  mcp.connect(a, w)
  assert(seen.url == "https://example/mcp" and seen.headers.auth == "…")
end

return T
