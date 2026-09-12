# speech — a talker in front, jobs behind

`src/speech.lua`. Contract first; the module is written to this document, and this
document is amended before the code diverges from it.

## What it is for

A person talks to an agent system by voice, or by typing one turn at a time, and the
system has to be fast at two different things at once. It has to answer within a second
or two, the way a person across a table does. And it has to get real work done, which takes
many model calls, tools and minutes, and which no one should sit in silence for.

One agent cannot do both, so `speech` puts two layers in front of the person:

- the **talker**, a small, fast agent that holds the conversation. It answers what it can
  in a sentence, and it hands everything that needs work to a job, saying a short lead-in
  as it does ("Let me look into that.");
- the **jobs**, each an ordinary agent run in the background (a subagent by default),
  with its own budget, tools and gate. A job never speaks. When it ends, its **report**
  goes back to the talker, which tells the person what it found when the person is not
  talking.

The talker and every job are ordinary malleable declarations run by the ordinary turn
loop. `speech` adds the conversation around them: who has the floor, what the talker
remembers, which jobs are running, and when a report may be spoken.

The same conversation runs **realtime** (a microphone and a speaker, reports spoken as
soon as the floor is free, the person able to talk over the reply) or **turn-based**
(typed or recorded turns, a report heard at the next turn). The mode is one option, not
two implementations.

## Where it came from

Hugging Face's speech-to-speech (github.com/huggingface/speech-to-speech, Apache 2.0, read
at 16d7f98 on 2026-09-11) is a cascade: VAD, then speech to text, then a language model,
then text to speech, in four threads joined by queues and served over the OpenAI Realtime
events. Its ideas are rebuilt here in this tree's own terms, and its code is not used:

| speech-to-speech | here |
| --- | --- |
| Silero VAD, Smart Turn, Parakeet, Qwen3-TTS, each a thread | `console/ml/voice.lua` over `silero_vad`, `smart_turn`, `moonshine`, `pocket_tts`: one slice a frame, no threads (spec/ml.md) |
| `CancelScope`: a generation counter every stage checks, so an interruption makes the reply in flight stale | a reply is a coroutine; an interruption stops resuming it. There is nothing to check, because nothing runs that is not resumed |
| the reply streamed to TTS a sentence at a time, with markdown and unspeakable characters stripped | the same, in `speech.sentences` |
| a tool result creates a follow-up response only when it asks for one (`ToolResult(create_response=…)`) | a tool that `ends` a run (spec/turn.md): `hand_off`, `cancel` and `decide` end the reply; `jobs` does not, so the talker speaks what it read |
| `conversation.item.truncate`: after a barge-in the model remembers what the person heard, not what it wrote | `c:cut()`: the reply is kept in the talker's history as far as it was said |
| the voice prompt: brief, spoken, no markdown, transcripts are noisy, one lead-in before a tool, never name a tool | the talker's brief, `speech.BRIEF` |
| `chat_size`: the conversation is kept to the last N items | `keep` |
| the LLM proxy, for "side tasks (summaries, titles, background agents)" run by the client | jobs, run by the harness, under its gates and budgets |

Four things of theirs are not rebuilt: the OpenAI Realtime server (WebSocket and WebRTC),
direct audio input to an audio model, language detection, and speculative turns. The first
three are transports and models this tree has no use for yet. Speculative turns start the
reply before the turn model has decided, and discard it if the person goes on; they are
worth up to a quarter of a second, and they are left as the next latency lever, measured
first (see "What it measures").

Nor is the second layer theirs: they have one model behind the voice. The two-layer
design follows the published ones: DeepMind's talker and reasoner (arXiv 2410.08328),
OpenAI's chat-supervisor pattern (openai/openai-realtime-agents), and LiveKit's
asynchronous tools. From these come four rules, all kept here. The talker says something
before it hands work off. A job's result is told in the talker's words, with its facts
exact. A job's work cannot be cancelled by the person talking over the reply. And a report
is spoken only when the floor is free, several at a time if they arrive together.

