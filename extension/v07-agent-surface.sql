-- ===== [was 24-skills.sql] =====
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
-- ===== [was 25-corpus.sql] =====
-- =====================================================================
-- 25-corpus.sql — intent→project mapping so every loop compounds a pool
-- =====================================================================
-- The reflect-steward compounds: its verified findings publish to the
-- searchable docs pool, deduped + surveyed + read back scoped to a project.
-- The digest loops (book-study, video-study, general-research) reach
-- maturity=verified but their work_items are NOT project-tagged — work_item_create
-- only defaults project_association = intent slug when a project with THAT slug
-- exists, and the digest intents (book-study, video-study, general-research) don't
-- name a project (the projects are `books`, `ai`). So they never pooled (08's
-- pool-publish is now decoupled from file-materialize but gates on
-- project_association).
--
-- This file adds the generic machinery that lets an operator map an intent to a
-- project: a mapping table + an ADDITIVE BEFORE-INSERT trigger that fills
-- project_association when NULL. Additive = no core function re-author (clobber-
-- check-safe). The map is EMPTY in core (a virgin install is a no-op); the
-- operator overlay seeds the rows (book-study→books, video-study→ai, …) and the
-- project_neighborhood cross-pollination.
--
-- Generic core: machinery + an empty map. requires create_skills (24) — installs
-- at the tail (no function re-authors; just a new table + trigger).
-- =====================================================================

