-- =====================================================================
-- 28-guard-autoresume.sql — the narrow auto-resume: the guard releases its
-- own brake once a self-clearing breach has demonstrably passed.
-- =====================================================================
-- The watchman guard (23) brakes on a runaway but waits for a human to lift it
-- (D&C 121 — account for emergency force; a human restores). That's right for the
-- breaches that need judgment, but two breach types are SELF-CLEARING: a windowed
-- SPEND cap (the window rolls off) and IN_FLIGHT (work drains). For those, making
-- a human babysit the resume is friction with no safety gain — the danger passes
-- on its own.
--
-- Ratified 2026-06-17 (Michael, "narrow resume"). This adds the release half of
-- the loop, NARROWLY:
--   * only a GUARD-initiated pause auto-resumes — a human reflect_pause stays
--     manual (if you stopped it, only you restart it);
--   * only SELF-CLEARING breaches (spend / in_flight) — a consecutive-failures or
--     proposal-backlog pause stays for a human (it does not heal with time);
--   * only when NO breach is currently active AND the cleared metric is back under
--     reflect_guard_autoresume_pct (default 75%) of its cap — a deadband/hysteresis
--     so it can't flap pause->resume->pause;
--   * every auto-resume is LOGGED to reflect_guard_log (action='auto_resumed') —
--     the watch accounts for RELEASING the brake, not just applying it.
--
-- The pause SOURCE is the load-bearing signal: reflect_pause records 'manual';
-- the guard overrides to 'guard:<breach>' immediately after. Auto-resume lifts
-- only 'guard:<spend|in_flight>' pauses.
--
-- Generic core. requires create_context_search (27). Re-authors (later-file-wins)
-- reflect_pause / reflect_watchman_tick / watchman_scheduler_fire / reflect_status
-- — bodies carried verbatim from 22/23 plus the source marker + the auto-resume call.
-- =====================================================================

-- ── config: the auto-resume switch + the deadband ───────────────────────────
SELECT stewards.config_set('reflect_guard_autoresume_enabled', 'true'::jsonb,
    'When true, the watchman heartbeat auto-RESUMES a guard pause once a self-clearing breach (spend / in_flight) has passed. Narrow: never lifts a human reflect_pause, and never lifts a consecutive-failures or proposal-backlog pause (those stay for a human). false = the guard only ever pauses; a human always resumes (the 23 behavior).');
SELECT stewards.config_set('reflect_guard_autoresume_pct', '75'::jsonb,
    'Hysteresis deadband: auto-resume only once the breached metric is back BELOW this percent of its cap (default 75). The guard trips at 100%; this resumes at <=75% so it cannot flap right at the threshold.');
-- the pause-source marker (default manual; set by reflect_pause / the guard tick).
SELECT stewards.config_set('reflect_pause_source', '"manual"'::jsonb,
    'Who set the current autonomy pause: ''manual'' (a human/agent reflect_pause) or ''guard:<breach>'' (the watchman guard). Read by the narrow auto-resume, which lifts only guard spend/in_flight pauses. ''auto-resumed'' after a self-heal.');

