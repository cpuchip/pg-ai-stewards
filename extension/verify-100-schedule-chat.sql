-- =====================================================================
-- verify-100-schedule-chat.sql — DRY synthetic smoke for 100-schedule-chat.sql.
--
-- Standalone verify script (the verify-*.sql convention, not part of
-- migration-order.txt / lib.rs — run manually against a scratch install,
-- per tests/README.md's "docker build + docker run + psql < file" recipe).
--
-- Usage:
--   docker exec -i <container> psql -U stewards -d stewards \
--       -v ON_ERROR_STOP=1 < extension/100-schedule-chat.sql
--   docker exec -i <container> psql -U stewards -d stewards \
--       -v ON_ERROR_STOP=1 < extension/verify-100-schedule-chat.sql
-- =====================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- Setup — a virgin core ships zero stewards.intents rows (00-config only
-- sets the config KEY default_intent_slug='default'; the row itself is
-- runtime-seeded). Mirrors verify-94-wiki-curator.sql's own setup step.
-- ---------------------------------------------------------------------
DO $setup$
DECLARE
    v_slug text := stewards.config_get_text('default_intent_slug', 'default');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM stewards.intents WHERE slug = v_slug) THEN
        INSERT INTO stewards.intents (slug, purpose, values_anchor)
        VALUES (v_slug, 'verify-100 synthetic default intent', 'test');
        RAISE NOTICE 'verify-100 setup: seeded the default intent (slug=%)', v_slug;
    END IF;
END;
$setup$;

-- =====================================================================
-- OK 100a — valid create: row lands, next_due_at is sane (in the future,
-- matches the pattern), enabled=true (well under any default cap).
-- =====================================================================
DO $t$
DECLARE
    v_result jsonb;
    v_due    timestamptz;
BEGIN
    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-lab-nightly',
        'pipeline_family', 'lab-regression',
        'cron_pattern', '6 3 * * *',
        'input', '{}'::jsonb,
        'note', 'verify-100 OK-100a'
    ));

    ASSERT coalesce((v_result->>'ok')::boolean, false),
        format('OK 100a: schedule_create should succeed on a valid family+cron, got %s', v_result);
    ASSERT (v_result->'schedule'->>'slug') = 'verify100-lab-nightly', 'OK 100a: returned row should carry the slug';
    ASSERT (v_result->'schedule'->>'enabled')::boolean = true, 'OK 100a: should land enabled (well under the default cap)';

    v_due := (v_result->'schedule'->>'next_due_at')::timestamptz;
    ASSERT v_due IS NOT NULL, 'OK 100a: next_due_at should be computed (18''s BEFORE-trigger fires on INSERT)';
    ASSERT v_due > now(), 'OK 100a: next_due_at should be in the future';
    ASSERT EXTRACT(MINUTE FROM (v_due AT TIME ZONE 'UTC'))::int = 6, 'OK 100a: next_due_at minute should match the "6" in the pattern';
    ASSERT EXTRACT(HOUR FROM (v_due AT TIME ZONE 'UTC'))::int = 3, 'OK 100a: next_due_at hour should match the "3" in the pattern';

    RAISE NOTICE 'OK 100a: schedule_create — valid family+cron lands enabled with a sane computed next_due_at (%)', v_due;
END;
$t$;

-- =====================================================================
-- OK 100b — invalid pipeline_family rejected, error lists valid families.
-- =====================================================================
DO $t$
DECLARE
    v_result jsonb;
BEGIN
    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-should-not-exist',
        'pipeline_family', 'not-a-real-pipeline-family',
        'cron_pattern', '0 6 * * *',
        'input', '{}'::jsonb
    ));

    ASSERT (v_result->>'ok')::boolean = false, 'OK 100b: unknown pipeline_family must be rejected';
    ASSERT (v_result->>'error') LIKE '%no pipeline_family%', format('OK 100b: error should name the missing family, got %L', v_result->>'error');
    ASSERT (v_result->>'error') LIKE '%lab-regression%', 'OK 100b: error should list valid families, including lab-regression';
    ASSERT NOT EXISTS (SELECT 1 FROM stewards.scheduled_pipelines WHERE slug = 'verify100-should-not-exist'),
        'OK 100b: no row should have been created on a rejected family';

    RAISE NOTICE 'OK 100b: schedule_create — unknown pipeline_family rejected with the valid-families list, no row created';
END;
$t$;

-- =====================================================================
-- OK 100c — malformed cron rejected (wrong field count / unparseable).
-- =====================================================================
DO $t$
DECLARE
    v_result jsonb;
