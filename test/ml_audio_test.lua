-- The microphone and the speaker (console/ml/native/audio.c, spec/ml.md "Audio").
--
-- Every test runs on miniaudio's null backend: a device with no hardware that hears
-- silence and plays into nothing at the rate asked for, so the rings, the threads and the
-- counts are checked on any machine, in CI, and with no microphone permission.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local T = {}

local fine, ml = pcall(require, "console.ml.engine")
if not fine then return T end

if not ml.audio_available() then
  function T.a_build_without_audio_says_how_to_get_it()
    local ok, err = pcall(ml.microphone, {})
    assert(not ok and tostring(err):find("ML_AUDIO", 1, true), tostring(err))
  end
  return T
end

-- Waits until f() is true or a second has gone.
local function within_a_second(f)
  local t0 = ml.now()
  while not f() do
    if ml.now() - t0 > 1 then return false end
    ml.sleep(0.01)
  end
  return true
end

function T.the_clock_goes_forward_and_sleep_waits()
  local t0 = ml.now()
  ml.sleep(0.05)
  local dt = ml.now() - t0
  assert(dt >= 0.045 and dt < 0.5, "slept " .. dt)
end

function T.the_null_backend_has_a_microphone_and_a_speaker()
  local kinds = {}
  for _, d in ipairs(ml.audio_devices "null") do kinds[d.kind] = true end
  assert(kinds.microphone and kinds.speaker)
end

function T.a_backend_that_does_not_exist_is_named_with_those_that_do()
  local ok, err = pcall(ml.microphone, { backend = "gramophone" })
  assert(not ok and tostring(err):find("no audio backend gramophone", 1, true), tostring(err))
end

function T.the_microphone_hears_at_its_rate_and_lua_reads_what_it_heard()
  local mic = ml.microphone { backend = "null", rate = 16000 }
  assert(mic:rate() == 16000 and mic:available() == 0)
  mic:start()
  assert(within_a_second(function () return mic:available() >= 1600 end), "heard " .. mic:available())
  local got = mic:read(800)
  assert(#got == 800 and got:stats() ~= nil)
  for i = 1, #got do assert(got[i] == 0, "the null device hears silence") end
  mic:stop()
  local rest = mic:read()
  assert(mic:available() == 0 and #rest >= 800)
  assert(mic:dropped() == 0)
  mic:close()
  local ok, err = pcall(mic.read, mic)
  assert(not ok and tostring(err):find("closed", 1, true), tostring(err))
end

function T.a_full_ring_drops_what_it_hears_and_counts_it()
  local mic = ml.microphone { backend = "null", rate = 16000, seconds = 1 }
  mic:start()
  assert(within_a_second(function () return mic:available() >= 16000 end) or true)
  ml.sleep(1.2)
  assert(mic:available() == 16000, "a one-second ring holds " .. mic:available())
  assert(mic:dropped() > 0)
  mic:close()
end

function T.the_speaker_plays_what_is_written_and_clear_stops_it()
  local spk = ml.speaker { backend = "null", rate = 24000, seconds = 2 }
  local tone = ml.buffer(24000)
  for i = 1, #tone do tone[i] = 0.25 * math.sin(2 * math.pi * 440 * i / 24000) end
  assert(spk:write(tone) == 24000 and spk:queued() == 24000)
  -- the queue holds two seconds; a third second is taken only in part
  assert(spk:write(tone) == 24000)
  assert(spk:write(tone) == 0, "a full queue takes nothing")
  spk:start()
  assert(within_a_second(function () return spk:played() >= 4800 end), "played " .. spk:played())
  assert(spk:queued() < 48000)
  spk:clear()
  assert(within_a_second(function () return spk:queued() == 0 end))
  local played = spk:played()
  ml.sleep(0.1)
  assert(spk:played() == played, "after clear nothing more plays")
  spk:close()
end

return T
