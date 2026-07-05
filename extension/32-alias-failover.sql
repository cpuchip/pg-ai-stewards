-- =====================================================================
-- 32-alias-failover.sql — runtime failover across alias members.
-- =====================================================================
-- 31 gave alias resolution a STATIC filter: a member that is unconfigured,
-- unusable, over-cap, or probe-failed is skipped at dispatch time. The gap it
-- left (the documented P1): a provider that is UP but fails MID-CALL (NVIDIA
-- returns a Cloudflare 521, Moonshot 522, an Anthropic 529 overload) — the
-- member was usable at dispatch, so the work_item just fails. The M.5 auto-probe
-- only flips it unusable on the next cadence.
--
-- This file closes that gap by teaching the steward to WALK to the next alias
-- member when a transient/timeout failure hits an alias-dispatched stage —
-- before pick_model (which raises for stages-jsonb pipelines that have no
-- stage_models row, so without this the steward gives an alias stage no retry at
-- all). It also fixes diagnose_failure, whose transient regex matched only
-- 500-504 and so MISSED the exact Cloudflare 52x shape that motivated this.
--
-- Three core re-authors (later-file-wins; CORE-on-CORE, clobber-check safe):
--   §1 diagnose_failure (07)      — broaden the transient class to any 5xx
--                                   (incl. 52x), 408, 529, "overloaded",
--                                   Cloudflare "web server" text.
--   §2 pick_alias_member (31)     — gains an exclude set (skip tried members).
--   §3 steward_tick (07)          — the alias-failover branch.
-- + §2.5 a small helper for the tried-transient member set.
--
-- requires create_model_aliases (31). No schema change; no data migration.
-- The mechanism mirrors the steward's existing escalation (set model_override +
-- provider_override, re-dispatch with p_allow_failed_status). Known limit: like
-- that escalation, the override persists, so a mid-pipeline failover keeps the
-- work_item's LATER stages on the chosen member for that run (it self-heals on
-- the next run / work_item). Clearing overrides on stage advance is the clean
-- follow-up (improves the existing escalation too).
-- =====================================================================


-- =====================================================================
-- §1 — diagnose_failure: the transient class was too narrow.
-- =====================================================================
-- The old regex matched 5(00|01|02|03|04) only, so a Cloudflare 521/522 ("web
-- server is down"), an Anthropic 529 ("overloaded"), and a 408 all fell through
-- to 'unknown' — and the alias failover keys on 'transient'/'timeout'. Broaden
-- to any 5xx + 408 + the overload/web-server phrasings. Timeout still checked
-- first (most specific). IMMUTABLE preserved.
CREATE OR REPLACE FUNCTION stewards.diagnose_failure(
    p_reason         text,
    p_failure_count  int DEFAULT 0
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_lower text;
BEGIN
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        IF p_failure_count >= 2 THEN
            RETURN 'model_limit';
        END IF;
        RETURN 'unknown';
    END IF;

    v_lower := lower(p_reason);

    IF v_lower ~ '(timeout|timed out|context deadline exceeded|inactivity|deadline)' THEN
        RETURN 'timeout';
    END IF;

    -- Transient: any 5xx (incl. Cloudflare 52x), 408, 429/rate limits, network
    -- blips, and the common overload / "web server is down" phrasings. Provider
    -- issue, not a model-capability issue.
    -- NOTE: 68-model-fallback-hardening.sql RE-AUTHORS this function (it is the
    -- live authority). The #326 upstream-400 pattern lives THERE, not here.
    IF v_lower ~ '(408|429|rate.?limit|5[0-9][0-9]|network|connection (refused|reset)|temporarily unavailable|service unavailable|overloaded|web server (is down|returned|error))' THEN
        RETURN 'transient';
    END IF;

    IF v_lower ~ '(tool.{0,30}(error|not found|missing|invalid)|function.{0,20}(error|not found|missing|invalid)|schema.{0,20}(error|invalid|mismatch)|validation.{0,20}(failed|error))' THEN
        RETURN 'tool_error';
    END IF;

    IF p_failure_count >= 2 THEN
        RETURN 'model_limit';
    END IF;

    RETURN 'unknown';
END;
$func$;

COMMENT ON FUNCTION stewards.diagnose_failure(text, int) IS
'Classify a failure reason into (transient | timeout | model_limit | tool_error | unknown). 32: the transient class now covers any 5xx (incl. Cloudflare 52x), 408, 529/overloaded, and "web server is down" — so alias failover triggers on the real provider-outage shapes.';


-- =====================================================================
-- §2 — pick_alias_member gains an exclude set.
-- =====================================================================
-- Same selection as 31 plus: skip any member whose {provider, model} is in
-- p_exclude. Used by the failover to walk PAST members that already failed this
-- attempt. Replaces the 2-arg form (drop-then-create — a defaulted 3rd arg
-- would make the 2-arg call ambiguous); the 31 dispatch's 2-arg call resolves
-- to this via the default at runtime.
DROP FUNCTION IF EXISTS stewards.pick_alias_member(text, boolean);

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
'31/32: resolve a model alias to its best concrete (provider, model) — lowest priority that is configured (when the registry is populated) + usable + under spend cap + (when p_forbid_training) no-train + NOT in p_exclude (a jsonb array of {provider, model} already tried this attempt). No rows if none qualify.';


-- =====================================================================
-- §2.5 — the tried-transient member set for a work_item's current stage.
-- =====================================================================
-- The members an alias-dispatched stage has already tried THIS run and that
-- failed with a transient/timeout error. Derived from work_queue history — no
-- new column. (A member that COMPLETED is not excluded, so a revise/re-run can
-- legitimately reuse it.) Resets naturally per stage (keyed by _stage_name).
CREATE OR REPLACE FUNCTION stewards.alias_transient_failed_members(
    p_work_item_id uuid,
    p_stage        text
) RETURNS jsonb
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object(
               'provider', wq.provider, 'model', wq.payload->>'requested_model')), '[]'::jsonb)
      FROM stewards.work_queue wq
     WHERE wq.kind = 'chat'
       AND wq.status = 'error'
       AND wq.payload->>'_work_item_id' = p_work_item_id::text
       AND wq.payload->>'_stage_name'   = p_stage
       AND stewards.diagnose_failure(COALESCE(wq.error, '')) IN ('transient','timeout');
