-- =====================================================================
-- 101-lab-dispatch.sql — the Lab's experiment runner (the increment 87
-- deferred: "Dispatch (randomized interleave as tagged work items) is
-- future work").
-- =====================================================================
-- experiment_run(name, subject) turns a declared experiment into real,
-- tagged work_items: every variant × n_per_variant, dispatched in ONE
-- randomized interleave (not blocked runs) so rig drift doesn't confound.
-- A variant (or the experiment's `dispatch` default) names the pipeline
-- executor; there is deliberately only ONE executor kind — the work_item
-- — because every run substrate we compare (native tool loop, harness_run
-- via loom, fan-out panels) is already reachable as a pipeline family.
--
-- Subject templating: any top-level string value in the merged input that
-- contains the literal token {SUBJECT} gets it replaced with
-- p_subject->>'subject'. This is how one experiment definition runs
-- against many subjects (variants carry the framing; the subject is the
-- thing framed).
--
-- experiment_harvest(name) back-fills metrics_observed on terminal runs
-- from the ledgers we already keep (status, duration, tokens, rounds) —
-- deterministic counting, no model tallies. experiment_report(name)
-- harvests then aggregates per-variant: honest n + spread, no p-value
-- theater (the 87/proposal rule).
--
-- requires: create_schedule_chat (100) — tail of the chain.
-- Tables touched: experiments (new `dispatch` column), experiment_runs
-- (rows), work_items (creation via the standard verbs), tool_defs +
-- agent_tool_perms (chat can drive the lab).
-- =====================================================================

-- §1 — experiments.dispatch: the experiment-level executor default a
-- variant may override key-by-key (pipeline_family / model / provider /
-- input).
ALTER TABLE stewards.experiments
    ADD COLUMN IF NOT EXISTS dispatch jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN stewards.experiments.dispatch IS
'101: executor defaults — {"pipeline_family": ..., "input": {...}}. Each variant object may override any key (its own pipeline_family/model/provider/input); variant input merges OVER dispatch input. The only executor kind is the work_item: every substrate we compare is already a pipeline family.';

-- §2 — experiment_run: variants × n, one randomized interleave, tagged
-- work items, one experiment_runs row per trial.
CREATE OR REPLACE FUNCTION stewards.experiment_run(
    p_name    text,
    p_subject jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(run_id bigint, variant text, work_item_id uuid)
LANGUAGE plpgsql
AS $func$
DECLARE
    v_exp      stewards.experiments%ROWTYPE;
    v_trial    record;
    v_cfg      jsonb;
    v_family   text;
    v_input    jsonb;
    v_subject  text;
    v_key      text;
    v_val      jsonb;
    v_wi       uuid;
    v_run      bigint;
BEGIN
    SELECT * INTO v_exp FROM stewards.experiments WHERE name = p_name;
    IF v_exp.id IS NULL THEN
        RAISE EXCEPTION 'experiment %: not found (see stewards.experiments)', p_name;
    END IF;
    IF v_exp.status <> 'active' THEN
        RAISE EXCEPTION 'experiment %: status is % — only active experiments run', p_name, v_exp.status;
    END IF;

    v_subject := coalesce(p_subject->>'subject', '');

    -- The whole trial list (variants × n) in ONE randomized interleave.
    FOR v_trial IN
        SELECT elem AS cfg, elem->>'variant' AS vname
          FROM jsonb_array_elements(v_exp.variants) elem,
               generate_series(1, greatest(v_exp.n_per_variant, 1))
         ORDER BY random()
    LOOP
        v_cfg    := v_trial.cfg;
        v_family := coalesce(v_cfg->>'pipeline_family', v_exp.dispatch->>'pipeline_family');
        IF v_family IS NULL THEN
            RAISE EXCEPTION 'experiment % variant %: no pipeline_family (set experiments.dispatch or the variant)', p_name, v_trial.vname;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family = v_family) THEN
            RAISE EXCEPTION 'experiment % variant %: pipeline_family % not installed', p_name, v_trial.vname, v_family;
        END IF;

        -- input = dispatch defaults <- variant input <- subject extras,
        -- then the experiment tags (always win).
        v_input := coalesce(v_exp.dispatch->'input', '{}'::jsonb)
                || coalesce(v_cfg->'input', '{}'::jsonb)
                || (p_subject - 'subject');

        -- {SUBJECT} templating across top-level string values.
        FOR v_key, v_val IN SELECT * FROM jsonb_each(v_input) LOOP
            IF jsonb_typeof(v_val) = 'string' AND (v_val #>> '{}') LIKE '%{SUBJECT}%' THEN
                v_input := jsonb_set(v_input, ARRAY[v_key],
                                     to_jsonb(replace(v_val #>> '{}', '{SUBJECT}', v_subject)));
            END IF;
        END LOOP;

        v_input := v_input || jsonb_build_object(
            '_experiment',    v_exp.name,
            '_experiment_id', v_exp.id,
            '_variant',       v_trial.vname);

        v_wi := stewards.work_item_create(v_family, v_input, NULL, 'lab', NULL, NULL);

        -- Variant model/provider pin rides the standard override columns
        -- (the same lever the Stewdio retry uses; beats the stage pin
        -- with a NOTICE).
        UPDATE stewards.work_items
           SET model_override    = coalesce(v_cfg->>'model',    model_override),
               provider_override = coalesce(v_cfg->>'provider', provider_override)
         WHERE id = v_wi
           AND (v_cfg ? 'model' OR v_cfg ? 'provider');

        INSERT INTO stewards.experiment_runs (experiment_id, variant, work_item_id)
        VALUES (v_exp.id, v_trial.vname, v_wi)
        RETURNING id INTO v_run;

        PERFORM stewards.work_item_dispatch_stage(v_wi, NULL, true);

        run_id := v_run; variant := v_trial.vname; work_item_id := v_wi;
        RETURN NEXT;
    END LOOP;
END;
$func$;

COMMENT ON FUNCTION stewards.experiment_run(text, jsonb) IS
'101: dispatch an active experiment — every variant × n_per_variant as tagged work_items in one randomized interleave. p_subject: {"subject": "<text substituted into {SUBJECT} slots>", ...extra input keys}. Returns (run_id, variant, work_item_id) per trial.';

-- §3 — experiment_harvest: deterministic metric back-fill for terminal
-- runs. Counts from the ledgers, never from model output.
CREATE OR REPLACE FUNCTION stewards.experiment_harvest(p_name text)
RETURNS int
LANGUAGE plpgsql
AS $func$
DECLARE
    v_exp_id bigint;
    v_n      int := 0;
    v_r      record;
    v_wi     stewards.work_items%ROWTYPE;
    v_rounds int;
BEGIN
    SELECT id INTO v_exp_id FROM stewards.experiments WHERE name = p_name;
    IF v_exp_id IS NULL THEN
        RAISE EXCEPTION 'experiment %: not found', p_name;
    END IF;

    FOR v_r IN
        SELECT r.id, r.work_item_id
          FROM stewards.experiment_runs r
         WHERE r.experiment_id = v_exp_id
           AND r.metrics_observed = '{}'::jsonb
           AND r.work_item_id IS NOT NULL
    LOOP
        SELECT * INTO v_wi FROM stewards.work_items WHERE id = v_r.work_item_id;
        CONTINUE WHEN v_wi.id IS NULL
                   OR v_wi.status NOT IN ('completed', 'failed', 'cancelled', 'awaiting_review');

        SELECT count(*) INTO v_rounds
          FROM stewards.work_queue q
         WHERE q.kind = 'chat'
           AND q.payload->>'_work_item_id' = v_wi.id::text;

        UPDATE stewards.experiment_runs
           SET metrics_observed = jsonb_build_object(
                   'status',     v_wi.status,
                   'duration_s', round(extract(epoch FROM (coalesce(v_wi.completed_at, v_wi.updated_at) - v_wi.created_at))::numeric, 1),
                   'tokens_in',  v_wi.tokens_in,
                   'tokens_out', v_wi.tokens_out,
                   'rounds',     v_rounds)
         WHERE id = v_r.id;
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END;
$func$;

COMMENT ON FUNCTION stewards.experiment_harvest(text) IS
'101: back-fill metrics_observed for terminal, unharvested runs — status / duration_s / tokens_in / tokens_out / rounds, counted from work_items + work_queue. Returns how many runs it filled. Idempotent (skips already-harvested rows).';

-- §4 — experiment_report: harvest, then per-variant honest numbers.
CREATE OR REPLACE FUNCTION stewards.experiment_report(p_name text)
RETURNS jsonb
LANGUAGE plpgsql
AS $func$
DECLARE
    v_exp stewards.experiments%ROWTYPE;
    v_out jsonb;
BEGIN
    SELECT * INTO v_exp FROM stewards.experiments WHERE name = p_name;
    IF v_exp.id IS NULL THEN
        RAISE EXCEPTION 'experiment %: not found', p_name;
    END IF;

    PERFORM stewards.experiment_harvest(p_name);

    SELECT jsonb_build_object(
        'experiment', v_exp.name,
        'hypothesis', v_exp.hypothesis,
        'status',     v_exp.status,
        'variants',   coalesce(jsonb_agg(v.summary ORDER BY v.variant), '[]'::jsonb))
      INTO v_out
      FROM (
        SELECT g.variant,
               jsonb_build_object(
                   'variant',    g.variant,
                   'n',          g.n,
                   'n_terminal', g.n_terminal,
                   'statuses', (
                       SELECT coalesce(jsonb_object_agg(s.status, s.cnt), '{}'::jsonb)
                         FROM (SELECT r2.metrics_observed->>'status' AS status, count(*) AS cnt
                                 FROM stewards.experiment_runs r2
                                WHERE r2.experiment_id = v_exp.id
                                  AND r2.variant = g.variant
                                  AND r2.metrics_observed ? 'status'
                                GROUP BY 1) s),
                   'metrics', (
                       SELECT coalesce(jsonb_object_agg(m.key, jsonb_build_object(
                                  'avg', m.avg_v, 'min', m.min_v, 'max', m.max_v)), '{}'::jsonb)
                         FROM (SELECT kv.key,
                                      round(avg((kv.value #>> '{}')::numeric), 1) AS avg_v,
                                      min((kv.value #>> '{}')::numeric)           AS min_v,
                                      max((kv.value #>> '{}')::numeric)           AS max_v
                                 FROM stewards.experiment_runs r3,
                                      jsonb_each(r3.metrics_observed) kv
                                WHERE r3.experiment_id = v_exp.id
                                  AND r3.variant = g.variant
                                  AND jsonb_typeof(kv.value) = 'number'
                                GROUP BY kv.key) m),
                   'work_items', (
                       SELECT coalesce(jsonb_agg(r4.work_item_id), '[]'::jsonb)
                         FROM stewards.experiment_runs r4
                        WHERE r4.experiment_id = v_exp.id AND r4.variant = g.variant)
               ) AS summary
          FROM (SELECT r.variant, count(*) AS n,
                       count(*) FILTER (WHERE r.metrics_observed <> '{}'::jsonb) AS n_terminal
                  FROM stewards.experiment_runs r
                 WHERE r.experiment_id = v_exp.id
                 GROUP BY r.variant) g
      ) v;

    RETURN v_out;
END;
$func$;

COMMENT ON FUNCTION stewards.experiment_report(text) IS
'101: harvest then aggregate — per-variant n, terminal count, status tally, avg/min/max of every numeric metric, and the work_item ids (so a human or a stronger judge can read the actual outputs). Honest small-n numbers; judgment stays with the reader.';

-- §5 — chat can drive the lab (the same sql_fn tool + perms convention
-- as 87/100).
CREATE OR REPLACE FUNCTION stewards.experiment_run_tool(p_args jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $func$
DECLARE
    v_rows jsonb;
BEGIN
    IF coalesce(btrim(p_args->>'name'), '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'name is required (an experiments.name)');
    END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'run_id', t.run_id, 'variant', t.variant, 'work_item_id', t.work_item_id)), '[]'::jsonb)
      INTO v_rows
      FROM stewards.experiment_run(p_args->>'name',
                                   coalesce(p_args->'subject_input', '{}'::jsonb)
                                   || CASE WHEN p_args ? 'subject'
                                           THEN jsonb_build_object('subject', p_args->>'subject')
                                           ELSE '{}'::jsonb END) t;
    RETURN jsonb_build_object('ok', true, 'dispatched', v_rows);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$func$;

CREATE OR REPLACE FUNCTION stewards.experiment_report_tool(p_args jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $func$
BEGIN
    IF coalesce(btrim(p_args->>'name'), '') = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'name is required (an experiments.name)');
    END IF;
    RETURN jsonb_build_object('ok', true, 'report', stewards.experiment_report(p_args->>'name'));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$func$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active, effect_class) VALUES
  ('experiment_run',
   'Dispatch a declared Lab experiment: every variant × n_per_variant as tagged work items in one randomized interleave. Args: name (experiments.name), subject (text substituted into {SUBJECT} slots in the variant inputs), subject_input (optional extra input keys).',
   '{"type":"object","additionalProperties":false,"required":["name"],"properties":{"name":{"type":"string"},"subject":{"type":"string"},"subject_input":{"type":"object"}}}'::jsonb,
   '{"kind":"sql_fn","schema":"stewards","name":"experiment_run_tool"}'::jsonb,
   true, 'write_local'),
  ('experiment_report',
   'Harvest metrics for a Lab experiment''s terminal runs, then report per-variant: n, statuses, avg/min/max of each numeric metric, and the work_item ids. Args: name.',
   '{"type":"object","additionalProperties":false,"required":["name"],"properties":{"name":{"type":"string"}}}'::jsonb,
   '{"kind":"sql_fn","schema":"stewards","name":"experiment_report_tool"}'::jsonb,
   true, 'read')
ON CONFLICT (name) DO UPDATE
   SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target, active = true,
       effect_class = EXCLUDED.effect_class;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'experiment_run',    'allow', 'manual'),
  ('work-item-chat', 'experiment_report', 'allow', 'manual')
ON CONFLICT DO NOTHING;

-- §6 — arm the two first-round experiments Michael named (#322) with
-- real executors. fable-hinge-ab stays declared-only: its subject (a
-- pending hinge review re-judged per rung) needs the hinge machinery
-- increment, not this one.
UPDATE stewards.experiments SET
  dispatch = '{"pipeline_family": "decompose-fanout"}'::jsonb,
  variants = '[
    {"variant": "same-prompt",
     "input": {"binding_question": "Convene a review panel of exactly THREE independent reviewers on the following subject. Decompose into exactly 3 child tasks, one per reviewer, each with the SAME neutral mandate: review the subject carefully and report the most important findings, strengths and weaknesses alike. Aggregate their reports, then list the DISTINCT findings with a count of how many reviewers surfaced each.\n\nSUBJECT:\n{SUBJECT}"}},
    {"variant": "opposed-mandate",
     "input": {"binding_question": "Convene a review panel of exactly THREE independent reviewers on the following subject. Decompose into exactly 3 child tasks with OPPOSED mandates — reviewer 1: PROVE the subject''s central claim is sound (strongest supporting case); reviewer 2: DISPROVE it (strongest refutation); reviewer 3: FIND THE THIRD OPTION (what both sides miss — reframings, hidden assumptions, orthogonal evidence). Aggregate their reports, then list the DISTINCT findings with a count of how many reviewers surfaced each.\n\nSUBJECT:\n{SUBJECT}"}}
  ]'::jsonb
WHERE name = 'opposed-mandate-panels';

-- sonnet-raw-vs-claude-code was declared LIVE during the 87 demo and never
-- seeded in a chain file — this INSERT makes 101 its source of record
-- (hypothesis text verbatim from the live row, Michael's question included).
INSERT INTO stewards.experiments (name, hypothesis, n_per_variant, metrics, variants) VALUES
  ('sonnet-raw-vs-claude-code',
   'sonnet-5 dispatched RAW through the substrate native tool loop (opencode-go API) behaves measurably differently from the SAME sonnet-5 inside Claude Code via loom (harness_run) on identical stage tasks — Claude Code scaffolding (system prompt, tool UX, subagents) should change trajectory shape, cost, and output quality. Michael, 2026-07-03: "will sonnet 5 from opencode go in pg-ai-stewards behave differently then sonnet 5 in claude code through loom (because claude code does a lot)".',
   1,
   '["output_quality_judge", "trajectory_tool_calls", "cost_usd", "wall_seconds"]'::jsonb,
   '[
    {"variant": "raw-substrate",
     "pipeline_family": "research-summary",
     "model": "claude-sonnet-4-6", "provider": "opencode_zen",
     "input": {"binding_question": "{SUBJECT}"},
     "route": "opencode_zen chat-completions, native substrate tool loop (gather/build/critique)"},
    {"variant": "claude-code-loom",
     "pipeline_family": "harness-review",
     "input": {"binding_question": "{SUBJECT}", "workdir": ""},
     "route": "harness_run --isolate via loom (claude-code, Max-sub routing)"}
   ]'::jsonb)
ON CONFLICT (name) DO UPDATE
   SET variants = EXCLUDED.variants, hypothesis = EXCLUDED.hypothesis,
       metrics = EXCLUDED.metrics;

-- =====================================================================
-- End of 101-lab-dispatch.sql
-- =====================================================================
