-- =====================================================================
-- tests/virgin-smoke.sql — the authoritative virgin-boot test
-- =====================================================================
-- Run against a FRESH Postgres (pgvector image) with the pg_ai_stewards
-- extension installed. Proves the authored chain (00→19) installs cleanly
-- and the clean-room invariants hold. Uses plpgsql ASSERT so a regression
-- makes psql exit non-zero (CI goes red), not just print.
--
--   docker build -t stewards-oss-pg:test extension/
--   docker run -d --name t -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=x \
--       -e POSTGRES_DB=stewards stewards-oss-pg:test \
--       -c shared_preload_libraries=pg_ai_stewards
--   psql ... -v ON_ERROR_STOP=1 -f tests/virgin-smoke.sql
--
-- See tests/README.md. The CI workflow (.github/workflows/ci.yml) runs exactly this.
-- =====================================================================
\set ON_ERROR_STOP on

\echo '== install (virgin, CASCADE pulls in vector) =='
CREATE EXTENSION pg_ai_stewards CASCADE;

-- ---------------------------------------------------------------------
-- 1. Dependency surface — vector ONLY. No pgcrypto, no AGE.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    ASSERT EXISTS (SELECT 1 FROM pg_extension WHERE extname='vector'),
        'vector extension must be installed (CASCADE)';
    ASSERT NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='pgcrypto'),
        'pgcrypto must NOT be required (sha256/gen_random_uuid are built-in)';
    ASSERT NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname='age'),
        'AGE must NOT be installed (the graph is relational)';
    ASSERT NOT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name='age'),
        'AGE must NOT even be available in the image';
    RAISE NOTICE 'OK 1: dependency surface = vector only (no pgcrypto, no AGE)';
END $$;

-- ---------------------------------------------------------------------
-- 2. The doc_* rename swept fully — zero study_* functions, tables, columns.
-- ---------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
     WHERE ns.nspname='stewards' AND p.proname LIKE 'study%';
    ASSERT n=0, format('expected 0 study%% functions, found %s', n);

    SELECT count(*) INTO n FROM information_schema.tables
     WHERE table_schema='stewards' AND table_name LIKE 'study%';
    ASSERT n=0, format('expected 0 study%% tables, found %s', n);

    SELECT count(*) INTO n FROM information_schema.columns
     WHERE table_schema='stewards' AND column_name='study_id';
    ASSERT n=0, format('expected 0 study_id columns, found %s', n);

    ASSERT EXISTS (SELECT 1 FROM information_schema.tables
                    WHERE table_schema='stewards' AND table_name='docs'),
        'stewards.docs (the renamed studies table) must exist';
    RAISE NOTICE 'OK 2: doc_* rename complete (0 study%% fns/tables/cols; docs present)';
END $$;

-- ---------------------------------------------------------------------
-- 3. A representative object from each authored subsystem (00→19) exists.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    want_fn text[] := ARRAY[
        'config_get_text',            -- 00 config
        'graph_walk',                 -- 01 graph (relational)
        'import_workstream',          -- 02 workstreams / docs
        'work_item_create',           -- 04 work-items
        'estimate_chat_tokens',       -- 03 watchman
        'steward_tick',               -- 07 steward
        'apply_gate_decision',        -- 08/11 gates+trust
        'seed_intents_from_yaml',     -- 09 intents
        'compose_messages',           -- 15b context surface
        'extract_engrams',            -- 15a context engrams
        'spawn_subagent_create',      -- 16 subagents
        'compose_tools',              -- 16 (final)
        'self_prompt_on',             -- 16 ct2-7e
        'cron_next_after',            -- 18 scheduler
        'scheduled_pipelines_fire',   -- 18
        'model_usable',               -- 19 models
        'work_item_dispatch_stage'    -- 19 dispatch FINAL
    ];
    f text;
