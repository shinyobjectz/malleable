# trace — what the run did, as spans, without the tree knowing what OpenTelemetry is

`src/trace.lua`. Contract, not implementation. No code exists yet; the module is written
to this document, and this document is amended before the code diverges from it.

## What it is for

An agent run is a tree: a turn holds steps, a step holds a model call and the tool calls it
asked for, a tool call may hold a question put to a human and may hold a whole child run.
That tree is exactly what a span is for, and until now this tree threw it away — the log
port took flat events, could not fail, and by its own contract may not be read back.

So the run records its own trace, and the record is a **fact about the result**, not a
favour from a sink. Two consumers, one vocabulary:

* **`result.spans`** — the whole tree, in memory, ordered, complete. Nothing drops it. This
  is what an eval reads, what a report prints, and what a test asserts on.
* **`port.log.write`** — the same records, emitted as they happen, for a host that wants a
  live view. Lossy by contract, exactly as before, which is now harmless: the authoritative
  copy is in the result.

A host that wants OpenTelemetry maps the first, the second, or both. This tree does not
know that OpenTelemetry exists, and `src/turn.lua` still names no vendor.

## Vocabulary

A **span** is one named thing that took time, with a start, a duration, a parent and a flat
table of attributes. A **trace** is the tree of them for one run. Both are OpenTelemetry's,
and both were checked against the repo ontology before use, with different answers.

**`trace` fits and was widened.** The repo already defined it as what a call leaves behind —
the ordered record of what was called, which whens held, and how it ended. That is the same
concept with a second subject, so the word was amended to cover both rather than split,
because two nouns here would have become two dashboards.

**`span` collides, and is the fourth recorded divergence.** This repository's `span` is a
candidate phrase of a unit with its bytes on the page — what the map rows and a citation
anchors. OpenTelemetry's span is a timed node in a trace. They are unrelated, and neither
can be renamed: one is on the wire format, the other is the map's whole vocabulary. So
inside this vendored tree **span means OpenTelemetry's span**, recorded here and in
DESIGN.md, and the ontology carries the other meaning as `otel-span` for anything outside
the tree to name it with. Code in the repo that touches both — `ta-harness`, first — must
qualify: `ta_harness::TraceSpan`, never a bare `Span`. The repo ontology carries the
ruling (`monty onto check TraceSpan`), which is what stops somebody later tidying the
qualifier away.

`step` is turn's step, as everywhere outside `gherkin.lua` and `behaviour.lua`
(DESIGN.md, "Four divergences, on purpose").

## The shape

    { id = "7", parent = "3", name = "execute_tool verdict",
      at = 1757462400123, ms = 41, ok = true,
      attrs = { ["gen_ai.tool.name"] = "verdict", ["malleable.gate.answer"] = "allowed" } }

* `id` and `parent` are opaque strings unique within the run; the root has no parent. They
  are **not** OpenTelemetry ids — a 16-byte trace id and an 8-byte span id are the host's to
  mint, because the host is the one that knows whether this run is a child of an HTTP
  request somebody is already tracing. `trace.otlp` takes the ids to use as an argument.
* `at` is milliseconds, from the clock port and nowhere else. A tree that reads a real clock
  cannot be tested; this one runs on a frozen double and every test asserts exact durations.
* `ms` is the duration. A span still open when the run ends is closed by the run with
  `ok = false` and `malleable.unclosed = true`, because a span that never closes is the one
  bug in a tracer that hides every other one.
* `ok` is false when the thing the span names failed. The *reason* is an attribute.
* `attrs` is flat, and its values are strings, numbers or booleans. Same rule as the log
  port, for the same reason.

## The rule this module carries

**No span attribute carries a payload.** Names, counts, sizes, durations, decisions and
codes — never a prompt, never a model's text, never a file's contents, never a tool's
arguments or its output, never a path outside the workspace root.

This is not tidiness. A trace exporter's whole job is to send what it is given somewhere
else, and an agent's arguments are the most sensitive bytes in the process. The rule is
enforced by construction — the recorder takes attributes from a closed vocabulary, and
every entry in that vocabulary is a name, a count, a size, a duration or a term from a
closed set — and by a test that walks a run's spans and fails on any value longer than 200
characters that is not in the vocabulary's string set.

