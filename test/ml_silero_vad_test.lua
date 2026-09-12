-- Silero VAD v6.2 on the console's engine (console/ml/silero_vad.lua), against the official
-- TorchScript model.
--
-- The reference is silero_vad.jit from github.com/snakers4/silero-vad (v6.2), run by
-- PyTorch 2.8 on whisper.cpp's samples/jfk.wav: reset once, then one call per 512-sample
-- window, the last window zero-padded, as get_speech_timestamps runs it (the script is in
-- console/ml/notes/silero_vad.md, section 8). The model carries its LSTM state and 64
-- samples of context from each window to the next, so every number after the first also
-- checks the state the steps before it left. On the CPU the two agree to about 2e-6; a GPU
-- rounds its transcendentals differently and agrees to a few millionths more.
-- Without the weights and jfk.wav (console/ml/models/, or ML_MODELS) or the engine,
-- nothing runs.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local T = {}

local fine, ml = pcall(require, "console.ml.engine")
local models = os.getenv("ML_MODELS") or here .. "/../console/ml/models"
local path, wav_path = models .. "/silero-vad.gguf", models .. "/jfk.wav"
local function exists(p) local f = io.open(p, "rb"); if f then f:close() end return f ~= nil end
if not fine or not exists(path) or not exists(wav_path) then return T end
local silero = require "console.ml.silero_vad"

