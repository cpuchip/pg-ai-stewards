-- =====================================================================
-- 59-self-improvement.sql — the substrate improves its own agents (gated)
-- =====================================================================
-- The trajectory critic (56) finds bad work. This closes the loop: recurring
-- failures → a SCOPED prompt-clause proposal → a DETERMINISTIC GATE → in-bounds
-- auto-apply (trailed + reversible), out-of-bounds escalate to the human →
-- the critic re-scores. dominion_in_council, ratified 2026-06-25.
--
-- SAFETY INVARIANT (the eval-gaming guard): the system may NEVER auto-modify
-- what GRADES or GATES it — any judge (response_format set), any critic, the
-- stewards/Hinge, or the improver itself. Those are escalate-to-human only.
-- Auto-applied clauses are ADDITIVE GUIDANCE only — never permission, constraint,
-- or guard changes (regex-blocked). The gate is re-checked at apply time.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — store the critic's verdicts (harvested from the trajectory-critic)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.trajectory_verdicts (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_session text NOT NULL,           -- the run that was judged
    agent_family   text,                    -- the family that ran it
    scores         jsonb,
    issues         jsonb,
    verdict        text,                     -- the critic's verdict word
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trajectory_verdicts_family_idx
    ON stewards.trajectory_verdicts(agent_family, created_at DESC);

-- harvest: when a trajectory-critic chat completes, parse its JSON verdict.
-- critique_trajectory (56) uses session 'trajcritic--<target>'.
CREATE OR REPLACE FUNCTION stewards.harvest_trajectory_verdict() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE v_content text; v_json jsonb; v_target text; v_family text;
BEGIN
    IF NEW.status='done' AND OLD.status<>'done' AND NEW.kind='chat'
       AND NEW.payload->>'agent_family'='trajectory-critic' THEN
        v_target := regexp_replace(NEW.payload->>'session_id', '^trajcrit(ic)?--', '');
        SELECT content INTO v_content FROM stewards.messages
         WHERE session_id = NEW.payload->>'session_id' AND role='assistant'
           AND coalesce(content,'')<>'' ORDER BY id DESC LIMIT 1;
        BEGIN v_json := v_content::jsonb; EXCEPTION WHEN others THEN v_json := NULL; END;
        IF v_json IS NOT NULL THEN
            SELECT payload->>'agent_family' INTO v_family FROM stewards.work_queue
             WHERE payload->>'session_id'=v_target AND kind='chat' ORDER BY id LIMIT 1;
            INSERT INTO stewards.trajectory_verdicts(target_session, agent_family, scores, issues, verdict)
            VALUES (v_target, v_family, v_json->'scores', v_json->'issues', v_json->>'verdict');
        END IF;
    END IF;
    RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS work_queue_harvest_trajectory ON stewards.work_queue;
CREATE TRIGGER work_queue_harvest_trajectory
    AFTER UPDATE OF status ON stewards.work_queue
    FOR EACH ROW EXECUTE FUNCTION stewards.harvest_trajectory_verdict();

-- ---------------------------------------------------------------------
-- §2 — the proposal ledger (trail + rollback)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.prompt_improvements (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_family    text NOT NULL,
    clause          text NOT NULL,
    rationale       text,
    source_verdicts bigint[] NOT NULL DEFAULT '{}',
    status          text NOT NULL DEFAULT 'proposed',  -- proposed|approved|applied|escalated|reverted|rejected
    gate_reason     text,
    prior_prompt    text,                               -- for rollback
    created_at      timestamptz NOT NULL DEFAULT now(),
    applied_at      timestamptz
);
CREATE INDEX IF NOT EXISTS prompt_improvements_status_idx
    ON stewards.prompt_improvements(status, created_at DESC);

