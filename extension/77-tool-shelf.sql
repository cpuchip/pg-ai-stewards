-- =====================================================================
-- 77-tool-shelf.sql — the Tool Shelf: progressive disclosure for TOOLS.
-- =====================================================================
-- Authored 2026-06-28. Spec: .spec/proposals/tool-shelf-progressive-disclosure.md
-- (RATIFIED in council 2026-06-27; the P0.5 probe GREENLIT the self-folding P0
-- on 2026-06-28 — scratchpad/shelf_probe.py drove the LOCAL models against the
-- live corpus with all 157 tools folded, and both qwen3.6 + gemma-4 opened the
-- right tools and made progress).
--
-- WHY THIS EXISTS
-- compose_tools is a DENY-list: every active tool ships on every dispatch unless
-- the agent's family denies it. The generic `research` family carries 157 tools
-- on EVERY turn — a ~105 KB tools array that is mostly tool args_schema. The
-- schemas are the cost: a tool's name + one-line description is cheap, its full
-- JSON-Schema is not, and the model pays for ALL of them every turn whether it
-- calls them or not. A 159-tool gather once wedged the local MoE. 37-tool-groups
-- did the STATIC half (a pipeline stage names the tool-groups it needs); this is
-- the DYNAMIC half (the tool twin of 24's skill shelf): default-fold everything to
-- a name+purpose CATALOG, and let the agent reveal a tool's schema on demand.
--
-- THE SELF-FOLDING SHELF (an LRU cache for tool schemas — the tools put themselves
-- away). When the shelf is ON for an agent:
--   * every tool folds to a one-line catalog entry; only reveal_tool/pin_tool/
--     unpin_tool are always present (the shelf-management levers).
--   * reveal_tool(name) loads a tool's full schema for the session.
--   * COOLDOWN auto-refold: a revealed tool not USED within the last N tool-call
--     rounds (config tool_shelf_cooldown, default 4) auto-folds — its schema drops
--     from the tools array, its catalog line stays. Inferred from the session's
--     recent messages.tool_calls (no separate write path). pin_tool exempts a tool.
--
-- LOAD-BEARING ORACLE: flag-off ⇒ byte-for-byte today's behavior. The shelf only
-- adds GATED branches to three functions (compose_tools, compose_system_prompt,
-- dry_run_chat), each a no-op when tool_shelf_on() is false, plus three NEW
-- tool_defs that are themselves gated off. With the flag off, compose_tools'
-- output is identical (the new levers are suppressed; every other tool hits the
-- same CASE arms verbatim), the catalog renders NULL, and dry_run_chat's tools
-- line falls to the exact 37 expression. Proven by the before/after diff on the
-- dev container and by virgin-smoke OK 68.
--
-- requires create_engram_search_wire (76 = chain head).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Config — the master switch + the cooldown. Default OFF (flag-off = today).
-- DO NOTHING: an upgrade never clobbers an operator's setting.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('tool_shelf_enabled', 'false'::jsonb,
   'Master switch for the Tool Shelf (77). false (default) ⇒ compose_tools/compose_system_prompt/dry_run_chat behave byte-for-byte as before — no folding, no levers. true + an agent with agents.tool_shelf_enabled=true ⇒ that agent''s tools fold to a catalog and it reveals schemas on demand.'),
  ('tool_shelf_cooldown', '4'::jsonb,
   'How many tool-call rounds a revealed tool stays open without being used before it auto-folds (its catalog line stays; pin_tool exempts it). Inferred from the session''s recent messages.tool_calls.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- Per-agent opt-in column — the marker for WHICH agents fold (mirror of
-- agents.context_tools_enabled). The shelf is ON for a dispatch only when
-- the master config is true AND the agent's family opted in. Default false.
-- ---------------------------------------------------------------------
ALTER TABLE stewards.agents
    ADD COLUMN IF NOT EXISTS tool_shelf_enabled boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN stewards.agents.tool_shelf_enabled IS
'77: when true (AND the master config tool_shelf_enabled is true), this family''s tools fold to the catalog and it reveals schemas on demand. Default false = render exactly as pre-77. Opt-in per family, like context_tools_enabled.';

