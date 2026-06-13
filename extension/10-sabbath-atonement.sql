-- =====================================================================
-- 10-sabbath-atonement.sql — endings (Sabbath) + lessons-from-failure
--   (Atonement) + the file-materialize machinery.
--
-- Consolidated (authoring leg, 2026-06-13) from the historical chain:
--   5e   — pipelines.sabbath/atonement flags, stewards.lessons ledger,
--          work_items.sabbath_completed_at  (the sessions.kind 'sabbath'/
--          'atonement' values are born in src/schema.rs)
--   5e2  — sabbath template + apply_sabbath_result
--   5e3  — atonement template + apply_atonement_result
--   h1-0 — sabbath_dispatch / atonement_dispatch / maybe_enqueue_atonement
--          FINAL override-aware forms + work_items.sabbath/atonement_enabled
--          overrides (D-H5). maturity_ladder (also h1-0) is born in 08-gates.
--   6d   — pending_file_writes + file columns + render_file_path_template
--   i3   — enqueue_work_item_file FINAL (sets work_items.file_enqueued_at;
--          the column is born here as file_enqueued_at directly — there was
--          never a materialized_at on work_items in the authored chain.
--          pending_file_writes.materialized_at is a DIFFERENT column kept as-is.)
--   6e   — enqueue_lesson_file + the lessons promoted_to trigger ONLY.
--          enqueue_resolution_file lives in 12-council: it declares
--          stewards.resolutions%ROWTYPE and triggers ON stewards.resolutions,
--          and a %ROWTYPE / trigger on a not-yet-existing table fails at
--          CREATE (unlike a forward column ref).
--   am1  — pg_notify on pending_file_writes INSERT.
--
-- Dependency notes:
--   * extract_work_item_file_content (final, h1-6-6) and render_file_destination
--     (h3-followup-2) are in 08-gates — only on_maturity_verified / enqueue
--     call them, at runtime, when the full bundle is installed.
--   * Operator data NOT shipped here: per-pipeline sabbath flags
--     (study-write/lesson/talk sabbath_enabled=true) and file_destination_template
--     seeds live in the workspace overlay. Core ships the columns (default off).
-- =====================================================================

-- ---------------------------------------------------------------------
-- pipelines: sabbath/atonement opt-in flags + file-destination machinery
-- ---------------------------------------------------------------------

ALTER TABLE stewards.pipelines
    ADD COLUMN IF NOT EXISTS sabbath_enabled            boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS atonement_enabled          boolean NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS file_destination_template  text,
    ADD COLUMN IF NOT EXISTS file_content_jsonpath      text;

COMMENT ON COLUMN stewards.pipelines.sabbath_enabled IS
'Sabbath dispatch fires when a work_item reaches verified maturity. Default OFF; operators opt pipelines in (the overlay seeds study/lesson/talk ON).';
COMMENT ON COLUMN stewards.pipelines.atonement_enabled IS
'Atonement dispatch fires when a work_item is quarantined. Default OFF; opt-in per pipeline.';
COMMENT ON COLUMN stewards.pipelines.file_destination_template IS
'Optional file-destination template (supports <slug>, <project>, <id>). UI prefill + render_file_destination source for SQL-bypass work_items. NOT enforced.';
COMMENT ON COLUMN stewards.pipelines.file_content_jsonpath IS
'jsonpath override for extracting file content from stage_results. NULL = convention (stage_results.<final_stage>.output).';

-- ---------------------------------------------------------------------
-- work_items: sabbath/atonement overrides + sabbath timestamp + file cols
-- ---------------------------------------------------------------------

ALTER TABLE stewards.work_items
    ADD COLUMN IF NOT EXISTS sabbath_enabled      boolean NULL,
    ADD COLUMN IF NOT EXISTS atonement_enabled    boolean NULL,
    ADD COLUMN IF NOT EXISTS sabbath_completed_at timestamptz,
    ADD COLUMN IF NOT EXISTS file_destination     text,
    ADD COLUMN IF NOT EXISTS file_enqueued_at     timestamptz;

