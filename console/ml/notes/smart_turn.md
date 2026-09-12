# Smart Turn v3.2 on ggml — implementation spec

Researched 2026-09-10. Everything below was checked against the published files. The model code
is `SmartTurnV3Model` in `train.py` of `github.com/pipecat-ai/smart-turn`. The fp32 ONNX graph
was walked node by node. A PyTorch re-implementation from the extracted weights matched the fp32
ONNX to 1e-6, and a ggml forward pass written to this spec (vendored ggml at `7840aaba`, CPU
backend) matched it to 2e-6 on eleven fixed inputs. The Python for that is outlined in section 10.

## 1. Which model and which files

- Upstream: `huggingface.co/pipecat-ai/smart-turn-v3` (model) and `github.com/pipecat-ai/smart-turn`
  (training and inference code). Licence **BSD 2-Clause** for code and weights. The base model
  `openai/whisper-tiny` is MIT.
- Versions: v3.0 (2025-09-11), v3.1 (2025-12-03), **v3.2 (2026-01-07, current)**. All three have
  the same architecture; only the weights and training data change. v3.2 benchmark on 31,527 test
  clips (23 languages): fp32 93.71 % accuracy, int8 92.63 % (v3.1 int8 90.13 %, v3.0 88.97 %).
- There is **no official PyTorch or safetensors checkpoint for v3.x.** The fp32 ONNX is the
  master copy. (`pipecat-ai/smart-turn` on HF holds the v1 wav2vec2-BERT model, 2.3 GB, and
  `pipecat-ai/smart-turn-v2` is wav2vec2. Neither is related.)

| File | Bytes | sha256 (prefix) | What it is |
|---|---:|---|---|
| `pipecat-ai/smart-turn-v3/smart-turn-v3.2-gpu.onnx` | 32,411,198 | `ab8dc64b8871` | **v3.2 fp32** (opset 18, exported by torch 2.9 dynamo). Use this. |
| `pipecat-ai/smart-turn-v3/smart-turn-v3.2-cpu.onnx` | 8,679,182 | `2bb026316b14` | v3.2 **int8** static QDQ (per-channel int8 weights, uint8 per-tensor activations) |
| `pipecat-ai/smart-turn-v3/smart-turn-v3.1-gpu.onnx` | 32,411,198 | `a32f7445d507` | v3.1 fp32 |
| `pipecat-ai/smart-turn-v3/smart-turn-v3.1-cpu.onnx` | 8,679,180 | `fb68d55c2d54` | v3.1 int8 |
| `pipecat-ai/smart-turn-v3/smart-turn-v3.0.onnx` | 8,757,193 | `07a133aba31e` | v3.0, int8 only (quantization-aware training) |
| `mlx-community/smart-turn-v3/model.safetensors` | 32,010,016 | `12d072e170f1` | **v3.2 fp32 as safetensors**, converted from `smart-turn-v3.2-gpu.onnx`; checked bit-identical to it. The plainest source. |
| `onnx-community/smart-turn-v3-ONNX/onnx/model.onnx` | 32,033,084 | `5d57dbe46c1d` | **v3.1** fp32 (bit-identical to v3.1-gpu) with the final Sigmoid **removed**: its `logits` output is a raw logit |
| `onnx-community/smart-turn-v3-ONNX/onnx/model_{int8,uint8,quantized,fp16,q4,q4f16,bnb4}.onnx` | 5.7–16 MB | | transformers.js re-quantizations of the v3.1 graph, not pipecat's own int8 |

Pipecat's `LocalSmartTurnAnalyzerV3` ships and uses `smart-turn-v3.2-cpu.onnx` by default.

Recommendation: take the weights from `mlx-community/.../model.safetensors` or from
`smart-turn-v3.2-gpu.onnx` (same numbers). Convert once to our own container with PyTorch-style
names (tables in section 5). Do not start from any int8 file: the int8 ONNX quantizes activations
as well, so dequantizing its weights into an fp32 graph gives a third model that matches neither.

## 2. Pipeline

```
16 kHz mono float PCM (the user's current turn)
  → keep the last 128,000 samples (8 s); if shorter, zero-pad at the START
  → zero-mean / unit-variance normalization over all 128,000 samples (padding included)
  → Whisper log-mel: n_fft 400, hop 160, 80 mels, periodic Hann, centered with reflect padding
     → 801 frames, drop the last → [80, 800]
  → Whisper-tiny encoder cut to 400 positions (conv stem, 4 pre-LN transformer layers) → [400, 384]
  → attention pooling over time → [384]
  → MLP head 384→256→LN→GELU→64→GELU→1 → sigmoid
  → p(turn complete); complete if p > 0.5
```

