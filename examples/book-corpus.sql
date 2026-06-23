-- =====================================================================
-- book-corpus.sql — persist a digested book's SOURCE TEXT into the DB.
-- =====================================================================
-- The book digester (examples/book-digester.sql) fetches a book's full text
-- with fetch_url at BUILD time. Today that text lives only in that run's
-- messages and is discarded once the digest publishes — so a book-study chat
-- (Stewdio's "chat with a work item") can ground on the doc + the building
-- sessions + citations, but NOT on the book's own passages. YouTube already
-- persists its source (examples/yt-transcripts.sql, keyed by video_id); this
-- gives books the same corpus facet, keyed by book_slug.
--
-- Two pieces, mirroring the YT pattern:
--   * book_text   — one row per book: the full source text + FTS (body_tsv),
--                   for verbatim "where does the book say this?" lookups.
--   * book_chunks — passage-level chunks: FTS-ranked retrieval that returns a
--                   LOCATION (chunk_idx) + an embedding column (mirror of docs)
--                   for future semantic recall. Embedding is OPT-IN (see below).
--
-- The digester never re-emits the (large, paged-in) book as a tool arg: it
-- passes the fetch HANDLE and book_persist_corpus reads the full content
-- server-side — exactly how yt_persist_transcript reads the bridge file and
-- how book_publish_draft pulls the draft body by handle.
--
-- Apply after core + the book digester:
--   docker compose exec -T pg psql -U stewards -d stewards < examples/book-corpus.sql
-- =====================================================================

-- Embedding the chunks is opt-in. The substrate has no synchronous query-embed
-- at tool-call time (doc_search is FTS; doc_similar uses PRECOMPUTED cosine
-- edges), so the live retrieval path is FTS — embeddings are forward-looking
-- infrastructure for a future precomputed-similarity feature. Enabling this on
-- a deployment WITHOUT a local embedder (lm_studio) just records embedding_error
-- per chunk (non-fatal). A work instance with a local nomic embedder flips it on
-- (it's $0 + private there). Default OFF so a vanilla deploy never fires a burst
-- of embed jobs it can't serve.
SELECT stewards.config_set('book_corpus_embed_chunks', 'false'::jsonb,
  'book-corpus: when ''true'', each persisted book_chunk enqueues an embed job (provider lm_studio, model from embed_model). Forward-looking — no live query path embeds today. Default ''false''.');

-- ── book_text — one row per book, the full source text (mirror yt_transcripts) ──
CREATE TABLE IF NOT EXISTS stewards.book_text (
    book_slug    text PRIMARY KEY,
    title        text,
    author       text,
    source_url   text,
    full_text    text,
    metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
    imported_at  timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    body_tsv     tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(full_text, ''))) STORED
);
COMMENT ON TABLE stewards.book_text IS
'One row per digested book — full source text + metadata, FTS via body_tsv. Populated by book_persist_corpus from the BUILD stage''s fetch. A book-study chat verifies "where does the book say this?" against full_text/body_tsv.';

CREATE INDEX IF NOT EXISTS book_text_body_tsv_idx ON stewards.book_text USING gin (body_tsv);

-- ── book_chunks — passage-level chunks (mirror docs: FTS + an embedding column) ──
CREATE TABLE IF NOT EXISTS stewards.book_chunks (
    id              text PRIMARY KEY,        -- book_slug || ':' || chunk_idx
    book_slug       text NOT NULL,
    chunk_idx       int  NOT NULL,
    text            text,
    embedding       vector(768),
    embedded_at     timestamptz,
    embedded_model  text,
    embedding_error text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    body_tsv        tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(text, ''))) STORED,
    UNIQUE (book_slug, chunk_idx)
);
COMMENT ON TABLE stewards.book_chunks IS
'Passage-level chunks of a book (mirror of stewards.docs: FTS body_tsv + an embedding column). FTS gives ranked passage retrieval with a location (chunk_idx); the embedding column is forward-looking (opt-in via config book_corpus_embed_chunks).';

