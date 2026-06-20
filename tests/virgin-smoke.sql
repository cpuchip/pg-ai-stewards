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
    -- a group's applies_to is a comma-separated list of family globs (multi-family)
    ASSERT stewards.group_applies('fiction,gamemaster','gamemaster')
       AND stewards.group_applies('fiction,gamemaster','fiction')
       AND NOT stewards.group_applies('fiction,gamemaster','librarian'),
        'group_applies must match any family in the comma list and reject others';

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

-- ── 10. corpus (25) — pool-publish decoupled from file-materialize + the map ──
DO $$
DECLARE
    v_intent uuid; v_wid uuid; v_wid2 uuid; v_proj text; v_pooled int;
BEGIN
    -- the machinery ships
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='intent_project_map'),
        'intent_project_map must ship';
    ASSERT EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
                    WHERE n.nspname='stewards' AND p.proname='fill_project_association'),
        'fill_project_association must ship';
    ASSERT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='work_items_fill_project'),
        'the BEFORE-INSERT fill trigger must be installed';
    -- core seeds an EMPTY map (the operator overlay fills it)
    ASSERT (SELECT count(*) FROM stewards.intent_project_map) = 0,
        'core must seed no intent→project mappings (overlay data)';

    SELECT id INTO v_intent FROM stewards.intents WHERE slug='default';
    INSERT INTO stewards.projects (slug, name) VALUES ('smoke-corpus','Smoke Corpus') ON CONFLICT DO NOTHING;
    -- a digest-style pipeline: auto_materialize OFF, no file_destination (writes its
    -- own file via fs tools in real life) — the case that never pooled before.
    INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled,
        file_destination_template, file_content_jsonpath, maturity_ladder, auto_materialize_on_verified, metadata)
    VALUES ('smoke-digest','virgin smoke digest',
      '[{"name":"digest","next":null,"agent_family":"smoke","auto_advance":false,"input_template":"{{input.binding_question}}"}]'::jsonb,
      false,false,NULL,NULL,'["raw","verified"]'::jsonb,false,'{}'::jsonb)
    ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, auto_materialize_on_verified=false;

    -- TRIGGER: a work_item under a mapped intent (project exists) gets project-tagged
    INSERT INTO stewards.intent_project_map (intent_slug, project_association) VALUES ('default','smoke-corpus');
    v_wid := stewards.work_item_create('smoke-digest','{"binding_question":"corpus q"}'::jsonb,'smoke-corpus-wi','tester',NULL,v_intent);
    SELECT project_association INTO v_proj FROM stewards.work_items WHERE id=v_wid;
    ASSERT v_proj = 'smoke-corpus',
        format('the fill trigger must tag a mapped intent''s work_item with its project, got %s', v_proj);

    -- DECOUPLE: this work_item has NO file_destination + auto_materialize OFF; flipping
    -- it to verified must STILL publish to the docs pool (the corpus-treatment fix).
    UPDATE stewards.work_items
       SET stage_results = '{"digest":{"output":"DIGEST: corpus body with a [ref](https://example.com)."}}'::jsonb
     WHERE id=v_wid;
    UPDATE stewards.work_items SET maturity='verified' WHERE id=v_wid;
    SELECT count(*) INTO v_pooled FROM stewards.docs WHERE slug='smoke-corpus-wi' AND project_association='smoke-corpus';
    ASSERT v_pooled = 1,
        'a verified, project-tagged work_item with NO file_destination must still publish to the pool (decoupled)';

    -- FK-GUARD: a map row pointing at a NON-existent project must not break inserts
    UPDATE stewards.intent_project_map SET project_association='no-such-project' WHERE intent_slug='default';
    v_wid2 := stewards.work_item_create('smoke-digest','{"binding_question":"q2"}'::jsonb,'smoke-corpus-wi2','tester',NULL,v_intent);
    SELECT project_association INTO v_proj FROM stewards.work_items WHERE id=v_wid2;
    ASSERT v_proj IS NULL,
        'the fill trigger must NOT set a project that does not exist (FK-safe)';

    -- restore virgin state
    DELETE FROM stewards.docs WHERE slug='smoke-corpus-wi';
    DELETE FROM stewards.work_items WHERE id IN (v_wid, v_wid2);
    DELETE FROM stewards.intent_project_map WHERE intent_slug='default';
    DELETE FROM stewards.pipelines WHERE family='smoke-digest';
    DELETE FROM stewards.projects WHERE slug='smoke-corpus';
    RAISE NOTICE 'OK 10: corpus pool-publish decoupled (project-tagged verified pools w/o a file) + intent→project fill trigger (FK-safe)';
END $$;

-- ── 11. planner dedup — the near-duplicate enqueue gate + survey studies ─────
DO $$
DECLARE
    v_intent uuid; v_ex uuid; v_pl uuid;
    v_dup_q  text := 'What are the top customer complaint categories in the product BBB profile';
    v_diff_q text := 'What do third party benchmarks reveal about product camera video latency';
    v_existing_q text := 'What are the most frequent customer complaints about the product on the BBB';
BEGIN
    -- the helper + the tunable threshold ship
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='binding_question_overlap'),
        'binding_question_overlap must ship';
    ASSERT stewards.config_get_text('reflect_dedup_overlap_threshold','x') = '0.5',
        'the dedup threshold config must seed at 0.5';
    -- the metric: a reworded near-duplicate scores high; a distinct topic scores low
    ASSERT stewards.binding_question_overlap(v_existing_q, v_dup_q) >= 0.5,
        format('a reworded near-duplicate must score >= 0.5, got %s', stewards.binding_question_overlap(v_existing_q, v_dup_q));
    ASSERT stewards.binding_question_overlap(v_existing_q, v_diff_q) < 0.5,
        format('a distinct topic must score < 0.5, got %s', stewards.binding_question_overlap(v_existing_q, v_diff_q));

    SELECT id INTO v_intent FROM stewards.intents WHERE slug='default';

    -- an existing PENDING proposal for the intent
    v_ex := stewards.work_item_create('smoke-pipe',
              jsonb_build_object('binding_question', v_existing_q), 'dq-existing-bbb','tester',NULL,v_intent);
    UPDATE stewards.work_items SET origin='agent_planning', status='pending' WHERE id=v_ex;

    -- a planning run proposing [near-duplicate, distinct]
    v_pl := stewards.work_item_create('smoke-pipe', '{"binding_question":"plan dq"}'::jsonb,'dq-planner','tester',NULL,v_intent);
    UPDATE stewards.work_items
       SET pipeline_family='planning',
           stage_results = jsonb_build_object('propose_work', jsonb_build_object('output',
             format('[{"slug":"dq-bbb-categories","binding_question":"%s","pipeline_family_hint":"research-write","rationale":"check the bbb categories"},{"slug":"dq-camera-latency","binding_question":"%s","pipeline_family_hint":"research-write","rationale":"benchmark camera latency"}]',
                    v_dup_q, v_diff_q)))
     WHERE id=v_pl;
    PERFORM stewards.enqueue_proposed_work_items(v_pl);

    ASSERT NOT EXISTS (SELECT 1 FROM stewards.work_items WHERE slug='dq-bbb-categories'),
        'the near-duplicate proposal must be gated (not enqueued)';
    ASSERT EXISTS (SELECT 1 FROM stewards.work_items WHERE slug='dq-camera-latency'),
        'the distinct proposal must be enqueued';

    -- the survey now carries existing_studies (the pool gists) for the planner
    ASSERT (stewards.intent_work_survey_tool(jsonb_build_object('intent','default'))::jsonb ? 'existing_studies'),
        'intent_work_survey must surface existing_studies';

    -- restore virgin state
    DELETE FROM stewards.work_items WHERE slug IN ('dq-existing-bbb','dq-planner','dq-camera-latency');
    RAISE NOTICE 'OK 11: planner dedup — near-dup enqueue gate works (reworded gated, distinct kept) + survey carries existing_studies';
