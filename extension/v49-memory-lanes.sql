-- =====================================================================
-- v49 — memory lanes: three independent mountains
-- =====================================================================
-- Ruled MANDATORY 2026-08-09 after both remote boxes independently asked
-- for attribution before anyone proposed it as a requirement. The design is
-- Michael's: every seat reads the shared record, every seat keeps its own
-- curated set, and its OWN lane is weighted first in recall.
--
-- Why it is not bookkeeping. Seats of the same model family, running the
-- same disciplines over ONE undifferentiated pool, recall the same sentences
-- in the same order and mistake shared priors for agreement. Lane-first
-- recall is the structural mitigation: each seat's own hard-won lesson
-- outranks the pool's consensus in its own head, so the seats keep arriving
-- from different directions. Independence of instrument, applied to memory.
--
-- Honest bound, from the seat that asked for lanes: this fixes RECALL
-- convergence only. It does not reach shared source, shared method, or the
-- room itself — and it makes convergence rarer but HARDER TO READ, because
-- agreement between laned seats looks like independent corroboration. The
-- standing orders carry that; SQL cannot.
--
-- Contents:
--   1. current_box()      — who is writing, derived from the pg role
--   2. origin_box columns + FORCING triggers (unforgeable, not a default)
--   3. backfill           — everything extant is fermion's
--   4. fact_recall_laned  — lane-first ordering (NEW function; the
--                           extension-function lock forbids re-parameterizing
--                           fact_recall, and a defaulted overload would make
--                           existing calls ambiguous)
--   5. memory_lane        — the projection a seat reads
--   6. lane_check()       — the oracle, including threadchip's falsifier rule
-- =====================================================================

-- 0. PREFLIGHT (added in the sol-p0-release-batch, 2026-08-11). This volume
--    GRANTs to the operator-provisioned group roles; without them the GRANT
--    aborts the whole CREATE EXTENSION with a bare "role does not exist"
--    55,000 lines into the script (red-run evidence:
--    .spec/reviews/sol-p0-release-batch-redrun-2026-08-11.md). Refuse HERE,
--    with the remediation in the message. The extension must not own
--    cluster-global roles (they outlive DROP EXTENSION and cross databases),
--    so it checks and points, never creates.
DO $preflight$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'brain_read')
       OR NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'brain_absorb') THEN
        RAISE EXCEPTION USING
            MESSAGE = 'pg_ai_stewards v49+ requires the operator-provisioned group roles '
                      'brain_read and brain_absorb (NOLOGIN). Run '
                      'extension/init/00-bootstrap-roles.sql as a superuser before '
                      'CREATE EXTENSION (docker compose runs it automatically on first boot).',
            ERRCODE = 'undefined_object';
    END IF;
END
$preflight$;

