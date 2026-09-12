/*
 * io.c -- files: GGUF out, safetensors in, WAV both ways, and resampling (spec/ml.md).
 *
 * The engine runs GGUF only. A checkpoint that ships as safetensors is converted once,
 * by a Lua script over these calls (console/ml/convert/), so the console needs no Python.
 */
#include "ml.h"

#include <ctype.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gguf.h"

/* ================================================================== a small JSON reader
 * Enough for a safetensors header: objects, arrays, strings, numbers, true/false/null,
 * pushed as Lua values. */

typedef struct { const char *s, *end; } jp;

static void j_ws(jp *p) { while (p->s < p->end && isspace((unsigned char)*p->s)) p->s++; }

static int j_value(lua_State *L, jp *p, int depth);

static int j_string(lua_State *L, jp *p) {
  if (p->s >= p->end || *p->s != '"') return 0;
  p->s++;
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  while (p->s < p->end && *p->s != '"') {
    char c = *p->s++;
    if (c == '\\' && p->s < p->end) {
      char e = *p->s++;
      switch (e) {
        case 'n': luaL_addchar(&b, '\n'); break;
        case 't': luaL_addchar(&b, '\t'); break;
        case 'r': luaL_addchar(&b, '\r'); break;
        case 'b': luaL_addchar(&b, '\b'); break;
        case 'f': luaL_addchar(&b, '\f'); break;
        case 'u': {
          unsigned cp = 0;
          for (int k = 0; k < 4 && p->s < p->end; k++) {
            char h = *p->s++;
            cp = cp * 16 + (unsigned)(isdigit((unsigned char)h) ? h - '0' : (tolower((unsigned char)h) - 'a' + 10));
          }
          if (cp < 0x80) luaL_addchar(&b, (char)cp);
          else if (cp < 0x800) { luaL_addchar(&b, (char)(0xC0 | (cp >> 6))); luaL_addchar(&b, (char)(0x80 | (cp & 0x3F))); }
          else { luaL_addchar(&b, (char)(0xE0 | (cp >> 12))); luaL_addchar(&b, (char)(0x80 | ((cp >> 6) & 0x3F))); luaL_addchar(&b, (char)(0x80 | (cp & 0x3F))); }
          break;
        }
        default: luaL_addchar(&b, e);
      }
    } else {
      luaL_addchar(&b, c);
    }
  }
  if (p->s >= p->end) return 0;
  p->s++;
  luaL_pushresult(&b);
  return 1;
}

static int j_value(lua_State *L, jp *p, int depth) {
  if (depth > 64) return 0;
  j_ws(p);
  if (p->s >= p->end) return 0;
  char c = *p->s;
  if (c == '{') {
    p->s++;
    lua_newtable(L);
    j_ws(p);
    if (p->s < p->end && *p->s == '}') { p->s++; return 1; }
    for (;;) {
      j_ws(p);
      if (!j_string(L, p)) return 0;
      j_ws(p);
      if (p->s >= p->end || *p->s != ':') return 0;
      p->s++;
      if (!j_value(L, p, depth + 1)) return 0;
      lua_rawset(L, -3);
      j_ws(p);
      if (p->s < p->end && *p->s == ',') { p->s++; continue; }
      if (p->s < p->end && *p->s == '}') { p->s++; return 1; }
      return 0;
    }
  }
  if (c == '[') {
    p->s++;
    lua_newtable(L);
    int k = 1;
    j_ws(p);
    if (p->s < p->end && *p->s == ']') { p->s++; return 1; }
    for (;;) {
      if (!j_value(L, p, depth + 1)) return 0;
      lua_rawseti(L, -2, k++);
      j_ws(p);
      if (p->s < p->end && *p->s == ',') { p->s++; continue; }
      if (p->s < p->end && *p->s == ']') { p->s++; return 1; }
      return 0;
    }
  }
  if (c == '"') return j_string(L, p);
  if (!strncmp(p->s, "true", 4)) { p->s += 4; lua_pushboolean(L, 1); return 1; }
  if (!strncmp(p->s, "false", 5)) { p->s += 5; lua_pushboolean(L, 0); return 1; }
  if (!strncmp(p->s, "null", 4)) { p->s += 4; lua_pushnil(L); return 1; }
  char *after;
  double v = strtod(p->s, &after);
  if (after == p->s) return 0;
  p->s = after;
  lua_pushnumber(L, v);
  return 1;
}

