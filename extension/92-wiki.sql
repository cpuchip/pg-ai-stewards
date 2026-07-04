-- =====================================================================
-- 92-wiki.sql — the Wiki: info-dump auto-organized into a browsable,
-- linked, growing store (.spec/proposals/lab-and-wiki.md Part 2)
-- =====================================================================
-- Michael's own words: "we really dont have a wiki, just a doc store and
-- a graph view... I cannot really human search it." This file ships the
-- SCHEMA + the primitives (WIKI-CORE's stripe of a 6-builder fleet): a
-- named-scope wiki over regenerable pages, page-level provenance, and the
-- two views that answer the proposal's most original ask — "the study or
-- doc can show the 'wiki' the agent pulled... then diff that against the
-- full source and see blind spots."
--
-- Fleet contract: WIKI-CORE owns every table below. Other builders in the
-- fleet (assets/extraction, curator/digester, browsing UI) REFERENCE these
-- tables; they do not create new ones. The curator agent that actually
-- sweeps an inbox and calls these functions is NOT built here — this file
-- ships the primitives it will call (wiki_page_upsert, wiki_page_dedup_check,
-- wiki_merge_propose, wiki_add_member, wiki_create) and the provenance
-- views (doc_pull_sources, doc_blind_spots), not the digester itself.
--
-- Six real-shape deviations from the brief, each discovered by reading the
-- actual SQL (not guessed), each documented at its call site below:
--
--  1. OK-NUMBER COLLISION. tests/virgin-smoke.sql already has "OK 92:" and
--     "OK 93:" RAISE NOTICE labels (the audit-synthesis M1 pin-final-bodies
--     check and the SECURITY DEFINER house rule) — pure test assertions
--     added with NO corresponding chain file (91-core-compat.sql is still
--     the last real file before this one). OK-block numbers in that file
--     already drift from chain-file numbers elsewhere (OK 73 is actually
--     file 82's test) — so this is precedented, not a new problem — but to
--     avoid a human grepping "OK 92" and finding two different meanings,
--     THIS file's own virgin-smoke block is labeled "OK 94". The next
--     fleet builder should follow with OK 95, not 94 or 92/93.
--
--  2. stewards.docs.id is TEXT (`gen_random_uuid()::text`), not uuid — and
--     every tool-call surface that carries a doc reference (doc_get's
--     `slug` argument, doc_search/doc_similar/pool_search result rows'
--     `slug` field) carries SLUG, never `id`. doc_pull_sources/
--     doc_blind_spots below take `p_doc_slug text`, not `p_doc uuid` as
--     the brief sketched — the mining key really is the slug. page_sources
--     .doc_id is `text REFERENCES stewards.docs(id)` for the same reason.
--
--  3. wiki_assets: the brief's sketch named a `storage_path text` column,
--     but P2/P3 rich-docs-in-chat (48-chat-attachments.sql, 49-doc-extract
--     .sql) store media as `bytes bytea` INLINE IN THE ROW — there is no
--     filesystem-path convention anywhere in this codebase for user/agent
--     content. wiki_assets follows the REAL convention (bytea +
--     source_attachment_id, when the asset already exists as a
--     chat_attachments row from doc-extract) rather than the sketched one.
--
--  4. work_items carries NO direct FK to the docs it produces. The only
--     link found is `docs.frontmatter->>'proposed_by_work_item_id'`,
--     stamped ONLY by apply_agent_proposal (13-research-pipelines.sql) for
--     docs created via the agent-proposal pipeline. Docs created via
--     doc_finalize/import_doc or the book/video digesters carry no such
--     link today. doc_pull_sources therefore takes an OPTIONAL
--     `p_work_item_id uuid DEFAULT NULL` override so a caller who already
--     knows the producing work_item (e.g. Stewdio, mid-session) isn't
--     stranded by the frontmatter heuristic — and returns an HONEST empty
--     set (not an error) when neither resolves.
--
--  5. tool-call mining is DOC-LEVEL, not chunk-level, by design — the brief
--     itself invited this: "If message tool-result shapes make chunk-level
--     mining unreliable, deliver doc-level faithfully and SAY SO." Verified
--     real shapes (tools.rs's own tool_dispatch parser is the ground
--     truth): an assistant message's tool_calls[i] = {id, type:"function",
--     function:{name, arguments: "<JSON-encoded STRING>"}}; the paired
--     role='tool' reply has content = the tool's JSON-serialized result
--     (a scalar TEXT column, cast at read time) and tool_call_id = the
--     call's id. doc_get's slug lives in the REQUEST (deterministic, no
--     result-parsing). doc_search/doc_similar/pool_search's slugs live in
--     the RESULT array (joined to the request by tool_call_id).
--     read_corpus_parents (paginated re-read of an oversized prior tool
--     result) takes a bare `message_id` — no doc slug is recoverable from
--     its own args or return shape, so it is mined at chunk-level ONLY
--     (chunk_ref = 'msg:<message_id>', doc_slug = NULL) rather than faking
--     a doc resolution the schema cannot support.
--
--  6. wiki_page_dedup_check's brief signature is (title, content) TEXT —
--     kept exactly (the OSS convention for TOOL-facing/text-in wrappers,
--     see doc_search_hybrid/world_entity_hybrid in 71, embed inline with a
--     graceful NULL-on-no-provider fallback). But 72's search_engrams_hybrid
--     established the OTHER half of this codebase's convention: take the
--     query EMBEDDING as a parameter so the math is deterministically
--     testable with a manufactured vector, no live provider required. Both
--     conventions are honored here: wiki_page_dedup_check_vec(vector) is
--     the pure, testable primitive; wiki_page_dedup_check(title, content)
--     is the text-in convenience wrapper that embeds via embed_query and
--     degrades to (false, NULL, NULL) with no provider.
--
-- One addition beyond the literal ask, done under the stewardship rule
-- (an obvious completion of a primitive this file already introduces, not
-- a new capability): wiki_merge_propose's Hinge-approved outcome needs
-- something to actually DO the merge. 41-memory-tend.sql's own pattern
-- (memory_apply_approved_link: an AFTER UPDATE OF status trigger on
-- hinge_reviews, WHEN kind=X AND status='approved', self-terminating
-- because it flips status to 'applied' which no longer matches the WHEN
-- clause) is reused verbatim as wiki_merge_apply_trigger — Michael's
-- approval alone performs the merge; no second manual "apply" call for a
-- future builder to forget to wire up.
--
-- requires create_core_compat (91) — installs at the tail of the chain;
-- reuses hinge_enqueue/hinge_reviews (39), work_items.session_ids (04),
-- docs (schema.rs/03), chat_attachments (48), embed_query (lib.rs/71).
-- =====================================================================

-- =====================================================================
-- §1 — wiki_pages + wiki_page_revisions: the regenerable page + its ledger
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.wiki_pages (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug           text NOT NULL UNIQUE,      -- page identity (Atlas/wiki lesson: identity is the hard part)
    title          text NOT NULL,
    content        text NOT NULL DEFAULT '',  -- markdown
    status         text NOT NULL DEFAULT 'live'
                   CHECK (status IN ('draft','live','superseded')),
    superseded_by  uuid REFERENCES stewards.wiki_pages(id) ON DELETE SET NULL,
    superseded_at  timestamptz,
    embedding      vector(768),
    embedded_at    timestamptz,
    embedded_model text,
    body_tsv       tsvector GENERATED ALWAYS AS (
                       to_tsvector('english', coalesce(title, '') || ' ' || coalesce(content, ''))
                   ) STORED,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS wiki_pages_status_idx    ON stewards.wiki_pages (status);
CREATE INDEX IF NOT EXISTS wiki_pages_fts_idx        ON stewards.wiki_pages USING gin (body_tsv);
CREATE INDEX IF NOT EXISTS wiki_pages_embedding_idx  ON stewards.wiki_pages USING hnsw (embedding vector_cosine_ops);

COMMENT ON TABLE stewards.wiki_pages IS
'92: a living topic page — REGENERABLE (dumps + provenance are the ledger; pages are the derived working memory, per the Atlas/wiki convergence in study/ai/elastic-atlas-agent-memory.md). slug is identity; wiki_page_revisions is the safety net that makes regeneration non-destructive. updated_at is maintained by the writer functions (wiki_page_upsert, wiki_merge_apply_trigger), not a trigger — every mutation path in this file sets it explicitly.';
COMMENT ON COLUMN stewards.wiki_pages.status IS
'92: draft = being built, not yet a citable page; live = the current regenerated view; superseded = merged into another page (see superseded_by) — a dead page is never deleted, only marked (same non-destructive discipline as docs.last_consolidated_at / graph_supersede in 44).';

CREATE TABLE IF NOT EXISTS stewards.wiki_page_revisions (
    id          bigserial PRIMARY KEY,
    page_id     uuid NOT NULL REFERENCES stewards.wiki_pages(id) ON DELETE CASCADE,
    rev         int NOT NULL,
    content     text NOT NULL,
    reason      text,     -- why this revision happened (a re-digest, a manual edit, a merge)
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (page_id, rev)
);
CREATE INDEX IF NOT EXISTS wiki_page_revisions_page_idx ON stewards.wiki_page_revisions (page_id, rev DESC);

COMMENT ON TABLE stewards.wiki_page_revisions IS
'92: the safety net under regeneration. One row per (page_id, rev); wiki_page_upsert appends here on every write, so a curator re-derivation (a better model, a bad merge) is always reversible by reading back an earlier rev — never a schema migration.';

-- =====================================================================
-- §2 — wiki_assets: extracted media, owned here (schema only — the
-- ASSETS builder fills these via extraction; see header deviation #3).
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.wiki_assets (
    id                    bigserial PRIMARY KEY,
    doc_id                text REFERENCES stewards.docs(id) ON DELETE SET NULL,           -- source doc this was extracted from
    kind                  text NOT NULL DEFAULT 'image' CHECK (kind IN ('image','table')),
    bytes                 bytea,                                                          -- inline storage — the P2/P3 convention (48/49), NOT a filesystem path
    mime_type             text,
    byte_size             int,
    source_attachment_id  bigint REFERENCES stewards.chat_attachments(id) ON DELETE SET NULL, -- when this asset already lives as a chat_attachments row (e.g. a 49 doc-extract page image), reference it instead of duplicating bytes
    caption               text,
    page_no               int,
    created_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS wiki_assets_doc_idx ON stewards.wiki_assets (doc_id);

COMMENT ON TABLE stewards.wiki_assets IS
'92: extracted media (images/tables) a wiki page can cite. Storage follows the REAL P2/P3 convention (48-chat-attachments.sql, 49-doc-extract.sql): bytea inline, not a filesystem path — see this file''s header deviation #3. source_attachment_id lets an asset point at an existing chat_attachments row (e.g. a doc-extract page image) instead of copying bytes twice. Schema owned by WIKI-CORE; populated by the assets/extraction builder.';

-- =====================================================================
-- §3 — page_links: the "See also" graph. Red links are a feature.
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.page_links (
    id         bigserial PRIMARY KEY,
    from_page  uuid NOT NULL REFERENCES stewards.wiki_pages(id) ON DELETE CASCADE,
    to_slug    text NOT NULL,   -- deliberately NOT an FK: a page that doesn't exist yet (a red link) is a real wiki's feature, not a defect
    kind       text NOT NULL DEFAULT 'ref',
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS page_links_from_idx    ON stewards.page_links (from_page);
CREATE INDEX IF NOT EXISTS page_links_to_slug_idx ON stewards.page_links (to_slug);

COMMENT ON TABLE stewards.page_links IS
'92: the wiki''s "See also" graph. to_slug is NOT a foreign key on purpose — a link to a topic that has no page yet (a red link) is exactly what a real wiki shows, and it is the cheapest signal of "a page that wants to exist." kind defaults ''ref''; wiki_merge_apply_trigger writes kind=''supersedes'' when a merge lands.';

-- =====================================================================
-- §4 — page_sources: per-claim-cluster provenance (what grounds this page)
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.page_sources (
    id          bigserial PRIMARY KEY,
    page_id     uuid NOT NULL REFERENCES stewards.wiki_pages(id) ON DELETE CASCADE,
    doc_id      text REFERENCES stewards.docs(id) ON DELETE SET NULL,          -- text, not uuid — see header deviation #2 (stewards.docs.id is text)
    chunk_ref   text,                                                          -- free-form pointer into the doc (a heading, a line range, a message id) when finer than whole-doc
    asset_id    bigint REFERENCES stewards.wiki_assets(id) ON DELETE SET NULL, -- bigint, not uuid — wiki_assets.id is bigserial
    kind        text NOT NULL DEFAULT 'doc',  -- open taxonomy (doc/asset/chunk/external...) — no CHECK, same philosophy as docs.kind
    note        text,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS page_sources_page_idx ON stewards.page_sources (page_id);
CREATE INDEX IF NOT EXISTS page_sources_doc_idx  ON stewards.page_sources (doc_id);

COMMENT ON TABLE stewards.page_sources IS
'92: provenance per claim-cluster on a wiki page — which doc/chunk/asset grounds this page (or this revision of it). Populated by wiki_page_upsert''s p_sources argument. doc_id/asset_id use the REAL column types (text/bigint) of the tables they reference, not the uuid the brief sketched — see header deviations #2 and #3.';

-- =====================================================================
-- §5 — wikis + wiki_members: a wiki is a NAMED SCOPE over many-to-many pages
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.wikis (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        text NOT NULL UNIQUE,
    title       text NOT NULL,
    kind        text NOT NULL DEFAULT 'collection'
                CHECK (kind IN ('project','world','manual','collection','pull')),
    scope       jsonb NOT NULL DEFAULT '{}'::jsonb,  -- the filter this wiki was scoped from (project/world/doc-kind/tags/a literal doc-id list) — open shape, read by whatever built it
    created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.wikis IS
'92: a NAMED SCOPE over wiki_pages (many-to-many via wiki_members). kind=''project''/''world''/''manual'' are standing scopes over existing corpora; kind=''collection'' is Michael''s on-the-spot wiki ("select a source or project... add to an on-the-spot wiki... saved/viewed/shared"); kind=''pull'' is the per-document provenance wiki (see doc_pull_sources below) materialized as a browsable page set when wanted.';

CREATE TABLE IF NOT EXISTS stewards.wiki_members (
    wiki_id   uuid NOT NULL REFERENCES stewards.wikis(id) ON DELETE CASCADE,
    page_id   uuid NOT NULL REFERENCES stewards.wiki_pages(id) ON DELETE CASCADE,
    added_by  text,   -- 'michael' | a curator/agent name | a function name (e.g. 'wiki_merge_apply')
    added_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (wiki_id, page_id)
);
CREATE INDEX IF NOT EXISTS wiki_members_page_idx ON stewards.wiki_members (page_id);

COMMENT ON TABLE stewards.wiki_members IS
'92: the many-to-many join — a page can belong to several wikis (a project wiki AND Michael''s on-the-spot collection), a wiki holds many pages. PRIMARY KEY (wiki_id, page_id) makes membership idempotent.';

-- =====================================================================
-- §6 — private helper: parse text as jsonb, or NULL on any failure.
-- Tool-call content/arguments are stored as scalar TEXT; a model-emitted
-- or provider-relayed string is not guaranteed well-formed JSON, and the
-- mining views below must never abort on one bad row.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards._wiki_safe_jsonb(p_text text)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $fn$
BEGIN
    RETURN p_text::jsonb;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$fn$;
COMMENT ON FUNCTION stewards._wiki_safe_jsonb(text) IS
'92: private helper (underscore prefix, per the 91/15b convention). Parses p_text as jsonb; returns NULL instead of raising on malformed input. Used by doc_pull_sources so one malformed tool_calls.arguments string or tool-reply content never aborts the whole mining query.';

-- =====================================================================
-- §7 — doc_pull_sources: "what the agent actually pulled" — mine the
-- producing work_item's sessions for doc/chunk retrieval evidence.
-- =====================================================================
-- Deviations from the brief's sketch are documented in the file header
-- (#2 uuid->text/slug, #4 the work_item link, #5 doc-level vs chunk-level).
--
-- Resolution order for the producing work_item:
--   1. p_work_item_id, if the caller already knows it (bypasses the
--      heuristic entirely — see header #4).
--   2. stewards.docs.frontmatter->>'proposed_by_work_item_id', the ONLY
--      link this schema stamps today (apply_agent_proposal only).
-- Neither resolving is not an error — it is an honest empty result (a doc
-- built by doc_finalize/import_doc/a book digester has no producing
-- work_item on file; that is a real gap in the schema, not a bug here).
CREATE OR REPLACE FUNCTION stewards.doc_pull_sources(
    p_doc_slug     text,
    p_work_item_id uuid DEFAULT NULL
) RETURNS TABLE (
    doc_slug   text,
    chunk_ref  text,
    tool       text,
    ts         timestamptz
) LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_wi_id       uuid := p_work_item_id;
    v_session_ids text[];
BEGIN
    IF v_wi_id IS NULL THEN
        BEGIN
            SELECT (frontmatter ->> 'proposed_by_work_item_id')::uuid INTO v_wi_id
              FROM stewards.docs WHERE slug = p_doc_slug;
        EXCEPTION WHEN OTHERS THEN
            v_wi_id := NULL;  -- malformed/absent frontmatter value — degrade to "unknown", not an error
        END;
    END IF;

    IF v_wi_id IS NULL THEN
        RETURN;  -- no discoverable producing work_item — honest empty set (see header #4)
    END IF;

    SELECT session_ids INTO v_session_ids FROM stewards.work_items WHERE id = v_wi_id;
    IF v_session_ids IS NULL OR cardinality(v_session_ids) = 0 THEN
        RETURN;
    END IF;

    RETURN QUERY
    WITH asst AS (
        -- every tool call the producing work_item's sessions made
        SELECT m.id, m.session_id, m.created_at, tc
          FROM stewards.messages m
          CROSS JOIN LATERAL jsonb_array_elements(m.tool_calls) AS tc
         WHERE m.session_id = ANY (v_session_ids)
           AND m.role = 'assistant'
           AND m.tool_calls IS NOT NULL
           AND jsonb_typeof(m.tool_calls) = 'array'
    ),
    -- doc_get: the slug is in the REQUEST — deterministic, no result join needed.
    doc_get_hits AS (
        SELECT stewards._wiki_safe_jsonb(a.tc #>> '{function,arguments}') ->> 'slug' AS doc_slug,
               NULL::text AS chunk_ref,
               'doc_get'::text AS tool,
               a.created_at AS ts
          FROM asst a
         WHERE a.tc #>> '{function,name}' = 'doc_get'
    ),
    -- doc_search / doc_similar / pool_search: the slugs are in the RESULT
    -- array, joined back to the request by tool_call_id (the OpenAI-shape
    -- reply contract every provider round-trip in this substrate honors).
    search_calls AS (
        SELECT a.tc ->> 'id' AS tc_id, a.session_id, a.tc #>> '{function,name}' AS fn_name
          FROM asst a
         WHERE a.tc #>> '{function,name}' IN ('doc_search', 'doc_similar', 'pool_search')
    ),
    search_hits AS (
        SELECT elem ->> 'slug' AS doc_slug,
               NULL::text AS chunk_ref,
               sc.fn_name AS tool,
               t.created_at AS ts
          FROM search_calls sc
          JOIN stewards.messages t
            ON t.session_id = sc.session_id AND t.role = 'tool' AND t.tool_call_id = sc.tc_id
          CROSS JOIN LATERAL jsonb_array_elements(
              CASE WHEN jsonb_typeof(coalesce(stewards._wiki_safe_jsonb(t.content), 'null'::jsonb)) = 'array'
                   THEN stewards._wiki_safe_jsonb(t.content)
                   ELSE '[]'::jsonb END
          ) AS elem
    ),
    -- read_corpus_parents: chunk-level ONLY (see header #5) — no doc slug
    -- is recoverable from its own args/return shape (it re-reads an
    -- oversized PRIOR tool result keyed by message_id, not a doc).
    corpus_hits AS (
        SELECT NULL::text AS doc_slug,
               'msg:' || (stewards._wiki_safe_jsonb(a.tc #>> '{function,arguments}') ->> 'message_id') AS chunk_ref,
               'read_corpus_parents'::text AS tool,
               a.created_at AS ts
          FROM asst a
         WHERE a.tc #>> '{function,name}' = 'read_corpus_parents'
    )
    SELECT * FROM doc_get_hits  WHERE doc_get_hits.doc_slug IS NOT NULL
    UNION ALL
    SELECT * FROM search_hits  WHERE search_hits.doc_slug IS NOT NULL
    UNION ALL
    SELECT * FROM corpus_hits
    ORDER BY ts;
END;
$fn$;

COMMENT ON FUNCTION stewards.doc_pull_sources(text, uuid) IS
'92: the "wiki the agent pulled" for one produced doc — mines its producing work_item''s sessions'' messages for doc/chunk retrieval tool calls (doc_get from the request; doc_search/doc_similar/pool_search from the paired result; read_corpus_parents at chunk-level only). p_work_item_id overrides the frontmatter heuristic (docs.frontmatter->>''proposed_by_work_item_id'', stamped only by apply_agent_proposal today — see file header #4). Returns an honest empty set, never an error, when the producing work_item cannot be found.';

-- =====================================================================
-- §8 — doc_blind_spots: the anti-join — what was NEVER pulled.
-- =====================================================================
-- p_scope recognizes: {"kind": "study"|["study","proposal"], "project_association":
-- "...", "tags": ["..."]}. Any key omitted = unfiltered on that axis. An
-- empty scope ({}) means "the whole corpus" — every other doc is a
-- candidate blind spot, which is a reasonable and honest default.
CREATE OR REPLACE FUNCTION stewards.doc_blind_spots(
    p_doc_slug     text,
    p_scope        jsonb DEFAULT '{}'::jsonb,
    p_work_item_id uuid  DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_pulled       text[];
    v_scope_kinds  text[];
    v_scope_proj   text;
    v_scope_tags   text[];
    v_total        int;
    v_retrieved    int;
    v_blind        jsonb;
BEGIN
    SELECT coalesce(array_agg(DISTINCT doc_slug), ARRAY[]::text[]) INTO v_pulled
      FROM stewards.doc_pull_sources(p_doc_slug, p_work_item_id)
     WHERE doc_slug IS NOT NULL;

    v_scope_kinds := CASE WHEN p_scope ? 'kind'
        THEN ARRAY(SELECT jsonb_array_elements_text(
                 CASE WHEN jsonb_typeof(p_scope -> 'kind') = 'array'
                      THEN p_scope -> 'kind'
                      ELSE jsonb_build_array(p_scope ->> 'kind') END))
        ELSE NULL END;
    v_scope_proj := p_scope ->> 'project_association';
    v_scope_tags := CASE WHEN p_scope ? 'tags'
        THEN ARRAY(SELECT jsonb_array_elements_text(p_scope -> 'tags'))
        ELSE NULL END;

    WITH scoped AS (
        SELECT d.slug, d.kind, d.title
          FROM stewards.docs d
         WHERE d.slug <> p_doc_slug
           AND (v_scope_kinds IS NULL OR d.kind = ANY (v_scope_kinds))
           AND (v_scope_proj  IS NULL OR d.project_association = v_scope_proj)
           AND (v_scope_tags  IS NULL OR d.tags && v_scope_tags)
    )
    SELECT count(*),
           count(*) FILTER (WHERE slug = ANY (v_pulled)),
           coalesce(jsonb_agg(jsonb_build_object('slug', slug, 'kind', kind, 'title', title)
                    ORDER BY slug) FILTER (WHERE NOT (slug = ANY (v_pulled))), '[]'::jsonb)
      INTO v_total, v_retrieved, v_blind
      FROM scoped;

    RETURN jsonb_build_object(
        'doc_slug',        p_doc_slug,
        'scope',           p_scope,
        'retrieved_slugs', to_jsonb(v_pulled),
        'blind_spots',     v_blind,
        'summary', jsonb_build_object(
            'total_in_scope', v_total,
            'retrieved',      v_retrieved,
            'blind',          v_total - v_retrieved,
            'coverage_pct',   CASE WHEN v_total > 0
                                   THEN round((100.0 * v_retrieved / v_total)::numeric, 1)
                                   ELSE NULL END
        )
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.doc_blind_spots(text, jsonb, uuid) IS
'92: the anti-join — docs matching p_scope (kind/project_association/tags; {} = whole corpus) that doc_pull_sources NEVER touched while producing p_doc_slug, plus a summary (total_in_scope/retrieved/blind/coverage_pct). Doc-level, matching doc_pull_sources — see file header #5 for why chunk-level precision is not faked.';

-- =====================================================================
-- §9 — wiki_page_upsert: revision-aware write (the regeneration path).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.wiki_page_upsert(
    p_slug    text,
    p_title   text,
    p_content text,
    p_sources jsonb DEFAULT '[]'::jsonb,
    p_reason  text  DEFAULT NULL,
    p_status  text  DEFAULT 'live'
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_id        uuid;
    v_next_rev  int;
    v_provider  text;
    v_model     text;
    v_vec       vector(768);
    v_src       jsonb;
BEGIN
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    BEGIN
        v_vec := stewards.embed_query(coalesce(p_title, '') || E'\n\n' || coalesce(p_content, ''),
                                       v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;  -- no embed provider / down — the page still writes, just unembedded until a later pass
    END;

    INSERT INTO stewards.wiki_pages (slug, title, content, status, embedding, embedded_at, embedded_model)
    VALUES (p_slug, p_title, p_content, coalesce(p_status, 'live'), v_vec,
            CASE WHEN v_vec IS NOT NULL THEN now() END, v_model)
    ON CONFLICT (slug) DO UPDATE
       SET title       = EXCLUDED.title,
           content     = EXCLUDED.content,
           -- a superseded page stays superseded — upsert never resurrects
           -- a merged-away page out from under wiki_merge_apply_trigger.
           status      = CASE WHEN stewards.wiki_pages.status = 'superseded'
                              THEN stewards.wiki_pages.status ELSE EXCLUDED.status END,
           embedding   = coalesce(EXCLUDED.embedding, stewards.wiki_pages.embedding),
           embedded_at = CASE WHEN EXCLUDED.embedding IS NOT NULL THEN now() ELSE stewards.wiki_pages.embedded_at END,
           updated_at  = now()
     RETURNING id INTO v_id;

    SELECT coalesce(max(rev), 0) + 1 INTO v_next_rev
      FROM stewards.wiki_page_revisions WHERE page_id = v_id;

    INSERT INTO stewards.wiki_page_revisions (page_id, rev, content, reason)
    VALUES (v_id, v_next_rev, p_content, p_reason);

    FOR v_src IN SELECT * FROM jsonb_array_elements(coalesce(p_sources, '[]'::jsonb))
    LOOP
        INSERT INTO stewards.page_sources (page_id, doc_id, chunk_ref, asset_id, kind, note)
        VALUES (
            v_id,
            NULLIF(v_src ->> 'doc_id', ''),
            NULLIF(v_src ->> 'chunk_ref', ''),
            NULLIF(v_src ->> 'asset_id', '')::bigint,
            coalesce(v_src ->> 'kind', 'doc'),
            v_src ->> 'note'
        );
    END LOOP;

    RETURN v_id;
END;
$fn$;

COMMENT ON FUNCTION stewards.wiki_page_upsert(text, text, text, jsonb, text, text) IS
'92: revision-aware wiki page write — the regeneration path. Upserts wiki_pages by slug (identity), appends a wiki_page_revisions row (rev = max+1), files p_sources into page_sources, and embeds inline (embed_query, graceful NULL-on-no-provider). Never resurrects a superseded page. p_sources element shape: {"doc_id","chunk_ref","asset_id","kind","note"} (all optional).';

-- =====================================================================
-- §10 — wiki_add_member / wiki_create: named-scope membership.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.wiki_create(
    p_slug  text,
    p_title text,
    p_kind  text  DEFAULT 'collection',
    p_scope jsonb DEFAULT '{}'::jsonb
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE v_id uuid;
BEGIN
    INSERT INTO stewards.wikis (slug, title, kind, scope)
    VALUES (p_slug, p_title, coalesce(p_kind, 'collection'), coalesce(p_scope, '{}'::jsonb))
    ON CONFLICT (slug) DO UPDATE
       SET title = EXCLUDED.title, kind = EXCLUDED.kind, scope = EXCLUDED.scope
     RETURNING id INTO v_id;
    RETURN v_id;
END;
$fn$;
COMMENT ON FUNCTION stewards.wiki_create(text, text, text, jsonb) IS
'92: upsert a named-scope wiki (kind: project|world|manual|collection|pull) by slug.';

CREATE OR REPLACE FUNCTION stewards.wiki_add_member(
    p_wiki_slug text,
    p_page_slug text,
    p_added_by  text DEFAULT NULL
) RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
    v_wiki_id uuid;
    v_page_id uuid;
BEGIN
    SELECT id INTO v_wiki_id FROM stewards.wikis      WHERE slug = p_wiki_slug;
    SELECT id INTO v_page_id FROM stewards.wiki_pages WHERE slug = p_page_slug;
    IF v_wiki_id IS NULL THEN
        RAISE EXCEPTION 'wiki_add_member: no wiki with slug %', p_wiki_slug;
    END IF;
    IF v_page_id IS NULL THEN
        RAISE EXCEPTION 'wiki_add_member: no wiki_page with slug %', p_page_slug;
    END IF;
    INSERT INTO stewards.wiki_members (wiki_id, page_id, added_by)
    VALUES (v_wiki_id, v_page_id, p_added_by)
    ON CONFLICT (wiki_id, page_id) DO NOTHING;
    RETURN true;
END;
$fn$;
COMMENT ON FUNCTION stewards.wiki_add_member(text, text, text) IS
'92: add an existing wiki_page (by slug) to an existing wiki (by slug). Idempotent (ON CONFLICT DO NOTHING on the (wiki_id,page_id) primary key).';

-- =====================================================================
-- §11 — wiki_page_dedup_check{,_vec}: the LIGHTNING-tier dedup gate.
-- =====================================================================
-- _vec is the pure, deterministic primitive (query embedding as a
-- parameter — 72's search_engrams_hybrid convention, testable with a
-- manufactured vector and no live embed provider). The text-in wrapper is
-- the brief's exact requested signature (71's doc_search_hybrid
-- convention: embed inline, degrade to (false,NULL,NULL) with no provider).
CREATE OR REPLACE FUNCTION stewards.wiki_page_dedup_check_vec(p_vec vector(768))
RETURNS TABLE (is_duplicate boolean, existing_slug text, similarity real)
LANGUAGE sql STABLE AS $fn$
    SELECT coalesce((1 - (wp.embedding <=> p_vec)) >= 0.90, false),
           wp.slug,
           (1 - (wp.embedding <=> p_vec))::real
      FROM (SELECT 1) AS z
      LEFT JOIN LATERAL (
          SELECT embedding, slug FROM stewards.wiki_pages
           WHERE embedding IS NOT NULL AND status <> 'superseded'
           ORDER BY embedding <=> p_vec
           LIMIT 1
      ) AS wp ON true;
$fn$;
COMMENT ON FUNCTION stewards.wiki_page_dedup_check_vec(vector) IS
'92: the pure dedup primitive — cosine similarity (1 - the pgvector <=> distance) of p_vec against the closest live/draft wiki_pages.embedding. similarity >= 0.90 is the Atlas rule (study/ai/elastic-atlas-agent-memory.md: "a fact whose top similarity clears >= 0.90 is treated as a duplicate"). Always returns exactly one row (false/NULL/NULL when no embedded page exists yet) so callers never special-case "no candidates".';

CREATE OR REPLACE FUNCTION stewards.wiki_page_dedup_check(
    p_title   text,
    p_content text
) RETURNS TABLE (is_duplicate boolean, existing_slug text, similarity real)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_provider text;
    v_model    text;
    v_vec      vector(768);
BEGIN
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    BEGIN
        v_vec := stewards.embed_query(coalesce(p_title, '') || E'\n\n' || coalesce(p_content, ''),
                                       v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;
    END;
    IF v_vec IS NULL THEN
        RETURN QUERY SELECT false, NULL::text, NULL::real;
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM stewards.wiki_page_dedup_check_vec(v_vec);
END;
$fn$;
COMMENT ON FUNCTION stewards.wiki_page_dedup_check(text, text) IS
'92: text-in convenience wrapper over wiki_page_dedup_check_vec — embeds title+content inline via embed_query (graceful NULL-on-no-provider, same convention as doc_search_hybrid in 71). is_duplicate>=0.90 is the auto-supersede-candidate signal (LIGHTNING tier); below threshold, the caller treats the page as distinct. Auto-supersede itself is the CALLER''s decision (a future curator digester), not performed here.';

-- =====================================================================
-- §12 — wiki_merge_propose + the Hinge-applied merge (MOUNTAIN tier).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.wiki_merge_propose(
    p_from_slug text,
    p_to_slug   text,
    p_rationale text DEFAULT NULL
) RETURNS bigint LANGUAGE sql AS $fn$
    SELECT stewards.hinge_enqueue(
        'wiki-merge',
        format('merge wiki page %s into %s', p_from_slug, p_to_slug),
        jsonb_build_object('from_slug', p_from_slug, 'to_slug', p_to_slug, 'rationale', p_rationale),
        'wiki_merge_propose'
    );
$fn$;
COMMENT ON FUNCTION stewards.wiki_merge_propose(text, text, text) IS
'92: page identity is the hard part (Atlas comparison) — a MOUNTAIN-tier structural change is never auto-applied. Parks a kind=''wiki-merge'' row on the real 39-hinge queue (reused, not reinvented). Approval performs the merge automatically — see wiki_merge_apply_trigger.';

-- wiki-merge ALWAYS escalates to Michael regardless of the claude-hinge
-- reviewer''s verdict — same defense-in-depth append as 84's tool-confirm
-- (idempotent: only appends if not already present).
UPDATE stewards.config
   SET value = value || '["wiki-merge"]'::jsonb
 WHERE key = 'hinge_escalate_always_kinds'
   AND NOT (value ? 'wiki-merge');

-- wiki_merge_apply_trigger: fires the moment a wiki-merge review's status
-- flips to 'approved' (Michael's own approval, per hinge_record_verdict's
-- v_michael bypass — the escalate-always wall above only binds the
-- claude-hinge reviewer, never Michael). Self-terminating: it sets
-- status='applied', which no longer matches the WHEN clause, so the
-- trigger's own UPDATE cannot recurse. Pattern reused verbatim from
-- memory_apply_approved_link (41-memory-tend.sql).
CREATE OR REPLACE FUNCTION stewards.wiki_merge_apply_trigger()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_from    text := NEW.payload ->> 'from_slug';
    v_to      text := NEW.payload ->> 'to_slug';
    v_from_id uuid;
    v_to_id   uuid;
BEGIN
    SELECT id INTO v_from_id FROM stewards.wiki_pages WHERE slug = v_from;
    SELECT id INTO v_to_id   FROM stewards.wiki_pages WHERE slug = v_to;

    IF v_from_id IS NULL OR v_to_id IS NULL THEN
        -- leave status='approved' (NOT 'applied') so the gap stays visible
        -- on the queue rather than silently swallowed.
        UPDATE stewards.hinge_reviews
           SET payload = payload || jsonb_build_object('apply_error',
                 format('wiki-merge apply: from(%s)=%s to(%s)=%s — one or both pages missing',
                        v_from, v_from_id, v_to, v_to_id))
         WHERE id = NEW.id;
        RETURN NEW;
    END IF;

    UPDATE stewards.wiki_pages
       SET status = 'superseded', superseded_by = v_to_id, superseded_at = now(), updated_at = now()
     WHERE id = v_from_id;

    -- carry every wiki membership the FROM page held onto the TO page.
    INSERT INTO stewards.wiki_members (wiki_id, page_id, added_by)
    SELECT wm.wiki_id, v_to_id, 'wiki_merge_apply'
      FROM stewards.wiki_members wm
     WHERE wm.page_id = v_from_id
    ON CONFLICT (wiki_id, page_id) DO NOTHING;

    -- a visible trail: the old page becomes a red/live link pointing at its merge target.
    INSERT INTO stewards.page_links (from_page, to_slug, kind)
    VALUES (v_from_id, v_to, 'supersedes');

    UPDATE stewards.hinge_reviews SET status = 'applied', applied_at = now() WHERE id = NEW.id;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS hinge_apply_wiki_merge ON stewards.hinge_reviews;
CREATE TRIGGER hinge_apply_wiki_merge
AFTER UPDATE OF status ON stewards.hinge_reviews
FOR EACH ROW WHEN (NEW.kind = 'wiki-merge' AND NEW.status = 'approved')
EXECUTE FUNCTION stewards.wiki_merge_apply_trigger();

COMMENT ON FUNCTION stewards.wiki_merge_apply_trigger() IS
'92: fires on hinge_reviews status -> approved for kind=wiki-merge. Marks the FROM page superseded (pointing at the TO page), carries its wiki_members over, writes a page_links(kind=supersedes) trail, and marks the review applied. Self-terminating (see comment above the trigger) — no separate manual "apply" call exists or is needed.';

-- =====================================================================
-- End of 92-wiki.sql
-- =====================================================================