COMMENT ON COLUMN stewards.work_items.sabbath_enabled IS
'D-H5 per-work_item override for pipeline.sabbath_enabled. NULL = inherit; true = force on; false = skip. Resolved at sabbath_dispatch entry.';
COMMENT ON COLUMN stewards.work_items.atonement_enabled IS
'D-H5 per-work_item override for pipeline.atonement_enabled. NULL = inherit; true = force on; false = skip. Resolved at maybe_enqueue_atonement / atonement_dispatch entry.';
COMMENT ON COLUMN stewards.work_items.sabbath_completed_at IS
'Timestamp the Sabbath reflection landed for this work_item. work_item_promote_to_doc refuses if NULL on a sabbath_enabled pipeline.';
COMMENT ON COLUMN stewards.work_items.file_destination IS
'NULL = DB-only (default). A path = materialize there. Settable at create time or after the fact.';
COMMENT ON COLUMN stewards.work_items.file_enqueued_at IS
'i3 (was materialized_at): timestamp when enqueue_work_item_file queued a pending_file_writes row. Set at QUEUE time, not file-write time. The actual file-write timestamp lives on stewards.pending_file_writes.materialized_at.';

-- ---------------------------------------------------------------------
-- stewards.lessons — append-only ledger (Atonement lessons + Sabbath
-- reflections). Humans curate via the UI before promotion to .mind/ files.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.lessons (
    id              bigserial PRIMARY KEY,
    work_item_id    uuid REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    at              timestamptz NOT NULL DEFAULT now(),
    kind            text NOT NULL CHECK (kind IN
                        ('principle', 'decision', 'lesson', 'sabbath_reflection')),
    content         text NOT NULL,
    raw_response    jsonb,
    ratified_at     timestamptz,
    ratified_by     text,
    promoted_to     text,    -- '.mind/principles.md' | '.mind/decisions.md' | NULL
    work_id         bigint
);

CREATE INDEX IF NOT EXISTS lessons_at         ON stewards.lessons (at);
CREATE INDEX IF NOT EXISTS lessons_work_item  ON stewards.lessons (work_item_id);
CREATE INDEX IF NOT EXISTS lessons_unratified ON stewards.lessons (ratified_at) WHERE ratified_at IS NULL;
CREATE INDEX IF NOT EXISTS lessons_kind       ON stewards.lessons (kind);

COMMENT ON TABLE stewards.lessons IS
'Append-only ledger of lessons produced by Atonement (kind in principle|decision|lesson) and reflections produced by Sabbath (kind=sabbath_reflection). All rows land unratified; humans curate before promotion to .mind/ files (D-D3).';

CREATE OR REPLACE VIEW stewards.lessons_recent_ratified AS
SELECT l.*, wi.pipeline_family, wi.current_stage
  FROM stewards.lessons l
  JOIN stewards.work_items wi ON wi.id = l.work_item_id
 WHERE l.ratified_at IS NOT NULL
   AND l.kind IN ('lesson', 'principle')
 ORDER BY l.at DESC;

COMMENT ON VIEW stewards.lessons_recent_ratified IS
'Keyed by pipeline_family + current_stage. The Phase E retry composer pulls the last 3 per (pipeline, stage) into retry context.';

-- ---------------------------------------------------------------------
-- stewards.pending_file_writes — the substrate-side file-write queue.
-- Substrate stays FS-stateless; stewards-cli / the bridge materializer
-- drains the table and does the actual file I/O.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.pending_file_writes (
    id              bigserial PRIMARY KEY,
    requested_at    timestamptz NOT NULL DEFAULT now(),
    requested_by    text NOT NULL,
    target_path     text NOT NULL,
    write_mode      text NOT NULL CHECK (write_mode IN ('append', 'create')),
    content         text NOT NULL,
    source_id       text,
    source_kind     text,
    materialized_at timestamptz,
    materialized_by text
);

CREATE INDEX IF NOT EXISTS pending_file_writes_unmaterialized
    ON stewards.pending_file_writes (requested_at)
    WHERE materialized_at IS NULL;
CREATE INDEX IF NOT EXISTS pending_file_writes_source
    ON stewards.pending_file_writes (source_kind, source_id);

COMMENT ON TABLE stewards.pending_file_writes IS
'The substrate-side file-write queue. Producer hooks (enqueue_work_item_file, enqueue_lesson_file, enqueue_resolution_file) INSERT rows; the bridge / stewards-cli materializer consumes them. materialized_at here is the actual file-write timestamp (distinct from work_items.file_enqueued_at).';