/* ml.json(text) -> a Lua value */
static int l_json(lua_State *L) {
  size_t len;
  const char *s = luaL_checklstring(L, 1, &len);
  jp p = { s, s + len };
  int top = lua_gettop(L);
  if (!j_value(L, &p, 0)) { lua_settop(L, top); return luaL_error(L, "ml.json: not JSON the reader understands"); }
  return 1;
}

/* ================================================================== safetensors */

#define ML_ST "ml.safetensors"

typedef struct { FILE *f; uint64_t data_start; } ml_st;

/* ml.safetensors(path) -> reader, header table */
static int l_safetensors(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  FILE *f = fopen(path, "rb");
  if (!f) return luaL_error(L, "ml.safetensors: could not open \"%s\"", path);
  unsigned char lenb[8];
  if (fread(lenb, 1, 8, f) != 8) { fclose(f); return luaL_error(L, "ml.safetensors: \"%s\" is too short", path); }
  uint64_t hlen = 0;
  for (int k = 7; k >= 0; k--) hlen = (hlen << 8) | lenb[k];
  if (hlen > (100u << 20)) { fclose(f); return luaL_error(L, "ml.safetensors: \"%s\" has a header of %d bytes", path, (int)hlen); }
  char *h = (char *)malloc(hlen);
  if (fread(h, 1, hlen, f) != hlen) { free(h); fclose(f); return luaL_error(L, "ml.safetensors: \"%s\" ends in its header", path); }
  ml_st *st = (ml_st *)lua_newuserdata(L, sizeof(ml_st));
  st->f = f;
  st->data_start = 8 + hlen;
  luaL_setmetatable(L, ML_ST);
  jp p = { h, h + hlen };
  int ok = j_value(L, &p, 0);
  free(h);
  if (!ok) return luaL_error(L, "ml.safetensors: \"%s\" has a header that is not JSON", path);
  return 2;
}

static float bf16_to_f32(uint16_t v) { uint32_t u = (uint32_t)v << 16; float f; memcpy(&f, &u, 4); return f; }

/* reader:read(dtype, begin, end) -> f32 buffer (or i32 for integer tensors), the bytes
 * data_offsets names, converted: F32, F16, BF16, F64, I64, I32, I16, I8, U8, BOOL */
static int st_read(lua_State *L) {
  ml_st *st = (ml_st *)luaL_checkudata(L, 1, ML_ST);
  if (!st->f) return luaL_error(L, "the safetensors reader was closed");
  const char *dtype = luaL_checkstring(L, 2);
  uint64_t a = (uint64_t)ml_checkint(L, 3), b = (uint64_t)ml_checkint(L, 4);
  if (b < a) return luaL_error(L, "reader:read: the offsets run backwards");
  size_t size = (size_t)(b - a);
  unsigned char *raw = (unsigned char *)malloc(size ? size : 1);
  if (fseek(st->f, (long)(st->data_start + a), SEEK_SET) != 0 || fread(raw, 1, size, st->f) != size) {
    free(raw);
    return luaL_error(L, "reader:read: the file ends inside the tensor");
  }
  ml_buffer *out;
  if (!strcmp(dtype, "F32")) { out = ml_newbuffer(L, ML_F32, size / 4); memcpy(out->data.f, raw, size); }
  else if (!strcmp(dtype, "BF16")) {
    out = ml_newbuffer(L, ML_F32, size / 2);
    for (size_t k = 0; k < size / 2; k++) out->data.f[k] = bf16_to_f32((uint16_t)(raw[2 * k] | (raw[2 * k + 1] << 8)));
  } else if (!strcmp(dtype, "F16")) {
    out = ml_newbuffer(L, ML_F32, size / 2);
    for (size_t k = 0; k < size / 2; k++) out->data.f[k] = ggml_fp16_to_fp32((ggml_fp16_t)(raw[2 * k] | (raw[2 * k + 1] << 8)));
  } else if (!strcmp(dtype, "F64")) {
    out = ml_newbuffer(L, ML_F32, size / 8);
    for (size_t k = 0; k < size / 8; k++) { double d; memcpy(&d, raw + 8 * k, 8); out->data.f[k] = (float)d; }
  } else if (!strcmp(dtype, "I64")) {
    out = ml_newbuffer(L, ML_I32, size / 8);
    for (size_t k = 0; k < size / 8; k++) { int64_t v; memcpy(&v, raw + 8 * k, 8); out->data.i[k] = (int32_t)v; }
  } else if (!strcmp(dtype, "I32")) { out = ml_newbuffer(L, ML_I32, size / 4); memcpy(out->data.i, raw, size); }
  else if (!strcmp(dtype, "I16")) {
    out = ml_newbuffer(L, ML_I32, size / 2);
    for (size_t k = 0; k < size / 2; k++) out->data.i[k] = (int16_t)(raw[2 * k] | (raw[2 * k + 1] << 8));
  } else if (!strcmp(dtype, "I8")) {
    out = ml_newbuffer(L, ML_I32, size);
    for (size_t k = 0; k < size; k++) out->data.i[k] = (int8_t)raw[k];
  } else if (!strcmp(dtype, "U8") || !strcmp(dtype, "BOOL")) {
    out = ml_newbuffer(L, ML_I32, size);
    for (size_t k = 0; k < size; k++) out->data.i[k] = raw[k];
  } else {
    free(raw);
    return luaL_error(L, "reader:read: the dtype %s is not one the engine reads", dtype);
  }
  free(raw);
  (void)out;
  return 1;
}

