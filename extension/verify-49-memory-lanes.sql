-- v49 verification — memory lanes, attribution, and the falsifier rule.
--
-- Runs stewards.lane_check() and fails loudly on any red. Also proves the
-- two properties a static check cannot: that the lane stamp is UNFORGEABLE
-- (a box role's explicit origin_box is discarded), and that lane-first
-- recall actually reorders. Both run inside a rolled-back transaction.
--
-- Run with:
--   Get-Content verify-49-memory-lanes.sql | docker exec -i <pg> psql -U stewards -d stewards

\set ON_ERROR_STOP 1
BEGIN;

\echo === lane_check ===
SELECT check_name, ok, detail FROM stewards.lane_check();

DO $$
DECLARE r record; v_bad text := '';
BEGIN
    FOR r IN SELECT * FROM stewards.lane_check() WHERE NOT ok LOOP
        v_bad := v_bad || r.check_name || ' (' || r.detail || '); ';
    END LOOP;
    IF v_bad <> '' THEN
        RAISE EXCEPTION 'LANE CHECK FAILED: %', v_bad;
    END IF;
    RAISE NOTICE 'lane_check: all green';
END $$;

\echo === the stamp is unforgeable (box role cannot claim another lane) ===
DO $$
DECLARE v_lane text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'box_threadchip') THEN
        RAISE NOTICE 'unforgeable: SKIP — no box role on this install';
        RETURN;
    END IF;
    SET LOCAL ROLE box_threadchip;
    INSERT INTO stewards.nodes (kind, ref, label, props, origin_box)
    VALUES ('memory', 'verify49-forge', 'forge attempt',
            '{"index_hook":"no numbers here"}'::jsonb, 'fermion');
    SELECT origin_box INTO v_lane FROM stewards.nodes WHERE ref = 'verify49-forge';
    RESET ROLE;
    IF v_lane <> 'threadchip' THEN
        RAISE EXCEPTION 'FORGEABLE LANE: a box_threadchip write claiming fermion landed as %', v_lane;
    END IF;
    RAISE NOTICE 'unforgeable: OK (claimed fermion, stamped %)', v_lane;
END $$;

\echo === lane-first recall reorders at equal relevance ===
DO $$
DECLARE v_seed uuid; v_mine uuid; v_theirs uuid; v_first text;
BEGIN
    INSERT INTO stewards.nodes (kind, ref, label) VALUES ('memory','verify49-seed','seed')
      RETURNING id INTO v_seed;
    INSERT INTO stewards.nodes (kind, ref, label) VALUES ('memory','verify49-shared','shared')
      RETURNING id INTO v_theirs;
    INSERT INTO stewards.nodes (kind, ref, label) VALUES ('memory','verify49-mine','mine')
      RETURNING id INTO v_mine;
    -- identical single-hop edges: the ONLY difference will be the lane
    INSERT INTO stewards.fact_edges (src, dst, kind, fact)
    VALUES (v_seed, v_theirs, 'RELATES', 'verify49 equal-weight edge a'),
           (v_seed, v_mine,   'RELATES', 'verify49 equal-weight edge b');
    -- v51: origin_box is immutable (reject trigger). This SETUP plants two
    -- different lanes to test recall ordering, so it steps around the wall
    -- the way an accounted administrative migration would — replica mode,
    -- inside this rolled-back transaction only. The wall itself is verified
    -- in verify-51 (change rejected) and CI smoke.
    SET LOCAL session_replication_role = 'replica';
    UPDATE stewards.nodes SET origin_box = 'otherbox' WHERE id = v_theirs;
    UPDATE stewards.nodes SET origin_box = 'fermion'  WHERE id = v_mine;
    SET LOCAL session_replication_role = 'origin';

    SELECT ref INTO v_first FROM stewards.fact_recall_laned(
        '[{"kind":"memory","ref":"verify49-seed"}]'::jsonb, 'fermion', 1, 5) LIMIT 1;
    IF v_first <> 'verify49-mine' THEN
        RAISE EXCEPTION 'LANE-FIRST FAILED: expected own-lane node first, got %', v_first;
    END IF;

    -- and the other seat sees ITS own first, from the same record
    SELECT ref INTO v_first FROM stewards.fact_recall_laned(
        '[{"kind":"memory","ref":"verify49-seed"}]'::jsonb, 'otherbox', 1, 5) LIMIT 1;
    IF v_first <> 'verify49-shared' THEN
        RAISE EXCEPTION 'LANE-FIRST NOT PER-CALLER: otherbox got % first', v_first;
    END IF;
    RAISE NOTICE 'lane-first: OK (each caller sees its own lane first; nothing filtered)';
END $$;

ROLLBACK;
