# compaction — context budget and compaction

`src/compaction.lua`. Status: implemented, `test/compaction_test.lua` passing under
both `lua` and `luajit`.

## What it is for

A long run keeps appending to one list of messages, and every model call sends that
whole list, so sooner or later the run stops fitting in the model's context window.
This subsystem answers three questions about that list: how big is it, is that too
big, and which stretch of it can be folded into one short note so the run continues.
It never throws work away silently — the fold is always a replacement, always leaves
the system prompt and the newest exchanges alone, and always reports what it did.

## The vocabulary

Four words, used exactly this way throughout.

- **history** — the list of messages a model call sends. A Lua array, index 1 upward,
  no holes.
- **estimate** — a number of context units this subsystem invents. It is not tokens.
  It is a deterministic function of the text, honest about being an approximation, and
  stable enough that the same history always crosses the same threshold.
- **fold** — replacing a contiguous run of messages with one message.
- **digest** — the message a fold leaves behind: prose describing what those messages
  contained, written by the model, marked `digest = true`.

## The world it takes through a port

Compaction is pure except for one call. It asks a model to write the digest, and it
gets the model the same way `turn.lua` does — through the port table the host supplies
(DESIGN.md rule 1). The whole of what it uses is `spec/port.md`'s model port:

    port.model.call(request) --> reply | nil, err

`request` is `{ model = <id>, system = <the instruction>, messages = <one message>,
max_output = <a number> }`. `reply` is `{ text = "…", calls = {…}, stop = "…" }`. A
model that declines says so in the reply, as `stop == "refused"`. A failure is
`nil, err`, where `err` carries port.md's closed `code` set; the codes compaction
distinguishes are `"timeout"` and — treated as one category, "the call failed" —
everything else.

Two accommodations, so a host that wired the earlier draft of this contract still
works: `port.model.complete` is used when `port.model.call` is absent, and `err.kind`
is read when `err.code` is absent. Neither is the contract; both are a fallback.

**The model id.** port.md's model port requires a non-empty `request.model`, and
compaction may not read the agent declaration to find one. So it takes the id as an
argument: `limits.model`, falling back to `port.model.id` when the host hangs one
there. When the port exposes `call` and neither is set, `compact` **raises** — a
compaction that could never make its one call is a wiring mistake, not weather.

**The role vocabulary.** port.md calls the model's own turn `"agent"`; the wider world
calls it `"assistant"`. Compaction reads both as the same thing, because a harness
using one word and a compaction knowing only the other would silently never fold
anything. A tool result's link to its call is read as `call_id`, or as `id` when
`call_id` is absent, which is the field port.md uses.

Everything else compaction needs is an argument. It takes no clock, no filesystem, no
logger, no random source.

## The message shape it reads

Compaction reads five fields and copies every message whole, so a host that carries
extra fields on a message loses nothing.

| field | type | meaning to compaction |
|---|---|---|
| `role` | string | `"system"`, `"user"`, `"assistant"`, `"tool"`. Any other string is carried but treated as an ordinary foldable message. |
| `text` | string or nil | the body. nil is legal and estimates as empty. |
| `calls` | list or nil | tool calls the assistant asked for; each has an `id` (a string). |
| `call_id` | string or nil | on a `"tool"` message, the call it answers. |
| `pin` | boolean or nil | the host's own "never fold this". |

Compaction never writes to a message it was given. Every returned history is a new
array whose unfolded entries are the *same table references* as the input's — shallow
reuse, no deep copy, no mutation.

## What is never folded

Four protections, checked in this order, and all four hold in every returned history.

1. **The system prompt.** Every message with `role == "system"`, wherever it sits.
2. **Anything pinned.** `pin == true`.
3. **The recent tail.** The last `keep_recent` messages (default 6).
4. **A tool result the model has not yet seen.** Derived from position alone, with no
   cooperation from `turn.lua`: every message from the last `"assistant"` message
   onward is unseen, because no model call has happened since it was appended. If the
   history contains no assistant message at all, nothing is folded.

A fifth rule is structural rather than a protection: **a fold boundary never splits a
call from its result.** If the span would end between an assistant message carrying
`calls` and a `"tool"` message answering one of them, the span shrinks until it does
not. An orphan `"tool"` message whose call was folded away is a bug, not a trade-off.

## The public API

Nothing in this module is a method; the module table is the only handle.

    local compaction = require "compaction"

