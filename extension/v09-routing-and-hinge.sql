-- ===== [was 37-tool-groups.sql] =====
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
           'result_read','result_search','fetch_url','fetch_urls','yt_get']),
  -- Narrow, single-finalize groups so a PUBLISHING stage sees exactly ONE finalize tool.
  -- The broad doc-build group above bundles every finalize tool together, which lets a
  -- local model on a book/playlist critique stage reach for the generic doc_finalize
  -- instead of the domain book_publish_draft. doc_finalize pools a digest-<slug> doc but
  -- does NOT run the domain boundary (mark the book/video done), so the item gets
  -- re-digested → a duplicate doc. doc-edit (no finalize) + exactly one *-finalize group
  -- per publishing stage makes the misroute structurally impossible.
  ('doc-edit', 'build/patch a draft document (NO finalize) + the page-in readers',
     ARRAY['doc_create','doc_append_section','doc_patch','doc_read','doc_current',
           'result_read','result_search']),
  ('book-finalize',     'the one finalize tool for the book-digest publishing stage',     ARRAY['book_publish_draft']),
  ('playlist-finalize', 'the one finalize tool for the playlist-digest publishing stage', ARRAY['playlist_publish_draft']),
  ('research-finalize', 'the one finalize tool for the research doc-construction publishing stage', ARRAY['doc_finalize'])
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
-- ===== [was 38-edge-vocabulary.sql] =====
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
-- ===== [was 39-hinge.sql] =====
-- =====================================================================
-- 39-hinge.sql — the Hinge review queue (Phase H of the self-tending memory).
-- =====================================================================
-- Gated decisions (an RTE skill-rule, a graph reorg, a cutover) need a Hinge. Michael
-- is the ultimate Hinge, but a curated `claude -p` reviewer (scripts/hinge-review) tiers
-- UNDER him: it reviews each item against the covenant + the gate's criteria and returns
-- a verdict; the SUBSTRATE applies what's approved (judges, not executors). This is the
-- queue + the bounds. D&C 121: the reviewer holds DELEGATED dominion within bounds Michael
-- grants in council; outside them, it ESCALATES to the human — enforced HERE, not in the
-- prompt, so a generous reviewer can never exceed its grant.
-- requires create_edge_vocabulary (38).
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.hinge_reviews (
    id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind          text NOT NULL,                 -- e.g. 'digest-skill-rule', 'graph-reorg', 'cutover'
    subject       text NOT NULL,                 -- one-line what-is-this
    payload       jsonb NOT NULL DEFAULT '{}'::jsonb,  -- the full proposal the reviewer reads
    status        text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','revise','escalated','applied','declined')),
    verdict       text,                          -- the reviewer's raw verdict (approve|revise|escalate)
    reason        text,                          -- the reviewer's reasoning
    reviewed_by   text,                          -- 'claude-hinge' | 'michael'
    proposer      text,                          -- who enqueued it (the RTE, a tending loop, …)
    created_at    timestamptz NOT NULL DEFAULT now(),
    reviewed_at   timestamptz,
    applied_at    timestamptz
);
COMMENT ON TABLE stewards.hinge_reviews IS
'39: the Hinge review queue. Proposers enqueue (hinge_enqueue); the claude -p reviewer (or Michael) records a verdict (hinge_record_verdict), which ENFORCES the bounds (config hinge_auto_approve_kinds / hinge_escalate_always_kinds) so a verdict can never exceed the reviewer''s delegated grant. The substrate applies status=approved items; status=escalated waits for Michael.';

CREATE INDEX IF NOT EXISTS hinge_reviews_status_idx ON stewards.hinge_reviews (status, created_at);

-- Bounds defaults: NOTHING auto-approves until Michael grants a kind in council; the
-- structural kinds ALWAYS escalate to the human regardless of the reviewer's verdict.
INSERT INTO stewards.config (key, value, description) VALUES
  ('hinge_auto_approve_kinds', '[]'::jsonb,
   'review kinds the claude -p Hinge may auto-approve within bounds; default none until granted in council'),
  ('hinge_escalate_always_kinds', '["cutover","new-pipeline","new-capability","spend-increase","schedule-change"]'::jsonb,
   'review kinds that ALWAYS escalate to Michael regardless of the reviewer verdict (D&C 121 — standing-behavior changes are the human''s)')
ON CONFLICT (key) DO NOTHING;

-- ── hinge_enqueue — a proposer asks for review.
CREATE OR REPLACE FUNCTION stewards.hinge_enqueue(
    p_kind text, p_subject text, p_payload jsonb DEFAULT '{}'::jsonb, p_proposer text DEFAULT NULL
) RETURNS bigint LANGUAGE sql AS $fn$
    INSERT INTO stewards.hinge_reviews (kind, subject, payload, proposer)
    VALUES (p_kind, p_subject, COALESCE(p_payload,'{}'::jsonb), p_proposer)
    RETURNING id;
