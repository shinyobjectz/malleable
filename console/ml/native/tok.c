/*
 * tok.c -- tokenizers, built from a GGUF's tokenizer.ggml.* metadata (spec/ml.md).
 *
 * Kept in C because a vocabulary is large: Gemma 4 has 262,144 tokens and 514,906 merges,
 * which as Lua tables would be tens of megabytes and a second to build.
 *
 *   "gemma4"   BPE over codepoints: spaces become U+2581, merges by rank, byte fallback
 *   "moonshine" the same BPE with one U+2581 in front (add_space_prefix), as Moonshine's
 *              tokenizer.json normalizes
 *   "llama"    SentencePiece unigram: the best-scoring segmentation (Viterbi), byte fallback
 */
#include "ml.h"

#include <stdlib.h>
#include <string.h>

#include "gguf.h"

#define ML_TOK "ml.tokenizer"

enum { TT_NORMAL = 1, TT_UNKNOWN = 2, TT_CONTROL = 3, TT_USER = 4, TT_UNUSED = 5, TT_BYTE = 6 };
enum { KIND_BPE = 1, KIND_UNIGRAM = 2 };

/* ------------------------------------------------------------------ hash maps */

typedef struct { const char *s; uint32_t len; int32_t id; } str_slot;
typedef struct { str_slot *slots; uint32_t cap; } str_map;

static uint64_t fnv(const char *s, size_t n) {
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0; i < n; i++) { h ^= (unsigned char)s[i]; h *= 1099511628211ULL; }
  return h;
}

static void str_map_init(str_map *m, uint32_t n) {
  uint32_t cap = 16;
  while (cap < n * 2) cap <<= 1;
  m->cap = cap;
  m->slots = (str_slot *)calloc(cap, sizeof(str_slot));
}

static void str_map_put(str_map *m, const char *s, uint32_t len, int32_t id) {
  uint32_t i = (uint32_t)fnv(s, len) & (m->cap - 1);
  while (m->slots[i].s) {
    if (m->slots[i].len == len && !memcmp(m->slots[i].s, s, len)) return;   /* first id wins */
    i = (i + 1) & (m->cap - 1);
  }
  m->slots[i].s = s; m->slots[i].len = len; m->slots[i].id = id;
}

static int32_t str_map_get(const str_map *m, const char *s, size_t len) {
  uint32_t i = (uint32_t)fnv(s, len) & (m->cap - 1);
  while (m->slots[i].s) {
    if (m->slots[i].len == len && !memcmp(m->slots[i].s, s, len)) return m->slots[i].id;
    i = (i + 1) & (m->cap - 1);
  }
  return -1;
}

typedef struct { uint64_t key; int32_t rank, result; } pair_slot;
typedef struct { pair_slot *slots; uint32_t cap; } pair_map;

static uint64_t mix64(uint64_t x) { x ^= x >> 33; x *= 0xff51afd7ed558ccdULL; x ^= x >> 33; return x; }

static void pair_map_init(pair_map *m, uint32_t n) {
  uint32_t cap = 16;
  while (cap < n * 2) cap <<= 1;
  m->cap = cap;
  m->slots = (pair_slot *)calloc(cap, sizeof(pair_slot));
  for (uint32_t i = 0; i < cap; i++) m->slots[i].rank = -1;
}

static void pair_map_put(pair_map *m, uint64_t key, int32_t rank, int32_t result) {
  uint32_t i = (uint32_t)mix64(key) & (m->cap - 1);
  while (m->slots[i].rank >= 0) {
    if (m->slots[i].key == key) return;
    i = (i + 1) & (m->cap - 1);
  }
  m->slots[i].key = key; m->slots[i].rank = rank; m->slots[i].result = result;
}

static const pair_slot *pair_map_get(const pair_map *m, uint64_t key) {
  uint32_t i = (uint32_t)mix64(key) & (m->cap - 1);
  while (m->slots[i].rank >= 0) {
    if (m->slots[i].key == key) return &m->slots[i];
    i = (i + 1) & (m->cap - 1);
  }
  return NULL;
}

/* ------------------------------------------------------------------ the tokenizer */

