# Pocket TTS on ggml — implementation spec

Researched 2026-09-10. Ground truth is the official Python package, `github.com/kyutai-labs/pocket-tts`
at commit `0c2db3bdea7c991c568989cc11b503f14483fabc` (package version 3.1.0). Every source file
named below was read at that commit. The weight layout was read from the safetensors headers over
HTTP range requests; nothing larger than 50 MB was downloaded.

What was checked by computation, not just by reading:

- **Tokenizer.** The token ids in §3 come from the real `tokenizer.model` run through `sentencepiece`.
- **FlowLM layer 0.** The published `alba` voice state holds layer 0's K and V at position 0. I
  recomputed them from the weights (LayerNorm eps 1e-5, then the K and V rows of `in_proj`, no rotation
  at position 0) and they match to every printed digit. That pins the q|k|v packing, the LayerNorm, and
  where the voice BOS sits in the sequence (§13.1).
- **Mimi decoder.** I ran the official Mimi decoder modules on a synthetic latent, with the real decoder
  weights (20.6 MB fetched by range request). The outputs are the test vectors in §13.2. The same run
  shows that decoding frame by frame and decoding all frames at once agree to 2e-7, and that the
  250-step attention window changes the output from about frame 16 onward.

The full text-to-audio reference was not run here, because it needs the 219 MB checkpoint. §13.3 is the
script that produces those numbers.

The community ports can serve as cross-checks:

- candle: `babybirdprd/pocket-tts`. It agrees on the variance-based "RMSNorm" (§6).
- ONNX: `KevinAHM/pocket-tts-onnx-export`, `VolgaGerm/PocketTTS.cpp`, sherpa-onnx.
- MLX: `jishnuvenugopal/pocket-tts-mlx`.
- jax-js: `ekzhang/jax-js`.
- XN: the repo has moved to `gradium-ai/xn` and no longer contains the pocket-tts crate.

Where a port and the Python source disagree, the Python source wins.

Notation: torch shapes are written `[a, b, c]` (row-major, last index fastest). ggml shapes are
written `ne=(ne0, ne1, ...)` (ne0 fastest). **A torch tensor `[a, b, c]` is ggml `ne=(c, b, a)`
with the same bytes**, so every weight loads without transposition unless a step below says so.

---

## 1. Licences, files, gating

### Licences

- **Code:** MIT. The repo's `LICENSE` is the MIT permission text.
- **Weights:** CC-BY-4.0, from the HF model-card metadata of both repos. The card and README add a
  prohibited-use clause: no voice cloning without consent, no deception or impersonation, nothing
  unlawful or harmful.
- **Voices:** the predefined voice states are derived from recordings under their own licences
  (`huggingface.co/kyutai/tts-voices` README). Most are CC0 or CC-BY-4.0:
  - alba (Alba MacKenna): CC-BY-4.0.
  - VCTK voices (anna, vera, fantine, charles, paul, eponine, azelma, george, mary, jane, michael,
    eve): CC-BY-4.0.
  - Voice donations (marius, javert) and voice-zero (bill_boerst, peter_yearsley, stuart_bell,
    caro_davy): CC0.

  Two are **non-commercial**: `cosette` (Expresso, CC-BY-NC-4.0) and `jean` (EARS, CC-BY-NC-4.0).
  Treat their embeddings as NC.

### Gating

| Repo | Gated | What differs |
|---|---|---|
| `kyutai/pocket-tts` | yes, `gated: auto`: log in and accept the terms (company field, purpose). Access is granted automatically. Anonymous range requests return 401. | full weights |
| `kyutai/pocket-tts-without-voice-cloning` | **no** | Identical files, except every tensor whose name starts with `mimi.encoder` (the SEANet encoder **and** `mimi.encoder_transformer`) is **zeroed**. Predefined voices work; cloning from audio does not. |

The Python loader tries the gated file first and falls back to the ungated one on any error. A port
that only ships predefined voices needs **only the ungated repo**, and does not need the encoder
tensors at all.

### Files for the default model

The default model is "english", which is the same model as "english_2026-04": same config, same
sha256.

Base URL, ungated and pinned: `https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/e81d79e8194ad4c7ce879c87a4258ef20cbf2487/`

| File | Bytes | dtype | sha256 |
|---|---|---|---|
| `languages/english/model.safetensors` | 219,029,196 | all BF16, 214 tensors, JSON header 24,896 bytes, no `__metadata__` | `be9c6b4876d3f30740a8225dfcaa2e43dc4aeb753c15272735bee16bbb4abb0a` |
| `languages/english/tokenizer.model` | 59,339 | SentencePiece protobuf | `d461765ae179566678c93091c5fa6f2984c31bbe990bf1aa62d92c64d91bc3f6` |
| `languages/english/embeddings/<voice>.safetensors` | 3.7–8.3 MB each, 26 voices | F32 KV caches plus I64 offsets (§4.1) | e.g. `alba` 6,194,424 bytes, `69c32db63ca56843d994f81f343f62e0bf2d73f7e4c9bc73e44bb1110b1d8845` |

- The gated equivalent is `https://huggingface.co/kyutai/pocket-tts/resolve/main/languages/english/model.safetensors`.
  The config pins revision `39592ff23c9ef80098bb74895d104c26275fe2c9`. It has the same size, and
  its encoder tensors are real.
- The config pins the ungated files at revision `d29db7978e464fb90cb3359ee0c69a273b9142cc`. Those
  files have the same sha256 as at `e81d79e`.
- The 26 English voices are: alba, anna, azelma, bill_boerst, caro_davy, charles, cosette, eponine,
  estelle, eve, fantine, george, giovanni, jane, javert, jean, juergen, lola, marius, mary, michael,
  paul, peter_yearsley, rafael, stuart_bell, vera.

Parameter count (english): **109,502,146**.

| Part | Params | Detail |
|---|---|---|
| FlowLM | 89,447,809 | transformer 75,522,048; text LUT 4,097,024; flow head 9,759,008; the rest is small |
| Mimi decoder side | 10,305,313 | SEANet decoder 3,974,945; decoder transformer 6,297,600; quantizer proj 16,384; upsample 16,384 |
| Mimi encoder side (voice cloning only) | 9,749,024 | SEANet encoder 2,927,136; encoder transformer 6,297,600; downsample 524,288 |

Runtime without cloning is about 99.8M params: 399 MB as F32, 200 MB as BF16.

### Other checkpoints in the same repos (not the default)

All of these share the architecture below unless noted.

- **`english_2026-01`** (`languages/english_2026-01/model.safetensors` and the legacy
  `tts_b6369a24.safetensors`, 235,738,732 bytes each):
  - `inner_dim 512`, so `mimi.downsample.conv.conv.weight` is `[512,512,32]` and
    `flow_lm.speaker_proj_weight` is `[1024,512]`.
  - No `flow_lm.bos_before_voice`.
  - `pad_with_spaces_for_short_inputs: true`, and default temperature 0.7.
  - Its voice states are the root `embeddings_v3/*.safetensors`: 125 positions, no BOS. The root
    `embeddings/*.safetensors` are an even older format, `audio_prompt` `[1,125,1024]`.
- **german, italian, portuguese, spanish:** 6-layer models with identical shapes and their own
  tokenizers (~60 KB, 4000 pieces). German uses `remove_semicolons`.
- **24-layer variants** (`*_24l`, 672 MB; `english_2026-04_24l` is 1.3 GB):
  - `num_layers: 24`.
  - **`english_2026-04_24l` mixes dtypes.** Its flow_lm tensors are F32 and its mimi tensors are
    BF16, so a loader must honour the dtype of each tensor.
  - `french_24l` sets `model_recommended_frames_after_eos: 8`.

---

## 2. Pipeline and constants

```
text ─► prepare_text_prompt ─► split into ≤50-token chunks ─► per chunk:
   SentencePiece ids [N] ─► LUT embed [N,1024]
voice state (KV cache of [bos_before_voice ; 125 voice frames]) ─┐
                                                                  ▼
FlowLM transformer (6 layers, causal, KV cache) over text tokens (prompt pass, output discarded)
then autoregressive, one frame per step:
   input latent (BOS on step 0) ─► input_linear ─► transformer ─► out_norm ─► h[1024]
      h ─► out_eos ─► logit > -4 ? EOS
      h ─► flow head (1 LSD step from noise ~ N(0, temp)) ─► latent[32] (normalised space)
      latent is both the next step's input and the Mimi input (after ×emb_std + emb_mean)
Mimi decoder, per latent frame:
   1x1 conv 32→512 ─► depthwise ConvTranspose ×16 (12.5 Hz → 200 Hz) ─► 2-layer transformer
   (window 250) ─► SEANet decoder (conv7, 3× [ELU, ConvTr, ResBlock], ELU, conv3) ─► 1920 samples
```

| Constant | Value |
|---|---|
| Sample rate | 24,000 Hz, mono, float32 output (not clipped) |
| Latent frame rate | 12.5 Hz, **1920 samples (80 ms) per frame** |
| Mimi inner rate | 200 Hz: 16 transformer steps per frame, SEANet hop 120 = 6·5·4 |
| Latent dim | 32 |
| FlowLM | d_model 1024, 6 layers, 16 heads × 64, FFN 4096 (GELU-tanh), pre-LayerNorm eps 1e-5 with bias, no bias on any attention/FFN linear, no LayerScale, full causal attention, RoPE base 10000 on all 64 dims, interleaved pairs |
| Text LUT | `nn.Embedding(4001, 1024)`: 4000 SentencePiece ids plus a padding row 4000 that is never used at inference |
| Flow head | SimpleMLPAdaLN: width 512, 6 AdaLN residual blocks, 2 timestep embedders, condition 1024→512 |
| Sampler | LSD, **1 step** by default, noise std = sqrt(temperature), **temperature 0.3** (english config), no clamp |
| EOS | `Linear(1024→1)` on the out_norm output; EOS when **logit > −4.0** |
| Mimi decoder transformer | d 512, 2 layers, 8 heads × 64, FFN 2048 (GELU-tanh), LayerScale, LayerNorm eps 1e-5, RoPE base 10000, **causal window 250 steps** (1.25 s at 200 Hz) |
| SEANet decoder channels | 512 → 512 → 256 → 128 → 64 → 1 |
| Max tokens per chunk | 50 |

The paper is CALM, arXiv 2509.06926. LSD is "Lagrangian Self-Distillation", arXiv 2505.18825, a
flow-map (consistency-style) model. It is trained so that one step from pure noise lands on a
sample.

---

## 3. Text front end

### 3.1 `prepare_text_prompt(text)` (`models/text_chunking.py`)

The English config sets `pad_with_spaces_for_short_inputs=False`, `remove_semicolons=False` and
`append_terminal_punctuation=True`.

1. Apply `strip()`. Empty input is an error.
2. Replace `"\n"` with `" "`, then `"\r"` with `" "`, then `"  "` with `" "`. **Each is a single
   non-overlapping pass:** 4 spaces become 2 and 3 spaces become 2. (The chunker re-runs this step,
   so runs collapse further; see the table.)
3. If `remove_semicolons`, replace `;` with `,`.
4. Set `frames_after_eos_guess` to 3 if `len(text.split()) <= 4`, else 1. **Add 2 later**, so the
   final value is 5 or 3, unless the config sets `model_recommended_frames_after_eos`.
