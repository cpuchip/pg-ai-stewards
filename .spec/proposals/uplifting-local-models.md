# Uplifting Local Models: the Elastic Rig, the Watcher, and the Rest

**Status:** DRAFT for wrestling + council (2026-06-28). Not ratified. No code yet.
**Authors:** Michael (intent + the rest-as-restricted-toolset insight) + Claude (synthesis).
**Frame:** the substrate practicing its own creation cycle — *work → rest → tidy → continue.*

---

## 1. The problem (the actual goal)

Small local models — **qwen especially** — *spiral to dead* on real autonomous tasks. They lose the
thread, loop, overflow context, leave 100+ tools open they'll never call, fail to recover from a bad
turn, and burn a whole run going nowhere. We have rich scaffolding for **our** work (covenant, oracles,
the Hinge, memory) — but the local models the substrate dispatches into long tool-loops have *no
keeper.* They go in alone and come out dead.

The goal of this arc is to **uplift them** — make qwen / gemma / the local fleet reliable enough on real
tasks that we can trust them with autonomy — through three composable mechanisms. This is not three
features; it's one discipline (context + model hygiene) with three faces.

> The spiral isn't a model-quality problem we can only fix by buying a bigger model. It's largely a
> *hygiene* problem — bloated context, tool overload, no breadcrumb back, wrong model for the phase.
> Those are fixable from the substrate side.

## 2. What we already know (the steering inputs — don't re-derive these)

- **Models don't manage their own context.** CT2.4 (#143/#136, settled this session): the write/curate
  side of agent-driven context management = **zero** usage. The reactive engram engine carries context
  management *because it's out-of-band.* → favor a **dedicated out-of-band keeper** over asking the
  active model to be disciplined. It already failed that test.
