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
    -- #326 (2026-07-04): gateways (opencode.ai "Console Go") wrap a failed UPSTREAM
    -- in an HTTP 400 — e.g. `Error from provider (Console Go): Upstream request
    -- failed`. That is a transient upstream blip, NOT a malformed request, so match
    -- the "upstream …" phrasing. Bare 400s (real client errors) stay non-transient.
    IF v_lower ~ '(408|429|rate.?limit|5[0-9][0-9]|network|connection (refused|reset)|temporarily unavailable|service unavailable|overloaded|web server (is down|returned|error)|upstream (request )?(failed|error|unavailable|timeout))' THEN
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
'68 (re-authors 32): classify a failure into (transient | timeout | model_limit | tool_error | unknown). Transient covers a pulled/unloaded model — the rig''s 404 "no local slot or reachable peer serves model X" and cloud "model not found / no such model" — and (#326) a gateway-wrapped upstream 400 ("Error from provider (X): Upstream request failed") — so failover/retry engages on real upstream blips instead of hard-failing. Bare 400s stay non-transient.';

-- ── §2 — REMOVED 2026-07-07 (feat/lightening, model-agnostic audit §E):
-- this block used to DELETE/UPDATE/INSERT concrete rows into
-- stewards.model_aliases naming Michael's specific local-rig topology
-- (gemma-4-26b-a4b / qwen3.6-35b-a3b on flexllama, re-prioritizing
-- opencode_go members) directly in the numbered core chain — landing
-- live on every fresh install instead of in the overlay this file's own
-- sibling seeds (06-cost, 19-models, 31-model-aliases) already established
-- as the pattern ("SEED ROWS MOVED TO THE OVERLAY"). Superseded in full by
-- .spec/lightening/local-overlay-example.sql §3 (role aliases: reason/
-- ingest/critic/vision/review), which carries the SAME local-first,
-- mutual-fallback shape this block built, under Michael's current
-- ratified economics rather than this file's 2026-06 ad-hoc version. Kept
-- here as the historical record — port from the overlay, not from here.

-- =====================================================================
-- End of 68-model-fallback-hardening.sql
-- =====================================================================
