-- =====================================================================
-- 106 — SCHEDULE VISIBILITY: a pause must be loud; staleness must alarm
-- =====================================================================
-- Found 2026-07-07 (feat/lightening, task #336): every scheduled pipeline
-- had been silent for 14 days and BOTH a UI walk and a steward diagnosis
-- read it as a dead scheduler. It wasn't — the LIVE fire() honors the
-- global kill switch (autonomy_paused, 22) and was returning 0 by design.
-- The deliberate pause was indistinguishable from death: no log line, no
-- UI state, /scheduled showing "(due now)" as if firing were imminent.
--
-- Two fixes here, plus one repo-truth repair:
--   §1 re-authors scheduled_pipelines_fire — porting the LIVE body (the
--      kill-switch clause 22 added, which 18's repo copy predates — the
--      port-from-highest-number trap, again) and adding ONE LOG line per
--      paused tick so pg logs always show WHY nothing fires.
--   §2 schedule_staleness_check(): a schedule past due by more than
--      2x its missed window while autonomy is NOT paused = something is
--      genuinely wrong → a deduped hinge_queue row (kind=schedule-stale)
--      surfacing in needs_attention. A dead scheduler can never again be
--      silent: paused → the log + UI banner say so; unpaused-and-stale →
--      the bell rings.
-- The UI half (banner + /scheduled state + GET /api/autonomy) ships in
-- the same branch (cmd/stewards-ui).
-- =====================================================================

-- ── §1 — fire(), re-authored from LIVE + the paused log line ─────────
CREATE OR REPLACE FUNCTION stewards.scheduled_pipelines_fire()
RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_row             stewards.scheduled_pipelines%ROWTYPE;
    v_child_slug      text;
    v_work_item_id    uuid;
    v_now             timestamptz := now();
    v_missed_cutoff   timestamptz;
    v_dispatched      int := 0;
    v_skipped_missed  int := 0;
    v_next_due        timestamptz;
BEGIN
    -- Global kill switch (22): when paused, fire no scheduled pipelines —
    -- but SAY SO, once per tick, so the pause is never mistaken for death.
    IF stewards.config_get_text('autonomy_paused', 'false') = 'true' THEN
        RAISE LOG 'scheduled_pipelines_fire: autonomy_paused=true — % enabled schedule(s) held',
            (SELECT count(*) FROM stewards.scheduled_pipelines WHERE enabled);
        RETURN 0;
    END IF;

    FOR v_row IN
        SELECT *
          FROM stewards.scheduled_pipelines
         WHERE enabled = true
           AND next_due_at IS NOT NULL
           AND next_due_at <= v_now
         ORDER BY next_due_at
         FOR UPDATE SKIP LOCKED
    LOOP
        -- D-PE4 missed-window: advance without dispatch after a long gap
        -- (prevents a thundering backlog after an unpause — deliberate).
        v_missed_cutoff := v_row.next_due_at + (v_row.missed_window_hours || ' hours')::interval;

        IF v_now > v_missed_cutoff THEN
            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET next_due_at = v_next_due, updated_at = v_now
             WHERE id = v_row.id;
            RAISE NOTICE 'scheduled_pipelines_fire: skipping missed run for % (due % older than % hours); advanced to %',
                v_row.slug, v_row.next_due_at, v_row.missed_window_hours, v_next_due;
            v_skipped_missed := v_skipped_missed + 1;
            CONTINUE;
        END IF;

        v_child_slug := v_row.slug || '--' ||
            to_char(v_row.next_due_at AT TIME ZONE 'UTC', 'YYYY-MM-DD-HH24MI');

        BEGIN
            v_work_item_id := stewards.work_item_create(
                p_pipeline_family => v_row.pipeline_family,
                p_input           => v_row.input_template,
                p_slug            => v_child_slug,
                p_actor           => 'scheduler',
                p_token_budget    => NULL,
                p_intent_id       => v_row.intent_id
            );
            PERFORM stewards.work_item_dispatch_stage(v_work_item_id);

            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET last_dispatched_at = v_now,
                   next_due_at        = v_next_due,
                   updated_at         = v_now
             WHERE id = v_row.id;

            RAISE NOTICE 'scheduled_pipelines_fire: dispatched %/% as work_item %; next_due_at=%',
                v_row.slug, v_child_slug, v_work_item_id, v_next_due;
            v_dispatched := v_dispatched + 1;

        EXCEPTION WHEN OTHERS THEN
            -- Per-row isolation (#330 discipline): one broken schedule must
            -- never stall the rest. Advance it and say so loudly.
            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET next_due_at = v_next_due, updated_at = v_now
             WHERE id = v_row.id;
            RAISE WARNING 'scheduled_pipelines_fire: dispatch FAILED for % (%); advanced next_due_at to %',
                v_row.slug, SQLERRM, v_next_due;
        END;
    END LOOP;

    -- Staleness sweep rides the same tick (no new caller to wire). Honest
    -- limitation: if fire() itself is never called (dead leader/watchman),
    -- this alarm dies with it — that failure mode is visible only by the
    -- ABSENCE of these ticks in pg logs; an external monitor is the deeper
    -- fix if it ever bites.
    BEGIN
        PERFORM stewards.schedule_staleness_check();
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'schedule_staleness_check failed: %', SQLERRM;
    END;

    RETURN v_dispatched;
END;
$func$;

COMMENT ON FUNCTION stewards.scheduled_pipelines_fire() IS
'106 re-authors 18/22: cron dispatcher for scheduled_pipelines. Honors the autonomy_paused kill switch LOUDLY (one LOG line per held tick). Per-row exception isolation. Port from HERE (highest number wins).';

-- ── §2 — the staleness alarm ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.schedule_staleness_check()
RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_row   record;
    v_count int := 0;
BEGIN
    -- Paused = held on purpose; the banner + log own that story. The alarm
    -- exists for the OTHER case: autonomy is on and a schedule still isn't
    -- firing — a genuine fault (locked rows, broken cron_next_after, a
    -- wedged leader) that yesterday's machinery let sit silent for 14 days.
    IF stewards.config_get_text('autonomy_paused', 'false') = 'true' THEN
        RETURN 0;
    END IF;

    FOR v_row IN
        SELECT sp.slug, sp.next_due_at, sp.missed_window_hours
          FROM stewards.scheduled_pipelines sp
         WHERE sp.enabled
           AND sp.next_due_at IS NOT NULL
           AND sp.next_due_at < now() - (GREATEST(sp.missed_window_hours, 1) * 2 || ' hours')::interval
           -- dedup: one open alarm per schedule at a time
           AND NOT EXISTS (
               SELECT 1 FROM stewards.hinge_reviews h
                WHERE h.kind = 'schedule-stale'
                  AND h.subject = sp.slug
                  AND h.status = 'pending')
    LOOP
        PERFORM stewards.hinge_enqueue(
            'schedule-stale',
            v_row.slug,
            jsonb_build_object(
                'next_due_at', v_row.next_due_at,
                'overdue_hours', round(extract(epoch FROM (now() - v_row.next_due_at))/3600),
                'note', 'schedule is past due by more than 2x its missed window while autonomy is ON — the scheduler may be faulted'),
            'schedule_staleness_check');
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$func$;

COMMENT ON FUNCTION stewards.schedule_staleness_check() IS
'106: rings the hinge bell (kind=schedule-stale, deduped per slug) when an enabled schedule sits past due by >2x its missed window with autonomy ON. Paused holds are the banner''s job; this alarm is for genuine scheduler faults, which were silent for 14 days before it existed.';

-- =====================================================================
-- End of 106-schedule-visibility.sql
-- =====================================================================
