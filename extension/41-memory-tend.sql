-- =====================================================================
-- 41-memory-tend.sql — the self-tending loops: WALK + LINK (Phase M2/M3).
-- =====================================================================
-- A memory that tends itself recalls by CONNECTEDNESS (not just cosine) and grows its
-- own typed links. This is the WALK (graph_recall — a HippoRAG-style weighted multi-hop
-- spread over the typed graph) and the LINK loop (find related-but-unlinked nodes →
-- propose a typed edge → the Hinge gates it → on approval the edge is created). The
-- gentle scheduled tending (REVIEW/NOTE/UPDATE/CONNECT/NUDGE) runs the memory-tend
-- pipeline; PRUNE (contrastive edge reweighting) is the next layer. requires create_rte (40).
-- =====================================================================

-- ── graph_recall (the WALK) — associative recall by connectedness. Spreads weight from
--    seed nodes along edges (both directions), decaying per hop, and ranks reached nodes
--    by accumulated weight. A node reached by many short paths scores high — the
--    hippocampal-index intuition (PPR), bounded + SQL-native.
CREATE OR REPLACE FUNCTION stewards.graph_recall(
    p_seeds jsonb, p_max_hops int DEFAULT 3, p_limit int DEFAULT 15, p_decay real DEFAULT 0.5
) RETURNS TABLE (kind text, ref text, label text, score real, hops int)
LANGUAGE sql STABLE AS $fn$
    WITH RECURSIVE seed AS (
        SELECT n.id, 1.0::real AS w, 0 AS hop
          FROM stewards.nodes n
          JOIN jsonb_array_elements(p_seeds) s
            ON n.kind = s->>'kind' AND n.ref = s->>'ref'
    ),
    walk AS (
        SELECT id, w, hop FROM seed
        UNION ALL
        SELECT CASE WHEN e.src = walk.id THEN e.dst ELSE e.src END,
               (walk.w * p_decay * e.weight)::real,
               walk.hop + 1
          FROM walk
          JOIN stewards.edges e ON (e.src = walk.id OR e.dst = walk.id)
         WHERE walk.hop < p_max_hops AND walk.w > 0.01
    )
    SELECT n.kind, n.ref, n.label, sum(walk.w)::real AS score, min(walk.hop) AS hops
      FROM walk JOIN stewards.nodes n ON n.id = walk.id
     WHERE walk.hop > 0                                  -- exclude the seeds (hop 0) …
       AND walk.id NOT IN (SELECT id FROM seed)          -- … and any path that loops back to a seed
     GROUP BY n.id, n.kind, n.ref, n.label
     ORDER BY score DESC
     LIMIT p_limit;
$fn$;
COMMENT ON FUNCTION stewards.graph_recall(jsonb,int,int,real) IS
'M3 (WALK): associative recall over the typed graph — spreads weight from seed nodes along edges (both directions, decaying per hop) and ranks reached nodes by connectedness. Augments vector/keyword recall; surfaces multi-hop associations cosine misses.';

CREATE OR REPLACE FUNCTION stewards.graph_recall_tool(p_args jsonb)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(jsonb_build_object('kind',kind,'ref',ref,'label',label,
        'score',round(score::numeric,3),'hops',hops) ORDER BY score DESC), '[]'::jsonb)::text
    FROM stewards.graph_recall(
        coalesce(p_args->'seeds', jsonb_build_array(jsonb_build_object('kind',p_args->>'kind','ref',p_args->>'ref'))),
        coalesce((p_args->>'max_hops')::int, 3), coalesce((p_args->>'limit')::int, 15));
$fn$;

