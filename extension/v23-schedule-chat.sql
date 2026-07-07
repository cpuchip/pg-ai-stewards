-- ===== [was 100-schedule-chat.sql] =====
-- =====================================================================
-- 100-schedule-chat.sql — chat HANDS for the cron scheduler.
-- =====================================================================
-- Michael's ask, verbatim: "can we add the ability to create a crawler cron
-- through chat like that? or edit a cron through chat? so that corpus can
-- grow automagically." 18-scheduler.sql already fires stewards.scheduled_
-- pipelines rows on a 5-field cron (scheduled_pipelines_fire, driven off the
-- 60s watchman tick) — but the table was OPERATOR data, reachable only by
-- hand-INSERTing a row. This file is the chat-facing gap-closer: four SQL
-- functions (create/list/update/delete) + *_tool(jsonb) wrappers + tool_defs,
-- so "crawl arXiv weekly for new LLM papers" becomes one sentence instead of
-- a psql session. 18's cron engine (cron_field_values, cron_next_after, the
-- compute-next-due trigger) is reused UNMODIFIED — this file only adds a
-- validator (cron_validate, below) that calls it; 18 itself is untouched.
--
-- Conventions followed (94-wiki-curator.sql's fleet-integration addendum):
-- every write-tool is a plain SQL function returning jsonb (never RAISE to
-- the loop — errors come back as {"ok":false,"error":"..."} so the model can
-- recover and retry), paired with a *_tool(jsonb) wrapper that reads
-- p_args ->> '<key>' and is what tool_defs.execute_target actually points at
-- (kind=sql_fn convention, 30-tool-primers / 94's wiki_search_tool etc.).
--
-- DESIGN — validation (the politeness floor, D-PE6 companion):
--   * pipeline_family must already exist in stewards.pipelines — otherwise
--     the error lists every valid family so the model can self-correct
--     without a round trip to schedule_list.
--   * cron_pattern must parse under 18's OWN cron_field_values (same ranges,
--     same 5-field shape) via the NEW stewards.cron_validate(text) below, AND
--     the minute field must resolve to exactly ONE value. 18's cron engine
--     is happy to fire every minute ("* * * * *") or every 5 minutes
--     ("*/5 * * * *") — fine for a human-authored operator row someone is
--     presumably watching, not fine for a chat-authored recurring job nobody
--     is standing over. Capping the minute field to a single literal value
--     bounds every chat-created schedule to at most once per hour without
--     touching 18's parser at all (cron_validate is a pure NEW function that
--     calls cron_field_values/cron_next_after; it never CREATE OR REPLACEs
--     anything in 18).
--   * slug is upsert-with-note: re-calling schedule_create on an existing
--     slug UPDATES that row (ON CONFLICT (slug) DO UPDATE) rather than
--     erroring — a chat model re-issuing "same schedule, different cron"
--     should not have to know to call schedule_update instead; the p_note
--     arg rides along either way.
--
-- DESIGN — the enabled cap (config schedule.max_enabled, seeded below,
-- default 12): a chat session strung along by an enthusiastic user could
-- otherwise accrete an unbounded number of always-firing cron jobs with
-- zero friction. schedule_create/schedule_update count currently-ENABLED
-- rows (excluding the slug being written, so re-saving an already-enabled
-- schedule never counts against itself) and, past the cap, land/leave the
-- row DISABLED with a plain-language message instead of failing outright —
-- nothing is lost, the schedule just doesn't fire until a human (or the
-- chat, told to) disables another or raises the config key.
--
-- requires create_wiki_assets (96 = the last entry found in THIS worktree;
-- three siblings are landing 97/98/99 in parallel — the integrator re-
-- stitches this file's src/lib.rs `requires` to whatever the real chain tail
-- turns out to be once all four land, same forward-ref discipline 94's own
-- header names for its 92/93 siblings).
--
-- GRANTS: all four tools go to 'work-item-chat' (chat IS Michael's hands —
-- creating/editing a cron is reversible, chat-scoped operator work, same
-- posture as 53-explore-repos.sql's research_codebase grant). The 'intake'
-- grant below is a SOFT check (EXISTS against stewards.agents) — a ROUTER
-- sibling is introducing that family in this same fleet run; if it hasn't
-- landed by the time this file applies, the grant is skipped silently and
-- is NOT retroactive (this file only runs once, at its place in the chain).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Config — the enabled-schedule cap.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('schedule.max_enabled', '12'::jsonb,
   'Cap on ENABLED stewards.scheduled_pipelines rows. schedule_create/schedule_update (100-schedule-chat) refuse to silently multiply always-firing cron jobs past this cap: a new or re-enabled schedule past it lands/stays DISABLED with a plain-language message instead of erroring. Raise this key to allow more concurrent enabled schedules.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- cron_validate(text) — 18's parser, reused unmodified. Parses the 5-field
-- pattern with stewards.cron_field_values (same function 18's own
-- cron_next_after uses), catching any RAISE it throws and turning it into a
-- jsonb verdict, then enforces the sub-hourly floor: the minute field must
-- resolve to exactly one value. Also confirms the pattern actually matches
-- SOMETHING within cron_next_after's 366-day horizon (catches e.g. a
-- Feb-30-only day/month combination) — same NULL-on-no-match contract
-- cron_next_after already documents.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.cron_validate(p_pattern text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_parts        text[];
    v_minute       text;
    v_hour         text;
    v_dom          text;
    v_month        text;
    v_dow          text;
    v_minute_count int;
BEGIN
    IF p_pattern IS NULL OR btrim(p_pattern) = '' THEN
        RETURN jsonb_build_object('valid', false, 'error', 'cron_pattern is required');
    END IF;

    v_parts := regexp_split_to_array(btrim(p_pattern), '\s+');
    IF array_length(v_parts, 1) <> 5 THEN
        RETURN jsonb_build_object('valid', false, 'error',
            format('expected a 5-field cron (minute hour day-of-month month day-of-week), got %s field(s) in "%s"',
                   coalesce(array_length(v_parts, 1), 0), p_pattern));
    END IF;

    v_minute := v_parts[1]; v_hour := v_parts[2]; v_dom := v_parts[3];
    v_month  := v_parts[4]; v_dow  := v_parts[5];

    BEGIN
        SELECT count(*) INTO v_minute_count FROM stewards.cron_field_values(v_minute, 0, 59);
        PERFORM 1 FROM stewards.cron_field_values(v_hour, 0, 23);
        PERFORM 1 FROM stewards.cron_field_values(v_dom, 1, 31);
        PERFORM 1 FROM stewards.cron_field_values(v_month, 1, 12);
        PERFORM 1 FROM stewards.cron_field_values(v_dow, 0, 6);
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('valid', false, 'error', 'unparseable cron field: ' || SQLERRM);
    END;

    IF v_minute_count > 1 THEN
        RETURN jsonb_build_object('valid', false, 'error',
            format('minute field "%s" fires %s times per hour — recurring chat-created schedules may fire at most once per hour; use a single specific minute (e.g. "6", not "*", a list, a range, or a step)',
                   v_minute, v_minute_count));
    END IF;

    IF stewards.cron_next_after(p_pattern, now()) IS NULL THEN
        RETURN jsonb_build_object('valid', false, 'error',
            format('cron_pattern "%s" never matches within the next 366 days — check the day-of-month/month combination', p_pattern));
    END IF;

    RETURN jsonb_build_object('valid', true);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('valid', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.cron_validate(text) IS
'100-schedule-chat: validates a 5-field cron pattern by calling 18-scheduler''s OWN cron_field_values/cron_next_after (unmodified) and enforces a politeness floor for chat-created recurring jobs: the minute field must resolve to exactly one value (no more than once-per-hour). Returns {"valid":true} or {"valid":false,"error":"..."} — never raises.';

-- =====================================================================
-- schedule_create — the entry point. Validates pipeline_family + cron,
-- resolves the default intent, applies the enabled cap, upserts by slug.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.schedule_create(
    p_slug            text,
    p_pipeline_family text,
    p_cron            text,
    p_input           jsonb,
    p_note            text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_families      text;
    v_validation    jsonb;
    v_intent_slug   text;
    v_intent_id     uuid;
    v_cap           int;
    v_enabled_count int;
    v_enabled       boolean;
    v_cap_note      text := NULL;
    v_row           stewards.scheduled_pipelines%ROWTYPE;
BEGIN
    IF p_slug IS NULL OR btrim(p_slug) = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'slug is required');
    END IF;
    IF p_pipeline_family IS NULL OR btrim(p_pipeline_family) = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'pipeline_family is required');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family = p_pipeline_family) THEN
        SELECT string_agg(family, ', ' ORDER BY family) INTO v_families FROM stewards.pipelines;
        RETURN jsonb_build_object('ok', false, 'error',
            format('no pipeline_family "%s" — valid families: %s', p_pipeline_family, coalesce(v_families, '(none registered)')));
    END IF;

    v_validation := stewards.cron_validate(p_cron);
    IF NOT coalesce((v_validation->>'valid')::boolean, false) THEN
        RETURN jsonb_build_object('ok', false, 'error', v_validation->>'error');
    END IF;

    v_intent_slug := stewards.config_get_text('default_intent_slug', 'default');
    SELECT id INTO v_intent_id FROM stewards.intents WHERE slug = v_intent_slug;
    IF v_intent_id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('no default intent seeded (config default_intent_slug=%s) — seed an intent before scheduling', v_intent_slug));
    END IF;

    v_cap := coalesce((stewards.config_get('schedule.max_enabled', '12'::jsonb))::text::int, 12);
    SELECT count(*) INTO v_enabled_count
      FROM stewards.scheduled_pipelines
     WHERE enabled = true AND slug <> p_slug;

    IF v_enabled_count >= v_cap THEN
        v_enabled  := false;
        v_cap_note := format('cap reached (%s/%s schedules already enabled) — created DISABLED. Disable another schedule or raise config ''schedule.max_enabled'' to enable this one.',
                              v_enabled_count, v_cap);
    ELSE
        v_enabled := true;
    END IF;

    INSERT INTO stewards.scheduled_pipelines
        (slug, pipeline_family, intent_id, cron_pattern, input_template, enabled, notes)
    VALUES
        (p_slug, p_pipeline_family, v_intent_id, p_cron, coalesce(p_input, '{}'::jsonb), v_enabled, p_note)
    ON CONFLICT (slug) DO UPDATE SET
        pipeline_family = EXCLUDED.pipeline_family,
        intent_id       = EXCLUDED.intent_id,
        cron_pattern    = EXCLUDED.cron_pattern,
        input_template  = EXCLUDED.input_template,
        enabled         = EXCLUDED.enabled,
        notes           = EXCLUDED.notes
    RETURNING * INTO v_row;

    RETURN jsonb_build_object(
        'ok', true,
        'schedule', row_to_json(v_row)::jsonb,
        'cap_note', v_cap_note
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.schedule_create(text, text, text, jsonb, text) IS
'100-schedule-chat: chat-facing entry point for 18-scheduler''s scheduled_pipelines. Validates pipeline_family exists + cron_pattern parses (cron_validate, at-most-once-per-hour floor), defaults intent_id to the config default_intent_slug intent, applies the schedule.max_enabled cap (creates DISABLED past the cap), and upserts by slug. Returns {"ok":true,"schedule":{...row incl. next_due_at...}} or {"ok":false,"error":"..."} — never raises.';

CREATE OR REPLACE FUNCTION stewards.schedule_create_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN stewards.schedule_create(
        p_args->>'slug',
        p_args->>'pipeline_family',
        p_args->>'cron_pattern',
        coalesce(p_args->'input', '{}'::jsonb),
        p_args->>'note'
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- =====================================================================
-- schedule_list — every schedule, one-line input summary.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.schedule_list()
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'slug',               slug,
            'pipeline_family',    pipeline_family,
            'cron_pattern',       cron_pattern,
            'enabled',            enabled,
            'next_due_at',        next_due_at,
            'last_dispatched_at', last_dispatched_at,
            'input_summary',      left(input_template::text, 120),
            'notes',              notes
        ) ORDER BY slug
    ), '[]'::jsonb)
    FROM stewards.scheduled_pipelines;
