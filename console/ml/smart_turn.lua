-- smart_turn — Smart Turn v3.2, the probability that a speaker has finished their turn,
-- on the console's engine.
--
--     local ml   = require "console.ml.engine"
--     local turn = require("console.ml.smart_turn").load(ml.engine(), "console/ml/models/smart-turn-v3.2.gguf")
--     local p = turn:predict(samples)      -- the turn so far, 16 kHz mono -> p(finished)
--
-- The pipeline is console/ml/notes/smart_turn.md, sections 2 to 4: the last 8 s of the
-- turn, zero-padded at the start; normalized to zero mean and unit variance over all
-- 8 s, padding included; Whisper's log-mel (ml.whisper_mel), 80 x 800; Whisper-tiny's
-- encoder cut to 400 positions; attention pooling over time; a small MLP and a sigmoid.
-- Checked against pipecat's fp32 ONNX model on prefixes of jfk.wav.
--
-- Run it when the VAD says speech has stopped, on the whole turn, not per window
-- (notes, section 9). p > 0.5 is "finished", the threshold upstream uses.

local ml = require "console.ml.engine"

local smart = {}

local RATE, SECONDS = 16000, 8
local N = RATE * SECONDS                       -- 128,000 samples
local MELS, FRAMES = 80, 800

local Turn = {}
Turn.__index = Turn

local function meta(w, key)
  local v = w:meta(key)
  if v == nil then error("smart_turn: the file has no " .. key, 3) end
  return v
end

--- Loads a GGUF written by console/ml/convert/smart_turn.lua.
function smart.load(engine, path)
  local w = engine:load(path)
  local arch = w:meta "general.architecture"
  if arch ~= "smart-turn" then error("smart_turn: " .. path .. " is a " .. tostring(arch) .. " model", 2) end
  local function t(name)
    local x = w:get(name)
    if not x then error("smart_turn: " .. path .. " has no " .. name, 2) end
    return x
  end
  local m = setmetatable({ engine = engine, w = w, path = path, t = t }, Turn)
  m.n_layer = meta(w, "smart-turn.block_count")
  m.d = meta(w, "smart-turn.embedding_length")
  m.heads = meta(w, "smart-turn.head_count")
  m.eps = meta(w, "smart-turn.layer_norm_epsilon")
  m.layers = {}
  for l = 0, m.n_layer - 1 do
    local p = "encoder.layers." .. l .. "."
    m.layers[l] = {
      ln1_w = t(p .. "self_attn_layer_norm.weight"), ln1_b = t(p .. "self_attn_layer_norm.bias"),
      q = t(p .. "self_attn.q_proj.weight"), q_b = t(p .. "self_attn.q_proj.bias"),
      k = t(p .. "self_attn.k_proj.weight"),                                  -- k has no bias
      v = t(p .. "self_attn.v_proj.weight"), v_b = t(p .. "self_attn.v_proj.bias"),
      o = t(p .. "self_attn.out_proj.weight"), o_b = t(p .. "self_attn.out_proj.bias"),
      ln2_w = t(p .. "final_layer_norm.weight"), ln2_b = t(p .. "final_layer_norm.bias"),
      fc1 = t(p .. "fc1.weight"), fc1_b = t(p .. "fc1.bias"),
      fc2 = t(p .. "fc2.weight"), fc2_b = t(p .. "fc2.bias"),
    }
  end
  m.graph = engine:graph(1024)
  m.norm = engine:graph(16)
  m:build()
  return m
end

-- Normalization on the engine: 128,000 multiply-adds are a node, where a Lua loop over a
-- buffer would be most of the prediction's time.
function Turn:build_norm()
  local g = self.norm
  g:reset()
  self.norm_x = g:input("f32", N)
  self.norm_mean = g:input("f32", 1)
  self.norm_scale = g:input("f32", 1)
  self.norm_y = g:mul(g:sub(self.norm_x, self.norm_mean), self.norm_scale)
  self.norm_built = false
end

-- A 1-D conv as im2col and a product, both in f32 (ggml's conv_1d rounds its im2col to
-- f16). kernel [K, IC, OC], x [L, IC]. Answers [OL, OC] when time_first, else [OC, OL].
local function conv(g, kernel, x, stride, pad, time_first)
  local K, IC, OC = kernel:shape()
  local cols = g:im2col(kernel, x, stride, 0, pad, 0, 1, 0, false, "f32")   -- [IC*K, OL]
  local k = g:reshape(kernel, K * IC, OC)
  if time_first then return g:mul_mat(cols, k) end
  return g:mul_mat(k, cols)
end