## The words

Checked with `monty onto check`; each was free.

- **conversation** — what `speech.new` returns: one person, one talker, its jobs.
- **talker** — the agent that speaks. A declaration like any other, briefed for speech.
- **worker** — an agent a job runs. The **roster** names them.
- **job** — one background run of a worker, started by the talker's `hand_off`. Ids are
  `j1`, `j2`, …, minted in order, never reused.
- **reply** — one run of the talker, started by a turn or by reports.
- **report** — what reaches the talker from a job: it ended, or it asks something.
- **floor** — whether anyone may speak. It is **free** when the person is not speaking,
  no reply is running, and nothing is waiting to be said.
- **cut** — a reply the person spoke over.
- **wait** — what a paused run yields to the conversation that resumes it.

`step`, `budget`, `port`, `transcript`, `gate` and `run` mean what `spec/turn.md` and
`spec/port.md` say they mean.

## The shape of it

```
 person ──words──▶ c:heard(text) ──▶ reply: the talker's run ──▶ sentences ──▶ c:take() ──▶ mouth
   ▲                                  │  hand_off ▼   ▲ reports                               │
   │                                  │         jobs: workers' runs, in the background       │
   └──────────────────────────────────┴───────────────────────────────────────── c:said() ◀┘
```

Everything runs in one Lua thread. A reply and each job is a **coroutine**. A run pauses
only where a port yields, and a port yields only when the host built it to. `c:update()`
resumes every run whose wait is over. So a job's model call, seconds long, sits in the
background while the talker answers the next turn, with no thread and no scheduler outside
this file.

### Waits

A run pauses by yielding one table. `src/wait.lua` is the dialect, shared with the
console's turn clock so the two pumps cannot drift. The conversation understands:

| yield | resumed when | with |
| --- | --- | --- |
| `{ wait = "host", poll = fn, cancel = fn|nil }` | `poll()` answers `true, value` | `value` |
| `{ wait = "sleep", seconds = n }` | `n` seconds have passed on `cfg.clock` (at the next update when there is no clock) | nothing |
| `{ wait = "person", question = q }` | the question is decided (below) | the decision |
| `{ wait = "gate", ... }` | the same as `person` | the decision |
| anything else | the next update | nothing |

`wait.host`, `wait.sleep` and `wait.person` build those tables. `gate` is `person`: a
person at the console. Sleep is in seconds; a frame clock converts with `wait.frames`.
`host` is the console's own wait (console/lib/turn_clock.lua), so a port written for the
console yields the same thing. When a run is abandoned (a cut reply, a cancelled job),
its wait's `cancel` is called under `pcall`, so a request in flight can be stopped.

A port that never yields is legal and makes everything sequential. A job then runs to its
end inside one `update`, which is correct and not concurrent. The yielding ports are the
host's to build. `bin/world.lua` builds them with `yielding = true`: its model requests go
through `curl.start`, a curl in the background that the poll reads when it exits, and its
sleeps yield. `console/ml/talk.lua` and `--talk` use them.

**The delegate world is per run.** `declare.enter` keeps a stack of the worlds that
delegates declared in a feature hand their children. Runs that interleave would read one
another's worlds from it. So the conversation swaps each coroutine's own stack in around
every resume (`declare.swap`), and a delegate inside a job reads that job's world.

## The talker

`speech.talker(opts) -> declaration` builds the default talker, and `cfg.talker` may
instead be any declaration. Either way, the conversation runs a copy with four tools
added. A declared tool of the same name is refused at `speech.new`.

