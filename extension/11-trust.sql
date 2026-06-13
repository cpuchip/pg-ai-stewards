-- =====================================================================
-- 11-trust.sql — the trust ladder + the trust-gated apply_gate_decision.
--
-- Consolidated (authoring leg, 2026-06-13) from the historical chain:
--   5f   — trust_scores / trust_transitions / gate_overrides /
--          trust_thresholds tables + threshold seeds
--   5f2  — trust_record_success/failure/override, evaluate_trust, trust_adjust
--   5f3  — work_item_stage_actor + apply_gate_decision (trust gate)
--   5f4  — retry_guidance_with_lessons
--   5f5  — apply_gate_override
--
-- apply_gate_decision lives HERE (not 08-gates): its trust check SELECTs
-- from stewards.trust_scores, and a plpgsql SELECT from a table born later
-- in the chain is not a proven-safe forward reference at CREATE. This is its
-- single, final definition — the trust gate (5f3) WITHOUT the inline
-- sabbath fire (h1-6-2 moved sabbath to the on_maturity_verified trigger in
-- 08-gates; firing it here too would double-dispatch).
--
-- Ladder (D-E1): trainee → journeyman → master, keyed by
-- (agent_family, pipeline_family, model). Trainee surfaces every advance
-- for human ratification; journeyman + master proceed automatically.
-- =====================================================================

-- ---------------------------------------------------------------------
-- trust_scores
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.trust_scores (
    agent_family            text NOT NULL,
    pipeline_family         text NOT NULL,
    model                   text NOT NULL,
    successful_completions  int NOT NULL DEFAULT 0,
    failed_completions      int NOT NULL DEFAULT 0,
    human_overrides         int NOT NULL DEFAULT 0,
    trust_level             text NOT NULL DEFAULT 'trainee'
                              CHECK (trust_level IN ('trainee', 'journeyman', 'master')),
    last_evaluated_at       timestamptz NOT NULL DEFAULT now(),
    last_completion_at      timestamptz,
    PRIMARY KEY (agent_family, pipeline_family, model)
);

COMMENT ON TABLE stewards.trust_scores IS
'Per-(agent_family, pipeline_family, model) trust state. Trainee surfaces every gate-advance for human ratification; journeyman + master proceed automatically. Demote on human override (D-E3 full weight).';

-- ---------------------------------------------------------------------
-- trust_transitions — audit ledger
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.trust_transitions (
    id                  bigserial PRIMARY KEY,
    at                  timestamptz NOT NULL DEFAULT now(),
    agent_family        text NOT NULL,
    pipeline_family     text NOT NULL,
    model               text NOT NULL,
    from_level          text NOT NULL,
    to_level            text NOT NULL,
    transition_kind     text NOT NULL CHECK (transition_kind IN ('auto', 'manual')),
    actor               text NOT NULL,
    justification       text,
    metrics             jsonb
);

CREATE INDEX IF NOT EXISTS trust_transitions_at   ON stewards.trust_transitions (at);
CREATE INDEX IF NOT EXISTS trust_transitions_cell ON stewards.trust_transitions (agent_family, pipeline_family, model);

COMMENT ON TABLE stewards.trust_transitions IS
'Every trust level change recorded with reason. Manual transitions require justification (D-E2).';

-- ---------------------------------------------------------------------
-- gate_overrides — human disagreement with a gate decision
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.gate_overrides (
    id                bigserial PRIMARY KEY,
    gate_decision_id  bigint NOT NULL REFERENCES stewards.gate_decisions(id),
    at                timestamptz NOT NULL DEFAULT now(),
    overridden_by     text NOT NULL,
    new_action        text NOT NULL CHECK (new_action IN ('advance', 'revise', 'surface')),
    justification     text NOT NULL
);

CREATE INDEX IF NOT EXISTS gate_overrides_decision ON stewards.gate_overrides (gate_decision_id);
CREATE INDEX IF NOT EXISTS gate_overrides_at       ON stewards.gate_overrides (at);

COMMENT ON TABLE stewards.gate_overrides IS
'Records when a human disagreed with a gate decision. Increments human_overrides on the relevant trust_scores row (D-E3 full weight).';

-- ---------------------------------------------------------------------
-- trust_thresholds — tunable promotion rules
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.trust_thresholds (
    transition          text PRIMARY KEY,
    required_successes  int NOT NULL,
    clean_window        int NOT NULL,
    demote_on_override  boolean NOT NULL DEFAULT true
);

