# The confidence plan: six things the evidence does not yet say, and what closes each

Written 2026-09-12 from the status in `docs/authoring-context.md` and `docs/eval-report.md`.
Each item names the gap, the patch to the harness or the system, the measurement that
closes it, and the ticket. The order is the order of leverage: the first two make every
later number worth more; the third is the one that finds faults before a real run does.
Epic: `mar-38nw`; the tickets are at the end.

## 1. Three samples say "holds", not "how often"

**Gap.** Every real-model rate today is 3 of 3 or 0 of 3. That separates broken from not
broken and nothing finer.

**Patch.**
* `scripts/eval.lua` gains `--samples N` runs in parallel batches (the API allows it; the
  world is doubled so samples are independent), a `--seed` written into the report, and a
  Wilson interval beside each rate, so a `9/10` prints as `9/10 (0.60–0.98)` and the
  reader sees what three samples cannot say.
* A `scripts/eval-all.lua` that runs every `evals/*.feature` that has behavioural
  scenarios at a stated sample count and writes one report file with the date, the model,
  the seed and the intervals, so two runs a week apart compare.
* `docs/eval-report.md` moves from prose tables to that generated file plus prose.

**Measurement.** The author, the author in modes, the notebook and the modes attacks at
20 samples a scenario. A rate with an interval narrower than 0.3 on every scenario is
the acceptance. Cost: about 4 × today's 3-sample runs; roughly an hour of model time.

## 2. One model

**Gap.** GLM 5.3 with reasoning low is the only model any number is about. A different
model reads the briefing, the vocabulary and the refusals differently, and nothing says
by how much.

**Patch.**
* `--model` already exists. `eval-all.lua` takes `--models a,b,c` and reports a table
  scenario × model.
* Two more models that this tree is allowed to use (the rulings: GLM for builds, Mercury
  for small edits, GLM flash by latency): `openrouter:inception/mercury-2.5-preview` and
  `openrouter:z-ai/glm-5.3-flash`. The report names the model on every row.
* What is model-dependent gets a home: a briefing that only one model reads right is a
  briefing to rewrite, and the report's "steps" column per model is the number that says
  which.

**Measurement.** The same four files at 10 samples on three models. Acceptance: the wall's
adversarial scenarios hold on every model (the rail claim is model-free, and this proves
it), and the working scenarios' rates and steps are in the report per model with no
scenario at 0 on a model without a written reason.

## 3. The doubles did not find the process-state hole

**Gap.** Every fault today was found by a real run. The doubles run one agent per
scenario, so a fault that needs two users of a kit, two runs in one process, or a delegate
under a mode is invisible to them until a model stumbles on it.

**Patch.**
* **The doubles get the author.** `evals/wall.feature` already runs the author against a
  notebook file on the doubles with a scripted model. Its Background gains the modes kit
  on both, and scenarios that script exactly the sequence the real author took: move,
  verify the notebook, edit. That scenario would have failed on the first draft of the
  kit. The rule: **every fault a real run finds becomes a doubles scenario first, and the
  fix second** (`docs/spec/behaviour.md` gains the sentence).
* **A kit contract test.** `test/kit_test.lua` gains a check every kit in `library/` and
  `showcase/kits/` passes: two agents use it in one process and each keeps its own state
  through the other's run; a run after a check-only scenario starts clean; a delegate
  under it is stated (allowed or not) in the kit's `about`. A kit that keeps process state
  cannot pass it.
* **The rail list.** `docs/spec/kit.md` gains "what a rail must survive": two users, a
  nested run, a check-only scenario, a beat, a delegate, trust trusted, an always-allow
  policy. Each is a doubles scenario a kit that carries a rail must ship with.

**Measurement.** The modes kit passes the contract test; the first draft of it (kept as a
fixture under `test/fixtures/modes-v1.lua`) fails it on the two-users case. That is the
proof the test finds what the real run found.

## 4. Cost: the edit shapes

**Gap.** The author gets the right result and spends 5 to 24 steps getting there, most of
them on the shape of an `edit` call. The briefing states the shapes and the model still
learns them by refusal.

**Patch.** Reader tolerance, with the refusal sentences as the work list, which the eval
now keeps on every refused or failed call:
* run the author files at 10 samples and collect every `not applied:` and `refused:`
  sentence with the call that drew it; group them;
* for each group either a tolerance in `declare.edit` or the tool (the op inferred from
  which of `line`/`with`/`text` is present; a scenario sent with its keyword lines
  unindented; a doc string sent inline as `doc` when the line takes one) or a sentence in
  the refusal that names the exact call to make instead (`send op = replace with line =
  the old line and with = the new line`);
* the `vocabulary` tool answers by phase on request (`phase = "is"`), cutting what the
  model reads from 8.9 KB to about 3 KB when it is choosing an is line.

