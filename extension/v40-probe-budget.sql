-- =====================================================================
-- v40-probe-budget.sql — the auto-probe must give reasoning models room
-- to think, or it falsely marks healthy models unusable.
-- =====================================================================
-- Live evidence (2026-07-18, the operator rig): the moment thinkingcap-qwen3.6-27b
-- was registered (capability + pricing rows), it became probe-due; the real
-- probe (work 44521) ran the real pipeline against the real rig and resolved
--   "auto-probe (streaming): no usable output (0 content chars, no
--    tool_calls), finish=length" → usable=false
-- — on a model that minutes earlier had passed a role bake-off, a six-case
-- spiral replay, and a vision test through the same :8090 router. The probe's
-- max_tokens=128 (v32 dropped it 400 → 128) is the whole failure: an
-- always-reasoning model (qwen3.6 family, gemma-4 family — i.e. the entire
-- local fleet) spends 300-2500 tokens in reasoning_content before emitting
-- any content, so the 128-token ceiling guarantees 0 content chars and
-- finish=length. trigger_resolve_model_probe then flips usable=false and
-- routing silently falls to the cloud fallback — the exact "re-poisoning
-- routing" failure v32 §2 existed to prevent, now caused by its own budget.
-- The workspace overlay has warned about this class since June ("any manual
-- probe MUST give it >=2500 tokens or it looks (falsely) broken").
--
-- Fix (Michael's ruling, 2026-07-18: "raise the probe budget to 32k — it's
-- too small otherwise"): max_tokens 128 → 32768. It is a CEILING, not a
-- spend — a healthy non-reasoning model still answers in a sentence and
-- stops; a reasoning model thinks as long as it needs and still lands its
-- prose. 32k also keeps the probe honest for models whose thinking length
-- varies run-to-run (the false-fail was nondeterministic near the boundary).
-- Re-authors enqueue_model_probe (v06/M.4, re-authored v32 §2) verbatim
-- EXCEPT the max_tokens value and the comments that documented the old one.
-- Idempotent (CREATE OR REPLACE).
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
    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', p_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_model_probe(text, text) IS
'M.4 (#item2 + v32/#359 + v40): enqueue a REALISTIC, tool-bearing, STREAMING chat (short prose prompt + a tool + tool_choice + stream:true/stream_options) to test whether (provider, model) is dispatchable on the exact streaming path real agent requests use. v40: max_tokens=32768 — a ceiling, not a spend; the v32-era 128 guaranteed 0 content chars on always-reasoning models (thinking consumed the whole budget, finish=length) and falsely flipped healthy local models unusable (live-proven 2026-07-18). Direct work_queue insert (bypasses the M.2 substitution gate); the model-probe agent (steps=0) caps it at one call. The terminal-transition trigger records the streaming verdict into model_capability (usable + supports_streaming).';

-- =====================================================================
-- End of v40-probe-budget.sql
-- =====================================================================
