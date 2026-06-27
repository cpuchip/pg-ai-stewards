-- =====================================================================
-- 75-wire-brain-hybrid.sql — the agent-facing brain search, finally hybrid.
-- =====================================================================
-- 73 built stewards.brain_search_hybrid (real equal-weight RRF, k=60, over
-- the FTS leg brain_search_text + the vector leg over brain_entries.embedding)
-- but left the AGENT-FACING tool on the single-leg path: the tool_def
-- 'brain_search_text' dispatches (execute_target sql_fn) to the wrapper
-- stewards.brain_search_text_tool, which still calls the FTS-only
-- brain_search_text. So agents never got the semantic leg.
--
-- This file repoints that wrapper — exactly as 71 §3 repointed doc_search_tool
-- to doc_search_hybrid, and 72 §2.3 repointed pool_search_tool. It is the
-- documented brain_search_semantic the schema.rs Phase-1.5 seed promised:
--   "a future brain_search_semantic (text-in, embed-via-worker, vec-search)
--    will replace it."
--
-- THE KEY INSIGHT (why this is a clean SQL swap, not a Go change):
-- 73's header reasoned that wiring the brain tool to the hybrid was "a
-- query-side-embed change in the Go/becoming layer ... exactly like 72 left
-- search_engrams_hybrid's Go wiring." That is true for the ENGRAM search,
-- whose agent-facing wrapper is a Go MCP tool. It is NOT true for the BRAIN
-- search: its agent-facing wrapper (brain_search_text_tool) is a pure SQL
-- sql_fn, and stewards.embed_query is a synchronous pg_extern. So the query
-- can be embedded INLINE IN SQL inside the wrapper — no Go dispatch involved.
-- That is what this file does.
--
-- The embed round-trip uses the SAME graceful EXCEPTION → NULL fallback as
-- 71/72's doc/pool tools: on a deployment with no embed provider (e.g. the
-- virgin-smoke env) embed_query raises, v_vec becomes NULL, brain_search_hybrid's
-- vector leg is empty, and the tool degrades cleanly to FTS-only — which must
-- still work. brain_search_hybrid takes the query embedding as a PARAMETER
-- (73's design), so this wrapper is the right place for the embed: it is the
-- "caller" 73's comment referred to.
--
-- Output shape is PRESERVED. The hybrid's fused-score column is `score`; the
-- old FTS tool surfaced `rank`. We alias score → rank so the agent-visible
-- keys stay (id, title, category, rank) — matching 71/72's convention of
-- surfacing the fused RRF score under the surface's original score-column name
-- (doc_search_hybrid / pool_search_hybrid both name theirs `rank`). The tool
-- args (query, category, limit) are unchanged, so args_schema is untouched.
--
-- The bare legs (brain_search_text, brain_search_vec) and the hybrid fn itself
-- are LEFT INTACT — this file changes only the agent-facing wrapper + the
-- tool_def description (made honest: it is hybrid now, and degrades to FTS-only
-- with no provider). The execute_target is unchanged (still the sql_fn
-- brain_search_text_tool), so the dispatch path is identical.
--
-- NOT done here (flagged, not invented): the ENGRAM search has no agent-facing
-- tool in this repo at all — no tool_def and no search_engrams Go handler;
-- search_engrams_hybrid (72) is an internal SQL fn only. Wiring it would mean
-- creating a new agent tool surface, which is out of scope without a council
-- nod. Left for a follow-up.
--
-- requires create_north_star (74).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Repoint the agent-facing brain search wrapper to the hybrid: embed the
-- query text INLINE via the embed_query pg_extern, then call
-- brain_search_hybrid with that vector. plpgsql (was sql) for the
-- EXCEPTION → NULL embed fallback. execute_target is unchanged, so the
-- tool_def 'brain_search_text' now resolves, through the same sql_fn, to
-- the hybrid path.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.brain_search_text_tool(p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_result   jsonb;
BEGIN
    -- Embed the query INLINE. embed_query is the synchronous pg_extern; with
    -- no embed provider configured it raises → caught → NULL ⇒ the hybrid's
    -- vector leg is empty ⇒ graceful FTS-only fallback (cf. 71/72's doc/pool).
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    BEGIN
        v_vec := stewards.embed_query(p_args->>'query', v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;   -- no embed provider / down: FTS-only
    END;

    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
      INTO v_result
      FROM (
        -- alias the fused score → rank to preserve the prior output shape
        -- (id, title, category, rank), mirroring 71/72's tools.
        SELECT h.id, h.title, h.category, h.score AS rank
          FROM stewards.brain_search_hybrid(
                   p_args->>'query',
                   v_vec,
                   p_args->>'category',
                   coalesce((p_args->>'limit')::int, 20)
               ) h
      ) t;
    RETURN v_result;
END $func$;

COMMENT ON FUNCTION stewards.brain_search_text_tool(jsonb) IS
'75: the agent-facing brain search wrapper, repointed to brain_search_hybrid (73). Embeds the query text inline via the embed_query pg_extern (EXCEPTION → NULL ⇒ FTS-only fallback with no provider) and fuses the FTS + vector legs via RRF. The fused score is aliased to `rank` to preserve the prior output shape (id, title, category, rank). This is the documented brain_search_semantic, made real as a clean SQL swap (no Go dispatch — the brain tool is a sql_fn, unlike the engram search whose wrapper is Go).';

-- Make the tool_def description honest now that the tool is hybrid (the agent
-- sees the description, not the wrapper). Args are unchanged → args_schema is
-- left as-is. The tool NAME and execute_target are kept (the established
-- agent-facing surface; renaming would touch the brain_* permission glob and
-- the reaper fixtures for no behavioral gain — cf. 71/72 keeping doc_search /
-- pool_search names while making them hybrid).
UPDATE stewards.tool_defs
   SET description = 'Hybrid search over your personal brain entries (notes, ideas, study fragments): Postgres FTS over the entry text FUSED with semantic vector search via Reciprocal Rank Fusion (RRF). You pass plain text — the query is embedded server-side, no vector input needed. Returns ranked matches with id, title, category, and a fused `rank` score. Optionally filter with `category`. On a deployment with no embed provider it degrades to FTS-only.'
 WHERE name = 'brain_search_text';
