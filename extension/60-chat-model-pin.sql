-- =====================================================================
-- 60-chat-model-pin.sql — let a Stewdio chat turn pin an EXPLICIT
-- (provider, model) instead of resolving a role alias.
-- =====================================================================
-- Stewdio's chat normally dispatches via dispatch_chat_turn, which resolves a
-- role ALIAS ('reason' → the operator's local rig) to (provider, model). That's
-- right for the default, but the UX asks for "let a stronger model take over":
-- the user picks a specific model (often a cloud one) for a retry/escalation.
--
-- dispatch_chat_turn can't express that — it only takes an alias, and a bare
-- model id falls back to catalog_default_provider() (the WRONG provider for,
-- say, a Gemini model). chat_enqueue already takes (model, provider) explicitly;
-- this is the thin entrypoint that reuses it, mirroring dispatch_chat_turn's
-- session-ensure + first-turn grounding so a pinned turn behaves identically
-- except for the model that answers.
--
-- TEXT turns only (the escalation case). A media turn keeps using
-- dispatch_chat_turn (vision auto-select) — pinning a vision model is a future
-- need, not this one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.dispatch_chat_pinned(
    p_session_id   text,
    p_user_input   text,
    p_agent_family text,
    p_model        text,
    p_provider     text,
    p_grounding    text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $FN$
DECLARE
    v_have int;
BEGIN
    IF p_model IS NULL OR btrim(p_model) = '' OR p_provider IS NULL OR btrim(p_provider) = '' THEN
        RAISE EXCEPTION 'dispatch_chat_pinned requires explicit model + provider (got model=%, provider=%)',
            p_model, p_provider;
    END IF;

    -- ensure the persistent chat session exists (kind='chat') — same as dispatch_chat_turn.
    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (p_session_id, 'stewdio chat ' || left(p_session_id, 40), 'chat')
    ON CONFLICT (id) DO NOTHING;

    -- first-turn grounding (only when the session is empty), same shape as dispatch_chat_turn.
    SELECT count(*) INTO v_have FROM stewards.messages WHERE session_id = p_session_id;
    IF v_have = 0 AND p_grounding IS NOT NULL AND length(btrim(p_grounding)) > 0 THEN
        INSERT INTO stewards.messages (session_id, role, content)
        VALUES (p_session_id, 'user', p_grounding);
    END IF;

    -- append the user turn + enqueue against the EXPLICIT (provider, model).
    RETURN stewards.chat_enqueue(p_agent_family, p_model, p_session_id, p_user_input, p_provider);
END
$FN$;

COMMENT ON FUNCTION stewards.dispatch_chat_pinned(text, text, text, text, text, text) IS
'60: enqueue one chat turn pinned to an EXPLICIT (provider, model) — the "let a stronger model take over" escalation path for Stewdio. Mirrors dispatch_chat_turn (session-ensure + first-turn grounding) but skips alias resolution and reuses chat_enqueue(provider) directly. Text turns only; media keeps the dispatch_chat_turn vision path. Marker-free kind=chat → bgworker tool loop → reply in messages.';

-- =====================================================================
-- End of 60-chat-model-pin.sql
-- =====================================================================
