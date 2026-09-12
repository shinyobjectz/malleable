/*
 * core.c -- the engine, sets, graphs and ops (spec/ml.md).
 *
 * A model is Lua that builds a graph of ggml ops each step and computes it on the engine.
 * The engine owns a scheduler over its devices: a graph's nodes run on the first device
 * that supports them, so an op a GPU lacks falls back to the CPU instead of failing.
 */
#include "ml.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ggml-alloc.h"
#include "ggml-cpu.h"
#include "gguf.h"

/* ggml checks its arguments with asserts that abort the process. While an op is being
 * built, on the thread that builds it, an abort raises in Lua instead: a wrong shape is a
 * message, never a crash. Anywhere else (a worker thread computing, a load) it aborts as
 * ggml would, after printing. */
#ifdef _WIN32
#  include <windows.h>
typedef DWORD ml_thread;
static ml_thread this_thread(void) { return GetCurrentThreadId(); }
static bool same_thread(ml_thread a, ml_thread b) { return a == b; }
#else
#  include <pthread.h>
typedef pthread_t ml_thread;
static ml_thread this_thread(void) { return pthread_self(); }
static bool same_thread(ml_thread a, ml_thread b) { return pthread_equal(a, b) != 0; }
#endif

void ggml_print_backtrace(void);
static lua_State *op_L;
static ml_thread op_thread;

static void ml_on_abort(const char *message) {
  lua_State *L = op_L;
  if (L && same_thread(this_thread(), op_thread)) {
    op_L = NULL;
    const char *slash = strrchr(message, '/');
    luaL_error(L, "ml: %s", slash ? slash + 1 : message);
  }
  fprintf(stderr, "%s\n", message);
  ggml_print_backtrace();
}

#ifndef ML_GGML_COMMIT
#  define ML_GGML_COMMIT "unknown"
#endif

/* ================================================================== helpers */

int64_t ml_checkint(lua_State *L, int i) {
  lua_Number n = luaL_checknumber(L, i);
  int64_t v = (int64_t)n;
  if ((lua_Number)v != n) luaL_argerror(L, i, "a whole number");
  return v;
}

int64_t ml_optint(lua_State *L, int i, int64_t d) {
  return lua_isnoneornil(L, i) ? d : ml_checkint(L, i);
}

enum ggml_type ml_checktype(lua_State *L, int i) {
  const char *name = luaL_checkstring(L, i);
  for (int t = 0; t < GGML_TYPE_COUNT; t++) {
    const char *n = ggml_type_name((enum ggml_type)t);
    if (n && strcmp(n, name) == 0) return (enum ggml_type)t;
  }
  luaL_argerror(L, i, lua_pushfstring(L, "no tensor type is called \"%s\" (f32, f16, bf16, i32, q8_0, q4_K ...)", name));
  return GGML_TYPE_F32;
}

enum ggml_type ml_opttype(lua_State *L, int i, enum ggml_type d) {
  return lua_isnoneornil(L, i) ? d : ml_checktype(L, i);
}

/* refs[handle] = owner: a tensor handle keeps whatever owns it alive. Weak keys, so the
 * entry goes when the handle does. */
static void ml_ref_owner(lua_State *L, int handle, int owner) {
  handle = ml_absindex(L, handle);
  owner = ml_absindex(L, owner);
  lua_getfield(L, LUA_REGISTRYINDEX, "ml.refs");
  lua_pushvalue(L, handle);
  lua_pushvalue(L, owner);
  lua_rawset(L, -3);
  lua_pop(L, 1);
}

void ml_pushtensor(lua_State *L, struct ggml_tensor *t, ml_owner *owner, int owner_index) {
  owner_index = ml_absindex(L, owner_index);
  if (t == NULL) luaL_error(L, "ml: ggml made no tensor (out of graph memory? give the graph more nodes)");
  ml_tensor *h = (ml_tensor *)lua_newuserdata(L, sizeof(ml_tensor));
  h->t = t;
  h->owner = owner;
  h->gen = owner->gen;
  luaL_setmetatable(L, ML_TENSOR);
  ml_ref_owner(L, -1, owner_index);
}

struct ggml_tensor *ml_checktensor(lua_State *L, int i) {
  ml_tensor *h = (ml_tensor *)luaL_checkudata(L, i, ML_TENSOR);
  if (!h->owner->alive) luaL_argerror(L, i, "this tensor's set or graph was freed");
  if (h->gen != h->owner->gen) luaL_argerror(L, i, "this tensor is from before its graph was reset");
  return h->t;
}

static struct ggml_tensor *ml_opttensor(lua_State *L, int i) {
  return lua_isnoneornil(L, i) ? NULL : ml_checktensor(L, i);
}

/* ================================================================== the live list
 * A host that exits without closing its Lua state (LuaJIT's os.exit) never finalizes the
 * sets and graphs, and ggml's Metal device refuses to be torn down while its buffers are
 * alive. So every live set and graph is on this list, and an atexit handler frees what is
 * left, before ggml's own teardown. */

static ml_owner *live = NULL;

static void live_add(ml_owner *o, int kind) {
  o->kind = kind;
  o->prev = NULL;
  o->next = live;
  if (live) live->prev = o;
  live = o;
}

static void live_remove(ml_owner *o) {
  if (o->prev) o->prev->next = o->next; else if (live == o) live = o->next;
  if (o->next) o->next->prev = o->prev;
  o->prev = o->next = NULL;
}

static void free_set(ml_set *s);
static void free_graph(ml_graph *g);

static void ml_atexit(void) {
  while (live) {
    ml_owner *o = live;
    if (o->kind == 1) free_set((ml_set *)o);    /* the owner is each struct's first field */
    else free_graph((ml_graph *)o);
    if (live == o) live_remove(o);
  }
}

/* ================================================================== engine */

static ml_engine *check_engine(lua_State *L, int i) {
  ml_engine *e = (ml_engine *)luaL_checkudata(L, i, ML_ENGINE);
  if (e->closed) luaL_argerror(L, i, "this engine was closed");
  return e;
}

static const char *device_type_name(enum ggml_backend_dev_type t) {
  switch (t) {
    case GGML_BACKEND_DEVICE_TYPE_CPU:  return "cpu";
    case GGML_BACKEND_DEVICE_TYPE_GPU:  return "gpu";
    case GGML_BACKEND_DEVICE_TYPE_IGPU: return "igpu";
    case GGML_BACKEND_DEVICE_TYPE_ACCEL: return "accel";
    default: return "other";
  }
}

/* ml.devices() -> { { name, description, type, free, total }, ... } */
/* ml.cpu_features() -> { neon = true, dotprod = true, avx2 = false, ... }: what ggml's CPU
 * kernels use on this machine. Kernels differ by feature, and so does how they round. */
static int l_cpu_features(lua_State *L) {
  static const struct { const char *name; int (*has)(void); } features[] = {
    { "neon", ggml_cpu_has_neon }, { "dotprod", ggml_cpu_has_dotprod }, { "matmul_int8", ggml_cpu_has_matmul_int8 },
    { "sve", ggml_cpu_has_sve }, { "avx2", ggml_cpu_has_avx2 }, { "avx512", ggml_cpu_has_avx512 },
    { "avx_vnni", ggml_cpu_has_avx_vnni }, { "fma", ggml_cpu_has_fma }, { "f16c", ggml_cpu_has_f16c },
    { "wasm_simd", ggml_cpu_has_wasm_simd },
  };
  lua_newtable(L);
  for (size_t i = 0; i < sizeof(features) / sizeof(features[0]); i++) {
    lua_pushboolean(L, features[i].has() != 0);
    lua_setfield(L, -2, features[i].name);
  }
  return 1;
}

static int l_devices(lua_State *L) {
  size_t n = ggml_backend_dev_count();
  lua_createtable(L, (int)n, 0);
  for (size_t k = 0; k < n; k++) {
    ggml_backend_dev_t d = ggml_backend_dev_get(k);
    size_t free = 0, total = 0;
    ggml_backend_dev_memory(d, &free, &total);
    lua_createtable(L, 0, 5);
    lua_pushstring(L, ggml_backend_dev_name(d)); lua_setfield(L, -2, "name");
    lua_pushstring(L, ggml_backend_dev_description(d)); lua_setfield(L, -2, "description");
    lua_pushstring(L, device_type_name(ggml_backend_dev_type(d))); lua_setfield(L, -2, "type");
    lua_pushnumber(L, (lua_Number)free); lua_setfield(L, -2, "free");
    lua_pushnumber(L, (lua_Number)total); lua_setfield(L, -2, "total");
    lua_rawseti(L, -2, (int)k + 1);
  }
  return 1;
}

