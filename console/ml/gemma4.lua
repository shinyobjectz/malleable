-- gemma4 — Gemma 4 E2B, a small language model that runs on the console's engine.
--
--     local ml    = require "console.ml.engine"
--     local gemma = require "console.ml.gemma4"
--     local m = gemma.load(ml.engine(), "console/ml/models/gemma-4-E2B-it-q4_0.gguf")
--     print(m:chat({ { role = "user", text = "Name a moth." } }, { max_tokens = 32 }))
--
-- The forward pass is console/ml/notes/gemma4.md, section 4, step for step: per-layer
-- embeddings, 35 layers of which the last 20 read the KV cache of layer 13 (sliding) or 14
-- (full), two head sizes, RoPE with frequency factors on the full layers, and a tied,
-- soft-capped head. llama.cpp's src/models/gemma4.cpp is what it was checked against.

local ml = require "console.ml.engine"
local unpack = table.unpack or unpack

local gemma = {}

local NEOX = 2                       -- ggml's RoPE mode for GEMMA4
-- Attention reads the cache in whole blocks of 256 cells, the ones past the last position
-- masked, as llama.cpp does: CUDA's fast attention kernels need a multiple of 256.
local KV_PAD = 256

local Model = {}
Model.__index = Model

local function meta(w, key, default)
  local v = w:meta(key)
  if v == nil then
    if default == nil then error("gemma4: the file has no " .. key, 3) end
    return default
  end
  return v
end

--- Loads a Gemma 4 GGUF. opts: { context = 4096 } cells of KV cache.
function gemma.load(engine, path, opts)
  opts = opts or {}
  local w = engine:load(path, {
    -- one 8960-wide row per token of a 1.9 GB table: it stays on the CPU (notes, gotcha 18)
    host = function (name) return name == "per_layer_token_embd.weight" end,
    -- on a CPU engine, repack every product's weight; the two tables are looked up by row
    pack = function (name) return name ~= "token_embd.weight" and name ~= "per_layer_token_embd.weight" end,
  })
  local arch = meta(w, "general.architecture")
  if arch ~= "gemma4" then error("gemma4: " .. path .. " is a " .. tostring(arch) .. " model", 2) end
  local A = "gemma4."
  local hp = {
    n_layer = meta(w, A .. "block_count"),
    n_embd = meta(w, A .. "embedding_length"),
    n_head = meta(w, A .. "attention.head_count"),
    n_head_kv = meta(w, A .. "attention.head_count_kv"),
    hd_full = meta(w, A .. "attention.key_length"),
    hd_swa = meta(w, A .. "attention.key_length_swa"),
    base_full = meta(w, A .. "rope.freq_base"),
    base_swa = meta(w, A .. "rope.freq_base_swa"),
    window = meta(w, A .. "attention.sliding_window"),
    pattern = meta(w, A .. "attention.sliding_window_pattern"),
    shared = meta(w, A .. "attention.shared_kv_layers"),
    eps = meta(w, A .. "attention.layer_norm_rms_epsilon"),
    n_ple = meta(w, A .. "embedding_length_per_layer_input"),
    softcap = meta(w, A .. "final_logit_softcapping"),
    n_ctx_train = meta(w, A .. "context_length"),
  }
  if type(hp.n_head_kv) == "table" then hp.n_head_kv = hp.n_head_kv[1] end
  hp.n_own = hp.n_layer - hp.shared                 -- layers 0..n_own-1 own a KV cache
  -- which earlier layer a shared layer reads: the last owner of its type
  hp.last_swa, hp.last_full = nil, nil
  for il = 0, hp.n_own - 1 do
    if hp.pattern[il + 1] then hp.last_swa = il else hp.last_full = il end
  end

  local m = setmetatable({ engine = engine, w = w, hp = hp, path = path }, Model)
  m.tok = w:tokenizer()
  m.n_ctx = math.ceil((opts.context or 4096) / KV_PAD) * KV_PAD

  -- The layers' weights, looked up once.
  m.layers = {}
  for il = 0, hp.n_layer - 1 do
    local function t(name, optional)
      local x = w:get(("blk.%d.%s.weight"):format(il, name))
      if not x and not optional then error("gemma4: no blk." .. il .. "." .. name, 2) end
      return x
    end
    local swa = hp.pattern[il + 1] == true
    local L = {
      swa = swa, hd = swa and hp.hd_swa or hp.hd_full, base = swa and hp.base_swa or hp.base_full,
      own = il < hp.n_own,
      attn_norm = t "attn_norm", q = t "attn_q", q_norm = t "attn_q_norm",
      o = t "attn_output", post_attn = t "post_attention_norm",
      ffn_norm = t "ffn_norm", gate = t "ffn_gate", up = t "ffn_up", down = t "ffn_down",
      post_ffw = t "post_ffw_norm", inp_gate = t "inp_gate", proj = t "proj",
      post_norm = t "post_norm", scale = t "layer_output_scale",
    }
    if L.own then
      L.k, L.v, L.k_norm = t "attn_k", t "attn_v", t "attn_k_norm"
      L.src = il
    else
      L.src = swa and hp.last_swa or hp.last_full
    end
    m.layers[il] = L
  end
  m.token_embd = w:get "token_embd.weight"
  m.ple_embd = w:get "per_layer_token_embd.weight"
  m.ple_proj = w:get "per_layer_model_proj.weight"
  m.ple_norm = w:get "per_layer_proj_norm.weight"
  m.output_norm = w:get "output_norm.weight"
  m.rope_freqs = w:get "rope_freqs.weight"

  -- The KV cache: layers that own one, F16, one KV head, a cell per position.
  m.cache = engine:set(2 * hp.n_own + 2)
  m.k, m.v = {}, {}
  for il = 0, hp.n_own - 1 do
    local hd = m.layers[il].hd
    m.k[il] = m.cache:new("k" .. il, "f16", hd, m.n_ctx)
    m.v[il] = m.cache:new("v" .. il, "f16", hd, m.n_ctx)
  end
  m.cache:alloc()
  m.past = {}                        -- the token ids the cache holds, in order
  m.graph = engine:graph(8192)
  return m
