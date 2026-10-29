-- =====================================================================
-- v76: a family's tool permission default is a setting.
-- =====================================================================
-- tool_permission (schema.rs) answers 'allow' when no agent_tool_perms rule matches a family and a tool, so a
-- family that should see only its own few tools needs a '*' deny row, and a family that forgets one is offered
-- every tool in tool_defs: on stuffleupagus, 148 instead of 41 (its T29 off run). The executor asks the same
-- question per call (compose_tools), so the default reaches both the offer and the run.
--
-- Now the fallback is a setting, at two levels, and unset everywhere it is 'allow' as before:
--   agent_family_defaults.tool_default   one family's default (allow, ask or deny)
--   config tool_permission_default       the instance's default, for a family with no row
-- An explicit rule (agent_tool_perms) still wins over either, longest pattern first, as before.
--
-- Why not default-deny for everyone: core's own families (work-item-chat, loremaster, the pipeline stages)
-- and every instance's families were written against default-allow; most list only the tools they deny or a
-- few they add, so a global flip would strip their tools on upgrade. An instance that wants deny-by-default
-- sets the config in one call (SELECT stewards.config_set('tool_permission_default', '"deny"')) and adds allow
-- rows, or opts one family in with a row here.
-- Oracle: virgin-smoke OK 143. Idempotent.
-- =====================================================================

CREATE TABLE IF NOT EXISTS stewards.agent_family_defaults (
    agent_family text PRIMARY KEY,
    tool_default text NOT NULL CHECK (tool_default IN ('allow', 'ask', 'deny')),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.agent_family_defaults IS
'v76: per-family defaults. tool_default answers tool_permission for a tool no agent_tool_perms rule of the family matches; a family with no row takes config tool_permission_default, else allow.';

CREATE OR REPLACE FUNCTION stewards.tool_permission_default(p_agent text)
RETURNS text LANGUAGE sql STABLE AS $func$
    SELECT coalesce(
        (SELECT tool_default FROM stewards.agent_family_defaults WHERE agent_family = p_agent),
        (SELECT d FROM (SELECT stewards.config_get_text('tool_permission_default') AS d) c
          WHERE d IN ('allow', 'ask', 'deny')),
        'allow')
$func$;

COMMENT ON FUNCTION stewards.tool_permission_default(text) IS
'v76: what tool_permission answers for a family when no rule matches: its agent_family_defaults row, else config tool_permission_default (allow, ask or deny; anything else is passed over), else allow.';

-- schema.rs's body, with the fallback 'allow' replaced by the family's default
CREATE OR REPLACE FUNCTION stewards.tool_permission(p_agent text, p_tool text)
RETURNS text
LANGUAGE sql STABLE AS $func$
    SELECT coalesce(
        (SELECT action FROM stewards.agent_tool_perms
         WHERE agent_family = p_agent
           AND stewards.glob_match(tool_pattern, p_tool)
         ORDER BY length(tool_pattern) DESC LIMIT 1),
        stewards.tool_permission_default(p_agent))
$func$;

COMMENT ON FUNCTION stewards.tool_permission(text, text) IS
'Permission lookup: allow, ask or deny. The longest matching agent_tool_perms pattern wins; with none, the family''s default (v76: agent_family_defaults, else config tool_permission_default, else allow).';
