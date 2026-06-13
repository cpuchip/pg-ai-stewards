-- =====================================================================
-- 18-scheduler.sql — cron-style scheduled pipeline dispatch
-- =====================================================================
-- Cron scheduling for pipeline dispatches: each scheduled_pipelines row
-- dispatches a fresh work_item of its pipeline_family on a 5-field cron
-- pattern. The cron parser is pure plpgsql (cron_next_after is called once
-- per dispatch, not per tick, so plpgsql is fine). The watchman's 60s
-- leader tick drives it via watchman_scheduler_fire.
--
-- Consolidated (clean-room: the FINAL state). Sources, in author order:
--   §1  pe6 — scheduled_pipelines table + cron_field_values + cron_next_after
--             + the compute-next-due trigger
--   §2  pe7 — scheduled_pipelines_fire (the dispatcher) + watchman_scheduler_fire
--             FINAL (re-authored over 03's, adding the pipelines tick at top)
--
-- requires create_personas (17): no hard dep on personas, but it follows 17
-- in the chain. The real deps — pipelines, intents, work_item_create,
-- work_item_dispatch_stage, the watchman_* functions — are all from earlier
-- batches.
--
-- OVERLAY (not core): pe7's `ai-news-7am` operator seed is a configured job
-- (references a general-research intent + a daily-digest output path) — it
-- lives in the workspace overlay, per the B2 operator-seeds-to-overlay rule.
-- Core ships the machinery, not anyone's specific schedule.
--
-- D-PE3: no hard frequency floor (cost-cap + bucket caps + quarantine are the
-- net). D-PE4: fire one missed run on recovery within missed_window_hours,
-- else advance without firing. D-PE6: standard 5-field cron (ranges/lists/steps).
-- =====================================================================


-- =====================================================================
-- §1 — pe6: scheduled_pipelines schema + the cron engine.
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.scheduled_pipelines (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                 text UNIQUE NOT NULL,
    pipeline_family      text NOT NULL REFERENCES stewards.pipelines(family) ON DELETE RESTRICT,
    intent_id            uuid NOT NULL REFERENCES stewards.intents(id) ON DELETE RESTRICT,
    cron_pattern         text NOT NULL,
    input_template       jsonb NOT NULL,
    enabled              boolean NOT NULL DEFAULT true,
    missed_window_hours  int    NOT NULL DEFAULT 24,
    last_dispatched_at   timestamptz,
    next_due_at          timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    notes                text,
    CONSTRAINT scheduled_pipelines_slug_check CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

CREATE INDEX IF NOT EXISTS scheduled_pipelines_due_idx
    ON stewards.scheduled_pipelines (next_due_at)
    WHERE enabled = true;

COMMENT ON TABLE stewards.scheduled_pipelines IS
'PE-B: cron-style scheduling for pipeline dispatches. Each row dispatches a new work_item of pipeline_family with input_template each time next_due_at is reached. scheduled_pipelines_fire() (called from the 60s watchman tick) scans this table.';

COMMENT ON COLUMN stewards.scheduled_pipelines.cron_pattern IS
'Standard 5-field cron (minute hour day-of-month month day-of-week). Supports literal, *, ranges (1-5), lists (1,3,5), and step values (*/15). Per D-PE6.';

COMMENT ON COLUMN stewards.scheduled_pipelines.missed_window_hours IS
'Per D-PE4: if next_due_at is in the past by less than this many hours, fire one missed run on recovery. Past that, skip the missed runs and advance next_due_at to the next future match. Default 24h.';

COMMENT ON COLUMN stewards.scheduled_pipelines.next_due_at IS
'Materialized by cron_next_after() trigger when cron_pattern is INSERT/UPDATEd, and recomputed by scheduled_pipelines_fire() after each dispatch.';


-- Cron field parser: the set of valid integers for one field. Supports
-- * (every value in [lo,hi]), N (literal), N-M (range), N,M,… (list), and
-- */N or N-M/N (step values).
CREATE OR REPLACE FUNCTION stewards.cron_field_values(
    p_field text,
    p_lo    int,
    p_hi    int
) RETURNS SETOF int
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_part    text;
    v_step    int;
    v_range   text;
    v_lo      int;
    v_hi      int;
    v_dash    int;
    v_n       int;
BEGIN
    FOR v_part IN
        SELECT trim(t) FROM unnest(string_to_array(p_field, ',')) AS t
    LOOP
        -- Step value: <range>/<n>
        IF v_part ~ '/' THEN
            v_step  := split_part(v_part, '/', 2)::int;
            v_range := split_part(v_part, '/', 1);
            IF v_step <= 0 THEN
                RAISE EXCEPTION 'cron_field_values: step must be > 0 in %', v_part;
            END IF;
        ELSE
            v_step  := 1;
            v_range := v_part;
        END IF;

        -- Resolve range bounds
        IF v_range = '*' THEN
            v_lo := p_lo;
            v_hi := p_hi;
        ELSIF v_range ~ '^[0-9]+-[0-9]+$' THEN
            v_dash := position('-' IN v_range);
            v_lo := substring(v_range FROM 1 FOR v_dash - 1)::int;
            v_hi := substring(v_range FROM v_dash + 1)::int;
        ELSIF v_range ~ '^[0-9]+$' THEN
            v_lo := v_range::int;
            v_hi := v_lo;
        ELSE
            RAISE EXCEPTION 'cron_field_values: unparseable part % (in %)', v_part, p_field;
        END IF;

        IF v_lo < p_lo OR v_hi > p_hi OR v_lo > v_hi THEN
            RAISE EXCEPTION 'cron_field_values: out-of-range [%-%] (allowed [%-%]) in %',
                v_lo, v_hi, p_lo, p_hi, p_field;
        END IF;

        -- Emit values
        v_n := v_lo;
        WHILE v_n <= v_hi LOOP
            RETURN NEXT v_n;
            v_n := v_n + v_step;
        END LOOP;
    END LOOP;
END;
$func$;


-- cron_next_after(pattern, after): brute-force minute-by-minute search for the
-- next UTC timestamp matching the 5-field cron pattern, bounded by a 366-day
-- horizon. Standard cron OR-semantics between day-of-month and day-of-week.
CREATE OR REPLACE FUNCTION stewards.cron_next_after(
    p_pattern text,
    p_after   timestamptz
) RETURNS timestamptz
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_parts    text[];
    v_minute   text;
    v_hour     text;
    v_dom      text;
    v_month    text;
    v_dow      text;
    v_t        timestamptz;
    v_horizon  timestamptz;
    v_t_utc    timestamp;
    v_m        int;
    v_h        int;
    v_d        int;
    v_mo       int;
    v_w        int;
    v_dom_unrestricted boolean;
    v_dow_unrestricted boolean;
    v_minute_ok boolean;
    v_hour_ok   boolean;
    v_month_ok  boolean;
    v_dom_ok    boolean;
    v_dow_ok    boolean;
BEGIN
    v_parts := regexp_split_to_array(trim(p_pattern), '\s+');
    IF array_length(v_parts, 1) <> 5 THEN
        RAISE EXCEPTION 'cron_next_after: expected 5-field cron, got %', p_pattern;
    END IF;

    v_minute := v_parts[1];
    v_hour   := v_parts[2];
    v_dom    := v_parts[3];
    v_month  := v_parts[4];
    v_dow    := v_parts[5];

    -- Standard cron semantics: when both dom and dow are restricted
    -- (not *), match if EITHER fires. When one is *, only the other
    -- gates. Implemented by tracking which fields are unrestricted.
    v_dom_unrestricted := (trim(v_dom) = '*');
    v_dow_unrestricted := (trim(v_dow) = '*');

    -- Start at the next minute boundary AFTER p_after (cron fires AT
    -- the minute mark, not in between).
    v_t := date_trunc('minute', p_after) + interval '1 minute';
    v_horizon := p_after + interval '366 days';

    WHILE v_t <= v_horizon LOOP
        v_t_utc := v_t AT TIME ZONE 'UTC';

        v_m  := EXTRACT(MINUTE FROM v_t_utc)::int;
        v_h  := EXTRACT(HOUR   FROM v_t_utc)::int;
        v_d  := EXTRACT(DAY    FROM v_t_utc)::int;
        v_mo := EXTRACT(MONTH  FROM v_t_utc)::int;
        v_w  := EXTRACT(DOW    FROM v_t_utc)::int;

        -- Cheap gates first (minute/hour) to skip-ahead quickly
        v_minute_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_minute, 0, 59) WHERE cron_field_values = v_m
        );
        IF NOT v_minute_ok THEN
            v_t := v_t + interval '1 minute';
            CONTINUE;
        END IF;

        v_hour_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_hour, 0, 23) WHERE cron_field_values = v_h
        );
        IF NOT v_hour_ok THEN
            v_t := v_t + interval '1 minute';
            CONTINUE;
        END IF;

        v_month_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_month, 1, 12) WHERE cron_field_values = v_mo
        );
        IF NOT v_month_ok THEN
            v_t := v_t + interval '1 minute';
            CONTINUE;
        END IF;

        -- Day-of-month + day-of-week OR-semantic
        v_dom_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_dom, 1, 31) WHERE cron_field_values = v_d
        );
        v_dow_ok := EXISTS (
            SELECT 1 FROM stewards.cron_field_values(v_dow, 0, 6) WHERE cron_field_values = v_w
        );

        IF v_dom_unrestricted AND v_dow_unrestricted THEN
            -- Both '*' — pass (already gated by minute/hour/month)
            RETURN v_t;
        ELSIF v_dom_unrestricted THEN
            IF v_dow_ok THEN RETURN v_t; END IF;
        ELSIF v_dow_unrestricted THEN
            IF v_dom_ok THEN RETURN v_t; END IF;
        ELSE
            -- Both restricted — OR semantics
            IF v_dom_ok OR v_dow_ok THEN RETURN v_t; END IF;
        END IF;

        v_t := v_t + interval '1 minute';
    END LOOP;

    -- Nothing matched in 366 days — likely an impossible pattern (e.g.
    -- Feb 30). Return NULL so the caller can flag the row.
    RETURN NULL;
