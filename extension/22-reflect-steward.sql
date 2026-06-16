-- =====================================================================
-- 22-reflect-steward.sql — the reflect-steward operator surface
-- =====================================================================
-- The reflect-steward is the `planning` pipeline pointed at an intent on a
-- schedule: it senses the intent's knowledge pool, brainstorms, and PROPOSES
-- work (parked agent_planning work_items). This file adds the control surface a
-- human needs to run that safely:
--
--   • a kill switch — global (autonomy_paused) AND per-intent (decommission a
--     runaway intent while the rest keep running);
--   • an approval queue with a CAPACITY-GATED drain — approving a proposal does
--     NOT dispatch it; the drain dispatches approved proposals as capacity
--     allows, so a big proposal batch never floods the workers;
--   • check-in verbs (status / proposals / approve / decline / steer) the human
--     (or the CLI/skill that drives on their behalf) calls.
--
-- The schedule + drain are gated by autonomy_paused, so one command stops all
-- new autonomous work. (In-flight stages still finish — to halt those too, use
-- the emergency-stop bleed-stoppers; autonomy_paused governs the SOURCE.)
--
-- Generic core: the machinery is intent-agnostic. The named intents (and their
-- scheduled_pipelines rows) are operator data — seed those in an overlay.
-- requires create_models (19) for scheduled_pipelines; create_subagents for the
-- planning pipeline it drives.
-- =====================================================================

-- ── config: the global kill switch + the drain's concurrency cap ─────────────
SELECT stewards.config_set('autonomy_paused', 'false'::jsonb,
    'Global reflect-steward kill switch. true = the scheduler dispatches no new scheduled pipelines and the approved-proposal drain dispatches nothing. In-flight work still finishes (use the emergency-stop brakes for that).');
SELECT stewards.config_set('reflect_max_concurrent', '2'::jsonb,
    'Capacity gate: the most reflect-approved proposals the drain will have in flight at once. Approved proposals beyond this wait in the queue until running ones finish.');

-- ── approval queue: a proposal the human said yes to (drain dispatches it) ────
CREATE TABLE IF NOT EXISTS stewards.reflect_approvals (
    work_item_id  uuid PRIMARY KEY REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    approved_by   text NOT NULL DEFAULT 'human',
    approved_at   timestamptz NOT NULL DEFAULT now(),
    dispatched_at timestamptz   -- set by the drain when it actually launches it
);
COMMENT ON TABLE stewards.reflect_approvals IS
'reflect-steward: proposals the human approved. dispatched_at NULL = waiting for capacity; the capacity-gated drain (reflect_drain_approved) launches them as running work drops below reflect_max_concurrent.';

-- ── per-intent pause: decommission a runaway intent without a global stop ────
CREATE TABLE IF NOT EXISTS stewards.reflect_intent_paused (
    intent_slug text PRIMARY KEY,
    paused_at   timestamptz NOT NULL DEFAULT now(),
    reason      text
);
COMMENT ON TABLE stewards.reflect_intent_paused IS
'reflect-steward per-intent kill switch: an intent here is skipped by the drain (its approved proposals do not dispatch). reflect_pause_intent also disables its scheduled_pipelines rows so no new cycles fire.';

-- ── steering: a human note that shapes the intent's next reflect cycle ───────
CREATE TABLE IF NOT EXISTS stewards.reflect_steering (
    id          bigserial PRIMARY KEY,
    intent_slug text NOT NULL,
    note        text NOT NULL,
    created_by  text NOT NULL DEFAULT 'human',
    created_at  timestamptz NOT NULL DEFAULT now(),
    applied_at  timestamptz   -- set when a reflect cycle has folded it in
);
CREATE INDEX IF NOT EXISTS reflect_steering_unapplied_idx
    ON stewards.reflect_steering (intent_slug, created_at) WHERE applied_at IS NULL;
COMMENT ON TABLE stewards.reflect_steering IS
'reflect-steward: human steering notes per intent. The reflect launch can fold unapplied notes into the binding question so a check-in suggestion shapes the next cycle.';