END $$;

-- ── 12. productivity (26) — todos/goals coupled to the tag lifecycle ─────────
DO $$
DECLARE v_sess text := 'smoke-todo-sess'; v_r jsonb; v_agenda text; v_state text;
BEGIN
    -- surface ships
    ASSERT (SELECT count(*) FROM information_schema.tables WHERE table_schema='stewards'
             AND table_name IN ('session_todos','session_goals')) = 2,
        'the todo/goal tables must ship';
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='render_agenda'), 'render_agenda must ship';
    ASSERT (SELECT count(*) FROM stewards.tool_defs WHERE active AND name IN
             ('todo_add','todo_done','todo_reopen','todo_focus','todo_list','goal_set')) = 6,
        'the 6 productivity tools must ship';
    ASSERT stewards.config_get_text('todo_autofold_on_done','x') = 'true', 'autofold config must seed true';

    -- a session + the loop: goal_set, todo_add (active + working_tag), tag a message
    INSERT INTO stewards.sessions (id) VALUES (v_sess) ON CONFLICT DO NOTHING;
    PERFORM stewards.goal_set_tool(jsonb_build_object('_session_id',v_sess,'goal','prove the todo loop'));
    v_r := stewards.todo_add_tool(jsonb_build_object('_session_id',v_sess,'title','Decouple the widget'));
    ASSERT (v_r->>'ok')='true' AND (v_r->>'slug')='decouple-the-widget', 'todo_add opens + slugifies';
    ASSERT (SELECT working_tag FROM stewards.sessions WHERE id=v_sess) = 'todo:decouple-the-widget',
        'the active todo sets sessions.working_tag (auto-stamp)';
    -- simulate work done under the active todo (a message bearing its tag)
    INSERT INTO stewards.messages (session_id, role, content, context_tags)
    VALUES (v_sess, 'assistant', 'working the widget', ARRAY['todo:decouple-the-widget']);

    -- AGENDA renders the goal + open todo
    v_agenda := stewards.render_agenda(v_sess);
    ASSERT v_agenda LIKE '%Goal: prove the todo loop%' AND v_agenda LIKE '%decouple-the-widget%',
        'render_agenda must show the goal + open todo';

    -- todo_done → marked done + AUTO-FOLD the tagged message (context_state→muted)
    v_r := stewards.todo_done_tool(jsonb_build_object('_session_id',v_sess,'slug','decouple-the-widget'));
    ASSERT (v_r->>'ok')='true' AND (v_r->>'folded')='true', 'todo_done must auto-fold';
    ASSERT (SELECT status FROM stewards.session_todos WHERE session_id=v_sess AND slug='decouple-the-widget')='done',
        'the todo must be marked done';
    SELECT context_state INTO v_state FROM stewards.messages WHERE session_id=v_sess AND context_tags @> ARRAY['todo:decouple-the-widget'];
    ASSERT v_state = 'muted', format('the tagged message must be folded (muted) after todo_done, got %s', v_state);

    -- todo_reopen → restores the message to verbatim
    PERFORM stewards.todo_reopen_tool(jsonb_build_object('_session_id',v_sess,'slug','decouple-the-widget'));
    SELECT context_state INTO v_state FROM stewards.messages WHERE session_id=v_sess AND context_tags @> ARRAY['todo:decouple-the-widget'];
    ASSERT v_state = 'verbatim', format('todo_reopen must restore the message to verbatim, got %s', v_state);

    -- restore virgin state
    DELETE FROM stewards.messages WHERE session_id=v_sess;
    DELETE FROM stewards.session_todos WHERE session_id=v_sess;
    DELETE FROM stewards.session_goals WHERE session_id=v_sess;
    DELETE FROM stewards.sessions WHERE id=v_sess;
    RAISE NOTICE 'OK 12: productivity surface — goal_set + todo_add (active+tag) + auto-fold on done + reopen restore (todo<->tag coupling proven)';
END $$;

-- ── 13: context_search (27) — grep over own + descendants, folded recovery, the wall
DO $$
DECLARE
    v_p text := 'smoke-cs-parent';
    v_c text := 'smoke-cs-child';
    v_intent uuid; v_pwi uuid; v_cwi uuid;
    v_r jsonb; v_handle text; v_resolved bigint;
