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

-- =====================================================================
-- End of 49-doc-extract.sql
-- =====================================================================
