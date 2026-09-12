-- pocket_tts — Kyutai's Pocket TTS, text to speech that runs on the console's engine and
-- streams its audio as it is made.
--
--     local ml     = require "console.ml.engine"
--     local pocket = require "console.ml.pocket_tts"
--     local tts = pocket.load(ml.engine(), "console/ml/models/pocket-tts.gguf",
--                             { voice = "console/ml/models/pocket-tts-alba.gguf" })
--     local samples = tts:speak("Hello world.", { on_audio = function (frame) end })
--     ml.wav_write("hello.wav", samples, 24000)
--
-- The model is console/ml/notes/pocket_tts.md, section by section, checked against the
-- official Python package (kyutai-labs/pocket-tts at 0c2db3b):
--   * a 6-layer causal transformer (the FlowLM) reads a voice, held as a precomputed KV
--     cache, then the text's tokens, then one 32-wide latent per 80 ms frame (section 5);
--   * from its last output, one step of a small AdaLN network (the flow head) turns
--     Gaussian noise into the next latent, and a linear layer says when speech ends (6, 7);
--   * the Mimi decoder turns each latent into 1920 samples at 24 kHz as soon as it exists:
--     an upsample to 200 Hz, a 2-layer transformer with a 250-step window, and a causal
--     SEANet of convolutions, all streaming, with their history in a set (8).
-- The weights are F32, the published BF16 values exactly (console/ml/convert/pocket_tts.lua).

local ml = require "console.ml.engine"
local unpack = table.unpack or unpack

local pocket = {}

local TTS = {}
TTS.__index = TTS

local F = 4                                     -- bytes in an f32
local LN_EPS, HEAD_EPS = 1e-5, 1e-6              -- the transformers' LayerNorm, the flow head's
local ROPE_NORMAL = 0                           -- adjacent pairs rotate (notes, F10); not NEOX

local function meta(w, key)
  local v = w:meta(key)
  if v == nil then error("pocket_tts: the file has no " .. key, 3) end
  return v
end

-- A count from the metadata as an integer: Lua 5.4 reads a u32 as a float, and a float
-- would name "layers.0.0".
local function count(w, key)
  local v = meta(w, key)
  if type(v) == "table" then
    local out = {}
    for i, x in ipairs(v) do out[i] = math.floor(x) end
    return out
  end
  return math.floor(v)
end

local function idiv(a, b) return math.floor(a / b) end

-- ------------------------------------------------------------------ the pieces of a graph

local function layer_norm(g, x, w, b, eps)
  local y = g:norm(x, eps)
  if w then y = g:add(g:mul(y, w), b) end
  return y
end

-- GELU, tanh form, in f32. ggml's gelu is that on a GPU, but on the CPU it looks its
-- input up in an f16 table (notes, F3), so there it is composed of nine f32 ops instead.
local function gelu_tanh(g, x, on_cpu)
  if not on_cpu then return g:gelu(x) end
  local inner = g:scale(g:add(x, g:scale(g:mul(g:sqr(x), x), 0.044715)), 0.7978845608028654)
  return g:mul(g:scale(x, 0.5), g:scale_bias(g:tanh(inner), 1, 1))
end

-- One step of attention for T queries over n_kv cached keys. The cache is (head, heads,
-- cells); `mask` is (n_kv, T), or nil when every key is visible.
local function attend(g, q, kc, vc, hd, H, T, n_kv, mask)
  local cell = hd * H * F
  local K = g:permute(g:view(kc, { hd, H, n_kv }, { hd * F, cell }, 0), 0, 2, 1, 3)           -- (hd, n_kv, H)
  local Vt = g:cont(g:permute(g:view(vc, { hd, H, n_kv }, { hd * F, cell }, 0), 1, 2, 0, 3))  -- (n_kv, hd, H)
  local kq = g:soft_max_ext(g:mul_mat(K, g:permute(q, 0, 2, 1, 3)), mask, 1 / math.sqrt(hd), 0)
  local o = g:mul_mat(Vt, kq)                                                                 -- (hd, T, H)
  return g:reshape(g:cont(g:permute(o, 0, 2, 1, 3)), hd * H, T)
end

-- q, k and v of T positions, from the packed in_proj product (3D, T): each (hd, H, T).
local function split_qkv(g, qkv, hd, H, T)
  local D = hd * H
  local q = g:view(qkv, { hd, H, T }, { hd * F, 3 * D * F }, 0)
  local k = g:view(qkv, { hd, H, T }, { hd * F, 3 * D * F }, D * F)
  local v = g:view(qkv, { hd, H, T }, { hd * F, 3 * D * F }, 2 * D * F)
  return q, k, v
end

local function rope(g, x, pos, hd, base)
  return g:rope_ext(x, pos, nil, hd, ROPE_NORMAL, 0, base, 1, 0, 1, 0, 0)
end

-- ------------------------------------------------------------------ loading