static int st_close(lua_State *L) {
  ml_st *st = (ml_st *)luaL_checkudata(L, 1, ML_ST);
  if (st->f) fclose(st->f);
  st->f = NULL;
  return 0;
}

/* ================================================================== GGUF writing */

#define ML_GW "ml.gguf_writer"

typedef struct {
  struct gguf_context *gguf;
  struct ggml_context **ctxs;   /* one small context per tensor, holding its converted data */
  int n, cap;
} ml_gw;

/* ml.gguf_writer() -> writer */
static int l_gguf_writer(lua_State *L) {
  ml_gw *w = (ml_gw *)lua_newuserdata(L, sizeof(ml_gw));
  memset(w, 0, sizeof(*w));
  w->gguf = gguf_init_empty();
  luaL_setmetatable(L, ML_GW);
  return 1;
}

static ml_gw *check_gw(lua_State *L) {
  ml_gw *w = (ml_gw *)luaL_checkudata(L, 1, ML_GW);
  if (!w->gguf) luaL_error(L, "the GGUF writer was closed");
  return w;
}

/* writer:set(key, value [, type]) -- a string, a boolean, a number (f32 unless type says
 * "u32", "i32", "u64", "f64"), or a list of strings or numbers (type as for numbers) */
static int gw_set(lua_State *L) {
  ml_gw *w = check_gw(L);
  const char *key = luaL_checkstring(L, 2);
  const char *type = luaL_optstring(L, 4, "f32");
  int t = lua_type(L, 3);
  if (t == LUA_TSTRING) { gguf_set_val_str(w->gguf, key, lua_tostring(L, 3)); return 0; }
  if (t == LUA_TBOOLEAN) { gguf_set_val_bool(w->gguf, key, lua_toboolean(L, 3)); return 0; }
  if (t == LUA_TNUMBER) {
    double v = lua_tonumber(L, 3);
    if (!strcmp(type, "u32")) gguf_set_val_u32(w->gguf, key, (uint32_t)v);
    else if (!strcmp(type, "i32")) gguf_set_val_i32(w->gguf, key, (int32_t)v);
    else if (!strcmp(type, "u64")) gguf_set_val_u64(w->gguf, key, (uint64_t)v);
    else if (!strcmp(type, "f64")) gguf_set_val_f64(w->gguf, key, v);
    else gguf_set_val_f32(w->gguf, key, (float)v);
    return 0;
  }
  if (t == LUA_TTABLE) {
    size_t n = ml_rawlen(L, 3);
    lua_rawgeti(L, 3, 1);
    bool strings = lua_type(L, -1) == LUA_TSTRING;
    lua_pop(L, 1);
    if (strings) {
      const char **list = (const char **)malloc(sizeof(char *) * (n ? n : 1));
      for (size_t k = 0; k < n; k++) { lua_rawgeti(L, 3, (int)k + 1); list[k] = luaL_checkstring(L, -1); lua_pop(L, 1); }
      /* the strings stay on the table argument, alive through the call */
      gguf_set_arr_str(w->gguf, key, list, n);
      free(list);
      return 0;
    }
    if (!strcmp(type, "i32") || !strcmp(type, "u32")) {
      int32_t *a = (int32_t *)malloc(sizeof(int32_t) * (n ? n : 1));
      for (size_t k = 0; k < n; k++) { lua_rawgeti(L, 3, (int)k + 1); a[k] = (int32_t)luaL_checknumber(L, -1); lua_pop(L, 1); }
      gguf_set_arr_data(w->gguf, key, !strcmp(type, "i32") ? GGUF_TYPE_INT32 : GGUF_TYPE_UINT32, a, n);
      free(a);
    } else {
      float *a = (float *)malloc(sizeof(float) * (n ? n : 1));
      for (size_t k = 0; k < n; k++) { lua_rawgeti(L, 3, (int)k + 1); a[k] = (float)luaL_checknumber(L, -1); lua_pop(L, 1); }
      gguf_set_arr_data(w->gguf, key, GGUF_TYPE_FLOAT32, a, n);
      free(a);
    }
    return 0;
  }
  return luaL_argerror(L, 3, "a string, boolean, number or list");
}