/* ml.engine{ device = "auto" | "cpu" | <device name>, threads = n } -> engine
 * "auto" takes the first GPU there is. The CPU is always there too, last, for the ops the
 * GPU does not have. */
static int l_engine(lua_State *L) {
  const char *want = "auto";
  int threads = 0;
  if (lua_istable(L, 1)) {
    lua_getfield(L, 1, "device");
    if (!lua_isnil(L, -1)) want = luaL_checkstring(L, -1);
    lua_pop(L, 1);
    lua_getfield(L, 1, "threads");
    if (!lua_isnil(L, -1)) threads = (int)ml_checkint(L, -1);
    lua_pop(L, 1);
  }
  ml_engine *e = (ml_engine *)lua_newuserdata(L, sizeof(ml_engine));
  memset(e, 0, sizeof(*e));
  luaL_setmetatable(L, ML_ENGINE);

  ggml_backend_dev_t gpu = NULL;
  if (strcmp(want, "auto") == 0) {
    gpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
    if (!gpu) gpu = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_IGPU);
  } else if (strcmp(want, "cpu") != 0) {
    gpu = ggml_backend_dev_by_name(want);
    if (!gpu) return luaL_error(L, "ml.engine: there is no device called \"%s\" (ml.devices() lists them)", want);
    if (ggml_backend_dev_type(gpu) == GGML_BACKEND_DEVICE_TYPE_CPU) gpu = NULL;
  }
  if (gpu) {
    ggml_backend_t b = ggml_backend_dev_init(gpu, NULL);
    if (!b) return luaL_error(L, "ml.engine: the device \"%s\" would not start", ggml_backend_dev_name(gpu));
    e->backends[e->n_backends] = b;
    e->bufts[e->n_backends] = ggml_backend_get_default_buffer_type(b);
    e->n_backends++;
  }
  e->cpu = ggml_backend_init_by_type(GGML_BACKEND_DEVICE_TYPE_CPU, NULL);
  if (!e->cpu) return luaL_error(L, "ml.engine: the CPU backend would not start");
  if (threads <= 0) threads = 4;
#if defined(__EMSCRIPTEN__) && !defined(__EMSCRIPTEN_PTHREADS__)
  threads = 1;                     /* WebAssembly built without threads runs on one */
#endif
  e->threads = threads;
  ggml_backend_cpu_set_n_threads(e->cpu, threads);
  e->backends[e->n_backends] = e->cpu;
  e->bufts[e->n_backends] = ggml_backend_get_default_buffer_type(e->cpu);
  e->n_backends++;
  return 1;
}

static int engine_close(lua_State *L) {
  ml_engine *e = (ml_engine *)luaL_checkudata(L, 1, ML_ENGINE);
  if (!e->closed) {
    for (int k = 0; k < e->n_backends; k++) ggml_backend_free(e->backends[k]);
    e->closed = true;
  }
  return 0;
}

/* engine:device() -> the name of the device a set's tensors live on */
static int engine_device(lua_State *L) {
  ml_engine *e = check_engine(L, 1);
  lua_pushstring(L, ggml_backend_name(e->backends[0]));
  return 1;
}

static int engine_threads(lua_State *L) {
  ml_engine *e = check_engine(L, 1);
  if (!lua_isnoneornil(L, 2)) {
    e->threads = (int)ml_checkint(L, 2);
#if defined(__EMSCRIPTEN__) && !defined(__EMSCRIPTEN_PTHREADS__)
    e->threads = 1;
#endif
    ggml_backend_cpu_set_n_threads(e->cpu, e->threads);
  }
  lua_pushinteger(L, e->threads);
  return 1;
}

/* ================================================================== sets */

static ml_set *check_set(lua_State *L, int i) {
  ml_set *s = (ml_set *)luaL_checkudata(L, i, ML_SET);
  if (!s->owner.alive) luaL_argerror(L, i, "this set was freed");
  return s;
}

static ml_set *new_set(lua_State *L, int engine_index, size_t n_tensors) {
  ml_engine *e = check_engine(L, engine_index);
  ml_set *s = (ml_set *)lua_newuserdata(L, sizeof(ml_set));
  memset(s, 0, sizeof(*s));
  s->owner.alive = true;
  live_add(&s->owner, 1);
  s->engine = e;
  luaL_setmetatable(L, ML_SET);
  ml_ref_owner(L, -1, engine_index);   /* the set keeps its engine alive */
  if (n_tensors > 0) {
    struct ggml_init_params p = { ggml_tensor_overhead() * n_tensors, NULL, true };
    s->ctx = ggml_init(p);
    if (!s->ctx) luaL_error(L, "ml: out of memory for a set of %d tensors", (int)n_tensors);
  }
  return s;
}

/* engine:set([capacity]) -> an empty set, for state: KV caches, recurrent state */
static int engine_set(lua_State *L) {
  size_t cap = (size_t)ml_optint(L, 2, 1024);
  new_set(L, 1, cap);
  return 1;
}

/* set:new(name, type, ne0 [, ne1, ne2, ne3]) -> tensor; before set:alloc() */
static int set_new(lua_State *L) {
  ml_set *s = check_set(L, 1);
  if (s->allocated) return luaL_error(L, "set:new: the set is allocated; make a new set");
  const char *name = luaL_checkstring(L, 2);
  enum ggml_type type = ml_checktype(L, 3);
  int64_t ne[4] = { ml_checkint(L, 4), ml_optint(L, 5, 1), ml_optint(L, 6, 1), ml_optint(L, 7, 1) };
  int dims = lua_gettop(L) - 3;
  struct ggml_tensor *t = ggml_new_tensor(s->ctx, type, dims < 1 ? 1 : (dims > 4 ? 4 : dims), ne);
  if (!t) return luaL_error(L, "set:new: the set is full");
  ggml_set_name(t, name);
  ml_pushtensor(L, t, &s->owner, 1);
  return 1;
}

/* set:alloc([device]) -- gives every tensor its memory on the engine's first device (or
 * the CPU with device = "cpu"), zeroed */
static int set_alloc(lua_State *L) {
  ml_set *s = check_set(L, 1);
  if (s->allocated) return 0;
  const char *where = luaL_optstring(L, 2, "device");
  ggml_backend_buffer_type_t buft = strcmp(where, "cpu") == 0
    ? ggml_backend_get_default_buffer_type(s->engine->cpu) : s->engine->bufts[0];
  s->buffer = ggml_backend_alloc_ctx_tensors_from_buft(s->ctx, buft);
  if (!s->buffer) return luaL_error(L, "set:alloc: the device has no room for the set");
  ggml_backend_buffer_clear(s->buffer, 0);
  s->allocated = true;
  return 0;
}

/* set:clear() -- zeroes every tensor */
static int set_clear(lua_State *L) {
  ml_set *s = check_set(L, 1);
  if (s->buffer) ggml_backend_buffer_clear(s->buffer, 0);
  return 0;
}

/* engine:load(path [, { host = function (name) -> true for a tensor kept on the CPU }])
 * -> set. A GGUF file's tensors, on the engine's first device, and its metadata. */
/* A seek past 2 GB: `long` is 32 bits on Windows and in WebAssembly (whose off_t is 64). */
static int seek64(FILE *f, uint64_t at) {
#if defined(_WIN32)
  return _fseeki64(f, (__int64)at, SEEK_SET);
#else
  return fseeko(f, (off_t)at, SEEK_SET);
#endif
}

/* The CPU's buffer type that repacks a quantized weight for its matrix kernels (ggml's
 * "extra" buffer types: Q4_0 interleaved for NEON or AVX, ...), or NULL where there is none. */
static ggml_backend_buffer_type_t cpu_pack_buft(ml_engine *e) {
  ggml_backend_dev_t dev = ggml_backend_get_device(e->cpu);
  ggml_backend_reg_t reg = ggml_backend_dev_backend_reg(dev);
  ggml_backend_dev_get_extra_bufts_t extra =
    (ggml_backend_dev_get_extra_bufts_t)ggml_backend_reg_get_proc_address(reg, "ggml_backend_dev_get_extra_bufts");
  if (!extra) return NULL;
  ggml_backend_buffer_type_t *list = extra(dev);
  return list && list[0] ? list[0] : NULL;
}

/* Whether the CPU would run mul_mat(w, x) with w repacked: asked the way llama.cpp asks,
 * with the op built on a buffer of that type. */
