-- =====================================================================
-- 104-observations.sql — the observations store: the atomic unit of
--   sourced, confidence-labelled knowledge.
-- =====================================================================
-- An "observation" is one small claim, tied to a source when possible,
-- carrying two DELIBERATELY DISTINCT labels:
--   * confidence — is the CLAIM reliable (high/medium/low/anecdotal)?
--   * fidelity   — how LOSSY was the EXTRACTION from its source
--                  (verbatim/paraphrase/inferred)?
-- A verbatim quote can still be a low-confidence claim (an unreliable
-- narrator saying something precisely). A paraphrase can carry high
-- confidence (a well-corroborated summary). Collapsing the two into one
-- axis loses exactly the distinction that makes an observation auditable —
-- that is the discipline this table exists to hold.
--
-- Counter-evidence is first-class: counter_of is a self-FK, not a boolean
-- flag bolted onto the row. An observation that CONTRADICTS another IS an
-- observation — sourced and confidence-labelled the same as any other —
-- so a claim and its rebuttal both stay first-class, queryable rows.
--
-- Schema deviations from the literal brief, VERIFIED LIVE via scripts/db.sh
-- before a single FK was written (the same discipline 92-wiki.sql's header
-- documents for its own doc_id/asset_id deviations):
--   * source_doc_id is `text`, not `uuid` — stewards.docs.id is `text`
--     (default gen_random_uuid()::text), same deviation class 92/96/97
--     already carry for every FK into stewards.docs.
--   * world_id is `bigint`, not `uuid` — stewards.worlds.world_id is a
--     `bigint GENERATED ALWAYS AS IDENTITY` column (54-loreworks.sql).
--   * entity_id is `bigint`, not `uuid` — stewards.world_entities.entity_id
--     is likewise a bigint identity column, matching world_id's real type.
--
-- Tool surface follows 94-wiki-curator.sql's fleet-integration addendum
-- (restated in 100-schedule-chat.sql's header): every write path is a
-- plain jsonb-in/jsonb-out SQL function that never RAISEs to the caller
-- (errors come back as {"ok":false,"error":"..."}), paired with a
-- `*_tool(jsonb)` wrapper that is what tool_defs.execute_target actually
-- points at (kind=sql_fn convention). World/entity identifiers are taken
-- as world_slug/entity_name (not raw ids) — the same surface 54/57/85's
-- lore tools already expose to a chat model, resolved server-side by
-- name-or-alias match (LIMIT 1, no ambiguity error — the established
-- 85-world-chat.sql precedent for that lookup).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — the table
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.observations (
    id            bigserial PRIMARY KEY,
    claim         text NOT NULL,
    confidence    text NOT NULL
                  CONSTRAINT observations_confidence_check
                  CHECK (confidence IN ('high','medium','low','anecdotal')),
    fidelity      text NOT NULL DEFAULT 'verbatim'
                  CONSTRAINT observations_fidelity_check
                  CHECK (fidelity IN ('verbatim','paraphrase','inferred')),
    source_doc_id text
                  REFERENCES stewards.docs(id) ON DELETE SET NULL,
    source_ref    text,        -- row/timestamp/page WITHIN the source doc
    world_id      bigint
                  REFERENCES stewards.worlds(world_id) ON DELETE SET NULL,
    entity_id     bigint
                  REFERENCES stewards.world_entities(entity_id) ON DELETE SET NULL,
    counter_of    bigint
                  REFERENCES stewards.observations(id) ON DELETE SET NULL,
    outcome_ref   text,        -- optional link to a real outcome this claim was checked against
    tags          text[] NOT NULL DEFAULT ARRAY[]::text[],
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    text NOT NULL DEFAULT 'agent'
);

CREATE INDEX IF NOT EXISTS observations_source_doc_idx
    ON stewards.observations(source_doc_id) WHERE source_doc_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS observations_world_idx
    ON stewards.observations(world_id) WHERE world_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS observations_confidence_idx
    ON stewards.observations(confidence);

-- Two additions beyond the ratified index list (obviously warranted, zero
-- behavior change — the same "fix it, don't just ask" call as a same-shape
-- bug found in a sibling file): entity_id and counter_of are BOTH filtered
-- by this file's own tool surface below (observation_search's entity_name
-- filter; a counter-evidence chain walked from counter_of), so leaving
-- them unindexed would mean the ratified tools ship with a sequential scan
-- on their own most natural filters.
CREATE INDEX IF NOT EXISTS observations_entity_idx
    ON stewards.observations(entity_id) WHERE entity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS observations_counter_of_idx
    ON stewards.observations(counter_of) WHERE counter_of IS NOT NULL;

