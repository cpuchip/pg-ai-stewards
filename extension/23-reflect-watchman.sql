-- =====================================================================
-- 23-reflect-watchman.sql — the substrate's self-presiding guard
-- =====================================================================
-- The reflect-steward (22) runs autonomously on a schedule. A human kill switch
-- only helps when a human is watching. This file gives the substrate the watch
-- over its OWN delegated work: a deterministic guard that runs every heartbeat
-- (from watchman_scheduler_fire, the bgworker tick — persistent, no session
-- required), checks the runaway signals, and pulls the global kill switch on a
-- clear breach. It is the presiding covenant made mechanical (D&C 121): it
-- watches what it set in motion, and when it applies emergency force (an
-- auto-pause) it ACCOUNTS for it — a reflect_guard_log row with the breach, the
-- signal snapshot, and the reason — so the next human/agent check-in sees
-- exactly why the watch stopped the work. It never auto-resumes; lifting a trip
-- is a human/agent act (reflect_resume), after they read the accounting.
--
-- Deterministic by design: no LLM, no cost. The guard is a cheap read +
-- a config flip. Conservative thresholds (precision over recall): a false
-- auto-pause merely halts new autonomous work (reversible in one verb); a missed
-- runaway burns money. Every threshold is config-tunable.
--
-- Generic core: thresholds + machinery only. requires create_reflect_steward
-- (22) for the kill switch + the watchman_scheduler_fire it re-authors.
-- =====================================================================

-- ── config: the guard's master switch + thresholds ──────────────────────────
SELECT stewards.config_set('reflect_guard_enabled', 'true'::jsonb,
    'Master switch for the self-presiding watchman guard. true = each heartbeat the guard checks runaway signals and auto-pauses (autonomy_paused) on a breach. false = the guard observes nothing and never acts (reflect_guard_signals still reports for inspection).');
SELECT stewards.config_set('reflect_guard_max_in_flight', '8'::jsonb,
    'Guard trips when autonomous work (actor scheduler/reflect-steward) in_progress+awaiting_review reaches this. The drain caps reflect proposals at reflect_max_concurrent; this catches the whole autonomous surface (schedules + spawned children) piling up.');
SELECT stewards.config_set('reflect_guard_max_proposals_pending', '50'::jsonb,
    'Guard trips when un-triaged agent_planning proposals reach this — the steward is proposing far faster than anyone approves; pause the source so it stops spinning out more (the queue is kept for review).');
SELECT stewards.config_set('reflect_guard_max_consecutive_failures', '5'::jsonb,
    'Guard trips when the most-recent autonomous runs are this many consecutive failures — the loop is broken; stop burning attempts until a human looks.');
SELECT stewards.config_set('reflect_guard_spend_window_hours', '24'::jsonb,
    'The rolling window (hours) over which the guard sums autonomous spend.');
SELECT stewards.config_set('reflect_guard_spend_cap_micro', '10000000'::jsonb,
    'Guard trips when autonomous spend (cost_events on scheduler/reflect-steward work_items) in the window reaches this many micro-dollars. Default 10000000 = $10. Distinct from provider_spend_caps (per-provider, enforced at dispatch); this is the autonomous-runaway brake.');

-- ── the accounting ledger: every emergency force the guard applies ───────────
CREATE TABLE IF NOT EXISTS stewards.reflect_guard_log (
    id          bigserial PRIMARY KEY,
    tripped_at  timestamptz NOT NULL DEFAULT now(),
    breach      text NOT NULL,     -- which threshold broke + the reason handed to reflect_pause
    signals     jsonb NOT NULL,    -- the full signal snapshot at trip time (the evidence)
    action      text NOT NULL DEFAULT 'paused_global'
);
COMMENT ON TABLE stewards.reflect_guard_log IS
'reflect-watchman accounting: one row per auto-pause the guard applied — the breach, the evidence (signal snapshot), and the action. D&C 121 "account for emergency force": the watch leaves a full record of every time it stopped the work, for the human/agent who lifts the pause.';

-- =====================================================================
-- reflect_guard_signals() — the current runaway signals vs the thresholds.
-- Read-only (no action). The tick uses the same logic to decide; reflect_status
-- folds it in; a human reads it to see how close the watch is to tripping.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_guard_signals()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_enabled    boolean := stewards.config_get_text('reflect_guard_enabled','true') = 'true';
    v_max_inf    int     := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_max_in_flight','8'),'')::int, 8);
    v_max_prop   int     := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_max_proposals_pending','50'),'')::int, 50);
    v_max_fail   int     := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_max_consecutive_failures','5'),'')::int, 5);
    v_win_hours  int     := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_spend_window_hours','24'),'')::int, 24);
    v_cap_micro  bigint  := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_spend_cap_micro','10000000'),'')::bigint, 10000000);
    v_in_flight  int;
    v_proposals  int;
    v_consec     int;
    v_spend      bigint;
    v_breach     text := NULL;
