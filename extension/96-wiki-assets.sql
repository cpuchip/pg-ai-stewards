-- =====================================================================
-- 96-wiki-assets.sql — PDF/web images as addressable, embeddable wiki assets.
-- =====================================================================
-- Michael's ask (2026-07-03, the 6-builder wiki fleet): "any source we give
-- it with images, web pages, pdfs (like our ttrpg rule books) could pull all
-- those out and make them usable in the wiki." This file is the WIKI-ASSETS
-- builder's slice: the substrate glue around stewards.wiki_assets, a table
-- OWNED by WIKI-CORE (92-wiki.sql) — not created here.
--
-- RECONCILIATION NOTE (this file was authored in an isolated worktree
-- against a SKETCHED contract before the fleet's other 5 builders merged;
-- fixed here against the REAL 92-wiki.sql once main showed it):
--   - id is bigserial (bigint), NOT uuid.
--   - doc_id is text (matches stewards.docs.id, itself text), NOT uuid.
--   - there is NO storage_path column. 92's header (deviation #3) is
--     explicit: rich-docs-in-chat (48-chat-attachments.sql, 49-doc-
--     extract.sql) stores media as `bytes bytea` INLINE, with no
--     filesystem-path convention anywhere in this codebase. wiki_assets
--     follows that REAL convention: `bytes bytea` (direct inline storage)
--     PLUS `source_attachment_id bigint` (when the asset ALREADY exists as
--     a stewards.chat_attachments row — e.g. the extractor below writes a
--     child attachment first, exactly like 49's page-image overlay does —
--     so the bytes are never duplicated). This file always takes the
--     source_attachment_id path: every asset it inserts already has a
--     chat_attachments row (created by the Go side, internal/wikiassets),
--     so wiki_assets.bytes stays NULL and the servable URL is derived from
--     source_attachment_id.
--
-- STORAGE / SERVE CONVENTION: an asset's bytes live in stewards.
-- chat_attachments (kind='image') — the SAME bytea-in-DB store 48/49/78 and
-- generate_image already use. The ui/bridge already serves this with no new
-- auth surface: GET /api/chat/attachment/<id> (cmd/stewards-ui/api/chat.go,
-- chatAttachmentHandler). wiki_assets.source_attachment_id IS that id, so
-- the serve URL is always '/api/chat/attachment/' || source_attachment_id —
-- wiki_asset_serve_url() below is the single place that builds it.
--
-- MARKDOWN EMBED CONVENTION: a wiki page embeds an asset as a standard
-- markdown image — `![caption](serve_url)`. wiki_asset_markdown() is the
-- single source of truth for that rendering, so WIKI-CURATOR's page-
-- authoring prompts and the doc viewer agree on the shape without either
-- hand-writing the `![]()` format independently.
--
--   §1  wiki_asset_serve_url(asset_id) / wiki_asset_markdown(asset_id) —
--       the serve + markdown-embed conventions, reading source_attachment_id
--       and caption straight off the row (no argument duplication risk).
--   §2  wiki_asset_caption_enqueue(asset_id) — send an asset's image to the
--       EXISTING vision route (47-multimodal + dispatch_chat_turn's
--       content_parts auto-select) to have a model describe it, writing the
--       reply back via §3. Deliberately rides the pre-existing 'chat'
--       work_queue kind (the same path 47/48 already dispatch through) —
--       NOT a new bgworker kind. A captioning hook is a cheap, optional-path
--       feature; a new Rust bgworker kind is not a cost this file pays for.
--   §3  wiki_asset_caption_collect(asset_id) — non-blocking poll: if the
--       caption session's reply has landed, write it back to both
--       wiki_assets.caption AND the underlying chat_attachments.caption (the
--       78 mechanism — so the SAME image, if it is ever re-attached to a
--       future chat, carries its caption as a vision text-part automatically).
--
-- requires create_model_role_toggles (95) — the true chain tail as merged.
-- =====================================================================

-- ── §1 — the serve URL + markdown embed conventions ───────────────────
-- Single source of truth for "how does a wiki asset become a URL" so no
-- caller (Go, SQL, a future wiki-reader endpoint) reinvents the join.
CREATE OR REPLACE FUNCTION stewards.wiki_asset_serve_url(p_asset_id bigint)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT '/api/chat/attachment/' || source_attachment_id
      FROM stewards.wiki_assets
     WHERE id = p_asset_id AND source_attachment_id IS NOT NULL;
$fn$;

COMMENT ON FUNCTION stewards.wiki_asset_serve_url(bigint) IS
'96: the wiki-assets serve convention — an asset''s bytes live in stewards.chat_attachments (source_attachment_id), served at the EXISTING /api/chat/attachment/<id> endpoint (no new auth surface). NULL when the asset has no source_attachment_id (e.g. bytes were populated directly on this row by some other writer — not a shape this file produces).';

CREATE OR REPLACE FUNCTION stewards.wiki_asset_markdown(p_asset_id bigint)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT '![' || coalesce(replace(caption, ']', ')'), 'wiki asset') || '](' || stewards.wiki_asset_serve_url(id) || ')'
      FROM stewards.wiki_assets
     WHERE id = p_asset_id;
$fn$;

COMMENT ON FUNCTION stewards.wiki_asset_markdown(bigint) IS
'96: the wiki markdown-embed convention for one asset — plain `![caption](serve_url)`. Single source of truth so WIKI-CURATOR''s page-authoring prompts and the doc viewer agree on the shape. caption NULL -> "wiki asset" alt text. NULL result when the asset has no servable URL yet.';

