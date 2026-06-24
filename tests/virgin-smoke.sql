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

-- ── 24: embed-model invariant (15a es2) — an embed job with no model MUST be
--    filled to a real embedding model; one that names a model is left untouched.
--    (Bug: engram embeds omitted the model -> fell to the lm_studio CHAT default
--    -> /v1/embeddings 400 -> vectors never written. The es2 trigger now enforces
--    BOTH provider AND model in one place.)
DO $$
DECLARE v_no_model bigint; v_has_model bigint;
BEGIN
    -- a) no model + wrong provider -> trigger fills model+dimensions AND forces lm_studio
    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('embed','opencode_go',
            jsonb_build_object('target_table','engram_embeddings','target_id','SMOKE-embed-nomodel','text','x'),
            'pending')
    RETURNING id INTO v_no_model;
    ASSERT (SELECT provider FROM stewards.work_queue WHERE id=v_no_model) = 'lm_studio',
        'es2 must force provider=lm_studio';
    ASSERT (SELECT payload->>'model' FROM stewards.work_queue WHERE id=v_no_model) = 'nomic-embed-text-v1.5',
        'es2 must fill the embed model when absent (the engram-misroute fix)';
    ASSERT (SELECT jsonb_typeof(payload->'dimensions') FROM stewards.work_queue WHERE id=v_no_model) = 'number'
       AND (SELECT payload->>'dimensions' FROM stewards.work_queue WHERE id=v_no_model) = '768',
        'es2 must fill dimensions as a JSON number (matches docs/brain)';

    -- b) an explicit model is left untouched (COALESCE leaves docs/brain enqueues be)
    INSERT INTO stewards.work_queue (kind, provider, payload, status)
    VALUES ('embed','lm_studio',
            jsonb_build_object('target_table','docs','target_id','SMOKE-embed-hasmodel',
                               'text','x','model','some-other-embed','dimensions',1024),
            'pending')
    RETURNING id INTO v_has_model;
    ASSERT (SELECT payload->>'model' FROM stewards.work_queue WHERE id=v_has_model) = 'some-other-embed',
        'es2 must NOT overwrite a model the enqueue site already set';

    DELETE FROM stewards.work_queue WHERE id IN (v_no_model, v_has_model);
    RAISE NOTICE 'OK 24: embed-model invariant — es2 fills model(nomic)+dimensions(768 number) when absent and forces lm_studio; an explicit model is preserved (the engram-misroute fix)';
END $$;

-- ── 25: single-finalize tool groups (37) — a PUBLISHING stage must see exactly ONE
--    finalize tool. The broad doc-build group bundles every finalize tool, which let a
--    book/playlist critique stage reach the generic doc_finalize instead of the domain
--    publish (→ a digest-<slug> dup that skipped the book-done boundary). doc-edit (no
--    finalize) + one *-finalize group per stage makes the misroute impossible.
DO $$
DECLARE v_scope text[];
BEGIN
    -- doc-edit is the build/patch set with NO finalize tool
    ASSERT EXISTS (SELECT 1 FROM stewards.tool_groups WHERE name='doc-edit'),
        'doc-edit group must ship';
    ASSERT NOT EXISTS (SELECT 1 FROM stewards.tool_groups WHERE name='doc-edit' AND 'doc_finalize' = ANY(tool_patterns)),
        'doc-edit must NOT contain a finalize tool';
    -- each single-finalize group names exactly one finalize tool
    ASSERT (SELECT tool_patterns FROM stewards.tool_groups WHERE name='book-finalize') = ARRAY['book_publish_draft'],
        'book-finalize must be exactly {book_publish_draft}';
    ASSERT (SELECT tool_patterns FROM stewards.tool_groups WHERE name='research-finalize') = ARRAY['doc_finalize'],
        'research-finalize must be exactly {doc_finalize}';
    -- a book-critique scope resolves to build tools + the ONE book finalize, NOT doc_finalize
    v_scope := stewards.resolve_tool_scope('["doc-edit","book-finalize"]'::jsonb);
    ASSERT 'book_publish_draft' = ANY(v_scope), 'book-critique scope must include book_publish_draft';
    ASSERT NOT ('doc_finalize' = ANY(v_scope)), 'book-critique scope must EXCLUDE doc_finalize (the dedup fix)';
    RAISE NOTICE 'OK 25: single-finalize tool groups — doc-edit has no finalize; book/research-finalize each name one tool; a book-critique scope keeps book_publish_draft and drops doc_finalize (the double-publish fix)';
END $$;

