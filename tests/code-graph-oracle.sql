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

-- ===================================================================
-- ORACLE 3 — import_lodestar_graph (the whole-graph path, 83): a full
-- lodestar extraction {worlds,nodes,edges,cross_edges} lands per-world
-- structure under PROJECT-SCOPED slugs + lodestar's already-paired
-- cross_edges DIRECTLY into cross_world_edges. Exercises the build-once
-- lookup maps: v_node_world (edge-slicing) + v_idmap (cross-edge resolve).
-- ===================================================================
SELECT stewards.import_lodestar_graph('ltg-demo', '{
  "worlds": ["svc-a","svc-b"],
  "nodes": [
    {"id":"a-f",  "world":"svc-a","kind":"file",         "name":"svc.go"},
    {"id":"a-fn", "world":"svc-a","kind":"function",     "name":"svc.go:Handler"},
    {"id":"a-ep", "world":"svc-a","kind":"http_endpoint","name":"GET /users","metadata":{"method":"GET","path":"/users/{id}"}},
    {"id":"b-f",  "world":"svc-b","kind":"file",         "name":"cli.go"},
    {"id":"b-cl", "world":"svc-b","kind":"http_client",  "name":"call users","metadata":{"method":"GET","path":"/users/1"}}
  ],
  "edges": [
    {"src":"a-f","dst":"a-fn","rel":"contains"},
    {"src":"a-fn","dst":"a-ep","rel":"contains"},
    {"src":"b-f","dst":"b-cl","rel":"contains"}
  ],
  "cross_edges": [
    {"src":"a-ep","dst":"b-cl","rel":"serves","protocol":"http","contract_key":"GET /users/{}","confidence":0.9}
  ]
}'::jsonb);

DO $$
DECLARE v_a int; v_b int; v_src bigint; v_dst bigint; v_ok boolean;
BEGIN
    -- project-scoped worlds populated (two projects with a shared world name would NOT merge)
    SELECT count(*) INTO v_a FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id WHERE w.slug='ltg-demo/svc-a';
    SELECT count(*) INTO v_b FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id WHERE w.slug='ltg-demo/svc-b';
    ASSERT v_a = 3, format('ltg-demo/svc-a should have 3 entities, got %s', v_a);
    ASSERT v_b = 2, format('ltg-demo/svc-b should have 2 entities, got %s', v_b);
    -- v_node_world edge-slicing routed the intra-world contains edge to svc-a (not svc-b)
    ASSERT EXISTS (
      SELECT 1 FROM stewards.world_edges g JOIN stewards.worlds w ON g.world_id=w.world_id
        JOIN stewards.world_entities s ON g.src_entity=s.entity_id
       WHERE w.slug='ltg-demo/svc-a' AND s.name='svc.go:Handler' AND g.rel_type='contains'),
      'the a-fn -> a-ep contains edge should land in svc-a (edge-slicing via v_node_world)';
    -- v_idmap resolved both endpoints (node-id -> entity_id); the cross_edge landed verbatim
    SELECT e.entity_id INTO v_src FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id WHERE w.slug='ltg-demo/svc-a' AND e.kind='http_endpoint';
    SELECT e.entity_id INTO v_dst FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id WHERE w.slug='ltg-demo/svc-b' AND e.kind='http_client';
    SELECT EXISTS(
      SELECT 1 FROM stewards.cross_world_edges c
       WHERE c.src_entity=v_src AND c.dst_entity=v_dst AND c.protocol='http' AND c.evidence='lodestar') INTO v_ok;
    ASSERT v_ok, 'lodestar cross_edge (svc-a endpoint -> svc-b client) should land in cross_world_edges via v_idmap';
    RAISE NOTICE 'OK whole-graph — import_lodestar_graph: project-scoped worlds + edge-slicing + cross_edge via build-once maps';
END $$;