end

-- The mask over n_kv cells for T queries at positions n_past .. n_past+T-1: 0 where a key
-- is visible, -inf where not; with a window, only the last `window` positions.
local function mask(n_past, T, n_kv, window)
  local b = ml.buffer(n_kv * T)
  local inf = -math.huge
  for i = 0, T - 1 do
    local p1 = n_past + i
    local row = i * n_kv
    for j = 0, n_kv - 1 do
      local visible = j <= p1 and (not window or p1 - j < window)
      b[row + j + 1] = visible and 0 or inf
    end
  end
  return b
end

--- Runs the tokens after what the cache holds. Answers the logits of the last token.
--- `taps`, if given, is a table keyed by llama.cpp's tensor names (inp_scaled, Qcur_pos-N,
--- Kcur_pos-N, Vcur_normed-N, kqv_out-N, attn_out-N, l_out-N); each named key is filled
--- with that tensor's buffer, for checking a layer.
function Model:forward(tokens, taps)
  local hp, g = self.hp, self.graph
  local tapped = {}
  local function tap(name, t) if taps and taps[name] then tapped[#tapped + 1] = { name, t } end return t end
  local T, n_past = #tokens, #self.past
  if n_past + T > self.n_ctx then error("gemma4: the context is full (" .. self.n_ctx .. " cells)", 2) end
  local n_kv = math.min(math.ceil((n_past + T) / KV_PAD) * KV_PAD, self.n_ctx)
  local E, P, NL, eps = hp.n_embd, hp.n_ple, hp.n_layer, hp.eps
  g:reset()

  local tok = g:input("i32", T)
  local ids = ml.buffer(T, "i32")
  local posb = ml.buffer(T, "i32")
  for i = 1, T do ids[i] = tokens[i]; posb[i] = n_past + i - 1 end
  g:set(tok, ids)
  local pos = g:input("i32", T)
  g:set(pos, posb)
  local mask_full = g:input("f16", n_kv, T)
  g:set(mask_full, mask(n_past, T, n_kv, nil))
  local mask_swa = g:input("f16", n_kv, T)
  g:set(mask_swa, mask(n_past, T, n_kv, hp.window))

  local function rms(x, w) return g:mul(g:rms_norm(x, eps), w) end

  -- 4.4: the embedding, and the per-layer inputs
  local x = tap("inp_scaled", g:scale(g:get_rows(self.token_embd, tok), math.sqrt(E)))
  local ple_t = g:scale(g:reshape(g:get_rows(self.ple_embd, tok), P, NL, T), math.sqrt(P))
  local ple_c = g:scale(g:mul_mat(self.ple_proj, x), 1 / math.sqrt(E))
  ple_c = rms(g:reshape(ple_c, P, NL, T), self.ple_norm)
  local ple = g:cont(g:permute(g:scale(g:add(ple_c, ple_t), 1 / math.sqrt(2)), 0, 2, 1, 3))   -- [P, T, NL]

  for il = 0, NL - 1 do
    local L = self.layers[il]
    local hd, H = L.hd, hp.n_head
    local rope_ff = not L.swa and self.rope_freqs or nil   -- only full layers scale their frequencies
    local h = rms(x, L.attn_norm)
    local q = rms(g:reshape(g:mul_mat(L.q, h), hd, H, T), L.q_norm)
    q = tap("Qcur_pos-" .. il, g:rope_ext(q, pos, rope_ff, hd, NEOX, hp.n_ctx_train, L.base, 1, 0, 1, 32, 1))
    if L.own then
      local k = rms(g:reshape(g:mul_mat(L.k, h), hd, 1, T), L.k_norm)
      local v = tap("Vcur_normed-" .. il, g:rms_norm(g:reshape(g:mul_mat(L.v, h), hd, 1, T), eps))
      k = tap("Kcur_pos-" .. il, g:rope_ext(k, pos, rope_ff, hd, NEOX, hp.n_ctx_train, L.base, 1, 0, 1, 32, 1))
      local row = hd * 2                                  -- f16 bytes per cell
      g:expand(g:cpy(g:reshape(k, hd, T), g:view(self.k[il], { hd, T }, { row }, n_past * row)))
      g:expand(g:cpy(g:reshape(v, hd, T), g:view(self.v[il], { hd, T }, { row }, n_past * row)))
    end
    local src = L.src
    local row = self.layers[src].hd * 2
    local K = g:view(self.k[src], { hd, n_kv, 1 }, { row, row * n_kv }, 0)
    local V = g:view(self.v[src], { hd, n_kv, 1 }, { row, row * n_kv }, 0)
    local o = g:flash_attn_ext(g:permute(q, 0, 2, 1, 3), K, V, L.swa and mask_swa or mask_full, 1.0, 0, 0)
    o = tap("kqv_out-" .. il, g:reshape(o, hd * H, T))
    o = rms(g:mul_mat(L.o, o), L.post_attn)
    local a = tap("attn_out-" .. il, g:add(o, x))
    local f = rms(a, L.ffn_norm)
    f = g:geglu_split(g:mul_mat(L.gate, f), g:mul_mat(L.up, f))
    f = rms(g:mul_mat(L.down, f), L.post_ffw)
    local y = g:add(f, a)
    local ple_l = g:view(ple, { P, T }, { P * 4 }, il * P * T * 4)
    local p = g:mul(g:gelu(g:mul_mat(L.inp_gate, y)), ple_l)
    p = rms(g:mul_mat(L.proj, p), L.post_norm)
    x = tap("l_out-" .. il, g:mul(g:add(y, p), L.scale))
  end

  -- 4.6: the last token's logits, soft-capped
  x = rms(x, self.output_norm)
  local last = g:cont(g:view(x, { E, 1 }, { E * 4 }, (T - 1) * E * 4))
  local logits = g:mul_mat(self.token_embd, last)
  logits = g:scale(g:tanh(g:scale(logits, 1 / hp.softcap)), hp.softcap)
  local outs = { logits }
  for i, t in ipairs(tapped) do outs[i + 1] = t[2] end
  g:compute(unpack(outs))
  for _, t in ipairs(tapped) do taps[t[1]] = g:read(t[2]) end
  for i = 1, T do self.past[n_past + i] = tokens[i] end
  return g:read(logits)
end

--- Forgets the cache from position n on (0 forgets everything).
function Model:rewind(n)
  for i = #self.past, n + 1, -1 do self.past[i] = nil end
end

-- The chat template (notes, 5.4): system and user text trimmed, a model turn keeps its answer.
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

function gemma.prompt(messages, thinking)
  local out = { "<bos>" }
  local first = 1
  if messages[1] and messages[1].role == "system" or thinking then
    local sys = messages[1] and messages[1].role == "system" and trim(messages[1].text) or ""
    out[#out + 1] = "<|turn>system\n" .. (thinking and "<|think|>\n" or "") .. sys .. "<turn|>\n"
    if messages[1] and messages[1].role == "system" then first = 2 end
  end
  for i = first, #messages do
    local msg = messages[i]
    local role = msg.role == "assistant" and "model" or msg.role
    local text = role == "model" and msg.text:gsub("<|channel>.-<channel|>", "") or trim(msg.text)
    out[#out + 1] = "<|turn>" .. role .. "\n" .. text .. "<turn|>\n"
  end
  out[#out + 1] = "<|turn>model\n"
  return table.concat(out)
end

local STOP = { [106] = true, [1] = true, [50] = true }

--- Generates after a prompt of token ids. opts: { max_tokens = 256, temperature = 1,
--- top_k = 64, top_p = 0.95, seed, on_piece = function (text) }. Answers the text and the
--- ids it generated, and how long the prompt and each token took.
function Model:generate(ids, opts)
  opts = opts or {}
  local now = opts.clock or os.clock
  -- Reuse what the cache already holds of this prompt.
  local keep = 0
  while keep < #ids and keep < #self.past and self.past[keep + 1] == ids[keep + 1] do keep = keep + 1 end
  if keep == #ids then keep = keep - 1 end             -- the last prompt token must run for its logits
  self:rewind(keep)
  local rest = {}
  for i = keep + 1, #ids do rest[#rest + 1] = ids[i] end
  local t0 = now()
  local logits
  local chunk = opts.batch or 256
  for i = 1, #rest, chunk do
    local piece = {}
    for j = i, math.min(i + chunk - 1, #rest) do piece[#piece + 1] = rest[j] end
    logits = self:forward(piece)
  end
  local t_prompt = now() - t0
  local rng = ml.rng(opts.seed or 0)
  local sampling = { temperature = opts.temperature or 1.0, top_k = opts.top_k or 64, top_p = opts.top_p or 0.95 }
  local out, text = {}, {}
  local t1 = now()
  for _ = 1, opts.max_tokens or 256 do
    local id = logits:sample(sampling, rng) - 1
    if STOP[id] then break end
    out[#out + 1] = id
    local piece = self.tok:piece(id)
    text[#text + 1] = piece
    if opts.on_piece then opts.on_piece(piece) end
    logits = self:forward({ id })
  end
  local t_gen = now() - t1
  return table.concat(text), out, { prompt_tokens = #rest, reused = keep, prompt_seconds = t_prompt,
                                    tokens = #out, generate_seconds = t_gen }
end

--- Frees the weights, the cache and the graph now, not when they are collected.
function Model:free()
  self.graph:free(); self.cache:free(); self.w:free()
end

--- A chat turn: messages { { role = "system" | "user" | "model", text } }. Answers the
--- reply's text, its ids, and the timings.
function Model:chat(messages, opts)
  opts = opts or {}
  local ids = self.tok:encode(gemma.prompt(messages, opts.thinking))
  return self:generate(ids, opts)
end

return gemma
