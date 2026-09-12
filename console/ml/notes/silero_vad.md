# Silero VAD v6.2 on ggml — implementation spec

Researched 2026-09-10. Everything below was checked against the published files: the
architecture was read out of the TorchScript archive and the ONNX graphs, the weights were
compared tensor by tensor across every published format, and a ggml forward pass written to this
spec (vendored ggml at `7840aaba`, CPU backend) reproduced the official JIT model on a fixed WAV to
within 2e-6 per chunk. The Python used for that is outlined in "Reference numbers" at the end.

## 1. Which model

- Upstream: `github.com/snakers4/silero-vad`, MIT licence. The latest model is **v6.2**
  (released 2025-11-06; pip `silero-vad` 6.2.1 on 2026-02-24 only made onnxruntime optional). v6.0
  was 2025-08-26 and v5.1.2 was 2024-10-09. v6 and v5 share the architecture below; only the
  weights differ.
- The TorchScript archive's top-level directory is `VADr_v6_10_25_noths_re/`. That is how to tell
  a v6.2 JIT from an older one.
- The model packs a 16 kHz network and an 8 kHz network in one file. This spec covers the 16 kHz
  one. The 8 kHz network is the same shape except n_fft 128, hop 64, 65 bins (first conv takes 65
  channels), 256-sample chunks and 32 context samples.

## 2. Architecture (16 kHz)

Input to one step is **576 samples**: the last 64 samples of the previous chunk followed by the
512 new ones (32 ms). Output is one speech probability plus the new LSTM state.