-- =====================================================================
-- Kill switch — global
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_pause(p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM stewards.config_set('autonomy_paused', 'true'::jsonb, NULL);
    RETURN 'PAUSED: all scheduled pipelines + the approved-proposal drain are halted'
        || COALESCE(' (' || p_reason || ')', '')
        || '. In-flight work finishes on its own. reflect_resume() to lift.';
END $$;

CREATE OR REPLACE FUNCTION stewards.reflect_resume()
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM stewards.config_set('autonomy_paused', 'false'::jsonb, NULL);
    RETURN 'RESUMED: scheduled pipelines + drain will run on the next tick.';
END $$;

-- =====================================================================
-- Kill switch — per-intent (decommission a runaway intent)
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_pause_intent(p_intent_slug text, p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_intent uuid; v_disabled int;
BEGIN
    SELECT id INTO v_intent FROM stewards.intents WHERE slug = p_intent_slug;
    IF v_intent IS NULL THEN RETURN 'no such intent: ' || p_intent_slug; END IF;

    INSERT INTO stewards.reflect_intent_paused (intent_slug, reason)
    VALUES (p_intent_slug, p_reason)
    ON CONFLICT (intent_slug) DO UPDATE SET paused_at = now(), reason = EXCLUDED.reason;

    UPDATE stewards.scheduled_pipelines SET enabled = false, updated_at = now()
     WHERE intent_id = v_intent AND enabled = true;
    GET DIAGNOSTICS v_disabled = ROW_COUNT;

    RETURN format('intent %s PAUSED: %s schedule(s) disabled; its approved proposals will not dispatch. reflect_resume_intent to lift.',
        p_intent_slug, v_disabled);
END $$;

CREATE OR REPLACE FUNCTION stewards.reflect_resume_intent(p_intent_slug text)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_intent uuid; v_enabled int;
BEGIN
    SELECT id INTO v_intent FROM stewards.intents WHERE slug = p_intent_slug;
    IF v_intent IS NULL THEN RETURN 'no such intent: ' || p_intent_slug; END IF;

    DELETE FROM stewards.reflect_intent_paused WHERE intent_slug = p_intent_slug;
    UPDATE stewards.scheduled_pipelines SET enabled = true, updated_at = now()
     WHERE intent_id = v_intent AND enabled = false;
    GET DIAGNOSTICS v_enabled = ROW_COUNT;

    RETURN format('intent %s RESUMED: %s schedule(s) re-enabled.', p_intent_slug, v_enabled);
END $$;

-- =====================================================================
-- The capacity-gated drain — dispatch approved proposals as capacity allows.
-- Called every tick from watchman_scheduler_fire. Honors the global pause and
-- per-intent pause; never exceeds reflect_max_concurrent in flight.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_drain_approved()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_cap       int;
    v_in_flight int;
    v_row       record;
    v_launched  int := 0;
BEGIN
    -- Global kill switch.
    IF stewards.config_get_text('autonomy_paused', 'false') = 'true' THEN
        RETURN 0;
    END IF;

    v_cap := COALESCE(NULLIF(stewards.config_get_text('reflect_max_concurrent', '2'), '')::int, 2);

    -- In flight = approved + dispatched + not yet terminal.
    SELECT count(*) INTO v_in_flight
      FROM stewards.reflect_approvals a
      JOIN stewards.work_items w ON w.id = a.work_item_id
     WHERE a.dispatched_at IS NOT NULL
       AND w.status NOT IN ('completed', 'failed', 'cancelled');

    -- Launch approved-but-undispatched proposals, oldest first, until the cap.
    FOR v_row IN
        SELECT a.work_item_id, w.intent_id, w.slug
          FROM stewards.reflect_approvals a
          JOIN stewards.work_items w ON w.id = a.work_item_id
         WHERE a.dispatched_at IS NULL
           AND w.status = 'pending'
           -- skip paused intents
           AND NOT EXISTS (
               SELECT 1 FROM stewards.reflect_intent_paused p
                JOIN stewards.intents i ON i.slug = p.intent_slug
               WHERE i.id = w.intent_id)
         ORDER BY a.approved_at
    LOOP
        EXIT WHEN v_in_flight >= v_cap;
        BEGIN
            PERFORM stewards.work_item_dispatch_stage(v_row.work_item_id);
            UPDATE stewards.reflect_approvals SET dispatched_at = now()
             WHERE work_item_id = v_row.work_item_id;
            v_in_flight := v_in_flight + 1;
            v_launched  := v_launched + 1;
            RAISE NOTICE 'reflect_drain_approved: launched % (%/% in flight)', v_row.slug, v_in_flight, v_cap;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'reflect_drain_approved: dispatch failed for %: %', v_row.slug, SQLERRM;
        END;
    END LOOP;

    RETURN v_launched;
END $$;
COMMENT ON FUNCTION stewards.reflect_drain_approved() IS
'reflect-steward: dispatch approved-but-undispatched proposals oldest-first up to reflect_max_concurrent in flight, skipping when autonomy_paused or the proposal''s intent is paused. Called each tick from watchman_scheduler_fire.';

-- =====================================================================
-- Check-in verbs (the human / the CLI-skill that drives for them)
-- =====================================================================

-- reflect_status — one glance: paused?, capacity, queue depths, recent runs.
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
        'recent_reflect_runs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('slug',slug,'status',status,'maturity',maturity,'at',to_char(updated_at,'MM-DD HH24:MI')) ORDER BY updated_at DESC), '[]'::jsonb)
                                 FROM (SELECT slug,status,maturity,updated_at FROM stewards.work_items
                                        WHERE pipeline_family='planning' AND actor IN ('scheduler','reflect-steward')
                                        ORDER BY updated_at DESC LIMIT 5) r)
    );
