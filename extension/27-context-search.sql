-- =====================================================================
-- 27-context-search.sql — context_search: deterministic grep over an
-- agent's OWN durable context (+ the watch over descendants), with a
-- private wall. A model's window is a lossy sliding pane; our messages
-- are durable rows, so we hand the agent the Ctrl-F it structurally can't
-- do over its own history.
-- =====================================================================
-- Ratified 2026-06-17 (Michael, council). P0 scope:
--   * `session`     — this session only (always; sees its own private context).
--   * `descendants` — this session + the NON-private sessions spawned under
--                     me (D&C 121 "watch what you order"), resolved via the
--                     work_items parent_work_item_id lineage + session_ids.
--   * a MANUAL session-level `private` flag that BEATS the watch — a private
--     child is invisible even to its parent (the security primitive:
--     sensitive work, e.g. on a local non-cloud model, walls its context).
--     The wall is ABSOLUTE; no parent can compel it down.
-- Curated by default (verbatim+pinned); `include_folded` reaches the folded
-- layer (muted/compressed) to RECOVER something to re-open. Results carry a
-- snippet + [ctx:handle] + session, so an own-session hit round-trips
-- through expand_message / context_resolve_handle.
--
-- Provenance != truth: context_search tells an agent what it SAID, not that
-- it was correct — self-recall, not a substitute for source verification.
--
-- DEFERRED to P1 (see .spec/proposals/context-search.md): `self` (all my
-- historical sessions — needs a session->agent identity map that doesn't
-- exist yet); `ancestors` (child -> parent, private-by-default) + per-message
-- private; the `sensitive` intent/agent flag (force local-dispatch + private
-- together); a per-tool-group usage primer for adoption.
--
-- requires create_productivity (26). Generic core. `context_search` and
-- `context_session_private` are `context_*` names, so the compose_tools FINAL
-- (26) already surfaces them on context-enabled agents — NO re-author needed.
-- =====================================================================

-- ── the private wall ─────────────────────────────────────────────────
-- Manual, default off (no sensitive workload yet; there for when needed).
ALTER TABLE stewards.sessions ADD COLUMN IF NOT EXISTS private boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN stewards.sessions.private IS
'When true, this session''s messages are searchable ONLY by itself via context_search — invisible to every other session INCLUDING its own parent (the wall beats the watch). Set via context_session_private. The security primitive for sensitive work (e.g. a steward dispatching to a local non-cloud model). Absolute: no parent can compel it down (D&C 121).';

