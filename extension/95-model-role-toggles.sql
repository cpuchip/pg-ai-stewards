-- =====================================================================
-- 95-model-role-toggles.sql — per-alias-member enable/disable + the
-- local-provider "rest all" bulk switch.
-- =====================================================================
-- Michael, fresh off the setup wizard (88/#256): "could use a few more ux
-- ease of life features. like turning off models for the different model
-- kinds (reason, ingest...) I cant disable the local models we've enabled
-- through lm studio or flexllama." 31/32 gave model_aliases a STATIC
-- availability filter — configured + usable (probe verdict) + under-cap +
-- no-train — but nothing an OPERATOR can flip by hand. model_capability.usable
-- is close but the wrong grain for this: it is the auto-probe's capability
-- verdict for a (provider, model) PAIR, shared across every alias that pair
-- happens to belong to, and overwritten by the M.4 probe on its own cadence —
-- reusing it for "Michael turned this off" would let a probe silently
-- re-enable a model he just disabled, and disabling it here would also mark
-- it unusable for any OTHER alias/role that member happens to serve.
--
-- This file adds a per-(alias, provider, provider_model) `enabled` flag — the
-- grain that actually matches "disable qwen3.6-27b for the reason role" (a
-- ROLE, not a global capability) — and teaches the ONE resolver both the
-- dispatcher (31) and the runtime failover walk (32) already share
-- (pick_alias_member) to skip disabled members. Because both consumers
-- already call through that single function, re-authoring it here is the
-- whole fix: work_item_dispatch_stage and steward_tick need no changes.
--
--   • model_aliases.enabled  — boolean, default true (idempotent ADD COLUMN).
--                              A virgin/pre-95 install behaves identically —
--                              every existing row starts enabled.
--   • provider_is_local(provider) — true for lm_studio/flexllama (mirrors
--                              cmd/stewards-ui/api/activity.go's localProviders
--                              map, the one existing "local" convention in
--                              this codebase). Read-only convenience.
--   • pick_alias_member(alias, forbid_training, exclude) — 32's FINAL 3-arg
--                              form, re-authored here (later-file-wins) with
--                              one added predicate: AND a.enabled.
--   • model_aliases_set_local_enabled(enabled) — the "rest all local models" /
--                              wake-all-back-up bulk action: flips enabled for
--                              every row whose provider is local. One
--                              function, one boolean, both directions — the
--                              cockpit's POST /api/models/aliases/rest-local
--                              wraps this so disabling is a click, not SQL.
--
-- requires create_core_compat (91) — purely for chain ordering; the only real
-- dependency is pick_alias_member (32). Generic core: the new column defaults
-- every member enabled, so nothing dispatches differently until an operator
-- (or the cockpit) flips a row off.
-- =====================================================================


-- =====================================================================
-- §1 — the toggle column.
-- =====================================================================
ALTER TABLE stewards.model_aliases
    ADD COLUMN IF NOT EXISTS enabled boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN stewards.model_aliases.enabled IS
'95: operator on/off switch for this alias member, distinct from model_capability.usable (the auto-probe''s capability verdict, shared across every alias a (provider,model) pair belongs to). Disabling a member here removes it from pick_alias_member''s resolution for THIS alias only — a different role that also lists the same (provider, model) is unaffected. Default true: a virgin install / pre-95 row dispatches exactly as before.';


-- =====================================================================
-- §2 — provider_is_local: the one existing "local" convention, named.
-- =====================================================================
-- cmd/stewards-ui/api/activity.go already hardcodes localProviders =
-- {flexllama, lm_studio} to badge live dispatches and drive the GPU column.
-- This mirrors it in SQL so the bulk rest-local toggle (and any future SQL
-- consumer) shares the one true list instead of growing a second copy in a
-- WHERE clause. Keep both in sync if a third local provider ever ships.
CREATE OR REPLACE FUNCTION stewards.provider_is_local(p_provider text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_provider IN ('flexllama', 'lm_studio');
$$;

COMMENT ON FUNCTION stewards.provider_is_local(text) IS
'95: true for the local-rig providers (flexllama, lm_studio) — mirrors cmd/stewards-ui/api/activity.go''s localProviders map. Backs model_aliases_set_local_enabled and the cockpit''s local-provider badge/grouping.';


-- =====================================================================
-- §3 — pick_alias_member FINAL: 32's 3-arg form + the enabled filter.
-- =====================================================================
-- Carries 32's body verbatim (configured + usable + under-cap + no-train +
-- not-excluded) and adds ONE predicate: AND a.enabled. Both consumers
-- (work_item_dispatch_stage's alias path in 31, steward_tick's alias-failover
-- branch in 32) call this SAME function, so re-authoring it here is the whole
-- fix — neither of those two (much larger) functions needs to change.
CREATE OR REPLACE FUNCTION stewards.pick_alias_member(
    p_alias           text,
    p_forbid_training boolean DEFAULT false,
    p_exclude         jsonb   DEFAULT '[]'::jsonb
)
RETURNS TABLE (provider text, model text)
LANGUAGE sql AS $$
    SELECT a.provider, a.provider_model
      FROM stewards.model_aliases a
     WHERE a.alias = p_alias
       AND a.enabled
       AND (
            NOT EXISTS (SELECT 1 FROM stewards.providers_loaded())   -- no registry info → don't filter
            OR stewards.provider_is_loaded(a.provider)
       )
       AND stewards.model_usable(a.provider, a.provider_model)
       AND NOT stewards.provider_cap_exceeded(a.provider)
       AND (NOT p_forbid_training
            OR NOT stewards.model_trains_on_data(a.provider, a.provider_model))
       AND NOT (p_exclude @> jsonb_build_array(
                jsonb_build_object('provider', a.provider, 'model', a.provider_model)))
     ORDER BY a.priority ASC, a.provider, a.provider_model
     LIMIT 1;
$$;

COMMENT ON FUNCTION stewards.pick_alias_member(text, boolean, jsonb) IS
'31/32/95: resolve a model alias to its best concrete (provider, model) — lowest priority that is ENABLED + configured (when the registry is populated) + usable + under spend cap + (when p_forbid_training) no-train + NOT in p_exclude (a jsonb array of {provider, model} already tried this attempt). No rows if none qualify. Both work_item_dispatch_stage (31) and steward_tick''s alias failover (32) resolve through this one function, so a disabled member is skipped at dispatch time AND at runtime failover.';


-- =====================================================================
-- §4 — the "rest all local models" bulk switch + its inverse.
-- =====================================================================
-- One function, one boolean: false rests every local alias member across
-- EVERY role at once — the pain point named verbatim ("I cant disable the
-- local models we've enabled through lm studio or flexllama") — true wakes
-- them all back up. The cockpit's POST /api/models/aliases/rest-local wraps
-- this in one click; no SQL required, and it's fully reversible (only ever
-- flips the enabled flag, never deletes a row), so it needs no confirmation.
CREATE OR REPLACE FUNCTION stewards.model_aliases_set_local_enabled(p_enabled boolean)
RETURNS int LANGUAGE sql AS $$
    WITH updated AS (
        UPDATE stewards.model_aliases
           SET enabled = p_enabled
         WHERE stewards.provider_is_local(provider)
           AND enabled IS DISTINCT FROM p_enabled
        RETURNING 1
    )
    SELECT count(*)::int FROM updated;
$$;

COMMENT ON FUNCTION stewards.model_aliases_set_local_enabled(boolean) IS
'95: bulk-flip enabled for every model_aliases row whose provider is local (provider_is_local) — false = "rest all local models" (every role at once), true = wake them back up. Returns the number of rows actually changed. Reversible, no confirmation needed: it only ever touches the enabled flag, never deletes a row.';

-- =====================================================================
-- End of 95-model-role-toggles.sql
-- =====================================================================
