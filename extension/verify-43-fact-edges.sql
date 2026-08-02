-- =====================================================================
-- verify-43-fact-edges.sql — the P0 oracle.
--
-- The SPEC grades P0 on "verify-suite + fixture queries (as-of, invalidation,
-- dedup)". This file IS those fixtures, plus the two companion fixes. Every
-- assertion is a hard RAISE EXCEPTION, so a regression fails the script rather
-- than printing a warning nobody reads.
--
-- Written to FAIL if the migration is absent or wrong — each block was
-- confirmed to fail against the pre-v43 chain before being kept (a check that
-- cannot fail is not a check).
--
-- Usage (scratch install, per the verify-*.sql convention):
--   docker exec -i <container> psql -U stewards -d stewards \
--       -v ON_ERROR_STOP=1 < extension/v43-fact-edges.sql
--   docker exec -i <container> psql -U stewards -d stewards \
--       -v ON_ERROR_STOP=1 < extension/verify-43-fact-edges.sql
--
-- Runs entirely inside one transaction that is ROLLED BACK, so it is safe to
-- point at a populated database.
-- =====================================================================

\set ON_ERROR_STOP on

BEGIN;

-- ---------------------------------------------------------------------
-- Fixtures: two entity nodes and one episode to hang assertions on.
-- ---------------------------------------------------------------------
DO $fixtures$
DECLARE
    v_src uuid;
    v_dst uuid;
    v_msg bigint;
    v_sess text;
BEGIN
    v_src := stewards.graph_node_upsert('person', 'v43-fixture-person', 'A Person', '{}'::jsonb);
    v_dst := stewards.graph_node_upsert('project', 'v43-fixture-project', 'A Project', '{}'::jsonb);

    INSERT INTO stewards.sessions (label) VALUES ('v43 fixture session')
    RETURNING id INTO v_sess;
    INSERT INTO stewards.messages (session_id, role, content)
    VALUES (v_sess, 'user', 'v43 fixture episode')
    RETURNING id INTO v_msg;

    CREATE TEMP TABLE v43_fix (src uuid, dst uuid, msg bigint) ON COMMIT DROP;
    INSERT INTO v43_fix VALUES (v_src, v_dst, v_msg);
END;
$fixtures$;

-- ---------------------------------------------------------------------
-- 1. AS-OF — the thing stewards.edges structurally cannot do.
--    One pair of nodes, two CONTRADICTORY assertions with disjoint event-time
--    windows. Both rows must survive, and an as-of query must return exactly
--    the one true at that instant.
-- ---------------------------------------------------------------------
DO $as_of$
DECLARE
    v_src uuid; v_dst uuid;
    v_2024 int; v_2026 int; v_between int;
BEGIN
    SELECT src, dst INTO v_src, v_dst FROM v43_fix;

    INSERT INTO stewards.fact_edges (src, dst, kind, fact, valid_at, invalid_at, fidelity)
    VALUES (v_src, v_dst, 'WORKS_ON', 'A Person works on A Project',
            '2024-01-01'::timestamptz, '2025-01-01'::timestamptz, 'verbatim');

    -- The SAME relation asserted again for a later window. Under
    -- stewards.edges' UNIQUE (src,dst,kind) this second row would have
    -- OVERWRITTEN the first and the history would be gone.
    INSERT INTO stewards.fact_edges (src, dst, kind, fact, valid_at, fidelity)
    VALUES (v_src, v_dst, 'WORKS_ON', 'A Person works on A Project again',
            '2026-01-01'::timestamptz, 'verbatim');

    SELECT count(*) INTO v_2024 FROM stewards.fact_edges
     WHERE src = v_src AND validity @> '2024-06-01'::timestamptz;
    SELECT count(*) INTO v_between FROM stewards.fact_edges
     WHERE src = v_src AND validity @> '2025-06-01'::timestamptz;
    SELECT count(*) INTO v_2026 FROM stewards.fact_edges
     WHERE src = v_src AND validity @> '2026-06-01'::timestamptz;

    IF v_2024 <> 1 THEN
        RAISE EXCEPTION 'as-of 2024 expected exactly 1 fact, got %', v_2024;
    END IF;
    IF v_between <> 0 THEN
        RAISE EXCEPTION 'as-of 2025 (the gap) expected 0 facts, got %', v_between;
    END IF;
    IF v_2026 <> 1 THEN
        RAISE EXCEPTION 'as-of 2026 expected exactly 1 fact, got %', v_2026;
    END IF;

    -- Both assertions still exist. This is the whole point of P0.
    IF (SELECT count(*) FROM stewards.fact_edges WHERE src = v_src) <> 2 THEN
        RAISE EXCEPTION 'both contradictory assertions must survive; the store overwrote one';
    END IF;
    RAISE NOTICE 'OK 1/6  as-of: two contradictory assertions coexist, each returned at its own instant';