-- ── §2 — wiki_asset_caption_enqueue: the captioning hook ──────────────
-- Resolves the asset's underlying chat_attachments row from
-- source_attachment_id (no path-parsing needed — the real schema carries
-- this as a proper FK), builds a one-shot multimodal content_parts array
-- directly from the stored bytes (the SAME data-URL construction 48/78's
-- chat_attachment_parts uses), and dispatches it into a deterministic
-- per-asset session so a repeat call resumes/collects rather than piling up
-- duplicate turns. dispatch_chat_turn auto-selects the `vision` alias
-- whenever content_parts is non-empty (47 §5) — this is "the existing
-- vision route", not a new one.
CREATE OR REPLACE FUNCTION stewards.wiki_asset_caption_enqueue(p_asset_id bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
    v_attachment_id bigint;
    v_session       text;
    v_parts         jsonb;
    v_wq            bigint;
BEGIN
    SELECT source_attachment_id INTO v_attachment_id
      FROM stewards.wiki_assets
     WHERE id = p_asset_id;

    IF v_attachment_id IS NULL THEN
        RAISE EXCEPTION 'wiki_asset_caption_enqueue: asset % not found or has no source_attachment_id', p_asset_id;
    END IF;

    -- deterministic per-asset session: a re-run resumes the SAME
    -- conversation (chat_post_internal/dispatch_chat_turn is additive), so
    -- calling this twice doesn't multiply cost or spawn duplicate turns.
    v_session := 'wiki-caption-' || p_asset_id::text;

    -- Build the multimodal part directly from the stored bytes (the same
    -- inline-data-URL shape as 48/78's chat_attachment_parts) rather than
    -- calling chat_attachment_parts itself, which is session-scoped to the
    -- attachment's OWN session_id (the doc-extract sandbox's session), not
    -- this fresh captioning session — see chat_attachment_parts' doc comment
    -- ("Scoped to p_session_id so a turn can only inject its own session's
    -- attachments").
    SELECT jsonb_build_array(jsonb_build_object(
               'type', 'image_url',
               'image_url', jsonb_build_object(
                   'url', 'data:' || coalesce(mime_type, 'image/png')
                          || ';base64,' || translate(encode(bytes, 'base64'), E'\n\r', ''))))
      INTO v_parts
      FROM stewards.chat_attachments
     WHERE id = v_attachment_id AND bytes IS NOT NULL;

    IF v_parts IS NULL THEN
        RAISE EXCEPTION 'wiki_asset_caption_enqueue: attachment % has no image bytes', v_attachment_id;
    END IF;

    v_wq := stewards.dispatch_chat_turn(
        v_session,
        'Caption this image for a wiki page in one or two plain sentences. Name concretely what it shows '
        || '(a map, a character portrait, a rules table, a diagram, an item card) and its key visible content. '
        || 'No preamble — the caption text only.',
        'work-item-chat', 'reason', NULL, v_parts);

    RETURN v_wq;
END;
$fn$;

COMMENT ON FUNCTION stewards.wiki_asset_caption_enqueue(bigint) IS
'96: the wiki_asset_caption enqueue — sends a wiki asset''s image to the EXISTING vision route (content_parts + dispatch_chat_turn''s auto-selected vision alias, 47 §5) asking for a one/two-sentence caption. Deliberately rides the pre-existing chat work_queue kind rather than a new bgworker kind (cheap, optional-path feature). Deterministic per-asset session (wiki-caption-<id>) so a repeat call resumes rather than duplicating. Pair with wiki_asset_caption_collect to harvest the reply once the bgworker answers.';

-- ── §3 — wiki_asset_caption_collect: harvest the reply ────────────────
-- Non-blocking (a SQL function must never block on an async bgworker turn):
-- checks whether the caption session already has an assistant reply; if so,
-- writes it back to wiki_assets.caption AND chat_attachments.caption (the 78
-- mechanism, so the same image re-attached to ANY future chat carries its
-- caption as a vision text-part automatically) and returns true. Idempotent
-- and safe to poll on a cadence (a Go caller does the actual waiting).
CREATE OR REPLACE FUNCTION stewards.wiki_asset_caption_collect(p_asset_id bigint)
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
    v_attachment_id bigint;
    v_session       text := 'wiki-caption-' || p_asset_id::text;
    v_caption       text;
BEGIN
    SELECT source_attachment_id INTO v_attachment_id
      FROM stewards.wiki_assets
     WHERE id = p_asset_id;
    IF v_attachment_id IS NULL THEN
        RETURN false;
    END IF;

    SELECT btrim(content) INTO v_caption
      FROM stewards.messages
     WHERE session_id = v_session AND role = 'assistant' AND coalesce(content, '') <> ''
     ORDER BY id DESC
     LIMIT 1;

    IF v_caption IS NULL OR v_caption = '' THEN
        RETURN false; -- not answered yet (or never enqueued) — caller polls again later
    END IF;

    UPDATE stewards.wiki_assets SET caption = v_caption WHERE id = p_asset_id;
    UPDATE stewards.chat_attachments SET caption = v_caption WHERE id = v_attachment_id;
    RETURN true;
END;
$fn$;

COMMENT ON FUNCTION stewards.wiki_asset_caption_collect(bigint) IS
'96: non-blocking harvest for wiki_asset_caption_enqueue — if the deterministic wiki-caption-<id> session already has an assistant reply, writes it to wiki_assets.caption AND chat_attachments.caption (so the image carries its caption into any future chat re-render, 78) and returns true; otherwise false (not answered yet). Safe to poll.';

-- =====================================================================
-- End of 96-wiki-assets.sql
-- =====================================================================
