/*
 * buffer.c -- host arrays: data into a graph and out of it (spec/ml.md, "Buffers").
 *
 * A buffer is a flat array of f32 or i32 on the host. Indexing is 1-based, as Lua's is.
 * Sampling a token from logits happens here, in C, so a vocabulary of 262,144 never
 * becomes a Lua table.
 */
#include "ml.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

ml_buffer *ml_checkbuffer(lua_State *L, int i) {
  return (ml_buffer *)luaL_checkudata(L, i, ML_BUFFER);
}

ml_buffer *ml_newbuffer(lua_State *L, ml_btype type, size_t n) {
  ml_buffer *b = (ml_buffer *)lua_newuserdata(L, sizeof(ml_buffer));
  b->type = type;
  b->n = n;
  b->data.p = calloc(n ? n : 1, 4);
  if (!b->data.p) luaL_error(L, "ml: out of memory for a buffer of %d values", (int)n);
  luaL_setmetatable(L, ML_BUFFER);
  return b;
}

static ml_btype check_btype(lua_State *L, int i) {
  const char *t = luaL_optstring(L, i, "f32");
  if (strcmp(t, "f32") == 0) return ML_F32;
  if (strcmp(t, "i32") == 0) return ML_I32;
  luaL_argerror(L, i, "a buffer is \"f32\" or \"i32\"");
  return ML_F32;
}

static double get_value(ml_buffer *b, size_t k) { return b->type == ML_F32 ? (double)b->data.f[k] : (double)b->data.i[k]; }
static void set_value(ml_buffer *b, size_t k, double v) {
  if (b->type == ML_F32) b->data.f[k] = (float)v; else b->data.i[k] = (int32_t)v;
}

static size_t check_index(lua_State *L, ml_buffer *b, int i) {
  int64_t k = ml_checkint(L, i);
  if (k < 1 || (size_t)k > b->n) luaL_argerror(L, i, lua_pushfstring(L, "index %d is outside 1..%d", (int)k, (int)b->n));
  return (size_t)(k - 1);
}

/* ml.buffer(n [, "f32" | "i32"]) -> zeros; ml.buffer{ values } [, type] -> those values */
static int l_buffer(lua_State *L) {
  ml_btype type = check_btype(L, 2);
  if (lua_istable(L, 1)) {
    size_t n = ml_rawlen(L, 1);
    ml_buffer *b = ml_newbuffer(L, type, n);
    for (size_t k = 0; k < n; k++) {
      lua_rawgeti(L, 1, (int)k + 1);
      set_value(b, k, luaL_checknumber(L, -1));
      lua_pop(L, 1);
    }
    return 1;
  }
  int64_t n = ml_checkint(L, 1);
  if (n < 0) return luaL_argerror(L, 1, "a size of 0 or more");
  ml_newbuffer(L, type, (size_t)n);
  return 1;
}

/* ml.decode(bytes, "f32" | "i16" | "i32" | "u8") -> buffer: little-endian samples; i16
 * and u8 are scaled to [-1, 1) as audio is */
static int l_decode(lua_State *L) {
  size_t len;
  const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &len);
  const char *fmt = luaL_checkstring(L, 2);
  if (strcmp(fmt, "f32") == 0) {
    ml_buffer *b = ml_newbuffer(L, ML_F32, len / 4);
    memcpy(b->data.f, s, (len / 4) * 4);
  } else if (strcmp(fmt, "i32") == 0) {
    ml_buffer *b = ml_newbuffer(L, ML_I32, len / 4);
    memcpy(b->data.i, s, (len / 4) * 4);
  } else if (strcmp(fmt, "i16") == 0) {
    ml_buffer *b = ml_newbuffer(L, ML_F32, len / 2);
    for (size_t k = 0; k < len / 2; k++) b->data.f[k] = (float)(int16_t)(s[2 * k] | (s[2 * k + 1] << 8)) / 32768.0f;
  } else if (strcmp(fmt, "u8") == 0) {
    ml_buffer *b = ml_newbuffer(L, ML_F32, len);
    for (size_t k = 0; k < len; k++) b->data.f[k] = ((float)s[k] - 128.0f) / 128.0f;
  } else {
    return luaL_argerror(L, 2, "\"f32\", \"i32\", \"i16\" or \"u8\"");
  }
  return 1;
}

