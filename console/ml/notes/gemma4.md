# Gemma 4 E2B-it on ggml: an implementation spec

This note is enough to write the Gemma 4 E2B text forward pass, the tokenizer and the chat
loop on bare ggml, without linking llama.cpp and without looking anything else up. Every number
below was read from a primary source on 2026-09-10:

| source | pinned at |
|---|---|
| llama.cpp (the ground truth for the math) | `df03399b885831b2a1603b3abb0d8c156808e363` (2026-09-10) |
| transformers `models/gemma4/modeling_gemma4.py` (cross-check) | `93ebf6b1` (2026-09-10) |
| transformers `modeling_rope_utils.py` | `5b7dcb0d` (2026-09-09) |
| `google/gemma-4-E2B-it` config, generation config, chat template, safetensors header | repo sha `3e22461f` |
| GGUF headers (metadata + tensor tables), read with HTTP range requests | the files in section 1 |
| ggml the console builds against (`console/ml/fetch-ggml.sh`) | `7840aaba` (2026-09-09) |

Line numbers such as `src/models/gemma4.cpp:154-436` refer to those commits. No model weights
were downloaded for this note. Only headers, a few small F32 tensors and the 15.8 MB vocab-only
GGUF were fetched.

The pinned ggml already has every op the port needs: `ggml_get_rows` (all quant types),
`ggml_rms_norm`, `ggml_mul`, `ggml_add`, `ggml_scale`, `ggml_mul_mat`, `ggml_rope_ext` with
freq factors in NEOX mode, `ggml_geglu_split`, `ggml_gelu`, `ggml_tanh`, `ggml_set_rows`,
`ggml_soft_max_ext`, `ggml_flash_attn_ext` (Metal supports head sizes 256 and 512),
`ggml_permute`, `ggml_cont`, `ggml_view_*` and `ggml_prec_set_acc`.

---

## 1. Which file to use

