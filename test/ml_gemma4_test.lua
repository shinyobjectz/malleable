-- Gemma 4 E2B on the console's engine (console/ml/gemma4.lua), against llama.cpp.
--
-- The reference is llama.cpp build 10250 (ee0445c99) on the same file, on the CPU with
-- flash attention: `llama-debug -m gemma-4-E2B-it-q4_0.gguf -p "The capital of France is"
-- --save-logits -fa on -ngl 0`. On the CPU the two are the same computation, so the logits
-- agree to the last digit printed; a GPU rounds differently and agrees to a few tenths.
-- Without the weights (console/ml/models/, or ML_MODELS) or the engine, nothing runs.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local T = {}

local fine, ml = pcall(require, "console.ml.engine")
local path = (os.getenv("ML_MODELS") or here .. "/../console/ml/models") .. "/gemma-4-E2B-it-q4_0.gguf"
local file = io.open(path, "rb")
if not fine or not file then return T end
file:close()
local gemma = require "console.ml.gemma4"

local PROMPT = { 2, 818, 5279, 529, 7001, 563 }        -- <bos>The capital of France is
-- llama.cpp's logits for the token after the prompt: its eight best, and four others.
local WANT = {
  { 9079, 25.1845 }, { 5213, 23.3579 }, { 7001, 19.3752 }, { 506, 18.8799 },
  { 236743, 18.1086 }, { 870, 17.4363 }, { 15687, 17.4104 }, { 711, 17.2264 },
  { 0, -7.5829 }, { 1000, -1.8237 }, { 100000, 0.3677 }, { 262143, -6.8339 },
}

-- In WebAssembly the weights take 3.3 of the 4 GB there are: what the last test left for
-- the collector (a vocabulary of 262,144 pieces) is collected before the next load.
local function fresh()
  collectgarbage(); collectgarbage()
end

local function against_llama_cpp(logits, tol, where)
  for _, w in ipairs(WANT) do
    local got = logits[w[1] + 1]
    assert(math.abs(got - w[2]) <= tol,
      string.format("%s: token %d is %.4f, llama.cpp %.4f (tolerance %g)", where, w[1], got, w[2], tol))
  end
  assert(logits:argmax() - 1 == 9079, where .. ": the best token is " .. (logits:argmax() - 1))
end

function T.the_prompt_tokenizes_as_llama_cpp_tokenizes_it()
  local e = ml.engine { device = "cpu" }
  local w = e:load(path, { data = false })
  local ids = w:tokenizer():encode("The capital of France is", { bos = true })
  assert(table.concat(ids, " ") == table.concat(PROMPT, " "), table.concat(ids, " "))
  w:free()
end

-- The reference ran on an ARM CPU (NEON with dot products): there the two are the same
-- kernels and agree to the last digit printed. Another CPU's kernels round the q8_0 input
-- of a q4_0 product their own way, which by the last layer is a few tenths of a logit.
function T.on_the_cpu_the_logits_are_llama_cpps()
  fresh()
  local m = gemma.load(ml.engine { device = "cpu", threads = 8 }, path, { context = 256 })
  local f = ml.cpu_features()
  local same_kernels = f.neon and f.dotprod
  against_llama_cpp(m:forward(PROMPT), same_kernels and 2e-4 or 0.75, same_kernels and "cpu" or "cpu, other kernels")
  m:free()
end

-- The prompt in two pieces, the second reading the first from the cache, answers what it
-- answers in one, as closely as the device's kernels allow for batches of other sizes:
-- Metal agrees to 1e-7 and an x86 CPU exactly. An ARM CPU rounds a q4_0 product's q8_0
-- input differently for another batch size (NMSE 9e-4 by the last layer; llama.cpp's too),
-- and CUDA's attention takes its vector kernel for one query and its tiled kernel, which
-- rounds the probabilities to f16, for more (NMSE 8e-3).
function T.a_prompt_in_pieces_reads_the_cache_as_one_piece_would()
  fresh()
  local e = ml.engine { device = "auto", threads = 8 }
  local m = gemma.load(e, path, { context = 256 })
  local whole = m:forward(PROMPT)
  m:rewind(0)
  m:forward { 2, 818, 5279 }
  local pieces = m:forward { 529, 7001, 563 }
  local se, sr = 0, 0
  for i = 1, #whole do local d = pieces[i] - whole[i]; se = se + d * d; sr = sr + whole[i] * whole[i] end
  local allowed = ({ CPU = 3e-3, CUDA0 = 2e-2 })[e:device()] or 1e-5
  assert(se / sr <= allowed, ("%s: in two pieces the logits move by NMSE %.2e (allowed %g)"):format(e:device(), se / sr, allowed))
  assert(pieces:argmax() == whole:argmax())
  m:free()
end

function T.on_the_device_the_logits_are_within_its_rounding()
  local e = ml.engine { device = "auto", threads = 8 }
  if e:device() == "CPU" then return end
  local m = gemma.load(e, path, { context = 256 })
  against_llama_cpp(m:forward(PROMPT), 0.5, e:device())
  local text = m:chat({ { role = "user", text = "What is the capital of France? One word." } },
                      { temperature = 0, max_tokens = 8 })
  assert(text:find("Paris", 1, true), text)
  m:free()
end

return T