BEGIN
    ASSERT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='stewards'
            AND table_name='sessions' AND column_name='private'), 'sessions.private must ship';
    ASSERT (SELECT count(*) FROM stewards.tool_defs WHERE active AND name IN
            ('context_search','context_session_private')) = 2, 'the 2 context_search tools must ship';
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='context_descendant_sessions'),
            'context_descendant_sessions must ship';

    -- seed: intent + pipeline + parent/child sessions + a parent->child work_item lineage
    INSERT INTO stewards.intents (slug,purpose) VALUES ('cs-smoke','context_search smoke')
      ON CONFLICT (slug) DO NOTHING;
    SELECT id INTO v_intent FROM stewards.intents WHERE slug='cs-smoke';
    INSERT INTO stewards.pipelines (family,stages) VALUES ('cs-smoke-pipe','[{"name":"s"}]'::jsonb)
      ON CONFLICT (family) DO NOTHING;
    INSERT INTO stewards.sessions (id,kind) VALUES (v_p,'agent'),(v_c,'agent') ON CONFLICT DO NOTHING;
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,session_ids,slug)
      VALUES ('cs-smoke-pipe','s',v_intent,ARRAY[v_p],'cs-parent') RETURNING id INTO v_pwi;
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,session_ids,parent_work_item_id,slug)
      VALUES ('cs-smoke-pipe','s',v_intent,ARRAY[v_c],v_pwi,'cs-child') RETURNING id INTO v_cwi;

    -- messages: parent verbatim + parent folded (muted via the real path) + child verbatim
    INSERT INTO stewards.messages (session_id,role,content)
      VALUES (v_p,'assistant','the WIDGET decision: ship it');
    INSERT INTO stewards.messages (session_id,role,content,context_tags)
      VALUES (v_p,'assistant','a folded WIDGET note',ARRAY['cs-fold']);
    PERFORM stewards.context_mute_tag_tool(jsonb_build_object('_session_id',v_p,'tag','cs-fold'));
    INSERT INTO stewards.messages (session_id,role,content)
      VALUES (v_c,'assistant','child found a WIDGET bug');

    -- (1) own session, curated default: finds the verbatim, NOT the folded
    v_r := stewards.context_search_tool(jsonb_build_object('_session_id',v_p,'pattern','widget'));
    ASSERT (v_r->>'count')::int = 1,
        format('own curated search must find 1 (verbatim only), got %s', v_r->>'count');

    -- (2) include_folded: finds both parent messages
    v_r := stewards.context_search_tool(jsonb_build_object('_session_id',v_p,'pattern','widget','include_folded',true));
    ASSERT (v_r->>'count')::int = 2,
        format('include_folded must find 2 (verbatim+folded), got %s', v_r->>'count');

    -- (3) a returned handle round-trips through context_resolve_handle (own session)
    v_handle := v_r->'results'->0->>'handle';
    v_resolved := stewards.context_resolve_handle(v_p, v_handle);
    ASSERT v_resolved IS NOT NULL, format('returned handle %s must resolve to a message id', v_handle);

    -- (4) descendants (the watch): parent sees the non-private child's message
    v_r := stewards.context_search_tool(jsonb_build_object('_session_id',v_p,'pattern','widget','scope','descendants'));
    ASSERT (v_r->>'count')::int = 2,
        format('descendants curated must find parent+child verbatim = 2, got %s', v_r->>'count');
    ASSERT v_r::text LIKE '%child found a WIDGET bug%', 'descendants must include the child message';

    -- (5) the private wall: child walls itself -> invisible to the parent's watch
    PERFORM stewards.context_session_private_tool(jsonb_build_object('_session_id',v_c,'on',true));
    v_r := stewards.context_search_tool(jsonb_build_object('_session_id',v_p,'pattern','widget','scope','descendants'));
    ASSERT (v_r->>'count')::int = 1,
        format('a private child must be invisible to the parent watch, got %s', v_r->>'count');
    ASSERT v_r::text NOT LIKE '%child found a WIDGET bug%', 'the private child message must NOT appear to the parent';
    -- but the child still searches its OWN context
    v_r := stewards.context_search_tool(jsonb_build_object('_session_id',v_c,'pattern','widget'));
    ASSERT (v_r->>'count')::int = 1, 'a private session can still search its own context';

    -- restore virgin state
    DELETE FROM stewards.messages WHERE session_id IN (v_p,v_c);
    DELETE FROM stewards.work_items WHERE id IN (v_pwi,v_cwi);
    DELETE FROM stewards.sessions WHERE id IN (v_p,v_c);
    DELETE FROM stewards.pipelines WHERE family='cs-smoke-pipe';
    DELETE FROM stewards.intents WHERE slug='cs-smoke';
    RAISE NOTICE 'OK 13: context_search — curated default hides folded (include_folded reveals), handle round-trips, the watch (parent->child), the private wall (private child invisible to parent, sees itself)';
END $$;

-- ── 14: guard narrow auto-resume (28) — self-clearing pauses self-heal, others don't
DO $$
BEGIN
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='reflect_guard_autoresume_tick'),
        'reflect_guard_autoresume_tick must ship';
    ASSERT stewards.config_get_text('reflect_guard_autoresume_enabled','x')='true',
        'autoresume enabled config must seed true';
    ASSERT stewards.reflect_status() ? 'autoresume', 'reflect_status must surface autoresume';

    PERFORM stewards.reflect_resume();   -- clean baseline (no autonomous load in smoke)

    -- Case A: a GUARD spend pause whose spend has cleared -> auto-resume lifts it
    PERFORM stewards.reflect_pause('simulated guard');
    PERFORM stewards.config_set('reflect_pause_source', to_jsonb('guard:autonomous spend $99 in 24h >= cap $10'::text), NULL);
    ASSERT stewards.config_get_text('autonomy_paused','false')='true', 'setup: paused';
    PERFORM stewards.reflect_guard_autoresume_tick();
    ASSERT stewards.config_get_text('autonomy_paused','false')='false',
        'a cleared guard SPEND pause must auto-resume';
    ASSERT EXISTS (SELECT 1 FROM stewards.reflect_guard_log WHERE action='auto_resumed'),
        'auto-resume must be logged (account for releasing the brake)';

    -- Case B: a HUMAN pause must NOT auto-resume
    PERFORM stewards.reflect_pause('human stop');   -- source='manual'
    PERFORM stewards.reflect_guard_autoresume_tick();
    ASSERT stewards.config_get_text('autonomy_paused','false')='true',
        'a human reflect_pause must NOT be auto-resumed';
    PERFORM stewards.reflect_resume();

    -- Case C: a guard FAILURE-streak pause (not self-clearing) must NOT auto-resume
    PERFORM stewards.reflect_pause('simulated guard');
    PERFORM stewards.config_set('reflect_pause_source', to_jsonb('guard:5 consecutive autonomous failures >= 5 (loop broken)'::text), NULL);
    PERFORM stewards.reflect_guard_autoresume_tick();
    ASSERT stewards.config_get_text('autonomy_paused','false')='true',
        'a failure-streak guard pause must stay for a human (not self-clearing)';

    -- restore virgin state
    PERFORM stewards.reflect_resume();
    PERFORM stewards.config_set('reflect_pause_source', to_jsonb('manual'::text), NULL);
    DELETE FROM stewards.reflect_guard_log WHERE action='auto_resumed';
    RAISE NOTICE 'OK 14: guard narrow auto-resume — cleared guard SPEND pause self-heals (logged); a human pause + a failure-streak pause do NOT';
END $$;

-- ── 15: intent-private file routing (29) — a private intent prefixes private/<intent>/
DO $$
DECLARE v_ipriv uuid; v_ipub uuid; v_wi uuid; v_dest text;
BEGIN
    ASSERT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='stewards'
            AND table_name='intents' AND column_name='file_private'), 'intents.file_private must ship';
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='work_item_private_file_route'), 'private-route fn must ship';
    ASSERT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='work_items_private_file_route'), 'private-route trigger must ship';

    INSERT INTO stewards.intents (slug,purpose,file_private) VALUES ('pr-priv','private smoke',true)
      ON CONFLICT (slug) DO UPDATE SET file_private=true RETURNING id INTO v_ipriv;
    INSERT INTO stewards.intents (slug,purpose) VALUES ('pr-pub','public smoke') ON CONFLICT (slug) DO NOTHING;
    SELECT id INTO v_ipub FROM stewards.intents WHERE slug='pr-pub';
    INSERT INTO stewards.pipelines (family,stages) VALUES ('pr-smoke-pipe','[{"name":"s"}]'::jsonb) ON CONFLICT (family) DO NOTHING;

    -- (1) INSERT under a private intent -> prefixed
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug,file_destination)
      VALUES ('pr-smoke-pipe','s',v_ipriv,'pr-priv-1','plans/pr-priv-1.md') RETURNING id INTO v_wi;
    SELECT file_destination INTO v_dest FROM stewards.work_items WHERE id=v_wi;
    ASSERT v_dest='private/pr-priv/plans/pr-priv-1.md', format('private INSERT must prefix, got %s', v_dest);

    -- (2) public intent -> unchanged
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug,file_destination)
      VALUES ('pr-smoke-pipe','s',v_ipub,'pr-pub-1','plans/pr-pub-1.md') RETURNING id INTO v_wi;
    SELECT file_destination INTO v_dest FROM stewards.work_items WHERE id=v_wi;
    ASSERT v_dest='plans/pr-pub-1.md', format('public intent must be unchanged, got %s', v_dest);

    -- (3) the on_maturity render path = an UPDATE of file_destination -> prefixed
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug)
      VALUES ('pr-smoke-pipe','s',v_ipriv,'pr-priv-2') RETURNING id INTO v_wi;
    UPDATE stewards.work_items SET file_destination='research/pr-priv-2.md' WHERE id=v_wi;
    SELECT file_destination INTO v_dest FROM stewards.work_items WHERE id=v_wi;
    ASSERT v_dest='private/pr-priv/research/pr-priv-2.md', format('private UPDATE must prefix, got %s', v_dest);

    -- (4) idempotent: already-private not double-prefixed
    UPDATE stewards.work_items SET file_destination='private/pr-priv/research/pr-priv-2.md' WHERE id=v_wi;
    SELECT file_destination INTO v_dest FROM stewards.work_items WHERE id=v_wi;
    ASSERT v_dest='private/pr-priv/research/pr-priv-2.md', format('already-private must not double-prefix, got %s', v_dest);

    DELETE FROM stewards.work_items WHERE pipeline_family='pr-smoke-pipe';
    DELETE FROM stewards.pipelines WHERE family='pr-smoke-pipe';
    DELETE FROM stewards.intents WHERE slug IN ('pr-priv','pr-pub');
    RAISE NOTICE 'OK 15: intent-private routing — private intent prefixes private/<intent>/ (INSERT + render-UPDATE), public unchanged, idempotent';
