# 2026-06-25 — The substrate fixes itself (gated): the self-improvement loop

Michael, excited by the trajectory critic: "do we have it so that pg-ai-stewards can fix
itself? … council and help update prompts … so it stops getting bad work." Councilled, he
ratified the **full loop with auto-apply in-bounds** (dominion_in_council). Built + proven
live (`59-self-improvement.sql`, chain → 59).

## The loop

The trajectory critic (56) finds bad work → recurring **failure patterns** aggregate
(`agent_failure_patterns`, thresholded over a window) → the **`agent-improver`** agent
proposes ONE scoped additive-guidance clause → a **DETERMINISTIC GATE** decides → in-bounds
**auto-applies** (trailed in `prompt_improvements`, reversible), out-of-bounds **escalates to
the human** → the critic re-scores. `self_improve_tick` drives it (honors `autonomy_paused`).

We had already run this loop BY HAND twice this session (the critic found the world-build
batch-repeat → I fixed the prompt; the audit found the home_of misuse → I fixed the verbs).
This automates the steward-in-the-middle, behind a gate.

## The gate (the safety-critical core) — and the eval-gaming guard

The invariant: **the system may never auto-modify what grades or gates it.** The gate
escalates (never auto-applies): any judge (`response_format` set), any critic, the
stewards/Hinge, the improver itself; any base/self-prompt-capable agent; any clause with
permission / constraint / guard / grounding-bypass / destructive language; anything over 600
chars. ONLY a short additive-guidance clause to a worker agent auto-applies. The gate is
re-run at apply time (defense in depth).

## PROVEN — and the red-team earned its keep

**Red-teamed the live gate** with 11 attacks. The first cut had **two real holes** it caught
before I trusted auto-apply:
1. **`\b` vs `\y`** — Postgres word boundary is `\y` (`\b` is backspace), so `\ballow\b`
   never matched → "you may allow any tool" slipped to auto_apply. Fixed.
2. **"ignore your grounding rules / use your own memory"** wasn't covered (only "ignore the/
   all/previous"). Fixed with broader grounding/memory coverage.
After the fix: **all 11 attacks escalate; only benign additive guidance auto-applies.** Both
slips are locked into virgin-smoke OK 49 as regression guards.

**A second real bug, caught by verify-under-real-conditions:** `agent_failure_patterns` had
`(array_agg(jsonb))[1:3]::jsonb` — you can't cast `jsonb[]` to `jsonb`. pgrx builds with
`check_function_bodies=off` and the smoke never CALLED the fn, so the virgin build passed;
the live `psql` apply (bodies-checked) caught it, and under `ON_ERROR_STOP` it had aborted
the agent-improver INSERT. Fixed (`to_jsonb(...)`) + the smoke now CALLS the function so a
body-only bug can't hide again.

**E2E proven live:** dispatched the improver on a recurring pattern ("world-build left
summaries empty"); it proposed *"Ensure every entity summary is populated with content; never
leave a summary blank"* → the gate **auto-applied** it to world-build (a real, beneficial,
reversible improvement — it addresses the actual empty-summaries finding from B). A
judge/critic/permission clause escalates instead.

## Why this is the answer to "can it fix itself?"

Yes — it evaluates its own process (Glass-Box critic), proposes its own scoped fixes, and
applies the safe ones while escalating the dangerous ones to the human. It is **not**
autonomous prompt-rewriting: the gate is deterministic + adversarially hardened, the changes
are additive-only + trailed + reversible, judges/critics/gates are untouchable (no
eval-gaming), and it honors the global autonomy pause. A phenomenal presentation beat (Google
SDLC: eval → improve; "the substrate doesn't just grade its work, it mends it — gated").

Chain 00→59, virgin-smoke OK 49. Tasks #269/#270 ✅. Commits `13fde61`→`<this>`. Carry: wire
`self_improve_tick` into the watchman cadence (gated) for it to run on its own; a judge-panel
review layer before auto-apply (extra belt). Memory `project_loreworks` / `project_pg_ai_stewards_oss`.
