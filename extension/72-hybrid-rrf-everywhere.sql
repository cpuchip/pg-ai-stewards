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
