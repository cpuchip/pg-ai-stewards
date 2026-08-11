-- =====================================================================
-- v53 — posture guard hardening: the key is pinned, the default is gone
-- =====================================================================
-- Codex's round-3 review of v52 (11803e4b) found the guard's WHEN clause
-- watched the VALUE while leaving the KEY a door. Reds observed live on the
-- v52 build before this volume was written (evidence file, round 3):
--
--   UPDATE stewards.config SET key='lane_identity_mode_old'
--    WHERE key='lane_identity_mode';            -- UPDATE 1 (escaped)
--   INSERT ... ('evil', '"anarchy"'); UPDATE ... SET key='lane_identity_mode'
--    WHERE key='evil';                          -- UPDATE 1 (poisoned in)
--   SELECT stewards.box_for_role('box_anything');  -- NULL, no complaint
--
-- Because v52's readers DEFAULTED a missing/foreign mode from roster
-- presence, renaming the row resurrected the exact structural fallback v52
-- existed to remove — with lane_check still reporting the mode valid, since
-- it used the same default. Three closures, per the ruling:
--
--   1. THE KEY IS PINNED. The guard fires when either side of an UPDATE
--      touches the key ('rename out' and 'rename in' both), and rejects any
--      key change. INSERT gains a value-validation leg (a deleted row may be
--      legitimately restored, but only with a lawful value).
--   2. THE DEFAULT IS GONE. Post-v52 the row always exists (the migration
--      is transactional, so "mid-upgrade" is not an observable runtime
--      state). A missing or invalid row now FAILS CLOSED in box_for_role —
--      in BOTH postures — and lane_check reports it red. Nothing
--      reconstructs posture from roster presence, ever again.
--   3. THE MIGRATION VALIDATES ITS INHERITANCE. A preexisting row (e.g.
--      seeded by the enrollment path before this volume applied) is
--      validated or the migration aborts.
--
-- Sibling fix in the same pass (same shape as codex's trigger-assert note):
-- every trigger assertion in lane_check now binds to ITS TABLE and to
-- enabled state — a same-named trigger elsewhere, or a disabled one, no
-- longer satisfies the oracle.
-- =====================================================================

-- 3. Validate the inheritance before touching anything else.
DO $v53_preseed$
DECLARE v_val text;
BEGIN
    SELECT value #>> '{}' INTO v_val FROM stewards.config
     WHERE key = 'lane_identity_mode';
    IF v_val IS NULL THEN
        RAISE EXCEPTION
            'v53 migration abort: lane_identity_mode row is missing. v52 seeds '
            'it in the same transaction on a fresh chain, so a missing row here '
            'means a damaged or tampered upgrade path. Restore the row '
            '(role_name or roster_required) and re-apply.';
    END IF;
    IF v_val NOT IN ('role_name', 'roster_required') THEN
        RAISE EXCEPTION
            'v53 migration abort: lane_identity_mode carries invalid value %. '
            'Fix the row to role_name or roster_required and re-apply.', v_val;
    END IF;
END
$v53_preseed$;

-- 1. The guard, re-authored: key pinned, all three verbs.
CREATE OR REPLACE FUNCTION stewards.lane_identity_mode_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE
    v_old text; v_new text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION
            'lane_identity_mode cannot be deleted (v52). Removing the posture row '
            'would resurrect the silent-downgrade seam it exists to close. An '
            'operator migration disables the lane_identity_mode_guard* triggers '
            'on stewards.config, acts, re-enables — and accounts for it.'
          USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    v_new := NEW.value #>> '{}';
    IF TG_OP = 'INSERT' THEN
        -- restoring a deleted row is lawful; poisoning the key is not
        IF v_new NOT IN ('role_name', 'roster_required') THEN
            RAISE EXCEPTION
                'lane_identity_mode must be role_name or roster_required, got %', v_new
              USING ERRCODE = 'invalid_parameter_value';
        END IF;
        RETURN NEW;
    END IF;

    -- UPDATE: the key is pinned (v53) — no rename out, no rename in.
    IF OLD.key IS DISTINCT FROM NEW.key THEN
        RAISE EXCEPTION
            'the lane_identity_mode key is pinned (v53): renaming the posture row '
            '(or renaming another row into its key) re-opens the silent-downgrade '
            'seam. Rejected: % -> %.', OLD.key, NEW.key
          USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    v_old := OLD.value #>> '{}';
    IF v_new NOT IN ('role_name', 'roster_required') THEN
        RAISE EXCEPTION
            'lane_identity_mode must be role_name or roster_required, got %', v_new
          USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF v_old = 'roster_required' AND v_new = 'role_name' THEN
        RAISE EXCEPTION
            'lane_identity_mode: roster_required -> role_name is an authority '
            'DOWNGRADE and never an ordinary UPDATE (v52). It is an explicit '
            'operator migration: disable the lane_identity_mode_guard* triggers '
            'on stewards.config; update; re-enable — and account for it.'
          USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$fn$;
COMMENT ON FUNCTION stewards.lane_identity_mode_guard() IS
'v52/v53: the posture row''s wall, all three verbs. Key pinned (no rename out or in), no delete, no unknown value, forward-only transition; INSERT restores only with a lawful value. Reverse = disable-and-account operator migration.';

-- v52's single trigger becomes three: WHEN clauses referencing NEW are
-- illegal on DELETE triggers, and the UPDATE leg must watch BOTH sides of
-- the key. Names share the lane_identity_mode_guard prefix; lane_check
-- asserts all three, bound to this table and to enabled state.
DROP TRIGGER IF EXISTS lane_identity_mode_guard ON stewards.config;
CREATE TRIGGER lane_identity_mode_guard
    BEFORE UPDATE ON stewards.config
    FOR EACH ROW
    WHEN (OLD.key = 'lane_identity_mode' OR NEW.key = 'lane_identity_mode')
    EXECUTE FUNCTION stewards.lane_identity_mode_guard();
DROP TRIGGER IF EXISTS lane_identity_mode_guard_del ON stewards.config;
CREATE TRIGGER lane_identity_mode_guard_del
    BEFORE DELETE ON stewards.config
    FOR EACH ROW WHEN (OLD.key = 'lane_identity_mode')
    EXECUTE FUNCTION stewards.lane_identity_mode_guard();
DROP TRIGGER IF EXISTS lane_identity_mode_guard_ins ON stewards.config;
CREATE TRIGGER lane_identity_mode_guard_ins
    BEFORE INSERT ON stewards.config
    FOR EACH ROW WHEN (NEW.key = 'lane_identity_mode')
    EXECUTE FUNCTION stewards.lane_identity_mode_guard();

-- 2. box_for_role: the default is gone. Missing or invalid row fails
--    closed in both postures.
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
        RETURN NULL;   -- role_name posture, declared by an existing valid row
    END IF;
    SELECT r.name INTO v_name FROM house.roster r
     WHERE r.pg_role = p_role AND r.revoked_at IS NULL LIMIT 1;
    RETURN v_name;
END;
$fn$;
COMMENT ON FUNCTION stewards.box_for_role(text) IS
'v49/v51/v52/v53: roster lookup for the writing seat''s lane. SECURITY DEFINER (house is host-private). v53: NO defaults — a missing or invalid posture row fails closed in both postures; a missing roster is lawful only under a VALID declared role_name row. Enrolled-name and unenrolled-NULL semantics unchanged.';

-- lane_check: no-default posture read; every trigger assertion bound to its
-- table and enabled state.
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

    -- (b) the stamp is forced, not defaulted — bound to table + enabled (v53)
    RETURN QUERY SELECT 'stamp_is_forced',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'stamp_origin_box' AND NOT tgisinternal
            AND tgenabled <> 'D'
            AND tgrelid IN ('stewards.nodes'::regclass, 'stewards.fact_edges'::regclass)),
        'BEFORE INSERT triggers present AND enabled on nodes + fact_edges';

    -- (b2, v51) the stamp is also immutable — bound to table + enabled (v53)
    RETURN QUERY SELECT 'stamp_is_immutable',
        (SELECT count(*) = 2 FROM pg_trigger
          WHERE tgname = 'reject_origin_box_change' AND NOT tgisinternal
            AND tgenabled <> 'D'
            AND tgrelid IN ('stewards.nodes'::regclass, 'stewards.fact_edges'::regclass)),
        'BEFORE UPDATE OF origin_box triggers present AND enabled on nodes + fact_edges';

    -- (b3, v52/v53) the posture row is present, valid, and guarded on all
    -- three verbs — read with NO default, guard bound to config + enabled.
    v_mode := stewards.config_get_text('lane_identity_mode', NULL);
    RETURN QUERY SELECT 'lane_identity_mode_valid',
        v_mode IN ('role_name', 'roster_required')
        AND (SELECT count(*) = 3 FROM pg_trigger
              WHERE tgname LIKE 'lane_identity_mode_guard%' AND NOT tgisinternal
                AND tgenabled <> 'D'
                AND tgrelid = 'stewards.config'::regclass),
        'mode=' || coalesce(v_mode, 'MISSING')
            || '; guard triggers (update/delete/insert) present AND enabled on stewards.config';

    -- (c) lane resolution, posture-aware. A missing/invalid posture row is
    -- the fail-closed state in EVERY posture (v53: no derived default).
    IF v_mode IS NULL OR v_mode NOT IN ('role_name', 'roster_required') THEN
        RETURN QUERY SELECT 'posture_fail_closed', false,
            'lane_identity_mode is ' || coalesce('invalid (' || v_mode || ')', 'MISSING')
            || ' — lane derivation, writes, and mine-recall are failing closed; '
            || 'restore the row with a lawful INSERT and account for how it was lost';
    ELSIF v_mode = 'roster_required' AND to_regclass('house.roster') IS NULL THEN
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
'v49/v51/v52/v53 oracle: lanes present, forced, immutable; posture row present + valid + guarded on all three verbs (no defaults — missing/invalid = fail-closed red); every trigger assertion bound to its table and enabled state. Plus threadchip''s falsifier rule.';
