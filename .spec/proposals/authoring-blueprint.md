# Authoring blueprint — the consolidated core chain

**Status:** ACTIVE under the 2026-06-12 stewardship grant. This file is
the externalized memory for the authoring leg: which source files fold
into which subsystem files, the rename rules woven through all of them,
and the verification loop. Sessions resume HERE.

## The shape (decided under the grant, consistent with all ratifications)

**Core = 100% bundle.** Every consolidated subsystem file joins the
`extension_sql_file!` chain in `src/lib.rs`; `CREATE EXTENSION
pg_ai_stewards` delivers the entire substrate atomically. The core
runtime-migration manifest starts EMPTY at v0.1. The migration runner
exists for (a) the overlay tier and (b) going-forward core hotfixes
between releases. Strangers get atomic install; downstreams get the
manifest mechanism. (The old bundle/runtime split was an accident of
growth, not a design.)

**The graph is relational** (AGE-out, ratified): `stewards.nodes` +
`stewards.edges` (kind + jsonb props), recursive-CTE walks, N-depth +
cycle-safe, `BUILDS_ON` doc lineage + `CITES` first-class. AGE leaves
`requires` nowhere (control already only requires `vector`); the
ag_catalog init block in schema.rs (~line 1456, the search_path
landmine) is DELETED, and init/00 drops `CREATE EXTENSION age`.

## Rename rules (woven through every authored file)

| Old | New |
|---|---|
| `stewards.studies` (table) | `stewards.docs` |
| `study_search_text` / `study_get` / `study_similar` / `study_citations` / `study_context_for` (tools + fns) | `doc_search` / `doc_get` / `doc_similar` / `doc_citations` / `doc_context_for` |
| `create_studies` / `create_study_show` (schema.rs blocks) | `create_docs` / `create_doc_show` |
| `intents.scripture_anchor` | `intents.values_anchor` |
| hardcoded `'scripture-study'` slug (yaml.rs, k4, j5/j8c/j9c/j12) | `stewards.config` key `default_intent_slug` |
| `work_items_to_studies` promotion | `work_items_to_docs` |
| pipeline-family LIKE lists in triggers (`'redline%'` leak) | data-driven: `pipelines.auto_verify` boolean column |

Every old→new pair ALSO lands in
`pg-ai-stewards-workspace/parity/rename-map.tsv` (the parity-diff
instrument).

## Genericization (same pass)

- seed_harness researcher prompt ("corpus of scripture") → generic
  research text; example agents = echo + research-lite per plan.
- 2-6a workstream seeds: already separated (overlay); the bundle's
  stale copy dies with the bundle-as-artifact decision.
- r10/coder example URLs (P2 wave), l6 judge-template wording,
  h1-7b/h2 corpus-kind text → generic.
- verify fixtures referencing gospel tools → re-authored against seeded
  example tools in tests/.

## Rust-side edits (src/, in place)