-- ---------------------------------------------------------------------
-- gate_prompts: sabbath + atonement templates (table + CHECK born in 08)
-- ---------------------------------------------------------------------

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('sabbath',
$tmpl$A work_item just reached verified maturity. Mark its ending with a structured reflection. This is not more work — it is the recording of an ending.

The intent and covenant for this work are loaded into your system prompt above.

Pipeline: {{pipeline_family}}
Binding question: {{input_summary}}
Final output (truncated):
{{stage_results_summary}}

Reflect on:
- What did this work produce that you did not expect at the start?
- What got harder than predicted? What got easier?
- What pattern would you carry forward to the next work in this pipeline?
- What is the one sentence the human should remember from this work?

Respond with JSON ONLY (no prose around it, no tool calls):
{
  "reflection": "2-4 sentences naming what this work produced and what it cost",
  "carry_forward": "one sentence: what pattern to bring to the next work in this pipeline",
  "surprise": "one sentence: what didn't go as predicted (positive or negative)"
}
$tmpl$,
     'Phase 5e (D.2): Sabbath reflection. Bgworker dispatches with tools_disabled=true (D-C6 cost lesson).')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('atonement',
$tmpl$A work_item was quarantined after {{failure_count}} failures. Walk back through what was tried, what failed, what was eventually completed (or not), and propose lessons that should outlive this work_item.

The intent and covenant for this work are loaded into your system prompt above.

Pipeline: {{pipeline_family}}
Binding question: {{input_summary}}
Failure count: {{failure_count}}
Quarantine reason: {{quarantine_reason}}

Failure history (steward actions, most recent first):
{{steward_actions_summary}}

Final stage results:
{{stage_results_summary}}

Distinguish three kinds of takeaways:
- principles: enduring insights about HOW the work should be done (candidate for .mind/principles.md)
- decisions: specific choices made about THIS pipeline/stage that should be recorded (candidate for .mind/decisions.md)
- lessons: ephemeral observations relevant only for similar future work (substrate-only)

Be sparse. Three lessons that survive scrutiny beat thirty that get pruned.

Respond with JSON ONLY (no prose around it, no tool calls):
{
  "principles_to_record": ["principle 1", "principle 2", ...],
  "decisions": ["decision 1", ...],
  "lessons": ["lesson 1", "lesson 2", ...]
}
$tmpl$,
     'Phase 5e (D.3): Atonement extraction. Bgworker dispatches with tools_disabled=true.')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

