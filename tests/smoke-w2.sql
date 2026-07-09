-- =====================================================================
-- tests/smoke-w2.sql — war-game W2 (forks + assumptions) oracle
-- =====================================================================
-- Standalone, self-contained smoke for v33-wargame-w2.sql. Like smoke-103
-- (and unlike tests/virgin-smoke.sql) it does NOT `CREATE EXTENSION` — it
-- runs against a DB with pg_ai_stewards installed (v00-v31 + v33 loaded). One
-- $vsw2$ DO block in vs102/vs103 style (plpgsql ASSERT, explicit cleanup, a
-- closing RAISE NOTICE) so file-level integration can lift it verbatim into
-- virgin-smoke.sql later.
--
--   scripts/db.sh -f tests/smoke-w2.sql          (or psql -f, ON_ERROR_STOP=1)
--
-- The whole block runs in ONE transaction, so the mission dispatch the
-- capture trigger enqueues stays invisible to the bgworker (MVCC) until the
-- block commits — no race with the assertions; cleanup wipes it at the end.
--
-- Exercises, end to end through the REAL capture-at-release path:
--   1. Schema: route_on_override column + the three W2 helpers exist.
--   2. A synthetic war-game block (aborts + forks + assumptions) pooled under
--      a war_game:true mission's companion item -> capture stamps war_game,
--      arms aborts (v25 regression), AND (v33) materializes forks + assumptions.
--   3. FORKS: one CLEAN fork (explicit from/when/goto naming real stages)
--      translates into work_items.route_on_override; one MESSY fork (the W1
--      {observe,route} prose shape) surfaces as ONE needs_attention ask.
--   4. ROUTING actually fires: work_item_advance at the branch stage consumes
--      the per-item override and routes; a different stage with no override
--      falls through to normal advance (per-stage scoping = prior behavior).
--   5. ABORTS: a mechanical predicate (repeat_failure) TRIPS -> item parks
--      awaiting_review + bell rings; the prose-only ('other') abort does NOT.
--   6. ASSUMPTIONS: both unresolved assumptions batch into ONE bell entry.
--   7. Idempotency: re-materialize does not duplicate a rule or ring twice.
-- =====================================================================
\set ON_ERROR_STOP on

DO $vsw2$
DECLARE
    v_res         jsonb;
    v_mission     uuid;
    v_wg_item     uuid;
    v_over        jsonb;
    v_build_rules jsonb;
    v_ret         text;
    v_status      text;
    v_stage       text;
    v_forks_ask   int;
    v_assum_ask   int;
    v_assum_q     text;
    v_row_repeat  bigint;
    v_row_other   bigint;
    v_block text :=
      '{"moves":[{"id":"m1","action":"run the migration","expect_ok":"goose up exits 0",'
      || '"expect_fail":"CHECK constraint violation on startup","failure":"enum drift between migration and live data",'
      || '"signal":"relation violates check constraint","countermove":"revert; re-derive the enum from source, not memory"}],'
      || '"forks":[{"from":"build","when":"CHECK constraint","goto":"recon",'
      || '"observe":"the migration constraint check fails on live data"},'
      || '{"observe":"if the upstream API returns 500","route":"retry the whole mission from the top"}],'
      || '"aborts":[{"condition":"the same failure repeats twice","kind":"repeat_failure","params":{"n":2}},'
      || '{"condition":"quality metric drops below threshold","kind":"metric_threshold","params":{"metric":"pass_rate","threshold":0.8}}],'
      || '"assumptions":[{"var":"db_url","why_unresolved":"not provided in the brief"},'
      || '{"var":"target_env","why_unresolved":"unclear which cluster to deploy to"}]}';