5. If `not text[0].isupper()`, then `text = text[0].upper() + text[1:]`.
6. Ensure terminal punctuation:
   - Let `core = text.rstrip('"\'”’)]» ')` and `closers = text[len(core):].strip()`.
   - If `core` is empty or ends in one of `. ! ? …`, keep the text.
   - Else if it ends in one of `, ; : - – —`, the result is `core.rstrip(",;:-–— ") + "." + closers`.
   - Otherwise append `"."`.
7. If padding is on and the text has fewer than 5 words, prefix 8 spaces. This is off for English.

No other normalisation is done: numbers, abbreviations and Unicode are passed through untouched.
The model reads digits one by one, because the tokenizer splits them.

### 3.2 Chunking (`split_into_best_sentences`, max_tokens 50)

1. Run `prepare_text_prompt` on the whole text, then `strip()`, then tokenize.
2. The end-of-sentence ids are the ids of `".!...?"` after dropping the first token (`▁`). For the
   English tokenizer these are `{263 '.', 682 '!', 799 '...', 292 '?'}`.
3. A boundary goes before the first non-EOS token that follows one or more EOS tokens. The exception
   is a decimal point: skip the boundary if `decode(prefix)` ends in digit + `.` and `decode(suffix)`
   starts with a digit.
4. Decode each segment back to text.
5. Any segment over 50 tokens is re-tokenized and split after runs of `,`, `;`, `:`. For English
   these are ids `{262, 1230, 3244}`, taken the same way, from `",;:"` minus the first token.
6. Greedily pack segments into chunks of at most 50 tokens, joining them with a space.
7. Run `prepare_text_prompt` again on each chunk. That second pass supplies the chunk's
   `frames_after_eos`.
8. **Each chunk is generated independently.** It starts from a fresh copy of the voice state and a
   fresh Mimi state, and the audio chunks are concatenated.

### 3.3 Tokenizer

The tokenizer is SentencePiece **unigram** (`model_type=1`):

- 4000 pieces: 3740 normal, 256 byte pieces, 3 control, 1 unknown.
- Special ids: `<unk>`=0, `<s>`=1, `</s>`=2, `<pad>`=3, then `<0x00>`..`<0xFF>` = ids 4..259.
- **No BOS or EOS is added.**
- Normaliser `identity`, with an empty charsmap, so there is no NFKC.
- `add_dummy_prefix=true`, `remove_extra_whitespaces=false`, `escape_whitespaces=true`.
- `byte_fallback=true`, `split_digits=true`, `allow_whitespace_only_pieces=true`, max piece length 6.
- Piece scores (log-probabilities) range from −13.87 to −2.88.

A port must implement the unigram Viterbi exactly:

1. Prepend `▁` (U+2581) and replace every space with `▁`. Runs of spaces stay runs: `"  A"` becomes
   `▁▁▁A`, which tokenizes as `[▁, ▁, ▁A]`.
2. Build the lattice over Unicode code points. Maximise the sum of piece scores among pieces of up
   to 6 code points that exist in the vocab, whether normal or `▁`-only.
3. A code point that no piece covers becomes `<unk>`, with score `min_score − 10` as in
   `unigram_model.cc`. Byte fallback then replaces it with the byte pieces of its UTF-8 encoding.
4. No multi-digit pieces exist, so digits come out one per token.

llama.cpp's UGM tokenizer (MIT) is a working C++ reference. Another option is to link `libsentencepiece`
(Apache-2.0).

Verified ids, from the real model file and the real chunking and prepare code:

| Input to `generate` | Prepared chunk | frames_after_eos | ids |
|---|---|---|---|
| `Hello world, this is a test.` | same | 3 | `[2994, 578, 262, 285, 277, 267, 1115, 263]` (`▁Hello ▁world , ▁this ▁is ▁a ▁test .`) |
| `hello world` | `Hello world.` | 5 | `[2994, 578, 263]` |
| `It costs $3.50 today` | `It costs $3.50 today.` | 5 | `[333, 1649, 261, 1124, 450, 263, 437, 316, 630, 263]` (the `.` in `3.50` is id 263 but is not a boundary) |
| `Café naïve – 2026年` | `Café naïve – 2026年.` | 5 | `[1130, 601, 745, 913, 199, 179, 314, 260, 3977, 260, 365, 316, 365, 543, 233, 189, 184, 263]` (`ï` and `年` go to byte pieces) |
| `a    b   c` | `A  b  c.` | 5 | `[383, 260, 557, 260, 331, 263]` (corrected from the package itself: the single pass leaves two spaces, and a lone `▁` is id 260) |
| `He said "hi"` | `He said "hi".` | 5 | `[414, 425, 694, 1449, 3877, 263]` |
| default English text (4 sentences) | one chunk | 3 | 41 ids, starting `[2994, 578, 263, 268, 686, 862, 327, 805, 1537, 264, 261, 1456, …]` and ending `…, 335, 282, 308, 263]` |

The last row is the default text: "Hello world. I am Kyutai's Pocket TTS. I'm fast enough to run on
small CPUs. I hope you'll like me."

---

## 4. Voice conditioning

The voice lives **only in the FlowLM KV cache**. The first transformer positions hold a voice
prompt: one learned `bos_before_voice` vector followed by F speaker-projected Mimi latents. Generation
then continues from that cache. There is no separate speaker embedding anywhere else.

### 4.1 Predefined voice states (no encoder needed)

`languages/english/embeddings/alba.safetensors` holds 12 tensors. For each layer l in 0..5:

- `transformer.layers.{l}.self_attn/cache`: F32 `[2, 1, 126, 16, 64]`. Index 0 is K and index 1 is V.
  Batch is 1; then positions, heads, head_dim. **K is stored after RoPE.**
- `transformer.layers.{l}.self_attn/offset`: I64 `[1]`, value **126**. That is 1 BOS plus 125 frames
  (10 s).

The key format is `<module path relative to flow_lm>/<state key>`. The tensor is 5-D, which is more
than ggml's `GGML_MAX_DIMS=4`. Split it at load: K is the first 126·16·64 floats, V is the next 126·16·64.

In memory, `[126,16,64]` row-major equals ggml `ne=(64,16,126)`, so each half is a single `memcpy`
into the KV cache at positions 0..125. The number of positions varies by voice: it is
(file size − header) / 49,152 bytes, e.g. about 162 for azelma. **Read it from `offset`.**

Legacy detail: `_import_model_state` maps an old `current_end` key to `offset = shape[0]`. The
English files use `offset`.

### 4.2 Voice cloning from audio (needs the gated weights)

`TTSModel.get_state_for_audio_prompt(path)` does the following:

1. Read the audio, average to mono, and resample to 24 kHz with `scipy.signal.resample_poly`. Any
   good resampler is fine. The `export-voice` CLI truncates to 30 s; the Python API only does so when
   `truncate=True`.
2. `encode_to_latent`:
   - Right-pad with zeros to a multiple of 1920.
   - Run the SEANet encoder (§8.5), then the encoder transformer over the whole prompt at 200 Hz
     (causal, window 250), then the downsample conv. The result is `[F, 32]` at 12.5 Hz.
3. `cond = latents @ speaker_proj_weight.T` gives `[F, 1024]`. The latents are raw encoder output,
   **not** normalised with emb_mean/std.
4. Prepend `bos_before_voice` (`[1,1,1024]`) to get `[F+1, 1024]`.
5. Run the FlowLM transformer on these F+1 vectors from an empty cache, at positions 0..F. Keep the
   caches, and set offset = F+1.

The Python code also runs out_norm, EOS and the flow head on this pass and discards the result. That
only matters because it consumes one random draw (§13.3).

---

## 5. FlowLM transformer (`models/flow_lm.py`, `modules/transformer.py`, `modules/attention.py`, `modules/rope.py`)

The input sequence is the concatenation of whatever this call feeds:

- **text:** `embed.weight[ids]`, `[N,1024]`. There is no scaling or projection; the LUT dim equals
  d_model.
- **voice:** as in §4.2.
- **latent:** `input_linear.weight @ latent`, `[1024]`, no bias. The step-0 BOS latent is NaN in
  Python and is replaced by `bos_emb` (`[32]`) before `input_linear`. The fed latent is in
  **normalised** space: the flow head's raw output, not ×std+mean.

Each layer is pre-norm:

```
h  = LayerNorm(x; norm1.weight, norm1.bias, eps=1e-5)
qkv = h @ in_proj.weight.T                       # [T, 3072]; view as [T, 3, 16, 64] -> q | k | v
q,k = RoPE(q, k, positions = offset + 0..T-1)    # interleaved pairs (see below)
append k, v to cache at [offset, offset+T)
a  = softmax(q k_allᵀ / 8 + mask) v_all          # scale 1/sqrt(64), mask: key_pos <= query_pos
x  = x + (a reshaped [T,1024]) @ out_proj.weight.T
h  = LayerNorm(x; norm2.*, eps=1e-5)
x  = x + (gelu_tanh(h @ linear1.weight.T)) @ linear2.weight.T
```

After the 6 layers comes `out_norm` (LayerNorm 1024, eps 1e-5, affine). Only the **last position** is
used: `h_last` feeds the EOS head and the flow head.

RoPE (`apply_rope`):

- `freqs[i] = exp(−ln(10000)·2i/64)` for i in 0..31.
- The angle is `(offset + t)·freqs[i]`, computed in float32.
- Each pair `(x[2i], x[2i+1])` is rotated as a complex number:
  `(r·cos − im·sin, r·sin + im·cos)`.

This is ggml `GGML_ROPE_TYPE_NORMAL` (mode 0), **not NEOX**. Positions are absolute. Text starts
at `offset = 126` for alba.

The offset advances by the number of vectors fed: tokens, latents or voice frames. That makes it
126 after the voice, 126+N after the text, and 126+N+k after k latents.

---

## 6. Flow head and LSD sampler (`modules/mlp.py`, `lsd_decode`)

Inputs: `c = h_last` `[1024]`, and noise `x0 ~ N(0, temp)`, shape `[32]`, where
`std = temp**0.5` (0.5477 at temp 0.3). If `noise_clamp` is set, use a truncated normal on
`[−clamp, clamp]`; the default is no clamp.

**LSD decode with n steps.** The default is n = 1:

```
x = x0
for i in 0..n-1:  s = i/n;  t = (i+1)/n;  x = x + v(c, s, t, x) / n
latent = x            # n = 1  ->  latent = x0 + v(c, 0, 1, x0)
```

**v(c, s, t, x):**

```
y  = cond_embed.weight @ c + cond_embed.bias                     # [512]
y  = y + (TE0(s) + TE1(t)) / 2                                   # two timestep embedders
sy = silu(y)                                                     # every adaLN applies SiLU first
x  = input_proj.weight @ x + input_proj.bias                     # [32] -> [512]
for b in res_blocks[0..5]:
    m = b.adaLN_modulation.1.weight @ sy + b.adaLN_modulation.1.bias   # [1536]
    shift, scale, gate = m[0:512], m[512:1024], m[1024:1536]
    u = LayerNorm(x; b.in_ln.weight, b.in_ln.bias, eps=1e-6)           # biased variance
    u = u * (1 + scale) + shift
    u = b.mlp.2.weight @ silu(b.mlp.0.weight @ u + b.mlp.0.bias) + b.mlp.2.bias
    x = x + gate * u
m = final_layer.adaLN_modulation.1.weight @ sy + final_layer.adaLN_modulation.1.bias   # [1024]
shift, scale = m[0:512], m[512:1024]
u = LayerNorm(x; no affine, eps=1e-6) * (1 + scale) + shift
v = final_layer.linear.weight @ u + final_layer.linear.bias      # [32]
```