## 3. Front end (exact)

Confirmed against `transformers.WhisperFeatureExtractor(chunk_length=8)` (4.57) and pipecat's
vendored numpy copy (`pipecat/audio/turn/smart_turn/_whisper_features.py`, a good single-file
reference). A hand implementation of the steps below matched HF to 1.5e-5 per feature.

1. **Window the audio** (`audio_utils.truncate_audio_to_last_n_seconds`): if len > 128000 keep
   `x[-128000:]`; if len < 128000, prepend zeros. The newest audio is always at the end.
2. **Normalize** (`do_normalize=True`): `x = (x − mean(x)) / sqrt(var(x) + 1e-7)`, with mean and
   (population) variance over the whole 128,000-sample buffer **including the zero padding**,
   in float32. The feature extractor sees an already-full buffer, so its attention mask is all
   ones. After this the pad region is the small constant −mean/std, not zero. This step makes the
   model gain-invariant.
3. **STFT**: pad 200 samples on **both** ends by reflection (`torch.stft(center=True,
   pad_mode='reflect')`, edge not repeated). Frames start at 160·t for t = 0..800, 400 samples
   each, multiplied by the periodic Hann window `w[n] = 0.5 − 0.5·cos(2πn/400)`. rFFT of 400
   points gives 201 bins. Power = |X|².
4. **Mel**: `mel = M · power` with M the 80×201 Slaney filterbank (below). `log10(max(mel,
   1e-10))`.
5. **Drop the last frame**: 801 → 800 frames.
6. **Floor and scale**: `L = max(L, max(L) − 8)` with max over the whole [80, 800] array, then
   `L = (L + 4) / 4`.

Mel filterbank (`mel_filter_bank(num_frequency_bins=201, num_mel_filters=80, min_frequency=0,
max_frequency=8000, sampling_rate=16000, norm="slaney", mel_scale="slaney")`), in float64:

```
hz→mel (Slaney): m = 3f/200 for f < 1000; m = 15 + ln(f/1000)·27/ln(6.4) for f ≥ 1000
mel→hz: the inverse
edges  = mel→hz(linspace(hz→mel(0), hz→mel(8000), 82))      # 82 edge frequencies
fft_f  = linspace(0, 8000, 201)
for filter j in 0..79:  weight(bin k) = max(0, min((fft_f[k] − edges[j]) / (edges[j+1] − edges[j]),
                                                  (edges[j+2] − fft_f[k]) / (edges[j+2] − edges[j+1])))
                        weight *= 2 / (edges[j+2] − edges[j])                # Slaney area norm
```

This is librosa's `filters.mel(sr=16000, n_fft=400, n_mels=80, htk=False, norm='slaney')`, the same
matrix OpenAI ships as `mel_filters.npz`. It is small enough (80×201) to ship as a constant.

Implementation advice: do the front end on the host in C. It is 801 real FFTs of length 400
(400 = 2⁴·5², so any mixed-radix FFT such as pocketfft or kissfft works; a 400×402 DFT matrix
product also works). It needs one global max, which ggml has no reduction for. In float32 it
matches HF to about 1e-5; HF computes it in float32 (torch) or float64 (numpy) and the two differ
by 1.2e-5 with no effect on the output (< 1e-6).

**Do not copy whisper.cpp's `log_mel_spectrogram`.** It reflects on the left but zero-pads on
the right and appends 30 s of zeros. The right edge is where the newest audio is. Replacing the
reflection there with zeros moved p on the 6 s prefix of the reference WAV from 0.1747 to 0.1405.

## 4. Network

### Encoder: Whisper-tiny, cut to 8 s

HF `WhisperEncoder` with the openai/whisper-tiny config, except
`config.max_source_positions = 400`:

