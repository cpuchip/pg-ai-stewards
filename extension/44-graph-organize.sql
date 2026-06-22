-- =====================================================================
-- 44-graph-organize.sql — the ORGANIZE keystone: corpus -> graph, with freshness.
-- =====================================================================
-- The "info brain" gained edge creation (graph_link, 38) and associative recall
-- (graph_recall, 41) but had NO way for a deliberate stage to create a NODE from a
-- corpus — graph_link only auto-upserts the endpoints of a relationship. This adds the
-- missing primitives so a gather -> ORGANIZE pipeline can turn just-gathered material
-- into structured, typed, TIME-AWARE knowledge:
--   * graph_node      — create/refresh an entity/claim node (stamps observed_at + status).
--   * graph_supersede — mark a node superseded and assert new SUPERSEDES old (SUPERSEDES
--                       already in the edge_kinds vocabulary, 38).
--   * graph_recall    — re-authored with an OPT-IN fresh_only filter (default off =
--                       identical to 41) so a reader can ignore resolved/stale/superseded
--                       nodes. A general info-brain property: the whole graph ages
--                       gracefully (news, evolving subjects), not just one slice.
--   * the graph-organize + graph-read tool_groups — the per-stage scopes.
--
-- DESIGN: an ORGANIZE stage runs inside an (already-approved) pipeline, so it asserts
-- nodes/edges DIRECTLY (graph_node/graph_link) — fast, the run is the unit of approval.
-- That is distinct from the AMBIENT memory-tend loop (41), which is unsupervised and so
-- routes every edge through the Hinge (memory_link_propose). Supervised batch vs.
-- autonomous trickle.
-- requires create_request_research (43, tail of the chain) + graph (01) + edge-vocab (38)
-- + memory-tend (41, the graph_recall it re-authors) + tool-groups (37).
-- =====================================================================

-- ── graph_node — create or refresh a node, stamping recency. props MERGE on upsert
--    (01 graph_node_upsert), so a re-sighting refreshes observed_at; caller-supplied
--    props win over the defaults (the || right operand wins on key conflict).
CREATE OR REPLACE FUNCTION stewards.graph_node_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_kind  text := btrim(coalesce(p_args->>'kind',''));
    v_ref   text := btrim(coalesce(p_args->>'ref',''));
    v_label text := p_args->>'label';
    v_props jsonb := coalesce(p_args->'props', '{}'::jsonb);
    v_id    uuid;
BEGIN
    IF v_kind = '' OR v_ref = '' THEN
        RETURN '{"error":"kind and ref are required (ref = a stable identifier for the entity/claim)"}';
    END IF;
    -- defaults first, caller props last (caller wins): a fresh sighting stamps now();
    -- an explicit status (e.g. resolved) or observed_at is honored.
    v_props := jsonb_build_object('observed_at', now(), 'status', 'current') || v_props;
    v_id := stewards.graph_node_upsert(v_kind, v_ref, v_label, v_props);
    RETURN jsonb_build_object('ok', true, 'node_id', v_id, 'kind', v_kind, 'ref', v_ref,
        'note', 'node upserted (props merged; observed_at refreshed)')::text;
END $fn$;
COMMENT ON FUNCTION stewards.graph_node_tool(jsonb) IS
'44: create/refresh a graph node from a corpus. Args: kind, ref (stable id), label?, props?. Stamps props.observed_at=now() + props.status=current unless the caller overrides. The ORGANIZE stage''s node-maker (graph_link only auto-upserts edge endpoints).';

