-- =====================================================================
-- 78-yt-slide-frames.sql — captioned vision frames: a slide + the words over it.
-- =====================================================================
-- Part B of .spec/proposals/yt-slide-frames.md (Part A = the workspace yt-MCP's
-- yt_frames/yt_download_video/yt_slides; the OSS bridge gained them WITH_YT=1,
-- now ffmpeg-equipped). This is the substrate side: teach the EXISTING vision
-- mechanism (47 multimodal + 49 doc-extract page-images) to read a slide frame
-- ALONGSIDE the transcript narration spoken over it — the rich-docs pattern
-- (text + page-pixels → a vision model) applied to video.
--
-- The only NEW generic capability vs. 49 is a CAPTION on an image attachment:
--   §1  chat_attachments.caption — text associated with an image (e.g. the
--       transcript narration spoken over a slide frame). Additive, NULL default.
--   §2  chat_attachment_parts re-authored (later-file-wins over 49) — a captioned
--       image emits its caption as a TEXT part IMMEDIATELY BEFORE its image_url
--       part, so the vision model reads "this slide + what was said over it."
--       Everything else is 49's body verbatim. 78 NOW OWNS chat_attachment_parts.
--   §3  align_slide_captions(frames, cues) — the pure, deterministic alignment:
--       for each frame, the narration = the transcript cues spoken between this
--       frame and the next (frames.json × cues.json). The frame↔cue join the
--       digester needs, written once, server-side, testable without a video.
--
-- The frame INGESTION itself (reading the bridge /yt volume's PNG bytes into
-- captioned image attachments) is OPERATOR glue that needs the yt overlay's /yt
-- mount, so — exactly like import_yt_transcript — it ships in the EXAMPLE
-- (examples/yt-transcripts.sql: import_yt_frames + the slide-read digest tool),
-- NOT in this core file. Core gives the generic mechanism; the overlay wires the
-- source.
--
-- LOAD-BEARING ORACLE: an image with no caption renders byte-identically to 49
-- (the §2 caption branch is skipped when caption IS NULL — the NULL-caption case
-- IS the off state, exactly like 47's content_parts-NULL identity). A virgin
-- install never sets a caption, so chat_attachment_parts is unchanged.
--
-- requires create_tool_shelf (77 = chain head). Also lists create_doc_extract
-- (49) explicitly: 78 re-authors chat_attachment_parts, and for 78's version to
-- WIN, cargo-pgrx must sort 78 AFTER 49. 77 is a transitive descendant of 49, but
-- the 2026-06-24 lesson (47's header) is that an under-constrained sort can
-- silently revert a re-authored function — so the edge is named, not assumed.
-- =====================================================================

-- ── §1 — caption: text associated with an image attachment ───────────
ALTER TABLE stewards.chat_attachments
    ADD COLUMN IF NOT EXISTS caption text;

COMMENT ON COLUMN stewards.chat_attachments.caption IS
'78: text associated with an IMAGE attachment — e.g. the transcript narration spoken over a slide frame. When set, chat_attachment_parts emits it as a text part immediately BEFORE the image_url part, so a vision model reads the slide AND the words over it. NULL (the default) ⇒ the image renders exactly as 49 (no caption part). Generic: any captioned image (not just yt frames) interleaves this way.';

-- ── §2 — chat_attachment_parts: caption text-part before the image ───
-- Re-authored (78 now owns it; later-file-wins over 49). The ONLY change vs. 49
-- is that a captioned image is expanded into TWO ordered parts — the caption
-- (subord 0) then the image (subord 1) — so the narration precedes its slide.
-- Uncaptioned images, documents (text / doc_extract nudge), the parent-document
-- page-image overlay, session scoping, and consumed_at marking are all 49's
-- behavior verbatim. NULL/blank caption ⇒ no caption part ⇒ byte-identical to 49.
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
        -- 78: the caption text-part for a captioned image — ordered (subord 0)
        -- immediately before its image (subord 1) so the words precede the slide.
        SELECT
            jsonb_build_object('type', 'text', 'text', w.caption) AS part,
            coalesce(w.parent_id, w.id) AS grp,
            (w.parent_id IS NOT NULL)   AS is_child,
            w.id                        AS oid,
            0                           AS subord
          FROM wanted w
         WHERE w.kind = 'image' AND w.bytes IS NOT NULL
           AND w.caption IS NOT NULL AND length(btrim(w.caption)) > 0
        UNION ALL
        -- 49's primary part for every attachment (image_url / doc text / doc nudge).
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
            w.id                        AS oid,
            1                           AS subord        -- the body part follows its caption
          FROM wanted w
    )
    SELECT jsonb_agg(part ORDER BY grp, is_child, oid, subord)
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
'78 (was 49): assemble the 47 content_parts array from this session''s attachments. Images → image_url (server-built data URL); documents → their extracted_text (or a doc_extract nudge); a referenced document''s page images ride along as the pixel overlay. 78 adds the caption: a captioned image emits its caption as a text part immediately before its image (the slide + the words over it). Session-scoped, marks consumed, NULL when nothing resolves. Byte-identical to 49 when no attachment carries a caption.';

-- ── §3 — align_slide_captions(frames, cues): the frame↔cue alignment ─
-- Pure, deterministic, IMMUTABLE. Given frames.json ([{sec,file,t_link}]) and
-- cues.json ([{begin,end,text}]), attach to each frame the narration spoken over
-- it = every cue whose begin falls in [this frame's sec, the next frame's sec).
-- Returns the frames with a "narration" field added (ordered by sec). This is the
-- alignment the digester needs ("this slide + what was said over it") written
-- once server-side, testable without a video or a vision model. The yt example
-- calls this to build each slide attachment's caption.
CREATE OR REPLACE FUNCTION stewards.align_slide_captions(p_frames jsonb, p_cues jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $fn$
    WITH f AS (
        SELECT (fr->>'sec')::numeric AS sec,
               fr->>'file'           AS file,
               fr->>'t_link'         AS t_link,
               lead((fr->>'sec')::numeric)
                   OVER (ORDER BY (fr->>'sec')::numeric) AS next_sec
          FROM jsonb_array_elements(coalesce(p_frames, '[]'::jsonb)) fr
    ),
    aligned AS (
        SELECT f.sec, f.file, f.t_link,
               (SELECT string_agg(c->>'text', ' ' ORDER BY (c->>'begin')::numeric)
                  FROM jsonb_array_elements(coalesce(p_cues, '[]'::jsonb)) c
                 WHERE (c->>'begin')::numeric >= f.sec
                   AND (f.next_sec IS NULL OR (c->>'begin')::numeric < f.next_sec)
               ) AS narration
          FROM f
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'sec',       sec,
               'file',      file,
               't_link',    t_link,
               'narration', coalesce(btrim(narration), '')
           ) ORDER BY sec), '[]'::jsonb)
      FROM aligned;
$fn$;

COMMENT ON FUNCTION stewards.align_slide_captions(jsonb, jsonb) IS
'78: align extracted video frames (frames.json [{sec,file,t_link}]) to the transcript (cues.json [{begin,end,text}]) — each frame gets a "narration" field = the cue text spoken between it and the next frame ([sec, next_sec)). Pure/IMMUTABLE; the deterministic frame↔cue join the slide digester reads to caption each slide image.';

-- =====================================================================
-- End of 78-yt-slide-frames.sql
-- =====================================================================
