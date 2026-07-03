-- =====================================================================
-- 86-sticky-agent-family.sql — session-sticky agent family (ratified 2026-07-03)
-- =====================================================================
-- The cockpit's chatSendHandler hardcoded agent_family='work-item-chat' for
-- every FOLLOW-UP turn, so a session opened AS a specialized agent (85's
-- loremaster "Chat with this world") ran as that agent only on turn 1. 85
-- bridged it by granting the read-only lore tools to work-item-chat — a wart
-- that grew work-item-chat's tool list. Michael approved the clean fix
-- ("decision 4"): store the agent family ON the session; follow-up dispatch
-- reads it and falls back to work-item-chat only when none was recorded.
--
-- Shape (minimal blast radius, no dispatch-function reauthoring):
--   * sessions.agent_family column — recorded by whoever OPENS a specialized
--     session (the world-chat handler; future specialized chats do the same).
--   * chat_agent_family(sid) — the COALESCE lookup the Go call sites use
--     inline: dispatch_chat_turn($1, ..., stewards.chat_agent_family($1), ...).
--   * backfill: world-chat-% sessions (85's naming convention) → loremaster.
--   * the 85 bridge grants come OFF work-item-chat (follow-ups now genuinely
--     dispatch as loremaster, which holds those grants itself).
-- requires create_world_chat (85).
-- =====================================================================

ALTER TABLE stewards.sessions ADD COLUMN IF NOT EXISTS agent_family text;
COMMENT ON COLUMN stewards.sessions.agent_family IS
'86: the agent family this session was OPENED as (loremaster, …). NULL = an ordinary
cockpit chat. chat_agent_family() resolves it with the work-item-chat fallback so
follow-up turns keep dispatching as the family the session began with.';

-- ── session_agent_family — the sticky lookup ─────────────────────────
-- The session''s recorded family is authoritative; the fallback is the cockpit
-- default. Unknown/absent session ids also fall back (a fresh session row is
-- created by the dispatch itself, after which an opener may record a family).
CREATE OR REPLACE FUNCTION stewards.chat_agent_family(p_session text)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(
        (SELECT agent_family FROM stewards.sessions WHERE id = p_session),
        'work-item-chat');
$fn$;
COMMENT ON FUNCTION stewards.chat_agent_family(text) IS
'86: resolve the agent family for a CHAT dispatch (named chat_* to avoid 15b''s
session_agent_family, which resolves a PIPELINE stage''s family — different semantics) — the session''s recorded family, else
the work-item-chat default. The Go chat handlers pass this instead of a hardcoded
family, so a specialized session (85 loremaster) STAYS its agent on follow-ups.';

-- ── session_set_agent_family — the opener''s one-liner ────────────────
-- Called right after the first dispatch (the dispatch creates the row). Kept as
-- a function so intentional MID-session switches have a named, auditable verb.
CREATE OR REPLACE FUNCTION stewards.session_set_agent_family(p_session text, p_family text)
RETURNS void LANGUAGE sql AS $fn$
    UPDATE stewards.sessions SET agent_family = p_family WHERE id = p_session;
$fn$;
COMMENT ON FUNCTION stewards.session_set_agent_family(text, text) IS
'86: record (or intentionally switch) a session''s sticky agent family.';

-- ── backfill: sessions opened by 85''s world-chat before 86 existed ────
UPDATE stewards.sessions SET agent_family = 'loremaster'
 WHERE id LIKE 'world-chat-%' AND agent_family IS NULL;

-- ── retire the 85 bridge: work-item-chat no longer needs the lore tools ─
-- Follow-up turns in a world-chat session now dispatch as loremaster itself
-- (which holds these grants in 57/85), so the bridge grants come off — an
-- ordinary cockpit chat never needed lore tools on its shelf.
DELETE FROM stewards.agent_tool_perms
 WHERE agent_family = 'work-item-chat'
   AND tool_pattern IN ('lore_search','lore_entity','lore_neighbors','world_neighbors','world_show')
   AND source = 'manual';