CREATE INDEX IF NOT EXISTS book_chunks_body_tsv_idx ON stewards.book_chunks USING gin (body_tsv);
CREATE INDEX IF NOT EXISTS book_chunks_slug_idx     ON stewards.book_chunks (book_slug);
CREATE INDEX IF NOT EXISTS book_chunks_embedding_idx ON stewards.book_chunks USING hnsw (embedding vector_cosine_ops);

-- ── embed-enqueue trigger (mirror docs.enqueue_doc_embed; the bgworker is generic
--    over target_table, and the es2 trigger fills model/dimensions). Gated by config.
CREATE OR REPLACE FUNCTION stewards.enqueue_book_chunk_embed() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    IF coalesce(NEW.text, '') = '' THEN RETURN NEW; END IF;
    IF stewards.config_get_text('book_corpus_embed_chunks', 'false') <> 'true' THEN
        RETURN NEW;
    END IF;
    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('embed', 'lm_studio', jsonb_build_object(
        'target_table', 'book_chunks',
        'target_id',    NEW.id,
        'text',         NEW.text));   -- es2 trigger_embed_provider_route fills model + dimensions
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS book_chunks_enqueue_embed ON stewards.book_chunks;
CREATE TRIGGER book_chunks_enqueue_embed
    AFTER INSERT OR UPDATE OF text ON stewards.book_chunks
    FOR EACH ROW EXECUTE FUNCTION stewards.enqueue_book_chunk_embed();

-- ── book_persist_corpus — upsert the full text + (re)build the chunks. Idempotent.
--    Chunks on blank-line paragraph boundaries, accumulating to ~p_chunk_chars, with
--    a hard split for any single over-long paragraph. Returns the chunk count.
CREATE OR REPLACE FUNCTION stewards.book_persist_corpus(
    p_book_slug   text,
    p_title       text,
    p_author      text,
    p_source_url  text,
    p_full_text   text,
    p_chunk_chars int DEFAULT 1500
) RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE
    v_para  text;
    v_buf   text := '';
    v_idx   int  := 0;
    v_count int  := 0;
    v_cap   int  := greatest(coalesce(p_chunk_chars, 1500), 200);
BEGIN
    IF p_book_slug IS NULL OR btrim(p_book_slug) = '' THEN
        RAISE EXCEPTION 'book_persist_corpus: book_slug required';
    END IF;

    INSERT INTO stewards.book_text (book_slug, title, author, source_url, full_text, updated_at)
    VALUES (p_book_slug, p_title, p_author, p_source_url, coalesce(p_full_text, ''), now())
    ON CONFLICT (book_slug) DO UPDATE SET
        title      = EXCLUDED.title,
        author     = EXCLUDED.author,
        source_url = EXCLUDED.source_url,
        full_text  = EXCLUDED.full_text,
        updated_at = now();

    -- rebuild chunks idempotently
    DELETE FROM stewards.book_chunks WHERE book_slug = p_book_slug;

    FOR v_para IN
        SELECT btrim(p) FROM regexp_split_to_table(coalesce(p_full_text, ''), E'\n[ \t]*\n') AS p
    LOOP
        CONTINUE WHEN v_para = '';
        -- flush the buffer if adding this paragraph would overflow the cap
        IF length(v_buf) > 0 AND length(v_buf) + length(v_para) + 2 > v_cap THEN
            INSERT INTO stewards.book_chunks (id, book_slug, chunk_idx, text)
            VALUES (p_book_slug || ':' || v_idx, p_book_slug, v_idx, v_buf);
            v_idx := v_idx + 1; v_count := v_count + 1; v_buf := '';
        END IF;
        v_buf := CASE WHEN v_buf = '' THEN v_para ELSE v_buf || E'\n\n' || v_para END;
        -- a single paragraph longer than ~2× the cap: hard-split it
        WHILE length(v_buf) > v_cap * 2 LOOP
            INSERT INTO stewards.book_chunks (id, book_slug, chunk_idx, text)
            VALUES (p_book_slug || ':' || v_idx, p_book_slug, v_idx, left(v_buf, v_cap));
            v_idx := v_idx + 1; v_count := v_count + 1;
            v_buf := substr(v_buf, v_cap + 1);
        END LOOP;
    END LOOP;
    IF length(btrim(v_buf)) > 0 THEN
        INSERT INTO stewards.book_chunks (id, book_slug, chunk_idx, text)
        VALUES (p_book_slug || ':' || v_idx, p_book_slug, v_idx, v_buf);
        v_count := v_count + 1;
    END IF;

    RAISE NOTICE 'book_persist_corpus: % stored (chars=%, chunks=%)',
        p_book_slug, length(coalesce(p_full_text, '')), v_count;
    RETURN v_count;
