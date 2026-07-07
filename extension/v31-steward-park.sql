-- =====================================================================
-- v31-steward-park.sql — park tick-errored items out of the retry lane
-- (task #338: steward retry-lane starvation)
-- =====================================================================
--
-- THE CHURN (found live 2026-07-07, unpause flashlight): steward_tick's
-- lane is `status='failed' AND failure_count<3 AND quarantined_at IS NULL
-- AND escalation_state='normal' ORDER BY updated_at ASC LIMIT 10`. When
-- an item raises INSIDE the per-item block BEFORE any row update — the
-- classic shape is pick_model()'s P0001 `no stage_models row for %/%`
-- (an operator-era family whose routing rows were lost, or any item
-- whose pipeline/stage has no routing config) — the per-item EXCEPTION
-- handler logged a 'tick_error' account and moved on. But the implicit
-- savepoint rollback meant NOTHING on the row changed: not status, not
-- failure_count, not updated_at. The same items stayed the 10 oldest
-- 'failed' rows, monopolized the LIMIT-10 lane every 30s tick, and
-- STARVED every retryable item behind them — invisible (failure_count
-- never moved) and eternal. 62 stale June items rode this carousel.
--
-- v27 (107) already broke the sibling loop where the DISPATCH call
-- failed (work_item_dispatch_stage_safe parks "nothing configured" into
-- awaiting_review). This volume closes the remaining half: an exception
-- ANYWHERE in the per-item block now parks the item the SAME way —
-- status='awaiting_review' + a readable error — which (a) frees the
-- lane immediately (status no longer 'failed'), and (b) gives the item
-- a face in needs_attention's 'review' bucket (v19: awaiting_review AND
-- a2a_question IS NULL, question = coalesce(error, …)), so the Stewdio
-- bell shows it instead of the ledger hiding it. Visibility over silent
-- churn — the same call as #336 (the kill switch) and #330 (the sweeper
-- poison-pill, per-row isolation so one poison row can't wedge a batch).
--
-- Park-on-first-strike is deliberate: the tick_error shapes seen in the
-- wild are deterministic (missing routing config), so a retry 30s later
-- fails identically; and a false positive (a genuinely transient tick
-- error parking a healthy item) costs one visible, resumable bell entry
-- — strictly better than the false negative's invisible starvation.
-- Resume paths already exist: fix the config, then resume from the bell
-- (work_item_escalation_resolve / the attention answer API re-dispatches
-- via work_item_dispatch_stage_safe, which re-parks if still broken).
--
-- OWNERSHIP: re-authors stewards.steward_tick() ONE more time. The
-- previous full author is v27-lifeless-core.sql (107, sentinel rename +
-- dispatch-safe swap over 32's FINAL body); v27 is NOT edited (its sha
-- is in the migrate ledger — editing an applied volume would trigger a
-- re-apply of the whole lifeless-core migration). Body below is v27's
-- verbatim except: DECLARE gains v_parked, and the per-item EXCEPTION
-- handler parks before it accounts. 103's guarded
-- abort_conditions_evaluate() sweep is carried verbatim.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.steward_tick()
RETURNS int
LANGUAGE plpgsql AS $stk$
DECLARE
    v_count               int := 0;
    v_item                record;
    v_diagnosis           text;
    v_next_model          text;
    v_breaker_ok          boolean;
    v_attempt             int;
    v_retry_text          text;
    v_dispatched_work_id  bigint;
    v_provider            text;
    v_stage               jsonb;
    v_stage_model         text;
    v_forbid              boolean;
    v_excluded            jsonb;
    v_fp                  text;
    v_fm                  text;
    v_parked              boolean;
