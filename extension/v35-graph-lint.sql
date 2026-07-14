-- ===== v35-graph-lint.sql =====
-- =====================================================================
-- v35-graph-lint.sql — the graph-health lint (S2): a deterministic oracle
--   over the doc relationship graph, feeding memory-tend a WORKLIST instead
--   of vibes.
-- =====================================================================
-- Ported from Understory's librarian-memory lint (proposal
-- .spec/proposals/understory-steals.md §S2). Two health signals, both
-- computed straight from the relational graph (01-graph in v00) + the docs
-- corpus (create_docs in schema.rs), no LLM in the loop:
--
--   ORPHANS        — a live corpus doc whose graph node has ZERO inbound
--                    edges of a genuine relationship kind. Nothing points AT
--                    it, so it is unreachable by traversal — invisible
--                    knowledge.
--   DANGLING EDGES — an edge whose endpoint is a doc-kind node with no
--                    backing stewards.docs row: a relationship asserted to a
--                    corpus doc that was deleted, or that was never imported.
--
-- healthy = (no orphans) AND (no dangling edges). memory-tend (41, v09) reads
-- graph_health at the top AND tail of its pass and reports before→after — the
-- oracle of its own tending (detect → fix → re-detect → green).
--
-- ---------------------------------------------------------------------
-- Schema surfaces this reads (verified LIVE via scripts/db.sh before a line
-- was written — the same discipline v26/v28 headers document):
--   * stewards.nodes   (v00) — graph vertices. A DOC always gets a node with
--     kind='doc', ref=<slug>; import_doc stamps props.id/file_path/doc_kind.
--     The node's kind is ALWAYS 'doc' regardless of the doc's OWN kind — the
--     doc kind (study/video/digest/…) lives in stewards.docs.kind and in
--     node.props->>'doc_kind', NEVER in node.kind. Every autogen/kind test
--     below therefore joins to stewards.docs.kind, never to nodes.kind.
--   * stewards.edges   (v00) — typed directed edges, src/dst → nodes (FK
--     ON DELETE CASCADE, so an edge can never outlive its NODES; a "dangling"
--     edge is one whose node has no backing DOC ROW, a different thing).
--   * stewards.edge_kinds (v09) — the curated relationship-verb registry.
--     This IS the substrate's own definition of "a genuine typed knowledge
--     relationship" (CITES, RELATES_TO, BUILDS_ON, SUPPORTS, …). We reuse it
--     as the boundary for "real relationship edge": structural/bookkeeping
--     edges the importers mint but never register here — HAS_PROPOSAL
--     (workstream membership), HAS_PHASE, HAS_TODO, and the frontmatter
--     shortcuts FEEDS/IMPLEMENTS — are deliberately NOT in edge_kinds, so they
--     do NOT rescue a doc from orphan status. Self-maintaining: registering a
--     verb in edge_kinds (a row, not a migration) makes it count automatically.
--   * stewards.docs    (schema.rs create_docs) — id/slug/kind/frontmatter.
--
-- ---------------------------------------------------------------------
-- THE UNDERSTORY SUBTLETY WE PORT — auto-generated sources must not drown the
-- signal. In Understory a generated CATALOG (a table-of-contents file that
-- links every concept) makes every file look linked, hiding the real orphans;
-- its lint excludes reserved/auto-generated files as link SOURCES.
--
-- Our equivalent, grounded in the live corpus (read 2026-07-14): we have NO
-- whole-corpus catalog today — the highest doc→doc fan-out is 5 (a video
-- digest citing its handful of sources). The drowning risk is therefore
-- LATENT, not active. It arrives with the first digest-index or
-- projection-catalog builder that enumerates the whole corpus. So we build the
-- exclusion now, deterministic and OPERATOR-OWNED (the substrate's "operators
-- own the rows" philosophy — config seeds are defaults, upgrades never
-- overwrite):
--
--   graph_lint.autogen_source_kinds   (default ["video","digest","crawl-page"])
--       doc kinds whose OUTBOUND links are machine-parsed digests of external
--       material, not authored cross-references. A doc whose ONLY inbound link
--       comes from such an aggregation is still effectively an orphan (no
--       AUTHORED doc points at it), so we drop those as link sources.
--   graph_lint.autogen_source_origins (default ["file-drop","workspace"])
--       frontmatter.origin markers for machine-projected docs (v28 file-drop,
--       v30 workspace projection).
--
-- When a future builder emits a whole-corpus index doc, adding its kind (or a
-- frontmatter marker) is a config UPDATE, not a migration. The exclusion also
-- drops MISSING/phantom doc nodes as sources — a deleted doc is not a real
-- link source either.
--
-- requires: create_v34_park_honesty (tail of the chain; additive — new views,
-- functions, config seeds, one tool, and a later-file-wins re-author of the
-- memory-tend tool_group + pipeline from v09).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — config seeds (the operator-owned exclusion knobs). Defaults only;
--      ON CONFLICT DO NOTHING so an upgrade never clobbers an operator's set.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('graph_lint.autogen_source_kinds', '["video","digest","crawl-page"]'::jsonb,
   'graph-health lint (v35): doc KINDS treated as auto-generated aggregation link sources — their outbound links do NOT rescue a doc from orphan status (a doc linked ONLY by an aggregation is still effectively orphaned). Port of Understory''s "generated catalogs link everything" exclusion. Operator-owned: add the kind of any whole-corpus index/catalog builder here.'),
  ('graph_lint.autogen_source_origins', '["file-drop","workspace"]'::jsonb,
   'graph-health lint (v35): frontmatter.origin values for machine-projected docs (v28 file-drop, v30 workspace) treated as auto-generated link sources, same rule as autogen_source_kinds.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- §2 — is this doc an auto-generated aggregation SOURCE? (config-driven)
--      Scalar STABLE predicate; the views call it per candidate source doc.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.graph_lint_is_autogen_source(
    p_kind text, p_frontmatter jsonb
) RETURNS boolean
LANGUAGE sql STABLE AS $fn$
    SELECT p_kind IN (
             SELECT jsonb_array_elements_text(
               stewards.config_get('graph_lint.autogen_source_kinds',
                                    '["video","digest","crawl-page"]'::jsonb)))
        OR coalesce(p_frontmatter->>'origin','') IN (
             SELECT jsonb_array_elements_text(
               stewards.config_get('graph_lint.autogen_source_origins',
                                    '["file-drop","workspace"]'::jsonb)));
$fn$;
COMMENT ON FUNCTION stewards.graph_lint_is_autogen_source(text,jsonb) IS
'v35: true when a doc is an auto-generated aggregation link source (kind ∈ graph_lint.autogen_source_kinds OR frontmatter.origin ∈ graph_lint.autogen_source_origins). Excluded as an edge SOURCE in orphan detection so generated catalogs cannot drown real orphans.';

-- ---------------------------------------------------------------------
-- §3 — missing corpus-doc nodes: doc-kind nodes with no backing docs row
--      that genuinely REPRESENT a corpus doc (so an external/relative-path
--      citation is NOT mistaken for a deleted doc).
--
--      Precision guard (the false-positive trap, verified live): parse_doc_links
--      (schema.rs) types every non-http link target as a 'doc' node. In a
--      scripture-study overlay those become their own kinds (scripture/talk/
--      manual), but in the CORE a relative-path citation like
--      "../gospel-library/…/130.md" IS a 'doc' node with no backing row — and
--      it is NOT a missing corpus doc, just an external citation. We keep it
--      out with two positive signals of "this WAS/should-be a corpus doc":
--        (a) props ? 'id'  — the node was minted by import_doc for a real doc
--            (the deleted-doc case; all 100 live danglers carry it), OR
--        (b) it participates in a NON-CITES edge — a declared/asserted
--            relationship verb (BUILDS_ON, SUPERSEDES, RELATES_TO, FEEDS, …)
--            only ever targets a corpus doc by slug (the broken-authored-link
--            case). CITES-only, no-props path targets are external → excluded.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.graph_missing_doc_nodes AS
    SELECT n.id AS node_id, n.ref AS slug, n.props
      FROM stewards.nodes n
     WHERE n.kind = 'doc'
       AND NOT EXISTS (SELECT 1 FROM stewards.docs d WHERE d.slug = n.ref)
       AND ( n.props ? 'id'
             OR EXISTS (SELECT 1 FROM stewards.edges e
                         WHERE (e.src = n.id OR e.dst = n.id)
                           AND e.kind <> 'CITES') );
COMMENT ON VIEW stewards.graph_missing_doc_nodes IS
'v35: doc-kind graph nodes that represent a corpus doc which no longer exists (deleted, or a declared/asserted reference to a slug never imported). External/relative-path CITES targets are excluded. The referents of graph_dangling_edges.';

-- ---------------------------------------------------------------------
-- §4 — ORPHANS: a live corpus doc whose node has ZERO inbound edges of a
--      curated relationship kind from a REAL source (a live, non-autogen doc,
--      or any non-doc node). Self-edges never count.
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
                ));
