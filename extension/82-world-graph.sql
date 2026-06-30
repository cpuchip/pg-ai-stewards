-- =====================================================================
-- 82-world-graph.sql — Projects-as-hierarchy + cross-service edges.
-- Ratified 2026-06-30 (world-graph-spec.md, D1-D5). The §10 HTTP spike
-- (spike-cross-service-http.sql) proved the thesis; this is the permanent,
-- idempotent chain file.
--
--   D1  projects gain a parent_slug → an n-level tree; worlds belong to a
--       project (FK). A project = a hierarchical container (folder/namespace/
--       access unit); a world = the leaf entity-graph.
--   D2  cross_world_edges — an edge between two entities that may live in
--       different worlds (and thus different projects). One mechanism carries
--       every cross-boundary link.
--   D3  contracts-as-nodes + the deterministic HTTP resolver (key-normalize
--       then GROUP BY — the normalizer is an oracle). Generalized to resolve
--       across a project SUBTREE so sibling services (apps↔platform) link.
--   picker  project_tree() — the recursive-CTE hierarchy for the UI.
--
-- Idempotent: safe on a virgin CREATE EXTENSION and on dev (where the spike
-- already created some of these). Generic core; no scripture, no overlay.
-- =====================================================================

-- ===== D1 — projects become an n-level tree =====
ALTER TABLE stewards.projects
  ADD COLUMN IF NOT EXISTS parent_slug text REFERENCES stewards.projects(slug) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS projects_parent_idx ON stewards.projects(parent_slug);

-- worlds belong to a project: backfill any flat world labels into real project
-- rows so the picker shows them under their project. worlds.project stays a SOFT
-- reference — we deliberately do NOT add a hard FK (worlds.project → projects.slug):
-- existing world-creation paths (world_upsert, the world-build pipeline) insert a
-- world with a project label without pre-creating the project row, and a hard FK
-- would break them. The hierarchy + picker work via project_tree's join regardless.
-- (FK hardening deferred until every world-insert path pre-creates its project.)
INSERT INTO stewards.projects(slug, name)
  SELECT DISTINCT project, project FROM stewards.worlds WHERE project IS NOT NULL
  ON CONFLICT (slug) DO NOTHING;

-- ===== the picker — the project hierarchy as a recursive CTE =====
-- project_tree(NULL) = the whole forest (all roots + descendants).
-- project_tree('platform') = 'platform' + its subtree.
CREATE OR REPLACE FUNCTION stewards.project_tree(p_root text DEFAULT NULL)
RETURNS TABLE(slug text, name text, parent_slug text, depth int, path text)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE t AS (
    SELECT p.slug, p.name, p.parent_slug, 1 AS depth, p.slug::text AS path
      FROM stewards.projects p
     WHERE (p_root IS NULL AND p.parent_slug IS NULL) OR (p.slug = p_root)
    UNION ALL
    SELECT c.slug, c.name, c.parent_slug, t.depth + 1, t.path || ' / ' || c.slug
      FROM stewards.projects c JOIN t ON c.parent_slug = t.slug
  )
  SELECT slug, name, parent_slug, depth, path FROM t;
$$;

-- ===== D2 — the cross-world edge store =====
CREATE TABLE IF NOT EXISTS stewards.cross_world_edges (
    edge_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    src_entity   bigint NOT NULL REFERENCES stewards.world_entities(entity_id) ON DELETE CASCADE,
    dst_entity   bigint NOT NULL REFERENCES stewards.world_entities(entity_id) ON DELETE CASCADE,
    rel_type     text   NOT NULL,   -- produces | consumes | http_calls | grpc_calls | publishes_to | shares_schema | ...
    contract_key text,              -- the normalized key that paired producer↔consumer
    protocol     text,              -- http | grpc | pubsub | graphql | schema | db | config | package
    confidence   real,              -- 1.0 extracted / 0.55–0.95 inferred / flagged ambiguous
    evidence     text,
    metadata     jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (src_entity, dst_entity, rel_type)
);
CREATE INDEX IF NOT EXISTS cross_world_edges_src_idx ON stewards.cross_world_edges(src_entity);
CREATE INDEX IF NOT EXISTS cross_world_edges_dst_idx ON stewards.cross_world_edges(dst_entity);
CREATE INDEX IF NOT EXISTS cross_world_edges_key_idx ON stewards.cross_world_edges(contract_key);

