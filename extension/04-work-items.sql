-- =====================================================================
-- 04-work-items — pipelines, work_items, doc tools, promotion
-- =====================================================================
-- Authored 2026-06-12 (consolidation leg). Sources folded, in original
-- ship order: 3c1 (pipelines + work_items + transitions), 3c2
-- (auto-advance trigger), 3c2-5 (doc tools + broadcast grant), 3c3
-- (stage templating; pipeline seeds went to the overlay at
-- extraction), 3c3-1 (trigger NULL-guard fixes; its chat_post_internal
-- marker-inheritance fix was born back into schema.rs), 3c3-3
-- (perms provenance; the source column was born back into schema.rs),
-- 3c3-5 + 5e4 §1 (promotion, merged final form), i1 (projects table),
-- i2 (project FK), i5 (origin CHECK final value set), h3-1
-- (work_items planning columns). Tables are born complete; functions
-- appear once, in final form.
--
-- Renames / redesigns at consolidation (parity/rename-map.tsv):
--   work_item_promote_to_study      → work_item_promote_to_doc
--   promoted doc kind 'study'       → 'doc'
--   trigger guard LIKE 'study-write%' → pipelines.promote_to_doc flag
--   promote 'review'-stage hardcode → pipeline's last stage
--   promotion writes via import_doc (graph CITES sync restored; 5e4's
--     live version had drifted to a direct INSERT)
--   doc tool schemas: workspace kind enum dropped; AGE wording gone
--
-- The design, in one paragraph: a pipeline is an immutable template —
-- a jsonb array of stages, each naming an agent_family/model/provider
-- and optionally an input_template and next stage. A work_item is an
-- instance flowing through those stages; dispatching a stage enqueues
-- one chat work_queue row tagged with _work_item_id/_stage_name
-- markers, and an AFTER UPDATE trigger harvests the completed chat:
-- rolls up tokens, detects final-vs-intermediate (tool loops continue
-- through the same session), records the stage output, and either
-- auto-dispatches the next stage or parks at awaiting_review (human
-- gate, token budget, or dispatch failure). Completed work_items on
-- pipelines with promote_to_doc=true land in stewards.docs through
-- the same import path every other doc uses.
-- =====================================================================