static bool packable(ml_engine *e, ggml_backend_buffer_type_t buft, const struct ggml_tensor *w) {
  if (ggml_n_dims(w) != 2 || !ggml_is_quantized(w->type)) return false;
  struct ggml_init_params p = { 4 * ggml_tensor_overhead(), NULL, true };
  struct ggml_context *ctx = ggml_init(p);
  struct ggml_tensor *wc = ggml_new_tensor_2d(ctx, w->type, w->ne[0], w->ne[1]);
  struct ggml_tensor *x = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, w->ne[0], 8);
  struct ggml_tensor *op = ggml_mul_mat(ctx, wc, x);
  ggml_backend_buffer_t dummy = ggml_backend_buft_alloc_buffer(buft, 0);
  wc->buffer = dummy;
  bool ok = ggml_backend_dev_supports_op(ggml_backend_get_device(e->cpu), op);
  ggml_backend_buffer_free(dummy);
  ggml_free(ctx);
  return ok;
}

static int engine_load(lua_State *L) {
  const char *path = luaL_checkstring(L, 2);
  bool has_host = lua_istable(L, 3);
  bool has_pack = lua_istable(L, 3);
  bool data = true;
  if (lua_istable(L, 3)) {
    lua_getfield(L, 3, "data");
    if (lua_isboolean(L, -1)) data = lua_toboolean(L, -1);
    lua_pop(L, 1);
  }
  /* The two choosers, at fixed places on the stack: 4 is host, 5 is pack. */
  if (lua_istable(L, 3)) {
    lua_getfield(L, 3, "host");
    lua_getfield(L, 3, "pack");
  } else {
    lua_settop(L, 3); lua_pushnil(L); lua_pushnil(L);
  }
  lua_settop(L, 5);
  has_host = has_host && lua_isfunction(L, 4);
  has_pack = has_pack && lua_isfunction(L, 5);

  struct ggml_context *meta = NULL;
  struct gguf_init_params gp = { true, &meta };
  struct gguf_context *gguf = gguf_init_from_file(path, gp);
  if (!gguf) return luaL_error(L, "engine:load: \"%s\" is not a GGUF file that could be read", path);

  int64_t n = gguf_get_n_tensors(gguf);
  ml_set *s = new_set(L, 1, 0);
  int set_index = lua_gettop(L);
  s->gguf = gguf;
  s->ctx = meta;
  if (!data) return 1;          /* the metadata and the tensors' shapes, no data */

  /* A second context, so its tensors get their own buffer: on an engine with a GPU, the
   * tensors `host` keeps on the CPU; on an engine that is only the CPU, the weights `pack`
   * names that the CPU can repack for its matrix kernels. */
  ml_engine *e = s->engine;
  bool gpu = e->n_backends > 1;
  ggml_backend_buffer_type_t pack_buft = (!gpu && has_pack) ? cpu_pack_buft(e) : NULL;
  int chooser = gpu ? (has_host ? 4 : 0) : (pack_buft ? 5 : 0);
  ggml_backend_buffer_type_t second_buft = gpu ? ggml_backend_get_default_buffer_type(e->cpu) : pack_buft;
  struct ggml_context *host_ctx = NULL;
  if (chooser) {
    struct ggml_init_params p = { ggml_tensor_overhead() * (size_t)(n + 1), NULL, true };
    host_ctx = ggml_init(p);
    struct ggml_context *dev_ctx = ggml_init(p);
    for (struct ggml_tensor *t = ggml_get_first_tensor(meta); t; t = ggml_get_next_tensor(meta, t)) {
      lua_pushvalue(L, chooser);
      lua_pushstring(L, ggml_get_name(t));
      lua_call(L, 1, 1);
      bool second = lua_toboolean(L, -1);
      lua_pop(L, 1);
      if (second && !gpu) second = packable(e, pack_buft, t);
      struct ggml_tensor *c = ggml_dup_tensor(second ? host_ctx : dev_ctx, t);
      ggml_set_name(c, ggml_get_name(t));
    }
    ggml_free(meta);
    s->ctx = dev_ctx;
    meta = NULL;
  }

  s->buffer = ggml_backend_alloc_ctx_tensors_from_buft(s->ctx, e->bufts[0]);
  ggml_backend_buffer_t host_buffer = NULL;
  if (host_ctx) host_buffer = ggml_backend_alloc_ctx_tensors_from_buft(host_ctx, second_buft);
  if ((!s->buffer && ggml_get_first_tensor(s->ctx)) || (host_ctx && !host_buffer && ggml_get_first_tensor(host_ctx))) {
    return luaL_error(L, "engine:load: the device has no room for \"%s\"", path);
  }
  if (s->buffer) ggml_backend_buffer_set_usage(s->buffer, GGML_BACKEND_BUFFER_USAGE_WEIGHTS);

  /* The data, read a megabyte at a time and copied to wherever each tensor lives. A packed
   * tensor is the exception: the CPU repacks it as it is set, so it is set whole. */
  FILE *f = fopen(path, "rb");
  if (!f) return luaL_error(L, "engine:load: could not open \"%s\"", path);
  size_t base = gguf_get_data_offset(gguf);
  size_t cap = 1 << 20;
  char *chunk = (char *)malloc(cap);
  if (!chunk) { fclose(f); return luaL_error(L, "engine:load: no memory to read \"%s\"", path); }
  for (int64_t k = 0; k < n; k++) {
    const char *name = gguf_get_tensor_name(gguf, k);
    struct ggml_tensor *t = ggml_get_tensor(s->ctx, name);
    if (!t && host_ctx) t = ggml_get_tensor(host_ctx, name);
    if (!t) continue;
    size_t size = ggml_nbytes(t);
    bool whole = pack_buft && t->buffer && ggml_backend_buffer_get_type(t->buffer) == pack_buft;
    if (whole && size > cap) {
      char *bigger = (char *)realloc(chunk, size);
      if (!bigger) { free(chunk); fclose(f); return luaL_error(L, "engine:load: no memory to read %s from \"%s\"", name, path); }
      chunk = bigger; cap = size;
    }
    if (seek64(f, (uint64_t)(base + gguf_get_tensor_offset(gguf, k))) != 0) {
      free(chunk); fclose(f);
      return luaL_error(L, "engine:load: \"%s\" ends before the tensor %s", path, name);
    }
    for (size_t at = 0; at < size; ) {
      size_t piece = size - at < cap ? size - at : cap;
      if (fread(chunk, 1, piece, f) != piece) {
        free(chunk); fclose(f);
        return luaL_error(L, "engine:load: \"%s\" ends inside the tensor %s", path, name);
      }
      ggml_backend_tensor_set(t, chunk, at, piece);
      at += piece;
    }
  }
  free(chunk);
  fclose(f);

  /* The host tensors live in their own set, held in the uservalue table so name lookups
   * find them. */
  if (host_ctx) {
    ml_set *h = new_set(L, 1, 0);
    h->ctx = host_ctx;
    h->buffer = host_buffer;
    h->allocated = true;
    if (host_buffer) ggml_backend_buffer_set_usage(host_buffer, GGML_BACKEND_BUFFER_USAGE_WEIGHTS);
    lua_getfield(L, LUA_REGISTRYINDEX, "ml.host");
    lua_pushvalue(L, set_index);
    lua_pushvalue(L, -3);
    lua_rawset(L, -3);
    lua_pop(L, 2);
  }
  s->allocated = true;
  lua_pushvalue(L, set_index);
  return 1;
}

static struct ggml_tensor *set_find(lua_State *L, int set_index, const char *name, ml_set **where, int *where_index) {
  ml_set *s = check_set(L, set_index);
  struct ggml_tensor *t = s->ctx ? ggml_get_tensor(s->ctx, name) : NULL;
  if (t) { *where = s; *where_index = set_index; return t; }
  lua_getfield(L, LUA_REGISTRYINDEX, "ml.host");
  lua_pushvalue(L, set_index);
  lua_rawget(L, -2);
  lua_remove(L, -2);
  if (lua_isuserdata(L, -1)) {
    ml_set *h = (ml_set *)lua_touserdata(L, -1);
    t = ggml_get_tensor(h->ctx, name);
    if (t) { *where = h; *where_index = lua_gettop(L); return t; }
  }
  lua_pop(L, 1);
  return NULL;
}

/* set:get(name) -> tensor, or nil */
static int set_get(lua_State *L) {
  const char *name = luaL_checkstring(L, 2);
  ml_set *where; int wi;
  int top = lua_gettop(L);
  struct ggml_tensor *t = set_find(L, 1, name, &where, &wi);
  if (!t) { lua_settop(L, top); lua_pushnil(L); return 1; }
  ml_pushtensor(L, t, &where->owner, wi);
  return 1;
}