BEGIN
    -- in flight: the whole autonomous surface (not just the drain's accounting).
    SELECT count(*) INTO v_in_flight FROM stewards.work_items
     WHERE actor IN ('scheduler','reflect-steward','subagent','persona-request')
       AND status IN ('in_progress','awaiting_review');

    -- un-triaged proposals (mirrors reflect_status.proposals_pending).
    SELECT count(*) INTO v_proposals FROM stewards.work_items w
     WHERE w.origin='agent_planning' AND w.status='pending'
       AND NOT EXISTS (SELECT 1 FROM stewards.reflect_approvals a WHERE a.work_item_id=w.id);

    -- leading consecutive failures among recent autonomous terminal runs.
    SELECT COALESCE(
        (SELECT min(rn) - 1
           FROM (SELECT status, row_number() OVER (ORDER BY updated_at DESC) rn
                   FROM stewards.work_items
                  WHERE actor IN ('scheduler','reflect-steward','subagent','persona-request')
                    AND status IN ('completed','failed','cancelled')) t
          WHERE status <> 'failed'),
        (SELECT count(*) FROM stewards.work_items
           WHERE actor IN ('scheduler','reflect-steward','subagent','persona-request')
             AND status IN ('completed','failed','cancelled'))
    ) INTO v_consec;

    -- autonomous spend in the window (cost_events on autonomous work_items).
    SELECT COALESCE(sum(ce.micro_dollars),0) INTO v_spend
      FROM stewards.cost_events ce
      JOIN stewards.work_items w ON w.id = ce.work_item_id
     WHERE ce.at > now() - make_interval(hours => greatest(v_win_hours,1))
       AND w.actor IN ('scheduler','reflect-steward','subagent','persona-request');

    -- first breach wins (the reason handed to reflect_pause).
    IF v_in_flight >= v_max_inf THEN
        v_breach := format('in_flight %s >= %s (autonomous work piling up)', v_in_flight, v_max_inf);
    ELSIF v_consec >= v_max_fail THEN
        v_breach := format('%s consecutive autonomous failures >= %s (loop broken)', v_consec, v_max_fail);
    ELSIF v_spend >= v_cap_micro THEN
        v_breach := format('autonomous spend $%s in %sh >= cap $%s',
            round(v_spend/1000000.0, 2), v_win_hours, round(v_cap_micro/1000000.0, 2));
    ELSIF v_proposals >= v_max_prop THEN
        v_breach := format('%s un-triaged proposals >= %s (proposing faster than triage)', v_proposals, v_max_prop);
    END IF;

    RETURN jsonb_build_object(
        'enabled', v_enabled,
        'checked_at', to_char(now(),'MM-DD HH24:MI'),
        'in_flight',            jsonb_build_object('value', v_in_flight, 'max', v_max_inf),
        'consecutive_failures', jsonb_build_object('value', v_consec,    'max', v_max_fail),
        'spend_window',         jsonb_build_object('usd', round(v_spend/1000000.0, 2), 'cap_usd', round(v_cap_micro/1000000.0, 2), 'hours', v_win_hours),
        'proposals_pending',    jsonb_build_object('value', v_proposals, 'max', v_max_prop),
        'would_trip', v_breach IS NOT NULL,
        'breach', v_breach
    );
END $$;
COMMENT ON FUNCTION stewards.reflect_guard_signals() IS
'reflect-watchman: the current runaway signals (in_flight, consecutive failures, windowed autonomous spend, un-triaged proposals) vs their thresholds, plus would_trip/breach. Read-only — the same logic the tick acts on. Surfaced in reflect_status.';

-- =====================================================================
-- reflect_watchman_tick() — the heartbeat guard. Acts on a breach.
-- Called each tick from watchman_scheduler_fire (before schedules fire + the
-- drain, so a trip stops this tick's new work too). Idempotent: a no-op when
-- the guard is disabled or autonomy is already paused (the guard only governs a
-- RUNNING system, and never re-trips a stopped one — no log spam).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_watchman_tick()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_sig    jsonb;
    v_breach text;
BEGIN
    -- Guard disabled, or already paused → nothing to govern.
    IF stewards.config_get_text('reflect_guard_enabled','true') <> 'true' THEN
        RETURN NULL;
    END IF;
    IF stewards.config_get_text('autonomy_paused','false') = 'true' THEN
        RETURN NULL;
    END IF;

    v_sig    := stewards.reflect_guard_signals();
    v_breach := v_sig->>'breach';
    IF v_breach IS NULL THEN
        RETURN NULL;   -- nominal
    END IF;

    -- Breach: apply emergency force (global pause) and account for it.
    PERFORM stewards.reflect_pause('watchman guard: ' || v_breach);
    INSERT INTO stewards.reflect_guard_log (breach, signals)
    VALUES (v_breach, v_sig);
    RAISE WARNING 'reflect_watchman_tick: AUTO-PAUSED — %', v_breach;
    RETURN v_breach;
END $$;
COMMENT ON FUNCTION stewards.reflect_watchman_tick() IS
'reflect-watchman heartbeat: if the guard is enabled and autonomy running, check reflect_guard_signals and, on a breach, auto-pause (reflect_pause) + log the trip to reflect_guard_log. Never auto-resumes. Called each tick from watchman_scheduler_fire.';

-- reflect_guard_trips — the recent accounting (what the watch stopped, and why).
CREATE OR REPLACE FUNCTION stewards.reflect_guard_trips(p_limit int DEFAULT 10)
RETURNS TABLE(tripped_at timestamptz, breach text, action text)
LANGUAGE sql STABLE AS $$
    SELECT tripped_at, breach, action FROM stewards.reflect_guard_log
     ORDER BY tripped_at DESC LIMIT greatest(p_limit, 1);
$$;

-- =====================================================================
-- reflect_status — re-authored to surface the guard (later-file-wins). Body is
-- 22's verbatim plus the 'guard' key, so a single glance shows whether the watch
-- is near tripping and the last trip if any.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_status()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'autonomy_paused', stewards.config_get_text('autonomy_paused','false') = 'true',
        'max_concurrent',  stewards.config_get_text('reflect_max_concurrent','2'),
        'in_flight', (SELECT count(*) FROM stewards.reflect_approvals a JOIN stewards.work_items w ON w.id=a.work_item_id
                       WHERE a.dispatched_at IS NOT NULL AND w.status NOT IN ('completed','failed','cancelled')),
        'approved_waiting', (SELECT count(*) FROM stewards.reflect_approvals a JOIN stewards.work_items w ON w.id=a.work_item_id
                              WHERE a.dispatched_at IS NULL AND w.status='pending'),
        'proposals_pending', (SELECT count(*) FROM stewards.work_items w
                               WHERE w.origin='agent_planning' AND w.status='pending'
                                 AND NOT EXISTS (SELECT 1 FROM stewards.reflect_approvals a WHERE a.work_item_id=w.id)),
        'intents_paused', (SELECT COALESCE(jsonb_agg(intent_slug), '[]'::jsonb) FROM stewards.reflect_intent_paused),
        'guard', stewards.reflect_guard_signals(),
        'last_guard_trip', (SELECT jsonb_build_object('at', to_char(tripped_at,'MM-DD HH24:MI'), 'breach', breach)
                              FROM stewards.reflect_guard_log ORDER BY tripped_at DESC LIMIT 1),
        'recent_reflect_runs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('slug',slug,'status',status,'maturity',maturity,'at',to_char(updated_at,'MM-DD HH24:MI')) ORDER BY updated_at DESC), '[]'::jsonb)
                                 FROM (SELECT slug,status,maturity,updated_at FROM stewards.work_items
                                        WHERE pipeline_family='planning' AND actor IN ('scheduler','reflect-steward','subagent','persona-request')
                                        ORDER BY updated_at DESC LIMIT 5) r)
    );
