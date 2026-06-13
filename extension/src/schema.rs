//! In-Rust-source schema definitions: all the `extension_sql!` blocks
//! that define `stewards.work_queue`, brain entries, agents, skills,
//! tool_defs, instructions, sessions, messages, studies, AGE citations,
//! similarity helpers, and chat helpers.
//!
//! These declarative blocks expand to Postgres DDL at `CREATE EXTENSION`
//! time. Per the pgrx-rust skill, `extension_sql!` works in any module —
//! pgrx's SQL emitter walks the entire crate via `pgrx_embed.rs` and
//! harvests metadata symbols regardless of source-file location.
//!
//! NOTE: `extension_sql_file!` macros (which load SQL from external
//! files) stay in `lib.rs`. Their relative paths reference the
//! `extension_sql_file!` *file location* — keeping them at crate root
//! avoids accidentally rewriting paths during a refactor.
//!
//! Extracted from lib.rs as Phase 3c.3.6 v5 (2026-05-08).

use pgrx::prelude::*;

// ---------------------------------------------------------------------------
// Schema bootstrap (creates table on `CREATE EXTENSION`)
// ---------------------------------------------------------------------------

extension_sql!(
    r#"
    -- The `stewards` schema is declared in pg_ai_stewards.control;
    -- pgrx creates it automatically when the extension is installed.

    CREATE TABLE stewards.work_queue (
        id          bigserial PRIMARY KEY,
        kind        text NOT NULL,
        provider    text NOT NULL,
        status      text NOT NULL DEFAULT 'pending'
                    -- 'waiting_for_tools' (3e.2.b, born here at
                    -- consolidation): a tool_dispatch row parked while
                    -- its async mcp_proxy children resolve.
                    CHECK (status IN ('pending', 'in_progress',
                                      'waiting_for_tools', 'done', 'error')),
        payload     jsonb NOT NULL DEFAULT '{}'::jsonb,
        result      jsonb,
        error       text,
        created_at  timestamptz NOT NULL DEFAULT now(),
        claimed_at  timestamptz,
        done_at     timestamptz
    );

    -- Index supporting the worker's claim query.
    CREATE INDEX work_queue_pending_idx
        ON stewards.work_queue (created_at)
        WHERE status = 'pending';
    "#,
    name = "create_work_queue",
);

extension_sql!(
    r#"
    -- ============================================================
    -- Step 3: brain replacement schema.
    --
    -- Single brain_entries table with a category enum + jsonb props,
    -- chosen over six per-category tables because it matches how
    -- chromem-go stores them today and keeps the migrator simple.
    -- Category-specific fields (name, follow_ups, status, due_date,
    -- mood, gratitude, ...) all live in `props`.
    --
    -- Categories enumerated in the CHECK constraint below come from
    -- scripts/brain/internal/classifier/classifier.go (the six the
    -- LLM classifier emits) plus 'inbox' (the unclassified default
    -- set by classifier.go and web/server.go). Read from code per
    -- the data-safety checklist; do NOT add categories from memory.
    -- ============================================================

    CREATE TABLE stewards.brain_entries (
        id              text PRIMARY KEY DEFAULT gen_random_uuid()::text,
        category        text NOT NULL
                        CHECK (category IN
                            ('people','projects','ideas','actions',
                             'study','journal','inbox')),
        title           text NOT NULL,
        body            text NOT NULL DEFAULT '',
        props           jsonb NOT NULL DEFAULT '{}'::jsonb,

        -- Provenance + classification metadata
        source          text NOT NULL DEFAULT 'cli',
        confidence      real NOT NULL DEFAULT 0.0,
        needs_review    boolean NOT NULL DEFAULT false,
        quarantined     boolean NOT NULL DEFAULT false,
        original_body   text,

        -- Embedding (populated async by bgworker; see embed trigger
        -- below + step 6/7 for the actual provider call).
        embedding       vector(768),
        embedded_at     timestamptz,
        embedded_model  text,
        embedding_error text,

        -- Full-text search column maintained automatically.
        body_tsv        tsvector
                        GENERATED ALWAYS AS (
                            to_tsvector('english',
                                coalesce(title, '') || ' ' || coalesce(body, ''))
                        ) STORED,

        created_at      timestamptz NOT NULL DEFAULT now(),
        updated_at      timestamptz NOT NULL DEFAULT now()
    );

    CREATE INDEX brain_entries_category_idx
        ON stewards.brain_entries (category);
    CREATE INDEX brain_entries_created_idx
        ON stewards.brain_entries (created_at DESC);
    CREATE INDEX brain_entries_needs_review_idx
        ON stewards.brain_entries (needs_review)
        WHERE needs_review = true;
    CREATE INDEX brain_entries_fts_idx
        ON stewards.brain_entries USING gin (body_tsv);
    CREATE INDEX brain_entries_props_idx
        ON stewards.brain_entries USING gin (props);

    -- HNSW index for cosine similarity. NULL embeddings are skipped
    -- by the index naturally; we filter them in queries too.
    CREATE INDEX brain_entries_embedding_idx
        ON stewards.brain_entries
        USING hnsw (embedding vector_cosine_ops);

    -- Tags split out for query / index efficiency. Mirrors the
    -- existing brain SQLite layout.
    CREATE TABLE stewards.brain_entry_tags (
        entry_id text NOT NULL
                 REFERENCES stewards.brain_entries(id) ON DELETE CASCADE,
        tag      text NOT NULL,
        PRIMARY KEY (entry_id, tag)
    );
    CREATE INDEX brain_entry_tags_tag_idx
        ON stewards.brain_entry_tags (tag);

    CREATE TABLE stewards.brain_subtasks (
        id          bigserial PRIMARY KEY,
        entry_id    text NOT NULL
                    REFERENCES stewards.brain_entries(id) ON DELETE CASCADE,
        body        text NOT NULL,
        done        boolean NOT NULL DEFAULT false,
        sort_order  int NOT NULL DEFAULT 0,
        created_at  timestamptz NOT NULL DEFAULT now(),
        updated_at  timestamptz NOT NULL DEFAULT now()
    );
    CREATE INDEX brain_subtasks_entry_idx
        ON stewards.brain_subtasks (entry_id, sort_order);

    -- Snapshot history. Captures (title, category, body, props) at
    -- mutation time; the touch_updated_at trigger inserts here on UPDATE.
    CREATE TABLE stewards.brain_versions (
        id          bigserial PRIMARY KEY,
        entry_id    text NOT NULL
                    REFERENCES stewards.brain_entries(id) ON DELETE CASCADE,
        title       text NOT NULL,
        category    text NOT NULL,
        body        text NOT NULL,
        props       jsonb NOT NULL DEFAULT '{}'::jsonb,
        changed_by  text NOT NULL DEFAULT 'system',
        changed_at  timestamptz NOT NULL DEFAULT now()
    );
    CREATE INDEX brain_versions_entry_idx
        ON stewards.brain_versions (entry_id, changed_at DESC);

    -- ============================================================
    -- Sessions + messages (basic conversation log).
    -- Goal: have something to embed and query end-to-end so step 6
    -- can prove the round-trip on more than a single table.
    -- ============================================================

    CREATE TABLE stewards.sessions (
        id              text PRIMARY KEY DEFAULT gen_random_uuid()::text,
        label           text,
        -- Born-complete kind set: gate (08), sabbath/atonement (10), and
        -- council (12) session kinds are folded in here so those subsystem
        -- files don't churn the constraint. Named so the historical
        -- per-phase ADD CONSTRAINT statements are no longer needed.
        kind            text NOT NULL DEFAULT 'chat'
                        CONSTRAINT sessions_kind_check
                        CHECK (kind IN ('chat','agent','tool','study','dev',
                                        'gate','sabbath','atonement','council')),
        created_at      timestamptz NOT NULL DEFAULT now(),
        last_active_at  timestamptz NOT NULL DEFAULT now()
    );

    CREATE TABLE stewards.messages (
        id              bigserial PRIMARY KEY,
        session_id      text NOT NULL
                        REFERENCES stewards.sessions(id) ON DELETE CASCADE,
        role            text NOT NULL
                        CHECK (role IN ('user','assistant','system','tool')),
        content         text NOT NULL DEFAULT '',
        model           text,
        tokens_in       int,
        tokens_out      int,
        -- Reasoning tokens are billed separately by some providers
        -- (kimi-k2.6 via OpenCode reports them under
        -- usage.completion_tokens_details.reasoning_tokens). They
        -- are NOT included in tokens_out, so cost computation must
        -- sum both. Captured here so we don't under-count.
        reasoning_tokens int,
        cost_usd        numeric(10, 6),

        -- Assistant messages may carry tool_calls instead of (or in
        -- addition to) content. Stored verbatim; Phase 1.6's loop
        -- will read this to dispatch tools. Step 7 just records.
        tool_calls      jsonb,
        finish_reason   text,
        tool_call_id    text,        -- set on role='tool' replies

        -- Reasoning fields. Required for echo-back when continuing a
        -- chat with thinking-enabled models (kimi-k2.6, o1-class).
        -- Without these, Moonshot returns 400:
        --   "thinking is enabled but reasoning_content is missing in
        --    assistant tool call message at index N"
        -- Capture both shapes — plain `reasoning` is what OpenRouter
        -- emits; `reasoning_details` is the structured array. We
        -- echo both back on the next request for cross-provider safety.
        reasoning_content text,
        reasoning_details jsonb,

        -- For role='tool' messages: which work_queue tool_dispatch
        -- row produced this. For 'assistant' messages: which 'chat'
        -- work_queue row produced this. NULL for 'user' / 'system'.
        -- Used for trace and to count loop iterations cleanly.
        parent_work_id  bigint REFERENCES stewards.work_queue(id) ON DELETE SET NULL,

        embedding       vector(768),
        embedded_at     timestamptz,
        embedded_model  text,
        embedding_error text,

        created_at      timestamptz NOT NULL DEFAULT now()
    );
    CREATE INDEX messages_session_idx
        ON stewards.messages (session_id, created_at);
    CREATE INDEX messages_embedding_idx
        ON stewards.messages
        USING hnsw (embedding vector_cosine_ops);

    -- ============================================================
    -- Triggers
    -- ============================================================

    -- Bump updated_at AND snapshot the previous version on UPDATE.
    -- Only snapshots when the *content* (title, category, body, props)
    -- actually changed. Embedding writes from the bgworker would
    -- otherwise create one junk brain_versions row per embed.
    CREATE FUNCTION stewards.touch_brain_entry() RETURNS trigger
    LANGUAGE plpgsql AS $func$
    BEGIN
        IF TG_OP = 'UPDATE' THEN
            IF NEW.title    IS DISTINCT FROM OLD.title
               OR NEW.category IS DISTINCT FROM OLD.category
               OR NEW.body     IS DISTINCT FROM OLD.body
               OR NEW.props    IS DISTINCT FROM OLD.props
            THEN
                INSERT INTO stewards.brain_versions
                    (entry_id, title, category, body, props, changed_by)
                VALUES
                    (OLD.id, OLD.title, OLD.category, OLD.body, OLD.props,
                     coalesce(current_setting('stewards.actor', true), 'system'));
                NEW.updated_at := now();
            END IF;
        END IF;
        RETURN NEW;
    END;
    $func$;

    CREATE TRIGGER brain_entries_touch
        BEFORE UPDATE ON stewards.brain_entries
        FOR EACH ROW EXECUTE FUNCTION stewards.touch_brain_entry();

    -- Enqueue an embedding job whenever title/body changes (or row
    -- is inserted). The bgworker (step 6) calls LM Studio's
    -- /v1/embeddings with model nomic-embed-text-v1.5 and writes
    -- the resulting 768-dim vector back to NEW.embedding.
    --
    -- Provider name 'lm_studio' resolves to the registry entry
    -- loaded from STEWARDS_PROVIDER_LM_STUDIO_*. Keep the embedding
    -- model consistent across stacks so stored vectors stay comparable.
    CREATE FUNCTION stewards.enqueue_brain_embed() RETURNS trigger
    LANGUAGE plpgsql AS $func$
    BEGIN
        IF TG_OP = 'INSERT'
           OR NEW.title IS DISTINCT FROM OLD.title
           OR NEW.body  IS DISTINCT FROM OLD.body
        THEN
            INSERT INTO stewards.work_queue (kind, provider, payload)
            VALUES (
                'embed',
                'lm_studio',
                jsonb_build_object(
                    'target_table', 'brain_entries',
                    'target_id',    NEW.id,
                    'text',         coalesce(NEW.title, '') || E'\n\n' || coalesce(NEW.body, ''),
                    'model',        'nomic-embed-text-v1.5',
                    'dimensions',   768
                )
            );
        END IF;
        RETURN NEW;
    END;
    $func$;

    CREATE TRIGGER brain_entries_enqueue_embed
        AFTER INSERT OR UPDATE OF title, body
        ON stewards.brain_entries
        FOR EACH ROW EXECUTE FUNCTION stewards.enqueue_brain_embed();

    CREATE FUNCTION stewards.touch_message() RETURNS trigger
    LANGUAGE plpgsql AS $func$
    BEGIN
        UPDATE stewards.sessions
        SET last_active_at = now()
        WHERE id = NEW.session_id;
        RETURN NEW;
    END;
    $func$;

    CREATE TRIGGER messages_touch_session
        AFTER INSERT ON stewards.messages
        FOR EACH ROW EXECUTE FUNCTION stewards.touch_message();

    -- ============================================================
    -- Helper SQL functions. Thin wrappers; the brain CLI driver
    -- (step 5) will call these instead of writing raw SQL.
    -- ============================================================

    -- Insert or update a brain entry. Returns the row's id.
    -- If `entry_id` is NULL a new id is generated and a row created;
    -- otherwise the matching row is updated. Tags are replaced wholesale
    -- (delete-then-insert under one transaction).
    CREATE FUNCTION stewards.brain_upsert(
        p_category text,
        p_title    text,
        p_body     text DEFAULT '',
        p_props    jsonb DEFAULT '{}'::jsonb,
        p_tags     text[] DEFAULT NULL,
        p_id       text DEFAULT NULL,
        p_source   text DEFAULT 'cli'
    ) RETURNS text
    LANGUAGE plpgsql AS $func$
    DECLARE
        v_id text;
    BEGIN
        IF p_id IS NULL THEN
            INSERT INTO stewards.brain_entries
                (category, title, body, props, source)
            VALUES
                (p_category, p_title, p_body, p_props, p_source)
            RETURNING id INTO v_id;
        ELSE
            INSERT INTO stewards.brain_entries
                (id, category, title, body, props, source)
            VALUES
                (p_id, p_category, p_title, p_body, p_props, p_source)
            ON CONFLICT (id) DO UPDATE SET
                category = EXCLUDED.category,
                title    = EXCLUDED.title,
                body     = EXCLUDED.body,
                props    = EXCLUDED.props,
                source   = EXCLUDED.source
            RETURNING id INTO v_id;
        END IF;

        IF p_tags IS NOT NULL THEN
            DELETE FROM stewards.brain_entry_tags WHERE entry_id = v_id;
            INSERT INTO stewards.brain_entry_tags (entry_id, tag)
            SELECT v_id, unnest(p_tags);
        END IF;

        RETURN v_id;
    END;
    $func$;

    -- Full-text search. Returns id, title, category, ts_rank score.
    CREATE FUNCTION stewards.brain_search_text(
        p_query    text,
        p_category text DEFAULT NULL,
        p_limit    int DEFAULT 20
    ) RETURNS TABLE (
        id       text,
        title    text,
        category text,
        rank     real
    )
    LANGUAGE sql STABLE AS $func$
        SELECT e.id, e.title, e.category,
               ts_rank(e.body_tsv, plainto_tsquery('english', p_query)) AS rank
        FROM stewards.brain_entries e
        WHERE e.body_tsv @@ plainto_tsquery('english', p_query)
          AND (p_category IS NULL OR e.category = p_category)
          AND NOT e.quarantined
        ORDER BY rank DESC
        LIMIT p_limit;
    $func$;

    -- Vector search. Caller passes a 768-dim embedding (computed
    -- elsewhere in step 3; in step 6 a sibling helper will accept
    -- raw text and route through Ollama via the work queue).
    CREATE FUNCTION stewards.brain_search_vec(
        p_embedding vector(768),
        p_category  text DEFAULT NULL,
        p_limit     int DEFAULT 20
    ) RETURNS TABLE (
        id       text,
        title    text,
        category text,
        distance real
    )
    LANGUAGE sql STABLE AS $func$
        SELECT e.id, e.title, e.category,
               (e.embedding <=> p_embedding)::real AS distance
        FROM stewards.brain_entries e
        WHERE e.embedding IS NOT NULL
          AND (p_category IS NULL OR e.category = p_category)
          AND NOT e.quarantined
        ORDER BY e.embedding <=> p_embedding
        LIMIT p_limit;
    $func$;
    "#,
    name = "create_brain_schema",
    requires = ["create_work_queue"],
);

