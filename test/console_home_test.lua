-- The home screen (console/lib/home.lua) and its bar (console/lib/bar.lua): the hints, the
-- typing line, the transcript, the captions and the voice switches, over a real
-- conversation (src/speech.lua) with scripted models, and a stand-in voice. The host's
-- drawing is not here; the view it draws is.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../?.lua;" .. here .. "/../src/?.lua;" .. package.path

local spec   = require "spec"
local double = require "double"
local speech = require "speech"
local home   = require "console.lib.home"

local T = {}

local function worker()
  local a = spec.new()
  spec.set_name(a, "notebook")
  spec.set_model(a, "test:worker")
  spec.set_system(a, "You keep notes.")
  spec.add_tool(a, "look", { about = "Look", args = {}, run = function () return "looked" end })
  return a
end

-- A screen over a talker that answers from `talker`, and a worker that answers from `worker`.
local function screen(o)
  o = o or {}
  local now = 0
  local c = speech.new {
    world = { model = double.model { replies = o.talker or { "Hello there. How can I help?" } } },
    job_world = { model = double.model { replies = o.worker or { "done" } }, fs = double.fs {} },
    workers = worker(),
  }
  local h = home.new { conversation = c, clock = function () return now end, voice_why = "no voice here" }
  return h, c, function (dt) now = now + dt end
end

-- Measures text as 7 pixels a character, whatever its size.
local function measure(s) return #s * 7 end

local function run(h, n) for _ = 1, n or 30 do h:update() end end