END;
$func$;

COMMENT ON FUNCTION stewards.cron_next_after(text, timestamptz) IS
'PE-B: returns the next timestamp >= p_after at which the standard 5-field cron pattern p_pattern fires. Treats p_pattern in UTC. Implements standard cron OR-semantics between day-of-month and day-of-week. Returns NULL if no match within 366 days.';


-- Trigger: materialize next_due_at on INSERT / cron_pattern change.
CREATE OR REPLACE FUNCTION stewards.scheduled_pipelines_compute_due()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    -- Only recompute when cron_pattern changes (or on INSERT). Avoids
    -- recomputing every time enabled / input_template / notes change.
    IF TG_OP = 'INSERT'
       OR NEW.cron_pattern IS DISTINCT FROM OLD.cron_pattern
    THEN
        NEW.next_due_at := stewards.cron_next_after(NEW.cron_pattern, now());
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS scheduled_pipelines_compute_due_tg ON stewards.scheduled_pipelines;
CREATE TRIGGER scheduled_pipelines_compute_due_tg
    BEFORE INSERT OR UPDATE ON stewards.scheduled_pipelines
    FOR EACH ROW EXECUTE FUNCTION stewards.scheduled_pipelines_compute_due();

COMMENT ON FUNCTION stewards.scheduled_pipelines_compute_due() IS
'PE-B: BEFORE INSERT/UPDATE trigger on scheduled_pipelines. Recomputes next_due_at via cron_next_after() whenever cron_pattern changes. Always bumps updated_at.';


