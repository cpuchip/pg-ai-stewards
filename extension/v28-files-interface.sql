-- =====================================================================
-- v28-files-interface.sql — files as interface, DB as engine (Layer 3):
--   ingest-by-drop + the knowledge projection tree.
-- =====================================================================
-- The two ratified files-interface increments from the lightening
-- verdict (.spec/proposals/files-as-interface-db-as-engine.md, ratified
-- 2026-07-07, four-layer ruling Layer 3): "prose = FILES — projected
-- FROM rows, authored IN files, ingested BY trigger." Item 6 of the
-- lightening batch names both halves shipped here:
--
--   * INGEST-BY-DROP — a drop directory whose ingest stamps provenance.
--     The bridge's drop watcher (cmd/stewards-mcp/dropwatcher.go) scans
--     STEWARDS_DROP_DIR and calls file_drop_ingest / _binary below; the
--     stewards.file_drops table is the provenance ledger the ruling
--     demands. The freshness principle from the same panel is binding
--     design input: a re-drop with a NEW sha for a known path is a
--     FRESHNESS UPDATE (re-ingest through import_doc's ON CONFLICT(slug)
--     DO UPDATE, which fires touch_doc and archives the prior revision
--     into stewards.doc_versions — the existing doc-update idiom, not a
--     new one). A re-drop with the SAME sha is skipped_unchanged.
--
--   * KNOWLEDGE PROJECTION TREE — wiki pages, pooled docs, and lessons
--     projected as a greppable, PR-able markdown tree under
--     STEWARDS_KNOWLEDGE_DIR. The projection CATALOG lives here in SQL
--     (knowledge_projection_pending / _record / _forget); the file
--     WRITING is the bridge's job (cmd/stewards-mcp/projector.go),
--     mirroring the ratified autonomous-materializer split (bridge-side
--     Go goroutine, LISTEN/NOTIFY + safety poll, path-validated writes
--     — .spec/proposals/autonomous-materializer.md, D-AM-1..3).
--
-- LINEAGE — this idea predates the substrate. The founding research
-- verdict (pg-ai-stewards docs/history/2026-05-02-research-verdict.md)
-- said it plainly before any schema existed: ".mind/ markdown files
-- remain useful for git history and human readability — but they become
-- *projections* of canonical rows, not the canonical store." v28 is
-- that sentence, shipped: rows stay canonical, files are the interface.
--
-- LIFELESS-CORE COMPLIANCE (v27, "default is no models"): nothing in
-- this file names a model or a provider. Ingest of plain markdown/text
-- works with ZERO models configured — the docs row lands, provenance is
-- stamped, and embedding/extraction ride the EXISTING triggers, which
-- already degrade gracefully per v27 §2 (an unembedded doc is a doc,
-- not an error). The binary path enqueues the deterministic doc-extract
-- capability (bridge-side Go, no model involved); absent the
-- doc-extract overlay the failure is recorded honestly in the ledger by
-- file_drop_reconcile, never silently.
--
-- HONEST LIMITATIONS, named up front (same discipline as v20's header):
--   * knowledge_projection_pending detects change via updated_at with a
--     content-sha disjunct as the correctness anchor (now() is
--     transaction-constant, so a same-transaction edit can leave
--     updated_at EQUAL to the watermark — the sha catches it; proven in
--     virgin-smoke OK 108). A docs.project_association change alone
--     bumps neither (touch_doc only fires on title/body/frontmatter, and
--     the sha is over the body), so a pure "project moved" edit
--     reprojects only after the next content touch.
--   * Two sources CAN sanitize to the same target_path (slug collision
--     across projects). The state table keys on (source_kind, source_id)
--     so both are tracked; on disk the last writer wins. Collisions are
--     visible by querying knowledge_projections GROUP BY target_path.
--   * ONE-WAY v1: the knowledge tree is never read back. The drop
--     directory is the write path (the ruling's "authored IN files,
--     ingested BY trigger" — the drop watcher is that trigger).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — stewards.file_drops: the ingest-by-drop provenance ledger.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.file_drops (
    id             bigserial PRIMARY KEY,
    path           text NOT NULL,     -- relative to the drop root, forward slashes
    sha256         text NOT NULL,     -- hex sha256 of the dropped bytes
    size_bytes     bigint,
    project_hint   text,              -- first path segment under the drop root (drop/work-corpus/x.md -> work-corpus); NULL for root files
    routed_to      text,              -- where it went: 'doc:<id> slug:<slug>' | 'corpus:<name> attachment:<id>' | ...
    attachment_id  bigint REFERENCES stewards.chat_attachments(id) ON DELETE SET NULL,  -- binary drops: the durable bytes
    work_queue_id  bigint,            -- binary drops: the mcp_proxy extract row (no FK — work_queue rows may be pruned)
    status         text NOT NULL DEFAULT 'error'
                   CHECK (status IN ('ingested', 'skipped_unchanged', 'error')),
    error          text,
    first_seen_at  timestamptz NOT NULL DEFAULT now(),
    ingested_at    timestamptz,
    UNIQUE (path, sha256)              -- re-drops with new content are natural new rows; same content is one row
);

CREATE INDEX IF NOT EXISTS file_drops_path_idx   ON stewards.file_drops (path, first_seen_at DESC);
CREATE INDEX IF NOT EXISTS file_drops_status_idx ON stewards.file_drops (status);

COMMENT ON TABLE stewards.file_drops IS
'v28: the ingest-by-drop provenance ledger (files-as-interface Layer 3). One row per (path, sha256) seen under the drop root — a re-drop with changed content is a NEW row (the freshness update); the same content is the same row (skipped). status=error rows carry why; the bridge retries them on the next sighting.';
COMMENT ON COLUMN stewards.file_drops.project_hint IS
'v28: first path segment under the drop root (drop/work-corpus/x.md -> work-corpus). Becomes docs.project_association on the pooled doc / the corpus_name on a binary extract. NULL for files dropped at the root.';
COMMENT ON COLUMN stewards.file_drops.work_queue_id IS
'v28: binary drops only — the kind=mcp_proxy work_queue row that carries the doc_import_corpus extract. file_drop_reconcile() reads its outcome back into this ledger.';

-- ---------------------------------------------------------------------
-- §2 — stewards.knowledge_projections: projection state (incremental
--       re-projection + future conflict detection).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.knowledge_projections (
    source_kind        text NOT NULL,   -- 'wiki_page' | 'doc' | 'lesson' (open taxonomy, same philosophy as docs.kind)
    source_id          text NOT NULL,   -- wiki_pages.id::text | docs.id | lessons.id::text
    target_path        text NOT NULL,   -- relative to the knowledge root, forward slashes ('wiki/<scope>/<slug>.md')
    source_updated_at  timestamptz,     -- the source row's updated_at AT projection time (the freshness watermark)
    content_sha        text,            -- sha256 of the projected body AT projection time (future conflict detection)
    projected_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source_kind, source_id)
);

