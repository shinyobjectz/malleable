# provider — model providers and adapters

Status: built. `src/provider.lua` exists and meets this contract; `test/provider_test.lua`
is the suite of §11, and it passes under both `lua` and `luajit`. Where the written
specification and the code disagreed, the specification has been corrected here and the
correction is marked **(corrected)** so a reader can see what moved. It is written
against `spec/port.md`, which is the authority on the shapes named here; where the two
disagree, port.md wins and this file is the bug. One deliberate divergence is stated and
argued in §10.

## 1. What it is for

`spec/port.md` defines a model port — `p.model.call(request) -> reply | nil, err` — and
supplies a scripted double for it, so the turn loop can be tested without a network.
`provider` is the other implementation of that same port: the one that turns the
harness's vendor-neutral request into what a real model API expects, sends it, and
turns the answer back into the port's reply shape. It knows about wire formats, tool
schema serialisation, HTTP statuses and retry, and that is the whole reason it exists —
so that nothing above it has to. It still opens no socket: the transport arrives as a
port function, so every behaviour below, including timeouts and rate limits, is proved
in a test with no network, no disk and no subprocess.

## 2. Where it lives

    src/provider.lua                the retry loop, the config, and the model port it builds
    src/provider/openai_chat.lua    the one concrete adapter: the chat-completions wire format
    src/provider/json.lua           the default json port: a pure-Lua encoder and decoder
    src/provider/double.lua         the scripted net double the tests drive it with

**(corrected)** The single file of the original draft became four. The split is not a
convenience: the adapter, the encoder and the double each have to be reachable on their
own — the wire-format tests of §11 call the adapter with no provider and no transport at
all, which is only possible because it is a module rather than a local table.

The last two live under `src/provider/` only because the ports they implement are new.
`spec/port.md` names six capabilities and `src/double.lua` supplies a double for each;
neither knows about `net` or `json` yet. When port.md adopts the two ports of §3, the
encoder belongs beside the other shared modules and the net double belongs in
`src/double.lua` as `double.net`, with the same constructor and the same three rules it
already obeys. Nothing outside this subsystem should be written against their current
paths.

It is not part of the `agent` declaration prefix. A declaration file names a model —
`agent.model "openrouter:z-ai/glm-5.3"` — and never mentions `provider`. The
host builds the model port at start-up and hands it to `turn.run` inside the port table,
in the slot `double.model` occupies in a test.

## 3. Two ports it adds

port.md names six capabilities. A real model port needs two more, and they are written
here in exactly port.md's style, obeying its one convention: **a wrong shape raises, a
wrong world returns `nil, err`**, where `err` is `port.error(which, call, code, message)`
with `code` drawn from port.md's closed set. When port.md adopts them, these two
paragraphs move there and this section becomes a pointer.

### The net port

    p.net.fetch(req) -> res | nil, err

`req` is `{ method = "POST", url = string, headers = { [name] = value }, body = string,
timeout = seconds or nil }`. `res` is `{ status = number, headers = { [lowercase name] =
value }, body = string }`. A completed exchange is a success **whatever the status is**:
a 500 is a response, not an error, and it is provider's job to read it.