BEGIN
    FOREACH f IN ARRAY want_fn LOOP
        ASSERT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
                        WHERE ns.nspname='stewards' AND p.proname=f),
            format('missing expected function stewards.%s', f);
    END LOOP;

    -- The dispatch FINAL must carry all four accreted layers.
    ASSERT (SELECT prosrc LIKE '%catalog_default_provider%' AND prosrc LIKE '%pick_usable_model%'
                   AND prosrc LIKE '%provider_cap_exceeded%' AND prosrc LIKE '%{body,max_tokens}%'
              FROM pg_proc p JOIN pg_namespace ns ON ns.oid=p.pronamespace
             WHERE ns.nspname='stewards' AND p.proname='work_item_dispatch_stage'),
        'work_item_dispatch_stage must carry all 4 dispatch layers (J.8.a + M.2 + J.11 + R.3)';
    RAISE NOTICE 'OK 3: every authored subsystem 00→19 has its representative object';
END $$;

-- ---------------------------------------------------------------------
-- 3b. The generic `research` agent is core-seeded + web-capable. Its
-- pipelines (planning, research-write, research-summary, echo-test) name
-- agent_family='research'; without the agent row a virgin dispatch fails
-- "no agent variant resolved". (Regression guard for the 2026-06-15 fix.)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    ASSERT EXISTS (SELECT 1 FROM stewards.agents
                    WHERE family='research' AND model_match='*' AND active),
        'the generic research agent must be core-seeded (planning/research/echo-test run on it)';
    ASSERT EXISTS (SELECT 1 FROM stewards.agent_tool_perms
                    WHERE agent_family='research' AND tool_pattern='web_search_exa' AND action='allow'),
        'the research agent must be granted web_search_exa (external research out of the box)';
    RAISE NOTICE 'OK 3b: generic research agent seeded + web-capable';
END $$;

-- ---------------------------------------------------------------------
-- 4. Clean-room: no operator / personal seeds leaked into core.
-- ---------------------------------------------------------------------
DO $$
DECLARE n int;
BEGIN
    -- Operator-configured runtime tables start empty (seeds live in the overlay).
    SELECT count(*) INTO n FROM stewards.scheduled_pipelines;
    ASSERT n=0, format('scheduled_pipelines must be empty in core, found %s', n);
    SELECT count(*) INTO n FROM stewards.model_capability;
    ASSERT n=0, format('model_capability must be empty in core, found %s', n);
    SELECT count(*) INTO n FROM stewards.model_pricing;
    ASSERT n=0, format('model_pricing must be empty in core, found %s', n);

    -- No workspace-specific persona families.
    SELECT count(*) INTO n FROM stewards.agents
     WHERE family IN ('codewright','librarian','gamemaster','callie');
    ASSERT n=0, format('workspace personas must NOT be in core, found %s', n);

    -- No personal intent slugs (only the generic 'default' may be seeded — and
    -- even that is seeded at runtime, so core ships zero intents).
    SELECT count(*) INTO n FROM stewards.intents WHERE slug IN ('scripture-study');
    ASSERT n=0, format('personal intent slugs must NOT be in core, found %s', n);

    -- mcp_servers: only generic core servers (fs-read, pg-ai-stewards, coder,
    -- fetch-md, git, exa-search). Web search via Exa's keyless free tier IS a
    -- core default (works out of the box). No DOMAIN/personal servers
    -- (gospel-engine, webster, yt, the old DuckDuckGo `search`, etc.) leak in.
    SELECT count(*) INTO n FROM stewards.mcp_servers
     WHERE name IN ('gospel-engine','gospel-engine-v2','webster','yt','search',
                    'byu-citations','becoming','strongs');
    ASSERT n=0, format('personal MCP servers must NOT be in core, found %s', n);
    ASSERT (SELECT count(*) FROM stewards.mcp_servers
             WHERE name IN ('fs-read','pg-ai-stewards','fetch-md','git','exa-search')) = 5,
        'the generic core MCP servers (fs-read, pg-ai-stewards, fetch-md, git, exa-search) must be seeded';
    RAISE NOTICE 'OK 4: no operator/personal seeds leaked (empty registries, no workspace personas, core MCP only)';
