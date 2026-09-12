-- provider -- the model port that talks to a real API, proved against a scripted
-- transport. No network, no disk, no subprocess, no real clock. Each test asserts with
-- plain `assert` and prints nothing on success.

local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../src/?.lua;" .. package.path

local port     = require("port")
local double   = require("double")
local spec     = require("spec")
local turn     = require("turn")
local provider = require("provider")
local json     = require("provider.json")
local chat     = require("provider.openai_chat")
local pdouble  = require("provider.double")

local T = {}

-- --------------------------------------------------------------------- the helpers

local function deep_eq(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_eq(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function deep_copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deep_copy(v) end
  return out
end

local function has(s, needle)
  return type(s) == "string" and s:find(needle, 1, true) ~= nil
end

local function raises(f, ...)
  local ok, e = pcall(f, ...)
  return (not ok), tostring(e)
end

-- The two pure functions an adapter is handed, built straight off the json port, so
-- the wire-format tests run with no provider and no transport at all.
local io_pair = {
  encode = function (v)
    local a, e = json.encode(v)
    if a == nil then return nil, e.message end
    return a
  end,
  decode = function (s)
    local a, e = json.decode(s)
    if a == nil then return nil, e.message end
    return a
  end,
}

local function ctx_for(model, sc)
  return { io = io_pair, model = model or "m", cfg = sc or {}, url = "https://x/y" }
end

local function scheme(over)
  local sc = { base_url = "https://api.example.test/v1", path = "/chat/completions",
               headers = {}, params = {}, adapter = "openai" }
  for k, v in pairs(over or {}) do sc[k] = v end
  return sc
end

-- A whole world: a scripted transport, the real encoder, a frozen clock, a recording
-- log. `responses` is the queue `n.fetch` answers from, in order.
local function world(responses, over)
  local w = {
    net   = pdouble.net(responses or {}),
    json  = json,
    clock = double.clock(),
    log   = double.log(),
  }
  for k, v in pairs(over or {}) do w[k] = v end
  return w
end

-- A 200 carrying a chat completion.
local function completion(choice, extra)
  local body = { choices = { choice } }
  for k, v in pairs(extra or {}) do body[k] = v end
  return { status = 200, body = (json.encode(body)) }
end

local function said(text, finish)
  return { message = { content = text }, finish_reason = finish or "stop" }
end

local function asked(calls, finish)
  return { message = { content = json.null, tool_calls = calls }, finish_reason = finish or "tool_calls" }
end

local function tool_call(id, name, args)
  return { id = id, type = "function", ["function"] = { name = name, arguments = args } }
end

local function ask_for(text)
  return { model = "openai:gpt-4o-mini", messages = { { role = "user", text = text or "hello" } } }
end

-- Two tools in the exact shape `spec.schema` returns.
local function two_tools()
  local a = spec.new()
  spec.add_tool(a, "read", {
    about = "Read a file",
    args = { path = spec.types.string "workspace-relative path" },
    run = function () end,
  })
  spec.add_tool(a, "write", {
    about = "Write a file",
    args = {
      path = spec.types.string "where to write",
      text = spec.types.string_opt "what to write",
    },
    ask = true,
    run = function () end,
  })
  return spec.schema(a)
end

-- ============================================================ the wire format

function T.a_request_becomes_a_body()
  local body = chat.body(ask_for("review it"), "inception/mercury-2.5", scheme(), ctx_for())
  assert(body.model == "inception/mercury-2.5", body.model)
  assert(#body.messages == 1)
  assert(body.messages[1].role == "user")
  assert(body.messages[1].content == "review it")
  assert(body.tools == nil)
end

-- The request's reasoning is OpenAI's `reasoning_effort`, which OpenRouter reads too; with
-- none declared the body says nothing about it.
function T.reasoning_becomes_reasoning_effort()
  local r = ask_for("go")
  assert(chat.body(r, "m", scheme(), ctx_for()).reasoning_effort == nil)
  r.reasoning = "low"
  assert(chat.body(r, "m", scheme(), ctx_for()).reasoning_effort == "low")
end

function T.a_system_prompt_leads()
  local r = ask_for("go")
  r.system = "you are careful"
  local body = chat.body(r, "m", scheme(), ctx_for())
  assert(#body.messages == 2)
  assert(body.messages[1].role == "system")
  assert(body.messages[1].content == "you are careful")
  assert(body.messages[2].role == "user")

  r.system = ""
  assert(#chat.body(r, "m", scheme(), ctx_for()).messages == 1)
  r.system = nil
  assert(#chat.body(r, "m", scheme(), ctx_for()).messages == 1)
end

function T.the_tool_list_survives()
  local r = ask_for()
  r.tools = two_tools()
  local body = chat.body(r, "m", scheme(), ctx_for())
  assert(#body.tools == 2)
  assert(body.tools[1].type == "function")
  assert(body.tools[1]["function"].name == "read")
  assert(body.tools[1]["function"].description == "Read a file")
  assert(body.tools[2]["function"].name == "write")
  assert(body.tools[2]["function"].description == "Write a file")
  local props = body.tools[1]["function"].parameters.properties
  assert(props.path.type == "string")
  assert(props.path.description == "workspace-relative path")
end

function T.only_required_arguments_are_required()
  local r = ask_for()
  r.tools = two_tools()
  local params = chat.body(r, "m", scheme(), ctx_for()).tools[2]["function"].parameters
  assert(#params.required == 1, tostring(#params.required))
  assert(params.required[1] == "path", params.required[1])
  assert(params.properties.text.type == "string")
end

function T.an_object_argument_is_any_object()
  -- A host that decodes under the schema would close a bare object and send `{}`.
  local a = spec.new()
  spec.add_tool(a, "show", { about = "Show a view", args = { view = spec.types.table "the tree" }, run = function () end })
  local r = ask_for()
  r.tools = spec.schema(a)
  local params = chat.body(r, "m", scheme(), ctx_for()).tools[1]["function"].parameters
  assert(params.properties.view.type == "object")
  assert(params.properties.view.additionalProperties == true)
end

function T.no_empty_collection_reaches_the_wire()
  -- A tool with no arguments at all.
  local a = spec.new()
  spec.add_tool(a, "clock", { about = "What time it is", run = function () end })
  local r = ask_for()
  r.tools = spec.schema(a)
  local body = chat.body(r, "m", scheme(), ctx_for())
  local params = body.tools[1]["function"].parameters
  assert(params.type == "object")
  assert(params.additionalProperties == false)
  assert(params.properties == nil)
  assert(params.required == nil)

  -- The assertion is on the encoded string, so an array-versus-object slip is caught
  -- where a table comparison would miss it.
  local text = assert(json.encode(body))
  assert(not has(text, "[]"), text)
  assert(not has(text, "{}"), text)

  -- And a request with no tools at all.
  local bare = assert(json.encode(chat.body(ask_for(), "m", scheme(), ctx_for())))
  assert(not has(bare, "[]"), bare)
  assert(not has(bare, "{}"), bare)
  assert(not has(bare, "tools"), bare)
end

function T.the_model_is_never_told_about_the_gate()
  local r = ask_for()
  r.tools = two_tools()
  assert(r.tools[2].ask == true, "the fixture must carry a gated tool")
  local text = assert(json.encode(chat.body(r, "m", scheme(), ctx_for())))
  assert(not has(text, "ask"), text)
  assert(not has(text, "true"), text)
end

function T.the_body_is_deterministic()
  local r = ask_for()
  r.system = "careful"
  r.tools = two_tools()
  r.messages[#r.messages + 1] = {
    role = "agent", text = "reading",
    calls = { { id = "c1", tool = "read", args = { path = "a.txt" } } },
  }
  r.messages[#r.messages + 1] = { role = "tool", id = "c1", ok = true, text = "hello" }
  local one = chat.body(r, "m", scheme(), ctx_for())
  local two = chat.body(r, "m", scheme(), ctx_for())
  assert(deep_eq(one, two))
  assert(json.encode(one) == json.encode(two))
end

function T.an_agent_message_carries_its_calls()
  local r = ask_for()
  r.messages[#r.messages + 1] = {
    role = "agent", text = "on it",
    calls = {
      { id = "c1", tool = "read", args = { path = "a.txt" } },
      { id = "c2", tool = "clock", args = {} },
    },
  }
  local body = chat.body(r, "m", scheme(), ctx_for())
  local w = body.messages[2]
  assert(w.role == "assistant")
  assert(w.content == "on it")
  assert(#w.tool_calls == 2)
  assert(w.tool_calls[1].id == "c1")
  assert(w.tool_calls[1].type == "function")
  assert(w.tool_calls[1]["function"].name == "read")
  -- Arguments travel as a JSON string, which is what the format asks for.
  assert(w.tool_calls[1]["function"].arguments == '{"path":"a.txt"}',
    w.tool_calls[1]["function"].arguments)
  assert(w.tool_calls[2]["function"].arguments == "{}")
  assert(deep_eq(json.decode(w.tool_calls[1]["function"].arguments), { path = "a.txt" }))
end

function T.a_tool_result_is_addressed_by_id()
  local r = ask_for()
  r.messages[#r.messages + 1] = { role = "tool", id = "c7", ok = false, text = "no such file" }
  local body = chat.body(r, "m", scheme(), ctx_for())
  local w = body.messages[2]
  assert(w.role == "tool")
  assert(w.tool_call_id == "c7")
  assert(w.content == "no such file")
  assert(w.ok == nil)
  -- Provider must not narrate a failure the harness already worded.
  local text = assert(json.encode(body))
  assert(not has(text, '"ok"'), text)
  assert(not has(text, "false"), text)
end

function T.config_cannot_overwrite_the_request()
  local n = pdouble.net { completion(said("hi")) }
  local p = world()
  p.net = n
  local m = assert(provider.model(
    { schemes = { openai = { key = "k", params = { temperature = 0.2, max_tokens = 64 } } } }, p))
  assert(m.call(ask_for()))
  local body = assert(json.decode(n.sent[1].body))
  assert(body.temperature == 0.2)
  assert(body.max_tokens == 64)
  assert(body.model == "gpt-4o-mini")

  local bad = raises(provider.model, { schemes = { openai = { params = { model = "sneaky" } } } }, p)
  assert(bad, "params.model must raise at build time")
  bad = raises(provider.model, { schemes = { openai = { params = { messages = {} } } } }, p)
  assert(bad, "params.messages must raise at build time")
  bad = raises(provider.model, { schemes = { openai = { headers = { Authorization = "Bearer x" } } } }, p)
  assert(bad, "headers.authorization must raise at build time")
  bad = raises(provider.model, { schemes = { openai = { headers = { ["content-type"] = "text/plain" } } } }, p)
  assert(bad, "headers.content-type must raise at build time")
end

-- ============================================================ reading a reply

local function one_call(responses, cfg)
  local p = world(responses)
  local m = assert(provider.model(cfg or {}, p))
  local reply, err = m.call(ask_for())
  return reply, err, p
end

function T.plain_text_is_done()
  local reply, err = one_call { completion(said("all done")) }
  assert(err == nil, err and err.message)
  assert(reply.text == "all done")
  assert(reply.stop == "done", reply.stop)
  assert(type(reply.calls) == "table" and #reply.calls == 0)
  assert(reply.raw_stop == "stop")
end

function T.tool_calls_are_calls()
  local reply, err = one_call {
    completion(asked { tool_call("c1", "read", '{"path":"a.txt"}') }),
  }
  assert(err == nil)
  assert(reply.stop == "calls", reply.stop)
  assert(reply.text == "")
  assert(#reply.calls == 1)
  assert(reply.calls[1].id == "c1")
  assert(reply.calls[1].tool == "read")
  assert(deep_eq(reply.calls[1].args, { path = "a.txt" }))
  assert(reply.calls[1].args_error == nil)
end

function T.text_and_calls_together()
  local choice = asked { tool_call("c1", "read", '{"path":"a.txt"}') }
  choice.message.content = "I will read it first."
  local reply = assert(one_call { completion(choice) })
  assert(reply.stop == "calls", reply.stop)
  assert(reply.text == "I will read it first.")
  assert(#reply.calls == 1)
end

function T.a_refusal_is_a_reply()
  local p = world { completion { message = { refusal = "I will not do that." }, finish_reason = "stop" } }
  local m = assert(provider.model({}, p))
  local reply, err = m.call(ask_for())
  assert(err == nil, err and err.message)
  assert(reply.stop == "refused", reply.stop)
  assert(reply.text == "I will not do that.")
  assert(type(reply.calls) == "table" and #reply.calls == 0)
  -- A refusal is never retried and never reported as an error.
  assert(#p.clock.slept == 0)
  assert(#p.net.sent == 1)
end

function T.a_filtered_reply_is_still_a_reply()
  local reply, err = one_call {
    completion { message = { content = json.null }, finish_reason = "content_filter" },
  }
  assert(err == nil)
  assert(reply.stop == "refused", reply.stop)
  assert(reply.text == "", tostring(reply.text))
  assert(reply.raw_stop == "content_filter")
end

function T.a_cut_reply_keeps_its_calls()
  local reply = assert(one_call {
    completion(asked({ tool_call("c1", "read", '{"path":"a.tx') }, "length")),
  })
  assert(reply.stop == "cut", reply.stop)
  assert(#reply.calls == 1)
  assert(reply.calls[1].tool == "read")
  -- Truncated arguments are the turn loop's to refuse; nothing is dropped here.
  assert(reply.calls[1].args_error ~= nil)
end

function T.usage_absent_is_nil()
  local reply = assert(one_call { completion(said("hi")) })
  assert(reply.usage == nil)

  local counted = assert(one_call {
    completion(said("hi"), { usage = { prompt_tokens = 812, completion_tokens = 44 }, model = "served/x" }),
  })
  assert(counted.usage.sent == 812)
  assert(counted.usage.back == 44)
  assert(counted.served_model == "served/x")
end

-- ============================================================ broken model output

function T.broken_arguments_are_not_a_failure()
  local reply, err = one_call { completion(asked { tool_call("c1", "read", "{path: ") }) }
  assert(err == nil, err and err.message)
  assert(reply.stop == "calls")
  assert(#reply.calls == 1)
  local c = reply.calls[1]
  assert(type(c.args) == "table" and next(c.args) == nil)
  assert(c.args_raw == "{path: ", tostring(c.args_raw))
  assert(type(c.args_error) == "string" and c.args_error ~= "")
end

function T.valid_json_of_the_wrong_type()
  local reply = assert(one_call { completion(asked { tool_call("c1", "read", "42") }) })
  local c = reply.calls[1]
  assert(type(c.args) == "table" and next(c.args) == nil)
  assert(has(c.args_error, "number"), c.args_error)
  assert(c.args_raw == "42")
end

function T.empty_arguments_decode_to_empty()
  local reply = assert(one_call { completion(asked { tool_call("c1", "clock", "") }) })
  local c = reply.calls[1]
  assert(type(c.args) == "table" and next(c.args) == nil)
  assert(c.args_error == nil, tostring(c.args_error))
end

function T.a_call_with_no_id_is_dropped()
  local reply, err = one_call {
    completion(asked {
      tool_call(nil, "read", "{}"),
      tool_call("c2", "write", '{"path":"b.txt"}'),
    }),
  }
  assert(err == nil)
  assert(#reply.calls == 1)
  assert(reply.calls[1].id == "c2")
  assert(type(reply.dropped) == "table" and #reply.dropped == 1)
  assert(reply.dropped[1].index == 1)
  assert(type(reply.dropped[1].why) == "string" and reply.dropped[1].why ~= "")
end

function T.an_html_error_page_is_malformed()
  local page = "<html><head><title>502</title></head><body>gateway</body></html>"
  local reply, err = one_call { { status = 200, body = page } }
  assert(reply == nil)
  assert(err.code == "malformed", err.code)
  assert(err.attempts == 1, tostring(err.attempts))
  assert(err.body == page, tostring(err.body))
  assert(#err.history == 1)
end

function T.a_2xx_with_no_choices_is_malformed()
  local p = world { { status = 200, body = '{"id":"x","object":"chat.completion"}' } }
  local m = assert(provider.model({}, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "malformed", err.code)
  assert(has(err.message, "choices"), err.message)
  assert(#p.net.sent == 1, "malformed is not retried")
end

function T.an_empty_choices_list_is_malformed()
  local p = world { { status = 200, body = '{"choices":[]}' } }
  local m = assert(provider.model({}, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "malformed", err.code)
  assert(has(err.message, "empty"), err.message)
  assert(#p.net.sent == 1)
end

-- ============================================================ failure and retry

function T.two_failures_then_a_reply()
  local p = world {
    { status = 503, body = "" },
    { status = 503, body = "" },
    completion(said("finally")),
  }
  local m = assert(provider.model({}, p))
  local reply, err = m.call(ask_for())
  assert(err == nil, err and err.message)
  assert(reply.text == "finally")
  assert(#p.net.sent == 3)
  assert(deep_eq(p.clock.slept, { 0.5, 1.0 }), table.concat(p.clock.slept, ","))
end

function T.retries_run_out_and_say_so()
  local p = world { { status = 503 }, { status = 503 }, { status = 503 } }
  local m = assert(provider.model({ retry = { attempts = 3 } }, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "unavailable", err.code)
  assert(err.attempts == 3, tostring(err.attempts))
  assert(#err.history == 3, tostring(#err.history))
  assert(err.status == 503)
  assert(err.history[1].delay == 0.5)
  assert(err.history[2].delay == 1.0)
  assert(err.history[3].delay == nil, "the last attempt is not followed by a wait")
end

function T.a_rejected_credential_is_not_retried()
  local p = world { { status = 401, body = '{"error":{"message":"bad key"}}' } }
  local m = assert(provider.model({ schemes = { openai = { key = "sk-x" } } }, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "denied", err.code)
  assert(err.attempts == 1, tostring(err.attempts))
  assert(#p.clock.slept == 0)
  assert(#p.net.sent == 1)
end

function T.retry_after_is_obeyed()
  local p = world {
    { status = 429, headers = { ["Retry-After"] = "2" }, body = "" },
    completion(said("ok")),
  }
  local m = assert(provider.model({}, p))
  assert(m.call(ask_for()))
  assert(deep_eq(p.clock.slept, { 2 }), table.concat(p.clock.slept, ","))
end

function T.retry_after_is_clamped()
  -- A header must not be able to park the harness for a quarter of an hour.
  local p = world {
    { status = 429, headers = { ["retry-after"] = "999" }, body = "" },
    completion(said("ok")),
  }
  local m = assert(provider.model({}, p))
  assert(m.call(ask_for()))
  assert(deep_eq(p.clock.slept, { 8 }), table.concat(p.clock.slept, ","))

  -- An HTTP date is not a number this provider can use, so the computed delay stands.
  local q = world {
    { status = 429, headers = { ["retry-after"] = "Wed, 21 Oct 2026 07:28:00 GMT" } },
    completion(said("ok")),
  }
  local m2 = assert(provider.model({}, q))
  assert(m2.call(ask_for()))
  assert(deep_eq(q.clock.slept, { 0.5 }), table.concat(q.clock.slept, ","))
end

function T.the_deadline_is_not_slept_through()
  local p = world { { status = 503 }, { status = 503 }, { status = 503 } }
  local m = assert(provider.model({ deadline = 1.2 }, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "timeout", err.code)
  assert(has(err.message, "deadline"), err.message)
  assert(err.attempts == 2, tostring(err.attempts))
  assert(deep_eq(p.clock.slept, { 0.5 }), table.concat(p.clock.slept, ","))
  assert(#p.net.sent == 2)
end

function T.no_sleep_means_no_retry()
  -- Plain Lua has no way to wait, so this is the default host, not an exotic one.
  local p = world { { status = 503 }, { status = 503 } }
  p.clock = {
    now = function () return 0 end,
    mono = function () return 0 end,
    sleep = function () return nil, port.error("clock", "sleep", "unavailable", "this host cannot wait") end,
  }
  local m = assert(provider.model({}, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "unavailable", err.code)
  assert(err.attempts == 1, tostring(err.attempts))
  assert(has(err.message, "retry was not possible"), err.message)
  assert(#p.net.sent == 1, "it must not spin and must not re-send immediately")
end

function T.transport_codes_are_honoured()
  -- The branch is on the code, never on the message text.
  local slow = world {
    { fail = { code = "timeout", message = "took too long" } },
    completion(said("ok")),
  }
  local m = assert(provider.model({}, slow))
  local reply, err = m.call(ask_for())
  assert(err == nil, err and err.message)
  assert(reply.text == "ok")
  assert(#slow.net.sent == 2)

  local stopped = world {
    { fail = { code = "cancelled", message = "the user pressed stop" } },
    completion(said("never reached")),
  }
  local m2 = assert(provider.model({}, stopped))
  local r2, e2 = m2.call(ask_for())
  assert(r2 == nil)
  assert(e2.code == "cancelled", e2.code)
  assert(e2.attempts == 1)
  assert(#stopped.net.sent == 1)
  assert(#stopped.clock.slept == 0)
end

function T.a_transport_that_raises_is_a_failure()
  local p = world { { raise = "the socket exploded" } }
  local m = assert(provider.model({ retry = { attempts = 1 } }, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "unavailable", err.code)
  assert(err.attempts == 1)
  assert(not has(err.message, "exploded"), err.message)
end

function T.a_string_status_does_not_crash()
  local p = world { { raw = { status = "200", body = "{}" } } }
  local m = assert(provider.model({ retry = { attempts = 1 } }, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "unavailable", err.code)
  assert(err.attempts == 1)
end

function T.a_sleep_that_raises_ends_the_loop()
  local p = world { { status = 503 }, { status = 503 }, { status = 503 } }
  p.clock = {
    now = function () return 0 end,
    mono = function () return 0 end,
    sleep = function () error("the clock is broken") end,
  }
  local m = assert(provider.model({}, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "unavailable", err.code)
  assert(err.attempts == 1, tostring(err.attempts))
  assert(has(err.message, "clock"), err.message)
  assert(#p.net.sent == 1, "no further attempt is made")
end

function T.the_last_failure_wins()
  local p = world {
    { status = 503 }, { status = 503 }, { status = 503 },
    { status = 401, body = "" },
  }
  local m = assert(provider.model({ retry = { attempts = 4 } }, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "denied", err.code)
  assert(err.attempts == 4, tostring(err.attempts))
  assert(#err.history == 4, tostring(#err.history))
  assert(err.history[1].code == "unavailable")
  assert(err.history[4].code == "denied")
  assert(err.history[4].status == 401)
end

-- ============================================================ secrets and hygiene

function T.the_key_never_comes_back()
  local key = "sk-test-123"
  local p = world {
    { status = 401, body = '{"error":{"message":"the key ' .. key .. ' is not valid"}}' },
  }
  local m = assert(provider.model({ schemes = { openai = { key = key } } }, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "denied", err.code)
  for k, v in pairs(err) do
    if type(v) == "string" then
      assert(not has(v, key), "the key reached err." .. tostring(k) .. ": " .. v)
    end
  end
  assert(has(err.body, "withheld"), tostring(err.body))
end

function T.the_key_is_never_logged()
  local key = "sk-secret-987"
  local p = world {
    { status = 503, body = key }, { status = 503, body = key }, { status = 503, body = key },
  }
  local m = assert(provider.model({ schemes = { openai = { key = key } } }, p))
  local _, err = m.call(ask_for())
  assert(err ~= nil)
  assert(#p.log.lines > 0, "a retry writes a line")
  for i = 1, #p.log.lines do
    local line = p.log.lines[i]
    assert(not has(line.event, key))
    for k, v in pairs(line.fields) do
      assert(not has(tostring(v), key), "the key reached the log field " .. tostring(k))
      assert(not has(tostring(k), key))
    end
  end
end

function T.the_request_is_not_mutated()
  local r = {
    model = "openai:gpt-4o-mini",
    system = "be careful",
    messages = {
      { role = "user", text = "go" },
      { role = "agent", text = "on it", calls = { { id = "c1", tool = "read", args = { path = "a.txt" } } } },
      { role = "tool", id = "c1", ok = true, text = "contents" },
    },
    tools = two_tools(),
  }
  local before = deep_copy(r)

  local p = world { completion(said("done")) }
  local m = assert(provider.model({}, p))
  assert(m.call(r))
  assert(deep_eq(r, before), "a success rewrote the request")

  -- The retry path is where a rewrite would hide.
  local q = world { { status = 503 }, { status = 503 }, { status = 503 } }
  local m2 = assert(provider.model({}, q))
  local reply = m2.call(r)
  assert(reply == nil)
  assert(deep_eq(r, before), "a three-attempt failure rewrote the request")
end

function T.no_credential_no_header()
  local p = world { completion(said("hi")) }
  local m = assert(provider.model({ schemes = { openai = { base_url = "https://local.test/v1/" } } }, p))
  assert(m.call(ask_for()))
  local sent = p.net.sent[1]
  assert(sent.headers["authorization"] == nil, tostring(sent.headers["authorization"]))
  assert(sent.headers["content-type"] == "application/json")
  -- The trailing slash is trimmed rather than doubled.
  assert(sent.url == "https://local.test/v1/chat/completions", sent.url)
  assert(sent.method == "POST")
  assert(sent.timeout == 60)

  local q = world { completion(said("hi")) }
  local m2 = assert(provider.model({ schemes = { openai = { key = "sk-1" } } }, q))
  assert(m2.call(ask_for()))
  assert(q.net.sent[1].headers["authorization"] == "Bearer sk-1")
end

-- ============================================================ wiring

function T.an_unknown_scheme_is_reported()
  local p = world {}
  local m, err = provider.model({ schemes = { nope = {} } }, p)
  assert(m == nil)
  assert(err.code == "unavailable", err.code)
  assert(has(err.message, "nope"), err.message)
  assert(has(err.message, "openrouter"), err.message)
end

function T.a_bare_model_name_is_refused()
  -- Guessing would send a key to a host the config never named.
  local p = world { completion(said("never sent")) }
  local m = assert(provider.model({}, p))
  local reply, err = m.call { model = "gpt-4o", messages = { { role = "user", text = "hi" } } }
  assert(reply == nil)
  assert(err.code == "malformed", err.code)
  assert(err.attempts == 0)
  assert(#p.net.sent == 0)
end

function T.wrong_types_raise()
  local p = world { completion(said("x")) }
  local m = assert(provider.model({}, p))
  assert(raises(m.call, "hello"))
  assert(raises(m.call, { model = "" }))
  assert(raises(m.call, { model = "openai:x", messages = 3 }))
  assert(raises(m.call, { model = "openai:x", messages = {}, system = 7 }))
  assert(raises(provider.parse_model, 42))
  assert(raises(provider.model, {}, {}))
  assert(raises(provider.model, {}, { net = { fetch = function () end } }))
end

function T.an_empty_transcript_sends_nothing()
  local p = world { completion(said("never sent")) }
  local m = assert(provider.model({}, p))
  local reply, err = m.call { model = "openai:gpt-4o", messages = {} }
  assert(reply == nil)
  assert(err.code == "malformed", err.code)
  assert(err.attempts == 0, tostring(err.attempts))
  assert(#p.net.sent == 0)

  -- A system prompt on its own is something to send.
  local q = world { completion(said("hi")) }
  local m2 = assert(provider.model({}, q))
  assert(m2.call { model = "openai:gpt-4o", messages = {}, system = "you are careful" })
  assert(#q.net.sent == 1)
end

function T.an_unknown_role_is_named()
  local p = world { completion(said("never sent")) }
  local m = assert(provider.model({}, p))
  local reply, err = m.call {
    model = "openai:gpt-4o",
    messages = { { role = "user", text = "hi" }, { role = "developer", text = "psst" } },
  }
  assert(reply == nil)
  assert(err.code == "malformed", err.code)
  assert(has(err.message, "developer"), err.message)
  assert(has(err.message, "2"), err.message)
  assert(#p.net.sent == 0)
end

function T.a_tool_message_needs_an_id()
  local p = world { completion(said("never sent")) }
  local m = assert(provider.model({}, p))
  local reply, err = m.call {
    model = "openai:gpt-4o",
    messages = { { role = "user", text = "hi" }, { role = "tool", text = "result" } },
  }
  assert(reply == nil)
  assert(err.code == "malformed", err.code)
  assert(has(err.message, "2"), err.message)
  assert(has(err.message, "id"), err.message)
  assert(#p.net.sent == 0)
end

function T.registering_runs_nothing()
  -- Declaring is not running: every function here raises, and registering must not
  -- call one of them.
  local boom = function () error("this adapter must never run") end
  local impl = { url = boom, headers = boom, body = boom, read = boom, retry_after = boom }
  provider.adapter("probe-inert", impl)
  local names = provider.adapters()
  local found = false
  for i = 1, #names do if names[i] == "probe-inert" then found = true end end
  assert(found, "the adapter was not registered")
end

function T.an_adapter_cannot_be_replaced()
  local ok = function () end
  provider.adapter("probe-once", { url = ok, headers = ok, body = ok, read = ok })
  local twice = raises(provider.adapter, "probe-once", { url = ok, headers = ok, body = ok, read = ok })
  assert(twice, "registering a name twice must raise")

  local missing, why = raises(provider.adapter, "probe-partial", { url = ok, headers = ok, body = ok })
  assert(missing)
  assert(has(why, "read"), why)
end

function T.parse_model_splits_once()
  local scheme_name, name = provider.parse_model("a:b:c")
  assert(scheme_name == "a", scheme_name)
  assert(name == "b:c", name)

  scheme_name, name = provider.parse_model("openrouter:inception/mercury-2.5")
  assert(scheme_name == "openrouter")
  assert(name == "inception/mercury-2.5")

  local bad, why = provider.parse_model(":x")
  assert(bad == nil and type(why) == "string" and why ~= "")
  bad, why = provider.parse_model("x:")
  assert(bad == nil and type(why) == "string" and why ~= "")
  bad, why = provider.parse_model("gpt-4o")
  assert(bad == nil and has(why, "scheme"), tostring(why))

  assert(raises(provider.parse_model, 42))
end

function T.a_real_port_passes_check()
  -- The proof that this subsystem is the other implementation of one contract, not a
  -- second contract: the same world, with `provider.model` where `double.model` was.
  local a = spec.new()
  spec.set_name(a, "tester")
  spec.set_model(a, "openai:gpt-4o-mini")
  spec.add_tool(a, "read", {
    about = "Read a file",
    args = { path = spec.types.string "workspace-relative path" },
    run = function (c) return c.fs.read(c.args.path) end,
  })

  local net = pdouble.net {
    completion(asked { tool_call("c1", "read", '{"path":"a.txt"}') }),
    completion(said("the file says hello")),
  }
  local p = double.world { fs = { ["a.txt"] = "hello" }, ask = true }
  p.net = net
  p.json = json
  p.model = assert(provider.model({ schemes = { openai = { key = "sk-1" } } }, p))

  local problems = port.check(p)
  assert(#problems == 0, table.concat(problems, "; "))

  local r = turn.run(a, "what does a.txt say", p)
  assert(r.stop == "answered", r.stop .. ": " .. tostring(r.reason))
  assert(r.answer == "the file says hello", tostring(r.answer))
  assert(#r.calls == 1)
  assert(r.calls[1].tool == "read")
  assert(#net.sent == 2)

  -- The second request carried the tool result back, addressed by id.
  local second = assert(json.decode(net.sent[2].body))
  local last = second.messages[#second.messages]
  assert(last.role == "tool", last.role)
  assert(last.tool_call_id == "c1", tostring(last.tool_call_id))
end

function T.two_providers_share_nothing()
  local p1 = world { completion(said("one")) }
  local p2 = world { completion(said("two")) }
  local m1 = assert(provider.model({ timeout = 5, schemes = { openai = { key = "sk-a" } } }, p1))
  local m2 = assert(provider.model({ timeout = 9, schemes = { openai = { key = "sk-b", base_url = "https://b.test" } } }, p2))

  local before = deep_copy(m2.settings)
  assert(m1.call(ask_for()))
  assert(deep_eq(m2.settings, before), "a call through one changed the other")
  assert(m1.settings.timeout == 5)
  assert(m2.settings.timeout == 9)
  assert(m1.settings.schemes.openai.key ~= m2.settings.schemes.openai.key)
  assert(#p2.net.sent == 0, "the other port opened nothing")

  assert(p1.net.sent[1].timeout == 5)
  assert(m2.call(ask_for()))
  assert(p2.net.sent[1].timeout == 9)
  assert(p2.net.sent[1].url == "https://b.test/chat/completions", p2.net.sent[1].url)
end

function T.a_json_port_that_raises_is_a_failure()
  -- §3 promises a test that injects a broken encoder to reach the paths a well-formed
  -- body never takes. A broken port is a failure, not a crash.
  local p = world { completion(said("never read")) }
  p.json = {
    encode = function () error("the encoder is broken") end,
    decode = json.decode,
  }
  local m = assert(provider.model({}, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "malformed", err.code)
  assert(err.attempts == 0, tostring(err.attempts))
  assert(#p.net.sent == 0)

  local q = world { completion(said("hi")) }
  q.json = { encode = json.encode, decode = function () error("the decoder is broken") end }
  local m2 = assert(provider.model({ retry = { attempts = 1 } }, q))
  local r2, e2 = m2.call(ask_for())
  assert(r2 == nil)
  assert(e2.code == "malformed", e2.code)
  assert(e2.attempts == 1)
end

function T.jitter_comes_from_the_host_never_from_math_random()
  local p = world { { status = 503 }, { status = 503 }, completion(said("ok")) }
  local rolls, at = { 0, 1 - 1e-9 }, 0
  p.rand = function () at = at + 1; return rolls[at] end
  local m = assert(provider.model({ retry = { attempts = 3, jitter = true } }, p))
  assert(m.call(ask_for()))
  -- 0.5 * (0.5 + 0) and then 1.0 * (0.5 + 0.5), to the edge of the range in both
  -- directions. Nothing here reads a global random source.
  assert(math.abs(p.clock.slept[1] - 0.25) < 1e-9, tostring(p.clock.slept[1]))
  assert(math.abs(p.clock.slept[2] - 1.0) < 1e-6, tostring(p.clock.slept[2]))
  assert(at == 2, tostring(at))

  -- With jitter on and no `p.rand`, the delay stands unjittered rather than reaching
  -- for math.random.
  local q = world { { status = 503 }, completion(said("ok")) }
  local m2 = assert(provider.model({ retry = { attempts = 2, jitter = true } }, q))
  assert(m2.call(ask_for()))
  assert(deep_eq(q.clock.slept, { 0.5 }), table.concat(q.clock.slept, ","))
end

function T.every_status_gets_its_own_code()
  -- §8's table, walked. Four of its rows had no test at all, and three of those four
  -- are the ones a real endpoint produces on a bad day.
  local function status_of(entry, cfg)
    local p = world { entry, entry, entry }
    local m = assert(provider.model(cfg or {}, p))
    local reply, err = m.call(ask_for())
    assert(reply == nil, "a non-2xx must not read as a reply")
    return err, p
  end

  local err = status_of { status = 400, body = '{"error":{"message":"tool schema is wrong"}}' }
  assert(err.code == "malformed", err.code)
  -- The API's own words, when one decoded.
  assert(has(err.message, "tool schema is wrong"), err.message)

  err = status_of { status = 422, body = "" }
  assert(err.code == "malformed", err.code)

  local p
  err, p = status_of { status = 404, body = "" }
  assert(err.code == "not_found", err.code)
  assert(has(err.message, "/chat/completions"), err.message)
  assert(has(err.message, "gpt-4o-mini"), err.message)
  assert(#p.net.sent == 1, "a 404 is deterministic and is not retried")

  err = status_of { status = 413, body = "" }
  assert(err.code == "too_big", err.code)

  err, p = status_of { status = 429, body = "" }
  assert(err.code == "exhausted", err.code)
  assert(err.attempts == 3, tostring(err.attempts))
  assert(#p.clock.slept == 2, "a 429 is retried")

  -- Any other non-2xx: reported, and not retried.
  err, p = status_of { status = 418, body = "short and stout" }
  assert(err.code == "unavailable", err.code)
  assert(err.attempts == 1, tostring(err.attempts))
  assert(#p.clock.slept == 0, "an unknown status is not a reason to ask twice")
  assert(err.body == "short and stout", tostring(err.body))
end

function T.a_refused_or_oversized_transport_is_not_retried()
  -- §8's two corrected rows. A sandbox that refused this host will refuse it again in
  -- half a second, and a response over the cap will be over it again.
  local p = world { { fail = { code = "denied", message = "the proxy refused" } }, completion(said("never reached")) }
  local m = assert(provider.model({}, p))
  local reply, err = m.call(ask_for())
  assert(reply == nil)
  assert(err.code == "denied", err.code)
  assert(err.attempts == 1, tostring(err.attempts))
  assert(#p.net.sent == 1)
  assert(#p.clock.slept == 0)

  local q = world { { fail = { code = "too_big", message = "over the cap" } }, completion(said("never reached")) }
  local m2 = assert(provider.model({}, q))
  local r2, e2 = m2.call(ask_for())
  assert(r2 == nil)
  assert(e2.code == "too_big", e2.code)
  assert(e2.attempts == 1, tostring(e2.attempts))
  assert(#q.net.sent == 1)
  assert(#q.clock.slept == 0)
end

function T.a_broken_adapter_is_a_failure_with_its_name()
  -- An adapter is third-party code the moment a host registers one of its own. Each
  -- of the five functions is called under pcall, and none of them may end the run
  -- with a traceback out of `m.call`.
  local fine_url  = function () return "https://adapter.test/v1/chat/completions" end
  local fine_head = function () return { ["content-type"] = "application/json" } end
  local fine_body = function () return { model = "x", messages = { { role = "user", content = "hi" } } } end
  local boom = function () error("the adapter blew up") end

  local cases = {
    { name = "probe-url",  impl = { url = boom, headers = fine_head, body = fine_body, read = function () end },
      code = "unavailable", attempts = 0, sent = 0 },
    { name = "probe-head", impl = { url = fine_url, headers = boom, body = fine_body, read = function () end },
      code = "unavailable", attempts = 0, sent = 0 },
    { name = "probe-body", impl = { url = fine_url, headers = fine_head, body = boom, read = function () end },
      code = "unavailable", attempts = 0, sent = 0 },
    { name = "probe-said", impl = { url = fine_url, headers = fine_head,
                                    body = function () return nil, "this request cannot be built" end,
                                    read = function () end },
      code = "malformed", attempts = 0, sent = 0 },
    { name = "probe-read", impl = { url = fine_url, headers = fine_head, body = fine_body, read = boom },
      code = "unavailable", attempts = 1, sent = 1 },
    { name = "probe-number", impl = { url = fine_url, headers = fine_head, body = fine_body,
                                      read = function () return 7 end },
      code = "malformed", attempts = 1, sent = 1 },
    -- A table is not yet a reply. Without a stop the turn loop cannot read it and
    -- would spend its whole budget re-prompting a model that never spoke.
    { name = "probe-stopless", impl = { url = fine_url, headers = fine_head, body = fine_body,
                                        read = function () return { text = "" } end },
      code = "malformed", attempts = 1, sent = 1 },
    { name = "probe-oddstop", impl = { url = fine_url, headers = fine_head, body = fine_body,
                                       read = function () return { stop = "banana", text = "" } end },
      code = "malformed", attempts = 1, sent = 1 },
  }

  for i = 1, #cases do
    local c = cases[i]
    provider.adapter(c.name, c.impl)
    local p = world { completion(said("hi")), completion(said("hi")), completion(said("hi")) }
    local m = assert(provider.model({ schemes = { [c.name] = {} } }, p))
    local reply, err = m.call { model = c.name .. ":x", messages = { { role = "user", text = "hi" } } }
    assert(reply == nil, c.name .. " must not read as a reply")
    assert(err.code == c.code, c.name .. ": " .. err.code)
    assert(err.attempts == c.attempts, c.name .. ": attempts " .. tostring(err.attempts))
    assert(#p.net.sent == c.sent, c.name .. ": sent " .. tostring(#p.net.sent))
    assert(has(err.message, c.name), c.name .. " is not named in: " .. err.message)
    -- A broken adapter is deterministic, so it is asked once and not three times.
    assert(#p.clock.slept == 0, c.name .. " was retried")
    -- And the raise itself never reaches the caller.
    assert(not has(err.message, "blew up"), err.message)
  end

  -- The one that works, so the loop above is not passing on a constant.
  provider.adapter("probe-whole", { url = fine_url, headers = fine_head, body = fine_body,
                                    read = function () return { stop = "done", text = "an answer" } end })
  local p = world { completion(said("ignored")) }
  local m = assert(provider.model({ schemes = { ["probe-whole"] = {} } }, p))
  local reply = assert(m.call { model = "probe-whole:x", messages = { { role = "user", text = "hi" } } })
  assert(reply.text == "an answer", reply.text)
  assert(type(reply.calls) == "table" and #reply.calls == 0)
end

function T.no_arguments_is_a_fresh_table_every_time()
  -- A chat completion routinely carries `"arguments": null`, and the json port decodes
  -- a null to one sentinel table shared by the whole process. Handing that out as
  -- `args` lets the first caller that fills in a default poison every later call that
  -- also arrived with no arguments.
  local function two_replies(arguments)
    local choice = { message = { tool_calls = { tool_call("c1", "clock", arguments) } },
                     finish_reason = "tool_calls" }
    local p = world { completion(choice), completion(choice) }
    local m = assert(provider.model({}, p))
    local first = assert(m.call(ask_for()))
    local second = assert(m.call(ask_for()))
    return first.calls[1], second.calls[1]
  end

  local a, b = two_replies(json.null)
  assert(a.args ~= json.null, "the null sentinel was handed out as `args`")
  assert(b.args ~= json.null)
  assert(a.args ~= b.args, "two calls shared one arguments table")
  assert(next(a.args) == nil and a.args_error == nil, tostring(a.args_error))
  a.args.where = "a caller's default"
  assert(b.args.where == nil, "writing into one reply's arguments reached another's")
  -- And the sentinel still encodes as null, which it would not if it had been written to.
  assert(json.encode(json.null) == "null", tostring(json.encode(json.null)))

  -- An endpoint that sent a real decoded object is still taken at its word.
  local c = two_replies({ path = "a.txt" })
  assert(deep_eq(c.args, { path = "a.txt" }), "a decoded object must survive")
  assert(c.args_error == nil)

  -- An empty decoded object is no arguments, and is fresh too.
  local d, e = two_replies({})
  assert(next(d.args) == nil and d.args_error == nil)
  assert(d.args ~= e.args)
end

function T.the_world_is_never_touched_directly()
  -- §10, read off the source the way port.md's own boundary test does.
  local banned = { "os%.getenv", "os%.time", "os%.clock", "os%.date", "os%.execute",
                   "io%.open", "io%.write", "io%.read", "io%.popen", "math%.random", "print%s*%(" }
  local files = { "provider.lua", "provider/json.lua", "provider/openai_chat.lua" }
  for i = 1, #files do
    local f = assert(loadfile(here .. "/../src/" .. files[i]))
    assert(f ~= nil)
    local handle = assert(io.open(here .. "/../src/" .. files[i], "r"))
    local text = handle:read("*a")
    handle:close()
    for j = 1, #banned do
      assert(not text:find(banned[j]), files[i] .. " names " .. banned[j])
    end
  end
end

return T
