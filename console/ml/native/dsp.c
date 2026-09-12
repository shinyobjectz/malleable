/*
 * dsp.c -- the front end speech models share: spectra and mel filters (spec/ml.md).
 *
 * A mixed-radix FFT (any length: Whisper's window is 400 = 2^4 * 5^2), a power STFT with
 * a Hann window and reflect padding, Slaney or HTK mel filters, and Whisper's log-mel
 * recipe exactly as openai/whisper and the transformers feature extractor compute it.
 */
#include "ml.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* ================================================================== FFT */

typedef struct { double re, im; } cpx;

/* One length's transform: its twiddles e^(-2 pi i t / n), made once, and a scratch. */
typedef struct { int n; cpx *tw; cpx *scratch; } fft_plan;

static fft_plan fft_plan_new(int n) {
  fft_plan p = { n, (cpx *)malloc(sizeof(cpx) * (size_t)n), (cpx *)malloc(sizeof(cpx) * (size_t)n * 2) };
  for (int t = 0; t < n; t++) { double a = -2 * M_PI * t / n; p.tw[t].re = cos(a); p.tw[t].im = sin(a); }
  return p;
}

static void fft_plan_free(fft_plan *p) { free(p->tw); free(p->scratch); }

/* out[k] = sum_j in[j*stride] e^(-2 pi i j k / n), recursive on the smallest factor. The
 * angle r k / n of a sub-transform is (r k mod n) * (N / n) of the plan's N. */
static void fft_rec(const cpx *in, cpx *out, int n, int stride, cpx *scratch, const cpx *tw, int N) {
  if (n == 1) { out[0] = in[0]; return; }
  int p = 2;
  while (p * p <= n && n % p) p++;
  if (n % p) p = n;                      /* n is prime: one DFT of n */
  int m = n / p, step = N / n;
  if (p == n) {
    for (int k = 0; k < n; k++) {
      double re = 0, im = 0;
      for (int j = 0; j < n; j++) {
        cpx w = tw[(size_t)((long)j * k % n) * (size_t)step], x = in[j * stride];
        re += x.re * w.re - x.im * w.im;
        im += x.re * w.im + x.im * w.re;
      }
      out[k].re = re; out[k].im = im;
    }
    return;
  }
  /* p sub-transforms of length m, each over every p-th sample */
  for (int r = 0; r < p; r++) fft_rec(in + r * stride, scratch + r * m, m, stride * p, out, tw, N);
  for (int k = 0; k < n; k++) {
    double re = 0, im = 0;
    int km = k % m;
    for (int r = 0; r < p; r++) {
      cpx w = tw[(size_t)((long)r * k % n) * (size_t)step], x = scratch[r * m + km];
      re += x.re * w.re - x.im * w.im;
      im += x.re * w.im + x.im * w.re;
    }
    out[k].re = re; out[k].im = im;
  }
}

/* The scratch of each level must not alias the output of the level above: fft_rec uses
 * `out` of the caller as the children's scratch, so the top call gets the plan's own. */
static void fft(const fft_plan *plan, const cpx *in, cpx *out) {
  fft_rec(in, out, plan->n, 1, plan->scratch, plan->tw, plan->n);
}

/* ================================================================== STFT */

/* Power spectrum frames: frames x (n_fft/2 + 1), bins fastest. center pads n_fft/2 on each
 * side by reflection, as torch.stft and numpy do. */
static float *stft_power(const float *x, size_t n, int n_fft, int hop, int center, const double *win, size_t *frames_out) {
  size_t pad = center ? (size_t)n_fft / 2 : 0;
  size_t len = n + 2 * pad;
  if (len < (size_t)n_fft) { *frames_out = 0; return NULL; }
  float *padded = (float *)malloc(sizeof(float) * len);
  for (size_t i = 0; i < len; i++) {
    long j = (long)i - (long)pad;
    if (n == 1) j = 0;
    while (j < 0 || j >= (long)n) {       /* reflect, without repeating the edge */
      if (j < 0) j = -j;
      if (j >= (long)n) j = 2 * ((long)n - 1) - j;
    }
    padded[i] = x[j];
  }
  size_t frames = 1 + (len - (size_t)n_fft) / (size_t)hop;
  int bins = n_fft / 2 + 1;
  float *out = (float *)malloc(sizeof(float) * frames * (size_t)bins);
  cpx *in = (cpx *)malloc(sizeof(cpx) * (size_t)n_fft), *sp = (cpx *)malloc(sizeof(cpx) * (size_t)n_fft);
  fft_plan plan = fft_plan_new(n_fft);
  for (size_t f = 0; f < frames; f++) {
    for (int j = 0; j < n_fft; j++) { in[j].re = padded[f * (size_t)hop + (size_t)j] * win[j]; in[j].im = 0; }
    fft(&plan, in, sp);
    for (int k = 0; k < bins; k++) out[f * (size_t)bins + (size_t)k] = (float)(sp[k].re * sp[k].re + sp[k].im * sp[k].im);
  }
  fft_plan_free(&plan);
  free(in); free(sp); free(padded);
  *frames_out = frames;
  return out;
}