// ---------------------------------------------------------------------------
// Phase 1.6: Tool wrappers (one-arg jsonb in, jsonb out).
// Convention: every sql_fn tool MUST have signature
//   fn(p_args jsonb) RETURNS jsonb
// so the Rust dispatcher is one line: SELECT <fn>($1). Underlying
// SQL fns can have arbitrary signatures; the wrapper unpacks args.
// ---------------------------------------------------------------------------

extension_sql!(
    r#"
    CREATE FUNCTION stewards.brain_search_text_tool(p_args jsonb)
    RETURNS jsonb
    LANGUAGE sql STABLE AS $func$
        SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
        FROM stewards.brain_search_text(
            p_args->>'query',
            p_args->>'category',
            coalesce((p_args->>'limit')::int, 20)
        ) t;
    $func$;

    -- load_skill_tool: returns the body of the named skill (variant-
    -- resolved against caller model is not done here; we just pick
    -- the longest matching pattern across active rows). The LLM sees
    -- the skill body as the tool reply and folds it into context.
    CREATE FUNCTION stewards.load_skill_tool(p_args jsonb)
    RETURNS jsonb
    LANGUAGE sql STABLE AS $func$
        SELECT coalesce(
            (SELECT to_jsonb(s.body)
               FROM stewards.skills s
              WHERE s.family = p_args->>'name' AND s.active
              ORDER BY length(model_match) DESC, model_match
              LIMIT 1),
            to_jsonb(format('skill not found: %s', p_args->>'name'))
        );
    $func$;
    "#,
    name = "create_tool_wrappers",
    requires = ["create_brain_schema"],
);

// ---------------------------------------------------------------------------
// Phase 1.5: Harness sketch — agents, skills, instructions, tool_defs.
//
// Goal: prove the prompt-assembly + tools[] round-trip BEFORE step 7
// makes a real chat call. `dry_run_chat(family, model, session, input)`
// returns the exact JSON body that would go to /v1/chat/completions
// so we can read it and judge the shape before sending bytes.
//
// Variant-by-glob design: agents/skills/instructions can have multiple
// rows for the same logical "family", differentiated by `model_match`
// (a glob like 'kimi-*'). The catch-all default uses '*', which
// glob-matches everything; resolution picks the LONGEST matching
// pattern, so '*' (length 1) is always the last-resort fallback and
// any specific glob wins over it. Using '*' instead of NULL keeps the
// PK clean and ON CONFLICT honest (PG treats NULL keys as distinct).
// This lets us tune prompts per-model without duplicating workflow
// rules. See `glob_match` and `resolve_*` below.
//
// Tools deliberately do NOT have variants in v1 — a tool's description
// is structural ("what does this do"), not stylistic ("how do I phrase
// this for Qwen"). Stylistic per-model guidance lives in instructions.
// ---------------------------------------------------------------------------

