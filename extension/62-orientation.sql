-- =====================================================================
-- 62-orientation.sql — autoload: lend orientation to an agent UNCONDITIONALLY
-- =====================================================================
-- The skills shelf (24) is opt-in: a body reaches an agent only if the agent
-- calls skill_load. So orientation stays DORMANT — it arrives only if the agent
-- already knows to ask, and an agent that is skill-denied (world-build, the
-- subagents, the digesters — they never got the skill levers) can never receive
-- it at all. That is backwards for ORIENTATION: the whole point of lending the
-- substrate our battle-tested judgment is that every agent carries it, including
-- the ones that don't manage skills. (Study: study/ai/harness/lending-the-
-- substrate-our-orientation.md — "no agent left orientation-poor.")
--
-- This adds an AUTOLOAD layer: a skill listed in skill_autoload for an agent-
-- family glob is injected into that agent's system prompt as a standing block,
-- regardless of whether the agent can call skill_load. It is the activation
-- layer that makes "fill the shelf" real. The MECHANISM is core; the autoload
-- CONFIG (which family carries which orientation) is operator content — core
-- seeds NONE, exactly like skill content itself (24).
--
-- requires create_world_build_worklist (61). Re-authors render_skills_block
-- (24) later-file-wins to be autoload-aware.
-- =====================================================================

-- ── §1 — the autoload map (operator config; core seeds none) ─────────
CREATE TABLE IF NOT EXISTS stewards.skill_autoload (
    agent_family  text NOT NULL,   -- glob matched against the agent's family ('world-build','subagent-*','*')
    skill_family  text NOT NULL,   -- resolved to its best model_match variant at render (no FK; mirrors session_skills)
    note          text,            -- why this orientation is lent here (operator's own record)
    created_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (agent_family, skill_family)
);
COMMENT ON TABLE stewards.skill_autoload IS
'62: orientation lent UNCONDITIONALLY. A skill listed here is injected into every agent whose family matches agent_family (glob), as a standing <loaded_skills> block, WHETHER OR NOT the agent can manage skills (it bypasses the skill-tool permission, the way a standing instruction would — that is the point: lend orientation to agents that never call skill_load). Per-skill skill_permission deny is still honored. Core seeds none; the autoload config is operator/overlay content like skill bodies.';

-- ── §2 — render_skills_block, autoload-aware (re-authors 24) ──────────
-- Change vs 24: autoloaded bodies are computed FIRST and rendered even when the
-- agent is skill-tool-denied (orientation is unconditional); the management
-- catalog + session-loaded bodies remain gated on the skill tool as before; a
-- family that is autoloaded is excluded from the catalog/session sets so it never
-- double-renders.
CREATE OR REPLACE FUNCTION stewards.render_skills_block(
    p_agent_family text, p_model text, p_session_id text
) RETURNS text
LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_auto      text;   -- autoloaded bodies (unconditional — the orientation lent to this family)
    v_summaries text;   -- tier 0
    v_front     text;   -- tier 1
    v_loaded    text;   -- tier 2 (session-loaded)
    v_loaded_all text;
    v_catalog   text;
    v_denied    bool := (stewards.tool_permission(p_agent_family, 'skill') = 'deny');
    v_out       text := '';
BEGIN
    -- AUTOLOAD (tier 2, unconditional): the orientation this family always carries.
    -- Honors per-skill skill_permission deny, but NOT the skill-tool permission —
    -- a skill-denied agent still receives its lent orientation.
    SELECT string_agg(
        '  <skill name="' || s.family || '" standing="true">' || E'\n' || s.body || E'\n  </skill>',
        E'\n' ORDER BY s.family)
    INTO v_auto
    FROM stewards.skill_autoload al
    JOIN LATERAL (
        SELECT sk.family, sk.body
        FROM stewards.skills sk
        WHERE sk.family = al.skill_family AND sk.active
          AND stewards.glob_match(sk.model_match, p_model)
        ORDER BY length(sk.model_match) DESC, sk.model_match
        LIMIT 1
    ) s ON true
    WHERE stewards.glob_match(al.agent_family, p_agent_family)
      AND stewards.skill_permission(p_agent_family, al.skill_family) <> 'deny';

    IF NOT v_denied THEN
        -- tier 2 — session-loaded bodies (best variant per family; still-visible only),
        -- excluding any family already supplied by autoload (no double render).
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
          AND stewards.skill_permission(p_agent_family, ss.family) <> 'deny'
          AND NOT EXISTS (SELECT 1 FROM stewards.skill_autoload al
                           WHERE al.skill_family = ss.family
                             AND stewards.glob_match(al.agent_family, p_agent_family));

        -- tier 1 — frontmatter for ungrouped/opened-group, not-loaded, not-autoloaded.
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
          AND NOT EXISTS (SELECT 1 FROM stewards.skill_autoload al
                           WHERE al.skill_family = s.family
                             AND stewards.glob_match(al.agent_family, p_agent_family))
          AND (
                s.group_family IS NULL
             OR EXISTS (SELECT 1 FROM stewards.session_skill_groups sg
                         WHERE sg.session_id = p_session_id AND sg.group_family = s.group_family)
          );

        -- tier 0 — one summary per applicable, active, CLOSED group with a visible skill.
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
    END IF;

    -- autoloaded (standing) bodies render for EVERY matching agent; session-loaded
    -- bodies only for skill-capable ones. Both live in <loaded_skills>.
    v_loaded_all := concat_ws(E'\n', NULLIF(v_auto, ''), NULLIF(v_loaded, ''));
    IF v_loaded_all IS NOT NULL AND v_loaded_all <> '' THEN
        v_out := v_out || E'\n\n<loaded_skills>' || E'\n' || v_loaded_all || E'\n</loaded_skills>';
    END IF;

    RETURN NULLIF(v_out, '');
END;
$fn$;
COMMENT ON FUNCTION stewards.render_skills_block(text, text, text) IS
'62 (re-authors 24): the SKILLS section for compose_system_prompt. Autoloaded (standing) orientation bodies render for EVERY agent whose family matches skill_autoload — unconditionally, even when the agent is skill-tool-denied (orientation is lent, not opted into). The management catalog (tiers 0/1) + session-loaded bodies still render only for skill-capable agents, and exclude any autoloaded family so nothing double-renders. NULL when an agent has neither autoloaded orientation nor (if skill-capable) a catalog.';

-- =====================================================================
-- End of 62-orientation.sql
-- =====================================================================