-- The JIT's probability for each of jfk.wav's 344 windows.
local JIT = {}
for v in ([[
  0.0016697 0.0846346 0.3019889 0.1334941 0.0832000 0.0434543 0.0554222 0.0526928 0.0313141 0.0376376
  0.3433437 0.9459893 0.9329346 0.8572596 0.9727624 0.9882603 0.9901643 0.9893607 0.9956138 0.9939688
  0.9821732 0.9943915 0.9945146 0.9948125 0.9909021 0.9853357 0.9889354 0.9856673 0.9695892 0.9757071
  0.9932111 0.9956257 0.9984165 0.9976143 0.9962697 0.9941962 0.9922134 0.9917862 0.9991333 0.9990755
  0.9976825 0.9961132 0.9967780 0.9991684 0.9974854 0.9978911 0.9963474 0.9957110 0.9952316 0.9955194
  0.9951213 0.9967932 0.9990409 0.9989620 0.9996246 0.9997911 0.9994051 0.9992779 0.9989474 0.9985839
  0.9986907 0.9993258 0.9995781 0.9989535 0.9984980 0.9992260 0.9908399 0.9835814 0.9471566 0.6790702
  0.3235934 0.1237182 0.0607228 0.0582419 0.0292867 0.0311272 0.0716067 0.0404412 0.0467220 0.0464740
  0.0552722 0.0290387 0.0183472 0.0181612 0.0152234 0.0192786 0.0129591 0.0112351 0.0124057 0.0229833
  0.0278124 0.0164143 0.0104333 0.0083720 0.0144432 0.0091742 0.0106487 0.0128816 0.0149972 0.0085942
  0.0114798 0.0103180 0.3281792 0.9869109 0.9938880 0.9966127 0.9972351 0.9964907 0.9954764 0.9942273
  0.9909902 0.9904872 0.9953154 0.9937319 0.9955515 0.9986200 0.9925238 0.9724960 0.7128978 0.3929316
  0.2065775 0.0669899 0.0303476 0.1055593 0.5943959 0.8858795 0.9975567 0.9994456 0.9992326 0.9993348
  0.9993698 0.9980420 0.9949540 0.9680347 0.9455866 0.9438340 0.7672285 0.3825614 0.1357624 0.0443325
  0.0319522 0.0464193 0.0657570 0.0371129 0.0284108 0.0263587 0.0190230 0.0549294 0.0403498 0.0359983
  0.0336165 0.0230063 0.0197739 0.0370250 0.0543122 0.0328818 0.0358182 0.0519834 0.0267723 0.0458336
  0.0365399 0.0574100 0.0590539 0.0244461 0.0240626 0.0485016 0.0953072 0.0393089 0.0373698 0.9902617
  0.9994919 0.9986708 0.9988701 0.9987588 0.9979114 0.9991210 0.9997088 0.9999331 0.9999511 0.9999479
  0.9998877 0.9998641 0.9997392 0.9990006 0.9990896 0.9978194 0.9990150 0.9997117 0.9994984 0.9998228
  0.9998488 0.9997578 0.9988433 0.9972139 0.9997990 0.9998646 0.9998211 0.9998347 0.9998732 0.9999150
  0.9998531 0.9996440 0.9985391 0.9997900 0.9994537 0.9993519 0.9995646 0.9996173 0.9991467 0.9997733
  0.9998912 0.9999628 0.9999137 0.9997786 0.9998747 0.9997819 0.9989336 0.9974800 0.9898315 0.9996018
  0.9998378 0.9998099 0.9998816 0.9999388 0.9999501 0.9999483 0.9998790 0.9998920 0.9999070 0.9999003
  0.9997783 0.9997689 0.9998259 0.9996325 0.9996803 0.9990216 0.9967602 0.8843257 0.4279222 0.2058602
  0.0741941 0.0472622 0.0257955 0.0251280 0.0773304 0.0382575 0.0426968 0.0318200 0.0213166 0.0241721
  0.0167013 0.0242926 0.0562584 0.0488908 0.0254070 0.0789135 0.9955848 0.9994575 0.9990864 0.9997252
  0.9995795 0.9994887 0.9996213 0.9992787 0.9989138 0.9979324 0.9881887 0.9714106 0.7969289 0.7926292
  0.9996157 0.9998746 0.9999136 0.9996122 0.9993296 0.9997711 0.9996070 0.9971161 0.9996164 0.9998775
  0.9999065 0.9998796 0.9998438 0.9997793 0.9996642 0.9997670 0.9991203 0.9986981 0.9988212 0.9999470
  0.9996868 0.9991919 0.9995907 0.9997116 0.9995859 0.9998789 0.9998802 0.9997508 0.9998085 0.9998751
  0.9998287 0.9996927 0.9988575 0.9988762 0.9991620 0.9995442 0.9990940 0.9997420 0.9999375 0.9999495
  0.9998517 0.9981017 0.9989706 0.9981852 0.9985906 0.9999059 0.9998730 0.9996339 0.9996032 0.9982526
  0.9974201 0.9974685 0.9865328 0.9893972 0.9757435 0.9871475 0.9693182 0.8689876 0.5568546 0.2731127
  0.5610284 0.1438238 0.1863684 0.0769363 0.1210449 0.0546769 0.0747040 0.0490869 0.0759907 0.1629877
  0.0740598 0.5132896 0.8762242 0.6384977
]]):gmatch("%S+") do JIT[#JIT + 1] = tonumber(v) end

-- The JIT reset, then given windows 101..112 alone (the notes' 100..111, counting from 0):
-- what the state before them is worth. Window 104 is 0.987 in the stream and 0.768 cold.
local FRESH_100 = { 0.0338306, 0.0140977, 0.0815571, 0.7678981, 0.8036869, 0.8954230,
                    0.8546986, 0.8054357, 0.6993781, 0.6127517, 0.4811449, 0.5241486 }

local wav = ml.wav_read(wav_path)

local function window(k)                    -- the k-th 512-sample window (1-based), zero-padded
  local from = (k - 1) * 512 + 1
  local piece = wav:slice(from, math.min(from + 511, #wav))
  if #piece < 512 then piece = ml.join(piece, ml.buffer(512 - #piece)) end
  return piece
end

local function against(got, want, tol, where)            -- got's windows against want's first
  local worst, at = 0, 0
  for i = 1, #got do
    local d = math.abs(got[i] - want[i])
    if d > worst then worst, at = d, i end
  end
  assert(worst <= tol, string.format("%s: window %d is %.7f, the JIT %.7f (tolerance %g)",
    where, at, got[at] or 0 / 0, want[at] or 0 / 0, tol))
end

function T.on_the_cpu_every_window_of_jfk_is_the_jits()
  local v = silero.load(ml.engine { device = "cpu" }, path)
  local p = v:run(wav)
  assert(#p == #JIT, "windows: " .. #p)
  against(p, JIT, 1e-5, "cpu")
  local speech = 0
  for i = 1, #p do if p[i] >= 0.5 then speech = speech + 1 end end
  assert(speech == 234, "windows at 0.5 or more: " .. speech)
  v:free()
end

-- The stream, a step at a time, is the clip; a reset forgets it; and the state is the
-- whole difference between a window heard in the stream and the same window heard cold.
function T.state_carries_from_step_to_step_and_a_reset_forgets_it()
  local v = silero.load(ml.engine { device = "cpu" }, path)
  local streamed = {}
  for k = 1, 112 do streamed[k] = v:step(window(k)) end
  against(streamed, JIT, 1e-5, "stepped")
  v:reset()
  local cold = {}
  for k = 101, 112 do cold[#cold + 1] = v:step(window(k)) end
  against(cold, FRESH_100, 1e-5, "after a reset")
  assert(math.abs(cold[4] - streamed[104]) > 0.2, "window 104 cold and streamed: the state did nothing")
  v:reset()
  assert(math.abs(v:step(window(1)) - JIT[1]) < 1e-6, "the first window after a reset")
  -- A list of numbers is a window too.
  v:reset()
  assert(math.abs(v:step(window(1):table()) - JIT[1]) < 1e-6, "a window as a list")
  v:free()
end

function T.a_step_is_512_samples()
  local v = silero.load(ml.engine { device = "cpu" }, path)
  local ok, err = pcall(v.step, v, ml.buffer(511))
  assert(not ok and tostring(err):find("512 samples", 1, true), tostring(err))
  v:free()
end

function T.on_the_device_every_window_is_within_its_rounding()
  local e = ml.engine { device = "auto" }
  if e:device() == "CPU" then return end
  local v = silero.load(e, path)
  local p = v:run(wav)
  -- Metal agrees to about 1e-6; CUDA's products round more, 2.4e-4 at worst on jfk.wav
  against(p, JIT, 5e-4, e:device())
  assert(v.graph:splits() == 1, e:device() .. ": the step was cut in " .. v.graph:splits())
  v:free()
end

return T
