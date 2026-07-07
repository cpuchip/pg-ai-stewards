-- ===== [was 08-gates.sql] =====
-- =====================================================================
-- 08-gates.sql — maturity ladder + gate evaluation + verify + the
--                maturity→verified producer trigger
--
-- Consolidated (authoring leg, 2026-06-13) from the historical chain:
--   5a-maturity-gate            — columns, gate tables, render_template,
--                                 evaluate_gate, parse_gate_response
--   5b-scenarios-verify         — generate_scenarios, verify_work_item,
--                                 apply_scenarios_result, apply_verify_result
--   5c-sessions-gate-kind       — sessions.kind 'gate' (now born in schema.rs)
--   5e4 (rest)                  — §1 (the promotion gate) already moved into
--                                 04-work-items; nothing else from 5e4 lands
--                                 here (apply_gate_decision → 11-trust,
--                                 maybe_enqueue_atonement → 10-sabbath)
--   h1-6-1                      — work_item_advance maturity hook (final)
--   h1-6-2                      — auto_materialize columns + on_maturity_verified
--   h1-6-6                      — extract_work_item_file_content REVIEW-strip
--   l28                         — review-prefix verify gate (BEFORE trigger)
--   i3 (on_maturity_verified)   — final form reading file_enqueued_at
--   h3-followup-2               — render_file_destination
--
-- Dependency notes (the B2 non-linear-requires lesson + the cross-batch
-- function-evolution traps):
--   * apply_gate_decision is NOT defined here. Its final form SELECTs from
--     stewards.trust_scores; a plpgsql SELECT from a table born later in the
--     chain is not a proven-safe forward reference at CREATE time. It is
--     authored once, in final form, in 11-trust.sql.
--   * maybe_enqueue_atonement → 10-sabbath (it resolves the work_item/pipeline
--     atonement override and calls atonement_dispatch, both 10-sabbath).
--   * on_maturity_verified (here) references columns born in 10-sabbath
--     (file_enqueued_at, sabbath_*, file_destination) via NEW.<field> and
--     calls 10/13 functions (sabbath_dispatch, enqueue_work_item_file,
--     render_file_destination, enqueue_proposed_work_items) — all wrapped in
--     BEGIN/EXCEPTION. Record-field access + wrapped function calls are the
--     forward-reference shape 04-work-items already relies on; the bundle
--     installs atomically so everything exists before the trigger can fire.
--   * pipelines.maturity_ladder is born here (gate machinery). h1-0 in B4
--     re-asserts it with ADD COLUMN IF NOT EXISTS — a no-op.
-- =====================================================================

-- ---------------------------------------------------------------------
-- work_items: gate columns (maturity ladder + verify + auto-materialize)
-- ---------------------------------------------------------------------

ALTER TABLE stewards.work_items
    ADD COLUMN IF NOT EXISTS maturity                 text NOT NULL DEFAULT 'raw',
    ADD COLUMN IF NOT EXISTS scenarios                jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS revision_count           int NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS spec                     text,
    ADD COLUMN IF NOT EXISTS destination_maturity     text,
    ADD COLUMN IF NOT EXISTS auto_materialize_enabled boolean NULL;

DO $check$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'work_items_maturity_check'
    ) THEN
        ALTER TABLE stewards.work_items
            ADD CONSTRAINT work_items_maturity_check
            CHECK (maturity IN
                ('raw','researched','planned','specced','executing','verified'));
    END IF;
END;
$check$;

DO $check2$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'work_items_destination_maturity_check'
    ) THEN
        ALTER TABLE stewards.work_items
            ADD CONSTRAINT work_items_destination_maturity_check
            CHECK (destination_maturity IS NULL OR destination_maturity IN
                ('researched','planned','specced','executing','verified'));
    END IF;
END;
$check2$;

COMMENT ON COLUMN stewards.work_items.maturity IS
'Current maturity of the work_item. Advanced by gate decisions / the work_item_advance maturity hook, NOT by raw stage transitions. raw → researched → planned → specced → executing → verified.';
COMMENT ON COLUMN stewards.work_items.scenarios IS
'LLM-generated acceptance criteria as a JSON array of strings. Populated when maturity advances to specced; verify checks against these.';
COMMENT ON COLUMN stewards.work_items.revision_count IS
'How many times the gate has returned action=revise for this maturity. Capped at 2 → auto-surface (D-B2).';
COMMENT ON COLUMN stewards.work_items.spec IS
'The canonical spec text for this work_item. Set during the specced maturity.';
COMMENT ON COLUMN stewards.work_items.destination_maturity IS
'Where the human wants this work_item to end. NULL = default (verified, full Ammon-loop). Set lower (e.g. specced) to surface for review before continuing.';
COMMENT ON COLUMN stewards.work_items.auto_materialize_enabled IS
'D-H6.3 per-work_item override for pipeline.auto_materialize_on_verified. NULL = inherit; true = force on; false = skip auto-mat for this work_item.';

-- ---------------------------------------------------------------------
-- pipelines: maturity ladder + auto-materialize flag (gate machinery)
-- ---------------------------------------------------------------------

ALTER TABLE stewards.pipelines
    ADD COLUMN IF NOT EXISTS maturity_ladder jsonb NOT NULL
        DEFAULT '["raw","researched","planned","specced","executing","verified"]'::jsonb,
    ADD COLUMN IF NOT EXISTS auto_materialize_on_verified boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN stewards.pipelines.maturity_ladder IS
'D-H2: ordered jsonb array of maturity rung names this pipeline''s stages may produce. Default is the full six-rung ladder. Pipelines may declare a narrower or differently-ordered ladder (e.g. fiction-scene: ["premise","draft","polish"]). work_item_advance reads this for the forward-only maturity high-water mark.';
COMMENT ON COLUMN stewards.pipelines.auto_materialize_on_verified IS
'D-H6.3: when true, enqueue_work_item_file fires automatically on maturity→verified for work_items with file_destination set. Default false preserves the "explicit gesture" design. Flip per pipeline once trustworthy.';

-- ---------------------------------------------------------------------
-- pipeline_stage_maturity — per-(family, stage) → produced maturity
--
-- Ships EMPTY in core: the per-pipeline rows (study-write outline→planned,
-- etc.) are operator data and live in the workspace overlay. Gate fires
-- when a stage completes that has a row here; no row = intermediate stage.
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.pipeline_stage_maturity (
    pipeline_family   text NOT NULL,
    stage_name        text NOT NULL,
    produces_maturity text NOT NULL CHECK (produces_maturity IN
        ('researched','planned','specced','executing','verified')),
    notes             text,
    PRIMARY KEY (pipeline_family, stage_name)
);

COMMENT ON TABLE stewards.pipeline_stage_maturity IS
'Per-(pipeline_family, stage) what maturity that stage produces. Gate fires when a stage completes that has a row here. NULL/missing row = stage doesn''t produce a maturity (intermediate stage). Operator data — per-pipeline rows live in the workspace overlay.';

-- ---------------------------------------------------------------------
-- gate_decisions — append-only audit ledger (written by apply_gate_decision,
-- which is authored in 11-trust)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.gate_decisions (
    id              bigserial PRIMARY KEY,
    work_item_id    uuid REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    at              timestamptz NOT NULL DEFAULT now(),
    from_maturity   text NOT NULL,
    action          text NOT NULL CHECK (action IN ('advance','revise','surface')),
    reasoning       text,
    feedback        text,
    work_id         bigint,
    revision_count  int NOT NULL DEFAULT 0,
    raw_response    jsonb
);
CREATE INDEX IF NOT EXISTS gate_decisions_work_item ON stewards.gate_decisions(work_item_id);
CREATE INDEX IF NOT EXISTS gate_decisions_at        ON stewards.gate_decisions(at);

COMMENT ON TABLE stewards.gate_decisions IS
'Append-only audit of every gate decision. Each row captures action (advance|revise|surface), reasoning, feedback, and a snapshot of revision_count at decision time.';

-- ---------------------------------------------------------------------
-- gate_prompts — per-prompt templates (born-complete CHECK)
--
-- The table + CHECK are born here with the full id set the chain uses.
-- Each subsystem seeds its own templates: gate (here), covenant_check
-- (09-intents), sabbath/atonement (10-sabbath), council_* (12-council).
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.gate_prompts (
    id        text PRIMARY KEY,
    template  text NOT NULL,
    notes     text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT gate_prompts_id_check CHECK (id IN (
        'evaluate','generate_scenarios','verify','covenant_check',
        'sabbath','atonement',
        'council_proposer','council_critic','council_synthesizer'
    ))
);

COMMENT ON TABLE stewards.gate_prompts IS
'Per-prompt templates with {{placeholder}} syntax. Each gate/sabbath/atonement/council dispatcher composes from these + work_item context. Born-complete id set; each subsystem seeds its own rows.';

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('evaluate',
$tmpl$You are a gate evaluator for a structured second-brain pipeline. Your job is to decide whether a piece of work has matured enough to advance, needs revision, or needs human steering.

The intent and covenant for this work are loaded into your system prompt above — keep them in mind. The covenant's surface_tensions and check_existing_work commitments apply to your evaluation.

Pipeline: {{pipeline_family}}
Current stage just completed: {{current_stage}}
Current maturity: {{maturity}}
Maturity this stage produces: {{produces_maturity}}
Revision count for this maturity: {{revision_count}}

Binding question / input:
{{input_summary}}

Latest stage output:
{{stage_output}}

Decide ONE of:
- "advance" — the work has clearly satisfied the criteria for this maturity AND advances the stated intent. Move to the next stage / next maturity.
- "revise" — the work is on the right track but needs another pass. Provide specific, actionable feedback for what to improve.
- "surface" — the work needs human steering. Either it drifts from the stated intent, hit a constraint you can't resolve, or the binding question shifted. Provide a brief explanation of what the human needs to decide.

Respond with JSON ONLY (no prose around it, no tool calls):
{
  "action": "advance" | "revise" | "surface",
  "reasoning": "1-3 sentences explaining the decision, referencing intent/covenant where relevant",
  "feedback": "if revise: what to do differently next pass; if surface: what the human needs to decide; if advance: omit or empty string"
}
$tmpl$,
     'Phase 5d (C.6 revision): references intent + covenant from system prompt; reminds model no tool calls. Default gate evaluation prompt; bgworker dispatches with tools_disabled=true.'),

    ('generate_scenarios',
$tmpl$You are producing acceptance criteria for a piece of work that has just been spec''d.

Pipeline: {{pipeline_family}}
Binding question: {{input_summary}}
Spec / planning output:
{{spec_or_stage_output}}

Generate 3-7 testable acceptance criteria as a JSON array of strings. Each criterion should be SPECIFIC, VERIFIABLE, and OBSERVABLE in the eventual execution output. Avoid vague criteria like "the work is high quality"; prefer "the output cites at least 3 sources by name" or "the conclusion answers the binding question explicitly."

Respond with JSON ONLY:
{
  "scenarios": [
    "criterion 1 phrased as a checkable statement",
    "criterion 2 ...",
    ...
  ]
}
$tmpl$,
     'Generates acceptance criteria. Output stored in work_items.scenarios; human-editable before execute begins (D-B3).'),

    ('verify',
$tmpl$You are checking whether the execution output meets each acceptance criterion.

Pipeline: {{pipeline_family}}
Binding question: {{input_summary}}

Acceptance criteria:
{{scenarios}}

Execution output:
{{stage_output}}

For each criterion, judge whether the execution output satisfies it. Be strict — if a criterion isn't clearly met, mark it failed.

Respond with JSON ONLY:
{
  "all_passed": true | false,
  "reasoning": "1-2 sentence overall summary",
  "results": [
    {"scenario": "criterion text verbatim", "passed": true, "notes": "where this is evidenced or what's missing"},
    ...
  ]
}
$tmpl$,
     'Verifies execution output against scenarios. all_passed=false drops maturity back to planned with verify feedback.')
ON CONFLICT (id) DO UPDATE
SET template   = EXCLUDED.template,
    notes      = EXCLUDED.notes,
    updated_at = now();

-- ---------------------------------------------------------------------
-- verify_results — per-work_item verify outcomes (born-complete:
-- reasoning nullable + raw_response, matching the final apply_verify_result)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.verify_results (
    id            bigserial PRIMARY KEY,
    work_item_id  uuid REFERENCES stewards.work_items(id) ON DELETE CASCADE,
    at            timestamptz NOT NULL DEFAULT now(),
    all_passed    boolean NOT NULL,
    reasoning     text,
    results       jsonb NOT NULL DEFAULT '[]'::jsonb,
    work_id       bigint,
    raw_response  jsonb
);
CREATE INDEX IF NOT EXISTS verify_results_work_item ON stewards.verify_results(work_item_id);

COMMENT ON TABLE stewards.verify_results IS
'Per-work_item verify pass/fail records. all_passed=false → maturity drops back to planned with results as feedback for re-execute.';

