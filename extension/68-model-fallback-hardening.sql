-- =====================================================================
-- 68-model-fallback-hardening.sql — survive a pulled local model
-- =====================================================================
-- Surfaced live: with a local model taken offline (a GPU reclaimed for other
-- work), a stage routed to it and the rig returned
--   HTTP 404: "no local slot or reachable peer serves model <X>"
-- which diagnose_failure (32) classified as 'unknown' (its transient regex
-- catches 5xx/408/429, NOT a 404 model-not-loaded). 'unknown' does not trigger
-- alias failover, so the pipeline HARD-FAILED instead of walking to a live model.
--
-- Two parts, both SQL, both idempotent:
--   §1  diagnose_failure learns the pulled-model shape → 'transient', so the
--       existing alias failover (32 §3, steward_tick keys on transient/timeout)
--       walks to the next alias member instead of dying.
--   §2  make the local MoE pair MUTUAL fallback members — gemma-4-26b-a4b and
--       qwen3.6-35b-a3b each appear on the other's local aliases — so the walk
--       lands on whichever local is up (gemma gone → qwen, and vice versa),
--       preferring a live LOCAL before a paid cloud fallback.
--
-- requires create_rigor_force_final (67) — purely for chain ordering; the only
-- real deps are diagnose_failure (32) and model_aliases (31). Generic core.
-- =====================================================================

-- ── §1 — diagnose_failure: a pulled / unloaded model is TRANSIENT ────
CREATE OR REPLACE FUNCTION stewards.diagnose_failure(
    p_reason         text,
    p_failure_count  int DEFAULT 0
) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $func$
DECLARE
    v_lower text;
BEGIN
    IF p_reason IS NULL OR length(trim(p_reason)) = 0 THEN
        IF p_failure_count >= 2 THEN
            RETURN 'model_limit';
        END IF;
        RETURN 'unknown';
    END IF;

    v_lower := lower(p_reason);

    IF v_lower ~ '(timeout|timed out|context deadline exceeded|inactivity|deadline)' THEN
        RETURN 'timeout';
    END IF;

    -- Transient: any 5xx (incl. Cloudflare 52x), 408, 429/rate limits, network
    -- blips, and the common overload / "web server is down" phrasings. Provider
    -- issue, not a model-capability issue.
    IF v_lower ~ '(408|429|rate.?limit|5[0-9][0-9]|network|connection (refused|reset)|temporarily unavailable|service unavailable|overloaded|web server (is down|returned|error))' THEN
        RETURN 'transient';
    END IF;

    -- 68: a model that's OFFLINE / not loaded (a local slot reclaimed, a peer
    -- that dropped). The rig returns 404 "no local slot or reachable peer serves
    -- model X"; cloud providers say "model not found / no such model". Treat as
    -- transient so alias failover WALKS to the next (live) member instead of
    -- hard-failing the pipeline. (Checked before tool_error; "model not found"
    -- has no tool/function/schema prefix so it never collides with that class.)
    IF v_lower ~ '(no (local )?slot|serves model|no such model|model (is )?(not (found|loaded|available|currently)|does not exist|unavailable|unknown|no longer))' THEN
        RETURN 'transient';
    END IF;

    IF v_lower ~ '(tool.{0,30}(error|not found|missing|invalid)|function.{0,20}(error|not found|missing|invalid)|schema.{0,20}(error|invalid|mismatch)|validation.{0,20}(failed|error))' THEN
        RETURN 'tool_error';
    END IF;

    IF p_failure_count >= 2 THEN
        RETURN 'model_limit';
    END IF;

    RETURN 'unknown';
END;
$func$;
COMMENT ON FUNCTION stewards.diagnose_failure(text, int) IS
'68 (re-authors 32): classify a failure into (transient | timeout | model_limit | tool_error | unknown). Transient now ALSO covers a pulled/unloaded model — the rig''s 404 "no local slot or reachable peer serves model X" and cloud "model not found / no such model" — so alias failover walks to a live member instead of hard-failing when a model is taken offline.';

-- ── §2 — the local MoE pair are mutual fallback members ─────────────
-- Drop any prior ad-hoc routing of these aliases to a single local, then seed a
-- clean local-first ladder: the live local anchor (qwen3.6-35b-a3b) and gemma
-- both present on the reasoning/local aliases, with paid cloud last. Failover
-- walks by priority and excludes the member that just failed, so a pulled model
-- is skipped and the walk lands on the other local.
DO $$
BEGIN
    -- ingest (fast local): nemotron primary, then the live 35b local, then paid.
    DELETE FROM stewards.model_aliases WHERE alias='ingest' AND provider='flexllama' AND provider_model='qwen3.6-35b-a3b';
    UPDATE stewards.model_aliases SET priority=4 WHERE alias='ingest' AND provider='opencode_go';
    INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, notes) VALUES
      ('ingest','flexllama','qwen3.6-35b-a3b',2,'68: live local fallback (gemma/nemotron pulled)'),
      ('ingest','flexllama','gemma-4-26b-a4b',3,'68: local fallback')
    ON CONFLICT DO NOTHING;

    -- research-local: gemma primary, the live 35b local as fallback.
    INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, notes) VALUES
      ('research-local','flexllama','gemma-4-26b-a4b',1,'68: local MoE primary'),
      ('research-local','flexllama','qwen3.6-35b-a3b',2,'68: live local fallback (gemma pulled)')
    ON CONFLICT DO NOTHING;

    -- reason / critic already carry the qwen variants; add gemma as the vice-versa
    -- local fallback (qwen pulled → gemma), ahead of the paid cloud member.
    UPDATE stewards.model_aliases SET priority=4 WHERE alias IN ('reason','critic') AND provider='opencode_go';
    INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, notes) VALUES
      ('reason','flexllama','gemma-4-26b-a4b',3,'68: local vice-versa fallback (qwen pulled → gemma)'),
      ('critic','flexllama','gemma-4-26b-a4b',3,'68: local vice-versa fallback (qwen pulled → gemma)')
    ON CONFLICT DO NOTHING;
END $$;

-- =====================================================================
-- End of 68-model-fallback-hardening.sql
-- =====================================================================
