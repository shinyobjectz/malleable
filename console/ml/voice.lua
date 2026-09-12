-- voice — a spoken conversation on the console's engine: the microphone, a VAD that hears
-- speech start and stop, a transcript as the person talks, a model that decides whether
-- they have finished, a reply from a language model, and a voice that says the reply while
-- the microphone goes on listening.
--
--     local v = voice.new { mic = mic, speaker = spk, vad = vad, turn = turn, asr = asr,
--                           reply = voice.gemma_reply(gemma_model), tts = tts }
--     v.on = function (event, data) print(event, data) end
--     while true do v:update(); ml.sleep(0.01) end
--
-- update() does a slice of the work and returns, so a console frame never waits for a
-- whole reply: it reads what the microphone heard and runs the VAD over it, feeds speech
-- to the transcript, asks the turn model when the person pauses, and advances the reply
-- by one piece and the voice by one piece of audio.
--
-- The parts are plain objects, so any of them can be another model or a stand-in:
--
--   mic      :read() -> an ml.buffer of what was heard since the last read, 16 kHz mono
--   speaker  :write(buffer) -> samples taken; :queued() -> samples not yet played; :clear()
--   vad      :step(512 samples) -> p(speech)                   (console/ml/silero_vad.lua)
--   turn     :predict(samples) -> p(finished)                  (console/ml/smart_turn.lua)
--   asr      :stream() -> s; s:push(buffer) -> text so far; s:finish() -> the text
--   reply    function (history, on_piece) calls on_piece(text) for each piece of the reply
--   tts      :speak(text, { on_audio = function (buffer) end }); tts.rate, its sample rate
--   mind     in place of `reply`: a conversation that decides what is said (src/speech.lua,
--            spec/speech.md) -- :hearing(), :heard(text), :cut(), :take() -> a sentence or
--            nil, :said(), :busy(), :pending(), :update(). It may speak when nobody asked: a
--            job's report is said as soon as the floor is free.
--
-- Events, to v.on(event, data): "speech" (the person started talking), "partial" (the text
-- so far), "heard" (their turn's text), "reply" (a piece of the answer), "said" (a sentence
-- the voice finished saying), "interrupted" (the person talked over the reply), "done"
-- (the reply was said).

local ml = require "console.ml.engine"
local unpack = table.unpack or unpack
local ok_wait, wait = pcall(require, "wait")

local voice = {}

local RATE, WINDOW = 16000, 512
local WINDOW_S = WINDOW / RATE

local Voice = {}
Voice.__index = Voice

