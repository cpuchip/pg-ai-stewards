-- v71 verification: tool rounds count per turn, not per session.
--
-- The same block as virgin-smoke OK 138, runnable against a LIVE record: it
-- creates its own session, calls chat_post_internal for three user turns, and
-- the transaction is rolled back regardless. Run with:
--   docker exec -i <pg> psql -U stewards -d stewards < extension/verify-71-per-turn-rounds.sql
-- Exit 0 and the OK 138 notice = the fix is live on that record.

\set ON_ERROR_STOP 1

BEGIN;
-- OK 138 (v71): tool rounds count per turn. A session with a second user
-- message starts that turn's count at zero: the first turn at its hard cap is
-- forced to answer, the next turn keeps its tools; and the soft-cap notice,
-- given once in the first turn, is given again in the next, and only once
-- within a turn however many rounds pass the soft cap. On v67 the second
-- turn inherited the first turn's rounds and was forced to answer with
-- tool_choice none (so no notice came in turns 2 or 3 either). A session with
-- no user message counts every round, as before (OK 56).
DO $vs138$
DECLARE
    v_steps  int;
    v_soft   int;
    v_hard   int;
    v_id1    bigint;
    v_id2    bigint;
    v_id3    bigint;
    v_id4    bigint;
    v_forced text;
    v_turn2  text;
    v_note   int;
    v_q4     bigint;
    v_r      int;
    v_ids    bigint[] := '{}';
    v_keep   int;
BEGIN
    SELECT a.steps INTO v_steps FROM stewards.agents a
     WHERE a.family = 'work-item-chat' ORDER BY length(a.model_match) DESC LIMIT 1;
    ASSERT COALESCE(v_steps, 0) >= 6, 'v71: work-item-chat has a real tool budget (>=6)';
    -- a budget with room between the soft and hard caps (restored below)
    v_keep := v_steps;
    UPDATE stewards.agents SET steps = 20 WHERE family = 'work-item-chat';
    v_steps := 20;
    v_hard := GREATEST(v_steps - 2, 2);
    v_soft := GREATEST((v_steps * 0.7)::int, 1);

    INSERT INTO stewards.sessions(id, kind) VALUES ('pt-smoke-71', 'agent');
    -- turn 1: at the hard cap, forced to answer (unchanged)
    INSERT INTO stewards.messages(session_id, role, content) VALUES ('pt-smoke-71', 'user', 'q1');
    INSERT INTO stewards.messages(session_id, role, content, finish_reason)
      SELECT 'pt-smoke-71', 'assistant', 't1-' || g, 'tool_calls' FROM generate_series(1, v_hard) g;
    v_id1 := stewards.chat_post_internal('work-item-chat', 'reason', 'pt-smoke-71', 'flexllama');
    SELECT payload->>'tools_disabled' INTO v_forced FROM stewards.work_queue WHERE id = v_id1;
    ASSERT v_forced = 'true', 'v71: within one turn the hard cap still forces an answer';

    -- turn 2: a new user message; its count starts at zero
    INSERT INTO stewards.messages(session_id, role, content) VALUES ('pt-smoke-71', 'user', 'q2');
    v_id2 := stewards.chat_post_internal('work-item-chat', 'reason', 'pt-smoke-71', 'flexllama');
    SELECT payload->>'tools_disabled' INTO v_turn2 FROM stewards.work_queue WHERE id = v_id2;
    ASSERT v_turn2 IS NULL, 'v71: a new user turn keeps its tools (its rounds start at zero, not at the session''s count)';

    -- the soft notice: given in turn 2 at its soft cap, and again in turn 3 at its own
    INSERT INTO stewards.messages(session_id, role, content, finish_reason)
      SELECT 'pt-smoke-71', 'assistant', 't2-' || g, 'tool_calls' FROM generate_series(1, v_soft) g;
    v_id3 := stewards.chat_post_internal('work-item-chat', 'reason', 'pt-smoke-71', 'flexllama');
    INSERT INTO stewards.messages(session_id, role, content) VALUES ('pt-smoke-71', 'user', 'q3');
    INSERT INTO stewards.messages(session_id, role, content, finish_reason)
      SELECT 'pt-smoke-71', 'assistant', 't3-' || g, 'tool_calls' FROM generate_series(1, v_soft) g;
    v_id4 := stewards.chat_post_internal('work-item-chat', 'reason', 'pt-smoke-71', 'flexllama');
    SELECT count(*) INTO v_note FROM stewards.work_queue
     WHERE id IN (v_id3, v_id4) AND (payload->>'_soft_cap_notified')::boolean;
    ASSERT v_note = 2, format('v71: the soft-cap notice is given once per turn (turns 2 and 3), got %s', v_note);

    -- within one turn, four rounds from the soft cap toward the hard cap: one notice, not one every other round
    INSERT INTO stewards.messages(session_id, role, content) VALUES ('pt-smoke-71', 'user', 'q4');
    INSERT INTO stewards.messages(session_id, role, content, finish_reason)
      SELECT 'pt-smoke-71', 'assistant', 't4-' || g, 'tool_calls' FROM generate_series(1, v_soft - 1) g;
    v_q4 := (SELECT max(id) FROM stewards.messages WHERE session_id = 'pt-smoke-71' AND role = 'user');
    FOR v_r IN 1..LEAST(4, v_hard - v_soft) LOOP
        INSERT INTO stewards.messages(session_id, role, content, finish_reason)
        VALUES ('pt-smoke-71', 'assistant', 't4-more-' || v_r, 'tool_calls');
        v_ids := v_ids || stewards.chat_post_internal('work-item-chat', 'reason', 'pt-smoke-71', 'flexllama');
    END LOOP;
    SELECT count(*) INTO v_note FROM stewards.messages
     WHERE session_id = 'pt-smoke-71' AND role = 'system' AND id > v_q4;
    ASSERT v_note = 1, format('v71: one soft-cap notice per turn, not one every other round (got %s in %s rounds)', v_note, cardinality(v_ids));

    UPDATE stewards.agents SET steps = v_keep WHERE family = 'work-item-chat';
    DELETE FROM stewards.work_queue WHERE id IN (v_id1, v_id2, v_id3, v_id4) OR id = ANY(v_ids);
    DELETE FROM stewards.messages WHERE session_id = 'pt-smoke-71';
    DELETE FROM stewards.sessions WHERE id = 'pt-smoke-71';
    RAISE NOTICE 'OK 138: tool rounds count per turn; a new user turn keeps its tools and gets its own soft-cap notice; one turn at its cap is still forced to answer; one notice per turn (v71)';
END $vs138$;

ROLLBACK;
