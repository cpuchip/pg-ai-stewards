-- v54 verification — posture chooses the identity source.
--
-- Single-session, rolled back — live-safe. The role_name-inert red (roster
-- present, mode role_name, box_for_role must stay NULL) is CI smoke's OK
-- 120; on a roster_required install that state is unreachable without the
-- accounted disable path, so here we verify whichever posture the install
-- declares, plus the origin-enabled trigger discipline.
--
-- Run with:
--   Get-Content verify-54-posture-chooses-source.sql | docker exec -i <pg> psql -U stewards -d stewards
\set ON_ERROR_STOP 1
BEGIN;

\echo === the declared posture and its source agree ===
DO $$
DECLARE v_mode text; v_role text; v_enrolled text; v_got text;
BEGIN
    v_mode := stewards.config_get_text('lane_identity_mode', NULL);
    IF v_mode IS NULL OR v_mode NOT IN ('role_name', 'roster_required') THEN
        RAISE EXCEPTION 'V54 FAIL-CLOSED STATE: lane_identity_mode is %',
            coalesce(v_mode, 'MISSING');
    END IF;

    IF v_mode = 'role_name' THEN
        -- the roster (present or not) must be INERT
        IF stewards.box_for_role('verify54_any_role') IS NOT NULL THEN
            RAISE EXCEPTION 'V54 SOURCE LEAK: box_for_role answered under role_name posture';
        END IF;
        IF to_regclass('house.roster') IS NOT NULL THEN
            RAISE NOTICE 'source: OK (role_name declared; roster present but inert)';
        ELSE
            RAISE NOTICE 'source: OK (role_name declared; no roster)';
        END IF;
    ELSE
        -- roster_required: the roster must exist and be authoritative
        IF to_regclass('house.roster') IS NULL THEN
            RAISE EXCEPTION 'V54 FAIL-CLOSED STATE: roster_required with house.roster missing';
        END IF;
        IF stewards.box_for_role('verify54_definitely_unenrolled') IS NOT NULL THEN
            RAISE EXCEPTION 'V54: an unenrolled role resolved to a lane';
        END IF;
        SELECT r.pg_role, r.name INTO v_role, v_enrolled FROM house.roster r
         WHERE r.pg_role IS NOT NULL AND r.revoked_at IS NULL LIMIT 1;
        IF v_role IS NULL THEN
            RAISE NOTICE 'source: roster_required, no enrolled pg_role rows — resolution vacuous here';
        ELSE
            v_got := stewards.box_for_role(v_role);
            IF v_got IS DISTINCT FROM v_enrolled THEN
                RAISE EXCEPTION 'V54: enrolled role % resolved to %, roster says %',
                    v_role, coalesce(v_got, '<null>'), v_enrolled;
            END IF;
            RAISE NOTICE 'source: OK (roster_required; enrolled % -> %)', v_role, v_enrolled;
        END IF;
    END IF;
END $$;

\echo === every lane trigger is origin-enabled (replica-only does not count) ===
DO $$
BEGIN
    IF (SELECT count(*) FROM pg_trigger
         WHERE tgname = 'stamp_origin_box' AND NOT tgisinternal
           AND tgenabled IN ('O', 'A')
           AND tgrelid IN ('stewards.nodes'::regclass, 'stewards.fact_edges'::regclass)) <> 2 THEN
        RAISE EXCEPTION 'V54: stamp_origin_box not origin-enabled on both tables';
    END IF;
    IF (SELECT count(*) FROM pg_trigger
         WHERE tgname = 'reject_origin_box_change' AND NOT tgisinternal
           AND tgenabled IN ('O', 'A')
           AND tgrelid IN ('stewards.nodes'::regclass, 'stewards.fact_edges'::regclass)) <> 2 THEN
        RAISE EXCEPTION 'V54: reject_origin_box_change not origin-enabled on both tables';
    END IF;
    IF (SELECT count(*) FROM pg_trigger
         WHERE tgname LIKE 'lane_identity_mode_guard%' AND NOT tgisinternal
           AND tgenabled IN ('O', 'A')
           AND tgrelid = 'stewards.config'::regclass) <> 3 THEN
        RAISE EXCEPTION 'V54: lane_identity_mode_guard* not origin-enabled (3 expected) on stewards.config';
    END IF;
    RAISE NOTICE 'triggers: OK (stamp x2, reject x2, guard x3 — all origin-enabled, bound to their tables)';
END $$;

ROLLBACK;
