-- examples/playlist-digester.sql — digest new videos on a YouTube playlist.
--
-- The #4 digester (sibling of examples/book-digester.sql). Polls a watched
-- playlist a few times a day, finds the next video it hasn't seen, pulls the
-- transcript, and digests it the way we study a talk: read -> digest ->
-- critique(null-case) -> recommend, then publishes a study doc + brain entry
-- with the actionable "what to learn / what to do" takeaways.
--
-- PREREQUISITE — the YouTube overlay. This needs the yt-mcp tools, which are
-- opt-in (the generic core image has no python/yt-dlp). Bring the stack up with
-- the yt overlay, THEN import this file:
--   docker compose -f docker-compose.yaml -f docker-compose.yt.yaml up -d --build
--   docker compose exec -T pg psql -U stewards -d stewards < examples/playlist-digester.sql
--   docker compose exec bridge stewards-mcp bridge refresh-tools
--
-- Also import the model catalog first (examples/models.sql) with a provider
-- configured. Models: kimi-k2.6 (doer), qwen3.7-plus (critic, NOT -max — ~2x
-- the cost). Uses the research agent (has the web + book/playlist tools).

-- ── the yt MCP server (opt-in; bridge must be built WITH_YT=1) ───────────────
INSERT INTO stewards.mcp_servers (name, description, transport, command, args, url, env, enabled)
VALUES (
  'yt',
  'YouTube transcripts + playlist discovery via yt-dlp. Tools: yt_playlist '
    || '(list a playlist/channel''s videos WITHOUT downloading), yt_download '
    || '(fetch one video''s English transcript + metadata), yt_get (read a '
    || 'previously downloaded video), yt_list / yt_search (over downloaded '
    || 'transcripts). OPT-IN: requires the yt overlay bridge (python3 + yt-dlp); '
    || 'see docker-compose.yt.yaml.',
  'stdio',
  '/usr/local/bin/yt-mcp',
  ARRAY['serve'],   -- yt-mcp needs the `serve` subcommand to start the MCP loop
  NULL,
  '{"YT_DIR": "/yt"}'::jsonb,
  true
)
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description, command = EXCLUDED.command,
  args = EXCLUDED.args, env = EXCLUDED.env, enabled = true;

