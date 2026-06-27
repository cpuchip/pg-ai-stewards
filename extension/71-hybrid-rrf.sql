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