COMMENT ON TABLE stewards.observations IS
'104: one small, sourced, confidence-labelled claim — the atomic unit this knowledge engine reasons over. confidence = is the claim reliable; fidelity = how lossy was the extraction (kept distinct on purpose — see file header). counter_of self-references another observation this one contradicts: counter-evidence is first-class, not a flag.';
COMMENT ON COLUMN stewards.observations.confidence IS
'How reliable the CLAIM is: high | medium | low | anecdotal. Orthogonal to fidelity.';
COMMENT ON COLUMN stewards.observations.fidelity IS
'How lossy the EXTRACTION was: verbatim (exact quote/reading) | paraphrase (restated, meaning preserved) | inferred (the observer''s own inference, not stated outright in the source). A verbatim quote can still be low-confidence; a paraphrase can be high-confidence.';
COMMENT ON COLUMN stewards.observations.counter_of IS
'Self-FK: this observation is COUNTER-EVIDENCE to the observation named here. NULL = not counter-evidence. Populated via observation_counter (below), never a plain boolean flag.';
COMMENT ON COLUMN stewards.observations.outcome_ref IS
'Optional free-text link to a real-world outcome this observation was later checked against (a result, a metric, an event) — the seam between a claim and what actually happened.';

-- =====================================================================
-- §2 — observation_add: validate + insert. Core logic (reused by
--   observation_counter below); observation_add_tool is the registered
--   tool wrapper (kind=sql_fn convention — every sql_fn tool_defs row in
--   this codebase points at a *_tool-suffixed function; verified live,
--   zero exceptions).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.observation_add(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_claim       text    := btrim(coalesce(p_args->>'claim', ''));
    v_confidence  text    := btrim(coalesce(p_args->>'confidence', ''));
    v_fidelity    text    := btrim(coalesce(p_args->>'fidelity', 'verbatim'));
    v_source_doc  text    := nullif(btrim(coalesce(p_args->>'source_doc_id', '')), '');
    v_source_ref  text    := nullif(btrim(coalesce(p_args->>'source_ref', '')), '');
    v_world_slug  text    := nullif(btrim(coalesce(p_args->>'world_slug', '')), '');
    v_entity_name text    := nullif(btrim(coalesce(p_args->>'entity_name', '')), '');
    v_outcome_ref text    := nullif(btrim(coalesce(p_args->>'outcome_ref', '')), '');
    v_created_by  text    := nullif(btrim(coalesce(p_args->>'created_by', '')), '');
    v_tags        text[];
    v_counter_of  bigint;
    v_world_id    bigint;
    v_entity_id   bigint;
    v_row         stewards.observations%ROWTYPE;
BEGIN
    IF v_claim = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'claim is required');
    END IF;
    IF v_confidence NOT IN ('high','medium','low','anecdotal') THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('confidence must be one of high, medium, low, anecdotal (got %L)', p_args->>'confidence'));
    END IF;
    IF v_fidelity NOT IN ('verbatim','paraphrase','inferred') THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('fidelity must be one of verbatim, paraphrase, inferred (got %L)', v_fidelity));
    END IF;

    IF v_source_doc IS NOT NULL AND NOT EXISTS (SELECT 1 FROM stewards.docs WHERE id = v_source_doc) THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no doc with id %s', v_source_doc));
    END IF;

    IF v_world_slug IS NOT NULL THEN
        SELECT world_id INTO v_world_id FROM stewards.worlds WHERE slug = v_world_slug;
        IF v_world_id IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'error', format('no world with slug "%s"', v_world_slug));
        END IF;
        IF v_entity_name IS NOT NULL THEN
            SELECT entity_id INTO v_entity_id FROM stewards.world_entities
             WHERE world_id = v_world_id AND (name = v_entity_name OR v_entity_name = ANY(aliases))
             LIMIT 1;
            IF v_entity_id IS NULL THEN
                RETURN jsonb_build_object('ok', false, 'error',
                    format('no entity named "%s" in world "%s"', v_entity_name, v_world_slug));
            END IF;
        END IF;
    ELSIF v_entity_name IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', 'entity_name requires world_slug');
    END IF;

    IF (p_args ? 'counter_of') AND jsonb_typeof(p_args->'counter_of') <> 'null' THEN
        v_counter_of := (p_args->>'counter_of')::bigint;
        IF NOT EXISTS (SELECT 1 FROM stewards.observations WHERE id = v_counter_of) THEN
            RETURN jsonb_build_object('ok', false, 'error', format('no observation with id %s to counter', v_counter_of));
        END IF;
    END IF;

    IF jsonb_typeof(p_args->'tags') = 'array' THEN
        SELECT array_agg(btrim(t)) INTO v_tags
          FROM jsonb_array_elements_text(p_args->'tags') AS t
         WHERE btrim(t) <> '';
    END IF;

    INSERT INTO stewards.observations
        (claim, confidence, fidelity, source_doc_id, source_ref, world_id, entity_id,
         counter_of, outcome_ref, tags, created_by)
    VALUES
        (v_claim, v_confidence, v_fidelity, v_source_doc, v_source_ref, v_world_id, v_entity_id,
         v_counter_of, v_outcome_ref, coalesce(v_tags, ARRAY[]::text[]), coalesce(v_created_by, 'agent'))
    RETURNING * INTO v_row;

    RETURN jsonb_build_object(
        'ok', true,
        'id', v_row.id,
        'observation', jsonb_build_object(
            'id', v_row.id, 'claim', v_row.claim, 'confidence', v_row.confidence,
            'fidelity', v_row.fidelity, 'source_doc_id', v_row.source_doc_id,
            'source_ref', v_row.source_ref, 'world_slug', v_world_slug,
            'entity_name', v_entity_name, 'counter_of', v_row.counter_of,
            'outcome_ref', v_row.outcome_ref, 'tags', to_jsonb(v_row.tags),
            'created_at', v_row.created_at, 'created_by', v_row.created_by));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.observation_add(jsonb) IS
