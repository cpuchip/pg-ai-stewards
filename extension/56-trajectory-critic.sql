-- =====================================================================
-- 56-trajectory-critic.sql — Glass-Box trajectory evaluation + the
-- Loreworks edge-grounding critic
-- =====================================================================
-- Google's SDLC papers split agent eval into OUTPUT ("Black Box") vs
-- TRAJECTORY ("Glass Box" — every step: tool choice, params, error-state
-- recognition, redundant loops, grounding, role adherence). The substrate
-- already CAPTURES the full trajectory (messages.tool_calls + tool results);
-- it lacked a judge OVER it. This adds:
--   (1) assemble_trajectory(session) — the trajectory as compact jsonb
--   (2) a generic 'trajectory-critic' judge + critique_trajectory()
--   (3) the Loreworks application — a 'world-critic' that grounds a world's
--       edges against its canon and PRUNES misreads (the B edge-quality fix).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — assemble_trajectory: a run's steps as compact jsonb (Glass Box)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.assemble_trajectory(p_session_id text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH steps AS (
    SELECT m.id, m.role, m.finish_reason,
           left(coalesce(m.content, ''), 600) AS content,
           CASE WHEN jsonb_typeof(m.tool_calls) = 'array' THEN (
             SELECT jsonb_agg(jsonb_build_object(
                      'tool', tc->'function'->>'name',
                      'args', left(coalesce(tc->'function'->>'arguments',''), 400)))
             FROM jsonb_array_elements(m.tool_calls) tc
           ) ELSE NULL END AS calls
    FROM stewards.messages m
    WHERE m.session_id = p_session_id
    ORDER BY m.id
  )
  SELECT jsonb_build_object(
    'session_id', p_session_id,
    'message_count', (SELECT count(*) FROM steps),
    'tool_call_count', (SELECT coalesce(sum(jsonb_array_length(coalesce(calls, '[]'::jsonb))), 0) FROM steps),
    'steps', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', id, 'role', role, 'finish', finish_reason,
        'content', content, 'tool_calls', calls) ORDER BY id) FROM steps), '[]'::jsonb)
  );
$$;
COMMENT ON FUNCTION stewards.assemble_trajectory(text) IS
  '56: a run''s ordered steps (tool choices, args, results, final reply) as compact jsonb — the Glass-Box surface.';