END $$;

-- ── 16: tool-usage primers (30) — gated per group, config-toggleable
DO $$
DECLARE v_ctx text; v_noctx text; v_skills text;
BEGIN
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='tool_primers'), 'tool_primers table must ship';
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='render_tool_primers'), 'render_tool_primers must ship';
    ASSERT (SELECT count(*) FROM stewards.tool_primers WHERE active) >= 2, 'core primers must seed';

    -- context primer gated on context_tools_on
    UPDATE stewards.agents SET context_tools_enabled=true WHERE family='research';
    v_ctx := stewards.render_tool_primers('research');
    ASSERT v_ctx IS NOT NULL AND v_ctx LIKE '%context_search%', 'context-on agent must get the context primer';
    UPDATE stewards.agents SET context_tools_enabled=false WHERE family='research';
    v_noctx := stewards.render_tool_primers('research');
    ASSERT v_noctx IS NULL OR v_noctx NOT LIKE '%context_search%', 'context-off agent must NOT get the context primer';

    -- skills primer gated on skill perm — throwaway family (context off, skill allowed)
    INSERT INTO stewards.agent_tool_perms (agent_family,tool_pattern,action,source)
      VALUES ('pr-skilltest','skill','allow','manual') ON CONFLICT (agent_family,tool_pattern) DO UPDATE SET action='allow';
    v_skills := stewards.render_tool_primers('pr-skilltest');
    ASSERT v_skills IS NOT NULL AND v_skills LIKE '%skill_load%', 'skill-allowed agent must get the skills primer';
    DELETE FROM stewards.agent_tool_perms WHERE agent_family='pr-skilltest';

    -- config toggle suppresses entirely
    UPDATE stewards.agents SET context_tools_enabled=true WHERE family='research';
    PERFORM stewards.config_set('tool_primers_enabled','false'::jsonb,NULL);
    ASSERT stewards.render_tool_primers('research') IS NULL, 'tool_primers_enabled=false must suppress primers';
    PERFORM stewards.config_set('tool_primers_enabled','true'::jsonb,NULL);
    UPDATE stewards.agents SET context_tools_enabled=false WHERE family='research';  -- restore core default
    RAISE NOTICE 'OK 16: tool primers — context primer gated on context_tools_on, skills primer on skill perm, config toggle suppresses';
END $$;

-- ── 17: empty-source halt (work_item_advance honors metadata.halt_on)
DO $$
DECLARE v_iv uuid; v_wi uuid; v_ret text; v_status text; v_stage text;
BEGIN
    INSERT INTO stewards.intents (slug,purpose) VALUES ('halt-smoke','halt') ON CONFLICT (slug) DO NOTHING;
    SELECT id INTO v_iv FROM stewards.intents WHERE slug='halt-smoke';
    INSERT INTO stewards.pipelines (family, stages, metadata) VALUES
      ('halt-smoke-pipe',
       '[{"name":"read","next":"digest","auto_advance":true},{"name":"digest","next":null,"auto_advance":true}]'::jsonb,
       jsonb_build_object('halt_on', jsonb_build_object('stage','read','outputs', jsonb_build_array('SHELF EMPTY'))))
      ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages, metadata=EXCLUDED.metadata;

    -- (1) read emits the sentinel -> HALT: advance returns NULL, cancelled, stays at read
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug,status)
      VALUES ('halt-smoke-pipe','read',v_iv,'halt-1','in_progress') RETURNING id INTO v_wi;
    v_ret := stewards.work_item_advance(v_wi, '{"output":"SHELF EMPTY"}'::jsonb);
    SELECT status,current_stage INTO v_status,v_stage FROM stewards.work_items WHERE id=v_wi;
    ASSERT v_ret IS NULL, format('halt must return NULL (no next stage), got %s', v_ret);
    ASSERT v_status='cancelled', format('halt must cancel, got %s', v_status);
    ASSERT v_stage='read', format('halt must NOT advance past read, got %s', v_stage);

    -- (2) read emits a real book -> normal advance to digest
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug,status)
      VALUES ('halt-smoke-pipe','read',v_iv,'halt-2','in_progress') RETURNING id INTO v_wi;
    v_ret := stewards.work_item_advance(v_wi, '{"output":"BOOK: Real Book by Author"}'::jsonb);
    SELECT status,current_stage INTO v_status,v_stage FROM stewards.work_items WHERE id=v_wi;
    ASSERT v_ret='digest' AND v_stage='digest' AND v_status='pending',
      format('non-sentinel must advance normally, got ret=%s stage=%s status=%s', v_ret, v_stage, v_status);

    -- (3) a pipeline WITHOUT halt_on -> advances even on the sentinel text (no halt)
    INSERT INTO stewards.pipelines (family, stages) VALUES
      ('halt-smoke-nohalt', '[{"name":"read","next":"digest","auto_advance":true},{"name":"digest","next":null}]'::jsonb)
      ON CONFLICT (family) DO NOTHING;
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug,status)
      VALUES ('halt-smoke-nohalt','read',v_iv,'halt-3','in_progress') RETURNING id INTO v_wi;
    v_ret := stewards.work_item_advance(v_wi, '{"output":"SHELF EMPTY"}'::jsonb);
    SELECT status INTO v_status FROM stewards.work_items WHERE id=v_wi;
    ASSERT v_ret='digest' AND v_status='pending', format('no halt_on -> normal advance, got ret=%s status=%s', v_ret, v_status);

    DELETE FROM stewards.work_items WHERE pipeline_family IN ('halt-smoke-pipe','halt-smoke-nohalt');
    DELETE FROM stewards.pipelines WHERE family IN ('halt-smoke-pipe','halt-smoke-nohalt');
    DELETE FROM stewards.intents WHERE slug='halt-smoke';
    RAISE NOTICE 'OK 17: empty-source halt — halt_on sentinel cancels at the stage + returns NULL (no advance); non-sentinel + no-halt_on advance normally';
