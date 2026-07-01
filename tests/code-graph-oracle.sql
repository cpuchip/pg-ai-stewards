-- code-graph-oracle.sql — proves the D5 ingest (83) end-to-end:
-- import two code repos (a service with an HTTP route + a client repo calling it)
-- → the deterministic cross-service resolver (82) pairs the extracted endpoint and
-- client across the two worlds → traversable in one query. Transactional (ROLLBACK).
BEGIN;

-- service A (a repo): a file with a function that calls another, exposing a route
SELECT stewards.import_code_graph('cg-svc-a','cg-demo',
  '[{"id":"f1","kind":"file","name":"users.go"},
    {"id":"fn1","kind":"function","name":"users.go:GetUser"},
    {"id":"fn2","kind":"function","name":"users.go:loadUser"},
    {"id":"ep1","kind":"http_endpoint","name":"route GetUser","metadata":{"method":"GET","path":"/users/{id}"}}]'::jsonb,
  '[{"src":"f1","dst":"fn1","rel":"contains"},
    {"src":"fn1","dst":"fn2","rel":"calls"},
    {"src":"fn1","dst":"ep1","rel":"contains"}]'::jsonb);

-- service B (another repo): a client calling /api/users/123
SELECT stewards.import_code_graph('cg-svc-b','cg-demo',
  '[{"id":"f2","kind":"file","name":"client.ts"},
    {"id":"cl1","kind":"http_client","name":"client getUser","metadata":{"method":"GET","path":"/api/users/123"}}]'::jsonb,
  '[{"src":"f2","dst":"cl1","rel":"contains"}]'::jsonb);

-- ORACLE 1 — the ingest landed entities + the intra-repo call edge
DO $$
DECLARE v_e int;
BEGIN
    SELECT count(*) INTO v_e FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id WHERE w.slug='cg-svc-a';
    ASSERT v_e = 4, format('svc-a should have 4 entities, got %s', v_e);
    ASSERT EXISTS (
      SELECT 1 FROM stewards.world_edges g
        JOIN stewards.worlds w ON g.world_id=w.world_id
        JOIN stewards.world_entities s ON g.src_entity=s.entity_id
        JOIN stewards.world_entities d ON g.dst_entity=d.entity_id
       WHERE w.slug='cg-svc-a' AND s.name='users.go:GetUser' AND d.name='users.go:loadUser' AND g.rel_type='calls'),
      'the GetUser -> loadUser calls edge should land';
    RAISE NOTICE 'OK ingest — svc-a: 4 entities + the intra-repo calls edge';
END $$;

SELECT stewards.resolve_cross_service_http('cg-demo') AS sides_linked;

-- ORACLE 2 — the EXTRACTED endpoint + client paired across the two repos, traversable
DO $$
DECLARE v_contract bigint; v_start bigint; v_target bigint; v_reached boolean;
BEGIN
    SELECT entity_id INTO v_contract FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id
      WHERE w.slug='cg-demo-contracts' AND e.kind='http_endpoint' AND e.name='GET /users/{}';
    ASSERT v_contract IS NOT NULL, 'a deduped GET /users/{} contract (api-stripped) should pair the two repos';
    SELECT entity_id INTO v_start  FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id WHERE w.slug='cg-svc-a' AND e.kind='http_endpoint';
    SELECT entity_id INTO v_target FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id WHERE w.slug='cg-svc-b' AND e.kind='http_client';
    WITH RECURSIVE reach(entity_id, depth) AS (
        SELECT v_start, 0
        UNION
        SELECT CASE WHEN c.src_entity=r.entity_id THEN c.dst_entity ELSE c.src_entity END, r.depth+1
          FROM reach r JOIN stewards.cross_world_edges c ON (c.src_entity=r.entity_id OR c.dst_entity=r.entity_id)
         WHERE r.depth < 4
    )
    SELECT EXISTS(SELECT 1 FROM reach WHERE entity_id = v_target) INTO v_reached;
    ASSERT v_reached, 'extracted route (svc-a) must reach extracted client (svc-b) across the cross-world edge';
    RAISE NOTICE 'OK e2e — extract 2 repos -> resolve -> svc-a route reaches svc-b client across worlds';
END $$;

SELECT 'CODE-GRAPH INGEST GREEN — extract → world-graph → cross-service traversal' AS result;
ROLLBACK;
