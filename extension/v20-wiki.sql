-- ===== [was 92-wiki.sql] =====
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
-- ===== [was 93-recall.sql] =====
-- =====================================================================
-- 93-recall.sql — the Atlas steal: retrieval-time relevance decay + a
-- use-count boost, as an explicit scoring term on the hybrid RRF fusions.
-- =====================================================================
-- Grounded in study/ai/elastic-atlas-agent-memory.md takeaway 1 ("Retrieval-
-- time relevance decay + use-count boost, as an explicit scoring term").
-- Elastic's Atlas bumps `last_used_at` on every semantic-memory recall and
-- multiplies its ranking score by `1 + log10(1+use_count) * weight`, plus a
-- Gauss decay on last_used_at — "relevance decay, not truth decay; truth
-- decay is handled by supersession." We had no retrieval-time recency or
-- frequency term anywhere (checked graph_recall, doc_search_hybrid, and the
-- RRF files per the study's own open question) — 71/72 fuse two RETRIEVERS
-- (lexical + semantic) but never learn from PAST retrievals. This file adds
-- that third axis to the two surfaces the study named: the doc-chunk search
-- surface (stewards.docs, read by doc_search_hybrid + pool_search_hybrid)
-- and the engram memory (stewards.engram_embeddings, read by
-- search_engrams_hybrid). world_entity_hybrid (a different table,
-- world_entities) is left untouched — out of this file's named scope.
--
-- THREE pieces:
--
--   1. Schema: last_used_at timestamptz + use_count int DEFAULT 0 on both
--      tables. Both are extension-owned tables (docs is born in schema.rs's
--      create_docs block; engram_embeddings in 15a) so a plain
--      `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` is exactly 72's own
--      precedent (engram_fts landed the same way) — a fast, metadata-only,
--      NOT NULL DEFAULT 0 add (PG11+: no table rewrite), fully live-safe via
--      scripts/migrate.sh (functions CREATE OR REPLACE, tables/columns
--      IF NOT EXISTS — no CREATE EXTENSION CASCADE required to apply this
--      file to a running deployment). There is no case here where a column
--      "can't" be added live; both tables are ours to alter.
--
--   2. stewards.recall_boost(use_count, last_used_at, freq_w, rec_w,
--      half_life) — ONE shared scoring function (not duplicated three
--      times) returning a real multiplier:
--        freq_mult = 1 + log10(1 + use_count) * freq_w        (>= 1, BOOST
--                    ONLY — use_count=0 (brand-new/unproven) => exactly 1.0,
--                    so the frequency term can never bury new content, only
--                    lift proven content above it)
--        rec_mult  = last_used_at IS NULL ? 1.0                (never
--                    recalled => neutral, same "don't bury the new" logic)
--                  : (1 - rec_w) + rec_w * 0.5^(days_idle / half_life)
--                    (exponential half-life decay toward a FLOOR of
--                    1-rec_w, never toward 0 — "relevance decay, not truth
--                    decay": a stale row gets tempered, not erased)
--      final multiplier = freq_mult * rec_mult. Two old docs with equal RRF
--      rank: the one used recently keeps rec_mult ~1 while the idle one
--      decays toward its floor, so old-but-recently-useful outranks
--      old-and-idle. A brand-new doc keeps multiplier == 1.0 exactly
--      (neutral on both terms), so it competes on pure RRF, never buried.
--      Weights read from stewards.config (00's key/value dial surface):
--        recall.freq_weight            default 0.2
--        recall.recency_weight         default 0.4  (in [0,1])
--        recall.recency_half_life_days default 30
--
--   3. Re-author doc_search_hybrid / pool_search_hybrid / search_engrams_-
--      hybrid to multiply their fused RRF score by recall_boost (read-only —
--      still STABLE, still pure, no side effects; the multiply happens
--      inside each function's own `fused` CTE, mirroring exactly how the
--      existing code already computes that column, so the diff versus
--      71/72 is the smallest one that does the job). Then add THREE NEW
--      `*_recall` wrapper functions (doc_search_recall, pool_search_recall,
--      search_engrams_recall) that call the pure hybrid fn once (a
--      MATERIALIZED CTE — forces one evaluation, since these do a real
--      embed_query round-trip) and UPDATE last_used_at/use_count on exactly
--      the rows returned, via a second, writable CTE over the SAME
--      materialized result — a side-effect wrapper, not a rewrite of the
--      STABLE search fns. Finally, repoint the three AGENT-FACING tool
--      wrappers (doc_search_tool, pool_search_tool, engram_search_tool) to
--      call the `*_recall` variant instead of the bare hybrid fn, so real
--      agent usage (and, via the new stewards-ui search surface, real human
--      usage) is exactly what feeds the boost — no separate "usage
--      tracking" system, the search path IS the usage signal.
--
-- requires create_core_compat (91) — the last entry in this worktree at
-- authoring time. WIKI-SEARCH and WIKI-CORE (92, a wiki table + wiki_create/
-- wiki_add_member/wiki_page_upsert) were built in parallel worktrees; the
-- integrator re-stitches this to `requires = ["create_wiki"]` (or whatever
-- 92 registers as) when both land, so the merged chain reads 91 -> 92 -> 93
-- instead of two siblings both hanging off 91.
-- =====================================================================


-- =====================================================================
-- §1 — schema: last_used_at + use_count on both recall surfaces.
-- =====================================================================
ALTER TABLE stewards.docs
  ADD COLUMN IF NOT EXISTS last_used_at timestamptz,
  ADD COLUMN IF NOT EXISTS use_count    int NOT NULL DEFAULT 0;

COMMENT ON COLUMN stewards.docs.last_used_at IS
'93/recall: bumped to now() by doc_search_recall/pool_search_recall whenever this doc is an actually-returned hybrid-search hit (agent tool call or the stewards-ui search page). NULL = never recalled since this column existed — treated as neutral (no recency penalty) by recall_boost.';
COMMENT ON COLUMN stewards.docs.use_count IS
'93/recall: incremented by doc_search_recall/pool_search_recall on every hit. Feeds recall_boost''s frequency term (1 + log10(1+use_count)*weight) — a boost only, never a filter.';

ALTER TABLE stewards.engram_embeddings
  ADD COLUMN IF NOT EXISTS last_used_at timestamptz,
  ADD COLUMN IF NOT EXISTS use_count    int NOT NULL DEFAULT 0;

COMMENT ON COLUMN stewards.engram_embeddings.last_used_at IS
'93/recall: bumped to now() by search_engrams_recall whenever this engram is an actually-returned hybrid-search hit. NULL = never recalled — neutral, no recency penalty (see stewards.recall_boost).';
COMMENT ON COLUMN stewards.engram_embeddings.use_count IS
'93/recall: incremented by search_engrams_recall on every hit. Feeds recall_boost''s frequency term.';


-- =====================================================================
-- §2 — the shared scoring term. Config-driven; sane defaults seeded below.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.recall_boost(
    p_use_count      int,
    p_last_used_at   timestamptz,
    p_freq_weight    double precision DEFAULT 0.2,
    p_recency_weight double precision DEFAULT 0.4,
    p_half_life_days double precision DEFAULT 30
) RETURNS real
LANGUAGE sql STABLE AS $$
    SELECT (
        -- frequency term — boost only. use_count=0 (unproven/brand-new)
        -- => log10(1)=0 => exactly 1.0: never buries new content, only
        -- lifts content that has actually been useful.
        (1.0 + log((1.0 + greatest(coalesce(p_use_count, 0), 0))::float8) * p_freq_weight)
        *
        -- recency term — NULL last_used_at (never recalled) => exactly
        -- 1.0, same "don't penalize the unproven" logic. Otherwise an
        -- exponential half-life decay toward a floor of (1-recency_weight),
        -- never toward 0: "relevance decay, not truth decay" (Atlas's own
        -- framing) — supersession, not this multiplier, is what should ever
        -- make old content unfindable.
        CASE WHEN p_last_used_at IS NULL THEN 1.0
             ELSE (1.0 - p_recency_weight)
                + p_recency_weight * power(
                      0.5::float8,
                      greatest(extract(epoch FROM (now() - p_last_used_at)) / 86400.0, 0.0)
                      / greatest(p_half_life_days, 0.001)
                  )
        END
    )::real;
$$;
COMMENT ON FUNCTION stewards.recall_boost(int, timestamptz, double precision, double precision, double precision) IS
'93: the Atlas steal (study/ai/elastic-atlas-agent-memory.md takeaway 1) as one shared scoring term, called from doc_search_hybrid/pool_search_hybrid/search_engrams_hybrid''s fused CTEs. frequency boost (1+log10(1+use_count)*freq_weight, floor 1.0, boost-only) times a recency multiplier (half-life decay on last_used_at toward a floor of 1-recency_weight; exactly 1.0 when never recalled). Old-but-recently-useful outranks old-and-idle; brand-new unproven content is never buried (both terms are neutral 1.0 with no history). Weights are read once per hybrid-fn invocation from stewards.config and passed in — this fn itself takes them as plain parameters so it stays a cheap, pure, per-row scalar.';

-- Config dials (00's key/value surface). Seeds only — operator-owned after
-- install (ON CONFLICT DO NOTHING, same convention as 00-config.sql).
INSERT INTO stewards.config (key, value, description) VALUES
  ('recall.freq_weight', '0.2'::jsonb,
   '93/recall: weight on the use-count boost term (1 + log10(1+use_count)*freq_weight) applied inside doc_search_hybrid/pool_search_hybrid/search_engrams_hybrid. 0 disables the frequency boost entirely (pure RRF + recency).'),
  ('recall.recency_weight', '0.4'::jsonb,
   '93/recall: how strongly recency-since-last-use can discount a hybrid score, in [0,1]. 0 disables recency decay entirely; 1 lets a fully-idle row''s recency multiplier decay all the way to 0x. Never applies to rows with no last_used_at — unproven content is never penalized.'),
  ('recall.recency_half_life_days', '30'::jsonb,
   '93/recall: days since last_used_at at which the recency multiplier''s decaying portion halves. Smaller = usage staleness bites faster.')
ON CONFLICT (key) DO NOTHING;


-- =====================================================================
-- §3 — doc_search_hybrid: fold recall_boost into the fused CTE.
-- Signature UNCHANGED from 72 (text, text[], int, boolean) — CREATE OR
-- REPLACE is sufficient, no DROP needed. Only the `fused` CTE's score
-- expression changes (an extra JOIN to read use_count/last_used_at + the
-- multiply); `direct`/`flr`/`nbr`/the outer UNION are untouched, so
-- graph-expand neighbors are (correctly) scored relative to the
-- ALREADY-boosted floor.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.doc_search_hybrid(
    p_query  text,
    p_kinds  text[]  DEFAULT ARRAY[]::text[],
    p_limit  int     DEFAULT 10,
    p_expand boolean DEFAULT false
) RETURNS TABLE (
    slug text, kind text, title text, snippet text, rank real
)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_provider  text;
    v_model     text;
    v_vec       vector(768);
    v_k         constant int := 60;
    v_freq_w    double precision;
    v_rec_w     double precision;
    v_half_life double precision;
BEGIN
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    v_freq_w    := stewards.config_get_text('recall.freq_weight', '0.2')::double precision;
    v_rec_w     := stewards.config_get_text('recall.recency_weight', '0.4')::double precision;
    v_half_life := stewards.config_get_text('recall.recency_half_life_days', '30')::double precision;
    BEGIN
        v_vec := stewards.embed_query(p_query, v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;
    END;

    RETURN QUERY
    WITH lex AS (
        SELECT d.slug AS d_slug, ROW_NUMBER() OVER (ORDER BY d.rank DESC, d.slug) AS rank
          FROM stewards.doc_search(p_query, p_kinds, p_limit * 3) d
    ),
    sem AS (
        SELECT s.slug AS d_slug, ROW_NUMBER() OVER (ORDER BY s.embedding <=> v_vec) AS rank
          FROM stewards.docs s
         WHERE v_vec IS NOT NULL AND s.embedding IS NOT NULL
           AND (cardinality(p_kinds) = 0 OR s.kind = ANY(p_kinds))
         ORDER BY s.embedding <=> v_vec
         LIMIT p_limit * 3
    ),
    fused AS (
        -- 93: the fused RRF score × this doc's recall_boost. d.use_count=0 /
        -- d.last_used_at IS NULL (a brand-new doc) => boost==1.0 exactly, so
        -- this is byte-identical to 72's math until something has actually
        -- been recalled at least once.
        SELECT coalesce(lex.d_slug, sem.d_slug) AS f_slug,
               ((coalesce(1.0/(v_k + lex.rank), 0)
               + coalesce(1.0/(v_k + sem.rank), 0))
               * stewards.recall_boost(d.use_count, d.last_used_at, v_freq_w, v_rec_w, v_half_life)
              )::real AS score
          FROM lex FULL JOIN sem ON lex.d_slug = sem.d_slug
          JOIN stewards.docs d ON d.slug = coalesce(lex.d_slug, sem.d_slug)
    ),
    direct AS (
        SELECT d.slug, d.kind, d.title,
               ts_headline('english', coalesce(d.body, ''),
                           websearch_to_tsquery('english', p_query),
                           'MaxWords=20, MinWords=10, ShortWord=3') AS snippet,
               f.score AS rank
          FROM fused f JOIN stewards.docs d ON d.slug = f.f_slug
         ORDER BY f.score DESC, d.slug
         LIMIT GREATEST(p_limit, 1)
    ),
    flr AS (SELECT min(direct.rank) AS f FROM direct),
    nbr AS (
        SELECT DISTINCT ON (sim.slug)
               sim.slug, dn.kind, dn.title,
               ts_headline('english', coalesce(dn.body, ''),
                           websearch_to_tsquery('english', p_query),
                           'MaxWords=20, MinWords=10, ShortWord=3') AS snippet,
               ((SELECT f FROM flr) * 0.5 * sim.score)::real AS rank
          FROM direct d
          JOIN LATERAL stewards.doc_similar(d.slug, 5) sim ON true
          JOIN stewards.docs dn ON dn.slug = sim.slug
         WHERE p_expand
           AND sim.slug NOT IN (SELECT direct.slug FROM direct)
           AND (cardinality(p_kinds) = 0 OR dn.kind = ANY(p_kinds))
         ORDER BY sim.slug, sim.score DESC
    )
    SELECT u.* FROM (
        SELECT * FROM direct
        UNION ALL
        SELECT * FROM nbr
    ) u
     ORDER BY u.rank DESC NULLS LAST
     LIMIT CASE WHEN p_expand THEN GREATEST(p_limit, 1) * 2 ELSE GREATEST(p_limit, 1) END;
END $fn$;
COMMENT ON FUNCTION stewards.doc_search_hybrid(text, text[], int, boolean) IS
'71/72/93: hybrid doc search — FTS (doc_search) fused with semantic (embed_query cosine over docs.embedding) via real equal-weight RRF (k=60), then scaled by stewards.recall_boost (use-count + recency-since-last-recall). p_expand=true adds a 1-hop SIMILAR_TO graph-expand. Degrades to FTS-only with no embed provider. STABLE / no side effects — doc_search_recall is the wrapper that bumps usage.';


-- =====================================================================
-- §4 — pool_search_hybrid: same treatment (reads the same stewards.docs).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.pool_search_hybrid(
    p_query     text,
    p_neighbors text[]  DEFAULT NULL,
    p_limit     int     DEFAULT 10,
    p_expand    boolean DEFAULT false
) RETURNS TABLE (
    slug text, kind text, title text, project_association text, snippet text, rank real
)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_provider  text;
    v_model     text;
    v_vec       vector(768);
    v_k         constant int := 60;
    v_freq_w    double precision;
    v_rec_w     double precision;
    v_half_life double precision;
BEGIN
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    v_freq_w    := stewards.config_get_text('recall.freq_weight', '0.2')::double precision;
    v_rec_w     := stewards.config_get_text('recall.recency_weight', '0.4')::double precision;
    v_half_life := stewards.config_get_text('recall.recency_half_life_days', '30')::double precision;
    BEGIN
        v_vec := stewards.embed_query(p_query, v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;
    END;

    RETURN QUERY
    WITH lex AS (
        SELECT p.slug AS d_slug,
               ROW_NUMBER() OVER (ORDER BY p.rank DESC, p.slug) AS rank
          FROM stewards.pool_search(p_query, p_neighbors, p_limit * 3) p
    ),
    sem AS (
        SELECT s.slug AS d_slug,
               ROW_NUMBER() OVER (ORDER BY s.embedding <=> v_vec) AS rank
          FROM stewards.docs s
         WHERE v_vec IS NOT NULL AND s.embedding IS NOT NULL
           AND (p_neighbors IS NULL OR s.project_association = ANY(p_neighbors))
         ORDER BY s.embedding <=> v_vec
         LIMIT p_limit * 3
    ),
    fused AS (
        SELECT coalesce(lex.d_slug, sem.d_slug) AS f_slug,
               ((coalesce(1.0/(v_k + lex.rank), 0)
               + coalesce(1.0/(v_k + sem.rank), 0))
               * stewards.recall_boost(d.use_count, d.last_used_at, v_freq_w, v_rec_w, v_half_life)
              )::real AS score
          FROM lex FULL JOIN sem ON lex.d_slug = sem.d_slug
          JOIN stewards.docs d ON d.slug = coalesce(lex.d_slug, sem.d_slug)
    ),
    direct AS (
        SELECT d.slug, d.kind, d.title, d.project_association,
               ts_headline('english', coalesce(d.body, ''),
                           websearch_to_tsquery('english', p_query),
                           'MaxWords=20, MinWords=10') AS snippet,
               f.score AS rank
          FROM fused f JOIN stewards.docs d ON d.slug = f.f_slug
         ORDER BY f.score DESC, d.slug
         LIMIT GREATEST(p_limit, 1)
    ),
    flr AS (SELECT min(direct.rank) AS f FROM direct),
    nbr AS (
        SELECT DISTINCT ON (sim.slug)
               sim.slug, dn.kind, dn.title, dn.project_association,
               ts_headline('english', coalesce(dn.body, ''),
                           websearch_to_tsquery('english', p_query),
                           'MaxWords=20, MinWords=10') AS snippet,
               ((SELECT f FROM flr) * 0.5 * sim.score)::real AS rank
          FROM direct d
          JOIN LATERAL stewards.doc_similar(d.slug, 5) sim ON true
          JOIN stewards.docs dn ON dn.slug = sim.slug
         WHERE p_expand
           AND sim.slug NOT IN (SELECT direct.slug FROM direct)
           AND (p_neighbors IS NULL OR dn.project_association = ANY(p_neighbors))
         ORDER BY sim.slug, sim.score DESC
    )
    SELECT u.* FROM (
        SELECT * FROM direct
        UNION ALL
        SELECT * FROM nbr
    ) u
     ORDER BY u.rank DESC NULLS LAST
     LIMIT CASE WHEN p_expand THEN GREATEST(p_limit, 1) * 2 ELSE GREATEST(p_limit, 1) END;
END $fn$;
COMMENT ON FUNCTION stewards.pool_search_hybrid(text, text[], int, boolean) IS
'72/93: project-scoped hybrid pool search — bare pool_search (FTS) fused with a semantic leg via real equal-weight RRF (k=60), scope applied to BOTH legs, then scaled by stewards.recall_boost. p_expand=true adds a 1-hop SIMILAR_TO graph-expand (kept inside the neighborhood). Degrades to FTS-only with no embed provider. STABLE / no side effects — pool_search_recall is the wrapper that bumps usage.';


-- =====================================================================
-- §5 — search_engrams_hybrid: same treatment over engram_embeddings.
-- LANGUAGE sql (not plpgsql) — no OUT-parameter/bare-identifier ambiguity,
-- so config is read via a small `cfg` CTE cross-joined once instead of
-- plpgsql DECLARE locals.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.search_engrams_hybrid(
    p_query_text          text,
    p_query_embedding     vector  DEFAULT NULL,
    p_session_id          text    DEFAULT NULL,
    p_project_association  text    DEFAULT NULL,
    p_limit               int     DEFAULT 10,
    p_expand              boolean DEFAULT false
) RETURNS TABLE (
    id text, message_id bigint, engram_id text, tier text, topic text,
    content_preview text, session_id text, project_association text, score real
)
LANGUAGE sql STABLE AS $fn$
    WITH cfg AS (
        SELECT stewards.config_get_text('recall.freq_weight', '0.2')::double precision AS freq_w,
               stewards.config_get_text('recall.recency_weight', '0.4')::double precision AS rec_w,
               stewards.config_get_text('recall.recency_half_life_days', '30')::double precision AS half_life
    ),
    lex AS (
        SELECT e.id,
               ROW_NUMBER() OVER (ORDER BY ts_rank(e.engram_fts, q) DESC, e.id) AS rank
          FROM stewards.engram_embeddings e,
               websearch_to_tsquery('english', p_query_text) q
         WHERE e.engram_fts @@ q
           AND (p_session_id IS NULL OR e.session_id = p_session_id)
           AND (p_project_association IS NULL OR e.project_association = p_project_association)
         ORDER BY ts_rank(e.engram_fts, q) DESC, e.id
         LIMIT p_limit * 3
    ),
    sem AS (
        SELECT e.id,
               ROW_NUMBER() OVER (ORDER BY e.embedding <=> p_query_embedding) AS rank
          FROM stewards.engram_embeddings e
         WHERE p_query_embedding IS NOT NULL AND e.embedding IS NOT NULL
           AND (p_session_id IS NULL OR e.session_id = p_session_id)
           AND (p_project_association IS NULL OR e.project_association = p_project_association)
         ORDER BY e.embedding <=> p_query_embedding
         LIMIT p_limit * 3
    ),
    fused AS (
        SELECT coalesce(lex.id, sem.id) AS eid,
               ((coalesce(1.0/(60 + lex.rank), 0)
               + coalesce(1.0/(60 + sem.rank), 0))
               * stewards.recall_boost(e.use_count, e.last_used_at, cfg.freq_w, cfg.rec_w, cfg.half_life)
              )::real AS score
          FROM lex FULL JOIN sem ON lex.id = sem.id
          JOIN stewards.engram_embeddings e ON e.id = coalesce(lex.id, sem.id)
          CROSS JOIN cfg
    ),
    direct AS (
        SELECT e.id, e.message_id, e.engram_id, e.tier, e.topic, e.content_preview,
               e.session_id, e.project_association, f.score AS score
          FROM fused f JOIN stewards.engram_embeddings e ON e.id = f.eid
         ORDER BY f.score DESC, e.id
         LIMIT GREATEST(p_limit, 1)
    ),
    flr AS (SELECT min(score) AS f FROM direct),
    nbr AS (
        SELECT DISTINCT ON (s.id)
               s.id, s.message_id, s.engram_id, s.tier, s.topic, s.content_preview,
               s.session_id, s.project_association,
               ((SELECT f FROM flr) * 0.5)::real AS score
          FROM direct d
          JOIN stewards.engram_embeddings s
            ON s.message_id = d.message_id AND s.id <> d.id
         WHERE p_expand
           AND s.id NOT IN (SELECT id FROM direct)
         ORDER BY s.id
    )
    SELECT * FROM direct
    UNION ALL
    SELECT * FROM nbr
     ORDER BY score DESC NULLS LAST
     LIMIT CASE WHEN p_expand THEN GREATEST(p_limit, 1) * 2 ELSE GREATEST(p_limit, 1) END;
$fn$;
COMMENT ON FUNCTION stewards.search_engrams_hybrid(text, vector, text, text, int, boolean) IS
'72/93: hybrid engram search — the engram_fts lexical leg fused with the embedding cosine leg via real equal-weight RRF (k=60), then scaled by stewards.recall_boost. Additive over search_engrams_by_vector. p_expand=true pulls same-message sibling engrams. STABLE / no side effects — search_engrams_recall is the wrapper that bumps usage.';


-- =====================================================================
-- §6 — the `*_recall` wrappers: call the pure hybrid fn ONCE (a
-- MATERIALIZED CTE — these do a real embed_query round-trip, so force
-- single evaluation regardless of planner CTE-inlining heuristics), then
-- bump last_used_at/use_count on exactly the rows returned via a second,
-- writable CTE over that SAME materialized set. VOLATILE by construction
-- (they UPDATE) — the hybrid fns above stay STABLE and side-effect-free.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.doc_search_recall(
    p_query  text,
    p_kinds  text[]  DEFAULT ARRAY[]::text[],
    p_limit  int     DEFAULT 10,
    p_expand boolean DEFAULT false
) RETURNS TABLE (slug text, kind text, title text, snippet text, rank real)
LANGUAGE sql AS $fn$
    WITH hits AS MATERIALIZED (
        SELECT * FROM stewards.doc_search_hybrid(p_query, p_kinds, p_limit, p_expand)
    ),
    bump AS (
        UPDATE stewards.docs d
           SET use_count    = d.use_count + 1,
               last_used_at = now()
          FROM hits h
         WHERE d.slug = h.slug
        RETURNING d.slug
    )
    SELECT h.slug, h.kind, h.title, h.snippet, h.rank FROM hits h;
$fn$;
COMMENT ON FUNCTION stewards.doc_search_recall(text, text[], int, boolean) IS
'93: doc_search_hybrid + a side effect — bumps last_used_at/use_count on every row actually returned (one MATERIALIZED evaluation of the hybrid fn, then a writable CTE UPDATE joined back to it). This is the surface doc_search_tool and the stewards-ui search page call; doc_search_hybrid itself stays STABLE/pure for callers that want no side effects.';

CREATE OR REPLACE FUNCTION stewards.pool_search_recall(
    p_query     text,
    p_neighbors text[]  DEFAULT NULL,
    p_limit     int     DEFAULT 10,
    p_expand    boolean DEFAULT false
) RETURNS TABLE (slug text, kind text, title text, project_association text, snippet text, rank real)
LANGUAGE sql AS $fn$
    WITH hits AS MATERIALIZED (
        SELECT * FROM stewards.pool_search_hybrid(p_query, p_neighbors, p_limit, p_expand)
    ),
    bump AS (
        UPDATE stewards.docs d
           SET use_count    = d.use_count + 1,
               last_used_at = now()
          FROM hits h
         WHERE d.slug = h.slug
        RETURNING d.slug
    )
    SELECT h.slug, h.kind, h.title, h.project_association, h.snippet, h.rank FROM hits h;
$fn$;
COMMENT ON FUNCTION stewards.pool_search_recall(text, text[], int, boolean) IS
'93: pool_search_hybrid + the same bump-on-return side effect. This is the surface pool_search_tool calls.';

CREATE OR REPLACE FUNCTION stewards.search_engrams_recall(
    p_query_text          text,
    p_query_embedding     vector  DEFAULT NULL,
    p_session_id          text    DEFAULT NULL,
    p_project_association  text    DEFAULT NULL,
    p_limit               int     DEFAULT 10,
    p_expand              boolean DEFAULT false
) RETURNS TABLE (
    id text, message_id bigint, engram_id text, tier text, topic text,
    content_preview text, session_id text, project_association text, score real
)
LANGUAGE sql AS $fn$
    WITH hits AS MATERIALIZED (
        SELECT * FROM stewards.search_engrams_hybrid(
            p_query_text, p_query_embedding, p_session_id, p_project_association, p_limit, p_expand)
    ),
    bump AS (
        UPDATE stewards.engram_embeddings e
           SET use_count    = e.use_count + 1,
               last_used_at = now()
          FROM hits h
         WHERE e.id = h.id
        RETURNING e.id
    )
    SELECT h.id, h.message_id, h.engram_id, h.tier, h.topic, h.content_preview,
           h.session_id, h.project_association, h.score
      FROM hits h;
$fn$;
COMMENT ON FUNCTION stewards.search_engrams_recall(text, vector, text, text, int, boolean) IS
'93: search_engrams_hybrid + the same bump-on-return side effect. This is the surface engram_search_tool calls.';


-- =====================================================================
-- §7 — repoint the three AGENT-FACING tool wrappers at the `*_recall`
-- variants, so real agent usage feeds the boost. Each loses its STABLE
-- marker (they now UPDATE); everything else about their envelopes/args is
-- unchanged.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.doc_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.doc_search_recall(
        p_args->>'query',
        coalesce(
            (SELECT array_agg(value::text)
               FROM jsonb_array_elements_text(coalesce(p_args->'kinds', '[]'::jsonb)) AS value),
            ARRAY[]::text[]
        ),
        coalesce((p_args->>'limit')::int, 10),
        coalesce((p_args->>'expand')::boolean, false)
    ) t;
$func$;

CREATE OR REPLACE FUNCTION stewards.pool_search_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess      text := p_args->>'_session_id';
    v_query     text := p_args->>'query';
    v_limit     int  := COALESCE(NULLIF(p_args->>'limit','')::int, 10);
    v_expand    boolean := COALESCE((p_args->>'expand')::boolean, false);
    v_project   text;
    v_neighbors text[];
    v_rows      jsonb;
BEGIN
    IF v_query IS NULL OR btrim(v_query) = '' THEN RETURN '{"error":"query required"}'; END IF;
    SELECT w.project_association INTO v_project
      FROM stewards.work_items w
     WHERE v_sess = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1;
    IF v_project IS NULL THEN v_project := p_args->>'project'; END IF;  -- fallback for direct callers
    v_neighbors := stewards.project_neighbors(v_project);

    SELECT jsonb_agg(jsonb_build_object('slug', slug, 'kind', kind, 'title', title,
                                        'project', project_association, 'snippet', snippet) ORDER BY rank DESC)
      INTO v_rows
      FROM stewards.pool_search_recall(v_query, v_neighbors, v_limit, v_expand);

    RETURN jsonb_build_object('project', v_project, 'neighborhood', v_neighbors,
        'results', COALESCE(v_rows, '[]'::jsonb),
        'note', CASE WHEN v_neighbors IS NULL
                     THEN 'no project scope — searched the whole pool (meta).'
                     ELSE 'scoped to this project''s neighborhood; other projects are walled off.' END)::text;
END $FN$;

CREATE OR REPLACE FUNCTION stewards.engram_search_tool(p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql AS $func$
DECLARE
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_result   jsonb;
BEGIN
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    BEGIN
        v_vec := stewards.embed_query(p_args->>'query', v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;   -- no embed provider / down: FTS-only
    END;

    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      INTO v_result
      FROM (
        SELECT h.message_id, h.engram_id, h.tier, h.topic, h.content_preview,
               h.session_id, h.project_association, h.score AS rank
          FROM stewards.search_engrams_recall(
                   p_args->>'query',
                   v_vec,
                   NULL,   -- p_session_id: substrate-wide
                   NULL,   -- p_project_association: substrate-wide
                   coalesce((p_args->>'limit')::int, 10),
                   coalesce((p_args->>'expand')::boolean, false)
               ) h
      ) t;
    RETURN v_result;
END $func$;
-- ===== [was 94-wiki-curator.sql] =====
-- =====================================================================
-- 94-wiki-curator.sql — the wiki-curator pipelines (info-dump -> auto-
-- organize; entities -> a fanned-out per-entity wiki).
-- =====================================================================
-- Michael's 5am vision (.spec/proposals/lab-and-wiki.md Part 2): dumping
-- knowledge in should cost NOTHING at write time; the substrate organizes
-- it. Two shapes, both LLM-wiki-flavored (study/yt/hQvwMj7IJe4-fable-
-- karpathy-llm-wiki.md names the flat-vs-nested heuristic and why page-
-- identity governance matters — not present in this worktree at authoring
-- time; the heuristic is applied directly from the mission brief below).
--
--   (a) wiki-organize — an existing source-doc set becomes wiki pages.
--       gather -> propose -> apply. apply is DETERMINISTIC (mirrors
--       apply_agent_proposal's shape, 13-research-pipelines): lightning-
--       tier dedup (similarity >= 0.90) auto-supersedes in place; mountain-
--       tier creates the new page AND queues a human merge review via the
--       Hinge (39-hinge) rather than silently multiplying near-duplicates.
--
--   (b) wiki-collect — "go fetch all the ponies in Equestria, then fan out
--       to their cutie marks / powers, then run research against that
--       subset." plan (LLM: entities + shared facet template) -> fan-out
--       (the EXISTING spawn_children machinery, 14-fanout-brainstorm,
--       reused byte-for-byte — not redefined) -> aggregate (the existing
--       generic aggregate-children pipeline, bridged into a real wiki page
--       by an additive trigger below).
--
-- ★ INTEGRATION POINT — WIKI-CORE (92-wiki-core.sql) is NOT present in this
-- worktree (parallel builder, 6-builder wiki fleet). WIKI-CORE owns:
--
--   TABLES   stewards.wikis        (slug PK, title, kind, scope, ...)
--            stewards.wiki_pages   (slug PK, title, content, ...)
--            stewards.wiki_members (wiki_slug, page_slug)
--            stewards.page_sources (page_slug, doc_slug, ...)
--
--   FUNCTIONS  wiki_create(p_slug, p_title, p_kind, p_scope)
--              wiki_page_upsert(p_slug, p_title, p_content, p_sources jsonb)
--              wiki_add_member(p_wiki_slug, p_page_slug)
--              wiki_page_dedup_check(p_wiki_slug, p_title, p_content)
--                RETURNS TABLE(candidate_slug text, similarity real)
--              wiki_merge_propose(p_from_slug, p_to_slug, p_rationale)
--
-- Every call into these (below) is a plain function call inside a plpgsql
-- body — Postgres does not validate a referenced object's existence until
-- the statement actually EXECUTES, so this file CREATEs cleanly against a
-- 00-91-only chain (verified: `docker build` + a scratch install below
-- succeed with 92 absent) and will start WORKING the moment 92 lands,
-- with zero changes to this file. This is the same forward-ref discipline
-- 08-gates.sql already relies on for its 10/13/14 callees (see that
-- file's header). Call sites that assume a specific 92 return SHAPE are
-- marked "-- INTEGRATION POINT" so a signature mismatch is easy to find.
--
-- What IS mine to own outright (not 92's): the wiki-as-lens seam
-- (wiki_search — restricts a search to one wiki's member pages' source
-- docs) and the glue that makes wiki-collect's fan-out land as a real
-- wiki page without touching core (08-gates.sql, 14-fanout-brainstorm.sql)
-- at all:
--
--   * spawn_children (14) is reused UNMODIFIED. Its trigger path
--     (on_maturity_verified, 08) only fires it for pipeline_family=
--     'decompose-fanout' — hardcoded, and rightly so (it is not this
--     file's place to make that dispatcher generic for every future
--     fan-out consumer). So wiki_collect_spawn() below does what
--     start_brainstorm (14) already does for the brainstorm lenses:
--     write a decompose-shaped manifest directly onto stage_results.
--     decompose.output and call stewards.spawn_children(...) directly.
--     spawn_children itself has NO pipeline_family gate — only the
--     TRIGGER does — so this is a legitimate, unmodified reuse of the
--     exact same public entry point start_brainstorm uses.
--   * The aggregator spawn_children creates is ALWAYS pipeline_family=
--     'aggregate-children' (hardcoded in spawn_children) running the
--     generic fanout-aggregate agent, which has no idea wiki_page_upsert
--     exists. Rather than fork spawn_children or re-author the shared
--     'aggregate-children' pipeline (both would ripple across every OTHER
--     fan-out consumer in the fleet/codebase), wiki_collect_aggregate_
--     bridge() is a NEW, narrowly-scoped additive trigger (same pattern
--     25-corpus.sql already uses for work_items_fill_project: a SEPARATE
--     trigger object, not a re-author of an existing one) that recognizes
--     ITS OWN aggregator runs (file_destination matches wikis/<slug>/
--     index.md, a path only wiki_collect_spawn ever sets) and turns the
--     generic markdown output into a real wiki_page + membership.
--
-- Bounded per 16-subagents "as-is": the width/depth caps already enforced
-- by trigger_enforce_subagent_depth are NOT reimplemented here. wiki-
-- collect's fan-out parent gets its OWN per-pipeline override row (the
-- exact mechanism decompose-fanout already uses — 'subagent_max_children.
-- <pipeline_family>' — just a new DATA row, not a new mechanism), sized
-- for a ~24-entity worklist + 1 aggregator slot. wiki_collect_spawn()
-- reads the EFFECTIVE cap at spawn time (not a hardcoded 24) and reports
-- any entities beyond it as "overflow" on the wiki's index page rather
-- than raising past the trigger's hard stop.
-- requires create_core_compat (91) — installs at the tail of the core
-- chain. When 92-wiki-core lands, this file's `requires` in src/lib.rs
-- should move to depend on it directly (currently points at 91 because
-- 92/93 are not in this worktree — flagged for the fleet integration).
-- =====================================================================

-- ---------------------------------------------------------------------
-- SECTION 0 — config knobs.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('wiki_dedup_mountain_floor', '0.55',
   'wiki-organize/wiki-collect dedup tier floor: similarity in [floor, 0.90) is "mountain" (create + flag for human merge review via the Hinge); below floor is a plain new page; >=0.90 is "lightning" (auto-supersede the matched page).'),
  ('subagent_max_children.wiki-collect', '25',
   'wiki-collect fans out to at most ~24 entities + 1 aggregator (25 total children under the parent). Same knob decompose-fanout already uses (16-subagents); this is a new DATA row for a new pipeline, not a new mechanism.')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- =====================================================================
-- SECTION 1 — the wiki-as-lens seam (mine to own; the ONE new tool
-- this file introduces, alongside the two pipeline-entry-point tools).
--
-- The research pipelines already reach for a corpus/project lens via
-- pool_search_tool (72-hybrid-rrf-everywhere): it derives a project from
-- the caller's session -> work_item.project_association, then scopes to
-- stewards.project_neighbors(project). The chat UI's "empty-chat lens
-- picker" (rich-docs P3d, cmd/stewards-ui/api/chat.go) is the same idea
-- one layer up: a "project:<name>" TargetRef grounds a whole conversation
-- in a corpus via a prompt instruction that tells the agent to doc_search
-- within it.
--
-- wiki_search is the SAME shape, scoped to a wiki instead of a project:
-- restrict to the doc_slugs that are page_sources of a wiki's member
-- pages. This is additive — it does NOT touch pool_search_tool/
-- doc_search_tool (owned by 71/72, shared by every other pipeline in the
-- fleet); it is a wholly new, narrow function + tool_def + tool_group.
-- =====================================================================

-- ── wiki_scope_doc_slugs — the doc set a wiki's gather stage may see.
-- Reconciled at fleet integration to 92's REAL shape: the junction tables
-- are id-keyed (wikis.id/wiki_pages.id uuids), page_sources carries doc_id
-- (= stewards.docs.id, text), and the slug every tool surface speaks lives
-- on docs.slug — so the walk is wikis→wiki_members→page_sources→docs.
CREATE OR REPLACE FUNCTION stewards.wiki_scope_doc_slugs(p_wiki_slug text)
RETURNS TABLE (doc_slug text)
LANGUAGE sql STABLE AS $fn$
    SELECT DISTINCT d.slug
      FROM stewards.wikis w
      JOIN stewards.wiki_members wm ON wm.wiki_id = w.id
      JOIN stewards.page_sources ps ON ps.page_id = wm.page_id
      JOIN stewards.docs d          ON d.id = ps.doc_id
     WHERE w.slug = p_wiki_slug
       AND ps.doc_id IS NOT NULL;
$fn$;
COMMENT ON FUNCTION stewards.wiki_scope_doc_slugs(text) IS
'94-wiki-curator: the doc slugs in scope for a wiki lens — every doc that is a page_source of one of the wiki''s member pages. INTEGRATION POINT: assumes 92-wiki-core''s wiki_members/page_sources shape.';

-- ── wiki_search — doc_search's FTS shape, restricted to one wiki's scope.
CREATE OR REPLACE FUNCTION stewards.wiki_search(
    p_wiki_slug text,
    p_query     text,
    p_limit     int DEFAULT 10
) RETURNS TABLE (slug text, kind text, title text, snippet text, rank real)
LANGUAGE sql STABLE AS $fn$
    SELECT d.slug, d.kind, d.title,
           ts_headline('english', coalesce(d.body, ''), q,
                       'MaxWords=20, MinWords=10, ShortWord=3') AS snippet,
           ts_rank(d.body_tsv, q) AS rank
      FROM stewards.docs d,
           websearch_to_tsquery('english', p_query) q
     WHERE d.body_tsv @@ q
       AND d.slug IN (SELECT doc_slug FROM stewards.wiki_scope_doc_slugs(p_wiki_slug))
     ORDER BY rank DESC
     LIMIT greatest(p_limit, 1);
$fn$;
COMMENT ON FUNCTION stewards.wiki_search(text, text, int) IS
'94-wiki-curator: the wiki lens — FTS over stewards.docs restricted to doc_slugs sourced by wiki_slug''s member pages. The wiki-scoped sibling of doc_search/pool_search (project lens).';

CREATE OR REPLACE FUNCTION stewards.wiki_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $FN$
DECLARE
    v_sess      text := p_args->>'_session_id';
    v_wiki_slug text;
    v_query     text := p_args->>'query';
    v_limit     int  := COALESCE(NULLIF(p_args->>'limit','')::int, 10);
    v_rows      jsonb;
BEGIN
    IF v_query IS NULL OR btrim(v_query) = '' THEN
        RETURN '{"error":"query required"}'::jsonb;
    END IF;

    -- Session-derived wiki scope first (mirrors pool_search_tool's project
    -- resolution), explicit arg as the fallback for direct/tool callers.
    SELECT w.input->>'wiki_slug' INTO v_wiki_slug
      FROM stewards.work_items w WHERE v_sess = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1;
    IF v_wiki_slug IS NULL THEN v_wiki_slug := p_args->>'wiki_slug'; END IF;
    IF v_wiki_slug IS NULL OR btrim(v_wiki_slug) = '' THEN
        RETURN '{"error":"wiki_slug required (no session-scoped wiki and none passed explicitly)"}'::jsonb;
    END IF;

    BEGIN
        SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_rows
          FROM stewards.wiki_search(v_wiki_slug, v_query, v_limit) t;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'wiki_search_tool: query failed (likely 92-wiki-core not yet installed): %', SQLERRM;
        RETURN jsonb_build_object('error', 'wiki search unavailable', 'detail', SQLERRM);
    END;

    RETURN jsonb_build_object('wiki_slug', v_wiki_slug, 'results', v_rows);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'wiki_search',
  'Search restricted to ONE wiki''s scope: only docs that are sources of that wiki''s member pages. The wiki-scoped sibling of doc_search/pool_search — use this when your stage''s scope names a wiki (scope.kind=''wiki'') instead of a project. Args: query (required), wiki_slug (optional if your session is already scoped to one wiki), limit.',
  '{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"wiki_slug":{"type":"string"},"limit":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_search_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- ── wiki-tools group — bundles the wiki_search lens (mine) with the
-- wiki-core verb names (92's, referenced by pattern only — an unmatched
-- pattern in a tool_group just contributes nothing, per resolve_tool_scope's
-- fail-open contract, 37-tool-groups).
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('wiki-tools', 'the wiki surface: search a wiki''s scope, create/upsert pages, add members, dedup-check, propose merges',
     ARRAY['wiki_search','wiki_create','wiki_page_upsert','wiki_add_member','wiki_page_dedup_check','wiki_merge_propose'])
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, tool_patterns=EXCLUDED.tool_patterns;

-- =====================================================================
-- SECTION 2 — agents. Deny-by-default holds (schema.rs agent_tool_perms):
-- each family below gets EXACTLY the tools its stage needs, nothing more.
-- =====================================================================

-- ── wiki-curator — the reading/reasoning/proposing persona. Used by
-- wiki-organize's gather+propose stages and wiki-collect's plan stage.
-- Never writes a page itself (apply/spawn are deterministic SQL below);
-- it reads, searches, and — for propose — is REQUIRED to call
-- wiki_page_dedup_check before finalizing any page proposal.
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES (
  'wiki-curator', '*',
  'Reads a source-doc set (or an entity/facet question) and organizes it: proposes wiki pages with provenance, checks for duplicates before proposing, and names the page-space shape (flat vs nested). Never writes a page directly — a deterministic apply step does that.',
  'primary',
  $PROMPT$You are the Wiki Curator. You turn scattered source material into a clean, browsable wiki, and you turn broad questions ("go fetch all the X, then look at their Y") into a scoped worklist someone else can research in parallel.

Principles:
- Provenance-first. Every page section traces to a source you actually read this session. Quote text VERBATIM only when you have the source in front of you; paraphrase otherwise — "X reports that..." is honest, an unverified direct quote is not. No unsourced claims.
- Concise over exhaustive. A tight page that gets read beats a sprawling one that doesn't. Merge closely related material into ONE page rather than one page per source if they cover the same topic.
- Dedup before you propose. Call wiki_page_dedup_check on every candidate page before finalizing it — a near-duplicate should supersede or flag for merge, not multiply silently.
- Flat when uniform, nested when heterogeneous. If the material is all one kind of thing, use a flat slug space. If it's a genuine mix of categories, prefix slugs by category so the wiki reads as sections, not one flat pile. Match the page-space shape to the material's actual structure; don't force a convention that isn't there.

You are one stage in a multi-stage pipeline. Do your stage's job, follow its output format and tool budget exactly, and hand off cleanly — do not perform the NEXT stage's job (you may search and reason; you do not upsert pages yourself unless your specific stage instructions say so).$PROMPT$,
  0.4
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, prompt = EXCLUDED.prompt, temperature = EXCLUDED.temperature, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator', 'fs_read',               'allow'),
  ('wiki-curator', 'fs_list',               'allow'),
  ('wiki-curator', 'fs_search',             'allow'),
  ('wiki-curator', 'doc_search',            'allow'),
  ('wiki-curator', 'doc_get',               'allow'),
  ('wiki-curator', 'doc_similar',           'allow'),
  ('wiki-curator', 'pool_search',           'allow'),
  ('wiki-curator', 'wiki_search',           'allow'),
  ('wiki-curator', 'wiki_page_dedup_check', 'allow'),
  ('wiki-curator', 'work_item_list',        'allow'),
  ('wiki-curator', 'work_item_show',        'allow'),
  -- discovery: plan needs to actually find the entity set for "go fetch
  -- all the X" style questions.
  ('wiki-curator', 'web_search_exa',        'allow'),
  ('wiki-curator', 'fetch_url',             'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ── wiki-curator-entity — the leaf researcher-writer. One child per
-- entity in wiki-collect's fan-out. Does its own research AND its own
-- writing; does not re-delegate (subagent-leaf discipline, 16-subagents).
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES (
  'wiki-curator-entity', '*',
  'Researches ONE entity from a wiki-collect worklist and writes ONE page for it. A leaf worker in a fan-out — does not re-delegate.',
  'primary',
  $PROMPT$You are a Wiki Curator researching ONE entity to add to a wiki. You are a leaf worker in a fan-out: sibling workers are each researching a different entity from the same worklist, in parallel.

Your job, in order:
1. Research your assigned entity with your tools (web_search_exa, fetch_url, doc_search, pool_search, wiki_search).
2. Before writing, call wiki_page_dedup_check to see if this entity already has a page in this wiki.
   - similarity >= 0.90: this is the SAME entity already documented. Read the existing page and UPDATE it with anything new you found (still via wiki_page_upsert, same slug) rather than creating a duplicate.
   - otherwise: proceed to create a new page.
3. Call wiki_page_upsert(slug, title, content, sources). Content is PROVENANCE-FIRST — every claim traces to a source you actually read this session. Quote VERBATIM only when the source text is in front of you; paraphrase otherwise ("X reports that..." is honest, an unverified direct quote is not). Concise over exhaustive. If your search turns up nothing credible, say so plainly in the page rather than inventing detail.
4. Call wiki_add_member(wiki_slug, slug) so the page joins the wiki.

You do not re-delegate — do your own research and writing directly. End your turn once wiki_page_upsert and wiki_add_member have both succeeded; your final message is one line confirming what you wrote and its slug.$PROMPT$,
  0.5
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, prompt = EXCLUDED.prompt, temperature = EXCLUDED.temperature, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator-entity', 'web_search_exa',        'allow'),
  ('wiki-curator-entity', 'fetch_url',             'allow'),
  ('wiki-curator-entity', 'doc_search',            'allow'),
  ('wiki-curator-entity', 'doc_get',                'allow'),
  ('wiki-curator-entity', 'pool_search',           'allow'),
  ('wiki-curator-entity', 'wiki_search',           'allow'),
  ('wiki-curator-entity', 'wiki_page_dedup_check', 'allow'),
  ('wiki-curator-entity', 'wiki_page_upsert',      'allow'),
  ('wiki-curator-entity', 'wiki_add_member',       'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- SECTION 3 — wiki-organize pipeline: gather -> propose -> (apply,
-- deterministic, fires on propose's maturity->verified via the additive
-- trigger below — NOT a pipeline stage; mirrors apply_agent_proposal's
-- shape, 13-research-pipelines).
--
-- input shape: {"scope": {"kind": "project"|"wiki"|"all", "value": text
-- or null}, "wiki_slug": text}. scope is the LENS the gather stage reads
-- FROM; wiki_slug is the DESTINATION wiki pages get organized INTO (often
-- the same wiki as scope.value when re-organizing a wiki's own docs, but
-- may differ — e.g. organizing a project's docs into a brand-new wiki).
-- =====================================================================
DO $seed$
DECLARE
    v_gather_template  text;
    v_propose_template text;
    v_stages           jsonb;
BEGIN

v_gather_template :=
$T$Scope: {{input.scope}}
Destination wiki: {{input.wiki_slug}}

## YOUR TASK — gather the source doc set for this scope

Gather the FULL set of source documents in scope so the next stage (propose) can decide how to organize them into wiki pages.

- If scope.kind = "wiki": call wiki_search (wiki_slug = scope.value) to list every doc that's already a source for that wiki's member pages, PLUS doc_search/pool_search for anything newly relevant that isn't in the wiki yet.
- If scope.kind = "project": use pool_search (already scoped to your project neighborhood by the session).
- If scope.kind = "all": use doc_search broadly.

For each doc kept, record: slug, kind, title, one-line summary of what it covers.

## HARD CONSTRAINTS

- Maximum 5 rounds of tool calls.
- Output budget ~2KB — list slugs + summaries, don't transcribe bodies.
- End-of-turn: your final message is the doc-set briefing in markdown, then STOP.

If the scope turns up nothing, say so explicitly — the propose stage will know there's nothing to organize yet.$T$;

v_propose_template :=
$T$Scope: {{input.scope}}
Destination wiki: {{input.wiki_slug}}

## SOURCE DOC SET (from gather stage)

{{stage_results.gather.output}}

## YOUR TASK — propose wiki pages

Organize the source docs above into a set of wiki page proposals. For EACH proposed page:

1. Decide its slug + title + a concise, provenance-first summary (every claim traces to a doc_slug above; quote VERBATIM only when you have the source text in front of you this session — paraphrase otherwise; NO unsourced claims).
2. Call wiki_page_dedup_check(title, summary) BEFORE finalizing the proposal. This call is REQUIRED for every single proposal, not optional — record what it returned (existing_slug + similarity) in the proposal's dedup_checked field even when it finds nothing (similarity 0 / existing_slug null IS a result).
3. Decide flat-vs-nested for the WHOLE proposal set: if the doc set is UNIFORM (all one kind of thing), use a flat slug space; if HETEROGENEOUS (several distinct categories), prefix slugs by category/ so the wiki reads as sections, not one flat pile.

## OUTPUT — JSON ONLY, no prose, no fences

```json
{
  "page_prefix_style": "flat" | "nested",
  "proposals": [
    {
      "slug": "kebab-case, category-prefixed if nested",
      "title": "...",
      "summary": "the page body -- concise, provenance-first markdown",
      "source_doc_slugs": ["..."],
      "dedup_checked": {"candidate_slug": null-or-a-slug, "similarity": 0.0}
    }
  ]
}
```

## HARD CONSTRAINTS

- Concise pages over exhaustive ones — merge closely related docs into ONE page rather than one page per doc if they cover the same topic.
- Every proposal MUST show a wiki_page_dedup_check call result.
- Output ONLY the JSON object.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object(
        'name', 'gather', 'next', 'propose',
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'wiki-curator', 'auto_advance', true,
        'tools_disabled', false, 'tool_groups', jsonb_build_array('substrate-read','wiki-tools'),
        'input_template', v_gather_template
    ),
    jsonb_build_object(
        'name', 'propose', 'next', NULL,
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'wiki-curator', 'auto_advance', true,
        'tools_disabled', false, 'tool_groups', jsonb_build_array('wiki-tools'),
        'input_template', v_propose_template
    )
);

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'wiki-organize',
    'Info-dump -> auto-organize. gather pulls the source doc set for a scope (project/wiki/all lens); propose organizes it into page proposals + REQUIRED dedup_check calls; apply (deterministic, fires on propose''s maturity->verified via an additive trigger, NOT a pipeline stage) writes pages: lightning tier (similarity>=0.90) auto-supersedes, mountain tier creates + queues a human merge review via the Hinge, no match creates plainly. No file artifact -- the wiki pages ARE the artifact.',
    v_stages,
    false,  -- sabbath_enabled: mechanical dedup+apply, not a creative artifact
    false,  -- atonement_enabled
    NULL,   -- file_destination_template: no file; pages land in wiki_pages
    NULL,
    '["raw","researched","verified"]'::jsonb,
    false   -- auto_materialize_on_verified: apply writes pages directly, no file
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
    file_destination_template = EXCLUDED.file_destination_template,
    file_content_jsonpath = EXCLUDED.file_content_jsonpath,
    maturity_ladder = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('wiki-organize', 'gather',  'researched', 'Source doc set gathered; ready for organizing.'),
    ('wiki-organize', 'propose', 'verified',   'Proposals + dedup_check results complete; fires wiki_organize_apply (deterministic).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('wiki-organize', 'gather',  'kimi-k2.6', 'Doc-set gather; tools enabled (wiki-tools + substrate-read).'),
    ('wiki-organize', 'propose', 'kimi-k2.6', 'Page proposals + required dedup_check calls; tools enabled (wiki-tools).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

END $seed$;

-- ---------------------------------------------------------------------
-- wiki_organize_apply — the deterministic apply. Fires on wiki-organize's
-- propose stage reaching maturity=verified (additive trigger below).
-- Mirrors apply_agent_proposal's role (13-research-pipelines): the LLM
-- proposes structured JSON; a DETERMINISTIC function decides the branch.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.wiki_organize_apply(p_work_item_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_wiki_slug      text;
    v_proposals_raw  jsonb;
    v_proposals      jsonb;
    v_prop           jsonb;
    v_slug           text;
    v_title          text;
    v_content        text;
    v_sources        jsonb;
    v_dedup_slug     text;
    v_dedup_sim      real;
    v_tier           text;
    v_mountain_floor real;
    v_n_created      int := 0;
    v_n_superseded   int := 0;
    v_n_flagged      int := 0;
    v_n_skipped      int := 0;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'wiki_organize_apply: work_item % not found', p_work_item_id;
    END IF;

    v_wiki_slug := COALESCE(NULLIF(v_wi.input ->> 'wiki_slug', ''), v_wi.slug);
    v_mountain_floor := COALESCE(stewards.config_get_text('wiki_dedup_mountain_floor', NULL)::real, 0.55);

    v_proposals_raw := v_wi.stage_results -> 'propose' -> 'output';
    IF v_proposals_raw IS NULL THEN
        RAISE EXCEPTION 'wiki_organize_apply: no propose output on work_item %', p_work_item_id;
    END IF;
    IF jsonb_typeof(v_proposals_raw) = 'string' THEN
        BEGIN
            v_proposals_raw := (v_proposals_raw #>> '{}')::jsonb;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'wiki_organize_apply: propose output is not valid JSON: %', SQLERRM;
        END;
    END IF;

    IF jsonb_typeof(v_proposals_raw) = 'object' AND v_proposals_raw ? 'proposals' THEN
        v_proposals := v_proposals_raw -> 'proposals';
    ELSE
        v_proposals := v_proposals_raw;
    END IF;

    IF v_proposals IS NULL OR jsonb_typeof(v_proposals) <> 'array' THEN
        RAISE EXCEPTION 'wiki_organize_apply: propose output has no proposals array';
    END IF;

    -- Ensure the destination wiki exists (wiki_create is idempotent per
    -- the mission's description of it).
    BEGIN
        PERFORM stewards.wiki_create(v_wiki_slug, initcap(replace(v_wiki_slug, '-', ' ')), 'organize', 'project');
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'wiki_organize_apply: wiki_create failed (likely 92-wiki-core not yet installed): %', SQLERRM;
    END;

    FOR v_prop IN SELECT * FROM jsonb_array_elements(v_proposals) LOOP
        v_slug    := v_prop ->> 'slug';
        v_title   := v_prop ->> 'title';
        v_content := v_prop ->> 'summary';
        v_sources := COALESCE(v_prop -> 'source_doc_slugs', '[]'::jsonb);

        IF v_slug IS NULL OR v_title IS NULL OR v_content IS NULL THEN
            RAISE NOTICE 'wiki_organize_apply: skipping malformed proposal (missing slug/title/summary): %', v_prop;
            v_n_skipped := v_n_skipped + 1;
            CONTINUE;
        END IF;

        v_dedup_slug := NULL;
        v_dedup_sim  := NULL;
        BEGIN
            -- Server-side safety net: re-run dedup_check even though propose
            -- was REQUIRED to call it — the LLM's echoed dedup_checked field
            -- is advisory; this authoritative branch decision is the real gate.
            -- 92's real shape (reconciled at fleet integration):
            -- wiki_page_dedup_check(p_title, p_content) RETURNS TABLE
            -- (is_duplicate boolean, existing_slug text, similarity real),
            -- single best-match row; page slugs are global, no wiki arg.
            SELECT existing_slug, similarity INTO v_dedup_slug, v_dedup_sim
              FROM stewards.wiki_page_dedup_check(v_title, v_content)
             LIMIT 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'wiki_organize_apply: wiki_page_dedup_check failed for % (likely 92-wiki-core not yet installed): %', v_slug, SQLERRM;
        END;

        v_tier := CASE
            WHEN v_dedup_sim IS NULL THEN 'none'
            WHEN v_dedup_sim >= 0.90 THEN 'lightning'
            WHEN v_dedup_sim >= v_mountain_floor THEN 'mountain'
            ELSE 'none'
        END;

        BEGIN
            IF v_tier = 'lightning' THEN
                -- Auto-supersede: write into the MATCHED existing slug, not a
                -- new one -- >=0.90 means "this is the same page."
                PERFORM stewards.wiki_page_upsert(COALESCE(v_dedup_slug, v_slug), v_title, v_content, v_sources);
                PERFORM stewards.wiki_add_member(v_wiki_slug, COALESCE(v_dedup_slug, v_slug));
                v_n_superseded := v_n_superseded + 1;
            ELSIF v_tier = 'mountain' THEN
                -- Create the new page (nothing is lost / blocked at write
                -- time -- Michael's stated design goal) AND flag it for a
                -- human merge review rather than silently growing a
                -- near-duplicate unchecked.
                PERFORM stewards.wiki_page_upsert(v_slug, v_title, v_content, v_sources);
                PERFORM stewards.wiki_add_member(v_wiki_slug, v_slug);
                PERFORM stewards.wiki_merge_propose(v_slug, v_dedup_slug,
                    format('wiki-organize proposed "%s" (similarity %.2f to existing "%s"); both now exist -- review whether they should merge.',
                           v_title, v_dedup_sim, v_dedup_slug));
                v_n_flagged := v_n_flagged + 1;
            ELSE
                PERFORM stewards.wiki_page_upsert(v_slug, v_title, v_content, v_sources);
                PERFORM stewards.wiki_add_member(v_wiki_slug, v_slug);
                v_n_created := v_n_created + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'wiki_organize_apply: apply failed for % (tier=%, likely 92-wiki-core not yet installed): %', v_slug, v_tier, SQLERRM;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'wiki_slug', v_wiki_slug,
        'created', v_n_created,
        'superseded', v_n_superseded,
        'flagged_for_merge_review', v_n_flagged,
        'skipped_malformed', v_n_skipped
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.wiki_organize_apply(uuid) IS
'94-wiki-curator: deterministic apply for the wiki-organize pipeline (mirrors apply_agent_proposal''s shape). Reads propose''s JSON proposals; per proposal, server-side re-runs wiki_page_dedup_check as the authoritative branch decision: lightning (>=0.90) supersedes in place, mountain ([floor,0.90)) creates + queues a Hinge merge review, none creates plainly. Fired by the additive trigger work_items_wiki_organize_apply, not a pipeline stage.';

-- ── the additive trigger — a SEPARATE trigger object from on_maturity_
-- verified (08-gates), scoped tightly to pipeline_family='wiki-organize'.
-- Precedent: 25-corpus.sql's work_items_fill_project does the same thing
-- (a new trigger rather than a re-author of a shared core function).
CREATE OR REPLACE FUNCTION stewards.wiki_organize_apply_trigger()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.pipeline_family = 'wiki-organize' THEN
        BEGIN
            PERFORM stewards.wiki_organize_apply(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'wiki_organize_apply_trigger: apply failed for work_item=%: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS work_items_wiki_organize_apply ON stewards.work_items;
CREATE TRIGGER work_items_wiki_organize_apply
    AFTER UPDATE OF maturity ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.maturity = 'verified' AND OLD.maturity IS DISTINCT FROM 'verified')
    EXECUTE FUNCTION stewards.wiki_organize_apply_trigger();

-- ── wiki_organize_start — the entry point (mirrors start_brainstorm's
-- role: the one call that kicks off a run). Registered as a tool so a
-- human or another agent can invoke it conversationally.
CREATE OR REPLACE FUNCTION stewards.wiki_organize_start(
    p_scope                jsonb,
    p_wiki_slug            text,
    p_actor                text DEFAULT 'human',
    p_project_association  text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_slug text;
    v_id   uuid;
BEGIN
    IF p_wiki_slug IS NULL OR btrim(p_wiki_slug) = '' THEN
        RAISE EXCEPTION 'wiki_organize_start: wiki_slug is required';
    END IF;
    v_slug := 'wiki-organize-' || p_wiki_slug || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS');

    v_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-organize',
        p_input           => jsonb_build_object(
            'binding_question', format('Organize the %s scope into wiki pages for "%s".',
                                        COALESCE(p_scope, '{"kind":"all"}'::jsonb), p_wiki_slug),
            'scope', COALESCE(p_scope, '{"kind":"all","value":null}'::jsonb),
            'wiki_slug', p_wiki_slug
        ),
        p_slug   => v_slug,
        p_actor  => COALESCE(p_actor, 'human')
    );
    UPDATE stewards.work_items
       SET project_association = p_project_association
     WHERE id = v_id;

    PERFORM stewards.work_item_dispatch_stage(v_id, NULL);
    RETURN v_id;
END;
$fn$;
COMMENT ON FUNCTION stewards.wiki_organize_start(jsonb, text, text, text) IS
'94-wiki-curator: entry point for wiki-organize (mirrors start_brainstorm''s role). scope = {"kind":"project"|"wiki"|"all","value":text-or-null} -- the lens the gather stage reads from. wiki_slug = the destination wiki pages get organized into.';

CREATE OR REPLACE FUNCTION stewards.wiki_organize_start_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_id uuid;
BEGIN
    v_id := stewards.wiki_organize_start(
        COALESCE(p_args->'scope', '{"kind":"all","value":null}'::jsonb),
        p_args->>'wiki_slug',
        COALESCE(p_args->>'actor', 'human'),
        p_args->>'project_association'
    );
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_id::text);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'wiki_organize_start',
  'Start a wiki-organize run: an existing source-doc set becomes wiki pages. Args: scope ({"kind":"project"|"wiki"|"all","value":text}), wiki_slug (the destination wiki), project_association (optional). Runs in the background; pages land via the deterministic apply step once propose completes.',
  '{"type":"object","required":["wiki_slug"],"properties":{"scope":{"type":"object"},"wiki_slug":{"type":"string"},"project_association":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_organize_start_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator', 'wiki_organize_start', 'allow'),
  ('research',     'wiki_organize_start', 'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- SECTION 4 — wiki-collect-entity: the leaf pipeline. One child per
-- entity, spawned by spawn_children (reused unmodified, see header).
-- Single stage; produces_maturity=verified directly (mirrors agent-
-- proposal's single-stage 'validate' shape, 13-research-pipelines).
-- =====================================================================
DO $seed$
DECLARE
    v_research_template text;
BEGIN

v_research_template :=
$T$Binding question: {{input.binding_question}}

You are researching ONE entity for the wiki: **{{input.entity_name}}**.

## YOUR TASK

1. Research this entity using your search tools (web_search_exa, fetch_url, doc_search, pool_search, wiki_search).
2. Call wiki_page_dedup_check first to see if this entity already has a page in this wiki.
   - similarity >= 0.90: same entity already documented -- read the existing page and UPDATE it (still via wiki_page_upsert, same slug) with anything new, rather than duplicating.
   - otherwise: proceed to create a new page.
3. Call wiki_page_upsert(slug, title, content, sources):
   - slug: kebab-case. If this wiki uses a nested/section slug space ({{input.page_prefix_style}}), prefix accordingly.
   - content: PROVENANCE-FIRST -- every claim traces to a source you actually read this session. Quote VERBATIM only when you have the source in front of you; paraphrase otherwise ("X reports that..." is honest; an unverified direct quote is not). Concise over exhaustive.
   - sources: the doc/URL references you drew from.
4. Call wiki_add_member(wiki_slug, slug) so the page joins this wiki.

## HARD CONSTRAINTS

- Maximum 6 rounds of tool calls.
- End your turn once wiki_page_upsert + wiki_add_member have both succeeded. Your final message: one line confirming what you wrote and its slug.

If your search turns up nothing credible on this entity, say so plainly in the page ("no credible source found for X") rather than inventing detail.$T$;

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'wiki-collect-entity',
    'The leaf pipeline for wiki-collect''s fan-out: one child per entity. Researches ONE entity and writes ONE wiki page (wiki_page_upsert + wiki_add_member), dedup-checked first. No file artifact -- the wiki page IS the artifact.',
    jsonb_build_array(
        jsonb_build_object(
            'name', 'research', 'next', NULL,
            'model', 'kimi-k2.6', 'provider', 'opencode_go',
            'agent_family', 'wiki-curator-entity', 'auto_advance', true,
            'tools_disabled', false, 'tool_groups', jsonb_build_array('web-research','wiki-tools'),
            'input_template', v_research_template
        )
    ),
    false, false, NULL, NULL,
    '["raw","verified"]'::jsonb,
    false
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
    file_destination_template = EXCLUDED.file_destination_template,
    file_content_jsonpath = EXCLUDED.file_content_jsonpath,
    maturity_ladder = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('wiki-collect-entity', 'research', 'verified', 'Single stage; page written + joined to the wiki.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('wiki-collect-entity', 'research', 'kimi-k2.6', 'One-entity research + write; tools enabled (web-research + wiki-tools).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

END $seed$;

-- =====================================================================
-- SECTION 5 — wiki-collect: plan -> fan-out (spawn_children, reused
-- unmodified) -> aggregate (the generic aggregate-children pipeline,
-- bridged into a real wiki page by an additive trigger).
--
-- input shape: {"question": text, "scope": {...same shape as wiki-
-- organize's...}, "wiki_slug": text}.
-- =====================================================================
DO $seed$
DECLARE
    v_plan_template text;
BEGIN

v_plan_template :=
$T$Question: {{input.question}}
Scope: {{input.scope}}
Wiki: {{input.wiki_slug}}

## YOUR TASK -- decompose into an entity/facet worklist

The question names or implies a SET of entities (e.g. "ponies in Equestria") and one or more FACETS to research per entity (e.g. "what cutie mark, what power it grants, evidence it's been used/saved/shared"). Your job:

1. Identify the entity set -- search if you need to (web_search_exa, fetch_url, doc_search, pool_search; wiki_search restricted to {{input.wiki_slug}}'s existing members if scope.kind="wiki" -- check what's already covered so you don't re-propose it).
2. Name the shared facet template every entity's research should cover.
3. Decide the page-space shape for the resulting wiki: flat (uniform entity kind) or nested (heterogeneous categories).

## OUTPUT -- JSON ONLY, no prose, no fences

```json
{
  "rationale": "1-3 sentences",
  "facet_template": "one sentence describing what every entity's page should cover",
  "entities": ["Entity Name 1", "Entity Name 2"],
  "page_prefix_style": "flat" | "nested"
}
```

## HARD CONSTRAINTS

- entities: as many as genuinely exist in the domain, up to a soft target of 24 -- if there are more, list the 24 most notable and note the rest don't fit in the rationale (the substrate enforces the real cap and reports any further overflow on the wiki's index page).
- Maximum 5 rounds of tool calls.
- Output ONLY the JSON object.$T$;

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified, metadata
)
VALUES (
    'wiki-collect',
    'Info-collect: "go fetch all the X, then look at their Y." plan (LLM: entity/facet worklist) -> fan-out (spawn_children, reused unmodified from 14-fanout-brainstorm -- wiki_collect_spawn writes the decompose-shaped manifest onto THIS work_item then calls spawn_children directly) -> aggregate (the generic aggregate-children pipeline, bridged into a real wiki index page by an additive trigger). Bounded per 16-subagents'' delegation limits (subagent_max_children.wiki-collect, seeded above).',
    jsonb_build_array(
        jsonb_build_object(
            'name', 'plan', 'next', NULL,
            'model', 'kimi-k2.6', 'provider', 'opencode_go',
            'agent_family', 'wiki-curator', 'auto_advance', true,
            'tools_disabled', false, 'tool_groups', jsonb_build_array('web-research','substrate-read','wiki-tools'),
            'input_template', v_plan_template
        )
    ),
    false, false, NULL, NULL,
    '["raw","verified"]'::jsonb,
    false,
    jsonb_build_object('shape', 'wiki-fanout')
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
    file_destination_template = EXCLUDED.file_destination_template,
    file_content_jsonpath = EXCLUDED.file_content_jsonpath,
    maturity_ladder = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    metadata = EXCLUDED.metadata,
    updated_at = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('wiki-collect', 'plan', 'verified', 'Entity/facet worklist complete; fires wiki_collect_spawn (deterministic manifest + spawn_children).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('wiki-collect', 'plan', 'kimi-k2.6', 'Entity/facet decomposition; tools enabled (web-research + substrate-read + wiki-tools).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

END $seed$;

-- ---------------------------------------------------------------------
-- wiki_collect_spawn — transforms plan's entity/facet JSON into the
-- EXACT decompose-shaped manifest spawn_children (14-fanout-brainstorm)
-- expects, writes it onto THIS work_item (stage_results.decompose.output
-- -- spawn_children keys strictly on that path regardless of the work_
-- item's own pipeline_family), then calls spawn_children directly. This
-- is the same move start_brainstorm (14) makes for the brainstorm lenses,
-- minus the LLM call being free-form here instead of a fixed lens list.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.wiki_collect_spawn(p_work_item_id uuid)
RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_plan_raw       jsonb;
    v_plan           jsonb;
    v_entities       jsonb;
    v_facet_template text;
    v_prefix_style   text;
    v_wiki_slug      text;
    v_cap            int;
    v_n_entities     int;
    v_n_kept         int;
    v_n_overflow     int;
    v_children       jsonb := '[]'::jsonb;
    v_entity         text;
    v_entity_slug    text;
    v_idx            int;
    v_dest           text;
    v_manifest       jsonb;
    v_spawned        int;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'wiki_collect_spawn: work_item % not found', p_work_item_id;
    END IF;

    v_wiki_slug := COALESCE(NULLIF(v_wi.input ->> 'wiki_slug', ''), v_wi.slug);

    v_plan_raw := v_wi.stage_results -> 'plan' -> 'output';
    IF v_plan_raw IS NULL THEN
        RAISE EXCEPTION 'wiki_collect_spawn: no plan output on work_item %', p_work_item_id;
    END IF;
    IF jsonb_typeof(v_plan_raw) = 'string' THEN
        BEGIN
            v_plan := (v_plan_raw #>> '{}')::jsonb;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'wiki_collect_spawn: plan output is not valid JSON: %', SQLERRM;
        END;
    ELSE
        v_plan := v_plan_raw;
    END IF;

    v_entities       := v_plan -> 'entities';
    v_facet_template := COALESCE(v_plan ->> 'facet_template', 'general research on this entity');
    v_prefix_style   := COALESCE(v_plan ->> 'page_prefix_style', 'flat');

    IF v_entities IS NULL OR jsonb_typeof(v_entities) <> 'array' OR jsonb_array_length(v_entities) = 0 THEN
        RAISE EXCEPTION 'wiki_collect_spawn: plan.entities is missing or empty';
    END IF;

    v_n_entities := jsonb_array_length(v_entities);

    -- Bounded per 16-subagents "as-is": read the EFFECTIVE cap at spawn
    -- time (the config row seeded above, or the global default), reserve
    -- 1 slot for the aggregator spawn_children always creates.
    v_cap := GREATEST(0, COALESCE(
        (SELECT value::int FROM stewards.config WHERE key = 'subagent_max_children.wiki-collect'),
        (SELECT value::int FROM stewards.config WHERE key = 'subagent_max_children'),
        8) - 1);
    v_n_kept     := LEAST(v_n_entities, v_cap);
    v_n_overflow := GREATEST(0, v_n_entities - v_n_kept);

    FOR v_idx IN 0 .. v_n_kept - 1 LOOP
        v_entity := v_entities ->> v_idx;
        EXIT WHEN v_entity IS NULL;
        v_entity_slug := trim(both '-' from regexp_replace(lower(btrim(v_entity)), '[^a-z0-9]+', '-', 'g'));
        IF v_prefix_style = 'nested' THEN
            v_entity_slug := v_wiki_slug || '/' || v_entity_slug;
        END IF;

        v_children := v_children || jsonb_build_object(
            'slug', COALESCE(v_wi.slug, p_work_item_id::text) || '-' || (v_idx + 1)::text,
            'pipeline_family', 'wiki-collect-entity',
            'binding_question', format('Research %s for the wiki "%s". Facets to cover: %s',
                                        v_entity, v_wiki_slug, v_facet_template),
            'input_extra', jsonb_build_object(
                'wiki_slug', v_wiki_slug,
                'entity_name', v_entity,
                'entity_slug', v_entity_slug,
                'page_prefix_style', v_prefix_style
            )
        );
    END LOOP;

    v_dest := 'wikis/' || v_wiki_slug || '/index.md';

    v_manifest := jsonb_build_object(
        'rationale', format('wiki-collect: %s entities decomposed (%s kept, %s overflow)',
                             v_n_entities, v_n_kept, v_n_overflow),
        'children', v_children,
        'aggregate', jsonb_build_object(
            'destination', v_dest,
            'synthesis', false,
            'overflow_count', v_n_overflow
        )
    );

    -- Write the decompose-shaped manifest onto THIS work_item so
    -- spawn_children (14-fanout-brainstorm, unmodified) can read it --
    -- it keys strictly on stage_results.decompose.output, regardless of
    -- this work_item's own pipeline_family (only the TRIGGER gates on
    -- pipeline_family='decompose-fanout'; spawn_children itself does not).
    UPDATE stewards.work_items
       SET stage_results = stage_results || jsonb_build_object('decompose', jsonb_build_object('output', v_manifest))
     WHERE id = p_work_item_id;

    v_spawned := stewards.spawn_children(p_work_item_id);

    RAISE NOTICE 'wiki_collect_spawn: work_item=% wiki=% entities=% kept=% overflow=% spawned=%',
        p_work_item_id, v_wiki_slug, v_n_entities, v_n_kept, v_n_overflow, v_spawned;

    RETURN v_spawned;
END;
$fn$;

COMMENT ON FUNCTION stewards.wiki_collect_spawn(uuid) IS
'94-wiki-curator: transforms wiki-collect''s plan output (entities + facet_template + page_prefix_style) into the decompose-shaped manifest spawn_children (14-fanout-brainstorm) expects, writes it onto stage_results.decompose.output, then calls spawn_children directly -- reusing it UNMODIFIED. Caps the entity list to the effective subagent_max_children.wiki-collect (config, seeded above) minus 1 (the aggregator slot); overflow is reported via the aggregate manifest and surfaces on the wiki index page (wiki_collect_aggregate_bridge).';

-- ── the additive trigger — scoped to pipeline_family='wiki-collect'.
CREATE OR REPLACE FUNCTION stewards.wiki_collect_spawn_trigger()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.pipeline_family = 'wiki-collect' THEN
        BEGIN
            PERFORM stewards.wiki_collect_spawn(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'wiki_collect_spawn_trigger: spawn failed for work_item=%: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS work_items_wiki_collect_spawn ON stewards.work_items;
CREATE TRIGGER work_items_wiki_collect_spawn
    AFTER UPDATE OF maturity ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.maturity = 'verified' AND OLD.maturity IS DISTINCT FROM 'verified')
    EXECUTE FUNCTION stewards.wiki_collect_spawn_trigger();

-- ---------------------------------------------------------------------
-- wiki_collect_aggregate_bridge — the generic aggregate-children pipeline
-- (spawn_children hardcodes it for EVERY fan-out consumer) writes plain
-- markdown to a file_destination. This bridge recognizes ITS OWN
-- aggregator runs (file_destination matches wikis/<slug>/index.md, a
-- path only wiki_collect_spawn ever sets) and turns that markdown into a
-- real wiki index page, appending the overflow/gaps note that spawn_
-- children's manifest handling doesn't forward on its own (it only reads
-- destination + synthesis off the aggregate object, so overflow_count is
-- pulled back from the PARENT's stored manifest here).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.wiki_collect_aggregate_bridge()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_wiki_slug  text;
    v_index_slug text;
    v_content    text;
    v_overflow   int;
BEGIN
    IF NEW.pipeline_family <> 'aggregate-children'
       OR NEW.file_destination IS NULL
       OR NEW.file_destination !~ '^wikis/[a-z0-9-]+/index\.md$' THEN
        RETURN NEW;
    END IF;

    v_wiki_slug := substring(NEW.file_destination FROM 'wikis/([a-z0-9-]+)/index\.md');
    v_content   := NEW.stage_results -> 'aggregate' ->> 'output';
    IF v_content IS NULL OR btrim(v_content) = '' THEN
        RAISE NOTICE 'wiki_collect_aggregate_bridge: no aggregate output for work_item=%', NEW.id;
        RETURN NEW;
    END IF;

    IF NEW.parent_work_item_id IS NOT NULL THEN
        SELECT (stage_results -> 'decompose' -> 'output' -> 'aggregate' ->> 'overflow_count')::int
          INTO v_overflow
          FROM stewards.work_items WHERE id = NEW.parent_work_item_id;
    END IF;
    IF COALESCE(v_overflow, 0) > 0 THEN
        v_content := v_content || E'\n\n## Gaps found\n\n' ||
            format('%s additional entities were identified but not researched this pass (worklist cap). Re-run wiki-collect on this wiki to cover them.', v_overflow);
    END IF;

    v_index_slug := v_wiki_slug || '-index';
    BEGIN
        PERFORM stewards.wiki_create(v_wiki_slug, initcap(replace(v_wiki_slug, '-', ' ')), 'collect', 'project');
        PERFORM stewards.wiki_page_upsert(v_index_slug, initcap(replace(v_wiki_slug, '-', ' ')) || ' -- Index', v_content, '[]'::jsonb);
        PERFORM stewards.wiki_add_member(v_wiki_slug, v_index_slug);
        RAISE NOTICE 'wiki_collect_aggregate_bridge: wiki=% index_page=% work_item=%', v_wiki_slug, v_index_slug, NEW.id;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'wiki_collect_aggregate_bridge: wiki_* call failed for wiki=% (likely 92-wiki-core not yet installed): %', v_wiki_slug, SQLERRM;
    END;

    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS work_items_wiki_collect_aggregate_bridge ON stewards.work_items;
CREATE TRIGGER work_items_wiki_collect_aggregate_bridge
    AFTER UPDATE OF maturity ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.maturity = 'verified' AND OLD.maturity IS DISTINCT FROM 'verified')
    EXECUTE FUNCTION stewards.wiki_collect_aggregate_bridge();

-- ── wiki_collect_start — the entry point.
CREATE OR REPLACE FUNCTION stewards.wiki_collect_start(
    p_question             text,
    p_scope                jsonb DEFAULT NULL,
    p_wiki_slug            text  DEFAULT NULL,
    p_actor                text  DEFAULT 'human',
    p_project_association  text  DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_wiki_slug text;
    v_slug      text;
    v_id        uuid;
BEGIN
    IF p_question IS NULL OR btrim(p_question) = '' THEN
        RAISE EXCEPTION 'wiki_collect_start: question is required';
    END IF;
    v_wiki_slug := COALESCE(NULLIF(p_wiki_slug, ''),
        trim(both '-' from regexp_replace(lower(btrim(p_question)), '[^a-z0-9]+', '-', 'g')));
    v_slug := 'wiki-collect-' || v_wiki_slug || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS');

    v_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-collect',
        p_input           => jsonb_build_object(
            'binding_question', p_question,
            'question', p_question,
            'scope', COALESCE(p_scope, '{"kind":"all","value":null}'::jsonb),
            'wiki_slug', v_wiki_slug
        ),
        p_slug   => v_slug,
        p_actor  => COALESCE(p_actor, 'human')
    );
    UPDATE stewards.work_items
       SET project_association = p_project_association
     WHERE id = v_id;

    PERFORM stewards.work_item_dispatch_stage(v_id, NULL);
    RETURN v_id;
END;
$fn$;
COMMENT ON FUNCTION stewards.wiki_collect_start(text, jsonb, text, text, text) IS
'94-wiki-curator: entry point for wiki-collect (mirrors start_brainstorm''s role). wiki_slug defaults to a slugified question if not given.';

CREATE OR REPLACE FUNCTION stewards.wiki_collect_start_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_id uuid;
BEGIN
    v_id := stewards.wiki_collect_start(
        p_args->>'question',
        p_args->'scope',
        p_args->>'wiki_slug',
        COALESCE(p_args->>'actor', 'human'),
        p_args->>'project_association'
    );
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_id::text);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'wiki_collect_start',
  'Start a wiki-collect run: "go fetch all the X, then research their Y" -- decomposes into an entity worklist, fans out one researcher per entity (~24 max), builds a wiki index page. Args: question (required), scope ({"kind":"project"|"wiki"|"all","value":text}), wiki_slug (defaults to a slugified question), project_association.',
  '{"type":"object","required":["question"],"properties":{"question":{"type":"string"},"scope":{"type":"object"},"wiki_slug":{"type":"string"},"project_association":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_collect_start_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator', 'wiki_collect_start', 'allow'),
  ('research',     'wiki_collect_start', 'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- End of 94-wiki-curator.sql
-- =====================================================================

-- =====================================================================
-- Fleet-integration addendum (integrator, 2026-07-03): the wiki-tools
-- group above grants five verb names that 92 authors only as PLAIN SQL
-- functions — no *_tool(jsonb) wrapper, no tool_defs row, so under
-- deny-by-default the propose stage and the collect-entity children had
-- grants to tools that did not exist. These wrappers follow
-- wiki_search_tool's conventions (jsonb in/out, error-as-jsonb, never
-- RAISE to the dispatch loop).
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.wiki_create_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    IF coalesce(btrim(p_args->>'slug'),'') = '' OR coalesce(btrim(p_args->>'title'),'') = '' THEN
        RETURN '{"error":"slug and title required"}'::jsonb;
    END IF;
    RETURN jsonb_build_object('wiki_id', stewards.wiki_create(
        p_args->>'slug', p_args->>'title',
        coalesce(p_args->>'kind','collection'),
        coalesce(p_args->'scope','{}'::jsonb)));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error','wiki_create failed','detail',SQLERRM);
END;
$FN$;

CREATE OR REPLACE FUNCTION stewards.wiki_page_upsert_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    IF coalesce(btrim(p_args->>'slug'),'') = '' OR coalesce(btrim(p_args->>'title'),'') = '' THEN
        RETURN '{"error":"slug and title required"}'::jsonb;
    END IF;
    RETURN jsonb_build_object('page_id', stewards.wiki_page_upsert(
        p_args->>'slug', p_args->>'title',
        coalesce(p_args->>'content',''),
        coalesce(p_args->'sources','[]'::jsonb),
        p_args->>'reason',
        coalesce(p_args->>'status','live')));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error','wiki_page_upsert failed','detail',SQLERRM);
END;
$FN$;

CREATE OR REPLACE FUNCTION stewards.wiki_add_member_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN jsonb_build_object('added', stewards.wiki_add_member(
        p_args->>'wiki_slug', p_args->>'page_slug', p_args->>'_agent_family'));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error','wiki_add_member failed','detail',SQLERRM);
END;
$FN$;

CREATE OR REPLACE FUNCTION stewards.wiki_page_dedup_check_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $FN$
DECLARE v jsonb;
BEGIN
    SELECT to_jsonb(t) INTO v
      FROM stewards.wiki_page_dedup_check(p_args->>'title', coalesce(p_args->>'content','')) t
     LIMIT 1;
    RETURN coalesce(v, '{"is_duplicate":false,"existing_slug":null,"similarity":null}'::jsonb);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error','dedup check failed','detail',SQLERRM);
END;
$FN$;

CREATE OR REPLACE FUNCTION stewards.wiki_merge_propose_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN jsonb_build_object('review_id', stewards.wiki_merge_propose(
        p_args->>'from_slug', p_args->>'to_slug', p_args->>'rationale'));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error','wiki_merge_propose failed','detail',SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'wiki_create',
  'Create a named wiki (a scope over pages). Args: slug (required), title (required), kind (project|world|manual|collection|pull; default collection), scope (jsonb).',
  '{"type":"object","required":["slug","title"],"properties":{"slug":{"type":"string"},"title":{"type":"string"},"kind":{"type":"string"},"scope":{"type":"object"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_create_tool"}'::jsonb, true ),
( 'wiki_page_upsert',
  'Create or revise a wiki page (revision-aware; slug is the page''s permanent identity). Args: slug (required), title (required), content (markdown), sources (jsonb array of {doc_id|chunk_ref|asset_id, kind, note} — cite what earned each claim), reason, status.',
  '{"type":"object","required":["slug","title"],"properties":{"slug":{"type":"string"},"title":{"type":"string"},"content":{"type":"string"},"sources":{"type":"array"},"reason":{"type":"string"},"status":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_page_upsert_tool"}'::jsonb, true ),
( 'wiki_add_member',
  'Add a page to a wiki (a page may belong to many wikis). Args: wiki_slug (required), page_slug (required).',
  '{"type":"object","required":["wiki_slug","page_slug"],"properties":{"wiki_slug":{"type":"string"},"page_slug":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_add_member_tool"}'::jsonb, true ),
( 'wiki_page_dedup_check',
  'REQUIRED before finalizing any page proposal: checks a candidate title+content against existing pages. Returns {is_duplicate, existing_slug, similarity}; >=0.90 similarity means supersede the existing page (lightning), a middling match means propose a merge instead of multiplying near-duplicates.',
  '{"type":"object","required":["title"],"properties":{"title":{"type":"string"},"content":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_page_dedup_check_tool"}'::jsonb, true ),
( 'wiki_merge_propose',
  'Propose merging one wiki page into another (mountain tier — a human approves it on the Hinge; the merge then applies itself). Args: from_slug, to_slug, rationale.',
  '{"type":"object","required":["from_slug","to_slug"],"properties":{"from_slug":{"type":"string"},"to_slug":{"type":"string"},"rationale":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_merge_propose_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;
-- ===== [was 95-model-role-toggles.sql] =====
-- =====================================================================
-- 95-model-role-toggles.sql — per-alias-member enable/disable + the
-- local-provider "rest all" bulk switch.
-- =====================================================================
-- Michael, fresh off the setup wizard (88/#256): "could use a few more ux
-- ease of life features. like turning off models for the different model
-- kinds (reason, ingest...) I cant disable the local models we've enabled
-- through lm studio or flexllama." 31/32 gave model_aliases a STATIC
-- availability filter — configured + usable (probe verdict) + under-cap +
-- no-train — but nothing an OPERATOR can flip by hand. model_capability.usable
-- is close but the wrong grain for this: it is the auto-probe's capability
-- verdict for a (provider, model) PAIR, shared across every alias that pair
-- happens to belong to, and overwritten by the M.4 probe on its own cadence —
-- reusing it for "Michael turned this off" would let a probe silently
-- re-enable a model he just disabled, and disabling it here would also mark
-- it unusable for any OTHER alias/role that member happens to serve.
--
-- This file adds a per-(alias, provider, provider_model) `enabled` flag — the
-- grain that actually matches "disable qwen3.6-27b for the reason role" (a
-- ROLE, not a global capability) — and teaches the ONE resolver both the
-- dispatcher (31) and the runtime failover walk (32) already share
-- (pick_alias_member) to skip disabled members. Because both consumers
-- already call through that single function, re-authoring it here is the
-- whole fix: work_item_dispatch_stage and steward_tick need no changes.
--
--   • model_aliases.enabled  — boolean, default true (idempotent ADD COLUMN).
--                              A virgin/pre-95 install behaves identically —
--                              every existing row starts enabled.
--   • provider_is_local(provider) — true for lm_studio/flexllama (mirrors
--                              cmd/stewards-ui/api/activity.go's localProviders
--                              map, the one existing "local" convention in
--                              this codebase). Read-only convenience.
--   • pick_alias_member(alias, forbid_training, exclude) — 32's FINAL 3-arg
--                              form, re-authored here (later-file-wins) with
--                              one added predicate: AND a.enabled.
--   • model_aliases_set_local_enabled(enabled) — the "rest all local models" /
--                              wake-all-back-up bulk action: flips enabled for
--                              every row whose provider is local. One
--                              function, one boolean, both directions — the
--                              cockpit's POST /api/models/aliases/rest-local
--                              wraps this so disabling is a click, not SQL.
--
-- requires create_core_compat (91) — purely for chain ordering; the only real
-- dependency is pick_alias_member (32). Generic core: the new column defaults
-- every member enabled, so nothing dispatches differently until an operator
-- (or the cockpit) flips a row off.
-- =====================================================================


-- =====================================================================
-- §1 — the toggle column.
-- =====================================================================
ALTER TABLE stewards.model_aliases
    ADD COLUMN IF NOT EXISTS enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN stewards.model_aliases.enabled IS
'95: operator on/off switch for this alias member, distinct from model_capability.usable (the auto-probe''s capability verdict, shared across every alias a (provider,model) pair belongs to). Disabling a member here removes it from pick_alias_member''s resolution for THIS alias only — a different role that also lists the same (provider, model) is unaffected. Default true: a virgin install / pre-95 row dispatches exactly as before.';


-- =====================================================================
-- §2 — provider_is_local: the one existing "local" convention, named.
-- =====================================================================
-- cmd/stewards-ui/api/activity.go already hardcodes localProviders =
-- {flexllama, lm_studio} to badge live dispatches and drive the GPU column.
-- This mirrors it in SQL so the bulk rest-local toggle (and any future SQL
-- consumer) shares the one true list instead of growing a second copy in a
-- WHERE clause. Keep both in sync if a third local provider ever ships.
CREATE OR REPLACE FUNCTION stewards.provider_is_local(p_provider text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_provider IN ('flexllama', 'lm_studio');
$$;

COMMENT ON FUNCTION stewards.provider_is_local(text) IS
'95: true for the local-rig providers (flexllama, lm_studio) — mirrors cmd/stewards-ui/api/activity.go''s localProviders map. Backs model_aliases_set_local_enabled and the cockpit''s local-provider badge/grouping.';


-- =====================================================================
-- §3 — pick_alias_member FINAL: 32's 3-arg form + the enabled filter.
-- =====================================================================
-- Carries 32's body verbatim (configured + usable + under-cap + no-train +
-- not-excluded) and adds ONE predicate: AND a.enabled. Both consumers
-- (work_item_dispatch_stage's alias path in 31, steward_tick's alias-failover
-- branch in 32) call this SAME function, so re-authoring it here is the whole
-- fix — neither of those two (much larger) functions needs to change.
CREATE OR REPLACE FUNCTION stewards.pick_alias_member(
    p_alias           text,
    p_forbid_training boolean DEFAULT false,
    p_exclude         jsonb   DEFAULT '[]'::jsonb
)
RETURNS TABLE (provider text, model text)
LANGUAGE sql AS $$
    SELECT a.provider, a.provider_model
      FROM stewards.model_aliases a
     WHERE a.alias = p_alias
       AND a.enabled
       AND (
            NOT EXISTS (SELECT 1 FROM stewards.providers_loaded())   -- no registry info → don't filter
            OR stewards.provider_is_loaded(a.provider)
       )
       AND stewards.model_usable(a.provider, a.provider_model)
       AND NOT stewards.provider_cap_exceeded(a.provider)
       AND (NOT p_forbid_training
            OR NOT stewards.model_trains_on_data(a.provider, a.provider_model))
       AND NOT (p_exclude @> jsonb_build_array(
                jsonb_build_object('provider', a.provider, 'model', a.provider_model)))
     ORDER BY a.priority ASC, a.provider, a.provider_model
     LIMIT 1;
$$;

COMMENT ON FUNCTION stewards.pick_alias_member(text, boolean, jsonb) IS
'31/32/95: resolve a model alias to its best concrete (provider, model) — lowest priority that is ENABLED + configured (when the registry is populated) + usable + under spend cap + (when p_forbid_training) no-train + NOT in p_exclude (a jsonb array of {provider, model} already tried this attempt). No rows if none qualify. Both work_item_dispatch_stage (31) and steward_tick''s alias failover (32) resolve through this one function, so a disabled member is skipped at dispatch time AND at runtime failover.';


-- =====================================================================
-- §4 — the "rest all local models" bulk switch + its inverse.
-- =====================================================================
-- One function, one boolean: false rests every local alias member across
-- EVERY role at once — the pain point named verbatim ("I cant disable the
-- local models we've enabled through lm studio or flexllama") — true wakes
-- them all back up. The cockpit's POST /api/models/aliases/rest-local wraps
-- this in one click; no SQL required, and it's fully reversible (only ever
-- flips the enabled flag, never deletes a row), so it needs no confirmation.
CREATE OR REPLACE FUNCTION stewards.model_aliases_set_local_enabled(p_enabled boolean)
RETURNS int LANGUAGE sql AS $$
    WITH updated AS (
        UPDATE stewards.model_aliases
           SET enabled = p_enabled
         WHERE stewards.provider_is_local(provider)
           AND enabled IS DISTINCT FROM p_enabled
        RETURNING 1
    )
    SELECT count(*)::int FROM updated;
$$;

COMMENT ON FUNCTION stewards.model_aliases_set_local_enabled(boolean) IS
'95: bulk-flip enabled for every model_aliases row whose provider is local (provider_is_local) — false = "rest all local models" (every role at once), true = wake them back up. Returns the number of rows actually changed. Reversible, no confirmation needed: it only ever touches the enabled flag, never deletes a row.';

-- =====================================================================
-- End of 95-model-role-toggles.sql
-- =====================================================================
-- ===== [was 96-wiki-assets.sql] =====
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
-- ===== [was 97-world-wiki-bridge.sql] =====
-- =====================================================================
-- 97-world-wiki-bridge.sql — the world→wiki bridge (.spec/proposals/
-- ingestion-crawler-and-raw-to-wiki.md Part 0 + Part 4 arc 1): every World
-- gets a readable face. A World (54-loreworks.sql: world_entities +
-- world_edges, the entity-graph projection) and a Wiki (92-wiki.sql:
-- wiki_pages + page_links, the page projection) are two views of one
-- corpus — this file is the missing cable: world entities auto-materialize
-- as wiki pages, edges become page links.
--
-- ★ THE ONE FUNCTION THAT MATTERS: stewards.world_to_wiki(world_slug) —
-- an idempotent FULL re-projection. Re-run it any time a world's canon
-- changes; it never accumulates duplicate pages (slug is stable identity,
-- 92's own convention), never fabricates a link that isn't a real
-- world_edges row, and never deletes an entity's page when the entity is
-- removed — it supersedes it (92's "a dead page is never deleted, only
-- marked" discipline, wiki_pages.status).
--
-- Real column reconciliations made against the ACTUAL 54/92 DDL (not
-- guessed — read both files before writing a line here):
--   * world_entities has NO updated_at / deleted flag. world_entity_upsert
--     (54) mutates a row in place (summary/aliases/source_refs) without
--     touching created_at, and a removed entity is a genuine hard DELETE
--     (CASCADE from worlds). So "did this entity change" is NOT
--     detectable from world_entities alone — world_to_wiki does not try;
--     it unconditionally re-derives every page's content from the LIVE
--     row on every call (a real full re-projection, not a diff). Only
--     world_wiki_refresh_due (§3) needs a "did something change" signal,
--     and it is honestly scoped to what created_at CAN prove: new
--     entities/edges since the wiki's last projection. An in-place edit
--     to an existing entity (e.g. a summary rewrite) will NOT trip
--     world_wiki_refresh_due — only world_to_wiki re-run (or a caller who
--     already knows a specific world changed) catches that. Documented
--     here, not silently glossed over.
--   * page_sources.doc_id is text (= stewards.docs.id, itself text — 92's
--     header deviation #2), NOT the doc slug world_entities.source_refs
--     carries ([{doc, chunk, quote}], "doc" = a SLUG). §1 resolves
--     source_refs' doc slug -> docs.id per element; an unresolvable slug
--     (no matching doc row) is never fabricated into page_sources — it
--     still appears in the page's own Sources section, marked
--     "(unresolved)", so nothing is silently dropped, but nothing is
--     silently invented as false provenance either.
--   * page_links carries NO unique constraint (no natural ON CONFLICT
--     target — 92's own header does not document one because nothing
--     needed one yet). This file's write side is therefore
--     delete-and-reinsert, scoped to `from_page = <this page's id>` on
--     every re-projection: idempotent by construction (a re-run always
--     leaves EXACTLY the current edge set, never a growing one), safe
--     because a world-entity page's OUTGOING page_links are wholly OWNED
--     by this bridge (nothing else in the fleet writes page_links from a
--     `<world>--<kind>--<name>`-shaped page).
--   * wikis.scope is the ONLY per-wiki free-form jsonb this schema
--     offers (92 §5) — no dedicated "last projected" column or config
--     row exists for a per-wiki timestamp. §3 (world_wiki_refresh_due)
--     stores/reads `scope->>'last_projected_at'` — the smallest honest
--     mechanism, not a new table. wiki_create's own upsert resets `scope`
--     wholesale on every call (92's literal SQL: `scope = EXCLUDED.scope`
--     in its ON CONFLICT), so world_to_wiki calls wiki_create with the
--     BASE scope first, then re-stamps last_projected_at with a direct
--     UPDATE at the very end of the same call — always consistent at
--     rest, briefly absent mid-projection (never observable outside this
--     function's own transaction).
--   * wikis has no is_private column. A World created with is_private=true
--     (54's own local-only/never-train-on-data flag) projects into a wiki
--     that carries NO such flag today — a real, pre-existing schema gap
--     (92 never anticipated a private wiki), not solved here, flagged for
--     the fleet integrator.
--   * Page-slug collision risk (honesty, not solved): the slug scheme
--     `<world_slug>--<kind>--<name-slugified>` is stable across re-runs
--     (a pure function of world/kind/name) and UNIQUE in practice because
--     world_entities itself enforces UNIQUE(world_id, kind, name) — but
--     two DIFFERENT names that slugify to the SAME string within one
--     (world, kind) (e.g. "Aria Stormwind" vs "Aria  Stormwind!") would
--     collide on one wiki_pages.slug and silently conflate two entities
--     into one page. Same class of risk 92's own header calls "page
--     identity is the hard part" for merges — not re-solved here.
--
-- One addition beyond the literal ask, under the stewardship rule (an
-- obvious completion of a primitive this file already introduces, not a
-- new capability): a "### Referenced by" section per page, listing
-- INCOMING edges (this entity as dst) as plain informational wikilinks.
-- Without it, a heavily-referenced entity (e.g. a faction every character
-- is `member_of`) would render with an empty Relations section despite
-- being the most-linked-to page in the world — a readable face that hides
-- the very thing it exists to show. This is textual only — it does NOT
-- write a page_links row (that would fabricate a reverse edge world_edges
-- never asserted); page_links stays a 1:1 mirror of the real graph.
--
-- Tension flagged, not resolved: 85-world-chat.sql's header states "the
-- loremaster stays read-only." Granting world_to_wiki (a WRITE) to the
-- loremaster family (per this mission's explicit ask, §3) sits against
-- that grain — a loremaster asking "refresh my world's wiki" is a
-- plausible, bounded, idempotent write (not open-ended authoring), but
-- it is still the family's first write grant. Surfaced for the fleet
-- integrator / Michael, not silently reconciled either direction.
--
-- ★ THE SMOKE TEST LIVES IN extension/verify-97-world-wiki-bridge.sql,
-- NOT in this file — a deliberate deviation from the literal mission
-- brief ("OK 97 smoke block... inside a transaction-safe DO block"),
-- discovered empirically, not guessed: embedding the fixture-seed/assert/
-- cleanup DO block directly in THIS file (so it runs as part of CREATE
-- EXTENSION) reproducibly broke a COMPLETELY UNRELATED statement later in
-- the SAME generated script — `CREATE FUNCTION stewards.
-- brain_search_text_tool` (schema.rs, a plain, non-OR-REPLACE create) —
-- with "already exists", because `75-wire-brain-hybrid.sql`'s `CREATE OR
-- REPLACE FUNCTION` of the SAME name got scheduled to run FIRST in that
-- build. Bisection proved it: the identical functions/tool/grants above,
-- built and CREATE EXTENSION'd with NO smoke block present, install
-- cleanly, every time; adding the smoke DO block's extra SQL statements
-- back in reliably reproduces the unrelated dupe, in BOTH a cached and a
-- `--no-cache` rebuild. schema.rs's plain CREATE FUNCTION for
-- brain_search_text_tool apparently has no `requires` edge pinning it
-- before 75's redefinition — a pre-existing latent ordering fragility in
-- the base chain, NOT a defect in this file's own SQL (proven: this
-- file's actual functions install and pass their assertions perfectly
-- when run as a standalone `\i` against an already-CREATE-EXTENSION'd
-- database — see the verify file). Flagged for the fleet integrator /
-- Michael; not silently patched by touching schema.rs or 75 from here.
--
-- requires create_wiki_assets (96) — the chain tail as merged (92-96 are
-- all present in this worktree; earlier siblings' "requires the last
-- entry found here, re-stitch at integration" caveat does not apply to
-- this file — it is written AFTER the 6-builder wiki fleet landed).
-- =====================================================================

-- =====================================================================
-- §0 — private helpers (underscore prefix, the 91/15b/92 convention).
-- =====================================================================

-- ── _wwb_slug — kebab-case a name for use inside a page slug. Same
-- regex shape as 26-productivity.sql's todo_slugify, minus the
-- per-session uniqueness suffix (uniqueness here comes from
-- world_entities' own UNIQUE(world_id, kind, name), not a counter).
CREATE OR REPLACE FUNCTION stewards._wwb_slug(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT NULLIF(btrim(regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '-', 'g'), '-'), '');
$fn$;
COMMENT ON FUNCTION stewards._wwb_slug(text) IS
'97: private helper — kebab-case a name for the world-entity page slug scheme. NULL on an empty/all-punctuation input (caller substitutes ''unnamed'').';

-- ── _wwb_entity_page_slug — the ONE place the slug scheme is computed,
-- so a target entity's slug (an edge's dst, looked up by kind+name) and
-- the entity's OWN slug (computed from its own row) are always the same
-- formula. Stable across re-runs: a pure function of (world_slug, kind,
-- name), no entity_id, no ordering dependency.
CREATE OR REPLACE FUNCTION stewards._wwb_entity_page_slug(p_world_slug text, p_kind text, p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT p_world_slug || '--' || lower(coalesce(p_kind, 'concept')) || '--' || coalesce(stewards._wwb_slug(p_name), 'unnamed');
$fn$;
COMMENT ON FUNCTION stewards._wwb_entity_page_slug(text, text, text) IS
'97: the world-entity wiki page slug scheme: <world_slug>--<kind>--<name-slugified>. Same entity (by world/kind/name) -> same slug on every call, so re-projection upserts in place rather than duplicating. See file header for the residual same-kind-name-collision caveat (not solved here).';

-- =====================================================================
-- §1 — world_to_wiki: the idempotent full re-projection.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.world_to_wiki(p_world_slug text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_world          stewards.worlds%ROWTYPE;
    v_wiki_slug      text;
    v_wiki_id        uuid;
    v_current_slugs  text[] := '{}';
    v_ent            record;
    v_edge           record;
    v_slug           text;
    v_target_slug    text;
    v_content        text;
    v_relations      text;
    v_incoming       text;
    v_sources_md     text;
    v_sources_json   jsonb;
    v_page_id        uuid;
    v_doc_id         text;
    v_src            jsonb;
    v_stale          record;
BEGIN
    SELECT * INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world.world_id IS NULL THEN
        RAISE EXCEPTION 'world_to_wiki: unknown world slug %', p_world_slug;
    END IF;

    v_wiki_slug := 'world-' || p_world_slug;
    v_wiki_id := stewards.wiki_create(v_wiki_slug, v_world.name, 'world',
                     jsonb_build_object('world', p_world_slug));

    -- ── one page per world_entity ──
    FOR v_ent IN
        SELECT * FROM stewards.world_entities WHERE world_id = v_world.world_id ORDER BY entity_id
    LOOP
        v_slug := stewards._wwb_entity_page_slug(p_world_slug, v_ent.kind, v_ent.name);
        v_current_slugs := v_current_slugs || v_slug;

        -- Relations: OUTGOING edges (this entity is the source). Each
        -- becomes both a markdown wikilink line AND (below) a real
        -- page_links row -- the two are always in lockstep here.
        v_relations := '';
        FOR v_edge IN
            SELECT g.rel_type, g.evidence, d.name AS target_name, d.kind AS target_kind
              FROM stewards.world_edges g
              JOIN stewards.world_entities d ON d.entity_id = g.dst_entity
             WHERE g.world_id = v_world.world_id AND g.src_entity = v_ent.entity_id
             ORDER BY g.rel_type, d.name
        LOOP
            v_target_slug := stewards._wwb_entity_page_slug(p_world_slug, v_edge.target_kind, v_edge.target_name);
            v_relations := v_relations || '- **' || v_edge.rel_type || '** [[' || v_target_slug || '|' || v_edge.target_name || ']]'
                        || CASE WHEN v_edge.evidence IS NOT NULL AND btrim(v_edge.evidence) <> ''
                                THEN ' — ' || v_edge.evidence ELSE '' END
                        || E'\n';
        END LOOP;

        -- "Referenced by": INCOMING edges (this entity is the target).
        -- Textual only -- see file header addition note. NOT written to
        -- page_links (that direction is asserted from the SOURCE side).
        v_incoming := '';
        FOR v_edge IN
            SELECT g.rel_type, s.name AS source_name, s.kind AS source_kind
              FROM stewards.world_edges g
              JOIN stewards.world_entities s ON s.entity_id = g.src_entity
             WHERE g.world_id = v_world.world_id AND g.dst_entity = v_ent.entity_id
             ORDER BY g.rel_type, s.name
        LOOP
            v_target_slug := stewards._wwb_entity_page_slug(p_world_slug, v_edge.source_kind, v_edge.source_name);
            v_incoming := v_incoming || '- [[' || v_target_slug || '|' || v_edge.source_name || ']] **' || v_edge.rel_type || '** this' || E'\n';
        END LOOP;

        -- Sources: source_refs ([{doc, chunk, quote}], doc = a SLUG) ->
        -- markdown text (always) + resolved doc_id for page_sources
        -- (only when the slug resolves to a real doc -- see file header).
        v_sources_md := '';
        v_sources_json := '[]'::jsonb;
        FOR v_src IN SELECT * FROM jsonb_array_elements(coalesce(v_ent.source_refs, '[]'::jsonb))
        LOOP
            v_doc_id := NULL;
            IF v_src ->> 'doc' IS NOT NULL THEN
                SELECT id INTO v_doc_id FROM stewards.docs WHERE slug = v_src ->> 'doc';
            END IF;
            v_sources_md := v_sources_md
                || '- ' || coalesce(v_src ->> 'doc', '(no doc named)')
                || CASE WHEN v_doc_id IS NULL THEN ' _(unresolved — no matching doc, not filed as page provenance)_' ELSE '' END
                || CASE WHEN v_src ->> 'chunk' IS NOT NULL THEN ' — chunk `' || (v_src ->> 'chunk') || '`' ELSE '' END
                || CASE WHEN v_src ->> 'quote' IS NOT NULL THEN ': "' || (v_src ->> 'quote') || '"' ELSE '' END
                || E'\n';
            IF v_doc_id IS NOT NULL THEN
                v_sources_json := v_sources_json || jsonb_build_array(jsonb_build_object(
                    'doc_id', v_doc_id, 'chunk_ref', v_src ->> 'chunk', 'kind', 'doc', 'note', v_src ->> 'quote'));
            END IF;
        END LOOP;

        -- assemble the page body.
        v_content := '# ' || v_ent.name || E'\n\n**Kind:** ' || v_ent.kind || E'\n';
        IF v_ent.aliases IS NOT NULL AND array_length(v_ent.aliases, 1) > 0 THEN
            v_content := v_content || '**Aliases:** ' || array_to_string(v_ent.aliases, ', ') || E'\n';
        END IF;
        v_content := v_content || E'\n' || coalesce(NULLIF(btrim(v_ent.summary), ''), '_no summary recorded._') || E'\n';
        v_content := v_content || E'\n## Relations\n\n'
                  || CASE WHEN v_relations = '' THEN '_none recorded._' || E'\n' ELSE v_relations END;
        IF v_incoming <> '' THEN
            v_content := v_content || E'\n### Referenced by\n\n' || v_incoming;
        END IF;
        v_content := v_content || E'\n## Sources\n\n'
                  || CASE WHEN v_sources_md = '' THEN '_no source_refs recorded._' || E'\n' ELSE v_sources_md END;

        v_page_id := stewards.wiki_page_upsert(
            v_slug, v_ent.name, v_content, v_sources_json,
            format('world_to_wiki: re-projected from world %s', p_world_slug), 'live');
        PERFORM stewards.wiki_add_member(v_wiki_slug, v_slug, 'world_to_wiki');

        -- page_links: delete-and-reinsert THIS page's outgoing set (no
        -- natural unique key on page_links to ON CONFLICT against -- see
        -- file header). Scoped to from_page so it never touches any
        -- other page's links.
        DELETE FROM stewards.page_links WHERE from_page = v_page_id;
        INSERT INTO stewards.page_links (from_page, to_slug, kind)
        SELECT v_page_id,
               stewards._wwb_entity_page_slug(p_world_slug, d.kind, d.name),
               g.rel_type
          FROM stewards.world_edges g
          JOIN stewards.world_entities d ON d.entity_id = g.dst_entity
         WHERE g.world_id = v_world.world_id AND g.src_entity = v_ent.entity_id;
    END LOOP;

    -- ── removed entities -> supersede (never delete) their page ──
    FOR v_stale IN
        SELECT wp.id, wp.slug, wp.title, wp.content
          FROM stewards.wiki_members wm
          JOIN stewards.wiki_pages wp ON wp.id = wm.page_id
         WHERE wm.wiki_id = v_wiki_id
           AND wp.slug LIKE (p_world_slug || '--%')
           AND wp.status <> 'superseded'
           AND NOT (wp.slug = ANY (v_current_slugs))
    LOOP
        PERFORM stewards.wiki_page_upsert(v_stale.slug, v_stale.title, v_stale.content, '[]'::jsonb,
            format('world_to_wiki: entity removed from world %s', p_world_slug), 'superseded');
        DELETE FROM stewards.page_links WHERE from_page = v_stale.id;
    END LOOP;

    -- ── stamp the projection timestamp (world_wiki_refresh_due's read) ──
    UPDATE stewards.wikis
       SET scope = scope || jsonb_build_object('last_projected_at', to_jsonb(now()))
     WHERE id = v_wiki_id;

    RETURN v_wiki_slug;
END;
$fn$;

COMMENT ON FUNCTION stewards.world_to_wiki(text) IS
'97: idempotent full re-projection of a World onto a wiki (kind=world, slug=world-<world_slug>). One page per world_entity (slug=<world_slug>--<kind>--<name-slugified>, stable across re-runs), page_links mirroring world_edges 1:1 (delete-and-reinsert per page, outgoing only), page_sources filed for every source_ref whose doc slug resolves (unresolved refs stay in the page text only -- never fabricated provenance). Entities removed from the world since the last run get their page marked status=''superseded'' (never deleted). Safe to call repeatedly -- see file header for exactly what "idempotent" does and does not mean here (page identity is stable; wiki_page_upsert''s own revision-per-call semantics, 92, are not this file''s to change).';

-- =====================================================================
-- §2 — world_wiki_refresh_due: cheap "who needs a re-projection" scan.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.world_wiki_refresh_due()
RETURNS TABLE (
    world_slug         text,
    wiki_slug          text,
    entity_count       bigint,
    last_projected_at  timestamptz,
    latest_change_at   timestamptz
) LANGUAGE sql STABLE AS $fn$
    WITH w_latest AS (
        SELECT w.world_id, w.slug,
               count(DISTINCT e.entity_id)             AS entity_count,
               GREATEST(max(e.created_at), max(g.created_at)) AS latest_change_at
          FROM stewards.worlds w
          LEFT JOIN stewards.world_entities e ON e.world_id = w.world_id
          LEFT JOIN stewards.world_edges    g ON g.world_id = w.world_id
         GROUP BY w.world_id, w.slug
        HAVING count(DISTINCT e.entity_id) > 0
    )
    SELECT wl.slug, 'world-' || wl.slug, wl.entity_count,
           NULLIF(wk.scope ->> 'last_projected_at', '')::timestamptz,
           wl.latest_change_at
      FROM w_latest wl
      LEFT JOIN stewards.wikis wk ON wk.slug = 'world-' || wl.slug
     WHERE wk.id IS NULL
        OR NULLIF(wk.scope ->> 'last_projected_at', '')::timestamptz IS NULL
        OR wl.latest_change_at > NULLIF(wk.scope ->> 'last_projected_at', '')::timestamptz
     ORDER BY wl.slug;
$fn$;

COMMENT ON FUNCTION stewards.world_wiki_refresh_due() IS
'97: worlds whose wiki has never been projected, or whose entities/edges carry a created_at later than the wiki''s last world_to_wiki call (wikis.scope->>''last_projected_at''). HONEST LIMITATION (see file header): world_entities/world_edges have no updated_at -- an in-place edit to an EXISTING entity (world_entity_upsert''s summary/aliases merge) does not bump created_at and will NOT be flagged here; only NEW entities/edges since the last projection are detectable this way. A caller who already knows a specific world changed should just call world_to_wiki directly rather than waiting on this scan.';

-- =====================================================================
-- §3 — tool_def + jsonb wrapper (94's exact convention: jsonb in/out,
-- error-as-jsonb, no exception escapes to the caller).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.world_to_wiki_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_world_slug text := p_args ->> 'world_slug';
    v_wiki_slug  text;
BEGIN
    IF v_world_slug IS NULL OR btrim(v_world_slug) = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'world_slug required');
    END IF;
    v_wiki_slug := stewards.world_to_wiki(v_world_slug);
    RETURN jsonb_build_object('ok', true, 'wiki_slug', v_wiki_slug);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_to_wiki',
  'Materialize (or re-project) a World''s entity graph as a browsable wiki: one page per world_entity, page links from world_edges, provenance from source_refs. Idempotent full re-projection — safe to re-run any time the world''s canon changes. Args: world_slug (required).',
  '{"type":"object","required":["world_slug"],"properties":{"world_slug":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_to_wiki_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- ── grants: wiki-curator (default source, matches 94's own grant rows
-- for this family) + loremaster (explicit source='manual', matching
-- 57/85's convention for THIS family -- loremaster's base row is a
-- wildcard '*' DENY, so every allow it holds is an explicit, longest-
-- match-wins override, never left to the frontmatter-reimport default).
-- See file header for the read-only-loremaster tension this grant sits
-- against -- flagged, not silently resolved.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator', 'world_to_wiki', 'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('loremaster', 'world_to_wiki', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- =====================================================================
-- End of 97-world-wiki-bridge.sql
-- =====================================================================