BEGIN
    -- ---- setup: a default intent (virgin core ships none) + a synthetic
    --      3-stage pipeline whose stage names the CLEAN fork references. ----
    INSERT INTO stewards.intents (slug, purpose) VALUES ('default', 'wargame-w2 smoke')
      ON CONFLICT (slug) DO NOTHING;
    INSERT INTO stewards.pipelines (family, stages) VALUES
      ('wgw2-test', jsonb_build_array(
         jsonb_build_object('name','recon','next','build','model','echo','auto_advance',true),
         jsonb_build_object('name','build','next','verify','model','echo','auto_advance',true),
         jsonb_build_object('name','verify','next', null,  'model','echo','auto_advance',true)))
      ON CONFLICT (family) DO NOTHING;

    -- ===== 1. schema =====
    ASSERT (SELECT count(*) FROM information_schema.columns
             WHERE table_schema='stewards' AND table_name='work_items'
               AND column_name='route_on_override') = 1,
        'W2.1: work_items.route_on_override column must exist';
    ASSERT to_regprocedure('stewards.wargame_apply_forks(uuid)') IS NOT NULL,
        'W2.2: wargame_apply_forks(uuid) must exist';
    ASSERT to_regprocedure('stewards.wargame_surface_assumptions(uuid)') IS NOT NULL,
        'W2.3: wargame_surface_assumptions(uuid) must exist';
    ASSERT to_regprocedure('stewards.wargame_materialize(uuid)') IS NOT NULL,
        'W2.4: wargame_materialize(uuid) must exist';

    -- ===== 2. arm+materialize via the REAL release path =====
    v_res := stewards.chat_start_task_tool(
      '{"pipeline":"wgw2-test","binding_question":"vsw2 mission","slug":"vsw2-mission","war_game":true}'::jsonb)::jsonb;
    ASSERT (v_res->>'ok')::boolean, format('W2.5: flagged start_task must succeed, got %s', v_res);
    v_mission := (v_res->>'work_item_id')::uuid;
    v_wg_item := (v_res->>'war_game_item_id')::uuid;
    ASSERT v_wg_item IS NOT NULL, 'W2.6: flagged start_task must create the companion war-game item';

    INSERT INTO stewards.docs (slug, title, body, work_item_id)
    VALUES ('vsw2-mission-wargame-doc', 'vsw2 mission war-game',
            E'```json\n' || v_block || E'\n```\n', v_wg_item);

    -- capture ran: war_game stamped + aborts armed (v25 behavior preserved
    -- despite the new materialize call sharing the release path)
    ASSERT (SELECT war_game IS NOT NULL FROM stewards.work_items WHERE id = v_mission),
        'W2.7: capture must stamp war_game onto the released mission';
    ASSERT (SELECT count(*) FROM stewards.work_item_abort_conditions WHERE work_item_id = v_mission) = 2,
        'W2.8: release must still arm one abort row per aborts[] entry (2) — materialize did not break arming';

    -- ===== 3. FORKS: clean -> route_on_override, messy -> ONE ask =====
    SELECT route_on_override INTO v_over FROM stewards.work_items WHERE id = v_mission;
    ASSERT v_over IS NOT NULL AND (v_over ? 'build'),
        'W2.9: the CLEAN fork must land in route_on_override keyed by its from-stage (build)';
    v_build_rules := v_over -> 'build';
    ASSERT jsonb_array_length(v_build_rules) = 1,
        format('W2.10: exactly ONE clean rule under build (messy fork excluded), got %s', v_build_rules);
    ASSERT v_build_rules->0->>'goto' = 'recon',
        'W2.11: the translated rule must carry goto=recon (the fork target)';
    ASSERT length(coalesce(v_build_rules->0->>'when','')) > 0,
        'W2.12: the translated rule must carry a non-empty observable when-trigger';

    SELECT count(*) INTO v_forks_ask FROM stewards.hinge_reviews
     WHERE kind='ask' AND status='pending'
       AND payload->>'wargame_kind'='forks' AND payload->>'work_item_id'=v_mission::text;
    ASSERT v_forks_ask = 1,
        format('W2.13: the MESSY fork must surface as exactly ONE needs_attention ask, got %s', v_forks_ask);
    ASSERT EXISTS (SELECT 1 FROM stewards.needs_attention
                    WHERE source_kind='ask' AND work_item_id=v_mission
                      AND question ILIKE '%could not be safely auto-routed%'),
        'W2.14: the messy-fork ask must render in the needs_attention bell';

    -- ===== 4. ASSUMPTIONS: both batch into ONE bell entry =====
    SELECT count(*) INTO v_assum_ask FROM stewards.hinge_reviews
     WHERE kind='ask' AND status='pending'
       AND payload->>'wargame_kind'='assumptions' AND payload->>'work_item_id'=v_mission::text;
    ASSERT v_assum_ask = 1,
        format('W2.15: 2 assumptions must batch into ONE ask, got %s', v_assum_ask);
    SELECT payload->>'question' INTO v_assum_q FROM stewards.hinge_reviews
     WHERE kind='ask' AND payload->>'wargame_kind'='assumptions'
       AND payload->>'work_item_id'=v_mission::text;
    ASSERT v_assum_q ILIKE '%db_url%' AND v_assum_q ILIKE '%target_env%',
        'W2.16: the single assumptions ask must list BOTH unresolved vars';

    -- steward_actions logged (the audit trail materialize leaves)
    ASSERT EXISTS (SELECT 1 FROM stewards.steward_actions
                    WHERE work_item_id=v_mission AND action='war_game_materialized'),
        'W2.17: materialize must log war_game_materialized';
    ASSERT EXISTS (SELECT 1 FROM stewards.steward_actions
                    WHERE work_item_id=v_mission AND action='war_game_forks_applied'),
        'W2.18: forks pass must log war_game_forks_applied';
    ASSERT EXISTS (SELECT 1 FROM stewards.steward_actions
                    WHERE work_item_id=v_mission AND action='war_game_assumptions_surfaced'),
        'W2.19: assumptions pass must log war_game_assumptions_surfaced';

    -- ===== 5. ROUTING actually fires (work_item_advance reads the override) =====
    UPDATE stewards.work_items SET current_stage='build', status='pending' WHERE id=v_mission;
    v_ret := stewards.work_item_advance(v_mission,
              '{"output":"migration failed: relation work_items violates CHECK constraint"}'::jsonb);
    SELECT current_stage INTO v_stage FROM stewards.work_items WHERE id=v_mission;
    ASSERT v_ret = 'recon' AND v_stage = 'recon',
        format('W2.20: the per-item override must route build->recon on a matching output, got ret=%s stage=%s', v_ret, v_stage);

    -- inverse: a stage with NO override entry falls through to normal advance,
    -- EVEN with the same trigger text present -> per-stage scoping = prior behavior
    UPDATE stewards.work_items SET current_stage='verify', status='pending' WHERE id=v_mission;
    v_ret := stewards.work_item_advance(v_mission,
              '{"output":"also mentions CHECK constraint but verify has no override"}'::jsonb);
    SELECT status INTO v_status FROM stewards.work_items WHERE id=v_mission;
    ASSERT v_ret IS NULL AND v_status = 'completed',
        format('W2.21: a stage with no override must advance normally (verify.next=null -> completed), got ret=%s status=%s', v_ret, v_status);

    -- ===== 6. ABORTS: mechanical trips, prose-only surfaces =====
    SELECT id INTO v_row_repeat FROM stewards.work_item_abort_conditions
     WHERE work_item_id=v_mission AND kind='repeat_failure';
    SELECT id INTO v_row_other FROM stewards.work_item_abort_conditions
     WHERE work_item_id=v_mission AND kind='other';   -- metric_threshold coerced
    ASSERT v_row_repeat IS NOT NULL AND v_row_other IS NOT NULL,
        'W2.22: both a mechanical (repeat_failure) and a coerced prose-only (other) abort must be armed';

    UPDATE stewards.work_items
       SET status='failed', failure_count=2, last_failure_reason='transient 502'
     WHERE id=v_mission;
    PERFORM stewards.abort_conditions_evaluate();

    ASSERT (SELECT armed=false AND tripped_at IS NOT NULL
              FROM stewards.work_item_abort_conditions WHERE id=v_row_repeat),
        'W2.23: the mechanical repeat_failure abort (n=2 <= failure_count=2) must TRIP and disarm';
    ASSERT (SELECT status FROM stewards.work_items WHERE id=v_mission)='awaiting_review',
        'W2.24: a trip must park the mission at awaiting_review (the bell)';
    ASSERT EXISTS (SELECT 1 FROM stewards.steward_actions
                    WHERE work_item_id=v_mission AND action='war_game_abort_tripped'),
        'W2.25: a trip must ring war_game_abort_tripped';
    ASSERT (SELECT armed FROM stewards.work_item_abort_conditions WHERE id=v_row_other)=true,
        'W2.26: the prose-only (other) abort must NEVER auto-trip — it surfaces, not fires';

    -- ===== 7. Idempotency: re-materialize duplicates nothing, rings nothing =====
    PERFORM stewards.wargame_materialize(v_mission);
    ASSERT jsonb_array_length((SELECT route_on_override->'build' FROM stewards.work_items WHERE id=v_mission)) = 1,
        'W2.27: re-materialize must NOT duplicate the clean route rule (still exactly 1)';
    ASSERT (SELECT count(*) FROM stewards.hinge_reviews
             WHERE kind='ask' AND status='pending'
               AND payload->>'wargame_kind'='assumptions' AND payload->>'work_item_id'=v_mission::text) = 1,
        'W2.28: re-materialize must NOT ring a second assumptions bell (still exactly 1)';

    -- ---- cleanup ----
    DELETE FROM stewards.work_item_abort_conditions WHERE work_item_id IN (v_mission, v_wg_item);
    DELETE FROM stewards.hinge_reviews WHERE payload->>'work_item_id'=v_mission::text;
    DELETE FROM stewards.docs WHERE slug LIKE 'vsw2-%';
    DELETE FROM stewards.steward_actions WHERE work_item_id IN (v_mission, v_wg_item);
    DELETE FROM stewards.work_queue
     WHERE payload::text LIKE '%'||v_wg_item::text||'%' OR payload::text LIKE '%'||v_mission::text||'%';
    DELETE FROM stewards.work_items WHERE id IN (v_wg_item, v_mission);
    DELETE FROM stewards.work_items WHERE pipeline_family='wgw2-test';
    DELETE FROM stewards.pipelines WHERE family='wgw2-test';

    RAISE NOTICE 'OK W2: war-game forks+assumptions operational — clean fork -> route_on_override (routes build->recon; per-stage scoped), messy fork -> ONE ask, 2 assumptions -> ONE ask, aborts armed+mechanical-trip+prose-no-trip regression, idempotent re-materialize (28 assertions)';
END
$vsw2$;

\echo '== smoke-w2 PASSED =='
