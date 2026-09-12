-- Pocket TTS on the console's engine (console/ml/pocket_tts.lua), against the official
-- Python package, kyutai-labs/pocket-tts at 0c2db3b, on the same weights.
--
-- The reference numbers come from three places: the tokenizer ids and the temperature-0
-- run from the package itself (`TTSModel.load_model(temp=0)`, the alba voice, "Hello
-- world, this is a test.", every latent and every sample recorded, one Mimi frame per
-- call); the layer-0 voice K and V, and the Mimi decoder's outputs for a made-up latent,
-- from console/ml/notes/pocket_tts.md, 13.1 and 13.2. On the CPU the port does the same
-- f32 arithmetic, so it agrees to the last digits printed and drifts only as far as an
-- autoregressive run of 25 frames lets rounding drift. A GPU rounds more: Metal's f32
-- matrix product keeps its tiles in f16, so the Mimi decoder there agrees to a few
-- parts in ten thousand. Without the weights (console/ml/models/, or ML_MODELS) or the
-- engine, nothing runs.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local T = {}

local fine, ml = pcall(require, "console.ml.engine")
local dir = os.getenv("ML_MODELS") or here .. "/../console/ml/models"
local MODEL, VOICE = dir .. "/pocket-tts.gguf", dir .. "/pocket-tts-alba.gguf"
local function exists(path) local f = io.open(path, "rb") if f then f:close() end return f ~= nil end
if not fine or not exists(MODEL) or not exists(VOICE) then return T end
local pocket = require "console.ml.pocket_tts"

-- One model per device for the file: loading takes a moment.
local loaded = {}
local function model(device)
  if not loaded[device] then
    local e = ml.engine { device = device, threads = 8 }
    loaded[device] = pocket.load(e, MODEL, { voice = VOICE })
  end
  return loaded[device]
end

local function near(got, want, tol, what)
  assert(math.abs(got - want) <= tol, string.format("%s: %.8g, the reference %.8g (tolerance %g)", what, got, want, tol))
end

local function each_near(buffer, from, want, tol, what)
  for i, w in ipairs(want) do near(buffer[from + i - 1], w, tol, what .. " [" .. (from + i - 2) .. "]") end
end

local function sum(b, i, j, abs)
  local s = 0
  for k = i, j do s = s + (abs and math.abs(b[k]) or b[k]) end
  return s
end

-- ------------------------------------------------------------------ text

-- What the package's prepare_text_prompt and SentencePiece answer for each (notes, 3).
local TEXTS = {
  { "Hello world, this is a test.", "Hello world, this is a test.", 3, "2994 578 262 285 277 267 1115 263" },
  { "hello world", "Hello world.", 5, "2994 578 263" },
  { "It costs $3.50 today", "It costs $3.50 today.", 5, "333 1649 261 1124 450 263 437 316 630 263" },
  { "Caf\195\169 na\195\175ve \226\128\147 2026\229\185\180", "Caf\195\169 na\195\175ve \226\128\147 2026\229\185\180.", 5,
    "1130 601 745 913 199 179 314 260 3977 260 365 316 365 543 233 189 184 263" },
  { "a    b   c", "A  b  c.", 5, "383 260 557 260 331 263" },
  { 'He said "hi"', 'He said "hi".', 5, "414 425 694 1449 3877 263" },
  { "Hello world. I am Kyutai's Pocket TTS. I'm fast enough to run on small CPUs. I hope you'll like me.",
    "Hello world. I am Kyutai's Pocket TTS. I'm fast enough to run on small CPUs. I hope you'll like me.", 3,
    "2994 578 263 268 686 862 327 805 1537 264 261 1456 603 597 602 854 640 263 268 264 283 1420 260 747 266 " ..
    "791 288 860 444 759 1917 261 263 268 818 270 264 335 282 308 263" },
}

function T.the_text_is_prepared_as_the_reference_prepares_it()
  for _, c in ipairs(TEXTS) do
    local text, after = pocket.prepare(c[1])
    assert(text == c[2], ("%q became %q, the reference %q"):format(c[1], text, c[2]))
    assert(after == c[3], ("%q keeps %d frames after EOS, the reference %d"):format(c[1], after, c[3]))
  end
end

function T.the_tokens_are_sentencepieces()
  local tts = model "cpu"
  for _, c in ipairs(TEXTS) do
    local ids = table.concat(tts:encode(c[2]), " ")
    assert(ids == c[4], ("%q: %s, the reference %s"):format(c[2], ids, c[4]))
  end
end

