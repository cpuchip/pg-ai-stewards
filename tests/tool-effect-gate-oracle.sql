-- =====================================================================
-- tests/tool-effect-gate-oracle.sql — the 84 gate, standalone + self-cleaning
-- =====================================================================
-- A fast dev-container check for the tool-effect gate (84). The whole loop
-- is baked into the assert with a VISIBLE side effect, so "was it executed?"
-- is deterministic, not a guess. The same coverage lives in
-- tests/virgin-smoke.sql (OK 84) for the CI virgin boot; this file is the
-- quick run against an ALREADY-installed DB (e.g. the running stewards-oss-pg).
--
--   docker exec -i stewards-oss-pg psql -U stewards -d stewards \
--       -v ON_ERROR_STOP=1 -f - < tests/tool-effect-gate-oracle.sql
--
-- Self-cleaning: it drops every scratch object it creates, so it is safe to
-- run repeatedly against a live DB.
-- =====================================================================
\set ON_ERROR_STOP on

-- A scratch sql_fn tool with a visible side effect (inserts into gate_probe).
CREATE TABLE IF NOT EXISTS stewards.gate_probe (n int);
TRUNCATE stewards.gate_probe;
CREATE OR REPLACE FUNCTION stewards.gate_probe_fire(p_args jsonb)
RETURNS jsonb LANGUAGE sql AS $g$
    INSERT INTO stewards.gate_probe (n) VALUES (1)
    RETURNING jsonb_build_object('fired', true, 'got', p_args);
$g$;
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target)
VALUES ('gate_probe_tool', 'scratch external-send probe (84 oracle)', '{"type":"object"}'::jsonb,
        '{"kind":"sql_fn","schema":"stewards","name":"gate_probe_fire"}'::jsonb)
ON CONFLICT (name) DO UPDATE SET execute_target = EXCLUDED.execute_target;
UPDATE stewards.tool_defs SET effect_class = 'external_send' WHERE name = 'gate_probe_tool';
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class)
VALUES ('gate_read_probe', 'scratch read probe (84 oracle)', '{"type":"object"}'::jsonb,
        '{"kind":"sql_fn","schema":"stewards","name":"gate_probe_fire"}'::jsonb, 'read')
ON CONFLICT (name) DO UPDATE SET effect_class = 'read';

DO $$
DECLARE v jsonb; v_id bigint; v_id2 bigint; v_id3 bigint; n int;
    v_target jsonb := '{"kind":"sql_fn","schema":"stewards","name":"gate_probe_fire"}'::jsonb;
BEGIN
    ASSERT stewards.config_get('hinge_escalate_always_kinds') ? 'tool-confirm',
           'tool-confirm must be escalate-always';
    ASSERT stewards.tool_requires_confirmation('gate_probe_tool') = true,
           'external_send tool must require confirmation';
    ASSERT stewards.tool_requires_confirmation('gate_read_probe') = false,
           'read tool must NOT require confirmation (inverse)';

    -- (a) WITHHOLD — enqueue, do not execute.
    v := stewards.tool_confirm_gate('gate_probe_tool','{"x":1}'::jsonb,v_target,'probe-agent','probe-session');
    ASSERT (v->>'withheld')::bool, 'gate must withhold';
    v_id := (v->>'hinge_id')::bigint;
    ASSERT EXISTS (SELECT 1 FROM stewards.hinge_reviews WHERE id=v_id AND kind='tool-confirm' AND status='pending'),
           'a pending tool-confirm review must exist';
    SELECT count(*) INTO n FROM stewards.gate_probe;
    ASSERT n = 0, format('withheld call must NOT have executed (rows=%s)', n);

    -- (b) APPROVE (michael) → execute the STORED call verbatim, once, idempotent.
    PERFORM stewards.hinge_record_verdict(v_id,'approve','ok','michael');
    ASSERT (SELECT status FROM stewards.hinge_reviews WHERE id=v_id)='approved', 'michael approve → approved';
    v := stewards.tool_confirm_apply(v_id);
    ASSERT (v->>'executed')::bool, 'apply must execute on approval';
    SELECT count(*) INTO n FROM stewards.gate_probe;
    ASSERT n = 1, format('approved call must execute once (rows=%s)', n);
    ASSERT (SELECT status FROM stewards.hinge_reviews WHERE id=v_id)='applied', 'review → applied';
    PERFORM stewards.tool_confirm_apply(v_id);
    SELECT count(*) INTO n FROM stewards.gate_probe;
    ASSERT n = 1, format('apply must be idempotent — no double-send (rows=%s)', n);

    -- (c) DECLINE → not executed.
    v := stewards.tool_confirm_gate('gate_probe_tool','{"x":2}'::jsonb,v_target,'probe-agent','probe-session');
    v_id2 := (v->>'hinge_id')::bigint;
    PERFORM stewards.hinge_record_verdict(v_id2,'decline','no','michael');
    v := stewards.tool_confirm_apply(v_id2);
    ASSERT NOT (v->>'executed')::bool, 'declined call must not execute';
    SELECT count(*) INTO n FROM stewards.gate_probe;
    ASSERT n = 1, format('decline must leave count unchanged (rows=%s)', n);

    -- (d) ESCALATE-ALWAYS — claude-hinge approve on a tool-confirm ESCALATES.
    v := stewards.tool_confirm_gate('gate_probe_tool','{"x":3}'::jsonb,v_target,'probe-agent','probe-session');
    v_id3 := (v->>'hinge_id')::bigint;
    v := stewards.hinge_record_verdict(v_id3,'approve','auto','claude-hinge');
    ASSERT (v->>'status')='escalated', format('claude-hinge approve must ESCALATE (got %s)', v->>'status');
    ASSERT (stewards.tool_confirm_apply(v_id3)->>'ok')='false', 'apply on escalated review must refuse';
    SELECT count(*) INTO n FROM stewards.gate_probe;
    ASSERT n = 1, format('escalated call must NOT execute (rows=%s)', n);

    RAISE NOTICE 'OK 84 gate oracle — withhold / approve-execute-once / idempotent / read-inverse / decline / escalate-always all pass';
END $$;

-- Self-clean: remove every scratch object.
DELETE FROM stewards.hinge_reviews WHERE kind='tool-confirm' AND payload->>'tool'='gate_probe_tool';
DELETE FROM stewards.tool_defs WHERE name IN ('gate_probe_tool','gate_read_probe');
DROP FUNCTION IF EXISTS stewards.gate_probe_fire(jsonb);
DROP TABLE IF EXISTS stewards.gate_probe;

\echo '== tool-effect-gate oracle PASSED =='
