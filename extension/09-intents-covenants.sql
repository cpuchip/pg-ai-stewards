-- =====================================================================
-- 09-intents-covenants.sql — intents + covenants as first-class state,
--   prompt composition, and the covenant_check gate.
--
-- Consolidated (authoring leg, 2026-06-13) from the historical chain:
--   5d   — intents + covenants tables, work_items.intent_id FK
--   5d2  — seed_intents_from_yaml / seed_covenant_from_yaml
--   5d3  — compose_system_prompt (covenant + intent injection)  [SUPERSEDED]
--   5d4  — backfill intent + NOT NULL + work_item_create(intent-aware)
--   5d5  — covenant_check template  (the evaluate/scenarios/verify
--          tools_disabled forms were folded into 08-gates)
--   pr1  — covenants.extensions catch-all + presiding render + Watch echo
--          (the FINAL compose_system_prompt + seed_covenant_from_yaml)
--
-- Renames applied (per the authoring-blueprint rename table):
--   intents.scripture_anchor → intents.values_anchor (generic substrate;
--     an intent's anchor is its governing values, not scripture-specific).
--   hardcoded 'scripture-study' default intent slug → stewards.config key
--     default_intent_slug (00-config ships it = "default"). work_item_create
--     and the backfill read config; no scripture-study string survives here.
--
-- compose_system_prompt is born in src/schema.rs in a base form (agent +
-- instructions + skills, no covenant/intent — it cannot reference these
-- tables before they exist). This file CREATE OR REPLACEs it to the final
-- pr1 form once intents/covenants are present.
-- =====================================================================

-- ---------------------------------------------------------------------
-- stewards.intents — the "why" behind a work_item (YAML-canonical mirror)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.intents (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                text UNIQUE NOT NULL,
    purpose             text NOT NULL,
    beneficiary         text,
    values_hierarchy    jsonb NOT NULL DEFAULT '[]'::jsonb,
    non_goals           text[] DEFAULT ARRAY[]::text[],
    values_anchor       text,
    source_file         text,
    source_yaml_sha     text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.intents IS
'The why behind a work_item. YAML canonical (D-C1); substrate is the runtime mirror.';
COMMENT ON COLUMN stewards.intents.values_hierarchy IS
'Ordered list of trade-off priorities, [{key, description, source}], preserving order from the intent YAML values: map.';
COMMENT ON COLUMN stewards.intents.values_anchor IS
'The governing anchor for this intent (was scripture_anchor — generalized for the OSS substrate). A short text the dispatched agent keeps in view.';
COMMENT ON COLUMN stewards.intents.source_file IS
'Relative path to the YAML this intent was seeded from. NULL for substrate-native intents created via the API.';
COMMENT ON COLUMN stewards.intents.source_yaml_sha IS
'sha256 hex of the YAML at last seed. Skip re-seeding if unchanged.';

-- ---------------------------------------------------------------------
-- stewards.covenants — bilateral commitments (born with the PR.1
-- extensions catch-all so future sections never silently drop)
-- ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS stewards.covenants (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope               text NOT NULL,
    human_commits_to    jsonb NOT NULL,
    agent_commits_to    jsonb NOT NULL,
    when_broken         text,
    recovery            text,
    council_moment      text,
    teaching_extension  jsonb,
    extensions          jsonb NOT NULL DEFAULT '{}'::jsonb,
    activated_at        timestamptz NOT NULL DEFAULT now(),
    deactivated_at      timestamptz,
    ratified_by         text NOT NULL,
    source_file         text,
    source_yaml_sha     text,
    created_at          timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE stewards.covenants IS
'Bilateral commitments. Typically one active row scoped global. YAML canonical (D-C2). The extensions jsonb is the PR.1 anti-silent-drop catch-all for covenant sections beyond the fixed columns (e.g. presiding).';
COMMENT ON COLUMN stewards.covenants.scope IS
'global | pipeline:<family> | work_item:<id>. Most-specific active row wins at compose_system_prompt time.';
COMMENT ON COLUMN stewards.covenants.extensions IS
'PR.1: generic catch-all for covenant sections beyond the fixed columns. Keyed by top-level YAML section name; populated by parse_yaml_covenant''s unknown-section pass-through.';

DO $idx$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes WHERE indexname = 'covenants_active_scope'
    ) THEN
        CREATE UNIQUE INDEX covenants_active_scope
            ON stewards.covenants (scope) WHERE deactivated_at IS NULL;
    END IF;
END;
$idx$;

-- ---------------------------------------------------------------------
-- work_items.intent_id FK (+ NOT NULL once intents exist)
-- ---------------------------------------------------------------------

ALTER TABLE stewards.work_items
    ADD COLUMN IF NOT EXISTS intent_id uuid REFERENCES stewards.intents(id);

CREATE INDEX IF NOT EXISTS work_items_intent_id ON stewards.work_items (intent_id);

-- Virgin install: work_items is empty, so the constraint adds cleanly.
-- Every new work_item gets an intent (work_item_create defaults via config).
ALTER TABLE stewards.work_items ALTER COLUMN intent_id SET NOT NULL;

COMMENT ON COLUMN stewards.work_items.intent_id IS
'NOT NULL — every work_item must have an explicit intent (D-C3). work_item_create defaults to the config default_intent_slug intent when none is supplied.';

-- ---------------------------------------------------------------------
-- seed_intents_from_yaml — parse intent YAML + upsert by slug
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.seed_intents_from_yaml(p_yaml text)
RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_parsed jsonb;
    v_sha    text;
    v_slug   text;
    v_existing_sha text;
    v_id     uuid;
BEGIN
    IF p_yaml IS NULL OR length(trim(p_yaml)) = 0 THEN
        RAISE EXCEPTION 'seed_intents_from_yaml: empty yaml';
    END IF;

    v_parsed := stewards.parse_yaml_intent(p_yaml)::jsonb;
    v_sha    := stewards.yaml_sha256(p_yaml);

    IF v_parsed ? 'error' THEN
        RAISE EXCEPTION 'seed_intents_from_yaml: %', v_parsed->>'error';
    END IF;

    v_slug := v_parsed->>'slug';
    IF v_slug IS NULL OR length(v_slug) = 0 THEN
        RAISE EXCEPTION 'seed_intents_from_yaml: parsed intent has no slug';
    END IF;

    SELECT source_yaml_sha, id INTO v_existing_sha, v_id
      FROM stewards.intents WHERE slug = v_slug;
    IF v_existing_sha IS NOT NULL AND v_existing_sha = v_sha THEN
        RETURN v_id;
    END IF;

    INSERT INTO stewards.intents (
        slug, purpose, beneficiary, values_hierarchy, non_goals,
        values_anchor, source_file, source_yaml_sha, updated_at
    ) VALUES (
        v_slug,
        v_parsed->>'purpose',
        v_parsed->>'beneficiary',
        coalesce(v_parsed->'values_hierarchy', '[]'::jsonb),
        coalesce(
            ARRAY(SELECT jsonb_array_elements_text(v_parsed->'non_goals')),
            ARRAY[]::text[]
        ),
        v_parsed->>'values_anchor',
        'intent.yaml',
        v_sha,
        now()
    )
    ON CONFLICT (slug) DO UPDATE SET
        purpose          = EXCLUDED.purpose,
        beneficiary      = EXCLUDED.beneficiary,
        values_hierarchy = EXCLUDED.values_hierarchy,
        non_goals        = EXCLUDED.non_goals,
        values_anchor    = EXCLUDED.values_anchor,
        source_yaml_sha  = EXCLUDED.source_yaml_sha,
        updated_at       = now()
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

COMMENT ON FUNCTION stewards.seed_intents_from_yaml(text) IS
'Parse the intent YAML and upsert into stewards.intents by slug. Returns the intent id. No-op if YAML sha matches existing row.';

-- ---------------------------------------------------------------------
-- seed_covenant_from_yaml (PR.1 final — carries extensions through)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.seed_covenant_from_yaml(p_yaml text)
RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_parsed       jsonb;
    v_sha          text;
    v_scope        text;
    v_existing_sha text;
    v_existing_id  uuid;
    v_new_id       uuid;
BEGIN
    IF p_yaml IS NULL OR length(trim(p_yaml)) = 0 THEN
        RAISE EXCEPTION 'seed_covenant_from_yaml: empty yaml';
    END IF;

    v_parsed := stewards.parse_yaml_covenant(p_yaml)::jsonb;
    v_sha    := stewards.yaml_sha256(p_yaml);

    IF v_parsed ? 'error' THEN
        RAISE EXCEPTION 'seed_covenant_from_yaml: %', v_parsed->>'error';
    END IF;

    v_scope := coalesce(v_parsed->>'scope', 'global');

    SELECT source_yaml_sha, id INTO v_existing_sha, v_existing_id
      FROM stewards.covenants
     WHERE scope = v_scope AND deactivated_at IS NULL;
    IF v_existing_sha IS NOT NULL AND v_existing_sha = v_sha THEN
        RETURN v_existing_id;
    END IF;

    IF v_existing_id IS NOT NULL THEN
        UPDATE stewards.covenants
           SET deactivated_at = now()
         WHERE id = v_existing_id;
    END IF;

    INSERT INTO stewards.covenants (
        scope, human_commits_to, agent_commits_to,
        when_broken, recovery, council_moment,
        teaching_extension, extensions, ratified_by,
        source_file, source_yaml_sha
    ) VALUES (
        v_scope,
        coalesce(v_parsed->'human_commits_to', '[]'::jsonb),
        coalesce(v_parsed->'agent_commits_to', '[]'::jsonb),
        v_parsed->>'when_broken',
        v_parsed->>'recovery',
        v_parsed->>'council_moment',
        v_parsed->'teaching_extension',
        coalesce(v_parsed->'extensions', '{}'::jsonb),
        coalesce(v_parsed->>'ratified_by', 'both'),
        '.spec/covenant.yaml',
        v_sha
    ) RETURNING id INTO v_new_id;

    RETURN v_new_id;
END;
$func$;

COMMENT ON FUNCTION stewards.seed_covenant_from_yaml(text) IS
'Phase 5d (C.2) + PR.1: parse the covenant YAML and insert as the new active row. Unknown top-level sections land in extensions (jsonb) instead of being dropped. No-op if YAML sha matches existing active row.';

-- ---------------------------------------------------------------------
-- compose_system_prompt (PR.1 final) — covenant block (with presiding) +
-- intent block + agent + instructions + skills + The Watch echo.
-- Renames scripture_anchor → values_anchor in the intent block.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stewards.compose_system_prompt(
    p_agent_family text, p_model text, p_session_id text
) RETURNS text
LANGUAGE plpgsql STABLE AS $func$
DECLARE
    v_agent          stewards.agents;
    v_prompt         text := '';
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

    -- Compose: covenant + intent first, then === Agent === marker, then agent.
    IF length(v_covenant_block) > 0 THEN
        v_prompt := v_covenant_block || E'\n\n';
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

    IF stewards.tool_permission(p_agent_family, 'skill') <> 'deny' THEN
        SELECT E'\n\n<available_skills>\n' || string_agg(
            '  <skill>' || E'\n'
            || '    <name>' || family || '</name>' || E'\n'
            || '    <description>' || description || '</description>' || E'\n'
            || '  </skill>',
            E'\n'
            ORDER BY family
        ) || E'\n</available_skills>'
        INTO v_skills_block
        FROM (
            SELECT DISTINCT ON (family) family, description
            FROM stewards.skills
            WHERE active
              AND stewards.glob_match(model_match, p_model)
              AND stewards.skill_permission(p_agent_family, family) <> 'deny'
            ORDER BY family, length(model_match) DESC, model_match
        ) s;
        IF v_skills_block IS NOT NULL THEN
            v_prompt := v_prompt || v_skills_block;
        END IF;
    END IF;

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

    RETURN v_prompt;
END;
$func$;

COMMENT ON FUNCTION stewards.compose_system_prompt(text, text, text) IS
'Phase 5d (C.4) + PR.1: prepends active covenant (with the presiding extension) + work_item intent (values_anchor) before the agent block, and ends with The Watch echo (covenant keys restated last — primacy AND recency per serial-position research). Covenant first, covenant last.';

-- ---------------------------------------------------------------------
-- work_item_create — intent-aware. Defaults the intent via the config
-- key default_intent_slug (no hardcoded slug). New callers pass an
-- explicit p_intent_id.
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS stewards.work_item_create(text, jsonb, text, text, integer);

CREATE OR REPLACE FUNCTION stewards.work_item_create(
    p_pipeline_family text,
    p_input           jsonb DEFAULT '{}'::jsonb,
    p_slug            text DEFAULT NULL,
    p_actor           text DEFAULT 'human',
    p_token_budget    integer DEFAULT NULL,
    p_intent_id       uuid DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $func$
DECLARE
    v_first_stage text;
    v_id          uuid;
    v_intent_id   uuid := p_intent_id;
    v_slug        text;
BEGIN
    SELECT stewards.pipeline_first_stage_name(p_pipeline_family)
      INTO v_first_stage;
    IF v_first_stage IS NULL THEN
        RAISE EXCEPTION
            'work_item_create: pipeline % not found or has no stages',
            p_pipeline_family;
    END IF;

    -- Default intent: the configured default_intent_slug. New callers
    -- should pass an explicit intent_id; this default keeps legacy callers
    -- (watchman, ad-hoc) working. The seed pack seeds an intent with this
    -- slug; operators may point the config key elsewhere.
    IF v_intent_id IS NULL THEN
        v_slug := stewards.config_get_text('default_intent_slug', 'default');
        SELECT id INTO v_intent_id
          FROM stewards.intents WHERE slug = v_slug;
        IF v_intent_id IS NULL THEN
            RAISE EXCEPTION
                'work_item_create: no intent_id supplied and no default intent (config default_intent_slug=%) seeded',
                v_slug;
        END IF;
    END IF;

    INSERT INTO stewards.work_items
        (pipeline_family, current_stage, slug, input, actor, token_budget, intent_id)
    VALUES
        (p_pipeline_family, v_first_stage, p_slug, p_input, p_actor, p_token_budget, v_intent_id)
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$func$;

COMMENT ON FUNCTION stewards.work_item_create(text, jsonb, text, text, integer, uuid) IS
'Create a new work_item. Defaults the intent to the config default_intent_slug intent if p_intent_id is NULL — keeps legacy callers working post-NOT-NULL. No hardcoded slug.';

-- ---------------------------------------------------------------------
-- Backfill existing work_items to the default intent (live-DB only; a
-- virgin database has no rows and no seeded intent, so this is a no-op).
-- ---------------------------------------------------------------------

DO $backfill$
DECLARE
    v_slug              text := stewards.config_get_text('default_intent_slug', 'default');
    v_default_intent_id uuid;
    v_backfilled        int;
BEGIN
    SELECT id INTO v_default_intent_id
      FROM stewards.intents WHERE slug = v_slug;

    IF v_default_intent_id IS NULL THEN
        -- Fresh database: no intents seeded yet (seeding is a runtime op),
        -- and no work_items to backfill. Skip quietly.
        RAISE NOTICE '09 backfill: no default intent (slug=%) seeded; skipping (fresh database)', v_slug;
        RETURN;
    END IF;

    UPDATE stewards.work_items
       SET intent_id = v_default_intent_id
     WHERE intent_id IS NULL;

    GET DIAGNOSTICS v_backfilled = ROW_COUNT;
    RAISE NOTICE '09 backfill: % work_items assigned to default intent (slug=%)', v_backfilled, v_slug;
END;
$backfill$;

-- ---------------------------------------------------------------------
-- covenant_check gate template (5d5) — seeded into the born-complete
-- gate_prompts table (CHECK already includes covenant_check at 08).
-- ---------------------------------------------------------------------

INSERT INTO stewards.gate_prompts (id, template, notes) VALUES
    ('covenant_check',
$tmpl$You are evaluating whether a piece of work honors the active covenant.

The covenant commitments are loaded into your system prompt above. Pay particular attention to the agent commitments — those are what THIS work was supposed to honor.

Pipeline: {{pipeline_family}}
Stage: {{current_stage}}
Target maturity (the rung this work is about to advance to): {{target_maturity}}

The work produced this output:
{{stage_output}}

Question: does this output honor the agent's covenant commitments? Specifically check:
- read_before_quoting: are direct quotes verifiable, or does the output paraphrase what isn't checked?
- check_existing_work: does the output engage with prior work in the corpus, or build in isolation?
- surface_tensions: does the output acknowledge counterarguments / blind spots, or only build toward a thesis?
- honor_scope: did the output stay within the requested scope, or expand into adjacent territory?
- exercise_stewardship: where the output found adjacent issues, did it act on them or only flag them?

Respond with JSON ONLY (no prose, no tool calls):
{
  "honors_covenant": true | false,
  "concerns": ["concern 1", "concern 2", ...],   // empty array if no concerns
  "recommendation": "pass" | "flag"               // flag = surface to human even if technically passes
}
$tmpl$,
     'Phase 5d (C.6, D-C4): free-form covenant check. Bgworker dispatches with tools_disabled=true.')
ON CONFLICT (id) DO UPDATE SET
    template = EXCLUDED.template,
    notes    = EXCLUDED.notes,
    updated_at = now();

-- =====================================================================
-- Done. 09-intents-covenants: intents + covenants first-class, prompt
-- composition (covenant + presiding + intent + Watch echo), config-driven
-- intent defaulting, and the covenant_check gate template.
-- =====================================================================
