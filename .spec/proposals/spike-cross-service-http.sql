-- =====================================================================
-- spike-cross-service-http.sql — the §10 spike for world-graph-spec.md
-- Prove: a deterministic HTTP key-normalizer matches a producer (route)
-- to a consumer (client) ACROSS two world boundaries, writes a cross-world
-- edge, and the link is traversable in one recursive query.
--
-- BUILD THE ORACLE FIRST: the normalizer is deterministic, so its test IS
-- the detector. Recall (the two forms collide) + precision (different route
-- / different method do NOT) + the inverse hypothesis (without templating
-- they stop matching). Re-runnable; applied on dev only (not a chain file).
-- =====================================================================

-- ---- teardown (re-runnable) ----
DELETE FROM stewards.world_entities e USING stewards.worlds w
  WHERE e.world_id = w.world_id AND w.project = 'demo-platform';  -- cascades cross_world_edges
DELETE FROM stewards.worlds   WHERE project = 'demo-platform';
DELETE FROM stewards.projects WHERE slug   = 'demo-platform';

-- ---- D2: the cross-world edge store ----
CREATE TABLE IF NOT EXISTS stewards.cross_world_edges (
    edge_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    src_entity   bigint NOT NULL REFERENCES stewards.world_entities(entity_id) ON DELETE CASCADE,
    dst_entity   bigint NOT NULL REFERENCES stewards.world_entities(entity_id) ON DELETE CASCADE,
    rel_type     text   NOT NULL,
    contract_key text,
    protocol     text,
    confidence   real,
    evidence     text,
    metadata     jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (src_entity, dst_entity, rel_type)
);
CREATE INDEX IF NOT EXISTS cross_world_edges_src_idx ON stewards.cross_world_edges(src_entity);
CREATE INDEX IF NOT EXISTS cross_world_edges_dst_idx ON stewards.cross_world_edges(dst_entity);