'104: validate + insert one observation. Args: claim, confidence (required); fidelity (default verbatim); source_doc_id, source_ref, world_slug, entity_name (requires world_slug, resolved by name-or-alias), counter_of (an existing observation id), outcome_ref, tags (array), created_by. Never raises — returns {"ok":false,"error":"..."} on any validation failure. Reused directly by observation_counter.';

CREATE OR REPLACE FUNCTION stewards.observation_add_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN stewards.observation_add(p_args);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- =====================================================================
-- §3 — observation_search: FTS over claim + confidence/world/entity/tags/
--   counter_of filters. Ad hoc to_tsvector (no stored/generated column, no
--   GIN index) — the same small-table convention 99-route-intake.sql uses
--   for scope_candidates over stewards.worlds; observations is expected to
--   stay in that size class. NOTE (named, not silently added): if this
--   table grows large, a stored claim_tsv + GIN index would be the next
--   move — not added here since it wasn't in the ratified index list.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.observation_search(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_query       text    := nullif(btrim(coalesce(p_args->>'query', '')), '');
    v_confidence  text    := nullif(btrim(coalesce(p_args->>'confidence', '')), '');
    v_world_slug  text    := nullif(btrim(coalesce(p_args->>'world_slug', '')), '');
    v_entity_name text    := nullif(btrim(coalesce(p_args->>'entity_name', '')), '');
    v_counter_of  bigint;
    v_world_id    bigint;
    v_entity_id   bigint;
    v_limit       int     := least(greatest(coalesce((p_args->>'limit')::int, 20), 1), 100);
    v_tags        text[];
    v_out         jsonb;
