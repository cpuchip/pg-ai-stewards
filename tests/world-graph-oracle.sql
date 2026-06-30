-- world-graph-oracle.sql — proves 82-world-graph.sql against Michael's exact
-- example: acme → {platform → {auth,user,account, eco → {devices,3rd-party}}, apps → {ios,android}}
-- and a cross-SIBLING-project edge: apps/ios calls platform/auth's /login.
-- Transactional: builds, asserts, ROLLS BACK (leaves no demo data).
BEGIN;

INSERT INTO stewards.projects(slug,name,parent_slug) VALUES
  ('wgd-acme','Acme',NULL),
  ('wgd-platform','Platform','wgd-acme'),
  ('wgd-eco','Eco','wgd-platform'),
  ('wgd-apps','Apps','wgd-acme');
INSERT INTO stewards.worlds(slug,name,project) VALUES
  ('wgd-auth','auth','wgd-platform'), ('wgd-user','user','wgd-platform'),
  ('wgd-account','account','wgd-platform'), ('wgd-devices','devices','wgd-eco'),
  ('wgd-thirdparty','3rd-party','wgd-eco'), ('wgd-ios','ios','wgd-apps'),
  ('wgd-android','android','wgd-apps');

-- auth (platform) exposes POST /login ; ios (apps) calls POST /api/login
INSERT INTO stewards.world_entities(world_id,kind,name,metadata)
  SELECT world_id,'http_endpoint','route POST /login',jsonb_build_object('method','POST','path','/login')
    FROM stewards.worlds WHERE slug='wgd-auth';
INSERT INTO stewards.world_entities(world_id,kind,name,metadata)
  SELECT world_id,'http_client','call POST /api/login',jsonb_build_object('method','POST','path','/api/login')
    FROM stewards.worlds WHERE slug='wgd-ios';

SELECT stewards.resolve_cross_service_http('wgd-acme') AS sides_linked;

-- ORACLE 1 — the hierarchy (n-level): acme depth1, platform/apps depth2, eco depth3
DO $$
DECLARE v_n int; v_maxd int;
BEGIN
  SELECT count(*), max(depth) INTO v_n, v_maxd FROM stewards.project_tree('wgd-acme');
  ASSERT v_n = 4, format('acme subtree should have 4 projects, got %s', v_n);
  ASSERT v_maxd = 3, format('eco should be at depth 3 (n-level), got max depth %s', v_maxd);
  ASSERT (SELECT depth FROM stewards.project_tree('wgd-acme') WHERE slug='wgd-eco') = 3, 'eco depth';
  ASSERT (SELECT depth FROM stewards.project_tree('wgd-acme') WHERE slug='wgd-apps') = 2, 'apps depth (sibling of platform)';
  RAISE NOTICE 'ORACLE 1 PASS — n-level project hierarchy (acme>platform>eco, apps sibling)';
END $$;

-- ORACLE 2 — the cross-SIBLING edge: /api/login (apps/ios) paired with /login (platform/auth)
DO $$
DECLARE v_contract bigint; v_prod int; v_cons int;
BEGIN
  SELECT entity_id INTO v_contract FROM stewards.world_entities e JOIN stewards.worlds w ON e.world_id=w.world_id
   WHERE w.slug='wgd-acme-contracts' AND e.kind='http_endpoint' AND e.name='POST /login';
  ASSERT v_contract IS NOT NULL, 'a single deduped POST /login contract should exist (/api stripped, matched across sibling projects)';
  SELECT count(*) INTO v_prod FROM stewards.cross_world_edges WHERE dst_entity=v_contract AND rel_type='produces';
  SELECT count(*) INTO v_cons FROM stewards.cross_world_edges WHERE dst_entity=v_contract AND rel_type='consumes';
  ASSERT v_prod=1 AND v_cons=1, format('1 produces + 1 consumes, got %s/%s', v_prod, v_cons);
  RAISE NOTICE 'ORACLE 2 PASS — apps/ios and platform/auth paired on POST /login across the sibling boundary';
END $$;

-- ORACLE 3 — traversal: from platform/auth's route, reach apps/ios's client (crosses 2 projects)
DO $$
DECLARE v_start bigint; v_target bigint; v_reached boolean;
BEGIN
  SELECT entity_id INTO v_start  FROM stewards.world_entities WHERE name='route POST /login';
  SELECT entity_id INTO v_target FROM stewards.world_entities WHERE name='call POST /api/login';
  WITH RECURSIVE reach(entity_id,depth) AS (
    SELECT v_start,0
    UNION
    SELECT CASE WHEN c.src_entity=r.entity_id THEN c.dst_entity ELSE c.src_entity END, r.depth+1
      FROM reach r JOIN stewards.cross_world_edges c ON (c.src_entity=r.entity_id OR c.dst_entity=r.entity_id)
     WHERE r.depth < 4
  )
  SELECT EXISTS(SELECT 1 FROM reach WHERE entity_id=v_target) INTO v_reached;
  ASSERT v_reached, 'platform/auth route must reach apps/ios client across the project boundary';
  RAISE NOTICE 'ORACLE 3 PASS — cross-project traversal auth(platform) -> contract -> ios(apps)';
END $$;

SELECT 'WORLD-GRAPH ORACLE GREEN — n-level hierarchy + cross-sibling-project service link' AS result;
ROLLBACK;
