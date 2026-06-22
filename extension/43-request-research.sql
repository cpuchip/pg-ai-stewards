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