| tool | args | ends the reply | what it does |
| --- | --- | --- | --- |
| `hand_off` | `task` (string), `to` (a worker's name; optional with one worker) | yes | starts a job: the worker runs `task` in the background |
| `jobs` | none | no | the jobs and what each is doing, for the talker to say |
| `cancel` | `job` | yes | stops a job |
| `decide` | `job`, `allow` (boolean), `why` (optional) | yes | answers a job's question with the person's words |

`task` is the whole of what the job is told. A job does not hear the conversation, and
the tool's `about` says so, so the talker writes a self-contained brief.

A reply is `turn.run(talker, prompt, port, { history = …, budget = … })`. The history is
the talker's own earlier messages, turns and reports, cut to the last `keep` messages at
a turn boundary. A reply whose model call ends in `hand_off`, `cancel` or `decide` is
over: those tools `end` the run (spec/turn.md), so nothing is said twice and no second
model call is made. The lead-in the model wrote with the call is what the person hears.

The default talker is `openrouter:z-ai/glm-5.3` with reasoning low and a budget of 3.
This is malleable's default model. It was the fastest of six tried on 2026-09-11 ("What
it measures"). Its brief, `speech.BRIEF`, is said in full in the source and says:

- you speak and the person hears; one short sentence, two if needed; no markdown,
  lists or symbols; transcripts are noisy;
- answer small talk and what you already know yourself; hand anything that needs
  work to a job, and say a short lead-in in the same reply;
- never say a job's work is done before its report comes; tell a report in your own
  words, keeping its facts exact;
- when a job asks, ask the person; call `decide` only with their answer;
- never name a tool.

`opts` for `speech.talker`: `model`, `reasoning`, `budget`, `brief` (replaces the brief)
and `name` (default `"talker"`).

## Jobs

`hand_off` checks its arguments, mints the id, and returns at once. The job starts at
the next `update`: a coroutine running
`run(worker, task, port, { budget = job_budget, depth = 1, id = "j1" })`. `run` is
`cfg.run`, `turn.run` by default; `agent.speech` passes `agent.run`, so a worker's
stores, skills and servers are bound as they are for any run.

A job's port is `cfg.job_world`, a port table or `function (job) -> port`, and
`cfg.world` when none is given. When `relay` is on (the default) its gate is replaced by
the conversation's, which yields `{ wait = "person" }` instead of answering. A job whose
tool asks first is then **asking**. The question becomes a report, and the talker asks
the person. The person's answer returns to the job through `decide`, or through
`c:decide` from the host.

**`decide` needs the person.** It is refused when no turn has been heard since the
question was put. A talker cannot announce a question and grant it in the same reply, and
a report reply can never grant one. Permission stays the harness's (rule 4): the talker
carries the person's words, and the decision records them (`why` defaults to what the
person said).

A job ends one of five ways. Each becomes a report:

| stop | state | the report says |
| --- | --- | --- |
| `answered` | `done` | the answer, cut to 2000 characters keeping both ends |
| `budget` | `spent` | that it ran out of steps, and its last text |
| `refused` | `refused` | why |
| `error` | `failed` | the error, in the run's own words |
| cancelled | `cancelled` | that it was stopped (only if the talker did not stop it itself) |

The job's work is kept whatever happens to the conversation. A cut reply never cancels a
job, only `cancel` does. A job whose coroutine raises is `failed`, with the raise as its
reason. At most `jobs` jobs run at once; `hand_off` beyond that returns a sentence
saying so, and the talker tells the person.

## The conversation

### Turns and replies

`c:heard(text)` is a turn. When the text is empty (a noise, a cough), the only effect is
that the person is no longer speaking. Otherwise any reply still running is cancelled and
kept as a cut. The turn, together with any reports waiting to ride along, becomes the
prompt of a new reply.

The model's text reaches the mouth as it comes back from each model call, not when the
run ends: the talker's model port is wrapped. So a lead-in is heard before the tool it
leads into has run. Text is split into sentences (`speech.sentences`: a stop, a question
or exclamation mark, or a line break, followed by a space), and markdown marks, list
bullets, and characters no voice can say are left out. The history keeps the text as
written.

`c:take()` hands out the next sentence and `c:said()` confirms that it was spoken.
`c:busy()` is true while a reply runs or a sentence waits. `c:pending()` is true while a
sentence waits or is being said: the mouth holds the floor from one sentence to the next,
so a turn cannot end in the moment between two of them.