-- =====================================================================
-- §2 — pe7: the dispatcher + the watchman tick integration.
-- =====================================================================

-- scheduled_pipelines_fire(): scan due rows, dispatch via work_item_create +
-- work_item_dispatch_stage, honor D-PE4 fire-one-missed.
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
    -- FOR UPDATE SKIP LOCKED keeps multiple leader candidates / multi-
    -- worker invocations from racing. With one leader today the lock
    -- just prevents accidental re-entry mid-tick.
    FOR v_row IN
        SELECT *
          FROM stewards.scheduled_pipelines
         WHERE enabled = true
           AND next_due_at IS NOT NULL
           AND next_due_at <= v_now
         ORDER BY next_due_at
         FOR UPDATE SKIP LOCKED
    LOOP
        -- D-PE4 missed-window check. If the scheduled time is older
        -- than the window allows, we advance next_due_at without
        -- dispatching. This prevents a flood after a long outage.
        v_missed_cutoff := v_row.next_due_at + (v_row.missed_window_hours || ' hours')::interval;

        IF v_now > v_missed_cutoff THEN
            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET next_due_at = v_next_due,
                   updated_at  = v_now
             WHERE id = v_row.id;
            RAISE NOTICE 'scheduled_pipelines_fire: skipping missed run for % (due % was older than % hours); advanced next_due_at to %',
                v_row.slug, v_row.next_due_at, v_row.missed_window_hours, v_next_due;
            v_skipped_missed := v_skipped_missed + 1;
            CONTINUE;
        END IF;

        -- Compose a child work_item slug. Append YYYY-MM-DD-HHMM in UTC
        -- so daily, sub-daily, and weekly schedules all produce
        -- non-colliding slugs without any ambiguity.
        v_child_slug := v_row.slug || '--' ||
            to_char(v_row.next_due_at AT TIME ZONE 'UTC', 'YYYY-MM-DD-HH24MI');

        -- Dispatch. work_item_create returns the new uuid; we then
        -- dispatch the first stage immediately so the work_queue picks
        -- it up next tick.
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

            -- Advance the schedule
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
            -- Don't kill the whole tick on one bad row. Log + leave
            -- the row alone (its next_due_at stays in the past so we
            -- retry next tick — unless missed-window kicks in).
            RAISE NOTICE 'scheduled_pipelines_fire: dispatch failed for %: % (next tick will retry)',
                v_row.slug, SQLERRM;
        END;
    END LOOP;

    IF v_dispatched > 0 OR v_skipped_missed > 0 THEN
        RAISE NOTICE 'scheduled_pipelines_fire: dispatched=% missed_skipped=%',
            v_dispatched, v_skipped_missed;
    END IF;

    RETURN v_dispatched;