BEGIN
    IF v_confidence IS NOT NULL AND v_confidence NOT IN ('high','medium','low','anecdotal') THEN
        RETURN jsonb_build_object('ok', false, 'error',
            format('confidence must be one of high, medium, low, anecdotal (got %L)', v_confidence));
    END IF;

    IF v_world_slug IS NOT NULL THEN
        SELECT world_id INTO v_world_id FROM stewards.worlds WHERE slug = v_world_slug;
        IF v_world_id IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'error', format('no world with slug "%s"', v_world_slug));
        END IF;
        IF v_entity_name IS NOT NULL THEN
            -- unresolved entity_name inside a KNOWN world is an empty
            -- result, not an error — the model may be probing spelling.
            SELECT entity_id INTO v_entity_id FROM stewards.world_entities
             WHERE world_id = v_world_id AND (name = v_entity_name OR v_entity_name = ANY(aliases))
             LIMIT 1;
        END IF;
    END IF;

    IF jsonb_typeof(p_args->'tags') = 'array' THEN
        SELECT array_agg(btrim(t)) INTO v_tags
          FROM jsonb_array_elements_text(p_args->'tags') AS t
         WHERE btrim(t) <> '';
    END IF;

    IF (p_args ? 'counter_of') AND jsonb_typeof(p_args->'counter_of') <> 'null' THEN
        v_counter_of := (p_args->>'counter_of')::bigint;
    END IF;

    SELECT coalesce(jsonb_agg(s.row_out ORDER BY s.rnk DESC NULLS LAST, s.created_at DESC), '[]'::jsonb)
      INTO v_out
      FROM (
        SELECT
            jsonb_build_object(
                'id', o.id, 'claim', o.claim, 'confidence', o.confidence,
                'fidelity', o.fidelity, 'source_doc_id', o.source_doc_id,
                'source_ref', o.source_ref, 'world_slug', w.slug,
                'entity_name', e.name, 'counter_of', o.counter_of,
                'outcome_ref', o.outcome_ref, 'tags', to_jsonb(o.tags),
                'created_at', o.created_at, 'created_by', o.created_by
            ) AS row_out,
            CASE WHEN v_query IS NOT NULL
                 THEN ts_rank(to_tsvector('english', o.claim), websearch_to_tsquery('english', v_query))
                 ELSE NULL END AS rnk,
            o.created_at
          FROM stewards.observations o
          LEFT JOIN stewards.worlds w ON w.world_id = o.world_id
          LEFT JOIN stewards.world_entities e ON e.entity_id = o.entity_id
         WHERE (v_query IS NULL OR to_tsvector('english', o.claim) @@ websearch_to_tsquery('english', v_query))
           AND (v_confidence IS NULL OR o.confidence = v_confidence)
           AND (v_world_slug IS NULL OR o.world_id = v_world_id)
           AND (v_entity_name IS NULL OR o.entity_id = v_entity_id)
           AND (v_tags IS NULL OR o.tags && v_tags)
           AND (v_counter_of IS NULL OR o.counter_of = v_counter_of)
         ORDER BY rnk DESC NULLS LAST, o.created_at DESC
         LIMIT v_limit
      ) s;

    RETURN jsonb_build_object('ok', true, 'count', jsonb_array_length(v_out), 'results', v_out);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.observation_search(jsonb) IS
'104: FTS (websearch_to_tsquery over claim) + filters (confidence, world_slug, entity_name requires world_slug, tags overlap, counter_of) over stewards.observations. limit default 20, capped 100. Never raises.';

CREATE OR REPLACE FUNCTION stewards.observation_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $FN$
BEGIN
    RETURN stewards.observation_search(p_args);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- =====================================================================
-- §4 — observation_counter: register counter-evidence. A thin,
--   discoverable front door over observation_add that REQUIRES a target
--   (`counters`) and validates it exists before delegating — the whole
--   point is that a model reaching for "this contradicts something" has an
--   obviously-named tool, not an easy-to-miss optional field on the add path.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.observation_counter(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_target bigint;
BEGIN
    IF NOT (p_args ? 'counters') OR jsonb_typeof(p_args->'counters') = 'null' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'counters (the id of the observation this counters) is required');
    END IF;
    v_target := (p_args->>'counters')::bigint;
    IF NOT EXISTS (SELECT 1 FROM stewards.observations WHERE id = v_target) THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no observation with id %s to counter', v_target));
    END IF;
    RETURN stewards.observation_add(p_args || jsonb_build_object('counter_of', v_target));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.observation_counter(jsonb) IS
'104: register counter-evidence. Args: counters (required — the id of the observation being countered) plus every observation_add field (claim, confidence required). Validates the target exists, then delegates to observation_add with counter_of set. Never raises.';

CREATE OR REPLACE FUNCTION stewards.observation_counter_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
BEGIN
    RETURN stewards.observation_counter(p_args);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