local DEFAULTS = {
  speech = 0.5,          -- the VAD's p above which a window is speech
  pause = 0.25,          -- seconds of quiet after speech before the turn model is asked
  give_up = 1.5,         -- seconds of quiet after which the turn is over whatever it says
  longest = 25,          -- seconds after which a turn ends even mid-sentence (a transcript's
                         -- caches hold a line of fixed length: Moonshine's 30 s by default)
  finished = 0.5,        -- the turn model's p above which the person has finished
  preroll = 0.3,         -- seconds before the VAD fired that the transcript still gets
  push_every = 0.16,     -- seconds of speech gathered before each push to the transcript
  barge_in = false,      -- talking over the reply stops it (needs headphones or echo cancelling)
  barge_windows = 3,     -- speech windows in a row that count as talking over the reply
  ahead = 1.0,           -- seconds of audio the voice may queue ahead of the speaker
}

--- A conversation over the parts. opts override DEFAULTS.
function voice.new(parts, opts)
  local v = setmetatable({ history = {}, state = "waiting" }, Voice)
  for k, d in pairs(DEFAULTS) do v[k] = (opts and opts[k] ~= nil) and opts[k] or d end
  for _, name in ipairs { "mic", "vad", "turn", "asr" } do
    if not parts[name] then error("voice: no " .. name, 2) end
    v[name] = parts[name]
  end
  v.reply, v.mind = parts.reply, parts.mind
  if not v.reply and not v.mind then error("voice: no reply, and no mind", 2) end
  if v.reply and v.mind then error("voice: a reply or a mind, not both", 2) end
  v.speaker, v.tts = parts.speaker, parts.tts
  if v.tts and not v.speaker then error("voice: a tts needs a speaker to say it on", 2) end
  v.pending = ml.buffer(0)             -- heard, not yet a whole window
  v.recent = {}                        -- the last windows, for the pre-roll
  v.on = function () end
  return v
end

local function emit(v, event, data) v.on(event, data) end

-- ------------------------------------------------------------------ listening

local function start_turn(v)
  v.state = "speaking"
  v.utterance = {}                     -- every window of this turn, for the turn model
  v.stream = v.asr:stream()
  v.unsent = {}
  for _, w in ipairs(v.recent) do v.utterance[#v.utterance + 1] = w; v.unsent[#v.unsent + 1] = w end
  v.quiet, v.length = 0, #v.recent * WINDOW_S
  if v.mind then v.mind:hearing() end
  emit(v, "speech")
end

local function push(v)
  if #v.unsent == 0 then return end
  local text = v.stream:push(ml.join(unpack(v.unsent)))
  v.unsent = {}
  if text and text ~= v.partial then v.partial = text; emit(v, "partial", text) end
end

local function end_turn(v)
  push(v)
  local text = v.stream:finish()
  v.stream, v.utterance, v.unsent, v.partial = nil, nil, nil, nil
  v.state = "waiting"
  if v.mind then
    if text and text:match("%S") then emit(v, "heard", text) end
    v.mind:heard(text or "")
    return
  end
  if text and text:match("%S") then
    emit(v, "heard", text)
    v.history[#v.history + 1] = { role = "user", text = text }
    v:answer()
  end
end

local function mouth_busy(v)
  return v.saying ~= nil or (v.speaker ~= nil and v.speaker:queued() > 0)
    or (v.mind ~= nil and v.mind.pending ~= nil and v.mind:pending())
end

local function interrupt(v)
  if v.mind then
    if not (mouth_busy(v) or v.mind:busy()) then return end
    v.saying, v.saying_wait = nil, nil
    if v.speaker then v.speaker:clear() end
    v.mind:cut()
    emit(v, "interrupted")
    return
  end
  if not v.answering then return end
  v.answering, v.answering_wait, v.saying, v.saying_wait, v.sentences = nil, nil, nil, nil, nil
  if v.speaker then v.speaker:clear() end
  if v.said and v.said:match("%S") then
    v.history[#v.history + 1] = { role = "model", text = v.said }
  end
  v.said = nil
  emit(v, "interrupted")
end

local function hear_window(v, w)
  local p = v.vad:step(w)
  local speech = p >= v.speech
  v.recent[#v.recent + 1] = w
  if #v.recent > math.ceil(v.preroll / WINDOW_S) then table.remove(v.recent, 1) end

  -- With a mind, the reply has the floor only while something is being said: the person may
  -- speak while the talker is still thinking, and their new turn replaces the reply.
  local holding = v.answering
  if v.mind then holding = mouth_busy(v) or (v.barge_in and v.mind:busy()) end
  if speech and holding then
    v.talking_over = (v.talking_over or 0) + 1
    if v.barge_in and v.talking_over >= v.barge_windows then interrupt(v) end
  elseif not speech then
    v.talking_over = 0
  end
  if holding and not v.barge_in then return end      -- the reply has the floor

  if v.state == "waiting" then
    if speech then start_turn(v) end
    return
  end
  -- speaking: every window is part of the turn, quiet ones too; the turn model hears 8 s
  v.utterance[#v.utterance + 1] = w
  if #v.utterance > 8 / WINDOW_S then table.remove(v.utterance, 1) end
  v.unsent[#v.unsent + 1] = w
  v.length = v.length + WINDOW_S
  if v.length >= v.longest then end_turn(v); return end
  if #v.unsent * WINDOW_S >= v.push_every then push(v) end
  if speech then v.quiet = 0; v.asked = nil; return end
  v.quiet = v.quiet + WINDOW_S
  if v.quiet >= v.give_up then end_turn(v); return end
  if v.quiet >= v.pause and not v.asked then
    v.asked = true
    local all = ml.join(unpack(v.utterance))
    if v.turn:predict(all) >= v.finished then end_turn(v) end
  end
end

local function listen(v)
  local heard = v.mic:read()
  if #heard == 0 then return end
  local buf = #v.pending > 0 and ml.join(v.pending, heard) or heard
  local n, at = #buf, 1
  while at + WINDOW - 1 <= n do
    hear_window(v, buf:slice(at, at + WINDOW - 1))
    at = at + WINDOW
  end
  v.pending = at <= n and buf:slice(at, n) or ml.buffer(0)
end

-- ------------------------------------------------------------------ answering

-- A sentence ends at . ! ? or a line break, followed by a space or the end: a unit the
-- voice can start saying while the rest of the reply is still being written.
local function next_sentence(text)
  local stop = text:find("[%.%!%?\n][%s\"')]", 1)
  if not stop then return nil, text end
  return text:sub(1, stop), text:sub(stop + 1)
end

--- Starts the reply to the history (called when a turn ends; a program may call it too).
function Voice:answer()
  local v = self
  v.said, v.sentences, v.answering_wait = "", {}, nil
  local text, written = "", ""
  v.answering = coroutine.create(function ()
    v.reply(v.history, function (piece)
      written = written .. piece
      text = text .. piece
      emit(v, "reply", piece)
      local s, rest = next_sentence(text)
      while s do
        if s:match("%S") then v.sentences[#v.sentences + 1] = s end
        text = rest
        s, rest = next_sentence(text)
      end
      coroutine.yield()
    end)
    if text:match("%S") then v.sentences[#v.sentences + 1] = text end
    v.written = written
  end)
end

local function speak_next(v)
  if not v.tts then                    -- no voice: the reply is said as soon as it is written
    local s = table.remove(v.sentences, 1)
    if s then v.said = v.said .. s; emit(v, "said", s) end
    return
  end
  local s = table.remove(v.sentences, 1)
  if not s then return end
  v.saying = coroutine.create(function ()
    v.tts:speak(s, { on_audio = function (samples)
      local at = 1
      while at <= #samples do
        local took = v.speaker:write(at == 1 and samples or samples:slice(at, #samples))
        at = at + took
        if at <= #samples then coroutine.yield() end            -- the speaker's queue is full
      end
      while v.speaker:queued() > v.ahead * v.tts.rate do coroutine.yield() end
      coroutine.yield()
    end })
    v.said = v.said .. s
    emit(v, "said", s)
  end)
end

local function resume(co, held)
  if held and ok_wait then
    local status, value = wait.ready(held)
    if status == "waiting" then return true, held end
    if status == "raised" then error(value, 0) end
    local ok, got = coroutine.resume(co, value)
    if not ok then error(got, 0) end
    if type(got) == "table" and wait.kind(got) == wait.HOST then return true, got end
    return coroutine.status(co) ~= "dead", nil
  end
  local ok, got = coroutine.resume(co)
  if not ok then error(got, 0) end
  if ok_wait and type(got) == "table" and wait.kind(got) == wait.HOST then
    return true, got
  end
  return coroutine.status(co) ~= "dead", nil
end

local function step_co(v, name)
  local co = v[name]
  if not co then return false end
  local going, held = resume(co, v[name .. "_wait"])
  v[name .. "_wait"] = held
  if not going then
    if name ~= "answering" then
      v[name] = nil
      v[name .. "_wait"] = nil
    end
    return false
  end
  return true
end

local function advance(v)
  if not v.answering then return end
  if coroutine.status(v.answering) ~= "dead" then step_co(v, "answering") end
  if v.saying then
    step_co(v, "saying")
  elseif #v.sentences > 0 then
    speak_next(v)
    if v.saying then step_co(v, "saying") end
  end
  local writing = coroutine.status(v.answering) ~= "dead"
  local playing = v.speaker and v.speaker:queued() > 0
  if not writing and not v.saying and #v.sentences == 0 and not playing then
    v.history[#v.history + 1] = { role = "model", text = v.written or v.said }
    v.answering, v.answering_wait, v.said, v.sentences, v.written = nil, nil, nil, nil, nil
    emit(v, "done")
  end
end

-- With a mind: the mind decides what is said, a sentence at a time, and is told when each
-- was said. "done" is the mouth falling quiet with nothing left to say.
local function speak_mind(v)
  local m = v.mind
  m:update()
  if v.saying then
    if not step_co(v, "saying") then
      m:said()
      emit(v, "said", v.sentence)
    end
    return
  end
  local s = m:take()
  if s then
    v.sentence = s
    v.spoke = true
    emit(v, "reply", s)
    if not v.tts then m:said(); emit(v, "said", s); return end
    v.saying = coroutine.create(function ()
      v.tts:speak(s, { on_audio = function (samples)
        local at = 1
        while at <= #samples do
          local took = v.speaker:write(at == 1 and samples or samples:slice(at, #samples))
          at = at + took
          if at <= #samples then coroutine.yield() end
        end
        while v.speaker:queued() > v.ahead * v.tts.rate do coroutine.yield() end
        coroutine.yield()
      end })
    end)
    if not step_co(v, "saying") then m:said(); emit(v, "said", s) end
    return
  end
  if v.spoke and not m:busy() and not mouth_busy(v) then
    v.spoke = nil
    emit(v, "done")
  end
end

--- One slice of the conversation: call it every frame.
function Voice:update()
  listen(self)
  if self.mind then speak_mind(self) else advance(self) end
end

--- Stops the reply being said, as talking over it does with barge-in: a Stop button.
function Voice:interrupt()
  interrupt(self)
end

--- Whether the person is talking, a reply is being written or said, or neither.
function Voice:status()
  if self.answering or (self.mind and (self.mind:busy() or mouth_busy(self))) then return "answering" end
  return self.state == "speaking" and "listening" or "waiting"
end

-- ------------------------------------------------------------------ parts

--- A reply function over a gemma4 model: the history as a chat, the pieces as they come.
--- opts: { system = "...", max_tokens = 256, temperature = 1, seed }
function voice.gemma_reply(model, opts)
  opts = opts or {}
  return function (history, on_piece)
    local messages = {}
    if opts.system then messages[1] = { role = "system", text = opts.system } end
    for _, m in ipairs(history) do messages[#messages + 1] = m end
    return model:chat(messages, { max_tokens = opts.max_tokens or 256, temperature = opts.temperature,
                                  seed = opts.seed, on_piece = on_piece })
  end
end

return voice
