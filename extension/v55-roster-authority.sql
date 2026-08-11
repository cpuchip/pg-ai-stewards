-- =====================================================================
-- v55 — roster authority: exactly one active mapping, or nothing writes
-- =====================================================================
-- Codex's round-5 review of v54 (50a56f6a): under roster_required, an
-- active-roster MISS still returned NULL, and current_box/fact_recall_mine
-- then fell back to the raw role name — so an authorized-but-unrostered
-- principal (a surviving brain_* membership with no active roster row)
-- wrote and read under a fresh lane the roster never granted. And with
-- pg_role non-unique among active rows, LIMIT 1 made authority
-- nondeterministic. All three watched red on the v54 build (evidence file,
-- round 5):
--
--   box_ghost IN ROLE brain_absorb, no roster row, mode=roster_required:
--     brain_add -> 'added red5-ghost to lane box_ghost'      (fresh lane)
--   two active rows pg_role=box_dup:
--     box_for_role('box_dup') -> 'name-one'                  (LIMIT 1 luck)
--   revoked mapping, surviving role:
--     brain_add -> 'added red5-revoked to lane box_ghost'    (revocation moot)
--
-- v55, per the ruling: in roster_required the roster is not merely the
-- source — it is the AUTHORITY. Host resolves fermion; every other caller
-- requires EXACTLY ONE active mapping; zero (unenrolled, revoked) or more
-- than one (integrity broken) FAILS CLOSED at the box_for_role choke point,
-- which closes writes (stamp trigger), lane derivation, and mine-recall
-- together. The private roster gains a partial unique index on active
-- pg_role (brain-client DDL) and enrollment reorders to roster row →
-- posture flip → login role in ONE transaction, so access is granted last
-- and an aborted enrollment leaves nothing authorized. role_name posture is
-- untouched: lanes are role names there by declaration.
-- =====================================================================

-- Migration gate: refuse to upgrade over broken authority data.
DO $v55_preflight$
DECLARE v_dups text;
BEGIN
    IF to_regclass('house.roster') IS NOT NULL THEN
        SELECT string_agg(pg_role || ' (' || n || ' active rows)', ', ')
          INTO v_dups
          FROM (SELECT pg_role, count(*) AS n FROM house.roster
                 WHERE revoked_at IS NULL AND pg_role IS NOT NULL
                 GROUP BY pg_role HAVING count(*) > 1) d;
        IF v_dups IS NOT NULL THEN
            RAISE EXCEPTION
                'v55 migration abort: duplicate ACTIVE pg_role mapping(s) in '
                'house.roster: %. Authority must be deterministic before this '
                'volume applies — revoke the stale rows, add the partial unique '
                'index (brain-client DDL), and re-apply.', v_dups;
        END IF;
    END IF;
END
$v55_preflight$;

CREATE OR REPLACE FUNCTION stewards.box_for_role(p_role text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = stewards, house, pg_temp AS $fn$
DECLARE
    v_name text;
    v_mode text;
    v_n    bigint;
BEGIN
    v_mode := stewards.config_get_text('lane_identity_mode', NULL);
    IF v_mode IS NULL OR v_mode NOT IN ('role_name', 'roster_required') THEN
        RAISE EXCEPTION
            'lane identity FAIL-CLOSED (v53): lane_identity_mode is % — post-v52 '
            'this row always exists and never defaults (a reconstructed default '
            'is the silent-downgrade seam). Restore it with a lawful INSERT '
            '(role_name or roster_required; the guard validates) — and account '
            'for how it was lost.',
            coalesce('invalid (' || v_mode || ')', 'MISSING')
          USING ERRCODE = 'undefined_object';
    END IF;

    -- v54: posture chooses the source. role_name = role names, period.
    IF v_mode = 'role_name' THEN
        RETURN NULL;
    END IF;

    -- roster_required: the roster is the AUTHORITY (v55).
    IF to_regclass('house.roster') IS NULL THEN
        RAISE EXCEPTION
            'lane identity FAIL-CLOSED (v52): lane_identity_mode=roster_required '
            'but house.roster is missing (table or schema dropped, or a restore '
            'is incomplete). Lane derivation, writes, and mine-recall refuse '
            'until the roster is restored — or an accounted operator migration '
            'flips the mode.'
          USING ERRCODE = 'undefined_table';
    END IF;

    -- host special case: the substrate owner is fermion, not a roster row
    IF p_role IN ('stewards', 'postgres')
       OR EXISTS (SELECT 1 FROM pg_roles pr WHERE pr.rolname = p_role AND pr.rolsuper) THEN
        RETURN 'fermion';
    END IF;

    -- every other caller: EXACTLY ONE active mapping, or nothing
    SELECT count(*), min(r.name) INTO v_n, v_name FROM house.roster r
     WHERE r.pg_role = p_role AND r.revoked_at IS NULL;
    IF v_n = 0 THEN
        RAISE EXCEPTION
            'lane identity FAIL-CLOSED (v55): role % has NO active roster '
            'mapping under roster_required. A brain_* membership without an '
            'enrollment is not an identity — enroll the box (roster row first, '
            'role last) or revoke the role.', p_role
          USING ERRCODE = 'insufficient_privilege';
    ELSIF v_n > 1 THEN
        RAISE EXCEPTION
            'lane identity FAIL-CLOSED (v55): role % has % ACTIVE roster '
            'mappings — authority is nondeterministic. Revoke the stale rows '
            '(the partial unique index on active pg_role prevents this class).',
            p_role, v_n
          USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN v_name;
END;
$fn$;
COMMENT ON FUNCTION stewards.box_for_role(text) IS
'v49/v51-v55: the writing seat''s lane. role_name posture: NULL unconditionally (lanes are role names; any roster inert). roster_required posture: roster missing = fail-closed; host = fermion; every other role needs EXACTLY ONE active mapping — zero (unenrolled/revoked) or duplicates fail closed. SECURITY DEFINER — house is host-private.';

-- lane_check: the roster_required branch also audits mapping uniqueness.
CREATE OR REPLACE FUNCTION stewards.lane_check()
RETURNS TABLE (check_name text, ok boolean, detail text)
LANGUAGE plpgsql STABLE AS $fn$
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
COMMENT ON FUNCTION stewards.lane_check() IS
'v49/v51-v55 oracle: lanes present, forced, immutable; posture row present + valid + guarded (no defaults); source chosen by posture; under roster_required, active-mapping uniqueness audited and misses fail closed. Every trigger assertion bound to its table and origin-enabled. Plus threadchip''s falsifier rule.';