-- ---------------------------------------------------------------------
-- render_file_path_template — <slug>/<id> substitution in a path
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.render_file_path_template(
    p_template text,
    p_slug     text,
    p_id       uuid
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
BEGIN
    IF p_template IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN replace(replace(p_template,
        '<slug>', coalesce(p_slug, p_id::text)),
        '<id>',   p_id::text);
END;
$func$;

COMMENT ON FUNCTION stewards.render_file_path_template(text, text, uuid) IS
'Substitute <slug> and <id> placeholders in a file path template. Used by enqueue_work_item_file.';

-- ---------------------------------------------------------------------
-- sabbath_dispatch (h1-0 final — work_item override resolved first)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.sabbath_dispatch(p_work_item_id uuid)
RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_pipeline        stewards.pipelines%ROWTYPE;
    v_effective       boolean;
    v_template        text;
    v_input_summary   text;
    v_stage_summary   text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_gate_model      text := 'qwen3.6-plus';
    v_gate_provider   text := 'opencode_go';
    v_gate_agent      text := 'plan';
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'sabbath_dispatch: work_item % not found', p_work_item_id;
    END IF;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    -- D-H5: resolve work_item override first; NULL inherits from pipeline.
    v_effective := COALESCE(v_wi.sabbath_enabled, v_pipeline.sabbath_enabled);
    IF NOT v_effective THEN
        RAISE EXCEPTION 'sabbath_dispatch: sabbath not enabled (work_item override=%, pipeline=%)',
            COALESCE(v_wi.sabbath_enabled::text, 'NULL'),
            v_pipeline.sabbath_enabled;
    END IF;

    SELECT template INTO v_template FROM stewards.gate_prompts WHERE id = 'sabbath';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.sabbath template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_summary := substring(coalesce(v_wi.stage_results::text, ''), 1, 8000);

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family',       v_wi.pipeline_family,
        'input_summary',         v_input_summary,
        'stage_results_summary', v_stage_summary
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--sabbath--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('sabbath work_item=%s', v_wi.id),
            'sabbath')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',      v_session_id,
        'agent_family',    v_gate_agent,
        'requested_model', v_gate_model,
        'meta',            '{}'::jsonb,
        'body',            (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                           || jsonb_build_object('user', v_session_id),
        'tools_disabled',  true,
        '_work_item_id',   p_work_item_id::text,
        '_sabbath',        true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.sabbath_dispatch(uuid) IS
'D-H5 final: resolves work_item.sabbath_enabled override first (COALESCE; NULL inherits pipeline). Enqueues a tools-off Sabbath reflection dispatch; bgworker auto-fires apply_sabbath_result on completion.';

-- ---------------------------------------------------------------------
-- apply_sabbath_result — write lesson row + timestamp work_item
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_sabbath_result(
    p_work_item_id uuid,
    p_result       jsonb,
    p_work_id      bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_lesson_id    bigint;
    v_reflection   text;
    v_carry        text;
    v_surprise     text;
    v_content      text;
BEGIN
    v_reflection := coalesce(p_result->>'reflection', '');
    v_carry      := coalesce(p_result->>'carry_forward', '');
    v_surprise   := coalesce(p_result->>'surprise', '');

    v_content := v_reflection;
    IF length(v_carry) > 0 THEN
        v_content := v_content || E'\n\nCarry forward: ' || v_carry;
    END IF;
    IF length(v_surprise) > 0 THEN
        v_content := v_content || E'\nSurprise: ' || v_surprise;
    END IF;

    INSERT INTO stewards.lessons
        (work_item_id, kind, content, raw_response, work_id)
    VALUES
        (p_work_item_id, 'sabbath_reflection', v_content, p_result, p_work_id)
    RETURNING id INTO v_lesson_id;

    UPDATE stewards.work_items
       SET sabbath_completed_at = now(),
           updated_at = now()
     WHERE id = p_work_item_id;

    RETURN v_lesson_id;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_sabbath_result(uuid, jsonb, bigint) IS
'Phase 5e (D.2): write Sabbath reflection to stewards.lessons + timestamp work_item.sabbath_completed_at. Returns lesson id.';

-- ---------------------------------------------------------------------
-- atonement_dispatch (h1-0 final — work_item override resolved first)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.atonement_dispatch(p_work_item_id uuid)
RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_pipeline        stewards.pipelines%ROWTYPE;
    v_effective       boolean;
    v_template        text;
    v_input_summary   text;
    v_stage_summary   text;
    v_actions_summary text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_gate_model      text := 'kimi-k2.6';
    v_gate_provider   text := 'opencode_go';
    v_gate_agent      text := 'plan';
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'atonement_dispatch: work_item % not found', p_work_item_id;
    END IF;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    -- D-H5: resolve work_item override first; NULL inherits from pipeline.
    v_effective := COALESCE(v_wi.atonement_enabled, v_pipeline.atonement_enabled);
    IF NOT v_effective THEN
        RAISE EXCEPTION 'atonement_dispatch: atonement not enabled (work_item override=%, pipeline=%)',
            COALESCE(v_wi.atonement_enabled::text, 'NULL'),
            v_pipeline.atonement_enabled;
    END IF;

    SELECT template INTO v_template FROM stewards.gate_prompts WHERE id = 'atonement';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.atonement template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_summary := substring(coalesce(v_wi.stage_results::text, ''), 1, 6000);

    SELECT string_agg(
             '  - [' || to_char(at, 'YYYY-MM-DD HH24:MI') || '] ' || action ||
             coalesce(' (' || diagnosis || ')', '') ||
             ': ' || observation,
             E'\n' ORDER BY at DESC)
      INTO v_actions_summary
      FROM (
        SELECT at, action, diagnosis, observation
          FROM stewards.steward_actions
         WHERE work_item_id = p_work_item_id
         ORDER BY at DESC
         LIMIT 20
      ) t;

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family',         v_wi.pipeline_family,
        'input_summary',           v_input_summary,
        'failure_count',           v_wi.failure_count::text,
        'quarantine_reason',       coalesce(v_wi.quarantine_reason, '(none)'),
        'steward_actions_summary', coalesce(v_actions_summary, '  (no steward actions recorded)'),
        'stage_results_summary',   v_stage_summary
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--atonement--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('atonement work_item=%s', v_wi.id),
            'atonement')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',      v_session_id,
        'agent_family',    v_gate_agent,
        'requested_model', v_gate_model,
        'meta',            '{}'::jsonb,
        'body',            (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                           || jsonb_build_object('user', v_session_id),
        'tools_disabled',  true,
        '_work_item_id',   p_work_item_id::text,
        '_atonement',      true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.atonement_dispatch(uuid) IS
'D-H5 final: resolves work_item.atonement_enabled override first (COALESCE; NULL inherits pipeline). Enqueues a tools-off Atonement extraction; bgworker auto-fires apply_atonement_result on completion.';

-- ---------------------------------------------------------------------
-- apply_atonement_result — one lesson row per item
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_atonement_result(
    p_work_item_id uuid,
    p_result       jsonb,
    p_work_id      bigint DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_principles jsonb;
    v_decisions  jsonb;
    v_lessons    jsonb;
    v_item       text;
    v_count      int := 0;
BEGIN
    v_principles := coalesce(p_result->'principles_to_record', '[]'::jsonb);
    v_decisions  := coalesce(p_result->'decisions',            '[]'::jsonb);
    v_lessons    := coalesce(p_result->'lessons',              '[]'::jsonb);

    FOR v_item IN SELECT jsonb_array_elements_text(v_principles) LOOP
        INSERT INTO stewards.lessons
            (work_item_id, kind, content, raw_response, work_id)
        VALUES
            (p_work_item_id, 'principle', v_item, p_result, p_work_id);
        v_count := v_count + 1;
    END LOOP;

    FOR v_item IN SELECT jsonb_array_elements_text(v_decisions) LOOP
        INSERT INTO stewards.lessons
            (work_item_id, kind, content, raw_response, work_id)
        VALUES
            (p_work_item_id, 'decision', v_item, p_result, p_work_id);
        v_count := v_count + 1;
    END LOOP;

    FOR v_item IN SELECT jsonb_array_elements_text(v_lessons) LOOP
        INSERT INTO stewards.lessons
            (work_item_id, kind, content, raw_response, work_id)
        VALUES
            (p_work_item_id, 'lesson', v_item, p_result, p_work_id);
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_atonement_result(uuid, jsonb, bigint) IS
'Phase 5e (D.3): write one stewards.lessons row per item across {principles, decisions, lessons}. All rows land unratified (D-D3 human curation). Returns total count inserted.';

-- ---------------------------------------------------------------------
-- maybe_enqueue_atonement (h1-0 final) — steward quarantine path entry.
-- No-op when atonement not enabled (override-aware). Safe to call always.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.maybe_enqueue_atonement(p_work_item_id uuid)
RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi        stewards.work_items%ROWTYPE;
    v_pipeline  stewards.pipelines%ROWTYPE;
    v_effective boolean;
    v_work_id   bigint;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    v_effective := COALESCE(v_wi.atonement_enabled, v_pipeline.atonement_enabled);
    IF NOT v_effective THEN
        RETURN NULL;
    END IF;

    BEGIN
        v_work_id := stewards.atonement_dispatch(p_work_item_id);
        RETURN v_work_id;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'maybe_enqueue_atonement: atonement_dispatch raised: %', SQLERRM;
        RETURN NULL;
    END;
END;
$func$;

COMMENT ON FUNCTION stewards.maybe_enqueue_atonement(uuid) IS
'D-H5 final: no-op if atonement not enabled (work_item override resolved first). The steward calls this from the quarantine path; safe to call always.';

-- ---------------------------------------------------------------------
-- enqueue_work_item_file (i3 final) — the universal work_item file
-- producer. Sets work_items.file_enqueued_at. Calls render_file_path_template
-- (here) + extract_work_item_file_content (08-gates, final h1-6-6 form).
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.enqueue_work_item_file(
    p_work_item_id uuid,
    p_requested_by text DEFAULT 'work_item'
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi      stewards.work_items%ROWTYPE;
    v_path    text;
    v_content text;
    v_pwid    bigint;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'enqueue_work_item_file: work_item % not found', p_work_item_id;
    END IF;

    IF v_wi.file_destination IS NULL THEN
        RETURN NULL;
    END IF;

    v_path := stewards.render_file_path_template(
        v_wi.file_destination, v_wi.slug, v_wi.id);
    IF v_path IS NULL OR length(trim(v_path)) = 0 THEN
        RAISE EXCEPTION 'enqueue_work_item_file: rendered path is empty for work_item %', p_work_item_id;
    END IF;

    v_content := stewards.extract_work_item_file_content(p_work_item_id);
    IF v_content IS NULL OR length(v_content) = 0 THEN
        RAISE EXCEPTION 'enqueue_work_item_file: extracted content is empty for work_item % (file path %)',
            p_work_item_id, v_path;
    END IF;

    INSERT INTO stewards.pending_file_writes
        (requested_by, target_path, write_mode, content, source_id, source_kind)
    VALUES
        (p_requested_by, v_path, 'create', v_content,
         p_work_item_id::text, 'work_item')
    RETURNING id INTO v_pwid;

    UPDATE stewards.work_items
       SET file_enqueued_at = now()
     WHERE id = p_work_item_id;

    RETURN v_pwid;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_work_item_file(uuid, text) IS
'i3 (was Batch G.4): the universal work_item file-write producer. Checks file_destination; if NULL returns NULL (no-op). Otherwise renders the path + extracts content via extract_work_item_file_content + INSERTs pending_file_writes + sets work_items.file_enqueued_at. Callers may re-enqueue intentionally (no internal guard).';

-- ---------------------------------------------------------------------
-- enqueue_lesson_file + the lessons promoted_to trigger (6e, lesson half).
-- The resolution-file producer is in 12-council (it needs stewards.resolutions).
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.enqueue_lesson_file(p_lesson_id bigint)
RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_lesson stewards.lessons%ROWTYPE;
    v_wi     stewards.work_items%ROWTYPE;
    v_pwid   bigint;
    v_header text;
    v_content text;
BEGIN
    SELECT * INTO v_lesson FROM stewards.lessons WHERE id = p_lesson_id;
    IF v_lesson.id IS NULL OR v_lesson.promoted_to IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_wi FROM stewards.work_items WHERE id = v_lesson.work_item_id;

    v_header := format(E'\n\n## %s — %s (%s)\n',
        to_char(coalesce(v_lesson.ratified_at, now()), 'YYYY-MM-DD'),
        v_lesson.kind,
        coalesce(v_wi.slug, v_lesson.work_item_id::text));

    v_content := v_header || v_lesson.content || E'\n';

    INSERT INTO stewards.pending_file_writes
        (requested_by, target_path, write_mode, content, source_id, source_kind)
    VALUES
        ('lesson_promote', v_lesson.promoted_to, 'append', v_content,
         v_lesson.id::text, 'lesson')
    RETURNING id INTO v_pwid;

    RETURN v_pwid;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_lesson_file(bigint) IS
'Batch G.4.5: queue a pending_file_writes row (append mode) for a ratified+promoted lesson. Dated section header keeps .mind/principles.md + .mind/decisions.md browsable as entries accumulate.';

CREATE OR REPLACE FUNCTION stewards.lessons_promoted_to_trigger()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    IF NEW.promoted_to IS NOT NULL
       AND (OLD.promoted_to IS NULL OR OLD.promoted_to <> NEW.promoted_to) THEN
        BEGIN
            PERFORM stewards.enqueue_lesson_file(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'enqueue_lesson_file failed for lesson %: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS lessons_promoted_to_au ON stewards.lessons;
CREATE TRIGGER lessons_promoted_to_au
    AFTER UPDATE OF promoted_to ON stewards.lessons
    FOR EACH ROW
    EXECUTE FUNCTION stewards.lessons_promoted_to_trigger();

COMMENT ON FUNCTION stewards.lessons_promoted_to_trigger() IS
'Batch G.4.5: fires enqueue_lesson_file when a lesson''s promoted_to column transitions from NULL to a path. Errors swallowed via NOTICE so the original ratify UPDATE still succeeds.';

-- ---------------------------------------------------------------------
-- am1 — pg_notify on pending_file_writes INSERT so the bridge drains
-- the table autonomously (with a 60s safety poll on the bridge side).
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.notify_pending_file_write()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('stewards_pending_file_write', NEW.id::text);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS pending_file_writes_notify ON stewards.pending_file_writes;
CREATE TRIGGER pending_file_writes_notify
    AFTER INSERT ON stewards.pending_file_writes
    FOR EACH ROW
    EXECUTE FUNCTION stewards.notify_pending_file_write();

COMMENT ON FUNCTION stewards.notify_pending_file_write() IS
'am1 (2026-05-22): fires pg_notify(stewards_pending_file_write) so the bridge can autonomously drain the table. See cmd/stewards-mcp materializerLoop.';

-- =====================================================================
-- Done. 10-sabbath-atonement: endings (Sabbath), lessons-from-failure
-- (Atonement), and the file-materialize queue + producers.
-- =====================================================================
