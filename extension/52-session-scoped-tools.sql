-- =====================================================================
-- 52-session-scoped-tools.sql — the dispatcher owns session_id, not the model.
-- =====================================================================
-- Some tools attach their output to the chat session they run in:
--   generate_image       → inserts a chat_attachment(kind='image')
--   coder_export_artifact → inserts a chat_attachment(kind='document')
-- Both take a session_id argument. Until now the MODEL supplied it,
-- nudged by a line in the chat grounding ("your session is X, pass it").
-- That is best-effort: stronger models comply, weaker ones pass a
-- placeholder ('chat-session') or omit it, and the artifact lands in the
-- wrong place or nowhere.
--
-- The dispatcher already knows the authoritative session (it threads
-- session_id through tool_dispatch). So we mark these tools
-- `inject_session` on their execute_target; tools.rs::exec_one_tool then
-- OVERRIDES the model-supplied session_id with the real dispatch session
-- before routing. Build-the-oracle: the model stops being load-bearing
-- for correctness. The Rust side reads this flag generically — the policy
-- (which tools) lives here in SQL.
--
-- WHY a trigger, not a one-shot UPDATE: tool_defs for mcp_proxy tools are
-- populated at RUNTIME by the bridge's refresh-tools (05-mcp-bridge.sql
-- upserts execute_target ON CONFLICT DO UPDATE). So (1) on a virgin boot
-- the rows don't exist yet — a one-shot UPDATE matches nothing — and (2)
-- the next refresh-tools would WIPE a one-shot flag by overwriting
-- execute_target. A BEFORE INSERT OR UPDATE trigger re-stamps the flag
-- every time those rows are written, so it survives refresh-tools and is
-- correct whenever the tool_def first appears.
--
-- requires create_rich_chat_hardening (51). Generic core. Idempotent.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.tool_def_inject_session()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- Session-scoped tools: the dispatcher overrides the model's session_id,
    -- so their execute_target must always carry the inject_session marker —
    -- even after a refresh-tools rebuild overwrites execute_target.
    IF NEW.name IN ('generate_image', 'coder_export_artifact') THEN
        NEW.execute_target :=
            coalesce(NEW.execute_target, '{}'::jsonb)
            || jsonb_build_object('inject_session', true);
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS tool_def_inject_session_trg ON stewards.tool_defs;
CREATE TRIGGER tool_def_inject_session_trg
    BEFORE INSERT OR UPDATE ON stewards.tool_defs
    FOR EACH ROW EXECUTE FUNCTION stewards.tool_def_inject_session();

-- Stamp any rows already present (a live instance where refresh-tools has
-- already run); the no-op touch fires the BEFORE-UPDATE trigger. On a
-- virgin boot this matches nothing and the trigger handles it at insert.
UPDATE stewards.tool_defs
   SET execute_target = execute_target
 WHERE name IN ('generate_image', 'coder_export_artifact');
