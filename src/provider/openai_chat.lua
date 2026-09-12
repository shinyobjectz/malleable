-- The `openai-chat` adapter: the chat-completions wire format, and nothing else.
--
-- Four pure functions and an id, per `spec/provider.md` §7. None of them touches a
-- port, sleeps, retries, or knows that retry exists -- everything they need arrives in
-- their arguments, which is what lets the whole wire format be proved with no
-- transport at all.
--
--   url     (scheme_cfg)                          -> string
--   headers (scheme_cfg)                          -> { [name] = value }
--   body    (request, model_name, scheme_cfg, ctx)-> table
--   read    (status, decoded, raw, scheme_cfg, ctx)-> reply | nil, fail
--   retry_after (headers)                         -> seconds | nil
--
-- `ctx` carries the two pure functions the wire format needs -- `ctx.io.encode` and
-- `ctx.io.decode`, both returning `value | nil, message` -- plus `ctx.model`,
-- `ctx.url` and `ctx.decode_error`, so a message can name what was asked for without
-- the adapter reaching for a port to find out. That fourth argument is a fix to §7,
-- which had `body` calling `p.json.encode` directly in §6 while §7 forbade it a port.
--
-- The provider has already checked the request before `body` sees it: every role is
-- one of the three, every tool message has an id. `body` may therefore read them
-- without re-deciding, and any message it does not recognise is a bug above it.

local chat = {}

-- The one relation this file has to the rest of the tree: none. It requires nothing.

local function str(v)
  if type(v) == "string" then return v end
  return nil
end

local function nonempty(v)
  local s = str(v)
  if s and s ~= "" then return s end
  return nil
end

-- --------------------------------------------------------------------------- the url

local function trim_slash(s)
  while s:sub(-1) == "/" do s = s:sub(1, -2) end
  return s
end

function chat.url(sc)
  local base = trim_slash(sc.base_url or "")
  local path = sc.path or "/chat/completions"
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  return base .. path
end

function chat.headers(sc)
  local h = { ["content-type"] = "application/json" }
  if nonempty(sc.key) then h["authorization"] = "Bearer " .. sc.key end
  return h
end

-- -------------------------------------------------------------------------- the body

-- A call's arguments travel as a JSON *string*, which is what the format asks for and
-- is also how the empty-table ambiguity is dodged: nothing to encode means the two
-- characters "{}" written out by hand, never a table handed to an encoder that would
-- have to guess.
local function argument_text(args, io)
  if type(args) ~= "table" or next(args) == nil then return "{}" end
  local text, why = io.encode(args)
  if not text then return nil, why end
  return text
end

local function wire_calls(calls, io)
  local out = {}
  for i = 1, #calls do
    local c = calls[i]
    local text, why = argument_text(c.args, io)
    if not text then
      return nil, string.format("call %d, to %s, has arguments that cannot be encoded: %s",
        i, tostring(c.tool), tostring(why))
    end
    out[#out + 1] = {
      id = c.id,
      type = "function",
      ["function"] = { name = c.tool, arguments = text },
    }
  end
  return out
end