-- tool_shelf_on(family) — the single gate both the system-prompt path and the
-- tools path consult. Master config AND the per-agent opt-in. STABLE/read-only.
CREATE OR REPLACE FUNCTION stewards.tool_shelf_on(p_agent_family text)
RETURNS boolean LANGUAGE sql STABLE AS $fn$
    SELECT COALESCE((stewards.config_get('tool_shelf_enabled', 'false'::jsonb))::text::boolean, false)
       AND COALESCE((SELECT bool_or(tool_shelf_enabled) FROM stewards.agents WHERE family = p_agent_family), false);
$fn$;
COMMENT ON FUNCTION stewards.tool_shelf_on(text) IS
'77: is the Tool Shelf active for this agent_family? master config tool_shelf_enabled AND agents.tool_shelf_enabled. false ⇒ flag-off ⇒ byte-for-byte pre-77.';

-- ---------------------------------------------------------------------
-- State — which tools are REVEALED (open) for a session. pinned exempts a
-- tool from the cooldown auto-refold. created_at doubles as the reveal
-- recency the cooldown reads. Exact sibling of session_skill_groups.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.session_tool_reveals (
    session_id text        NOT NULL,
    tool_name  text        NOT NULL,
    pinned     boolean     NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, tool_name)
);
COMMENT ON TABLE stewards.session_tool_reveals IS
'77: the open set of the Tool Shelf — a row per (session, tool) the agent revealed. pinned=true exempts a tool from the cooldown auto-refold. created_at is the reveal recency the cooldown reads. The tool-side sibling of session_skill_groups.';

-- ---------------------------------------------------------------------
-- effective_revealed_tools(session) — which revealed tools are still OPEN
-- this turn (schema rendered). A revealed tool is open iff: it is pinned,
-- OR no tool-call rounds have happened yet (nothing can have aged out),
-- OR it was revealed within the last N rounds (created_at >= the window
-- start — handles a just-revealed-not-yet-used tool), OR it was CALLED in
-- the last N tool-call rounds. The cooldown (N) is config-driven. Purely
-- inferred from messages.tool_calls — no separate write path.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.effective_revealed_tools(p_session_id text)
RETURNS text[] LANGUAGE sql STABLE AS $fn$
    WITH n AS (
        SELECT GREATEST(COALESCE((stewards.config_get('tool_shelf_cooldown', '4'::jsonb))::text::int, 4), 1) AS v
    ),
    rounds AS (
        SELECT m.id, m.created_at, m.tool_calls
          FROM stewards.messages m
         WHERE m.session_id = p_session_id
           AND m.role = 'assistant'
           AND m.tool_calls IS NOT NULL
           AND jsonb_typeof(m.tool_calls) = 'array'
           AND jsonb_array_length(m.tool_calls) > 0
         ORDER BY m.id DESC
         LIMIT (SELECT v FROM n)
    )
    SELECT COALESCE(array_agg(str.tool_name ORDER BY str.tool_name), ARRAY[]::text[])
      FROM stewards.session_tool_reveals str
     WHERE str.session_id = p_session_id
       AND (
            str.pinned
         OR NOT EXISTS (SELECT 1 FROM rounds)
         OR str.created_at >= (SELECT min(created_at) FROM rounds)
         OR EXISTS (
              SELECT 1
                FROM rounds r
                CROSS JOIN LATERAL jsonb_array_elements(r.tool_calls) tc
               WHERE COALESCE(tc ->> 'name', tc -> 'function' ->> 'name') = str.tool_name
            )
       );
$fn$;
COMMENT ON FUNCTION stewards.effective_revealed_tools(text) IS
'77: the OPEN subset of a session''s revealed tools this turn (cooldown applied). Open iff pinned, or no rounds yet, or revealed within the last N tool-call rounds, or called within them. N = config tool_shelf_cooldown. Inferred from messages.tool_calls.';

