-- =====================================================================
-- v42-unmined-sources.sql — the graph-health lint (v35) counted a class of
--   docs as ORPHANS that are not really orphans at all: auto-generated SOURCE
--   docs (videos, digests, crawl-pages) that ARE cross-linked into the graph
--   but whose only inbound links come from other auto-generated sources. v35's
--   autogen-source SOURCE-exclusion (working exactly as designed) discounts
--   those inbound links, so the doc lands in the orphan worklist. v41 already
--   reserved this call to the operator; this migration IS that call.
-- =====================================================================
-- THE OPERATOR RULING (2026-07-18): "I like the 'unmined sources' signal.
-- make it so." — these docs are not orphans, they are UNMINED: watched, filed,
-- and cross-linked (their curated video<->video edges), but never yet drawn on
-- by an AUTHORED study. Keep the honest signal, renamed. An orphan is a knowledge
-- unit nothing points at (a human should wire it or leave it); an UNMINED source
-- is external material you've filed and connected but not yet mined into authored
-- work — a reading/mining candidate, NOT a linking worklist and NOT a blocker on
-- graph health.
--
-- v41's own header named the boundary it would not cross: "Whether a raw video
-- with only a digest-inbound link should itself count as an orphan is a DESIGN
-- call about the autogen-source rule, reserved for the operator; this migration
-- does NOT touch it." v42 makes that design call. It does NOT touch the v35
-- autogen-source SOURCE predicate, the v41 exemptions, or any doc/edge data —
-- it reclassifies a subset of the v41 orphan set into a new sibling view and
-- narrows graph_orphans to exclude exactly that subset.
--
-- ---------------------------------------------------------------------
-- THE BOUNDARY, decided precisely after reading the v35 predicate (v35 §4) and
-- verified against the LIVE corpus (scripts/db.sh, 2026-07-18, read-only):
--
--   A doc is UNMINED when ALL of:
--     (1) it is itself an auto-generated SOURCE doc — graph_lint_is_autogen_source
--         (kind in graph_lint.autogen_source_kinds, e.g. video/digest/crawl-page,
--         OR frontmatter.origin in graph_lint.autogen_source_origins). An unmined
--         SOURCE must be a source; a PLAIN authored doc whose only inbound happens
--         to come from a video is a GENUINE orphan (a human should ask why only a
--         video links it) and stays in graph_orphans. This condition is what keeps
--         that case honest — see virgin-smoke test 115's vs115-orphan2.
--     (2) it passes the v41 candidate exemptions (a PDF ingestion chunk or a
--         fan-out aggregate-index doc is a storage artifact, never a "source").
--     (3) it is a v35 ORPHAN: zero inbound curated edges from a REAL source
--         (the v35 §4 inbound test, byte-for-byte).
--     (4) it WOULD be rescued if the autogen-source SOURCE-exclusion were lifted:
--         it has >= 1 inbound curated edge from a LIVE auto-generated doc. That
--         discounted inbound edge is the "cross-linked / watched / filed" signal
--         that makes it UNMINED rather than a truly-edgeless plain orphan.
--
--   A TRULY EDGELESS auto-generated doc (a raw video nobody digested or linked)
--   fails (4) and stays a plain orphan — exactly as the ruling requires ("a truly
--   edgeless video stays a plain orphan"). (4) is the razor between the two.
--
--   graph_orphans (v41) is therefore a clean PARTITION: the v42 orphans (docs
--   nothing authored points at) + graph_unmined_sources (filed sources not yet
--   mined). No doc moves out of the lint entirely; it just moves to the honest bin.
--
-- ---------------------------------------------------------------------
-- LIVE SPLIT (verified 2026-07-18 in the ROLLED-BACK validation; the corpus
-- drifts day to day, so these are the real numbers on this date, NOT the round
-- estimate v41's header carried):
--   v35 orphans (before any exemption) ......... 265
--   - v41 PDF ingestion chunks (exempt) ........ 210
--   - v41 aggregate-index docs (exempt) ..........  4
--   = v41 orphan set ...........................  51
--   of which UNMINED (this migration) ..........  11  (all kind='video', each with
--                                                       curated video<->video edges,
--                                                       inbound discounted by v35)
--   = v42 orphans (remain) .....................  40  (14 truly-edgeless videos +
--                                                       1 edgeless workspace/file-drop
--                                                       doc + 24 authored docs +
--                                                       1 case-file — genuine orphans)
--
--   NOTE on the split vs v41's header estimate: v41's header said "25 videos"
--   move to unmined. On the live corpus only 11 of the 25 video-orphans are
--   actually cross-linked; the other 14 are truly edgeless (zero curated edges
--   of any kind) and CORRECTLY stay as plain orphans under the boundary above.
--   The "25" conflated all video-orphans with the digest-linked subset. The
--   real, verified split is 11 unmined / 40 orphan. (graph_health's `healthy`
--   stays false either way — 40 real orphans remain.)
--
--   dangling=0, missing=0 on live: the unmined docs all have backing docs rows,
--   so they never appeared in graph_missing_doc_nodes / graph_dangling_edges —
--   there is nowhere else in the lint they are counted.
--
-- graph_health()/graph_health_tool() gain an `unmined_count` field. The `healthy`
-- boolean is the SAME formula (no orphans AND no dangling edges) — UNMINED does
-- NOT block healthy: a filed-but-not-yet-mined source is not a defect, it is a
-- backlog. That is the whole point of the rename.
--
-- Data-only, idempotent (CREATE OR REPLACE views + DROP FUNCTION IF EXISTS /
-- CREATE + tool_defs ON CONFLICT DO UPDATE). No config knob is added: the class
-- is fully determined by the existing v35 autogen predicate + v41 exemptions +
-- the graph, so there is nothing new for an operator to tune.
-- requires: create_v41_graph_lint_exemptions (tail of the chain).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — graph_unmined_sources: the reclassified bin. Same v41 orphan CANDIDATE
--      base + v35 orphan inbound test, PLUS "is itself an autogen source" (1) and
--      "has a discounted autogen inbound edge" (4). This is a SUBSET of the v41
--      orphan set by construction.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.graph_unmined_sources AS
    SELECT d.slug, d.kind, d.title
      FROM stewards.docs d
      JOIN stewards.nodes n ON n.kind = 'doc' AND n.ref = d.slug
     WHERE
       -- (1) the doc is itself an auto-generated SOURCE (a filed external artifact)
       stewards.graph_lint_is_autogen_source(d.kind, d.frontmatter)
       -- (2) v41 candidate exemptions: a chunk/index is a storage artifact, not a source
       AND NOT stewards.graph_lint_is_ingestion_chunk(d.frontmatter)
       AND NOT stewards.graph_lint_is_aggregate_index(d.frontmatter)
       -- (3) it is a v35 ORPHAN — zero inbound curated edges from a REAL source
       --     (this NOT EXISTS block is v35 §4 preserved byte-for-byte)
       AND NOT EXISTS (
             SELECT 1
               FROM stewards.edges e
               JOIN stewards.edge_kinds ek ON ek.name = e.kind   -- curated verbs = "real relationship"
               JOIN stewards.nodes ns ON ns.id = e.src
              WHERE e.dst = n.id
                AND e.src <> n.id                                 -- a self-link is not a link
                AND NOT (                                         -- the source must be REAL:
                     ns.kind = 'doc' AND (
                         EXISTS (SELECT 1 FROM stewards.docs sd
                                  WHERE sd.slug = ns.ref
                                    AND stewards.graph_lint_is_autogen_source(sd.kind, sd.frontmatter))
                      OR NOT EXISTS (SELECT 1 FROM stewards.docs sd WHERE sd.slug = ns.ref)
                     )
                ))
       -- (4) but it has >= 1 inbound curated edge from a LIVE auto-generated doc —
       --     the discounted "cross-linked / watched / filed" signal. Lifting the
       --     autogen SOURCE-exclusion would rescue it: that is what makes it UNMINED
       --     rather than a truly-edgeless plain orphan.
       AND EXISTS (
             SELECT 1
               FROM stewards.edges e
               JOIN stewards.edge_kinds ek ON ek.name = e.kind
               JOIN stewards.nodes ns ON ns.id = e.src
               JOIN stewards.docs sd ON sd.slug = ns.ref          -- source is a LIVE doc
              WHERE e.dst = n.id
                AND e.src <> n.id
                AND ns.kind = 'doc'
                AND stewards.graph_lint_is_autogen_source(sd.kind, sd.frontmatter));
COMMENT ON VIEW stewards.graph_unmined_sources IS
'v42: auto-generated SOURCE docs (graph_lint_is_autogen_source: video/digest/crawl-page or file-drop/workspace origin) that are v35 orphans ONLY because the autogen-source SOURCE-exclusion discounts their inbound links — i.e. they are cross-linked (>=1 inbound curated edge from a live autogen doc) but no AUTHORED study draws on them. UNMINED, not orphaned: watched/filed/cross-linked, not yet mined. A truly-edgeless autogen doc has no such inbound edge and stays a plain orphan (graph_orphans). A subset of the v41 orphan set; removed from graph_orphans by this migration. Does NOT block graph_health.healthy.';

-- ---------------------------------------------------------------------
-- §2 — re-author graph_orphans (v35 §4 + v41 §4) to EXCLUDE the unmined subset.
--      The v41 predicate (v35 inbound test + the two v41 candidate exemptions) is
--      preserved exactly; the only change is the final NOT EXISTS against
--      graph_unmined_sources, which subtracts the reclassified docs. Output columns
--      (slug, kind, title) are unchanged, so v36's keeper-constitution detector and
--      graph_health_tool's worklist keep working.
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
       AND NOT stewards.graph_lint_is_aggregate_index(d.frontmatter)
       -- v42: the UNMINED subset is not an orphan — it is a filed source not yet
       -- mined. Reclassified into graph_unmined_sources; excluded here.
       AND NOT EXISTS (SELECT 1 FROM stewards.graph_unmined_sources u WHERE u.slug = d.slug);
COMMENT ON VIEW stewards.graph_orphans IS
'v35+v41+v42: live corpus docs with inbound-degree zero over curated relationship edges (edge_kinds), counting only real sources — auto-generated aggregation docs and deleted/missing docs excluded as sources (v35). v41 exempts two non-knowledge CANDIDATE classes (ingestion chunks, aggregate-index docs). v42 additionally excludes graph_unmined_sources — auto-generated sources that are cross-linked but never mined by an authored study (reclassified, not dropped). The memory-tend worklist: docs nothing authored points at, that a human should wire or leave.';

-- ---------------------------------------------------------------------
-- §3 — graph_health(): add unmined_count. The output signature changes (a new
--      column), which CREATE OR REPLACE cannot do, so DROP + CREATE. Drop the
--      tool first (it reads graph_health) so no dependency blocks the drop; both
--      are recreated below. `healthy` is UNCHANGED: (no orphans) AND (no dangling).
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS stewards.graph_health_tool(jsonb);
DROP FUNCTION IF EXISTS stewards.graph_health();

CREATE FUNCTION stewards.graph_health()
RETURNS TABLE (orphan_count int, unmined_count int, dangling_edge_count int, missing_doc_count int, healthy boolean)
LANGUAGE sql STABLE AS $fn$
    SELECT (SELECT count(*)::int FROM stewards.graph_orphans),
           (SELECT count(*)::int FROM stewards.graph_unmined_sources),
           (SELECT count(*)::int FROM stewards.graph_dangling_edges),
           (SELECT count(*)::int FROM stewards.graph_missing_doc_nodes),
           (SELECT count(*) FROM stewards.graph_orphans) = 0
             AND (SELECT count(*) FROM stewards.graph_dangling_edges) = 0;
$fn$;
COMMENT ON FUNCTION stewards.graph_health() IS
'v35+v42: graph-health summary — orphan_count, unmined_count (v42: filed sources not yet mined), dangling_edge_count, missing_doc_count, and healthy = (no orphans AND no dangling edges). UNMINED does NOT affect healthy — it is a backlog, not a defect. The deterministic oracle memory-tend reports before->after.';

-- ---------------------------------------------------------------------
-- §4 — graph_health_tool(jsonb)->text: add unmined_count + a capped unmined
--      worklist to the JSON, and explain the bin in the note. jsonb-in/out, never
--      RAISEs (house convention). Same cap knob (limit, default 25, max 200).
-- ---------------------------------------------------------------------
CREATE FUNCTION stewards.graph_health_tool(p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $fn$
    WITH lim AS (SELECT greatest(1, least(coalesce((p_args->>'limit')::int, 25), 200)) AS n),
    h AS (SELECT * FROM stewards.graph_health()),
    orph AS (
        SELECT coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'kind', kind, 'title', title)
                        ORDER BY slug), '[]'::jsonb) AS j
          FROM (SELECT slug, kind, title FROM stewards.graph_orphans
                 ORDER BY slug LIMIT (SELECT n FROM lim)) s),
    unmined AS (
        SELECT coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'kind', kind, 'title', title)
                        ORDER BY slug), '[]'::jsonb) AS j
          FROM (SELECT slug, kind, title FROM stewards.graph_unmined_sources
                 ORDER BY slug LIMIT (SELECT n FROM lim)) s),
    dang AS (
        SELECT coalesce(jsonb_agg(jsonb_build_object('edge_id', edge_id, 'edge_kind', edge_kind,
                        'missing_slug', missing_slug, 'missing_end', missing_end)
                        ORDER BY missing_slug), '[]'::jsonb) AS j
          FROM (SELECT edge_id, edge_kind, missing_slug, missing_end
                  FROM stewards.graph_dangling_edges
                 ORDER BY missing_slug LIMIT (SELECT n FROM lim)) s)
    SELECT jsonb_build_object(
        'healthy',             (SELECT healthy FROM h),
        'orphan_count',        (SELECT orphan_count FROM h),
        'unmined_count',       (SELECT unmined_count FROM h),
        'dangling_edge_count', (SELECT dangling_edge_count FROM h),
        'missing_doc_count',   (SELECT missing_doc_count FROM h),
        'orphans',             (SELECT j FROM orph),
        'unmined_sources',     (SELECT j FROM unmined),
        'dangling_edges',      (SELECT j FROM dang),
        'note', CASE WHEN (SELECT healthy FROM h)
                     THEN 'graph healthy — no orphans, no dangling edges.' ||
                          CASE WHEN (SELECT unmined_count FROM h) > 0
                               THEN ' (' || (SELECT unmined_count FROM h) || ' unmined sources are filed but not yet drawn on by an authored study — a reading backlog, not a defect.)'
                               ELSE '' END
                     ELSE 'worklist. ORPHANS: for the ones that genuinely relate to existing work, propose a typed link (memory_link_propose) — do NOT invent a relationship; if an orphan relates to nothing, leave it. UNMINED SOURCES: auto-generated sources (videos/digests) you have filed and cross-linked but no authored study draws on yet — a MINING candidate list (read/study one, then let an authored doc CITE it), NOT a linking worklist; they do not block health. DANGLING EDGES: they reference deleted/missing corpus docs — surface for repair (re-import or prune), do not guess.'
                END
    )::text;
$fn$;
COMMENT ON FUNCTION stewards.graph_health_tool(jsonb) IS
'v35+v42: graph-health lint as a tool — counts (incl. unmined_count) + healthy + capped worklists (orphans, unmined_sources, dangling_edges; limit default 25, max 200). Wired into the memory-tend tool group.';

-- Refresh the tool registration description so the tool surface documents unmined.
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'graph_health',
  'Deterministic health check on the memory graph: orphan_count (docs nothing authored links to), unmined_count (auto-generated sources you filed and cross-linked but never mined into an authored study — a backlog, not a defect), dangling_edge_count (edges pointing at deleted/missing docs), missing_doc_count, a healthy boolean (no orphans AND no dangling — unmined does NOT block it), and capped worklists. Call it at the START and END of a tending pass to report before->after.',
  '{"type":"object","properties":{"limit":{"type":"integer","description":"max worklist rows per list (default 25, max 200)"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"graph_health_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- =====================================================================
-- End of v42-unmined-sources.sql
-- =====================================================================