extension_sql!(
    r#"
    -- ============================================================
    -- glob matcher — used by all resolve_* and *_permission helpers.
    --
    -- Converts a shell-style glob ('kimi-*', 'brain_*') to a
    -- Postgres LIKE pattern. We escape `\`, `%`, `_` first so
    -- they match literally, then turn `*` into `%`. `?` (single-char)
    -- is intentionally NOT supported — model names don't need it
    -- and supporting it would require escaping `_` differently.
    -- ============================================================

    CREATE FUNCTION stewards.glob_match(p_pattern text, p_value text)
    RETURNS bool
    LANGUAGE sql IMMUTABLE AS $func$
        SELECT p_value LIKE
            replace(
                replace(
                    replace(
                        replace(p_pattern, '\', '\\'),
                        '%', '\%'),
                    '_', '\_'),
                '*', '%')
    $func$;

    -- ============================================================
    -- Agents — one row per (family, model_match). NULL model_match
    -- is the catch-all default; non-NULL globs win when they match.
    -- ============================================================

    CREATE TABLE stewards.agents (
        family       text NOT NULL,
        model_match  text NOT NULL DEFAULT '*',    -- glob; '*' = default
        description  text NOT NULL,
        mode         text NOT NULL DEFAULT 'primary'
                     CHECK (mode IN ('primary','subagent','all')),
        model_pin    text,                         -- override session model
        prompt       text NOT NULL,                -- agent persona/role
        temperature  real,
        top_p        real,
        response_format jsonb,                       -- e.g. {"type": "json_object"}
        steps        int NOT NULL DEFAULT 8,        -- max agentic iterations
        active       bool NOT NULL DEFAULT true,
        created_at   timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (family, model_match)
    );

    -- ============================================================
    -- Skills — same variant pattern as agents.
    -- ============================================================

    CREATE TABLE stewards.skills (
        family       text NOT NULL
                     CHECK (family ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
        model_match  text NOT NULL DEFAULT '*',
        description  text NOT NULL
                     CHECK (length(description) BETWEEN 1 AND 1024),
        body         text NOT NULL,
        license      text,
        metadata     jsonb NOT NULL DEFAULT '{}',
        active       bool NOT NULL DEFAULT true,
        created_at   timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (family, model_match)
    );

    -- ============================================================
    -- Instructions — flat-merged into the system prompt.
    -- scope = 'global' | 'agent:<family>' | 'session:<id>'
    -- ord = sort order within scope (lower first)
    -- ============================================================

    CREATE TABLE stewards.instructions (
        id            bigserial PRIMARY KEY,
        family        text NOT NULL,                  -- logical name for variant grouping
        model_match   text NOT NULL DEFAULT '*',
        scope         text NOT NULL,
        body          text NOT NULL,
        ord           int  NOT NULL DEFAULT 100,
        active        bool NOT NULL DEFAULT true,
        source_label  text,                            -- e.g. 'project:AGENTS.md'
        created_at    timestamptz NOT NULL DEFAULT now(),
        UNIQUE (family, model_match, scope)
    );
    CREATE INDEX instructions_scope_idx ON stewards.instructions (scope, ord);

    -- ============================================================
    -- Tool defs — what tools an agent can see. No variants in v1.
    -- name follows '<prefix>_<rest>' convention (brain_*, doc_*).
    -- execute_target is jsonb describing dispatch. v1 supports:
    --   {"kind":"sql_fn","schema":"stewards","name":"brain_search_text"}
    -- Future kinds: 'http', 'subagent', 'mcp'.
    -- ============================================================

    CREATE TABLE stewards.tool_defs (
        name            text PRIMARY KEY
                        CHECK (name ~ '^[a-z][a-z0-9_]*$'),
        description     text NOT NULL,
        args_schema     jsonb NOT NULL,        -- JSON Schema for params
        execute_target  jsonb NOT NULL,
        active          bool NOT NULL DEFAULT true,
        created_at      timestamptz NOT NULL DEFAULT now(),
        -- Budget hooks (3c.2.5, born here at consolidation): typical
        -- token weight of a result / one invocation. NULL = unknown.
        -- Populate from observation data, not guesses.
        expected_result_tokens     int,
        expected_invocation_tokens int
    );

    -- ============================================================
    -- Per-agent permissions for tools and skills.
    -- Glob-matched against tool name / skill family.
    -- Last (longest) matching pattern wins. Default: 'allow' if
    -- no rule exists (mirrors opencode's default-allow behavior).
    -- ============================================================

    CREATE TABLE stewards.agent_tool_perms (
        agent_family  text NOT NULL,
        tool_pattern  text NOT NULL,
        action        text NOT NULL CHECK (action IN ('allow','ask','deny')),
        -- Provenance (3c.3.3, born here at consolidation): the importer
        -- deletes/rebuilds only source='frontmatter' rows on agent
        -- re-import; broadcast (substrate-internal SQL grants) and
        -- manual (one-off psql) rows survive.
        source        text NOT NULL DEFAULT 'frontmatter'
                      CHECK (source IN ('frontmatter','broadcast','manual')),
        PRIMARY KEY (agent_family, tool_pattern)
    );

    CREATE TABLE stewards.agent_skill_perms (
        agent_family  text NOT NULL,
        skill_pattern text NOT NULL,
        action        text NOT NULL CHECK (action IN ('allow','ask','deny')),
        PRIMARY KEY (agent_family, skill_pattern)
    );

    -- ============================================================
    -- Tool calls — one row per tool invocation by an agent. Empty
    -- in v1 (no agent loop yet); the table exists so step 7+ can
    -- write to it without a migration.
    -- ============================================================

    CREATE TABLE stewards.tool_calls (
        id            bigserial PRIMARY KEY,
        message_id    bigint REFERENCES stewards.messages(id) ON DELETE CASCADE,
        tool          text NOT NULL,
        args          jsonb NOT NULL,
        result        jsonb,
        status        text NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending','running','done','error')),
        error         text,
        started_at    timestamptz,
        ended_at      timestamptz
    );
    CREATE INDEX tool_calls_message_idx ON stewards.tool_calls (message_id);

    -- ============================================================
    -- Resolution — pick the most-specific row matching this model.
    -- Longest non-NULL pattern wins; NULL is the catch-all fallback.
    -- ============================================================

    CREATE FUNCTION stewards.resolve_agent(p_family text, p_model text)
    RETURNS stewards.agents
    LANGUAGE sql STABLE AS $func$
        SELECT *
        FROM stewards.agents
        WHERE family = p_family
          AND active
          AND stewards.glob_match(model_match, p_model)
        ORDER BY length(model_match) DESC, model_match
        LIMIT 1
    $func$;

    CREATE FUNCTION stewards.resolve_skill(p_family text, p_model text)
    RETURNS stewards.skills
    LANGUAGE sql STABLE AS $func$
        SELECT *
        FROM stewards.skills
        WHERE family = p_family
          AND active
          AND stewards.glob_match(model_match, p_model)
        ORDER BY length(model_match) DESC, model_match
        LIMIT 1
    $func$;

    -- Permission lookup — returns 'allow'|'ask'|'deny'. Default 'allow'.
    CREATE FUNCTION stewards.tool_permission(p_agent text, p_tool text)
    RETURNS text
    LANGUAGE sql STABLE AS $func$
        SELECT coalesce(
            (SELECT action FROM stewards.agent_tool_perms
             WHERE agent_family = p_agent
               AND stewards.glob_match(tool_pattern, p_tool)
             ORDER BY length(tool_pattern) DESC LIMIT 1),
            'allow')
    $func$;

    CREATE FUNCTION stewards.skill_permission(p_agent text, p_skill text)
    RETURNS text
    LANGUAGE sql STABLE AS $func$
        SELECT coalesce(
            (SELECT action FROM stewards.agent_skill_perms
             WHERE agent_family = p_agent
               AND stewards.glob_match(skill_pattern, p_skill)
             ORDER BY length(skill_pattern) DESC LIMIT 1),
            'allow')
    $func$;

    -- ============================================================
    -- Composition — these are the functions step 7 will reuse.
    -- All STABLE / read-only. dry_run_chat is the verification target.
    -- ============================================================

    -- compose_system_prompt: agent.prompt + matching instructions
    -- + (if 'skill' tool permitted) <available_skills> XML block.
    CREATE FUNCTION stewards.compose_system_prompt(
        p_agent_family text, p_model text, p_session_id text
    ) RETURNS text
    LANGUAGE plpgsql STABLE AS $func$
    DECLARE
        v_agent stewards.agents;
        v_prompt text := '';
        v_instructions text;
        v_skills_block text;
    BEGIN
        v_agent := stewards.resolve_agent(p_agent_family, p_model);
        IF v_agent.family IS NULL THEN
            RAISE EXCEPTION
                'no agent variant resolved: family=% model=%',
                p_agent_family, p_model;
        END IF;
        v_prompt := v_agent.prompt;

        -- Append global + agent-scoped instructions (one row per
        -- family, picking the best model match per family).
        SELECT string_agg(body, E'\n\n' ORDER BY ord, family)
        INTO v_instructions
        FROM (
            SELECT DISTINCT ON (family)
                family, body, ord
            FROM stewards.instructions
            WHERE active
              AND scope IN ('global', 'agent:' || p_agent_family)
              AND stewards.glob_match(model_match, p_model)
            ORDER BY family, length(model_match) DESC, model_match
        ) t;
        IF v_instructions IS NOT NULL THEN
            v_prompt := v_prompt || E'\n\n' || v_instructions;
        END IF;

        -- Append <available_skills> if 'skill' tool isn't denied.
        -- Per opencode pattern: skills are advertised here, loaded
        -- on-demand by the agent calling skill({name: 'foo'}).
        IF stewards.tool_permission(p_agent_family, 'skill') <> 'deny' THEN
            SELECT E'\n\n<available_skills>\n' || string_agg(
                '  <skill>' || E'\n'
                || '    <name>' || family || '</name>' || E'\n'
                || '    <description>' || description || '</description>' || E'\n'
                || '  </skill>',
                E'\n'
                ORDER BY family
            ) || E'\n</available_skills>'
            INTO v_skills_block
            FROM (
                SELECT DISTINCT ON (family) family, description
                FROM stewards.skills
                WHERE active
                  AND stewards.glob_match(model_match, p_model)
                  AND stewards.skill_permission(p_agent_family, family) <> 'deny'
                ORDER BY family, length(model_match) DESC, model_match
            ) s;
            IF v_skills_block IS NOT NULL THEN
                v_prompt := v_prompt || v_skills_block;
            END IF;
        END IF;

        RETURN v_prompt;
    END;
    $func$;

    -- compose_messages: [system, ...history, ?user]
    --
    -- Each history row is emitted with the FULL OpenAI message shape
    -- so multi-turn tool flows are valid. Concretely:
    --   - role='user'/'system': {role, content}
    --   - role='assistant' WITHOUT tool_calls: {role, content}
    --   - role='assistant' WITH tool_calls: {role, content, tool_calls}
    --     (content may be empty string when only tool_calls were
    --     emitted; OpenAI requires the field to exist)
    --   - role='tool': {role, tool_call_id, content}
    --     (NO content field omission — must be present and string)
    --
    -- Stripping any of these would cause the provider to 400 with
    -- "messages with role 'tool' must follow an assistant message
    -- with tool_calls" or similar shape errors. Do not simplify.
    CREATE FUNCTION stewards.compose_messages(
        p_agent_family text,
        p_model text,
        p_session_id text,
        p_user_input text DEFAULT NULL
    ) RETURNS jsonb
    LANGUAGE plpgsql STABLE AS $func$
    DECLARE
        v_system  text;
        v_history jsonb;
        v_result  jsonb;
    BEGIN
        v_system := stewards.compose_system_prompt(p_agent_family, p_model, p_session_id);

        SELECT coalesce(jsonb_agg(
            CASE m.role
                WHEN 'tool' THEN jsonb_build_object(
                    'role', 'tool',
                    'tool_call_id', coalesce(m.tool_call_id, ''),
                    'content', m.content
                )
                WHEN 'assistant' THEN
                    -- Build the assistant message field-by-field. We
                    -- ALWAYS include role+content. tool_calls and the
                    -- reasoning fields are added only when present so
                    -- non-tool, non-thinking turns stay minimal.
                    --
                    -- Why both reasoning_content AND reasoning_details:
                    -- Moonshot's request-side validation reads
                    -- `reasoning_content` (string). OpenRouter's pass-
                    -- through reads `reasoning_details` (structured).
                    -- Sending both lets the next request work whether
                    -- the gateway normalizes or not.
                    jsonb_build_object('role', 'assistant', 'content', m.content)
                    || (CASE WHEN m.tool_calls IS NOT NULL
                             THEN jsonb_build_object('tool_calls', m.tool_calls)
                             ELSE '{}'::jsonb END)
                    || (CASE WHEN m.reasoning_content IS NOT NULL
                             THEN jsonb_build_object('reasoning_content', m.reasoning_content)
                             ELSE '{}'::jsonb END)
                    || (CASE WHEN m.reasoning_details IS NOT NULL
                             THEN jsonb_build_object('reasoning_details', m.reasoning_details)
                             ELSE '{}'::jsonb END)
                ELSE
                    jsonb_build_object('role', m.role, 'content', m.content)
            END
            ORDER BY m.created_at, m.id
        ), '[]'::jsonb)
        INTO v_history
        FROM stewards.messages m
        WHERE m.session_id = p_session_id;

        v_result := jsonb_build_array(
            jsonb_build_object('role', 'system', 'content', v_system)
        ) || v_history;

        IF p_user_input IS NOT NULL THEN
            v_result := v_result || jsonb_build_array(
                jsonb_build_object('role', 'user', 'content', p_user_input)
            );
        END IF;

        RETURN v_result;
    END;
    $func$;

    -- compose_tools: OpenAI-shape tools[] array, filtered by perms.
    -- 'ask' tools are included (the loop will handle prompting); only
    -- 'deny' is excluded.
    CREATE FUNCTION stewards.compose_tools(p_agent_family text)
    RETURNS jsonb
    LANGUAGE sql STABLE AS $func$
        SELECT coalesce(jsonb_agg(
            jsonb_build_object(
                'type', 'function',
                'function', jsonb_build_object(
                    'name', t.name,
                    'description', t.description,
                    'parameters', t.args_schema
                )
            )
            ORDER BY t.name
        ), '[]'::jsonb)
        FROM stewards.tool_defs t
        WHERE t.active
          AND stewards.tool_permission(p_agent_family, t.name) <> 'deny'
    $func$;

    -- dry_run_chat: returns the EXACT POST body /v1/chat/completions
    -- would receive — but does NOT send. The verification target.
    CREATE FUNCTION stewards.dry_run_chat(
        p_agent_family text,
        p_model text,
        p_session_id text,
        p_user_input text DEFAULT NULL
    ) RETURNS jsonb
    LANGUAGE plpgsql STABLE AS $func$
    DECLARE
        v_agent stewards.agents;
        v_body  jsonb;
    BEGIN
        v_agent := stewards.resolve_agent(p_agent_family, p_model);
        IF v_agent.family IS NULL THEN
            RAISE EXCEPTION
                'no agent variant resolved: family=% model=%',
                p_agent_family, p_model;
        END IF;

        v_body := jsonb_build_object(
            'model', coalesce(v_agent.model_pin, p_model),
            'messages', stewards.compose_messages(
                p_agent_family, p_model, p_session_id, p_user_input),
            'tools', stewards.compose_tools(p_agent_family)
        );
        IF v_agent.temperature IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('temperature', v_agent.temperature);
        END IF;
        IF v_agent.top_p IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('top_p', v_agent.top_p);
        IF v_agent.response_format IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('response_format', v_agent.response_format);
        END IF;
        END IF;

        RETURN v_body || jsonb_build_object(
            '_meta', jsonb_build_object(
                'agent_family', p_agent_family,
                'agent_variant_match', v_agent.model_match,
                'requested_model', p_model,
                'pinned_model', v_agent.model_pin,
                'session_id', p_session_id
            )
        );
    END;
    $func$;
    "#,
    name = "create_harness_schema",
    requires = ["create_brain_schema"],
);

// ---------------------------------------------------------------------------
// Phase 1.5 seed data — minimum to exercise dry_run_chat against
// real-shaped data. Idempotent; safe to re-run.
// ---------------------------------------------------------------------------

extension_sql!(
    r#"
    -- One agent family with a default + a kimi-specific variant
    -- so the resolver actually has to pick. Both share workflow
    -- rules (which live in instructions); only the persona differs.
    INSERT INTO stewards.agents
        (family, model_match, description, mode, prompt, temperature, top_p, steps)
    VALUES
        (
            'stewards-explore', '*',
            'Read-only researcher over the brain and document corpus',
            'primary',
            E'You are a careful researcher with access to a Postgres-backed brain of notes and a document corpus.\n\nYour job: when asked a question, search before answering. Cite the brain entry IDs (or source references) you actually consulted. If the brain has no entry on a topic, say so plainly — do not invent IDs.',
            0.2, NULL, 8
        ),
        (
            'stewards-explore', 'kimi-*',
            'Read-only researcher (Kimi tuning)',
            'primary',
            E'You are a careful researcher with access to a Postgres-backed brain of notes and a document corpus.\n\nYour job: when asked a question, search before answering. Cite the brain entry IDs (or source references) you actually consulted. If the brain has no entry on a topic, say so plainly — do not invent IDs.\n\nKimi-specific: be terse. Prefer 2-3 sentences over paragraphs. Skip throat-clearing.',
            0.2, NULL, 8
        )
    ON CONFLICT (family, model_match) DO NOTHING;

    -- Workflow rules shared across model variants.
    INSERT INTO stewards.instructions
        (family, model_match, scope, body, ord, source_label)
    VALUES
        (
            'honesty', '*', 'global',
            E'## Honesty\n- Read before quoting. Do not paraphrase from memory.\n- If a search returns no results, report that. Do not fabricate.',
            10, 'seed:phase-1.5'
        ),
        (
            'search-budget', '*', 'agent:stewards-explore',
            E'## Search budget\n- Run at most 3 searches before responding. If still uncertain after 3, say what you searched and ask the user to narrow the question.',
            20, 'seed:phase-1.5'
        )
    ON CONFLICT (family, model_match, scope) DO NOTHING;

    -- Two skills lifted in spirit from .github/skills/. Real bodies
    -- would be longer; these prove the shape, not the corpus.
    INSERT INTO stewards.skills
        (family, model_match, description, body, license, metadata)
    VALUES
        (
            'source-verification', '*',
            'Verify quotes against actual source files before quoting',
            E'# Source Verification\n\nBefore using quotation marks around any quoted text, you must have read the actual source row in this session. Training-data memory confabulates.\n\nIf you have not verified, paraphrase using indirect speech ("the source argues that...") rather than direct quotation.',
            'MIT', '{"audience":"researcher"}'::jsonb
        ),
        (
            'reference-linking', '*',
            'Format source references as links to their canonical location',
            E'# Reference Linking\n\nCite a source by a stable short form and link it to its canonical location; accompany it with the brain entry ID if one exists.',
            'MIT', '{"audience":"researcher"}'::jsonb
        )
    ON CONFLICT (family, model_match) DO NOTHING;

    -- Tool defs the agent will actually see. Two for v1: a real
    -- search tool and the special skill-loader. brain_search_vec
    -- is intentionally omitted because the agent can't construct
    -- a vector input directly; a future brain_search_semantic
    -- (text-in, embed-via-worker, vec-search) will replace it.
    INSERT INTO stewards.tool_defs
        (name, description, args_schema, execute_target)
    VALUES
        (
            'brain_search_text',
            'Full-text search over brain entries (notes, ideas, study fragments). Returns ranked matches with id, title, category, and rank score.',
            $j${
                "type": "object",
                "properties": {
                    "query":    {"type": "string", "description": "Search terms (plain language)."},
                    "category": {"type": "string", "description": "Optional category filter.",
                                 "enum": ["inbox","study","journal","action","idea","person","project"]},
                    "limit":    {"type": "integer", "description": "Max results (default 20).", "minimum": 1, "maximum": 100}
                },
                "required": ["query"]
            }$j$::jsonb,
            $j${"kind":"sql_fn","schema":"stewards","name":"brain_search_text_tool"}$j$::jsonb
        ),
        (
            'skill',
            'Load the body of a named skill from the <available_skills> list and return its content into the conversation. Use when a skill''s description matches the task at hand.',
            $j${
                "type": "object",
                "properties": {
                    "name": {"type": "string", "description": "The skill family name (e.g., source-verification)."}
                },
                "required": ["name"]
            }$j$::jsonb,
            $j${"kind":"sql_fn","schema":"stewards","name":"load_skill_tool"}$j$::jsonb
        )
    ON CONFLICT (name) DO NOTHING;

    -- Permissions for stewards-explore: deny anything not brain_*
    -- or skill, allow those explicitly. Demonstrates the glob model.
    INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action)
    VALUES
        ('stewards-explore', '*',          'deny'),
        ('stewards-explore', 'brain_*',    'allow'),
        ('stewards-explore', 'skill',      'allow')
    ON CONFLICT (agent_family, tool_pattern) DO NOTHING;

    INSERT INTO stewards.agent_skill_perms (agent_family, skill_pattern, action)
    VALUES
        ('stewards-explore', '*', 'allow')
    ON CONFLICT (agent_family, skill_pattern) DO NOTHING;
    "#,
    name = "seed_harness",
    requires = ["create_harness_schema"],
);

// ---------------------------------------------------------------------------
// Step 7 / Phase 1.6: chat round-trip helpers + agent loop enqueuers.
//
// Architecture (Option B — work-item-per-iteration):
//   chat_enqueue      → chat_post_internal → enqueues kind='chat'
//   bgworker chat()   → POSTs, writes assistant message
//   if assistant.tool_calls present AND iteration<steps:
//     phase 3 enqueues kind='tool_dispatch' (carries parent_work_id)
//   bgworker tool_dispatch() → runs each tool, returns ToolsDispatched
//     phase 3 inserts N role='tool' messages, then enqueues kind='chat'
//     (no user input — the messages history already has the new tool
//     replies, compose_messages picks them up automatically)
//   loop terminates when finish_reason='stop'/'length'/'content_filter'
//   OR iteration count >= agent.steps.
//
// Stable-prefix discipline for prompt caching:
//   Every body produced by compose_messages within a session has the
//   same [system, ...prior_history] prefix. Only NEW messages append.
//   This is exactly what OpenAI/Moonshot automatic prompt caching
//   wants. Do not insert anything that varies between system and
//   history (e.g., timestamps, request IDs, freshly-rolled UUIDs).
// ---------------------------------------------------------------------------

extension_sql!(
    r#"
    -- chat_post_internal: compose body from CURRENT session state
    -- (no user input append) and enqueue a chat work item. Used by
    -- chat_enqueue for the first turn AND by tool_dispatch's phase 3
    -- to continue the loop after appending tool replies.
    --
    -- Continuation chats inherit any payload keys starting with `_`
    -- from the most recent chat work_queue row in the same session
    -- (the 3c.3.1 fix, born here at consolidation). Without this,
    -- continuation chats lose markers like _watchman_pass_id /
    -- _work_item_id, so the harvest triggers only see the FIRST chat
    -- per stage and miss the actual final chat. Generic: works for
    -- any marker scheme as long as marker keys start with underscore.
    CREATE FUNCTION stewards.chat_post_internal(
        p_agent_family text,
        p_model        text,
        p_session_id   text,
        p_provider     text
    ) RETURNS bigint
    LANGUAGE plpgsql AS $func$
    DECLARE
        v_body              jsonb;
        v_payload           jsonb;
        v_work_id           bigint;
        v_inherited_markers jsonb;
    BEGIN
        -- compose with NULL user_input — history already contains
        -- everything we need (the user message was inserted by the
        -- caller of chat_enqueue, or the tool replies were inserted
        -- by tool_dispatch's phase 3).
        v_body := stewards.dry_run_chat(
            p_agent_family, p_model, p_session_id, NULL);

        SELECT jsonb_object_agg(je.key, je.value)
          INTO v_inherited_markers
          FROM stewards.work_queue wq
          CROSS JOIN LATERAL jsonb_each(wq.payload) je
         WHERE wq.payload->>'session_id' = p_session_id
           AND wq.kind = 'chat'
           AND wq.id = (
               SELECT max(id) FROM stewards.work_queue
                WHERE payload->>'session_id' = p_session_id
                  AND kind = 'chat'
           )
           AND je.key LIKE '\_%' ESCAPE '\';

        v_payload := jsonb_build_object(
            'session_id',      p_session_id,
            'agent_family',    p_agent_family,
            'requested_model', p_model,
            'meta',            v_body->'_meta',
            -- Inject `user = <session_id>` so OpenCode (and other
            -- providers that surface per-session billing) can attribute
            -- cost AND so prompt caching keys on a stable user id.
            'body',            (v_body - '_meta')
                               || jsonb_build_object('user', p_session_id)
        ) || coalesce(v_inherited_markers, '{}'::jsonb);

        INSERT INTO stewards.work_queue (kind, provider, payload)
        VALUES ('chat', p_provider, v_payload)
        RETURNING id INTO v_work_id;

        RETURN v_work_id;
    END;
    $func$;

    -- chat_enqueue: persist user turn + delegate to chat_post_internal.
    -- Caller-facing entry point for starting or continuing a chat
    -- with a new user message. Returns the chat work_queue id.
    CREATE FUNCTION stewards.chat_enqueue(
        p_agent_family text,
        p_model        text,
        p_session_id   text,
        p_user_input   text,
        p_provider     text
    ) RETURNS bigint
    LANGUAGE plpgsql AS $func$
    BEGIN
        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (p_session_id, 'user', p_user_input, p_model);

        RETURN stewards.chat_post_internal(
            p_agent_family, p_model, p_session_id, p_provider);
    END;
    $func$;

    -- tool_dispatch_enqueue: called from the bgworker (via SPI) when
    -- a chat response carried tool_calls AND iteration < agent.steps.
    -- Builds the tool_dispatch payload and inserts the work row.
    -- The actual tool execution happens in the bgworker dispatch arm.
    CREATE FUNCTION stewards.tool_dispatch_enqueue(
        p_parent_work_id bigint,
        p_agent_family   text,
        p_model          text,
        p_session_id     text,
        p_provider       text
    ) RETURNS bigint
    LANGUAGE sql AS $func$
        INSERT INTO stewards.work_queue (kind, provider, payload)
        VALUES (
            'tool_dispatch',
            p_provider,
            jsonb_build_object(
                'parent_work_id', p_parent_work_id,
                'agent_family',   p_agent_family,
                'model',          p_model,
                'session_id',     p_session_id
            )
        )
        RETURNING id;
    $func$;

    -- iteration_count: number of assistant messages in this session
    -- since the last user message. Used by the chat handler's phase 3
    -- to compare against agent.steps and decide whether to continue
    -- the loop or stop.
    CREATE FUNCTION stewards.iteration_count(p_session_id text)
    RETURNS int
    LANGUAGE sql STABLE AS $func$
        SELECT count(*)::int FROM stewards.messages
        WHERE session_id = p_session_id
          AND role = 'assistant'
          AND created_at > coalesce(
            (SELECT max(created_at) FROM stewards.messages
             WHERE session_id = p_session_id AND role = 'user'),
            'epoch'::timestamptz
          );
    $func$;

    -- synthesize_tool_failure: when a tool_dispatch row fails BEFORE
    -- the per-tool dispatcher could write its own role='tool' replies
    -- (mode 3 = dispatcher itself errors; mode 4 = bgworker crashed
    -- mid-dispatch and the reaper is cleaning up), this builds the
    -- missing tool replies AND enqueues the continuation chat so the
    -- loop never stalls.
    --
    -- For each tool_call in the parent assistant message that does
    -- NOT already have a matching role='tool' reply in the session
    -- history, insert a synthetic reply with the error message. Then
    -- call chat_post_internal to enqueue the continuation. The model
    -- sees the failure, decides whether to retry-with-different-args
    -- or give up gracefully.
    --
    -- Idempotent: if all tool_calls already have replies (e.g. half
    -- the dispatch succeeded before crash), only the missing ones get
    -- synthesized. If the parent has no tool_calls (caller invoked
    -- this for the wrong row), it's a no-op and returns NULL.
    CREATE FUNCTION stewards.synthesize_tool_failure(
        p_parent_work_id bigint,
        p_agent_family   text,
        p_model          text,
        p_session_id     text,
        p_provider       text,
        p_error          text
    ) RETURNS bigint
    LANGUAGE plpgsql AS $func$
    DECLARE
        v_parent_assistant_id bigint;
        v_tool_calls          jsonb;
        v_tc                  jsonb;
        v_tc_id               text;
        v_synthetic_count     int := 0;
        v_continuation_id     bigint;
    BEGIN
        -- Find the parent assistant message (the one that requested
        -- the tools).
        SELECT id, tool_calls
        INTO v_parent_assistant_id, v_tool_calls
        FROM stewards.messages
        WHERE parent_work_id = p_parent_work_id
          AND role = 'assistant'
        ORDER BY id DESC
        LIMIT 1;

        IF v_parent_assistant_id IS NULL OR v_tool_calls IS NULL
           OR jsonb_array_length(v_tool_calls) = 0 THEN
            RETURN NULL;
        END IF;

        -- For each tool_call, insert a synthetic reply UNLESS one
        -- already exists for that tool_call_id in this session.
        FOR v_tc IN SELECT * FROM jsonb_array_elements(v_tool_calls)
        LOOP
            v_tc_id := v_tc->>'id';
            IF v_tc_id IS NULL THEN CONTINUE; END IF;

            IF NOT EXISTS (
                SELECT 1 FROM stewards.messages
                WHERE session_id = p_session_id
                  AND role = 'tool'
                  AND tool_call_id = v_tc_id
            ) THEN
                INSERT INTO stewards.messages
                    (session_id, role, content,
                     tool_call_id, parent_work_id)
                VALUES (
                    p_session_id, 'tool',
                    jsonb_build_object(
                        'error', p_error,
                        '_synthetic', true,
                        '_reason', 'dispatcher failure; no tool execution occurred'
                    )::text,
                    v_tc_id,
                    p_parent_work_id
                );
                v_synthetic_count := v_synthetic_count + 1;
            END IF;
        END LOOP;

        -- Always enqueue continuation, even if all replies already
        -- existed (caller may be retrying after a previous reaper
        -- run wrote replies but didn't enqueue continuation).
        v_continuation_id := stewards.chat_post_internal(
            p_agent_family, p_model, p_session_id, p_provider);

        RAISE NOTICE 'synthesize_tool_failure: parent=% synthetic=% continuation=%',
            p_parent_work_id, v_synthetic_count, v_continuation_id;
        RETURN v_continuation_id;
    END;
    $func$;

    -- session_status: collapse a session's state into one row.
    -- Useful for any UI/API answering "did this loop finish or stall?".
    -- Joins the latest assistant message's finish_reason with the
    -- latest chat work_queue row's loop_stop_reason and any errored
    -- work_queue rows in the session's parent_work_id chain.
    CREATE VIEW stewards.session_status AS
    SELECT
        s.id AS session_id,
        s.kind,
        s.label,
        -- Latest assistant message in the session
        (SELECT m.finish_reason FROM stewards.messages m
         WHERE m.session_id = s.id AND m.role = 'assistant'
         ORDER BY m.id DESC LIMIT 1) AS last_finish_reason,
        (SELECT m.created_at FROM stewards.messages m
         WHERE m.session_id = s.id AND m.role = 'assistant'
         ORDER BY m.id DESC LIMIT 1) AS last_assistant_at,
        -- Latest chat work_queue row's loop_stop_reason (e.g.
        -- 'steps_exhausted' or 'truncated_tool_calls')
        (SELECT (w.result->>'loop_stop_reason') FROM stewards.work_queue w
         WHERE w.kind = 'chat'
           AND w.payload->>'session_id' = s.id
         ORDER BY w.id DESC LIMIT 1) AS last_loop_stop_reason,
        -- Anything pending or in_progress for this session?
        (SELECT count(*)::int FROM stewards.work_queue w
         WHERE w.payload->>'session_id' = s.id
           AND w.status IN ('pending', 'in_progress')) AS pending_work,
        -- Anything errored?
        (SELECT count(*)::int FROM stewards.work_queue w
         WHERE w.payload->>'session_id' = s.id
           AND w.status = 'error') AS errored_work,
        -- Token + cost rollup across all assistant turns
        (SELECT coalesce(sum(m.tokens_in), 0)::bigint
         FROM stewards.messages m
         WHERE m.session_id = s.id) AS total_tokens_in,
        (SELECT coalesce(sum(m.tokens_out + coalesce(m.reasoning_tokens, 0)), 0)::bigint
         FROM stewards.messages m
         WHERE m.session_id = s.id) AS total_billable_out,
        s.created_at
    FROM stewards.sessions s;

    -- NOTE: an earlier draft included a chat_round_trip() that
    -- enqueued + polled inside one SQL function. That's a footgun:
    -- the SQL function holds an open transaction for the whole loop,
    -- so the work_queue row it just inserted is invisible to the
    -- bgworker (MVCC), AND the still-open tx blocks other writers
    -- on row locks (e.g., the sessions row from the same call).
    -- Removed. Callers should `chat_enqueue()` then either LISTEN
    -- stewards_done or poll work_queue from a separate statement.
    "#,
    name = "create_chat_helpers",
    requires = ["seed_harness"],
);

// ---------------------------------------------------------------------------
// Docs corpus (authored 2026-06-12; consolidates the historical Phase 2.1
// "studies" block plus the 6a / h3-1 column migrations).
//
// Docs are first-class rows with embeddings (so similarity search works
// the same way it does for brain entries). Citations to canonical sources
// are typed CITES edges in the relational graph (01-graph.sql) — one
// 'doc' node per doc row, one node per unique URI cited.
//
// URI scheme: the cited source's link target (a relative path or an
// external URL), as written, is the canonical id. Examples:
//   docs/architecture.md           (a doc in the corpus)
//   docs/architecture.md#caching   (a section anchor)
//   https://example.com/spec       (an external source)
// ---------------------------------------------------------------------------
extension_sql!(
    r#"
    CREATE TABLE stewards.docs (
        id              text PRIMARY KEY DEFAULT gen_random_uuid()::text,
        slug            text NOT NULL UNIQUE,
        title           text NOT NULL,
        -- Nullable: docs promoted from completed work items may not
        -- have a file destination (absorbed from migration 6a).
        file_path       text,
        body            text NOT NULL DEFAULT '',
        frontmatter     jsonb NOT NULL DEFAULT '{}'::jsonb,

        -- Kind discriminator. Open taxonomy — known kinds include
        -- 'doc', 'study', 'proposal', 'phase-doc', 'journal'. A CHECK
        -- constraint is intentionally NOT added: the taxonomy belongs
        -- to the deployment, and a new kind should cost a row, not a
        -- migration.
        kind            text NOT NULL DEFAULT 'doc',

        -- Cross-domain metadata (absorbed from migration h3-1).
        tags                text[] NOT NULL DEFAULT '{}',
        source_type         text,
        project_association text,

        -- Embedding (populated async via the same embed work_queue
        -- path that brain_entries uses; trigger below).
        embedding       vector(768),
        embedded_at     timestamptz,
        embedded_model  text,
        embedding_error text,

        body_tsv        tsvector
                        GENERATED ALWAYS AS (
                            to_tsvector('english',
                                coalesce(title, '') || ' ' || coalesce(body, ''))
                        ) STORED,

        created_at      timestamptz NOT NULL DEFAULT now(),
        updated_at      timestamptz NOT NULL DEFAULT now()
    );

    CREATE INDEX docs_slug_idx       ON stewards.docs (slug);
    CREATE INDEX docs_kind_idx       ON stewards.docs (kind);
    CREATE INDEX docs_created_idx    ON stewards.docs (created_at DESC);
    CREATE INDEX docs_fts_idx        ON stewards.docs USING gin (body_tsv);
    CREATE INDEX docs_embedding_idx  ON stewards.docs
        USING hnsw (embedding vector_cosine_ops);
    CREATE INDEX docs_frontmatter_idx ON stewards.docs USING gin (frontmatter);
    CREATE INDEX docs_tags_gin        ON stewards.docs USING gin (tags);
    CREATE INDEX docs_source_type_idx ON stewards.docs (source_type);
    CREATE INDEX docs_project_association_idx
        ON stewards.docs (project_association);

    CREATE TABLE stewards.doc_versions (
        id          bigserial PRIMARY KEY,
        doc_id      text NOT NULL
                    REFERENCES stewards.docs(id) ON DELETE CASCADE,
        title       text NOT NULL,
        body        text NOT NULL,
        frontmatter jsonb NOT NULL DEFAULT '{}'::jsonb,
        changed_by  text NOT NULL DEFAULT 'system',
        changed_at  timestamptz NOT NULL DEFAULT now()
    );
    CREATE INDEX doc_versions_doc_idx
        ON stewards.doc_versions (doc_id, changed_at DESC);

    CREATE FUNCTION stewards.touch_doc() RETURNS trigger
    LANGUAGE plpgsql AS $func$
    BEGIN
        IF TG_OP = 'UPDATE' THEN
            IF NEW.title       IS DISTINCT FROM OLD.title
               OR NEW.body         IS DISTINCT FROM OLD.body
               OR NEW.frontmatter  IS DISTINCT FROM OLD.frontmatter
            THEN
                INSERT INTO stewards.doc_versions
                    (doc_id, title, body, frontmatter, changed_by)
                VALUES
                    (OLD.id, OLD.title, OLD.body, OLD.frontmatter,
                     coalesce(current_setting('stewards.actor', true), 'system'));
                NEW.updated_at := now();
            END IF;
        END IF;
        RETURN NEW;
    END;
    $func$;

    CREATE TRIGGER docs_touch
        BEFORE UPDATE ON stewards.docs
        FOR EACH ROW EXECUTE FUNCTION stewards.touch_doc();

    -- Embed-enqueue trigger. Reuses the existing 'embed' work_kind
    -- in the bgworker (which UPDATEs stewards.<target_table> by id).
    CREATE FUNCTION stewards.enqueue_doc_embed() RETURNS trigger
    LANGUAGE plpgsql AS $func$
    BEGIN
        IF TG_OP = 'INSERT'
           OR NEW.title IS DISTINCT FROM OLD.title
           OR NEW.body  IS DISTINCT FROM OLD.body
        THEN
            INSERT INTO stewards.work_queue (kind, provider, payload)
            VALUES (
                'embed',
                'lm_studio',
                jsonb_build_object(
                    'target_table', 'docs',
                    'target_id',    NEW.id,
                    'text',         coalesce(NEW.title, '') || E'\n\n' || coalesce(NEW.body, ''),
                    'model',        'nomic-embed-text-v1.5',
                    'dimensions',   768
                )
            );
        END IF;
        RETURN NEW;
    END;
    $func$;

    CREATE TRIGGER docs_enqueue_embed
        AFTER INSERT OR UPDATE OF title, body
        ON stewards.docs
        FOR EACH ROW EXECUTE FUNCTION stewards.enqueue_doc_embed();

    -- ============================================================
    -- Markdown link parser (generic, domain-agnostic).
    --
    -- parse_doc_links(body) returns one row per markdown link found in
    -- the body. For each match returns:
    --   uri         text  -- the link target, as written
    --   anchor_text text  -- the [text] portion
    --   kind        text  -- 'external' (http/https) | 'doc' (else)
    --
    -- Pure-fragment (#...), mailto:, and empty targets are skipped.
    -- Uses regexp_matches with the 'g' flag so all links are returned.
    -- import_doc consumes this to build the CITES edge graph. Operators
    -- who want domain-specific link classification (e.g. scripture /
    -- talk / manual) override this function in an overlay migration.
    -- ============================================================
    CREATE FUNCTION stewards.parse_doc_links(p_body text)
    RETURNS TABLE (uri text, anchor_text text, kind text)
    LANGUAGE plpgsql STABLE AS $func$
    DECLARE
        v_match text[];
        v_url   text;
    BEGIN
        FOR v_match IN
            SELECT regexp_matches(
                p_body,
                -- group 1: link text; group 2: link target
                E'\\[([^\\]]+)\\]\\(([^)]+)\\)',
                'g'
            )
        LOOP
            v_url := btrim(v_match[2]);
            -- Skip pure-fragment, mailto, and empty targets.
            CONTINUE WHEN v_url = '' OR left(v_url, 1) = '#'
                       OR v_url LIKE 'mailto:%';

            uri := v_url;
            anchor_text := v_match[1];
            kind := CASE
                WHEN v_url ~* '^https?://' THEN 'external'
                ELSE 'doc'
            END;
            RETURN NEXT;
        END LOOP;
    END;
    $func$;

    -- ============================================================
    -- import_doc: insert/upsert the row + sync the graph.
    --
    -- - INSERT or UPDATE stewards.docs on slug conflict.
    -- - Upsert the 'doc' node, then for each unique source link in
    --   the body, upsert the cited node + a CITES edge. The cited
    --   node's kind is the parsed link kind ('external' | 'doc');
    --   its ref is the link target URI.
    -- - Existing CITES edges from this doc are deleted first
    --   (sync semantics: edges always reflect the current body).
    --
    -- Edge weight carries the citation count so weighted walks can
    -- rank by citation density; props keep the exact numbers.
    --
    -- Returns the doc id.
    -- ============================================================
    CREATE FUNCTION stewards.import_doc(
        p_slug        text,
        p_file_path   text,
        p_title       text,
        p_body        text,
        p_frontmatter jsonb DEFAULT '{}'::jsonb,
        p_kind        text  DEFAULT 'doc'
    ) RETURNS text
    LANGUAGE plpgsql AS $func$
    DECLARE
        v_id      text;
        v_node    uuid;
        v_link    record;
    BEGIN
        INSERT INTO stewards.docs (slug, file_path, title, body, frontmatter, kind)
        VALUES (p_slug, p_file_path, p_title, p_body, p_frontmatter, p_kind)
        ON CONFLICT (slug) DO UPDATE
            SET title       = EXCLUDED.title,
                file_path   = EXCLUDED.file_path,
                body        = EXCLUDED.body,
                frontmatter = EXCLUDED.frontmatter,
                kind        = EXCLUDED.kind
        RETURNING id INTO v_id;

        v_node := stewards.graph_node_upsert(
            'doc', p_slug, p_title,
            jsonb_build_object('id', v_id,
                               'file_path', p_file_path,
                               'doc_kind',  p_kind));

        -- Drop existing CITES edges so re-imports stay in sync with body.
        DELETE FROM stewards.edges
         WHERE src = v_node AND kind = 'CITES';

        -- For each unique cited URI, upsert the cited node + CITES edge.
        FOR v_link IN
            SELECT uri,
                   max(anchor_text) AS anchor_text,
                   max(kind)        AS kind,
                   count(*)::int    AS citation_count
              FROM stewards.parse_doc_links(p_body)
             GROUP BY uri
        LOOP
            PERFORM stewards.graph_edge_upsert(
                'doc', p_slug,
                v_link.kind, v_link.uri,
                'CITES',
                v_link.citation_count::real,
                jsonb_build_object(
                    'anchor_text',    v_link.anchor_text,
                    'citation_count', v_link.citation_count,
                    'provenance',     'parsed',
                    'source',         'import_doc'));
        END LOOP;

        RETURN v_id;
    END;
    $func$;

    -- Convenience read function: one row per cited URI with the
    -- anchor text and citation count from the CITES edge props.
    CREATE FUNCTION stewards.doc_citations(p_slug text)
    RETURNS TABLE (
        doc_slug   text,
        cited_uri  text,
        cited_kind text,
        anchor_text text,
        citation_count int
    )
    LANGUAGE sql STABLE AS $func$
        SELECT s.ref,
               t.ref,
               t.kind,
               e.props->>'anchor_text',
               coalesce((e.props->>'citation_count')::int, 1)
          FROM stewards.edges e
          JOIN stewards.nodes s ON s.id = e.src
                               AND s.kind = 'doc' AND s.ref = p_slug
          JOIN stewards.nodes t ON t.id = e.dst
         WHERE e.kind = 'CITES'
         ORDER BY coalesce((e.props->>'citation_count')::int, 1) DESC,
                  t.ref ASC;
    $func$;
    "#,
    name = "create_docs",
    requires = ["create_chat_helpers"],
);

// ---------------------------------------------------------------------------
// External-resource resolver (generic, config-driven)
//
// A doc's CITES edges carry only an anchor_text and a URI. To show the
// actual content behind a citation, the operator configures an HTTP
// endpoint via STEWARDS_RESOLVER_URL (a "{ref}" template) and the bridge
// fetches it. Results cache in stewards.resolved_refs keyed by the
// reference string so repeated citations reuse one fetched row.
//
// The bgworker handles the HTTP round-trip via the 'resolve_ref' work
// kind (see tools.rs::resolve_ref). The core resolves whatever reference
// string it is handed — it has no notion of what a reference *means*.
// Domain-specific decomposition (e.g. a scripture verse range into one
// row per verse) is layered in an overlay migration that overrides
// refresh_doc_refs / doc_citations_resolved.
// ---------------------------------------------------------------------------
extension_sql!(
    r#"
    -- Cache table. Key is the reference string passed to the configured
    -- resolver endpoint — whatever the operator's service accepts (a doc
    -- URI, a wiki slug, a scripture verse, a SKU). content is the parsed
    -- JSON response; error records a negative/soft-failed lookup.
    CREATE TABLE stewards.resolved_refs (
        ref          text PRIMARY KEY,
        content      jsonb,
        error        text,
        fetched_at   timestamptz NOT NULL DEFAULT now(),
        attempt_count int NOT NULL DEFAULT 1
    );
    CREATE INDEX resolved_refs_fetched_idx
        ON stewards.resolved_refs (fetched_at DESC);
    CREATE INDEX resolved_refs_error_idx
        ON stewards.resolved_refs (ref) WHERE error IS NOT NULL;

    -- ============================================================
    -- enqueue_resolve(ref) — idempotent enqueue.
    --
    -- Skips if ref already has ANY cached row (success OR error).
    -- Errors are sticky: a 404 is usually a genuine gap in the
    -- configured source, and re-fetching every refresh wastes work.
    -- Callers who want to force a retry should DELETE the row first
    -- (or call stewards.invalidate_ref(ref) once that lands).
    --
    -- Also skips if the same ref is already pending/running, to
    -- prevent dup enqueues from concurrent callers.
    --
    -- Returns work_queue id, or NULL if no enqueue happened.
    -- ============================================================
    CREATE FUNCTION stewards.enqueue_resolve(p_ref text)
    RETURNS bigint
    LANGUAGE plpgsql AS $func$
    DECLARE
        v_id bigint;
    BEGIN
        IF EXISTS (
            SELECT 1 FROM stewards.resolved_refs WHERE ref = p_ref
        ) THEN
            RETURN NULL;
        END IF;
        IF EXISTS (
            SELECT 1 FROM stewards.work_queue
             WHERE kind = 'resolve_ref'
               AND status IN ('pending', 'running')
               AND payload->>'ref' = p_ref
        ) THEN
            RETURN NULL;
        END IF;

        INSERT INTO stewards.work_queue (kind, provider, payload)
        VALUES (
            'resolve_ref',
            'resolver',
            jsonb_build_object('ref', p_ref)
        )
        RETURNING id INTO v_id;
        RETURN v_id;
    END;
    $func$;

    -- Force a single ref to re-resolve next time refresh runs.
    -- Returns true if a row was deleted, false if it wasn't cached.
    CREATE FUNCTION stewards.invalidate_ref(p_ref text)
    RETURNS boolean
    LANGUAGE sql AS $func$
        WITH d AS (
            DELETE FROM stewards.resolved_refs
             WHERE ref = p_ref
             RETURNING 1
        )
        SELECT EXISTS (SELECT 1 FROM d);
    $func$;

    -- Refresh refs for every doc in the corpus. Returns total
    -- newly enqueued items. Use after a parser/normalizer change
    -- (followed by `DELETE FROM stewards.resolved_refs WHERE error
    -- IS NOT NULL` to retry the previously-missing refs).
    CREATE FUNCTION stewards.refresh_all_doc_refs()
    RETURNS int
    LANGUAGE sql AS $func$
        SELECT coalesce(sum(stewards.refresh_doc_refs(slug))::int, 0)
          FROM stewards.docs;
    $func$;

    -- ============================================================
    -- refresh_doc_refs(slug) — enqueue a resolve for every distinct
    -- URI the doc cites that isn't cached yet. Returns count of newly
    -- enqueued items. Generic: the cited URI itself is the reference
    -- string handed to the resolver. An overlay can override this to
    -- decompose anchor_text into finer references (e.g. verse ranges).
    --
    -- Idempotent — calling twice without intervening work just
    -- returns 0 the second time.
    -- ============================================================
    CREATE FUNCTION stewards.refresh_doc_refs(p_slug text)
    RETURNS int
    LANGUAGE plpgsql AS $func$
    DECLARE
        v_enqueued int := 0;
        v_link     record;
        v_id       bigint;
    BEGIN
        FOR v_link IN
            SELECT DISTINCT cited_uri
              FROM stewards.doc_citations(p_slug)
        LOOP
            v_id := stewards.enqueue_resolve(v_link.cited_uri);
            IF v_id IS NOT NULL THEN
                v_enqueued := v_enqueued + 1;
            END IF;
        END LOOP;
        RETURN v_enqueued;
    END;
    $func$;

    -- ============================================================
    -- doc_citations_resolved(slug) — each citation joined with the
    -- resolver's cached content for that cited URI. One row per CITES
    -- edge; `resolved` is the resolved_refs row ({ref, content, error})
    -- or an empty object when the URI hasn't been resolved yet.
    --
    -- Generic: the cited URI is the resolver key. An overlay can
    -- override this to aggregate finer references (e.g. verses).
    -- ============================================================
    CREATE FUNCTION stewards.doc_citations_resolved(p_slug text)
    RETURNS TABLE (
        cited_uri        text,
        cited_kind       text,
        anchor_text      text,
        citation_count   int,
        resolved         jsonb
    )
    LANGUAGE sql STABLE AS $func$
        SELECT c.cited_uri,
               c.cited_kind,
               c.anchor_text,
               c.citation_count,
               CASE WHEN rr.ref IS NULL THEN '{}'::jsonb
                    ELSE jsonb_build_object(
                             'ref',     rr.ref,
                             'content', rr.content,
                             'error',   rr.error)
               END AS resolved
          FROM stewards.doc_citations(p_slug) c
          LEFT JOIN stewards.resolved_refs rr ON rr.ref = c.cited_uri
         ORDER BY c.citation_count DESC, c.cited_uri ASC;
    $func$;
    "#,
    name = "create_resolver",
    requires = ["create_docs"],
);

// ---------------------------------------------------------------------------
// Similarity bridge (pgvector cosine -> SIMILAR_TO edges)
//
// All docs are embedded by the existing `embed` work_kind. This block
// writes precomputed similarity into the relational graph (01-graph):
//   1. For one source doc, compute cosine similarity against every
//      other embedded doc using pgvector's `<=>` operator.
//   2. Take top-K above min_score, upsert SIMILAR_TO edges with the
//      score as the edge weight and {method, score} in props.
//   3. Edges are directional from the source's perspective. Reads
//      union both directions so "similar to X" returns both
//      X->Y (X picked Y as top-K) and Y->X (Y picked X as top-K).
//
// Kept deliberately simple:
//   - One method only ('pgvector_cosine'), recorded in props. Edge
//     identity is (src, dst, kind) — a future second method either
//     replaces the edge or earns its own edge kind.
//   - No vector aggregation across citations yet — body embedding
//     IS the doc's representation. Sub-document similarity, if it
//     ever lands, gets its own edge kind.
//   - Refresh is on-demand. Re-embeds don't auto-trigger refresh;
//     bulk refresh is cheap at small corpus sizes. Revisit with a
//     NOTIFY-triggered refresh when the corpus grows past ~1000
//     docs and bulk refresh starts to hurt.
// ---------------------------------------------------------------------------
extension_sql!(
    r#"
    -- ============================================================
    -- refresh_doc_similarity(slug, top_k, min_score)
    --
    -- For one source doc, drop its outgoing SIMILAR_TO edges
    -- and write fresh ones for the top-K nearest other docs
    -- with cosine similarity >= min_score.
    --
    -- Returns the count of edges written. Returns 0 (and writes
    -- nothing) when the source doc has no embedding yet.
    --
    -- Defaults: top_k=5, min_score=0.5. Tune after observing real
    -- score distributions in the deployed corpus.
    -- ============================================================
    CREATE FUNCTION stewards.refresh_doc_similarity(
        p_slug      text,
        p_top_k     int     DEFAULT 5,
        p_min_score float   DEFAULT 0.5
    )
    RETURNS int
    LANGUAGE plpgsql AS $func$
    DECLARE
        v_src_emb     vector(768);
        v_node        uuid;
        v_written     int := 0;
        v_pair        record;
    BEGIN
        SELECT embedding INTO v_src_emb
          FROM stewards.docs
         WHERE slug = p_slug;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'doc not found: %', p_slug;
        END IF;

        v_node := stewards.graph_node_upsert('doc', p_slug);

        -- Always drop existing outgoing edges first — even when the
        -- embedding is NULL. "Refresh\" means the cache reflects
        -- current state; if the source has no embedding, current
        -- state is "no edges,\" not "whatever was here before.\"
        -- (Inverse hypothesis caught this: nulling the embedding +
        -- refreshing previously left stale edges in place.)
        DELETE FROM stewards.edges
         WHERE src = v_node
           AND kind = 'SIMILAR_TO'
           AND props->>'method' = 'pgvector_cosine';

        IF v_src_emb IS NULL THEN
            -- Not embedded yet — outgoing edges cleared, nothing to
            -- write. Caller can re-run after the embed bgworker drains.
            RETURN 0;
        END IF;

        -- Compute top-K and write each edge. Cosine similarity is
        -- 1 - (a <=> b) where <=> is pgvector's cosine distance.
        FOR v_pair IN
            SELECT s.slug AS dst_slug,
                   round((1 - (s.embedding <=> v_src_emb))::numeric, 4)::float AS score
              FROM stewards.docs s
             WHERE s.slug <> p_slug
               AND s.embedding IS NOT NULL
               AND (1 - (s.embedding <=> v_src_emb)) >= p_min_score
             ORDER BY s.embedding <=> v_src_emb
             LIMIT p_top_k
        LOOP
            PERFORM stewards.graph_edge_upsert(
                'doc', p_slug, 'doc', v_pair.dst_slug,
                'SIMILAR_TO',
                v_pair.score::real,
                jsonb_build_object('method', 'pgvector_cosine',
                                   'score',  v_pair.score));
            v_written := v_written + 1;
        END LOOP;

        RETURN v_written;
    END;
    $func$;

    -- Convenience: refresh every doc that has an embedding.
    -- Returns total edges written across the corpus.
    CREATE FUNCTION stewards.refresh_all_doc_similarity(
        p_top_k     int   DEFAULT 5,
        p_min_score float DEFAULT 0.5
    )
    RETURNS int
    LANGUAGE sql AS $func$
        SELECT coalesce(sum(stewards.refresh_doc_similarity(slug, p_top_k, p_min_score))::int, 0)
          FROM stewards.docs
         WHERE embedding IS NOT NULL;
    $func$;

    -- ============================================================
    -- doc_similar(slug, limit) — read SIMILAR_TO edges back.
    --
    -- Returns one row per OTHER doc related to the input slug.
    -- Matches edges in BOTH directions (a->b OR b->a), takes the
    -- higher score per pair (since both directions may exist with
    -- different scores — cosine is symmetric but top-K cutoffs
    -- can asymmetrically include/exclude an edge).
    --
    -- Joins back to stewards.docs so callers get title + file_path
    -- without a second round trip. Pure SQL — the relational graph
    -- removed the AGE temp-table workaround entirely.
    -- ============================================================
    CREATE FUNCTION stewards.doc_similar(
        p_slug  text,
        p_limit int DEFAULT 10
    )
    RETURNS TABLE (
        slug      text,
        title     text,
        file_path text,
        score     float,
        direction text   -- 'outgoing' | 'incoming' | 'mutual'
    )
    LANGUAGE sql STABLE AS $func$
        WITH me AS (
            SELECT id FROM stewards.nodes
             WHERE kind = 'doc' AND ref = p_slug
        ),
        hits AS (
            SELECT n.ref AS other_slug,
                   (e.props->>'score')::float AS score,
                   'outgoing' AS dir
              FROM stewards.edges e
              JOIN me ON e.src = me.id
              JOIN stewards.nodes n ON n.id = e.dst
             WHERE e.kind = 'SIMILAR_TO'
            UNION ALL
            SELECT n.ref,
                   (e.props->>'score')::float,
                   'incoming'
              FROM stewards.edges e
              JOIN me ON e.dst = me.id
              JOIN stewards.nodes n ON n.id = e.src
             WHERE e.kind = 'SIMILAR_TO'
        ),
        merged AS (
            SELECT h.other_slug,
                   max(h.score) AS score,
                   CASE
                       WHEN bool_or(h.dir = 'outgoing') AND bool_or(h.dir = 'incoming')
                            THEN 'mutual'
                       WHEN bool_or(h.dir = 'outgoing') THEN 'outgoing'
                       ELSE 'incoming'
                   END AS direction
              FROM hits h
             GROUP BY h.other_slug
        )
        SELECT m.other_slug, d.title, d.file_path, m.score, m.direction
          FROM merged m
          JOIN stewards.docs d ON d.slug = m.other_slug
         ORDER BY m.score DESC, m.other_slug ASC
         LIMIT p_limit;
    $func$;
    "#,
    name = "create_similarity",
    requires = ["create_resolver"],
);

// ---------------------------------------------------------------------------
// `doc show` view
//
// One SQL function that pulls together everything the docs subsystem
// built:
//   - the doc row (title, file_path, frontmatter)
//   - resolved citations with verse text
//   - similar docs ranked by cosine score
//
// Returns a single text blob formatted as markdown so a thin CLI
// wrapper just prints it. Keeping all formatting in SQL means the
// CLI is a one-liner (`psql -t -A -c "SELECT stewards.doc_show(...)"`)
// and any client (psql, Go binary, MCP tool, eventual web UI)
// renders the same view.
//
// Cite text is truncated for the show view (~140 chars) so the
// output stays scannable; full text is always available via
// stewards.doc_citations_resolved(slug).
// ---------------------------------------------------------------------------
extension_sql!(
    r#"
    CREATE FUNCTION stewards.doc_show(
        p_slug             text,
        p_similarity_limit int DEFAULT 5,
        p_citation_limit   int DEFAULT 20,
        p_verse_chars      int DEFAULT 140
    )
    RETURNS text
    LANGUAGE plpgsql AS $func$
    DECLARE
        v_study      stewards.docs%ROWTYPE;
        v_out        text := '';
        v_cite       record;
        v_verse      jsonb;
        v_sim        record;
        v_resolved_count int := 0;
        v_missing_count  int := 0;
        v_sim_count      int := 0;
    BEGIN
        SELECT * INTO v_study FROM stewards.docs WHERE slug = p_slug;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'doc not found: %', p_slug;
        END IF;

        v_out := v_out || '# ' || v_study.title || E'\n\n';
        v_out := v_out || '*kind:* `' || v_study.kind || '`'
                       || '  *slug:* `' || v_study.slug || '`'
                       || '  *file:* `' || v_study.file_path || '`' || E'\n';

        IF v_study.frontmatter IS NOT NULL
           AND v_study.frontmatter <> '{}'::jsonb
           AND jsonb_typeof(v_study.frontmatter) = 'object'
           AND (SELECT count(*) FROM jsonb_object_keys(v_study.frontmatter)) > 0 THEN
            v_out := v_out || E'\n*frontmatter:* `'
                           || v_study.frontmatter::text || '`' || E'\n';
        END IF;

        IF v_study.embedded_at IS NULL THEN
            v_out := v_out || E'\n*embedding:* not yet computed\n';
        ELSE
            v_out := v_out || E'\n*embedded:* '
                           || to_char(v_study.embedded_at, 'YYYY-MM-DD HH24:MI')
                           || ' (' || coalesce(v_study.embedded_model, '?') || ')'
                           || E'\n';
        END IF;

        -- ---------------- Citations (resolved) ----------------
        v_out := v_out || E'\n## Citations\n\n';

        FOR v_cite IN
            SELECT cited_uri, cited_kind, anchor_text, citation_count, resolved_verses
              FROM stewards.doc_citations_resolved(p_slug)
             ORDER BY citation_count DESC, anchor_text ASC
             LIMIT p_citation_limit
        LOOP
            v_out := v_out
                || '### ' || v_cite.anchor_text
                || '  *(' || v_cite.cited_kind || ', '
                || v_cite.citation_count::text
                || ' uses)*' || E'\n';
            v_out := v_out
                || '`' || v_cite.cited_uri || '`' || E'\n\n';

            -- Walk the resolved_verses array. Each element is
            -- {ref, content:{text,...}, error}.
            IF jsonb_array_length(coalesce(v_cite.resolved_verses, '[]'::jsonb)) = 0 THEN
                v_out := v_out
                    || '> _(no resolvable verses for this anchor — '
                    || 'chapter-only ref, talk URI, or unparseable)_'
                    || E'\n\n';
            ELSE
                FOR v_verse IN
                    SELECT * FROM jsonb_array_elements(v_cite.resolved_verses)
                LOOP
                    IF v_verse->>'error' IS NOT NULL THEN
                        v_out := v_out
                            || '- **' || (v_verse->>'ref') || '** _('
                            || (v_verse->>'error') || ')_' || E'\n';
                        v_missing_count := v_missing_count + 1;
                    ELSE
                        v_out := v_out
                            || '- **' || (v_verse->>'ref') || '** '
                            || left(coalesce(v_verse->'content'->>'text', ''), p_verse_chars)
                            || CASE
                                 WHEN length(coalesce(v_verse->'content'->>'text', ''))
                                      > p_verse_chars
                                 THEN ' …'
                                 ELSE ''
                               END
                            || E'\n';
                        v_resolved_count := v_resolved_count + 1;
                    END IF;
                END LOOP;
                v_out := v_out || E'\n';
            END IF;
        END LOOP;

        -- ---------------- Similar docs ----------------
        v_out := v_out || E'## Similar docs\n\n';

        FOR v_sim IN
            SELECT slug, title, score, direction
              FROM stewards.doc_similar(p_slug, p_similarity_limit)
        LOOP
            v_out := v_out
                || '- **' || v_sim.title || '** '
                || '(`' || v_sim.slug || '`) — '
                || 'score=' || to_char(v_sim.score, 'FM0.000')
                || ', ' || v_sim.direction || E'\n';
            v_sim_count := v_sim_count + 1;
        END LOOP;

        IF v_sim_count = 0 THEN
            v_out := v_out
                || '_(no similarity edges — run '
                || '`SELECT stewards.refresh_doc_similarity(''' || p_slug || ''')` '
                || 'to compute them)_' || E'\n';
        END IF;

        -- ---------------- Footer ----------------
        v_out := v_out
            || E'\n---\n'
            || '*' || v_resolved_count::text || ' verses resolved, '
            || v_missing_count::text || ' missing, '
            || v_sim_count::text || ' similar docs*' || E'\n';

        RETURN v_out;
    END;
    $func$;
    "#,
    name = "create_doc_show",
    requires = ["create_similarity"],
);