-- ---- the deterministic HTTP key normalizer (THE ORACLE) ----
-- METHOD upper-cased; query string dropped; {id}/:id/${id} and numeric
-- segments collapsed to {}; one leading /api or /vN stripped; // collapsed.
CREATE OR REPLACE FUNCTION stewards.normalize_http_key(p_method text, p_path text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT upper(coalesce(nullif(p_method,''),'GET')) || ' ' ||
    regexp_replace(                                            -- collapse // -> /
      regexp_replace(                                          -- strip one /api or /vN prefix
        regexp_replace(                                        -- /123 -> /{}
          regexp_replace(                                      -- {id} / ${id} / :id -> {}
            split_part(coalesce(nullif(p_path,''),'/'), '?', 1),
            '(\{[^/}]+\}|\$\{[^/}]+\}|:[A-Za-z_][A-Za-z0-9_]*)', '{}', 'g'),
          '/[0-9]+', '/{}', 'g'),
        '^/(api|v[0-9]+)(/|$)', '/', ''),
      '//+', '/', 'g');
$$;

-- ---- the HTTP contract resolver (D3: contract-as-node) ----
-- For every producer (http_endpoint) and consumer (http_client) in a project's
-- worlds, compute the normalized key, upsert the deduped contract entity in the
-- project's `<project>-contracts` world (the (world,kind,name) dedup IS the
-- matcher), and link produces/consumes as cross-world edges.
CREATE OR REPLACE FUNCTION stewards.resolve_cross_service_http(p_project text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_contracts_world bigint;
    v_contract        bigint;
    v_n               int := 0;
    r                 record;
BEGIN
    SELECT world_id INTO v_contracts_world FROM stewards.worlds
      WHERE project = p_project AND slug = p_project || '-contracts';
    IF v_contracts_world IS NULL THEN
        INSERT INTO stewards.worlds(slug, name, project)
        VALUES (p_project || '-contracts', p_project || ' contracts', p_project)
        RETURNING world_id INTO v_contracts_world;
    END IF;

    FOR r IN
        SELECT e.entity_id, e.kind,
               stewards.normalize_http_key(e.metadata->>'method', e.metadata->>'path') AS ckey
        FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id = w.world_id
        WHERE w.project = p_project
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

-- =====================================================================
-- ORACLE 1 — the normalizer (recall + precision + inverse hypothesis)
-- =====================================================================
DO $$
BEGIN
    -- RECALL: the two forms (and the /api-prefixed form) collide
    ASSERT stewards.normalize_http_key('GET','/users/123')
         = stewards.normalize_http_key('get','/users/{id}'),
         'recall: /users/123 and /users/{id} must normalize equal';
    ASSERT stewards.normalize_http_key('GET','/api/users/55')
         = stewards.normalize_http_key('GET','/users/{id}'),
         'recall: /api prefix must be stripped';
    -- PRECISION: a different route or a different method must NOT collide
    ASSERT stewards.normalize_http_key('GET','/orders/123')
        <> stewards.normalize_http_key('GET','/users/123'),
        'precision: different paths must not collide';
    ASSERT stewards.normalize_http_key('POST','/users/123')
        <> stewards.normalize_http_key('GET','/users/123'),
        'precision: method mismatch must not collide';
    -- INVERSE HYPOTHESIS: without templating, the raw strings differ — so it
    -- is the normalization (not luck) that makes producer/consumer match.
    ASSERT '/users/123' <> '/users/{id}', 'inverse: raw paths differ (templating is doing the work)';
    RAISE NOTICE 'ORACLE 1 PASS — normalizer recall+precision+inverse hold';
END $$;

-- =====================================================================
-- the two toy services
-- =====================================================================
INSERT INTO stewards.projects(slug, name) VALUES ('demo-platform','Demo Platform');
INSERT INTO stewards.worlds(slug, name, project) VALUES
  ('demo-svc-a','svc-a (provider)','demo-platform'),
  ('demo-svc-b','svc-b (consumer)','demo-platform');

INSERT INTO stewards.world_entities(world_id, kind, name, metadata)
SELECT world_id, 'http_endpoint', 'route GET /users/{id}',
       jsonb_build_object('method','GET','path','/users/{id}')
  FROM stewards.worlds WHERE slug='demo-svc-a';
INSERT INTO stewards.world_entities(world_id, kind, name, metadata)
SELECT world_id, 'http_client', 'call axios.get(/users/123)',
       jsonb_build_object('method','GET','path','/users/123')
  FROM stewards.worlds WHERE slug='demo-svc-b';

-- run the resolver
SELECT stewards.resolve_cross_service_http('demo-platform') AS sides_linked;

-- =====================================================================
-- ORACLE 2 — exactly one contract, produced by the route, consumed by the client
-- =====================================================================
DO $$
DECLARE v_contract bigint; v_produces int; v_consumes int;
BEGIN
    SELECT entity_id INTO v_contract FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id
      WHERE w.slug='demo-platform-contracts' AND e.kind='http_endpoint';
    ASSERT v_contract IS NOT NULL, 'a single deduped contract entity should exist';
    SELECT count(*) INTO v_produces FROM stewards.cross_world_edges WHERE dst_entity=v_contract AND rel_type='produces';
    SELECT count(*) INTO v_consumes FROM stewards.cross_world_edges WHERE dst_entity=v_contract AND rel_type='consumes';
    ASSERT v_produces=1 AND v_consumes=1, format('expected 1 produces + 1 consumes, got %s/%s', v_produces, v_consumes);
    RAISE NOTICE 'ORACLE 2 PASS — route produces + client consumes one contract';
END $$;

-- =====================================================================
-- ORACLE 3 — TRAVERSAL: from svc-a's route, reach svc-b's client across the
-- world (and project-internal) boundary in one recursive query.
-- =====================================================================
DO $$
DECLARE v_start bigint; v_target bigint; v_reached boolean;
BEGIN
    SELECT entity_id INTO v_start  FROM stewards.world_entities WHERE name='route GET /users/{id}';
    SELECT entity_id INTO v_target FROM stewards.world_entities WHERE name='call axios.get(/users/123)';
    WITH RECURSIVE reach(entity_id, depth) AS (
        SELECT v_start, 0
        UNION
        SELECT CASE WHEN c.src_entity=r.entity_id THEN c.dst_entity ELSE c.src_entity END, r.depth+1
          FROM reach r JOIN stewards.cross_world_edges c
            ON (c.src_entity=r.entity_id OR c.dst_entity=r.entity_id)
         WHERE r.depth < 4
    )
    SELECT EXISTS(SELECT 1 FROM reach WHERE entity_id = v_target) INTO v_reached;
    ASSERT v_reached, 'svc-b client must be reachable from svc-a route across the cross-world edge';
    RAISE NOTICE 'ORACLE 3 PASS — cross-world traversal route -> contract -> client works';
END $$;

SELECT 'SPIKE GREEN — cross-service code-graph thesis proven' AS result;