/* set:names() -> { name, ... } in file order */
static int set_names(lua_State *L) {
  ml_set *s = check_set(L, 1);
  lua_newtable(L);
  int k = 1;
  if (s->gguf) {
    for (int64_t i = 0; i < gguf_get_n_tensors(s->gguf); i++) {
      lua_pushstring(L, gguf_get_tensor_name(s->gguf, i));
      lua_rawseti(L, -2, k++);
    }
  } else if (s->ctx) {
    for (struct ggml_tensor *t = ggml_get_first_tensor(s->ctx); t; t = ggml_get_next_tensor(s->ctx, t)) {
      lua_pushstring(L, ggml_get_name(t));
      lua_rawseti(L, -2, k++);
    }
  }
  return 1;
}

static size_t gguf_size_of(enum gguf_type t) {
  switch (t) {
    case GGUF_TYPE_UINT8: case GGUF_TYPE_INT8: case GGUF_TYPE_BOOL: return 1;
    case GGUF_TYPE_UINT16: case GGUF_TYPE_INT16: return 2;
    case GGUF_TYPE_UINT32: case GGUF_TYPE_INT32: case GGUF_TYPE_FLOAT32: return 4;
    case GGUF_TYPE_UINT64: case GGUF_TYPE_INT64: case GGUF_TYPE_FLOAT64: return 8;
    default: return 0;
  }
}

static void push_gguf_value(lua_State *L, struct gguf_context *g, int64_t id, enum gguf_type type, const void *p) {
  switch (type) {
    case GGUF_TYPE_UINT8:   lua_pushinteger(L, *(const uint8_t *)p); break;
    case GGUF_TYPE_INT8:    lua_pushinteger(L, *(const int8_t *)p); break;
    case GGUF_TYPE_UINT16:  lua_pushinteger(L, *(const uint16_t *)p); break;
    case GGUF_TYPE_INT16:   lua_pushinteger(L, *(const int16_t *)p); break;
    case GGUF_TYPE_UINT32:  lua_pushnumber(L, (lua_Number)*(const uint32_t *)p); break;
    case GGUF_TYPE_INT32:   lua_pushinteger(L, *(const int32_t *)p); break;
    case GGUF_TYPE_UINT64:  lua_pushnumber(L, (lua_Number)*(const uint64_t *)p); break;
    case GGUF_TYPE_INT64:   lua_pushnumber(L, (lua_Number)*(const int64_t *)p); break;
    case GGUF_TYPE_FLOAT32: lua_pushnumber(L, *(const float *)p); break;
    case GGUF_TYPE_FLOAT64: lua_pushnumber(L, *(const double *)p); break;
    case GGUF_TYPE_BOOL:    lua_pushboolean(L, *(const int8_t *)p != 0); break;
    default: (void)g; (void)id; lua_pushnil(L);
  }
}

/* set:meta(key) -> a number, string, boolean or list; nil when the file has no such key */
static int set_meta(lua_State *L) {
  ml_set *s = check_set(L, 1);
  const char *key = luaL_checkstring(L, 2);
  if (!s->gguf) { lua_pushnil(L); return 1; }
  int64_t id = gguf_find_key(s->gguf, key);
  if (id < 0) { lua_pushnil(L); return 1; }
  enum gguf_type type = gguf_get_kv_type(s->gguf, id);
  if (type == GGUF_TYPE_STRING) { lua_pushstring(L, gguf_get_val_str(s->gguf, id)); return 1; }
  if (type == GGUF_TYPE_ARRAY) {
    enum gguf_type at = gguf_get_arr_type(s->gguf, id);
    size_t n = gguf_get_arr_n(s->gguf, id);
    lua_createtable(L, (int)n, 0);
    if (at == GGUF_TYPE_STRING) {
      for (size_t k = 0; k < n; k++) { lua_pushstring(L, gguf_get_arr_str(s->gguf, id, k)); lua_rawseti(L, -2, (int)k + 1); }
    } else {
      const char *data = (const char *)gguf_get_arr_data(s->gguf, id);
      size_t size = gguf_size_of(at);
      for (size_t k = 0; k < n; k++) { push_gguf_value(L, s->gguf, id, at, data + k * size); lua_rawseti(L, -2, (int)k + 1); }
    }
    return 1;
  }
  push_gguf_value(L, s->gguf, id, type, gguf_get_val_data(s->gguf, id));
  return 1;
}

/* set:keys() -> { key, ... } */
static int set_keys(lua_State *L) {
  ml_set *s = check_set(L, 1);
  lua_newtable(L);
  if (!s->gguf) return 1;
  for (int64_t k = 0; k < gguf_get_n_kv(s->gguf); k++) {
    lua_pushstring(L, gguf_get_key(s->gguf, k));
    lua_rawseti(L, -2, (int)k + 1);
  }
  return 1;
}

/* set:tokenizer() -> the tokenizer the file's metadata describes (tok.c) */
static int set_tokenizer(lua_State *L) {
  ml_set *s = check_set(L, 1);
  return ml_tokenizer_from_gguf(L, s->gguf);
}

/* set:bytes() -> the bytes the set's tensors take on the device */
static int set_bytes(lua_State *L) {
  ml_set *s = check_set(L, 1);
  lua_pushnumber(L, s->buffer ? (lua_Number)ggml_backend_buffer_get_size(s->buffer) : 0);
  return 1;
}

static void free_set(ml_set *s) {
  if (!s->owner.alive) return;
  s->owner.alive = false;
  live_remove(&s->owner);
  if (s->buffer) ggml_backend_buffer_free(s->buffer);
  if (s->ctx) ggml_free(s->ctx);
  if (s->gguf) gguf_free(s->gguf);
  s->buffer = NULL; s->ctx = NULL; s->gguf = NULL;
}

static int set_free(lua_State *L) {
  ml_set *s = (ml_set *)luaL_checkudata(L, 1, ML_SET);
  free_set(s);
  return 0;
}

/* ================================================================== tensors */

/* tensor:shape() -> ne0, ne1, ne2, ne3 */
static int tensor_shape(lua_State *L) {
  struct ggml_tensor *t = ml_checktensor(L, 1);
  for (int k = 0; k < 4; k++) lua_pushinteger(L, (lua_Integer)t->ne[k]);
  return 4;
}

/* tensor:strides() -> nb0, nb1, nb2, nb3 in bytes */
static int tensor_strides(lua_State *L) {
  struct ggml_tensor *t = ml_checktensor(L, 1);
  for (int k = 0; k < 4; k++) lua_pushinteger(L, (lua_Integer)t->nb[k]);
  return 4;
}

static int tensor_type(lua_State *L) {
  struct ggml_tensor *t = ml_checktensor(L, 1);
  lua_pushstring(L, ggml_type_name(t->type));
  return 1;
}

static int tensor_name(lua_State *L) {
  struct ggml_tensor *t = ml_checktensor(L, 1);
  if (!lua_isnoneornil(L, 2)) { ggml_set_name(t, luaL_checkstring(L, 2)); lua_settop(L, 1); return 1; }
  lua_pushstring(L, ggml_get_name(t));
  return 1;
}

static int tensor_nelements(lua_State *L) {
  struct ggml_tensor *t = ml_checktensor(L, 1);
  lua_pushinteger(L, (lua_Integer)ggml_nelements(t));
  return 1;
}

static int tensor_nbytes(lua_State *L) {
  struct ggml_tensor *t = ml_checktensor(L, 1);
  lua_pushinteger(L, (lua_Integer)ggml_nbytes(t));
  return 1;
}

static int tensor_tostring(lua_State *L) {
  ml_tensor *h = (ml_tensor *)luaL_checkudata(L, 1, ML_TENSOR);
  if (!h->owner->alive || h->gen != h->owner->gen) { lua_pushstring(L, "ml.tensor (stale)"); return 1; }
  struct ggml_tensor *t = h->t;
  lua_pushfstring(L, "ml.tensor %s %s [%d, %d, %d, %d]", ggml_get_name(t), ggml_type_name(t->type),
                  (int)t->ne[0], (int)t->ne[1], (int)t->ne[2], (int)t->ne[3]);
  return 1;
}

/* tensor:write(buffer [, offset_in_elements]) and tensor:read() -> buffer: a set's tensor,
 * straight from and to the device. For weights and state; a graph's tensors are read with
 * graph:read after compute. */
static size_t element_size(struct ggml_tensor *t) { return ggml_type_size(t->type) / ggml_blck_size(t->type); }