-- ---------------------------------------------------------------------
-- The levers (sql_fn tools). Each reads the dispatch _session_id the
-- bgworker injects (cf. skill_group_open_tool). Refuse with a clear error
-- so the model can recover; never raise.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.reveal_tool_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_name text := p_args->>'name';
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_name IS NULL OR v_name = '' THEN RETURN jsonb_build_object('error','name required (the exact tool name from <folded_tools>)'); END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name = v_name AND active) THEN
        RETURN jsonb_build_object('error','no active tool named "'||v_name||'" — check the exact name in <folded_tools>'); END IF;
    -- Re-revealing refreshes the cooldown (created_at = now() ⇒ "I still want this").
    INSERT INTO stewards.session_tool_reveals (session_id, tool_name) VALUES (v_sess, v_name)
      ON CONFLICT (session_id, tool_name) DO UPDATE SET created_at = now();
    RETURN jsonb_build_object('ok', true, 'tool', v_name,
        'note', 'its schema is now loaded — you can call '||v_name||' now. It folds again after '||
                COALESCE((stewards.config_get('tool_shelf_cooldown','4'::jsonb))::text,'4')||
                ' idle tool-call rounds; pin_tool("'||v_name||'") keeps it open.');
END;
$fn$;

CREATE OR REPLACE FUNCTION stewards.pin_tool_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_name text := p_args->>'name';
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_name IS NULL OR v_name = '' THEN RETURN jsonb_build_object('error','name required'); END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.tool_defs WHERE name = v_name AND active) THEN
        RETURN jsonb_build_object('error','no active tool named "'||v_name||'"'); END IF;
    INSERT INTO stewards.session_tool_reveals (session_id, tool_name, pinned) VALUES (v_sess, v_name, true)
      ON CONFLICT (session_id, tool_name) DO UPDATE SET pinned = true;
    RETURN jsonb_build_object('ok', true, 'tool', v_name, 'pinned', true,
        'note', v_name||' stays open (exempt from the cooldown) until unpin_tool("'||v_name||'").');
END;
$fn$;

CREATE OR REPLACE FUNCTION stewards.unpin_tool_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_name text := p_args->>'name'; v_n int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_name IS NULL OR v_name = '' THEN RETURN jsonb_build_object('error','name required'); END IF;
    UPDATE stewards.session_tool_reveals SET pinned = false WHERE session_id = v_sess AND tool_name = v_name;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'tool', v_name, 'pinned', false, 'unpinned', v_n > 0,
        'note', 'it folds again after the cooldown if it goes unused.');
END;
$fn$;

-- tool_defs — the three shelf-management levers. Gated in compose_tools (below)
-- on tool_shelf_on, so a non-shelf dispatch never sees them (flag-off identity).
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('reveal_tool',
 'Load the full schema of a FOLDED tool (one listed in <folded_tools>) so you can call it. Pass the exact tool name. Open the tools the task needs, then use them. They fold again after a few idle rounds — pin_tool one you will reuse.',
 '{"type":"object","required":["name"],"additionalProperties":false,"properties":{"name":{"type":"string","description":"The exact tool name from <folded_tools>, e.g. doc_search."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','reveal_tool_tool','schema','stewards'), true),
('pin_tool',
 'Keep a revealed tool open — exempt it from the auto-fold cooldown — for a tool you will reuse across many rounds. Release it with unpin_tool.',
 '{"type":"object","required":["name"],"additionalProperties":false,"properties":{"name":{"type":"string","description":"The tool name to pin open."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','pin_tool_tool','schema','stewards'), true),
('unpin_tool',
 'Release a pinned tool so it can fold again once it goes unused.',
 '{"type":"object","required":["name"],"additionalProperties":false,"properties":{"name":{"type":"string","description":"The pinned tool name to release."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','unpin_tool_tool','schema','stewards'), true)
ON CONFLICT (name) DO UPDATE
  SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
      execute_target=EXCLUDED.execute_target, active=EXCLUDED.active;

-- ---------------------------------------------------------------------
-- render_folded_tools_block(family, session) — the CATALOG. Mirrors
-- render_skills_block's tier-0 catalog: one line per foldable tool (name +
-- first-line purpose + the reveal hint). SELF-GATES: NULL when the shelf is
-- off, so compose_system_prompt's append is a clean no-op (flag-off identity).
-- Foldable set = the agent's scoped tools MINUS the always-present levers.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.render_folded_tools_block(
    p_agent_family text, p_session_id text
) RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_scope text[];
    v_lines text;
