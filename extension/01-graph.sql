-- =====================================================================
-- 01-graph — the relational graph (nodes, edges, walks)
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg; NEW — replaces Apache AGE).
-- Ratified design: plain tables + recursive CTEs give the substrate
-- everything it used AGE for, with the full Postgres toolbox (indexes,
-- RLS, partitioning) and none of the install friction. Prior art:
-- gospel-engine's SQLite edges; SQL:2023 PGQ; Facebook TAO.
--
-- Design inputs (ratified 2026-06-12):
--   - N-depth walks are a requirement: docs CHAIN (BUILDS_ON lineage).
--   - Cycles are SAFE in the data graph — walks terminate via visited-
--     path arrays. The WORK graph keeps its own depth caps (subagents);
--     that wall is governance, not storage.
--   - Edge kinds are open data: CITES, BUILDS_ON, DECLARED today;
--     a new kind is a new row, never a schema change.
--
-- Generic by design: doc-specific conveniences (doc_lineage,
-- doc_citations) live with the corpus subsystem, built on these walks.
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.nodes (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind       text NOT NULL,            -- 'doc' | 'workstream' | 'todo' | 'phase' | ...
    ref        text,                     -- stable external reference (doc slug, WS code)
    label      text,
    props      jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ref is the upsert identity when present; allow ref-less anonymous nodes.
CREATE UNIQUE INDEX IF NOT EXISTS nodes_kind_ref_uq
    ON stewards.nodes (kind, ref) WHERE ref IS NOT NULL;
CREATE INDEX IF NOT EXISTS nodes_kind_idx ON stewards.nodes (kind);

CREATE TABLE IF NOT EXISTS stewards.edges (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    src        uuid NOT NULL REFERENCES stewards.nodes(id) ON DELETE CASCADE,
    dst        uuid NOT NULL REFERENCES stewards.nodes(id) ON DELETE CASCADE,
    kind       text NOT NULL,            -- 'CITES' | 'BUILDS_ON' | 'DECLARED' | ...
    weight     real NOT NULL DEFAULT 1.0,
    props      jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (src, dst, kind)
);

CREATE INDEX IF NOT EXISTS edges_src_kind_idx ON stewards.edges (src, kind);
CREATE INDEX IF NOT EXISTS edges_dst_kind_idx ON stewards.edges (dst, kind);

COMMENT ON TABLE stewards.nodes IS
  'Graph vertices. kind+ref is the stable identity for upserts; props is open jsonb.';
COMMENT ON TABLE stewards.edges IS
  'Typed, weighted, directed edges. Edge kinds are open data — adding a kind is a row, not a migration.';

-- ---------------------------------------------------------------------
-- Upsert helpers (ref-based, for importers and tools)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.graph_node_upsert(
    p_kind text, p_ref text, p_label text DEFAULT NULL, p_props jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_id uuid;
BEGIN
    INSERT INTO stewards.nodes (kind, ref, label, props)
    VALUES (p_kind, p_ref, p_label, COALESCE(p_props, '{}'::jsonb))
    ON CONFLICT (kind, ref) WHERE ref IS NOT NULL
    DO UPDATE SET label = COALESCE(EXCLUDED.label, stewards.nodes.label),
                  props = stewards.nodes.props || EXCLUDED.props,
                  updated_at = now()
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION stewards.graph_edge_upsert(
    p_src_kind text, p_src_ref text,
    p_dst_kind text, p_dst_ref text,
    p_edge_kind text,
    p_weight real DEFAULT 1.0,
    p_props jsonb DEFAULT '{}'::jsonb
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_src uuid;
    v_dst uuid;
    v_id  uuid;
BEGIN
    v_src := stewards.graph_node_upsert(p_src_kind, p_src_ref);
    v_dst := stewards.graph_node_upsert(p_dst_kind, p_dst_ref);
    INSERT INTO stewards.edges (src, dst, kind, weight, props)
    VALUES (v_src, v_dst, p_edge_kind, p_weight, COALESCE(p_props, '{}'::jsonb))
    ON CONFLICT (src, dst, kind)
    DO UPDATE SET weight = EXCLUDED.weight,
                  props  = stewards.edges.props || EXCLUDED.props
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Walks
--
-- graph_walk: the workhorse. N-depth (p_max_depth is a parameter, not a
-- ceiling), direction 'out' | 'in' | 'both', optional edge-kind filter
-- (NULL = all kinds). Cycle-safe via the visited-path array; returns
-- the path so callers can render lineage chains.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.graph_walk(
    p_start uuid,
    p_edge_kinds text[] DEFAULT NULL,
    p_max_depth int DEFAULT 10,
    p_direction text DEFAULT 'out'
) RETURNS TABLE (node_id uuid, depth int, path uuid[])
LANGUAGE sql STABLE AS $$
    WITH RECURSIVE walk(node_id, depth, path) AS (
        SELECT p_start, 0, ARRAY[p_start]
        UNION ALL
        SELECT CASE WHEN e.src = w.node_id THEN e.dst ELSE e.src END,
               w.depth + 1,
               w.path || CASE WHEN e.src = w.node_id THEN e.dst ELSE e.src END
          FROM walk w
          JOIN stewards.edges e
            ON (   (p_direction IN ('out','both') AND e.src = w.node_id)
                OR (p_direction IN ('in','both')  AND e.dst = w.node_id))
         WHERE w.depth < p_max_depth
           AND (p_edge_kinds IS NULL OR e.kind = ANY(p_edge_kinds))
           AND NOT (CASE WHEN e.src = w.node_id THEN e.dst ELSE e.src END) = ANY(w.path)
    )
    SELECT node_id, depth, path FROM walk;
$$;

-- Convenience over refs: walk from (kind, ref), join labels back on.
CREATE OR REPLACE FUNCTION stewards.graph_walk_ref(
    p_kind text, p_ref text,
    p_edge_kinds text[] DEFAULT NULL,
    p_max_depth int DEFAULT 10,
    p_direction text DEFAULT 'out'
) RETURNS TABLE (node_id uuid, node_kind text, node_ref text, label text, depth int)
LANGUAGE sql STABLE AS $$
    SELECT n.id, n.kind, n.ref, n.label, w.depth
      FROM stewards.graph_walk(
               (SELECT id FROM stewards.nodes WHERE kind = p_kind AND ref = p_ref),
               p_edge_kinds, p_max_depth, p_direction) w
      JOIN stewards.nodes n ON n.id = w.node_id;
$$;

-- Direct neighbors with edge metadata (1-hop, both directions labeled).
CREATE OR REPLACE FUNCTION stewards.graph_neighbors(
    p_node uuid, p_edge_kinds text[] DEFAULT NULL
) RETURNS TABLE (node_id uuid, edge_kind text, direction text, weight real, props jsonb)
LANGUAGE sql STABLE AS $$
    SELECT e.dst, e.kind, 'out', e.weight, e.props
      FROM stewards.edges e
     WHERE e.src = p_node AND (p_edge_kinds IS NULL OR e.kind = ANY(p_edge_kinds))
    UNION ALL
    SELECT e.src, e.kind, 'in', e.weight, e.props
      FROM stewards.edges e
     WHERE e.dst = p_node AND (p_edge_kinds IS NULL OR e.kind = ANY(p_edge_kinds));
$$;
