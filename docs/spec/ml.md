# ml — models that run inside the console

## What it is for

A program on the console can hear and speak and think without a network: a small
language model, a voice, a microphone that knows when a person is speaking and when
they have finished, and a transcript as they talk. All of it runs in the console's own
process, on the console's own engine — never a server, never a subprocess, never a
model runtime installed on the system. The same Lua runs on a Mac (Metal), on a PC
(CUDA or the CPU) and in a browser (WebAssembly).

The engine is ggml, the C tensor library under llama.cpp, compiled into one native
module. The models are Lua: each one builds its computation from the engine's ops, the
way a UI draws from the console's drawing calls. Nothing of llama.cpp is linked; its
source and the other ports are references a model is checked against.

## Where it lives

    console/ml/engine.lua       loads the native module built for the running interpreter
    console/ml/native/          the module: ml.h, core.c (engine, sets, graphs, ops),
                                buffer.c (host arrays, sampling), io.c (GGUF, safetensors,
                                WAV, resampling), audio.c (microphone and speaker)
    console/ml/CMakeLists.txt   ggml and the module, one build per interpreter ABI
    console/ml/build.sh         builds console/ml/lib/<abi>/ml_core.so
    console/ml/build-wasm.sh    builds console/ml/lib/wasm/ml_lua.cjs: Lua 5.4 with the engine in
    console/ml/fetch-ggml.sh    fetches ggml at the pinned commit into console/ml/ggml/
    console/ml/fetch-miniaudio.sh  fetches miniaudio.h at the pinned release
    console/ml/<model>.lua      a model, in Lua over the engine: gemma4, silero_vad, smart_turn,
                                moonshine, pocket_tts
    console/ml/voice.lua        a spoken conversation over the models, a slice a frame
    console/ml/talk.lua         that conversation from a terminal: luajit console/ml/talk.lua
    console/ml/convert/         one-time converters from a published checkpoint to GGUF
    console/ml/notes/           what each model is, layer by layer, and where it came from
    test/ml_*_test.lua          the engine and each model

ggml, miniaudio, the builds and the model files are not in the repository. The fetch
scripts pin ggml and miniaudio; each model's notes name its weights and the converter that
makes its GGUF.

Nothing under `src/` requires `console/ml`, as nothing under `src/` requires `console/`.

The console's host is LÖVE, whose LuaJIT loads the same `lib/luajit/ml_core.so`: the engine,
the models and the audio run inside the console's own process, on Metal on a Mac.

## A conversation

`console/ml/voice.lua` joins the models into a spoken conversation. `voice.new(parts)` takes
a microphone, a VAD, a turn model, a transcript, a reply function and, if it is to speak, a
TTS and a speaker; `v:update()` does a slice of the work and returns, so a frame never waits
for a reply. The person's turn starts when the VAD hears speech (with the 0.3 s before it),
is transcribed as it goes, and ends when a pause of 0.25 s has the turn model saying they
have finished, or after 1.5 s of quiet whatever it says. The reply is written a piece at a
time and said a sentence at a time, the first sentence while the rest is still being
written. With `barge_in`, talking over the reply stops it and keeps what was said; it is off
by default, because without headphones or echo cancelling the microphone hears the reply.
Events come to `v.on(event, data)`: speech, partial, heard, reply, said, interrupted, done.

In place of the reply function, the loop takes a `mind`: an object told when the person
starts (`hearing`) and what they said (`heard`), which hands out what to say a sentence at a
time (`take`, then `said` once it is spoken) and may speak when nobody asked, as when a job
ends. A cut calls its `cut`. It is given a slice every frame (`update`), and the mouth holds
the floor while it is `busy` or has a sentence `pending`. The one this tree has is the
conversation of spec/speech.md: a fast talker that answers and hands work to agents that run
behind it. A loop takes a reply or a mind, never both. `luajit console/ml/talk.lua --agent
FILE [--root DIR]` talks to an agent that way, with FILE a `.feature` or a `.lua`
declaration and DIR the folder its world reaches.

## The engine

    local ml = require "console.ml.engine"
    local e  = ml.engine { device = "auto", threads = 4 }

`device` is `"auto"` (the first GPU there is, then the CPU), `"cpu"`, or a device name from
`ml.devices()`. `ml.cpu_features()` says what ggml's CPU kernels use here (`neon`, `dotprod`,
`avx2`, `avx512`, `wasm_simd` ...): kernels differ by feature, and so does how they round.
The CPU is always on the engine too, last: a graph's op that the GPU does not have runs on
the CPU, and `graph:splits()` counts the pieces the graph was cut into.

The module loads for the interpreter it runs under: PUC Lua 5.4 or 5.5, or LuaJIT. One
build per ABI (`build.sh lua5.5`, `build.sh luajit`); a missing build raises with the
command that makes it.

### Sets