END;
$fn$;

-- ── book_persist_corpus tool — called from the BUILD stage after fetch_url. The
--    model passes the page-in HANDLE (not the text); the function reads the full
--    fetched content server-side from messages, scoped to its own session + the
--    non-private watch (same resolver as result_read). A `full_text` arg is also
--    accepted for manual/backfill use. book_slug is guarded to a safe slug shape.
CREATE OR REPLACE FUNCTION stewards.book_persist_corpus_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_slug   text := coalesce(p_args ->> 'book_slug', p_args ->> 'slug', '');
    v_title  text := p_args ->> 'title';
    v_author text := p_args ->> 'author';
    v_url    text := coalesce(p_args ->> 'source_url', p_args ->> 'url');
    v_handle text := lower((regexp_match(coalesce(p_args ->> 'handle', ''), '([0-9a-fA-F]{3,8})'))[1]);
    v_chunk  int  := coalesce((p_args ->> 'chunk_chars')::int, 1500);
    v_text   text := p_args ->> 'full_text';
    v_count  int;
BEGIN
    IF v_slug !~ '^[A-Za-z0-9_-]{1,100}$' THEN
        RETURN jsonb_build_object('ok', false,
            'note', 'book_slug required (letters, digits, _ or - only)')::text;
    END IF;

    -- prefer the handle: read the full fetched text from messages (server-side)
    IF v_text IS NULL AND v_handle IS NOT NULL THEN
        IF v_sess IS NULL OR v_sess = '' THEN
            RETURN jsonb_build_object('ok', false, 'note', 'no session context to resolve the handle')::text;
        END IF;
        SELECT m.content INTO v_text
          FROM stewards.messages m
         WHERE stewards.context_handle(m.id) = v_handle
           AND m.session_id IN (SELECT v_sess
                                UNION
                                SELECT session_id FROM stewards.context_descendant_sessions(v_sess))
         LIMIT 1;
        IF v_text IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'note', 'no readable message for handle ' || v_handle || ' in your context')::text;
        END IF;
    END IF;

    IF v_text IS NULL OR length(btrim(v_text)) < 200 THEN
        RETURN jsonb_build_object('ok', false,
            'note', 'pass the fetch handle (the [page-in] banner id) or a full_text of the book to persist')::text;
    END IF;

    v_count := stewards.book_persist_corpus(v_slug, v_title, v_author, v_url, v_text, v_chunk);
    RETURN jsonb_build_object('ok', true, 'book_slug', v_slug, 'chunks', v_count,
        'chars', length(v_text),
        'note', 'book corpus stored — passages are now quotable via book_search')::text;
END;
$fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'book_persist_corpus',
  'Save the SOURCE TEXT of the book you just fetched so its passages can be quoted later. Call this in the build stage right after fetch_url, passing the [page-in] banner handle (NOT the text — it is read server-side), plus book_slug, title, author, and source_url. Server-side: you never re-emit the book.',
  '{"type":"object","required":["book_slug"],"properties":{'
    '"book_slug":{"type":"string","description":"the book slug (from the read-stage header)"},'
    '"title":{"type":"string"},"author":{"type":"string"},'
    '"source_url":{"type":"string","description":"the full-text URL you fetched"},'
    '"handle":{"type":"string","description":"the [page-in] banner handle from the fetch_url result"},'
    '"full_text":{"type":"string","description":"alternative to handle: the raw book text directly (manual/backfill)"},'
    '"chunk_chars":{"type":"integer","description":"target chunk size in chars (default 1500)"}'
  '}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"book_persist_corpus_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- ── book_search — the corpus facet for the chat (and the digest self-check). Returns