typedef struct {
  int kind;
  int32_t n;
  char **text;          /* each token's text, owned */
  uint32_t *len;
  int32_t *type;
  float *score;
  str_map vocab;
  pair_map merges;
  int32_t *specials;    /* control/user/unknown ids, longest text first */
  int32_t n_specials;
  int32_t byte_id[256];
  int32_t bos, eos, unk;
  bool add_bos, space_prefix;
} ml_tok;

static ml_tok *sort_ctx_tok;
static int special_cmp(const void *a, const void *b) {
  int32_t x = *(const int32_t *)a, y = *(const int32_t *)b;
  uint32_t lx = sort_ctx_tok->len[x], ly = sort_ctx_tok->len[y];
  if (lx != ly) return lx > ly ? -1 : 1;
  return x - y;
}

static int64_t key_of(struct gguf_context *g, const char *k) { return gguf_find_key(g, k); }

static int32_t int_meta(struct gguf_context *g, const char *k, int32_t d) {
  int64_t id = key_of(g, k);
  if (id < 0) return d;
  switch (gguf_get_kv_type(g, id)) {
    case GGUF_TYPE_UINT32: return (int32_t)gguf_get_val_u32(g, id);
    case GGUF_TYPE_INT32: return gguf_get_val_i32(g, id);
    default: return d;
  }
}

static bool bool_meta(struct gguf_context *g, const char *k, bool d) {
  int64_t id = key_of(g, k);
  if (id < 0 || gguf_get_kv_type(g, id) != GGUF_TYPE_BOOL) return d;
  return gguf_get_val_bool(g, id);
}

static void tok_free(ml_tok *t) {
  if (t->text) { for (int32_t i = 0; i < t->n; i++) free(t->text[i]); }
  free(t->text); free(t->len); free(t->type); free(t->score);
  free(t->vocab.slots); free(t->merges.slots); free(t->specials);
  memset(t, 0, sizeof(*t));
}