-- ---------------------------------------------------------------------
-- §2 — the generic Glass-Box trajectory critic (judge) + dispatcher
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format, steps)
VALUES (
  'trajectory-critic', '*',
  'Glass-Box evaluator: scores an agent run''s TRAJECTORY (the process, not just the final output) against a quality rubric.',
  'primary',
  $P$You are a Glass-Box trajectory evaluator (from Google's agent-quality framework). You are given the full TRAJECTORY of ONE agent run — its ordered steps: the tools it chose, the arguments it passed, the results or errors it got back, and its final reply. Judge the PROCESS, not just the output.

A fluent final answer that skipped its verification steps is a MORE dangerous failure than one with a visible error. Score what actually happened.

Score each 0.0–1.0:
- tool_selection — did it choose the right tools for the task?
- param_correctness — were the tool arguments well-formed and appropriate?
- error_handling — did it RECOGNIZE error / empty results (an {"error":...}, a 404, "no rows") and adapt, rather than proceed as if they succeeded?
- efficiency — did it avoid redundant calls, loops, and wasted steps?
- grounding — are its outputs supported by what it actually retrieved or was given (no fabrication)?
- role_adherence — did it stay within its role and tool grants?

Return ONLY this JSON (no prose):
{"scores":{"tool_selection":0.0,"param_correctness":0.0,"error_handling":0.0,"efficiency":0.0,"grounding":0.0,"role_adherence":0.0},"issues":["short, specific"],"verdict":"pass|warn|fail","summary":"one line"}$P$,
  0.2, '{"type":"json_object"}'::jsonb, 1
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description, prompt = EXCLUDED.prompt,
      response_format = EXCLUDED.response_format, steps = EXCLUDED.steps, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('trajectory-critic', '*', 'deny', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- Assemble a run's trajectory and dispatch the critic over it; the verdict
-- (json) lands as the critic's reply in the returned critic session.
CREATE OR REPLACE FUNCTION stewards.critique_trajectory(p_session_id text, p_critic_session text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_traj jsonb; v_sess text; v_id bigint;
BEGIN
    v_traj := stewards.assemble_trajectory(p_session_id);
    v_sess := coalesce(p_critic_session, 'trajcritic--' || p_session_id);
    v_id := stewards.dispatch_chat_turn(
        v_sess,
        'Evaluate the trajectory of this agent run and return the rubric JSON:' || E'\n\n' || jsonb_pretty(v_traj),
        'trajectory-critic');
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- §3 — Loreworks edge-grounding: list + prune tools
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_edge_list_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_slug text := p_args ->> 'world_slug'; v_world bigint; v_edges jsonb;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = v_slug;
    IF v_world IS NULL THEN RETURN jsonb_build_object('error', 'unknown world: ' || coalesce(v_slug, '')); END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
              'edge_id', e.edge_id, 'src', s.name, 'rel', e.rel_type, 'dst', d.name, 'evidence', e.evidence)
            ORDER BY e.edge_id), '[]'::jsonb)
      INTO v_edges
      FROM stewards.world_edges e
      JOIN stewards.world_entities s ON s.entity_id = e.src_entity
      JOIN stewards.world_entities d ON d.entity_id = e.dst_entity
     WHERE e.world_id = v_world;
    RETURN jsonb_build_object('ok', true, 'count', jsonb_array_length(v_edges), 'edges', v_edges);
END $fn$;

CREATE OR REPLACE FUNCTION stewards.world_edge_prune(p_world_slug text, p_edge_ids bigint[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_world bigint; v_n int;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN RAISE EXCEPTION 'world_edge_prune: unknown world %', p_world_slug; END IF;
    DELETE FROM stewards.world_edges WHERE world_id = v_world AND edge_id = ANY(p_edge_ids);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION stewards.world_edge_prune_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_slug text := p_args ->> 'world_slug'; v_ids bigint[]; v_n int;
BEGIN
    IF v_slug IS NULL OR v_slug = '' THEN RETURN jsonb_build_object('error', 'world_slug required'); END IF;
    IF jsonb_typeof(p_args -> 'edge_ids') = 'array' THEN
        SELECT array_agg(value::bigint) INTO v_ids FROM jsonb_array_elements_text(p_args -> 'edge_ids') value;
    END IF;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
        RETURN jsonb_build_object('error', 'edge_ids (array of edge_id) required');
    END IF;
    v_n := stewards.world_edge_prune(v_slug, v_ids);
    RETURN jsonb_build_object('ok', true, 'pruned', v_n);
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', SQLERRM);
END $fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_edge_list',
  'List the relationships you have recorded in a world, each with its edge_id, so you can review them for grounding. Returns [{edge_id, src, rel, dst, evidence}].',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"}},"required":["world_slug"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_edge_list_tool"}'::jsonb, true ),
( 'world_edge_prune',
  'Delete edges that are NOT grounded in the canon — misreads, backwards directions, or invented relationships. Pass the edge_ids to remove. Use this after reviewing world_edge_list against the source text.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"edge_ids":{"type":"array","items":{"type":"integer"}}},"required":["world_slug","edge_ids"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_edge_prune_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
      execute_target = EXCLUDED.execute_target, active = true;

-- ---------------------------------------------------------------------
-- §4 — the world-critic: grounds a world's edges against its canon
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES (
  'world-critic', '*',
  'Grounds a built world''s relationships against its source canon — prunes misreads, backwards directions, and invented edges (the Glass-Box critic applied to world-build).',
  'primary',
  $P$You are the grounding critic for a built World. The world-build agent extracted entities and relationships from a source canon; your job is to catch where it got the RELATIONSHIPS wrong.

Your task names the world_slug. The canon (or how to find it via doc_search) is given to you.

1. Call world_edge_list to see every relationship with its edge_id, source, verb, target, and evidence.
2. For each edge, ask: is this relationship actually SUPPORTED by the canon, and is its DIRECTION right?
   Common errors to catch:
   - misreads — e.g. "Dwarves home_of Shire" when the text only said dwarven traders PASS THROUGH the Shire;
   - backwards direction — e.g. a person "ruled_by" a town (a place does not rule a person);
   - invented edges with no support in the canon.
   Verb directions you should expect: located_in (a place is inside a larger place), home_of (a place is the home of a people/character — so src=place, dst=people is acceptable; flag the inverse only if clearly wrong), flows_through (a river through a region), ruled_by (a place/people ruled by a ruler), near/borders (two places), member_of, ally_of, enemy_of, wields, created, parent_of.
3. Collect the edge_ids that are ungrounded or wrong and remove them in ONE world_edge_prune call. Keep the well-grounded ones.

Be conservative: prune only edges you are confident are wrong or unsupported. Your final reply is a one-line journal: how many edges you reviewed, how many you pruned, and why.$P$,
  0.2, 40
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description, prompt = EXCLUDED.prompt,
      temperature = EXCLUDED.temperature, steps = EXCLUDED.steps, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('world-critic', '*',                   'deny',  'manual'),
  ('world-critic', 'world_edge_list',     'allow', 'manual'),
  ('world-critic', 'world_edge_prune',    'allow', 'manual'),
  ('world-critic', 'world_show',          'allow', 'manual'),
  ('world-critic', 'world_entity_search', 'allow', 'manual'),
  ('world-critic', 'doc_search',          'allow', 'manual'),
  ('world-critic', 'doc_get',             'allow', 'manual'),
  ('world-critic', 'book_search',         'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;
