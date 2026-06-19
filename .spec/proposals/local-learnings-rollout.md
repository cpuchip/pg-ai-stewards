# Rollout — apply the local-model learnings across pg-ai-stewards

**Status:** PLAN for ratification (dominion_in_council). **Date:** 2026-06-19.
**Origin:** the 2026-06-19 local-model soak + the doc-construction pilot (proven on playlist-digest).
Detail: `agentic-doc-construction.md` + `local-throughput-experiments.md`; journal
`2026-06-19-local-soak-and-doc-construction.md`.

## The learnings (proven this session)
1. **Build large docs via tool-call diffs + a journal output**, not one-shot — proven on playlist-digest
   on qwen (the model that 500'd one-shot ran 0-error). Fixes reaper + contention + grammar at once.
2. **gemma q8 `--parallel 4`** = 4×131k slots, 248 tok/s — codified. (`--parallel 1` wedges.)
3. **KV must live in dedicated VRAM** (q8 the enabler) — codified for qwen/nemotron/gemma.
4. **Local-first role-alias routing** (ingest/reason/critic) — LIVE but only on the running DB (drift).
5. **Read stages must not echo big sources** — cache + emit a reference; the builder pages it in.

## Rollout phases

**R1 — Hygiene (no new behavior; codify what is already live). Low risk, do first.**
- Codify the 5-family local routing as a workspace overlay (stop the live-only drift).
- pgrx image rebuild to bake `34-doc-builder.sql` + the playlist recast; sweep the inert
  `doc-build-test` pipeline (FK-pinned) at the rebuild.
- Re-run virgin-smoke + overlay-clobber checks (the discipline) after the rebuild.

**R2 — Generalize doc-construction to the remaining large-doc digesters.** One pipeline at a time,
e2e-proven on local before the next (exactly how playlist-digest went).
- **book-digest** FIRST (highest value — hourly, the one tripping the reaper): read (cache the book,
  emit a reference, no echo) → build (page the book in via a getter + `doc_*` + a `book_publish_draft`
  bridge that pulls body server-side, mirroring `playlist_publish_draft`) → critic (`doc_read` +
  `doc_patch` objections).
- **research-summary** (ai-news) + **research-write**: the `synthesize` stage builds via `doc_*` and
  finalizes with the generic `doc_finalize` (these pool a doc, no custom publish) + a critic stage.
- **NOT recast:** book-curate (a curator decision, not a large doc) + planning/work-corpus (emits proposals,
  not one big doc). Different shape — leave them.

**R3 — Core robustness (helps every local digester).**
- Reaper: make the hardcoded 15-min "stale in_progress" threshold a config (`reaper_stale_minutes`),
  raise for local (~30). Big local reads stop getting false-killed.
- Route the 3 background judges (engram-extractor / judge-brief / watchman-consolidator, hardcoded to
  opencode_go) to the local `reason` alias — kills the harmless-but-noisy 429s, runs the context engine
  + watchman on local.

## Decisions — RATIFIED 2026-06-19 (Michael)
1. **Doc-construction scope = ALL THREE** (book-digest + research-summary + research-write); book-curate
   + planning excluded (different shape). **Michael's emphasis: research-summary + research-write must
   ALSO be multi-shot doc-diff builds** (one-shotting a *plan/research synthesis* is the same trap as a
   digest) — build via `doc_*`, **journal output kept as a reviewable log**. Build one at a time,
   e2e-prove on local before the next (book-digest first as the highest-value proof).
2. **Separate critic stage — YES**, per recast digester (reads the draft via doc_read, doc_patches in
   objections; the D&C 88:122 second-model pass; ~$0 on local).
3. **R3 core robustness — YES** (reaper → config + raise for local; route the 3 background judges to local).
4. **Order:** R1 hygiene first (codify routing overlay + pgrx rebuild — note: the rebuild briefly
   recreates the substrate container, time it quiet), then R2 (book-digest → research-summary →
   research-write, each proven on local), then R3.

## Execution note
Fully spec'd + ratified. This is a multi-pipeline build (3 recasts + per-pipeline finalize bridges +
critic stages + reaper config + judges) best run in a fresh, focused context — the same "plan reduces
errors" discipline that caught the read-stage echo. The autonomous loop keeps running the current setup
on schedule meanwhile (playlist already recast; the others on the old one-shot pattern, which works with
occasional reaper requeues until R2 reaches them).

## Cross-project
Leave a note in the general-workspace session to review this session and apply what transfers to
**Garrison** (the local-first coding agent): it already builds code via edits + borrows the same
FlexLLama rig — the journal-as-output, the `--parallel`/q8 rig lessons, and the source-page-in all
likely transfer.