-- ── 26: edge-verb vocabulary (38) — the graph's grammar for the self-tending memory.
--    The canonical registry seeds the verbs; graph_link validates against it and writes
--    symmetric verbs both ways; an unknown verb is refused with the valid set.
DO $$
DECLARE v_res jsonb; v_n int;
BEGIN
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='edge_kinds'),
        'edge_kinds registry must ship';
    ASSERT (SELECT count(*) FROM stewards.edge_kinds) >= 18, 'the verb vocabulary must seed (>=18 verbs)';
    ASSERT (SELECT count(DISTINCT edge_group) FROM stewards.edge_kinds) = 4,
        'all four verb groups (provenance/causal/dialectical/associative) must seed';
    ASSERT EXISTS (SELECT 1 FROM stewards.edge_kinds WHERE name='CONTRADICTS' AND is_symmetric),
        'CONTRADICTS must be symmetric';

    -- an unknown verb is refused (and lists the valid set)
    v_res := stewards.graph_link('doc','smoke-a','doc','smoke-b','FROBNICATES','x');
    ASSERT (v_res->>'ok')::boolean IS FALSE AND v_res ? 'verbs',
        'graph_link must refuse an unknown verb and return the valid verbs';

    -- a known symmetric verb links both directions
    v_res := stewards.graph_link('doc','smoke-a','doc','smoke-b','CONTRADICTS','smoke');
    ASSERT (v_res->>'ok')::boolean, 'graph_link must accept a canonical verb';
    SELECT count(*) INTO v_n FROM stewards.edges e
      JOIN stewards.nodes s ON s.id=e.src JOIN stewards.nodes d ON d.id=e.dst
     WHERE e.kind='CONTRADICTS' AND s.ref IN ('smoke-a','smoke-b') AND d.ref IN ('smoke-a','smoke-b');
    ASSERT v_n = 2, format('a symmetric verb must write both directions, got %s', v_n);

    -- graph_vocabulary lists the verbs
    ASSERT jsonb_array_length(stewards.graph_vocabulary_tool('{}'::jsonb)::jsonb) >= 18,
        'graph_vocabulary must list the verbs';

    -- restore virgin state
    DELETE FROM stewards.edges WHERE src IN (SELECT id FROM stewards.nodes WHERE ref IN ('smoke-a','smoke-b'))
                                  OR dst IN (SELECT id FROM stewards.nodes WHERE ref IN ('smoke-a','smoke-b'));
    DELETE FROM stewards.nodes WHERE ref IN ('smoke-a','smoke-b');
    RAISE NOTICE 'OK 26: edge-verb vocabulary — registry seeds 19 verbs/4 groups; graph_link validates + writes symmetric verbs both ways + refuses unknowns; graph_vocabulary lists them (the graph''s grammar)';
END $$;

-- ── 27: the Hinge review queue (39) — bounds are ENFORCED in the substrate, never in
--    the prompt: the claude reviewer's approval only sticks for an in-bounds kind; an
--    out-of-bounds or escalate-always kind escalates to Michael regardless; Michael's
--    verdict is final and can clear an escalated item.
DO $$
DECLARE a bigint; b bigint; c bigint;
BEGIN
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='hinge_reviews'),
        'hinge_reviews queue must ship';
    ASSERT stewards.config_get('hinge_escalate_always_kinds') ? 'cutover',
        'cutover must default to escalate-always';
    PERFORM stewards.config_set('hinge_auto_approve_kinds', '["smoke-rule"]'::jsonb, 'smoke');

    a := stewards.hinge_enqueue('smoke-rule','in-bounds','{}','smoke');
    b := stewards.hinge_enqueue('graph-reorg','out-of-bounds','{}','smoke');
    c := stewards.hinge_enqueue('cutover','escalate-always','{}','smoke');
    ASSERT (stewards.hinge_record_verdict(a,'approve','x')->>'status') = 'approved',
        'an in-bounds kind the reviewer approves must be approved';
    ASSERT (stewards.hinge_record_verdict(b,'approve','x')->>'status') = 'escalated',
        'an out-of-bounds approval must escalate to Michael (the reviewer cannot exceed its grant)';
    ASSERT (stewards.hinge_record_verdict(c,'approve','x')->>'status') = 'escalated',
        'an escalate-always kind must escalate regardless of the reviewer verdict';
    ASSERT (stewards.hinge_record_verdict(c,'approve','his call','michael')->>'status') = 'approved',
        'Michael can clear an escalated item (his verdict is final)';

    -- restore virgin state
    PERFORM stewards.config_set('hinge_auto_approve_kinds', '[]'::jsonb, 'reset');
    DELETE FROM stewards.hinge_reviews WHERE proposer = 'smoke';
    RAISE NOTICE 'OK 27: Hinge review queue — bounds enforced in the substrate (in-bounds approve sticks; out-of-bounds + escalate-always escalate to Michael regardless of the reviewer; Michael''s verdict is final)';
END $$;

-- ── 28: the Reflective Tuning Engine (40) — the self-improvement loop. A flagged-quote
--    signal → a proposed rule → the Hinge gate → on approval the trigger auto-applies it
--    → the digester reads it via quote_rules. The oracle becomes a gradient.
DO $$
DECLARE v_res jsonb; v_rid bigint; v_hid bigint;
BEGIN
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='quote_flags'),
        'quote_flags (the gradient signal) must ship';
    ASSERT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='stewards' AND table_name='digest_skill_rules'),
        'digest_skill_rules must ship';
    ASSERT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family='digest-tuning'),
        'the digest-tuning pipeline must ship';

    -- the RTE proposes a rule
    v_res := stewards.rte_enqueue_quote_rule('smoke rule: paraphrase as prose, do not quote it', 'smoke flags');
    ASSERT (v_res->>'ok')::boolean, 'rte_enqueue_quote_rule must propose + queue';
    v_rid := (v_res->>'rule_id')::bigint; v_hid := (v_res->>'hinge_id')::bigint;

    -- before approval: not active (the digester sees only the default)
    ASSERT stewards.quote_rules_tool('{}'::jsonb) NOT LIKE '%smoke rule%',
        'a proposed (un-approved) rule must NOT be active';

    -- approve via the Hinge (grant the kind) → the trigger auto-activates the rule
    PERFORM stewards.config_set('hinge_auto_approve_kinds', '["digest-skill-rule"]'::jsonb, 'smoke');
    PERFORM stewards.hinge_record_verdict(v_hid, 'approve', 'sound');
    ASSERT (SELECT status FROM stewards.digest_skill_rules WHERE id = v_rid) = 'active',
        'Hinge approval must auto-activate the rule (the RTE trigger)';
    ASSERT stewards.quote_rules_tool('{}'::jsonb) LIKE '%smoke rule%',
        'an active rule must reach the digester via quote_rules';
    ASSERT (SELECT status FROM stewards.hinge_reviews WHERE id = v_hid) = 'applied',
        'the applied Hinge review must be marked applied';

    -- restore virgin state
    PERFORM stewards.config_set('hinge_auto_approve_kinds', '[]'::jsonb, 'reset');
    DELETE FROM stewards.hinge_reviews WHERE id = v_hid;
    DELETE FROM stewards.digest_skill_rules WHERE id = v_rid;
    RAISE NOTICE 'OK 28: the RTE loop — a flagged-quote signal → proposed rule → Hinge gate → trigger auto-applies → the digester reads it via quote_rules (the oracle as a gradient; build-the-oracle-first realized)';
