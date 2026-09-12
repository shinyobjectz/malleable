/*
 * wasm_main.c -- a Lua interpreter with the engine linked in, for WebAssembly, where a
 * native module cannot be loaded at run time (console/ml/build-wasm.sh).
 *
 *   node console/ml/lib/wasm/ml_lua.cjs script.lua args...
 *
 * `require "console.ml.engine"` finds the engine in package.preload; everything else is
 * the stock interpreter: the standard libraries, `arg`, and an error with its traceback.
 */
#include <stdio.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

int luaopen_ml_core(lua_State *L);

static int traceback(lua_State *L) {
  const char *msg = lua_tostring(L, 1);
  luaL_traceback(L, L, msg ? msg : "(an error that is not a string)", 1);
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: ml_lua script.lua [args...]\n");
    return 1;
  }
  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, luaopen_ml_core);
  lua_setfield(L, -2, "ml_core");
  lua_pop(L, 1);

  lua_createtable(L, argc, 1);                 /* arg[0] is the script, as lua.c has it */
  for (int i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i - 1);
  }
  lua_setglobal(L, "arg");

  lua_pushcfunction(L, traceback);
  int status = luaL_loadfile(L, argv[1]);
  if (status == LUA_OK) {
    for (int i = 2; i < argc; i++) lua_pushstring(L, argv[i]);
    status = lua_pcall(L, argc - 2, 0, 1);
  }
  if (status != LUA_OK) fprintf(stderr, "ml_lua: %s\n", lua_tostring(L, -1));
  lua_close(L);
  return status == LUA_OK ? 0 : 1;
}
