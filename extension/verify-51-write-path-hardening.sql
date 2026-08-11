-- v51 verification — write-path hardening (the sol-p0-release-batch).
--
-- Single-session checks only, rolled back — live-safe. The two-session race
-- regressions (concurrent add, concurrent amend) live in
-- tests/concurrency-write-path.sql, which is CI-ONLY (it installs dblink and
-- its probe writes commit). Red-first: every property here was watched fail
-- against the pre-v51 chain — .spec/reviews/sol-p0-release-batch-redrun-2026-08-11.md.
--
-- Run with:
--   Get-Content verify-51-write-path-hardening.sql | docker exec -i <pg> psql -U stewards -d stewards
\set ON_ERROR_STOP 1
BEGIN;

\echo === origin_box is immutable (reject trigger, both tables) ===
DO $$
DECLARE v_a uuid; v_b uuid; v_caught boolean;
BEGIN
    INSERT INTO stewards.nodes (kind, ref, label) VALUES ('memory','verify51-immut-a','probe a')
      RETURNING id INTO v_a;
    INSERT INTO stewards.nodes (kind, ref, label) VALUES ('memory','verify51-immut-b','probe b')
      RETURNING id INTO v_b;

    v_caught := false;
    BEGIN
        UPDATE stewards.nodes SET origin_box = 'forged' WHERE id = v_a;
    EXCEPTION WHEN integrity_constraint_violation THEN v_caught := true;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'ORIGIN_BOX REWRITTEN: post-insert lane forgery allowed on nodes';
    END IF;

    INSERT INTO stewards.fact_edges (src, dst, kind, fact)
    VALUES (v_a, v_b, 'RELATES', 'verify51 immutability probe edge');
    v_caught := false;
    BEGIN
        UPDATE stewards.fact_edges SET origin_box = 'forged'
         WHERE src = v_a AND dst = v_b;
    EXCEPTION WHEN integrity_constraint_violation THEN v_caught := true;
    END;
    IF NOT v_caught THEN
        RAISE EXCEPTION 'ORIGIN_BOX REWRITTEN: post-insert lane forgery allowed on fact_edges';
    END IF;

    -- a same-value SET must PASS: no-op writers survive the wall
    UPDATE stewards.nodes SET origin_box = origin_box WHERE id = v_a;
    RAISE NOTICE 'origin_box immutability: OK (changes rejected on both tables; no-op SET allowed)';
END $$;

\echo === p_force is operator-only ===
DO $$
DECLARE v_caught boolean := false;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'box_threadchip') THEN
        RAISE NOTICE 'p_force box path: SKIP — no box role on this install (CI covers it via box_smoke)';
    ELSE
        SET LOCAL ROLE box_threadchip;
        BEGIN
            PERFORM stewards.brain_add('verify51-force','Verify51 Force','h','b','reference', true);
        EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
        END;
        RESET ROLE;
        IF NOT v_caught THEN
            RAISE EXCEPTION 'P_FORCE OPEN: a box role forced past the collision guard';
        END IF;
        RAISE NOTICE 'p_force gate: OK (box refused)';
    END IF;
    -- the operator path stays open (collision override proper is
    -- brain_write_check (b); this proves the gate recognizes the host)
    PERFORM stewards.brain_add('verify51-force-host','Verify51 Force Host','h','b','reference', true);
    RAISE NOTICE 'p_force gate: OK (host allowed through)';
END $$;