local function lines_of(h, who)
  local out = {}
  for _, l in ipairs(h.lines) do if l.who == who then out[#out + 1] = l.text end end
  return out
end

-- A voice that does what console/ml/voice.lua does to the screen, without models.
local function fake_voice()
  local v = { state = "waiting", updates = 0, cleared = 0, interrupted = 0 }
  v.tts = { name = "tts" }
  v.speaker = { queued = function () return 0 end, clear = function () v.cleared = v.cleared + 1 end }
  function v:update() self.updates = self.updates + 1 end
  function v:interrupt() self.interrupted = self.interrupted + 1 end
  return v
end

function T.each_action_has_a_key_and_an_end_of_the_bar()
  local seen, sides = {}, { left = 0, right = 0 }
  for _, t in ipairs(home.TOOLBAR) do
    assert(t.key and t.shows and t.label and t.action, "an action is missing a part")
    assert(not seen[t.key], "two actions share " .. t.key)
    seen[t.key] = true
    sides[t.side] = sides[t.side] + 1
  end
  assert(#home.TOOLBAR == 6 and sides.left == 3 and sides.right == 3)
end

function T.typing_sends_a_turn_and_the_reply_comes_back()
  local h, c = screen()
  assert(h:key("t") and h.typing)
  h:text("t")                                  -- the T that opened it
  assert(h.draft == "", "the opening T was typed: " .. h.draft)
  for ch in ("hi there"):gmatch(".") do h:text(ch) end
  h:key("backspace")
  assert(h.draft == "hi ther", h.draft)
  h:key("return")
  assert(h.draft == "" and h.typing, "the line stays open for the next turn")
  assert(lines_of(h, "you")[1] == "hi ther")
  run(h)
  assert(lines_of(h, "agent")[1] == "Hello there. How can I help?", table.concat(lines_of(h, "agent"), "|"))
  assert(not c:busy(), "the reply's sentences were taken and said")
  assert(h:key("escape") and not h.typing)
end

function T.an_empty_line_is_not_a_turn()
  local h, c = screen()
  h:key("t"); h:key("return")
  assert(#lines_of(h, "you") == 0 and not c:busy())
end

function T.keys_that_are_typing_do_not_press_buttons()
  local h = screen()
  h:key("t")
  h:key("tab"); h:key("space"); h:key("m")
  assert(not h.transcript_open and not h.mic_open and h.voice_on, "a key pressed a button while typing")
end

function T.talk_without_a_voice_says_why()
  local h = screen()
  local ok, why = h:act("talk")
  assert(not ok and why == "no voice here")
  assert(not h.mic_open)
  assert(h.lines[#h.lines].text:find("no voice here", 1, true))
end

function T.talk_with_a_voice_opens_and_closes_the_microphone()
  local h = screen()
  local v = fake_voice()
  h:attach_voice(v)
  assert(h:key("space") and h.mic_open)
  assert(h:key("space") and not h.mic_open)
  run(h, 3)
  assert(v.updates == 3, "the voice drives the conversation once it is here")
end

function T.voice_off_keeps_replies_quiet_and_on_brings_them_back()
  local h = screen()
  local v = fake_voice()
  local tts = v.tts
  h:attach_voice(v, tts)
  h:key("m")
  assert(not h.voice_on and v.tts == nil and v.cleared == 1)
  h:key("m")
  assert(h.voice_on and v.tts == tts)
end

function T.stop_interrupts_the_voice_or_cuts_the_reply()
  local h, c = screen { talker = { "One. Two. Three." } }
  c:heard("count")
  c:update()
  assert(h:stoppable())
  h:act("stop")
  assert(not c:busy(), "stop left the reply running")
  local v = fake_voice()
  h:attach_voice(v)
  h:act("stop")
  assert(v.interrupted == 1)
end

function T.the_transcript_opens_scrolls_and_escape_closes_it()
  local h = screen()
  for i = 1, 60 do h:add("note", "line " .. i) end
  h:key("tab")
  assert(h.transcript_open)
  h:view(800, 600, measure)
  h:key("up"); h:key("up")
  assert(h.scroll == 2)
  h:wheel(-1)
  assert(h.scroll == 0)
  h:key("escape")
  assert(not h.transcript_open)
end

function T.jobs_questions_and_failures_reach_the_transcript()
  local h = screen { talker = { { text = "On it.", calls = { { tool = "hand_off", args = { task = "look" } } } }, "Done." },
                     worker = { { calls = { { tool = "look", args = {} } } }, "Looked." } }
  h:send("look it up")
  run(h, 60)
  local jobs = lines_of(h, "job")
  assert(#jobs >= 2 and jobs[1]:find("started", 1, true) and jobs[#jobs]:find("done", 1, true),
    table.concat(jobs, " | "))
  h:conversation_event("question", { id = "j1", tool = "write" })
  h:conversation_event("failed", { reason = "no key" })
  assert(lines_of(h, "ask")[1]:find("j1 asks to run write", 1, true))
  assert(lines_of(h, "error")[1]:find("no key", 1, true))
end

function T.the_caption_fades_once_it_is_old()
  local h, _, tick = screen()
  h:send("hello")
  local function caption_alpha()
    for _, it in ipairs(h:view(900, 600, measure).items) do
      if it.kind == "text" and it.text == "hello" then return it.alpha end
    end
    return 0
  end
  local first = caption_alpha()
  assert(first > 0)
  tick(home.CAPTION_HOLD + home.CAPTION_FADE / 2)
  local a = caption_alpha()
  assert(a > 0 and a < first, tostring(a))
  tick(home.CAPTION_FADE)
  assert(caption_alpha() == 0)
end

-- The texts drawn, by text.
local function texts_of(view)
  local t = {}
  for _, it in ipairs(view.items) do if it.kind == "text" then t[it.text] = it end end
  return t
end

function T.every_action_is_a_hint_on_the_bar_while_the_pointer_is_over_it()
  local h, _, tick = screen()
  h:attach_voice(fake_voice())
  h:pointer(500, 675)
  local view = h:view(1000, 680, measure)
  local texts = texts_of(view)
  for _, t in ipairs(home.TOOLBAR) do
    local key = texts[t.shows]
    assert(key, "no key shown for " .. t.action)
    assert(texts[t.label:lower()], "no label for " .. t.action)
    assert(key.y >= view.bar.y and key.y < view.bar.y + view.bar.h, t.action .. " is not on the bar")
    assert((t.side == "left") == (key.x < 500), t.action .. " is at the wrong end")
    local hit
    for _, r in ipairs(h.hits) do if r.action == t.action then hit = r end end
    assert(hit and h:hit(hit.x + 1, hit.y + 1) == t.action, "no hint for " .. t.action)
  end
  assert(view.stage.y == 0 and view.stage.h == view.bar.y and view.bar.y + view.bar.h == 680
    and view.bar.w == 1000, "the stage is the window above the bar")
  assert(view.bar.h < 680 * 0.1, "the bar takes more than a tenth of the window")
  local talk
  for _, r in ipairs(h.hits) do if r.action == "talk" then talk = r end end
  assert(h:press(talk.x + 1, talk.y + 1) == "talk" and h.mic_open)
  -- the pointer goes up onto the stage: the hints fade, and nothing on the bar answers a click
  h:pointer(500, 200)
  for _ = 1, 10 do tick(0.1); view = h:view(1000, 680, measure) end
  assert(not texts_of(view).Tab and #h.hits == 0, "a hint is still drawn")
  h:pointer(500, 675)
  for _ = 1, 10 do tick(0.1); view = h:view(1000, 680, measure) end
  assert(texts_of(view).Tab)
  h:pointer(nil)
  for _ = 1, 10 do tick(0.1); view = h:view(1000, 680, measure) end
  assert(not texts_of(view).Tab, "the pointer left the window and a hint is still drawn")
end

function T.captions_turn_off_and_on()
  local h = screen()
  h:send("hello")
  assert(texts_of(h:view(900, 600, measure)).hello, "no caption")
  assert(h:key("c") and not h.captions_on)
  assert(not texts_of(h:view(900, 600, measure)).hello, "the caption is drawn with captions off")
  h:key("c")
  assert(texts_of(h:view(900, 600, measure)).hello)
  h:key("t"); h:text("t"); h:text("c")
  assert(h.captions_on and h.draft == "c", "a C typed switched the captions")
end

function T.the_status_says_what_is_happening()
  local h, c = screen()
  assert(h:status().mode == "ready")
  c:heard("hi")
  assert(h:status().mode == "thinking")
  local v = fake_voice()
  h:attach_voice(v)
  v.state = "speaking"
  assert(h:status().mode == "hearing you")
end

function T.nothing_is_drawn_on_the_stage_while_nothing_is_shown()
  local h, c = screen()
  h:send("hi")
  assert(c:busy())
  local view = h:view(900, 600, measure)
  local any = false
  for _, it in ipairs(view.items) do
    if it.kind == "text" then
      any = true
      assert(it.y >= view.bar.y and it.y < view.bar.y + view.bar.h, "'" .. it.text .. "' is drawn on the stage")
    end
  end
  assert(any, "the caption is not drawn")
end

-- The bar's items in a view: its ground and its dots.
local function bar_of(view)
  local b = { dots = {} }
  for _, it in ipairs(view.items) do
    if it.kind == "rect" and it.y == view.bar.y and it.h == view.bar.h then b.ground = it end
    if it.kind == "circle" then b.dots[#b.dots + 1] = it end
  end
  return b
end

-- Whether any dot has a colour that is not a grey.
local function coloured(dots)
  for _, d in ipairs(dots) do
    if math.abs(d.rgb[1] - d.rgb[2]) > 0.1 or math.abs(d.rgb[2] - d.rgb[3]) > 0.1 then return true end
  end
  return false
end

function T.the_bar_is_dark_then_grey_dots_while_the_person_is_heard_then_coloured_while_the_agent_speaks()
  local h, _, tick = screen()
  local v = fake_voice()
  h:attach_voice(v)
  local function settle() local view; for _ = 1, 12 do tick(0.05); view = h:view(900, 600, measure) end; return view end
  local quiet = bar_of(settle())
  assert(quiet.ground and #quiet.dots == 0, "the bar is not dark with nothing happening")
  h:act("talk")
  h:hear_level(0.8)
  local heard = bar_of(settle())
  assert(#heard.dots > 0 and not coloured(heard.dots), "the person's dots are not grey")
  h:act("talk")
  v.saying = "Hello."
  h:say_level(0.8)
  local said = bar_of(settle())
  assert(#said.dots == #heard.dots and coloured(said.dots), "the agent's dots are not in colour")
  for _, b in ipairs { heard, said } do
    assert(b.ground.y == quiet.ground.y and b.ground.h == quiet.ground.h, "the bar changed its size")
  end
  v.saying = nil
  settle()
  assert(#bar_of(settle()).dots == 0, "the dots stayed after the agent stopped")
end

function T.the_caption_is_in_the_middle_of_the_bar_a_line_at_a_time_and_the_dots_under_it_rest()
  local h, _, tick = screen()
  h:attach_voice(fake_voice())
  h:set_caption("agent", "one two three four five six seven eight nine ten eleven twelve thirteen fourteen")
  h.v.saying = "one"
  h:say_level(1)
  local function caption(view)
    for _, it in ipairs(view.items) do
      if it.kind == "text" and it.y >= view.bar.y then return it end
    end
  end
  local view = h:view(400, 600, measure)
  local first = caption(view)
  assert(first and first.text:find("^one"), "the first line is not shown first")
  assert(math.abs(first.x + measure(first.text) / 2 - 200) <= 4, "the caption is not in the middle")
  assert(first.x > 40 and first.x + measure(first.text) < 360, "the caption reaches the ends of the bar")
  for _ = 1, 100 do tick(0.05); view = h:view(400, 600, measure) end
  local later = caption(view)
  assert(later and later.text ~= first.text and later.text:find("fourteen$"), "the lines did not come in turn")
  -- the dots under the caption rest, and those at the ends are lit
  local x0, x1 = later.x, later.x + measure(later.text)
  local under, ends = 0, 0
  for _, d in ipairs(bar_of(view).dots) do
    if d.x > x0 and d.x < x1 then under = math.max(under, d.alpha)
    elseif d.x < x0 - 20 or d.x > x1 + 20 then ends = math.max(ends, d.alpha) end
  end
  assert(under < 0.25 and ends > 0.5, "under " .. under .. ", at the ends " .. ends)
end

function T.the_line_being_typed_is_in_the_middle_of_the_bar()
  local h, _, tick = screen()
  h:key("t")
  local view = h:view(900, 600, measure)
  local hint = texts_of(view)["Type to the agent. Enter sends, Esc closes."]
  assert(hint and hint.y >= view.bar.y, "no invitation to type on the bar")
  for ch in ("hello"):gmatch(".") do h:text(ch) end
  for _ = 1, 10 do tick(0.05); view = h:view(900, 600, measure) end
  local line = texts_of(view).hello
  assert(line and math.abs(line.x + measure("hello") / 2 - 450) <= 4, "the line is not in the middle")
  assert(#bar_of(view).dots > 0, "the bar does not hear typing")
end

function T.the_dots_spread_from_where_they_are_lit_and_fade()
  local bar = require "console.lib.bar"
  local b = bar.new()
  local t = 0
  local function frames(n, level, still)
    local items
    for _ = 1, n do
      t = t + 1 / 60
      items = b:draw { x = 0, y = 0, w = 400, h = 32, now = t, state = "hearing", level = level, still = still }
    end
    local dots = {}
    for _, it in ipairs(items) do if it.kind == "circle" then dots[#dots + 1] = it end end
    return dots
  end
  local dots = frames(30, 0)
  assert(#dots == b.cols * b.rows and #dots > 40)
  for _, d in ipairs(dots) do assert(d.alpha < 0.3, "a dot is lit with nothing heard") end
  b:pour(0.25, 3)
  dots = frames(6, 0)
  -- the brightest dot in the column nearest x
  local function near(x)
    local best
    for _, d in ipairs(dots) do
      if math.abs(d.x - x) <= bar.PITCH / 2 and (not best or d.alpha > best.alpha) then best = d end
    end
    return best
  end
  assert(near(100).alpha > near(300).alpha + 0.2, "the pulse did not light where it was poured")
  assert(near(116).alpha > near(300).alpha, "the pulse did not spread")
  dots = frames(180, 0)
  for _, d in ipairs(dots) do assert(d.alpha < 0.3, "the pulse did not fade") end
  -- a loud voice lights the dots, but none under a span that rests
  dots = frames(40, 1, { { 120, 280 } })
  local lit, under = 0, 0
  for _, d in ipairs(dots) do
    if d.x >= 120 and d.x <= 280 then under = math.max(under, d.alpha)
    elseif d.alpha > 0.6 then lit = lit + 1 end
  end
  assert(lit > 3, "a loud voice lights nothing")
  assert(under <= bar.REST + 0.02, "a dot under text is lit: " .. under)
end

function T.the_agent_file_is_on_the_stage_at_rest_and_the_transcript_takes_its_place()
  local h = screen()
  assert(h:set_file("Feature: greeter\n  Says hello.\n\n  Scenario: it greets\n    When the agent is asked \"hi\"\n    Then the answer says \"hello\"\n"))
  local view = h:view(900, 600, measure)
  local texts = texts_of(view)
  assert(texts.greeter and texts["Scenario:"] and texts["it greets"], "the file is not on the stage")
  for _, it in ipairs(view.items) do
    if it.kind == "text" and it.text == "greeter" then assert(it.y < view.bar.y, "the file is over the bar") end
  end
  h:key("tab")
  texts = texts_of(h:view(900, 600, measure))
  assert(texts.Transcript and not texts.greeter, "the transcript did not take the file's place")
  h:key("tab")
  assert(texts_of(h:view(900, 600, measure)).greeter)
  assert(not h:set_file("Scenario: bare\n  Given nothing\n"), "a bare scenario is not a file")
end

function T.a_job_is_an_observed_scenario_on_the_file_while_it_runs_and_folds_after_it_ends()
  local h, _, tick = screen { talker = { { text = "On it.", calls = { { tool = "hand_off", args = { task = "look" } } } }, "Done." },
                              worker = { { calls = { { tool = "look", args = {} } } }, "Looked." } }
  assert(h:set_file("Feature: notebook\n  Keeps notes.\n"))
  h:send("look it up")
  local seen_running, seen_call = false, false
  for _ = 1, 60 do
    h:update()
    tick(0.05)
    local texts = texts_of(h:view(900, 700, measure))
    for t in pairs(texts) do
      if t:find("^j1 notebook") then seen_running = true end
      if t == "it calls look with {}" then seen_call = true end
    end
  end
  assert(seen_running, "the job's scenario never showed")
  assert(seen_call, "the job's call never showed")
  local texts = texts_of(h:view(900, 700, measure))
  assert(texts["it stops with answered"], "the finished run's stop is not on the file")
  tick(home.FOLD + 1)
  h:view(900, 700, measure)
  tick(0.5)                                    -- the lines that went have faded
  texts = texts_of(h:view(900, 700, measure))
  assert(texts["done after 2 steps"] and not texts["it stops with answered"], "the run did not fold")
end

function T.the_files_scenarios_are_run_and_marked_on_the_stage()
  local h = screen()
  local text = 'Feature: b\n  Background:\n    Given the agent is called b\n    And its model is "x:y"\n    And it has a tool greet for "Say hello.", which takes:\n      | argument | type   | about |\n      | name     | string | who   |\n    And the tool greet does:\n      """lua\n      return "hello, " .. c.args.name\n      """\n\n  Scenario: it greets\n    Given the model calls greet with {"name": "ada"}\n    And the model answers "hi"\n    When the agent is asked "greet ada"\n    Then the call to greet answers "hello, ada"\n\n  Scenario: it is wrong about itself\n    Given the model answers "hi"\n    When the agent is asked "greet ada"\n    Then it calls greet\n'
  assert(h:set_file(text))
  local results = assert(h:verify(double.fs {}, "agents"))
  assert(#results == 2 and results[1].outcome == "passed" and results[2].outcome == "failed", results[2].outcome)
  local states = {}
  for _, r in ipairs(h.file:rows()) do if r.kind == "block" then states[r.parts[2].text] = r.state end end
  assert(states["it greets"] == "passed" and states["it is wrong about itself"] == "failed")
  local seen = {}
  for _, it in ipairs(h:view(900, 700, measure).items) do
    if it.kind == "text" and it.text == "it greets" then seen.passed = it.rgb[2] end
    if it.kind == "text" and it.text == "it is wrong about itself" then seen.failed = it.rgb[1] end
  end
  assert(seen.passed == 0.8 and seen.failed == 1, "the states are not coloured on the stage")
  assert(not h:verify(double.fs {}, "agents") == false)
end

function T.a_run_a_job_delegated_nests_under_it_with_what_it_did()
  local subagent = require "subagent"
  local helper = spec.new()
  spec.set_name(helper, "helper"); spec.set_model(helper, "test:helper"); spec.set_system(helper, "You mark.")
  spec.add_tool(helper, "mark", { about = "Mark", args = {}, run = function () return "marked" end })
  local helper_model = double.model { replies = { { calls = { { tool = "mark", args = {} } } }, "helper done" } }
  local w = spec.new()
  spec.set_name(w, "notebook"); spec.set_model(w, "test:worker"); spec.set_system(w, "You keep notes.")
  spec.add_tool(w, "delegate", subagent.tool { about = "Hand a job on", agents = { helper = helper }, world = { model = helper_model }, ask = false })
  local now = 0
  local c = speech.new {
    world = { model = double.model { replies = { { text = "On it.", calls = { { tool = "hand_off", args = { task = "count" } } } }, "Done." } } },
    job_world = { model = double.model { replies = { { calls = { { tool = "delegate", args = { agent = "helper", prompt = "go" } } } }, "counted" } }, fs = double.fs {} },
    workers = w, clock = function () return now end,
  }
  local h = home.new { conversation = c, clock = function () return now end }
  assert(h:set_file("Feature: notebook\n  Keeps notes.\n"))
  h:send("count the notes")
  for _ = 1, 80 do h:update(); now = now + 0.05 end
  assert(c:jobs()[1].state == "done", c:jobs()[1].state)
  local rows = {}
  for _, r in ipairs((function () h:view(900, 700, measure); return h.file:rows() end)()) do
    if r.kind == "block" then rows[r.parts[2].text] = r end
  end
  local nested = rows["helper, handed delegate"]
  assert(nested and nested.indent == 1 and nested.state == "passed", "the delegated run is not nested")
  local texts = texts_of(h:view(900, 700, measure))
  assert(texts["it calls mark"] and texts["it stops with answered"], "the delegated run's lines are missing")
  now = now + home.FOLD + 1
  h:view(900, 700, measure); now = now + 0.5
  texts = texts_of(h:view(900, 700, measure))
  assert(not texts["it calls mark"], "a folded job still shows what it delegated")
end

function T.the_transcript_is_shown_on_the_stage()
  local h = screen()
  h:send("hello")
  run(h)
  h:key("tab")
  local view = h:view(900, 600, measure)
  local texts = texts_of(view)
  assert(texts.Transcript and texts.hello and texts["Hello there. How can I help?"], "the transcript is not shown")
  for _, it in ipairs(view.items) do
    if it.kind == "text" then assert(it.y + view.size < view.bar.y, "'" .. it.text .. "' is over the bar") end
  end
  h:key("tab")
  assert(not texts_of(h:view(900, 600, measure)).Transcript, "the transcript is still up")
end

function T.every_size_of_window_is_laid_out_at_once()
  for _, s in ipairs { { 320, 240 }, { 560, 665 }, { 1400, 900 }, { 2400, 700 } } do
    local w, hgt = s[1], s[2]
    local h = screen()
    h:send("a caption long enough to need more than one line at the narrowest of these windows")
    h:pointer(w / 2, hgt - 2)
    local view = h:view(w, hgt, measure)
    assert(view.bar.y + view.bar.h == hgt and view.bar.w == w, "the bar is not along the foot at " .. w)
    local spans = {}
    for _, it in ipairs(view.items) do
      if it.kind == "text" then
        assert(it.x >= 0 and it.x + measure(it.text) <= w, "'" .. it.text .. "' is off the window at " .. w)
        assert(it.y >= 0 and it.y < hgt, "'" .. it.text .. "' is off the window at " .. w .. " x " .. hgt)
      end
    end
    for _, r in ipairs(h.hits) do spans[#spans + 1] = r end
    assert(#spans == #home.TOOLBAR, "a hint is missing at " .. w)
    for i = 1, #spans do
      for j = i + 1, #spans do
        local a, b = spans[i], spans[j]
        assert(a.x + a.w <= b.x + 8 or b.x + b.w <= a.x + 8, "two hints overlap at " .. w)
      end
    end
  end
end

function T.the_bar_reaches_nothing()
  local f = assert(io.open(here .. "/../console/lib/bar.lua", "rb"))
  local code = f:read("*a"):gsub("%-%-[^\n]*", "")
  f:close()
  for _, word in ipairs { "love", "io", "os" } do
    assert(not code:find("%f[%w_]" .. word .. "%f[^%w_]"), "bar.lua names " .. word)
  end
end

function T.wrap_keeps_words_whole_and_breaks_a_long_one()
  local lines = home.wrap("one two three four", 7 * 9, measure)
  assert(lines[1] == "one two" and lines[2] == "three" and lines[3] == "four", table.concat(lines, "|"))
  local long = home.wrap("abcdefghijkl", 7 * 5, measure)
  assert(long[1] == "abcde" and long[2] == "fghij" and long[3] == "kl", table.concat(long, "|"))
end

return T
