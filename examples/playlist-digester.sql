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
-- the cost). Uses the stewards-explore agent (has the web + book/playlist tools).

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
( 'playlist_add',
  'Watch a new YouTube playlist (or channel) for future digests. Provide title (required) and url (the playlist/channel URL).',
  '{"type":"object","required":["title","url"],"properties":{"title":{"type":"string"},"url":{"type":"string"},"position":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"playlist_add_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- Grant the playlist tools + the yt MCP tools to the explore agent.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('stewards-explore','playlist_next','allow','manual'),
    ('stewards-explore','playlist_publish','allow','manual'),
    ('stewards-explore','playlist_add','allow','manual'),
    ('stewards-explore','yt_playlist','allow','manual'),
    ('stewards-explore','yt_download','allow','manual'),
    ('stewards-explore','yt_get','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET
    action = EXCLUDED.action, source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- ── the playlist-digest pipeline ────────────────────────────────────────────
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder,
    auto_materialize_on_verified
) VALUES (
    'playlist-digest',
    'Digest the next unseen video on a watched playlist: read (find new video + fetch transcript) -> digest -> critique(null-case) -> recommend, then playlist_publish saves a study doc + brain entry. Single-pass v1. Uses the stewards-explore agent.',
    jsonb_build_array(
        jsonb_build_object('name','read','next','digest',
            'model','kimi-k2.6','provider','opencode_go','agent_family','stewards-explore',
            'auto_advance',true,'tools_disabled',false,
            'input_template',
              'You are the READ stage of the playlist digester.' || E'\n\n' ||
              '1. Call `playlist_next`. It returns {playlist_slug, playlist_url, seen_video_ids}. If it returns playlist:null, reply EXACTLY "NO PLAYLISTS" and stop.' || E'\n' ||
              '2. Call `yt_playlist` with url = playlist_url to list the playlist''s videos (id, title, url).' || E'\n' ||
              '3. Choose the FIRST video whose id is NOT in seen_video_ids. If every listed video is already in seen_video_ids, reply EXACTLY "NOTHING NEW" and stop.' || E'\n' ||
              '4. Call `yt_download` with that video''s url to fetch its transcript.' || E'\n' ||
              '5. Output, starting with these EXACT three lines:' || E'\n' ||
              '   VIDEO_ID: <the video id>' || E'\n' ||
              '   PLAYLIST: <the playlist_slug>' || E'\n' ||
              '   TITLE: <the video title>' || E'\n' ||
              '   then the full transcript. The next stage digests it — do NOT digest it yourself.' ),
        jsonb_build_object('name','digest','next','critique',
            'model','kimi-k2.6','provider','opencode_go','agent_family','stewards-explore',
            'auto_advance',true,'tools_disabled',true,
            'input_template',
              'You are the DIGEST stage. If the text below is exactly "NO PLAYLISTS" or "NOTHING NEW", reply with that same word(s) and stop.' || E'\n\n' ||
              'Here is the video header + transcript from the read stage:' || E'\n\n' ||
              '{{stage_results.read.output}}' || E'\n\n' ||
              'Digest this talk/video the way a careful student studies it — depth over breadth. KEEP the VIDEO_ID / PLAYLIST / TITLE header lines at the top of your output, then produce, in markdown:' || E'\n' ||
              '- **The core thesis / claim** (2-4 sentences).' || E'\n' ||
              '- **How it builds** — the structure of the argument.' || E'\n' ||
              '- **Key passages** — 3-6 quoted verbatim from the transcript, each with a one-line gloss.' || E'\n' ||
              '- **Themes** — the recurring ideas.' || E'\n\n' ||
              'Be faithful to the transcript. Quote only what is actually said.' ),
        jsonb_build_object('name','critique','next','recommend',
            'model','qwen3.7-plus','provider','opencode_go','agent_family','stewards-explore',
            'auto_advance',true,'tools_disabled',true,
            'input_template',
              'You are the CRITIQUE / null-case stage. If the digest below is exactly "NO PLAYLISTS" or "NOTHING NEW", reply with that same word(s) and stop.' || E'\n\n' ||
              'TRANSCRIPT (excerpt):' || E'\n' || '{{stage_results.read.output}}' || E'\n\n' ||
              'DIGEST:' || E'\n' || '{{stage_results.digest.output}}' || E'\n\n' ||
              'Pressure-test the digest: What did it flatten or miss? Is any claim unfaithful to what was actually said? What is the STRONGEST objection to the video''s thesis (the null case)? Return the digest (keep the VIDEO_ID/PLAYLIST/TITLE header), corrected where it was wrong, with a new "## Tensions & objections" section. Keep the good parts verbatim.' ),
        jsonb_build_object('name','recommend','next',NULL,
            'model','kimi-k2.6','provider','opencode_go','agent_family','stewards-explore',
            'auto_advance',true,'tools_disabled',false,
            'input_template',
              'You are the RECOMMEND stage — the final one. If the text below is exactly "NO PLAYLISTS" or "NOTHING NEW", reply with that same word(s) and do NOT publish.' || E'\n\n' ||
              'The refined digest (its first lines carry VIDEO_ID / PLAYLIST / TITLE):' || E'\n\n' ||
              '{{stage_results.critique.output}}' || E'\n\n' ||
              'Add a final section "## What''s worth learning — and what we could do with it": 3-6 concrete, actionable takeaways (not platitudes — things a person or this substrate could actually try). Then assemble the COMPLETE document (title, the digest, tensions, recommendations — you may drop the raw header lines from the published body) and call `playlist_publish` with: video_id + title + playlist (read them from the header lines) and the complete document as `body`. After publishing, output the document.' )
    ),
    false, false,
    NULL, NULL,
    '["raw","researched","planned","verified"]'::jsonb,
    false   -- playlist_publish persists directly (no file auto-materialize)
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages, updated_at = now();

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('playlist-digest','read',     'kimi-k2.6',    'Find a new video + fetch transcript; tools on (playlist_next, yt_playlist, yt_download).'),
    ('playlist-digest','digest',   'kimi-k2.6',    'Faithful study digest of the transcript; tools off.'),
    ('playlist-digest','critique', 'qwen3.7-plus', 'Null-case the digest; NOT qwen3.7-max (cost). Tools off.'),
    ('playlist-digest','recommend','kimi-k2.6',    'Actionable takeaways + playlist_publish; tools on.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity) VALUES
    ('playlist-digest','digest',   'researched'),
    ('playlist-digest','critique', 'planned'),
    ('playlist-digest','recommend','verified')
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
