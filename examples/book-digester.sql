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
( 'book_add',
  'Queue a book on the reading shelf for a future digest. Provide title (required), author, and optionally a source_url hint.',
  '{"type":"object","required":["title"],"properties":{"title":{"type":"string"},"author":{"type":"string"},"url":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"book_add_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- Grant the book tools + fetch_url + web_search_exa to the research agent.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('stewards-explore','book_next','allow','manual'),
    ('stewards-explore','book_publish','allow','manual'),
    ('stewards-explore','book_add','allow','manual'),
    ('stewards-explore','fetch_url','allow','manual'),
    ('stewards-explore','web_search_exa','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET
    action = EXCLUDED.action, source = COALESCE(EXCLUDED.source, stewards.agent_tool_perms.source);

-- ── the book-digest pipeline ────────────────────────────────────────────────
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder,
    auto_materialize_on_verified
) VALUES (
    'book-digest',
    'Read a book the way we read scripture: read (find + fetch the text) -> digest -> critique(null-case) -> recommend, then book_publish saves a study doc + brain entry. Single-pass v1 (short books). Uses the research agent.',
    jsonb_build_array(
        jsonb_build_object('name','read','next','digest',
            'model','kimi-k2.6','provider','opencode_go','agent_family','stewards-explore',
            'auto_advance',true,'tools_disabled',false,
            'input_template',
              'You are the READ stage of the book digester.' || E'\n\n' ||
              '1. Call `book_next` to get your assigned book ({slug,title,author,source_url}). If it returns book:null, reply exactly "SHELF EMPTY" and stop.' || E'\n' ||
              '2. Get the FULL public-domain text. If source_url is given, `fetch_url` it. Otherwise `web_search_exa` for "<title> <author> full text Project Gutenberg" (or Standard Ebooks) and `fetch_url` the plain-text page.' || E'\n' ||
              '3. Output the full book text (or as much as you fetched), prefixed with a line: BOOK: <title> by <author>. The next stage digests it. Do NOT digest yourself.' ),
        jsonb_build_object('name','digest','next','critique',
            'model','kimi-k2.6','provider','opencode_go','agent_family','stewards-explore',
            'auto_advance',true,'tools_disabled',true,
            'input_template',
              'You are the DIGEST stage. Here is the book text from the read stage:' || E'\n\n' ||
              '{{stage_results.read.output}}' || E'\n\n' ||
              'Digest it the way a careful student studies a text — depth over breadth. Produce, in markdown:' || E'\n' ||
              '- **The core argument / thesis** (2-4 sentences).' || E'\n' ||
              '- **Structure** — how the book builds its case.' || E'\n' ||
              '- **Key passages** — 3-6 quoted verbatim, each with a one-line gloss.' || E'\n' ||
              '- **Themes** — the recurring ideas.' || E'\n\n' ||
              'Be faithful to the text. Quote only what is actually there.' ),
        jsonb_build_object('name','critique','next','recommend',
            'model','qwen3.7-plus','provider','opencode_go','agent_family','stewards-explore',
            'auto_advance',true,'tools_disabled',true,
            'input_template',
              'You are the CRITIQUE / null-case stage. The book text and the digest:' || E'\n\n' ||
              'TEXT (excerpt):' || E'\n' || '{{stage_results.read.output}}' || E'\n\n' ||
              'DIGEST:' || E'\n' || '{{stage_results.digest.output}}' || E'\n\n' ||
              'Pressure-test the digest: What did it flatten or miss? Is any claim unfaithful to the text? What is the STRONGEST objection to the book''s argument (the null case)? Return the digest, corrected where it was wrong, with a new "## Tensions & objections" section. Keep the good parts verbatim.' ),
        jsonb_build_object('name','recommend','next',NULL,
            'model','kimi-k2.6','provider','opencode_go','agent_family','stewards-explore',
            'auto_advance',true,'tools_disabled',false,
            'input_template',
              'You are the RECOMMEND stage — the final one. The refined digest:' || E'\n\n' ||
              '{{stage_results.critique.output}}' || E'\n\n' ||
              'Add a final section "## What''s worth learning — and what we could do with it": 3-6 concrete, actionable takeaways (not platitudes — things a person or this substrate could actually try). Then assemble the COMPLETE document (title, the digest, tensions, recommendations) and call `book_publish` with it as `body`. After publishing, output the document.' )
    ),
    false, false,
    NULL, NULL,
    '["raw","researched","planned","verified"]'::jsonb,
    false   -- book_publish does the persistence directly (no file auto-materialize)
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages, updated_at = now();

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('book-digest','read',     'kimi-k2.6',    'Find + fetch the text; tools on (book_next, web_search_exa, fetch_url).'),
    ('book-digest','digest',   'kimi-k2.6',    'Faithful study digest; tools off.'),
    ('book-digest','critique', 'qwen3.7-plus', 'Null-case the digest; NOT qwen3.7-max (cost). Tools off.'),
    ('book-digest','recommend','kimi-k2.6',    'Actionable takeaways + book_publish; tools on (book_publish).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity) VALUES
    ('book-digest','digest',   'researched'),
    ('book-digest','critique', 'planned'),
    ('book-digest','recommend','verified')
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
