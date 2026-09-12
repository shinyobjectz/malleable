# ASR: Moonshine Streaming on ggml

Implementation spec for the console's speech recogniser. Researched 2026-09-10 against
transformers `main` (the `moonshine_streaming` model), the Hugging Face checkpoints, the
official `moonshine-ai/moonshine` runtime (234f60f), transcribe.cpp (92fc36d) and CrispASR
(301acd8). Every number below was read from those sources or from the safetensors headers
over HTTP; nothing is from memory unless it says so.

Notation: shapes of torch tensors are written `(a, b)` in torch order; ggml shapes are
written `ne=[ne0, ne1, ...]`, innermost first, so a torch `Linear(in, out)` weight of shape
`(out, in)` is `ne=[in, out]` in ggml and `ggml_mul_mat(W, x)` with `x ne=[in, T]` gives
`ne=[out, T]`.

---

## 1. The choice

**Primary: Moonshine Streaming Small (123 M).** **Tiny variant: Moonshine Streaming Tiny
(34 M)** for WebAssembly and weak CPUs. **Medium (245 M)** runs on the same code with a
different config and is the upgrade when a GPU is present; it sits at the size budget.

| Candidate | Params | WER (LS-clean; Open ASR avg where known) | True streaming? | Licence (code / weights) | Writing it on ggml |
|---|---|---|---|---|---|
| **Moonshine Streaming tiny** | 34 M | 4.49; avg 12.01 | Yes. Causal conv frontend, sliding-window encoder with no positions, 240 ms fixed lookahead, encoder frames final once seen | MIT / MIT | Easy. Plain transformer; two causal convs; no FFT |
| **Moonshine Streaming small** | 123 M | 2.49; avg 7.84 | Same | MIT / MIT | Same code |
| **Moonshine Streaming medium** | 245 M | 2.08; avg 6.65 | Same | MIT / MIT | Same code |
| Moonshine v1 tiny / base | 27 M / 61 M | tiny 4.58, base 3.28 (ggml port) | No. Full-attention encoder with RoPE; every update re-encodes the whole buffer | MIT / MIT | Easy |
| NVIDIA Parakeet realtime EOU 120M v1 | 120 M | 3.61; avg 9.30 | Yes. Cache-aware FastConformer-RNNT, 80-160 ms | NVIDIA Open Model License | Hard. Mel frontend, relative-position attention with limited context, cached depthwise causal convs, RNNT with an LSTM predictor (no LSTM op in ggml). No punctuation or case |
| NVIDIA Nemotron Speech Streaming en 0.6B | 600 M | 2.31 (ggml Q8_0); streaming avg 8.20 (arXiv 2604.14493, int4) | Yes. Cache-aware, 80 ms-1.12 s chunks | NVIDIA Open Model License | Hard, and over budget (Q8_0 is 696 MB) |
| Kyutai stt-1b-en_fr | ~1 B | not on the card | Yes, 0.5 s delay, 12.5 Hz | weights CC-BY-4.0 | Hard. Needs the Mimi codec (conv encoder, transformer, RVQ) plus a 1 B decoder; over budget |
| Whisper tiny.en / base.en + streaming wrapper | 39 M / 74 M | tiny.en 5.77, base.en 4.14 (ggml port) | No. Fixed 30 s window re-encoded per update; LocalAgreement-style commits arrive 1-3 s late; hallucinates on silence | MIT (OpenAI release; the HF cards say Apache-2.0) | Easy (whisper.cpp exists), but the wrapper is the problem |
| Mistral Voxtral Realtime 2602 | ~4.4 B | 2.07 (Q8_0) | Yes | Apache-2.0 | Far over budget (Q8_0 4.7 GB) |
| k2-fsa streaming Zipformer transducers | 20-70 M | not weighed | Yes | Apache-2.0 | Hardest on the list: multi-rate stacks, BiasNorm, Swoosh activations, chunked causal conv state |

Why Moonshine Streaming wins:

- **Accuracy per parameter.** Small (123 M) averages 7.84 % over the Open ASR sets, better than
  the 120 M Parakeet EOU (9.30 %) and close to the 600 M Nemotron (8.20 % streaming). It emits
  punctuation and case.
- **Streaming is in the architecture, not a wrapper.** The frontend is causal, the encoder has
  no positional encoding and only local windows, so an encoder frame is final 240 ms after its
  audio arrives and never changes. The decoder re-reads a growing cross-attention memory.
- **It is the easiest to write.** No STFT, no mel filterbank, no relative positions, no LSTM,
  no transducer search. Every op is in ggml except `asinh`, which is four ops.
- **MIT code and weights**, the only fully OSI-licensed option in the accurate tier.
- **Two independent ggml ports exist to check against** (transcribe.cpp, CrispASR), plus the
  official ONNX runtime whose streaming logic is readable C++.

### Weight files

The Hugging Face org `UsefulSensors` now redirects to `moonshine-ai`. All three repos are MIT,
not gated, and every tensor is F32. Pin the revisions.

| Variant | Repo @ revision | `model.safetensors` | Tensors | Stored values | Unique values |
|---|---|---|---|---|---|
| tiny | `moonshine-ai/moonshine-streaming-tiny` @ `f8e9dfd8c562c257c151a907b7b7f2fe8ff8511a` | 176,237,308 B | 161 | 44.05 M | 33.57 M |
| small | `moonshine-ai/moonshine-streaming-small` @ `2c036506f23a09c18df5a50057599ba6d9280999` | 560,571,228 B | 262 | 140.14 M | 123.36 M |
| medium | `moonshine-ai/moonshine-streaming-medium` @ `57b843633a8c183cadf6699ffa761377a933a866` | 1,063,634,564 B | 362 | 265.90 M | 244.93 M |

URL form: `https://huggingface.co/moonshine-ai/moonshine-streaming-<v>/resolve/<rev>/model.safetensors`.
The other files in each repo: `config.json` (1.4-1.7 KB), `generation_config.json`,
`preprocessor_config.json`, `processor_config.json`, `special_tokens_map.json`,
`tokenizer_config.json`, and `tokenizer.json` (1,676,069 B, sha256
`28bbc54a47dfa33673affa26010f23ac452685b18c76e81451d9b3ea25a54d54`, identical in all three).

"Unique" excludes `proj_out.weight`: the config says `tie_word_embeddings=false`, but sampled rows
(0, 1, 2, 500, 20000) of `proj_out.weight` and `model.decoder.embed_tokens.weight` are bit-identical
in all three checkpoints, and the paper's parameter counts (33.57 / 123.36 / 244.93 M) count the
matrix once. Our converter should compare the two tensors in full and store one if they match.

Ready-made GGUFs (MIT, transcribe.cpp naming, which we adopt, see section 4):

| Repo `handy-computer/moonshine-streaming-<v>-gguf` | F32 | F16 | Q8_0 |
|---|---|---|---|
| tiny | 177.8 MB | 89.8 MB | 50.5 MB |
| small | 562.1 MB | 282.1 MB | 198.5 MB |
| medium | 1065.2 MB | 533.8 MB | 295.8 MB |

In their Q8_0 files the 2-D matrices are Q8_0, the frontend `linear` and both conv kernels are
F16, and every 1-D tensor is F32. They store `lm_head` separately. Our own converter, which
dedups the head, would give about 36 / 131 / 260 MB at Q8_0.

---

## 2. Audio front end

There is no spectrogram. The model reads raw PCM.

- **Input:** 16 kHz mono float32 in [-1, 1] (int16 / 32768). No global normalisation
  (`do_normalize=false`), no dither, no pre-emphasis. Resample the microphone to 16 kHz with a
  proper low-pass (for example 48 kHz to 16 kHz by an FIR decimate-by-3).
- **Framing:** non-overlapping frames of `frame_len = round(16000 * 5 ms) = 80` samples. No window.
- **Per-frame CMVN**, with no parameters: `x = (x - mean(x)) / sqrt(mean((x - mean)^2) + 1e-6)` over
  the 80 samples of each frame. This is exactly `ggml_norm(x, 1e-6)` along ne0.
