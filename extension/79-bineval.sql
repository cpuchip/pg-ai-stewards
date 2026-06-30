-- =====================================================================
-- 79-bineval.sql — BINEVAL via a TOOL: force the trajectory critic to
-- DECOMPOSE its verdict into binary answers ("Ask, Don't Judge", 2606.27226).
-- =====================================================================
-- v1 (free-text JSON) failed on the real path: qwen produced holistic scores
-- and SKIPPED the binary questions — a weak model drops "also fill in this
-- array". Fix (Michael's idea): make the questions the REQUIRED ARGS of a tool.
-- The model cannot answer without filling the schema, so the decomposition is
-- forced; and the tool stores the verdict SYNCHRONOUSLY (so a later work error
-- can't lose it — the old free-text path depended on a status='done' harvest).
--
-- ★ The spiral link: `committed` is one of the required questions — "did it
-- commit, or gather without end?". A false → verdict fail → the note flows to
-- 59's agent-improver. The judge, the spiral oracle, and the self-improvement
-- loop now point at the same target. BACKWARD-COMPATIBLE: still writes
-- trajectory_verdicts(scores/issues/verdict) so 59 reads it unchanged.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — the verdict sink: derive scores/verdict/issues from the binary
-- answers and store. Target = the injected _session_id ('trajcritic--<run>').
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.submit_trajectory_verdict_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_target text;
    v_family text;
    v_ts boolean := coalesce((p_args->>'tool_selection_ok')::boolean, true);
    v_pp boolean := coalesce((p_args->>'params_ok')::boolean, true);
    v_eh boolean := coalesce((p_args->>'error_handling_ok')::boolean, true);
    v_nr boolean := coalesce((p_args->>'no_redundancy')::boolean, true);
    v_co boolean := coalesce((p_args->>'committed')::boolean, true);
    v_gr boolean := coalesce((p_args->>'grounded')::boolean, true);
    v_ro boolean := coalesce((p_args->>'role_ok')::boolean, true);
    v_scores jsonb; v_verdict text;
BEGIN
    v_target := nullif(regexp_replace(coalesce(v_sess,''), '^trajcrit(ic)?--', ''), '');
    IF v_target IS NULL THEN
        RETURN jsonb_build_object('error',
            'could not resolve the run being judged from _session_id ('||coalesce(v_sess,'(null)')||')');
    END IF;
    v_scores := jsonb_build_object(
        'tool_selection',    CASE WHEN v_ts THEN 1.0 ELSE 0.0 END,
        'param_correctness', CASE WHEN v_pp THEN 1.0 ELSE 0.0 END,
        'error_handling',    CASE WHEN v_eh THEN 1.0 ELSE 0.0 END,
        'efficiency',        ((CASE WHEN v_nr THEN 1 ELSE 0 END) + (CASE WHEN v_co THEN 1 ELSE 0 END)) / 2.0,
        'grounding',         CASE WHEN v_gr THEN 1.0 ELSE 0.0 END,
        'role_adherence',    CASE WHEN v_ro THEN 1.0 ELSE 0.0 END);
    -- fail if ungrounded OR it never committed (the spiral); warn on any other "no"; else pass.
    v_verdict := CASE
        WHEN (NOT v_gr) OR (NOT v_co) THEN 'fail'
        WHEN NOT (v_ts AND v_pp AND v_eh AND v_nr AND v_ro) THEN 'warn'
        ELSE 'pass' END;
    SELECT payload->>'agent_family' INTO v_family FROM stewards.work_queue
     WHERE payload->>'session_id' = v_target AND kind='chat' ORDER BY id LIMIT 1;
    INSERT INTO stewards.trajectory_verdicts(target_session, agent_family, scores, issues, verdict)
    VALUES (v_target, v_family, v_scores,
            coalesce(p_args->'notes', '[]'::jsonb), v_verdict);
    RETURN jsonb_build_object('ok', true, 'verdict', v_verdict, 'target', v_target,
        'recorded', 'Verdict stored. You are done — no further reply needed.');
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', SQLERRM);
END $fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
('submit_trajectory_verdict',
 'Record your Glass-Box verdict on the agent run you were given. Answer each question true (good) or false (a problem), with a short note for each "false" (the note is what gets used to fix the agent). Calling this records your verdict and ends your evaluation.',
 jsonb_build_object(
   'type','object','additionalProperties', false,
   'properties', jsonb_build_object(
     'tool_selection_ok', jsonb_build_object('type','boolean','description','Did it choose appropriate tools for the task?'),
     'params_ok',         jsonb_build_object('type','boolean','description','Were the tool arguments well-formed and appropriate?'),
     'error_handling_ok', jsonb_build_object('type','boolean','description','When a tool returned an error or empty result, did it recognize that and adapt (not proceed as if it had succeeded)?'),
     'no_redundancy',     jsonb_build_object('type','boolean','description','Did it avoid repeating the same call / hammering one tool over and over?'),
     'committed',         jsonb_build_object('type','boolean','description','Did it COMMIT to a final answer instead of gathering without end? A run that calls tools many times and never answers is a spiral — answer false.'),
     'grounded',          jsonb_build_object('type','boolean','description','Is every claim supported by what it actually retrieved or was given? No fabrication, and no over-generalizing a single record into a population- or state-level stat (FIDELITY).'),
     'role_ok',           jsonb_build_object('type','boolean','description','Did it stay within its role and its granted tools?'),
     'notes',             jsonb_build_object('type','array','items', jsonb_build_object('type','string'),
                            'description','A short, specific note for each question you answered false, saying why.')),
   'required', jsonb_build_array('tool_selection_ok','params_ok','error_handling_ok','no_redundancy','committed','grounded','role_ok')),
 '{"kind":"sql_fn","schema":"stewards","name":"submit_trajectory_verdict_tool"}'::jsonb, true)
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
  execute_target=EXCLUDED.execute_target, active=true;

-- ---------------------------------------------------------------------
-- §2 — re-author the trajectory critic to ANSWER VIA THE TOOL (no free-text
-- JSON, no response_format — those let the weak model skip the questions).
-- ---------------------------------------------------------------------
UPDATE stewards.agents
   SET description = 'Glass-Box evaluator (BINEVAL): judges an agent run''s TRAJECTORY by calling submit_trajectory_verdict with binary yes/no answers + notes — forced decomposition, reliable even for a weak local model.',
       prompt = $P$You are a Glass-Box trajectory evaluator (the "BINEVAL" method). You are given the full TRAJECTORY of ONE agent run: its ordered steps — the tools it chose, the arguments it passed, the results or errors it got back, and its final reply. Judge the PROCESS, not just the output. A fluent final answer that skipped its verification steps is a MORE dangerous failure than one with a visible error.

Read the trajectory, then call **submit_trajectory_verdict** exactly once. Answer each field true (good) or false (a problem), and put a short note in `notes` for every field you answer false (the note is what gets used to fix the agent):
- tool_selection_ok — did it choose appropriate tools?
- params_ok — were the arguments well-formed?
- error_handling_ok — did it recognize errors/empty results and adapt, not proceed as if they succeeded?
- no_redundancy — did it avoid repeating the same call / hammering one tool?
- committed — did it COMMIT to a final answer instead of gathering without end? (many calls, never an answer = a spiral = false)
- grounded — is every claim supported by what it actually retrieved? No fabrication, and no over-generalizing a single record into a population- or state-level claim, or stating a subset as the whole (FIDELITY).
- role_ok — did it stay within its role and granted tools?

Calling submit_trajectory_verdict records your verdict and ends your evaluation. Do not write a free-text verdict; the tool IS your answer.$P$,
       response_format = NULL,
       temperature = 0.2,
       steps = 3,
       active = true
 WHERE family = 'trajectory-critic';

-- grant ONLY the verdict tool (it remains a no-other-tools judge).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('trajectory-critic', '*',                          'deny',  'manual'),
  ('trajectory-critic', 'submit_trajectory_verdict',  'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;