function T.a_long_text_is_spoken_in_the_references_chunks()
  local tts = model "cpu"
  local fox = "The quick brown fox jumps over the lazy dog."
  local text = (fox .. " "):rep(6) .. "Then it sleeps, dreams, and wakes up; finally: it runs away!"
  local chunks = tts:chunks(text)
  local three = fox .. " " .. fox .. " " .. fox
  assert(#chunks == 3, #chunks .. " chunks")
  assert(chunks[1] == three and chunks[2] == three, chunks[1])
  assert(chunks[3] == "Then it sleeps, dreams, and wakes up; finally: it runs away!", chunks[3])
  assert(#tts:encode(chunks[1]) == 42 and #tts:encode(chunks[3]) == 21)
  -- a decimal point is not the end of a sentence
  local one = tts:chunks("It costs $3.50 today")
  assert(#one == 1 and one[1] == "It costs $3.50 today.", one[1])
end

-- ------------------------------------------------------------------ the voice

-- Layer 0, position 0, head 0, values 0..7: the BOS before the voice (notes, 13.1).
local VOICE_K = { -0.00832703, -0.00160593, -0.00400324, 0.00542767, -0.00520538, 0.00725109, 0.00412817, 0.00337402 }
local VOICE_V = { -0.00492142, -0.00129018, 0.00767036, 0.01448909, -0.00316598, 0.09348, 0.00117009, -0.00604142 }

function T.the_voice_puts_layer_0s_k_and_v_at_position_0()
  local tts = model "cpu"
  local k, v = tts:cached(0, 0)
  each_near(k, 1, VOICE_K, 5e-8, "K")      -- the notes' 8 decimals of the same sum, in torch
  each_near(v, 1, VOICE_V, 5e-8, "V")
  -- and they are the weights' own: in_proj's K and V rows of LayerNorm(bos_before_voice)
  local L = tts.layers[0]
  local g = tts.engine:graph()
  local h = g:add(g:mul(g:norm(tts.bos_before_voice, 1e-5), L.norm1_w), L.norm1_b)
  local qkv = g:mul_mat(L.qkv, h)
  g:compute(qkv)
  local x = g:read(qkv)
  -- (1024-long f32 dot products, summed in another order than torch's: a few ulps)
  assert(ml.max_diff(x:slice(1025, 2048), k) < 2e-6, "K is not in_proj's K of the BOS: " .. ml.max_diff(x:slice(1025, 2048), k))
  assert(ml.max_diff(x:slice(2049, 3072), v) < 2e-6, "V is not in_proj's V of the BOS: " .. ml.max_diff(x:slice(2049, 3072), v))
  g:free()
end

-- ------------------------------------------------------------------ the Mimi decoder

-- zn[f][d] = 0.8 sin(0.37 (f+1)(d+1)), and what the reference's modules make of it,
-- frame 0: (channels, values at channel 0 and channel 1 for steps 0..3, mean |x|, steps).
local function made_up(frames)
  local b = ml.buffer(32 * frames)
  for f = 0, frames - 1 do for d = 0, 31 do b[f * 32 + d + 1] = 0.8 * math.sin(0.37 * (f + 1) * (d + 1)) end end
  return b
end

local STAGES = {
  quantizer = { 512, { -1.9873593 }, { 0.4595907 }, 0.469209, 1 },
  upsample = { 512, { -0.5705895, -0.5511817, -0.504603, -0.477432 }, { 0.0700158, 0.0682205, 0.0464528, 0.0446575 }, 0.0531166, 16 },
  transformer = { 512, { -0.5375092, -0.5584011, -0.5433848, -0.5339487 }, { -0.4323802, 0.08497, 0.1439926, 0.2058088 }, 0.408421, 16 },
  conv_in = { 512, { -0.9837393, -2.026342, -2.0650342, -2.3386045 }, { -0.5023116, -1.1848223, -1.5860629, -2.0385628 }, 2.31033, 16 },
  ["up.1"] = { 256, { 0.555433, 0.463955, 0.3019074, 0.0914273 }, { -0.2175322, 0.456852, -0.4226618, 0.3146947 }, 1.57258, 96 },
  ["res.1"] = { 256, { 1.8373127, 1.5507765, 1.3935964, 0.9669604 }, { 0.2854988, 0.9475849, 0.0740229, 0.8126237 }, 1.63349, 96 },
  ["up.2"] = { 128, { 0.0973223, 0.2289094, 0.0820317, 0.1802865 }, { 0.1944223, 0.0094079, 0.0599547, 0.1475576 }, 0.44557, 480 },
  ["up.3"] = { 64, { -0.3427803, -0.3518591, -0.3240042, -0.301523 }, { -0.0973823, -0.1331523, -0.1608749, -0.1580625 }, 0.252023, 1920 },
}

local function stage_taps()
  local taps = {}
  for name in pairs(STAGES) do taps[name] = true end
  return taps
end

local function against_the_stages(taps, tol, where)
  for name, s in pairs(STAGES) do
    local b, C = taps[name], s[1]
    for t = 1, #s[2] do
      near(b[(t - 1) * C + 1], s[2][t], tol, where .. " " .. name .. " channel 0 step " .. (t - 1))
      near(b[(t - 1) * C + 2], s[3][t], tol, where .. " " .. name .. " channel 1 step " .. (t - 1))
    end
    near(sum(b, 1, C * s[5], true) / (C * s[5]), s[4], s[4] * 1e-5 + tol, where .. " " .. name .. " mean |x|")
  end
end

-- The samples of the made-up latents, 20 frames: the first 12, 1000.., frame 1, frame 19
-- (after the 250-step window first drops a key), and sums.
local function against_the_samples(a, tol, sum_tol, where)
  each_near(a, 1, { 0.0005371, 0.0021438, 0.0038239, 0.0031311, -0.0001629, -0.0031992, -0.0074632, -0.0105186,
                    -0.0111194, -0.0128237, -0.0133886, -0.0132442 }, tol, where .. " audio")
  each_near(a, 1001, { 0.0168021, 0.0154555, 0.014058, 0.0126015, 0.0111655, 0.0097504 }, tol, where .. " audio")
  each_near(a, 1921, { 0.0537098, 0.0520044, 0.0502825, 0.0479068, 0.0443647, 0.0395277 }, tol, where .. " audio")
  each_near(a, 36481, { -0.0177266, -0.0165139, -0.0153342, -0.0135595, -0.0118193, -0.0105901 }, tol, where .. " audio")
  near(sum(a, 1, 1000), -3.9979455, sum_tol, where .. " sum of samples 0..999")
  near(sum(a, 1, 1000, true), 20.417957, sum_tol, where .. " sum of |samples| 0..999")
  near(sum(a, 36481, 38400), -7.0774136, sum_tol, where .. " sum of frame 19")
  near(sum(a, 36481, 38400, true), 29.585445, sum_tol, where .. " sum of |frame 19|")
  local _, _, _, rms = a:slice(1, 7680):stats()
  near(rms, 0.0236475, sum_tol * 1e-2, where .. " rms of frames 0..3")
end

local function frame_by_frame(tts, z, frames, taps)
  tts:mimi_reset()
  local out = {}
  for f = 1, frames do out[f] = tts:decode(z:slice((f - 1) * 32 + 1, f * 32), f == 1 and taps or nil) end
  return ml.join((table.unpack or unpack)(out))
end

function T.frame_by_frame_the_mimi_decoder_answers_the_reference()
  local tts = model "cpu"
  local taps = stage_taps()
  local a = frame_by_frame(tts, made_up(20), 20, taps)
  assert(#a == 20 * 1920, #a .. " samples")
  against_the_stages(taps, 3e-6, "cpu")
  -- sums of 1920 samples near 7 and 29: 1e-5 is the order another CPU's kernels add in
  against_the_samples(a, 5e-7, 1e-5, "cpu")
end

function T.all_at_once_the_mimi_decoder_answers_what_it_does_frame_by_frame()
  local tts = model "cpu"
  local z = made_up(20)
  local frames = frame_by_frame(tts, z, 20)
  local taps = stage_taps()
  local whole = tts:decode_all(made_up(4), taps)
  against_the_stages(taps, 3e-6, "cpu, all at once")
  assert(ml.max_diff(whole, frames:slice(1, 4 * 1920)) <= 1e-7, "4 frames at once: " .. ml.max_diff(whole, frames:slice(1, 4 * 1920)))
  local all = tts:decode_all(z)
  assert(ml.max_diff(all, frames) <= 1e-6, "20 frames at once: " .. ml.max_diff(all, frames))
  -- and the decoder goes on frame by frame from where the whole decode left it
  tts:decode_all(made_up(4))
  local next = tts:decode(z:slice(4 * 32 + 1, 5 * 32))
  assert(ml.max_diff(next, frames:slice(4 * 1920 + 1, 5 * 1920)) <= 1e-7, "frame 4 after a whole decode")
end

-- ------------------------------------------------------------------ speaking

-- "Hello world, this is a test." in alba's voice at temperature 0: the reference's
-- latents (normalised) at frames 0, 1, 12 and 24, its EOS logit at every step, and its
-- samples. EOS fires at step 22 and three frames follow: 25 frames, 48,000 samples.
local LATENTS = {
  [0] = { -0.52808964, 0.32488334, -0.24332158, 0.26649165, 0.032998227, 0.92161757, -0.066416711, -0.016707566 },
  [1] = { 0.35816497, -0.54307216, -0.68455601, 0.15917018, -0.45170185, -0.24701592, 1.2759132, -0.71942556 },
  [12] = { -2.6807342, -0.71741784, 0.13140728, 0.75275642, -0.17500938, 1.2363602, -0.2611973, -0.18681967 },
  [24] = { -3.4991095, -0.61845505, -0.049061492, 0.35107797, -1.0309039, 1.7432934, -0.3929252, -0.24429689 },
}
local EOS = { -9.8390503, -10.031678, -10.709244, -10.964396, -11.240232, -10.227093, -10.751949, -11.485361, -11.603086,
              -12.231365, -12.518971, -11.893404, -12.785193, -11.123152, -10.790606, -11.221783, -11.112177, -9.6685829,
              -6.9273643, -6.3169899, -7.2783966, -4.9839668, 3.8605735, 7.6583233, 6.8497138, 6.8346534 }
local SAMPLES = { 0.0010954428, 0.0037776458, 0.0071348795, 0.0083660586, 0.0064289793, 0.0045787757, 0.0017192811,
                  0.00016693145, 0.0013172132, 0.0012164128, 0.0021701443, 0.0029546642 }
local FRAME_1 = { -0.029815789, -0.031189701, -0.0078469915, -0.023597244, -0.015743874, -0.02163052 }
local PROMPT_COND = { -0.37945205, 0.04091613, 0.38216451, 0.33464572, 0.82202899, -0.39633191 }

-- The temperature-0 run, one step and one frame at a time; tolerances: the first latent,
-- the rest, EOS, the first frame's samples, frame 1's, and the sums over all 48,000.
local function speaks_as_the_reference(tts, tol)
  local ids = tts:encode((pocket.prepare("Hello world, this is a test.")))
  each_near(tts:start(ids, 59), 1, PROMPT_COND, tol.first, "the prompt's out_norm")
  tts:mimi_reset()
  local zeros, latent, parts = ml.buffer(32), nil, {}
  for step = 0, 25 do
    local eos
    latent, eos = tts:step(latent, zeros)
    near(eos, EOS[step + 1], tol.eos, "the EOS logit at step " .. step)
    if LATENTS[step] then each_near(latent, 1, LATENTS[step], step == 0 and tol.first or tol.latent, "latent " .. step) end
    if step < 25 then parts[#parts + 1] = tts:decode(latent) end
  end
  local a = ml.join((table.unpack or unpack)(parts))
  each_near(a, 1, SAMPLES, tol.audio, "the samples")
  each_near(a, 1921, FRAME_1, tol.frame_1, "frame 1's samples")
  near(sum(a, 1, #a), -2.1942592, tol.sum, "the sum of the samples")
  near(sum(a, 1, #a, true), 2148.9478, tol.sum * 10, "the sum of |samples|")

  -- speak says the same, frame by frame as it decodes them
  local heard = {}
  local samples, info = tts:speak("Hello world, this is a test.", { temperature = 0,
    on_audio = function (frame) heard[#heard + 1] = frame end })
  assert(info.frames == 25 and info.eos[1] == 22, info.frames .. " frames, EOS at " .. tostring(info.eos[1]))
  assert(#samples == 48000 and #heard == 25 and #heard[1] == 1920, #samples .. " samples in " .. #heard .. " frames")
  assert(ml.max_diff(ml.join((table.unpack or unpack)(heard)), samples) == 0, "on_audio heard other samples")
  each_near(samples, 1, SAMPLES, tol.audio, "speak's samples")
  near(sum(samples, 1, #samples, true), 2148.9478, tol.sum * 10, "speak's sum of |samples|")
  assert(info.first_audio < info.seconds)
end

function T.at_temperature_0_the_cpu_speaks_as_the_reference()
  speaks_as_the_reference(model "cpu", { first = 5e-6, latent = 1e-3, eos = 1e-3, audio = 1e-5, frame_1 = 1e-4, sum = 0.02 })
end

-- At temperature 0 the flow head starts from zero; at 0.3 from noise. The reference's
-- first two draws (torch.manual_seed(1234)), given as the noise, give its first latents.
local NOISE = {
  { -0.81877714, 0.48252231, -0.64557183, -0.51157022, -0.31085747, -0.15184388, -1.1958961, 0.20091908, 0.51377892,
    0.0042812647, -0.17190847, -0.63355309, 1.0082793, -0.55727065, 0.66780591, 0.087705038, 0.87553322, -0.025666472,
    -0.83636802, -1.1032526, -0.83104086, 0.21237497, -0.64897209, 0.37774998, 0.72474176, 0.99517739, 0.37287065,
    0.39675161, 0.017697299, -0.90882355, -1.0282556, 0.40380627 },
  { 0.50704998, 0.50647694, 0.099978887, -0.040365927, 0.17235649, -0.56793398, 0.11504447, 0.33653581, 0.034394711,
    -0.18057024, -0.98424011, 0.47806194, 0.42008385, -0.062320534, -0.51640344, 0.41299495, 0.077080153, -0.37994814,
    -0.33733886, -0.39959058, 0.23597546, 0.15676008, -0.13590254, 0.11171224, 0.46659014, -0.77238792, -0.058662135,
    -0.43917015, 0.15175983, 1.4021298, -0.92848569, 0.1032644 },
}
local NOISY = {
  { -0.7866528, 0.50289035, -0.42561686, 0.42664129, 0.076530099, 0.92511749, -0.066501856, -0.0027381331 },
  { 0.62784916, -0.82360119, -0.59104472, 0.2154772, -0.14676574, -0.62148243, 1.1652837, -1.0047566 },
}

function T.from_the_references_noise_the_flow_head_makes_its_latents()
  local tts = model "cpu"
  tts:start(tts:encode((pocket.prepare("Hello world, this is a test."))), 59)
  local latent
  for step = 1, 2 do
    latent = tts:step(latent, ml.buffer(NOISE[step]))
    each_near(latent, 1, NOISY[step], step == 1 and 5e-6 or 5e-5, "latent " .. (step - 1) .. " at temperature 0.3")
  end
end

-- Metal rounds a matrix product's operands to f16 only for wide products. CUDA runs every
-- f32 product in TF32 (ten bits of mantissa; ggml sets it), and the latents feed the next
-- step, so the error grows with the steps: a table of its own.
local DEVICE_ROUNDING = {
  metal = { speak = { first = 5e-5, latent = 1e-3, eos = 1e-3, audio = 1e-3, frame_1 = 2e-3, sum = 0.05 },
            stages = 2e-3, samples = 1e-4, samples_sum = 0.02 },
  -- measured on an RTX 4070: latents 4.3e-3 by step 24, the EOS logit 0.05 (its threshold
  -- is -4, far from the -7 to -10 it drifts around), stages 2.4e-3, samples 1.6e-5
  cuda = { speak = { first = 1e-3, latent = 1e-2, eos = 0.1, audio = 5e-3, frame_1 = 1e-2, sum = 0.25 },
           stages = 1e-2, samples = 5e-4, samples_sum = 0.1 },
}

function T.on_the_device_it_speaks_as_the_reference_within_its_rounding()
  local tts = model "auto"
  local device = tts.engine:device()
  if device == "CPU" then return end
  local tol = device:match("^CUDA") and DEVICE_ROUNDING.cuda or DEVICE_ROUNDING.metal
  speaks_as_the_reference(tts, tol.speak)
  local taps = stage_taps()
  local a = frame_by_frame(tts, made_up(20), 20, taps)
  against_the_stages(taps, tol.stages, device)
  against_the_samples(a, tol.samples, tol.samples_sum, device)
end

-- The converter's "f16" file, if there is one, speaks as the f32 file does: F16 holds the
-- matrices' BF16 values, the CPU casts them back, and a GPU keeps its activations f32.
function T.the_f16_file_speaks_as_the_f32_file_does()
  local path = dir .. "/pocket-tts-f16.gguf"
  if not exists(path) then return end
  for _, device in ipairs { "cpu", "auto" } do
    local tts = pocket.load(ml.engine { device = device, threads = 8 }, path, { voice = VOICE })
    local samples, info = tts:speak("Hello world, this is a test.", { temperature = 0 })
    assert(info.frames == 25 and info.eos[1] == 22, device .. ": " .. info.frames .. " frames")
    each_near(samples, 1, SAMPLES, 1e-3, device .. " f16 samples")
    tts:free()
  end
end

function T.a_voice_file_that_is_not_one_is_refused()
  local tts = model "cpu"
  local ok, err = pcall(tts.set_voice, tts, MODEL)
  assert(not ok and tostring(err):find("not a Pocket TTS voice", 1, true), tostring(err))
  local again = tts:speak("Yes.", { temperature = 0 })
  assert(#again > 0 and #again % 1920 == 0)
end

return T
