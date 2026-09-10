-- The net double: a scripted transport, so the provider is proved with no network.
--
-- It obeys the three rules `src/double.lua` states for every double in the tree --
-- deterministic, fresh, inspectable -- and answers nothing it was not taught. It lives
-- here rather than in `src/double.lua` only because the net port is new: when
-- `spec/port.md` adopts `net.fetch`, this constructor belongs there as `double.net`
-- and this file becomes a pointer.
--
--   local n = pdouble.net { { status = 200, body = "…" }, { fail = { code = "timeout" } } }
--   n.fetch(req) -> res | nil, err
--   n.sent       -- the requests actually attempted, in order, copied
--
-- A script entry is one of:
--
--   { status = 200, headers = { … }, body = "…" }   a response, whatever the status
--   { fail = { code = "timeout", message = "…" } }  the port returns nil, err
--   { raise = "…" }                                 the port raises
--   { raw = v }                                     returned verbatim, for the ugly cases
--   function (req) -> res | nil, err                the rare conditional script
--
-- Entries may instead be keyed by url, in `by_url`, when a test cares which endpoint
-- was asked rather than in what order.

local port = require "port"

local pdouble = {}

local function copy(t)
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then out[k] = copy(v) else out[k] = v end
  end
  return out
end

function pdouble.net(cfg)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then
    error("double.net takes a table, got " .. type(cfg), 2)
  end
  if cfg.responses == nil and cfg.by_url == nil and #cfg > 0 then
    cfg = { responses = cfg }
  end

  local after = cfg.after or "error"
  if after ~= "error" and after ~= "repeat" then
    error('double.net: `after` is "error" or "repeat", got ' .. tostring(cfg.after), 2)
  end

  local n = { sent = {}, responses = cfg.responses or {}, by_url = cfg.by_url, after = after }
  local at = 0

  local function fail(code, message)
    return nil, port.error("net", "fetch", code, message)
  end

  local function answer(entry, req)
    if type(entry) == "function" then return entry(req) end
    if type(entry) ~= "table" then
      return fail("malformed", "the script entry is a " .. type(entry) .. ", not a response")
    end
    if entry.raise ~= nil then error(entry.raise, 0) end
    if entry.raw ~= nil then return entry.raw end
    if entry.fail ~= nil then
      return fail(entry.fail.code or "unavailable", entry.fail.message)
    end
    local headers = {}
    for k, v in pairs(entry.headers or {}) do headers[tostring(k):lower()] = v end
    return { status = entry.status or 200, headers = headers, body = entry.body or "" }
  end

  function n.fetch(req)
    -- A wrong shape raises, exactly as the six ports do.
    if type(req) ~= "table" then
      error("net.fetch: `req` is a table, got " .. type(req), 2)
    end
    if type(req.url) ~= "string" or req.url == "" then
      error("net.fetch: `req.url` is a non-empty string, got " .. tostring(req.url), 2)
    end
    n.sent[#n.sent + 1] = copy(req)

    if n.by_url then
      local entry = n.by_url[req.url]
      if entry == nil then
        return fail("unscripted", "no response is scripted for " .. req.url)
      end
      return answer(entry, req)
    end

    at = at + 1
    local entry = n.responses[at]
    if entry == nil then
      if n.after == "repeat" and #n.responses > 0 then
        entry = n.responses[#n.responses]
      else
        return fail("unscripted", string.format("the script has %d responses and this is request %d",
          #n.responses, at))
      end
    end
    return answer(entry, req)
  end

  return n
end

return pdouble
