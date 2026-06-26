-- =====================================================================
-- 67-rigor-force-final.sql — force-final-at-cap for the INTERACTIVE chat loop
-- =====================================================================
-- The durable fix behind the rigor-v2 cap raise (45: work-item-chat steps 12→40).
-- Raising the ceiling only makes the silent death RARER; this removes it.
--
-- The failure (found vetting rigor v2 on a real bucket): an interactive chat
-- (work-item-chat) burns its whole tool-loop budget gathering — rigor mode
-- re-reads every cited source, and a big corpus paginates each read — then the
-- bridge hits agent.steps and STOPS with no final answer. The user sees the chat
-- die mid-thought.
--
-- chat_post_internal ALREADY solves this for PIPELINE stages: a couple rounds
-- before the cap it drops tools (tools_disabled + tool_choice=none), so the model
-- MUST synthesize what it has. But that grace was gated to pipelines
-- (_pipeline_family + _stage_name). An interactive chat carries neither, so it
-- fell through to the raw steps cap with no force-final.
--
-- This re-authors chat_post_internal (later-file-wins over 15b's l32 final) to add
-- an ELSE branch: for an interactive chat, derive the caps from the agent's own
-- `steps` (the bridge's bound) — force-final two rounds before it, with a wrap-up
-- nudge earlier — and reuse the exact same machinery (build_soft_cap_notice +
-- v_force_tools_disabled). Strictly an improvement: a (possibly partial but real)
-- grounded answer instead of a dead chat. Gated by config 'chat_force_final_enabled'
-- (default true) as an escape hatch.
--
-- requires create_rigor_verify (66). Generic core.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.chat_post_internal(
    p_agent_family text,
    p_model        text,
    p_session_id   text,
    p_provider     text
) RETURNS bigint LANGUAGE plpgsql AS $FN$
DECLARE
    v_body                  jsonb;
    v_payload               jsonb;
    v_work_id               bigint;
    v_inherited_markers     jsonb;
    v_stage_name            text;
    v_pipeline_family       text;
    v_soft_cap              int;
    v_hard_cap              int;
    v_rounds_so_far         int;
    v_agent_steps           int;
    v_force_tools_disabled  boolean := false;
    v_inject_soft_notice    boolean := false;
    v_already_soft_notified boolean := false;
    v_notice_text           text;
BEGIN
    -- Pull inherited markers FIRST so we can use them for cap lookup
    -- BEFORE composing the body.
    SELECT jsonb_object_agg(je.key, je.value)
      INTO v_inherited_markers
      FROM stewards.work_queue wq
      CROSS JOIN LATERAL jsonb_each(wq.payload) je
     WHERE wq.payload->>'session_id' = p_session_id
       AND wq.kind = 'chat'
       AND wq.id = (
           SELECT max(id) FROM stewards.work_queue
            WHERE payload->>'session_id' = p_session_id
              AND kind = 'chat'
       )
       AND je.key LIKE '\_%' ESCAPE '\';

    v_pipeline_family := v_inherited_markers ->> '_pipeline_family';
    v_stage_name      := v_inherited_markers ->> '_stage_name';

    v_already_soft_notified := COALESCE(
        (v_inherited_markers ->> '_soft_cap_notified')::boolean, false);

    IF v_pipeline_family IS NOT NULL AND v_stage_name IS NOT NULL THEN
        -- PIPELINE stage: per-stage soft/hard caps (unchanged — l32).
        v_soft_cap := COALESCE(
            stewards.stage_max_tool_rounds(v_pipeline_family, v_stage_name),
            5
        );
        v_hard_cap := COALESCE(
            stewards.stage_max_tool_rounds_hard(v_pipeline_family, v_stage_name),
            50
        );

        SELECT count(*) INTO v_rounds_so_far
          FROM stewards.messages
         WHERE session_id = p_session_id
           AND role = 'assistant';

        IF v_rounds_so_far >= v_hard_cap THEN
            v_force_tools_disabled := true;
            RAISE NOTICE 'chat_post_internal: session=% rounds=%/HARD-cap-% — forcing tools_disabled+tool_choice=none',
                p_session_id, v_rounds_so_far, v_hard_cap;
        ELSIF v_rounds_so_far >= v_soft_cap AND NOT v_already_soft_notified THEN
            v_inject_soft_notice := true;
            RAISE NOTICE 'chat_post_internal: session=% rounds=%/soft-cap-% — injecting STEWARD NOTICE',
                p_session_id, v_rounds_so_far, v_soft_cap;
        END IF;
    ELSIF stewards.config_get('chat_force_final_enabled', 'true'::jsonb) = 'true'::jsonb THEN
        -- INTERACTIVE chat (no pipeline stage — e.g. work-item-chat). The bridge
        -- bounds the loop at the agent's `steps` and then STOPS with no final
        -- answer (the silent death rigor mode surfaced). Give it the same grace,
        -- derived from the agent's own budget: force-final two rounds before the
        -- bridge stop, with a wrap-up nudge earlier. Only worth it for agents with
        -- a real tool budget (>= 6); tiny-budget agents fall through unchanged.
        SELECT a.steps INTO v_agent_steps
          FROM stewards.agents a
         WHERE a.family = p_agent_family
           AND stewards.glob_match(a.model_match, p_model)
         ORDER BY length(a.model_match) DESC
         LIMIT 1;

        IF COALESCE(v_agent_steps, 0) >= 6 THEN
            v_hard_cap   := GREATEST(v_agent_steps - 2, 2);          -- force-final before the bridge cuts it off
            v_soft_cap   := GREATEST((v_agent_steps * 0.7)::int, 1); -- wrap-up nudge earlier
            v_stage_name := COALESCE(v_stage_name, 'chat');          -- label for the notice text

            SELECT count(*) INTO v_rounds_so_far
              FROM stewards.messages
             WHERE session_id = p_session_id
               AND role = 'assistant';

            IF v_rounds_so_far >= v_hard_cap THEN
                v_force_tools_disabled := true;
                RAISE NOTICE 'chat_post_internal: session=% rounds=%/HARD-cap-% (interactive) — forcing tools_disabled+tool_choice=none',
                    p_session_id, v_rounds_so_far, v_hard_cap;
            ELSIF v_rounds_so_far >= v_soft_cap AND NOT v_already_soft_notified THEN
                v_inject_soft_notice := true;
                RAISE NOTICE 'chat_post_internal: session=% rounds=%/soft-cap-% (interactive) — injecting STEWARD NOTICE',
                    p_session_id, v_rounds_so_far, v_soft_cap;
            END IF;
        END IF;
    END IF;

    -- Soft-cap notice is globally gateable (config 'soft_cap_notice_enabled',
    -- default true). compose_messages now relabels it to 'user' at render so it
    -- no longer breaks strict templates; this flag turns it off entirely.
    IF v_inject_soft_notice
       AND stewards.config_get('soft_cap_notice_enabled', 'true'::jsonb) = 'true'::jsonb THEN
        v_notice_text := stewards.build_soft_cap_notice(
            v_rounds_so_far, v_soft_cap, v_hard_cap, v_stage_name);
        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (p_session_id, 'system', v_notice_text, p_model);
    END IF;

    v_body := stewards.dry_run_chat(p_agent_family, p_model, p_session_id, NULL, p_provider);
    v_body := v_body - '_meta';

    IF v_force_tools_disabled THEN
        v_body := v_body || jsonb_build_object('tool_choice', 'none');
    END IF;

    v_payload := jsonb_build_object(
        'session_id',      p_session_id,
        'agent_family',    p_agent_family,
        'requested_model', p_model,
        'body',            v_body
    );

    IF v_force_tools_disabled THEN
        v_payload := v_payload || jsonb_build_object('tools_disabled', true);
    END IF;

    IF v_inject_soft_notice THEN
        v_payload := v_payload || jsonb_build_object(
            '_soft_cap_notified', true,
            '_soft_cap_injected_at_round', v_rounds_so_far
        );
    END IF;

    IF v_inherited_markers IS NOT NULL THEN
        v_payload := (v_inherited_markers - '_soft_cap_notified' - '_soft_cap_injected_at_round') || v_payload;
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat', p_provider, v_payload, 'pending')
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$FN$;

COMMENT ON FUNCTION stewards.chat_post_internal(text, text, text, text) IS
'67 (re-authors 15b l32): enqueue a continuation chat with two-tier tool-round caps. PIPELINE stages use per-stage soft/hard caps; INTERACTIVE chats (no _pipeline_family) derive caps from the agent''s own steps (force-final at steps-2, wrap-up nudge at 0.7×) so a chat that exhausts its budget is FORCED to synthesize an answer instead of dying silently at the bridge''s steps cap. Soft cap injects a [STEWARD NOTICE] (tools stay — Judges principle); hard cap forces tools_disabled+tool_choice=none. Interactive force-final gated by config chat_force_final_enabled (default true).';

-- =====================================================================
-- End of 67-rigor-force-final.sql
-- =====================================================================