An eval that needs to see what actually came back reads `result.transcript`, which never
leaves the process.

*Test: `a_span_carries_no_payload`, in `scripts/rules-test.lua` beside the others.*

## The spans

| name | opened by | closed when |
| --- | --- | --- |
| `invoke_agent {name}` | the run | the turn stops |
| `malleable.step` | each pass of the loop | the pass ends |
| `chat {model}` | a model call | the reply arrives or fails |
| `execute_tool {tool}` | a tool call | the body answers, raises, or is refused |
| `malleable.gate {tool}` | a question put to the approval port | the answer arrives |
| `malleable.compaction` | the context budget dropping history | it has dropped it |
| `malleable.skill` | the workspace's skills catalogued and the briefing composed | the briefing exists |
| `malleable.server {name}` | connecting a declared server | connected or reported |
| `invoke_agent {name}` (nested) | `agent.delegate` | the child run stops |
| `malleable.beat {name}` | `agent.tick` firing one beat | that run stops |
| `malleable.scenario {name}` | a scenario, under `--verify` or `--eval` | the scenario ends |

**What is built, and what is owed.** Ten of the eleven are recorded and have tests. Four
of them were missing for one reason rather than four, and the reason was worth naming
before it was fixed:

**The recorder's life was the turn's life.** It was built inside `turn.run` and died with
it, so anything happening outside a turn could not be a span at all. The hoist (mar-qghy)
is `turn.recorder`: the factory is handed out, `turn.run` takes `opts.tracer` and
`opts.run_span` and still makes its own when nobody hands it one, and `agent.run` now
opens the run's own span before it catalogues a skill or reaches a server. The loop closes
that span, because what a run amounts to is only known there.

Three consequences worth stating, because each is a rule holding under a change rather
than a line of code:

* **A caller's spans are not the loop's to sweep.** `close_all` takes a floor and closes
  only what was opened at or after the run's own span. Without it the first run to finish
  would mark every span above it unclosed — a tracer reporting its own bookkeeping as a
  fault in the run.
* **`mcp.connect` does not hold a recorder.** It takes `opts.watch(name)`, which answers a
  function taking a boolean and a count. Two scalars, and nothing else can travel; the
  span, the clock and the vocabulary all stay in `agent.run`. A callback that could carry
  a string would be a payload leak with extra steps.
* **A tool body does not hold a recorder either** (mar-gogg). The child run's finished
  spans are left on `ctx.nested`, a plain list the loop hands each call and re-stamps —
  every id renumbered, every parent remapped — before hanging them under the
  `execute_tool` span. Rule 4 withholds `model` and `ask` from a body because those are
  *authority*; a recorder is authority of the same kind, reaching across the whole run. A
  list of spans that have already closed is not.

What is still owed:

* `malleable.compaction` — **not owed at all today.** The turn loop never calls compaction;
  it is a module a host reaches for. There is nothing to record until a run compacts.

And one thing the hoist corrected rather than built. `malleable.skill` was specified as one
span per skill *read*, which was never the truth: `agent.run` **catalogues** skills and
composes a briefing, and a skill's body is read by the skill tool during a step, where it
already is an `execute_tool skill` span. So the span is the catalogue, and its number —
how many procedures this run was briefed on — is the one that says whether the agent had
anything to follow.

`malleable.scenario` is built and is the **join**: every scenario opens one and the whole
run hangs under it, so a trace in a collector is attributable to the sentence in the
feature file that asked for it. Without that, a falling rate says a thing is broken without
saying where.

`invoke_agent`, `chat` and `execute_tool` are OpenTelemetry's own GenAI span names and are
spelled its way, not ours. Everything the harness has that GenAI does not is prefixed
`malleable.`, and the gate is the important one: **how often an agent asks, and what it is
told, is the number nobody else's telemetry has**, and it is a better measure of whether an
agent is safe to leave running than anything in a token count.

## The attributes

Two kinds, and the difference is a rule rather than a preference.

**Adopted.** Where OpenTelemetry's GenAI semantic conventions have a name for something,
that name is used verbatim and is not paraphrased, re-cased or extended:
`gen_ai.operation.name`, `gen_ai.provider.name`, `gen_ai.request.model`,
`gen_ai.response.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`,
`gen_ai.tool.name`, `gen_ai.tool.call.id`, `gen_ai.agent.name`.