- **asinh compression:** `y = asinh(k * x)` with a learned scalar `k = exp(log_k)`:
  tiny `log_k = -0.438764` (`k = 0.644833`), small `-0.487520` (`0.614148`), medium `-0.592998`
  (`0.552668`).
- **Linear 80 -> De, no bias, then SiLU**, one vector per 5 ms frame (200 Hz).
- **CausalConv1d(De -> 2De, k=5, stride 2, bias) then SiLU** (100 Hz). "Causal" means 4 zero frames
  are padded on the left only; output `t` reads input frames `[2t-4, 2t]`.
- **CausalConv1d(2De -> De, k=5, stride 2, bias), no activation** (50 Hz). Output `t` reads conv1
  outputs `[2t-4, 2t]`.
- **Result:** one encoder input frame per 320 samples (20 ms). For input padded to a multiple of
  80 samples, `T_enc = ceil(n_samples / 320)` (HF: `T = n // 80; T = (T-1)//2 + 1; T = (T-1)//2 + 1`).

The frontend has no lookahead: an encoder input frame exists as soon as its 320 samples have
arrived.

**Streaming chunk size.** Feed the frontend in whole blocks of 320 samples (one encoder frame).
Then the stride-2 phase of both convs never shifts and the frontend state is just two
histories (section 3.5). Keep any remainder under 320 samples for the next call. Useful update
cadences: encoder every 80-160 ms of audio (4-8 frames); decoder every 240-500 ms (transcribe.cpp
defaults to 240 ms, the official runtime to 500 ms).

---

## 3. Architecture

### 3.1 Dimensions

| Symbol | Meaning | tiny | small | medium |
|---|---|---|---|---|
| `De` | encoder width | 320 | 620 | 768 |
| `He x hd_e` | encoder heads x head dim | 8 x 40 | 8 x 64 | 10 x 64 |
| `A` | encoder attention width `He*hd_e` | 320 | **512** | **640** |
| `Fe` | encoder FFN width | 1280 | 2480 | 3072 |
| `Le` | encoder layers | 6 | 10 | 14 |
| windows `(L,R)` per layer | | (16,4)x2, (16,0)x2, (16,4)x2 | (16,4)x2, (16,0)x6, (16,4)x2 | (16,4)x2, (16,0)x10, (16,4)x2 |
| `Dd` | decoder width = `Hd*hd_d` | 320 | 512 | 640 |
| `Hd x hd_d` | decoder heads x head dim | 8 x 40 | 8 x 64 | 10 x 64 |
| `Fd` | decoder FFN width (fc1 emits `2Fd`) | 1280 | 2048 | 2560 |
| `Ld` | decoder layers | 6 | 10 | 14 |
| rotary dims | `int(hd_d * partial_rotary_factor)` | 32 (0.8 x 40) | 32 (0.5 x 64) | 32 (0.5 x 64) |
| adapter projection | | none (De = Dd) | 620 -> 512 | 768 -> 640 |
| `Lt` left context, frames | `sum(L_i - 1)` | 90 (1.8 s) | 150 (3.0 s) | 210 (4.2 s) |
| `Rt` right context, frames | `sum(max(R_i - 1, 0))` | 12 (240 ms) | 12 | 12 |
| vocab `V` | | 32768 | 32768 | 32768 |
| `max_position_embeddings` | adapter table rows = decoder positions | 4096 | 4096 | 4096 |

All: no GQA (KV heads = heads), `attention_bias=false`, `rope_theta=10000`, `rope_type=default`,
`pad_head_dim_to_multiple_of=null`, LayerNorm eps 1e-5 everywhere except CMVN (1e-6).

In small and medium the encoder attention is not square: Q/K/V project `De -> A` and O projects
`A -> De`. The attention scale is `1/sqrt(hd)` (40 or 64), never `1/sqrt(De/He)`.

### 3.2 Encoder (per layer, pre-norm)

```
x (De, per frame)
h = LN_u(x) * (gamma_attn + 1)          # LayerNorm, no affine, no bias; "unit offset" gain
q,k,v = h Wq, h Wk, h Wv                # De -> A, no bias; split into He heads of hd_e
a = softmax(q k^T / sqrt(hd_e) + M_l) v # NO positional encoding of any kind
x = x + a Wo                            # A -> De, no bias
h = LN_u(x) * (gamma_ffn + 1)
x = x + fc2(gelu_erf(fc1(h)))           # fc1 De -> Fe (+bias), fc2 Fe -> De (+bias), exact erf GELU
```
After the last layer: `e = LN_u(x) * (gamma_final + 1)`.

The stored `gamma` tensors are centred on 0 (tiny `final_norm.gamma[:4] = [-0.070, 0.230, 0.091,
0.024]`); the effective gain is `gamma + 1`. Fold the `+1` at conversion.

**Sliding-window mask** for a layer with window `(L, R)`, query frame `q`, key frame `k`:
attend iff `0 <= q-k < L` or `0 < k-q < R`. So `(16,4)` sees 15 past frames, itself, and 3 future
frames; `(16,0)` sees 15 past frames and itself. Positions come only from the mask ("ergodic"
encoder), so the same audio gives the same output frame wherever it sits in the stream.

Receptive field of output frame `t`: frontend outputs `[t - Lt, t + Rt]`. Every output frame
whose 12 successors exist is final.

### 3.3 Adapter

```
m_t = e_t + P[t]        # P = learned table (4096, De); t = frame index from the start of the line
m_t = m_t Wp            # small/medium only: De -> Dd, no bias
```
`t` is absolute within the utterance. This is the only place position enters the audio path,
and it caps a line at 4096 frames (81.9 s).

### 3.4 Decoder (per layer, pre-norm)

```
x = E[token]                                   # (V, Dd) embedding, no scaling
h = LN(x) * w_in                               # plain LayerNorm weight, no bias, no offset
q,k,v = h Wq, h Wk, h Wv                       # Dd -> Dd, no bias
q,k = rope(q,k, pos)                           # interleaved pairs, first 32 dims of each head only
x = x + causal_softmax(q k^T / sqrt(hd_d)) v Wo
h = LN(x) * w_cross
x = x + softmax(h Wq_c (m Wk_c)^T / sqrt(hd_d)) (m Wv_c) Wo_c   # no RoPE, no mask, all frames
h = LN(x) * w_ffn
u = h W1 + b1                                  # Dd -> 2Fd
x = x + (silu(u[Fd:2Fd]) * u[0:Fd]) W2 + b2    # the SECOND half is the gate
```
Then `logits = (LN(x) * w_norm) W_lm` with `W_lm` the `(V, Dd)` head.

RoPE: `inv_freq_i = 10000^(-2i/32)` for `i < 16`; the pair `(2i, 2i+1)` is rotated by
`pos * inv_freq_i` (HF `rotate_half` over `x[..., 0::2]`, `x[..., 1::2]` with interleaved cos/sin).
Dims 32 and up pass through. This is `ggml_rope_ext(..., n_dims=32, mode=GGML_ROPE_TYPE_NORMAL)`,
not NEOX. Positions start at 0 for the BOS token.

### 3.5 Streaming mechanism

One **stream** is one line of speech (a VAD segment, at most 15 s as in the official runtime).
All state below is reset at each new line; the model was trained on utterances that start at
frame 0 and position 0, so a reset matches training.

**State carried between calls**