BEGIN
    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-wrong-field-count',
        'pipeline_family', 'lab-regression',
        'cron_pattern', 'not a real cron',
        'input', '{}'::jsonb
    ));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100c: wrong-field-count cron must be rejected';
    ASSERT (v_result->>'error') LIKE '%5-field%', format('OK 100c: error should name the 5-field expectation, got %L', v_result->>'error');

    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-bad-cron',
        'pipeline_family', 'lab-regression',
        'cron_pattern', 'not a cron at all',
        'input', '{}'::jsonb
    ));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100c: unparseable cron field content must be rejected';
    ASSERT (v_result->>'error') LIKE '%unparseable%', format('OK 100c: error should say unparseable, got %L', v_result->>'error');

    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-bad-range',
        'pipeline_family', 'lab-regression',
        'cron_pattern', '5 99 * * *',
        'input', '{}'::jsonb
    ));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100c: out-of-range hour field (99) must be rejected';

    ASSERT NOT EXISTS (SELECT 1 FROM stewards.scheduled_pipelines WHERE slug IN ('verify100-wrong-field-count', 'verify100-bad-cron', 'verify100-bad-range')),
        'OK 100c: no row should have been created on a rejected cron';

    RAISE NOTICE 'OK 100c: schedule_create — wrong field count, unparseable field content, and out-of-range values all rejected, no rows created';
END;
$t$;

-- =====================================================================
-- OK 100d — sub-hourly cron rejected (the politeness floor): "*", a list,
-- a range, and a step in the minute field must all be rejected; a single
-- literal minute must NOT be.
-- =====================================================================
DO $t$
DECLARE
    v_result jsonb;
BEGIN
    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-every-minute', 'pipeline_family', 'lab-regression',
        'cron_pattern', '* * * * *', 'input', '{}'::jsonb));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100d: "*" minute field must be rejected (fires 60x/hour)';

    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-step-5', 'pipeline_family', 'lab-regression',
        'cron_pattern', '*/5 * * * *', 'input', '{}'::jsonb));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100d: "*/5" minute field must be rejected (fires 12x/hour)';

    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-list', 'pipeline_family', 'lab-regression',
        'cron_pattern', '0,30 * * * *', 'input', '{}'::jsonb));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100d: "0,30" minute field must be rejected (fires 2x/hour)';

    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-range', 'pipeline_family', 'lab-regression',
        'cron_pattern', '0-5 * * * *', 'input', '{}'::jsonb));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100d: "0-5" minute field must be rejected (fires 6x/hour)';

    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-once-hourly', 'pipeline_family', 'lab-regression',
        'cron_pattern', '15 * * * *', 'input', '{}'::jsonb));
    ASSERT coalesce((v_result->>'ok')::boolean, false),
        format('OK 100d: a single literal minute ("15") must be ACCEPTED (exactly once per hour), got %s', v_result);

    DELETE FROM stewards.scheduled_pipelines WHERE slug = 'verify100-once-hourly';

    ASSERT NOT EXISTS (SELECT 1 FROM stewards.scheduled_pipelines
                        WHERE slug IN ('verify100-every-minute','verify100-step-5','verify100-list','verify100-range')),
        'OK 100d: no row should have been created for any rejected sub-hourly pattern';

    RAISE NOTICE 'OK 100d: schedule_create — sub-hourly minute fields ("*", "*/5", "0,30", "0-5") all rejected; a single literal minute ("15") accepted';
END;
$t$;

-- =====================================================================
-- OK 100e — the enabled cap: set schedule.max_enabled=1 inside this test
-- transaction (already 1 enabled row from OK-100a), the next create lands
-- DISABLED with a clear cap_note. Inverse leg: raise the cap back and
-- flip it on via schedule_update, proving the gate is genuinely driven by
-- the live count vs the config value, not a hardcoded rejection.
-- =====================================================================
DO $t$
DECLARE
    v_prior  jsonb;
    v_result jsonb;