A set holds tensors that outlive a graph: a model's weights, or a run's state (a KV
cache, a recurrent state, a convolution's history).

    local w = e:load("model.gguf", { host = function (name) return name == "token_embd.weight" end })
    w:get "blk.0.attn_q.weight"     -- a tensor, or nil
    w:meta "general.architecture"   -- the file's metadata: a number, string, boolean or list
    w:names(), w:keys(), w:bytes()

    local s = e:set()
    local k = s:new("k_cache", "f16", 64, 4096, 8)
    s:alloc()                        -- on the engine's first device, zeroed
    k:write(buffer); k:read()

`host` keeps a tensor on the CPU when the engine has a GPU: a large embedding table that
is only ever looked up by row. `pack` names the weights that are only ever the first
argument of `mul_mat`; on an engine that is only the CPU, those the CPU can repack for its
matrix kernels (Q4_0 interleaved for NEON or AVX, ...) are loaded repacked, which doubles a
prompt's speed there. A tensor looked up by row must not be packed.

### Graphs

A graph is one computation. Ops make new tensors of the graph; `compute` runs every op
that the named outputs, and every expanded node, need.

    local g = e:graph()             -- up to 8192 nodes; e:graph(n) for more
    local x = g:input("f32", 512)
    g:set(x, samples)               -- a buffer, copied now, written when the graph runs
    local y = g:gelu(g:mul_mat(w:get "fc.weight", x))
    g:expand(g:cpy(y, s:get "state"))   -- a write into a set, which nothing else reads
    g:compute(y)
    local out = g:read(y)           -- a buffer

`compute` is also a host wait. `g:start(y)` prepares; `g:poll()` runs the remaining work
and answers true when the outputs can be read. `g:job(y)` is `{ wait = "host", poll }`
for speech and the turn clock. Inside a coroutine, `g:compute` itself yields that wait,
so `voice.update` can start a graph on one frame and finish it on a later one. On
WebAssembly without threads, one poll runs the remaining compute; with a GPU, start is
the upload and poll is the run.

A graph is built again each step: `g:reset()` empties it, and every tensor made before
the reset is refused if it is used again, with a message, never a crash. A graph computed
a second time without a reset takes whatever its inputs were set to since.

### Ops

The ops are ggml's, by ggml's names and argument order, so ggml's header documents them:
`add sub mul div scale scale_bias mul_mat mul_mat_f32 out_prod get_rows set_rows cpy
cast concat repeat repeat_4d reshape view permute transpose cont cont_nd dup norm
rms_norm l2_norm group_norm soft_max soft_max_ext rope_ext flash_attn_ext diag_mask_inf
conv_1d conv_1d_dw conv_transpose_1d im2col pad pad_ext pad_reflect_1d pool_1d interpolate argsort top_k
argmax sum sum_rows mean arange fill clamp leaky_relu neg abs sgn step tanh elu relu
sigmoid gelu gelu_erf gelu_quick silu swiglu_split swiglu_swapped geglu_split exp log sqr sqrt sin cos`.
A model that needs another adds it to `core.c`, in the same shape.

### Buffers

A buffer is a flat f32 or i32 array on the host, 1-based: `ml.buffer(n)`,
`ml.buffer{...}`, `b[i]`, `#b`, `b:table()`, `b:slice(i, j)`, `ml.join(a, b)`,
`b:encode("i16")`, `ml.decode(bytes, "i16")`, `b:argmax()`, `b:stats()`,
`ml.max_diff(a, b)`.

Sampling is `logits:sample({ temperature, top_k, top_p, min_p }, rng)`, in C, so a
vocabulary of 262,144 is never a Lua table. `ml.rng(seed)` is a stream that is the same
for the same seed on every host; `rng:normals(n, std)` is Gaussian noise.

### Files

    ml.wav_read(path) -> samples, rate, channels     (mono, f32 in [-1, 1])
    ml.wav_write(path, samples, rate)                (mono, 16-bit)
    ml.resample(samples, from, to)                   (windowed sinc)
    ml.safetensors(path) -> reader, header           reader:read(dtype, begin, end)
    ml.gguf_writer()  w:set(key, value [, type])  w:add(name, buffer, shape, type)  w:write(path)
    ml.json(text)

The engine runs GGUF only. A model published as safetensors is converted once, by a Lua
script over the reader and the writer, which may quantize (`q8_0`, `q4_K` ...).

### Time

`ml.now()` is seconds on a clock that only goes forward, for timing a model; `os.clock`
counts the CPU time of every thread, so a threaded graph would look slower than it is.
`ml.sleep(seconds)` waits, for a loop that polls the microphone.

### Audio

    local mic = ml.microphone { rate = 16000 }      -- the default microphone, f32 mono
    mic:start()
    local heard = mic:read()                        -- a buffer: what was heard since the last read
    local spk = ml.speaker { rate = 24000 }
    spk:write(samples)                              -- how many it took; fewer when the queue is full
    spk:start()
    spk:clear()                                     -- drop what is queued: the person started talking

A device runs on its own thread, and a ring with one writer and one reader sits between
it and Lua, so neither waits on the other. `mic:available()`, `mic:dropped()` (heard while
the ring was full, and lost), `spk:queued()`, `spk:played()`, `rate()`, `name()`, `stop()`,
`close()`. Options: `rate`, `seconds` (the ring: 10 for a microphone, 30 for a speaker),
`device` (part of a name from `ml.audio_devices()`), and `backend` (`coreaudio`, `wasapi`,
`alsa`, `pulseaudio`, `webaudio`, ... or `null`, a device with no hardware that hears
silence and plays into nothing at the rate asked for, which the tests use).
`ml.audio_available()` is false in a build without miniaudio (`ML_AUDIO=OFF`, and the
WebAssembly build), where opening a device raises saying so.

On macOS a process without microphone permission hears silence, not an error: the
terminal or app that runs the console needs it in System Settings, Privacy & Security,
Microphone.

### WebAssembly

`build-wasm.sh` (with the Emscripten SDK) builds one interpreter, Lua 5.4 and the engine
linked together, on ggml's CPU backend with WebAssembly SIMD and one thread:
`node console/ml/lib/wasm/ml_lua.cjs script.lua`. `ML_WASM_THREADS=8 build-wasm.sh` builds
`ml_lua_mt.cjs`, whose CPU backend runs on that many workers (a browser must serve it
cross-origin isolated, for shared memory). `require "console.ml.engine"` finds the engine in
`package.preload`. Memory is at most 4 GB, which Gemma 4 E2B's 3.3 GB of weights just fit.

In node on the Mac (M4): a VAD step takes 74 µs for 32 ms of audio; a Smart Turn prediction
250 ms on one thread and 87 ms on eight (58 ms native); Gemma 4 E2B on eight threads reads a
prompt at 21 tokens a second and writes at 14.

## What it measures

Measured 2026-09-10 (the PC) and 2026-09-11 (the Mac), wall clock, every model in one process. The Mac is a MacBook Air (M4,
16 GB) on Metal; the PC is an RTX 4070 on CUDA (WSL Ubuntu); WebAssembly is node on the Mac,
eight threads.

| | Mac, Metal | PC, CUDA | WebAssembly |
| --- | --- | --- | --- |
| Silero VAD, one 32 ms step (CPU, one thread) | 60 µs | 37 µs | 74 µs |
| Smart Turn, one 8 s prediction | 19 ms | 22 ms | 87 ms |
| Moonshine Small, real-time factor, whole / streamed | 0.017 / 0.083 | 0.006 / 0.030 | |
| Moonshine Small, last words after the person stops | 18 ms | 5 ms | |
| Pocket TTS, first audio / times real time | 21 ms / 6.7× | 6 ms / 25.9× | |
| Gemma 4 E2B q4_0, prompt / generate, tokens a second | 622 / 46-51 | 5896 / 110 | 21 / 14 |

On the CPUs alone Gemma reads 251 and writes 53 on the Mac (weights packed), and 235 / 35 on
the PC's. llama.cpp on the same Mac: 621 / 56 on Metal, 206 / 51.5 on the CPU.

## Failure modes

| what happens | what the caller sees |
| --- | --- |
| the module is not built for this interpreter | `require` raises, naming `build.sh <abi>` |
| a device, type or tensor name that does not exist | raises, naming it and what exists |
| a tensor used after its graph reset or its set was freed | raises: "from before its graph was reset" / "freed" |
| a graph larger than its node count | raises: give the graph more nodes |
| a device with no room for a set or a graph | raises, naming the file or the graph |
| an input set to a buffer of the wrong size or type | raises with both sizes |
| a host that exits without closing Lua | the engine frees what is left before ggml's teardown |
| an op given shapes ggml refuses | raises with ggml's check (`GGML_ASSERT(...) failed`), and the graph goes on |
| a microphone or speaker that will not open, or an unknown backend | raises, naming it and the backends there are |

## What it must not do

- Link a model runtime. The models are Lua over ops; a runtime would be a second place a
  model is defined, and a second copy of ggml.
- Crash on a stale handle. A handle knows the generation it was made in.
- Print on stderr unless asked. `ML_LOG=warn|info|debug` turns ggml's log on.
- Keep a vocabulary's logits as Lua values.

## The tests that would prove it

`test/ml_engine_test.lua`: every op agrees between the device and the CPU; a hand-worked
product; stale handles and freed sets refused; a graph computed twice; state written by
one graph and read by the next; buffers; deterministic noise and sampling; GGUF written
and loaded back with metadata and quantized tensors; safetensors by hand; WAV round trip;
resampling keeps a tone; a wrong shape raises and the graph goes on. It passes under
LuaJIT, Lua 5.4, Lua 5.5 and WebAssembly. `test/ml_audio_test.lua`, on the null backend: the
microphone hears at its rate, a full ring drops and counts, the speaker plays what is
written and stops on clear. `test/ml_voice_test.lua`, over stand-in parts: a turn is heard,
answered and said sentence by sentence; the transcript gets the pre-roll; an unfinished turn
waits for the long quiet; talking over the reply stops it; and the real VAD, Smart Turn and
Moonshine hear a recording through to its transcript. Each model has its own test against
numbers from its reference implementation (`test/ml_gemma4_test.lua`: on the CPU the logits
are llama.cpp's to 2e-4). All eight files pass on the Mac (LuaJIT, Lua 5.5), on the PC with
CUDA (LuaJIT, Lua 5.4) and in WebAssembly.
