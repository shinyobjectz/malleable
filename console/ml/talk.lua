-- talk — a spoken conversation from the terminal, every model in this process:
--
--     luajit console/ml/talk.lua [--models DIR] [--quiet] [--barge-in] [--system "..."]
--                                [--listen in.wav] [--out reply.wav]
--                                [--agent FILE [--root DIR]]
--
-- With --agent, the reply is not Gemma's: a talker answers (spec/speech.md), fast, and hands
-- the work to the agent in FILE (a .feature or a .lua declaration) as background jobs whose
-- reports it speaks when the person is not talking. The talker and the jobs reach their
-- model over the network (OPENROUTER_API_KEY); hearing and speaking stay in this process.
-- --root is the workspace the agent's tools see (default: the working directory).
--
-- The microphone, Silero VAD for speech, Moonshine for the words as they are said, Smart
-- Turn for whether the person has finished, Gemma 4 for the reply, Pocket TTS to say it, and
-- the speaker (console/ml/voice.lua does the joining). --quiet prints the reply instead of
-- saying it. --listen plays a WAV in as the microphone, at the pace it was spoken, and stops
-- after the reply; --out writes what the voice says to a WAV instead of the speaker. On a
-- Mac the terminal needs microphone access (System Settings, Privacy & Security,
-- Microphone), or the microphone hears silence; this says so if it does.

local root = (debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or ".") .. "/../.."
package.path = root .. "/?.lua;" .. root .. "/src/?.lua;" .. root .. "/bin/?.lua;" .. package.path

local ml = require "console.ml.engine"
local unpack = table.unpack or unpack
local voice = require "console.ml.voice"

local opts = { models = root .. "/console/ml/models", system = "You are a helpful voice assistant. Answer in one or two short spoken sentences, without lists or markdown." }
local i = 1
while arg[i] do
  local a = arg[i]
  if a == "--models" then opts.models = arg[i + 1]; i = i + 1
  elseif a == "--system" then opts.system = arg[i + 1]; i = i + 1
  elseif a == "--quiet" then opts.quiet = true
  elseif a == "--barge-in" then opts.barge_in = true
  elseif a == "--listen" then opts.listen = arg[i + 1]; i = i + 1
  elseif a == "--out" then opts.out = arg[i + 1]; i = i + 1
  elseif a == "--agent" then opts.agent = arg[i + 1]; i = i + 1
  elseif a == "--root" then opts.root = arg[i + 1]; i = i + 1
  else io.stderr:write("talk: what is " .. a .. "?\n"); os.exit(2) end
  i = i + 1
end

local function path(name)
  local p = opts.models .. "/" .. name
  local f = io.open(p, "rb")
  if not f then io.stderr:write("talk: no " .. p .. " (see console/ml/notes/ for where each model comes from)\n"); os.exit(1) end
  f:close()
  return p
end

local function say(s) io.write(s); io.flush() end