**The pin.** `open-telemetry/semantic-conventions-genai`, `main`, read **2026-09-10**,
status *Development*. That repository is where these conventions went when they left
`open-telemetry/semantic-conventions` at **v1.42.0** (June 2026); it has cut no release
since, so v1.42.0 is the last versioned document and `main` is what is actually current.
There is therefore no schema URL to pin against yet, and this paragraph is the pin. The
same three lines are repeated above `trace.ADOPTED` in `src/trace.lua`, because a pin
nobody reading the list can see is not a pin.

Those conventions are **experimental and they move**, and pinning them for the first time
proved it twice:

* `gen_ai.system` is **gone** from the registry, replaced by `gen_ai.provider.name`. It
  was adopted here and never written, so the repair was a rename in the list and a line in
  `turn.lua` that writes the real thing. The provider is the declaration's own prefix —
  `agent.model "openrouter:z-ai/glm-5.3"` says `openrouter` — and a model id with
  no prefix gets **no attribute at all** rather than a default, because which provider a
  bare id belongs to is the host's question and answering it in the loop would be rule 1
  broken by a default instead of by a `require`.
* `gen_ai.response.model` is in the pinned document, is adopted here, and is **not
  written**. The model port's reply carries text, calls, a stop reason and a usage count,
  and no field says which model answered. Writing the attribute would mean widening
  `spec/provider.md`, which is a change to that contract and not a change to this one.
  Owed, and named here so it is not mistaken for an oversight.

A drift is a ticket that amends this file, never a rename in the code. Half-adopting a
convention is worse than not adopting it, because a dashboard that half-works is a
dashboard people believe.

**Minted.** Everything the harness has that the conventions do not. Each is defined in the
repo ontology, each names a closed set or a number, and there is no free-text one:

| | |
| --- | --- |
| `malleable.stop` | one of `answered`, `budget`, `refused`, `error` |
| `malleable.steps` | how many passes the turn took |
| `malleable.budget` | the step budget it was given |
| `malleable.gate.answer` | `allowed`, `edited` (allowed with the person's changes), `refused`, `stopped`, `absent` |
| `malleable.refused_by` | `gate`, `hook` or `error` |
| `malleable.requirement` | `unmet` on a call a requirement stopped before it ran |
| `malleable.unclosed` | true on a span the run had to close for it |
| `malleable.calls` | tool calls in this span's subtree |
| `malleable.act` | what a tool call DID, from the closed set in `spec/command.md`, sorted and comma-joined |
| `malleable.unplaced` | simple commands in this call the vocabulary could not name |
| `malleable.tools` | tools a server offered and this run took |
| `malleable.cached_tokens` | prompt tokens the vendor served from its cache on this chat span, when it said (2026-09-12) |
| `malleable.skills` | skills the workspace and the declaration hold between them |
| `malleable.notes` | notes the run made |
| `malleable.depth` | 0 for a run a person asked for, 1 for a delegate's child, and so on |
| `malleable.dropped` | messages compaction dropped |
| `malleable.undefined` | steps in this scenario that matched no expression |
| `malleable.outcome` | `passed`, `failed`, `undefined`, `broken`, `skipped` |
| `malleable.samples` | under `--eval`, how many times this scenario ran |
| `malleable.rate` | under `--eval`, how many of them passed, as a number in [0,1] |

**These fourteen names are not in the repo ontology, and that is the ruling rather than an
omission.** The obvious move was to define each one in `.monty` and let `monty lint` keep
the table and the code together, and it is wrong for three reasons that compound:

* **The gate is already here.** `trace.allowed` refuses any name outside `ADOPTED` and
  `MINTED`, the rule 8 test walks every span of the whole suite through it, and both run
  under `lua` and under `luajit` with no database anywhere. A second check that agrees
  with the first is not two checks.
* **This tree is published on its own.** It is vendored here and it is also
  `github.com/shinyobjectz/malleable`. A vocabulary that only one embedder can consult is
  not a vocabulary the tree can be checked against, and the table above would then be true
  in this checkout and unenforced in every other.
* **`.monty` is this repository's words.** It governs what Typeaway's own code and pages
  say. A span attribute of a vendored harness is that harness's word; putting it in
  Typeaway's ontology would make the ontology answer for a tree it does not own.

What *does* belong in `.monty` is the collision at the top of this file — `span` — because
that one is a Typeaway word being shadowed, and a Typeaway reader is who gets confused.
It is recorded: `monty onto check TraceSpan`.

## The renderers

`trace.otlp(spans, ids)` answers OTLP/JSON as a string. Pure — a table in, a string out —
and it opens no socket, because that would be a network client and this tree does not have
one (`spec/provider.md` settled the same question for the model). A host posts it, or
ignores it and walks `result.spans` itself.

**What a host actually does with it**, taking this repository as the worked example.
`ta-harness` surfaces the tree as plain Rust — `Run { spans: Vec<TraceSpan>, .. }` — and
exports nothing, for the same reason it declares `Model` as a trait and implements none:
the crate that embeds this tree names no vendor either. The application above it
(`app/src-tauri/src/telemetry.rs`) walks the tree into a live OpenTelemetry SDK, and three
things are the host's there and could not have been anything else:

* **the ids.** A span here is numbered `"1"`, `"2"`, `"3"` within its run. OTLP wants 16
  bytes and 8; the SDK mints them.
* **the parent.** Whether a run is already inside a trace is a fact about the process
  holding the request, not about the run. The host reads its own current context and hangs
  the whole tree under it, or starts a root when there is nothing above.
* **the times.** They are copied, not re-taken. A tree is recorded inside Lua from the
  clock port and arrives after the run is over, so replaying it through a live tracing
  macro would stamp every span with the moment it was replayed and flatten the tree into
  whatever happened to be open. The export sets each span's start and end explicitly.

Span kind is `INTERNAL` on both sides — `trace.otlp` writes `"kind":1` and the Rust export
sets `SpanKind::Internal` — because a run's spans describe what the harness did, not a call
it made to a service that is also being traced. Two renderings of one tree that disagreed
about that would be two traces.

`trace.render(spans)` answers the tree as indented text, for a person at a terminal. It is
what `--verify` prints under `-v` and what a failing eval sample prints in full.

OTLP/JSON is a published wire format, not a vendor. Rule 1 binds `src/turn.lua` and it
still holds: the loop records spans in its own vocabulary and has never heard of this file.

## What it must NOT do

* Open a socket, hold a queue, batch, retry, or sample. A tracer that drops spans under
  load is a tracer that drops the interesting ones; the host owns that decision and has a
  real SDK to make it with.
* Read a clock other than the port's.
* Mint an OpenTelemetry trace id or span id.
* Carry a payload (the rule above).
* Cost anything when nobody is looking. Recording is a table append per span, bounded by
  the step budget and the calls-per-step cap, so a run cannot record unboundedly. There is
  no "tracing off" switch, because a switch means the traced path and the real path are two
  paths and only one of them is tested.

## The tests that would prove it

* every span in **The spans** opens and closes once in a run that reaches it, with a parent
  that is the span it should be under;
* a tool body that raises closes its span with `ok = false` and a reason attribute, and the
  turn goes on;
* a run that stops on budget still closes every open span, and none is marked unclosed;
* a span left open is swept, marked `malleable.unclosed` and failed — tested at the
  recorder, because the loop closes everything it opens on every path it has and the
  run-level tests assert exactly that. What the sweep covers is a caller above the loop,
  or a path added later, that does not close. The sweep's floor is tested too: a span the
  caller opened before handing the recorder over is not the loop's to close;
* on the frozen clock, a scripted run's spans have exact, asserted `at` and `ms`;
* a delegate's child run nests under the `execute_tool` span that started it, at depth 1;
* no attribute in any span of the whole test suite is outside the vocabulary (the rule
  test);
* `trace.otlp` answers a document a real collector accepts — checked against a schema
  vendored beside the test, not against a running collector. **NOT BUILT.** What is tested
  is the document's *shape*: `resourceSpans`, `scopeSpans`, the host's trace id used
  verbatim, and times in nanoseconds. No schema is vendored, so nothing here would catch
  a field a collector requires and this does not write. It is the one promise in this file
  with no test behind it, and it is named here rather than left to be discovered;
* the same run traced twice on the same doubles produces byte-identical spans;
* everything above under `lua` and under `luajit`.
