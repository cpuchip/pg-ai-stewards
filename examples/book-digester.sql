-- examples/book-digester.sql — read a book the way we read scripture.
--
-- The #3 digester (see .spec/proposals/book-digester.md). Picks the next book
-- off a shelf, finds + fetches its public-domain text, and digests it in one
-- pass: read -> digest -> critique(null-case) -> recommend, then publishes a
-- study doc + a brain entry. v1 is single-pass (short books fit in context);
-- the map-reduce-over-a-long-book path is a v2.
--
-- Import after the model catalog (examples/models.sql) into a stack with a
-- provider configured:
--   docker compose exec -T pg psql -U stewards -d stewards < examples/book-digester.sql
--
-- Models: kimi-k2.6 (doer), qwen3.7-plus (critic). Uses the `research` agent
-- (which has the web tools); this file grants it the book_* tools + fetch_url.

-- ── reading shelf ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stewards.book_shelf (
    slug        text PRIMARY KEY CHECK (slug ~ '^[a-z0-9-]+$'),
    title       text NOT NULL,
    author      text,
    source_url  text,                       -- optional hint; null = let the agent find it
    position    int  NOT NULL DEFAULT 100,
    status      text NOT NULL DEFAULT 'queued'
                CHECK (status IN ('queued','reading','done','skipped')),
    started_at  timestamptz,
    done_at     timestamptz,
    added_by    text NOT NULL DEFAULT 'seed',
    added_at    timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.book_shelf IS
'book-digester reading queue. status flows queued -> reading -> done. The single reading row is the cross-stage cursor (book_next claims it, book_publish closes it).';

-- ── book_next(): claim the next book (resume the reading one, else next queued)
CREATE OR REPLACE FUNCTION stewards.book_next()
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE v_row stewards.book_shelf%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM stewards.book_shelf
     WHERE status = 'reading' ORDER BY position, added_at LIMIT 1;
    IF v_row.slug IS NULL THEN
        SELECT * INTO v_row FROM stewards.book_shelf
         WHERE status = 'queued' ORDER BY position, added_at LIMIT 1
           FOR UPDATE SKIP LOCKED;
        IF v_row.slug IS NULL THEN RETURN NULL; END IF;
        UPDATE stewards.book_shelf
           SET status = 'reading', started_at = COALESCE(started_at, now())
         WHERE slug = v_row.slug;
    END IF;
    RETURN jsonb_build_object('slug', v_row.slug, 'title', v_row.title,
                              'author', v_row.author, 'source_url', v_row.source_url);
END $func$;

CREATE OR REPLACE FUNCTION stewards.book_next_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $func$
    SELECT COALESCE(stewards.book_next()::text,
                    '{"book": null, "note": "the shelf is empty — nothing queued"}');
$func$;

-- ── book_publish(body): save the digest of the CURRENTLY-reading book ───────
CREATE OR REPLACE FUNCTION stewards.book_publish(p_body text)
RETURNS jsonb LANGUAGE plpgsql AS $func$
DECLARE v_row stewards.book_shelf%ROWTYPE; v_doc text;
BEGIN
    SELECT * INTO v_row FROM stewards.book_shelf
     WHERE status = 'reading' ORDER BY position, added_at LIMIT 1;
    IF v_row.slug IS NULL THEN
        RETURN '{"ok": false, "note": "no book is currently being read"}'::jsonb;
    END IF;
    IF p_body IS NULL OR length(trim(p_body)) < 100 THEN
        RETURN '{"ok": false, "note": "digest body too short to publish"}'::jsonb;
    END IF;
    v_doc := stewards.import_doc(
        'book-' || v_row.slug,
        'study/books/' || v_row.slug || '.md',
        'Digest: ' || v_row.title || COALESCE(' — ' || v_row.author, ''),
        p_body,
        jsonb_build_object('source_type','book-digest','book_slug',v_row.slug,
                           'book_title',v_row.title,'book_author',v_row.author),
        'doc');
    -- Queue the file write too, so the digest materializes to disk IF the
    -- operator has the materializer on (/workspace RW). With /workspace RO
    -- (the safe default) this row simply waits — the doc is always in the DB.
    INSERT INTO stewards.pending_file_writes
        (requested_by, target_path, write_mode, content, source_id, source_kind)
    VALUES ('book_publish', 'study/books/' || v_row.slug || '.md', 'create',
            p_body, v_doc, 'book-digest');
    PERFORM stewards.brain_upsert('ideas',
        'Book digest: ' || v_row.title,
        left(p_body, 4000),
        jsonb_build_object('book_slug', v_row.slug, 'doc_id', v_doc),
        ARRAY['book-digest', v_row.slug]);
    UPDATE stewards.book_shelf SET status = 'done', done_at = now() WHERE slug = v_row.slug;
    RETURN jsonb_build_object('ok', true, 'doc_id', v_doc, 'book', v_row.slug,
                              'path', 'study/books/' || v_row.slug || '.md');
END $func$;

CREATE OR REPLACE FUNCTION stewards.book_publish_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $func$
    SELECT stewards.book_publish(COALESCE(p_args->>'body', p_args->>'digest', p_args->>'document'))::text;
$func$;

-- ── book_publish_draft(): publish a doc-construction DRAFT (the doc-builder path).
--    The build/critique stages built the digest incrementally with doc_create/
--    doc_append/doc_patch; here we pull its body SERVER-SIDE by handle (the model
--    never re-emits the whole body as a tool arg — that is the one-shot generation
--    we are avoiding), run the same publish boundary as book_publish, project-tag
--    the pooled doc, then clear the draft. Mirrors playlist_publish_draft.
CREATE OR REPLACE FUNCTION stewards.book_publish_draft_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $func$
DECLARE
    v_sess     text := p_args ->> '_session_id';
    v_handle   text := lower(btrim(coalesce(p_args ->> 'handle', '')));
    v_body     text;
    v_proj     text;
    v_res      jsonb;
    v_bookslug text;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN '{"ok":false,"note":"no session context"}'; END IF;
    IF v_handle = '' THEN
        -- handle omitted — fall back to the active draft for this work item
        SELECT handle INTO v_handle FROM stewards.doc_drafts
         WHERE stewards.doc_draft_session_match(session_id, v_sess)
         ORDER BY updated_at DESC LIMIT 1;
        IF v_handle IS NULL THEN RETURN '{"ok":false,"note":"no draft for this work item — doc_create + doc_append_section first"}'; END IF;
    END IF;
    SELECT body, project INTO v_body, v_proj
      FROM stewards.doc_drafts
     WHERE handle = v_handle AND stewards.doc_draft_session_match(session_id, v_sess);
    IF v_body IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'note', 'no draft ' || v_handle || ' for this work item — doc_create + doc_append_section first')::text;
    END IF;
    -- reuse the exact publish boundary (currently-reading book, import_doc, file write, brain, shelf done)
    v_res := stewards.book_publish(v_body);
    IF (v_res->>'ok')::boolean THEN
        v_bookslug := v_res->>'book';
        -- project-tag the CANONICAL pooled doc (slug book-<slug>) so the real digest
        -- is findable in the project pool. on_maturity_verified no longer auto-pools
        -- the journal for this pipeline (metadata.pools_via_tool) — this is the one pool.
        -- Prefer the draft's explicit project; else fall back to the WORK ITEM's
        -- project (the book-study intent->project map). The draft only carries a
        -- project if the model passed one to doc_create; the work-item fallback makes
        -- the tag robust regardless (mirrors doc_finalize). Session = wi--<uuid8>--<stage>.
        v_proj := nullif(btrim(coalesce(v_proj, '')), '');
        IF v_proj IS NULL AND left(v_sess, 4) = 'wi--' THEN
            SELECT project_association INTO v_proj FROM stewards.work_items
             WHERE left(id::text, 8) = split_part(v_sess, '--', 2)
               AND project_association IS NOT NULL
             LIMIT 1;
        END IF;
        IF v_proj IS NOT NULL AND v_bookslug IS NOT NULL THEN
            UPDATE stewards.docs SET project_association = v_proj WHERE slug = 'book-' || v_bookslug;
        END IF;
        DELETE FROM stewards.doc_drafts WHERE handle = v_handle;
        v_res := v_res || jsonb_build_object('note', 'published from draft ' || v_handle || ' and cleared it. Your reply now is a short JOURNAL of what you did — do NOT paste the digest.');
    END IF;
    RETURN v_res::text;
