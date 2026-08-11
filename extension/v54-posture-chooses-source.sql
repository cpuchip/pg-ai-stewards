-- =====================================================================
-- v54 — posture chooses the source: role_name means role names, period
-- =====================================================================
-- Codex's round-4 review of v53 (5ae8901b): the mode row was validated but
-- not USED to choose the identity source — in role_name posture,
-- box_for_role still consulted house.roster whenever the table existed. So
-- creating or restoring a roster (a backup restore, an experiment, an
-- enrollment prepared early) silently changed every box's lane derivation
-- with no posture transition. Watched red on the v53 build:
--
--   declared_mode = role_name
--   CREATE TABLE house.roster; INSERT ... ('box','probename',...,'box_probe');
--   SELECT stewards.box_for_role('box_probe');   -- 'probename'  (roster answered)
--
-- v54 makes posture CAUSAL, not diagnostic:
--   role_name        -> box_for_role returns NULL unconditionally; lanes are
--                       role names; an existing roster is INERT until the
--                       explicit forward flip.
--   roster_required  -> the roster is required (missing = fail-closed, v52)
--                       and is THE source.
--
-- Second closure, the oracle's own skin: tgenabled <> 'D' accepted 'R'
-- (replica-only) — a trigger that never fires in origin sessions satisfied
-- lane_check while the stamp silently stopped stamping (watched: ENABLE
-- REPLICA TRIGGER stamp_origin_box; lane_check green; next INSERT stamped
-- NULL). Every trigger assertion now requires tgenabled IN ('O','A').
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.box_for_role(p_role text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = stewards, house, pg_temp AS $fn$
DECLARE
    v_name text;
    v_mode text;
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

    -- v54: the posture CHOOSES the source. Under role_name, lanes are role
    -- names unconditionally — an existing roster is inert until the explicit
    -- forward flip. (v53 consulted it whenever present, so restoring a
    -- backup silently changed lane derivation with no transition.)
    IF v_mode = 'role_name' THEN
        RETURN NULL;
    END IF;

    -- roster_required: the roster is required, and it is THE source.
    IF to_regclass('house.roster') IS NULL THEN
        RAISE EXCEPTION
            'lane identity FAIL-CLOSED (v52): lane_identity_mode=roster_required '
            'but house.roster is missing (table or schema dropped, or a restore '
            'is incomplete). Lane derivation, writes, and mine-recall refuse '
            'until the roster is restored — or an accounted operator migration '
            'flips the mode.'
          USING ERRCODE = 'undefined_table';
    END IF;
    SELECT r.name INTO v_name FROM house.roster r
     WHERE r.pg_role = p_role AND r.revoked_at IS NULL LIMIT 1;
    RETURN v_name;
END;
$fn$;
COMMENT ON FUNCTION stewards.box_for_role(text) IS
'v49/v51-v54: the writing seat''s lane source, CHOSEN by posture. role_name: NULL unconditionally (lanes are role names; any roster is inert). roster_required: roster required (missing = fail-closed) and authoritative. Missing/invalid posture row fails closed in both postures. SECURITY DEFINER — house is host-private.';

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

    -- (b) the stamp is forced — v54: fires-in-origin-sessions required
    --     (tgenabled 'R' satisfied v53's check while stamping NULL).
    RETURN QUERY SELECT 'stamp_is_forced',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'stamp_origin_box' AND NOT tgisinternal
            AND tgenabled IN ('O', 'A')
            AND tgrelid IN ('stewards.nodes'::regclass, 'stewards.fact_edges'::regclass)),
        'BEFORE INSERT triggers present AND origin-enabled on nodes + fact_edges';

    -- (b2, v51) the stamp is also immutable — same binding discipline
    RETURN QUERY SELECT 'stamp_is_immutable',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'reject_origin_box_change' AND NOT tgisinternal
            AND tgenabled IN ('O', 'A')
            AND tgrelid IN ('stewards.nodes'::regclass, 'stewards.fact_edges'::regclass)),
        'BEFORE UPDATE OF origin_box triggers present AND origin-enabled on nodes + fact_edges';

    -- (b3, v52/v53) the posture row is present, valid, and guarded on all
    -- three verbs — no-default read, guards origin-enabled on config.
    v_mode := stewards.config_get_text('lane_identity_mode', NULL);
    RETURN QUERY SELECT 'lane_identity_mode_valid',
        v_mode IN ('role_name', 'roster_required')
        AND (SELECT count(*) = 3 FROM pg_trigger
              WHERE tgname LIKE 'lane_identity_mode_guard%' AND NOT tgisinternal
                AND tgenabled IN ('O', 'A')
                AND tgrelid = 'stewards.config'::regclass),
        'mode=' || coalesce(v_mode, 'MISSING')
            || '; guard triggers (update/delete/insert) present AND origin-enabled on stewards.config';

    -- (c) lane resolution, source chosen by posture (v54).
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
'v49/v51-v54 oracle: lanes present, forced, immutable; posture row present + valid + guarded (no defaults); lane source CHOSEN by posture (role_name = role names, roster inert; roster_required = roster authoritative or fail-closed red); every trigger assertion bound to its table and ORIGIN-ENABLED (tgenabled O/A — replica-only does not fire and does not count). Plus threadchip''s falsifier rule.';