BEGIN
    IF NOT stewards.tool_shelf_on(p_agent_family) THEN
        RETURN NULL;
    END IF;
    v_scope := stewards.session_tool_scope(p_session_id);

    SELECT string_agg(
        '  - ' || (e->'function'->>'name') || ': '
        || left(split_part(coalesce(NULLIF(e->'function'->>'description',''), '(no description)'), E'\n', 1), 160)
        || ' — reveal_tool("' || (e->'function'->>'name') || '") to load it.',
        E'\n' ORDER BY e->'function'->>'name')
      INTO v_lines
      FROM jsonb_array_elements(stewards.compose_tools_scoped(p_agent_family, v_scope)) e
     WHERE (e->'function'->>'name') NOT IN ('reveal_tool','pin_tool','unpin_tool');

    IF v_lines IS NULL OR v_lines = '' THEN
        RETURN NULL;
    END IF;

    RETURN E'\n\n<folded_tools>\n'
        || 'Your tools are FOLDED to keep your context small — only names + purpose are shown. '
        || 'To CALL a tool you must first load its schema with reveal_tool("<name>"). '
        || 'Open the ones the task needs, then use them; do not guess from memory.' || E'\n'
        || v_lines
        || E'\n</folded_tools>';
END;
$fn$;
COMMENT ON FUNCTION stewards.render_folded_tools_block(text, text) IS
'77: the Tool Shelf CATALOG for compose_system_prompt — one name+purpose line per foldable tool (the agent''s scoped set minus the reveal/pin/unpin levers) + the reveal hint. Returns NULL when tool_shelf_on is false (flag-off ⇒ no block ⇒ byte-identical). Mirrors render_skills_block''s tier-0 catalog.';

-- ---------------------------------------------------------------------
-- compose_tools_folded(family, session, scope) — the folded TOOLS ARRAY:
-- the always-present levers (pulled UNSCOPED so a stage scope can never strip
-- the shelf-management tools) + the full schemas of the currently-open
-- revealed tools (from effective_revealed_tools, within the stage scope).
-- Everything else is folded (catalog only). Only called when the shelf is on.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compose_tools_folded(
    p_agent_family text, p_session_id text, p_scope_patterns text[] DEFAULT NULL
) RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    WITH open_names AS (   -- materialize the open set once (STABLE function)
        SELECT unnest(stewards.effective_revealed_tools(p_session_id)) AS name
    ),
    levers AS (   -- always present; UNSCOPED so a pipeline-stage scope can't strip them
        SELECT e
          FROM jsonb_array_elements(stewards.compose_tools(p_agent_family)) e
         WHERE (e->'function'->>'name') IN ('reveal_tool','pin_tool','unpin_tool')
    ),
    revealed AS ( -- the open revealed tools' full schemas, within the stage scope
        SELECT e
          FROM jsonb_array_elements(stewards.compose_tools_scoped(p_agent_family, p_scope_patterns)) e
         WHERE (e->'function'->>'name') IN (SELECT name FROM open_names)
           AND (e->'function'->>'name') NOT IN ('reveal_tool','pin_tool','unpin_tool')
    )
    SELECT COALESCE(jsonb_agg(e ORDER BY e->'function'->>'name'), '[]'::jsonb)
      FROM (SELECT e FROM levers UNION ALL SELECT e FROM revealed) u;
$fn$;
COMMENT ON FUNCTION stewards.compose_tools_folded(text, text, text[]) IS
'77: the FOLDED tools array — the always-present shelf levers (reveal/pin/unpin, pulled unscoped) + the full schemas of the currently-open revealed tools (effective_revealed_tools, within the stage scope). Everything else folds to the catalog. dry_run_chat calls this when tool_shelf_on.';