END $$;

-- ── 29: the self-tending loops (41) — the WALK (graph_recall by connectedness) + the
--    LINK loop (propose a typed edge → the Hinge gates it → on approval the edge is born).
DO $$
DECLARE v_recall text; v_hid bigint;
BEGIN
    ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='graph_recall' AND pronamespace='stewards'::regnamespace),
        'graph_recall (the WALK) must ship';
    ASSERT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family='memory-tend'),
        'the memory-tend pipeline must ship';

    -- a mini graph: sm-a -BUILDS_ON-> sm-b -BUILDS_ON-> sm-c
    PERFORM stewards.graph_link('doc','sm-a','doc','sm-b','BUILDS_ON','t');
    PERFORM stewards.graph_link('doc','sm-b','doc','sm-c','BUILDS_ON','t');
    v_recall := stewards.graph_recall_tool(jsonb_build_object('kind','doc','ref','sm-a','max_hops',2,'limit',10));
    ASSERT v_recall LIKE '%sm-b%' AND v_recall LIKE '%sm-c%', 'recall must reach b (1 hop) and c (2 hops)';
    ASSERT v_recall NOT LIKE '%sm-a%', 'recall must exclude the seed itself';

    -- LINK loop: propose → Hinge approve → the edge is created
    v_hid := (stewards.memory_link_propose('doc','sm-a','doc','sm-c','RELATES_TO','test')->>'hinge_id')::bigint;
    PERFORM stewards.config_set('hinge_auto_approve_kinds','["graph-link"]'::jsonb,'smoke');
    PERFORM stewards.hinge_record_verdict(v_hid,'approve','ok');
    ASSERT EXISTS (SELECT 1 FROM stewards.edges e JOIN stewards.nodes s ON s.id=e.src JOIN stewards.nodes d ON d.id=e.dst
                    WHERE e.kind='RELATES_TO' AND s.ref='sm-a' AND d.ref='sm-c'),
        'an approved graph-link must create the edge (the LINK loop)';

    -- restore virgin state
    PERFORM stewards.config_set('hinge_auto_approve_kinds','[]'::jsonb,'reset');
    DELETE FROM stewards.hinge_reviews WHERE proposer='memory-tend';
    DELETE FROM stewards.edges WHERE src IN (SELECT id FROM stewards.nodes WHERE ref IN ('sm-a','sm-b','sm-c'))
                                  OR dst IN (SELECT id FROM stewards.nodes WHERE ref IN ('sm-a','sm-b','sm-c'));
    DELETE FROM stewards.nodes WHERE ref IN ('sm-a','sm-b','sm-c');
    RAISE NOTICE 'OK 29: the self-tending loops — graph_recall walks the typed graph by connectedness (reaches multi-hop neighbors, excludes the seed); the LINK loop proposes a typed edge, the Hinge gates it, and approval creates it (the memory grows its own connections, watched)';
END $$;

-- ── 30: the Hinge daemon contract (39) — the substrate DRIVES the host daemon and the
--    emergency stop (autonomy_paused) HALTS the gate. The daemon obeys should_run.
DO $$
DECLARE v_hid bigint;
BEGIN
    ASSERT (stewards.hinge_gate_status()->>'should_run')::bool = false,
        'a virgin queue (nothing pending) must say should_run=false';
    v_hid := stewards.hinge_enqueue('graph-link','smoke-gate','{}'::jsonb,'smoke');
    ASSERT (stewards.hinge_gate_status()->>'should_run')::bool = true,
        'pending work + not paused must say should_run=true';
    PERFORM stewards.config_set('autonomy_paused','true'::jsonb,'smoke');
    ASSERT (stewards.hinge_gate_status()->>'should_run')::bool = false,
        'the emergency stop (autonomy_paused) must force should_run=false — the gate obeys the global pause';
    ASSERT (stewards.hinge_gate_status()->>'paused_reason') IS NOT NULL, 'paused must carry a reason';
    PERFORM stewards.config_set('autonomy_paused','false'::jsonb,'restore');
    DELETE FROM stewards.hinge_reviews WHERE id = v_hid;
    ASSERT (stewards.hinge_gate_status()->>'interval_seconds')::int > 0, 'the substrate must dictate a poll interval';
    RAISE NOTICE 'OK 30: the Hinge daemon contract — substrate-driven (interval from config) and obeys the emergency stop (autonomy_paused forces should_run=false; the global pause halts the gate with the source and the digesters)';
END $$;

-- ── 31: route_on (42) — the data-driven conditional / loop-back stage edge that
--    generalizes the old hardcoded code-pr loop-backs. Loop-back increments a
--    counter; the cap routes to on_max_goto; a non-match falls through to the
--    normal forward advance; a null-goto rule halts. AND the code-pr migration
--    landed (review/plan_review carry route_on, not the retired hardcode).
DO $$
DECLARE
  v_intent uuid; v_wi uuid; v_wi2 uuid; v_ret text; v_n int; v_stage text; v_status text;
  v_review jsonb;
