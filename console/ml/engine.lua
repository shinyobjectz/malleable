-- engine — the console's ML engine, from Lua (spec/ml.md).
--
--     local ml = require "console.ml.engine"
--     local e  = ml.engine { device = "auto" }     -- the GPU if there is one, and the CPU
--     local w  = e:load "console/ml/models/silero-vad.gguf"
--     local g  = e:graph()
--     local x  = g:input("f32", 512)
--     g:set(x, ml.buffer(512))
--     local y  = g:sigmoid(g:mul_mat(w:get "head.weight", x))
--     g:compute(y)                 -- or g:start(y); while not g:poll() do end
--     print(g:read(y)[1])
--
-- The native module is built once per interpreter (console/ml/build.sh), into
-- console/ml/lib/<abi>/ml_core.so; this file loads the one for the interpreter it runs
-- under. In WebAssembly the interpreter has the module linked in (console/ml/build-wasm.sh). Everything the module has is on the table this file answers, as it is.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."

local function abi()
  if type(jit) == "table" then return "luajit" end
  return "lua" .. (_VERSION:match("%d+%.%d+") or "5.4")
end

local ABI = abi()
local dir = here .. "/lib/" .. ABI

local function load_core()
  -- WebAssembly has no loadable modules: its interpreter links the engine in (build-wasm.sh)
  if package.preload.ml_core then return package.preload.ml_core("ml_core") end
  local ext = package.cpath:match("%.dll") and "dll" or "so"
  local path = dir .. "/ml_core." .. ext
  local open, why = package.loadlib(path, "luaopen_ml_core")
  if not open then
    error("console.ml: the engine is not built for " .. ABI .. " (" .. tostring(why)
      .. "); run console/ml/build.sh " .. ABI, 3)
  end
  return open()
end

local core = load_core()
core.abi = ABI
core.root = here

-- A graph's compute is a host wait when the caller is a coroutine: start prepares, poll
-- runs the remaining work, and voice.update (or speech) resumes once a frame.
local ok_wait, wait = pcall(require, "wait")
local unpack = table.unpack or unpack

-- Inside a coroutine that can yield, and not the main thread. LÖVE resumes its main thread
-- as if it were a coroutine, so there it can yield too; a host wait yielded there goes back
-- to LÖVE, which does not answer it, and the graph is read before it is computed.
local function in_coroutine()
  if not (coroutine.isyieldable and coroutine.isyieldable()) then return false end
  local co, main = coroutine.running()
  return co ~= nil and not main
end

local function wrap_graph(g)
  local native_start, native_poll, native_compute = g.start, g.poll, g.compute
  local has_native = type(native_start) == "function" and type(native_poll) == "function"
  local outs

  local function start(_, ...)
    if has_native then return native_start(g, ...) end
    outs = { n = select("#", ...), ... }
  end

  local function poll()
    if has_native then return native_poll(g) end
    native_compute(g, unpack(outs, 1, outs.n))
    return true
  end

  local function compute(_, ...)
    if ok_wait and in_coroutine() then
      start(nil, ...)
      coroutine.yield(wait.host(function () return poll() end))
      return
    end
    return native_compute(g, ...)
  end

  local proxy = {
    start = start,
    poll = poll,
    compute = compute,
    job = function (_, ...)
      start(nil, ...)
      if not ok_wait then return { wait = "host", poll = poll } end
      return wait.host(function () return poll() end)
    end,
  }
  return setmetatable(proxy, {
    __index = function (_, k)
      local v = g[k]
      if type(v) == "function" then
        return function (_, ...) return v(g, ...) end
      end
      return v
    end,
  })
end

local make = core.engine
function core.engine(opts)
  local e = make(opts)
  return setmetatable({
    graph = function (_, ...) return wrap_graph(e:graph(...)) end,
  }, {
    __index = function (_, k)
      local v = e[k]
      if type(v) == "function" then
        return function (_, ...) return v(e, ...) end
      end
      return v
    end,
  })
end

return core
