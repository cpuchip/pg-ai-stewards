-- =====================================================================
-- v67-max-tokens.sql: every chat round carries a max_tokens.
--
-- Only work_item_dispatch_stage set body.max_tokens (from the item's input or
-- the stage). chat_post_internal, which builds every later round of a tool loop
-- and every bare session turn (dispatch_chat_turn), rebuilt the body through
-- dry_run_chat without one, and the anthropic translator then sent a fixed 4096.
-- The Claude 5.5 models think by default and bill thinking against max_tokens:
-- a bare session turn on Haiku 5.5 (2026-10-10) spent all 4096 on thinking and
-- returned empty content with finish_reason length.
--
-- chat_post_internal now takes, in order: the body's own max_tokens (a _sampling
-- override), the session's previous round's, or for an anthropic-format model its
-- model_capability.max_output_tokens (new column, nullable) capped at 32768. It
-- records which one in payload.max_tokens_source. With none of these the
-- translator's default applies, raised from 4096 to 16384. cost_events.notes
-- records the max_tokens sent and its source.
-- =====================================================================

ALTER TABLE stewards.model_capability ADD COLUMN IF NOT EXISTS max_output_tokens int;
ALTER TABLE stewards.model_capability DROP CONSTRAINT IF EXISTS model_capability_max_output_tokens_check;
ALTER TABLE stewards.model_capability ADD CONSTRAINT model_capability_max_output_tokens_check
    CHECK (max_output_tokens IS NULL OR max_output_tokens > 0);

COMMENT ON COLUMN stewards.model_capability.max_output_tokens IS
'v67: the model''s maximum output tokens on the synchronous API, from its provider''s documentation. For an
anthropic-format model, a chat round with no max_tokens of its own and none to carry sends least(this, 32768).
NULL = unknown (the translator''s default, 16384, applies).';

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
    -- REST (80)
    v_rest_every            int;
    v_is_rest               boolean := false;
    v_rest_tools            jsonb;
    v_last_rested           int;
    -- v67
    v_mt_source             text;
    v_prev_mt               jsonb;
    v_cap                   int;
