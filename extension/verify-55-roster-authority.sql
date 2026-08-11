-- v55 verification — roster authority (exactly one active mapping).
--
-- Single-session, rolled back — live-safe. The SET ROLE fail-closed writes
-- are CI smoke's OK 120j/120k; here we verify what a single session can:
-- the unenrolled miss raises, active mappings are unique, the host resolves,
-- and (advisory) the partial unique index exists where a roster does.
--
-- Run with:
--   Get-Content verify-55-roster-authority.sql | docker exec -i <pg> psql -U stewards -d stewards
\set ON_ERROR_STOP 1
BEGIN;

DO $$
DECLARE v_mode text; v_caught boolean; v_dups text;
BEGIN
    v_mode := stewards.config_get_text('lane_identity_mode', NULL);
    IF v_mode <> 'roster_required' THEN
        RAISE NOTICE 'v55 authority checks: mode=% — the authority semantics only bind under roster_required; CI covers them (OK 120j/120k)', coalesce(v_mode,'MISSING');
        RETURN;
    END IF;

    -- an unenrolled role fails closed (not NULL, not a fresh lane)
    v_caught := false;
    BEGIN
        PERFORM stewards.box_for_role('verify55_definitely_unenrolled');
    EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'V55 AUTHORITY OPEN: an unenrolled role resolved (or returned NULL for a role-name fallback) under roster_required';
    END IF;

    -- no duplicate active mappings on this install
    SELECT string_agg(pg_role || ' (' || n || ')', ', ') INTO v_dups
      FROM (SELECT pg_role, count(*) AS n FROM house.roster
             WHERE revoked_at IS NULL AND pg_role IS NOT NULL
             GROUP BY pg_role HAVING count(*) > 1) d;
    IF v_dups IS NOT NULL THEN
        RAISE EXCEPTION 'V55 DUPLICATE AUTHORITY: % — affected roles are failing closed; revoke the stale rows', v_dups;
    END IF;

    -- the host resolves fermion
    IF stewards.box_for_role('stewards') IS DISTINCT FROM 'fermion' THEN
        RAISE EXCEPTION 'V55 HOST: stewards did not resolve to fermion under roster_required';
    END IF;

    -- advisory: the partial unique index should guard the duplicate class
    IF NOT EXISTS (SELECT 1 FROM pg_indexes
                    WHERE schemaname = 'house' AND tablename = 'roster'
                      AND indexdef ILIKE '%pg_role%' AND indexdef ILIKE '%revoked_at IS NULL%') THEN
        RAISE NOTICE 'advisory: no partial unique index on active pg_role — run brain-client cmd_init (DDL adds it); until then duplicates are caught only at read time';
    END IF;

    RAISE NOTICE 'v55 authority: OK (unenrolled fails closed, mappings unique, host=fermion)';
END $$;

ROLLBACK;
