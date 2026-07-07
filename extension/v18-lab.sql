-- ===== [was 87-lab.sql] =====
-- =====================================================================
-- 87-lab.sql — the Lab: experiments as a first-class surface + a
-- standing regression suite (.spec/proposals/lab-and-wiki.md Part 1)
-- =====================================================================
-- The audit's #1 pick ("it grades everything after it"). The substrate has
-- been an ACCIDENTAL physics lab all along — every dispatch is a tracked,
-- repeatable row (sessions, tool calls, costs, BINEVAL verdicts, spiral
-- metrics) — but each past experiment (qwen-sampling A/B, the REST A/B, the
-- BINEVAL gemma-inversion) was hand-rolled SQL + hand-diffed results. This
-- gives the ergonomics: a place to DECLARE an experiment once, and a
-- standing golden-case suite that regresses the substrate's own invariants
-- every night instead of only at the moment a human happens to remember.
--
-- Two independent halves:
--   §1  stewards.experiments / experiment_runs — declare-once experiment
--       rows (variants + metrics as data) + the runs that fill them in.
--       Dispatch machinery (randomized interleave, work_item tagging) is
--       future work per the proposal's sequencing — this batch ships the
--       SHAPE and REGISTERS the two experiments Michael named, not the
--       runner. The Stewdio Experiments panel reads run COUNTS today.
--   §2  stewards.golden_cases / lab_regression_run() — a deterministic
--       regression suite. kind is a free-form text column (deliberately
--       no CHECK — see §2 comment) so an LLM-dispatch case kind can be
--       added later by a function body REPLACE, no ALTER TABLE. v1 ships
--       two synchronous, no-model kinds: sql_assert and function_result.
--       A failed run is LOUD: it lands in the 39-hinge queue (kind=
--       'lab-regression-failure', the same "something needs a human"
--       surface 84's tool-confirm gate uses) AND in the always-queryable
--       lab_regression_failures view — belt and suspenders.
--
-- Schema note (proposal vs. this file): the proposal's prose names
-- variants/metrics/n_per_variant as the experiment shape; this file adds a
-- surrogate bigserial id + unique name (so experiment_runs can FK cleanly)
-- and a status/conclusion pair (so a concluded experiment records its
-- verdict in one place) — neither is proposal-contradicting, both are the
-- minimal shape the proposal left silent.
--
-- Scheduler note: 18-scheduler's OWN header states scheduled_pipelines rows
-- are OPERATOR data (seeded in the workspace overlay, never core) — and
-- tests/virgin-smoke.sql already asserts `scheduled_pipelines must be
-- empty in core`. So this file ships the MACHINERY the nightly cron would
-- dispatch (a 'lab-regression' pipeline + agent + tool), NOT a seeded
-- scheduled_pipelines row — see §3's closing comment for the one-line the
-- operator adds to wire up the actual cron entry.
--
-- requires create_sticky_agent_family (86) — installs at the tail of the
-- chain; reuses hinge_enqueue (39), agents/agent_tool_perms (schema.rs),
-- pipelines (04), tool_defs (schema.rs).
-- =====================================================================

-- =====================================================================
-- §1 — stewards.experiments / stewards.experiment_runs
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.experiments (
    id            bigserial PRIMARY KEY,
    name          text UNIQUE NOT NULL,
    hypothesis    text NOT NULL,
    variants      jsonb NOT NULL DEFAULT '[]'::jsonb,   -- array of {"variant": "...", ...config deltas}
    n_per_variant int  NOT NULL DEFAULT 1,
    metrics       jsonb NOT NULL DEFAULT '[]'::jsonb,   -- array of metric-name strings to observe per run
    status        text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','paused','concluded')),
    conclusion    text,                                 -- filled in when status='concluded'
    created_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.experiments IS
'87: declare-once experiment rows — name/hypothesis/variants (config deltas: model alias, sampling params, prompt id, ladder rung…)/n_per_variant/metrics (measurables to observe: cost, rounds, tool_calls, agreement_with_michael, distinct_finding_count…). Dispatch (randomized interleave as tagged work items) is future work; this batch ships the shape + the two experiments Michael named in .spec/proposals/lab-and-wiki.md.';
COMMENT ON COLUMN stewards.experiments.variants IS
'87: jsonb array, each element a variant config delta, e.g. {"variant":"fable","rung_top_model_alias":"fable"}. No fixed schema beyond a "variant" name key — different experiments vary different knobs.';
COMMENT ON COLUMN stewards.experiments.metrics IS
'87: jsonb array of metric-name strings this experiment observes (matched against experiment_runs.metrics_observed keys when runs land). No p-value theater at small n — honest numbers + spread, per the proposal.';

CREATE TABLE IF NOT EXISTS stewards.experiment_runs (
    id               bigserial PRIMARY KEY,
    experiment_id    bigint NOT NULL REFERENCES stewards.experiments(id) ON DELETE CASCADE,
    variant          text NOT NULL,
    work_item_id     uuid REFERENCES stewards.work_items(id) ON DELETE SET NULL,
    subject_ref      text,                               -- free-form ref when the run isn't a work_item (a session id, a redline id, a hinge review id…)
    metrics_observed jsonb NOT NULL DEFAULT '{}'::jsonb,
    ran_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS experiment_runs_experiment_idx ON stewards.experiment_runs (experiment_id, ran_at DESC);

COMMENT ON TABLE stewards.experiment_runs IS
'87: one row per (experiment, variant) trial. work_item_id when the trial rode a real dispatched work_item; subject_ref for anything else (a redline id, a hinge review id, a raw session id). metrics_observed carries whatever subset of experiments.metrics this trial could measure.';

-- experiment_summary — the Stewdio panel''s one-query read: name/hypothesis/
-- status + a run count, so "declare / run / watch fills" has something to
-- watch fill from day one (0 until the runner ships).
CREATE OR REPLACE VIEW stewards.experiment_summary AS
SELECT e.id, e.name, e.hypothesis, e.status, e.variants, e.metrics,
       e.conclusion, e.created_at,
       count(r.id) AS run_count
  FROM stewards.experiments e
  LEFT JOIN stewards.experiment_runs r ON r.experiment_id = e.id
 GROUP BY e.id
 ORDER BY e.created_at DESC;

COMMENT ON VIEW stewards.experiment_summary IS
'87: experiments + a run_count, one query. Backs the Stewdio Experiments panel list.';

-- =====================================================================
-- §2 — stewards.golden_cases / lab_regression_run() — the regression suite
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.golden_cases (
    id          bigserial PRIMARY KEY,
    name        text UNIQUE NOT NULL,
    kind        text NOT NULL,                         -- deliberately NO CHECK — see comment below
    input       jsonb NOT NULL DEFAULT '{}'::jsonb,
    expectation jsonb NOT NULL DEFAULT '{}'::jsonb,
    enabled     boolean NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN stewards.golden_cases.kind IS
'87: the case dispatcher lab_regression_run() switches on. No CHECK constraint — ON PURPOSE, so a new kind (an LLM-dispatch case: judge this trajectory, verify this quote) can be added later by a CREATE OR REPLACE on the runner function, never an ALTER TABLE. v1 ships two synchronous, no-model kinds:
  sql_assert       — input={"query": "<SQL expr, any scalar>"}; expectation={"equals": "<text>"} (default "true"). The runner casts (query)::text and compares to expectation.equals as text — works for booleans, ints, or short text alike.
  function_result  — input={"fn": "schema.function_name", "args": [<positional args, cast via quote_literal>]}; expectation={"equals": "<text>"}. The runner casts the function''s result ::text and compares the same way.
Unknown kinds record a loud fail (''unknown golden_case kind'') rather than silently skipping — a typo in kind should never look like a pass.';

COMMENT ON TABLE stewards.golden_cases IS
'87: the Lab''s regression fixtures. Each row is one deterministic, synchronous, side-effect-free check against a real substrate invariant (grants deny-by-default, a fallback resolver, a schema-drift catcher…). enabled=false retires a case without deleting its history. Seeded from the substrate''s own existing invariants — see the seed block below for the list + why each was picked.';

CREATE TABLE IF NOT EXISTS stewards.lab_regression_results (
    id      bigserial PRIMARY KEY,
    run_id  text NOT NULL,
    case_id bigint NOT NULL REFERENCES stewards.golden_cases(id) ON DELETE CASCADE,
    pass    boolean NOT NULL,
    detail  text,
    ran_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS lab_regression_results_run_idx  ON stewards.lab_regression_results (run_id);
CREATE INDEX IF NOT EXISTS lab_regression_results_case_idx ON stewards.lab_regression_results (case_id, ran_at DESC);

COMMENT ON TABLE stewards.lab_regression_results IS
'87: one row per (run, case). run_id groups a single lab_regression_run() call (watchman_passes-style text tag, not a separate header table — group by run_id for the per-run summary, see lab_regression_runs_summary).';

-- lab_regression_failures — the always-queryable minimum-bar surface: the
-- MOST RECENT run''s failed cases, joined to the case name for legibility.
-- Empty (0 rows) is the healthy state.
CREATE OR REPLACE VIEW stewards.lab_regression_failures AS
SELECT r.id, r.run_id, r.case_id, gc.name AS case_name, gc.kind, r.detail, r.ran_at
  FROM stewards.lab_regression_results r
  JOIN stewards.golden_cases gc ON gc.id = r.case_id
 WHERE r.pass = false
   AND r.run_id = (SELECT run_id FROM stewards.lab_regression_results ORDER BY ran_at DESC LIMIT 1)
 ORDER BY r.ran_at DESC;

COMMENT ON VIEW stewards.lab_regression_failures IS
'87: the LATEST run''s failing cases. Empty = healthy. The minimum-bar loud surface required even without the hinge alert (see lab_regression_run()).';

-- lab_regression_runs_summary — per-run rollup (total/passed/failed +
-- window), newest first. Backs the Stewdio panel''s "recent regression
-- runs" list; the panel queries lab_regression_results directly (filtered
-- by run_id) for the per-case failure-detail expansion.
CREATE OR REPLACE VIEW stewards.lab_regression_runs_summary AS
SELECT run_id,
       count(*)                         AS total,
       count(*) FILTER (WHERE pass)     AS passed,
       count(*) FILTER (WHERE NOT pass) AS failed,
       min(ran_at)                      AS started_at,
       max(ran_at)                      AS finished_at
  FROM stewards.lab_regression_results
 GROUP BY run_id
 ORDER BY max(ran_at) DESC;

COMMENT ON VIEW stewards.lab_regression_runs_summary IS
'87: per-run_id rollup (total/passed/failed + start/finish), newest first. Backs the Stewdio Experiments panel''s regression-run list.';

-- ---------------------------------------------------------------------
-- lab_regression_run() — the dispatcher. Iterates enabled golden cases,
-- executes each synchronously (no model turn — sql_assert/function_result
-- are both pure SQL), records a result row, and — if anything failed —
-- fires a LOUD alert into the 39-hinge queue (the same "needs a human"
-- surface 84's tool-confirm gate uses) in addition to the always-queryable
-- lab_regression_failures view. Returns the run summary as jsonb.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.lab_regression_run()
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_run_id  text := 'labrun-'
                    || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD"T"HH24MISS"Z"')
                    || '-'
                    || substring(replace(gen_random_uuid()::text, '-', '') FROM 1 FOR 6);
    v_case    stewards.golden_cases%ROWTYPE;
    v_actual  text;
    v_expected text;
    v_args_sql text;
    v_pass    boolean;
    v_detail  text;
    v_total   int := 0;
    v_passed  int := 0;
    v_failed  int := 0;
BEGIN
    FOR v_case IN SELECT * FROM stewards.golden_cases WHERE enabled ORDER BY id LOOP
        v_total := v_total + 1;
        v_pass  := false;
        v_detail := NULL;

        BEGIN
            IF v_case.kind = 'sql_assert' THEN
                EXECUTE format('SELECT (%s)::text', v_case.input ->> 'query') INTO v_actual;
                v_expected := coalesce(v_case.expectation ->> 'equals', 'true');
                v_pass     := (v_actual IS NOT DISTINCT FROM v_expected);
                v_detail   := format('query=%s actual=%s expected=%s',
                                      v_case.input ->> 'query', coalesce(v_actual, '(null)'), v_expected);

            ELSIF v_case.kind = 'function_result' THEN
                SELECT string_agg(quote_literal(elem #>> '{}'), ',')
                  INTO v_args_sql
                  FROM jsonb_array_elements(coalesce(v_case.input -> 'args', '[]'::jsonb)) elem;
                EXECUTE format('SELECT (%s(%s))::text', v_case.input ->> 'fn', coalesce(v_args_sql, ''))
                  INTO v_actual;
                v_expected := coalesce(v_case.expectation ->> 'equals', 'true');
                v_pass     := (v_actual IS NOT DISTINCT FROM v_expected);
                v_detail   := format('fn=%s actual=%s expected=%s',
                                      v_case.input ->> 'fn', coalesce(v_actual, '(null)'), v_expected);

            ELSE
                v_pass   := false;
                v_detail := format('unknown golden_case kind: %s (no dispatcher registered — add one to lab_regression_run before enabling this case)', v_case.kind);
            END IF;

        EXCEPTION WHEN OTHERS THEN
            v_pass   := false;
            v_detail := 'error: ' || SQLERRM;
        END;

        INSERT INTO stewards.lab_regression_results (run_id, case_id, pass, detail)
        VALUES (v_run_id, v_case.id, v_pass, v_detail);

        IF v_pass THEN v_passed := v_passed + 1; ELSE v_failed := v_failed + 1; END IF;
    END LOOP;

    -- LOUD: a failed run alerts through the Hinge, same as 84's tool-confirm
    -- gate — a human should see this without having to remember to look.
    IF v_failed > 0 THEN
        PERFORM stewards.hinge_enqueue(
            'lab-regression-failure',
            format('lab regression run %s: %s/%s cases failed', v_run_id, v_failed, v_total),
            jsonb_build_object('run_id', v_run_id, 'total', v_total, 'passed', v_passed, 'failed', v_failed),
            'lab_regression_run'
        );
    END IF;

    RETURN jsonb_build_object('run_id', v_run_id, 'total', v_total, 'passed', v_passed, 'failed', v_failed);
END;
$fn$;

COMMENT ON FUNCTION stewards.lab_regression_run() IS
'87: run every enabled golden_case synchronously (sql_assert/function_result — no model turn), record each result, and — on any failure — hinge_enqueue a lab-regression-failure alert (in addition to the always-queryable lab_regression_failures view). Returns {"run_id","total","passed","failed"}.';

-- ---------------------------------------------------------------------
-- Seed: 8 golden cases, each a REAL invariant the substrate already
-- depends on, chosen to be green on a virgin 00→87 chain with zero manual
-- data. Four are runtime schema-drift catchers for structural facts
-- virgin-smoke already proves at install time (81/84/03/08); four exercise
-- live resolver functions on inputs manufactured to be unambiguous
-- (a session/tool name guaranteed never to have been granted or touched).
-- ---------------------------------------------------------------------
INSERT INTO stewards.golden_cases (name, kind, input, expectation) VALUES

  ('spiral-oracle-fresh-session-not-spiraled', 'sql_assert',
   '{"query": "NOT stewards.session_spiraled(''lab-golden-nonexistent-session-000'')"}'::jsonb,
   '{"equals": "true"}'::jsonb),

  ('grants-deny-by-default-trajectory-critic', 'function_result',
   '{"fn": "stewards.tool_permission", "args": ["trajectory-critic", "lab-golden-unclaimed-tool-zzz"]}'::jsonb,
   '{"equals": "deny"}'::jsonb),

  ('chat-agent-family-fallback', 'function_result',
   '{"fn": "stewards.chat_agent_family", "args": ["lab-golden-unknown-chat-session-000"]}'::jsonb,
   '{"equals": "work-item-chat"}'::jsonb),

  ('tool-effect-gate-unknown-tool-safe-default', 'sql_assert',
   '{"query": "NOT stewards.tool_requires_confirmation(''lab-golden-unregistered-tool-zzz'')"}'::jsonb,
   '{"equals": "true"}'::jsonb),

  ('escalation-ladder-table-exists', 'sql_assert',
   '{"query": "(SELECT count(*) FROM information_schema.tables WHERE table_schema=''stewards'' AND table_name=''escalation_ladder'') = 1"}'::jsonb,
   '{"equals": "true"}'::jsonb),

  ('watchman-config-singleton-exists', 'sql_assert',
   '{"query": "(SELECT count(*) FROM stewards.watchman_config WHERE id=1) = 1"}'::jsonb,
   '{"equals": "true"}'::jsonb),

  ('gate-prompts-core-templates-present', 'sql_assert',
   '{"query": "(SELECT count(*) FROM stewards.gate_prompts WHERE id IN (''evaluate'',''generate_scenarios'',''verify'')) = 3"}'::jsonb,
   '{"equals": "true"}'::jsonb),

  ('tool-confirm-escalate-always-bound', 'sql_assert',
   '{"query": "stewards.config_get(''hinge_escalate_always_kinds'') ? ''tool-confirm''"}'::jsonb,
   '{"equals": "true"}'::jsonb)

ON CONFLICT (name) DO UPDATE
   SET kind = EXCLUDED.kind, input = EXCLUDED.input, expectation = EXCLUDED.expectation, enabled = true;

-- =====================================================================
-- §3 — the nightly regression: machinery only (no seeded cron row)
-- =====================================================================
-- lab_regression_run_tool wraps the zero-arg function in the one-jsonb-arg
-- shape every sql_fn tool takes (mirrors gate_probe_fire / world_edge_list_tool).
CREATE OR REPLACE FUNCTION stewards.lab_regression_run_tool(p_args jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
    SELECT stewards.lab_regression_run();
$fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active, effect_class) VALUES
  ('lab_regression_run',
   'Run the Lab''s standing regression suite (every enabled golden case) and report the pass/fail summary. Takes no arguments.',
   '{"type":"object","additionalProperties":false,"properties":{}}'::jsonb,
   '{"kind":"sql_fn","schema":"stewards","name":"lab_regression_run_tool"}'::jsonb,
   true, 'write_local')
ON CONFLICT (name) DO UPDATE
   SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
       execute_target = EXCLUDED.execute_target, active = true;

-- A minimal one-tool agent, same deny-'*'-then-allow-one convention as
-- watchman-consolidator (03) and trajectory-critic (56/79) — it can do
-- nothing but fire the suite and report the numbers.
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps) VALUES
  ('lab-regression', '*',
   'Fires the Lab''s nightly regression suite (lab_regression_run) and reports the pass/fail summary. No other tools — a failed case already alerts through the hinge queue.',
   'primary',
   $P$You are the Lab''s nightly regression runner. Call lab_regression_run exactly once — it takes no arguments — and reply with one short line reporting the total/passed/failed counts it returns. Do not investigate any failures yourself; a failed case already alerts a human through the hinge queue. Your job starts and ends with firing the run and reporting the numbers.$P$,
   0.0, 3)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, prompt = EXCLUDED.prompt,
       temperature = EXCLUDED.temperature, steps = EXCLUDED.steps, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('lab-regression', '*',                 'deny',  'manual'),
  ('lab-regression', 'lab_regression_run', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- Single-stage pipeline (echo-test's shape, §1319 of 04-work-items.sql) —
-- what a nightly scheduled_pipelines row would dispatch.
INSERT INTO stewards.pipelines (family, description, stages) VALUES (
  'lab-regression',
  'Single-stage nightly regression run: dispatches the lab-regression agent, which calls lab_regression_run and reports the pass/fail summary.',
  jsonb_build_array(
    jsonb_build_object(
      'name',           'run',
      'agent_family',   'lab-regression',
      'model',          'kimi-k2.6',
      'provider',       'opencode_go',
      'next',           null,
      'auto_advance',   true,
      'input_template', 'Run the nightly Lab regression suite now.'
    )
  )
)
ON CONFLICT (family) DO UPDATE
   SET description = EXCLUDED.description, stages = EXCLUDED.stages, updated_at = now();

-- No INSERT INTO stewards.scheduled_pipelines here — 18-scheduler.sql's own
-- header (and tests/virgin-smoke.sql''s OK-4 clean-room block) establish
-- that scheduled_pipelines rows are OPERATOR data, empty in core. The
-- operator wires up the nightly cron alongside their own intent:
--   INSERT INTO stewards.scheduled_pipelines
--       (slug, pipeline_family, intent_id, cron_pattern, input_template)
--   VALUES ('lab-regression-nightly', 'lab-regression',
--           (SELECT id FROM stewards.intents WHERE slug = 'default'),
--           '0 6 * * *', '{}'::jsonb);

-- =====================================================================
-- §4 — register the two experiments from the proposal
-- =====================================================================
INSERT INTO stewards.experiments (name, hypothesis, variants, metrics, status) VALUES

  ('fable-hinge-ab',
   'A Fable-model Hinge reviewer agrees with Michael''s own past verdicts on the same pending hinge-review fixtures at least as often as an Opus or claude-p-sonnet Hinge, at lower cost — testing whether Fable can safely sit at the top rung of the escalation_ladder.',
   '[{"variant":"fable","rung_top_model_alias":"fable"},{"variant":"opus","rung_top_model_alias":"opus"},{"variant":"claude-p-sonnet","rung_top_model_alias":"claude-p-sonnet"}]'::jsonb,
   '["agreement_with_michael","escalation_rate","cost_usd"]'::jsonb,
   'active'),

  ('opposed-mandate-panels',
   'A 3-reviewer panel assigned OPPOSED mandates (prove / disprove / find-the-third) on the same panel_redline target surfaces more distinct AND more verified findings than giving all 3 reviewers the identical neutral prompt — testing the entropy-collapse claim (same-prompt panels converge and lose diversity) against our own local panels.',
   '[{"variant":"same-prompt","mandates":["neutral","neutral","neutral"]},{"variant":"opposed-mandate","mandates":["prove","disprove","find-the-third"]}]'::jsonb,
   '["distinct_finding_count","verified_finding_count"]'::jsonb,
   'active')

ON CONFLICT (name) DO UPDATE
   SET hypothesis = EXCLUDED.hypothesis, variants = EXCLUDED.variants, metrics = EXCLUDED.metrics;

-- =====================================================================
-- §5 — Stewdio API helpers: jsonb-returning thin passthroughs (the a2a/
-- hinge convention — cmd/stewards-ui/api/lab.go's handlers are one-line
-- `SELECT stewards.lab_..._list($1)` wrappers, same shape as a2aQuery).
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.lab_experiments_list()
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', id, 'name', name, 'hypothesis', hypothesis,
             'status', status, 'variants', variants, 'metrics', metrics,
             'conclusion', conclusion, 'created_at', created_at,
             'run_count', run_count) ORDER BY created_at DESC), '[]'::jsonb)
      FROM stewards.experiment_summary;
$fn$;

COMMENT ON FUNCTION stewards.lab_experiments_list() IS
'87: every experiment + its run_count, as jsonb. Backs GET /api/lab/experiments.';

CREATE OR REPLACE FUNCTION stewards.lab_regression_runs_list(p_limit int DEFAULT 20)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'run_id', s.run_id, 'total', s.total, 'passed', s.passed, 'failed', s.failed,
             'started_at', s.started_at, 'finished_at', s.finished_at)
             ORDER BY s.finished_at DESC), '[]'::jsonb)
      FROM (SELECT * FROM stewards.lab_regression_runs_summary ORDER BY finished_at DESC LIMIT p_limit) s;
$fn$;

COMMENT ON FUNCTION stewards.lab_regression_runs_list(int) IS
'87: the most recent N regression runs (rollup), newest first, as jsonb. Backs GET /api/lab/regression-runs.';

CREATE OR REPLACE FUNCTION stewards.lab_regression_run_detail(p_run_id text)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'case_id', r.case_id, 'case_name', gc.name, 'kind', gc.kind,
             'pass', r.pass, 'detail', r.detail, 'ran_at', r.ran_at)
             ORDER BY r.case_id), '[]'::jsonb)
      FROM stewards.lab_regression_results r
      JOIN stewards.golden_cases gc ON gc.id = r.case_id
     WHERE r.run_id = p_run_id;
$fn$;

COMMENT ON FUNCTION stewards.lab_regression_run_detail(text) IS
'87: per-case results for one run_id (pass/fail + detail), for the Stewdio panel''s failure-detail expansion. Backs GET /api/lab/regression-runs/detail.';

-- =====================================================================
-- End of 87-lab.sql
-- =====================================================================
