-- =====================================================================
-- yt-transcripts.sql — persist YouTube transcripts into the DB (opt-in yt overlay).
-- =====================================================================
-- The yt-mcp downloads each video's transcript to the bridge's `yt-transcripts`
-- volume (`/yt/<channel>/<videoID>/{transcript.md,metadata.json,cues.json}`).
-- This makes those transcripts queryable from SQL — so the quote oracle can verify
-- video quotes against the real transcript, and the digest critique can self-check.
--
-- The pg container must MOUNT that volume to read the files. docker-compose.yt.yaml
-- mounts `yt-transcripts:/yt:ro` into pg; the path is configurable via the
-- `yt_dir` config key (default `/yt`). `stewards` is superuser so pg_read_file/
-- pg_ls_dir on the mount work.
--
-- Apply AFTER the yt overlay is up and pg has the mount:
--   docker compose -f docker-compose.yaml -f docker-compose.yt.yaml up -d pg
--   psql ... -f examples/yt-transcripts.sql
-- Then the playlist digester's read stage calls import_yt_transcript(video_id)
-- after it caches the video, and `verify-digest-quotes.py` can check yt-* docs.
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.yt_transcripts (
    video_id         text PRIMARY KEY,
    channel_slug     text,
    title            text,
    duration_seconds int,
    published_at     timestamptz,
    full_text        text,
    metadata         jsonb,
    imported_at      timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    body_tsv         tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(full_text, ''))) STORED
);
COMMENT ON TABLE stewards.yt_transcripts IS
'One row per imported YouTube video — full_text + metadata, FTS via body_tsv. Populated by import_yt_transcript from the bridge yt volume. The quote oracle + the digest critique read full_text/body_tsv to verify video quotes.';

CREATE INDEX IF NOT EXISTS yt_transcripts_body_tsv_idx ON stewards.yt_transcripts USING gin (body_tsv);

CREATE TABLE IF NOT EXISTS stewards.yt_transcript_segments (
    video_id      text NOT NULL,
    segment_idx   int  NOT NULL,
    start_seconds real,
    end_seconds   real,
    text          text,
    PRIMARY KEY (video_id, segment_idx)
);
COMMENT ON TABLE stewards.yt_transcript_segments IS
'Timestamped cues for a transcript (begin/end/text). Re-built idempotently by import_yt_transcript.';

-- ── import_yt_transcript(video_id) — read the bridge volume files → upsert the DB.
--    Path is config-driven (yt_dir, default /yt) so it works on any deployment that
--    mounts the yt volume into pg. Server-side read = the digester never re-emits the
--    (possibly large/paged-in) transcript as a tool arg.
CREATE OR REPLACE FUNCTION stewards.import_yt_transcript(p_video_id text)
RETURNS text LANGUAGE plpgsql AS $function$
DECLARE
    v_root            text := stewards.config_get_text('yt_dir', '/yt');
    v_channel_slug    text;
    v_dir             text;
    v_metadata_path   text;
    v_cues_path       text;
    v_transcript_path text;
    v_metadata_json   jsonb;
    v_cues_json       jsonb;
    v_title           text;
    v_duration        int;
    v_upload_date     text;
    v_published_at    timestamptz;
    v_full_text       text;
    v_segments_count  int := 0;
    v_channel_dirs    text[];
    v_chan            text;