-- The one graph every prediction computes again, with new features.
function Turn:build()
  local g, t, eps, D, H = self.graph, self.t, self.eps, self.d, self.heads
  local hd = math.floor(D / H)
  local T = math.floor(FRAMES / 2)                                     -- 400 positions
  g:reset()
  local function ln(x, w, b) return g:add(g:mul(g:norm(x, eps), w), b) end
  local function linear(x, w, b) local y = g:mul_mat(w, x); return b and g:add(y, b) or y end

  local mel = g:input("f32", FRAMES, MELS)                             -- [time, mel], as im2col reads it
  -- The conv stem, exact (erf) GELU.
  local x = conv(g, t "encoder.conv1.weight", mel, 1, 1, true)        -- [800, 384]
  x = g:gelu_erf(g:add(x, g:reshape(t "encoder.conv1.bias", 1, D)))
  x = g:gelu_erf(g:add(conv(g, t "encoder.conv2.weight", x, 2, 1, false), t "encoder.conv2.bias"))   -- [384, 400]
  local h = g:add(x, t "encoder.embed_positions.weight")

  for l = 0, self.n_layer - 1 do
    local L = self.layers[l]
    local y = ln(h, L.ln1_w, L.ln1_b)
    local q = linear(y, L.q, L.q_b)
    local k = linear(y, L.k)
    local v = linear(y, L.v, L.v_b)
    local Q = g:cont(g:permute(g:reshape(q, hd, H, T), 0, 2, 1, 3))  -- [64, 400, 6]
    local K = g:cont(g:permute(g:reshape(k, hd, H, T), 0, 2, 1, 3))
    local P = g:soft_max_ext(g:mul_mat(K, Q), nil, 1 / math.sqrt(hd), 0)   -- [keys, queries, heads]
    local V = g:cont(g:permute(g:reshape(v, hd, H, T), 1, 2, 0, 3))  -- [400, 64, 6]
    local O = g:cont_nd(g:permute(g:mul_mat(V, P), 0, 2, 1, 3), D, T)   -- [384, 400]
    h = g:add(h, linear(O, L.o, L.o_b))
    y = ln(h, L.ln2_w, L.ln2_b)
    y = g:gelu_erf(linear(y, L.fc1, L.fc1_b))
    h = g:add(h, linear(y, L.fc2, L.fc2_b))
  end
  h = ln(h, t "encoder.layer_norm.weight", t "encoder.layer_norm.bias")   -- [384, 400]

  -- Attention pooling: a weight per position, softmax over time.
  local s = linear(g:tanh(linear(h, t "pool_attention.0.weight", t "pool_attention.0.bias")),
                   t "pool_attention.2.weight", t "pool_attention.2.bias")   -- [1, 400]
  local a = g:soft_max(g:reshape(s, T, 1))
  local pooled = g:mul_mat(g:cont(g:transpose(h)), a)                 -- [384, 1]

  -- The head: 384 -> 256 -> LayerNorm -> GELU -> 64 -> GELU -> 1 -> sigmoid.
  local z = linear(pooled, t "classifier.0.weight", t "classifier.0.bias")
  z = g:gelu_erf(ln(z, t "classifier.1.weight", t "classifier.1.bias"))
  z = g:gelu_erf(linear(z, t "classifier.4.weight", t "classifier.4.bias"))
  local p = g:sigmoid(linear(z, t "classifier.6.weight", t "classifier.6.bias"))
  self.mel, self.p, self.built = mel, p, false
  self:build_norm()
end

--- The features the encoder reads: the last 8 s of the samples (16 kHz mono, zeros in
--- front of a shorter turn), normalized over all 8 s, as Whisper's log-mel. Answers an
--- ml.buffer of 80 x 800, frames fastest.
function Turn:features(samples)
  if type(samples) == "table" then samples = ml.buffer(samples) end
  local n = #samples
  local x
  if n >= N then x = samples:slice(n - N + 1, n)
  elseif n == 0 then x = ml.buffer(N)
  else x = ml.join(ml.buffer(N - n), samples) end
  -- The statistics include the padding (notes, gotcha 1): the pad becomes -mean/std.
  local _, _, mean, rms = x:stats()
  local var = math.max(rms * rms - mean * mean, 0)
  local g = self.norm
  g:set(self.norm_x, x)
  g:set(self.norm_mean, ml.buffer { mean })
  g:set(self.norm_scale, ml.buffer { 1 / math.sqrt(var + 1e-7) })
  if self.norm_built then g:compute() else g:compute(self.norm_y); self.norm_built = true end
  local mel = ml.whisper_mel(g:read(self.norm_y), MELS, FRAMES)
  return mel
end

--- The probability that the speaker has finished, from the turn so far (16 kHz mono,
--- an ml.buffer or a list of numbers). Only the last 8 s are heard.
function Turn:predict(samples)
  return self:predict_features(self:features(samples))
end

--- The same from features made by Turn:features (80 x 800, frames fastest).
function Turn:predict_features(mel)
  if #mel ~= MELS * FRAMES then error("smart_turn: features are 80 x 800, not " .. #mel .. " values", 2) end
  local g = self.graph
  g:set(self.mel, mel)
  if self.built then g:compute() else g:compute(self.p); self.built = true end
  return g:read(self.p)[1]
end

--- Frees the weights and the graphs now, not when they are collected.
function Turn:free()
  self.graph:free(); self.norm:free(); self.w:free()
end

return smart
