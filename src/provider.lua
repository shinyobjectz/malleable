-- provider -- model providers and adapters.
--
-- `spec/port.md` defines a model port, `p.model.call(request) -> reply | nil, err`,
-- and supplies a scripted double for it. This is the other implementation of that same
-- port: the one that turns the harness's vendor-neutral request into what a real model
-- API expects, sends it, and turns the answer back into the port's reply shape. It
-- knows about wire formats, tool schema serialisation, HTTP statuses and retry, and
-- that is the whole reason it exists -- so that nothing above it has to.
--
-- It still opens no socket. The transport arrives as a port function, so every
-- behaviour here, timeouts and rate limits included, is proved in a test with no
-- network, no disk and no subprocess.
--
-- Three results, and keeping them apart is the point of the file:
--
--   a reply    the API answered and the model produced something -> reply, nil
--   a refusal  the model declined -- a REPLY, stop = "refused", never retried
--   a failure  no reply was produced                             -> nil, err
--
-- And port.md's one convention, unchanged: a wrong shape RAISES, a wrong world
-- RETURNS. A number where a message list belongs stops the program; an empty
-- transcript, an unknown scheme, a 503 or a model that emitted broken JSON comes back
-- as a value the caller reads.
--
-- What it must not do, from `spec/provider.md` §10: it names nothing in the `os` or
-- `io` libraries, takes no random number, opens no socket, writes no global, reads no
-- environment variable for a credential, mutates no `request`, prints nothing, falls
-- back to no second model, streams nothing and caches nothing -- and it never decides
-- what a failure means for the run. A test reads this file for those names. It
-- requires `src/port.lua` and its own submodules, and nothing else in the tree.

local port = require "port"

local function submodule(name)
  local ok, m = pcall(require, "provider." .. name)
  if ok then return m end
  return require("src.provider." .. name)
end

local json = submodule("json")
local openai_chat = submodule("openai_chat")

local provider = {}

provider.json = json

-- ------------------------------------------------------------------------ small tools

local function copy(t)
  local out = {}
  for k, v in pairs(t) do
    if type(v) == "table" then out[k] = copy(v) else out[k] = v end
  end
  return out
end

local function raise(fmt, ...)
  error("provider: " .. string.format(fmt, ...), 3)
end

local function nonempty(v)
  if type(v) == "string" and v ~= "" then return v end
  return nil
end

-- ------------------------------------------------------------------------ model ids

-- `"openrouter:inception/mercury-2.5"` is a scheme and a name, split on the FIRST
-- colon. A bare `"gpt-4o"` is not a model id here: the scheme is how an adapter is
-- chosen, and guessing a default vendor from a bare name is how a key ends up at the
-- wrong host.
function provider.parse_model(id)
  if type(id) ~= "string" then
    raise("parse_model takes a model id as a string, got %s", type(id))
  end
  local at = id:find(":", 1, true)
  if not at then
    return nil, string.format("%q names no provider: a model id reads \"<scheme>:<name>\", like \"openrouter:inception/mercury-2.5\"", id)
  end
  local scheme = id:sub(1, at - 1)
  local name = id:sub(at + 1)
  if scheme == "" then
    return nil, string.format("%q has no scheme before its colon", id)
  end
  if name == "" then
    return nil, string.format("%q has no model name after its colon", id)
  end
  return scheme, name
end

-- ------------------------------------------------------------------------- adapters

local adapters = {}

local required_fns = { "url", "headers", "body", "read" }

-- Registration runs nothing: the functions are stored and never called, which is the
-- discipline DESIGN.md's rule 2 gives a declaration file, applied one layer down.
function provider.adapter(name, impl)
  if type(name) ~= "string" or name == "" then
    raise("adapter takes a scheme name as a non-empty string, got %s", type(name))
  end
  if type(impl) ~= "table" then
    raise("adapter %q takes a table of functions, got %s", name, type(impl))
  end
  for i = 1, #required_fns do
    local fn = required_fns[i]
    if type(impl[fn]) ~= "function" then
      raise("adapter %q needs `%s` to be a function, got %s", name, fn, type(impl[fn]))
    end
  end
  if impl.retry_after ~= nil and type(impl.retry_after) ~= "function" then
    raise("adapter %q: `retry_after` is a function or nil, got %s", name, type(impl.retry_after))
  end
  if adapters[name] then
    -- Silent replacement is how one test leaks into the next.
    raise("the adapter %q is already registered", name)
  end
  adapters[name] = impl
  return impl