| # | Stage | Op | Output shape (C, T) |
|---|---|---|---|
| 0 | input | 64 context + 512 new samples | (1, 576) |
| 1 | pad | `ReflectionPad1d((0, 64))`: reflect-pad the **right** side only, 64 samples, edge sample not repeated | (1, 640) |
| 2 | STFT as conv | `conv1d(x, forward_basis_buffer[258,1,256], stride=128, padding=0)`, no bias | (258, 4) |
| 3 | magnitude | `sqrt(re² + im²)`, re = channels 0..128, im = channels 129..257 | (129, 4) |
| 4 | encoder 0 | Conv1d 129→128, k3, stride 1, pad 1, bias, ReLU | (128, 4) |
| 5 | encoder 1 | Conv1d 128→64, k3, stride 2, pad 1, bias, ReLU | (64, 2) |
| 6 | encoder 2 | Conv1d 64→64, k3, stride 2, pad 1, bias, ReLU | (64, 1) |
| 7 | encoder 3 | Conv1d 64→128, k3, stride 1, pad 1, bias, ReLU | (128, 1) |
| 8 | squeeze | drop the length-1 time axis | (128) |
| 9 | LSTMCell | input 128, hidden 128, PyTorch gate order i, f, g, o | h', c' (128 each) |
| 10 | head | Dropout(0.1) (no-op at inference), ReLU(h'), Conv1d 128→1 k1 with bias, Sigmoid | (1, 1) |
| 11 | output | `mean` over the time axis of length 1 (a no-op), unsqueeze | (1) |

Details that matter:

- **STFT basis.** `forward_basis_buffer` is a windowed DFT: for k in 0..128 and t in 0..255,
  row k = `cos(2πkt/256)·w[t]` and row 129+k = `−sin(2πkt/256)·w[t]`, where w is the *periodic*
  Hann window `0.5 − 0.5·cos(2πt/256)`. Checked against the stored buffer to 7.7e-8. You can
  regenerate it instead of shipping it, though shipping the stored values is simplest.
- **Encoder blocks** are `SileroVadBlock`s trained as MobileOne-style blocks with five branches
  (`num_conv_branches=5`) and folded for inference (`inference_mode=True`) into a single
  `reparam_conv`. The `se` member is `Identity`. At inference each block is exactly
  conv + bias + ReLU.
- **Frame count.** (640 − 256)/128 + 1 = 4 STFT frames. The encoder reduces 4 → 4 → 2 → 1 → 1, so
  the LSTM sees a single 128-vector per 32 ms step. The model therefore only works with exactly
  576 input samples: a longer input gives more than one encoder frame, and the decoder's
  `squeeze(-1)` then fails. The wrappers reject anything but 512 new samples.
- **LSTM.** `gates = W_ih·x + b_ih + W_hh·h + b_hh` (512 values), split into four 128-blocks in
  the order i, f, g, o: `c' = σ(f)·c + σ(i)·tanh(g)`, `h' = σ(o)·tanh(c')`. The state carried to
  the next step is the **pre-ReLU** `h'` and `c'`. The ReLU belongs to the output head only.
- The JIT casts the STFT real and imaginary parts to float32 (`torch.to(..., 6)`). Everything is
  float32 end to end.

## 3. Streaming state

Three things carry from one 512-sample chunk to the next:

| State | Shape | Initial value | Update |
|---|---|---|---|
| context | 64 samples | zeros | the last 64 samples of this step's 576-sample input (the tail of the new chunk) |
| h | 128 float | zeros | h' from step 9 |
| c | 128 float | zeros | c' from step 9 |

The ONNX exports take and return the LSTM state as one tensor `state[2, B, 128]` (index 0 = h,
1 = c). The ONNX graph does **not** hold the context: its `input` is already the 576-sample
concatenation, and the Python `OnnxWrapper` keeps the context. The JIT's `VADRNNJITMerge.forward`
takes 512 samples and keeps both context and state inside the module.

`reset_states()` zeroes all three. Silero's own `get_speech_timestamps` and `VADIterator` reset
once per audio stream. Pipecat's `SileroVADAnalyzer` and the smart-turn demo
(`record_and_predict.py`) additionally reset every 5 s (`_MODEL_RESET_STATES_TIME = 5.0`). That is
a consumer policy, not part of the model; the reference numbers below never reset mid-stream.

## 4. Published weight files and how they are packed

All files are in `src/silero_vad/data/` of the repo (fetch from
`raw.githubusercontent.com/snakers4/silero-vad/master/src/silero_vad/data/<file>`).

| File | Bytes | sha256 (prefix) | What it is |
|---|---:|---|---|
| `silero_vad.jit` | 2,272,526 | `e1122837f415` | v6.2, TorchScript zip, 16 k + 8 k networks, keeps context and state internally |
| `silero_vad.onnx` | 2,327,524 | `1a153a22f450` | v6.2, opset 16, exported with spox; inputs `input[B,576]`, `state[2,B,128]`, `sr` (int64 scalar); outputs `output[B,1]`, `stateN` |
| `silero_vad_16k_op15.onnx` | 1,289,603 | `7ed98ddbad84` | v6.2, 16 k only, opset 15, **weights as named initializers**: the easiest ONNX to read |
| `silero_vad_op18_ifless.onnx` | 2,845,718 | `7671cd04b004` | v6.2, opset 18, LSTM written out as Gemm + Split + Sigmoid/Tanh (a useful explicit reference) |
| `silero_vad_half.onnx` | 1,280,395 | `1e0b195ad480` | **v5** (2024-08-22), fp16 — not v6 |
| `silero_vad_16k.safetensors` | 1,239,748 | `c59271c284ae` | added 2025-12-10 for the tinygrad port; **not bitwise equal to v6.2** (see below) |

**Weights are identical across `silero_vad.jit`, `silero_vad.onnx` (then-branch = 16 k),
`silero_vad_16k_op15.onnx` and `silero_vad_op18_ifless.onnx`** (max abs difference 0.0).

**The safetensors file is a different checkpoint.** Its STFT basis matches, but every learned
tensor differs from v6.2 (conv4 weight by up to 18.2, final bias −0.574 vs −0.625), and it also
matches neither v6.0 nor v5. On the reference WAV its probabilities differ from the v6.2 JIT by up
to 0.41 (mean 0.021, 7 of 344 chunks cross 0.5). Its names are plain (`stft_conv.weight`,
`conv1..4.{weight,bias}`, `lstm_cell.{weight_ih,weight_hh,bias_ih,bias_hh}`,
`final_conv.{weight,bias}`) and its graph is `tinygrad_model.py` in the same repo, but it is not
the model the official Python API runs. Use it only if you deliberately want that checkpoint.

### JIT packing

A TorchScript zip: `VADr_v6_10_25_noths_re/{code/,data/,data.pkl,constants.pkl,...}`. The
readable module source is under `code/__torch__/vad/model/vad_annotator.py`,
`vad/utils/pytorch_stft.py` and `vad/utils/model_utils.py`. The state dict, all float32, is:

```
_model.stft.forward_basis_buffer          (258, 1, 256)
_model.encoder.{0..3}.reparam_conv.weight (128,129,3) (64,128,3) (64,64,3) (128,64,3)
_model.encoder.{0..3}.reparam_conv.bias   (128) (64) (64) (128)
_model.decoder.rnn.weight_ih              (512, 128)
_model.decoder.rnn.weight_hh              (512, 128)
_model.decoder.rnn.bias_ih                (512)
_model.decoder.rnn.bias_hh                (512)
_model.decoder.decoder.2.weight           (1, 128, 1)
_model.decoder.decoder.2.bias             (1)
_model_8k.*                               same names; basis (130,1,128), encoder.0 weight (128,65,3)
```

Total 16 k parameters: 309,633, of which 66,048 are the fixed STFT basis.

### ONNX packing

- `silero_vad_16k_op15.onnx`: 15 graph initializers named `model.<state-dict name without _model.>`
  (for example `model.decoder.rnn.weight_ih`), in PyTorch layout and PyTorch gate order.
- `silero_vad.onnx`: no graph initializers. The weights are `Constant` nodes inside the two
  branches of the top-level `If` on `sr` (then = 16 k, else = 8 k). A reader must walk into
  `AttributeProto.g` subgraphs to find them.
- The ONNX `LSTM` op wants gate order i, o, f, c. The stored constants are still in PyTorch order
  (i, f, g, o); the graph reorders them with `Slice`/`Concat` in front of the `LSTM` node. If you
  take weights from the constants, use PyTorch order. If you take them from the `LSTM` node's
  computed `W`/`R` inputs, reorder.

For a minimal protobuf reader that pulls initializers without the `onnx` package, see section 6 of
`smart_turn.md`; the same field numbers apply.

## 5. whisper.cpp's ggml port (a working reference, with two deviations)

whisper.cpp ships Silero as a separate small ggml model, used by `whisper_vad_*` in
`src/whisper.cpp` and converted by `models/convert-silero-vad-to-ggml.py` (which calls
`silero_vad.load_silero_vad()` and so converts whatever JIT the installed pip package carries).
Prebuilt files: `huggingface.co/ggml-org/whisper-vad`:

| File | Bytes | sha256 (prefix) |
|---|---:|---|
| `ggml-silero-v6.2.0.bin` | 885,098 | `2aa269b785ee` |
| `ggml-silero-v5.1.2.bin` | 885,098 | `29940d98d42b` |

`ggml-silero-v6.2.0.bin` holds the v6.2 weights (checked: max difference from the JIT equals the
fp16 rounding of the conv weights; the LSTM tensors are bit-exact).

### File format (legacy ggml, little-endian int32 unless noted)

```
u32   magic 0x67676d6c ("ggml")
i32   len, then bytes "silero-16k"
i32   major, minor, patch          (6, 2, 0)
i32   n_window = 512, n_context = 64
i32   n_encoder_layers = 4
4 x   i32 in_ch, out_ch, kernel    (129,128,3) (128,64,3) (64,64,3) (64,128,3)
i32   lstm_input = 128, lstm_hidden = 128
i32   final_conv_in = 128, final_conv_out = 1
then per tensor until EOF:
i32   n_dims, name_len, ftype (0 = f32, 1 = f16)
i32   ne[n_dims]                   (ggml order: fastest dimension first)
bytes name
data  (contiguous; the numpy shape reversed is ne)
```

Note: the converter does not write the strides. The loader hard-codes them in the graph code.

### Tensors (in file order)

| Name | ggml ne | Type |
|---|---|---|
| `_model.encoder.0.reparam_conv.weight` | [3, 129, 128] | f16 |
| `_model.encoder.0.reparam_conv.bias` | [128] | f32 |
| `_model.encoder.1.reparam_conv.weight` | [3, 128, 64] | f16 |
| `_model.encoder.1.reparam_conv.bias` | [64] | f32 |
| `_model.encoder.2.reparam_conv.weight` | [3, 64, 64] | f16 |
| `_model.encoder.2.reparam_conv.bias` | [64] | f32 |
| `_model.encoder.3.reparam_conv.weight` | [3, 64, 128] | f16 |
| `_model.encoder.3.reparam_conv.bias` | [128] | f32 |
| `_model.decoder.rnn.weight_ih` | [128, 512] | f32 |
| `_model.decoder.rnn.weight_hh` | [128, 512] | f32 |
| `_model.decoder.rnn.bias_ih` | [512] | f32 |
| `_model.decoder.rnn.bias_hh` | [512] | f32 |
| `_model.decoder.decoder.2.weight` | [128] (squeezed; the loader declares it [128, 1]) | f16 |
| `_model.decoder.decoder.2.bias` | n_dims = 0 (squeezed scalar; the loader reads it as [1]) | f32 |
| `_model.stft.forward_basis_buffer` | [256, 1, 258] | f16 |

### Graph construction (quoted from `src/whisper.cpp`, master as of 2026-09-10)

```cpp
static ggml_tensor * whisper_vad_build_stft_layer(ggml_context * ctx0,
        const whisper_vad_model & model, ggml_tensor * cur) {
    // Apply reflective padding to the input tensor
    ggml_tensor * padded = ggml_pad_reflect_1d(ctx0, cur, 64, 64);

    struct ggml_tensor * stft = ggml_conv_1d(ctx0, model.stft_forward_basis, padded, model.hparams.lstm_input_size, 0, 1);

    // Calculate cutoff for real/imaginary parts
    int cutoff = model.stft_forward_basis->ne[2] / 2;

    // Extract real part (first half of the STFT output).
    struct ggml_tensor * real_part = ggml_view_2d(ctx0, stft, 4, cutoff, stft->nb[1], 0);
    // Extract imaginary part (second half of the STFT output).
    struct ggml_tensor * img_part = ggml_view_2d(ctx0, stft, 4, cutoff, stft->nb[1], cutoff * stft->nb[1]);

    // Calculate magnitude: sqrt(real^2 + imag^2)
    struct ggml_tensor * real_squared = ggml_mul(ctx0, real_part, real_part);
    struct ggml_tensor * img_squared  = ggml_mul(ctx0, img_part, img_part);
    struct ggml_tensor * sum_squares  = ggml_add(ctx0, real_squared, img_squared);
    struct ggml_tensor * magnitude    = ggml_sqrt(ctx0, sum_squares);
    return magnitude;
}

static ggml_tensor * whisper_vad_build_encoder_layer(ggml_context * ctx0,
        const whisper_vad_model & model, ggml_tensor * cur) {
    // First Conv1D: expands to 128 channels.
    cur = ggml_conv_1d(ctx0, model.encoder_0_weight, cur, 1, 1, 1);
    cur = ggml_add(ctx0, cur, ggml_reshape_3d(ctx0, model.encoder_0_bias, 1, 128, 1));
    cur = ggml_relu(ctx0, cur);

    // Second Conv1D: reduces to 64 channels.
    cur = ggml_conv_1d(ctx0, model.encoder_1_weight, cur, 2, 1, 1);
    cur = ggml_add(ctx0, cur, ggml_reshape_3d(ctx0, model.encoder_1_bias, 1, 64, 1));
    cur = ggml_relu(ctx0, cur);

    // Third Conv1D: maintains 64 channels
    cur = ggml_conv_1d(ctx0, model.encoder_2_weight, cur, 2, 1, 1);
    cur = ggml_add(ctx0, cur, ggml_reshape_3d(ctx0, model.encoder_2_bias, 1, 64, 1));
    cur = ggml_relu(ctx0, cur);

    // Fourth Conv1D: expands to 128 channels
    cur = ggml_conv_1d(ctx0, model.encoder_3_weight, cur, 1, 1, 1);
    cur = ggml_add(ctx0, cur, ggml_reshape_3d(ctx0, model.encoder_3_bias, 1, 128, 1));
    cur = ggml_relu(ctx0, cur);

    return cur;
}

static ggml_tensor * whisper_vad_build_lstm_layer(ggml_context * ctx0,
        const whisper_vad_context & vctx, ggml_tensor * cur, ggml_cgraph * gf) {
    const whisper_vad_model & model = vctx.model;
    const int hdim = model.hparams.lstm_hidden_size;

    struct ggml_tensor * x_t = ggml_transpose(ctx0, cur);

    // Create operations using the input-to-hidden weights.
    struct ggml_tensor * inp_gate = ggml_mul_mat(ctx0, model.lstm_ih_weight, x_t);
    inp_gate = ggml_add(ctx0, inp_gate, model.lstm_ih_bias);

    // Create operations using the hidden-to-hidden weights.
    struct ggml_tensor * hid_gate = ggml_mul_mat(ctx0, model.lstm_hh_weight, vctx.h_state);
    hid_gate = ggml_add(ctx0, hid_gate, model.lstm_hh_bias);

    // Create add operation to get preactivations for all gates.
    struct ggml_tensor * out_gate = ggml_add(ctx0, inp_gate, hid_gate);

    const size_t hdim_size = ggml_row_size(out_gate->type, hdim);

    struct ggml_tensor * i_t = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, out_gate, hdim, 0 * hdim_size));
    struct ggml_tensor * f_t = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, out_gate, hdim, 1 * hdim_size));
    struct ggml_tensor * g_t = ggml_tanh(ctx0, ggml_view_1d(ctx0, out_gate, hdim, 2 * hdim_size));
    struct ggml_tensor * o_t = ggml_sigmoid(ctx0, ggml_view_1d(ctx0, out_gate, hdim, 3 * hdim_size));

    // Update cell state
    struct ggml_tensor * c_out = ggml_add(ctx0,
        ggml_mul(ctx0, f_t, vctx.c_state),
        ggml_mul(ctx0, i_t, g_t));
    ggml_build_forward_expand(gf, ggml_cpy(ctx0, c_out, vctx.c_state));

    // Update hidden state
    struct ggml_tensor * out = ggml_mul(ctx0, o_t, ggml_tanh(ctx0, c_out));
    ggml_build_forward_expand(gf, ggml_cpy(ctx0, out,   vctx.h_state));

    return out;
}

static struct ggml_cgraph * whisper_vad_build_graph(whisper_vad_context & vctx) {
    ...
    struct ggml_tensor * frame = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, vctx.n_window, 1);
    ggml_set_name(frame, "frame");
    ggml_set_input(frame);

    struct ggml_tensor * cur = nullptr;
    {
        cur = whisper_vad_build_stft_layer(ctx0, model, frame);

        cur = whisper_vad_build_encoder_layer(ctx0, model, cur);

        // Extract the first element of the first dimension
        // (equivalent to pytorch's [:, :, 0])
        cur = ggml_view_2d(ctx0, cur, 1, 128, cur->nb[1], 0);

        cur = whisper_vad_build_lstm_layer(ctx0, vctx, cur, gf);
        cur = ggml_relu(ctx0, cur);
        cur = ggml_conv_1d(ctx0, model.final_conv_weight, cur, 1, 0, 1);
        cur = ggml_add(ctx0, cur, model.final_conv_bias);
        cur = ggml_sigmoid(ctx0, cur);
        ggml_set_name(cur, "prob");
        ggml_set_output(cur);
    }
    ...
}
```

The state tensors `h_state` and `c_state` are 1-D f32 [128] in their own backend buffer, updated
in place by the `ggml_cpy` nodes. `whisper_vad_reset_state` clears that buffer.
`whisper_vad_detect_speech` resets and then loops over 512-sample chunks, zero-padding the last
partial chunk; `whisper_vad_detect_speech_no_reset` skips the reset (use that for streaming).
whisper.cpp builds the graph once and recomputes it per chunk. It forces the VAD onto the CPU
("GPU VAD is forced disabled until the performance is improved").

### Where whisper.cpp departs from the reference

1. **No context samples.** It feeds 512 samples and reflect-pads **64 on both sides**. The model
   was trained on 64 samples of real left context plus 64 of right reflection. The right side
   agrees (the tail of the 576 buffer is the tail of the chunk); the left 64 samples do not. Every
   one of the 4 STFT frames sees part of the left pad, so this changes every step. Measured on
   `jfk.wav`: max |Δp| = 0.20 against the JIT, mean 0.011, 2 of 344 chunks flip at 0.5.
2. **F16 im2col.** `ggml_conv_1d` builds its im2col in F16 whenever the kernel is not BF16 (see
   `ggml_conv_1d` in `ggml/src/ggml.c`), so the audio, the magnitudes and every encoder activation
   are rounded to half precision, on top of the f16 kernels. Measured with F32 weights and our
   graph: max |Δp| = 0.009, no flips.
3. Minor: the STFT stride is passed as `hparams.lstm_input_size` (128 happens to equal the hop).

## 6. Our ggml graph (verified)

Weights: take them from `silero_vad_16k_op15.onnx` (or the JIT) and store all tensors as **F32**
(1.2 MB; the model is too small for quantization to be worth anything). ggml ne is the PyTorch
shape reversed, so every tensor loads verbatim from the ONNX raw data.

Per step, with `inp` = f32[576] (context ‖ chunk), `h_in`, `c_in` = f32[128, 1]:

```c
// conv1d with an F32 im2col (ggml_conv_1d would round activations to F16)
static ggml_tensor * conv1d(ggml_context * c, ggml_tensor * k /*[K,IC,OC]*/, ggml_tensor * x /*[L,IC]*/, int s, int p) {
    ggml_tensor * im = ggml_im2col(c, k, x, s, 0, p, 0, 1, 0, false, GGML_TYPE_F32);           // [N, OL, IC*K]
    ggml_tensor * r  = ggml_mul_mat(c, ggml_reshape_2d(c, im, im->ne[0], im->ne[2]*im->ne[1]),
                                       ggml_reshape_2d(c, k, k->ne[0]*k->ne[1], k->ne[2]));    // [N*OL, OC]
    return ggml_reshape_3d(c, r, im->ne[1], k->ne[2], im->ne[2]);                              // [OL, OC, N]
}

x   = ggml_pad_reflect_1d(c, ggml_reshape_2d(c, inp, 576, 1), 0, 64);        // [640,1]
st  = conv1d(c, stft_basis /*ne [256,1,258]*/, x, 128, 0);                   // [4,258]
re  = ggml_view_2d(c, st, 4, 129, st->nb[1], 0);
im  = ggml_view_2d(c, st, 4, 129, st->nb[1], 129*st->nb[1]);
cur = ggml_sqrt(c, ggml_add(c, ggml_sqr(c, re), ggml_sqr(c, im)));          // [4,129]
for i in 0..3, stride = {1,2,2,1}:
    cur = ggml_relu(c, ggml_add(c, conv1d(c, enc_w[i], cur, stride[i], 1),
                                   ggml_reshape_2d(c, enc_b[i], 1, OC_i)));  // [4,128] [2,64] [1,64] [1,128]
x   = ggml_reshape_2d(c, cur, 128, 1);
g   = ggml_add(c, ggml_add(c, ggml_mul_mat(c, w_ih /*[128,512]*/, x), b_ih),
                  ggml_add(c, ggml_mul_mat(c, w_hh, h_in), b_hh));           // [512,1]
i   = ggml_sigmoid(c, ggml_view_2d(c, g, 128, 1, g->nb[1], 0*512));         // byte offsets: 128 floats per gate
f   = ggml_sigmoid(c, ggml_view_2d(c, g, 128, 1, g->nb[1], 1*512));
gg  = ggml_tanh   (c, ggml_view_2d(c, g, 128, 1, g->nb[1], 2*512));
o   = ggml_sigmoid(c, ggml_view_2d(c, g, 128, 1, g->nb[1], 3*512));
c_out = ggml_add(c, ggml_mul(c, f, c_in), ggml_mul(c, i, gg));
h_out = ggml_mul(c, o, ggml_tanh(c, c_out));
p   = ggml_sigmoid(c, ggml_add(c, ggml_mul_mat(c, ggml_reshape_2d(c, fin_w, 128, 1), ggml_relu(c, h_out)), fin_b));
// outputs: p [1,1], h_out, c_out -> next step's h_in, c_in; context = inp[512..575]
```

Ops needed: `ggml_pad_reflect_1d`, `ggml_im2col`, `ggml_mul_mat`, `ggml_view_2d`, `ggml_sqr`,
`ggml_sqrt`, `ggml_add` (with broadcast), `ggml_mul`, `ggml_relu`, `ggml_sigmoid`, `ggml_tanh`,
`ggml_reshape_*`. For the state, either copy h/c/context through the host each step (simplest; that
is what the verification harness did) or keep them in a persistent backend buffer and write them
with `ggml_cpy` inside the graph as whisper.cpp does.

Cost is about 0.7 M multiply-adds per 32 ms step, so per-graph dispatch overhead dominates. Build
the graph once, keep the allocation, and run it on the **CPU backend** on every platform
(including WebAssembly); sending it to Metal or CUDA only adds latency. Verified result: max
|Δp| = 2e-6 against the JIT over 344 chunks.

## 7. Post-processing

### Streaming: `VADIterator` (utils_vad.py)

Parameters and defaults: `threshold=0.5`, `min_silence_duration_ms=100`, `speech_pad_ms=30`,
`sampling_rate=16000`. The exit threshold is fixed at `threshold − 0.15` (0.35). There is **no
minimum speech duration** in the iterator. Per 512-sample chunk:

```python
self.current_sample += 512                       # sample index of the END of this chunk
p = model(chunk)
if p >= threshold and self.temp_end:
    self.temp_end = 0                            # speech resumed: cancel pending end
if p >= threshold and not self.triggered:
    self.triggered = True
    return {'start': max(0, current_sample - speech_pad_samples - 512)}
if p < threshold - 0.15 and self.triggered:
    if not self.temp_end:
        self.temp_end = current_sample
    if current_sample - temp_end < min_silence_samples:
        return None
    speech_end = temp_end + speech_pad_samples - 512
    self.temp_end = 0; self.triggered = False
    return {'end': speech_end}
return None
```

`temp_end` is the end of the first chunk below 0.35, and the end fires once
`current_sample − temp_end ≥ 1600`. With 512-sample chunks that is the fifth low chunk, four
chunks (128 ms) after the first; on `jfk.wav` the first low chunk is 70 and the end event comes at
chunk 74. A chunk with p ≥ 0.5 cancels the pending end. A chunk with 0.35 ≤ p < 0.5 neither
cancels it nor fires it: time keeps running, but the end is only reported on a chunk below 0.35
(hysteresis). The start is reported 30 ms before the start of the triggering chunk, and the end
2 ms before the end of the first low chunk.

### Offline: `get_speech_timestamps`

Defaults: `threshold=0.5`, `neg_threshold=max(threshold−0.15, 0.01)`,
`min_speech_duration_ms=250`, `min_silence_duration_ms=100`, `speech_pad_ms=30`,
`max_speech_duration_s=inf`, `min_silence_at_max_speech=98` ms,
`use_max_poss_sil_at_max_speech=True` (when a segment exceeds the maximum, cut at the longest
silence inside it). Final pass: pad each segment by 30 ms on each side; if the gap between two
segments is under 2×30 ms, split the gap between them instead.

whisper.cpp's `whisper_vad_segments_from_probs` follows an older version of this loop (it keeps
the "last silence" rule, not `use_max_poss_sil_at_max_speech`) and adds two passes the Python does
not have: it merges segments separated by less than 200 ms, then drops segments shorter than
`min_speech_duration_ms` again. whisper.cpp defaults: threshold 0.5, min speech 250 ms, min
silence 100 ms, pad 30 ms, samples_overlap 0.1 s.