CREATE INDEX IF NOT EXISTS knowledge_projections_path_idx ON stewards.knowledge_projections (target_path);

COMMENT ON TABLE stewards.knowledge_projections IS
'v28: which rows have been projected into the knowledge tree, and at what watermark. Enables incremental projection (knowledge_projection_pending only returns rows newer than their watermark) and future drift/conflict detection (content_sha vs what is on disk). The bridge''s projector owns the file I/O; this table owns the truth about what was projected when.';

-- ---------------------------------------------------------------------
-- §3 — private helpers: filesystem-safe segments + drop-path slugs.
-- ---------------------------------------------------------------------
-- _files_safe_seg: one path segment -> lowercase [a-z0-9_-] only, runs of
-- anything else collapse to '-'. '..' cannot survive (dots are replaced),
-- so a projected target path can never traverse upward. Empty -> 'unfiled'.
CREATE OR REPLACE FUNCTION stewards._files_safe_seg(p_raw text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT coalesce(
        nullif(btrim(regexp_replace(lower(coalesce(p_raw, '')), '[^a-z0-9_-]+', '-', 'g'), '-'), ''),
        'unfiled');
$fn$;
COMMENT ON FUNCTION stewards._files_safe_seg(text) IS
'v28: private helper (underscore prefix, per the 91/15b convention). Sanitize one path segment for the knowledge tree: lowercase, [a-z0-9_-] only, never empty, can never contain ''.'' (so ''..'' traversal is structurally impossible).';

-- _file_drop_slug: a drop path -> a stable docs.slug. Extension stripped,
-- whole path (directories included) collapsed to one safe segment, so
-- 'work-corpus/Notes/Meeting 1.md' -> 'work-corpus-notes-meeting-1' and a re-drop of
-- the same path always lands on the same doc (the freshness update).
CREATE OR REPLACE FUNCTION stewards._file_drop_slug(p_path text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT stewards._files_safe_seg(
        regexp_replace(coalesce(p_path, ''), '\.(md|markdown|txt)\s*$', '', 'i'));
$fn$;
COMMENT ON FUNCTION stewards._file_drop_slug(text) IS
'v28: private helper. Drop path -> stable docs.slug (extension stripped, path-scoped, sanitized). Stability per path is what makes a re-drop an UPDATE of the same doc rather than a sibling.';

-- ---------------------------------------------------------------------
-- §4 — file_drop_ingest: text drops (md/txt) -> the docs pool, through
--       the EXISTING import_doc path, provenance stamped.
-- ---------------------------------------------------------------------
-- Routing choice, documented: route_intake (v22) is the model-driven
-- router (classify->match pipeline stages); under the lifeless core it
-- parks awaiting_review with no models configured. The drop directory's
-- contract is stronger — a plain markdown drop must LAND with zero
-- models — so text drops take the deterministic import_doc path (the
-- same one doc_finalize/34, the crawler/98, and doc_import_corpus
-- already use), which pools the doc + syncs the CITES graph with no
-- model anywhere. An operator who wants model-driven routing for a
-- specific drop can still call route_intake('file', <doc slug>, ...)
-- on the pooled result.
--
-- Never RAISEs to the caller (the 94/100 tool-surface convention):
-- errors come back as {"ok":false,...} AND land on the ledger row.
CREATE OR REPLACE FUNCTION stewards.file_drop_ingest(
    p_path         text,
    p_content      text,
    p_project_hint text DEFAULT NULL,
    p_sha          text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_path      text := ltrim(regexp_replace(btrim(coalesce(p_path, '')), '^\./', ''), '/');
    v_sha       text;
    v_hint      text := nullif(btrim(coalesce(p_project_hint, '')), '');
    v_slug      text;
    v_title     text;
    v_doc_id    text;
    v_drop_id   bigint;
    v_status    text;
    v_routed    text;
    v_prior_sha text;
    v_fm        jsonb;
BEGIN
    IF v_path = '' THEN
        RETURN jsonb_build_object('ok', false, 'status', 'error', 'error', 'path is required');
    END IF;
    IF p_content IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'status', 'error', 'error', 'content is required (text drops carry content inline)');
    END IF;

    v_sha := lower(coalesce(nullif(btrim(coalesce(p_sha, '')), ''),
                            encode(sha256(convert_to(p_content, 'UTF8')), 'hex')));

    -- Same (path, sha) already ingested -> the freshness principle's
    -- cheap half: nothing changed, skip (no new ledger row).
    SELECT fd.id, fd.status, fd.routed_to INTO v_drop_id, v_status, v_routed
      FROM stewards.file_drops fd WHERE fd.path = v_path AND fd.sha256 = v_sha;
    IF v_drop_id IS NOT NULL AND v_status = 'ingested' THEN
        RETURN jsonb_build_object('ok', true, 'status', 'skipped_unchanged',
                                  'drop_id', v_drop_id, 'routed_to', v_routed);
    END IF;

    -- A prior INGESTED sha for this path means this call is the
    -- freshness update — record which revision it supersedes.
    SELECT fd.sha256 INTO v_prior_sha
      FROM stewards.file_drops fd
     WHERE fd.path = v_path AND fd.status = 'ingested' AND fd.sha256 <> v_sha
     ORDER BY fd.ingested_at DESC NULLS LAST LIMIT 1;

    -- Ledger row FIRST (provenance survives even a routing failure).
    IF v_drop_id IS NULL THEN
        INSERT INTO stewards.file_drops (path, sha256, size_bytes, project_hint, status, error)
        VALUES (v_path, v_sha, length(convert_to(p_content, 'UTF8')), v_hint,
                'error', 'ingest did not complete')
        RETURNING id INTO v_drop_id;
    ELSE
        UPDATE stewards.file_drops
           SET project_hint = coalesce(v_hint, project_hint),
               status = 'error', error = 'ingest did not complete (retry)'
         WHERE id = v_drop_id;
    END IF;

    BEGIN
        v_slug  := stewards._file_drop_slug(v_path);
        v_title := btrim(coalesce(
            (regexp_match(p_content, '^#\s+(.+?)\s*$', 'n'))[1],
            regexp_replace(regexp_replace(v_path, '^.*/', ''), '\.(md|markdown|txt)\s*$', '', 'i')));

        v_fm := jsonb_strip_nulls(jsonb_build_object(
            'origin',         'file-drop',
            'drop_path',      v_path,
            'drop_sha256',    v_sha,
            'project_hint',   v_hint,
            'superseded_sha', v_prior_sha));

        -- The EXISTING pool path: import_doc upserts by slug (a re-drop
        -- fires touch_doc -> prior revision archived in doc_versions),
        -- syncs the CITES graph, and the docs embed trigger rides along
        -- (degrading to unembedded under the lifeless core, v27 §2).
        v_doc_id := stewards.import_doc(v_slug, v_path, v_title, p_content, v_fm, 'doc');

        UPDATE stewards.docs
           SET source_type = 'file-drop',
               project_association = coalesce(v_hint, project_association)
         WHERE id = v_doc_id;

        UPDATE stewards.file_drops
           SET status = 'ingested', error = NULL, ingested_at = now(),
               routed_to = 'doc:' || v_doc_id || ' slug:' || v_slug
         WHERE id = v_drop_id;
    EXCEPTION WHEN OTHERS THEN
        UPDATE stewards.file_drops
           SET status = 'error', error = left(SQLERRM, 2000)
         WHERE id = v_drop_id;
        RETURN jsonb_build_object('ok', false, 'status', 'error',
                                  'drop_id', v_drop_id, 'error', SQLERRM);
    END;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ok', true, 'status', 'ingested', 'drop_id', v_drop_id,
        'doc_id', v_doc_id, 'doc_slug', v_slug,
        'superseded_sha', v_prior_sha));
