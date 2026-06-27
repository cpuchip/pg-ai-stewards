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
