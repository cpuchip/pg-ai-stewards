-- ===== [was 71-hybrid-rrf.sql] =====
-- =====================================================================
-- 71-hybrid-rrf.sql — make hybrid search REAL Reciprocal Rank Fusion.
-- =====================================================================
-- Two fusion sites called "hybrid" were not doing what hybrid retrieval
-- means in the literature:
--   • 57's world_entity_hybrid fused weighted-LINEAR: 0.45·lex_score +
--     0.55·sem_score. Blending raw scores lets one leg's magnitude (a huge
--     ILIKE/ts_rank number, or an uncalibrated cosine) dominate the other,
--     so a hit that BOTH legs agree on can lose to a single-leg outlier.
--   • doc_search was FTS-only — no semantic leg at all, even though
--     stewards.docs already carries a vector(768) `embedding`.
--
-- This file replaces both with canonical Reciprocal Rank Fusion (RRF):
--
--     score = Σ over each leg the item appears in of  1 / (k + rank)
--
-- with k = 60 (the standard constant), rank 1-based per leg, and a UNION of
-- the legs (FULL JOIN + coalesce(1/(k+rank), 0)) so an item present in only
-- one leg still contributes its single term. RRF fuses by RANK POSITION, not
-- raw score — so agreement across legs (a thing both the lexical and the
-- semantic search surfaced) wins, which is the whole point of hybrid search.
-- This matches gospel-engine v1/v2's proven rrfMerge.
--
-- Equal weight is deliberate (the old 0.45/0.55 lean was a non-canonical
-- guess). If a semantic lean is ever wanted, weighted-RRF — w/(k+rank) per
-- leg — is a one-line change at the fused CTE.
--
-- Both functions keep the embed_query round-trip with a graceful
-- EXCEPTION → NULL fallback: on a deployment with no embed provider (e.g. the
-- virgin-smoke env), v_vec is NULL, the semantic leg is empty, and search
-- degrades cleanly to lexical-only — which must still work.
--
-- requires create_hinge_decouple (70).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — world_entity_hybrid: real RRF (supersedes 57's weighted-linear).
--   lex leg  = world_entity_search (name/alias/summary), top p_limit*3
--   sem leg  = cosine over world_entities.embedding, top p_limit*3
-- Signature, embed round-trip, and the lexical-only fallback are unchanged
-- from 57; only the fusion math changes (weighted-linear → RRF).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_entity_hybrid(
    p_world_slug text, p_query text, p_limit int DEFAULT 12)
RETURNS TABLE (entity_id bigint, kind text, name text, summary text, score real)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_world    bigint;
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_k        constant int := 60;   -- canonical RRF damping constant
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN RETURN; END IF;
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    BEGIN
        v_vec := stewards.embed_query(p_query, v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;   -- no embed provider / down: lexical-only
    END;

    RETURN QUERY
    WITH lex AS (
        -- world_entity_search already returns top-N pre-sorted by its score DESC.
        SELECT s.entity_id, ROW_NUMBER() OVER (ORDER BY s.score DESC) AS rank
          FROM stewards.world_entity_search(p_world_slug, p_query, p_limit * 3) s
    ),
    sem AS (
        SELECT e.entity_id, ROW_NUMBER() OVER (ORDER BY e.embedding <=> v_vec) AS rank
          FROM stewards.world_entities e
         WHERE e.world_id = v_world AND v_vec IS NOT NULL AND e.embedding IS NOT NULL
         ORDER BY e.embedding <=> v_vec
         LIMIT p_limit * 3
    ),
    fused AS (
        -- RRF: Σ 1/(k+rank) over the legs each entity appears in. UNION via
        -- FULL JOIN + coalesce(...,0) so a single-leg hit keeps its one term.
        -- (Weighted-RRF available later: 0.45/(k+lex.rank) + 0.55/(k+sem.rank).)
        SELECT coalesce(lex.entity_id, sem.entity_id) AS eid,
               (coalesce(1.0/(v_k + lex.rank), 0)
              + coalesce(1.0/(v_k + sem.rank), 0))::real AS score
          FROM lex FULL JOIN sem ON lex.entity_id = sem.entity_id
    )
    SELECT e.entity_id, e.kind, e.name, e.summary, f.score
      FROM fused f JOIN stewards.world_entities e ON e.entity_id = f.eid
     ORDER BY f.score DESC, e.name
     LIMIT GREATEST(p_limit, 1);
END $$;
COMMENT ON FUNCTION stewards.world_entity_hybrid(text,text,int) IS
  '57/71: fused lexical(world_entity_search) + semantic(embed_query cosine) entity search via real equal-weight Reciprocal Rank Fusion (RRF, k=60) — supersedes 57''s weighted-linear blend. Degrades to lexical-only when no embed provider is configured.';

-- ---------------------------------------------------------------------
-- §2 — doc_search_hybrid: give the doc corpus a semantic leg.
--   lex leg  = doc_search (the FTS primitive, kept intact — see §3), top*3
--   sem leg  = cosine over docs.embedding (vector(768)), top*3
-- Same shape as doc_search: (slug, kind, title, snippet, rank). The `rank`
-- column now carries the fused RRF score (not ts_rank). The snippet is rebuilt
-- with the same ts_headline params doc_search uses.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.doc_search_hybrid(
    p_query text,
    p_kinds text[] DEFAULT ARRAY[]::text[],
    p_limit int DEFAULT 10
) RETURNS TABLE (
    slug    text,
    kind    text,
    title   text,
    snippet text,
    rank    real
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_k        constant int := 60;   -- canonical RRF damping constant
BEGIN
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    BEGIN
        v_vec := stewards.embed_query(p_query, v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;   -- no embed provider / down: lexical-only
    END;

    RETURN QUERY
    WITH lex AS (
        -- the FTS leg = doc_search (already kind-filtered + top-N by ts_rank DESC).
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
        -- RRF: Σ 1/(k+rank) over the legs each doc appears in. UNION via FULL
        -- JOIN + coalesce(...,0). (Weighted-RRF available later as in §1.)
        SELECT coalesce(lex.d_slug, sem.d_slug) AS f_slug,
               (coalesce(1.0/(v_k + lex.rank), 0)
              + coalesce(1.0/(v_k + sem.rank), 0))::real AS score
          FROM lex FULL JOIN sem ON lex.d_slug = sem.d_slug
    )
    SELECT d.slug, d.kind, d.title,
           ts_headline('english', coalesce(d.body, ''),
                       websearch_to_tsquery('english', p_query),
                       'MaxWords=20, MinWords=10, ShortWord=3') AS snippet,
           f.score AS rank
      FROM fused f JOIN stewards.docs d ON d.slug = f.f_slug
     ORDER BY f.score DESC, d.slug
     LIMIT GREATEST(p_limit, 1);
END $$;
COMMENT ON FUNCTION stewards.doc_search_hybrid(text, text[], int) IS
  '71: hybrid doc search — the FTS leg (doc_search) fused with a semantic leg (embed_query cosine over docs.embedding) via real equal-weight RRF (k=60). Same shape as doc_search; the rank column carries the fused score. Degrades to FTS-only when no embed provider is configured.';

-- ---------------------------------------------------------------------
-- §3 — repoint the agent-facing doc_search TOOL to the hybrid function.
-- The bare stewards.doc_search FTS function is LEFT INTACT: it is the
-- lexical leg of doc_search_hybrid above (its internal caller) and the
-- stable FTS primitive other internal callers can rely on. Only the
-- model-facing wrapper switches to hybrid, so agents get the semantic leg.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.doc_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.doc_search_hybrid(
        p_args->>'query',
        coalesce(
            (SELECT array_agg(value::text)
               FROM jsonb_array_elements_text(coalesce(p_args->'kinds', '[]'::jsonb)) AS value),
            ARRAY[]::text[]
        ),
        coalesce((p_args->>'limit')::int, 10)
    ) t;
$func$;

-- Keep the doc_search tool_def description honest now that it is hybrid (the
-- `rank` is a fused RRF score, and the semantic leg degrades gracefully).
UPDATE stewards.tool_defs
   SET description = 'Hybrid search over the substrate''s document corpus: Postgres FTS over body_tsv FUSED with semantic vector search (embed_query cosine over the doc embeddings) via Reciprocal Rank Fusion (RRF). Returns ranked matches with slug, kind, title, snippet, and a fused `rank` score. Use this to find docs by topic before reading them with doc_get. Filter to specific kinds via the `kinds` array (kinds are operator-defined; empty = all). On a deployment with no embed provider it degrades to FTS-only.'
 WHERE name = 'doc_search';
-- ===== [was 72-hybrid-rrf-everywhere.sql] =====
-- =====================================================================
-- 72-hybrid-rrf-everywhere.sql — finish what 71 started.
-- =====================================================================
-- 71 made "hybrid" REAL Reciprocal Rank Fusion (k=60) for two surfaces
-- (world_entity_hybrid, doc_search_hybrid). This file extends the SAME
-- treatment to EVERY remaining doc-corpus surface, and adds an opt-in
-- 1-hop graph-expand hop to all four hybrid surfaces.
--
-- THREE distinct mechanisms (don't conflate them):
--
--   1. RRF = FUSION of two retrievers (lexical + semantic), ranked by
--      Σ 1/(k+rank). Brought here to pool_search and the engram search,
--      which were single-leg (FTS-only / vector-only) like doc_search was
--      before 71. The fixed point is 71's doc_search_hybrid.
--
--   2. The engram FTS leg is a genuine SCHEMA change: engram_embeddings
--      had no tsvector at all (vector-only). We add a GENERATED ... STORED
--      tsvector + GIN index so engrams get a lexical leg to fuse with.
--      STORED means ALTER ADD COLUMN backfills every existing row at
--      migration time (no manual UPDATE), and inserts keep it current.
--
--   3. graph-expand = TRAVERSAL AFTER retrieval (not fusion). Opt-in via a
--      p_expand boolean DEFAULT false on each hybrid: retrieve → take the
--      top-K hits → pull their 1-hop graph neighbors → merge, ranked BELOW
--      the direct hits. OFF by default (auto-expanding every search would
--      add noise + cost). Each surface uses the graph it already has:
--        • docs / pool_search → doc_similar (SIMILAR_TO cosine edges)
--        • worlds             → world_edges (the relational entity graph)
--        • engrams            → same-message provenance siblings (engrams
--          are NOT first-class graph nodes; the available in-table 1-hop
--          neighbor is a sibling engram extracted from the same source).
--
-- Both new fused functions keep the embed_query round-trip with a graceful
-- EXCEPTION → NULL fallback (no embed provider ⇒ semantic leg empty ⇒
-- degrade to lexical-only). The engram hybrid takes the query embedding as
-- a PARAMETER (mirroring search_engrams_by_vector, whose Go wrapper embeds
-- query-side) — so p_query_embedding NULL is its FTS-only fallback.
--
-- doc_search_hybrid + world_entity_hybrid (authored in 71) gain p_expand
-- via the established drop-then-create idiom (a defaulted extra arg would
-- make the prior N-arg calls ambiguous; cf. 32's pick_alias_member). Their
-- existing callers resolve to the new form via the default at runtime.
--
-- requires create_hybrid_rrf (71).
-- =====================================================================


-- =====================================================================
-- §1 — engram FTS leg (the one real schema change).
-- engram_embeddings was vector-only. Add a GENERATED tsvector over the
-- searchable text (topic + content_preview — the same text the embed
-- enqueue uses) + a GIN index. STORED ⇒ existing rows backfill at ALTER.
-- =====================================================================
ALTER TABLE stewards.engram_embeddings
  ADD COLUMN IF NOT EXISTS engram_fts tsvector
  GENERATED ALWAYS AS (
      to_tsvector('english',
          coalesce(topic, '') || ' ' || coalesce(content_preview, ''))
  ) STORED;

CREATE INDEX IF NOT EXISTS engram_embeddings_fts_idx
  ON stewards.engram_embeddings USING gin (engram_fts);

COMMENT ON COLUMN stewards.engram_embeddings.engram_fts IS
'72: GENERATED tsvector over (topic || content_preview) — the lexical leg for search_engrams_hybrid. STORED, so ALTER ADD COLUMN backfills every existing row at migration time (no manual UPDATE) and inserts/updates keep it current automatically.';


-- =====================================================================
-- §2 — pool_search → RRF.
-- pool_search was FTS-only (ts_rank), inlined inside pool_search_tool, over
-- the same stewards.docs that already carry a vector(768) embedding. Give
-- it a semantic leg and fuse via RRF, applying the project-neighborhood
-- scope to BOTH legs. Mirrors 71's doc_search decision exactly:
--   • a bare FTS primitive (stewards.pool_search) is the lexical leg AND a
--     stable scoped-FTS primitive internal callers can rely on;
--   • pool_search_hybrid fuses it with the semantic leg;
--   • pool_search_tool routes through the hybrid fn (keeping its envelope).
-- =====================================================================

-- §2.1 — bare scoped-FTS primitive (the lexical leg; same FTS the inline
-- pool_search_tool used). p_neighbors NULL = global/unscoped; else restrict
-- to the named projects. This IS the scope enforcement, applied per-leg.
CREATE OR REPLACE FUNCTION stewards.pool_search(
    p_query     text,
    p_neighbors text[] DEFAULT NULL,
    p_limit     int    DEFAULT 10
) RETURNS TABLE (
    slug text, kind text, title text, project_association text, snippet text, rank real
)
LANGUAGE sql STABLE AS $func$
    SELECT s.slug, s.kind, s.title, s.project_association,
           ts_headline('english', coalesce(s.body, ''), q, 'MaxWords=20, MinWords=10') AS snippet,
           ts_rank(s.body_tsv, q)::real AS rank
      FROM stewards.docs s, websearch_to_tsquery('english', p_query) q
     WHERE s.body_tsv @@ q
       AND (p_neighbors IS NULL OR s.project_association = ANY(p_neighbors))
     ORDER BY rank DESC
     LIMIT greatest(p_limit, 1);
$func$;
COMMENT ON FUNCTION stewards.pool_search(text, text[], int) IS
'72: bare project-scoped FTS primitive over stewards.docs.body_tsv (p_neighbors NULL = global). The lexical leg of pool_search_hybrid and a stable scoped-FTS primitive. Ordered by ts_rank.';

-- §2.2 — pool_search_hybrid: RRF(FTS + semantic), scoped on BOTH legs, with
-- an opt-in 1-hop graph-expand (doc_similar) that STAYS inside the project
-- neighborhood (so expansion never leaks across walled-off projects).
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
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_k        constant int := 60;   -- canonical RRF damping constant
BEGIN
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    BEGIN
        v_vec := stewards.embed_query(p_query, v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;   -- no embed provider / down: lexical-only
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
               (coalesce(1.0/(v_k + lex.rank), 0)
              + coalesce(1.0/(v_k + sem.rank), 0))::real AS score
          FROM lex FULL JOIN sem ON lex.d_slug = sem.d_slug
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
        -- 1-hop SIMILAR_TO neighbors of the direct hits, scored strictly
        -- BELOW the lowest direct (flr*0.5*edge_score < flr), and kept
        -- inside the project neighborhood (no wall leak).
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
    -- subquery wrap so ORDER BY is a qualified column (u.rank), not the
    -- RETURNS TABLE OUT-variable `rank` (plpgsql would call it ambiguous).
    SELECT u.* FROM (
        SELECT * FROM direct
        UNION ALL
        SELECT * FROM nbr
    ) u
     ORDER BY u.rank DESC NULLS LAST
     LIMIT CASE WHEN p_expand THEN GREATEST(p_limit, 1) * 2 ELSE GREATEST(p_limit, 1) END;
END $fn$;
COMMENT ON FUNCTION stewards.pool_search_hybrid(text, text[], int, boolean) IS
'72: project-scoped hybrid pool search — bare pool_search (FTS) fused with a semantic leg (embed_query cosine over docs.embedding) via real equal-weight RRF (k=60), scope applied to BOTH legs. p_expand=true adds a 1-hop SIMILAR_TO graph-expand (neighbors kept inside the neighborhood, ranked below direct hits; may return up to 2×limit rows). Degrades to FTS-only with no embed provider.';

-- §2.3 — repoint pool_search_tool through the hybrid fn (keeps its scope
-- resolution + JSON envelope; adds an opt-in `expand` arg).
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
      FROM stewards.pool_search_hybrid(v_query, v_neighbors, v_limit, v_expand);

    RETURN jsonb_build_object('project', v_project, 'neighborhood', v_neighbors,
        'results', COALESCE(v_rows, '[]'::jsonb),
        'note', CASE WHEN v_neighbors IS NULL
                     THEN 'no project scope — searched the whole pool (meta).'
                     ELSE 'scoped to this project''s neighborhood; other projects are walled off.' END)::text;
END $FN$;

UPDATE stewards.tool_defs
   SET description = 'Search the knowledge pool (docs) SCOPED to your project''s neighborhood — your own project plus any it is connected to — using HYBRID retrieval (Postgres FTS fused with semantic vector search via Reciprocal Rank Fusion (RRF), scope applied to both legs). Use this for normal reading so you stay on-topic and do not bleed across walled-off projects. (Global doc_search exists for deliberate cross-project meta-studies.) Args: query (required), limit, expand (optional bool — also pull in 1-hop similar neighbors of the top hits, kept inside your neighborhood). On a deployment with no embed provider it degrades to FTS-only.',
       args_schema = '{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"limit":{"type":"integer"},"expand":{"type":"boolean"}}}'::jsonb
 WHERE name = 'pool_search';


-- =====================================================================
-- §3 — search_engrams_hybrid: RRF(FTS leg + the existing vector leg).
-- Additive — search_engrams_by_vector is untouched. The query embedding is
-- a PARAMETER (mirroring search_engrams_by_vector; the Go search_engrams
-- wrapper embeds query-side), so p_query_embedding NULL ⇒ semantic leg
-- empty ⇒ graceful FTS-only fallback. p_expand=true pulls same-message
-- sibling engrams (the available 1-hop provenance neighbor).
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
    WITH lex AS (
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
               (coalesce(1.0/(60 + lex.rank), 0)
              + coalesce(1.0/(60 + sem.rank), 0))::real AS score
          FROM lex FULL JOIN sem ON lex.id = sem.id
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
        -- engram 1-hop adjacency = same-message provenance siblings (engrams
        -- extracted from the same source document). engrams are NOT graph
        -- nodes, so this is the available in-table neighbor. Scored below
        -- every direct hit (flr*0.5) so directs are never displaced.
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
'72: hybrid engram search — the new engram_fts lexical leg fused with the existing embedding cosine leg via real equal-weight RRF (k=60). Additive (search_engrams_by_vector untouched). p_query_embedding is supplied by the caller (NULL ⇒ FTS-only fallback). p_expand=true pulls same-message sibling engrams (1-hop provenance neighbor), ranked below direct hits. session/project filters apply to both legs.';


-- =====================================================================
-- §4 — doc_search_hybrid (71) gains the opt-in graph-expand hop.
-- Drop-then-create to add p_expand (a defaulted extra arg would make the
-- 71 three-arg call ambiguous — cf. 32's pick_alias_member). doc_search_tool
-- and other 3-arg callers resolve to the new form via the default.
-- =====================================================================
DROP FUNCTION IF EXISTS stewards.doc_search_hybrid(text, text[], int);
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
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_k        constant int := 60;
BEGIN
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
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
        SELECT coalesce(lex.d_slug, sem.d_slug) AS f_slug,
               (coalesce(1.0/(v_k + lex.rank), 0)
              + coalesce(1.0/(v_k + sem.rank), 0))::real AS score
          FROM lex FULL JOIN sem ON lex.d_slug = sem.d_slug
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
        -- 1-hop SIMILAR_TO neighbors of the direct hits, kept on-kind, scored
        -- strictly below the lowest direct (flr*0.5*edge_score < flr).
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
    -- subquery wrap so ORDER BY is a qualified column (u.rank), not the
    -- RETURNS TABLE OUT-variable `rank` (plpgsql would call it ambiguous).
    SELECT u.* FROM (
        SELECT * FROM direct
        UNION ALL
        SELECT * FROM nbr
    ) u
     ORDER BY u.rank DESC NULLS LAST
     LIMIT CASE WHEN p_expand THEN GREATEST(p_limit, 1) * 2 ELSE GREATEST(p_limit, 1) END;
END $fn$;
COMMENT ON FUNCTION stewards.doc_search_hybrid(text, text[], int, boolean) IS
'71/72: hybrid doc search — FTS (doc_search) fused with semantic (embed_query cosine over docs.embedding) via real equal-weight RRF (k=60). p_expand=true adds a 1-hop SIMILAR_TO graph-expand (on-kind neighbors ranked below direct hits; may return up to 2×limit rows). Degrades to FTS-only with no embed provider.';

-- repoint doc_search_tool to pass the opt-in expand flag through.
CREATE OR REPLACE FUNCTION stewards.doc_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.doc_search_hybrid(
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

UPDATE stewards.tool_defs
   SET description = 'Hybrid search over the substrate''s document corpus: Postgres FTS over body_tsv FUSED with semantic vector search (embed_query cosine over the doc embeddings) via Reciprocal Rank Fusion (RRF). Returns ranked matches with slug, kind, title, snippet, and a fused `rank` score. Use this to find docs by topic before reading them with doc_get. Filter to specific kinds via the `kinds` array (kinds are operator-defined; empty = all). Set `expand` true to also pull in 1-hop similar (SIMILAR_TO) neighbors of the top hits — related docs that did not directly match. On a deployment with no embed provider it degrades to FTS-only.',
       args_schema = '{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"kinds":{"type":"array","items":{"type":"string"}},"limit":{"type":"integer"},"expand":{"type":"boolean"}}}'::jsonb
 WHERE name = 'doc_search';


-- =====================================================================
-- §5 — world_entity_hybrid (71) gains the opt-in graph-expand hop.
-- Drop-then-create to add p_expand. lore_search_tool / the loremaster
-- 3-arg calls resolve to the new form via the default.
-- =====================================================================
DROP FUNCTION IF EXISTS stewards.world_entity_hybrid(text, text, int);
CREATE OR REPLACE FUNCTION stewards.world_entity_hybrid(
    p_world_slug text,
    p_query      text,
    p_limit      int     DEFAULT 12,
    p_expand     boolean DEFAULT false)
RETURNS TABLE (entity_id bigint, kind text, name text, summary text, score real)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_world    bigint;
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_k        constant int := 60;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN RETURN; END IF;
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    BEGIN
        v_vec := stewards.embed_query(p_query, v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;
    END;

    RETURN QUERY
    WITH lex AS (
        SELECT s.entity_id, ROW_NUMBER() OVER (ORDER BY s.score DESC) AS rank
          FROM stewards.world_entity_search(p_world_slug, p_query, p_limit * 3) s
    ),
    sem AS (
        SELECT e.entity_id, ROW_NUMBER() OVER (ORDER BY e.embedding <=> v_vec) AS rank
          FROM stewards.world_entities e
         WHERE e.world_id = v_world AND v_vec IS NOT NULL AND e.embedding IS NOT NULL
         ORDER BY e.embedding <=> v_vec
         LIMIT p_limit * 3
    ),
    fused AS (
        SELECT coalesce(lex.entity_id, sem.entity_id) AS eid,
               (coalesce(1.0/(v_k + lex.rank), 0)
              + coalesce(1.0/(v_k + sem.rank), 0))::real AS score
          FROM lex FULL JOIN sem ON lex.entity_id = sem.entity_id
    ),
    direct AS (
        SELECT e.entity_id, e.kind, e.name, e.summary, f.score AS score
          FROM fused f JOIN stewards.world_entities e ON e.entity_id = f.eid
         ORDER BY f.score DESC, e.name
         LIMIT GREATEST(p_limit, 1)
    ),
    flr AS (SELECT min(direct.score) AS f FROM direct),
    nbr AS (
        -- 1-hop world_edges neighbors of the direct hits (either direction),
        -- scored below every direct (flr*0.5).
        SELECT DISTINCT ON (o.entity_id)
               o.entity_id, o.kind, o.name, o.summary,
               ((SELECT f FROM flr) * 0.5)::real AS score
          FROM direct d
          JOIN stewards.world_edges g
            ON (g.src_entity = d.entity_id OR g.dst_entity = d.entity_id)
           AND g.world_id = v_world
          JOIN stewards.world_entities o
            ON o.entity_id = CASE WHEN g.src_entity = d.entity_id THEN g.dst_entity ELSE g.src_entity END
         WHERE p_expand
           AND o.entity_id NOT IN (SELECT direct.entity_id FROM direct)
         ORDER BY o.entity_id
    )
    -- subquery wrap so ORDER BY is a qualified column (u.score), not the
    -- RETURNS TABLE OUT-variable `score` (plpgsql would call it ambiguous).
    SELECT u.* FROM (
        SELECT * FROM direct
        UNION ALL
        SELECT * FROM nbr
    ) u
     ORDER BY u.score DESC NULLS LAST
     LIMIT CASE WHEN p_expand THEN GREATEST(p_limit, 1) * 2 ELSE GREATEST(p_limit, 1) END;
END $fn$;
COMMENT ON FUNCTION stewards.world_entity_hybrid(text,text,int,boolean) IS
'57/71/72: fused lexical(world_entity_search) + semantic(embed_query cosine) entity search via real equal-weight RRF (k=60). p_expand=true adds a 1-hop world_edges graph-expand (related entities ranked below direct hits; may return up to 2×limit rows). Degrades to lexical-only when no embed provider is configured.';

-- expose the opt-in expand through lore_search (the loremaster's entry tool).
CREATE OR REPLACE FUNCTION stewards.lore_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_slug text := p_args->>'world_slug'; v_q text := p_args->>'query';
        v_lim int := coalesce((p_args->>'limit')::int, 10);
        v_expand boolean := coalesce((p_args->>'expand')::boolean, false);
        v_hits jsonb;
BEGIN
    IF v_slug IS NULL OR v_q IS NULL THEN RETURN jsonb_build_object('error','world_slug and query required'); END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
              'kind', h.kind, 'name', h.name, 'summary', h.summary,
              'source_refs', (SELECT e.source_refs FROM stewards.world_entities e WHERE e.entity_id=h.entity_id))
            ORDER BY h.score DESC), '[]'::jsonb)
      INTO v_hits
      FROM stewards.world_entity_hybrid(v_slug, v_q, v_lim, v_expand) h;
    RETURN jsonb_build_object('ok', true, 'hits', v_hits);
END $fn$;

UPDATE stewards.tool_defs
   SET args_schema = '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"query":{"type":"string"},"limit":{"type":"integer"},"expand":{"type":"boolean"}},"required":["world_slug","query"]}'::jsonb
 WHERE name = 'lore_search';
-- ===== [was 73-brain-hybrid.sql] =====
-- =====================================================================
-- 73-brain-hybrid.sql — the last doc-corpus surface to get real RRF.
-- =====================================================================
-- 71 made "hybrid" REAL Reciprocal Rank Fusion (k=60) for the world and
-- doc surfaces; 72 carried it to pool_search and the engrams. The personal
-- brain (stewards.brain_entries) was still single-leg split: a FTS search
-- (brain_search_text) and a vector search (brain_search_vec) that never
-- fuse. This file adds stewards.brain_search_hybrid — the same canonical
-- equal-weight RRF over those two legs.
--
-- ZERO schema change: brain_entries already carries BOTH a GENERATED
-- body_tsv (+ GIN index brain_entries_fts_idx) AND an embedding vector(768)
-- (+ HNSW index). Both legs already exist as registered functions; this
-- file only fuses them.
--
-- The query embedding is a PARAMETER (mirroring brain_search_vec, whose
-- caller supplies the 768-dim vector — the brain's query path embeds
-- query-side in the Go/becoming layer, exactly like search_engrams_by_vector
-- in 72). So p_query_embedding NULL ⇒ semantic leg empty ⇒ graceful
-- FTS-only fallback. This is the brain analog of 72's search_engrams_hybrid,
-- NOT of doc_search_hybrid (which embeds query-side internally via
-- embed_query because its agent-facing tool only passes text).
--
-- The bare legs are LEFT INTACT and additive:
--   • brain_search_text — the lexical leg AND a stable FTS primitive.
--   • brain_search_vec  — untouched; the vector-only primitive.
-- Both the category filter and the `NOT quarantined` guard the existing
-- brain search applies are mirrored on BOTH legs (brain_search has no
-- needs_review filter, so neither does this — read from the existing fns,
-- not from memory).
--
-- NO graph-expand (no p_expand). brain_entries are NOT graph nodes — same
-- as engrams. Unlike engrams there is no trivial in-table 1-hop neighbor
-- worth surfacing: same-tag entries would be a DESIGNED feature, not a
-- provenance sibling like an engram's same-message peer. Inventing a graph
-- here would be out of bounds, so this surface stays retrieval-only.
--
-- MCP wiring is DEFERRED (named as a follow-up), exactly like 72 left
-- search_engrams_hybrid's Go wiring: the agent-facing brain search tool
-- (becoming's brain_search, and/or the substrate's brain_search_text_tool)
-- passes only text, so routing it through the hybrid is a query-side-embed
-- change in the Go/becoming layer — not a clean SQL swap. Left untouched.
--
-- requires create_hybrid_rrf_everywhere (72).
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.brain_search_hybrid(
    p_query           text,
    p_query_embedding vector(768) DEFAULT NULL,
    p_category        text        DEFAULT NULL,
    p_limit           int         DEFAULT 20
) RETURNS TABLE (
    id       text,
    title    text,
    category text,
    score    real
)
LANGUAGE sql STABLE AS $fn$
    WITH lex AS (
        -- FTS leg = brain_search_text (intact): already category-filtered,
        -- NOT quarantined, and pre-sorted by ts_rank DESC. Re-rank 1-based.
        SELECT b.id,
               ROW_NUMBER() OVER (ORDER BY b.rank DESC, b.id) AS rank
          FROM stewards.brain_search_text(p_query, p_category, p_limit * 3) b
    ),
    sem AS (
        -- vector leg = cosine over brain_entries.embedding, SAME filters
        -- (category + NOT quarantined) applied per-leg. NULL query embedding
        -- ⇒ this leg is empty ⇒ FTS-only fallback.
        SELECT e.id,
               ROW_NUMBER() OVER (ORDER BY e.embedding <=> p_query_embedding) AS rank
          FROM stewards.brain_entries e
         WHERE p_query_embedding IS NOT NULL AND e.embedding IS NOT NULL
           AND (p_category IS NULL OR e.category = p_category)
           AND NOT e.quarantined
         ORDER BY e.embedding <=> p_query_embedding
         LIMIT p_limit * 3
    ),
    fused AS (
        -- RRF: Σ 1/(k+rank) over the legs each entry appears in, k=60.
        -- UNION via FULL JOIN + coalesce(...,0) so a single-leg hit keeps
        -- its one term. (Weighted-RRF available later as in 71/72's §1.)
        SELECT coalesce(lex.id, sem.id) AS bid,
               (coalesce(1.0/(60 + lex.rank), 0)
              + coalesce(1.0/(60 + sem.rank), 0))::real AS score
          FROM lex FULL JOIN sem ON lex.id = sem.id
    )
    SELECT e.id, e.title, e.category, f.score AS score
      FROM fused f JOIN stewards.brain_entries e ON e.id = f.bid
     ORDER BY f.score DESC, e.id
     LIMIT GREATEST(p_limit, 1);
$fn$;
COMMENT ON FUNCTION stewards.brain_search_hybrid(text, vector, text, int) IS
'73: hybrid brain search — the FTS leg (brain_search_text) fused with the vector leg (cosine over brain_entries.embedding) via real equal-weight Reciprocal Rank Fusion (RRF, k=60). Additive: brain_search_text + brain_search_vec are untouched. p_query_embedding is supplied by the caller (NULL ⇒ FTS-only graceful fallback), mirroring brain_search_vec. The category filter and the NOT-quarantined guard apply to BOTH legs. Returns (id, title, category, score) where score is the fused RRF score. No graph-expand — brain_entries are not graph nodes.';
-- ===== [was 74-north-star.sql] =====
-- =====================================================================
-- 74-north-star.sql — the substrate's Intent (step 1), on every call.
-- =====================================================================
-- Authored 2026-06-27.
--
-- WHY THIS EXISTS
-- The substrate runs the back half of a creation cycle — covenant,
-- stewardship, specification, watching, atonement — but step 1, the named
-- *why*, was never made explicit on the work itself. Every LLM call carried
-- the covenant (how we work) but not the Intent it serves (what the work is
-- ultimately FOR). This file gives the substrate its North Star: a short,
-- standing *why* prepended to the system prompt of every agent call, ahead of
-- the covenant, with directions that re-root the substrate's EXISTING covenant
-- behaviors under that why — so it becomes the tie-breaker when values conflict.
--
-- LOAD-BEARING, NOT A STICKER
-- A why pasted on every prompt that changes nothing becomes wallpaper the model
-- ignores. The block therefore does two things: it names the why, and it names
-- the behaviors that why governs (welfare over the metric; point to the source;
-- persuade, don't compel; verify before you assert and assume you can be wrong)
-- — the substrate's own covenant clauses, restated as the *why beneath them*.
-- The closing line makes the role explicit: when the commitments below pull in
-- different directions, the North Star breaks the tie.
--
-- GENERIC IN THE CORE, OPERATOR-OWNED IN CONFIG
-- The public core ships a real, generic default why + directions. It hardcodes
-- no scripture and no operator-specific content (same discipline as 09's
-- scripture_anchor -> values_anchor genericization). Each operator names their
-- OWN north star with config_set('north_star.why', ...) — the FORM is universal
-- (every steward must name an Intent), the CONTENT is theirs. The seed uses
-- ON CONFLICT DO NOTHING so a migrate never clobbers an operator's value.
-- An empty/absent why means no block renders (an operator may opt out; the
-- mechanism fails open to silence). Recommended scriptures for operators who
-- share the faith live in docs/north-star.md, never in the core.
--
-- WHERE IT LANDS
-- render_north_star() composes the block from config; compose_system_prompt
-- (re-authored here, later-file-wins over 09) prepends it FIRST and echoes it
-- last (primacy AND recency, like the covenant). One chokepoint => every agent
-- call carries the why. Personas (17) compose their own prompt and are out of
-- scope by design — the North Star governs the substrate's own labor, not a
-- role-played character's voice.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Config — the operator-owned north star. Generic, real defaults.
-- DO NOTHING: upgrades never overwrite an operator's setting.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('north_star.why',
   to_jsonb('Serve the genuine good of the people this work is for — not merely the completion of the task.'::text),
   'The substrate''s guiding *why*, prepended to every agent system prompt (step 1 of the creation cycle). Operators: set your own with config_set(''north_star.why'', to_jsonb(''...''::text)). Empty/absent ⇒ no North Star block renders. See docs/north-star.md for recommended anchors.'),

  ('north_star.directions',
   '["Serve the real welfare of the people you act for, above any metric or quota.",
     "Point to the source of what you report; take no credit that is not yours.",
     "Persuade and invite — never compel.",
     "Read before you assert, and assume you can be wrong."]'::jsonb,
   'The directions the North Star governs — the substrate''s existing covenant behaviors, restated as the *why beneath them* so the why is load-bearing, not a sticker. Operators may override or extend. Empty array ⇒ the why renders alone.'),

  ('north_star.source',
   to_jsonb(''::text),
   'Optional citation/anchor shown beneath the why (e.g. an operator''s chosen scripture or maxim). Empty ⇒ no attribution line.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- render_north_star() — compose the block from config, or NULL if the
-- operator has cleared the why (opt-out / fail-open-to-silence).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.render_north_star()
RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_why        text  := stewards.config_get_text('north_star.why');
    v_source     text  := stewards.config_get_text('north_star.source');
    v_directions jsonb := stewards.config_get('north_star.directions');
    v_dir_str    text;
    v_block      text;
BEGIN
    -- No why ⇒ no North Star. An operator can opt out by clearing the key.
    IF v_why IS NULL OR length(trim(v_why)) = 0 THEN
        RETURN NULL;
    END IF;

    v_block := E'=== North Star ===\n' || trim(v_why);

    IF v_source IS NOT NULL AND length(trim(v_source)) > 0 THEN
        v_block := v_block || E'\n  — ' || trim(v_source);
    END IF;

    IF v_directions IS NOT NULL
       AND jsonb_typeof(v_directions) = 'array'
       AND jsonb_array_length(v_directions) > 0 THEN
        SELECT string_agg('  - ' || trim(d.value #>> '{}'), E'\n')
          INTO v_dir_str
          FROM jsonb_array_elements(v_directions) d;
        v_block := v_block ||
            E'\n\nLet this why govern how you work here:\n' || v_dir_str ||
            E'\n\nWhen the commitments and values below pull in different directions, this is the tie-breaker.';
    END IF;

    RETURN v_block;
END;
$func$;

COMMENT ON FUNCTION stewards.render_north_star() IS
'Composes the === North Star === block from the north_star.* config keys (why + optional source + directions). Returns NULL when the why is empty/absent (operator opt-out). Called first by compose_system_prompt; the why is the standing Intent (step 1) carried on every agent call.';

-- ---------------------------------------------------------------------
-- compose_system_prompt — re-authored (later-file-wins over 09) to
-- prepend the North Star FIRST and echo it last. Body is otherwise the
-- 09/PR.1 version verbatim: covenant + presiding, work_item intent,
-- agent prompt, instructions, skills, agenda, tool primers, Watch echo.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compose_system_prompt(
    p_agent_family text, p_model text, p_session_id text
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_agent          stewards.agents;
    v_prompt         text := '';
    v_north_star     text;
    v_instructions   text;
    v_skills_block   text;
    v_covenant       stewards.covenants;
    v_intent         stewards.intents;
    v_covenant_block text := '';
    v_intent_block   text := '';
    v_human_str      text;
    v_agent_str      text;
    v_values_str     text;
    v_non_goals_str  text;
    v_presiding          jsonb;
    v_presiding_str      text;
    v_presiding_cncl_str text;
    v_echo_keys          text;
BEGIN
    v_agent := stewards.resolve_agent(p_agent_family, p_model);
    IF v_agent.family IS NULL THEN
        RAISE EXCEPTION
            'no agent variant resolved: family=% model=%',
            p_agent_family, p_model;
    END IF;

    -- Step 1: the North Star — the substrate's standing *why*, ahead of all else.
    v_north_star := stewards.render_north_star();

    -- Active covenant block (always-on for global scope).
    SELECT * INTO v_covenant
      FROM stewards.covenants
     WHERE scope = 'global' AND deactivated_at IS NULL
     ORDER BY activated_at DESC
     LIMIT 1;

    IF v_covenant.id IS NOT NULL THEN
        SELECT string_agg('  - ' || (c->>'key') || ': ' || (c->>'description'), E'\n')
          INTO v_human_str
          FROM jsonb_array_elements(v_covenant.human_commits_to) c;

        SELECT string_agg('  - ' || (c->>'key') || ': ' || (c->>'description'), E'\n')
          INTO v_agent_str
          FROM jsonb_array_elements(v_covenant.agent_commits_to) c;

        v_covenant_block :=
            E'=== Active Covenant ===\n' ||
            E'The human commits to:\n' || coalesce(v_human_str, '  (none)') || E'\n\n' ||
            E'The agent (you) commits to:\n' || coalesce(v_agent_str, '  (none)');

        IF v_covenant.council_moment IS NOT NULL AND length(v_covenant.council_moment) > 0 THEN
            v_covenant_block := v_covenant_block || E'\n\nCouncil moment:\n  ' || v_covenant.council_moment;
        END IF;

        -- PR.1: presiding extension — the chain-of-watches delegation terms.
        v_presiding := v_covenant.extensions -> 'presiding';
        IF v_presiding IS NOT NULL THEN
            SELECT string_agg(
                     '  - ' || e.key || ': ' || trim(e.value->>'description') ||
                     CASE WHEN e.value ? 'emergency'
                          THEN E'\n    Emergency: ' || trim(e.value->>'emergency')
                          ELSE '' END,
                     E'\n' ORDER BY e.key)
              INTO v_presiding_str
              FROM jsonb_each(v_presiding->'agent_commits_to') e;

            SELECT string_agg('  - ' || e.key || ': ' || trim(e.value->>'description'),
                              E'\n' ORDER BY e.key)
              INTO v_presiding_cncl_str
              FROM jsonb_each(v_presiding->'council_commits_to') e;

            IF v_presiding_str IS NOT NULL THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nWhen you delegate — subagents, dispatches, persona turns — you preside over that work, and commit to:\n' ||
                    v_presiding_str;
            END IF;
            IF v_presiding_cncl_str IS NOT NULL THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nThe council commits to:\n' || v_presiding_cncl_str;
            END IF;
            IF v_presiding ? 'when_presiding_is_broken' THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nBreach signature: ' ||
                    trim(v_presiding->'when_presiding_is_broken'->>'description');
            END IF;
        END IF;
    END IF;

    -- Intent block (only when the session resolves to a work_item with an intent).
    SELECT i.* INTO v_intent
      FROM stewards.intents i
      JOIN stewards.work_items wi ON wi.intent_id = i.id
     WHERE p_session_id = ANY(coalesce(wi.session_ids, ARRAY[]::text[]))
     LIMIT 1;

    IF v_intent.id IS NOT NULL THEN
        SELECT string_agg(
                 '  - ' || (v->>'key') ||
                 CASE WHEN v ? 'kind' AND v->>'kind' = 'constraint'
                      THEN ' [constraint, severity=' || coalesce(v->>'severity','?') || ']'
                      ELSE ''
                 END ||
                 ': ' || (v->>'description'),
                 E'\n'
               )
          INTO v_values_str
          FROM jsonb_array_elements(v_intent.values_hierarchy) v;

        v_non_goals_str := array_to_string(v_intent.non_goals, E'\n  - ', '');

        v_intent_block :=
            E'=== Intent ===\n' ||
            E'Slug: ' || v_intent.slug || E'\n' ||
            E'Purpose: ' || v_intent.purpose || E'\n';

        IF v_intent.beneficiary IS NOT NULL THEN
            v_intent_block := v_intent_block || E'Beneficiary: ' || v_intent.beneficiary || E'\n';
        END IF;

        v_intent_block := v_intent_block || E'\nValues (in order of priority):\n' ||
            coalesce(v_values_str, '  (none)');

        IF v_intent.non_goals IS NOT NULL AND array_length(v_intent.non_goals, 1) > 0 THEN
            v_intent_block := v_intent_block || E'\n\nNon-goals:\n  - ' || v_non_goals_str;
        END IF;

        IF v_intent.values_anchor IS NOT NULL THEN
            v_intent_block := v_intent_block || E'\n\nValues anchor: ' || v_intent.values_anchor;
        END IF;
    END IF;

    -- Compose: North Star + covenant + intent first, then === Agent === marker, then agent.
    IF v_north_star IS NOT NULL THEN
        v_prompt := v_north_star || E'\n\n';
    END IF;
    IF length(v_covenant_block) > 0 THEN
        v_prompt := v_prompt || v_covenant_block || E'\n\n';
    END IF;
    IF length(v_intent_block) > 0 THEN
        v_prompt := v_prompt || v_intent_block || E'\n\n';
    END IF;
    IF length(v_prompt) > 0 THEN
        v_prompt := v_prompt || E'=== Agent ===\n';
    END IF;

    v_prompt := v_prompt || v_agent.prompt;

    -- Existing logic: instructions + skills.
    SELECT string_agg(body, E'\n\n' ORDER BY ord, family)
    INTO v_instructions
    FROM (
        SELECT DISTINCT ON (family)
            family, body, ord
        FROM stewards.instructions
        WHERE active
          AND scope IN ('global', 'agent:' || p_agent_family)
          AND stewards.glob_match(model_match, p_model)
        ORDER BY family, length(model_match) DESC, model_match
    ) t;
    IF v_instructions IS NOT NULL THEN
        v_prompt := v_prompt || E'\n\n' || v_instructions;
    END IF;

    -- Skills — the 3-tier catalog (group summaries -> opened-group frontmatter ->
    -- loaded bodies). Built in 24-skills.sql; the call is late-bound (plpgsql), so
    -- the forward reference to a later chain file is safe. Returns NULL when the
    -- agent is skill-denied or nothing is visible.
    v_skills_block := stewards.render_skills_block(p_agent_family, p_model, p_session_id);
    IF v_skills_block IS NOT NULL THEN
        v_prompt := v_prompt || v_skills_block;
    END IF;

    -- Agenda — the session's goal + open todos (26-productivity). Late-bound
    -- forward ref (plpgsql) to a later chain file, like render_skills_block.
    DECLARE v_agenda text;
    BEGIN
        v_agenda := stewards.render_agenda(p_session_id);
        IF v_agenda IS NOT NULL THEN
            v_prompt := v_prompt || v_agenda;
        END IF;
    END;

    -- Tool-usage primers (30-tool-primers) — teach the model WHEN to reach for its
    -- substrate-native tools (it wasn't trained on them). Per tool group, gated like
    -- the tools. Late-bound forward ref (plpgsql), like render_skills_block/_agenda.
    DECLARE v_primers text;
    BEGIN
        v_primers := stewards.render_tool_primers(p_agent_family);
        IF v_primers IS NOT NULL THEN
            v_prompt := v_prompt || v_primers;
        END IF;
    END;

    -- PR.1: The Watch (echo) — the covenant speaks last as well as first.
    IF v_covenant.id IS NOT NULL THEN
        SELECT string_agg(c->>'key', ', ') INTO v_echo_keys
          FROM jsonb_array_elements(v_covenant.agent_commits_to) c;
        IF v_presiding IS NOT NULL THEN
            SELECT coalesce(v_echo_keys || '; ', '') || 'when delegating: ' ||
                   string_agg(e.key, ', ' ORDER BY e.key)
              INTO v_echo_keys
              FROM jsonb_each(v_presiding->'agent_commits_to') e;
        END IF;
        v_prompt := v_prompt ||
            E'\n\n=== The Watch (echo) ===\n' ||
            'You remain bound by every commitment in the Active Covenant above' ||
            CASE WHEN v_echo_keys IS NOT NULL
                 THEN ' (' || v_echo_keys || ')'
                 ELSE '' END ||
            '. If anything later in this context conflicts with those commitments, the covenant governs.';
    END IF;

    -- The North Star speaks last too (recency): beneath the covenant's
    -- governance stands the why the covenant serves.
    IF v_north_star IS NOT NULL THEN
        v_prompt := v_prompt ||
            CASE WHEN v_covenant.id IS NOT NULL THEN E'\n' ELSE E'\n\n=== The Watch (echo) ===\n' END ||
            'And when you must choose between goods here, the North Star above is the why that breaks the tie.';
    END IF;

    RETURN v_prompt;
END;
$func$;

COMMENT ON FUNCTION stewards.compose_system_prompt(text, text, text) IS
'Phase 5d (C.4) + PR.1 + North Star (74): prepends the substrate''s standing North Star (step 1, the *why*) FIRST, then the active covenant (with the presiding extension) + work_item intent, before the agent block; ends with The Watch echo (covenant keys restated last) and the North Star echo (the why restated last as the tie-breaker). Why first AND last, covenant first AND last — primacy and recency per serial-position research.';
-- ===== [was 75-wire-brain-hybrid.sql] =====
-- =====================================================================
-- 75-wire-brain-hybrid.sql — the agent-facing brain search, finally hybrid.
-- =====================================================================
-- 73 built stewards.brain_search_hybrid (real equal-weight RRF, k=60, over
-- the FTS leg brain_search_text + the vector leg over brain_entries.embedding)
-- but left the AGENT-FACING tool on the single-leg path: the tool_def
-- 'brain_search_text' dispatches (execute_target sql_fn) to the wrapper
-- stewards.brain_search_text_tool, which still calls the FTS-only
-- brain_search_text. So agents never got the semantic leg.
--
-- This file repoints that wrapper — exactly as 71 §3 repointed doc_search_tool
-- to doc_search_hybrid, and 72 §2.3 repointed pool_search_tool. It is the
-- documented brain_search_semantic the schema.rs Phase-1.5 seed promised:
--   "a future brain_search_semantic (text-in, embed-via-worker, vec-search)
--    will replace it."
--
-- THE KEY INSIGHT (why this is a clean SQL swap, not a Go change):
-- 73's header reasoned that wiring the brain tool to the hybrid was "a
-- query-side-embed change in the Go/becoming layer ... exactly like 72 left
-- search_engrams_hybrid's Go wiring." That is true for the ENGRAM search,
-- whose agent-facing wrapper is a Go MCP tool. It is NOT true for the BRAIN
-- search: its agent-facing wrapper (brain_search_text_tool) is a pure SQL
-- sql_fn, and stewards.embed_query is a synchronous pg_extern. So the query
-- can be embedded INLINE IN SQL inside the wrapper — no Go dispatch involved.
-- That is what this file does.
--
-- The embed round-trip uses the SAME graceful EXCEPTION → NULL fallback as
-- 71/72's doc/pool tools: on a deployment with no embed provider (e.g. the
-- virgin-smoke env) embed_query raises, v_vec becomes NULL, brain_search_hybrid's
-- vector leg is empty, and the tool degrades cleanly to FTS-only — which must
-- still work. brain_search_hybrid takes the query embedding as a PARAMETER
-- (73's design), so this wrapper is the right place for the embed: it is the
-- "caller" 73's comment referred to.
--
-- Output shape is PRESERVED. The hybrid's fused-score column is `score`; the
-- old FTS tool surfaced `rank`. We alias score → rank so the agent-visible
-- keys stay (id, title, category, rank) — matching 71/72's convention of
-- surfacing the fused RRF score under the surface's original score-column name
-- (doc_search_hybrid / pool_search_hybrid both name theirs `rank`). The tool
-- args (query, category, limit) are unchanged, so args_schema is untouched.
--
-- The bare legs (brain_search_text, brain_search_vec) and the hybrid fn itself
-- are LEFT INTACT — this file changes only the agent-facing wrapper + the
-- tool_def description (made honest: it is hybrid now, and degrades to FTS-only
-- with no provider). The execute_target is unchanged (still the sql_fn
-- brain_search_text_tool), so the dispatch path is identical.
--
-- NOT done here (flagged, not invented): the ENGRAM search has no agent-facing
-- tool in this repo at all — no tool_def and no search_engrams Go handler;
-- search_engrams_hybrid (72) is an internal SQL fn only. Wiring it would mean
-- creating a new agent tool surface, which is out of scope without a council
-- nod. Left for a follow-up.
--
-- requires create_north_star (74).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Repoint the agent-facing brain search wrapper to the hybrid: embed the
-- query text INLINE via the embed_query pg_extern, then call
-- brain_search_hybrid with that vector. plpgsql (was sql) for the
-- EXCEPTION → NULL embed fallback. execute_target is unchanged, so the
-- tool_def 'brain_search_text' now resolves, through the same sql_fn, to
-- the hybrid path.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.brain_search_text_tool(p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_result   jsonb;
BEGIN
    -- Embed the query INLINE. embed_query is the synchronous pg_extern; with
    -- no embed provider configured it raises → caught → NULL ⇒ the hybrid's
    -- vector leg is empty ⇒ graceful FTS-only fallback (cf. 71/72's doc/pool).
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
        -- alias the fused score → rank to preserve the prior output shape
        -- (id, title, category, rank), mirroring 71/72's tools.
        SELECT h.id, h.title, h.category, h.score AS rank
          FROM stewards.brain_search_hybrid(
                   p_args->>'query',
                   v_vec,
                   p_args->>'category',
                   coalesce((p_args->>'limit')::int, 20)
               ) h
      ) t;
    RETURN v_result;
END $func$;

COMMENT ON FUNCTION stewards.brain_search_text_tool(jsonb) IS
'75: the agent-facing brain search wrapper, repointed to brain_search_hybrid (73). Embeds the query text inline via the embed_query pg_extern (EXCEPTION → NULL ⇒ FTS-only fallback with no provider) and fuses the FTS + vector legs via RRF. The fused score is aliased to `rank` to preserve the prior output shape (id, title, category, rank). This is the documented brain_search_semantic, made real as a clean SQL swap (no Go dispatch — the brain tool is a sql_fn, unlike the engram search whose wrapper is Go).';

-- Make the tool_def description honest now that the tool is hybrid (the agent
-- sees the description, not the wrapper). Args are unchanged → args_schema is
-- left as-is. The tool NAME and execute_target are kept (the established
-- agent-facing surface; renaming would touch the brain_* permission glob and
-- the reaper fixtures for no behavioral gain — cf. 71/72 keeping doc_search /
-- pool_search names while making them hybrid).
UPDATE stewards.tool_defs
   SET description = 'Hybrid search over your personal brain entries (notes, ideas, study fragments): Postgres FTS over the entry text FUSED with semantic vector search via Reciprocal Rank Fusion (RRF). You pass plain text — the query is embedded server-side, no vector input needed. Returns ranked matches with id, title, category, and a fused `rank` score. Optionally filter with `category`. On a deployment with no embed provider it degrades to FTS-only.'
 WHERE name = 'brain_search_text';
-- ===== [was 76-wire-engram-search.sql] =====
-- =====================================================================
-- 76-wire-engram-search.sql — the agent-facing ENGRAM search, the twin
-- of 75's brain wiring.
-- =====================================================================
-- 72 built stewards.search_engrams_hybrid (real equal-weight RRF, k=60, over
-- the engram_fts lexical leg + the embedding vector leg, with an opt-in
-- same-message graph-expand) — but NO agent could reach it. Unlike the brain
-- search, the engram search had no agent-facing surface AT ALL: no tool_def,
-- and no Go MCP handler in this repo (the only engram tools agents see are
-- expand_message, mark_engram_important, re_extract_engrams — none a search).
-- 75 flagged this gap rather than filling it. This file fills it, as the exact
-- twin of 75's brain wiring.
--
-- §1 — engram_search_tool: the SQL wrapper. text-in → embed the query INLINE
--   via the embed_query pg_extern (same EXCEPTION → NULL guard as 75: no embed
--   provider ⇒ vector leg empty ⇒ graceful FTS-only fallback) → call
--   search_engrams_hybrid with that vector. Pure SQL, no Go dispatch — exactly
--   like the brain tool, and unlike the Go wrapper 72's header imagined.
--
-- §2 — the engram_search tool_def. Named for the SEARCH-tool convention
--   (doc_search / pool_search / lore_search / brain_search*), not the
--   verb-noun of the mutation tools (mark_engram_important, re_extract_engrams).
--   Substrate-wide by default (single-user deployments are first-class, so this
--   mirrors brain_search's un-scoped reach over the personal corpus); the
--   underlying fn's session/project filters are left at NULL here. Output shape
--   surfaces message_id + engram_id (the pair expand_message / mark_engram_-
--   important consume) plus tier/topic/content_preview and the fused RRF score
--   aliased to `rank` — consistent with the other search tools.
--
-- §3 — the grant. Mirror brain_search_text's families EXACTLY, no broader.
--   The resolver (tool_permission → compose_tools) defaults to ALLOW for any
--   family without a `* : deny` base, so every brain_search_text family except
--   one ALREADY reaches engram_search by that same default — granting them
--   nothing new. The lone exception is stewards-explore, which carries a
--   `* : deny` base + an explicit `brain_*` allow; engram_search does not match
--   `brain_*`, so without this row it would be denied there while brain_search
--   is allowed. Adding the single mirroring allow makes engram_search reachable
--   by EXACTLY brain_search_text's set. Brain-DENIED families (analyst, the
--   watchman family, loremaster, persona, …) keep denying engram_search too —
--   no broadening. (Verified against the live perm resolver before authoring.)
--
-- requires create_brain_search_wire (75).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — engram_search_tool: embed inline, then search_engrams_hybrid.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.engram_search_tool(p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_result   jsonb;
BEGIN
    -- Embed the query INLINE (no Go wrapper — the engram tool is a sql_fn, like
    -- the brain tool). embed_query is the synchronous pg_extern; with no embed
    -- provider it raises → caught → NULL ⇒ the hybrid's vector leg is empty ⇒
    -- graceful FTS-only fallback (identical to 75's brain wiring).
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
        -- substrate-wide (session/project NULL); fused score aliased → rank.
        SELECT h.message_id, h.engram_id, h.tier, h.topic, h.content_preview,
               h.session_id, h.project_association, h.score AS rank
          FROM stewards.search_engrams_hybrid(
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

COMMENT ON FUNCTION stewards.engram_search_tool(jsonb) IS
'76: the agent-facing engram search wrapper — text-in, embeds the query inline via the embed_query pg_extern (EXCEPTION → NULL ⇒ FTS-only fallback with no provider), and fuses the engram FTS + vector legs via search_engrams_hybrid (72, RRF k=60). Substrate-wide (session/project NULL). Returns message_id, engram_id, tier, topic, content_preview, session_id, project_association, and the fused score as `rank`. The clean-SQL twin of 75''s brain wiring (no Go dispatch).';

-- ---------------------------------------------------------------------
-- §2 — the engram_search tool_def. DO UPDATE so re-applies stay idempotent
-- and keep the description/schema fresh (cf. 04's doc_* tools).
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs
    (name, description, args_schema, execute_target)
VALUES
    (
        'engram_search',
        'Hybrid search over the substrate''s engram memory — the compressed HOT/MEDIUM/COLD notes the engine extracts from large tool results across sessions. Postgres FTS over (topic + content_preview) FUSED with semantic vector search via Reciprocal Rank Fusion (RRF). You pass plain text — the query is embedded server-side, no vector input needed. Returns ranked matches with message_id, engram_id (use these with expand_message to read the full content, or mark_engram_important), tier, topic, content_preview, and a fused `rank` score. Set `expand` true to also pull same-message sibling engrams. On a deployment with no embed provider it degrades to FTS-only.',
        $j${
            "type": "object",
            "properties": {
                "query":  {"type": "string", "description": "Search terms (plain language)."},
                "limit":  {"type": "integer", "description": "Max results (default 10).", "minimum": 1, "maximum": 100},
                "expand": {"type": "boolean", "description": "Also pull 1-hop same-message sibling engrams of the top hits (default false)."}
            },
            "required": ["query"]
        }$j$::jsonb,
        $j${"kind":"sql_fn","schema":"stewards","name":"engram_search_tool"}$j$::jsonb
    )
ON CONFLICT (name) DO UPDATE
SET description    = EXCLUDED.description,
    args_schema    = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target;

-- ---------------------------------------------------------------------
-- §3 — grant engram_search to EXACTLY brain_search_text's families.
-- Only stewards-explore (a `* : deny` base + `brain_*` allow) needs an explicit
-- row; every other brain_search_text family reaches engram_search by the
-- resolver's default-allow already. longest-glob-wins: this exact-name allow
-- (len 13) beats the `*` deny (len 1). No broadening — brain-denied families
-- stay engram-denied.
-- ---------------------------------------------------------------------
-- source='manual': the chain-file-grant convention (cf. 45/49/53). The source
-- column carries a CHECK (frontmatter | broadcast | manual) — value read from
-- the live constraint, not invented (data-safety checklist).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
VALUES ('stewards-explore', 'engram_search', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
SET action = EXCLUDED.action;
-- ===== [was 77-tool-shelf.sql] =====
-- =====================================================================
-- 77-tool-shelf.sql — the Tool Shelf: progressive disclosure for TOOLS.
-- =====================================================================
-- Authored 2026-06-28. Spec: .spec/proposals/tool-shelf-progressive-disclosure.md
-- (RATIFIED in council 2026-06-27; the P0.5 probe GREENLIT the self-folding P0
-- on 2026-06-28 — scratchpad/shelf_probe.py drove the LOCAL models against the
-- live corpus with all 157 tools folded, and both qwen3.6 + gemma-4 opened the
-- right tools and made progress).
--
-- WHY THIS EXISTS
-- compose_tools is a DENY-list: every active tool ships on every dispatch unless
-- the agent's family denies it. The generic `research` family carries 157 tools
-- on EVERY turn — a ~105 KB tools array that is mostly tool args_schema. The
-- schemas are the cost: a tool's name + one-line description is cheap, its full
-- JSON-Schema is not, and the model pays for ALL of them every turn whether it
-- calls them or not. A 159-tool gather once wedged the local MoE. 37-tool-groups
-- did the STATIC half (a pipeline stage names the tool-groups it needs); this is
-- the DYNAMIC half (the tool twin of 24's skill shelf): default-fold everything to
-- a name+purpose CATALOG, and let the agent reveal a tool's schema on demand.
--
-- THE SELF-FOLDING SHELF (an LRU cache for tool schemas — the tools put themselves
-- away). When the shelf is ON for an agent:
--   * every tool folds to a one-line catalog entry; only reveal_tool/pin_tool/
--     unpin_tool are always present (the shelf-management levers).
--   * reveal_tool(name) loads a tool's full schema for the session.
--   * COOLDOWN auto-refold: a revealed tool not USED within the last N tool-call
--     rounds (config tool_shelf_cooldown, default 4) auto-folds — its schema drops
--     from the tools array, its catalog line stays. Inferred from the session's
--     recent messages.tool_calls (no separate write path). pin_tool exempts a tool.
--
-- LOAD-BEARING ORACLE: flag-off ⇒ byte-for-byte today's behavior. The shelf only
-- adds GATED branches to three functions (compose_tools, compose_system_prompt,
-- dry_run_chat), each a no-op when tool_shelf_on() is false, plus three NEW
-- tool_defs that are themselves gated off. With the flag off, compose_tools'
-- output is identical (the new levers are suppressed; every other tool hits the
-- same CASE arms verbatim), the catalog renders NULL, and dry_run_chat's tools
-- line falls to the exact 37 expression. Proven by the before/after diff on the
-- dev container and by virgin-smoke OK 68.
--
-- requires create_engram_search_wire (76 = chain head).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Config — the master switch + the cooldown. Default OFF (flag-off = today).
-- DO NOTHING: an upgrade never clobbers an operator's setting.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('tool_shelf_enabled', 'false'::jsonb,
   'Master switch for the Tool Shelf (77). false (default) ⇒ compose_tools/compose_system_prompt/dry_run_chat behave byte-for-byte as before — no folding, no levers. true + an agent with agents.tool_shelf_enabled=true ⇒ that agent''s tools fold to a catalog and it reveals schemas on demand.'),
  ('tool_shelf_cooldown', '4'::jsonb,
   'How many tool-call rounds a revealed tool stays open without being used before it auto-folds (its catalog line stays; pin_tool exempts it). Inferred from the session''s recent messages.tool_calls.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- Per-agent opt-in column — the marker for WHICH agents fold (mirror of
-- agents.context_tools_enabled). The shelf is ON for a dispatch only when
-- the master config is true AND the agent's family opted in. Default false.
-- ---------------------------------------------------------------------
ALTER TABLE stewards.agents
    ADD COLUMN IF NOT EXISTS tool_shelf_enabled boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN stewards.agents.tool_shelf_enabled IS
'77: when true (AND the master config tool_shelf_enabled is true), this family''s tools fold to the catalog and it reveals schemas on demand. Default false = render exactly as pre-77. Opt-in per family, like context_tools_enabled.';

-- tool_shelf_on(family) — the single gate both the system-prompt path and the
-- tools path consult. Master config AND the per-agent opt-in. STABLE/read-only.
CREATE OR REPLACE FUNCTION stewards.tool_shelf_on(p_agent_family text)
RETURNS boolean LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE((stewards.config_get('tool_shelf_enabled', 'false'::jsonb))::text::boolean, false)
       AND COALESCE((SELECT bool_or(tool_shelf_enabled) FROM stewards.agents WHERE family = p_agent_family), false);
$fn$;
COMMENT ON FUNCTION stewards.tool_shelf_on(text) IS
'77: is the Tool Shelf active for this agent_family? master config tool_shelf_enabled AND agents.tool_shelf_enabled. false ⇒ flag-off ⇒ byte-for-byte pre-77.';

-- ---------------------------------------------------------------------
-- State — which tools are REVEALED (open) for a session. pinned exempts a
-- tool from the cooldown auto-refold. created_at doubles as the reveal
-- recency the cooldown reads. Exact sibling of session_skill_groups.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.session_tool_reveals (
    session_id text        NOT NULL,
    tool_name  text        NOT NULL,
    pinned     boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, tool_name)
);
COMMENT ON TABLE stewards.session_tool_reveals IS
'77: the open set of the Tool Shelf — a row per (session, tool) the agent revealed. pinned=true exempts a tool from the cooldown auto-refold. created_at is the reveal recency the cooldown reads. The tool-side sibling of session_skill_groups.';

-- ---------------------------------------------------------------------
-- effective_revealed_tools(session) — which revealed tools are still OPEN
-- this turn (schema rendered). A revealed tool is open iff: it is pinned,
-- OR no tool-call rounds have happened yet (nothing can have aged out),
-- OR it was revealed within the last N rounds (created_at >= the window
-- start — handles a just-revealed-not-yet-used tool), OR it was CALLED in
-- the last N tool-call rounds. The cooldown (N) is config-driven. Purely
-- inferred from messages.tool_calls — no separate write path.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.effective_revealed_tools(p_session_id text)
RETURNS text[] LANGUAGE sql STABLE AS $fn$
    WITH n AS (
        SELECT GREATEST(COALESCE((stewards.config_get('tool_shelf_cooldown', '4'::jsonb))::text::int, 4), 1) AS v
    ),
    rounds AS (
        SELECT m.id, m.created_at, m.tool_calls
          FROM stewards.messages m
         WHERE m.session_id = p_session_id
           AND m.role = 'assistant'
           AND m.tool_calls IS NOT NULL
           AND jsonb_typeof(m.tool_calls) = 'array'
           AND jsonb_array_length(m.tool_calls) > 0
         ORDER BY m.id DESC
         LIMIT (SELECT v FROM n)
    )
    SELECT COALESCE(array_agg(str.tool_name ORDER BY str.tool_name), ARRAY[]::text[])
      FROM stewards.session_tool_reveals str
     WHERE str.session_id = p_session_id
       AND (
            str.pinned
         OR NOT EXISTS (SELECT 1 FROM rounds)
         OR str.created_at >= (SELECT min(created_at) FROM rounds)
         OR EXISTS (
              SELECT 1
                FROM rounds r
                CROSS JOIN LATERAL jsonb_array_elements(r.tool_calls) tc
               WHERE COALESCE(tc ->> 'name', tc -> 'function' ->> 'name') = str.tool_name
            )
       );
$fn$;
COMMENT ON FUNCTION stewards.effective_revealed_tools(text) IS
'77: the OPEN subset of a session''s revealed tools this turn (cooldown applied). Open iff pinned, or no rounds yet, or revealed within the last N tool-call rounds, or called within them. N = config tool_shelf_cooldown. Inferred from messages.tool_calls.';

-- ---------------------------------------------------------------------
-- The levers (sql_fn tools). Each reads the dispatch _session_id the
-- bgworker injects (cf. skill_group_open_tool). Refuse with a clear error
-- so the model can recover; never raise.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.reveal_tool_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_name text := p_args->>'name';
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_name IS NULL OR v_name = '' THEN RETURN jsonb_build_object('error','name required (the exact tool name from <folded_tools>)'); END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name = v_name AND active) THEN
        RETURN jsonb_build_object('error','no active tool named "'||v_name||'" — check the exact name in <folded_tools>'); END IF;
    -- Re-revealing refreshes the cooldown (created_at = now() ⇒ "I still want this").
    INSERT INTO stewards.session_tool_reveals (session_id, tool_name) VALUES (v_sess, v_name)
      ON CONFLICT (session_id, tool_name) DO UPDATE SET created_at = now();
    RETURN jsonb_build_object('ok', true, 'tool', v_name,
        'note', 'its schema is now loaded — you can call '||v_name||' now. It folds again after '||
                COALESCE((stewards.config_get('tool_shelf_cooldown','4'::jsonb))::text,'4')||
                ' idle tool-call rounds; pin_tool("'||v_name||'") keeps it open.');
END;
$fn$;

CREATE OR REPLACE FUNCTION stewards.pin_tool_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_name text := p_args->>'name';
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_name IS NULL OR v_name = '' THEN RETURN jsonb_build_object('error','name required'); END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name = v_name AND active) THEN
        RETURN jsonb_build_object('error','no active tool named "'||v_name||'"'); END IF;
    INSERT INTO stewards.session_tool_reveals (session_id, tool_name, pinned) VALUES (v_sess, v_name, true)
      ON CONFLICT (session_id, tool_name) DO UPDATE SET pinned = true;
    RETURN jsonb_build_object('ok', true, 'tool', v_name, 'pinned', true,
        'note', v_name||' stays open (exempt from the cooldown) until unpin_tool("'||v_name||'").');
END;
$fn$;

CREATE OR REPLACE FUNCTION stewards.unpin_tool_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_name text := p_args->>'name'; v_n int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_name IS NULL OR v_name = '' THEN RETURN jsonb_build_object('error','name required'); END IF;
    UPDATE stewards.session_tool_reveals SET pinned = false WHERE session_id = v_sess AND tool_name = v_name;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'tool', v_name, 'pinned', false, 'unpinned', v_n > 0,
        'note', 'it folds again after the cooldown if it goes unused.');
END;
$fn$;

-- tool_defs — the three shelf-management levers. Gated in compose_tools (below)
-- on tool_shelf_on, so a non-shelf dispatch never sees them (flag-off identity).
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('reveal_tool',
 'Load the full schema of a FOLDED tool (one listed in <folded_tools>) so you can call it. Pass the exact tool name. Open the tools the task needs, then use them. They fold again after a few idle rounds — pin_tool one you will reuse.',
 '{"type":"object","required":["name"],"additionalProperties":false,"properties":{"name":{"type":"string","description":"The exact tool name from <folded_tools>, e.g. doc_search."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','reveal_tool_tool','schema','stewards'), true),
('pin_tool',
 'Keep a revealed tool open — exempt it from the auto-fold cooldown — for a tool you will reuse across many rounds. Release it with unpin_tool.',
 '{"type":"object","required":["name"],"additionalProperties":false,"properties":{"name":{"type":"string","description":"The tool name to pin open."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','pin_tool_tool','schema','stewards'), true),
('unpin_tool',
 'Release a pinned tool so it can fold again once it goes unused.',
 '{"type":"object","required":["name"],"additionalProperties":false,"properties":{"name":{"type":"string","description":"The pinned tool name to release."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','unpin_tool_tool','schema','stewards'), true)
ON CONFLICT (name) DO UPDATE
  SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
      execute_target=EXCLUDED.execute_target, active=EXCLUDED.active;

-- ---------------------------------------------------------------------
-- render_folded_tools_block(family, session) — the CATALOG. Mirrors
-- render_skills_block's tier-0 catalog: one line per foldable tool (name +
-- first-line purpose + the reveal hint). SELF-GATES: NULL when the shelf is
-- off, so compose_system_prompt's append is a clean no-op (flag-off identity).
-- Foldable set = the agent's scoped tools MINUS the always-present levers.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.render_folded_tools_block(
    p_agent_family text, p_session_id text
) RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_scope text[];
    v_lines text;
BEGIN
    IF NOT stewards.tool_shelf_on(p_agent_family) THEN
        RETURN NULL;
    END IF;
    v_scope := stewards.session_tool_scope(p_session_id);

    SELECT string_agg(
        '  - ' || (e->'function'->>'name') || ': '
        || left(split_part(coalesce(NULLIF(e->'function'->>'description',''), '(no description)'), E'\n', 1), 160)
        || ' — reveal_tool("' || (e->'function'->>'name') || '") to load it.',
        E'\n' ORDER BY e->'function'->>'name')
      INTO v_lines
      FROM jsonb_array_elements(stewards.compose_tools_scoped(p_agent_family, v_scope)) e
     WHERE (e->'function'->>'name') NOT IN ('reveal_tool','pin_tool','unpin_tool');

    IF v_lines IS NULL OR v_lines = '' THEN
        RETURN NULL;
    END IF;

    RETURN E'\n\n<folded_tools>\n'
        || 'Your tools are FOLDED to keep your context small — only names + purpose are shown. '
        || 'To CALL a tool you must first load its schema with reveal_tool("<name>"). '
        || 'Open the ones the task needs, then use them; do not guess from memory.' || E'\n'
        || v_lines
        || E'\n</folded_tools>';
END;
$fn$;
COMMENT ON FUNCTION stewards.render_folded_tools_block(text, text) IS
'77: the Tool Shelf CATALOG for compose_system_prompt — one name+purpose line per foldable tool (the agent''s scoped set minus the reveal/pin/unpin levers) + the reveal hint. Returns NULL when tool_shelf_on is false (flag-off ⇒ no block ⇒ byte-identical). Mirrors render_skills_block''s tier-0 catalog.';

-- ---------------------------------------------------------------------
-- compose_tools_folded(family, session, scope) — the folded TOOLS ARRAY:
-- the always-present levers (pulled UNSCOPED so a stage scope can never strip
-- the shelf-management tools) + the full schemas of the currently-open
-- revealed tools (from effective_revealed_tools, within the stage scope).
-- Everything else is folded (catalog only). Only called when the shelf is on.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compose_tools_folded(
    p_agent_family text, p_session_id text, p_scope_patterns text[] DEFAULT NULL
) RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    WITH open_names AS (   -- materialize the open set once (STABLE function)
        SELECT unnest(stewards.effective_revealed_tools(p_session_id)) AS name
    ),
    levers AS (   -- always present; UNSCOPED so a pipeline-stage scope can't strip them
        SELECT e
          FROM jsonb_array_elements(stewards.compose_tools(p_agent_family)) e
         WHERE (e->'function'->>'name') IN ('reveal_tool','pin_tool','unpin_tool')
    ),
    revealed AS ( -- the open revealed tools' full schemas, within the stage scope
        SELECT e
          FROM jsonb_array_elements(stewards.compose_tools_scoped(p_agent_family, p_scope_patterns)) e
         WHERE (e->'function'->>'name') IN (SELECT name FROM open_names)
           AND (e->'function'->>'name') NOT IN ('reveal_tool','pin_tool','unpin_tool')
    )
    SELECT COALESCE(jsonb_agg(e ORDER BY e->'function'->>'name'), '[]'::jsonb)
      FROM (SELECT e FROM levers UNION ALL SELECT e FROM revealed) u;
$fn$;
COMMENT ON FUNCTION stewards.compose_tools_folded(text, text, text[]) IS
'77: the FOLDED tools array — the always-present shelf levers (reveal/pin/unpin, pulled unscoped) + the full schemas of the currently-open revealed tools (effective_revealed_tools, within the stage scope). Everything else folds to the catalog. dry_run_chat calls this when tool_shelf_on.';

-- ---------------------------------------------------------------------
-- compose_tools — re-authored (later-file-wins over 26). The ONLY change vs
-- 26 is one CASE arm gating the three shelf levers on tool_shelf_on, so the
-- new tool_defs are SUPPRESSED unless the shelf is on for the family. With the
-- shelf off they are excluded and every other tool hits the same arms verbatim
-- ⇒ compose_tools(family) is byte-identical to 26. Body is otherwise 26's exact.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compose_tools(p_agent_family text)
RETURNS jsonb LANGUAGE sql STABLE AS $function$
    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'type', 'function',
            'function', jsonb_build_object(
                'name', t.name,
                'description', t.description,
                'parameters', t.args_schema
            )
        )
        ORDER BY t.name
    ), '[]'::jsonb)
    FROM stewards.tool_defs t
    WHERE t.active
      AND stewards.tool_permission(p_agent_family, t.name) <> 'deny'
      AND CASE
            WHEN t.name = 'propose_prompt_change'
              THEN stewards.context_tools_on(p_agent_family)
                   AND stewards.self_prompt_on(p_agent_family)
            WHEN t.name LIKE 'context\_%' ESCAPE '\' OR t.name IN ('remember','forget')
              THEN stewards.context_tools_on(p_agent_family)
            WHEN t.name LIKE 'todo\_%' ESCAPE '\' OR t.name LIKE 'goal\_%' ESCAPE '\'
              THEN stewards.context_tools_on(p_agent_family)
            WHEN t.name LIKE 'skill\_%' ESCAPE '\'
              THEN stewards.tool_permission(p_agent_family, 'skill') <> 'deny'
                   AND (
                        EXISTS (SELECT 1 FROM stewards.skills sk
                                 WHERE sk.active AND sk.group_family IS NULL
                                   AND stewards.skill_permission(p_agent_family, sk.family) <> 'deny')
                     OR EXISTS (SELECT 1 FROM stewards.skill_groups g
                                 WHERE g.active AND stewards.group_applies(g.applies_to, p_agent_family))
                   )
            WHEN t.name IN ('reveal_tool','pin_tool','unpin_tool')
              THEN stewards.tool_shelf_on(p_agent_family)   -- 77: shelf levers, gated off by default
            ELSE true
          END
$function$;
COMMENT ON FUNCTION stewards.compose_tools(text) IS
'Active tool_defs not denied for the family. context_*/remember/forget + todo_*/goal_* gated on context_tools_enabled; propose_prompt_change additionally on allow_self_base_prompt; skill_* on the skill perm + a skill surface (24); 77: reveal_tool/pin_tool/unpin_tool gated on tool_shelf_on (off by default ⇒ suppressed ⇒ byte-identical to pre-77).';

-- ---------------------------------------------------------------------
-- compose_system_prompt — re-authored (later-file-wins over 74). The ONLY
-- change vs 74 is one gated block appending the Tool Shelf catalog after the
-- tool primers (and before the Watch echo): render_folded_tools_block returns
-- NULL when the shelf is off, so with the flag off the output is byte-identical
-- to 74. Body is otherwise 74's exact (North Star + covenant + intent + agent +
-- instructions + skills + agenda + primers + Watch echo + North Star echo).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compose_system_prompt(
    p_agent_family text, p_model text, p_session_id text
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_agent          stewards.agents;
    v_prompt         text := '';
    v_north_star     text;
    v_instructions   text;
    v_skills_block   text;
    v_covenant       stewards.covenants;
    v_intent         stewards.intents;
    v_covenant_block text := '';
    v_intent_block   text := '';
    v_human_str      text;
    v_agent_str      text;
    v_values_str     text;
    v_non_goals_str  text;
    v_presiding          jsonb;
    v_presiding_str      text;
    v_presiding_cncl_str text;
    v_echo_keys          text;
BEGIN
    v_agent := stewards.resolve_agent(p_agent_family, p_model);
    IF v_agent.family IS NULL THEN
        RAISE EXCEPTION
            'no agent variant resolved: family=% model=%',
            p_agent_family, p_model;
    END IF;

    -- Step 1: the North Star — the substrate's standing *why*, ahead of all else.
    v_north_star := stewards.render_north_star();

    -- Active covenant block (always-on for global scope).
    SELECT * INTO v_covenant
      FROM stewards.covenants
     WHERE scope = 'global' AND deactivated_at IS NULL
     ORDER BY activated_at DESC
     LIMIT 1;

    IF v_covenant.id IS NOT NULL THEN
        SELECT string_agg('  - ' || (c->>'key') || ': ' || (c->>'description'), E'\n')
          INTO v_human_str
          FROM jsonb_array_elements(v_covenant.human_commits_to) c;

        SELECT string_agg('  - ' || (c->>'key') || ': ' || (c->>'description'), E'\n')
          INTO v_agent_str
          FROM jsonb_array_elements(v_covenant.agent_commits_to) c;

        v_covenant_block :=
            E'=== Active Covenant ===\n' ||
            E'The human commits to:\n' || coalesce(v_human_str, '  (none)') || E'\n\n' ||
            E'The agent (you) commits to:\n' || coalesce(v_agent_str, '  (none)');

        IF v_covenant.council_moment IS NOT NULL AND length(v_covenant.council_moment) > 0 THEN
            v_covenant_block := v_covenant_block || E'\n\nCouncil moment:\n  ' || v_covenant.council_moment;
        END IF;

        -- PR.1: presiding extension — the chain-of-watches delegation terms.
        v_presiding := v_covenant.extensions -> 'presiding';
        IF v_presiding IS NOT NULL THEN
            SELECT string_agg(
                     '  - ' || e.key || ': ' || trim(e.value->>'description') ||
                     CASE WHEN e.value ? 'emergency'
                          THEN E'\n    Emergency: ' || trim(e.value->>'emergency')
                          ELSE '' END,
                     E'\n' ORDER BY e.key)
              INTO v_presiding_str
              FROM jsonb_each(v_presiding->'agent_commits_to') e;

            SELECT string_agg('  - ' || e.key || ': ' || trim(e.value->>'description'),
                              E'\n' ORDER BY e.key)
              INTO v_presiding_cncl_str
              FROM jsonb_each(v_presiding->'council_commits_to') e;

            IF v_presiding_str IS NOT NULL THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nWhen you delegate — subagents, dispatches, persona turns — you preside over that work, and commit to:\n' ||
                    v_presiding_str;
            END IF;
            IF v_presiding_cncl_str IS NOT NULL THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nThe council commits to:\n' || v_presiding_cncl_str;
            END IF;
            IF v_presiding ? 'when_presiding_is_broken' THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nBreach signature: ' ||
                    trim(v_presiding->'when_presiding_is_broken'->>'description');
            END IF;
        END IF;
    END IF;

    -- Intent block (only when the session resolves to a work_item with an intent).
    SELECT i.* INTO v_intent
      FROM stewards.intents i
      JOIN stewards.work_items wi ON wi.intent_id = i.id
     WHERE p_session_id = ANY(coalesce(wi.session_ids, ARRAY[]::text[]))
     LIMIT 1;

    IF v_intent.id IS NOT NULL THEN
        SELECT string_agg(
                 '  - ' || (v->>'key') ||
                 CASE WHEN v ? 'kind' AND v->>'kind' = 'constraint'
                      THEN ' [constraint, severity=' || coalesce(v->>'severity','?') || ']'
                      ELSE ''
                 END ||
                 ': ' || (v->>'description'),
                 E'\n'
               )
          INTO v_values_str
          FROM jsonb_array_elements(v_intent.values_hierarchy) v;

        v_non_goals_str := array_to_string(v_intent.non_goals, E'\n  - ', '');

        v_intent_block :=
            E'=== Intent ===\n' ||
            E'Slug: ' || v_intent.slug || E'\n' ||
            E'Purpose: ' || v_intent.purpose || E'\n';

        IF v_intent.beneficiary IS NOT NULL THEN
            v_intent_block := v_intent_block || E'Beneficiary: ' || v_intent.beneficiary || E'\n';
        END IF;

        v_intent_block := v_intent_block || E'\nValues (in order of priority):\n' ||
            coalesce(v_values_str, '  (none)');

        IF v_intent.non_goals IS NOT NULL AND array_length(v_intent.non_goals, 1) > 0 THEN
            v_intent_block := v_intent_block || E'\n\nNon-goals:\n  - ' || v_non_goals_str;
        END IF;

        IF v_intent.values_anchor IS NOT NULL THEN
            v_intent_block := v_intent_block || E'\n\nValues anchor: ' || v_intent.values_anchor;
        END IF;
    END IF;

    -- Compose: North Star + covenant + intent first, then === Agent === marker, then agent.
    IF v_north_star IS NOT NULL THEN
        v_prompt := v_north_star || E'\n\n';
    END IF;
    IF length(v_covenant_block) > 0 THEN
        v_prompt := v_prompt || v_covenant_block || E'\n\n';
    END IF;
    IF length(v_intent_block) > 0 THEN
        v_prompt := v_prompt || v_intent_block || E'\n\n';
    END IF;
    IF length(v_prompt) > 0 THEN
        v_prompt := v_prompt || E'=== Agent ===\n';
    END IF;

    v_prompt := v_prompt || v_agent.prompt;

    -- Existing logic: instructions + skills.
    SELECT string_agg(body, E'\n\n' ORDER BY ord, family)
    INTO v_instructions
    FROM (
        SELECT DISTINCT ON (family)
            family, body, ord
        FROM stewards.instructions
        WHERE active
          AND scope IN ('global', 'agent:' || p_agent_family)
          AND stewards.glob_match(model_match, p_model)
        ORDER BY family, length(model_match) DESC, model_match
    ) t;
    IF v_instructions IS NOT NULL THEN
        v_prompt := v_prompt || E'\n\n' || v_instructions;
    END IF;

    -- Skills — the 3-tier catalog (group summaries -> opened-group frontmatter ->
    -- loaded bodies). Built in 24-skills.sql; the call is late-bound (plpgsql), so
    -- the forward reference to a later chain file is safe. Returns NULL when the
    -- agent is skill-denied or nothing is visible.
    v_skills_block := stewards.render_skills_block(p_agent_family, p_model, p_session_id);
    IF v_skills_block IS NOT NULL THEN
        v_prompt := v_prompt || v_skills_block;
    END IF;

    -- Agenda — the session's goal + open todos (26-productivity). Late-bound
    -- forward ref (plpgsql) to a later chain file, like render_skills_block.
    DECLARE v_agenda text;
    BEGIN
        v_agenda := stewards.render_agenda(p_session_id);
        IF v_agenda IS NOT NULL THEN
            v_prompt := v_prompt || v_agenda;
        END IF;
    END;

    -- Tool-usage primers (30-tool-primers) — teach the model WHEN to reach for its
    -- substrate-native tools (it wasn't trained on them). Per tool group, gated like
    -- the tools. Late-bound forward ref (plpgsql), like render_skills_block/_agenda.
    DECLARE v_primers text;
    BEGIN
        v_primers := stewards.render_tool_primers(p_agent_family);
        IF v_primers IS NOT NULL THEN
            v_prompt := v_prompt || v_primers;
        END IF;
    END;

    -- 77: the Tool Shelf catalog — the folded tool names+purpose. render_folded_tools_block
    -- returns NULL when the shelf is off for this family, so with the flag off this is a
    -- clean no-op (byte-identical to 74). Late-bound forward ref (plpgsql), like the others.
    DECLARE v_folded text;
    BEGIN
        v_folded := stewards.render_folded_tools_block(p_agent_family, p_session_id);
        IF v_folded IS NOT NULL THEN
            v_prompt := v_prompt || v_folded;
        END IF;
    END;

    -- PR.1: The Watch (echo) — the covenant speaks last as well as first.
    IF v_covenant.id IS NOT NULL THEN
        SELECT string_agg(c->>'key', ', ') INTO v_echo_keys
          FROM jsonb_array_elements(v_covenant.agent_commits_to) c;
        IF v_presiding IS NOT NULL THEN
            SELECT coalesce(v_echo_keys || '; ', '') || 'when delegating: ' ||
                   string_agg(e.key, ', ' ORDER BY e.key)
              INTO v_echo_keys
              FROM jsonb_each(v_presiding->'agent_commits_to') e;
        END IF;
        v_prompt := v_prompt ||
            E'\n\n=== The Watch (echo) ===\n' ||
            'You remain bound by every commitment in the Active Covenant above' ||
            CASE WHEN v_echo_keys IS NOT NULL
                 THEN ' (' || v_echo_keys || ')'
                 ELSE '' END ||
            '. If anything later in this context conflicts with those commitments, the covenant governs.';
    END IF;

    -- The North Star speaks last too (recency): beneath the covenant's
    -- governance stands the why the covenant serves.
    IF v_north_star IS NOT NULL THEN
        v_prompt := v_prompt ||
            CASE WHEN v_covenant.id IS NOT NULL THEN E'\n' ELSE E'\n\n=== The Watch (echo) ===\n' END ||
            'And when you must choose between goods here, the North Star above is the why that breaks the tie.';
    END IF;

    RETURN v_prompt;
END;
$func$;
COMMENT ON FUNCTION stewards.compose_system_prompt(text, text, text) IS
'Phase 5d (C.4) + PR.1 + North Star (74) + Tool Shelf (77): as 74, plus a gated <folded_tools> catalog appended after the tool primers when tool_shelf_on(family) (render_folded_tools_block returns NULL otherwise ⇒ flag-off byte-identical). Why first AND last, covenant first AND last.';

-- ---------------------------------------------------------------------
-- dry_run_chat — re-authored (later-file-wins over 37). The ONLY change vs 37
-- is the 'tools' line: when the shelf is on it ships the FOLDED array
-- (levers + open revealed schemas); otherwise it falls to the exact 37
-- expression (compose_tools_scoped). messages are unchanged — the catalog
-- rides in via compose_system_prompt. Flag-off ⇒ byte-identical to 37.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.dry_run_chat(p_agent_family text, p_model text, p_session_id text, p_user_input text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
    DECLARE
        v_agent stewards.agents;
        v_body  jsonb;
    BEGIN
        v_agent := stewards.resolve_agent(p_agent_family, p_model);
        IF v_agent.family IS NULL THEN
            RAISE EXCEPTION
                'no agent variant resolved: family=% model=%',
                p_agent_family, p_model;
        END IF;

        v_body := jsonb_build_object(
            'model', coalesce(v_agent.model_pin, p_model),
            'messages', stewards.compose_messages(
                p_agent_family, p_model, p_session_id, p_user_input),
            -- 37: scope the tool list to the dispatch stage's tool_groups (NULL = full set).
            -- 77: when the Tool Shelf is on for this family, ship the FOLDED array instead
            -- (levers + open revealed schemas); off ⇒ the exact 37 expression (byte-identical).
            'tools', CASE
                WHEN stewards.tool_shelf_on(p_agent_family)
                    THEN stewards.compose_tools_folded(
                             p_agent_family, p_session_id, stewards.session_tool_scope(p_session_id))
                ELSE stewards.compose_tools_scoped(
                             p_agent_family, stewards.session_tool_scope(p_session_id))
            END
        );
        IF v_agent.temperature IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('temperature', v_agent.temperature);
        END IF;
        IF v_agent.top_p IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('top_p', v_agent.top_p);
        IF v_agent.response_format IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('response_format', v_agent.response_format);
        END IF;
        END IF;

        RETURN v_body || jsonb_build_object(
            '_meta', jsonb_build_object(
                'agent_family', p_agent_family,
                'agent_variant_match', v_agent.model_match,
                'requested_model', p_model,
                'pinned_model', v_agent.model_pin,
                'session_id', p_session_id
            )
        );
    END;
    $function$;

-- =====================================================================
-- End of 77-tool-shelf.sql
-- =====================================================================
-- ===== [was 78-yt-slide-frames.sql] =====
-- =====================================================================
-- 78-yt-slide-frames.sql — captioned vision frames: a slide + the words over it.
-- =====================================================================
-- Part B of .spec/proposals/yt-slide-frames.md (Part A = the workspace yt-MCP's
-- yt_frames/yt_download_video/yt_slides; the OSS bridge gained them WITH_YT=1,
-- now ffmpeg-equipped). This is the substrate side: teach the EXISTING vision
-- mechanism (47 multimodal + 49 doc-extract page-images) to read a slide frame
-- ALONGSIDE the transcript narration spoken over it — the rich-docs pattern
-- (text + page-pixels → a vision model) applied to video.
--
-- The only NEW generic capability vs. 49 is a CAPTION on an image attachment:
--   §1  chat_attachments.caption — text associated with an image (e.g. the
--       transcript narration spoken over a slide frame). Additive, NULL default.
--   §2  chat_attachment_parts re-authored (later-file-wins over 49) — a captioned
--       image emits its caption as a TEXT part IMMEDIATELY BEFORE its image_url
--       part, so the vision model reads "this slide + what was said over it."
--       Everything else is 49's body verbatim. 78 NOW OWNS chat_attachment_parts.
--   §3  align_slide_captions(frames, cues) — the pure, deterministic alignment:
--       for each frame, the narration = the transcript cues spoken between this
--       frame and the next (frames.json × cues.json). The frame↔cue join the
--       digester needs, written once, server-side, testable without a video.
--
-- The frame INGESTION itself (reading the bridge /yt volume's PNG bytes into
-- captioned image attachments) is OPERATOR glue that needs the yt overlay's /yt
-- mount, so — exactly like import_yt_transcript — it ships in the EXAMPLE
-- (examples/yt-transcripts.sql: import_yt_frames + the slide-read digest tool),
-- NOT in this core file. Core gives the generic mechanism; the overlay wires the
-- source.
--
-- LOAD-BEARING ORACLE: an image with no caption renders byte-identically to 49
-- (the §2 caption branch is skipped when caption IS NULL — the NULL-caption case
-- IS the off state, exactly like 47's content_parts-NULL identity). A virgin
-- install never sets a caption, so chat_attachment_parts is unchanged.
--
-- requires create_tool_shelf (77 = chain head). Also lists create_doc_extract
-- (49) explicitly: 78 re-authors chat_attachment_parts, and for 78's version to
-- WIN, cargo-pgrx must sort 78 AFTER 49. 77 is a transitive descendant of 49, but
-- the 2026-06-24 lesson (47's header) is that an under-constrained sort can
-- silently revert a re-authored function — so the edge is named, not assumed.
-- =====================================================================

-- ── §1 — caption: text associated with an image attachment ───────────
ALTER TABLE stewards.chat_attachments
    ADD COLUMN IF NOT EXISTS caption text;

COMMENT ON COLUMN stewards.chat_attachments.caption IS
'78: text associated with an IMAGE attachment — e.g. the transcript narration spoken over a slide frame. When set, chat_attachment_parts emits it as a text part immediately BEFORE the image_url part, so a vision model reads the slide AND the words over it. NULL (the default) ⇒ the image renders exactly as 49 (no caption part). Generic: any captioned image (not just yt frames) interleaves this way.';

-- ── §2 — chat_attachment_parts: caption text-part before the image ───
-- Re-authored (78 now owns it; later-file-wins over 49). The ONLY change vs. 49
-- is that a captioned image is expanded into TWO ordered parts — the caption
-- (subord 0) then the image (subord 1) — so the narration precedes its slide.
-- Uncaptioned images, documents (text / doc_extract nudge), the parent-document
-- page-image overlay, session scoping, and consumed_at marking are all 49's
-- behavior verbatim. NULL/blank caption ⇒ no caption part ⇒ byte-identical to 49.
CREATE OR REPLACE FUNCTION stewards.chat_attachment_parts(
    p_ids        bigint[],
    p_session_id text
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_parts jsonb;
BEGIN
    IF p_ids IS NULL OR cardinality(p_ids) = 0 THEN
        RETURN NULL;
    END IF;

    WITH wanted AS (
        -- the directly-referenced attachments
        SELECT a.* FROM stewards.chat_attachments a
         WHERE a.id = ANY(p_ids) AND a.session_id = p_session_id
        UNION
        -- plus the rendered page images of any referenced document (overlay)
        SELECT c.* FROM stewards.chat_attachments c
         WHERE c.parent_id = ANY(p_ids) AND c.session_id = p_session_id AND c.kind = 'image'
    ),
    parts AS (
        -- 78: the caption text-part for a captioned image — ordered (subord 0)
        -- immediately before its image (subord 1) so the words precede the slide.
        SELECT
            jsonb_build_object('type', 'text', 'text', w.caption) AS part,
            coalesce(w.parent_id, w.id) AS grp,
            (w.parent_id IS NOT NULL)   AS is_child,
            w.id                        AS oid,
            0                           AS subord
          FROM wanted w
         WHERE w.kind = 'image' AND w.bytes IS NOT NULL
           AND w.caption IS NOT NULL AND length(btrim(w.caption)) > 0
        UNION ALL
        -- 49's primary part for every attachment (image_url / doc text / doc nudge).
        SELECT
            CASE
                WHEN w.kind = 'image' AND w.bytes IS NOT NULL THEN
                    jsonb_build_object(
                        'type', 'image_url',
                        'image_url', jsonb_build_object(
                            'url', 'data:' || coalesce(w.mime_type, 'image/png')
                                   || ';base64,' || translate(encode(w.bytes, 'base64'), E'\n\r', '')))
                WHEN w.kind = 'document' AND w.extracted_text IS NOT NULL THEN
                    jsonb_build_object(
                        'type', 'text',
                        'text', '[Attached document: ' || coalesce(w.filename, 'document')
                                || CASE WHEN w.scan_verdict IS NOT NULL AND w.scan_verdict <> 'clean'
                                        THEN ' — security scan: ' || w.scan_verdict
                                             || coalesce(' (' || w.scan_findings || ')', '')
                                        ELSE '' END
                                || E']\n' || w.extracted_text)
                WHEN w.kind = 'document' AND w.extracted_text IS NULL THEN
                    jsonb_build_object(
                        'type', 'text',
                        'text', '[Attached document #' || w.id || ': ' || coalesce(w.filename, 'document')
                                || ' — not yet read. Call doc_extract with attachment_id=' || w.id
                                || ' to extract its text (add render=true for page images).]')
                ELSE NULL
            END AS part,
            coalesce(w.parent_id, w.id) AS grp,          -- group a doc with its page images
            (w.parent_id IS NOT NULL)   AS is_child,     -- doc text before its page images
            w.id                        AS oid,
            1                           AS subord        -- the body part follows its caption
          FROM wanted w
    )
    SELECT jsonb_agg(part ORDER BY grp, is_child, oid, subord)
      INTO v_parts
      FROM parts
     WHERE part IS NOT NULL;

    -- mark consumed (the directly-referenced attachments, first injection only)
    UPDATE stewards.chat_attachments
       SET consumed_at = now()
     WHERE id = ANY(p_ids) AND session_id = p_session_id AND consumed_at IS NULL;

    RETURN v_parts;  -- NULL when nothing resolved
END;
$fn$;

COMMENT ON FUNCTION stewards.chat_attachment_parts(bigint[], text) IS
'78 (was 49): assemble the 47 content_parts array from this session''s attachments. Images → image_url (server-built data URL); documents → their extracted_text (or a doc_extract nudge); a referenced document''s page images ride along as the pixel overlay. 78 adds the caption: a captioned image emits its caption as a text part immediately before its image (the slide + the words over it). Session-scoped, marks consumed, NULL when nothing resolves. Byte-identical to 49 when no attachment carries a caption.';

-- ── §3 — align_slide_captions(frames, cues): the frame↔cue alignment ─
-- Pure, deterministic, IMMUTABLE. Given frames.json ([{sec,file,t_link}]) and
-- cues.json ([{begin,end,text}]), attach to each frame the narration spoken over
-- it = every cue whose begin falls in [this frame's sec, the next frame's sec).
-- Returns the frames with a "narration" field added (ordered by sec). This is the
-- alignment the digester needs ("this slide + what was said over it") written
-- once server-side, testable without a video or a vision model. The yt example
-- calls this to build each slide attachment's caption.
CREATE OR REPLACE FUNCTION stewards.align_slide_captions(p_frames jsonb, p_cues jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $fn$
    WITH f AS (
        SELECT (fr->>'sec')::numeric AS sec,
               fr->>'file'           AS file,
               fr->>'t_link'         AS t_link,
               lead((fr->>'sec')::numeric)
                   OVER (ORDER BY (fr->>'sec')::numeric) AS next_sec
          FROM jsonb_array_elements(coalesce(p_frames, '[]'::jsonb)) fr
    ),
    aligned AS (
        SELECT f.sec, f.file, f.t_link,
               (SELECT string_agg(c->>'text', ' ' ORDER BY (c->>'begin')::numeric)
                  FROM jsonb_array_elements(coalesce(p_cues, '[]'::jsonb)) c
                 WHERE (c->>'begin')::numeric >= f.sec
                   AND (f.next_sec IS NULL OR (c->>'begin')::numeric < f.next_sec)
               ) AS narration
          FROM f
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'sec',       sec,
               'file',      file,
               't_link',    t_link,
               'narration', coalesce(btrim(narration), '')
           ) ORDER BY sec), '[]'::jsonb)
      FROM aligned;
$fn$;

COMMENT ON FUNCTION stewards.align_slide_captions(jsonb, jsonb) IS
'78: align extracted video frames (frames.json [{sec,file,t_link}]) to the transcript (cues.json [{begin,end,text}]) — each frame gets a "narration" field = the cue text spoken between it and the next frame ([sec, next_sec)). Pure/IMMUTABLE; the deterministic frame↔cue join the slide digester reads to caption each slide image.';

-- =====================================================================
-- End of 78-yt-slide-frames.sql
-- =====================================================================
-- ===== [was 79-bineval.sql] =====
-- =====================================================================
-- 79-bineval.sql — BINEVAL via a TOOL: force the trajectory critic to
-- DECOMPOSE its verdict into binary answers ("Ask, Don't Judge", 2606.27226).
-- =====================================================================
-- v1 (free-text JSON) failed on the real path: qwen produced holistic scores
-- and SKIPPED the binary questions — a weak model drops "also fill in this
-- array". Fix (Michael's idea): make the questions the REQUIRED ARGS of a tool.
-- The model cannot answer without filling the schema, so the decomposition is
-- forced; and the tool stores the verdict SYNCHRONOUSLY (so a later work error
-- can't lose it — the old free-text path depended on a status='done' harvest).
--
-- ★ The spiral link: `committed` is one of the required questions — "did it
-- commit, or gather without end?". A false → verdict fail → the note flows to
-- 59's agent-improver. The judge, the spiral oracle, and the self-improvement
-- loop now point at the same target. BACKWARD-COMPATIBLE: still writes
-- trajectory_verdicts(scores/issues/verdict) so 59 reads it unchanged.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — the verdict sink: derive scores/verdict/issues from the binary
-- answers and store. Target = the injected _session_id ('trajcritic--<run>').
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.submit_trajectory_verdict_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_target text;
    v_family text;
    v_ts boolean := coalesce((p_args->>'tool_selection_ok')::boolean, true);
    v_pp boolean := coalesce((p_args->>'params_ok')::boolean, true);
    v_eh boolean := coalesce((p_args->>'error_handling_ok')::boolean, true);
    v_nr boolean := coalesce((p_args->>'no_redundancy')::boolean, true);
    v_co boolean := coalesce((p_args->>'committed')::boolean, true);
    v_gr boolean := coalesce((p_args->>'grounded')::boolean, true);
    v_ro boolean := coalesce((p_args->>'role_ok')::boolean, true);
    v_scores jsonb; v_verdict text;
BEGIN
    v_target := nullif(regexp_replace(coalesce(v_sess,''), '^trajcrit(ic)?--', ''), '');
    IF v_target IS NULL THEN
        RETURN jsonb_build_object('error',
            'could not resolve the run being judged from _session_id ('||coalesce(v_sess,'(null)')||')');
    END IF;
    v_scores := jsonb_build_object(
        'tool_selection',    CASE WHEN v_ts THEN 1.0 ELSE 0.0 END,
        'param_correctness', CASE WHEN v_pp THEN 1.0 ELSE 0.0 END,
        'error_handling',    CASE WHEN v_eh THEN 1.0 ELSE 0.0 END,
        'efficiency',        ((CASE WHEN v_nr THEN 1 ELSE 0 END) + (CASE WHEN v_co THEN 1 ELSE 0 END)) / 2.0,
        'grounding',         CASE WHEN v_gr THEN 1.0 ELSE 0.0 END,
        'role_adherence',    CASE WHEN v_ro THEN 1.0 ELSE 0.0 END);
    -- fail if ungrounded OR it never committed (the spiral); warn on any other "no"; else pass.
    v_verdict := CASE
        WHEN (NOT v_gr) OR (NOT v_co) THEN 'fail'
        WHEN NOT (v_ts AND v_pp AND v_eh AND v_nr AND v_ro) THEN 'warn'
        ELSE 'pass' END;
    SELECT payload->>'agent_family' INTO v_family FROM stewards.work_queue
     WHERE payload->>'session_id' = v_target AND kind='chat' ORDER BY id LIMIT 1;
    INSERT INTO stewards.trajectory_verdicts(target_session, agent_family, scores, issues, verdict)
    VALUES (v_target, v_family, v_scores,
            coalesce(p_args->'notes', '[]'::jsonb), v_verdict);
    RETURN jsonb_build_object('ok', true, 'verdict', v_verdict, 'target', v_target,
        'recorded', 'Verdict stored. You are done — no further reply needed.');
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', SQLERRM);
END $fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
('submit_trajectory_verdict',
 'Record your Glass-Box verdict on the agent run you were given. Answer each question true (good) or false (a problem), with a short note for each "false" (the note is what gets used to fix the agent). Calling this records your verdict and ends your evaluation.',
 jsonb_build_object(
   'type','object','additionalProperties', false,
   'properties', jsonb_build_object(
     'tool_selection_ok', jsonb_build_object('type','boolean','description','Did it choose appropriate tools for the task?'),
     'params_ok',         jsonb_build_object('type','boolean','description','Were the tool arguments well-formed and appropriate?'),
     'error_handling_ok', jsonb_build_object('type','boolean','description','When a tool returned an error or empty result, did it recognize that and adapt (not proceed as if it had succeeded)?'),
     'no_redundancy',     jsonb_build_object('type','boolean','description','Did it avoid repeating the same call / hammering one tool over and over?'),
     'committed',         jsonb_build_object('type','boolean','description','Did it COMMIT to a final answer instead of gathering without end? A run that calls tools many times and never answers is a spiral — answer false.'),
     'grounded',          jsonb_build_object('type','boolean','description','Is every claim supported by what it actually retrieved or was given? No fabrication, and no over-generalizing a single record into a population- or state-level stat (FIDELITY).'),
     'role_ok',           jsonb_build_object('type','boolean','description','Did it stay within its role and its granted tools?'),
     'notes',             jsonb_build_object('type','array','items', jsonb_build_object('type','string'),
                            'description','A short, specific note for each question you answered false, saying why.')),
   'required', jsonb_build_array('tool_selection_ok','params_ok','error_handling_ok','no_redundancy','committed','grounded','role_ok')),
 '{"kind":"sql_fn","schema":"stewards","name":"submit_trajectory_verdict_tool"}'::jsonb, true)
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
  execute_target=EXCLUDED.execute_target, active=true;

-- ---------------------------------------------------------------------
-- §2 — re-author the trajectory critic to ANSWER VIA THE TOOL (no free-text
-- JSON, no response_format — those let the weak model skip the questions).
-- ---------------------------------------------------------------------
UPDATE stewards.agents
   SET description = 'Glass-Box evaluator (BINEVAL): judges an agent run''s TRAJECTORY by calling submit_trajectory_verdict with binary yes/no answers + notes — forced decomposition, reliable even for a weak local model.',
       prompt = $P$You are a Glass-Box trajectory evaluator (the "BINEVAL" method). You are given the full TRAJECTORY of ONE agent run: its ordered steps — the tools it chose, the arguments it passed, the results or errors it got back, and its final reply. Judge the PROCESS, not just the output. A fluent final answer that skipped its verification steps is a MORE dangerous failure than one with a visible error.

Read the trajectory, then call **submit_trajectory_verdict** exactly once. Answer each field true (good) or false (a problem), and put a short note in `notes` for every field you answer false (the note is what gets used to fix the agent):
- tool_selection_ok — did it choose appropriate tools?
- params_ok — were the arguments well-formed?
- error_handling_ok — did it recognize errors/empty results and adapt, not proceed as if they succeeded?
- no_redundancy — did it avoid repeating the same call / hammering one tool?
- committed — did it COMMIT to a final answer instead of gathering without end? (many calls, never an answer = a spiral = false)
- grounded — is every claim supported by what it actually retrieved? No fabrication, and no over-generalizing a single record into a population- or state-level claim, or stating a subset as the whole (FIDELITY).
- role_ok — did it stay within its role and granted tools?

Calling submit_trajectory_verdict records your verdict and ends your evaluation. Do not write a free-text verdict; the tool IS your answer.$P$,
       response_format = NULL,
       temperature = 0.2,
       steps = 3,
       active = true
 WHERE family = 'trajectory-critic';

-- grant ONLY the verdict tool (it remains a no-other-tools judge).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('trajectory-critic', '*',                          'deny',  'manual'),
  ('trajectory-critic', 'submit_trajectory_verdict',  'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;
-- ===== [was 80-rest.sql] =====
-- =====================================================================
-- 80-rest.sql — the REST: every N tool-rounds, the model pauses to tidy.
-- =====================================================================
-- The uplift-local-models hypothesis (Michael's): a weak model spirals because
-- it never steps back. So every N rounds, fold the tools down to HOUSEKEEPING
-- only (context/tool/skill/note management) and nudge it to review its context,
-- fold what's spent, update its plan, and check progress — then full tools resume.
-- The creation cycle, made literal: work → rest → tidy → continue.
--
-- Re-authors chat_post_internal (later-file-wins over 67) to add a REST branch
-- alongside the existing force-final-at-cap logic. Force-final still wins near the
-- cap (a model being forced to ANSWER should not rest). Config-gated so it ships
-- OFF and we A/B it against the spiral oracle:
--   config rest_every_n_steps (int, default 0 = OFF) — rest every N assistant rounds
--   config rest_tools (jsonb array) — the housekeeping toolset the rest leaves open
--
-- requires create_rigor_force_final (67). Generic core.
-- =====================================================================

-- The housekeeping toolset a rest turn leaves open (override per operator).
INSERT INTO stewards.config (key, value) VALUES
  ('rest_every_n_steps', '0'::jsonb),
  ('rest_tools', '["compact_context","context_search","expand_message","remember","skill_load","skill_unload"]'::jsonb)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION stewards.chat_post_internal(
    p_agent_family text,
    p_model        text,
    p_session_id   text,
    p_provider     text
) RETURNS bigint LANGUAGE plpgsql AS $FN$
DECLARE
    v_body                  jsonb;
    v_payload               jsonb;
    v_work_id               bigint;
    v_inherited_markers     jsonb;
    v_stage_name            text;
    v_pipeline_family       text;
    v_soft_cap              int;
    v_hard_cap              int;
    v_rounds_so_far         int;
    v_agent_steps           int;
    v_force_tools_disabled  boolean := false;
    v_inject_soft_notice    boolean := false;
    v_already_soft_notified boolean := false;
    v_notice_text           text;
    -- REST (80)
    v_rest_every            int;
    v_is_rest               boolean := false;
    v_rest_tools            jsonb;
    v_last_rested           int;
BEGIN
    SELECT jsonb_object_agg(je.key, je.value)
      INTO v_inherited_markers
      FROM stewards.work_queue wq
      CROSS JOIN LATERAL jsonb_each(wq.payload) je
     WHERE wq.payload->>'session_id' = p_session_id
       AND wq.kind = 'chat'
       AND wq.id = (
           SELECT max(id) FROM stewards.work_queue
            WHERE payload->>'session_id' = p_session_id
              AND kind = 'chat'
       )
       AND je.key LIKE '\_%' ESCAPE '\';

    v_pipeline_family := v_inherited_markers ->> '_pipeline_family';
    v_stage_name      := v_inherited_markers ->> '_stage_name';
    v_already_soft_notified := COALESCE((v_inherited_markers ->> '_soft_cap_notified')::boolean, false);

    IF v_pipeline_family IS NOT NULL AND v_stage_name IS NOT NULL THEN
        v_soft_cap := COALESCE(stewards.stage_max_tool_rounds(v_pipeline_family, v_stage_name), 5);
        v_hard_cap := COALESCE(stewards.stage_max_tool_rounds_hard(v_pipeline_family, v_stage_name), 50);
        SELECT count(*) INTO v_rounds_so_far FROM stewards.messages
         WHERE session_id = p_session_id AND role = 'assistant';
        IF v_rounds_so_far >= v_hard_cap THEN
            v_force_tools_disabled := true;
        ELSIF v_rounds_so_far >= v_soft_cap AND NOT v_already_soft_notified THEN
            v_inject_soft_notice := true;
        END IF;
    ELSIF stewards.config_get('chat_force_final_enabled', 'true'::jsonb) = 'true'::jsonb THEN
        SELECT a.steps INTO v_agent_steps FROM stewards.agents a
         WHERE a.family = p_agent_family AND stewards.glob_match(a.model_match, p_model)
         ORDER BY length(a.model_match) DESC LIMIT 1;
        IF COALESCE(v_agent_steps, 0) >= 6 THEN
            v_hard_cap   := GREATEST(v_agent_steps - 2, 2);
            v_soft_cap   := GREATEST((v_agent_steps * 0.7)::int, 1);
            v_stage_name := COALESCE(v_stage_name, 'chat');
            SELECT count(*) INTO v_rounds_so_far FROM stewards.messages
             WHERE session_id = p_session_id AND role = 'assistant';
            IF v_rounds_so_far >= v_hard_cap THEN
                v_force_tools_disabled := true;
            ELSIF v_rounds_so_far >= v_soft_cap AND NOT v_already_soft_notified THEN
                v_inject_soft_notice := true;
            END IF;
        END IF;
    END IF;

    -- Make sure we have the round count even when neither cap branch ran above.
    IF v_rounds_so_far IS NULL THEN
        SELECT count(*) INTO v_rounds_so_far FROM stewards.messages
         WHERE session_id = p_session_id AND role = 'assistant';
    END IF;

    -- ---- REST (80): every N rounds, tidy. Force-final wins (don't rest a model
    -- being forced to answer); never rest the same round twice. ----
    -- per-dispatch override (_rest_every marker, propagated) wins over the global config,
    -- so a control run and a treatment run can A/B side by side.
    v_rest_every := COALESCE(
        (v_inherited_markers ->> '_rest_every')::int,
        (stewards.config_get('rest_every_n_steps','0'::jsonb) #>> '{}')::int,
        0);
    v_last_rested := COALESCE((v_inherited_markers ->> '_rested_at_round')::int, -1);
    IF v_rest_every > 0
       AND v_rounds_so_far > 0
       AND (v_rounds_so_far % v_rest_every) = 0
       AND v_rounds_so_far <> v_last_rested
       AND NOT v_force_tools_disabled THEN
        v_is_rest := true;
        v_inject_soft_notice := false;  -- a rest turn carries its own nudge
        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (p_session_id, 'system',
            '[REST] You have taken ' || v_rounds_so_far || ' steps. Pause and tidy before continuing — only your housekeeping tools are available this turn. '
            || 'Review your context and fold away what is spent (compact_context), note your plan and what you have learned so far, prune anything you no longer need, and decide your next concrete step. '
            || 'Do this housekeeping now; your full tools return next turn so you can continue from a lighter, clearer place.',
            p_model);
    END IF;

    IF v_inject_soft_notice
       AND stewards.config_get('soft_cap_notice_enabled', 'true'::jsonb) = 'true'::jsonb THEN
        v_notice_text := stewards.build_soft_cap_notice(v_rounds_so_far, v_soft_cap, v_hard_cap, v_stage_name);
        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (p_session_id, 'system', v_notice_text, p_model);
    END IF;

    v_body := stewards.dry_run_chat(p_agent_family, p_model, p_session_id, NULL, p_provider);
    v_body := v_body - '_meta';

    IF v_force_tools_disabled THEN
        v_body := v_body || jsonb_build_object('tool_choice', 'none');
    END IF;

    -- REST: fold the tools down to the housekeeping set for this one turn.
    IF v_is_rest THEN
        v_rest_tools := stewards.config_get('rest_tools', '[]'::jsonb);
        v_body := jsonb_set(v_body, '{tools}', COALESCE((
            SELECT jsonb_agg(t)
              FROM jsonb_array_elements(COALESCE(v_body->'tools','[]'::jsonb)) t
             WHERE v_rest_tools ? (t->'function'->>'name')
        ), '[]'::jsonb));
    END IF;

    -- SAMPLING (Tier-1 qwen3.6 MoE repetition-loop fix): a per-dispatch _sampling
    -- override merged into the body (the documented fix: presence_penalty=1.5 for the
    -- MoE, temp 0.6 not near-greedy, top_p=0.95, top_k=20, min_p=0). Propagates like the
    -- other markers; A/B-able now, becomes a per-model default config when it proves out.
    IF v_inherited_markers ? '_sampling' AND jsonb_typeof(v_inherited_markers->'_sampling')='object' THEN
        v_body := v_body || (v_inherited_markers->'_sampling');
    END IF;

    v_payload := jsonb_build_object(
        'session_id', p_session_id, 'agent_family', p_agent_family,
        'requested_model', p_model, 'body', v_body);

    IF v_force_tools_disabled THEN
        v_payload := v_payload || jsonb_build_object('tools_disabled', true);
    END IF;
    IF v_inject_soft_notice THEN
        v_payload := v_payload || jsonb_build_object('_soft_cap_notified', true, '_soft_cap_injected_at_round', v_rounds_so_far);
    END IF;
    IF v_is_rest THEN
        v_payload := v_payload || jsonb_build_object('_rested_at_round', v_rounds_so_far);
    END IF;

    IF v_inherited_markers IS NOT NULL THEN
        v_payload := (v_inherited_markers - '_soft_cap_notified' - '_soft_cap_injected_at_round' - '_rested_at_round') || v_payload;
    END IF;

    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat', p_provider, v_payload, 'pending')
    RETURNING id INTO v_work_id;
    RETURN v_work_id;
END;
$FN$;

COMMENT ON FUNCTION stewards.chat_post_internal(text, text, text, text) IS
'80 (re-authors 67): per-round continuation enqueue with two-tier force-final caps PLUS the REST — every rest_every_n_steps assistant rounds (config, default 0=off), fold tools to the rest_tools housekeeping set and inject a [REST] tidy-up nudge so the model reviews context, compacts, re-plans, then continues with full tools. Force-final near the cap takes precedence over a rest. A/B-able against the spiral oracle.';
-- ===== [was 81-spiral-oracle.sql] =====
-- =====================================================================
-- 81-spiral-oracle.sql — the deterministic gauge for the "uplift local models" arc.
-- =====================================================================
-- Build-the-oracle-first: measure the spiral before building the cure, so every
-- intervention (sampling fix, route-to-gemma, BINEVAL, the rest, a model swap) is
-- scored against a real before/after on real ledger data. Read-only; no behavior
-- change.
--
-- A "hard spiral" = the over-gather-never-commit loop: the model hammered a few
-- tools many times and never produced a committed (non-tool) answer. Validated
-- against the real ledger 2026-06-29 (the world-build/tor-build loops at 60-364
-- calls/tool are the extreme cases; the repetition discriminator filters legit
-- tool-only stages out). Honest baseline at registration: qwen3.6-35b ~11.9%,
-- gemma 0%. The two thresholds below are the tunable lines.
--
-- Generic core; no scripture, no overlay. requires create_rest (80) only for
-- chain ORDER (it reads stewards.messages, which exists far earlier).
-- =====================================================================

-- Per-session spiral predicate (also the seed for a future watcher trigger).
CREATE OR REPLACE FUNCTION stewards.session_spiraled(
  p_session       text,
  p_min_calls     int DEFAULT 15,   -- tunable: a real loop calls a lot
  p_min_per_tool  numeric DEFAULT 4 -- tunable: hammering few tools, not diverse use
) RETURNS boolean AS $$
  WITH asst AS (
    SELECT tool_calls,
           -- coalesce to false: a committed answer stores tool_calls=NULL, and
           -- jsonb_typeof(NULL)='array' is NULL → NOT is_tool would be NULL (uncounted).
           coalesce(jsonb_typeof(tool_calls)='array' AND jsonb_array_length(tool_calls)>0, false) AS is_tool
    FROM stewards.messages WHERE role='assistant' AND session_id = p_session
  ),
  calls AS (SELECT (jsonb_array_elements(tool_calls)->'function'->>'name') AS tool FROM asst WHERE is_tool)
  SELECT (SELECT count(*) FROM calls) >= p_min_calls
     AND (SELECT count(*) FROM calls)::numeric
         / nullif((SELECT count(DISTINCT tool) FROM calls),0) >= p_min_per_tool
     AND (SELECT count(*) FILTER (WHERE NOT is_tool) FROM asst) = 0;
$$ LANGUAGE sql STABLE;

-- Per-model baseline report: the standing gauge. Re-run after every intervention.
CREATE OR REPLACE FUNCTION stewards.spiral_report(
  p_min_sessions  int DEFAULT 10,
  p_min_calls     int DEFAULT 15,
  p_min_per_tool  numeric DEFAULT 4
) RETURNS TABLE(model text, sessions bigint, hard_spirals bigint, spiral_pct numeric) AS $$
  WITH asst AS (
    SELECT session_id, coalesce(model,'?') AS model, tool_calls,
           coalesce(jsonb_typeof(tool_calls)='array' AND jsonb_array_length(tool_calls)>0, false) AS is_tool
    FROM stewards.messages WHERE role='assistant'
  ),
  calls AS (SELECT session_id, (jsonb_array_elements(tool_calls)->'function'->>'name') AS tool FROM asst WHERE is_tool),
  call_stats AS (SELECT session_id, count(*) AS total_calls, count(DISTINCT tool) AS distinct_tools FROM calls GROUP BY session_id),
  per AS (
    SELECT a.session_id,
           mode() WITHIN GROUP (ORDER BY a.model) AS model,
           count(*) FILTER (WHERE a.is_tool) AS tool_turns,
           count(*) FILTER (WHERE NOT a.is_tool) AS answer_turns
    FROM asst a GROUP BY a.session_id
  ),
  j AS (
    SELECT p.model,
           (c.total_calls >= p_min_calls
            AND c.total_calls::numeric/nullif(c.distinct_tools,0) >= p_min_per_tool
            AND p.answer_turns = 0) AS hard_spiral
    FROM per p LEFT JOIN call_stats c USING(session_id)
    WHERE p.tool_turns >= 1
  )
  SELECT model, count(*), count(*) FILTER (WHERE hard_spiral),
         round(100.0*count(*) FILTER (WHERE hard_spiral)/count(*), 1)
  FROM j GROUP BY model HAVING count(*) >= p_min_sessions
  ORDER BY count(*) FILTER (WHERE hard_spiral) DESC;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION stewards.session_spiraled(text,int,numeric) IS
'81: deterministic per-session spiral predicate — >= p_min_calls tool calls AND >= p_min_per_tool calls/distinct-tool (hammering) AND zero committed answer turns. The gauge for the uplift-local-models arc.';
COMMENT ON FUNCTION stewards.spiral_report(int,int,numeric) IS
'81: per-model spiral baseline over the whole ledger. Re-run before/after any reliability intervention (sampling, routing, circuit-breaker).';