### `compaction.defaults`

A table, read for its values and never modified by the module.

    { window = 128000, headroom = 0.75, target = 0.5, keep_recent = 6, attempts = 2 }

- `window` — estimated units the model accepts.
- `headroom` — fold when the estimate exceeds `window * headroom`.
- `target` — fold enough that the estimate lands at or under `window * target`.
- `keep_recent` — messages at the tail that are never folded.
- `attempts` — model calls allowed per compaction before giving up.

`defaults` holds those five. A `limits` table may carry a sixth key that has no
default and is not a budget: `model`, the model id the digest request carries (see
"The world it takes through a port"). It is a string or nil.

A `limits` argument anywhere below is a table of these keys or nil. Missing keys take
the default. **An unrecognised key raises**, because a misspelt `keep_recents` that
silently did nothing is the worst outcome available. `window` must be a number above
zero; `headroom` and `target` must be numbers in `(0, 1]` with `target <= headroom`;
`keep_recent` a whole number at or above zero; `attempts` a whole number at or above 1;
`model` a string. Violations raise.

### `compaction.estimate(value) --> n, info`

Returns a non-negative integer estimate for any Lua value, and a table
`{ truncated = boolean, depth = number, nodes = number }`.

The rule, stated so a test can pin it: a string estimates as `ceil(len / 4) + 1`; a
number or boolean as 2; nil as 0; a table as the sum of its keys and values plus 2 per
entry; a message estimates as its fields plus a flat 4 for the role framing. A
function, userdata or thread estimates as 1 and does not raise, because a host is
allowed to hang a callback on a message.

It never raises and it never hangs. Cycles are handled by a visited set: a table
already counted on the current path contributes 0 **and sets `truncated = true`**,
because the number that comes back is a floor and the caller has to be able to tell.
Depth beyond 12 and node count beyond 100000 stop the walk the same way; the number returned is still
a number, still monotone in what it did see, and the caller can tell it is a floor.

`compaction.estimate` is the whole of the estimator's public surface. There is no
`set_estimator`, no pluggable tokeniser, no unit table. If the host has a real
tokeniser it computes its own budget and passes a `window` scaled to these units.

### `compaction.check(history, limits) --> report`

Pure. Measures without changing anything. Raises on a bad `history` (not a table, a
table with a hole, a table with a key that is not a positive whole number, or an entry
that is not a table) or bad `limits`. Never returns nil.

The history's estimate is the sum of its messages' estimates. That makes it monotone:
appending never lowers it.

`report` is a table:

    {
      messages  = 42,      -- how many messages
      estimate  = 118400,  -- the whole history
      window    = 128000,
      limit     = 96000,   -- window * headroom
      goal      = 64000,   -- window * target
      over      = true,    -- estimate > limit
      protected = 9,       -- messages the four protections hold back
      foldable  = 33,      -- messages eligible, ignoring span rules
      floor     = 20100,   -- estimate of the protected messages alone
      truncated = false,   -- an estimate hit a walk cap
    }

`over == false` is the only answer a caller needs on the common path. `floor` is the
number that matters when compaction cannot help: if `floor > limit`, folding
everything foldable still will not fit, and the caller is looking at a window that is
structurally too small rather than a history that grew.

An empty history returns a report with `messages = 0`, `estimate = 0`, `over = false`.
It is not an error to ask about nothing.

### `compaction.plan(history, limits) --> plan` or `nil, why`

Pure. Chooses the span to fold and does not touch the model. Raises on bad arguments,
exactly as `check` does. Returns `nil, why` — `why` a lowercase reason string, never a
table and never an error — when there is nothing sensible to do.

    {
      from      = 2,      -- inclusive index into history
      to        = 27,     -- inclusive
      count     = 26,
      total     = 61,     -- the length of the history this plan was made from
      removed   = 88000,  -- estimate of the span
      after     = 30400,  -- projected estimate with an empty digest in its place
      messages  = { ... },-- the span, a new array of the same message tables
      report    = { ... },-- the report `check` would have returned
    }

`total` is there so `apply` can refuse a history that has moved on without holding a
reference to the history itself.