-- =====================================================================
-- §5 — tool_defs + tool_groups + grants (research + work-item-chat, per
--   the ratified brief).
-- =====================================================================
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
('observation_add',
 'Record one small, sourced, confidence-labelled claim — the atomic unit of knowledge this substrate reasons over. confidence (required) is whether the CLAIM is reliable: high | medium | low | anecdotal. fidelity (default verbatim) is how lossy the EXTRACTION from its source was: verbatim | paraphrase | inferred — keep these two DISTINCT (a verbatim quote can still be low-confidence; a paraphrase can be high-confidence). Optionally ground the claim in a source_doc_id + source_ref, and/or a world_slug (+ entity_name, resolved by name-or-alias within that world). If this claim CONTRADICTS an existing observation, prefer observation_counter over passing counter_of here directly.',
 '{"type":"object","required":["claim","confidence"],"properties":{'
   '"claim":{"type":"string","description":"the claim itself, one small statement"},'
   '"confidence":{"type":"string","enum":["high","medium","low","anecdotal"],"description":"is the CLAIM reliable"},'
   '"fidelity":{"type":"string","enum":["verbatim","paraphrase","inferred"],"description":"how lossy was the EXTRACTION from its source; defaults to verbatim"},'
   '"source_doc_id":{"type":"string","description":"a stewards.docs id this claim is grounded in"},'
   '"source_ref":{"type":"string","description":"row/timestamp/page WITHIN the source doc"},'
   '"world_slug":{"type":"string","description":"a stewards.worlds slug this observation grounds"},'
   '"entity_name":{"type":"string","description":"an entity name (or alias) within world_slug; requires world_slug"},'
   '"counter_of":{"type":"integer","description":"id of an observation this one counters — prefer the dedicated observation_counter tool instead"},'
   '"outcome_ref":{"type":"string","description":"optional link to a real outcome this claim was later checked against"},'
   '"tags":{"type":"array","items":{"type":"string"}},'
   '"created_by":{"type":"string"}'
 '}}'::jsonb,
 '{"kind":"sql_fn","schema":"stewards","name":"observation_add_tool"}'::jsonb, 'write_local', true),

('observation_search',
 'Search recorded observations: full-text over the claim (query) plus filters for confidence, world_slug (+ entity_name), tags, and counter_of (find the counter-evidence chain for a given observation id). Returns up to `limit` (default 20, max 100) matches, most relevant/most recent first.',
 '{"type":"object","properties":{'
   '"query":{"type":"string","description":"full-text search over claim"},'
   '"confidence":{"type":"string","enum":["high","medium","low","anecdotal"]},'
   '"world_slug":{"type":"string"},'
   '"entity_name":{"type":"string","description":"requires world_slug"},'
   '"tags":{"type":"array","items":{"type":"string"},"description":"matches observations carrying ANY of these tags"},'
   '"counter_of":{"type":"integer","description":"find observations that counter this observation id"},'
   '"limit":{"type":"integer","description":"default 20, max 100"}'
 '}}'::jsonb,
 '{"kind":"sql_fn","schema":"stewards","name":"observation_search_tool"}'::jsonb, 'read', true),

('observation_counter',
 'Register COUNTER-EVIDENCE against an existing observation. counters (required) is the id of the observation being contradicted; every other field is the same as observation_add (claim + confidence required). Counter-evidence is first-class here — the new observation is a normal row, sourced and confidence-labelled like any other, linked back via counter_of.',
 '{"type":"object","required":["counters","claim","confidence"],"properties":{'
   '"counters":{"type":"integer","description":"id of the observation this new one counters"},'
   '"claim":{"type":"string"},'
   '"confidence":{"type":"string","enum":["high","medium","low","anecdotal"]},'
   '"fidelity":{"type":"string","enum":["verbatim","paraphrase","inferred"]},'
   '"source_doc_id":{"type":"string"},'
   '"source_ref":{"type":"string"},'
   '"world_slug":{"type":"string"},'
   '"entity_name":{"type":"string","description":"requires world_slug"},'
   '"outcome_ref":{"type":"string"},'
   '"tags":{"type":"array","items":{"type":"string"}},'
   '"created_by":{"type":"string"}'
 '}}'::jsonb,
 '{"kind":"sql_fn","schema":"stewards","name":"observation_counter_tool"}'::jsonb, 'write_local', true)

ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, effect_class = EXCLUDED.effect_class, active = true;

-- discoverability: bundle the three (37-tool-groups' pattern, mirror of
-- 100-schedule-chat's 'schedule-tools' group).
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('observation-tools', 'record/search sourced, confidence-labelled observations (the atomic unit of knowledge) + register counter-evidence',
     ARRAY['observation_add','observation_search','observation_counter'])
ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description, tool_patterns = EXCLUDED.tool_patterns;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('research',        'observation_add',     'allow', 'manual'),
  ('research',        'observation_search',  'allow', 'manual'),
  ('research',        'observation_counter', 'allow', 'manual'),
  ('work-item-chat',  'observation_add',     'allow', 'manual'),
  ('work-item-chat',  'observation_search',  'allow', 'manual'),
  ('work-item-chat',  'observation_counter', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- =====================================================================
-- End of 104-observations.sql
-- =====================================================================