**TEk(τ)** is `time_embed.{k}`, with k=0 for s and k=1 for t:

```
args = τ * freqs_k          # freqs_k = time_embed.{k}.freqs from the FILE, [128] (BF16-rounded!)
e    = [cos(args), sin(args)]                  # [256], cos first
h    = mlp.2.weight @ silu(mlp.0.weight @ e + mlp.0.bias) + mlp.2.bias      # [512]
h    = h * alpha / sqrt(var_unbiased(h) + 1e-5)      # "RMSNorm": see below
```

This "RMSNorm" is **not** RMS. It is `x.var(dim=-1)`, torch's default **unbiased** variance: mean
subtracted, divided by N−1 = 511. It is multiplied onto the **un-centred** `h`, and `alpha` is
`mlp.3.alpha`. The candle port confirms this reading.

With one step, `s = 0` and `t = 1` are constants. So `tconst = (TE0(0) + TE1(1)) / 2` is a fixed
512-vector. **Compute it once at load time**, on the host in f32 or f64. It is then just added to
`y`. Note that TE0(0) uses `e = [1]*128 + [0]*128`.

---

## 7. Generation loop and end of speech (`models/tts_model.py`)

For each chunk:

```
state   = deep copy of the voice state (KV caches, offset P0)
ids     = tokenize(prepared chunk);  N = len(ids)
max_gen = ceil((N / 3 + 2) * 12.5)                      # _estimate_max_gen_len
fae     = config.model_recommended_frames_after_eos ?? (guess + 2)   # 3 or 5 for English
prompt pass: run FlowLM on the N text embeddings (positions P0..P0+N-1); ignore its outputs
x = BOS
for step in 0..max_gen-1:
    h = FlowLM(x at position P0+N+step); logit = out_eos.weight · h + out_eos.bias
    latent = x0 + v(h, 0, 1, x0),  x0 ~ N(0, temp)
    if logit > -4.0 and eos_step unset: eos_step = step
    if eos_step set and step >= eos_step + fae: break        # this step's latent is dropped
    emit latent  (to Mimi as latent * emb_std + emb_mean)
    x = latent                                              # normalised space
```

Frames emitted = `eos_step + fae`. If EOS never fires, Python emits `max_gen` frames and logs a warning.

The KV capacity needed is `P0 + N + max_gen`. Python grows the cache to exactly that. For N ≤ 50
and alba that is at most 126 + 50 + 234 = 410 positions.

---

## 8. Mimi decoder (`models/mimi.py`, `modules/seanet.py`, `modules/conv.py`, `modules/resample.py`)

`decode_from_latent(z)`, where z is `[1, T12, 32]` and `z = latent*emb_std + emb_mean`:

1. **quantizer.output_proj**: a 1×1 Conv1d, 32 → 512, no bias. Its weight is `[512,32,1]`; use it as
   a `[512,32]` linear.
2. **upsample**: `ConvTranspose1d(512, 512, k=32, s=16, groups=512, bias=False)`, which is
   **depthwise**. The weight is `[512,1,32]`. Streaming output is exactly 16 steps per input frame.
3. **decoder_transformer**: `ProjectedTransformer` with d 512 and no input or output projection,
   because both dims are 512. It has 2 layers, like §5 but with these differences:
   - 8 heads.
   - The two residual updates are multiplied by `layer_scale_1.scale` and `layer_scale_2.scale`
     (`[512]` each).
   - `in_proj.weight` is `[1536,512]` and FFN is 512 → 2048 → 512, GELU-tanh, no biases.
   - The attention mask is `0 ≤ query_pos − key_pos < 250`.
   - RoPE as in §5, with head_dim 64 and absolute positions that advance by 16 per frame.
4. **SEANet decoder**. The config sets pad_mode `constant`, so every conv is causal.

| idx | Module | Weight (torch) | k, s | In → out ch | Streaming state |
|---|---|---|---|---|---|
| 0 | StreamingConv1d | `[512,512,7]` + bias | 7, 1 | 512 → 512 | prev input, 6 steps |
| 1 | ELU(α=1) | | | | |
| 2 | StreamingConvTranspose1d | `[512,256,12]` + bias | 12, 6 | 512 → 256 | partial output, 6 steps |
| 3 | ResBlock(256) | block.1 `[128,256,3]`+b, block.3 `[256,128,1]`+b | | 256 | block.1 prev input, 2 steps |
| 4 | ELU | | | | |
| 5 | ConvTranspose1d | `[256,128,10]` + bias | 10, 5 | 256 → 128 | partial, 5 steps |
| 6 | ResBlock(128) | `[64,128,3]`+b, `[128,64,1]`+b | | 128 | prev, 2 steps |
| 7 | ELU | | | | |
| 8 | ConvTranspose1d | `[128,64,8]` + bias | 8, 4 | 128 → 64 | partial, 4 steps |
| 9 | ResBlock(64) | `[32,64,3]`+b, `[64,32,1]`+b | | 64 | prev, 2 steps |
| 10 | ELU | | | | |
| 11 | StreamingConv1d | `[1,64,3]` + bias | 3, 1 | 64 → 1 | prev, 2 steps |

The ResBlock computes `x + conv_k1(ELU(conv_k3(ELU(x))))`. Its hidden width is dim/2 and its
dilation is 1, since `n_residual_layers=1`.

Per latent frame, the lengths are 1 → 16 (upsample) → 16 → 96 → 480 → 1920 samples. There is no
final activation, no tanh, and no clipping.

### 8.1 Streaming Conv1d (`StreamingConv1d.forward`)

- The state `prev` is the last `P = (k−1)·d + 1 − s` input steps. It starts as zeros for pad_mode
  `constant`; for `replicate` it starts as copies of the first input step.
- `y = conv1d(cat(prev, x), W, b, stride s, padding 0)`.
- Then `prev = cat(prev, x)[..., −P:]`.
- The input length must be a multiple of s.

This is ordinary causal left-padding by `k − s` zeros, carried across calls.

### 8.2 Streaming ConvTranspose1d (`StreamingConvTranspose1d.forward`)

- The state `partial` covers `K − S` output steps, with no bias, and starts as zeros.
- Compute `y = convtr(x, W)` without bias. Its length is `(T−1)S + K`.
- `y[:, :K−S] += partial`.
- `partial = y[:, T·S:]`.
- `out = y[:, :T·S] + bias`.

Python adds the bias to all of `y`, then subtracts it from the saved tail. That is the same thing.
**Every transposed conv here has K = 2S.**

### 8.3 Depthwise upsample, closed form

With K = 2S = 32 and one input frame e[c] (512 values), and e_prev being the previous frame
(zeros at start):

```
u[c, j] = e[c] * w[c, j] + e_prev[c] * w[c, 16 + j]        j = 0..15
```

So the streaming state can just be `e_prev` (512 floats). That is equivalent to Python's `partial`,
which holds `e_prev[c]·w[c,16+j]`.

### 8.4 Mimi transformer cache

Python uses a linear cache of `max_gen·16` positions plus the window mask. Any buffer that keeps the
last 249 keys and values plus the 16 new ones is enough.

### 8.5 SEANet encoder (voice cloning only)

The encoder mirrors the decoder, with ratios reversed to 4, 5, 6. All convs are causal:

| idx | Module |
|---|---|
| 0 | conv `[64,1,7]` |
| 1 | ResBlock(64): `[32,64,3]`, `[64,32,1]` |
| 2 | ELU |
| 3 | conv `[128,64,8]`, s4 |
| 4 | ResBlock(128) |
| 5 | ELU |
| 6 | conv `[256,128,10]`, s5 |
| 7 | ResBlock(256) |
| 8 | ELU |
| 9 | conv `[512,256,12]`, s6 |
| 10 | ELU |
| 11 | conv `[512,512,3]` |

Then:

- `encoder_transformer`: same as the decoder's; run it non-streaming over the whole prompt with
  causal window 250.
- `downsample.conv`: Conv1d 512 → 32, k 32, s 16, **no bias, pad_mode `replicate`**. The 16-step left
  pad is the first 200 Hz frame repeated 16 times.

For L input samples (already a multiple of 1920) the output is L/1920 frames.

---

## 9. Checkpoint tensor inventory (english, 214 tensors, all BF16)

`{i}` runs over 0..5 for FlowLM and 0..1 for the Mimi transformers.

### FlowLM: embedding, IO and state (11 tensors)

| Tensor | Shape | Used in |
|---|---|---|
| `flow_lm.conditioner.embed.weight` | [4001, 1024] | text LUT (§5) |
| `flow_lm.bos_emb` | [32] | step-0 latent (§5) |
| `flow_lm.bos_before_voice` | [1, 1, 1024] | voice prompt position 0 (§4.2) |
| `flow_lm.speaker_proj_weight` | [1024, 32] | voice cloning (§4.2) |
| `flow_lm.input_linear.weight` | [1024, 32] | latent to d_model, no bias |
| `flow_lm.out_norm.weight` | [1024] | final LayerNorm, eps 1e-5 |
| `flow_lm.out_norm.bias` | [1024] | final LayerNorm, eps 1e-5 |
| `flow_lm.out_eos.weight` | [1, 1024] | EOS logit |
| `flow_lm.out_eos.bias` | [1] | EOS logit (value −0.3027) |
| `flow_lm.emb_mean` | [32] | Mimi input: `latent*std + mean` |
| `flow_lm.emb_std` | [32] | Mimi input: `latent*std + mean` |

### FlowLM transformer (48 tensors: 8 per layer × 6)

| Tensor | Shape | Used in |
|---|---|---|
| `flow_lm.transformer.layers.{i}.norm1.weight` | [1024] | LayerNorm before attention |
| `flow_lm.transformer.layers.{i}.norm1.bias` | [1024] | LayerNorm before attention |
| `flow_lm.transformer.layers.{i}.self_attn.in_proj.weight` | [3072, 1024] | packed q, k, v rows 0–1023, 1024–2047, 2048–3071; head h is rows h·64..h·64+63 within each |
| `flow_lm.transformer.layers.{i}.self_attn.out_proj.weight` | [1024, 1024] | attention output |
| `flow_lm.transformer.layers.{i}.norm2.weight` | [1024] | LayerNorm before FFN |
| `flow_lm.transformer.layers.{i}.norm2.bias` | [1024] | LayerNorm before FFN |
| `flow_lm.transformer.layers.{i}.linear1.weight` | [4096, 1024] | FFN up |
| `flow_lm.transformer.layers.{i}.linear2.weight` | [1024, 4096] | FFN down |

### Flow head (68 tensors)