`fetch` raises if `req` is not a table or `url` is not a non-empty string. It returns
`nil, err` for everything the world does, with `code` one of `timeout` (the deadline
passed), `cancelled` (the caller's cancel signal fired), `denied` (a sandbox or proxy
refused the connection), `too_big` (a response over the port's own cap) or
`unavailable` (everything else: no route, refused connection, TLS failure, DNS). **The
provider never reads the text of `message` to decide anything** — the code is the whole
signal, and a transport that wants a timeout treated as a timeout must say `timeout`.

`double.net { … }` scripts it, keyed by url or by request-order, with the same three
rules every double in port.md obeys — deterministic, fresh, inspectable. `n.sent` is
the list of requests actually attempted, so a test can assert on the bytes that would
have gone out.

### The json port

    p.json.encode(v) -> string | nil, err
    p.json.decode(s) -> value | nil, err

Codes: `malformed` for input the decoder cannot read, `too_big` for input over a cap.
`encode` fails only on a value it cannot represent (a function, a cycle) and that is
`malformed` too. Both raise only on a wrong argument type. The tree's own pure-Lua
encoder is the default implementation; a test injects a broken one to reach the decode
paths.

**Empty tables.** A Lua encoder cannot tell an empty object from an empty array, so the
json port is not asked to. Provider's rule is that **no request body it builds ever
contains an empty table** — discharged by omission in §6 — and no test needs the
encoder to guess. **(corrected)** The default encoder still has to write *something*
when a host hands it one directly, and it writes `{}`, an object. That is a stated
default, not a guess the provider relies on.

**(corrected) Two more properties the default encoder has, and the provider leans on.**

- **Object keys are emitted in sorted order.** A body that is deterministic as a table
  is then deterministic as a string, which is what lets §11's tests assert on the bytes
  rather than on a table shape. An encoder that emitted `pairs` order would make test 5
  and test 6 flap.
- **JSON `null` decodes to `json.null`, a unique sentinel, not to nil.** A nil in the
  middle of a decoded array puts a hole in it and `#` starts lying — and a chat
  completion routinely carries `"content": null` beside its tool calls. The provider
  type-checks every field it reads, so the sentinel falls out on its own wherever a
  string or a table was wanted.

## 4. Vocabulary: the three results

Everything here is one of three things, and keeping them apart is the point of the
subsystem.

- **A reply.** The API answered and the model produced something: text, tool calls, or a
  refusal. `call` returns `reply, nil`.
- **A refusal.** The model declined. That is a *reply*, with `stop = "refused"` and the
  model's words in `text`. It is never retried, never logged as an error, never turned
  into an `err`. Rule 4's shape, applied one level down: a refusal is an ordinary result
  the model's reader sees.
- **A failure.** No reply was produced: no connection, a non-2xx status, a body that did
  not decode, a shape no adapter recognised. `call` returns `nil, err`.

And the line between raising and returning, from port.md: **a wrong shape raises, a
wrong world returns.** A number where a message list belongs stops the program. An empty
transcript, an unknown model scheme, a 503 or a model that emitted broken JSON comes
back as a value the caller reads.

## 5. The public API

### `provider.parse_model(id) -> scheme, name | nil, message`

Splits `"openrouter:z-ai/glm-5.3"` into `"openrouter"` and
`"z-ai/glm-5.3"` on the **first** colon. Pure; touches no port.

- `id` not a string → raises.
- No colon, an empty scheme, or an empty name → `nil, message`. `"gpt-4o"` on its own is
  not a model id here: the scheme is how an adapter is chosen, and guessing a default
  vendor from a bare name is how a key ends up at the wrong host.
- The name may contain further colons and slashes; only the first colon splits.

### `provider.adapter(name, impl) -> impl`

Registers an adapter under a scheme name (§7). Called by the host at start-up, and by a
test that wants a scheme of its own.

- `name` a non-empty string, `impl` a table carrying the four required functions.
  Anything else raises, naming the field that is missing or wrongly typed.
- Registering a name twice raises. Silent replacement is how one test leaks into the
  next.
- Registration runs nothing. `impl`'s functions are stored, never called — the same
  discipline rule 2 gives a declaration file.

`provider.adapters() -> { "openai", "openrouter", … }` returns the registered names,
sorted, as a fresh list.

### `provider.model(cfg, p) -> m | nil, err`

Builds the model port. `m.call(request)` is exactly port.md's model port and may be put
straight into a port table where `double.model` would go.

- `cfg` is a table or nil; `p` is a port table carrying at least `net` and `json`, and
  using `clock` and `log` when they are there. Wrong types raise, naming what is
  missing: `p.net.fetch` absent raises, because a model port with no transport is a
  wiring bug, not a condition the network can produce.
- Returns `nil, err` with code `unavailable` when `cfg` names a scheme that has no
  registered adapter — a config typo must be reportable at start-up, not fatal.
- `m` holds no connection and no state between calls beyond its config. Two `m`s built
  from two configs share nothing.
- **(corrected)** `m.settings` is a fresh deep copy of the resolved config — the
  defaults filled in, the base url trimmed, the schemes checked. It exists so a host can
  print what it actually wired up, and so test 51 has something to compare that is not
  the internals. Reading or writing it changes nothing about the port.

`cfg`, all fields optional:

| field | default | meaning |
| --- | --- | --- |
| `schemes` | `{}` | per-scheme config, keyed by scheme name (see below) |
| `timeout` | `60` | seconds per attempt, passed to `p.net.fetch`; `request.timeout` overrides it |
| `deadline` | nil | seconds for the whole call, sleeps included; needs `p.clock.mono` |
| `retry` | `{ attempts = 3, base = 0.5, factor = 2, cap = 8, jitter = false }` | §8 |

`cfg.schemes.openrouter`, and every other entry:

| field | default | meaning |
| --- | --- | --- |
| `base_url` | the adapter's default | a trailing slash is trimmed |
| `path` | `"/chat/completions"` | joined to `base_url` |
| `key` | nil | bearer credential, supplied by the host. **Provider never reads an environment variable.** nil means no authorization header is sent, which is what a local endpoint wants |
| `headers` | `{}` | extra request headers; overriding `authorization` or `content-type` raises at build time |
| `params` | `{}` | extra body fields — `temperature`, `max_tokens` — merged into the body; overriding `model`, `messages` or `tools` raises at build time |
| `adapter` | the scheme's own name | which registered adapter to use, so a host can point `"local"` at the OpenAI-compatible shape |

Both raises happen in `provider.model`, not on the first call: a config that cannot be
honoured should fail while the host is still starting up.

### `m.call(request) -> reply | nil, err`

One exchange, retries included. It blocks only in `p.clock.sleep`.

`request` is port.md's: `model` (required, non-empty string), `system` (string or nil),
`messages` (list, required, may be empty), `tools` (list or nil, exactly what
`spec.schema(a)` returned), `timeout` (number or nil).

- Raises if `request` is not a table, if `model` is missing or empty, or if `messages`
  is not a list. That is port.md's sentence, unchanged.
- `messages` empty **and** `system` nil or empty → `nil, err`, code `malformed`, message
  saying there was nothing to send; `p.net.fetch` is not called. port.md permits an
  empty transcript at the port surface, so this cannot raise, but there is no request to
  make and inventing one would put a fabricated message in a real conversation.
- A message with an unrecognised `role`, or a `tool` message with no `id`, → `nil, err`,
  code `malformed`, naming the index. Nothing is sent.
- **(corrected)** So does an element of `messages` that is not a table at all, and a
  message whose `text` is neither a string nor nil. port.md's raise sentence covers
  `messages` itself and stops there; a list whose third element is a number is something
  the harness above got wrong and the caller should be able to report, and reaching into
  it to build a body would be a crash rather than a message.
- **(corrected)** An adapter that raises, or that produces no url, no headers or no
  body, → `nil, err`, code `unavailable`, naming the adapter, with `attempts = 0`. A
  body that cannot be encoded is `malformed`, also with `attempts = 0`. Neither is a
  reason to end the run with a Lua traceback.
- **`request` is read-only.** Nothing reachable from it is added to, removed from or
  rewritten, on the first attempt or any retry. The turn loop keeps that table and
  appends to it; a provider that rewrote a message would corrupt the next step.

`reply` is port.md's shape and nothing more is required of a reader:

    { text = "…", calls = { { id = "c1", tool = "read", args = { path = "a.txt" } } },
      stop = "done" | "calls" | "cut" | "refused", usage = { sent = n, back = n } }

with three additions a caller may ignore:

- `raw_stop` — the vendor's own finish word, verbatim, for a log line.
- `served_model` — what the API said it actually ran, when it said.
- `dropped` — a list of `{ index, why }` for tool calls that could not be delivered
  (§9), absent when nothing was dropped.

`text` is always a string, possibly empty — never nil, per port.md. `calls` is always a
list, empty when the model asked for nothing, so no caller nil-checks before iterating.
`usage` is nil when the API reported none: nil means unmeasured, and zeros would read as
a measurement.

## 6. The wire shapes, for `openai-chat`

The one concrete adapter, registered by default under `openai` (base
`https://api.openai.com/v1`) and `openrouter` (base `https://openrouter.ai/api/v1`).
Same code, different default base.

**The model name sent** is the part after the scheme: `openrouter:z-ai/glm-5.3`
sends `"z-ai/glm-5.3"`.

**Messages.** port.md's three roles, and only these:

| port.md | on the wire |
| --- | --- |
| `{ role = "user", text = … }` | `{ role = "user", content = text }` |
| `{ role = "agent", text = …, calls = { … } }` | `{ role = "assistant", content = text }`, plus `tool_calls` when `calls` is non-empty |
| `{ role = "tool", id = …, ok = …, text = … }` | `{ role = "tool", tool_call_id = id, content = text }` |

**(corrected)** `content` is always present and always a string: a message with no
`text` sends `""`. An absent `content` on an assistant turn is read by some endpoints as
a different thing from an empty one, and `""` is the honest report of what the harness
holds.

`request.system`, when a non-empty string, is prepended as a `system` message. The
harness's word for the agent is `agent`; the wire's is `assistant`; translating between
them is exactly the kind of vendor knowledge port.md forbids in the shapes and locates
here.

`ok` on a tool message is **not** serialised. A failed or refused tool call is already
carried in its `text`, in whatever words the harness wrote. Provider does not compose
that wording and must not learn to: it does not know what a permission refusal reads
like, and a second account of the same event would eventually disagree with the first.

A call in an agent message becomes
`{ id = id, type = "function", ["function"] = { name = tool, arguments = <encoded> } }`,
where `<encoded>` is `p.json.encode(args)`, or the two-character string `"{}"` when
`args` is nil or empty. Arguments travel as a JSON *string*, which is both what the
format asks for and how the empty-table ambiguity is dodged.

**Tools.** `request.tools` is the list `spec.schema` returns —
`{ name, about, args = { { name, kind, required, description }, … }, ask }`. Each entry
becomes:

    { "type": "function",
      "function": { "name": …, "description": <about>,
                    "parameters": { "type": "object",
                                    "properties": { "<arg>": { "type": …, "description": … } },
                                    "required": [ … ] } } }

`kind` maps straight across: `string`, `number`, `boolean`, `object`, `array`. `required`
is omitted when nothing is required. **(corrected)** An argument whose `description` is
the empty string — which is what `spec.lua` stores when a declaration gave none — is
sent with no `description` field rather than with an empty one: absent is absent, and
`"description": ""` is one more empty thing for the model to read past. A tool with no arguments gets
`parameters = { type = "object", additionalProperties = false }` — no empty collection
anywhere in the body, ever, which is the rule from §3.

`ask` is **not serialised**, and a test asserts it appears nowhere in the encoded bytes.
Whether the harness will stop and ask a human is the harness's business; rule 4 says a
tool body cannot approve itself, and a model told which tools are gated will negotiate
with the gate.

No JSON null is ever emitted. Absent is absent.

Known gap, stated rather than hidden: `spec.lua`'s `list` type carries no element type,
so an array argument goes out as `{ "type": "array", "items": { "type": "string" } }` —
strict endpoints reject an array schema with no `items`, and a wrong `items` is more
usable than a rejected request. A list of numbers is therefore described to the model as
a list of strings. The repair is an element type on the declaration surface, not a guess
in the adapter.

**Reading the response.** From `choices[1]`:

| what came back | reply |
| --- | --- |
| `message.content` non-empty, `finish_reason` = `stop` | `text`, `stop = "done"` |
| `message.tool_calls` non-empty | `calls` filled, `stop = "calls"` |
| `message.refusal` a non-empty string | `stop = "refused"`, `text` = the refusal, `calls = {}` |
| `finish_reason` = `length` | `stop = "cut"`, with whatever text and calls parsed |
| `finish_reason` = `content_filter`, no refusal string | `stop = "refused"`, `text = ""` |
| anything else | `stop = "done"`, `raw_stop` carrying the vendor's word |

**(corrected) The rows are a table, not an order, and an order is what the code needs.**
Two of them can match one response at once, so the adapter decides in this sequence and
takes the first that fits:

1. `message.refusal` is a non-empty string → `refused`, its words as `text`, and `calls`
   and `dropped` cleared. A model that declined did not also ask for a tool.
2. `finish_reason` is `content_filter` → `refused`, `text = ""`, calls cleared.
3. `finish_reason` is `length` → `cut`, with whatever text and calls parsed.
4. `calls` is non-empty → `calls`.
5. otherwise → `done`.

**(corrected)** `raw_stop` carries the vendor's finish word whenever there was one, not
only on the "anything else" row: a log line wants to say `tool_calls` or `length` as
readily as it wants to say the word nobody recognised.

A reply may carry both text and calls; both are returned, and `stop` is `"calls"`.
`usage.prompt_tokens` and `usage.completion_tokens` become `usage.sent` and
`usage.back`; `usage.prompt_tokens_details.cached_tokens`, when the API reports it,
becomes `usage.cached` (added 2026-09-12): the part of `sent` the vendor served from its
prompt cache. OpenRouter reports it for every model whose provider caches, and most cache
a byte-identical prefix on their own; the number is how a run knows whether the system
message and the tool list it sends unchanged every step are in fact being cached. Measured
2026-09-12 on the notebook, two samples of three steps in one process: GLM 5.3 flash 76%
of the prompt tokens cached, GLM 5.3 64%, the first step of a process 0%. No cache mark is
sent, and none is needed for these; an explicit `cache_control` mark is what OpenRouter
forwards to Anthropic and Gemini models only, and would be a one-line addition to
`openai_chat.lua` on the system message the day one is used.

`stop = "cut"` with tool calls is returned as it arrived, calls and all. Truncated
arguments are the turn loop's to refuse; provider does not silently drop what the API
sent, because a caller that cannot see it cannot report it.

## 7. The adapter contract

An adapter is four functions and an id. None of them may touch a port, sleep, retry, or
know that retry exists. They are pure, which is what lets the whole wire format be
tested with no transport at all.

    { id           = "openai-chat",
      default_base = "https://api.openai.com/v1",
      url     = function (scheme_cfg)                          -> string end,
      headers = function (scheme_cfg)                          -> { [name] = value } end,
      body    = function (request, model_name, scheme_cfg, ctx)-> table | nil, message end,
      read    = function (status, decoded, raw, scheme_cfg, ctx) -> reply | nil, fail end,
      retry_after = function (headers)                         -> seconds | nil end,  -- optional
    }

**(corrected) `ctx`, and why the draft needed it.** §6 had `body` calling
`p.json.encode` to turn a call's arguments into a JSON string, while this section
forbade an adapter a port. Both are right about what they want and they cannot both be
satisfied by the draft's signature, so the two pure functions the wire format needs are
handed in instead:

    ctx = { io = { encode = function (v) -> string | nil, message end,
                   decode = function (s) -> value  | nil, message end },
            model        = the model name after the scheme,
            url          = where the request is going,
            cfg          = the resolved scheme config,
            decode_error = why the response body did not decode, when it did not }

`ctx.io` is the json port with its error table unwrapped to a sentence and a raise
turned into a returned message, so an adapter still has no port, no error channel to
mishandle and no way to crash the call. The adapter stays pure: given the same
arguments it returns the same table, and a test calls it with a hand-built `ctx` and no
transport at all. `ctx.model` and `ctx.url` are there so a 404 can name the path and the
model it asked for, which the draft's message required and its signature could not
supply.

**(corrected)** `body` may also return `nil, message` — a call whose arguments cannot be
encoded is the case — and `default_base` is how one adapter shape serves two schemes
from two homes.

- `body` returns a table the caller encodes. It is deterministic: called twice on the
  same input it returns deeply equal tables. It places no empty table and no null in the
  result.
- `read` is given the status, the decoded body (nil when it did not decode, with the
  reason in `ctx.decode_error`) and the raw body string. It decides reply-versus-failure
  and nothing else. It does **not** decide
  whether to retry; it returns `fail` as a bare table `{ code, message, retryable }` and
  §8 turns that into a port error.
- `retry_after` reads response headers only. A header carrying an HTTP date rather than
  a number returns nil: provider has `p.clock.mono`, which is not wall time, and doing
  date arithmetic with it would be a guess.

## 8. Failure modes

Every failure is port.md's error table, `{ port = "model", call = "call", code = … ,
message = … }`, with `code` from port.md's closed set, plus four fields a caller may
ignore and a debugger will want:

| extra field | meaning |
| --- | --- |
| `status` | the HTTP status, when there was one |
| `attempts` | exchanges actually tried; `0` when none was |
| `history` | `{ { code, status, delay }, … }`, one entry per attempt |
| `body` | the response body, truncated to 1024 bytes, or nil |

| what happened | code | retried | what the caller sees |
| --- | --- | --- | --- |
| unknown scheme, or no adapter registered for it | `unavailable` | no | the scheme and the registered names |
| empty transcript, unknown role, tool message with no id | `malformed` | no | which index, or that there was nothing to send; `attempts = 0` |
| 2xx body that is not JSON | `malformed` | no | the decoder's message, `body` set |
| 2xx JSON with no `choices`, or an empty `choices` | `malformed` | no | which field was missing |
| 400, 422 | `malformed` | no | the API's own error message when one decoded, else `body` |
| 401, 403 | `denied` | no | that the credential was rejected — **never the credential** |
| 404 | `not_found` | no | the url's path and the model name |
| 413, or a response over the net port's cap | `too_big` | no | the limit that was hit |
| 429 | `exhausted` | yes | attempts made and the last delay waited |
| 500, 502, 503, 504 | `unavailable` | yes | status and attempts |
| any other non-2xx | `unavailable` | no | status and `body` |
| `fetch` returned `timeout`, or `cfg.deadline` passed | `timeout` | yes / no | which of the two, and how long was left |
| `fetch` returned `cancelled` | `cancelled` | no | that the run was cancelled, with the attempt count |
| `fetch` returned `denied` **(corrected)** | `denied` | no | that the connection was refused before it was made |
| `fetch` returned `too_big` **(corrected)** | `too_big` | no | that the response was over the transport's own limit |
| `fetch` returned any other code, returned a response with a non-numeric status, or **raised** | `unavailable` | yes | the port's own message |

**(corrected)** The draft swept `denied` and `too_big` into the last row, where they
would have been reported as `unavailable` and retried three times. §3 names both as
codes the net port returns and §10 forbids retrying a deterministic failure: a sandbox
that refused this host will refuse it again in half a second, and a response that was
over the cap will be over it again. Each keeps its own code and is not retried.

**(corrected)** The per-attempt timeout handed to `fetch` is `min(request.timeout or
cfg.timeout, what is left of cfg.deadline)`. A 60-second attempt inside a 5-second
deadline is a 5-second attempt; sending the longer number would make the deadline a
suggestion.

Rules that hold across all of them:

1. **A refusal is not a failure.** It is a reply with `stop = "refused"`. Nothing about
   it is retried or reported as an error. This is the distinction the subsystem exists
   to keep, and two tests guard it.
2. **The credential never leaves.** `message`, `body` and anything handed to
   `p.log.write` are compared against the configured `key` and the authorization header
   value before they are returned; if the API echoed the key into an error body, that
   body is replaced by a note saying it was withheld. This is a comparison against the
   configured secret, not a search for anything that looks like one.
3. **A broken port is a failure, not a crash.** Every port call is made under `pcall`. A
   `fetch` that raises becomes `unavailable`; a `decode` that raises becomes
   `malformed`; a `sleep` that raises ends the retry loop and returns the failure
   already in hand, with the sleep's error appended to the message. **(corrected)** The
   same holds for an adapter, which is third-party code the moment a host registers one
   of its own: `url`, `headers`, `body`, `read` and `retry_after` are all called under
   `pcall`, and an adapter that raises or answers with something that is not a reply is
   a failure with the adapter named, never a traceback out of `m.call`. **(corrected)**
   "Not a reply" is checked at `stop`: a `read` that answers with a table carrying no
   `stop`, or a `stop` outside the four words of §5, is `malformed` with the adapter
   named, not a reply with a hole in it. `turn.lua` reads a reply with no `stop` as an
   answer it could not understand and re-prompts, so passing one on would spend a whole
   step budget on a model that never spoke. A `body` that refuses with `nil, message`
   names the adapter too: a host that registered its own has to be able to tell whose
   sentence it is reading.
4. **`attempts` is truthful.** One exchange is `attempts = 1`. `0` appears only when no
   request was made at all, so a caller can tell "we never asked" from "we asked and it
   went wrong".
5. **The last failure wins; `history` keeps the rest.** Three 503s then a 401 returns
   the 401 with four history entries. **(corrected)** An entry's `delay` is the wait
   that followed *that* attempt, so it is nil on the last one and on any attempt the
   loop decided not to sleep after — a reader can see where the waiting stopped and
   why.
6. **`message` is one sentence, safe to show a model**, per port.md: no stack, no host
   absolute path, no secret, no raw HTML.

**Retry and backoff.** Only a retryable failure is retried, at most `retry.attempts - 1`
further times. The delay before attempt *n* (n from 2) is
`min(base * factor^(n-2), cap)`; with `jitter` true it is multiplied by
`0.5 + 0.5 * p.rand()`, where `p.rand() -> [0, 1)` is an optional host function — no
`rand`, no jitter, and never `math.random`. Jitter is off by default so that a test
asserting a sleep sequence has a sequence to assert. A `retry-after` header, when
`retry_after` returns a number, replaces the computed delay, still clamped to `cap`.

Before each sleep, two checks:

- **The deadline.** With `cfg.deadline` set and `p.clock.mono` present, if
  `mono() + delay` would pass the deadline, provider stops and returns the failure in
  hand with code `timeout`, saying the deadline was reached, rather than sleeping into
  it.
- **Whether it can sleep at all.** `p.clock.sleep` may return `nil, err` with
  `unavailable` — plain Lua has no way to wait, and port.md is explicit that a host
  without one gets an honest refusal rather than a busy loop. When sleep is
  unavailable, provider **stops retrying** and returns the failure it has, with a
  message saying retry was not possible here. It does not spin, and it does not retry
  immediately, which would be three failed requests in a millisecond.

`retry.attempts = 1` disables retry entirely, and then the clock is never touched.

Defaults are three attempts, a 60-second per-attempt timeout and a half-second base:
quick retries against a fast model, not a long wait dressed up as resilience.

## 9. Tool-call arguments: a model mistake is not a call failure

Tool-call arguments arrive as a JSON *string the model wrote*. It is routinely
malformed, and that is a model problem, not a transport one.

When `p.json.decode` cannot read an argument string, the call is still delivered:
`args` is an **empty table** — port.md promises a table, and a caller that indexes it
must not blow up — with `args_error` set to the decoder's message and `args_raw` set to
the exact string the model sent. The exchange is a success and `call` returns a reply.
The turn loop is then positioned to send a tool result back saying the arguments did not
parse and let the model try again, which is the behaviour that makes a harness usable.
Ending a run because a model emitted a stray comma would not be.

An argument string that decodes to something that is not a table — a bare number, a
string, `true` — is treated identically, with an `args_error` saying an object was
expected. An empty argument string, or one that is only whitespace, decodes to an empty
table with no error: nothing is handed to the decoder, so there is nothing for it to
complain about.

**(corrected)** `arguments` is not always a string. An endpoint that already decoded it
and sent an object is taken at its word and the object becomes `args` — there is nothing
to parse and no mistake to report. `arguments` absent entirely is an empty table with no
error. **(corrected)** So is an `arguments` with nothing in it, however it arrived —
absent, `{}`, or JSON `null`, which the json port decodes to its shared null sentinel —
and the empty table handed back is a **fresh** one every time. Handing out the sentinel
itself, or any table a second call also holds, lets the first caller that fills in a
default write into a value another call is still reading. Any other type is an empty table with an `args_error` naming the type and no
`args_raw`, because there are no bytes the model wrote to hand back to it.

A tool call with no `id`, or no `function.name`, is **dropped** and recorded in
`reply.dropped`. It cannot be answered — a tool result is addressed by id — so passing
it on would build a transcript the API rejects on the next step.

## 10. What it must NOT do

- **It must not require `turn.lua` or `spec.lua`.** It receives the tool list as data in
  the shape `spec.schema` returns, never calls a tool body, never asks whether a call is
  allowed, and never reads `ask` except to refuse to serialise it. It may require
  `src/port.lua` for `port.error` and the code set, and nothing else in the tree.
- **It must not touch the world directly.** No `os.getenv`, `os.time`, `os.clock`,
  `os.date`, `io.*`, `math.random`, no socket, no global writes. Everything arrives
  through `p`. A test reads the source for those names, the way port.md's own boundary
  test does.
- **It must not read an environment variable for a credential.** The host supplies
  `key`. A provider that can find a key by itself can send one somewhere the host did
  not intend.
- **It must not mutate `request`**, on any path, including retries.
- **It must not print, and must not write a file.** `p.log.write` or nothing — and
  nothing is the default, because port.md is right that a port narrating itself produces
  a second account that eventually disagrees with the caller's. Provider logs only what
  a caller cannot see: the attempt number and the delay of a retry.
- **It must not decide what a failure means for the run.** Whether a timeout ends the
  turn, whether a refusal stops the loop, whether a `"cut"` reply is usable — all
  `turn.lua`'s. Provider reports; it does not conclude.
- **It must not retry anything deterministic** — a refusal, a `malformed`, a `denied`, a
  `not_found`. Retrying a deterministic failure turns one bad request into three.
- **It must not fall back.** No second model, no shortened prompt, no dropped tool list,
  no compaction. Those change what the model is asked and are visible decisions that
  belong where a reader is looking for them.
- **It must not stream, batch or cache.** One request, one response. Streaming is a
  later, separate adapter function, and nothing in this contract may assume it exists.
  (The upstream's own prompt cache is another matter, noted 2026-09-12: the system message
  and the tool list are the stable prefix of every request a run makes, and `turn` sends
  them first and unchanged, so a vendor that caches a prefix caches them. An explicit
  cache mark on the system content is a request field OpenRouter forwards only to Anthropic
  and Gemini models, which this tree does not use; it is not sent, and the day one of those
  models is used it is a one-line addition to `openai_chat.lua`, with the mark on the
  system message only.)
- **It must not name an agent, a tool or a workspace.** It is vendor-aware by design and
  application-blind by rule.

**The stated divergence.** port.md's boundary section says a port "must not run a
policy. No retries, no backoff", and locates those in the turn loop. This spec keeps
transport retry here, and the argument is this: re-sending the *same* request after a
connection failure, a 429 or a 503 changes nothing the turn loop can observe except how
long the call took, whereas every policy port.md is protecting — a fallback model, a
shorter prompt, a different tool list, a pause between turns — changes what the model is
asked and must stay visible above. The narrow reading of port.md is available in one
line, `retry = { attempts = 1 }`, and a host that wants retry in the turn loop instead
gets exactly the port.md behaviour by setting it. If that argument is rejected, the
repair is to move §8's loop into `turn.lua` and leave provider as adapter plus one
exchange; nothing else in this file changes.

## 11. The tests that prove it

**(corrected)** They do, in `test/provider_test.lua`, and they pass under both `lua` and
`luajit`. All fifty-one below are there under the names they are given here, plus seven
the draft assumed and did not list. **(corrected again, on a verification pass)** Four
of the seven are new, 55 to 58, and they were written because a second reading of §8's
failure table and §9 found six of §8's rows and one of §9's sentences with no test at
all behind them. Two of the four found a real defect; two found only that correct code
was unguarded, which is the outcome a coverage test is allowed to have.

52. `the_world_is_never_touched_directly` — the three source files are read for
    `os.getenv`, `os.time`, `os.clock`, `os.date`, `os.execute`, `io.open`, `io.write`,
    `io.read`, `io.popen`, `math.random` and `print`, and name none of them.
    *Adversarial: §10's boundary, checked the way port.md checks its own.*
53. `a_json_port_that_raises_is_a_failure` — the broken encoder §3 promises: an `encode`
    that raises is `malformed` with `attempts = 0` and nothing sent, a `decode` that
    raises is `malformed` with `attempts = 1`. *Adversarial: rule 3 of §8, at the one
    place every adapter reaches the world.*
54. `jitter_comes_from_the_host_never_from_math_random` — with `jitter` on, `p.rand`
    rolled at 0 and at just under 1 gives 0.25 and 1.0 against a 0.5/1.0 sequence; with
    `jitter` on and no `p.rand`, the delay stands unjittered. *Adversarial: the rule is
    "no `rand`, no jitter", not "no `rand`, use the global one".*
55. `every_status_gets_its_own_code` — §8's status table walked: 400 and 422 are
    `malformed` and carry the API's own words, 404 is `not_found` naming the path and
    the model, 413 is `too_big`, 429 is `exhausted` and is retried, and 418 is
    `unavailable`, asked once, with the body kept. *Adversarial: four of those rows had
    nothing behind them, and 404, 400 and 429 are what a real endpoint produces on a bad
    day. Found no defect.*
56. `a_refused_or_oversized_transport_is_not_retried` — the two rows §8 corrected: a
    `fetch` that says `denied` or `too_big` keeps its own code, is asked once and is
    never slept on. *Adversarial: the draft would have swept both into `unavailable` and
    retried them three times, and the correction had no test. Found no defect.*
57. `a_broken_adapter_is_a_failure_with_its_name` — each of `url`, `headers`, `body` and
    `read` raising, `body` refusing with a message, and `read` answering with a number,
    with a table that has no `stop`, and with a table whose `stop` is a word nobody
    knows; each is a failure naming the adapter, with `attempts` 0 before a request went
    out and 1 after, never retried, and the adapter's own raise text never reaching the
    caller. A working adapter closes the test, so the loop cannot be passing on a
    constant. *Adversarial: §8's rule 3, which is the only thing standing between a host
    that registers its own adapter and a traceback out of `m.call`. **Found a defect**:
    a table with no `stop` was passed through as a reply, and `turn.lua` reads that as
    an unreadable answer and spends its whole budget re-prompting a model that never
    spoke. A `body` that refused with a message also came back without naming whose
    sentence it was. Both repaired.*
58. `no_arguments_is_a_fresh_table_every_time` — a tool call whose `arguments` is JSON
    `null` gives an empty `args` with no error, a different table on every call, and one
    the caller may write into. *Adversarial: `"arguments": null` is routine, and the json
    port decodes a null to one sentinel table shared by the whole process. **Found a
    defect**: that sentinel was handed out as `args`, so the first caller to fill in a
    default poisoned every later call that also arrived with no arguments — across every
    provider built in that process — and left `json.null` encoding as an object rather
    than as null. `args` is now a fresh table whenever there is nothing in it, however
    it arrived. Repaired.*

Every test builds a world from port.md's doubles plus a scripted net double: canned
responses from a queue, `double.clock` for sleeps (which advance a frozen clock and
record durations in `c.slept`), `double.log` for lines. The net double is `pdouble.net`
in `src/provider/double.lua` until port.md adopts the port and it can become
`double.net` — see §2. No network, no disk, no subprocess, no real clock. Adversarial
tests are marked; they are the ones worth writing first.

**The wire format** — adapter functions only, no transport at all

1. `a_request_becomes_a_body` — one user message produces a body whose `model` is the
   name after the scheme and whose `messages` is one entry with role `user`.
2. `a_system_prompt_leads` — `system` set produces a leading system message; `""` and
   nil both produce none.
3. `the_tool_list_survives` — two tools from `spec.schema` produce two function entries
   in declaration order, each with its `about` as the description.
4. `only_required_arguments_are_required` — a tool with one required and one optional
   argument produces `required` containing only the first.
5. `no_empty_collection_reaches_the_wire` — a tool with no arguments, and a request with
   no tools, produce an encoded body containing neither `[]` nor `{}` where a shape is
   meant. *Adversarial: the assertion is on the encoded string, so an array-versus-object
   slip is caught where a table comparison would miss it.*
6. `the_model_is_never_told_about_the_gate` — `ask = true` on a tool appears nowhere in
   the encoded bytes. *Adversarial: rule 4.*
7. `the_body_is_deterministic` — `body` called twice on one request returns deeply equal
   tables.
8. `an_agent_message_carries_its_calls` — an agent message with two calls round-trips
   with arguments as JSON strings, and empty args become the string `"{}"`.
9. `a_tool_result_is_addressed_by_id` — a tool message becomes `tool_call_id`, and its
   `ok` field appears nowhere in the body. *Adversarial: provider must not narrate a
   failure the harness already worded.*
10. `config_cannot_overwrite_the_request` — `params.temperature` reaches the body;
    `params.model` raises at build time; `headers.authorization` raises at build time.
    *Adversarial.*

**Reading a reply**

11. `plain_text_is_done` — a text completion returns `stop = "done"`, the text, and
    `calls` as an empty list, not nil.
12. `tool_calls_are_calls` — a tool-call response returns `stop = "calls"` with id, tool
    name and decoded args.
13. `text_and_calls_together` — a response with both returns both, `stop = "calls"`.
14. `a_refusal_is_a_reply` — `message.refusal` returns `stop = "refused"` with the
    refusal in `text`, empty `calls`, and a nil second return. *Adversarial: the test
    also asserts `c.slept` is empty and `n.sent` has one entry — a refusal is never
    retried.*
15. `a_filtered_reply_is_still_a_reply` — `content_filter` with no refusal string returns
    `stop = "refused"` and `text = ""`, never nil. *Adversarial.*
16. `a_cut_reply_keeps_its_calls` — `finish_reason = "length"` with a tool call returns
    `stop = "cut"` and the call still present.
17. `usage_absent_is_nil` — no usage in the response yields `usage = nil`, not zeros.

**Broken model output**

18. `broken_arguments_are_not_a_failure` — a tool call whose `arguments` is `'{path: '`
    returns a reply, with `args` an empty table, `args_raw` the exact string and a
    non-empty `args_error`. *Adversarial: the whole point of §9.*
19. `valid_json_of_the_wrong_type` — `arguments` of `"42"` is an argument error, not a
    number passed through. *Adversarial.*
20. `empty_arguments_decode_to_empty` — `arguments` of `""` gives an empty table and no
    error.
21. `a_call_with_no_id_is_dropped` — it is absent from `calls`, present in
    `reply.dropped`, and the reply is still a success. *Adversarial.*
22. `an_html_error_page_is_malformed` — a 200 whose body is HTML returns `malformed`,
    `attempts = 1`, and the truncated body in `err.body`. *Adversarial: a proxy's error
    page is the common real case.*
23. `a_2xx_with_no_choices_is_malformed` — and is not retried.
24. `an_empty_choices_list_is_malformed` — well-formed JSON, empty array. *Adversarial:
    empty input.*

**Failure and retry**

25. `two_failures_then_a_reply` — 503, 503, 200 returns the reply, and `c.slept` is
    `{ 0.5, 1.0 }` with jitter off.
26. `retries_run_out_and_say_so` — three 503s with `attempts = 3` returns `unavailable`,
    `attempts = 3`, `history` of three.
27. `a_rejected_credential_is_not_retried` — 401 returns `denied`, `attempts = 1`,
    `c.slept` empty.
28. `retry_after_is_obeyed` — 429 with `retry-after: 2` sleeps 2, not 0.5.
29. `retry_after_is_clamped` — 429 with `retry-after: 999` sleeps `cap`. *Adversarial: a
    header must not be able to park the harness for a quarter of an hour.*
30. `the_deadline_is_not_slept_through` — `cfg.deadline` set so the second sleep would
    pass it returns `timeout` naming the deadline, and the second `sleep` was never
    called. *Adversarial.*
31. `no_sleep_means_no_retry` — a clock whose `sleep` returns `unavailable` returns the
    first failure, `attempts = 1`, and the message says retry was not possible. It does
    not spin and it does not re-send immediately. *Adversarial: port.md says plain Lua
    cannot wait, so this is the default host, not an exotic one.*
32. `transport_codes_are_honoured` — `fetch` returning `timeout` is retried; returning
    `cancelled` is not, and comes back as `cancelled`. *Adversarial: the branch is on the
    code, never on the message text.*
33. `a_transport_that_raises_is_a_failure` — a `fetch` that calls `error()` returns
    `unavailable` and does not propagate the raise. *Adversarial: a broken port must not
    end the turn.*
34. `a_string_status_does_not_crash` — `fetch` returning `{ status = "200" }` returns
    `unavailable`, not an arithmetic error. *Adversarial.*
35. `a_sleep_that_raises_ends_the_loop` — the failure in hand comes back with the sleep
    error appended, and no further attempt is made. *Adversarial.*
36. `the_last_failure_wins` — 503, 503, 503, 401 returns `denied` with four history
    entries. *Adversarial.*

**Secrets and hygiene**

37. `the_key_never_comes_back` — with `key = "sk-test-123"`, a 401 whose body echoes the
    key returns an error in which the key appears in no field, and `err.body` says it was
    withheld. *Adversarial: the one that matters most.*
38. `the_key_is_never_logged` — nothing written to `double.log` across a full retry
    sequence contains the key. *Adversarial.*
39. `the_request_is_not_mutated` — a deep copy of `request` taken before the call is
    deeply equal after a success and after a three-attempt failure. *Adversarial: the
    retry path is where a rewrite would hide.*
40. `no_credential_no_header` — with `key = nil` the request carries no authorization
    header at all, rather than an empty one.

**Wiring**

41. `an_unknown_scheme_is_reported` — `provider.model { schemes = { nope = {} } }`
    returns `unavailable` listing the registered adapters; it does not raise.
42. `a_bare_model_name_is_refused` — a request with `model = "gpt-4o"` returns
    `malformed`, rather than guessing a vendor. *Adversarial: guessing would send a key
    to a host the config never named.*
43. `wrong_types_raise` — `m.call("hello")`, `m.call { model = "" }` and
    `m.call { model = "openai:x", messages = 3 }` all raise, per port.md's sentence.
44. `an_empty_transcript_sends_nothing` — `messages = {}` with no system returns
    `malformed`, `attempts = 0`, and `n.sent` is empty. *Adversarial: empty input.*
45. `an_unknown_role_is_named` — `role = "developer"` returns `malformed` naming the
    index and the role; nothing is sent. *Adversarial.*
46. `a_tool_message_needs_an_id` — a tool message with no id returns `malformed` naming
    the index. *Adversarial.*
47. `registering_runs_nothing` — registering an adapter whose every function raises, then
    never calling it, passes. *Adversarial: mirrors rule 2 — declaring is not running.*
48. `an_adapter_cannot_be_replaced` — registering a name twice raises; an impl missing
    `read` raises naming `read`.
49. `parse_model_splits_once` — `"a:b:c"` splits on the first colon; `":x"` and `"x:"`
    return `nil, message`; `42` raises.
50. `a_real_port_passes_check` — `port.check` on a world whose `model` is
    `provider.model(cfg, p)` returns no problems, and the same turn-loop test that runs
    against `double.model` runs unchanged against it with a scripted `double.net`.
    *Adversarial in the useful sense: it is the proof that this subsystem is the other
    implementation of one contract, not a second contract.*
51. `two_providers_share_nothing` — a call through one leaves the other's config
    untouched, and neither holds a connection.
