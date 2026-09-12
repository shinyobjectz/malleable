#!/bin/sh
# Builds the engine for one interpreter ABI: console/ml/lib/<abi>/ml_core.so. One job.
#
#   console/ml/build.sh lua5.5            the Lua 5.5 headers from LUA_INCLUDE_DIR or Homebrew
#   console/ml/build.sh luajit
#   ML_CUDA=ON console/ml/build.sh lua5.4  with ggml's CUDA backend (nvcc on PATH)
#   ML_AUDIO=OFF console/ml/build.sh ...    without the microphone and speaker
#   ML_CMAKE_ARGS="-DCMAKE_CUDA_ARCHITECTURES=89" ...   anything more for cmake
set -eu
abi=${1:?"which interpreter: lua5.4, lua5.5 or luajit"}
here=$(cd "$(dirname "$0")" && pwd)
[ -d "$here/ggml" ] || "$here/fetch-ggml.sh"
[ "${ML_AUDIO:-ON}" = OFF ] || [ -f "$here/miniaudio/miniaudio.h" ] || "$here/fetch-miniaudio.sh"
if [ -z "${LUA_INCLUDE_DIR:-}" ]; then
  for d in /opt/homebrew/include /usr/local/include /usr/include; do
    case $abi in
      luajit) cand="$d/luajit-2.1" ;;
      *) cand="$d/$abi" ;;
    esac
    if [ -f "$cand/lua.h" ]; then LUA_INCLUDE_DIR=$cand; break; fi
  done
fi
: "${LUA_INCLUDE_DIR:?"no Lua headers found for $abi; set LUA_INCLUDE_DIR"}"
# One build at a time: two builds in one tree would race for the same objects.
lock="$here/build/.lock"
mkdir -p "$here/build"
until mkdir "$lock" 2>/dev/null; do
  echo "waiting: another build holds $lock" >&2; sleep 2
done
trap 'rmdir "$lock"' EXIT INT TERM
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
cmake -S "$here" -B "$here/build/$abi" -DCMAKE_BUILD_TYPE=Release -DLUA_INCLUDE_DIR="$LUA_INCLUDE_DIR" \
  -DML_ABI="$abi" -DML_CUDA="${ML_CUDA:-OFF}" -DML_AUDIO="${ML_AUDIO:-ON}" ${ML_CMAKE_ARGS:-} >/dev/null
cmake --build "$here/build/$abi" -j "$jobs"
echo "built $here/lib/$abi/ml_core.so"
