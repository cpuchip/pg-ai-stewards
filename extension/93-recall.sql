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
