# 2026-07-07 — The lightening overnight: lifeless core, 28 volumes, and the unpause that found two ghosts

**Session:** overnight grind on `feat/lightening` under Michael's standing grant ("2 weeks is
something you can do in about 1.5 hours... im heading back to bed. good luck!"). Delivered as
**PR #31**. Ten commits, five builder agents (E lifeless-strip, F tooling, G UI merge, the
opus consolidation pass, plus the pre-compaction wave-1 builders), every batch independently
re-verified by the session lead before commit.

## What shipped (the branch)

1. **The founding principle, executed** — v27-lifeless-core: no default models anywhere in
   core. Catalog defaults are config (NULL absent); embed routing, watchman, gates, sabbath,
   atonement, councils, judges all resolve config → catalog-default → park-in-review.
   `__queue_for_opus__` → `__queue_for_strongest__`. Every stripped literal re-seeded 1:1 in
   the overlay example. E proved the round-trip: lifeless virgin parks a dispatch in
   `awaiting_review`; overlay applied; the same dispatch resolves.
2. **109 chain files → 28 themed volumes**, byte-preserving and *proven* — the move-proof
   checker strips banners and asserts byte-equality with the git originals; schema dump of
   old vs new virgin containers diffs empty. The opus builder's load-bearing discovery:
   **pgrx install order ≠ lib.rs text order** (35 is a DAG sink installing dead last; 36
   installs right after 16) — cutting volumes along lib.rs order would have silently changed
   which CREATE OR REPLACE wins. The shepherd amendment (contiguous segments of the real
   topo order) held.
3. **W2 aborts** (103) · **observations + seams_report** (104/105 — the sanitized
   seam-finding core) · **schedule visibility** (106) · **UI 24 routes → 10 + Dev flyout**
   (deployed, before/after delivered) · **generated COPY manifest + CI drift gate +
   `stewards-cli update`**.

## What the night taught (the part worth keeping)

**The dress rehearsal earned its keep twice.** E's strip was correct for virgin installs but
107 applied to a *lifeful* box deletes 73 stage_models rows, the judge config, watchman
defaults, and leaves 4 escalation rows pointing at a renamed sentinel. Nobody had tested the
upgrade path — E proved virgin and virgin+overlay only. A scratch rehearsal on the old image
exposed all of it; live then got an atomic snapshot-restore migration (backup tables
`stewards._migr107_*` kept as rollback anchor) with in-transaction asserts. Residual diff:
exactly the intended two config keys + four sentinel renames. **Lesson: "virgin green" and
"upgrade green" are different oracles; rehearse the lifeful path before touching live.**

**The unpause was a flashlight.** Within one scheduled fire it exposed two live↔repo drifts
and one design gap, none visible while paused:
- `pick_alias_member` on live was the pre-95 body — **ignores the `enabled` flag** Michael
  curates in the wizard. His 07-04 rest-the-locals toggles were silently decorative; dispatch
  picked a rig model nothing serves (404). Repo was correct all along; a #326-era re-apply of
  32 had clobbered 95's final on live. Ported the truth.
- `diagnose_failure` on live lacked 68/#326's transient patterns — the exact 404 ("no local
  slot serves model") that should trigger alias-walking was classified hard-fail. Ported.
- **The constant-10 churn mystery, root-caused:** items whose retry raises *before* dispatch
  (pick_model `no stage_models row`) get their progress update rolled back by the per-item
  exception handler, so the same 10 oldest items re-enter the LIMIT-10 tick window every 30s
  forever — 300 tick_errors/15min — and **starve every legitimate retry** (the first
  memory-tend fire sat unretried behind them). Mitigated live by quarantining churners;
  durable fix filed (park-to-awaiting_review inside the handler — the #330 poison-pill
  pattern applied to work_items). Extra weight: a virgin lifeless install has an EMPTY
  stage_models, so this shape matters for every fresh deployment.

**parity-check.sh closed the night at exit 0** — live matches the branch's virgin image
exactly (held overlay re-authors excepted). The drift oracle also caught two CRLF-only
function bodies (normalized) exactly where the consolidation builder predicted.

## Live-box end state
- Chain content ≡ branch (parity green). UI redeployed with the merged nav + PAUSED banner.
- `autonomy_paused=false`; only memory-tend-gentle + book-digest-hourly enabled (7 others
  disabled with dated notes); reflect-guard cap $12→$5/24h; missed-window rolled the stale
  due-times forward (no thundering herd). Routing on Michael's own alias enablement:
  reason→deepseek-flash / ingest→mimo (flat-rate opencode_go), critic→loom sonnet seat.
- Quarantined: the churn cohort (reason strings say why and point here).

## Carry-forward
- **PR #31 = the Hinge.** Nothing merges without Michael.
- #338 steward retry-lane starvation (durable fix, small chain increment).
- 107-on-work-box: `stewards-cli update` + the consolidation-adopt path now handle it, but
  the work box will ALSO need its own overlay/restore pass (it is lifeful too) — the
  live-migration script pattern in scratchpad is the recipe; consider promoting it to
  `scripts/` before the work-box pull.
- Loom role-seats beyond `sonnet#critic` (tend/ingest/build) = Michael's seat-design call.
- W2 remaining halves (forks→route_on, assumptions→ask_up); D2A pack proof rides the
  standalone PACK volumes.

## Set down
- Re-pointing memory-tend/book-digest onto new loom seats overnight — deliberately not done
  (new standing machinery; his call).
- The migrate.sh `status`-mode cosmetic double-print (documented in-file, builder flagged).
- ~24 old-filename references in docs/ — left as history; every old name survives as a
  banner + map entry, grep still lands.
