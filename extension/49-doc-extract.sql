-- =====================================================================
-- 49-doc-extract.sql — rich documents in chat, P3: document extraction.
-- =====================================================================
-- The substrate side of the doc-extract capability (proposal
-- .spec/proposals/doc-extract-sandbox.md). The heavy lifting is the bridge's
-- doc-extract-mcp + the hardened doc-extract sandbox image (Go); this file is
-- the thin DB surface:
--
--   §1  chat_attachments gains parent_id (a rendered page image belongs to its
--       source document) + scan_verdict / scan_findings (the security scan,
--       recorded for provenance + the model's awareness).
--   §2  chat_attachment_parts is re-authored so a DOCUMENT attachment surfaces
--       its extracted_text (or a "call doc_extract" nudge when not yet read),
--       AND any rendered page images of a referenced document ride along as the
--       pixel overlay (P3c). 49 now OWNS chat_attachment_parts.
--   §3  the doc-extract MCP server is registered (the bridge spawns it; the
--       capability needs docker-compose.doc-extract.yaml for the socket + the
--       freshclam-fed clamav-db volume).
--   §4  doc_extract is granted to the work-item-chat agent (the rich-docs chat
--       surface), so an attached document can be turned into subject material.
--
-- requires create_chat_attachments (48).
-- =====================================================================

-- ── §1 — columns: parent linkage + the recorded scan verdict ─────────
ALTER TABLE stewards.chat_attachments
    ADD COLUMN IF NOT EXISTS parent_id     bigint,   -- a page image's source document (NULL for top-level uploads)
    ADD COLUMN IF NOT EXISTS scan_verdict  text,     -- clean | suspicious | malicious (recorded by doc_extract)
    ADD COLUMN IF NOT EXISTS scan_findings text;     -- comma-joined structural findings (transparency)

CREATE INDEX IF NOT EXISTS chat_attachments_parent_idx
    ON stewards.chat_attachments (parent_id) WHERE parent_id IS NOT NULL;

COMMENT ON COLUMN stewards.chat_attachments.parent_id IS
'49: for a rendered page image, the chat_attachments id of its source document (the pixel overlay). chat_attachment_parts expands a referenced document to include its children.';

-- ── §2 — chat_attachment_parts: text + nudge + the pixel overlay ─────
-- Re-authored (49 now owns it). For each referenced attachment AND the page
-- images of any referenced document, build the 47 content_parts array:
--   image            -> image_url part (server-built data URL; base64 unwrapped)
--   document w/ text -> a text part carrying the extracted markdown
--   document w/o text-> a "call doc_extract(id)" nudge (so the agent reads it)
-- Ordered so a document's text precedes its page images. Session-scoped (no
-- cross-session injection). Marks consumed_at. NULL when nothing resolves.
CREATE OR REPLACE FUNCTION stewards.chat_attachment_parts(
    p_ids        bigint[],
    p_session_id text
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_parts jsonb;
BEGIN
    IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN
        RETURN NULL;
    END IF;

    WITH wanted AS (
        -- the directly-referenced attachments
        SELECT a.* FROM stewards.chat_attachments a
         WHERE a.id = ANY(p_ids) AND a.session_id = p_session_id
        UNION
        -- plus the rendered page images of any referenced document (overlay)
        SELECT c.* FROM stewards.chat_attachments c
         WHERE c.parent_id = ANY(p_ids) AND c.session_id = p_session_id AND c.kind = 'image'
    ),
    parts AS (
        SELECT
            CASE
                WHEN w.kind = 'image' AND w.bytes IS NOT NULL THEN
                    jsonb_build_object(
                        'type', 'image_url',
                        'image_url', jsonb_build_object(
                            'url', 'data:' || coalesce(w.mime_type, 'image/png')
                                   || ';base64,' || translate(encode(w.bytes, 'base64'), E'\n\r', '')))
                WHEN w.kind = 'document' AND w.extracted_text IS NOT NULL THEN
                    jsonb_build_object(
                        'type', 'text',
                        'text', '[Attached document: ' || coalesce(w.filename, 'document')
                                || CASE WHEN w.scan_verdict IS NOT NULL AND w.scan_verdict <> 'clean'
                                        THEN ' — security scan: ' || w.scan_verdict
                                             || coalesce(' (' || w.scan_findings || ')', '')
                                        ELSE '' END
                                || E']\n' || w.extracted_text)
                WHEN w.kind = 'document' AND w.extracted_text IS NULL THEN
                    jsonb_build_object(
                        'type', 'text',
                        'text', '[Attached document #' || w.id || ': ' || coalesce(w.filename, 'document')
                                || ' — not yet read. Call doc_extract with attachment_id=' || w.id
                                || ' to extract its text (add render=true for page images).]')
                ELSE NULL
            END AS part,
            coalesce(w.parent_id, w.id) AS grp,          -- group a doc with its page images
            (w.parent_id IS NOT NULL)   AS is_child,     -- doc text before its page images
            w.id                        AS oid
          FROM wanted w
    )
    SELECT jsonb_agg(part ORDER BY grp, is_child, oid)
      INTO v_parts
      FROM parts
     WHERE part IS NOT NULL;

    -- mark consumed (the directly-referenced attachments, first injection only)
    UPDATE stewards.chat_attachments
       SET consumed_at = now()
     WHERE id = ANY(p_ids) AND session_id = p_session_id AND consumed_at IS NULL;

    RETURN v_parts;  -- NULL when nothing resolved
END;
$fn$;

COMMENT ON FUNCTION stewards.chat_attachment_parts(bigint[], text) IS
'49: assemble the 47 content_parts array from this session''s attachments. Images -> image_url (server-built data URL); documents -> their extracted_text (or a doc_extract nudge); a referenced document''s rendered page images ride along as the pixel overlay. Session-scoped, marks consumed, NULL when nothing resolves.';

-- ── §3 — register the doc-extract MCP server (bridge-spawned) ────────
-- The capability needs docker-compose.doc-extract.yaml (the docker socket on
-- the bridge + the freshclam-fed clamav-db volume). Without the overlay the
-- server is registered but a doc_extract call errors clearly (no image/socket).
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled) VALUES
  ('doc-extract',
   'Hardened document extraction — turn an attached PDF / Office / HTML / text / archive into safe, readable subject material inside a no-network sandbox (text always; page pixels on request). Tool: doc_extract(attachment_id). Needs the docker-compose.doc-extract.yaml overlay (docker socket + clamav-db volume).',
   'stdio', '/usr/local/bin/doc-extract-mcp', '{}'::text[], NULL, '{}'::jsonb, 't')
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, transport = EXCLUDED.transport,
    command = EXCLUDED.command, args = EXCLUDED.args, env = EXCLUDED.env,
    enabled = EXCLUDED.enabled;