-- ── graph_supersede — time-awareness: a node is no longer current; a newer one replaces
--    it. Marks the old node''s status + stamps superseded_at, and asserts new SUPERSEDES
--    old (auto-upserts both). Resolved/stale (no successor) = just set status via graph_node.
CREATE OR REPLACE FUNCTION stewards.graph_supersede(
    p_old_kind text, p_old_ref text, p_new_kind text, p_new_ref text, p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_link jsonb; v_n int;
BEGIN
    IF coalesce(p_old_ref,'') = '' OR coalesce(p_new_ref,'') = '' THEN
        RETURN jsonb_build_object('ok', false, 'note', 'old and new refs are required');
    END IF;
    UPDATE stewards.nodes
       SET props = props || jsonb_build_object('status','superseded','superseded_at', now()),
           updated_at = now()
     WHERE kind = p_old_kind AND ref = p_old_ref;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_link := stewards.graph_link(p_new_kind, p_new_ref, p_old_kind, p_old_ref, 'SUPERSEDES', p_reason);
    RETURN jsonb_build_object('ok', true, 'old_marked', v_n, 'edge', v_link,
        'reading', p_new_ref || ' SUPERSEDES ' || p_old_ref);
END $fn$;
COMMENT ON FUNCTION stewards.graph_supersede(text,text,text,text,text) IS
'44: time-awareness — mark the old node superseded (props.status + superseded_at) and assert new SUPERSEDES old. For resolved/stale with no successor, set props.status via graph_node instead.';

CREATE OR REPLACE FUNCTION stewards.graph_supersede_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $fn$
    SELECT stewards.graph_supersede(
        p_args->>'old_kind', p_args->>'old_ref',
        p_args->>'new_kind', p_args->>'new_ref', p_args->>'reason')::text;
$fn$;

-- ── graph_recall_tool — re-authored from 41 with an OPT-IN fresh_only filter. Default
--    off → byte-for-byte the 41 behavior (the memory-tend callers are unaffected). When
--    fresh_only, drop reached nodes whose status is superseded/resolved/stale. Post-filter
--    (the walk's limit is applied first), so fresh_only can return fewer than `limit` —
--    acceptable for a freshness pass; the analyze stage just asks for more if it needs to.
CREATE OR REPLACE FUNCTION stewards.graph_recall_tool(p_args jsonb)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(jsonb_build_object('kind',r.kind,'ref',r.ref,'label',r.label,
        'score',round(r.score::numeric,3),'hops',r.hops) ORDER BY r.score DESC), '[]'::jsonb)::text
    FROM stewards.graph_recall(
        coalesce(p_args->'seeds', jsonb_build_array(jsonb_build_object('kind',p_args->>'kind','ref',p_args->>'ref'))),
        coalesce((p_args->>'max_hops')::int, 3), coalesce((p_args->>'limit')::int, 15)) r
    WHERE NOT coalesce((p_args->>'fresh_only')::bool, false)
       OR NOT EXISTS (SELECT 1 FROM stewards.nodes n
                       WHERE n.kind = r.kind AND n.ref = r.ref
                         AND n.props->>'status' IN ('superseded','resolved','stale'));
$fn$;

-- ── tool_defs: graph_node, graph_supersede; refresh graph_recall''s description (fresh_only).
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'graph_node',
  'Create or refresh a knowledge-graph node for an entity, claim, category, or fact found in the corpus. Args: kind (e.g. fault, product, category, claim, root_cause), ref (a stable identifier — reuse the same ref to refresh the same node), label (human title), props (optional facts). The node is stamped observed_at=now and status=current automatically; pass props.status=resolved/stale to age it. Use during ORGANIZE to turn gathered material into nodes; link them with graph_link.',
  '{"type":"object","required":["kind","ref"],"properties":{"kind":{"type":"string"},"ref":{"type":"string"},"label":{"type":"string"},"props":{"type":"object"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"graph_node_tool"}'::jsonb, true ),
( 'graph_supersede',
  'Time-awareness: mark a node as no longer current because a newer one replaces it. Asserts new SUPERSEDES old and stamps the old node superseded. Args: old_kind, old_ref, new_kind, new_ref, reason. For an issue that is simply resolved or stale with no successor, call graph_node with props.status=resolved instead.',
  '{"type":"object","required":["old_kind","old_ref","new_kind","new_ref"],"properties":{"old_kind":{"type":"string"},"old_ref":{"type":"string"},"new_kind":{"type":"string"},"new_ref":{"type":"string"},"reason":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"graph_supersede_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

UPDATE stewards.tool_defs
   SET description = 'Associative recall over the typed knowledge graph: spread weight from seed node(s) along edges and rank reached nodes by connectedness (surfaces multi-hop links cosine misses). Args: seeds (array of {kind,ref}) or a single kind+ref, max_hops, limit, fresh_only (when true, omit nodes marked superseded/resolved/stale — use it when you only want current knowledge).'
 WHERE name = 'graph_recall';

-- ── grants: the analyze/organize family may create/age nodes (graph_link/recall/vocabulary
--    are already active+ungated). A stage still opts in via the tool_groups below.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('research','graph_node','allow'),
  ('research','graph_supersede','allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action='allow';

-- ── the per-stage scopes.
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('graph-organize',
   'turn a gathered corpus into typed, time-aware graph knowledge: create nodes (graph_node), assert relationships (graph_link), age out the resolved/superseded (graph_supersede), and see what is already there (graph_recall, graph_vocabulary).',
   ARRAY['graph_node','graph_link','graph_supersede','graph_recall','graph_vocabulary']),
  ('graph-read',
   'read the knowledge graph to reason over it: associative recall (graph_recall, supports fresh_only) + the edge vocabulary (graph_vocabulary).',
   ARRAY['graph_recall','graph_vocabulary'])
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, tool_patterns=EXCLUDED.tool_patterns;

-- =====================================================================
-- End of 44-graph-organize.sql
-- =====================================================================
