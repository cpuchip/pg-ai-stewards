-- =====================================================================
-- 83-code-graph.sql — the INGEST half of the code extractor (D5).
-- =====================================================================
-- Lands a normalized {nodes, edges} code graph (produced by the deterministic
-- tree-sitter PARSE — graphify, MIT, run in the research_codebase sandbox) into
-- a code World via world_entity_upsert / world_edge_upsert. The PARSE half
-- (clone → graphify → this JSON) is sandbox orchestration; THIS is the substrate
-- ingest, oracle-gated independently. Deterministic — no LLM, so it can neither
-- fabricate (gemma's flaw) nor spiral (qwen's) on code.
--
-- Node: {id, kind, name (qualified, unique within world+kind), summary?,
--        source_refs?, metadata?}  — metadata carries method/path for
--        http_endpoint/http_client so the cross-service resolvers (82) can pair them.
-- Edge: {src (id), dst (id), rel}  — ids resolved to names via the node map.
-- Code entity kinds: file|module|class|function|method|interface|endpoint|
--   http_endpoint|http_client|rpc_service|topic|schema|config_key|data_entity|package
-- Code edge rels: contains|calls|imports|inherits|implements
--
-- requires create_world_graph (82) — reuses world_*_upsert + feeds the resolver.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.import_code_graph(
    p_world_slug text,
    p_project    text,
    p_nodes      jsonb,
    p_edges      jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_idmap   jsonb := '{}'::jsonb;   -- graphify node id -> entity name
    v_eid     bigint;
    v_n_ent   int := 0;
    v_n_edge  int := 0;
    r         jsonb;
    v_src     text;
    v_dst     text;
BEGIN
    -- ensure the project row (so project_tree/the picker see this world) + the world.
    INSERT INTO stewards.projects(slug, name) VALUES (p_project, p_project)
      ON CONFLICT (slug) DO NOTHING;
    PERFORM stewards.world_upsert(p_world_slug, p_world_slug, 'code world (extracted)', p_project, false);

    -- entities: upsert each node (dedup on world+kind+name); record id -> name;
    -- carry metadata (method/path/...) which world_entity_upsert does not take.
    FOR r IN SELECT value FROM jsonb_array_elements(coalesce(p_nodes,'[]'::jsonb)) AS t(value) LOOP
        SELECT stewards.world_entity_upsert(
            p_world_slug,
            coalesce(r->>'kind','concept'),
            r->>'name',
            r->>'summary',
            '{}'::text[],
            coalesce(r->'source_refs','[]'::jsonb)
        ) INTO v_eid;
        IF r ? 'metadata' THEN
            UPDATE stewards.world_entities SET metadata = (r->'metadata') WHERE entity_id = v_eid;
        END IF;
        v_idmap := v_idmap || jsonb_build_object(r->>'id', r->>'name');
        v_n_ent := v_n_ent + 1;
    END LOOP;

    -- edges: resolve src/dst ids -> names via the map, then upsert (by name).
    FOR r IN SELECT value FROM jsonb_array_elements(coalesce(p_edges,'[]'::jsonb)) AS t(value) LOOP
        v_src := v_idmap ->> (r->>'src');
        v_dst := v_idmap ->> (r->>'dst');
        IF v_src IS NOT NULL AND v_dst IS NOT NULL THEN
            PERFORM stewards.world_edge_upsert(p_world_slug, v_src, v_dst,
                                               coalesce(r->>'rel','references'), 'code-extract');
            v_n_edge := v_n_edge + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('world', p_world_slug, 'entities', v_n_ent, 'edges', v_n_edge);
END $fn$;

COMMENT ON FUNCTION stewards.import_code_graph(text,text,jsonb,jsonb) IS
'83 (D5 ingest): land a normalized {nodes,edges} code graph (from the deterministic tree-sitter parse) into a code World via world_*_upsert; carries http metadata so the 82 cross-service resolvers can pair endpoints/clients. The parse half (clone→graphify→JSON) is sandbox orchestration. No LLM — cannot fabricate or spiral.';

-- =====================================================================
-- import_lodestar_graph — the whole-graph front door for the lodestar extractor.
-- =====================================================================
-- lodestar (github.com/cpuchip/lodestar) is the native tree-sitter extractor: it
-- parses many repos and emits ONE graph {worlds, nodes, edges, cross_edges} where
-- it has ALREADY computed the cross-service edges deterministically (HTTP/gRPC/
-- pub-sub key-joins). So the substrate is the STORE, not the re-resolver: this
-- function lands each world's structure via import_code_graph, then lands
-- lodestar's cross_edges DIRECTLY into cross_world_edges (mapping the extractor's
-- node ids → entity ids). One source of truth for extraction; no duplicate resolver
-- logic in SQL. Deterministic in, deterministic stored — cannot fabricate or spiral.
--
-- p_graph shape (lodestar internal/graph.Graph, JSON):
--   { "worlds":[slug,...],
--     "nodes":[{id,world,kind,name,summary?,metadata?}...],
--     "edges":[{src,dst,rel}...],                     -- intra-world
--     "cross_edges":[{src,dst,rel,protocol,contract_key,confidence}...] }
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.import_lodestar_graph(
    p_project text,
    p_graph   jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    w            text;
    v_worlds     int := 0;
    v_ce         int := 0;
    ce           jsonb;
    v_src_eid    bigint;
    v_dst_eid    bigint;
    v_node_world jsonb;  -- node id -> its world (built once; O(1) edge-slicing)
    v_idmap      jsonb;  -- node id -> entity_id (built once; O(1) cross-edge resolve)
BEGIN
    -- ★ Perf (2026-07-01): build two lookup maps ONCE instead of scanning the nodes
    -- array per edge. The old nested scans were O(worlds×edges×nodes) + O(edges×nodes)
    -- — fine for a demo, but they timed out importing a 45-service/3200-node monolith.

    -- node id -> world (bare), so edges slice by world with a map lookup, no nested scan.
    SELECT coalesce(jsonb_object_agg(n->>'id', n->>'world'), '{}'::jsonb) INTO v_node_world
      FROM jsonb_array_elements(coalesce(p_graph->'nodes','[]'::jsonb)) n;

    -- Per-world structural import: reuse import_code_graph for nodes + intra-world
    -- edges + metadata (dedup on world+kind+name). Slice the combined graph by world.
    -- ★ World slugs are PROJECT-SCOPED (project/world): world_upsert dedups on slug
    -- globally, so two projects that each have a "frontend" would otherwise merge.
    FOR w IN SELECT jsonb_array_elements_text(coalesce(p_graph->'worlds','[]'::jsonb)) LOOP
        PERFORM stewards.import_code_graph(
            p_project || '/' || w, p_project,
            (SELECT coalesce(jsonb_agg(n),'[]'::jsonb)
               FROM jsonb_array_elements(coalesce(p_graph->'nodes','[]'::jsonb)) n
              WHERE n->>'world' = w),
            (SELECT coalesce(jsonb_agg(e),'[]'::jsonb)
               FROM jsonb_array_elements(coalesce(p_graph->'edges','[]'::jsonb)) e
              WHERE v_node_world ->> (e->>'src') = w)   -- O(1) map lookup, not a nested scan
        );
        v_worlds := v_worlds + 1;
    END LOOP;

    -- node id -> entity_id, built ONCE via an indexed join (worlds.slug +
    -- world_entities(world_id,kind,name)); cross-edge resolution is then O(1) per edge.
    SELECT coalesce(jsonb_object_agg(n->>'id', to_jsonb(e.entity_id)), '{}'::jsonb) INTO v_idmap
      FROM jsonb_array_elements(coalesce(p_graph->'nodes','[]'::jsonb)) n
      JOIN stewards.worlds wo ON wo.slug = p_project || '/' || (n->>'world')
      JOIN stewards.world_entities e ON e.world_id = wo.world_id
                                    AND e.kind = n->>'kind' AND e.name = n->>'name';

    -- Cross-world edges: lodestar already paired producer↔consumer. Resolve each
    -- endpoint's extractor node-id → entity_id via the map, and store the edge verbatim.
    FOR ce IN SELECT value FROM jsonb_array_elements(coalesce(p_graph->'cross_edges','[]'::jsonb)) AS t(value) LOOP
        v_src_eid := (v_idmap ->> (ce->>'src'))::bigint;
        v_dst_eid := (v_idmap ->> (ce->>'dst'))::bigint;
        IF v_src_eid IS NULL OR v_dst_eid IS NULL THEN CONTINUE; END IF;

        INSERT INTO stewards.cross_world_edges(src_entity, dst_entity, rel_type, contract_key, protocol, confidence, evidence)
        VALUES (v_src_eid, v_dst_eid, coalesce(ce->>'rel','references'),
                ce->>'contract_key', ce->>'protocol',
                coalesce((ce->>'confidence')::real, 0.8), 'lodestar')
        ON CONFLICT (src_entity, dst_entity, rel_type) DO NOTHING;
        v_ce := v_ce + 1;
    END LOOP;

    RETURN jsonb_build_object('project', p_project, 'worlds', v_worlds, 'cross_edges', v_ce);
END $fn$;

COMMENT ON FUNCTION stewards.import_lodestar_graph(text,jsonb) IS
'83 (D5 ingest, whole-graph): land a full lodestar extraction {worlds,nodes,edges,cross_edges} — per-world structure via import_code_graph, then lodestar''s already-computed cross-service edges DIRECTLY into cross_world_edges (node-id→entity-id). lodestar is the single deterministic extraction authority; the substrate stores. Feed via: SELECT stewards.import_lodestar_graph(''project'', ''<lodestar JSON>''::jsonb).';