BEGIN
  INSERT INTO stewards.intents (slug, purpose) VALUES ('rt-smoke','route_on smoke')
    RETURNING id INTO v_intent;
  INSERT INTO stewards.pipelines (family, stages) VALUES
  ('rt-test', jsonb_build_array(
    jsonb_build_object('name','a','next','b','route_on', jsonb_build_array(
      jsonb_build_object('when','BACK','goto','a','count_key','n','max',2,'on_max_goto','b'),
      jsonb_build_object('when','STOP','goto', null))),
    jsonb_build_object('name','b','next', null)));

  -- loop-back (n 0->1->2), then cap -> on_max_goto
  INSERT INTO stewards.work_items (pipeline_family, current_stage, intent_id, status)
    VALUES ('rt-test','a',v_intent,'in_progress') RETURNING id INTO v_wi;
  v_ret := stewards.work_item_advance(v_wi, '{"output":"go BACK"}'::jsonb);
  SELECT current_stage, (input->>'n')::int INTO v_stage, v_n FROM stewards.work_items WHERE id=v_wi;
  ASSERT v_ret='a' AND v_stage='a' AND v_n=1, format('route_on loop-back: ret=%s stage=%s n=%s', v_ret, v_stage, v_n);
  v_ret := stewards.work_item_advance(v_wi, '{"output":"BACK"}'::jsonb);
  ASSERT v_ret='a' AND (SELECT (input->>'n')::int FROM stewards.work_items WHERE id=v_wi)=2, 'route_on 2nd loop';
  v_ret := stewards.work_item_advance(v_wi, '{"output":"BACK"}'::jsonb);
  ASSERT v_ret='b', format('route_on cap->on_max_goto: ret=%s', v_ret);

  -- no match -> normal advance; null-goto -> halt
  INSERT INTO stewards.work_items (pipeline_family, current_stage, intent_id, status)
    VALUES ('rt-test','a',v_intent,'in_progress') RETURNING id INTO v_wi2;
  ASSERT stewards.work_item_advance(v_wi2, '{"output":"DONE"}'::jsonb)='b', 'route_on no-match must advance to b';
  INSERT INTO stewards.work_items (pipeline_family, current_stage, intent_id, status)
    VALUES ('rt-test','a',v_intent,'in_progress') RETURNING id INTO v_wi2;
  v_ret := stewards.work_item_advance(v_wi2, '{"output":"STOP"}'::jsonb);
  SELECT status INTO v_status FROM stewards.work_items WHERE id=v_wi2;
  ASSERT v_ret IS NULL AND v_status='cancelled', format('route_on null-goto halt: ret=%s status=%s', v_ret, v_status);

  -- the code-pr loop-backs migrated to route_on data (the hardcode is retired)
  SELECT s INTO v_review FROM stewards.pipelines, jsonb_array_elements(stages) s
   WHERE family='code-pr' AND s->>'name'='review';
  ASSERT v_review->'route_on'->0->>'goto' = 'implement',
    'code-pr review must carry route_on goto=implement (cv6 migrated)';

  DELETE FROM stewards.work_items WHERE pipeline_family='rt-test';
  DELETE FROM stewards.pipelines WHERE family='rt-test';
  DELETE FROM stewards.intents WHERE id=v_intent;
  RAISE NOTICE 'OK 31: route_on — loop-back + counter + cap->on_max_goto + no-match-advance + null-goto-halt; code-pr cv6/cv11 migrated to route_on data (hardcode retired)';
END $$;

-- ── 32: request_research + gather-feedback (43) — primitive B as core. The
--    gather-feedback tool_group resolves to request_research; a scoped analyze stage
--    ships it as a real allow-list that narrows the firehose; calling request_research
--    parks a targeted, deduped, approve-gated reqres proposal into the reflect queue.
DO $$
DECLARE
  v_intent uuid; v_scope text[]; v_full jsonb; v_scoped jsonb;
  v_has_rr bool; v_all_in_scope bool; v_ret text; v_q text := 'rr-smoke gap question';
  v_wi stewards.work_items; v_dupe int;
BEGIN
  INSERT INTO stewards.intents (slug, purpose) VALUES ('rr-smoke','request_research smoke')
    RETURNING id INTO v_intent;

  -- the group resolves to exactly request_research
  ASSERT stewards.resolve_tool_scope('["gather-feedback"]'::jsonb) = ARRAY['request_research'],
    'gather-feedback must resolve to request_research';

  -- a scoped analyze stage (research family) ships request_research as a real allow-list
  v_scope  := stewards.resolve_tool_scope('["substrate-read","gather-feedback"]'::jsonb);
  v_full   := stewards.compose_tools('research');
  v_scoped := stewards.compose_tools_scoped('research', v_scope);
  SELECT bool_or(e->'function'->>'name'='request_research') INTO v_has_rr
    FROM jsonb_array_elements(v_scoped) e;
  ASSERT v_has_rr, 'scoped research stage must ship request_research';
  SELECT bool_and(EXISTS (SELECT 1 FROM unnest(v_scope) pat
            WHERE stewards.glob_match(pat, e->'function'->>'name'))) INTO v_all_in_scope
    FROM jsonb_array_elements(v_scoped) e;
  ASSERT v_all_in_scope, 'every scoped tool must match a declared pattern (allow-list)';
  ASSERT jsonb_array_length(v_scoped) < jsonb_array_length(v_full),
    'scope must narrow the research firehose';

  -- calling request_research parks a targeted reqres proposal; dedup holds
  v_ret := stewards.request_research_tool(jsonb_build_object('question', v_q, 'project', 'rr-smoke'));
  ASSERT (v_ret::jsonb->>'ok')::bool AND (v_ret::jsonb ? 'queued_as'), format('request_research queue: %s', v_ret);
  SELECT * INTO v_wi FROM stewards.work_items
   WHERE slug LIKE 'reqres-%' AND lower(input->>'binding_question')=lower(v_q) ORDER BY id DESC LIMIT 1;
  ASSERT v_wi.status='pending' AND v_wi.origin='agent_planning' AND v_wi.pipeline_family='research-write',
    'reqres parked pending/agent_planning/research-write';
  v_ret := stewards.request_research_tool(jsonb_build_object('question', v_q, 'project', 'rr-smoke'));
  ASSERT (v_ret::jsonb->>'note') LIKE '%not duplicated%', 'second identical request must dedup';
  SELECT count(*) INTO v_dupe FROM stewards.work_items
   WHERE slug LIKE 'reqres-%' AND lower(input->>'binding_question')=lower(v_q) AND status='pending';
  ASSERT v_dupe=1, 'exactly one pending reqres after dedup';

  DELETE FROM stewards.work_items WHERE intent_id=v_intent;
  DELETE FROM stewards.intents WHERE id=v_intent;
  RAISE NOTICE 'OK 32: request_research + gather-feedback (B) — group resolves, scoped allow-list narrows the firehose, targeted reqres proposal parked, dedup holds';