-- ---------------------------------------------------------------------
-- §3 — THE GATE (the deterministic safety floor)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.prompt_improvement_gate(p_family text, p_clause text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_agent stewards.agents%ROWTYPE; v_cap int := 600;
BEGIN
    SELECT * INTO v_agent FROM stewards.agents WHERE family = p_family AND active LIMIT 1;
    IF v_agent.family IS NULL THEN
        RETURN jsonb_build_object('disposition','escalate','reason','unknown agent family: '||coalesce(p_family,'(null)'));
    END IF;
    -- (1) EVAL-GAMING GUARD: never auto-modify what grades or gates the system.
    IF v_agent.response_format IS NOT NULL THEN
        RETURN jsonb_build_object('disposition','escalate','reason','target is a JUDGE (response_format set) — grading agents are escalate-only');
    END IF;
    IF p_family = ANY (ARRAY[
        'trajectory-critic','world-critic','agent-improver','prompt-critic','judge-brief',
        'compactor','engram-extractor','watchman-consolidator','reflect-steward','hinge','steward']) THEN
        RETURN jsonb_build_object('disposition','escalate','reason','target is a critic / gate / steward — escalate-only (gate integrity)');
    END IF;
    -- (2) base-prompt / self-edit-capable agents escalate
    IF coalesce(v_agent.allow_self_base_prompt, false) THEN
        RETURN jsonb_build_object('disposition','escalate','reason','target is self-base-prompt-capable — escalate-only');
    END IF;
    -- (3) the clause must be SHORT, ADDITIVE GUIDANCE — not a constraint/permission/guard change
    IF char_length(coalesce(p_clause,'')) = 0 THEN
        RETURN jsonb_build_object('disposition','escalate','reason','empty clause');
    END IF;
    IF char_length(p_clause) > v_cap THEN
        RETURN jsonb_build_object('disposition','escalate','reason',format('clause too long (%s > %s chars) — large changes escalate', char_length(p_clause), v_cap));
    END IF;
    -- Red-flag WORDS (Postgres word boundary is \y, NOT \b — \b is backspace):
    IF p_clause ~* '\y(ignore|disregard|override|bypass|jailbreak|unrestricted|allow|deny|grant|permission|autonomy)\y'
       -- Red-flag PHRASES (grounding/verification bypass, permission/capability, self/base/destructive):
       OR p_clause ~* '(tool_perm|any tool|all tools|self.?prompt|base prompt|system prompt|spend.?cap|delete from|drop table|truncate table|do not (verify|check|cite|ground|stop|validate|refuse)|skip (the )?(verification|check|grounding|validation)|always (allow|approve|say|pass)|without (limit|restriction|approval|verif|check|grounding)|use your (own )?(memory|training|knowledge)|from (your )?(memory|training)|trust your (memory|judgment|training)|grounding rules)' THEN
        RETURN jsonb_build_object('disposition','escalate','reason','clause contains permission/constraint/guard/grounding-bypass/destructive language — escalate (auto-apply is additive guidance only)');
    END IF;
    RETURN jsonb_build_object('disposition','auto_apply','reason','scoped additive guidance to a worker agent (within bounds)');
END $$;
COMMENT ON FUNCTION stewards.prompt_improvement_gate(text,text) IS
  '59: the deterministic safety floor for self-improvement. auto_apply ONLY a short additive-guidance clause to a non-judge/non-critic/non-gate worker agent; everything else escalates. The eval-gaming guard.';

-- ---------------------------------------------------------------------
-- §4 — apply (trailed) + revert (rollback)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.apply_prompt_improvement(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_imp_rec stewards.prompt_improvements%ROWTYPE;
BEGIN
    SELECT * INTO v_imp_rec FROM stewards.prompt_improvements WHERE id = p_id;
    IF v_imp_rec.id IS NULL THEN RETURN jsonb_build_object('error','no such improvement '||p_id); END IF;
    -- DEFENSE IN DEPTH: re-run the gate at apply time; refuse if not in-bounds.
    IF (stewards.prompt_improvement_gate(v_imp_rec.agent_family, v_imp_rec.clause)->>'disposition') <> 'auto_apply' THEN
        UPDATE stewards.prompt_improvements SET status='escalated',
            gate_reason='apply-time gate refused (out-of-bounds)' WHERE id=p_id;
        RETURN jsonb_build_object('error','apply refused: out-of-bounds at apply time','id',p_id);
    END IF;
    UPDATE stewards.agents
       SET prompt = prompt || E'\n\n[auto-improved '||to_char(now(),'YYYY-MM-DD')||', from trajectory critique]: '||v_imp_rec.clause
     WHERE family = v_imp_rec.agent_family AND active;
    UPDATE stewards.prompt_improvements SET status='applied', applied_at=now() WHERE id=p_id;
    RETURN jsonb_build_object('ok',true,'id',p_id,'agent_family',v_imp_rec.agent_family,'applied',true);
END $$;

CREATE OR REPLACE FUNCTION stewards.revert_prompt_improvement(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_imp_rec stewards.prompt_improvements%ROWTYPE;
BEGIN
    SELECT * INTO v_imp_rec FROM stewards.prompt_improvements WHERE id = p_id;
    IF v_imp_rec.id IS NULL OR v_imp_rec.prior_prompt IS NULL THEN
        RETURN jsonb_build_object('error','no such improvement or no prior prompt to restore');
    END IF;
    UPDATE stewards.agents SET prompt = v_imp_rec.prior_prompt
     WHERE family = v_imp_rec.agent_family AND active;
    UPDATE stewards.prompt_improvements SET status='reverted' WHERE id=p_id;
    RETURN jsonb_build_object('ok',true,'id',p_id,'reverted',true);
END $$;

-- ---------------------------------------------------------------------
-- §5 — propose: gate, then auto-apply or escalate
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.propose_prompt_improvement(
    p_family text, p_clause text, p_rationale text DEFAULT NULL, p_source_verdicts bigint[] DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_gate jsonb; v_disp text; v_id bigint; v_prior text; v_applied jsonb;
BEGIN
    v_gate := stewards.prompt_improvement_gate(p_family, p_clause);
    v_disp := v_gate->>'disposition';
    SELECT prompt INTO v_prior FROM stewards.agents WHERE family=p_family AND active LIMIT 1;
    INSERT INTO stewards.prompt_improvements(agent_family, clause, rationale, source_verdicts, status, gate_reason, prior_prompt)
    VALUES (p_family, p_clause, p_rationale, coalesce(p_source_verdicts,'{}'),
            CASE WHEN v_disp='auto_apply' THEN 'approved' ELSE 'escalated' END,
            v_gate->>'reason', v_prior)
    RETURNING id INTO v_id;
    IF v_disp = 'auto_apply' THEN
        v_applied := stewards.apply_prompt_improvement(v_id);
        RETURN jsonb_build_object('ok',true,'id',v_id,'disposition','auto_apply',
            'applied',(v_applied->>'ok')='true','reason',v_gate->>'reason');
    END IF;
    RETURN jsonb_build_object('ok',true,'id',v_id,'disposition','escalate','applied',false,
        'reason',v_gate->>'reason','note','escalated to the human — review stewards.prompt_improvements WHERE status=''escalated''');
END $$;

-- model-callable wrapper (the agent-improver calls this)
CREATE OR REPLACE FUNCTION stewards.propose_prompt_improvement_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_family text := p_args->>'agent_family'; v_clause text := p_args->>'clause';
        v_rat text := p_args->>'rationale'; v_vs bigint[];
BEGIN
    IF v_family IS NULL OR v_clause IS NULL THEN RETURN jsonb_build_object('error','agent_family and clause required'); END IF;
    IF jsonb_typeof(p_args->'source_verdicts')='array' THEN
        SELECT array_agg(value::bigint) INTO v_vs FROM jsonb_array_elements_text(p_args->'source_verdicts') value;
    END IF;
    RETURN stewards.propose_prompt_improvement(v_family, v_clause, v_rat, coalesce(v_vs,'{}'));
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', SQLERRM);
END $fn$;

-- ---------------------------------------------------------------------
-- §6 — agent_failure_patterns: recurring, thresholded failures
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.agent_failure_patterns(p_min_count int DEFAULT 3, p_window interval DEFAULT '14 days')
RETURNS TABLE (agent_family text, bad_runs bigint, verdicts jsonb, sample_issues jsonb, sample_verdict_ids bigint[])
LANGUAGE sql STABLE AS $$
    SELECT v.agent_family,
           count(*) AS bad_runs,
           jsonb_object_agg(v.verdict, 1) FILTER (WHERE v.verdict IS NOT NULL) AS verdicts,
           to_jsonb((array_agg(v.issues ORDER BY v.created_at DESC))[1:3]) AS sample_issues,
           (array_agg(v.id ORDER BY v.created_at DESC))[1:10] AS sample_verdict_ids
      FROM stewards.trajectory_verdicts v
     WHERE v.agent_family IS NOT NULL
       AND v.created_at > now() - p_window
       AND v.verdict IN ('flawed','unsound','fail','warn')
     GROUP BY v.agent_family
    HAVING count(*) >= p_min_count;
$$;

-- ---------------------------------------------------------------------
-- §7 — the agent-improver (proposes ONE scoped clause per pattern)
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'propose_prompt_improvement',
  'Propose ONE short, additive guidance clause to append to an agent''s prompt, to fix a recurring failure the trajectory critic found. It is GATED: a scoped guidance clause to a worker agent auto-applies; anything touching a judge/critic/gate, a base prompt, a permission/constraint, or anything long, escalates to the human. Pass agent_family, the clause (additive guidance only), a rationale, and the source_verdicts that justify it.',
  '{"type":"object","additionalProperties":false,"properties":{"agent_family":{"type":"string"},"clause":{"type":"string"},"rationale":{"type":"string"},"source_verdicts":{"type":"array","items":{"type":"integer"}}},"required":["agent_family","clause","rationale"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"propose_prompt_improvement_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
  execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES (
  'agent-improver', '*',
  'Reads a recurring failure pattern (from trajectory critiques) for ONE agent family and proposes a single scoped, additive guidance clause to fix it — gated, never freeform.',
  'primary',
  $P$You improve the substrate's own agents. You are given a recurring FAILURE PATTERN for one agent family: how many bad runs, the critic's verdicts, and sample issues. Propose ONE fix.

Your fix is a SINGLE short clause of ADDITIVE GUIDANCE to append to that agent's prompt — a concrete instruction that would prevent the recurring failure. For example, if the critic keeps flagging "re-emitted the whole batch", the clause is "Record each item once; never re-issue calls you have already made." If it keeps flagging "proceeded past a tool error", the clause is "If a tool returns an error, stop and adjust — do not continue as if it succeeded."

Rules:
- Propose ONE clause, grounded in the SPECIFIC failures you were shown. Cite the source_verdicts.
- ADDITIVE GUIDANCE ONLY. Never propose to remove a constraint, change a permission, weaken a check, or touch a base/system prompt — the gate will reject those and they only waste the proposal.
- Keep it short and concrete (one or two sentences).
- Call propose_prompt_improvement once with {agent_family, clause, rationale, source_verdicts}. It tells you whether it auto-applied (in-bounds) or escalated to the human (out-of-bounds).
- Your final reply is a one-line note: what you proposed and whether it applied or escalated.$P$,
  0.3, 6
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description=EXCLUDED.description, prompt=EXCLUDED.prompt, temperature=EXCLUDED.temperature,
      steps=EXCLUDED.steps, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('agent-improver', '*',                          'deny',  'manual'),
  ('agent-improver', 'propose_prompt_improvement', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- ---------------------------------------------------------------------
-- §8 — the tick: critique recent runs, then improve recurring patterns
-- ---------------------------------------------------------------------
-- Dispatches the agent-improver for each actionable failure pattern. Gated by
-- the global autonomy pause (reuses reflect_status' autonomy_paused).
CREATE OR REPLACE FUNCTION stewards.self_improve_tick(p_min_count int DEFAULT 3)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r record; v_dispatched int := 0; v_paused boolean;
BEGIN
    SELECT coalesce((stewards.config_get_text('autonomy_paused','false'))::boolean, false) INTO v_paused;
    IF v_paused THEN RETURN jsonb_build_object('ok',true,'paused',true,'dispatched',0); END IF;
    FOR r IN SELECT * FROM stewards.agent_failure_patterns(p_min_count) LOOP
        -- skip families the gate would always escalate (don't waste improver runs)
        CONTINUE WHEN (stewards.prompt_improvement_gate(r.agent_family, 'probe additive guidance')->>'disposition') <> 'auto_apply';
        -- skip if a recent open proposal already targets this family
        CONTINUE WHEN EXISTS (SELECT 1 FROM stewards.prompt_improvements
                               WHERE agent_family=r.agent_family AND status IN ('proposed','approved','applied')
                                 AND created_at > now() - interval '7 days');
        PERFORM stewards.dispatch_chat_turn(
            'agent-improve--'||r.agent_family||'--'||to_char(now(),'YYYYMMDDHH24MI'),
            'Recurring failure pattern for agent family "'||r.agent_family||'": '||r.bad_runs||' bad runs. '||
            'Verdicts: '||coalesce(r.verdicts::text,'{}')||'. Sample issues: '||coalesce(r.sample_issues::text,'[]')||'. '||
            'Source verdict ids: '||coalesce(r.sample_verdict_ids::text,'{}')||'. Propose one scoped additive guidance clause to fix it.',
            'agent-improver');
        v_dispatched := v_dispatched + 1;
    END LOOP;
    RETURN jsonb_build_object('ok',true,'paused',false,'dispatched',v_dispatched);
END $$;
COMMENT ON FUNCTION stewards.self_improve_tick(int) IS
  '59: the self-improvement tick — for each recurring failure pattern, dispatch the agent-improver to propose a gated fix. Honors autonomy_paused; skips always-escalate families and recently-proposed ones.';