The span is the **oldest** eligible run. A fold replaces a contiguous stretch, so a
span may only contain foldable messages: a protected message inside the range ends the
run. `plan` walks the maximal contiguous runs of foldable messages oldest first, and
inside a run grows `to` forward from `from` — snapping to the boundary rule — until
either `after <= goal` or the run ends. The first run that yields two messages or more
is the plan. Folding the oldest is the whole point: the newest exchanges are the ones
the model is still reasoning about.

A run that yields only one message is skipped rather than folded, and so is one that
cannot be folded without orphaning a tool result; `plan` moves to the next run. Only
when no run at all yields two messages does it give up.

The `why` values, and they are the complete list:

| `why` | when |
|---|---|
| `"not over budget"` | `report.over` is false. |
| `"nothing to fold"` | every message is protected. |
| `"one message to fold"` | no run of foldable messages yields a span of two: folding one message into one message is churn, not compaction. The same answer covers the rarer case where the only candidate span cannot be folded without orphaning a tool result. |
| `"a single message is larger than the window"` | some one message estimates above `window`. Folding cannot fix that; the caller must truncate or fail the run. |

`nil, "not over budget"` is the normal answer most of the time and is not a failure.

### `compaction.prompt(plan, limits) --> messages, words`

Pure. Builds the message list handed to the model. Separated out so the prompt is
testable with no model at all.

Returns a new list: one `"system"` message instructing the model to write a factual
digest of a conversation span, and one `"user"` message carrying the span rendered as
plain text with a role label per message and a line per tool call. The instruction
states the three things the digest must keep — decisions made, files and identifiers
touched, and work still outstanding — and states a length ceiling in words. `words`
comes back as a second return value so `compact` can size `max_output` without parsing
its own prompt. Raises if `plan` is not a plan table.

The ceiling: `allowance` is `goal - plan.after`, floored at zero — the units the digest
may spend and still land at the goal — capped at half of `plan.removed`, converted at
1.5 units a word, and clamped to `[20, 800]`. It is monotone in the goal: a tighter
goal never asks for more words. `limits` is optional; without it the goal comes from
`plan.report`.

`compact` moves the system message into `request.system`, because that is where
`spec/port.md` carries it, and sends the second message as the request's one message.

The rendering never includes a function value and never calls `tostring` on a table
field; a non-string field renders as its type name in angle brackets.

### `compaction.apply(history, plan, digest) --> new_history` or `nil, why`

Pure. Replaces `plan.from .. plan.to` with one message:

    { role = "user", digest = true, text = digest, folded = 26 }

`digest` must be a string. A digest that is empty or only whitespace returns
`nil, "the digest is empty"`. A digest whose estimate is not smaller than
`plan.removed` returns `nil, "the digest is not smaller than what it replaces"` —
compaction that grows the history is worse than no compaction, and it is refused here
rather than detected later.

Raises if `digest` is not a string — `compact` turns a non-string reply into `""` before
it gets here, so this raise is only ever a caller's own mistake. Raises if `history` is
not the list the plan was made from — checked by `plan.total` against the length, and by
identity of the messages at `from` and `to`. A plan applied to a history that has
moved on is a programmer error, not a world error, and it is loud.

A digest is an ordinary foldable message. A second compaction folds an old digest and
the exchanges after it into one new digest, so digests do not accumulate. Only a
digest inside the chosen span is affected; compaction never rewrites a digest in place.

### `compaction.compact(port, history, limits) --> new_history, report`

The one entry point that reaches the world. Runs `plan`, `prompt`, the model call, and
`apply`, in that order.

On success returns the new history and a report with two extra fields:
`compacted = true` and `folded = <count>`. The report's `estimate` is the estimate
**after** the fold, so a caller can compare it against `limit` without measuring again.

On any outcome that leaves the history alone it returns **the original history table,
unchanged and by identity**, and a report with `compacted = false` and
`why = "<reason>"`. It does not raise for anything the world did. It raises only for a
bad `port` (not a table, or no `model.call`/`model.complete` function), for a `call`
port with no model id to send, and for the bad `history` and `limits` cases above — a missing port is a wiring mistake, not weather.

Returning the original table by identity is deliberate: `new_history == history` is a
one-line test for "nothing happened", and a caller who assigns the result unconditionally
is always correct.

`compact` never calls itself and never calls a tool. The model call it makes is not
subject to compaction — a prompt built from a plan is bounded by construction, and a
compaction that triggered a compaction is a loop with no floor.

## The failure modes

Every row is a returned failure with the history unchanged, unless the row says raise.