local t0 = ml.now()
local gpu = ml.engine { device = "auto", threads = 4 }
local one = ml.engine { device = "cpu", threads = 1 }            -- the VAD is too small for a GPU
say(("loading on %s ...\n"):format(gpu:device()))
local vad = require("console.ml.silero_vad").load(one, path "silero-vad.gguf")
local turn = require("console.ml.smart_turn").load(gpu, path "smart-turn-v3.2.gguf")
local asr = require("console.ml.moonshine").load(gpu, path "moonshine-streaming-small-f32.gguf")
local gemma = not opts.agent and require("console.ml.gemma4").load(gpu, path "gemma-4-E2B-it-q4_0.gguf", { context = 4096 })
local tts, speaker
if not opts.quiet then
  local pocket = require("console.ml.pocket_tts")
  local model = pocket.load(gpu, path "pocket-tts.gguf", { voice = path "pocket-tts-alba.gguf" })
  tts = { rate = model.rate or (model.hp and model.hp.rate) or 24000,
          speak = function (_, text, o) return model:speak(text, o) end }
  if opts.out then
    -- a speaker that keeps what it is given, and plays it as fast as it comes
    speaker = { parts = {}, write = function (s, b) s.parts[#s.parts + 1] = b; return #b end,
                queued = function () return 0 end, clear = function () end }
  else
    speaker = ml.speaker { rate = tts.rate }
    speaker:start()
  end
end
local mic
if opts.listen then
  -- a WAV as the microphone, at the pace it was spoken, then quiet
  local x, rate = ml.wav_read(opts.listen)
  if rate ~= 16000 then x = ml.resample(x, rate, 16000) end
  local start, given = ml.now(), 0
  mic = { read = function ()
    local due = math.floor((ml.now() - start) * 16000)
    if due <= given then return ml.buffer(0) end
    local b = given < #x and x:slice(given + 1, math.min(due, #x)) or ml.buffer(0)
    if due > #x then b = ml.join(b, ml.buffer(due - math.max(given, #x))) end
    given = due
    return b
  end, start = function () end, done = function () return given >= #x end }
else
  mic = ml.microphone { rate = 16000 }
end
mic:start()
say(("ready in %.1f s. Talk; Ctrl-C to stop.\n\n"):format(ml.now() - t0))

-- The conversation behind the voice: Gemma's reply, or a talker and the agent's jobs.
local mind, conversation
if opts.agent then
  local agent = require "agent"
  local f = io.open(opts.agent, "rb")
  if not f then io.stderr:write("talk: no " .. opts.agent .. "\n"); os.exit(1) end
  local text = f:read("*a"); f:close()
  if opts.agent:match("%.feature$") then
    local dir = opts.agent:match("^(.*)[/\\][^/\\]*$") or "."
    agent.declare(text, { read = function (p)
      local g = io.open(dir .. "/" .. p, "rb"); if not g then return nil, "no such file" end
      local t = g:read("*a"); g:close(); return t
    end })
  else
    dofile(opts.agent)
  end
  local w, why = require("world").ports { root = opts.root or ".", yielding = true }
  if not w then io.stderr:write("talk: " .. tostring(why) .. "\n"); os.exit(1) end
  conversation = agent.speech { world = w, clock = ml.now }
  mind = conversation
end

local v = voice.new({
  mic = mic, vad = vad, turn = turn, asr = asr, tts = tts, speaker = speaker,
  reply = not mind and voice.gemma_reply(gemma, { system = opts.system, max_tokens = 200 }) or nil,
  mind = mind,
}, { barge_in = opts.barge_in })

local line, heard_at = "", nil
local who = conversation and conversation.talker.name or "gemma"
v.on = function (event, data)
  if event == "partial" then line = data; say("\r\27[2Kyou: " .. data)
  elseif event == "heard" then
    heard_at = ml.now()
    say("\r\27[2Kyou: " .. data .. "\n" .. (conversation and "" or (who .. ": ")))
  elseif event == "reply" then
    if conversation then
      local took = heard_at and string.format(" (%.2f s)", ml.now() - heard_at) or ""
      heard_at = nil
      say(who .. took .. ": " .. data .. "\n")
    else
      say(data)
    end
  elseif event == "interrupted" then say(" [interrupted]\n")
  elseif event == "done" then
    if not conversation then say("\n\n") end
    if opts.listen and not conversation then
      if opts.out and speaker.parts and #speaker.parts > 0 then
        ml.wav_write(opts.out, ml.join(unpack(speaker.parts)), tts.rate)
        say("the reply is in " .. opts.out .. "\n")
      end
      os.exit(0)
    end
  end
end
if conversation then
  conversation.on = function (event, data)
    if event == "job" then
      if data.state == "running" and data.steps == 0 then say("  (" .. data.id .. " started: " .. data.worker .. ")\n")
      elseif data.state ~= "running" and data.state ~= "asking" and data.state ~= "starting" then
        say("  (" .. data.id .. " " .. data.state .. ", " .. data.steps .. " steps)\n")
      end
    elseif event == "question" then say("  (" .. data.id .. " asks to run " .. tostring(data.tool) .. ")\n")
    elseif event == "failed" then say("  (the talker failed: " .. tostring(data.reason) .. ")\n")
    end
  end
end

-- With --listen and a conversation, the run ends when the WAV has played, every job is
-- done and heard, and the voice is quiet.
local listened = nil
local function all_done()
  if not (opts.listen and conversation and mic.done and mic.done()) then return false end
  for _, j in ipairs(conversation:jobs()) do
    if j.state == "running" or j.state == "starting" or j.state == "asking" then return false end
  end
  if #conversation.reports > 0 or v:status() ~= "waiting" then listened = nil; return false end
  listened = listened or ml.now()
  return ml.now() - listened > 2
end

-- A microphone that hears nothing but zeros for two seconds has no permission.
local heard_anything, since = opts.listen ~= nil, ml.now()
local read = mic.read
v.mic = { read = function ()
  local b = read(mic)
  if not heard_anything and #b > 0 then
    local lo, hi = b:stats()
    if lo ~= 0 or hi ~= 0 then heard_anything = true end
    if not heard_anything and ml.now() - since > 2 then
      say("the microphone hears only silence: give this terminal microphone access, then run again\n")
      since = math.huge
    end
  end
  return b
end }

while true do
  v:update()
  if all_done() then
    if opts.out and speaker.parts and #speaker.parts > 0 then
      ml.wav_write(opts.out, ml.join(unpack(speaker.parts)), tts.rate)
      say("what the voice said is in " .. opts.out .. "\n")
    end
    os.exit(0)
  end
  ml.sleep(0.005)
end
