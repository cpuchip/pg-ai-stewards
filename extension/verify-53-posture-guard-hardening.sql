-- v53 verification — posture guard hardening (key pin, no defaults).
--
-- Single-session, rolled back — live-safe. The missing-row fail-closed
-- simulation (which requires disabling the guards) is CI smoke's OK 120i;
-- here we prove the pins and the no-default consistency without touching
-- trigger state.
--
-- Run with:
--   Get-Content verify-53-posture-guard-hardening.sql | docker exec -i <pg> psql -U stewards -d stewards
\set ON_ERROR_STOP 1
BEGIN;

\echo === posture row exists, valid, and read with NO default ===
DO $$
DECLARE v_mode text;
BEGIN
    v_mode := stewards.config_get_text('lane_identity_mode', NULL);
    IF v_mode IS NULL THEN
        RAISE EXCEPTION 'V53 FAIL-CLOSED STATE: lane_identity_mode row MISSING — post-v52 it must always exist; this install is refusing writes';
    END IF;
    IF v_mode NOT IN ('role_name', 'roster_required') THEN
        RAISE EXCEPTION 'V53 FAIL-CLOSED STATE: lane_identity_mode invalid (%)', v_mode;
    END IF;
    RAISE NOTICE 'posture: mode=% (no-default read)', v_mode;
END $$;

\echo === three guard triggers, bound to stewards.config, enabled ===
DO $$
BEGIN
    -- v54: origin-enabled required — tgenabled 'R' (replica-only) never
    -- fires for normal sessions and must not satisfy this check.
    IF (SELECT count(*) FROM pg_trigger
         WHERE tgname LIKE 'lane_identity_mode_guard%' AND NOT tgisinternal
           AND tgenabled IN ('O', 'A')
           AND tgrelid = 'stewards.config'::regclass) <> 3 THEN
        RAISE EXCEPTION 'V53 GUARD INCOMPLETE: expected 3 ORIGIN-enabled lane_identity_mode_guard* triggers on stewards.config';
    END IF;
    RAISE NOTICE 'guards: OK (update/delete/insert legs present and origin-enabled)';
END $$;

\echo === the key is pinned: rename out and rename in both refuse ===
DO $$
DECLARE v_caught boolean;
BEGIN
    v_caught := false;
    BEGIN
        UPDATE stewards.config SET key = 'lane_identity_mode_old'
         WHERE key = 'lane_identity_mode';
    EXCEPTION WHEN integrity_constraint_violation THEN v_caught := true;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'V53 PIN OPEN: the posture row was renamed OUT of its key';
    END IF;

    INSERT INTO stewards.config (key, value)
    VALUES ('verify53-evil', to_jsonb('anarchy'::text));
    v_caught := false;
    BEGIN
        UPDATE stewards.config SET key = 'lane_identity_mode'
         WHERE key = 'verify53-evil';
    EXCEPTION WHEN integrity_constraint_violation THEN v_caught := true;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'V53 PIN OPEN: a foreign row was renamed INTO the posture key';
    END IF;
    RAISE NOTICE 'key pin: OK (rename out and rename in both rejected by the guard)';
END $$;

ROLLBACK;