-- ---------------------------------------------------------------------
-- compose_tools — re-authored (later-file-wins over 26). The ONLY change vs
-- 26 is one CASE arm gating the three shelf levers on tool_shelf_on, so the
-- new tool_defs are SUPPRESSED unless the shelf is on for the family. With the
-- shelf off they are excluded and every other tool hits the same arms verbatim
-- ⇒ compose_tools(family) is byte-identical to 26. Body is otherwise 26's exact.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compose_tools(p_agent_family text)
RETURNS jsonb LANGUAGE sql STABLE AS $function$
    SELECT coalesce(jsonb_agg(
        jsonb_build_object(
            'type', 'function',
            'function', jsonb_build_object(
                'name', t.name,
                'description', t.description,
                'parameters', t.args_schema
            )
        )
        ORDER BY t.name
    ), '[]'::jsonb)
    FROM stewards.tool_defs t
    WHERE t.active
      AND stewards.tool_permission(p_agent_family, t.name) <> 'deny'
      AND CASE
            WHEN t.name = 'propose_prompt_change'
              THEN stewards.context_tools_on(p_agent_family)
                   AND stewards.self_prompt_on(p_agent_family)
            WHEN t.name LIKE 'context\_%' ESCAPE '\' OR t.name IN ('remember','forget')
              THEN stewards.context_tools_on(p_agent_family)
            WHEN t.name LIKE 'todo\_%' ESCAPE '\' OR t.name LIKE 'goal\_%' ESCAPE '\'
              THEN stewards.context_tools_on(p_agent_family)
            WHEN t.name LIKE 'skill\_%' ESCAPE '\'
              THEN stewards.tool_permission(p_agent_family, 'skill') <> 'deny'
                   AND (
                        EXISTS (SELECT 1 FROM stewards.skills sk
                                 WHERE sk.active AND sk.group_family IS NULL
                                   AND stewards.skill_permission(p_agent_family, sk.family) <> 'deny')
                     OR EXISTS (SELECT 1 FROM stewards.skill_groups g
                                 WHERE g.active AND stewards.group_applies(g.applies_to, p_agent_family))
                   )
            WHEN t.name IN ('reveal_tool','pin_tool','unpin_tool')
              THEN stewards.tool_shelf_on(p_agent_family)   -- 77: shelf levers, gated off by default
            ELSE true
          END
$function$;
COMMENT ON FUNCTION stewards.compose_tools(text) IS
'Active tool_defs not denied for the family. context_*/remember/forget + todo_*/goal_* gated on context_tools_enabled; propose_prompt_change additionally on allow_self_base_prompt; skill_* on the skill perm + a skill surface (24); 77: reveal_tool/pin_tool/unpin_tool gated on tool_shelf_on (off by default ⇒ suppressed ⇒ byte-identical to pre-77).';