-- =====================================================================
-- reflect_pause — re-authored to record the pause SOURCE as 'manual'. The guard
-- tick overrides to 'guard:<breach>' right after it calls this. Body otherwise
-- verbatim from 22.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_pause(p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM stewards.config_set('autonomy_paused', 'true'::jsonb, NULL);
    PERFORM stewards.config_set('reflect_pause_source', to_jsonb('manual'::text), NULL);
    RETURN 'PAUSED: all scheduled pipelines + the approved-proposal drain are halted'
        || COALESCE(' (' || p_reason || ')', '')
        || '. In-flight work finishes on its own. reflect_resume() to lift.';
END $$;

-- =====================================================================
-- reflect_watchman_tick — re-authored (body verbatim from 23) + it now tags the
-- pause SOURCE 'guard:<breach>' so the narrow auto-resume can recognise its own
-- pauses (reflect_pause set it to 'manual'; this overrides).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_watchman_tick()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_sig    jsonb;
    v_breach text;
BEGIN
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
    PERFORM stewards.config_set('reflect_pause_source', to_jsonb('guard:'||v_breach), NULL);
    INSERT INTO stewards.reflect_guard_log (breach, signals)
    VALUES (v_breach, v_sig);
    RAISE WARNING 'reflect_watchman_tick: AUTO-PAUSED — %', v_breach;
    RETURN v_breach;
END $$;

-- =====================================================================
-- reflect_guard_autoresume_tick — the release half. Lifts ONLY a guard pause
-- whose self-clearing breach (spend / in_flight) has passed the deadband.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_guard_autoresume_tick()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_pct    int;
    v_source text;
    v_sig    jsonb;
    v_kind   text;
    v_cur    numeric;
    v_max    numeric;
    v_detail text;
BEGIN
    IF stewards.config_get_text('reflect_guard_autoresume_enabled','true') <> 'true' THEN RETURN NULL; END IF;
    IF stewards.config_get_text('autonomy_paused','false') <> 'true' THEN RETURN NULL; END IF;

    -- only a GUARD pause is auto-resumable; a human reflect_pause stays manual.
    v_source := stewards.config_get_text('reflect_pause_source','manual');
    IF v_source NOT LIKE 'guard:%' THEN RETURN NULL; END IF;

    -- only SELF-CLEARING breaches (spend / in_flight). Failure-streak / proposal
    -- backlog do not heal with time -> stay for a human.
    IF    v_source LIKE 'guard:autonomous spend%' THEN v_kind := 'spend';
    ELSIF v_source LIKE 'guard:in_flight%'        THEN v_kind := 'in_flight';
    ELSE  RETURN NULL; END IF;

    -- no breach may be active right now (don't resume into a different runaway).
    v_sig := stewards.reflect_guard_signals();
    IF (v_sig->>'would_trip')::boolean THEN RETURN NULL; END IF;

    v_pct := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_autoresume_pct','75'),'')::int, 75);

    IF v_kind = 'spend' THEN
        v_cur := (v_sig->'spend_window'->>'usd')::numeric;
        v_max := (v_sig->'spend_window'->>'cap_usd')::numeric;
        v_detail := format('spend $%s back under %s%% of $%s', v_cur, v_pct, v_max);
    ELSE
        v_cur := (v_sig->'in_flight'->>'value')::numeric;
        v_max := (v_sig->'in_flight'->>'max')::numeric;
        v_detail := format('in_flight %s back under %s%% of %s', v_cur, v_pct, v_max);
    END IF;

    -- deadband: only once the metric is below pct% of its cap.
    IF v_max IS NULL OR v_max = 0 OR v_cur >= v_max * v_pct / 100.0 THEN
        RETURN NULL;
    END IF;

    -- clear: lift the pause + account for releasing the brake (same ledger).
    PERFORM stewards.reflect_resume();
    PERFORM stewards.config_set('reflect_pause_source', to_jsonb('auto-resumed'::text), NULL);
    INSERT INTO stewards.reflect_guard_log (breach, signals, action)
    VALUES ('auto-resume: '||v_detail||' (was '||v_source||')', v_sig, 'auto_resumed');
    RAISE WARNING 'reflect_guard_autoresume_tick: AUTO-RESUMED — %', v_detail;
    RETURN v_detail;
END $$;
COMMENT ON FUNCTION stewards.reflect_guard_autoresume_tick() IS
'reflect-watchman release half: auto-resume a GUARD pause (reflect_pause_source=guard:*) whose SELF-CLEARING breach (spend/in_flight) has passed — no active breach + the metric back under reflect_guard_autoresume_pct%% of cap (hysteresis). Never lifts a human pause or a failure/proposal pause. Logs action=auto_resumed. Called each tick from watchman_scheduler_fire.';

-- =====================================================================
-- watchman_scheduler_fire — re-authored (body verbatim from 23) + the auto-resume
-- tick right after the guard tick, BEFORE schedules fire (so a resumed run fires
-- this same heartbeat). Wrapped so it can never break the heartbeat.
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
    v_autoresume      text;
BEGIN
    -- 23: self-presiding guard FIRST — auto-pause on runaway before any new work.
    BEGIN
        v_guard_breach := stewards.reflect_watchman_tick();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_watchman_tick raised: %', SQLERRM;
    END;

    -- 28: narrow auto-resume — lift a guard spend/in_flight pause once it self-clears.
    BEGIN
        v_autoresume := stewards.reflect_guard_autoresume_tick();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_guard_autoresume_tick raised: %', SQLERRM;
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
-- reflect_status — re-authored (body verbatim from 23) + the pause source, the
-- auto-resume config, and last_guard_trip filtered to real trips (auto_resumed
-- rows no longer masquerade as the last trip) + last_guard_resume.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_status()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'autonomy_paused', stewards.config_get_text('autonomy_paused','false') = 'true',
        'pause_source',    stewards.config_get_text('reflect_pause_source','manual'),
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
        'autoresume', jsonb_build_object(
            'enabled', stewards.config_get_text('reflect_guard_autoresume_enabled','true')='true',
            'pct',     COALESCE(NULLIF(stewards.config_get_text('reflect_guard_autoresume_pct','75'),'')::int, 75)),
        'last_guard_trip', (SELECT jsonb_build_object('at', to_char(tripped_at,'MM-DD HH24:MI'), 'breach', breach)
                              FROM stewards.reflect_guard_log WHERE action='paused_global' ORDER BY tripped_at DESC LIMIT 1),
        'last_guard_resume', (SELECT jsonb_build_object('at', to_char(tripped_at,'MM-DD HH24:MI'), 'breach', breach)
                              FROM stewards.reflect_guard_log WHERE action='auto_resumed' ORDER BY tripped_at DESC LIMIT 1),
        'recent_reflect_runs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('slug',slug,'status',status,'maturity',maturity,'at',to_char(updated_at,'MM-DD HH24:MI')) ORDER BY updated_at DESC), '[]'::jsonb)
                                 FROM (SELECT slug,status,maturity,updated_at FROM stewards.work_items
                                        WHERE pipeline_family='planning' AND actor IN ('scheduler','reflect-steward')
                                        ORDER BY updated_at DESC LIMIT 5) r)
    );
$$;

-- =====================================================================
-- End of 28-guard-autoresume.sql
-- =====================================================================