Gemma 4 is **Apache 2.0**, not the Gemma Terms of Use that covered Gemma 1-3. Every repo below
declares `license: apache-2.0`, and `general.license` inside the GGUFs says the same. The license
page (https://ai.google.dev/gemma/docs/gemma_4_license) states Apache 2.0 and also links a
prohibited-use policy and an intended-use statement. None of the repos is gated.

The GGUFs are about 3 GB at 4 bits even though the model is called "2B". That is because 1.3-2.5 GB
of each file is the per-layer embedding table (section 2.3). That table is only ever read with
`get_rows`, so it can stay memory-mapped and never has to reach the GPU.

| use | file | bytes | sha256 | text tensor types |
|---|---|---|---|---|
| **Primary: the port's weights** | `google/gemma-4-E2B-it-qat-q4_0-gguf` / `gemma-4-E2B_q4_0-it.gguf` | 3,349,516,256 | `fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634` | Q4_0 matrices, Q6_K `token_embd` and `per_layer_token_embd`, F16 `per_layer_model_proj`, F32 norms |
| Smallest | `ggml-org/gemma-4-E2B-it-GGUF` / `gemma-4-E2B-it-Q4_0.gguf` | 2,841,481,184 | `8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52` | Q4_0 matrices and PLE table, Q8_0 `token_embd`, BF16 `per_layer_model_proj` |
| High-fidelity reference | `ggml-org/gemma-4-E2B-it-GGUF` / `gemma-4-E2B-it-Q8_0.gguf` | 4,967,497,152 | `996d08777aadc6bfd3c7375ef70ba25a0f55240075860754fdb18d6d860aa63a` | Q8_0 everywhere, BF16 `per_layer_model_proj` |
| K-quant alternative | `unsloth/gemma-4-E2B-it-GGUF` / `gemma-4-E2B-it-Q4_K_M.gguf` | 3,106,738,272 | `740185b21d22ceb83a11c3aa62ad5842ef32c70f6096d756bbee85a1e4ec34b8` | Q4_K and Q6_K mix, Q5_K PLE table, F32 `inp_gate`/`proj`, imatrix |

Exact download URLs:

```
https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/gemma-4-E2B_q4_0-it.gguf
https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_0.gguf
https://huggingface.co/ggml-org/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q8_0.gguf
https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf
```

Pick the Google QAT Q4_0 file for the port. It is Google's own quantization-aware-trained
checkpoint, so quality is close to bf16 at 4 bits, and it uses only four tensor types (Q4_0,
Q6_K, F16, F32). The ggml-org Q4_0 is 500 MB smaller but is a plain post-training quant. Keep
the ggml-org Q8_0 as the reference to diff against. Other files in the same repos: BF16 GGUFs
(9.3 GB), `mmproj-*` vision+audio towers (557 MB at Q8_0, 987 MB at BF16), and `mtp-*` drafters
for speculative decoding (59-170 MB; the architecture is `gemma4_assistant`, out of scope here).
The README says a QAT target needs a QAT drafter of the same precision.

The HF original is `google/gemma-4-E2B-it/model.safetensors`: 10.2 GB of bf16, with the
language model under `model.language_model.*` and the towers under `model.vision_tower.*`,
`model.audio_tower.*`, `model.embed_vision.*` and `model.embed_audio.*`.

---

## 2. Hyperparameters

### 2.1 GGUF metadata (identical in all four files except `general.*` and `file_type`)

```
general.architecture                        = "gemma4"        # llama.cpp LLM_ARCH_GEMMA4; 35 layers -> LLM_TYPE_E2B
general.size_label                          = "4.6B"
gemma4.block_count                          = 35
gemma4.context_length                       = 131072
gemma4.embedding_length                     = 1536
gemma4.feed_forward_length                  = [6144 x15, 12288 x20]          # per layer (see 2.3)
gemma4.attention.head_count                 = 8
gemma4.attention.head_count_kv              = 1                              # MQA, every layer
gemma4.attention.key_length                 = 512                            # full-attention layers
gemma4.attention.value_length               = 512
gemma4.attention.key_length_swa             = 256                            # sliding layers
gemma4.attention.value_length_swa           = 256
gemma4.rope.dimension_count                 = 512                            # full layers: n_rot = whole head
gemma4.rope.dimension_count_swa             = 256
gemma4.rope.freq_base                       = 1000000.0                      # full layers
gemma4.rope.freq_base_swa                   = 10000.0                        # sliding layers
gemma4.attention.sliding_window             = 512
gemma4.attention.sliding_window_pattern     = [T,T,T,T,F] x7                 # bool per layer, True = sliding
gemma4.attention.shared_kv_layers           = 20
gemma4.attention.layer_norm_rms_epsilon     = 1e-6
gemma4.embedding_length_per_layer_input     = 256
gemma4.final_logit_softcapping              = 30.0
general.sampling.top_k = 64, general.sampling.top_p = 0.95, general.sampling.temp = 1.0
tokenizer.ggml.model = "gemma4", add_bos_token = true, add_space_prefix = false
tokenizer.ggml.bos/eos/unk/pad/mask_token_id = 2 / 1 / 3 / 0 / 4
```

There is no attention-softcapping key. Gemma 3 dropped attention softcapping and Gemma 4 keeps
it dropped (`conversion/gemma.py` asserts `attn_logit_softcapping is None`).

### 2.2 The same model from the HF `text_config`

`hidden_size 1536`, `num_hidden_layers 35`, `num_attention_heads 8`, `num_key_value_heads 1`,
`head_dim 256` (sliding), `global_head_dim 512` (full), `intermediate_size 6144`,
`use_double_wide_mlp true`, `num_kv_shared_layers 20`, `hidden_size_per_layer_input 256`,
`vocab_size 262144`, `vocab_size_per_layer_input 262144`, `sliding_window 512`,
`max_position_embeddings 131072`, `rms_norm_eps 1e-6`, `final_logit_softcapping 30.0`,
`hidden_activation gelu_pytorch_tanh`, `tie_word_embeddings true`, `attention_bias false`,
`attention_k_eq_v false`, `enable_moe_block false`, `use_bidirectional_attention null`
(causal everywhere),
`rope_parameters.sliding_attention = {rope_type default, rope_theta 10000}`,
`rope_parameters.full_attention = {rope_type proportional, partial_rotary_factor 0.25, rope_theta 1e6}`.
Special ids in the HF config: `eos_token_id [1, 106]`, `bos 2`, `pad 0`, `boi 255999`, `boa 256000`,
`image 258880`, `audio 258881`, `eoi 258882`, `eoa 258883`, `video 258884`.

### 2.3 Derived per-layer layout (35 layers, `il` = 0..34)

| | layers | head_dim | q / k / v width | n_rot | RoPE base | freq factors | FFN width | K/V |
|---|---|---|---|---|---|---|---|---|
| sliding, owns K/V | 0-3, 5-8, 10-13 (12 layers) | 256 | 2048 / 256 / 256 | 256 | 10 000 | none | 6144 | computes and caches |
| full, owns K/V | 4, 9, 14 (3 layers) | 512 | 4096 / 512 / 512 | 512 | 1 000 000 | `rope_freqs` | 6144 | computes and caches |
| sliding, shared | 15-18, 20-23, 25-28, 30-33 (16 layers) | 256 | 2048 / - / - | 256 | 10 000 | none | 12288 | reads layer **13**'s cache |
| full, shared | 19, 24, 29, 34 (4 layers) | 512 | 4096 / - / - | 512 | 1 000 000 | `rope_freqs` | 12288 | reads layer **14**'s cache |

- A layer is sliding iff `il % 5 != 4`, so the last layer (34) is full. That matches HF
  `layer_types` and the GGUF `sliding_window_pattern`.
- KV sharing: `n_layer_kv_from_start = 35 - 20 = 15`, so layers 0-14 own a cache. A layer
  `il >= 15` reuses layer `15 - 2 = 13` if it is sliding and layer `15 - 1 = 14` if it is full.
  This comes from `src/llama-model.cpp:2631-2641`, and it is HF's `store_full_length_kv` rule:
  "the last non-shared layer of the same type".
- The FFN is double width (12288) exactly on the KV-shared layers. That is HF `use_double_wide_mlp`,
  and the converter writes the per-layer array (`conversion/gemma.py:706-712`).
- The attention scale is **1.0**, not `1/sqrt(head_dim)`. Q and K are RMS-normalised per head, so
  no further scaling is applied (`src/models/gemma4.cpp:11`; HF `self.scaling = 1.0`).
- Embedding scale is `sqrt(1536) = 39.191837`. The PLE table scale is `sqrt(256) = 16`. The PLE
  projection scale is `1/sqrt(1536) = 0.025515518`. The PLE combine scale is
  `1/sqrt(2) = 0.70710678`.
- Compute per token is about 1.88 GMAC in the blocks plus 0.40 GMAC in the tied LM head, 2.28
  GMAC in total. That is the "2.3B effective".

### 2.4 What the "E" design keeps from Gemma 3n and what it drops

| Gemma 3n feature | Gemma 4 E2B | evidence |
|---|---|---|
| Per-layer embeddings (PLE) | **kept**, 256 per layer x 35 layers | `per_layer_*`, `inp_gate`, `proj`, `post_norm` tensors |
| KV-cache sharing across layers | **kept**, last 20 of 35 layers | `shared_kv_layers = 20` |
| q_norm / k_norm, unweighted v_norm, attention scale 1.0 | **kept** | graph lines 224, 255-256 |
| AltUp (4 parallel residual streams) | **dropped** | no `altup_*` tensors; the HF blog says Gemma 4 "leaves out ... AltUp" |
| LAuReL low-rank residual | **dropped** | no `laurel_*` tensors |
| Activation sparsity (gaussian top-k in early FFNs) | **dropped** | no config key; no top-k op in `gemma4.cpp` |
| MatFormer per-layer FFN widths | **replaced**: uniform 6144, doubled to 12288 on the shared layers | `feed_forward_length` array |
| New in Gemma 4 | per-layer `layer_output_scale` that multiplies the whole residual; dual head dims (256 sliding, 512 full); proportional RoPE on full layers; new chat tokens; BPE tokenizer | sections 3-5 |

---

## 3. GGUF tensors

ggml shape order is `ne = [ne0, ne1]`, where `ne0` is the contiguous input dimension. A weight
`W` with `ne = [in, out]` is applied as `ggml_mul_mat(W, x[in, T]) -> [out, T]`.

### 3.1 Global tensors

| GGUF name | ne | QAT Q4_0 | ggml Q4_0 | ggml Q8_0 | HF name (`model.language_model.` omitted) |
|---|---|---|---|---|---|
| `token_embd.weight` | [1536, 262144] | Q6_K | Q8_0 | Q8_0 | `embed_tokens.weight`; also the tied LM head (there is no `output.weight`) |
| `per_layer_token_embd.weight` | [8960, 262144] | Q6_K | Q4_0 | Q8_0 | `embed_tokens_per_layer.weight` (8960 = 35 x 256) |
| `per_layer_model_proj.weight` | [1536, 8960] | F16 | BF16 | BF16 | `per_layer_model_projection.weight` |
| `per_layer_proj_norm.weight` | [256] | F32 | F32 | F32 | `per_layer_projection_norm.weight` |
| `output_norm.weight` | [1536] | F32 | F32 | F32 | `norm.weight` |
| `rope_freqs.weight` | [256] | F32 | F32 | F32 | *generated by the converter*: 64 x `1.0` then 192 x `1e30` |

### 3.2 Per-layer tensors, `blk.N.*` for N = 0..34

`hd` is 256 on sliding layers and 512 on full layers. `ff` is 6144 for N < 15 and 12288 for N >= 15.

| GGUF name | ne | type (QAT / ggml Q4_0 / Q8_0) | HF name (`layers.N.`) | used by |
|---|---|---|---|---|
| `attn_norm.weight` | [1536] | F32 | `input_layernorm` | all |
| `attn_q.weight` | [1536, 8*hd] | Q4_0 / Q4_0 / Q8_0 | `self_attn.q_proj` | all |
| `attn_q_norm.weight` | [hd] | F32 | `self_attn.q_norm` | all |
| `attn_k.weight` | [1536, hd] | Q4_0 / Q4_0 / Q8_0 | `self_attn.k_proj` | N < 15 only |
| `attn_k_norm.weight` | [hd] | F32 | `self_attn.k_norm` | N < 15 only |
| `attn_v.weight` | [1536, hd] | Q4_0 / Q4_0 / Q8_0 | `self_attn.v_proj` | N < 15 only |
| `attn_output.weight` | [8*hd, 1536] | Q4_0 / Q4_0 / Q8_0 | `self_attn.o_proj` | all |
| `post_attention_norm.weight` | [1536] | F32 | `post_attention_layernorm` | all |
| `ffn_norm.weight` | [1536] | F32 | `pre_feedforward_layernorm` | all |
| `ffn_gate.weight` | [1536, ff] | Q4_0 / Q4_0 / Q8_0 | `mlp.gate_proj` | all |
| `ffn_up.weight` | [1536, ff] | Q4_0 / Q4_0 / Q8_0 | `mlp.up_proj` | all |
| `ffn_down.weight` | [ff, 1536] | Q4_0 / Q4_0 / Q8_0 | `mlp.down_proj` | all |
| `post_ffw_norm.weight` | [1536] | F32 | `post_feedforward_layernorm` | all |
| `inp_gate.weight` | [1536, 256] | Q4_0 / Q4_0 / Q8_0 | `per_layer_input_gate` | all |
| `proj.weight` | [256, 1536] | Q4_0 / Q4_0 / Q8_0 | `per_layer_projection` | all |
| `post_norm.weight` | [1536] | F32 | `post_per_layer_input_norm` | all |
| `layer_output_scale.weight` | [1] | F32 | `layer_scalar` | all |

Tensor counts: the QAT and ggml-org Q4_0 files hold **541** tensors, because they omit
`attn_k`, `attn_v` and `attn_k_norm` on layers 15-34. The ggml-org Q8_0 and unsloth files hold
**601** tensors, because they keep those 60 dead tensors, copied from the HF checkpoint. The
loader must accept both: those tensors are optional for N >= 15 and must be ignored when present.
In the unsloth Q4_K_M file, `attn_v` and `ffn_down` are Q6_K on 17 layers and Q4_K on the rest.
There is no `wqkv` (fused QKV) in any of these files. llama.cpp accepts one since 2026-09-06 (a
`--fuse-qkv` converter flag), so a future file may carry `blk.N.attn_qkv.weight` instead of Q/K/V.

The text model has 4.63 B parameters. Byte breakdown of the QAT file: PLE table 1927 MB,
`token_embd` 330 MB, blocks 1049 MB, `per_layer_model_proj` 27.5 MB. The GGUF data section
starts at the header end rounded up to `general.alignment`, which is 32 by default.

Sanity values read from the Q8_0 file. Their size proves that norm weights are used as-is and
there is no `(1 + w)`: `output_norm` mean 14.17, `blk.0.attn_norm` mean 10.67,
`blk.0.attn_q_norm` all 0.984, `blk.0.attn_k_norm` all 0.127, `per_layer_proj_norm` mean 0.765.
`layer_output_scale` per layer, 0..34:

```
0.01782 0.2227 0.7930 0.2871 0.4980 0.6367 0.4980 0.6094 0.3770 0.4648 0.4434 0.3691
0.3242 0.08838 0.02856 0.2539 0.5859 0.6563 0.6016 0.5391 0.4941 0.6445 0.6328 0.4316
0.4375 0.7852 0.8242 0.8203 0.8203 0.8125 0.8711 0.8281 0.8711 0.6953 0.1670
```

### 3.3 Multimodal packaging (not needed for text)

The towers live in a separate `mmproj` GGUF (`general.architecture = "clip"`, 1411 tensors).
It holds a 16-layer ViT (`v.blk.*`, hidden 768, 12 heads, patch 16, `projector_type gemma4v`), a
12-layer conformer audio encoder (`a.blk.*`, hidden 1024, 8 heads, 128 mel bins,
`projector_type gemma4a`), and projections into the text width: `mm.input_projection` [768 -> 1536]
and `mm.a.input_projection` [1536 -> 1536]. The main GGUF contains no vision or audio weights.
When the text model is fed embeddings instead of tokens, llama.cpp skips the `sqrt(n_embd)` scale
and uses PLE row 0 (the pad token) for those positions (`gemma4.cpp:164, 456-469`). An image
becomes `<|image>` 255999 ... soft tokens ... `<image|>` 258882, with 280 soft tokens by default.

---

## 4. The forward pass

### 4.1 Reference code (llama.cpp `df03399b`)

| what | where |
|---|---|
| hparams, tensor creation, whole graph | `src/models/gemma4.cpp:3-34`, `:36-141`, `:154-436` |
| PLE token part / context part | `src/models/gemma4.cpp:440-471` / `:478-498` |
| `build_norm` (RMS, then `mul` by w) | `src/llama-graph.cpp:1583-1616` |
| `build_ffn` (GELU + PAR becomes `ggml_geglu_split`) | `src/llama-graph.cpp:1748-1947` |
| `build_attn_mha` (flash and non-flash) | `src/llama-graph.cpp:2591-2727` |
| `build_attn` for the ISWA cache (write K/V, pick cache and mask by layer type) | `src/llama-graph.cpp:3077-3162` |
| KV reuse map for Gemma 3n and 4 | `src/llama-model.cpp:2628-2641`; applied at `src/llama-kv-cache.cpp:252-274` |
| `has_kv` | `src/llama-hparams.cpp:320-331` |
| SWA mask rule | `src/llama-hparams.h:466-478` |
| SWA cache size | `src/llama-kv-cache-iswa.cpp:69-81` |
| RoPE type (NEOX for GEMMA4) | `src/llama-model.cpp:2983-3022` |
| per-layer RoPE base/scale | `src/llama-model.cpp:2224-2230` |
| `rope_freqs` generation | `conversion/gemma.py:713-761` |
| norm shift is 0 for Gemma 4 (Gemma 3 adds 1) | `conversion/gemma.py:636-638` vs `:130-131` |

HF cross-check in `modeling_gemma4.py@93ebf6b1`: `Gemma4RMSNorm` 197-215, `Gemma4TextMLP` 1061-1078,
RoPE 1080-1160, `Gemma4TextAttention` 1162-1277, `Gemma4TextDecoderLayer` 1355-1441,
`Gemma4TextModel` (embedding, PLE, layer loop) 1560-1789, softcap 1862-1867. Proportional RoPE
is in `modeling_rope_utils.py:193-265`.

### 4.2 Constants and notation

```
E = 1536, H = 8, HKV = 1, L = 35, P = 256 (PLE width), V = 262144, eps = 1e-6
swa(il) = (il % 5 != 4);  hd(il) = swa ? 256 : 512;  ff(il) = il < 15 ? 6144 : 12288
kv_src(il) = il < 15 ? il : (swa(il) ? 13 : 14)
rope(il): n_dims = hd(il), mode = GGML_ROPE_TYPE_NEOX (2), n_ctx_orig = 131072,
          freq_base = swa ? 10000 : 1e6, freq_scale = 1, ext_factor = 0, attn_factor = 1,
          beta_fast = 32, beta_slow = 1, freq_factors c = swa ? NULL : rope_freqs.weight
RMS(x, w) = ggml_mul(ctx, ggml_rms_norm(ctx, x, eps), w)      # w used as-is
T = tokens in this call (T = 1 for a decode step)
```

### 4.3 Graph inputs

| tensor | type, ne | content |
|---|---|---|
| `tok` | I32 [T] | token ids |
| `pos` | I32 [T] | absolute positions |
| `mask_full` | F16 [n_kv, T] for flash attention, F32 for soft_max | 0 where key cell j is visible to query i, `-INFINITY` otherwise; visible iff the cell holds a position p0 with p0 <= p1, where p1 = pos[i] |
| `mask_swa` | same, over the sliding cache | as above and also `p1 - p0 < 512` (llama.cpp masks when `p1 - p0 >= n_swa`) |
| `kidx_full`, `kidx_swa` | I64 [T] | the cache row each new token's K/V is written to |
| `out_ids` | I32 [n_out] | rows whose logits are wanted (for a prompt, only the last one) |

Unused or empty cells must be `-INF` in both masks. llama.cpp pads `n_kv` up to a multiple of 256
only so that it can reuse the graph; a port can use `n_kv` = used cells. Neither
`ggml_flash_attn_ext` nor `ggml_soft_max_ext` needs the mask's T dimension padded in this ggml.

### 4.4 Token embedding and per-layer inputs (once per call)

```
1. x      = ggml_get_rows(token_embd, tok)                 # [1536, T] F32 (dequantised)
2. x      = ggml_scale(x, sqrtf(1536))                     # "inp_scaled"
3. ple_t  = ggml_get_rows(per_layer_token_embd, tok)       # [8960, T]
4. ple_t  = ggml_reshape_3d(ple_t, 256, 35, T)
5. ple_t  = ggml_scale(ple_t, 16.0f)                       # sqrt(256); "inp_per_layer_selected"
6. ple_c  = ggml_mul_mat(per_layer_model_proj, x)          # [8960, T]  (uses the *scaled* x)
7. ple_c  = ggml_scale(ple_c, 1.0f/sqrtf(1536))
8. ple_c  = ggml_reshape_3d(ple_c, 256, 35, T)
9. ple_c  = RMS(ple_c, per_layer_proj_norm)                # normalises each 256-slice; "per_layer_proj"
10. ple   = ggml_scale(ggml_add(ple_c, ple_t), 1.0f/sqrtf(2))          # "inp_per_layer"
11. ple   = ggml_cont(ggml_permute(ple, 0, 2, 1, 3))                    # [256, T, 35]
    ple_l(il) = ggml_view_2d(ple, 256, T, ple->nb[1], il*ple->nb[2])  # [256, T] slice for layer il
```

llama.cpp quote (`gemma4.cpp:478-497`, abridged):

```cpp
per_layer_proj = ggml_mul_mat   (ctx0, model.per_layer_model_proj, inp_batch);
per_layer_proj = ggml_scale     (ctx0, per_layer_proj, 1.0f / sqrtf((float) n_embd));
per_layer_proj = ggml_reshape_3d(ctx0, per_layer_proj, n_embd_per_layer, n_layer, n_tokens);
per_layer_proj = build_norm(per_layer_proj, model.per_layer_proj_norm, nullptr, LLM_NORM_RMS, -1);
inp_per_layer  = ggml_add  (ctx0, per_layer_proj, inp_per_layer);
inp_per_layer  = ggml_scale(ctx0, inp_per_layer, 1.0f / sqrtf(2.0f));
inp_per_layer  = ggml_cont(ctx0, ggml_permute(ctx0, inp_per_layer, 0, 2, 1, 3));
```

### 4.5 One decoder layer, `il` = 0..34

```
 1. h   = RMS(x, attn_norm)                                             # [1536, T]  "attn_norm-il"
 2. q   = ggml_mul_mat(attn_q, h)                                       # [8*hd, T]
 3. q   = ggml_reshape_3d(q, hd, 8, T)
 4. q   = RMS(q, attn_q_norm)                                           # per head, over hd
 5. q   = ggml_rope_ext(q, pos, c, hd, NEOX, 131072, base, 1, 0, 1, 32, 1)   # "Qcur_pos-il"
    if il < 15:                                                          # this layer owns K/V
 6.   k = ggml_reshape_3d(ggml_mul_mat(attn_k, h), hd, 1, T)
 7.   v = ggml_reshape_3d(ggml_mul_mat(attn_v, h), hd, 1, T)
 8.   k = RMS(k, attn_k_norm)
 9.   v = ggml_rms_norm(v, eps)                                         # no weight
10.   k = ggml_rope_ext(k, pos, c, hd, NEOX, 131072, base, 1, 0, 1, 32, 1)
11.   expand(ggml_set_rows(Kcache[il], ggml_view_2d(k, hd, T, ...), kidx))  # F16 cache
      expand(ggml_set_rows(Vcache[il], ggml_view_2d(v, hd, T, ...), kidx))
12. K   = view of Kcache[kv_src(il)] as [hd, 1, n_kv];  V likewise; mask = swa ? mask_swa : mask_full
13. attention (kq_scale = 1.0f, no softcap, no ALiBi):
      Qp = ggml_permute(q, 0,2,1,3)            # [hd, T, 8]
      Kp = ggml_permute(K, 0,2,1,3)            # [hd, n_kv, 1]
      Vp = ggml_permute(V, 0,2,1,3)            # [hd, n_kv, 1]
    flash:  o = ggml_flash_attn_ext(Qp, Kp, Vp, mask_f16, 1.0f, 0.0f, 0.0f)
            ggml_prec_set_acc(o, GGML_PREC_F32)                          # -> [hd, 8, T]
            o = ggml_reshape_2d(o, hd*8, T)
    plain:  kq = ggml_mul_mat(Kp, Qp); ggml_prec_set_acc(kq, GGML_PREC_F32)   # [n_kv, T, 8]
            kq = ggml_soft_max_ext(kq, mask_f32, 1.0f, 0.0f)
            o  = ggml_mul_mat(Vt, kq)          # Vt = V stored transposed, [n_kv, hd, 1]
            o  = ggml_cont_2d(ggml_permute(o, 0,2,1,3), hd*8, T)
14. o   = ggml_mul_mat(attn_output, o)                                  # [1536, T]  "kqv_out-il"
    (il == 34, optional: o = get_rows(o, out_ids); x = get_rows(x, out_ids); ple_l = get_rows(ple_l, out_ids))
15. o   = RMS(o, post_attention_norm)                                   # "attn_post_norm-il"
16. a   = ggml_add(o, x)                                                # "attn_out-il"
17. f   = RMS(a, ffn_norm)
18. f   = ggml_geglu_split(ggml_mul_mat(ffn_gate, f), ggml_mul_mat(ffn_up, f))   # gelu_tanh(gate) * up
19. f   = ggml_mul_mat(ffn_down, f)                                     # [1536, T]  "ffn_out-il"
20. f   = RMS(f, post_ffw_norm)
21. y   = ggml_add(f, a)                                                # "pe_in-il"
22. p   = ggml_gelu(ggml_mul_mat(inp_gate, y))                          # [256, T] (tanh GELU)
23. p   = ggml_mul(p, ple_l(il))
24. p   = RMS(ggml_mul_mat(proj, p), post_norm)                         # [1536, T] "per_layer_embd_out-il"
25. y   = ggml_add(y, p)
26. x   = ggml_mul(y, layer_output_scale)                               # [1] broadcast; "out_scaled-il", "l_out-il"
```

llama.cpp quotes for the parts that are easy to get wrong:

```cpp
// gemma4.cpp:222-229: Q is normed per head, then roped
Qcur = ggml_reshape_3d(ctx0, Qcur, n_embd_head, n_head, n_tokens);
Qcur = build_norm(Qcur, model.layers[il].attn_q_norm, nullptr, LLM_NORM_RMS, il);
Qcur = ggml_rope_ext(ctx0, Qcur, inp_pos, freq_factors, n_rot_l, rope_type, n_ctx_orig,
                     freq_base_l, freq_scale_l, ext_factor, attn_factor, beta_fast, beta_slow);
// gemma4.cpp:252-262: K normed with weight, V normed without, only K roped
Kcur = build_norm(Kcur, model.layers[il].attn_k_norm, nullptr, LLM_NORM_RMS, il);
Vcur = ggml_rms_norm(ctx0, Vcur, hparams.f_norm_rms_eps);
Kcur = ggml_rope_ext(ctx0, Kcur, inp_pos, freq_factors, ...);
// gemma4.cpp:269-274: shared layers pass no K/V and read an earlier layer's cache
cur = build_attn(inp_attn, model.layers[il].wo, nullptr, model.layers[il].wo_s,
                 Qcur, nullptr, nullptr, nullptr, nullptr, nullptr, hparams.f_attention_scale, il);
// gemma4.cpp:367-395: per-layer embedding block, then the layer scalar on the whole stream
cur = build_lora_mm(model.layers[il].per_layer_inp_gate, cur);  cur = ggml_gelu(ctx0, cur);
cur = ggml_mul(ctx0, cur, inp_this_layer);
cur = build_lora_mm(model.layers[il].per_layer_proj, cur);
cur = build_norm(cur, model.layers[il].per_layer_post_norm, nullptr, LLM_NORM_RMS, il);
cur = ggml_add(ctx0, pe_in, cur);
cur = ggml_mul(ctx0, cur, model.layers[il].out_scale);
```

The FFN comes from `build_ffn(..., LLM_FFN_GELU, LLM_FFN_PAR)`, which reduces to
`cur = ggml_geglu_split(ctx0, gate_out, up_out)` (`llama-graph.cpp:1857-1862`). The first
argument is the one passed through GELU.

### 4.6 Output head

```
1. x      = RMS(x, output_norm)                            # "result_norm"
2. x      = ggml_get_rows(x, out_ids)                      # if not already done at layer 34
3. logits = ggml_mul_mat(token_embd, x)                    # [262144, n_out]; tied weights
4. logits = ggml_scale(ggml_tanh(ggml_scale(logits, 1/30.0f)), 30.0f)   # "result_output"
```

### 4.7 KV cache, and a decode step versus a prompt batch

The graph is the same for T = 1 and T = n. What changes between them is the masks, the write
indices and `out_ids`.

- **Storage.** Only layers 0-14 own cache tensors: 12 sliding layers with K and V each
  [256, n_cells] F16, and 3 full layers with K and V each [512, n_cells] F16. Layers 15-34 own
  nothing. In llama.cpp, `map_layer_ids[il] = map_layer_ids[reuse(il)]`, so `get_k(il)` for a
  shared layer is a view of layer 13's or layer 14's buffer, while the mask comes from the cache
  whose type matches the layer. For flash attention, store V un-transposed like K. The soft_max
  path wants V transposed ([n_cells, hd]); llama.cpp's non-transposed fallback is marked
  "avoid this branch".
- **Size.** With full-size caches (the simplest first port) the cost is
  12 x 2 x 256 x 2 B + 3 x 2 x 512 x 2 B = 18 KiB per token of context: 144 MiB at 8K and
  2.25 GiB at 128K. llama.cpp instead gives the sliding layers a ring of
  `pad256(min(n_ctx, 512 + n_ubatch))` cells, which makes long contexts cheap: 6 KiB per token for
  the full layers plus a fixed sliding part. A ring must hold at least `512 + T - 1` cells for a
  batch of T.
- **Decode step (T = 1).** `pos = [n_past]`. Write K/V for layers 0-14 at the cell for `n_past`,
  build the masks over all cells holding positions <= n_past (and within 512 for the sliding
  mask), and set `out_ids = [0]`.
- **Prompt batch.** Feed up to `n_ubatch` tokens per call; llama.cpp defaults to 512. Mask entry
  (i, j) is visible iff `pos_j <= pos_i`, and for the sliding mask also `pos_i - pos_j < 512`.
  Keys include tokens of the same batch, which were written in step 11 of the same graph. Set
  `out_ids = [T-1]` so that the 262144-wide LM head runs once.
- **Ordering inside one graph.** A shared layer reads K/V that layer 13 or 14 wrote in the same
  graph, and a layer's own attention reads the rows it just wrote. The cache view carries no ggml
  dependency on the `set_rows` node. llama.cpp gets the order right by calling
  `ggml_build_forward_expand` on the write before building the attention that reads the cache
  (`llama-graph.cpp:3109-3141`). Do the same.
- **Hadamard rotation.** llama.cpp rotates Q/K/V with a Hadamard matrix only when the KV cache
  type is *quantized* (`llama-kv-cache.cpp:321-339`; disable with `LLAMA_ATTN_ROT_DISABLE=1`).
  With an F16 cache, which is the default and what this spec assumes, there is no rotation.

---

## 5. Tokenizer and chat template

### 5.1 Type and data

The tokenizer is **BPE with merges**, not SentencePiece unigram, stored as
`tokenizer.ggml.model = "gemma4"`. It uses the SPM-style `▁` for spaces and `<0xXX>` byte fallback.

- `tokenizer.ggml.tokens`: 262144 strings. `tokenizer.ggml.merges`: 514906 strings of the form
  `"left right"`, where the array index is the rank and a lower rank merges first.
- `tokenizer.ggml.scores`: all -1000, so ignore them.
- `tokenizer.ggml.token_type`: 1 normal (261864), 3 control (17), 4 user-defined (7), 6 byte (256).
- Byte tokens `<0x00>`..`<0xFF>` are ids 238..493, so `id = 238 + byte`. `▁` (U+2581) is id 236743.
- HF `tokenizer.json` agrees: normalizer `Replace(" " -> "▁")`, model BPE with
  `byte_fallback: true` and `ignore_merges: false`, and no prefix space. Its `Split(" ")`
  pre-tokenizer never fires, because the normalizer has already removed every space.

### 5.2 Encoding (what llama.cpp does, `src/llama-vocab.cpp`)

1. **Special-token split** (`tokenizer_st_partition`, from line 3228). Scan the raw text for the
   text of every CONTROL, USER_DEFINED or UNKNOWN token, longest first. USER_DEFINED tokens are
   always matched. CONTROL tokens are matched only when parse_special is on, which it must be for
   chat prompts. Matched spans become their ids directly.
2. For each remaining text fragment, replace every `" "` with `"▁"` (line 3361). Apply no other
   normalization: no NFKC and no prefix space.
3. Split the fragment with the regex `[^\n]+|[\n]+` (lines 522-531). No token and no merge in
   this vocab mixes newlines with other characters (I checked all 514906 merges), so this split
   is exact.
4. If a piece is all newlines and the whole piece is a token (ids 107.. hold `\n`, `\n\n`, ...),
   emit it (lines 631-637). Otherwise start from one symbol per UTF-8 codepoint and repeatedly
   merge the adjacent pair with the lowest merge rank. Break ties by the leftmost pair
   (comparator at line 267). Stop when no adjacent pair has a rank.
5. Map each final symbol to its id. If a symbol is not in the vocab, emit one `<0xXX>` token per
   byte (lines 709-723).
6. Prepend BOS (2). `add_bos` is forced true for this pre-tokenizer even when metadata says false
   (lines 2626-2632). Do not append EOS.

Decoding: normal tokens replace `▁` with a space, byte tokens emit their raw byte (join the bytes
before UTF-8 decoding), and control and user-defined tokens emit their text.

ASCII digits never merge, so `"3333"` becomes four copies of 236800. Test vectors (no BOS) from
`models/ggml-vocab-gemma-4.gguf.inp/.out`:

```
"Hello world"      -> 9259 1902          " Hello world" -> 26352 1902
"Hello, world!"    -> 9259 236764 1902 236888
" "  -> 236743     "  " -> 138     "   " -> 139     "\t" -> 255968     "\n" -> 107     "\n\n" -> 108
"    Hello\n    Hello" -> 140 9259 107 140 9259
"Äpfel" -> 239122 22744 535          "ied 4 ½ months" -> 1178 236743 236812 47041 3794
```

The full 46-case suite is at
https://raw.githubusercontent.com/ggml-org/llama.cpp/df03399b885831b2a1603b3abb0d8c156808e363/models/ggml-vocab-gemma-4.gguf.inp
(with a matching `.out` file). The 15.8 MB vocab-only GGUF next to it
(`models/ggml-vocab-gemma-4.gguf`) works with `llama-tokenize` as an oracle.

### 5.3 Special tokens

| id | text | type | role |
|---|---|---|---|
| 0 | `<pad>` | control | padding; PLE row used for multimodal positions |
| 1 | `<eos>` | control | end of sequence (**stop**) |
| 2 | `<bos>` | control | start, always prepended |
| 3 | `<unk>` | control | |
| 4 | `<mask>` | control | |
| 46 / 47 | `<\|tool>` / `<tool\|>` | control | tool declaration in the system turn |
| 48 / 49 | `<\|tool_call>` / `<tool_call\|>` | user-defined | model's tool call |
| 50 | `<\|tool_response>` | user-defined | model hands over to a tool (**stop**) |
| 51 | `<tool_response\|>` | user-defined | end of tool response |
| 52 | `<\|"\|>` | user-defined | string delimiter inside tool syntax |
| 98 | `<\|think\|>` | control | enables thinking when placed in the system turn |
| 100 / 101 | `<\|channel>` / `<channel\|>` | user-defined | thought channel open/close |
| 105 | `<\|turn>` | control | start of turn |
| 106 | `<turn\|>` | control | end of turn (**stop**) |
| 255999 / 258882 | `<\|image>` / `<image\|>` | control | image span |
| 256000 / 258883 | `<\|audio>` / `<audio\|>` | control | audio span |
| 258880 / 258881 / 258884 | `<\|image\|>` / `<\|audio\|>` / `<\|video\|>` | control | soft-token placeholders |

(In the table the pipes are escaped with backslashes; the actual token texts are
`<|turn>`, `<turn|>`, `<|tool>` and so on.)

Gemma 4 does **not** use Gemma 3's `<start_of_turn>`/`<end_of_turn>`, and it has a real `system` role.

### 5.4 Chat template (the `tokenizer.chat_template` in the GGUF is byte-identical to HF `chat_template.jinja`, dated 2026-07-09)

The strings the template produces, with `\n` meaning a newline. User and system content is
trimmed of surrounding whitespace.

```
# one user turn, no system prompt, thinking off (the default)
<bos><|turn>user\n{user}<turn|>\n<|turn>model\n

# with a system prompt
<bos><|turn>system\n{system}<turn|>\n<|turn>user\n{user}<turn|>\n<|turn>model\n

# thinking on (the <|think|> token goes at the top of the first system turn; the turn exists even with no system prompt)
<bos><|turn>system\n<|think|>\n{system or nothing}<turn|>\n<|turn>user\n{user}<turn|>\n<|turn>model\n

# history: a past model turn keeps only its final answer (strip <|channel>...<channel|>)
<|turn>model\n{answer}<turn|>\n
```

The model ends its turn with `<turn|>` (106). With thinking on, it first writes
`<|channel>thought\n{reasoning}<channel|>` and then the answer. With thinking off, E2B and E4B
emit no thought block at all. Larger Gemma 4 models emit an empty one, `<|channel>thought\n<channel|>`.

Token ids for the reference prompt (with parse_special on):

```
"<|turn>user\nWhat is the capital of France?<turn|>\n<|turn>model\n"
-> [2, 105, 2364, 107, 3689, 563, 506, 5279, 529, 7001, 236881, 106, 107, 105, 4368, 107]
```

---

## 6. Sampling and stopping

- Google's recommendation (model card "Best Practices", `generation_config.json`, and the GGUF
  `general.sampling.*` keys) is **temperature 1.0, top_k 64, top_p 0.95**, the same for every
  use. Nothing else is recommended: no min_p and no repetition penalty. llama.cpp's own defaults
  include `min_p = 0.05`; switch that off to match Google. Greedy (argmax) decoding is for tests.
