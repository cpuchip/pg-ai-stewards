-- v50 verification — the guarded lane write path (add / amend).
--
-- Runs brain_write_check() (collision refusal + p_force override) and the two
-- properties that need a second role: a box cannot amend another box's memory,
-- and amend strikes-in-place. All inside a rolled-back transaction.
--
-- Run with:
--   Get-Content verify-50-lane-write-path.sql | docker exec -i <pg> psql -U stewards -d stewards

\set ON_ERROR_STOP 1
BEGIN;

\echo === brain_write_check (collision + force) ===
SELECT check_name, ok, detail FROM stewards.brain_write_check();

DO $$
DECLARE r record; bad text := '';
BEGIN
    FOR r IN SELECT * FROM stewards.brain_write_check() WHERE NOT ok LOOP
        bad := bad || r.check_name || ' (' || r.detail || '); ';
    END LOOP;
    IF bad <> '' THEN RAISE EXCEPTION 'BRAIN WRITE CHECK FAILED: %', bad; END IF;
    RAISE NOTICE 'brain_write_check: green';
END $$;

\echo === cross-lane amend is refused; own-lane amend strikes in place ===
DO $$
DECLARE v_body text; v_refused boolean := false;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='box_threadchip') THEN
        RAISE NOTICE 'cross-lane: SKIP — no box role on this install';
        RETURN;
    END IF;

    -- fermion (this session) writes a memory in its lane
    PERFORM stewards.brain_add('verify50-fermion','Verify50 Fermion','h','fermion body');

    -- a box tries to amend it -> must refuse
    SET LOCAL ROLE box_threadchip;
    BEGIN
        PERFORM stewards.brain_amend('verify50-fermion','sneaky');
    EXCEPTION WHEN insufficient_privilege THEN v_refused := true;
    END;

    -- the box amends its OWN memory -> strike in place
    PERFORM stewards.brain_add('verify50-own','Verify50 Own','claim','value is 5 always');
    PERFORM stewards.brain_amend('verify50-own','value is 5 only under load','value is 5 always');
    SELECT props->>'body' INTO v_body FROM stewards.nodes WHERE ref='verify50-own';
    RESET ROLE;

    IF NOT v_refused THEN
        RAISE EXCEPTION 'CROSS-LANE AMEND WAS ALLOWED — a box edited another lane';
    END IF;
    IF v_body NOT LIKE '%~~value is 5 always~~%' OR v_body NOT LIKE '%CORRECTED%' THEN
        RAISE EXCEPTION 'AMEND DID NOT STRIKE IN PLACE: %', v_body;
    END IF;
    RAISE NOTICE 'lane write path: OK (cross-lane refused; own-lane struck-and-corrected)';
END $$;

ROLLBACK;
