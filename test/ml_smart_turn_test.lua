-- Smart Turn v3.2 on the console's engine (console/ml/smart_turn.lua), against pipecat's
-- fp32 ONNX model.
--
-- The reference is smart-turn-v3.2-gpu.onnx from huggingface.co/pipecat-ai/smart-turn-v3,
-- run by onnxruntime 1.19 on features from transformers' WhisperFeatureExtractor
-- (chunk_length 8) after pipecat's truncate_audio_to_last_n_seconds, on the prefixes of
-- whisper.cpp's samples/jfk.wav of 1 to 11 s: the decision at each pause point (the script
-- is in console/ml/notes/smart_turn.md, section 10). On the CPU the model agrees to about
-- 2e-6. Metal multiplies large matrices from half-precision tiles, so it agrees to a few
-- ten-thousandths. Without the weights and jfk.wav (console/ml/models/, or ML_MODELS) or
-- the engine, nothing runs.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local T = {}

local fine, ml = pcall(require, "console.ml.engine")
local models = os.getenv("ML_MODELS") or here .. "/../console/ml/models"
local path, wav_path = models .. "/smart-turn-v3.2.gguf", models .. "/jfk.wav"
local function exists(p) local f = io.open(p, "rb"); if f then f:close() end return f ~= nil end
if not fine or not exists(path) or not exists(wav_path) then return T end
local smart = require "console.ml.smart_turn"

-- The ONNX model's p(finished) for jfk.wav's first 1, 2, ... 11 seconds.
local ONNX = { 0.0060647, 0.0064680, 0.9863093, 0.0052871, 0.0717439, 0.1747333,
               0.0072100, 0.0200511, 0.0135888, 0.0195090, 0.9486192 }

local wav = ml.wav_read(wav_path)

local function against_onnx(m, tol, where)
  for s = 1, #ONNX do
    local p = m:predict(wav:slice(1, s * 16000))
    assert(math.abs(p - ONNX[s]) <= tol,
      string.format("%s: after %d s p is %.7f, the ONNX model %.7f (tolerance %g)", where, s, p, ONNX[s], tol))
    assert((p > 0.5) == (ONNX[s] > 0.5), where .. ": the decision after " .. s .. " s")
  end
end

-- The features are the extractor's, to its own float32 rounding: the whole clip (its last
-- 8 s) and the 1 s prefix, whose first 7 s are padding at the -8 floor.
function T.the_features_are_whisper_feature_extractors()
  local m = smart.load(ml.engine { device = "cpu" }, path)
  local f = m:features(wav)
  assert(#f == 80 * 800, "features: " .. #f)
  local mn, mx, mean = f:stats()
  assert(math.abs(mn - -0.107879) < 1e-5 and math.abs(mx - 1.892121) < 1e-5 and math.abs(mean - 0.577721) < 1e-5,
    string.format("min %.6f max %.6f mean %.6f", mn, mx, mean))
  local at = function (mel, frame) return f[mel * 800 + frame + 1] end
  for _, want in ipairs { { 0, 799, 0.6126942 }, { 79, 400, -0.1078790 }, { 40, 100, 0.6420803 }, { 10, 650, 1.5564628 } } do
    local got = at(want[1], want[2])
    assert(math.abs(got - want[3]) < 5e-5, string.format("mel %d frame %d is %.7f, the extractor %.7f", want[1], want[2], got, want[3]))
  end
  f = m:features(wav:slice(1, 16000))
  for _, frame in ipairs { 0, 300, 599 } do
    assert(math.abs(f[40 * 800 + frame + 1] - 0.022983) < 1e-5, "the padding's floor at frame " .. frame)
  end
  m:free()
end

function T.on_the_cpu_p_is_the_onnx_models()
  local m = smart.load(ml.engine { device = "cpu", threads = 8 }, path)
  against_onnx(m, 1e-5, "cpu")
  m:free()
end

-- Only the last 8 s are heard; a turn given as a list of numbers is the same turn.
function T.a_turn_is_its_last_eight_seconds()
  local m = smart.load(ml.engine { device = "cpu", threads = 8 }, path)
  local whole = m:predict(wav)
  assert(m:predict(wav:slice(#wav - 128000 + 1, #wav)) == whole, "the last 8 s alone")
  local short = wav:slice(1, 800)
  assert(m:predict(short:table()) == m:predict(short), "a list and a buffer")
  local silent = m:predict(ml.buffer(0))
  assert(silent >= 0 and silent <= 1, "an empty turn: " .. tostring(silent))
  m:free()
end

function T.on_the_device_p_is_within_its_rounding()
  local e = ml.engine { device = "auto", threads = 8 }
  if e:device() == "CPU" then return end
  local m = smart.load(e, path)
  against_onnx(m, 2e-3, e:device())
  assert(m.graph:splits() == 1, e:device() .. ": the graph was cut in " .. m.graph:splits())
  m:free()
end

return T