### Pipecat's VAD (the context smart-turn was tuned with)

`VADParams`: `confidence=0.7`, `start_secs=0.2`, `stop_secs=0.2`, `min_volume=0.6`. A chunk
counts as speaking when p ≥ 0.7 *and* the smoothed volume is ≥ 0.6. The state goes QUIET →
STARTING → SPEAKING after round(0.2/0.032) = 6 consecutive speaking chunks, and SPEAKING →
STOPPING → QUIET after 6 consecutive non-speaking chunks (192 ms). One speaking chunk during
STOPPING returns to SPEAKING. The transition to QUIET is when pipecat runs Smart Turn (see
`smart_turn.md`, section 9).

## 8. Reference numbers

Fixed WAV: whisper.cpp's `samples/jfk.wav` (16 kHz mono s16, 176,000 samples = 11.0 s, 352,078
bytes, sha256 `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`), zero-padded to
344 chunks of 512.

Script outline (run with torch, onnxruntime and soundfile; torch.set_num_threads(1)):

```python
wav, sr = soundfile.read('jfk.wav', dtype='float32')          # sr == 16000
chunks = np.pad(wav, (0, (-len(wav)) % 512)).reshape(-1, 512)
jit = torch.jit.load('silero_vad.jit'); jit.eval(); jit.reset_states()
p_jit = [jit(torch.from_numpy(c), 16000).item() for c in chunks]      # the official path
# cross-check with ONNX: carry state[2,1,128] and a 64-sample context yourself
sess = onnxruntime.InferenceSession('silero_vad.onnx'); state = zeros((2,1,128)); ctx = zeros((1,64))
for c in chunks:
    x = concat([ctx, c[None]], 1)
    out, state = sess.run(None, {'input': x, 'state': state, 'sr': np.array(16000, np.int64)})
    ctx = x[:, -64:]
np.savetxt('silero_jfk_probs.txt', p_jit, fmt='%.6f')
# events: VADIterator(model, threshold=0.5, min_silence_duration_ms=100, speech_pad_ms=30) over the
# same chunks; get_speech_timestamps(torch.from_numpy(wav), model)
```

