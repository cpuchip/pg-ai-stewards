-- =====================================================================
-- v48 — the window clamp: every budget layer bounded by the model's
--       real context window
-- =====================================================================
-- Ruling context (2026-08-08, cache-experiment arms A/D/E): three local
-- workflow runs composed past their server's n_ctx and died HTTP 400
-- (67,174 > 65,536 · 50,293 > 49,152 · 70,348 > 65,536). Layer 2.5 of
-- effective_budget (window-aware budget, 2026-06-18) already knew how to
-- clamp — but (a) every local seat's model_capability.context_window was
-- NULL so it never fired, and (b) Layers 1/2 (stage / agent budgets)
-- RETURN EARLY, bypassing the clamp entirely even when it would fire.
-- work_items.token_budget is a SPEND gate, not a compose bound — it never
-- constrained composition at all.
--
-- The fix: hoist the model-window lookup to the top and bound EVERY
-- return path with LEAST(value, floor(window * 0.70)). The 0.70 keeps
-- 30% of the window free for reasoning + output (a near-full window
-- starves generation), and absorbs some of the chars/3.5 estimator's
-- undercount on JSON/reasoning-heavy traffic (~30-40% observed).
-- Models with no known window behave exactly as before.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.effective_budget(p_session_id text, p_stage_name text DEFAULT NULL::text)
 RETURNS integer
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_work_item    stewards.work_items%ROWTYPE;
    v_stage_name   text := p_stage_name;
    v_agent_family text;
    v_budget       int;
    v_provider     text;
    v_context_win  int;
    v_model        text;
    v_model_win    int;
    v_clamp        int;   -- v48: floor(model window * 0.70), NULL when unknown
BEGIN
    SELECT * INTO v_work_item
      FROM stewards.work_items
     WHERE p_session_id = ANY(session_ids)
     LIMIT 1;

    IF v_stage_name IS NULL THEN
        v_stage_name := v_work_item.current_stage;
    END IF;

    v_provider := stewards.provider_for_session(p_session_id);

    -- v48: the Layer-2.5 model-window lookup, HOISTED — the clamp must bound
    -- every layer below, not only the fall-through path. (First compose of a
    -- session has no prior chat row → no clamp on round 1; round 1 is small.)
    SELECT payload -> 'body' ->> 'model' INTO v_model
      FROM stewards.work_queue
     WHERE payload ->> 'session_id' = p_session_id
       AND kind = 'chat'
     ORDER BY id DESC
     LIMIT 1;
    IF v_model IS NOT NULL THEN
        SELECT context_window INTO v_model_win
          FROM stewards.model_capability
         WHERE model = v_model
           AND context_window IS NOT NULL
         ORDER BY (provider = v_provider) DESC NULLS LAST
         LIMIT 1;
        IF v_model_win IS NOT NULL AND v_model_win > 0 THEN
            v_clamp := floor(v_model_win * 0.70)::int;
        END IF;
    END IF;

    -- Layer 1: pipeline-stage (now window-bounded).
    v_budget := stewards.stage_working_budget(v_work_item.pipeline_family, v_stage_name);
    IF v_budget IS NOT NULL AND v_budget > 0 THEN
        RETURN LEAST(v_budget, COALESCE(v_clamp, v_budget));
    END IF;

    -- Layer 2: agent — resolve from the most-recent chat payload on this session.
    SELECT payload ->> 'agent_family' INTO v_agent_family
      FROM stewards.work_queue
     WHERE payload ->> 'session_id' = p_session_id
       AND kind = 'chat'
     ORDER BY id DESC
     LIMIT 1;

    IF v_agent_family IS NOT NULL THEN
        SELECT working_budget INTO v_budget
          FROM stewards.agents
         WHERE family = v_agent_family
           AND active
         ORDER BY model_match = '*' ASC  -- prefer specific match
         LIMIT 1;
        IF v_budget IS NOT NULL AND v_budget > 0 THEN
            RETURN LEAST(v_budget, COALESCE(v_clamp, v_budget));
        END IF;
    END IF;

    -- Layer 2.5: the model window alone (lookup already done above).
    IF v_clamp IS NOT NULL THEN
        RETURN v_clamp;
    END IF;

    -- Layer 3: provider.context_window (now window-bounded — a provider-wide
    -- number can exceed a specific local model's window only when the model
    -- window is unknown, in which case v_clamp is NULL and this is unchanged).
    IF v_provider IS NOT NULL THEN
        SELECT context_window INTO v_context_win
          FROM stewards.provider_rules
         WHERE name = v_provider;
        IF v_context_win IS NOT NULL AND v_context_win > 0 THEN
            RETURN v_context_win;
        END IF;
    END IF;

    -- Final fallback: a conservative default so callers never get NULL.
    RETURN 64000;
END;
$function$;

COMMENT ON FUNCTION stewards.effective_budget(text, text) IS
'Budget cascade: stage working_budget -> agent working_budget -> model window * 0.70 -> provider window -> 64000. v48: the model-window clamp (Layer 2.5) is hoisted and bounds EVERY layer — three local runs composed past n_ctx and 400d because stage/agent budgets returned early, bypassing the clamp, and local seats had NULL context_window.';

-- Visibility: expose context_window on the catalog view (column appended —
-- CREATE OR REPLACE VIEW allows appending only).
CREATE OR REPLACE VIEW stewards.model_catalog AS
 SELECT mp.provider,
    mp.model,
    mp.input_micro_per_mtok,
    mp.output_micro_per_mtok,
    mp.notes AS pricing_notes,
    COALESCE(mc.usable, true) AS usable,
    mc.supports_streaming,
    mc.last_probed_at,
    mc.probe_detail,
    COALESCE(mc.probed_via, 'unprobed'::text) AS probed_via,
    mc.context_window
   FROM (( SELECT DISTINCT ON (model_pricing.provider, model_pricing.model) model_pricing.provider,
            model_pricing.model,
            model_pricing.input_micro_per_mtok,
            model_pricing.output_micro_per_mtok,
            model_pricing.notes
           FROM stewards.model_pricing
          ORDER BY model_pricing.provider, model_pricing.model, model_pricing.effective_at DESC) mp
     LEFT JOIN stewards.model_capability mc ON (((mc.provider = mp.provider) AND (mc.model = mp.model))));

-- Seed the known local windows (the rows whose NULLs caused the DNFs).
-- These reflect the llama-server -c values the seats are launched with;
-- relaunching at a different -c means updating the row (P2 auto-probe will
-- take this over via /props).
UPDATE stewards.model_capability SET context_window = 131072
 WHERE provider = 'flexllama' AND model = 'gemma-4-26b-a4b';
UPDATE stewards.model_capability SET context_window = 65536
 WHERE provider = 'flexllama' AND model = 'laguna-s';
UPDATE stewards.model_capability SET context_window = 49152
 WHERE provider = 'flexllama' AND model = 'deepseek-v4-flash-local';
UPDATE stewards.model_capability SET context_window = 65536
 WHERE provider = 'flexllama' AND model = 'qwen3.6-27b';