END $$;

-- ---------------------------------------------------------------------
-- 5. Functional spine, end to end: intent → work_item → dispatch → work_queue.
--    Proves the core actually runs, with the dispatch FINAL's capability path.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_intent uuid;
    v_wid    uuid;
    v_model  text;
    v_capped text;
BEGIN
    -- Seed the default intent (a runtime op; core ships none).
    INSERT INTO stewards.intents (slug, purpose) VALUES ('default','virgin smoke')
    ON CONFLICT (slug) DO NOTHING;

    -- A minimal agent + one-shot pipeline whose stage resolves to an UNUSABLE
    -- model, so dispatch must substitute the (usable-by-default) catalog default.
    INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
    VALUES ('smoke','*','virgin smoke agent','primary','You are a smoke agent.',0.2)
    ON CONFLICT (family, model_match) DO UPDATE SET prompt=EXCLUDED.prompt;

    INSERT INTO stewards.model_capability (provider, model, usable)
    VALUES ('opencode_go','smoke-bad',false)
    ON CONFLICT (provider, model) DO UPDATE SET usable=false;

    INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled,
        file_destination_template, file_content_jsonpath, maturity_ladder, auto_materialize_on_verified, metadata)
    VALUES ('smoke-pipe','virgin smoke pipeline',
      '[{"name":"work","next":null,"model":"smoke-bad","agent_family":"smoke","auto_advance":false,"input_template":"{{input.binding_question}}"}]'::jsonb,
      false,false,NULL,NULL,'["raw","verified"]'::jsonb,false,'{}'::jsonb)
    ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages;

    SELECT id INTO v_intent FROM stewards.intents WHERE slug='default';
    v_wid := stewards.work_item_create('smoke-pipe','{"binding_question":"hello"}'::jsonb,'smoke-wi','tester',NULL,v_intent);
    PERFORM stewards.work_item_dispatch_stage(v_wid);

    SELECT payload->>'requested_model' INTO v_model
      FROM stewards.work_queue
     WHERE kind='chat' AND payload->>'_work_item_id' = v_wid::text;

    ASSERT v_model = 'kimi-k2.6',
        format('dispatch should substitute the unusable model with the catalog default kimi-k2.6, got %s', v_model);
    ASSERT EXISTS (SELECT 1 FROM stewards.model_substitutions
                    WHERE pipeline_family='smoke-pipe' AND reason LIKE 'capability:%'),
        'the capability substitution must be logged with a reason';
    ASSERT stewards.provider_cap_exceeded('opencode_go') = false,
        'an uncapped provider must never be gated';
    RAISE NOTICE 'OK 5: spine runs e2e (intent→work_item→dispatch); capability substitution + logging work';
END $$;

-- ── 6. compact_context (M5) ships in core, as a tools-off judge ──────────
DO $$
BEGIN
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='compact_context_surface')
       AND EXISTS (SELECT 1 FROM pg_proc WHERE proname='compact_context_apply'),
        'compact_context surface + apply functions must ship in core';
    -- the compactor is a TOOLS-OFF judge (it returns a verdict; the substrate acts)
    ASSERT EXISTS (SELECT 1 FROM stewards.agents
                    WHERE family='compactor' AND context_tools_enabled = false),
        'the compactor agent must ship tools-off (judges, not executes)';
    ASSERT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family='compact-context'),
        'the compact-context pipeline must ship in core';
    ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name='compact_context' AND active),
        'the compact_context tool_def must ship active';
    -- the ≥threshold nudge knob is seeded
    ASSERT EXISTS (SELECT 1 FROM stewards.config WHERE key='compact_context_suggest_tokens'),
        'the compact_context_suggest_tokens nudge threshold must be seeded';
    RAISE NOTICE 'OK 6: compact_context ships (tools-off compactor + surface/apply + tool_def + nudge config)';