**Measurement.** The three editing scenarios of the author in modes, 20 samples: steps in
total down by a third from 68 per 3 samples (about 23 a scenario) with no rate lost. The
refusal count per sample is the second number, and the acceptance is that no refusal
sentence appears in more than one sample without a tolerance or a rewritten sentence.

## 5. The console has not run the author in modes

**Gap.** The seeded kit path and the author in modes verify on the doubles and under the
eval; the console itself, the program a person uses, has not loaded them.

**Patch.**
* A headless console load: `console/main.lua`'s `load_agent` is already a function of a
  directory; `test/console_home_test.lua` gains a test that seeds a scratch workspace,
  loads the author, and asserts `agents/modes.lua` is there and the author's declaration
  has the `mode` tool and its hooks.
* One real session, by hand: open the console on a scratch workspace, ask the author to
  narrow the notebook, watch the move be asked for and the edit land; record the
  transcript under `docs/eval-report.md`.

**Measurement.** The headless test in the suite; the session recorded with its step count.

## 6. Trust turns the rails off

**Gap.** `its trust is trusted` and `it may always call mode` make the `mode` tool run
unasked, and the mode becomes a sentence. Documented, and a person who sets trust for
convenience loses the rail without being told.

**Patch.** A tool may declare that its question cannot be waived:
* `spec.add_tool` accepts `ask = "always"`: the gate asks the person whatever the trust
  and whatever the policy says; `--yes` still answers it (a person's standing yes is a
  person), `trusted` does not. `docs/spec/approval.md` and `docs/spec/turn.md` say it;
  the is line is `the tool {word} always asks first`, a gate line like `asks first`.
* The modes kit's `mode` tool asks always. `evals/modes-trusted.feature` and
  `modes-policy.feature` flip from stating the hole to stating the rail: trusted, the
  move is still asked.
* `cli.problems` warns when a declaration sets `trusted` and has a tool that always asks,
  naming it, so the person reads what trust does not cover.

**Measurement.** The two features pass with the rail held; the wall test shows `always
asks first` is a gate the agent cannot remove; the real-model attack run repeated under
`its trust is trusted` holds at the same rate.

## Order and cost

1 and 2 are one week of script work and a few hours of model time, and everything after
is measured with them. 3 is the one that changes how faults are found and should land
before 4's tolerances, so each tolerance ships with a doubles scenario. 6 is a small
harness change with a spec amendment. 5 is an afternoon. 4 is open-ended and is bounded
by its measurement.

## Status, 2026-09-12 (the same day)

| item | state | what the measurement said |
| --- | --- | --- |
| 6 | closed (`mar-sw4j`) | `evals/modes-trusted` and `modes-policy` hold the rail on the doubles; the wall test refuses removing `always asks first`; the attacks under trust went from three scenarios at 0 of 3 to eight at 3 of 3 once `propose` asked always too, a hole the run found and the plan had not named |
| 3 | closed (`mar-0w7p`) | `evals/modes-rails.feature` failed on its first run against the shipped kit (the Then line read the nested run), the first fault the doubles found before a model; `test/fixtures/modes-v1.lua` fails it on both counts; kits with a hook must name `rails` and `delegate` |
| 5 | closed (`mar-me3l`) | the headless load in the suite; one scripted console session, 66 s, the author's job 6 steps, the move asked and answered by typing, the line landed (`docs/eval-report.md`) |
| 1 | closed (`mar-mdcw`) | intervals beside every rate; `--seed`; `scripts/eval-all.lua` in parallel batches; the nine-sample run of the four files is `docs/evals/2026-09-12.md`: rails at 9/9 with a lower bound of 0.70, the strict route lines at 7/9 |
| 2 | closed (`mar-4woi`) | `docs/evals/2026-09-12-models.md`: the rails hold on all three models; what differs is the loop after a refusal (Mercury retries to the budget, GLM stops) |
| 4 | closed as measured (`mar-2kaz`) | refusals kept per sample, declined edits counted, vocabulary by phase, the mode refusal leads with the move, the briefing carries the runtime: mode refusals to zero, steps level at 436 of 441, the scenario edit still 7/9; the acceptance (a third off the steps) was not met, and the remaining list is in `docs/evals/2026-09-12-briefing.md` |

## Tickets

Created 2026-09-12 with `tk`, under the epic `mar-38nw`:

| item | ticket | depends on |
| --- | --- | --- |
| 1 rates with intervals, batches, a seed, eval-all | `mar-mdcw` | |
| 2 a second and third model | `mar-4woi` | 1 |
| 3 doubles that find rails, the kit contract test | `mar-0w7p` | |
| 4 the cost of an edit: tolerances, vocabulary by phase | `mar-2kaz` | 1, 3 |
| 5 the console runs the author in modes | `mar-me3l` | |
| 6 a question trust cannot waive | `mar-sw4j` | |
