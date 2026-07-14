-- ===== v36-keeper-constitution.sql =====
-- =====================================================================
-- v36-keeper-constitution.sql — the Knowledge-Keeper constitution (S3): three
--   mechanical rules for every agent that WRITES to the memory corpus, wired
--   into the doc-construction digesters through BOTH channels S1 proved reach a
--   client model (the tool description + the stage prompt), plus a deterministic
--   living-vs-record boundary that rule 3 is forbidden to cross.
-- =====================================================================
-- Ported (not code — prose IP) from Understory's Knowledge Keeper system prompt
-- (proposal .spec/proposals/understory-steals.md §S3;
-- external_context/understory core/src/agent/system-prompt.ts). The three rules
-- are the transferable heart of "you are tending ONE shared body of knowledge,
-- not filing separate reports":
--
--   1. ENRICH OVER CREATE  — a fact that is an ATTRIBUTE of an existing doc gets
--                            patched INTO it; a new doc is minted only for a
--                            distinct entity someone would look up on its own.
--   2. LINK BOTH WAYS      — a doc nothing points at is invisible knowledge. Wire
--                            it in. The deterministic detector for a violation is
--                            S2's stewards.graph_orphans view (v35) — this rule
--                            NAMES that view so the constitution and its oracle
--                            reference each other, and the memory-tend loop (v35)
--                            already owns the Hinge-gated BACK-edge half.
--   3. SUPERSEDE COMPLETELY — when new knowledge contradicts what a doc asserts,
--                            update to the new value and make the stale statement
--                            appear NOWHERE (rewrite the whole body if need be).
--                            MEMORY side only: this governs LIVING / current-state
--                            docs and NEVER a record (a journal, a dated digest —
--                            immutable history). His own design agrees: memory
--                            mutations are git-committed, history lives in commits.
--
-- HOW A CONSTITUTION LANDS IN THIS SUBSTRATE — constitutions are DATA here, not
-- code (the same shape S1/S2 used). This file ships:
--   §1  config seed — keeper.record_kinds, the operator-owned list of doc kinds
--       that are immutable history (default ["journal"]). ON CONFLICT DO NOTHING,
--       so an operator's own taxonomy is never clobbered (the v35 idiom).
--   §2  stewards.keeper_doc_is_record(kind, frontmatter) — the deterministic
--       living-vs-record boundary rule 3 must not cross. Mirrors v35's
--       graph_lint_is_autogen_source EXACTLY and REUSES the Watchman's own
--       frontmatter-exempt gate (v01 dirty_queue: watchman ∈ skip|exempt) so the
--       "do not rewrite this doc" boundary is ONE definition, not two that drift.
--   §3  stewards.keeper_constitution() — the canonical three-rule text. ONE
--       source of truth the channels below splice, so the rules can never drift
--       between where they are stated and where they are read.
--   §4  the TOOL-DESCRIPTION channel (S1's universal fallback: every tool-calling
--       client loads descriptions) — a concise keeper directive appended to the
--       doc_create tool_defs.description. This is the lever that reaches EVERY
--       doc-construction agent in EVERY pipeline, core or operator overlay
--       (book-digest, playlist-digest, case-file — examples/), because they all
--       hold doc_create. Idempotent (guarded on its own marker).
--   §5  the STAGE-PROMPT channel (S1's standards channel) — the FULL constitution
--       appended to the doc-construction BUILD stages of the core digesters
--       (research-summary, research-write; the "research-recast" of v27). Extend-
--       don't-reshape: only the input_template string grows; stage shape, model
--       role, tool_groups, and next-pointer are preserved byte-for-byte. Idempotent.
--
-- WHY THE BUILD STAGE, NOT THE CRITIQUE STAGE — all three rules are authoring
-- decisions: whether to doc_create or enrich (1), what to link (2), and how to
-- retire a contradicted claim (3) all happen while the body is being built. The
-- critique stage reviews and finalizes; loading the full canon there too would
-- only double the tokens. The tool-description channel (§4) still reaches the
-- critique stage (it holds doc tools), so the rules are not absent there.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT TOUCH — the memory-tend pipeline (v35/S2,
-- just landed) already carries rule 2's back-edge half ("wire orphans, do NOT
-- invent a relationship"); re-authoring it here would reshape a sibling's fresh
-- work for no gain (honor_scope). The engram-extractor (v04) and the normalize
-- tools (v29) are memory writers of a DIFFERENT shape — the extractor distils a
-- single message into transient per-message engrams (it creates neither a corpus
-- doc nor a graph edge), and doc_fact_add only ever writes a typed fact INTO an
-- existing doc (it structurally CANNOT mint a doc, so it already embodies rule 1).
-- The three doc-level rules — create-vs-enrich a DOC, link DOCS, rewrite a DOC
-- body — have no honest surface on either, so they are not force-fit there.
--
-- LIFELESS-CORE COMPLIANCE (v27): nothing here names a model or a provider. The
-- predicate, the constitution text, and the two channel patches are deterministic
-- SQL; the stages they land in name ROLES (reason/critic), resolved by the alias
-- router as everywhere else.
--
-- requires create_v35_graph_lint — chain position (after S2) and because rule 2's
-- text asserts stewards.graph_orphans exists as its detector. keeper_doc_is_record
-- reads graph_lint.autogen_source_kinds via config_get with the SAME default v35
-- seeds, so it classifies dated auto-generated snapshots (video/digest/crawl-page)
-- as records even before that config row is materialised. Purely additive: one
-- config seed, two functions, and two idempotent later-file-wins column/stage
-- patches of v08's doc_create description and v27's digester build stages.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — the record-kind boundary (operator-owned). The doc kinds that are
--      immutable HISTORY: rule 3 corrects them with a NEW dated entry, never by
--      rewriting the record. Default is the one unambiguous record kind in the
--      docs taxonomy (schema.rs: 'doc','study','proposal','phase-doc','journal').
--      The dated AUTO-GENERATED snapshots (video/digest/crawl-page) are folded in
--      via v35's graph_lint.autogen_source_kinds in §2 — a per-source digest is a
--      record of what a source said on a day, not standing knowledge to rewrite.
--      ON CONFLICT DO NOTHING: an operator who has already tuned this keeps it.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('keeper.record_kinds', '["journal"]'::jsonb,
   'keeper constitution (v36): doc KINDS that are immutable history — rule 3 (SUPERSEDE COMPLETELY) never rewrites them; a contradiction is corrected by a NEW dated entry. Default ["journal"]. The dated auto-generated snapshots (video/digest/crawl-page) are ALSO treated as records via graph_lint.autogen_source_kinds. Operator-owned: add any kind your deployment treats as an append-only record (e.g. a book digest you never revise).')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- §2 — is this doc a RECORD (immutable history), off-limits to rule 3?
--      The single definition of the living-vs-record boundary. True when:
--        (a) kind ∈ keeper.record_kinds (journal), OR
--        (b) kind ∈ graph_lint.autogen_source_kinds (v35: the dated autogen
--            snapshots — a digest/video/crawl-page is a record of a source at a
--            point in time), OR
--        (c) frontmatter.watchman ∈ (skip|exempt) — the EXACT gate the Watchman's
--            dirty_queue uses to exclude a doc from consolidation (v01). A doc the
--            operator has fenced off from the Watchman's rewriting is fenced off
--            from the keeper's too: one boundary, honoured by both.
--      Everything else — doc, study, proposal, phase-doc, book, case-file — is a
--      LIVING / current-state doc rule 3 may supersede. Scalar STABLE predicate,
--      the twin of graph_lint_is_autogen_source(kind, frontmatter).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.keeper_doc_is_record(
    p_kind text, p_frontmatter jsonb
) RETURNS boolean
LANGUAGE sql STABLE AS $fn$
    SELECT p_kind IN (
             SELECT jsonb_array_elements_text(
               stewards.config_get('keeper.record_kinds', '["journal"]'::jsonb)))
        OR p_kind IN (
             SELECT jsonb_array_elements_text(
               stewards.config_get('graph_lint.autogen_source_kinds',
                                    '["video","digest","crawl-page"]'::jsonb)))
        OR coalesce(lower(p_frontmatter->>'watchman'), '') IN ('skip','exempt');
$fn$;
COMMENT ON FUNCTION stewards.keeper_doc_is_record(text,jsonb) IS
'v36: the living-vs-record boundary for the keeper constitution''s rule 3 (SUPERSEDE COMPLETELY). true = an immutable RECORD (rule 3 must NOT rewrite it): kind ∈ keeper.record_kinds (journal) OR kind ∈ graph_lint.autogen_source_kinds (dated autogen snapshots) OR frontmatter.watchman ∈ (skip|exempt) — the same gate the Watchman''s dirty_queue uses, so "do not rewrite this doc" is one definition. false = a LIVING / current-state doc (doc/study/proposal/phase-doc/…) rule 3 may supersede.';

-- ---------------------------------------------------------------------
-- §3 — the canonical constitution text. ONE source of truth; §4/§5 splice it.
--      Rule 2 names graph_orphans (its detector); rule 3 names keeper_doc_is_record
--      and the journal/record + watchman:skip|exempt boundary — the constitution
--      and its deterministic oracles pointing at each other, by name.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.keeper_constitution()
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
SELECT $kc$## Knowledge-Keeper rules

You are tending ONE shared body of knowledge, not filing separate reports. Three rules bind every write you make to the corpus:

1. ENRICH OVER CREATE. Before you `doc_create`, search the corpus (`doc_search`, `doc_similar`) for a doc that already covers the same distinct entity or topic. A fact that is an ATTRIBUTE or detail of an existing doc belongs patched INTO that doc — build onto it, do not mint a near-duplicate beside it. Create a NEW doc only for a distinct entity or topic someone would look up on its own. (A dated record — a daily digest, a per-source digest — IS such a distinct entity: enrich-over-create governs standing knowledge, not the day's record.)

2. LINK BOTH WAYS. A doc nothing points at is invisible knowledge — unreachable by traversal, and flagged as an orphan by `stewards.graph_orphans` (the graph-health lint, the deterministic detector for this violation). So wire your doc into the graph: cite the corpus docs it genuinely relates to with inline links (its forward edges), and where a relationship truly matters the related doc should reference it back too — those back-edges the memory-tend loop proposes for you (Hinge-gated) when you cannot reach the other doc from your own draft. Never invent a relationship to beat the lint: a doc that genuinely relates to nothing yet is left as an honest orphan.

3. SUPERSEDE COMPLETELY — living docs only. When new knowledge CONTRADICTS what a living doc currently asserts, do not stack the new claim above the stale one. Update the doc to the new value, say briefly that it supersedes the prior one, and make sure the old statement no longer appears ANYWHERE in the doc — rewrite the whole body if that is what it takes. This governs LIVING / current-state docs ONLY (doc, study, proposal, phase-doc). It NEVER touches a RECORD: a journal entry, a dated digest, or any doc `keeper_doc_is_record()` flags (a record kind, an auto-generated dated snapshot, or a `watchman: skip`/`exempt` frontmatter) is immutable history — corrected by a NEW dated entry, never by rewriting the record.$kc$;
$fn$;
COMMENT ON FUNCTION stewards.keeper_constitution() IS
'v36: the canonical Knowledge-Keeper constitution (S3) — the three memory-write rules (ENRICH OVER CREATE / LINK BOTH WAYS / SUPERSEDE COMPLETELY, living-docs-only). One source of truth spliced into the doc_create tool description (§4, the universal-fallback channel) and the digester build-stage prompts (§5, the standards channel). Rule 2 names graph_orphans (v35); rule 3 names keeper_doc_is_record (§2) — constitution and oracle referencing each other.';

-- ---------------------------------------------------------------------
-- §4 — the tool-description channel (S1's universal fallback). Append a concise
--      keeper directive to doc_create's description so EVERY doc-construction
--      agent that holds the tool — core digesters AND operator overlays
--      (book/playlist/case-file, examples/) — reads the three rules even where
--      the fuller stage prompt (§5) does not reach. Column-level extend-don't-
--      reshape: only the description grows. Idempotent on the KEEPER RULES marker.
-- ---------------------------------------------------------------------
UPDATE stewards.tool_defs
   SET description = description || E'\n\n' ||
       'KEEPER RULES (you are tending one shared body of knowledge, not filing separate reports): '
       || '(1) ENRICH OVER CREATE — before creating, doc_search for an existing doc on the same distinct entity and build INTO it; create a new doc only for an entity someone would look up on its own. '
       || '(2) LINK BOTH WAYS — cite the related corpus docs with inline links, or the doc is invisible knowledge (stewards.graph_orphans flags it); never invent a link to beat the lint. '
       || '(3) SUPERSEDE COMPLETELY on LIVING docs — when new knowledge contradicts a living doc, rewrite so the stale claim appears nowhere; NEVER rewrite a journal or a dated record (immutable history — keeper_doc_is_record).'
 WHERE name = 'doc_create'
   AND description NOT LIKE '%KEEPER RULES%';

-- ---------------------------------------------------------------------
-- §5 — the stage-prompt channel (S1's standards channel). Append the FULL
--      constitution to the doc-construction BUILD stages of the core digesters.
--      Extend-don't-reshape via a jsonb_agg map that rewrites ONLY the matched
--      stage's input_template (WITH ORDINALITY preserves stage order; every other
--      key of the stage object is passed through untouched). Idempotent: the
--      ENRICH OVER CREATE marker guards against a second append, and the family +
--      shape guards keep it to the reviewed doc-construction build stages.
-- ---------------------------------------------------------------------
UPDATE stewards.pipelines p
   SET stages = (
        SELECT jsonb_agg(
                 CASE
                   WHEN e->>'name' = 'build'
                    AND (e->>'input_template') LIKE '%doc_append_section%'
                    AND (e->>'input_template') NOT LIKE '%ENRICH OVER CREATE%'
                   THEN jsonb_set(e, '{input_template}',
                          to_jsonb((e->>'input_template') || E'\n\n' || stewards.keeper_constitution()))
                   ELSE e
                 END ORDER BY ord)
          FROM jsonb_array_elements(p.stages) WITH ORDINALITY t(e, ord)),
       updated_at = now()
 WHERE p.family IN ('research-summary','research-write')
   AND p.stages::text LIKE '%doc_append_section%'
   AND p.stages::text NOT LIKE '%ENRICH OVER CREATE%';

-- =====================================================================
-- End of v36-keeper-constitution.sql
-- =====================================================================