END $$;


-- ── 18: model aliases + the file_private no-train guard rail
DO $$
DECLARE v_prov text; v_mod text; v_iv uuid; v_wi uuid; v_caught boolean;
BEGIN
    -- the policy column + helpers exist; default no-train, flag flips it
    PERFORM 1 FROM information_schema.columns
      WHERE table_schema='stewards' AND table_name='model_capability' AND column_name='trains_on_data';
    ASSERT FOUND, 'model_capability.trains_on_data column must exist';
    ASSERT stewards.model_trains_on_data('nosuch','model') = false, 'unflagged model defaults no-train';

    INSERT INTO stewards.model_capability (provider, model, usable, trains_on_data, probed_via) VALUES
      ('aliastest_free','m-free', true, true,  'manual'),
      ('aliastest_paid','m-paid', true, false, 'manual')
      ON CONFLICT (provider, model) DO UPDATE
        SET usable=EXCLUDED.usable, trains_on_data=EXCLUDED.trains_on_data;
    ASSERT stewards.model_trains_on_data('aliastest_free','m-free') = true, 'flagged model trains';

    -- alias: a free (prio 0, train-on-data) member + a paid (prio 1, no-train) fallback
    INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority) VALUES
      ('aliastest-wq','aliastest_free','m-free',0),
      ('aliastest-wq','aliastest_paid','m-paid',1)
      ON CONFLICT (alias, provider, provider_model) DO NOTHING;

    -- public (forbid=false): lowest priority wins => the free member
    SELECT provider, model INTO v_prov, v_mod FROM stewards.pick_alias_member('aliastest-wq', false);
    ASSERT v_prov='aliastest_free' AND v_mod='m-free',
      format('public alias picks free prio0, got %s/%s', v_prov, v_mod);

    -- private (forbid=true): the free member trains => dropped => falls to paid
    SELECT provider, model INTO v_prov, v_mod FROM stewards.pick_alias_member('aliastest-wq', true);
    ASSERT v_prov='aliastest_paid' AND v_mod='m-paid',
      format('private alias drops train-on-data, falls to paid, got %s/%s', v_prov, v_mod);

    -- an unusable member is skipped (public)
    UPDATE stewards.model_capability SET usable=false WHERE provider='aliastest_free' AND model='m-free';
    SELECT provider, model INTO v_prov, v_mod FROM stewards.pick_alias_member('aliastest-wq', false);
    ASSERT v_prov='aliastest_paid', format('unusable member skipped, got %s', v_prov);
    UPDATE stewards.model_capability SET usable=true WHERE provider='aliastest_free' AND model='m-free';

    -- intent_forbids_training reads file_private
    INSERT INTO stewards.intents (slug,purpose,file_private) VALUES ('aliastest-priv','t',true)
      ON CONFLICT (slug) DO UPDATE SET file_private=true;
    SELECT id INTO v_iv FROM stewards.intents WHERE slug='aliastest-priv';
    ASSERT stewards.intent_forbids_training(v_iv) = true, 'file_private intent forbids training';

    -- a working agent for the dispatch paths that proceed past the guard
    INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
      VALUES ('aliastest','*','alias smoke agent','primary','You are a smoke agent.',0.2)
      ON CONFLICT (family, model_match) DO UPDATE SET prompt=EXCLUDED.prompt;

    -- guard rail: a file_private intent + a LITERAL train-on-data stage model
    -- (no public_io) => refused
    INSERT INTO stewards.pipelines (family, stages) VALUES
      ('aliastest-litpipe',
       jsonb_build_array(jsonb_build_object(
         'name','gather','agent_family','aliastest','model','m-free','provider','aliastest_free','next',null)))
      ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages;
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug,status)
      VALUES ('aliastest-litpipe','gather',v_iv,'aliastest-lit','pending') RETURNING id INTO v_wi;
    v_caught := false;
    BEGIN
        PERFORM stewards.work_item_dispatch_stage(v_wi);
    EXCEPTION WHEN OTHERS THEN
        v_caught := (SQLERRM LIKE '%train-on-data%');
    END;
    ASSERT v_caught, 'file_private literal train-on-data dispatch must be refused with a train-on-data error';

    -- public_io escape hatch: same private intent + train-on-data model, but the
    -- stage declares public_io => the no-train guard is bypassed (gather I/O is
    -- public), so dispatch proceeds (no train-on-data error).
    INSERT INTO stewards.pipelines (family, stages) VALUES
      ('aliastest-pubio',
       jsonb_build_array(jsonb_build_object(
         'name','gather','agent_family','aliastest','model','m-free','provider','aliastest_free','public_io',true,'next',null)))
      ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages;
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug,status)
      VALUES ('aliastest-pubio','gather',v_iv,'aliastest-pubio-wi','pending') RETURNING id INTO v_wi;
    v_caught := false;
    BEGIN
        PERFORM stewards.work_item_dispatch_stage(v_wi);
    EXCEPTION WHEN OTHERS THEN
        v_caught := (SQLERRM LIKE '%train-on-data%');
    END;
    ASSERT NOT v_caught, 'public_io stage must bypass the no-train guard even under a file_private intent';

    DELETE FROM stewards.work_queue WHERE payload->>'_pipeline_family' IN ('aliastest-litpipe','aliastest-pubio');
    DELETE FROM stewards.messages WHERE session_id LIKE 'wi--%--gather';
    DELETE FROM stewards.work_items WHERE pipeline_family IN ('aliastest-litpipe','aliastest-pubio');
    DELETE FROM stewards.sessions WHERE id LIKE 'wi--%--gather';
    DELETE FROM stewards.pipelines WHERE family IN ('aliastest-litpipe','aliastest-pubio');
    DELETE FROM stewards.agents WHERE family='aliastest';
    DELETE FROM stewards.model_aliases WHERE alias='aliastest-wq';
    DELETE FROM stewards.model_capability WHERE provider IN ('aliastest_free','aliastest_paid');
    DELETE FROM stewards.intents WHERE slug='aliastest-priv';
    RAISE NOTICE 'OK 18: model aliases — priority pick + private drops train-on-data member (falls to paid) + unusable skipped; intent_forbids_training=file_private; literal train-on-data into a private intent refused; public_io bypasses the guard';
END $$;


