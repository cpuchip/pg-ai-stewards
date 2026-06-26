-- =====================================================================
-- 64-auto-critique.sql — make trajectory verification STANDING
-- =====================================================================
-- Phase 3 of lending the substrate our orientation: the VERIFY half. Google's
-- SDLC: both output AND trajectory eval are necessary, and the skipped one hides
-- the MORE dangerous failures (a fluent answer that never ran its verification,
-- a 404 read as success, a loop that never converged). The substrate built the
-- trajectory critic (56) and the verdict→self-improvement loop (59) — but nothing
-- FIRES it; critique_trajectory was call-on-demand. So the Glass-Box half sat
-- dormant, exactly like the orientation shelf did (62).
--
-- This adds the missing FRONT: when a WORKER run finishes, automatically critique
-- its trajectory. The verdict lands via the existing harvest trigger (59) →
-- trajectory_verdicts → the self-improvement loop. The loop closes itself; this
-- is the one trigger that makes it standing. No bgworker change (a trigger
-- enqueues the critic chat the existing bgworker already drains).
--
-- COST-SAFE: default OFF (a config gate, like autonomy_paused) — an LLM critique
-- per worker run is real spend; the operator opts in, and the reflect-watchman
-- spend guard (23) still caps it. GATE INTEGRITY: never critiques a grader/steward
-- (no recursion, and we do not grade the graders) — the same exclusion the
-- eval-gaming gate (59) uses.
--
-- requires create_orient_survey (63). Generic core.
-- =====================================================================

-- ── config: the gate (default OFF) + which agent families to critique ──
SELECT stewards.config_set('auto_critique_on_complete', 'false'::jsonb,
    'When true, a WORKER run finishing automatically dispatches the trajectory-critic (56) over its trajectory; the verdict lands via the harvest trigger (59) and feeds the self-improvement loop. Default false — an LLM critique per run is real spend. Turn on per substrate when you want the Glass-Box verification half standing.');
SELECT stewards.config_set('auto_critique_families', '"research,dev,world-build"'::jsonb,
    'Comma-separated agent-family globs whose runs get auto-critiqued when auto_critique_on_complete is on (group_applies semantics). The worker families; never the graders/stewards (those are hard-excluded for gate integrity).');

-- ── the decision: a deterministic predicate (so it is testable without a live dispatch) ──
CREATE OR REPLACE FUNCTION stewards.should_auto_critique(p_session text, p_family text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_fin text; v_tools int;
BEGIN
    -- the gate
    IF coalesce((stewards.config_get('auto_critique_on_complete','false'::jsonb))::text::boolean, false) IS NOT TRUE THEN
        RETURN false;
    END IF;
    IF p_session IS NULL OR p_family IS NULL THEN RETURN false; END IF;
    -- only the configured worker families…
    IF NOT stewards.group_applies(stewards.config_get_text('auto_critique_families', ''), p_family) THEN
        RETURN false;
    END IF;
    -- …and NEVER a grader / gate / steward (no recursion; do not grade the graders)
    IF p_family IN ('trajectory-critic','world-critic','prompt-critic','judge-brief','agent-improver',
                    'compactor','engram-extractor','watchman-consolidator','reflect-steward','hinge','steward') THEN
        RETURN false;
    END IF;
    -- fire once, at the run's COMMITTED end, and only if there is a real trajectory to judge
    SELECT finish_reason INTO v_fin FROM stewards.messages
     WHERE session_id = p_session AND role = 'assistant' ORDER BY id DESC LIMIT 1;
    IF v_fin IS DISTINCT FROM 'stop' THEN RETURN false; END IF;
    SELECT (stewards.assemble_trajectory(p_session) ->> 'tool_call_count')::int INTO v_tools;
    IF coalesce(v_tools, 0) = 0 THEN RETURN false; END IF;  -- no tools → no interesting Glass-Box surface
    -- not already judged
    IF EXISTS (SELECT 1 FROM stewards.trajectory_verdicts WHERE target_session = p_session) THEN
        RETURN false;
    END IF;
    RETURN true;
END $fn$;
COMMENT ON FUNCTION stewards.should_auto_critique(text, text) IS
'64: the standing-critique predicate — config-gated, worker-families-only, graders-excluded, fires once at a run''s committed end (finish_reason=stop) when it used tools and has no verdict yet. Deterministic so the gate is testable without a live dispatch.';

-- ── the trigger: a worker run finishing → critique its trajectory ──
CREATE OR REPLACE FUNCTION stewards.auto_critique_on_complete_fn() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.status = 'done' AND OLD.status <> 'done' AND NEW.kind = 'chat'
       AND stewards.should_auto_critique(NEW.payload ->> 'session_id', NEW.payload ->> 'agent_family') THEN
        PERFORM stewards.critique_trajectory(NEW.payload ->> 'session_id');
    END IF;
    RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS work_queue_auto_critique ON stewards.work_queue;
CREATE TRIGGER work_queue_auto_critique
    AFTER UPDATE OF status ON stewards.work_queue
    FOR EACH ROW EXECUTE FUNCTION stewards.auto_critique_on_complete_fn();
COMMENT ON FUNCTION stewards.auto_critique_on_complete_fn() IS
'64: standing Glass-Box verification — when a worker chat run finishes (and should_auto_critique passes), dispatch the trajectory-critic over it. The verdict is harvested by 59 into trajectory_verdicts and feeds the self-improvement loop. Default off; graders excluded (no recursion).';

-- =====================================================================
-- End of 64-auto-critique.sql
-- =====================================================================