### Cuts

`c:cut()` is the mouth saying the person spoke over the reply. Barge-in is detected by the
host (`voice.lua`, `barge_in`); the conversation is only told. The reply's run is abandoned
and the sentences still waiting are dropped. The reply's messages go into the history as
far as they happened: the calls it made, their results, and each of its texts cut to the
sentences handed to the mouth, the one being said included. The conversation knows those
because it handed them out (`take`) and was told when each was said (`said`). A job the
reply started stays started. A turn heard while a reply is still running or being said
cuts it first.

`c:hearing()` is the person starting to speak. It holds reports back. It does not cut.

### Reports

A report waits in a queue. With `proactive` on (the default), `update` starts a report
reply when the floor has been free for `settle` seconds (0.6). Every report waiting then
goes into that one reply, marked as coming from the jobs and not from the person. With
`proactive` off, reports wait for the next turn and ride along with it, and `c:deliver()`
starts a report reply at once if the floor is free.

Realtime is `proactive = true`, with a host calling `update` every frame. Turn-based is
`proactive = false`, with a host calling `heard` and then `update` until `busy()` is false.

### The API

| call | answers |
| --- | --- |
| `speech.new(cfg)` | a conversation. Raises for a malformed `cfg` (below) |
| `speech.talker(opts)` | the default talker declaration |
| `speech.sentences(text)` | the speakable sentences of a text, and the rest that is not yet a sentence |
| `c:heard(text)` | nothing |
| `c:hearing()` | nothing |
| `c:cut()` | nothing |
| `c:take()` | the next sentence, or nil |
| `c:said()` | nothing |
| `c:update()` | nothing |
| `c:busy()` | boolean |
| `c:pending()` | boolean |
| `c:deliver()` | true if a report reply started |
| `c:decide(id, allow, why)` | true, or nil and why not |
| `c:cancel(id)` | true, or nil and why not |
| `c:jobs()` | a fresh list of `{ id, worker, task, state, steps }` |
| `c.history` | the talker's messages, read by the host, written only here |
| `c.on(event, data)` | set by the host |

`cfg`:

| field | default | meaning |
| --- | --- | --- |
| `workers` | required | a table of name to declaration, or one declaration (its own name) |
| `world` | required | the talker's port: `model` at least |
| `talker` | `speech.talker()` | a declaration, or the options for the default one |
| `job_world` | `world` | a port, or `function (job) -> port` |
| `run` | `turn.run` | `function (decl, prompt, port, opts) -> result` |
| `clock` | none | `function () -> seconds` |
| `keep` | 40 | messages of history the talker is given |
| `jobs` | 4 | most jobs running at once |
| `job_budget` | 24 | steps a job may take |
| `proactive` | true | reports are spoken when the floor is free |
| `settle` | 0.6 | seconds the floor is free before a report is spoken |
| `relay` | true | a job's question goes to the person through the talker |

An unknown key raises, as in `spec/subagent.md`: a mistyped limit that keeps its default
silently is the bug to prevent.

### Events

`c.on(event, data)`, called under `pcall`. What the host shows and what `talk.lua` prints:

| event | data |
| --- | --- |
| `reply` | `{ text }`: text the talker wrote, as it arrives |
| `done` | `{ stop, steps }`: a reply ended and everything in it was said |
| `cut` | `{ said }` |
| `job` | `{ id, worker, state, steps }`, on every change of state |
| `question` | `{ id, tool }`: a job asks |
| `report` | `{ ids }`: a report reply started |
| `failed` | `{ reason }`: a reply ended in an error |

## The doors

- **Lua.** `agent.speech(cfg)` is `speech.new` with this agent as the one worker when
  `cfg.workers` is absent, and with `agent.run` as `run`.
- **Turn-based, typed.** `malleable --talk agent.lua|agent.feature`: each line is a turn,
  the reply is printed, and an empty line waits for the running jobs and hears their
  reports. `--yes` answers every question itself, instead of relaying it.