$fn$;

-- ── hinge_pending — the reviewer's worklist (oldest first).
CREATE OR REPLACE FUNCTION stewards.hinge_pending(p_limit int DEFAULT 20)
RETURNS TABLE (id bigint, kind text, subject text, payload jsonb, created_at timestamptz)
LANGUAGE sql STABLE AS $fn$
    SELECT id, kind, subject, payload, created_at
      FROM stewards.hinge_reviews WHERE status = 'pending'
     ORDER BY created_at ASC LIMIT p_limit;
$fn$;

-- ── hinge_record_verdict — the reviewer (or Michael) records a verdict; BOUNDS ENFORCED.
--    A verdict of 'approve' only sticks as approved if the kind is in
--    hinge_auto_approve_kinds AND not in hinge_escalate_always_kinds; otherwise it is
--    escalated to the human. This is the wall around the reviewer's delegated dominion.
CREATE OR REPLACE FUNCTION stewards.hinge_record_verdict(
    p_id bigint, p_verdict text, p_reason text DEFAULT NULL, p_reviewer text DEFAULT 'claude-hinge'
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_row     stewards.hinge_reviews%ROWTYPE;
    v_v       text := lower(btrim(coalesce(p_verdict,'')));
    v_status  text;
    v_auto    boolean;
    v_force   boolean;
    v_michael boolean := (p_reviewer = 'michael');
BEGIN
    SELECT * INTO v_row FROM stewards.hinge_reviews WHERE id = p_id;
    IF v_row.id IS NULL THEN RETURN jsonb_build_object('ok', false, 'note', 'no such review'); END IF;
    -- Claude reviews PENDING items; Michael can also act on an ESCALATED item (the
    -- claude reviewer escalated it to him, with its recommendation recorded).
    IF v_row.status <> 'pending' AND NOT (v_michael AND v_row.status = 'escalated') THEN
        RETURN jsonb_build_object('ok', false, 'note', 'already ' || v_row.status);
    END IF;

    v_force := (v_row.kind = ANY (SELECT jsonb_array_elements_text(stewards.config_get('hinge_escalate_always_kinds'))));
    v_auto  := (v_row.kind = ANY (SELECT jsonb_array_elements_text(stewards.config_get('hinge_auto_approve_kinds'))));

    IF v_v IN ('approve','approved') THEN
        -- Michael's approval is final; the claude reviewer's approval must be in-bounds.
        IF v_michael OR (v_auto AND NOT v_force) THEN
            v_status := 'approved';
        ELSE
            v_status := 'escalated';      -- approved out of bounds → the human decides
        END IF;
    ELSIF v_v IN ('revise','revision') THEN
        v_status := 'revise';
    ELSIF v_v IN ('decline','declined','reject') THEN
        v_status := 'declined';
    ELSE
        v_status := 'escalated';
    END IF;

    UPDATE stewards.hinge_reviews
       SET status = v_status, verdict = v_v, reason = p_reason,
           reviewed_by = p_reviewer, reviewed_at = now()
     WHERE id = p_id;

    RETURN jsonb_build_object('ok', true, 'id', p_id, 'verdict', v_v, 'status', v_status,
        'in_bounds', (v_auto AND NOT v_force), 'escalate_always', v_force,
        'note', CASE WHEN v_status='escalated' AND NOT v_michael
                     THEN 'escalated to Michael — outside the reviewer''s grant' ELSE v_status END);
END;
$fn$;

-- ── hinge_status — a glance at the queue.
CREATE OR REPLACE FUNCTION stewards.hinge_status()
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_object_agg(status, n), '{}'::jsonb)
      FROM (SELECT status, count(*) n FROM stewards.hinge_reviews GROUP BY status) x;
$fn$;

-- ── hinge_gate_status — the substrate DRIVES the host Hinge daemon. The daemon polls this
--    each tick and obeys it: it runs the reviewer only when should_run is true, sleeps for
--    interval_seconds, and — critically — STOPS when the substrate is paused (autonomy_paused,
--    the same emergency stop the watchman trips). One switch (the pause) halts the source,
--    the digesters, AND the gate. The cadence lives in config too, so pg-ai-stewards owns the
--    schedule, not the host.
CREATE OR REPLACE FUNCTION stewards.hinge_gate_status()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_paused   bool := stewards.config_get_text('autonomy_paused','false') = 'true';
    v_pending  int  := (SELECT count(*) FROM stewards.hinge_reviews WHERE status = 'pending');
    v_interval int  := coalesce(nullif(stewards.config_get_text('hinge_daemon_interval_seconds',''),'')::int, 300);