| Item | Value |
|---|---|
| Input | log-mel [80, 800] (exactly 800 frames; HF raises otherwise) |
| conv1 | Conv1d 80→384, k3, stride 1, pad 1, bias, then GELU (erf) → [384, 800] |
| conv2 | Conv1d 384→384, k3, stride 2, pad 1, bias, then GELU → [384, 400] |
| positions | `embed_positions.weight` [400, 384] added after the transpose to [400, 384]. It is the first 400 rows of Whisper's fixed sinusoidal table (`sinusoids(400, 384)`, frozen during training; matches the formula to 2.3e-5, f32 rounding). |
| layers | 4, pre-LN: `h += out_proj(MHA(LN1(h)))`; `h += fc2(GELU(fc1(LN2(h))))` |
| d_model, heads, head dim, FFN | 384, 6, 64, 1536 |
| attention | q and v have bias, **k has no bias**, out_proj has bias; scale 1/√64 = 0.125 (the export applies 64^−¼ to both q and k); softmax over keys; **no mask** (all 400 positions attend to all) |
| LayerNorm | eps 1e-5, biased variance, affine |
| GELU | exact erf GELU everywhere (`0.5·x·(1+erf(x/√2))`) |
| final | `encoder.layer_norm` → [400, 384] |

So yes, the encoder is truncated: it keeps Whisper-tiny's weights and structure but runs on
400 positions (8 s of audio) instead of 1500 (30 s). This is the same trick as whisper.cpp's
`audio_ctx`. Every encoder weight was fine-tuned (nothing is frozen except the positional table),
so Whisper-tiny's own weights (for example whisper.cpp's `ggml-tiny.bin`) cannot be reused.

### Head: attention pooling + MLP

```
s      = pool_attention.2( tanh( pool_attention.0(h) ) )     # Linear 384→256, Tanh, Linear 256→1   → [400, 1]
a      = softmax(s, over the 400 time steps)
pooled = Σ_t a_t · h_t                                        # [384]
z = classifier.0(pooled)          # Linear 384→256
z = GELU(classifier.1(z))         # LayerNorm(256), eps 1e-5 — then GELU
                                  # classifier.3 is Dropout(0.1), no-op
z = GELU(classifier.4(z))         # Linear 256→64
z = classifier.6(z)               # Linear 64→1
p = sigmoid(z)                    # the ONNX output named "logits" is already this probability
```

`pool_attention.2.bias` (−4.5e-5) cancels in the softmax; you may drop it.

**Output and threshold:** p is the probability that the turn is complete. Upstream
(`inference.py`, pipecat) uses `prediction = 1 if p > 0.5 else 0`. The published benchmarks are
at 0.5, and the third-party conversions (mlx-community, soniqo) record `threshold: 0.5` in their
configs. No other threshold is recommended anywhere upstream.

Size: 8,000,386 values in 79 tensors, including the 153,600-value positional table; 7,291,200 of
them are 2-D matmul weights and 534,528 are the two conv kernels. Cost per inference is about
3.6 G multiply-adds (conv stem 0.25 G; each layer 0.83 G: 0.24 G for QKVO, 0.12 G for attention,
0.47 G for the FFN), about 7 GFLOP.

## 5. Tensors