BEGIN
    SELECT value INTO v_prior FROM stewards.config WHERE key = 'schedule.max_enabled';
    UPDATE stewards.config SET value = '1'::jsonb WHERE key = 'schedule.max_enabled';

    -- verify100-lab-nightly (OK-100a) already counts as 1 enabled row.
    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'verify100-cap-overflow', 'pipeline_family', 'lab-regression',
        'cron_pattern', '20 4 * * *', 'input', '{}'::jsonb));

    ASSERT coalesce((v_result->>'ok')::boolean, false),
        format('OK 100e: schedule_create should still SUCCEED past the cap (creates disabled, does not fail), got %s', v_result);
    ASSERT (v_result->'schedule'->>'enabled')::boolean = false,
        'OK 100e: past the cap, the new row should land DISABLED';
    ASSERT (v_result->>'cap_note') LIKE '%cap reached%', format('OK 100e: cap_note should explain the cap, got %L', v_result->>'cap_note');
    ASSERT EXISTS (SELECT 1 FROM stewards.scheduled_pipelines WHERE slug = 'verify100-cap-overflow' AND enabled = false),
        'OK 100e: the row itself should be persisted disabled (nothing lost)';

    -- Inverse leg: raise the cap and flip it on via schedule_update — the
    -- SAME row, no re-create, proving update re-checks the live cap too.
    UPDATE stewards.config SET value = '5'::jsonb WHERE key = 'schedule.max_enabled';
    v_result := stewards.schedule_update_tool(jsonb_build_object(
        'slug', 'verify100-cap-overflow', 'patch', jsonb_build_object('enabled', true)));
    ASSERT coalesce((v_result->>'ok')::boolean, false), format('OK 100e-inverse: update should succeed, got %s', v_result);
    ASSERT (v_result->'schedule'->>'enabled')::boolean = true,
        'OK 100e-inverse: raising the cap then flipping enabled=true should now actually enable the row';
    ASSERT (v_result->>'cap_note') IS NULL, 'OK 100e-inverse: no cap_note once comfortably under the raised cap';

    UPDATE stewards.config SET value = coalesce(v_prior, '12'::jsonb) WHERE key = 'schedule.max_enabled';

    RAISE NOTICE 'OK 100e: enabled cap — past cap(1) a new schedule lands DISABLED with a clear cap_note; raising the cap then re-enabling via schedule_update actually flips it on (inverse-verified, not coincidental)';
END;
$t$;

-- =====================================================================
-- OK 100f — schedule_update: flips enabled, changes cron, next_due_at
-- recomputes off the NEW pattern (not stale).
-- =====================================================================
DO $t$
DECLARE
    v_result jsonb;
    v_due    timestamptz;
BEGIN
    v_result := stewards.schedule_update_tool(jsonb_build_object(
        'slug', 'verify100-lab-nightly',
        'patch', jsonb_build_object('enabled', false, 'cron_pattern', '45 9 * * *', 'note', 'updated by OK-100f')
    ));

    ASSERT coalesce((v_result->>'ok')::boolean, false), format('OK 100f: schedule_update should succeed, got %s', v_result);
    ASSERT (v_result->'schedule'->>'enabled')::boolean = false, 'OK 100f: enabled should now be false';
    ASSERT (v_result->'schedule'->>'notes') = 'updated by OK-100f', 'OK 100f: notes should reflect the patch';

    v_due := (v_result->'schedule'->>'next_due_at')::timestamptz;
    ASSERT EXTRACT(MINUTE FROM (v_due AT TIME ZONE 'UTC'))::int = 45, 'OK 100f: next_due_at minute should match the NEW pattern (45), not the old (6)';
    ASSERT EXTRACT(HOUR FROM (v_due AT TIME ZONE 'UTC'))::int = 9, 'OK 100f: next_due_at hour should match the NEW pattern (9), not the old (3)';

    -- A rejected patch (bad cron) must leave the row UNCHANGED.
    v_result := stewards.schedule_update_tool(jsonb_build_object(
        'slug', 'verify100-lab-nightly', 'patch', jsonb_build_object('cron_pattern', '* * * * *')));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100f: a sub-hourly patch must be rejected';
    ASSERT (SELECT cron_pattern FROM stewards.scheduled_pipelines WHERE slug = 'verify100-lab-nightly') = '45 9 * * *',
        'OK 100f: a rejected patch must leave the existing cron_pattern untouched';

    RAISE NOTICE 'OK 100f: schedule_update — enabled flips, cron_pattern changes recompute next_due_at off the NEW pattern, and a rejected patch leaves the row unchanged';
END;
$t$;

-- =====================================================================
-- OK 100g — schedule_delete: round-trip (echoes what was deleted; the
-- row is actually gone; a repeat delete reports the honest not-found).
-- =====================================================================
DO $t$
DECLARE
    v_result jsonb;
BEGIN
    v_result := stewards.schedule_delete_tool(jsonb_build_object('slug', 'verify100-lab-nightly'));
    ASSERT coalesce((v_result->>'ok')::boolean, false), format('OK 100g: schedule_delete should succeed on an existing slug, got %s', v_result);
    ASSERT (v_result->'deleted'->>'slug') = 'verify100-lab-nightly', 'OK 100g: should echo the deleted row';
    ASSERT NOT EXISTS (SELECT 1 FROM stewards.scheduled_pipelines WHERE slug = 'verify100-lab-nightly'),
        'OK 100g: the row must actually be gone';

    v_result := stewards.schedule_delete_tool(jsonb_build_object('slug', 'verify100-lab-nightly'));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100g: deleting an already-gone slug should report a clean not-found, not raise';

    RAISE NOTICE 'OK 100g: schedule_delete — round-trips (echoes the deleted row, row is gone, repeat delete reports honest not-found)';
END;
$t$;

