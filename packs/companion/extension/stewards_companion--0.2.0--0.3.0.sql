\echo Use "ALTER EXTENSION stewards_companion UPDATE" to load this file. \quit
-- >>> from packs/companion/steward-unstick-reset.sql
-- =====================================================================
-- packs/companion/steward-unstick-reset.sql — work_item_unstick resets the
-- loop counters (companion 0.3.0; defect 3).
-- =====================================================================
-- The 0.2.0 work_item_unstick (steward-tools.sql) re-dispatches a parked
-- item's current stage but never clears the route_on loop machinery, so a
-- cap-parked item (e.g. revise_count already at the cap of 2, or a crawl at
-- its _crawl_steps cap) re-runs its stage ONCE and instantly re-parks — it
-- cannot make progress. This supersedes that definition (CREATE OR REPLACE):
-- on unstick, reset every route_on count_key THIS item's pipeline uses
-- (revise_count, plan_revise_count, _crawl_steps, _pr_url_retry, …), zero the
-- failure_count column, and drop the _route_hops loop-guard from
-- stage_results — THEN re-dispatch. Everything else (the
-- failed/awaiting_review-only guard, the model-override validation, the
-- verbal-gate note) is unchanged from 0.2.0.
--
-- Packaged as a NEW source (not an edit of steward-tools.sql) so the shipped
-- 0.2.0 scripts stay frozen and byte-verifiable: the 0.3.0 full install
-- applies the 0.2.0 definition then this override, and the 0.2.0->0.3.0
-- upgrade delta applies this override alone — both CREATE OR REPLACE, so the
-- final state is the fixed function either way.
-- =====================================================================

-- ── work_item_unstick: the recovery verb (0.3.0 — resets the loop counters) ──
CREATE OR REPLACE FUNCTION companion.work_item_unstick(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi         uuid;
    v_status     text;
    v_model      text := nullif(btrim(coalesce(p_args->>'model','')),'');
    v_prov       text;
    v_name       text;
    v_ok         boolean;
    v_wq         bigint;
    v_count_keys text[];
BEGIN
    BEGIN v_wi := (p_args->>'work_item_id')::uuid;
    EXCEPTION WHEN others THEN RETURN jsonb_build_object('error','work_item_id (uuid) required'); END;
    SELECT status INTO v_status FROM stewards.work_items WHERE id = v_wi;
    IF v_status IS NULL THEN RETURN jsonb_build_object('error','no such work item'); END IF;
    IF v_status NOT IN ('failed','awaiting_review') THEN
        RETURN jsonb_build_object('error','item is '||v_status||' — unstick only touches failed or awaiting_review items');
    END IF;

    IF v_model IS NOT NULL THEN
        IF position('/' IN v_model) > 0 THEN
            v_prov := split_part(v_model,'/',1); v_name := split_part(v_model,'/',2);
            SELECT usable INTO v_ok FROM stewards.model_catalog WHERE provider=v_prov AND model=v_name;
            IF v_ok IS DISTINCT FROM true THEN
                RETURN jsonb_build_object('error','model '||v_model||' is not a usable catalog model — model_health lists what is');
            END IF;
            UPDATE stewards.work_items SET provider_override=v_prov, model_override=v_name WHERE id=v_wi;
        ELSE
            IF NOT EXISTS (SELECT 1 FROM stewards.model_aliases WHERE alias=v_model AND enabled) THEN
                RETURN jsonb_build_object('error','no enabled alias named '||v_model||' — model_health lists aliases');
            END IF;
            UPDATE stewards.work_items SET model_override=v_model, provider_override=NULL WHERE id=v_wi;
        END IF;
    END IF;

    -- Reset the loop machinery so a cap-parked item can make progress instead
    -- of re-running once and instantly re-parking (defect 3): clear every
    -- route_on count_key THIS item's pipeline uses, zero the failure_count
    -- column, and drop the _route_hops loop-guard from stage_results.
    SELECT coalesce(array_agg(DISTINCT r->>'count_key'), ARRAY[]::text[])
      INTO v_count_keys
      FROM stewards.work_items w
      JOIN stewards.pipelines p ON p.family = w.pipeline_family
      CROSS JOIN LATERAL jsonb_array_elements(p.stages) s
      CROSS JOIN LATERAL jsonb_array_elements(coalesce(s->'route_on','[]'::jsonb)) r
     WHERE w.id = v_wi AND r ? 'count_key';

    UPDATE stewards.work_items
       SET input         = coalesce(input, '{}'::jsonb) - v_count_keys,
           failure_count = 0,
           stage_results = coalesce(stage_results, '{}'::jsonb) - '_route_hops'
     WHERE id = v_wi;

    v_wq := stewards.work_item_dispatch_stage_safe(v_wi, NULL, true);
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_wi, 'was', v_status,
        'model_override', v_model, 'redispatched', v_wq IS NOT NULL,
        'reset', jsonb_build_object('count_keys', to_jsonb(v_count_keys), 'failure_count', 0, '_route_hops', 'cleared'),
        'note', 'VERBAL-GATE PROTOCOL: only call this after reading the item''s error (and the intended model, if overriding) aloud and hearing an explicit yes.');