PyTorch-style names as in the state dict (drop the export's `inner.` prefix). "ggml ne" is the
PyTorch shape reversed, which is what a verbatim copy of the row-major data gives you.

| Name | PyTorch shape | ggml ne | Source in `smart-turn-v3.2-gpu.onnx` |
|---|---|---|---|
| `encoder.conv1.weight` | [384, 80, 3] | [3, 80, 384] | `inner.encoder.conv1.weight` |
| `encoder.conv1.bias` | [384] | [384] | `inner.encoder.conv1.bias` |
| `encoder.conv2.weight` | [384, 384, 3] | [3, 384, 384] | `inner.encoder.conv2.weight` |
| `encoder.conv2.bias` | [384] | [384] | `inner.encoder.conv2.bias` |
| `encoder.embed_positions.weight` | [400, 384] | [384, 400] | `inner.encoder.embed_positions.weight` |
| `encoder.layers.{L}.self_attn_layer_norm.{weight,bias}` | [384] | [384] | same name with `inner.` |
| `encoder.layers.{L}.self_attn.q_proj.weight` | [384, 384] | [384, 384] | `val_{17,92,165,238}[L]`, **transposed** |
| `encoder.layers.{L}.self_attn.q_proj.bias` | [384] | [384] | same name with `inner.` |
| `encoder.layers.{L}.self_attn.k_proj.weight` | [384, 384] | [384, 384] | `val_{25,100,173,246}[L]`, transposed (no bias exists) |
| `encoder.layers.{L}.self_attn.v_proj.weight` | [384, 384] | [384, 384] | `val_{32,107,180,253}[L]`, transposed |
| `encoder.layers.{L}.self_attn.v_proj.bias` | [384] | [384] | same name with `inner.` |
| `encoder.layers.{L}.self_attn.out_proj.weight` | [384, 384] | [384, 384] | `val_{75,148,221,294}[L]`, transposed |
| `encoder.layers.{L}.self_attn.out_proj.bias` | [384] | [384] | same name with `inner.` |
| `encoder.layers.{L}.final_layer_norm.{weight,bias}` | [384] | [384] | same name with `inner.` |
| `encoder.layers.{L}.fc1.weight` | [1536, 384] | [384, 1536] | `val_{79,152,225,298}[L]` (stored [384,1536]), transposed |
| `encoder.layers.{L}.fc1.bias` | [1536] | [1536] | same name with `inner.` |
| `encoder.layers.{L}.fc2.weight` | [384, 1536] | [1536, 384] | `val_{88,161,234,307}[L]` (stored [1536,384]), transposed |
| `encoder.layers.{L}.fc2.bias` | [384] | [384] | same name with `inner.` |
| `encoder.layer_norm.{weight,bias}` | [384] | [384] | same name with `inner.` |
| `pool_attention.0.weight` | [256, 384] | [384, 256] | `val_311` (stored [384,256]), transposed |
| `pool_attention.0.bias` | [256] | [256] | `inner.pool_attention.0.bias` |
| `pool_attention.2.weight` | [1, 256] | [256, 1] | `val_313` (stored [256,1]), transposed |
| `pool_attention.2.bias` | [1] | [1] | `inner.pool_attention.2.bias` |
| `classifier.0.weight` | [256, 384] | [384, 256] | `inner.classifier.0.weight` (Gemm, transB=1, already PyTorch layout) |
| `classifier.0.bias` | [256] | [256] | `inner.classifier.0.bias` |
| `classifier.1.{weight,bias}` | [256] | [256] | `inner.classifier.1.*` (the LayerNorm) |
| `classifier.4.weight` | [64, 256] | [256, 64] | `inner.classifier.4.weight` |
| `classifier.4.bias` | [64] | [64] | `inner.classifier.4.bias` |
| `classifier.6.weight` | [1, 64] | [64, 1] | `inner.classifier.6.weight` |
| `classifier.6.bias` | [1] | [1] | `inner.classifier.6.bias` |

The same `val_*` numbering holds in `smart-turn-v3.1-gpu.onnx`. Don't hard-code it, though: a
re-export renumbers them. Derive the mapping from the graph (next section).

In `mlx-community/smart-turn-v3/model.safetensors` the tensors that were named initializers keep
the `inner.` prefix (`inner.encoder.conv1.weight`, ...), and the reconstructed linear weights
have no prefix (`encoder.layers.0.self_attn.q_proj.weight`, `pool_attention.0.weight`, ...),
already transposed back to PyTorch [out, in]. Strip `inner.` and you get exactly the names in the
table above: 79 tensors.

## 6. Reading the ONNX directly

If you want to load the ONNX without Python, a minimal protobuf reader is enough. Every
initializer in these files is inline `raw_data` (little-endian); none uses `float_data` or
external data. The fields needed (tested on all the files above):

```
ModelProto:   7 graph (message)
GraphProto:   1 node (repeated message), 5 initializer (repeated TensorProto),
              11 input, 12 output (ValueInfoProto)
NodeProto:    1 input (repeated string), 2 output (repeated string), 3 name, 4 op_type,
              5 attribute (repeated AttributeProto), 7 domain
TensorProto:  1 dims (repeated int64; packed or not), 2 data_type (1 FLOAT, 2 UINT8, 3 INT8,
              6 INT32, 7 INT64, 10 FLOAT16), 8 name, 9 raw_data, 4 float_data (packed),
              13 external_data, 14 data_location (1 = external)
AttributeProto: 1 name, 20 type, 2 f, 3 i, 4 s, 5 t (TensorProto), 6 g (GraphProto), 7 floats, 8 ints
wire types: 0 varint, 1 fixed64, 2 length-delimited, 5 fixed32
```

Mapping the anonymous `val_*` weights to names: for every `MatMul` whose second input is an
initializer, look at the node consuming its output. If that node is an `Add` with an
`inner.*.bias` initializer, the weight is that bias's `.weight` (q_proj, v_proj, out_proj, fc1,
fc2, pool_attention.0). The four `MatMul`s with no bias `Add` are the k_proj weights; assign them
by which LayerNorm output feeds them (`layer_norm`, `layer_norm_2`, `layer_norm_4`,
`layer_norm_6` → layers 0..3). `pool_attention.2` has an `Add` with the scalar bias. MatMul
weights are stored [in, out], so transpose them to PyTorch [out, in]; the `Gemm` weights of the
classifier have `transB=1` and are already [out, in]. Other constants in the graph: `val_1` = √2,
`val_4` = 1, `val_6` = 0.5 (the erf-GELU), `val_63` = 0.353553 = 64^−¼ (the split attention
scale), and int64 shape constants.

