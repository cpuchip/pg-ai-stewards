-- =====================================================================
-- Batch J.12 — brainstorm cap pre-flight (remaining half)
-- =====================================================================
-- (classify_error + the work_item_failures view moved into 06-cost.sql
--  at the 2026-06-12 consolidation. What remains is the
--  start_brainstorm redefinition — the J.9.c signature + the pre-flight
--  enforced-cap check — which consolidates with the fanout batch.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 3. start_brainstorm pre-flight cap check (carry J.9.c forward).
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS stewards.start_brainstorm(text, text, text, text, text, bigint, jsonb, text[]);

CREATE OR REPLACE FUNCTION stewards.start_brainstorm(
    p_binding_question        text,
    p_destination             text,
    p_project_association     text     DEFAULT NULL,
    p_actor                   text     DEFAULT 'human',
    p_slug                    text     DEFAULT NULL,
    p_cost_cap_per_lens_micro bigint   DEFAULT 200000,
    p_models                  jsonb    DEFAULT NULL,
    p_lenses                  text[]   DEFAULT ARRAY['scamper', 'six-hats', 'crazy8s', 'reverse']
)
RETURNS uuid LANGUAGE plpgsql AS $FN$
DECLARE
    v_slug             text;
    v_parent_id        uuid;
    v_manifest         jsonb;
    v_lens             text;
    v_lens_family      text;
    v_lens_slug        text;
    v_models_entry     jsonb;
    v_model_override   text;
    v_provider_override text;
    v_child            jsonb;
    v_children_arr     jsonb := '[]'::jsonb;
    v_unknown_lenses   text[];
    v_lens_provider    text;
    v_capped           text[] := ARRAY[]::text[];
BEGIN
    IF p_lenses IS NULL OR cardinality(p_lenses) = 0 THEN
        RAISE EXCEPTION 'start_brainstorm: p_lenses must contain at least one lens name';
    END IF;

    -- Validate every requested lens corresponds to an existing pipeline.
    SELECT array_agg(lens_name)
      INTO v_unknown_lenses
      FROM (SELECT unnest(p_lenses) AS lens_name) requested
     WHERE NOT EXISTS (
         SELECT 1 FROM stewards.pipelines
          WHERE family = 'brainstorm-' || requested.lens_name
     );
    IF v_unknown_lenses IS NOT NULL THEN
        RAISE EXCEPTION 'start_brainstorm: unknown lens name(s): %. Available lenses: %. (Introspect with SELECT regexp_replace(family, ''^brainstorm-'', '''') FROM stewards.pipelines WHERE family LIKE ''brainstorm-%%'')',
            v_unknown_lenses,
            (SELECT array_agg(regexp_replace(family, '^brainstorm-', ''))
               FROM stewards.pipelines WHERE family LIKE 'brainstorm-%');
    END IF;

    -- J.12 PRE-FLIGHT: refuse early (with a clear message) if any lens
    -- routes to a provider whose enforced spend cap is already reached.
    -- Resolves each lens's effective provider the same way dispatch does
    -- (p_models override -> pipeline default -> catalog default), so a
    -- capped Gemini lens surfaces here instead of being silently dropped
    -- by spawn_children's swallowed dispatch RAISE.
    FOREACH v_lens IN ARRAY p_lenses LOOP
        v_lens_provider := NULL;
        IF p_models IS NOT NULL AND (p_models ? v_lens)
           AND jsonb_typeof(p_models -> v_lens) = 'object' THEN
            v_lens_provider := (p_models -> v_lens) ->> 'provider';
        END IF;
        IF v_lens_provider IS NULL THEN
            v_lens_provider := COALESCE(
                (SELECT metadata->>'default_provider' FROM stewards.pipelines
                  WHERE family = 'brainstorm-' || v_lens),
                stewards.catalog_default_provider()
            );
        END IF;
        IF v_lens_provider IS NOT NULL
           AND stewards.provider_cap_exceeded(v_lens_provider)
           AND NOT (v_lens_provider = ANY(v_capped)) THEN
            v_capped := v_capped || v_lens_provider;
        END IF;
    END LOOP;

    IF cardinality(v_capped) > 0 THEN
        RAISE EXCEPTION 'start_brainstorm: refused — provider(s) % at spend cap. Top up + reset: SELECT stewards.provider_cap_refill(''<provider>''); (or drop the lens(es) routed to them).',
            v_capped;
    END IF;

    v_slug := COALESCE(p_slug, 'brainstorm-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS'));

    FOREACH v_lens IN ARRAY p_lenses LOOP
        v_lens_family    := 'brainstorm-' || v_lens;
        v_lens_slug      := v_slug || '-' || v_lens;
        v_model_override := NULL;
        v_provider_override := NULL;

        IF p_models IS NOT NULL AND (p_models ? v_lens) THEN
            v_models_entry := p_models -> v_lens;
            IF jsonb_typeof(v_models_entry) = 'string' THEN
                v_model_override := v_models_entry #>> '{}';
            ELSIF jsonb_typeof(v_models_entry) = 'object' THEN
                v_model_override    := v_models_entry ->> 'model';
                v_provider_override := v_models_entry ->> 'provider';
            END IF;
        END IF;

        v_child := jsonb_build_object(
            'slug',             v_lens_slug,
            'pipeline_family',  v_lens_family,
            'binding_question', p_binding_question,
            'cost_cap_micro',   p_cost_cap_per_lens_micro
        );
        IF v_model_override IS NOT NULL THEN
            v_child := v_child || jsonb_build_object('model_override', v_model_override);
        END IF;
        IF v_provider_override IS NOT NULL THEN
            v_child := v_child || jsonb_build_object('provider_override', v_provider_override);
        END IF;

        v_children_arr := v_children_arr || v_child;
    END LOOP;

    v_manifest := jsonb_build_object(
        'rationale', format('Brainstorm: %s lens(es) — %s. Synthesis aggregator combines.',
                            cardinality(p_lenses), array_to_string(p_lenses, ', ')),
        'children', v_children_arr,
        'aggregate', jsonb_build_object('destination', p_destination, 'synthesis', true)
    );

    INSERT INTO stewards.work_items (
        pipeline_family, current_stage, slug, input, intent_id, actor,
        project_association, stage_results, maturity, status
    ) VALUES (
        'decompose-fanout', 'decompose', v_slug,
        jsonb_build_object('binding_question', p_binding_question, 'lenses', to_jsonb(p_lenses)),
        (SELECT id FROM stewards.intents WHERE slug = 'scripture-study'),
        p_actor, p_project_association,
        jsonb_build_object(
            'context_gather', jsonb_build_object('output', format('brainstorm: pre-populated %s-lens manifest, no context_gather LLM call', cardinality(p_lenses))),
            'decompose', jsonb_build_object('output', v_manifest)
        ),
        'planned', 'completed'
    )
    RETURNING id INTO v_parent_id;

    UPDATE stewards.work_items SET maturity = 'verified' WHERE id = v_parent_id;

    RAISE NOTICE 'start_brainstorm: parent=% slug=% lenses=% p_models=%',
        v_parent_id, v_slug, p_lenses, COALESCE(p_models::text, 'NULL');
    RETURN v_parent_id;
END;
$FN$;

COMMENT ON FUNCTION stewards.start_brainstorm(text, text, text, text, text, bigint, jsonb, text[]) IS
'J.12: adds a pre-flight enforced-cap check (refuses with a clear message before spawning if any lens routes to an over-cap provider) on top of the J.9.c lens-subset + per-lens-model signature. The J.11 dispatch gate remains the universal enforcement; this just surfaces the cap cleanly on the brainstorm path.';

-- =====================================================================
-- Acceptance:
--   1. classify_error('... spend cap reached ...') = 'spend_cap_reached'
--   2. classify_error('chat HTTP 429: {... RESOURCE_EXHAUSTED ... quota ...}') = 'provider_budget'
--   3. classify_error('chat HTTP 401: invalid API key') = 'auth'
--   4. classify_error('') = 'none'
--   5. With google_gemini over cap, start_brainstorm(..., p_models with a
--      gemini lens) RAISEs 'refused — provider(s) {google_gemini} at spend
--      cap' BEFORE inserting the parent.
-- =====================================================================