-- 1. Who is writing. A box authenticates as its own role (box_threadchip);
--    the host authenticates as `stewards` and is fermion. Unknown roles get
--    their own name rather than silently inheriting anyone's lane.
-- A SECURITY DEFINER lookup, because `house` is the host's private schema and
-- a box role has no USAGE on it. current_user is resolved in the CALLER's
-- context and passed IN; inside a definer function current_user would be the
-- owner, which would silently attribute every box's writes to fermion.
-- (Same class as the charter projection that took down both boxes' pulls
-- hours earlier: a function tested only on the host, where `house` is
-- readable. Caught here by this file's own negative test, before shipping.)
CREATE OR REPLACE FUNCTION stewards.box_for_role(p_role text) RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = stewards, house, pg_temp AS $fn$
    SELECT r.name FROM house.roster r
     WHERE r.pg_role = p_role AND r.revoked_at IS NULL LIMIT 1
$fn$;
REVOKE ALL ON FUNCTION stewards.box_for_role(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION stewards.box_for_role(text) TO brain_read;

CREATE OR REPLACE FUNCTION stewards.current_box() RETURNS text
LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE(
        stewards.box_for_role(current_user::text),
        CASE WHEN current_user IN ('stewards', 'postgres') THEN 'fermion'
             ELSE current_user::text END)
$fn$;
COMMENT ON FUNCTION stewards.current_box() IS
'v49: the writing seat''s lane name, from house.roster by pg role (via the definer lookup box_for_role). The host (stewards) is fermion. Never trusts a caller-supplied value — see the forcing triggers.';

-- 2. The columns, and triggers that FORCE them. A DEFAULT would be
--    overridable by an explicit INSERT; nocix asked for enforceable rather
--    than merely intended, so the value is stamped on the way in and a
--    caller-supplied origin_box is discarded.
ALTER TABLE stewards.nodes      ADD COLUMN IF NOT EXISTS origin_box text;
ALTER TABLE stewards.fact_edges ADD COLUMN IF NOT EXISTS origin_box text;

COMMENT ON COLUMN stewards.nodes.origin_box IS
'v49 lane: which seat wrote this. Forced by trigger from stewards.current_box(); a caller cannot set it.';
COMMENT ON COLUMN stewards.fact_edges.origin_box IS
'v49 lane: which seat asserted this edge. Forced by trigger; see nodes.origin_box.';

CREATE OR REPLACE FUNCTION stewards.stamp_origin_box() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    NEW.origin_box := stewards.current_box();
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS stamp_origin_box ON stewards.nodes;
CREATE TRIGGER stamp_origin_box BEFORE INSERT ON stewards.nodes
    FOR EACH ROW EXECUTE FUNCTION stewards.stamp_origin_box();
DROP TRIGGER IF EXISTS stamp_origin_box ON stewards.fact_edges;
CREATE TRIGGER stamp_origin_box BEFORE INSERT ON stewards.fact_edges
    FOR EACH ROW EXECUTE FUNCTION stewards.stamp_origin_box();

-- 3. Everything that exists predates lanes and is the host's.
UPDATE stewards.nodes      SET origin_box = 'fermion' WHERE origin_box IS NULL;
UPDATE stewards.fact_edges SET origin_box = 'fermion' WHERE origin_box IS NULL;

CREATE INDEX IF NOT EXISTS nodes_origin_box_idx      ON stewards.nodes (origin_box);
CREATE INDEX IF NOT EXISTS fact_edges_origin_box_idx ON stewards.fact_edges (origin_box);

-- 4. Lane-first recall. NOT a re-parameterization of fact_recall: the
--    extension-function lock forbids that, and a defaulted overload would
--    make every existing 1-5 arg call ambiguous. Same walk, same sqrt(deg)
--    normalization, same as-of belief set — the ONLY difference is that the
--    caller's own lane sorts ahead of the shared pool at equal relevance.
--    Nothing is filtered out: a seat still reaches everything the fleet knows.
CREATE OR REPLACE FUNCTION stewards.fact_recall_laned(
    p_seeds    jsonb,
    p_lane     text,
    p_max_hops integer DEFAULT 2,
    p_limit    integer DEFAULT 15,
    p_decay    real    DEFAULT 0.5,
    p_as_of    timestamptz DEFAULT NULL,
    p_boost    real    DEFAULT 1.35
) RETURNS TABLE (kind text, ref text, label text, score real, hops integer,
                 origin_box text, own_lane boolean)
LANGUAGE sql STABLE AS $fn$
    WITH RECURSIVE live AS (
        SELECT f.src, f.dst
          FROM stewards.fact_edges f
         WHERE f.created_at <= coalesce(p_as_of, now())
           AND (f.expired_at IS NULL OR f.expired_at > coalesce(p_as_of, now()))
           AND f.validity @> coalesce(p_as_of, now())
    ),
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
    SELECT n.kind, n.ref, n.label,
           (sum(walk.w) * CASE WHEN n.origin_box = p_lane THEN p_boost ELSE 1.0 END)::real AS score,
           min(walk.hop) AS hops,
           n.origin_box,
           (n.origin_box = p_lane) AS own_lane
      FROM walk JOIN stewards.nodes n ON n.id = walk.id
     WHERE walk.hop > 0
       AND walk.id NOT IN (SELECT id FROM seed)
     GROUP BY n.id, n.kind, n.ref, n.label, n.origin_box
     ORDER BY (n.origin_box = p_lane) DESC, score DESC
     LIMIT p_limit;
$fn$;
COMMENT ON FUNCTION stewards.fact_recall_laned(jsonb, text, integer, integer, real, timestamptz, real) IS
'v49: fact_recall with the caller''s own lane ordered first (and boosted at equal relevance). Nothing is filtered — a seat still reaches the whole record; only the ORDER differs. Separate function, not an overload: the extension-function lock forbids re-parameterizing fact_recall, and a defaulted overload would make existing calls ambiguous.';

-- 5. What a seat reads about its own lane.
CREATE OR REPLACE VIEW stewards.memory_lane AS
SELECT n.origin_box,
       n.kind,
       n.ref,
       n.label,
       n.props ->> 'file'       AS file,
       n.props ->> 'index_hook' AS hook,
       n.created_at,
       (n.origin_box = stewards.current_box()) AS mine
  FROM stewards.nodes n
 WHERE n.kind = 'memory';
COMMENT ON VIEW stewards.memory_lane IS
'v49: every memory with its lane, and whether it is the caller''s own. Shared by default, curated per box, attributed always.';
GRANT SELECT ON stewards.memory_lane TO brain_read;

-- 6. THE ORACLE. Built before the callers, per the house rule; red on a
--    pre-v49 record, green after. Returns one row per check.
CREATE OR REPLACE FUNCTION stewards.lane_check()
RETURNS TABLE (check_name text, ok boolean, detail text)
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_n bigint; v_txt text;
BEGIN
    -- (a) every memory node and live edge carries a lane
    SELECT count(*) INTO v_n FROM stewards.nodes WHERE origin_box IS NULL;
    RETURN QUERY SELECT 'nodes_have_lane', v_n = 0,
        v_n || ' node(s) with NULL origin_box';
    SELECT count(*) INTO v_n FROM stewards.fact_edges WHERE origin_box IS NULL;
    RETURN QUERY SELECT 'edges_have_lane', v_n = 0,
        v_n || ' fact_edge(s) with NULL origin_box';

    -- (b) the stamp is forced, not defaulted — a caller cannot forge a lane
    RETURN QUERY SELECT 'stamp_is_forced',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'stamp_origin_box' AND NOT tgisinternal),
        'BEFORE INSERT triggers present on nodes + fact_edges';

    -- (c) lane names resolve to real seats (a typo'd lane is an orphan lane)
    SELECT string_agg(DISTINCT origin_box, ', ') INTO v_txt
      FROM stewards.nodes n
     WHERE n.origin_box IS NOT NULL
       AND n.origin_box <> 'fermion'
       AND NOT EXISTS (SELECT 1 FROM house.roster r
                        WHERE r.name = n.origin_box);
    RETURN QUERY SELECT 'lanes_are_seats', v_txt IS NULL,
        COALESCE('unknown lane(s): ' || v_txt, 'all lanes resolve to roster seats');

    -- (d) THREADCHIP'S FALSIFIER RULE. A memory whose hook carries a
    --     quantitative claim must also carry the axis along which it stops
    --     being true. Its own evidence: of four wrong generalizations it
    --     shipped in a week, a hardware fingerprint would have caught one —
    --     the discriminators were model family, which-resource-binds-first,
    --     workload shape, and concurrency. By its account this check would
    --     have caught two at write time.
    --     Advisory for pre-v49 rows (reported, not failed); the write path
    --     enforces it going forward.
    SELECT count(*) INTO v_n
      FROM stewards.nodes n
     WHERE n.kind = 'memory'
       AND n.created_at > '2026-08-10'::timestamptz
       AND (n.props ->> 'index_hook') ~ '[0-9]+(\.[0-9]+)?\s*(x|×|%|ms|s\b|tok|MB|GB|/s)'
       AND (n.props ->> 'index_hook') !~* 'falsifi|stale.when|until|unless|only (when|on|for)|breaks (when|at)';
    RETURN QUERY SELECT 'quantitative_claims_have_falsifier', v_n = 0,
        v_n || ' post-v49 memory hook(s) carry a number with no falsifier '
             || '(the axis along which it stops being true)';
END;
$fn$;
COMMENT ON FUNCTION stewards.lane_check() IS
'v49 oracle: lanes present, forced, and resolvable; plus threadchip''s falsifier rule on quantitative memory claims. Run in the verify suite.';
