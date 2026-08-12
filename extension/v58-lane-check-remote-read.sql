-- ---------------------------------------------------------------------
-- v58 — lane_check(), runnable from the boxes whose lanes it is about.
--
-- FOUND BY NOCIX (#705, and it sat unread for two days behind a routing
-- bug). stewards.lane_check() was INVOKER and reads house.roster, which is
-- host-private — no box role has USAGE on that schema. So the instrument
-- that proves lane integrity died with
--
--     permission denied for schema house
--
-- from ANY remote box. nocix and threadchip could only take lane
-- correctness on fermion's report of fermion's own run: verify-real-path,
-- broken at fleet scale, on the one check that is about everybody.
--
-- THE FIX IS THE PATTERN box_for_role ALREADY PROVES (v49:66-72): SECURITY
-- DEFINER, narrow, SET search_path, REVOKE ALL FROM PUBLIC, explicit GRANT
-- to brain_read — which brain_absorb is a member of (bootstrap), so every
-- enrolled box reaches it. NOTHING here widens write access to house: this
-- function only SELECTs, and it is STABLE.
--
-- WHY DEFINER IS SAFE HERE, read rather than assumed: lane_check's entire
-- body is GLOBAL — counts of NULL-lane nodes and fact_edges, the four stamp
-- triggers via pg_trigger, roster resolution, threadchip's falsifier rule.
-- There is no current_user in it and nothing caller-relative. Definer
-- changes WHO MAY RUN IT, not what it reports.
--
-- That distinction is the whole reason box_for_role takes the role as a
-- PARAMETER instead of reading current_user: inside a definer function
-- current_user is the OWNER, and that would have silently attributed every
-- box's writes to fermion. v49's own comment records it, caught by its own
-- negative test before shipping. A function that DID report per-caller
-- state must not get this treatment; this one does not.
--
-- Body is v55's verbatim — the CURRENT one. lane_check is re-authored six
-- times in the chain (v49, v51, v52, v53, v54, v55): posture-awareness,
-- per-table trigger binding, posture-chooses-source, roster authority. This
-- file carries the LAST, verified byte-identical against the installed
-- prosrc on a live v57 cluster — not against whichever definition a
-- truncated grep happened to show first.
-- Oracle: virgin-smoke OK 120m (red on v57 with exactly the error above;
-- green after, the box seat's FULL ORDERED RESULT SET equal to the host's,
-- and a role outside brain_read still refused).
--
-- BOUNDARY, named rather than overclaimed: that oracle uses SET ROLE, which
-- proves EXECUTE and schema privilege AS the box role — the defect nocix hit
-- — but does NOT change session_user, so it is not a literal remote-session
-- equivalence test. Sound for THIS function because the body below reads
-- neither session_user nor current_user (verified, not assumed). If a
-- caller-relative check is ever added here, that oracle will not notice, and
-- a real separate-login harness becomes required.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.lane_check()
RETURNS TABLE (check_name text, ok boolean, detail text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = stewards, house, pg_temp AS $fn$
DECLARE
    v_n bigint; v_txt text; v_mode text;
BEGIN
    -- (a) every memory node and live edge carries a lane
    SELECT count(*) INTO v_n FROM stewards.nodes WHERE origin_box IS NULL;
    RETURN QUERY SELECT 'nodes_have_lane', v_n = 0,
        v_n || ' node(s) with NULL origin_box';
    SELECT count(*) INTO v_n FROM stewards.fact_edges WHERE origin_box IS NULL;
    RETURN QUERY SELECT 'edges_have_lane', v_n = 0,
        v_n || ' fact_edge(s) with NULL origin_box';

    -- (b) the stamp is forced — origin-enabled on its own tables (v54)
    RETURN QUERY SELECT 'stamp_is_forced',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'stamp_origin_box' AND NOT tgisinternal
            AND tgenabled IN ('O', 'A')
            AND tgrelid IN ('stewards.nodes'::regclass, 'stewards.fact_edges'::regclass)),
        'BEFORE INSERT triggers present AND origin-enabled on nodes + fact_edges';

    -- (b2, v51) the stamp is also immutable
    RETURN QUERY SELECT 'stamp_is_immutable',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'reject_origin_box_change' AND NOT tgisinternal
            AND tgenabled IN ('O', 'A')
            AND tgrelid IN ('stewards.nodes'::regclass, 'stewards.fact_edges'::regclass)),
        'BEFORE UPDATE OF origin_box triggers present AND origin-enabled on nodes + fact_edges';

    -- (b3, v52/v53) the posture row is present, valid, guarded
    v_mode := stewards.config_get_text('lane_identity_mode', NULL);
    RETURN QUERY SELECT 'lane_identity_mode_valid',
        v_mode IN ('role_name', 'roster_required')
        AND (SELECT count(*) = 3 FROM pg_trigger
              WHERE tgname LIKE 'lane_identity_mode_guard%' AND NOT tgisinternal
                AND tgenabled IN ('O', 'A')
                AND tgrelid = 'stewards.config'::regclass),
        'mode=' || coalesce(v_mode, 'MISSING')
            || '; guard triggers (update/delete/insert) present AND origin-enabled on stewards.config';

    -- (c) lane resolution, source chosen by posture (v54), authority
    --     audited under roster_required (v55).
    IF v_mode IS NULL OR v_mode NOT IN ('role_name', 'roster_required') THEN
        RETURN QUERY SELECT 'posture_fail_closed', false,
            'lane_identity_mode is ' || coalesce('invalid (' || v_mode || ')', 'MISSING')
            || ' — lane derivation, writes, and mine-recall are failing closed; '
            || 'restore the row with a lawful INSERT and account for how it was lost';
    ELSIF v_mode = 'role_name' THEN
        RETURN QUERY SELECT 'lanes_are_seats', true,
            'role_name posture (declared): lanes are role names'
            || CASE WHEN to_regclass('house.roster') IS NOT NULL
                    THEN '; a roster is present but INERT until the explicit flip'
                    ELSE '' END;
    ELSIF to_regclass('house.roster') IS NULL THEN
        RETURN QUERY SELECT 'roster_required_fail_closed', false,
            'lane_identity_mode=roster_required but house.roster is MISSING — '
            'authority data dropped or restore incomplete; lane derivation, '
            'writes, and mine-recall are failing closed until it is restored '
            '(or an accounted operator migration flips the mode)';
    ELSE
        -- (c1, v55) active mappings are unique per pg_role
        SELECT string_agg(pg_role || ' (' || n || ')', ', ') INTO v_txt
          FROM (SELECT pg_role, count(*) AS n FROM house.roster
                 WHERE revoked_at IS NULL AND pg_role IS NOT NULL
                 GROUP BY pg_role HAVING count(*) > 1) d;
        RETURN QUERY SELECT 'roster_pg_role_unique', v_txt IS NULL,
            COALESCE('duplicate ACTIVE pg_role mapping(s): ' || v_txt
                     || ' — affected roles are failing closed',
                     'every active pg_role maps exactly once');

        SELECT string_agg(DISTINCT origin_box, ', ') INTO v_txt
          FROM stewards.nodes n
         WHERE n.origin_box IS NOT NULL
           AND n.origin_box <> 'fermion'
           AND NOT EXISTS (SELECT 1 FROM house.roster r
                            WHERE r.name = n.origin_box);
        RETURN QUERY SELECT 'lanes_are_seats', v_txt IS NULL,
            COALESCE('unknown lane(s): ' || v_txt, 'all lanes resolve to roster seats');
    END IF;

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

-- The read is definer'd; it is NOT public. Same shape as box_for_role.
REVOKE ALL ON FUNCTION stewards.lane_check() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION stewards.lane_check() TO brain_read;

COMMENT ON FUNCTION stewards.lane_check() IS
'v49/v51 oracle, v58 made fleet-runnable: lanes present, forced, immutable, and resolvable (roster-less installs vacuously green by design); plus threadchip''s falsifier rule on quantitative memory claims. SECURITY DEFINER because it reads host-private house.roster and every box needs to verify its own lanes rather than take the host''s word (nocix #705); safe because the body is entirely global — no current_user, nothing caller-relative, no writes. REVOKE PUBLIC + GRANT to brain_read (brain_absorb inherits).';
