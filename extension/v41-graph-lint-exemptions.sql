-- =====================================================================
-- v41-graph-lint-exemptions.sql — the graph-health lint (v35) counts two
--   classes of NON-knowledge docs as orphans, drowning the real signal. This
--   exempts them from graph_orphans, the way v35 already exempts auto-generated
--   aggregation link SOURCES.
-- =====================================================================
-- v35 built the orphan oracle: a live corpus doc whose node has zero inbound
-- curated-relationship edges is "invisible knowledge" — the memory-tend
-- worklist. The oracle is honest, but on the live corpus (read 2026-07-18, in
-- the ROLLED-BACK validation below) 214 of 267 orphans are not knowledge units
-- at all — they are STORAGE artifacts that, by construction, nothing authored
-- will ever link to. Left in, they turn a 53-item worklist into a 267-item one
-- and hide the 27 doc-orphans that a human actually should look at.
--
-- Two unambiguous classes, each with a structural marker verified LIVE (see the
-- counts in each section). This migration exempts BOTH from graph_orphans.
--
--   1. MULTI-PART PDF INGESTION CHUNKS (210 of the 267). When a PDF is imported
--      it is split into per-page/per-part slices, each stored as its own
--      stewards.docs row. A slice is a byte-range of ONE parent PDF, not a
--      knowledge unit — no authored doc cites "part 27 of the rulebook", so
--      every slice is a permanent false orphan. Shared structural marker across
--      BOTH importer generations found live:
--        frontmatter ? 'part'   AND frontmatter ? 'corpus'
--        AND ( frontmatter->>'source_object' LIKE 'att:%'   -- backing attachment
--              OR frontmatter->>'imported_via' = 'doc-extract' )
--      Live breakdown of the 210: 96 carry the full doc-extract signature
--      (part+parts+corpus+imported_via='doc-extract', e.g. the MLP rulebook);
--      114 come from an EARLIER importer that stamped only part+corpus+
--      source_object='att:NN' (e.g. star-trek-core-NNN). Both are the same
--      thing — a numbered slice of a named parent, backed by an attachment.
--      FALSE-POSITIVE CHECK (live): zero docs in the whole corpus carry
--      part+corpus WITHOUT the att:/doc-extract signature, so the predicate is
--      exact. (Note: the tend that motivated this described the marker as the
--      fuller doc-extract field set; the real corpus count it produced — 210 —
--      includes the older att-backed slices, so the predicate keys on the
--      shared part+corpus+attachment shape, not on 'parts'/'imported_via'
--      alone, which would exempt only 96 and leave 114 obvious slices in the
--      worklist. The exempted count is verified against the live corpus, not
--      the field description.)
--
--   2. AGGREGATE-CHILDREN FAN-OUT INDEX DOCS (4 of the 267). A brainstorm /
--      fan-out run emits an "aggregator" index doc that gathers its children;
--      it is a pipeline bookkeeping artifact (frontmatter.source_type =
--      'aggregate-children', carrying intent_id + work_item_id, no authored
--      prose), never an inbound-link target. Operator-owned like v35's
--      autogen_source_kinds: the set of index source_types lives in
--      config (graph_lint.aggregate_index_source_types, default
--      ["aggregate-children"]), so a future fan-out index kind is a config row,
--      not a migration.
--
-- DELIBERATELY UNTOUCHED — the third class. The remaining 53 orphans after this
-- migration are 25 raw `video` docs (whose only inbound links come from their
-- own digests — the v35 autogen_source_kinds SOURCE-exclusion working exactly
-- as designed) plus 27 doc + 1 case-file that are genuine, human-worth-looking
-- orphans. Whether a raw video with only a digest-inbound link should itself
-- count as an orphan is a DESIGN call about the autogen-source rule, reserved
-- for the operator; this migration does NOT touch it, video docs, or the v35
-- autogen_source SOURCE predicate. It only narrows the orphan CANDIDATE set.
--
-- Scope: this touches ONLY the orphan CANDIDATE filter (the outer FROM of
-- graph_orphans). The exempted docs all have backing stewards.docs rows, so
-- they never appeared in graph_missing_doc_nodes or graph_dangling_edges (both
-- still 0 live) — there is nowhere else in the lint they are counted.
-- graph_health() and graph_health_tool() read graph_orphans unchanged, so they
-- pick up the narrower count automatically; the `healthy` boolean is the SAME
-- formula (no orphans AND no dangling) — after this migration the live graph is
-- orphans=53, dangling=0, missing=0, healthy=false (53 real orphans remain).
--
-- Validated LIVE 2026-07-18 in a ROLLED-BACK transaction: BEFORE 267/0/0/f,
-- AFTER 53/0/0/f. Data-only, idempotent (CREATE OR REPLACE + config
-- ON CONFLICT DO NOTHING).
-- requires: create_v40_probe_budget (tail of the chain).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — config seed: the operator-owned set of fan-out index source_types.
--      Defaults only; ON CONFLICT DO NOTHING so an upgrade never clobbers an
--      operator's set. Mirrors v35's autogen_source_kinds philosophy.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('graph_lint.aggregate_index_source_types', '["aggregate-children"]'::jsonb,
   'graph-health lint (v41): frontmatter.source_type values that mark a pipeline fan-out / aggregation INDEX doc (a bookkeeping artifact that gathers its children, never an inbound-link target). Such docs are exempted from graph_orphans. Operator-owned: add the source_type of any future fan-out index builder here — a config row, not a migration.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- §2 — is this doc a multi-part PDF ingestion CHUNK? Pure structural predicate
--      over frontmatter shape (no DB read → IMMUTABLE). A numbered slice
--      (part) of a named parent (corpus) that is backed by an attachment
--      (source_object att:NN) or was cut by the doc-extract importer.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.graph_lint_is_ingestion_chunk(
    p_frontmatter jsonb
) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $fn$
    SELECT coalesce(p_frontmatter ? 'part', false)
       AND coalesce(p_frontmatter ? 'corpus', false)
       AND ( coalesce(p_frontmatter->>'source_object','') LIKE 'att:%'
             OR coalesce(p_frontmatter->>'imported_via','') = 'doc-extract' );
$fn$;
COMMENT ON FUNCTION stewards.graph_lint_is_ingestion_chunk(jsonb) IS
'v41: true when a doc is a multi-part PDF ingestion chunk — a numbered slice (frontmatter.part) of a named parent (frontmatter.corpus) backed by an attachment (source_object LIKE ''att:%'') or cut by the doc-extract importer (imported_via=''doc-extract''). A storage artifact, never an authored-link target; exempted from graph_orphans. Live-verified exact: exempts 210, zero corpus-wide false positives.';

-- ---------------------------------------------------------------------
-- §3 — is this doc a fan-out / aggregation INDEX doc? (config-driven, like
--      v35's graph_lint_is_autogen_source). Reads config → STABLE.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.graph_lint_is_aggregate_index(
    p_frontmatter jsonb
) RETURNS boolean
LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(p_frontmatter->>'source_type','') IN (
             SELECT jsonb_array_elements_text(
               stewards.config_get('graph_lint.aggregate_index_source_types',
                                    '["aggregate-children"]'::jsonb)));
$fn$;
COMMENT ON FUNCTION stewards.graph_lint_is_aggregate_index(jsonb) IS
'v41: true when a doc is a pipeline fan-out / aggregation INDEX doc (frontmatter.source_type ∈ graph_lint.aggregate_index_source_types, default ["aggregate-children"]). A bookkeeping artifact, never an inbound-link target; exempted from graph_orphans.';

-- ---------------------------------------------------------------------
-- §4 — re-author graph_orphans (v35 §4) with the two exemptions added to the
--      orphan CANDIDATE filter (outer WHERE on d). The inbound-edge NOT EXISTS
--      body — including the v35 autogen-source SOURCE exclusion — is preserved
--      byte-for-byte; this migration ONLY narrows which docs are candidates.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.graph_orphans AS
    SELECT d.slug, d.kind, d.title
      FROM stewards.docs d
      JOIN stewards.nodes n ON n.kind = 'doc' AND n.ref = d.slug
     WHERE NOT EXISTS (
             SELECT 1
               FROM stewards.edges e
               JOIN stewards.edge_kinds ek ON ek.name = e.kind   -- curated verbs = "real relationship"
               JOIN stewards.nodes ns ON ns.id = e.src
              WHERE e.dst = n.id
                AND e.src <> n.id                                 -- a self-link is not a link
                AND NOT (                                         -- the source must be REAL:
                     ns.kind = 'doc' AND (
                         -- an auto-generated aggregation source does not rescue,
                         EXISTS (SELECT 1 FROM stewards.docs sd
                                  WHERE sd.slug = ns.ref
                                    AND stewards.graph_lint_is_autogen_source(sd.kind, sd.frontmatter))
                         -- nor does a deleted/missing doc,
                      OR NOT EXISTS (SELECT 1 FROM stewards.docs sd WHERE sd.slug = ns.ref)
                     )
                ))
       -- v41 exemptions: storage/bookkeeping artifacts that are permanent false
       -- orphans by construction (nothing authored will ever link to them).
       AND NOT stewards.graph_lint_is_ingestion_chunk(d.frontmatter)
       AND NOT stewards.graph_lint_is_aggregate_index(d.frontmatter);
COMMENT ON VIEW stewards.graph_orphans IS
'v35+v41: live corpus docs with inbound-degree zero over curated relationship edges (edge_kinds), counting only real sources — auto-generated aggregation docs and deleted/missing docs are excluded as sources (v35). v41 additionally exempts two non-knowledge CANDIDATE classes: multi-part PDF ingestion chunks (graph_lint_is_ingestion_chunk) and fan-out/aggregation index docs (graph_lint_is_aggregate_index), both permanent false orphans. The memory-tend worklist: docs nothing authored points at.';

-- =====================================================================
-- End of v41-graph-lint-exemptions.sql
-- =====================================================================