| what happens | what the caller sees |
|---|---|
| the history fits | `plan` returns `nil, "not over budget"`; `compact` returns the same history and `why = "not over budget"`. |
| the model call fails | `why = "the model could not be reached: <message>"`, after `attempts` tries. The run continues over budget; the caller decides whether to stop. |
| the port itself raises | the raise is caught and reported like any other failed call, `why = "the model could not be reached: <what it raised>"`. A transport that throws must not take the run down through compaction. Lua's own `<chunk>:<line>: ` prefix is trimmed off the front of what it raised, because the chunk is a host absolute path and port.md's promise of a message safe to show a model does not reach a raise; a prefix that does not look like a source location is left alone. |
| the model call times out | a timeout is the same as any other failed call except the reason names it: `why = "the digest timed out"`. Retried within `attempts` like the others, because a timeout is the failure most likely to pass on a second try. |
| the model refuses | `stop == "refused"` in the reply, or `code == "refused"` on an error: `why = "the model would not write the digest"`. **Not retried** — a refusal repeated is a refusal, and the second call buys nothing but latency. |
| the model returns an empty or whitespace digest | `why = "the digest is empty"`. Counts as a failed attempt and is retried within `attempts`. |
| the model returns a digest as big as the span | `why = "the digest is not smaller than what it replaces"`. Not retried; a model that ignored the length ceiling once will ignore it again. |
| the model returns something that is not a string | treated as an empty digest. A port that hands back a number is a broken port, but compaction is not the subsystem that gets to end the run over it. |
| everything is protected | `why = "nothing to fold"`, and `report.floor` says how much the protections cost. |
| one message alone exceeds the window | `why = "a single message is larger than the window"`. Compaction cannot fix this and does not try to truncate the message — truncating a tool result would hand the model a lie. |
| the fold succeeded and the history still does not fit | returns the folded history with `compacted = true` **and** `over = true`. Success and sufficiency are separate facts and are reported separately. |
| a cyclic table on a message | the estimate completes with `truncated = true` in the report. No hang, no stack overflow. |
| a history with a hole, or a non-table entry | raises. A malformed history is the caller's bug. |
| an unknown key in `limits` | raises, naming the key. |
| `port` is nil or has no `model.call` | raises. |
| the port has `model.call` and no model id is given | raises, naming `limits.model`. |
| `apply` given a history the plan does not match | raises. |

Two rules govern that table and are worth stating on their own, because every future
addition has to pick a side:

- **A bad argument raises. A bad world returns a failure.** A misspelt limit, a
  missing port, a plan applied to the wrong history: those are code that is wrong now
  and should stop. A model that timed out, refused, or wrote a useless digest: those
  are Tuesday, and the run keeps going.
- **A failure never half-applies.** There is no state in which some of a span was
  folded. `apply` builds a new list or returns nil.

## What it must not do

- **It must not name a provider, an HTTP library, a clock or a filesystem.** DESIGN.md
  rule 1 covers `turn.lua`; this module holds to it identically. No `io`, no `os`, no
  `require` of anything but the standard library.
- **It must not read the agent declaration.** It never sees `spec.lua`'s table, never
  reads `tools`, `hooks`, `budget` or `system`, and never calls `spec.schema`. The
  system *message* it protects is a message in the history, found by its role.
- **It must not run a tool, or ask permission.** Compaction is bookkeeping the harness
  does to itself. It is not an action the user approves and it is never gated by `ask`;
  routing it through the approval gate would put a modal dialog between the agent and
  its own memory.
- **It must not decide the turn is over.** It reports `over` and `why`. Ending a run is
  `turn.lua`'s, under rule 5.
- **It must not mutate its arguments.** Not the history, not a message, not `limits`,
  not `defaults`.
- **It must not persist anything.** No session file, no cache of digests. What it
  returns is the whole of what it produced.
- **It must not print.** No `print`, no write to a stream. If the host wants to see a
  compaction it reads the report.
- **It must not implement a tokeniser** or ship a vocabulary file. The estimate is a
  formula in a dozen lines and stays one.
- **It must not re-enter itself.** No compaction of the digest prompt, no recursive
  `compact` when the first fold was not enough. One `compact` call folds one span; a
  caller that wants two calls two.

## The tests that would prove it

Adversarial ones are marked **[adv]**. All run with no network, no disk and no
subprocess: the model port is a table literal whose `call` returns whatever the
test says, including nothing.