-- ── 19: alias runtime failover (steward walks to the next member on a transient)
DO $$
DECLARE v_iv uuid; v_wi uuid; v_mo text; v_po text; v_n int;
BEGIN
    -- 32 broadened diagnose_failure to the real outage shapes
    ASSERT stewards.diagnose_failure('chat HTTP 521 Web server is down') = 'transient',
      'Cloudflare 521 must diagnose transient';
    ASSERT stewards.diagnose_failure('HTTP 529: overloaded') = 'transient', '529 overloaded → transient';
    ASSERT stewards.diagnose_failure('context deadline exceeded') = 'timeout', 'deadline → timeout';

    -- exclude param skips a tried member
    INSERT INTO stewards.model_capability (provider, model, usable, probed_via) VALUES
      ('ftp_a','m-a', true, 'manual'), ('ftp_b','m-b', true, 'manual')
      ON CONFLICT (provider, model) DO UPDATE SET usable=true;
    INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority) VALUES
      ('failtest','ftp_a','m-a',0), ('failtest','ftp_b','m-b',1)
      ON CONFLICT (alias, provider, provider_model) DO NOTHING;
    SELECT provider INTO v_po FROM stewards.pick_alias_member('failtest', false, '[{"provider":"ftp_a","model":"m-a"}]'::jsonb);
    ASSERT v_po='ftp_b', format('exclude must skip ftp_a → ftp_b, got %s', v_po);

    -- steward_tick failover: a failed alias work_item whose member A errored
    -- transiently → re-dispatched onto member B (override set, action logged).
    INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
      VALUES ('failtest','*','failover smoke agent','primary','You are a smoke agent.',0.2)
      ON CONFLICT (family, model_match) DO UPDATE SET prompt=EXCLUDED.prompt;
    INSERT INTO stewards.intents (slug,purpose) VALUES ('failtest-intent','t') ON CONFLICT (slug) DO NOTHING;
    SELECT id INTO v_iv FROM stewards.intents WHERE slug='failtest-intent';
    INSERT INTO stewards.pipelines (family, stages) VALUES
      ('failtest-pipe', jsonb_build_array(jsonb_build_object(
        'name','gather','agent_family','failtest','model','failtest','next',null)))
      ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages;
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug,status,failure_count,last_failure_reason,escalation_state)
      VALUES ('failtest-pipe','gather',v_iv,'failover-wi','failed',1,'chat dispatch failed at stage gather: HTTP 521 Web server is down','normal')
      RETURNING id INTO v_wi;
    -- the prior (member A) attempt, recorded as a transient error in work_queue
    INSERT INTO stewards.work_queue (kind, provider, status, error, payload) VALUES
      ('chat','ftp_a','error','HTTP 521 Web server is down',
       jsonb_build_object('session_id','wi--x--gather','_work_item_id',v_wi::text,'_stage_name','gather','requested_model','m-a'));

    PERFORM stewards.steward_tick();

    SELECT model_override, provider_override INTO v_mo, v_po FROM stewards.work_items WHERE id=v_wi;
    ASSERT v_mo='m-b' AND v_po='ftp_b',
      format('failover must set override to the next member ftp_b/m-b, got %s/%s', v_po, v_mo);
    SELECT count(*) INTO v_n FROM stewards.steward_actions WHERE work_item_id=v_wi AND action='alias_failover';
    ASSERT v_n=1, format('exactly one alias_failover action expected, got %s', v_n);

    DELETE FROM stewards.work_queue WHERE payload->>'_work_item_id'=v_wi::text;
    DELETE FROM stewards.messages WHERE session_id LIKE 'wi--%--gather';
    DELETE FROM stewards.steward_actions WHERE work_item_id=v_wi;
    DELETE FROM stewards.work_items WHERE id=v_wi;
    DELETE FROM stewards.sessions WHERE id LIKE 'wi--%--gather';
    DELETE FROM stewards.pipelines WHERE family='failtest-pipe';
    DELETE FROM stewards.agents WHERE family='failtest';
    DELETE FROM stewards.model_aliases WHERE alias='failtest';
    DELETE FROM stewards.model_capability WHERE provider IN ('ftp_a','ftp_b');
    DELETE FROM stewards.intents WHERE slug='failtest-intent';
    RAISE NOTICE 'OK 19: alias failover — diagnose covers 5xx/52x/529/timeout; exclude skips a tried member; steward walks a transient alias failure to the next member (override set + alias_failover logged)';
END $$;

-- ── 20: doc-construction (34/35) — work-item-scoped drafts, cross-stage handoff,
--        doc_finalize project-fallback, pools_via_tool skips the double-pool,
--        research-summary/write recast.
DO $$
DECLARE
    v_wid uuid; v_uuid8 text; v_sb text; v_sc text;
    v_h text; v_r jsonb; v_proj text; v_slug text; v_journal int;