local function wire_messages(request, io)
  local out = {}
  local system = nonempty(request.system)
  if system then out[#out + 1] = { role = "system", content = system } end

  local messages = request.messages
  for i = 1, #messages do
    local m = messages[i]
    if m.role == "user" then
      out[#out + 1] = { role = "user", content = m.text or "" }
    elseif m.role == "agent" then
      -- The harness's word for the agent is `agent`; the wire's is `assistant`.
      -- Translating between them is exactly the vendor knowledge that lives here.
      local w = { role = "assistant", content = m.text or "" }
      if type(m.calls) == "table" and #m.calls > 0 then
        local calls, why = wire_calls(m.calls, io)
        if not calls then return nil, why end
        w.tool_calls = calls
      end
      out[#out + 1] = w
    elseif m.role == "tool" then
      -- `ok` is deliberately not serialised. Whether the call failed is already in the
      -- text, in the harness's own words; a second account of it would eventually
      -- disagree with the first.
      out[#out + 1] = { role = "tool", tool_call_id = m.id, content = m.text or "" }
    else
      return nil, string.format("message %d has the role %q, which is not one of the three", i, tostring(m.role))
    end
  end
  return out
end

-- `spec.lua`'s `list` carries no element type, so an array argument goes out as a list
-- of strings. A strict endpoint rejects an array schema with no `items`, and a wrong
-- `items` is more usable than a rejected request. The repair is an element type on the
-- declaration surface, not a better guess here.
local function argument_schema(a)
  local s = { type = a.kind or "string" }
  if s.type == "array" then s.items = { type = "string" } end
  -- An object argument is any object: a host that decodes under the schema would
  -- otherwise close it and send `{}` (seen on 2026-09-11 with the show tool).
  if s.type == "object" then s.additionalProperties = true end
  -- A one_of is told as the list it is: the model cannot guess a value it was shown.
  if type(a.choices) == "table" and #a.choices > 0 then
    s.enum = {}
    for i = 1, #a.choices do s.enum[i] = a.choices[i] end
  end
  if nonempty(a.description) then s.description = a.description end
  return s
end

local function wire_tools(tools)
  local out = {}
  for i = 1, #tools do
    local t = tools[i]
    local parameters
    local args = t.args
    if type(args) ~= "table" or #args == 0 then
      -- No empty collection reaches the wire, ever. A tool with no arguments says so
      -- with a closed object rather than an empty `properties` map.
      parameters = { type = "object", additionalProperties = false }
    else
      local properties, required = {}, {}
      for j = 1, #args do
        local a = args[j]
        properties[a.name] = argument_schema(a)
        if a.required then required[#required + 1] = a.name end
      end
      parameters = { type = "object", properties = properties }
      if #required > 0 then parameters.required = required end
    end
    -- `ask` is not serialised. Whether the harness will stop and ask a human is the
    -- harness's business, and a model told which tools are gated will negotiate.
    out[#out + 1] = {
      type = "function",
      ["function"] = { name = t.name, description = t.about, parameters = parameters },
    }
  end
  return out
end

function chat.body(request, model_name, sc, ctx)
  local messages, why = wire_messages(request, ctx.io)
  if not messages then return nil, why end

  local body = { model = model_name, messages = messages }

  if type(request.tools) == "table" and #request.tools > 0 then
    body.tools = wire_tools(request.tools)
  end

  -- OpenAI's field, and OpenRouter reads it too (measured on Mercury 2.5, 2026-09-10: "low"
  -- sends back about 300 tokens where the default sends back 2,400).
  if type(request.reasoning) == "string" then body.reasoning_effort = request.reasoning end

  -- Extra body fields, checked at build time for the three they may not overwrite, so
  -- this loop can be a plain merge.
  if type(sc.params) == "table" then
    for k, v in pairs(sc.params) do body[k] = v end
  end

  return body
end

-- ------------------------------------------------------------------ reading a reply

local function read_usage(u)
  if type(u) ~= "table" then return nil end
  local sent = type(u.prompt_tokens) == "number" and u.prompt_tokens or nil
  local back = type(u.completion_tokens) == "number" and u.completion_tokens or nil
  local details = type(u.prompt_tokens_details) == "table" and u.prompt_tokens_details or nil
  local cached = details and type(details.cached_tokens) == "number" and details.cached_tokens or nil
  -- nil means unmeasured. Zeros would read as a measurement.
  if sent == nil and back == nil then return nil end
  return { sent = sent, back = back, cached = cached }
end

-- A model mistake is not a call failure: an argument string the model wrote badly
-- still becomes a call, with an empty table for `args` so a caller that indexes it
-- does not blow up, and the exact bytes kept in `args_raw` so the turn loop can tell
-- the model what it sent.
local function read_arguments(raw_args, io)
  if type(raw_args) == "table" then
    -- An endpoint that already decoded the arguments is taken at its word. A table
    -- with nothing in it is not: a JSON `null` decodes to the port's own null
    -- sentinel, which is one shared table for the whole process, and handing it out
    -- as `args` would let the first caller that filled in a default poison every
    -- later call that also arrived with no arguments. No arguments is a FRESH empty
    -- table, every time, whether it arrived as null, as `{}` or not at all.
    if next(raw_args) == nil then return {} end
    return raw_args
  end
  if raw_args == nil then return {} end
  if type(raw_args) ~= "string" then
    return {}, "the arguments arrived as a " .. type(raw_args) .. ", not as JSON text", nil
  end
  if raw_args:match("^%s*$") then return {} end
  local v, why = io.decode(raw_args)
  if v == nil then
    return {}, why or "the arguments did not decode", raw_args
  end
  if type(v) ~= "table" then
    return {}, "the arguments decoded to a " .. type(v) .. ", where an object was expected", raw_args
  end
  return v
end

local function read_calls(list, io)
  local calls, dropped = {}, {}
  for i = 1, #list do
    local t = list[i]
    local f = type(t) == "table" and t["function"] or nil
    local id = type(t) == "table" and nonempty(t.id) or nil
    local name = type(f) == "table" and nonempty(f.name) or nil
    if not id then
      -- A tool result is addressed by id. A call with none cannot be answered, and
      -- passing it on would build a transcript the API rejects on the next step.
      dropped[#dropped + 1] = { index = i, why = "the call arrived with no id and cannot be answered" }
    elseif not name then
      dropped[#dropped + 1] = { index = i, why = "the call arrived with no tool name" }
    else
      local args, args_error, args_raw = read_arguments(f.arguments, io)
      calls[#calls + 1] = {
        id = id, tool = name, args = args,
        args_error = args_error, args_raw = args_raw,
      }
    end
  end
  return calls, dropped
end

local function api_message(decoded)
  if type(decoded) ~= "table" then return nil end
  local e = decoded.error
  if type(e) == "table" then return nonempty(e.message) end
  return nonempty(e)
end

local function fail(code, message, retryable)
  return nil, { code = code, message = message, retryable = retryable or false }
end

function chat.read(status, decoded, raw, sc, ctx)
  if status >= 200 and status <= 299 then
    if decoded == nil then
      return fail("malformed",
        "the endpoint answered 200 with something that is not JSON: " .. (ctx.decode_error or "it did not decode"))
    end
    if type(decoded) ~= "table" then
      return fail("malformed", "the endpoint answered with a bare JSON value, not a completion")
    end
    local choices = decoded.choices
    if type(choices) ~= "table" then
      return fail("malformed", "the completion carried no `choices`")
    end
    if #choices == 0 then
      return fail("malformed", "the completion carried an empty `choices`")
    end
    local choice = choices[1]
    if type(choice) ~= "table" then
      return fail("malformed", "the first choice is not an object")
    end

    local message = type(choice.message) == "table" and choice.message or {}
    local finish = nonempty(choice.finish_reason)
    local text = str(message.content) or ""
    local refusal = nonempty(message.refusal)

    local calls, dropped = {}, {}
    if type(message.tool_calls) == "table" then
      calls, dropped = read_calls(message.tool_calls, ctx.io)
    end

    local stop
    if refusal then
      -- A refusal is a reply. It is never retried, never logged as an error, never
      -- turned into an err: the model declined, and its reader sees the words.
      stop, text, calls, dropped = "refused", refusal, {}, {}
    elseif finish == "content_filter" then
      stop, text, calls, dropped = "refused", "", {}, {}
    elseif finish == "length" then
      -- Returned as it arrived, calls and all. Truncated arguments are the turn loop's
      -- to refuse; a caller that cannot see them cannot report them.
      stop = "cut"
    elseif #calls > 0 then
      stop = "calls"
    else
      stop = "done"
    end

    local reply = {
      text = text, calls = calls, stop = stop,
      usage = read_usage(decoded.usage),
      raw_stop = finish,
      served_model = nonempty(decoded.model),
    }
    if #dropped > 0 then reply.dropped = dropped end
    return reply
  end

  local said = api_message(decoded)

  if status == 400 or status == 422 then
    return fail("malformed", said or "the endpoint refused the request as malformed")
  elseif status == 401 or status == 403 then
    -- What was rejected, never what was sent.
    return fail("denied", "the endpoint rejected the credential it was given")
  elseif status == 404 then
    return fail("not_found", string.format("nothing is served at %s for the model %s",
      sc.path or "/chat/completions", tostring(ctx.model)))
  elseif status == 413 then
    return fail("too_big", said or "the endpoint refused the request as too large")
  elseif status == 429 then
    return fail("exhausted", said or "the endpoint is rate limiting this credential", true)
  elseif status == 500 or status == 502 or status == 503 or status == 504 then
    return fail("unavailable", string.format("the endpoint answered %d", status), true)
  end

  return fail("unavailable", said or string.format("the endpoint answered %d, which this adapter does not know", status))
end

-- Headers only, and a number only. A `retry-after` carrying an HTTP date is refused:
-- the clock this provider has is monotonic, not wall time, and doing date arithmetic
-- with it would be a guess.
function chat.retry_after(headers)
  if type(headers) ~= "table" then return nil end
  local v = headers["retry-after"] or headers["Retry-After"]
  if type(v) == "number" then
    if v >= 0 and v == v and v ~= math.huge then return v end
    return nil
  end
  if type(v) ~= "string" then return nil end
  if not v:match("^%s*%d+%.?%d*%s*$") then return nil end
  return tonumber(v)
end

-- Two schemes, one wire format, different homes. `new` exists so a host can register
-- the same shape under a third name -- a local endpoint, a gateway -- without copying
-- the file.
function chat.new(default_base)
  return {
    id = "openai-chat",
    default_base = default_base,
    url = chat.url,
    headers = chat.headers,
    body = chat.body,
    read = chat.read,
    retry_after = chat.retry_after,
  }
end

return chat