static int buf_len(lua_State *L) { lua_pushinteger(L, (lua_Integer)ml_checkbuffer(L, 1)->n); return 1; }

static int buf_get(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  lua_pushnumber(L, get_value(b, check_index(L, b, 2)));
  return 1;
}

static int buf_set(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  set_value(b, check_index(L, b, 2), luaL_checknumber(L, 3));
  return 0;
}

static int buf_type(lua_State *L) { lua_pushstring(L, ml_checkbuffer(L, 1)->type == ML_F32 ? "f32" : "i32"); return 1; }

/* buf:table([from, to]) -> { values } */
static int buf_table(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  int64_t from = ml_optint(L, 2, 1), to = ml_optint(L, 3, (int64_t)b->n);
  if (from < 1) from = 1;
  if (to > (int64_t)b->n) to = (int64_t)b->n;
  lua_createtable(L, to >= from ? (int)(to - from + 1) : 0, 0);
  for (int64_t k = from; k <= to; k++) { lua_pushnumber(L, get_value(b, (size_t)(k - 1))); lua_rawseti(L, -2, (int)(k - from + 1)); }
  return 1;
}

/* buf:encode("f32" | "i16") -> bytes, little-endian; i16 clips to [-1, 1] */
static int buf_encode(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  const char *fmt = luaL_optstring(L, 2, "f32");
  if (strcmp(fmt, "f32") == 0 || strcmp(fmt, "i32") == 0) {
    lua_pushlstring(L, (const char *)b->data.p, b->n * 4);
    return 1;
  }
  if (strcmp(fmt, "i16") == 0) {
    unsigned char *out = (unsigned char *)malloc(b->n * 2 + 1);
    for (size_t k = 0; k < b->n; k++) {
      double v = get_value(b, k);
      if (v > 1.0) v = 1.0;
      if (v < -1.0) v = -1.0;
      int s = (int)lrint(v * 32767.0);
      out[2 * k] = (unsigned char)(s & 0xff);
      out[2 * k + 1] = (unsigned char)((s >> 8) & 0xff);
    }
    lua_pushlstring(L, (const char *)out, b->n * 2);
    free(out);
    return 1;
  }
  return luaL_argerror(L, 2, "\"f32\", \"i32\" or \"i16\"");
}

/* buf:slice(from, to) -> a copy of values from..to */
static int buf_slice(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  int64_t from = ml_optint(L, 2, 1), to = ml_optint(L, 3, (int64_t)b->n);
  if (from < 1) from = 1;
  if (to > (int64_t)b->n) to = (int64_t)b->n;
  size_t n = to >= from ? (size_t)(to - from + 1) : 0;
  ml_buffer *c = ml_newbuffer(L, b->type, n);
  if (n) memcpy(c->data.p, (char *)b->data.p + (from - 1) * 4, n * 4);
  return 1;
}

/* ml.join(a, b, ...) -> one buffer of all of them, in order */
static int l_join(lua_State *L) {
  int n = lua_gettop(L);
  size_t total = 0;
  ml_btype type = ML_F32;
  for (int k = 1; k <= n; k++) {
    ml_buffer *b = ml_checkbuffer(L, k);
    if (k == 1) type = b->type;
    else if (b->type != type) return luaL_argerror(L, k, "buffers of one type");
    total += b->n;
  }
  ml_buffer *out = ml_newbuffer(L, type, total);
  size_t at = 0;
  for (int k = 1; k <= n; k++) {
    ml_buffer *b = ml_checkbuffer(L, k);
    memcpy((char *)out->data.p + at * 4, b->data.p, b->n * 4);
    at += b->n;
  }
  return 1;
}