BEGIN
    FOR v_item IN
        SELECT id, pipeline_family, current_stage, failure_count,
               last_failure_reason, escalation_state, intent_id
          FROM stewards.work_items
         WHERE status = 'failed'
           AND failure_count < 3
           AND quarantined_at IS NULL
           AND escalation_state = 'normal'
         ORDER BY updated_at ASC
         LIMIT 10
         FOR UPDATE SKIP LOCKED
    LOOP
        BEGIN
            v_attempt := v_item.failure_count + 1;

            IF stewards.cost_cap_exceeded(v_item.id) THEN
                UPDATE stewards.work_items
                   SET quarantined_at = now(),
                       quarantine_reason = 'cost_cap_exceeded'
                 WHERE id = v_item.id;

                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action, details)
                VALUES
                    (v_item.id,
                     'cumulative cost exceeded cap; quarantining',
                     'cost_limit',
                     'quarantine',
                     jsonb_build_object('quarantine_reason','cost_cap_exceeded'));

                PERFORM stewards.maybe_enqueue_atonement(v_item.id);

                v_count := v_count + 1;
                CONTINUE;
            END IF;

            v_diagnosis := stewards.diagnose_failure(
                v_item.last_failure_reason, v_item.failure_count);
            UPDATE stewards.work_items
               SET last_failure_diagnosis = v_diagnosis
             WHERE id = v_item.id;

            v_breaker_ok := stewards.breaker_check(
                v_item.pipeline_family, v_item.current_stage);
            IF NOT v_breaker_ok THEN
                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action)
                VALUES
                    (v_item.id,
                     format('breaker open for %s/%s; deferring',
                            v_item.pipeline_family, v_item.current_stage),
                     v_diagnosis,
                     'defer_breaker_open');
                v_count := v_count + 1;
                CONTINUE;
            END IF;

            IF v_diagnosis IN ('transient','timeout') THEN
                v_stage := stewards.pipeline_stage_lookup(
                    v_item.pipeline_family, v_item.current_stage);
                v_stage_model := v_stage->>'model';
                IF v_stage_model IS NOT NULL
                   AND EXISTS (SELECT 1 FROM stewards.model_aliases WHERE alias = v_stage_model) THEN
                    v_forbid := stewards.intent_forbids_training(v_item.intent_id)
                                AND NOT COALESCE((v_stage->>'public_io')::boolean, false);
                    v_excluded := stewards.alias_transient_failed_members(
                        v_item.id, v_item.current_stage);
                    SELECT m.provider, m.model INTO v_fp, v_fm
                      FROM stewards.pick_alias_member(v_stage_model, v_forbid, v_excluded) m;
                    IF v_fp IS NOT NULL AND v_fm IS NOT NULL THEN
                        UPDATE stewards.work_items
                           SET provider_override = v_fp,
                               model_override    = v_fm,
                               failure_count     = failure_count + 1
                         WHERE id = v_item.id;

                        -- 107: swapped to the safe wrapper so an alias
                        -- member that resolves but is STILL unusable
                        -- (capability-unusable, no substitute) breaks the
                        -- retry loop into awaiting_review instead of
                        -- retrying this same item forever.
                        v_dispatched_work_id := stewards.work_item_dispatch_stage_safe(
                            v_item.id, NULL, true);

                        INSERT INTO stewards.steward_actions
                            (work_item_id, observation, diagnosis, action, model_used,
                             details)
                        VALUES
                            (v_item.id,
                             format('alias %s failover -> %s/%s (attempt #%s after %s); work_id %s',
                                    v_stage_model, v_fp, v_fm, v_attempt, v_diagnosis,
                                    v_dispatched_work_id),
                             v_diagnosis,
                             CASE WHEN v_dispatched_work_id IS NULL THEN 'alias_failover_parked' ELSE 'alias_failover' END,
                             v_fm,
                             jsonb_build_object(
                                 'alias', v_stage_model,
                                 'provider', v_fp,
                                 'model', v_fm,
                                 'excluded', v_excluded,
                                 'dispatched_work_id', v_dispatched_work_id));

                        v_count := v_count + 1;
                        CONTINUE;
                    END IF;
                ELSIF v_stage IS NOT NULL AND v_stage_model IS NOT NULL THEN
                    UPDATE stewards.work_items
                       SET failure_count = failure_count + 1
                     WHERE id = v_item.id;
                    v_dispatched_work_id := stewards.work_item_dispatch_stage_safe(
                        v_item.id, NULL, true);
                    INSERT INTO stewards.steward_actions
                        (work_item_id, observation, diagnosis, action, model_used, details)
                    VALUES
                        (v_item.id,
                         format('pinned %s transient retry (attempt #%s after %s); work_id %s',
                                v_stage_model, v_attempt, v_diagnosis, v_dispatched_work_id),
                         v_diagnosis,
                         CASE WHEN v_dispatched_work_id IS NULL THEN 'pinned_retry_parked' ELSE 'pinned_retry' END,
                         v_stage_model,
                         jsonb_build_object('model', v_stage_model,
                                            'dispatched_work_id', v_dispatched_work_id));
                    v_count := v_count + 1;
                    CONTINUE;
                END IF;
            END IF;

            v_next_model := stewards.pick_model(
                v_item.pipeline_family, v_item.current_stage,
                v_attempt, v_diagnosis);

            IF v_next_model = '__queue_for_strongest__' THEN
                UPDATE stewards.work_items
                   SET escalation_state = 'queued',
                       escalation_attempts = escalation_attempts + 1
                 WHERE id = v_item.id;

                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action, model_used,
                     details)
                VALUES
                    (v_item.id,
                     'escalation chain exhausted; queued for human-mediated boost',
                     v_diagnosis,
                     'queue_for_strongest',
                     '__queue_for_strongest__',
                     jsonb_build_object(
                         'attempt', v_attempt,
                         'escalation_attempts',
                             (SELECT escalation_attempts FROM stewards.work_items
                               WHERE id = v_item.id)));
                v_count := v_count + 1;
                CONTINUE;
            END IF;

            SELECT provider INTO v_provider
              FROM stewards.model_pricing
             WHERE model = v_next_model
             ORDER BY effective_at DESC
             LIMIT 1;

            v_retry_text := stewards.retry_guidance_with_lessons(
                v_diagnosis, v_attempt,
                v_item.pipeline_family, v_item.current_stage);

            UPDATE stewards.work_items
               SET model_override     = v_next_model,
                   provider_override  = v_provider,
                   failure_count      = failure_count + 1
             WHERE id = v_item.id;

            -- 107: swapped to the safe wrapper. Previously an "unconfigured"
            -- failure here rolled back this whole BEGIN block (including the
            -- UPDATE just above), so the item's failure_count never advanced
            -- and steward_tick picked the SAME item again next tick, forever
            -- — the exact silent-retry-loop shape the audit named for the
            -- scheduler. Now it lands cleanly in awaiting_review instead.
            v_dispatched_work_id := stewards.work_item_dispatch_stage_safe(
                v_item.id, v_retry_text, true);

            INSERT INTO stewards.steward_actions
                (work_item_id, observation, diagnosis, action, model_used,
                 details)
            VALUES
                (v_item.id,
                 format('attempt #%s after %s; dispatched as work_id %s',
                        v_attempt, v_diagnosis, v_dispatched_work_id),
                 v_diagnosis,
                 CASE WHEN v_dispatched_work_id IS NULL THEN 'retry_parked_for_review' ELSE 'retry_dispatched' END,
                 v_next_model,
                 jsonb_build_object(
                     'attempt', v_attempt,
                     'retry_guidance', v_retry_text,
                     'dispatched_work_id', v_dispatched_work_id,
                     'provider_override', v_provider));

            v_count := v_count + 1;
        EXCEPTION WHEN OTHERS THEN
            -- v31 (#338): the savepoint rollback undid every row change,
            -- so without a park this item stays among the 10 oldest
            -- 'failed' rows and monopolizes the lane forever. Park it
            -- out of the lane, visibly (needs_attention 'review' bucket
            -- renders the error as the question), then account.
            v_parked := false;
            BEGIN
                UPDATE stewards.work_items
                   SET status     = 'awaiting_review',
                       error      = left(
                           'steward retry errored: ' || SQLERRM
                           || ' — likely missing routing config (stage_models / pipeline stages) for '
                           || COALESCE(v_item.pipeline_family, '?') || '/'
                           || COALESCE(v_item.current_stage, '?')
                           || '. Fix the configuration, then resume from the bell.',
                           2000),
                       updated_at = now()
                 WHERE id = v_item.id;
                v_parked := true;
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
            BEGIN
                INSERT INTO stewards.steward_actions
                    (work_item_id, observation, diagnosis, action, details)
                VALUES
                    (v_item.id,
                     'tick error: ' || SQLERRM,
                     COALESCE(v_diagnosis, 'unknown'),
                     'tick_error',
                     jsonb_build_object(
                         'sqlerrm', SQLERRM,
                         'sqlstate', SQLSTATE,
                         'pipeline_family', v_item.pipeline_family,
                         'current_stage', v_item.current_stage,
                         'parked_awaiting_review', v_parked));
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
            v_count := v_count + 1;
        END;
    END LOOP;

    IF to_regprocedure('stewards.abort_conditions_evaluate()') IS NOT NULL THEN
        BEGIN
            v_count := v_count + stewards.abort_conditions_evaluate();
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                INSERT INTO stewards.steward_actions (observation, action, details)
                VALUES ('abort_conditions_evaluate failed: ' || SQLERRM, 'tick_error',
                        jsonb_build_object('sqlerrm', SQLERRM, 'sqlstate', SQLSTATE,
                                           'source', 'abort_conditions_evaluate'));
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
        END;
    END IF;

    RETURN v_count;
END;
$stk$;

COMMENT ON FUNCTION stewards.steward_tick() IS
'v31 (#338, re-authors 107''s FINAL body, tick-error park only): Watch->Diagnose->Act->Account with per-item exception isolation; alias-failover + pinned-retry branches; lessons-aware retry + pick_model escalation (__queue_for_strongest__ sentinel). NEW: a per-item exception (classically pick_model''s "no stage_models row" P0001 on an item with no routing config) now PARKS the item at awaiting_review with a readable error — freeing the LIMIT-10 lane and ringing needs_attention''s review bucket — instead of leaving the row untouched to monopolize the lane every tick (the starvation churn found live 2026-07-07). The tick_error account carries parked_awaiting_review. 103''s guarded abort_conditions_evaluate() sweep carried verbatim; the dispatch-failure half of this loop was already parked by 107''s work_item_dispatch_stage_safe.';