/* set:tokenizer() -> the tokenizer the file's metadata describes */
int ml_tokenizer_from_gguf(lua_State *L, struct gguf_context *g) {
  if (!g) return luaL_error(L, "set:tokenizer: the set did not come from a file");
  int64_t mk = key_of(g, "tokenizer.ggml.model");
  if (mk < 0) return luaL_error(L, "set:tokenizer: the file has no tokenizer.ggml.model");
  const char *model = gguf_get_val_str(g, mk);
  int kind = !strcmp(model, "gemma4") || !strcmp(model, "moonshine") ? KIND_BPE : (!strcmp(model, "llama") ? KIND_UNIGRAM : 0);
  if (!kind) return luaL_error(L, "set:tokenizer: the tokenizer \"%s\" is not one the engine has (gemma4, moonshine, llama)", model);
  int64_t tk = key_of(g, "tokenizer.ggml.tokens");
  if (tk < 0) return luaL_error(L, "set:tokenizer: the file has no tokenizer.ggml.tokens");

  ml_tok *t = (ml_tok *)lua_newuserdata(L, sizeof(ml_tok));
  memset(t, 0, sizeof(*t));
  luaL_setmetatable(L, ML_TOK);
  t->kind = kind;
  t->n = (int32_t)gguf_get_arr_n(g, tk);
  t->text = (char **)calloc((size_t)t->n, sizeof(char *));
  t->len = (uint32_t *)calloc((size_t)t->n, sizeof(uint32_t));
  t->type = (int32_t *)calloc((size_t)t->n, sizeof(int32_t));
  t->score = (float *)calloc((size_t)t->n, sizeof(float));
  str_map_init(&t->vocab, (uint32_t)t->n);
  int64_t ty = key_of(g, "tokenizer.ggml.token_type");
  int64_t sc = key_of(g, "tokenizer.ggml.scores");
  const int32_t *types = ty >= 0 ? (const int32_t *)gguf_get_arr_data(g, ty) : NULL;
  const float *scores = sc >= 0 ? (const float *)gguf_get_arr_data(g, sc) : NULL;
  for (int k = 0; k < 256; k++) t->byte_id[k] = -1;
  int32_t n_spec = 0;
  for (int32_t i = 0; i < t->n; i++) {
    const char *s = gguf_get_arr_str(g, tk, (size_t)i);
    size_t l = strlen(s);
    t->text[i] = (char *)malloc(l + 1);
    memcpy(t->text[i], s, l + 1);
    t->len[i] = (uint32_t)l;
    t->type[i] = types ? types[i] : TT_NORMAL;
    t->score[i] = scores ? scores[i] : 0;
    str_map_put(&t->vocab, t->text[i], (uint32_t)l, i);
    if (t->type[i] == TT_BYTE && l == 6 && !strncmp(s, "<0x", 3)) t->byte_id[strtol(s + 3, NULL, 16) & 0xff] = i;
    if (t->type[i] == TT_CONTROL || t->type[i] == TT_USER || t->type[i] == TT_UNKNOWN) n_spec++;
  }
  t->specials = (int32_t *)malloc(sizeof(int32_t) * (size_t)(n_spec ? n_spec : 1));
  for (int32_t i = 0; i < t->n; i++) {
    if ((t->type[i] == TT_CONTROL || t->type[i] == TT_USER || t->type[i] == TT_UNKNOWN) && t->len[i] > 0) t->specials[t->n_specials++] = i;
  }
  sort_ctx_tok = t;
  qsort(t->specials, (size_t)t->n_specials, sizeof(int32_t), special_cmp);

  if (kind == KIND_BPE) {
    int64_t mg = key_of(g, "tokenizer.ggml.merges");
    if (mg < 0) return luaL_error(L, "set:tokenizer: a BPE tokenizer with no tokenizer.ggml.merges");
    size_t nm = gguf_get_arr_n(g, mg);
    pair_map_init(&t->merges, (uint32_t)nm);
    for (size_t r = 0; r < nm; r++) {
      const char *m = gguf_get_arr_str(g, mg, r);
      const char *sp = strchr(m + 1, ' ');       /* the first space after the first byte */
      if (!sp) continue;
      int32_t a = str_map_get(&t->vocab, m, (size_t)(sp - m));
      int32_t b = str_map_get(&t->vocab, sp + 1, strlen(sp + 1));
      if (a < 0 || b < 0) continue;
      size_t la = (size_t)(sp - m), lb = strlen(sp + 1);
      char *joined = (char *)malloc(la + lb + 1);
      memcpy(joined, m, la); memcpy(joined + la, sp + 1, lb); joined[la + lb] = 0;
      int32_t c = str_map_get(&t->vocab, joined, la + lb);
      free(joined);
      if (c < 0) continue;
      pair_map_put(&t->merges, ((uint64_t)(uint32_t)a << 32) | (uint32_t)b, (int32_t)r, c);
    }
  }
  t->bos = int_meta(g, "tokenizer.ggml.bos_token_id", -1);
  t->eos = int_meta(g, "tokenizer.ggml.eos_token_id", -1);
  t->unk = int_meta(g, "tokenizer.ggml.unknown_token_id", -1);
  t->add_bos = kind == KIND_BPE ? true : bool_meta(g, "tokenizer.ggml.add_bos_token", true);
  t->space_prefix = bool_meta(g, "tokenizer.ggml.add_space_prefix", kind == KIND_UNIGRAM);
  return 1;
}

static ml_tok *check_tok(lua_State *L, int i) {
  ml_tok *t = (ml_tok *)luaL_checkudata(L, i, ML_TOK);
  if (!t->text) luaL_argerror(L, i, "this tokenizer was freed");
  return t;
}

/* ------------------------------------------------------------------ growing id lists */

typedef struct { int32_t *v; size_t n, cap; } ids;
static void ids_push(ids *o, int32_t x) {
  if (o->n == o->cap) { o->cap = o->cap ? o->cap * 2 : 64; o->v = (int32_t *)realloc(o->v, sizeof(int32_t) * o->cap); }
  o->v[o->n++] = x;
}

static size_t utf8_len(unsigned char c) {
  if (c < 0x80) return 1;
  if ((c & 0xE0) == 0xC0) return 2;
  if ((c & 0xF0) == 0xE0) return 3;
  if ((c & 0xF8) == 0xF0) return 4;
  return 1;
}

