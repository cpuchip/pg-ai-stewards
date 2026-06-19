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

## Execution log

**2026-06-19 — R1 + foundation + R2a DONE (proven e2e on local; OSS commit `d38b336` held local).**

A council-moment read of the pipeline machinery surfaced two things the plan didn't anticipate, both fixed:
1. **Per-stage sessions.** `work_item_dispatch_stage` gives each stage its own session id
   (`wi--<uuid8>--<stage>`), so `doc_drafts` (session-keyed) would NOT survive a stage boundary — a
   *separate* critic stage couldn't `doc_patch` the build stage's draft as the plan's critic design
   assumed. **Foundation built** (`34-doc-builder`): `doc_draft_session_match` scopes drafts to the
   shared `wi--<uuid8>` work-item prefix (keeping cross-work-item + persona isolation), plus a
   `doc_current` tool so a later stage finds the active draft. This unblocks the critic for ALL THREE
   recasts uniformly. **Proven**: book critique read the build stage's draft cross-session.
2. **Latent double-pool.** `on_maturity_verified` auto-pooled the final-stage output for any
   project-tagged verified work — but a doc-construction final output is a JOURNAL, and the canonical
   doc is already pooled by the publish/finalize tool. The shipped playlist loop was silently pooling
   BOTH the real `yt-<id>` digest AND a journal under the work_item slug (project='ai'), while the real
   digest wasn't even project-tagged. **Fixed**: pipelines declare `metadata.pools_via_tool` → the arm
   skips; the publish bridges project-tag the canonical doc. (Historical `playlist-digest-cron--*` junk
   docs remain in the pool — see carry-forward; Michael's call to purge.)

- **R1 routing — DONE.** book-digest / book-curate / playlist name roles in OSS examples (alias
  indirection = routing); `examples/models.sql` seeds public-default ingest/reason/critic (priority 5);
  the overlay `role-aliases.sql` recasts planning + research-write + research-summary to local roles
  (workspace `80aea6a`, pushed). The 5-family drift is codified.
- **R2a book-digest — DONE + PROVEN.** read(ingest, header-only no echo) → build(reason, doc_* diffs,
  no publish) → critique(critic, doc_current → doc_read → doc_patch corrections + doc_append Tensions →
  book_publish_draft). A Modest Proposal digested e2e on local (gemma+qwen): pooled once as
  `book-a-modest-proposal` (project=books, 6 sections incl. Tensions), **0 double-pool junk**, $0, 0 errors.

**Carry-forward (next focused session — foundation in place makes these fast):**
- **R2b research-summary + R2c research-write** doc-construction recast in OSS core `13-research-pipelines.sql`:
  recast synthesize→build (doc_*) + review→critique (doc_current → doc_read → doc_patch → **doc_finalize**),
  set `auto_materialize_on_verified=false` + `metadata.pools_via_tool=true`, drop `file_content_jsonpath`.
  **New sub-task: `doc_finalize` project fallback** — research has no static project (unlike book='books'),
  so `doc_finalize` (and the publish bridges) should default the pooled doc's `project_association` to the
  WORK ITEM's project when the draft's project is empty (look up `work_items` by the `wi--<uuid8>` session
  prefix). Without this the research pool docs won't be project-findable. Then update `role-aliases.sql`
  to target the new build/critique stage names. Prove each e2e on local before the next.
- **R3** reaper_stale_minutes config (raise ~30 local) + route the 3 background judges to the reason alias.
- **The pgrx rebuild** (bakes `08-gates` pools_via_tool + `34` work-item drafts/doc_current + R2b/c `13` +
  R3 reaper) + **virgin-smoke + overlay-clobber** → THEN **push the held OSS commit `d38b336`** (public
  push is gated on virgin-smoke per the rebuild discipline) + sweep the FK-pinned `doc-build-test` pipeline.
- **Critique-convergence tuning**: the critic stage inherits the research agent's web tools and uses them
  to re-verify the source (slow, ~2 extra turns on local; it DID inform real corrections, so not pure
  waste). Consider: critique prompt "work from the draft only, do NOT re-search," or deny web tools for
  the critique stage. Structural, not a defect — book still converged + published.
- **Pool cleanup (Michael's call):** purge the historical `playlist-digest-cron--*` journal/duplicate
  docs (project='ai') now that the double-pool is fixed; verify each has a clean `yt-<id>` twin first.

## Cross-project
Leave a note in the general-workspace session to review this session and apply what transfers to
**Garrison** (the local-first coding agent): it already builds code via edits + borrows the same
FlexLLama rig — the journal-as-output, the `--parallel`/q8 rig lessons, and the source-page-in all
likely transfer.
