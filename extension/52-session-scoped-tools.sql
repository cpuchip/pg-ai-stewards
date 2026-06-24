-- =====================================================================
-- 52-session-scoped-tools.sql — the dispatcher owns session_id, not the model.
-- =====================================================================
-- `generate_image` (chat) attaches its output to the session it runs in:
-- inserts a chat_attachment(kind='image'). The MODEL was asked to pass the
-- session_id (a grounding nudge), which is best-effort — weak models pass a
-- placeholder ('chat-session') or omit it, and the image lands nowhere.
--
-- The dispatcher already knows the authoritative session (it threads
-- session_id through tool_dispatch). So we mark generate_image
-- `inject_session` on its execute_target; tools.rs::exec_one_tool then
-- OVERRIDES the model-supplied session_id with the real dispatch session
-- before routing. Build-the-oracle: the model stops being load-bearing
-- for correctness. The Rust side reads this flag generically — the policy
-- (which tools) lives here in SQL.
--
-- ⚠ coder_export_artifact is DELIBERATELY EXCLUDED. It does cross-session
-- routing on purpose: the doc-build pipeline's build stage runs in its own
-- session (wi--<id>--build) but exports the artifact to a DIFFERENT session —
-- the spawning chat — via the template's explicit
-- session_id="{{input.spawned_from_chat}}". An inject_session OVERRIDE would
-- clobber that with the (transient) build-stage session, so the artifact lands
-- in wi--<id>--build, the artifact-gate (51) sees nothing under
-- spawned_from_chat and fails the build, and the chat never gets the file.
-- coder_export_artifact's session_id is always caller-provided and correct —
-- it must NOT be injected. (A general fix — inject only as a FALLBACK when the
-- arg is absent/placeholder — is the follow-up; for now generate_image is the
-- only tool whose target == the dispatch session.)
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
    -- generate_image's target IS the dispatch session, so the dispatcher
    -- overrides the model's session_id — and the marker must survive a
    -- refresh-tools rebuild that overwrites execute_target. (coder_export_artifact
    -- is excluded — see the header: it routes cross-session on purpose.)
    IF NEW.name IN ('generate_image') THEN
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

-- Stamp generate_image if its row is already present (a live instance where
-- refresh-tools has already run); the no-op touch fires the BEFORE-UPDATE
-- trigger. On a virgin boot this matches nothing and the trigger handles it
-- at insert.
UPDATE stewards.tool_defs
   SET execute_target = execute_target
 WHERE name = 'generate_image';

-- Un-stamp coder_export_artifact on instances that ran an earlier 52 (which
-- wrongly marked it inject_session). It must use the caller-provided session_id.
UPDATE stewards.tool_defs
   SET execute_target = execute_target - 'inject_session'
 WHERE name = 'coder_export_artifact'
   AND execute_target ? 'inject_session';