static int tensor_write(lua_State *L) {
  struct ggml_tensor *t = ml_checktensor(L, 1);
  if (!t->buffer) return luaL_error(L, "tensor:write: the tensor has no memory yet (alloc its set, or use graph:set)");
  ml_buffer *b = ml_checkbuffer(L, 2);
  size_t offset = (size_t)ml_optint(L, 3, 0);
  size_t es = element_size(t);
  if ((b->type == ML_F32 && t->type != GGML_TYPE_F32) || (b->type == ML_I32 && t->type != GGML_TYPE_I32)) {
    return luaL_error(L, "tensor:write: the buffer is %s and the tensor is %s", b->type == ML_F32 ? "f32" : "i32", ggml_type_name(t->type));
  }
  if ((offset + b->n) * es > ggml_nbytes(t)) return luaL_error(L, "tensor:write: %d values from %d do not fit", (int)b->n, (int)offset);
  ggml_backend_tensor_set(t, b->data.p, offset * es, b->n * es);
  return 0;
}

static int tensor_read(lua_State *L) {
  struct ggml_tensor *t = ml_checktensor(L, 1);
  if (!t->buffer) return luaL_error(L, "tensor:read: the tensor has no memory");
  if (t->type != GGML_TYPE_F32 && t->type != GGML_TYPE_I32) {
    return luaL_error(L, "tensor:read: a %s tensor; read an f32 or i32 one (cast it in a graph)", ggml_type_name(t->type));
  }
  ml_buffer *b = ml_newbuffer(L, t->type == GGML_TYPE_F32 ? ML_F32 : ML_I32, (size_t)ggml_nelements(t));
  ggml_backend_tensor_get(t, b->data.p, 0, ggml_nbytes(t));
  return 1;
}

/* ================================================================== graphs */

static ml_graph *check_graph(lua_State *L, int i) {
  ml_graph *g = (ml_graph *)luaL_checkudata(L, i, ML_GRAPH);
  if (!g->owner.alive) luaL_argerror(L, i, "this graph was freed");
  if (g->engine->closed) luaL_argerror(L, i, "this graph's engine was closed");
  return g;
}

static void graph_start(lua_State *L, ml_graph *g) {
  struct ggml_init_params p = { ggml_tensor_overhead() * g->max_nodes + ggml_graph_overhead_custom(g->max_nodes, false), NULL, true };
  g->ctx = ggml_init(p);
  if (!g->ctx) luaL_error(L, "ml: out of memory for a graph of %d nodes", (int)g->max_nodes);
  g->cgraph = ggml_new_graph_custom(g->ctx, g->max_nodes, false);
  g->computed = false;
  g->prepared = false;
}

static void graph_drop_pending(ml_graph *g) {
  for (int k = 0; k < g->n_pending; k++) free(g->pending[k].data);
  g->n_pending = 0;
}

/* engine:graph([max_nodes]) -> graph */
static int engine_graph(lua_State *L) {
  ml_engine *e = check_engine(L, 1);
  size_t max_nodes = (size_t)ml_optint(L, 2, 8192);
  ml_graph *g = (ml_graph *)lua_newuserdata(L, sizeof(ml_graph));
  memset(g, 0, sizeof(*g));
  g->owner.alive = true;
  live_add(&g->owner, 2);
  g->engine = e;
  g->max_nodes = max_nodes;
  luaL_setmetatable(L, ML_GRAPH);
  ml_ref_owner(L, -1, 1);
  graph_start(L, g);
  g->sched = ggml_backend_sched_new(e->backends, e->bufts, e->n_backends, max_nodes, false, true);
  if (!g->sched) return luaL_error(L, "ml: the scheduler would not start");
  return 1;
}

/* graph:reset() -- every tensor of this graph becomes stale; the graph is empty again */
static int graph_reset(lua_State *L) {
  ml_graph *g = check_graph(L, 1);
  g->owner.gen++;
  ggml_backend_sched_reset(g->sched);
  ggml_free(g->ctx);
  graph_drop_pending(g);
  graph_start(L, g);
  return 0;
}

static void free_graph(ml_graph *g) {
  if (!g->owner.alive) return;
  g->owner.alive = false;
  live_remove(&g->owner);
  graph_drop_pending(g);
  free(g->pending); g->pending = NULL; g->cap_pending = 0;
  if (g->sched) ggml_backend_sched_free(g->sched);
  if (g->ctx) ggml_free(g->ctx);
  g->sched = NULL; g->ctx = NULL;
}

static int graph_free(lua_State *L) {
  ml_graph *g = (ml_graph *)luaL_checkudata(L, 1, ML_GRAPH);
  free_graph(g);
  return 0;
}

/* graph:input(type, ne0 [, ne1, ne2, ne3]) -> tensor whose data graph:set gives */
static int graph_input(lua_State *L) {
  ml_graph *g = check_graph(L, 1);
  enum ggml_type type = ml_checktype(L, 2);
  int64_t ne[4] = { ml_checkint(L, 3), ml_optint(L, 4, 1), ml_optint(L, 5, 1), ml_optint(L, 6, 1) };
  int dims = lua_gettop(L) - 2;
  struct ggml_tensor *t = ggml_new_tensor(g->ctx, type, dims < 1 ? 1 : (dims > 4 ? 4 : dims), ne);
  ggml_set_input(t);
  ml_pushtensor(L, t, &g->owner, 1);
  return 1;
}

/* graph:set(tensor, buffer) -- the data an input tensor holds when the graph computes */
static int graph_set(lua_State *L) {
  ml_graph *g = check_graph(L, 1);
  struct ggml_tensor *t = ml_checktensor(L, 2);
  ml_buffer *b = ml_checkbuffer(L, 3);
  if (!(t->flags & GGML_TENSOR_FLAG_INPUT)) return luaL_error(L, "graph:set: the tensor is not one of this graph's inputs");
  bool half = b->type == ML_F32 && t->type == GGML_TYPE_F16;   /* an f16 input takes f32, converted */
  if (!half && ((b->type == ML_F32 && t->type != GGML_TYPE_F32) || (b->type == ML_I32 && t->type != GGML_TYPE_I32))) {
    return luaL_error(L, "graph:set: the buffer is %s and the tensor is %s", b->type == ML_F32 ? "f32" : "i32", ggml_type_name(t->type));
  }
  if ((int64_t)b->n != ggml_nelements(t)) {
    return luaL_error(L, "graph:set: the tensor holds %d values and the buffer %d", (int)ggml_nelements(t), (int)b->n);
  }
  if (g->n_pending == g->cap_pending) {
    g->cap_pending = g->cap_pending ? g->cap_pending * 2 : 16;
    g->pending = (ml_pending *)realloc(g->pending, sizeof(ml_pending) * (size_t)g->cap_pending);
  }
  ml_pending *p = &g->pending[g->n_pending++];
  p->t = t;
  p->size = ggml_nbytes(t);
  p->data = malloc(p->size);
  if (half) ggml_fp32_to_fp16_row(b->data.f, (ggml_fp16_t *)p->data, (int64_t)b->n);
  else memcpy(p->data, b->data.p, p->size);
  return 0;
}

/* graph:expand(tensor) -- compute this node, and everything it needs, now in the graph's
 * order, even though nothing reads it: a copy into a set's tensor (a KV cache, a recurrent
 * state). A write expanded before the ops that read the same memory runs before them; ggml
 * sees no edge between a write into a set and a later view of it, so the order is this. */
static int graph_expand(lua_State *L) {
  ml_graph *g = check_graph(L, 1);
  struct ggml_tensor *t = ml_checktensor(L, 2);
  if (g->computed) return luaL_error(L, "graph:expand: the graph was computed; reset it first");
  ggml_build_forward_expand(g->cgraph, t);
  return 0;
}