1. `an_empty_history_is_not_over_budget` — `check({})` returns a report with zero
   messages, zero estimate and `over == false`, and does not raise.
2. `the_estimate_is_deterministic` — the same history estimated twice gives the same
   number; two histories differing by one character do not always differ, but a history
   twice as long estimates at least 1.5 times as much.
3. `the_estimate_is_monotone` — appending a message never lowers the estimate.
4. **[adv]** `a_cyclic_message_estimates_and_returns` — a message whose field points at
   itself estimates to a finite number with `truncated == true`, in bounded time. This
   is the test that stops a stack overflow reaching the host.
5. **[adv]** `a_function_on_a_message_does_not_raise` — a message carrying a closure
   estimates without error.
6. `a_history_under_headroom_plans_nothing` — `plan` returns `nil, "not over budget"`.
7. `the_system_prompt_survives_every_fold` — after a compaction of a long history whose
   first message is the system prompt, that exact table is still at index 1, by identity.
8. **[adv]** `a_system_prompt_in_the_middle_survives` — the same, with the system
   message at index 9 rather than 1, so an implementation that special-cases index 1
   fails here.
9. `a_pinned_message_survives` — `pin = true` at a foldable position is still present
   after compaction.
10. `the_recent_tail_survives` — the last `keep_recent` messages are present, by
    identity and in order, after compaction.
11. **[adv]** `an_unseen_tool_result_is_never_folded` — a history ending in
    assistant-with-calls followed by two tool results is compacted; both tool results
    are still there. This is the protection that keeps the model from being asked to
    reason about a call whose answer vanished.
12. **[adv]** `a_history_with_no_assistant_message_folds_nothing` — a long history of
    only user messages returns `nil, "nothing to fold"`, because nothing in it has been
    seen by a model.
13. **[adv]** `a_fold_never_orphans_a_tool_result` — over many generated histories
    (assistant/tool interleavings at varied lengths), no returned history contains a
    `"tool"` message whose `call_id` is not answered by a surviving assistant `calls`
    entry. Property-style, run over a fixed list of shapes so it is reproducible.
14. `the_oldest_span_is_the_one_folded` — `plan.from` is the first foldable index, not
    a later one.
15. `the_fold_replaces_with_one_message` — the returned history is shorter by exactly
    `plan.count - 1`, and the message at `plan.from` has `digest == true` and
    `folded == plan.count`.
16. `a_digest_is_foldable_again` — compacting twice produces one digest, not two.
17. **[adv]** `an_empty_digest_is_refused` — the port returns `text = ""`; the history
    comes back by identity with `why == "the digest is empty"`.
18. **[adv]** `a_whitespace_digest_is_refused` — the port returns three newlines; same
    outcome. An implementation that checks only for the empty string fails here.
19. **[adv]** `a_digest_bigger_than_the_span_is_refused` — the port returns a wall of
    text; the history is unchanged and the reason says the digest is not smaller.
    Without this, compaction can make the problem worse.
20. **[adv]** `a_refusal_is_reported_and_not_retried` — the port returns
    `err.code == "refused"` and counts its calls; the count is 1 and `why` names the
    refusal. The same holds for a reply carrying `stop == "refused"`.
21. **[adv]** `a_timeout_is_retried_then_reported` — the port returns
    `err.code == "timeout"` twice with `attempts = 2`; the count is 2, the history is
    unchanged, and `why` names the timeout.
22. `a_transient_failure_then_success_compacts` — the port fails once and succeeds on
    the second call; the history is folded and `compacted == true`.
23. **[adv]** `a_non_string_digest_is_treated_as_empty` — the port returns
    `text = 42`; refused, no raise, no `tostring` sneaking a number into the history.
24. `a_missing_port_raises` — `compact(nil, h)` and `compact({}, h)` both raise, and
    the message names the missing `model.call`.
25. **[adv]** `a_plan_applied_to_a_different_history_raises` — build a plan, append to
    the history, apply; it raises rather than folding the wrong span.
26. **[adv]** `an_unknown_limit_key_raises` — `{ keep_recents = 4 }` raises and the
    message names `keep_recents`. The typo that silently does nothing is the failure
    this test exists to prevent.