| State | Shape | Purpose |
|---|---|---|
| PCM remainder | < 320 samples | keeps the 320-sample block phase |
| `hist1` | `ne=[De, 4]` | last 4 post-SiLU `linear` outputs (conv1 left context), zeros at line start |
| `hist2` | `ne=[2De, 4]` | last 4 post-SiLU conv1 outputs (conv2 left context), zeros at line start |
| feature ring | `ne=[De, >= Lt + Rt + max_new]` + absolute index of column 0 | encoder inputs still needed |
| `N`, `C` | ints | features produced; encoder frames committed |
| Mode B only: per-layer input rings | `ne=[De, <= 15 + r_i + max_new]` per layer | see below |
| cross K/V per decoder layer | `ne=[Dd, T_max]` x 2 x `Ld` | projected memory; `T_max` = 1024 covers 20 s |
| self K/V per decoder layer | `ne=[Dd, n_ctx]` x 2 x `Ld` | `n_ctx` = 256 is plenty for 15 s |
| last hypothesis | token ids | speculative verification and stable-prefix display |

Zero histories at line start are exact: HF left-pads each conv input with zeros, and zeros in
the post-SiLU domain are what those histories hold.

**Encoder, mode A (windowed recompute; simplest; both ggml ports and the official runtime do this)**

Each encoder tick, after the frontend has appended features up to `N`:

1. `S = N - Rt` (stable frames). If `S <= C`, nothing to commit.
2. Window start `ws = max(0, C - Lt)`. Run the encoder on features `[ws, N)` with the masks of
   3.2 built for that window.
3. Output columns `[C - ws, S - ws)` are bit-for-bit (up to reduction order) what a one-shot run
   over the whole line gives for frames `[C, S)`. Columns before `C - ws` lack left context and
   are discarded; columns from `S - ws` lack right context (see "provisional" below).
4. Adapter on the committed slice with position ids `C .. S-1`, then per decoder layer
   `K_c = m Wk_c`, `V_c = m Wv_c` appended to the cross cache at columns `[C, S)`. `C = S`.
5. Drop features before `C - Lt`.

Cost per tick is `(Lt + Rt + new)` encoder frames. With 8 new frames per tick that is 110 frames
for tiny (about 5 GMAC/s of audio), 170 for small (46 GMAC/s), 230 for medium (135 GMAC/s). Fine
for tiny everywhere and for small/medium on Metal or CUDA; too heavy for small/medium on CPU.

**Encoder, mode B (incremental per layer; needed for small/medium on CPU)**

