-- The net port over curl: `fetch(req) -> res | nil, err`, the shape spec/provider.md §3
-- gives it. A host file, like bin/malleable.lua: it names `io` and `os` so nothing under
-- src/ has to.
--
-- Every request goes through a curl config file, never the command line, so a header --
-- the bearer credential above all -- is never visible in a process listing. The config
-- file and the request body are temporary files, removed before this returns.
--
-- Two ways to call it. `curl(req)` (or `curl.fetch(req)`) waits for the answer.
-- `curl.start(req)` starts curl in the background and answers a handle at once: `poll()`
-- answers false while curl runs, and true with `{ res, err }` when it has exited;
-- `cancel()` stops it. A run that must not block (spec/speech.md) yields the poll.

local port = require "port"

local function quoted(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- A value inside a curl config file: double-quoted, with backslash and quote escaped.
local function conf(s)
  return '"' .. tostring(s):gsub('[\\"]', "\\%0"):gsub("\n", "\\n") .. '"'
end

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return "" end
  local text = f:read("*a") or ""
  f:close()
  return text
end

local function spill(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

-- The last header block: a 100 Continue or a redirect writes one block each before it.
local function headers_of(raw)
  local block = ""
  for each in (raw .. "\r\n\r\n"):gmatch("(.-)\r?\n\r?\n") do
    if each:match("^HTTP/") then block = each end
  end
  local h = {}
  for line in block:gmatch("[^\r\n]+") do
    local name, value = line:match("^([^:]+):%s*(.-)%s*$")
    if name then h[name:lower()] = value end
  end
  return h
end

-- curl's exit codes, into port.md's closed set.
local CODES = {
  [28] = "timeout",            -- the operation timed out
  [63] = "too_big",            -- over --max-filesize
}

-- The request, written to a config file curl reads. Answers the temporary paths.
local function prepare(req, level)
  if type(req) ~= "table" then
    error("net.fetch takes a request table, got " .. type(req), level)
  end
  if type(req.url) ~= "string" or req.url == "" then
    error("net.fetch needs a non-empty url", level)
  end

  local p = { config = os.tmpname(), body_in = os.tmpname(), body_out = os.tmpname(),
              head_out = os.tmpname() }
  local lines = {
    "url = " .. conf(req.url),
    "request = " .. conf(req.method or "POST"),
    "max-time = " .. conf(tonumber(req.timeout) or 60),
    "max-filesize = " .. conf(16 * 1024 * 1024),
    "output = " .. conf(p.body_out),
    "dump-header = " .. conf(p.head_out),
  }
  for name, value in pairs(req.headers or {}) do
    lines[#lines + 1] = "header = " .. conf(name .. ": " .. value)
  end
  if req.body ~= nil then
    spill(p.body_in, req.body)
    lines[#lines + 1] = "data-binary = " .. conf("@" .. p.body_in)
  end
  spill(p.config, table.concat(lines, "\n") .. "\n")
  return p
end

local function clean(p)
  os.remove(p.config); os.remove(p.body_in); os.remove(p.body_out); os.remove(p.head_out)
  if p.said then os.remove(p.said) end
end

-- What curl said on stdout and stderr, ending in "<status> <exit>", into res | nil, err.
local function finish(said, p)
  local status, exit = said:match("(%d+) (%d+)%s*$")
  status, exit = tonumber(status), tonumber(exit)
  local complaint = (said:gsub("\n?%d+ %d+%s*$", "")):match("^%s*(.-)%s*$")

  if exit == nil then
    clean(p)
    return nil, port.error("net", "fetch", "unavailable",
      "curl answered with something that is not a status: " .. said:sub(1, 200))
  end
  if exit ~= 0 then
    clean(p)
    return nil, port.error("net", "fetch", CODES[exit] or "unavailable",
      "curl exited " .. exit .. (complaint ~= "" and (": " .. complaint) or ""))
  end

  local res = { status = status, headers = headers_of(slurp(p.head_out)), body = slurp(p.body_out) }
  clean(p)
  return res
end

local WRITE_OUT = " -w '\\n%{http_code} %{exitcode}'"

local function fetch(req)
  local p = prepare(req, 3)
  local pipe = io.popen("curl -sS -K " .. quoted(p.config) .. WRITE_OUT .. " 2>&1")
  if not pipe then
    clean(p)
    return nil, port.error("net", "fetch", "unavailable", "curl could not be started")
  end
  local said = pipe:read("*a") or ""
  pipe:close()
  return finish(said, p)
end

-- curl in the background, its stdout and stderr to a file. The write-out line is the last
-- thing curl writes, so a file ending in one is a curl that has exited.
local function start(req)
  local p = prepare(req, 3)
  p.said = os.tmpname()
  local pipe = io.popen("curl -sS -K " .. quoted(p.config) .. WRITE_OUT .. " > " .. quoted(p.said)
    .. " 2>&1 & echo $!")
  local pid = pipe and pipe:read("*l")
  if pipe then pipe:close() end
  pid = pid and pid:match("^%s*(%d+)%s*$")
  -- A curl that vanished without writing is not waited on for ever.
  local deadline = os.time() + (tonumber(req.timeout) or 60) + 15
  local done = false
  local handle = {}
  function handle.poll()
    if done then return true, { nil, port.error("net", "fetch", "unavailable", "polled after it ended") } end
    local said = slurp(p.said)
    if said:match("%d+ %d+%s*$") then
      done = true
      local res, err = finish(said, p)
      return true, { res, err }
    end
    if not pid or os.time() > deadline then
      done = true
      if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
      clean(p)
      return true, { nil, port.error("net", "fetch", pid and "timeout" or "unavailable",
        pid and "curl did not finish" or "curl could not be started") }
    end
    return false
  end
  function handle.cancel()
    if done then return end
    done = true
    if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
    clean(p)
  end
  return handle
end

return setmetatable({ fetch = fetch, start = start }, {
  __call = function (_, req) return fetch(req) end,
})