| Tensor | Shape | Used in |
|---|---|---|
| `flow_lm.flow_net.cond_embed.weight` | [512, 1024] | condition c → y |
| `flow_lm.flow_net.cond_embed.bias` | [512] | condition c → y |
| `flow_lm.flow_net.input_proj.weight` | [512, 32] | noise → width 512 |
| `flow_lm.flow_net.input_proj.bias` | [512] | noise → width 512 |
| `flow_lm.flow_net.time_embed.{0,1}.freqs` | [128] | sinusoid frequencies; **use these values** |
| `flow_lm.flow_net.time_embed.{0,1}.mlp.0.weight` | [512, 256] | timestep MLP, Linear 256→512 |
| `flow_lm.flow_net.time_embed.{0,1}.mlp.0.bias` | [512] | timestep MLP, Linear 256→512 |
| `flow_lm.flow_net.time_embed.{0,1}.mlp.2.weight` | [512, 512] | timestep MLP, Linear 512→512 (after SiLU) |
| `flow_lm.flow_net.time_embed.{0,1}.mlp.2.bias` | [512] | timestep MLP, Linear 512→512 (after SiLU) |
| `flow_lm.flow_net.time_embed.{0,1}.mlp.3.alpha` | [512] | variance "RMSNorm" gain |
| `flow_lm.flow_net.res_blocks.{i}.in_ln.weight` | [512] | block LayerNorm, eps 1e-6 |
| `flow_lm.flow_net.res_blocks.{i}.in_ln.bias` | [512] | block LayerNorm, eps 1e-6 |
| `flow_lm.flow_net.res_blocks.{i}.mlp.0.weight` | [512, 512] | block MLP, first linear |
| `flow_lm.flow_net.res_blocks.{i}.mlp.0.bias` | [512] | block MLP, first linear |
| `flow_lm.flow_net.res_blocks.{i}.mlp.2.weight` | [512, 512] | block MLP, second linear |
| `flow_lm.flow_net.res_blocks.{i}.mlp.2.bias` | [512] | block MLP, second linear |
| `flow_lm.flow_net.res_blocks.{i}.adaLN_modulation.1.weight` | [1536, 512] | shift, scale, gate from silu(y) |
| `flow_lm.flow_net.res_blocks.{i}.adaLN_modulation.1.bias` | [1536] | shift, scale, gate from silu(y) |
| `flow_lm.flow_net.final_layer.adaLN_modulation.1.weight` | [1024, 512] | shift, scale |
| `flow_lm.flow_net.final_layer.adaLN_modulation.1.bias` | [1024] | shift, scale |
| `flow_lm.flow_net.final_layer.linear.weight` | [32, 512] | output velocity |
| `flow_lm.flow_net.final_layer.linear.bias` | [32] | output velocity |

The `.1.` in `adaLN_modulation.1` is index 1 of `Sequential(SiLU, Linear)`.

### Mimi decoder side (44 tensors, all needed)

| Tensor | Shape | Used in |
|---|---|---|
| `mimi.quantizer.output_proj.weight` | [512, 32, 1] | latent 32 → 512 (§8 step 1) |
| `mimi.upsample.convtr.convtr.weight` | [512, 1, 32] | depthwise ×16 upsample (§8.3) |
| `mimi.decoder_transformer.transformer.layers.{i}.norm1.weight` | [512] | LayerNorm before attention |
| `mimi.decoder_transformer.transformer.layers.{i}.norm1.bias` | [512] | LayerNorm before attention |
| `mimi.decoder_transformer.transformer.layers.{i}.norm2.weight` | [512] | LayerNorm before FFN |
| `mimi.decoder_transformer.transformer.layers.{i}.norm2.bias` | [512] | LayerNorm before FFN |
| `mimi.decoder_transformer.transformer.layers.{i}.self_attn.in_proj.weight` | [1536, 512] | packed q, k, v |
| `mimi.decoder_transformer.transformer.layers.{i}.self_attn.out_proj.weight` | [512, 512] | attention output |
| `mimi.decoder_transformer.transformer.layers.{i}.linear1.weight` | [2048, 512] | FFN up |
| `mimi.decoder_transformer.transformer.layers.{i}.linear2.weight` | [512, 2048] | FFN down |
| `mimi.decoder_transformer.transformer.layers.{i}.layer_scale_1.scale` | [512] | LayerScale on attention update |
| `mimi.decoder_transformer.transformer.layers.{i}.layer_scale_2.scale` | [512] | LayerScale on FFN update |
| `mimi.decoder.model.0.conv.weight` | [512, 512, 7] | conv in |
| `mimi.decoder.model.0.conv.bias` | [512] | conv in |
| `mimi.decoder.model.2.convtr.weight` | [512, 256, 12] | up ×6 |
| `mimi.decoder.model.2.convtr.bias` | [256] | up ×6 |
| `mimi.decoder.model.3.block.1.conv.weight` | [128, 256, 3] | ResBlock(256), k3 conv |
| `mimi.decoder.model.3.block.1.conv.bias` | [128] | ResBlock(256), k3 conv |
| `mimi.decoder.model.3.block.3.conv.weight` | [256, 128, 1] | ResBlock(256), k1 conv |
| `mimi.decoder.model.3.block.3.conv.bias` | [256] | ResBlock(256), k1 conv |
| `mimi.decoder.model.5.convtr.weight` | [256, 128, 10] | up ×5 |
| `mimi.decoder.model.5.convtr.bias` | [128] | up ×5 |
| `mimi.decoder.model.6.block.1.conv.weight` | [64, 128, 3] | ResBlock(128), k3 conv |
| `mimi.decoder.model.6.block.1.conv.bias` | [64] | ResBlock(128), k3 conv |
| `mimi.decoder.model.6.block.3.conv.weight` | [128, 64, 1] | ResBlock(128), k1 conv |
| `mimi.decoder.model.6.block.3.conv.bias` | [128] | ResBlock(128), k1 conv |
| `mimi.decoder.model.8.convtr.weight` | [128, 64, 8] | up ×4 |
| `mimi.decoder.model.8.convtr.bias` | [64] | up ×4 |
| `mimi.decoder.model.9.block.1.conv.weight` | [32, 64, 3] | ResBlock(64), k3 conv |
| `mimi.decoder.model.9.block.1.conv.bias` | [32] | ResBlock(64), k3 conv |
| `mimi.decoder.model.9.block.3.conv.weight` | [64, 32, 1] | ResBlock(64), k1 conv |
| `mimi.decoder.model.9.block.3.conv.bias` | [64] | ResBlock(64), k1 conv |
| `mimi.decoder.model.11.conv.weight` | [1, 64, 3] | conv out |
| `mimi.decoder.model.11.conv.bias` | [1] | conv out |

### Mimi encoder side (43 tensors; voice cloning only, zeroed in the ungated repo)

| Tensor | Shape |
|---|---|
| `mimi.encoder.model.0.conv.weight` | [64, 1, 7] |
| `mimi.encoder.model.0.conv.bias` | [64] |
| `mimi.encoder.model.1.block.1.conv.weight` | [32, 64, 3] |
| `mimi.encoder.model.1.block.1.conv.bias` | [32] |
| `mimi.encoder.model.1.block.3.conv.weight` | [64, 32, 1] |
| `mimi.encoder.model.1.block.3.conv.bias` | [64] |
| `mimi.encoder.model.3.conv.weight` | [128, 64, 8] |
| `mimi.encoder.model.3.conv.bias` | [128] |
| `mimi.encoder.model.4.block.1.conv.weight` | [64, 128, 3] |
| `mimi.encoder.model.4.block.1.conv.bias` | [64] |
| `mimi.encoder.model.4.block.3.conv.weight` | [128, 64, 1] |
| `mimi.encoder.model.4.block.3.conv.bias` | [128] |
| `mimi.encoder.model.6.conv.weight` | [256, 128, 10] |
| `mimi.encoder.model.6.conv.bias` | [256] |
| `mimi.encoder.model.7.block.1.conv.weight` | [128, 256, 3] |
| `mimi.encoder.model.7.block.1.conv.bias` | [128] |
| `mimi.encoder.model.7.block.3.conv.weight` | [256, 128, 1] |
| `mimi.encoder.model.7.block.3.conv.bias` | [256] |
| `mimi.encoder.model.9.conv.weight` | [512, 256, 12] |
| `mimi.encoder.model.9.conv.bias` | [512] |
| `mimi.encoder.model.11.conv.weight` | [512, 512, 3] |
| `mimi.encoder.model.11.conv.bias` | [512] |
| `mimi.encoder_transformer.transformer.layers.{i}.*` | the same 10 names and shapes as the decoder transformer, × 2 layers |
| `mimi.downsample.conv.conv.weight` | [32, 512, 32] (not zeroed in the ungated repo) |

Counted from the header, the 214 tensors split as follows:

| Group | Tensors |
|---|---|
| FlowLM IO and state | 11 |
| FlowLM transformer | 48 |
| Flow head | 68 (cond 2 + input_proj 2 + time_embed 12 + res_blocks 48 + final 4) |
| Mimi decoder side | 44 (quantizer 1 + upsample 1 + transformer 20 + SEANet 22) |
| Mimi encoder side | 43 (SEANet 22 + transformer 20 + downsample 1) |

The listing above names every tensor in the file.

Notes:

- There are no `weight_g` / `weight_v` pairs. **Weight norm is already folded** in the released
  file. `get_mimi_state_dict` folds it only for raw training checkpoints.
- **16 names exceed 63 characters**, the limit set by `GGML_MAX_NAME=64`. They are all under
  `mimi.{en,de}coder_transformer.transformer.layers.*`. Rename them in any GGUF converter, e.g.
  `mimi.decoder_transformer.transformer.layers.N.` → `mimi.dec_tr.N.`.

Small tensor values, useful for checking a loader:

- `emb_mean[0:4]` = −0.100098, −0.026001, −0.036377, −0.341797
- `emb_std[0:4]` = 0.964844, 0.992188, 1.039062, 0.925781
- `bos_emb[0:3]` = −0.049072, 0.020752, −0.017578
- `time_embed.0.freqs[0:4]` = 1, 0.929688, 0.867188, 0.804688. The exact values would be 1, 0.930572, ….
- decoder `layers.0.layer_scale_1.scale[0:3]` = 0.000147, 0.141602, 0.092285

---

## 10. The forward pass in ggml

The shapes below are ggml `ne`. The weight `W` for a torch Linear `[out, in]` is `ne=(in, out)`, so
`ggml_mul_mat(W, x)` with x `ne=(in, T)` gives `ne=(out, T)`.

For reference parity, **load every weight as F32** (§11, flag F1). The console engine keeps weights
and run state in `ml.set`s and computes `ml.graph`s (`native/ml.h`). State write-backs are graph
nodes computed for their effect.

### 10.0 Load time

1. Read the safetensors header: 8-byte little-endian length, then the JSON. Each tensor is
   `{dtype, shape, data_offsets}` relative to byte `8 + header_len`. Convert BF16 to F32 by shifting
   each u16 left 16 bits (`ggml_bf16_to_fp32_row`). Alternatively convert once to GGUF, renaming the
   16 long names.
2. Precompute `tconst[512] = (TE0(0) + TE1(1)) / 2` on the host (§6).
3. Optional. These are only rearrangements; the values are unchanged:
   - Split the upsample weight `ne=(32,1,512)` into `w_lo = [:, 0:16]` and `w_hi = [:, 16:32]`, as
     contiguous `ne=(16,512)` each.
   - Stack the 6 block adaLN weights and the final adaLN weight into one `ne=(512, 6·1536+1024)`
     matrix, so each frame needs one matvec for all modulations.