END $func$;

-- ── book_add(url,title): queue a book ───────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.book_add(p_title text, p_author text DEFAULT NULL,
                                             p_url text DEFAULT NULL, p_position int DEFAULT 100)
RETURNS text LANGUAGE plpgsql AS $func$
DECLARE v_slug text;
BEGIN
    v_slug := trim(both '-' from lower(regexp_replace(p_title, '[^a-zA-Z0-9]+', '-', 'g')));
    IF v_slug = '' THEN v_slug := 'book-' || substr(md5(random()::text),1,8); END IF;
    INSERT INTO stewards.book_shelf (slug, title, author, source_url, position, added_by)
    VALUES (v_slug, p_title, p_author, p_url, p_position, 'tool')
    ON CONFLICT (slug) DO NOTHING;
    RETURN v_slug;
END $func$;

CREATE OR REPLACE FUNCTION stewards.book_add_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $func$
    SELECT jsonb_build_object('added_slug',
        stewards.book_add(p_args->>'title', p_args->>'author', p_args->>'url'))::text;
$func$;

-- ── tool defs (so agents can call them) ─────────────────────────────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'book_next',
  'Claim the next book to digest from the reading shelf. Returns {slug, title, author, source_url} for the book you should read now (resumes an in-progress one, else the next queued), or {book: null} if the shelf is empty. Call this FIRST.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"book_next_tool"}'::jsonb ),