-- ── the map: intent slug → the project its verified work should be tagged to ──
CREATE TABLE IF NOT EXISTS stewards.intent_project_map (
    intent_slug          text PRIMARY KEY,
    project_association   text NOT NULL,     -- a stewards.projects(slug); checked at fill time
    created_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.intent_project_map IS
'Operator map: a work_item under intent <intent_slug> with no project gets tagged to <project_association> (if that project exists). Lets the digest loops (book-study→books, video-study→ai, general-research→ai) feed a compounding pool the same way the reflect-steward does. Empty in core; seeded by the operator overlay.';

-- ── the additive trigger: fill project_association from the map when NULL ─────
-- BEFORE INSERT, only when project_association is NULL and the mapped project
-- actually exists (work_items.project_association FKs stewards.projects(slug) with
-- ON DELETE RESTRICT — setting a non-existent slug would abort the insert, so we
-- guard exactly as compose's tagging does). No-op when the map is empty.
CREATE OR REPLACE FUNCTION stewards.fill_project_association()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_intent_slug text;
    v_project     text;
BEGIN
    IF NEW.project_association IS NOT NULL OR NEW.intent_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT slug INTO v_intent_slug FROM stewards.intents WHERE id = NEW.intent_id;
    IF v_intent_slug IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT m.project_association INTO v_project
      FROM stewards.intent_project_map m WHERE m.intent_slug = v_intent_slug;
    IF v_project IS NOT NULL
       AND EXISTS (SELECT 1 FROM stewards.projects WHERE slug = v_project) THEN
        NEW.project_association := v_project;
    END IF;
    RETURN NEW;
END;
$fn$;
COMMENT ON FUNCTION stewards.fill_project_association() IS
'BEFORE-INSERT on work_items: when project_association is NULL, fill it from intent_project_map (if the mapped project exists). Additive — does not re-author work_item_create; only fills a gap, so existing project tags and the work_item_create default both win over it.';

DROP TRIGGER IF EXISTS work_items_fill_project ON stewards.work_items;
CREATE TRIGGER work_items_fill_project
    BEFORE INSERT ON stewards.work_items
    FOR EACH ROW
    EXECUTE FUNCTION stewards.fill_project_association();

-- =====================================================================
-- End of 25-corpus.sql
-- =====================================================================
-- ===== [was 26-productivity.sql] =====
-- =====================================================================
-- 26-productivity.sql — the agent productivity surface: todos & goals, coupled
-- to the working-tag lifecycle so finishing a task auto-folds its context
-- =====================================================================
-- Ratified 2026-06-16 (Michael, council/ask-tool): auto-fold ON by default
-- (reversible/togglable), SINGLE active todo (auto-stamp; todo_focus to switch),
-- todos kept SEPARATE from work_items in P0 (promote later), granted to all
-- context-enabled agents.
--
-- The realization: a todo IS a working tag with a lifecycle. The hard machinery
-- already exists (15b): context_set_tag makes a tag active so new messages
-- auto-stamp (sessions.working_tag); context_mute_tag folds a whole tagged set;
-- context_expand_tag restores it. This file is the thin semantic layer —
-- todo_add → set the tag active; todo_done → mute the tag (auto-fold). That gives
-- the now-enabled context engine a REASON to fire (the #136 usage-driver).
--
-- requires create_corpus (25) — installs at the tail; re-authors compose_tools
-- (later-file-wins) to surface todo_/goal_ levers on context-enabled agents, and
-- compose_system_prompt (09) calls render_agenda (late-bound). Generic core.
-- =====================================================================

-- ── config: auto-fold on done (Michael: on, togglable) ──────────────────────
SELECT stewards.config_set('todo_autofold_on_done', 'true'::jsonb,
    'When true, todo_done folds (context_mute_tag) the finished todo''s tagged messages to an engram — "finish the work, reclaim its context." Reversible via todo_reopen. false = todo_done only marks done; the agent folds manually.');

-- ── the store: a session todo list + one session goal ───────────────────────
CREATE TABLE IF NOT EXISTS stewards.session_todos (
    session_id text NOT NULL,
    slug       text NOT NULL,
    title      text NOT NULL,
    tag        text NOT NULL,                 -- the working tag ('todo:'||slug)
    status     text NOT NULL DEFAULT 'open' CHECK (status IN ('open','done')),
    is_active  bool NOT NULL DEFAULT false,    -- the one auto-stamping new work
    created_at timestamptz NOT NULL DEFAULT now(),
    closed_at  timestamptz,
    PRIMARY KEY (session_id, slug)
);
COMMENT ON TABLE stewards.session_todos IS
'Per-session, self-curated todo list. Each todo owns a working tag; the active one auto-stamps new messages (sessions.working_tag); todo_done folds the tag. Session-scoped self-management — NOT work_items (no dispatch/spend/cross-session).';

CREATE TABLE IF NOT EXISTS stewards.session_goals (
    session_id text PRIMARY KEY,
    goal       text NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- ── slug helper: title → unique kebab slug within the session ────────────────
CREATE OR REPLACE FUNCTION stewards.todo_slugify(p_session_id text, p_title text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE v_base text; v_slug text; v_n int := 1;
BEGIN
    v_base := btrim(regexp_replace(lower(coalesce(p_title,'')), '[^a-z0-9]+', '-', 'g'), '-');
    v_base := left(NULLIF(v_base,''), 48);
    IF v_base IS NULL THEN v_base := 'todo'; END IF;
    v_slug := v_base;
    WHILE EXISTS (SELECT 1 FROM stewards.session_todos WHERE session_id=p_session_id AND slug=v_slug) LOOP
        v_n := v_n + 1; v_slug := v_base || '-' || v_n;
    END LOOP;
    RETURN v_slug;
END;
$fn$;

-- =====================================================================
-- The levers (sql_fn tools; _session_id-injected). Each wraps the existing
-- working-tag tools so the fold/auto-stamp machinery is reused, not rebuilt.
-- =====================================================================

-- todo_add — open a todo, make its tag active (new work auto-stamps it).
CREATE OR REPLACE FUNCTION stewards.todo_add_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_title text := btrim(coalesce(p_args->>'title',''));
        v_slug text; v_tag text;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_title = '' THEN RETURN jsonb_build_object('error','title required'); END IF;
    v_slug := stewards.todo_slugify(v_sess, v_title);
    v_tag  := 'todo:' || v_slug;
    UPDATE stewards.session_todos SET is_active = false WHERE session_id = v_sess AND is_active;  -- single active
    INSERT INTO stewards.session_todos (session_id, slug, title, tag, status, is_active)
    VALUES (v_sess, v_slug, v_title, v_tag, 'open', true);
    -- make it the active working tag so subsequent messages auto-stamp (best-effort:
    -- if the session row doesn't exist yet, the todo still tracks).
    BEGIN PERFORM stewards.context_set_tag_tool(jsonb_build_object('_session_id', v_sess, 'tag', v_tag));
    EXCEPTION WHEN OTHERS THEN NULL; END;
    RETURN jsonb_build_object('ok', true, 'slug', v_slug, 'tag', v_tag,
        'note', 'active — your work is tagged "'||v_tag||'"; todo_done folds it when finished');
END;
$fn$;

-- todo_done — mark done + auto-fold the tagged context (config-gated).
CREATE OR REPLACE FUNCTION stewards.todo_done_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_slug text := btrim(coalesce(p_args->>'slug',''));
        v_tag text; v_was_active bool; v_fold bool;
        v_autofold bool := coalesce(NULLIF(stewards.config_get_text('todo_autofold_on_done','true'),''),'true') = 'true';
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    SELECT tag, is_active INTO v_tag, v_was_active FROM stewards.session_todos
     WHERE session_id = v_sess AND slug = v_slug;
    IF v_tag IS NULL THEN RETURN jsonb_build_object('error','no open todo "'||v_slug||'"'); END IF;
    UPDATE stewards.session_todos SET status='done', is_active=false, closed_at=now()
     WHERE session_id=v_sess AND slug=v_slug;
    v_fold := false;
    IF v_autofold THEN
        BEGIN PERFORM stewards.context_mute_tag_tool(jsonb_build_object('_session_id', v_sess, 'tag', v_tag)); v_fold := true;
        EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
    IF v_was_active THEN
        BEGIN PERFORM stewards.context_clear_tag_tool(jsonb_build_object('_session_id', v_sess)); EXCEPTION WHEN OTHERS THEN NULL; END;
    END IF;
    RETURN jsonb_build_object('ok', true, 'slug', v_slug, 'folded', v_fold);
END;
$fn$;

-- todo_reopen — reopen + restore its folded messages, make it active again.
CREATE OR REPLACE FUNCTION stewards.todo_reopen_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_slug text := btrim(coalesce(p_args->>'slug','')); v_tag text;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    SELECT tag INTO v_tag FROM stewards.session_todos WHERE session_id=v_sess AND slug=v_slug;
    IF v_tag IS NULL THEN RETURN jsonb_build_object('error','no todo "'||v_slug||'"'); END IF;
    UPDATE stewards.session_todos SET is_active=false WHERE session_id=v_sess AND is_active;
    UPDATE stewards.session_todos SET status='open', is_active=true, closed_at=NULL
     WHERE session_id=v_sess AND slug=v_slug;
    BEGIN PERFORM stewards.context_expand_tag_tool(jsonb_build_object('_session_id', v_sess, 'tag', v_tag)); EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN PERFORM stewards.context_set_tag_tool(jsonb_build_object('_session_id', v_sess, 'tag', v_tag)); EXCEPTION WHEN OTHERS THEN NULL; END;
    RETURN jsonb_build_object('ok', true, 'slug', v_slug, 'reopened', true);
END;
$fn$;

-- todo_focus — switch which open todo is active (auto-stamps new work).
CREATE OR REPLACE FUNCTION stewards.todo_focus_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_slug text := btrim(coalesce(p_args->>'slug','')); v_tag text;
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    SELECT tag INTO v_tag FROM stewards.session_todos WHERE session_id=v_sess AND slug=v_slug AND status='open';
    IF v_tag IS NULL THEN RETURN jsonb_build_object('error','no open todo "'||v_slug||'"'); END IF;
    UPDATE stewards.session_todos SET is_active=(slug=v_slug) WHERE session_id=v_sess;
    BEGIN PERFORM stewards.context_set_tag_tool(jsonb_build_object('_session_id', v_sess, 'tag', v_tag)); EXCEPTION WHEN OTHERS THEN NULL; END;
    RETURN jsonb_build_object('ok', true, 'active', v_slug);
END;
$fn$;

-- todo_list — the agenda (open todos + done count + the goal).
CREATE OR REPLACE FUNCTION stewards.todo_list_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_sess text := p_args->>'_session_id';
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    RETURN jsonb_build_object(
        'goal', (SELECT goal FROM stewards.session_goals WHERE session_id=v_sess),
        'open', COALESCE((SELECT jsonb_agg(jsonb_build_object('slug',slug,'title',title,'active',is_active) ORDER BY created_at)
                            FROM stewards.session_todos WHERE session_id=v_sess AND status='open'), '[]'::jsonb),
        'done_count', (SELECT count(*) FROM stewards.session_todos WHERE session_id=v_sess AND status='done')
    );
END;
$fn$;

-- goal_set — the session's north-star (anti-drift on long runs).
CREATE OR REPLACE FUNCTION stewards.goal_set_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_sess text := p_args->>'_session_id'; v_goal text := btrim(coalesce(p_args->>'goal',''));
BEGIN
    IF v_sess IS NULL OR v_sess = '' THEN RETURN jsonb_build_object('error','no session context'); END IF;
    IF v_goal = '' THEN RETURN jsonb_build_object('error','goal required'); END IF;
    INSERT INTO stewards.session_goals (session_id, goal) VALUES (v_sess, v_goal)
    ON CONFLICT (session_id) DO UPDATE SET goal=EXCLUDED.goal, updated_at=now();
    RETURN jsonb_build_object('ok', true, 'goal', v_goal);
END;
$fn$;

-- =====================================================================
-- render_agenda — the AGENDA block compose_system_prompt appends (only when
-- non-empty, so zero cost otherwise). The "what am I doing" anchor for long runs.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.render_agenda(p_session_id text)
RETURNS text LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_goal text; v_open text; v_done int; v_out text := '';
BEGIN
    SELECT goal INTO v_goal FROM stewards.session_goals WHERE session_id = p_session_id;
    SELECT string_agg('  ' || CASE WHEN is_active THEN '► ' ELSE '· ' END || slug || ' — ' || title, E'\n' ORDER BY created_at)
      INTO v_open FROM stewards.session_todos WHERE session_id = p_session_id AND status='open';
    SELECT count(*) INTO v_done FROM stewards.session_todos WHERE session_id = p_session_id AND status='done';
    IF v_goal IS NULL AND v_open IS NULL THEN RETURN NULL; END IF;
    v_out := E'\n\n=== Agenda ===';
    IF v_goal IS NOT NULL THEN v_out := v_out || E'\nGoal: ' || v_goal; END IF;
    IF v_open IS NOT NULL THEN
        v_out := v_out || E'\nOpen todos (► = active, auto-tagging your work):\n' || v_open;
    END IF;
    IF v_done > 0 THEN v_out := v_out || E'\n(' || v_done || ' done — folded)'; END IF;
    v_out := v_out || E'\ntodo_add to start one; todo_done folds it when finished; todo_focus switches the active one.';
    RETURN v_out;
END;
$fn$;

-- ── tool_defs (gated in compose_tools below on context_tools_enabled) ────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES
('goal_set',
 'Set this session''s goal — your north star. Keeps a long run from drifting; it shows in your Agenda. Re-set it if the goal changes.',
 '{"type":"object","required":["goal"],"additionalProperties":false,"properties":{"goal":{"type":"string"}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','goal_set_tool','schema','stewards'), true),
('todo_add',
 'Open a todo for the task you''re about to work. It becomes the ACTIVE todo and your work from here is auto-tagged to it, so todo_done can fold the whole task''s context in one move. Use one todo per discrete task.',
 '{"type":"object","required":["title"],"additionalProperties":false,"properties":{"title":{"type":"string"}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','todo_add_tool','schema','stewards'), true),
('todo_done',
 'Mark a todo finished. By default this AUTO-FOLDS the messages tagged to it (collapses the task''s context to a one-line engram — reclaiming the space). Recoverable with todo_reopen.',
 '{"type":"object","required":["slug"],"additionalProperties":false,"properties":{"slug":{"type":"string"}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','todo_done_tool','schema','stewards'), true),
('todo_reopen',
 'Reopen a finished todo and restore its folded messages to full verbatim. Makes it the active todo again.',
 '{"type":"object","required":["slug"],"additionalProperties":false,"properties":{"slug":{"type":"string"}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','todo_reopen_tool','schema','stewards'), true),
('todo_focus',
 'Switch which open todo is active (the one auto-tagging your new work). Use when juggling more than one.',
 '{"type":"object","required":["slug"],"additionalProperties":false,"properties":{"slug":{"type":"string"}}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','todo_focus_tool','schema','stewards'), true),
('todo_list',
 'List your open todos (which is active), the done count, and the session goal — your current agenda.',
 '{"type":"object","additionalProperties":false,"properties":{}}'::jsonb,
 jsonb_build_object('kind','sql_fn','name','todo_list_tool','schema','stewards'), true)
ON CONFLICT (name) DO UPDATE
  SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
      execute_target=EXCLUDED.execute_target, active=EXCLUDED.active;

-- =====================================================================
-- compose_tools — re-authored (later-file-wins) to surface todo_/goal_ levers on
-- context-enabled agents (gated on context_tools_on, like the context levers).
-- Body is 24's verbatim plus the todo/goal arm.
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
            ELSE true
          END
$function$;
COMMENT ON FUNCTION stewards.compose_tools(text) IS
'Active tool_defs not denied for the family. context_*/remember/forget + todo_*/goal_* gated on context_tools_enabled; propose_prompt_change additionally on allow_self_base_prompt; skill_* on the skill perm + a skill surface (24).';

-- =====================================================================
-- End of 26-productivity.sql
-- =====================================================================
-- ===== [was 27-context-search.sql] =====
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
-- ===== [was 28-guard-autoresume.sql] =====
-- =====================================================================
-- 28-guard-autoresume.sql — the narrow auto-resume: the guard releases its
-- own brake once a self-clearing breach has demonstrably passed.
-- =====================================================================
-- The watchman guard (23) brakes on a runaway but waits for a human to lift it
-- (D&C 121 — account for emergency force; a human restores). That's right for the
-- breaches that need judgment, but two breach types are SELF-CLEARING: a windowed
-- SPEND cap (the window rolls off) and IN_FLIGHT (work drains). For those, making
-- a human babysit the resume is friction with no safety gain — the danger passes
-- on its own.
--
-- Ratified 2026-06-17 (Michael, "narrow resume"). This adds the release half of
-- the loop, NARROWLY:
--   * only a GUARD-initiated pause auto-resumes — a human reflect_pause stays
--     manual (if you stopped it, only you restart it);
--   * only SELF-CLEARING breaches (spend / in_flight) — a consecutive-failures or
--     proposal-backlog pause stays for a human (it does not heal with time);
--   * only when NO breach is currently active AND the cleared metric is back under
--     reflect_guard_autoresume_pct (default 75%) of its cap — a deadband/hysteresis
--     so it can't flap pause->resume->pause;
--   * every auto-resume is LOGGED to reflect_guard_log (action='auto_resumed') —
--     the watch accounts for RELEASING the brake, not just applying it.
--
-- The pause SOURCE is the load-bearing signal: reflect_pause records 'manual';
-- the guard overrides to 'guard:<breach>' immediately after. Auto-resume lifts
-- only 'guard:<spend|in_flight>' pauses.
--
-- Generic core. requires create_context_search (27). Re-authors (later-file-wins)
-- reflect_pause / reflect_watchman_tick / watchman_scheduler_fire / reflect_status
-- — bodies carried verbatim from 22/23 plus the source marker + the auto-resume call.
-- =====================================================================

-- ── config: the auto-resume switch + the deadband ───────────────────────────
SELECT stewards.config_set('reflect_guard_autoresume_enabled', 'true'::jsonb,
    'When true, the watchman heartbeat auto-RESUMES a guard pause once a self-clearing breach (spend / in_flight) has passed. Narrow: never lifts a human reflect_pause, and never lifts a consecutive-failures or proposal-backlog pause (those stay for a human). false = the guard only ever pauses; a human always resumes (the 23 behavior).');
SELECT stewards.config_set('reflect_guard_autoresume_pct', '75'::jsonb,
    'Hysteresis deadband: auto-resume only once the breached metric is back BELOW this percent of its cap (default 75). The guard trips at 100%; this resumes at <=75% so it cannot flap right at the threshold.');
-- the pause-source marker (default manual; set by reflect_pause / the guard tick).
SELECT stewards.config_set('reflect_pause_source', '"manual"'::jsonb,
    'Who set the current autonomy pause: ''manual'' (a human/agent reflect_pause) or ''guard:<breach>'' (the watchman guard). Read by the narrow auto-resume, which lifts only guard spend/in_flight pauses. ''auto-resumed'' after a self-heal.');

-- =====================================================================
-- reflect_pause — re-authored to record the pause SOURCE as 'manual'. The guard
-- tick overrides to 'guard:<breach>' right after it calls this. Body otherwise
-- verbatim from 22.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_pause(p_reason text DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    PERFORM stewards.config_set('autonomy_paused', 'true'::jsonb, NULL);
    PERFORM stewards.config_set('reflect_pause_source', to_jsonb('manual'::text), NULL);
    RETURN 'PAUSED: all scheduled pipelines + the approved-proposal drain are halted'
        || COALESCE(' (' || p_reason || ')', '')
        || '. In-flight work finishes on its own. reflect_resume() to lift.';
END $$;

-- =====================================================================
-- reflect_watchman_tick — re-authored (body verbatim from 23) + it now tags the
-- pause SOURCE 'guard:<breach>' so the narrow auto-resume can recognise its own
-- pauses (reflect_pause set it to 'manual'; this overrides).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_watchman_tick()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_sig    jsonb;
    v_breach text;
BEGIN
    IF stewards.config_get_text('reflect_guard_enabled','true') <> 'true' THEN
        RETURN NULL;
    END IF;
    IF stewards.config_get_text('autonomy_paused','false') = 'true' THEN
        RETURN NULL;
    END IF;

    v_sig    := stewards.reflect_guard_signals();
    v_breach := v_sig->>'breach';
    IF v_breach IS NULL THEN
        RETURN NULL;   -- nominal
    END IF;

    -- Breach: apply emergency force (global pause) and account for it.
    PERFORM stewards.reflect_pause('watchman guard: ' || v_breach);
    PERFORM stewards.config_set('reflect_pause_source', to_jsonb('guard:'||v_breach), NULL);
    INSERT INTO stewards.reflect_guard_log (breach, signals)
    VALUES (v_breach, v_sig);
    RAISE WARNING 'reflect_watchman_tick: AUTO-PAUSED — %', v_breach;
    RETURN v_breach;
END $$;

-- =====================================================================
-- reflect_guard_autoresume_tick — the release half. Lifts ONLY a guard pause
-- whose self-clearing breach (spend / in_flight) has passed the deadband.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_guard_autoresume_tick()
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
    v_pct    int;
    v_source text;
    v_sig    jsonb;
    v_kind   text;
    v_cur    numeric;
    v_max    numeric;
    v_detail text;
BEGIN
    IF stewards.config_get_text('reflect_guard_autoresume_enabled','true') <> 'true' THEN RETURN NULL; END IF;
    IF stewards.config_get_text('autonomy_paused','false') <> 'true' THEN RETURN NULL; END IF;

    -- only a GUARD pause is auto-resumable; a human reflect_pause stays manual.
    v_source := stewards.config_get_text('reflect_pause_source','manual');
    IF v_source NOT LIKE 'guard:%' THEN RETURN NULL; END IF;

    -- only SELF-CLEARING breaches (spend / in_flight). Failure-streak / proposal
    -- backlog do not heal with time -> stay for a human.
    IF    v_source LIKE 'guard:autonomous spend%' THEN v_kind := 'spend';
    ELSIF v_source LIKE 'guard:in_flight%'        THEN v_kind := 'in_flight';
    ELSE  RETURN NULL; END IF;

    -- no breach may be active right now (don't resume into a different runaway).
    v_sig := stewards.reflect_guard_signals();
    IF (v_sig->>'would_trip')::boolean THEN RETURN NULL; END IF;

    v_pct := COALESCE(NULLIF(stewards.config_get_text('reflect_guard_autoresume_pct','75'),'')::int, 75);

    IF v_kind = 'spend' THEN
        v_cur := (v_sig->'spend_window'->>'usd')::numeric;
        v_max := (v_sig->'spend_window'->>'cap_usd')::numeric;
        v_detail := format('spend $%s back under %s%% of $%s', v_cur, v_pct, v_max);
    ELSE
        v_cur := (v_sig->'in_flight'->>'value')::numeric;
        v_max := (v_sig->'in_flight'->>'max')::numeric;
        v_detail := format('in_flight %s back under %s%% of %s', v_cur, v_pct, v_max);
    END IF;

    -- deadband: only once the metric is below pct% of its cap.
    IF v_max IS NULL OR v_max = 0 OR v_cur >= v_max * v_pct / 100.0 THEN
        RETURN NULL;
    END IF;

    -- clear: lift the pause + account for releasing the brake (same ledger).
    PERFORM stewards.reflect_resume();
    PERFORM stewards.config_set('reflect_pause_source', to_jsonb('auto-resumed'::text), NULL);
    INSERT INTO stewards.reflect_guard_log (breach, signals, action)
    VALUES ('auto-resume: '||v_detail||' (was '||v_source||')', v_sig, 'auto_resumed');
    RAISE WARNING 'reflect_guard_autoresume_tick: AUTO-RESUMED — %', v_detail;
    RETURN v_detail;
END $$;
COMMENT ON FUNCTION stewards.reflect_guard_autoresume_tick() IS
'reflect-watchman release half: auto-resume a GUARD pause (reflect_pause_source=guard:*) whose SELF-CLEARING breach (spend/in_flight) has passed — no active breach + the metric back under reflect_guard_autoresume_pct%% of cap (hysteresis). Never lifts a human pause or a failure/proposal pause. Logs action=auto_resumed. Called each tick from watchman_scheduler_fire.';

-- =====================================================================
-- watchman_scheduler_fire — re-authored (body verbatim from 23) + the auto-resume
-- tick right after the guard tick, BEFORE schedules fire (so a resumed run fires
-- this same heartbeat). Wrapped so it can never break the heartbeat.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.watchman_scheduler_fire()
RETURNS text
LANGUAGE plpgsql AS $func$
DECLARE
    v_reason          text;
    v_cfg             stewards.watchman_config%ROWTYPE;
    v_pass_id         text;
    v_pipelines_fired int;
    v_drained         int;
    v_guard_breach    text;
    v_autoresume      text;
BEGIN
    -- 23: self-presiding guard FIRST — auto-pause on runaway before any new work.
    BEGIN
        v_guard_breach := stewards.reflect_watchman_tick();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_watchman_tick raised: %', SQLERRM;
    END;

    -- 28: narrow auto-resume — lift a guard spend/in_flight pause once it self-clears.
    BEGIN
        v_autoresume := stewards.reflect_guard_autoresume_tick();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_guard_autoresume_tick raised: %', SQLERRM;
    END;

    BEGIN
        v_pipelines_fired := stewards.scheduled_pipelines_fire();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: scheduled_pipelines_fire raised: %', SQLERRM;
    END;

    -- 22: drain the reflect-steward approval queue (capacity-gated, pause-aware).
    BEGIN
        v_drained := stewards.reflect_drain_approved();
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'watchman_scheduler_fire: reflect_drain_approved raised: %', SQLERRM;
    END;

    v_reason := stewards.watchman_should_fire();
    IF v_reason IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT * INTO v_cfg FROM stewards.watchman_config WHERE id = 1;

    v_pass_id := stewards.watchman_pass_start(
        p_limit => v_cfg.schedule_pass_limit, p_provider => NULL, p_model => NULL,
        p_agent_family => NULL, p_actor => 'scheduler', p_trigger => v_reason, p_token_budget => NULL);

    RAISE NOTICE 'watchman scheduler fired (%): pass_id=%', v_reason, v_pass_id;
    RETURN v_pass_id;
END;
$func$;

-- =====================================================================
-- reflect_status — re-authored (body verbatim from 23) + the pause source, the
-- auto-resume config, and last_guard_trip filtered to real trips (auto_resumed
-- rows no longer masquerade as the last trip) + last_guard_resume.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.reflect_status()
RETURNS jsonb LANGUAGE sql STABLE AS $$
    SELECT jsonb_build_object(
        'autonomy_paused', stewards.config_get_text('autonomy_paused','false') = 'true',
        'pause_source',    stewards.config_get_text('reflect_pause_source','manual'),
        'max_concurrent',  stewards.config_get_text('reflect_max_concurrent','2'),
        'in_flight', (SELECT count(*) FROM stewards.reflect_approvals a JOIN stewards.work_items w ON w.id=a.work_item_id
                       WHERE a.dispatched_at IS NOT NULL AND w.status NOT IN ('completed','failed','cancelled')),
        'approved_waiting', (SELECT count(*) FROM stewards.reflect_approvals a JOIN stewards.work_items w ON w.id=a.work_item_id
                              WHERE a.dispatched_at IS NULL AND w.status='pending'),
        'proposals_pending', (SELECT count(*) FROM stewards.work_items w
                               WHERE w.origin='agent_planning' AND w.status='pending'
                                 AND NOT EXISTS (SELECT 1 FROM stewards.reflect_approvals a WHERE a.work_item_id=w.id)),
        'intents_paused', (SELECT COALESCE(jsonb_agg(intent_slug), '[]'::jsonb) FROM stewards.reflect_intent_paused),
        'guard', stewards.reflect_guard_signals(),
        'autoresume', jsonb_build_object(
            'enabled', stewards.config_get_text('reflect_guard_autoresume_enabled','true')='true',
            'pct',     COALESCE(NULLIF(stewards.config_get_text('reflect_guard_autoresume_pct','75'),'')::int, 75)),
        'last_guard_trip', (SELECT jsonb_build_object('at', to_char(tripped_at,'MM-DD HH24:MI'), 'breach', breach)
                              FROM stewards.reflect_guard_log WHERE action='paused_global' ORDER BY tripped_at DESC LIMIT 1),
        'last_guard_resume', (SELECT jsonb_build_object('at', to_char(tripped_at,'MM-DD HH24:MI'), 'breach', breach)
                              FROM stewards.reflect_guard_log WHERE action='auto_resumed' ORDER BY tripped_at DESC LIMIT 1),
        'recent_reflect_runs', (SELECT COALESCE(jsonb_agg(jsonb_build_object('slug',slug,'status',status,'maturity',maturity,'at',to_char(updated_at,'MM-DD HH24:MI')) ORDER BY updated_at DESC), '[]'::jsonb)
                                 FROM (SELECT slug,status,maturity,updated_at FROM stewards.work_items
                                        WHERE pipeline_family='planning' AND actor IN ('scheduler','reflect-steward')
                                        ORDER BY updated_at DESC LIMIT 5) r)
    );
$$;

-- =====================================================================
-- End of 28-guard-autoresume.sql
-- =====================================================================
-- ===== [was 29-intent-private-routing.sql] =====
-- =====================================================================
-- 29-intent-private-routing.sql — a private intent routes its materialized
-- file drops under private/<intent>/ instead of the shared public dirs.
-- =====================================================================
-- The reflect-steward / research / planning pipelines materialize via SHARED
-- per-pipeline templates (planning -> plans/<slug>, research-write ->
-- research/<slug>) into the RW /workspace mount. The folder is the same for
-- every intent — only the slug differs — so a client-sensitive intent's drops
-- land in the public workspace tree alongside everyone else's.
--
-- This makes "private" a first-class property of an INTENT: mark it, and every
-- file it materializes is prefixed `private/<intent_slug>/...`. The operator's
-- /workspace already gitignores /private/, so private intents never leak.
--
-- ONE trigger catches every stamping site (on_maturity_verified's render-UPDATE,
-- 13-research's enqueue UPDATE, 14-fanout's child INSERTs) because they all set
-- work_items.file_destination, and enqueue_work_item_file re-reads that column.
--
-- Generic core (the mechanism). The per-intent flag is operator data: an operator
-- marks which of THEIR intents are private in an overlay. requires
-- create_guard_autoresume (28).
-- =====================================================================

ALTER TABLE stewards.intents ADD COLUMN IF NOT EXISTS file_private boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN stewards.intents.file_private IS
'When true, every file this intent materializes is routed under private/<intent_slug>/ instead of the shared public pipeline dirs (plans/, research/, ...). For client-sensitive intents whose drops must not enter the public workspace tree (which gitignores /private/). Set per-operator in an overlay.';

CREATE OR REPLACE FUNCTION stewards.work_item_private_file_route()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_slug text; v_priv boolean;
BEGIN
    -- nothing to route, or already routed (idempotent), or no intent to check.
    IF NEW.file_destination IS NULL OR NEW.file_destination = '' THEN RETURN NEW; END IF;
    IF NEW.file_destination LIKE 'private/%' THEN RETURN NEW; END IF;
    IF NEW.intent_id IS NULL THEN RETURN NEW; END IF;

    SELECT slug, file_private INTO v_slug, v_priv
      FROM stewards.intents WHERE id = NEW.intent_id;
    IF COALESCE(v_priv, false) THEN
        NEW.file_destination := 'private/' || v_slug || '/' || NEW.file_destination;
    END IF;
    RETURN NEW;
END $$;
COMMENT ON FUNCTION stewards.work_item_private_file_route() IS
'BEFORE INSERT/UPDATE OF file_destination on work_items: if the work_item''s intent is file_private, prefix the destination with private/<intent_slug>/ (idempotent; skips already-private paths). Single choke point — enqueue_work_item_file re-reads file_destination, so the prefix flows to the materialized file.';

DROP TRIGGER IF EXISTS work_items_private_file_route ON stewards.work_items;
CREATE TRIGGER work_items_private_file_route
    BEFORE INSERT OR UPDATE OF file_destination ON stewards.work_items
    FOR EACH ROW EXECUTE FUNCTION stewards.work_item_private_file_route();

-- =====================================================================
-- End of 29-intent-private-routing.sql
-- =====================================================================
-- ===== [was 30-tool-primers.sql] =====
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