The int8 file (`-cpu`) is QDQ. Each quantized weight is an INT8 initializer `<w>_quantized` with
per-channel `<w>_scale` (float) and `<w>_zero_point` (INT8) feeding a `DequantizeLinear`, axis 0
for Conv/Gemm weights and axis 1 for the [in, out] MatMul weights. Activations go through
`QuantizeLinear`/`DequantizeLinear` pairs with per-tensor uint8 (for example the input features:
scale 0.0096, zero point 28). Only `embed_positions` stays float. As said in section 1, don't use it
as a weight source.

## 7. Forward pass in ggml (verified)

Layout: ggml ne0 is the fastest dimension. The mel input from HF is [80][800] row-major, which is
ggml ne [800, 80], i.e. [length, channels], the data layout `ggml_im2col` expects for 1-D conv.
All weights are loaded as in section 5.

```c
// conv1d with an F32 im2col; ggml_conv_1d would round the activations to F16.
static ggml_tensor * conv1d(ggml_context * c, ggml_tensor * k /*[K,IC,OC]*/, ggml_tensor * x /*[L,IC]*/, int s, int p) {
    ggml_tensor * im = ggml_im2col(c, k, x, s, 0, p, 0, 1, 0, false, GGML_TYPE_F32);              // [N, OL, IC*K]
    ggml_tensor * r  = ggml_mul_mat(c, ggml_reshape_2d(c, im, im->ne[0], im->ne[2]*im->ne[1]),
                                       ggml_reshape_2d(c, k, k->ne[0]*k->ne[1], k->ne[2]));       // [N*OL, OC]
    return ggml_reshape_3d(c, r, im->ne[1], k->ne[2], im->ne[2]);                                 // [OL, OC, N]
}
static ggml_tensor * ln(ggml_context * c, ggml_tensor * x, ggml_tensor * w, ggml_tensor * b) {
    return ggml_add(c, ggml_mul(c, ggml_norm(c, x, 1e-5f), w), b);                                // over ne0
}

// conv stem
x = ggml_gelu_erf(c, ggml_add(c, conv1d(c, conv1_w, mel, 1, 1), ggml_reshape_2d(c, conv1_b, 1, 384)));   // [800,384]
x = ggml_gelu_erf(c, ggml_add(c, conv1d(c, conv2_w, x,   2, 1), ggml_reshape_2d(c, conv2_b, 1, 384)));   // [400,384]
h = ggml_add(c, ggml_cont(c, ggml_transpose(c, ggml_reshape_2d(c, x, 400, 384))), pos);                 // [384,400]

for (l = 0; l < 4; l++) {
    y  = ln(c, h, ln1_w, ln1_b);
    q  = ggml_add(c, ggml_mul_mat(c, wq, y), bq);                                   // [384,400]
    k  = ggml_mul_mat(c, wk, y);                                                    // no bias
    v  = ggml_add(c, ggml_mul_mat(c, wv, y), bv);
    Q  = ggml_permute(c, ggml_reshape_3d(c, q, 64, 6, 400), 0, 2, 1, 3);            // [64,400,6]
    K  = ggml_permute(c, ggml_reshape_3d(c, k, 64, 6, 400), 0, 2, 1, 3);            // [64,400,6]
    P  = ggml_soft_max_ext(c, ggml_mul_mat(c, K, Q), NULL, 0.125f, 0.0f);           // [400 keys, 400 queries, 6]
    V  = ggml_cont(c, ggml_permute(c, ggml_reshape_3d(c, v, 64, 6, 400), 1, 2, 0, 3)); // [400,64,6]
    O  = ggml_cont_2d(c, ggml_permute(c, ggml_mul_mat(c, V, P), 0, 2, 1, 3), 384, 400);
    h  = ggml_add(c, h, ggml_add(c, ggml_mul_mat(c, wo, O), bo));
    y  = ln(c, h, ln2_w, ln2_b);
    y  = ggml_gelu_erf(c, ggml_add(c, ggml_mul_mat(c, fc1_w, y), fc1_b));           // [1536,400]
    h  = ggml_add(c, h, ggml_add(c, ggml_mul_mat(c, fc2_w, y), fc2_b));
}
h = ln(c, h, enc_ln_w, enc_ln_b);                                                   // [384,400]

// attention pooling
s      = ggml_add(c, ggml_mul_mat(c, pool2_w, ggml_tanh(c, ggml_add(c, ggml_mul_mat(c, pool0_w, h), pool0_b))), pool2_b); // [1,400]
a      = ggml_soft_max_ext(c, ggml_reshape_2d(c, s, 400, 1), NULL, 1.0f, 0.0f);    // softmax over time
pooled = ggml_mul_mat(c, ggml_cont(c, ggml_transpose(c, h)), a);                   // [384,1]

// head
z = ggml_add(c, ggml_mul_mat(c, cls0_w, pooled), cls0_b);                           // [256,1]
z = ggml_gelu_erf(c, ln(c, z, cls1_w, cls1_b));
z = ggml_gelu_erf(c, ggml_add(c, ggml_mul_mat(c, cls4_w, z), cls4_b));             // [64,1]
p = ggml_sigmoid(c, ggml_add(c, ggml_mul_mat(c, cls6_w, z), cls6_b));              // [1,1]
```

