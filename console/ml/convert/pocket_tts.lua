-- pocket_tts — converts Kyutai's Pocket TTS checkpoint and its voices to GGUF, once.
--
--     luajit console/ml/convert/pocket_tts.lua model <model.safetensors> <tokenizer.model> <out.gguf> [f16]
--     luajit console/ml/convert/pocket_tts.lua voice <alba.safetensors> <out.gguf>
--
-- The checkpoint is kyutai/pocket-tts-without-voice-cloning, languages/english (notes,
-- section 1). Every weight is written as F32: the published BF16 values exactly, because
-- a BF16 or F16 weight makes ggml's CPU product round the activations too (notes, F1).
--
-- With "f16", the FlowLM's large matrices (its transformer's and the flow head's) are F16
-- instead: 231 MB, not 399. Every BF16 value they hold is an F16 value too, except the
-- 0.15% smaller than F16's normal range, which move by at most 3e-8. A GPU reads half the
-- bytes per frame and keeps its activations in f32 (Metal's matrix-vector product does);
-- console/ml/pocket_tts.lua casts these matrices back to F32 when it runs on the CPU.
--
-- What changes on the way, and why:
--   * The names lose their "flow_lm." prefix, and the Mimi decoder transformer's long
--     "mimi.decoder_transformer.transformer.layers.N." becomes "mimi.dec_tr.N.": sixteen
--     names are longer than ggml's 63 characters (notes, F12).
--   * The voice-cloning half (the Mimi encoder, its transformer, the downsample and the
--     speaker projection) is left out. It is zeroed in this checkpoint anyway.
--   * The Mimi decoder's convolutions are laid out for the way console/ml/pocket_tts.lua
--     runs them, channels first: a Conv1d [OC, IC, K] becomes ne = (IC*K, OC), each row
--     the kernel's taps with the input channel fastest, so a window of the signal is one
--     row of a matrix product; a ConvTranspose1d [IC, OC, K] becomes ne = (IC, K*OC), so
--     one product gives every tap for every input step; the depthwise upsample [512, 1, 32]
--     becomes ne = (512, 32). The values are the checkpoint's; only their order moves.
--   * The tokenizer.model protobuf becomes the tokenizer.ggml.* metadata the engine's
--     "llama" (SentencePiece unigram) tokenizer reads.
--
-- A voice file holds each layer's K and V after RoPE at positions 0..P-1, split from the
-- 5-D [2, 1, P, 16, 64] cache the checkpoint ships (notes, 4.1).

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../../../?.lua;" .. package.path
local ml = require "console.ml.engine"

local function fail(msg) io.stderr:write("pocket_tts: ", msg, "\n"); os.exit(1) end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then fail("could not open " .. path) end
  local s = f:read("*a")
  f:close()
  return s
end

-- ------------------------------------------------------------------ the tokenizer

-- A protobuf reader for SentencePiece's ModelProto: field 1 is each piece, a message of
-- 1 (the text), 2 (the score, a float) and 3 (the type, NORMAL when absent).
local function varint(s, i)
  local v, mul = 0, 1
  while true do
    local b = s:byte(i)
    i = i + 1
    v = v + (b % 128) * mul
    if b < 128 then return v, i end
    mul = mul * 128
  end
end

local function fields(s, from, to, each)
  local i = from
  while i < to do
    local key
    key, i = varint(s, i)
    local field, wire = math.floor(key / 8), key % 8
    if wire == 0 then
      local v
      v, i = varint(s, i)
      each(field, wire, v)
    elseif wire == 1 then
      each(field, wire, s:sub(i, i + 7)); i = i + 8
    elseif wire == 2 then
      local n
      n, i = varint(s, i)
      each(field, wire, i, i + n)
      i = i + n
    elseif wire == 5 then
      each(field, wire, s:sub(i, i + 3)); i = i + 4
    else
      fail("the tokenizer.model has a wire type " .. wire .. " this reader does not know")
    end
  end
end

local function tokenizer(path)
  local s = read_file(path)
  local tokens, scores, types = {}, {}, {}
  fields(s, 1, #s + 1, function (field, wire, a, b)
    if field ~= 1 or wire ~= 2 then return end
    local text, score, kind = "", 0, 1
    fields(s, a, b, function (f, w, x, y)
      if f == 1 and w == 2 then text = s:sub(x, y - 1)
      elseif f == 2 and w == 5 then score = ml.decode(x, "f32")[1]
      elseif f == 3 and w == 0 then kind = x end
    end)
    tokens[#tokens + 1] = text
    scores[#scores + 1] = score
    types[#types + 1] = kind
  end)
  return tokens, scores, types
end

-- ------------------------------------------------------------------ the weights

local cpu = ml.engine { device = "cpu", threads = 4 }

-- Reorders a tensor's values on the engine: `ne` is the checkpoint's shape in ggml's
-- order, the axes are ggml_permute's.
local function permute(values, ne, a0, a1, a2)
  local g = cpu:graph(16)
  local x = g:input("f32", ne[1], ne[2], ne[3])
  g:set(x, values)
  local y = g:cont(g:permute(x, a0, a1, a2, 3))
  g:compute(y)
  local out = g:read(y)
  g:free()
  return out
end

-- The checkpoint's shape, torch order, as ggml's ne (fastest first).
local function ne_of(shape)
  local ne = {}
  for k = #shape, 1, -1 do ne[#ne + 1] = shape[k] end
  if #ne == 0 then ne[1] = 1 end
  return ne
end

local function skipped(name)
  return name:find("^mimi%.encoder") or name:find("^mimi%.downsample") or name == "flow_lm.speaker_proj_weight"
end

local function renamed(name)
  name = name:gsub("^flow_lm%.", "")
  name = name:gsub("^mimi%.decoder_transformer%.transformer%.layers%.", "mimi.dec_tr.")
  return name
end

-- The FlowLM matrices an "f16" file keeps in F16: the ones a frame reads in full.
local function large_matrix(short, ne)
  if #ne ~= 2 or ne[1] < 512 then return false end
  return short:find("^transformer%.layers%.") or (short:find("^flow_net%.") and not short:find("time_embed"))
end

local function convert_model(model_path, tokenizer_path, out, matrices)
  local reader, header = ml.safetensors(model_path)
  local names = {}
  for name in pairs(header) do if name ~= "__metadata__" then names[#names + 1] = name end end
  table.sort(names)

  local w = ml.gguf_writer()
  w:set("general.architecture", "pocket_tts")
  w:set("general.name", "Pocket TTS (english)")
  w:set("general.license", "CC-BY-4.0")
  w:set("general.source.url", "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning")
  local A = "pocket_tts."
  w:set(A .. "sample_rate", 24000, "u32")
  w:set(A .. "frame_samples", 1920, "u32")
  w:set(A .. "latent_dim", 32, "u32")
  w:set(A .. "flow.block_count", 6, "u32")
  w:set(A .. "flow.embedding_length", 1024, "u32")
  w:set(A .. "flow.head_count", 16, "u32")
  w:set(A .. "flow.head_width", 512, "u32")
  w:set(A .. "flow.head_blocks", 6, "u32")
  w:set(A .. "mimi.block_count", 2, "u32")
  w:set(A .. "mimi.embedding_length", 512, "u32")
  w:set(A .. "mimi.head_count", 8, "u32")
  w:set(A .. "mimi.context", 250, "u32")
  w:set(A .. "mimi.upsample", 16, "u32")
  w:set(A .. "mimi.ratios", { 6, 5, 4 }, "u32")
  w:set(A .. "rope.freq_base", 10000)
  w:set(A .. "eos_threshold", -4.0)
  w:set(A .. "default_temperature", 0.3)
  w:set(A .. "max_tokens", 50, "u32")

  local tokens, scores, types = tokenizer(tokenizer_path)
  w:set("tokenizer.ggml.model", "llama")
  w:set("tokenizer.ggml.tokens", tokens)
  w:set("tokenizer.ggml.scores", scores)
  w:set("tokenizer.ggml.token_type", types, "i32")
  w:set("tokenizer.ggml.unknown_token_id", 0, "u32")
  w:set("tokenizer.ggml.bos_token_id", 1, "u32")
  w:set("tokenizer.ggml.eos_token_id", 2, "u32")
  w:set("tokenizer.ggml.add_bos_token", false)
  w:set("tokenizer.ggml.add_space_prefix", true)

  local n, params = 0, 0
  for _, name in ipairs(names) do
    local h = header[name]
    if not skipped(name) then
      local values = reader:read(h.dtype, h.data_offsets[1], h.data_offsets[2])
      local ne = ne_of(h.shape)
      local short = renamed(name)
      if name:find("^mimi%.decoder%.model%.%d+%.convtr%.weight$") then
        -- [IC, OC, K] = ne (K, OC, IC) -> ne (IC, OC, K), rows of IC: row k*OC + oc
        local K, OC, IC = ne[1], ne[2], ne[3]
        values = permute(values, ne, 2, 1, 0)
        ne = { IC, OC * K }
      elseif name:find("^mimi%.decoder%.model%.[%d.a-z]*conv%.weight$") then
        -- [OC, IC, K] = ne (K, IC, OC) -> ne (IC, K, OC): a row is K taps of IC channels
        local K, IC, OC = ne[1], ne[2], ne[3]
        values = permute(values, ne, 1, 0, 2)
        ne = { IC * K, OC }
      elseif name == "mimi.upsample.convtr.convtr.weight" then
        -- [512, 1, 32] = ne (32, 1, 512) -> ne (512, 32): each tap's 512 channels together
        values = permute(values, { ne[1], ne[3], 1 }, 1, 0, 2)
        ne = { ne[3], ne[1] }
        short = "mimi.upsample.weight"
      elseif name == "mimi.quantizer.output_proj.weight" then
        ne = { ne[2], ne[3] }                         -- a 1x1 conv is a linear: ne (32, 512)
      elseif name == "flow_lm.bos_before_voice" then
        ne = { ne[1] }
      end
      if #short > 63 then fail("the name " .. short .. " is longer than ggml's 63 characters") end
      local type = "f32"
      if matrices == "f16" and large_matrix(short, ne) then
        local lo, hi = values:stats()
        if math.max(-lo, hi) >= 65504 then fail(short .. " holds a value F16 cannot") end
        type = "f16"
      end
      w:add(short, values, ne, type)
      n = n + 1
      params = params + #values
    end
  end
  w:write(out)
  w:close()
  reader:close()
  print(("pocket_tts: %d tensors, %d parameters, %d tokens -> %s"):format(n, params, #tokens, out))
end

local function convert_voice(voice_path, out)
  local reader, header = ml.safetensors(voice_path)
  local w = ml.gguf_writer()
  w:set("general.architecture", "pocket_tts.voice")
  local layers, positions = 0, nil
  while header[("transformer.layers.%d.self_attn/cache"):format(layers)] do layers = layers + 1 end
  if layers == 0 then fail(voice_path .. " holds no transformer.layers.N.self_attn/cache") end
  for l = 0, layers - 1 do
    local c = header[("transformer.layers.%d.self_attn/cache"):format(l)]
    local o = header[("transformer.layers.%d.self_attn/offset"):format(l)]
    local offset = reader:read(o.dtype, o.data_offsets[1], o.data_offsets[2])[1]
    if positions and positions ~= offset then fail("the layers hold different numbers of positions") end
    positions = offset
    -- [2, 1, C, H, D]: K is the first half, V the second; each keeps its first `offset` positions
    local two, batch, cap, heads, width = c.shape[1], c.shape[2], c.shape[3], c.shape[4], c.shape[5]
    if two ~= 2 or batch ~= 1 then fail("a cache of shape [" .. table.concat(c.shape, ", ") .. "]") end
    local all = reader:read(c.dtype, c.data_offsets[1], c.data_offsets[2])
    local half, used = cap * heads * width, offset * heads * width
    w:add(("voice.%d.k"):format(l), all:slice(1, used), { width, heads, offset }, "f32")
    w:add(("voice.%d.v"):format(l), all:slice(half + 1, half + used), { width, heads, offset }, "f32")
  end
  w:set("pocket_tts.voice.block_count", layers, "u32")
  w:set("pocket_tts.voice.positions", positions, "u32")
  w:write(out)
  w:close()
  reader:close()
  print(("pocket_tts: a voice of %d positions over %d layers -> %s"):format(positions, layers, out))
end

local what = arg[1]
if what == "model" and arg[4] and (arg[5] == nil or arg[5] == "f16" or arg[5] == "f32") then
  convert_model(arg[2], arg[3], arg[4], arg[5] or "f32")
elseif what == "voice" and arg[3] then
  convert_voice(arg[2], arg[3])
else
  fail("usage: pocket_tts.lua model <model.safetensors> <tokenizer.model> <out.gguf> [f16]\n" ..
       "       pocket_tts.lua voice <voice.safetensors> <out.gguf>")
end