4. Allocate the state tensors (§12), zeroed. Load the voice state:
   - For each layer, `memcpy` K into `Kc[l]` `ne=(64,16,n_ctx)` at positions 0..P0−1, and V into `Vc[l]`.
   - Set `P = P0` (126 for alba).

### 10.1 FlowLM pass (text prompt: T = N; AR step: T = 1)

Inputs:

- `pos`: I32 `ne=(T)` = P..P+T−1.
- `mask`: F32 `ne=(P+T, T)`, where `mask[j,i] = 0` if `j ≤ P+i`, else `−INFINITY`.

Input embeddings:

1. Text: `x = ggml_get_rows(embed ne=(1024,4001), ids I32 ne=(N))` gives `ne=(1024,N)`.
   AR: `x = ggml_mul_mat(input_linear ne=(32,1024), lat ne=(32,1))` gives `ne=(1024,1)`, where
   `lat = bos_emb` on step 0.

Per layer l = 0..5:

2. `h = ggml_add(ggml_mul(ggml_norm(x, 1e-5f), norm1.w), norm1.b)`. The 1-D weights broadcast over T.
3. `qkv = ggml_mul_mat(in_proj ne=(1024,3072), h)` gives `ne=(3072,T)`.
4. Split `qkv` into three views, each `ne=(64,16,T)`:
   `q = ggml_view_3d(qkv, 64,16,T, 64*4, qkv->nb[1], 0)`, and the same for `k` at byte offset 4096
   and `v` at 8192. Apply `ggml_cont` to each if the backend wants contiguous input for rope.
5. `q = ggml_rope_ext(q, pos, NULL, 64, GGML_ROPE_TYPE_NORMAL, 0, 10000.f, 1.f, 0.f, 1.f, 0.f, 0.f)`,
   and the same for `k`.
6. Write the cache:
   `ggml_cpy(k, ggml_view_3d(Kc, 64,16,T, Kc->nb[1], Kc->nb[2], P*Kc->nb[2]))`, and the same for
   `v` into `Vc`. Expand both copies into the graph **before** the attention nodes (flag F7).
7. `K = ggml_permute(ggml_view_3d(Kc,64,16,P+T,…,0), 0,2,1,3)` gives `ne=(64,P+T,16)`.
   `Q = ggml_permute(q, 0,2,1,3)` gives `ne=(64,T,16)`.
8. `kq = ggml_mul_mat(K, Q)` gives `ne=(P+T,T,16)`.
   Then `kq = ggml_soft_max_ext(kq, mask, 0.125f, 0.0f)`.
9. `Vt = ggml_cont(ggml_permute(ggml_view_3d(Vc,64,16,P+T,…), 1,2,0,3))` gives `ne=(P+T,64,16)`.
   `o = ggml_mul_mat(Vt, kq)` gives `ne=(64,T,16)`.
   Then `o = ggml_reshape_2d(ggml_cont(ggml_permute(o,0,2,1,3)), 1024, T)`.
10. `x = ggml_add(x, ggml_mul_mat(out_proj, o))`.
11. `h = LN(x; norm2)`, then `f = ggml_mul_mat(linear1 ne=(1024,4096), h)`.
    Then `f = gelu_tanh(f)` (flag F3), then `x = ggml_add(x, ggml_mul_mat(linear2 ne=(4096,1024), f))`.

Output:

12. After layer 5, advance `P += T`.
    For the prompt pass, stop here: skip out_norm, EOS and the flow head.
    For an AR step, `hl = LN(x; out_norm, 1e-5)`, which is `ne=(1024,1)`.
13. `logit = ggml_add(ggml_mul_mat(out_eos.w ne=(1024,1), hl), out_eos.b)`, a scalar.

### 10.2 Flow head (AR step only)

`x0` is `ne=(32,1)` noise generated on the host (§6).

1. `y = ggml_add(ggml_add(ggml_mul_mat(cond_embed.w ne=(1024,512), hl), cond_embed.b), tconst)`,
   then `sy = ggml_silu(y)`.
2. `z = ggml_add(ggml_mul_mat(input_proj.w ne=(32,512), x0), input_proj.b)`, which is `ne=(512,1)`.
3. For each block b = 0..5:
   - `m = mul_mat(ada_b.w ne=(512,1536), sy) + ada_b.b`.
   - `shift, scale, gate` are the 512-element views of `m` at offsets 0, 512 and 1024 (×4 bytes).
   - `u = ggml_add(ggml_mul(ggml_norm(z, 1e-6f), in_ln.w), in_ln.b)`.
   - `u = ggml_add(ggml_add(u, ggml_mul(u, scale)), shift)`.
   - `u = ggml_add(mul_mat(mlp.2.w, ggml_silu(ggml_add(mul_mat(mlp.0.w, u), mlp.0.b))), mlp.2.b)`.
   - `z = ggml_add(z, ggml_mul(gate, u))`.
4. Final layer:
   - `m = mul_mat(final.ada.w ne=(512,1024), sy) + b`, with `shift = m[0:512]` and `scale = m[512:1024]`.
   - `u = ggml_norm(z, 1e-6f)`; this norm has no affine.
   - `u = u + u*scale + shift`.
   - `v = mul_mat(final.linear.w ne=(512,32), u) + final.linear.b`.
5. `latent = ggml_add(x0, v)`, which is `ne=(32,1)`.
6. Read back `logit` and `latent`. Apply §7's stopping rule. The Mimi input is
   `ggml_add(ggml_mul(latent, emb_std), emb_mean)`. The next step's input is `latent` itself.

The whole AR step (10.1 with T = 1, plus 10.2) is one graph.

### 10.3 Mimi decode, one latent frame per graph

For one frame, channel-fastest `ne=(C,1)` and time-fastest `ne=(1,C)` are the same bytes. So the
steps below switch layouts with `ggml_reshape` wherever T12 = 1.

The SEANet runs in **time-fastest** layout `ne=(T, C)`, which is ggml's conv convention. The
transformer runs in **channel-fastest** layout `ne=(C, T)`.

1. `e = ggml_mul_mat(qproj ne=(32,512), zmimi ne=(32,1))` gives `ne=(512,1)`. Reshape it to `ne=(1,512)`.
2. Upsample (§8.3): `u = ggml_add(ggml_mul(w_lo ne=(16,512), e), ggml_mul(w_hi, e_prev))` gives
   `ne=(16,512)`, time-fastest. `e` is `ne=(1,512)` and broadcasts. Then write `e` into the `e_prev`
   state (flag F7).
3. `xt = ggml_cont(ggml_transpose(u))` gives `ne=(512,16)`. Run 2 layers of 10.1 with these changes:
   - d 512 and 8 heads, so `in_proj` is `ne=(512,1536)`, the views are `ne=(64,8,16)`, and the
     q/k/v byte offsets are 0, 2048 and 4096.
   - The residual updates are `ggml_mul(update, layer_scale_k)`.
   - `pos` = Pm..Pm+15, where `Pm` is the Mimi transformer offset.
   - The keys are the last `min(Pm, 249)` cached positions plus the 16 new ones. The mask entry for
     (key j with absolute position pk, query i with pq = Pm+i) is 0 if `0 ≤ pq − pk < 250`, else −inf.
   - Afterwards, `Pm += 16`.
4. `xs = ggml_cont(ggml_transpose(xt))` gives `ne=(16,512)`.
5. SEANet, using the helpers below. Apply `elu` = `ggml_elu` everywhere the table in §8 says ELU.
   - `x = conv(xs, model.0, state c0)` gives (16,512).
   - `x = convtr(elu(x), model.2, s6, state t2)` gives (96,256).
   - `x = res(x, model.3)`.
   - `x = convtr(elu(x), model.5, s5)` gives (480,128), then `x = res(x, model.6)`.
   - `x = convtr(elu(x), model.8, s4)` gives (1920,64), then `x = res(x, model.9)`.
   - `x = conv(elu(x), model.11)` gives `ne=(1920,1)`, which is the audio.

**Helper `conv(x ne=(T,IC), W ne=(K,IC,OC), b, state ne=(P,IC))`**, with `P = K−1` since s = 1 in the
decoder:

```
xc   = ggml_concat(state, x, 0)                                        # (P+T, IC)
cols = ggml_im2col(W, xc, s, 0, 0, 0, 1, 0, false, GGML_TYPE_F32)       # (IC*K, T)  -- F32, flag F2
y    = ggml_mul_mat(cols, ggml_reshape_2d(W, K*IC, OC))                # (T, OC)
y    = ggml_add(y, ggml_reshape_2d(b, 1, OC))
new state = ggml_view_2d(xc, P, IC, xc->nb[1], T*sizeof(float))  -> ggml_cpy into state
```

The k=1 convs use the same helper with `P = 0`, so there is no concat and im2col is a transpose.
Alternatively, transpose once and use a plain `ggml_mul_mat`.

**Helper `convtr(x ne=(T,IC), W ne=(K,OC,IC), b, partial ne=(S,OC))`**, with K = 2S:

```
y    = ggml_conv_transpose_1d(W, x, S, 0, 1)                           # ((T+1)S, OC), no bias; W must be F32 (F4)
head = ggml_add(ggml_view_2d(y, S, OC, y->nb[1], 0), partial)
body = ggml_view_2d(y, (T-1)*S, OC, y->nb[1], S*4)                      # empty when T == 1
out  = ggml_add(ggml_concat(head, body, 0), bias reshaped (1,OC))       # (T*S, OC)
new partial = ggml_view_2d(y, S, OC, y->nb[1], T*S*4) -> ggml_cpy into partial   (hazard: F7)
```

A faster equivalent is `ggml_mul_mat(Wt ne=(IC,K*OC), x^T)` followed by `ggml_col2im_1d(cols, S, OC, 0)`.
The column layout is `(oc*K + k, t)`, and `Wt` is the torch weight `[IC,OC,K]` reshaped to
`[IC, OC*K]` and transposed once at load. The pinned ggml has `ggml_col2im_1d`.

**Helper `res(x, blk)`**: `x + conv(elu(conv(elu(x), block.1, state), block.3, none))`.

### 10.4 Mimi encoder (voice cloning), one non-streaming graph

1. Audio `ne=(L,1)`, right-padded with zeros to a multiple of 1920.
2. SEANet encoder convs through the same `conv` helper with zero-filled `state` (or
   `ggml_pad_ext(x, P,0, …)`), strides 4, 5 and 6. The output is `ne=(L/120, 512)`.
3. Transpose it. Run the 2-layer transformer with the full causal window mask 250 (a `ne=(L/120, L/120)`
   mask), then transpose back.
4. Downsample:
   - The left pad is `ggml_repeat(first column ne=(1,512), ne=(16,512))`; concat it in front.
   - `cols = ggml_im2col(W ne=(32,512,32), xc, 16, …, F32)`, then `mul_mat(cols, W2d ne=(16384,32))`.
     This gives `ne=(F,32)`, with no bias.
5. `cond = ggml_mul_mat(speaker_proj ne=(32,1024), transpose(lat))`, which is `ne=(1024,F)`.
6. Concatenate `bos_before_voice` in front, giving `ne=(1024,F+1)`.
7. Run 10.1 with T = F+1 and P = 0, as a prompt pass.