END $$;

-- ── 7. reflect-steward (22) operator surface ships in core ───────────────────
DO $$
BEGIN
    -- kill switch: global flag + the verbs + the capacity-gated drain
    ASSERT EXISTS (SELECT 1 FROM stewards.config WHERE key='autonomy_paused'),
        'the global kill switch config autonomy_paused must be seeded';
    ASSERT EXISTS (SELECT 1 FROM stewards.config WHERE key='reflect_max_concurrent'),
        'the drain capacity cap reflect_max_concurrent must be seeded';
    ASSERT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='stewards'
               AND p.proname IN ('reflect_pause','reflect_resume','reflect_pause_intent',
                   'reflect_resume_intent','reflect_status','reflect_proposals',
                   'reflect_approve','reflect_decline','reflect_steer','reflect_drain_approved')) = 10,
        'all reflect-steward verbs + the drain must ship in core';
    -- the queue + control tables
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='reflect_approvals')
       AND EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='reflect_intent_paused'),
        'reflect_approvals + reflect_intent_paused tables must ship';
    -- the gathered-source dedup ledger + its tools (the "don't re-scrub" memory)
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='intent_source_ledger'),
        'the per-intent gathered-source ledger must ship';
    ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name='intent_sources_recent' AND active)
       AND EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name='intent_source_record' AND active),
        'the dedup tools (intent_sources_recent/record) must ship active';
    -- project-neighborhood knowledge scoping (controlled bleed)
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='project_neighborhood'),
        'the project_neighborhood table must ship';
    ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name='pool_search' AND active),
        'the scoped pool_search tool must ship active';
    ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name='intent_work_survey' AND active),
        'the council/anti-dup intent_work_survey tool must ship active';
    -- core ships NO neighborhood rows (operator data) — a fresh project is isolated
    ASSERT (SELECT count(*) FROM stewards.project_neighborhood) = 0,
        'project_neighborhood must be empty in core (cross-pollination is operator config)';
    -- the scheduler gates on the kill switch (re-authored fire carries the check)
    ASSERT (SELECT prosrc LIKE '%autonomy_paused%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='stewards' AND p.proname='scheduled_pipelines_fire'),
        'scheduled_pipelines_fire must gate on autonomy_paused';
    -- core ships NO scheduled reflect runs (operator/overlay data); paused by default
    ASSERT stewards.config_get_text('autonomy_paused','x') = 'false',
        'autonomy_paused must default to false (off, but no schedules seeded in core)';
    RAISE NOTICE 'OK 7: reflect-steward surface ships (kill switch + verbs + capacity-gated drain + scheduler gate)';
END $$;

-- ── 8. reflect-watchman (23) self-presiding guard ships + ACTS ───────────────
DO $$
DECLARE v_breach text;
BEGIN
    -- the threshold configs
    ASSERT (SELECT count(*) FROM stewards.config WHERE key IN
            ('reflect_guard_enabled','reflect_guard_max_in_flight','reflect_guard_max_proposals_pending',
             'reflect_guard_max_consecutive_failures','reflect_guard_spend_window_hours','reflect_guard_spend_cap_micro')) = 6,
        'all reflect-guard threshold configs must be seeded';
    -- the guard surface: signals + tick + trips verb + the accounting ledger
    ASSERT (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='stewards'
               AND p.proname IN ('reflect_guard_signals','reflect_watchman_tick','reflect_guard_trips')) = 3,
        'the guard functions (signals/tick/trips) must ship';
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='reflect_guard_log'),
        'the reflect_guard_log accounting ledger must ship';
    -- reflect_status surfaces the guard; the heartbeat runs the guard
    ASSERT (stewards.reflect_status() ? 'guard'),
        'reflect_status must surface the guard signals';
    ASSERT (SELECT prosrc LIKE '%reflect_watchman_tick%' FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='stewards' AND p.proname='watchman_scheduler_fire'),
        'watchman_scheduler_fire must call reflect_watchman_tick each tick';
    -- nominal on a virgin system: no breach, no action
    ASSERT (stewards.reflect_guard_signals()->>'would_trip') = 'false',
        'a virgin system must not trip the guard';
    ASSERT stewards.reflect_watchman_tick() IS NULL,
        'the tick must be a no-op (NULL) when nominal';

    -- INVERSE: force a breach (cap in_flight at 0 → value 0 >= 0 trips), prove it ACTS.
    PERFORM stewards.config_set('reflect_guard_max_in_flight', '0'::jsonb, NULL);
    v_breach := stewards.reflect_watchman_tick();
    ASSERT v_breach IS NOT NULL, 'a forced breach must return a non-null breach';
    ASSERT stewards.config_get_text('autonomy_paused','x') = 'true',
        'a breach must auto-pause autonomy (the emergency force)';
    ASSERT (SELECT count(*) FROM stewards.reflect_guard_log) = 1,
        'a breach must be accounted for — exactly one reflect_guard_log row';
    -- idempotent: ticking again while paused is a no-op (no log spam, no re-trip)
    ASSERT stewards.reflect_watchman_tick() IS NULL,
        'the tick must be a no-op once autonomy is already paused';
    ASSERT (SELECT count(*) FROM stewards.reflect_guard_log) = 1,
        'an already-paused system must not re-log trips';

    -- restore virgin state (resume + reset threshold + clear the test trip)
    PERFORM stewards.reflect_resume();
    PERFORM stewards.config_set('reflect_guard_max_in_flight', '8'::jsonb, NULL);
    DELETE FROM stewards.reflect_guard_log;
    RAISE NOTICE 'OK 8: self-presiding watchman guard ships + acts (auto-pause + accounting + idempotent; inverse-proven)';
