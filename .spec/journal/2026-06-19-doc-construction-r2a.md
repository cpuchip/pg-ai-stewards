# 2026-06-19 — Doc-construction rollout: R1 + foundation + R2a (book-digest) proven

Continuation of `2026-06-19-local-soak-and-doc-construction.md`. Michael: "lets go ahead
and build out those plans we made" → execute `local-learnings-rollout.md` (ratified).

## What shipped (proven e2e on local, $0)

- **R1 routing codified.** book-digest / book-curate / playlist name roles in OSS examples
  (the alias is the routing layer); `examples/models.sql` seeds public-default ingest/reason/critic
  (priority 5) so a bare public install runs; the overlay `role-aliases.sql` recasts planning +
  research-write + research-summary to local roles (the live-only drift). Workspace pushed (`80aea6a`).
- **Foundation (beyond the plan).** Two integration realities the plan didn't anticipate:
  - **Per-stage sessions** (`wi--<uuid8>--<stage>`) → `doc_drafts` wouldn't cross a stage boundary, so a
    *separate* critic stage couldn't patch the build's draft. Built `doc_draft_session_match`
    (work-item-prefix scoping, keeps cross-WI + persona isolation) + `doc_current` tool. Proven: book
    critique read the build draft cross-session.
  - **Latent double-pool.** `on_maturity_verified` auto-pooled the final stage output for project-tagged
    verified work — a journal, for doc-construction, while the real doc was already pooled by the publish
    tool (and not project-tagged). The shipped playlist loop was doing this silently. Fixed with
    `metadata.pools_via_tool` (skip the arm) + the publish bridges project-tag the canonical doc.
- **R2a book-digest** recast to read → build → critique (doc_* construction; critique = a real
  second-pass that doc_current → doc_read → patches corrections + appends Tensions → book_publish_draft).
  Proven: *A Modest Proposal* digested end-to-end on local (gemma read + qwen build/critique), pooled once
  as `book-a-modest-proposal` (project=books, 6 sections incl. Tensions & objections), **0 double-pool
  junk**, $0, 0 errors, 22 chats.

## Surprises / notes

- The critique stage did **genuine** work — it web-verified the digest's quotes against the source, found
  a systematic misread of Swift's "reform" satire, and `doc_patch`ed corrections across multiple sections
  before publishing. That's the D&C 88:122 value made concrete (a second pass catching the first's errors).
  Caveat: locally `reason` and `critic` both map to qwen3.6-27b, so it's a second *pass* (fresh context),
  not a second *model*; and the web re-verification slows convergence (a tuning item, not a defect).
- Presiding: paused `autonomy_paused` for the recast window (~20:33–20:43 UTC) as a lawful wall, ran one
  controlled `work_item_create` + `work_item_dispatch_stage` (not autonomy-gated) to prove on the live
  stack, then resumed. Accounted here + in the lane.
- The missing-'s' in psql output was a heredoc/Git-Bash display artifact; server-side counts confirmed the
  stored bodies are clean.

## Carry-forward
Full list in `local-learnings-rollout.md` → Execution log. Short: R2b research-summary + R2c
research-write (with a `doc_finalize` project-from-work-item fallback), R3 reaper config + judges→local,
then the pgrx **rebuild + virgin-smoke** (which gates the held OSS push `d38b336`) + sweep `doc-build-test`.
Plus: critique-convergence prompt tuning; purge the historical `playlist-digest-cron--*` pool junk (Michael's call).