Results with v6.2 (JIT and ONNX agree to 3e-6; our ggml graph to 2e-6):

- 344 probabilities, sum 236.805958, mean 0.688389, 234 chunks ≥ 0.5.
- Chunks 0–39:
  `0.001670 0.084635 0.301989 0.133494 0.083200 0.043454 0.055422 0.052693 0.031314 0.037638
  0.343344 0.945989 0.932935 0.857260 0.972762 0.988260 0.990164 0.989361 0.995614 0.993969
  0.982173 0.994392 0.994515 0.994812 0.990902 0.985336 0.988935 0.985667 0.969589 0.975707
  0.993211 0.995626 0.998417 0.997614 0.996270 0.994196 0.992213 0.991786 0.999133 0.999076`
- Chunks 100–111: `0.011480 0.010318 0.328179 0.986911 0.993888 0.996613 0.997235 0.996491
  0.995476 0.994227 0.990990 0.990487`
- Chunks 334–343: `0.121045 0.054677 0.074704 0.049087 0.075991 0.162988 0.074060 0.513290
  0.876224 0.638498`
- `get_speech_timestamps` (samples): [5152, 36320], [52256, 71136], [86048, 122848],
  [130592, 169952].
- `VADIterator` events as (chunk index, event): (11, start 5152), (74, end 36320),
  (103, start 52256), (142, end 71136), (169, start 86048), (243, end 122848),
  (256, start 130592), (335, end 169952), (341, start 174112).