END;
$as_of$;

-- ---------------------------------------------------------------------
-- 2. INVALIDATION — stamping the loser, and knowing WHO refuted it
--    (invalidated_by is our addition; graphiti cannot answer this).
-- ---------------------------------------------------------------------
DO $invalidation$
DECLARE
    v_src uuid; v_dst uuid; v_msg bigint;
    v_id uuid;
    v_live int;
    v_by bigint;
BEGIN
    SELECT src, dst, msg INTO v_src, v_dst, v_msg FROM v43_fix;

    INSERT INTO stewards.fact_edges (src, dst, kind, fact, valid_at)
    VALUES (v_src, v_dst, 'BELIEVES', 'A Person believes something retractable',
            '2026-01-01'::timestamptz)
    RETURNING id INTO v_id;

    SELECT count(*) INTO v_live FROM stewards.fact_edges
     WHERE src = v_src AND kind = 'BELIEVES' AND expired_at IS NULL;
    IF v_live <> 1 THEN
        RAISE EXCEPTION 'expected 1 live BELIEVES before invalidation, got %', v_live;
    END IF;

    -- Refute it: stamp, never delete.
    UPDATE stewards.fact_edges
       SET expired_at = now(), invalid_at = '2026-07-01'::timestamptz, invalidated_by = v_msg
     WHERE id = v_id;

    SELECT count(*) INTO v_live FROM stewards.fact_edges
     WHERE src = v_src AND kind = 'BELIEVES' AND expired_at IS NULL;
    IF v_live <> 0 THEN
        RAISE EXCEPTION 'invalidated fact still counts as live (%)' , v_live;
    END IF;

    -- The row must still be there — retraction is not deletion.
    IF NOT EXISTS (SELECT 1 FROM stewards.fact_edges WHERE id = v_id) THEN
        RAISE EXCEPTION 'invalidation destroyed the row; it must survive stamped';
    END IF;

    SELECT invalidated_by INTO v_by FROM stewards.fact_edges WHERE id = v_id;
    IF v_by IS DISTINCT FROM v_msg THEN
        RAISE EXCEPTION 'invalidated_by lost the refuting episode (got %, want %)', v_by, v_msg;
    END IF;

    -- And it is still visible as-of a time when it WAS true.
    IF NOT EXISTS (
        SELECT 1 FROM stewards.fact_edges
         WHERE id = v_id AND validity @> '2026-03-01'::timestamptz) THEN
        RAISE EXCEPTION 'a retracted fact must remain queryable as-of when it held';
    END IF;
    RAISE NOTICE 'OK 2/6  invalidation: stamped not deleted, refuter recorded, still true-as-of';
END;
$invalidation$;

-- ---------------------------------------------------------------------
-- 3. DEDUP — exact, in-engine, and scoped to LIVE rows only.
-- ---------------------------------------------------------------------
DO $dedup$
DECLARE
    v_src uuid; v_dst uuid;
    v_id uuid;
    v_norm text;
    v_dup boolean := false;
BEGIN
    SELECT src, dst INTO v_src, v_dst FROM v43_fix;

    INSERT INTO stewards.fact_edges (src, dst, kind, fact)
    VALUES (v_src, v_dst, 'NOTES', '  The   Fact   With  Messy Spacing ')
    RETURNING id INTO v_id;

    SELECT fact_norm INTO v_norm FROM stewards.fact_edges WHERE id = v_id;
    IF v_norm <> ' the fact with messy spacing ' THEN
        RAISE EXCEPTION 'fact_norm normalization wrong: [%]', v_norm;
    END IF;

    -- Same normalized fact, different case/spacing => must be refused while live.
    BEGIN
        INSERT INTO stewards.fact_edges (src, dst, kind, fact)
        VALUES (v_src, v_dst, 'DIFFERENT_KIND', '  the FACT with   messy spacing ');
        v_dup := true;
    EXCEPTION WHEN unique_violation THEN
        NULL;  -- expected
    END;
    IF v_dup THEN
        RAISE EXCEPTION 'live dedup failed: a duplicate normalized fact was accepted';
    END IF;

    -- ...and the dedup key deliberately OMITS kind, matching upstream. The
    -- attempt above used a different kind and still had to be refused.

    -- Once the original is expired, the same fact may be asserted again:
    -- the unique index is partial on expired_at IS NULL.
    UPDATE stewards.fact_edges SET expired_at = now() WHERE id = v_id;
    INSERT INTO stewards.fact_edges (src, dst, kind, fact)
    VALUES (v_src, v_dst, 'NOTES', 'The Fact With Messy Spacing');
    RAISE NOTICE 'OK 3/6  dedup: exact-normalized, kind-agnostic, live-only (re-assertable after expiry)';