$$;

COMMENT ON FUNCTION stewards.alias_transient_failed_members(uuid, text) IS
'32: the {provider, model} set an alias stage already tried this run that failed transiently (from work_queue error rows). Feeds pick_alias_member''s exclude so failover walks to the next member.';


-- =====================================================================
-- §3 — steward_tick: walk to the next alias member on a transient failure.
-- =====================================================================
-- Carries the 07 final verbatim and inserts ONE branch (step 3.5) after the
-- breaker check and before pick_model: when the failed work_item's current
-- stage declares a model ALIAS and the diagnosis is transient/timeout, pick the
-- next untried member (excluding the ones that already transient-failed this
-- run) and re-dispatch it. Falls through to the normal pick_model path when the
-- stage is not an alias, the failure is not transient, or all members are spent.
CREATE OR REPLACE FUNCTION stewards.steward_tick()
RETURNS int
LANGUAGE plpgsql AS $func$
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
    -- 32 alias-failover state
    v_stage               jsonb;
    v_stage_model         text;
    v_forbid              boolean;
    v_excluded            jsonb;
    v_fp                  text;
    v_fm                  text;
BEGIN
    FOR v_item IN
        SELECT id, pipeline_family, current_stage, failure_count,
               last_failure_reason, escalation_state, intent_id
          FROM stewards.work_items
         WHERE status = 'failed'
           AND failure_count < 3
           AND quarantined_at IS NULL
           AND escalation_state = 'normal'
         ORDER BY updated_at ASC  -- oldest failures first
         LIMIT 10
         FOR UPDATE SKIP LOCKED
    LOOP
        BEGIN
            v_attempt := v_item.failure_count + 1;

            -- 1. Cost cap check
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

            -- 2. Diagnose (cached on the work_item for visibility)
            v_diagnosis := stewards.diagnose_failure(
                v_item.last_failure_reason, v_item.failure_count);
            UPDATE stewards.work_items
               SET last_failure_diagnosis = v_diagnosis
             WHERE id = v_item.id;

            -- 3. Breaker check
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

            -- 3.5 ALIAS RUNTIME FAILOVER (32): a provider/transient/timeout
            -- failure on an alias-dispatched stage → walk to the next untried
            -- member. Runs BEFORE pick_model, which raises for stages-jsonb
            -- pipelines (no stage_models row) and so would give an alias stage
            -- no retry at all.
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

                        v_dispatched_work_id := stewards.work_item_dispatch_stage(
                            v_item.id, NULL, true);

                        INSERT INTO stewards.steward_actions
                            (work_item_id, observation, diagnosis, action, model_used,
                             details)
                        VALUES
                            (v_item.id,
                             format('alias %s failover → %s/%s (attempt #%s after %s); work_id %s',
                                    v_stage_model, v_fp, v_fm, v_attempt, v_diagnosis,
                                    v_dispatched_work_id),
                             v_diagnosis,
                             'alias_failover',
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
                    -- no untried member left → fall through to pick_model.
                ELSIF v_stage IS NOT NULL AND v_stage_model IS NOT NULL THEN
                    -- #326: pinned concrete model on a stages-jsonb stage. No alias
                    -- to walk, and pick_model RAISES for stages pipelines (no
                    -- stage_models row) — so without this a transient provider blip
                    -- (e.g. a gateway-wrapped upstream 400) gives the stage NO
                    -- retry at all. Re-dispatch the SAME pinned stage; failure_count<3
                    -- caps it, then it parks (a persistent outage escalates normally).
                    UPDATE stewards.work_items
                       SET failure_count = failure_count + 1
                     WHERE id = v_item.id;
                    v_dispatched_work_id := stewards.work_item_dispatch_stage(
                        v_item.id, NULL, true);
                    INSERT INTO stewards.steward_actions
                        (work_item_id, observation, diagnosis, action, model_used, details)
                    VALUES
                        (v_item.id,
                         format('pinned %s transient retry (attempt #%s after %s); work_id %s',
                                v_stage_model, v_attempt, v_diagnosis, v_dispatched_work_id),
                         v_diagnosis, 'pinned_retry', v_stage_model,
                         jsonb_build_object('model', v_stage_model,
                                            'dispatched_work_id', v_dispatched_work_id));
                    v_count := v_count + 1;
                    CONTINUE;
                END IF;
            END IF;

            -- 4. Pick model (raises if no stage_models row exists;
            -- caught by the per-item EXCEPTION below)
            v_next_model := stewards.pick_model(
                v_item.pipeline_family, v_item.current_stage,
                v_attempt, v_diagnosis);

            -- 5. Queue sentinel → human-mediated escalation
            IF v_next_model = '__queue_for_opus__' THEN
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
                     'queue_for_opus',
                     '__queue_for_opus__',
                     jsonb_build_object(
                         'attempt', v_attempt,
                         'escalation_attempts',
                             (SELECT escalation_attempts FROM stewards.work_items
                               WHERE id = v_item.id)));
                v_count := v_count + 1;
                CONTINUE;
            END IF;

            -- 6. Resolve provider from model_pricing (each model knows
            -- its provider; that's the canonical mapping). NULL when
            -- the model has no pricing row — then no provider override
            -- is set and the stage's own provider applies at dispatch.
            SELECT provider INTO v_provider
              FROM stewards.model_pricing
             WHERE model = v_next_model
             ORDER BY effective_at DESC
             LIMIT 1;

            -- 7. Retry path: lessons-aware guidance, set overrides,
            -- dispatch, account.
            v_retry_text := stewards.retry_guidance_with_lessons(
                v_diagnosis, v_attempt,
                v_item.pipeline_family, v_item.current_stage);

            UPDATE stewards.work_items
               SET model_override     = v_next_model,
                   provider_override  = v_provider,
                   failure_count      = failure_count + 1
             WHERE id = v_item.id;

            v_dispatched_work_id := stewards.work_item_dispatch_stage(
                v_item.id, v_retry_text, true);

            INSERT INTO stewards.steward_actions
                (work_item_id, observation, diagnosis, action, model_used,
                 details)
            VALUES
                (v_item.id,
                 format('attempt #%s after %s; dispatched as work_id %s',
                        v_attempt, v_diagnosis, v_dispatched_work_id),
                 v_diagnosis,
                 'retry_dispatched',
                 v_next_model,
                 jsonb_build_object(
                     'attempt', v_attempt,
                     'retry_guidance', v_retry_text,
                     'dispatched_work_id', v_dispatched_work_id,
                     'provider_override', v_provider));

            v_count := v_count + 1;
        EXCEPTION WHEN OTHERS THEN
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
                         'current_stage', v_item.current_stage));
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
            v_count := v_count + 1;
        END;
    END LOOP;

    RETURN v_count;
END;
$func$;

COMMENT ON FUNCTION stewards.steward_tick() IS
'Watch→Diagnose→Act→Account orchestration (32): per-item exception isolation; an ALIAS-FAILOVER branch walks a transient/timeout alias failure to its next untried member before pick_model (which raises for stages-jsonb pipelines); #326 adds a PINNED-RETRY sibling branch — a transient/timeout failure on a pinned concrete-model stages-jsonb stage re-dispatches the same stage (failure_count<3 caps it) instead of getting no retry at all; otherwise lessons-aware retry guidance + pick_model escalation. Returns count of actions taken. Called by the bgworker on tick.';


-- =====================================================================
-- End of 32-alias-failover.sql
-- =====================================================================