The per-chunk probability file and the scripts used are in the research scratchpad; rebuild them
from the outline above rather than depending on it.

## 9. Gotchas

- **Feed 576 samples, not 512.** Keep the previous chunk's last 64 samples yourself, zeros on the
  first step and after a reset. Reflect-padding instead (whisper.cpp) costs up to 0.2 in
  probability.
- The right pad is **reflect**, 64 samples, edge not repeated (`[a b c d] → [a b c d c b]`).
  `ggml_pad_reflect_1d(x, 0, 64)` has exactly these semantics.
- **Do not use `ggml_conv_1d` if you want to match the reference.** It rounds activations to F16
  via im2col. Use `ggml_im2col(..., GGML_TYPE_F32)` + `ggml_mul_mat` (section 6).
- Gate order is i, f, g, o (PyTorch), and the carried h is pre-ReLU.
- `silero_vad_16k.safetensors` is not v6.2 and `silero_vad_half.onnx` is v5. Take weights from
  the JIT, `silero_vad_16k_op15.onnx` or `ggml-silero-v6.2.0.bin`.
- `mean(dim=1)` in the output head averages a single element. Do not read it as "average over
  frames".
- Audio must be 16 kHz mono float in [−1, 1] (int16 / 32768). The wrappers accept multiples of
  16 kHz by taking every n-th sample (no low-pass). Resample properly on the host.
