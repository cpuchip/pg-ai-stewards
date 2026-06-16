-- =====================================================================
-- 24-skills.sql — on-demand, agent-managed instruction modules (the 3-tier
-- skills catalog: groups → frontmatter → loaded bodies)
-- =====================================================================
-- A SKILL is a reusable instruction module — "here is how to do X well" — that
-- an agent or persona pulls into its context when a task calls for it and drops
-- when done. The base `stewards.skills` table (family/model_match/description/
-- body) and the flat <available_skills> catalog already exist (schema.rs / 09).
-- This file adds the lever that makes skills a CONTEXT LEVER, the same shape as
-- the context engine (15a/15b's mute/pin/expand): cheap to advertise, paid for
-- only when reached for, and turned on/off by the model itself.
--
-- Three tiers (the engram move — an unneeded group costs one summary line):
--   tier 0  group summary          one line per applicable, closed group
--   tier 1  skill frontmatter      shown for ungrouped skills + opened-group skills
--   tier 2  skill body             the full instructions, only when LOADED
-- Levers: skill_group_open/close (tier 0 <-> 1) and skill_load/unload (tier 1 <-> 2).
-- A loaded-skill BUDGET (config) makes "save context space" real: skill_load
-- REFUSES a load that would push the loaded bodies over budget (no surprise
-- eviction — the model unloads something first). Ratified 2026-06-16 (D1-D6).
--
-- Generic core: machinery + the levers only. NO seeded skills/groups (the first
-- group, `storytelling`, is an operator overlay seeded from the D&D study).
-- requires create_reflect_watchman (23) — installs at the tail; re-authors
-- compose_tools (later-file-wins) once skill_groups exists.
-- =====================================================================

-- ── config: the loaded-skill budget (the "save context space" gate) ──────────
SELECT stewards.config_set('skill_loaded_budget_tokens', '4000'::jsonb,
    'Max estimated tokens of skill BODIES an agent may hold loaded at once (tier 2). skill_load refuses a load that would exceed this — the agent unloads a skill first. The catalog (tiers 0/1) is not counted; only loaded bodies. Tune up for skill-heavy personas, down to force tighter just-in-time loading.');

-- ── skill groups — the tier-0 layer ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS stewards.skill_groups (
    family      text PRIMARY KEY
                CHECK (family ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    name        text NOT NULL,
    summary     text NOT NULL              -- the ONE-line tier-0 default ("the engram")
                CHECK (length(summary) BETWEEN 1 AND 512),
    applies_to  text,                       -- agent_family glob ('fiction', 'persona-%', '*'); NULL = none
    active      bool NOT NULL DEFAULT true,
    created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.skill_groups IS
'Skills belong to groups so the catalog scales: a closed group costs ONE summary line no matter how many skills it holds. applies_to scopes a group to agent families (NULL = none). The model opens a group (skill_group_open) to reveal its skills, loads one (skill_load), and collapses the group back when done.';

-- group membership on the existing skills table (NULL = ungrouped → always tier-1,
-- preserving the prior flat-catalog behavior for skills that have no group).
ALTER TABLE stewards.skills
    ADD COLUMN IF NOT EXISTS group_family text REFERENCES stewards.skill_groups(family);

-- ── session state — what THIS session has opened / loaded (mirrors session_facets) ──
CREATE TABLE IF NOT EXISTS stewards.session_skill_groups (
    session_id  text NOT NULL,
    group_family text NOT NULL,
    opened_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, group_family)
);
CREATE TABLE IF NOT EXISTS stewards.session_skills (
    session_id  text NOT NULL,
    family      text NOT NULL,
    loaded_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, family)
);
COMMENT ON TABLE stewards.session_skills IS
'Per-session loaded skills (tier 2). A row means the skill body is injected into compose_system_prompt for this session. Fully reversible (skill_unload) — a loaded skill is conceptually a pinned context block; unloading is muting it.';

-- group_applies — does a skill group's applies_to (a comma-separated list of
-- agent_family globs) match this agent? Lets a group target more than one family
-- (e.g. 'fiction,gamemaster') while a single value with no comma still works.
CREATE OR REPLACE FUNCTION stewards.group_applies(p_applies_to text, p_agent_family text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_applies_to IS NOT NULL AND EXISTS (
        SELECT 1 FROM regexp_split_to_table(p_applies_to, ',') pat
         WHERE stewards.glob_match(btrim(pat), p_agent_family))
$$;
COMMENT ON FUNCTION stewards.group_applies(text, text) IS
'A skill group''s applies_to is a comma-separated list of agent_family globs; this returns true if ANY matches p_agent_family. One value with no comma behaves like a single glob (backward compatible).';

-- =====================================================================
-- render_skills_block(agent, model, session) — the 3-tier SKILLS section
-- appended by compose_system_prompt (09). Returns NULL when the agent is
-- skill-denied or nothing is visible. Permission + model scoping is enforced
-- HERE (render side), so loading a skill an agent may not see never renders it.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.render_skills_block(
    p_agent_family text, p_model text, p_session_id text
) RETURNS text
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_summaries text;   -- tier 0: closed applicable groups, one summary line each
    v_front     text;   -- tier 1: frontmatter for ungrouped + opened-group skills (not loaded)
    v_loaded    text;   -- tier 2: bodies of loaded skills
    v_catalog   text;
    v_out       text := '';
BEGIN
    IF stewards.tool_permission(p_agent_family, 'skill') = 'deny' THEN
        RETURN NULL;
    END IF;

    -- tier 2 — loaded skill bodies (best variant per family; still-visible only).
    SELECT string_agg(
        '  <skill name="' || s.family || '">' || E'\n' || s.body || E'\n  </skill>',
        E'\n' ORDER BY s.family)
    INTO v_loaded
    FROM stewards.session_skills ss
    JOIN LATERAL (
        SELECT sk.family, sk.body
        FROM stewards.skills sk
        WHERE sk.family = ss.family AND sk.active
          AND stewards.glob_match(sk.model_match, p_model)
        ORDER BY length(sk.model_match) DESC, sk.model_match
        LIMIT 1
    ) s ON true
    WHERE ss.session_id = p_session_id
      AND stewards.skill_permission(p_agent_family, ss.family) <> 'deny';

    -- tier 1 — frontmatter for skills that are ungrouped OR in an opened group,
    -- and not already loaded (those show their body in tier 2).
    SELECT string_agg(
        '  <skill>' || E'\n'
        || '    <name>' || s.family || '</name>' || E'\n'
        || '    <description>' || s.description || '</description>' || E'\n'
        || '  </skill>',
        E'\n' ORDER BY s.family)
    INTO v_front
    FROM (
        SELECT DISTINCT ON (sk.family) sk.family, sk.description, sk.group_family
        FROM stewards.skills sk
        WHERE sk.active
          AND stewards.glob_match(sk.model_match, p_model)
          AND stewards.skill_permission(p_agent_family, sk.family) <> 'deny'
        ORDER BY sk.family, length(sk.model_match) DESC, sk.model_match
    ) s
    WHERE NOT EXISTS (SELECT 1 FROM stewards.session_skills ss
                       WHERE ss.session_id = p_session_id AND ss.family = s.family)
      AND (
            s.group_family IS NULL
         OR EXISTS (SELECT 1 FROM stewards.session_skill_groups sg
                     WHERE sg.session_id = p_session_id AND sg.group_family = s.group_family)
      );

    -- tier 0 — one summary per applicable, active, CLOSED group that has at least
    -- one visible skill (an opened group shows its skills in tier 1 instead).
    SELECT string_agg(
        '  <group name="' || g.family || '">' || g.summary
        || ' — skill_group_open("' || g.family || '") to list its skills</group>',
        E'\n' ORDER BY g.family)
    INTO v_summaries
    FROM stewards.skill_groups g
    WHERE g.active
      AND stewards.group_applies(g.applies_to, p_agent_family)
      AND NOT EXISTS (SELECT 1 FROM stewards.session_skill_groups sg
                       WHERE sg.session_id = p_session_id AND sg.group_family = g.family)
      AND EXISTS (
            SELECT 1 FROM stewards.skills sk
            WHERE sk.group_family = g.family AND sk.active
              AND stewards.glob_match(sk.model_match, p_model)
              AND stewards.skill_permission(p_agent_family, sk.family) <> 'deny'
      );

    v_catalog := concat_ws(E'\n', NULLIF(v_summaries, ''), NULLIF(v_front, ''));

    IF v_catalog IS NOT NULL AND v_catalog <> '' THEN
        v_out := E'\n\n<available_skills>' || E'\n' || v_catalog || E'\n</available_skills>'
              || E'\n(skill_load("<name>") pulls a skill''s full instructions into context; skill_unload("<name>") releases the space. skill_group_open/close reveal/collapse a group.)';
    END IF;

    IF v_loaded IS NOT NULL AND v_loaded <> '' THEN
        v_out := v_out || E'\n\n<loaded_skills>' || E'\n' || v_loaded || E'\n</loaded_skills>';
    END IF;

    RETURN NULLIF(v_out, '');
END;
$fn$;
COMMENT ON FUNCTION stewards.render_skills_block(text, text, text) IS
'The 3-tier SKILLS section for compose_system_prompt: tier-0 group summaries + tier-1 frontmatter (ungrouped or opened-group, unloaded) inside <available_skills>, then tier-2 loaded bodies inside <loaded_skills>. Permission (skill_permission) + model_match are enforced here so a wrongly-loaded skill never renders. NULL when skill-denied or empty.';

-- =====================================================================
-- The levers — sql_fn tools (the bridge injects _session_id into p_args, same
-- as the context levers). All return jsonb {ok|error, ...}.
-- =====================================================================

-- skill_load — mark a skill loaded for this session (tier 1 -> 2), budget-gated.
CREATE OR REPLACE FUNCTION stewards.skill_load_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_sess   text    := p_args->>'_session_id';
    v_family text    := p_args->>'skill';
    v_cpt    numeric := coalesce(NULLIF(stewards.config_get_text('chars_per_token_default',''),'')::numeric, 3.5);
    v_budget int     := coalesce(NULLIF(stewards.config_get_text('skill_loaded_budget_tokens','4000'),'')::int, 4000);
    v_new    int;
    v_cur    int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN
        RETURN jsonb_build_object('error','no session context (internal: _session_id missing)'); END IF;
    IF v_family IS NULL OR v_family = '' THEN
        RETURN jsonb_build_object('error','skill required (the <name> from the available_skills catalog)'); END IF;

    -- exists + active? estimate the loaded cost from the largest active variant body.
    SELECT ceil(max(length(body))::numeric / v_cpt)::int INTO v_new
      FROM stewards.skills WHERE family = v_family AND active;
    IF v_new IS NULL THEN
        RETURN jsonb_build_object('error',
            'no active skill named "'||v_family||'" — check the catalog; if it is grouped, skill_group_open its group first'); END IF;

    IF EXISTS (SELECT 1 FROM stewards.session_skills WHERE session_id=v_sess AND family=v_family) THEN
        RETURN jsonb_build_object('ok',true,'skill',v_family,'note','already loaded'); END IF;

    -- budget: currently-loaded bodies + this one must fit.
    SELECT coalesce(sum(t.tok),0) INTO v_cur FROM (
        SELECT ceil(max(length(s.body))::numeric / v_cpt)::int AS tok
          FROM stewards.session_skills ss
          JOIN stewards.skills s ON s.family = ss.family AND s.active
         WHERE ss.session_id = v_sess
         GROUP BY ss.family) t;
    IF v_cur + v_new > v_budget THEN
        RETURN jsonb_build_object('error',
            format('loading "%s" (~%s tok) would exceed the loaded-skill budget (%s of %s tok in use). Unload a skill first with skill_unload.',
                   v_family, v_new, v_cur, v_budget),
            'budget_used', v_cur, 'budget', v_budget); END IF;

    INSERT INTO stewards.session_skills (session_id, family) VALUES (v_sess, v_family)
      ON CONFLICT DO NOTHING;
    RETURN jsonb_build_object('ok',true,'skill',v_family,'tokens',v_new,
        'budget_used', v_cur+v_new, 'budget', v_budget);
END;
$fn$;

-- skill_unload — drop a loaded skill (tier 2 -> 1).
CREATE OR REPLACE FUNCTION stewards.skill_unload_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_family text := p_args->>'skill'; v_n int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_family IS NULL OR v_family = '' THEN RETURN jsonb_build_object('error','skill required'); END IF;
    DELETE FROM stewards.session_skills WHERE session_id=v_sess AND family=v_family;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok',true,'skill',v_family,'unloaded', v_n > 0);
END;
$fn$;

-- skill_group_open — reveal a group's skills' frontmatter (tier 0 -> 1).
CREATE OR REPLACE FUNCTION stewards.skill_group_open_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_group text := p_args->>'group';
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_group IS NULL OR v_group = '' THEN RETURN jsonb_build_object('error','group required (the <group name> from the catalog)'); END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.skill_groups WHERE family=v_group AND active) THEN
        RETURN jsonb_build_object('error','no active skill group named "'||v_group||'"'); END IF;
    INSERT INTO stewards.session_skill_groups (session_id, group_family) VALUES (v_sess, v_group)
      ON CONFLICT DO NOTHING;
    RETURN jsonb_build_object('ok',true,'group',v_group,
        'note','its skills are now listed; skill_load one to pull in its full instructions');
