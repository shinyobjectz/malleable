-- speech -- a talker in front, jobs behind (spec/speech.md), over scripted models that
-- yield `host` waits for a set number of polls: concurrency with no network and no clock.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local spec    = require "spec"
local turn    = require "turn"
local double  = require "double"
local declare = require "declare"
local speech  = require "speech"

local T = {}

-- ------------------------------------------------------------------- builders

-- A model that answers from a script, and makes whoever asked wait `polls` polls first.
-- `log` records the order things happened in, across every model in a test.
local function slow(replies, polls, log, name)
  local m = double.model { replies = replies }
  local out = { seen = m.seen, cancelled = 0 }
  out.call = function (request)
    local reply, err = m.call(request)
    if polls > 0 and coroutine.isyieldable() then
      local left = polls
      local got = coroutine.yield { wait = "host",
        poll = function () left = left - 1; if left <= 0 then return true, { reply, err } end; return false end,
        cancel = function () out.cancelled = out.cancelled + 1 end }
      reply, err = got[1], got[2]
    end
    if log then log[#log + 1] = name .. (reply and reply.text and reply.text ~= "" and (": " .. reply.text) or "") end
    return reply, err
  end
  return out
end

local function worker(name, tools)
  local a = spec.new()
  spec.set_name(a, name)
  spec.set_model(a, "test:worker")
  spec.set_system(a, "You look things up.")
  for _, t in ipairs(tools or {}) do spec.add_tool(a, t.name, t.tool) end
  if #a.order == 0 then
    spec.add_tool(a, "look", { about = "Look", args = {}, run = function () return "looked" end })
  end
  return a
end

local function hand(task, to) return { tool = "hand_off", args = { task = task, to = to } } end

-- A conversation over a talker script and one or more worker scripts.
local function conversation(o)
  local log = o.log or {}
  local talk = slow(o.talker, o.talker_polls or 1, log, "talker")
  local jobs_model = slow(o.worker or { "done" }, o.worker_polls or 1, log, "worker")
  local fs = double.fs(o.files or {})
  local cfg = {
    world = { model = talk },
    job_world = o.job_world or { model = jobs_model, fs = fs },
    workers = o.workers or worker("research"),
  }
  for k, v in pairs(o.cfg or {}) do cfg[k] = v end
  local c = speech.new(cfg)
  local events = {}
  c.on = function (event, data) events[#events + 1] = { event = event, data = data } end
  return c, { talk = talk, worker = jobs_model, log = log, events = events, fs = fs }
end

-- Drives the conversation: updates, and says every sentence it hands out. Stops when
-- `until_` answers true, or after `n` slices.
local function drive(c, n, until_)
  local said = {}
  for _ = 1, n or 200 do
    c:update()
    local s = c:take()
    while s do said[#said + 1] = s; c:said(s); s = c:take() end
    if until_ and until_() then break end
  end
  return said
end

local function idle(c) return function () return not c:busy() end end

local function count(events, name)
  local n = 0
  for _, e in ipairs(events) do if e.event == name then n = n + 1 end end
  return n
end

local function last_request(m) return m.seen[#m.seen] end

local function user_texts(request)
  local out = {}
  for _, msg in ipairs(request.messages) do if msg.role == "user" then out[#out + 1] = msg.text end end
  return out
end

-- ------------------------------------------------------------------- tests

function T.a_turn_is_answered_a_sentence_at_a_time()
  local c, w = conversation { talker = { "Hello there. How can I help?" } }
  c:heard("hi")
  assert(c:busy())
  local said = drive(c, 20, idle(c))
  assert(said[1] == "Hello there." and said[2] == "How can I help?", table.concat(said, "|"))
  assert(not c:busy())
  assert(count(w.events, "done") == 1)
  assert(#w.talk.seen == 1)
  assert(c.history[1].role == "user" and c.history[1].text == "hi")
  assert(c.history[2].role == "agent" and c.history[2].text == "Hello there. How can I help?")
end

function T.a_lead_in_is_heard_and_the_reply_makes_one_model_call()
  local c, w = conversation {
    talker = { { text = "Let me look into that.", calls = { hand("count the notes") } }, "You have three notes." },
    worker = { "There are 3 notes." },
  }
  c:heard("how many notes do I have?")
  local said = drive(c, 60, function () return #c.job_list > 0 and c.job_list[1].state == "done" and not c:busy() end)
  assert(said[1] == "Let me look into that.", said[1])
  -- the lead-in, then the report reply: the hand-off itself asked the model nothing more
  assert(said[2] == "You have three notes.", tostring(said[2]))
  assert(#w.talk.seen == 2, #w.talk.seen)
  local report = user_texts(last_request(w.talk))
  assert(report[#report]:find("j1, research, done in 1 steps: There are 3 notes.", 1, true), report[#report])
  assert(report[#report]:find("not the person's words", 1, true))
  -- the worker was told the task, and nothing of the conversation
  local told = w.worker.seen[1].messages
  assert(#told == 1 and told[1].text == "count the notes")
end

function T.a_job_runs_while_the_next_turn_is_answered()
  local c, w = conversation {
    talker = { { text = "On it.", calls = { hand("a long job") } }, "It is sunny." },
    worker = { "the long job is done" }, worker_polls = 40,
  }
  c:heard("do the long job")
  drive(c, 5, idle(c))
  assert(c.job_list[1].state == "running")
  c:heard("what's the weather?")
  local said = drive(c, 10, idle(c))
  assert(said[1] == "It is sunny.", tostring(said[1]))
  assert(c.job_list[1].state == "running", "the job is still at its model call")
  -- the talker's second reply came back before the worker's only reply
  local talker_at, worker_at
  for i, line in ipairs(w.log) do
    if line == "talker: It is sunny." then talker_at = i end
    if line:find("^worker") then worker_at = i end
  end
  assert(talker_at and (worker_at == nil or talker_at < worker_at))
end

function T.a_report_waits_for_the_floor_and_two_together_are_one_reply()
  local c, w = conversation {
    talker = { { text = "Both started.", calls = { hand("one"), hand("two") } }, "Here is what they found." },
    worker = { "first", "second" }, worker_polls = 3,
  }
  c:heard("do both")
  drive(c, 3, idle(c))
  c:hearing()                                  -- the person starts talking
  drive(c, 30)
  assert(c.job_list[1].state == "done" and c.job_list[2].state == "done")
  assert(count(w.events, "report") == 0, "nothing is spoken while the person speaks")
  c:heard("")                                  -- a noise: they stopped
  drive(c, 20, idle(c))
  assert(count(w.events, "report") == 1)
  local ids
  for _, e in ipairs(w.events) do if e.event == "report" then ids = e.data.ids end end
  assert(#ids == 2 and ids[1] == "j1" and ids[2] == "j2")
  assert(#w.talk.seen == 2)
end

function T.turn_based_reports_ride_along_with_the_next_turn()
  local c, w = conversation {
    talker = { { text = "Started.", calls = { hand("look") } }, "Thanks. Also, it found the file.", "Nothing else." },
    worker = { "found the file" }, cfg = { proactive = false },
  }
  c:heard("find it")
  drive(c, 30, function () return c.job_list[1] and c.job_list[1].state == "done" and not c:busy() end)
  assert(#c.reports == 1 and count(w.events, "report") == 0, "a report waits for a turn")
  c:heard("thanks")
  drive(c, 20, idle(c))
  local users = user_texts(last_request(w.talk))
  local prompt = users[#users]
  assert(prompt:find("found the file", 1, true) and prompt:find("thanks$"), prompt)
  assert(#c.reports == 0)
  -- deliver: nothing waits now, so nothing starts
  assert(c:deliver() == false)
end

function T.deliver_speaks_waiting_reports_on_request()
  local c, w = conversation {
    talker = { { text = "Started.", calls = { hand("look") } }, "It found the file." },
    worker = { "found the file" }, cfg = { proactive = false },
  }
  c:heard("find it")
  drive(c, 30, function () return c.job_list[1] and c.job_list[1].state == "done" and not c:busy() end)
  assert(c:deliver() == true)
  local said = drive(c, 20, idle(c))
  assert(said[1] == "It found the file.")
end

function T.a_cut_keeps_what_was_said_and_the_job()
  local c, w = conversation {
    talker = { { text = "One. Two. Three.", calls = { hand("keep going") } } },
    worker = { "kept going" }, worker_polls = 50,
  }
  c:heard("go")
  for _ = 1, 5 do c:update() end
  assert(c:take() == "One."); c:said()
  assert(c:take() == "Two.")                   -- being said when the person speaks
  c:cut()
  assert(not c:busy())
  local agent_text
  for _, m in ipairs(c.history) do if m.role == "agent" then agent_text = m.text end end
  assert(agent_text == "One. Two.", agent_text)
  assert(c.job_list[1].state == "running", "a cut never cancels a job")
  local cut
  for _, e in ipairs(w.events) do if e.event == "cut" then cut = e.data.said end end
  assert(cut == "One. Two.")
end

function T.a_cut_before_the_model_answered_abandons_the_call()
  local c, w = conversation { talker = { "too late" }, talker_polls = 50 }
  c:heard("hello")
  drive(c, 3)
  c:cut()
  assert(w.talk.cancelled == 1, "the wait's cancel was called")
  assert(not c:busy())
  assert(#c.history == 1 and c.history[1].text == "hello")
  drive(c, 60)
  assert(#w.talk.seen == 1, "an abandoned reply is never resumed")
end

function T.a_question_is_relayed_and_decided_only_after_the_person_speaks()
  local wrote = worker("notes", { { name = "write_note", tool = {
    about = "Write a note", ask = true, args = { text = spec.types.string "the note" },
    run = function (ctx) ctx.fs.write("note.md", ctx.args.text); return "written" end } } })
  local c, w = conversation {
    workers = wrote,
    talker = {
      { text = "I'll get that written.", calls = { hand("write a note saying hi") } },
      { text = "It wants to write a note. Shall it?", calls = { { tool = "decide", args = { job = "j1", allow = true } } } },
      "Should it go ahead?",
      { text = "Going ahead.", calls = { { tool = "decide", args = { job = "j1", allow = true } } } },
      "The note is written.",
    },
    worker = { { tool = "write_note", args = { text = "hi" } }, "Saved the note." },
  }
  c:heard("write a note")
  -- the job asks; the report reply tries to decide on its own, is refused, and asks instead
  local said = drive(c, 60, function () return count(w.events, "done") >= 2 and not c:busy() end)
  assert(c.job_list[1].state == "asking", "no turn yet, so no decision")
  assert(count(w.events, "question") == 1)
  local refused = false
  for _, m in ipairs(w.talk.seen[3].messages) do
    if m.role == "tool" and m.text:find("has not answered yet", 1, true) then refused = true end
  end
  assert(refused)
  assert(said[#said] == "Should it go ahead?", tostring(said[#said]))
  c:heard("yes, go ahead")
  drive(c, 60, function () return c.job_list[1].state == "done" and not c:busy() end)
  assert(c.job_list[1].state == "done", c.job_list[1].state)
  assert(w.fs.files["note.md"] == "hi", "the gate let the call through")
end

function T.the_host_can_decide_and_the_question_leaves_the_queue()
  local wrote = worker("notes", { { name = "write_note", tool = {
    about = "Write a note", ask = true, args = {}, run = function () return "written" end } } })
  local c = conversation {
    workers = wrote, cfg = { proactive = false },
    talker = { { text = "Sure.", calls = { hand("write") } } },
    worker = { { tool = "write_note", args = {} }, "done" },
  }
  c:heard("write")
  drive(c, 20, function () return c.job_list[1] and c.job_list[1].state == "asking" end)
  assert(#c.reports == 1 and c.reports[1].kind == "question")
  assert(c:decide("j1", false, "not now"))
  assert(#c.reports == 0)
  drive(c, 20, function () return c.job_list[1].state == "done" end)
  assert(c.job_list[1].state == "done")
  assert(c.job_list[1].result.calls[1].refused == true)
  local ok, why = c:decide("j9", true)
  assert(ok == nil and why:find("no job j9"))
end

function T.the_talker_speaks_what_jobs_says()
  local c, w = conversation {
    talker = { { text = "Starting.", calls = { hand("slow") } }, { tool = "jobs", args = {} }, "One job is running." },
    worker = { "done" }, worker_polls = 50,
  }
  c:heard("start it")
  drive(c, 5, idle(c))
  c:heard("how is it going?")
  local said = drive(c, 10, idle(c))
  assert(said[1] == "One job is running.", tostring(said[1]))
  local seen = last_request(w.talk)
  local status = seen.messages[#seen.messages].text
  assert(status:find("j1, research: running", 1, true), status)
end

function T.cancel_stops_a_job_and_its_call()
  local c, w = conversation {
    talker = { { text = "Starting.", calls = { hand("slow") } },
               { text = "Stopping it.", calls = { { tool = "cancel", args = { job = "j1" } } } } },
    worker = { "done" }, worker_polls = 50,
  }
  c:heard("start")
  drive(c, 5, idle(c))
  c:heard("stop that")
  drive(c, 10, idle(c))
  assert(c.job_list[1].state == "cancelled")
  assert(w.worker.cancelled == 1)
  assert(#c.reports == 0, "the talker stopped it itself, so there is nothing to report")
  assert(#w.talk.seen == 2, "cancel ends the reply")
  local ok, why = c:cancel("j1")
  assert(ok == nil and why:find("not running"))
end

function T.limits_are_sentences_the_talker_reads()
  local two = { research = worker("research"), notes = worker("notes") }
  local c, w = conversation {
    workers = two, cfg = { jobs = 1, talker = { budget = 6 } }, worker_polls = 50,
    talker = {
      { text = "", calls = { hand("x") } },                       -- no worker named, with two
      { text = "", calls = { hand("x", "nobody") } },
      { text = "", calls = { hand("   ", "notes") } },
      { text = "", calls = { hand("x", "notes") } },
      "one is running",
    },
  }
  c:heard("go")
  drive(c, 10, idle(c))
  local outs = {}
  for _, m in ipairs(last_request(w.talk).messages) do if m.role == "tool" then outs[#outs + 1] = m.text end end
  assert(outs[1]:find("say which worker: notes, research", 1, true), outs[1])
  assert(outs[2]:find("one of notes, research", 1, true) and outs[2]:find("nobody", 1, true), outs[2])
  assert(outs[3]:find("the task is empty", 1, true), outs[3])
  -- the fourth started a job and ended the reply, so a second turn meets the limit
  assert(#c.job_list == 1)
  local c2, w2 = conversation {
    workers = two, cfg = { jobs = 1 }, worker_polls = 50,
    talker = { { text = "A.", calls = { hand("x", "notes") } }, { text = "B.", calls = { hand("y", "notes") } }, "Wait for it." },
  }
  c2:heard("one"); drive(c2, 5, idle(c2))
  c2:heard("two"); drive(c2, 5, idle(c2))
  local limit = last_request(w2.talk).messages
  assert(limit[#limit].text:find("already 1 jobs running", 1, true), limit[#limit].text)
end

function T.a_job_that_fails_runs_out_or_raises_reports()
  local c, w = conversation {
    talker = { { text = "Go.", calls = { hand("a"), hand("b") } }, "Reported." },
    worker = { { code = "timeout", message = "no answer in 60s" } },
  }
  c:heard("go")
  drive(c, 30, function () return #c.job_list == 2 and c.job_list[2].state ~= "running" and c.job_list[2].state ~= "starting" end)
  assert(c.job_list[1].state == "failed", c.job_list[1].state)
  assert(c.reports[1] and c.reports[1].text:find("failed: the model call failed", 1, true) or count(w.events, "report") == 1)

  local spent = conversation {
    talker = { { text = "Go.", calls = { hand("loop") } }, "It ran out." },
    worker = { { tool = "look", args = {} }, { tool = "look", args = {} }, { tool = "look", args = {} } },
    cfg = { job_budget = 2 },
  }
  spent:heard("go")
  drive(spent, 30, function () return spent.job_list[1] and spent.job_list[1].state == "spent" end)
  assert(spent.job_list[1].state == "spent")

  local raised = conversation {
    talker = { { text = "Go.", calls = { hand("boom") } }, "It broke." },
    cfg = { run = function (decl, prompt, port, opts)
      if opts.id == "j1" then error("the worker exploded") end
      return turn.run(decl, prompt, port, opts)
    end },
  }
  raised:heard("go")
  drive(raised, 30, function () return raised.job_list[1] and raised.job_list[1].state == "failed" end)
  assert(raised.job_list[1].state == "failed")
  assert(raised.job_list[1].result.reason:find("the worker exploded", 1, true))
end

function T.history_is_kept_to_keep_at_a_turn_boundary()
  local replies = {}
  for i = 1, 6 do replies[i] = "answer " .. i .. "." end
  local c, w = conversation { talker = replies, cfg = { keep = 3 } }
  for i = 1, 6 do c:heard("question " .. i); drive(c, 10, idle(c)) end
  local req = last_request(w.talk)
  -- keep 3 from ten earlier messages starts at a user message: question 5, answer 5, then the prompt
  assert(#req.messages == 3, #req.messages)
  assert(req.messages[1].role == "user" and req.messages[1].text == "question 5")
  assert(req.messages[3].text == "question 6")
end

function T.a_delegate_world_is_per_run()
  local worlds = {}
  local function top()
    local s = declare.swap({})
    declare.swap(s)
    return s[#s]
  end
  local before = top()
  local c = conversation {
    talker = { { text = "Both.", calls = { hand("one"), hand("two") } }, "Done." },
    job_world = function (job) return { model = { call = function () end }, name = job.id } end,
    cfg = { run = function (decl, prompt, port, opts)
      if opts.id == nil or opts.id == "talker" then return turn.run(decl, prompt, port, opts) end
      local depth = declare.enter(port)
      local left = 3
      coroutine.yield { wait = "host", poll = function () left = left - 1; return left <= 0 end }
      worlds[opts.id] = top().name
      declare.leave(depth)
      return { stop = "answered", answer = "ok", steps = 1, transcript = {} }
    end },
  }
  c:heard("go")
  drive(c, 20)
  assert(worlds.j1 == "j1" and worlds.j2 == "j2", tostring(worlds.j1) .. " " .. tostring(worlds.j2))
  assert(top() == before, "the outer stack is untouched")
end

function T.sentences_leave_out_markdown_and_wait_for_a_stop()
  local s, rest = speech.sentences("**Two** things:\n- the `first` one\n- the [second](http://x) one. And a thir")
  assert(s[1] == "Two things:" or s[1] == "Two things: the first one", table.concat(s, "|"))
  assert(rest == " And a thir" or rest == "And a thir", rest)
  local whole = speech.sentences("Done. ## Heading here", true)
  assert(whole[1] == "Done." and whole[2] == "Heading here", table.concat(whole, "|"))
  assert(#speech.sentences("", true) == 0)
  assert(#speech.sentences("--- *** ", true) == 0, "nothing sayable")
end

function T.a_gate_wait_is_a_person_wait()
  local c = conversation {
    talker = { { text = "Asking.", calls = { hand("file a note") } }, "Filed." },
    talker_polls = 0, worker_polls = 0,
    cfg = {
      relay = true,
      run = function (decl, prompt, port, opts)
        if opts and tostring(opts.id):find("^j") then
          local d = coroutine.yield { wait = "gate", question = { tool = "file", about = "File a line." } }
          return { stop = "answered", answer = d.allow and "filed" or "refused", steps = 1, transcript = {} }
        end
        return turn.run(decl, prompt, port, opts)
      end,
    },
  }
  c:heard("file it")
  drive(c, 10, function () return c.job_list[1] and c.job_list[1].state == "asking" end)
  assert(c.job_list[1].state == "asking", c.job_list[1] and c.job_list[1].state)
  assert(c:decide("j1", true))
  drive(c, 10, idle(c))
  assert(c.job_list[1].result.answer == "filed", c.job_list[1].result.answer)
end

function T.a_sleep_in_seconds_waits_on_the_clock()
  local t = 0
  local c = conversation {
    talker = { "Later." }, talker_polls = 0,
    cfg = {
      clock = function () return t end,
      run = function ()
        coroutine.yield { wait = "sleep", seconds = 2 }
        return { stop = "answered", answer = "Later.", steps = 1, transcript = {} }
      end,
    },
  }
  c:heard("wait")
  c:update(); c:update()
  assert(c:busy(), "it woke before the clock")
  t = 2
  drive(c, 5, idle(c))
  assert(not c:busy())
end

function T.a_port_that_never_yields_works_in_order()
  local c, w = conversation {
    talker = { { text = "Sure.", calls = { hand("x") } }, "It is done." },
    talker_polls = 0, worker_polls = 0, worker = { "x is done" },
  }
  c:heard("do x")
  local said = drive(c, 10, function () return count(w.events, "done") == 2 end)
  assert(said[1] == "Sure." and said[2] == "It is done.", table.concat(said, "|"))
end

function T.new_refuses_what_it_cannot_run()
  local ok, err
  ok, err = pcall(speech.new, { world = { model = {} }, workers = worker("w"), wrokers = 1 })
  assert(not ok and err:find("no option \"wrokers\"", 1, true), err)
  ok, err = pcall(speech.new, { workers = worker("w") })
  assert(not ok and err:find("needs `world`", 1, true))
  ok, err = pcall(speech.new, { world = { model = {} } })
  assert(not ok and err:find("needs `workers`", 1, true))
  local talker = speech.talker()
  spec.add_tool(talker, "hand_off", { about = "mine", run = function () end })
  ok, err = pcall(speech.new, { world = { model = {} }, workers = worker("w"), talker = talker })
  assert(not ok and err:find("the conversation's own", 1, true))
  ok, err = pcall(speech.new, { world = { model = {} }, workers = worker("w"), jobs = 0 })
  assert(not ok and err:find("`jobs` is a whole number", 1, true))
  -- the talker given is copied, never changed
  local mine = speech.talker { model = "test:fast" }
  local c = speech.new { world = { model = {} }, workers = worker("w"), talker = mine }
  assert(#mine.order == 0 and #c.talker.order == 4)
  assert(c.talker.model == "test:fast" and c.talker.system:find("The workers you can hand work to:\n- w: You look things up.", 1, true))
end

function T.the_default_talker_is_glm_with_reasoning_low()
  local t = speech.talker()
  assert(t.model == "openrouter:z-ai/glm-5.3" and t.reasoning == "low" and t.budget == 3)
  assert(t.system == speech.BRIEF)
end

function T.speech_reaches_nothing()
  local f = assert(io.open(here .. "/../src/speech.lua", "rb"))
  local text = f:read("*a"); f:close()
  local code = text:gsub("%-%-[^\n]*", "")
  for _, bad in ipairs { "io%.", "os%.", "math%.random", "require \"console", "print%(" } do
    assert(not code:find(bad), "src/speech.lua mentions " .. bad)
  end
end

-- turn's two additions, used by speech and proved here against the loop itself.

function T.turn_puts_history_before_the_prompt()
  local a = worker("w")
  local w = double.world { model = { replies = { "fine" } } }
  local r = turn.run(a, "and now?", w, { history = {
    { role = "user", text = "before" }, { role = "agent", text = "earlier answer" } } })
  assert(r.stop == "answered")
  local sent = w.model.seen[1].messages
  assert(#sent == 3 and sent[1].text == "before" and sent[2].role == "agent" and sent[3].text == "and now?")
  local ok, problems = turn.check(a, w, { history = { { role = "system", text = "x" } } })
  assert(not ok and problems[1]:find("opts.history%[1%]"))
end

function T.a_tool_that_ends_ends_the_run_unless_it_failed()
  local a = spec.new()
  spec.set_name(a, "t"); spec.set_model(a, "test:m")
  local fail_next = false
  spec.add_tool(a, "go", { about = "go", ends = true, args = {},
    run = function () if fail_next then return nil, "cannot" end; return "gone" end })
  local w = double.world { model = { replies = { { text = "Off I go.", calls = { { tool = "go" } } } } } }
  local r = turn.run(a, "go", w)
  assert(r.stop == "answered" and r.answer == "Off I go." and r.steps == 1)
  fail_next = true
  local w2 = double.world { model = { replies = { { text = "Trying.", calls = { { tool = "go" } } }, "It failed." } } }
  local r2 = turn.run(a, "go", w2)
  assert(r2.stop == "answered" and r2.answer == "It failed." and r2.steps == 2)
  local ok, err = pcall(spec.add_tool, a, "bad", { about = "x", run = function () end, ends = "yes" })
  assert(not ok and err:find("`ends` is true or false", 1, true))
end

function T.a_jobs_calls_so_far_are_listed_while_it_runs()
  local c = conversation {
    talker = { { text = "On it.", calls = { hand("look it up") } }, "Done." },
    worker = { { calls = { { tool = "look", args = {} } } }, "looked it up" }, worker_polls = 40,
  }
  c:heard("look it up")
  -- the worker's first reply lands after 40 polls; the tool then runs and the second call is made
  drive(c, 50, function () local j = c:jobs()[1]; return j and j.calls and #j.calls > 0 end)
  local j = c:jobs()[1]
  assert(j.state == "running", j.state)
  assert(type(j.calls) == "table" and #j.calls == 1 and j.calls[1].tool == "look" and j.calls[1].ok == true,
    "the call so far is not listed")
  assert(j.result == nil and j.ended == nil)
  drive(c, 200)
  j = c:jobs()[1]
  assert(j.state == "done" and j.result and #j.result.calls == 1 and j.ended ~= nil, j.state)
  -- its trace is its own, and was there while it ran
  local names = {}
  for _, sp in ipairs(j.spans or {}) do names[#names + 1] = sp.name end
  assert(#names > 0 and names[1]:find("^invoke_agent"), table.concat(names, ", "))
  local tool = false
  for _, n in ipairs(names) do if n == "execute_tool look" then tool = true end end
  assert(tool, "the call is not in the job's trace")
end

return T