END $$;

-- ── 33: the organize keystone (44) — graph_node creates a freshness-stamped node;
--    graph_link asserts a typed edge; graph_supersede ages a node out (status +
--    SUPERSEDES edge); graph_recall fresh_only omits the superseded node while plain
--    recall still reaches it. The graph-organize/graph-read tool_groups resolve.
DO $$
DECLARE
  v_n1 text; v_sup text; v_recall_all jsonb; v_recall_fresh jsonb; v_status text;
BEGIN
  -- node-maker stamps observed_at + status=current
  v_n1 := stewards.graph_node_tool('{"kind":"oz-fault","ref":"oz-billing-1","label":"billing glitch"}'::jsonb);
  ASSERT (v_n1::jsonb->>'ok')::bool, format('graph_node: %s', v_n1);
  ASSERT (SELECT props->>'status' FROM stewards.nodes WHERE kind='oz-fault' AND ref='oz-billing-1')='current'
     AND (SELECT props ? 'observed_at' FROM stewards.nodes WHERE kind='oz-fault' AND ref='oz-billing-1'),
     'graph_node must stamp status=current + observed_at';

  -- a successor + supersede: old marked, new SUPERSEDES old
  PERFORM stewards.graph_node_tool('{"kind":"oz-fault","ref":"oz-billing-2","label":"billing fixed in v2"}'::jsonb);
  v_sup := stewards.graph_supersede_tool('{"old_kind":"oz-fault","old_ref":"oz-billing-1","new_kind":"oz-fault","new_ref":"oz-billing-2","reason":"resolved in v2"}'::jsonb);
  ASSERT (v_sup::jsonb->>'ok')::bool, format('graph_supersede: %s', v_sup);
  SELECT props->>'status' INTO v_status FROM stewards.nodes WHERE kind='oz-fault' AND ref='oz-billing-1';
  ASSERT v_status='superseded', format('old node must be superseded, got %s', v_status);
  ASSERT EXISTS (SELECT 1 FROM stewards.edges e
                  JOIN stewards.nodes s ON s.id=e.src JOIN stewards.nodes d ON d.id=e.dst
                 WHERE e.kind='SUPERSEDES' AND s.ref='oz-billing-2' AND d.ref='oz-billing-1'),
     'a SUPERSEDES edge (new->old) must exist';

  -- recall from the successor: plain reaches the superseded old; fresh_only omits it
  v_recall_all   := stewards.graph_recall_tool('{"kind":"oz-fault","ref":"oz-billing-2","max_hops":2}'::jsonb)::jsonb;
  v_recall_fresh := stewards.graph_recall_tool('{"kind":"oz-fault","ref":"oz-billing-2","max_hops":2,"fresh_only":true}'::jsonb)::jsonb;
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(v_recall_all) e WHERE e->>'ref'='oz-billing-1'),
     'plain recall must reach the superseded node';
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_recall_fresh) e WHERE e->>'ref'='oz-billing-1'),
     'fresh_only recall must omit the superseded node';

  -- the scopes resolve
  ASSERT 'graph_node' = ANY(stewards.resolve_tool_scope('["graph-organize"]'::jsonb))
     AND 'graph_supersede' = ANY(stewards.resolve_tool_scope('["graph-organize"]'::jsonb)),
     'graph-organize must scope graph_node + graph_supersede';
  ASSERT stewards.resolve_tool_scope('["graph-read"]'::jsonb) @> ARRAY['graph_recall'],
     'graph-read must scope graph_recall';

  DELETE FROM stewards.edges WHERE src IN (SELECT id FROM stewards.nodes WHERE kind='oz-fault')
                                OR dst IN (SELECT id FROM stewards.nodes WHERE kind='oz-fault');
  DELETE FROM stewards.nodes WHERE kind='oz-fault';
  RAISE NOTICE 'OK 33: organize keystone — graph_node (freshness-stamped), graph_supersede (status + SUPERSEDES edge), graph_recall fresh_only filter, graph-organize/graph-read scopes';
END $$;

