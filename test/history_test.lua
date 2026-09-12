-- history -- every run kept as a story and its evidence (docs/spec/history.md), over the
-- doubles and an in-memory history.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local agent   = require "agent"
local double  = require "double"
local history = require "history"
local gherkin = require "gherkin"

local T = {}

local NOON = 1789128000            -- 2026-09-11 12:00:00 UTC

-- A notebook agent with the files kit, and write asking first.
local function notebook()
  local a = agent.new()
  a.name "notebook"
  a.model "test:scripted"
  a.files { root = "" }
  a.tool "stamp" { about = "Stamp the page.", args = {}, run = function (c)
    return c.history and (c.history.write and "WRITER" or "reader") or "none"
  end }
  return a
end

local function world(o)
  o = o or {}
  local w = double.world { fs = o.fs or {}, model = o.model, ask = o.ask or { write = true },
                           clock = { at = o.at or NOON } }
  w.history = o.history or double.history(o.hp)
  return w
end

-- ------------------------------------------------------------------ the id

function T.the_id_says_where_and_when()
  local at = NOON + 3 * 3600 + 25 * 60 + 7                       -- 15:25:07 UTC
  local id = history.id({ worktree = "notes", git_branch = "main", offset = -7 * 3600 }, at, "notebook", "job")
  assert(id == "notes@main/2026-09-11/08-25-07-notebook-job", id)
  assert(history.id({ worktree = "notes", git_branch = "feature/voice" }, at, "notebook", "talk")
    == "notes@feature~voice/2026-09-11/15-25-07-notebook-talk")
  assert(history.id({ worktree = "my notes" }, at, "notebook", "cli") == "my-notes/2026-09-11/15-25-07-notebook-cli",
    history.id({ worktree = "my notes" }, at, "notebook", "cli"))
  local c = history.civil(951782400, 0)                          -- 2000-02-29
  assert(c.year == 2000 and c.month == 2 and c.day == 29)
end

function T.two_runs_in_one_second_get_two_ids()
  local hp = double.history()
  local where = hp.where()
  local a = history.claim(hp, where, NOON, "notebook", "job")
  local b = history.claim(hp, where, NOON, "notebook", "job")
  assert(a ~= b and b == a .. "-2", b)
end

-- ------------------------------------------------------------------ the tap

function T.the_tap_passes_everything_through_and_remembers_it()
  local w = double.world { fs = { ["a.md"] = "one\n" }, sh = { ["echo hi"] = { code = 0, out = "hi\n" } },
                           model = { "hello" }, ask = { write = false } }
  local t, log = history.tap(w)
  assert(t.fs.read("a.md") == "one\n")
  local none, err = t.fs.read("missing.md")
  assert(none == nil and err ~= nil, "an error comes through as it was")
  assert(t.fs.write("a.md", "two\n"))
  assert(t.fs.write("b.md", "new\n"))
  local r = t.sh.run({ "echo", "hi" })
  assert(r.code == 0)
  local reply = t.model.call { model = "test:scripted", messages = {} }
  assert(reply.text == "hello")
  local d = t.ask.request { tool = "write", args = { path = "a.md" } }
  assert(d.allow == false)
  assert(w.fs.files["a.md"] == "two\n", "the write reached the world")
  assert(log.files["a.md"].first == "one\n" and log.files["a.md"].before == "one\n" and log.files["a.md"].after == "two\n")
  assert(log.files["b.md"].before == nil and log.files["b.md"].after == "new\n")
  assert(log.commands[1].argv[1] == "echo" and log.commands[1].out == "hi\n")
  assert(log.model[1].text == "hello")
  assert(log.asks[1].tool == "write" and log.asks[1].allow == false)
end

function T.the_tap_lets_a_model_call_yield()
  local w = { model = { call = function () return coroutine.yield("waiting") end } }
  local t = history.tap(w)
  local co = coroutine.create(function () return t.model.call { model = "x", messages = {} } end)
  local _, got = coroutine.resume(co)
  assert(got == "waiting")
  local _, reply = coroutine.resume(co, { text = "done" })
  assert(reply.text == "done")
