-- =====================================================================
-- 48-chat-attachments.sql — rich documents in chat, P2: attachments.
-- =====================================================================
-- Durable, session-scoped media a user attaches to a Stewdio chat as injectable
-- subject material. The bytes live in the DB (bytea) so they carry with the
-- session and into spawned work (P4); a turn assembles the attachments into the
-- multimodal content array (47's content_parts) the vision model sees.
--
-- Flow: the UI uploads a file -> POST /api/chat/attach INSERTs a row -> the next
-- chat send passes the attachment ids -> dispatch_chat_turn(p_content_parts :=
-- chat_attachment_parts(ids, session)) injects them. The base64 never round-trips
-- through the app — chat_attachment_parts builds the data URL server-side from the
-- stored bytea, the same "read by handle, don't re-emit" discipline as page-in /
-- the book corpus.
--
-- Generic core (spec §7: chat_attachments is OSS core). P2 handles images;
-- documents (extracted_text / kind='document') are populated by P3's extraction.
-- requires create_multimodal (47). Proposal: .spec/proposals/rich-docs-in-chat.md.
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.chat_attachments (
    id             bigserial PRIMARY KEY,
    session_id     text NOT NULL,             -- the chat session it belongs to (no FK: upload can precede the session)
    filename       text NOT NULL DEFAULT 'attachment',
    mime_type      text NOT NULL DEFAULT 'application/octet-stream',
    kind           text NOT NULL DEFAULT 'image'   -- 'image' (vision) | 'document' (extracted text, P3)
                   CHECK (kind IN ('image', 'document')),
    bytes          bytea,                      -- the original file (durable; carries into spawned work)
    byte_size      int,                        -- bytes length (for listings without reading the blob)
    extracted_text text,                       -- for documents: the extracted text injected as a text part (P3)
    consumed_at    timestamptz,               -- first turn that injected it (informational)
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chat_attachments_session_idx
    ON stewards.chat_attachments (session_id, id);

COMMENT ON TABLE stewards.chat_attachments IS
'48: durable session-scoped media attached to a Stewdio chat as injectable subject material. bytes (bytea) carry with the session + into spawned work; chat_attachment_parts() assembles them into the 47 content_parts array a vision model sees. P2 = images; P3 populates extracted_text for documents.';

-- ── chat_attachment_parts: build the multimodal content array from stored bytes.
-- Scoped to p_session_id so a turn can only inject its own session's attachments
-- (no cross-session leak). Images -> an image_url part with an inline data URL
-- built server-side from the bytea; documents with extracted_text -> a text part.
-- Marks consumed_at on first injection (informational). Returns NULL when nothing
-- resolves, so dispatch_chat_turn falls back to the text-only path.
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

    SELECT jsonb_agg(
        CASE
            WHEN a.kind = 'image' AND a.bytes IS NOT NULL THEN
                jsonb_build_object(
                    'type', 'image_url',
                    -- encode(...,'base64') MIME-wraps at 76 chars with newlines; a data
                    -- URL must be unwrapped or the model fails to load the image.
                    'image_url', jsonb_build_object(
                        'url', 'data:' || coalesce(a.mime_type, 'image/png')
                               || ';base64,' || translate(encode(a.bytes, 'base64'), E'\n\r', '')))
            WHEN a.kind = 'document' AND a.extracted_text IS NOT NULL THEN
                jsonb_build_object(
                    'type', 'text',
                    'text', '[Attached document: ' || coalesce(a.filename, 'document')
                            || E']\n' || a.extracted_text)
            ELSE NULL
        END
        ORDER BY a.id)
      INTO v_parts
      FROM stewards.chat_attachments a
     WHERE a.id = ANY(p_ids)
       AND a.session_id = p_session_id;

    -- jsonb_agg keeps NULLs as JSON null entries; strip them so the array is clean.
    SELECT jsonb_agg(e) INTO v_parts
      FROM jsonb_array_elements(coalesce(v_parts, '[]'::jsonb)) e
     WHERE jsonb_typeof(e) <> 'null';

    -- mark consumed (first injection only)
    UPDATE stewards.chat_attachments
       SET consumed_at = now()
     WHERE id = ANY(p_ids) AND session_id = p_session_id AND consumed_at IS NULL;

    RETURN v_parts;  -- NULL when nothing resolved
END;
$fn$;

COMMENT ON FUNCTION stewards.chat_attachment_parts(bigint[], text) IS
'48: assemble the 47 content_parts array from this session''s attachments (images -> an inline-data-URL image_url part built server-side from the bytea; documents -> a text part from extracted_text). Session-scoped (no cross-session injection). Marks consumed_at. NULL when nothing resolves. The base64 is built in the DB — it never round-trips through the app.';

-- =====================================================================
-- End of 48-chat-attachments.sql
-- =====================================================================