-- ---------------------------------------------------------------------
-- compose_system_prompt — re-authored (later-file-wins over 74). The ONLY
-- change vs 74 is one gated block appending the Tool Shelf catalog after the
-- tool primers (and before the Watch echo): render_folded_tools_block returns
-- NULL when the shelf is off, so with the flag off the output is byte-identical
-- to 74. Body is otherwise 74's exact (North Star + covenant + intent + agent +
-- instructions + skills + agenda + primers + Watch echo + North Star echo).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.compose_system_prompt(
    p_agent_family text, p_model text, p_session_id text
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_agent          stewards.agents;
    v_prompt         text := '';
    v_north_star     text;
    v_instructions   text;
    v_skills_block   text;
    v_covenant       stewards.covenants;
    v_intent         stewards.intents;
    v_covenant_block text := '';
    v_intent_block   text := '';
    v_human_str      text;
    v_agent_str      text;
    v_values_str     text;
    v_non_goals_str  text;
    v_presiding          jsonb;
    v_presiding_str      text;
    v_presiding_cncl_str text;
    v_echo_keys          text;
BEGIN
    v_agent := stewards.resolve_agent(p_agent_family, p_model);
    IF v_agent.family IS NULL THEN
        RAISE EXCEPTION
            'no agent variant resolved: family=% model=%',
            p_agent_family, p_model;
    END IF;

    -- Step 1: the North Star — the substrate's standing *why*, ahead of all else.
    v_north_star := stewards.render_north_star();

    -- Active covenant block (always-on for global scope).
    SELECT * INTO v_covenant
      FROM stewards.covenants
     WHERE scope = 'global' AND deactivated_at IS NULL
     ORDER BY activated_at DESC
     LIMIT 1;

    IF v_covenant.id IS NOT NULL THEN
        SELECT string_agg('  - ' || (c->>'key') || ': ' || (c->>'description'), E'\n')
          INTO v_human_str
          FROM jsonb_array_elements(v_covenant.human_commits_to) c;

        SELECT string_agg('  - ' || (c->>'key') || ': ' || (c->>'description'), E'\n')
          INTO v_agent_str
          FROM jsonb_array_elements(v_covenant.agent_commits_to) c;

        v_covenant_block :=
            E'=== Active Covenant ===\n' ||
            E'The human commits to:\n' || coalesce(v_human_str, '  (none)') || E'\n\n' ||
            E'The agent (you) commits to:\n' || coalesce(v_agent_str, '  (none)');

        IF v_covenant.council_moment IS NOT NULL AND length(v_covenant.council_moment) > 0 THEN
            v_covenant_block := v_covenant_block || E'\n\nCouncil moment:\n  ' || v_covenant.council_moment;
        END IF;

        -- PR.1: presiding extension — the chain-of-watches delegation terms.
        v_presiding := v_covenant.extensions -> 'presiding';
        IF v_presiding IS NOT NULL THEN
            SELECT string_agg(
                     '  - ' || e.key || ': ' || trim(e.value->>'description') ||
                     CASE WHEN e.value ? 'emergency'
                          THEN E'\n    Emergency: ' || trim(e.value->>'emergency')
                          ELSE '' END,
                     E'\n' ORDER BY e.key)
              INTO v_presiding_str
              FROM jsonb_each(v_presiding->'agent_commits_to') e;

            SELECT string_agg('  - ' || e.key || ': ' || trim(e.value->>'description'),
                              E'\n' ORDER BY e.key)
              INTO v_presiding_cncl_str
              FROM jsonb_each(v_presiding->'council_commits_to') e;

            IF v_presiding_str IS NOT NULL THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nWhen you delegate — subagents, dispatches, persona turns — you preside over that work, and commit to:\n' ||
                    v_presiding_str;
            END IF;
            IF v_presiding_cncl_str IS NOT NULL THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nThe council commits to:\n' || v_presiding_cncl_str;
            END IF;
            IF v_presiding ? 'when_presiding_is_broken' THEN
                v_covenant_block := v_covenant_block ||
                    E'\n\nBreach signature: ' ||
                    trim(v_presiding->'when_presiding_is_broken'->>'description');
            END IF;
        END IF;
    END IF;

    -- Intent block (only when the session resolves to a work_item with an intent).
    SELECT i.* INTO v_intent
      FROM stewards.intents i
      JOIN stewards.work_items wi ON wi.intent_id = i.id
     WHERE p_session_id = ANY(coalesce(wi.session_ids, ARRAY[]::text[]))
     LIMIT 1;

    IF v_intent.id IS NOT NULL THEN
        SELECT string_agg(
                 '  - ' || (v->>'key') ||
                 CASE WHEN v ? 'kind' AND v->>'kind' = 'constraint'
                      THEN ' [constraint, severity=' || coalesce(v->>'severity','?') || ']'
                      ELSE ''
                 END ||
                 ': ' || (v->>'description'),
                 E'\n'
               )
          INTO v_values_str
          FROM jsonb_array_elements(v_intent.values_hierarchy) v;

        v_non_goals_str := array_to_string(v_intent.non_goals, E'\n  - ', '');

        v_intent_block :=
            E'=== Intent ===\n' ||
            E'Slug: ' || v_intent.slug || E'\n' ||
            E'Purpose: ' || v_intent.purpose || E'\n';

        IF v_intent.beneficiary IS NOT NULL THEN
            v_intent_block := v_intent_block || E'Beneficiary: ' || v_intent.beneficiary || E'\n';
        END IF;

        v_intent_block := v_intent_block || E'\nValues (in order of priority):\n' ||
            coalesce(v_values_str, '  (none)');

        IF v_intent.non_goals IS NOT NULL AND array_length(v_intent.non_goals, 1) > 0 THEN
            v_intent_block := v_intent_block || E'\n\nNon-goals:\n  - ' || v_non_goals_str;
        END IF;

        IF v_intent.values_anchor IS NOT NULL THEN
            v_intent_block := v_intent_block || E'\n\nValues anchor: ' || v_intent.values_anchor;
        END IF;
    END IF;

    -- Compose: North Star + covenant + intent first, then === Agent === marker, then agent.
    IF v_north_star IS NOT NULL THEN
        v_prompt := v_north_star || E'\n\n';
    END IF;
    IF length(v_covenant_block) > 0 THEN
        v_prompt := v_prompt || v_covenant_block || E'\n\n';
    END IF;
    IF length(v_intent_block) > 0 THEN
        v_prompt := v_prompt || v_intent_block || E'\n\n';
    END IF;
    IF length(v_prompt) > 0 THEN
        v_prompt := v_prompt || E'=== Agent ===\n';
    END IF;

    v_prompt := v_prompt || v_agent.prompt;

    -- Existing logic: instructions + skills.
    SELECT string_agg(body, E'\n\n' ORDER BY ord, family)
    INTO v_instructions
    FROM (
        SELECT DISTINCT ON (family)
            family, body, ord
        FROM stewards.instructions
        WHERE active
          AND scope IN ('global', 'agent:' || p_agent_family)
          AND stewards.glob_match(model_match, p_model)
        ORDER BY family, length(model_match) DESC, model_match
    ) t;
    IF v_instructions IS NOT NULL THEN
        v_prompt := v_prompt || E'\n\n' || v_instructions;
    END IF;

    -- Skills — the 3-tier catalog (group summaries -> opened-group frontmatter ->
    -- loaded bodies). Built in 24-skills.sql; the call is late-bound (plpgsql), so
    -- the forward reference to a later chain file is safe. Returns NULL when the
    -- agent is skill-denied or nothing is visible.
    v_skills_block := stewards.render_skills_block(p_agent_family, p_model, p_session_id);
    IF v_skills_block IS NOT NULL THEN
        v_prompt := v_prompt || v_skills_block;
    END IF;

    -- Agenda — the session's goal + open todos (26-productivity). Late-bound
    -- forward ref (plpgsql) to a later chain file, like render_skills_block.
    DECLARE v_agenda text;
    BEGIN
        v_agenda := stewards.render_agenda(p_session_id);
        IF v_agenda IS NOT NULL THEN
            v_prompt := v_prompt || v_agenda;
        END IF;
    END;

    -- Tool-usage primers (30-tool-primers) — teach the model WHEN to reach for its
    -- substrate-native tools (it wasn't trained on them). Per tool group, gated like
    -- the tools. Late-bound forward ref (plpgsql), like render_skills_block/_agenda.
    DECLARE v_primers text;
    BEGIN
        v_primers := stewards.render_tool_primers(p_agent_family);
        IF v_primers IS NOT NULL THEN
            v_prompt := v_prompt || v_primers;
        END IF;
    END;

    -- 77: the Tool Shelf catalog — the folded tool names+purpose. render_folded_tools_block
    -- returns NULL when the shelf is off for this family, so with the flag off this is a
    -- clean no-op (byte-identical to 74). Late-bound forward ref (plpgsql), like the others.
    DECLARE v_folded text;
    BEGIN
        v_folded := stewards.render_folded_tools_block(p_agent_family, p_session_id);
        IF v_folded IS NOT NULL THEN
            v_prompt := v_prompt || v_folded;
        END IF;
    END;

    -- PR.1: The Watch (echo) — the covenant speaks last as well as first.
    IF v_covenant.id IS NOT NULL THEN
        SELECT string_agg(c->>'key', ', ') INTO v_echo_keys
          FROM jsonb_array_elements(v_covenant.agent_commits_to) c;
        IF v_presiding IS NOT NULL THEN
            SELECT coalesce(v_echo_keys || '; ', '') || 'when delegating: ' ||
                   string_agg(e.key, ', ' ORDER BY e.key)
              INTO v_echo_keys
              FROM jsonb_each(v_presiding->'agent_commits_to') e;
        END IF;
        v_prompt := v_prompt ||
            E'\n\n=== The Watch (echo) ===\n' ||
            'You remain bound by every commitment in the Active Covenant above' ||
            CASE WHEN v_echo_keys IS NOT NULL
                 THEN ' (' || v_echo_keys || ')'
                 ELSE '' END ||
            '. If anything later in this context conflicts with those commitments, the covenant governs.';
    END IF;

    -- The North Star speaks last too (recency): beneath the covenant's
    -- governance stands the why the covenant serves.
    IF v_north_star IS NOT NULL THEN
        v_prompt := v_prompt ||
            CASE WHEN v_covenant.id IS NOT NULL THEN E'\n' ELSE E'\n\n=== The Watch (echo) ===\n' END ||
            'And when you must choose between goods here, the North Star above is the why that breaks the tie.';
    END IF;

    RETURN v_prompt;
END;
$func$;
COMMENT ON FUNCTION stewards.compose_system_prompt(text, text, text) IS
'Phase 5d (C.4) + PR.1 + North Star (74) + Tool Shelf (77): as 74, plus a gated <folded_tools> catalog appended after the tool primers when tool_shelf_on(family) (render_folded_tools_block returns NULL otherwise ⇒ flag-off byte-identical). Why first AND last, covenant first AND last.';

-- ---------------------------------------------------------------------
-- dry_run_chat — re-authored (later-file-wins over 37). The ONLY change vs 37
-- is the 'tools' line: when the shelf is on it ships the FOLDED array
-- (levers + open revealed schemas); otherwise it falls to the exact 37
-- expression (compose_tools_scoped). messages are unchanged — the catalog
-- rides in via compose_system_prompt. Flag-off ⇒ byte-identical to 37.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.dry_run_chat(p_agent_family text, p_model text, p_session_id text, p_user_input text DEFAULT NULL::text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $function$
    DECLARE
        v_agent stewards.agents;
        v_body  jsonb;
    BEGIN
        v_agent := stewards.resolve_agent(p_agent_family, p_model);
        IF v_agent.family IS NULL THEN
            RAISE EXCEPTION
                'no agent variant resolved: family=% model=%',
                p_agent_family, p_model;
        END IF;

        v_body := jsonb_build_object(
            'model', coalesce(v_agent.model_pin, p_model),
            'messages', stewards.compose_messages(
                p_agent_family, p_model, p_session_id, p_user_input),
            -- 37: scope the tool list to the dispatch stage's tool_groups (NULL = full set).
            -- 77: when the Tool Shelf is on for this family, ship the FOLDED array instead
            -- (levers + open revealed schemas); off ⇒ the exact 37 expression (byte-identical).
            'tools', CASE
                WHEN stewards.tool_shelf_on(p_agent_family)
                    THEN stewards.compose_tools_folded(
                             p_agent_family, p_session_id, stewards.session_tool_scope(p_session_id))
                ELSE stewards.compose_tools_scoped(
                             p_agent_family, stewards.session_tool_scope(p_session_id))
            END
        );
        IF v_agent.temperature IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('temperature', v_agent.temperature);
        END IF;
        IF v_agent.top_p IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('top_p', v_agent.top_p);
        IF v_agent.response_format IS NOT NULL THEN
            v_body := v_body || jsonb_build_object('response_format', v_agent.response_format);
        END IF;
        END IF;

        RETURN v_body || jsonb_build_object(
            '_meta', jsonb_build_object(
                'agent_family', p_agent_family,
                'agent_variant_match', v_agent.model_match,
                'requested_model', p_model,
                'pinned_model', v_agent.model_pin,
                'session_id', p_session_id
            )
        );
    END;
    $function$;

-- =====================================================================
-- End of 77-tool-shelf.sql
-- =====================================================================
