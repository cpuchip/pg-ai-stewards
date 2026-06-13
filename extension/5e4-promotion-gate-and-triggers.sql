-- =====================================================================
-- Phase 5e.4 (Phase D.5) — Sabbath gate on promotion + triggering hooks
--
-- Pieces:
--   (the sabbath gate on promotion moved into work_item_promote_to_doc
--    in 04-work-items.sql at the 2026-06-12 consolidation)
--   2. apply_gate_decision: when action='advance' lands maturity at
--      'verified' on a sabbath_enabled pipeline, enqueue sabbath
--   3. apply_verify_result: when all_passed=true on a sabbath_enabled
--      pipeline, enqueue sabbath
--   4. New helper stewards.maybe_enqueue_atonement(work_item_id) for
--      callers that quarantine — opt-in fire of atonement_dispatch
--      when atonement_enabled
-- =====================================================================

-- ---------------------------------------------------------------------
-- (2) Wrap apply_gate_decision: after action='advance' lands at
--     verified on a sabbath-enabled pipeline, fire sabbath_dispatch
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_gate_decision(
    p_work_item_id uuid,
    p_decision     jsonb,
    p_work_id      bigint DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_pipeline       stewards.pipelines%ROWTYPE;
    v_action         text;
    v_reasoning      text;
    v_feedback       text;
    v_new_maturity   text;
    v_produces_mat   text;
    v_maturity_order text[] := ARRAY['raw','researched','planned','specced','executing','verified'];
    v_idx            int;
    v_new_revision   int;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    v_action    := p_decision->>'action';
    v_reasoning := p_decision->>'reasoning';
    v_feedback  := p_decision->>'feedback';

    IF v_action NOT IN ('advance', 'revise', 'surface') THEN
        RAISE EXCEPTION 'apply_gate_decision: invalid action %', v_action;
    END IF;

    INSERT INTO stewards.gate_decisions
        (work_item_id, from_maturity, action, reasoning, feedback,
         work_id, revision_count, raw_response)
    VALUES
        (p_work_item_id, v_wi.maturity, v_action, v_reasoning, v_feedback,
         p_work_id, v_wi.revision_count, p_decision);

    v_new_maturity := v_wi.maturity;

    IF v_action = 'advance' THEN
        SELECT produces_maturity INTO v_produces_mat
          FROM stewards.pipeline_stage_maturity
         WHERE pipeline_family = v_wi.pipeline_family
           AND stage_name = v_wi.current_stage;

        IF v_produces_mat IS NOT NULL THEN
            v_new_maturity := v_produces_mat;
        ELSE
            v_idx := array_position(v_maturity_order, v_wi.maturity);
            IF v_idx IS NOT NULL AND v_idx < array_length(v_maturity_order, 1) THEN
                v_new_maturity := v_maturity_order[v_idx + 1];
            END IF;
        END IF;

        UPDATE stewards.work_items
           SET maturity       = v_new_maturity,
               revision_count = 0,
               updated_at     = now()
         WHERE id = p_work_item_id;

        -- Phase 5e (D.5): fire sabbath when reaching verified on a
        -- sabbath-enabled pipeline (and we haven't already).
        IF v_new_maturity = 'verified' THEN
            SELECT * INTO v_pipeline FROM stewards.pipelines
             WHERE family = v_wi.pipeline_family;
            IF v_pipeline.sabbath_enabled
               AND v_wi.sabbath_completed_at IS NULL THEN
                BEGIN
                    PERFORM stewards.sabbath_dispatch(p_work_item_id);
                EXCEPTION WHEN OTHERS THEN
                    RAISE NOTICE 'sabbath_dispatch from apply_gate_decision raised: %', SQLERRM;
                END;
            END IF;
        END IF;

    ELSIF v_action = 'revise' THEN
        v_new_revision := v_wi.revision_count + 1;

        IF v_new_revision > 2 THEN
            UPDATE stewards.work_items
               SET status = 'awaiting_review',
                   revision_count = v_new_revision,
                   updated_at = now()
             WHERE id = p_work_item_id;
        ELSE
            UPDATE stewards.work_items
               SET status                 = 'failed',
                   revision_count         = v_new_revision,
                   last_failure_reason    = 'gate revise: ' || coalesce(v_feedback, '(no feedback)'),
                   last_failure_diagnosis = 'gate_revise',
                   updated_at             = now()
             WHERE id = p_work_item_id;
        END IF;

    ELSIF v_action = 'surface' THEN
        UPDATE stewards.work_items
           SET status     = 'awaiting_review',
               updated_at = now()
         WHERE id = p_work_item_id;
    END IF;

    RETURN v_new_maturity;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_gate_decision(uuid, jsonb, bigint) IS
'Phase 5a + 5e (D.5): on advance to verified maturity for a sabbath-enabled pipeline, automatically fires sabbath_dispatch. Sabbath errors swallowed (logged via NOTICE) so gate decision still applies cleanly.';

-- ---------------------------------------------------------------------
-- (3) Wrap apply_verify_result: when all_passed=true on a
--     sabbath-enabled pipeline, fire sabbath
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_verify_result(
    p_work_item_id uuid,
    p_result       jsonb,
    p_work_id      bigint DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_pipeline    stewards.pipelines%ROWTYPE;
    v_all_passed  boolean;
    v_results     jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'apply_verify_result: work_item % not found', p_work_item_id;
    END IF;

    v_all_passed := coalesce((p_result->>'all_passed')::boolean, false);
    v_results    := coalesce(p_result->'results', '[]'::jsonb);

    INSERT INTO stewards.verify_results
        (work_item_id, all_passed, results, work_id, raw_response)
    VALUES
        (p_work_item_id, v_all_passed, v_results, p_work_id, p_result);

    IF v_all_passed THEN
        -- Phase 5e (D.5): fire sabbath if eligible
        SELECT * INTO v_pipeline FROM stewards.pipelines
         WHERE family = v_wi.pipeline_family;
        IF v_pipeline.sabbath_enabled
           AND v_wi.sabbath_completed_at IS NULL THEN
            BEGIN
                PERFORM stewards.sabbath_dispatch(p_work_item_id);
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'sabbath_dispatch from apply_verify_result raised: %', SQLERRM;
            END;
        END IF;
    ELSE
        UPDATE stewards.work_items
           SET maturity               = 'planned',
               status                 = 'failed',
               last_failure_reason    = 'verify failed: see verify_results',
               last_failure_diagnosis = 'verify_failed',
               updated_at             = now()
         WHERE id = p_work_item_id;
    END IF;

    RETURN v_all_passed;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_verify_result(uuid, jsonb, bigint) IS
'Phase 5b + 5e (D.5): on verify all_passed=true for a sabbath-enabled pipeline, fires sabbath_dispatch.';

-- ---------------------------------------------------------------------
-- (4) maybe_enqueue_atonement helper for steward-side quarantine path
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.maybe_enqueue_atonement(
    p_work_item_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi       stewards.work_items%ROWTYPE;
    v_pipeline stewards.pipelines%ROWTYPE;
    v_work_id  bigint;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;
    IF NOT v_pipeline.atonement_enabled THEN
        RETURN NULL;
    END IF;
    BEGIN
        v_work_id := stewards.atonement_dispatch(p_work_item_id);
        RETURN v_work_id;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'maybe_enqueue_atonement: atonement_dispatch raised: %', SQLERRM;
        RETURN NULL;
    END;
END;
$func$;

COMMENT ON FUNCTION stewards.maybe_enqueue_atonement(uuid) IS
'Phase 5e (D.5): no-op if pipeline.atonement_enabled is false. Steward calls this from the quarantine path; safe to call always.';