END;
$fn$;

-- skill_group_close — collapse a group back to its summary (tier 1 -> 0).
CREATE OR REPLACE FUNCTION stewards.skill_group_close_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_group text := p_args->>'group'; v_n int;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_group IS NULL OR v_group = '' THEN RETURN jsonb_build_object('error','group required'); END IF;
    DELETE FROM stewards.session_skill_groups WHERE session_id=v_sess AND group_family=v_group;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok',true,'group',v_group,'closed', v_n > 0);
END;
$fn$;

-- tool_defs — the four levers, gated in compose_tools (below) on the 'skill' perm.
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('skill_group_open',
 'Reveal the skills inside a skill GROUP shown in <available_skills> (so you can see what each does). Cheap — it only lists frontmatter; load a skill to actually use it. Collapse with skill_group_close when done.',
 '{"type":"object","required":["group"],"additionalProperties":false,"properties":{"group":{"type":"string","description":"The group name, e.g. storytelling."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','skill_group_open_tool','schema','stewards'), true),
('skill_group_close',
 'Collapse a skill group back to its one-line summary, reclaiming the catalog space its skills'' frontmatter took.',
 '{"type":"object","required":["group"],"additionalProperties":false,"properties":{"group":{"type":"string","description":"The group name to collapse."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','skill_group_close_tool','schema','stewards'), true),