/* writer:add(name, buffer, { ne0, ne1, ... }, type) -- a tensor, converted from the f32
 * (or i32) buffer to type: f32, f16, bf16, i32, or a quantized type (q8_0, q4_0, q4_K,
 * q5_K, q6_K ...; rows must be a whole number of blocks) */
static int gw_add(lua_State *L) {
  ml_gw *w = check_gw(L);
  const char *name = luaL_checkstring(L, 2);
  ml_buffer *b = ml_checkbuffer(L, 3);
  luaL_checktype(L, 4, LUA_TTABLE);
  int dims = (int)ml_rawlen(L, 4);
  if (dims < 1 || dims > 4) return luaL_argerror(L, 4, "1 to 4 sizes");
  int64_t ne[4] = {1, 1, 1, 1};
  int64_t count = 1;
  for (int k = 0; k < dims; k++) { lua_rawgeti(L, 4, k + 1); ne[k] = ml_checkint(L, -1); lua_pop(L, 1); count *= ne[k]; }
  if ((size_t)count != b->n) return luaL_error(L, "writer:add %s: the shape holds %d values and the buffer %d", name, (int)count, (int)b->n);
  enum ggml_type type = ml_opttype(L, 5, b->type == ML_I32 ? GGML_TYPE_I32 : GGML_TYPE_F32);
  if (b->type == ML_I32 && type != GGML_TYPE_I32) return luaL_error(L, "writer:add %s: an i32 buffer is written as i32", name);
  if (b->type == ML_F32 && type == GGML_TYPE_I32) return luaL_error(L, "writer:add %s: an f32 buffer cannot be written as i32", name);
  if (ne[0] % ggml_blck_size(type) != 0) {
    return luaL_error(L, "writer:add %s: rows of %d values are not whole %s blocks of %d", name, (int)ne[0], ggml_type_name(type), (int)ggml_blck_size(type));
  }

  size_t row = ggml_row_size(type, ne[0]);
  size_t nrows = (size_t)(count / ne[0]);
  struct ggml_init_params p = { ggml_tensor_overhead() + row * nrows + 64, NULL, false };
  struct ggml_context *ctx = ggml_init(p);
  if (!ctx) return luaL_error(L, "writer:add %s: out of memory", name);
  struct ggml_tensor *t = ggml_new_tensor(ctx, type, dims, ne);
  ggml_set_name(t, name);
  if (type == GGML_TYPE_F32 || type == GGML_TYPE_I32) memcpy(t->data, b->data.p, b->n * 4);
  else if (type == GGML_TYPE_F16) ggml_fp32_to_fp16_row(b->data.f, (ggml_fp16_t *)t->data, count);
  else if (type == GGML_TYPE_BF16) ggml_fp32_to_bf16_row(b->data.f, (ggml_bf16_t *)t->data, count);
  else ggml_quantize_chunk(type, b->data.f, t->data, 0, (int64_t)nrows, ne[0], NULL);

  if (w->n == w->cap) {
    w->cap = w->cap ? w->cap * 2 : 64;
    w->ctxs = (struct ggml_context **)realloc(w->ctxs, sizeof(*w->ctxs) * (size_t)w->cap);
  }
  w->ctxs[w->n++] = ctx;
  gguf_add_tensor(w->gguf, t);
  return 0;
}

