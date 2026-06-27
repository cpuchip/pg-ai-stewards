-- =====================================================================
-- 74-north-star.sql — the substrate's Intent (step 1), on every call.
-- =====================================================================
-- Authored 2026-06-27.
--
-- WHY THIS EXISTS
-- The substrate runs the back half of a creation cycle — covenant,
-- stewardship, specification, watching, atonement — but step 1, the named
-- *why*, was never made explicit on the work itself. Every LLM call carried
-- the covenant (how we work) but not the Intent it serves (what the work is
-- ultimately FOR). This file gives the substrate its North Star: a short,
-- standing *why* prepended to the system prompt of every agent call, ahead of
-- the covenant, with directions that re-root the substrate's EXISTING covenant
-- behaviors under that why — so it becomes the tie-breaker when values conflict.
--
-- LOAD-BEARING, NOT A STICKER
-- A why pasted on every prompt that changes nothing becomes wallpaper the model
-- ignores. The block therefore does two things: it names the why, and it names
-- the behaviors that why governs (welfare over the metric; point to the source;
-- persuade, don't compel; verify before you assert and assume you can be wrong)
-- — the substrate's own covenant clauses, restated as the *why beneath them*.
-- The closing line makes the role explicit: when the commitments below pull in
-- different directions, the North Star breaks the tie.
--
-- GENERIC IN THE CORE, OPERATOR-OWNED IN CONFIG
-- The public core ships a real, generic default why + directions. It hardcodes
-- no scripture and no operator-specific content (same discipline as 09's
-- scripture_anchor -> values_anchor genericization). Each operator names their
-- OWN north star with config_set('north_star.why', ...) — the FORM is universal
-- (every steward must name an Intent), the CONTENT is theirs. The seed uses
-- ON CONFLICT DO NOTHING so a migrate never clobbers an operator's value.
-- An empty/absent why means no block renders (an operator may opt out; the
-- mechanism fails open to silence). Recommended scriptures for operators who
-- share the faith live in docs/north-star.md, never in the core.
--
-- WHERE IT LANDS
-- render_north_star() composes the block from config; compose_system_prompt
-- (re-authored here, later-file-wins over 09) prepends it FIRST and echoes it
-- last (primacy AND recency, like the covenant). One chokepoint => every agent
-- call carries the why. Personas (17) compose their own prompt and are out of
-- scope by design — the North Star governs the substrate's own labor, not a
-- role-played character's voice.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Config — the operator-owned north star. Generic, real defaults.
-- DO NOTHING: upgrades never overwrite an operator's setting.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('north_star.why',
   to_jsonb('Serve the genuine good of the people this work is for — not merely the completion of the task.'::text),
   'The substrate''s guiding *why*, prepended to every agent system prompt (step 1 of the creation cycle). Operators: set your own with config_set(''north_star.why'', to_jsonb(''...''::text)). Empty/absent ⇒ no North Star block renders. See docs/north-star.md for recommended anchors.'),

  ('north_star.directions',
   '["Serve the real welfare of the people you act for, above any metric or quota.",
     "Point to the source of what you report; take no credit that is not yours.",
     "Persuade and invite — never compel.",
     "Read before you assert, and assume you can be wrong."]'::jsonb,
   'The directions the North Star governs — the substrate''s existing covenant behaviors, restated as the *why beneath them* so the why is load-bearing, not a sticker. Operators may override or extend. Empty array ⇒ the why renders alone.'),

  ('north_star.source',
   to_jsonb(''::text),
   'Optional citation/anchor shown beneath the why (e.g. an operator''s chosen scripture or maxim). Empty ⇒ no attribution line.')
ON CONFLICT (key) DO NOTHING;

-- ---------------------------------------------------------------------
-- render_north_star() — compose the block from config, or NULL if the
-- operator has cleared the why (opt-out / fail-open-to-silence).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.render_north_star()
RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_why        text  := stewards.config_get_text('north_star.why');
    v_source     text  := stewards.config_get_text('north_star.source');
    v_directions jsonb := stewards.config_get('north_star.directions');
    v_dir_str    text;
    v_block      text;
BEGIN
    -- No why ⇒ no North Star. An operator can opt out by clearing the key.
    IF v_why IS NULL OR length(trim(v_why)) = 0 THEN
        RETURN NULL;
    END IF;

    v_block := E'=== North Star ===\n' || trim(v_why);

    IF v_source IS NOT NULL AND length(trim(v_source)) > 0 THEN
        v_block := v_block || E'\n  — ' || trim(v_source);
    END IF;

    IF v_directions IS NOT NULL
       AND jsonb_typeof(v_directions) = 'array'
       AND jsonb_array_length(v_directions) > 0 THEN
        SELECT string_agg('  - ' || trim(d.value #>> '{}'), E'\n')
          INTO v_dir_str
          FROM jsonb_array_elements(v_directions) d;
        v_block := v_block ||
            E'\n\nLet this why govern how you work here:\n' || v_dir_str ||
            E'\n\nWhen the commitments and values below pull in different directions, this is the tie-breaker.';
    END IF;

    RETURN v_block;
END;
$func$;

COMMENT ON FUNCTION stewards.render_north_star() IS
'Composes the === North Star === block from the north_star.* config keys (why + optional source + directions). Returns NULL when the why is empty/absent (operator opt-out). Called first by compose_system_prompt; the why is the standing Intent (step 1) carried on every agent call.';

-- ---------------------------------------------------------------------
-- compose_system_prompt — re-authored (later-file-wins over 09) to
-- prepend the North Star FIRST and echo it last. Body is otherwise the
-- 09/PR.1 version verbatim: covenant + presiding, work_item intent,
-- agent prompt, instructions, skills, agenda, tool primers, Watch echo.
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
'Phase 5d (C.4) + PR.1 + North Star (74): prepends the substrate''s standing North Star (step 1, the *why*) FIRST, then the active covenant (with the presiding extension) + work_item intent, before the agent block; ends with The Watch echo (covenant keys restated last) and the North Star echo (the why restated last as the tie-breaker). Why first AND last, covenant first AND last — primacy and recency per serial-position research.';
