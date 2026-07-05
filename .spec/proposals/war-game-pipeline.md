# Proposal: the war-game pipeline (prospective failure simulation)

**Status:** ★ RATIFIED 2026-07-05 (Michael) — ready to build. Source: `study/yt/nuwlyQXrADg-war-gaming-plans-into-executables.md`.
**One line:** before a big/risky/expensive work item executes, run a strong model to *war-game* it — produce a move-by-move artifact of expected observations, failure signals, countermoves, fork triggers, unresolved assumptions, and abort conditions — then execute with those guardrails materialized as real gate checks and `route_on` edges.

## Why (the gap)

pg-ai-stewards handles failure **reactively**: `send_with_retry` absorbs a transient blip in place (#243), `steward_tick` walks a transient failure to the next alias member or a pinned retry (#326), the breaker/quarantine/spend-cap abort a runaway, `needs_attention`+`ask_up` escalate a blocker to the human. All of it is *generic* and *after the fact*. Nothing produces a **task-specific pre-mortem** — the failure modes a strong model would foresee for *this* mission before the first token is spent. That is the unknown-unknowns surface, and it is where a Fable/Opus-tier model earns its cost.

## What (two increments)

### W1 — the `war-game` pipeline (small; rides decompose-fanout)

A new pipeline family, `war-game`, seeded in a new chain file (workspace or core — see "Boundary" below). Input: `binding_question` (the mission brief). Stages:

- **wargame** (strong model, `loom` sonnet — free via Max sub): produces the war-game artifact. Prompt spine (from the source):
  - You are war-gaming, not executing. A cheaper model will run this brief.
  - Fight the mission on paper, move by move. Each move: expected observation if it worked / if it failed; the most-likely failure + its signal + the countermove.
  - Forks get triggers: `if observe X → route A else B`.
  - Flag assumptions recon could not resolve as `((needs: <var>))` placeholders.
  - End with abort conditions (the errors at which the plan must stop).
  - Trace 2nd/3rd-order consequences.
  - Output BOTH prose (the doc) AND a fenced ```json``` block: `{ moves:[{id, action, expect_ok, expect_fail, failure, signal, countermove}], forks:[{observe, route}], aborts:[{condition}], assumptions:[{var, why_unresolved}] }` — the structured half W2 consumes.
- **critique** (optional, second loom witness): a skeptic pass — "which foreseen failure is wishful, which real failure is missing?" (the completeness-critic shape). Reuses the existing critique stage machinery.

Output: a pooled war-game doc (via doc-construction, so it rides the arc-c capability + the new `docs.work_item_id` provenance) **plus** the parsed structured block persisted on the work item (a `war_game jsonb` column on `work_items`, or a `work_item_war_games` row). Oracle: a run completes and the JSON block parses into ≥1 move with a countermove and ≥1 abort condition; the critique names at least one gap or declares it sound.

This increment alone is demoable and cheap — it is decompose-fanout's structure with a new child template and a strong-model stage.

### W2 — war-game-informed execution (the differentiator)

When a work item carries a war-game, the executor stages change in two enforced ways (not just prompt injection):

1. **Context injection** (easy): the executor stage's `input_template` gains the war-game's moves/countermoves so the cheap model runs with the simulation in view.
2. **Materialized guardrails** (the categorical value): translate the structured block into live control flow —
   - each `abort` becomes a check the bgworker evaluates each turn (same shape as the spiral oracle / step budget) → hitting it routes to `awaiting_review` with the abort reason, not a silent fail;
   - each `fork` becomes a `route_on` edge on the executor stage (route_on already evaluates a data-driven condition to pick the next stage);
   - each unresolved `assumption` becomes an `ask_up` entry in `needs_attention` *before* execution, so the human fills the `((needs:))` blanks up front instead of the run dying on them mid-way.

The honest boundary: the war-game is a **prior**, never a guarantee. It informs; it does not replace the reactive failover hardened this week. A foreseen failure that doesn't happen costs nothing; an unforeseen one still hits `steward_tick`. Prospective + reactive = belt and suspenders.

## Boundary (core vs workspace — the D2A question in miniature)

The `war-game` **mechanism** (the pipeline shape, the JSON contract, the abort/fork/assumption materialization) is generic → **core**. Any *specific* war-game prompts tuned to Michael's domains would be workspace, but the base wargame agent is generic enough to seed in core. This is a clean core candidate — unlike the plan/study/yt agents (workspace, content-specific), the war-game agent is pure mechanism.

## What we do NOT copy from the source

- Static markdown-in-a-folder — that's the artisanal ceiling; our live control flow is the point.
- "Tailor the war-game to a specific executor model's system card" — we abstract over models via aliases; the war-game stays model-agnostic, routing owns model choice.

## Ratified (2026-07-05, Michael)

1. **Trigger → OPT-IN.** War-game only when explicitly requested — a `war_game: true` flag on `start_task` (and a Stewdio toggle). NOT every work item, NOT a cost/risk auto-threshold (that can come later as an additive default, not a v1 requirement). Deliberate and cheap.
2. **Scope → CORE.** The base `wargame` agent seeds in the **core** chain with `model_match = '*'` — pure mechanism (the move/observation/countermove/abort structure), not domain content, so it belongs in core alongside `research`/`dev`. Domain-tuned war-game prompts would be a workspace override later; v1 is one generic core agent.
3. **Abort-materialization → REUSE.** W2 wires abort conditions through the **existing spiral-oracle / gate surface** and forks through the **existing `route_on`** — NO new `work_item_abort_conditions` table. Fewer moving parts; the abort/fork/assumption outputs map onto surfaces already run each turn.

### Build shape (ready to pick up)
- **W1** (small, demoable): new core chain file seeding the `war-game` pipeline (`wargame` [loom] → optional `critique` [loom]) + the generic core `wargame` agent (`*`); `start_task`/dispatch honors the `war_game: true` flag; the strong stage emits prose + a fenced ```json``` block; a `war_game jsonb` column on `work_items` holds the parsed block. Oracle: a flagged run completes, the JSON parses to ≥1 move-with-countermove and ≥1 abort, the critique names a gap or declares it sound.
- **W2** (the differentiator, follow-on): inject the war-game into executor `input_template`s; translate `aborts[]` → gate/spiral checks the bgworker evaluates each turn (→ `awaiting_review` with the abort reason), `forks[]` → `route_on` edges, unresolved `assumptions[]` → `ask_up` entries surfaced BEFORE execution. Stays a prior; the reactive failover (#243/#326) remains the backstop.

The Fable-window use (war-game D2A/D3C/multi-tenancy) rides W1 the moment it exists.

## Fable-window tie-in

W1 is the ideal expiring-Fable spend: war-game the substrate's own hardest open items (D2A, D3C, multi-tenancy) with Fable, banking durable artifacts a cheaper model executes later. Folds into the Lab's Fable-hinge A/B (#322).