$fn$;
COMMENT ON FUNCTION stewards.schedule_list() IS
'100-schedule-chat: every stewards.scheduled_pipelines row as jsonb (slug, pipeline_family, cron_pattern, enabled, next_due_at, last_dispatched_at, a one-line input summary, notes). Used by schedule_list_tool for the chat surface.';

CREATE OR REPLACE FUNCTION stewards.schedule_list_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN jsonb_build_object('ok', true, 'schedules', stewards.schedule_list());
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- =====================================================================
-- schedule_update — patch by slug. Re-validates cron_pattern; re-checks
-- the enabled cap only when flipping disabled -> enabled (a flip that
-- bypassed the cap check would make schedule_create's cap trivially
-- avoidable by create-disabled-then-enable).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.schedule_update(
    p_slug  text,
    p_patch jsonb
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_existing      stewards.scheduled_pipelines%ROWTYPE;
    v_new_cron      text;
    v_new_input     jsonb;
    v_new_enabled   boolean;
    v_new_notes     text;
    v_validation    jsonb;
    v_cap           int;
    v_enabled_count int;
    v_cap_note      text := NULL;
    v_row           stewards.scheduled_pipelines%ROWTYPE;
BEGIN
    IF p_slug IS NULL OR btrim(p_slug) = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'slug is required');
    END IF;
    IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'patch (a jsonb object) is required');
    END IF;

    SELECT * INTO v_existing FROM stewards.scheduled_pipelines WHERE slug = p_slug;
    IF v_existing.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no schedule with slug "%s"', p_slug));
    END IF;

    v_new_cron    := coalesce(p_patch->>'cron_pattern', v_existing.cron_pattern);
    v_new_input   := coalesce(p_patch->'input_template', v_existing.input_template);
    v_new_notes   := coalesce(p_patch->>'note', v_existing.notes);
    v_new_enabled := coalesce((p_patch->>'enabled')::boolean, v_existing.enabled);

    v_validation := stewards.cron_validate(v_new_cron);
    IF NOT coalesce((v_validation->>'valid')::boolean, false) THEN
        RETURN jsonb_build_object('ok', false, 'error', v_validation->>'error');
    END IF;

    IF v_new_enabled AND NOT v_existing.enabled THEN
        v_cap := coalesce((stewards.config_get('schedule.max_enabled', '12'::jsonb))::text::int, 12);
        SELECT count(*) INTO v_enabled_count
          FROM stewards.scheduled_pipelines
         WHERE enabled = true AND slug <> p_slug;

        IF v_enabled_count >= v_cap THEN
            v_new_enabled := false;
            v_cap_note := format('cap reached (%s/%s schedules already enabled) — left DISABLED. Disable another schedule or raise config ''schedule.max_enabled'' to enable this one.',
                                  v_enabled_count, v_cap);
        END IF;
    END IF;

    UPDATE stewards.scheduled_pipelines
       SET cron_pattern   = v_new_cron,
           input_template = v_new_input,
           enabled        = v_new_enabled,
           notes          = v_new_notes
     WHERE slug = p_slug
     RETURNING * INTO v_row;

    RETURN jsonb_build_object('ok', true, 'schedule', row_to_json(v_row)::jsonb, 'cap_note', v_cap_note);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.schedule_update(text, jsonb) IS