-- ── §4 — grant doc_extract to the work-item-chat agent ──────────────
-- The rich-docs chat surface: when a document is attached, the agent calls
-- doc_extract to read it (the nudge in §2 prompts this). Read-only allow-list,
-- longest-glob-wins, so this specific allow beats the deny '*' base.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'doc_extract',       'allow', 'manual'),
  ('work-item-chat', 'doc_import_corpus', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ── §5 — P3e: archive/folder import → searchable project pool ───────
-- doc_import_corpus (a doc-extract tool, bridge-side Go) unpacks an attached
-- archive in the sandbox and pools each member as a searchable doc via the
-- existing import_doc path, tagged with a project_association so doc_search
-- scopes to the corpus — "drop a folder of docs, get a searchable project."
-- No new table: it reuses the docs pool (the substrate's existing corpus
-- model), so doc_search/doc_get/doc_similar (already granted to work-item-chat)
-- find the imported members immediately. The grant is in §4 above.
--
-- P3f (digester-reads-repos): the SAME no-network extract sandbox reads a
-- read-only repo checkout — a repo is just a folder, so it rides this path via
-- doc_import_corpus once a repo is mounted/cloned (see the proposal §7 P3f).

-- ── §6 — P4: start_task carries the chat's attachments into spawned work ──
-- chat_task_input builds the spawned work_item's input from the chat session:
-- the user's assignment PLUS the extracted text of any document attachments in
-- the session, folded into the binding question so EVERY pipeline carries the
-- subject material (and attachment_ids for tools that want the originals). This
-- is the deterministic, testable core; chat_start_task_tool calls it.
CREATE OR REPLACE FUNCTION stewards.chat_task_input(
    p_session  text,
    p_question text
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_docs    text;
    v_att_ids bigint[];
    v_q       text := btrim(coalesce(p_question, ''));
    v_input   jsonb := jsonb_build_object(
                  'spawned_from_chat', coalesce(p_session, ''),
                  -- a stable sandbox id for coder/doc-build pipelines spawned from
                  -- this chat (the build stage runs in coder_sandbox_start <sandbox>).
                  'sandbox', 'task-' || substr(md5(coalesce(p_session, 'x') || '|' || coalesce(p_question, '')), 1, 12));
BEGIN
    -- The session's extracted document attachments become subject material.
    SELECT string_agg('### ' || coalesce(filename, 'document') || E'\n' || left(extracted_text, 8000),
                      E'\n\n' ORDER BY id),
           array_agg(id)
      INTO v_docs, v_att_ids
      FROM stewards.chat_attachments
     WHERE session_id = p_session AND kind = 'document' AND extracted_text IS NOT NULL;

    IF v_docs IS NOT NULL THEN
        -- cap the aggregate so a big folder can't blow the child's prompt
        v_docs := left(v_docs, 24000);
        v_q := nullif(v_q, '')
               || CASE WHEN v_q <> '' THEN E'\n\n' ELSE '' END
               || '--- Attached subject material (from the chat) ---' || E'\n' || v_docs;
        v_input := v_input || jsonb_build_object(
            'attached_documents', v_docs,
            'attachment_ids',     to_jsonb(v_att_ids));
    END IF;

    IF coalesce(v_q, '') <> '' THEN
        v_input := v_input || jsonb_build_object('binding_question', v_q, 'assignment', v_q);
    END IF;
    RETURN v_input;
END;
$fn$;

COMMENT ON FUNCTION stewards.chat_task_input(text, text) IS
'49/P4: build a spawned work_item input from a chat session — the assignment plus the extracted text of the session''s document attachments, folded into the binding question (so any pipeline carries it) + attachment_ids.';

-- Re-author chat_start_task_tool (46) to carry the attachments via chat_task_input.
CREATE OR REPLACE FUNCTION stewards.chat_start_task_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess     text := p_args ->> '_session_id';
    v_pipeline text := coalesce(p_args ->> 'pipeline', p_args ->> 'pipeline_family', '');
    v_question text := btrim(coalesce(p_args ->> 'binding_question', p_args ->> 'assignment', p_args ->> 'task', ''));
    v_slug     text := nullif(btrim(coalesce(p_args ->> 'slug', '')), '');
    v_parent   uuid;
    v_input    jsonb;
    v_child    uuid;
    v_wq       bigint;
BEGIN
    IF v_pipeline = '' THEN
        RETURN jsonb_build_object('ok', false,
            'note', 'pipeline required (e.g. research-summary, book-digest, playlist-digest)')::text;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family = v_pipeline) THEN
        RETURN jsonb_build_object('ok', false,
            'note', format('no pipeline named %L — list_pipelines for the options', v_pipeline))::text;
    END IF;

    v_parent := (regexp_match(coalesce(v_sess, ''),
                 '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'))[1]::uuid;
    IF v_parent IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stewards.work_items WHERE id = v_parent) THEN
        v_parent := NULL;
    END IF;

    -- P4: the input now carries the chat's attached documents as subject material.
    v_input := stewards.chat_task_input(v_sess, v_question);

    BEGIN
        v_child := stewards.work_item_create(
            v_pipeline, v_input,
            coalesce(v_slug, v_pipeline || '-chat-' || to_char(now(), 'YYYYMMDD-HH24MISS')),
            'work-item-chat', NULL::int, NULL::uuid);
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'note', 'could not create task: ' || SQLERRM)::text;
    END;

    IF v_parent IS NOT NULL THEN
        UPDATE stewards.work_items SET parent_work_item_id = v_parent WHERE id = v_child;
    END IF;

    BEGIN
        v_wq := stewards.work_item_dispatch_stage(v_child);
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', true, 'work_item_id', v_child::text,
            'parent_work_item_id', v_parent, 'dispatched', false,
            'note', 'task created + linked but not dispatched: ' || SQLERRM)::text;
    END;

    RETURN jsonb_build_object('ok', true,
        'work_item_id', v_child::text,
        'pipeline', v_pipeline,
        'parent_work_item_id', v_parent,
        'dispatched', true,
        'carried_attachments', (v_input ? 'attachment_ids'),
        'note', CASE WHEN v_parent IS NOT NULL
                     THEN 'task started and linked to this work item — it will appear nested under it in the cockpit; watch it advance in the center panel'
                     ELSE 'task started (top-level — this chat is not grounded in a work item); watch it in the work-item browser' END)::text;
END;
$fn$;

-- =====================================================================
-- End of 49-doc-extract.sql
-- =====================================================================
