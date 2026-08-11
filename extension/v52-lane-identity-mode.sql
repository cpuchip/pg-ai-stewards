-- =====================================================================
-- v52 — lane identity mode: posture is declared, sticky, and fail-closed
-- =====================================================================
-- Codex's authority-semantics ruling on v51's roster-absence fallback
-- (review of e79895fc, 2026-08-11): STRUCTURAL ABSENCE IS NOT PUBLIC
-- POSTURE. to_regclass('house.roster') is mutable database state; letting
-- its disappearance silently change the identity function from roster name
-- to role name means dropping authority data DOWNGRADES the authority model
-- with no tell. Posture must be chosen, recorded, and never auto-downgraded.
--
--   lane_identity_mode = 'role_name'        public-install posture: lanes
--                                           are role names; no roster needed.
--   lane_identity_mode = 'roster_required'  enrollment posture: the roster
--                                           is the identity source; if it is
--                                           MISSING (table or schema), lane
--                                           derivation, writes through the
--                                           stamp trigger, and mine-recall
--                                           all FAIL CLOSED and lane_check
--                                           goes red until it is restored —
--                                           or an operator migration flips
--                                           the mode, accounted.
--
-- Sticky: seeded once from roster presence at install/upgrade time, ON
-- CONFLICT DO NOTHING. Guarded: the row cannot be deleted, cannot take an
-- unknown value, and the ONLY normal transition is role_name →
-- roster_required (the private enrollment path flips it before granting
-- writers). The reverse is an explicit operator migration: disable the
-- guard trigger, update, re-enable — and account for it (same
-- disable-and-account path as origin_box immutability).
-- =====================================================================

-- The posture row. Sticky — a re-run never overwrites a chosen mode.
INSERT INTO stewards.config (key, value, description)
VALUES ('lane_identity_mode',
        to_jsonb(CASE WHEN to_regclass('house.roster') IS NOT NULL
                      THEN 'roster_required' ELSE 'role_name' END),
        'v52: lane identity posture. role_name = lanes are pg role names (public-install posture). roster_required = house.roster is the identity source and its absence fails closed. Forward-only (role_name -> roster_required); reverse or delete = operator migration via disable-trigger-and-account.')
ON CONFLICT (key) DO NOTHING;

-- The guard: the mode row is not ordinarily writable history.
CREATE OR REPLACE FUNCTION stewards.lane_identity_mode_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE
    v_old text; v_new text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'lane_identity_mode cannot be deleted (v52). Removing the posture row '
            'would resurrect the silent-downgrade seam it exists to close. An '
            'operator migration disables trigger lane_identity_mode_guard on '
            'stewards.config, acts, re-enables — and accounts for it.'
          USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    v_old := OLD.value #>> '{}';
    v_new := NEW.value #>> '{}';
    IF v_new NOT IN ('role_name', 'roster_required') THEN
        RAISE EXCEPTION
            'lane_identity_mode must be role_name or roster_required, got %', v_new
          USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_old = 'roster_required' AND v_new = 'role_name' THEN
        RAISE EXCEPTION
            'lane_identity_mode: roster_required -> role_name is an authority '
            'DOWNGRADE and never an ordinary UPDATE (v52). It is an explicit '
            'operator migration: ALTER TABLE stewards.config DISABLE TRIGGER '
            'lane_identity_mode_guard; update; re-enable — and account for it.'
          USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$fn$;
COMMENT ON FUNCTION stewards.lane_identity_mode_guard() IS
'v52: the posture row''s wall. No delete, no unknown value, forward-only transition (role_name -> roster_required). Reverse = disable-and-account operator migration.';

DROP TRIGGER IF EXISTS lane_identity_mode_guard ON stewards.config;
CREATE TRIGGER lane_identity_mode_guard
    BEFORE UPDATE OR DELETE ON stewards.config
    FOR EACH ROW WHEN (OLD.key = 'lane_identity_mode')
    EXECUTE FUNCTION stewards.lane_identity_mode_guard();