- **Stop tokens:** 106 `<turn|>`, 1 `<eos>` and 50 `<|tool_response>`. HF `generation_config`
  has `eos_token_id: [1, 106, 50]`, and llama.cpp marks the same three as end-of-generation
  (`llama-vocab.cpp:2884-2886`). Without tool use, 106 is the one that fires.

---

## 7. Reference numbers for testing a port

No reference logits are recorded here, because producing them needs the weights (2.8-5 GB) and
the rule for this session was no download over 50 MB. The procedure below produces them. The
Homebrew llama.cpp on this Mac is build 10250, which supports Gemma 4 and ships `llama-debug`
and `llama-eval-callback`.

**Tier 1: the port against llama.cpp on the same GGUF.** This is the tight check, since both
sides use identical weights and quantization.

```sh
M=gemma-4-E2B_q4_0-it.gguf
# final logits of the last prompt token -> data/llamacpp-<stem>.bin (262144 x f32), plus -tokens.bin
llama-debug -m $M -p "The capital of France is" --save-logits -c 1024 -fa off -ngl 0 -t 8
# per-tensor dumps (first/last 3 values of each row, and the tensor sum)
llama-debug -m $M -p "The capital of France is" --verbose -c 1024 -fa off -ngl 0 \
  --tensor-filter '^(inp_scaled|inp_per_layer|attn_norm-0|Qcur_pos-0|Kcur_pos-0|kqv_out-0|attn_out-0|ffn_out-0|per_layer_embd_out-0|l_out-(0|4|13|14|15|19|34)|result_norm|result_output)$'
```

