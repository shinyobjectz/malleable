# The console's ML engine: ggml compiled in, and the Lua module over it (spec/ml.md).
#
#   cmake -S console/ml -B console/ml/build/lua5.5 -DLUA_INCLUDE_DIR=/opt/homebrew/include/lua5.5 -DML_ABI=lua5.5
#   cmake --build console/ml/build/lua5.5 -j
#
# writes console/ml/lib/<ML_ABI>/ml_core.so, which console/ml/engine.lua loads for the
# interpreter it runs under. One build per interpreter ABI: lua5.4, lua5.5, luajit.
cmake_minimum_required(VERSION 3.18)
project(ml C CXX)

set(LUA_INCLUDE_DIR "" CACHE PATH "the headers of the Lua the module is built for")
set(ML_ABI "lua" CACHE STRING "the interpreter ABI: lua5.4, lua5.5, luajit")
option(ML_CUDA "build ggml's CUDA backend" OFF)
option(ML_AUDIO "build the microphone and speaker (miniaudio, console/ml/fetch-miniaudio.sh)" ON)

if(NOT LUA_INCLUDE_DIR)
  message(FATAL_ERROR "set LUA_INCLUDE_DIR to the Lua headers (lua.h)")
endif()

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
if(APPLE)
  set(GGML_METAL ON CACHE BOOL "" FORCE)
  set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
endif()
if(ML_CUDA)
  set(GGML_CUDA ON CACHE BOOL "" FORCE)
endif()
add_subdirectory(ggml)

execute_process(COMMAND git -C ${CMAKE_CURRENT_SOURCE_DIR}/ggml rev-parse --short HEAD
                OUTPUT_VARIABLE ML_GGML_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)

set(ML_SOURCES native/core.c native/buffer.c native/io.c native/audio.c native/dsp.c native/tok.c)
if(EMSCRIPTEN)
  # WebAssembly loads no module at run time: one interpreter, Lua and the engine linked
  # together, run by node with the host's files (console/ml/build-wasm.sh).
  set(LUA_SOURCE_DIR "" CACHE PATH "the Lua source tree the WebAssembly interpreter is built from")
  file(GLOB LUA_SOURCES ${LUA_SOURCE_DIR}/src/*.c)
  list(FILTER LUA_SOURCES EXCLUDE REGEX "/(lua|luac)\\.c$")
  add_executable(ml_core ${ML_SOURCES} native/wasm_main.c ${LUA_SOURCES})
  set(ML_WASM_THREADS 0 CACHE STRING "worker threads for ggml's CPU backend in WebAssembly (0: one thread, no workers)")
  target_link_options(ml_core PRIVATE -sNODERAWFS=1 -sALLOW_MEMORY_GROWTH=1 -sMAXIMUM_MEMORY=4GB
                      -sSTACK_SIZE=8MB -sEXIT_RUNTIME=1 -sENVIRONMENT=node)
  set(ML_WASM_NAME ml_lua)
  if(ML_WASM_THREADS GREATER 0)
    # every object, ggml's too, is compiled with -pthread (build-wasm.sh sets the flags)
    target_link_options(ml_core PRIVATE -pthread -sPTHREAD_POOL_SIZE=${ML_WASM_THREADS})
    set(ML_WASM_NAME ml_lua_mt)
  endif()
  set_target_properties(ml_core PROPERTIES OUTPUT_NAME ${ML_WASM_NAME} SUFFIX ".cjs"
                        RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/lib/${ML_ABI})
else()
  add_library(ml_core MODULE ${ML_SOURCES})
endif()
target_include_directories(ml_core PRIVATE ${LUA_INCLUDE_DIR} native)
target_link_libraries(ml_core PRIVATE ggml)
target_compile_definitions(ml_core PRIVATE ML_GGML_COMMIT="${ML_GGML_COMMIT}")
if(ML_AUDIO)
  if(NOT EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/miniaudio/miniaudio.h)
    message(FATAL_ERROR "no miniaudio: run console/ml/fetch-miniaudio.sh, or build with ML_AUDIO=OFF")
  endif()
  target_compile_definitions(ml_core PRIVATE ML_AUDIO)
  target_include_directories(ml_core PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/miniaudio)
  if(APPLE)
    target_link_libraries(ml_core PRIVATE "-framework CoreFoundation" "-framework CoreAudio" "-framework AudioToolbox")
  elseif(UNIX AND NOT EMSCRIPTEN)
    target_link_libraries(ml_core PRIVATE dl pthread m)   # miniaudio opens ALSA or PulseAudio at run time
  endif()
endif()
set_target_properties(ml_core PROPERTIES C_STANDARD 11)
if(NOT EMSCRIPTEN)
  set_target_properties(ml_core PROPERTIES PREFIX "" SUFFIX ".so" OUTPUT_NAME ml_core
                        LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/lib/${ML_ABI})
endif()
if(APPLE)
  target_link_options(ml_core PRIVATE -undefined dynamic_lookup)
endif()
