-- =====================================================================
-- 76-wire-engram-search.sql — the agent-facing ENGRAM search, the twin
-- of 75's brain wiring.
-- =====================================================================
-- 72 built stewards.search_engrams_hybrid (real equal-weight RRF, k=60, over
-- the engram_fts lexical leg + the embedding vector leg, with an opt-in
-- same-message graph-expand) — but NO agent could reach it. Unlike the brain
-- search, the engram search had no agent-facing surface AT ALL: no tool_def,
-- and no Go MCP handler in this repo (the only engram tools agents see are
-- expand_message, mark_engram_important, re_extract_engrams — none a search).
-- 75 flagged this gap rather than filling it. This file fills it, as the exact
-- twin of 75's brain wiring.
--
-- §1 — engram_search_tool: the SQL wrapper. text-in → embed the query INLINE
--   via the embed_query pg_extern (same EXCEPTION → NULL guard as 75: no embed
--   provider ⇒ vector leg empty ⇒ graceful FTS-only fallback) → call
--   search_engrams_hybrid with that vector. Pure SQL, no Go dispatch — exactly
--   like the brain tool, and unlike the Go wrapper 72's header imagined.
--
-- §2 — the engram_search tool_def. Named for the SEARCH-tool convention
--   (doc_search / pool_search / lore_search / brain_search*), not the
--   verb-noun of the mutation tools (mark_engram_important, re_extract_engrams).
--   Substrate-wide by default (single-user deployments are first-class, so this
--   mirrors brain_search's un-scoped reach over the personal corpus); the
--   underlying fn's session/project filters are left at NULL here. Output shape
--   surfaces message_id + engram_id (the pair expand_message / mark_engram_-
--   important consume) plus tier/topic/content_preview and the fused RRF score
--   aliased to `rank` — consistent with the other search tools.
--
-- §3 — the grant. Mirror brain_search_text's families EXACTLY, no broader.
--   The resolver (tool_permission → compose_tools) defaults to ALLOW for any
--   family without a `* : deny` base, so every brain_search_text family except
--   one ALREADY reaches engram_search by that same default — granting them
--   nothing new. The lone exception is stewards-explore, which carries a
--   `* : deny` base + an explicit `brain_*` allow; engram_search does not match
--   `brain_*`, so without this row it would be denied there while brain_search
--   is allowed. Adding the single mirroring allow makes engram_search reachable
--   by EXACTLY brain_search_text's set. Brain-DENIED families (analyst, the
--   watchman family, loremaster, persona, …) keep denying engram_search too —
--   no broadening. (Verified against the live perm resolver before authoring.)
--
-- requires create_brain_search_wire (75).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — engram_search_tool: embed inline, then search_engrams_hybrid.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.engram_search_tool(p_args jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_provider text;
    v_model    text;
    v_vec      vector(768);
    v_result   jsonb;
BEGIN
    -- Embed the query INLINE (no Go wrapper — the engram tool is a sql_fn, like
    -- the brain tool). embed_query is the synchronous pg_extern; with no embed
    -- provider it raises → caught → NULL ⇒ the hybrid's vector leg is empty ⇒
    -- graceful FTS-only fallback (identical to 75's brain wiring).
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
        -- substrate-wide (session/project NULL); fused score aliased → rank.
        SELECT h.message_id, h.engram_id, h.tier, h.topic, h.content_preview,
               h.session_id, h.project_association, h.score AS rank
          FROM stewards.search_engrams_hybrid(
                   p_args->>'query',
                   v_vec,
                   NULL,   -- p_session_id: substrate-wide
                   NULL,   -- p_project_association: substrate-wide
                   coalesce((p_args->>'limit')::int, 10),
                   coalesce((p_args->>'expand')::boolean, false)
               ) h
      ) t;
    RETURN v_result;
END $func$;

COMMENT ON FUNCTION stewards.engram_search_tool(jsonb) IS
'76: the agent-facing engram search wrapper — text-in, embeds the query inline via the embed_query pg_extern (EXCEPTION → NULL ⇒ FTS-only fallback with no provider), and fuses the engram FTS + vector legs via search_engrams_hybrid (72, RRF k=60). Substrate-wide (session/project NULL). Returns message_id, engram_id, tier, topic, content_preview, session_id, project_association, and the fused score as `rank`. The clean-SQL twin of 75''s brain wiring (no Go dispatch).';

-- ---------------------------------------------------------------------
-- §2 — the engram_search tool_def. DO UPDATE so re-applies stay idempotent
-- and keep the description/schema fresh (cf. 04's doc_* tools).
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs
    (name, description, args_schema, execute_target)
VALUES
    (
        'engram_search',
        'Hybrid search over the substrate''s engram memory — the compressed HOT/MEDIUM/COLD notes the engine extracts from large tool results across sessions. Postgres FTS over (topic + content_preview) FUSED with semantic vector search via Reciprocal Rank Fusion (RRF). You pass plain text — the query is embedded server-side, no vector input needed. Returns ranked matches with message_id, engram_id (use these with expand_message to read the full content, or mark_engram_important), tier, topic, content_preview, and a fused `rank` score. Set `expand` true to also pull same-message sibling engrams. On a deployment with no embed provider it degrades to FTS-only.',
        $j${
            "type": "object",
            "properties": {
                "query":  {"type": "string", "description": "Search terms (plain language)."},
                "limit":  {"type": "integer", "description": "Max results (default 10).", "minimum": 1, "maximum": 100},
                "expand": {"type": "boolean", "description": "Also pull 1-hop same-message sibling engrams of the top hits (default false)."}
            },
            "required": ["query"]
        }$j$::jsonb,
        $j${"kind":"sql_fn","schema":"stewards","name":"engram_search_tool"}$j$::jsonb
    )
ON CONFLICT (name) DO UPDATE
SET description    = EXCLUDED.description,
    args_schema    = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target;

-- ---------------------------------------------------------------------
-- §3 — grant engram_search to EXACTLY brain_search_text's families.
-- Only stewards-explore (a `* : deny` base + `brain_*` allow) needs an explicit
-- row; every other brain_search_text family reaches engram_search by the
-- resolver's default-allow already. longest-glob-wins: this exact-name allow
-- (len 13) beats the `*` deny (len 1). No broadening — brain-denied families
-- stay engram-denied.
-- ---------------------------------------------------------------------
-- source='manual': the chain-file-grant convention (cf. 45/49/53). The source
-- column carries a CHECK (frontmatter | broadcast | manual) — value read from
-- the live constraint, not invented (data-safety checklist).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
VALUES ('stewards-explore', 'engram_search', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE
SET action = EXCLUDED.action;