-- ── graph_link_candidates (LINK) — related-but-unlinked node pairs the tending loop can
--    propose edges for. Signal: co-citation (two docs citing the same source) without an
--    existing associative link. Cheap, deterministic; the loop adds the verb + a reason.
CREATE OR REPLACE FUNCTION stewards.graph_link_candidates_tool(p_args jsonb)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'a_kind',ak,'a_ref',ar,'b_kind',bk,'b_ref',br,'shared_sources',shared) ORDER BY shared DESC), '[]'::jsonb)::text
    FROM (
        SELECT na.kind ak, na.ref ar, nb.kind bk, nb.ref br, count(*) shared
          FROM stewards.edges a
          JOIN stewards.edges b ON a.dst = b.dst AND a.src < b.src AND a.kind='CITES' AND b.kind='CITES'
          JOIN stewards.nodes na ON na.id = a.src
          JOIN stewards.nodes nb ON nb.id = b.src
         WHERE NOT EXISTS (
                 SELECT 1 FROM stewards.edges e
                  WHERE e.kind IN ('RELATES_TO','SIMILAR_TO','BUILDS_ON','SUPPORTS','CONTRADICTS')
                    AND ((e.src=a.src AND e.dst=b.src) OR (e.src=b.src AND e.dst=a.src)))
           -- and don't re-surface a pair the Hinge has already ruled on (any verdict): a
           -- revised proposal makes no edge, so without this the same pair is proposed and
           -- re-reviewed every cycle — pure waste (the reviewer is not free).
           AND NOT EXISTS (
                 SELECT 1 FROM stewards.hinge_reviews h
                  WHERE h.kind = 'graph-link'
                    AND ((h.payload->>'src_ref' = na.ref AND h.payload->>'dst_ref' = nb.ref)
                      OR (h.payload->>'src_ref' = nb.ref AND h.payload->>'dst_ref' = na.ref)))
         GROUP BY na.kind, na.ref, nb.kind, nb.ref
        HAVING count(*) >= coalesce((p_args->>'min_shared')::int, 2)
         ORDER BY shared DESC
         LIMIT coalesce((p_args->>'limit')::int, 20)
    ) c;
$fn$;

-- ── memory_link_propose — the loop proposes a typed edge; the Hinge (kind graph-link)
--    gates it; on approval the trigger below creates the edge. The graph only grows
--    connections the Hinge approved.
CREATE OR REPLACE FUNCTION stewards.memory_link_propose(
    p_src_kind text, p_src_ref text, p_dst_kind text, p_dst_ref text, p_kind text, p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_v text := upper(btrim(coalesce(p_kind,''))); v_hid bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM stewards.edge_kinds WHERE name = v_v) THEN
        RETURN jsonb_build_object('ok', false, 'note', 'unknown verb — call graph_vocabulary');
    END IF;
    v_hid := stewards.hinge_enqueue('graph-link',
        p_src_ref || ' ' || v_v || ' ' || p_dst_ref,
        jsonb_build_object('src_kind',p_src_kind,'src_ref',p_src_ref,'dst_kind',p_dst_kind,
                           'dst_ref',p_dst_ref,'kind',v_v,'reason',p_reason),
        'memory-tend');
    RETURN jsonb_build_object('ok', true, 'hinge_id', v_hid, 'note', 'proposed — the Hinge gates it');
END;
$fn$;
CREATE OR REPLACE FUNCTION stewards.memory_link_propose_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $fn$
    SELECT stewards.memory_link_propose(p_args->>'src_kind', p_args->>'src_ref',
        p_args->>'dst_kind', p_args->>'dst_ref', p_args->>'kind', p_args->>'reason')::text;
$fn$;

-- ── on Hinge approval of a graph-link, create the edge.
CREATE OR REPLACE FUNCTION stewards.memory_apply_approved_link()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE p jsonb := NEW.payload;
BEGIN
    IF NEW.kind = 'graph-link' AND NEW.status = 'approved' AND (OLD.status IS DISTINCT FROM 'approved') THEN
        PERFORM stewards.graph_link(p->>'src_kind', p->>'src_ref', p->>'dst_kind', p->>'dst_ref',
                                    p->>'kind', p->>'reason');
        UPDATE stewards.hinge_reviews SET status='applied', applied_at=now() WHERE id = NEW.id;
    END IF;
    RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS hinge_apply_graph_link ON stewards.hinge_reviews;