- **Realtime, spoken.** `luajit console/ml/talk.lua --agent agent.lua|agent.feature`: the
  microphone, VAD, Smart Turn and Moonshine hear the person, the talker answers, and Pocket
  TTS speaks. `voice.lua` takes the conversation as its `mind` part (spec/ml.md).

## Failure modes

Nothing a model, a person or a world does raises out of `update`. Every row below is a
report, an event or a sentence a model reads.

- **The talker's model fails.** The reply ends `error`; a `failed` event; nothing is
  said, and the turn is kept in the history with no answer.
- **The talker writes no lead-in before `hand_off`.** Nothing is said and the job
  starts. The brief asks for one, and the rate is measured ("What it measures").
- **The talker names a worker not on the roster, or an empty task.** `hand_off` answers
  with the roster or the reason, the run goes on, and the talker says something else.
- **Too many jobs.** `hand_off` says the limit.
- **A job fails, runs out, or is refused.** A report says so.
- **A job's run raises, or its poll raises.** The job is `failed`, with the raise.
- **A question nobody answers.** The job waits, `asking`, until a decision or `cancel`.
  It holds no step while it waits.
- **The person speaks while a report reply is running.** The reply is cut. The report is
  in the history, so the talker knows it was given, and the cut text shows how much the
  person heard.
- **`decide` with no turn since the question.** Refused, with the reason, to the talker.
- **Two jobs run one declaration.** They share its tools' call counts (spec/declare.md,
  `may be called at most`), because the count is kept on the declaration. Stated and not
  fixed.

## What it must not do

- **It must not reach the world except through ports.** No `io`, no `os`, no clock but
  `cfg.clock`, no `math.random`. A test reads the file for them.
- **It must not let a job speak.** Only the talker's text reaches `take`. A job's words
  reach the person only through the talker.
- **It must not approve a job's call.** A decision comes from the person, through
  `decide` after a turn, or from the host.
- **It must not cancel a job on a cut.** Only `cancel` stops one.
- **It must not change a declaration it is given.** The talker is copied before its four
  tools are added; workers are run as they are.
- **It must not require `console/`.** Nothing under `src/` does.

## The tests that would prove it

`test/speech_test.lua`, over scripted models that yield `host` waits for a set number of
polls, so concurrency is tested with no network and no clock.

1. A turn is answered: the reply's sentences come out of `take` in order, `busy` falls.
2. A lead-in is heard before the job starts, and the reply makes one model call.
3. A job runs while the next turn is answered: the talker's second reply finishes while
   the job's model call is still polling.
4. A report is spoken when the floor is free, not while the person is speaking, and two
   reports that end together are one reply.
5. Turn-based: a report waits for the next turn and rides along in its prompt; `deliver`
   speaks it on request.
6. A cut keeps what was said: the history's last text is the said part, the waiting
   sentences are gone, and the job the reply started still runs.
7. A question is relayed, refused to a `decide` in the same reply, and granted after a
   turn; the job's gate receives the decision and the person's words.
8. `jobs` is spoken about: a second model call reads the status.
9. `cancel` stops a job; its wait's `cancel` is called; the report says nothing new.
10. Limits: the fifth job with `jobs = 4` is refused; an unknown worker lists the roster;
    an empty task is refused.
11. A job that fails, one that runs out and one whose run raises each report.
12. History is kept to `keep` at a turn boundary and never splits a call from its result.
13. A delegate inside a job reads the job's world, while another job's world is on the
    stack (`declare.swap`).
14. Sentences: markdown and bullets are dropped, a sentence waits for its stop.
15. A port that never yields still works, sequentially.
16. `speech.new` refuses an unknown key, a missing world, no workers, and a talker whose
    tool is called `hand_off`.
17. The file reaches nothing: no `io`, `os`, `math.random` or `require "console`.

## What it measures

Filled in from the runs below, with the date each was taken. All are live calls to
OpenRouter from the Mac, so the network is in every number.

