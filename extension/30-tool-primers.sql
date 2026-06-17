-- =====================================================================
-- 30-tool-primers.sql — teach the model WHEN to reach for its substrate tools.
-- =====================================================================
-- The substrate's self-management tools (context_search, todo_*/goal_*,
-- skill_*, remember/forget) are NATIVE to it — models weren't trained on them,
-- so they don't reach for them unprompted. Telemetry (2026-06-17) confirmed it:
-- the tools were surfaced on 36/39 agents but had ~0 agent-driven use, while the
-- reactive context engine quietly worked. Surfacing a tool ≠ adoption.
--
-- So: a short usage primer per tool GROUP, injected into the system prompt for
-- exactly the agents that have that group. One or two sentences — what it is,
-- when to reach for it, why it beats re-deriving. Gated like the tools
-- themselves, so a tools-off one-shot stage (compactor/critic/gate) sees nothing.
--
-- This is the skill-group render pattern pointed at tool families. Data-driven
-- (tool_primers table) so operators can tune/extend per overlay.
--
-- Generic core. requires create_intent_private_routing (29). compose_system_prompt
-- (09) calls render_tool_primers late-bound, exactly like render_skills_block /
-- render_agenda.
-- =====================================================================

SELECT stewards.config_set('tool_primers_enabled', 'true'::jsonb,
    'When true, compose_system_prompt injects per-tool-group usage primers (render_tool_primers) for the groups an agent has. false = no primers (the pre-30 behavior).');

CREATE TABLE IF NOT EXISTS stewards.tool_primers (
    slug   text PRIMARY KEY,
    gate   text NOT NULL DEFAULT 'always' CHECK (gate IN ('always','context','skills')),
    body   text NOT NULL,
    active boolean NOT NULL DEFAULT true,
    ord    int NOT NULL DEFAULT 100
);
COMMENT ON TABLE stewards.tool_primers IS
'Per-tool-group usage primers injected into the system prompt by render_tool_primers, for the agents that have the group (gate: context=context_tools_on, skills=skill perm, always=every agent). Teaches models to USE substrate-native tools they weren''t trained on. Operator-tunable.';

-- core primers (generic). Operators may add/override per overlay.
INSERT INTO stewards.tool_primers (slug, gate, body, ord) VALUES
('context', 'context',
 'DURABLE CONTEXT & SELF-MANAGEMENT — your context window is lossy and forgets what scrolled off, but the substrate keeps every message as a durable, searchable row. Reach for these instead of re-deriving or guessing:' || E'\n' ||
 '- `context_search` — grep your OWN past turns by text/regex (a decision or finding that fell out of view); `include_folded` to recover something you muted. Returns [ctx:handle]s; `expand_message` reopens one. (It tells you what you SAID — still verify external facts at the source.)' || E'\n' ||
 '- `todo_add` / `todo_done` / `goal_set` — track multi-step work; finishing a todo auto-folds its spent context so the window stays lean.' || E'\n' ||
 '- `remember` / `forget` — durable self-notes that survive the window.', 10),
('skills', 'skills',
 'ON-DEMAND SKILLS — deeper instructions load only when you ask, so you don''t carry what you aren''t using. `skill_group_open` to see a group''s catalog, `skill_load` to pull a skill''s full body into context when a task matches it, `skill_unload` to drop it when done.', 20)
ON CONFLICT (slug) DO UPDATE SET gate=EXCLUDED.gate, body=EXCLUDED.body, ord=EXCLUDED.ord, active=true;

-- render: the primers for the groups THIS agent has (gated like the tools).
CREATE OR REPLACE FUNCTION stewards.render_tool_primers(p_agent_family text)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE v_out text := ''; r record;
BEGIN
    IF stewards.config_get_text('tool_primers_enabled','true') <> 'true' THEN RETURN NULL; END IF;
    FOR r IN SELECT slug, gate, body FROM stewards.tool_primers WHERE active ORDER BY ord, slug
    LOOP
        IF (r.gate = 'always')
           OR (r.gate = 'context' AND stewards.context_tools_on(p_agent_family))
           OR (r.gate = 'skills'  AND stewards.tool_permission(p_agent_family, 'skill') <> 'deny')
        THEN
            v_out := v_out || E'\n' || r.body || E'\n';
        END IF;
    END LOOP;
    IF v_out = '' THEN RETURN NULL; END IF;
    RETURN E'\n## Your substrate tools — when to reach for them\n' || v_out;
END $$;
COMMENT ON FUNCTION stewards.render_tool_primers(text) IS
'Returns the system-prompt block of tool-group usage primers for the groups p_agent_family has (context=context_tools_on, skills=skill perm, always=all). NULL when none apply or tool_primers_enabled=false. Called late-bound by compose_system_prompt (09).';

-- =====================================================================
-- End of 30-tool-primers.sql
-- =====================================================================