`llama-debug` tokenizes with parse_special **off**, so keep control tokens out of its `-p`.
Otherwise `<|turn>` is split into four text tokens (236820 236909 887 236813).
`"The capital of France is"` tokenizes to `[2, 818, 5279, 529, 7001, 563]`. For a
chat-formatted prompt use `llama-eval-callback`, which parses specials, or send
`llama-server /completion` the token-id array
`[2, 105, 2364, 107, 3689, 563, 506, 5279, 529, 7001, 236881, 106, 107, 105, 4368, 107]` with
`"n_predict": 1, "n_probs": 5`.

Compare on the same GGUF, at CPU and F32 compute, with flash attention off on both sides:

1. The token ids must be identical.
2. The top-5 ids of the last-token logits must be identical and in the same order.
3. Every logit should satisfy `max |dlogit| < ~1e-2`. Use NMSE < 1e-5 as a guide
   (`examples/model-conversion/scripts/utils/check-nmse.py` computes it).
4. If a check fails, bisect with the per-tensor dumps. Walk through `inp_scaled`,
   `inp_per_layer`, then `l_out-0`, then `l_out-14` (last layer that owns K/V), then `l_out-15`
   (first shared layer).

Then repeat with flash attention on, and on Metal. Expect ranks and top-5 to hold, with
`|dlogit|` up to about 5e-2.