COMMENT ON VIEW stewards.graph_orphans IS
'v35: live corpus docs with inbound-degree zero over curated relationship edges (edge_kinds), counting only real sources — auto-generated aggregation docs and deleted/missing docs are excluded as sources. The memory-tend worklist: docs nothing authored points at.';

-- ---------------------------------------------------------------------
-- §5 — DANGLING EDGES: edges touching a missing corpus-doc node (either end).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.graph_dangling_edges AS
    SELECT e.id       AS edge_id,
           e.kind     AS edge_kind,
           ns.kind    AS src_kind, ns.ref AS src_ref,
           nd.kind    AS dst_kind, nd.ref AS dst_ref,
           CASE WHEN md.node_id IS NOT NULL THEN 'dst' ELSE 'src' END AS missing_end,
           coalesce(md.slug, ms.slug) AS missing_slug
      FROM stewards.edges e
      JOIN stewards.nodes ns ON ns.id = e.src
      JOIN stewards.nodes nd ON nd.id = e.dst
      LEFT JOIN stewards.graph_missing_doc_nodes md ON md.node_id = e.dst
      LEFT JOIN stewards.graph_missing_doc_nodes ms ON ms.node_id = e.src
     WHERE md.node_id IS NOT NULL OR ms.node_id IS NOT NULL;
