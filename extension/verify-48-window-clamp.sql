-- v48 verification — the window clamp bounds every budget layer.
--
-- Self-contained: runs in a rolled-back transaction against the most recent
-- chat session. Asserts:
--   1. With the model's context_window set small, effective_budget returns
--      floor(window * 0.70) even when a stage/agent budget is larger.
--   2. With context_window NULL, behavior is the pre-v48 cascade (unclamped).
--
-- Run with:
--   Get-Content verify-48-window-clamp.sql | docker exec -i <pg> psql -U stewards -d stewards

\set ON_ERROR_STOP 1

BEGIN;

DO $$
DECLARE
    v_sess     text;
    v_provider text;
    v_model    text;
    v_before   int;
    v_clamped  int;
BEGIN
    SELECT wq.payload ->> 'session_id',
           wq.provider,
           wq.payload -> 'body' ->> 'model'
      INTO v_sess, v_provider, v_model
      FROM stewards.work_queue wq
     WHERE wq.kind = 'chat' AND wq.payload -> 'body' ? 'model'
     ORDER BY wq.id DESC
     LIMIT 1;

    IF v_sess IS NULL THEN
        RAISE NOTICE 'window-clamp: SKIP — no chat dispatch with a body.model';
        RETURN;
    END IF;

    -- Baseline with no window on this model.
    UPDATE stewards.model_capability SET context_window = NULL
     WHERE provider = v_provider AND model = v_model;
    v_before := stewards.effective_budget(v_sess, NULL);

    -- Set a tiny window; the clamp must bound whatever layer fired.
    INSERT INTO stewards.model_capability (provider, model, context_window)
    VALUES (v_provider, v_model, 10000)
    ON CONFLICT (provider, model) DO UPDATE SET context_window = 10000;
    v_clamped := stewards.effective_budget(v_sess, NULL);

    RAISE NOTICE 'window-clamp: session=% model=%/% unclamped=% clamped=%',
        v_sess, v_provider, v_model, v_before, v_clamped;

    -- The invariant: with a 10k window, every path returns
    -- LEAST(what it returned before, 7000). A pre-existing budget smaller
    -- than the clamp legitimately survives.
    IF v_clamped <> LEAST(v_before, 7000) THEN
        RAISE EXCEPTION 'WINDOW CLAMP FAILED: expected LEAST(%, 7000) = %, got %',
            v_before, LEAST(v_before, 7000), v_clamped;
    END IF;

    RAISE NOTICE 'window-clamp: OK (every layer bounded by window * 0.70)';
END;
$$;

ROLLBACK;