-- ===== D3 — the deterministic HTTP key normalizer (the oracle) =====
-- METHOD upper-cased; query string dropped; {id}/:id/${id} and numeric path
-- segments collapsed to {}; one leading /api or /vN stripped; // collapsed.
CREATE OR REPLACE FUNCTION stewards.normalize_http_key(p_method text, p_path text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT upper(coalesce(nullif(p_method,''),'GET')) || ' ' ||
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            split_part(coalesce(nullif(p_path,''),'/'), '?', 1),
            '(\{[^/}]+\}|\$\{[^/}]+\}|:[A-Za-z_][A-Za-z0-9_]*)', '{}', 'g'),
          '/[0-9]+', '/{}', 'g'),
        '^/(api|v[0-9]+)(/|$)', '/', ''),
      '//+', '/', 'g');
$$;

-- ===== D3 — the HTTP contract resolver (contract-as-node), subtree-scoped =====
-- Resolve every producer (http_endpoint) and consumer (http_client) across the
-- WHOLE subtree under p_root (so sibling services link), pairing them on the
-- normalized key via a deduped contract entity in p_root's `<root>-contracts`
-- world. The existing (world,kind,name) dedup IS the matcher.
-- DROP first: the §10 spike created this with param name p_project; CREATE OR
-- REPLACE cannot rename an input parameter, so drop the spike version.
DROP FUNCTION IF EXISTS stewards.resolve_cross_service_http(text);
CREATE OR REPLACE FUNCTION stewards.resolve_cross_service_http(p_root text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_contracts_world bigint;
    v_contract        bigint;
    v_n               int := 0;
    r                 record;
BEGIN
    SELECT world_id INTO v_contracts_world FROM stewards.worlds
      WHERE project = p_root AND slug = p_root || '-contracts';
    IF v_contracts_world IS NULL THEN
        INSERT INTO stewards.worlds(slug, name, project)
        VALUES (p_root || '-contracts', p_root || ' contracts', p_root)
        RETURNING world_id INTO v_contracts_world;
    END IF;

    FOR r IN
        SELECT e.entity_id, e.kind,
               stewards.normalize_http_key(e.metadata->>'method', e.metadata->>'path') AS ckey
        FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id = w.world_id
        WHERE w.project IN (SELECT slug FROM stewards.project_tree(p_root))
          AND e.kind IN ('http_endpoint','http_client')
          AND e.metadata ? 'path'
    LOOP
        SELECT entity_id INTO v_contract FROM stewards.world_entities
          WHERE world_id = v_contracts_world AND kind = 'http_endpoint' AND name = r.ckey;
        IF v_contract IS NULL THEN
            INSERT INTO stewards.world_entities(world_id, kind, name)
            VALUES (v_contracts_world, 'http_endpoint', r.ckey) RETURNING entity_id INTO v_contract;
        END IF;
        INSERT INTO stewards.cross_world_edges(src_entity, dst_entity, rel_type, contract_key, protocol, confidence)
        VALUES (r.entity_id, v_contract,
                CASE WHEN r.kind = 'http_endpoint' THEN 'produces' ELSE 'consumes' END,
                r.ckey, 'http', 1.0)
        ON CONFLICT (src_entity, dst_entity, rel_type) DO NOTHING;
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END $$;

COMMENT ON FUNCTION stewards.project_tree(text) IS
'82: the project hierarchy (n-level) as a recursive CTE. NULL root = the whole forest; a slug = that project + its subtree. The picker + the subtree scope for cross-service resolution.';
COMMENT ON FUNCTION stewards.resolve_cross_service_http(text) IS
'82: HTTP cross-service resolver (contract-as-node). Pairs producers (routes) and consumers (clients) across the whole subtree under p_root on the normalized contract key, via cross_world_edges. The first of 8 protocol resolvers (gRPC/pub-sub/GraphQL/shared-schema/DB/config/package to follow).';