- The last partial chunk is zero-padded to 512 by every official wrapper. In streaming, just wait
  for a full chunk.
- Batching changes nothing numerically, but the official wrappers reset the state when the batch
  size or sample rate changes between calls.

## 10. Port

Ported 2026-09-10 to `console/ml/silero_vad.lua`, with `console/ml/convert/silero_vad.lua` and
`test/ml_silero_vad_test.lua`.

    local vad = require("console.ml.silero_vad").load(engine, "console/ml/models/silero-vad.gguf")
    vad:step(samples)   -- 512 new samples at 16 kHz -> p(speech); vad:reset(); vad:run(clip) -> buffer of p

**Weights.** The converter reads `silero_vad_16k_op15.onnx` in Lua (a protobuf walk of four
fields, section 4) and writes every tensor as f32 under its state-dict name without `model.`:
1,239,872 bytes. Neither `ggml-silero-v6.2.0.bin` (its conv kernels are f16) nor a Python export
was needed. The file goes in `console/ml/models/` with `jfk.wav` for the test.

**State.** The 64 samples of context and the LSTM's h and c are three tensors in a set on the
engine's device. The graph is built once, reads them, and writes them back with `cpy`, so a step
moves 512 samples in and one number out. The writes are expanded after the output: ggml sees no
edge between a write into a set and an earlier read of it, so the graph's order has to be the
edge. `run` resets first, as `get_speech_timestamps` does, and zero-pads the last window.

