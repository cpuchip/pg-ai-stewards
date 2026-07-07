-- =====================================================================
-- tests/smoke-103.sql — abort conditions (W2, #331) oracle
-- =====================================================================
-- Standalone, self-contained smoke test for 103-abort-conditions.sql.
-- Unlike tests/virgin-smoke.sql this does NOT `CREATE EXTENSION` — it runs
-- against an already-running dev DB with pg_ai_stewards installed (00-106
-- loaded). Structured as a single $vs103$ DO block in vs102's style
-- (plpgsql ASSERT, '103: ...'-prefixed messages, explicit cleanup, a
-- closing RAISE NOTICE) so file-level integration can lift the block
-- verbatim into virgin-smoke.sql later — NOT done here; that file is
-- another builder's integration surface.
--
--   scripts/db.sh -f tests/smoke-103.sql
--
-- Exercises:
--   1. Schema: work_item_abort_conditions exists; abort_conditions_evaluate()
--      exists.
--   2. Arming via the REAL release path: a war_game:true mission + its
--      companion war-game pooling an artifact with 4 aborts (repeat_failure,
--      error_matches, an UNKNOWN kind the artifact invents, budget_fraction)
--      -> asserts all 4 armed and the unknown kind coerced to 'other'
--      (never erroring — the D3C "metric_threshold" case named in the
--      proposal).
--   3. Evaluator, one sweep, four outcomes at once:
--      - repeat_failure (n=2, failure_count forced to 2) TRIPS: disarmed,
--        tripped_at stamped, work item -> awaiting_review, a
--        war_game_abort_tripped steward_actions row logged.
--      - error_matches (pattern that does NOT match last_failure_reason)
--        does NOT trip — inverse, same sweep, same item.
--      - budget_fraction (0.9, cost nowhere near the cap) does NOT trip —
--        inverse.
--      - the coerced 'other' row does NOT trip no matter what — categorical,
--        human-only.
-- =====================================================================
\set ON_ERROR_STOP on

DO $vs103$
DECLARE
    v_mission     uuid;
    v_wg_item     uuid;
    v_res         jsonb;
    v_block       text := '{"moves":[{"id":"m1","action":"deploy the migration","expect_ok":"goose up exits 0","expect_fail":"CHECK constraint violation on startup","failure":"enum drift between migration and live data","signal":"relation \"work_items\" violates check constraint","countermove":"revert the migration; re-derive the enum from source, not memory"}],"forks":[],"aborts":[{"condition":"same failure repeats twice","kind":"repeat_failure","params":{"n":2}},{"condition":"a spend-cap error surfaces","kind":"error_matches","params":{"pattern":"spend cap exceeded"}},{"condition":"quality metric drops below threshold","kind":"metric_threshold","params":{"metric":"pass_rate","threshold":0.8}},{"condition":"more than 90% of budget spent","kind":"budget_fraction","params":{"fraction":0.9}}],"assumptions":[]}';
    v_row_repeat  bigint;
    v_row_error   bigint;
    v_row_other   bigint;
    v_row_budget  bigint;
BEGIN
    -- 1. schema
    ASSERT (SELECT count(*) FROM information_schema.columns
             WHERE table_schema = 'stewards' AND table_name = 'work_item_abort_conditions'
               AND column_name = 'kind') = 1,
        '103: work_item_abort_conditions table must exist';
    ASSERT to_regprocedure('stewards.abort_conditions_evaluate()') IS NOT NULL,
        '103: abort_conditions_evaluate() must exist';

    -- 2. arm via the REAL release path (102's opt-in flag + capture trigger)
    v_res := stewards.chat_start_task_tool(
        '{"pipeline":"research-summary","binding_question":"vs103 abort-armed mission","slug":"vs103-mission","war_game":true}'::jsonb)::jsonb;
    ASSERT (v_res->>'ok')::boolean, format('103: flagged start_task must succeed, got %s', v_res);
    v_mission := (v_res->>'work_item_id')::uuid;
    v_wg_item := (v_res->>'war_game_item_id')::uuid;
    ASSERT v_wg_item IS NOT NULL, '103: flagged start_task must create the companion war-game item';

    INSERT INTO stewards.docs (slug, title, body, work_item_id)
    VALUES ('vs103-mission-wargame-doc', 'vs103 mission war-game',
            E'```json\n' || v_block || E'\n```\n', v_wg_item);

    ASSERT (SELECT war_game IS NOT NULL FROM stewards.work_items WHERE id = v_mission),
        '103: capture must still stamp war_game onto the released mission (102 behavior preserved)';
    ASSERT (SELECT count(*) FROM stewards.work_item_abort_conditions WHERE work_item_id = v_mission) = 4,
        '103: release must arm one row per aborts[] entry (4 expected)';
    ASSERT (SELECT count(*) FROM stewards.work_item_abort_conditions
             WHERE work_item_id = v_mission AND armed) = 4,
        '103: all 4 rows must start armed';
    ASSERT EXISTS (SELECT 1 FROM stewards.steward_actions
                    WHERE work_item_id = v_mission AND action = 'war_game_aborts_armed'),
        '103: arming must be logged (war_game_aborts_armed)';

    SELECT id INTO v_row_repeat FROM stewards.work_item_abort_conditions
     WHERE work_item_id = v_mission AND kind = 'repeat_failure';
    SELECT id INTO v_row_error FROM stewards.work_item_abort_conditions
     WHERE work_item_id = v_mission AND kind = 'error_matches';
    SELECT id INTO v_row_budget FROM stewards.work_item_abort_conditions
     WHERE work_item_id = v_mission AND kind = 'budget_fraction';
    SELECT id INTO v_row_other FROM stewards.work_item_abort_conditions
     WHERE work_item_id = v_mission AND kind = 'other';
    ASSERT v_row_repeat IS NOT NULL AND v_row_error IS NOT NULL
       AND v_row_budget IS NOT NULL AND v_row_other IS NOT NULL,
        '103: all 4 kinds must be present, including the unknown "metric_threshold" coerced to other';
    ASSERT (SELECT condition FROM stewards.work_item_abort_conditions WHERE id = v_row_other)
           = 'quality metric drops below threshold',
        '103: the coerced row must keep the artifact''s human-readable condition text';

    -- 3. evaluator, one sweep, four outcomes
    UPDATE stewards.work_items
       SET status = 'failed',
           failure_count = 2,                                   -- repeat_failure n=2 -> trips
           last_failure_reason = 'transient 502 from upstream',  -- does NOT match error_matches pattern
           cost_cap_micro = 1000000,
           cost_micro_dollars = 1000                             -- fraction 0.001, nowhere near 0.9
     WHERE id = v_mission;

    PERFORM stewards.abort_conditions_evaluate();

    ASSERT (SELECT armed FROM stewards.work_item_abort_conditions WHERE id = v_row_repeat) = false,
        '103: repeat_failure (n=2 <= failure_count=2) must trip and disarm';
    ASSERT (SELECT tripped_at FROM stewards.work_item_abort_conditions WHERE id = v_row_repeat) IS NOT NULL,
        '103: a tripped row must stamp tripped_at';
    ASSERT (SELECT tripped_reason FROM stewards.work_item_abort_conditions WHERE id = v_row_repeat) IS NOT NULL,
        '103: a tripped row must stamp tripped_reason';

    ASSERT (SELECT armed FROM stewards.work_item_abort_conditions WHERE id = v_row_error) = true,
        '103: error_matches must NOT trip when the pattern does not match (inverse, same sweep)';
    ASSERT (SELECT armed FROM stewards.work_item_abort_conditions WHERE id = v_row_budget) = true,
        '103: budget_fraction far below threshold must NOT trip (inverse)';
    ASSERT (SELECT armed FROM stewards.work_item_abort_conditions WHERE id = v_row_other) = true,
        '103: kind=other must never auto-trip regardless of item state (human-only, categorical)';

    ASSERT (SELECT status FROM stewards.work_items WHERE id = v_mission) = 'awaiting_review',
        '103: a trip must move the work item to awaiting_review';
    ASSERT EXISTS (SELECT 1 FROM stewards.steward_actions
                    WHERE work_item_id = v_mission AND action = 'war_game_abort_tripped'),
        '103: a trip must log war_game_abort_tripped';

    -- inverse-inverse: pushing failure_count far past n must not un-trip an
    -- already-disarmed row, and must not touch the 'other' row either.
    UPDATE stewards.work_items SET failure_count = 99 WHERE id = v_mission;
    PERFORM stewards.abort_conditions_evaluate();
    ASSERT (SELECT armed FROM stewards.work_item_abort_conditions WHERE id = v_row_repeat) = false,
        '103: an already-disarmed row must stay disarmed on a later sweep';
    ASSERT (SELECT armed FROM stewards.work_item_abort_conditions WHERE id = v_row_other) = true,
        '103: other must still never trip even after further failures';

    -- clean up
    DELETE FROM stewards.work_item_abort_conditions WHERE work_item_id IN (v_mission, v_wg_item);
    DELETE FROM stewards.docs WHERE slug LIKE 'vs103-%';
    DELETE FROM stewards.steward_actions WHERE work_item_id IN (v_mission, v_wg_item);
    DELETE FROM stewards.work_queue
     WHERE payload::text LIKE '%' || v_wg_item::text || '%'
        OR payload::text LIKE '%' || v_mission::text || '%';
    DELETE FROM stewards.work_items WHERE id IN (v_wg_item, v_mission);
    RAISE NOTICE 'OK 103: abort conditions -- table+arming (4 rows from a real war-game release, unknown kind coerced to other), evaluator (repeat_failure trips + awaiting_review + action row + disarm; error_matches/budget_fraction/other inverses hold across two sweeps)';
END
$vs103$;

\echo '== smoke-103 PASSED =='