/* Build and allocate, or refresh inputs on a graph already computed. poll() runs it. */
static void graph_prepare(lua_State *L, ml_graph *g, int top) {
  op_L = NULL;
  if (g->computed) {
    for (int k = 0; k < g->n_pending; k++) {
      ggml_backend_tensor_set(g->pending[k].t, g->pending[k].data, 0, g->pending[k].size);
    }
    graph_drop_pending(g);
    g->prepared = true;
    return;
  }
  for (int k = 2; k <= top; k++) {
    struct ggml_tensor *t = ml_checktensor(L, k);
    ggml_set_output(t);
    ggml_build_forward_expand(g->cgraph, t);
  }
  /* ggml keeps the last memory plan while a graph has as many nodes and each still fits,
   * without looking at which nodes are outputs: a graph that reads other tensors than the
   * last one would read memory a later node wrote over. Other outputs, a new scheduler,
   * which plans afresh. (Asking the old one to re-plan, ggml_backend_sched_reserve, lost
   * the inputs' copies to the GPU once a set was on it.) */
  uint64_t outputs = 1469598103934665603ull;
  for (int i = 0; i < ggml_graph_n_nodes(g->cgraph); i++) {
    if (ggml_graph_node(g->cgraph, i)->flags & GGML_TENSOR_FLAG_OUTPUT) {
      outputs = (outputs ^ (uint64_t)(i + 1)) * 1099511628211ull;
    }
  }
  if (g->outputs && outputs != g->outputs) {
    ggml_backend_sched_free(g->sched);
    g->sched = ggml_backend_sched_new(g->engine->backends, g->engine->bufts, g->engine->n_backends, g->max_nodes, false, true);
    if (!g->sched) luaL_error(L, "ml: the scheduler would not start");
  }
  g->outputs = outputs;
  if (!ggml_backend_sched_alloc_graph(g->sched, g->cgraph)) {
    luaL_error(L, "graph:compute: the devices have no room for the graph");
  }
  for (int k = 0; k < g->n_pending; k++) {
    if (!g->pending[k].t->buffer) {
      luaL_error(L, "graph:compute: the input %s is not used by anything computed", ggml_get_name(g->pending[k].t));
    }
    ggml_backend_tensor_set(g->pending[k].t, g->pending[k].data, 0, g->pending[k].size);
  }
  graph_drop_pending(g);
  g->prepared = true;
}

static void graph_run(lua_State *L, ml_graph *g) {
  enum ggml_status st = ggml_backend_sched_graph_compute(g->sched, g->cgraph);
  if (st != GGML_STATUS_SUCCESS) luaL_error(L, "graph:compute: the device failed (status %d)", (int)st);
  g->computed = true;
  g->prepared = false;
}

/* graph:compute(out1, out2, ...) -- builds the graph that reaches the outputs and every
 * expanded node, and runs it. The outputs can be read with graph:read. */
static int graph_compute(lua_State *L) {
  ml_graph *g = check_graph(L, 1);
  graph_prepare(L, g, lua_gettop(L));
  graph_run(L, g);
  return 0;
}

/* graph:start(out1, ...) -- prepare only. poll() runs the compute, so a frame can start
 * a graph and finish it on a later one (spec/ml.md). */
static int graph_compute_begin(lua_State *L) {
  ml_graph *g = check_graph(L, 1);
  graph_prepare(L, g, lua_gettop(L));
  return 0;
}

/* graph:poll() -> true when the graph has been computed. One slice: the remaining work. */
static int graph_compute_poll(lua_State *L) {
  ml_graph *g = check_graph(L, 1);
  if (g->computed && !g->prepared) { lua_pushboolean(L, 1); return 1; }
  if (!g->prepared) return luaL_error(L, "graph:poll: start the graph first");
  graph_run(L, g);
  lua_pushboolean(L, 1);
  return 1;
}

/* graph:read(tensor) -> buffer: an output, after compute */
static int graph_read(lua_State *L) {
  check_graph(L, 1);
  struct ggml_tensor *t = ml_checktensor(L, 2);
  if (!t->buffer) return luaL_error(L, "graph:read: %s was not computed (pass it to compute)", ggml_get_name(t));
  if (t->type != GGML_TYPE_F32 && t->type != GGML_TYPE_I32) {
    return luaL_error(L, "graph:read: %s is %s; read an f32 or i32 tensor (cast it first)", ggml_get_name(t), ggml_type_name(t->type));
  }
  if (!ggml_is_contiguous(t)) return luaL_error(L, "graph:read: %s is not contiguous (cont it first)", ggml_get_name(t));
  ml_buffer *b = ml_newbuffer(L, t->type == GGML_TYPE_F32 ? ML_F32 : ML_I32, (size_t)ggml_nelements(t));
  ggml_backend_tensor_get(t, b->data.p, 0, ggml_nbytes(t));
  return 1;
}

/* graph:nodes() -> how many nodes the computed graph has; graph:splits() -> how many
 * pieces the scheduler cut it into (more than one means some op fell back to the CPU) */
static int graph_nodes(lua_State *L) {
  ml_graph *g = check_graph(L, 1);
  lua_pushinteger(L, g->cgraph ? ggml_graph_n_nodes(g->cgraph) : 0);
  return 1;
}

static int graph_splits(lua_State *L) {
  ml_graph *g = check_graph(L, 1);
  lua_pushinteger(L, ggml_backend_sched_get_n_splits(g->sched));
  return 1;
}

/* ================================================================== ops
 *
 * Every op is graph:<op>(...) and answers a new tensor of the graph. The names and
 * arguments are ggml's, so ggml's documentation is theirs too (spec/ml.md, "Ops").
 */

#define G   ml_graph *g = check_graph(L, 1); op_L = L; op_thread = this_thread()
#define T(i) ml_checktensor(L, (i))
#define F(i) ((float)luaL_checknumber(L, (i)))
#define FO(i, d) ((float)luaL_optnumber(L, (i), (d)))
#define I(i) ((int)ml_checkint(L, (i)))
#define IO(i, d) ((int)ml_optint(L, (i), (d)))
#define RET(x) do { struct ggml_tensor *r_ = (x); op_L = NULL; ml_pushtensor(L, r_, &g->owner, 1); return 1; } while (0)

#define UNARY(name, fn) static int op_##name(lua_State *L) { G; RET(fn(g->ctx, T(2))); }
#define BINARY(name, fn) static int op_##name(lua_State *L) { G; RET(fn(g->ctx, T(2), T(3))); }

UNARY(neg, ggml_neg)
UNARY(abs, ggml_abs)
UNARY(sgn, ggml_sgn)
UNARY(step, ggml_step)
UNARY(tanh, ggml_tanh)
UNARY(elu, ggml_elu)
UNARY(relu, ggml_relu)
UNARY(sigmoid, ggml_sigmoid)
UNARY(gelu, ggml_gelu)
UNARY(gelu_erf, ggml_gelu_erf)
UNARY(gelu_quick, ggml_gelu_quick)
UNARY(silu, ggml_silu)
UNARY(exp, ggml_exp)
UNARY(log, ggml_log)
UNARY(sqr, ggml_sqr)
UNARY(sqrt, ggml_sqrt)
UNARY(sin, ggml_sin)
UNARY(cos, ggml_cos)
UNARY(cont, ggml_cont)
UNARY(transpose, ggml_transpose)
UNARY(sum, ggml_sum)
UNARY(sum_rows, ggml_sum_rows)
UNARY(mean, ggml_mean)
UNARY(argmax, ggml_argmax)
UNARY(soft_max, ggml_soft_max)
UNARY(dup, ggml_dup)
UNARY(swiglu_swapped, ggml_swiglu_swapped)   /* silu of the second half times the first */

BINARY(add, ggml_add)
BINARY(sub, ggml_sub)
BINARY(mul, ggml_mul)
BINARY(div, ggml_div)
BINARY(mul_mat, ggml_mul_mat)
BINARY(out_prod, ggml_out_prod)
BINARY(get_rows, ggml_get_rows)
BINARY(cpy, ggml_cpy)
BINARY(repeat, ggml_repeat)
BINARY(swiglu_split, ggml_swiglu_split)
BINARY(geglu_split, ggml_geglu_split)

/* graph:mul_mat_f32(a, b): mul_mat accumulated in f32 whatever the device prefers */
static int op_mul_mat_f32(lua_State *L) {
  G;
  struct ggml_tensor *r = ggml_mul_mat(g->ctx, T(2), T(3));
  ggml_prec_set_acc(r, GGML_PREC_F32);
  RET(r);
}

static int op_scale(lua_State *L) { G; RET(ggml_scale(g->ctx, T(2), F(3))); }
static int op_scale_bias(lua_State *L) { G; RET(ggml_scale_bias(g->ctx, T(2), F(3), F(4))); }
static int op_clamp(lua_State *L) { G; RET(ggml_clamp(g->ctx, T(2), F(3), F(4))); }
static int op_leaky_relu(lua_State *L) { G; RET(ggml_leaky_relu(g->ctx, T(2), F(3), false)); }
static int op_norm(lua_State *L) { G; RET(ggml_norm(g->ctx, T(2), FO(3, 1e-5f))); }
static int op_rms_norm(lua_State *L) { G; RET(ggml_rms_norm(g->ctx, T(2), FO(3, 1e-6f))); }
static int op_l2_norm(lua_State *L) { G; RET(ggml_l2_norm(g->ctx, T(2), FO(3, 1e-12f))); }
static int op_group_norm(lua_State *L) { G; RET(ggml_group_norm(g->ctx, T(2), I(3), FO(4, 1e-5f))); }
static int op_cast(lua_State *L) { G; RET(ggml_cast(g->ctx, T(2), ml_checktype(L, 3))); }
static int op_concat(lua_State *L) { G; RET(ggml_concat(g->ctx, T(2), T(3), IO(4, 0))); }
static int op_set_rows(lua_State *L) { G; RET(ggml_set_rows(g->ctx, T(2), T(3), T(4))); }
static int op_diag_mask_inf(lua_State *L) { G; RET(ggml_diag_mask_inf(g->ctx, T(2), I(3))); }
static int op_top_k(lua_State *L) { G; RET(ggml_top_k(g->ctx, T(2), I(3))); }
static int op_arange(lua_State *L) { G; RET(ggml_arange(g->ctx, F(2), F(3), FO(4, 1.0f))); }

