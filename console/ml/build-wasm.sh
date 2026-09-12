#!/bin/sh
# Builds the engine for WebAssembly: console/ml/lib/wasm/ml_lua.cjs (and ml_lua.wasm), a Lua 5.4
# interpreter with the engine linked in, on ggml's CPU backend with WebAssembly SIMD. One job.
#
#   source ~/emsdk/emsdk_env.sh; console/ml/build-wasm.sh
#   node console/ml/lib/wasm/ml_lua.cjs console/ml/smoke.lua
#
# ML_WASM_THREADS=8 builds lib/wasm/ml_lua_mt.cjs instead, with ggml's CPU backend on that
# many workers (a browser serves it cross-origin isolated). The microphone and the speaker
# are not in either build: node has no audio device.
set -eu
LUA=5.4.7
LUA_SHA=9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30
here=$(cd "$(dirname "$0")" && pwd)
command -v emcmake >/dev/null || { echo "no emcmake: source the Emscripten SDK (emsdk_env.sh) first" >&2; exit 1; }
[ -d "$here/ggml" ] || "$here/fetch-ggml.sh"
src="$here/build/lua-$LUA"
if [ ! -f "$src/src/lua.h" ]; then
  mkdir -p "$here/build"
  curl -sSfL -o "$src.tar.gz" "https://www.lua.org/ftp/lua-$LUA.tar.gz"
  got=$( (shasum -a 256 "$src.tar.gz" 2>/dev/null || sha256sum "$src.tar.gz") | cut -d' ' -f1)
  [ "$got" = "$LUA_SHA" ] || { rm -f "$src.tar.gz"; echo "lua-$LUA.tar.gz is $got, not the pinned $LUA_SHA" >&2; exit 1; }
  tar xzf "$src.tar.gz" -C "$here/build" && rm -f "$src.tar.gz"
fi
lock="$here/build/.lock"
until mkdir "$lock" 2>/dev/null; do echo "waiting: another build holds $lock" >&2; sleep 2; done
trap 'rmdir "$lock"' EXIT INT TERM
threads=${ML_WASM_THREADS:-0}
if [ "$threads" -gt 0 ]; then
  dir="$here/build/wasm-mt"; name=ml_lua_mt; flags="-pthread"
else
  dir="$here/build/wasm"; name=ml_lua; flags=""
fi
emcmake cmake -S "$here" -B "$dir" -DCMAKE_BUILD_TYPE=Release -DML_ABI=wasm \
  -DLUA_SOURCE_DIR="$src" -DLUA_INCLUDE_DIR="$src/src" -DML_AUDIO=OFF -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF -DML_WASM_THREADS="$threads" -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags" >/dev/null
cmake --build "$dir" -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
echo "built $here/lib/wasm/$name.cjs"
