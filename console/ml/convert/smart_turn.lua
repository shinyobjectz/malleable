-- smart_turn — writes Smart Turn v3.2 as a GGUF the engine loads.
--
--     luajit console/ml/convert/smart_turn.lua [model.safetensors] [smart-turn-v3.2.gguf] [f32|f16|q8_0]
--
-- The source is mlx-community/smart-turn-v3's model.safetensors (32 MB, sha256
-- 12d072e170f1...): pipecat-ai's fp32 smart-turn-v3.2-gpu.onnx, bit for bit, with the
-- linear weights back in PyTorch's [out, in] (console/ml/notes/smart_turn.md, section 5).
-- Stripping its "inner." prefix gives the names of SmartTurnV3Model's state dict; the
-- GGUF keeps those names.
--
-- The last argument is the type of the 2-D product weights (attention, feed-forward,
-- pooling and head). The conv kernels, norms, biases and the position table stay f32:
-- a conv's kernel is the f32 side of its product, and the rest is small. f32 is the
-- default and matches the ONNX model to 2e-6; f16 costs about 2e-3 in p, q8_0 about 1e-2
-- (notes, section 8).

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../../../?.lua;" .. package.path
local ml = require "console.ml.engine"

local models = os.getenv("ML_MODELS") or (here .. "/../models")
local src = arg and arg[1] or (models .. "/smart-turn-v3.2.safetensors")
local dst = arg and arg[2] or (models .. "/smart-turn-v3.2.gguf")
local wtype = arg and arg[3] or "f32"

local reader, header = ml.safetensors(src)

local function product_weight(name, shape)
  return #shape == 2 and name:match("%.weight$") and not name:match("embed_positions") and not name:match("norm")
end

local names = {}
for k in pairs(header) do if k ~= "__metadata__" then names[#names + 1] = k end end
table.sort(names)
if #names ~= 79 then error("smart_turn: " .. src .. " has " .. #names .. " tensors, not Smart Turn v3's 79", 0) end

local w = ml.gguf_writer()
w:set("general.architecture", "smart-turn")
w:set("general.name", "Smart Turn v3.2")
w:set("general.license", "BSD-2-Clause")
w:set("general.source.url", "https://huggingface.co/pipecat-ai/smart-turn-v3")
w:set("smart-turn.sample_rate", 16000, "u32")
w:set("smart-turn.seconds", 8, "u32")
w:set("smart-turn.n_mels", 80, "u32")
w:set("smart-turn.n_frames", 800, "u32")
w:set("smart-turn.block_count", 4, "u32")
w:set("smart-turn.embedding_length", 384, "u32")
w:set("smart-turn.head_count", 6, "u32")
w:set("smart-turn.layer_norm_epsilon", 1e-5)

local total = 0
for _, key in ipairs(names) do
  local info = header[key]
  if info.dtype ~= "F32" then error("smart_turn: " .. key .. " is " .. info.dtype .. ", not F32", 0) end
  local name = key:gsub("^inner%.", "")
  local ne, count = {}, 1
  for k = #info.shape, 1, -1 do ne[#ne + 1] = info.shape[k]; count = count * info.shape[k] end   -- ggml's order
  local buf = reader:read(info.dtype, info.data_offsets[1], info.data_offsets[2])
  if #buf ~= count then error("smart_turn: " .. key .. " holds " .. #buf .. " values, not " .. count, 0) end
  w:add(name, buf, ne, product_weight(name, info.shape) and wtype or "f32")
  total = total + count
end
reader:close()
w:write(dst)
w:close()
print(("smart_turn: %d tensors, %d values, product weights %s -> %s"):format(#names, total, wtype, dst))