'100-schedule-chat: patch an existing scheduled_pipelines row by slug. patch keys: cron_pattern (re-validated via cron_validate), enabled, input_template, note. Recomputes next_due_at via 18''s BEFORE-trigger when cron_pattern changes. Re-applies the schedule.max_enabled cap when flipping disabled->enabled. Returns {"ok":true,"schedule":{...}} or {"ok":false,"error":"..."} — never raises.';

CREATE OR REPLACE FUNCTION stewards.schedule_update_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN stewards.schedule_update(p_args->>'slug', coalesce(p_args->'patch', '{}'::jsonb));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- =====================================================================
-- schedule_delete — hard delete by slug. Returns what was deleted so
-- chat can echo it (trivially recreatable via schedule_create).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.schedule_delete(p_slug text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_row stewards.scheduled_pipelines%ROWTYPE;
BEGIN
    IF p_slug IS NULL OR btrim(p_slug) = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'slug is required');
    END IF;

    DELETE FROM stewards.scheduled_pipelines WHERE slug = p_slug RETURNING * INTO v_row;
    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no schedule with slug "%s"', p_slug));
    END IF;

    RETURN jsonb_build_object('ok', true, 'deleted', row_to_json(v_row)::jsonb);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.schedule_delete(text) IS
'100-schedule-chat: hard-deletes a scheduled_pipelines row by slug and returns what was deleted (chat echoes it; trivially recreatable via schedule_create — reversible enough). Returns {"ok":false,"error":"..."} on a missing slug — never raises.';

