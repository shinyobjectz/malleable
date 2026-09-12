-- silero_vad — Silero VAD v6.2, the probability that a 32 ms window of 16 kHz audio is
-- speech, on the console's engine.
--
--     local ml  = require "console.ml.engine"
--     local vad = require("console.ml.silero_vad").load(ml.engine { device = "cpu" },
--                                                          "console/ml/models/silero-vad.gguf")
--     local p = vad:step(samples)          -- 512 new samples -> p(speech)
--
-- The forward pass is console/ml/notes/silero_vad.md, section 6: the window after the
-- previous window's last 64 samples, reflect-padded on the right to 640, a windowed DFT
-- as a strided conv (4 frames of 129 magnitudes), four conv+ReLU blocks down to one
-- 128-vector, an LSTM cell, and a sigmoid head. Checked against the official TorchScript
-- model (silero_vad.jit) on jfk.wav, window by window.
--
-- The stream's state is three tensors in a set, on the engine's device: the 64 samples of
-- context, and the LSTM's h and c. The graph is built once, reads them and writes them
-- back, so a step moves 512 samples in and one number out and nothing else.

local ml = require "console.ml.engine"

local silero = {}

local WINDOW, CONTEXT, HIDDEN = 512, 64, 128

local Vad = {}
Vad.__index = Vad

-- A 1-D conv as im2col and a product, both in f32. ggml's conv_1d builds its im2col in
-- f16, which rounds the audio and every activation (notes, section 5, point 2).
-- kernel [K, IC, OC], x [L, IC] -> [OC, OL], channels first.
--
-- The kernel is the product's first operand and the frames (4 at most) its second: with
-- more than 8 columns in the second operand, Metal takes its matrix-matrix kernel, which
-- stages both operands in half precision, and the audio would be rounded after all.
local function conv(g, kernel, x, stride, pad)
  local K, IC, OC = kernel:shape()
  local cols = g:im2col(kernel, x, stride, 0, pad, 0, 1, 0, false, "f32")   -- [IC*K, OL]
  return g:mul_mat(g:reshape(kernel, K * IC, OC), cols)
end

--- Loads a GGUF written by console/ml/convert/silero_vad.lua.
function silero.load(engine, path)
  local w = engine:load(path)
  local arch = w:meta "general.architecture"
  if arch ~= "silero-vad" then error("silero_vad: " .. path .. " is a " .. tostring(arch) .. " model", 2) end
  local function t(name)
    local x = w:get(name)
    if not x then error("silero_vad: " .. path .. " has no " .. name, 2) end
    return x
  end
  local v = setmetatable({ engine = engine, w = w, path = path }, Vad)
  v.basis = t "stft.forward_basis_buffer"
  v.enc = {}
  for i = 0, 3 do
    v.enc[i + 1] = { w = t("encoder." .. i .. ".reparam_conv.weight"), b = t("encoder." .. i .. ".reparam_conv.bias") }
  end
  v.w_ih, v.w_hh = t "decoder.rnn.weight_ih", t "decoder.rnn.weight_hh"
  v.b_ih, v.b_hh = t "decoder.rnn.bias_ih", t "decoder.rnn.bias_hh"
  v.head_w, v.head_b = t "decoder.decoder.2.weight", t "decoder.decoder.2.bias"

  v.state = engine:set(3)
  v.context = v.state:new("context", "f32", CONTEXT)
  v.h = v.state:new("h", "f32", HIDDEN)
  v.c = v.state:new("c", "f32", HIDDEN)
  v.state:alloc()
  v.graph = engine:graph(128)
  v:build()
  return v
end

-- The one graph every step computes again, with new samples.
function Vad:build()
  local g = self.graph
  g:reset()
  local chunk = g:input("f32", WINDOW)
  local x = g:concat(self.context, chunk, 0)                         -- 576: context, then the window
  x = g:pad_reflect_1d(g:reshape(x, WINDOW + CONTEXT, 1), 0, 64)     -- 640, the right side mirrored

  -- The DFT as a conv: rows 0..128 are the real parts, 129..257 the imaginary.
  local st = g:cont(g:transpose(conv(g, self.basis, x, 128, 0)))    -- [4 frames, 258]
  local bins = 129
  local re = g:view(st, { 4, bins }, { 16 }, 0)
  local im = g:view(st, { 4, bins }, { 16 }, bins * 16)
  local cur = g:sqrt(g:add(g:sqr(re), g:sqr(im)))                    -- [4, 129]

  for i, stride in ipairs { 1, 2, 2, 1 } do                          -- 4 -> 4 -> 2 -> 1 -> 1 frames
    local e = self.enc[i]
    local y = g:relu(g:add(conv(g, e.w, cur, stride, 1), e.b))       -- [OC, OL]
    cur = i < 4 and g:cont(g:transpose(y)) or y                      -- the next conv reads [OL, OC]
  end
  x = g:reshape(cur, HIDDEN)                                         -- one frame of 128

  -- The LSTM cell, PyTorch's gate order: i, f, g, o. The state carried on is h before
  -- the head's ReLU.
  local gates = g:add(g:add(g:mul_mat(self.w_ih, x), self.b_ih), g:add(g:mul_mat(self.w_hh, self.h), self.b_hh))
  local function gate(k) return g:view(gates, { HIDDEN }, k * HIDDEN * 4) end
  local c = g:add(g:mul(g:sigmoid(gate(1)), self.c), g:mul(g:sigmoid(gate(0)), g:tanh(gate(2))))
  local h = g:mul(g:sigmoid(gate(3)), g:tanh(c))
  local p = g:sigmoid(g:add(g:mul_mat(g:reshape(self.head_w, HIDDEN), g:relu(h)), self.head_b))

  -- Everything that reads the old state is in the graph before the writes: ggml sees no
  -- edge between a write into a set and an earlier read of it, so the order is the edge.
  g:expand(p)
  g:expand(g:cpy(c, self.c))
  g:expand(g:cpy(h, self.h))
  g:expand(g:cpy(g:view(chunk, { CONTEXT }, (WINDOW - CONTEXT) * 4), self.context))
  self.chunk, self.p, self.built = chunk, p, false
end

--- Takes the next 512 samples (16 kHz mono, an ml.buffer or a list of numbers) and
--- answers the probability that they are speech.
function Vad:step(samples)
  if type(samples) == "table" then samples = ml.buffer(samples) end
  if #samples ~= WINDOW then
    error("silero_vad: a step takes " .. WINDOW .. " samples, not " .. #samples, 2)
  end
  local g = self.graph
  g:set(self.chunk, samples)
  if self.built then g:compute() else g:compute(self.p); self.built = true end
  return g:read(self.p)[1]
end

--- Forgets the stream: the context and the LSTM state go back to zeros.
function Vad:reset()
  self.state:clear()
end

--- A whole clip from a fresh state, as silero's own get_speech_timestamps runs it: one
--- probability per 512-sample window, the last window zero-padded. Answers an ml.buffer.
function Vad:run(samples)
  if type(samples) == "table" then samples = ml.buffer(samples) end
  self:reset()
  local n = #samples
  local windows = math.ceil(n / WINDOW)
  local out = ml.buffer(windows)
  for k = 1, windows do
    local from = (k - 1) * WINDOW + 1
    local piece = samples:slice(from, math.min(from + WINDOW - 1, n))
    if #piece < WINDOW then piece = ml.join(piece, ml.buffer(WINDOW - #piece)) end
    out[k] = self:step(piece)
  end
  return out
end

--- Frees the weights, the state and the graph now, not when they are collected.
function Vad:free()
  self.graph:free(); self.state:free(); self.w:free()
end

return silero