static void bytes_fallback(ml_tok *t, const char *s, size_t n, ids *out) {
  for (size_t k = 0; k < n; k++) {
    int32_t b = t->byte_id[(unsigned char)s[k]];
    ids_push(out, b >= 0 ? b : t->unk);
  }
}

/* ------------------------------------------------------------------ BPE */

typedef struct { size_t at, len; int32_t id; int alive; } sym;

static void bpe_piece(ml_tok *t, const char *s, size_t n, ids *out) {
  int32_t whole = str_map_get(&t->vocab, s, n);
  bool newlines = true;
  for (size_t k = 0; k < n; k++) if (s[k] != '\n') { newlines = false; break; }
  if (newlines && whole >= 0) { ids_push(out, whole); return; }

  size_t cap = n ? n : 1, m = 0;
  sym *y = (sym *)malloc(sizeof(sym) * cap);
  for (size_t k = 0; k < n;) {
    size_t l = utf8_len((unsigned char)s[k]);
    if (k + l > n) l = n - k;
    y[m].at = k; y[m].len = l; y[m].id = str_map_get(&t->vocab, s + k, l); y[m].alive = 1;
    m++; k += l;
  }
  /* Merge the adjacent pair with the lowest rank, leftmost first, until none has a rank. */
  for (;;) {
    int32_t best = -1;
    size_t bi = 0, bj = 0;
    size_t prev = (size_t)-1;
    for (size_t k = 0; k < m; k++) {
      if (!y[k].alive) continue;
      if (prev != (size_t)-1 && y[prev].id >= 0 && y[k].id >= 0) {
        const pair_slot *p = pair_map_get(&t->merges, ((uint64_t)(uint32_t)y[prev].id << 32) | (uint32_t)y[k].id);
        if (p && (best < 0 || p->rank < best)) { best = p->rank; bi = prev; bj = k; }
      }
      prev = k;
    }
    if (best < 0) break;
    const pair_slot *p = pair_map_get(&t->merges, ((uint64_t)(uint32_t)y[bi].id << 32) | (uint32_t)y[bj].id);
    y[bi].len += y[bj].len;
    y[bi].id = p->result;
    y[bj].alive = 0;
  }
  for (size_t k = 0; k < m; k++) {
    if (!y[k].alive) continue;
    if (y[k].id >= 0) ids_push(out, y[k].id);
    else bytes_fallback(t, s + y[k].at, y[k].len, out);
  }
  free(y);
}

/* Spaces to U+2581, then pieces of [^\n]+ and [\n]+. */
static void bpe_text(ml_tok *t, const char *s, size_t n, ids *out) {
  size_t cap = n * 3 + 4, m = 0;
  char *r = (char *)malloc(cap);
  if (t->space_prefix) { r[m++] = (char)0xE2; r[m++] = (char)0x96; r[m++] = (char)0x81; }
  for (size_t k = 0; k < n; k++) {
    if (s[k] == ' ') { r[m++] = (char)0xE2; r[m++] = (char)0x96; r[m++] = (char)0x81; }
    else r[m++] = s[k];
  }
  for (size_t k = 0; k < m;) {
    size_t e = k;
    bool nl = r[k] == '\n';
    while (e < m && ((r[e] == '\n') == nl)) e++;
    bpe_piece(t, r + k, e - k, out);
    k = e;
  }
  free(r);
}

/* ------------------------------------------------------------------ unigram */