**Tier 2: llama.cpp or the port against transformers.** This check is looser because of quantization.

```python
# needs transformers >= 5.5 (Gemma 4). Memory: f32 is about 20 GB because the PLE table alone is 9.4 GB at f32,
# bf16 is about 10 GB. On the 16 GB Mac run it on the GPU box or compare against the BF16 GGUF instead.
import torch, numpy as np
from transformers import AutoModelForMultimodalLM        # what the model card uses
ids = [2, 818, 5279, 529, 7001, 563]                     # "<bos>The capital of France is"
m = AutoModelForMultimodalLM.from_pretrained("google/gemma-4-E2B-it", dtype=torch.float32).eval()
with torch.no_grad():
    out = m(input_ids=torch.tensor([ids]), output_hidden_states=True)
logits = out.logits[0, -1].float()
v, i = torch.topk(logits, 5); print(list(zip(i.tolist(), v.tolist())))
logits.numpy().astype(np.float32).tofile("pytorch-gemma-4-E2B-it.bin")   # same layout as llama-debug's .bin
# out.hidden_states[0] is the scaled embedding; entry k+1 is the output of layer k ("l_out-k")
```

Against the BF16 GGUF, expect the same top-1 and nearly the same top-5. Against Q4_0 or Q8_0,
expect the same top-1 on easy prompts and some reordering further down.
`examples/model-conversion/scripts/causal/compare-logits.py` in llama.cpp compares the two
`.bin` files.

