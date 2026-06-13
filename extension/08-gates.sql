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
    v_gate_model      text := 'qwen3.6-plus';
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
    v_gate_model      text := 'qwen3.6-plus';
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