-- ── snippet helper: a window centred on the first match ───────────────
CREATE OR REPLACE FUNCTION stewards.context_search_snippet(p_content text, p_pattern text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE v_off int; v_start int; v_snip text;
BEGIN
    IF p_content IS NULL OR p_content = '' THEN RETURN ''; END IF;
    v_off := regexp_instr(p_content, p_pattern, 1, 1, 0, 'i');
    IF v_off IS NULL OR v_off = 0 THEN
        RETURN left(regexp_replace(p_content, '\s+', ' ', 'g'), 200);
    END IF;
    v_start := greatest(1, v_off - 60);
    v_snip  := regexp_replace(substring(p_content from v_start for 200), '\s+', ' ', 'g');
    RETURN (CASE WHEN v_start > 1 THEN '…' ELSE '' END) || btrim(v_snip) ||
           (CASE WHEN v_start - 1 + 200 < length(p_content) THEN '…' ELSE '' END);
END;
$fn$;

-- ── descendant-session resolver (the watch) ──────────────────────────
-- my work_item (the one whose session_ids contains me) -> recurse
-- parent_work_item_id downward -> their session_ids; NON-private only.
CREATE OR REPLACE FUNCTION stewards.context_descendant_sessions(p_session_id text)
RETURNS TABLE(session_id text) LANGUAGE sql STABLE AS $fn$
    WITH RECURSIVE me AS (
        SELECT id FROM stewards.work_items
         WHERE session_ids @> ARRAY[p_session_id]
    ),
    tree AS (
        SELECT w.id FROM stewards.work_items w JOIN me ON w.parent_work_item_id = me.id
        UNION ALL
        SELECT c.id FROM stewards.work_items c JOIN tree t ON c.parent_work_item_id = t.id
    )
    SELECT DISTINCT s.id
      FROM tree t
      JOIN stewards.work_items w ON w.id = t.id
      CROSS JOIN LATERAL unnest(coalesce(w.session_ids, ARRAY[]::text[])) AS sid
      JOIN stewards.sessions s ON s.id = sid
     WHERE NOT s.private;
$fn$;
COMMENT ON FUNCTION stewards.context_descendant_sessions(text) IS
'P0 watch: the NON-private sessions spawned under p_session_id, via the work_items parent_work_item_id lineage + session_ids. A private descendant is excluded (the wall beats the watch).';

-- ── context_search — the tool ────────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.context_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_sess     text := p_args->>'_session_id';
    v_pat      text := p_args->>'pattern';
    v_scope    text := lower(coalesce(NULLIF(p_args->>'scope',''), 'session'));
    v_folded   bool := coalesce((p_args->>'include_folded')::bool, false);
    v_limit    int  := least(greatest(coalesce((p_args->>'limit')::int, 20), 1), 100);
    v_sessions text[];
    v_results  jsonb;
    v_count    int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_pat IS NULL OR btrim(v_pat) = '' THEN RETURN jsonb_build_object('error','pattern required'); END IF;
    -- guard: reject a pattern that won't compile as a POSIX regex
    BEGIN PERFORM regexp_instr('probe', v_pat, 1, 1, 0, 'i');
    EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error','invalid regex: '||SQLERRM); END;

    IF v_scope = 'descendants' THEN
        v_sessions := ARRAY(SELECT v_sess
                             UNION
                            SELECT session_id FROM stewards.context_descendant_sessions(v_sess));
    ELSE
        -- 'session' (default). 'self'/'ancestors'/'global' are P1 -> own for now.
        v_scope := 'session';
        v_sessions := ARRAY[v_sess];
    END IF;

    SELECT jsonb_agg(hits.r ORDER BY hits.id DESC), count(*)
      INTO v_results, v_count
    FROM (
        SELECT jsonb_build_object(
                   'session', m.session_id,
                   'handle',  '[ctx:'||stewards.context_handle(m.id)||']',
                   'id',      m.id,
                   'role',    m.role,
                   'at',      to_char(m.created_at,'YYYY-MM-DD HH24:MI'),
                   'state',   m.context_state,
                   'folded',  (m.context_state NOT IN ('verbatim','pinned')),
                   'snippet', stewards.context_search_snippet(m.content, v_pat)
               ) AS r,
               m.id AS id
          FROM stewards.messages m
         WHERE m.session_id = ANY(v_sessions)
           AND m.content ~* v_pat
           AND (v_folded OR m.context_state IN ('verbatim','pinned'))
         ORDER BY m.id DESC
         LIMIT v_limit
    ) hits;

    RETURN jsonb_build_object(
        'ok', true,
        'scope', v_scope,
        'sessions_searched', coalesce(array_length(v_sessions,1),0),
        'include_folded', v_folded,
        'count', coalesce(v_count,0),
        'results', coalesce(v_results, '[]'::jsonb),
        'note', CASE
                  WHEN coalesce(v_count,0)=0 THEN
                    'no matches'||CASE WHEN NOT v_folded
                       THEN ' (curated layer only — pass include_folded=true to also search muted/compressed)'
                       ELSE '' END
                  ELSE 'expand a [ctx:handle] from your OWN session with expand_message; folded=true rows are muted/compressed (context_expand to restore). This is what you SAID — verify external claims at the source.'
                END
    );
END;
$fn$;

-- ── context_session_private — the manual wall lever ──────────────────
CREATE OR REPLACE FUNCTION stewards.context_session_private_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id';
        v_on   bool := coalesce((p_args->>'on')::bool, true);
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    UPDATE stewards.sessions SET private = v_on WHERE id = v_sess;
    IF NOT FOUND THEN
        INSERT INTO stewards.sessions (id, kind, created_at, last_active_at, private)
        VALUES (v_sess, 'agent', now(), now(), v_on)
        ON CONFLICT (id) DO UPDATE SET private = EXCLUDED.private;
    END IF;
    RETURN jsonb_build_object('ok', true, 'session', v_sess, 'private', v_on,
        'note', CASE WHEN v_on
            THEN 'walled — only this session can context_search its own messages; even a parent cannot'
            ELSE 'wall lifted — this session is searchable again by a parent (the watch)' END);
END;
$fn$;

-- ── register the tools (context_* names => compose_tools 26 surfaces them
--    on context-enabled agents automatically; no re-author needed) ──────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'context_search',
  'Search your OWN durable conversation history by text/regex — the Ctrl-F your context window can''t do (the window is lossy; this reads the permanent record). Use it to recall what you decided or found earlier, to pull your own prior finding into a document, or (with include_folded) to recover something you muted and now want back. Returns snippets + [ctx:handle]s; expand one from your own session with expand_message. It tells you what you SAID, not that it was true — still verify external claims at the source.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"pattern":{"type":"string","description":"text or POSIX regex to find (case-insensitive)"},'
    '"scope":{"type":"string","enum":["session","descendants"],"description":"session = this session only (default); descendants = this session + the non-private sessions you spawned (the watch)"},'
    '"include_folded":{"type":"boolean","description":"also search muted/compressed (folded) messages — use to FIND something you folded away to re-open it (default false = curated layer only)"},'
    '"limit":{"type":"integer","description":"max results (default 20, max 100)"}'
  '},"required":["pattern"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"context_search_tool"}'::jsonb, true ),
( 'context_session_private',
  'Wall THIS session private: its messages become searchable only by itself — invisible to context_search from any other agent, including a parent that spawned you. Use for sensitive work (handling secrets, or a run on a local non-cloud model) so its context can''t leak to other sessions. on=false lifts the wall.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"on":{"type":"boolean","description":"true (default) = wall this session; false = lift the wall"}'
  '}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"context_session_private_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET
    description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- =====================================================================
-- End of 27-context-search.sql
-- =====================================================================
