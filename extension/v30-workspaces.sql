-- =====================================================================
-- v30-workspaces.sql — the DB-projected WORKSPACE: a writable projection
--   scope. Files in, rows out; rows in, files out. The filesystem is
--   the API.
-- =====================================================================
-- The ratified direction (.spec/proposals/db-projected-workspace.md,
-- 2026-07-07): "spin up claude code in a db projected file system, where
-- the updates land live in the db." v28 made rows readable as files
-- (one-way); v30 makes an OPT-IN scope of the tree writable:
--
--   * knowledge_workspaces — the registry. A workspace is an explicitly
--     created projection of ONE scope (a project, a wiki, a world, a
--     doc kind) into its own directory under the knowledge root
--     (_workspaces/<name>), write-back armed (mode=rw). The knowledge
--     tree at large stays one-way; only registered workspace dirs are
--     ever read back (design decision 1 + 4, "the wall").
--
--   * workspace_projection_pending — the workspace catalog, the same
--     shape as v28's knowledge_projection_pending so the bridge's
--     projector drains both through one code path. Workspace rows are
--     tracked in the SAME knowledge_projections state table under
--     source_kind = 'ws:<name>:doc' / 'ws:<name>:wiki_page' — a doc can
--     be projected in the main tree AND in a workspace without the two
--     watermarks colliding (the PK is (source_kind, source_id)).
--
--   * workspace_writeback — the write path. The sha-TRIPLE decides,
--     transactionally, in SQL (design decision 2, "never silent
--     clobber"):
--         S_proj = knowledge_projections.content_sha at last projection
--         S_file = sha256 of the file body (frontmatter stripped)
--         S_row  = sha256 of the current row body (same normalization)
--       S_file = S_proj                      -> noop (file unchanged;
--                                               row-side drift is the
--                                               projector's job)
--       S_file <> S_proj AND S_row = S_proj  -> APPLY file -> row via
--                                               the import_doc /
--                                               touch_doc revision idiom
--                                               (docs) or
--                                               wiki_page_upsert (wiki
--                                               pages), provenance
--                                               stamped (decision 3)
--       S_file <> S_proj AND S_row <> S_proj
--         AND S_file = S_row                 -> converged: heal the
--                                               watermark, no revision
--         AND S_file <> S_row                -> CONFLICT: park BOTH
--                                               versions in
--                                               workspace_conflicts +
--                                               one deduped
--                                               needs_attention 'ask',
--                                               touch NOTHING
--     A new file with no frontmatter identity -> a NEW doc inside the
--     scope, flagged in the result. A frontmatter identity claiming a
--     row OUTSIDE the workspace scope -> a conflict, never a write
--     (decision 4).
--
--   * workspace_conflicts + workspace_conflict_resolve — the parking
--     lot and its exits (row-wins / file-wins / dismiss). While a
--     conflict is PENDING its path is FROZEN both directions: the
--     catalog withholds re-projection (the row side does not clobber
--     the divergent file) and write-back keeps updating the parked
--     copy instead of the row. Resolution unfreezes.
--
-- PROVENANCE (decision 3): every applied write-back stamps (a) the
-- doc_versions.changed_by via the stewards.actor GUC ('workspace:
-- <name>:<actor>'), (b) a frontmatter 'workspace_writeback' object
-- (workspace, path, actor, shas, at), and (c)
-- knowledge_workspaces.last_writeback_at. Wiki-page write-backs carry
-- the same provenance in the revision reason.
--
-- LIVE = ONE POLL (decision 5): the bridge's workspace watcher polls
-- registered dirs every 30s; a successful write-back fires the
-- stewards_knowledge_projection NOTIFY so row-side re-projection (the
-- main tree AND other workspaces watching the same rows) lands within
-- ~1s, not an hour.
--
-- LIFELESS-CORE COMPLIANT: nothing here names a model or provider.
-- Write-back is deterministic SQL end to end; embedding rides the
-- existing docs trigger / wiki_page_upsert's graceful degrade (v27 §2).
--
-- HONEST LIMITATIONS, named up front (v28's discipline):
--   * Two in-scope sources can sanitize to the same filename (slug
--     collision) — same limitation as v28: both are tracked, the last
--     writer wins on disk. Write-back on a collided path resolves to
--     the most recently projected state row.
--   * CRLF: a Windows editor that rewrites the file with \r\n line
--     endings reads as a content change (the shas are over the bytes,
--     not a canonicalized text) — the write-back applies it as an edit.
--     Honest, deterministic, but expect one revision of churn if an
--     editor flips line endings.
--   * Deleting a FILE in a workspace is not a signal (never
--     destructive from the file side): the row stays; the file returns
--     on the next row change or a row-wins resolve. Deleting ROWS
--     happens DB-side, and the projector then removes the file.
--   * 'wiki' scope write-back targets wiki_pages via wiki_page_upsert
--     (revision-aware); NEW files in a wiki workspace become new wiki
--     pages + members. 'world' scope projects the world's canon corpus
--     (worlds.project) docs — entities/edges are graph rows, not prose,
--     and do not project.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — stewards.knowledge_workspaces: the registry (the wall's ledger).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.knowledge_workspaces (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name              text NOT NULL UNIQUE,
    scope_kind        text NOT NULL CHECK (scope_kind IN ('project','wiki','world','doc-kind')),
    scope_ref         text NOT NULL,
    dir               text NOT NULL,   -- relative to the knowledge root, forward slashes ('_workspaces/<name>')
    mode              text NOT NULL DEFAULT 'rw' CHECK (mode = 'rw'),
    created_by        text,
    created_at        timestamptz NOT NULL DEFAULT now(),
    last_writeback_at timestamptz,
    CONSTRAINT knowledge_workspaces_name_safe
        CHECK (name = stewards._files_safe_seg(name) AND name <> 'unfiled')
);

COMMENT ON TABLE stewards.knowledge_workspaces IS
'v30: the write-back registry. A workspace is an OPT-IN, per-scope writable projection (db-projected-workspace decision 1): its dir under the knowledge root is projected FROM the scope''s rows and read BACK by the bridge''s workspace watcher. Only dirs registered here are ever read back — the wall (decision 4). mode is rw-only by design: a read-only projection is just the v28 tree.';
COMMENT ON COLUMN stewards.knowledge_workspaces.scope_ref IS
'v30: what the scope_kind points at — project: docs.project_association; wiki: wikis.slug; world: worlds.slug (projects the world''s canon corpus, worlds.project); doc-kind: docs.kind.';

-- ---------------------------------------------------------------------
-- §2 — stewards.workspace_conflicts: both versions, parked, deduped.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.workspace_conflicts (
    id            bigserial PRIMARY KEY,
    workspace     text NOT NULL,      -- knowledge_workspaces.name (no FK: a conflict outlives a deleted workspace as evidence)
    relpath       text NOT NULL,      -- relative to the workspace dir, forward slashes
    source_kind   text,               -- 'doc' | 'wiki_page' | NULL (identity never resolved)
    source_id     text,               -- the claimed/looked-up row id
    file_sha      text,               -- sha256 of the raw file bytes at parking time (provenance)
    body_sha      text,               -- sha256 of the frontmatter-stripped body (the decision leg)
    row_sha       text,               -- sha256 of the row body at parking time (normalized)
    projected_sha text,               -- knowledge_projections.content_sha at parking time
    file_content  text,               -- the FULL parked file (frontmatter included) — the file''s version, preserved
    reason        text,
    status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','resolved')),
    resolution    text,               -- 'row-wins' | 'file-wins' | 'dismissed'
    resolved_by   text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    resolved_at   timestamptz
);

-- One PENDING conflict per (workspace, path): a re-poll with the same (or
-- newer) divergent file updates the parked copy in place, never spams.
CREATE UNIQUE INDEX IF NOT EXISTS workspace_conflicts_pending_uq
    ON stewards.workspace_conflicts (workspace, relpath) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS workspace_conflicts_status_idx
    ON stewards.workspace_conflicts (status, created_at);

COMMENT ON TABLE stewards.workspace_conflicts IS
'v30: the never-silent-clobber parking lot. When BOTH the row and the file changed since projection (or a file claims an identity outside the workspace scope), the file''s version parks HERE with all three shas, the row is not touched, and ONE deduped needs_attention ''ask'' is enqueued. While pending, the path is FROZEN both directions (no re-projection over the divergent file, no row write). Resolve with stewards.workspace_conflict_resolve(id, ''row-wins''|''file-wins''|''dismiss'').';

-- ---------------------------------------------------------------------
-- §3 — private helpers: normalization, sha, frontmatter, scope tests.
-- ---------------------------------------------------------------------
-- _ws_norm: the ONE normalization both sides share. The projector's file
-- render appends a trailing newline when the body lacks one; without a
-- shared rule, sha(projected body) and sha(file body) would disagree on
-- every body that does not end in '\n' and the triple would misfire.
CREATE OR REPLACE FUNCTION stewards._ws_norm(p_body text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE
        WHEN coalesce(p_body, '') = '' THEN ''
        WHEN right(p_body, 1) = E'\n'  THEN p_body
        ELSE p_body || E'\n'
    END;
$fn$;
COMMENT ON FUNCTION stewards._ws_norm(text) IS
'v30: private helper. Body normalization shared by the workspace catalog and write-back: empty stays empty, otherwise exactly ensure a trailing newline (matching the projector''s file render). All workspace content shas are over _ws_norm output.';

CREATE OR REPLACE FUNCTION stewards._ws_sha(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT encode(sha256(convert_to(coalesce(p_text, ''), 'UTF8')), 'hex');
$fn$;
COMMENT ON FUNCTION stewards._ws_sha(text) IS
'v30: private helper. Lowercase hex sha256 of UTF-8 text (NULL-safe).';

-- _ws_split_frontmatter: (frontmatter_inner, body). No frontmatter ->
-- (NULL, whole content). Handles LF and CRLF delimiters and the optional
-- blank line after the closing '---' (the projector writes one).
-- PROCEDURAL ON PURPOSE: a regex version trips PostgreSQL's ARE rule that
-- the WHOLE pattern's greediness follows its FIRST quantifier — a body
-- containing a markdown '---' horizontal rule could be swallowed into the
-- frontmatter under overall-greedy matching. strpos finds the FIRST
-- closing delimiter line, always.
CREATE OR REPLACE FUNCTION stewards._ws_split_frontmatter(p_content text)
RETURNS TABLE (fm text, body text) LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
    v_c     text := coalesce(p_content, '');
    v_open  text;
    v_close text;
    v_blank text;
    v_idx   int;
BEGIN
    IF left(v_c, 4) = E'---\n' THEN
        v_open := E'---\n';  v_close := E'\n---\n';  v_blank := E'\n';
    ELSIF left(v_c, 5) = E'---\r\n' THEN
        v_open := E'---\r\n'; v_close := E'\r\n---\r\n'; v_blank := E'\r\n';
    ELSE
        fm := NULL; body := v_c; RETURN NEXT; RETURN;
    END IF;

    -- First closing '---' line after the opener (frontmatter keys can
    -- never themselves be a bare '---' line — the projector yaml-quotes).
    v_idx := strpos(substr(v_c, char_length(v_open) + 1), v_close);
    IF v_idx = 0 THEN
        -- Degenerate: closing delimiter at EOF with no trailing newline.
        IF right(v_c, char_length(v_close) - 1) = substr(v_close, 1, char_length(v_close) - 1) THEN
            fm := substr(v_c, char_length(v_open) + 1,
                         char_length(v_c) - char_length(v_open) - (char_length(v_close) - 1));
            body := '';
        ELSE
            fm := NULL; body := v_c; -- opener with no closer: not frontmatter
        END IF;
        RETURN NEXT; RETURN;
    END IF;

    fm := substr(v_c, char_length(v_open) + 1, v_idx - 1);
    body := substr(v_c, char_length(v_open) + (v_idx - 1) + char_length(v_close) + 1);
    -- The projector writes ONE blank line between frontmatter and body —
    -- it belongs to the frame, not the body.
    IF left(body, char_length(v_blank)) = v_blank THEN
        body := substr(body, char_length(v_blank) + 1);
    END IF;
    RETURN NEXT;
END;
$fn$;
COMMENT ON FUNCTION stewards._ws_split_frontmatter(text) IS
'v30: private helper. Split a projected file into (frontmatter inner text, body). The SQL-side parse is AUTHORITATIVE for write-back — the bridge''s Go strip is a convenience for logging, never the decision-maker (one parser owns the transactional decision).';

-- _ws_fm_get: one scalar out of the frontmatter inner text (id / kind /
-- workspace). Values are the projector's yamlQuote output — optionally
-- double-quoted, no embedded quotes in practice (uuids, kind names).
CREATE OR REPLACE FUNCTION stewards._ws_fm_get(p_fm text, p_key text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT nullif(btrim(
        (regexp_match(coalesce(p_fm, ''),
                      '(?n)^' || p_key || ':[ \t]*"?([^"\r\n]*)"?[ \t]*\r?$'))[1]), '');
$fn$;
COMMENT ON FUNCTION stewards._ws_fm_get(text, text) IS
'v30: private helper. Extract one frontmatter scalar (id, kind, workspace) from _ws_split_frontmatter''s fm text.';

-- _ws_doc_kinds: the SAME operator config v28's catalog reads.
CREATE OR REPLACE FUNCTION stewards._ws_doc_kinds()
RETURNS text[] LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(array_agg(t.k), ARRAY['doc','study'])
      FROM jsonb_array_elements_text(
               stewards.config_get('knowledge_projection.doc_kinds',
                                   '["doc","study"]'::jsonb)) AS t(k);
$fn$;
COMMENT ON FUNCTION stewards._ws_doc_kinds() IS
'v30: private helper. The doc kinds that project (knowledge_projection.doc_kinds — one config governs the v28 tree and every workspace, deliberately).';

-- _ws_doc_in_scope: does a docs row belong to this workspace's scope?
-- Used by the catalog (what projects), the write-back wall (what a file
-- may claim), and the create path (what a new file becomes).
CREATE OR REPLACE FUNCTION stewards._ws_doc_in_scope(
    p_scope_kind text, p_scope_ref text, p_project text, p_kind text
) RETURNS boolean LANGUAGE sql STABLE AS $fn$
    SELECT CASE p_scope_kind
        WHEN 'project'  THEN p_project IS NOT DISTINCT FROM p_scope_ref
                             AND p_kind = ANY (stewards._ws_doc_kinds())
        WHEN 'world'    THEN p_project IS NOT DISTINCT FROM
                             (SELECT w.project FROM stewards.worlds w WHERE w.slug = p_scope_ref)
                             AND p_kind = ANY (stewards._ws_doc_kinds())
        WHEN 'doc-kind' THEN p_kind = p_scope_ref
        ELSE false
    END;
$fn$;
COMMENT ON FUNCTION stewards._ws_doc_in_scope(text, text, text, text) IS
'v30: private helper. The scope wall for docs: project -> project_association match (configured kinds only); world -> the world''s canon corpus (worlds.project, configured kinds); doc-kind -> kind match. wiki scope never matches docs (wiki workspaces hold wiki_pages).';

-- _ws_page_in_scope: wiki-scope membership test for a wiki_pages row.
CREATE OR REPLACE FUNCTION stewards._ws_page_in_scope(
    p_scope_kind text, p_scope_ref text, p_page_id uuid
) RETURNS boolean LANGUAGE sql STABLE AS $fn$
    SELECT p_scope_kind = 'wiki' AND EXISTS (
        SELECT 1
          FROM stewards.wikis wk
          JOIN stewards.wiki_members m ON m.wiki_id = wk.id
          JOIN stewards.wiki_pages wp ON wp.id = m.page_id
         WHERE wk.slug = p_scope_ref AND wp.id = p_page_id AND wp.status = 'live');
$fn$;
COMMENT ON FUNCTION stewards._ws_page_in_scope(text, text, uuid) IS
'v30: private helper. The scope wall for wiki pages: live member of the scoped wiki.';

-- ---------------------------------------------------------------------
-- §4 — workspace_create: register + return the projection spec.
-- ---------------------------------------------------------------------
-- Never RAISEs (the 94/100 tool-surface convention). Idempotent: re-create
-- with the SAME scope returns the existing registration; a different scope
-- under a taken name is refused.
CREATE OR REPLACE FUNCTION stewards.workspace_create(
    p_name       text,
    p_scope_kind text,
    p_scope_ref  text,
    p_created_by text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_name    text := lower(btrim(coalesce(p_name, '')));
    v_kind    text := lower(btrim(coalesce(p_scope_kind, '')));
    v_ref     text := btrim(coalesce(p_scope_ref, ''));
    v_row     stewards.knowledge_workspaces%ROWTYPE;
    v_pending int;
    v_existed boolean := false;
BEGIN
    IF v_name = '' OR v_name <> stewards._files_safe_seg(v_name) OR v_name = 'unfiled' THEN
        RETURN jsonb_build_object('ok', false,
            'error', format('workspace name must be a safe segment ([a-z0-9_-]+), got %L', p_name));
    END IF;
    IF v_kind NOT IN ('project','wiki','world','doc-kind') THEN
        RETURN jsonb_build_object('ok', false,
            'error', format('scope_kind must be project|wiki|world|doc-kind, got %L', p_scope_kind));
    END IF;
    IF v_ref = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'scope_ref is required');
    END IF;
    -- A wiki/world scope must point at a registry row that EXISTS — a typo
    -- here would project an eternally-empty workspace and confuse everyone.
    -- (project / doc-kind refs are open taxonomies: zero docs today is a
    -- legitimate new-project state, reported via doc_count.)
    IF v_kind = 'wiki' AND NOT EXISTS (SELECT 1 FROM stewards.wikis wk WHERE wk.slug = v_ref) THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no wiki with slug %L', v_ref));
    END IF;
    IF v_kind = 'world' AND NOT EXISTS (SELECT 1 FROM stewards.worlds w WHERE w.slug = v_ref) THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no world with slug %L', v_ref));
    END IF;

    INSERT INTO stewards.knowledge_workspaces (name, scope_kind, scope_ref, dir, created_by)
    VALUES (v_name, v_kind, v_ref, '_workspaces/' || v_name, p_created_by)
    ON CONFLICT (name) DO NOTHING;
    IF NOT FOUND THEN
        SELECT * INTO v_row FROM stewards.knowledge_workspaces WHERE name = v_name;
        IF v_row.scope_kind <> v_kind OR v_row.scope_ref <> v_ref THEN
            RETURN jsonb_build_object('ok', false,
                'error', format('workspace %L already exists with scope %s:%s (asked for %s:%s)',
                                v_name, v_row.scope_kind, v_row.scope_ref, v_kind, v_ref));
        END IF;
        v_existed := true;
    ELSE
        SELECT * INTO v_row FROM stewards.knowledge_workspaces WHERE name = v_name;
    END IF;

    SELECT count(*) INTO v_pending
      FROM stewards.workspace_projection_pending(v_name) p WHERE p.action = 'project';

    -- Ring the projector's bell: the workspace catalog rides the same pass.
    PERFORM stewards.knowledge_project_now();

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ok', true, 'existed', CASE WHEN v_existed THEN true END,
        'workspace', v_row.name, 'scope_kind', v_row.scope_kind,
        'scope_ref', v_row.scope_ref, 'dir', v_row.dir, 'mode', v_row.mode,
        'pending', v_pending));
END;
$fn$;

COMMENT ON FUNCTION stewards.workspace_create(text, text, text, text) IS
'v30: register a writable workspace projection (opt-in per workspace, decision 1) and fire the projection NOTIFY so its files land within ~1s of a running bridge. Returns the projection spec {workspace, scope_kind, scope_ref, dir, mode, pending}. Idempotent on identical scope; refuses a taken name with a different scope. Never RAISEs.';

-- ---------------------------------------------------------------------
-- §5 — workspace_projection_pending: the workspace catalog.
-- ---------------------------------------------------------------------
-- Same column shape as knowledge_projection_pending() so the bridge's
-- projector drains both catalogs through one loop. source_kind is
-- 'ws:<name>:doc' / 'ws:<name>:wiki_page' (workspace names are safe
-- segments — ':' cannot occur), which keys the SAME knowledge_projections
-- state table without colliding with the main tree's watermarks.
-- p_workspace = NULL means all registered workspaces.
--
-- THE FREEZE: a path with a PENDING conflict is withheld from
-- (re)projection AND deletion — the human sees both versions exactly as
-- they diverged; resolution unfreezes.
CREATE OR REPLACE FUNCTION stewards.workspace_projection_pending(p_workspace text DEFAULT NULL)
RETURNS TABLE (
    action            text,
    source_kind       text,
    source_id         text,
    target_path       text,
    title             text,
    body              text,
    project           text,
    source_updated_at timestamptz,
    content_sha       text
) LANGUAGE sql STABLE AS $fn$
-- docs in scope (project / world / doc-kind workspaces)
SELECT 'project', 'ws:' || w.name || ':doc', d.id,
       w.dir || '/' || stewards._files_safe_seg(d.slug) || '.md',
       d.title, stewards._ws_norm(d.body), d.project_association, d.updated_at,
       stewards._ws_sha(stewards._ws_norm(d.body))
  FROM stewards.knowledge_workspaces w
  JOIN stewards.docs d
       ON stewards._ws_doc_in_scope(w.scope_kind, w.scope_ref, d.project_association, d.kind)
  LEFT JOIN stewards.knowledge_projections kp
       ON kp.source_kind = 'ws:' || w.name || ':doc' AND kp.source_id = d.id
 WHERE (p_workspace IS NULL OR w.name = p_workspace)
   AND (kp.source_id IS NULL
        OR d.updated_at > kp.source_updated_at
        -- sha is the correctness anchor (v28's lesson: now() is
        -- transaction-constant, so a same-txn edit can leave updated_at
        -- EQUAL to the watermark).
        OR stewards._ws_sha(stewards._ws_norm(d.body)) IS DISTINCT FROM kp.content_sha)
   AND NOT EXISTS (SELECT 1 FROM stewards.workspace_conflicts c
                    WHERE c.status = 'pending' AND c.workspace = w.name
                      AND c.relpath = stewards._files_safe_seg(d.slug) || '.md')

UNION ALL
-- live wiki pages of a wiki-scoped workspace
SELECT 'project', 'ws:' || w.name || ':wiki_page', wp.id::text,
       w.dir || '/' || stewards._files_safe_seg(wp.slug) || '.md',
       wp.title, stewards._ws_norm(wp.content), w.scope_ref, wp.updated_at,
       stewards._ws_sha(stewards._ws_norm(wp.content))
  FROM stewards.knowledge_workspaces w
  JOIN stewards.wikis wk ON w.scope_kind = 'wiki' AND wk.slug = w.scope_ref
  JOIN stewards.wiki_members m ON m.wiki_id = wk.id
  JOIN stewards.wiki_pages wp ON wp.id = m.page_id AND wp.status = 'live'
  LEFT JOIN stewards.knowledge_projections kp
       ON kp.source_kind = 'ws:' || w.name || ':wiki_page' AND kp.source_id = wp.id::text
 WHERE (p_workspace IS NULL OR w.name = p_workspace)
   AND (kp.source_id IS NULL
        OR wp.updated_at > kp.source_updated_at
        OR stewards._ws_sha(stewards._ws_norm(wp.content)) IS DISTINCT FROM kp.content_sha)
   AND NOT EXISTS (SELECT 1 FROM stewards.workspace_conflicts c
                    WHERE c.status = 'pending' AND c.workspace = w.name
                      AND c.relpath = stewards._files_safe_seg(wp.slug) || '.md')

UNION ALL
-- deletions: a workspace projection whose workspace, source, or scope
-- membership vanished (the file should leave the tree).
SELECT 'delete', kp.source_kind, kp.source_id, kp.target_path,
       NULL, NULL, NULL, NULL, NULL
  FROM stewards.knowledge_projections kp
 WHERE kp.source_kind LIKE 'ws:%'
   AND (p_workspace IS NULL OR split_part(kp.source_kind, ':', 2) = p_workspace)
   AND NOT EXISTS (
        SELECT 1 FROM stewards.knowledge_workspaces w
         WHERE w.name = split_part(kp.source_kind, ':', 2)
           AND CASE split_part(kp.source_kind, ':', 3)
               WHEN 'doc' THEN EXISTS (
                    SELECT 1 FROM stewards.docs d
                     WHERE d.id = kp.source_id
                       AND stewards._ws_doc_in_scope(w.scope_kind, w.scope_ref,
                                                     d.project_association, d.kind))
               WHEN 'wiki_page' THEN stewards._ws_page_in_scope(
                    w.scope_kind, w.scope_ref, kp.source_id::uuid)
               ELSE false
               END)
   AND NOT EXISTS (
        SELECT 1 FROM stewards.workspace_conflicts c
          JOIN stewards.knowledge_workspaces w2 ON w2.name = c.workspace
         WHERE c.status = 'pending'
           AND kp.target_path = w2.dir || '/' || c.relpath);
$fn$;

COMMENT ON FUNCTION stewards.workspace_projection_pending(text) IS
'v30: the WORKSPACE projection catalog — same shape as knowledge_projection_pending() so the bridge''s projector drains both in one pass (the chosen seam). Rows are keyed in knowledge_projections under source_kind=''ws:<name>:doc''/''ws:<name>:wiki_page'' so a doc can project into the main tree AND a workspace without watermark collision. Paths with a PENDING workspace_conflicts row are FROZEN (withheld from projection and deletion) until resolved. NULL = all workspaces.';

-- ---------------------------------------------------------------------
-- §6 — _workspace_apply: the one apply path (write-back + file-wins).
-- ---------------------------------------------------------------------
-- Applies a file body onto its row through the substrate's EXISTING
-- revision idioms: docs via import_doc (ON CONFLICT(slug) UPDATE fires
-- touch_doc -> prior revision archived in doc_versions, CITES graph
-- re-synced) with the stewards.actor GUC carrying the write-back actor
-- into doc_versions.changed_by; wiki pages via wiki_page_upsert (revision
-- appended with a provenance reason). Advances the workspace watermark so
-- the projector does not immediately re-project, and fires the projection
-- NOTIFY so the row's OTHER projections (main tree, sibling workspaces)
-- catch up within ~1s (decision 5's other half).
CREATE OR REPLACE FUNCTION stewards._workspace_apply(
    p_ws            stewards.knowledge_workspaces,
    p_kind          text,      -- 'doc' | 'wiki_page'
    p_source_id     text,
    p_relpath       text,
    p_body          text,      -- frontmatter-stripped file body
    p_actor         text,
    p_file_sha      text,      -- raw file-bytes sha (provenance)
    p_projected_sha text,      -- watermark at decision time (provenance)
    p_via           text       -- 'writeback' | 'conflict-resolve'
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_store  text := stewards._ws_norm(p_body);
    v_sha    text := stewards._ws_sha(stewards._ws_norm(p_body));
    v_doc    stewards.docs%ROWTYPE;
    v_page   stewards.wiki_pages%ROWTYPE;
    v_title  text;
    v_stamp  jsonb;
    v_actor  text := 'workspace:' || p_ws.name || ':' || coalesce(nullif(btrim(coalesce(p_actor,'')),''), 'file-edit');
    v_upd    timestamptz;
BEGIN
    v_stamp := jsonb_build_object(
        'workspace',     p_ws.name,
        'path',          p_relpath,
        'actor',         coalesce(nullif(btrim(coalesce(p_actor,'')),''), 'file-edit'),
        'via',           p_via,
        'file_sha',      p_file_sha,
        'projected_sha', p_projected_sha,
        'at',            to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));

    IF p_kind = 'doc' THEN
        SELECT * INTO v_doc FROM stewards.docs d WHERE d.id = p_source_id;
        IF v_doc.id IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'status', 'error',
                                      'error', format('doc %s vanished mid-apply', p_source_id));
        END IF;
        v_title := coalesce((regexp_match(v_store, '^#\s+(.+?)\s*$', 'n'))[1], v_doc.title);

        -- Identical after normalization -> heal the watermark, no revision
        -- (kills the re-apply churn a restarted watcher would otherwise
        -- cause on files saved without a trailing newline).
        IF v_doc.body = v_store AND v_doc.title = v_title THEN
            PERFORM stewards.knowledge_projection_record(
                'ws:' || p_ws.name || ':doc', v_doc.id,
                p_ws.dir || '/' || p_relpath, v_doc.updated_at, v_sha);
            RETURN jsonb_build_object('ok', true, 'status', 'noop',
                                      'note', 'content identical after normalization; watermark healed');
        END IF;

        -- Provenance leg (a): doc_versions.changed_by via the touch_doc GUC.
        PERFORM set_config('stewards.actor', v_actor, true);
        -- The EXISTING revision idiom: import_doc upserts by slug -> the
        -- UPDATE fires touch_doc (prior title/body/frontmatter archived) and
        -- re-syncs the CITES graph for the new body. Provenance leg (b): the
        -- frontmatter workspace_writeback stamp (merged, never wholesale).
        PERFORM stewards.import_doc(
            v_doc.slug, v_doc.file_path, v_title, v_store,
            v_doc.frontmatter || jsonb_build_object('workspace_writeback', v_stamp),
            v_doc.kind);

        SELECT d.updated_at INTO v_upd FROM stewards.docs d WHERE d.id = v_doc.id;
        PERFORM stewards.knowledge_projection_record(
            'ws:' || p_ws.name || ':doc', v_doc.id,
            p_ws.dir || '/' || p_relpath, v_upd, v_sha);

    ELSIF p_kind = 'wiki_page' THEN
        SELECT * INTO v_page FROM stewards.wiki_pages wp WHERE wp.id = p_source_id::uuid;
        IF v_page.id IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'status', 'error',
                                      'error', format('wiki page %s vanished mid-apply', p_source_id));
        END IF;
        v_title := coalesce((regexp_match(v_store, '^#\s+(.+?)\s*$', 'n'))[1], v_page.title);

        IF v_page.content = v_store AND v_page.title = v_title THEN
            PERFORM stewards.knowledge_projection_record(
                'ws:' || p_ws.name || ':wiki_page', v_page.id::text,
                p_ws.dir || '/' || p_relpath, v_page.updated_at, v_sha);
            RETURN jsonb_build_object('ok', true, 'status', 'noop',
                                      'note', 'content identical after normalization; watermark healed');
        END IF;

        -- The wiki twin of the idiom: wiki_page_upsert appends a
        -- wiki_page_revisions row; the reason line IS the provenance stamp.
        PERFORM stewards.wiki_page_upsert(
            v_page.slug, v_title, v_store, '[]'::jsonb,
            'workspace write-back ' || v_stamp::text, 'live');

        SELECT wp.updated_at INTO v_upd FROM stewards.wiki_pages wp WHERE wp.id = v_page.id;
        PERFORM stewards.knowledge_projection_record(
            'ws:' || p_ws.name || ':wiki_page', v_page.id::text,
            p_ws.dir || '/' || p_relpath, v_upd, v_sha);
    ELSE
        RETURN jsonb_build_object('ok', false, 'status', 'error',
                                  'error', format('unknown target kind %L', p_kind));
    END IF;

    -- Provenance leg (c) + the live loop's other half.
    UPDATE stewards.knowledge_workspaces SET last_writeback_at = now() WHERE id = p_ws.id;
    PERFORM stewards.knowledge_project_now();

    RETURN jsonb_build_object('ok', true, 'status', 'applied',
                              'target_kind', p_kind, 'target_id', p_source_id,
                              'title', v_title, 'actor', v_actor, 'via', p_via);
END;
$fn$;

COMMENT ON FUNCTION stewards._workspace_apply(stewards.knowledge_workspaces, text, text, text, text, text, text, text, text) IS
'v30: private. The ONE apply path (used by workspace_writeback''s file-wins leg and workspace_conflict_resolve(file-wins)): docs through import_doc (touch_doc archives the prior revision, changed_by = the stewards.actor GUC = workspace:<name>:<actor>, frontmatter gains a merged workspace_writeback stamp, CITES re-synced); wiki pages through wiki_page_upsert (revision reason = the stamp). Advances the workspace watermark and fires the projection NOTIFY so the row''s other projections catch up. Identical-after-normalization content heals the watermark with NO revision.';

-- ---------------------------------------------------------------------
-- §7 — _workspace_conflict: park both versions, enqueue ONE ask.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards._workspace_conflict(
    p_ws            stewards.knowledge_workspaces,
    p_relpath       text,
    p_source_kind   text,
    p_source_id     text,
    p_file_sha      text,
    p_body_sha      text,
    p_row_sha       text,
    p_projected_sha text,
    p_file_content  text,
    p_reason        text
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_id  bigint;
    v_new boolean := false;
BEGIN
    INSERT INTO stewards.workspace_conflicts
        (workspace, relpath, source_kind, source_id, file_sha, body_sha,
         row_sha, projected_sha, file_content, reason)
    VALUES (p_ws.name, p_relpath, p_source_kind, p_source_id, p_file_sha, p_body_sha,
            p_row_sha, p_projected_sha, p_file_content, p_reason)
    ON CONFLICT (workspace, relpath) WHERE status = 'pending' DO UPDATE
       -- A re-park refreshes the PARKED COPY (latest file wins the park) but
       -- preserves the original evidence: the sha triple as it stood when
       -- the divergence was detected, and the reason that named it.
       SET file_sha = EXCLUDED.file_sha, body_sha = EXCLUDED.body_sha,
           file_content = EXCLUDED.file_content,
           row_sha       = coalesce(EXCLUDED.row_sha, stewards.workspace_conflicts.row_sha),
           projected_sha = coalesce(EXCLUDED.projected_sha, stewards.workspace_conflicts.projected_sha),
           source_kind = coalesce(EXCLUDED.source_kind, stewards.workspace_conflicts.source_kind),
           source_id   = coalesce(EXCLUDED.source_id, stewards.workspace_conflicts.source_id),
           updated_at = now()
    RETURNING id, (xmax = 0) INTO v_id, v_new;

    -- ONE deduped needs_attention ask per pending (workspace, path) — the
    -- 89 'ask' bucket. A refreshed parked copy re-uses the standing ask.
    IF v_new AND NOT EXISTS (
        SELECT 1 FROM stewards.hinge_reviews hr
         WHERE hr.kind = 'ask' AND hr.status IN ('pending','escalated')
           AND hr.payload->>'workspace' = p_ws.name
           AND hr.payload->>'relpath' = p_relpath)
    THEN
        PERFORM stewards.hinge_enqueue('ask',
            format('Workspace conflict: %s/%s', p_ws.name, p_relpath),
            jsonb_build_object(
                'question', format('%s — the file''s version is parked in workspace_conflicts (id %s); the row is untouched. Resolve with SELECT stewards.workspace_conflict_resolve(%s, ''row-wins''|''file-wins''|''dismiss'');',
                                   p_reason, v_id, v_id),
                'workspace', p_ws.name, 'relpath', p_relpath,
                'conflict_id', v_id),
            'workspace-writeback');
    END IF;

    RETURN jsonb_build_object('ok', false, 'status', 'conflict',
                              'conflict_id', v_id, 'reason', p_reason);
END;
$fn$;

COMMENT ON FUNCTION stewards._workspace_conflict(stewards.knowledge_workspaces, text, text, text, text, text, text, text, text, text) IS
'v30: private. Park a write-back conflict (both versions preserved: the file''s in workspace_conflicts.file_content, the row''s in the row) and enqueue at most ONE needs_attention ''ask'' per pending (workspace, path). A re-park refreshes the parked copy in place.';

-- ---------------------------------------------------------------------
-- §8 — workspace_writeback: the sha-triple decision, transactional.
-- ---------------------------------------------------------------------
-- The bridge's workspace watcher calls this for every changed file in a
-- registered dir. p_content is the RAW file (frontmatter included) — the
-- SQL-side parse is authoritative so the whole decision commits or rolls
-- back as one transaction. p_file_sha is the sha256 of the raw file bytes
-- (change-detection + provenance); the DECISION shas are computed here
-- over the frontmatter-stripped, _ws_norm-alized body.
-- Never RAISEs.
CREATE OR REPLACE FUNCTION stewards.workspace_writeback(
    p_workspace text,
    p_relpath   text,
    p_content   text,
    p_file_sha  text,
    p_actor     text DEFAULT 'file-edit'
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_ws        stewards.knowledge_workspaces%ROWTYPE;
    v_rel       text := ltrim(replace(btrim(coalesce(p_relpath, '')), E'\\', '/'), '/');
    v_fm        text;
    v_body      text;
    v_body_sha  text;
    v_claim_id  text;
    v_claim_k   text;
    v_target    text;
    v_kp        stewards.knowledge_projections%ROWTYPE;
    v_kind      text;   -- resolved target kind: 'doc' | 'wiki_page'
    v_id        text;   -- resolved target id
    v_row_sha   text;
    v_in_scope  boolean;
    v_slug      text;
    v_title     text;
    v_doc_id    text;
    v_page_id   uuid;
    v_seg       text;
BEGIN
    SELECT * INTO v_ws FROM stewards.knowledge_workspaces WHERE name = lower(btrim(coalesce(p_workspace, '')));
    IF v_ws.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'status', 'error',
            'error', format('no workspace named %L (the wall: only registered workspaces write back)', p_workspace));
    END IF;
    IF v_rel = '' OR p_content IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'status', 'error', 'error', 'relpath and content are required');
    END IF;
    -- Path hygiene: forward slashes, no traversal, no hidden segments. The
    -- bridge validates too; SQL does not TRUST the bridge (same
    -- belt-and-suspenders as v28's safeKnowledgeRel).
    FOREACH v_seg IN ARRAY string_to_array(v_rel, '/') LOOP
        IF v_seg IN ('', '.', '..') OR left(v_seg, 1) = '.' THEN
            RETURN jsonb_build_object('ok', false, 'status', 'error',
                'error', format('unsafe relpath %L', p_relpath));
        END IF;
    END LOOP;
    v_target := v_ws.dir || '/' || v_rel;

    SELECT s.fm, s.body INTO v_fm, v_body FROM stewards._ws_split_frontmatter(p_content) s;
    v_body_sha := stewards._ws_sha(stewards._ws_norm(v_body));
    v_claim_id := stewards._ws_fm_get(v_fm, 'id');
    v_claim_k  := stewards._ws_fm_get(v_fm, 'kind');

    -- A pending conflict on this path keeps it FROZEN: refresh the parked
    -- copy, never touch the row, never spam the bell.
    IF EXISTS (SELECT 1 FROM stewards.workspace_conflicts c
                WHERE c.workspace = v_ws.name AND c.relpath = v_rel AND c.status = 'pending') THEN
        RETURN stewards._workspace_conflict(v_ws, v_rel, NULL, NULL,
            lower(coalesce(nullif(btrim(coalesce(p_file_sha,'')),''), stewards._ws_sha(p_content))),
            v_body_sha, NULL, NULL, p_content,
            'path frozen by a pending conflict (parked copy refreshed)');
    END IF;

    -- ── Resolve the target row: projection state first, frontmatter second.
    SELECT kp.* INTO v_kp
      FROM stewards.knowledge_projections kp
     WHERE kp.target_path = v_target AND kp.source_kind LIKE 'ws:' || v_ws.name || ':%'
     ORDER BY kp.projected_at DESC LIMIT 1;

    IF v_kp.source_id IS NOT NULL THEN
        v_kind := split_part(v_kp.source_kind, ':', 3);
        v_id   := v_kp.source_id;
        -- Frontmatter claiming a DIFFERENT row than this path's projection
        -- state is a copied/moved file — never a write (decision 4).
        IF v_claim_id IS NOT NULL AND v_claim_id <> v_id THEN
            RETURN stewards._workspace_conflict(v_ws, v_rel, v_kind, v_claim_id,
                lower(coalesce(nullif(btrim(coalesce(p_file_sha,'')),''), stewards._ws_sha(p_content))),
                v_body_sha, NULL, v_kp.content_sha, p_content,
                format('frontmatter claims id %s but this path projects row %s', v_claim_id, v_id));
        END IF;
    ELSIF v_claim_id IS NOT NULL THEN
        -- Identity without state (a file copied into the workspace). Verify
        -- the claim against the wall below; the sha-triple degenerates (no
        -- projected sha), so only exact file==row convergence heals it.
        v_kind := CASE WHEN v_ws.scope_kind = 'wiki' THEN 'wiki_page' ELSE 'doc' END;
        v_id   := v_claim_id;
    ELSE
        -- ── No identity anywhere: a NEW file. Create INSIDE the scope
        -- (decision 4's "new rows are created within the scope, flagged").
        v_slug  := v_ws.name || '-' || stewards._files_safe_seg(
                       regexp_replace(v_rel, '\.(md|markdown|txt)\s*$', '', 'i'));
        v_title := coalesce((regexp_match(v_body, '^#\s+(.+?)\s*$', 'n'))[1],
                            regexp_replace(regexp_replace(v_rel, '^.*/', ''),
                                           '\.(md|markdown|txt)\s*$', '', 'i'));
        IF v_ws.scope_kind = 'wiki' THEN
            IF EXISTS (SELECT 1 FROM stewards.wiki_pages wp WHERE wp.slug = v_slug) THEN
                RETURN stewards._workspace_conflict(v_ws, v_rel, 'wiki_page', NULL,
                    lower(coalesce(nullif(btrim(coalesce(p_file_sha,'')),''), stewards._ws_sha(p_content))),
                    v_body_sha, NULL, NULL, p_content,
                    format('new file, but wiki page slug %L already exists (will not adopt silently)', v_slug));
            END IF;
            v_page_id := stewards.wiki_page_upsert(v_slug, v_title, stewards._ws_norm(v_body),
                             '[]'::jsonb,
                             format('created from workspace %s file %s by %s', v_ws.name, v_rel, coalesce(p_actor,'file-edit')),
                             'live');
            PERFORM stewards.wiki_add_member(v_ws.scope_ref, v_slug,
                                             'workspace:' || v_ws.name);
            UPDATE stewards.knowledge_workspaces SET last_writeback_at = now() WHERE id = v_ws.id;
            -- Deliberately NOT recording a watermark: the next projector pass
            -- rewrites this file WITH identity frontmatter; the watcher then
            -- no-ops on it (round-trip proven by the sha).
            PERFORM stewards.knowledge_project_now();
            RETURN jsonb_build_object('ok', true, 'status', 'created',
                'target_kind', 'wiki_page', 'target_id', v_page_id::text, 'slug', v_slug,
                'note', 'new wiki page created in scope; the projector will rewrite the file with identity frontmatter');
        ELSE
            IF EXISTS (SELECT 1 FROM stewards.docs d WHERE d.slug = v_slug) THEN
                RETURN stewards._workspace_conflict(v_ws, v_rel, 'doc', NULL,
                    lower(coalesce(nullif(btrim(coalesce(p_file_sha,'')),''), stewards._ws_sha(p_content))),
                    v_body_sha, NULL, NULL, p_content,
                    format('new file, but doc slug %L already exists (will not adopt silently)', v_slug));
            END IF;
            PERFORM set_config('stewards.actor',
                'workspace:' || v_ws.name || ':' || coalesce(nullif(btrim(coalesce(p_actor,'')),''), 'file-edit'), true);
            v_doc_id := stewards.import_doc(v_slug, v_target, v_title, stewards._ws_norm(v_body),
                jsonb_build_object(
                    'origin', 'workspace',
                    'workspace', v_ws.name,
                    'workspace_path', v_rel,
                    'created_by', coalesce(p_actor, 'file-edit')),
                CASE WHEN v_ws.scope_kind = 'doc-kind' THEN v_ws.scope_ref ELSE 'doc' END);
            UPDATE stewards.docs d
               SET source_type = 'workspace',
                   project_association = CASE v_ws.scope_kind
                       WHEN 'project' THEN v_ws.scope_ref
                       WHEN 'world'   THEN (SELECT w.project FROM stewards.worlds w WHERE w.slug = v_ws.scope_ref)
                       ELSE d.project_association END
             WHERE d.id = v_doc_id;
            UPDATE stewards.knowledge_workspaces SET last_writeback_at = now() WHERE id = v_ws.id;
            PERFORM stewards.knowledge_project_now();
            RETURN jsonb_build_object('ok', true, 'status', 'created',
                'target_kind', 'doc', 'target_id', v_doc_id, 'slug', v_slug,
                'note', 'new doc created in scope; the projector will rewrite the file with identity frontmatter');
        END IF;
    END IF;

    -- ── The wall: the resolved/claimed row must live INSIDE this scope.
    IF v_kind = 'doc' THEN
        SELECT stewards._ws_doc_in_scope(v_ws.scope_kind, v_ws.scope_ref,
                                         d.project_association, d.kind),
               stewards._ws_sha(stewards._ws_norm(d.body))
          INTO v_in_scope, v_row_sha
          FROM stewards.docs d WHERE d.id = v_id;
    ELSE
        BEGIN
            SELECT stewards._ws_page_in_scope(v_ws.scope_kind, v_ws.scope_ref, wp.id),
                   stewards._ws_sha(stewards._ws_norm(wp.content))
              INTO v_in_scope, v_row_sha
              FROM stewards.wiki_pages wp WHERE wp.id = v_id::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            v_in_scope := NULL; v_row_sha := NULL;
        END;
    END IF;
    IF v_in_scope IS NULL THEN
        RETURN stewards._workspace_conflict(v_ws, v_rel, v_kind, v_id,
            lower(coalesce(nullif(btrim(coalesce(p_file_sha,'')),''), stewards._ws_sha(p_content))),
            v_body_sha, NULL, v_kp.content_sha, p_content,
            format('claimed %s %s does not exist', v_kind, v_id));
    END IF;
    IF NOT v_in_scope THEN
        RETURN stewards._workspace_conflict(v_ws, v_rel, v_kind, v_id,
            lower(coalesce(nullif(btrim(coalesce(p_file_sha,'')),''), stewards._ws_sha(p_content))),
            v_body_sha, v_row_sha, v_kp.content_sha, p_content,
            format('%s %s is OUTSIDE this workspace''s scope (%s:%s) — a claim across the wall is a conflict, not a write',
                   v_kind, v_id, v_ws.scope_kind, v_ws.scope_ref));
    END IF;

    -- ── Identity-without-state: heal on exact convergence, else park.
    IF v_kp.source_id IS NULL THEN
        IF v_body_sha = v_row_sha THEN
            PERFORM stewards.knowledge_projection_record(
                'ws:' || v_ws.name || ':' || v_kind, v_id, v_target, now(), v_row_sha);
            RETURN jsonb_build_object('ok', true, 'status', 'noop',
                'note', 'no projection state for path, but file matches the row exactly — state healed');
        END IF;
        RETURN stewards._workspace_conflict(v_ws, v_rel, v_kind, v_id,
            lower(coalesce(nullif(btrim(coalesce(p_file_sha,'')),''), stewards._ws_sha(p_content))),
            v_body_sha, v_row_sha, NULL, p_content,
            'no projection state for this path — cannot prove the row is unchanged since projection');
    END IF;

    -- ── The sha triple (projected / file / row) decides.
    IF v_body_sha = v_kp.content_sha THEN
        -- File unchanged since projection. Row-side drift is the
        -- projector's job, not write-back's.
        RETURN jsonb_build_object('ok', true, 'status', 'noop',
                                  'note', 'file matches its projection');
    END IF;
    IF v_row_sha = v_kp.content_sha THEN
        -- File changed, row unchanged -> the file wins (it is the
        -- authoring surface). Apply with full provenance.
        RETURN stewards._workspace_apply(v_ws, v_kind, v_id, v_rel, v_body,
                                         p_actor,
                                         lower(coalesce(nullif(btrim(coalesce(p_file_sha,'')),''), stewards._ws_sha(p_content))),
                                         v_kp.content_sha, 'writeback');
    END IF;
    IF v_body_sha = v_row_sha THEN
        -- Both moved to the SAME content (e.g. the watcher raced the
        -- projector's record step). Nothing to write; heal the watermark.
        PERFORM stewards.knowledge_projection_record(
            'ws:' || v_ws.name || ':' || v_kind, v_id, v_target, now(), v_row_sha);
        RETURN jsonb_build_object('ok', true, 'status', 'noop',
                                  'note', 'file and row converged; watermark healed');
    END IF;
    -- BOTH changed, divergently -> park, enqueue, touch NOTHING.
    RETURN stewards._workspace_conflict(v_ws, v_rel, v_kind, v_id,
        lower(coalesce(nullif(btrim(coalesce(p_file_sha,'')),''), stewards._ws_sha(p_content))),
        v_body_sha, v_row_sha, v_kp.content_sha, p_content,
        'both the file and the row changed since projection');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'status', 'error', 'error', left(SQLERRM, 2000));
END;
$fn$;

COMMENT ON FUNCTION stewards.workspace_writeback(text, text, text, text, text) IS
'v30: the write path of the db-projected workspace. Takes the RAW file (frontmatter included) so the parse + sha-triple decision + apply are ONE transaction. Decision table (S_proj=watermark, S_file=stripped-body sha, S_row=row-body sha, both _ws_norm-alized): S_file=S_proj -> noop; S_file<>S_proj & S_row=S_proj -> apply (file wins, provenance stamped, revision archived); S_file<>S_proj & S_row<>S_proj & S_file=S_row -> heal watermark; all three differ -> conflict parked + one deduped needs_attention ask, row untouched. No frontmatter identity + no state -> CREATE a new doc/wiki-page inside the scope (flagged ''created''). Identity outside the scope -> conflict, never a write. Never RAISEs.';

-- ---------------------------------------------------------------------
-- §9 — workspace_conflict_resolve: the parking lot's exits.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.workspace_conflict_resolve(
    p_conflict_id bigint,
    p_choice      text,
    p_actor       text DEFAULT 'human'
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_c      stewards.workspace_conflicts%ROWTYPE;
    v_ws     stewards.knowledge_workspaces%ROWTYPE;
    v_choice text := lower(btrim(coalesce(p_choice, '')));
    v_body   text;
    v_res    jsonb;
BEGIN
    SELECT * INTO v_c FROM stewards.workspace_conflicts WHERE id = p_conflict_id;
    IF v_c.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no conflict %s', p_conflict_id));
    END IF;
    IF v_c.status <> 'pending' THEN
        RETURN jsonb_build_object('ok', false, 'error', format('conflict %s already resolved (%s)', v_c.id, v_c.resolution));
    END IF;
    IF v_choice NOT IN ('row-wins','file-wins','dismiss') THEN
        RETURN jsonb_build_object('ok', false, 'error', 'choice must be row-wins | file-wins | dismiss');
    END IF;
    SELECT * INTO v_ws FROM stewards.knowledge_workspaces WHERE name = v_c.workspace;

    IF v_choice = 'file-wins' THEN
        IF v_ws.id IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'error', 'workspace no longer registered — file-wins has nowhere to write');
        END IF;
        IF v_c.source_kind IS NULL OR v_c.source_id IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'error', 'this conflict has no resolved in-scope target (out-of-scope claim / unresolved identity) — file-wins is not applicable; fix the file or dismiss');
        END IF;
        SELECT s.body INTO v_body FROM stewards._ws_split_frontmatter(v_c.file_content) s;
        v_res := stewards._workspace_apply(v_ws, v_c.source_kind, v_c.source_id,
                                           v_c.relpath, v_body, p_actor,
                                           v_c.file_sha, v_c.projected_sha, 'conflict-resolve');
        IF NOT (v_res->>'ok')::boolean THEN
            RETURN v_res; -- apply failed; conflict stays pending
        END IF;
    ELSIF v_choice = 'row-wins' AND v_c.source_kind IS NOT NULL AND v_c.source_id IS NOT NULL THEN
        -- Null the watermark sha so the catalog re-pends the row and the
        -- projector rewrites the file from the row's version.
        UPDATE stewards.knowledge_projections kp
           SET content_sha = NULL
         WHERE kp.source_kind = 'ws:' || v_c.workspace || ':' || v_c.source_kind
           AND kp.source_id = v_c.source_id;
        PERFORM stewards.knowledge_project_now();
    END IF;
    -- 'dismiss' resolves the park without acting; note the row's version
    -- will re-project over the file on the next pass (the freeze lifts),
    -- so dismiss converges to row-wins passively.

    UPDATE stewards.workspace_conflicts
       SET status = 'resolved', resolution = CASE v_choice WHEN 'dismiss' THEN 'dismissed' ELSE v_choice END,
           resolved_by = p_actor, resolved_at = now(), updated_at = now()
     WHERE id = v_c.id;

    -- Retire the standing ask (best-effort; the machine path mirrors what
    -- ask_record_answer would do for a human free-text answer).
    UPDATE stewards.hinge_reviews
       SET status = 'applied', verdict = 'resolved:' || v_choice,
           reason = format('workspace conflict %s resolved (%s) by %s', v_c.id, v_choice, p_actor),
           reviewed_by = p_actor, reviewed_at = now(), applied_at = now()
     WHERE kind = 'ask' AND status IN ('pending','escalated')
       AND payload->>'workspace' = v_c.workspace AND payload->>'relpath' = v_c.relpath;

    RETURN jsonb_build_object('ok', true, 'conflict_id', v_c.id, 'resolution', v_choice,
                              'applied', CASE WHEN v_choice = 'file-wins' THEN v_res END);
END;
$fn$;

COMMENT ON FUNCTION stewards.workspace_conflict_resolve(bigint, text, text) IS
'v30: resolve a parked workspace conflict. row-wins -> null the watermark sha so the projector rewrites the file from the row; file-wins -> apply the PARKED file body through the standard provenance-stamped apply path (refused when the conflict has no in-scope target); dismiss -> resolve without acting (the freeze lifts; the row re-projects over the file on the next pass). Retires the matching needs_attention ask. Never RAISEs.';

-- ---------------------------------------------------------------------
-- §10 — workspace_list: the registry, with live counts (CLI surface).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.workspace_list()
RETURNS TABLE (
    name              text,
    scope_kind        text,
    scope_ref         text,
    dir               text,
    mode              text,
    projected         bigint,
    pending           bigint,
    conflicts         bigint,
    created_by        text,
    created_at        timestamptz,
    last_writeback_at timestamptz
) LANGUAGE sql STABLE AS $fn$
    SELECT w.name, w.scope_kind, w.scope_ref, w.dir, w.mode,
           (SELECT count(*) FROM stewards.knowledge_projections kp
             WHERE kp.source_kind LIKE 'ws:' || w.name || ':%'),
           (SELECT count(*) FROM stewards.workspace_projection_pending(w.name) p
             WHERE p.action = 'project'),
           (SELECT count(*) FROM stewards.workspace_conflicts c
             WHERE c.workspace = w.name AND c.status = 'pending'),
           w.created_by, w.created_at, w.last_writeback_at
      FROM stewards.knowledge_workspaces w
     ORDER BY w.name;
$fn$;

COMMENT ON FUNCTION stewards.workspace_list() IS
'v30: one row per registered workspace with live counts — projected (state rows on disk''s side of the ledger), pending (awaiting the next projector pass), conflicts (pending parks). Backs `stewards-cli workspace list`.';
