-- moonshine — Moonshine Streaming, speech to text as a person talks, on the console's engine.
--
--     local ml        = require "console.ml.engine"
--     local moonshine = require "console.ml.moonshine"
--     local asr = moonshine.load(ml.engine(), "console/ml/models/moonshine-streaming-small-f32.gguf")
--     print(asr:transcribe(ml.wav_read "jfk.wav"))          -- 16 kHz mono samples
--
--     local s = asr:stream()
--     for chunk in microphone do print(s:push(chunk)) end    -- the text so far
--     print(s:finish())                                      -- the final text
--
-- The forward pass is console/ml/notes/asr.md, sections 2 to 5: raw 16 kHz audio in 5 ms
-- frames, each normalised on its own and compressed with asinh, two causal stride-2
-- convolutions down to one frame per 20 ms, an encoder with sliding windows and no positions,
-- an adapter that adds a learned position table, and a decoder with partial RoPE and
-- cross-attention. The weights come from console/ml/convert/moonshine.lua.
--
-- The encoder is incremental (the notes' mode B). Each layer keeps the last frames of its
-- input in a set, and a push runs every layer only over the frames that have become final
-- since the last one: a frame of layer i is final once the r_i frames after it are final in
-- the layer below (r_i = 3 in the lookahead layers, 0 in the others), so the encoder's output
-- trails its input by 12 frames, 240 ms. The arithmetic is the one-shot arithmetic, only cut
-- at other places, so pushing a clip in pieces commits the same frames as encoding it whole.
-- Committed frames go through the adapter into each decoder layer's cross-attention keys and
-- values, in a set, once. The decoder re-reads the line from its start on each decode, since
-- its own keys depend on every frame; the previous text is checked in one batched pass and
-- only what the model no longer agrees with is decoded again (the notes' 3.5).

local ml = require "console.ml.engine"
local unpack = table.unpack or unpack

local moonshine = {}

local Model = {}
Model.__index = Model
local Stream = {}
Stream.__index = Stream

local NORMAL = 0                     -- ggml's RoPE mode that rotates interleaved pairs
local RATE = 16000
local BLOCK = 320                    -- samples per encoder frame: 4 frames of 80, halved twice
local INF = -math.huge

-- A whole number as an integer: GGUF's u32 values and an i32 buffer's values reach Lua 5.4
-- and later as floats (1126.0), which would print so in a token list.
local function whole(x) return math.floor(x + 0.5) end

local function meta(w, key, default)
  local v = w:meta("stt.moonshine_streaming." .. key)
  if v == nil then
    if default == nil then error("moonshine: the file has no stt.moonshine_streaming." .. key, 3) end
    return default
  end
  return v
end

--- Loads a Moonshine Streaming GGUF. opts: { seconds = 30, the longest line the caches
--- hold; cache = "f32" | "f16", the cross- and self-attention caches; block = 256, the most
--- encoder frames one graph takes }.
function moonshine.load(engine, path, opts)
  opts = opts or {}
  local w = engine:load(path)
  if w:meta "general.architecture" ~= "moonshine_streaming" then
    error("moonshine: " .. path .. " is a " .. tostring(w:meta "general.architecture") .. " model", 2)
  end
  local hp = {
    e_layers = meta(w, "encoder.n_layers"), e_width = meta(w, "encoder.d_model"),
    e_heads = meta(w, "encoder.n_heads"), e_hd = meta(w, "encoder.head_dim"),
    frame = meta(w, "encoder.frame_len"),
    d_layers = meta(w, "decoder.n_layers"), d_width = meta(w, "decoder.d_model"),
    d_heads = meta(w, "decoder.n_heads"), d_hd = meta(w, "decoder.head_dim"),
    vocab = meta(w, "decoder.vocab_size"), positions = meta(w, "decoder.max_position_embeddings"),
    rotary = meta(w, "partial_rotary_factor"), theta = meta(w, "rope_theta"),
    cmvn_eps = meta(w, "cmvn_eps", 1e-6),
    bos = meta(w, "decoder_start_token_id"), eos = meta(w, "eos_token_id"),
  }
  for key, v in pairs(hp) do
    if key ~= "rotary" and key ~= "theta" and key ~= "cmvn_eps" then hp[key] = whole(v) end
  end
  if not meta(w, "encoder_layernorm_unit_offset", false) then
    error("moonshine: the encoder's gains are not folded (+1); convert with console/ml/convert/moonshine.lua", 2)
  end
  hp.n_rot = math.floor(hp.d_hd * hp.rotary + 0.5)
  assert(hp.frame * 4 == BLOCK, "moonshine: frames of " .. hp.frame .. " samples")

  local m = setmetatable({ engine = engine, w = w, hp = hp, path = path }, Model)
  local function t(name, optional)
    local x = w:get(name)
    if not x and not optional then error("moonshine: the file has no " .. name, 3) end
    return x
  end
  m.k_comp = math.exp(t("enc.embedder.comp.log_k"):read()[1])
  m.lin = t "enc.embedder.linear.weight"
  m.c1, m.c1_b = t "enc.embedder.conv1.weight", t "enc.embedder.conv1.bias"
  m.c2, m.c2_b = t "enc.embedder.conv2.weight", t "enc.embedder.conv2.bias"

  -- Each encoder layer's window (L, R): it sees L-1 frames back and R-1 ahead.
  local windows = meta(w, "encoder.sliding_windows")
  m.enc = {}
  for i = 0, hp.e_layers - 1 do
    local p = "enc.blocks." .. i .. "."
    local L, R = windows[2 * i + 1], windows[2 * i + 2]
    m.enc[i] = {
      back = L - 1, ahead = math.max(R - 1, 0),
      norm_attn = t(p .. "norm_attn.weight"), q = t(p .. "attn.q.weight"), k = t(p .. "attn.k.weight"),
      v = t(p .. "attn.v.weight"), o = t(p .. "attn.out.weight"), norm_ffn = t(p .. "norm_ffn.weight"),
      fc1 = t(p .. "ffn.fc1.weight"), fc1_b = t(p .. "ffn.fc1.bias"),
      fc2 = t(p .. "ffn.fc2.weight"), fc2_b = t(p .. "ffn.fc2.bias"),
    }
    m.enc[i].keep = m.enc[i].back + m.enc[i].ahead   -- input frames a layer keeps between pushes
  end
  m.enc_norm = t "enc.final_norm.weight"
  m.pos_emb = t "adapter.pos_emb.weight"
  m.proj = t("adapter.proj.weight", true)
  m.dec = {}
  for j = 0, hp.d_layers - 1 do
    local p = "dec.blocks." .. j .. "."
    m.dec[j] = {
      norm_self = t(p .. "norm_self.weight"), q = t(p .. "self_attn.q.weight"), k = t(p .. "self_attn.k.weight"),
      v = t(p .. "self_attn.v.weight"), o = t(p .. "self_attn.out.weight"),
      norm_cross = t(p .. "norm_cross.weight"), cq = t(p .. "cross_attn.q.weight"),
      ck = t(p .. "cross_attn.k.weight"), cv = t(p .. "cross_attn.v.weight"), co = t(p .. "cross_attn.out.weight"),
      norm_ffn = t(p .. "norm_ffn.weight"), fc1 = t(p .. "ffn.fc1.weight"), fc1_b = t(p .. "ffn.fc1.bias"),
      fc2 = t(p .. "ffn.fc2.weight"), fc2_b = t(p .. "ffn.fc2.bias"),
    }
  end
  m.dec_norm = t "dec.final_norm.weight"
  m.token_embd = t "dec.token_embd.weight"
  m.head = t("dec.lm_head.weight", true) or m.token_embd   -- stored once when they are equal
  m.tok = w:tokenizer()

  -- The caches: the longest line in frames (20 ms) and in tokens (the budget, 6.5 a second).
  local seconds = opts.seconds or 30
  m.n_frames = math.min(math.floor(seconds * RATE / BLOCK), hp.positions)
  m.n_ctx = math.ceil(seconds * 6.5) + 8
  m.cache_type = opts.cache or "f32"
  m.es = m.cache_type == "f16" and 2 or 4
  m.block = opts.block or 256

  -- The state a line carries: the convolutions' last inputs and each encoder layer's last
  -- input frames (zeroed at each line), and the caches, which are only read where written.
  local De, Dd = hp.e_width, hp.d_width
  m.hist = engine:set(2 + hp.e_layers)
  m.h1 = m.hist:new("conv1_in", "f32", De, 4)
  m.h2 = m.hist:new("conv2_in", "f32", 2 * De, 4)
  m.eh = {}
  for i = 0, hp.e_layers - 1 do m.eh[i] = m.hist:new("enc_in" .. i, "f32", De, m.enc[i].keep) end
  m.hist:alloc()
  m.cache = engine:set(4 * hp.d_layers)
  m.ck, m.cv, m.sk, m.sv = {}, {}, {}, {}
  for j = 0, hp.d_layers - 1 do
    m.ck[j] = m.cache:new("cross_k" .. j, m.cache_type, Dd, m.n_frames)
    m.cv[j] = m.cache:new("cross_v" .. j, m.cache_type, Dd, m.n_frames)
    m.sk[j] = m.cache:new("self_k" .. j, m.cache_type, Dd, m.n_ctx)
    m.sv[j] = m.cache:new("self_v" .. j, m.cache_type, Dd, m.n_ctx)
  end
  m.cache:alloc()
  m.genc = engine:graph(4096)
  m.gdec = engine:graph(4096)
  return m
end

-- The mask of an encoder layer: n_q queries at absolute frames q0.., W keys at absolute
-- frames base..; a key is seen when it is at most back frames before the query or at most
-- ahead frames after it, and not before the line's start. ne = [W, n_q], 0 or -inf.
local function window_mask(base, W, q0, n_q, back, ahead)
  local b = ml.buffer(W * n_q):fill(INF)
  for j = 0, n_q - 1 do
    local q = q0 + j
    local lo, hi = math.max(q - back, base, 0), math.min(q + ahead, base + W - 1)
    local row = j * W - base + 1
    for a = lo, hi do b[row + a] = 0 end
  end
  return b
end

-- The decoder's causal mask for n queries after n_past cached tokens. ne = [n_past+n, n].
local function causal_mask(n_past, n)
  local n_kv = n_past + n
  local b = ml.buffer(n_kv * n):fill(INF)
  for i = 0, n - 1 do
    for j = 0, n_past + i do b[i * n_kv + j + 1] = 0 end
  end
  return b
end

--- A new line: the state is zeroed, the caches forgotten. opts: { every = 0.24, seconds of
--- audio between updates of the text while pushing (0 updates on every push); taps = true
--- keeps the frontend's, the encoder's and the adapter's outputs for checking }.
function Model:stream(opts)
  opts = opts or {}
  self.hist:clear()
  local every = opts.every
  if every == nil then every = 0.24 end
  local s = setmetatable({
    model = self, pending = ml.buffer(0), samples = 0,
    N = 0,                               -- encoder input frames the frontend has made
    f = {},                              -- f[i]: output frames of encoder layer i that are final
    decoded_at = 0,
    -- Audio waits until an update is due and is then encoded in one graph: the text only
    -- changes at a decode, and on a GPU each graph costs a few milliseconds whatever its size.
    every = math.max(BLOCK, math.floor(every * RATE + 0.5)),
    ids = {}, text = "", finished = false,
    taps = opts.taps and { features = {}, encoder = {}, adapter = {}, cross_k0 = {} } or nil,
  }, Stream)
  for i = 0, self.hp.e_layers - 1 do s.f[i] = 0 end
  self.active = s
  return s
end

-- One graph: the frontend over k new encoder frames (320k samples, or none), then each
-- encoder layer over the frames that became final, then the adapter and the cross keys and
-- values of the committed frames. `final` makes every frame final, as at the end of a line.
function Stream:encode(samples, k, final)
  local m, hp, g = self.model, self.model.hp, self.model.genc
  local De, A, He, hd = hp.e_width, hp.e_heads * hp.e_hd, hp.e_heads, hp.e_hd
  g:reset()
  local outs, tapped = {}, {}
  local function tap(name, x) if self.taps then tapped[#tapped + 1] = { name, x }; outs[#outs + 1] = x end end
  local function ln(x, w) return g:mul(g:norm(x, 1e-5), w) end
  local work = false

  -- Frontend (notes F1-F6).
  local new = nil                                  -- the newest frames of the layer below
  local N_old = self.N
  if k > 0 then
    local x = g:input("f32", hp.frame, 4 * k)
    g:set(x, samples)
    x = g:norm(x, hp.cmvn_eps)                     -- each 5 ms frame to zero mean, unit variance
    local z = g:scale(x, m.k_comp)
    -- asinh(z) = sgn(z) log(|z| + sqrt(z^2 + 1)), written for |z| so that negative z does
    -- not cancel
    local y = g:mul(g:sgn(z), g:log(g:add(g:abs(z), g:sqrt(g:scale_bias(g:sqr(z), 1, 1)))))
    local h = g:silu(g:mul_mat(m.lin, y))          -- [De, 4k]
    -- Two causal convolutions, k=5, stride 2: each one's left context is the last four
    -- columns it read, kept in the set. im2col in f32 and a product, so nothing rounds to
    -- f16 as conv_1d would.
    local function conv(hist, x_new, w, b, c_in, c_out, n_in)
      local c = g:concat(hist, x_new, 1)            -- [c_in, n_in + 4]
      g:expand(g:cpy(g:view(c, { c_in, 4 }, { c_in * 4 }, n_in * c_in * 4), hist))
      local cT = g:reshape(g:cont(g:transpose(c)), n_in + 4, c_in, 1)
      local col = g:im2col(w, cT, 2, 0, 0, 0, 1, 0, false, "f32")     -- [5 c_in, n_in / 2]
      local y = g:mul_mat(g:reshape(w, 5 * c_in, c_out), g:reshape(col, 5 * c_in, n_in / 2))
      return g:add(y, b)
    end
    local u = g:silu(conv(m.h1, h, m.c1, m.c1_b, De, 2 * De, 4 * k))
    new = conv(m.h2, u, m.c2, m.c2_b, 2 * De, De, 2 * k)                -- [De, k]
    tap("features", new)
    self.N = self.N + k
    work = true
  end

  -- Encoder layers (notes 3.2 and mode B of 3.5). f_prev_old and f_prev_new are the final
  -- frames of the layer below before and after this push.
  local f_prev_old, f_prev_new = N_old, self.N
  local masks = {}
  for i = 0, hp.e_layers - 1 do
    local L = m.enc[i]
    local f_old = self.f[i]
    local f_new = final and f_prev_new or math.max(f_old, f_prev_new - L.ahead)
    local n_prev = f_prev_new - f_prev_old
    local n_q = f_new - f_old
    -- The keys: the kept input frames, then the new ones. kv column c is frame base + c.
    local base = f_prev_old - L.keep
    local kv = m.eh[i]
    if n_prev > 0 then
      kv = g:concat(m.eh[i], new, 1)
      g:expand(g:cpy(g:view(kv, { De, L.keep }, { De * 4 }, n_prev * De * 4), m.eh[i]))
    end
    local out = nil
    if n_q > 0 then
      local W = L.keep + n_prev
      local q0 = f_old - base                      -- the first query's column
      -- A mask depends only on where the keys sit against the queries, until the keys reach
      -- back before the line's start; then where the start falls matters too.
      local key = table.concat({ math.min(base, 0), base - f_old, W, n_q, L.back, L.ahead }, ",")
      local mask = masks[key]
      if not mask then
        mask = g:input("f16", W, n_q)
        g:set(mask, window_mask(base, W, f_old, n_q, L.back, L.ahead))
        masks[key] = mask
      end
      local x = g:view(kv, { De, n_q }, { De * 4 }, q0 * De * 4)
      local h = ln(kv, L.norm_attn)                -- [De, W]
      local hq = g:view(h, { De, n_q }, { De * 4 }, q0 * De * 4)
      local q = g:permute(g:reshape(g:mul_mat(L.q, hq), hd, He, n_q), 0, 2, 1, 3)
      local kk = g:permute(g:reshape(g:mul_mat(L.k, h), hd, He, W), 0, 2, 1, 3)
      local v = g:permute(g:reshape(g:mul_mat(L.v, h), hd, He, W), 0, 2, 1, 3)
      local o = g:flash_attn_ext(q, kk, v, mask, 1 / math.sqrt(hd), 0, 0)   -- [hd, He, n_q]
      x = g:add(x, g:mul_mat(L.o, g:reshape(o, A, n_q)))
      local f = g:gelu_erf(g:add(g:mul_mat(L.fc1, ln(x, L.norm_ffn)), L.fc1_b))
      out = g:add(x, g:add(g:mul_mat(L.fc2, f), L.fc2_b))                  -- [De, n_q]
      work = true
    end
    self.f[i] = f_new
    f_prev_old, f_prev_new = f_old, f_new
    new = out
  end

  -- The committed frames: final norm, the adapter (notes 3.3), and every decoder layer's
  -- cross keys and values, written once into the cache.
  local c_old, c_new = f_prev_old, f_prev_new
  if c_new > c_old then
    if c_new > m.n_frames then
      error(("moonshine: the line is longer than the %d frames the caches hold (load with a larger seconds)"):format(m.n_frames), 3)
    end
    local n = c_new - c_old
    local e = ln(new, m.enc_norm)
    tap("encoder", e)
    local ids = g:input("i32", n)
    local b = ml.buffer(n, "i32")
    for j = 1, n do b[j] = c_old + j - 1 end
    g:set(ids, b)
    local a = g:add(e, g:get_rows(m.pos_emb, ids))
    if m.proj then a = g:mul_mat(m.proj, a) end
    tap("adapter", a)
    local Dd, es = hp.d_width, m.es
    for j = 0, hp.d_layers - 1 do
      local D = m.dec[j]
      local kx = g:mul_mat(D.ck, a)
      if j == 0 then tap("cross_k0", kx) end
      g:expand(g:cpy(kx, g:view(m.ck[j], { Dd, n }, { Dd * es }, c_old * Dd * es)))
      g:expand(g:cpy(g:mul_mat(D.cv, a), g:view(m.cv[j], { Dd, n }, { Dd * es }, c_old * Dd * es)))
    end
  end
  if work then
    g:compute(unpack(outs))
    for _, t in ipairs(tapped) do
      local list = self.taps[t[1]]
      list[#list + 1] = g:read(t[2])
    end
  end
end

-- Feeds whole 320-sample blocks to the encoder, at most `block` frames to a graph, and
-- keeps what is left over for the next push.
function Stream:feed(samples)
  local m = self.model
  local all = #self.pending > 0 and ml.join(self.pending, samples) or samples
  local blocks = math.floor(#all / BLOCK)
  local at = 0
  while at < blocks do
    local k = math.min(m.block, blocks - at)
    self:encode(all:slice(at * BLOCK + 1, (at + k) * BLOCK), k, false)
    at = at + k
  end
  self.pending = all:slice(blocks * BLOCK + 1, #all)
end

-- The decoder over n tokens at positions n_past.., reading `frames` cross columns. Writes
-- their keys and values into the self cache. Answers each position's best token (an i32
-- buffer of ids), and the logits when asked.
function Model:pass(tokens, n_past, frames, want_logits)
  local hp, g = self.hp, self.gdec
  local n = #tokens
  if n_past + n > self.n_ctx then error("moonshine: more tokens than the cache holds (" .. self.n_ctx .. ")", 3) end
  local Dd, H, hd, es = hp.d_width, hp.d_heads, hp.d_hd, self.es
  local n_kv = n_past + n
  g:reset()
  local function ln(x, w) return g:mul(g:norm(x, 1e-5), w) end
  local tok = g:input("i32", n)
  local pos = g:input("i32", n)
  local ids, posb = ml.buffer(n, "i32"), ml.buffer(n, "i32")
  for i = 1, n do ids[i] = tokens[i]; posb[i] = n_past + i - 1 end
  g:set(tok, ids)
  g:set(pos, posb)
  local mask = nil
  if n > 1 then
    mask = g:input("f16", n_kv, n)
    g:set(mask, causal_mask(n_past, n))
  end
  local scale = 1 / math.sqrt(hd)
  local x = g:get_rows(self.token_embd, tok)                     -- [Dd, n]
  for j = 0, hp.d_layers - 1 do
    local D = self.dec[j]
    -- Self-attention with RoPE on the first 32 dims of each head, interleaved pairs.
    local h = ln(x, D.norm_self)
    local q = g:rope_ext(g:reshape(g:mul_mat(D.q, h), hd, H, n), pos, nil, hp.n_rot, NORMAL, hp.positions, hp.theta, 1, 0, 1, 0, 0)
    local k = g:rope_ext(g:reshape(g:mul_mat(D.k, h), hd, H, n), pos, nil, hp.n_rot, NORMAL, hp.positions, hp.theta, 1, 0, 1, 0, 0)
    g:expand(g:cpy(g:reshape(k, Dd, n), g:view(self.sk[j], { Dd, n }, { Dd * es }, n_past * Dd * es)))
    g:expand(g:cpy(g:mul_mat(D.v, h), g:view(self.sv[j], { Dd, n }, { Dd * es }, n_past * Dd * es)))
    local K = g:view(self.sk[j], { hd, n_kv, H }, { Dd * es, hd * es }, 0)
    local V = g:view(self.sv[j], { hd, n_kv, H }, { Dd * es, hd * es }, 0)
    local o = g:flash_attn_ext(g:permute(q, 0, 2, 1, 3), K, V, mask, scale, 0, 0)
    x = g:add(x, g:mul_mat(D.o, g:reshape(o, Dd, n)))
    -- Cross-attention over every committed frame; no mask, no positions.
    h = ln(x, D.norm_cross)
    local cq = g:permute(g:reshape(g:mul_mat(D.cq, h), hd, H, n), 0, 2, 1, 3)
    local CK = g:view(self.ck[j], { hd, frames, H }, { Dd * es, hd * es }, 0)
    local CV = g:view(self.cv[j], { hd, frames, H }, { Dd * es, hd * es }, 0)
    o = g:flash_attn_ext(cq, CK, CV, nil, scale, 0, 0)
    x = g:add(x, g:mul_mat(D.co, g:reshape(o, Dd, n)))
    -- SwiGLU with the gate in the second half of fc1's output.
    h = ln(x, D.norm_ffn)
    local u = g:swiglu_swapped(g:add(g:mul_mat(D.fc1, h), D.fc1_b))
    x = g:add(x, g:add(g:mul_mat(D.fc2, u), D.fc2_b))
  end
  local logits = g:mul_mat(self.head, ln(x, self.dec_norm))      -- [V, n]
  local best = g:argmax(logits)
  if want_logits then g:compute(best, logits) else g:compute(best) end
  local ids_out = g:read(best)
  if want_logits then return ids_out, g:read(logits) end
  return ids_out
end

-- The length of the n-gram, 3 to 10 tokens, that the last 3n tokens repeat three times
-- over: the loop the model card warns about on noise. Not in any reference; the budget is
-- the other guard.
local function looping(out)
  for n = 3, 10 do
    local len = #out
    if len < 3 * n then return nil end
    local same = true
    for i = len - n + 1, len do
      if out[i] ~= out[i - n] or out[i] ~= out[i - 2 * n] then same = false; break end
    end
    if same then return n end
  end
  return nil
end

-- A decode over the committed frames: the last text checked in one pass, then greedy steps
-- from the first token the model no longer agrees with, to EOS or the budget (HF's
-- max_length, int(samples * 6.5 / 16000), counting the start token).
function Stream:decode()
  local m, hp = self.model, self.model.hp
  local frames = self.f[hp.e_layers - 1]
  self.decoded_at = frames
  local budget = math.min(math.floor(self.samples * 6.5 / RATE) - 1, m.n_ctx - 1)
  if frames == 0 or budget <= 0 then self.ids = {}; return end
  local given = { hp.bos }
  for i = 1, math.min(#self.ids, budget - 1) do given[i + 1] = self.ids[i] end
  local best = m:pass(given, 0, frames)
  local out, d = {}, 0
  while d < #given - 1 and whole(best[d + 1]) == given[d + 2] do d = d + 1; out[d] = given[d + 1] end
  local nxt, n_past = whole(best[d + 1]), d + 1
  while nxt ~= hp.eos and #out < budget do
    out[#out + 1] = nxt
    local n = looping(out)
    if n then
      for _ = 1, 2 * n do out[#out] = nil end
      break
    end
    if #out >= budget then break end
    nxt = whole(m:pass({ nxt }, n_past, frames)[1])
    n_past = n_past + 1
  end
  self.ids = out
end

-- Text of ids: specials skipped, U+2581 as spaces, one leading space dropped. While the line
-- is open, a character cut between byte tokens is held back.
local function text_of(tok, ids, closed)
  local s = tok:decode(ids):gsub("^ ", "")
  if not closed then
    local n = #s
    for back = 1, math.min(3, n) do
      local c = s:byte(n - back + 1)
      if c >= 0xC0 then
        local need = 2
        if c >= 0xF0 then need = 4 elseif c >= 0xE0 then need = 3 end
        if back < need then s = s:sub(1, n - back) end
        break
      elseif c < 0x80 then
        break
      end
    end
  end
  return s
end

local function samples_of(x)
  if type(x) == "table" then return ml.buffer(x) end
  return x
end

--- Pushes 16 kHz mono samples (a buffer or a table) and answers the text so far: the
--- decode of every frame that is final, brought up to date once `every` seconds of audio
--- have come since the last time.
function Stream:push(samples)
  if self.finished then error("moonshine: the stream is finished; start another", 2) end
  if self.model.active ~= self then error("moonshine: another stream has the model now", 2) end
  samples = samples_of(samples)
  self.samples = self.samples + #samples
  if #self.pending + #samples < self.every then
    self.pending = #self.pending > 0 and ml.join(self.pending, samples) or samples:slice(1, #samples)
    return self.text
  end
  self:feed(samples)
  if self.f[self.model.hp.e_layers - 1] > self.decoded_at then
    self:decode()
    self.text = text_of(self.model.tok, self.ids, false)
  end
  return self.text
end

--- Ends the line: the last partial 5 ms frame is zeroed and the line padded to a whole block,
--- as the reference pads it, every frame is committed, and the line decoded once more.
--- Answers the final text and its token ids.
function Stream:finish()
  if self.finished then return self.text, self.ids end
  if self.model.active ~= self then error("moonshine: another stream has the model now", 2) end
  local m = self.model
  if #self.pending > m.block * BLOCK then self:feed(ml.buffer(0)) end
  local r, frame = #self.pending, m.hp.frame
  local k, block = math.ceil(r / BLOCK), nil
  if k > 0 then
    local kept = math.floor(r / frame) * frame
    block = ml.join(self.pending:slice(1, kept), ml.buffer(k * BLOCK - kept))
  end
  self.pending = ml.buffer(0)
  self:encode(block, k, true)
  self:decode()
  self.finished = true
  self.text = text_of(self.model.tok, self.ids, true)
  return self.text, self.ids
end

--- The logits for token ids (the start token first) over every committed frame: [V, n],
--- for checking against the reference. Rewrites the self cache.
function Stream:logits(ids)
  local _, logits = self.model:pass(ids, 0, self.f[self.model.hp.e_layers - 1], true)
  return logits
end

--- A clip at once: its text and ids. The same as pushing it into a stream and finishing,
--- without decoding on the way.
function Model:transcribe(samples)
  local s = self:stream()
  samples = samples_of(samples)
  s.samples = #samples
  s:feed(samples)
  return s:finish()
end

--- Frees the weights, the caches and the graphs now, not when they are collected.
function Model:free()
  self.genc:free(); self.gdec:free(); self.hist:free(); self.cache:free(); self.w:free()
end

return moonshine
