-- moonshine — converts a Moonshine Streaming checkpoint to the GGUF console/ml/moonshine.lua runs.
--
--     luajit console/ml/convert/moonshine.lua <checkpoint dir> <out.gguf> [f32 | f16 | q8_0]
--
-- The checkpoint is the directory of moonshine-ai/moonshine-streaming-{tiny,small,medium}
-- as Hugging Face publishes it: config.json, tokenizer.json and model.safetensors, every
-- tensor F32. The names written are transcribe.cpp's (console/ml/notes/asr.md, section 4),
-- with the encoder's unit-offset gains folded (+1) and the head stored once when it is the
-- embedding table, which it is in all three checkpoints.
--
-- f32 keeps everything as published, for checking against the reference. f16 halves the
-- matrices. q8_0 quantizes the matrices whose rows are whole blocks of 32; the rest (the
-- encoder's 620-wide inputs in small, the frontend, the position table) stay f16, and every
-- vector stays f32.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../../../?.lua;" .. package.path
local ml = require "console.ml.engine"

local dir, out, kind = arg[1], arg[2], arg[3] or "f32"
if not dir or not out then
  io.stderr:write("usage: moonshine.lua <checkpoint dir> <out.gguf> [f32 | f16 | q8_0]\n")
  os.exit(2)
end
assert(kind == "f32" or kind == "f16" or kind == "q8_0", "the type is f32, f16 or q8_0, not " .. kind)

local function slurp(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- ml.json writes a 🎙 pair as two three-byte sequences; tokens with characters
-- outside the first plane need them joined into the one four-byte sequence they are.
local function join_surrogates(s)
  return (s:gsub("\237([\160-\175])([\128-\191])\237([\176-\191])([\128-\191])", function (a, b, c, d)
    local hi = 0xD000 + (a:byte() - 0x80) * 64 + (b:byte() - 0x80)
    local lo = 0xD000 + (c:byte() - 0x80) * 64 + (d:byte() - 0x80)
    local cp = 0x10000 + (hi - 0xD800) * 1024 + (lo - 0xDC00)
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
                       0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end))
end

local config = ml.json(slurp(dir .. "/config.json"))
local enc = config.encoder_config
local tokenizer = ml.json(slurp(dir .. "/tokenizer.json"))
local st, header = ml.safetensors(dir .. "/model.safetensors")

local w = ml.gguf_writer()
local A = "stt.moonshine_streaming."

-- The hyperparameters, under transcribe.cpp's keys.
w:set("general.architecture", "moonshine_streaming")
w:set("general.name", dir:match("([^/\\]+)[/\\]*$") or "moonshine-streaming")
w:set(A .. "encoder.n_layers", enc.num_hidden_layers, "u32")
w:set(A .. "encoder.d_model", enc.hidden_size, "u32")
w:set(A .. "encoder.n_heads", enc.num_attention_heads, "u32")
w:set(A .. "encoder.n_kv_heads", enc.num_key_value_heads, "u32")
w:set(A .. "encoder.head_dim", enc.head_dim, "u32")
w:set(A .. "encoder.ffn_dim", enc.intermediate_size, "u32")
w:set(A .. "encoder.activation", enc.hidden_act)
w:set(A .. "encoder.frame_ms", enc.frame_ms)
w:set(A .. "encoder.frame_len", math.floor(enc.sample_rate * enc.frame_ms / 1000 + 0.5), "u32")
local windows = {}
for _, lr in ipairs(enc.sliding_windows) do windows[#windows + 1] = lr[1]; windows[#windows + 1] = lr[2] end
w:set(A .. "encoder.sliding_windows", windows, "i32")
w:set(A .. "decoder.n_layers", config.num_hidden_layers, "u32")
w:set(A .. "decoder.d_model", config.hidden_size, "u32")
w:set(A .. "decoder.n_heads", config.num_attention_heads, "u32")
w:set(A .. "decoder.n_kv_heads", config.num_key_value_heads, "u32")
w:set(A .. "decoder.head_dim", config.head_dim, "u32")
w:set(A .. "decoder.ffn_dim", config.intermediate_size, "u32")
w:set(A .. "decoder.activation", config.hidden_act)
w:set(A .. "decoder.vocab_size", config.vocab_size, "u32")
w:set(A .. "decoder.max_position_embeddings", config.max_position_embeddings, "u32")
w:set(A .. "partial_rotary_factor", config.rope_parameters.partial_rotary_factor or 1.0)
w:set(A .. "rope_theta", config.rope_parameters.rope_theta)
w:set(A .. "encoder_layernorm_unit_offset", true)
w:set(A .. "cmvn_eps", 1e-6)
w:set(A .. "encoder_hidden_size", config.encoder_hidden_size, "u32")
w:set(A .. "adapter_has_proj", config.encoder_hidden_size ~= config.hidden_size)
w:set(A .. "decoder_start_token_id", config.decoder_start_token_id, "u32")
w:set(A .. "bos_token_id", config.bos_token_id, "u32")
w:set(A .. "eos_token_id", config.eos_token_id, "u32")
w:set(A .. "pad_token_id", config.pad_token_id, "u32")
w:set("stt.frontend.type", "raw")
w:set("stt.frontend.sample_rate", enc.sample_rate, "u32")

-- The tokenizer: BPE with byte fallback, spaces written as U+2581 and one in front
-- (tokenizer.json's normalizer), which the engine's tokenizer calls "moonshine".
-- Token types are llama.cpp's: 1 normal, 2 unknown, 3 control (the specials, which
-- decoding skips), 6 a byte.
local tokens, types, special = {}, {}, {}
for text, id in pairs(tokenizer.model.vocab) do tokens[id + 1] = join_surrogates(text) end
for _, t in ipairs(tokenizer.added_tokens) do
  tokens[t.id + 1] = join_surrogates(t.content)
  if t.special then special[t.id] = true end
end
for id = 0, config.vocab_size - 1 do
  local text = tokens[id + 1]
  assert(text, "tokenizer.json has no token " .. id)
  local ty = 1
  if id == config.pad_token_id and text == "<unk>" then ty = 2
  elseif special[id] then ty = 3
  elseif text:match("^<0x%x%x>$") then ty = 6 end
  types[id + 1] = ty
end
local merges = {}
for i, m in ipairs(tokenizer.model.merges) do
  merges[i] = join_surrogates(type(m) == "table" and (m[1] .. " " .. m[2]) or m)
end
w:set("tokenizer.ggml.model", "moonshine")
w:set("tokenizer.ggml.tokens", tokens)
w:set("tokenizer.ggml.token_type", types, "i32")
w:set("tokenizer.ggml.merges", merges)
w:set("tokenizer.ggml.byte_fallback", true)
w:set("tokenizer.ggml.add_space_prefix", true)
w:set("tokenizer.ggml.add_bos_token", false)
w:set("tokenizer.ggml.unknown_token_id", 0, "u32")
w:set("tokenizer.ggml.bos_token_id", config.bos_token_id, "u32")
w:set("tokenizer.ggml.eos_token_id", config.eos_token_id, "u32")
w:set("tokenizer.ggml.padding_token_id", config.pad_token_id, "u32")
tokens, types, merges, tokenizer = nil, nil, nil, nil

-- The tensors.
local function read(name)
  local h = header[name]
  if not h then error("the checkpoint has no " .. name, 2) end
  local ne = {}
  for i = #h.shape, 1, -1 do ne[#ne + 1] = h.shape[i] end
  if #ne == 0 then ne = { 1 } end
  return st:read(h.dtype, h.data_offsets[1], h.data_offsets[2]), ne
end

-- The type a tensor is written as: vectors f32; the frontend and the position table (rows of
-- 80 or 620, looked up or convolved) never quantized; matrices as asked when their rows are
-- whole q8_0 blocks.
local function type_of(gname, ne)
  if #ne == 1 or kind == "f32" then return "f32" end
  if gname:match("^enc%.embedder%.") or gname == "adapter.pos_emb.weight" then return "f16" end
  if kind == "q8_0" and ne[1] % 32 ~= 0 then return "f16" end
  return kind
end

local written, bytes = 0, 0
local function put(gname, buf, ne)
  local ty = type_of(gname, ne)
  w:add(gname, buf, ne, ty)
  written = written + 1
  bytes = bytes + #buf * 4
  collectgarbage()
end

local function copy(hname, gname) local b, ne = read(hname); put(gname, b, ne) end

-- The encoder's LayerNorm gains are stored centred on zero; the model multiplies by gamma + 1.
local function gain(hname, gname)
  local b, ne = read(hname)
  for i = 1, #b do b[i] = b[i] + 1 end
  put(gname, b, ne)
end

local E = "model.encoder."
copy(E .. "embedder.comp.log_k", "enc.embedder.comp.log_k")
copy(E .. "embedder.linear.weight", "enc.embedder.linear.weight")
copy(E .. "embedder.conv1.weight", "enc.embedder.conv1.weight")
copy(E .. "embedder.conv1.bias", "enc.embedder.conv1.bias")
copy(E .. "embedder.conv2.weight", "enc.embedder.conv2.weight")
copy(E .. "embedder.conv2.bias", "enc.embedder.conv2.bias")
for i = 0, enc.num_hidden_layers - 1 do
  local h, g = E .. "layers." .. i .. ".", "enc.blocks." .. i .. "."
  gain(h .. "input_layernorm.gamma", g .. "norm_attn.weight")
  copy(h .. "self_attn.q_proj.weight", g .. "attn.q.weight")
  copy(h .. "self_attn.k_proj.weight", g .. "attn.k.weight")
  copy(h .. "self_attn.v_proj.weight", g .. "attn.v.weight")
  copy(h .. "self_attn.o_proj.weight", g .. "attn.out.weight")
  gain(h .. "post_attention_layernorm.gamma", g .. "norm_ffn.weight")
  copy(h .. "mlp.fc1.weight", g .. "ffn.fc1.weight")
  copy(h .. "mlp.fc1.bias", g .. "ffn.fc1.bias")
  copy(h .. "mlp.fc2.weight", g .. "ffn.fc2.weight")
  copy(h .. "mlp.fc2.bias", g .. "ffn.fc2.bias")
end
gain(E .. "final_norm.gamma", "enc.final_norm.weight")

local D = "model.decoder."
copy(D .. "pos_emb.weight", "adapter.pos_emb.weight")
if header[D .. "proj.weight"] then copy(D .. "proj.weight", "adapter.proj.weight") end
for j = 0, config.num_hidden_layers - 1 do
  local h, g = D .. "layers." .. j .. ".", "dec.blocks." .. j .. "."
  copy(h .. "input_layernorm.weight", g .. "norm_self.weight")
  copy(h .. "self_attn.q_proj.weight", g .. "self_attn.q.weight")
  copy(h .. "self_attn.k_proj.weight", g .. "self_attn.k.weight")
  copy(h .. "self_attn.v_proj.weight", g .. "self_attn.v.weight")
  copy(h .. "self_attn.o_proj.weight", g .. "self_attn.out.weight")
  copy(h .. "post_attention_layernorm.weight", g .. "norm_cross.weight")
  copy(h .. "encoder_attn.q_proj.weight", g .. "cross_attn.q.weight")
  copy(h .. "encoder_attn.k_proj.weight", g .. "cross_attn.k.weight")
  copy(h .. "encoder_attn.v_proj.weight", g .. "cross_attn.v.weight")
  copy(h .. "encoder_attn.o_proj.weight", g .. "cross_attn.out.weight")
  copy(h .. "final_layernorm.weight", g .. "norm_ffn.weight")
  copy(h .. "mlp.fc1.weight", g .. "ffn.fc1.weight")
  copy(h .. "mlp.fc1.bias", g .. "ffn.fc1.bias")
  copy(h .. "mlp.fc2.weight", g .. "ffn.fc2.weight")
  copy(h .. "mlp.fc2.bias", g .. "ffn.fc2.bias")
end
copy(D .. "norm.weight", "dec.final_norm.weight")

-- The head: config.json says it is not tied, but every published checkpoint holds the same
-- values in both (notes, gotcha 10). Store it once when that is so.
local embd, ne_embd = read(D .. "embed_tokens.weight")
local head = read("proj_out.weight")
local same = ml.max_diff(embd, head) == 0
head = nil
put("dec.token_embd.weight", embd, ne_embd)
embd = nil
collectgarbage()
w:set(A .. "decoder.tie_word_embeddings", same)
if not same then copy("proj_out.weight", "dec.lm_head.weight") end

w:write(out)
st:close()
print(("wrote %s: %d tensors, %.1f M values, %s, head %s"):format(out, written, bytes / 4 / 1e6, kind,
  same and "shared with the embedding" or "stored"))