COMMENT ON VIEW stewards.graph_dangling_edges IS
'v35: edges whose src or dst is a missing corpus-doc node (graph_missing_doc_nodes) — a relationship asserted to a deleted or never-imported corpus doc. missing_slug names the absent doc; missing_end says which endpoint. The repair worklist.';

-- ---------------------------------------------------------------------
-- §6 — graph_health(): the one-row summary + healthy boolean. The oracle.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.graph_health()
RETURNS TABLE (orphan_count int, dangling_edge_count int, missing_doc_count int, healthy boolean)
LANGUAGE sql STABLE AS $fn$
    SELECT (SELECT count(*)::int FROM stewards.graph_orphans),
           (SELECT count(*)::int FROM stewards.graph_dangling_edges),
           (SELECT count(*)::int FROM stewards.graph_missing_doc_nodes),
           (SELECT count(*) FROM stewards.graph_orphans) = 0
             AND (SELECT count(*) FROM stewards.graph_dangling_edges) = 0;
$fn$;
COMMENT ON FUNCTION stewards.graph_health() IS
'v35: graph-health summary — orphan_count, dangling_edge_count, missing_doc_count, and healthy = (no orphans AND no dangling edges). The deterministic oracle memory-tend reports before→after.';

-- ---------------------------------------------------------------------
-- §7 — the tool surface: graph_health_tool(jsonb)->text. jsonb-in/jsonb-out,
--      never RAISEs (the house tool convention). Ships the counts + healthy +
--      a CAPPED sample of each worklist (default 25; "…and N more" via the
--      counts) so it informs the tending pass without flooding context.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.graph_health_tool(p_args jsonb)
RETURNS text
LANGUAGE sql STABLE AS $fn$
    WITH lim AS (SELECT greatest(1, least(coalesce((p_args->>'limit')::int, 25), 200)) AS n),
    h AS (SELECT * FROM stewards.graph_health()),
    orph AS (
        SELECT coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'kind', kind, 'title', title)
                        ORDER BY slug), '[]'::jsonb) AS j
          FROM (SELECT slug, kind, title FROM stewards.graph_orphans
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
        'dangling_edge_count', (SELECT dangling_edge_count FROM h),
        'missing_doc_count',   (SELECT missing_doc_count FROM h),
        'orphans',             (SELECT j FROM orph),
        'dangling_edges',      (SELECT j FROM dang),
        'note', CASE WHEN (SELECT healthy FROM h)
                     THEN 'graph healthy — no orphans, no dangling edges.'
                     ELSE 'worklist. ORPHANS: for the ones that genuinely relate to existing work, propose a typed link (memory_link_propose) — do NOT invent a relationship; if an orphan relates to nothing, leave it. DANGLING EDGES: they reference deleted/missing corpus docs — surface for repair (re-import or prune), do not guess.'
                END
    )::text;
