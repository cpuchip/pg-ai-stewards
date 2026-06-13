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
| 06 | `06-cost.sql` | 4a-cost-tracking, 4a-escalation-chain, 4g, es11, j10, j11, j12, an4, cv4 |
| 07 | `07-steward.sql` | 4a-steward, 4b, 4c, 4d, 6b |
| 08 | `08-gates.sql` | 5a, 5b, 5c, 5e4(§1 already in 04), h1-6-1, h1-6-2, h1-6-6, l28, i3(on_maturity_verified final form), h3-followup-2(render_file_destination) |
| 09 | `09-intents-covenants.sql` | 5d, 5d2, 5d3, 5d4, 5d5, pr1 (values_anchor + extensions/presiding INCLUDED) |
| 10 | `10-sabbath-atonement.sql` | 5e, 5e2, 5e3, 6c, 6d, 6e, am1, i3(work_items born with file_enqueued_at — no materialized_at; enqueue_work_item_file final form) |
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
**B2** = 03–07. **B3** = 08–12. **B4** = 13–16. **B5** = 17–19 +
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