BEGIN
    -- 34 surface ships
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='doc_drafts'),
        'doc_drafts must ship';
    ASSERT (SELECT count(*) FROM stewards.tool_defs WHERE active AND name IN
             ('doc_create','doc_append_section','doc_patch','doc_read','doc_finalize','doc_current')) = 6,
        'the 6 doc-construction tools must ship';
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='doc_draft_session_match'),
        'doc_draft_session_match must ship';

    -- work-item scoping: same wi across stages matches; cross-wi + persona do not
    ASSERT stewards.doc_draft_session_match('wi--abc12345--build','wi--abc12345--critique'),
        'same work item across stages must match (cross-stage draft)';
    ASSERT NOT stewards.doc_draft_session_match('wi--abc12345--build','wi--def67890--critique'),
        'different work items must not match';
    ASSERT NOT stewards.doc_draft_session_match('persona-x','persona-y'),
        'non-wi sessions match only exactly';
    ASSERT stewards.doc_draft_session_match('persona-x','persona-x'),
        'an exact session always matches';

    -- a project-tagged work item; derive its stage sessions from the id
    INSERT INTO stewards.projects (slug,name) VALUES ('dc-smoke-proj','DC Smoke') ON CONFLICT DO NOTHING;
    INSERT INTO stewards.intents (slug,purpose) VALUES ('dc-smoke','dc') ON CONFLICT (slug) DO NOTHING;
    INSERT INTO stewards.pipelines (family,stages,metadata,auto_materialize_on_verified) VALUES
      ('dc-smoke-pipe','[{"name":"build","next":"critique"},{"name":"critique","next":null}]'::jsonb,
       jsonb_build_object('pools_via_tool',true), false)
      ON CONFLICT (family) DO UPDATE SET metadata=EXCLUDED.metadata, auto_materialize_on_verified=false;
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug,project_association)
      VALUES ('dc-smoke-pipe','critique',(SELECT id FROM stewards.intents WHERE slug='dc-smoke'),
              'dc-smoke-wi','dc-smoke-proj')
      RETURNING id INTO v_wid;
    v_uuid8 := left(v_wid::text,8);
    v_sb := 'wi--'||v_uuid8||'--build';
    v_sc := 'wi--'||v_uuid8||'--critique';
    INSERT INTO stewards.sessions (id,kind) VALUES (v_sb,'agent'),(v_sc,'agent') ON CONFLICT DO NOTHING;
    UPDATE stewards.work_items SET session_ids=ARRAY[v_sb,v_sc] WHERE id=v_wid;

    -- build stage creates + appends a draft
    v_r := stewards.doc_create_tool(jsonb_build_object('_session_id',v_sb,'title','DC Smoke Digest'));
    v_h := v_r->>'handle';
    ASSERT v_h IS NOT NULL, 'doc_create must return a handle';
    PERFORM stewards.doc_append_section_tool(jsonb_build_object('_session_id',v_sb,'handle',v_h,
      'heading','Body','body','Enough body text to clear the doc_finalize eighty-character floor so this draft pools cleanly.'));

    -- CROSS-STAGE: the critique session finds the build stage's draft via doc_current
    v_r := stewards.doc_current_tool(jsonb_build_object('_session_id',v_sc));
    ASSERT (v_r->>'handle')=v_h,
        format('doc_current from the sibling stage must find the build draft, got %s', v_r->>'handle');

    -- doc_finalize from the critique session: pools + project-fallback to the work item's project
    v_r := stewards.doc_finalize_tool(jsonb_build_object('_session_id',v_sc,'handle',v_h));
    ASSERT (v_r->>'ok')='true', 'doc_finalize must succeed cross-stage';
    v_slug := v_r->>'slug';
    SELECT project_association INTO v_proj FROM stewards.docs WHERE slug=v_slug;
    ASSERT v_proj='dc-smoke-proj',
        format('doc_finalize must project-tag the pooled doc from the work item (fallback), got %s', v_proj);
    ASSERT NOT EXISTS (SELECT 1 FROM stewards.doc_drafts WHERE handle=v_h), 'doc_finalize must clear the draft';

    -- 08 pools_via_tool: flipping to verified must NOT auto-pool the journal (no doc under the wi slug)
    UPDATE stewards.work_items SET stage_results='{"critique":{"output":"JOURNAL: pooled it."}}'::jsonb WHERE id=v_wid;
    UPDATE stewards.work_items SET maturity='verified' WHERE id=v_wid;
    SELECT count(*) INTO v_journal FROM stewards.docs WHERE slug='dc-smoke-wi';
    ASSERT v_journal=0,
        'pools_via_tool must skip on_maturity auto-pool (no journal doc under the work_item slug)';

    -- 35: research-summary + research-write recast to build/critique + pools_via_tool + auto_mat off
    ASSERT EXISTS (SELECT 1 FROM stewards.pipelines p, jsonb_array_elements(p.stages) s
                    WHERE p.family='research-summary' AND s->>'name'='build'),
        'research-summary must be recast to a build stage';
    ASSERT EXISTS (SELECT 1 FROM stewards.pipelines p, jsonb_array_elements(p.stages) s
                    WHERE p.family='research-write' AND s->>'name'='critique'),
        'research-write must be recast to a critique stage';
    ASSERT (SELECT (metadata->>'pools_via_tool')::boolean AND NOT auto_materialize_on_verified
              FROM stewards.pipelines WHERE family='research-summary'),
        'research-summary must declare pools_via_tool + auto_materialize off';
    ASSERT (SELECT (metadata->>'pools_via_tool')::boolean AND NOT auto_materialize_on_verified
              FROM stewards.pipelines WHERE family='research-write'),
        'research-write must declare pools_via_tool + auto_materialize off';

    -- restore virgin state
    DELETE FROM stewards.docs WHERE slug IN (v_slug,'dc-smoke-wi');
    DELETE FROM stewards.work_items WHERE id=v_wid;
    DELETE FROM stewards.sessions WHERE id IN (v_sb,v_sc);
    DELETE FROM stewards.pipelines WHERE family='dc-smoke-pipe';
    DELETE FROM stewards.intents WHERE slug='dc-smoke';
    DELETE FROM stewards.projects WHERE slug='dc-smoke-proj';
    RAISE NOTICE 'OK 20: doc-construction — 6 doc tools + work-item-scoped drafts (cross-stage doc_current) + doc_finalize project-fallback + pools_via_tool skips the double-pool; research-summary/write recast (build/critique, auto_mat off)';
END $$;

-- ── 21: judge local-routing (36) — config-gated reroute of the 3 background judges
DO $$
DECLARE v_prov text; v_reqm text; v_bodym text;
BEGIN
    -- ships OFF with public defaults (a bare install is unchanged)
    ASSERT stewards.config_get_text('judge_dispatch_local','x') = 'false',
        'judge_dispatch_local must default false (public install unchanged)';
    ASSERT stewards.config_get_text('judge_dispatch_provider','x') = 'opencode_go',
        'judge_dispatch_provider must default opencode_go';
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='reroute_judge_to_local'),
        'the reroute function must ship';
    ASSERT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='work_queue_reroute_judge_to_local'),
        'the BEFORE-INSERT reroute trigger must be installed';

    INSERT INTO stewards.sessions (id,kind) VALUES ('smoke-judge','tool') ON CONFLICT DO NOTHING;

    -- OFF: a judge dispatch is left on its declared provider/model
    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat','opencode_go',
            jsonb_build_object('agent_family','engram-extractor','requested_model','deepseek-v4-flash',
                               'session_id','smoke-judge','body', jsonb_build_object('model','deepseek-v4-flash')),
            'pending')
    RETURNING provider, payload->>'requested_model', payload->'body'->>'model' INTO v_prov, v_reqm, v_bodym;
    ASSERT v_prov='opencode_go' AND v_reqm='deepseek-v4-flash' AND v_bodym='deepseek-v4-flash',
        format('with routing OFF a judge dispatch is unchanged, got %s/%s/%s', v_prov, v_reqm, v_bodym);

    -- ON: a judge dispatch is repointed to the configured local provider + model (BOTH fields)
    PERFORM stewards.config_set('judge_dispatch_local','true'::jsonb,NULL);
    PERFORM stewards.config_set('judge_dispatch_provider', to_jsonb('flexllama'::text), NULL);
    PERFORM stewards.config_set('judge_dispatch_model', to_jsonb('gemma-12b'::text), NULL);
    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat','opencode_go',
            jsonb_build_object('agent_family','engram-extractor','requested_model','deepseek-v4-flash',
                               'session_id','smoke-judge','body', jsonb_build_object('model','deepseek-v4-flash')),
            'pending')
    RETURNING provider, payload->>'requested_model', payload->'body'->>'model' INTO v_prov, v_reqm, v_bodym;
    ASSERT v_prov='flexllama' AND v_reqm='gemma-12b' AND v_bodym='gemma-12b',
        format('with routing ON a judge dispatch must reroute provider + requested_model + body.model, got %s/%s/%s', v_prov, v_reqm, v_bodym);

    -- a NON-judge dispatch is never touched, even with routing on
    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('chat','opencode_go',
            jsonb_build_object('agent_family','research','requested_model','kimi-k2.6',
                               'session_id','smoke-judge','body', jsonb_build_object('model','kimi-k2.6')),
            'pending')
    RETURNING provider, payload->'body'->>'model' INTO v_prov, v_bodym;
    ASSERT v_prov='opencode_go' AND v_bodym='kimi-k2.6',
        format('a non-judge dispatch must be untouched, got %s/%s', v_prov, v_bodym);

    -- restore virgin state
    PERFORM stewards.config_set('judge_dispatch_local','false'::jsonb,NULL);
    PERFORM stewards.config_set('judge_dispatch_provider', to_jsonb('opencode_go'::text), NULL);
    PERFORM stewards.config_set('judge_dispatch_model', to_jsonb('deepseek-v4-flash'::text), NULL);
    DELETE FROM stewards.work_queue WHERE payload->>'session_id'='smoke-judge';
    DELETE FROM stewards.sessions WHERE id='smoke-judge';
    RAISE NOTICE 'OK 21: judge local-routing — default off leaves judges unchanged; on reroutes the 3 judge families (provider + requested_model + body.model); non-judge dispatches untouched';
END $$;