static int op_argsort(lua_State *L) {
  G;
  const char *order = luaL_optstring(L, 3, "asc");
  RET(ggml_argsort(g->ctx, T(2), strcmp(order, "desc") == 0 ? GGML_SORT_ORDER_DESC : GGML_SORT_ORDER_ASC));
}

/* graph:soft_max_ext(a, mask|nil, scale, max_bias) */
static int op_soft_max_ext(lua_State *L) { G; RET(ggml_soft_max_ext(g->ctx, T(2), ml_opttensor(L, 3), FO(4, 1.0f), FO(5, 0.0f))); }

/* graph:rope_ext(a, pos, freq_factors|nil, n_dims, mode, n_ctx_orig, freq_base, freq_scale,
 *                ext_factor, attn_factor, beta_fast, beta_slow) */
static int op_rope_ext(lua_State *L) {
  G;
  RET(ggml_rope_ext(g->ctx, T(2), T(3), ml_opttensor(L, 4), I(5), IO(6, 0), IO(7, 0), FO(8, 10000.0f),
                    FO(9, 1.0f), FO(10, 0.0f), FO(11, 1.0f), FO(12, 32.0f), FO(13, 1.0f)));
}

/* graph:flash_attn_ext(q, k, v, mask|nil, scale, max_bias, logit_softcap) */
static int op_flash_attn_ext(lua_State *L) {
  G;
  struct ggml_tensor *r = ggml_flash_attn_ext(g->ctx, T(2), T(3), T(4), ml_opttensor(L, 5), F(6), FO(7, 0.0f), FO(8, 0.0f));
  ggml_prec_set_acc(r, GGML_PREC_F32);
  RET(r);
}

/* graph:conv_1d(kernel, data, stride, padding, dilation) and friends */
static int op_conv_1d(lua_State *L) { G; RET(ggml_conv_1d(g->ctx, T(2), T(3), IO(4, 1), IO(5, 0), IO(6, 1))); }
static int op_conv_1d_dw(lua_State *L) { G; RET(ggml_conv_1d_dw(g->ctx, T(2), T(3), IO(4, 1), IO(5, 0), IO(6, 1))); }
static int op_conv_transpose_1d(lua_State *L) { G; RET(ggml_conv_transpose_1d(g->ctx, T(2), T(3), IO(4, 1), IO(5, 0), IO(6, 1))); }

/* graph:im2col(kernel, data, s0, s1, p0, p1, d0, d1, is_2d, type) */
static int op_im2col(lua_State *L) {
  G;
  RET(ggml_im2col(g->ctx, T(2), T(3), I(4), I(5), I(6), I(7), I(8), I(9), lua_toboolean(L, 10), ml_opttype(L, 11, GGML_TYPE_F32)));
}

/* graph:pad(a, p0, p1, p2, p3) pads at the end; graph:pad_ext(a, lp0, rp0, lp1, rp1, ...) */
static int op_pad(lua_State *L) { G; RET(ggml_pad(g->ctx, T(2), IO(3, 0), IO(4, 0), IO(5, 0), IO(6, 0))); }
static int op_pad_ext(lua_State *L) {
  G;
  RET(ggml_pad_ext(g->ctx, T(2), IO(3, 0), IO(4, 0), IO(5, 0), IO(6, 0), IO(7, 0), IO(8, 0), IO(9, 0), IO(10, 0)));
}
/* graph:pad_reflect_1d(a, p0, p1): p0 before and p1 after along ne0, mirrored without
 * repeating the edge ([a b c d] -> [b a b c d c]) */
static int op_pad_reflect_1d(lua_State *L) { G; RET(ggml_pad_reflect_1d(g->ctx, T(2), IO(3, 0), IO(4, 0))); }

static int op_pool_1d(lua_State *L) {
  G;
  const char *op = luaL_optstring(L, 3, "avg");
  RET(ggml_pool_1d(g->ctx, T(2), strcmp(op, "max") == 0 ? GGML_OP_POOL_MAX : GGML_OP_POOL_AVG, I(4), I(5), IO(6, 0)));
}

/* graph:interpolate(a, ne0, ne1, ne2, ne3, "nearest" | "bilinear") */
static int op_interpolate(lua_State *L) {
  G;
  const char *mode = luaL_optstring(L, 7, "nearest");
  RET(ggml_interpolate(g->ctx, T(2), ml_checkint(L, 3), ml_checkint(L, 4), ml_checkint(L, 5), ml_checkint(L, 6),
                       strcmp(mode, "bilinear") == 0 ? GGML_SCALE_MODE_BILINEAR : GGML_SCALE_MODE_NEAREST));
}

/* graph:reshape(a, ne0 [, ne1, ne2, ne3]) */
static int op_reshape(lua_State *L) {
  G;
  struct ggml_tensor *a = T(2);
  int n = lua_gettop(L) - 2;
  switch (n) {
    case 1: RET(ggml_reshape_1d(g->ctx, a, ml_checkint(L, 3)));
    case 2: RET(ggml_reshape_2d(g->ctx, a, ml_checkint(L, 3), ml_checkint(L, 4)));
    case 3: RET(ggml_reshape_3d(g->ctx, a, ml_checkint(L, 3), ml_checkint(L, 4), ml_checkint(L, 5)));
    case 4: RET(ggml_reshape_4d(g->ctx, a, ml_checkint(L, 3), ml_checkint(L, 4), ml_checkint(L, 5), ml_checkint(L, 6)));
    default: return luaL_error(L, "graph:reshape: 1 to 4 sizes");
  }
}

/* graph:view(a, {ne0, ...}, {nb1, ...}, offset_bytes): 1 to 4 sizes, and one stride fewer */
static int op_view(lua_State *L) {
  G;
  struct ggml_tensor *a = T(2);
  luaL_checktype(L, 3, LUA_TTABLE);
  int n = (int)ml_rawlen(L, 3);
  int64_t ne[4] = {1, 1, 1, 1};
  size_t nb[3] = {0, 0, 0};
  for (int k = 0; k < n && k < 4; k++) { lua_rawgeti(L, 3, k + 1); ne[k] = ml_checkint(L, -1); lua_pop(L, 1); }
  if (n > 1) {
    luaL_checktype(L, 4, LUA_TTABLE);
    for (int k = 0; k < n - 1 && k < 3; k++) { lua_rawgeti(L, 4, k + 1); nb[k] = (size_t)ml_checkint(L, -1); lua_pop(L, 1); }
  }
  size_t offset = (size_t)ml_optint(L, n > 1 ? 5 : 4, 0);
  switch (n) {
    case 1: RET(ggml_view_1d(g->ctx, a, ne[0], offset));
    case 2: RET(ggml_view_2d(g->ctx, a, ne[0], ne[1], nb[0], offset));
    case 3: RET(ggml_view_3d(g->ctx, a, ne[0], ne[1], ne[2], nb[0], nb[1], offset));
    case 4: RET(ggml_view_4d(g->ctx, a, ne[0], ne[1], ne[2], ne[3], nb[0], nb[1], nb[2], offset));
    default: return luaL_error(L, "graph:view: 1 to 4 sizes");
  }
}

static int op_permute(lua_State *L) { G; RET(ggml_permute(g->ctx, T(2), I(3), I(4), IO(5, 2), IO(6, 3))); }
static int op_repeat_4d(lua_State *L) {
  G;
  RET(ggml_repeat_4d(g->ctx, T(2), ml_checkint(L, 3), ml_optint(L, 4, 1), ml_optint(L, 5, 1), ml_optint(L, 6, 1)));
}

/* graph:cont_nd(a, ne0, ne1, ne2, ne3) -- cont into a new shape */
static int op_cont_nd(lua_State *L) {
  G;
  RET(ggml_cont_4d(g->ctx, T(2), ml_checkint(L, 3), ml_optint(L, 4, 1), ml_optint(L, 5, 1), ml_optint(L, 6, 1)));
}