$$;

-- =====================================================================
-- watchman_scheduler_fire — re-authored (later-file-wins) to run the guard tick
-- FIRST each heartbeat. Body is 22's verbatim plus the leading guard call: if it
-- trips, the pause it sets makes scheduled_pipelines_fire + reflect_drain_approved
-- no-ops this same tick (both already gate on autonomy_paused). The guard call is
-- wrapped so a guard error can never break the heartbeat.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_fire()
RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_reason          text;
    v_cfg             stewards.watchman_config%ROWTYPE;
    v_pass_id         text;
    v_pipelines_fired int;
    v_drained         int;
    v_guard_breach    text;
BEGIN
    -- 23: self-presiding guard FIRST — auto-pause on runaway before any new work.
    BEGIN
        v_guard_breach := stewards.reflect_watchman_tick();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_watchman_tick raised: %', SQLERRM;
    END;

    BEGIN
        v_pipelines_fired := stewards.scheduled_pipelines_fire();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: scheduled_pipelines_fire raised: %', SQLERRM;
    END;

    -- 22: drain the reflect-steward approval queue (capacity-gated, pause-aware).
    BEGIN
        v_drained := stewards.reflect_drain_approved();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_drain_approved raised: %', SQLERRM;
    END;

    v_reason := stewards.watchman_should_fire();
    IF v_reason IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;

    v_pass_id := stewards.watchman_pass_start(
        p_limit => v_cfg.schedule_pass_limit, p_provider => NULL, p_model => NULL,
        p_agent_family => NULL, p_actor => 'scheduler', p_trigger => v_reason, p_token_budget => NULL);

    RAISE NOTICE 'watchman scheduler fired (%): pass_id=%', v_reason, v_pass_id;
    RETURN v_pass_id;
END;
$func$;

-- =====================================================================
-- End of 23-reflect-watchman.sql
-- =====================================================================
