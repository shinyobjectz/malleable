-- The console's ML engine: the native core under the models (spec/ml.md).
--
-- The engine is built per interpreter (console/ml/build.sh). Where it is not built, this
-- file checks only that loading it says how to build it; everything else needs the core.
-- No test here needs a model file: the models have their own tests, which a missing
-- weight file skips the same way.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. here .. "/../?.lua;" .. package.path

local T = {}

local fine, ml = pcall(require, "console.ml.engine")

if not fine then
  function T.an_engine_that_is_not_built_says_how_to_build_it()
    assert(tostring(ml):find("console/ml/build.sh", 1, true), tostring(ml))
  end
  return T
end

local function tmp(name)
  return os.tmpname() .. "-" .. name
end

local function close(a, b, tol, what)
  assert(#a == #b, (what or "") .. ": " .. #a .. " values against " .. #b)
  local d, at = ml.max_diff(a, b)
  assert(d <= tol, string.format("%s: differs by %g at %d (tolerance %g)", what or "values", d, at, tol))
end

-- Values as text, the same under every interpreter: 4, not 4.0.
local function says(b)
  local out = {}
  for i, v in ipairs(b:table()) do out[i] = string.format("%g", v) end
  return table.concat(out, ",")
end

local function wave(n, f)
  local b = ml.buffer(n)
  for i = 1, n do b[i] = f(i) end
  return b
end

-- One engine for the file: a device takes a moment to start.
local device = ml.engine { device = "auto", threads = 4 }
local cpu = ml.engine { device = "cpu", threads = 4 }

-- Runs build(g, inputs...) on an engine and answers the output buffer.
local function on(e, build, ...)
  local g = e:graph()
  local out = build(g, ...)
  g:compute(out)
  return g:read(out)
end

-- ------------------------------------------------------------------ the devices

function T.the_cpu_is_always_a_device()
  local names = {}
  for _, d in ipairs(ml.devices()) do names[#names + 1] = d.type end
  assert(table.concat(names, " "):find("cpu", 1, true), table.concat(names, " "))
  assert(cpu:device() == "CPU", cpu:device())
end

-- ------------------------------------------------------------------ ops agree across devices

local function a_set(e)
  local s = e:set()
  local w = s:new("w", "f32", 64, 48)
  local k = s:new("k", "f32", 5, 8, 16)        -- conv kernel: 5 taps, 8 in, 16 out
  s:alloc()
  w:write(wave(64 * 48, function (i) return math.sin(i * 0.37) * 0.2 end))
  k:write(wave(5 * 8 * 16, function (i) return math.cos(i * 0.11) * 0.3 end))
  return s, w, k
end

local function each_op(e)
  local s, w, k = a_set(e)
  local x = wave(64 * 7, function (i) return math.cos(i * 0.21) end)
  local outs = {}
  outs.mul_mat = on(e, function (g)
    local xi = g:input("f32", 64, 7); g:set(xi, x)
    return g:mul_mat(w, xi)
  end)
  outs.norms = on(e, function (g)
    local xi = g:input("f32", 64, 7); g:set(xi, x)
    return g:add(g:rms_norm(xi, 1e-6), g:norm(xi, 1e-5))
  end)
  outs.soft_max = on(e, function (g)
    local xi = g:input("f32", 64, 7); g:set(xi, x)
    return g:soft_max_ext(xi, nil, 0.5, 0)
  end)
  outs.rope = on(e, function (g)
    local xi = g:input("f32", 16, 4, 7); g:set(xi, x)      -- head dim 16, 4 heads, 7 positions
    local pos = g:input("i32", 7); g:set(pos, ml.buffer({ 0, 1, 2, 3, 4, 5, 6 }, "i32"))
    return g:rope_ext(xi, pos, nil, 16, 2, 0, 10000, 1, 0, 1, 32, 1)
  end)
  outs.conv = on(e, function (g)
    local xi = g:input("f32", 40, 8); g:set(xi, wave(40 * 8, function (i) return math.sin(i * 0.05) end))
    return g:conv_1d(k, xi, 2, 2, 1)
  end)
  outs.activations = on(e, function (g)
    local xi = g:input("f32", 64, 7); g:set(xi, x)
    return g:add(g:add(g:silu(xi), g:elu(xi)), g:add(g:tanh(xi), g:sigmoid(xi)))
  end)
  s:free()
  return outs
end

function T.every_op_gives_the_same_numbers_on_the_device_as_on_the_cpu()
  local a, b = each_op(device), each_op(cpu)
  for _, name in ipairs { "mul_mat", "norms", "soft_max", "rope", "conv", "activations" } do
    close(a[name], b[name], 2e-3, name)
  end
end

function T.a_graph_reads_back_what_numpy_would_compute()
  -- a 2x3 times 3x2, by hand: ggml's mul_mat(a, b) is b times a transposed.
  local out = on(cpu, function (g)
    local a = g:input("f32", 3, 2); g:set(a, ml.buffer { 1, 2, 3, 4, 5, 6 })
    local b = g:input("f32", 3, 2); g:set(b, ml.buffer { 1, 0, 1, 0, 1, 0 })
    return g:mul_mat(a, b)
  end)
  -- rows of b against rows of a: {1,0,1}.{1,2,3}=4, .{4,5,6}=10; {0,1,0}.{1,2,3}=2, .{4,5,6}=5
  assert(says(out) == "4,10,2,5", says(out))
end

-- ------------------------------------------------------------------ handles

function T.a_tensor_from_before_a_reset_is_refused_with_a_reason()
  local g = cpu:graph()
  local x = g:input("f32", 4)
  g:reset()
  local ok, err = pcall(g.gelu, g, x)
  assert(not ok and tostring(err):find("before its graph was reset", 1, true), tostring(err))
end

function T.a_freed_set_refuses_its_tensors()
  local s = cpu:set()
  local t = s:new("t", "f32", 4)
  s:alloc()
  s:free()
  local ok, err = pcall(t.shape, t)
  assert(not ok and tostring(err):find("freed", 1, true), tostring(err))
end

function T.a_wrong_shape_raises_and_the_graph_goes_on()
  local g = device:graph()
  local x = g:input("f32", 6)
  local ok, err = pcall(g.reshape, g, x, 4, 2)
  assert(not ok and tostring(err):find("ggml_nelements", 1, true), tostring(err))
  ok, err = pcall(g.mul_mat, g, x, g:input("f32", 5))
  assert(not ok and tostring(err):find("can_mul_mat", 1, true), tostring(err))
  local y = g:scale(g:reshape(x, 3, 2), 2)
  g:set(x, ml.buffer { 1, 2, 3, 4, 5, 6 })
  g:compute(y)
  assert(says(g:read(y)) == "2,4,6,8,10,12", says(g:read(y)))
end

-- ggml keeps a graph's last memory plan when the next has as many nodes, without looking at
-- which are outputs; a graph that reads an intermediate the last one did not must get a plan
-- that keeps it, not memory a later node wrote over.
function T.a_rebuilt_graph_that_reads_an_intermediate_gets_it_not_what_came_after()
  for _, e in ipairs { cpu, device } do
    local g = e:graph()
    -- a chain where each node has one reader, so ggml runs each in the memory of the last
    local function build()
      local x = g:input("f32", 4)
      g:set(x, ml.buffer { 1, 2, 3, 4 })
      local a = g:scale(x, 2)
      local c = g:scale(g:sqr(g:scale(a, 3)), 0.5)
      return a, c
    end
    local _, c = build()
    g:compute(c)
    assert(says(g:read(c)) == "18,72,162,288", says(g:read(c)))
    g:reset()
    local a, c2 = build()
    g:compute(c2, a)
    assert(says(g:read(a)) == "2,4,6,8", e:device() .. ": the intermediate reads " .. says(g:read(a)))
    assert(says(g:read(c2)) == "18,72,162,288")
  end
end

function T.a_graph_computed_twice_takes_new_inputs()
  local g = device:graph()
  local x = g:input("f32", 3)
  local y = g:scale(x, 2)
  g:set(x, ml.buffer { 1, 2, 3 })
  g:compute(y)
  assert(says(g:read(y)) == "2,4,6", says(g:read(y)))
  g:set(x, ml.buffer { 5, 6, 7 })
  g:compute(y)
  assert(says(g:read(y)) == "10,12,14", says(g:read(y)))
end

function T.state_in_a_set_is_written_by_one_graph_and_read_by_the_next()
  local s = device:set()
  local acc = s:new("acc", "f32", 4)
  s:alloc()
  for step = 1, 3 do
    local g = device:graph()
    local x = g:input("f32", 4)
    g:set(x, ml.buffer { step, step, step, step })
    g:expand(g:cpy(g:add(acc, x), acc))
    g:compute()
  end
  assert(says(acc:read()) == "6,6,6,6", says(acc:read()))
end

-- ------------------------------------------------------------------ buffers and sampling

function T.a_buffer_is_one_based_and_says_what_it_holds()
  local b = ml.buffer { 3, 1, 4, 1, 5 }
  assert(#b == 5 and b[1] == 3 and b[5] == 5)
  b[2] = 9
  local i, v = b:argmax()
  assert(i == 2 and v == 9)
  assert(not pcall(function () return b[6] end), "index 6 of 5 was read")
end

function T.the_same_seed_gives_the_same_noise_and_the_same_samples()
  local a, b = ml.rng(7):normals(100), ml.rng(7):normals(100)
  close(a, b, 0, "noise")
  local logits = wave(1000, function (i) return math.sin(i) * 3 end)
  local r1, r2 = ml.rng(42), ml.rng(42)
  for _ = 1, 20 do
    local x = logits:sample({ temperature = 0.8, top_k = 40, top_p = 0.95 }, r1)
    local y = logits:sample({ temperature = 0.8, top_k = 40, top_p = 0.95 }, r2)
    assert(x == y)
  end
  local mn, mx, mean, rms = ml.rng(1):normals(20000):stats()
  assert(math.abs(mean) < 0.03 and math.abs(rms - 1) < 0.03, mean .. " " .. rms)
  assert(mn < -3 and mx > 3)
end

function T.temperature_zero_is_the_argmax_and_top_k_one_is_too()
  local logits = ml.buffer { 0.1, 2.5, 0.3, 2.4 }
  assert(logits:sample({ temperature = 0 }) == 2)
  local r = ml.rng(3)
  for _ = 1, 10 do assert(logits:sample({ temperature = 1, top_k = 1 }, r) == 2) end
end

-- ------------------------------------------------------------------ files

function T.a_gguf_written_here_loads_back_with_its_metadata_and_quantized_tensors()
  local path = tmp("round.gguf")
  local w = ml.gguf_writer()
  w:set("general.name", "round trip")
  w:set("round.layers", 3, "u32")
  w:set("round.eps", 1e-5)
  w:set("round.list", { "a", "b" })
  local data = wave(64 * 4, function (i) return math.sin(i * 0.1) end)
  w:add("t.f32", data, { 64, 4 }, "f32")
  w:add("t.f16", data, { 64, 4 }, "f16")
  w:add("t.q8", data, { 64, 4 }, "q8_0")
  w:write(path)
  w:close()
  local s = device:load(path)
  assert(s:meta("general.name") == "round trip")
  assert(s:meta("round.layers") == 3)
  assert(math.abs(s:meta("round.eps") - 1e-5) < 1e-9)
  assert(table.concat(s:meta("round.list"), ",") == "a,b")
  assert(table.concat(s:names(), ",") == "t.f32,t.f16,t.q8")
  local x = wave(64, function (i) return math.cos(i * 0.3) end)
  local function mm(name)
    return on(device, function (g)
      local xi = g:input("f32", 64); g:set(xi, x)
      return g:mul_mat(s:get(name), xi)
    end)
  end
  local exact = mm "t.f32"
  close(mm "t.f16", exact, 5e-3, "f16")
  close(mm "t.q8", exact, 5e-2, "q8_0")
  assert(s:get "missing" == nil)
  os.remove(path)
end

function T.a_safetensors_file_reads_back_as_its_header_and_its_tensors()
  -- Two tensors, F32 and BF16, written by hand.
  local a = ml.buffer { 1.5, -2, 0.25 }
  local bf = string.char(0x80, 0x3f, 0x00, 0xc0)             -- 1.0 and -2.0 in bfloat16
  local header = '{"a":{"dtype":"F32","shape":[3],"data_offsets":[0,12]},'
    .. '"b":{"dtype":"BF16","shape":[2],"data_offsets":[12,16]},"__metadata__":{"format":"pt"}}'
  local n = #header
  local len = string.char(n % 256, math.floor(n / 256) % 256, 0, 0, 0, 0, 0, 0)
  local path = tmp("t.safetensors")
  local f = assert(io.open(path, "wb"))
  f:write(len, header, a:encode("f32"), bf)
  f:close()
  local r, h = ml.safetensors(path)
  assert(h.a.dtype == "F32" and h.a.shape[1] == 3 and h.__metadata__.format == "pt")
  close(r:read(h.a.dtype, h.a.data_offsets[1], h.a.data_offsets[2]), a, 0, "F32")
  close(r:read(h.b.dtype, h.b.data_offsets[1], h.b.data_offsets[2]), ml.buffer { 1, -2 }, 0, "BF16")
  r:close()
  os.remove(path)
end

function T.a_wav_written_reads_back_at_its_rate()
  local path = tmp("tone.wav")
  local tone = wave(1600, function (i) return 0.5 * math.sin(2 * math.pi * 440 * i / 16000) end)
  ml.wav_write(path, tone, 16000)
  local back, rate, channels = ml.wav_read(path)
  assert(rate == 16000 and channels == 1 and #back == 1600)
  close(back, tone, 1 / 32767 + 1e-6, "16-bit")
  os.remove(path)
end

function T.a_graph_starts_and_polls_as_a_host_wait()
  local g = cpu:graph()
  local x = g:input("f32", 4)
  g:set(x, ml.buffer { 1, 2, 3, 4 })
  local y = g:scale(x, 2)
  g:start(y)
  local n = 0
  while not g:poll() do
    n = n + 1
    assert(n < 8, "poll never finished")
  end
  assert(says(g:read(y)) == "2,4,6,8", says(g:read(y)))
end

function T.compute_inside_a_coroutine_yields_a_host_wait()
  local g = cpu:graph()
  local x = g:input("f32", 2)
  g:set(x, ml.buffer { 3, 4 })
  local y = g:scale(x, 2)
  local wait = require "wait"
  local co = coroutine.create(function ()
    g:compute(y)
    return "done"
  end)
  local ok, got = coroutine.resume(co)
  assert(ok, tostring(got))
  if coroutine.status(co) ~= "dead" then
    assert(wait.kind(got) == "host", tostring(got and got.wait))
    local status, value = wait.ready(got)
    while status == "waiting" do status, value = wait.ready(got) end
    assert(status == "ready", tostring(status) .. " " .. tostring(value))
    ok, got = coroutine.resume(co, value)
    assert(ok and got == "done", tostring(got))
  end
  assert(says(g:read(y)) == "6,8", says(g:read(y)))
end

function T.resampling_keeps_a_tone_and_its_loudness()
  local tone = wave(4800, function (i) return math.sin(2 * math.pi * 440 * i / 48000) end)
  local down = ml.resample(tone, 48000, 16000)
  assert(#down == 1600, #down)
  -- the same tone at the lower rate, away from the edges the filter cannot see past
  local want = wave(1600, function (i) return math.sin(2 * math.pi * 440 * (i - 1) / 16000 + 2 * math.pi * 440 / 48000) end)
  close(down:slice(100, 1500), want:slice(100, 1500), 0.02, "440 Hz at 16 kHz")
end

return T