-- ===================================================================
-- ORACLE 4 — branch-aware capture (#298, legs 1): the two OPTIONAL params
-- stamp git provenance WITHOUT changing world identity. Asserts (a) world
-- metadata.{ref, repo_origin} lands (repo_origin only for worlds in the map),
-- (b) entity metadata.file_path is the repo-relative FILE path parsed from the
-- node id's 2nd ::-segment (uniform across file/decl/contract) + entity
-- repo_origin — ADDITIVE: metadata.path is LEFT as the HTTP route import_code_graph
-- stores for a contract node (a path template is not a full URI, so it belongs
-- under path; file_path is the pedantic, uniform key #301 reads).
-- ===================================================================
SELECT stewards.import_lodestar_graph('ref-demo', '{
  "worlds": ["svc-a","svc-b"],
  "nodes": [
    {"id":"svc-a::src/users.go","world":"svc-a","kind":"file","name":"users.go"},
    {"id":"svc-a::src/users.go::http_endpoint::GET /users/{}","world":"svc-a","kind":"http_endpoint","name":"GET /users/{}","metadata":{"method":"GET","path":"/users/{id}"}},
    {"id":"svc-b::src/client.ts","world":"svc-b","kind":"file","name":"client.ts"}
  ],
  "edges": [
    {"src":"svc-a::src/users.go","dst":"svc-a::src/users.go::http_endpoint::GET /users/{}","rel":"contains"}
  ],
  "cross_edges": []
}'::jsonb, 'v1.2', '{"svc-a":"https://github.com/x/svc-a"}'::jsonb);

DO $$
DECLARE
    v_wref_a text; v_worg_a text; v_wref_b text; v_worg_b text;
    v_fpath text; v_eorg text; v_ep_fpath text; v_ep_path text; v_ep_method text;
BEGIN
    -- (a) world A: ref + repo_origin both stamped from the params
    SELECT metadata->>'ref', metadata->>'repo_origin' INTO v_wref_a, v_worg_a
      FROM stewards.worlds WHERE slug='ref-demo/svc-a';
    ASSERT v_wref_a = 'v1.2', format('svc-a world ref should be v1.2, got %s', v_wref_a);
    ASSERT v_worg_a = 'https://github.com/x/svc-a', format('svc-a world repo_origin should be the URL, got %s', v_worg_a);
    -- world B: ref stamped, repo_origin UNSET (svc-b is not in p_repo_origins)
    SELECT metadata->>'ref', metadata->>'repo_origin' INTO v_wref_b, v_worg_b
      FROM stewards.worlds WHERE slug='ref-demo/svc-b';
    ASSERT v_wref_b = 'v1.2', format('svc-b world ref should be v1.2, got %s', v_wref_b);
    ASSERT v_worg_b IS NULL, format('svc-b world repo_origin should be unset (not in the map), got %s', v_worg_b);
    -- (b) file entity: file_path parsed from the node-id 2nd ::-segment + repo_origin
    SELECT e.metadata->>'file_path', e.metadata->>'repo_origin' INTO v_fpath, v_eorg
      FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id
     WHERE w.slug='ref-demo/svc-a' AND e.kind='file' AND e.name='users.go';
    ASSERT v_fpath = 'src/users.go', format('file entity file_path should be src/users.go, got %s', v_fpath);
    ASSERT v_eorg = 'https://github.com/x/svc-a', format('file entity repo_origin should be the URL, got %s', v_eorg);
    -- additive on a contract entity: file_path added, metadata.path (the route) LEFT ALONE, method untouched
    SELECT e.metadata->>'file_path', e.metadata->>'path', e.metadata->>'method'
      INTO v_ep_fpath, v_ep_path, v_ep_method
      FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id
     WHERE w.slug='ref-demo/svc-a' AND e.kind='http_endpoint' AND e.name='GET /users/{}';
    ASSERT v_ep_fpath = 'src/users.go', format('endpoint file_path should be the file src/users.go, got %s', v_ep_fpath);
    ASSERT v_ep_path = '/users/{id}', format('endpoint metadata.path (the route) should be LEFT untouched, got %s', v_ep_path);
    ASSERT v_ep_method = 'GET', format('endpoint method should be untouched, got %s', v_ep_method);
    RAISE NOTICE 'OK ref-capture — world.{ref,repo_origin} + entity.{file_path,repo_origin} stamped; metadata.path (route) untouched; repo_origin conditional on the map';
END $$;

SELECT 'CODE-GRAPH INGEST GREEN — extract → world-graph → cross-service traversal + whole-graph import + branch-aware capture' AS result;
ROLLBACK;