-- ---------------------------------------------------------------------
-- box_for_role, mode-aware. Replaces v51's structural-absence fallback:
-- absence is only a lawful posture when the recorded mode SAYS role_name;
-- under roster_required it fails closed. (A missing mode row can only mean
-- an install mid-upgrade — it derives from roster presence, matching what
-- the seed would have written.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.box_for_role(p_role text) RETURNS text
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = stewards, house, pg_temp AS $fn$
DECLARE
    v_name text;
    v_mode text;
BEGIN
    v_mode := stewards.config_get_text('lane_identity_mode',
        CASE WHEN to_regclass('house.roster') IS NOT NULL
             THEN 'roster_required' ELSE 'role_name' END);
    IF to_regclass('house.roster') IS NULL THEN
        IF v_mode = 'roster_required' THEN
            RAISE EXCEPTION
                'lane identity FAIL-CLOSED (v52): lane_identity_mode=roster_required '
                'but house.roster is missing (table or schema dropped, or a restore '
                'is incomplete). Lane derivation, writes, and mine-recall refuse '
                'until the roster is restored — or an accounted operator migration '
                'flips the mode.'
              USING ERRCODE = 'undefined_table';
        END IF;
        RETURN NULL;   -- role_name posture: lanes are role names by declaration
    END IF;
    SELECT r.name INTO v_name FROM house.roster r
     WHERE r.pg_role = p_role AND r.revoked_at IS NULL LIMIT 1;
    RETURN v_name;
END;
$fn$;
COMMENT ON FUNCTION stewards.box_for_role(text) IS
'v49/v51/v52: roster lookup for the writing seat''s lane. SECURITY DEFINER (house is host-private). v52: posture-aware — a missing roster is lawful ONLY under the recorded role_name mode; under roster_required it fails closed. Enrolled-name and unenrolled-NULL semantics unchanged.';

-- ---------------------------------------------------------------------
-- lane_check, mode-aware. Report-only as always; the fail-closed state is
-- a RED ROW here, never a raise (the oracle must stay readable exactly
-- when the system is refusing writes).
-- ---------------------------------------------------------------------
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

    -- (b) the stamp is forced, not defaulted — a caller cannot forge a lane
    RETURN QUERY SELECT 'stamp_is_forced',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'stamp_origin_box' AND NOT tgisinternal),
        'BEFORE INSERT triggers present on nodes + fact_edges';

    -- (b2, v51) the stamp is also immutable — post-insert rewrites rejected
    RETURN QUERY SELECT 'stamp_is_immutable',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'reject_origin_box_change' AND NOT tgisinternal),
        'BEFORE UPDATE OF origin_box triggers present on nodes + fact_edges';

    -- (b3, v52) the posture row is present, valid, and guarded
    v_mode := stewards.config_get_text('lane_identity_mode',
        CASE WHEN to_regclass('house.roster') IS NOT NULL
             THEN 'roster_required' ELSE 'role_name' END);
    RETURN QUERY SELECT 'lane_identity_mode_valid',
        v_mode IN ('role_name', 'roster_required')
        AND EXISTS (SELECT 1 FROM pg_trigger
                     WHERE tgname = 'lane_identity_mode_guard' AND NOT tgisinternal),
        'mode=' || v_mode || '; guard trigger present';

    -- (c) lane names resolve to real seats — posture-aware (v52).
    IF v_mode = 'roster_required' AND to_regclass('house.roster') IS NULL THEN
        RETURN QUERY SELECT 'roster_required_fail_closed', false,
            'lane_identity_mode=roster_required but house.roster is MISSING — '
            'authority data dropped or restore incomplete; lane derivation, '
            'writes, and mine-recall are failing closed until it is restored '
            '(or an accounted operator migration flips the mode)';
    ELSIF to_regclass('house.roster') IS NULL THEN
        RETURN QUERY SELECT 'lanes_are_seats', true,
            'role_name posture (declared): lanes are role names; no roster to resolve against';
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
'v49/v51/v52 oracle: lanes present, forced, immutable; posture row valid + guarded; resolution posture-aware (role_name = declared role-name lanes; roster_required + missing roster = RED fail-closed row, never a raise). Plus threadchip''s falsifier rule.';

-- ---------------------------------------------------------------------
-- fact_recall_mine, guard-first. v51 wrote it as an inlinable SQL function
-- — and PostgreSQL inlined the lane expression into per-row contexts, so a
-- recall with an empty result set NEVER EVALUATED box_for_role and answered
-- happily in the fail-closed state (caught by smoke OK 120d's red run on
-- this very volume's first build). plpgsql computes the lane before any
-- query runs: fail-closed cannot depend on how many rows came back.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.fact_recall_mine(
    p_seeds    jsonb,
    p_max_hops integer DEFAULT 2,
    p_limit    integer DEFAULT 15,
    p_decay    real    DEFAULT 0.5,
    p_as_of    timestamptz DEFAULT NULL,
    p_boost    real    DEFAULT 1.35
) RETURNS TABLE (kind text, ref text, label text, score real, hops integer,
                 origin_box text, own_lane boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = stewards, house, pg_temp AS $fn$
DECLARE
    v_lane text;
BEGIN
    v_lane := coalesce(stewards.box_for_role(session_user::text),
                       CASE WHEN session_user IN ('stewards', 'postgres') THEN 'fermion'
                            ELSE session_user::text END);
    RETURN QUERY SELECT * FROM stewards.fact_recall_laned(
        p_seeds, v_lane, p_max_hops, p_limit, p_decay, p_as_of, p_boost);
END;
$fn$;
COMMENT ON FUNCTION stewards.fact_recall_mine(jsonb,integer,integer,real,timestamptz,real) IS
'v51/v52: lane-first recall for the CALLER''s own lane, derived from session_user (roster first, host fallback, else role name). v52: plpgsql, lane computed BEFORE the query — the identity guard fires even on an empty recall, so roster_required fail-closed holds regardless of result size. fact_recall_laned stays owner-only.';