static void unigram_text(ml_tok *t, const char *s, size_t n, ids *out) {
  /* SentencePiece: a space prefix when asked, spaces to U+2581, then the segmentation with
   * the highest total score; a character no token covers falls back to bytes. */
  size_t cap = n * 3 + 4, m = 0;
  char *r = (char *)malloc(cap);
  if (t->space_prefix) { r[m++] = (char)0xE2; r[m++] = (char)0x96; r[m++] = (char)0x81; }
  for (size_t k = 0; k < n; k++) {
    if (s[k] == ' ') { r[m++] = (char)0xE2; r[m++] = (char)0x96; r[m++] = (char)0x81; }
    else r[m++] = s[k];
  }
  double *best = (double *)malloc(sizeof(double) * (m + 1));
  int32_t *from = (int32_t *)malloc(sizeof(int32_t) * (m + 1));
  int32_t *tokid = (int32_t *)malloc(sizeof(int32_t) * (m + 1));
  best[0] = 0;
  for (size_t k = 1; k <= m; k++) { best[k] = -1e300; from[k] = -1; tokid[k] = -1; }
  for (size_t k = 0; k < m; k++) {
    if (best[k] <= -1e299) continue;
    /* every token that starts here, up to 64 bytes */
    for (size_t e = k + 1; e <= m && e - k <= 64; e++) {
      int32_t id = str_map_get(&t->vocab, r + k, e - k);
      if (id < 0 || t->type[id] == TT_UNUSED || t->type[id] == TT_CONTROL) continue;
      double v = best[k] + (t->type[id] == TT_USER ? 0 : t->score[id]);
      if (v > best[e]) { best[e] = v; from[e] = (int32_t)k; tokid[e] = id; }
    }
    /* one character with no token: its bytes, with a poor score */
    size_t l = utf8_len((unsigned char)r[k]);
    if (k + l <= m && from[k + l] < 0) {
      double v = best[k] - 1e6;
      if (v > best[k + l]) { best[k + l] = v; from[k + l] = (int32_t)k; tokid[k + l] = -1; }
    }
  }
  ids rev = { 0 };
  for (size_t e = m; e > 0;) {
    size_t k = (size_t)from[e];
    if (tokid[e] >= 0) ids_push(&rev, tokid[e]);
    else { for (size_t j = e; j > k; j--) { int32_t b = t->byte_id[(unsigned char)r[j - 1]]; ids_push(&rev, b >= 0 ? b : t->unk); } }
    e = k;
  }
  for (size_t k = rev.n; k > 0; k--) ids_push(out, rev.v[k - 1]);
  free(rev.v); free(best); free(from); free(tokid); free(r);
}

/* ------------------------------------------------------------------ encode / decode */

/* tok:encode(text [, { bos = true, special = true }]) -> { id, ... } (0-based ids, as the
 * model's tables are). special: control tokens written in the text are those tokens. */
static int tok_encode(lua_State *L) {
  ml_tok *t = check_tok(L, 1);
  size_t n;
  const char *s = luaL_checklstring(L, 2, &n);
  bool bos = t->add_bos, special = true;
  if (lua_istable(L, 3)) {
    lua_getfield(L, 3, "bos"); if (!lua_isnil(L, -1)) bos = lua_toboolean(L, -1); lua_pop(L, 1);
    lua_getfield(L, 3, "special"); if (!lua_isnil(L, -1)) special = lua_toboolean(L, -1); lua_pop(L, 1);
  }
  ids out = { 0 };
  if (bos && t->bos >= 0) ids_push(&out, t->bos);
  size_t start = 0;
  for (size_t k = 0; k <= n;) {
    int32_t hit = -1;
    if (k < n) {
      for (int32_t j = 0; j < t->n_specials; j++) {
        int32_t id = t->specials[j];
        if (!special && t->type[id] != TT_USER) continue;
        if (t->len[id] <= n - k && !memcmp(s + k, t->text[id], t->len[id])) { hit = id; break; }
      }
    }
    if (hit >= 0 || k == n) {
      if (k > start) {
        if (t->kind == KIND_BPE) bpe_text(t, s + start, k - start, &out);
        else unigram_text(t, s + start, k - start, &out);
      }
      if (hit < 0) break;
      ids_push(&out, hit);
      k += t->len[hit];
      start = k;
    } else {
      k++;
    }
  }
  lua_createtable(L, (int)out.n, 0);
  for (size_t k = 0; k < out.n; k++) { lua_pushinteger(L, out.v[k]); lua_rawseti(L, -2, (int)k + 1); }
  free(out.v);
  return 1;
}

