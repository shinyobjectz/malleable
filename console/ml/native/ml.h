/*
 * ml.h -- the console's ML engine, shared between the native files (spec/ml.md).
 *
 * The engine is ggml, compiled in. Lua sees five kinds of object:
 *
 *   engine   the devices a graph runs on: a GPU when there is one, and the CPU always
 *   set      tensors that outlive a graph: a model's weights, a run's state (KV caches,
 *            recurrent state, convolution buffers), each set in one backend buffer
 *   graph    one computation: tensors built by ops, then computed on the engine
 *   tensor   a handle on a tensor in a set or a graph; a stale handle raises, never crashes
 *   buffer   a plain array of floats or ints on the host, for data in and out
 *
 * Nothing here runs a model. The models are Lua (console/ml/<model>.lua), built from these ops.
 * Builds against Lua 5.1 (LuaJIT), 5.4 and 5.5.
 */
#ifndef ML_H
#define ML_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "lua.h"
#include "lauxlib.h"

#include "ggml.h"
#include "ggml-backend.h"

struct gguf_context;

/* ------------------------------------------------------------------ compat */

#if LUA_VERSION_NUM < 502
#  define ml_rawlen(L, i)      lua_objlen((L), (i))
#  define ml_absindex(L, i)    (((i) > 0 || (i) <= LUA_REGISTRYINDEX) ? (i) : lua_gettop(L) + (i) + 1)
#else
#  define ml_rawlen(L, i)      lua_rawlen((L), (i))
#  define ml_absindex(L, i)    lua_absindex((L), (i))
#endif

/* An integer argument, whether the interpreter has integers or only doubles. */
int64_t ml_checkint(lua_State *L, int i);
int64_t ml_optint(lua_State *L, int i, int64_t d);

/* ------------------------------------------------------------------ objects */

#define ML_ENGINE "ml.engine"
#define ML_SET    "ml.set"
#define ML_GRAPH  "ml.graph"
#define ML_TENSOR "ml.tensor"
#define ML_BUFFER "ml.buffer"

#define ML_MAX_BACKENDS 4

typedef struct ml_engine {
  ggml_backend_t backends[ML_MAX_BACKENDS];   /* the GPU first when there is one; the CPU last */
  ggml_backend_buffer_type_t bufts[ML_MAX_BACKENDS];
  int n_backends;
  ggml_backend_t cpu;
  int threads;
  bool closed;
} ml_engine;

/* Whatever owns tensors: a set or a graph. A tensor handle holds the owner and the
 * generation it was made in; a graph that is reset or freed moves on a generation, so an
 * old handle is refused with a message instead of reading freed memory. */
typedef struct ml_owner {
  uint32_t gen;
  bool alive;
  struct ml_owner *prev, *next;   /* every live set and graph, freed at exit if still alive */
  int kind;                       /* 1 set, 2 graph */
} ml_owner;

typedef struct ml_set {
  ml_owner owner;
  ml_engine *engine;            /* the engine this set's buffer is on (kept alive by a ref) */
  struct ggml_context *ctx;     /* tensor metadata; no data */
  ggml_backend_buffer_t buffer; /* the data, on the engine's first device */
  struct gguf_context *gguf;    /* the file it came from, for its metadata, or NULL */
  bool allocated;
} ml_set;

/* Data waiting for a graph's input tensor until the graph is allocated. */
typedef struct ml_pending {
  struct ggml_tensor *t;
  void *data;
  size_t size;
} ml_pending;

typedef struct ml_graph {
  ml_owner owner;
  ml_engine *engine;
  struct ggml_context *ctx;     /* node metadata for this graph, no data */
  size_t max_nodes;
  ggml_backend_sched_t sched;
  struct ggml_cgraph *cgraph;   /* nodes in the order they were expanded, then the outputs */
  ml_pending *pending;
  int n_pending, cap_pending;
  bool computed;
  bool prepared;                /* start() has built the graph; poll() still owes compute */
  uint64_t outputs;             /* which nodes the last plan kept as outputs (a hash) */
} ml_graph;

typedef struct ml_tensor {
  struct ggml_tensor *t;
  ml_owner *owner;
  uint32_t gen;
} ml_tensor;

typedef enum { ML_F32 = 0, ML_I32 = 1 } ml_btype;

typedef struct ml_buffer {
  ml_btype type;
  size_t n;
  union { float *f; int32_t *i; void *p; } data;
} ml_buffer;

/* ------------------------------------------------------------------ shared helpers */

struct ggml_tensor *ml_checktensor(lua_State *L, int i);
void ml_pushtensor(lua_State *L, struct ggml_tensor *t, ml_owner *owner, int owner_index);
ml_buffer *ml_checkbuffer(lua_State *L, int i);
ml_buffer *ml_newbuffer(lua_State *L, ml_btype type, size_t n);
enum ggml_type ml_checktype(lua_State *L, int i);
enum ggml_type ml_opttype(lua_State *L, int i, enum ggml_type d);

/* Registers the functions of each file on the module table at the top of the stack. */
void ml_open_buffer(lua_State *L);
void ml_open_io(lua_State *L);
void ml_open_audio(lua_State *L);
void ml_open_dsp(lua_State *L);
void ml_open_tok(lua_State *L);
int ml_tokenizer_from_gguf(lua_State *L, struct gguf_context *g);

#endif