\echo === function ACLs: reap + laned locked away; mine granted to brain_read ===
DO $$
BEGIN
    -- proacl NULL means DEFAULT privileges — which include PUBLIC EXECUTE
    IF (SELECT proacl IS NULL FROM pg_proc
         WHERE oid = 'stewards.brain_selftest_reap()'::regprocedure) THEN
        RAISE EXCEPTION 'REAP ACL DEFAULT: brain_selftest_reap has no explicit ACL (PUBLIC can execute a SECURITY DEFINER delete)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                WHERE p.oid = 'stewards.brain_selftest_reap()'::regprocedure
                  AND a.grantee = 0) THEN
        RAISE EXCEPTION 'REAP ACL PUBLIC: brain_selftest_reap is PUBLIC-executable';
    END IF;
    IF NOT has_function_privilege('brain_absorb', 'stewards.brain_selftest_reap()', 'EXECUTE') THEN
        RAISE EXCEPTION 'REAP ACL MISSING: brain_absorb lost its v50 reap grant';
    END IF;

    IF (SELECT proacl IS NULL FROM pg_proc
         WHERE oid = 'stewards.fact_recall_laned(jsonb,text,integer,integer,real,timestamptz,real)'::regprocedure) THEN
        RAISE EXCEPTION 'LANED ACL DEFAULT: fact_recall_laned has no explicit ACL (any caller can privilege a rival lane)';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
                WHERE p.oid = 'stewards.fact_recall_laned(jsonb,text,integer,integer,real,timestamptz,real)'::regprocedure
                  AND a.grantee = 0) THEN
        RAISE EXCEPTION 'LANED ACL PUBLIC: fact_recall_laned is PUBLIC-executable';
    END IF;

    IF NOT has_function_privilege('brain_read',
            'stewards.fact_recall_mine(jsonb,integer,integer,real,timestamptz,real)', 'EXECUTE') THEN
        RAISE EXCEPTION 'MINE ACL MISSING: brain_read cannot execute fact_recall_mine';
    END IF;
    RAISE NOTICE 'function ACLs: OK (reap + laned explicit and PUBLIC-free; mine granted)';
END $$;

\echo === box_for_role: lane derivation, POSTURE-AWARE (v54/v55) ===
-- Updated 2026-08-11 (live reconciliation): the original assumed "roster
-- present + unenrolled -> NULL", true through v53. v54 made posture (not
-- roster presence) the discriminator, and v55 made an unenrolled role
-- FAIL CLOSED under roster_required — so the branch must key on the posture.
DO $$
DECLARE v_role text; v_enrolled text; v_got text; v_mode text; v_caught boolean;
BEGIN
    v_mode := stewards.config_get_text('lane_identity_mode', NULL);
    IF v_mode = 'role_name' THEN
        -- v54: role_name -> NULL for ANY role; a present roster is inert.
        IF stewards.box_for_role('verify51_any_role') IS NOT NULL THEN
            RAISE EXCEPTION 'BOX_FOR_ROLE: returned a lane under role_name posture (roster must be inert)';
        END IF;
        RAISE NOTICE 'box_for_role: OK (role_name -> NULL, roster inert)';
    ELSIF v_mode = 'roster_required' THEN
        -- v55: unenrolled -> fail closed; host -> fermion; enrolled -> name.
        v_caught := false;
        BEGIN
            PERFORM stewards.box_for_role('verify51_definitely_unenrolled');
        EXCEPTION WHEN insufficient_privilege THEN v_caught := true;
        END;
        IF NOT v_caught THEN
            RAISE EXCEPTION 'BOX_FOR_ROLE: an unenrolled role did not fail closed under roster_required';
        END IF;
        SELECT r.pg_role, r.name INTO v_role, v_enrolled FROM house.roster r
         WHERE r.pg_role IS NOT NULL AND r.revoked_at IS NULL LIMIT 1;
        IF v_role IS NULL THEN
            RAISE NOTICE 'box_for_role: OK (roster_required: unenrolled fail-closed; no enrolled pg_role rows to check)';
        ELSE
            v_got := stewards.box_for_role(v_role);
            IF v_got IS DISTINCT FROM v_enrolled THEN
                RAISE EXCEPTION 'BOX_FOR_ROLE: enrolled role % resolved to %, roster says %',
                    v_role, coalesce(v_got, '<null>'), v_enrolled;
            END IF;
            RAISE NOTICE 'box_for_role: OK (roster_required: unenrolled fail-closed; enrolled % -> %)', v_role, v_enrolled;
        END IF;
    ELSE
        -- pre-v52 install (no posture row): the original structural fallback.
        IF to_regclass('house.roster') IS NULL
           AND stewards.box_for_role('verify51_any_role') IS NOT NULL THEN
            RAISE EXCEPTION 'BOX_FOR_ROLE: returned a lane with no roster and no posture row';
        END IF;
        RAISE NOTICE 'box_for_role: OK (no posture row — pre-v52 structural fallback)';
    END IF;
END $$;

\echo === fact_recall_mine executes for the host (lane derived, not chosen) ===
DO $$
BEGIN
    PERFORM * FROM stewards.fact_recall_mine(
        '[{"kind":"memory","ref":"verify51-immut-a"}]'::jsonb, 1, 3);
    RAISE NOTICE 'fact_recall_mine: OK (executes; SET ROLE testability limit documented at v51 — only a real box login exercises a non-host lane)';
END $$;

ROLLBACK;