static double *hann(int n, int periodic) {
  double *w = (double *)malloc(sizeof(double) * (size_t)n);
  int d = periodic ? n : n - 1;
  for (int i = 0; i < n; i++) w[i] = 0.5 - 0.5 * cos(2 * M_PI * i / (d > 0 ? d : 1));
  return w;
}

/* ================================================================== mel */

static double hz_to_mel(double f, int htk) {
  if (htk) return 2595.0 * log10(1.0 + f / 700.0);
  double f_sp = 200.0 / 3, min_log_hz = 1000.0, min_log_mel = min_log_hz / f_sp, logstep = log(6.4) / 27.0;
  return f < min_log_hz ? f / f_sp : min_log_mel + log(f / min_log_hz) / logstep;
}

static double mel_to_hz(double m, int htk) {
  if (htk) return 700.0 * (pow(10.0, m / 2595.0) - 1.0);
  double f_sp = 200.0 / 3, min_log_hz = 1000.0, min_log_mel = min_log_hz / f_sp, logstep = log(6.4) / 27.0;
  return m < min_log_mel ? f_sp * m : min_log_hz * exp(logstep * (m - min_log_mel));
}

/* n_mels x bins, as librosa.filters.mel computes them: triangles between mel-spaced edges,
 * divided by their width when norm is slaney. */
static float *mel_filters(double sr, int n_fft, int n_mels, double fmin, double fmax, int htk, int slaney_norm) {
  int bins = n_fft / 2 + 1;
  float *fb = (float *)calloc((size_t)n_mels * (size_t)bins, sizeof(float));
  double *edges = (double *)malloc(sizeof(double) * (size_t)(n_mels + 2));
  double lo = hz_to_mel(fmin, htk), hi = hz_to_mel(fmax, htk);
  for (int i = 0; i < n_mels + 2; i++) edges[i] = mel_to_hz(lo + (hi - lo) * i / (n_mels + 1), htk);
  for (int m = 0; m < n_mels; m++) {
    double left = edges[m], center = edges[m + 1], right = edges[m + 2];
    double enorm = slaney_norm ? 2.0 / (right - left) : 1.0;
    for (int k = 0; k < bins; k++) {
      double f = sr * k / n_fft;
      double lower = (f - left) / (center - left), upper = (right - f) / (right - center);
      double v = lower < upper ? lower : upper;
      if (v < 0) v = 0;
      fb[(size_t)m * (size_t)bins + (size_t)k] = (float)(v * enorm);
    }
  }
  free(edges);
  return fb;
}

/* ml.mel_filters(rate, n_fft, n_mels [, { fmin = 0, fmax = rate/2, htk = false, norm = "slaney" }])
 * -> buffer n_mels x (n_fft/2 + 1), a row per mel */
static int l_mel_filters(lua_State *L) {
  double sr = luaL_checknumber(L, 1);
  int n_fft = (int)ml_checkint(L, 2), n_mels = (int)ml_checkint(L, 3);
  double fmin = 0, fmax = sr / 2;
  int htk = 0, slaney = 1;
  if (lua_istable(L, 4)) {
    lua_getfield(L, 4, "fmin"); fmin = luaL_optnumber(L, -1, 0); lua_pop(L, 1);
    lua_getfield(L, 4, "fmax"); fmax = luaL_optnumber(L, -1, sr / 2); lua_pop(L, 1);
    lua_getfield(L, 4, "htk"); htk = lua_toboolean(L, -1); lua_pop(L, 1);
    lua_getfield(L, 4, "norm");
    if (lua_isstring(L, -1)) slaney = strcmp(lua_tostring(L, -1), "slaney") == 0;
    else if (lua_isboolean(L, -1)) slaney = lua_toboolean(L, -1);
    lua_pop(L, 1);
  }
  int bins = n_fft / 2 + 1;
  float *fb = mel_filters(sr, n_fft, n_mels, fmin, fmax, htk, slaney);
  ml_buffer *b = ml_newbuffer(L, ML_F32, (size_t)n_mels * (size_t)bins);
  memcpy(b->data.f, fb, sizeof(float) * (size_t)n_mels * (size_t)bins);
  free(fb);
  return 1;
}