static int buf_fill(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  double v = luaL_checknumber(L, 2);
  for (size_t k = 0; k < b->n; k++) set_value(b, k, v);
  lua_settop(L, 1);
  return 1;
}

/* buf:argmax() -> index (1-based), value */
static int buf_argmax(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  if (b->n == 0) return 0;
  size_t best = 0;
  double bv = get_value(b, 0);
  for (size_t k = 1; k < b->n; k++) { double v = get_value(b, k); if (v > bv) { bv = v; best = k; } }
  lua_pushinteger(L, (lua_Integer)best + 1);
  lua_pushnumber(L, bv);
  return 2;
}

/* buf:stats() -> min, max, mean, rms */
static int buf_stats(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  if (b->n == 0) { lua_pushnumber(L, 0); lua_pushnumber(L, 0); lua_pushnumber(L, 0); lua_pushnumber(L, 0); return 4; }
  double mn = get_value(b, 0), mx = mn, sum = 0, sq = 0;
  for (size_t k = 0; k < b->n; k++) {
    double v = get_value(b, k);
    if (v < mn) mn = v;
    if (v > mx) mx = v;
    sum += v; sq += v * v;
  }
  lua_pushnumber(L, mn); lua_pushnumber(L, mx);
  lua_pushnumber(L, sum / (double)b->n); lua_pushnumber(L, sqrt(sq / (double)b->n));
  return 4;
}

/* ml.max_diff(a, b) -> the largest |a[k] - b[k]| and its index: how a port is checked
 * against reference numbers */
static int l_max_diff(lua_State *L) {
  ml_buffer *a = ml_checkbuffer(L, 1), *b = ml_checkbuffer(L, 2);
  if (a->n != b->n) return luaL_error(L, "ml.max_diff: %d values against %d", (int)a->n, (int)b->n);
  double worst = 0;
  size_t at = 0;
  for (size_t k = 0; k < a->n; k++) {
    double d = fabs(get_value(a, k) - get_value(b, k));
    if (d > worst || d != d) { worst = d; at = k; if (d != d) break; }
  }
  lua_pushnumber(L, worst);
  lua_pushinteger(L, (lua_Integer)at + 1);
  return 2;
}

/* ------------------------------------------------------------------ random */

#define ML_RNG "ml.rng"

typedef struct { uint64_t s[4]; int has_spare; double spare; } ml_rng;

static uint64_t rotl(uint64_t x, int k) { return (x << k) | (x >> (64 - k)); }

static uint64_t rng_next(ml_rng *r) {     /* xoshiro256** */
  uint64_t result = rotl(r->s[1] * 5, 7) * 9, t = r->s[1] << 17;
  r->s[2] ^= r->s[0]; r->s[3] ^= r->s[1]; r->s[1] ^= r->s[2]; r->s[0] ^= r->s[3];
  r->s[2] ^= t; r->s[3] = rotl(r->s[3], 45);
  return result;
}

static double rng_uniform(ml_rng *r) { return (double)(rng_next(r) >> 11) * (1.0 / 9007199254740992.0); }

static double rng_normal(ml_rng *r) {     /* Box-Muller, one kept for the next call */
  if (r->has_spare) { r->has_spare = 0; return r->spare; }
  double u, v, s;
  do { u = rng_uniform(r) * 2 - 1; v = rng_uniform(r) * 2 - 1; s = u * u + v * v; } while (s >= 1 || s == 0);
  s = sqrt(-2 * log(s) / s);
  r->spare = v * s; r->has_spare = 1;
  return u * s;
}