END;
$dedup$;

-- ---------------------------------------------------------------------
-- 4. JUNCTION — the role discriminator, and the ordinal-0 creating episode.
-- ---------------------------------------------------------------------
DO $junction$
DECLARE
    v_src uuid; v_dst uuid; v_msg bigint;
    v_id uuid;
    v_bad boolean := false;
BEGIN
    SELECT src, dst, msg INTO v_src, v_dst, v_msg FROM v43_fix;

    INSERT INTO stewards.fact_edges (src, dst, kind, fact)
    VALUES (v_src, v_dst, 'JUNCTION_TEST', 'a fact with episodes')
    RETURNING id INTO v_id;

    -- The SAME episode may both create and later refute a fact; the PK
    -- includes role precisely so that is representable.
    INSERT INTO stewards.fact_edge_episodes (fact_edge_id, message_id, role, ordinal)
    VALUES (v_id, v_msg, 'supports', 0), (v_id, v_msg, 'invalidates', 1);

    IF (SELECT count(*) FROM stewards.fact_edge_episodes WHERE fact_edge_id = v_id) <> 2 THEN
        RAISE EXCEPTION 'role discriminator failed: both roles for one episode must coexist';
    END IF;

    BEGIN
        INSERT INTO stewards.fact_edge_episodes (fact_edge_id, message_id, role, ordinal)
        VALUES (v_id, v_msg, 'mentions', 2);   -- not a legal role
        v_bad := true;
    EXCEPTION WHEN check_violation THEN
        NULL;  -- expected
    END;
    IF v_bad THEN
        RAISE EXCEPTION 'role CHECK accepted an illegal role';
    END IF;

    -- Deleting the fact must take its junction rows with it.
    DELETE FROM stewards.fact_edges WHERE id = v_id;
    IF EXISTS (SELECT 1 FROM stewards.fact_edge_episodes WHERE fact_edge_id = v_id) THEN
        RAISE EXCEPTION 'junction rows outlived their fact (cascade missing)';
    END IF;
    RAISE NOTICE 'OK 4/6  junction: supports/invalidates coexist, illegal role refused, cascade holds';
END;
$junction$;

-- ---------------------------------------------------------------------
-- 5. EVENT-ORDER GUARD — a fact cannot stop being true before it started.
-- ---------------------------------------------------------------------
DO $guard$
DECLARE
    v_src uuid; v_dst uuid;
    v_bad boolean := false;
BEGIN
    SELECT src, dst INTO v_src, v_dst FROM v43_fix;
    BEGIN
        INSERT INTO stewards.fact_edges (src, dst, kind, fact, valid_at, invalid_at)
        VALUES (v_src, v_dst, 'BACKWARDS', 'time running backwards',
                '2026-06-01'::timestamptz, '2026-01-01'::timestamptz);
        v_bad := true;
    -- TWO guards can refuse this, and the GENERATED tstzrange wins the race:
    -- constructing tstzrange(later, earlier) raises data_exception before the
    -- CHECK is ever evaluated. Both are accepted here because which one fires
    -- is an implementation detail — what the store must guarantee is that the
    -- row does not land. (Measured on the scratch chain, not assumed.)
    EXCEPTION
        WHEN check_violation OR data_exception THEN
            NULL;  -- expected
    END;
    IF v_bad THEN
        RAISE EXCEPTION 'event-order guard accepted invalid_at < valid_at';
    END IF;
    RAISE NOTICE 'OK 5/6  event-order guard: backwards validity refused';
END;
$guard$;

-- ---------------------------------------------------------------------
-- 6. COMPANION FIXES.
--    (a) graph_recall keeps its signature, defaults, and result shape — the
--        extension-function lock means a change here breaks every caller.
--    (b) import_doc no longer deletes CITES edges that are still cited: the
--        surviving edge keeps its ORIGINAL created_at across a re-import.
-- ---------------------------------------------------------------------
DO $companions$
DECLARE
    v_args text;
    v_res  text;
    v_edge_1 uuid;
    v_edge_2 uuid;
    v_kept int;
    v_dropped int;