end

function provider.adapters()
  local out = {}
  for name in pairs(adapters) do out[#out + 1] = name end
  table.sort(out)
  return out
end

local function adapter_list()
  return table.concat(provider.adapters(), ", ")
end

provider.adapter("openai", openai_chat.new("https://api.openai.com/v1"))
provider.adapter("openrouter", openai_chat.new("https://openrouter.ai/api/v1"))

-- ---------------------------------------------------------------------- the config

local retry_defaults = { attempts = 3, base = 0.5, factor = 2, cap = 8, jitter = false }

-- The four words a reply may stop on. An adapter that answers with anything else has
-- not produced a reply, and §8's rule 3 says that is a failure with the adapter named.
local stop_words = { done = true, calls = true, cut = true, refused = true }

local reserved_headers = { authorization = true, ["content-type"] = true }
local reserved_params  = { model = true, messages = true, tools = true }

local function number_field(where, t, key, default, least)
  local v = t[key]
  if v == nil then return default end
  if type(v) ~= "number" or v ~= v or v < least then
    raise("%s.%s is a number of at least %s, got %s", where, key, tostring(least), tostring(v))
  end
  return v
end

local function read_retry(cfg)
  local r = cfg.retry
  if r == nil then return copy(retry_defaults) end
  if type(r) ~= "table" then raise("cfg.retry is a table, got %s", type(r)) end
  local out = {
    attempts = number_field("cfg.retry", r, "attempts", retry_defaults.attempts, 1),
    base     = number_field("cfg.retry", r, "base",     retry_defaults.base,     0),
    factor   = number_field("cfg.retry", r, "factor",   retry_defaults.factor,   1),
    cap      = number_field("cfg.retry", r, "cap",      retry_defaults.cap,      0),
    jitter   = false,
  }
  if out.attempts ~= math.floor(out.attempts) then
    raise("cfg.retry.attempts is a whole number of attempts, got %s", tostring(r.attempts))
  end
  if r.jitter ~= nil then
    if type(r.jitter) ~= "boolean" then raise("cfg.retry.jitter is true or false, got %s", type(r.jitter)) end
    out.jitter = r.jitter
  end
  return out
end

-- One scheme's settings, resolved and checked while the host is still starting up. A
-- config that cannot be honoured fails here, not on the first call.
local function read_scheme(name, given, impl)
  local sc = {}
  given = given or {}
  if type(given) ~= "table" then
    raise("cfg.schemes.%s is a table, got %s", name, type(given))
  end

  if given.base_url ~= nil and type(given.base_url) ~= "string" then
    raise("cfg.schemes.%s.base_url is a string, got %s", name, type(given.base_url))
  end
  sc.base_url = given.base_url or (impl and impl.default_base) or ""
  while sc.base_url:sub(-1) == "/" do sc.base_url = sc.base_url:sub(1, -2) end

  if given.path ~= nil and type(given.path) ~= "string" then
    raise("cfg.schemes.%s.path is a string, got %s", name, type(given.path))
  end
  sc.path = given.path or "/chat/completions"

  if given.key ~= nil and type(given.key) ~= "string" then
    raise("cfg.schemes.%s.key is a string or nil, got %s", name, type(given.key))
  end
  -- nil means no authorization header at all, which is what a local endpoint wants.
  sc.key = nonempty(given.key)

  sc.headers = {}
  if given.headers ~= nil then
    if type(given.headers) ~= "table" then
      raise("cfg.schemes.%s.headers is a table of name = value, got %s", name, type(given.headers))
    end
    for k, v in pairs(given.headers) do
      if type(k) ~= "string" then raise("cfg.schemes.%s.headers has a non-string name", name) end
      local low = k:lower()
      if reserved_headers[low] then
        raise("cfg.schemes.%s.headers may not set %s: the adapter owns it", name, low)
      end
      if type(v) ~= "string" and type(v) ~= "number" then
        raise("cfg.schemes.%s.headers.%s is a string, got %s", name, k, type(v))
      end
      sc.headers[low] = tostring(v)
    end
  end

  sc.params = {}
  if given.params ~= nil then
    if type(given.params) ~= "table" then
      raise("cfg.schemes.%s.params is a table of body fields, got %s", name, type(given.params))
    end
    for k, v in pairs(given.params) do
      if type(k) ~= "string" then raise("cfg.schemes.%s.params has a non-string name", name) end
      if reserved_params[k] then
        raise("cfg.schemes.%s.params may not set %s: the request owns it", name, k)
      end
      sc.params[k] = v
    end
  end

  sc.adapter = given.adapter or name
  if type(sc.adapter) ~= "string" or sc.adapter == "" then
    raise("cfg.schemes.%s.adapter names a registered adapter, got %s", name, tostring(given.adapter))
  end

  return sc
end

-- ------------------------------------------------------------------------- secrets

-- A comparison against the configured secret, not a search for anything that looks
-- like one. If the API echoed the key into an error body, the body is withheld.
local function secrets_of(schemes)
  local out = {}
  for _, sc in pairs(schemes) do
    if sc.key then
      out[#out + 1] = sc.key
      out[#out + 1] = "Bearer " .. sc.key
    end
  end
  return out
end

local function carries_secret(s, secrets)
  if type(s) ~= "string" then return false end
  for i = 1, #secrets do
    if secrets[i] ~= "" and s:find(secrets[i], 1, true) then return true end
  end
  return false
end

local function scrub_message(s, secrets)
  if not carries_secret(s, secrets) then return s end
  local out = s
  for i = 1, #secrets do
    if secrets[i] ~= "" then
      out = out:gsub(secrets[i]:gsub("%W", "%%%0"), "(the credential, withheld)")
    end
  end
  return out
end

local function scrub_body(s, secrets)
  if s == nil then return nil end
  if carries_secret(s, secrets) then
    return "(the response body is withheld: it repeated the credential)"
  end
  return s
end

-- --------------------------------------------------------------------- the model port

local function fail_shape(where, what, ...)
  error(where .. ": " .. string.format(what, ...), 3)
end

function provider.model(cfg, p)
  if cfg == nil then cfg = {} end
  if type(cfg) ~= "table" then
    fail_shape("provider.model", "`cfg` is a table or nil, got %s", type(cfg))
  end
  if type(p) ~= "table" then
    fail_shape("provider.model", "`p` is a port table, got %s", type(p))
  end
  -- A model port with no transport is a wiring bug, not a condition the network can
  -- produce, so it raises rather than returning.
  if type(p.net) ~= "table" or type(p.net.fetch) ~= "function" then
    fail_shape("provider.model", "`p.net.fetch` must be a function: a model port needs a transport")
  end
  if type(p.json) ~= "table" or type(p.json.encode) ~= "function" or type(p.json.decode) ~= "function" then
    fail_shape("provider.model", "`p.json.encode` and `p.json.decode` must be functions")
  end

  local timeout  = number_field("cfg", cfg, "timeout", 60, 0)
  local deadline = cfg.deadline
  if deadline ~= nil and (type(deadline) ~= "number" or deadline <= 0) then
    fail_shape("provider.model", "`cfg.deadline` is a positive number of seconds or nil, got %s", tostring(deadline))
  end
  local retry = read_retry(cfg)

  if cfg.schemes ~= nil and type(cfg.schemes) ~= "table" then
    fail_shape("provider.model", "`cfg.schemes` is a table keyed by scheme name, got %s", type(cfg.schemes))
  end

  local schemes = {}
  local names = {}
  for name in pairs(cfg.schemes or {}) do names[#names + 1] = name end
  table.sort(names)
  for i = 1, #names do
    local name = names[i]
    local given = cfg.schemes[name]
    local want = (type(given) == "table" and given.adapter) or name
    local impl = adapters[want]
    if impl == nil then
      -- A config typo must be reportable at start-up, not fatal.
      return nil, port.error("model", "call", "unavailable", string.format(
        "no adapter is registered for %q; the registered ones are %s", tostring(want), adapter_list()))
    end
    schemes[name] = read_scheme(name, given, impl)
  end

  local secrets = secrets_of(schemes)

  -- The two pure functions an adapter is given. They unwrap the port's error table
  -- into a sentence, and a port that raises becomes a returned message rather than a
  -- crash: rule 3 of §8, applied at the one place every adapter reaches the world.
  local io_encode = function (v)
    local ok, a, b = pcall(p.json.encode, v)
    if not ok then return nil, "the json port raised while encoding" end
    if a == nil then
      return nil, (type(b) == "table" and b.message) or "the value could not be encoded"
    end
    return a
  end

  local io_decode = function (s)
    local ok, a, b = pcall(p.json.decode, s)
    if not ok then return nil, "the json port raised while decoding" end
    if a == nil then
      return nil, (type(b) == "table" and b.message) or "the text could not be decoded"
    end
    return a
  end

  local io_pair = { encode = io_encode, decode = io_decode }

  local function log(event, fields)
    if type(p.log) ~= "table" or type(p.log.write) ~= "function" then return end
    pcall(p.log.write, "info", event, fields)
  end

  local m = {}

  -- A fresh copy, so a caller can read what this port was built with and two ports
  -- built from two configs share nothing at all.
  m.settings = copy({ timeout = timeout, deadline = deadline, retry = retry, schemes = schemes })

  local function err(code, message, extra)
    extra = extra or {}
    local e = port.error("model", "call", code, scrub_message(message, secrets))
    e.status = extra.status
    e.attempts = extra.attempts or 0
    e.history = extra.history or {}
    e.body = scrub_body(extra.body, secrets)
    return nil, e
  end

  -- What is left of the whole-call deadline, in seconds. nil when there is no deadline
  -- or no monotonic clock to measure one against.
  local function remaining(started)
    if deadline == nil or started == nil then return nil end
    local ok, now = pcall(p.clock.mono)
    if not ok or type(now) ~= "number" then return nil end
    return deadline - (now - started)
  end

  function m.call(request)
    -- port.md's sentence, unchanged: a wrong shape raises.
    port.shape.request("model.call", request)

    local scheme, name = provider.parse_model(request.model)
    if scheme == nil then
      return err("malformed", name)
    end

    local sc = schemes[scheme]
    if sc == nil then
      local impl_name = scheme
      if adapters[impl_name] == nil then
        return err("unavailable", string.format(
          "no adapter is registered for the scheme %q; the registered ones are %s", scheme, adapter_list()))
      end
      -- A scheme the config never mentioned but an adapter knows: its own defaults,
      -- and no credential, which is what a local endpoint wants.
      sc = read_scheme(scheme, nil, adapters[impl_name])
    end

    local impl = adapters[sc.adapter]
    if impl == nil then
      return err("unavailable", string.format(
        "no adapter is registered for %q; the registered ones are %s", sc.adapter, adapter_list()))
    end

    -- The transcript, checked before anything is sent. Nothing here is a raise: port.md
    -- permits an empty transcript at the port surface, and a role the harness wrote
    -- wrongly is a condition a caller should be able to read and report.
    local messages = request.messages
    for i = 1, #messages do
      local msg = messages[i]
      if type(msg) ~= "table" then
        return err("malformed", string.format("message %d is a %s, not a message", i, type(msg)))
      end
      if msg.role ~= "user" and msg.role ~= "agent" and msg.role ~= "tool" then
        return err("malformed", string.format(
          "message %d has the role %q, and the three roles are user, agent and tool", i, tostring(msg.role)))
      end
      if msg.text ~= nil and type(msg.text) ~= "string" then
        return err("malformed", string.format("message %d carries a `text` that is not a string", i))
      end
      if msg.role == "tool" and nonempty(msg.id) == nil then
        return err("malformed", string.format(
          "message %d is a tool result with no id, and a tool result is addressed by id", i))
      end
    end

    if #messages == 0 and nonempty(request.system) == nil then
      -- There is no request to make, and inventing one would put a fabricated message
      -- in a real conversation.
      return err("malformed", "there was nothing to send: the transcript is empty and there is no system prompt")
    end

    local ctx = { io = io_pair, model = name, cfg = sc }

    local ok, url = pcall(impl.url, sc)
    if not ok or type(url) ~= "string" or url == "" then
      return err("unavailable", string.format("the %s adapter produced no url to send to", sc.adapter))
    end
    ctx.url = url

    local headers
    ok, headers = pcall(impl.headers, sc)
    if not ok or type(headers) ~= "table" then
      return err("unavailable", string.format("the %s adapter produced no headers", sc.adapter))
    end
    local sent_headers = {}
    for k, v in pairs(headers) do sent_headers[tostring(k):lower()] = v end
    for k, v in pairs(sc.headers) do sent_headers[k] = v end

    local body, why
    ok, body, why = pcall(impl.body, request, name, sc, ctx)
    if not ok then
      return err("unavailable", string.format("the %s adapter raised while building the request", sc.adapter))
    end
    if body == nil then
      -- The adapter refused the request rather than raising over it. Name it: a host
      -- that registered its own has to be able to tell whose sentence this is.
      return err("malformed", string.format("the %s adapter could not build the request: %s",
        sc.adapter, tostring(why or "it gave no reason")))
    end

    local payload, encode_why = io_encode(body)
    if payload == nil then
      return err("malformed", "the request body could not be encoded: " .. tostring(encode_why))
    end

    local started = nil
    if deadline ~= nil and type(p.clock) == "table" and type(p.clock.mono) == "function" then
      local got, now = pcall(p.clock.mono)
      if got and type(now) == "number" then started = now end
    end

    local history = {}
    local attempts = 0
    local last = nil   -- { code, message, status, body, retryable }

    local function answer()
      return err(last.code, last.message, {
        status = last.status, attempts = attempts, history = history, body = last.body,
      })
    end

    while true do
      local left = remaining(started)
      if left ~= nil and left <= 0 then
        if last == nil then
          return err("timeout", string.format(
            "the %g second deadline for the whole call had already passed before an attempt was made", deadline),
            { attempts = attempts, history = history })
        end
        last.code, last.message = "timeout", string.format(
          "the %g second deadline for the whole call passed after %d attempt(s); the last failure was: %s",
          deadline, attempts, last.message)
        return answer()
      end

      local req = {
        method = "POST",
        url = url,
        headers = sent_headers,
        body = payload,
        timeout = request.timeout or timeout,
      }
      if left ~= nil and left < req.timeout then req.timeout = left end

      attempts = attempts + 1
      local entry = { code = nil, status = nil, delay = nil }
      history[#history + 1] = entry

      local got, res, ferr = pcall(p.net.fetch, req)

      if not got then
        -- A broken port is a failure, not a crash.
        last = { code = "unavailable", message = "the transport raised instead of answering", retryable = true }
      elseif res == nil then
        local code = (type(ferr) == "table" and type(ferr.code) == "string") and ferr.code or "unavailable"
        local said = (type(ferr) == "table" and type(ferr.message) == "string") and ferr.message or code
        -- The branch is on the code and never on the text of the message: a transport
        -- that wants a timeout treated as a timeout has to say `timeout`.
        if code == "timeout" then
          last = { code = "timeout", message = "the attempt passed its own timeout: " .. said, retryable = true }
        elseif code == "cancelled" then
          last = { code = "cancelled", message = "the run was cancelled: " .. said, retryable = false }
        elseif code == "denied" then
          last = { code = "denied", message = "the connection was refused before it was made: " .. said, retryable = false }
        elseif code == "too_big" then
          last = { code = "too_big", message = "the response was over the transport's own limit: " .. said, retryable = false }
        else
          last = { code = "unavailable", message = said, retryable = true }
        end
      elseif type(res) ~= "table" or type(res.status) ~= "number" then
        last = { code = "unavailable", message = "the transport answered with something that is not a response", retryable = true }
      else
        local raw = type(res.body) == "string" and res.body or ""
        local decoded, decode_why = nil, nil
        if raw ~= "" then
          decoded, decode_why = io_decode(raw)
        else
          decode_why = "the body was empty"
        end
        ctx.decode_error = decode_why

        local reply, bad
        got, reply, bad = pcall(impl.read, res.status, decoded, raw, sc, ctx)
        if not got then
          last = { code = "unavailable", status = res.status,
                   message = string.format("the %s adapter raised while reading the answer", sc.adapter),
                   body = raw:sub(1, 1024), retryable = false }
        elseif reply ~= nil then
          -- A refusal arrives here too, and leaves here too: it is a reply.
          if type(reply) ~= "table" then
            last = { code = "malformed", status = res.status,
                     message = string.format("the %s adapter returned a %s, not a reply", sc.adapter, type(reply)),
                     body = raw:sub(1, 1024), retryable = false }
          elseif not stop_words[reply.stop] then
            -- An adapter is third-party code the moment a host registers one of its
            -- own, and a table with no `stop` is not a reply: the turn loop cannot
            -- read it and would spend its whole budget re-prompting a model that
            -- never spoke. Name the adapter instead.
            local said_stop = reply.stop == nil and "no stop at all"
                              or string.format("the stop %s", string.format("%q", tostring(reply.stop)))
            last = { code = "malformed", status = res.status,
                     message = string.format(
                       "the %s adapter answered with %s, and a reply stops on one of done, calls, cut or refused",
                       sc.adapter, said_stop),
                     body = raw:sub(1, 1024), retryable = false }
          else
            if type(reply.text) ~= "string" then reply.text = "" end
            if type(reply.calls) ~= "table" then reply.calls = {} end
            return reply
          end
        else
          local code = (type(bad) == "table" and type(bad.code) == "string") and bad.code or "malformed"
          if not port.codes[code] then code = "malformed" end
          last = {
            code = code, status = res.status,
            message = (type(bad) == "table" and type(bad.message) == "string" and bad.message)
                      or string.format("the endpoint answered %d", res.status),
            body = raw:sub(1, 1024),
            retryable = (type(bad) == "table" and bad.retryable == true),
          }
        end

        if last ~= nil and last.status ~= nil then
          entry.status = last.status
        end
        if last ~= nil and last.retryable and impl.retry_after then
          local read_ok, secs = pcall(impl.retry_after, res.headers)
          if read_ok and type(secs) == "number" and secs >= 0 then last.retry_after = secs end
        end
      end

      entry.code = last.code
      entry.status = last.status

      if not last.retryable then return answer() end
      if attempts >= retry.attempts then return answer() end

      -- min(base * factor^(n-2), cap) for attempt n, which is base before the second
      -- attempt. A retry-after header replaces it, still clamped to cap.
      local delay = retry.base * (retry.factor ^ (attempts - 1))
      if last.retry_after ~= nil then delay = last.retry_after end
      if delay > retry.cap then delay = retry.cap end
      if retry.jitter and type(p.rand) == "function" then
        local rolled, r = pcall(p.rand)
        if rolled and type(r) == "number" and r >= 0 and r < 1 then
          delay = delay * (0.5 + 0.5 * r)
        end
      end

      local can_sleep = type(p.clock) == "table" and type(p.clock.sleep) == "function"
      if not can_sleep then
        last.message = last.message .. "; retry was not possible here, because this host has no way to wait"
        return answer()
      end

      local left_now = remaining(started)
      if left_now ~= nil and left_now - delay <= 0 then
        -- Stop rather than sleep into the deadline.
        last.code = "timeout"
        last.message = string.format(
          "the %g second deadline for the whole call would have passed during the %g second wait before attempt %d; the last failure was: %s",
          deadline, delay, attempts + 1, last.message)
        return answer()
      end

      entry.delay = delay
      log("model.retry", { attempt = attempts, next = attempts + 1, delay = delay,
                           code = last.code, status = last.status })

      local slept, slept_ok, sleep_err = pcall(p.clock.sleep, delay)
      if not slept then
        -- A sleep that raises ends the retry loop with the failure already in hand.
        last.message = last.message .. "; retry stopped because the clock raised while waiting"
        entry.delay = nil
        return answer()
      end
      if slept_ok == nil then
        local said = (type(sleep_err) == "table" and type(sleep_err.message) == "string")
                     and sleep_err.message or "the clock could not wait"
        last.message = last.message .. "; retry was not possible here: " .. said
        entry.delay = nil
        return answer()
      end
    end
  end

  return m
end

return provider