---

## 11. ggml op checklist and flags

Used as is: `ggml_mul_mat`, `ggml_get_rows` (a BF16 or F32 table gives F32 rows), `ggml_norm`
(= LayerNorm core, biased variance), `ggml_add`/`ggml_mul` (broadcasting), `ggml_scale`,
`ggml_silu`, `ggml_elu` (α=1, exact `expm1f`), `ggml_tanh`, `ggml_rope_ext` (mode 0),
`ggml_soft_max_ext`, `ggml_im2col`, `ggml_conv_transpose_1d`, `ggml_col2im_1d`, `ggml_concat`,
`ggml_view_*`, `ggml_permute`, `ggml_transpose`, `ggml_cont`, `ggml_reshape_*`, `ggml_cpy`, `ggml_repeat`.

Flags. Each was checked against the pinned ggml `7840aaba`:

- **F1. BF16 weights silently round the activations.** The CPU `mul_mat` converts src1 to the weight's
  `vec_dot_type`. For BF16 that is BF16, and for F16 it is F16. Python computes in **f32 with
  BF16-valued weights**. For parity, convert every weight to F32 at load; that is 438 MB for all, or
  399 MB without the encoder. Afterwards, try BF16 or Q8_0 for the FlowLM transformer's attention
  and FFN only. Python's own int8 option quantizes exactly those and reports no WER change. Keep the
  flow head and Mimi in F32.
- **F2. `ggml_conv_1d` builds its im2col in F16** unless the kernel is BF16. That drops activation
  precision. Call `ggml_im2col(..., GGML_TYPE_F32)` and `ggml_mul_mat` yourself, and keep the conv
  kernels F32 (they are the second `mul_mat` operand).
- **F3. `ggml_gelu` on CPU uses an FP16 lookup table** (`GGML_GELU_FP16` is defined in
  `ggml-cpu/vec.h`). Its input is rounded to half, with errors around 1e-3. Compose the tanh form in
  f32 instead:
  `0.5·x·(1 + tanh(0.7978845608·(x + 0.044715·x³)))` =
  `ggml_mul(ggml_scale(x,0.5f), ggml_scale_bias(ggml_tanh(ggml_scale(ggml_add(x, ggml_scale(ggml_mul(ggml_sqr(x),x),0.044715f)),0.7978845608f)),1.f,1.f))`.
  Or build ggml with that define removed. Do **not** use `ggml_gelu_erf`: the model uses the tanh form.
- **F4. `ggml_conv_transpose_1d`:** it asserts `p0 == 0` and `d0 == 1` (fine here). It has **no groups
  argument**, so the depthwise upsample uses §8.3 with mul/add. Its F16-kernel path casts the input
  to F16, so use F32 kernels. The CPU kernel re-lays-out the whole weight on every call. That is
  cheap at these sizes; use the `mul_mat` + `col2im_1d` form if it shows up in profiles.
- **F5. There is no op for the variance "RMSNorm"**, and `ggml_rms_norm` computes something else.
  With one LSD step it is a load-time constant (§6). For n > 1 steps, compose it:
  `d = x − mean(x)`, then `var = sum_rows(d²)/511`, then `x·alpha / sqrt(var + 1e-5)`.
  `ggml_timestep_embedding` recomputes the frequencies exactly and so disagrees with the BF16-rounded
  `freqs` in the file. Use `ggml_cos`/`ggml_sin` on `τ·freqs`, or the host.
- **F6. Causal padding for streaming.** Every conv is left-padded by `k − s` with the carried state,
  and never on the right. There is no symmetric padding, and no `reflect` padding despite the SEANet
  class default. The first call sees zeros; the encoder downsample alone replicates its first sample.
  `ggml_pad_reflect_1d` is never needed.
- **F7. Read-before-write on state.** When a graph reads a state tensor (`partial`, `e_prev`, conv
  `prev`, KV cache) and also writes new state into the same tensor, the write must come after the
  read. `ggml_cpy` into a view creates no dependency on the reader. Options:
  - Double-buffer each state: read A, write B, and swap per frame. This is the safest.
  - For conv `prev`, it is already safe, because the new value is a view of `concat(prev, x)`.
  - For KV caches, llama.cpp expands the `cpy` first and relies on CPU node order. The read range
    `[0, P)` and the write range `[P, P+T)` do not overlap, but the attention view spans both.
- **F8. LayerScale** exists only in the Mimi transformers; it is a per-channel `ggml_mul`. FlowLM has
  none.
- **F9. Weight norm** is already folded (§9). Nothing to do.
- **F10. RoPE mode** is `GGML_ROPE_TYPE_NORMAL` (0), which rotates adjacent pairs. NEOX is wrong.
  ggml takes `pos` as I32, and `a` must be `ne=(64, heads, T)`.
- **F11. Random normal** has no ggml op. Draw on the host (Box–Muller or similar). To compare against
  Python at temp > 0, inject the recorded noise (§13.3).
- **F12. Names and dims.** 16 checkpoint names are longer than 63 characters, and the voice cache is
  5-D. Rename and split both when making a GGUF (§4.1, §9).

---

## 12. Streaming structure, state and latency

State carried across AR steps within one chunk:

- **FlowLM**, per layer: `Kc`, `Vc` `ne=(64,16,n_ctx)` F32, where `n_ctx ≥ P0 + N + max_gen`. That
  is 48 KiB per position, or ~19.7 MB at 410 positions.
- **FlowLM**, scalars: the shared position `P`, the last latent (32 floats, the next input) and the
  `eos_step` bookkeeping.
- Each chunk restarts from the pristine voice state. Copy it, as Python's `copy_state=True` does.

State carried across frames by the Mimi decoder (fresh and zeroed for every chunk):

| State | Shape | Floats |
|---|---|---|
| `e_prev` (upsample) | 512 | 512 |
| decoder transformer K, V × 2 layers | ≥ (249 + 16) × 512 each | ~2.2 MB total windowed; Python keeps `max_gen·16` positions |
| `Pm` | int | +16 per frame |
| conv `prev`, model.0 | (6, 512) | 3072 |
| conv `prev`, res3 block.1 | (2, 256) | 512 |
| conv `prev`, res6 block.1 | (2, 128) | 256 |
| conv `prev`, res9 block.1 | (2, 64) | 128 |
| conv `prev`, model.11 | (2, 64) | 128 |
| convtr `partial`, model.2 | (6, 256) | 1536 |
| convtr `partial`, model.5 | (5, 128) | 640 |
| convtr `partial`, model.8 | (4, 64) | 256 |

The k=1 convs carry no state.

Python runs the FlowLM loop and the Mimi decoder on two threads, pinned with
`torch.set_num_threads(1)`, and joined by a queue. A port can do the same with two graphs.

**Latency.** The codec is causal with no lookahead, so the first frame's 1920 samples come out as soon
as frame 0 exists. Time to first audio is:

- the text prompt pass (N tokens through 6 layers, ≈ 75M·N MAC),
- plus one AR step (≈ 76M MAC transformer + 8M MAC flow head),
- plus one Mimi frame (≈ 100M MAC transformer at 16 steps + ≈ 160M MAC SEANet).

The upstream README reports **~200 ms to the first chunk** and ~6× real time on a MacBook Air M4, on 2
cores, in Python. Steady state costs about 350M MAC per 80 ms frame, which is about 4.3 GMAC per
second of audio. **The Mimi decoder is the larger share.** The FlowLM step is bound by memory
bandwidth: at F32 each step reads 302 MB of transformer weights.

---

## 13. Reference numbers

### 13.1 Offline check, no Python needed

Load `alba`. Layer 0 at position 0 must equal `W_{k,v} · LayerNorm(bos_before_voice; norm1, eps 1e-5)`,
where W_k is `in_proj` rows 1024..2047 and W_v is rows 2048..3071. RoPE is the identity at position 0.
Computed from the BF16 weights in f32, for head 0 and dims 0..7:

```
K = -0.00832703 -0.00160593 -0.00400324  0.00542767 -0.00520538  0.00725109  0.00412817  0.00337402
V = -0.00492142 -0.00129018  0.00767036  0.01448909 -0.00316598  0.09348     0.00117009 -0.00604142
```

These match the stored cache to every printed digit. A mismatch means the loader, the LayerNorm or
the q|k|v split is wrong.

### 13.2 Mimi decoder test vectors, computed with the official modules

I ran the official modules with the `languages/english` decoder weights in f32, torch 2.8 CPU, on a
fresh state, one frame per call:

```
zn[f][d] = 0.8 * sin(0.37 * (f+1) * (d+1))      f = 0..F-1, d = 0..31   (double, then f32)
z = zn * emb_std + emb_mean                       -> decode_from_latent frame by frame
```

With F = 4:

| Tensor (frame 0) | Shape (C,T) | `[ch0, t0..3]` | `[ch1, t0..3]` | mean abs |
|---|---|---|---|---|
| quantizer out | (512,1) | −1.9873593 | 0.4595907 | 0.469209 |
| upsample out | (512,16) | −0.5705895 −0.5511817 −0.504603 −0.477432 | 0.0700158 0.0682205 0.0464528 0.0446575 | 0.0531166 |
| decoder_transformer out | (512,16) | −0.5375092 −0.5584011 −0.5433848 −0.5339487 | −0.4323802 0.08497 0.1439926 0.2058088 | 0.408421 |
| decoder.model.0 | (512,16) | −0.9837393 −2.026342 −2.0650342 −2.3386045 | −0.5023116 −1.1848223 −1.5860629 −2.0385628 | 2.31033 |
| decoder.model.2 (convtr ×6) | (256,96) | 0.555433 0.463955 0.3019074 0.0914273 | −0.2175322 0.456852 −0.4226618 0.3146947 | 1.57258 |
| decoder.model.3 (res) | (256,96) | 1.8373127 1.5507765 1.3935964 0.9669604 | 0.2854988 0.9475849 0.0740229 0.8126237 | 1.63349 |
| decoder.model.5 (convtr ×5) | (128,480) | 0.0973223 0.2289094 0.0820317 0.1802865 | 0.1944223 0.0094079 0.0599547 0.1475576 | 0.44557 |
| decoder.model.8 (convtr ×4) | (64,1920) | −0.3427803 −0.3518591 −0.3240042 −0.301523 | −0.0973823 −0.1331523 −0.1608749 −0.1580625 | 0.252023 |

The first 12 audio samples are:

```
0.0005371  0.0021438  0.0038239  0.0031311 -0.0001629 -0.0031992 -0.0074632 -0.0105186 -0.0111194 -0.0128237 -0.0133886 -0.0132442
```

| Check | Value |
|---|---|
| `audio[1000:1006]` | 0.0168021 0.0154555 0.014058 0.0126015 0.0111655 0.0097504 |
| `audio[1920:1926]`, frame 1 | 0.0537098 0.0520044 0.0502825 0.0479068 0.0443647 0.0395277 |
| `sum(audio[0:1000])` | −3.9979455 |
| `sum|audio[0:1000]|` | 20.417957 |
| RMS over 7680 samples | 0.0236475 |
| Frame-by-frame vs all-at-once | max diff 2.2e-7 |

