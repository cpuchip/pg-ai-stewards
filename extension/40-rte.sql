-- =====================================================================
-- 40-rte.sql — the Reflective Tuning Engine (Phase G of the self-tending memory).
-- =====================================================================
-- An oracle is not just a gate — it is a GRADIENT SIGNAL the substrate can improve
-- itself against ("textual gradient descent" / loop engineering, from the Homer +
-- Microsoft-agent-skills digests in our own pool). The quote oracle marks digests
-- passed/flagged; the RTE reads the FLAGGED quotes beside the PASSED ones, diagnoses the
-- delta, and proposes a refined quote-skill rule — gated through the Hinge (39), then
-- auto-applied. The digester reads the active rules and quotes better; the oracle
-- re-scores; the flag rate is the measurable outcome. The capstone of "build the oracle
-- first": every checker becomes an engine of improvement. requires create_hinge (39).
-- =====================================================================

-- ── the per-quote failure signal (the oracle --mark writes these) ────
CREATE TABLE IF NOT EXISTS stewards.quote_flags (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_slug    text NOT NULL,
    quote       text NOT NULL,
    score       real,                          -- the oracle's match ratio (0..1)
    source_kind text,                          -- 'book' | 'video'
    flagged_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS quote_flags_recent_idx ON stewards.quote_flags (flagged_at DESC);
COMMENT ON TABLE stewards.quote_flags IS
'40: one row per quote the quote oracle flagged (not verbatim). The RTE''s raw gradient signal — it diagnoses why these failed vs what the passed digests did right.';

-- ── the learned rules (the gradient, applied) ───────────────────────
CREATE TABLE IF NOT EXISTS stewards.digest_skill_rules (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_text    text NOT NULL,
    grounded_in  text,                          -- what evidence prompted it
    status       text NOT NULL DEFAULT 'proposed'
                   CHECK (status IN ('proposed','active','retired')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    activated_at timestamptz
);
COMMENT ON TABLE stewards.digest_skill_rules IS
'40: quote-discipline rules the RTE learned from flagged digests. A rule is proposed -> (Hinge approves) -> active. The digester reads active rules via quote_rules and follows them.';

-- ── quote_rules — the active rules the digester consults before quoting.
CREATE OR REPLACE FUNCTION stewards.quote_rules_tool(p_args jsonb)
RETURNS text LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(
        string_agg('- ' || rule_text, E'\n' ORDER BY activated_at),
        'No learned rules yet — quote verbatim or do not use quotation marks.')
      FROM stewards.digest_skill_rules WHERE status = 'active';
$fn$;

-- ── rte_quote_contrast — the gradient signal for the diagnoser: recent flagged quotes
--    (the failures) + the pass/flag rate (so it can see the trend it must move).
CREATE OR REPLACE FUNCTION stewards.rte_quote_contrast_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_limit int := coalesce((p_args->>'limit')::int, 30);
    v_flags jsonb;
    v_rate  jsonb;
BEGIN
    SELECT jsonb_agg(jsonb_build_object('doc', doc_slug, 'quote', left(quote,200), 'score', score)
                     ORDER BY flagged_at DESC)
      INTO v_flags FROM (SELECT * FROM stewards.quote_flags ORDER BY flagged_at DESC LIMIT v_limit) f;
    SELECT jsonb_object_agg(qc, n) INTO v_rate FROM (
        SELECT coalesce(frontmatter->>'quote_check','unmarked') qc, count(*) n FROM stewards.docs GROUP BY 1) y;
    RETURN jsonb_build_object('flagged_quotes', coalesce(v_flags,'[]'::jsonb),
                              'corpus_quote_check', coalesce(v_rate,'{}'::jsonb),
                              'active_rules', stewards.quote_rules_tool('{}'::jsonb))::text;
END;
$fn$;

-- ── rte_enqueue_quote_rule — the diagnoser proposes a rule → a proposed row + a Hinge
--    review (kind digest-skill-rule). On Hinge approval the trigger below activates it.
CREATE OR REPLACE FUNCTION stewards.rte_enqueue_quote_rule(p_rule text, p_grounding text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_rid bigint; v_hid bigint;
BEGIN
    IF coalesce(btrim(p_rule),'') = '' THEN RETURN jsonb_build_object('ok', false, 'note', 'empty rule'); END IF;
    INSERT INTO stewards.digest_skill_rules (rule_text, grounded_in) VALUES (p_rule, p_grounding) RETURNING id INTO v_rid;
    v_hid := stewards.hinge_enqueue('digest-skill-rule',
                left('Quote-skill rule: ' || p_rule, 200),
                jsonb_build_object('rule_id', v_rid, 'rule', p_rule, 'grounded_in', p_grounding),
                'rte');
    RETURN jsonb_build_object('ok', true, 'rule_id', v_rid, 'hinge_id', v_hid,
        'note', 'proposed + queued for the Hinge — it activates on approval');
END;
$fn$;
CREATE OR REPLACE FUNCTION stewards.rte_enqueue_quote_rule_tool(p_args jsonb)
RETURNS text LANGUAGE sql AS $fn$
    SELECT stewards.rte_enqueue_quote_rule(p_args->>'rule', p_args->>'grounding')::text;
$fn$;

-- ── auto-apply: when the Hinge approves a digest-skill-rule, activate the rule.
CREATE OR REPLACE FUNCTION stewards.rte_apply_approved_rule()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.kind = 'digest-skill-rule' AND NEW.status = 'approved'
       AND (OLD.status IS DISTINCT FROM 'approved') THEN
        UPDATE stewards.digest_skill_rules
           SET status = 'active', activated_at = now()
         WHERE id = (NEW.payload->>'rule_id')::bigint AND status = 'proposed';
        UPDATE stewards.hinge_reviews SET status = 'applied', applied_at = now() WHERE id = NEW.id;
    END IF;
    RETURN NEW;
END;
$fn$;
DROP TRIGGER IF EXISTS hinge_apply_digest_skill_rule ON stewards.hinge_reviews;
CREATE TRIGGER hinge_apply_digest_skill_rule
AFTER UPDATE OF status ON stewards.hinge_reviews
FOR EACH ROW WHEN (NEW.kind = 'digest-skill-rule' AND NEW.status = 'approved')
EXECUTE FUNCTION stewards.rte_apply_approved_rule();

-- ── tools (the digest-tuning pipeline + the digesters use these) ─────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target) VALUES
( 'quote_rules',
  'Read the verbatim-discipline rules the substrate has LEARNED from past quoting mistakes. Call this before writing quotes and follow the rules.',
  '{"type":"object","properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"quote_rules_tool"}'::jsonb ),
( 'rte_quote_contrast',
  'Get the quote-oracle gradient signal: recent FLAGGED quotes (the failures), the corpus pass/flag counts, and the active rules. Use it to diagnose WHY quotes fail and propose a better rule.',
  '{"type":"object","properties":{"limit":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"rte_quote_contrast_tool"}'::jsonb ),
( 'rte_propose_quote_rule',
  'Propose a refined quote-discipline rule for the digesters (one or two sentences, actionable). It is queued for the Hinge and activates only on approval. Give the grounding (what flagged quotes prompted it).',
  '{"type":"object","required":["rule"],"properties":{"rule":{"type":"string"},"grounding":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"rte_enqueue_quote_rule_tool"}'::jsonb )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
    ('research','quote_rules','allow','manual'),
    ('research','rte_quote_contrast','allow','manual'),
    ('research','rte_propose_quote_rule','allow','manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ── the digest-tuning pipeline — the RTE's LLM diagnoser (textual gradient descent).
--    Reads the gradient (flagged vs passed), diagnoses the delta, proposes ONE refined
--    rule (Hinge-gated). Scoped to a lean self-tuning tool group. Dispatchable; a
--    disabled daily schedule is seeded for the operator to enable.
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('self-tuning', 'the RTE diagnoser tools', ARRAY['rte_quote_contrast','rte_propose_quote_rule','quote_rules'])
ON CONFLICT (name) DO UPDATE SET tool_patterns = EXCLUDED.tool_patterns;

-- The digest-tuning PIPELINE (the capability) is core; its INTENT + SCHEDULE (when it
-- actually runs) are operator config and live in a workspace overlay (overlays/
-- self-tuning.sql) — core ships with no intents or schedules (virgin-smoke enforces this).
INSERT INTO stewards.pipelines (family, description, stages, maturity_ladder, auto_materialize_on_verified, metadata)
VALUES (
  'digest-tuning',
  'The RTE diagnoser: read the quote-oracle gradient (flagged vs passed), diagnose the delta, propose a refined quote rule (Hinge-gated). Textual gradient descent on the digester skill.',
  jsonb_build_array(jsonb_build_object(
    'name','tune','next', NULL, 'model','critic','agent_family','research',
    'auto_advance', true, 'tools_disabled', false,
    'tool_groups', jsonb_build_array('self-tuning'),
    'input_template',
      'You are the digest-tuning stage — the Reflective Tuning Engine.' || E'\n\n' ||
      '1. Call `rte_quote_contrast` to see recent FLAGGED quotes (the failures), the corpus pass/flag counts, and the rules already active.' || E'\n' ||
      '2. Diagnose the delta: what do the flagged quotes share that the passed digests avoid — fabrication, paraphrase-in-quotes, or wrong attribution?' || E'\n' ||
      '3. If there is ONE clear, NEW rule that would reduce these failures and is NOT already an active rule, call `rte_propose_quote_rule` with a one-sentence actionable rule + the grounding (which flagged quotes prompted it). If the active rules already cover it, propose nothing.' || E'\n' ||
      '4. Reply with a 2-3 sentence journal: what you diagnosed and whether you proposed a rule.'
  )),
  '["raw","verified"]'::jsonb, false, jsonb_build_object('pools_via_tool', true))
ON CONFLICT (family) DO UPDATE SET stages = EXCLUDED.stages, description = EXCLUDED.description, updated_at = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity)
VALUES ('digest-tuning','tune','verified')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET produces_maturity = EXCLUDED.produces_maturity;

-- =====================================================================
-- End of 40-rte.sql
-- =====================================================================