--    whether the phrase is a verbatim substring of the book (whitespace-normalized) +
--    the best-matching PASSAGES (FTS-ranked chunks) with their location (chunk_idx).
CREATE OR REPLACE FUNCTION stewards.book_search_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_slug  text := coalesce(p_args ->> 'book_slug', p_args ->> 'slug', '');
    v_q     text := coalesce(p_args ->> 'query', p_args ->> 'quote', '');
    v_lim   int  := least(greatest(coalesce((p_args ->> 'limit')::int, 5), 1), 15);
    v_eff   text;
    v_full  text;
    v_found boolean;
    v_vsnip text;
    v_pass  jsonb;
BEGIN
    IF v_slug = '' OR v_q = '' THEN
        RETURN jsonb_build_object('error', 'book_slug and query required')::text;
    END IF;
    -- accept either the book_slug ('on-liberty') or the doc slug ('book-on-liberty');
    -- prefer an exact match, else fall back to the 'book-' prefix stripped.
    SELECT book_slug, full_text INTO v_eff, v_full
      FROM stewards.book_text
     WHERE book_slug = v_slug OR book_slug = regexp_replace(v_slug, '^book-', '')
     ORDER BY (book_slug = v_slug) DESC LIMIT 1;
    IF v_full IS NULL THEN
        RETURN jsonb_build_object('found', false, 'passages', '[]'::jsonb,
            'note', 'no source corpus stored for this book — it predates corpus persistence (re-digest it) or call book_persist_corpus')::text;
    END IF;

    v_found := position(lower(regexp_replace(v_q, '\s+', ' ', 'g'))
                        in lower(regexp_replace(v_full, '\s+', ' ', 'g'))) > 0;
    v_vsnip := ts_headline('english', v_full, plainto_tsquery('english', v_q),
                           'MaxFragments=2,MinWords=5,MaxWords=20,StartSel=[[,StopSel=]]');

    -- best-matching passages (FTS over the chunks) — each carries its location
    SELECT jsonb_agg(jsonb_build_object(
               'location', 'chunk ' || c.chunk_idx,
               'chunk_idx', c.chunk_idx,
               'rank', round(ts_rank(c.body_tsv, q)::numeric, 4),
               'snippet', ts_headline('english', c.text, q,
                          'MaxFragments=1,MinWords=8,MaxWords=35,StartSel=[[,StopSel=]]'))
           ORDER BY ts_rank(c.body_tsv, q) DESC)
      INTO v_pass
      FROM stewards.book_chunks c, websearch_to_tsquery('english', v_q) q
     WHERE c.book_slug = v_eff AND c.body_tsv @@ q
     LIMIT greatest(v_lim, 1);

    RETURN jsonb_build_object(
        'found_verbatim', v_found,
        'verbatim_snippet', left(coalesce(v_vsnip, ''), 600),
        'passages', coalesce(v_pass, '[]'::jsonb),
        'note', CASE WHEN v_found
                     THEN 'verbatim match — you may quote this exactly'
                     ELSE 'not a verbatim substring; the passages above are the closest the book gets — paraphrase, do not put quotation marks around words the book did not use' END)::text;
END;
$fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'book_search',
  'Search a digested book''s SOURCE TEXT — to quote its actual passages or check a quote is verbatim. Pass book_slug + query. Returns {found_verbatim, verbatim_snippet, passages:[{location, snippet, rank}]}. Use this when discussing a book study so every claim about what the book says is grounded in the real text.',
  '{"type":"object","required":["book_slug","query"],"properties":{'
    '"book_slug":{"type":"string"},"query":{"type":"string"},'
    '"limit":{"type":"integer","description":"max passages (default 5, max 15)"}'
  '}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"book_search_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- ── grants. research (the digester) persists + verifies; work-item-chat (the
--    Stewdio chat agent, core extension/45) reads the corpus to quote passages.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research',        'book_persist_corpus', 'allow', 'manual'),
    ('research',        'book_search',         'allow', 'manual'),
    ('work-item-chat',  'book_search',         'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- End of book-corpus.sql
-- =====================================================================
