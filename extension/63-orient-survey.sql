-- =====================================================================
-- 63-orient-survey.sql — the universal orient move: "what already exists here?"
-- =====================================================================
-- Phase 2 of lending the substrate our orientation. Phase 1 gave every corpus-
-- builder the orient-first DISPOSITION (the skill) — and the watch showed agents
-- acting on it ("I'll start by orienting…") using whatever survey they had
-- (world-build called world_show; the chat called doc_search). This gives them
-- the MECHANISM uniformly: orient_survey generalizes the reflect-steward's
-- intent_work_survey (22, intent-scoped, planner-only) to ANY agent, keyed on a
-- PROJECT — what docs, worlds, and work already exist for it, so the builder
-- EXTENDS rather than rebuilds. The council moment (Abraham 4:26) as a tool, for
-- everyone, not just the planner.
--
-- requires create_orientation (62). Generic core.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.orient_survey_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $FN$
DECLARE
    v_sess    text := p_args->>'_session_id';
    v_project text := nullif(btrim(coalesce(p_args->>'project','')), '');
BEGIN
    -- resolve the project: explicit arg, else this session's work_item.
    IF v_project IS NULL THEN
        SELECT project_association INTO v_project
          FROM stewards.work_items
         WHERE v_sess = ANY(session_ids) AND project_association IS NOT NULL
         ORDER BY id DESC LIMIT 1;
    END IF;
    IF v_project IS NULL THEN
        RETURN '{"error":"no project to orient on — pass {\"project\":\"<name>\"} (or call this from a project-scoped work item)"}';
    END IF;

    RETURN jsonb_build_object(
        'project', v_project,
        'doc_count', (SELECT count(*) FROM stewards.docs WHERE project_association = v_project),
        'recent_docs', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'slug', slug, 'title', title,
                       'gist', left(regexp_replace(coalesce(body,''), '\s+', ' ', 'g'), 160)
                     ) ORDER BY updated_at DESC), '[]'::jsonb)
              FROM (SELECT slug, title, body, updated_at FROM stewards.docs
                     WHERE project_association = v_project ORDER BY updated_at DESC LIMIT 10) d),
        'existing_worlds', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'slug', w.slug, 'name', w.name,
                       'entities', (SELECT count(*) FROM stewards.world_entities e WHERE e.world_id = w.world_id),
                       'edges', (SELECT count(*) FROM stewards.world_edges g WHERE g.world_id = w.world_id))), '[]'::jsonb)
              FROM stewards.worlds w WHERE w.project = v_project),
        'recent_work', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'slug', slug, 'pipeline', pipeline_family, 'status', status) ORDER BY created_at DESC), '[]'::jsonb)
              FROM (SELECT slug, pipeline_family, status, created_at FROM stewards.work_items
                     WHERE project_association = v_project ORDER BY created_at DESC LIMIT 10) wi),
        'note', 'ORIENT — this is what already exists for this project. EXTEND it; do not rebuild or duplicate what is already here. If a world or doc already covers what you were asked to make, deepen that line rather than starting over (cite its slug). This is your council moment (Abraham 4:26 — take counsel before acting).'
    )::text;
END $FN$;
COMMENT ON FUNCTION stewards.orient_survey_tool(jsonb) IS
'63: the universal orient survey — "what already exists for this project?" (docs + worlds + work). Generalizes intent_work_survey (22) from intent→project so any corpus-builder can orient before acting, not just the reflect-steward.';

-- ── register + grant to the corpus-builders (the agents that carry orient-first) ──
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES (
  'orient_survey',
  'Orient before you build: returns what ALREADY EXISTS for a project — how many docs, the recent ones with a gist, any worlds built over it (with entity/edge counts), and recent work items. Call this FIRST when you are building/extracting/researching over a project, so you extend what is there instead of duplicating it. Pass {"project":"<name>"} or call from a project-scoped work item. Your council moment.',
  '{"type":"object","additionalProperties":false,"properties":{"project":{"type":"string","description":"the project/corpus to orient on (optional if your work item is project-scoped)"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"orient_survey_tool"}'::jsonb, true)
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('world-build',              'orient_survey', 'allow', 'manual'),
  ('research',                 'orient_survey', 'allow', 'manual'),
  ('subagent-doc-investigate', 'orient_survey', 'allow', 'manual'),
  ('subagent-docs-audit',      'orient_survey', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- =====================================================================
-- End of 63-orient-survey.sql
-- =====================================================================