$$;

-- reflect_proposals — the parked queue awaiting your call.
CREATE OR REPLACE FUNCTION stewards.reflect_proposals()
RETURNS TABLE(slug text, intent text, pipeline text, status text, approved boolean, binding_question text)
LANGUAGE sql STABLE AS $$
    SELECT w.slug, i.slug, w.pipeline_family, w.status,
           EXISTS(SELECT 1 FROM stewards.reflect_approvals a WHERE a.work_item_id=w.id) AS approved,
           w.input->>'binding_question'
      FROM stewards.work_items w
      LEFT JOIN stewards.intents i ON i.id = w.intent_id
     WHERE w.origin='agent_planning' AND w.status='pending'
     ORDER BY i.slug, w.slug;
$$;

-- reflect_approve — say yes. Does NOT dispatch; the drain launches it as capacity allows.
CREATE OR REPLACE FUNCTION stewards.reflect_approve(p_slug text, p_by text DEFAULT 'human')
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_id uuid; v_status text;
BEGIN
    SELECT id, status INTO v_id, v_status FROM stewards.work_items
     WHERE slug = p_slug AND origin = 'agent_planning';
    IF v_id IS NULL THEN RETURN 'no proposal with slug ' || p_slug; END IF;
    IF v_status <> 'pending' THEN
        RETURN format('proposal %s is %s, not pending — nothing to approve', p_slug, v_status);
    END IF;
    INSERT INTO stewards.reflect_approvals (work_item_id, approved_by)
    VALUES (v_id, p_by) ON CONFLICT (work_item_id) DO NOTHING;
    RETURN format('approved %s — queued; the drain dispatches it when in-flight work drops below the cap.', p_slug);
END $$;

