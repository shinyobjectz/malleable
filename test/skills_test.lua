-- skills: the procedures a workspace keeps.
--
-- No network, no disk, no clock. The adversarial half is the half worth reading: what
-- happens when two sources hold one name, when a body is missing, and when the world
-- answers with rubbish.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local skills = require "skills"
local spec   = require "spec"
local double = require "double"

local T = {}

local function raised(fn, ...)
  local ok, message = pcall(fn, ...)
  return (not ok), tostring(message)
end

local function declared()
  local a = spec.new()
  a.name, a.model = "keeper", "m"
  spec.add_skill(a, "triage", { about = "how this team triages", does = "1. reproduce\n2. label" })
  spec.add_skill(a, "deploy", { about = "the deploy checklist", file = "docs/deploy.md" })
  return a
end

function T.a_skill_needs_a_name_a_sentence_and_exactly_one_body()
  local a = spec.new()
  local no, why = raised(spec.add_skill, a, "x", { does = "y" })
  assert(no and why:match("needs `about`"), why)

  no, why = raised(spec.add_skill, a, "x", { about = "s" })
  assert(no and why:match("needs `does`"), why)

  -- Two sources for one procedure is a procedure nobody can be sure they are reading.
  no, why = raised(spec.add_skill, a, "x", { about = "s", does = "y", file = "z.md" })
  assert(no and why:match("one source"), why)

  spec.add_skill(a, "x", { about = "s", does = "y" })
  no, why = raised(spec.add_skill, a, "x", { about = "s", does = "y" })
  assert(no and why:match("declared twice"), why)
end