This is the non-flash attention path of whisper.cpp's `whisper_build_graph_encoder`, without the
f16 casts and with `ggml_gelu_erf` where whisper.cpp uses `ggml_gelu`. `ggml_flash_attn_ext(Q, K,
V, NULL, 0.125f, 0, 0)` with K and V as [64, 400, 6] (result [64, 6, 400], reshape to [384, 400])
also works. whisper.cpp pads K/V to 256 and casts them to F16 when it uses it, which costs
precision for no gain at 400 positions.

Ops needed: `ggml_im2col`, `ggml_mul_mat`, `ggml_add`, `ggml_mul`, `ggml_gelu_erf`, `ggml_norm`,
`ggml_reshape_2d/3d`, `ggml_permute`, `ggml_transpose`, `ggml_cont`, `ggml_cont_2d`,
`ggml_soft_max_ext`, `ggml_tanh`, `ggml_sigmoid` (plus the host front end). All of them exist in
the CPU, Metal and CUDA backends of the vendored ggml. `GGML_OP_GELU_ERF` also has Metal, CUDA,
Vulkan and WebGPU kernels.

Run it once per decision, not per chunk. Unlike the VAD, it is large enough to benefit from the
GPU backends. On the CPU backend of an Apple M4, 4 threads, in an unoptimized harness (graph
rebuilt per call, no BLAS): F32 weights about 75 ms, F16 about 50 ms, Q8_0 about 45 ms.

## 8. Precision (measured against the fp32 ONNX on the 11 reference inputs)