/* ml.rng(seed) -> a stream of numbers that is the same for the same seed, on every host */
static int l_rng(lua_State *L) {
  uint64_t seed = (uint64_t)ml_optint(L, 1, 0);
  ml_rng *r = (ml_rng *)lua_newuserdata(L, sizeof(ml_rng));
  memset(r, 0, sizeof(*r));
  for (int k = 0; k < 4; k++) {           /* splitmix64 fills the state */
    seed += 0x9e3779b97f4a7c15ULL;
    uint64_t z = seed;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    r->s[k] = z ^ (z >> 31);
  }
  luaL_setmetatable(L, ML_RNG);
  return 1;
}

static int rng_uniform_l(lua_State *L) { lua_pushnumber(L, rng_uniform((ml_rng *)luaL_checkudata(L, 1, ML_RNG))); return 1; }

/* rng:normals(n [, std]) -> an f32 buffer of Gaussian noise */
static int rng_normals(lua_State *L) {
  ml_rng *r = (ml_rng *)luaL_checkudata(L, 1, ML_RNG);
  size_t n = (size_t)ml_checkint(L, 2);
  double sd = luaL_optnumber(L, 3, 1.0);
  ml_buffer *b = ml_newbuffer(L, ML_F32, n);
  for (size_t k = 0; k < n; k++) b->data.f[k] = (float)(rng_normal(r) * sd);
  return 1;
}

/* ------------------------------------------------------------------ sampling */

typedef struct { float logit; int32_t id; } cand;

static int cand_desc(const void *a, const void *b) {
  float x = ((const cand *)a)->logit, y = ((const cand *)b)->logit;
  if (x > y) return -1;
  if (x < y) return 1;
  return ((const cand *)a)->id - ((const cand *)b)->id;
}

/* logits:sample{ temperature = 1, top_k = 0, top_p = 1, min_p = 0 }, rng -> index (1-based)
 * temperature 0 is argmax. The candidates are the top_k by logit (all of them when 0),
 * then the smallest set whose probability reaches top_p, then those at least min_p times
 * the most likely. */
static int buf_sample(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  if (b->type != ML_F32 || b->n == 0) return luaL_argerror(L, 1, "f32 logits");
  double temp = 1.0, top_p = 1.0, min_p = 0.0;
  int64_t top_k = 0;
  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "temperature"); temp = luaL_optnumber(L, -1, 1.0); lua_pop(L, 1);
    lua_getfield(L, 2, "top_k"); top_k = ml_optint(L, -1, 0); lua_pop(L, 1);
    lua_getfield(L, 2, "top_p"); top_p = luaL_optnumber(L, -1, 1.0); lua_pop(L, 1);
    lua_getfield(L, 2, "min_p"); min_p = luaL_optnumber(L, -1, 0.0); lua_pop(L, 1);
  }
  if (temp <= 0) {
    size_t best = 0;
    for (size_t k = 1; k < b->n; k++) if (b->data.f[k] > b->data.f[best]) best = k;
    lua_pushinteger(L, (lua_Integer)best + 1);
    return 1;
  }
  ml_rng *r = (ml_rng *)luaL_checkudata(L, 3, ML_RNG);
  size_t n = b->n, k = (top_k > 0 && (size_t)top_k < n) ? (size_t)top_k : n;

  /* The top k by a bounded min-heap when k is small, a full sort otherwise. */
  cand *c = (cand *)malloc(sizeof(cand) * (k < n ? k : n));
  if (k < n) {
    size_t have = 0;
    for (size_t i = 0; i < n; i++) {
      float v = b->data.f[i];
      if (have < k) {
        size_t j = have++;
        c[j].logit = v; c[j].id = (int32_t)i;
        while (j > 0) { size_t p = (j - 1) / 2; if (c[p].logit <= c[j].logit) break; cand t = c[p]; c[p] = c[j]; c[j] = t; j = p; }
      } else if (v > c[0].logit) {
        c[0].logit = v; c[0].id = (int32_t)i;
        size_t j = 0;
        for (;;) {
          size_t l = 2 * j + 1, rr = l + 1, m = j;
          if (l < k && c[l].logit < c[m].logit) m = l;
          if (rr < k && c[rr].logit < c[m].logit) m = rr;
          if (m == j) break;
          cand t = c[m]; c[m] = c[j]; c[j] = t; j = m;
        }
      }
    }
  } else {
    for (size_t i = 0; i < n; i++) { c[i].logit = b->data.f[i]; c[i].id = (int32_t)i; }
  }
  qsort(c, k, sizeof(cand), cand_desc);

  double mx = c[0].logit, sum = 0;
  double *p = (double *)malloc(sizeof(double) * k);
  for (size_t i = 0; i < k; i++) { p[i] = exp((c[i].logit - mx) / temp); sum += p[i]; }
  size_t keep = k;
  double cum = 0;
  for (size_t i = 0; i < k; i++) {
    p[i] /= sum;
    if (min_p > 0 && p[i] < min_p * p[0]) { keep = i; break; }
    cum += p[i];
    if (cum >= top_p) { keep = i + 1; break; }
  }
  if (keep == 0) keep = 1;
  double total = 0;
  for (size_t i = 0; i < keep; i++) total += p[i];
  double u = rng_uniform(r) * total, acc = 0;
  int32_t pick = c[keep - 1].id;
  for (size_t i = 0; i < keep; i++) { acc += p[i]; if (u < acc) { pick = c[i].id; break; } }
  free(p); free(c);
  lua_pushinteger(L, (lua_Integer)pick + 1);
  return 1;
}