INSERT INTO stewards.trust_thresholds (transition, required_successes, clean_window, demote_on_override) VALUES
    ('trainee_to_journeyman', 5, 5, true),
    ('journeyman_to_master', 15, 15, true)
ON CONFLICT (transition) DO UPDATE SET
    required_successes = EXCLUDED.required_successes,
    clean_window       = EXCLUDED.clean_window,
    demote_on_override = EXCLUDED.demote_on_override;

COMMENT ON TABLE stewards.trust_thresholds IS
'Tunable promotion rules. Default: trainee → journeyman after 5 clean successes; journeyman → master after 15 more clean. Demote one level on any override.';

-- ---------------------------------------------------------------------
-- trust_record_success / failure / override
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.trust_record_success(
    p_agent_family text, p_pipeline_family text, p_model text
) RETURNS text
LANGUAGE plpgsql AS $func$
BEGIN
    INSERT INTO stewards.trust_scores
        (agent_family, pipeline_family, model,
         successful_completions, last_completion_at)
    VALUES
        (p_agent_family, p_pipeline_family, p_model, 1, now())
    ON CONFLICT (agent_family, pipeline_family, model) DO UPDATE SET
        successful_completions = stewards.trust_scores.successful_completions + 1,
        last_completion_at     = now();

    RETURN stewards.evaluate_trust(p_agent_family, p_pipeline_family, p_model);
END;
$func$;

COMMENT ON FUNCTION stewards.trust_record_success(text, text, text) IS
'Phase 5f (E.2): increment successful_completions and re-evaluate. Called when a work_item reaches verified maturity.';

CREATE OR REPLACE FUNCTION stewards.trust_record_failure(
    p_agent_family text, p_pipeline_family text, p_model text
) RETURNS text
LANGUAGE plpgsql AS $func$
BEGIN
    INSERT INTO stewards.trust_scores
        (agent_family, pipeline_family, model, failed_completions)
    VALUES
        (p_agent_family, p_pipeline_family, p_model, 1)
    ON CONFLICT (agent_family, pipeline_family, model) DO UPDATE SET
        failed_completions = stewards.trust_scores.failed_completions + 1;

    RETURN stewards.evaluate_trust(p_agent_family, p_pipeline_family, p_model);
END;
$func$;

COMMENT ON FUNCTION stewards.trust_record_failure(text, text, text) IS
'Phase 5f (E.2): increment failed_completions on quarantine.';

CREATE OR REPLACE FUNCTION stewards.trust_record_override(
    p_agent_family text, p_pipeline_family text, p_model text
) RETURNS text
LANGUAGE plpgsql AS $func$
BEGIN
    INSERT INTO stewards.trust_scores
        (agent_family, pipeline_family, model, human_overrides)
    VALUES
        (p_agent_family, p_pipeline_family, p_model, 1)
    ON CONFLICT (agent_family, pipeline_family, model) DO UPDATE SET
        human_overrides = stewards.trust_scores.human_overrides + 1;

    RETURN stewards.evaluate_trust(p_agent_family, p_pipeline_family, p_model);
END;
$func$;

COMMENT ON FUNCTION stewards.trust_record_override(text, text, text) IS
'Phase 5f (E.2): increment human_overrides and re-evaluate. evaluate_trust auto-demotes on any override per D-E3.';