F = 20 exercises the 250-step window, which first drops keys at position 250 in frame 15.
The first 4 frames are bit-identical to the F = 4 run.

| Check | Value |
|---|---|
| `audio[36480:36486]`, frame 19 | −0.0177266 −0.0165139 −0.0153342 −0.0135595 −0.0118193 −0.0105901 |
| `sum(audio[36480:38400])` | −7.0774136 |
| `sum|…|` | 29.585445 |

Running without the window changes frames 16–19 by up to 0.02. Expect agreement to about 1e-5
with F32 weights.

### 13.3 Full pipeline script (not run here: needs the 219 MB checkpoint and torch)

Run it with:

```
uv run --python 3.12 --with "git+https://github.com/kyutai-labs/pocket-tts@0c2db3bdea7c991c568989cc11b503f14483fabc" --with safetensors python ref_pocket_tts.py
```

No HF login is needed: the loader falls back to the ungated weights, and the voice is a predefined
state.

```python
"""Reference dump for a ggml port of Pocket TTS."""
import copy
import numpy as np, torch
from safetensors.numpy import save_file
from pocket_tts import TTSModel
from pocket_tts.models.text_chunking import prepare_text_prompt
from pocket_tts.modules.stateful_module import init_states, increment_steps

TEXT, VOICE = "Hello world, this is a test.", "alba"

def run(temp, seed, out):
    torch.manual_seed(seed)
    m = TTSModel.load_model(language="english", temp=temp)   # 1 LSD step, eos -4.0, no clamp
    fl = m.flow_lm
    voice = m.get_state_for_audio_prompt(VOICE)              # KV state import: no compute, no RNG
    text, guess = prepare_text_prompt(TEXT, m.pad_with_spaces_for_short_inputs,
                                      m.remove_semicolons, m.append_terminal_punctuation)
    fae = m.model_recommended_frames_after_eos if m.model_recommended_frames_after_eos is not None else guess + 2
    tokens = fl.conditioner.prepare(text)                    # [1, N]; expect [2994,578,262,285,277,267,1115,263]
    n_tok = tokens.shape[1]
    max_gen = m._estimate_max_gen_len(n_tok)
    state = copy.deepcopy(voice)
    p0 = m._flow_lm_current_end(state)                       # 126
    m._expand_kv_cache(state, p0 + n_tok + max_gen)

    rec = {"cond": [], "noise": [], "flow": [], "eos": [], "layers": []}
    hooks = [
        fl.flow_net.register_forward_hook(lambda mod, i, o: (rec["cond"].append(i[0][0].clone()),
                                                              rec["noise"].append(i[3][0].clone()),
                                                              rec["flow"].append(o[0].clone()))),
        fl.out_eos.register_forward_hook(lambda mod, i, o: rec["eos"].append(float(o.reshape(-1)[0]))),
    ]
    for layer in fl.transformer.layers:
        hooks.append(layer.register_forward_hook(lambda mod, i, o: rec["layers"].append(o[0, -1].clone())))

    with torch.no_grad():
        m._run_flow_lm_and_increment_step(model_state=state, text_tokens=tokens)   # call 0: text prompt
        x = torch.full((1, 1, fl.ldim), float("nan"))                              # NaN = BOS
        latents, eos_step = [], None
        for step in range(max_gen):
            nxt, is_eos = m._run_flow_lm_and_increment_step(model_state=state, backbone_input_latents=x)
            if bool(is_eos.item()) and eos_step is None:
                eos_step = step
            if eos_step is not None and step >= eos_step + fae:
                break
            latents.append(nxt)
            x = nxt
    for h in hooks:
        h.remove()
    lat = torch.cat(latents, dim=1)                                                 # [1, F, 32], normalised

    mim = {}
    mh = [m.mimi.quantizer.register_forward_hook(lambda mod, i, o: mim.setdefault("q", o[0, :, 0].clone())),
          m.mimi.upsample.register_forward_hook(lambda mod, i, o: mim.setdefault("up", o[0].T.clone())),
          m.mimi.decoder_transformer.register_forward_hook(lambda mod, i, o: mim.setdefault("tr", o[0][0].T.clone()))]
    ms = init_states(m.mimi, batch_size=1, sequence_length=max_gen * 16)
    audio = []
    with torch.no_grad():
        for f in range(lat.shape[1]):                                               # one frame per call, like the port
            audio.append(m.mimi.decode_from_latent(lat[:, f:f+1] * fl.emb_std + fl.emb_mean, ms)[0, 0])
            increment_steps(m.mimi, ms, increment=16)
    for h in mh:
        h.remove()
    audio = torch.cat(audio)

    if temp == 0.0:   # cross-check against the threaded public API (deterministic at temp 0)
        ref = m.generate_audio(voice, TEXT)
        print("public API len", ref.shape[0], "max|diff|", (ref[: audio.shape[0]] - audio).abs().max().item())

    t = lambda v: v.detach().float().contiguous().numpy()
    save_file({
        "tokens": tokens[0].to(torch.int32).numpy(),
        "prompt_cond": t(rec["cond"][0]),                      # out_norm(h) at the last text position
        "prompt_eos_logit": np.array([rec["eos"][0]], np.float32),
        "layers_prompt_last": t(torch.stack(rec["layers"][0:6])),   # per-layer output, last text position
        "layers_ar0": t(torch.stack(rec["layers"][6:12])),          # per-layer output, BOS step
        "cond": t(torch.stack(rec["cond"][1:])),               # per AR step (includes the dropped last step)
        "noise": t(torch.stack(rec["noise"][1:])),             # x0 per AR step: inject these in the port
        "flow_out": t(torch.stack(rec["flow"][1:])),           # v(c, 0, 1, x0)
        "eos_logits": np.array(rec["eos"][1:], np.float32),
        "latents": t(lat[0]),                                  # emitted, normalised
        "latents_denorm": t(lat[0] * fl.emb_std + fl.emb_mean),
        "mimi_q0": t(mim["q"]), "mimi_up0": t(mim["up"]), "mimi_tr0": t(mim["tr"]),
        "audio_first1000": t(audio[:1000]), "audio": t(audio),
        "meta": np.array([p0, n_tok, max_gen, -1 if eos_step is None else eos_step, fae, lat.shape[1]], np.int32),
    }, out)
    print(out, "frames", lat.shape[1], "eos_step", eos_step, "first latent", lat[0, 0, :4].tolist(),
          "audio[0:8]", audio[:8].tolist())

if __name__ == "__main__":
    run(0.0, 0, "ref_temp0.safetensors")      # noise is exactly zero: fully deterministic
    run(0.3, 1234, "ref_temp03.safetensors")  # compare with the recorded noise injected
```

How to compare against these dumps:

1. Check `tokens`.
2. Check `layers_prompt_last`, `prompt_cond` and `prompt_eos_logit`.
3. **With teacher forcing** (feed the reference `latents` as the AR input, not your own), check for
   every step:
   - `layers_ar0` and `cond`,
   - `flow_out`, using the reference `noise`,
   - `eos_logits`.
4. Decode the reference `latents_denorm` and check `mimi_q0`, `mimi_up0`, `mimi_tr0`, then
   `audio_first1000`.

Free-running comparison over many frames drifts, because autoregression is chaotic. A 1e-6 difference
can move EOS by one frame. So use free running only as an end-to-end listening test.

---

## 14. Gotchas

1. **Precision.**
   - The weights are BF16, but Python computes in f32. See F1, F2 and F3 for the three places ggml
     quietly drops to 16-bit.
   - Buffers are BF16-rounded too (`emb_mean`, `emb_std`, `bos_emb`, `freqs`). Use the file values;
     never recompute `freqs`.
2. **The "RMSNorm" in the timestep embedders** is `h·alpha/√(unbiased var(h)+1e-5)`, not RMS.
3. **Two LayerNorm epsilons.** It is 1e-5 in both transformers and `out_norm`, and 1e-6 in the flow
   head (`in_ln` and `final_layer`, where the final one has no affine).
4. **adaLN applies SiLU to the condition first**, and the chunk order is shift, scale, gate. The
   modulation is `x·(1+scale)+shift`.
5. **Normalised versus raw latents.** The AR loop feeds back the **normalised** latent. Only Mimi sees
   `latent·emb_std + emb_mean`. The voice-cloning conditioning uses **raw** encoder latents with no
   normalisation.
6. **The BOS latent** is NaN in Python, replaced by `bos_emb` inside `forward`. Never let a NaN reach
   ggml. Python's caches are NaN-filled beyond `offset`, but it only ever reads `[0, offset+T)`. Zero
   your buffers, and keep views within the written range.
7. **Voice state layout.** K is stored after RoPE, positions start at 0, and `bos_before_voice` is
   position 0. Text starts at `offset`, which is 126 for alba and different for other voices.
8. **Mimi transformer attention** is a **250-step sliding window** at 200 Hz (1.25 s), with absolute
   RoPE positions advancing 16 per frame. The FlowLM has no window.
9. **Upsample.** It is depthwise with K = 2S, and there is no bias on the upsample or the downsample.
   ggml's conv-transpose has no groups argument, so write it as two broadcast multiplies.
10. **Causal convs only:** left pad `k−s` and no right pad. The transposed convs drop the last
    `K−S` outputs into the carried `partial`, so each frame yields exactly T·S samples.
11. **Stopping rule.** The latent from the step that fires EOS is emitted, and emission continues
    for `fae` frames in total counting that one, where `fae` = 3 for more than 4 words and 5 for up
    to 4. The latent of the step that trips the break is discarded.
12. **Prompt passes.** Python also runs the flow head, and draws noise, on the text prompt pass and on
    a cloning prompt pass. A port skips that work. The only visible effect is on torch's RNG
    sequence, so compare with injected noise.
13. **Chunks are independent.** Each chunk gets a fresh voice-state copy and a fresh Mimi state, and
    Python concatenates the audio with no crossfade.
14. **Tokenizer.** It adds no BOS or EOS, uses the identity normaliser, and does not collapse spaces
    (the text prep does). Byte fallback is on. The text prep uses single-pass `replace("  ", " ")`
    and a Python `str.upper()` on the first character. The end-of-sentence ids come from encoding
    `".!...?"`.
15. **GGUF limits.** 16 names are over 63 characters, and the voice cache is 5-D.
16. **Mixed dtypes** in `english_2026-04_24l` (F32 FlowLM, BF16 Mimi). Also, 2026-01 has a different
    `speaker_proj` and `downsample` shape and no `bos_before_voice`. Key everything off the tensor
    header, not assumptions.
17. **Temperature defaults.** The code-wide default is 0.7, but the English config's
    `default_temperature` is 0.3, and `load_model(temp=None)` uses the config value. The EOS
    threshold is −4.0 on the raw logit, with no sigmoid.
18. **Output range.** Audio is not clipped. Clamp to [−1, 1] before int16 conversion.

---

## Summary

