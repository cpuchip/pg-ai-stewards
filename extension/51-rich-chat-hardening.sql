-- =====================================================================
-- 51-rich-chat-hardening.sql — e2e findings from the doc-build runs.
-- =====================================================================
-- Two fixes surfaced by running doc-build end-to-end (.spec/journal/
-- 2026-06-24-rich-chat-and-artifacts.md + the rerun):
--
--   §1  doc-build artifact-exists gate. A build that exports NO downloadable
--       file is a FAILURE, not a success — but the pipeline was marking it
--       "completed" anyway (gemini-3.5-flash ran fast, made one tool call, and
--       produced nothing, yet the work_item showed completed). A deterministic
--       BEFORE-UPDATE trigger flips a doc-build completion to 'failed' when no
--       artifact landed for its chat session, so an empty build can't pose as
--       done (the worst demo failure mode: a "success" with no document).
--
--   §2  chat → brainstorm. The work-item chat could spawn pipelines via
--       start_task but not kick a proper BRAINSTORM. Granting start_brainstorm
--       lets the chat run any of the 12 brainstorm techniques (six-hats,
--       SCAMPER, TRIZ, …) on the work item / corpus in focus — "chat, then
--       brainstorm on it" in one place.
--
-- requires create_doc_build (50). Generic core.
-- =====================================================================

-- ── §1 — doc-build artifact-exists gate ─────────────────────────────
CREATE OR REPLACE FUNCTION stewards.doc_build_verify_artifact()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- Only judge doc-build work_items at the moment they claim completion.
    IF NEW.pipeline_family = 'doc-build'
       AND NEW.status = 'completed'
       AND coalesce(OLD.status, '') <> 'completed' THEN
        -- The build must have exported a downloadable artifact (a chat_attachment
        -- under the spawning chat session, created during this run). If not, the
        -- "completion" is empty — mark it failed so it can't pose as success.
        IF NOT EXISTS (
            SELECT 1 FROM stewards.chat_attachments a
             WHERE a.session_id = NEW.input ->> 'spawned_from_chat'
               AND a.created_at >= NEW.created_at
        ) THEN
            NEW.status := 'failed';
            NEW.last_failure_reason :=
                'doc-build exported no artifact — the build produced no downloadable document (failing instead of reporting a false success)';
        END IF;
    END IF;
    RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION stewards.doc_build_verify_artifact() IS
'51: deterministic gate — a doc-build that completes without exporting an artifact (chat_attachment for its spawned_from_chat session) is flipped to failed, so an empty build never poses as a successful document.';

CREATE OR REPLACE TRIGGER doc_build_verify_artifact_trg
    BEFORE UPDATE ON stewards.work_items
    FOR EACH ROW
    EXECUTE FUNCTION stewards.doc_build_verify_artifact();

-- ── §2 — chat → brainstorm ──────────────────────────────────────────
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'start_brainstorm', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- Teach the chat it can brainstorm (append to the Ask/Delegate guidance).
UPDATE stewards.agents
   SET prompt = prompt || E'\n\nYou can also run a BRAINSTORM on the work item / corpus in focus: call start_brainstorm when the user wants ideas, options, or divergent thinking (it offers techniques like six-hats, SCAMPER, TRIZ). Like start_task, it spawns work the user watches in the cockpit.'
 WHERE family = 'work-item-chat' AND model_match = '*'
   AND prompt NOT LIKE '%start_brainstorm%';

-- §3 — teach the chat to DELEGATE document generation (e2e finding: asked to
-- "generate a PDF", the chat wrote it inline and said "I can't emit a file" —
-- it did not realize it can spawn doc-build, which produces a real download).
UPDATE stewards.agents
   SET prompt = prompt || E'\n\nWhen the user asks you to GENERATE, CREATE, BUILD, or EXPORT a document — a PDF, spreadsheet (xlsx), slide deck (pptx), Word doc (docx), image, or zip bundle — do NOT write it inline and do NOT say you cannot emit files. You CAN: call start_task with pipeline="doc-build" and a binding_question describing the document and any source material to pull from the corpus. The doc-build pipeline writes a real, downloadable file the user receives in the cockpit. Only answer inline when the user wants the content IN the chat, not as a file.'
 WHERE family = 'work-item-chat' AND model_match = '*'
   AND prompt NOT LIKE '%pipeline="doc-build"%';

-- =====================================================================
-- End of 51-rich-chat-hardening.sql
-- =====================================================================