| Block / file | Action |
|---|---|
| schema.rs `create_work_queue`, `create_brain_schema`, `create_tool_wrappers`, `create_harness_schema`, `create_chat_helpers`, `create_resolver`, `create_similarity` | Keep; audit pass only |
| schema.rs `seed_harness` | Genericize seeded agent text |
| schema.rs `create_studies` → `create_docs`, `create_study_show` → `create_doc_show` | Rename + AGE-out (CITES edges → relational graph) |
| schema.rs AGE graph init (~1456) | DELETE (01-graph replaces) |
| yaml.rs hardcoded slug | read `stewards.config` |
| lib.rs `extension_sql_file!` chain | Rewritten to the subsystem files below |
| bgworker.rs 7 string markers | `payload._kind` enum (ratified lesson #3) |

## Subsystem files (the new chain, in dependency order)

| # | File | Sources (classification.tsv names) |
|---|---|---|
| 00 | `00-config.sql` | NEW — `stewards.config` k/v (default_intent_slug, pressure tiers, provider chars/token rows) |
| 01 | `01-graph.sql` | NEW — nodes/edges/walks; replaces AGE init; absorbs graph halves of 2-6a/2-6c + CITES machinery from create_studies |
| 02 | `02-workstreams.sql` | 2-6a, 2-6b, 2-6c (re-authored on 01) — **DONE B1b** |
| 03 | `03-watchman.sql` | 2-7a, 3a, 2-7b1, 2-7b2, 2-7b3, 2-7b4 — **DONE B2** (study_id→doc_id cols; tables born complete; estimate_chat_tokens reads config chars_per_token_default) |
| 04 | `04-work-items.sql` | 3c1, 3c2, 3c2-5, 3c3(core half), 3c3-1, 3c3-3, 3c3-5 + 5e4§1(merged), i1, i2, i5(pulled forward), h3-1(work_items half) — **DONE B2** (promote_to_doc flag replaces 'study-write%' guard; promote via import_doc; chat_post_internal marker fix + tool_defs budget cols + perms source born in schema.rs; i3 + h3-followup-2 REASSIGNED to B3 — their substance lives in 6d/h1-6-2's subsystems: 10-sabbath births file_enqueued_at + enqueue_work_item_file final, 08-gates births on_maturity_verified final + render_file_destination) |
| 05 | `05-mcp-bridge.sql` | 3e2-1(core), 3e2-2(core), 3e2-3(core), h1-5a, h1-7a |
| 06 | `06-cost.sql` | 4a-cost-tracking, 4a-escalation-chain, 4g, es11, j10, j11§1-4, j12§1-2, an4, cv4 — **DONE B2** (machinery only; ALL seed rows → overlay seed-4a-cost-escalation-models.sql; record_cost_event single 11-arg form; work_items cost/escalation cols born in 04; j11's dispatch-gate + j12's start_brainstorm halves trimmed in place for B4's 14-fanout) |
| 07 | `07-steward.sql` | 4a-steward, 4b, 4c, 4d, 6b, 6c(pulled forward — it was only the tick redefinition) — **DONE B2, batch complete** (steward_tick in 6c final form: lessons-aware guidance + atonement-on-quarantine; dispatch born 3-arg override-aware in 04; failure/quarantine/provider_override cols born in 04; 4d's stage_models seeds → overlay; provider fallback de-hardcoded — NULL means the stage's provider applies) |
| 08 | `08-gates.sql` | 5a, 5b, 5c, 5e4(§1 already in 04), h1-6-1, h1-6-2, h1-6-6, l28, i3(on_maturity_verified final form), h3-followup-2(render_file_destination) |
| 09 | `09-intents-covenants.sql` | 5d, 5d2, 5d3, 5d4, 5d5, pr1 (values_anchor + extensions/presiding INCLUDED) |
| 10 | `10-sabbath-atonement.sql` | 5e, 5e2, 5e3, 6d, 6e, am1, i3(work_items born with file_enqueued_at — no materialized_at; enqueue_work_item_file final form) — (6c absorbed at B2 into 07-steward) |
| 11 | `11-trust.sql` | 5f, 5f2, 5f3, 5f4, 5f5 |
| 12 | `12-council.sql` | 5g, 5g2, 5g3, 5g4 |
| 13 | `13-research-pipelines.sql` | h1-0, h1-1→generic example, h1-2, h1-7b, h2, h3-4, h3-5, h3-followup-3, i4, i6, i7, pe2 (i5 absorbed at B2 — origin CHECK born with agent_proposal) |
| 14 | `14-fanout-brainstorm.sql` | j1, j2, j3, j4, j5, j6, j7, j8a, j8b, j8c, j9a, j9b, j9c |
| 15 | `15-context-engine.sql` | k1–k9, l1, l3–l27, l29–l32, es1–es7, es9, ct2-1, ct2-2, ct2-3, ct2-7a, ct2-7a2, ct2-7b, ct2-7d (may split 15a/15b if unwieldy) |
| 16 | `16-subagents.sql` | k4, l9, es8, es10, r11, ct2-5, ct2-7e |
| 17 | `17-personas.sql` | r7, r8, r16, r17(core), r18, r19, r20, r21, ct2-7c |
| 18 | `18-scheduler.sql` | pe6, pe7 |
| 19 | `19-models.sql` | m1, m2, m4, m5, an1, zen1, j8a? (fallback chain → here if cleaner) |
| — | `tests/` | verify-* + test-gate-e2e re-authored per subsystem (lesson #2) |

P2 wave (NOT in this chain yet): cc*, cv*, r10, r12 → `20-coder.sql`
after the hardening review.

## Verification loop (per batch)

1. Author subsystem file(s) + lib.rs entries + Dockerfile COPY.
2. `docker build` the extension image.
3. Scratch container: virgin `CREATE EXTENSION` (vector only, NO age).
4. Assertions: subsystem objects exist; rename-map spot-checks (new
   names exist, old names absent); zero workspace seeds.
5. Commit (each batch is a working extension — the chain grows the way
   the substrate originally grew, but authored).

Batch plan: **B1** = 00+01+02 (+schema.rs AGE-out/doc-rename + init/00
age removal) — the riskiest, most creative batch. **B1a SHIPPED**
(config + graph, `3602500`). **B1b SHIPPED** (02-workstreams re-authored
relational; create_studies→create_docs with 6a + h3-1-docs-half
absorbed; create_study_show→create_doc_show; resolver/similarity on
the relational graph; AGE deleted from schema.rs, init/00, and the
Dockerfile stage-2; doc_* rename swept through every downstream chain
file, the runner-replay files, AND the Go daemons — tool names
study_search/study_get/study_similar/study_citations → doc_*;
todos.parent_kind values lowercased to workstream|doc|todo).
**B2** = 03–07 — **SHIPPED 2026-06-12/13** (03 `80c9f4c`, 04 `d1d74ef`,
05 `c4ed606`, 06 `e49ec38`, 07 batch-final commit; 28 historical files
died, manifest 189→155; operator seeds now live in the workspace
overlay seed-4a-cost-escalation-models.sql; lib.rs requires-graph is
NOT linear — sweep for non-linear edges on every chain cut).
**B3** = 08–12 — **SHIPPED 2026-06-13** (virgin scratch smoke fully green:
AGE absent, 0 study% fns / study_id cols, values_anchor + file_enqueued_at
renames clean, 15 tables / 9 gate_prompts / 5 triggers; gate ladder + trust
gate + l28 veto + verify-fail + the 08→10 on_maturity_verified materialize
path all e2e; GOWORK=off go build+vet green). 32 historical files died;
manifest 155→123. **Dependency-correctness deviations from this file's
literal source-map (the B2 non-linear lesson, applied to cross-batch
function evolution + forward refs):**
- `apply_gate_decision` final form is authored ONCE in **11-trust** (not
  08): its trust check `SELECT`s from `trust_scores`, and a plpgsql SELECT
  from a table born later in the chain is NOT a safe CREATE-time forward
  ref (unlike `NEW.<field>` record access + wrapped function calls, which
  04 already relies on). It is the trust-gated form WITHOUT the inline
  sabbath fire (h1-6-2 moved sabbath to the trigger; firing it inline too
  would double-dispatch).
- `maybe_enqueue_atonement` + the override-aware `sabbath_dispatch` /
  `atonement_dispatch` (h1-0 finals) → **10-sabbath**; **`h1-0` is fully
  consumed at B3** (maturity_ladder → 08; work_items sabbath/atonement
  overrides → 10) — REMOVE h1-0 from 13-research-pipelines' source list.
- `pipelines.maturity_ladder` born in **08** (gate machinery; h1-0's
  ADD COLUMN IF NOT EXISTS in B4 is a no-op).
- `5d5`'s tools_disabled finals for evaluate_gate/generate_scenarios/
  verify_work_item + the intent-aware `evaluate` template folded into 08
  (single definition). `covenant_check` template seeded in 09.
- **`6e` SPLIT**: lesson-file producer → 10; resolution-file producer →
  **12** (it declares `resolutions%ROWTYPE` + triggers ON resolutions; a
  %ROWTYPE / trigger on a not-yet-existing table fails at CREATE — only
  forward *column* refs are deferred).
- sessions.kind union folded into `src/schema.rs` (born-complete; 5c/5e/5g
  constraint churn dropped). yaml.rs: slug from YAML (default "default",
  was hardcoded scripture-study) + emits values_anchor.
**SURFACED TENSION (for Michael, not silently fixed):** `work_item_promote_trigger`
(04, B2-shipped) calls `work_item_promote_to_doc` UNWRAPPED, so on a
sabbath-enabled pipeline a `status→completed` transition *aborts* (the
sabbath gate RAISEs check_violation) until `sabbath_completed_at` is set.
This conflates "defer promotion" with "block completion." Faithful to the
historical authoring (not introduced by B3), but likely wants the PERFORM
wrapped in BEGIN/EXCEPTION→NOTICE (mirroring on_maturity_verified). Touches
sabbath-discipline semantics → Michael's call.
**B4** = 13–16 (incl. j8a+j11-dispatch+j12-brainstorm
trimmed halves; es7's judge-gated tool_dispatch_complete_waiting;
es1's cancel-cascade).
- **B4/13 SHIPPED 2026-06-13** (OSS `97f42db`): research-write (4-stage
  context_gather→gather→synthesize→review, h2 final) / planning (5-stage) /
  agent-proposal / revise-proposal / research-summary pipeline seeds +
  enqueue_proposed_work_items + apply_agent_proposal (i7 final incl. i6
  claude_attested gate) + apply_revision. Virgin scratch smoke fully green;
  GOWORK=off go build+vet green; 13 historical files retired, manifest
  123→110. **Deviations:** h1-0 + h3-1 already consumed (dropped); h-ledger-1's
  `schema_migrations` table relocated to **00-config** (bundle must birth it —
  empty runtime manifest, overlay tier records into it); on_maturity_verified
  NOT redefined here (08 owns the single final form, calls these as wrapped
  forward refs — agent-proposal + fanout branches fold into 08 at B4 close);
  apply_agent_proposal single i7 form; work_item_dispatch_stage tools_disabled
  forward deferred to 19-models (final accretes through r3); genericized
  "gospel" corpus text + neutralized personal project example names. NO
  rename-map rows (consolidation, not renames). **on_maturity_verified true
  final is j7** (j1/j7 add fanout-aggregator branches) → 08's update at B4
  close must fold i4 agent-proposal + j1/j7 fanout branches, all wrapped.
- **B4/14 SHIPPED 2026-06-13** (OSS `b1a9b01`): fan-out machinery
  (fanout-decompose/aggregate agents, decompose-fanout + aggregate-children
  pipelines, spawn_children) + 12-lens brainstorm library (agents+pipelines,
  start_brainstorm) + catalog_default_* helpers + the one-shot/child-terminal
  triggers. Virgin scratch smoke fully green; go build+vet green; 13 files
  retired (j8a + j11 KEPT for B5/19), manifest 110→97. **Deviations:**
  on_maturity_verified TRUE final (j7) folded once into **08** (calls
  spawn_children/check_and_dispatch_fanout_aggregator[14] +
  apply_agent_proposal/enqueue_proposed_work_items[13] as late-bound forward
  refs); **work_item_dispatch_stage dispatch-final defers to 19** (j8a 4-layer
  + j11 cap-gate accrete via m2/r3) — only j8a's dependency-free
  catalog_default_* helpers moved to 14 (j12 pre-flight needs them); j8b
  consumed into the 4 lens pipeline defs (NULL model + metadata.default_*);
  j2's on_aggregate_completed superseded by j6's on_one_shot; start_brainstorm
  'scripture-study' → config default_intent_slug. ★ **spawn_children =
  CORRECT UNION of j3+j4+j8c** — j8c (last live redefinition) DROPPED j3's
  aggregator + j4's per-child file_destination while adding override
  propagation (the aggregate-children template was NULL'd by j3, so the index
  would never materialize); restored here — FLAG for the 20-mismatch
  classification (live may carry the j8c regression). NOTE: lens dispatch
  with NULL models needs 19's fallback (degrades gracefully until then).
- **B4/15a SHIPPED 2026-06-13** (OSS `<pending>`): `15a-context-engrams.sql`
  — the engram + corpus DATA layer (split from 15b per the size note).
  messages.engrams + flagged_injection + agents.working_budget columns;
  provider_rules table+seed + provider helpers; engram_embeddings + populate
  trigger + search_engrams_by_vector; messages_raw_overflow (parents only,
  + content_sha256 + source_sha256_… helper); model_substitutions + trigger;
  kind_circuit_breaker + record/reset helpers; the extraction pipeline
  (engram-extractor agent = **es6 prompt w/ PROVENANCE**, extract_engrams =
  **es7 final** [skips judge-owned], apply_engram_extraction = **es6 final**
  [4-shape normalizer + provenance], agent-aware extraction trigger = l12
  final); render_engrams_under_pressure (l1); the budget cascade
  (effective_budget/stage_working_budget) + extraction-threshold +
  stage_context_strategy helpers; map_reduce_extract_engrams (+ apply +
  l21 map-reduce trigger only); the injection regex screen (k6); embed-route
  trigger (es2); and the 5 engram tool_defs (expand_message /
  mark_engram_important / re_extract_engrams / summarize_my_context /
  read_corpus_parents). Virgin scratch smoke fully green (CASCADE vector;
  22 kept fns, 0 dead fns, 7 triggers, leaves table absent, injection flag +
  extraction-enqueue + render functional); 27 historical files retired,
  manifest 97→70, extension dir 86 .sql. **★ KEY DEVIATION — authored the
  post-ES.3 FINAL state, never build-then-drop.** The historical chain built
  the leaf-chunk-and-embed corpus (l14 leaves table, l15 contextualize_leaf,
  l16 chunk_and_index + split helpers, l17 retrieve_with_merge, es3 circuit
  breaker, es4) and **es9 dropped all of it** (ratified ES.3 council
  2026-05-15, decision 3) once the judge-compiled-brief (es7, → 15b)
  replaced it. So 15a omits the leaf machinery entirely. **It ALSO omits 3
  orphan helpers es9 left undropped in live** (`split_one_chunk`,
  `find_last_break_pos`, the `leaf-contextualizer` agent — dead once
  chunk_and_index/contextualize_leaf were dropped) → **FLAG for the
  20-mismatch classification: live carries these 3 orphans; the authored
  core intentionally does not.** One-shot live-data migrations dropped
  (no-ops on virgin DB): l3 backfill DO, l27 sha backfill UPDATE, es2
  misroute discard. pgcrypto/`digest` concern deferred to 15b (only es7's
  intercept computes a content sha; 15a has zero crypto). NO doc_* renames
  in 15a (those land in 15b with l6's wrappers).
- **B4/15b NEXT:** `15b-context-surface.sql` — the live composition + judge
  surface. compose_messages FINAL (**ct2-7a2** — verify it folds k6/k7/k8/k9/
  l1/l13 fixes) + compose_tools FINAL (**ct2-7b**); the judge-brief path
  (**es7**: judge-brief agent, dispatch_judge_brief, render_judge_brief_surface,
  apply_judge_brief + trigger, intercept_oversized_tool_after FINAL + the l23
  `messages_aa_intercept_oversized` trigger, tool_dispatch_complete_waiting
  FINAL); intercept_threshold_chars (l22) + read_overflow_raw (l23);
  **l6 heavyweight wrappers WITH the doc_* renames** (investigate_study/
  summarize_study/audit_studies → investigate_doc/summarize_doc/audit_docs —
  the FIRST rename-map.tsv rows of B4); deep_research (k5); l7 suspect-sources
  + l8 untrusted-data-wrap (`tool_name_for_tool_call_id` — used by es7
  intercept); l24/l25 dry_run_chat; l30/l31/l32 tool-round caps; es1
  cancel-cascade; ct2-1/2/3 context state/render/tools; ct2-7a self-notes
  store + ct2-7a2 wire + ct2-7b tools; ct2-7d working tags. **Resolve at 15b:**
  pgcrypto vs built-in `sha256()` for es7's intercept content-sha (lean
  built-in to drop the dep — byte-identical); **judge_templates (l18) +
  render_judge_surface (l22) are DEAD post-es9** (render_judge_surface = 0
  callers after es7) → OMIT both (flag: live may carry orphan judge_templates).
- **B4/16:** 16-subagents (k4/l9/es8/es10/r11/ct2-5/ct2-7e; k4 hardcoded
  'scripture-study' slug → config default_intent_slug; k4/l9 subagent depth
  caps). **B5** = 17–19 +
seed_harness genericize + bgworker `_kind` enum. **B6** = tests/ + CI
workflow + rename-map.tsv finalization + overlay copies updated to new
names (overlay note: init/01-seed-workstreams + any overlay migration
touching study_* tools or AGE must re-author against doc_* + relational
graph; import_workstream signature is unchanged).

B1b audit notes for later batches:
- `parse_gospel_links` kept as-is in core (markdown-link parser with a
  gospel-library prefix); genericization candidate for B6 review.
- Embed trigger still hardcodes provider 'lm_studio' +
  'nomic-embed-text-v1.5' + 768 dims — config-table candidates at B5
  (models subsystem), though vector(768) is a column type either way.
- Watchman tables (verdicts/findings/etc.) keep their `study_id`
  columns until B2 re-authors 03-watchman; Go queries already join
  them against stewards.docs.
- l6 wrapper tool names (investigate_study, summarize_study,
  audit_studies) rename at B4 with 15-context-engine.

## Cross-checks before the leg closes

- verify-suite run against live → classify the 20 mismatches; back-port
  any live-only fixes INTO the authored files (grant: act+report).
- Overlay repo: re-author the 33 overlay migrations against new names
  (doc_*, values_anchor, config keys).
- Anatomy doc: update names + the "two tiers" section to bundle+overlay.
