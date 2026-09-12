-- The spoken conversation's loop (console/ml/voice.lua), over stand-in parts: a microphone
-- that plays a script of loud and quiet, a VAD that calls loud speech, a turn model that
-- answers what the test says, a transcript that counts what it was given, a reply in two
-- sentences and a voice that makes two pieces of audio a sentence. The models have their
-- own tests; this one is the order of things.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local T = {}

local fine, ml = pcall(require, "console.ml.engine")
if not fine then return T end
local voice = require "console.ml.voice"
local unpack = table.unpack or unpack

-- A microphone that hears `script`, a list of { seconds, loudness }, 1600 samples a read.
local function script_mic(script)
  local all = {}
  for _, part in ipairs(script) do
    local b = ml.buffer(math.floor(part[1] * 16000))
    b:fill(part[2])
    all[#all + 1] = b
  end
  local audio, at = ml.join(unpack(all)), 1
  return {
    read = function ()
      if at > #audio then return ml.buffer(0) end
      local b = audio:slice(at, math.min(at + 1599, #audio))
      at = at + #b
      return b
    end,
    done = function () return at > #audio end,
  }
end

local function parts(script, finished, opts)
  opts = opts or {}
  local log = { pushed = 0, spoken = {} }
  local p = {
    mic = script_mic(script),
    vad = { step = function (_, w) return w[1] > 0.5 and 0.95 or 0.02 end },
    turn = { predict = function (_, s) log.predicted = #s; return finished end },
    asr = { stream = function ()
      return {
        push = function (_, b) log.pushed = log.pushed + #b; return ("%d samples"):format(log.pushed) end,
        finish = function () return "what time is it" end,
      }
    end },
    reply = function (history, on_piece)
      log.history_at_reply = #history
      for _, piece in ipairs(opts.pieces or { "It is ", "noon. ", "Anything ", "else?" }) do on_piece(piece) end
    end,
    tts = { rate = 24000, speak = function (_, text, o)
      log.spoken[#log.spoken + 1] = text
      o.on_audio(ml.buffer(2400)); o.on_audio(ml.buffer(2400))
    end },
    speaker = {
      q = 0, cleared = 0,
      write = function (s, b) s.q = s.q + #b; return #b end,
      queued = function (s) return s.q end,
      clear = function (s) s.q = 0; s.cleared = s.cleared + 1 end,
    },
  }
  return p, log
end

local function run(v, p, frames)
  local events = {}
  v.on = function (e, d) events[#events + 1] = d and (e .. ":" .. d) or e end
  for _ = 1, frames do
    v:update()
    p.speaker.q = math.max(0, p.speaker.q - 2400)     -- the speaker plays 0.1 s a frame
  end
  return events
end

local function find(events, what)
  for i, e in ipairs(events) do if e == what then return i end end
end

function T.a_finished_turn_is_heard_answered_and_said_sentence_by_sentence()
  local p, log = parts({ { 0.5, 0 }, { 1.0, 1 }, { 0.6, 0 } }, 0.9)
  local v = voice.new(p)
  local events = run(v, p, 60)
  local speech, heard = find(events, "speech"), find(events, "heard:what time is it")
  assert(speech and heard and speech < heard, table.concat(events, " | "))
  local said1, said2, done = find(events, "said:It is noon."), find(events, "said: Anything else?"), find(events, "done")
  assert(said1 and said2 and done and heard < said1 and said1 < said2 and said2 < done, table.concat(events, " | "))
  assert(#log.spoken == 2, #log.spoken)
  assert(log.history_at_reply == 1)
  assert(#v.history == 2 and v.history[1].role == "user" and v.history[2].text == "It is noon. Anything else?",
    v.history[2] and v.history[2].text)
  assert(v:status() == "waiting")
end

function T.the_transcript_gets_the_moment_before_the_vad_fired_and_the_pause()
  local p, log = parts({ { 0.5, 0 }, { 1.0, 1 }, { 0.6, 0 } }, 0.9)
  local v = voice.new(p)
  run(v, p, 30)
  -- a second of speech, 0.3 s of pre-roll, and the quiet up to the turn model's yes
  assert(log.pushed >= 16000 + 4000 and log.pushed <= 16000 + 4800 + 4800, log.pushed)
  assert(log.predicted and log.predicted >= 16000, "the turn model heard the turn")
end

function T.a_turn_the_model_calls_unfinished_waits_until_the_quiet_is_long()
  local p = parts({ { 0.2, 0 }, { 1.0, 1 }, { 1.0, 0 } }, 0.1)
  local v = voice.new(p)
  local events = run(v, p, 12)
  assert(not find(events, "heard:what time is it"), "heard after a second of quiet: " .. table.concat(events, " | "))
  p.mic = nil
  local p2 = parts({ { 0.2, 0 }, { 1.0, 1 }, { 2.0, 0 } }, 0.1)
  v = voice.new(p2)
  events = run(v, p2, 40)
  assert(find(events, "heard:what time is it"), "never gave up: " .. table.concat(events, " | "))
end

function T.talking_over_the_reply_stops_it_when_barge_in_is_on()
  local pieces = {}
  for i = 1, 40 do pieces[i] = "word " .. i .. ". " end
  local p, log = parts({ { 0.2, 0 }, { 1.0, 1 }, { 0.6, 0 }, { 0.3, 0 }, { 1.0, 1 }, { 2.0, 0 } }, 0.9, { pieces = pieces })
  local v = voice.new(p, { barge_in = true })
  local events = run(v, p, 60)
  local interrupted = find(events, "interrupted")
  assert(interrupted, table.concat(events, " | "))
  assert(p.speaker.cleared >= 1)
  assert(#log.spoken < 40, "it went on saying " .. #log.spoken)
  assert(v.history[2].role == "model" and v.history[3].role == "user", "the half-said reply is kept, then the new turn")
end

-- A mind in place of the reply (src/speech.lua is the real one): it is told when the person
-- starts and what they said, and it hands out what to say a sentence at a time.
local function fake_mind(o)
  o = o or {}
  local m = { out = {}, log = {}, thinking = false }
  function m:hearing() self.log[#self.log + 1] = "hearing" end
  function m:heard(t)
    self.log[#self.log + 1] = "heard:" .. t
    if t ~= "" then self.out = o.reply or { "It is noon.", "Anything else?" } end
  end
  function m:cut() self.log[#self.log + 1] = "cut"; self.out = {} end
  function m:take() return table.remove(self.out, 1) end
  function m:said() self.log[#self.log + 1] = "said" end
  function m:busy() return #self.out > 0 or self.thinking end
  function m:update() self.updates = (self.updates or 0) + 1 end
  return m
end

local function mind_parts(script, mind)
  local p, log = parts(script, 0.9)
  p.reply, p.mind = nil, mind
  return p, log
end

function T.a_mind_hears_the_turn_and_its_sentences_are_said()
  local mind = fake_mind()
  local p, log = mind_parts({ { 0.5, 0 }, { 1.0, 1 }, { 0.6, 0 } }, mind)
  local v = voice.new(p)
  local events = run(v, p, 60)
  assert(mind.log[1] == "hearing" and mind.log[2] == "heard:what time is it", table.concat(mind.log, " | "))
  assert(log.spoken[1] == "It is noon." and log.spoken[2] == "Anything else?")
  local said = 0
  for _, e in ipairs(mind.log) do if e == "said" then said = said + 1 end end
  assert(said == 2)
  assert(find(events, "said:It is noon.") < find(events, "done"), table.concat(events, " | "))
  assert(mind.updates and mind.updates >= 60, "the mind is given a slice every frame")
end

function T.a_mind_may_speak_when_nobody_asked()
  local mind = fake_mind()
  mind.out = { "Your report is in." }                     -- a job ended; nobody spoke
  local p, log = mind_parts({ { 1.0, 0 } }, mind)
  local v = voice.new(p)
  local events = run(v, p, 20)
  assert(log.spoken[1] == "Your report is in.")
  assert(find(events, "done"))
end

function T.the_person_is_heard_while_the_mind_is_still_thinking()
  local mind = fake_mind()
  mind.thinking = true                                   -- a reply is running, nothing to say yet
  local p = mind_parts({ { 0.2, 0 }, { 1.0, 1 }, { 0.8, 0 } }, mind)
  local v = voice.new(p)
  run(v, p, 40)
  assert(mind.log[1] == "hearing" and mind.log[2] == "heard:what time is it", table.concat(mind.log, " | "))
end

function T.talking_over_a_mind_cuts_it_when_barge_in_is_on()
  local long = {}
  for i = 1, 40 do long[i] = "word " .. i .. "." end
  local mind = fake_mind { reply = long }
  local p, log = mind_parts({ { 0.2, 0 }, { 1.0, 1 }, { 0.6, 0 }, { 0.3, 0 }, { 1.0, 1 }, { 2.0, 0 } }, mind)
  local v = voice.new(p, { barge_in = true })
  local events = run(v, p, 60)
  assert(find(events, "interrupted"), table.concat(events, " | "))
  local cut = false
  for _, e in ipairs(mind.log) do if e == "cut" then cut = true end end
  assert(cut and p.speaker.cleared >= 1)
  assert(#log.spoken < 40)
end

function T.a_host_wait_in_the_reply_spans_frames()
  local polls = 0
  local p, log = parts({ { 0.5, 0 }, { 1.0, 1 }, { 0.6, 0 } }, 0.9)
  p.reply = function (_, on_piece)
    coroutine.yield { wait = "host", poll = function ()
      polls = polls + 1
      return polls >= 3
    end }
    on_piece("It is noon. ")
  end
  local v = voice.new(p)
  local events = run(v, p, 60)
  assert(polls >= 3, "the reply was not polled across frames: " .. polls)
  assert(find(events, "said:It is noon."), table.concat(events, " | "))
  assert(#log.spoken == 1)
end

function T.a_mind_and_a_reply_are_one_or_the_other()
  local p = parts({ { 0.1, 0 } }, 0.9)
  p.mind = fake_mind()
  assert(not pcall(voice.new, p))
  p.reply, p.mind = nil, nil
  assert(not pcall(voice.new, p))
end

-- The real models, if they are here: jfk.wav into the VAD, the turn model and Moonshine
-- through the loop, and a stand-in reply. The turn is heard as Moonshine hears the clip.
local models = os.getenv("ML_MODELS") or here .. "/../console/ml/models"
local function have(name) local f = io.open(models .. "/" .. name, "rb"); if f then f:close() end; return f ~= nil end

if have "jfk.wav" and have "silero-vad.gguf" and have "smart-turn-v3.2.gguf" and have "moonshine-streaming-tiny-f32.gguf" then
  function T.jfk_is_heard_through_the_real_vad_turn_model_and_transcript()
    local cpu = ml.engine { device = "cpu", threads = 4 }
    local one = ml.engine { device = "cpu", threads = 1 }
    local x = ml.wav_read(models .. "/jfk.wav")
    local audio = ml.join(x, ml.buffer(16000 * 2))                -- and two seconds of quiet
    local at = 1
    local mic = { read = function ()
      if at > #audio then return ml.buffer(0) end
      local b = audio:slice(at, math.min(at + 1599, #audio)); at = at + #b; return b
    end }
    local v = voice.new {
      mic = mic,
      vad = require("console.ml.silero_vad").load(one, models .. "/silero-vad.gguf"),
      turn = require("console.ml.smart_turn").load(cpu, models .. "/smart-turn-v3.2.gguf"),
      asr = require("console.ml.moonshine").load(cpu, models .. "/moonshine-streaming-tiny-f32.gguf"),
      reply = function (_, on_piece) on_piece("Noted.") end,
    }
    local heard, partials = {}, 0
    v.on = function (e, d)
      if e == "heard" then heard[#heard + 1] = d end
      if e == "partial" then partials = partials + 1 end
    end
    for _ = 1, 200 do v:update() end
    local all = table.concat(heard, " ")
    assert(all:find("fellow Americans", 1, true) and all:find("for your country", 1, true), all)
    assert(partials >= 3, "the transcript came as the clip played: " .. partials .. " partials")
  end
end

return T