-- reflect_decline — say no (cancel the proposal).
CREATE OR REPLACE FUNCTION stewards.reflect_decline(p_slug text, p_why text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
    SELECT id INTO v_id FROM stewards.work_items
     WHERE slug = p_slug AND origin = 'agent_planning';
    IF v_id IS NULL THEN RETURN 'no proposal with slug ' || p_slug; END IF;
    PERFORM stewards.work_item_cancel(v_id, 'declined' || COALESCE(': ' || p_why, ''));
    DELETE FROM stewards.reflect_approvals WHERE work_item_id = v_id;  -- in case it was approved then reversed
    RETURN format('declined %s%s', p_slug, COALESCE(' (' || p_why || ')', ''));
END $$;

-- reflect_steer — drop a note that shapes the intent's next cycle.
CREATE OR REPLACE FUNCTION stewards.reflect_steer(p_intent_slug text, p_note text, p_by text DEFAULT 'human')
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM stewards.intents WHERE slug = p_intent_slug) THEN
        RETURN 'no such intent: ' || p_intent_slug;
    END IF;
    IF p_note IS NULL OR length(btrim(p_note)) = 0 THEN RETURN 'note required'; END IF;
    INSERT INTO stewards.reflect_steering (intent_slug, note, created_by)
    VALUES (p_intent_slug, btrim(p_note), p_by);
    RETURN format('steering noted for %s — folds into its next reflect cycle.', p_intent_slug);
END $$;