CREATE OR REPLACE FUNCTION stewards.schedule_delete_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN stewards.schedule_delete(p_args->>'slug');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- =====================================================================
-- tool_defs — written FOR THE CHAT MODEL (the crawl use-case named
-- explicitly, per the mission brief).
-- =====================================================================
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
('schedule_create',
 'Create (or update, if the slug already exists) a recurring cron schedule that dispatches a pipeline automatically — e.g. pipeline_family "crawl" with input {"url":"...","purpose":"...","config":{...}} makes a corpus grow on a schedule with no further chat needed. cron_pattern is standard 5-field cron (minute hour day-of-month month day-of-week); the minute field must resolve to ONE specific minute (no "*", no lists/ranges/steps) — chat-created recurring jobs may fire at most once per hour. input MUST match the target pipeline_family''s expected input shape — check with the user or schedule_list if unsure. An enabled-schedule cap exists (config schedule.max_enabled); past it, a new schedule lands DISABLED with a clear message instead of failing. Returns the created/updated row including next_due_at so you can tell the user when it first fires.',
 '{"type":"object","required":["slug","pipeline_family","cron_pattern","input"],"additionalProperties":false,"properties":{"slug":{"type":"string","description":"kebab-case unique id, e.g. arxiv-llm-weekly"},"pipeline_family":{"type":"string","description":"an existing stewards.pipelines family, e.g. crawl, lab-regression, wiki-organize"},"cron_pattern":{"type":"string","description":"5-field cron; minute field must be one specific minute, e.g. \"0 6 * * 1\" for Monday 6am UTC"},"input":{"type":"object","description":"the input_template jsonb passed to work_item_create every time this fires — must match pipeline_family''s expected input"},"note":{"type":"string","description":"optional human-readable note about why this schedule exists"}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','schedule_create_tool','schema','stewards'), true),