--- Loads a Pocket TTS GGUF (console/ml/convert/pocket_tts.lua makes one). opts:
--- { voice = path to a voice GGUF, context = room in the FlowLM cache after the voice }.
function pocket.load(engine, path, opts)
  opts = opts or {}
  local w = engine:load(path)
  local arch = meta(w, "general.architecture")
  if arch ~= "pocket_tts" then error("pocket_tts: " .. path .. " is a " .. tostring(arch) .. " model", 2) end
  local A = "pocket_tts."
  local hp = {
    rate = count(w, A .. "sample_rate"), frame = count(w, A .. "frame_samples"), ldim = count(w, A .. "latent_dim"),
    n_layer = count(w, A .. "flow.block_count"), d = count(w, A .. "flow.embedding_length"),
    heads = count(w, A .. "flow.head_count"), head_width = count(w, A .. "flow.head_width"),
    head_blocks = count(w, A .. "flow.head_blocks"),
    m_layer = count(w, A .. "mimi.block_count"), md = count(w, A .. "mimi.embedding_length"),
    m_heads = count(w, A .. "mimi.head_count"), context = count(w, A .. "mimi.context"),
    upsample = count(w, A .. "mimi.upsample"), ratios = count(w, A .. "mimi.ratios"),
    base = meta(w, A .. "rope.freq_base"), eos = meta(w, A .. "eos_threshold"),
    temperature = meta(w, A .. "default_temperature"), max_tokens = count(w, A .. "max_tokens"),
  }
  hp.hd = idiv(hp.d, hp.heads)
  hp.m_hd = idiv(hp.md, hp.m_heads)
  -- The Mimi transformer's keys live in a ring of whole frames: enough frames that the
  -- oldest key the window still reaches, context - 1 steps before a frame, is kept.
  hp.ring = idiv(hp.context - 1 + hp.upsample - 1, hp.upsample) + 1
  local m = setmetatable({ engine = engine, w = w, hp = hp, path = path, room = opts.context or 300,
                           on_cpu = engine:device() == "CPU" }, TTS)
  m.tok = w:tokenizer()

  -- A file may hold the FlowLM's matrices in F16 (the converter's "f16"), which a GPU
  -- multiplies with f32 activations. The CPU would round each activation to F16 on the way
  -- into such a product (notes, F1), so there they are cast back to F32 once, here.
  local upcast = {}
  if engine:device() == "CPU" then
    local halves = {}
    for _, name in ipairs(w:names()) do
      if w:get(name):type() == "f16" then halves[#halves + 1] = name end
    end
    if #halves > 0 then
      m.upcast = engine:set(#halves)
      for _, name in ipairs(halves) do upcast[name] = m.upcast:new(name, "f32", w:get(name):shape()) end
      m.upcast:alloc()
      local g = engine:graph(4 * #halves + 16)          -- a copy, its source and its target each
      for name, x in pairs(upcast) do g:expand(g:cpy(w:get(name), x)) end
      g:compute()
      g:free()
    end
  end

  local function t(name)
    local x = upcast[name] or w:get(name)
    if not x then error("pocket_tts: the file has no " .. name, 3) end
    return x
  end
  m.text_embd = t "conditioner.embed.weight"
  m.bos_emb, m.bos_before_voice = t "bos_emb", t "bos_before_voice"
  m.input_linear = t "input_linear.weight"
  m.out_norm_w, m.out_norm_b = t "out_norm.weight", t "out_norm.bias"
  m.out_eos_w, m.out_eos_b = t "out_eos.weight", t "out_eos.bias"
  m.emb_mean, m.emb_std = t "emb_mean", t "emb_std"
  m.layers = {}
  for l = 0, hp.n_layer - 1 do
    local p = "transformer.layers." .. l .. "."
    m.layers[l] = {
      norm1_w = t(p .. "norm1.weight"), norm1_b = t(p .. "norm1.bias"),
      qkv = t(p .. "self_attn.in_proj.weight"), out = t(p .. "self_attn.out_proj.weight"),
      norm2_w = t(p .. "norm2.weight"), norm2_b = t(p .. "norm2.bias"),
      up = t(p .. "linear1.weight"), down = t(p .. "linear2.weight"),
    }
  end
  local f = "flow_net."
  m.head = {
    cond_w = t(f .. "cond_embed.weight"), cond_b = t(f .. "cond_embed.bias"),
    in_w = t(f .. "input_proj.weight"), in_b = t(f .. "input_proj.bias"),
    final_ada_w = t(f .. "final_layer.adaLN_modulation.1.weight"),
    final_ada_b = t(f .. "final_layer.adaLN_modulation.1.bias"),
    final_w = t(f .. "final_layer.linear.weight"), final_b = t(f .. "final_layer.linear.bias"),
    blocks = {},
  }
  for b = 0, hp.head_blocks - 1 do
    local p = f .. "res_blocks." .. b .. "."
    m.head.blocks[b] = {
      ln_w = t(p .. "in_ln.weight"), ln_b = t(p .. "in_ln.bias"),
      mlp0_w = t(p .. "mlp.0.weight"), mlp0_b = t(p .. "mlp.0.bias"),
      mlp2_w = t(p .. "mlp.2.weight"), mlp2_b = t(p .. "mlp.2.bias"),
      ada_w = t(p .. "adaLN_modulation.1.weight"), ada_b = t(p .. "adaLN_modulation.1.bias"),
    }
  end
  m.mimi = { qproj = t "mimi.quantizer.output_proj.weight", upsample = t "mimi.upsample.weight", layers = {} }
  for l = 0, hp.m_layer - 1 do
    local p = "mimi.dec_tr." .. l .. "."
    m.mimi.layers[l] = {
      norm1_w = t(p .. "norm1.weight"), norm1_b = t(p .. "norm1.bias"),
      qkv = t(p .. "self_attn.in_proj.weight"), out = t(p .. "self_attn.out_proj.weight"),
      norm2_w = t(p .. "norm2.weight"), norm2_b = t(p .. "norm2.bias"),
      up = t(p .. "linear1.weight"), down = t(p .. "linear2.weight"),
      scale1 = t(p .. "layer_scale_1.scale"), scale2 = t(p .. "layer_scale_2.scale"),
    }
  end
  local d = "mimi.decoder.model."
  local function conv(i, name) return { w = t(d .. i .. "." .. name .. ".weight"), b = t(d .. i .. "." .. name .. ".bias") } end
  m.seanet = {
    conv_in = conv(0, "conv"), conv_out = conv(11, "conv"),
    up = { conv(2, "convtr"), conv(5, "convtr"), conv(8, "convtr") },
    res = {
      { conv(3, "block.1.conv"), conv(3, "block.3.conv") },
      { conv(6, "block.1.conv"), conv(6, "block.3.conv") },
      { conv(9, "block.1.conv"), conv(9, "block.3.conv") },
    },
  }
  -- channels at each stage of the SEANet: 512 in, halved by each upsampling
  local ch = { hp.md }
  for i = 1, #hp.ratios do ch[i + 1] = idiv(ch[i], 2) end
  m.channels = ch

  m.graph = engine:graph(4096)
  m.mgraph = engine:graph(4096)
  m:make_time_constant()
  m:make_mimi_state()

  -- the ids that end a sentence and those that may end a clause (notes, 3.2)
  m.sentence_ends, m.clause_ends = {}, {}
  local e = m.tok:encode(".!...?", { special = false })
  for i = 2, #e do m.sentence_ends[e[i]] = true end
  local c = m.tok:encode(",;:", { special = false })
  for i = 2, #c do m.clause_ends[c[i]] = true end

  if opts.voice then m:set_voice(opts.voice) end
  return m
end

-- With one LSD step, the flow head's two timestep embeddings are of s = 0 and t = 1, so
-- their mean is a constant of the weights: computed once here (notes, section 6). The
-- embedders' "RMSNorm" is h * alpha / sqrt(var(h) + 1e-5) with the unbiased variance.
function TTS:make_time_constant()
  local w, hp, g = self.w, self.hp, self.graph
  g:reset()
  local sum
  for k, tau in ipairs { 0, 1 } do
    local p = "flow_net.time_embed." .. (k - 1) .. "."
    local freqs = w:get(p .. "freqs"):read()
    local half = #freqs
    local e = ml.buffer(2 * half)
    for i = 1, half do
      local a = tau * freqs[i]
      e[i], e[half + i] = math.cos(a), math.sin(a)
    end
    local x = g:input("f32", 2 * half)
    g:set(x, e)
    local h = g:add(g:mul_mat(w:get(p .. "mlp.0.weight"), x), w:get(p .. "mlp.0.bias"))
    h = g:add(g:mul_mat(w:get(p .. "mlp.2.weight"), g:silu(h)), w:get(p .. "mlp.2.bias"))
    local n = hp.head_width
    local centred = g:sub(h, g:mean(h))
    local var = g:scale(g:sum_rows(g:sqr(centred)), 1 / (n - 1))
    h = g:mul(g:div(h, g:sqrt(g:scale_bias(var, 1, 1e-5))), w:get(p .. "mlp.3.alpha"))
    sum = sum and g:add(sum, h) or h
  end
  local tconst = g:scale(sum, 0.5)
  g:compute(tconst)
  local values = g:read(tconst)
  g:reset()
  self.consts = self.engine:set(1)
  self.tconst = self.consts:new("tconst", "f32", hp.head_width)
  self.consts:alloc()
  self.tconst:write(values)
end

-- The Mimi decoder's history, fresh for every chunk. Each piece of it that a frame both
-- reads and replaces is kept twice: frame f reads copy f % 2 and writes the other, so no
-- write can land before its read (notes, F7). The transformer's keys and values are a
-- ring of whole frames, where a frame writes its own slot before attention reads them all.
function TTS:make_mimi_state()
  local hp, ch = self.hp, self.channels
  local s = self.engine:set(64)
  local copies = {}
  for c = 1, 2 do
    local function new(name, ...) return s:new(name .. "." .. c, "f32", ...) end
    copies[c] = {
      e_prev = new("e_prev", hp.md),
      conv_in = new("conv_in", ch[1], 6),
      up = { new("up.1", ch[2] * hp.ratios[1]), new("up.2", ch[3] * hp.ratios[2]), new("up.3", ch[4] * hp.ratios[3]) },
      res = { new("res.1", ch[2], 2), new("res.2", ch[3], 2), new("res.3", ch[4], 2) },
      conv_out = new("conv_out", ch[4], 2),
    }
  end
  local ring = hp.ring * hp.upsample
  self.mimi_k, self.mimi_v = {}, {}
  for l = 0, hp.m_layer - 1 do
    self.mimi_k[l] = s:new("ring_k." .. l, "f32", hp.m_hd, hp.m_heads, ring)
    self.mimi_v[l] = s:new("ring_v." .. l, "f32", hp.m_hd, hp.m_heads, ring)
  end
  s:alloc()
  self.mstate, self.mcopies, self.mframe = s, copies, 0
end

-- The FlowLM cache: K and V of every position, voice first (notes, section 12).
function TTS:make_cache(n_ctx)
  local hp = self.hp
  if self.cache then self.cache:free() end
  self.cache = self.engine:set(2 * hp.n_layer)
  self.k, self.v = {}, {}
  for l = 0, hp.n_layer - 1 do
    self.k[l] = self.cache:new("k" .. l, "f32", hp.hd, hp.heads, n_ctx)
    self.v[l] = self.cache:new("v" .. l, "f32", hp.hd, hp.heads, n_ctx)
  end
  self.cache:alloc()
  self.n_ctx = n_ctx
end

--- Speaks in another voice from now on: a voice GGUF, whose K and V become the first
--- positions of the FlowLM cache (notes, 4.1).
function TTS:set_voice(path)
  local hp = self.hp
  local v = self.engine:load(path)
  if v:meta "general.architecture" ~= "pocket_tts.voice" then
    v:free()
    error("pocket_tts: " .. path .. " is not a Pocket TTS voice", 2)
  end
  local P0 = count(v, "pocket_tts.voice.positions")
  if not self.n_ctx or self.n_ctx < P0 + self.room then self:make_cache(P0 + self.room) end
  local g = self.graph
  g:reset()
  local cell = hp.hd * hp.heads * F
  for l = 0, hp.n_layer - 1 do
    g:expand(g:cpy(v:get("voice." .. l .. ".k"), g:view(self.k[l], { hp.hd, hp.heads, P0 }, { hp.hd * F, cell }, 0)))
    g:expand(g:cpy(v:get("voice." .. l .. ".v"), g:view(self.v[l], { hp.hd, hp.heads, P0 }, { hp.hd * F, cell }, 0)))
  end
  g:compute()
  g:reset()
  v:free()
  self.voice, self.P0, self.P = path, P0, P0
end

--- The FlowLM cache at one position of one layer: K (after RoPE) and V, each 16 heads of
--- 64 values, head after head. Position 0 of a voice is its BOS (notes, 13.1).
function TTS:cached(layer, position)
  local n = self.hp.hd * self.hp.heads
  local from, to = position * n + 1, (position + 1) * n
  return self.k[layer]:read():slice(from, to), self.v[layer]:read():slice(from, to)
end

-- ------------------------------------------------------------------ the FlowLM

-- The transformer over x (d, T) at positions P .. P+T-1, whose K and V it writes to the
-- cache. Positions below P, the voice and what came before, are only read.
function TTS:transformer(g, x, T, tap)
  local hp = self.hp
  local P, hd, H = self.P, hp.hd, hp.heads
  local n_kv = P + T
  if n_kv > self.n_ctx then error("pocket_tts: the FlowLM cache is full (" .. self.n_ctx .. " positions)", 3) end
  local pos = g:input("i32", T)
  local p = ml.buffer(T, "i32")
  for i = 1, T do p[i] = P + i - 1 end
  g:set(pos, p)
  local mask
  if T > 1 then
    mask = g:input("f32", n_kv, T)
    local b = ml.buffer(n_kv * T)
    for i = 0, T - 1 do
      for j = P + i + 1, n_kv - 1 do b[i * n_kv + j + 1] = -math.huge end
    end
    g:set(mask, b)
  end
  local cell = hd * H * F
  for l = 0, hp.n_layer - 1 do
    local L = self.layers[l]
    local q, k, v = split_qkv(g, g:mul_mat(L.qkv, layer_norm(g, x, L.norm1_w, L.norm1_b, LN_EPS)), hd, H, T)
    q, k = rope(g, q, pos, hd, hp.base), rope(g, k, pos, hd, hp.base)
    g:expand(g:cpy(k, g:view(self.k[l], { hd, H, T }, { hd * F, cell }, P * cell)))
    g:expand(g:cpy(v, g:view(self.v[l], { hd, H, T }, { hd * F, cell }, P * cell)))
    x = g:add(x, g:mul_mat(L.out, attend(g, q, self.k[l], self.v[l], hd, H, T, n_kv, mask)))
    local f = gelu_tanh(g, g:mul_mat(L.up, layer_norm(g, x, L.norm2_w, L.norm2_b, LN_EPS)), self.on_cpu)
    x = tap("layer-" .. l, g:add(x, g:mul_mat(L.down, f)))
  end
  self.P = n_kv
  return x
end

-- Collects the tensors a caller asked to read: `taps` is a table whose keys name them.
-- A call with taps builds in a graph of its own: ggml's allocator reuses a graph's last
-- plan when the next one has as many nodes, and that plan may have given a tensor now
-- tapped memory that a later node overwrites.
local function graph_for(self, taps, g)
  if taps and next(taps) then
    local own = self.engine:graph(4096)
    return own, function () own:free() end
  end
  return g, function () end
end

local function tapper(taps)
  local list = {}
  local function tap(name, t)
    if taps and taps[name] then list[#list + 1] = { name, t } end
    return t
  end
  local function outputs(...)
    local outs = { ... }
    for _, t in ipairs(list) do outs[#outs + 1] = t[2] end
    return unpack(outs)
  end
  local function read(g)
    for _, t in ipairs(list) do taps[t[1]] = g:read(t[2]) end
  end
  return tap, outputs, read
end

--- Starts a chunk: the FlowLM goes back to just the voice and reads the text's token ids.
--- Answers the out_norm output at the last token (the reference's "prompt_cond").
function TTS:start(ids, max_frames, taps)
  if not self.voice then error("pocket_tts: no voice; load one with set_voice", 2) end
  local need = self.P0 + #ids + (max_frames or 0)
  if need > self.n_ctx then
    local voice = self.voice
    self:make_cache(need)
    self:set_voice(voice)
  end
  self.P = self.P0
  local hp = self.hp
  local g, done = graph_for(self, taps, self.graph)
  local tap, outputs, read = tapper(taps)
  g:reset()
  local T = #ids
  local tok = g:input("i32", T)
  local b = ml.buffer(T, "i32")
  for i = 1, T do b[i] = ids[i] end
  g:set(tok, b)
  local x = self:transformer(g, g:get_rows(self.text_embd, tok), T, tap)
  local last = g:view(x, { hp.d, 1 }, { hp.d * F }, (T - 1) * hp.d * F)
  local c = layer_norm(g, g:cont(last), self.out_norm_w, self.out_norm_b, LN_EPS)
  g:compute(outputs(c))
  read(g)
  local answer = g:read(c)
  done()
  return answer
end

-- The FlowLM's step for one frame, added to g: it reads the previous latent (nil for the
-- first frame, which reads the learned BOS), and the flow head turns `noise` into the next
-- latent. Answers the latent, in the model's normalised space, and the EOS logit.
function TTS:add_step(g, latent, noise, tap)
  local hp, H = self.hp, self.head
  local lat = self.bos_emb
  if latent then
    lat = g:input("f32", hp.ldim)
    g:set(lat, latent)
  end
  local x = self:transformer(g, g:mul_mat(self.input_linear, lat), 1, tap)
  local c = tap("cond", layer_norm(g, x, self.out_norm_w, self.out_norm_b, LN_EPS))
  local eos = g:add(g:mul_mat(self.out_eos_w, c), self.out_eos_b)

  -- The flow head, v(c, 0, 1, x0), and the latent x0 + v (notes, section 6).
  local x0 = g:input("f32", hp.ldim)
  g:set(x0, noise)
  local W = hp.head_width
  local sy = g:silu(g:add(g:add(g:mul_mat(H.cond_w, c), H.cond_b), self.tconst))
  local z = g:add(g:mul_mat(H.in_w, x0), H.in_b)
  local function chunk(m, i) return g:view(m, { W }, i * W * F) end
  for b = 0, hp.head_blocks - 1 do
    local B = H.blocks[b]
    local m = g:add(g:mul_mat(B.ada_w, sy), B.ada_b)          -- shift | scale | gate
    local u = layer_norm(g, z, B.ln_w, B.ln_b, HEAD_EPS)
    u = g:add(g:mul(u, g:scale_bias(chunk(m, 1), 1, 1)), chunk(m, 0))
    u = g:add(g:mul_mat(B.mlp2_w, g:silu(g:add(g:mul_mat(B.mlp0_w, u), B.mlp0_b))), B.mlp2_b)
    z = g:add(z, g:mul(chunk(m, 2), u))
  end
  local m = g:add(g:mul_mat(H.final_ada_w, sy), H.final_ada_b)  -- shift | scale
  local u = g:add(g:mul(g:norm(z, HEAD_EPS), g:scale_bias(chunk(m, 1), 1, 1)), chunk(m, 0))
  local v = tap("flow", g:add(g:mul_mat(H.final_w, u), H.final_b))
  return g:add(x0, v), eos
end

--- One frame of the FlowLM: the previous latent (nil for the first frame) and `noise`, 32
--- values of N(0, temperature), make the next latent. Answers it, in the model's
--- normalised space, and the EOS logit. `taps` may name cond, flow and layer-0 .. layer-5.
function TTS:step(latent, noise, taps)
  local g, done = graph_for(self, taps, self.graph)
  local tap, outputs, read = tapper(taps)
  g:reset()
  local out, eos = self:add_step(g, latent, noise, tap)
  g:compute(outputs(out, eos))
  read(g)
  local latent_out, logit = g:read(out), g:read(eos)[1]
  done()
  return latent_out, logit
end

-- ------------------------------------------------------------------ the Mimi decoder

--- Forgets the Mimi decoder's history: the next frame is the first of a chunk.
function TTS:mimi_reset()
  self.mstate:clear()
  self.mframe = 0
end

-- A causal convolution with stride 1, channels first: x (IC, T) after the last K-1 steps
-- it saw, which it replaces. A window of K steps is IC*K values in a row, channel fastest,
-- as the converted kernel's rows are; ggml will not view rows that overlap, so the windows
-- are copied out by im2col, reading the (IC, steps) signal as an image and each window as
-- an IC-wide, K-high patch of it (im2col's F32 form: its F16 one rounds, notes F2).
local function conv(g, x, c, IC, T, K, prev, next_prev)
  if K == 1 then return g:add(g:mul_mat(c.w, x), c.b) end
  local xc = g:concat(prev, x, 1)                                       -- (IC, K-1+T)
  local OC = select(2, c.w:shape())
  local cols = g:im2col(g:reshape(c.w, IC, K, 1, OC), xc, 1, 1, 0, 0, 1, 1, true, "f32")
  g:expand(g:cpy(g:view(xc, { IC * (K - 1) }, T * IC * F), next_prev))
  return g:add(g:mul_mat(c.w, g:reshape(cols, IC * K, T)), c.b)
end

-- A causal transposed convolution with kernel 2S and stride S, channels first. One product
-- gives each input step's 2S output steps; the first S of step t add to the last S of
-- step t-1, and the last S of the final step wait in `prev` for the next call (notes, 8.2).
local function convtr(g, x, c, OC, T, S, prev, next_prev)
  local K = 2 * S
  local cols = g:mul_mat(c.w, x)                                        -- (K*OC, T)
  local lo = g:view(cols, { OC * S, T }, { K * OC * F }, 0)
  local hi = g:view(cols, { OC * S, T }, { K * OC * F }, OC * S * F)
  local carried = g:reshape(prev, OC * S, 1)
  if T > 1 then carried = g:concat(carried, g:view(hi, { OC * S, T - 1 }, { K * OC * F }, 0), 1) end
  g:expand(g:cpy(g:view(cols, { OC * S }, (T - 1) * K * OC * F + OC * S * F), next_prev))
  return g:add(g:reshape(g:add(lo, carried), OC, S * T), c.b)
end

-- The Mimi decoder for nf latents z (a tensor of g, 32 x nf, normalised), added to g:
-- answers their samples, and moves the decoder's history on by nf frames. One frame reads
-- the transformer's keys from the ring; several at once start from a fresh decoder, attend
-- to their own keys, and leave the ring as one frame at a time would have.
function TTS:add_decode(g, z, nf, tap)
  local hp, M, S = self.hp, self.mimi, self.seanet
  local f = self.mframe
  if nf > 1 and f ~= 0 then error("pocket_tts: several frames at once start from a fresh decoder (mimi_reset)", 3) end
  -- frame f reads copy f % 2 and leaves copy (f + 1) % 2 for the next; several frames
  -- read the other copy from the one they leave, both zero in a fresh decoder
  local wr, rd = self.mcopies[(f + nf) % 2 + 1], self.mcopies[(f + nf + 1) % 2 + 1]
  local md, up = hp.md, hp.upsample
  local e = tap("quantizer", g:mul_mat(M.qproj, g:add(g:mul(z, self.emb_std), self.emb_mean)))   -- (512, nf)

  -- The depthwise upsample, kernel 2S: each 200 Hz step mixes its frame and the one before.
  local w_lo = g:view(M.upsample, { md, up }, { md * F }, 0)
  local w_hi = g:view(M.upsample, { md, up }, { md * F }, md * up * F)
  local x
  if nf == 1 then
    x = g:add(g:mul(w_lo, e), g:mul(w_hi, rd.e_prev))                                         -- (512, 16)
  else
    local before = g:concat(g:reshape(rd.e_prev, md, 1), g:view(e, { md, nf - 1 }, { md * F }, 0), 1)
    x = g:add(g:mul(g:repeat_4d(w_lo, md, up, nf), g:reshape(e, md, 1, nf)),
              g:mul(g:repeat_4d(w_hi, md, up, nf), g:reshape(before, md, 1, nf)))
    x = g:reshape(x, md, up * nf)
  end
  x = tap("upsample", x)
  g:expand(g:cpy(g:view(e, { md }, (nf - 1) * md * F), wr.e_prev))

  -- The transformer: 16 steps a frame at absolute positions 16f .., each key visible to a
  -- query at most context - 1 steps after it.
  local T, hd, H = up * nf, hp.m_hd, hp.m_heads
  local ring = hp.ring * up
  local slot = f % hp.ring
  local pos = g:input("i32", T)
  local p = ml.buffer(T, "i32")
  for i = 1, T do p[i] = f * up + i - 1 end
  g:set(pos, p)
  local n_kv = nf == 1 and ring or T
  local mask = g:input("f32", n_kv, T)
  -- Once every slot holds a frame, the mask depends only on which slot is this frame's,
  -- so it is made once per slot.
  local full = nf == 1 and f >= hp.ring - 1
  self.masks = self.masks or {}
  local mb = full and self.masks[slot]
  if not mb then
    mb = ml.buffer(n_kv * T)
    if nf == 1 then
      for s = 0, hp.ring - 1 do
        local fs = f - ((slot - s) % hp.ring)           -- the frame whose keys slot s holds
        for j = 0, up - 1 do
          local pk = fs * up + j
          for i = 0, T - 1 do
            local d = f * up + i - pk
            if fs < 0 or d < 0 or d >= hp.context then mb[i * ring + s * up + j + 1] = -math.huge end
          end
        end
      end
      if full then self.masks[slot] = mb end
    else
      for i = 0, T - 1 do
        for j = 0, T - 1 do
          if j > i or i - j >= hp.context then mb[i * T + j + 1] = -math.huge end
        end
      end
    end
  end
  g:set(mask, mb)
  local cell = hd * H * F
  for l = 0, hp.m_layer - 1 do
    local L = M.layers[l]
    local q, k, v = split_qkv(g, g:mul_mat(L.qkv, layer_norm(g, x, L.norm1_w, L.norm1_b, LN_EPS)), hd, H, T)
    q, k = rope(g, q, pos, hd, hp.base), rope(g, k, pos, hd, hp.base)
    local a
    if nf == 1 then
      g:expand(g:cpy(k, g:view(self.mimi_k[l], { hd, H, T }, { hd * F, cell }, slot * T * cell)))
      g:expand(g:cpy(v, g:view(self.mimi_v[l], { hd, H, T }, { hd * F, cell }, slot * T * cell)))
      a = attend(g, q, self.mimi_k[l], self.mimi_v[l], hd, H, T, ring, mask)
    else
      v = g:cont(v)
      a = attend(g, q, k, v, hd, H, T, T, mask)
      for i = math.max(0, nf - hp.ring), nf - 1 do      -- the frames a next frame still reaches
        local at = (i % hp.ring) * up * cell
        g:expand(g:cpy(g:view(k, { hd, H, up }, { hd * F, cell }, i * up * cell), g:view(self.mimi_k[l], { hd, H, up }, { hd * F, cell }, at)))
        g:expand(g:cpy(g:view(v, { hd, H, up }, { hd * F, cell }, i * up * cell), g:view(self.mimi_v[l], { hd, H, up }, { hd * F, cell }, at)))
      end
    end
    x = g:add(x, g:mul(g:mul_mat(L.out, a), L.scale1))
    local ff = g:mul_mat(L.down, gelu_tanh(g, g:mul_mat(L.up, layer_norm(g, x, L.norm2_w, L.norm2_b, LN_EPS)), self.on_cpu))
    x = g:add(x, g:mul(ff, L.scale2))
  end
  tap("transformer", x)

  -- The SEANet decoder (notes, 8): conv 7, then three of ELU, upsampling, residual block,
  -- then ELU and conv 3. Channels first throughout.
  local ch = self.channels
  x = tap("conv_in", conv(g, x, S.conv_in, ch[1], T, 7, rd.conv_in, wr.conv_in))
  for i = 1, #hp.ratios do
    local r = hp.ratios[i]
    x = tap("up." .. i, convtr(g, g:elu(x), S.up[i], ch[i + 1], T, r, rd.up[i], wr.up[i]))
    T = T * r
    local h = conv(g, g:elu(x), S.res[i][1], ch[i + 1], T, 3, rd.res[i], wr.res[i])
    h = conv(g, g:elu(h), S.res[i][2], idiv(ch[i + 1], 2), T, 1)
    x = tap("res." .. i, g:add(x, h))
  end
  self.mframe = f + nf
  return conv(g, g:elu(x), S.conv_out, ch[#ch], T, 3, rd.conv_out, wr.conv_out)
end

--- Decodes one latent (normalised, as step answers it) into 1920 samples, carrying the
--- decoder's history from the frame before. `taps` may name quantizer, upsample,
--- transformer, conv_in, up.1 .. up.3, res.1 .. res.3; each is (channels, steps),
--- channel fastest.
function TTS:decode(latent, taps)
  local g, done = graph_for(self, taps, self.mgraph)
  local tap, outputs, read = tapper(taps)
  g:reset()
  local z = g:input("f32", self.hp.ldim)
  g:set(z, latent)
  local audio = self:add_decode(g, z, 1, tap)
  g:compute(outputs(audio))
  read(g)
  local samples = g:read(audio)
  done()
  return samples
end

--- Decodes several latents at once (32 values each, one after another) from a fresh
--- decoder, as the reference's non-streaming decode does; frame by frame with decode
--- answers the same. The decoder can go on frame by frame after it. `taps` as decode's.
--- Its memory grows with the frames (the last stages hold 1920 x 64 x 3 values a frame),
--- so it is for a few seconds, not a book.
function TTS:decode_all(latents, taps)
  local nf = idiv(#latents, self.hp.ldim)
  local g, done = graph_for(self, taps, self.mgraph)
  local tap, outputs, read = tapper(taps)
  self:mimi_reset()
  g:reset()
  local z = g:input("f32", self.hp.ldim, nf)
  g:set(z, latents)
  local audio = self:add_decode(g, z, nf, tap)
  g:compute(outputs(audio))
  read(g)
  local samples = g:read(audio)
  done()
  return samples
end

--- One frame of speech in one graph: the FlowLM's step, then the Mimi decoder on the latent
--- it made, which never leaves the device in between. Answers the latent, the EOS logit
--- and the frame's samples. A frame that EOS says to drop has still moved the decoder on,
--- which only matters to a chunk that goes on after it, and none does.
function TTS:frame(latent, noise)
  local g = self.graph
  g:reset()
  local out, eos = self:add_step(g, latent, noise, tapper())
  local audio = self:add_decode(g, out, 1, tapper())
  g:compute(out, eos, audio)
  return g:read(out), g:read(eos)[1], g:read(audio)
end

-- ------------------------------------------------------------------ text

local function strip(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function words(s)
  local n = 0
  for _ in s:gmatch("%S+") do n = n + 1 end
  return n
end

-- Removes, from the end of s, any run of characters in `set` (a table of UTF-8 strings).
local function rstrip_set(s, set)
  local changed = true
  while changed and #s > 0 do
    changed = false
    for c in pairs(set) do
      if #s >= #c and s:sub(-#c) == c then s = s:sub(1, -#c - 1); changed = true; break end
    end
  end
  return s
end

local function set_of(...) local t = {} for _, c in ipairs { ... } do t[c] = true end return t end
local TERMINAL = set_of(".", "!", "?", "\226\128\166")
local WEAK = set_of(",", ";", ":", "-", "\226\128\147", "\226\128\148")
local CLOSERS = set_of('"', "'", "\226\128\157", "\226\128\153", ")", "]", "\194\187", " ")
local WEAK_SPACE = set_of(",", ";", ":", "-", "\226\128\147", "\226\128\148", " ")

local function last_char(s)
  for c in pairs(TERMINAL) do if s:sub(-#c) == c then return c, "terminal" end end
  for c in pairs(WEAK) do if s:sub(-#c) == c then return c, "weak" end end
end

--- The text the model reads for a prompt, and how many frames to keep after it says EOS
--- (notes, 3.1): newlines to spaces, one pass of double spaces to single, a capital first
--- letter, and sentence-final punctuation.
function pocket.prepare(text)
  text = strip(text)
  if text == "" then error("pocket_tts: there is no text to speak", 2) end
  text = text:gsub("\n", " "):gsub("\r", " "):gsub("  ", " ")
  local frames_after_eos = words(text) <= 4 and 3 or 1
  text = text:sub(1, 1):upper() .. text:sub(2)
  local core = rstrip_set(text, CLOSERS)
  local closers = strip(text:sub(#core + 1))
  local _, kind = last_char(core)
  if core ~= "" and kind ~= "terminal" then
    if kind == "weak" then text = rstrip_set(core, WEAK_SPACE) .. "." .. closers
    else text = text .. "." end
  end
  return text, frames_after_eos + 2
end

-- Text as SentencePiece decodes it: the leading space of the first piece is not text.
function TTS:decode_text(ids)
  local s = self.tok:decode(ids)
  return (s:gsub("^ ", ""))
end

function TTS:encode(text)
  return self.tok:encode(text, { special = false })
end

local function slice(t, i, j)
  local out = {}
  for k = i, j do out[#out + 1] = t[k] end
  return out
end

-- Where segments start: before the first token that follows a run of boundary tokens,
-- except after a decimal point (notes, 3.2). 0-based starts, the length last.
function TTS:boundaries(ids, ends, decimals)
  local starts, after = { 0 }, false
  for i, id in ipairs(ids) do
    if ends[id] then
      after = true
    else
      if after then
        local cut = true
        if decimals then
          local prefix, suffix = self:decode_text(slice(ids, 1, i - 1)), self:decode_text(slice(ids, i, #ids))
          if #prefix >= 2 and prefix:sub(-1) == "." and prefix:sub(-2, -2):match("%d") and suffix:sub(1, 1):match("%d") then
            cut = false
          end
        end
        if cut then starts[#starts + 1] = i - 1 end
      end
      after = false
    end
  end
  starts[#starts + 1] = #ids
  return starts
end

function TTS:segments(ids, starts)
  local out = {}
  for k = 1, #starts - 1 do
    out[#out + 1] = { starts[k + 1] - starts[k], self:decode_text(slice(ids, starts[k] + 1, starts[k + 1])) }
  end
  return out
end

--- The chunks a text is spoken in: sentences, packed up to max_tokens (50) tokens each;
--- a sentence longer than that is split after its commas, semicolons and colons.
function TTS:chunks(text)
  local limit = self.hp.max_tokens
  text = strip((pocket.prepare(text)))
  local ids = self:encode(text)
  local refined = {}
  for _, seg in ipairs(self:segments(ids, self:boundaries(ids, self.sentence_ends, true))) do
    if seg[1] <= limit then
      refined[#refined + 1] = seg
    else
      local sub = self:encode(strip(seg[2]))
      local parts = self:segments(sub, self:boundaries(sub, self.clause_ends, false))
      if #parts > 1 then
        for _, p in ipairs(parts) do refined[#refined + 1] = p end
      else
        refined[#refined + 1] = seg
      end
    end
  end
  local chunks, current, count = {}, "", 0
  for _, seg in ipairs(refined) do
    if current == "" then
      current, count = seg[2], seg[1]
    elseif count + seg[1] > limit then
      chunks[#chunks + 1] = strip(current)
      current, count = seg[2], seg[1]
    else
      current, count = current .. " " .. seg[2], count + seg[1]
    end
  end
  if current ~= "" then chunks[#chunks + 1] = strip(current) end
  return chunks
end

-- ------------------------------------------------------------------ speaking

--- Speaks a text. opts: { temperature = 0.3, seed = 0, on_audio = function (samples),
--- frames_after_eos, noise = function (step, chunk) -> 32 values, clock = ml.now }.
--- Each 80 ms frame's 1920 samples go to on_audio as soon as they are decoded. `noise`
--- replaces the seeded draws (a reference's recorded noise; step counts from 0 in each
--- chunk). Answers every sample (24 kHz, mono, f32, not clipped) and what happened:
--- frames, the chunks as spoken, each chunk's EOS step (false if none), seconds to the
--- first audio, seconds in all, seconds of audio.
function TTS:speak(text, opts)
  opts = opts or {}
  local hp = self.hp
  local now = opts.clock or ml.now
  local t0 = now()
  local temperature = opts.temperature or hp.temperature
  local std = math.sqrt(temperature)
  local rng = ml.rng(opts.seed or 0)
  local zeros = ml.buffer(hp.ldim)
  local pieces, info = {}, { frames = 0, chunks = {}, eos = {} }
  for n, chunk in ipairs(self:chunks(text)) do
    local prepared, after = pocket.prepare(chunk)
    after = opts.frames_after_eos or after
    local ids = self:encode(prepared)
    local max_frames = math.ceil((#ids / 3 + 2) * 12.5)
    self:start(ids, max_frames)
    self:mimi_reset()
    local latent, eos_step
    local frames = {}
    for step = 0, max_frames - 1 do
      local noise = zeros
      if opts.noise then noise = opts.noise(step, n)
      elseif temperature > 0 then noise = rng:normals(hp.ldim, std) end
      local next_latent, eos, audio = self:frame(latent, noise)
      if eos > hp.eos and not eos_step then eos_step = step end
      if eos_step and step >= eos_step + after then break end
      if not info.first_audio then info.first_audio = now() - t0 end
      if opts.on_audio then opts.on_audio(audio) end
      frames[#frames + 1] = audio
      latent = next_latent
    end
    info.frames = info.frames + #frames
    info.chunks[#info.chunks + 1] = prepared
    info.eos[#info.eos + 1] = eos_step or false
    -- joined a hundred frames at a time: unpack has a limit on what it spreads
    for i = 1, #frames, 100 do pieces[#pieces + 1] = ml.join(unpack(frames, i, math.min(i + 99, #frames))) end
  end
  info.seconds = now() - t0
  local samples = ml.buffer(0)
  if #pieces > 0 then samples = ml.join(unpack(pieces)) end
  info.audio_seconds = #samples / hp.rate
  return samples, info
end

--- Frees the weights, the state and the graphs now, not when they are collected.
function TTS:free()
  self.graph:free(); self.mgraph:free()
  if self.cache then self.cache:free() end
  if self.upcast then self.upcast:free() end
  self.mstate:free(); self.consts:free(); self.w:free()
end

return pocket