static void piece_into(ml_tok *t, int32_t id, luaL_Buffer *b, bool special) {
  if (id < 0 || id >= t->n) return;
  if (t->type[id] == TT_BYTE && t->len[id] == 6) { luaL_addchar(b, (char)strtol(t->text[id] + 3, NULL, 16)); return; }
  if (t->type[id] == TT_CONTROL && !special) return;
  const char *s = t->text[id];
  for (uint32_t k = 0; k < t->len[id];) {
    if (k + 3 <= t->len[id] && (unsigned char)s[k] == 0xE2 && (unsigned char)s[k + 1] == 0x96 && (unsigned char)s[k + 2] == 0x81) {
      luaL_addchar(b, ' '); k += 3;
    } else {
      luaL_addchar(b, s[k]); k++;
    }
  }
}

/* tok:decode(ids [, { special = false }]) -> text; ids a table or an i32 buffer */
static int tok_decode(lua_State *L) {
  ml_tok *t = check_tok(L, 1);
  bool special = false;
  if (lua_istable(L, 3)) { lua_getfield(L, 3, "special"); special = lua_toboolean(L, -1); lua_pop(L, 1); }
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  if (lua_istable(L, 2)) {
    size_t n = ml_rawlen(L, 2);
    for (size_t k = 1; k <= n; k++) {
      lua_rawgeti(L, 2, (int)k);
      int32_t id = (int32_t)lua_tonumber(L, -1);
      lua_pop(L, 1);
      piece_into(t, id, &b, special);
    }
  } else {
    ml_buffer *ib = ml_checkbuffer(L, 2);
    for (size_t k = 0; k < ib->n; k++) piece_into(t, ib->type == ML_I32 ? ib->data.i[k] : (int32_t)ib->data.f[k], &b, special);
  }
  luaL_pushresult(&b);
  return 1;
}

/* tok:piece(id [, special]) -> the text of one token, as decode writes it */
static int tok_piece(lua_State *L) {
  ml_tok *t = check_tok(L, 1);
  int32_t id = (int32_t)ml_checkint(L, 2);
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  piece_into(t, id, &b, lua_toboolean(L, 3));
  luaL_pushresult(&b);
  return 1;
}

/* tok:id(text) -> the id of the token whose text this is, or nil */
static int tok_id(lua_State *L) {
  ml_tok *t = check_tok(L, 1);
  size_t n;
  const char *s = luaL_checklstring(L, 2, &n);
  int32_t id = str_map_get(&t->vocab, s, n);
  if (id < 0) lua_pushnil(L); else lua_pushinteger(L, id);
  return 1;
}

/* tok:text(id) -> the token's text as the vocabulary stores it */
static int tok_text(lua_State *L) {
  ml_tok *t = check_tok(L, 1);
  int32_t id = (int32_t)ml_checkint(L, 2);
  if (id < 0 || id >= t->n) return luaL_argerror(L, 2, "no such token");
  lua_pushlstring(L, t->text[id], t->len[id]);
  return 1;
}

static int tok_size(lua_State *L) { lua_pushinteger(L, check_tok(L, 1)->n); return 1; }

static int tok_specials(lua_State *L) {
  ml_tok *t = check_tok(L, 1);
  lua_createtable(L, 0, 3);
  lua_pushinteger(L, t->bos); lua_setfield(L, -2, "bos");
  lua_pushinteger(L, t->eos); lua_setfield(L, -2, "eos");
  lua_pushinteger(L, t->unk); lua_setfield(L, -2, "unk");
  return 1;
}

static int tok_gc(lua_State *L) { tok_free((ml_tok *)lua_touserdata(L, 1)); return 0; }

static const luaL_Reg tok_methods[] = {
  { "encode", tok_encode }, { "decode", tok_decode }, { "piece", tok_piece }, { "id", tok_id },
  { "text", tok_text }, { "size", tok_size }, { "specials", tok_specials }, { NULL, NULL }
};

void ml_open_tok(lua_State *L) {
  luaL_newmetatable(L, ML_TOK);
  lua_newtable(L);
  luaL_setfuncs(L, tok_methods, 0);
  lua_setfield(L, -2, "__index");
  lua_pushcfunction(L, tok_gc);
  lua_setfield(L, -2, "__gc");
  lua_pop(L, 1);
}