| Variant | max \|Δp\| |
|---|---:|
| this graph, F32 weights, F32 im2col, `ggml_gelu_erf` | 2e-6 |
| `ggml_conv_1d` (F16 im2col) for the two stem convs | 3e-4 (emulated), 6e-4 (ggml) |
| tanh-approximate GELU instead of erf (measured in PyTorch; ggml's CPU `ggml_gelu` also rounds through an F16 table) | 1.7e-3 |
| F16 matmul weights (conv and norms F32) | 1.8e-3 |
| Q8_0 matmul weights | 1.2e-2 |
| pipecat's int8 ONNX (`-cpu`) vs its fp32 ONNX | 1.1e-1 (0.949 → 0.839 on the full clip) |
| normalize only the real audio and leave the pad at exact zero (wrong) | 1.1e-2 |
| zero instead of reflect padding at the right edge of the STFT (wrong) | 3.4e-2 |

Recommendation: F32 for the conv stem, biases, norms and positional table, and F16 for the 2-D
matmul weights: 17.4 MB in total. Q8_0 matmul weights (10.6 MB in total) are acceptable if size
matters; that is still closer to fp32 than the int8 model pipecat ships.

## 9. When to run it

From the upstream README and pipecat:

- Run it when the VAD reports the end of speech. Pipecat's VAD stops after 0.2 s below
  confidence 0.7 (`VADParams.stop_secs = 0.2`; see `silero_vad.md`, section 7). The demo
  `record_and_predict.py` instead waits for 1 s of VAD silence.
- Input is the **whole current turn**, from speech start (pipecat includes `pre_speech_ms = 500`
  ms before the VAD start, plus the VAD's `start_secs`) up to now, trailing silence included,
  truncated to the last 8 s. Audio from earlier turns is not needed.
- If p ≤ 0.5 (incomplete), keep listening. If the user speaks again, re-run on the **entire**
  turn including the new audio, not only the new segment. Pipecat's fallback ends the turn anyway
  after `stop_secs = 3` s of silence.
- The model is not meant for very short clips; it needs the context.
- Pipecat keeps int16 PCM and divides by 32768 before the front end. The normalization in step 2
  makes the scale irrelevant anyway.

## 10. Reference numbers

Fixed WAV: whisper.cpp `samples/jfk.wav` (16 kHz mono, 176,000 samples, sha256
`59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`; "And so my fellow
Americans, ask not what your country can do for you, ask what you can do for your country.").
Inputs are prefixes `wav[:n·16000]` for n = 1..11 s, which simulates the decision at different
pause points.

Script outline (numpy, transformers ≥ 4.5x, onnxruntime, soundfile):

```python
from transformers import WhisperFeatureExtractor
fe = WhisperFeatureExtractor(chunk_length=8)
def last8(a):
    n = 128000
    return a[-n:] if len(a) > n else np.pad(a, (n - len(a), 0))
def feats(a):
    return fe(last8(a), sampling_rate=16000, return_tensors='np', padding='max_length',
              max_length=128000, truncation=True, do_normalize=True).input_features.astype(np.float32)  # [1,80,800]
s32 = ort.InferenceSession('smart-turn-v3.2-gpu.onnx'); s8 = ort.InferenceSession('smart-turn-v3.2-cpu.onnx')
for n in range(1, 12):
    x = feats(wav[:n * 16000])
    print(n, s32.run(None, {'input_features': x})[0].item(), s8.run(None, {'input_features': x})[0].item())
np.save('features_11s.npy', feats(wav))   # compare the C front end against this
```

Results (the fp32 column is also what our PyTorch re-implementation and our ggml graph give, to
2e-6):

| prefix | p fp32 (v3.2-gpu) | p int8 (v3.2-cpu) |
|---:|---:|---:|
| 1 s | 0.006065 | 0.006422 |
| 2 s | 0.006468 | 0.008120 |
| 3 s | 0.986309 | 0.954035 |
| 4 s | 0.005287 | 0.006176 |
| 5 s | 0.071745 | 0.082973 |
| 6 s | 0.174734 | 0.092418 |
| 7 s | 0.007210 | 0.014565 |
| 8 s | 0.020051 | 0.023163 |
| 9 s | 0.013589 | 0.017009 |
| 10 s | 0.019509 | 0.015142 |
| 11 s (whole clip, last 8 s) | 0.948620 | 0.839466 |

Feature checks: for the whole clip the [1, 80, 800] features have min −0.107879, max 1.892121,
mean 0.577721. For the 1 s prefix, frames 0–599 (well inside the 7 s of padding) all sit exactly
at the floor value 0.022983 ((max − 8 + 4)/4).

## 11. Gotchas

- **Padding goes at the start**, and the normalization statistics include it. The feature
  extractor on its own pads on the *right* and excludes the pad from the statistics; always run
  `truncate_audio_to_last_n_seconds` first, as upstream does.
- **Reflect-pad both STFT edges** and drop the 801st frame. Take the −8 floor over the whole
  8 s window.
- **Exact GELU.** `ggml_gelu` is the tanh approximation read from an F16 table on the CPU; use
  `ggml_gelu_erf`.
- **`ggml_conv_1d` rounds activations to F16**; use `ggml_im2col(..., GGML_TYPE_F32)` +
  `ggml_mul_mat`, and keep conv kernels F32 (in that product the kernel is the `src1` operand,
  which must be F32).
- k_proj has **no bias**. The attention scale is 1/8 in total (the ONNX splits it as 64^−¼ on q
  and on k).
- The attention pooling softmax runs over **time** (the 400 positions), not over channels.
- The ONNX output named `logits` is already a **probability** in pipecat's files, but the
  onnx-community `model.onnx` returns a raw logit (Sigmoid removed) and is v3.1.
- In the fp32 ONNX all linear weights are anonymous `val_*` tensors stored [in, out]. Transpose
  them.
- Exactly 800 mel frames. The positional table has 400 rows, so the encoder cannot take longer or
  shorter input without retraining.
- Match on the fp32 model. The int8 model is a different function (activation quantization) and
  differs by up to 0.11.

## 12. Port

Ported 2026-09-10 to `console/ml/smart_turn.lua`, with `console/ml/convert/smart_turn.lua` and
`test/ml_smart_turn_test.lua`.

    local turn = require("console.ml.smart_turn").load(engine, "console/ml/models/smart-turn-v3.2.gguf")
    turn:predict(samples_16k)   -- the turn so far -> p(finished); turn:features(s), turn:predict_features(mel)

**Weights.** The converter reads `mlx-community/smart-turn-v3/model.safetensors` (copied to
`console/ml/models/smart-turn-v3.2.safetensors`), strips `inner.`, and writes the 79 tensors under
the state-dict names of section 5. Its third argument is the type of the 2-D product weights:
`f32` (the default, 32 MB), `f16` or `q8_0`. Conv kernels, norms, biases and the position table
are always f32.

**Front end.** The last 8 s, zeros in front; mean and variance from `buffer:stats()` (in double)
over all 128,000 samples; the normalization itself as one node on the engine (a Lua loop over a
buffer would cost more than the model); then `ml.whisper_mel(x, 80, 800)`. The features match
`WhisperFeatureExtractor` to 1.2e-5 per value on the whole clip.

**Graph.** Section 7, as written, with two changes. `Q` and `K` are made contiguous before their
product, and the conv stem's second conv puts the kernel first so its output is already
[384, 400] and needs no transpose. The graph is built once and computed again per prediction;
173 nodes, one split on Metal.

**Checked.** Against pipecat's `smart-turn-v3.2-gpu.onnx` (onnxruntime 1.19, features from
transformers 4.57) on the 1–11 s prefixes of `jfk.wav`, the reference printed to 7 decimals:

| weights | CPU max \|Δp\| | Metal max \|Δp\| |
|---|---:|---:|
| f32 | 1.9e-6 | 2.3e-4 |
| f16 | 1.4e-3 | 2.3e-4 |
| q8_0 | 9.7e-3 | 4.7e-3 |

Every decision at 0.5 is the reference's. Tolerances in the test: 1e-5 on the CPU, 2e-3 on the
device.

**Speed** (Apple M4, wall clock, the whole clip, the same on LuaJIT and Lua 5.5):

| engine | features | model | predict |
|---|---:|---:|---:|
| CPU, 4 threads, f32 | 25 ms | 61 ms | 87 ms |
| CPU, 8 threads, f32 | 25 ms | 46 ms | 72 ms |
| CPU, 4 threads, f16 | 25 ms | 43 ms | 69 ms |
| CPU, 4 threads, q8_0 | 25 ms | 39 ms | 65 ms |
| Metal, f32 | 25 ms | 7 ms | 35 ms |
| Metal, f16 | 25 ms | 6 ms | 36 ms |

**For the next person.**

- The front end was most of a prediction on Metal: 23 of its 25 ms were `ml.whisper_mel`, and
  19 of those were `dsp.c`'s FFT working out its twiddle factors with `cos` and `sin` inside the
  butterflies. The twiddles are now a table made once per STFT, and `ml.whisper_mel` over 8 s
  takes 8.7 ms, so the times above are about 15 ms lower on every row.
- Metal's matrix-matrix kernel (`kernel_mul_mm_f32_f32`, used when the second operand has more
  than 8 columns) stages both operands in half precision, whatever the tensors' types. That is
  all of this model's large products, so on Metal f32 weights buy nothing over f16: the same
  2.3e-4, and 16 MB more. On the CPU f32 is the exact one. The small products of the pooling and
  the head (one column) take the f32 matrix-vector kernel on Metal too.
- Run it when the VAD says speech stopped, on the whole turn (section 9). It answers in about
  35 ms on Metal, well inside pipecat's 200 ms stop window.
