-- Moonshine Streaming on the console's engine (console/ml/moonshine.lua), against Hugging
-- Face transformers.
--
-- The reference is transformers 5.17.0 (torch 2.12.1) on the published checkpoints
-- moonshine-ai/moonshine-streaming-small @ 2c036506 and -tiny @ f8e9dfd8, eager attention,
-- f32, one thread, on jfk.wav (whisper.cpp's sample, 176,000 samples, 550 encoder frames):
-- the frontend's output, the encoder's, the adapter's, the first decoder layer's cross
-- keys, the logits of every step with the transcript's own tokens fed back, and the greedy
-- transcript with HF's budget. The numbers are sampled points and the rms and mean of each
-- whole tensor; the full comparison (console/ml/notes/asr.md, "Port") found every value
-- within 1.5e-4 of transformers on the CPU.
--
-- The model files are console/ml/convert/moonshine.lua's f32 GGUFs of those checkpoints, and
-- jfk.wav sits beside them (console/ml/models/, or ML_MODELS). Without a file, its tests do
-- nothing; without the engine or the clip, none do.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local T = {}

local fine, ml = pcall(require, "console.ml.engine")
local dir = os.getenv("ML_MODELS") or here .. "/../console/ml/models"
local clip = dir .. "/jfk.wav"
local function exists(path) local f = io.open(path, "rb"); if f then f:close() end return f ~= nil end
if not fine or not exists(clip) then return T end
local moonshine = require "console.ml.moonshine"

-- transformers' numbers on jfk.wav. `at` holds { 1-based index, value } of a tensor laid out
-- as ggml has it (the channel innermost, a frame per column). `logits` holds, per step,
-- { token, logit }: the transcript's next token first; at steps 0 and 10 four fixed tokens
-- too, and at step 0 the next four best.
local SMALL = {
  file = dir .. "/moonshine-streaming-small-f32.gguf",
  features = { n = 341000, rms = 0.2813784, mean = -0.002213963, at = { { 8, -0.0641587 }, { 28424, 0.0133677 }, { 56841, 0.0414871 }, { 85258, -0.00574879 }, { 113674, 0.00441858 }, { 142091, 0.0154644 }, { 170508, -0.00835992 }, { 198924, 0.080415 }, { 227341, -0.00782385 }, { 255758, 0.0237514 }, { 284174, -0.0383773 }, { 312591, 0.0999537 } } },
  encoder = { n = 341000, rms = 0.4832364, mean = -0.006822711, at = { { 8, 0.0691568 }, { 5659, -0.498833 }, { 28424, -0.388965 }, { 56841, -0.0167621 }, { 85258, 0.231533 }, { 113674, -0.0646681 }, { 142091, -0.117331 }, { 170508, 0.0831192 }, { 198924, -1.32072 }, { 227341, -0.247342 }, { 255758, -0.00181384 }, { 284174, -0.658308 }, { 312591, 0.669476 } } },
  adapter = { n = 281600, rms = 0.9037268, mean = -0.01238293, at = { { 8, -0.0250837 }, { 23474, 0.323484 }, { 46941, 0.896044 }, { 70408, 0.0335651 }, { 93874, 0.443028 }, { 117341, -0.257097 }, { 140808, 0.227302 }, { 164274, -0.00587326 }, { 187741, 0.624328 }, { 211208, 0.018713 }, { 234674, -0.4805 }, { 258141, -0.384044 } } },
  cross_k0 = { n = 281600, rms = 3.528177, mean = -0.07039167, at = { { 8, -1.91339 }, { 23474, -1.73255 }, { 46941, 8.84137 }, { 70408, -2.00951 }, { 93874, -3.69256 }, { 117341, -0.312047 }, { 140808, -0.459855 }, { 164274, -4.77277 }, { 187741, 7.39189 }, { 211208, -3.01102 }, { 234674, -8.06587 }, { 258141, 0.559975 } } },
  logits = {
    { { 1126, 11.26668 }, { 0, -9.21617 }, { 1000, -5.64943 }, { 20000, -4.42615 }, { 32767, -9.80212 }, { 322, 9.26765 }, { 29871, 7.28051 }, { 376, 6.73598 }, { 448, 6.42959 } },
    { { 577, 14.90419 } }, { { 590, 11.98700 } }, { { 10404, 16.39435 } }, { { 23035, 15.11398 } },
    { { 29892, 10.86321 } }, { { 2244, 14.63537 } }, { { 451, 15.55345 } }, { { 825, 13.82712 } },
    { { 596, 14.51366 } },
    { { 4234, 15.99932 }, { 0, -9.68174 }, { 1000, -6.51429 }, { 20000, -7.80133 }, { 32767, -10.28713 } },
    { { 508, 16.04314 } }, { { 437, 17.44981 } }, { { 363, 15.13955 } }, { { 366, 15.63874 } },
    { { 29892, 10.74946 } }, { { 2244, 12.64223 } }, { { 825, 14.39467 } }, { { 366, 15.29857 } },
    { { 508, 14.89140 } }, { { 437, 15.90672 } }, { { 363, 14.82195 } }, { { 596, 15.51531 } },
    { { 4234, 14.61563 } }, { { 29889, 11.73131 } }, { { 2, 12.26940 } },
  },
  ids = { 1126, 577, 590, 10404, 23035, 29892, 2244, 451, 825, 596, 4234, 508, 437, 363, 366, 29892, 2244, 825, 366, 508, 437, 363, 596, 4234, 29889 },
  text = "And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country.",
}

local TINY = {
  file = dir .. "/moonshine-streaming-tiny-f32.gguf",
  encoder = { n = 176000, rms = 0.8775985, mean = -0.004255122, at = { { 8, -0.153243 }, { 5659, -0.157359 }, { 14674, 0.630397 }, { 29341, -0.188225 }, { 44008, -0.201354 }, { 58674, 0.0462811 }, { 73341, 0.552585 }, { 88008, -1.47162 }, { 102674, 0.705173 }, { 117341, 0.448706 }, { 132008, -1.32182 }, { 146674, -1.56318 }, { 161341, 0.00409762 } } },
  cross_k0 = { n = 176000, rms = 2.51164, mean = -0.0685518, at = { { 8, -0.605286 }, { 14674, 0.396527 }, { 29341, 3.65039 }, { 44008, -1.66434 }, { 58674, -1.26395 }, { 73341, 1.887 }, { 88008, -1.38443 }, { 102674, 0.419583 }, { 117341, -3.43523 }, { 132008, -3.43993 }, { 146674, -0.171516 }, { 161341, -0.146448 } } },
  logits = {
    { { 1126, 11.34568 }, { 0, -12.03344 }, { 1000, -8.80642 }, { 20000, -5.72619 }, { 32767, -12.05091 }, { 322, 8.83947 }, { 448, 6.28602 }, { 1105, 6.16727 }, { 29871, 6.02753 } },
    { { 577, 14.34775 } }, { { 29892, 10.34459 } }, { { 590, 13.56543 } }, { { 10404, 20.25660 } },
    { { 23035, 14.79018 } }, { { 29892, 11.13940 } }, { { 2244, 12.00548 } }, { { 451, 12.25175 } },
    { { 825, 13.71339 } },
    { { 596, 14.07154 }, { 0, -14.39508 }, { 1000, -6.22618 }, { 20000, -8.69109 }, { 32767, -13.57563 } },
    { { 4234, 19.32312 } }, { { 508, 17.92865 } }, { { 437, 19.66576 } }, { { 363, 15.24386 } },
    { { 366, 16.49413 } }, { { 29892, 10.55316 } }, { { 2244, 13.81227 } }, { { 825, 15.89156 } },
    { { 366, 15.39030 } }, { { 508, 15.99424 } }, { { 437, 18.26181 } }, { { 363, 14.25675 } },
    { { 596, 15.41020 } }, { { 4234, 18.68088 } }, { { 29889, 10.93791 } }, { { 2, 11.50490 } },
  },
  ids = { 1126, 577, 29892, 590, 10404, 23035, 29892, 2244, 451, 825, 596, 4234, 508, 437, 363, 366, 29892, 2244, 825, 366, 508, 437, 363, 596, 4234, 29889 },
  text = "And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.",
}

local unpack = table.unpack or unpack
local V = 32768

local function against(name, got, want, tol, where)
  assert(#got == want.n, ("%s: %s has %d values, transformers %d"):format(where, name, #got, want.n))
  for _, p in ipairs(want.at) do
    local d = math.abs(got[p[1]] - p[2])
    assert(d <= tol, ("%s: %s[%d] is %.6g, transformers %.6g (tolerance %g)"):format(where, name, p[1], got[p[1]], p[2], tol))
  end
  local _, _, mean, rms = got:stats()
  assert(math.abs(rms - want.rms) <= tol, ("%s: %s's rms is %.7g, transformers %.7g"):format(where, name, rms, want.rms))
  assert(math.abs(mean - want.mean) <= tol, ("%s: %s's mean is %.7g, transformers %.7g"):format(where, name, mean, want.mean))
end

local function logits_against(logits, want, tol, where)
  assert(#logits == V * #want, where .. ": " .. #logits .. " logits")
  for step, row in ipairs(want) do
    for _, p in ipairs(row) do
      local got = logits[(step - 1) * V + p[1] + 1]
      assert(math.abs(got - p[2]) <= tol,
        ("%s: step %d, token %d is %.5f, transformers %.5f (tolerance %g)"):format(where, step - 1, p[1], got, p[2], tol))
    end
    local best = logits:slice((step - 1) * V + 1, step * V):argmax() - 1
    assert(best == row[1][1], ("%s: at step %d the best token is %d, transformers %d"):format(where, step - 1, best, row[1][1]))
  end
end

local function same_ids(got, want, where)
  assert(table.concat(got, " ") == table.concat(want, " "),
    where .. ": the ids are\n  " .. table.concat(got, " ") .. "\nand should be\n  " .. table.concat(want, " "))
end

-- The whole clip, with every tapped tensor joined over the graphs it took.
local function whole(asr, pcm)
  local s = asr:stream { taps = true }
  s.samples = #pcm
  s:feed(pcm)
  local text, ids = s:finish()
  local taps = {}
  for name, list in pairs(s.taps) do taps[name] = ml.join(unpack(list)) end
  return s, text, ids, taps
end

-- The clip pushed in pieces of `ms`, as a microphone would give it.
local function streamed(asr, pcm, ms, opts)
  local s = asr:stream(opts)
  local n = math.floor(16000 * ms / 1000)
  local partial = ""
  for i = 1, #pcm, n do partial = s:push(pcm:slice(i, math.min(i + n - 1, #pcm))) end
  local text, ids = s:finish()
  return s, text, ids, partial
end

-- A variant's whole clip against transformers: the encoder and the cross keys (and the
-- frontend and adapter where the variant has them), the logits, the transcript.
local function variant_against(want, device, tol)
  local e = ml.engine { device = device, threads = 4 }
  if device ~= "cpu" and e:device() == "CPU" then return end
  local where = e:device()
  local asr = moonshine.load(e, want.file)
  local pcm = ml.wav_read(clip)
  local s, text, ids, taps = whole(asr, pcm)
  for _, name in ipairs { "features", "encoder", "adapter", "cross_k0" } do
    if want[name] then against(name, taps[name], want[name], tol[name], where) end
  end
  logits_against(s:logits { 1, unpack(want.ids) }, want.logits, tol.logits, where)
  assert(text == want.text, where .. ": " .. text)
  same_ids(ids, want.ids, where)
  local _, streamed_text, streamed_ids = streamed(asr, pcm, 160)
  assert(streamed_text == want.text, where .. ", 160 ms pieces: " .. streamed_text)
  same_ids(streamed_ids, want.ids, where .. ", 160 ms pieces")
  asr:free()
end

local CPU = { features = 5e-5, encoder = 1e-4, adapter = 2e-4, cross_k0 = 5e-4, logits = 2e-4 }
-- Metal's matrix products round their tiles to f16.
local DEVICE = { features = 5e-3, encoder = 0.1, adapter = 0.1, cross_k0 = 0.3, logits = 0.15 }

function T.small_on_the_cpu_is_transformers()
  if exists(SMALL.file) then variant_against(SMALL, "cpu", CPU) end
end

function T.small_on_the_device_is_transformers_within_its_rounding()
  if exists(SMALL.file) then variant_against(SMALL, "auto", DEVICE) end
end

function T.tiny_on_the_cpu_is_transformers()
  if exists(TINY.file) then variant_against(TINY, "cpu", CPU) end
end

function T.tiny_on_the_device_is_transformers_within_its_rounding()
  if exists(TINY.file) then variant_against(TINY, "auto", DEVICE) end
end

-- A frame of the encoder is final 12 frames after its audio, and a push computes only the
-- frames that became final, so the committed frames of a stream are the whole clip's, and
-- so is the text it finishes with.
function T.pushed_in_pieces_a_clip_ends_as_it_does_whole()
  if not exists(SMALL.file) then return end
  local asr = moonshine.load(ml.engine { device = "cpu", threads = 4 }, SMALL.file)
  local pcm = ml.wav_read(clip)
  local _, _, _, taps = whole(asr, pcm)
  for _, piece in ipairs { { 20, 0.24 }, { 80, 0.16 }, { 320, 0 } } do
    local ms, every = piece[1], piece[2]
    local s, text, ids, partial = streamed(asr, pcm, ms, { taps = true, every = every })
    local enc = ml.join(unpack(s.taps.encoder))
    local d = ml.max_diff(enc, taps.encoder)
    assert(d <= 5e-5, ("%d ms pieces: the committed frames move by %g from the whole clip's"):format(ms, d))
    assert(#partial > 0 and SMALL.text:find(partial:sub(1, 12), 1, true) == 1,
      ms .. " ms pieces: the text before the end was \"" .. partial .. "\"")
    assert(text == SMALL.text, ms .. " ms pieces: " .. text)
    same_ids(ids, SMALL.ids, ms .. " ms pieces")
  end
  asr:free()
end

-- A clip whose length is not a whole 20 ms: the last partial 5 ms frame is dropped and the
-- rest padded, as the reference's processor pads it, pushed whole or in pieces alike.
function T.a_clip_of_any_length_ends_the_same_pushed_or_whole()
  if not exists(SMALL.file) then return end
  local asr = moonshine.load(ml.engine { device = "cpu", threads = 4 }, SMALL.file)
  local pcm = ml.wav_read(clip):slice(1, 171234)
  local _, whole_text, whole_ids = whole(asr, pcm)
  local _, text, ids = streamed(asr, pcm, 130)
  assert(text == whole_text, text .. "\n" .. whole_text)
  same_ids(ids, whole_ids, "130 ms pieces")
  assert(asr:transcribe(ml.buffer(0)) == "", "silence of no length has no text")
  asr:free()
end

return T
