-- verify-362-park-honesty.sql — focused scratch check for #362 half 2.
--
-- Run AFTER the extension is installed (CREATE EXTENSION pg_ai_stewards).
-- Self-contained: seeds its own intent/agent/pipeline/config, asserts the
-- redispatch chokepoint clears a stale park reason, and runs the inverse
-- hypothesis (Agans rule 9) — the same UPDATE WITHOUT the v34 error=NULL line
-- leaves the stale error, so the one-line fix is exactly what closes the bug.
\set ON_ERROR_STOP on

DO $$
DECLARE
    v_intent uuid;
    v_wi     uuid;
    v_wi2    uuid;
    v_error  text;
    v_status text;
    v_qrows  int;
    c_stale  text := 'STALE: 2026-07-05 qwen3.7-plus error — Console Go waves 400 (from a PRIOR cycle)';
BEGIN
    -- ── setup: a dispatchable pipeline (a usable model, so dispatch runs to
    --    the terminal UPDATE instead of parking) ────────────────────────────
    INSERT INTO stewards.intents (slug, purpose) VALUES ('default','park-honesty check')
    ON CONFLICT (slug) DO NOTHING;
    SELECT id INTO v_intent FROM stewards.intents WHERE slug='default';

    INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
    VALUES ('smoke-park','*','park-honesty agent','primary','You are a park agent.',0.2)
    ON CONFLICT (family, model_match) DO UPDATE SET prompt=EXCLUDED.prompt;

    PERFORM stewards.config_set('default_provider', to_jsonb('opencode_go'::text), NULL);
    PERFORM stewards.config_set('default_model',    to_jsonb('kimi-k2.6'::text),  NULL);

    INSERT INTO stewards.pipelines (family, description, stages, sabbath_enabled, atonement_enabled,
        file_destination_template, file_content_jsonpath, maturity_ladder, auto_materialize_on_verified, metadata)
    VALUES ('park-pipe','park-honesty pipeline',
      '[{"name":"work","next":null,"model":"kimi-k2.6","provider":"opencode_go","agent_family":"smoke-park","auto_advance":false,"input_template":"{{input.binding_question}}"}]'::jsonb,
      false,false,NULL,NULL,'["raw","verified"]'::jsonb,false,'{}'::jsonb)
    ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages;

    -- ── POSITIVE: a redispatch clears the prior cycle's stale error ─────────
    v_wi := stewards.work_item_create('park-pipe','{"binding_question":"hello"}'::jsonb,'park-wi','tester',NULL,v_intent);
    -- Park it with a STALE error, exactly the live shape (#362): a days-old
    -- failure left on the row.
    UPDATE stewards.work_items
       SET status = 'awaiting_review', error = c_stale, updated_at = now()
     WHERE id = v_wi;

    -- pre-condition: needs_attention would quote the stale error right now.
    SELECT error INTO v_error FROM stewards.work_items WHERE id = v_wi;
    ASSERT v_error = c_stale, format('pre: stale error should be set, got: %s', v_error);

    -- Redispatch through the real chokepoint.
    PERFORM stewards.work_item_dispatch_stage(v_wi);

    SELECT status, error INTO v_status, v_error FROM stewards.work_items WHERE id = v_wi;
    SELECT count(*) INTO v_qrows FROM stewards.work_queue
      WHERE kind='chat' AND payload->>'_work_item_id' = v_wi::text;

    ASSERT v_status = 'in_progress',
        format('post: redispatch must move the item to in_progress, got: %s', v_status);
    ASSERT v_qrows = 1,
        format('post: redispatch must enqueue exactly one chat work_queue row (proves dispatch ran to the terminal UPDATE), got: %s', v_qrows);
    ASSERT v_error IS NULL,
        format('post: v34 must CLEAR the stale error on redispatch so the bell quotes only the current failure, got: %s', v_error);

    -- ── INVERSE (Agans rule 9): the SAME terminal UPDATE without the v34
    --    error=NULL line leaves the stale error — i.e. remove the fix and the
    --    bug returns. This is the exact pre-v34 write shape. ─────────────────
    v_wi2 := stewards.work_item_create('park-pipe','{"binding_question":"hi2"}'::jsonb,'park-wi2','tester',NULL,v_intent);
    UPDATE stewards.work_items
       SET status = 'awaiting_review', error = c_stale, updated_at = now()
     WHERE id = v_wi2;
    -- pre-v34 terminal UPDATE (status + session + updated_at, NO error clear):
    UPDATE stewards.work_items
       SET status = 'in_progress', session_ids = session_ids || 'inverse-sess'::text, updated_at = now()
     WHERE id = v_wi2;
    SELECT error INTO v_error FROM stewards.work_items WHERE id = v_wi2;
    ASSERT v_error = c_stale,
        format('inverse: WITHOUT the error=NULL clear the stale error persists (bug returns) — got: %s', v_error);

    -- ── teardown ────────────────────────────────────────────────────────────
    DELETE FROM stewards.config WHERE key IN ('default_provider','default_model');

    RAISE NOTICE '362 OK: redispatch (work_item_dispatch_stage) CLEARS work_items.error and enqueues the chat row (status=in_progress); the inverse proves the error=NULL line is exactly what closes the stale-park bug.';
END $$;