-- =====================================================================
-- OK 100h — grants: schedule_* resolve to 'allow' for work-item-chat
-- (longest-glob-wins beats the agent's own '*' deny).
-- =====================================================================
DO $t$
BEGIN
    ASSERT stewards.tool_permission('work-item-chat', 'schedule_create') = 'allow', 'OK 100h: schedule_create must be allowed for work-item-chat';
    ASSERT stewards.tool_permission('work-item-chat', 'schedule_list')   = 'allow', 'OK 100h: schedule_list must be allowed for work-item-chat';
    ASSERT stewards.tool_permission('work-item-chat', 'schedule_update') = 'allow', 'OK 100h: schedule_update must be allowed for work-item-chat';
    ASSERT stewards.tool_permission('work-item-chat', 'schedule_delete') = 'allow', 'OK 100h: schedule_delete must be allowed for work-item-chat';
    -- the agent's own base deny-'*' still holds for anything NOT explicitly allowed
    ASSERT stewards.tool_permission('work-item-chat', 'some_random_unlisted_tool') = 'deny',
        'OK 100h: work-item-chat''s base deny-''*'' should still hold for tools not explicitly allowed';

    ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name = 'schedule_create' AND active), 'OK 100h: schedule_create tool_def must be active';
    ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name = 'schedule_list'   AND active), 'OK 100h: schedule_list tool_def must be active';
    ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name = 'schedule_update' AND active), 'OK 100h: schedule_update tool_def must be active';
    ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name = 'schedule_delete' AND active), 'OK 100h: schedule_delete tool_def must be active';

    RAISE NOTICE 'OK 100h: all four schedule_* tools resolve to allow for work-item-chat (longest-glob-wins over the agent''s base deny), active tool_defs present';
END;
$t$;

-- =====================================================================
-- OK 100i — the realistic end-to-end shape from the mission brief:
--   1) schedule_create for pipeline_family 'crawl' — NOT present on this
--      scratch install (a sibling builder's file) — must fail with the
--      honest family-not-found error, not a crash.
--   2) the SAME shape against an existing family ('lab-regression') must
--      succeed end to end, including schedule_list surfacing it.
-- =====================================================================
DO $t$
DECLARE
    v_result jsonb;
BEGIN
    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'arxiv-llm-weekly',
        'pipeline_family', 'crawl',
        'cron_pattern', '0 6 * * 1',
        'input', jsonb_build_object(
            'url', 'https://arxiv.org/list/cs.CL/recent',
            'purpose', 'new findings about working with LLMs',
            'config', jsonb_build_object('max_pages', 15)
        )
    ));
    ASSERT (v_result->>'ok')::boolean = false, 'OK 100i: pipeline_family "crawl" is not installed on this scratch (a sibling builder''s file) — must fail honestly';
    ASSERT (v_result->>'error') LIKE '%no pipeline_family "crawl"%', format('OK 100i: error should name crawl specifically, got %L', v_result->>'error');
    RAISE NOTICE 'OK 100i (1/2): the arxiv-llm-weekly / pipeline_family=crawl shape correctly fails honest-not-found on this scratch (crawl lands via a sibling file)';

    -- Same shape, an existing family — the full happy path, mission-realistic.
    v_result := stewards.schedule_create_tool(jsonb_build_object(
        'slug', 'lab-regression-weekly',
        'pipeline_family', 'lab-regression',
        'cron_pattern', '0 6 * * 1',
        'input', '{}'::jsonb,
        'note', 'weekly instead of nightly, chat-authored'
    ));
    ASSERT coalesce((v_result->>'ok')::boolean, false), format('OK 100i: the same shape against an EXISTING family must succeed, got %s', v_result);
    ASSERT (v_result->'schedule'->>'next_due_at') IS NOT NULL, 'OK 100i: next_due_at should be present so chat can echo it';

    ASSERT EXISTS (
        SELECT 1 FROM jsonb_array_elements(stewards.schedule_list()) s
         WHERE s->>'slug' = 'lab-regression-weekly' AND s->>'pipeline_family' = 'lab-regression'
    ), 'OK 100i: schedule_list should surface the newly created schedule';

    RAISE NOTICE 'OK 100i (2/2): the identical shape against an existing family (lab-regression) succeeds end to end and is visible via schedule_list -- the ONLY thing standing between chat and a live cron job is a real pipeline_family, exactly as designed';
END;
$t$;

-- ---------------------------------------------------------------------
-- Cleanup — leave no test rows behind.
-- ---------------------------------------------------------------------
DELETE FROM stewards.scheduled_pipelines WHERE slug LIKE 'verify100%' OR slug IN ('arxiv-llm-weekly', 'lab-regression-weekly');

DO $t$ BEGIN RAISE NOTICE '== ALL verify-100-schedule-chat ASSERTIONS PASSED =='; END; $t$;