-- ── 22: page-in tool cap (the research notebook) — role-aware in compose_messages
DO $$
DECLARE
    v_iv uuid; v_sess text := 'smoke-pagein'; v_msgs jsonb; v_toolc text; v_asstc text;
    v_big text := repeat('x', 6000);
BEGIN
    -- the config ships OFF (public default = no behavior change)
    ASSERT stewards.config_get_text('page_in_tool_result_cap_chars','x') = '0',
        'page_in_tool_result_cap_chars must default 0 (off; public unchanged)';
    -- the cap helper truncates over the cap + leaves a page-in handle
    ASSERT (stewards.page_in_cap(jsonb_build_object('role','tool','content',v_big), 500, 'abcd')->>'content') LIKE '%[page-in:%result_search%',
        'page_in_cap must truncate over-cap content to a head + a page-in/result_search banner';

    -- compose_messages role-awareness: a big TOOL result is capped to the low tool
    -- cap; a big ASSISTANT message is NOT (it stays on the high ratio cap).
    INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
      VALUES ('smoke-pagein','*','pagein smoke','primary','You are a smoke agent.',0.2)
      ON CONFLICT (family, model_match) DO UPDATE SET prompt=EXCLUDED.prompt;
    INSERT INTO stewards.sessions (id,kind) VALUES (v_sess,'agent') ON CONFLICT DO NOTHING;
    INSERT INTO stewards.messages (session_id, role, content, tool_call_id)
      VALUES (v_sess,'user','start',NULL),
             (v_sess,'assistant',v_big,NULL),
             (v_sess,'tool',v_big,'tc1');

    -- ratio high so the ratio cap never fires; tool cap low so only tool results page.
    -- compose_messages args = (agent_family, model, session_id, user_input).
    PERFORM stewards.config_set('page_in_single_msg_ratio','0.99'::jsonb,NULL);
    PERFORM stewards.config_set('page_in_tool_result_cap_chars','800'::jsonb,NULL);
    v_msgs := stewards.compose_messages('smoke-pagein','smoke-model',v_sess,NULL);

    SELECT e->>'content' INTO v_toolc FROM jsonb_array_elements(v_msgs) e WHERE e->>'role'='tool' LIMIT 1;
    SELECT e->>'content' INTO v_asstc FROM jsonb_array_elements(v_msgs) e
      WHERE e->>'role'='assistant' AND length(e->>'content') > 2000 LIMIT 1;
    ASSERT v_toolc IS NOT NULL AND length(v_toolc) < 2000 AND v_toolc LIKE '%[page-in:%',
        format('the big tool result must be paged to a small head+banner, got len=%s', length(coalesce(v_toolc,'')));
    -- a big assistant message keeps the high ratio cap (well above the 800 tool cap)
    ASSERT v_asstc IS NOT NULL AND length(v_asstc) > 2000,
        format('a big assistant message must NOT be tool-capped (ratio cap only), got len=%s', length(coalesce(v_asstc,'')));

    -- restore virgin state
    PERFORM stewards.config_set('page_in_single_msg_ratio','0.5'::jsonb,NULL);
    PERFORM stewards.config_set('page_in_tool_result_cap_chars','0'::jsonb,NULL);
    DELETE FROM stewards.messages WHERE session_id=v_sess;
    DELETE FROM stewards.sessions WHERE id=v_sess;
    DELETE FROM stewards.agents WHERE family='smoke-pagein';
    RAISE NOTICE 'OK 22: page-in tool cap — config off by default; page_in_cap truncates+handles; compose_messages caps a big TOOL result to the low tool cap while a big ASSISTANT stays on the ratio cap (the research notebook)';
END $$;

-- ── 23: tool-groups (37) — per-stage tool scoping (the tool-side mirror of skills)
DO $$
DECLARE v_full int; v_scoped int; v_wid uuid; v_sess text;
BEGIN
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='tool_groups'),
        'tool_groups table must ship';
    ASSERT (SELECT count(*) FROM stewards.tool_groups WHERE name IN ('web-research','substrate-read','doc-build')) = 3,
        'the core tool groups must seed';
    -- resolver: a named group -> its patterns; empty/null -> NULL (unscoped)
    ASSERT array_length(stewards.resolve_tool_scope('["web-research"]'::jsonb), 1) > 5,
        'resolve_tool_scope(web-research) must return the group''s patterns';
    ASSERT stewards.resolve_tool_scope('[]'::jsonb) IS NULL AND stewards.resolve_tool_scope(NULL) IS NULL,
        'empty/null tool_groups must resolve to NULL (unscoped)';

    -- compose_tools_scoped narrows; NULL scope = full set (backward-compatible)
    INSERT INTO stewards.agents (family,model_match,description,mode,prompt,temperature)
      VALUES ('smoke-tg','*','tg smoke','primary','x',0.2)
      ON CONFLICT (family,model_match) DO UPDATE SET prompt='x';
    v_full   := jsonb_array_length(stewards.compose_tools('smoke-tg'));
    v_scoped := jsonb_array_length(stewards.compose_tools_scoped('smoke-tg', ARRAY['doc_*']));  -- core sql_fn tools (glob uses *)
    ASSERT v_full > v_scoped AND v_scoped >= 1,
        format('a scoped set must be smaller than the full set, got full=%s scoped=%s', v_full, v_scoped);
    ASSERT jsonb_array_length(stewards.compose_tools_scoped('smoke-tg', NULL)) = v_full,
        'a NULL scope must return the full set (byte-for-byte backward compatible)';

    -- session_tool_scope derives the scope from a stage that declares tool_groups
    INSERT INTO stewards.intents (slug,purpose) VALUES ('tg-smoke','tg') ON CONFLICT (slug) DO NOTHING;
    INSERT INTO stewards.pipelines (family,stages) VALUES
      ('tg-smoke-pipe', jsonb_build_array(jsonb_build_object('name','gather','tool_groups',jsonb_build_array('web-research'))))
      ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages;
    INSERT INTO stewards.work_items (pipeline_family,current_stage,intent_id,slug)
      VALUES ('tg-smoke-pipe','gather',(SELECT id FROM stewards.intents WHERE slug='tg-smoke'),'tg-wi')
      RETURNING id INTO v_wid;
    v_sess := 'wi--'||left(v_wid::text,8)||'--gather';
    ASSERT array_length(stewards.session_tool_scope(v_sess),1) > 5,
        'session_tool_scope must derive a stage''s declared tool_groups';
    ASSERT stewards.session_tool_scope('persona-x') IS NULL,
        'a non-wi session must be unscoped (NULL)';

    -- restore virgin state
    DELETE FROM stewards.work_items WHERE id=v_wid;
    DELETE FROM stewards.pipelines WHERE family='tg-smoke-pipe';
    DELETE FROM stewards.intents WHERE slug='tg-smoke';
    DELETE FROM stewards.agents WHERE family='smoke-tg';
    RAISE NOTICE 'OK 23: tool-groups — table+3 seeds; resolve unions patterns (empty/null->unscoped); compose_tools_scoped narrows (NULL=full set); session_tool_scope derives a stage''s tool_groups (non-wi->NULL)';
END $$;

\echo '== ALL VIRGIN-SMOKE ASSERTIONS PASSED — the authored chain (00→37) is sound =='