-- ---------------------------------------------------------------------
-- 45-work-item-chat — "chat with a work item": a read-only retrieval agent +
-- dispatch_chat_turn (persistent chat sessions). Assert the objects exist and
-- the grant is a read-only allow-list (deny '*' base). No dispatch here — smoke
-- is vector-only / no rig.
-- ---------------------------------------------------------------------
DO $$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM stewards.agents WHERE family='work-item-chat' AND active),
     'work-item-chat agent must exist + be active';
  ASSERT EXISTS (SELECT 1 FROM stewards.agent_tool_perms
                  WHERE agent_family='work-item-chat' AND tool_pattern='*' AND action='deny'),
     'work-item-chat must deny * (read-only allow-list base)';
  ASSERT (SELECT action FROM stewards.agent_tool_perms
           WHERE agent_family='work-item-chat' AND tool_pattern='doc_get')='allow',
     'work-item-chat must allow doc_get';
  ASSERT NOT EXISTS (SELECT 1 FROM stewards.agent_tool_perms
                      WHERE agent_family='work-item-chat'
                        AND tool_pattern IN ('fetch_url','doc_create','work_item_create')
                        AND action='allow'),
     'work-item-chat must NOT allow write/egress tools';
  -- 47 extended dispatch_chat_turn to a 6th optional p_content_parts jsonb; the
  -- 5-arg overload is dropped (a 5-arg call would be ambiguous with the defaulted
  -- 6-arg). Assert on pronargs + the last arg type (jsonb) — robust across pg
  -- versions (pg_get_function_identity_arguments formatting varies).
  ASSERT EXISTS (SELECT 1 FROM pg_proc
                  WHERE proname='dispatch_chat_turn' AND pronargs=6
                    AND proargtypes[5]='jsonb'::regtype),
     'dispatch_chat_turn must have 6 args with a jsonb 6th (47 multimodal arg)';
  ASSERT NOT EXISTS (SELECT 1 FROM pg_proc
                      WHERE proname='dispatch_chat_turn' AND pronargs=5),
     'the old 5-arg dispatch_chat_turn must be dropped (would be ambiguous with the 6-arg defaulted overload)';
  RAISE NOTICE 'OK 34: work-item-chat — read-only retrieval agent (deny * + allow-list) + dispatch_chat_turn helper';
END $$;

-- ---------------------------------------------------------------------
-- 46 — chat delegation: the chat can start a sub work_item (Delegate mode),
-- but still cannot call work_item_create directly (it goes through start_task,
-- the controlled wrapper that parent-links + dispatches).
-- ---------------------------------------------------------------------
DO $$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM pg_proc WHERE proname='chat_start_task_tool'),
     'chat_start_task_tool must exist';
  ASSERT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name='start_task' AND active),
     'start_task tool must be registered + active';
  ASSERT (SELECT action FROM stewards.agent_tool_perms
           WHERE agent_family='work-item-chat' AND tool_pattern='start_task')='allow',
     'work-item-chat must allow start_task';
  ASSERT NOT EXISTS (SELECT 1 FROM stewards.agent_tool_perms
                      WHERE agent_family='work-item-chat' AND tool_pattern='work_item_create' AND action='allow'),
     'work-item-chat must NOT call work_item_create directly (start_task is the controlled path)';
  RAISE NOTICE 'OK 35: chat delegation — start_task spawns a parent-linked sub work_item (Delegate mode)';
END $$;

-- ---------------------------------------------------------------------
-- 47 — rich documents in chat, P1: the substrate carries an image.
-- content_parts jsonb on messages + supports_vision capability bit +
-- compose_messages passes a content_parts row through as a verbatim ARRAY
-- (no [ctx:] prefix, no page-in cap on arrays).
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_msgs jsonb;
  v_user jsonb;
BEGIN
  ASSERT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='stewards' AND table_name='messages'
                    AND column_name='content_parts' AND data_type='jsonb'),
     'messages.content_parts jsonb must exist (multimodal content array)';
  ASSERT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema='stewards' AND table_name='model_capability'
                    AND column_name='supports_vision'),
     'model_capability.supports_vision must exist';
  ASSERT stewards.model_supports_vision('nope','nope') = false,
     'model_supports_vision defaults false for an unflagged model';
  -- page_in_cap must pass an ARRAY-content message through untouched (never
  -- truncate it to a corrupting string), even with a tiny cap.
  ASSERT jsonb_typeof(stewards.page_in_cap(
           jsonb_build_object('role','user','content',
             jsonb_build_array(jsonb_build_object('type','text','text','hi'),
                               jsonb_build_object('type','image_url','image_url',
                                 jsonb_build_object('url','data:image/png;base64,AAAA')))),
           5, 'abcd') -> 'content') = 'array',
     'page_in_cap must pass multimodal ARRAY content through untouched';
  -- compose_messages must render a content_parts row as a verbatim array.
  INSERT INTO stewards.sessions (id, label, kind)
    VALUES ('virgin-mm-smoke', 'mm smoke', 'chat') ON CONFLICT (id) DO NOTHING;
  INSERT INTO stewards.messages (session_id, role, content, content_parts)
    VALUES ('virgin-mm-smoke', 'user', 'what is in this image?',
            jsonb_build_array(jsonb_build_object('type','text','text','what is in this image?'),
                              jsonb_build_object('type','image_url','image_url',
                                jsonb_build_object('url','data:image/png;base64,iVBORw0KGgo='))));
  v_msgs := stewards.compose_messages('work-item-chat', 'x', 'virgin-mm-smoke', NULL);
  -- find the user row in the composed array; its content must be an ARRAY with an image_url part.
  SELECT e INTO v_user
    FROM jsonb_array_elements(v_msgs) e
   WHERE e->>'role' = 'user' AND jsonb_typeof(e->'content') = 'array'
   LIMIT 1;
  ASSERT v_user IS NOT NULL,
     'compose_messages must emit the content_parts row with an ARRAY content';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(v_user->'content') p
                  WHERE p->>'type' = 'image_url'),
     'the composed multimodal user content must carry the image_url part verbatim';
  DELETE FROM stewards.sessions WHERE id = 'virgin-mm-smoke';  -- cascades messages
  RAISE NOTICE 'OK 36: multimodal — content_parts column + compose_messages array passthrough + page_in_cap array guard';
