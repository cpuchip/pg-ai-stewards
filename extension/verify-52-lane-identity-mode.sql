-- v52 verification — lane identity mode (posture row, guard, consistency).
--
-- Single-session, rolled back — live-safe. The destructive fail-closed
-- cases (DROP TABLE / DROP SCHEMA under roster_required, and the recovery)
-- are CI smoke's OK 120c–g — they cannot run against a live roster.
--
-- Run with:
--   Get-Content verify-52-lane-identity-mode.sql | docker exec -i <pg> psql -U stewards -d stewards
\set ON_ERROR_STOP 1
BEGIN;

\echo === posture row present, valid, guarded ===
DO $$
DECLARE v_mode text;
BEGIN
    v_mode := stewards.config_get_text('lane_identity_mode', 'MISSING');
    IF v_mode = 'MISSING' THEN
        RAISE EXCEPTION 'V52 NOT SEEDED: no lane_identity_mode row (has the migration been applied?)';
    END IF;
    IF v_mode NOT IN ('role_name', 'roster_required') THEN
        RAISE EXCEPTION 'V52 INVALID MODE: %', v_mode;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgname = 'lane_identity_mode_guard' AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'V52 GUARD MISSING: lane_identity_mode_guard trigger absent';
    END IF;
    RAISE NOTICE 'posture: mode=% (guarded)', v_mode;
END $$;

\echo === posture/roster consistency ===
DO $$
DECLARE v_mode text;
BEGIN
    v_mode := stewards.config_get_text('lane_identity_mode', 'MISSING');
    IF v_mode = 'roster_required' AND to_regclass('house.roster') IS NULL THEN
        RAISE EXCEPTION 'V52 FAIL-CLOSED STATE: roster_required with house.roster MISSING — this install is refusing writes (restore the roster or run the accounted operator migration)';
    END IF;
    IF v_mode = 'role_name' AND to_regclass('house.roster') IS NOT NULL THEN
        RAISE NOTICE 'consistency note: roster present under role_name posture — lawful (pre-enrollment), but if boxes are enrolled the enrollment path should have flipped the mode';
    END IF;
    RAISE NOTICE 'consistency: OK';
END $$;

\echo === guard behavior: forward-only, no unknown value, no delete ===
DO $$
DECLARE v_mode text; v_caught boolean;
BEGIN
    v_mode := stewards.config_get_text('lane_identity_mode', 'MISSING');

    -- forward transition allowed (exercised only when starting from role_name;
    -- everything here rolls back with the outer transaction)
    IF v_mode = 'role_name' THEN
        UPDATE stewards.config SET value = to_jsonb('roster_required'::text)
         WHERE key = 'lane_identity_mode';
    END IF;

    -- reverse rejected as an ordinary UPDATE
    v_caught := false;
    BEGIN
        UPDATE stewards.config SET value = to_jsonb('role_name'::text)
         WHERE key = 'lane_identity_mode';
    EXCEPTION WHEN integrity_constraint_violation THEN v_caught := true;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'V52 GUARD OPEN: roster_required -> role_name passed as an ordinary UPDATE';
    END IF;

    -- unknown value rejected
    v_caught := false;
    BEGIN
        UPDATE stewards.config SET value = to_jsonb('anarchy'::text)
         WHERE key = 'lane_identity_mode';
    EXCEPTION WHEN invalid_parameter_value THEN v_caught := true;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'V52 GUARD OPEN: an unknown mode value was accepted';
    END IF;

    -- delete rejected
    v_caught := false;
    BEGIN
        DELETE FROM stewards.config WHERE key = 'lane_identity_mode';
    EXCEPTION WHEN integrity_constraint_violation THEN v_caught := true;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'V52 GUARD OPEN: the posture row was deleted';
    END IF;

    RAISE NOTICE 'guard: OK (forward-only; unknown value, reverse, delete all rejected)';
END $$;

ROLLBACK;