-- ---------------------------------------------------------------------
-- evaluate_trust — promotion / demotion against thresholds
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.evaluate_trust(
    p_agent_family text, p_pipeline_family text, p_model text
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_score        stewards.trust_scores%ROWTYPE;
    v_new_level    text;
    v_t2j_required int;
    v_j2m_required int;
    v_demote       boolean;
    v_overrides_since_promo int := 0;
BEGIN
    SELECT * INTO v_score
      FROM stewards.trust_scores
     WHERE agent_family = p_agent_family
       AND pipeline_family = p_pipeline_family
       AND model = p_model
       FOR UPDATE;

    IF NOT FOUND THEN
        RETURN 'trainee';
    END IF;

    v_new_level := v_score.trust_level;

    SELECT required_successes INTO v_t2j_required
      FROM stewards.trust_thresholds WHERE transition='trainee_to_journeyman';
    SELECT required_successes INTO v_j2m_required
      FROM stewards.trust_thresholds WHERE transition='journeyman_to_master';
    SELECT demote_on_override INTO v_demote
      FROM stewards.trust_thresholds WHERE transition='trainee_to_journeyman';

    IF v_score.trust_level <> 'trainee' AND v_demote THEN
        SELECT coalesce((metrics->>'overrides')::int, 0)
          INTO v_overrides_since_promo
          FROM stewards.trust_transitions
         WHERE agent_family = p_agent_family
           AND pipeline_family = p_pipeline_family
           AND model = p_model
           AND to_level = v_score.trust_level
         ORDER BY at DESC LIMIT 1;

        v_overrides_since_promo := coalesce(v_overrides_since_promo, 0);

        IF v_score.human_overrides > v_overrides_since_promo THEN
            v_new_level := CASE v_score.trust_level
                WHEN 'master'     THEN 'journeyman'
                WHEN 'journeyman' THEN 'trainee'
                ELSE v_score.trust_level
            END;
        END IF;
    END IF;

    IF v_new_level = v_score.trust_level THEN
        IF v_score.trust_level = 'trainee'
           AND v_score.successful_completions >= v_t2j_required
           AND v_score.human_overrides = 0 THEN
            v_new_level := 'journeyman';
        ELSIF v_score.trust_level = 'journeyman'
           AND v_score.successful_completions >= (v_t2j_required + v_j2m_required)
           AND v_score.human_overrides = coalesce(v_overrides_since_promo, 0) THEN
            v_new_level := 'master';
        END IF;
    END IF;

    IF v_new_level <> v_score.trust_level THEN
        UPDATE stewards.trust_scores
           SET trust_level = v_new_level, last_evaluated_at = now()
         WHERE agent_family = p_agent_family
           AND pipeline_family = p_pipeline_family
           AND model = p_model;

        INSERT INTO stewards.trust_transitions
            (agent_family, pipeline_family, model, from_level, to_level,
             transition_kind, actor, metrics)
        VALUES
            (p_agent_family, p_pipeline_family, p_model,
             v_score.trust_level, v_new_level, 'auto', 'system',
             jsonb_build_object(
                 'successful', v_score.successful_completions,
                 'failed',     v_score.failed_completions,
                 'overrides',  v_score.human_overrides
             ));
    ELSE
        UPDATE stewards.trust_scores
           SET last_evaluated_at = now()
         WHERE agent_family = p_agent_family
           AND pipeline_family = p_pipeline_family
           AND model = p_model;
    END IF;

    RETURN v_new_level;
END;
$func$;

COMMENT ON FUNCTION stewards.evaluate_trust(text, text, text) IS
'Phase 5f (E.2): apply promotion/demotion rules from trust_thresholds. Called by record_* helpers and invokable manually. Returns the new (or unchanged) trust level.';

-- ---------------------------------------------------------------------
-- trust_adjust — manual level change (D-E2 requires justification)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.trust_adjust(
    p_agent_family    text,
    p_pipeline_family text,
    p_model           text,
    p_new_level       text,
    p_actor           text,
    p_justification   text
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_score stewards.trust_scores%ROWTYPE;
BEGIN
    IF p_new_level NOT IN ('trainee','journeyman','master') THEN
        RAISE EXCEPTION 'trust_adjust: invalid level %', p_new_level;
    END IF;
    IF p_justification IS NULL OR length(trim(p_justification)) < 10 THEN
        RAISE EXCEPTION 'trust_adjust: justification required (>= 10 chars) per D-E2';
    END IF;

    SELECT * INTO v_score
      FROM stewards.trust_scores
     WHERE agent_family = p_agent_family
       AND pipeline_family = p_pipeline_family
       AND model = p_model
       FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO stewards.trust_scores
            (agent_family, pipeline_family, model, trust_level)
        VALUES
            (p_agent_family, p_pipeline_family, p_model, p_new_level);

        INSERT INTO stewards.trust_transitions
            (agent_family, pipeline_family, model, from_level, to_level,
             transition_kind, actor, justification, metrics)
        VALUES
            (p_agent_family, p_pipeline_family, p_model,
             'trainee', p_new_level, 'manual', p_actor, p_justification,
             jsonb_build_object('successful', 0, 'failed', 0, 'overrides', 0));

        RETURN p_new_level;
    END IF;

    IF v_score.trust_level = p_new_level THEN
        RETURN p_new_level;
    END IF;

    UPDATE stewards.trust_scores
       SET trust_level = p_new_level, last_evaluated_at = now()
     WHERE agent_family = p_agent_family
       AND pipeline_family = p_pipeline_family
       AND model = p_model;

    INSERT INTO stewards.trust_transitions
        (agent_family, pipeline_family, model, from_level, to_level,
         transition_kind, actor, justification, metrics)
    VALUES
        (p_agent_family, p_pipeline_family, p_model,
         v_score.trust_level, p_new_level, 'manual', p_actor, p_justification,
         jsonb_build_object(
             'successful', v_score.successful_completions,
             'failed',     v_score.failed_completions,
             'overrides',  v_score.human_overrides
         ));

    RETURN p_new_level;
END;
$func$;

COMMENT ON FUNCTION stewards.trust_adjust(text, text, text, text, text, text) IS
'Phase 5f (E.2): manual trust level change with required justification (D-E2). Creates the trust_scores row if missing. Logs to trust_transitions with kind=manual.';

-- ---------------------------------------------------------------------
-- work_item_stage_actor — (agent_family, pipeline_family, model) for the
-- work_item's current stage, honoring model_override. Used by the trust
-- gate + apply_gate_override. Defined BEFORE apply_gate_decision.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.work_item_stage_actor(
    p_work_item_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_wi    stewards.work_items%ROWTYPE;
    v_stage jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RETURN NULL;
    END IF;
    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN jsonb_build_object(
        'agent_family',    v_stage->>'agent_family',
        'pipeline_family', v_wi.pipeline_family,
        'model',           coalesce(v_wi.model_override, v_stage->>'model')
    );
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_stage_actor(uuid) IS
'Phase 5f (E.3): returns {agent_family, pipeline_family, model} for the work_item''s current stage. model honors work_items.model_override. Used by the trust gate + trust counter increment.';

-- ---------------------------------------------------------------------
-- apply_gate_decision — FINAL form: trust gate, no inline sabbath.
-- On action=advance: a trainee (or no trust row) surfaces for human
-- ratification; journeyman/master proceed. On a real advance to verified,
-- records the trust success. The maturity UPDATE to 'verified' fires the
-- on_maturity_verified trigger (08-gates), which dispatches sabbath +
-- materialize — so this function does NOT fire sabbath itself.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_gate_decision(
    p_work_item_id uuid,
    p_decision     jsonb,
    p_work_id      bigint DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_action         text;
    v_reasoning      text;
    v_feedback       text;
    v_new_maturity   text;
    v_produces_mat   text;
    v_maturity_order text[] := ARRAY['raw','researched','planned','specced','executing','verified'];
    v_idx            int;
    v_new_revision   int;
    v_actor          jsonb;
    v_trust_level    text;
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
        -- Trust check (E.3): trainee (or no row) surfaces every advance for
        -- human ratification; journeyman + master proceed.
        v_actor := stewards.work_item_stage_actor(p_work_item_id);
        IF v_actor IS NOT NULL THEN
            SELECT trust_level INTO v_trust_level
              FROM stewards.trust_scores
             WHERE agent_family    = v_actor->>'agent_family'
               AND pipeline_family = v_actor->>'pipeline_family'
               AND model           = v_actor->>'model';

            IF v_trust_level IS NULL OR v_trust_level = 'trainee' THEN
                UPDATE stewards.work_items
                   SET status = 'awaiting_review',
                       updated_at = now()
                 WHERE id = p_work_item_id;
                RETURN v_wi.maturity;  -- maturity unchanged; human must ratify
            END IF;
        END IF;

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

        -- Record successful completion when reaching verified.
        IF v_new_maturity = 'verified' AND v_actor IS NOT NULL THEN
            BEGIN
                PERFORM stewards.trust_record_success(
                    v_actor->>'agent_family',
                    v_actor->>'pipeline_family',
                    v_actor->>'model'
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'trust_record_success raised: %', SQLERRM;
            END;
        END IF;

        -- sabbath_dispatch is NOT fired here — the maturity→verified UPDATE
        -- above fires the work_items_on_maturity_verified trigger (08-gates),
        -- which dispatches sabbath + materialize. Single source of truth.

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
'Phase 5a + 5f (E.3) + H.1.6.2: on action=advance, checks trust_scores for the work_item''s (agent_family, pipeline_family, model). Trainee or no-row surfaces for human ratification. On a real advance to verified, records trust success; sabbath fires from the on_maturity_verified trigger (not inline). Writes a gate_decisions audit row for every call.';

-- ---------------------------------------------------------------------
-- retry_guidance_with_lessons — base retry guidance + last 3 ratified
-- lessons for the (pipeline, stage) cell.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.retry_guidance_with_lessons(
    p_diagnosis       text,
    p_attempt         integer,
    p_pipeline_family text,
    p_stage_name      text
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_base    text;
    v_lessons text;
BEGIN
    v_base := stewards.retry_guidance(p_diagnosis, p_attempt);

    SELECT string_agg('  - ' || content, E'\n')
      INTO v_lessons
      FROM (
        SELECT content
          FROM stewards.lessons_recent_ratified
         WHERE pipeline_family = p_pipeline_family
           AND current_stage   = p_stage_name
         ORDER BY at DESC
         LIMIT 3
      ) recent;

    IF v_lessons IS NOT NULL THEN
        v_base := coalesce(v_base, '') ||
                  E'\n\nRecent lessons from this pipeline + stage:\n' ||
                  v_lessons;
    END IF;

    RETURN v_base;
END;
$func$;

COMMENT ON FUNCTION stewards.retry_guidance_with_lessons(text, integer, text, text) IS
'Phase 5f (E.4): wraps retry_guidance() and appends the last 3 ratified lessons for the (pipeline_family, current_stage) cell from lessons_recent_ratified. Only ratified content influences retry context (D-D3).';

-- ---------------------------------------------------------------------
-- apply_gate_override — atomic human override of a gate decision
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_gate_override(
    p_gate_decision_id bigint,
    p_overridden_by    text,
    p_new_action       text,
    p_justification    text
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_decision     stewards.gate_decisions%ROWTYPE;
    v_actor        jsonb;
    v_new_decision jsonb;
    v_result       text;
BEGIN
    IF p_new_action NOT IN ('advance','revise','surface') THEN
        RAISE EXCEPTION 'apply_gate_override: invalid new_action %', p_new_action;
    END IF;
    IF p_justification IS NULL OR length(trim(p_justification)) < 10 THEN
        RAISE EXCEPTION 'apply_gate_override: justification required (>= 10 chars)';
    END IF;
    IF p_overridden_by IS NULL OR length(trim(p_overridden_by)) = 0 THEN
        RAISE EXCEPTION 'apply_gate_override: overridden_by required';
    END IF;

    SELECT * INTO v_decision FROM stewards.gate_decisions WHERE id = p_gate_decision_id;
    IF v_decision.id IS NULL THEN
        RAISE EXCEPTION 'apply_gate_override: gate_decision % not found', p_gate_decision_id;
    END IF;

    IF v_decision.action = p_new_action THEN
        RAISE EXCEPTION 'apply_gate_override: original action and new_action are both %; this is a no-op', p_new_action;
    END IF;

    INSERT INTO stewards.gate_overrides
        (gate_decision_id, overridden_by, new_action, justification)
    VALUES
        (p_gate_decision_id, p_overridden_by, p_new_action, p_justification);

    v_actor := stewards.work_item_stage_actor(v_decision.work_item_id);
    IF v_actor IS NOT NULL THEN
        BEGIN
            PERFORM stewards.trust_record_override(
                v_actor->>'agent_family',
                v_actor->>'pipeline_family',
                v_actor->>'model'
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'trust_record_override raised: %', SQLERRM;
        END;
    END IF;

    v_new_decision := jsonb_build_object(
        'action',    p_new_action,
        'reasoning', '[human override by ' || p_overridden_by || '] ' ||
                     coalesce(v_decision.reasoning, ''),
        'feedback',  coalesce(v_decision.feedback, '')
    );
    v_result := stewards.apply_gate_decision(
        v_decision.work_item_id, v_new_decision, v_decision.work_id);

    RETURN v_result;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_gate_override(bigint, text, text, text) IS
'Phase 5f (E.5): atomic override of a gate decision. Writes a gate_overrides row, bumps human_overrides on trust_scores (auto-demotes per D-E3), re-applies apply_gate_decision with the new action. Requires justification >= 10 chars.';

-- =====================================================================
-- Done. 11-trust: the trust ladder + counters + evaluate/adjust + the
-- trust-gated apply_gate_decision (single, final definition) + override.
-- =====================================================================