-- ── watched playlists ───────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stewards.playlist_watch (
    slug            text PRIMARY KEY CHECK (slug ~ '^[a-z0-9-]+$'),
    title           text NOT NULL,
    playlist_url    text NOT NULL,
    position        int  NOT NULL DEFAULT 100,
    status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active','paused')),
    last_checked_at timestamptz,
    added_by        text NOT NULL DEFAULT 'seed',
    added_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.playlist_watch IS
'playlist-digester watch list. playlist_next() round-robins active rows by last_checked_at; each tick digests one not-yet-seen video.';

-- ── digested videos (global dedupe — a video id is digested at most once) ────
CREATE TABLE IF NOT EXISTS stewards.playlist_seen (
    video_id      text PRIMARY KEY,
    playlist_slug text,                       -- informational; no hard FK so a
                                              -- mismatched slug can't block a publish
    title         text,
    doc_id        text,
    digested_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.playlist_seen IS
'Videos already digested. video_id is globally unique on YouTube, so this is the dedupe set: playlist_next() hands the agent every seen id to skip.';

-- ── playlist_next(): claim the next playlist to check + the global seen set ──
CREATE OR REPLACE FUNCTION stewards.playlist_next()
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE v_row stewards.playlist_watch%ROWTYPE; v_seen jsonb;
BEGIN
    SELECT * INTO v_row FROM stewards.playlist_watch
     WHERE status = 'active'
     ORDER BY last_checked_at ASC NULLS FIRST, position, added_at
     LIMIT 1 FOR UPDATE SKIP LOCKED;
    IF v_row.slug IS NULL THEN RETURN NULL; END IF;
    UPDATE stewards.playlist_watch SET last_checked_at = now() WHERE slug = v_row.slug;
    SELECT COALESCE(jsonb_agg(video_id), '[]'::jsonb) INTO v_seen
      FROM stewards.playlist_seen;
    RETURN jsonb_build_object('playlist_slug', v_row.slug,
                              'playlist_url', v_row.playlist_url,
                              'seen_video_ids', v_seen);
END $func$;

CREATE OR REPLACE FUNCTION stewards.playlist_next_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $func$
    SELECT COALESCE(stewards.playlist_next()::text,
                    '{"playlist": null, "note": "no active playlists to check"}');
$func$;

-- ── playlist_publish(): save a video digest + mark the video seen ───────────
CREATE OR REPLACE FUNCTION stewards.playlist_publish(
    p_video_id text, p_title text, p_body text, p_playlist_slug text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE v_doc text; v_id text;
BEGIN
    v_id := trim(COALESCE(p_video_id, ''));
    IF v_id = '' THEN
        RETURN '{"ok": false, "note": "video_id is required"}'::jsonb;
    END IF;
    -- Deterministic floor: a real YouTube id is exactly 11 chars of
    -- [A-Za-z0-9_-]. Reject anything else so a failed yt_playlist listing
    -- (or a run that should have emitted "NOTHING NEW") can't publish a
    -- placeholder digest like "(unknown)". The model can misbehave; the
    -- write boundary still refuses garbage.
    IF v_id !~ '^[A-Za-z0-9_-]{11}$' THEN
        RETURN jsonb_build_object('ok', false,
            'note', format('video_id %L is not a valid YouTube id — not publishing. A failed listing or "NOTHING NEW" should stop before publish.', v_id));
    END IF;
    IF p_body IS NULL OR length(trim(p_body)) < 100 THEN
        RETURN '{"ok": false, "note": "digest body too short to publish"}'::jsonb;
    END IF;
    v_doc := stewards.import_doc(
        'yt-' || v_id,
        'study/yt/' || v_id || '.md',
        'Digest: ' || COALESCE(p_title, v_id),
        p_body,
        jsonb_build_object('source_type','playlist-digest','video_id',v_id,
                           'video_title',p_title,'playlist_slug',p_playlist_slug,
                           'video_url','https://www.youtube.com/watch?v=' || v_id),
        'doc');
    INSERT INTO stewards.pending_file_writes
        (requested_by, target_path, write_mode, content, source_id, source_kind)
    VALUES ('playlist_publish', 'study/yt/' || v_id || '.md', 'create',
            p_body, v_doc, 'playlist-digest');
    PERFORM stewards.brain_upsert('ideas',
        'Video digest: ' || COALESCE(p_title, v_id),
        left(p_body, 4000),
        jsonb_build_object('video_id', v_id, 'doc_id', v_doc, 'playlist_slug', p_playlist_slug),
        ARRAY['playlist-digest', COALESCE(p_playlist_slug, 'video')]);
    INSERT INTO stewards.playlist_seen (video_id, playlist_slug, title, doc_id)
    VALUES (v_id, p_playlist_slug, p_title, v_doc)
    ON CONFLICT (video_id) DO UPDATE SET
        title = EXCLUDED.title, doc_id = EXCLUDED.doc_id, digested_at = now();
    RETURN jsonb_build_object('ok', true, 'doc_id', v_doc, 'video_id', v_id,
                              'path', 'study/yt/' || v_id || '.md');
END $func$;

CREATE OR REPLACE FUNCTION stewards.playlist_publish_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $func$
    SELECT stewards.playlist_publish(
        COALESCE(p_args->>'video_id', p_args->>'id'),
        COALESCE(p_args->>'title', p_args->>'video_title'),
        COALESCE(p_args->>'body', p_args->>'digest', p_args->>'document'),
        COALESCE(p_args->>'playlist', p_args->>'playlist_slug'))::text;
$func$;

-- ── playlist_publish_draft(): publish a doc-construction DRAFT (the doc-builder
--    path). The model built the digest incrementally with doc_create/append; here
--    we pull its body SERVER-SIDE by handle (the model never re-emits the whole
--    body as a tool arg — that would be the one-shot generation we are avoiding),
--    run the same publish logic as playlist_publish, then clear the draft.
CREATE OR REPLACE FUNCTION stewards.playlist_publish_draft_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $func$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_vid    text := coalesce(p_args ->> 'video_id', p_args ->> 'id');
    v_title  text := coalesce(p_args ->> 'title', p_args ->> 'video_title');
    v_play   text := coalesce(p_args ->> 'playlist', p_args ->> 'playlist_slug');
    v_body   text;
    v_res    jsonb;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN '{"ok":false,"note":"no session context"}'; END IF;
    IF v_handle = '' THEN RETURN '{"ok":false,"note":"handle required (from doc_create)"}'; END IF;
    SELECT body, COALESCE(v_title, title) INTO v_body, v_title
      FROM stewards.doc_drafts WHERE handle = v_handle AND session_id = v_sess;
    IF v_body IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'note', 'no draft ' || v_handle || ' in your session — doc_create + doc_append_section first')::text;
    END IF;
    -- reuse the exact publish boundary (video-id guard, import_doc, file write, brain, seen-set)
    v_res := stewards.playlist_publish(v_vid, v_title, v_body, v_play);
    IF (v_res->>'ok')::boolean THEN
        DELETE FROM stewards.doc_drafts WHERE handle = v_handle AND session_id = v_sess;
        v_res := v_res || jsonb_build_object('note', 'published from draft ' || v_handle || ' and cleared it. Your reply now is a short JOURNAL of what you did — do NOT paste the digest.');
    END IF;
    RETURN v_res::text;
END $func$;

-- ── playlist_add(): watch a new playlist ────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.playlist_add(
    p_title text, p_url text, p_position int DEFAULT 100)
RETURNS text LANGUAGE plpgsql AS $func$
DECLARE v_slug text;
BEGIN
    v_slug := trim(both '-' from lower(regexp_replace(p_title, '[^a-zA-Z0-9]+', '-', 'g')));
    IF v_slug = '' THEN v_slug := 'playlist-' || substr(md5(random()::text),1,8); END IF;
    INSERT INTO stewards.playlist_watch (slug, title, playlist_url, position, added_by)
    VALUES (v_slug, p_title, p_url, p_position, 'tool')
    ON CONFLICT (slug) DO NOTHING;
    RETURN v_slug;
END $func$;

CREATE OR REPLACE FUNCTION stewards.playlist_add_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $func$
    SELECT jsonb_build_object('added_slug',
        stewards.playlist_add(p_args->>'title', p_args->>'url',
                              COALESCE((p_args->>'position')::int, 100)))::text;
$func$;

-- ── tool defs ───────────────────────────────────────────────────────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'playlist_next',
  'Claim the next watched playlist to check. Returns {playlist_slug, playlist_url, seen_video_ids:[...]} — the playlist to scan and the ids you have ALREADY digested (skip those). Returns {playlist: null} if nothing is being watched. Call this FIRST.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"playlist_next_tool"}'::jsonb ),
( 'playlist_publish',
  'Save the finished digest of one video and mark it seen so it is never re-digested. Pass video_id, title, the playlist slug, and the COMPLETE digest as `body`. Writes study/yt/<video_id>.md + a brain entry. Call this LAST, once.',
  '{"type":"object","required":["video_id","body"],"properties":{"video_id":{"type":"string"},"title":{"type":"string"},"playlist":{"type":"string","description":"the playlist_slug from playlist_next"},"body":{"type":"string","minLength":100,"description":"the complete digest document (markdown)"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"playlist_publish_tool"}'::jsonb ),
( 'playlist_publish_draft',
  'Publish the video digest you BUILT with the doc tools (doc_create/doc_append_section). Pass the draft `handle` plus video_id, title, and the playlist slug — NOT the body (the body is pulled from your draft server-side, so you never re-emit the whole document). Marks the video seen so it is never re-digested. Call this LAST, once, after the draft is complete.',
  '{"type":"object","required":["handle","video_id"],"properties":{"handle":{"type":"string","description":"the draft handle from doc_create"},"video_id":{"type":"string"},"title":{"type":"string"},"playlist":{"type":"string","description":"the playlist_slug from playlist_next"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"playlist_publish_draft_tool"}'::jsonb ),
( 'playlist_add',
  'Watch a new YouTube playlist (or channel) for future digests. Provide title (required) and url (the playlist/channel URL).',
  '{"type":"object","required":["title","url"],"properties":{"title":{"type":"string"},"url":{"type":"string"},"position":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"playlist_add_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- Grant the playlist tools + the yt MCP tools to the explore agent.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','playlist_next','allow','manual'),
    ('research','playlist_publish','allow','manual'),
    ('research','playlist_publish_draft','allow','manual'),
    ('research','playlist_add','allow','manual'),
    ('research','yt_playlist','allow','manual'),
    ('research','yt_download','allow','manual'),
    ('research','yt_get','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET
    action = EXCLUDED.action, source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- ── the playlist-digest pipeline ────────────────────────────────────────────
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder,
    auto_materialize_on_verified
) VALUES (
    'playlist-digest',
    'Digest the next unseen video on a watched playlist. read (find new video + cache transcript, emit header only) -> build (fetch transcript via yt_get, construct the digest as a DOCUMENT via doc_* tool-call diffs, then playlist_publish_draft from the handle). The model never one-shots the digest; its reply is a journal. Doc-construction recast (agentic-doc-construction.md) — fixes the local reaper/contention/grammar failures. Uses the research agent.',
    jsonb_build_array(
        -- READ: find a new video, CACHE its transcript, emit ONLY the header.
        -- It does NOT echo the transcript (a long transcript re-emit is itself a
        -- one-shot generation that trips the reaper on a local model). The build
        -- stage fetches the cached transcript via yt_get + page-in.
        jsonb_build_object('name','read','next','build',
            'model','ingest','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            'input_template',
              'You are the READ stage of the playlist digester.' || E'\n\n' ||
              '1. Call `playlist_next`. It returns {playlist_slug, playlist_url, seen_video_ids}. If it returns playlist:null, reply EXACTLY "NO PLAYLISTS" and stop.' || E'\n' ||
              '2. Call `yt_playlist` with url = playlist_url to list the playlist''s videos (id, title, url).' || E'\n' ||
              '3. Choose the FIRST video whose id is NOT in seen_video_ids. If every listed video is already in seen_video_ids, reply EXACTLY "NOTHING NEW" and stop.' || E'\n' ||
              '4. Call `yt_download` with that video''s url to fetch + CACHE its transcript. You do NOT need to read or repeat the transcript.' || E'\n' ||
              '5. Output EXACTLY these three lines and NOTHING ELSE (no transcript — the build stage fetches it):' || E'\n' ||
              '   VIDEO_ID: <the video id>' || E'\n' ||
              '   PLAYLIST: <the playlist_slug>' || E'\n' ||
              '   TITLE: <the video title>' ),
        -- BUILD: construct the digest as a DOCUMENT via tool-call diffs (doc_*),
        -- then publish from the draft handle. The model never emits the whole
        -- digest as one generation — it builds it section by section and its
        -- chat reply is a short journal. (agentic-doc-construction.md)
        jsonb_build_object('name','build','next',NULL,
            'model','reason','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            'input_template',
              'You are the BUILD stage. BUILD the digest as a document using your doc tools — do NOT write the digest as your reply.' || E'\n\n' ||
              'The read stage gave you this header:' || E'\n\n' ||
              '{{stage_results.read.output}}' || E'\n\n' ||
              'Steps:' || E'\n' ||
              '1. Read the VIDEO_ID, PLAYLIST, and TITLE from the header above.' || E'\n' ||
              '2. Call `yt_get` with the video_id to read the cached transcript. If it is large you will see a [page-in] banner with a handle — use `result_read`(handle, offset, limit) to read it in chunks; do not pull it all at once.' || E'\n' ||
              '3. Call `doc_create` with title = the TITLE and project "ai".' || E'\n' ||
              '4. Build the digest with `doc_append_section` (one call each, keep each small, faithful to the transcript, quote only what is actually said):' || E'\n' ||
              '   - "Thesis" — the core claim in 2-4 sentences.' || E'\n' ||
              '   - "How it builds" — the structure of the argument.' || E'\n' ||
              '   - "Key passages" — 3-6 verbatim quotes, each with a one-line gloss.' || E'\n' ||
              '   - "Themes" — the recurring ideas.' || E'\n' ||
              '   - "Tensions & objections" — the STRONGEST objection to the thesis (the null case); be honest, not agreeable.' || E'\n' ||
              '   - "What''s worth learning" — 3-6 concrete, actionable takeaways (not platitudes).' || E'\n' ||
              '5. Call `doc_read` to review the whole draft; fix anything weak with `doc_patch`.' || E'\n' ||
              '6. Call `playlist_publish_draft` with the handle + video_id + title + playlist (from the header). This publishes the doc and marks the video seen.' || E'\n' ||
              '7. Finally, reply with a short JOURNAL (2-4 sentences): what the video argued, what you built, and the slug. Do NOT paste the document.' )
    ),
    false, false,
    NULL, NULL,
    '["raw","verified"]'::jsonb,
    false   -- playlist_publish_draft persists directly (no file auto-materialize)
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages, updated_at = now();

-- recast read/build (drop the old digest/critique/recommend rows — orphaned by the recast)
DELETE FROM stewards.stage_models
 WHERE pipeline_family='playlist-digest' AND stage_name IN ('digest','critique','recommend');
INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('playlist-digest','read',  'ingest', 'Find a new video + cache transcript, emit header only; tools on (playlist_next/yt_playlist/yt_download). Local ingest alias (gemma).'),
    ('playlist-digest','build', 'reason', 'Build the digest as a doc via doc_* tool-call diffs + playlist_publish_draft; tools on. Local reason alias (qwen).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

DELETE FROM stewards.pipeline_stage_maturity
 WHERE pipeline_family='playlist-digest' AND stage_name IN ('digest','critique','recommend');
INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity) VALUES
    ('playlist-digest','build','verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

-- ── the video-study intent (the core ships no intents; seed our own) ─────────
INSERT INTO stewards.intents (slug, purpose, beneficiary, values_hierarchy, values_anchor)
VALUES (
    'video-study',
    'Watch freely-available talks and videos with depth; extract what is worth learning and what we could do with it, while staying current with a topic.',
    'the operator and the substrate''s own growth',
    jsonb_build_array(
        jsonb_build_object('key','faithful-to-the-source','description','Understand before judging; quote before summarizing. The digest must be true to what was actually said.'),
        jsonb_build_object('key','depth-over-breadth','description','A few ideas understood deeply beat a list of topics skimmed.'),
        jsonb_build_object('key','name-the-null-case','description','State the strongest objection to the video''s thesis. Intellectual honesty over agreement.'),
        jsonb_build_object('key','actionable-learning','description','End with what a person or this substrate could actually try, not platitudes.')
    ),
    'Watch the way a careful student listens: understand before you judge, quote before you summarize, and name what you would do differently.'
)
ON CONFLICT (slug) DO NOTHING;

-- ── schedule: a few times a day ─────────────────────────────────────────────
INSERT INTO stewards.scheduled_pipelines (slug, pipeline_family, intent_id, cron_pattern, input_template, enabled, missed_window_hours, notes)
VALUES (
    'playlist-digest-cron', 'playlist-digest',
    (SELECT id FROM stewards.intents WHERE slug = 'video-study' LIMIT 1),
    '0 */6 * * *',
    '{"assignment": "Check the watched playlists for a new video and digest it. Call playlist_next to get your assignment."}'::jsonb,
    true, 4,
    'playlist-digester: every 6 hours, digest one not-yet-seen video (playlist_next claims a playlist; playlist_publish marks the video seen).'
)
ON CONFLICT (slug) DO UPDATE SET
    pipeline_family = EXCLUDED.pipeline_family, cron_pattern = EXCLUDED.cron_pattern,
    input_template = EXCLUDED.input_template, enabled = EXCLUDED.enabled, updated_at = now();

-- ── starter watch list (operator content — edit freely) ─────────────────────
INSERT INTO stewards.playlist_watch (slug, title, playlist_url, position) VALUES
    ('ai-research', 'AI research',
     'https://www.youtube.com/playlist?list=PLcHf1NPbY2qXi5MkL-BzJb7t4r-m8SIEq', 10)
ON CONFLICT (slug) DO NOTHING;

-- ── empty-source halt (generic: core work_item_advance honors metadata.halt_on) ──
-- The read stage replies "NO PLAYLISTS" (nothing watched) or "NOTHING NEW" (every
-- video already digested). Declaring halt_on makes core work_item_advance cancel
-- at the read stage and not advance — no wasted digest/critique/recommend, nothing
-- pooled. (Replaces the per-pipeline BEFORE-UPDATE guard, which raced the dispatcher;
-- see digester-empty-source-halt.)
UPDATE stewards.pipelines
   SET metadata = COALESCE(metadata, '{}'::jsonb)
                || jsonb_build_object('halt_on',
                       jsonb_build_object('stage','read','outputs', jsonb_build_array('NO PLAYLISTS','NOTHING NEW'))),
       updated_at = now()
 WHERE family = 'playlist-digest';
DROP TRIGGER IF EXISTS work_items_playlist_digest_skip_empty ON stewards.work_items;
DROP FUNCTION IF EXISTS stewards.playlist_digest_skip_empty();