BEGIN
    RETURN jsonb_build_object(
        'should_run',       (v_pending > 0 AND NOT v_paused),
        'pending',          v_pending,
        'paused',           v_paused,
        'paused_reason',    CASE WHEN v_paused THEN 'autonomy_paused (emergency stop) — Hinge daemon holds' ELSE NULL END,
        'interval_seconds', v_interval);
END;
$fn$;
COMMENT ON FUNCTION stewards.hinge_gate_status() IS
'39: the substrate-driven contract for the host Hinge daemon. should_run = pending>0 AND NOT autonomy_paused; interval_seconds from config (hinge_daemon_interval_seconds, default 300). The daemon obeys this, so the global emergency stop pauses the gate along with everything else.';

INSERT INTO stewards.config (key, value, description) VALUES
  ('hinge_daemon_interval_seconds', '300'::jsonb,
   'How often (seconds) the host Hinge daemon polls hinge_gate_status. The substrate owns the Hinge cadence.')
ON CONFLICT (key) DO NOTHING;

-- =====================================================================
-- End of 39-hinge.sql
-- =====================================================================
-- ===== [was 40-rte.sql] =====
-- =====================================================================
-- 40-rte.sql — the Reflective Tuning Engine (Phase G of the self-tending memory).
-- =====================================================================
-- An oracle is not just a gate — it is a GRADIENT SIGNAL the substrate can improve
-- itself against ("textual gradient descent" / loop engineering, from the Homer +
-- Microsoft-agent-skills digests in our own pool). The quote oracle marks digests
-- passed/flagged; the RTE reads the FLAGGED quotes beside the PASSED ones, diagnoses the
-- delta, and proposes a refined quote-skill rule — gated through the Hinge (39), then
-- auto-applied. The digester reads the active rules and quotes better; the oracle
-- re-scores; the flag rate is the measurable outcome. The capstone of "build the oracle
-- first": every checker becomes an engine of improvement. requires create_hinge (39).
-- =====================================================================

