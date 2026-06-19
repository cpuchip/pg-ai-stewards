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

## Execution log — Session 2 (2026-06-19 PM, "keep going with the carry-forwards")

Almost the whole tail landed + the OSS push is now public (`e8a040c`; ws `558bedf`):
- **Pool junk cleanup — DONE.** Purged 20 double-pool artifacts (`playlist-digest-cron--*` + the
  old one-shot `book-digest-hourly--*` journal/duplicate docs); canonical pools intact (33 yt + 27 book).
- **Critique-convergence tuning — DONE.** book + research critique prompts now say "work ONLY from the
  draft; do NOT fetch_url/web_search — you are reviewing the draft, not re-researching." (The e2e showed
  the critic wandering into source re-verification — it found a real Swift-satire misread, but slow.)
- **`doc_finalize` project-from-work-item fallback — DONE** (34): pools as kind `doc` (was `digest`) and
  falls back to the work item's `project_association` (derived from the `wi--<uuid8>` session) when the
  draft has no project. Proven in virgin-smoke OK 20.
- **R2b research-summary + R2c research-write — DONE** (new `35-research-doc-construction.sql`, chained in
  lib.rs): gather→build→critique / context_gather→gather→build→critique; synthesize→doc_* build,
  review→doc_patch+doc_finalize critique; `auto_materialize` off + `pools_via_tool`; roles named; gather
  stages preserved. Applied live + virgin-smoke-asserted.
- **Dockerfile bug FIXED** (rebuild gate caught it): 34 was added to lib.rs last session but never to the
  Dockerfile COPY → the image would FAIL to build (CI red on next push). Added 34 + 35.
- **Rebuild + virgin-smoke — DONE: 20/20 PASS** (chain 00→35; OK 20 = doc-construction layer) +
  **overlay-clobber PASS** (caught that `cut3` re-authored `on_maturity_verified` with the stale body →
  mirrored the `pools_via_tool` guard so cut3 stays a core superset). Swept the FK-pinned `doc-build-test`.
- **OSS pushed public** (gate satisfied): `e8a040c`. Workspace `558bedf`.

**New finding (separate from the rollout):** research-summary's GATHER stage (gemma/ingest doing
multi-round web research) can **wedge** on a large accumulated context — a controlled run hung 13+ min on
one gather turn after 3 web_search_exa results (the rig was otherwise healthy, 41 flexllama chats done).
This is the *unchanged* gather stage, not the doc-construction build/critique (which is proven). A wedged
gather self-heals via the reaper requeue. Worth a follow: cap gather web-rounds, or route gather to a
larger-context/faster model (nemotron 512k or kimi) for the heavy-web pipelines on local.

**Carry-forward (small remainder):**
- **R3** — `reaper_stale_minutes` config (Rust, bgworker.rs `interval '15 minutes'` ×2) + route the 3
  background judges (engram-extractor / judge-brief / watchman-consolidator, ~5 hardcoded `opencode_go`
  sites in 15a/16) to the local `reason` alias. Both want the next pgrx rebuild — fold them together.
  NOTE: doc-construction already MITIGATES the reaper concern (its short diffs never approach 15 min), so
  the reaper raise lost its urgency; the gather-wedge above is the remaining 15-min-reaper trigger.
- The gather-wedge follow above (cap rounds / bigger gather model on local).
- e2e-prove research-summary/write build+critique on local once gather is unblocked (machinery already
  proven by virgin-smoke OK 20 + the book-digest e2e; only the live run is pending the gather fix).

## Cross-project
Leave a note in the general-workspace session to review this session and apply what transfers to
**Garrison** (the local-first coding agent): it already builds code via edits + borrows the same
FlexLLama rig — the journal-as-output, the `--parallel`/q8 rig lessons, and the source-page-in all
likely transfer.