/* graph:fill(type, value, ne0 [, ne1, ne2, ne3]) -- a constant tensor, made on the device */
static int op_fill(lua_State *L) {
  G;
  enum ggml_type type = ml_checktype(L, 2);
  float v = F(3);
  int64_t ne[4] = { ml_checkint(L, 4), ml_optint(L, 5, 1), ml_optint(L, 6, 1), ml_optint(L, 7, 1) };
  struct ggml_tensor *t = ggml_new_tensor(g->ctx, type, 4, ne);
  RET(ggml_fill(g->ctx, t, v));
}

#undef G
#undef T
#undef F
#undef FO
#undef I
#undef IO
#undef RET

/* ================================================================== logging
 * ggml says a great deal on stderr. The console hears errors only, unless ML_LOG says
 * otherwise: "warn", "info" or "debug". */

static int log_floor = GGML_LOG_LEVEL_ERROR;

static void ml_log(enum ggml_log_level level, const char *text, void *user) {
  (void)user;
  if (level == GGML_LOG_LEVEL_CONT) { if (log_floor <= GGML_LOG_LEVEL_INFO) fputs(text, stderr); return; }
  if ((int)level >= log_floor) fputs(text, stderr);
}

static void log_from_env(void) {
  const char *v = getenv("ML_LOG");
  if (!v) return;
  if (!strcmp(v, "debug")) log_floor = GGML_LOG_LEVEL_DEBUG;
  else if (!strcmp(v, "info")) log_floor = GGML_LOG_LEVEL_INFO;
  else if (!strcmp(v, "warn")) log_floor = GGML_LOG_LEVEL_WARN;
}

/* ================================================================== module */

static const luaL_Reg engine_methods[] = {
  { "set", engine_set }, { "load", engine_load }, { "graph", engine_graph },
  { "device", engine_device }, { "threads", engine_threads }, { "close", engine_close },
  { NULL, NULL }
};

static const luaL_Reg set_methods[] = {
  { "new", set_new }, { "alloc", set_alloc }, { "clear", set_clear }, { "get", set_get },
  { "names", set_names }, { "meta", set_meta }, { "keys", set_keys }, { "bytes", set_bytes },
  { "tokenizer", set_tokenizer }, { "free", set_free }, { NULL, NULL }
};

static const luaL_Reg tensor_methods[] = {
  { "shape", tensor_shape }, { "strides", tensor_strides }, { "type", tensor_type },
  { "name", tensor_name }, { "nelements", tensor_nelements }, { "nbytes", tensor_nbytes },
  { "write", tensor_write }, { "read", tensor_read }, { NULL, NULL }
};

static const luaL_Reg graph_methods[] = {
  { "input", graph_input }, { "set", graph_set }, { "expand", graph_expand },
  { "compute", graph_compute }, { "start", graph_compute_begin }, { "poll", graph_compute_poll },
  { "read", graph_read }, { "reset", graph_reset },
  { "nodes", graph_nodes }, { "splits", graph_splits }, { "free", graph_free },
  /* ops */
  { "neg", op_neg }, { "abs", op_abs }, { "sgn", op_sgn }, { "step", op_step }, { "tanh", op_tanh },
  { "elu", op_elu }, { "relu", op_relu }, { "sigmoid", op_sigmoid }, { "gelu", op_gelu },
  { "gelu_erf", op_gelu_erf }, { "gelu_quick", op_gelu_quick }, { "silu", op_silu }, { "exp", op_exp },
  { "log", op_log }, { "sqr", op_sqr }, { "sqrt", op_sqrt }, { "sin", op_sin }, { "cos", op_cos },
  { "cont", op_cont }, { "transpose", op_transpose }, { "sum", op_sum }, { "sum_rows", op_sum_rows },
  { "mean", op_mean }, { "argmax", op_argmax }, { "soft_max", op_soft_max }, { "dup", op_dup },
  { "add", op_add }, { "sub", op_sub }, { "mul", op_mul }, { "div", op_div }, { "mul_mat", op_mul_mat },
  { "mul_mat_f32", op_mul_mat_f32 }, { "out_prod", op_out_prod }, { "get_rows", op_get_rows },
  { "cpy", op_cpy }, { "repeat", op_repeat }, { "swiglu_split", op_swiglu_split },
  { "geglu_split", op_geglu_split }, { "swiglu_swapped", op_swiglu_swapped },
  { "scale", op_scale }, { "scale_bias", op_scale_bias },
  { "clamp", op_clamp }, { "leaky_relu", op_leaky_relu }, { "norm", op_norm }, { "rms_norm", op_rms_norm },
  { "l2_norm", op_l2_norm }, { "group_norm", op_group_norm }, { "cast", op_cast }, { "concat", op_concat },
  { "set_rows", op_set_rows }, { "diag_mask_inf", op_diag_mask_inf }, { "top_k", op_top_k },
  { "arange", op_arange }, { "argsort", op_argsort }, { "soft_max_ext", op_soft_max_ext },
  { "rope_ext", op_rope_ext }, { "flash_attn_ext", op_flash_attn_ext }, { "conv_1d", op_conv_1d },
  { "conv_1d_dw", op_conv_1d_dw }, { "conv_transpose_1d", op_conv_transpose_1d }, { "im2col", op_im2col },
  { "pad", op_pad }, { "pad_ext", op_pad_ext }, { "pad_reflect_1d", op_pad_reflect_1d }, { "pool_1d", op_pool_1d }, { "interpolate", op_interpolate },
  { "reshape", op_reshape }, { "view", op_view }, { "permute", op_permute }, { "repeat_4d", op_repeat_4d },
  { "cont_nd", op_cont_nd }, { "fill", op_fill },
  { NULL, NULL }
};

static int set_gc(lua_State *L) { free_set((ml_set *)lua_touserdata(L, 1)); return 0; }
static int graph_gc(lua_State *L) { free_graph((ml_graph *)lua_touserdata(L, 1)); return 0; }

static void new_class(lua_State *L, const char *name, const luaL_Reg *methods, lua_CFunction gc, lua_CFunction tostring) {
  luaL_newmetatable(L, name);
  lua_newtable(L);
  luaL_setfuncs(L, methods, 0);
  lua_setfield(L, -2, "__index");
  if (gc) { lua_pushcfunction(L, gc); lua_setfield(L, -2, "__gc"); }
  if (tostring) { lua_pushcfunction(L, tostring); lua_setfield(L, -2, "__tostring"); }
  lua_pushstring(L, name);
  lua_setfield(L, -2, "__name");
  lua_pop(L, 1);
}

/* A collected engine leaves its backends be: a set or graph finalized after it (the order
 * is not promised at exit) may still reach them. engine:close() frees them. */
static int engine_gc(lua_State *L) { (void)L; return 0; }

static const luaL_Reg module_functions[] = {
  { "engine", l_engine }, { "devices", l_devices }, { "cpu_features", l_cpu_features },
  { NULL, NULL }
};

#if defined(_WIN32)
#  define ML_EXPORT __declspec(dllexport)
#else
#  define ML_EXPORT __attribute__((visibility("default")))
#endif

ML_EXPORT int luaopen_ml_core(lua_State *L) {
  log_from_env();
  ggml_log_set(ml_log, NULL);
  /* ggml makes its devices on first use; the handler goes after them, so it runs first. */
  static bool registered = false;
  (void)ggml_backend_dev_count();
  if (!registered) { atexit(ml_atexit); ggml_set_abort_callback(ml_on_abort); registered = true; }
  /* refs: weak keys, so a handle's entry goes with the handle. host: a loaded set's CPU
   * half, keyed by the set. */
  lua_newtable(L);
  lua_newtable(L);
  lua_pushstring(L, "k");
  lua_setfield(L, -2, "__mode");
  lua_setmetatable(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, "ml.refs");
  lua_newtable(L);
  lua_newtable(L);
  lua_pushstring(L, "k");
  lua_setfield(L, -2, "__mode");
  lua_setmetatable(L, -2);
  lua_setfield(L, LUA_REGISTRYINDEX, "ml.host");

  new_class(L, ML_ENGINE, engine_methods, engine_gc, NULL);
  new_class(L, ML_SET, set_methods, set_gc, NULL);
  new_class(L, ML_TENSOR, tensor_methods, NULL, tensor_tostring);
  new_class(L, ML_GRAPH, graph_methods, graph_gc, NULL);

  lua_newtable(L);
  luaL_setfuncs(L, module_functions, 0);
  ml_open_buffer(L);
  ml_open_io(L);
  ml_open_audio(L);
  ml_open_dsp(L);
  ml_open_tok(L);
  lua_pushstring(L, ML_GGML_COMMIT);
  lua_setfield(L, -2, "ggml");
  return 1;
}