Layer `i` has `r_i = max(R_i - 1, 0)`. Keep per layer a ring of its *input* frames and an output
frontier `f_i` (frames of that layer's output that are final). With `f_{-1} = N`:

- new frontier `f_i' = f_{i-1}' - r_i`; new outputs are frames `[f_i, f_i')`;
- keys/values come from input frames `[a, b) = [max(0, f_i - 15), f_{i-1}')`, queries only from
  `[f_i, f_i')`; mask rule of 3.2 with absolute indices;
- residual and FFN run on the query columns only; append them to layer `i+1`'s ring;
- afterwards drop input frames before `f_i' - 15`.

The last frontier is `N - 12`, the same as mode A, and the arithmetic is the same as one-shot.
Cost is about one encoder pass per frame plus a K/V overhead of `(15 + r_i)` frames per layer
per tick: 3.0 GMAC/s of audio for small and 6.2 for medium, all stages included. Build mode A
first, then check mode B against it.

**Provisional tail (optional, lowers display latency by 240 ms).** On a display tick, also take
the encoder outputs for frames `[S, N)` (mode A already has them; mode B runs the remaining
layers on the not-yet-final frames without storing them), put their adapter + cross K/V in the
scratch columns `[S, N)` of the cross cache, and decode with `T_kv = N`. Those frames see a
truncated right context, which is exactly what one-shot does at the end of every utterance, so
the model has seen it in training. The next tick overwrites the scratch columns.

**Decoder: how it consumes new frames.** Cross-attention K/V are per-frame linear maps of the
adapter output, so new frames are appended columns. But every self-attention K/V the decoder
produced depends, through cross-attention, on all frames, so they go stale whenever frames are
added. Each decode tick therefore re-decodes the line from BOS. Speculative verification (the
official runtime's `decode_full`) makes this cheap:

1. Feed `[BOS, t1..tm]` (the previous hypothesis) at positions `0..m` in one batched pass with a
   causal mask; take `pred[i] = argmax(logits[i])`.
2. `d` = number of leading `i` with `pred[i] == t_{i+1}`.
3. The self K/V at positions `0..d` depend only on `BOS, t1..td`, so keep them: set `n_past = d+1`
   and continue greedy single-token steps from `pred[d]`. (The official code re-runs the
   accepted prefix here; that is unnecessary.)
4. Stop at EOS (id 2) or at the token budget (section 6).

**Revision and commit.**

- Within the open line the text is tentative and any token may change on the next tick.
- Display hint: the longest token prefix identical across the last 3 hypotheses is "stable"
  (transcribe.cpp's default). It is a hint, not a promise; transcribe.cpp documents that a
  "committed" token can still change.
- **Commit is per line.** When the VAD closes the line (or it reaches 15 s): finalize (zero any
  trailing partial 80-sample frame, zero-pad to a 320 multiple, run the frontend, set `S = N` and
  commit every frame), decode once more, freeze the text, reset the state. With that padding
  rule the final result equals HF one-shot on the same samples.

**VAD.** The official runtime uses Silero VAD (threshold 0.5, 0.5 s window, 512-sample hop,
8192-sample look-behind, 15 s max segment). A separate port; start with an energy gate plus a
hangover of about 300 ms and add Silero later. When a line hits 15 s, cut at the quietest 20 ms
frame of its last 2 s.

**Latency.** A stable encoder frame exists 20 ms (block) + 240 ms (right context) after its audio.
Displayed words lag that by half a decode period plus decode time, or by about 20 ms plus the
decode period with the provisional tail. Note the paper and model card describe the right context
as 4 frames (80 ms) per lookahead layer and a conservative 16-frame total, and the official
runtime waits 16 frames (320 ms); the code's mask gives 3 future frames per layer and 12 in total,
which transcribe.cpp verified gives exact parity with one-shot.

---

## 4. Tensors

GGUF names are transcribe.cpp's; loading their published GGUFs needs no renaming. Transforms
listed are applied by the converter. `i` = encoder layer, `j` = decoder layer. Steps refer to
section 5.

**Frontend** (`model.encoder.embedder.*`)

| HF name | GGUF name | torch shape | ggml ne | Transform | Step |
|---|---|---|---|---|---|
| `comp.log_k` | `enc.embedder.comp.log_k` | `()` | `[1]` | 0-d to 1-d; runtime uses `exp()` | F3 |
| `linear.weight` | `enc.embedder.linear.weight` | `(De, 80)` | `[80, De]` | keep F16 or F32 (80 is not a multiple of 32) | F4 |
| `conv1.weight` | `enc.embedder.conv1.weight` | `(2De, De, 5)` | `[5, De, 2De]` | keep F16 or F32 | F5 |
| `conv1.bias` | `enc.embedder.conv1.bias` | `(2De,)` | `[2De]` | | F5 |
| `conv2.weight` | `enc.embedder.conv2.weight` | `(De, 2De, 5)` | `[5, 2De, De]` | keep F16 or F32 | F6 |
| `conv2.bias` | `enc.embedder.conv2.bias` | `(De,)` | `[De]` | | F6 |

**Encoder** (`model.encoder.layers.i.*`, then the final norm)

| HF name | GGUF name | torch shape | ggml ne | Transform | Step |
|---|---|---|---|---|---|
| `input_layernorm.gamma` | `enc.blocks.i.norm_attn.weight` | `(De,)` | `[De]` | **+1.0** | E1 |
| `self_attn.q_proj.weight` | `enc.blocks.i.attn.q.weight` | `(A, De)` | `[De, A]` | | E2 |
| `self_attn.k_proj.weight` | `enc.blocks.i.attn.k.weight` | `(A, De)` | `[De, A]` | | E2 |
| `self_attn.v_proj.weight` | `enc.blocks.i.attn.v.weight` | `(A, De)` | `[De, A]` | | E2 |
| `self_attn.o_proj.weight` | `enc.blocks.i.attn.out.weight` | `(De, A)` | `[A, De]` | | E5 |
| `post_attention_layernorm.gamma` | `enc.blocks.i.norm_ffn.weight` | `(De,)` | `[De]` | **+1.0** | E6 |
| `mlp.fc1.weight` | `enc.blocks.i.ffn.fc1.weight` | `(Fe, De)` | `[De, Fe]` | | E6 |
| `mlp.fc1.bias` | `enc.blocks.i.ffn.fc1.bias` | `(Fe,)` | `[Fe]` | | E6 |
| `mlp.fc2.weight` | `enc.blocks.i.ffn.fc2.weight` | `(De, Fe)` | `[Fe, De]` | | E6 |
| `mlp.fc2.bias` | `enc.blocks.i.ffn.fc2.bias` | `(De,)` | `[De]` | | E6 |
| `model.encoder.final_norm.gamma` | `enc.final_norm.weight` | `(De,)` | `[De]` | **+1.0** | E7 |

**Adapter** (lives under `model.decoder` in HF)

| HF name | GGUF name | torch shape | ggml ne | Transform | Step |
|---|---|---|---|---|---|
| `model.decoder.pos_emb.weight` | `adapter.pos_emb.weight` | `(4096, De)` | `[De, 4096]` | | A1 |
| `model.decoder.proj.weight` (small, medium) | `adapter.proj.weight` | `(Dd, De)` | `[De, Dd]` | | A2 |

**Decoder top**

| HF name | GGUF name | torch shape | ggml ne | Transform | Step |
|---|---|---|---|---|---|
| `model.decoder.embed_tokens.weight` | `dec.token_embd.weight` | `(32768, Dd)` | `[Dd, 32768]` | | D1 |
| `model.decoder.norm.weight` | `dec.final_norm.weight` | `(Dd,)` | `[Dd]` | none (plain LN weight) | D8 |
| `proj_out.weight` | `dec.lm_head.weight` | `(32768, Dd)` | `[Dd, 32768]` | may alias `dec.token_embd.weight` if equal | D8 |

**Decoder layer** (`model.decoder.layers.j.*`)

| HF name | GGUF name | torch shape | ggml ne | Step |
|---|---|---|---|---|
| `input_layernorm.weight` | `dec.blocks.j.norm_self.weight` | `(Dd,)` | `[Dd]` | D2 |
| `self_attn.q_proj.weight` | `dec.blocks.j.self_attn.q.weight` | `(Dd, Dd)` | `[Dd, Dd]` | D2 |
| `self_attn.k_proj.weight` | `dec.blocks.j.self_attn.k.weight` | `(Dd, Dd)` | `[Dd, Dd]` | D2 |
| `self_attn.v_proj.weight` | `dec.blocks.j.self_attn.v.weight` | `(Dd, Dd)` | `[Dd, Dd]` | D2 |
| `self_attn.o_proj.weight` | `dec.blocks.j.self_attn.out.weight` | `(Dd, Dd)` | `[Dd, Dd]` | D5 |
| `post_attention_layernorm.weight` | `dec.blocks.j.norm_cross.weight` | `(Dd,)` | `[Dd]` | D6 |
| `encoder_attn.q_proj.weight` | `dec.blocks.j.cross_attn.q.weight` | `(Dd, Dd)` | `[Dd, Dd]` | D6 |
| `encoder_attn.k_proj.weight` | `dec.blocks.j.cross_attn.k.weight` | `(Dd, Dd)` | `[Dd, Dd]` | A3 |
| `encoder_attn.v_proj.weight` | `dec.blocks.j.cross_attn.v.weight` | `(Dd, Dd)` | `[Dd, Dd]` | A3 |
| `encoder_attn.o_proj.weight` | `dec.blocks.j.cross_attn.out.weight` | `(Dd, Dd)` | `[Dd, Dd]` | D6 |
| `final_layernorm.weight` | `dec.blocks.j.norm_ffn.weight` | `(Dd,)` | `[Dd]` | D7 |
| `mlp.fc1.weight` | `dec.blocks.j.ffn.fc1.weight` | `(2Fd, Dd)` | `[Dd, 2Fd]` | D7 |
| `mlp.fc1.bias` | `dec.blocks.j.ffn.fc1.bias` | `(2Fd,)` | `[2Fd]` | D7 |
| `mlp.fc2.weight` | `dec.blocks.j.ffn.fc2.weight` | `(Dd, Fd)` | `[Fd, Dd]` | D7 |
| `mlp.fc2.bias` | `dec.blocks.j.ffn.fc2.bias` | `(Dd,)` | `[Dd]` | D7 |

Counts: `6 + 1 + 10 Le + 1 (+1 proj) + 3 + 15 Ld` = 161 / 262 / 362, matching the headers.

Parameter groups (M values): tiny frontend 2.07, encoder 7.39, adapter 1.31, decoder layers 12.31,
embedding 10.49, head 10.49. Small 7.74 / 43.49 / 2.86 / 52.49 / 16.78 / 16.78. Medium 11.86 /
93.66 / 3.64 / 114.80 / 20.97 / 20.97.

**GGUF metadata keys** (transcribe.cpp; all under `stt.moonshine_streaming.` unless noted):
`encoder.{n_layers, d_model, n_heads, n_kv_heads, head_dim, ffn_dim, activation, frame_ms,
frame_len}`, `encoder.sliding_windows` (flat `[L0,R0,L1,R1,...]`), `decoder.{n_layers, d_model,
n_heads, n_kv_heads, head_dim, ffn_dim, activation, vocab_size, max_position_embeddings,
tie_word_embeddings}`, `partial_rotary_factor`, `rope_theta`, `attention_bias`,
`pad_head_dim_to_multiple_of`, `encoder_layernorm_unit_offset` (true: already folded), `cmvn_eps`,
`encoder_hidden_size`, `adapter_has_proj`, `{decoder_start,bos,eos,pad}_token_id`; plus
`tokenizer.ggml.{model=bpe, tokens, token_type, merges, byte_fallback, unknown_token_id,
bos_token_id, eos_token_id, padding_token_id}` and `stt.frontend.{type=raw, sample_rate}`.
CrispASR uses different keys (`moonshine_streaming.encoder.block_count`, ...); its GGUFs are not
interchangeable with these.

---

## 5. Forward pass in ggml ops

Activations F32 throughout. `LN(x, w)` below means `ggml_mul(ggml_norm(x, 1e-5), w)`. Graphs are
rebuilt per call (shapes change per tick); reserve the allocator once at the largest shapes
(`W_max`, `T_max`, the verify batch).

**Missing from ggml:** only `asinh` (composed in F3). Sliding-window attention is an explicit
mask. Everything else below exists in the pinned ggml (7840aab) and has kernels in the CPU, Metal,
CUDA, Vulkan and WebGPU backends: `ggml_gelu_erf`, `ggml_im2col` (Metal wants contiguous F32 data
and an F16 or F32 destination), `ggml_concat`, `ggml_flash_attn_ext`, `ggml_swiglu_swapped`,
`ggml_rope_ext`, `ggml_argmax`, `ggml_get_rows`, `ggml_set_rows`, `ggml_sgn`, `ggml_abs`,
`ggml_sqrt`, `ggml_log`. Flash-attention head dims 40 and 64 are accepted by Metal and CUDA; on
other backends ask `ggml_backend_supports_op` and fall back to `ggml_soft_max_ext`.

**Frontend** (one call per batch of `k` encoder frames = `320k` samples)

- F1. `x`: input `ne=[80, 4k]`, the PCM reshaped so each column is one 5 ms frame.
- F2. `x = ggml_norm(x, 1e-6)` (CMVN).
- F3. `z = ggml_scale(x, k_comp)` with `k_comp = exp(log_k)` computed on the host at load.
  `y = ggml_mul(ggml_sgn(z), ggml_log(ggml_add(ggml_abs(z), ggml_sqrt(ggml_scale_bias(ggml_sqr(z), 1, 1)))))`.
  That is `asinh` in its odd-symmetric form, which avoids cancellation for negative `z`.
- F4. `h = ggml_silu(ggml_mul_mat(W_lin, y))` gives `ne=[De, 4k]`.
- F5. conv1:
  `c = ggml_concat(hist1, h, 1)` gives `[De, 4k+4]`; the new `hist1` is `c` columns `[4k, 4k+4)`
  (copy into the state tensor with `ggml_cpy` of a `ggml_view_2d`).
  `cT = ggml_cont(ggml_transpose(c))` gives `[4k+4, De]`.
  `col = ggml_im2col(W_c1, ggml_reshape_3d(cT, 4k+4, De, 1), 2, 0, 0, 0, 1, 0, false, GGML_TYPE_F32)`
  gives `[5De, 2k, 1]` (use `GGML_TYPE_F16` if `W_c1` is F16).
  `u = ggml_mul_mat(ggml_reshape_2d(W_c1, 5De, 2De), ggml_reshape_2d(col, 5De, 2k))` gives
  `[2De, 2k]`, channels innermost, no transpose back.
  `u = ggml_silu(ggml_add(u, b_c1))`.
- F6. conv2: the same with `hist2` (`[2De, 4]`), `W_c2` (`[5, 2De, De]`, reshaped
  `[10De, De]`), giving `f = ggml_add(ggml_mul_mat(...), b_c2)`, `ne=[De, k]`. No activation.
  Append `f` to the feature ring.

(With `k` encoder frames the concat input has `4k+4` and `2k+4` columns, and a stride-2, k=5,
unpadded conv returns exactly `2k` and `k` outputs. Do not use `ggml_conv_1d`; see gotchas.)

**Encoder** (window `x = ne=[De, W]` from the feature ring; mode B uses the same ops on slices)

Masks: two F16 tensors `ne=[W, W]` (ne0 = key, ne1 = query), built on the host: `0` where the
3.2 rule allows, `-INFINITY` elsewhere. One for `(16,4)`, one for `(16,0)`; reuse them across
layers. In mode B the masks are `ne=[b-a, n_q]` with absolute indices.

For each layer `l`:

- E1. `h = LN(x, g_attn_l)`.
- E2. `q = ggml_mul_mat(Wq, h)`, `k`, `v` likewise, each `[A, W]`.
- E3. `q = ggml_cont(ggml_permute(ggml_reshape_3d(q, hd_e, He, W), 0, 2, 1, 3))` gives
  `[hd_e, W, He]`; the same for `k` and `v` (cast `k`, `v` to F16 with `ggml_cast` if the backend's
  flash attention wants F16).
- E4. `o = ggml_flash_attn_ext(q, k, v, mask_l, 1/sqrt(hd_e), 0, 0)` gives `[hd_e, He, W]`
  (already permuted), so `o = ggml_reshape_2d(o, A, W)`.
  Without flash attention: `s = ggml_mul_mat(k, q)` `[W, W, He]`;
  `s = ggml_soft_max_ext(s, mask_l, 1/sqrt(hd_e), 0)`;
  `o = ggml_mul_mat(ggml_cont(ggml_permute(v, 1, 0, 2, 3)), s)` `[hd_e, W, He]`;
  `o = ggml_reshape_2d(ggml_cont(ggml_permute(o, 0, 2, 1, 3)), A, W)`.
- E5. `x = ggml_add(x, ggml_mul_mat(Wo, o))`.
- E6. `h = LN(x, g_ffn_l)`; `h = ggml_gelu_erf(ggml_add(ggml_mul_mat(W1, h), b1))`;
  `x = ggml_add(x, ggml_add(ggml_mul_mat(W2, h), b2))`.
- E7. After the last layer: `e = LN(x, g_final)`. Keep the committed columns (and the
  provisional ones if used).

**Adapter and cross K/V** (slice `e_s = ne=[De, n]`, absolute frame ids `p0 .. p0+n-1`)

- A1. `m = ggml_add(e_s, ggml_get_rows(P, ids))` with `ids` I32 `[n]`.
- A2. Small and medium: `m = ggml_mul_mat(Wp, m)` gives `[Dd, n]`.
- A3. For each decoder layer `j`: `ggml_cpy(ggml_mul_mat(Wk_c_j, m), view_2d(cross_k[j], Dd, n, nb1, p0*nb1))`,
  and the same for V. Store the caches F16 (or F32).

**Decoder** (`n` tokens at positions `p .. p+n-1`; `n = m+1` for the verify pass, 1 per step)

- D1. `x = ggml_get_rows(E_tok, ids)` gives `[Dd, n]`.
- D2. `h = LN(x, w_self)`; `q, k, v = ggml_mul_mat(W*, h)` reshaped to `[hd_d, Hd, n]`.
- D3. `q = ggml_rope_ext(q, pos, NULL, 32, GGML_ROPE_TYPE_NORMAL, 0, 10000, 1, 0, 1, 0, 0)`, and the
  same for `k` (`pos` I32 `[n]`; with `ext_factor = 0` the beta arguments are unused).
- D4. Write roped `k` and `v` (`[Dd, n]`) into self-cache rows `p .. p+n-1` (`ggml_cpy` into a
  `ggml_view_2d`, or `ggml_set_rows`).
- D5. `K = ggml_view_3d(self_k[j], hd_d, n_kv, Hd, Dd*es, hd_d*es, 0)` with `n_kv = p+n`, `V` alike;
  `Q = ggml_permute(q, 0, 2, 1, 3)`;
  `o = ggml_flash_attn_ext(Q, K, V, mask, 1/sqrt(hd_d), 0, 0)`, where `mask` is F16 `[n_kv, n]`, 0 for
  `key <= p + query`, `-INF` otherwise, and `NULL` when `n = 1`;
  `x = ggml_add(x, ggml_mul_mat(Wo, ggml_reshape_2d(o, Dd, n)))`.
  (llama.cpp passes such strided cache views straight to flash attention; `ggml_cont` them if a
  backend refuses.)
- D6. `h = LN(x, w_cross)`; `Q = permute(reshape_3d(ggml_mul_mat(Wq_c, h), hd_d, Hd, n), 0, 2, 1, 3)`;
  `K, V` = views of `cross_k[j]`, `cross_v[j]` over `T_kv` columns; flash attention with no mask;
  `x = ggml_add(x, ggml_mul_mat(Wo_c, reshape_2d(o, Dd, n)))`.
- D7. `h = LN(x, w_ffn)`; `u = ggml_add(ggml_mul_mat(W1, h), b1)` `[2Fd, n]`;
  `g = ggml_swiglu_swapped(u)` `[Fd, n]` (that is `silu(u[Fd:]) * u[:Fd]`; plain `ggml_swiglu` is
  the wrong half); `x = ggml_add(x, ggml_add(ggml_mul_mat(W2, g), b2))`.
- D8. `x = LN(x, w_norm)`; `logits = ggml_mul_mat(W_lm, x)` `[V, n]`;
  `next = ggml_argmax(logits)` I32 `[n]`. Read back only `next` (one int per position).

**Per-frame and per-token cost** (MACs): frontend 3.2 / 11.7 / 17.9 M per encoder frame; encoder
7.4 / 43.5 / 93.7 M per frame; cross K/V 1.2 / 5.5 / 12 M per frame; decoder 22 / 64 / 124 M per
token including the head (tiny / small / medium).

---

## 6. Tokenizer and decoding

**Type.** SentencePiece-style BPE with byte fallback, the Llama-2 32000-piece layout: id 0 `<unk>`,
1 `<s>`, 2 `</s>`, 3-258 `<0x00>`..`<0xFF>`, 259 onward merged pieces with `U+2581` (`▁`) as the
word marker, plus 768 added specials `<<ST_0>>`..`<<ST_767>>` at 32000-32767 (never emitted in
transcription). 61,249 merges. The same `tokenizer.json` ships with all three variants; the GGUF
carries it as `tokenizer.ggml.tokens` / `token_type` / `merges`.

**Special ids.** `decoder_start = bos = 1`, `eos = 2`, `pad = 0` (`pad_token` string is `<unk>`).
No language, task or timestamp tokens.

**Detokenise.** For each id, skip 0, 1, 2 and anything >= 32000. If the piece is `<0xHH>`, emit
byte `HH`; otherwise emit the piece's UTF-8 with every `▁` replaced by a space. Concatenate the
bytes, decode as UTF-8, and strip one leading space. While streaming, hold back a trailing
incomplete UTF-8 sequence (byte-fallback characters span several tokens). Encoding text is only
needed for contextual biasing later: prepend `▁`, replace spaces with `▁`, apply the merges.

**Decoding.** Greedy argmax (`num_beams=1`, `do_sample=False` in the reference). No beam search.
Start with `[1]` at position 0. Stop at EOS or at the budget:

- HF model card: `max_length = int(n_samples * 6.5 / 16000)`, counting the start token. Use this
  for parity tests.
- Official runtime: `min(ceil(6.5 * seconds), 256)`; transcribe.cpp: `6.5 * seconds + 24`.
- Recommended: `min(ceil(6.5 * seconds) + 4, n_ctx - 1)`.

The budget is the guard against the looping hallucinations the model card warns about on short
or noisy segments. Our own addition (not in any reference): also stop when the tail repeats the
same n-gram (n >= 3) three times in a row.

**Timestamps.** None in the model. Line start and end come from sample counts. Word times, if
wanted later, can come from cross-attention peaks (the official runtime has
`core/word-alignment.h`); out of scope for the first port.

---

## 7. Existing implementations to check against

**transcribe.cpp** (`handy-computer/transcribe.cpp` @ `92fc36d`, MIT). Numerically validated
against HF; its streaming final transcript equals its one-shot on chunk sizes 1-1000 ms.

- `src/arch/moonshine_streaming/encoder.cpp`: `asinh_op` (L49), `mha_encoder_swa` (L66, non-square
  attention), `ffn_encoder` (L140), `build_sliding_window_mask` (L232), `build_encoder_graph`
  (L247, frontend + blocks).
- `src/arch/moonshine_streaming/decoder.cpp`: `apply_partial_rope` (L53), `ffn_decoder_swiglu`
  (L69), `mha_self_cached` (L95), `mha_cross_cached` (L188), `build_adapter_graph` (L248),
  `build_cross_kv_projection_graph` (L353), `build_decoder_graph_kv` (L462).
- `src/arch/moonshine_streaming/model.cpp`: `cumulative_right_context` / `_left_context`
  (L379/L393), `decode_generation_budget` (L431), `flush_stable_frames` (L1446), `trim_pcm_buffer`
  (L1542), `stream_feed` (L1560), `stream_finalize` (L1651), commit-prefix logic (L1287-L1330).
- `src/arch/moonshine_streaming/weights.{h,cpp}`: tensor catalogue and GGUF keys.
- `scripts/convert-moonshine_streaming.py`: the HF-to-GGUF name table and the `+1` fold.
- `scripts/dump_reference_moonshine_streaming_transformers.py`: reference tensor dumps.
- `tests/moonshine_streaming_stream_parity.cpp`, `tests/tolerances/moonshine_streaming.json`
  (per-tensor tolerances; for tiny, final logits differ from HF by at most 1.8e-3).
- `docs/porting/families/moonshine_streaming.md`, `reports/porting/moonshine_streaming/forward-map.md`.

Where we differ from it on purpose: our frontend is incremental with conv histories (theirs
re-runs it over retained PCM with 4 frames of slack); we verify the previous hypothesis instead
of greedy-decoding from BOS every tick; we commit per VAD line; we zero the trailing partial
frame at finalize (they only pad it, a tiny mismatch with HF).

**CrispASR** (`CrispStrobe/CrispASR` @ `301acd8`, MIT): `src/moonshine_streaming.cpp`
(`audio_frontend_cpu` L466 runs the frontend on the host, `run_encoder` L595),
`models/convert-moonshine-streaming-to-gguf.py`, `tools/reference_backends/moonshine_streaming.py`.

**Official runtime** (`moonshine-ai/moonshine` @ `234f60f`, MIT, ONNX Runtime):
`core/moonshine-streaming-model.cpp`, with `process_audio_chunk` (L641: frontend state of a
79-sample buffer and `[d,4]` / `[c1,4]` conv buffers), `encode` (L818: windowed encoder,
`total_lookahead=16`, left context `16*depth`), `decode_full` (L1407: speculative verification);
`core/transcriber.cpp` `transcribe_segment_with_streaming_model` (about L1340: VAD lines, 1280-sample
chunks, token cap); defaults in `core/transcriber.h` (about L182-L196).

**Reference model code:** transformers
`src/transformers/models/moonshine_streaming/modeling_moonshine_streaming.py` (v5.7 or later).

---

## 8. Reference numbers

The reference is HF transformers. The official `moonshine-voice` pip package runs ONNX exports
and does not expose tensors; it is only useful as an end-to-end transcript check
(`moonshine-voice mic --language en`).

**Environment:** Python 3.11+, `transformers>=5.7,<6`, `torch` (CPU build), `soundfile`, `numpy`.
Torch and the checkpoint are large (small is 561 MB), so run this on cuda-box or wherever disk
allows, and copy the `.npy` files back.

**Audio:** `jfk.wav` from whisper.cpp (`https://github.com/ggml-org/whisper.cpp/raw/master/samples/jfk.wav`),
16-bit mono 16 kHz, 176,000 samples (11.0 s, exactly 550 encoder frames), sha256
`59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.

```python
import json, numpy as np, soundfile as sf, torch
from transformers import AutoProcessor, MoonshineStreamingForConditionalGeneration

M, REV = "moonshine-ai/moonshine-streaming-small", "2c036506f23a09c18df5a50057599ba6d9280999"
proc  = AutoProcessor.from_pretrained(M, revision=REV)
model = MoonshineStreamingForConditionalGeneration.from_pretrained(
            M, revision=REV, attn_implementation="eager").float().eval()
torch.set_num_threads(1)  # deterministic reductions

pcm, sr = sf.read("jfk.wav", dtype="float32")          # int16 / 32768
assert sr == 16000 and pcm.ndim == 1 and len(pcm) % 320 == 0

def inputs(x):
    # attention_mask is REQUIRED: without it the encoder skips the sliding windows
    return proc(x, sampling_rate=16000, return_tensors="pt", return_attention_mask=True)

taps = {}
def tap(name):
    def f(mod, args, out):
        taps[name] = (out[0] if isinstance(out, tuple) else out)[0].detach().numpy().copy()
    return f
enc = model.model.encoder
enc.embedder.cmvn.register_forward_hook(tap("cmvn"))      # [T*4, 80]
enc.embedder.linear.register_forward_hook(tap("linear"))  # PRE-SiLU
enc.embedder.register_forward_hook(tap("features"))       # post-conv2, [T, De]
for i, layer in enumerate(enc.layers):
    layer.register_forward_hook(tap(f"layer{i}"))

def encode(x):
    inp = inputs(x)
    with torch.inference_mode():
        return enc(inp.input_values, attention_mask=inp.attention_mask).last_hidden_state[0].numpy()

enc_chunk0 = encode(pcm[:16000]); np.save("enc_chunk0.npy", enc_chunk0)   # first 1.0 s: [50, De]
for k, v in taps.items(): np.save(f"chunk0_{k}.npy", v)
enc_full = encode(pcm);           np.save("enc_full.npy", enc_full)       # [550, De]
# ergodicity: frames with all 12 right-context frames inside the chunk agree
assert np.abs(enc_chunk0[:38] - enc_full[:38]).max() < 1e-4

dec = model.model.decoder
with torch.inference_mode():
    h = torch.from_numpy(enc_full)[None].clone()         # clone: HF adds pos_emb IN PLACE
    m = dec.proj(h + dec.pos_emb(torch.arange(h.shape[1])))
    np.save("adapter_out.npy", m[0].numpy())
    np.save("cross_k0.npy", dec.layers[0].encoder_attn.k_proj(m)[0].numpy())

    inp = inputs(pcm)
    ids = model.generate(**inp, do_sample=False, num_beams=1,
                         max_length=int(len(pcm) * 6.5 / 16000))[0].tolist()
    step0 = model(input_values=inp.input_values, attention_mask=inp.attention_mask,
                  decoder_input_ids=torch.tensor([[1]])).logits[0, 0].numpy()
np.save("logits_step0.npy", step0)
json.dump({"ids": ids, "text": proc.decode(ids, skip_special_tokens=True),
           "step0_top5": np.argsort(-step0)[:5].tolist()}, open("tokens.json", "w"), indent=1)
```

`ids` starts with 1 and ends with 2. The expected text begins "And so my fellow Americans";
the exact string and ids come from the run (record them for tiny and small).

**Checks for our port:**

1. Frontend on `pcm[:16000]` equals `chunk0_features.npy`, fed as one call and as 50 single
   320-sample calls.
2. Encoder on the first 1.0 s, finalized, equals `enc_chunk0.npy`; streamed without finalize,
   the 38 committed frames equal `enc_full.npy[:38]`.
3. Streaming the whole file in 20, 80 and 320 ms pieces, the committed frames equal `enc_full.npy`
   and the finalized line gives exactly `ids`.
4. `adapter_out.npy`, `cross_k0.npy`, `logits_step0.npy` within about 1e-3 absolute at F32
   (transcribe.cpp's measured drift for tiny: `enc.final` 2.6e-4, `adapter.out` 2.7e-4, logits at
   step 20 1.8e-3).

---

## 9. Gotchas

1. **HF drops the windows without a mask.** `MoonshineStreamingEncoder.forward` builds the
   per-layer sliding-window masks only when `attention_mask` is passed; otherwise every layer
   attends to everything. Always pass it in reference runs.
2. **HF mutates the encoder output.** `MoonshineStreamingDecoder.forward` does
   `encoder_hidden_states += pos_emb` in place. Clone before reusing the tensor; apply our adapter
   exactly once per frame.
3. **Unit-offset LayerNorm in the encoder only.** Encoder gains are `gamma + 1`; decoder LN
   weights are used as stored. None of the LayerNorms has a bias.
4. **Exact GELU.** The encoder uses `gelu` (erf). `ggml_gelu` is the tanh approximation; use
   `ggml_gelu_erf`.
5. **SwiGLU half order.** `fc1` output `[value | gate]`, result `silu(gate) * value`, so
   `ggml_swiglu_swapped`. `fc1` and `fc2` have biases.
6. **RoPE is interleaved and partial.** `GGML_ROPE_TYPE_NORMAL`, `n_dims = 32` for every
   variant (0.8 x 40 in tiny, 0.5 x 64 in small and medium). NEOX mode or rotating the whole head
   gives wrong but plausible text.
7. **Non-square encoder attention** in small and medium (`A` = 512/640 against `De` = 620/768).
   Scale by `1/sqrt(hd)`.
8. **Right context is 12 frames, not 16.** The mask `-dist < R` gives `R-1` future frames. The
   paper, the model card ("80 ms") and the official runtime (`total_lookahead=16`) are
   conservative.
9. **`pos_emb` has 4096 rows.** A line cannot exceed 81.9 s; reset per VAD line (at most 15 s).
10. **The head is untied on paper but identical in fact.** Check equality of the full tensors in
    the converter before sharing one buffer between `get_rows` (embedding) and `mul_mat` (head).
    Both work on Q8_0.
11. **`ggml_conv_1d` casts the im2col to F16** when the kernel is not BF16. Call `ggml_im2col` with
    `GGML_TYPE_F32` for an F32 kernel (or F16 for an F16 kernel) and do the `ggml_mul_mat` yourself,
    kernel first, so the result comes out channels-innermost. Conv kernels (`ne0=5`) and
    `linear.weight` (`ne0=80`) cannot be Q8_0; keep them F16 or F32.
12. **Flash-attention masks must be F16 and contiguous** (asserted). `ggml_soft_max_ext` also
    accepts F32. Mask layout is `ne=[n_kv, n_q]`.
13. **Block phase.** Feed the frontend whole 320-sample blocks, or track the stride-2 phases. The
    official runtime notes that its older ONNX frontend graphs silently dropped samples when a chunk
    was not a multiple of 80.
14. **CMVN amplifies quiet frames.** Each 5 ms frame is scaled to unit variance, so background noise
    in a pause looks like signal; digital silence gives exact zeros. That is by design. Do not add
    dither, and gate the decoder with the VAD so it does not hallucinate on noise.
15. **Finalize padding.** HF pads to a multiple of 80 and zeroes the trailing partial frame (its
    padding mask floors the frame count). For parity: zero the partial frame, zero-pad to 320. Use
    test WAVs whose length is a multiple of 320 to sidestep this entirely.
16. **HF hooks see pre-activation outputs.** Hooks on `embedder.linear` and `embedder.conv1` capture
    values before SiLU, and `conv1` returns a tuple `(x, mask)`.
17. **Committed text can still change** under prefix-agreement commit (transcribe.cpp says so). Only
    a closed VAD line is final.
18. **The decoder is re-run every tick.** Any stored self K/V are stale once cross frames are
    added. Keep only the verified prefix of the current tick's batched pass, never the previous
    tick's.
19. **Encoder window edges.** In mode A, output columns within `Lt` of the window start are wrong
    unless the window starts at frame 0. Never emit them.
20. **Graph shapes change per tick** (`W`, `T_kv`, verify length). Build graphs per call and
    reserve buffers for the maxima once, or bucket the sizes.

---

## Summary

**Choice:** Moonshine Streaming Small (123 M, MIT code and weights, 7.84 % average Open ASR WER,
2.49 % LibriSpeech clean), with Moonshine Streaming Tiny (34 M, 12.01 %, 4.49 %) for WebAssembly
and Medium (245 M, 6.65 %) as the GPU upgrade on the same code.

**Files:** `moonshine-ai/moonshine-streaming-{tiny,small,medium}/model.safetensors`, all F32:
176.2 MB, 560.6 MB, 1063.6 MB (the head duplicates the embedding, so 33.6 / 123.4 / 244.9 M unique
values). `tokenizer.json` is 1.68 MB and shared. Ready GGUFs from `handy-computer`: Q8_0 50.5 /
198.5 / 295.8 MB; our deduplicated Q8_0 would be about 36 / 131 / 260 MB.

**Architecture:** raw 16 kHz PCM is cut into 5 ms frames, each normalised on its own (CMVN),
compressed with `asinh(k x)`, projected to the encoder width with SiLU, then two causal stride-2
convolutions bring it to 50 Hz. The encoder is a pre-norm transformer with no positional encoding
and per-layer sliding windows (15 past frames, plus 3 future frames in the first two and last
two layers), so each 20 ms frame is final after 240 ms of lookahead. An adapter adds a learned
absolute position table (and projects to the decoder width in small and medium). A pre-norm
decoder with partial interleaved RoPE, cross-attention and SwiGLU re-decodes the current VAD
line each tick, verifying the previous hypothesis in one batched pass. Greedy decoding stops at
EOS or 6.5 tokens per second, and a line is committed when the VAD closes it.

**ggml ops:** `ggml_norm`, `ggml_mul`, `ggml_add`, `ggml_scale`, `ggml_scale_bias`, `ggml_sqr`,
`ggml_sqrt`, `ggml_abs`, `ggml_sgn`, `ggml_log` (for asinh, the only missing op), `ggml_mul_mat`,
`ggml_silu`, `ggml_gelu_erf`, `ggml_concat`, `ggml_transpose`/`ggml_cont`/`ggml_permute`/reshape
and views, `ggml_im2col`, `ggml_flash_attn_ext` (or `ggml_soft_max_ext`), `ggml_get_rows`,
`ggml_rope_ext`, `ggml_swiglu_swapped`, `ggml_cpy`/`ggml_set_rows`, `ggml_cast`, `ggml_argmax`.

---

## Port

Done 2026-09-10: Small, then Tiny. The files are `console/ml/moonshine.lua` (the model),
`console/ml/convert/moonshine.lua` (the converter) and `test/ml_moonshine_test.lua`. The engine
gained one op, `swiglu_swapped`, and one tokenizer mode, `"moonshine"` in `native/tok.c`. That mode
is the gemma4 BPE with `add_space_prefix` honoured; only decoding is used, but encoding the
reference text gives the reference ids.

    luajit console/ml/convert/moonshine.lua <checkpoint dir> console/ml/models/moonshine-streaming-small-f32.gguf f32

The converter reads the Hugging Face directory (`config.json`, `tokenizer.json`,
`model.safetensors`). It writes transcribe.cpp's names and keys, folds the encoder gains (+1), and
stores the head once, because `proj_out` equals `embed_tokens` bit for bit in both checkpoints.
`f16` halves the matrices. `q8_0` quantizes the matrices whose rows are whole blocks: in Small the
620-wide encoder inputs and `fc2` stay f16. File sizes: Small f32 495 MB, f16 249 MB, q8_0 181 MB;
Tiny f32 136 MB. `ml.json` writes a UTF-16 surrogate pair as two three-byte sequences, and
`tokenizer.json` has some; the converter joins them.

**Where it differs from section 3.5.** The encoder is mode B from the start. Each layer keeps its
last `15 + r_i` input frames in a set, and one graph per push runs the frontend, each layer over
the frames that became final, the adapter, and the cross K/V writes. The masks are built on the
host and shared between layers that have the same one. They are keyed on the absolute position
while a window still reaches back before frame 0: sharing them by relative offset alone corrupted
the first frames of the lookahead layers when streaming (0.8 off), and whole-clip runs never showed
it. `asinh` is composed from ops; the frontend matches to 2e-5, so it needs no native op. Pushed
audio waits until `every` (0.24 s) is pending, then goes through one encoder graph and one decode,
because on Metal a graph costs 2.5–7 ms whatever its size. The decode is the speculative one:
one batched pass checks the last text, the self K/V of the agreeing prefix are kept, and greedy
decoding continues from there. The budget is HF's `int(n * 6.5 / 16000)`, counting the start
token. A loop guard, found in no reference, cuts a 3–10 token n-gram repeated three times back to
one copy and stops. The caches are f32 unless `cache = "f16"`, and hold a 30 s line unless
`seconds` says otherwise.

**What was checked.** The reference is transformers 5.17.0 (torch 2.12.1, eager attention, f32,
one thread) on jfk.wav. It gives the frontend output, the encoder output, the adapter output,
layer 0's cross K, the logits of every step with the transcript fed back, and the greedy ids.
The table gives the largest absolute difference over every element.

| | features | encoder | adapter | cross K 0 | logits |
|---|---|---|---|---|---|
| Small, CPU, f32 | 2.1e-5 | 4.6e-5 | 9.4e-5 | 1.6e-4 | 3.2e-5 |
| Tiny, CPU, f32 | 8.8e-6 | 5.0e-5 | 5.0e-5 | 9.5e-5 | 6.4e-5 |
| Small, Metal, f32 or f16 weights | 1.0e-3 | 1.9e-2 | 3.6e-2 | 7.6e-2 | 2.6e-2 |
| Tiny, Metal, f32 | 1.1e-3 | 6.2e-2 | 6.2e-2 | 0.16 | 6.0e-2 |
| Small, CPU, f16 / q8_0 | 2.8e-3 / 2.8e-3 | 5.5e-2 / 0.24 | 0.12 / 0.47 | 0.23 / 0.64 | 4.5e-2 / 0.24 |

Metal's matrix kernel rounds its tiles to f16, so f32 and f16 weights give the same numbers
there. The transcript equals HF's ids in every row: Small gives "And so my fellow Americans, ask
not what your country can do for you, ask what you can do for your country." and Tiny gives "And
so, my fellow Americans, ...". The clip was also pushed in 20, 80, 130, 160, 320 and 1000 ms
pieces. In every case the committed encoder frames stay within 5e-5 of the whole clip's (about
1e-5; batch shapes round differently) and the ids come out the same. A clip cut to 171,234
samples, not a whole block, ends the same pushed or whole. The test's tolerances, at sampled
points and on each tensor's rms and mean, are:

- CPU: features 5e-5, encoder 1e-4, adapter 2e-4, cross K 5e-4, logits 2e-4.
- Device: 5e-3, 0.1, 0.1, 0.3 and 0.15 in the same order.
- Streamed against whole: 5e-5.

The test passes on LuaJIT and Lua 5.5 (6 tests, about 15 s).

**Speed.** The clip is jfk.wav, 11.0 s. The runs used LuaJIT on an Apple M4 (4 performance and 6
efficiency cores), timed wall-clock with `ml.now()`, taking the median of 3. Other agents' builds
shared the machine, so a figure can move by about 30%. "Stream" pushes 160 ms pieces with
`every = 0.24`, and its time covers all pushes plus `finish`. "Finish" is how long `finish()` takes
after the last push, which is the latency from the end of speech (the caller closing the line) to
the final text. The slowest single push was 20–90 ms.

| model | device | whole clip | RTF | stream | RTF | finish |
|---|---|---|---|---|---|---|
| Small f32 | CPU, 8 threads | 0.55 s | 0.050 | 1.26 s | 0.115 | 40 ms |
| Small f16 | CPU, 8 threads | 0.33 s | 0.030 | 0.81 s | 0.074 | 27 ms |
| Small q8_0 | CPU, 8 threads | 0.30 s | 0.028 | 0.69 s | 0.063 | 23 ms |
| Small f32 | Metal | 0.18 s | 0.017 | 0.97 s | 0.088 | 16 ms |
| Small f16 | Metal | 0.18 s | 0.016 | 0.79 s | 0.072 | 15 ms |
| Small q8_0 | Metal | 0.14 s | 0.013 | 0.99 s | 0.090 | 17 ms |
| Tiny f32 | CPU, 8 threads | 0.13 s | 0.012 | 0.39 s | 0.036 | 13 ms |
| Tiny f32 | Metal | 0.09 s | 0.008 | 0.82 s | 0.075 | 11 ms |
| Tiny f32 | WASM (node, SIMD), 1 thread | 0.57 s | 0.052 | 1.21 s | 0.110 | 53 ms |
| Tiny f32 | WASM, 4 threads | 0.30 s | 0.027 | 0.55 s | 0.050 | 19 ms |

With 4 CPU threads everything takes about a third longer. On the CPU a single-token decoder step
is bound by memory bandwidth: F32 reads 0.5 GB of weights per token, about 3.8 ms. On Metal a
step costs 2.5–5 ms, which is mostly the fixed cost of a graph, so streaming there is dominated by
the roughly 46 decodes rather than the encoder. Small in WASM runs at RTF 1.1 (q8_0, one thread),
because the f16 and q8_0 kernels there are slow; Tiny f32 is the WASM model. The partial text
trails the audio by the 240 ms lookahead, plus up to `every`, plus one decode.

**What remains.**

- Medium: not converted or run. It is the same code.
- The provisional tail (3.5) is not built, so the partial text waits the full 240 ms.
- There is no VAD. A stream is one line: the caller calls `finish()` at a pause and starts
  another stream, and a line longer than `seconds` raises. The 15 s cut is not done.
- Graphs are rebuilt for every decoder token. Reusing them (positions written with `set_rows`, a
  padded KV length) would remove most of Metal's per-step cost.
- There is no stable-prefix hint for display, and no word times.