/* ml.stft_power(samples, n_fft, hop [, { center = true, periodic = true }]) -> buffer
 * frames x bins (bins fastest), frames */
static int l_stft_power(lua_State *L) {
  ml_buffer *x = ml_checkbuffer(L, 1);
  int n_fft = (int)ml_checkint(L, 2), hop = (int)ml_checkint(L, 3);
  int center = 1, periodic = 1;
  if (lua_istable(L, 4)) {
    lua_getfield(L, 4, "center"); if (!lua_isnil(L, -1)) center = lua_toboolean(L, -1); lua_pop(L, 1);
    lua_getfield(L, 4, "periodic"); if (!lua_isnil(L, -1)) periodic = lua_toboolean(L, -1); lua_pop(L, 1);
  }
  if (x->type != ML_F32 || x->n == 0) return luaL_argerror(L, 1, "f32 samples");
  double *win = hann(n_fft, periodic);
  size_t frames;
  float *p = stft_power(x->data.f, x->n, n_fft, hop, center, win, &frames);
  free(win);
  int bins = n_fft / 2 + 1;
  ml_buffer *b = ml_newbuffer(L, ML_F32, frames * (size_t)bins);
  if (p) memcpy(b->data.f, p, sizeof(float) * frames * (size_t)bins);
  free(p);
  lua_pushinteger(L, (lua_Integer)frames);
  return 2;
}

/* ml.whisper_mel(samples [, n_mels = 80 [, n_frames]]) -> buffer n_mels x frames (frames
 * fastest, as a conv over time reads it), frames.
 *
 * openai/whisper's log_mel_spectrogram: 16 kHz, n_fft 400, hop 160, periodic Hann, reflect
 * padding, |STFT|^2 with the last frame dropped, Slaney mel filters, log10 clamped at 1e-10,
 * floored at the maximum minus 8, then (x + 4) / 4. With n_frames the result is cut or
 * padded to that many frames; padding is the log of silence, as the extractor's is when it
 * pads the audio with zeros first. */
static int l_whisper_mel(lua_State *L) {
  ml_buffer *x = ml_checkbuffer(L, 1);
  int n_mels = (int)ml_optint(L, 2, 80);
  int64_t want = ml_optint(L, 3, -1);
  const int n_fft = 400, hop = 160;
  if (x->type != ML_F32 || x->n < 2) return luaL_argerror(L, 1, "f32 samples at 16 kHz");
  double *win = hann(n_fft, 1);
  size_t frames;
  float *p = stft_power(x->data.f, x->n, n_fft, hop, 1, win, &frames);
  free(win);
  if (!p || frames < 2) { free(p); return luaL_argerror(L, 1, "too few samples for one frame"); }
  frames -= 1;                          /* whisper drops the last frame */
  int bins = n_fft / 2 + 1;
  float *fb = mel_filters(16000, n_fft, n_mels, 0, 8000, 0, 1);
  size_t out_frames = want > 0 ? (size_t)want : frames;
  ml_buffer *b = ml_newbuffer(L, ML_F32, (size_t)n_mels * out_frames);
  double mx = -1e30;
  for (int m = 0; m < n_mels; m++) {
    for (size_t t = 0; t < out_frames; t++) {
      double v = 0;
      if (t < frames) for (int k = 0; k < bins; k++) v += (double)fb[(size_t)m * (size_t)bins + (size_t)k] * p[t * (size_t)bins + (size_t)k];
      v = log10(v < 1e-10 ? 1e-10 : v);
      b->data.f[(size_t)m * out_frames + t] = (float)v;
      if (v > mx) mx = v;
    }
  }
  for (size_t i = 0; i < b->n; i++) {
    double v = b->data.f[i];
    if (v < mx - 8.0) v = mx - 8.0;
    b->data.f[i] = (float)((v + 4.0) / 4.0);
  }
  free(fb); free(p);
  lua_pushinteger(L, (lua_Integer)out_frames);
  return 2;
}

static const luaL_Reg dsp_functions[] = {
  { "mel_filters", l_mel_filters }, { "stft_power", l_stft_power }, { "whisper_mel", l_whisper_mel },
  { NULL, NULL }
};

void ml_open_dsp(lua_State *L) {
  luaL_setfuncs(L, dsp_functions, 0);
}