---

## 8. Gotchas

1. **The norms are `x * w`, not `x * (1 + w)`.** Gemma 1-3 stored `w - 1`, and llama.cpp's
   Gemma 3 converter adds 1 back. Gemma 4 stores the real scale: the converter's `norm_shift`
   returns 0 and the HF `Gemma4RMSNorm` multiplies by `weight`. Adding 1 breaks every layer.
2. **The attention scale is 1.0.** Do not multiply by `1/sqrt(256)` or `1/sqrt(512)`. The Q and K
   RMS norms do the job instead.
3. **V gets an RMS norm without a weight.** K gets a weighted RMS norm. RoPE is applied to Q and
   K only.
4. **Proportional RoPE on full layers is not NEOX partial rotation.** Pass `n_dims = 512` (the
   whole head) together with the `rope_freqs` factors (64 x 1.0, 192 x 1e30). NEOX pairs element
   `i` with element `i + n_dims/2`, so the rotated pairs are (i, i+256) for i < 64, and the
   exponent is `2i/512`. Calling `ggml_rope_ext(n_dims = 128)` instead pairs (i, i+64) with
   exponent `2i/128`, which is wrong. The `1e30` divisor makes theta effectively 0, so cos is 1
   and sin is 0 and those pairs pass through unchanged. The factors are one shared tensor,
   `rope_freqs.weight`, with no layer index.