END;
$fn$;

COMMENT ON FUNCTION stewards.file_drop_ingest(text, text, text, text) IS
'v28: ingest a TEXT drop (md/txt) into the docs pool via the existing import_doc path, provenance stamped (frontmatter.origin=file-drop + docs.source_type + the file_drops ledger row). Same (path,sha) already ingested -> skipped_unchanged. New sha for a known path -> the freshness update: import_doc''s ON CONFLICT(slug) upsert fires touch_doc, archiving the prior revision into doc_versions — the substrate''s existing update idiom. Works with ZERO models configured (embedding degrades per v27). Never RAISEs; errors land on the ledger row and in the returned jsonb.';

-- ---------------------------------------------------------------------
-- §5 — file_drop_ingest_binary: binary drops (pdf/docx/zip/images) ->
--       the EXISTING attachment/extract/corpus path (rich-docs v10).
-- ---------------------------------------------------------------------
-- Exactly what a chat upload does: bytes land durable in
-- chat_attachments (kind=document), then doc_import_corpus (the
-- doc-extract MCP tool — deterministic bridge-side Go, no model) unpacks
-- and pools each member as a searchable doc tagged with the corpus name.
-- The enqueue is mcp_proxy_enqueue — the same soft-fail child-row path
-- the bgworker itself uses. Needs the docker-compose.doc-extract.yaml
-- overlay to actually extract; absent it, the extract errors CLEARLY and
-- file_drop_reconcile() writes that outcome back onto the ledger row
-- (the bytes stay safe in the attachment either way).
CREATE OR REPLACE FUNCTION stewards.file_drop_ingest_binary(
    p_path         text,
    p_bytes        bytea,
    p_mime         text DEFAULT NULL,
    p_project_hint text DEFAULT NULL,
    p_sha          text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_path    text := ltrim(regexp_replace(btrim(coalesce(p_path, '')), '^\./', ''), '/');
    v_sha     text;
    v_hint    text := nullif(btrim(coalesce(p_project_hint, '')), '');
    v_corpus  text;
    v_att     bigint;
    v_wq      bigint;
    v_drop_id bigint;
    v_status  text;
    v_routed  text;
BEGIN
    IF v_path = '' THEN
        RETURN jsonb_build_object('ok', false, 'status', 'error', 'error', 'path is required');
    END IF;
    IF p_bytes IS NULL OR length(p_bytes) = 0 THEN
        RETURN jsonb_build_object('ok', false, 'status', 'error', 'error', 'bytes are required');
    END IF;

    v_sha := lower(coalesce(nullif(btrim(coalesce(p_sha, '')), ''),
                            encode(sha256(p_bytes), 'hex')));

    SELECT fd.id, fd.status, fd.routed_to INTO v_drop_id, v_status, v_routed
      FROM stewards.file_drops fd WHERE fd.path = v_path AND fd.sha256 = v_sha;
    IF v_drop_id IS NOT NULL AND v_status = 'ingested' THEN
        RETURN jsonb_build_object('ok', true, 'status', 'skipped_unchanged',
                                  'drop_id', v_drop_id, 'routed_to', v_routed);
    END IF;

    IF v_drop_id IS NULL THEN
        INSERT INTO stewards.file_drops (path, sha256, size_bytes, project_hint, status, error)
        VALUES (v_path, v_sha, length(p_bytes), v_hint, 'error', 'ingest did not complete')
        RETURNING id INTO v_drop_id;
    ELSE
        UPDATE stewards.file_drops
           SET project_hint = coalesce(v_hint, project_hint),
               status = 'error', error = 'ingest did not complete (retry)'
         WHERE id = v_drop_id;
    END IF;

    BEGIN
        v_corpus := coalesce(v_hint, 'file-drop');

        INSERT INTO stewards.chat_attachments
            (session_id, filename, mime_type, kind, bytes, byte_size)
        VALUES ('file-drop', regexp_replace(v_path, '^.*/', ''),
                coalesce(nullif(btrim(coalesce(p_mime, '')), ''), 'application/octet-stream'),
                'document', p_bytes, length(p_bytes))
        RETURNING id INTO v_att;

        -- The existing extract/corpus path (soft-fail: NULL when the
        -- doc-extract server row is disabled/unregistered).
        v_wq := stewards.mcp_proxy_enqueue(
            'doc-extract', 'doc_import_corpus',
            jsonb_build_object('attachment_id', v_att, 'corpus_name', v_corpus),
            NULL);

        IF v_wq IS NULL THEN
            UPDATE stewards.file_drops
               SET status = 'error', attachment_id = v_att,
                   routed_to = 'attachment:' || v_att,
                   error = 'doc-extract MCP server not registered/enabled — binary drop stored as attachment ' || v_att
                        || ' but not extracted (enable the doc-extract overlay, then re-drop)'
             WHERE id = v_drop_id;
            RETURN jsonb_build_object('ok', false, 'status', 'error', 'drop_id', v_drop_id,
                                      'attachment_id', v_att,
                                      'error', 'doc-extract server not available');
        END IF;

        UPDATE stewards.file_drops
           SET status = 'ingested', error = NULL, ingested_at = now(),
               attachment_id = v_att, work_queue_id = v_wq,
               routed_to = 'corpus:' || v_corpus || ' attachment:' || v_att
         WHERE id = v_drop_id;
    EXCEPTION WHEN OTHERS THEN
        UPDATE stewards.file_drops
           SET status = 'error', error = left(SQLERRM, 2000)
         WHERE id = v_drop_id;
        RETURN jsonb_build_object('ok', false, 'status', 'error',
                                  'drop_id', v_drop_id, 'error', SQLERRM);
    END;

    RETURN jsonb_build_object('ok', true, 'status', 'ingested', 'drop_id', v_drop_id,
                              'attachment_id', v_att, 'work_queue_id', v_wq,
                              'corpus', v_corpus);
END;
$fn$;

COMMENT ON FUNCTION stewards.file_drop_ingest_binary(text, bytea, text, text, text) IS
'v28: ingest a BINARY drop (pdf/docx/zip/...) through the EXISTING rich-docs path: bytes -> chat_attachments (durable), then mcp_proxy_enqueue(doc-extract, doc_import_corpus) pools the extracted members tagged with the project hint as corpus_name. Deterministic end to end (doc-extract is bridge-side Go — no model). Requires the doc-extract overlay to actually extract; without it the outcome lands honestly on the ledger via file_drop_reconcile(). Never RAISEs.';

-- ---------------------------------------------------------------------
-- §6 — file_drop_reconcile: read extract outcomes back onto the ledger.
-- ---------------------------------------------------------------------
-- The binary path is async (the bridge drains the mcp_proxy row on its
-- own clock). This pulls failures back onto file_drops so the ledger
-- never claims 'ingested' for an extract that actually died — the
-- freshness panel's rule that staleness/failure must FLAG, not hide.
-- The bridge's drop watcher calls this once per scan pass.
CREATE OR REPLACE FUNCTION stewards.file_drop_reconcile()
RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE
    v_n int;
BEGIN
    UPDATE stewards.file_drops fd
       SET status = 'error',
           error  = left(coalesce(wq.error,
                                  wq.result ->> 'content',
                                  'doc_import_corpus failed (no detail on the work_queue row)'), 2000)
      FROM stewards.work_queue wq
     WHERE fd.work_queue_id = wq.id
       AND fd.status = 'ingested'
       AND (wq.status = 'error'
            OR (wq.status = 'done' AND (wq.result ->> 'isError')::boolean IS TRUE));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$fn$;

COMMENT ON FUNCTION stewards.file_drop_reconcile() IS
'v28: flip ledger rows whose async doc_import_corpus extract errored (work_queue status=error, or done with isError=true) to status=error with the failure text. Returns how many rows flipped. Called by the bridge''s drop watcher each scan pass; idempotent.';

-- ---------------------------------------------------------------------
-- §7 — knowledge_projection_pending: the projection catalog.
-- ---------------------------------------------------------------------
-- Returns every row needing (re)projection into the knowledge tree,
-- plus 'delete' rows for projections whose source vanished (or fell out
-- of scope — a superseded wiki page, a doc whose kind left the config).
-- Layout (relative to the knowledge root; the bridge joins the dir):
--   wiki/<scope-or-collection>/<slug>.md    (scope = first wiki membership)
--   docs/<project>/<slug>.md                (project = project_association)
--   lessons/lesson-<id>-<kind>.md
-- Which doc kinds project is operator-owned config
-- (knowledge_projection.doc_kinds, default ["doc","study"] — the pool +
-- study kinds; crawl-page and other bulk kinds stay DB-side by default).
CREATE OR REPLACE FUNCTION stewards.knowledge_projection_pending()
RETURNS TABLE (
    action            text,        -- 'project' | 'delete'
    source_kind       text,        -- 'wiki_page' | 'doc' | 'lesson'
    source_id         text,
    target_path       text,        -- relative, forward slashes, sanitized segments
    title             text,
    body              text,
    project           text,
    source_updated_at timestamptz,
    content_sha       text
) LANGUAGE sql STABLE AS $fn$
WITH doc_kinds AS (
    SELECT coalesce(array_agg(t.k), ARRAY['doc','study']) AS kinds
      FROM jsonb_array_elements_text(
               stewards.config_get('knowledge_projection.doc_kinds',
                                   '["doc","study"]'::jsonb)) AS t(k)
)
-- live wiki pages, new or newer than their watermark
SELECT 'project', 'wiki_page', wp.id::text,
       'wiki/' || stewards._files_safe_seg(wk.slug) || '/'
                || stewards._files_safe_seg(wp.slug) || '.md',
       wp.title, wp.content, wk.slug, wp.updated_at,
       encode(sha256(convert_to(coalesce(wp.content, ''), 'UTF8')), 'hex')
  FROM stewards.wiki_pages wp
  LEFT JOIN LATERAL (
       SELECT w.slug FROM stewards.wiki_members m
         JOIN stewards.wikis w ON w.id = m.wiki_id
        WHERE m.page_id = wp.id
        ORDER BY m.added_at, w.slug LIMIT 1) wk ON true
  LEFT JOIN stewards.knowledge_projections kp
         ON kp.source_kind = 'wiki_page' AND kp.source_id = wp.id::text
 WHERE wp.status = 'live'
   AND (kp.source_id IS NULL
        OR wp.updated_at > kp.source_updated_at
        -- sha is the correctness anchor: now() is transaction-constant, so
        -- an edit in the same transaction as the previous projection pass
        -- leaves updated_at EQUAL to the watermark — the timestamp check
        -- alone would go blind to it. Equal sha keeps the pass quiet.
        OR encode(sha256(convert_to(coalesce(wp.content, ''), 'UTF8')), 'hex')
           IS DISTINCT FROM kp.content_sha)

UNION ALL
-- pooled docs of the configured kinds
SELECT 'project', 'doc', d.id,
       'docs/' || stewards._files_safe_seg(d.project_association) || '/'
                || stewards._files_safe_seg(d.slug) || '.md',
       d.title, d.body, d.project_association, d.updated_at,
       encode(sha256(convert_to(coalesce(d.body, ''), 'UTF8')), 'hex')
  FROM stewards.docs d
  LEFT JOIN stewards.knowledge_projections kp
         ON kp.source_kind = 'doc' AND kp.source_id = d.id
  CROSS JOIN doc_kinds dk
 WHERE d.kind = ANY (dk.kinds)
   AND (kp.source_id IS NULL
        OR d.updated_at > kp.source_updated_at
        OR encode(sha256(convert_to(coalesce(d.body, ''), 'UTF8')), 'hex')
           IS DISTINCT FROM kp.content_sha)

UNION ALL
-- lessons (append-only; ratification bumps the watermark)
SELECT 'project', 'lesson', l.id::text,
       'lessons/lesson-' || l.id || '-' || stewards._files_safe_seg(l.kind) || '.md',
       format('Lesson %s (%s)', l.id, l.kind), l.content, NULL,
       greatest(l.at, coalesce(l.ratified_at, l.at)),
       encode(sha256(convert_to(coalesce(l.content, ''), 'UTF8')), 'hex')
  FROM stewards.lessons l
  LEFT JOIN stewards.knowledge_projections kp
         ON kp.source_kind = 'lesson' AND kp.source_id = l.id::text
 WHERE kp.source_id IS NULL
    OR greatest(l.at, coalesce(l.ratified_at, l.at)) > kp.source_updated_at
    OR encode(sha256(convert_to(coalesce(l.content, ''), 'UTF8')), 'hex')
       IS DISTINCT FROM kp.content_sha

UNION ALL
-- deletions: projected once, but the source vanished or left scope
SELECT 'delete', kp.source_kind, kp.source_id, kp.target_path,
       NULL, NULL, NULL, NULL, NULL
  FROM stewards.knowledge_projections kp, doc_kinds dk
 WHERE (kp.source_kind = 'wiki_page' AND NOT EXISTS (
            SELECT 1 FROM stewards.wiki_pages wp
             WHERE wp.id::text = kp.source_id AND wp.status = 'live'))
    OR (kp.source_kind = 'doc' AND NOT EXISTS (
            SELECT 1 FROM stewards.docs d
             WHERE d.id = kp.source_id AND d.kind = ANY (dk.kinds)))
    OR (kp.source_kind = 'lesson' AND NOT EXISTS (
            SELECT 1 FROM stewards.lessons l WHERE l.id::text = kp.source_id));
$fn$;

COMMENT ON FUNCTION stewards.knowledge_projection_pending() IS
'v28: the projection CATALOG (the file writing is the bridge''s job — projector.go). ''project'' rows are sources that are new or newer than their knowledge_projections watermark; ''delete'' rows are projections whose source vanished or left scope. Incremental by design: a second call after knowledge_projection_record returns nothing for that source. Layout: wiki/<scope>/<slug>.md, docs/<project>/<slug>.md, lessons/lesson-<id>-<kind>.md.';

-- ---------------------------------------------------------------------
-- §8 — record / forget: the projector's write-back.
-- ---------------------------------------------------------------------
-- record returns the PRIOR target_path when the projection MOVED (project
-- reassigned, slug changed) so the bridge can remove the orphaned file;
-- NULL otherwise.
CREATE OR REPLACE FUNCTION stewards.knowledge_projection_record(
    p_source_kind       text,
    p_source_id         text,
    p_target_path       text,
    p_source_updated_at timestamptz,
    p_content_sha       text
) RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_old text;
BEGIN
    SELECT kp.target_path INTO v_old
      FROM stewards.knowledge_projections kp
     WHERE kp.source_kind = p_source_kind AND kp.source_id = p_source_id;

    INSERT INTO stewards.knowledge_projections
        (source_kind, source_id, target_path, source_updated_at, content_sha, projected_at)
    VALUES (p_source_kind, p_source_id, p_target_path, p_source_updated_at, p_content_sha, now())
    ON CONFLICT (source_kind, source_id) DO UPDATE
       SET target_path       = EXCLUDED.target_path,
           source_updated_at = EXCLUDED.source_updated_at,
           content_sha       = EXCLUDED.content_sha,
           projected_at      = now();

    RETURN CASE WHEN v_old IS NOT NULL AND v_old <> p_target_path THEN v_old END;
END;
$fn$;

COMMENT ON FUNCTION stewards.knowledge_projection_record(text, text, text, timestamptz, text) IS
'v28: the projector calls this after each successful file write. Upserts the watermark; returns the PRIOR target_path when the projection moved (so the caller deletes the orphaned file), NULL otherwise.';

CREATE OR REPLACE FUNCTION stewards.knowledge_projection_forget(
    p_source_kind text,
    p_source_id   text
) RETURNS boolean LANGUAGE plpgsql AS $fn$
BEGIN
    DELETE FROM stewards.knowledge_projections kp
     WHERE kp.source_kind = p_source_kind AND kp.source_id = p_source_id;
    RETURN FOUND;
END;
$fn$;

COMMENT ON FUNCTION stewards.knowledge_projection_forget(text, text) IS
'v28: the projector calls this after removing a ''delete'' row''s file. Drops the state row; returns whether one existed.';

-- ---------------------------------------------------------------------
-- §9 — knowledge_project_now: on-demand projection nudge.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.knowledge_project_now()
RETURNS void LANGUAGE sql AS $fn$
    SELECT pg_notify('stewards_knowledge_projection', 'manual');
$fn$;

COMMENT ON FUNCTION stewards.knowledge_project_now() IS
'v28: fire the stewards_knowledge_projection NOTIFY the bridge''s projector LISTENs on (hourly tick + startup pass are the safety net — the ratified LISTEN/NOTIFY + poll shape from the autonomous materializer, D-AM-3). `stewards-cli project` calls this.';

-- ---------------------------------------------------------------------
-- §10 — config seed (operator-owned after install, per 00's convention).
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('knowledge_projection.doc_kinds', '["doc","study"]'::jsonb,
   'Which stewards.docs kinds project into the knowledge tree (knowledge_projection_pending). Default: the pool + study kinds. Add kinds with config_set; removing a kind makes its projected files pending deletion on the next pass.')
ON CONFLICT (key) DO NOTHING;
