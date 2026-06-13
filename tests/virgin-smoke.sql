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
    -- fetch-md, git). No personal/keyed servers (gospel-engine, webster, yt,
    -- web search, etc.) leak in — web search needs an operator key, so it is
    -- overlay/BYO, NOT core.
    SELECT count(*) INTO n FROM stewards.mcp_servers
     WHERE name IN ('gospel-engine','gospel-engine-v2','webster','yt','search',
                    'exa-search','byu-citations','becoming','strongs');
    ASSERT n=0, format('personal MCP servers must NOT be in core, found %s', n);
    ASSERT (SELECT count(*) FROM stewards.mcp_servers
             WHERE name IN ('fs-read','pg-ai-stewards','fetch-md','git')) = 4,
        'the generic core MCP servers (fs-read, pg-ai-stewards, fetch-md, git) must be seeded';
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

\echo '== ALL VIRGIN-SMOKE ASSERTIONS PASSED — the authored chain (00→19) is sound =='