END $$;

-- ---------------------------------------------------------------------
-- 48 — rich documents in chat, P2: chat_attachments + chat_attachment_parts.
-- A session-scoped attachment assembles into a 47 content_parts array (image ->
-- image_url with a server-built data URL); the helper is session-scoped (no
-- cross-session injection) and returns NULL when nothing resolves.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_a1 bigint;
  v_a2 bigint;
  v_parts jsonb;
BEGIN
  ASSERT EXISTS (SELECT 1 FROM information_schema.tables
                  WHERE table_schema='stewards' AND table_name='chat_attachments'),
     'chat_attachments table must exist';
  -- a 1x1 png (bytes), session 'att-smoke'
  INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, bytes, byte_size)
    VALUES ('att-smoke','dot.png','image/png','image', decode('89504e470d0a1a0a','hex'), 8)
    RETURNING id INTO v_a1;
  -- a DIFFERENT session's attachment must NOT be injectable into att-smoke
  INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, bytes, byte_size)
    VALUES ('other-sess','x.png','image/png','image', decode('89504e470d0a1a0a','hex'), 8)
    RETURNING id INTO v_a2;
  v_parts := stewards.chat_attachment_parts(ARRAY[v_a1, v_a2], 'att-smoke');
  ASSERT v_parts IS NOT NULL AND jsonb_typeof(v_parts)='array' AND jsonb_array_length(v_parts)=1,
     'chat_attachment_parts must return exactly the session-owned attachment (1, not the other session''s)';
  ASSERT v_parts->0->>'type'='image_url'
         AND (v_parts->0->'image_url'->>'url') LIKE 'data:image/png;base64,%',
     'an image attachment must become an image_url part with a server-built data URL';
  ASSERT (SELECT consumed_at IS NOT NULL FROM stewards.chat_attachments WHERE id=v_a1),
     'chat_attachment_parts must mark the injected attachment consumed';
  ASSERT stewards.chat_attachment_parts(ARRAY[]::bigint[], 'att-smoke') IS NULL
         AND stewards.chat_attachment_parts(NULL, 'att-smoke') IS NULL,
     'chat_attachment_parts must return NULL for no ids (text-only fallback)';
  DELETE FROM stewards.chat_attachments WHERE session_id IN ('att-smoke','other-sess');
  RAISE NOTICE 'OK 37: chat attachments — session-scoped media -> content_parts (image_url data URL), consumed-marking, NULL-when-empty';
END $$;

-- ---------------------------------------------------------------------
-- 49 — rich documents in chat, P3: doc-extract surface. parent_id + scan
-- columns on chat_attachments; chat_attachment_parts surfaces a document's
-- extracted text (or a doc_extract nudge) AND its rendered page images (the
-- pixel overlay); the doc-extract MCP server is registered + doc_extract is
-- granted to work-item-chat.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_doc   bigint;
  v_page  bigint;
  v_raw   bigint;
  v_parts jsonb;
BEGIN
  -- columns exist
  ASSERT (SELECT count(*) FROM information_schema.columns
           WHERE table_schema='stewards' AND table_name='chat_attachments'
             AND column_name IN ('parent_id','scan_verdict','scan_findings')) = 3,
     '49: chat_attachments must gain parent_id + scan_verdict + scan_findings';

  -- an EXTRACTED document + a rendered page image child of it
  INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, byte_size, extracted_text, scan_verdict)
    VALUES ('dx-smoke','report.pdf','application/pdf','document', 0, 'Quarterly revenue rose 12%.', 'clean')
    RETURNING id INTO v_doc;
  INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, bytes, byte_size, parent_id)
    VALUES ('dx-smoke','report-p1.png','image/png','image', decode('89504e470d0a1a0a','hex'), 8, v_doc)
    RETURNING id INTO v_page;

  -- referencing ONLY the document must surface its text part AND its page image
  -- (the overlay), document text first.
  v_parts := stewards.chat_attachment_parts(ARRAY[v_doc], 'dx-smoke');
  ASSERT v_parts IS NOT NULL AND jsonb_array_length(v_parts) = 2,
     '49: a referenced document must surface its text part + its page-image overlay (2 parts)';
  ASSERT v_parts->0->>'type' = 'text' AND (v_parts->0->>'text') LIKE '%Quarterly revenue%',
     '49: the document text part must come first and carry the extracted text';
  ASSERT v_parts->1->>'type' = 'image_url'
         AND (v_parts->1->'image_url'->>'url') LIKE 'data:image/png;base64,%',
     '49: the rendered page image must ride along as the pixel overlay';

  -- an UN-extracted document must surface a doc_extract nudge
  INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, byte_size)
    VALUES ('dx-smoke','unread.pdf','application/pdf','document', 0)
    RETURNING id INTO v_raw;
  v_parts := stewards.chat_attachment_parts(ARRAY[v_raw], 'dx-smoke');
  ASSERT v_parts IS NOT NULL AND (v_parts->0->>'text') LIKE '%doc_extract%',
     '49: an unread document must surface a doc_extract nudge';

  -- server + grant
  ASSERT EXISTS (SELECT 1 FROM stewards.mcp_servers WHERE name='doc-extract' AND enabled),
     '49: the doc-extract MCP server must be registered + enabled';
  ASSERT (SELECT count(*) FROM stewards.agent_tool_perms
                  WHERE agent_family='work-item-chat'
                    AND tool_pattern IN ('doc_extract','doc_import_corpus') AND action='allow') = 2,
     '49: doc_extract + doc_import_corpus must be granted to the work-item-chat agent';

  DELETE FROM stewards.chat_attachments WHERE session_id='dx-smoke';
  RAISE NOTICE 'OK 38: doc-extract surface — parent-linked page overlay + doc_extract nudge + server + grant';
