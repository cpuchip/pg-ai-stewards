-- =====================================================================
-- v74: the soft-cap notice ends a stretch, not a task, when an agent says so.
-- =====================================================================
-- The interactive soft-cap notice (chat_post_internal, at 0.7 x steps) told the model: "If you can answer the
-- binding question now from what you have already gathered, finalize your response." A model that runs its
-- work across several chains of steps (a work session that a harness restarts after each chain) reads that as
-- the end of the work: on stuffleupagus every Opus work session ended after one chain of about 11 rounds by
-- calling its finish tool on the notice, where qwen had carried on past it (2026-10-28/29).
--
-- The wording is now a setting, at two levels, and unset everywhere the notice is byte for byte what it was:
--   agents.soft_cap_notice          this agent's wording (NULL: the instance's)
--   config soft_cap_notice          the instance's wording (unset: the classic text)
-- Either holds 'classic', 'stretch' (the shipped wording below: finish the step, note where you are, end the
-- stretch; the task is not over), or a template of your own with {rounds}, {soft_cap}, {hard_cap} and {stage}.
-- build_soft_cap_notice keeps its 4-argument form (v12's rigor path and v14's search path call it; it now
-- reads the config) and gains a 5-argument form that takes the wording. chat_post_internal is v71's body
-- verbatim with the agent's wording passed in.
-- Oracle: virgin-smoke OK 141. Idempotent.
-- =====================================================================

ALTER TABLE stewards.agents ADD COLUMN IF NOT EXISTS soft_cap_notice text;
COMMENT ON COLUMN stewards.agents.soft_cap_notice IS
'v74: this agent''s soft-cap notice: classic, stretch, or a template with {rounds} {soft_cap} {hard_cap} {stage}. NULL: config soft_cap_notice, else classic.';

CREATE OR REPLACE FUNCTION stewards.soft_cap_notice_template()
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT nullif(btrim(stewards.config_get_text('soft_cap_notice')), '')
$$;

COMMENT ON FUNCTION stewards.soft_cap_notice_template() IS
'v74: config soft_cap_notice (classic, stretch, or a template), or NULL when unset.';

CREATE OR REPLACE FUNCTION stewards.build_soft_cap_notice(
    p_rounds_so_far int,
    p_soft_cap      int,
    p_hard_cap      int,
    p_stage_name    text,
    p_template      text
) RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_template IS NULL OR btrim(p_template) IN ('', 'classic') THEN
            '[STEWARD NOTICE — soft cap reached]' || E'\n\n' ||
            'You have used ' || p_rounds_so_far::text || ' tool calls in the ' ||
            COALESCE(p_stage_name, 'current') || ' stage. The soft cap for this stage is ' ||
            p_soft_cap::text || '; the hard cap (where tools will be removed entirely) is ' ||
            p_hard_cap::text || '.' || E'\n\n' ||
            'If you can answer the binding question now from what you have already gathered, ' ||
            'finalize your response. If you genuinely need another tool call, include a ' ||
            'one-sentence justification in your next response so future review can audit ' ||
            'the decision.' || E'\n\n' ||
            'You retain full agency. The substrate is funding your mission, not micromanaging it.'
        WHEN btrim(p_template) = 'stretch' THEN
            '[STEWARD NOTICE — soft cap reached]' || E'\n\n' ||
            'You have used ' || p_rounds_so_far::text || ' tool calls in this stretch of the ' ||
            COALESCE(p_stage_name, 'current') || ' stage. The soft cap for a stretch is ' ||
            p_soft_cap::text || '; at ' || p_hard_cap::text || ' tools are removed for the rest of it.' || E'\n\n' ||
            'This notice is about the stretch, not your task. Finish the step you are on, write down where you ' ||
            'are and what is next, and end the stretch with a line saying so. Do not end or hand back the task ' ||
            'because of this notice: end it when the work is done.' || E'\n\n' ||
            'You retain full agency. The substrate is funding your mission, not micromanaging it.'
        ELSE
            replace(replace(replace(replace(p_template,
                '{rounds}', p_rounds_so_far::text), '{soft_cap}', p_soft_cap::text),
                '{hard_cap}', p_hard_cap::text), '{stage}', COALESCE(p_stage_name, 'current'))
    END
$$;

COMMENT ON FUNCTION stewards.build_soft_cap_notice(int, int, int, text, text) IS
'v74: the soft-cap notice in the given wording: classic (NULL, empty or ''classic''; the text before v74), stretch, or a template with {rounds} {soft_cap} {hard_cap} {stage}.';

-- the 4-argument form: the instance's wording (v12 and v14 call it)
CREATE OR REPLACE FUNCTION stewards.build_soft_cap_notice(
    p_rounds_so_far int,
    p_soft_cap      int,
    p_hard_cap      int,
    p_stage_name    text
) RETURNS text LANGUAGE sql STABLE AS $$
    SELECT stewards.build_soft_cap_notice(p_rounds_so_far, p_soft_cap, p_hard_cap, p_stage_name,
                                          stewards.soft_cap_notice_template())
$$;

-- chat_post_internal: v71's body verbatim, with the agent's wording passed to the notice.
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
    -- v74
    v_notice_template       text;
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
        -- v74: the agent's own wording, else the instance's (soft_cap_notice_template)
        SELECT a.soft_cap_notice INTO v_notice_template FROM stewards.agents a
         WHERE a.family = p_agent_family AND stewards.glob_match(a.model_match, p_model)
         ORDER BY length(a.model_match) DESC LIMIT 1;
        v_notice_text := stewards.build_soft_cap_notice(v_rounds_so_far, v_soft_cap, v_hard_cap, v_stage_name,
                                                        coalesce(v_notice_template, stewards.soft_cap_notice_template()));
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
'v71 (re-authors v67): per-round continuation enqueue with two-tier force-final caps and the REST, counted per turn: rounds are the assistant messages after the session''s latest user message (every one when there is none), and the soft-notice and rest markers apply only under the user message they were written for (_cap_turn). v67: every round carries a max_tokens (the body''s own, the session''s previous round''s, or the model''s max_output_tokens capped at 32768 for anthropic format), recorded in payload.max_tokens_source. v74: the soft-cap notice in the agent''s wording (agents.soft_cap_notice), else the instance''s (config soft_cap_notice).';