5. **Two head sizes.** Sliding layers use 256 and full layers use 512, so Q, O and the K/V cache
   widths differ by layer type. Size the buffers per layer.
6. **KV sharing.** Layers 15-34 compute Q only and read layer 13's cache (sliding) or layer 14's
   cache (full), under the mask of their own type. They still apply their own `attn_q_norm` and
   RoPE. The dead `attn_k`, `attn_v` and `attn_k_norm` for those layers exist in some files and
   not in others (601 versus 541 tensors).
7. **The FFN width depends on the layer:** 6144 for layers 0-14 and 12288 for layers 15-34. Read
   `feed_forward_length` as an array.
8. **`layer_output_scale` multiplies the whole residual stream** after the PLE add, not only the
   block's contribution. Its values run from 0.018 to 0.87.
9. **The PLE context projection consumes the scaled embedding**, meaning `x * sqrt(1536)` from
   step 2 of 4.4, and runs once per call, before layer 0. llama.cpp moved it there in April 2026
   (PR #21612). The token part is scaled by 16, not by `sqrt(1536)`.
10. **The PLE gate uses tanh GELU** (`ggml_gelu`, HF `gelu_pytorch_tanh`), and so does the FFN
    through `ggml_geglu_split(gate, up)`. Argument order matters because the first argument is
    the one activated. On CPU, ggml evaluates GELU through an FP16 lookup table (`GGML_GELU_FP16`
    in `ggml-cpu/vec.h`), which adds small differences against PyTorch. That is expected.
11. **The embedding scale in HF is rounded to bf16** when the model is loaded in bf16:
    `sqrt(1536)` becomes 39.25 instead of 39.19. llama.cpp uses the exact float. Run
    transformers in f32 for tight comparisons.
12. **The LM head is tied.** There is no `output.weight`; multiply by `token_embd`, which is
    quantized (Q6_K or Q8_0). Softcap afterwards, as `30 * tanh(logits / 30)`. Select `out_ids`
    before the head: 262144 x 1536 per row is 17% of all compute per token.
13. **The tokenizer is BPE, not SentencePiece.** Scores are all -1000 and meaningless. Newlines
    need the special handling in 5.2 step 4, and BOS must be added even if the metadata ever
    says otherwise.
14. **Chat tokens changed**, to `<|turn>` 105 and `<turn|>` 106. Stop on 106, 1 and 50. Some
    tokens are user-defined rather than control (`<|channel>`, `<channel|>`, the tool tokens and
    `<|"|>`), so they are matched in text even with parse_special off and are rendered in
    output. That is deliberate, so a chat parser can see them.
15. **Cache writes must come before cache reads in the graph** (4.7). ggml has no dependency
    edge from a `set_rows` to a later view of the same buffer.
16. **The mask must be F16 for `ggml_flash_attn_ext`** and F32 (or F16) for `ggml_soft_max_ext`,
    with `-INFINITY` for blocked cells. With flash attention, K and V must be F16 (llama.cpp
    casts any F32 K/V) and the result needs `ggml_prec_set_acc(..., GGML_PREC_F32)`.
17. **`per_layer_model_proj` is BF16** in the ggml-org files and F16 in the QAT file. Metal
    supports BF16 only on Apple6 and Metal3-class GPUs. llama.cpp runs this matmul on the CPU
    input layer anyway; converting it to F16 at load time also works.
18. **Keep `per_layer_token_embd` off the GPU.** It takes 1.3-2.5 GB, and each token needs only
    one 8960-wide row. llama.cpp reads it lazily and places it with the input layer (CPU).
19. **For multimodal later:** embedding inputs are not scaled by `sqrt(1536)`, and they take their
    PLE token part from row 0 (`<pad>`).

---

## Summary

Use `google/gemma-4-E2B-it-qat-q4_0-gguf` / `gemma-4-E2B_q4_0-it.gguf`, 3,349,516,256 bytes,
Apache 2.0, not gated:
https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/gemma-4-E2B_q4_0-it.gguf.
Diff against `ggml-org/gemma-4-E2B-it-GGUF` Q8_0 (4.97 GB). The towers are in a separate mmproj
file.

Key hyperparameters: 35 layers; hidden size 1536; 8 query heads and 1 KV head. Head dim is 256
on sliding layers and 512 on full layers, where every fifth layer (4, 9, ..., 34) is full. The
sliding window is 512. RoPE is NEOX with base 1e4 on sliding layers and base 1e6 with
proportional factors (64 of 256 pairs rotated) on full layers. FFN is GeGLU (tanh) with width
6144 for layers 0-14 and 12288 for layers 15-34. Vocab is 262144, context 131072, RMS eps 1e-6,
norms are plain `x*w`, attention scale is 1.0, there is no attention softcap, and the final logit
softcap is 30. Embeddings are scaled by sqrt(1536). Per-layer embeddings are 256 wide per layer:
the token part is scaled by 16, the context part is a projection scaled by 1/sqrt(1536) and then
RMS-normed, and the two are summed and scaled by 1/sqrt(2). Each layer ends with a gated
PLE-residual block and a per-layer output scalar. Layers 15-34 reuse the KV of layer 13
(sliding) or 14 (full). The LM head is tied. AltUp, LAuReL and activation sparsity are gone.

Tokenizer: BPE with 514906 merges, spaces become `▁`, `<0xXX>` byte fallback, BOS 2 always.
Chat format `<|turn>role\n...<turn|>\n`. Stop on 106, 1 and 50. Sample with temperature 1.0,
top_k 64, top_p 0.95.

ggml ops: `get_rows`, `scale`, `reshape_3d`, `permute`, `cont`, `view_2d`, `rms_norm`, `mul`,
`add`, `mul_mat`, `rope_ext` (NEOX, freq factors), `set_rows`, `flash_attn_ext` or
`soft_max_ext`, `geglu_split`, `gelu`, `tanh`, `prec_set_acc`.

## Port (console/ml/gemma4.lua, 2026-09-10)

Checked against llama.cpp build 10250 (ee0445c99) on the same file, the QAT Q4_0 GGUF
(`google/gemma-4-E2B-it-qat-q4_0-gguf`, sha256 fa401b55...6634), prompt "The capital of
France is" (ids 2 818 5279 529 7001 563), CPU, flash attention on:

| what | result |
| --- | --- |
| logits, our CPU against llama.cpp's CPU | max difference 0.0000, NMSE 7.6e-15: the same computation |
| logits, our Metal against llama.cpp's CPU | max 0.51, NMSE 5.5e-4, the same top 5 |
| llama.cpp against itself, flash attention on and off | max 0.94, NMSE 2.4e-3 |
| layer 0, every tapped tensor (Q, K, V, attention out) | equal to the digits llama-debug prints |
| the prompt in two pieces against one, on Metal | NMSE 1e-7 |
| the same, on the CPU | NMSE 8.7e-4: q8_0 activation rounding flips with the batch size (below) |

`Model:forward(tokens, taps)` fills `taps` with intermediate tensors under llama.cpp's names
(`inp_scaled`, `Qcur_pos-N`, `Kcur_pos-N`, `Vcur_normed-N`, `kqv_out-N`, `attn_out-N`,
`l_out-N`), which is how the layers were compared with `llama-debug --tensor-filter`.

Speed on a MacBook Air (M-series, 16 GB), 138-token prompt, 20 generated, wall clock:

| | prompt tok/s | generate tok/s | llama.cpp (llama-bench) |
| --- | --- | --- | --- |
| Metal, LuaJIT / Lua 5.5 | 612-622 | 46-51 | 621 / 56 |
| CPU, 8 threads, weights packed | 251 | 53 | 206 / 51.5 |
| CPU, not packed | 115 | 48 | |
| RTX 4070, CUDA, LuaJIT / Lua 5.4 | 5896 | 110 | |
| the PC's CPU (x86, AVX2), packed | 235 | 35 | |
| WebAssembly in node, 8 threads | 21 | 14 | |

On CUDA, generation went from 90 to 110 tokens a second when the KV view was padded to 256
cells (`KV_PAD`), as llama.cpp pads it: the fast flash-attention kernels want the length a
multiple of 256.

Load takes 1.8 s on Metal. The first Metal run of a process compiles the shaders (16 s the
very first time on a machine, 0.01 s after, from the system's cache).

Found while porting:

- `L.swa and nil or self.rope_freqs` is always `self.rope_freqs` (Lua's `and`/`or` with a
  nil in the middle). The sliding layers took the full layers' frequency factors, which
  stop the low-frequency half of each head from rotating: the top five were right and every
  logit was off by up to 0.7, which looked like flash attention's rounding until the layer-0
  taps showed Q wrong only in its last dimensions.
- `a and table.unpack(t) or unpack(t)` passes one value, not the list.
- On the CPU a q4_0 product rounds its input to q8_0 per block of 32; a batch of another
  size can round a value the other way, 1e-4 at layer 0 and a tenth of a logit by the end.
  llama.cpp's CPU does the same. On a GPU the pieces agree to 1e-7.