**Checked.** Against the official `silero_vad.jit` (PyTorch 2.8) on `jfk.wav`, all 344 windows
from one reset, the reference printed to 7 decimals:

| where | max \|Δp\| | mean \|Δp\| |
|---|---:|---:|
| CPU | 1.5e-6 | 1.0e-7 |
| Metal (M4) | 1.2e-6 | 7.2e-8 |

The test also steps the first 112 windows one at a time, then resets and runs windows 101–112
cold against the JIT reset at the same point (window 104 is 0.987 streamed and 0.768 cold), so
both the carried state and the reset are checked against the reference. 234 windows reach 0.5,
as in section 8. Tolerances in the test: 1e-5 on the CPU, 1e-4 on the device.

**Speed** (Apple M4, wall clock, the same on LuaJIT and Lua 5.5): 60 µs a step on the CPU with
one thread (65 µs with four: the ops are too small to share), 330–340 µs on Metal, where the
dispatch is the cost. A step is 32 ms of audio, so the CPU runs it about 530 times faster than
real time. Give the VAD its own `ml.engine { device = "cpu", threads = 1 }` even when the
program has a GPU for other models.

**For the next person.**

- `pad_reflect_1d` was added to `core.c` for the right-side pad (section 9's semantics).
- Metal's matrix-matrix kernel (`kernel_mul_mm_f32_f32`, taken when the second operand has more
  than 8 columns and the rows are 64 or longer) stages **both** operands in half precision. With
  the kernel as the second operand of the conv's product, the DFT's 258 rows sent the audio
  through half precision and p moved by 2e-3 from the first window. The conv here puts the kernel
  first and the frames (4 at most) second, so every product takes the f32 matrix-vector kernel,
  and each conv's output is transposed back to [time, channels] for the next im2col.
- The graph is one split on Metal: `concat`, `pad_reflect_1d`, `im2col` and the rest all have
  Metal kernels.
