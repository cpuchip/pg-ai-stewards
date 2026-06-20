-- =====================================================================
-- 37-tool-groups.sql — per-stage TOOL scoping (the tool-side mirror of skill groups).
-- =====================================================================
-- compose_tools is a DENY-list: every active tool ships on every dispatch unless the
-- agent explicitly denies it. The generic `research` agent therefore carries ~150
-- tools (coder, dnd, gospel, doc, context, productivity, …) on EVERY stage — a research
-- GATHER turn shipped a 54k-token prompt that was mostly tool schemas, which is what
-- wedged the local model. Skill-groups solved this for SKILLS (instruction modules);
-- this does the same for TOOLS: a pipeline stage names tool-groups it actually needs,
-- and compose_tools narrows to that scope (an allow-list INTERSECTED with the deny-list).
--
-- A stage with no tool_groups declaration is UNCHANGED (full deny-list) — fully
-- backward-compatible. Scope is derived from the dispatch session id
-- (wi--<uuid8>--<stage>) so nothing else has to plumb it through.
-- requires create_productivity (26 = compose_tools final) + work-items/pipelines (04).
-- =====================================================================

-- ── tool_groups: named bundles of tool-name glob patterns (sibling of skill_groups)
CREATE TABLE IF NOT EXISTS stewards.tool_groups (
    name          text PRIMARY KEY CHECK (name ~ '^[a-z0-9-]+$'),
    description   text,
    tool_patterns text[] NOT NULL DEFAULT '{}',
    created_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.tool_groups IS
'37: named bundles of tool-name glob patterns. A pipeline stage declares stages[].tool_groups=[names]; compose_tools then narrows that stage''s tool list to the union of the groups'' patterns (intersected with the agent deny-list). The tool-side mirror of skill_groups.';

-- core groups (generic; a pattern that matches no installed tool just contributes nothing)
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('web-research', 'external web search + fetch + the page-in readers + the source dedup ledger',
     ARRAY['web_search','web_search_exa','news_search','instant_answer','deep_research',
           'fetch_url','fetch_urls','fetch_url_raw','extract_links',
           'result_read','result_search',
           'intent_sources_recent','intent_source_record','intent_work_survey','pool_search']),
  ('substrate-read', 'read the substrate''s own prior work (files, docs, work_items, watchman)',
     ARRAY['fs_read','fs_list','fs_search','doc_search','doc_get','doc_similar','doc_context_for',
           'work_item_list','work_item_show','watchman_pass_show','watchman_passes_list',
           'intent_work_survey','pool_search','result_read','result_search']),
  ('doc-build', 'build a document with the doc_* tool-call diffs + page-in readers + the publish bridges',
     ARRAY['doc_create','doc_append_section','doc_patch','doc_read','doc_current','doc_finalize',
           'book_publish_draft','playlist_publish_draft','book_publish','playlist_publish',
           'result_read','result_search','fetch_url','fetch_urls','yt_get'])
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, tool_patterns=EXCLUDED.tool_patterns;

-- ── resolve a stages[].tool_groups jsonb array → the union of glob patterns (NULL = unscoped)
CREATE OR REPLACE FUNCTION stewards.resolve_tool_scope(p_groups jsonb)
RETURNS text[] LANGUAGE sql STABLE AS $fn$
    SELECT CASE
        WHEN p_groups IS NULL OR jsonb_typeof(p_groups) <> 'array' OR jsonb_array_length(p_groups) = 0
            THEN NULL
        ELSE (SELECT array_agg(DISTINCT pat)
                FROM stewards.tool_groups tg, unnest(tg.tool_patterns) pat
               WHERE tg.name IN (SELECT jsonb_array_elements_text(p_groups)))
    END;
$fn$;
COMMENT ON FUNCTION stewards.resolve_tool_scope(jsonb) IS
'37: a stages[].tool_groups array → the union of the named groups'' glob patterns. NULL when no groups (compose_tools then applies no scope). Fail-open: an unknown group name contributes nothing (and all-unknown → NULL → unscoped, never an empty toolbox).';

-- ── derive the tool scope for a dispatch session (wi--<uuid8>--<stage>)
CREATE OR REPLACE FUNCTION stewards.session_tool_scope(p_session_id text)
RETURNS text[] LANGUAGE sql STABLE AS $fn$
    SELECT stewards.resolve_tool_scope(s.elem -> 'tool_groups')
      FROM stewards.work_items w
      JOIN stewards.pipelines p ON p.family = w.pipeline_family
      CROSS JOIN jsonb_array_elements(p.stages) s(elem)
     WHERE p_session_id IS NOT NULL AND left(p_session_id, 4) = 'wi--'
       AND left(w.id::text, 8) = split_part(p_session_id, '--', 2)
       AND s.elem ->> 'name' = split_part(p_session_id, '--', 3)
     LIMIT 1;
$fn$;
COMMENT ON FUNCTION stewards.session_tool_scope(text) IS
'37: the tool scope (glob patterns) for a dispatch session, from its work item''s pipeline stage''s tool_groups. NULL for non-wi sessions or a stage with no tool_groups (→ unscoped).';

-- ── compose_tools_scoped — a thin WRAPPER over compose_tools that narrows the tool
--    list to a per-stage scope. We do NOT overload compose_tools(text) (it is an
--    extension member that can't be dropped, and a second overload makes the 1-arg
--    call ambiguous for every existing caller) — so this is a separate function that
--    reuses compose_tools and post-filters. NULL/empty scope = the full set, verbatim.
CREATE OR REPLACE FUNCTION stewards.compose_tools_scoped(p_agent_family text, p_scope_patterns text[] DEFAULT NULL)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT CASE
        WHEN p_scope_patterns IS NULL OR array_length(p_scope_patterns, 1) IS NULL
            THEN stewards.compose_tools(p_agent_family)
        ELSE coalesce((
            SELECT jsonb_agg(e ORDER BY e->'function'->>'name')
              FROM jsonb_array_elements(stewards.compose_tools(p_agent_family)) e
             WHERE EXISTS (SELECT 1 FROM unnest(p_scope_patterns) pat
                            WHERE stewards.glob_match(pat, e->'function'->>'name'))
        ), '[]'::jsonb)
    END;
$fn$;
COMMENT ON FUNCTION stewards.compose_tools_scoped(text, text[]) IS
'37: compose_tools narrowed to a per-stage tool scope (the tool-groups allow-list, intersected with compose_tools'' deny-list/gating). NULL scope returns the full compose_tools set unchanged. dry_run_chat passes session_tool_scope(session) here so a stage that declares tool_groups ships only the tools it needs.';

-- ── dry_run_chat (the dispatch body builder) passes the session''s stage scope.
--    Faithful re-author of the 04/26 final with ONLY the compose_tools call scoped.
CREATE OR REPLACE FUNCTION stewards.dry_run_chat(p_agent_family text, p_model text, p_session_id text, p_user_input text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
    DECLARE
        v_agent stewards.agents;
        v_body  jsonb;
    BEGIN
        v_agent := stewards.resolve_agent(p_agent_family, p_model);
        IF v_agent.family IS NULL THEN
            RAISE EXCEPTION
                'no agent variant resolved: family=% model=%',
                p_agent_family, p_model;
        END IF;

        v_body := jsonb_build_object(
            'model', coalesce(v_agent.model_pin, p_model),
            'messages', stewards.compose_messages(
                p_agent_family, p_model, p_session_id, p_user_input),
            -- 37: scope the tool list to the dispatch stage''s tool_groups (NULL = full set)
            'tools', stewards.compose_tools_scoped(p_agent_family, stewards.session_tool_scope(p_session_id))
        );
        IF v_agent.temperature IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('temperature', v_agent.temperature);
        END IF;
        IF v_agent.top_p IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('top_p', v_agent.top_p);
        IF v_agent.response_format IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('response_format', v_agent.response_format);
        END IF;
        END IF;

        RETURN v_body || jsonb_build_object(
            '_meta', jsonb_build_object(
                'agent_family', p_agent_family,
                'agent_variant_match', v_agent.model_match,
                'requested_model', p_model,
                'pinned_model', v_agent.model_pin,
                'session_id', p_session_id
            )
        );
    END;
    $function$;

-- =====================================================================
-- End of 37-tool-groups.sql
-- =====================================================================
