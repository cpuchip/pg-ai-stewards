-- =====================================================================
-- v71-per-turn-rounds.sql: a chat's tool rounds count per turn, not per session.
--
-- chat_post_internal counted every assistant message in the session against
-- its caps: the pipeline soft and hard caps, the interactive force-final at
-- steps-2 (soft notice at 0.7 x steps), and the REST cadence. A session that
-- lives across many user turns (a long-running chat persona) crossed the hard
-- cap after a handful of turns and from then on every turn went out with
-- tool_choice none: measured on a live instance (2026-10-20), 20 of 47
-- re-asked turns were empty because the model still emitted a tool call that
-- tool_choice none discarded, and 5 more stopped steps_exhausted after a
-- single tool call. The soft-notice and rest markers were read from the
-- previous round whichever turn it belonged to.
--
-- Now every count starts after the session's latest user message, and the
-- markers are read only when they were written under that same message
-- (_cap_turn). A session with no user message counts every round, as before.
-- Within a turn the markers are carried forward once written: v67 dropped them
-- on every round that did not set them, so the soft-cap notice came every
-- other round between the soft and hard caps.
-- The body is v67's with only those sites changed.
-- Oracle: virgin-smoke OK 138; extension/verify-71-per-turn-rounds.sql on a live record.
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
    -- REST (80)
    v_rest_every            int;
    v_is_rest               boolean := false;
    v_rest_tools            jsonb;
    v_last_rested           int;
    -- v67
    v_mt_source             text;
    v_prev_mt               jsonb;
    v_cap                   int;
    -- v71
    v_turn                  bigint;
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

    -- v71: rounds count from the session's latest user message, so a long session's earlier turns
    -- do not spend this one's budget. With no user message the anchor is 0 and every round counts,
    -- as before.
    SELECT COALESCE(max(id), 0) INTO v_turn FROM stewards.messages
     WHERE session_id = p_session_id AND role = 'user';

    v_pipeline_family := v_inherited_markers ->> '_pipeline_family';
    v_stage_name      := v_inherited_markers ->> '_stage_name';
    v_already_soft_notified := COALESCE((v_inherited_markers ->> '_soft_cap_notified')::boolean, false)
        AND COALESCE((v_inherited_markers ->> '_cap_turn')::bigint, -1) = v_turn;

    IF v_pipeline_family IS NOT NULL AND v_stage_name IS NOT NULL THEN
        v_soft_cap := COALESCE(stewards.stage_max_tool_rounds(v_pipeline_family, v_stage_name), 5);
        v_hard_cap := COALESCE(stewards.stage_max_tool_rounds_hard(v_pipeline_family, v_stage_name), 50);
        SELECT count(*) INTO v_rounds_so_far FROM stewards.messages
         WHERE session_id = p_session_id AND role = 'assistant' AND id > v_turn;
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
             WHERE session_id = p_session_id AND role = 'assistant' AND id > v_turn;
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
         WHERE session_id = p_session_id AND role = 'assistant' AND id > v_turn;
    END IF;

    -- ---- REST (80): every N rounds, tidy. Force-final wins (don't rest a model
    -- being forced to answer); never rest the same round twice. ----
    -- per-dispatch override (_rest_every marker, propagated) wins over the global config,
    -- so a control run and a treatment run can A/B side by side.
    v_rest_every := COALESCE(
        (v_inherited_markers ->> '_rest_every')::int,
        (stewards.config_get('rest_every_n_steps','0'::jsonb) #>> '{}')::int,
        0);
    v_last_rested := CASE WHEN COALESCE((v_inherited_markers ->> '_cap_turn')::bigint, -1) = v_turn
                          THEN COALESCE((v_inherited_markers ->> '_rested_at_round')::int, -1) ELSE -1 END;
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
        v_payload := v_payload || jsonb_build_object('_soft_cap_notified', true, '_soft_cap_injected_at_round', v_rounds_so_far,
                                                     '_cap_turn', v_turn);
    ELSIF v_already_soft_notified THEN
        -- v71: this turn's notice was given in an earlier round; carry its markers, or the strip below drops them
        -- and the next round gives the notice again (v67 gave it every other round between the soft and hard caps)
        v_payload := v_payload || jsonb_build_object('_soft_cap_notified', true,
                                                     '_soft_cap_injected_at_round', v_inherited_markers -> '_soft_cap_injected_at_round',
                                                     '_cap_turn', v_turn);
    END IF;
    IF v_is_rest THEN
        v_payload := v_payload || jsonb_build_object('_rested_at_round', v_rounds_so_far, '_cap_turn', v_turn);
    ELSIF v_last_rested >= 0 THEN
        v_payload := v_payload || jsonb_build_object('_rested_at_round', v_last_rested, '_cap_turn', v_turn);
    END IF;

    IF v_inherited_markers IS NOT NULL THEN
        v_payload := (v_inherited_markers - '_soft_cap_notified' - '_soft_cap_injected_at_round' - '_rested_at_round'
                      - '_cap_turn') || v_payload;
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat', p_provider, v_payload, 'pending')
    RETURNING id INTO v_work_id;
    RETURN v_work_id;
END;
$FN$;

COMMENT ON FUNCTION stewards.chat_post_internal(text, text, text, text) IS
'v71 (re-authors v67): per-round continuation enqueue with two-tier force-final caps and the REST, counted per turn: rounds are the assistant messages after the session''s latest user message (every one when there is none), and the soft-notice and rest markers apply only under the user message they were written for (_cap_turn). v67: every round carries a max_tokens (the body''s own, the session''s previous round''s, or the model''s max_output_tokens capped at 32768 for anthropic format), recorded in payload.max_tokens_source.';
