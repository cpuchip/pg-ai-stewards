-- =====================================================================
-- v61: the model probe leaves temperature out for Anthropic-format models.
-- =====================================================================
-- enqueue_model_probe sends 'temperature', 0, and the anthropic translator
-- forwards it. Claude 5.5 models (Haiku, Sonnet and Opus 5.5) reject the
-- field with HTTP 400 invalid_request_error "`temperature` is deprecated for
-- this model.", so the probe recorded all three as unusable although agent
-- requests without a temperature succeed. Found on a second instance taking
-- Anthropic models on its own key, and on the live instance the same night.
--
-- Re-authors enqueue_model_probe (v40) verbatim plus one block before the
-- work_queue insert: when the probed model's api_format is 'anthropic', the
-- temperature key is removed from the body. Other providers' probes are
-- unchanged. Oracle: virgin-smoke OK 128. Idempotent (CREATE OR REPLACE).
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.enqueue_model_probe(
    p_provider text,
    p_model    text
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_session  text;
    v_payload  jsonb;
    v_work_id  bigint;
BEGIN
    v_session := substring(
        'probe--' || p_provider || '--' || p_model || '--'
        || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS')
        FROM 1 FOR 200);

    -- The session must exist so the bgworker's assistant-message INSERT lands.
    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session, format('model probe %s/%s', p_provider, p_model), 'agent')
    ON CONFLICT (id) DO NOTHING;

    -- #item2 (2026-07-05): a REALISTIC, tool-bearing probe. The old body stripped
    -- tools and asked for a 2-char echo — so kimi-k2.7-code "passed" on ~2 chars
    -- while REAL requests 400 ("Console Go: Upstream request failed"; "When using
    -- tool_choice, tools must be set"). This body asks for a short prose reply AND
    -- ships a tool + tool_choice, exercising the exact path a real agent request
    -- uses. The tool is deliberately IRRELEVANT to the question, so a healthy
    -- model answers in prose (no tool call → no continuation) while a model whose
    -- gateway trips on tool schemas 400s → recorded unusable. tools_disabled=false
    -- so the bgworker forwards body.tools instead of stripping them.
    -- v32 (#359): stream:true + stream_options.include_usage so the probe runs
    -- the SAME streaming path a real dispatch does — a model whose streaming path
    -- a provider rejects (SSE error / streams empty) now FAILS the probe instead
    -- of false-passing a non-streaming completion and re-poisoning routing.
    -- v40: max_tokens 128 → 32768. The 128 ceiling guaranteed 0 content chars on
    -- always-reasoning models (thinking eats the whole budget, finish=length) →
    -- usable=false on healthy models. A big ceiling costs nothing on healthy
    -- terse models and lets reasoners finish thinking and land their prose.
    v_payload := jsonb_build_object(
        'session_id',      v_session,
        'agent_family',    'model-probe',
        'requested_model', p_model,
        'tools_disabled',  false,
        'body', jsonb_build_object(
            'model',         p_model,
            'max_tokens',    32768,
            'temperature',   0,
            'stream',        true,
            'stream_options', jsonb_build_object('include_usage', true),
            'messages',    jsonb_build_array(
                jsonb_build_object('role', 'system',
                    'content', 'You are a model dispatchability probe. Answer briefly and directly.'),
                jsonb_build_object('role', 'user',
                    'content', 'In 1-2 sentences, state which model you are and one task you are good at. A weather tool is offered but is NOT relevant to this question — just answer in prose.')
            ),
            'tools', jsonb_build_array(
                jsonb_build_object(
                    'type', 'function',
                    'function', jsonb_build_object(
                        'name', 'get_current_weather',
                        'description', 'Get the current weather for a location. Offered only to exercise the tool-call path; not relevant to the probe question.',
                        'parameters', jsonb_build_object(
                            'type', 'object',
                            'properties', jsonb_build_object(
                                'location', jsonb_build_object('type', 'string', 'description', 'City name')),
                            'required', jsonb_build_array('location'))))),
            'tool_choice', 'auto'
        ),
        '_probe', jsonb_build_object('provider', p_provider, 'model', p_model)
    );

    -- Direct work_queue insert — NOT work_item_dispatch_stage — so the M.2
    -- capability substitution does not swap the model under test.
    -- v61: Claude 5.5 models answer HTTP 400 "`temperature` is deprecated for this
    -- model", and the anthropic translator forwards a temperature as given, so a
    -- probe that sends one marks a healthy Anthropic model unusable. Anthropic-
    -- format models are probed without it; every other probe is unchanged.
    IF (SELECT api_format FROM stewards.model_capability
         WHERE provider = p_provider AND model = p_model) = 'anthropic' THEN
        v_payload := jsonb_set(v_payload, '{body}', (v_payload->'body') - 'temperature');
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', p_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_model_probe(text, text) IS
'M.4 (#item2 + v32/#359 + v40): enqueue a REALISTIC, tool-bearing, STREAMING chat (short prose prompt + a tool + tool_choice + stream:true/stream_options) to test whether (provider, model) is dispatchable on the exact streaming path real agent requests use. v40: max_tokens=32768 — a ceiling, not a spend; the v32-era 128 guaranteed 0 content chars on always-reasoning models (thinking consumed the whole budget, finish=length) and falsely flipped healthy local models unusable (live-proven 2026-07-18). Direct work_queue insert (bypasses the M.2 substitution gate); the model-probe agent (steps=0) caps it at one call. The terminal-transition trigger records the streaming verdict into model_capability (usable + supports_streaming). v61: Anthropic-format models (model_capability.api_format = ''anthropic'') are probed without temperature, which Claude 5.5 rejects.';

-- =====================================================================
-- End of v61-probe-anthropic-temperature.sql
-- =====================================================================