-- ---------------------------------------------------------------------
-- projects — formalizes work_items.project_association into an entity.
-- Slug regex enforced at the application layer (same shape as
-- work_items.slug): ^[a-z0-9-]+$. Not a CHECK so it can be relaxed
-- without surgery.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.projects (
    slug             text PRIMARY KEY,
    name             text NOT NULL,
    description      text,
    root_directory   text,        -- nullable; workspace-mount hook
    archived         boolean NOT NULL DEFAULT false,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.projects IS
'Project entities referenced by work_items.project_association. Archive via the UI; hard delete is restricted while work_items reference the project.';

CREATE INDEX IF NOT EXISTS projects_archived_idx
    ON stewards.projects(archived) WHERE NOT archived;

-- ---------------------------------------------------------------------
-- pipelines — immutable templates.
--
-- stages: jsonb array. Each element is an object with:
--   name           text  required, unique within the pipeline
--   agent_family   text  required, refs stewards.agents
--   model          text  required (the requested model)
--   provider       text  required (e.g., 'opencode_go', 'lm_studio')
--   input_template text  optional; {{input.x}} / {{stage_results.y}}
--                        placeholders rendered at dispatch
--   next           text  next stage name; NULL/missing for terminal
--   auto_advance   bool  default true; false = stop at awaiting_review
--
-- promote_to_doc: completed work_items on this pipeline are upserted
-- into stewards.docs by work_item_promote_to_doc (replaces the old
-- hardcoded LIKE 'study-write%' trigger guard — pipeline families are
-- operator data; behavior flags belong on the row).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.pipelines (
    family       text PRIMARY KEY
                 CHECK (family ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    description  text NOT NULL DEFAULT '',
    stages       jsonb NOT NULL
                 CHECK (jsonb_typeof(stages) = 'array'
                        AND jsonb_array_length(stages) >= 1),
    metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
    promote_to_doc boolean NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.pipelines IS
'Pipeline definitions. Each row is an immutable template describing the stages of a multi-step agent flow. work_items are instances that traverse a pipeline''s stages.';

COMMENT ON COLUMN stewards.pipelines.promote_to_doc IS
'When true, work_items that complete on this pipeline are upserted into stewards.docs via work_item_promote_to_doc (the last stage''s output is the publishable body).';

-- ---------------------------------------------------------------------
-- work_items — instances flowing through pipeline stages.
--
-- Status lifecycle:
--   pending          — created, current_stage not yet dispatched
--   in_progress      — current_stage's chat dispatched
--   awaiting_review  — stage completed; human ack needed (auto_advance
--                      off, token budget hit, or dispatch failure)
--   completed        — all stages done; terminal
--   failed           — error encountered; recoverable via human
--   cancelled        — terminal, intentional stop
--
-- origin: who created this work_item. 'agent_planning' rows are
-- proposals from a planning run; 'agent_proposal' from the
-- agent-proposal pipeline. parent_work_item_id points proposed items
-- back at the run that proposed them (ON DELETE SET NULL).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.work_items (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug            text UNIQUE,
    pipeline_family text NOT NULL
                    REFERENCES stewards.pipelines(family) ON DELETE RESTRICT,
    current_stage   text NOT NULL,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'in_progress',
                                       'awaiting_review', 'completed',
                                       'failed', 'cancelled')),
    -- Opening inputs — the user-supplied data the first stage works on.
    input           jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Per-stage outputs accumulate here keyed by stage name:
    --   {"outline": {"output": "...", "completed_at": "...",
    --                "tokens_in": N, "tokens_out": N}, ...}
    stage_results   jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- All chat session ids spawned by this work_item (one per stage).
    session_ids     text[] NOT NULL DEFAULT ARRAY[]::text[],
    -- Cost guards (06-cost maintains the micro-dollar columns via the
    -- cost_events trigger; born here so the table is complete)
    token_budget    int,
    tokens_in       int NOT NULL DEFAULT 0,
    tokens_out      int NOT NULL DEFAULT 0,
    cost_micro_dollars  bigint NOT NULL DEFAULT 0,
    cost_cap_micro      bigint,
    cost_capped_at      timestamptz,
    -- Model/provider pins + human-mediated escalation queue (06-cost +
    -- 07-steward machinery)
    model_override  text,
    provider_override text,
    -- Steward failure tracking (07-steward maintains these)
    failure_count           int NOT NULL DEFAULT 0,
    last_failure_reason     text,
    last_failure_diagnosis  text,
    quarantined_at          timestamptz,
    quarantine_reason       text,
    escalation_state    text NOT NULL DEFAULT 'normal'
                    CONSTRAINT work_items_escalation_state_check
                    CHECK (escalation_state IN ('normal','queued',
                                                 'in_progress','failed',
                                                 'resolved')),
    escalation_claimed_by   text,
    escalation_claimed_at   timestamptz,
    escalation_completed_at timestamptz,
    escalation_attempts     int NOT NULL DEFAULT 0,
    -- Provenance + planning (h3-1, born here)
    origin          text NOT NULL DEFAULT 'human'
                    CONSTRAINT work_items_origin_check
                    CHECK (origin = ANY (ARRAY[
                        'human', 'scheduled', 'watchman', 'steward',
                        'council', 'agent_planning', 'agent_proposal'
                    ])),
    project_association text
                    CONSTRAINT work_items_project_association_fkey
                    REFERENCES stewards.projects(slug)
                    ON UPDATE CASCADE
                    ON DELETE RESTRICT,
    parent_work_item_id uuid
                    CONSTRAINT work_items_parent_work_item_fk
                    REFERENCES stewards.work_items(id)
                    ON DELETE SET NULL,
    -- Audit
    actor           text NOT NULL DEFAULT 'human',
    error           text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz
);

CREATE INDEX IF NOT EXISTS work_items_status_idx
    ON stewards.work_items (status, created_at DESC);
CREATE INDEX IF NOT EXISTS work_items_pipeline_idx
    ON stewards.work_items (pipeline_family);
CREATE INDEX IF NOT EXISTS work_items_active_idx
    ON stewards.work_items (created_at DESC)
    WHERE status NOT IN ('completed', 'cancelled');
CREATE INDEX IF NOT EXISTS work_items_origin_idx
    ON stewards.work_items(origin);
CREATE INDEX IF NOT EXISTS work_items_project_association_idx
    ON stewards.work_items(project_association)
    WHERE project_association IS NOT NULL;
CREATE INDEX IF NOT EXISTS work_items_parent_work_item_idx
    ON stewards.work_items(parent_work_item_id)
    WHERE parent_work_item_id IS NOT NULL;

COMMENT ON TABLE stewards.work_items IS
'Instances flowing through a pipeline''s stages. Each stage''s output is recorded in stage_results keyed by stage name. session_ids carries the chat session id per dispatched stage so the full message history is reachable via `SELECT * FROM messages WHERE session_id = ANY(work_item.session_ids)`.';

COMMENT ON COLUMN stewards.work_items.project_association IS
'Optional project this work belongs to. FK to stewards.projects: ON UPDATE CASCADE propagates slug renames; ON DELETE RESTRICT prevents deleting a project with work_items (archive instead).';

-- ---------------------------------------------------------------------
-- Stage helpers
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.pipeline_stage_lookup(
    p_family     text,
    p_stage_name text
) RETURNS jsonb
LANGUAGE sql STABLE AS $func$
    SELECT s
      FROM stewards.pipelines p,
           jsonb_array_elements(p.stages) AS s
     WHERE p.family = p_family
       AND s->>'name' = p_stage_name
     LIMIT 1;
$func$;

CREATE OR REPLACE FUNCTION stewards.pipeline_first_stage_name(p_family text)
RETURNS text
LANGUAGE sql STABLE AS $func$
    SELECT (stages->0)->>'name'
      FROM stewards.pipelines
     WHERE family = p_family;
$func$;

CREATE OR REPLACE FUNCTION stewards.pipeline_last_stage_name(p_family text)
RETURNS text
LANGUAGE sql STABLE AS $func$
    SELECT (stages->(jsonb_array_length(stages) - 1))->>'name'
      FROM stewards.pipelines
     WHERE family = p_family;
$func$;

COMMENT ON FUNCTION stewards.pipeline_last_stage_name(text) IS
'Name of the pipeline''s terminal stage. work_item_promote_to_doc reads the publishable body from this stage''s output (replaces the old hardcoded ''review'' stage name).';

-- ---------------------------------------------------------------------
-- work_item_create(pipeline, input, slug?, actor?, token_budget?)
--
-- Creates a new work_item with status='pending', current_stage =
-- pipeline's first stage. Does NOT auto-dispatch; caller decides when
-- via work_item_dispatch_stage() (or the auto-advance trigger).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_create(
    p_pipeline_family text,
    p_input           jsonb DEFAULT '{}'::jsonb,
    p_slug            text  DEFAULT NULL,
    p_actor           text  DEFAULT 'human',
    p_token_budget    int   DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_first_stage text;
    v_id          uuid;
BEGIN
    SELECT stewards.pipeline_first_stage_name(p_pipeline_family)
      INTO v_first_stage;
    IF v_first_stage IS NULL THEN
        RAISE EXCEPTION
            'work_item_create: pipeline % not found or has no stages',
            p_pipeline_family;
    END IF;

    INSERT INTO stewards.work_items
        (pipeline_family, current_stage, slug, input, actor, token_budget)
    VALUES
        (p_pipeline_family, v_first_stage, p_slug, p_input, p_actor, p_token_budget)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_create(text, jsonb, text, text, int) IS
'Create a new work_item bound to a pipeline. Status starts ''pending'' with current_stage = first stage in the pipeline definition. Caller dispatches with work_item_dispatch_stage().';

-- ---------------------------------------------------------------------
-- Stage input templating.
--
-- resolve_template_path walks a {{root.a.b.c}} path against
-- work_item.input or work_item.stage_results, erroring loudly on
-- missing paths so template bugs surface at dispatch, not in agent
-- output. render_stage_input renders the current stage's
-- input_template; NULL when the stage has no template (caller falls
-- back).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.resolve_template_path(
    p_input         jsonb,
    p_stage_results jsonb,
    p_path          text
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_parts text[];
    v_root  text;
    v_value jsonb;
    i       int;
BEGIN
    v_parts := string_to_array(trim(p_path), '.');
    IF cardinality(v_parts) < 1 OR v_parts[1] IS NULL OR v_parts[1] = '' THEN
        RAISE EXCEPTION
            'resolve_template_path: empty path';
    END IF;

    v_root := v_parts[1];
    IF v_root = 'input' THEN
        v_value := p_input;
    ELSIF v_root = 'stage_results' THEN
        v_value := p_stage_results;
    ELSE
        RAISE EXCEPTION
            'resolve_template_path: unknown root % in path %; expected "input" or "stage_results"',
            v_root, p_path;
    END IF;

    -- Walk the rest of the path through nested jsonb objects.
    FOR i IN 2..cardinality(v_parts) LOOP
        IF v_value IS NULL OR jsonb_typeof(v_value) <> 'object' THEN
            RAISE EXCEPTION
                'resolve_template_path: path % not resolvable; stopped at %',
                p_path, v_parts[i-1];
        END IF;
        v_value := v_value -> v_parts[i];
    END LOOP;

    IF v_value IS NULL THEN
        RAISE EXCEPTION
            'resolve_template_path: path % resolved to NULL', p_path;
    END IF;

    -- Strings unwrap (no quotes); other types stringify.
    IF jsonb_typeof(v_value) = 'string' THEN
        RETURN v_value #>> '{}';
    ELSE
        RETURN v_value::text;
    END IF;
END;
$func$;

COMMENT ON FUNCTION stewards.resolve_template_path(jsonb, jsonb, text) IS
'Walk a {{root.a.b.c}} template path against work_item.input or work_item.stage_results. Errors loudly on missing paths so template bugs surface at dispatch, not in agent output.';

CREATE OR REPLACE FUNCTION stewards.render_stage_input(p_work_item_id uuid)
RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_wi       stewards.work_items%ROWTYPE;
    v_stage    jsonb;
    v_template text;
    v_rendered text;
    v_match    text[];
    v_path     text;
    v_value    text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'render_stage_input: work_item % not found', p_work_item_id;
    END IF;

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION
            'render_stage_input: stage % not found in pipeline %',
            v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    v_template := v_stage->>'input_template';
    IF v_template IS NULL THEN
        RETURN NULL;  -- caller falls back
    END IF;

    v_rendered := v_template;
    -- Walk every distinct {{...}} match.
    FOR v_match IN
        SELECT regexp_matches(v_template, '\{\{\s*([^}]+?)\s*\}\}', 'g')
    LOOP
        v_path := v_match[1];
        v_value := stewards.resolve_template_path(
            v_wi.input, v_wi.stage_results, v_path);
        -- Replace every literal {{<path>}} occurrence (with surrounding
        -- whitespace tolerance via a regex_replace).
        v_rendered := regexp_replace(
            v_rendered,
            '\{\{\s*' || regexp_replace(v_path, '([\\.()|*+?\[\]{}^$])', '\\\1', 'g') || '\s*\}\}',
            v_value,
            'g'
        );
    END LOOP;

    RETURN v_rendered;
END;
$func$;

COMMENT ON FUNCTION stewards.render_stage_input(uuid) IS
'Render the current stage''s input_template against work_item state. Returns NULL if the stage has no template (caller falls back).';

-- ---------------------------------------------------------------------
-- work_item_dispatch_stage(work_item_id, user_input?, allow_failed?)
--
-- Composes input + payload + enqueues a chat work_queue row for the
-- work_item's current_stage. Sets status='in_progress'. Builds the
-- payload directly (not via chat_enqueue) so it can inject the
-- _work_item_id / _stage_name markers the auto-advance trigger reads.
--
-- Honors work_items.model_override + provider_override (the steward's
-- one-shot pins). p_allow_failed_status=true unlocks re-dispatch from
-- status='failed' (steward retries pass true; other call sites stay
-- safe by passing nothing). failure_count is NOT reset on dispatch —
-- it tracks consecutive failures and resets only when a stage
-- genuinely advances.
--
-- Input resolution priority:
--   1. Explicit p_user_input override (CLI --user-input, or the
--      steward's retry guidance).
--   2. Stage's input_template rendered against work_item state.
--   3. work_item.input.user_input field (legacy fallback).
--   4. Stringified work_item.input (last-resort fallback).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_dispatch_stage(
    p_work_item_id           uuid,
    p_user_input             text DEFAULT NULL,
    p_allow_failed_status    boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_stage       jsonb;
    v_agent       text;
    v_model       text;
    v_provider    text;
    v_session_id  text;
    v_user_input  text;
    v_body        jsonb;
    v_payload     jsonb;
    v_work_id     bigint;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;
    IF v_wi.status NOT IN ('pending', 'awaiting_review')
       AND NOT (p_allow_failed_status AND v_wi.status = 'failed')
    THEN
        RAISE EXCEPTION 'work_item %: cannot dispatch from status %',
            p_work_item_id, v_wi.status;
    END IF;

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    v_agent    := v_stage->>'agent_family';
    -- Model + provider honor the work_item's one-shot overrides.
    v_model    := COALESCE(v_wi.model_override,    v_stage->>'model');
    v_provider := COALESCE(v_wi.provider_override, v_stage->>'provider');
    IF v_agent IS NULL OR v_model IS NULL OR v_provider IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % missing agent_family/model/provider',
            p_work_item_id, v_wi.current_stage;
    END IF;

    -- Session id pattern: wi--<short-uuid>--<stage>, capped at 200.
    v_session_id := substring(
        'wi--' || substring(p_work_item_id::text FROM 1 FOR 8)
        || '--' || v_wi.current_stage
        FROM 1 FOR 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('work_item %s stage %s', v_wi.id, v_wi.current_stage),
            'agent')
    ON CONFLICT (id) DO NOTHING;

    IF p_user_input IS NOT NULL THEN
        v_user_input := p_user_input;
    ELSE
        v_user_input := stewards.render_stage_input(p_work_item_id);
        IF v_user_input IS NULL THEN
            v_user_input := coalesce(
                v_wi.input->>'user_input',
                v_wi.input::text
            );
        END IF;
    END IF;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_user_input, v_model);

    v_body := stewards.dry_run_chat(v_agent, v_model, v_session_id, NULL);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_agent,
        'requested_model',    v_model,
        'meta',               v_body->'_meta',
        'body',               (v_body - '_meta')
                              || jsonb_build_object('user', v_session_id),
        -- Markers read by the auto-advance trigger:
        '_work_item_id',      p_work_item_id::text,
        '_stage_name',        v_wi.current_stage,
        '_pipeline_family',   v_wi.pipeline_family
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_provider, v_payload)
    RETURNING id INTO v_work_id;

    UPDATE stewards.work_items
       SET status      = 'in_progress',
           session_ids = session_ids || v_session_id,
           updated_at  = now()
     WHERE id = p_work_item_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_dispatch_stage(uuid, text, boolean) IS
'Dispatch the current stage. Honors work_items.model_override + provider_override; p_allow_failed_status=true unlocks steward re-dispatch from status=failed. Composes the chat body via dry_run_chat, enqueues a kind=chat work_queue row with _work_item_id/_stage_name markers, and sets status=in_progress.';

-- ---------------------------------------------------------------------
-- work_item_advance(work_item_id, stage_output)
--
-- Records the current stage's output, finds the next stage, and either
-- advances current_stage (status pending | awaiting_review per the
-- completing stage's auto_advance) or marks the work_item completed.
-- Returns the next stage name, or NULL if completed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_advance(
    p_work_item_id uuid,
    p_stage_output jsonb DEFAULT '{}'::jsonb
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_stage       jsonb;
    v_next_name   text;
    v_auto_advance bool;
    v_results     jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;
    IF v_wi.status NOT IN ('in_progress', 'awaiting_review', 'pending') THEN
        RAISE EXCEPTION 'work_item %: cannot advance from status %',
            p_work_item_id, v_wi.status;
    END IF;

    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RAISE EXCEPTION 'work_item %: stage % not found in pipeline %',
            p_work_item_id, v_wi.current_stage, v_wi.pipeline_family;
    END IF;

    v_next_name := v_stage->>'next';
    -- coalesce missing/null auto_advance to true
    v_auto_advance := coalesce((v_stage->>'auto_advance')::bool, true);

    -- Record this stage's output keyed by stage name.
    v_results := v_wi.stage_results
              || jsonb_build_object(v_wi.current_stage,
                     p_stage_output
                     || jsonb_build_object('completed_at', now()));

    IF v_next_name IS NULL OR v_next_name = '' THEN
        -- Terminal: no next stage.
        UPDATE stewards.work_items
           SET stage_results = v_results,
               status        = 'completed',
               completed_at  = now(),
               updated_at    = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    -- Validate next stage exists in the pipeline.
    IF stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_next_name) IS NULL THEN
        RAISE EXCEPTION
            'work_item %: stage %s `next` references missing stage %',
            p_work_item_id, v_wi.current_stage, v_next_name;
    END IF;

    UPDATE stewards.work_items
       SET stage_results = v_results,
           current_stage = v_next_name,
           status        = CASE WHEN v_auto_advance THEN 'pending'
                                ELSE 'awaiting_review' END,
           updated_at    = now()
     WHERE id = p_work_item_id;

    RETURN v_next_name;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_advance(uuid, jsonb) IS
'Record the current stage''s output and transition to the next stage (or mark completed if terminal). Returns next stage name or NULL.';

-- ---------------------------------------------------------------------
-- work_item_fail / work_item_cancel
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_fail(
    p_work_item_id uuid,
    p_error        text
) RETURNS void
LANGUAGE plpgsql AS $func$
BEGIN
    UPDATE stewards.work_items
       SET status     = 'failed',
           error      = p_error,
           updated_at = now()
     WHERE id = p_work_item_id
       AND status NOT IN ('completed', 'cancelled');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'work_item_fail: % not found or already in terminal status',
            p_work_item_id;
    END IF;
END;
$func$;

CREATE OR REPLACE FUNCTION stewards.work_item_cancel(
    p_work_item_id uuid,
    p_reason       text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS $func$
BEGIN
    UPDATE stewards.work_items
       SET status       = 'cancelled',
           error        = coalesce(p_reason, error),
           updated_at   = now(),
           completed_at = now()
     WHERE id = p_work_item_id
       AND status NOT IN ('completed', 'cancelled');
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'work_item_cancel: % not found or already in terminal status',
            p_work_item_id;
    END IF;
END;
$func$;

-- ---------------------------------------------------------------------
-- handle_work_item_chat_completion — the auto-advance trigger.
--
-- When a chat dispatched by work_item_dispatch_stage lands done/error:
--   1. Rolls up tokens into the parent work_item (always — including
--      intermediate tool-loop iterations; continuation chats inherit
--      the _* markers via chat_post_internal).
--   2. Detects final (clean stop / loop stop) vs intermediate (chat
--      handler enqueued a tool_dispatch continuation).
--   3. On final: work_item_advance with structured stage_output, then
--      auto-dispatch the next stage subject to auto_advance + token
--      budget gates; failures park at awaiting_review.
--   4. On error: work_item_fail.
--
-- Every clause of the final-detection is NULL-guarded (the original
-- version let `NULL IN (...)` poison the boolean and advanced on
-- intermediate chats). Defensive everywhere: a bug in the harvester
-- never breaks the bgworker's status flip.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.handle_work_item_chat_completion()
RETURNS trigger
LANGUAGE plpgsql AS $func$
DECLARE
    v_work_item_id    uuid;
    v_stage_name      text;
    v_session_id      text;
    v_assistant       stewards.messages%ROWTYPE;
    v_finish_reason   text;
    v_loop_stop       text;
    v_has_tool_calls  boolean;
    v_is_final        boolean;
    v_stage_output    jsonb;
    v_next_stage      text;
    v_wi_after        stewards.work_items%ROWTYPE;
    v_msg_tokens_in   int;
    v_msg_tokens_out  int;
BEGIN
    -- WHEN clause prefilters; this is belt-and-suspenders.
    IF NEW.kind <> 'chat'
       OR (NEW.payload->>'_work_item_id') IS NULL THEN
        RETURN NEW;
    END IF;
    IF NEW.status NOT IN ('done', 'error') THEN
        RETURN NEW;
    END IF;
    IF OLD.status = NEW.status THEN
        RETURN NEW;
    END IF;

    v_work_item_id := (NEW.payload->>'_work_item_id')::uuid;
    v_stage_name   := NEW.payload->>'_stage_name';
    v_session_id   := NEW.payload->>'session_id';

    -- Error path: fail the work_item.
    IF NEW.status = 'error' THEN
        BEGIN
            PERFORM stewards.work_item_fail(
                v_work_item_id,
                format('chat dispatch failed at stage %s: %s',
                       v_stage_name,
                       coalesce(NEW.error, '(no error msg)')));
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING
                'work_item trigger work_item_fail() failed for %: %',
                v_work_item_id, SQLERRM;
        END;
        RETURN NEW;
    END IF;

    -- Done path: read the latest assistant message.
    SELECT * INTO v_assistant
      FROM stewards.messages
     WHERE session_id = v_session_id AND role = 'assistant'
     ORDER BY id DESC LIMIT 1;

    IF v_assistant.id IS NULL THEN
        BEGIN
            PERFORM stewards.work_item_fail(
                v_work_item_id,
                format('no assistant message for stage %s session %s',
                       v_stage_name, v_session_id));
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RETURN NEW;
    END IF;

    -- Token rollup — applies to BOTH intermediate and final chats.
    v_msg_tokens_in  := coalesce(v_assistant.tokens_in,  0);
    v_msg_tokens_out := coalesce(v_assistant.tokens_out, 0)
                      + coalesce(v_assistant.reasoning_tokens, 0);

    UPDATE stewards.work_items
       SET tokens_in  = tokens_in  + v_msg_tokens_in,
           tokens_out = tokens_out + v_msg_tokens_out,
           updated_at = now()
     WHERE id = v_work_item_id;

    -- Final-vs-intermediate detection. Every clause NULL-guarded so
    -- the whole expression collapses to a true boolean (never NULL).
    v_finish_reason  := v_assistant.finish_reason;
    v_loop_stop      := NEW.result->>'loop_stop_reason';
    v_has_tool_calls := v_assistant.tool_calls IS NOT NULL
                        AND jsonb_typeof(v_assistant.tool_calls) = 'array'
                        AND jsonb_array_length(v_assistant.tool_calls) > 0;

    v_is_final := coalesce(
        (NOT v_has_tool_calls
         AND v_finish_reason IS NOT NULL
         AND v_finish_reason IN ('stop', 'length', 'content_filter'))
        OR (v_loop_stop IS NOT NULL
            AND v_loop_stop IN ('steps_exhausted', 'truncated_tool_calls')),
        false
    );

    IF NOT v_is_final THEN
        RETURN NEW;
    END IF;

    -- Build stage output. Includes loop_stop_reason when present so
    -- downstream stages can see "the prior stage hit step budget."
    v_stage_output := jsonb_build_object(
        'output',           v_assistant.content,
        'model',            v_assistant.model,
        'tokens_in',        v_msg_tokens_in,
        'tokens_out',       v_msg_tokens_out,
        'finish_reason',    v_finish_reason
    );
    IF v_loop_stop IS NOT NULL THEN
        v_stage_output := v_stage_output
            || jsonb_build_object('loop_stop_reason', v_loop_stop);
    END IF;

    BEGIN
        v_next_stage := stewards.work_item_advance(v_work_item_id, v_stage_output);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING
            'work_item trigger work_item_advance() failed for %: %',
            v_work_item_id, SQLERRM;
        BEGIN
            PERFORM stewards.work_item_fail(v_work_item_id,
                'auto-advance failed: ' || SQLERRM);
        EXCEPTION WHEN OTHERS THEN NULL;
        END;
        RETURN NEW;
    END;

    -- Terminal stage → work_item is now status=completed. Done.
    IF v_next_stage IS NULL THEN
        RETURN NEW;
    END IF;

    -- Re-fetch to check status. Only auto-dispatch when 'pending'
    -- (auto_advance=false on the completing stage parks at
    -- awaiting_review).
    SELECT * INTO v_wi_after FROM stewards.work_items WHERE id = v_work_item_id;
    IF v_wi_after.status <> 'pending' THEN
        RETURN NEW;
    END IF;

    -- Token budget gate (cost guard).
    IF v_wi_after.token_budget IS NOT NULL
       AND (v_wi_after.tokens_in + v_wi_after.tokens_out)
            >= v_wi_after.token_budget THEN
        UPDATE stewards.work_items
           SET status     = 'awaiting_review',
               error      = format(
                   'token budget exhausted at stage %s (%s/%s); '
                   || 'next stage %s not auto-dispatched',
                   v_stage_name,
                   v_wi_after.tokens_in + v_wi_after.tokens_out,
                   v_wi_after.token_budget,
                   v_next_stage),
               updated_at = now()
         WHERE id = v_work_item_id;
        RETURN NEW;
    END IF;

    -- Auto-dispatch next stage. If dispatch fails, mark awaiting_review
    -- (the prior stage's results are valid; the human decides).
    BEGIN
        PERFORM stewards.work_item_dispatch_stage(v_work_item_id);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING
            'work_item trigger dispatch_stage() failed for %: %',
            v_work_item_id, SQLERRM;
        UPDATE stewards.work_items
           SET status     = 'awaiting_review',
               error      = format('auto-dispatch of stage %s failed: %s',
                                   v_next_stage, SQLERRM),
               updated_at = now()
         WHERE id = v_work_item_id;
    END;

    RETURN NEW;
END;
$func$;

COMMENT ON FUNCTION stewards.handle_work_item_chat_completion() IS
'AFTER UPDATE trigger function on work_queue. When a chat row dispatched by work_item_dispatch_stage() lands done/error, advances the parent work_item: rolls up tokens, detects intermediate-vs-final, calls work_item_advance, and auto-dispatches the next stage (subject to token_budget + auto_advance gates). All side effects in the same tx as the work_queue status flip.';

-- Drop and recreate the trigger so re-applying this file is idempotent.
DROP TRIGGER IF EXISTS work_item_advance_completion ON stewards.work_queue;

CREATE TRIGGER work_item_advance_completion
    AFTER UPDATE OF status ON stewards.work_queue
    FOR EACH ROW
    WHEN ((NEW.kind = 'chat')
          AND (NEW.payload ? '_work_item_id')
          AND (NEW.status IN ('done', 'error'))
          AND (OLD.status IS DISTINCT FROM NEW.status))
    EXECUTE FUNCTION stewards.handle_work_item_chat_completion();

-- ---------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW stewards.work_items_active AS
SELECT id, slug, pipeline_family, current_stage, status,
       jsonb_object_keys(stage_results) AS completed_stage,
       cardinality(session_ids) AS sessions_dispatched,
       tokens_in, tokens_out, token_budget, actor,
       created_at, updated_at
  FROM stewards.work_items
 WHERE status NOT IN ('completed', 'cancelled');

CREATE OR REPLACE VIEW stewards.work_items_summary AS
SELECT wi.id,
       wi.slug,
       wi.pipeline_family,
       wi.current_stage,
       wi.status,
       wi.created_at,
       wi.updated_at,
       wi.completed_at,
       (wi.completed_at - wi.created_at) AS elapsed,
       wi.tokens_in,
       wi.tokens_out,
       wi.token_budget,
       cardinality(wi.session_ids)            AS stages_dispatched,
       (SELECT count(*) FROM jsonb_object_keys(wi.stage_results)) AS stages_completed,
       (SELECT jsonb_array_length(p.stages) FROM stewards.pipelines p
         WHERE p.family = wi.pipeline_family) AS stages_total,
       wi.actor,
       wi.error
  FROM stewards.work_items wi;

-- ---------------------------------------------------------------------
-- Doc tools: doc_search + doc_get (the corpus surface agents use).
-- The other three tool wrappers below front functions owned by other
-- subsystems (doc_similar, doc_citations, context_for).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.doc_search(
    p_query text,
    p_kinds text[] DEFAULT ARRAY[]::text[],
    p_limit int DEFAULT 10
) RETURNS TABLE (
    slug    text,
    kind    text,
    title   text,
    snippet text,
    rank    real
)
LANGUAGE sql STABLE AS $func$
    SELECT s.slug,
           s.kind,
           s.title,
           ts_headline('english', coalesce(s.body, ''), q,
                       'MaxWords=20, MinWords=10, ShortWord=3') AS snippet,
           ts_rank(s.body_tsv, q) AS rank
      FROM stewards.docs s,
           websearch_to_tsquery('english', p_query) q
     WHERE s.body_tsv @@ q
       AND (cardinality(p_kinds) = 0 OR s.kind = ANY(p_kinds))
     ORDER BY rank DESC
     LIMIT greatest(p_limit, 1);
$func$;

COMMENT ON FUNCTION stewards.doc_search(text, text[], int) IS
'FTS over stewards.docs.body_tsv. Multi-kind filter via array (empty = all). Ordered by ts_rank.';

CREATE OR REPLACE FUNCTION stewards.doc_get(
    p_slug          text,
    p_include_body  boolean DEFAULT true,
    p_line_offset   int     DEFAULT 0,
    p_line_count    int     DEFAULT 200,
    p_max_chars     int     DEFAULT 20000
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_doc             stewards.docs%ROWTYPE;
    v_lines           text[];
    v_total_lines     int;
    v_actual_count    int;
    v_body_slice      text;
    v_truncated       bool := false;
    v_citation_count  int;
    v_result          jsonb;
BEGIN
    SELECT * INTO v_doc FROM stewards.docs WHERE slug = p_slug;
    IF v_doc.id IS NULL THEN
        RETURN jsonb_build_object(
            'error', format('doc not found: %s', p_slug));
    END IF;

    SELECT count(*)::int INTO v_citation_count
      FROM stewards.doc_citations(p_slug);

    v_result := jsonb_build_object(
        'slug',           v_doc.slug,
        'kind',           v_doc.kind,
        'title',          v_doc.title,
        'frontmatter',    coalesce(v_doc.frontmatter, '{}'::jsonb),
        'citation_count', v_citation_count
    );

    IF p_include_body THEN
        v_lines := string_to_array(coalesce(v_doc.body, ''), E'\n');
        v_total_lines := cardinality(v_lines);

        IF p_line_offset < 0 THEN p_line_offset := 0; END IF;
        IF p_line_count < 1  THEN p_line_count  := 200; END IF;

        v_actual_count := least(
            p_line_count,
            greatest(0, v_total_lines - p_line_offset)
        );

        IF v_actual_count > 0 THEN
            v_body_slice := array_to_string(
                v_lines[p_line_offset + 1 : p_line_offset + v_actual_count],
                E'\n'
            );
        ELSE
            v_body_slice := '';
        END IF;

        IF p_max_chars > 0 AND length(v_body_slice) > p_max_chars THEN
            v_body_slice := substring(v_body_slice FROM 1 FOR p_max_chars);
            v_truncated  := true;
        END IF;

        v_result := v_result
            || jsonb_build_object(
                'body',                    v_body_slice,
                'body_line_offset',        p_line_offset,
                'body_lines_returned',     v_actual_count,
                'body_total_lines',        v_total_lines,
                'body_truncated_by_chars', v_truncated
            );
    ELSE
        -- Surface the line count even when body is omitted, so the
        -- agent can decide whether to fetch and at what offset.
        v_lines := string_to_array(coalesce(v_doc.body, ''), E'\n');
        v_result := v_result
            || jsonb_build_object(
                'body_total_lines', cardinality(v_lines)
            );
    END IF;

    RETURN v_result;
END;
$func$;

COMMENT ON FUNCTION stewards.doc_get(text, boolean, int, int, int) IS
'Read a doc + frontmatter + citation count + (optional) body with line-based pagination. Mirrors the Read tool''s offset/limit semantics. Returns jsonb.';

-- ---------------------------------------------------------------------
-- Tool wrappers (jsonb → jsonb). All decode args from the model's
-- tool_call.arguments jsonb, apply defaults, and call the underlying
-- typed function.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.doc_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.doc_search(
        p_args->>'query',
        coalesce(
            (SELECT array_agg(value::text)
               FROM jsonb_array_elements_text(coalesce(p_args->'kinds', '[]'::jsonb)) AS value),
            ARRAY[]::text[]
        ),
        coalesce((p_args->>'limit')::int, 10)
    ) t;
$func$;

CREATE OR REPLACE FUNCTION stewards.doc_get_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT stewards.doc_get(
        p_args->>'slug',
        coalesce((p_args->>'include_body')::boolean, true),
        coalesce((p_args->>'body_line_offset')::int, 0),
        coalesce((p_args->>'body_line_count')::int, 200),
        coalesce((p_args->>'max_body_chars')::int, 20000)
    );
$func$;

CREATE OR REPLACE FUNCTION stewards.doc_similar_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.doc_similar(
        p_args->>'slug',
        coalesce((p_args->>'limit')::int, 5)
    ) t
    WHERE coalesce((p_args->>'min_score')::float, 0.0) <= t.score;
$func$;

CREATE OR REPLACE FUNCTION stewards.doc_citations_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.doc_citations(p_args->>'slug') t;
$func$;

CREATE OR REPLACE FUNCTION stewards.doc_context_for_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $func$
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
    FROM stewards.context_for(
        p_args->>'slug',
        coalesce((p_args->>'depth')::int, 2)
    ) t;
$func$;

-- ---------------------------------------------------------------------
-- tool_defs registrations
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target)
VALUES
(
    'doc_search',
    'Full-text search over the substrate''s document corpus. Returns ranked matches with slug, kind, title, snippet, and ts_rank score. Use this to find docs by topic before reading them with doc_get. Filter to specific kinds via the `kinds` array (kinds are operator-defined; empty = all). Backed by Postgres FTS over body_tsv.',
    '{
        "type": "object",
        "required": ["query"],
        "properties": {
            "query":  {"type": "string", "minLength": 1, "maxLength": 200,
                       "description": "Natural-language search terms. Phrases in quotes are matched verbatim."},
            "kinds":  {"type": "array",
                       "items": {"type": "string"},
                       "description": "Filter to one or more doc kinds (e.g. doc, proposal, journal). Empty/omitted = search all kinds."},
            "limit":  {"type": "integer", "minimum": 1, "maximum": 20,
                       "description": "Max results (default 10)."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_search_tool"}'::jsonb
),
(
    'doc_get',
    'Read a doc by slug. Returns title, frontmatter, citation count, and body with line-based pagination. The body slice is bounded by `body_line_count` (line-aligned, no mid-word splits) AND `max_body_chars` (hard cap that wins if the slice is dense). For long docs, paginate via `body_line_offset = previous_offset + body_lines_returned` until `body_total_lines` is reached. Set `include_body=false` to fetch only metadata + total line count.',
    '{
        "type": "object",
        "required": ["slug"],
        "properties": {
            "slug":             {"type": "string", "description": "Doc slug (e.g. \"charity\", \"proposal-token-efficiency\")."},
            "include_body":     {"type": "boolean", "description": "Default true. Set false for metadata only."},
            "body_line_offset": {"type": "integer", "minimum": 0, "description": "Lines to skip before the slice (default 0)."},
            "body_line_count":  {"type": "integer", "minimum": 1, "maximum": 1000, "description": "Max lines per call (default 200)."},
            "max_body_chars":   {"type": "integer", "minimum": 100, "maximum": 50000, "description": "Hard char cap on the returned slice (default 20000)."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_get_tool"}'::jsonb
),
(
    'doc_similar',
    'Return docs semantically similar to the given slug, using precomputed pgvector cosine similarity edges. No on-the-fly embedding; cheap. Each result has a score (0..1, higher = more similar) and direction (outgoing | incoming | mutual). Use after doc_search to expand a topic''s neighborhood.',
    '{
        "type": "object",
        "required": ["slug"],
        "properties": {
            "slug":      {"type": "string"},
            "limit":     {"type": "integer", "minimum": 1, "maximum": 10, "description": "Max neighbors (default 5)."},
            "min_score": {"type": "number",  "minimum": 0,  "maximum": 1, "description": "Filter results below this score."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_similar_tool"}'::jsonb
),
(
    'doc_citations',
    'Return the canonical sources cited by a doc. Backed by CITES edges in the relational graph, parsed from markdown links during import. Returns cited_uri, cited_kind (external | doc), anchor_text (the link text the doc used), and citation_count (how many times that uri appears).',
    '{
        "type": "object",
        "required": ["slug"],
        "properties": {
            "slug": {"type": "string"}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_citations_tool"}'::jsonb
),
(
    'doc_context_for',
    'Walk the relational graph outward from a doc, returning typed-edge neighbors up to `depth` hops. Surfaces structural connections (workstream, doc, todo nodes via HAS_PROPOSAL, FEEDS, SUPERSEDES, IMPLEMENTS, HAS_TODO, HAS_PHASE edges) and semantic ones (CITES, SIMILAR_TO). Use this when "what''s connected to X?" is the question; use doc_similar when only semantic similarity is needed.',
    '{
        "type": "object",
        "required": ["slug"],
        "properties": {
            "slug":  {"type": "string"},
            "depth": {"type": "integer", "minimum": 1, "maximum": 4, "description": "Hops to walk (default 2). Capped at 4."}
        }
    }'::jsonb,
    '{"kind":"sql_fn","schema":"stewards","name":"doc_context_for_tool"}'::jsonb
)
ON CONFLICT (name) DO UPDATE
SET description    = EXCLUDED.description,
    args_schema    = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target;

-- ---------------------------------------------------------------------
-- Broadcast: allow doc_* across all non-watchman agents.
--
-- The tools are read-only over substrate state; there's no destructive
-- risk in granting broad access. Watchman's deny-everything pattern is
-- preserved (it ships with its own tools=none design). glob_match:
-- `doc_*` beats `*: deny` via the longest-match-wins resolver.
--
-- Tagged source='broadcast' so the importer's reimport-DELETE
-- (filtered to source='frontmatter') doesn't wipe it. ON CONFLICT
-- updates only `action` to avoid downgrading a row the agent's
-- frontmatter has since declared explicitly.
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
SELECT DISTINCT a.family, 'doc_*', 'allow', 'broadcast'
  FROM stewards.agents a
 WHERE a.family NOT LIKE 'watchman%'
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
SET action = EXCLUDED.action;

-- Provenance observability (3c.3.3).
CREATE OR REPLACE VIEW stewards.agent_tool_perms_by_source AS
SELECT source, count(*) AS row_count, count(DISTINCT agent_family) AS family_count
  FROM stewards.agent_tool_perms
 GROUP BY source;

-- ---------------------------------------------------------------------
-- Step budget for tool-using agents (3c.3.1 fix 3).
--
-- Real tool-using research routinely needs 20+ iterations; the agent
-- stops early on finish_reason='stop', so 50 is generous but safe.
-- Watchman agents stay at steps=1 (single-shot, no tools by design).
-- (B5 bakes steps=50 into seed_harness directly; this UPDATE then
-- covers only operator-imported agents.)
-- ---------------------------------------------------------------------
UPDATE stewards.agents
   SET steps = 50
 WHERE family NOT LIKE 'watchman%'
   AND steps < 50;

-- ---------------------------------------------------------------------
-- work_item_promote_to_doc — completed work_items land in the corpus.
--
-- Merged final form of 3c3-5 + 5e4 §1: flag-driven via
-- pipelines.promote_to_doc (was LIKE 'study-write%'), sabbath-gated
-- (refuses when the pipeline opts into sabbath and no reflection was
-- recorded — columns land later in the chain; the bundle installs
-- atomically so they exist before anything calls this), publishable
-- body read from the pipeline's LAST stage (was hardcoded 'review'),
-- title from input.binding_question, and the write goes through
-- import_doc so the doc node + CITES edges land in the graph (5e4's
-- live version had drifted to a direct INSERT that lost that sync).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.work_item_promote_to_doc(p_work_item_id uuid)
RETURNS text  -- the resulting slug, or NULL if not promotable
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_pipeline    stewards.pipelines%ROWTYPE;
    v_last_stage  text;
    v_body_text   text;
    v_slug        text;
    v_title       text;
    v_frontmatter jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF NOT FOUND THEN
        RAISE NOTICE 'work_item_promote_to_doc: % not found', p_work_item_id;
        RETURN NULL;
    END IF;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    -- Only promote completed work_items on pipelines that opt in.
    IF v_wi.status <> 'completed'
       OR v_pipeline.family IS NULL
       OR NOT v_pipeline.promote_to_doc THEN
        RETURN NULL;
    END IF;

    -- Sabbath gate (5e/D.5): if the pipeline opts into sabbath but the
    -- work_item never had a Sabbath reflection recorded, refuse
    -- promotion with a clear hint. The discipline is endings recorded.
    IF v_pipeline.sabbath_enabled AND v_wi.sabbath_completed_at IS NULL THEN
        RAISE EXCEPTION 'work_item_promote_to_doc: sabbath required before promotion for sabbath-enabled pipeline. Call stewards.sabbath_dispatch(%) first.', p_work_item_id
            USING ERRCODE = 'check_violation';
    END IF;

    -- The last stage's `output` is the publishable body. If it's empty
    -- or trivially short, skip — early failures shouldn't pollute docs.
    v_last_stage := stewards.pipeline_last_stage_name(v_wi.pipeline_family);
    v_body_text  := v_wi.stage_results -> v_last_stage ->> 'output';
    IF v_body_text IS NULL OR length(v_body_text) < 100 THEN
        RETURN NULL;
    END IF;

    v_slug := coalesce(v_wi.slug, p_work_item_id::text);

    v_title := v_wi.input ->> 'binding_question';
    IF v_title IS NULL OR length(v_title) = 0 THEN
        v_title := v_slug;
    END IF;

    -- Frontmatter records provenance + cost so readers can distinguish
    -- substrate-produced docs from imported ones.
    v_frontmatter := jsonb_build_object(
        'pipeline',             v_wi.pipeline_family,
        'work_item_id',         v_wi.id::text,
        'completed_at',         v_wi.completed_at,
        'sabbath_completed_at', v_wi.sabbath_completed_at,
        'tokens_in',            v_wi.tokens_in,
        'tokens_out',           v_wi.tokens_out
    );

    PERFORM stewards.import_doc(
        v_slug,
        NULL,           -- no file on disk; substrate-produced
        v_title,
        v_body_text,
        v_frontmatter,
        'doc'
    );

    RETURN v_slug;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_promote_to_doc(uuid) IS
'Upserts a completed work_item into stewards.docs via the standard import_doc() path (doc node + CITES edges included). Promotable iff the pipeline has promote_to_doc=true, the work_item is completed, the sabbath gate passes, and the last stage''s output is non-trivial. Returns the resulting slug or NULL. Idempotent.';

-- Trigger — fires on the status→completed transition. The pipeline
-- flag lives on another table, so the WHEN clause only narrows to the
-- transition; the function itself checks promote_to_doc.
CREATE OR REPLACE FUNCTION stewards.work_item_promote_trigger()
RETURNS trigger LANGUAGE plpgsql AS $func$
BEGIN
    IF NEW.status = 'completed' AND coalesce(OLD.status, '') <> 'completed' THEN
        PERFORM stewards.work_item_promote_to_doc(NEW.id);
    END IF;
    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS work_item_promote_trg ON stewards.work_items;
CREATE TRIGGER work_item_promote_trg
    AFTER UPDATE OF status ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.status = 'completed')
    EXECUTE FUNCTION stewards.work_item_promote_trigger();

-- ---------------------------------------------------------------------
-- Seed: echo-test pipeline (1 stage, smoke-test wiring). The agent
-- family / model / provider it names are operator data — the seed pack
-- ships matching example agents.
-- ---------------------------------------------------------------------
INSERT INTO stewards.pipelines (family, description, stages)
VALUES (
    'echo-test',
    'Single-stage smoke test. Dispatches one chat to verify the pipeline → work_item → chat → completion wiring.',
    jsonb_build_array(
        jsonb_build_object(
            'name',         'echo',
            'agent_family', 'stewards-explore',
            'model',        'kimi-k2.6',
            'provider',     'opencode_go',
            'next',         null,
            'auto_advance', true
        )
    )
)
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description,
       stages      = EXCLUDED.stages,
       updated_at  = now();