end

-- ------------------------------------------------------------------ keeping a run

local function kept_run(o)
  o = o or {}
  local a = notebook()
  local w = world {
    fs = o.fs or { ["notes/budget.md"] = "The venue is 1200.\n" },
    model = o.model or {
      { tool = "read", args = { path = "notes/budget.md" } },
      { tool = "write", args = { path = "notes/todo.md", text = "call the venue\n" } },
      { text = "Noted, in notes/todo.md." },
    },
    hp = o.hp, history = o.history,
  }
  local result = a.run(o.prompt or "note that I must call the venue", w)
  return a, w, result
end

function T.a_run_is_kept_with_its_evidence()
  local _, w, result = kept_run()
  assert(result.stop == "answered", result.reason)
  local id = result.entry
  assert(id and id:match("^work@main/2026%-09%-11/12%-00%-00%-notebook%-run$"), tostring(id))
  local h = history.open(w.history)
  assert(#h.rows == 1 and h.rows[1].id == id)
  local calls = assert(history.evidence(h, id, "calls"))
  assert(calls:find("1. read", 1, true) and calls:find("2. write", 1, true), calls)
  local files = assert(history.evidence(h, id, "files"))
  assert(files:find("notes/budget.md: read 1 time", 1, true) and files:find("notes/todo.md: created", 1, true), files)
  local diff = assert(history.evidence(h, id, "diff", "notes/todo.md"))
  assert(diff:find("+call the venue", 1, true), diff)
  local transcript = assert(history.evidence(h, id, "transcript"))
  assert(transcript:find("user: note that I must call the venue", 1, true), transcript)
  local model = assert(history.evidence(h, id, "model"))
  assert(model:find("test:scripted", 1, true))
end

function T.the_story_parses_names_its_id_and_runs_again()
  local a, w, result = kept_run()
  local h = history.open(w.history)
  local story = assert(history.recall(h, result.entry))
  assert(story:find("@" .. result.entry, 1, true) and story:find("@run", 1, true), story)
  assert(story:find('When the agent is asked "note that I must call the venue"', 1, true), story)
  local day = w.history.read("stories/notebook/2026-09-11.feature")
  assert(day and day:find("Feature: notebook, 2026-09-11", 1, true), tostring(day))
  assert(gherkin.pickle(day), "the day's feature parses")
  local report = assert(a.verify("Feature: replay\n" .. story, { kept = function (n) return history.kept(h, n) end }))
  assert(report.passed == 1, report.scenarios[1] and report.scenarios[1].steps
    and (function () local o = {} for _, s in ipairs(report.scenarios[1].steps) do o[#o + 1] = s.outcome .. " " .. s.text .. " " .. tostring(s.why) end return table.concat(o, "\n") end)())
end

function T.a_long_file_is_kept_apart_and_the_story_still_runs()
  local long = {}
  for i = 1, 40 do long[i] = "line " .. i end
  local text = table.concat(long, "\n") .. "\n"
  local a, w, result = kept_run { fs = { ["notes/budget.md"] = text } }
  local h = history.open(w.history)
  local story = history.recall(h, result.entry)
  assert(story:find("contains the text kept as " .. result.entry .. "#1", 1, true), story)
  assert(not story:find("line 40", 1, true), "the long text is in the story")
  assert(history.kept(h, result.entry .. "#1") == text)
  local report = a.verify("Feature: replay\n" .. story, { kept = function (n) return history.kept(h, n) end })
  assert(report.passed == 1)
  local without = a.verify("Feature: replay\n" .. story)
  assert(without.failed == 1, "a kept text with no history to find it in fails the step")
end

function T.a_failed_write_is_a_note_and_the_run_is_unchanged()
  local _, _, result = kept_run { hp = { fail = true } }
  assert(result.stop == "answered")
  local found = false
  for _, n in ipairs(result.notes) do if n:find("the history could not be kept", 1, true) then found = true end end
  assert(found, table.concat(result.notes, " | "))
end

function T.a_tool_body_gets_a_view_that_reads_and_never_the_port()
  local a = notebook()
  local w = world { model = { { tool = "stamp", args = {} }, { text = "stamped" } } }
  local result = a.run("stamp it", w)
  assert(result.calls[1].output == "reader", tostring(result.calls[1].output))
  local unkept = a.run("stamp it", w, { entry = false })
  assert(unkept.entry == nil)
end

function T.a_world_with_no_history_keeps_nothing()
  local a = notebook()
  local w = double.world { model = { { text = "hi" } } }
  local result = a.run("hello", w)
  assert(result.entry == nil and result.stop == "answered")
end

-- ------------------------------------------------------------------ finding

-- Five runs across three days, two git branches and two files.
local function five()
  local hp = double.history()
  local a = notebook()
  local function one(at, git_branch, path, prompt)
    hp.where().git_branch = git_branch
    local w = world { history = hp, at = at, fs = { [path] = "x\n" },
                      model = { { tool = "read", args = { path = path } }, { text = "read it" } } }
    return a.run(prompt, w).entry
  end
  local ids = {
    one(NOON - 30 * 86400, "main", "notes/a.md", "a month ago"),
    one(NOON - 86400, "main", "notes/todo.md", "yesterday, todo, main"),
    one(NOON - 86400 + 60, "voice", "notes/todo.md", "yesterday, todo, voice"),
    one(NOON, "main", "notes/a.md", "today, a, main"),
    one(NOON + 60, "voice", "notes/a.md", "today, a, voice"),
  }
  return hp, ids
end

function T.find_ranks_by_circumstance_and_says_what_matched()
  local hp, ids = five()
  local h = history.open(hp)
  local got = assert(history.find(h, { git_branch = "main", file = "notes/todo.md" }))
  assert(got[1].id == ids[2], history.line(got[1]))
  local m = table.concat(got[1].matched, ",")
  assert(m:find("git_branch") and m:find("file"), m)
  local voice = assert(history.find(h, { git_branch = "voice" }))
  assert((voice[1].id == ids[3] or voice[1].id == ids[5]) and (voice[2].id == ids[3] or voice[2].id == ids[5]))
end

function T.a_day_with_no_runs_still_ranks_the_day_before_above_a_month_before()
  local hp, ids = five()
  local h = history.open(hp)
  local got = assert(history.find(h, { day = "2026-09-09", file = "notes/a.md", limit = 5 }))
  local rank = {}
  for i, r in ipairs(got) do rank[r.id] = i end
  -- a.md was read a month ago and today; two days before today is nearer than thirty
  assert(rank[ids[4]] < rank[ids[1]], history.line(got[1]) .. " / " .. history.line(got[2]))
end

function T.like_finds_the_runs_most_like_one()
  local hp, ids = five()
  local h = history.open(hp)
  local got = assert(history.find(h, { like = ids[2] }))
  assert(got[1].id == ids[3], "the run most like yesterday's todo on main is yesterday's todo on voice: " .. history.line(got[1]))
end

function T.a_part_of_an_id_finds_the_entry()
  local hp, ids = five()
  local h = history.open(hp)
  assert(history.resolve(h, ids[1]:sub(1, 30)) == ids[1])
  assert(not history.resolve(h, "work@"), "an ambiguous part names no entry")
  -- a model shortens an id from the front as often as from the back
  local inner = ids[1]:match("/(%d%d%d%d%-%d%d%-%d%d/%d%d%-%d%d%-%d%d)")
  assert(history.resolve(h, inner) == ids[1], inner)
  assert(history.resolve(h, ids[2]:match("/(%d.*)$")) == ids[2])
  local both, why2 = history.resolve(h, ids[2]:match("/([^/]+)$"))       -- yesterday's noon and today's
  assert(both == nil and why2:find("more than one", 1, true), tostring(why2))
  local none, why = history.resolve(h, "2031-01-01")
  assert(none == nil and why:find("no entry", 1, true))
end

function T.an_exact_question_puts_the_matches_first_and_the_newest_first_among_them()
  local hp, ids = five()
  local h = history.open(hp)
  local got = assert(history.find(h, { git_branch = "main" }))
  assert(got[1].id == ids[4] and got[2].id == ids[2] and got[3].id == ids[1],
    got[1].id .. " / " .. got[2].id .. " / " .. got[3].id)
  local folder = assert(history.find(h, { file = "notes/" }))
  for i = 1, 5 do assert(folder[i].matched[1] == "file", "a folder matches the files under it") end
  assert(folder[1].id == ids[5])
end

function T.the_index_is_rebuilt_when_it_disagrees_with_the_runs()
  local hp, ids = five()
  hp.files.index = nil
  local h = history.open(hp)
  assert(#h.rows == 5 and h.by_id[ids[5]])
end

-- ------------------------------------------------------------------ looking back

local function output_of(result, tool)
  for _, c in ipairs(result.calls) do if c.tool == tool then return tostring(c.output) end end
  return "(no call to " .. tool .. ")"
end

function T.the_three_tools_answer_from_a_kept_history()
  local hp = double.history()
  local first = select(3, kept_run { history = hp })
  local w = world { history = hp, at = NOON + 600, fs = {}, model = {
    { tool = "history", args = { file = "notes/todo.md" } },
    { tool = "recall", args = { id = first.entry:sub(1, 28) } },
    { tool = "evidence", args = { id = first.entry, part = "diff", which = "notes/todo.md" } },
    { tool = "evidence", args = { id = first.entry, part = "nonsense" } },
    { text = "looked" },
  } }
  local a = notebook()
  a.history()
  local result = a.run("what did I note?", w)
  assert(result.stop == "answered", result.reason)
  local found = output_of(result, "history")
  assert(found:find(first.entry, 1, true) and found:find("matched file", 1, true), found)
  assert(found:match("^It is now 2026%-09%-11, 12:10%.\n"), "the listing says what day it is: " .. found)
  local story = output_of(result, "recall")
  assert(story:find("Scenario:", 1, true) and story:find("@" .. first.entry, 1, true), story)
  local diff = output_of(result, "evidence")
  assert(diff:find("--- notes/todo.md", 1, true) and diff:find("+call the venue", 1, true), diff)
  assert(result.calls[4].output:find("no part called nonsense", 1, true), result.calls[4].output)
  assert(#history.open(hp).rows == 2, "reading kept nothing but the run that read")
end

function T.a_reading_tool_pages_a_long_answer()
  local long = {}
  for i = 1, 1000 do long[i] = "line " .. i end
  local hp = double.history()
  local first = select(3, kept_run { history = hp, fs = { ["notes/budget.md"] = table.concat(long, "\n") } })
  local w = world { history = hp, at = NOON + 600, fs = {}, model = {
    { tool = "evidence", args = { id = first.entry, part = "kept", which = "1" } },
    { tool = "evidence", args = { id = first.entry, part = "kept", which = "1", from = history.CUT + 1 } },
    { text = "read" },
  } }
  local a = notebook()
  a.history()
  local result = a.run("read the budget back", w)
  local one, two = result.calls[1].output, result.calls[2].output
  assert(one:find("ask again with from = " .. (history.CUT + 1), 1, true), one:sub(-120))
  assert(not one:find("line 1000", 1, true) and two:find("line 1000", 1, true))
end

function T.the_tools_say_when_the_world_keeps_no_history()
  local a = notebook()
  a.history()
  local result = a.run("look back", double.world { model = { { tool = "history", args = {} }, { text = "none" } } })
  assert(result.calls[1].output == "this world keeps no history", result.calls[1].output)
end

function T.the_is_line_gives_the_three_tools()
  local a = agent.new()
  a.declare [[
Feature: looker
  Background:
    Given the agent is called looker
    And its model is "test:scripted"
    And it can read its history
]]
  local names = a.spec().tools
  assert(names.history and names.recall and names.evidence, "the is line declared the three tools")
end

function T.the_files_kit_never_reaches_where_runs_are_kept()
  local hp = double.history()
  kept_run { history = hp }
  local fs = { ["notes/a.md"] = "venue\n", [".malleable/history/index"] = "venue secret\n" }
  local w = world { history = hp, fs = fs, model = {
    { tool = "read", args = { path = ".malleable/history/index" } },
    { tool = "write", args = { path = ".malleable/history/index", text = "" } },
    { tool = "list", args = { path = "" } },
    { tool = "glob", args = { pattern = "**" } },
    { tool = "search", args = { pattern = "venue" } },
    { tool = "list", args = { path = ".malleable" } },
    { text = "done" },
  } }
  local result = notebook().run("look everywhere", w)
  for i = 1, 6 do
    assert(not tostring(result.calls[i].output):find("secret", 1, true), i .. ": " .. tostring(result.calls[i].output))
  end
  assert(tostring(result.calls[1].output):find("where runs are kept", 1, true), tostring(result.calls[1].output))
  assert(tostring(result.calls[2].output):find("where runs are kept", 1, true), tostring(result.calls[2].output))
  assert(not tostring(result.calls[3].output):find(".malleable", 1, true), tostring(result.calls[3].output))
  assert(not tostring(result.calls[4].output):find(".malleable", 1, true), tostring(result.calls[4].output))
  assert(tostring(result.calls[5].output):find("notes/a.md", 1, true), tostring(result.calls[5].output))
  assert(w.fs.files[".malleable/history/index"] == "venue secret\n", "the write did not reach it")
end

-- ------------------------------------------------------------------ a conversation

function T.a_conversation_keeps_its_reply_and_the_job_it_started_naming_the_reply()
  local speech = require "speech"
  local hp = double.history()
  local clock = { now = function () return NOON end, mono = function () return 0 end }
  local talk = double.model { replies = {
    { text = "Let me look.", calls = { { tool = "hand_off", args = { task = "read notes/a.md" } } } },
    "It says venue.",
  } }
  local work = double.model { replies = { { tool = "read", args = { path = "notes/a.md" } }, "venue" } }
  local c = speech.new {
    world = { model = talk, clock = clock, history = hp },
    job_world = { model = work, fs = double.fs { ["notes/a.md"] = "venue\n" }, clock = clock, history = hp },
    workers = notebook().spec(),
  }
  local events = {}
  c.on = function (event, data) if event == "job" then events[#events + 1] = data end end
  c:heard("what is in my note?")
  for _ = 1, 100 do
    c:update()
    local s = c:take()
    while s do c:said(s); s = c:take() end
    if #c.job_list > 0 and c.job_list[1].state == "done" and not c:busy() then break end
  end
  local h = history.open(hp)
  local by = {}
  for _, r in ipairs(h.rows) do by[r.cause] = by[r.cause] or {}; table.insert(by[r.cause], r) end
  assert(by.talk and #by.talk == 1, "the reply is kept as talk")
  assert(by.job and #by.job == 1, "the job is kept")
  local job = by.job[1]
  assert(job.parent == by.talk[1].id, tostring(job.parent))
  local reply = h.by_id[job.parent] and h.rows[h.by_id[job.parent]]
  assert(reply.prompt:find("what is in my note", 1, true), "the job names the reply the person asked for")
  assert(c:jobs()[1].entry == job.id and c:jobs()[1].parent == job.parent)
  local story = history.recall(h, job.id)
  assert(story:find("@from-" .. job.parent, 1, true), story)
  local found = assert(history.find(h, { parent = job.parent }))
  assert(found[1].id == job.id)
  assert(c.talker.tools.history and not c.talker.tools.recall, "the talker has the listing, and only that")
  local plain = speech.new { world = { model = talk }, workers = notebook().spec() }
  assert(plain.talker.tools.history == nil, "a world with no history gives the talker no listing")
end

-- ------------------------------------------------------------------ the command line

local NOTEBOOK = [[
Feature: notebook
  Background:
    Given the agent is called notebook
    And its model is "test:scripted"
    And it reads and writes the workspace
]]

-- A host for cli.main whose ports are the doubles, sharing one history.
local function host(hp, replies)
  local w = { outs = {}, errs = {} }
  w.out = function (t) w.outs[#w.outs + 1] = t end
  w.err = function (t) w.errs[#w.errs + 1] = t end
  w.read = function (path)
    if path == "notebook.feature" then return NOTEBOOK end
    return nil, "missing"
  end
  w.ports = function (cfg)
    if cfg.only == "history" then return { history = hp } end
    local p = double.world { fs = { ["notes/a.md"] = "venue\n" }, model = replies, clock = { at = NOON } }
    p.history = hp
    return p
  end
  return w
end

function T.a_command_line_run_is_kept_as_cli_and_read_back_by_the_three_flags()
  local cli = require "cli"
  local hp = double.history()
  local run = host(hp, { { tool = "write", args = { path = "notes/a.md", text = "venue, 1200\n" } }, { text = "noted" } })
  assert(cli.main({ "--yes", "notebook.feature", "note", "the", "price" }, run) == 0, table.concat(run.errs))
  local said = table.concat(run.outs)
  local id = said:match("kept as (%S+)")
  assert(id and id:match("%-notebook%-cli$"), said)
  assert(history.open(hp).rows[1].cause == "cli")

  local found = host(hp)
  assert(cli.main({ "--history", "--file", "notes/a.md" }, found) == 0, table.concat(found.errs))
  assert(table.concat(found.outs):find(id .. "  cli, answered", 1, true), table.concat(found.outs))

  local story = host(hp)
  assert(cli.main({ "--recall", id:sub(1, 25) }, story) == 0, table.concat(story.errs))
  assert(table.concat(story.outs):find("@" .. id, 1, true))
  assert(table.concat(story.outs):find("Feature: notebook", 1, true) == nil, "the story is one scenario")

  local diff = host(hp)
  assert(cli.main({ "--evidence", id, "diff", "notes/a.md" }, diff) == 0, table.concat(diff.errs))
  assert(table.concat(diff.outs):find("-venue\n+venue, 1200\n", 1, true), table.concat(diff.outs))

  local wrong = host(hp)
  assert(cli.main({ "--evidence", id, "nonsense" }, wrong) ~= 0)
  assert(table.concat(wrong.errs):find("no part called nonsense", 1, true), table.concat(wrong.errs))
  assert(#history.open(hp).rows == 1, "reading kept nothing")
end

function T.the_history_flags_say_what_they_will_not_take()
  local cli = require "cli"
  local function says(argv, needle)
    local _, why = cli.parse(argv)
    assert(why and why:find(needle, 1, true), tostring(why))
  end
  says({ "--day", "2026-09-11", "a.feature" }, "--day narrows --history")
  says({ "--history", "--recall", "x" }, "ask one")
  says({ "--history", "a.feature" }, "take no file")
  says({ "--evidence", "x", "diff", "a", "b" }, "at most one more word")
end

function T.the_file_reaches_nothing()
  local f = assert(io.open(here .. "/../src/history.lua", "rb"))
  local code = f:read("*a"):gsub("%-%-[^\n]*", "")
  f:close()
  for _, word in ipairs { "io", "os" } do
    assert(not code:find("%f[%w_]" .. word .. "%f[^%w_]"), "history.lua names " .. word)
  end
  assert(not code:find("math.random", 1, true))
end

return T