('schedule_list',
 'List every scheduled pipeline: slug, pipeline_family, cron_pattern, enabled, next_due_at, last_dispatched_at, and a one-line input summary. Use this before schedule_update/schedule_delete to find the right slug, or when the user asks "what''s scheduled?" or "what crons do we have running?"',
 '{"type":"object","additionalProperties":false,"properties":{}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','schedule_list_tool','schema','stewards'), true),

('schedule_update',
 'Edit an existing schedule by slug. patch may include any of: cron_pattern (re-validated the same way as schedule_create — still at most once per hour), enabled (true/false), input_template (must still match the pipeline''s expected input), note. Only the keys present in patch are changed. Re-checks the enabled-schedule cap if you flip enabled from false to true. Returns the updated row with next_due_at recomputed.',
 '{"type":"object","required":["slug","patch"],"additionalProperties":false,"properties":{"slug":{"type":"string"},"patch":{"type":"object","description":"any of: cron_pattern (string), enabled (boolean), input_template (object), note (string)"}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','schedule_update_tool','schema','stewards'), true),

('schedule_delete',
 'Delete a schedule by slug. Hard delete — returns what was deleted so you can tell the user, and it''s trivially recreatable with schedule_create if that was a mistake.',
 '{"type":"object","required":["slug"],"additionalProperties":false,"properties":{"slug":{"type":"string"}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','schedule_delete_tool','schema','stewards'), true)

ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- ── discoverability: a tool_group bundling the four (37-tool-groups'
-- pattern, mirror of 94's 'wiki-tools') — a pattern that matches no
-- installed tool just contributes nothing, so this is harmless whether or
-- not any future pipeline stage ever names it.
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('schedule-tools', 'create/list/update/delete recurring cron schedules that dispatch pipelines automatically — the chat hands for 18-scheduler.sql',
     ARRAY['schedule_create','schedule_list','schedule_update','schedule_delete'])
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, tool_patterns=EXCLUDED.tool_patterns;

-- =====================================================================
-- Grants. work-item-chat denies '*' by default (45-work-item-chat.sql) and
-- allows specific tools by exact name — longest-glob-wins (tool_permission,
-- src/schema.rs) means these exact-name allows beat the agent's '*' deny.
-- =====================================================================
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'schedule_create', 'allow', 'manual'),
  ('work-item-chat', 'schedule_list',   'allow', 'manual'),
  ('work-item-chat', 'schedule_update', 'allow', 'manual'),
  ('work-item-chat', 'schedule_delete', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- SOFT check: a ROUTER sibling in this same fleet run is introducing the
-- 'intake' agent family. If it exists by the time THIS file applies, grant
-- it the same four tools; if not, skip quietly (not retroactive — see
-- header). agent_tool_perms carries no FK to stewards.agents, so either
-- branch is safe.
DO $intake_grant$
BEGIN
    IF EXISTS (SELECT 1 FROM stewards.agents WHERE family = 'intake') THEN
        INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
          ('intake', 'schedule_create', 'allow', 'manual'),
          ('intake', 'schedule_list',   'allow', 'manual'),
          ('intake', 'schedule_update', 'allow', 'manual'),
          ('intake', 'schedule_delete', 'allow', 'manual')
        ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;
        RAISE NOTICE '100-schedule-chat: granted schedule_* to the intake agent family (found present).';
    ELSE
        RAISE NOTICE '100-schedule-chat: intake agent family not present at apply time — skipping its grant (not retroactive; a later manual grant closes this if intake lands after this file).';
    END IF;
END;
$intake_grant$;

-- =====================================================================
-- End of 100-schedule-chat.sql
-- =====================================================================