CREATE TRIGGER hinge_apply_graph_link
AFTER UPDATE OF status ON stewards.hinge_reviews
FOR EACH ROW WHEN (NEW.kind = 'graph-link' AND NEW.status = 'approved')
EXECUTE FUNCTION stewards.memory_apply_approved_link();

-- ── tools + the memory-tend tool group (lean scope for the tending pipeline).
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('memory-tend', 'the self-tending loop tools (walk, find candidates, propose typed links)',
     ARRAY['graph_recall','graph_link_candidates','memory_link_propose','graph_vocabulary','doc_search','doc_get'])
ON CONFLICT (name) DO UPDATE SET tool_patterns = EXCLUDED.tool_patterns;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'graph_recall',
  'Associative recall over the memory graph: give seed nodes (kind+ref) and get the most CONNECTED nodes back (multi-hop, ranked by connectedness) — surfaces relationships cosine/keyword search misses.',
  '{"type":"object","properties":{"seeds":{"type":"array"},"kind":{"type":"string"},"ref":{"type":"string"},"max_hops":{"type":"integer"},"limit":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"graph_recall_tool"}'::jsonb ),
( 'graph_link_candidates',
  'Find related-but-unlinked node pairs (currently: docs that cite the same sources but have no associative edge) — the raw material for proposing new typed links.',
  '{"type":"object","properties":{"min_shared":{"type":"integer"},"limit":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"graph_link_candidates_tool"}'::jsonb ),
( 'memory_link_propose',
  'Propose a TYPED edge between two memory nodes (a canonical verb — see graph_vocabulary — plus a reason). It is queued for the Hinge and the edge is created only on approval. This is how the memory grows its connections, watched.',
  '{"type":"object","required":["src_kind","src_ref","dst_kind","dst_ref","kind"],"properties":{"src_kind":{"type":"string"},"src_ref":{"type":"string"},"dst_kind":{"type":"string"},"dst_ref":{"type":"string"},"kind":{"type":"string"},"reason":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"memory_link_propose_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','graph_recall','allow','manual'),
    ('research','graph_link_candidates','allow','manual'),
    ('research','memory_link_propose','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ── the memory-tend pipeline (M4) — the gentle tending loop (CONNECT/LINK/NUDGE). One
--    tools-on stage, scoped to memory-tend; dispatchable; its intent+schedule live in a
--    workspace overlay (core ships no schedules).
INSERT INTO stewards.pipelines (family, description, stages, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES (
  'memory-tend',
  'The self-tending loop: walk the graph, find related-but-unlinked nodes, and propose typed edges (Hinge-gated). Slow + gentle — the memory grows its own connections.',
  jsonb_build_array(jsonb_build_object(
    'name','tend','next', NULL, 'model','reason','agent_family','research',
    'auto_advance', true, 'tools_disabled', false,
    'tool_groups', jsonb_build_array('memory-tend'),
    'input_template',
      'You are the memory-tend stage — you keep the knowledge graph alive.' || E'\n\n' ||
      '1. Call `graph_link_candidates` to see node pairs that are related (they cite the same sources) but not yet linked.' || E'\n' ||
      '2. For a FEW of the clearest pairs, decide the right relationship and call `memory_link_propose` with a canonical verb (call `graph_vocabulary` if unsure) + a one-line reason. Prefer precision over volume — a few good links, not many weak ones. Each goes to the Hinge.' || E'\n' ||
      '3. Reply with a short journal: which links you proposed and why.'
  )),
  '["raw","verified"]'::jsonb, false, jsonb_build_object('pools_via_tool', true))
ON CONFLICT (family) DO UPDATE SET stages = EXCLUDED.stages, description = EXCLUDED.description, updated_at = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity)
VALUES ('memory-tend','tend','verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

-- =====================================================================
-- End of 41-memory-tend.sql
-- =====================================================================