BEGIN
    IF p_video_id IS NULL OR length(p_video_id) = 0 THEN
        RAISE EXCEPTION 'import_yt_transcript: video_id required';
    END IF;

    -- Discover channel_slug by listing yt_dir/* and finding the one whose subdir
    -- matches p_video_id.
    SELECT array_agg(d) INTO v_channel_dirs FROM pg_ls_dir(v_root) d;
    IF v_channel_dirs IS NULL THEN
        RAISE NOTICE 'import_yt_transcript: % not readable from pg container (is the yt volume mounted there?)', v_root;
        RETURN NULL;
    END IF;

    FOREACH v_chan IN ARRAY v_channel_dirs LOOP
        BEGIN
            IF EXISTS (
                SELECT 1 FROM pg_ls_dir(v_root || '/' || v_chan || '/' || p_video_id) LIMIT 1
            ) THEN
                v_channel_slug := v_chan;
                EXIT;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            -- pg_ls_dir raises if the path doesn't exist or isn't a directory;
            -- treat as "not this channel" and keep scanning.
            CONTINUE;
        END;
    END LOOP;

    IF v_channel_slug IS NULL THEN
        RAISE NOTICE 'import_yt_transcript: video_id % not found under % (have you yt_download''d it?)',
            p_video_id, v_root;
        RETURN NULL;
    END IF;

    v_dir             := v_root || '/' || v_channel_slug || '/' || p_video_id;
    v_metadata_path   := v_dir || '/metadata.json';
    v_cues_path       := v_dir || '/cues.json';
    v_transcript_path := v_dir || '/transcript.md';

    -- metadata.json → jsonb. Required.
    BEGIN
        v_metadata_json := pg_read_file(v_metadata_path)::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'import_yt_transcript: failed to read %: %', v_metadata_path, SQLERRM;
        RETURN NULL;
    END;

    v_title       := coalesce(v_metadata_json->>'title', p_video_id);
    v_duration    := nullif(v_metadata_json->>'duration', '')::int;
    v_upload_date := v_metadata_json->>'upload_date';
    -- yt-dlp upload_date is YYYYMMDD. Convert to timestamptz at midnight UTC.
    IF v_upload_date IS NOT NULL AND length(v_upload_date) = 8 THEN
        v_published_at := to_timestamp(v_upload_date, 'YYYYMMDD') AT TIME ZONE 'UTC';
    END IF;

    -- cues.json → jsonb array of {begin,end,text}. Optional.
    BEGIN
        v_cues_json := pg_read_file(v_cues_path)::jsonb;
    EXCEPTION WHEN OTHERS THEN
        v_cues_json := NULL;
    END;

    -- transcript.md → full_text. If absent, derive from cues. If both absent, empty.
    BEGIN
        v_full_text := pg_read_file(v_transcript_path);
    EXCEPTION WHEN OTHERS THEN
        IF v_cues_json IS NOT NULL THEN
            SELECT string_agg(c->>'text', ' ' ORDER BY ord)
              INTO v_full_text
              FROM jsonb_array_elements(v_cues_json) WITH ORDINALITY t(c, ord);
        ELSE
            v_full_text := '';
        END IF;
    END;

    -- UPSERT yt_transcripts.
    INSERT INTO stewards.yt_transcripts (
        video_id, channel_slug, title, duration_seconds, published_at,
        full_text, metadata, imported_at, updated_at
    ) VALUES (
        p_video_id, v_channel_slug, v_title, v_duration, v_published_at,
        coalesce(v_full_text, ''), coalesce(v_metadata_json, '{}'::jsonb), now(), now()
    )
    ON CONFLICT (video_id) DO UPDATE SET
        channel_slug     = EXCLUDED.channel_slug,
        title            = EXCLUDED.title,
        duration_seconds = EXCLUDED.duration_seconds,
        published_at     = EXCLUDED.published_at,
        full_text        = EXCLUDED.full_text,
        metadata         = EXCLUDED.metadata,
        updated_at       = now();

    -- DELETE + re-INSERT segments. Idempotent.
    DELETE FROM stewards.yt_transcript_segments WHERE video_id = p_video_id;

    IF v_cues_json IS NOT NULL AND jsonb_typeof(v_cues_json) = 'array' THEN
        INSERT INTO stewards.yt_transcript_segments
            (video_id, segment_idx, start_seconds, end_seconds, text)
        SELECT
            p_video_id, (ord - 1)::int,
            coalesce((c->>'begin')::real, 0),
            coalesce((c->>'end')::real, 0),
            coalesce(c->>'text', '')
          FROM jsonb_array_elements(v_cues_json) WITH ORDINALITY t(c, ord);
        GET DIAGNOSTICS v_segments_count = ROW_COUNT;
    ELSIF v_duration IS NOT NULL AND length(coalesce(v_full_text,'')) > 0 THEN
        INSERT INTO stewards.yt_transcript_segments
            (video_id, segment_idx, start_seconds, end_seconds, text)
        VALUES (p_video_id, 0, 0, v_duration, v_full_text);
        v_segments_count := 1;
    END IF;

    RAISE NOTICE 'import_yt_transcript: % ingested (channel=%, segments=%, full_text_chars=%)',
        p_video_id, v_channel_slug, v_segments_count, length(coalesce(v_full_text,''));
    RETURN p_video_id;
END;
$function$;

-- ── yt_persist_transcript tool — let the playlist digester persist the transcript
--    of the video it just cached (server-side file read; no transcript re-emit).
--    Guards the video_id to a YouTube id shape so a crafted id can't path-traverse
--    the pg_read_file/pg_ls_dir under yt_dir.
CREATE OR REPLACE FUNCTION stewards.yt_persist_transcript_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE v_vid text := coalesce(p_args->>'video_id', p_args->>'id', '');
BEGIN
    IF v_vid !~ '^[A-Za-z0-9_-]{11}$' THEN
        RETURN jsonb_build_object('ok', false, 'note',
            'video_id must be an 11-char YouTube id ([A-Za-z0-9_-])')::text;
    END IF;
    RETURN jsonb_build_object('ok', stewards.import_yt_transcript(v_vid) IS NOT NULL,
                              'video_id', v_vid,
                              'note', 'transcript persisted to yt_transcripts (or NULL if not yet downloaded)')::text;
END;
$fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'yt_persist_transcript',
  'Persist the transcript of a video you just cached (yt_download) into the database so it can be quote-verified later. Pass the 11-char YouTube video_id. Call this in the read stage AFTER the video is downloaded. Server-side — you do NOT pass the transcript text.',
  '{"type":"object","required":["video_id"],"properties":{"video_id":{"type":"string","description":"the 11-char YouTube video id"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"yt_persist_transcript_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','yt_persist_transcript','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ── transcript_search — verify a quote against a stored transcript (the digest
--    self-check, Pillar 3b). Returns whether the phrase is a verbatim substring of
--    the transcript (whitespace-normalized) + highlighted snippets, so the build
--    stage can confirm a quote before publishing and fix/de-quote any that miss.
CREATE OR REPLACE FUNCTION stewards.transcript_search_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_vid  text := coalesce(p_args->>'video_id', p_args->>'id', '');
    v_q    text := coalesce(p_args->>'query', p_args->>'quote', '');
    v_full text;
    v_found boolean;
    v_snip text;
BEGIN
    IF v_vid = '' OR v_q = '' THEN
        RETURN jsonb_build_object('error', 'video_id and query required')::text;
    END IF;
    SELECT full_text INTO v_full FROM stewards.yt_transcripts WHERE video_id = v_vid;
    IF v_full IS NULL THEN
        RETURN jsonb_build_object('found', false,
            'note', 'no transcript stored for this video_id (read stage calls yt_persist_transcript)')::text;
    END IF;
    v_found := position(lower(regexp_replace(v_q, '\s+', ' ', 'g'))
                        in lower(regexp_replace(v_full, '\s+', ' ', 'g'))) > 0;
    v_snip := ts_headline('english', v_full, plainto_tsquery('english', v_q),
                          'MaxFragments=2,MinWords=5,MaxWords=20,StartSel=[[,StopSel=]]');
    RETURN jsonb_build_object('found', v_found, 'snippets', left(coalesce(v_snip, ''), 600),
        'note', CASE WHEN v_found THEN 'verbatim match — keep the quote'
                     ELSE 'NOT a verbatim substring — fix the quote to the EXACT transcript words or remove the quotation marks' END)::text;
END;
$fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'transcript_search',
  'Check whether a quote appears VERBATIM in a video transcript before you publish it. Pass video_id (11-char) + query (the quoted phrase). Returns {found, snippets}. If found=false, fix the quote to the exact words or drop the quotation marks.',
  '{"type":"object","required":["video_id","query"],"properties":{"video_id":{"type":"string"},"query":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"transcript_search_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','transcript_search','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- SLIDE FRAMES (Part B of yt-slide-frames.md) — teach the digester to SEE slides.
-- =====================================================================
-- The OSS yt-mcp (built WITH_YT=1, now ffmpeg-equipped) writes slide screenshots
-- to the bridge /yt volume: /yt/<channel>/<videoID>/frames/*.png + frames.json
-- (sec/file/t_link). The core file 78 supplies the generic vision mechanism — a
-- `caption` on an image attachment that renders as a text part right before the
-- image (47/49 multimodal), plus align_slide_captions(frames,cues). This OVERLAY
-- glue (like import_yt_transcript: needs the /yt mount) reads the PNG bytes
-- server-side and turns each frame into a captioned image attachment the digest's
-- vision model can read. The digester never re-emits the pixels as a tool arg.

-- ── import_yt_frames(video_id, session_id) — /yt frames → captioned attachments.
--    Reads frames.json (+ cues.json for narration) from the mounted /yt volume,
--    aligns each frame to the transcript via align_slide_captions (78), and inserts
--    one image attachment per frame (kind='image', parent_id = a 'document' for the
--    video, caption = "[slide at Ns — ?t= link] narration"). Idempotent per
--    (session, video). Returns {ok, frames, parent_id, attachment_ids}.
CREATE OR REPLACE FUNCTION stewards.import_yt_frames(p_video_id text, p_session_id text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_root         text := stewards.config_get_text('yt_dir', '/yt');
    v_channel_dirs text[];
    v_chan         text;
    v_channel_slug text;
    v_dir          text;
    v_frames_json  jsonb;
    v_cues_json    jsonb;
    v_meta         jsonb;
    v_aligned      jsonb;
    v_title        text;
    v_web          text;
    v_parent       bigint;
    v_id           bigint;
    v_ids          bigint[] := ARRAY[]::bigint[];
    v_frame        jsonb;
    v_png          bytea;
    v_sec          int;
    v_caption      text;
    v_n            int := 0;
BEGIN
    IF p_video_id !~ '^[A-Za-z0-9_-]{11}$' THEN
        RETURN jsonb_build_object('ok', false, 'note', 'video_id must be an 11-char YouTube id');
    END IF;
    IF coalesce(p_session_id, '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'note', 'session_id required (the digest session the slides attach to)');
    END IF;

    -- discover channel_slug under /yt (same scan as import_yt_transcript)
    SELECT array_agg(d) INTO v_channel_dirs FROM pg_ls_dir(v_root) d;
    IF v_channel_dirs IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'note', format('%s not readable from pg (is the yt volume mounted? see docker-compose.yt.yaml)', v_root));
    END IF;
    FOREACH v_chan IN ARRAY v_channel_dirs LOOP
        BEGIN
            IF EXISTS (SELECT 1 FROM pg_ls_dir(v_root||'/'||v_chan||'/'||p_video_id) LIMIT 1) THEN
                v_channel_slug := v_chan; EXIT;
            END IF;
        EXCEPTION WHEN OTHERS THEN CONTINUE;  -- not this channel
        END;
    END LOOP;
    IF v_channel_slug IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'note', format('video %s not found under %s — yt_slides/yt_frames it first', p_video_id, v_root));
    END IF;

    v_dir := v_root||'/'||v_channel_slug||'/'||p_video_id;

    -- frames.json required; cues.json + metadata.json optional
    BEGIN
        v_frames_json := pg_read_file(v_dir||'/frames.json')::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false,
            'note', 'no frames.json for this video — run yt_frames or yt_slides first');
    END;
    BEGIN v_cues_json := pg_read_file(v_dir||'/cues.json')::jsonb;    EXCEPTION WHEN OTHERS THEN v_cues_json := NULL; END;
    BEGIN v_meta      := pg_read_file(v_dir||'/metadata.json')::jsonb; EXCEPTION WHEN OTHERS THEN v_meta := '{}'::jsonb; END;
    v_title := coalesce(v_meta->>'title', p_video_id);
    v_web   := coalesce(v_meta->>'url', 'https://www.youtube.com/watch?v='||p_video_id);

    -- 78: align each frame to the transcript narration spoken over it
    v_aligned := stewards.align_slide_captions(v_frames_json, v_cues_json);

    -- the session the slides attach to
    INSERT INTO stewards.sessions (id, kind) VALUES (p_session_id, 'chat') ON CONFLICT DO NOTHING;

    -- idempotent: clear any prior frames for this video in this session
    DELETE FROM stewards.chat_attachments
     WHERE session_id = p_session_id
       AND filename LIKE 'yt:'||p_video_id||':%';

    -- a parent 'document' for the video (the frames group under it; referencing
    -- the doc pulls every frame as the 49 pixel overlay — use slides_read to page
    -- them in a few at a time instead of all at once)
    INSERT INTO stewards.chat_attachments (session_id, kind, filename, extracted_text)
    VALUES (p_session_id, 'document', 'yt:'||p_video_id||':slides',
            'Slide frames for "'||v_title||'" ('||v_web||E').\n'||
            'Each child image is one slide, captioned with the transcript narration spoken over it.')
    RETURNING id INTO v_parent;

    FOR v_frame IN SELECT value FROM jsonb_array_elements(v_aligned) LOOP
        v_sec := (v_frame->>'sec')::int;
        BEGIN
            v_png := pg_read_binary_file(v_dir||'/'||(v_frame->>'file'));
        EXCEPTION WHEN OTHERS THEN
            CONTINUE;  -- a capped/missing frame referenced by the manifest; skip
        END;
        v_caption := '[Slide at '||v_sec||'s — '||(v_frame->>'t_link')||']'
                     || CASE WHEN coalesce(v_frame->>'narration','') <> ''
                             THEN E'\nNarration: '||(v_frame->>'narration') ELSE '' END;
        INSERT INTO stewards.chat_attachments
            (session_id, kind, filename, mime_type, bytes, byte_size, caption, parent_id)
        VALUES (p_session_id, 'image', 'yt:'||p_video_id||':'||(v_frame->>'file'),
                'image/png', v_png, length(v_png), v_caption, v_parent)
        RETURNING id INTO v_id;
        v_ids := v_ids || v_id;
        v_n := v_n + 1;
    END LOOP;

    RETURN jsonb_build_object('ok', v_n > 0, 'video_id', p_video_id, 'frames', v_n,
        'parent_id', v_parent, 'attachment_ids', to_jsonb(v_ids),
        'note', CASE WHEN v_n > 0
                     THEN format('%s slide frames ingested as captioned vision attachments — page them in with slides_read', v_n)
                     ELSE 'no frame PNGs could be read (manifest present but files missing?)' END);
END;
$fn$;

COMMENT ON FUNCTION stewards.import_yt_frames(text, text) IS
'Overlay glue (needs the /yt mount): read a video''s frames.json + cues.json + PNGs from the bridge yt volume, align each frame to the transcript narration (align_slide_captions, 78), and insert one captioned image attachment per frame (parent = a video document). The digest''s vision model reads the slide + the words over it. Idempotent per (session, video). Server-side — no pixel re-emit.';

-- ── yt_persist_frames tool — the read-stage call that ingests the frames the
--    digester just extracted (sibling of yt_persist_transcript). _session_id is
--    injected by the bgworker; the frames attach to the digest session.
CREATE OR REPLACE FUNCTION stewards.yt_persist_frames_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_vid  text := coalesce(p_args->>'video_id', p_args->>'id', '');
    v_sess text := p_args->>'_session_id';
BEGIN
    IF v_vid !~ '^[A-Za-z0-9_-]{11}$' THEN
        RETURN jsonb_build_object('ok', false, 'note', 'video_id must be an 11-char YouTube id')::text;
    END IF;
    IF coalesce(v_sess,'') = '' THEN
        RETURN jsonb_build_object('ok', false, 'note', 'no session context')::text;
    END IF;
    RETURN stewards.import_yt_frames(v_vid, v_sess)::text;
END;
$fn$;

-- ── slides_read tool — page a BATCH of slides into the session as a vision turn.
--    Honors the rich-docs page-in discipline: load `count` frames at a time (not
--    all at once). Inserts a user message carrying the 47 content_parts (each
--    slide''s caption text + its image, via 78''s chat_attachment_parts), so the
--    NEXT turn of a VISION-capable digest stage SEES the slides and records what
--    each shows. Returns the loaded range + the next offset (or done).
CREATE OR REPLACE FUNCTION stewards.slides_read_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess  text := p_args->>'_session_id';
    v_vid   text := coalesce(p_args->>'video_id', p_args->>'id', '');
    v_from  int  := greatest(coalesce((p_args->>'from')::int, 0), 0);
    v_count int  := least(greatest(coalesce((p_args->>'count')::int, 4), 1), 8);
    v_ids   bigint[];
    v_total int;
    v_parts jsonb;
BEGIN
    IF coalesce(v_sess,'') = '' THEN RETURN jsonb_build_object('ok', false, 'note', 'no session context')::text; END IF;
    IF v_vid = '' THEN RETURN jsonb_build_object('ok', false, 'note', 'video_id required')::text; END IF;

    SELECT count(*) INTO v_total
      FROM stewards.chat_attachments
     WHERE session_id = v_sess AND kind = 'image' AND filename LIKE 'yt:'||v_vid||':%';
    IF v_total = 0 THEN
        RETURN jsonb_build_object('ok', false,
            'note', 'no ingested frames for this video — call yt_persist_frames first')::text;
    END IF;

    -- the next batch, ordered by frame timestamp (id order = ingest order = sec order)
    SELECT array_agg(id ORDER BY id) INTO v_ids FROM (
        SELECT id FROM stewards.chat_attachments
         WHERE session_id = v_sess AND kind = 'image' AND filename LIKE 'yt:'||v_vid||':%'
         ORDER BY id OFFSET v_from LIMIT v_count) s;

    IF v_ids IS NULL OR cardinality(v_ids) = 0 THEN
        RETURN jsonb_build_object('ok', true, 'done', true, 'total', v_total,
            'note', format('all %s slides have been paged in', v_total))::text;
    END IF;

    -- 78/47: caption text + image per slide, as a vision content turn in the session
    v_parts := stewards.chat_attachment_parts(v_ids, v_sess);
    INSERT INTO stewards.messages (session_id, role, content, content_parts)
    VALUES (v_sess, 'user',
            format('[slides %s..%s of %s loaded — look at each image; the caption above each is the transcript narration spoken over it]',
                   v_from, v_from + cardinality(v_ids) - 1, v_total),
            v_parts);

    RETURN jsonb_build_object('ok', true, 'loaded', cardinality(v_ids),
        'from', v_from, 'next', v_from + cardinality(v_ids), 'total', v_total,
        'done', (v_from + cardinality(v_ids)) >= v_total,
        'note', 'the slides are now in view — describe what each shows that the transcript missed (a diagram, a number, the SQL/code on the slide), then call slides_read again with from=next until done')::text;
END;
$fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'yt_persist_frames',
  'Ingest the slide frames you just extracted (yt_slides/yt_frames) into the database as captioned, vision-readable image attachments aligned to the transcript narration. Pass the 11-char video_id. Call in the read stage AFTER extracting frames. Server-side — you do NOT pass the images.',
  '{"type":"object","required":["video_id"],"properties":{"video_id":{"type":"string","description":"the 11-char YouTube video id"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"yt_persist_frames_tool"}'::jsonb ),
( 'slides_read',
  'Page a BATCH of slide frames into view so you can READ them (a vision-capable stage only). Loads `count` slides (default 4) starting at `from`; each slide''s caption is the transcript narration spoken over it. After it returns, the slides are in view: describe what each shows that the transcript missed (a diagram label, a benchmark number, the SQL/code on the slide), then call slides_read again with from=next until done=true. Never load all slides at once.',
  '{"type":"object","required":["video_id"],"properties":{"video_id":{"type":"string"},"from":{"type":"integer","description":"0-based index of the first slide in this batch (use the previous call''s next)"},"count":{"type":"integer","description":"how many slides to load (1-8, default 4)"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"slides_read_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','yt_persist_frames','allow','manual'),
    ('research','slides_read','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- End of yt-transcripts.sql
-- =====================================================================