END;
$func$;

COMMENT ON FUNCTION stewards.scheduled_pipelines_fire() IS
'PE-B: scan scheduled_pipelines for due rows, dispatch work_items via work_item_create + work_item_dispatch_stage, honor D-PE4 fire-one-missed (skip missed runs older than missed_window_hours). Returns count dispatched. Called from watchman_scheduler_fire on the 60s leader tick.';


-- watchman_scheduler_fire FINAL: the live watchman body (03) with the
-- scheduled-pipelines tick prepended. We tick scheduled_pipelines FIRST so
-- scheduled jobs fire even when the watchman soak is paused.
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_fire()
RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_reason             text;
    v_cfg                stewards.watchman_config%ROWTYPE;
    v_pass_id            text;
    v_pipelines_fired    int;
BEGIN
    -- PE-B: dispatch any scheduled pipelines that are due. Independent
    -- of watchman pass logic — runs every tick even when the watchman
    -- soak is paused. EXCEPTION wrapper keeps a bad row from killing
    -- the watchman tick.
    BEGIN
        v_pipelines_fired := stewards.scheduled_pipelines_fire();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: scheduled_pipelines_fire raised: %', SQLERRM;
    END;

    -- Original watchman logic below (verbatim).
    v_reason := stewards.watchman_should_fire();
    IF v_reason IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;

    v_pass_id := stewards.watchman_pass_start(
        p_limit        => v_cfg.schedule_pass_limit,
        p_provider     => NULL,
        p_model        => NULL,
        p_agent_family => NULL,
        p_actor        => 'scheduler',
        p_trigger      => v_reason,
        p_token_budget => NULL
    );

    RAISE NOTICE 'watchman scheduler fired (%): pass_id=%', v_reason, v_pass_id;
    RETURN v_pass_id;
END;
$func$;

COMMENT ON FUNCTION stewards.watchman_scheduler_fire() IS
'PE-B final: calls scheduled_pipelines_fire() at the top of each tick (independent of watchman state), then the original watchman pass logic (verbatim from 03-watchman).';


-- =====================================================================
-- End of 18-scheduler.sql
-- =====================================================================
