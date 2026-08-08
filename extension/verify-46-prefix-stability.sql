-- v46 verification — the prefix-stability oracle (cache discipline).
--
-- Asserts the STABLE-FIRST LAW on a real session: composing the same session
-- twice is byte-deterministic, the system prompt is byte-stable across a
-- synthetic appended round, and the history prefix outside the tail
-- allowance re-renders identically. This is the check that failed on
-- pre-v46 code (the pressure line churned the system prompt every round;
-- 30 days of cost_events showed 0 cache_read_tokens on every provider).
--
-- Run with:
--   Get-Content verify-46-prefix-stability.sql | docker exec -i <pg> psql -U stewards -d stewards
--
-- Self-contained: wraps the oracle's synthetic insert/delete in a rolled-back
-- transaction; skips (loudly) when the DB has no session with >= 4 messages.

\set ON_ERROR_STOP 1

BEGIN;

DO $$
DECLARE
    v_sess  text;
    v_fam   text;
    v_model text;
    v_rep   jsonb;
BEGIN
    SELECT m.session_id, s.agent_family
      INTO v_sess, v_fam
      FROM stewards.messages m
      JOIN stewards.sessions s ON s.id = m.session_id
     WHERE s.agent_family IS NOT NULL
     GROUP BY m.session_id, s.agent_family
    HAVING count(*) >= 4
     ORDER BY max(m.created_at) DESC
     LIMIT 1;

    IF v_sess IS NULL THEN
        RAISE NOTICE 'prefix-stability: SKIP — no session with >= 4 messages and an agent_family';
        RETURN;
    END IF;

    SELECT ce.model INTO v_model
      FROM stewards.cost_events ce
     WHERE ce.session_id = v_sess
     ORDER BY ce.at DESC
     LIMIT 1;
    v_model := COALESCE(v_model, 'verify');

    v_rep := stewards.prefix_stability_check(v_fam, v_model, v_sess);

    RAISE NOTICE 'prefix-stability report (session=%, family=%, model=%): %',
        v_sess, v_fam, v_model, v_rep::text;

    IF NOT (v_rep ->> 'ok')::boolean THEN
        RAISE EXCEPTION 'PREFIX STABILITY FAILED — the composed prompt is cache-poisoned again. Report: %',
            v_rep::text;
    END IF;

    RAISE NOTICE 'prefix-stability: OK (system stable, history prefix stable, deterministic)';
END;
$$;

ROLLBACK;
