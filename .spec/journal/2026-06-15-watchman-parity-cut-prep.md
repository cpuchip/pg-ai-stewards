# 2026-06-15 — the self-presiding watchman, M4, parity refresh, cut-prep

Michael's ask after the reflect-steward went live: "what's not pulled over that
we could pull?" The honest answer was *almost nothing* — the clean-room is done,
and the pull direction has inverted (OSS now exceeds live). So the work turned
to **prove → protect → cut**. He picked four: (1) a persistent watchman, (2)
prove personas on OSS, (3) refresh parity, (4) cut-prep — holding the services-
to-own-repos topic for later.

## 1. The self-presiding watchman guard (`23-reflect-watchman.sql`, `082be5e`)

The reflect-steward runs autonomously on a schedule; the human kill switch only
helps when a human is watching. So the substrate now watches its OWN delegated
work: a **deterministic** guard wired into `watchman_scheduler_fire` (the
bgworker heartbeat — persistent, no session required) that auto-pauses the global
kill switch on a clear runaway:

- `in_flight` autonomous work ≥ threshold (the whole surface, not just the drain's
  cap — schedules + spawned children),
- consecutive autonomous failures (loop broken),
- windowed autonomous spend over the cap,
- un-triaged proposals exploding.

It is D&C 121 made mechanical: it watches what it set in motion, and when it
applies emergency force (an auto-pause) it **accounts** for it — a
`reflect_guard_log` row with the breach + signal snapshot — for whoever lifts the
pause. It never auto-resumes. No LLM, no cost: a read + a config flip.
`reflect_status` now surfaces `guard{would_trip,breach,…}`. virgin-smoke **OK 8**
inverse-proves the act (force a breach → auto-pause + exactly one log row +
idempotent). Michael's framing: "a presiding agent of sorts."

The implementation pattern is the lesson worth keeping: a guard like this belongs
on the substrate's own heartbeat, not in an external watcher (a cron, a human, an
agent) that can lapse. The heartbeat already runs for the scheduler; the guard
rides it for free.

## 2. Personas fire on the virgin OSS core (M4)

Schedules were already proven (the reflect-steward's cadence). For personas, the
faithful proof is the **front-desk persona answering from the gathered knowledge
pool**: the persona-host reads the pool and injects context; the tool-free
`persona` agent just talks in character. Dispatched a `persona-turn` on the live
OSS stack with a research-intent analyst brief + the pool's findings + a real
question — got back a concise, in-character, *grounded* answer that cited the
gathered specifics. That's the whole architecture end to end on the extracted
core: **gatherer writes the pool → host reads it → persona talks from it.**

## 3. Parity refresh — GREEN, and stronger (`mismatch-classification.md`)

The 06-13 classification predated four chain files (20–23). Refreshed:
- Live schema **frozen since 06-12** (migration ledger); today's live activity is
  data, not function changes — so the 06-13 body-diff still holds.
- **Function-name-set diff:** 430 rebuilt fns vs 325 live. Every live-only fn is a
  documented deliberate change (pgcrypto dropped, `study_*`→`doc_*` rename,
  retired/orphan/superseded helpers). **Zero uncaptured live behavior.**
- The 06-13 deferred P2 coder arm is **closed** (`20-coder`).
- Rebuilt is a **superset** (compact_context, reflect-steward, watchman, graph_*
  relational). The pull direction inverted.
- **Overlay-replay 36/36** on core 00→23.

## 4. Cut-prep

- **Sabbath-tension resolved** (`2f43d3b`): `work_item_promote_trigger` did an
  unwrapped `PERFORM work_item_promote_to_doc` on completion, so a promotion
  failure rolled back the completion — an unattended sabbath that completes many
  items must not be abortable by one item's hiccup. Wrapped it (WARNING, completion
  kept), matching the side-effect pattern in 22's drain + 23's guard.
- **The gating prerequisite for the cut** (in the private runbook): a downstream
  chat front-end still dials the *live* bridge; the cut must repoint it to the OSS
  bridge first, or those personas go dark. Parity was never the blocker — this is.
- The cut itself stays Michael's Hinge (it's outward-facing now).

## Carry-forward

- The cut: repoint the chat front-end → OSS bridge, then the cut sequence (private
  runbook). Michael's go.
- Minor: `on_maturity_verified` still tries `sabbath_dispatch` on an unseeded
  `plan` agent (caught/non-fatal) — same missing-agent shape as `research` was.
- The live soak carries 22/23 + the wrap via psql; the image rebake lands at the
  cut (the standalone-reapply discipline: 23 is the chain tail, safe; the promote
  trigger is only authored in 04, so its standalone CREATE OR REPLACE is safe too).