**Which model talks (2026-09-11).** One talker-shaped call: a voice brief, the `hand_off`
tool, and two prompts, one small talk and one that needs work, three times each. Wall
time per call:

| model | seconds per call | handed the work off |
| --- | --- | --- |
| `z-ai/glm-5.3`, reasoning low | 0.40–0.56 | 3 of 3 |
| `z-ai/glm-5.3-flash`, reasoning low | 0.59–1.82 | 3 of 3 |
| `google/gemini-3.1-flash-lite` | 0.82–1.07 | 3 of 3 |
| `inception/mercury-2.5` | 0.71–2.16 | 3 of 3 |
| `openai/gpt-5.6-luna` (two rounds) | 1.15–2.18 | 2 of 2 |
| `deepseek/deepseek-v4-flash` (two rounds) | 1.95–3.87 | 2 of 2 |

GLM 5.3 with reasoning low was the fastest and the steadiest, so it is the default. Both GLM
models refuse a call with reasoning off ("Reasoning is mandatory for this endpoint").

**Turn-based (2026-09-11).** Fifteen fresh conversations over the notebook agent (then
`example/notebook.feature`, now `console/agents/notebook.feature`), each given one line,
with the yielding world (`world.ports{yielding=true}`):

- Small talk ("hello!", "what's two plus two?"): the first sentence came 0.41–1.00 s after
  the turn, and 5 of 5 were answered by the talker itself, with no job.
- Work ("what do my notes say about the budget?", "add a note that…"): the lead-in came
  0.68–1.93 s after the turn, and 10 of 10 were handed off with a lead-in before the job
  started. In the first `--talk` run, before the `hand_off` description asked for a lead-in
  every time, one of two hand-offs had none.
- One job, from the turn to the first sentence of its spoken report: 3.5 s. The report
  named the note and the figures in it.
- Three model calls yielded side by side took 0.64 s in all, against 0.69 s for one call
  that blocks, so a job's calls do not hold up the talker's.

**Realtime, spoken (2026-09-11).** Three recorded turns played into `voice.lua` as the
microphone, at their own pace, over Silero VAD, Smart Turn v3.2, Moonshine streaming small
and Pocket TTS on the Mac's GPU, with the conversation as the mind. Timed from the end of
the person's speech in the recording:

| turn | heard | first sentence | first audio |
| --- | --- | --- | --- |
| 1, work | +0.39 s | +1.03 s | +1.06 s |
| report of job 1 | – | +0.54 s | +0.59 s |
| 2, work | +1.59 s | +2.18 s | +2.23 s |
| 3, work | +0.42 s | +1.33 s | +1.37 s |
| report of job 2 | – | +0.42 s | +0.46 s |

A report's times are from when its reply started. Turn 2 was heard late because it ended
while the first report was being spoken, and without barge-in the turn waits for the floor.
What the voice said, transcribed back by Moonshine, matched the talker's text.

**What the runs showed that the tests did not.**

- The mouth let go of the floor between two sentences of one reply, and a report started in
  the gap. `c:pending()` was added and `voice.lua` holds the floor while it is true.
- Once, the model cut its own lead-in short, a sentence ending mid-thought before the call.
  It is the model's text, and it was said as written.
- Without barge-in, the start of a turn spoken over the voice is lost: the VAD hears it,
  but the turn is not opened until the voice stops. With barge-in, the reply is cut instead.
- One turn in an earlier run was answered with nothing said. It was not reproduced in the
  runs after it.
- Most of a spoken turn's time is the talker's call. Speculative turns (see "Where it came
  from") are the next thing to measure against it.

## What a job shows of itself (amended 2026-09-11, docs/spec/agent-file.md)

`c:jobs()` lists each job with `calls`, the calls it has made so far, read off the
transcript it sends its model at every call and held in the shape a result holds them
(`tool`, `args`, `step`, `ok`, `refused`); `result` once it ended; `question` while it
asks; and `ended`, the host clock when it ended (0 with no clock). A host shows a job
as an observed scenario from these, and never from its words.