$fn$;
COMMENT ON FUNCTION stewards.graph_health_tool(jsonb) IS
'v35: graph-health lint as a tool — counts + healthy + capped worklists (limit default 25, max 200). Wired into the memory-tend tool group.';

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'graph_health',
  'Deterministic health check on the memory graph: orphan_count (docs nothing links to), dangling_edge_count (edges pointing at deleted/missing docs), missing_doc_count, a healthy boolean (no orphans AND no dangling), and capped worklists. Call it at the START and END of a tending pass to report before→after.',
  '{"type":"object","properties":{"limit":{"type":"integer","description":"max worklist rows per list (default 25, max 200)"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"graph_health_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- Grant it to the research family (the memory-tend stage's agent_family, v09).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','graph_health','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ---------------------------------------------------------------------
-- §8 — wire graph_health into memory-tend (41, v09). Later-file-wins
--      re-authors: add graph_health to the tool group, and re-author the
--      pipeline's single 'tend' stage input_template so the loop reads the
--      health worklist FIRST and reports before→after. Extend, don't reshape —
--      the stage/model/agent_family/tool_groups shape is preserved from v09.
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('memory-tend', 'the self-tending loop tools (health lint, walk, find candidates, propose typed links)',
     ARRAY['graph_health','graph_recall','graph_link_candidates','memory_link_propose','graph_vocabulary','doc_search','doc_get'])
ON CONFLICT (name) DO UPDATE SET
    tool_patterns = EXCLUDED.tool_patterns, description = EXCLUDED.description;

INSERT INTO stewards.pipelines (family, description, stages, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES (
  'memory-tend',
  'The self-tending loop: read graph health, wire orphans (Hinge-gated links), surface dangling edges, and report before→after. Slow + gentle — the memory grows its own connections and keeps itself honest.',
  jsonb_build_array(jsonb_build_object(
    'name','tend','next', NULL, 'model','reason','agent_family','research',
    'auto_advance', true, 'tools_disabled', false,
    'tool_groups', jsonb_build_array('memory-tend'),
    'input_template',
      'You are the memory-tend stage — you keep the knowledge graph alive AND healthy.' || E'\n\n' ||
      '1. Call `graph_health`. Note the BEFORE counts: orphan_count (docs nothing links to), dangling_edge_count (edges pointing at deleted/missing docs), and read the worklists it returns.' || E'\n' ||
      '2. ORPHANS: for a FEW orphans that genuinely relate to existing work, use `graph_link_candidates` and `doc_search` to find the real relationship, then call `memory_link_propose` with a canonical verb (call `graph_vocabulary` if unsure) + a one-line reason. Each goes to the Hinge. Prefer precision over volume. Do NOT invent a relationship — if an orphan genuinely relates to nothing, leave it.' || E'\n' ||
      '3. DANGLING EDGES: each references a corpus doc that no longer exists. Do NOT guess a repair — list them in your journal for a human (re-import the missing doc, or prune the stale edge).' || E'\n' ||
      '4. Call `graph_health` again. Reply with a short journal: the BEFORE→AFTER counts (orphans, dangling), which links you proposed and why, and any dangling edges surfaced. (Proposed links land as the Hinge approves them, so the orphan count usually drops over later passes, not within this one.)'
  )),
  '["raw","verified"]'::jsonb, false, jsonb_build_object('pools_via_tool', true))
ON CONFLICT (family) DO UPDATE SET
    stages = EXCLUDED.stages, description = EXCLUDED.description, updated_at = now();

-- =====================================================================
-- End of v35-graph-lint.sql
-- =====================================================================
