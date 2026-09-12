-- spec/declare.md: an agent written in Gherkin, the shorthands it adds to the vocabulary,
-- and the edits it may make to itself.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local agent   = require "agent"
local declare = require "declare"
local spec    = require "spec"
local cli     = require "cli"

local T = {}

local function load(text, opts)
  local a = spec.new()
  local info, why = declare.apply(text, a, opts)
  return info and a or nil, why, info
end

local function refused(text, needle)
  local a, why = load(text)
  assert(a == nil, "expected a refusal containing " .. needle)
  assert(tostring(why):find(needle, 1, true), "the refusal was: " .. tostring(why))
  return why
end

local function contains(s, needle) return tostring(s):find(needle, 1, true) ~= nil end

local function feature(background, rest)
  return "Feature: t\n\n  Background:\n" .. background .. "\n" .. (rest or "")
end

local ONE = [[
    Given the agent is called one
    And its model is "test:model"
    And it has a tool say for "Say it."
    And the tool say answers "said"
]]

-- ------------------------------------------------------------------ the is lines

function T.each_is_line_declares_what_it_says()
  local a = assert(load([[
Feature: all
  Background:
    Given the agent is called all
    And its model is "test:model"
    And its reasoning is low
    And it may take 9 steps
    And it is briefed:
      """
      Be brief.
      """
    And its trust is ask
    And it reads and writes the workspace
    And it never touches "**/*.key"
    And it runs commands
    And each command may run 30 seconds
    And it keeps a plan
    And it keeps a store notes of "one note a row":
      | column | type                     | about        |
      | text   | string                   | the note     |
      | tag    | optional one of red, blue | a colour     |
    And the store notes is sorted by text
    And it has a tool note for "Keep a note.", which takes:
      | argument | type             | about        |
      | text     | string           | the note     |
      | tag      | optional one of red, blue | a colour |
    And the tool note adds a row to notes
    And the tool note asks first, letting the person change tag
    And the tool note shows its call before it runs
    And the tool note may be called at most 3 times
    And it has a tool notes for "Every note."
    And the tool notes lists notes
    And the tool shell is for "Run one command."
    And the tool read requires "a path under src", checked by:
      """lua
      return c.args.path:sub(1, 4) == "src/", "only src"
      """
    And it keeps a skill tidy for "How to tidy.":
      """
      Tidy it.
      """
    And it keeps a skill ship for "How to ship.", in "docs/ship.md"
    And the beat nightly comes every day at "18:00" and asks "summarise the day"
    And the beat nightly runs once per day
    And the beat pulse comes every 60 seconds and asks "anything new?"
    And the step "the queue holds {int} tickets" sets up:
      """lua
      c.world.queue = c.args[1]
      """
    And it may always call read
    And it may never call write
]]))
  assert(a.name == "all" and a.model == "test:model" and a.reasoning == "low" and a.budget == 9)
  assert(a.system == "Be brief." and a.trust == "ask")
  for _, t in ipairs { "read", "write", "edit", "list", "glob", "search", "shell", "plan", "mark", "note", "notes" } do
    assert(a.tools[t], "no tool " .. t)
  end
  assert(a.tools.shell.about == "Run one command.")
  assert(a.tools.note.ask == true and a.tools.note.edit[1] == "tag" and a.tools.note.preview == true)
  assert(a.tools.note.args.tag.choices[2] == "blue" and a.tools.note.args.tag.required == false)
  assert(a.tools.read.requires and a.tools.read.requires[#a.tools.read.requires].says == "a path under src")
  assert(a.stores.notes.sort[1] == "text" and a.stores.notes.columns.tag.choices)
  assert(a.skills.tidy.does == "Tidy it." and a.skills.ship.file == "docs/ship.md")
  assert(a.beats.nightly.day_at == "18:00" and a.beats.nightly.once_per == "day" and a.beats.pulse.every == 60)
  assert(a.steps["the queue holds {int} tickets"].phase == "given")
  assert(a.policy[1].tool == "read" and a.policy[1].allow and a.policy[2].tool == "write" and a.policy[2].deny)
  assert(a.hooks.call and a.hooks.start, "the call limit is a hook")
end

-- The reviewer of example/reviewer.lua, said in Gherkin: the same declaration.
local REVIEWER = [[
Feature: reviewer

  Background:
    Given the agent is called reviewer
    And its model is "openrouter:z-ai/glm-5.3"
    And it may take 12 steps
    And it is briefed:
      """
      You review a change in a Lua workspace.
      """
    And it reads the workspace
    And it never touches ".git/**"
    And it never touches "**/*.key"
    And it runs commands
    And each command may run 60 seconds
    And the tool shell is for "Run one command in the workspace."
    And it has a tool verdict for "File the review. Call this once.", which takes:
      | argument | type             | about                                            |
      | summary  | string           | the review, in one paragraph                     |
      | block    | optional boolean | true to hold the change, false to let it through |
    And the tool verdict asks first
    And the tool verdict does:
      """lua
      local held = c.args.block == true
      local ok, why = c.fs.write("REVIEW.md", (held and "BLOCKED" or "APPROVED") .. "\n\n" .. c.args.summary .. "\n")
      if not ok then return nil, why end
      return "filed: " .. (held and "blocked" or "approved")
      """
]]

local function same(x, y, path)
  if type(x) ~= type(y) then error(path .. ": " .. type(x) .. " against " .. type(y), 0) end
  if type(x) ~= "table" then
    if x ~= y then error(path .. ": " .. tostring(x) .. " against " .. tostring(y), 0) end
    return
  end
  for k, v in pairs(x) do same(v, y[k], path .. "." .. tostring(k)) end
  for k in pairs(y) do if x[k] == nil then error(path .. "." .. tostring(k) .. " only on one side", 0) end end
end

function T.a_feature_and_the_lua_it_replaces_compile_to_the_same_declaration()
  local lua = agent.new()
  lua.name "reviewer"
  lua.model "openrouter:z-ai/glm-5.3"
  lua.budget(12)
  lua.system "You review a change in a Lua workspace."
  lua.files { root = "", read_only = true, deny = { ".git/**", "**/*.key" } }
  lua.shell { root = ".", about = "Run one command in the workspace.", timeout_ms = 60000 }
  lua.tool "verdict" {
    about = "File the review. Call this once.",
    ask = true,
    args = { summary = lua.string "the review, in one paragraph",
             block = lua.boolean_opt "true to hold the change, false to let it through" },
    run = function (c)
      local held = c.args.block == true
      local ok, why = c.fs.write("REVIEW.md", (held and "BLOCKED" or "APPROVED") .. "\n\n" .. c.args.summary .. "\n")
      if not ok then return nil, why end
      return "filed: " .. (held and "blocked" or "approved")
    end,
  }
  local g = assert(load(REVIEWER))
  local l = lua.spec()
  for _, k in ipairs { "name", "model", "budget", "system" } do same(l[k], g[k], k) end
  same(l.order, g.order, "order")
  same(spec.schema(l), spec.schema(g), "schema")
  -- the bodies, compared by what they answer and what they write
  local function call(d, args)
    local w = agent.world {}
    return d.tools.verdict.run({ args = args, fs = w.fs, note = function () end }), w.fs.files["REVIEW.md"]
  end
  local a1, f1 = call(l, { summary = "fine", block = true })
  local a2, f2 = call(g, { summary = "fine", block = true })
  assert(a1 == a2 and f1 == f2, tostring(a2) .. " / " .. tostring(f2))
  -- and the files tools refuse the same paths
  local w = agent.world { fs = { ["a.key"] = "secret", ["src/x.lua"] = "x" } }
  local r1 = l.tools.read.run({ args = { path = "a.key" }, fs = w.fs })
  local r2 = g.tools.read.run({ args = { path = "a.key" }, fs = w.fs })
  assert(r1 == r2, tostring(r1) .. " / " .. tostring(r2))
end

function T.every_entry_point_of_the_surface_is_said_or_listed_unsaid()
  local covered = {}
  for _, v in ipairs(declare.vocabulary()) do covered[v.covers] = true end
  local a = spec.new()
  local missing = {}
  local keys = {}
  for k in pairs(cli.surface(a)) do keys[#keys + 1] = k end
  for _, k in ipairs { "files", "shell", "plan", "delegate" } do keys[#keys + 1] = k end
  for _, k in ipairs(keys) do
    -- the argument types are said by an argument table's type column
    if not spec.types[k] and not covered[k] and not declare.UNSAID[k] then missing[#missing + 1] = k end
  end
  table.sort(missing)
  assert(#missing == 0, "no is line says, and UNSAID does not list: " .. table.concat(missing, ", "))
end

function T.an_is_line_anywhere_but_the_background_is_refused()
  refused(feature(ONE, "  Scenario: s\n    Given it runs commands\n    When the agent is asked \"x\"\n"),
          "said once, in the feature's Background")
end

function T.an_is_line_after_a_given_line_is_refused()
  refused(feature('    Given the file "a" is missing\n' .. ONE), "comes before the Background's other lines")
end

function T.a_background_line_that_matches_nothing_is_refused_with_its_line()
  local why = refused(feature(ONE .. "    And it hands work to greeting, the agent in \"g.feature\"\n"),
                      "matches no line of the vocabulary")
  assert(contains(why, "line 8"), why)
end

function T.a_tool_with_no_body_is_refused()
  refused(feature('    Given the agent is called x\n    And it has a tool t for "T."\n'), "has no body")
end

function T.a_body_that_does_not_compile_is_refused_with_its_line()
  local why = refused(feature(ONE:gsub('    And the tool say answers "said"\n', "")
    .. '    And the tool say does:\n      """lua\n      return (\n      """\n'), "does not compile")
  assert(contains(why, "line 7"), why)
end

function T.a_body_reaches_nothing_but_c_and_says_so_by_name()
  local a = assert(load(feature(ONE:gsub('    And the tool say answers "said"\n', "")
    .. '    And the tool say does:\n      """lua\n      return io.open("/etc/passwd")\n      """\n')))
  local ok, err = pcall(a.tools.say.run, { args = {} })
  assert(not ok and contains(err, "io is not here"), tostring(err))
  local b = assert(load(feature(ONE:gsub('    And the tool say answers "said"\n', "")
    .. '    And the tool say does:\n      """lua\n      kept = 1\n      """\n')))
  local ok2, err2 = pcall(b.tools.say.run, { args = {} })
  assert(not ok2 and contains(err2, "keeps no globals"), tostring(err2))
end

function T.loading_a_feature_runs_no_body()
  local a = assert(load(feature(ONE:gsub('    And the tool say answers "said"\n', "")
    .. '    And the tool say does:\n      """lua\n      error("a body ran at load")\n      """\n'
    .. '    And the tool say requires "never", checked by:\n      """lua\n      error("a check ran at load")\n      """\n')))
  assert(a.tools.say, "the tool is declared")
end

function T.a_delegate_reads_the_other_file_and_refuses_one_that_hands_work_to_itself()
  local files = {
    ["g.feature"] = feature(ONE),
    ["loop.feature"] = feature('    Given the agent is called loop\n    And it hands work to the agent in "loop.feature" as again\n'),
  }
  local read = function (p) return files[p] end
  local a = assert(load(feature('    Given the agent is called desk\n    And it hands work to the agent in "g.feature" as helper\n'),
                   { read = read }))
  assert(a.tools.helper and a.tools.helper.ask == true, "a delegate asks, as subagent.tool does")
  local _, why = load(files["loop.feature"], { read = read })
  assert(contains(why, "hands work to itself"), tostring(why))
end

-- ------------------------------------------------------------------ shorthands

local SH = feature(ONE, [[
  @shorthand
  Scenario: it said <what> as "<text>"
    Then the call to <what> answers "<text>"

  @shorthand
  Scenario: it spoke
    Then it said say as "said"
    And it stops with answered

  Scenario: uses both
    Given the model calls say with {}
    And the model answers "ok"
    When the agent is asked "speak"
    Then it spoke
]])

function T.a_shorthand_expands_where_it_is_used_and_nests()
  local a = assert(load(SH))
  local pickles, list = assert(declare.pickles(SH, a))
  assert(#pickles == 1 and #list == 2, "the shorthands are not scenarios")
  local texts = {}
  for _, s in ipairs(pickles[1].steps) do texts[#texts + 1] = s.text end
  local joined = table.concat(texts, " | ")
  assert(contains(joined, 'the call to say answers "said"') and contains(joined, "it stops with answered"), joined)
  assert(not contains(joined, "the agent is called"), "the is lines are taken out: " .. joined)
  local p = agent.new()
  p.declare(SH)
  local report = assert(p.verify(SH))
  assert(report.passed == 1 and report.ok, agent.behaviour.report(report))
end

function T.a_shorthand_that_reaches_itself_is_refused()
  local text = feature(ONE, "  @shorthand\n  Scenario: round\n    Then about\n\n  @shorthand\n  Scenario: about\n    Then round\n")
  local _, why = declare.pickles(text, assert(load(feature(ONE))))
  assert(contains(why, "reaches itself"), tostring(why))
end

function T.a_shorthand_of_when_lines_is_refused()
  local text = feature(ONE, "  @shorthand\n  Scenario: go\n    When the agent is asked \"x\"\n")
  local _, why = declare.pickles(text, assert(load(feature(ONE))))
  assert(contains(why, "the three ways a run starts"), tostring(why))
end

function T.a_shorthand_that_reads_a_built_in_line_is_refused()
  local text = feature(ONE, "  @shorthand\n  Scenario: it calls <tool>\n    Then it never calls say\n")
  local _, why = declare.pickles(text, assert(load(feature(ONE))))
  assert(contains(why, "same lines as the built-in"), tostring(why))
end

-- ------------------------------------------------------------------ edits and reach

local BASE = [[
Feature: t

  Background:
    Given the agent is called one
    And its model is "test:model"
    And it may take 4 steps
    And it has a tool say for "Say it."
    And the tool say answers "said"
    And the tool say asks first

  # a comment the edit must keep
  Scenario: authored
    Given the human approves say
    And the model calls say with {}
    And the model answers "ok"
    When the agent is asked "x"
    Then it stops with answered

  @proposed
  Scenario: mine
    Given the model answers "ok"
    When the agent is asked "y"
    Then it stops with answered
]]

local function edit(op)
  return declare.edit(BASE, op)
end

local function untouched(new, keep)
  for _, line in ipairs(keep) do assert(contains(new, line), "lost: " .. line) end
end

function T.each_edit_keeps_every_line_it_was_not_asked_to_touch()
  local keep = { "  # a comment the edit must keep", "  Scenario: authored", '    And the model calls say with {}' }
  local new, c = assert(edit { add = "it keeps a plan" })
  untouched(new, keep); assert(c.reach == "widens")
  assert(contains(new, '    And the tool say asks first\n    And it keeps a plan\n'), new)
  new, c = assert(edit { replace = "it may take 4 steps", with = "it may take 6 steps" })
  untouched(new, keep); assert(c.reach == "neither" and contains(new, "it may take 6 steps"))
  new, c = assert(edit { remove = "it may take 4 steps" })
  untouched(new, keep); assert(not contains(new, "4 steps") and c.reach == "neither")
  new, c = assert(edit { scenario = "Scenario: more\n  Given the model answers \"z\"\n  When the agent is asked \"z\"\n  Then it stops with answered" })
  untouched(new, keep); assert(contains(new, "  @proposed\n  Scenario: more"), new)
  new, c = assert(edit { withdraw = "mine" })
  untouched(new, keep); assert(not contains(new, "Scenario: mine"), new)
  -- and nothing else moved: the two texts differ only where the edit was
  local back = assert(declare.edit(assert(edit { add = "it keeps a plan" }), { remove = "it keeps a plan" }))
  assert(back == BASE, "an add and its remove do not give the file back")
end

-- Found by evals/author.feature: the author wrote the tag itself, added the line it meant
-- to replace (a duplicate), and sent `with` to an add, which was ignored.
function T.an_edit_takes_a_written_tag_and_refuses_a_duplicate_line()
  local new = assert(edit { scenario = "@proposed\nScenario: more\n  Given the model answers \"z\"\n  When the agent is asked \"z\"\n  Then it stops with answered" })
  assert(contains(new, "  @proposed\n  Scenario: more") and not contains(new, "@proposed\n  @proposed"), new)
  new = assert(edit { scenario = "@proposed Scenario: more\n  Given the model answers \"z\"\n  When the agent is asked \"z\"\n  Then it stops with answered" })
  assert(contains(new, "  @proposed\n  Scenario: more"), new)
  local _, why = edit { add = "it may take 4 steps" }
  assert(why and contains(why, "already says"), tostring(why))
end

function T.reach_follows_the_lines()
  local _, c = assert(edit { add = "it runs commands" }); assert(c.reach == "widens")
  _, c = assert(edit { add = "it may never call say" }); assert(c.reach == "narrows")
  _, c = assert(edit { replace = 'it has a tool say for "Say it."', with = 'it has a tool say for "Say it aloud."' })
  assert(c.reach == "neither", "a tool's `for` changes nothing it can reach: " .. c.reach)
  _, c = assert(edit { replace = 'its model is "test:model"', with = 'its model is "other:model"' })
  assert(c.reach == "widens")
  _, c = assert(edit { replace = 'the tool say answers "said"', with = 'the tool say answers "spoken"' })
  assert(c.reach == "neither")
end

function T.removing_a_tool_takes_its_lines_with_it_and_narrows()
  local new, c = assert(edit { remove = 'it has a tool say for "Say it."' })
  assert(not contains(new, "the tool say"), new)
  assert(c.reach == "narrows" and contains(c.why, "2 line(s) about say"), c.why)
end

function T.a_gate_never_opens()
  local new, why, wall = edit { remove = "the tool say asks first" }
  assert(new == nil and wall == "wall" and contains(why, "never take one away"), tostring(why))
  new, why, wall = edit { replace = "the tool say asks first", with = "it keeps a plan" }
  assert(new == nil and wall == "wall", tostring(why))
end

function T.an_authored_scenario_is_the_persons()
  local new, why, wall = edit { withdraw = "authored" }
  assert(new == nil and wall == "wall" and contains(why, "is authored"), tostring(why))
end

function T.a_scenario_edit_cannot_slip_in_an_authored_scenario()
  local new, why = edit { scenario = "Scenario: one\n  When the agent is asked \"a\"\n  Then it stops with answered\n\n"
    .. "Scenario: two\n  When the agent is asked \"b\"\n  Then it stops with answered" }
  assert(new == nil and contains(why, "adds one scenario, and this adds 2"), tostring(why))
end

function T.nothing_an_agent_adds_may_give_an_authored_line_a_meaning()
  local text = BASE:gsub("    Then it stops with answered\n\n  @proposed", "    Then it stops with answered\n    And the report is filed\n\n  @proposed")
  local new, why, wall = declare.edit(text, { shorthand = "Scenario: the report is filed\n  Then it stops with answered" })
  assert(new == nil and wall == "wall" and contains(why, "the report is filed"), tostring(why))
  new, why, wall = declare.edit(text, { add = 'the step "the report is filed" checks:', doc = "return true" })
  assert(new == nil and wall == "wall", tostring(why))
  -- and a shorthand no authored line uses is the agent's to add
  assert(declare.edit(text, { shorthand = "Scenario: it is quiet\n  Then it never calls say" }))
end

function T.a_proposed_scenario_takes_a_name_of_its_own()
  local new, why = edit { scenario = "Scenario: authored\n  When the agent is asked \"a\"\n  Then it stops with answered" }
  assert(new == nil and contains(why, "already"), tostring(why))
end

function T.every_line_level_problem_comes_back_at_once()
  local _, why = load(feature('    Given the agent is called x\n    And it is briefed:\n    And it has a tool t for "T."\n    And the tool t does:\n'))
  assert(contains(why, "line 5: `it is briefed:` takes a doc string") and contains(why, "line 7: `the tool {word} does:`"), tostring(why))
end

function T.an_edit_that_is_not_an_is_line_is_refused_with_where_to_look()
  local new, why = edit { add = "it can fly" }
  assert(new == nil and contains(why, "vocabulary"), tostring(why))
end

-- ------------------------------------------------------------------ the authoring tools

function T.the_authoring_tools_take_what_a_model_sends_and_refuse_what_is_no_agent()
  local b = agent.new()
  b.declare(feature('    Given the agent is called b\n    And its model is "x:y"\n    And it edits agents in "agents"\n'))
  local bare = "Feature: notes\n  Background:\n    the agent is called notes\n    its model is \"x:y\"\n"
    .. "    it has a tool add for \"Add.\"\n    the tool add answers \"kept\"\n"
  local w = agent.world { ask = { propose = true }, model = {
    { tool = "propose", args = { path = "agents/notes.feature", op = "create", text = bare } },
    { tool = "propose", args = { path = "other.feature", op = "create", text = "Feature: other\n  Just prose.\n" } },
    { tool = "edit", args = { path = "notes.feature", op = "add", line = "  12  And the tool add asks first" } },
    { text = "done" } } }
  local r = b.run("go", w)
  assert(contains(r.calls[1].output, "applied: created"), r.calls[1].output)
  assert(contains(w.fs.files["agents/notes.feature"], "    Given the agent is called notes"), "the keyword was not put back")
  assert(contains(r.calls[2].output, "says what it is"), r.calls[2].output)
  assert(contains(r.calls[3].output, "applied: adds \"the tool add asks first\""), r.calls[3].output)
  -- an add given `with` is the wrong op, and is told so rather than adding the wrong line
  local w2 = agent.world { fs = { ["agents/notes.feature"] = w.fs.files["agents/notes.feature"] }, model = {
    { tool = "edit", args = { path = "notes.feature", op = "add", line = "the tool add asks first", with = "it may take 3 steps" } },
    { text = "done" } } }
  local r2 = b.run("go", w2)
  assert(contains(r2.calls[1].output, "the op is replace"), r2.calls[1].output)
  assert(not contains(w2.fs.files["agents/notes.feature"], "3 steps"))
end

-- Found by evals/author.feature: the folder joined with an empty path gave "agents/", which
-- the doubles' fs does not know as a directory, so `features` listed nothing on the doubles.
function T.the_features_tool_lists_the_folder_on_the_doubles()
  local b = agent.new()
  b.declare(feature('    Given the agent is called b\n    And its model is "x:y"\n    And it edits agents in "agents"\n'))
  local w = agent.world { fs = { ["agents/notes.feature"] = "Feature: notes\n", ["agents/deep/more.feature"] = "Feature: more\n" },
                          model = { { tool = "features", args = {} }, { text = "done" } } }
  local r = b.run("what agents are there?", w)
  assert(r.calls[1].output == "deep/more.feature\nnotes.feature", tostring(r.calls[1].output))
end

-- ------------------------------------------------------------------ the runner

local function run_cli(args)
  local out, err = {}, {}
  local code = cli.main(args, {
    out = function (t) out[#out + 1] = t end, err = function (t) err[#err + 1] = t end,
    read = function (path)
      local f = io.open(path, "rb")
      if not f then return nil, "missing" end
      local t = f:read("*a"); f:close(); return t
    end,
    env = function () return nil end, now = function () return 0 end,
  })
  return code, table.concat(out), table.concat(err)
end

function T.the_runner_verifies_each_example_written_in_gherkin()
  for _, name in ipairs { "counter", "greeter", "desk", "builder" } do
    local code, out, err = run_cli { "--verify", here .. "/../example/" .. name .. ".feature" }
    assert(code == 0, name .. ": " .. out .. err)
    assert(contains(out, " 0 failed, 0 undefined, 0 broken"), name .. ": " .. out)
  end
end


-- ------------------------------------------------------------------ always asks first (2026-09-12)

function T.always_asks_first_is_a_gate_the_agent_cannot_open()
  local text = BASE:gsub("And the tool say asks first", "And the tool say always asks first")
  local a = spec.new()
  local info, why = declare.apply(text, a, { read = function () return nil end })
  assert(info, tostring(why))
  assert(a.tools.say.ask == true and a.tools.say.always == true, "asks, and always")
  assert(spec.schema(a)[1].ask == "always", "the schema says always")
  local new, why2, wall = declare.edit(text, { remove = "the tool say always asks first" })
  assert(new == nil and wall == "wall", tostring(why2))
  new, why2, wall = declare.edit(text, { replace = "the tool say always asks first", with = "the tool say asks first" })
  assert(new == nil and wall == "wall", "widening a gate: " .. tostring(why2))
  new, why2 = declare.edit(BASE, { add = "the tool say always asks first" })
  assert(new and why2.reach == "narrows", "asks first may become always asks first: " .. tostring(why2 and why2.why or why2))
  -- the two lines are order-free
  local both = BASE:gsub("And the tool say asks first", "And the tool say always asks first\n    And the tool say asks first")
  a = spec.new()
  info, why = declare.apply(both, a, { read = function () return nil end })
  assert(info and a.tools.say.always == true, tostring(why))
  local twice = BASE:gsub("And the tool say asks first", "And the tool say always asks first\n    And the tool say always asks first")
  info, why = declare.apply(twice, spec.new(), { read = function () return nil end })
  assert(info == nil and contains(why, "already always asks first"), tostring(why))
end


-- ------------------------------------------------------------------ the wall, as features

function T.the_wall_features_verify_on_the_doubles()
  -- evals/wall.feature scripts every edit that tries to take an agent past what a person
  -- allowed; wall-trusted.feature the same under `its trust is trusted` (2026-09-12, the
  -- trusted attack run: propose approved itself). Both hold on the doubles.
  local root = here .. "/.."
  for _, name in ipairs { "wall", "wall-trusted" } do
    local w = { outs = {}, errs = {} }
    w.out = function (t) w.outs[#w.outs + 1] = t end
    w.err = function (t) w.errs[#w.errs + 1] = t end
    w.read = function (path)
      local f = io.open(path, "rb")
      if not f then return nil, "missing" end
      local t = f:read("a"); f:close(); return t
    end
    w.env = function () return nil end
    w.now = function () return 0 end
    local f = root .. "/evals/" .. name .. ".feature"
    local code = cli.main({ "--verify", "--feature", f, f }, w)
    local out = table.concat(w.outs) .. table.concat(w.errs)
    assert(code == 0 and out:find(" 0 failed", 1, true), name .. ":\n" .. out)
  end
end

return T