function T.the_catalogue_is_declared_first_then_the_world_alphabetically()
  local a = declared()
  local w = double.world { skills = { review = { about = "the review pass", does = "…" },
                                      audit  = { about = "the audit",       does = "…" } } }
  local cat = skills.catalogue(a, w)
  assert(#cat == 4, #cat)
  assert(cat[1].name == "triage" and cat[1].from == "declared")
  assert(cat[2].name == "deploy")
  -- The world's, alphabetically: audit before review, whatever order pairs walked.
  assert(cat[3].name == "audit" and cat[3].from == "workspace", cat[3].name)
  assert(cat[4].name == "review")
end

function T.a_name_held_by_both_is_reported_and_the_declared_one_is_read()
  local a = declared()
  local w = double.world { skills = { triage = { about = "someone elses triage", does = "do it differently" } } }
  local cat, clashes = skills.catalogue(a, w)
  assert(#clashes == 1 and clashes[1] == "triage")
  -- Named once in the catalogue, not twice.
  local count = 0
  for i = 1, #cat do if cat[i].name == "triage" then count = count + 1 end end
  assert(count == 1)
  assert(skills.body(a, w, "triage"):match("reproduce"), "the declared body is the one read")
  -- And the run is told, rather than the shadowing happening in silence.
  local _, said = skills.briefing(a, w)
  assert(#said == 1 and said[1] == "triage")
end

function T.a_file_skill_is_read_through_the_fs_port_when_it_is_asked_for()
  local a = declared()
  local w = double.world { fs = { ["docs/deploy.md"] = "tag, then push" } }
  assert(skills.body(a, w, "deploy") == "tag, then push")
  -- Editing the file changes the next read, not this process: nothing was cached at
  -- declaration time, which is the whole reason `file` exists next to `does`.
  w.fs.write("docs/deploy.md", "tag, wait, then push")
  assert(skills.body(a, w, "deploy") == "tag, wait, then push")
end

function T.a_missing_body_is_a_sentence_naming_the_file()
  local a = declared()
  local w = double.world {}
  local text, why = skills.body(a, w, "deploy")
  assert(text == nil)
  assert(why:match("docs/deploy%.md") and why:match("did not read"), why)

  -- And with no filesystem at all, it says that instead of raising.
  local text2, why2 = skills.body(a, {}, "deploy")
  assert(text2 == nil and why2:match("no filesystem"), why2)
end

function T.a_skill_that_does_not_exist_is_answered_with_the_ones_that_do()
  local a = declared()
  local w = double.world { skills = { review = "read the diff twice" } }
  local text, why = skills.body(a, w, "tirage")
  assert(text == nil)
  -- Never a near miss offered as a correction: that is how a model runs one procedure
  -- believing it asked for another.
  assert(not why:match("did you mean"), why)
  assert(why:match("triage") and why:match("deploy") and why:match("review"), why)
end

function T.the_worlds_not_found_reads_as_no_such_skill_and_not_as_a_broken_world()
  local a = spec.new()
  a.name, a.model = "k", "m"
  spec.add_skill(a, "triage", { about = "t", does = "y" })
  local w = double.world { skills = {} }
  local _, why = skills.body(a, w, "nope")
  assert(why:match("there is no skill") and why:match("triage"), why)

  -- Anything OTHER than not_found is the world failing, and says so.
  local broken = { skills = { list = function () return {} end,
                              read = function () return nil, { code = "timeout", message = "the disk did not answer" } end } }
  local _, why2 = skills.body(a, broken, "nope")
  assert(why2:match("did not answer"), why2)
end

function T.a_world_that_answers_with_rubbish_costs_its_skills_and_not_the_run()
  local a = declared()
  local rubbish = { skills = { list = function () return 7 end, read = function () return nil end } }
  local cat = skills.catalogue(a, rubbish)
  assert(#cat == 2, "the declared two survive")

  local mixed = { skills = { list = function () return { "plain", { about = "no name" }, { name = "ok", about = "fine" } } end,
                             read = function () return "…" end } }
  local cat2 = skills.catalogue(a, mixed)
  local names = {}
  for i = 1, #cat2 do names[cat2[i].name] = true end
  assert(names["plain"] and names["ok"] and not names["no name"], "the nameless entry is dropped, the rest kept")
end

function T.the_briefing_is_the_authors_own_sentence_never_a_summary()
  local a = declared()
  local brief = skills.briefing(a, {})
  assert(brief:match("triage %-%- how this team triages"), brief)
  assert(brief:match("skill tool"), "it names the tool the model must call")
  -- Nothing to say when there is nothing to read.
  assert(skills.briefing(spec.new(), {}) == nil)
  -- The tool's name is the one that was installed, when it is not the default.
  assert(skills.briefing(a, {}, { tool = "procedure" }):match("procedure tool"))
end

function T.the_tool_answers_with_the_body_and_never_raises()
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "keeper"; agent.model "m"
  agent.skill "triage" { about = "t", does = "1. reproduce" }
  local t = agent.skills()
  assert(t.name == "skill" and t.args.name.kind == "string")
  assert(t.run { args = { name = "triage" } } == "1. reproduce")
  -- A miss is a sentence the model can read, not an error the run has to survive.
  local out = t.run { args = { name = "nope" } }
  assert(type(out) == "string" and out:match("there is no skill"), out)
  -- And an argument of the wrong shape is the same: a sentence.
  assert(t.run({ args = {} }):match("asked for by name"))
end

function T.the_briefing_reaches_the_model_and_the_body_only_when_asked_for()
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "keeper"; agent.model "m"
  agent.system "You keep this workspace."
  agent.skill "triage" { about = "how this team triages", does = "THE PROCEDURE ITSELF" }
  agent.skills()
  local w = agent.double.world { model = { { stop = "done", text = "ok" } } }
  local r = agent.run("hello", w)

  local system = r.transcript[1]
  assert(system.role == "system")
  assert(system.text:match("You keep this workspace"), "the declared system message survives")
  assert(system.text:match("triage %-%- how this team triages"), "the briefing is appended")
  -- The body is NOT in the system message. This is the whole of progressive disclosure,
  -- and it is the assertion that fails the day someone "helpfully" inlines the bodies.
  assert(not system.text:match("THE PROCEDURE ITSELF"), "the body waits until it is asked for")

  -- And an agent with no skills at all is unchanged: no briefing, no empty heading.
  agent.reset(); agent.name "bare"; agent.model "m"
  agent.tool "noop" { about = "does nothing", run = function () return "" end }
  local r2 = agent.run("hello", agent.double.world { model = { { stop = "done", text = "ok" } } })
  assert(r2.transcript[1].role == "user", "no system message was invented")
end

function T.a_declaration_that_states_a_skill_gets_the_tool_without_asking()
  -- A briefing that names a tool the run does not have is a promise the model cannot
  -- keep, and the author sees nothing at all. So the tool is installed at RUN time when
  -- there is anything to read and nothing to read it with.
  local agent = dofile(here .. "/../agent.lua")
  agent.reset(); agent.name "k"; agent.model "m"
  agent.skill "triage" { about = "how we triage", does = "THE BODY" }
  assert(agent.spec().tools.skill == nil, "declaring a skill declared a tool: rule 2")

  local w = agent.double.world {
    model = { { stop = "calls", calls = { { id = "c1", tool = "skill", args = { name = "triage" } } } },
              { stop = "done", text = "ok" } } }
  local r = agent.run("go", w)
  assert(r.calls[1].ok and r.calls[1].output == "THE BODY")

  -- A declaration that installed it itself, under its own name, is left alone.
  agent.reset(); agent.name "k"; agent.model "m"
  agent.skill "triage" { about = "t", does = "b" }
  agent.skills { name = "procedure" }
  skills.ensure(agent.spec(), {})
  assert(agent.spec().tools.skill == nil, "a second tool was added for the same seam")
  assert(agent.spec().tools.procedure)
  assert(skills.system(agent.spec(), {}):match("procedure tool"), "the briefing names the installed tool")

  -- And an agent with no skills and no port is untouched.
  local bare = spec.new()
  assert(skills.ensure(bare, {}) == nil and next(bare.tools) == nil)
  -- A port with skills in it is reason enough, even with nothing declared.
  local from_world = spec.new()
  assert(skills.ensure(from_world, double.world { skills = { review = "…" } }))
end

function T.the_briefing_reaches_the_core_as_an_option_and_not_as_a_dependency()
  -- Rule 1: the core depends on the declaration surface and on nothing else. The
  -- briefing is composed outside it and handed in as `opts.system`, which is the seam
  -- anything else composed at run time will use too.
  local turn = require "turn"
  local a = declared()
  spec.add_tool(a, "noop", { about = "does nothing", run = function () return "" end })
  a.system = "You keep this workspace."
  local system = skills.system(a, {})
  assert(system:match("^You keep this workspace") and system:match("triage %-%- how"), system)

  local w = double.world { model = { { stop = "done", text = "ok" } } }
  local r = turn.run(a, "go", w, { system = system })
  assert(r.transcript[1].text == system)
  assert(w.model.seen[1].system == system)

  -- And the option is checked like every other: a wrong shape is a caller bug.
  local ok, problems = turn.check(a, w, { system = 7 })
  assert(not ok)
  local named = false
  for i = 1, #problems do if problems[i]:match("opts.system is a string") then named = true end end
  assert(named, table.concat(problems, " | "))

  -- With nothing to say it answers nothing, so a caller passes it straight through.
  assert(skills.system(spec.new(), {}) == nil)
end

return T
