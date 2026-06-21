-- =====================================================================
-- 38-edge-vocabulary.sql — the graph's grammar (Phase M1 of the self-tending memory).
-- =====================================================================
-- The graph (01-graph) stores typed edges and edge kinds are OPEN data ("a row, not a
-- migration"). But the vocabulary in use is one verb deep — `CITES` (parse provenance
-- from import_doc) is ~all there is. A memory that tends itself needs a richer voice:
-- causal, dialectical, and associative relationships, not just citation.
--
-- This is the CANONICAL vocabulary (a registry) + a typed `graph_link` the tending
-- loops and agents use to assert relationships against it. `graph_edge_upsert` (01)
-- stays open for importers (CITES) and legacy callers; `graph_link` is the curated path
-- that VALIDATES the verb, so the self-managing loops keep the vocabulary clean.
-- requires create_tool_groups (37). Phase M2+ (the LINK/WALK/tending loops) build on this.
-- =====================================================================

-- ── the canonical edge-verb registry ────────────────────────────────
CREATE TABLE IF NOT EXISTS stewards.edge_kinds (
    name            text PRIMARY KEY CHECK (name = upper(name)),     -- the verb, UPPER_SNAKE
    edge_group      text NOT NULL CHECK (edge_group IN ('provenance','causal','dialectical','associative')),
    gloss           text NOT NULL,                                    -- one-line meaning (src → dst)
    is_symmetric    boolean NOT NULL DEFAULT false,                   -- A↔B (e.g. SIMILAR_TO) vs directed
    inverse_reading text,                                             -- how to read dst → src for directed verbs
    created_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.edge_kinds IS
'38: the canonical edge-verb vocabulary for the self-tending memory graph. graph_link validates against it. Edge kinds remain open in stewards.edges (a row, not a migration); this is the curated set the tending loops use.';

INSERT INTO stewards.edge_kinds (name, edge_group, gloss, is_symmetric, inverse_reading) VALUES
  -- provenance / structural
  ('CITES',        'provenance',  'src quotes or references dst as a source',               false, 'is cited by'),
  ('MENTIONS',     'provenance',  'src names dst without citing it as a source',            false, 'is mentioned by'),
  ('DECLARED',     'provenance',  'src (an actor/run) declared/produced dst',               false, 'was declared by'),
  ('DERIVED_FROM', 'provenance',  'src (a summary/engram) points home to its raw dst',      false, 'is the source of'),
  -- causal / logical
  ('BUILDS_ON',    'causal',      'src extends or presupposes dst',                         false, 'is built on by'),
  ('DEPENDS_ON',   'causal',      'src requires dst to hold',                               false, 'is depended on by'),
  ('CAUSED_BY',    'causal',      'src is a consequence of dst',                            false, 'caused'),
  ('REFINES',      'causal',      'src sharpens or corrects dst',                           false, 'is refined by'),
  ('ELABORATES',   'causal',      'src expands on dst',                                     false, 'is elaborated by'),
  ('EXEMPLIFIES',  'causal',      'src is a concrete instance of the general dst',          false, 'is exemplified by'),
  -- dialectical (the council verbs)
  ('SUPPORTS',     'dialectical', 'src is evidence for dst',                                false, 'is supported by'),
  ('CONTRADICTS',  'dialectical', 'src is in direct conflict with dst',                     true,  NULL),
  ('TENSIONS_WITH','dialectical', 'src sits in unresolved tension with dst',                true,  NULL),
  ('QUALIFIES',    'dialectical', 'src bounds or conditions dst',                           false, 'is qualified by'),
  ('SUPERSEDES',   'dialectical', 'src replaces dst as the current truth',                  false, 'is superseded by'),
  ('ANSWERS',      'dialectical', 'src answers the question posed by dst',                  false, 'is answered by'),
  -- associative
  ('SIMILAR_TO',   'associative', 'src and dst are near in meaning (often vector-derived)', true,  NULL),
  ('RELATES_TO',   'associative', 'src and dst are related (discovered, weak)',             true,  NULL),
  ('ANALOGOUS_TO', 'associative', 'src and dst share a structure across domains',           true,  NULL)
ON CONFLICT (name) DO UPDATE SET
  edge_group = EXCLUDED.edge_group, gloss = EXCLUDED.gloss,
  is_symmetric = EXCLUDED.is_symmetric, inverse_reading = EXCLUDED.inverse_reading;

-- ── graph_link — assert a TYPED relationship (validated against the vocabulary).
--    Ref-based (node kind+ref) so agents/loops link by stable identity (e.g. doc slug).
--    For a symmetric verb, writes both directions so a walk finds it either way.
CREATE OR REPLACE FUNCTION stewards.graph_link(
    p_src_kind text, p_src_ref text,
    p_dst_kind text, p_dst_ref text,
    p_kind text, p_reason text DEFAULT NULL, p_weight real DEFAULT 1.0
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_kind  text := upper(btrim(coalesce(p_kind, '')));
    v_ek    stewards.edge_kinds%ROWTYPE;
    v_props jsonb;
    v_id    uuid;
BEGIN
    SELECT * INTO v_ek FROM stewards.edge_kinds WHERE name = v_kind;
    IF v_ek.name IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'note', 'unknown edge verb "' || v_kind || '" — use one of the canonical verbs',
            'verbs', (SELECT jsonb_agg(name ORDER BY edge_group, name) FROM stewards.edge_kinds));
    END IF;
    IF coalesce(p_src_ref,'') = '' OR coalesce(p_dst_ref,'') = '' THEN
        RETURN jsonb_build_object('ok', false, 'note', 'src and dst refs are required');
    END IF;
    v_props := jsonb_strip_nulls(jsonb_build_object('reason', p_reason, 'by', 'graph_link'));
    v_id := stewards.graph_edge_upsert(p_src_kind, p_src_ref, p_dst_kind, p_dst_ref, v_kind, p_weight, v_props);
    IF v_ek.is_symmetric THEN
        PERFORM stewards.graph_edge_upsert(p_dst_kind, p_dst_ref, p_src_kind, p_src_ref, v_kind, p_weight, v_props);
    END IF;
    RETURN jsonb_build_object('ok', true, 'edge_id', v_id, 'kind', v_kind,
        'symmetric', v_ek.is_symmetric, 'reading', p_src_ref || ' ' || v_kind || ' ' || p_dst_ref);
END;
$fn$;
COMMENT ON FUNCTION stewards.graph_link(text,text,text,text,text,text,real) IS
'38: assert a typed relationship validated against edge_kinds. Ref-based; symmetric verbs are written both ways. The curated path the tending loops use (graph_edge_upsert stays open for importers).';

CREATE OR REPLACE FUNCTION stewards.graph_link_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $fn$
    SELECT stewards.graph_link(
        p_args->>'src_kind', p_args->>'src_ref',
        p_args->>'dst_kind', p_args->>'dst_ref',
        p_args->>'kind', p_args->>'reason',
        coalesce((p_args->>'weight')::real, 1.0))::text;
$fn$;

-- ── graph_vocabulary — list the canonical verbs (so agents/loops use the right one).
CREATE OR REPLACE FUNCTION stewards.graph_vocabulary_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $fn$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'verb', name, 'group', edge_group, 'gloss', gloss, 'symmetric', is_symmetric
    ) ORDER BY edge_group, name), '[]'::jsonb)::text
    FROM stewards.edge_kinds;
$fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'graph_vocabulary',
  'List the canonical edge verbs (relationship types) you can use to link memory nodes — grouped provenance/causal/dialectical/associative, with their meanings. Call this before graph_link if unsure which verb to use.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"graph_vocabulary_tool"}'::jsonb ),
( 'graph_link',
  'Assert a TYPED relationship between two memory nodes (by kind+ref, e.g. doc/<slug>, scripture/<ref>). kind must be a canonical verb (see graph_vocabulary). Give a short reason. Symmetric verbs (SIMILAR_TO, CONTRADICTS, …) are linked both ways automatically. This is how the memory grows its connections.',
  '{"type":"object","required":["src_kind","src_ref","dst_kind","dst_ref","kind"],"properties":{"src_kind":{"type":"string"},"src_ref":{"type":"string"},"dst_kind":{"type":"string"},"dst_ref":{"type":"string"},"kind":{"type":"string","description":"a canonical edge verb"},"reason":{"type":"string"},"weight":{"type":"number"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"graph_link_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- Grant to research (the tending loops run as research); deny-by-default elsewhere.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','graph_vocabulary','allow','manual'),
    ('research','graph_link','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- End of 38-edge-vocabulary.sql
-- =====================================================================