( 'book_publish',
  'Save the finished digest of the book you are currently reading. Pass the COMPLETE digest document as `body`. Writes a study doc at study/books/<slug>.md + a brain entry and marks the book done. Call this LAST, once.',
  '{"type":"object","required":["body"],"properties":{"body":{"type":"string","minLength":100,"description":"The complete digest document (markdown)."}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"book_publish_tool"}'::jsonb ),
( 'book_publish_draft',
  'Publish the book digest you BUILT with the doc tools (doc_create/doc_append_section/doc_patch). Pass the draft `handle` (or omit it to use this run''s active draft) — NOT the body (the body is pulled from your draft server-side, so you never re-emit the whole document). Marks the currently-reading book done. Call this LAST, once, after the draft is complete.',
  '{"type":"object","properties":{"handle":{"type":"string","description":"the draft handle from doc_create (optional; defaults to this run''s active draft)"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"book_publish_draft_tool"}'::jsonb ),
( 'book_add',
  'Queue a book on the reading shelf for a future digest. Provide title (required), author, and optionally a source_url hint.',
  '{"type":"object","required":["title"],"properties":{"title":{"type":"string"},"author":{"type":"string"},"url":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"book_add_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- Grant the book tools + fetch_url + web_search_exa to the research agent.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','book_next','allow','manual'),
    ('research','book_publish','allow','manual'),
    ('research','book_publish_draft','allow','manual'),
    ('research','book_add','allow','manual'),
    ('research','fetch_url','allow','manual'),
    ('research','web_search_exa','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET
    action = EXCLUDED.action, source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- ── the book-digest pipeline (doc-construction recast) ──────────────────────
-- read (find the text, emit a reference — no echo) -> build (page the text in,
-- BUILD the digest as a DOCUMENT via doc_* tool-call diffs) -> critique (a
-- second pass: doc_read + doc_patch the null-case in, then book_publish_draft).
-- The model never one-shots the digest; its reply each stage is a journal. This
-- fixes the local reaper/contention/grammar failures (agentic-doc-construction.md).
-- Stages name ROLES (ingest/reason/critic); the alias router picks the best
-- available member (local-first via the workspace overlay). Uses the research agent.
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder,
    auto_materialize_on_verified, metadata
) VALUES (
    'book-digest',
    'Read a book the way we read scripture, building the digest as a document: read (find the text, emit a reference, no echo) -> build (page the text in, construct the digest via doc_* tool-call diffs) -> critique (second pass: doc_patch the null-case in, then book_publish_draft). Doc-construction recast (agentic-doc-construction.md). Uses the research agent.',
    jsonb_build_array(
        -- READ: find the book + a fetchable full-text URL, emit ONLY a header.
        -- Does NOT fetch/echo the book (a whole-book re-emit is itself a one-shot
        -- generation that trips the reaper on a local model). The build stage
        -- fetches the text via fetch_url (large content pages in automatically).
        jsonb_build_object('name','read','next','build',
            'model','ingest','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            'input_template',
              'You are the READ stage of the book digester.' || E'\n\n' ||
              '1. Call `book_next` to get your assigned book ({slug,title,author,source_url}). If it returns book:null, reply EXACTLY "SHELF EMPTY" and stop.' || E'\n' ||
              '2. Determine a fetchable FULL-TEXT URL. If source_url is given, use it. Otherwise `web_search_exa` for "<title> <author> full text Project Gutenberg" (or Standard Ebooks / archive.org) and pick the plain-text page URL. Do NOT fetch the book here — just find the URL.' || E'\n' ||
              '3. Output EXACTLY these four lines and NOTHING ELSE (no book text — the build stage fetches it):' || E'\n' ||
              '   BOOK_SLUG: <the slug>' || E'\n' ||
              '   TITLE: <the title>' || E'\n' ||
              '   AUTHOR: <the author>' || E'\n' ||
              '   SOURCE_URL: <the full-text url>' ),
        -- BUILD: construct the digest as a DOCUMENT via doc_* tool-call diffs.
        -- Never emits the whole digest as one generation — builds it section by
        -- section; its chat reply is a short journal. Does NOT publish (critique does).
        jsonb_build_object('name','build','next','critique',
            'model','reason','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            'input_template',
              'You are the BUILD stage. BUILD the digest as a document using your doc tools — do NOT write the digest as your reply.' || E'\n\n' ||
              'The read stage gave you this header:' || E'\n\n' ||
              '{{stage_results.read.output}}' || E'\n\n' ||
              'Steps:' || E'\n' ||
              '1. Read TITLE, AUTHOR, and SOURCE_URL from the header above.' || E'\n' ||
              '2. Call `fetch_url` with the SOURCE_URL to get the book text. If it is large you will see a [page-in] banner with a handle — use `result_read`(handle, offset, limit) to read it in chunks; do not pull it all at once.' || E'\n' ||
              '3. Call `doc_create` with title = "Digest: <TITLE> — <AUTHOR>" and project "books".' || E'\n' ||
              '4. Build the digest with `doc_append_section` (one call each, keep each small, depth over breadth, faithful to the text, quote only what is actually there):' || E'\n' ||
              '   - "The core argument" — the thesis in 2-4 sentences.' || E'\n' ||
              '   - "Structure" — how the book builds its case.' || E'\n' ||
              '   - "Key passages" — 3-6 verbatim quotes, each with a one-line gloss.' || E'\n' ||
              '   - "Themes" — the recurring ideas.' || E'\n' ||
              '   - "What''s worth learning" — 3-6 concrete, actionable takeaways (not platitudes — things a person or this substrate could actually try).' || E'\n' ||
              '5. Call `doc_read` to review the whole draft; fix anything weak or unfaithful with `doc_patch`. Do NOT publish — the critique stage does that.' || E'\n' ||
              '6. Reply with a short JOURNAL (2-4 sentences): the book, what you built, and the draft handle. Do NOT paste the document.' ),
        -- CRITIQUE: a second pass (the D&C 88:122 review). Picks up the draft via
        -- doc_current (work-item-scoped), pressure-tests it, patches the null-case
        -- in, then publishes. Tools on (doc_*, book_publish_draft).
        jsonb_build_object('name','critique','next',NULL,
            'model','critic','agent_family','research',
            'auto_advance',true,'tools_disabled',false,
            -- 37: scope this PUBLISHING stage to doc-edit + the ONE book finalize tool.
            -- Excludes the generic doc_finalize so the model can't pool a stray
            -- digest-<slug> doc that skips the book-done boundary (→ re-digest dup).
            'tool_groups', jsonb_build_array('doc-edit','book-finalize'),
            'input_template',
              'You are the CRITIQUE stage — the final review before publish. The build stage built a digest draft for this run.' || E'\n\n' ||
              'Work ONLY from the draft. Your tools are doc_current, doc_read, doc_patch, doc_append_section, and book_publish_draft. Do NOT fetch_url or web_search — the build stage already read the source; re-researching wastes a slow round and risks not finishing. Judge faithfulness from the draft''s own quotes and internal consistency.' || E'\n\n' ||
              'Steps (be efficient — converge to publish):' || E'\n' ||
              '1. Call `doc_current` to get the draft handle, then `doc_read` it once.' || E'\n' ||
              '2. Pressure-test it: What did it flatten or miss? Is any claim internally inconsistent or unsupported by its own quotes? Fix the weak parts with `doc_patch` (find the exact text, replace it). A few targeted patches, not a rewrite.' || E'\n' ||
              '3. Add the null case: `doc_append_section` a "Tensions & objections" section with the STRONGEST objection to the book''s argument. Be honest, not agreeable.' || E'\n' ||
              '4. Call `book_publish_draft` with the handle. This saves the digest as a study doc + brain entry and marks the book done.' || E'\n' ||
              '5. Reply with a short JOURNAL (2-4 sentences): what you corrected, the objection you added, and that you published. Do NOT paste the document.' )
    ),
    false, false,
    NULL, NULL,
    '["raw","verified"]'::jsonb,
    false,  -- book_publish_draft persists directly (no file auto-materialize)
    -- doc-construction: book_publish_draft pools the canonical doc; the critique
    -- stage's final output is a journal, so DON'T auto-pool it (pools_via_tool).
    jsonb_build_object('pools_via_tool', true)
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    maturity_ladder = EXCLUDED.maturity_ladder, metadata = stewards.pipelines.metadata || EXCLUDED.metadata,
    updated_at = now();

-- recast read/build/critique (drop the old digest/recommend rows — orphaned by the recast)
DELETE FROM stewards.stage_models
 WHERE pipeline_family='book-digest' AND stage_name IN ('digest','recommend');
INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('book-digest','read',     'ingest', 'Find the text + a full-text URL, emit header only; tools on (book_next, web_search_exa). Local ingest alias (gemma).'),
    ('book-digest','build',    'reason', 'Build the digest as a doc via doc_* tool-call diffs (no publish); tools on. Local reason alias (qwen).'),
    ('book-digest','critique', 'critic', 'Second pass: doc_patch the null-case in + book_publish_draft; tools on. Local critic alias (qwen).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

DELETE FROM stewards.pipeline_stage_maturity
 WHERE pipeline_family='book-digest' AND stage_name IN ('digest','recommend');
INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity) VALUES
    ('book-digest','critique','verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

-- ── the book-study intent (the core ships no intents; seed our own) ─────────
INSERT INTO stewards.intents (slug, purpose, beneficiary, values_hierarchy, values_anchor)
VALUES (
    'book-study',
    'Read freely-available books with depth and rigor; extract what is worth learning and what we could do with it.',
    'the operator and the substrate''s own growth',
    jsonb_build_array(
        jsonb_build_object('key','faithful-to-the-text','description','Understand before judging; quote before summarizing. The digest must be true to what the book actually says.'),
        jsonb_build_object('key','depth-over-breadth','description','A few ideas understood deeply beat a list of topics skimmed.'),
        jsonb_build_object('key','name-the-null-case','description','State the strongest objection to the book''s argument. Intellectual honesty over agreement.'),
        jsonb_build_object('key','actionable-learning','description','End with what a person or this substrate could actually try, not platitudes.')
    ),
    'Read the way a careful student reads: understand before you judge, quote before you summarize, and name what you would do differently.'
)
ON CONFLICT (slug) DO NOTHING;

-- ── hourly schedule ─────────────────────────────────────────────────────────
INSERT INTO stewards.scheduled_pipelines (slug, pipeline_family, intent_id, cron_pattern, input_template, enabled, missed_window_hours, notes)
VALUES (
    'book-digest-hourly', 'book-digest',
    (SELECT id FROM stewards.intents WHERE slug = 'book-study' LIMIT 1),
    '0 * * * *',
    '{"assignment": "Read and digest the next book on the shelf. Call book_next to get your assignment."}'::jsonb,
    true, 2,
    'book-digester: one book per hourly tick (book_next claims the next; book_publish closes it).'
)
ON CONFLICT (slug) DO UPDATE SET
    pipeline_family = EXCLUDED.pipeline_family, cron_pattern = EXCLUDED.cron_pattern,
    input_template = EXCLUDED.input_template, enabled = EXCLUDED.enabled, updated_at = now();

-- ── starter shelf (operator content — edit freely) ──────────────────────────
INSERT INTO stewards.book_shelf (slug, title, author, source_url, position) VALUES
    ('self-reliance',  'Self-Reliance',  'Ralph Waldo Emerson', NULL, 10),
    ('meditations',    'Meditations',    'Marcus Aurelius',     NULL, 20),
    ('tao-te-ching',   'Tao Te Ching',   'Laozi',               NULL, 30),
    ('the-art-of-war', 'The Art of War', 'Sun Tzu',             NULL, 40)
ON CONFLICT (slug) DO NOTHING;

-- ── empty-shelf halt (generic: core work_item_advance honors metadata.halt_on) ──
-- The read stage replies "SHELF EMPTY" when book_next returns null. Declaring
-- halt_on makes core work_item_advance cancel the run AT the read stage and not
-- advance — so digest/critique/recommend never dispatch and nothing is pooled.
-- Re-queue a book (book_add) and the next scheduled run proceeds normally.
-- (Replaces the old per-pipeline BEFORE-UPDATE guard, which raced the dispatcher:
-- it set status=cancelled but work_item_advance still returned the next stage name,
-- and the bgworker dispatched off the return value. See digester-empty-source-halt.)
UPDATE stewards.pipelines
   SET metadata = COALESCE(metadata, '{}'::jsonb)
                || jsonb_build_object('halt_on',
                       jsonb_build_object('stage','read','outputs', jsonb_build_array('SHELF EMPTY'))),
       updated_at = now()
 WHERE family = 'book-digest';
DROP TRIGGER IF EXISTS work_items_book_digest_skip_empty ON stewards.work_items;
DROP FUNCTION IF EXISTS stewards.book_digest_skip_empty_shelf();

-- =====================================================================
-- THE CURATOR — a presiding steward over the book line (digester-steward.md, P0).
-- Ratified 2026-06-16 (council): keep the shelf fed with verified, non-duplicate
-- books that further book-study; on a dry shelf, brainstorm new directions. Feed
-- ONLY when the queue is low (don't over-fill); enabled by default (capped by the
-- watchman guard + the operator's provider spend cap). This is the back-office
-- steward leg the reflect-steward gives any intent (22-reflect-steward.sql),
-- brought here to the book-study line.
-- =====================================================================

-- runway + dedup surface for the curator (queued/reading/done counts + titles).
CREATE OR REPLACE FUNCTION stewards.book_shelf_status()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'queued',  (SELECT count(*) FROM stewards.book_shelf WHERE status='queued'),
        'reading', (SELECT count(*) FROM stewards.book_shelf WHERE status='reading'),
        'done',    (SELECT count(*) FROM stewards.book_shelf WHERE status='done'),
        'queued_titles', COALESCE((SELECT jsonb_agg(title ORDER BY position)
                                     FROM stewards.book_shelf WHERE status IN ('queued','reading')), '[]'::jsonb),
        'done_titles',   COALESCE((SELECT jsonb_agg(title) FROM (
                                     SELECT title FROM stewards.book_shelf WHERE status='done'
                                      ORDER BY done_at DESC NULLS LAST LIMIT 50) d), '[]'::jsonb));
$$;
CREATE OR REPLACE FUNCTION stewards.book_shelf_status_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $$ SELECT stewards.book_shelf_status(); $$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'book_shelf_status',
  'The reading shelf at a glance: how many books are queued/reading/done, plus the queued and recently-done titles. Call this FIRST when curating, to see the runway and what NOT to re-add.',
  '{"type":"object","additionalProperties":false,"properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"book_shelf_status_tool"}'::jsonb,
  true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- tunable dials (the prompt hardcodes the same defaults; config documents/overrides)
SELECT stewards.config_set('book_curate_runway_threshold', '3'::jsonb,
    'The curator tops up the shelf only when queued books are BELOW this (don''t over-fill).');
SELECT stewards.config_set('book_curate_max_adds', '5'::jsonb,
    'Max books the curator adds in one run.');

-- the curator can read the shelf + brainstorm (research already has book_add, web,
-- intent_work_survey, fetch). Grant the two it lacks.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','book_shelf_status','allow','manual'),
    ('research','start_brainstorm', 'allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action='allow';

-- the curate pipeline (one tools-on stage; reuses the research agent).
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder,
    auto_materialize_on_verified, metadata)
VALUES (
    'book-curate',
    'Presiding curator for the book line: keep the shelf fed with verified, non-duplicate books that further book-study; brainstorm new directions when it runs dry. Feeds only when the queue is low. Single tools-on stage (research agent).',
    jsonb_build_array(jsonb_build_object(
        'name','curate','next',NULL,'model','reason',
        'agent_family','research','auto_advance',true,'tools_disabled',false,'max_tokens',6000,
        'input_template',
          'You are the BOOK-STUDY CURATOR. Keep the reading shelf fed with books worth digesting, and never let it sit empty. Today: {{input.today}}.' || E'\n\n' ||
          'STEP 1 — RUNWAY. Call book_shelf_status. If `queued` >= 3, reply EXACTLY "SHELF STOCKED" and stop — do not over-fill.' || E'\n\n' ||
          'STEP 2 — SURVEY (avoid repeats). Call intent_work_survey. Combine with book_shelf_status''s queued_titles + done_titles. NEVER propose a book already queued, reading, or done.' || E'\n\n' ||
          'STEP 3 — PICK + VERIFY, then add (up to 3 minus the current queued count). Choose books that further book-study — wisdom, philosophy, science, craft; depth over breadth; classics with freely-available full text. For EACH candidate you MUST verify a real, fetchable full-text source exists: call web_search_exa (and fetch_url if needed) to confirm a working URL on Project Gutenberg / archive.org / similar. ONLY when you have a verified URL, call book_add(title, author, url). Never add a book whose source you could not verify — a phantom wastes a digest run.' || E'\n\n' ||
          'STEP 4 — DRY SHELF. If you cannot name good concrete next books, call start_brainstorm on the book-study intent to discover new directions, then turn the strongest idea into a verified pick (step 3).' || E'\n\n' ||
          'Report the books you added (each: title — source url), or "SHELF STOCKED".' )),
    false, false, NULL, NULL,
    '["raw","verified"]'::jsonb, false,
    jsonb_build_object('shape','curator','line','book-study')
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages, metadata = EXCLUDED.metadata, updated_at = now();

-- the curator schedule (enabled by default — capped by the guard + opencode-go).
INSERT INTO stewards.scheduled_pipelines (slug, pipeline_family, intent_id, cron_pattern, input_template, enabled, missed_window_hours, notes)
VALUES (
    'book-curate-cron', 'book-curate',
    (SELECT id FROM stewards.intents WHERE slug='book-study' LIMIT 1),
    -- every 2h: book-digest consumes ~1 book/hour, so a 6h curator (adds up to 3)
    -- loses the race and the shelf drains; 2h keeps it fed (a STOCKED run is a
    -- single cheap call that adds nothing, so over-frequency costs ~nothing).
    '0 */2 * * *',
    '{"assignment":"Curate the book shelf: top it up with verified, non-duplicate books that further book-study; brainstorm new directions if it is running dry."}'::jsonb,
    true, 6,
    'book-curate: presiding steward; tops up the shelf only when queued < threshold; brainstorms on a dry shelf.'
)
ON CONFLICT (slug) DO UPDATE SET
    pipeline_family = EXCLUDED.pipeline_family, cron_pattern = EXCLUDED.cron_pattern,
    input_template = EXCLUDED.input_template, enabled = EXCLUDED.enabled, updated_at = now();