-- ── the per-quote failure signal (the oracle --mark writes these) ────
CREATE TABLE IF NOT EXISTS stewards.quote_flags (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_slug    text NOT NULL,
    quote       text NOT NULL,
    score       real,                          -- the oracle's match ratio (0..1)
    source_kind text,                          -- 'book' | 'video'
    flagged_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS quote_flags_recent_idx ON stewards.quote_flags (flagged_at DESC);
COMMENT ON TABLE stewards.quote_flags IS
'40: one row per quote the quote oracle flagged (not verbatim). The RTE''s raw gradient signal — it diagnoses why these failed vs what the passed digests did right.';

-- ── the learned rules (the gradient, applied) ───────────────────────
CREATE TABLE IF NOT EXISTS stewards.digest_skill_rules (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_text    text NOT NULL,
    grounded_in  text,                          -- what evidence prompted it
    status       text NOT NULL DEFAULT 'proposed'
                   CHECK (status IN ('proposed','active','retired')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    activated_at timestamptz
);
COMMENT ON TABLE stewards.digest_skill_rules IS
'40: quote-discipline rules the RTE learned from flagged digests. A rule is proposed -> (Hinge approves) -> active. The digester reads active rules via quote_rules and follows them.';

-- ── quote_rules — the active rules the digester consults before quoting.
CREATE OR REPLACE FUNCTION stewards.quote_rules_tool(p_args jsonb)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(
        string_agg('- ' || rule_text, E'\n' ORDER BY activated_at),
        'No learned rules yet — quote verbatim or do not use quotation marks.')
      FROM stewards.digest_skill_rules WHERE status = 'active';
$fn$;

-- ── rte_quote_contrast — the gradient signal for the diagnoser: recent flagged quotes
--    (the failures) + the pass/flag rate (so it can see the trend it must move).
CREATE OR REPLACE FUNCTION stewards.rte_quote_contrast_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_limit    int := coalesce((p_args->>'limit')::int, 30);
    v_flags    jsonb;
    v_rate     jsonb;
    v_feedback jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('doc', doc_slug, 'quote', left(quote,200), 'score', score)
                     ORDER BY flagged_at DESC)
      INTO v_flags FROM (SELECT * FROM stewards.quote_flags ORDER BY flagged_at DESC LIMIT v_limit) f;
    SELECT jsonb_object_agg(qc, n) INTO v_rate FROM (
        SELECT coalesce(frontmatter->>'quote_check','unmarked') qc, count(*) n FROM stewards.docs GROUP BY 1) y;
    -- prior rules the Hinge sent back, with WHY — so the diagnoser learns from the gate
    -- (do not re-propose a revised/declined rule; address the feedback instead).
    SELECT jsonb_agg(jsonb_build_object('proposed_rule', payload->>'rule',
                                        'hinge_verdict', status, 'hinge_reason', reason) ORDER BY reviewed_at DESC)
      INTO v_feedback FROM stewards.hinge_reviews
     WHERE kind = 'digest-skill-rule' AND status IN ('revise','declined')
       AND reviewed_at > now() - interval '14 days';
    RETURN jsonb_build_object('flagged_quotes', coalesce(v_flags,'[]'::jsonb),
                              'corpus_quote_check', coalesce(v_rate,'{}'::jsonb),
                              'active_rules', stewards.quote_rules_tool('{}'::jsonb),
                              'prior_hinge_feedback', coalesce(v_feedback,'[]'::jsonb))::text;
END;
$fn$;

-- ── rte_enqueue_quote_rule — the diagnoser proposes a rule → a proposed row + a Hinge
--    review (kind digest-skill-rule). On Hinge approval the trigger below activates it.
CREATE OR REPLACE FUNCTION stewards.rte_enqueue_quote_rule(p_rule text, p_grounding text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_rid bigint; v_hid bigint;
BEGIN
    IF coalesce(btrim(p_rule),'') = '' THEN RETURN jsonb_build_object('ok', false, 'note', 'empty rule'); END IF;
    INSERT INTO stewards.digest_skill_rules (rule_text, grounded_in) VALUES (p_rule, p_grounding) RETURNING id INTO v_rid;
    v_hid := stewards.hinge_enqueue('digest-skill-rule',
                left('Quote-skill rule: ' || p_rule, 200),
                jsonb_build_object('rule_id', v_rid, 'rule', p_rule, 'grounded_in', p_grounding),
                'rte');
    RETURN jsonb_build_object('ok', true, 'rule_id', v_rid, 'hinge_id', v_hid,
        'note', 'proposed + queued for the Hinge — it activates on approval');
END;
$fn$;
CREATE OR REPLACE FUNCTION stewards.rte_enqueue_quote_rule_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $fn$
    SELECT stewards.rte_enqueue_quote_rule(p_args->>'rule', p_args->>'grounding')::text;
$fn$;

-- ── auto-apply: when the Hinge approves a digest-skill-rule, activate the rule.
CREATE OR REPLACE FUNCTION stewards.rte_apply_approved_rule()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.kind = 'digest-skill-rule' AND NEW.status = 'approved'
       AND (OLD.status IS DISTINCT FROM 'approved') THEN
        UPDATE stewards.digest_skill_rules
           SET status = 'active', activated_at = now()
         WHERE id = (NEW.payload->>'rule_id')::bigint AND status = 'proposed';
        UPDATE stewards.hinge_reviews SET status = 'applied', applied_at = now() WHERE id = NEW.id;
    END IF;
    RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS hinge_apply_digest_skill_rule ON stewards.hinge_reviews;
CREATE TRIGGER hinge_apply_digest_skill_rule
AFTER UPDATE OF status ON stewards.hinge_reviews
FOR EACH ROW WHEN (NEW.kind = 'digest-skill-rule' AND NEW.status = 'approved')
EXECUTE FUNCTION stewards.rte_apply_approved_rule();

-- ── tools (the digest-tuning pipeline + the digesters use these) ─────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'quote_rules',
  'Read the verbatim-discipline rules the substrate has LEARNED from past quoting mistakes. Call this before writing quotes and follow the rules.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"quote_rules_tool"}'::jsonb ),
( 'rte_quote_contrast',
  'Get the quote-oracle gradient signal: recent FLAGGED quotes (the failures), the corpus pass/flag counts, and the active rules. Use it to diagnose WHY quotes fail and propose a better rule.',
  '{"type":"object","properties":{"limit":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"rte_quote_contrast_tool"}'::jsonb ),
( 'rte_propose_quote_rule',
  'Propose a refined quote-discipline rule for the digesters (one or two sentences, actionable). It is queued for the Hinge and activates only on approval. Give the grounding (what flagged quotes prompted it).',
  '{"type":"object","required":["rule"],"properties":{"rule":{"type":"string"},"grounding":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"rte_enqueue_quote_rule_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','quote_rules','allow','manual'),
    ('research','rte_quote_contrast','allow','manual'),
    ('research','rte_propose_quote_rule','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ── the digest-tuning pipeline — the RTE's LLM diagnoser (textual gradient descent).
--    Reads the gradient (flagged vs passed), diagnoses the delta, proposes ONE refined
--    rule (Hinge-gated). Scoped to a lean self-tuning tool group. Dispatchable; a
--    disabled daily schedule is seeded for the operator to enable.
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('self-tuning', 'the RTE diagnoser tools', ARRAY['rte_quote_contrast','rte_propose_quote_rule','quote_rules'])
ON CONFLICT (name) DO UPDATE SET tool_patterns = EXCLUDED.tool_patterns;

-- The digest-tuning PIPELINE (the capability) is core; its INTENT + SCHEDULE (when it
-- actually runs) are operator config and live in a workspace overlay (overlays/
-- self-tuning.sql) — core ships with no intents or schedules (virgin-smoke enforces this).
INSERT INTO stewards.pipelines (family, description, stages, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES (
  'digest-tuning',
  'The RTE diagnoser: read the quote-oracle gradient (flagged vs passed), diagnose the delta, propose a refined quote rule (Hinge-gated). Textual gradient descent on the digester skill.',
  jsonb_build_array(jsonb_build_object(
    'name','tune','next', NULL, 'model','critic','agent_family','research',
    'auto_advance', true, 'tools_disabled', false,
    'tool_groups', jsonb_build_array('self-tuning'),
    'input_template',
      'You are the digest-tuning stage — the Reflective Tuning Engine.' || E'\n\n' ||
      '1. Call `rte_quote_contrast` to see recent FLAGGED quotes (the failures), the corpus pass/flag counts, and the rules already active.' || E'\n' ||
      '2. Diagnose the delta: what do the flagged quotes share that the passed digests avoid — fabrication, paraphrase-in-quotes, or wrong attribution?' || E'\n' ||
      '3. Check `prior_hinge_feedback` in the contrast. If the Hinge revised an earlier rule, read WHY and let it sharpen you — do NOT re-propose a revised rule; address the feedback with a better-scoped, better-grounded one.' || E'\n' ||
      '4. If there is ONE clear rule that would reduce these failures, is NOT already active, and is not the thing the Hinge just sent back, call `rte_propose_quote_rule` with a one-sentence actionable rule + the grounding (which flagged quotes prompted it). If the active rules + prior feedback already cover it, propose nothing.' || E'\n' ||
      '5. Reply with a 2-3 sentence journal: what you diagnosed and whether you proposed a rule.'
  )),
  '["raw","verified"]'::jsonb, false, jsonb_build_object('pools_via_tool', true))
ON CONFLICT (family) DO UPDATE SET stages = EXCLUDED.stages, description = EXCLUDED.description, updated_at = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity)
VALUES ('digest-tuning','tune','verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

-- =====================================================================
-- End of 40-rte.sql
-- =====================================================================
-- ===== [was 41-memory-tend.sql] =====
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
-- ===== [was 42-route-on.sql] =====
-- =====================================================================
-- 42-route-on.sql — the route_on primitive (A): data-driven conditional /
-- loop-back stage routing.
-- =====================================================================
-- Re-authors work_item_advance (final form in 20-coder §8) to REPLACE the two
-- hardcoded code-pr loop-backs (cv6 review->implement, cv11 plan_review->plan)
-- with ONE generic, data-driven evaluator. Everything else — load/validate,
-- stage_results recording, the empty-source halt_on, the maturity hook, and the
-- normal forward advance — is preserved verbatim.
--
-- A stage declares routing in its own jsonb:
--   "route_on": [ { when?, unless?, goto, feedback_key?, count_key?, max?,
--                   on_max_goto?, on_max_status?, on_max_reason? } ]
-- Evaluated (in order, first match wins) against the completing stage's text
-- output. A rule FIRES when its `when` regex matches (or is absent) AND its
-- `unless` regex does NOT match (or is absent), case-insensitive.
--   goto = an EARLIER stage  -> loop back     (study workflow: critical -> gather)
--   goto = a  LATER  stage   -> skip forward
--   goto = null              -> halt (cancel)  (generalizes halt_on per-stage)
-- Loop guard: a looping rule should carry { count_key, max } — the counter lives
-- in work_items.input; on reaching max the rule routes to on_max_goto (else sets
-- on_max_status, default awaiting_review). A hard global hop ceiling
-- (route_on_max_hops, default 50) backstops a misconfigured infinite loop.
-- feedback_key (optional) injects the completing stage's output into input under
-- that key (so the looped-to stage sees why it was sent back).
--
-- No route_on, or no rule matches -> fall through to the normal advance.
-- requires: create_memory_tend (41) — tail of the chain; this is a pure
-- re-author of work_item_advance, no new tables.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.work_item_advance(
    p_work_item_id uuid,
    p_stage_output jsonb DEFAULT '{}'::jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_pipeline        stewards.pipelines%ROWTYPE;
    v_stage           jsonb;
    v_next_name       text;
    v_auto_advance    boolean;
    v_results         jsonb;
    v_completing      text;
    v_new_maturity    text;
    v_current_idx     int;
    v_new_idx         int;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;
    IF v_wi.status NOT IN ('in_progress', 'awaiting_review', 'pending') THEN
        RAISE EXCEPTION 'work_item %: cannot advance from status %',
            p_work_item_id, v_wi.status;
    END IF;

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    v_next_name    := v_stage->>'next';
    v_auto_advance := COALESCE((v_stage->>'auto_advance')::bool, true);
    v_completing   := v_wi.current_stage;

    v_results := v_wi.stage_results
              || jsonb_build_object(v_completing,
                     p_stage_output
                     || jsonb_build_object('completed_at', now()));

    -- ----- empty-source halt (digester-empty-source-halt; pipeline-level) -----
    DECLARE
        v_halt jsonb;
    BEGIN
        SELECT metadata->'halt_on' INTO v_halt
          FROM stewards.pipelines WHERE family = v_wi.pipeline_family;
        IF v_halt IS NOT NULL
           AND v_halt->>'stage' = v_completing
           AND (v_halt->'outputs') ? btrim(COALESCE(v_results->v_completing->>'output','')) THEN
            UPDATE stewards.work_items
               SET stage_results       = v_results,
                   status              = 'cancelled',
                   last_failure_reason = format(
                       'empty-source halt: stage "%s" emitted "%s" (pipeline halt_on) — no downstream dispatch, nothing pooled',
                       v_completing, btrim(v_results->v_completing->>'output')),
                   updated_at          = now()
             WHERE id = p_work_item_id;
            RETURN NULL;
        END IF;
    END;

    -- ----- route_on: data-driven conditional / loop-back routing (A) -----
    -- Generalizes the old hardcoded code-pr review->implement (cv6) and
    -- plan_review->plan (cv11) loop-backs. First matching rule wins.
    DECLARE
        v_route    jsonb;
        v_rule     jsonb;
        v_out      text := btrim(COALESCE(v_results->v_completing->>'output',''));
        v_when     text;
        v_unless   text;
        v_goto     text;
        v_count    int;
        v_max      int;
        v_hops     int;
        v_hop_cap  int := COALESCE((SELECT (value#>>'{}')::int FROM stewards.config
                                     WHERE key = 'route_on_max_hops'), 50);
    BEGIN
        v_route := v_stage->'route_on';
        IF v_route IS NOT NULL AND jsonb_typeof(v_route) = 'array' THEN
            FOR v_rule IN SELECT * FROM jsonb_array_elements(v_route) LOOP
                v_when   := v_rule->>'when';
                v_unless := v_rule->>'unless';
                CONTINUE WHEN NOT ((v_when IS NULL OR v_out ~* v_when)
                                   AND (v_unless IS NULL OR v_out !~* v_unless));

                v_goto := v_rule->>'goto';
                v_max  := (v_rule->>'max')::int;          -- NULL if absent
                v_count := CASE WHEN v_rule->>'count_key' IS NOT NULL
                                THEN COALESCE((v_wi.input->>(v_rule->>'count_key'))::int, 0)
                                ELSE 0 END;

                -- capped: stop looping (on_max_goto, else on_max_status)
                IF v_max IS NOT NULL AND v_count >= v_max THEN
                    IF v_rule->>'on_max_goto' IS NOT NULL THEN
                        UPDATE stewards.work_items
                           SET stage_results = v_results,
                               current_stage = v_rule->>'on_max_goto',
                               status        = 'pending',
                               updated_at    = now()
                         WHERE id = p_work_item_id;
                        RETURN v_rule->>'on_max_goto';
                    END IF;
                    UPDATE stewards.work_items
                       SET stage_results     = v_results,
                           status            = COALESCE(v_rule->>'on_max_status','awaiting_review'),
                           quarantine_reason = COALESCE(quarantine_reason, v_rule->>'on_max_reason'),
                           error             = COALESCE(error, v_rule->>'on_max_reason'),
                           updated_at        = now()
                     WHERE id = p_work_item_id;
                    RETURN NULL;
                END IF;

                -- goto null -> halt (per-stage cancel)
                IF v_goto IS NULL THEN
                    UPDATE stewards.work_items
                       SET stage_results       = v_results,
                           status              = 'cancelled',
                           last_failure_reason = COALESCE(v_rule->>'on_max_reason',
                               format('route_on halt: stage "%s" matched a null-goto rule', v_completing)),
                           updated_at          = now()
                     WHERE id = p_work_item_id;
                    RETURN NULL;
                END IF;

                -- global infinite-loop backstop (misconfigured uncapped loop)
                v_hops := COALESCE((v_results->'_route_hops'->>v_completing)::int, 0) + 1;
                IF v_hops > v_hop_cap THEN
                    UPDATE stewards.work_items
                       SET stage_results     = v_results,
                           status            = 'awaiting_review',
                           quarantine_reason = COALESCE(quarantine_reason,
                               format('route_on: stage "%s" exceeded %s hops (loop guard)', v_completing, v_hop_cap)),
                           updated_at        = now()
                     WHERE id = p_work_item_id;
                    RETURN NULL;
                END IF;

                -- route (loop back or skip): set goto, inject feedback + counter
                UPDATE stewards.work_items
                   SET stage_results = jsonb_set(v_results, ARRAY['_route_hops', v_completing],
                                                 to_jsonb(v_hops), true),
                       current_stage = v_goto,
                       input         = input
                         || CASE WHEN v_rule->>'feedback_key' IS NOT NULL
                                 THEN jsonb_build_object(v_rule->>'feedback_key', v_out)
                                 ELSE '{}'::jsonb END
                         || CASE WHEN v_rule->>'count_key' IS NOT NULL
                                 THEN jsonb_build_object(v_rule->>'count_key', v_count + 1)
                                 ELSE '{}'::jsonb END,
                       status        = 'pending',
                       updated_at    = now()
                 WHERE id = p_work_item_id;
                RETURN v_goto;
            END LOOP;
        END IF;
    END;

    -- ----- maturity advance hook (forward-only) -----
    SELECT produces_maturity INTO v_new_maturity
      FROM stewards.pipeline_stage_maturity
     WHERE pipeline_family = v_wi.pipeline_family
       AND stage_name      = v_completing;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    IF v_new_maturity IS NOT NULL AND v_pipeline.maturity_ladder IS NOT NULL THEN
        SELECT pos - 1 INTO v_current_idx
          FROM jsonb_array_elements_text(v_pipeline.maturity_ladder)
          WITH ORDINALITY AS t(rung, pos)
         WHERE rung = COALESCE(v_wi.maturity, 'raw');

        SELECT pos - 1 INTO v_new_idx
          FROM jsonb_array_elements_text(v_pipeline.maturity_ladder)
          WITH ORDINALITY AS t(rung, pos)
         WHERE rung = v_new_maturity;

        IF v_current_idx IS NOT NULL AND v_new_idx IS NOT NULL AND v_new_idx > v_current_idx THEN
            NULL;
        ELSE
            v_new_maturity := NULL;
        END IF;
    END IF;

    IF v_next_name IS NULL OR v_next_name = '' THEN
        UPDATE stewards.work_items
           SET stage_results = v_results,
               status        = 'completed',
               completed_at  = now(),
               maturity      = COALESCE(v_new_maturity, maturity),
               updated_at    = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    IF stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_next_name) IS NULL THEN
        RAISE EXCEPTION
            'work_item %: stage %s `next` references missing stage %',
            p_work_item_id, v_completing, v_next_name;
    END IF;

    UPDATE stewards.work_items
       SET stage_results = v_results,
           current_stage = v_next_name,
           status        = CASE WHEN v_auto_advance THEN 'pending'
                                ELSE 'awaiting_review' END,
           maturity      = COALESCE(v_new_maturity, maturity),
           updated_at    = now()
     WHERE id = p_work_item_id;

    RETURN v_next_name;
END;
$func$;

-- ----- migrate code-pr off the retired hardcoded loop-backs to route_on data -----
-- review: loop to implement UNLESS the verdict line says "REVIEW: passes"; cap 2,
--   then awaiting_review (cv6). plan_review: loop to plan UNLESS "PLAN: approved";
--   cap 2, then proceed to implement (cv11). The dispatch-stage critic-immunity
--   branch (cv7/cv10) in 20-coder §9 is untouched.
UPDATE stewards.pipelines p SET stages = (
    SELECT jsonb_agg(
        CASE
            WHEN elem->>'name' = 'review' THEN elem || jsonb_build_object('route_on', jsonb_build_array(
                jsonb_build_object(
                    'unless', '(^|\n)\s*REVIEW:\s*passes',
                    'goto', 'implement',
                    'feedback_key', 'review_feedback',
                    'count_key', 'revise_count',
                    'max', 2,
                    'on_max_status', 'awaiting_review',
                    'on_max_reason', 'critic review deficient after revise cap; needs a human')))
            WHEN elem->>'name' = 'plan_review' THEN elem || jsonb_build_object('route_on', jsonb_build_array(
                jsonb_build_object(
                    'unless', '(^|\n)\s*PLAN:\s*approved',
                    'goto', 'plan',
                    'feedback_key', 'plan_feedback',
                    'count_key', 'plan_revise_count',
                    'max', 2,
                    'on_max_goto', 'implement')))
            ELSE elem
        END ORDER BY ord)
    FROM jsonb_array_elements(p.stages) WITH ORDINALITY AS t(elem, ord))
WHERE p.family = 'code-pr';

-- =====================================================================
-- End of 42-route-on.sql
-- =====================================================================
-- ===== [was 43-request-research.sql] =====
-- =====================================================================
-- 43-request-research.sql — request_research + the gather-feedback loop (primitive B).
-- =====================================================================
-- The analyze->gather feedback loop, as core: when a stage (or a pool-reading persona)
-- cannot answer from the knowledge pool, it queues a *targeted* research request as a
-- PROPOSAL for the intent — origin='agent_planning', pending — in the same queue the
-- reflect-steward uses. The human approves it; the capacity-gated drain works it in the
-- background; the finding publishes to the pool (on_maturity_verified) so the next cycle
-- is better-informed. It adds NO new unsupervised autonomy (human stays the Hinge; the
-- watchman guard already covers the queue).
--
-- This is the tool-side dual of route_on (42): route_on loops a stage back WITHIN one
-- run; request_research feeds the POOL so a LATER cycle is better-informed. A stage opts
-- into the loop by declaring the gather-feedback tool_group (defined below) — typically
-- paired with substrate-read/web-research so it surveys the pool before requesting only
-- the genuine gap (the Council-Moment survey).
-- requires create_route_on (42, tail of the chain) + work-items/pipelines (04) +
-- tool-groups (37) + the reflect-steward queue (22).
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.request_research_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess     text := p_args->>'_session_id';
    v_question text := btrim(COALESCE(p_args->>'question',''));
    v_project  text := btrim(COALESCE(p_args->>'project',''));
    v_intent   uuid;
    v_intent_slug text;
    v_dupe     int;
    v_id       uuid;
    v_slug     text;
BEGIN
    IF v_question = '' THEN RETURN '{"error":"question is required"}'; END IF;

    -- Resolve the intent: prefer the caller's session project tag, else the
    -- explicitly-passed project (a dedicated persona/stage knows its own domain).
    IF v_project = '' THEN
        SELECT w.project_association INTO v_project
          FROM stewards.work_items w WHERE v_sess = ANY(w.session_ids)
         ORDER BY w.id DESC LIMIT 1;
    END IF;
    IF COALESCE(v_project,'') = '' THEN
        RETURN '{"error":"could not resolve a project/intent; pass project explicitly (your domain)"}';
    END IF;
    SELECT id, slug INTO v_intent, v_intent_slug FROM stewards.intents WHERE slug = v_project;
    IF v_intent IS NULL THEN
        RETURN jsonb_build_object('error','no intent matches project '||v_project)::text;
    END IF;

    -- Dedup: don't queue the same question twice (pending OR recently gathered).
    SELECT count(*) INTO v_dupe FROM stewards.work_items
     WHERE intent_id = v_intent AND status = 'pending' AND pipeline_family LIKE 'research%'
       AND lower(input->>'binding_question') = lower(v_question);
    IF v_dupe > 0 THEN
        RETURN jsonb_build_object('ok',true,'note',
            'A matching research request is already queued for '||v_intent_slug||' — not duplicated.')::text;
    END IF;

    -- Park it as a proposal (the human approves; the drain works it; finding -> pool).
    v_slug := 'reqres-'||v_intent_slug||'-'||to_char(now(),'YYYYMMDD-HH24MISS');
    v_id := stewards.work_item_create('research-write',
        jsonb_build_object('binding_question', v_question),
        v_slug, 'persona-request', NULL, v_intent);
    UPDATE stewards.work_items SET origin = 'agent_planning' WHERE id = v_id;

    RETURN jsonb_build_object('ok',true,'queued_as',v_slug,'intent',v_intent_slug,
        'note','Research request queued as a proposal — once approved it is gathered in the background and the finding lands in the pool.')::text;
END $FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'request_research',
  'When the knowledge pool cannot answer a question, queue a research request so the team gathers the missing info in the background (it lands in the pool for next time). Args: question (what to find out — be specific), project (the intent/domain to file it under, e.g. your own domain). It is queued as a proposal for human approval, NOT run immediately. Use it sparingly, for genuine gaps — not for things the pool already covers (search first).',
  '{"type":"object","required":["question"],"properties":{"question":{"type":"string"},"project":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"request_research_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- The analyze/critique family may use it. A stage still has to OPT IN via the
-- gather-feedback tool_group below (or run unscoped); this grant just declares intent.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action)
VALUES ('research','request_research','allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action='allow';

-- ── the gather-feedback tool_group — the opt-in per-stage scope for primitive B.
-- Any critical/analyze stage declares "tool_groups": ["substrate-read","gather-feedback"]
-- to gain the targeted-regather move. Single-purpose by design — it pairs WITH
-- substrate-read/web-research for the "search first, then request only the gap" discipline.
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('gather-feedback',
   'the analyze->gather feedback loop: queue a targeted regather for a genuine pool gap (request_research). Pairs with substrate-read/web-research (survey first). The tool-side dual of route_on.',
   ARRAY['request_research'])
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, tool_patterns=EXCLUDED.tool_patterns;

-- =====================================================================
-- End of 43-request-research.sql
-- =====================================================================
-- ===== [was 44-graph-organize.sql] =====
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
