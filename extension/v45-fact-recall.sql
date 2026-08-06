-- v45 — fact_recall: associative recall over the bi-temporal fact graph.
--
-- THE SEAM THIS CLOSES (found 2026-08-06 by the golden recall set's very first
-- run): graph_recall walks stewards.edges — which holds the old world/doc
-- graph and ZERO rows touching memory nodes — while the brain-v5 importers
-- write stewards.fact_edges (413 facts, all touching memory nodes). The
-- advertised associative recall was blind to the entire memory corpus. The
-- recall surface predated the P0 schema and nobody owned the seam between
-- them; the golden set (private-workspace/scripts/brain-v5/golden-recall.*)
-- is now the standing judge of this surface.
--
-- Design notes (the Zero-Mem steal, arXiv 2607.29377, adapted):
--   * Deterministic end to end — no model call anywhere in recall.
--   * Bi-temporal, which Zero-Mem does not have: p_as_of reconstructs the
--     belief set at any moment. A fact participates only if it was INGESTED
--     by then (created_at <= t, not yet expired) AND event-valid at t
--     (validity @> t). Default t = now() = current belief.
--   * Evidence closure in the _tool wrapper: each hit returns the FACTS that
--     connect it (text + file:line provenance), not just a label — recall
--     hands back testimony, in the paper's terms "provenance-bearing source
--     units," never a generated abstraction.
--
-- Additive only: graph_recall keeps its table and its contract untouched
-- (extension-function lock; and the old world-graph is still its turf).

CREATE OR REPLACE FUNCTION stewards.fact_recall(
    p_seeds jsonb, p_max_hops int DEFAULT 2, p_limit int DEFAULT 15,
    p_decay real DEFAULT 0.5, p_as_of timestamptz DEFAULT NULL
) RETURNS TABLE (kind text, ref text, label text, score real, hops int)
LANGUAGE sql STABLE AS $fn$
    WITH RECURSIVE live AS (
        -- the belief set at time t: ingest-visible AND event-valid
        SELECT f.src, f.dst
          FROM stewards.fact_edges f
         WHERE f.created_at <= coalesce(p_as_of, now())
           AND (f.expired_at IS NULL OR f.expired_at > coalesce(p_as_of, now()))
           AND f.validity @> coalesce(p_as_of, now())
    ),
    -- Degree per node, for propagation normalization. Without it a
    -- high-degree hub floods every nearby neighborhood: the golden set
    -- measured a degree-7 seed whose single-path 1-hop neighbor (0.5) was
    -- outranked by ~25 two-hop nodes at 0.75-1.5, all multi-path routes
    -- through two degree-26 hubs. PageRank fixes this by dividing weight
    -- among edges; full division (w/deg) over-corrects and starves legitimate
    -- 2-hop discovery below the prune floor, so we normalize by sqrt(deg) —
    -- hubs damped quadratically, low-degree bridges still conductive.
    deg AS (
        SELECT id, count(*)::real AS d FROM (
            SELECT src AS id FROM live UNION ALL SELECT dst FROM live) e
        GROUP BY id
    ),
    seed AS (
        SELECT n.id, 1.0::real AS w, 0 AS hop
          FROM stewards.nodes n
          JOIN jsonb_array_elements(p_seeds) s
            ON n.kind = s->>'kind' AND n.ref = s->>'ref'
    ),
    walk AS (
        SELECT id, w, hop FROM seed
        UNION ALL
        SELECT CASE WHEN l.src = walk.id THEN l.dst ELSE l.src END,
               (walk.w * p_decay / sqrt(deg.d))::real,
               walk.hop + 1
          FROM walk
          JOIN live l ON (l.src = walk.id OR l.dst = walk.id)
          JOIN deg ON deg.id = walk.id
         WHERE walk.hop < p_max_hops AND walk.w > 0.001
    )
    SELECT n.kind, n.ref, n.label, sum(walk.w)::real AS score, min(walk.hop) AS hops
      FROM walk JOIN stewards.nodes n ON n.id = walk.id
     WHERE walk.hop > 0
       AND walk.id NOT IN (SELECT id FROM seed)
     GROUP BY n.id, n.kind, n.ref, n.label
     ORDER BY score DESC
     LIMIT p_limit;
$fn$;
COMMENT ON FUNCTION stewards.fact_recall(jsonb,int,int,real,timestamptz) IS
'Associative recall over the bi-temporal fact graph (fact_edges) — spreads weight from seeds along LIVE facts, both directions, decaying per hop. p_as_of reconstructs the belief set at any moment (ingest-visible AND event-valid); default = current belief. Judged by the golden recall set. v45.';

CREATE OR REPLACE FUNCTION stewards.fact_recall_tool(p_args jsonb)
RETURNS text LANGUAGE sql STABLE AS $fn$
    WITH hits AS (
        SELECT * FROM stewards.fact_recall(
            coalesce(p_args->'seeds',
                     jsonb_build_array(jsonb_build_object('kind', p_args->>'kind',
                                                          'ref',  p_args->>'ref'))),
            coalesce((p_args->>'max_hops')::int, 2),
            coalesce((p_args->>'limit')::int, 15),
            coalesce((p_args->>'decay')::real, 0.5),
            (p_args->>'as_of')::timestamptz)
    ),
    member AS (  -- hits plus the seeds: closure connects within this set
        SELECT n.id, n.ref FROM stewards.nodes n JOIN hits h
          ON n.kind = h.kind AND n.ref = h.ref
        UNION
        SELECT n.id, n.ref FROM stewards.nodes n
          JOIN jsonb_array_elements(coalesce(p_args->'seeds',
                jsonb_build_array(jsonb_build_object('kind', p_args->>'kind',
                                                     'ref',  p_args->>'ref')))) s
            ON n.kind = s->>'kind' AND n.ref = s->>'ref'
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'kind', h.kind, 'ref', h.ref, 'label', h.label,
        'score', round(h.score::numeric, 3), 'hops', h.hops,
        -- evidence closure: the live facts tying this hit into the returned
        -- set — the line that says so, not a summary of it.
        'evidence', (
            SELECT coalesce(jsonb_agg(ev), '[]'::jsonb) FROM (
                SELECT jsonb_build_object(
                    'fact', f.fact,
                    'with', CASE WHEN ms.id = f.src THEN mo.ref ELSE ms.ref END,
                    'file', f.props->>'file', 'line', f.props->>'line') AS ev
                  FROM stewards.fact_edges f
                  JOIN member ms ON ms.id = f.src
                  JOIN member mo ON mo.id = f.dst
                  JOIN stewards.nodes hn ON hn.kind = h.kind AND hn.ref = h.ref
                 WHERE (f.src = hn.id OR f.dst = hn.id)
                   AND f.created_at <= coalesce((p_args->>'as_of')::timestamptz, now())
                   AND (f.expired_at IS NULL OR
                        f.expired_at > coalesce((p_args->>'as_of')::timestamptz, now()))
                   AND f.validity @> coalesce((p_args->>'as_of')::timestamptz, now())
                 LIMIT 3) e)
        ) ORDER BY h.score DESC), '[]'::jsonb)::text
    FROM hits h;
$fn$;
COMMENT ON FUNCTION stewards.fact_recall_tool(p_args jsonb) IS
'Tool face of fact_recall with evidence closure: each hit carries up to 3 connecting facts (text + file:line provenance) tying it into the returned set. Args: seeds|[kind,ref], max_hops, limit, decay, as_of. v45.';