- **Tool overload kills small models.** The 159-tool gather hung gemma-12b for 30 min
  (`reference_local_moe_for_substrate`). The tool-shelf (#284) folds tools, but its cooldown is a *blunt
  timer* — the model never folds its own.
- **The rig is already an elastic controller, unused.** llama-chip exposes `/v1/models` (discover),
  `/api/ensure` (load-by-need), `/api/profile`, `/api/unload`, `/api/unload-all` — and the config comment
  literally says they exist *"so the substrate can load what a work phase needs."* The substrate just
  doesn't drive them yet; it only speaks OpenAI at the rig.
- **`reveal` is cheap and reversible.** A folded tool is one `reveal_tool(name)` away. This is the safety
  net that makes aggressive folding safe (see §4).

## 3. Three mechanisms (the stages)

### Stage 1 — The elastic rig: a llama-chip-aware provider kind

The substrate gains a provider *kind* that speaks llama-chip's control API, not just OpenAI:
- **Auto-discover** models via `GET /v1/models` (no env archaeology; #256).
- **Scale up on demand:** before a dispatch, `POST /api/ensure` the target model is resident; the rig
  loads it if no healthy slot serves it (it already unloads an overlapping-GPU slot to make room).
- **Scale down:** unload idle slots after a quiet window.
- **`model_aliases` integration:** an alias already maps → (provider, model); the llama-chip provider
  adds "…and make sure it's loaded first." Right model for the phase — don't make qwen do vision; ensure
  gemma+mmproj when a vision turn is queued.
- **UI/CLI:** add providers + keys + models from the cockpit; see what's available vs loaded; manual
  load/unload/profile. (Folds in #256.)

**★ The tension we must resolve (we just lived it):** substrate-managed auto-scaling **collides with a
human experimenting on the rig.** This hour, general-workspace had the rig on Nemotron; the substrate
would have fought them for the GPUs. → A self-scaling provider needs a **lease/mode**: a "manual hold"
that pauses substrate auto-scaling while someone experiments (and a way for the substrate to claim it
back). The lane-coordination we did by hand is the human protocol; the automated one needs a lock.

### Stage 2 — The watcher: a context-janitor shadowing a live session

A cheap, fast, **big-context** model (Nemotron — fast MoE, ~1M ctx so it holds the whole active session)
shadows one or more live sessions:
- Reads the active session's messages + revealed-tool state.
- Decides what's stale/foldable: superseded search results, completed sub-task scaffolding, tool schemas
  unused for N turns, redundant context.
- Emits **fold-ops** the substrate executes (fold tool X; compact message Y via the engram path; drop a
  superseded result). **One watcher : many watched** — amortize the slot across sessions.

**★ The safety unlock — reversibility.** Because `reveal` is cheap, the watcher folds **aggressively**:
a wrong fold costs *one re-reveal*, not a derailed task. "Fold-aggressive-because-reversible" removes the
"what if it folds something I needed" fear that would otherwise force timid, useless folding.

**Open design choices (wrestle):**
- New agent kind, or **grow the reactive engram engine** a fold-emitting head? (It already reads messages
  out-of-band — the watcher might be its next organ, not a new animal.)
- Propose vs impose? Reversibility argues **impose** (and let the active model re-reveal). But a
  propose-mode could feed Stage 3.
- "Stale" by heuristic (age / supersession / completed-subtask) first; learned heuristic later.

### Stage 3 — The rest: a restricted-toolset housekeeping turn

Periodically, the active model takes a **rest turn** — and Michael's sharp refinement is the spec line:

> A rest turn is a turn where **most tools are folded away and the only tools it has are the
> housekeeping ones** — context / tool / skill / journal / note management. It can't *work* this turn.
> It can only *tend.*

The model reviews its own context, folds what it doesn't need, **writes its place into its journal/notes**
(the breadcrumb that survives the fold), tidies its skills/tools — then steps back into the task.

**"As if the fold step didn't happen":** the rest is *infrastructure between turns.* The continuity is
carried by the journal/note the model writes at the start of the rest — it folds, then resumes *from its
own breadcrumb.* The model never experiences a jarring "reset"; it sees a leaner context and its own note
saying where it was.

This is the **sabbath turn** — the creation cycle's rest step, made literal. The restricted toolset is
the *scaffold*: by removing the work-tools, you **force** the housekeeping (the model can't dodge tidying
by doing more work — the only affordances left are tend-affordances).

**★ The tension (wrestle):** if small models are bad at self-management (CT2.4), does a forced rest help
or just waste a turn? Two answers: (a) the **restricted toolset is exactly the fix** — CT2.4's failure
was models *choosing* not to manage; remove the choice and the only moves are management moves. (b) Pair
it with the watcher: the **watcher prepares the rest** (flags fold candidates, pre-writes a draft
breadcrumb) and the **rest turn is where the model ratifies + journals** — so even a weak model just has
to approve, not originate.

## 4. How the three compose (the unified picture)

- **Stage 1** keeps the *right model resident* for each phase (including both the watcher and the active
  model).
- **Stage 2** (watcher) *continuously tidies* behind the active model, out-of-band.
- **Stage 3** (rest) *periodically* lets the active model ratify + journal + fold in-band, with only the
  housekeeping tools.

The model works; the watcher tidies behind it; on a cadence the model rests, journals its place, tidies
deliberately, and continues. **Work → rest → tidy → continue.** The reactive engine is already half of
this; this makes the whole cycle deliberate.

## 5. Anti-spiral: the failure modes, mapped to the fix

| Spiral failure mode (qwen) | Fix |
|---|---|
| Context bloat → overflow / drift | Watcher (continuous) + rest (deliberate) keep it lean |
| Tool overload (159-tool hang) | Tool-shelf + watcher fold to the few in use |
| Loses the thread mid-task | The journal/note at each rest = its own breadcrumb back |
| Loops / repeats | Rest is a **circuit-breaker** — a forced step-back interrupts the loop; the watcher can *detect* repetition and *trigger* a rest |
| Wrong model for the phase (qwen doing vision → 500) | Stage 1 ensures the right model (gemma+mmproj) is resident |

## 6. Open questions for council (the wrestling list)

1. **Lease/contention** for Stage 1 — substrate-managed vs human-experiment. The one we just lived.
   What's the lock? (per-GPU lease? a global "manual hold"? a TTL?)
2. **Watcher: new kind vs grow the reactive engine?** And impose (reversibility) vs propose (feeds rest)?
3. **Rest cadence:** fixed every-N-turns? context-pressure threshold? watcher-triggered? loop-detected?
   (Probably "whichever fires first.")
4. **Does the restricted-toolset rest actually force good housekeeping, or do small models flail even at
   tidying?** This is the load-bearing empirical question — and per `verify_real_path`, it gets a **real
   probe, not a synthetic one.**
5. **Cost/benefit:** a continuous watcher slot + rest turns cost compute. Justified only if it materially
   drops the spiral-rate. → we need a **baseline spiral-rate** before we build the cure.
6. **Where it lives:** the *mechanism* is generic (OSS core); the *model choices* (Nemotron-watcher,
   which models rest) are config/overlay. Keep the split clean.

## 7. First step if ratified — build the oracle, not the cure (per `build_the_oracle_first`)

Do **not** build the whole apparatus blind. First:
- **Instrument the spiral.** Define + measure a spiral: turns-with-no-progress, context-at-overflow,
  tool-loop repetition, dead-end exits. Run qwen on a real tool-heavy task (the kind that kills it today)
  and get a **baseline spiral-rate.** That's the oracle — the deterministic before/after gauge.
- *Then* Stage 1 (elastic provider) — mostly wiring endpoints that already exist, and it unblocks giving
  the watcher + active model their own resident slots.
- *Then* a minimal watcher + rest against the instrumented task, and measure the spiral-rate drop.

The inverse hypothesis applies: prove the spiral exists, apply the fix, confirm it shrinks, remove the
fix, confirm it returns.

## 8. Deferred / explicitly out of scope (for now)

- Learned (vs heuristic) fold policy for the watcher.
- Multi-node watcher (one watcher shadowing sessions across federated peers).
- Auto-tuning the rest cadence from observed spiral data.
- Letting the watcher *escalate the model* (Stage 1) when it detects a spiral a small model can't escape
  — promising, but it crosses into autonomous model-selection; council that separately.

---

*Wrestle freely. The three stages are separable — we can ratify Stage 1 alone, or the probe alone, and
hold the watcher/rest design open longer. The probe (§7) is the safe first move regardless of how the
rest of the design settles.*