BEGIN
    SELECT pg_get_function_arguments(oid), pg_get_function_result(oid)
      INTO v_args, v_res
      FROM pg_proc WHERE proname = 'graph_recall';
    IF v_args <> 'p_seeds jsonb, p_max_hops integer DEFAULT 3, p_limit integer DEFAULT 15, p_decay real DEFAULT 0.5' THEN
        RAISE EXCEPTION 'graph_recall signature drifted: [%]', v_args;
    END IF;
    IF v_res <> 'TABLE(kind text, ref text, label text, score real, hops integer)' THEN
        RAISE EXCEPTION 'graph_recall result shape drifted: [%]', v_res;
    END IF;
    -- It must still RUN (a guard that breaks the walk is worse than no guard).
    PERFORM * FROM stewards.graph_recall(
        jsonb_build_array(jsonb_build_object('kind','person','ref','v43-fixture-person')), 2, 5, 0.5);

    -- import_doc: import a doc citing two links, then re-import citing one.
    -- The fixture uses a FILE-PATH link on purpose: core parses it via
    -- parse_doc_links and the live overlay via parse_gospel_links, and the two
    -- accept different formats (the scripture:// URI form works only in core).
    -- The assertions below depend on edge IDENTITY, not on which node kind/ref
    -- each parser derives, so this block runs against either owner.
    PERFORM stewards.import_doc('v43-cites-fixture', '/tmp/v43.md', 'v43 cites fixture',
        E'See [Alma 32](../../gospel-library/eng/scriptures/bofm/alma/32.md)
 and [Moroni 10](../../gospel-library/eng/scriptures/bofm/moro/10.md).');

    -- Identity, NOT created_at. edges.created_at defaults to now(), which is
    -- the TRANSACTION timestamp — constant inside this rolled-back txn, so a
    -- created_at comparison passes even when the row IS destroyed and
    -- recreated. That exact vacuous check was written first and caught by
    -- negative-testing this file against the old function; edges.id defaults
    -- to gen_random_uuid(), so a delete-and-recreate changes it while an
    -- upsert-in-place preserves it.
    SELECT e.id INTO v_edge_1
      FROM stewards.edges e
      JOIN stewards.nodes s ON s.id = e.src
      JOIN stewards.nodes d ON d.id = e.dst
     WHERE s.ref = 'v43-cites-fixture' AND e.kind = 'CITES' AND d.ref LIKE '%alma%';
    IF v_edge_1 IS NULL THEN
        RAISE EXCEPTION 'import_doc did not create the expected CITES edge';
    END IF;

    -- Re-import: Alma still cited, Moroni dropped.
    PERFORM stewards.import_doc('v43-cites-fixture', '/tmp/v43.md', 'v43 cites fixture',
        E'See only [Alma 32](../../gospel-library/eng/scriptures/bofm/alma/32.md) now.');

    SELECT e.id INTO v_edge_2
      FROM stewards.edges e
      JOIN stewards.nodes s ON s.id = e.src
      JOIN stewards.nodes d ON d.id = e.dst
     WHERE s.ref = 'v43-cites-fixture' AND e.kind = 'CITES' AND d.ref LIKE '%alma%';

    IF v_edge_2 IS DISTINCT FROM v_edge_1 THEN
        RAISE EXCEPTION 'still-cited CITES edge was destroyed and recreated (edge id % -> %)',
            v_edge_1, v_edge_2;
    END IF;

    SELECT count(*) INTO v_dropped
      FROM stewards.edges e
      JOIN stewards.nodes s ON s.id = e.src
      JOIN stewards.nodes d ON d.id = e.dst
     WHERE s.ref = 'v43-cites-fixture' AND e.kind = 'CITES' AND d.ref LIKE '%moro%';
    IF v_dropped <> 0 THEN
        RAISE EXCEPTION 'a citation removed from the body must lose its edge (found %)', v_dropped;
    END IF;

    SELECT count(*) INTO v_kept
      FROM stewards.edges e JOIN stewards.nodes s ON s.id = e.src
     WHERE s.ref = 'v43-cites-fixture' AND e.kind = 'CITES';
    IF v_kept <> 1 THEN
        RAISE EXCEPTION 'expected exactly 1 surviving CITES edge, got %', v_kept;
    END IF;

    RAISE NOTICE 'OK 6/6  companions: graph_recall signature+walk intact; import_doc preserves still-cited history';
END;
$companions$;

ROLLBACK;

\echo 'verify-43-fact-edges: ALL CHECKS PASSED (transaction rolled back)'