BEGIN
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
    v_already_soft_notified := COALESCE((v_inherited_markers ->> '_soft_cap_notified')::boolean, false);

    IF v_pipeline_family IS NOT NULL AND v_stage_name IS NOT NULL THEN
        v_soft_cap := COALESCE(stewards.stage_max_tool_rounds(v_pipeline_family, v_stage_name), 5);
        v_hard_cap := COALESCE(stewards.stage_max_tool_rounds_hard(v_pipeline_family, v_stage_name), 50);
        SELECT count(*) INTO v_rounds_so_far FROM stewards.messages
         WHERE session_id = p_session_id AND role = 'assistant';
        IF v_rounds_so_far >= v_hard_cap THEN
            v_force_tools_disabled := true;
        ELSIF v_rounds_so_far >= v_soft_cap AND NOT v_already_soft_notified THEN
            v_inject_soft_notice := true;
        END IF;
    ELSIF stewards.config_get('chat_force_final_enabled', 'true'::jsonb) = 'true'::jsonb THEN
        SELECT a.steps INTO v_agent_steps FROM stewards.agents a
         WHERE a.family = p_agent_family AND stewards.glob_match(a.model_match, p_model)
         ORDER BY length(a.model_match) DESC LIMIT 1;
        IF COALESCE(v_agent_steps, 0) >= 6 THEN
            v_hard_cap   := GREATEST(v_agent_steps - 2, 2);
            v_soft_cap   := GREATEST((v_agent_steps * 0.7)::int, 1);
            v_stage_name := COALESCE(v_stage_name, 'chat');
            SELECT count(*) INTO v_rounds_so_far FROM stewards.messages
             WHERE session_id = p_session_id AND role = 'assistant';
            IF v_rounds_so_far >= v_hard_cap THEN
                v_force_tools_disabled := true;
            ELSIF v_rounds_so_far >= v_soft_cap AND NOT v_already_soft_notified THEN
                v_inject_soft_notice := true;
            END IF;
        END IF;
    END IF;

    -- Make sure we have the round count even when neither cap branch ran above.
    IF v_rounds_so_far IS NULL THEN
        SELECT count(*) INTO v_rounds_so_far FROM stewards.messages
         WHERE session_id = p_session_id AND role = 'assistant';
    END IF;

    -- ---- REST (80): every N rounds, tidy. Force-final wins (don't rest a model
    -- being forced to answer); never rest the same round twice. ----
    -- per-dispatch override (_rest_every marker, propagated) wins over the global config,
    -- so a control run and a treatment run can A/B side by side.
    v_rest_every := COALESCE(
        (v_inherited_markers ->> '_rest_every')::int,
        (stewards.config_get('rest_every_n_steps','0'::jsonb) #>> '{}')::int,
        0);
    v_last_rested := COALESCE((v_inherited_markers ->> '_rested_at_round')::int, -1);
    IF v_rest_every > 0
       AND v_rounds_so_far > 0
       AND (v_rounds_so_far % v_rest_every) = 0
       AND v_rounds_so_far <> v_last_rested
       AND NOT v_force_tools_disabled THEN
        v_is_rest := true;
        v_inject_soft_notice := false;  -- a rest turn carries its own nudge
        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (p_session_id, 'system',
            '[REST] You have taken ' || v_rounds_so_far || ' steps. Pause and tidy before continuing — only your housekeeping tools are available this turn. '
            || 'Review your context and fold away what is spent (compact_context), note your plan and what you have learned so far, prune anything you no longer need, and decide your next concrete step. '
            || 'Do this housekeeping now; your full tools return next turn so you can continue from a lighter, clearer place.',
            p_model);
    END IF;

    IF v_inject_soft_notice
       AND stewards.config_get('soft_cap_notice_enabled', 'true'::jsonb) = 'true'::jsonb THEN
        v_notice_text := stewards.build_soft_cap_notice(v_rounds_so_far, v_soft_cap, v_hard_cap, v_stage_name);
        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (p_session_id, 'system', v_notice_text, p_model);
    END IF;

    v_body := stewards.dry_run_chat(p_agent_family, p_model, p_session_id, NULL, p_provider);
    v_body := v_body - '_meta';

    IF v_force_tools_disabled THEN
        v_body := v_body || jsonb_build_object('tool_choice', 'none');
    END IF;

    -- REST: fold the tools down to the housekeeping set for this one turn.
    IF v_is_rest THEN
        v_rest_tools := stewards.config_get('rest_tools', '[]'::jsonb);
        v_body := jsonb_set(v_body, '{tools}', COALESCE((
            SELECT jsonb_agg(t)
              FROM jsonb_array_elements(COALESCE(v_body->'tools','[]'::jsonb)) t
             WHERE v_rest_tools ? (t->'function'->>'name')
        ), '[]'::jsonb));
    END IF;

    -- SAMPLING (Tier-1 qwen3.6 MoE repetition-loop fix): a per-dispatch _sampling
    -- override merged into the body (the documented fix: presence_penalty=1.5 for the
    -- MoE, temp 0.6 not near-greedy, top_p=0.95, top_k=20, min_p=0). Propagates like the
    -- other markers; A/B-able now, becomes a per-model default config when it proves out.
    IF v_inherited_markers ? '_sampling' AND jsonb_typeof(v_inherited_markers->'_sampling')='object' THEN
        v_body := v_body || (v_inherited_markers->'_sampling');
    END IF;

    -- v67: every round carries a max_tokens. dry_run_chat builds a body without one, and the anthropic
    -- translator otherwise sends a fixed default, which a thinking model can spend entirely on thinking
    -- (a bare session turn on Haiku 5.5, 2026-10-10: 4096 thinking tokens, empty answer). In order: the
    -- body's own (a _sampling override), the session's previous round (so round 2+ of a tool loop keeps
    -- its stage's value), the model's max_output_tokens for an anthropic-format model, at most 32768.
    IF v_body ? 'max_tokens' THEN
        v_mt_source := 'body';
    ELSE
        SELECT payload #> '{body,max_tokens}' INTO v_prev_mt
          FROM stewards.work_queue
         WHERE kind = 'chat' AND payload->>'session_id' = p_session_id
           AND payload #> '{body,max_tokens}' IS NOT NULL
         ORDER BY id DESC
         LIMIT 1;
        IF v_prev_mt IS NOT NULL THEN
            v_body := jsonb_set(v_body, '{max_tokens}', v_prev_mt);
            v_mt_source := 'carried';
        ELSIF stewards.model_api_format(p_provider, p_model) = 'anthropic' THEN
            SELECT max_output_tokens INTO v_cap
              FROM stewards.model_capability
             WHERE provider = p_provider AND model = p_model;
            IF v_cap IS NOT NULL THEN
                v_body := jsonb_set(v_body, '{max_tokens}', to_jsonb(least(v_cap, 32768)));
                v_mt_source := 'model';
            END IF;
        END IF;
    END IF;

    v_payload := jsonb_build_object(
        'session_id', p_session_id, 'agent_family', p_agent_family,
        'requested_model', p_model, 'body', v_body);

    -- v67: where max_tokens came from, for cost_events.notes (no leading underscore: not inherited).
    IF v_mt_source IS NOT NULL THEN
        v_payload := v_payload || jsonb_build_object('max_tokens_source', v_mt_source);
    END IF;

    IF v_force_tools_disabled THEN
        v_payload := v_payload || jsonb_build_object('tools_disabled', true);
    END IF;
    IF v_inject_soft_notice THEN
        v_payload := v_payload || jsonb_build_object('_soft_cap_notified', true, '_soft_cap_injected_at_round', v_rounds_so_far);
    END IF;
    IF v_is_rest THEN
        v_payload := v_payload || jsonb_build_object('_rested_at_round', v_rounds_so_far);
    END IF;

    IF v_inherited_markers IS NOT NULL THEN
        v_payload := (v_inherited_markers - '_soft_cap_notified' - '_soft_cap_injected_at_round' - '_rested_at_round') || v_payload;
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat', p_provider, v_payload, 'pending')
    RETURNING id INTO v_work_id;
    RETURN v_work_id;
END;
$FN$;

COMMENT ON FUNCTION stewards.chat_post_internal(text, text, text, text) IS
'80 (re-authors 67): per-round continuation enqueue with two-tier force-final caps PLUS the REST — every rest_every_n_steps assistant rounds (config, default 0=off), fold tools to the rest_tools housekeeping set and inject a [REST] tidy-up nudge so the model reviews context, compacts, re-plans, then continues with full tools. Force-final near the cap takes precedence over a rest. A/B-able against the spiral oracle. v67: every round carries a max_tokens (the body''s own, the session''s previous round''s, or the model''s max_output_tokens capped at 32768 for anthropic format), recorded in payload.max_tokens_source.';