END $$;

-- ---------------------------------------------------------------------
-- 49 P4 — chat_task_input folds a chat session's extracted document
-- attachments into the spawned task's binding question (so any pipeline
-- carries the subject material) + attachment_ids.
-- ---------------------------------------------------------------------
DO $$
DECLARE
  v_a     bigint;
  v_input jsonb;
BEGIN
  INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, byte_size, extracted_text)
    VALUES ('stewdio-p4', 'brief.pdf', 'application/pdf', 'document', 0, 'The Q3 brief: ship the widget by October.')
    RETURNING id INTO v_a;
  v_input := stewards.chat_task_input('stewdio-p4', 'plan the launch');
  ASSERT (v_input->>'binding_question') LIKE '%plan the launch%'
         AND (v_input->>'binding_question') LIKE '%ship the widget by October%'
         AND (v_input->>'binding_question') LIKE '%Attached subject material%',
     '49/P4: chat_task_input must fold the attached document text into the binding question';
  ASSERT v_input ? 'attachment_ids' AND (v_input->'attachment_ids')->>0 = v_a::text,
     '49/P4: chat_task_input must carry the attachment_ids';
  -- a session with no attachments just carries the question (no subject-material header)
  v_input := stewards.chat_task_input('stewdio-empty', 'just a question');
  ASSERT (v_input->>'binding_question') = 'just a question' AND NOT (v_input ? 'attachment_ids'),
     '49/P4: a session with no document attachments carries only the question';
  ASSERT (v_input ? 'sandbox') AND (v_input->>'sandbox') LIKE 'task-%',
     '49/P4: chat_task_input must seed a stable sandbox id for coder/doc-build spawns';
  DELETE FROM stewards.chat_attachments WHERE session_id = 'stewdio-p4';
  RAISE NOTICE 'OK 39: P4 — spawned work carries the chat''s extracted document attachments + a sandbox id';
END $$;

-- ---------------------------------------------------------------------
-- 50 — Arc B doc-build: the doc-build pipeline (generate documents in the
-- coder sandbox) + the coder_export_artifact grant.
-- ---------------------------------------------------------------------
DO $$
BEGIN
  ASSERT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family='doc-build'),
     '50: the doc-build pipeline must be seeded';
  ASSERT (SELECT jsonb_array_length(stages) FROM stewards.pipelines WHERE family='doc-build') = 3,
     '50: doc-build must have plan/build/deliver stages';
  ASSERT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family='doc-build'
                  AND stages::text LIKE '%coder_export_artifact%'),
     '50: the doc-build build stage must export the artifact';
  ASSERT EXISTS (SELECT 1 FROM stewards.agent_tool_perms
                  WHERE agent_family='dev' AND tool_pattern='coder_export_artifact' AND action='allow'),
     '50: coder_export_artifact must be granted to the dev agent';
  RAISE NOTICE 'OK 40: doc-build — pipeline (plan/build/deliver) + coder_export_artifact grant';
END $$;

-- ---------------------------------------------------------------------
-- 51 — rich-chat hardening: the doc-build artifact-exists gate (an empty
-- build must FAIL, not pose as success) + the chat→brainstorm grant.
-- ---------------------------------------------------------------------
DO $$
DECLARE v_wi uuid; v_status text;
BEGIN
  ASSERT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname='doc_build_verify_artifact_trg'),
     '51: the doc-build artifact-exists gate trigger must exist';
  -- A doc-build that completes with NO exported artifact must be flipped to failed.
  v_wi := stewards.work_item_create('doc-build',
            jsonb_build_object('spawned_from_chat','vs-gate-test','binding_question','x'),
            'vs-gate-test', 'dev', NULL::int, NULL::uuid);
  UPDATE stewards.work_items SET status='completed' WHERE id=v_wi;
  SELECT status INTO v_status FROM stewards.work_items WHERE id=v_wi;
  ASSERT v_status='failed',
     '51: doc-build completing with no artifact must flip to failed (got '||v_status||')';
  -- With an artifact present for the session, completion stands.
  INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, bytes, byte_size)
    VALUES ('vs-gate-test','d.pdf','application/pdf','document','\x25504446'::bytea, 4);
  UPDATE stewards.work_items SET status='in_progress' WHERE id=v_wi;
  UPDATE stewards.work_items SET status='completed' WHERE id=v_wi;
  SELECT status INTO v_status FROM stewards.work_items WHERE id=v_wi;
  ASSERT v_status='completed',
     '51: doc-build completing WITH an artifact must stay completed (got '||v_status||')';
  DELETE FROM stewards.work_items WHERE id=v_wi;
  DELETE FROM stewards.chat_attachments WHERE session_id='vs-gate-test';
  -- chat → brainstorm grant.
  ASSERT EXISTS (SELECT 1 FROM stewards.agent_tool_perms
                  WHERE agent_family='work-item-chat' AND tool_pattern='start_brainstorm' AND action='allow'),
     '51: work-item-chat must be granted start_brainstorm (chat→brainstorm)';
  ASSERT EXISTS (SELECT 1 FROM stewards.agent_tool_perms
                  WHERE agent_family='work-item-chat' AND tool_pattern='generate_image' AND action='allow'),
     '51: work-item-chat must be granted generate_image';
  RAISE NOTICE 'OK 41: artifact gate (empty doc-build → failed) + chat→brainstorm + generate_image grants';
END $$;

\echo '== ALL VIRGIN-SMOKE ASSERTIONS PASSED — the authored chain (00→51) is sound =='