('skill_load',
 'Pull a skill''s full instructions into your context for the task at hand. Address it by the <name> in <available_skills> (open its group first if it is grouped). Refused if it would exceed the loaded-skill budget — skill_unload something first. Release it with skill_unload when the task is done.',
 '{"type":"object","required":["skill"],"additionalProperties":false,"properties":{"skill":{"type":"string","description":"The skill name, e.g. believable-villains."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','skill_load_tool','schema','stewards'), true),
('skill_unload',
 'Release a previously loaded skill, dropping its instructions from your context to reclaim the space. Address it by name.',
 '{"type":"object","required":["skill"],"additionalProperties":false,"properties":{"skill":{"type":"string","description":"The loaded skill name to release."}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','skill_unload_tool','schema','stewards'), true)
ON CONFLICT (name) DO UPDATE
  SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
      execute_target=EXCLUDED.execute_target, active=EXCLUDED.active;

-- =====================================================================
-- compose_tools — re-authored (later-file-wins) to surface the skill_* levers
-- only when the agent isn't skill-denied AND has a skill surface (an ungrouped
-- skill available, or a group that applies to it). On a virgin core (no skills,
-- no groups) the levers stay hidden — clean. Body is 16's verbatim plus the
-- skill arm; placed here so the skill_groups reference validates at CREATE
-- (LANGUAGE sql checks table refs at create time — the reason this lives in 24).
-- =====================================================================
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
            WHEN t.name LIKE 'skill\_%' ESCAPE '\'
              THEN stewards.tool_permission(p_agent_family, 'skill') <> 'deny'
                   AND (
                        EXISTS (SELECT 1 FROM stewards.skills sk
                                 WHERE sk.active AND sk.group_family IS NULL
                                   AND stewards.skill_permission(p_agent_family, sk.family) <> 'deny')
                     OR EXISTS (SELECT 1 FROM stewards.skill_groups g
                                 WHERE g.active AND stewards.group_applies(g.applies_to, p_agent_family))
                   )
            ELSE true
          END
$function$;
COMMENT ON FUNCTION stewards.compose_tools(text) IS
'Active tool_defs not denied for the family. CT2.3/§7: context_* + remember/forget gated on context_tools_enabled; §7.3 propose_prompt_change additionally on allow_self_base_prompt; 24-skills: skill_* levers gated on the ''skill'' perm + the agent having a skill surface (an ungrouped skill or an applicable group).';

-- =====================================================================
-- End of 24-skills.sql
-- =====================================================================