/* writer:write(path) */
static int gw_write(lua_State *L) {
  ml_gw *w = check_gw(L);
  const char *path = luaL_checkstring(L, 2);
  if (!gguf_write_to_file(w->gguf, path, false)) return luaL_error(L, "writer:write: could not write \"%s\"", path);
  return 0;
}

static int gw_close(lua_State *L) {
  ml_gw *w = (ml_gw *)luaL_checkudata(L, 1, ML_GW);
  if (w->gguf) gguf_free(w->gguf);
  for (int k = 0; k < w->n; k++) ggml_free(w->ctxs[k]);
  free(w->ctxs);
  w->gguf = NULL; w->ctxs = NULL; w->n = w->cap = 0;
  return 0;
}

/* ================================================================== WAV */

static uint32_t rd32(const unsigned char *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint16_t rd16(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }

/* ml.wav_read(path) -> buffer of mono f32 samples in [-1, 1], sample rate, channels.
 * PCM 8/16/24/32-bit and IEEE float; several channels are averaged into one. */
static int l_wav_read(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  FILE *f = fopen(path, "rb");
  if (!f) return luaL_error(L, "ml.wav_read: could not open \"%s\"", path);
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *d = (unsigned char *)malloc((size_t)len);
  if (fread(d, 1, (size_t)len, f) != (size_t)len) { fclose(f); free(d); return luaL_error(L, "ml.wav_read: could not read \"%s\"", path); }
  fclose(f);
  if (len < 12 || memcmp(d, "RIFF", 4) || memcmp(d + 8, "WAVE", 4)) { free(d); return luaL_error(L, "ml.wav_read: \"%s\" is not a WAV file", path); }
  uint16_t fmt = 0, channels = 0, bits = 0;
  uint32_t rate = 0;
  const unsigned char *data = NULL;
  uint32_t data_len = 0;
  long at = 12;
  while (at + 8 <= len) {
    uint32_t size = rd32(d + at + 4);
    if (!memcmp(d + at, "fmt ", 4) && size >= 16) {
      fmt = rd16(d + at + 8); channels = rd16(d + at + 10); rate = rd32(d + at + 12); bits = rd16(d + at + 22);
      if (fmt == 0xFFFE && size >= 26) fmt = rd16(d + at + 32);   /* WAVE_FORMAT_EXTENSIBLE: the subformat */
    } else if (!memcmp(d + at, "data", 4)) {
      data = d + at + 8;
      data_len = size;
      if ((long)(at + 8 + data_len) > len) data_len = (uint32_t)(len - at - 8);
      break;
    }
    at += 8 + size + (size & 1);
  }
  if (!data || !channels || !bits) { free(d); return luaL_error(L, "ml.wav_read: \"%s\" has no fmt or data chunk", path); }
  size_t bps = bits / 8, frames = data_len / (bps * channels);
  ml_buffer *b = ml_newbuffer(L, ML_F32, frames);
  for (size_t k = 0; k < frames; k++) {
    double sum = 0;
    for (int c = 0; c < channels; c++) {
      const unsigned char *s = data + (k * channels + (size_t)c) * bps;
      double v = 0;
      if (fmt == 3 && bits == 32) { float x; memcpy(&x, s, 4); v = x; }
      else if (fmt == 3 && bits == 64) { double x; memcpy(&x, s, 8); v = x; }
      else if (bits == 8) v = ((double)s[0] - 128.0) / 128.0;
      else if (bits == 16) v = (double)(int16_t)rd16(s) / 32768.0;
      else if (bits == 24) { int32_t x = (int32_t)((uint32_t)s[0] << 8 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 24) >> 8; v = x / 8388608.0; }
      else if (bits == 32) v = (double)(int32_t)rd32(s) / 2147483648.0;
      sum += v;
    }
    b->data.f[k] = (float)(sum / channels);
  }
  free(d);
  lua_pushinteger(L, (lua_Integer)rate);
  lua_pushinteger(L, channels);
  return 3;
}

static void wr32(unsigned char *p, uint32_t v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; p[2] = (v >> 16) & 0xff; p[3] = (v >> 24) & 0xff; }
static void wr16(unsigned char *p, uint16_t v) { p[0] = v & 0xff; p[1] = (v >> 8) & 0xff; }

/* ml.wav_write(path, buffer, rate) -- mono 16-bit PCM */
static int l_wav_write(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  ml_buffer *b = ml_checkbuffer(L, 2);
  uint32_t rate = (uint32_t)ml_checkint(L, 3);
  if (b->type != ML_F32) return luaL_argerror(L, 2, "f32 samples");
  FILE *f = fopen(path, "wb");
  if (!f) return luaL_error(L, "ml.wav_write: could not write \"%s\"", path);
  unsigned char h[44];
  uint32_t data_len = (uint32_t)(b->n * 2);
  memcpy(h, "RIFF", 4); wr32(h + 4, 36 + data_len); memcpy(h + 8, "WAVEfmt ", 8);
  wr32(h + 16, 16); wr16(h + 20, 1); wr16(h + 22, 1); wr32(h + 24, rate); wr32(h + 28, rate * 2);
  wr16(h + 32, 2); wr16(h + 34, 16); memcpy(h + 36, "data", 4); wr32(h + 40, data_len);
  fwrite(h, 1, 44, f);
  for (size_t k = 0; k < b->n; k++) {
    float v = b->data.f[k];
    if (v > 1) v = 1;
    if (v < -1) v = -1;
    int16_t s = (int16_t)lrintf(v * 32767.0f);
    unsigned char o[2];
    wr16(o, (uint16_t)s);
    fwrite(o, 1, 2, f);
  }
  fclose(f);
  return 0;
}

/* ================================================================== resampling */

/* ml.resample(buffer, from_rate, to_rate) -> buffer
 * A windowed-sinc filter (Blackman, 32 taps each side), low-passed at the lower Nyquist,
 * so 48 kHz from a microphone comes down to 16 kHz without folding back. */
static int l_resample(lua_State *L) {
  ml_buffer *in = ml_checkbuffer(L, 1);
  double from = luaL_checknumber(L, 2), to = luaL_checknumber(L, 3);
  if (in->type != ML_F32 || from <= 0 || to <= 0) return luaL_argerror(L, 1, "f32 samples and two rates");
  if (from == to) { ml_buffer *c = ml_newbuffer(L, ML_F32, in->n); memcpy(c->data.f, in->data.f, in->n * 4); return 1; }
  double ratio = to / from;
  size_t n = (size_t)floor((double)in->n * ratio);
  ml_buffer *out = ml_newbuffer(L, ML_F32, n);
  double cutoff = ratio < 1 ? ratio : 1.0;
  const int half = 32;
  for (size_t k = 0; k < n; k++) {
    double center = (double)k / ratio;
    long first = (long)floor(center) - half + 1, last = (long)floor(center) + half;
    double acc = 0, wsum = 0;
    for (long j = first; j <= last; j++) {
      double x = (double)j - center;
      double sinc = x == 0 ? 1.0 : sin(M_PI * x * cutoff) / (M_PI * x * cutoff);
      double t = (x + half) / (2.0 * half);
      double win = (t < 0 || t > 1) ? 0 : 0.42 - 0.5 * cos(2 * M_PI * t) + 0.08 * cos(4 * M_PI * t);
      double wgt = sinc * win * cutoff;
      if (j >= 0 && (size_t)j < in->n) acc += in->data.f[j] * wgt;
      wsum += wgt;
    }
    out->data.f[k] = (float)(wsum != 0 ? acc / wsum : 0);   /* unit gain at DC */
  }
  return 1;
}

/* ================================================================== registration */

static const luaL_Reg st_methods[] = { { "read", st_read }, { "close", st_close }, { NULL, NULL } };
static const luaL_Reg gw_methods[] = { { "set", gw_set }, { "add", gw_add }, { "write", gw_write }, { "close", gw_close }, { NULL, NULL } };

static const luaL_Reg io_functions[] = {
  { "json", l_json }, { "safetensors", l_safetensors }, { "gguf_writer", l_gguf_writer },
  { "wav_read", l_wav_read }, { "wav_write", l_wav_write }, { "resample", l_resample },
  { NULL, NULL }
};

static void io_class(lua_State *L, const char *name, const luaL_Reg *methods, lua_CFunction gc) {
  luaL_newmetatable(L, name);
  lua_newtable(L);
  luaL_setfuncs(L, methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
}

void ml_open_io(lua_State *L) {
  io_class(L, ML_ST, st_methods, st_close);
  io_class(L, ML_GW, gw_methods, gw_close);
  luaL_setfuncs(L, io_functions, 0);
}