-- =====================================================================
-- Scheduler integration: gate firing on the global kill switch, and drain the
-- approval queue each tick. Re-authors the two 18-scheduler functions to their
-- final form (later-file-wins; the bodies are 18's verbatim plus these hooks).
-- =====================================================================

-- scheduled_pipelines_fire: bail at the top when autonomy is paused.
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
    -- Global kill switch (22): when paused, fire no scheduled pipelines.
    IF stewards.config_get_text('autonomy_paused', 'false') = 'true' THEN
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
               SET last_dispatched_at = v_now, next_due_at = v_next_due, updated_at = v_now
             WHERE id = v_row.id;

            RAISE NOTICE 'scheduled_pipelines_fire: dispatched %/% as work_item %; next_due_at=%',
                v_row.slug, v_child_slug, v_work_item_id, v_next_due;
            v_dispatched := v_dispatched + 1;

        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'scheduled_pipelines_fire: dispatch failed for %: % (next tick will retry)',
                v_row.slug, SQLERRM;
        END;
    END LOOP;

    IF v_dispatched > 0 OR v_skipped_missed > 0 THEN
        RAISE NOTICE 'scheduled_pipelines_fire: dispatched=% missed_skipped=%', v_dispatched, v_skipped_missed;
    END IF;

    RETURN v_dispatched;
END;
$func$;

-- watchman_scheduler_fire: after firing schedules, drain the approval queue.
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_fire()
RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_reason          text;
    v_cfg             stewards.watchman_config%ROWTYPE;
    v_pass_id         text;
    v_pipelines_fired int;
    v_drained         int;
BEGIN
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
-- The intent knowledge pool's dedup/provenance layer — "don't re-scrub".
--
-- The knowledge itself lives in stewards.docs (FTS + vector, global-readable so
-- gatherers can do meta-studies across intents). This ledger is the missing
-- piece: a per-intent record of which external sources/queries have been
-- gathered, when, and the one-line finding + the doc it landed in. The gatherer
-- checks intent_sources_recent BEFORE crawling (skip what's fresh) and calls
-- intent_source_record AFTER — so each cycle builds the pool UP instead of
-- re-scrubbing the same sites. Time-aware: a source older than the freshness
-- window is fair to re-gather (new reviews appear). This is the gatherer's half
-- of the Zion pool; the persona reads the docs side.
-- =====================================================================
CREATE TABLE IF NOT EXISTS stewards.intent_source_ledger (
    intent_slug  text NOT NULL,
    source_key   text NOT NULL,   -- normalized source/query id: a URL, "bbb-complaints", "query:product billing"
    gathered_at  timestamptz NOT NULL DEFAULT now(),
    finding      text,            -- one-line gist (so a skip still informs the plan)
    doc_slug     text,            -- the doc the finding was published into
    gather_count int NOT NULL DEFAULT 1,
    PRIMARY KEY (intent_slug, source_key)
);
COMMENT ON TABLE stewards.intent_source_ledger IS
'reflect-steward dedup/provenance: which external sources/queries an intent has gathered, when, the one-line finding, and the doc it landed in. Gatherer checks intent_sources_recent before crawling and intent_source_record after — builds the knowledge pool up instead of re-scrubbing.';

-- helper: derive the caller's intent slug from the injected _session_id.
CREATE OR REPLACE FUNCTION stewards.session_intent_slug(p_session_id text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT i.slug FROM stewards.work_items w JOIN stewards.intents i ON i.id = w.intent_id
     WHERE p_session_id = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION stewards.intent_sources_recent(p_intent_slug text, p_window_days int DEFAULT 10)
RETURNS TABLE(source_key text, gathered_at timestamptz, finding text, doc_slug text)
LANGUAGE sql STABLE AS $$
    SELECT source_key, gathered_at, finding, doc_slug
      FROM stewards.intent_source_ledger
     WHERE intent_slug = p_intent_slug
       AND gathered_at > now() - make_interval(days => greatest(p_window_days, 0))
     ORDER BY gathered_at DESC;
$$;

-- tool: "what have we gathered recently for my intent?" (skip those — they're fresh)
CREATE OR REPLACE FUNCTION stewards.intent_sources_recent_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_intent text := COALESCE(stewards.session_intent_slug(p_args->>'_session_id'), p_args->>'intent');
    v_window int  := COALESCE(NULLIF(p_args->>'window_days','')::int, 10);
    v_rows   jsonb;
BEGIN
    IF v_intent IS NULL THEN
        RETURN '{"error":"could not resolve the intent for this session; pass intent explicitly"}';
    END IF;
    SELECT jsonb_agg(jsonb_build_object('source', source_key, 'gathered_at', gathered_at,
                                        'finding', finding, 'doc', doc_slug))
      INTO v_rows FROM stewards.intent_sources_recent(v_intent, v_window);
    RETURN jsonb_build_object(
        'intent', v_intent, 'window_days', v_window,
        'already_gathered_recently', COALESCE(v_rows, '[]'::jsonb),
        'note', 'Skip sources/queries listed here — they are fresh. Their findings are already in the docs pool (doc_search). Gather only NEW sources, and call intent_source_record after each.'
    )::text;
END $FN$;

-- tool: "I gathered this source; record it" (after publishing the finding)
CREATE OR REPLACE FUNCTION stewards.intent_source_record_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_intent text := COALESCE(stewards.session_intent_slug(p_args->>'_session_id'), p_args->>'intent');
    v_source text := btrim(COALESCE(p_args->>'source', p_args->>'source_key', ''));
BEGIN
    IF v_intent IS NULL THEN RETURN '{"error":"could not resolve intent for this session"}'; END IF;
    IF v_source = '' THEN RETURN '{"error":"source (a url/source name/query) is required"}'; END IF;
    INSERT INTO stewards.intent_source_ledger (intent_slug, source_key, finding, doc_slug)
    VALUES (v_intent, v_source, p_args->>'finding', p_args->>'doc_slug')
    ON CONFLICT (intent_slug, source_key) DO UPDATE
        SET gathered_at = now(),
            finding     = COALESCE(EXCLUDED.finding, stewards.intent_source_ledger.finding),
            doc_slug    = COALESCE(EXCLUDED.doc_slug, stewards.intent_source_ledger.doc_slug),
            gather_count = stewards.intent_source_ledger.gather_count + 1;
    RETURN jsonb_build_object('ok', true, 'intent', v_intent, 'source', v_source,
                              'note', 'recorded — future cycles will skip this while it is fresh')::text;
END $FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'intent_sources_recent',
  'Before you crawl or run a web query, call this to see which sources/queries this intent already gathered recently (within the freshness window). SKIP those — they are fresh and their findings are already in the docs pool (use doc_search to read them). Gather only NEW sources.',
  '{"type":"object","properties":{"window_days":{"type":"integer","description":"freshness window; default 10"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"intent_sources_recent_tool"}'::jsonb, true ),
( 'intent_source_record',
  'After you gather a NEW source (and publish its finding), call this to record it so future cycles skip it while fresh. Pass source (the url/source name/query), a one-line finding, and the doc_slug you published it into.',
  '{"type":"object","required":["source"],"properties":{"source":{"type":"string"},"finding":{"type":"string"},"doc_slug":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"intent_source_record_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- =====================================================================
-- Project neighborhoods — controlled knowledge bleed across the pool.
--
-- The pool (stewards.docs) is tagged by project (project_association; defaulted
-- to the intent's slug in work_item_create). A project reads its OWN docs plus
-- any projects in its neighborhood — so you isolate one project (e.g. a work
-- project) while letting others cross-pollinate (e.g. research + books). The
-- scope is enforced by pool_search (it resolves the caller's project from the
-- session, not the model's choice); global doc_search remains as an explicit
-- meta escape hatch. Neighborhood rows are operator data — seed them in an
-- overlay (a fresh project reads only itself until you connect it).
-- =====================================================================
CREATE TABLE IF NOT EXISTS stewards.project_neighborhood (
    project       text NOT NULL,   -- the reading project
    reads_project text NOT NULL,   -- a project it may ALSO read (besides itself)
    PRIMARY KEY (project, reads_project)
);
COMMENT ON TABLE stewards.project_neighborhood IS
'reflect-steward knowledge scope: a project reads its own docs + the reads_project rows here. Default (no rows) = isolated. e.g. (ai,books)+(books,ai) lets research + books cross-pollinate while a work project stays walled off.';

CREATE OR REPLACE FUNCTION stewards.project_neighbors(p_project text)
RETURNS text[] LANGUAGE sql STABLE AS $$
    SELECT CASE WHEN p_project IS NULL OR p_project = '' THEN NULL
           ELSE array(SELECT DISTINCT x FROM (
                  SELECT p_project AS x
                  UNION
                  SELECT reads_project FROM stewards.project_neighborhood WHERE project = p_project
                ) u WHERE x IS NOT NULL) END;
$$;
COMMENT ON FUNCTION stewards.project_neighbors(text) IS
'The set of projects p_project may read: itself + its project_neighborhood rows. NULL/empty input → NULL (pool_search treats that as global / unscoped).';

-- pool_search: doc search scoped to the caller's project neighborhood (enforced).
CREATE OR REPLACE FUNCTION stewards.pool_search_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess      text := p_args->>'_session_id';
    v_query     text := p_args->>'query';
    v_limit     int  := COALESCE(NULLIF(p_args->>'limit','')::int, 10);
    v_project   text;
    v_neighbors text[];
    v_rows      jsonb;
BEGIN
    IF v_query IS NULL OR btrim(v_query) = '' THEN RETURN '{"error":"query required"}'; END IF;
    SELECT w.project_association INTO v_project
      FROM stewards.work_items w
     WHERE v_sess = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1;
    IF v_project IS NULL THEN v_project := p_args->>'project'; END IF;  -- fallback for direct callers
    v_neighbors := stewards.project_neighbors(v_project);

    SELECT jsonb_agg(jsonb_build_object('slug', slug, 'kind', kind, 'title', title,
                                        'project', project_association, 'snippet', snippet) ORDER BY rank DESC)
      INTO v_rows
      FROM (
        SELECT s.slug, s.kind, s.title, s.project_association,
               ts_headline('english', coalesce(s.body, ''), q, 'MaxWords=20, MinWords=10') AS snippet,
               ts_rank(s.body_tsv, q) AS rank
          FROM stewards.docs s, websearch_to_tsquery('english', v_query) q
         WHERE s.body_tsv @@ q
           -- enforced scope: if the caller has a project, restrict to its neighborhood;
           -- a caller with no project (untagged / a meta intent) searches globally.
           AND (v_neighbors IS NULL OR s.project_association = ANY(v_neighbors))
         ORDER BY rank DESC
         LIMIT greatest(v_limit, 1)
      ) r;

    RETURN jsonb_build_object('project', v_project, 'neighborhood', v_neighbors,
        'results', COALESCE(v_rows, '[]'::jsonb),
        'note', CASE WHEN v_neighbors IS NULL
                     THEN 'no project scope — searched the whole pool (meta).'
                     ELSE 'scoped to this project''s neighborhood; other projects are walled off.' END)::text;
END $FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES (
  'pool_search',
  'Search the knowledge pool (docs) SCOPED to your project''s neighborhood — your own project plus any it is connected to. Use this for normal reading so you stay on-topic and do not bleed across walled-off projects. (Global doc_search exists for deliberate cross-project meta-studies.) Args: query (required), limit.',
  '{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"limit":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"pool_search_tool"}'::jsonb, true)
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- =====================================================================
-- The council moment, baked in — survey existing work before proposing.
--
-- Cold starts reproduce each other: a reflect run that can't see its siblings'
-- pending proposals re-proposes the same plan (we watched one intent accrue 13
-- near-duplicate proposals). This is the substrate's own Council Moment
-- (Abraham 4:26 — "took counsel among themselves" before acting) given to the
-- autonomous steward: before proposing, see what is already proposed / in
-- flight / done for THIS intent, with provenance, and either propose something
-- genuinely new or refine an existing item (don't duplicate). The gatherer calls
-- this in its first (situational-awareness) stage.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.intent_work_survey_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql AS $FN$
DECLARE
    v_sess   text := p_args->>'_session_id';
    v_intent uuid;
    v_slug   text;
BEGIN
    SELECT w.intent_id, i.slug INTO v_intent, v_slug
      FROM stewards.work_items w JOIN stewards.intents i ON i.id = w.intent_id
     WHERE v_sess = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1;
    IF v_intent IS NULL THEN
        v_slug := p_args->>'intent';
        SELECT id INTO v_intent FROM stewards.intents WHERE slug = v_slug;
    END IF;
    IF v_intent IS NULL THEN RETURN '{"error":"could not resolve the intent for this session"}'; END IF;

    RETURN jsonb_build_object(
        'intent', v_slug,
        'already_proposed', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'slug', slug, 'pipeline', pipeline_family,
                       'binding_question', left(input->>'binding_question', 160)) ORDER BY created_at DESC), '[]'::jsonb)
              FROM stewards.work_items
             WHERE intent_id = v_intent AND origin = 'agent_planning' AND status = 'pending'),
        'in_flight', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object('slug', slug, 'stage', current_stage) ORDER BY created_at DESC), '[]'::jsonb)
              FROM stewards.work_items
             WHERE intent_id = v_intent AND status IN ('in_progress', 'awaiting_review')),
        'recently_done', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object('slug', slug, 'maturity', maturity) ORDER BY updated_at DESC), '[]'::jsonb)
              FROM (SELECT slug, maturity, updated_at FROM stewards.work_items
                     WHERE intent_id = v_intent AND status = 'completed'
                     ORDER BY updated_at DESC LIMIT 15) d),
        'note', 'COUNCIL MOMENT — these are already proposed / running / done for this intent (slugs are your provenance). Do NOT re-propose any of them. Propose only genuinely NEW next-steps, or explicitly refine/extend an existing one by citing its slug. Cold starts tend to duplicate; this is how you avoid it.'
    )::text;
END $FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES (
  'intent_work_survey',
  'Call this FIRST, before proposing anything. Returns what is already proposed (pending), in flight, and recently done for this intent — with slugs as provenance. Use it to avoid re-proposing duplicate work (cold starts repeat themselves): propose only NEW next-steps, or refine an existing item by citing its slug. This is your council moment.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"intent_work_survey_tool"}'::jsonb, true)
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- =====================================================================
-- End of 22-reflect-steward.sql
-- =====================================================================
