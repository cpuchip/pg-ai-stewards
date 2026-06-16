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