27. `bad_limit_values_raise` — `headroom = 0`, `headroom = 2`, `target > headroom`,
    `keep_recent = -1`, `attempts = 0`, `window = 0` each raise.
28. **[adv]** `a_single_message_over_the_window_is_named` — one message estimating
    above `window` yields `nil, "a single message is larger than the window"`, and the
    message is not truncated.
29. **[adv]** `a_span_of_one_is_not_folded` — a history where only one message is
    eligible returns `nil, "one message to fold"` rather than replacing a message with
    a digest of itself.
30. `still_over_budget_is_reported_as_success_and_over` — a history far above the
    window compacts, and the report has `compacted == true` and `over == true` at once.
31. `the_floor_is_reported_when_nothing_helps` — with `keep_recent` large enough to
    protect everything, `report.floor > report.limit` and `why == "nothing to fold"`.
32. `nothing_is_mutated` — a deep snapshot of the history, its messages and the
    `limits` table taken before `compact` is equal after it, on both the success and
    every failure path.
33. `the_unchanged_history_is_returned_by_identity` — on every failure path,
    `new_history == history` is true.
34. `surviving_messages_are_the_same_tables` — a returned history's unfolded entries
    are identical tables to the input's, not copies.
35. **[adv]** `compact_calls_the_model_once_per_attempt_and_no_tool` — a port whose
    `model.call` counts calls and whose every other field raises if it is so much as
    indexed; compaction finishes having touched only `model.call`. This is the
    test that catches compaction reaching for a filesystem, a clock, or a tool.
36. **[adv]** `compact_does_not_re_enter` — a port whose `call` calls
    `compaction.compact` again on a large history; the outer call still returns, and
    the inner one is the caller's business, not an infinite descent through the outer.
37. `the_prompt_is_buildable_with_no_model` — `prompt(plan)` returns a two-message list
    naming the span's roles, with no function values and no address-like strings from
    `tostring` on a table.
38. `the_module_names_no_vendor` — read `src/compaction.lua` as text and assert it
    contains none of `io.`, `os.`, `socket`, `http`, `require "` beyond the standard
    library. The sibling of `core_names_no_vendor`, applied here.

Nine more the implementation added, because each of them was a thing the code could get
wrong that none of the 38 would have caught:

39. `the_estimate_reads_every_lua_value` — the formula, pinned value by value.
40. `a_very_deep_table_is_truncated_not_overflowed` — a 400-deep chain reports
    `truncated` with `depth <= 12` rather than blowing the stack.
41. `an_unreachable_model_is_reported_after_every_attempt` — three attempts, three
    calls, and the reason carries the port's own message.
42. `a_port_that_raises_is_a_failure_not_a_crash` — a transport that throws is weather.
43. `a_model_port_without_an_id_raises`, and naming it in `limits.model` is enough.
44. `a_malformed_history_raises` — a string, a non-table entry, a hole, a string key.
45. `apply_refuses_a_digest_that_is_not_a_string`, and `prompt` refuses a non-plan.
46. `the_prompt_names_a_smaller_ceiling_for_a_tighter_goal` — the ceiling is monotone
    in the goal.
47. `the_scripted_model_double_folds_a_history` — the whole of `compact` against
    `double.model` from `spec/port.md`, proving the request shape that port validates:
    a model id, the instruction as `system`, one message, and no tools offered.

Four more the verification pass added, each covering a documented behaviour that had no
test and could therefore have been absent:

48. **[adv]** `the_port_vocabulary_is_read_as_the_same_thing` — a history written in
    spec/port.md's own words (`role == "agent"`, a tool message keyed by `id`) is over
    budget, has foldable messages, folds, orphans nothing, and holds back the tail after
    the last agent turn. A compaction that knew only `"assistant"` and only `call_id`
    folds nothing here, and orphans results if it does fold.
49. `the_earlier_port_shape_still_works` — the two accommodations exercised: `complete`
    where `call` is absent carries the digest and is not asked for a model id, and
    `err.kind` is read as `err.code` is, timeout retried and refusal not.
50. **[adv]** `a_reply_that_is_not_a_table_is_a_failed_call` — a bare string, a number
    and a boolean each come back as a failed call with the history unchanged.
51. **[adv]** `a_raise_does_not_carry_a_host_path_into_the_report` — a port that throws
    is reported by what it said and not by where it said it; a raise with no message at
    all is still a stated failure; and a message that merely contains a colon survives
    whole.