**Architecture.** The FlowLM is a 6-layer, 1024-wide causal transformer: 16 heads, interleaved
RoPE, LayerNorm eps 1e-5, GELU-tanh FFN 4096, no biases. Its KV cache is seeded with a voice
prompt (`bos_before_voice` plus 125 projected Mimi latents), shipped as a precomputed KV cache per
voice. Then come SentencePiece unigram tokens (4000 pieces, 4001×1024 table), then one 32-dim
latent per 80 ms frame. Each frame's normed last hidden state feeds a 1024→1 EOS logit (stop when
it exceeds −4, plus 3–5 frames) and a 6-block AdaLN MLP flow head. That head maps noise ~ N(0, 0.3)
to the latent in one LSD step: `x = x0 + v(c, 0, 1, x0)`. Latents are denormalised, projected to
512, upsampled ×16 by a depthwise transposed conv, and passed through a 2-layer transformer at
200 Hz with a 250-step window. A causal SEANet decodes them: conv7, three ELU → ConvTranspose (×6,
×5, ×4) → ResBlock stages, ELU → conv3. Output is 1920 samples per frame at 24 kHz.

**Files** (ungated `kyutai/pocket-tts-without-voice-cloning` @ `e81d79e`, CC-BY-4.0):

| File | Size |
|---|---|
| `languages/english/model.safetensors` | 219,029,196 B, BF16, 109.5M params |
| `languages/english/tokenizer.model` | 59,339 B |
| `languages/english/embeddings/alba.safetensors` (any of 26 voices) | 6,194,424 B |

Voice cloning needs the gated `kyutai/pocket-tts` copy, which has real encoder weights.

**ggml ops:**

- `mul_mat`, `get_rows`, `norm`, `add`, `mul`, `scale`, `scale_bias`
- `silu`, `elu`, `tanh`, `sqr` (compose GELU-tanh; `ggml_gelu` uses an FP16 table)
- `rope_ext` (mode 0), `soft_max_ext` with an explicit mask
- `im2col` (F32 destination) + `mul_mat` for Conv1d
- `conv_transpose_1d` (F32 kernels) or `mul_mat` + `col2im_1d`
- `concat`, `view`, `permute`, `transpose`, `cont`, `cpy` for streaming state

The host handles noise, the "RMSNorm" constant and tokenizing.

---

## Port

Done 2026-09-10: `console/ml/pocket_tts.lua` (the model), `console/ml/convert/pocket_tts.lua`
(checkpoint and voices to GGUF), `test/ml_pocket_tts_test.lua`. No op was added to the engine
and `native/tok.c` is unchanged: the "llama" unigram mode already tokenizes as SentencePiece does.

    luajit console/ml/convert/pocket_tts.lua model model.safetensors tokenizer.model console/ml/models/pocket-tts.gguf
    luajit console/ml/convert/pocket_tts.lua model model.safetensors tokenizer.model console/ml/models/pocket-tts-f16.gguf f16
    luajit console/ml/convert/pocket_tts.lua voice alba.safetensors console/ml/models/pocket-tts-alba.gguf

    local tts = pocket.load(ml.engine { device = "auto" }, "console/ml/models/pocket-tts.gguf",
                            { voice = "console/ml/models/pocket-tts-alba.gguf" })
    local samples, info = tts:speak(text, { temperature = 0.3, seed = 1, on_audio = function (frame) end })
    tts:set_voice(other_voice_gguf)

`speak` answers every sample and `info` (frames, chunks, EOS steps, `first_audio`, `seconds`,
`audio_seconds`). The pieces are public for checking: `start(ids)` (the prompt pass), `step(latent,
noise, taps)`, `decode(latent, taps)` (one frame, streaming), `decode_all(latents)` (several frames
from a fresh decoder, as the package's non-streaming decode), `cached(layer, position)`, `chunks`,
`pocket.prepare`.

### How it runs

- **Weights.** The default GGUF is F32, the BF16 values exactly (F1). The `f16` GGUF keeps the
  FlowLM's large matrices in F16 (231 MB, not 399): every BF16 value there is an F16 value except the
  0.15% below F16's normal range, which move by at most 3e-8. A GPU reads half the bytes and its
  matrix-vector product keeps activations f32; on a CPU engine `load` casts those matrices back to
  F32, so either file gives the CPU's numbers.
- **One graph per frame.** `speak` builds the FlowLM step and the Mimi decode of the latent it made
  into one graph (`frame`); the latent never leaves the device between them. Graphs are rebuilt per
  frame; building costs 0.3 to 0.5 ms of a 7 to 12 ms frame.
- **The voice** is copied into positions 0..P0-1 of the FlowLM cache once, by `set_voice`. Nothing
  ever writes below P0, so a new chunk starts from the voice by setting the position back to P0; no
  copy per chunk. The cache has room for P0 + 300 positions and grows when a chunk needs more (a
  sentence of 58 tokens with no punctuation needed 451).
- **Mimi, channels first.** The whole decoder runs in ggml's (C, T) layout, the transformer's, so
  there is no transpose. A Conv1d is one `mul_mat` of the kernel, converted to rows of K taps with the
  channel fastest, over its windows; `im2col` copies the windows out by reading the (C, T+K-1)
  signal as an image and each window as a C-wide, K-high patch of it (ggml will not view overlapping
  rows). A ConvTranspose1d (all have K = 2S) is one `mul_mat` that gives each input step's 2S outputs;
  the first S add to the last S of the step before, and the last step's go to the next call. The
  depthwise upsample is two broadcast multiplies (8.3).
- **Mimi state.** Every conv history and the upsample's last frame are double-buffered (F7): frame f
  reads copy f % 2 and writes the other. The transformer's K and V are a ring of 17 frames (the
  oldest key a window of 250 still reaches is 249 steps before a frame's first query), each frame
  writing its own slot before attention reads the ring; the mask is rebuilt from each slot's frame,
  and cached per slot once the ring is full.
- **GELU.** Composed of f32 ops on the CPU (F3); on a GPU ggml's gelu is already the f32 tanh form.

### What was checked, and how closely

All against the package at 0c2db3b on these weights, run locally (torch 2.12, `TTSModel.load_model`
from a config naming the local files; the dump script is 13.3's, with its forward hooks made to
return None). Every number below was measured on the CPU and on Metal (M4), under LuaJIT; Lua 5.5
gives the same numbers bit for bit.

| Check | CPU | Metal |
|---|---|---|
| Tokenizer: the seven rows of 3.3; 3,000 random strings (ASCII, accents, dashes, CJK, emoji) against `sentencepiece` | all equal | same |
| Text preparation and chunking (a 3-chunk text: 42, 42, 21 tokens; `$3.50` not a boundary) | equal | same |
| Voice: layer 0, position 0 against 13.1's printed values / against in_proj·LN(bos) | 3e-8 / 5.4e-7 | same |
| FlowLM prompt pass: each layer's last position, out_norm | 3.1e-6, 3.2e-6 | 2.9e-6, 3.3e-6 |
| FlowLM, teacher forced over all 26 steps: out_norm, flow head output, EOS logit, latent | 2.9e-6, 2.2e-5, 7.2e-6, 2.2e-5 | 2.7e-6, 7.4e-6, 6.0e-6, 7.4e-6 |
| Flow head from the recorded noise (temperature 0.3): latents 0 and 1 | 9.5e-7, 5.3e-6 | 2.2e-6, 1.9e-6 |
| Mimi, 13.2's made-up latents, frame by frame: every stage, samples, sums, frame 19 | every printed digit (2.4e-6 on the stages, 2.2e-7 on the samples) | 4.5e-4 stages, 4e-5 samples |
| Mimi all at once against frame by frame (F = 4, F = 20) | 0, 3.5e-8 | 0, 8.2e-5 |
| Mimi on the reference's latents, 25 frames | 2.1e-6 | 5.5e-4 |
| Free run, temperature 0: frames, EOS step | 25, 22 (as the reference) | 25, 22 |
| Free run, temperature 0: latents, EOS logits, all samples, first frame | 2.6e-4, 7.8e-5, 1.5e-4, 9e-7 | 4.8e-5, 5.8e-5, 4.9e-4, 3.6e-4 |
| Free run, temperature 0.3 with the recorded noise: frames, EOS, samples | 24, 21 (as the reference), 5.4e-5 | 24, 21, 9.3e-4 |

The test holds the CPU to 5e-6 on the first latent, 1e-3 on the later ones and the EOS logits (25
autoregressive frames let rounding drift that far), 1e-5 on the first samples, and 13.2's digits on
the Mimi decoder; the device test allows 1e-3 on samples. Metal differs more in Mimi for one reason:
ggml-metal's f32 matrix-matrix kernel (`kernel_mul_mm_f32_f32`, used from 9 columns on) keeps its
tiles in `half`. The FlowLM step is a matrix-vector product there, exact in f32, so only the audio
moves, and nothing feeds audio back into generation.

### Speed

Apple M4 (4 performance, 6 efficiency cores), wall clock (`ml.now`), best of three, while other
agents kept the machine at a load average of 4 to 8, so a quiet machine does somewhat better. "Short"
is "Hello world, this is a test." (8 tokens, 1.9 s of audio); "long" is three sentences (46 tokens,
11.3 s). Time to first audio counts from `speak`'s call to the first `on_audio`.

| Engine, file | first audio, short | first audio, long | real time |
|---|---|---|---|
| CPU, 4 threads, F32 or f16 file | 23 ms | 78 ms | 5.8x to 6.1x |
| CPU, 8 threads | 21 ms | 60 ms | 6.7x to 7.0x |
| Metal, F32 file | 13 ms | 17 to 27 ms | 6.5x to 10.3x |
| Metal, f16 file | 12 ms | 13 to 15 ms | 9.9x to 11.9x |
| Lua 5.5: CPU F32 / Metal f16 | 24 ms / 15 ms | 78 ms / 19 ms | 6.0x / 9.0x |

Per frame on the CPU: the FlowLM step about 6 ms (it reads 340 MB of F32 weights; bandwidth-bound)
and the Mimi decode about 6 ms; the prompt pass of 41 tokens 51 ms at 4 threads (compute-bound, the
long text's first audio). On Metal with the f16 file: step about 4.5 ms, Mimi 3.5 ms, prompt 12 ms;
the 509 small kernels of a frame make launch overhead a real share. The package's README reports
~200 ms to the first audio and ~6x real time on an M4 in Python.

### What remains

- **An engine hazard, worked around here.** ggml's graph allocator reuses a graph's previous plan
  whenever the new graph has as many nodes and leaves and every size fits (`ggml_gallocr_needs_realloc`
  compares sizes only). A graph of the same shape with other outputs marked (a tap) then reads a
  tensor whose memory the old plan gave to a later node. `pocket_tts.lua` builds every call that has
  taps in a graph of its own. The fix belongs in `graph_compute` in `core.c` (force a fresh plan
  when a graph's outputs change); `gemma4.lua`'s taps can read garbage the same way.
- **Voice cloning** (the Mimi encoder, 8.5 and 10.4) is not ported; the ungated weights zero it.
- **Other checkpoints** (german, italian, portuguese, spanish, the 24-layer ones) are untested; the
  converter writes the english config's constants rather than reading a config.
- **Text.** `prepare` upper-cases and strips ASCII only; Python's `str.upper` and `strip` are Unicode.
  Seeds do not reproduce Python's draws (only recorded noise does): `ml.rng` is not torch's generator.
- **Speed.** Python overlaps the FlowLM and Mimi on two threads; here they run one after the other,
  and overlapping them would need an asynchronous compute in the engine. The Mimi decoder could run
  on the CPU beside a GPU FlowLM for exact audio on Metal. Q8_0 FlowLM weights were not tried.