-- ---------------------------------------------------------------------
-- render_template — minimal {{placeholder}} substitution
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.render_template(
    p_template text,
    p_kv       jsonb
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_out text := p_template;
    v_key text;
    v_val text;
BEGIN
    IF p_kv IS NULL THEN
        RETURN v_out;
    END IF;
    FOR v_key, v_val IN
        SELECT key, coalesce(value::text, '')
          FROM jsonb_each_text(p_kv)
    LOOP
        v_out := replace(v_out, '{{' || v_key || '}}', v_val);
    END LOOP;
    RETURN v_out;
END;
$func$;

COMMENT ON FUNCTION stewards.render_template(text, jsonb) IS
'Minimal {{key}} → value substitution for prompt templates. NOT a full template engine.';

-- ---------------------------------------------------------------------
-- evaluate_gate(work_item_id) — enqueue a gate-eval chat
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.evaluate_gate(
    p_work_item_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_produces_maturity text;
    v_template        text;
    v_input_summary   text;
    v_stage_output    text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_gate_model      text := 'qwen3.7-plus';
    v_gate_provider   text := 'opencode_go';
    v_gate_agent      text := 'plan';
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    SELECT produces_maturity INTO v_produces_maturity
      FROM stewards.pipeline_stage_maturity
     WHERE pipeline_family = v_wi.pipeline_family
       AND stage_name = v_wi.current_stage;

    SELECT template INTO v_template
      FROM stewards.gate_prompts WHERE id = 'evaluate';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.evaluate template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_output  := substring(
        coalesce(v_wi.stage_results->v_wi.current_stage->>'output', ''),
        1, 8000);

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family',   v_wi.pipeline_family,
        'current_stage',     v_wi.current_stage,
        'maturity',          v_wi.maturity,
        'produces_maturity', coalesce(v_produces_maturity, '(none)'),
        'revision_count',    v_wi.revision_count::text,
        'input_summary',     v_input_summary,
        'stage_output',      v_stage_output
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--gate-' ||
        v_wi.maturity || '--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('gate eval work_item=%s maturity=%s', v_wi.id, v_wi.maturity),
            'gate')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_gate_agent,
        'requested_model',    v_gate_model,
        'meta',               '{}'::jsonb,
        'body',               (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                              || jsonb_build_object('user', v_session_id),
        'tools_disabled',     true,           -- C.6: structured JSON output, no research loop
        '_work_item_id',      p_work_item_id::text,
        '_stage_name',        v_wi.current_stage,
        '_pipeline_family',   v_wi.pipeline_family,
        '_gate_eval',         true,
        '_gate_from_maturity', v_wi.maturity
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.evaluate_gate(uuid) IS
'Enqueues a gate-eval chat for a work_item. Returns the work_queue id; the bgworker parses the JSON response and calls apply_gate_decision (11-trust) on the _gate_eval marker.';

-- ---------------------------------------------------------------------
-- parse_gate_response(work_id) — extract JSON decision from the chat
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.parse_gate_response(
    p_work_id bigint
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_session_id text;
    v_content    text;
    v_json_start int;
    v_json_end   int;
    v_candidate  text;
    v_parsed     jsonb;
BEGIN
    SELECT (payload->>'session_id') INTO v_session_id
      FROM stewards.work_queue
     WHERE id = p_work_id;
    IF v_session_id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT content INTO v_content
      FROM stewards.messages
     WHERE session_id = v_session_id AND role = 'assistant'
     ORDER BY id DESC LIMIT 1;
    IF v_content IS NULL OR length(trim(v_content)) = 0 THEN
        RETURN NULL;
    END IF;

    v_json_start := position('{' in v_content);
    v_json_end := length(v_content) - position('}' in reverse(v_content)) + 1;
    IF v_json_start = 0 OR v_json_end < v_json_start THEN
        RETURN NULL;
    END IF;
    v_candidate := substring(v_content FROM v_json_start FOR v_json_end - v_json_start + 1);

    BEGIN
        v_parsed := v_candidate::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RETURN NULL;
    END;

    RETURN v_parsed;
END;
$func$;

COMMENT ON FUNCTION stewards.parse_gate_response(bigint) IS
'Reads the assistant message for a gate-eval work_queue id, extracts the JSON decision (heuristic: first { to last }), returns parsed jsonb or NULL. Doubles for any JSON-returning gate chat (scenarios, verify).';

-- ---------------------------------------------------------------------
-- generate_scenarios(work_item_id) — enqueue scenarios chat
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.generate_scenarios(
    p_work_item_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_template        text;
    v_input_summary   text;
    v_stage_output    text;
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
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    SELECT template INTO v_template
      FROM stewards.gate_prompts WHERE id = 'generate_scenarios';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.generate_scenarios template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_output := substring(
        coalesce(v_wi.spec, v_wi.stage_results->v_wi.current_stage->>'output', ''),
        1, 8000);

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family',     v_wi.pipeline_family,
        'input_summary',       v_input_summary,
        'spec_or_stage_output', v_stage_output
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--scenarios--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('scenarios gen work_item=%s', v_wi.id),
            'gate')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_gate_agent,
        'requested_model',    v_gate_model,
        'meta',               '{}'::jsonb,
        'body',               (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                              || jsonb_build_object('user', v_session_id),
        'tools_disabled',     true,           -- C.6
        '_work_item_id',      p_work_item_id::text,
        '_scenarios_gen',     true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.generate_scenarios(uuid) IS
'Phase 5b + 5d (C.6): enqueue a chat that generates 3-7 acceptance criteria for a work_item. tools_disabled=true (no research loop). Output written to work_items.scenarios via apply_scenarios_result (auto-fired by bgworker on _scenarios_gen marker).';

-- ---------------------------------------------------------------------
-- apply_scenarios_result(work_item_id, scenarios_array)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_scenarios_result(
    p_work_item_id uuid,
    p_scenarios    jsonb,
    p_work_id      bigint DEFAULT NULL
) RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_count int;
BEGIN
    IF jsonb_typeof(p_scenarios) = 'object' AND p_scenarios ? 'scenarios' THEN
        p_scenarios := p_scenarios->'scenarios';
    END IF;

    IF jsonb_typeof(p_scenarios) != 'array' THEN
        RAISE EXCEPTION 'apply_scenarios_result: expected JSON array, got %',
            jsonb_typeof(p_scenarios);
    END IF;

    v_count := jsonb_array_length(p_scenarios);

    UPDATE stewards.work_items
       SET scenarios  = p_scenarios,
           updated_at = now()
     WHERE id = p_work_item_id;

    INSERT INTO stewards.steward_actions
        (work_item_id, observation, diagnosis, action, details)
    VALUES
        (p_work_item_id,
         format('scenarios generated: %s criteria', v_count),
         'gate',
         'scenarios_generated',
         jsonb_build_object('count', v_count, 'work_id', p_work_id));

    RETURN v_count;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_scenarios_result(uuid, jsonb, bigint) IS
'Write generated scenarios to work_items.scenarios. Accepts {"scenarios":[...]} or bare array. Returns count.';

-- ---------------------------------------------------------------------
-- verify_work_item(work_item_id) — enqueue verify chat
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.verify_work_item(
    p_work_item_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_template        text;
    v_input_summary   text;
    v_stage_output    text;
    v_scenarios_str   text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_gate_model      text := 'qwen3.7-plus';
    v_gate_provider   text := 'opencode_go';
    v_gate_agent      text := 'plan';
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    IF v_wi.scenarios IS NULL OR jsonb_array_length(v_wi.scenarios) = 0 THEN
        RAISE EXCEPTION 'verify_work_item: work_item % has no scenarios — call generate_scenarios first', p_work_item_id;
    END IF;

    SELECT template INTO v_template
      FROM stewards.gate_prompts WHERE id = 'verify';
    IF v_template IS NULL THEN
        RAISE EXCEPTION 'gate_prompts.verify template missing';
    END IF;

    v_input_summary := substring(coalesce(v_wi.input::text, ''), 1, 2000);
    v_stage_output := substring(
        coalesce(v_wi.stage_results->v_wi.current_stage->>'output', ''),
        1, 8000);

    SELECT string_agg('  - ' || s, E'\n')
      INTO v_scenarios_str
      FROM jsonb_array_elements_text(v_wi.scenarios) s;

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'pipeline_family', v_wi.pipeline_family,
        'input_summary',   v_input_summary,
        'scenarios',       coalesce(v_scenarios_str, '(none)'),
        'stage_output',    v_stage_output
    ));

    v_session_id := substring(
        'wi--' || substring(v_wi.id::text FROM 1 FOR 8) || '--verify--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('verify work_item=%s', v_wi.id),
            'gate')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_gate_model);

    v_payload := jsonb_build_object(
        'session_id',         v_session_id,
        'agent_family',       v_gate_agent,
        'requested_model',    v_gate_model,
        'meta',               '{}'::jsonb,
        'body',               (stewards.dry_run_chat(v_gate_agent, v_gate_model, v_session_id, NULL) - '_meta')
                              || jsonb_build_object('user', v_session_id),
        'tools_disabled',     true,           -- C.6
        '_work_item_id',      p_work_item_id::text,
        '_verify',            true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', v_gate_provider, v_payload)
    RETURNING id INTO v_work_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.verify_work_item(uuid) IS
'Phase 5b + 5d (C.6): enqueue a verify chat that checks execution output against work_items.scenarios. tools_disabled=true. Result written via apply_verify_result (auto-fired by bgworker on _verify marker).';

-- ---------------------------------------------------------------------
-- apply_verify_result(work_item_id, result_jsonb)
--
-- Final form (h1-6-2): on all_passed=true does NOT advance maturity or fire
-- sabbath — the maturity→verified transition is driven by apply_gate_decision
-- (11-trust) and sabbath fires from the on_maturity_verified trigger.
-- all_passed=false drops maturity back to planned + status=failed so the
-- steward retry path re-executes.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_verify_result(
    p_work_item_id uuid,
    p_result       jsonb,
    p_work_id      bigint DEFAULT NULL
) RETURNS boolean
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_all_passed  boolean;
    v_results     jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'apply_verify_result: work_item % not found', p_work_item_id;
    END IF;

    v_all_passed := coalesce((p_result->>'all_passed')::boolean, false);
    v_results    := coalesce(p_result->'results', '[]'::jsonb);

    INSERT INTO stewards.verify_results
        (work_item_id, all_passed, results, work_id, raw_response)
    VALUES
        (p_work_item_id, v_all_passed, v_results, p_work_id, p_result);

    IF NOT v_all_passed THEN
        UPDATE stewards.work_items
           SET maturity               = 'planned',
               status                 = 'failed',
               last_failure_reason    = 'verify failed: see verify_results',
               last_failure_diagnosis = 'verify_failed',
               updated_at             = now()
         WHERE id = p_work_item_id;
    END IF;

    RETURN v_all_passed;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_verify_result(uuid, jsonb, bigint) IS
'Write verify result to verify_results. all_passed=true is a no-op on maturity (the gate advance drives verified, the trigger fires sabbath); all_passed=false → maturity=planned + status=failed (steward retry re-executes).';

-- ---------------------------------------------------------------------
-- work_item_advance — final form with the forward-only maturity hook.
--
-- Redefines the base work_item_advance from 04-work-items: on each stage
-- completion, look up pipeline_stage_maturity for the completing stage and,
-- if the produced rung is forward of current in the pipeline's
-- maturity_ladder, raise work_items.maturity. Forward-only (D-H6.1):
-- re-running an earlier stage never downgrades the high-water mark.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.work_item_advance(
    p_work_item_id uuid,
    p_stage_output jsonb DEFAULT '{}'::jsonb
)
RETURNS text
LANGUAGE plpgsql
AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_pipeline        stewards.pipelines%ROWTYPE;
    v_stage           jsonb;
    v_next_name       text;
    v_auto_advance    boolean;
    v_results         jsonb;
    v_completing      text;
    v_new_maturity    text;
    v_current_idx     int;
    v_new_idx         int;
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

    v_next_name    := v_stage->>'next';
    v_auto_advance := COALESCE((v_stage->>'auto_advance')::bool, true);
    v_completing   := v_wi.current_stage;

    v_results := v_wi.stage_results
              || jsonb_build_object(v_completing,
                     p_stage_output
                     || jsonb_build_object('completed_at', now()));

    -- maturity advance hook (forward-only)
    SELECT produces_maturity INTO v_new_maturity
      FROM stewards.pipeline_stage_maturity
     WHERE pipeline_family = v_wi.pipeline_family
       AND stage_name      = v_completing;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;

    IF v_new_maturity IS NOT NULL AND v_pipeline.maturity_ladder IS NOT NULL THEN
        SELECT pos - 1 INTO v_current_idx
          FROM jsonb_array_elements_text(v_pipeline.maturity_ladder)
          WITH ORDINALITY AS t(rung, pos)
         WHERE rung = COALESCE(v_wi.maturity, 'raw');

        SELECT pos - 1 INTO v_new_idx
          FROM jsonb_array_elements_text(v_pipeline.maturity_ladder)
          WITH ORDINALITY AS t(rung, pos)
         WHERE rung = v_new_maturity;

        IF v_current_idx IS NOT NULL
           AND v_new_idx IS NOT NULL
           AND v_new_idx > v_current_idx
        THEN
            NULL;  -- carry v_new_maturity through to the UPDATE below
        ELSE
            v_new_maturity := NULL;  -- do not change maturity
        END IF;
    END IF;

    IF v_next_name IS NULL OR v_next_name = '' THEN
        UPDATE stewards.work_items
           SET stage_results = v_results,
               status        = 'completed',
               completed_at  = now(),
               maturity      = COALESCE(v_new_maturity, maturity),
               updated_at    = now()
         WHERE id = p_work_item_id;
        RETURN NULL;
    END IF;

    IF stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_next_name) IS NULL THEN
        RAISE EXCEPTION
            'work_item %: stage %s `next` references missing stage %',
            p_work_item_id, v_completing, v_next_name;
    END IF;

    UPDATE stewards.work_items
       SET stage_results = v_results,
           current_stage = v_next_name,
           status        = CASE WHEN v_auto_advance THEN 'pending'
                                ELSE 'awaiting_review' END,
           maturity      = COALESCE(v_new_maturity, maturity),
           updated_at    = now()
     WHERE id = p_work_item_id;

    RETURN v_next_name;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_advance(uuid, jsonb) IS
'H.1.6.1: on each stage completion, look up pipeline_stage_maturity for the completing stage. If produces_maturity is set AND the new rung is forward of current in the pipeline''s maturity_ladder, raise work_items.maturity. Forward-only per D-H6.1 (re-running earlier stages does not downgrade the high-water mark).';

-- ---------------------------------------------------------------------
-- review-prefix verify gate (l28) — BEFORE UPDATE OF maturity.
-- Vetoes a maturity→verified transition on a review-style stage unless the
-- stage output begins with the explicit "REVIEW: passes|revised" verdict.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.review_output_passes_gate(p_output_text text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_output_text IS NOT NULL
       AND p_output_text ~* '^\s*REVIEW:\s*(passes|revised)';
$$;

COMMENT ON FUNCTION stewards.review_output_passes_gate(text) IS
'Returns true if the review-stage output text starts with the explicit verdict prefix REVIEW: passes or REVIEW: revised. Anything else (including the bacteriopolis "where''s the draft" message) fails the gate.';

CREATE OR REPLACE FUNCTION stewards.trigger_review_prefix_verify_gate()
RETURNS trigger LANGUAGE plpgsql AS $FN$
DECLARE
    v_review_stages constant text[] := ARRAY['review','review_plan','revise','validate'];
    v_completing    text;
    v_stage_output  text;
    v_passes        boolean;
BEGIN
    IF NEW.maturity IS DISTINCT FROM OLD.maturity AND NEW.maturity = 'verified' THEN
        v_completing := COALESCE(NEW.current_stage, OLD.current_stage);

        IF v_completing IS NULL OR NOT (v_completing = ANY(v_review_stages)) THEN
            RETURN NEW;
        END IF;

        v_stage_output := NEW.stage_results -> v_completing ->> 'output';
        v_passes := stewards.review_output_passes_gate(v_stage_output);

        IF NOT v_passes THEN
            RAISE NOTICE 'review verify gate FAILED: work_item=% stage=% output_head=%',
                NEW.id, v_completing,
                substring(COALESCE(v_stage_output, '(null)') FROM 1 FOR 80);

            NEW.maturity         := OLD.maturity;
            NEW.quarantine_reason := COALESCE(
                NEW.quarantine_reason,
                'verify gate (L.1.1.14): review-stage output did not start with REVIEW: passes or REVIEW: revised. ' ||
                'Output head: ' || substring(COALESCE(v_stage_output, '(null)') FROM 1 FOR 200)
            );
        END IF;
    END IF;

    RETURN NEW;
END;
$FN$;

DROP TRIGGER IF EXISTS work_items_review_verify_gate ON stewards.work_items;
CREATE TRIGGER work_items_review_verify_gate
BEFORE UPDATE OF maturity ON stewards.work_items
FOR EACH ROW
EXECUTE FUNCTION stewards.trigger_review_prefix_verify_gate();

COMMENT ON FUNCTION stewards.trigger_review_prefix_verify_gate() IS
'L.1.1.14: BEFORE UPDATE trigger. When maturity is being set to verified on a review-style stage (review, review_plan, revise, validate), the stage_results[stage].output must start with REVIEW: passes or REVIEW: revised. Otherwise maturity stays at OLD value and quarantine_reason captures why.';

-- ---------------------------------------------------------------------
-- extract_work_item_file_content (h1-6-6 final) — pulls the publishable
-- body from the pipeline's file_content_jsonpath or, by convention, the
-- final stage's output. Strips the substrate REVIEW: verdict prefix when
-- it came through the convention path.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.extract_work_item_file_content(p_work_item_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_pipeline    stewards.pipelines%ROWTYPE;
    v_path        text;
    v_content     text;
    v_final_stage text;
    v_used_convention boolean := false;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN RETURN NULL; END IF;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;
    IF v_pipeline.family IS NULL THEN RETURN NULL; END IF;

    IF v_pipeline.file_content_jsonpath IS NOT NULL THEN
        v_path := v_pipeline.file_content_jsonpath;
    ELSE
        SELECT s->>'name' INTO v_final_stage
          FROM jsonb_array_elements(v_pipeline.stages) s
         WHERE s->>'next' IS NULL OR s->'next' = 'null'::jsonb
         LIMIT 1;
        IF v_final_stage IS NULL THEN RETURN NULL; END IF;
        v_path := format('stage_results.%s.output', v_final_stage);
        v_used_convention := true;
    END IF;

    DECLARE
        v_parts text[];
        v_traversed jsonb := to_jsonb(v_wi);
    BEGIN
        v_parts := string_to_array(v_path, '.');
        FOR i IN 1..array_length(v_parts, 1) LOOP
            IF v_traversed IS NULL THEN RETURN NULL; END IF;
            v_traversed := v_traversed -> v_parts[i];
        END LOOP;
        IF v_traversed IS NULL THEN RETURN NULL; END IF;
        IF jsonb_typeof(v_traversed) = 'string' THEN
            v_content := v_traversed #>> '{}';
        ELSE
            v_content := v_traversed::text;
        END IF;
    END;

    IF v_used_convention THEN
        v_content := regexp_replace(v_content, E'^REVIEW:\\s+\\w+\\s*\\n+', '');
    END IF;

    RETURN v_content;
END;
$func$;

COMMENT ON FUNCTION stewards.extract_work_item_file_content(uuid) IS
'H.1.6.6: when content comes through the convention path (stage_results.<final>.output, no explicit file_content_jsonpath) and the first line matches the substrate REVIEW verdict pattern, strip that line + following blank line(s). Pipelines that explicitly set file_content_jsonpath own their own conventions and are not affected.';

-- ---------------------------------------------------------------------
-- render_file_destination (h3-followup-2) — render the pipeline's
-- file_destination_template against a work_item. Used by on_maturity_verified
-- to auto-render SQL-bypass work_items whose file_destination was never set.
--
-- Reads pipeline.file_destination_template (born in 10-sabbath). Only ever
-- CALLED from on_maturity_verified (also gated to verified), so it never runs
-- before the bundle finishes installing.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.render_file_destination(p_work_item_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $func$
DECLARE
    v_wi       stewards.work_items%ROWTYPE;
    v_pipeline stewards.pipelines%ROWTYPE;
    v_tmpl     text;
    v_out      text;
    v_project  text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = v_wi.pipeline_family;
    IF v_pipeline.family IS NULL OR v_pipeline.file_destination_template IS NULL THEN
        RETURN NULL;
    END IF;

    v_tmpl    := v_pipeline.file_destination_template;
    v_project := COALESCE(NULLIF(v_wi.project_association, ''), 'misc');

    v_out := v_tmpl;
    v_out := replace(v_out, '<slug>',    COALESCE(v_wi.slug, ''));
    v_out := replace(v_out, '<project>', v_project);
    v_out := replace(v_out, '<id>',      substring(v_wi.id::text FROM 1 FOR 8));

    RETURN v_out;
END;
$func$;

COMMENT ON FUNCTION stewards.render_file_destination(uuid) IS
'H.3 followup: render the pipeline''s file_destination_template against a work_item''s slug/project/id. Returns NULL if no template. Used by on_maturity_verified to auto-render SQL-bypass work_items whose file_destination was never set by the UI.';

-- ---------------------------------------------------------------------
-- on_maturity_verified (j7 final) — AFTER UPDATE OF maturity producer.
-- Single final form. On transition TO verified, in order:
--   1. sabbath_dispatch (if enabled + not done)        [10-sabbath]
--   2. agent-proposal apply (agent-proposal family)    [apply_agent_proposal, 13]
--   3. decompose-fanout spawn (decompose-fanout family) [spawn_children, 14]
--   4. auto-render + auto-materialize the file          [render_file_destination 08 / enqueue_work_item_file 10]
--   5. planning proposed-work enqueue (planning family) [enqueue_proposed_work_items, 13]
--   6. aggregator dispatch when a fanout child verifies  [check_and_dispatch_fanout_aggregator, 14]
-- Every cross-subsystem call is wrapped in BEGIN/EXCEPTION → NOTICE so the
-- parent transaction always succeeds. Callees born in 10/13/14 are forward
-- refs — plpgsql function calls are late-bound and the bundle installs
-- atomically, so all callees exist by the time the trigger ever fires.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.on_maturity_verified()
RETURNS trigger
LANGUAGE plpgsql
AS $func$
DECLARE
    v_pipeline      stewards.pipelines%ROWTYPE;
    v_sabbath       boolean;
    v_auto_mat      boolean;
    v_pwid          bigint;
    v_dispatch_id   bigint;
    v_proposed_n    int;
    v_rendered      text;
    v_agent_ok      boolean;
    v_spawn_n       int;
    v_doc_slug      text;
    v_content       text;
BEGIN
    IF NEW.maturity <> 'verified' OR OLD.maturity = 'verified' THEN
        RETURN NEW;
    END IF;

    SELECT * INTO v_pipeline FROM stewards.pipelines WHERE family = NEW.pipeline_family;
    IF v_pipeline.family IS NULL THEN
        RAISE NOTICE 'on_maturity_verified: pipeline % not found', NEW.pipeline_family;
        RETURN NEW;
    END IF;

    v_sabbath := COALESCE(NEW.sabbath_enabled, v_pipeline.sabbath_enabled);
    IF v_sabbath AND NEW.sabbath_completed_at IS NULL THEN
        BEGIN
            v_dispatch_id := stewards.sabbath_dispatch(NEW.id);
            RAISE NOTICE 'on_maturity_verified: sabbath_dispatch work_id=% for work_item=%',
                v_dispatch_id, NEW.id;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'on_maturity_verified: sabbath_dispatch failed: %', SQLERRM;
        END;
    END IF;

    -- i4: agent-proposal source_type routing. Runs BEFORE the enqueue path
    -- so apply_agent_proposal can set file_destination dynamically.
    IF NEW.pipeline_family = 'agent-proposal' AND NEW.agent_proposal_applied_at IS NULL THEN
        BEGIN
            v_agent_ok := stewards.apply_agent_proposal(NEW.id);
            IF v_agent_ok THEN
                SELECT file_destination INTO NEW.file_destination
                  FROM stewards.work_items WHERE id = NEW.id;
            ELSE
                RAISE NOTICE 'on_maturity_verified: apply_agent_proposal returned false for work_item=%; skipping file enqueue',
                    NEW.id;
                RETURN NEW;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'on_maturity_verified: apply_agent_proposal raised: %', SQLERRM;
            RETURN NEW;
        END;
    END IF;

    -- j1/j7: decompose-fanout parent reached verified → spawn children.
    IF NEW.pipeline_family = 'decompose-fanout' THEN
        BEGIN
            v_spawn_n := stewards.spawn_children(NEW.id);
            RAISE NOTICE 'on_maturity_verified: spawn_children parent=% spawned=%',
                NEW.id, v_spawn_n;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'on_maturity_verified: spawn_children failed: %', SQLERRM;
            -- A fan-out parent that completes with 0 children LOOKS fine in every
            -- list view (the lying-completed shape, 3rd sighting 2026-07-04).
            -- Leave a visible trace on the row even though completion proceeds.
            UPDATE stewards.work_items
               SET last_failure_reason = 'spawn_children failed (completed WITHOUT fan-out): ' || SQLERRM
             WHERE id = NEW.id;
        END;
    END IF;

    v_auto_mat := COALESCE(NEW.auto_materialize_enabled, v_pipeline.auto_materialize_on_verified);
    IF v_auto_mat AND NEW.file_enqueued_at IS NULL THEN
        IF NEW.file_destination IS NULL AND v_pipeline.file_destination_template IS NOT NULL THEN
            BEGIN
                v_rendered := stewards.render_file_destination(NEW.id);
                IF v_rendered IS NOT NULL THEN
                    UPDATE stewards.work_items
                       SET file_destination = v_rendered
                     WHERE id = NEW.id;
                    NEW.file_destination := v_rendered;
                    RAISE NOTICE 'on_maturity_verified: auto-rendered file_destination=% for work_item=%',
                        v_rendered, NEW.id;
                END IF;
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'on_maturity_verified: render_file_destination failed: %', SQLERRM;
            END;
        END IF;

        IF NEW.file_destination IS NOT NULL THEN
            BEGIN
                v_pwid := stewards.enqueue_work_item_file(NEW.id, 'auto_materialize_on_verified');
                RAISE NOTICE 'on_maturity_verified: enqueue_work_item_file pwid=% for work_item=%',
                    v_pwid, NEW.id;
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'on_maturity_verified: enqueue_work_item_file failed: %', SQLERRM;
            END;
        END IF;
    END IF;

    -- Pool-publish — DECOUPLED from file-materialize (2026-06-16, corpus treatment).
    -- Publish a verified finding to the searchable docs pool whether or not a file
    -- was written. The digest loops (book/video/news) write their own files via fs
    -- tools (auto_materialize off, no file_destination) — so the pool never
    -- compounded for them. Gate on project_association (filled by the intent->
    -- project trigger in 25-corpus) so any project-tagged verified work pools; the
    -- auto_materialize+file arm preserves the prior reflect/planning pooling.
    -- import_doc is idempotent by slug; we then tag the doc with the project.
    --
    -- pools_via_tool (2026-06-19, doc-construction): a doc-construction pipeline
    -- BUILDS its artifact with doc_* tool-call diffs and pools the CANONICAL doc
    -- itself via a publish/finalize tool (playlist_publish_draft / book_publish_draft
    -- / doc_finalize). Its final-stage output is a short JOURNAL, not the document —
    -- so auto-pooling that output here would pool a journal as if it were the digest
    -- (and the OLD one-shot digesters double-pooled a near-duplicate). When the
    -- pipeline declares metadata.pools_via_tool, skip this arm entirely; the tool
    -- already pooled the real doc (and project-tagged it). See agentic-doc-construction.md.
    IF ((v_auto_mat AND NEW.file_destination IS NOT NULL)
        OR NEW.project_association IS NOT NULL)
       AND NOT COALESCE((v_pipeline.metadata->>'pools_via_tool')::boolean, false) THEN
        BEGIN
            v_content := stewards.extract_work_item_file_content(NEW.id);
            IF v_content IS NULL OR length(btrim(v_content)) = 0 THEN
                RAISE NOTICE 'on_maturity_verified: no extractable content to pool for work_item=%', NEW.id;
            ELSE
                v_doc_slug := stewards.import_doc(
                    NEW.slug,
                    NEW.file_destination,
                    left(COALESCE(NEW.input->>'binding_question', NEW.slug), 200),
                    v_content,
                    jsonb_build_object('source_type', NEW.pipeline_family,
                                       'work_item_id', NEW.id::text,
                                       'intent_id', NEW.intent_id::text),
                    'doc');
                -- import_doc returns the doc id; tag by the slug we passed (=NEW.slug).
                IF v_doc_slug IS NOT NULL AND NEW.project_association IS NOT NULL THEN
                    UPDATE stewards.docs SET project_association = NEW.project_association
                     WHERE slug = NEW.slug;
                END IF;
                RAISE NOTICE 'on_maturity_verified: published doc % to pool (project=%) for work_item=%',
                    v_doc_slug, NEW.project_association, NEW.id;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'on_maturity_verified: import_doc to pool failed: %', SQLERRM;
        END;
    END IF;

    IF NEW.pipeline_family = 'planning' THEN
        BEGIN
            v_proposed_n := stewards.enqueue_proposed_work_items(NEW.id);
            RAISE NOTICE 'on_maturity_verified: enqueue_proposed_work_items inserted=% for work_item=%',
                v_proposed_n, NEW.id;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'on_maturity_verified: enqueue_proposed_work_items failed: %', SQLERRM;
        END;
    END IF;

    -- j7: child of a fan-out verified → check siblings; dispatch aggregator
    -- if all terminal. (Failed siblings fire via on_child_status_terminal in 14.)
    IF NEW.parent_work_item_id IS NOT NULL
       AND NEW.pipeline_family <> 'aggregate-children' THEN
        BEGIN
            PERFORM stewards.check_and_dispatch_fanout_aggregator(NEW.parent_work_item_id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'on_maturity_verified: aggregator-dispatch-check failed: %', SQLERRM;
        END;
    END IF;

    RETURN NEW;
END;
$func$;

COMMENT ON FUNCTION stewards.on_maturity_verified() IS
'j7 final (single form): AFTER UPDATE trigger fn. On maturity→verified, in order: sabbath_dispatch (10), agent-proposal apply (13), decompose-fanout spawn (14), auto-render+enqueue the work_item file (08/10), planning proposed-work enqueue (13), and aggregator dispatch when a fanout child verifies (14). All cross-subsystem calls wrapped → NOTICE; forward refs to 10/13/14 are late-bound.';

DROP TRIGGER IF EXISTS work_items_on_maturity_verified ON stewards.work_items;
CREATE TRIGGER work_items_on_maturity_verified
    AFTER UPDATE OF maturity ON stewards.work_items
    FOR EACH ROW
    EXECUTE FUNCTION stewards.on_maturity_verified();

-- =====================================================================
-- Done. 08-gates: maturity ladder + gate evaluation + scenarios/verify +
-- the review-prefix BEFORE gate + the maturity→verified AFTER producer.
-- apply_gate_decision is authored in 11-trust (needs trust_scores).
-- =====================================================================
-- ===== [was 09-intents-covenants.sql] =====
-- =====================================================================
-- 09-intents-covenants.sql — intents + covenants as first-class state,
--   prompt composition, and the covenant_check gate.
--
-- Consolidated (authoring leg, 2026-06-13) from the historical chain:
--   5d   — intents + covenants tables, work_items.intent_id FK
--   5d2  — seed_intents_from_yaml / seed_covenant_from_yaml
--   5d3  — compose_system_prompt (covenant + intent injection)  [SUPERSEDED]
--   5d4  — backfill intent + NOT NULL + work_item_create(intent-aware)
--   5d5  — covenant_check template  (the evaluate/scenarios/verify
--          tools_disabled forms were folded into 08-gates)
--   pr1  — covenants.extensions catch-all + presiding render + Watch echo
--          (the FINAL compose_system_prompt + seed_covenant_from_yaml)
--
-- Renames applied (per the authoring-blueprint rename table):
--   intents.scripture_anchor → intents.values_anchor (generic substrate;
--     an intent's anchor is its governing values, not scripture-specific).
--   hardcoded 'scripture-study' default intent slug → stewards.config key
--     default_intent_slug (00-config ships it = "default"). work_item_create
--     and the backfill read config; no scripture-study string survives here.
--
-- compose_system_prompt is born in src/schema.rs in a base form (agent +
-- instructions + skills, no covenant/intent — it cannot reference these
-- tables before they exist). This file CREATE OR REPLACEs it to the final
-- pr1 form once intents/covenants are present.
-- =====================================================================

-- ---------------------------------------------------------------------
-- stewards.intents — the "why" behind a work_item (YAML-canonical mirror)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.intents (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                text UNIQUE NOT NULL,
    purpose             text NOT NULL,
    beneficiary         text,
    values_hierarchy    jsonb NOT NULL DEFAULT '[]'::jsonb,
    non_goals           text[] DEFAULT ARRAY[]::text[],
    values_anchor       text,
    source_file         text,
    source_yaml_sha     text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.intents IS
'The why behind a work_item. YAML canonical (D-C1); substrate is the runtime mirror.';
COMMENT ON COLUMN stewards.intents.values_hierarchy IS
'Ordered list of trade-off priorities, [{key, description, source}], preserving order from the intent YAML values: map.';
COMMENT ON COLUMN stewards.intents.values_anchor IS
'The governing anchor for this intent (was scripture_anchor — generalized for the OSS substrate). A short text the dispatched agent keeps in view.';
COMMENT ON COLUMN stewards.intents.source_file IS
'Relative path to the YAML this intent was seeded from. NULL for substrate-native intents created via the API.';
COMMENT ON COLUMN stewards.intents.source_yaml_sha IS
'sha256 hex of the YAML at last seed. Skip re-seeding if unchanged.';

-- ---------------------------------------------------------------------
-- stewards.covenants — bilateral commitments (born with the PR.1
-- extensions catch-all so future sections never silently drop)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.covenants (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope               text NOT NULL,
    human_commits_to    jsonb NOT NULL,
    agent_commits_to    jsonb NOT NULL,
    when_broken         text,
    recovery            text,
    council_moment      text,
    teaching_extension  jsonb,
    extensions          jsonb NOT NULL DEFAULT '{}'::jsonb,
    activated_at        timestamptz NOT NULL DEFAULT now(),
    deactivated_at      timestamptz,
    ratified_by         text NOT NULL,
    source_file         text,
    source_yaml_sha     text,
    created_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.covenants IS
'Bilateral commitments. Typically one active row scoped global. YAML canonical (D-C2). The extensions jsonb is the PR.1 anti-silent-drop catch-all for covenant sections beyond the fixed columns (e.g. presiding).';
COMMENT ON COLUMN stewards.covenants.scope IS
'global | pipeline:<family> | work_item:<id>. Most-specific active row wins at compose_system_prompt time.';
COMMENT ON COLUMN stewards.covenants.extensions IS
'PR.1: generic catch-all for covenant sections beyond the fixed columns. Keyed by top-level YAML section name; populated by parse_yaml_covenant''s unknown-section pass-through.';

DO $idx$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes WHERE indexname = 'covenants_active_scope'
    ) THEN
        CREATE UNIQUE INDEX covenants_active_scope
            ON stewards.covenants (scope) WHERE deactivated_at IS NULL;
    END IF;
END;
$idx$;

-- ---------------------------------------------------------------------
-- work_items.intent_id FK (+ NOT NULL once intents exist)
-- ---------------------------------------------------------------------

ALTER TABLE stewards.work_items
    ADD COLUMN IF NOT EXISTS intent_id uuid REFERENCES stewards.intents(id);

CREATE INDEX IF NOT EXISTS work_items_intent_id ON stewards.work_items (intent_id);

-- Virgin install: work_items is empty, so the constraint adds cleanly.
-- Every new work_item gets an intent (work_item_create defaults via config).
ALTER TABLE stewards.work_items ALTER COLUMN intent_id SET NOT NULL;

COMMENT ON COLUMN stewards.work_items.intent_id IS
'NOT NULL — every work_item must have an explicit intent (D-C3). work_item_create defaults to the config default_intent_slug intent when none is supplied.';

-- ---------------------------------------------------------------------
-- seed_intents_from_yaml — parse intent YAML + upsert by slug
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.seed_intents_from_yaml(p_yaml text)
RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_parsed jsonb;
    v_sha    text;
    v_slug   text;
    v_existing_sha text;
    v_id     uuid;
BEGIN
    IF p_yaml IS NULL OR length(trim(p_yaml)) = 0 THEN
        RAISE EXCEPTION 'seed_intents_from_yaml: empty yaml';
    END IF;

    v_parsed := stewards.parse_yaml_intent(p_yaml)::jsonb;
    v_sha    := stewards.yaml_sha256(p_yaml);

    IF v_parsed ? 'error' THEN
        RAISE EXCEPTION 'seed_intents_from_yaml: %', v_parsed->>'error';
    END IF;

    v_slug := v_parsed->>'slug';
    IF v_slug IS NULL OR length(v_slug) = 0 THEN
        RAISE EXCEPTION 'seed_intents_from_yaml: parsed intent has no slug';
    END IF;

    SELECT source_yaml_sha, id INTO v_existing_sha, v_id
      FROM stewards.intents WHERE slug = v_slug;
    IF v_existing_sha IS NOT NULL AND v_existing_sha = v_sha THEN
        RETURN v_id;
    END IF;

    INSERT INTO stewards.intents (
        slug, purpose, beneficiary, values_hierarchy, non_goals,
        values_anchor, source_file, source_yaml_sha, updated_at
    ) VALUES (
        v_slug,
        v_parsed->>'purpose',
        v_parsed->>'beneficiary',
        coalesce(v_parsed->'values_hierarchy', '[]'::jsonb),
        coalesce(
            ARRAY(SELECT jsonb_array_elements_text(v_parsed->'non_goals')),
            ARRAY[]::text[]
        ),
        v_parsed->>'values_anchor',
        'intent.yaml',
        v_sha,
        now()
    )
    ON CONFLICT (slug) DO UPDATE SET
        purpose          = EXCLUDED.purpose,
        beneficiary      = EXCLUDED.beneficiary,
        values_hierarchy = EXCLUDED.values_hierarchy,
        non_goals        = EXCLUDED.non_goals,
        values_anchor    = EXCLUDED.values_anchor,
        source_yaml_sha  = EXCLUDED.source_yaml_sha,
        updated_at       = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

COMMENT ON FUNCTION stewards.seed_intents_from_yaml(text) IS
'Parse the intent YAML and upsert into stewards.intents by slug. Returns the intent id. No-op if YAML sha matches existing row.';

-- ---------------------------------------------------------------------
-- seed_covenant_from_yaml (PR.1 final — carries extensions through)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.seed_covenant_from_yaml(p_yaml text)
RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_parsed       jsonb;
    v_sha          text;
    v_scope        text;
    v_existing_sha text;
    v_existing_id  uuid;
    v_new_id       uuid;
BEGIN
    IF p_yaml IS NULL OR length(trim(p_yaml)) = 0 THEN
        RAISE EXCEPTION 'seed_covenant_from_yaml: empty yaml';
    END IF;

    v_parsed := stewards.parse_yaml_covenant(p_yaml)::jsonb;
    v_sha    := stewards.yaml_sha256(p_yaml);

    IF v_parsed ? 'error' THEN
        RAISE EXCEPTION 'seed_covenant_from_yaml: %', v_parsed->>'error';
    END IF;

    v_scope := coalesce(v_parsed->>'scope', 'global');

    SELECT source_yaml_sha, id INTO v_existing_sha, v_existing_id
      FROM stewards.covenants
     WHERE scope = v_scope AND deactivated_at IS NULL;
    IF v_existing_sha IS NOT NULL AND v_existing_sha = v_sha THEN
        RETURN v_existing_id;
    END IF;

    IF v_existing_id IS NOT NULL THEN
        UPDATE stewards.covenants
           SET deactivated_at = now()
         WHERE id = v_existing_id;
    END IF;

    INSERT INTO stewards.covenants (
        scope, human_commits_to, agent_commits_to,
        when_broken, recovery, council_moment,
        teaching_extension, extensions, ratified_by,
        source_file, source_yaml_sha
    ) VALUES (
        v_scope,
        coalesce(v_parsed->'human_commits_to', '[]'::jsonb),
        coalesce(v_parsed->'agent_commits_to', '[]'::jsonb),
        v_parsed->>'when_broken',
        v_parsed->>'recovery',
        v_parsed->>'council_moment',
        v_parsed->'teaching_extension',
        coalesce(v_parsed->'extensions', '{}'::jsonb),
        coalesce(v_parsed->>'ratified_by', 'both'),
        '.spec/covenant.yaml',
        v_sha
    ) RETURNING id INTO v_new_id;

    RETURN v_new_id;
END;
$func$;

COMMENT ON FUNCTION stewards.seed_covenant_from_yaml(text) IS
'Phase 5d (C.2) + PR.1: parse the covenant YAML and insert as the new active row. Unknown top-level sections land in extensions (jsonb) instead of being dropped. No-op if YAML sha matches existing active row.';

-- ---------------------------------------------------------------------
-- compose_system_prompt (PR.1 final) — covenant block (with presiding) +
-- intent block + agent + instructions + skills + The Watch echo.
-- Renames scripture_anchor → values_anchor in the intent block.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.compose_system_prompt(
    p_agent_family text, p_model text, p_session_id text
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_agent          stewards.agents;
    v_prompt         text := '';
    v_instructions   text;
    v_skills_block   text;
    v_covenant       stewards.covenants;
    v_intent         stewards.intents;
    v_covenant_block text := '';
    v_intent_block   text := '';
    v_human_str      text;
    v_agent_str      text;
    v_values_str     text;
    v_non_goals_str  text;
    v_presiding          jsonb;
    v_presiding_str      text;
    v_presiding_cncl_str text;
    v_echo_keys          text;
BEGIN
    v_agent := stewards.resolve_agent(p_agent_family, p_model);
    IF v_agent.family IS NULL THEN
        RAISE EXCEPTION
            'no agent variant resolved: family=% model=%',
            p_agent_family, p_model;
    END IF;

    -- Active covenant block (always-on for global scope).
    SELECT * INTO v_covenant
      FROM stewards.covenants
     WHERE scope = 'global' AND deactivated_at IS NULL
     ORDER BY activated_at DESC
     LIMIT 1;

    IF v_covenant.id IS NOT NULL THEN
        SELECT string_agg('  - ' || (c->>'key') || ': ' || (c->>'description'), E'\n')
          INTO v_human_str
          FROM jsonb_array_elements(v_covenant.human_commits_to) c;

        SELECT string_agg('  - ' || (c->>'key') || ': ' || (c->>'description'), E'\n')
          INTO v_agent_str
          FROM jsonb_array_elements(v_covenant.agent_commits_to) c;

        v_covenant_block :=
            E'=== Active Covenant ===\n' ||
            E'The human commits to:\n' || coalesce(v_human_str, '  (none)') || E'\n\n' ||
            E'The agent (you) commits to:\n' || coalesce(v_agent_str, '  (none)');

        IF v_covenant.council_moment IS NOT NULL AND length(v_covenant.council_moment) > 0 THEN
            v_covenant_block := v_covenant_block || E'\n\nCouncil moment:\n  ' || v_covenant.council_moment;
        END IF;

        -- PR.1: presiding extension — the chain-of-watches delegation terms.
        v_presiding := v_covenant.extensions -> 'presiding';
        IF v_presiding IS NOT NULL THEN
            SELECT string_agg(
                     '  - ' || e.key || ': ' || trim(e.value->>'description') ||
                     CASE WHEN e.value ? 'emergency'
                          THEN E'\n    Emergency: ' || trim(e.value->>'emergency')
                          ELSE '' END,
                     E'\n' ORDER BY e.key)
              INTO v_presiding_str
              FROM jsonb_each(v_presiding->'agent_commits_to') e;

            SELECT string_agg('  - ' || e.key || ': ' || trim(e.value->>'description'),
                              E'\n' ORDER BY e.key)
              INTO v_presiding_cncl_str
              FROM jsonb_each(v_presiding->'council_commits_to') e;

            IF v_presiding_str IS NOT NULL THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nWhen you delegate — subagents, dispatches, persona turns — you preside over that work, and commit to:\n' ||
                    v_presiding_str;
            END IF;
            IF v_presiding_cncl_str IS NOT NULL THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nThe council commits to:\n' || v_presiding_cncl_str;
            END IF;
            IF v_presiding ? 'when_presiding_is_broken' THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nBreach signature: ' ||
                    trim(v_presiding->'when_presiding_is_broken'->>'description');
            END IF;
        END IF;
    END IF;

    -- Intent block (only when the session resolves to a work_item with an intent).
    SELECT i.* INTO v_intent
      FROM stewards.intents i
      JOIN stewards.work_items wi ON wi.intent_id = i.id
     WHERE p_session_id = ANY(coalesce(wi.session_ids, ARRAY[]::text[]))
     LIMIT 1;

    IF v_intent.id IS NOT NULL THEN
        SELECT string_agg(
                 '  - ' || (v->>'key') ||
                 CASE WHEN v ? 'kind' AND v->>'kind' = 'constraint'
                      THEN ' [constraint, severity=' || coalesce(v->>'severity','?') || ']'
                      ELSE ''
                 END ||
                 ': ' || (v->>'description'),
                 E'\n'
               )
          INTO v_values_str
          FROM jsonb_array_elements(v_intent.values_hierarchy) v;

        v_non_goals_str := array_to_string(v_intent.non_goals, E'\n  - ', '');

        v_intent_block :=
            E'=== Intent ===\n' ||
            E'Slug: ' || v_intent.slug || E'\n' ||
            E'Purpose: ' || v_intent.purpose || E'\n';

        IF v_intent.beneficiary IS NOT NULL THEN
            v_intent_block := v_intent_block || E'Beneficiary: ' || v_intent.beneficiary || E'\n';
        END IF;

        v_intent_block := v_intent_block || E'\nValues (in order of priority):\n' ||
            coalesce(v_values_str, '  (none)');

        IF v_intent.non_goals IS NOT NULL AND array_length(v_intent.non_goals, 1) > 0 THEN
            v_intent_block := v_intent_block || E'\n\nNon-goals:\n  - ' || v_non_goals_str;
        END IF;

        IF v_intent.values_anchor IS NOT NULL THEN
            v_intent_block := v_intent_block || E'\n\nValues anchor: ' || v_intent.values_anchor;
        END IF;
    END IF;

    -- Compose: covenant + intent first, then === Agent === marker, then agent.
    IF length(v_covenant_block) > 0 THEN
        v_prompt := v_covenant_block || E'\n\n';
    END IF;
    IF length(v_intent_block) > 0 THEN
        v_prompt := v_prompt || v_intent_block || E'\n\n';
    END IF;
    IF length(v_prompt) > 0 THEN
        v_prompt := v_prompt || E'=== Agent ===\n';
    END IF;

    v_prompt := v_prompt || v_agent.prompt;

    -- Existing logic: instructions + skills.
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

    -- Skills — the 3-tier catalog (group summaries -> opened-group frontmatter ->
    -- loaded bodies). Built in 24-skills.sql; the call is late-bound (plpgsql), so
    -- the forward reference to a later chain file is safe. Returns NULL when the
    -- agent is skill-denied or nothing is visible.
    v_skills_block := stewards.render_skills_block(p_agent_family, p_model, p_session_id);
    IF v_skills_block IS NOT NULL THEN
        v_prompt := v_prompt || v_skills_block;
    END IF;

    -- Agenda — the session's goal + open todos (26-productivity). Late-bound
    -- forward ref (plpgsql) to a later chain file, like render_skills_block.
    DECLARE v_agenda text;
    BEGIN
        v_agenda := stewards.render_agenda(p_session_id);
        IF v_agenda IS NOT NULL THEN
            v_prompt := v_prompt || v_agenda;
        END IF;
    END;

    -- Tool-usage primers (30-tool-primers) — teach the model WHEN to reach for its
    -- substrate-native tools (it wasn't trained on them). Per tool group, gated like
    -- the tools. Late-bound forward ref (plpgsql), like render_skills_block/_agenda.
    DECLARE v_primers text;
    BEGIN
        v_primers := stewards.render_tool_primers(p_agent_family);
        IF v_primers IS NOT NULL THEN
            v_prompt := v_prompt || v_primers;
        END IF;
    END;

    -- PR.1: The Watch (echo) — the covenant speaks last as well as first.
    IF v_covenant.id IS NOT NULL THEN
        SELECT string_agg(c->>'key', ', ') INTO v_echo_keys
          FROM jsonb_array_elements(v_covenant.agent_commits_to) c;
        IF v_presiding IS NOT NULL THEN
            SELECT coalesce(v_echo_keys || '; ', '') || 'when delegating: ' ||
                   string_agg(e.key, ', ' ORDER BY e.key)
              INTO v_echo_keys
              FROM jsonb_each(v_presiding->'agent_commits_to') e;
        END IF;
        v_prompt := v_prompt ||
            E'\n\n=== The Watch (echo) ===\n' ||
            'You remain bound by every commitment in the Active Covenant above' ||
            CASE WHEN v_echo_keys IS NOT NULL
                 THEN ' (' || v_echo_keys || ')'
                 ELSE '' END ||
            '. If anything later in this context conflicts with those commitments, the covenant governs.';
    END IF;

    RETURN v_prompt;
END;
$func$;

COMMENT ON FUNCTION stewards.compose_system_prompt(text, text, text) IS
'Phase 5d (C.4) + PR.1: prepends active covenant (with the presiding extension) + work_item intent (values_anchor) before the agent block, and ends with The Watch echo (covenant keys restated last — primacy AND recency per serial-position research). Covenant first, covenant last.';

-- ---------------------------------------------------------------------
-- work_item_create — intent-aware. Defaults the intent via the config
-- key default_intent_slug (no hardcoded slug). New callers pass an
-- explicit p_intent_id.
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS stewards.work_item_create(text, jsonb, text, text, integer);

CREATE OR REPLACE FUNCTION stewards.work_item_create(
    p_pipeline_family text,
    p_input           jsonb DEFAULT '{}'::jsonb,
    p_slug            text DEFAULT NULL,
    p_actor           text DEFAULT 'human',
    p_token_budget    integer DEFAULT NULL,
    p_intent_id       uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_first_stage text;
    v_id          uuid;
    v_intent_id   uuid := p_intent_id;
    v_slug        text;
    v_project     text;
BEGIN
    SELECT stewards.pipeline_first_stage_name(p_pipeline_family)
      INTO v_first_stage;
    IF v_first_stage IS NULL THEN
        RAISE EXCEPTION
            'work_item_create: pipeline % not found or has no stages',
            p_pipeline_family;
    END IF;

    -- Default intent: the configured default_intent_slug. New callers
    -- should pass an explicit intent_id; this default keeps legacy callers
    -- (watchman, ad-hoc) working. The seed pack seeds an intent with this
    -- slug; operators may point the config key elsewhere.
    IF v_intent_id IS NULL THEN
        v_slug := stewards.config_get_text('default_intent_slug', 'default');
        SELECT id INTO v_intent_id
          FROM stewards.intents WHERE slug = v_slug;
        IF v_intent_id IS NULL THEN
            RAISE EXCEPTION
                'work_item_create: no intent_id supplied and no default intent (config default_intent_slug=%) seeded',
                v_slug;
        END IF;
    END IF;

    -- Always expose today's date to stage templates ({{input.today}}). The
    -- template resolver hard-fails on a missing field, and planning-family
    -- templates reference input.today — inject it so manual + scheduled launches
    -- never trip on it. (Surfaced by the reflect-steward P0 dry-run.)
    IF NOT (p_input ? 'today') THEN
        p_input := p_input || jsonb_build_object('today', to_char(current_date, 'YYYY-MM-DD'));
    END IF;

    -- Default the project (knowledge-pool tag) to the intent's slug, so docs this
    -- work produces are scopeable by project_neighborhood (22). project_association
    -- FKs to stewards.projects, so only tag when a project with that slug is
    -- REGISTERED — else leave NULL (untagged/global, the safe default; a fresh core
    -- ships no projects). Several intents can pour into one registered project by
    -- passing project_association explicitly. (Knowledge-scope design, 2026-06-15.)
    SELECT slug INTO v_project FROM stewards.intents WHERE id = v_intent_id;
    IF v_project IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stewards.projects WHERE slug = v_project) THEN
        v_project := NULL;
    END IF;

    INSERT INTO stewards.work_items
        (pipeline_family, current_stage, slug, input, actor, token_budget, intent_id, project_association)
    VALUES
        (p_pipeline_family, v_first_stage, p_slug, p_input, p_actor, p_token_budget, v_intent_id, v_project)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_create(text, jsonb, text, text, integer, uuid) IS
'Create a new work_item. Defaults the intent to the config default_intent_slug intent if p_intent_id is NULL — keeps legacy callers working post-NOT-NULL. No hardcoded slug.';

-- ---------------------------------------------------------------------
-- Backfill existing work_items to the default intent (live-DB only; a
-- virgin database has no rows and no seeded intent, so this is a no-op).
-- ---------------------------------------------------------------------

DO $backfill$
DECLARE
    v_slug              text := stewards.config_get_text('default_intent_slug', 'default');
    v_default_intent_id uuid;
    v_backfilled        int;
BEGIN
    SELECT id INTO v_default_intent_id
      FROM stewards.intents WHERE slug = v_slug;

    IF v_default_intent_id IS NULL THEN
        -- Fresh database: no intents seeded yet (seeding is a runtime op),
        -- and no work_items to backfill. Skip quietly.
        RAISE NOTICE '09 backfill: no default intent (slug=%) seeded; skipping (fresh database)', v_slug;
        RETURN;
    END IF;

    UPDATE stewards.work_items
       SET intent_id = v_default_intent_id
     WHERE intent_id IS NULL;

    GET DIAGNOSTICS v_backfilled = ROW_COUNT;
    RAISE NOTICE '09 backfill: % work_items assigned to default intent (slug=%)', v_backfilled, v_slug;
END;
$backfill$;

-- ---------------------------------------------------------------------
-- covenant_check gate template (5d5) — seeded into the born-complete
-- gate_prompts table (CHECK already includes covenant_check at 08).
-- ---------------------------------------------------------------------

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('covenant_check',
$tmpl$You are evaluating whether a piece of work honors the active covenant.

The covenant commitments are loaded into your system prompt above. Pay particular attention to the agent commitments — those are what THIS work was supposed to honor.

Pipeline: {{pipeline_family}}
Stage: {{current_stage}}
Target maturity (the rung this work is about to advance to): {{target_maturity}}

The work produced this output:
{{stage_output}}

Question: does this output honor the agent's covenant commitments? Specifically check:
- read_before_quoting: are direct quotes verifiable, or does the output paraphrase what isn't checked?
- check_existing_work: does the output engage with prior work in the corpus, or build in isolation?
- surface_tensions: does the output acknowledge counterarguments / blind spots, or only build toward a thesis?
- honor_scope: did the output stay within the requested scope, or expand into adjacent territory?
- exercise_stewardship: where the output found adjacent issues, did it act on them or only flag them?

Respond with JSON ONLY (no prose, no tool calls):
{
  "honors_covenant": true | false,
  "concerns": ["concern 1", "concern 2", ...],   // empty array if no concerns
  "recommendation": "pass" | "flag"               // flag = surface to human even if technically passes
}
$tmpl$,
     'Phase 5d (C.6, D-C4): free-form covenant check. Bgworker dispatches with tools_disabled=true.')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

-- =====================================================================
-- Done. 09-intents-covenants: intents + covenants first-class, prompt
-- composition (covenant + presiding + intent + Watch echo), config-driven
-- intent defaulting, and the covenant_check gate template.
-- =====================================================================
-- ===== [was 10-sabbath-atonement.sql] =====
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
    v_gate_model      text := 'qwen3.7-plus';
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
-- ===== [was 11-trust.sql] =====
-- =====================================================================
-- 11-trust.sql — the trust ladder + the trust-gated apply_gate_decision.
--
-- Consolidated (authoring leg, 2026-06-13) from the historical chain:
--   5f   — trust_scores / trust_transitions / gate_overrides /
--          trust_thresholds tables + threshold seeds
--   5f2  — trust_record_success/failure/override, evaluate_trust, trust_adjust
--   5f3  — work_item_stage_actor + apply_gate_decision (trust gate)
--   5f4  — retry_guidance_with_lessons
--   5f5  — apply_gate_override
--
-- apply_gate_decision lives HERE (not 08-gates): its trust check SELECTs
-- from stewards.trust_scores, and a plpgsql SELECT from a table born later
-- in the chain is not a proven-safe forward reference at CREATE. This is its
-- single, final definition — the trust gate (5f3) WITHOUT the inline
-- sabbath fire (h1-6-2 moved sabbath to the on_maturity_verified trigger in
-- 08-gates; firing it here too would double-dispatch).
--
-- Ladder (D-E1): trainee → journeyman → master, keyed by
-- (agent_family, pipeline_family, model). Trainee surfaces every advance
-- for human ratification; journeyman + master proceed automatically.
-- =====================================================================

-- ---------------------------------------------------------------------
-- trust_scores
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.trust_scores (
    agent_family            text NOT NULL,
    pipeline_family         text NOT NULL,
    model                   text NOT NULL,
    successful_completions  int NOT NULL DEFAULT 0,
    failed_completions      int NOT NULL DEFAULT 0,
    human_overrides         int NOT NULL DEFAULT 0,
    trust_level             text NOT NULL DEFAULT 'trainee'
                              CHECK (trust_level IN ('trainee', 'journeyman', 'master')),
    last_evaluated_at       timestamptz NOT NULL DEFAULT now(),
    last_completion_at      timestamptz,
    PRIMARY KEY (agent_family, pipeline_family, model)
);

COMMENT ON TABLE stewards.trust_scores IS
'Per-(agent_family, pipeline_family, model) trust state. Trainee surfaces every gate-advance for human ratification; journeyman + master proceed automatically. Demote on human override (D-E3 full weight).';

-- ---------------------------------------------------------------------
-- trust_transitions — audit ledger
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.trust_transitions (
    id                  bigserial PRIMARY KEY,
    at                  timestamptz NOT NULL DEFAULT now(),
    agent_family        text NOT NULL,
    pipeline_family     text NOT NULL,
    model               text NOT NULL,
    from_level          text NOT NULL,
    to_level            text NOT NULL,
    transition_kind     text NOT NULL CHECK (transition_kind IN ('auto', 'manual')),
    actor               text NOT NULL,
    justification       text,
    metrics             jsonb
);

CREATE INDEX IF NOT EXISTS trust_transitions_at   ON stewards.trust_transitions (at);
CREATE INDEX IF NOT EXISTS trust_transitions_cell ON stewards.trust_transitions (agent_family, pipeline_family, model);

COMMENT ON TABLE stewards.trust_transitions IS
'Every trust level change recorded with reason. Manual transitions require justification (D-E2).';

-- ---------------------------------------------------------------------
-- gate_overrides — human disagreement with a gate decision
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.gate_overrides (
    id                bigserial PRIMARY KEY,
    gate_decision_id  bigint NOT NULL REFERENCES stewards.gate_decisions(id),
    at                timestamptz NOT NULL DEFAULT now(),
    overridden_by     text NOT NULL,
    new_action        text NOT NULL CHECK (new_action IN ('advance', 'revise', 'surface')),
    justification     text NOT NULL
);

CREATE INDEX IF NOT EXISTS gate_overrides_decision ON stewards.gate_overrides (gate_decision_id);
CREATE INDEX IF NOT EXISTS gate_overrides_at       ON stewards.gate_overrides (at);

COMMENT ON TABLE stewards.gate_overrides IS
'Records when a human disagreed with a gate decision. Increments human_overrides on the relevant trust_scores row (D-E3 full weight).';

-- ---------------------------------------------------------------------
-- trust_thresholds — tunable promotion rules
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.trust_thresholds (
    transition          text PRIMARY KEY,
    required_successes  int NOT NULL,
    clean_window        int NOT NULL,
    demote_on_override  boolean NOT NULL DEFAULT true
);

INSERT INTO stewards.trust_thresholds (transition, required_successes, clean_window, demote_on_override) VALUES
    ('trainee_to_journeyman', 5, 5, true),
    ('journeyman_to_master', 15, 15, true)
ON CONFLICT (transition) DO UPDATE SET
    required_successes = EXCLUDED.required_successes,
    clean_window       = EXCLUDED.clean_window,
    demote_on_override = EXCLUDED.demote_on_override;

COMMENT ON TABLE stewards.trust_thresholds IS
'Tunable promotion rules. Default: trainee → journeyman after 5 clean successes; journeyman → master after 15 more clean. Demote one level on any override.';

-- ---------------------------------------------------------------------
-- trust_record_success / failure / override
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.trust_record_success(
    p_agent_family text, p_pipeline_family text, p_model text
) RETURNS text
LANGUAGE plpgsql AS $func$
BEGIN
    INSERT INTO stewards.trust_scores
        (agent_family, pipeline_family, model,
         successful_completions, last_completion_at)
    VALUES
        (p_agent_family, p_pipeline_family, p_model, 1, now())
    ON CONFLICT (agent_family, pipeline_family, model) DO UPDATE SET
        successful_completions = stewards.trust_scores.successful_completions + 1,
        last_completion_at     = now();

    RETURN stewards.evaluate_trust(p_agent_family, p_pipeline_family, p_model);
END;
$func$;

COMMENT ON FUNCTION stewards.trust_record_success(text, text, text) IS
'Phase 5f (E.2): increment successful_completions and re-evaluate. Called when a work_item reaches verified maturity.';

CREATE OR REPLACE FUNCTION stewards.trust_record_failure(
    p_agent_family text, p_pipeline_family text, p_model text
) RETURNS text
LANGUAGE plpgsql AS $func$
BEGIN
    INSERT INTO stewards.trust_scores
        (agent_family, pipeline_family, model, failed_completions)
    VALUES
        (p_agent_family, p_pipeline_family, p_model, 1)
    ON CONFLICT (agent_family, pipeline_family, model) DO UPDATE SET
        failed_completions = stewards.trust_scores.failed_completions + 1;

    RETURN stewards.evaluate_trust(p_agent_family, p_pipeline_family, p_model);
END;
$func$;

COMMENT ON FUNCTION stewards.trust_record_failure(text, text, text) IS
'Phase 5f (E.2): increment failed_completions on quarantine.';

CREATE OR REPLACE FUNCTION stewards.trust_record_override(
    p_agent_family text, p_pipeline_family text, p_model text
) RETURNS text
LANGUAGE plpgsql AS $func$
BEGIN
    INSERT INTO stewards.trust_scores
        (agent_family, pipeline_family, model, human_overrides)
    VALUES
        (p_agent_family, p_pipeline_family, p_model, 1)
    ON CONFLICT (agent_family, pipeline_family, model) DO UPDATE SET
        human_overrides = stewards.trust_scores.human_overrides + 1;

    RETURN stewards.evaluate_trust(p_agent_family, p_pipeline_family, p_model);
END;
$func$;

COMMENT ON FUNCTION stewards.trust_record_override(text, text, text) IS
'Phase 5f (E.2): increment human_overrides and re-evaluate. evaluate_trust auto-demotes on any override per D-E3.';

-- ---------------------------------------------------------------------
-- evaluate_trust — promotion / demotion against thresholds
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.evaluate_trust(
    p_agent_family text, p_pipeline_family text, p_model text
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_score        stewards.trust_scores%ROWTYPE;
    v_new_level    text;
    v_t2j_required int;
    v_j2m_required int;
    v_demote       boolean;
    v_overrides_since_promo int := 0;
BEGIN
    SELECT * INTO v_score
      FROM stewards.trust_scores
     WHERE agent_family = p_agent_family
       AND pipeline_family = p_pipeline_family
       AND model = p_model
       FOR UPDATE;

    IF NOT FOUND THEN
        RETURN 'trainee';
    END IF;

    v_new_level := v_score.trust_level;

    SELECT required_successes INTO v_t2j_required
      FROM stewards.trust_thresholds WHERE transition='trainee_to_journeyman';
    SELECT required_successes INTO v_j2m_required
      FROM stewards.trust_thresholds WHERE transition='journeyman_to_master';
    SELECT demote_on_override INTO v_demote
      FROM stewards.trust_thresholds WHERE transition='trainee_to_journeyman';

    IF v_score.trust_level <> 'trainee' AND v_demote THEN
        SELECT coalesce((metrics->>'overrides')::int, 0)
          INTO v_overrides_since_promo
          FROM stewards.trust_transitions
         WHERE agent_family = p_agent_family
           AND pipeline_family = p_pipeline_family
           AND model = p_model
           AND to_level = v_score.trust_level
         ORDER BY at DESC LIMIT 1;

        v_overrides_since_promo := coalesce(v_overrides_since_promo, 0);

        IF v_score.human_overrides > v_overrides_since_promo THEN
            v_new_level := CASE v_score.trust_level
                WHEN 'master'     THEN 'journeyman'
                WHEN 'journeyman' THEN 'trainee'
                ELSE v_score.trust_level
            END;
        END IF;
    END IF;

    IF v_new_level = v_score.trust_level THEN
        IF v_score.trust_level = 'trainee'
           AND v_score.successful_completions >= v_t2j_required
           AND v_score.human_overrides = 0 THEN
            v_new_level := 'journeyman';
        ELSIF v_score.trust_level = 'journeyman'
           AND v_score.successful_completions >= (v_t2j_required + v_j2m_required)
           AND v_score.human_overrides = coalesce(v_overrides_since_promo, 0) THEN
            v_new_level := 'master';
        END IF;
    END IF;

    IF v_new_level <> v_score.trust_level THEN
        UPDATE stewards.trust_scores
           SET trust_level = v_new_level, last_evaluated_at = now()
         WHERE agent_family = p_agent_family
           AND pipeline_family = p_pipeline_family
           AND model = p_model;

        INSERT INTO stewards.trust_transitions
            (agent_family, pipeline_family, model, from_level, to_level,
             transition_kind, actor, metrics)
        VALUES
            (p_agent_family, p_pipeline_family, p_model,
             v_score.trust_level, v_new_level, 'auto', 'system',
             jsonb_build_object(
                 'successful', v_score.successful_completions,
                 'failed',     v_score.failed_completions,
                 'overrides',  v_score.human_overrides
             ));
    ELSE
        UPDATE stewards.trust_scores
           SET last_evaluated_at = now()
         WHERE agent_family = p_agent_family
           AND pipeline_family = p_pipeline_family
           AND model = p_model;
    END IF;

    RETURN v_new_level;
END;
$func$;

COMMENT ON FUNCTION stewards.evaluate_trust(text, text, text) IS
'Phase 5f (E.2): apply promotion/demotion rules from trust_thresholds. Called by record_* helpers and invokable manually. Returns the new (or unchanged) trust level.';

-- ---------------------------------------------------------------------
-- trust_adjust — manual level change (D-E2 requires justification)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.trust_adjust(
    p_agent_family    text,
    p_pipeline_family text,
    p_model           text,
    p_new_level       text,
    p_actor           text,
    p_justification   text
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_score stewards.trust_scores%ROWTYPE;
BEGIN
    IF p_new_level NOT IN ('trainee','journeyman','master') THEN
        RAISE EXCEPTION 'trust_adjust: invalid level %', p_new_level;
    END IF;
    IF p_justification IS NULL OR length(trim(p_justification)) < 10 THEN
        RAISE EXCEPTION 'trust_adjust: justification required (>= 10 chars) per D-E2';
    END IF;

    SELECT * INTO v_score
      FROM stewards.trust_scores
     WHERE agent_family = p_agent_family
       AND pipeline_family = p_pipeline_family
       AND model = p_model
       FOR UPDATE;

    IF NOT FOUND THEN
        INSERT INTO stewards.trust_scores
            (agent_family, pipeline_family, model, trust_level)
        VALUES
            (p_agent_family, p_pipeline_family, p_model, p_new_level);

        INSERT INTO stewards.trust_transitions
            (agent_family, pipeline_family, model, from_level, to_level,
             transition_kind, actor, justification, metrics)
        VALUES
            (p_agent_family, p_pipeline_family, p_model,
             'trainee', p_new_level, 'manual', p_actor, p_justification,
             jsonb_build_object('successful', 0, 'failed', 0, 'overrides', 0));

        RETURN p_new_level;
    END IF;

    IF v_score.trust_level = p_new_level THEN
        RETURN p_new_level;
    END IF;

    UPDATE stewards.trust_scores
       SET trust_level = p_new_level, last_evaluated_at = now()
     WHERE agent_family = p_agent_family
       AND pipeline_family = p_pipeline_family
       AND model = p_model;

    INSERT INTO stewards.trust_transitions
        (agent_family, pipeline_family, model, from_level, to_level,
         transition_kind, actor, justification, metrics)
    VALUES
        (p_agent_family, p_pipeline_family, p_model,
         v_score.trust_level, p_new_level, 'manual', p_actor, p_justification,
         jsonb_build_object(
             'successful', v_score.successful_completions,
             'failed',     v_score.failed_completions,
             'overrides',  v_score.human_overrides
         ));

    RETURN p_new_level;
END;
$func$;

COMMENT ON FUNCTION stewards.trust_adjust(text, text, text, text, text, text) IS
'Phase 5f (E.2): manual trust level change with required justification (D-E2). Creates the trust_scores row if missing. Logs to trust_transitions with kind=manual.';

-- ---------------------------------------------------------------------
-- work_item_stage_actor — (agent_family, pipeline_family, model) for the
-- work_item's current stage, honoring model_override. Used by the trust
-- gate + apply_gate_override. Defined BEFORE apply_gate_decision.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.work_item_stage_actor(
    p_work_item_id uuid
) RETURNS jsonb
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_wi    stewards.work_items%ROWTYPE;
    v_stage jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RETURN NULL;
    END IF;
    v_stage := stewards.pipeline_stage_lookup(v_wi.pipeline_family, v_wi.current_stage);
    IF v_stage IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN jsonb_build_object(
        'agent_family',    v_stage->>'agent_family',
        'pipeline_family', v_wi.pipeline_family,
        'model',           coalesce(v_wi.model_override, v_stage->>'model')
    );
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_stage_actor(uuid) IS
'Phase 5f (E.3): returns {agent_family, pipeline_family, model} for the work_item''s current stage. model honors work_items.model_override. Used by the trust gate + trust counter increment.';

-- ---------------------------------------------------------------------
-- apply_gate_decision — FINAL form: trust gate, no inline sabbath.
-- On action=advance: a trainee (or no trust row) surfaces for human
-- ratification; journeyman/master proceed. On a real advance to verified,
-- records the trust success. The maturity UPDATE to 'verified' fires the
-- on_maturity_verified trigger (08-gates), which dispatches sabbath +
-- materialize — so this function does NOT fire sabbath itself.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_gate_decision(
    p_work_item_id uuid,
    p_decision     jsonb,
    p_work_id      bigint DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_action         text;
    v_reasoning      text;
    v_feedback       text;
    v_new_maturity   text;
    v_produces_mat   text;
    v_maturity_order text[] := ARRAY['raw','researched','planned','specced','executing','verified'];
    v_idx            int;
    v_new_revision   int;
    v_actor          jsonb;
    v_trust_level    text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'work_item % not found', p_work_item_id;
    END IF;

    v_action    := p_decision->>'action';
    v_reasoning := p_decision->>'reasoning';
    v_feedback  := p_decision->>'feedback';

    IF v_action NOT IN ('advance', 'revise', 'surface') THEN
        RAISE EXCEPTION 'apply_gate_decision: invalid action %', v_action;
    END IF;

    INSERT INTO stewards.gate_decisions
        (work_item_id, from_maturity, action, reasoning, feedback,
         work_id, revision_count, raw_response)
    VALUES
        (p_work_item_id, v_wi.maturity, v_action, v_reasoning, v_feedback,
         p_work_id, v_wi.revision_count, p_decision);

    v_new_maturity := v_wi.maturity;

    IF v_action = 'advance' THEN
        -- Trust check (E.3): trainee (or no row) surfaces every advance for
        -- human ratification; journeyman + master proceed.
        v_actor := stewards.work_item_stage_actor(p_work_item_id);
        IF v_actor IS NOT NULL THEN
            SELECT trust_level INTO v_trust_level
              FROM stewards.trust_scores
             WHERE agent_family    = v_actor->>'agent_family'
               AND pipeline_family = v_actor->>'pipeline_family'
               AND model           = v_actor->>'model';

            IF v_trust_level IS NULL OR v_trust_level = 'trainee' THEN
                UPDATE stewards.work_items
                   SET status = 'awaiting_review',
                       updated_at = now()
                 WHERE id = p_work_item_id;
                RETURN v_wi.maturity;  -- maturity unchanged; human must ratify
            END IF;
        END IF;

        SELECT produces_maturity INTO v_produces_mat
          FROM stewards.pipeline_stage_maturity
         WHERE pipeline_family = v_wi.pipeline_family
           AND stage_name = v_wi.current_stage;

        IF v_produces_mat IS NOT NULL THEN
            v_new_maturity := v_produces_mat;
        ELSE
            v_idx := array_position(v_maturity_order, v_wi.maturity);
            IF v_idx IS NOT NULL AND v_idx < array_length(v_maturity_order, 1) THEN
                v_new_maturity := v_maturity_order[v_idx + 1];
            END IF;
        END IF;

        UPDATE stewards.work_items
           SET maturity       = v_new_maturity,
               revision_count = 0,
               updated_at     = now()
         WHERE id = p_work_item_id;

        -- Record successful completion when reaching verified.
        IF v_new_maturity = 'verified' AND v_actor IS NOT NULL THEN
            BEGIN
                PERFORM stewards.trust_record_success(
                    v_actor->>'agent_family',
                    v_actor->>'pipeline_family',
                    v_actor->>'model'
                );
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'trust_record_success raised: %', SQLERRM;
            END;
        END IF;

        -- sabbath_dispatch is NOT fired here — the maturity→verified UPDATE
        -- above fires the work_items_on_maturity_verified trigger (08-gates),
        -- which dispatches sabbath + materialize. Single source of truth.

    ELSIF v_action = 'revise' THEN
        v_new_revision := v_wi.revision_count + 1;

        IF v_new_revision > 2 THEN
            UPDATE stewards.work_items
               SET status = 'awaiting_review',
                   revision_count = v_new_revision,
                   updated_at = now()
             WHERE id = p_work_item_id;
        ELSE
            UPDATE stewards.work_items
               SET status                 = 'failed',
                   revision_count         = v_new_revision,
                   last_failure_reason    = 'gate revise: ' || coalesce(v_feedback, '(no feedback)'),
                   last_failure_diagnosis = 'gate_revise',
                   updated_at             = now()
             WHERE id = p_work_item_id;
        END IF;

    ELSIF v_action = 'surface' THEN
        UPDATE stewards.work_items
           SET status     = 'awaiting_review',
               updated_at = now()
         WHERE id = p_work_item_id;
    END IF;

    RETURN v_new_maturity;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_gate_decision(uuid, jsonb, bigint) IS
'Phase 5a + 5f (E.3) + H.1.6.2: on action=advance, checks trust_scores for the work_item''s (agent_family, pipeline_family, model). Trainee or no-row surfaces for human ratification. On a real advance to verified, records trust success; sabbath fires from the on_maturity_verified trigger (not inline). Writes a gate_decisions audit row for every call.';

-- ---------------------------------------------------------------------
-- retry_guidance_with_lessons — base retry guidance + last 3 ratified
-- lessons for the (pipeline, stage) cell.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.retry_guidance_with_lessons(
    p_diagnosis       text,
    p_attempt         integer,
    p_pipeline_family text,
    p_stage_name      text
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_base    text;
    v_lessons text;
BEGIN
    v_base := stewards.retry_guidance(p_diagnosis, p_attempt);

    SELECT string_agg('  - ' || content, E'\n')
      INTO v_lessons
      FROM (
        SELECT content
          FROM stewards.lessons_recent_ratified
         WHERE pipeline_family = p_pipeline_family
           AND current_stage   = p_stage_name
         ORDER BY at DESC
         LIMIT 3
      ) recent;

    IF v_lessons IS NOT NULL THEN
        v_base := coalesce(v_base, '') ||
                  E'\n\nRecent lessons from this pipeline + stage:\n' ||
                  v_lessons;
    END IF;

    RETURN v_base;
END;
$func$;

COMMENT ON FUNCTION stewards.retry_guidance_with_lessons(text, integer, text, text) IS
'Phase 5f (E.4): wraps retry_guidance() and appends the last 3 ratified lessons for the (pipeline_family, current_stage) cell from lessons_recent_ratified. Only ratified content influences retry context (D-D3).';

-- ---------------------------------------------------------------------
-- apply_gate_override — atomic human override of a gate decision
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_gate_override(
    p_gate_decision_id bigint,
    p_overridden_by    text,
    p_new_action       text,
    p_justification    text
) RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_decision     stewards.gate_decisions%ROWTYPE;
    v_actor        jsonb;
    v_new_decision jsonb;
    v_result       text;
BEGIN
    IF p_new_action NOT IN ('advance','revise','surface') THEN
        RAISE EXCEPTION 'apply_gate_override: invalid new_action %', p_new_action;
    END IF;
    IF p_justification IS NULL OR length(trim(p_justification)) < 10 THEN
        RAISE EXCEPTION 'apply_gate_override: justification required (>= 10 chars)';
    END IF;
    IF p_overridden_by IS NULL OR length(trim(p_overridden_by)) = 0 THEN
        RAISE EXCEPTION 'apply_gate_override: overridden_by required';
    END IF;

    SELECT * INTO v_decision FROM stewards.gate_decisions WHERE id = p_gate_decision_id;
    IF v_decision.id IS NULL THEN
        RAISE EXCEPTION 'apply_gate_override: gate_decision % not found', p_gate_decision_id;
    END IF;

    IF v_decision.action = p_new_action THEN
        RAISE EXCEPTION 'apply_gate_override: original action and new_action are both %; this is a no-op', p_new_action;
    END IF;

    INSERT INTO stewards.gate_overrides
        (gate_decision_id, overridden_by, new_action, justification)
    VALUES
        (p_gate_decision_id, p_overridden_by, p_new_action, p_justification);

    v_actor := stewards.work_item_stage_actor(v_decision.work_item_id);
    IF v_actor IS NOT NULL THEN
        BEGIN
            PERFORM stewards.trust_record_override(
                v_actor->>'agent_family',
                v_actor->>'pipeline_family',
                v_actor->>'model'
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'trust_record_override raised: %', SQLERRM;
        END;
    END IF;

    v_new_decision := jsonb_build_object(
        'action',    p_new_action,
        'reasoning', '[human override by ' || p_overridden_by || '] ' ||
                     coalesce(v_decision.reasoning, ''),
        'feedback',  coalesce(v_decision.feedback, '')
    );
    v_result := stewards.apply_gate_decision(
        v_decision.work_item_id, v_new_decision, v_decision.work_id);

    RETURN v_result;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_gate_override(bigint, text, text, text) IS
'Phase 5f (E.5): atomic override of a gate decision. Writes a gate_overrides row, bumps human_overrides on trust_scores (auto-demotes per D-E3), re-applies apply_gate_decision with the new action. Requires justification >= 10 chars.';

-- =====================================================================
-- Done. 11-trust: the trust ladder + counters + evaluate/adjust + the
-- trust-gated apply_gate_decision (single, final definition) + override.
-- =====================================================================
-- ===== [was 12-council.sql] =====
-- =====================================================================
-- 12-council.sql — councils (Zion / cycle step 11): convene → deliberate
--   → synthesize → bishop resolution, + the resolution-file producer.
--
-- Consolidated (authoring leg, 2026-06-13) from the historical chain:
--   5g   — councils / council_members / resolutions tables (+ the
--          one_active_council index). The sessions.kind 'council' value is
--          born in src/schema.rs (no constraint churn here).
--   5g2  — council_proposer/critic/synthesizer templates + convene_council
--   5g3  — synthesize_council / apply_synthesize_result / resolve_council
--   5g4  — bishop_eligible (values_anchor) + suggest_councils
--   6e   — enqueue_resolution_file + the resolutions promoted_to trigger
--          (these live HERE, not 10-sabbath, because they declare
--          stewards.resolutions%ROWTYPE and trigger ON stewards.resolutions —
--          a %ROWTYPE / trigger on a not-yet-existing table fails at CREATE).
--
-- Rename applied: bishop_eligible's low-stakes test reads
-- intents.values_anchor (was scripture_anchor).
-- =====================================================================

-- ---------------------------------------------------------------------
-- councils — one row per convened council (D-F1: one active at a time)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.councils (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    intent_id         uuid NOT NULL REFERENCES stewards.intents(id),
    binding_question  text NOT NULL,
    convened_at       timestamptz NOT NULL DEFAULT now(),
    convened_by       text NOT NULL,
    bishop            text NOT NULL,
    status            text NOT NULL DEFAULT 'deliberating'
                       CHECK (status IN ('deliberating', 'synthesizing', 'awaiting_bishop',
                                          'resolved', 'dissolved')),
    resolution_id     uuid,                    -- FK wired after resolutions exists
    dissolved_reason  text,
    resolved_at       timestamptz
);

CREATE INDEX IF NOT EXISTS councils_status      ON stewards.councils (status);
CREATE INDEX IF NOT EXISTS councils_convened_at ON stewards.councils (convened_at);

DO $idx$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes WHERE indexname = 'one_active_council'
    ) THEN
        CREATE UNIQUE INDEX one_active_council
            ON stewards.councils ((1))
            WHERE status IN ('deliberating', 'synthesizing', 'awaiting_bishop');
    END IF;
END;
$idx$;

COMMENT ON TABLE stewards.councils IS
'Phase 5g (F.1): one row per convened council. one_active_council partial unique index enforces D-F1 (one concurrent council initially).';

-- ---------------------------------------------------------------------
-- council_members
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.council_members (
    council_id    uuid NOT NULL REFERENCES stewards.councils(id) ON DELETE CASCADE,
    agent_family  text NOT NULL,
    role          text NOT NULL CHECK (role IN ('proposer', 'critic', 'synthesizer')),
    work_id       bigint,
    response      text,
    completed_at  timestamptz,
    PRIMARY KEY (council_id, agent_family, role)
);

CREATE INDEX IF NOT EXISTS council_members_council ON stewards.council_members (council_id);

COMMENT ON TABLE stewards.council_members IS
'Phase 5g (F.1): per-(council, agent_family, role) member. Member key = (council_id, agent_family, role); model floats per dispatch.';

-- ---------------------------------------------------------------------
-- resolutions
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.resolutions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    council_id      uuid REFERENCES stewards.councils(id),
    resolved_at     timestamptz NOT NULL DEFAULT now(),
    resolved_by     text NOT NULL,
    text            text NOT NULL,
    promoted_to     text,
    promoted_at     timestamptz,
    raw_proposal    jsonb
);

CREATE INDEX IF NOT EXISTS resolutions_council ON stewards.resolutions (council_id);

COMMENT ON TABLE stewards.resolutions IS
'Phase 5g (F.1): canonical resolutions (D-F3). Bishop accept may also promote to study/ or .mind/decisions.md based on question type via the resolutions promoted_to trigger.';

-- Wire the FK back from councils.resolution_id → resolutions.id
DO $fk$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'councils_resolution_id_fkey'
    ) THEN
        ALTER TABLE stewards.councils
            ADD CONSTRAINT councils_resolution_id_fkey
            FOREIGN KEY (resolution_id) REFERENCES stewards.resolutions(id);
    END IF;
END;
$fk$;

-- ---------------------------------------------------------------------
-- council member prompt templates (table + CHECK born in 08-gates)
-- ---------------------------------------------------------------------

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('council_proposer',
$tmpl$You are a member of a council convened to address a single binding question. Your role is PROPOSER.

The intent and active covenant for this council are loaded into your system prompt above.

Council intent: {{intent_purpose}}
Binding question: {{binding_question}}

Your job as proposer: offer a concrete proposed answer to the binding question. Lead with the answer; back it with reasoning that engages the corpus where relevant. You have substrate-internal tools (doc_search, doc_get, doc_similar, doc_citations) available — use them to ground your proposal in existing work.

Don't hedge. Don't list every possible angle. Take a position and defend it. The critic will stress-test it; the synthesizer will integrate.

Respond with prose (no JSON shape required). Aim for 200-500 words.
$tmpl$,
     'Phase 5g (F.2): proposer role. Tools enabled.')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('council_critic',
$tmpl$You are a member of a council convened to address a single binding question. Your role is CRITIC.

The intent and active covenant for this council are loaded into your system prompt above.

Council intent: {{intent_purpose}}
Binding question: {{binding_question}}

Your job as critic: find what's wrong, missing, or under-considered in the proposer's framing. The covenant's surface_tensions commitment binds you here — your function is the council's check, not its echo.

If the proposer's response is available you'll see it below; if not, articulate the strongest counterposition you can.

{{proposer_responses}}

Don't be contrarian for sport. Identify the real fault lines. What's the proposer assuming that they shouldn't? What corpus context would change the picture? You have substrate-internal tools available.

Respond with prose. 200-500 words.
$tmpl$,
     'Phase 5g (F.2): critic role. Tools enabled. surface_tensions covenant directly applied.')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('council_synthesizer',
$tmpl$You are the synthesizer for a council convened to address a single binding question.

The intent and active covenant for this council are loaded into your system prompt above.

Council intent: {{intent_purpose}}
Binding question: {{binding_question}}

Council members responded:

{{member_responses}}

Your job: produce a single proposed resolution. Honor the proposer's instinct where it survived the critic; honor the critic's catch where the proposer missed something; name the genuine tension where both have a point and the human bishop needs to decide.

Don't paper over disagreement. Don't pretend to consensus that isn't there.

Respond with JSON ONLY (no prose around it, no tool calls):
{
  "resolution": "the proposed answer (1-3 paragraphs)",
  "tensions": ["unresolved tension 1", "tension 2", ...],
  "destination_hint": "study" | "decisions" | "either" | "none"
}

destination_hint guides the bishop: 'study' if the resolution belongs in study/<slug>.md (doctrinal/narrative), 'decisions' if it belongs in .mind/decisions.md (engineering/operational), 'either' if both, 'none' if it should stay in the resolutions table only.
$tmpl$,
     'Phase 5g (F.2): synthesizer role. Tools DISABLED (structured JSON output). Per D-F3, destination_hint feeds the bishop''s promotion choice.')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

-- ---------------------------------------------------------------------
-- convene_council — D-F1 enforcement + parallel member dispatch
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.convene_council(
    p_intent_id        uuid,
    p_binding_question text,
    p_members          jsonb,
    p_bishop           text,
    p_convened_by      text DEFAULT 'human'
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_council_id  uuid;
    v_intent      stewards.intents%ROWTYPE;
    v_member      jsonb;
    v_role        text;
    v_agent       text;
    v_model       text;
    v_session_id  text;
    v_template_id text;
    v_template    text;
    v_prompt      text;
    v_payload     jsonb;
    v_work_id     bigint;
    v_provider    text := 'opencode_go';
    v_tools_off   boolean;
    v_member_count int;
BEGIN
    SELECT * INTO v_intent FROM stewards.intents WHERE id = p_intent_id;
    IF v_intent.id IS NULL THEN
        RAISE EXCEPTION 'convene_council: intent % not found', p_intent_id;
    END IF;

    IF p_members IS NULL OR jsonb_typeof(p_members) <> 'array' THEN
        RAISE EXCEPTION 'convene_council: p_members must be a jsonb array';
    END IF;

    v_member_count := jsonb_array_length(p_members);
    IF v_member_count < 2 OR v_member_count > 5 THEN
        RAISE EXCEPTION 'convene_council: must have between 2 and 5 members (got %)', v_member_count;
    END IF;

    IF EXISTS (SELECT 1 FROM stewards.councils
                WHERE status IN ('deliberating', 'synthesizing', 'awaiting_bishop')) THEN
        RAISE EXCEPTION 'convene_council: one council at a time (D-F1) — resolve or dissolve the active council first';
    END IF;

    INSERT INTO stewards.councils (intent_id, binding_question, convened_by, bishop)
    VALUES (p_intent_id, p_binding_question, p_convened_by, p_bishop)
    RETURNING id INTO v_council_id;

    FOR v_member IN SELECT * FROM jsonb_array_elements(p_members) LOOP
        v_role  := v_member->>'role';
        v_agent := v_member->>'agent_family';
        v_model := coalesce(v_member->>'model', 'kimi-k2.6');

        IF v_role NOT IN ('proposer', 'critic', 'synthesizer') THEN
            RAISE EXCEPTION 'convene_council: invalid role % for agent %', v_role, v_agent;
        END IF;

        v_template_id := 'council_' || v_role;
        SELECT template INTO v_template
          FROM stewards.gate_prompts WHERE id = v_template_id;

        v_session_id := substring(
            'council--' || substring(v_council_id::text FROM 1 FOR 8) ||
            '--' || v_role || '--' || v_agent,
            1, 200);

        INSERT INTO stewards.sessions (id, label, kind)
        VALUES (v_session_id,
                format('council %s role=%s agent=%s', v_council_id, v_role, v_agent),
                'council')
        ON CONFLICT (id) DO NOTHING;

        v_prompt := stewards.render_template(v_template, jsonb_build_object(
            'intent_purpose',     v_intent.purpose,
            'binding_question',   p_binding_question,
            'proposer_responses', '(none yet — proposer responses arrive in parallel)',
            'member_responses',   '(none yet — members responding in parallel)'
        ));

        INSERT INTO stewards.messages (session_id, role, content, model)
        VALUES (v_session_id, 'user', v_prompt, v_model);

        v_tools_off := (v_role = 'synthesizer');

        v_payload := jsonb_build_object(
            'session_id',      v_session_id,
            'agent_family',    v_agent,
            'requested_model', v_model,
            'meta',            '{}'::jsonb,
            'body',            (stewards.dry_run_chat(v_agent, v_model, v_session_id, NULL) - '_meta')
                               || jsonb_build_object('user', v_session_id),
            'tools_disabled',  v_tools_off,
            '_council_id',     v_council_id::text,
            '_council_member', true,
            '_council_role',   v_role
        );

        INSERT INTO stewards.work_queue (kind, provider, payload)
        VALUES ('chat', v_provider, v_payload)
        RETURNING id INTO v_work_id;

        INSERT INTO stewards.council_members (council_id, agent_family, role, work_id)
        VALUES (v_council_id, v_agent, v_role, v_work_id);
    END LOOP;

    RETURN v_council_id;
END;
$func$;

COMMENT ON FUNCTION stewards.convene_council(uuid, text, jsonb, text, text) IS
'Phase 5g (F.2): convene a council. Validates intent + members shape (2-5) + D-F1 (one active at a time). Dispatches each member in parallel with role-specific prompt + _council_id/_council_member markers. Synthesizer member gets tools_disabled=true; proposer/critic get tools enabled.';

-- ---------------------------------------------------------------------
-- synthesize_council — second-round dispatch with member context
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.synthesize_council(
    p_council_id uuid
) RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_council         stewards.councils%ROWTYPE;
    v_intent          stewards.intents%ROWTYPE;
    v_template        text;
    v_member_responses text;
    v_prompt          text;
    v_session_id      text;
    v_payload         jsonb;
    v_work_id         bigint;
    v_synth_agent     text := 'plan';
    v_synth_model     text := 'kimi-k2.6';
BEGIN
    SELECT * INTO v_council FROM stewards.councils WHERE id = p_council_id;
    IF v_council.id IS NULL THEN
        RAISE EXCEPTION 'synthesize_council: council % not found', p_council_id;
    END IF;
    IF v_council.status NOT IN ('deliberating', 'synthesizing') THEN
        RAISE EXCEPTION 'synthesize_council: council % status=%, expected deliberating/synthesizing',
                        p_council_id, v_council.status;
    END IF;

    SELECT * INTO v_intent FROM stewards.intents WHERE id = v_council.intent_id;

    SELECT template INTO v_template FROM stewards.gate_prompts WHERE id = 'council_synthesizer';

    SELECT string_agg(
             format(E'### %s (%s)\n\n%s', upper(role), agent_family,
                    coalesce(response, '(no response)')),
             E'\n\n---\n\n' ORDER BY role, agent_family)
      INTO v_member_responses
      FROM stewards.council_members
     WHERE council_id = p_council_id
       AND role IN ('proposer', 'critic');

    v_prompt := stewards.render_template(v_template, jsonb_build_object(
        'intent_purpose',   v_intent.purpose,
        'binding_question', v_council.binding_question,
        'member_responses', coalesce(v_member_responses, '(no member responses recorded)')
    ));

    v_session_id := substring(
        'council--' || substring(v_council.id::text FROM 1 FOR 8) ||
        '--synthesize--' ||
        to_char(extract(epoch from now())::bigint, 'FM9999999999'),
        1, 200);

    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (v_session_id,
            format('council %s synthesizer (auto)', v_council.id),
            'council')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO stewards.messages (session_id, role, content, model)
    VALUES (v_session_id, 'user', v_prompt, v_synth_model);

    v_payload := jsonb_build_object(
        'session_id',           v_session_id,
        'agent_family',         v_synth_agent,
        'requested_model',      v_synth_model,
        'meta',                 '{}'::jsonb,
        'body',                 (stewards.dry_run_chat(v_synth_agent, v_synth_model, v_session_id, NULL) - '_meta')
                                || jsonb_build_object('user', v_session_id),
        'tools_disabled',       true,
        '_council_id',          v_council.id::text,
        '_council_synthesize',  true
    );

    INSERT INTO stewards.work_queue (kind, provider, payload)
    VALUES ('chat', 'opencode_go', v_payload)
    RETURNING id INTO v_work_id;

    UPDATE stewards.councils
       SET status = 'synthesizing'
     WHERE id = p_council_id;

    RETURN v_work_id;
END;
$func$;

COMMENT ON FUNCTION stewards.synthesize_council(uuid) IS
'Phase 5g (F.3): enqueue the synthesizer dispatch with proposer + critic responses in context. tools_disabled=true. Status → synthesizing. bgworker auto-fires apply_synthesize_result on completion.';

-- ---------------------------------------------------------------------
-- apply_synthesize_result — store draft + transition to bishop
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.apply_synthesize_result(
    p_council_id uuid,
    p_result     jsonb,
    p_work_id    bigint DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_council        stewards.councils%ROWTYPE;
    v_resolution_id  uuid;
BEGIN
    SELECT * INTO v_council FROM stewards.councils WHERE id = p_council_id FOR UPDATE;
    IF v_council.id IS NULL THEN
        RAISE EXCEPTION 'apply_synthesize_result: council % not found', p_council_id;
    END IF;

    INSERT INTO stewards.resolutions
        (council_id, resolved_by, text, raw_proposal)
    VALUES
        (p_council_id, '__draft__', coalesce(p_result->>'resolution', '(no resolution text)'),
         p_result)
    RETURNING id INTO v_resolution_id;

    UPDATE stewards.councils
       SET status        = 'awaiting_bishop',
           resolution_id = v_resolution_id
     WHERE id = p_council_id;

    RETURN v_resolution_id;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_synthesize_result(uuid, jsonb, bigint) IS
'Phase 5g (F.3): store the synthesizer''s draft resolution; transition council to awaiting_bishop. resolved_by=__draft__ until the bishop accepts via resolve_council.';

-- ---------------------------------------------------------------------
-- resolve_council — bishop's accept / request_revision / dissolve
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.resolve_council(
    p_council_id      uuid,
    p_action          text,
    p_resolution_text text,
    p_destination     text,
    p_resolved_by     text,
    p_dissolved_reason text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_council    stewards.councils%ROWTYPE;
    v_resolution_id uuid;
    v_promoted_to text;
BEGIN
    SELECT * INTO v_council FROM stewards.councils WHERE id = p_council_id FOR UPDATE;
    IF v_council.id IS NULL THEN
        RAISE EXCEPTION 'resolve_council: council % not found', p_council_id;
    END IF;
    IF p_action NOT IN ('accept', 'request_revision', 'dissolve') THEN
        RAISE EXCEPTION 'resolve_council: invalid action %', p_action;
    END IF;
    IF v_council.status NOT IN ('awaiting_bishop', 'deliberating', 'synthesizing') THEN
        RAISE EXCEPTION 'resolve_council: council % status=%, cannot resolve', p_council_id, v_council.status;
    END IF;

    IF p_action = 'accept' THEN
        IF p_resolution_text IS NULL OR length(trim(p_resolution_text)) = 0 THEN
            RAISE EXCEPTION 'resolve_council: accept requires resolution_text';
        END IF;
        IF p_resolved_by IS NULL OR length(trim(p_resolved_by)) = 0 THEN
            RAISE EXCEPTION 'resolve_council: accept requires resolved_by';
        END IF;

        v_promoted_to := CASE p_destination
            WHEN 'study'     THEN 'study/' || substring(v_council.id::text FROM 1 FOR 8) || '.md'
            WHEN 'decisions' THEN '.mind/decisions.md'
            ELSE NULL
        END;

        IF v_council.resolution_id IS NOT NULL THEN
            UPDATE stewards.resolutions
               SET text         = p_resolution_text,
                   resolved_by  = p_resolved_by,
                   resolved_at  = now(),
                   promoted_to  = v_promoted_to,
                   promoted_at  = CASE WHEN v_promoted_to IS NOT NULL THEN now() ELSE NULL END
             WHERE id = v_council.resolution_id
            RETURNING id INTO v_resolution_id;
        ELSE
            INSERT INTO stewards.resolutions
                (council_id, resolved_by, text, promoted_to, promoted_at)
            VALUES
                (p_council_id, p_resolved_by, p_resolution_text, v_promoted_to,
                 CASE WHEN v_promoted_to IS NOT NULL THEN now() ELSE NULL END)
            RETURNING id INTO v_resolution_id;
        END IF;

        UPDATE stewards.councils
           SET status        = 'resolved',
               resolution_id = v_resolution_id,
               resolved_at   = now()
         WHERE id = p_council_id;

        RETURN v_resolution_id;

    ELSIF p_action = 'request_revision' THEN
        IF v_council.resolution_id IS NOT NULL THEN
            UPDATE stewards.resolutions
               SET text = text || E'\n\n[Bishop requests revision] ' || coalesce(p_resolution_text, '')
             WHERE id = v_council.resolution_id;
        END IF;
        UPDATE stewards.councils SET status = 'deliberating' WHERE id = p_council_id;
        PERFORM stewards.synthesize_council(p_council_id);
        RETURN v_council.resolution_id;

    ELSIF p_action = 'dissolve' THEN
        UPDATE stewards.councils
           SET status           = 'dissolved',
               dissolved_reason = coalesce(p_dissolved_reason, 'no reason given'),
               resolved_at      = now()
         WHERE id = p_council_id;
        RETURN v_council.resolution_id;
    END IF;

    RETURN NULL;
END;
$func$;

COMMENT ON FUNCTION stewards.resolve_council(uuid, text, text, text, text, text) IS
'Phase 5g (F.3): bishop''s resolution path. accept = canonicalize the draft (optional promotion to study/ or .mind/decisions.md per D-F3); request_revision = re-fire synthesize with bishop note; dissolve = terminate with reason.';

-- ---------------------------------------------------------------------
-- bishop_eligible — D-F2. Humans always; agents only on low-stakes
-- intents (values_anchor IS NULL + values_hierarchy lacks doctrinal/
-- spiritual/discernment) AND master-tier on the intent's pipeline.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.bishop_eligible(
    p_bishop    text,
    p_intent_id uuid
) RETURNS boolean
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_intent      stewards.intents%ROWTYPE;
    v_parts       text[];
    v_agent       text;
    v_pipeline    text;
    v_required_tier text;
    v_actual_level text;
    v_low_stakes  boolean;
BEGIN
    IF p_bishop LIKE 'human:%' THEN
        RETURN true;
    END IF;

    SELECT * INTO v_intent FROM stewards.intents WHERE id = p_intent_id;
    IF v_intent.id IS NULL THEN
        RETURN false;
    END IF;

    -- Low-stakes check: doctrinal/spiritual/discernment intents (or any
    -- intent carrying a values_anchor) always require a human bishop.
    v_low_stakes := (
        v_intent.values_anchor IS NULL
        AND v_intent.values_hierarchy::text !~* '(doctrinal|spiritual|discernment)'
    );

    IF NOT v_low_stakes THEN
        RETURN false;
    END IF;

    v_parts := string_to_array(p_bishop, ':');
    IF array_length(v_parts, 1) < 4 OR v_parts[1] <> 'agent' THEN
        RETURN false;
    END IF;
    v_agent         := v_parts[2];
    v_pipeline      := v_parts[3];
    v_required_tier := v_parts[4];

    IF v_required_tier <> 'master' THEN
        RETURN false;
    END IF;

    SELECT trust_level INTO v_actual_level
      FROM stewards.trust_scores
     WHERE agent_family = v_agent
       AND pipeline_family = v_pipeline
       AND trust_level = 'master'
     LIMIT 1;

    RETURN v_actual_level IS NOT NULL;
END;
$func$;

COMMENT ON FUNCTION stewards.bishop_eligible(text, uuid) IS
'Phase 5g (F.5): bishop eligibility per D-F2. Humans always eligible. Agents (bishop=agent:<family>:<pipeline>:master) only on low-stakes intents (no values_anchor + values_hierarchy lacks doctrinal/spiritual/discernment) AND master-tier on at least one (agent, pipeline, model) cell.';

-- ---------------------------------------------------------------------
-- suggest_councils — clusters of 5+ ratified lessons by (pipeline, stage)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.suggest_councils(
    p_min_lessons int DEFAULT 5
) RETURNS TABLE (
    pipeline_family text,
    current_stage   text,
    lesson_count    bigint,
    sample_content  text
)
LANGUAGE sql STABLE AS $func$
SELECT
    pipeline_family,
    current_stage,
    count(*) AS lesson_count,
    string_agg('  - ' || left(content, 100), E'\n' ORDER BY at DESC) FILTER (WHERE rn <= 3) AS sample_content
  FROM (
    SELECT
        l.id,
        l.content,
        l.at,
        wi.pipeline_family,
        wi.current_stage,
        row_number() OVER (PARTITION BY wi.pipeline_family, wi.current_stage ORDER BY l.at DESC) AS rn
      FROM stewards.lessons l
      JOIN stewards.work_items wi ON wi.id = l.work_item_id
     WHERE l.ratified_at IS NOT NULL
       AND l.kind IN ('lesson', 'principle')
       AND l.at > COALESCE((
           SELECT max(c.convened_at)
             FROM stewards.councils c
             JOIN stewards.intents i ON i.id = c.intent_id
            WHERE i.purpose ILIKE '%' || wi.pipeline_family || '%'
       ), '-infinity'::timestamptz)
  ) clustered
 GROUP BY pipeline_family, current_stage
HAVING count(*) >= p_min_lessons
 ORDER BY lesson_count DESC, pipeline_family, current_stage;
$func$;

COMMENT ON FUNCTION stewards.suggest_councils(int) IS
'Phase 5g (F.5): scan ratified lessons for clusters by (pipeline_family, current_stage). Default threshold 5+. Heuristic dedupe: skip clusters where a council on this pipeline was convened more recently than the lessons.';

-- ---------------------------------------------------------------------
-- enqueue_resolution_file + the resolutions promoted_to trigger
-- (6e resolution half — needs stewards.resolutions + stewards.councils).
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.enqueue_resolution_file(p_resolution_id uuid)
RETURNS bigint
LANGUAGE plpgsql AS $func$
DECLARE
    v_res stewards.resolutions%ROWTYPE;
    v_council stewards.councils%ROWTYPE;
    v_pwid bigint;
    v_content text;
    v_write_mode text;
BEGIN
    SELECT * INTO v_res FROM stewards.resolutions WHERE id = p_resolution_id;
    IF v_res.id IS NULL OR v_res.promoted_to IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_council FROM stewards.councils WHERE id = v_res.council_id;

    IF v_res.promoted_to LIKE '.mind/%' THEN
        v_write_mode := 'append';
        v_content := format(
            E'\n\n## %s — Council resolution: %s\n\n%s\n',
            to_char(coalesce(v_res.resolved_at, now()), 'YYYY-MM-DD'),
            coalesce(v_council.binding_question, '(no binding question)'),
            v_res.text);
    ELSE
        v_write_mode := 'create';
        v_content := format(
            E'# Council resolution\n\n**Binding question:** %s\n**Resolved by:** %s\n**Resolved at:** %s\n\n---\n\n%s\n',
            coalesce(v_council.binding_question, '(no binding question)'),
            v_res.resolved_by,
            to_char(coalesce(v_res.resolved_at, now()), 'YYYY-MM-DD HH24:MI'),
            v_res.text);
    END IF;

    INSERT INTO stewards.pending_file_writes
        (requested_by, target_path, write_mode, content, source_id, source_kind)
    VALUES
        ('council_resolve', v_res.promoted_to, v_write_mode, v_content,
         v_res.id::text, 'resolution')
    RETURNING id INTO v_pwid;

    RETURN v_pwid;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_resolution_file(uuid) IS
'Batch G.4.5: queue a pending_file_writes row for an accepted council resolution. Paths under .mind/ use append mode + dated header; study/<id>.md paths use create mode + full document frontmatter.';

CREATE OR REPLACE FUNCTION stewards.resolutions_promoted_to_trigger()
RETURNS trigger
LANGUAGE plpgsql AS $func$
BEGIN
    IF NEW.promoted_to IS NOT NULL
       AND (OLD.promoted_to IS NULL OR OLD.promoted_to <> NEW.promoted_to) THEN
        BEGIN
            PERFORM stewards.enqueue_resolution_file(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'enqueue_resolution_file failed for resolution %: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$func$;

DROP TRIGGER IF EXISTS resolutions_promoted_to_au ON stewards.resolutions;
CREATE TRIGGER resolutions_promoted_to_au
    AFTER UPDATE OF promoted_to ON stewards.resolutions
    FOR EACH ROW
    EXECUTE FUNCTION stewards.resolutions_promoted_to_trigger();

COMMENT ON FUNCTION stewards.resolutions_promoted_to_trigger() IS
'Batch G.4.5: fires enqueue_resolution_file when a council resolution''s promoted_to transitions from NULL to a path (bishop accepted with destination=study|decisions). Errors swallowed via NOTICE.';

-- =====================================================================
-- Done. 12-council: convene → deliberate → synthesize → bishop resolution,
-- bishop eligibility, council suggestion, and the resolution-file producer.
-- =====================================================================
-- ===== [was 13-research-pipelines.sql] =====
-- =====================================================================
-- 13-research-pipelines.sql — research / planning / agent-write-back
--   pipeline-family seeds and their apply functions.
--
-- Consolidates (authoring blueprint, batch B4):
--   h1-2  research-write pipeline (gather/synthesize/review)
--   h1-5b gather-template tighten        ┐ both superseded by h2's final
--   h1-7b research tool grants + template┘ context_gather / gather split
--   h2    context_gather stage  → research-write FINAL is 4 stages:
--                                 context_gather → gather → synthesize → review
--   h3-4  planning pipeline (5 stages)
--   h3-5  enqueue_proposed_work_items
--   h3-followup-3 revise-proposal pipeline + apply_revision
--   i4    agent-proposal pipeline + apply_agent_proposal base
--         + the agent_proposal_applied_at column
--   i6    schema-migration claude_attested gate   ┐ folded into the single
--   i7    apply_agent_proposal FINAL (direct       ┘ i7 form authored below
--         pending_file_writes queue; bypasses the i4 JSON-wrapper bug)
--   pe2   research-summary (daily-digest) pipeline
--
-- Dependency-correctness deviations from the blueprint's literal source
-- map (the forward-ref rule, same class as the B2/B3 deviations):
--
--   * h1-0 and h3-1 were already FULLY consumed before B4 — h1-0 at B3
--     (maturity_ladder → 08, sabbath/atonement overrides → 10); h3-1's
--     work_items columns (origin/project_association/parent_work_item_id
--     + the origin CHECK carrying agent_planning AND agent_proposal) are
--     born in 04, its docs columns in create_docs. Both are dropped from
--     this file's source list.
--
--   * h-ledger-1's stewards.schema_migrations table is migration
--     INFRASTRUCTURE, not a research pipeline. In the consolidated bundle
--     the runtime manifest starts empty, so the table must be born by
--     CREATE EXTENSION for the overlay tier (and going-forward core
--     hotfixes) to record into it. It moves to 00-config, not here.
--
--   * on_maturity_verified is NOT redefined here. It is authored once in
--     08-gates as a single final form that calls enqueue_proposed_work_items
--     (this file), apply_agent_proposal (this file), and the fan-out
--     aggregator (14-fanout) as WRAPPED forward refs — the 04/B3 precedent
--     (a wrapped function call to an object born later in the chain is a
--     safe CREATE-time forward ref; a SELECT-from-a-later-table is not).
--     08's single final form is updated at the close of B4 once 13's and
--     14's functions both exist.
--
--   * apply_agent_proposal is authored ONCE in its i7 final form (the
--     direct pending_file_writes queue, which also carries i6's
--     claude_attested gate). i4's base and i6's redefinition collapse into
--     it; i4's validate-stage prompt is seeded in the i6 form (the one that
--     documents the KIMI-TRUST GATE).
--
--   * work_item_dispatch_stage's per-stage tools_disabled forward
--     (h1-2 §H.1.3) is NOT authored here. That function accretes across
--     the chain (04 base → tools_disabled → fallback chain → spend caps →
--     capability gate → max-tokens) and is authored once in its final form
--     in 19-models (B5), where its last dependency (r3 max-tokens) lands.
--     04's base form holds until then; the pipeline seeds below still carry
--     each stage's tools_disabled flag in the stages jsonb.
--
-- Genericization (classification notes "genericize corpus-kind text"):
-- the scripture-study "gospel" corpus reference in the prior-work tool
-- descriptions is generalized, and the project-specific example names in
-- the planning propose_work example are neutralized. Model / provider
-- names (kimi-k2.6 / qwen3.7-plus / opencode_go) are kept as operator-data
-- references, consistent with 04's echo-test example seed: the seed pack
-- ships matching example agents/models/providers.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Feature columns this subsystem owns (work_items spine lives in 04).
-- ---------------------------------------------------------------------
ALTER TABLE stewards.work_items
    ADD COLUMN IF NOT EXISTS agent_proposal_applied_at timestamp with time zone,
    ADD COLUMN IF NOT EXISTS revision_applied_at       timestamp with time zone;

COMMENT ON COLUMN stewards.work_items.agent_proposal_applied_at IS
'i4/i7 (13-research-pipelines): set by apply_agent_proposal when an agent-proposal work_item has been persisted (docs row + pending_file_write queued). NULL = not yet persisted (or never an agent proposal). Idempotency guard.';
COMMENT ON COLUMN stewards.work_items.revision_applied_at IS
'h3-followup-3 (13-research-pipelines): set by apply_revision when a revise-proposal work_item has been merged into its parent proposal. NULL = not yet applied (or rejected). Idempotency guard.';

-- ---------------------------------------------------------------------
-- The generic `research` agent — core-seeded so a virgin install's own
-- research/planning pipelines (below) actually run.
--
-- Before 2026-06-15 this family was referenced by every pipeline in this
-- file (and granted tools, below) but the AGENT ROW was never seeded, so a
-- fresh CREATE EXTENSION failed at dispatch with "no agent variant
-- resolved: family=research". The example digesters had drifted onto a
-- second name (`stewards-explore`) that nothing shipped either. Both now
-- unify on this one generic agent. (Surfaced by the reflect-steward P0
-- dry-run; see .spec/proposals/reflect-steward-p0-dryrun-report.md.)
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES (
  'research', '*',
  'Generic research/explore agent: gathers via tools, reads sources faithfully, '
    || 'synthesizes grounded output. The agent the research, planning, and digester '
    || 'pipelines run on.',
  'primary',
  $RESEARCH$You are a research agent in an autonomous stewardship substrate. You gather information with your tools, read sources faithfully, and synthesize what you find into clear, grounded output.

Principles:
- Discover with your tools; do not rely on memory. Search and read before you conclude.
- Ground every claim in a source you actually retrieved. Quote or cite; never invent a fact, a complaint, or a quote.
- Depth over breadth: understand the strongest signal before moving on.
- Follow your pipeline stage's instructions for output format and tool budget exactly.

You are one stage in a multi-stage pipeline. Do your stage's job and hand off cleanly.$RESEARCH$,
  0.4)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, prompt = EXCLUDED.prompt, active = true;

-- Research agent-family tool grants (h1-7b). Internal surface = filesystem-read
-- + prior-work inspection; web_search_exa + fetch_url give it external reach
-- (exa-search ships as a core default server, so the generic research agent can
-- actually research the web out of the box). Escalation WRITE tools are
-- deliberately NOT granted (operator surface).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('research', 'fs_read',              'allow', 'manual'),
  ('research', 'fs_list',              'allow', 'manual'),
  ('research', 'fs_search',            'allow', 'manual'),
  ('research', 'work_item_list',       'allow', 'manual'),
  ('research', 'work_item_show',       'allow', 'manual'),
  ('research', 'watchman_pass_show',   'allow', 'manual'),
  ('research', 'watchman_passes_list', 'allow', 'manual'),
  ('research', 'web_search_exa',       'allow', 'manual'),
  ('research', 'fetch_url',            'allow', 'manual'),
  -- Sense the intent's knowledge pool: the substrate self-surface read tools.
  ('research', 'doc_search',           'allow', 'manual'),
  ('research', 'doc_get',              'allow', 'manual'),
  ('research', 'doc_similar',          'allow', 'manual'),
  -- Context self-management + durable memory. A reflect-steward cycle (and a
  -- digest of a huge book/transcript) can build long context; give research the
  -- tools to fold/mute/pin/compress its own window, commission a compactor, and
  -- keep durable notes across cycles. The self-editable BASE-prompt tool
  -- (propose_prompt_change) is deliberately NOT granted — that stays gated.
  ('research', 'compact_context',      'allow', 'manual'),
  ('research', 'remember',             'allow', 'manual'),
  ('research', 'forget',               'allow', 'manual'),
  ('research', 'expand_message',       'allow', 'manual'),
  ('research', 'summarize_my_context', 'allow', 'manual'),
  ('research', 'context_mute',         'allow', 'manual'),
  ('research', 'context_compress',     'allow', 'manual'),
  ('research', 'context_pin',          'allow', 'manual'),
  ('research', 'context_unpin',        'allow', 'manual'),
  ('research', 'context_expand',       'allow', 'manual'),
  ('research', 'context_set_tag',      'allow', 'manual'),
  ('research', 'context_clear_tag',    'allow', 'manual'),
  ('research', 'context_fold_tag',     'allow', 'manual'),
  ('research', 'context_mute_tag',     'allow', 'manual'),
  ('research', 'context_pin_tag',      'allow', 'manual'),
  ('research', 'context_expand_tag',   'allow', 'manual'),
  -- the gathered-source dedup ledger (22): check before crawl, record after.
  ('research', 'intent_sources_recent', 'allow', 'manual'),
  ('research', 'intent_source_record',  'allow', 'manual'),
  -- scoped knowledge-pool read (project neighborhood, 22); doc_search stays for meta.
  ('research', 'pool_search',           'allow', 'manual'),
  -- the council moment: survey what's already proposed/in-flight/done before proposing.
  ('research', 'intent_work_survey',    'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO NOTHING;

-- =====================================================================
-- research-write — deep-research pipeline (4 stages, h2 final form)
--   context_gather → gather → synthesize → review
-- =====================================================================
DO $seed$
DECLARE
    v_context_gather_template text;
    v_gather_template         text;
    v_synthesize_template     text;
    v_review_template         text;
    v_stages                  jsonb;
BEGIN

v_context_gather_template :=
$T$Binding question: {{input.binding_question}}

## YOUR TASK — situational awareness briefing

You are gathering context from the substrate's own knowledge — prior journals, proposals, mind files, docs, and work_items — to brief the next stage (the external-research gather stage) on what we already know about this binding question. Your output is NOT the final research piece. It is a *briefing* the next stage reads before doing external search.

## TOOLS

You have:
- `fs_search` (regex search across `.spec/journal/*`, `.spec/proposals/*`, `.mind/*`, `docs/**`)
- `fs_read` (read a file in full)
- `fs_list` (list files matching a glob)
- `doc_search` (the substrate's docs corpus — research, planning, and other studies)
- `doc_get` (read a doc by slug)
- `doc_similar` (related docs via embedding edges)
- `work_item_list` / `work_item_show` (prior work_items on this binding)

## HARD CONSTRAINTS

- **Maximum 4 rounds of tool calls.** Spend them on the most likely prior-work sources first (journals named for the topic; proposals; mind files like `.mind/active.md`, `.mind/principles.md`).
- **Output budget: ~2KB.** Summarize, don't transcribe. The gather stage reads your briefing in addition to its own template; keep it tight.
- **End-of-turn:** your final message is the briefing in markdown, then STOP.

## OUTPUT FORMAT — the briefing

```
## Prior context for: <one-line restatement of the binding question>

### What we already know
<2-4 bullets: the most relevant prior journals/proposals/docs and what they say>

### Gaps in our prior work
<2-3 bullets: what the prior work does NOT cover that the binding question needs>

### Suggested external-search angle for the next stage
<1-2 sentences: where the gather stage should focus its external search to fill the gaps>
```

If prior work is sparse or absent (e.g., this is a brand-new topic for us), say so explicitly — "We have no prior journals or proposals on X" — and the gather stage will know to start fresh externally.$T$;

v_gather_template :=
$T$Binding question: {{input.binding_question}}

## PRIOR CONTEXT (from context_gather stage)

{{stage_results.context_gather.output}}

## YOUR TASK

Given the prior context above, find external sources to fill the gaps and answer what prior work doesn't cover. Then **STOP**, produce the sources brief, and end your turn.

## HARD CONSTRAINTS

- **Maximum 8 strong sources** in the final brief. The prior context above counts as 0 of those — your job is the EXTERNAL sources.
- **Maximum 5 rounds of tool calls.** Cast wide early, narrow with `fetch_url` on high-value hits.
- **End-of-turn:** your final message is the sources brief in markdown. No further tool calls.

## TOOL GUIDANCE

You have `fetch_url` / `fetch_urls` (fetch a page as readable markdown) and `web_search_exa` (Exa web search — the default, works on the free tier out of the box), plus any other search tools your operator registered (`news_search`, `yt_search`, `yt_get`). Use 1-2 search calls per round to cast wide; use `fetch_url` to read a specific high-value source. Parallel tool calls in one round = ONE round.

You can also still use `fs_*` and `doc_*` if the prior context surfaces a substrate document you want to read directly — but skip another full sweep; context_gather already did that.

## FOR EACH SOURCE YOU KEEP

- **Title** + **URL** + **publication date**
- **One-sentence summary** of what it adds (especially what prior context didn't already cover)
- **Short verbatim quote** (1-3 sentences) you might draw on in synthesis
- **Source type:** primary documentation / news reporting / opinion / vendor blog / academic / etc.
- **Credibility note:** primary source for this claim? secondary? recency vs domain half-life?

## OUTPUT FORMAT

Produce a markdown sources brief: a numbered list of up to 8 sources, each with the five fields above. **No prose intro. No prose outro.** Just the structured list. The synthesize stage drafts the actual research piece from your brief + the prior context.$T$;

v_synthesize_template :=
$T$Binding question: {{input.binding_question}}

Sources brief from the gather stage:

{{stage_results.gather.output}}

Now write the research piece. Draw on the sources collected in the gather stage. You MAY re-fetch any source via fetch_url if you need to re-read it; you SHOULD NOT introduce new sources here — that's a sign the gather stage was incomplete and would be better fixed by re-running gather.

Quote text VERBATIM only when you have the source text in front of you in this session. Paraphrase otherwise — "Vendor X says that..." is honest; an unverified direct quote is not.

Attribution: every non-trivial claim cites the source it came from. Use inline markdown links: [Source Title](https://url). Where a claim is your synthesis across multiple sources, say so explicitly.

Structure suggestion (adapt to what the binding question actually needs):
  - **Headlines** — the 3-5 most important findings that answer the binding question
  - **Notable** — second-tier findings worth knowing
  - **Skeptical takes** — credible dissenting voices, if any
  - **Open questions** — what the sources don't answer

Length: aim for 800-2500 words depending on topic depth. Resist the urge to pad. Honest uncertainty ("I couldn't find a credible source on X") is preferred over fabrication.

Produce the complete research piece in markdown. The next stage reviews it.$T$;

v_review_template :=
$T$Binding question: {{input.binding_question}}

The draft from the previous stage:

{{stage_results.synthesize.output}}

Review the draft against four criteria:

1. **Source credibility.** Every claim of fact has a citation. Citations point to credible sources (primary docs or established reporting, not random blog posts presented as fact). Where a claim is uncited or cited weakly, flag it.

2. **Recency.** Where the domain moves fast, sources are 2025-2026. Older sources are explicitly flagged or appropriate to a slow-moving domain.

3. **Binding question coverage.** Does the draft answer what was asked? If not, name what's missing.

4. **Honest uncertainty.** Where the sources don't support a strong claim, the draft says so. No fabricated certainty.

Tools are DISABLED for this stage. You CANNOT fetch URLs or re-search — your review must rest on the draft itself plus the sources it cites in-line. If a claim looks unverifiable from the draft alone, flag it as unverifiable rather than try to verify externally.

Return ONE of:
(a) The same draft, verbatim and unchanged, if it passes all four criteria. Prefix with a single line: "REVIEW: passes" then a blank line then the draft.
(b) A revised draft. Prefix with "REVIEW: revised" then a blank line, the revised draft, and at the end a brief notes section listing what changed and why.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object(
        'name', 'context_gather', 'next', 'gather',
        'model', 'qwen3.7-plus', 'provider', 'opencode_go',
        'agent_family', 'research', 'auto_advance', true,
        'tools_disabled', false, 'input_template', v_context_gather_template
    ),
    jsonb_build_object(
        'name', 'gather', 'next', 'synthesize',
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'research', 'auto_advance', true,
        'tools_disabled', false, 'input_template', v_gather_template
    ),
    jsonb_build_object(
        'name', 'synthesize', 'next', 'review',
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'research', 'auto_advance', true,
        'tools_disabled', false, 'input_template', v_synthesize_template
    ),
    jsonb_build_object(
        'name', 'review', 'next', NULL,
        'model', 'qwen3.7-plus', 'provider', 'opencode_go',
        'agent_family', 'research', 'auto_advance', true,
        'tools_disabled', true, 'input_template', v_review_template
    )
);

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'research-write',
    'Deep-research pipeline. context_gather reads prior substrate work, gather does external search, synthesize drafts the piece, review verifies it tools-off. Uses the research agent family. Materializes to research/<slug>.md on verified.',
    v_stages,
    true,   -- sabbath_enabled (research is creative; sabbath reflection is valuable)
    true,   -- atonement_enabled
    'research/<slug>.md',
    NULL,   -- file_content_jsonpath: whole final-stage output
    '["raw","researched","planned","specced","executing","verified"]'::jsonb,
    true    -- auto_materialize_on_verified (set since H.1.6.5)
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('research-write', 'context_gather', 'qwen3.7-plus', 'Prior-work briefing; structured, not creative.'),
    ('research-write', 'gather',         'kimi-k2.6',    'External-source gather; tools enabled (exa, web_search, fetch_url, yt_*).'),
    ('research-write', 'synthesize',     'kimi-k2.6',    'Draft synthesis from gather brief; tools enabled lightly (re-fetch only).'),
    ('research-write', 'review',         'qwen3.7-plus', 'Tools-disabled verification pass.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

-- context_gather does NOT advance maturity (no row → COALESCE leaves it).
-- research skips "executing": synthesize IS the draft.
INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('research-write', 'gather',     'researched', 'Sources collected + summarized; ready for synthesis.'),
    ('research-write', 'synthesize', 'planned',    'Draft is the plan. No separate executing rung.'),
    ('research-write', 'review',     'verified',   'Review pass complete; piece is verified.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

END $seed$;

-- =====================================================================
-- planning — exploratory binding question → plan doc + proposed work_items
--   context_gather → explore → synthesize → propose_work → review_plan
-- =====================================================================
DO $seed$
DECLARE
    v_context_gather_template text;
    v_explore_template        text;
    v_synthesize_template     text;
    v_propose_work_template   text;
    v_review_plan_template    text;
    v_stages                  jsonb;
BEGIN

v_context_gather_template :=
$T$Binding question: {{input.binding_question}}

## YOUR TASK — situational awareness briefing for planning

You are gathering context from the substrate's own knowledge — prior journals, proposals, mind files, docs, and work_items — to brief the next stage (the explore stage) on what we already know about this binding question. The next stage will think about what to PLAN; your job is to give it the lay of the land.

## TOOLS

- `fs_search` / `fs_read` / `fs_list` — substrate-scoped files (journals, proposals, mind, docs, and per-pipeline-scoped project dirs if available)
- `doc_search` / `doc_get` / `doc_similar` — the substrate's docs corpus
- `work_item_list` / `work_item_show` — prior work_items on this topic or in the same project
- `watchman_pass_show` / `watchman_passes_list` — substrate state

## HARD CONSTRAINTS

- **Maximum 4 rounds of tool calls.** Spend them on the highest-signal sources first: prior plans in `/plans/` or `/projects/<project>/plans/`, recent journal entries, proposals, work_items with same `project_association`.
- **Output budget: ~2KB.** Summarize, don't transcribe.
- **End-of-turn:** your final message is the briefing in markdown, then STOP.

## OUTPUT FORMAT

```
## Prior context for: <one-line restatement of the binding question>

### What we already know
<2-4 bullets — what we've planned/built/discussed before that bears on this>

### Constraints already established
<2-3 bullets — covenants, prior decisions, ratifications relevant here>

### Gaps / open questions in our prior thinking
<2-3 bullets — what's NOT been decided that this plan must decide>

### Suggested angle for the explore stage
<1-2 sentences — where should the next stage focus its thinking>
```

If prior work is sparse, say so. The explore stage will know to start fresh.$T$;

v_explore_template :=
$T$Binding question: {{input.binding_question}}

## PRIOR CONTEXT (from context_gather stage)

{{stage_results.context_gather.output}}

## YOUR TASK — think alongside the operator

You are the *planning-partner*. Your job is NOT to produce a research artifact. Your job is to explore the question, surface assumptions, identify risks, and converge toward one strong plan. Think the way the operator would think with unlimited focus right now.

Follow the **planning-partner** intent's values:
- **Surface assumptions first.** Before any recommendation, name what you're assuming. If you can't name them, you don't understand the problem yet.
- **Ask back when underspecified.** If the binding question doesn't give enough constraint to plan well, name what's missing and propose options. "What are you optimizing for?" is a valid first move — write that down, don't invent the answer.
- **Converge.** Don't list five branches. Pick one and commit (the operator can redirect after).
- **Name risks.** Every plan has things that could go wrong. Surface them now, not later.
- **Small finishable work.** Anything you'll later propose as a follow-up work_item must be ≤2hr of work.

## TOOLS

You have the full research suite: `fs_*`, `doc_*`, `work_item_*` on the substrate side; `fetch_url` / `fetch_urls` plus any web-search tools your operator registered (`web_search_exa`, `news_search`, `yt_search`, `yt_get`) on the external side. Use external search only when prior context doesn't cover something the plan needs.

## HARD CONSTRAINTS

- **Maximum 6 rounds of tool calls total.** Most of your value is in thinking, not searching.
- **End-of-turn:** your final message is a structured exploration in markdown (see format below), then STOP. The synthesize stage takes this and turns it into the plan.

## OUTPUT FORMAT — exploration brief

```
## Exploration: <one-line binding question>

### Assumptions
<3-5 bullets — what you're assuming. Each assumption a one-liner.>

### What you'd ask back (if anything)
<0-3 bullets — questions whose answers would shape the plan. Empty if the binding is well-specified.>

### The plan you're converging toward (one option)
<3-7 sentences — the core direction. Not five branches; one plan with sub-decisions.>

### Risks
<2-4 bullets — concrete things that could go wrong. Not generic; specific to this plan.>

### Tangents you considered but rejected
<1-3 bullets — why you didn't go with X, Y, Z. Names the road-not-taken so synthesize doesn't reopen them.>
```$T$;

v_synthesize_template :=
$T$Binding question: {{input.binding_question}}

## EXPLORATION (from previous stage)

{{stage_results.explore.output}}

## YOUR TASK — write the plan document

Convert the exploration brief above into a publishable plan document. The plan will land at `projects/<project>/plans/<slug>.md` (or `plans/<slug>.md` if no project). The operator reads it; future runs read it as prior context; the substrate keeps it as a doc artifact.

## HARD CONSTRAINTS

- **No external tools.** This stage is pure writing. The explore stage already gathered.
- **End-of-turn:** your final message IS the plan document. No prose-around-the-prose.

## VOICE

Concrete, direct, unadorned. One em-dash per paragraph max. *Therefore* / *but*, not "and then." No closing refrain. No meta-narration.

## OUTPUT FORMAT — the plan document

```markdown
# <Plan title — short, derived from binding question>

**Binding question:** <restate verbatim>

**Project:** <inherited from work_item.project_association, or "—" if standalone>

**Date:** {{input.today}}

---

## The plan

<3-6 paragraphs. The one-option plan you converged on in explore.
Concrete actions, not aspirations.>

## Assumptions

<bullets — copied from exploration; reframed if synthesis surfaced
something deeper. Each assumption phrased so a future reader knows
when it'd break.>

## Risks

<bullets — concrete failure modes; mitigation if obvious, else
"watch for X" framing.>

## Next steps

<short paragraph — what gets done first, second, third. Maps to
the proposed work_items the next stage will emit.>
```$T$;

v_propose_work_template :=
$T$Binding question: {{input.binding_question}}

## THE PLAN (from synthesize stage)

{{stage_results.synthesize.output}}

## YOUR TASK — emit proposed follow-up work_items

You are the *propose_work* stage. Your output is a **JSON array** of proposed follow-up work_items. NO prose. NO markdown fences around the JSON. Just the array.

The substrate's review_plan stage (next) will validate your JSON. If invalid, the substrate revises this stage. If valid, the substrate creates each item as a `work_items` row at `maturity='raw'` with `origin='agent_planning'` and `parent_work_item_id` pointing back at this planning run. The operator ratifies (advances maturity) before they actually fire.

## SCHEMA — every array element MUST have these keys

```json
{
  "slug":                 "kebab-case-identifier",
  "binding_question":     "The actual question this work answers (verbatim, complete sentence)",
  "pipeline_family_hint": "research-write" | "planning" | null,
  "rationale":            "One sentence — why this work is worth doing"
}
```

Optional keys (omit if not applicable):
- `"project_association"`: string — inherits from parent if omitted
- `"destination_maturity"`: "researched" | "planned" | "specced" | "executing" | "verified"

## HARD CONSTRAINTS

- **Output ONLY the JSON array.** No prose intro/outro. No markdown fences. Just `[ ... ]`.
- **Maximum 3 proposed work_items — fewer, deeper, higher-leverage.** A short list of substantial, well-scoped next-steps beats a long shallow one. Pick only the ones that genuinely move the intent forward; it is fine to propose just one, or none if nothing new is warranted.
- **Do NOT re-propose work that already exists.** The plan above was briefed (council survey) on what is already proposed, in flight, or done — and on the existing studies in the pool and what they cover. Propose only genuinely NEW questions, or a *deeper* extension of an existing line (and say which it extends). A reworded version of an existing proposal/study will be rejected by the substrate's duplicate gate and wastes the slot.
- **Each work_item must be ≤2hr scope.** "Build the substrate" is not a work_item; "Add origin column to work_items" is.
- **slugs must be kebab-case** matching `^[a-z0-9-]+$`, prefixed with the parent slug or project where possible (e.g., `museum-exhibit-budget-q2`).
- **No external tools.** This stage is pure structured output.

## EXAMPLE

```json
[
  {
    "slug": "exhibit-wall-vendor-eval",
    "binding_question": "Which modular exhibit wall system (Flexhibit, CoMotion, or DIY) best fits a regional science center's 6-rotation-per-year cadence and a $50K capital budget?",
    "pipeline_family_hint": "research-write",
    "rationale": "The plan commits to a modular wall as foundation; vendor choice is the first concrete decision that gates everything else."
  },
  {
    "slug": "ai-exhibit-mvp-scope",
    "binding_question": "What's the minimum-viable AI-literacy exhibit we could build in 8 weeks with one staffer and ~$3K in materials?",
    "pipeline_family_hint": "planning",
    "rationale": "Plan identifies AI as the signature topic; need to scope a buildable MVP before fundraising or partnership talks."
  }
]
```

Your turn. Output ONLY the JSON array.$T$;

v_review_plan_template :=
$T$Binding question: {{input.binding_question}}

## THE PLAN (synthesize)

{{stage_results.synthesize.output}}

## PROPOSED WORK_ITEMS (propose_work — raw JSON)

{{stage_results.propose_work.output}}

## YOUR TASK — review the plan + the proposed work

You are the review_plan gate. Verify BOTH the plan document AND the JSON array of proposed work_items, then emit a one-line `REVIEW:` verdict (format below). The substrate uses it to decide: passes → verified maturity → trigger fires materialization + work_item proposals; revised → the plan stays at `planned` for revision with your feedback.

## CHECKS — both must pass

### A. JSON validation (propose_work output)
- Output is a valid JSON array (no prose, no markdown fences)
- Length ≤ 5
- Every element has required keys: `slug`, `binding_question`, `pipeline_family_hint`, `rationale`
- `slug` matches `^[a-z0-9-]+$` and is unique within the array
- `binding_question` is a complete sentence ending in `?`
- `pipeline_family_hint` is one of: `"research-write"`, `"planning"`, or `null`
- `rationale` is a single sentence

### B. Plan quality (synthesize output)
- Assumptions are explicitly named (not implicit)
- At least one risk is concrete (not generic "things could go wrong")
- The plan converges on ONE direction (not five branches)
- "Next steps" section maps to the proposed work_items
- Proposed work_items are each ≤2hr scope (judge from the binding_question — "Build the substrate" = revise; "Add origin column" = ok)

## HARD CONSTRAINTS

- **No external tools.** Pure verification.
- Your **first line** is the verdict the substrate gates on. It must be exactly
  `REVIEW: passes` or `REVIEW: revised` — nothing before it. (The substrate's
  review-verify gate only promotes the plan to `verified` maturity — which fires
  the work_item proposals — when the output starts with that prefix.)

## OUTPUT FORMAT

(a) If BOTH checks pass — first line exactly:

REVIEW: passes

then a blank line, then a one-line confirmation (e.g. "5 work_items, all valid; plan converges, risks named, items appropriately sized").

(b) If EITHER check fails — first line exactly:

REVIEW: revised

then a blank line, then a short, specific list of what propose_work (or synthesize) must fix. Do not output anything before the `REVIEW:` line.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object('name','context_gather','next','explore',
        'model','qwen3.7-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',false,'input_template',v_context_gather_template),
    jsonb_build_object('name','explore','next','synthesize',
        'model','kimi-k2.6','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',false,'input_template',v_explore_template),
    jsonb_build_object('name','synthesize','next','propose_work',
        'model','kimi-k2.6','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_synthesize_template),
    jsonb_build_object('name','propose_work','next','review_plan',
        'model','qwen3.7-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_propose_work_template),
    jsonb_build_object('name','review_plan','next',NULL,
        'model','qwen3.7-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_review_plan_template)
);

INSERT INTO stewards.pipelines (
    family, description, stages, metadata,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'planning',
    'Planning pipeline — converts an exploratory binding question into a plan document + a JSON array of proposed follow-up work_items. Uses the planning-partner intent. Plan materializes via auto_materialize_on_verified; proposed work_items materialize via the on_maturity_verified trigger (enqueue_proposed_work_items).',
    v_stages,
    jsonb_build_object(
        'cost_cap_default_micro', 750000,
        'cost_cap_default_dollars', 0.75,
        'note_cost_cap', 'UI/CLI should set work_items.cost_cap_micro=750000 as default when origin=human creates a planning work_item.'
    ),
    true,   -- sabbath_enabled
    true,   -- atonement_enabled
    'plans/<slug>.md',  -- fallback; compose_file_destination prefers projects/<project>/plans/<slug>.md
    NULL,   -- overridden below to stage_results.synthesize.output
    '["raw","researched","planned","specced","executing","verified"]'::jsonb,
    true    -- auto_materialize_on_verified
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    metadata                     = EXCLUDED.metadata,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

-- The plan document lives in stage_results.synthesize.output, not
-- review_plan.output (which is the verdict JSON).
UPDATE stewards.pipelines
   SET file_content_jsonpath = 'stage_results.synthesize.output'
 WHERE family = 'planning';

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity) VALUES
    ('planning', 'explore',     'researched'),
    ('planning', 'synthesize',  'planned'),
    ('planning', 'review_plan', 'verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model) VALUES
    ('planning', 'context_gather', 'qwen3.7-plus'),
    ('planning', 'explore',        'kimi-k2.6'),
    ('planning', 'synthesize',     'kimi-k2.6'),
    ('planning', 'propose_work',   'qwen3.7-plus'),
    ('planning', 'review_plan',    'qwen3.7-plus')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET default_model = EXCLUDED.default_model;

END $seed$;

-- =====================================================================
-- agent-proposal — agent submits a doc/schema-migration proposal for
--   human ratification. Single validate stage; apply_agent_proposal
--   persists on verified (i6 KIMI-TRUST GATE prompt + i7 apply form).
-- =====================================================================
DO $seed$
DECLARE
    v_validate_template text;
    v_stages            jsonb;
BEGIN

v_validate_template :=
$T$You are validating an agent-submitted proposal for a substrate artifact.

## AGENT DRAFT

```json
{{input.draft}}
```

## YOUR TASK

Read the draft. Validate and normalize it. Output ONLY a JSON object — no prose, no markdown fences.

## SCHEMA (output)

```json
{
  "source_type": "study | lesson | note | exhibit | schema-migration",
  "slug": "kebab-case-slug",
  "title": "Human-readable title (10-120 chars)",
  "body": "Full markdown body OR full SQL for schema-migration",
  "frontmatter": { /* per-source-type metadata; jsonb object */ },
  "project_association": "string slug or null",
  "rationale": "Why this proposal exists (1-3 sentences; shown in ratification UI)"
}
```

## VALIDATION RULES

- `source_type` MUST be one of: study, lesson, note, exhibit, schema-migration.
- `slug` MUST match `^[a-z0-9-]+$`. If the draft slug is malformed, fix it.
- `title` MUST be 10-120 chars. If too short, expand from body's first heading. If too long, trim.
- `body` MUST be non-empty.
- For `schema-migration`: `body` MUST start with `-- ` (SQL comment header) and contain at least one `CREATE`, `ALTER`, `INSERT`, or `CREATE OR REPLACE` statement.
- `frontmatter` MUST be a JSON object (use `{}` if no metadata).
- `project_association` is optional; pass through from draft or set null.
- `rationale` MUST be 20-500 chars. If missing, derive from body's intro.

## SCHEMA-MIGRATION CLAUDE-ATTEST GATE (i6)

For `source_type=schema-migration`, the substrate enforces a `claude_attested=true` gate at apply time: substrate-internal SQL stays Claude-only. The attestation lives on `input.draft.claude_attested` and is NOT promoted by this validate stage. Your output should preserve any draft.claude_attested value verbatim alongside the normalized fields, but the gate check reads from input.draft directly.

## ON ERROR

If the draft cannot be normalized into a valid proposal, output:
```json
{"error": "Brief reason"}
```

Output ONLY the JSON object. Your turn.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object('name','validate','next',NULL,
        'model','qwen3.7-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_validate_template)
);

INSERT INTO stewards.pipelines (
    family, description, stages, metadata,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'agent-proposal',
    'Agent submits a study/lesson/note/exhibit/schema-migration proposal. Single-stage validate pass normalizes the draft JSON. On verified, apply_agent_proposal persists to docs + queues the file write directly. The operator ratifies via the Proposed-work panel (origin filter agent_proposal). schema-migration source_type is Claude-only and lands at the extension dir as <slug>.sql.',
    v_stages,
    jsonb_build_object(
        'cost_cap_default_micro', 100000,
        'cost_cap_default_dollars', 0.10,
        'note', 'Single qwen validate pass; typical cost $0.005-0.01. apply_agent_proposal sets file_destination dynamically per source_type.'
    ),
    false,  -- sabbath_enabled
    false,  -- atonement_enabled
    NULL,   -- file_destination_template: dynamic via apply_agent_proposal
    'stage_results.validate.output',
    '["raw","verified"]'::jsonb,
    true    -- auto_materialize_on_verified
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    metadata                     = EXCLUDED.metadata,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity)
VALUES ('agent-proposal', 'validate', 'verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model)
VALUES ('agent-proposal', 'validate', 'qwen3.7-plus')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET default_model = EXCLUDED.default_model;

END $seed$;

-- =====================================================================
-- revise-proposal — AI revision of an existing proposed work_item.
--   Single revise stage; apply_revision merges into the parent on Accept.
-- =====================================================================
DO $seed$
DECLARE
    v_revise_template text;
    v_stages          jsonb;
BEGIN

v_revise_template :=
$T$You are revising a proposed work_item based on user feedback.

## ORIGINAL PROPOSAL (the work_item being revised)

- slug: {{input.original_slug}}
- binding_question: {{input.original_binding_question}}
- rationale: {{input.original_rationale}}
- pipeline_family_hint: {{input.original_pipeline_family_hint}}
- project_association: {{input.original_project_association}}

## PARENT PLANNING CONTEXT (excerpt)

{{input.parent_plan_excerpt}}

## USER FEEDBACK

{{input.feedback}}

## YOUR TASK — emit a JSON revision

Read the original + parent context + user feedback. Emit a JSON object with the REVISED fields. Only include fields you're changing — omit fields that stay the same. The substrate will merge your output into the original.

## SCHEMA

```json
{
  "binding_question":     "Revised question text (optional)",
  "rationale":            "Revised rationale, one sentence (optional)",
  "slug":                 "revised-kebab-case-slug (optional)",
  "pipeline_family_hint": "research-write | planning | null (optional)",
  "project_association":  "string or null (optional)"
}
```

## HARD CONSTRAINTS

- **Output ONLY the JSON object.** No prose intro/outro. No markdown fences.
- **Honor the user's feedback as the primary signal.** If they say "scope tighter," tighten. If they say "rephrase," rephrase. Don't second-guess.
- **Preserve fields the user didn't ask to change.** Omit them from your output.
- **slug regex: ^[a-z0-9-]+$** if you're changing it.
- **binding_question must be a complete question** ending in `?` and ≥20 chars.

## EXAMPLE

User feedback: "scope this tighter — just validate the laptop webcams, not the full ML stack"

Original binding_question: "Do all five repurposed laptops support Chrome kiosk mode and offline TensorFlow.js webcam inference without driver conflicts or privacy blocks?"

Revision:
```json
{
  "binding_question": "Do all five repurposed laptops have functional built-in webcams accessible to Chrome under a kiosk-mode user profile, ignoring ML stack validation for a later work_item?",
  "rationale": "Splits hardware compatibility from software validation so the cheaper hardware test runs first."
}
```

Your turn. Output ONLY the JSON.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object('name','revise','next',NULL,
        'model','qwen3.7-plus','provider','opencode_go','agent_family','research',
        'auto_advance',true,'tools_disabled',true,'input_template',v_revise_template)
);

INSERT INTO stewards.pipelines (
    family, description, stages, metadata,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'revise-proposal',
    'AI revision of an existing proposed work_item. Reads the original + parent plan + user feedback; emits a JSON partial revision; the UI shows a diff card with Accept/Reject. parent_work_item_id MUST be set to the proposal being revised.',
    v_stages,
    jsonb_build_object(
        'cost_cap_default_micro', 100000,
        'cost_cap_default_dollars', 0.10,
        'note', 'Single stage, qwen3.7-plus, tools off; typical cost $0.02-0.05'
    ),
    false,  -- sabbath_enabled
    false,  -- atonement_enabled
    NULL,   -- file_destination_template: no file artifact
    'stage_results.revise.output',
    '["raw","verified"]'::jsonb,
    false   -- auto_materialize_on_verified: no file write
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    metadata                     = EXCLUDED.metadata,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity)
VALUES ('revise-proposal', 'revise', 'verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model)
VALUES ('revise-proposal', 'revise', 'qwen3.7-plus')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET default_model = EXCLUDED.default_model;

END $seed$;

-- =====================================================================
-- research-summary — daily-digest (lighter research-write; no sabbath)
--   gather → synthesize → review
-- =====================================================================
INSERT INTO stewards.pipelines (
    family, description, stages, sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath, maturity_ladder,
    auto_materialize_on_verified
)
VALUES (
    'research-summary',
    'Daily-digest pipeline — a 24-hour news scan, not a deep dive. Same agent + model shape as research-write with lighter templates and sabbath/atonement off. Materializes to study/daily-digest/<slug>.md on verified.',
    jsonb_build_array(
        jsonb_build_object(
            'name',            'gather',
            'next',            'synthesize',
            'model',           'kimi-k2.6',
            'provider',        'opencode_go',
            'agent_family',    'research',
            'auto_advance',    true,
            'tools_disabled',  false,
            'input_template',
                'Binding question: {{input.binding_question}}' || E'\n\n' ||
                'You are gathering items for a DAILY DIGEST that answers the binding question above. This is not a deep research piece — it is a 24-hour news scan.' || E'\n\n' ||
                'Use the tools available (fetch_url plus any registered web search like web_search_exa, news_search, yt_*) to find 4-8 noteworthy items from the last 24 hours that bear on the binding question. Prefer primary sources (official announcements, vendor docs, the paper itself). Secondary reporting only when it adds context the primary source omits.' || E'\n\n' ||
                'For each item kept, capture:' || E'\n' ||
                '  - Title + URL + publication date/time' || E'\n' ||
                '  - One-sentence summary of what shipped or was reported' || E'\n' ||
                '  - A short verbatim quote (1-2 sentences) you might draw on in the synthesis' || E'\n' ||
                '  - Item type: official-release, news-reporting, vendor-blog, opinion-piece, social-media-thread' || E'\n\n' ||
                'The general-research intent applies — apply credibility-over-volume, skepticism-as-default, and surface-the-rhetoric. A loud headline is not evidence of a substantive change; flag rhetorical heat that isn''t backed by a concrete release or document.' || E'\n\n' ||
                'Recency is the whole point of a daily digest: items older than 48 hours need a strong justification to keep. If a story keeps trending on day 3, that itself is the news — note the trending arc, not the original event.' || E'\n\n' ||
                'Produce an items brief — a structured list of every item kept, with the four fields above. The next stage drafts the digest from this brief. Do NOT write the digest yet.'
        ),
        jsonb_build_object(
            'name',            'synthesize',
            'next',            'review',
            'model',           'kimi-k2.6',
            'provider',        'opencode_go',
            'agent_family',    'research',
            'auto_advance',    true,
            'tools_disabled',  false,
            'input_template',
                'Binding question: {{input.binding_question}}' || E'\n\n' ||
                'Items brief from the gather stage:' || E'\n\n' ||
                '{{stage_results.gather.output}}' || E'\n\n' ||
                'Now write the daily digest. Aim for 300-700 words total. This is a scan, not a deep dive — the reader will read it once and move on. If a single item warrants depth, name it and recommend a follow-up deep-research run rather than expanding inline.' || E'\n\n' ||
                'Attribution: every claim has an inline markdown link to the source it came from: [Title](URL). Paraphrase by default; quote verbatim only when you have the source text in front of you in this session.' || E'\n\n' ||
                'Structure (adapt to what the day actually produced):' || E'\n' ||
                '  - **Headlines** — the 1-3 most important items of the day, one short paragraph each' || E'\n' ||
                '  - **Notable** — second-tier items worth knowing, one-line each with link' || E'\n' ||
                '  - **Skeptical takes** — credible dissenting voices on any headline item, if any' || E'\n' ||
                '  - **Carry-forward** — what to watch for tomorrow; any deep-research candidates' || E'\n\n' ||
                'No filler. If a day produced nothing noteworthy, the digest can be three lines: "Slow news day. [link to the one minor thing]. Carry-forward: nothing." Honest emptiness beats manufactured importance.' || E'\n\n' ||
                'Produce the complete digest in markdown. The next stage reviews it.'
        ),
        jsonb_build_object(
            'name',            'review',
            'next',            NULL,
            'model',           'qwen3.7-plus',
            'provider',        'opencode_go',
            'agent_family',    'research',
            'auto_advance',    true,
            'tools_disabled',  true,
            'input_template',
                'Binding question: {{input.binding_question}}' || E'\n\n' ||
                'The digest draft from the previous stage:' || E'\n\n' ||
                '{{stage_results.synthesize.output}}' || E'\n\n' ||
                'Review the digest against four criteria:' || E'\n\n' ||
                '1. **Attribution.** Every claim has an inline link. No claims without a source. If a claim is the synthesizer''s own observation, it is named as such ("These three releases together suggest...") rather than presented as reporting.' || E'\n\n' ||
                '2. **Recency.** Every item is from within the last 24-48 hours, OR the item is explicitly framed as a "still trending" follow-up to an older event.' || E'\n\n' ||
                '3. **Rhetorical inflation.** No headline manufactured from minor news. No urgency that isn''t in the underlying source. Flag any item where the digest''s framing is hotter than the source''s.' || E'\n\n' ||
                '4. **Honest emptiness.** If the day was slow, the digest says so. No padding.' || E'\n\n' ||
                'Tools are DISABLED for this stage. You CANNOT fetch URLs — review on the digest text + its in-line links only.' || E'\n\n' ||
                'Return ONE of:' || E'\n' ||
                '(a) The same digest, verbatim and unchanged, if it passes all four criteria. Prefix with a single line: "REVIEW: passes" then a blank line then the digest.' || E'\n' ||
                '(b) A revised digest. Prefix with "REVIEW: revised" then a blank line, the revised digest, and at the end a brief notes section listing what changed and why.'
        )
    ),
    false,  -- sabbath_enabled: daily-digest is transient
    false,  -- atonement_enabled
    'study/daily-digest/<slug>.md',
    NULL,
    '["raw","researched","planned","specced","executing","verified"]'::jsonb,
    true    -- auto_materialize_on_verified
)
ON CONFLICT (family) DO UPDATE SET
    description                  = EXCLUDED.description,
    stages                       = EXCLUDED.stages,
    sabbath_enabled              = EXCLUDED.sabbath_enabled,
    atonement_enabled            = EXCLUDED.atonement_enabled,
    file_destination_template    = EXCLUDED.file_destination_template,
    file_content_jsonpath        = EXCLUDED.file_content_jsonpath,
    maturity_ladder              = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at                   = now();

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('research-summary', 'gather',     'kimi-k2.6',    'Daily-digest source gather; tools enabled. 24-hour scan.'),
    ('research-summary', 'synthesize', 'kimi-k2.6',    'Daily-digest synthesis from gather brief; 300-700 word target.'),
    ('research-summary', 'review',     'qwen3.7-plus', 'Tools-disabled verification pass.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('research-summary', 'gather',     'researched', 'Items collected + summarized; ready for synthesis.'),
    ('research-summary', 'synthesize', 'planned',    'Draft is the plan. No separate executing rung.'),
    ('research-summary', 'review',     'verified',   'Review pass complete; digest is verified and auto-materializes.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

-- =====================================================================
-- binding_question_overlap — a cheap, generic near-duplicate signal: the
-- Jaccard overlap of the two questions' SIGNIFICANT words (lowercased, length
-- >= 4, minus a small generic-English stoplist). No pg_trgm / no extension dep
-- (keeps the vector-only invariant). 0 = disjoint, 1 = same word set. The
-- council survey is the soft nudge; the enqueue gate (below) uses this as the
-- hard floor so a cold-start planner cannot re-enqueue a reworded duplicate.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.binding_question_overlap(p_a text, p_b text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $bq$
    WITH stop(w) AS (VALUES
        ('what'),('does'),('what''s'),('with'),('that'),('this'),('their'),('they'),
        ('from'),('have'),('about'),('would'),('which'),('when'),('where'),('there'),
        ('these'),('those'),('into'),('over'),('your'),('been'),('such'),('than'),
        ('then'),('them'),('also'),('most'),('more'),('only'),('some'),('upon'),
        ('across'),('based'),('specific'),('specifically'),('public'),('publicly'),
        ('include'),('including')),
    -- strip a trailing 's' (cheap singular/plural fold: complaints->complaint,
    -- reviews->review, customers->customer) so the common drift still matches.
    wa AS (SELECT DISTINCT regexp_replace(t, 's$', '') AS t
             FROM regexp_split_to_table(lower(coalesce(p_a,'')), '[^a-z0-9'']+') t
            WHERE length(t) >= 4 AND t NOT IN (SELECT w FROM stop)),
    wb AS (SELECT DISTINCT regexp_replace(t, 's$', '') AS t
             FROM regexp_split_to_table(lower(coalesce(p_b,'')), '[^a-z0-9'']+') t
            WHERE length(t) >= 4 AND t NOT IN (SELECT w FROM stop)),
    u  AS (SELECT t FROM wa UNION SELECT t FROM wb),
    i  AS (SELECT t FROM wa INTERSECT SELECT t FROM wb)
    SELECT CASE WHEN (SELECT count(*) FROM u) = 0 THEN 0
                ELSE round((SELECT count(*) FROM i)::numeric / (SELECT count(*) FROM u), 3) END
$bq$;
COMMENT ON FUNCTION stewards.binding_question_overlap(text, text) IS
'Jaccard overlap of two questions'' significant words (len>=4, minus a generic stoplist). The deterministic near-duplicate signal the enqueue gate uses so reworded re-proposals are dropped regardless of model behavior. Generic — domain words are kept as signal; the distinctive nouns dominate.';

-- the gate''s threshold — operator-tunable without a rebuild (the watchman-guard pattern).
SELECT stewards.config_set('reflect_dedup_overlap_threshold', '0.5'::jsonb,
    'enqueue_proposed_work_items drops a proposed work_item whose binding_question has >= this Jaccard word-overlap (significant words, singular/plural-folded) with an existing non-terminal proposal for the same intent. 0.5 default = catches verbatim re-proposals AND moderate rewordings (a real reworded pair scores ~0.57) while sparing genuinely distinct angles (~0.1-0.3). Higher = stricter (fewer drops); lower = more aggressive; 0 disables.');

-- =====================================================================
-- enqueue_proposed_work_items (h3-5) — called by 08's on_maturity_verified
-- planning branch (wrapped forward ref). Reads a planning work_item's
-- propose_work.output JSON array; inserts each proposed work_item.
-- 2026-06-16: + a deterministic near-duplicate gate (binding_question_overlap)
-- so the planner can't re-enqueue work already pending/in-flight for the intent.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.enqueue_proposed_work_items(p_work_item_id uuid)
RETURNS int
LANGUAGE plpgsql
AS $func$
DECLARE
    v_wi              stewards.work_items%ROWTYPE;
    v_raw_output      text;
    v_clean_output    text;
    v_json            jsonb;
    v_item            jsonb;
    v_slug            text;
    v_binding         text;
    v_rationale       text;
    v_hint            text;
    v_project         text;
    v_dest_maturity   text;
    v_target_pipeline text;
    v_first_stage     text;
    v_inserted        int := 0;
    v_skipped         int := 0;
    v_reason          text;
    v_threshold       numeric;
    v_dup_slug        text;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE NOTICE 'enqueue_proposed_work_items: work_item % not found', p_work_item_id;
        RETURN 0;
    END IF;

    v_threshold := COALESCE(NULLIF(stewards.config_get_text('reflect_dedup_overlap_threshold','0.5'),'')::numeric, 0.5);

    -- Only planning-family work_items emit proposed work.
    IF v_wi.pipeline_family <> 'planning' THEN
        RETURN 0;
    END IF;

    v_raw_output := (v_wi.stage_results -> 'propose_work' -> 'output') #>> '{}';
    IF v_raw_output IS NULL OR length(trim(v_raw_output)) = 0 THEN
        RAISE NOTICE 'enqueue_proposed_work_items: empty propose_work.output for work_item %', p_work_item_id;
        RETURN 0;
    END IF;

    -- Strip optional markdown code fences.
    v_clean_output := regexp_replace(
        v_raw_output,
        E'^\\s*```(?:json)?\\s*\\n?|\\n?```\\s*$',
        '',
        'g'
    );
    v_clean_output := trim(v_clean_output);

    BEGIN
        v_json := v_clean_output::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'enqueue_proposed_work_items: JSON parse failed for work_item %: %', p_work_item_id, SQLERRM;
        RETURN 0;
    END;

    IF jsonb_typeof(v_json) <> 'array' THEN
        RAISE NOTICE 'enqueue_proposed_work_items: top-level JSON is %, expected array (work_item %)',
            jsonb_typeof(v_json), p_work_item_id;
        RETURN 0;
    END IF;

    FOR v_item IN SELECT * FROM jsonb_array_elements(v_json)
    LOOP
        v_reason := NULL;

        v_slug      := v_item ->> 'slug';
        v_binding   := v_item ->> 'binding_question';
        v_rationale := v_item ->> 'rationale';
        v_hint      := v_item ->> 'pipeline_family_hint';

        IF v_slug IS NULL OR v_slug !~ '^[a-z0-9-]+$' THEN
            v_reason := format('invalid slug: %s', COALESCE(v_slug, '(null)'));
        ELSIF v_binding IS NULL OR length(trim(v_binding)) < 20 THEN
            v_reason := format('binding_question too short or missing for slug=%s (need ≥20 chars)', v_slug);
        ELSIF v_rationale IS NULL OR length(trim(v_rationale)) < 10 THEN
            v_reason := format('rationale missing or too short for slug=%s (need ≥10 chars)', v_slug);
        END IF;

        v_project       := COALESCE(v_item ->> 'project_association', v_wi.project_association);
        v_dest_maturity := v_item ->> 'destination_maturity';

        v_target_pipeline := NULL;
        v_first_stage := NULL;
        IF v_hint IS NOT NULL AND v_hint <> '' AND v_hint <> 'null' THEN
            IF EXISTS (SELECT 1 FROM stewards.pipelines WHERE family = v_hint) THEN
                v_target_pipeline := v_hint;
                v_first_stage := stewards.pipeline_first_stage_name(v_hint);
            ELSE
                RAISE NOTICE 'enqueue_proposed_work_items: unknown pipeline_family_hint=% for slug=%; inserting as proposal-only',
                    v_hint, v_slug;
            END IF;
        END IF;

        IF v_reason IS NOT NULL THEN
            RAISE NOTICE 'enqueue_proposed_work_items: skipping element: %', v_reason;
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        IF EXISTS (SELECT 1 FROM stewards.work_items WHERE slug = v_slug) THEN
            RAISE NOTICE 'enqueue_proposed_work_items: slug=% already exists, skipping', v_slug;
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        -- Near-duplicate gate (2026-06-16): drop a proposal that overlaps an
        -- existing NON-TERMINAL proposal for the same intent above the threshold.
        -- Exact-slug above only catches identical slugs; this catches reworded
        -- re-proposals (the cold-start failure mode) — deterministic, not the
        -- planner's goodwill. threshold=0 disables it.
        IF v_threshold > 0 THEN
            SELECT w.slug INTO v_dup_slug
              FROM stewards.work_items w
             WHERE w.intent_id = v_wi.intent_id
               AND w.origin = 'agent_planning'
               AND w.status IN ('pending','in_progress','awaiting_review')
               AND w.id <> p_work_item_id
               AND stewards.binding_question_overlap(w.input->>'binding_question', v_binding) >= v_threshold
             ORDER BY w.created_at DESC
             LIMIT 1;
            IF v_dup_slug IS NOT NULL THEN
                RAISE NOTICE 'enqueue_proposed_work_items: slug=% is a near-duplicate of pending/in-flight % (overlap>=%), skipping',
                    v_slug, v_dup_slug, v_threshold;
                v_skipped := v_skipped + 1;
                CONTINUE;
            END IF;
        END IF;

        -- If no target pipeline resolved, park under planning with a
        -- non-dispatchable stage so it shows in the UI but can't run.
        IF v_target_pipeline IS NULL THEN
            v_target_pipeline := 'planning';
            v_first_stage     := '__proposal_only';
        END IF;

        INSERT INTO stewards.work_items (
            slug, pipeline_family, current_stage, input, actor,
            intent_id, origin, parent_work_item_id, project_association,
            destination_maturity
        )
        VALUES (
            v_slug, v_target_pipeline, v_first_stage,
            jsonb_build_object(
                'binding_question', v_binding,
                'rationale_from_planning', v_rationale,
                'proposed_by_work_item_id', v_wi.id::text,
                'proposed_by_slug', v_wi.slug,
                'today', to_char(current_date, 'YYYY-MM-DD')
            ),
            'agent',
            v_wi.intent_id,   -- inherit; operator can swap at ratification
            'agent_planning',
            v_wi.id,
            v_project,
            v_dest_maturity
        );

        v_inserted := v_inserted + 1;
    END LOOP;

    RAISE NOTICE 'enqueue_proposed_work_items: work_item=% inserted=% skipped=%',
        p_work_item_id, v_inserted, v_skipped;
    RETURN v_inserted;
END;
$func$;

COMMENT ON FUNCTION stewards.enqueue_proposed_work_items(uuid) IS
'h3-5 (13-research-pipelines): reads a planning work_item''s stage_results.propose_work.output JSON array and inserts each proposed work_item with origin=agent_planning, parent_work_item_id pointing back, and intent inherited. Malformed elements are skipped with NOTICE (not raised) so the calling trigger remains non-throwing. Called by on_maturity_verified''s planning branch (08, wrapped).';

-- =====================================================================
-- apply_agent_proposal (i7 final — incl. i6 claude_attested gate).
-- Queues pending_file_writes DIRECTLY with the validated body as content
-- (bypassing extract_work_item_file_content, which would return the JSON
-- wrapper), sets file_enqueued_at so on_maturity_verified's enqueue path
-- is a no-op. Scoped to the agent-proposal pipeline. Called by 08's
-- on_maturity_verified agent-proposal branch (wrapped forward ref).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.apply_agent_proposal(p_work_item_id uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $func$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_raw         text;
    v_clean       text;
    v_json        jsonb;
    v_source_type text;
    v_slug        text;
    v_title       text;
    v_body        text;
    v_frontmatter jsonb;
    v_project     text;
    v_rationale   text;
    v_file_dest   text;
    v_existing_id text;
    v_claude_attested boolean;
    v_pwid        bigint;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE NOTICE 'apply_agent_proposal: work_item % not found', p_work_item_id;
        RETURN false;
    END IF;
    IF v_wi.pipeline_family <> 'agent-proposal' THEN
        RAISE NOTICE 'apply_agent_proposal: work_item % is not agent-proposal (family=%)',
            p_work_item_id, v_wi.pipeline_family;
        RETURN false;
    END IF;
    IF v_wi.agent_proposal_applied_at IS NOT NULL THEN
        RAISE NOTICE 'apply_agent_proposal: already applied at %', v_wi.agent_proposal_applied_at;
        RETURN false;
    END IF;

    v_raw := (v_wi.stage_results -> 'validate' -> 'output') #>> '{}';
    IF v_raw IS NULL OR length(trim(v_raw)) = 0 THEN
        RAISE NOTICE 'apply_agent_proposal: validate.output is empty';
        RETURN false;
    END IF;

    v_clean := regexp_replace(v_raw, E'^\\s*```(?:json)?\\s*\\n?|\\n?```\\s*$', '', 'g');
    v_clean := trim(v_clean);

    BEGIN
        v_json := v_clean::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'apply_agent_proposal: JSON parse failed: %', SQLERRM;
        RETURN false;
    END;

    IF v_json ? 'error' THEN
        RAISE NOTICE 'apply_agent_proposal: validator returned error: %', v_json->>'error';
        RETURN false;
    END IF;

    v_source_type := v_json ->> 'source_type';
    v_slug        := v_json ->> 'slug';
    v_title       := v_json ->> 'title';
    v_body        := v_json ->> 'body';
    v_frontmatter := COALESCE(v_json -> 'frontmatter', '{}'::jsonb);
    v_project     := v_json ->> 'project_association';
    v_rationale   := v_json ->> 'rationale';

    IF v_source_type IS NULL OR v_source_type NOT IN ('study','lesson','note','exhibit','schema-migration') THEN
        RAISE NOTICE 'apply_agent_proposal: invalid source_type %', v_source_type;
        RETURN false;
    END IF;
    IF v_slug IS NULL OR v_slug !~ '^[a-z0-9-]+$' THEN
        RAISE NOTICE 'apply_agent_proposal: invalid slug %', v_slug;
        RETURN false;
    END IF;
    IF v_title IS NULL OR length(v_title) < 10 OR length(v_title) > 120 THEN
        RAISE NOTICE 'apply_agent_proposal: invalid title length: %', coalesce(length(v_title), 0);
        RETURN false;
    END IF;
    IF v_body IS NULL OR length(trim(v_body)) = 0 THEN
        RAISE NOTICE 'apply_agent_proposal: empty body';
        RETURN false;
    END IF;

    -- i6: schema-migration claude_attested gate (reads input.draft directly;
    -- the validate stage cannot promote attestation).
    IF v_source_type = 'schema-migration' THEN
        v_claude_attested := COALESCE(
            (v_wi.input -> 'draft' ->> 'claude_attested')::boolean,
            false
        );
        IF v_claude_attested <> true THEN
            RAISE NOTICE 'apply_agent_proposal: schema-migration requires input.draft.claude_attested=true (substrate-internal SQL stays Claude-only); got %',
                v_wi.input -> 'draft' ->> 'claude_attested';
            RETURN false;
        END IF;
    END IF;

    v_file_dest := CASE v_source_type
        WHEN 'study'            THEN 'study/' || v_slug || '.md'
        WHEN 'lesson'           THEN 'lessons/' || v_slug || '.md'
        WHEN 'note'             THEN 'becoming/notes/' || v_slug || '.md'
        WHEN 'exhibit'          THEN 'exhibits/' || v_slug || '.md'
        WHEN 'schema-migration' THEN 'projects/pg-ai-stewards/extension/' || v_slug || '.sql'
    END;

    IF v_source_type IN ('study','lesson','note','exhibit') THEN
        SELECT id INTO v_existing_id
          FROM stewards.docs
         WHERE kind = v_source_type AND slug = v_slug
         LIMIT 1;
        IF v_existing_id IS NOT NULL THEN
            RAISE NOTICE 'apply_agent_proposal: (kind=%, slug=%) already exists as doc id=%',
                v_source_type, v_slug, v_existing_id;
            RETURN false;
        END IF;

        v_frontmatter := v_frontmatter
                      || jsonb_build_object(
                            'source_type', v_source_type,
                            'origin', 'agent_proposal',
                            'proposed_by_work_item_id', p_work_item_id::text,
                            'rationale', v_rationale
                         );

        INSERT INTO stewards.docs (slug, title, body, kind, frontmatter, project_association, file_path)
        VALUES (v_slug, v_title, v_body, v_source_type, v_frontmatter, v_project, v_file_dest);

    ELSIF v_source_type = 'schema-migration' THEN
        RAISE NOTICE 'apply_agent_proposal: schema-migration; queueing file at %', v_file_dest;
    END IF;

    -- i7: queue pending_file_writes DIRECTLY with the body as content,
    -- bypassing enqueue_work_item_file's extract (which would return the
    -- full JSON wrapper).
    INSERT INTO stewards.pending_file_writes
        (requested_by, target_path, write_mode, content, source_id, source_kind)
    VALUES
        ('apply_agent_proposal', v_file_dest, 'create', v_body,
         p_work_item_id::text, 'work_item')
    RETURNING id INTO v_pwid;

    -- Set file_destination AND file_enqueued_at so on_maturity_verified's
    -- subsequent enqueue path becomes a no-op (its guard is file_enqueued_at IS NULL).
    UPDATE stewards.work_items
       SET file_destination          = v_file_dest,
           file_enqueued_at          = now(),
           agent_proposal_applied_at = now(),
           updated_at                = now()
     WHERE id = p_work_item_id;

    RAISE NOTICE 'apply_agent_proposal: persisted source_type=% slug=% body_len=% pwid=% file_dest=%',
        v_source_type, v_slug, length(v_body), v_pwid, v_file_dest;
    RETURN true;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_agent_proposal(uuid) IS
'i4/i6/i7 (13-research-pipelines): persists a verified agent-proposal work_item. Parses stage_results.validate.output, validates schema + the i6 claude_attested gate (schema-migration), INSERTs into docs for study/lesson/note/exhibit, then queues pending_file_writes DIRECTLY with the validated body as content (i7 — bypasses the JSON-wrapper bug) and sets file_enqueued_at so the subsequent on_maturity_verified enqueue path is a no-op. Idempotent via agent_proposal_applied_at. Called by on_maturity_verified''s agent-proposal branch (08, wrapped).';

-- =====================================================================
-- apply_revision (h3-followup-3) — merge a completed revise-proposal
-- work_item into its parent (the original proposal). UI-invoked.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.apply_revision(p_revise_work_item_id uuid)
RETURNS boolean
LANGUAGE plpgsql
AS $func$
DECLARE
    v_revise   stewards.work_items%ROWTYPE;
    v_original stewards.work_items%ROWTYPE;
    v_raw      text;
    v_clean    text;
    v_json     jsonb;
    v_new_slug text;
    v_new_binding text;
    v_new_rationale text;
    v_new_hint text;
    v_new_project text;
BEGIN
    SELECT * INTO v_revise FROM stewards.work_items WHERE id = p_revise_work_item_id;
    IF v_revise.id IS NULL THEN
        RAISE NOTICE 'apply_revision: revise work_item % not found', p_revise_work_item_id;
        RETURN false;
    END IF;
    IF v_revise.pipeline_family <> 'revise-proposal' THEN
        RAISE NOTICE 'apply_revision: work_item % is not a revise-proposal (family=%)',
            p_revise_work_item_id, v_revise.pipeline_family;
        RETURN false;
    END IF;
    IF v_revise.revision_applied_at IS NOT NULL THEN
        RAISE NOTICE 'apply_revision: revision already applied at %', v_revise.revision_applied_at;
        RETURN false;
    END IF;
    IF v_revise.status = 'cancelled' THEN
        RAISE NOTICE 'apply_revision: revision was rejected (status=cancelled)';
        RETURN false;
    END IF;
    IF v_revise.parent_work_item_id IS NULL THEN
        RAISE NOTICE 'apply_revision: revision % has no parent_work_item_id', p_revise_work_item_id;
        RETURN false;
    END IF;

    SELECT * INTO v_original FROM stewards.work_items WHERE id = v_revise.parent_work_item_id;
    IF v_original.id IS NULL THEN
        RAISE NOTICE 'apply_revision: parent (original) work_item % not found', v_revise.parent_work_item_id;
        RETURN false;
    END IF;

    v_raw := (v_revise.stage_results -> 'revise' -> 'output') #>> '{}';
    IF v_raw IS NULL OR length(trim(v_raw)) = 0 THEN
        RAISE NOTICE 'apply_revision: revise.output is empty';
        RETURN false;
    END IF;

    v_clean := regexp_replace(v_raw, E'^\\s*```(?:json)?\\s*\\n?|\\n?```\\s*$', '', 'g');
    v_clean := trim(v_clean);

    BEGIN
        v_json := v_clean::jsonb;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'apply_revision: JSON parse failed: %', SQLERRM;
        RETURN false;
    END;

    v_new_slug      := v_json ->> 'slug';
    v_new_binding   := v_json ->> 'binding_question';
    v_new_rationale := v_json ->> 'rationale';
    v_new_hint      := v_json ->> 'pipeline_family_hint';
    v_new_project   := v_json ->> 'project_association';

    IF v_new_slug IS NOT NULL THEN
        IF v_new_slug !~ '^[a-z0-9-]+$' THEN
            RAISE NOTICE 'apply_revision: invalid slug %', v_new_slug;
            RETURN false;
        END IF;
        IF EXISTS (
            SELECT 1 FROM stewards.work_items
             WHERE slug = v_new_slug AND id <> v_original.id
        ) THEN
            RAISE NOTICE 'apply_revision: slug % already in use', v_new_slug;
            RETURN false;
        END IF;
    END IF;
    IF v_new_binding IS NOT NULL AND length(trim(v_new_binding)) < 20 THEN
        RAISE NOTICE 'apply_revision: binding_question too short';
        RETURN false;
    END IF;

    -- "null" string = explicit clear-hint.
    IF v_new_hint IS NOT NULL AND v_new_hint = 'null' THEN
        v_new_hint := NULL;
    END IF;

    UPDATE stewards.work_items
       SET slug            = COALESCE(v_new_slug, slug),
           input           = input
                          || COALESCE(
                               CASE WHEN v_new_binding IS NOT NULL
                                    THEN jsonb_build_object('binding_question', v_new_binding)
                                    ELSE NULL END,
                               '{}'::jsonb)
                          || COALESCE(
                               CASE WHEN v_new_rationale IS NOT NULL
                                    THEN jsonb_build_object('rationale_from_planning', v_new_rationale)
                                    ELSE NULL END,
                               '{}'::jsonb),
           pipeline_family = CASE
                                WHEN v_new_hint IS NOT NULL AND EXISTS (
                                    SELECT 1 FROM stewards.pipelines WHERE family = v_new_hint
                                ) THEN v_new_hint
                                ELSE pipeline_family
                             END,
           current_stage   = CASE
                                WHEN v_new_hint IS NOT NULL AND EXISTS (
                                    SELECT 1 FROM stewards.pipelines WHERE family = v_new_hint
                                ) THEN stewards.pipeline_first_stage_name(v_new_hint)
                                ELSE current_stage
                             END,
           project_association = CASE
                                    WHEN v_json ? 'project_association'
                                        THEN v_new_project
                                    ELSE project_association
                                END,
           updated_at      = now()
     WHERE id = v_original.id;

    UPDATE stewards.work_items
       SET revision_applied_at = now(),
           updated_at = now()
     WHERE id = p_revise_work_item_id;

    RAISE NOTICE 'apply_revision: applied revision % to original %',
        p_revise_work_item_id, v_original.id;
    RETURN true;
END;
$func$;

COMMENT ON FUNCTION stewards.apply_revision(uuid) IS
'h3-followup-3 (13-research-pipelines): applies a completed revise-proposal work_item to its parent (the original proposal). Validates schema, UPDATEs the original with non-null revision fields (COALESCE preserves unchanged values), marks the revise work_item with revision_applied_at. Idempotent — re-call after applied returns false.';