END $$;

-- ── 9. skills (24) — the 3-tier catalog ships + tiers/levers/budget work ──────
DO $$
DECLARE
    v0 text; v1 text; v2 text;
    v_tools jsonb; v_load jsonb; v_over jsonb;
BEGIN
    -- the surface ships: the new tables, the budget config, the four levers, the render fn
    ASSERT (SELECT count(*) FROM information_schema.tables WHERE table_schema='stewards'
             AND table_name IN ('skill_groups','session_skills','session_skill_groups')) = 3,
        'the skills tables (skill_groups/session_skills/session_skill_groups) must ship';
    ASSERT stewards.config_get_text('skill_loaded_budget_tokens','x') = '4000',
        'the loaded-skill budget config must seed';
    ASSERT (SELECT count(*) FROM stewards.tool_defs WHERE active AND name IN
             ('skill_load','skill_unload','skill_group_open','skill_group_close')) = 4,
        'the four skill levers must ship as tool_defs';
    ASSERT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname='stewards' AND p.proname='render_skills_block'),
        'render_skills_block must ship';
    ASSERT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='stewards'
                    AND table_name='skills' AND column_name='group_family'),
        'the skills table must gain group_family';

    -- an agent explicitly DENIED the 'skill' permission gets no catalog and no levers
    -- (core ships 2 ungrouped skills — reference-linking, source-verification — so
    -- the deny gate, not emptiness, is what hides the surface).
    INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action)
      VALUES ('smoke-skilldeny','skill','deny');
    v_tools := stewards.compose_tools('smoke-skilldeny');
    ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_tools) e WHERE e->'function'->>'name' = 'skill_load'),
        'skill levers must be hidden for an agent denied the skill permission';
    ASSERT stewards.render_skills_block('smoke-skilldeny','test-model','smoke-sess') IS NULL,
        'the skills catalog must be empty for a skill-denied agent';
    DELETE FROM stewards.agent_tool_perms WHERE agent_family='smoke-skilldeny';

    -- seed a throwaway group + two grouped skills (cleaned up below)
    INSERT INTO stewards.skill_groups (family,name,summary,applies_to)
      VALUES ('smoke-story','Smoke Story','narrative-craft skills (smoke fixture)','smoke-skills');
    INSERT INTO stewards.skills (family,model_match,description,body,group_family) VALUES
      ('smoke-villains','*','antagonists with real motivation','BODY: villains want something specific and think they are right.','smoke-story'),
      ('smoke-pacing','*','therefore/but scene momentum','BODY: connect every beat by therefore or but, never and then.','smoke-story');

    -- the levers now surface for an agent the group applies to
    v_tools := stewards.compose_tools('smoke-skills');
    ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(v_tools) e WHERE e->'function'->>'name' = 'skill_load'),
        'skill levers must surface once a group applies to the agent';

    -- TIER 0 (nothing opened): the group summary shows; its skills stay hidden
    v0 := stewards.render_skills_block('smoke-skills','test-model','smoke-sess');
    ASSERT v0 LIKE '%<group name="smoke-story">%', 'tier 0: the closed group summary must render';
    ASSERT v0 NOT LIKE '%smoke-villains%', 'tier 0: a closed group''s skills must be hidden';

    -- TIER 1 (open the group): the skills'' frontmatter appears, bodies still hidden
    PERFORM stewards.skill_group_open_tool(jsonb_build_object('_session_id','smoke-sess','group','smoke-story'));
    v1 := stewards.render_skills_block('smoke-skills','test-model','smoke-sess');
    ASSERT v1 LIKE '%<name>smoke-villains</name>%', 'tier 1: an opened group must list its skills'' frontmatter';
    ASSERT v1 NOT LIKE '%BODY: villains%', 'tier 1: a skill body stays hidden until loaded';

    -- TIER 2 (load one): the body appears under loaded_skills, its frontmatter drops out
    v_load := stewards.skill_load_tool(jsonb_build_object('_session_id','smoke-sess','skill','smoke-villains'));
    ASSERT (v_load->>'ok') = 'true', 'skill_load must succeed within budget';
    v2 := stewards.render_skills_block('smoke-skills','test-model','smoke-sess');
    ASSERT v2 LIKE '%<loaded_skills>%' AND v2 LIKE '%BODY: villains%', 'tier 2: a loaded skill''s body must render';
    ASSERT v2 NOT LIKE '%<name>smoke-villains</name>%', 'tier 2: a loaded skill drops out of the frontmatter list';

    -- BUDGET: tighten to 1 token → loading another body must be REFUSED (no eviction)
    PERFORM stewards.config_set('skill_loaded_budget_tokens', '1'::jsonb, NULL);
    v_over := stewards.skill_load_tool(jsonb_build_object('_session_id','smoke-sess','skill','smoke-pacing'));
    ASSERT (v_over ? 'error'), 'a skill_load over budget must be refused';
    ASSERT NOT EXISTS (SELECT 1 FROM stewards.session_skills WHERE session_id='smoke-sess' AND family='smoke-pacing'),
        'a refused load must not be recorded';

    -- restore virgin state
    PERFORM stewards.config_set('skill_loaded_budget_tokens', '4000'::jsonb, NULL);
    DELETE FROM stewards.session_skills       WHERE session_id='smoke-sess';
    DELETE FROM stewards.session_skill_groups WHERE session_id='smoke-sess';
    DELETE FROM stewards.skills               WHERE group_family='smoke-story';
    DELETE FROM stewards.skill_groups         WHERE family='smoke-story';
    RAISE NOTICE 'OK 9: skills 3-tier catalog ships + tiers/levers/budget proven (summary -> frontmatter -> loaded body; over-budget refused)';
END $$;

\echo '== ALL VIRGIN-SMOKE ASSERTIONS PASSED — the authored chain (00→24) is sound =='
