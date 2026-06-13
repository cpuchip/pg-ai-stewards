-- =====================================================================
-- 07-steward — Watch → Diagnose → Act → Account
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Sources folded, in original
-- ship order: 4a-steward (failure tracking, diagnosis, retry guidance,
-- circuit breaker, the original tick), 4b (override-aware dispatch —
-- born into 04-work-items' work_item_dispatch_stage; its live-data
-- provider rename died with the fresh rebuild), 4c (tick actually
-- dispatches), 4d (per-item exception isolation + provider derived
-- from model_pricing; its stage_models seeds moved to the overlay),
-- 6b (retry guidance pulls ratified lessons), 6c (quarantine fires
-- atonement — pulled forward from the sabbath batch; the whole file
-- was just the tick redefinition). steward_tick appears once, in the
-- 6c final form. The work_items failure/quarantine/override columns
-- are born in 04-work-items' CREATE TABLE.
--
-- The design, in one paragraph: when a dispatch fails, the bridge
-- sets status='failed' and records the reason; the steward's tick
-- (called by the bgworker) walks failed work_items oldest-first and,
-- per item: quarantines on cost-cap (firing atonement when the
-- pipeline opts in), defers when the circuit breaker for the
-- (pipeline, stage) is open, classifies the failure (diagnose_failure,
-- a 5-type classifier), picks the next model by walking the
-- escalation matrix (06-cost), and either queues for human-mediated
-- escalation (the __queue_for_opus__ sentinel) or re-dispatches with
-- per-diagnosis retry guidance plus the last ratified lessons for the
-- stage. Every decision lands in steward_actions — the Account step.
-- Per-item exception isolation: one bad item logs a tick_error and
-- the loop continues.
--
-- (steward_tick's body references retry_guidance_with_lessons and
-- maybe_enqueue_atonement, which are created later in the chain —
-- safe because the bundle installs atomically and plpgsql bodies are
-- not validated at CREATE time.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- steward_actions — append-only audit ledger of every steward decision.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.steward_actions (
    id            bigserial PRIMARY KEY,
    work_item_id  uuid REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    at            timestamptz NOT NULL DEFAULT now(),
    observation   text NOT NULL,
    diagnosis     text,
    action        text NOT NULL,
    details       jsonb NOT NULL DEFAULT '{}'::jsonb,
    model_used    text,
    cost_micro    bigint
);
CREATE INDEX IF NOT EXISTS steward_actions_work_item ON stewards.steward_actions(work_item_id);
CREATE INDEX IF NOT EXISTS steward_actions_at        ON stewards.steward_actions(at);
CREATE INDEX IF NOT EXISTS steward_actions_action    ON stewards.steward_actions(action);

COMMENT ON TABLE stewards.steward_actions IS
'Append-only audit of every steward decision. The "Account" step of Watch→Diagnose→Act→Account.';

-- ---------------------------------------------------------------------
-- diagnose_failure — classify a failure reason into one of
-- (transient | timeout | model_limit | tool_error | unknown).
-- IMMUTABLE so it can be inlined in views and indexed if needed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.diagnose_failure(
    p_reason         text,
    p_failure_count  int DEFAULT 0
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_lower text;
BEGIN
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        -- No reason text. Use failure_count as proxy: a few failures
        -- with no reason string reads as model_limit so escalation
        -- kicks in.
        IF p_failure_count >= 2 THEN
            RETURN 'model_limit';
        END IF;
        RETURN 'unknown';
    END IF;

    v_lower := lower(p_reason);

    -- Order matters: timeout is most specific (overrides "rate limit"
    -- false-positives like "request timeout: rate limit hit").
    IF v_lower ~ '(timeout|timed out|context deadline exceeded|inactivity|deadline)' THEN
        RETURN 'timeout';
    END IF;

    -- Transient: rate limits, 5xx, network blips. Provider issue, not
    -- a model-capability issue.
    IF v_lower ~ '(429|rate.?limit|5(00|01|02|03|04)|network|connection refused|temporarily unavailable|service unavailable)' THEN
        RETURN 'transient';
    END IF;

    -- Tool error: model called a tool wrong, or the tool rejected the
    -- call. Distinct from model_limit because re-prompting with
    -- feedback usually fixes it.
    IF v_lower ~ '(tool.{0,30}(error|not found|missing|invalid)|function.{0,20}(error|not found|missing|invalid)|schema.{0,20}(error|invalid|mismatch)|validation.{0,20}(failed|error))' THEN
        RETURN 'tool_error';
    END IF;

    -- After 2+ failures without a recognized pattern, treat as
    -- model_limit. The model genuinely can't handle this.
    IF p_failure_count >= 2 THEN
        RETURN 'model_limit';
    END IF;

    RETURN 'unknown';
END;
$func$;

COMMENT ON FUNCTION stewards.diagnose_failure(text, int) IS
'Classify a failure reason into one of (transient | timeout | model_limit | tool_error | unknown).';

-- ---------------------------------------------------------------------
-- retry_guidance_text — per-diagnosis retry-context templates.
-- {attempt} is substituted by retry_guidance(). These defaults are
-- machinery (generic discipline text), not operator data.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.retry_guidance_text (
    diagnosis   text PRIMARY KEY CHECK (diagnosis IN
        ('transient','timeout','model_limit','tool_error','unknown')),
    template    text NOT NULL,
    notes       text
);

COMMENT ON TABLE stewards.retry_guidance_text IS
'Per-diagnosis retry-context templates. {attempt} is replaced with the current attempt number by retry_guidance().';

INSERT INTO stewards.retry_guidance_text (diagnosis, template, notes) VALUES
    ('transient',
     '**Steward retry context (attempt {attempt}):** Previous attempt failed with a transient provider issue (rate limit, 5xx, or network blip). The underlying issue has likely resolved. Proceed with the same approach.',
     'Same model, no strategy change'),
    ('timeout',
     '**Steward retry context (attempt {attempt}):** Previous attempt timed out. Break the work into smaller steps. Read files in targeted ranges rather than full files. Avoid loops that touch many tools in sequence. If you need to plan, plan tightly.',
     'Reduce per-step work to fit inside the timeout window'),
    ('tool_error',
     '**Steward retry context (attempt {attempt}):** Previous attempt failed with a tool error — the tool may not exist, the arguments may be wrong, or a schema check failed. Check the tool name against your available tools. Verify argument names and types. If the schema rejected your output, re-read the schema constraints carefully.',
     'Help the model self-correct on tool usage'),
    ('model_limit',
     '**Steward retry context (attempt {attempt}):** Previous attempts failed despite reasonable strategies, suggesting this task may be at the edge of what the current model can handle. Simplify the task. Re-read the plan/spec carefully. Identify the single most important next step and do only that. The next attempt will use a more capable model.',
     'Acknowledge the cliff; sets up the escalation'),
    ('unknown',
     '**Steward retry context (attempt {attempt}):** Previous attempt failed but the failure reason did not match a known pattern. Re-examine the input, the spec, and any error output from the last attempt. Be deliberate.',
     'Generic fallback')
ON CONFLICT (diagnosis) DO UPDATE
SET template = EXCLUDED.template,
    notes    = EXCLUDED.notes;

-- Compose retry guidance for a diagnosis + attempt. NULL if no
-- template exists (caller skips prepending guidance).
CREATE OR REPLACE FUNCTION stewards.retry_guidance(
    p_diagnosis text,
    p_attempt   int
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_template text;
BEGIN
    SELECT template INTO v_template
      FROM stewards.retry_guidance_text
     WHERE diagnosis = p_diagnosis;

    IF v_template IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN replace(v_template, '{attempt}', p_attempt::text);
END;
$func$;

COMMENT ON FUNCTION stewards.retry_guidance(text, int) IS
'Compose the per-diagnosis retry-context message with attempt number substituted.';

-- ---------------------------------------------------------------------
-- pipeline_breakers — per-(pipeline, stage) circuit breaker. Three
-- states: closed (normal) | open (cooling down) | half_open (probe).
-- failure_threshold trips it; cooldown elapses to half_open; success
-- on half-open closes; failure on half-open re-opens.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.pipeline_breakers (
    pipeline_family   text NOT NULL,
    stage_name        text NOT NULL,
    state             text NOT NULL DEFAULT 'closed' CHECK (state IN ('closed','open','half_open')),
    failure_count     int NOT NULL DEFAULT 0,
    opened_at         timestamptz,
    half_open_at      timestamptz,
    cooldown_minutes  int NOT NULL DEFAULT 10,
    failure_threshold int NOT NULL DEFAULT 5,
    last_state_change timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (pipeline_family, stage_name)
);

COMMENT ON TABLE stewards.pipeline_breakers IS
'Per-(pipeline_family, stage) circuit breaker. closed (normal) | open (cooling down) | half_open (probe). failure_threshold failures trip it; cooldown_minutes later one probe is allowed.';

-- Returns true if the breaker permits a dispatch. Lazy-creates the
-- breaker row; transitions open → half_open when cooldown elapses.
CREATE OR REPLACE FUNCTION stewards.breaker_check(
    p_pipeline text,
    p_stage    text
) RETURNS boolean
LANGUAGE plpgsql AS $func$
DECLARE
    v_breaker stewards.pipeline_breakers;
BEGIN
    INSERT INTO stewards.pipeline_breakers (pipeline_family, stage_name)
    VALUES (p_pipeline, p_stage)
    ON CONFLICT DO NOTHING;

    SELECT * INTO v_breaker
      FROM stewards.pipeline_breakers
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage
     FOR UPDATE;

    IF v_breaker.state = 'closed' THEN
        RETURN true;
    END IF;

    -- Half-open: one probe permitted; record_success/record_failure
    -- will close or re-open.
    IF v_breaker.state = 'half_open' THEN
        RETURN true;
    END IF;

    -- Open: transition to half_open when cooldown elapses.
    IF v_breaker.opened_at IS NOT NULL
       AND v_breaker.opened_at + (v_breaker.cooldown_minutes * interval '1 minute') <= now()
    THEN
        UPDATE stewards.pipeline_breakers
           SET state = 'half_open',
               half_open_at = now(),
               last_state_change = now()
         WHERE pipeline_family = p_pipeline AND stage_name = p_stage;
        RETURN true;
    END IF;

    RETURN false;
END;
$func$;

COMMENT ON FUNCTION stewards.breaker_check(text, text) IS
'Returns true if the breaker permits a dispatch. Lazy-creates breaker row; transitions open → half_open on cooldown.';

CREATE OR REPLACE FUNCTION stewards.breaker_record_failure(
    p_pipeline text,
    p_stage    text
) RETURNS void
LANGUAGE plpgsql AS $func$
DECLARE
    v_breaker stewards.pipeline_breakers;
BEGIN
    INSERT INTO stewards.pipeline_breakers (pipeline_family, stage_name)
    VALUES (p_pipeline, p_stage)
    ON CONFLICT DO NOTHING;

    SELECT * INTO v_breaker
      FROM stewards.pipeline_breakers
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage
     FOR UPDATE;

    IF v_breaker.state = 'half_open' THEN
        -- Probe failed. Re-open with fresh cooldown.
        UPDATE stewards.pipeline_breakers
           SET state = 'open',
               opened_at = now(),
               half_open_at = NULL,
               last_state_change = now(),
               failure_count = failure_count + 1
         WHERE pipeline_family = p_pipeline AND stage_name = p_stage;
        RETURN;
    END IF;

    UPDATE stewards.pipeline_breakers
       SET failure_count = failure_count + 1
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage;

    SELECT * INTO v_breaker
      FROM stewards.pipeline_breakers
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage;

    IF v_breaker.state = 'closed'
       AND v_breaker.failure_count >= v_breaker.failure_threshold
    THEN
        UPDATE stewards.pipeline_breakers
           SET state = 'open',
               opened_at = now(),
               last_state_change = now()
         WHERE pipeline_family = p_pipeline AND stage_name = p_stage;
    END IF;
END;
$func$;

CREATE OR REPLACE FUNCTION stewards.breaker_record_success(
    p_pipeline text,
    p_stage    text
) RETURNS void
LANGUAGE plpgsql AS $func$
BEGIN
    UPDATE stewards.pipeline_breakers
       SET state = 'closed',
           failure_count = 0,
           opened_at = NULL,
           half_open_at = NULL,
           last_state_change = now()
     WHERE pipeline_family = p_pipeline AND stage_name = p_stage
       AND (state != 'closed' OR failure_count > 0);
END;
$func$;

COMMENT ON FUNCTION stewards.breaker_record_failure(text, text) IS
'Increment breaker failure_count; trip if threshold reached.';
COMMENT ON FUNCTION stewards.breaker_record_success(text, text) IS
'Reset breaker to closed state with failure_count=0.';

-- ---------------------------------------------------------------------
-- steward_tick — the orchestration, in its final form (4d isolation +
-- 6b lessons-aware retry guidance + 6c atonement-on-quarantine).
-- Returns count of actions taken; the bgworker calls it on tick and
-- logs the count.
-- ---------------------------------------------------------------------
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
BEGIN
    FOR v_item IN
        SELECT id, pipeline_family, current_stage, failure_count,
               last_failure_reason, escalation_state
          FROM stewards.work_items
         WHERE status = 'failed'
           AND failure_count < 3
           AND quarantined_at IS NULL
           AND escalation_state = 'normal'
         ORDER BY updated_at ASC  -- oldest failures first
         LIMIT 10
         FOR UPDATE SKIP LOCKED
    LOOP
        -- Per-item exception isolation. Any error inside this block
        -- logs to steward_actions and the loop continues; one bad item
        -- never poisons the tick batch.
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

                -- Fire atonement on quarantine. No-op when the
                -- pipeline's atonement_enabled is false.
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
            -- Per-item failure isolation. The BEGIN block's
            -- sub-transaction rolled back this item's partial work;
            -- log in a fresh sub-transaction and move on.
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
                NULL;  -- if even logging fails, keep the loop alive
            END;
            v_count := v_count + 1;
        END;
    END LOOP;

    RETURN v_count;
END;
$func$;

COMMENT ON FUNCTION stewards.steward_tick() IS
'Watch→Diagnose→Act→Account orchestration, final form: per-item exception isolation, lessons-aware retry guidance (retry_guidance_with_lessons), provider derived from model_pricing (NULL = stage provider applies), cost-cap quarantine fires maybe_enqueue_atonement (no-op when the pipeline opts out). Returns count of actions taken. Called by the bgworker on tick.';

-- ---------------------------------------------------------------------
-- work_items_steward_status — latest steward_action per work_item,
-- joined with the work_item. For status panels.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.work_items_steward_status AS
SELECT
    wi.id                       AS work_item_id,
    wi.slug,
    wi.pipeline_family,
    wi.current_stage,
    wi.status,
    wi.failure_count,
    wi.last_failure_diagnosis,
    wi.escalation_state,
    wi.quarantined_at,
    wi.quarantine_reason,
    wi.cost_micro_dollars,
    wi.cost_cap_micro,
    wi.cost_capped_at,
    sa.at                       AS last_action_at,
    sa.observation              AS last_observation,
    sa.action                   AS last_action,
    sa.model_used               AS last_model_used,
    sa.diagnosis                AS last_action_diagnosis
  FROM stewards.work_items wi
  LEFT JOIN LATERAL (
      SELECT * FROM stewards.steward_actions
       WHERE work_item_id = wi.id
       ORDER BY at DESC
       LIMIT 1
  ) sa ON true;

COMMENT ON VIEW stewards.work_items_steward_status IS
'Per-work_item status with the most recent steward_action surfaced. For status panels.';
