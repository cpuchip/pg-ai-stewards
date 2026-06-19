-- =====================================================================
-- 33-page-in.sql — page in large tool results instead of inlining them.
-- =====================================================================
-- The problem (from the FlexLLama local-inference session, 2026-06-18):
-- compose_messages preserves the fresh tail RAW, so a single big fetch_url
-- result (~40k tokens) can blow a small window in ONE round — and the
-- budget-driven folding can't compress a message it must keep verbatim.
-- The window-aware budget (15a Layer 2.5) handles the torso; this handles
-- the fat fresh message: cap it to a head + a handle, and let the model
-- PAGE the rest on demand. Model-chosen retrieval beats lossy auto-summary,
-- and it cuts token cost on paid providers (stop shipping 200k of raw pages).
--
-- Ratified 2026-06-18 (Michael — "lets build number 3"). P0 scope:
--   * page_in_cap: compose_messages truncates any single rendered message
--     over effective_budget*ratio to head + a [page-in] banner with its handle.
--   * result_read(handle, offset, limit) / result_search(handle, query):
--     read spans / grep within the full stored message (own session + the
--     non-private watch — reuses 27's context_descendant_sessions).
-- Window-aware (rides the now-correct effective_budget): big-window models
-- rarely truncate; small windows never overflow on one fat fetch.
-- Proposal: .spec/proposals/page-in-large-results.md.
-- requires create_alias_failover (32). Generic core.
-- =====================================================================

SELECT stewards.config_set('page_in_single_msg_ratio', '0.5'::jsonb,
  '33: compose_messages caps any single rendered message to effective_budget * this ratio (tokens, ~3.5 chars/tok); over the cap -> head + a page-in banner carrying the message handle. The model reads the rest with result_read/result_search. Window-aware. 0 disables.');

-- ── the cap helper (wrapped around each rendered message by compose_messages) ──
CREATE OR REPLACE FUNCTION stewards.page_in_cap(p_obj jsonb, p_cap_chars int, p_handle text)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE
        WHEN p_cap_chars IS NULL OR p_cap_chars <= 0 THEN p_obj
        WHEN p_obj ? 'content' AND p_obj ->> 'content' IS NOT NULL
             AND length(p_obj ->> 'content') > p_cap_chars THEN
            jsonb_set(p_obj, '{content}', to_jsonb(
                left(p_obj ->> 'content', p_cap_chars)
                || E'\n\n[page-in: ' || (length(p_obj ->> 'content') - p_cap_chars)::text
                || ' more chars truncated to fit the window. Read the rest with '
                || 'result_read("' || COALESCE(p_handle, '?') || '", offset, limit) or '
                || 'result_search("' || COALESCE(p_handle, '?') || '", "your query"); '
                || 'expand_message("' || COALESCE(p_handle, '?') || '") for the full text.]'))
        ELSE p_obj
    END;
$fn$;
COMMENT ON FUNCTION stewards.page_in_cap(jsonb, int, text) IS
'33: cap a single rendered message to p_cap_chars (head) + a page-in banner carrying its handle. No-op when content fits or cap<=0. Trims only content; tool_call_id/tool_calls/reasoning_content stay intact.';

-- ── result_read — read a span of a stored message by handle ──────────
CREATE OR REPLACE FUNCTION stewards.result_read_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower((regexp_match(coalesce(p_args ->> 'handle', ''), '([0-9a-fA-F]{3,8})'))[1]);
    v_off    int  := greatest(coalesce((p_args ->> 'offset')::int, 0), 0);
    v_lim    int  := least(greatest(coalesce((p_args ->> 'limit')::int, 4000), 100), 20000);
    v_content text;
    v_total  int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle IS NULL THEN RETURN jsonb_build_object('error', 'handle required (the id from a [ctx:..] / page-in banner)'); END IF;
    SELECT m.content INTO v_content
      FROM stewards.messages m
     WHERE stewards.context_handle(m.id) = v_handle
       AND m.session_id IN (SELECT v_sess
                            UNION
                            SELECT session_id FROM stewards.context_descendant_sessions(v_sess))
     LIMIT 1;
    IF v_content IS NULL THEN RETURN jsonb_build_object('error', 'no readable message for handle ' || v_handle || ' in your context'); END IF;
    v_total := length(v_content);
    RETURN jsonb_build_object(
        'ok', true, 'handle', v_handle, 'offset', v_off, 'total_chars', v_total,
        'returned', substring(v_content from v_off + 1 for v_lim),
        'has_more', (v_off + v_lim < v_total),
        'note', CASE WHEN v_off + v_lim < v_total
                     THEN 'more available — call again with offset=' || (v_off + v_lim)::text
                     ELSE 'end of content' END);
END;
$fn$;

-- ── result_search — grep within a stored message by handle ───────────
CREATE OR REPLACE FUNCTION stewards.result_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_sess   text := p_args ->> '_session_id';
    v_handle text := lower((regexp_match(coalesce(p_args ->> 'handle', ''), '([0-9a-fA-F]{3,8})'))[1]);
    v_query  text := p_args ->> 'query';
    v_lim    int  := least(greatest(coalesce((p_args ->> 'limit')::int, 5), 1), 20);
    v_content text;
    v_res    jsonb;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error', 'no session context'); END IF;
    IF v_handle IS NULL THEN RETURN jsonb_build_object('error', 'handle required'); END IF;
    IF v_query IS NULL OR btrim(v_query) = '' THEN RETURN jsonb_build_object('error', 'query required'); END IF;
    BEGIN PERFORM regexp_instr('probe', v_query, 1, 1, 0, 'i');
    EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', 'invalid regex: ' || SQLERRM); END;
    SELECT m.content INTO v_content
      FROM stewards.messages m
     WHERE stewards.context_handle(m.id) = v_handle
       AND m.session_id IN (SELECT v_sess
                            UNION
                            SELECT session_id FROM stewards.context_descendant_sessions(v_sess))
     LIMIT 1;
    IF v_content IS NULL THEN RETURN jsonb_build_object('error', 'no readable message for handle ' || v_handle); END IF;
    SELECT jsonb_agg(jsonb_build_object(
               'at', off,
               'snippet', regexp_replace(substring(v_content from greatest(1, off - 60) for 220), '\s+', ' ', 'g')
           ) ORDER BY off)
      INTO v_res
    FROM (SELECT regexp_instr(v_content, v_query, 1, g, 0, 'i') AS off
            FROM generate_series(1, v_lim) g) s
   WHERE off > 0;
    RETURN jsonb_build_object('ok', true, 'handle', v_handle, 'query', v_query,
        'matches', coalesce(v_res, '[]'::jsonb),
        'note', 'offsets are char positions — result_read(handle, offset, limit) to read a span in full');
END;
$fn$;

-- ── register the tools (sql_fn — no bridge refresh needed) ────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'result_read',
  'Read a span of a large tool result that was page-in truncated in your context. When a fetched page / document is too big to inline, you see its head plus a [page-in] banner with a handle; call result_read with that handle to read the rest in chunks. The full text is durable — you choose what to pull into your window.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the id from a [ctx:..] or page-in banner"},'
    '"offset":{"type":"integer","description":"start char offset (default 0)"},'
    '"limit":{"type":"integer","description":"chars to return (default 4000, max 20000)"}'
  '},"required":["handle"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"result_read_tool"}'::jsonb, true ),
( 'result_search',
  'Grep within a large tool result that was page-in truncated. Pass the handle from the [page-in] banner and a text/regex query; returns the char offsets + snippets of each match so you can result_read the right span. Use this to find the part of a big page you actually need without pulling the whole thing into your window.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"handle":{"type":"string","description":"the id from a [ctx:..] or page-in banner"},'
    '"query":{"type":"string","description":"text or POSIX regex to find (case-insensitive)"},'
    '"limit":{"type":"integer","description":"max matches (default 5, max 20)"}'
  '},"required":["handle","query"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"result_search_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- ── grant to the tool-using doers (idempotent) ───────────────────────
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source)
SELECT v.a, v.b, 'allow', 'manual'
  FROM (VALUES ('research','result_read'), ('research','result_search'),
               ('dev','result_read'), ('dev','result_search')) v(a, b)
 WHERE NOT EXISTS (
        SELECT 1 FROM stewards.agent_tool_perms p
         WHERE p.agent_family = v.a AND p.tool_pattern = v.b AND p.action = 'allow');

-- =====================================================================
-- End of 33-page-in.sql
-- =====================================================================
