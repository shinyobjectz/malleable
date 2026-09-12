-- silero_vad — writes Silero VAD v6.2's 16 kHz network as a GGUF the engine loads.
--
--     luajit console/ml/convert/silero_vad.lua [silero_vad_16k_op15.onnx] [silero-vad.gguf]
--
-- The source is `silero_vad_16k_op15.onnx` from github.com/snakers4/silero-vad
-- (src/silero_vad/data/, sha256 7ed98ddbad84...): the only published file that holds v6.2's
-- 16 kHz weights as named initializers, bit for bit the JIT's (console/ml/notes/silero_vad.md,
-- section 4). whisper.cpp's ggml-silero-v6.2.0.bin rounds the conv kernels to f16, and
-- silero_vad_16k.safetensors is another checkpoint, so neither is read.
--
-- An ONNX file is a protobuf. Fifteen tensors need only four of its fields, so this reads
-- them by hand rather than bring a protobuf library: ModelProto.graph (7), GraphProto.
-- initializer (5), and TensorProto's dims (1), data_type (2), name (8) and raw_data (9).
-- Every tensor stays f32: the model is 1.2 MB and its cost is the step, not the weights.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../../../?.lua;" .. package.path
local ml = require "console.ml.engine"

local models = os.getenv("ML_MODELS") or (here .. "/../models")
local src = arg and arg[1] or (models .. "/silero_vad_16k_op15.onnx")
local dst = arg and arg[2] or (models .. "/silero-vad.gguf")

-- ------------------------------------------------------------------ protobuf, the least of it

-- A varint at byte i: its value and the byte after it. Arithmetic, not bit operations, so
-- LuaJIT (doubles) and Lua 5.4+ (integers) read it alike; no value here passes 2^53.
local function varint(s, i)
  local v, mul = 0, 1
  while true do
    local b = s:byte(i)
    if not b then error("silero_vad: the file ends inside a varint", 0) end
    i = i + 1
    v = v + (b % 128) * mul
    if b < 128 then return v, i end
    mul = mul * 128
  end
end

-- Walks the fields of the message in s[from, to): calls each(field, wire, value, a, b),
-- where a varint's value is its number and a length-delimited field's bytes are s[a, b).
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
    elseif wire == 2 then
      local n
      n, i = varint(s, i)
      each(field, wire, nil, i, i + n)
      i = i + n
    elseif wire == 1 then i = i + 8
    elseif wire == 5 then i = i + 4
    else error("silero_vad: wire type " .. wire .. " is not one this reader knows", 0) end
  end
end

local function initializers(s)
  local out = {}
  fields(s, 1, #s + 1, function (field, _, _, a, b)
    if field ~= 7 then return end                                      -- ModelProto.graph
    fields(s, a, b, function (gfield, _, _, ga, gb)
      if gfield ~= 5 then return end                                   -- GraphProto.initializer
      local t = { dims = {} }
      fields(s, ga, gb, function (tf, wire, v, ta, tb)
        if tf == 1 and wire == 0 then t.dims[#t.dims + 1] = v
        elseif tf == 1 then                                            -- packed dims
          local j = ta
          while j < tb do local d; d, j = varint(s, j); t.dims[#t.dims + 1] = d end
        elseif tf == 2 then t.type = v
        elseif tf == 8 then t.name = s:sub(ta, tb - 1)
        elseif tf == 9 then t.raw = s:sub(ta, tb - 1)
        end
      end)
      out[#out + 1] = t
    end)
  end)
  return out
end

-- ------------------------------------------------------------------ the conversion

local f = assert(io.open(src, "rb"), "silero_vad: no " .. src)
local bytes = f:read("a")
f:close()

local WANT = {                                        -- the state dict, less "model."
  "stft.forward_basis_buffer",
  "encoder.0.reparam_conv.weight", "encoder.0.reparam_conv.bias",
  "encoder.1.reparam_conv.weight", "encoder.1.reparam_conv.bias",
  "encoder.2.reparam_conv.weight", "encoder.2.reparam_conv.bias",
  "encoder.3.reparam_conv.weight", "encoder.3.reparam_conv.bias",
  "decoder.rnn.weight_ih", "decoder.rnn.weight_hh", "decoder.rnn.bias_ih", "decoder.rnn.bias_hh",
  "decoder.decoder.2.weight", "decoder.decoder.2.bias",
}

local found = {}
for _, t in ipairs(initializers(bytes)) do
  if t.name then found[(t.name:gsub("^model%.", ""))] = t end
end

local w = ml.gguf_writer()
w:set("general.architecture", "silero-vad")
w:set("general.name", "Silero VAD v6.2, 16 kHz")
w:set("general.license", "MIT")
w:set("general.source.url", "https://github.com/snakers4/silero-vad")
w:set("silero-vad.sample_rate", 16000, "u32")
w:set("silero-vad.window", 512, "u32")
w:set("silero-vad.context", 64, "u32")

local total = 0
for _, name in ipairs(WANT) do
  local t = found[name]
  if not t then error("silero_vad: " .. src .. " has no model." .. name, 0) end
  if t.type ~= 1 or not t.raw then error("silero_vad: model." .. name .. " is not raw float32", 0) end
  local ne, count = {}, 1
  for k = #t.dims, 1, -1 do ne[#ne + 1] = t.dims[k]; count = count * t.dims[k] end   -- ggml's order
  if #ne == 0 then ne[1] = 1 end
  local buf = ml.decode(t.raw, "f32")
  if #buf ~= count then error("silero_vad: model." .. name .. " holds " .. #buf .. " values, not " .. count, 0) end
  w:add(name, buf, ne, "f32")
  total = total + count
end
w:write(dst)
w:close()
print(("silero_vad: %d tensors, %d values -> %s"):format(#WANT, total, dst))