END;
$fn$;
COMMENT ON FUNCTION companion.work_item_unstick(jsonb) IS
'companion pack (0.3.0): re-dispatch ONE failed/parked work item''s current stage after RESETTING its loop machinery (route_on count_keys + failure_count + _route_hops) so a cap-parked item can progress instead of instantly re-parking. Optional model pin ("alias" or "provider/model", validated). Never touches running/pending/done items. Verbal gate is procedural: error read aloud + explicit yes first.';
-- ===== PACKAGING (extension-only) =====
-- These statements exist ONLY in the extension build, never in the loose-SQL
-- pack sources (packs/companion/*.sql). verify-verbatim.sh strips everything
-- between this marker and the END marker before its byte-for-byte compare.
-- Rationale: .spec/proposals/d2a-pack-extension-battle-plan.md (mechanic #3)
-- and stewards_companion.control's DROP-survivors posture block.

-- companion.companion_uninstall() — THE documented uninstall step. Call it
-- BEFORE `DROP EXTENSION stewards_companion`. It (1) SHRINKS the Arc-C
-- dynamic-write allowlist back, removing only THIS pack's write-tool names
-- (any operator/other-pack additions stay), and (2) DEACTIVATES this pack's
-- own tool_defs rows (active=false, never deleted — a re-install's upsert
-- reactivates them). It deliberately does NOT touch forged tools, the forge
-- pipeline row, or the companion intent row. See the control-file posture.
CREATE OR REPLACE FUNCTION companion.companion_uninstall() RETURNS jsonb
LANGUAGE plpgsql AS $uninstall$
DECLARE
    v_write_names text[] := ARRAY['reminder_set','reminder_cancel','companion_approve','forge_start','work_item_unstick','models_health_check'];
    v_tool_names  text[] := ARRAY['forge_register','reminder_set','reminder_list','reminder_cancel','companion_bell','companion_approve','forge_start','work_item_unstick','model_health','models_health_check'];
    v_allow jsonb;
    v_kept  jsonb;
    v_deact int := 0;
BEGIN
    -- 1. shrink the allowlist, preserving the order of the names we keep.
    v_allow := stewards.config_get('arc_c_dynamic_write_allowlist');
    IF v_allow IS NOT NULL AND jsonb_typeof(v_allow) = 'array' THEN
        SELECT coalesce(jsonb_agg(e ORDER BY ord), '[]'::jsonb) INTO v_kept
          FROM jsonb_array_elements_text(v_allow) WITH ORDINALITY AS t(e, ord)
         WHERE e <> ALL (v_write_names);
        PERFORM stewards.config_set('arc_c_dynamic_write_allowlist', v_kept,
            'companion pack uninstall: this pack''s write-tool names removed from the Arc-C allowlist.');
    END IF;

    -- 2. deactivate (never delete) this pack's own tool_defs rows. Forged
    --    tools live in the forge schema too but are NOT in this list, so
    --    they are untouched — that is the survivors posture.
    UPDATE stewards.tool_defs SET active = false WHERE name = ANY (v_tool_names);
    GET DIAGNOSTICS v_deact = ROW_COUNT;

    RETURN jsonb_build_object('ok', true,
        'allowlist_after', coalesce(v_kept, v_allow, '[]'::jsonb),
        'tool_defs_deactivated', v_deact,
        'kept', jsonb_build_object(
            'forge_pipeline',   'kept (ledger history references it)',
            'companion_intent', 'kept (work_items reference it)',
            'forged_tools',     'kept (operator data — DROP EXTENSION refuses while they exist; CASCADE to destroy)'),
        'note', 'companion uninstall step complete. Now: DROP EXTENSION stewards_companion; '
             || 'it REFUSES while forged tools exist (that is the guard) — DROP EXTENSION ... CASCADE '
             || 'is the explicit choice to destroy forged functions too.');
END;
$uninstall$;
COMMENT ON FUNCTION companion.companion_uninstall() IS
'companion pack (extension build only): THE documented uninstall step — call BEFORE DROP EXTENSION. Shrinks the Arc-C dynamic-write allowlist back (removes only this pack''s write-tool names) and deactivates this pack''s own tool_defs rows (active=false, never deleted; re-install reactivates). Leaves forged tools, the forge pipeline row, and the companion intent row untouched.';
-- ===== END PACKAGING =====