/* ------------------------------------------------------------------ registration */

static int buf_index(lua_State *L) {
  if (lua_type(L, 2) == LUA_TNUMBER) return buf_get(L);
  luaL_getmetatable(L, ML_BUFFER);
  lua_getfield(L, -1, "methods");
  lua_pushvalue(L, 2);
  lua_rawget(L, -2);
  return 1;
}

static int buf_newindex(lua_State *L) { return buf_set(L); }

static int buf_gc(lua_State *L) {
  ml_buffer *b = (ml_buffer *)lua_touserdata(L, 1);
  free(b->data.p);
  b->data.p = NULL; b->n = 0;
  return 0;
}

static int buf_tostring(lua_State *L) {
  ml_buffer *b = ml_checkbuffer(L, 1);
  lua_pushfstring(L, "ml.buffer %s [%d]", b->type == ML_F32 ? "f32" : "i32", (int)b->n);
  return 1;
}

static const luaL_Reg buffer_methods[] = {
  { "get", buf_get }, { "set", buf_set }, { "type", buf_type }, { "len", buf_len },
  { "table", buf_table }, { "encode", buf_encode }, { "slice", buf_slice }, { "fill", buf_fill },
  { "argmax", buf_argmax }, { "stats", buf_stats }, { "sample", buf_sample },
  { NULL, NULL }
};

static const luaL_Reg rng_methods[] = { { "uniform", rng_uniform_l }, { "normals", rng_normals }, { NULL, NULL } };

static const luaL_Reg buffer_functions[] = {
  { "buffer", l_buffer }, { "decode", l_decode }, { "join", l_join }, { "max_diff", l_max_diff },
  { "rng", l_rng }, { NULL, NULL }
};

void ml_open_buffer(lua_State *L) {
  luaL_newmetatable(L, ML_BUFFER);
  lua_newtable(L);
  luaL_setfuncs(L, buffer_methods, 0);
  lua_setfield(L, -2, "methods");
  lua_pushcfunction(L, buf_index); lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, buf_newindex); lua_setfield(L, -2, "__newindex");
  lua_pushcfunction(L, buf_len); lua_setfield(L, -2, "__len");
  lua_pushcfunction(L, buf_gc); lua_setfield(L, -2, "__gc");
  lua_pushcfunction(L, buf_tostring); lua_setfield(L, -2, "__tostring");
  lua_pop(L, 1);

  luaL_newmetatable(L, ML_RNG);
  lua_newtable(L);
  luaL_setfuncs(L, rng_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pop(L, 1);

  luaL_setfuncs(L, buffer_functions, 0);
}
