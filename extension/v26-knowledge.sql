-- ===== [was 104-observations.sql] =====
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
-- ===== [was 105-seams.sql] =====
-- =====================================================================
-- 105-seams.sql — the seams report: where two LENSES on the same domain
--   diverge.
-- =====================================================================
-- Two worlds (54-loreworks.sql) built over overlapping territory — a
-- market model and a code model of the same product, or two competing
-- readings of the same corpus — each name entities their own way. Where
-- they name the SAME thing differently (or the same name, differently),
-- that divergence is itself the product: it is where one lens saw
-- something the other missed, or where the two disagree about what a
-- shared thing actually IS.
--
-- v1 is deliberately DETERMINISTIC (the ratified brief's own framing): no
-- embedding distance, no fuzzy match — normalized (lower/trim) exact
-- string equality across each entity's name AND every alias. An entity in
-- world A is "the same" as one in world B iff any of A's name/aliases
-- normalize-equal any of B's name/aliases. Known v1 limitation, named not
-- hidden: if an entity's name/alias set matches MORE THAN ONE entity on
-- the other side (an ambiguous alias overlap), it produces multiple
-- matched pairs rather than erroring — acceptable for a first cut; not
-- expected to bite on the common case of clean per-world entity naming.
--
-- Schema verified live via scripts/db.sh before writing a single join (same
-- discipline 104-observations.sql's header documents):
--   * stewards.worlds.world_id / stewards.world_entities.entity_id are
--     both bigint identity columns (54-loreworks.sql) — p_world_a/
--     p_world_b are SLUGS (text), resolved to world_id server-side, the
--     same surface every world/lore tool in this codebase already uses
--     (54/57/85's world_slug convention, not raw ids).
--   * world_entities carries `aliases text[]` and `kind`/`summary` — the
--     brief's assumed columns are all real.
--   * world_edges is (world_id, src_entity, dst_entity, rel_type,
--     evidence) — directed, typed, no cross-world edges of its own (82's
--     cross_world_edges is a DIFFERENT, separately-modeled seam; this file
--     does not touch it — a within-domain, two-lens comparison is a
--     different question than 82/85's cross-service graph).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — seams_report(world_a, world_b) — typed core. Read-only, STABLE.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.seams_report(p_world_a text, p_world_b text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
    v_a                  bigint;
    v_b                  bigint;
    v_shared             jsonb;
    v_only_a             jsonb;
    v_only_b             jsonb;
    v_edge_disagreements jsonb;
    v_counts             jsonb;
BEGIN
    IF p_world_a IS NULL OR btrim(p_world_a) = '' OR p_world_b IS NULL OR btrim(p_world_b) = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'world_a and world_b are both required');
    END IF;

    SELECT world_id INTO v_a FROM stewards.worlds WHERE slug = p_world_a;
    IF v_a IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no world with slug "%s"', p_world_a));
    END IF;
    SELECT world_id INTO v_b FROM stewards.worlds WHERE slug = p_world_b;
    IF v_b IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'error', format('no world with slug "%s"', p_world_b));
    END IF;
    IF v_a = v_b THEN
        RETURN jsonb_build_object('ok', false, 'error', 'world_a and world_b must be different worlds');
    END IF;

    WITH a_names AS (
        SELECT entity_id, lower(btrim(name)) AS nm
          FROM stewards.world_entities WHERE world_id = v_a AND btrim(name) <> ''
        UNION
        SELECT entity_id, lower(btrim(alias))
          FROM stewards.world_entities, unnest(aliases) AS alias
         WHERE world_id = v_a AND btrim(alias) <> ''
    ),
    b_names AS (
        SELECT entity_id, lower(btrim(name)) AS nm
          FROM stewards.world_entities WHERE world_id = v_b AND btrim(name) <> ''
        UNION
        SELECT entity_id, lower(btrim(alias))
          FROM stewards.world_entities, unnest(aliases) AS alias
         WHERE world_id = v_b AND btrim(alias) <> ''
    ),
    -- distinct (a_entity, b_entity) pairs sharing at least one normalized
    -- name/alias string. This IS the "same entity across both lenses" set.
    matched AS (
        SELECT DISTINCT a.entity_id AS a_id, b.entity_id AS b_id
          FROM a_names a JOIN b_names b ON a.nm = b.nm
    ),
    shared AS (
        SELECT m.a_id, m.b_id, ea.name AS name, ea.kind AS a_kind, ea.summary AS a_summary,
               eb.kind AS b_kind, eb.summary AS b_summary
          FROM matched m
          JOIN stewards.world_entities ea ON ea.entity_id = m.a_id
          JOIN stewards.world_entities eb ON eb.entity_id = m.b_id
    ),
    -- edges between two MATCHED (shared) entities only — a relationship
    -- disagreement is only meaningful when both endpoints exist in both
    -- lenses. a_edges stays in A's own id space; b_edges_in_a_space maps
    -- B's edges into A's id space via `matched` so both sides compare by
    -- the SAME (src, dst, rel_type) tuple shape without a name round-trip.
    a_edges AS (
        SELECT g.src_entity AS src, g.dst_entity AS dst, g.rel_type
          FROM stewards.world_edges g
         WHERE g.world_id = v_a
           AND g.src_entity IN (SELECT a_id FROM matched)
           AND g.dst_entity IN (SELECT a_id FROM matched)
    ),
    b_edges_in_a_space AS (
        SELECT ms.a_id AS src, md.a_id AS dst, g.rel_type
          FROM stewards.world_edges g
          JOIN matched ms ON ms.b_id = g.src_entity
          JOIN matched md ON md.b_id = g.dst_entity
         WHERE g.world_id = v_b
    ),
    missing_in_b AS (           -- A has this edge (between shared entities); B does not
        SELECT src, dst, rel_type FROM a_edges
        EXCEPT
        SELECT src, dst, rel_type FROM b_edges_in_a_space
    ),
    missing_in_a AS (           -- B has this edge (translated); A does not
        SELECT src, dst, rel_type FROM b_edges_in_a_space
        EXCEPT
        SELECT src, dst, rel_type FROM a_edges
    ),
    edge_disagreements AS (
        SELECT src, dst, rel_type, 'a'::text AS present_in FROM missing_in_b
        UNION ALL
        SELECT src, dst, rel_type, 'b'::text AS present_in FROM missing_in_a
    )
    SELECT
        -- (a) shared entities, ALL reported (per the ratified v1 shape),
        -- each carrying a same_kind boolean so the caller sees divergence
        -- without this fn pre-judging which divergences matter.
        (SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'name', s.name,
                   'a', jsonb_build_object('kind', s.a_kind, 'summary', s.a_summary),
                   'b', jsonb_build_object('kind', s.b_kind, 'summary', s.b_summary),
                   'same_kind', (s.a_kind = s.b_kind)
                 ) ORDER BY s.name), '[]'::jsonb)
           FROM shared s),
        -- (b) blind spots: entities with no counterpart at all on the other side.
        (SELECT coalesce(jsonb_agg(DISTINCT e.name ORDER BY e.name), '[]'::jsonb)
           FROM stewards.world_entities e
          WHERE e.world_id = v_a
            AND NOT EXISTS (SELECT 1 FROM matched m WHERE m.a_id = e.entity_id)),
        (SELECT coalesce(jsonb_agg(DISTINCT e.name ORDER BY e.name), '[]'::jsonb)
           FROM stewards.world_entities e
          WHERE e.world_id = v_b
            AND NOT EXISTS (SELECT 1 FROM matched m WHERE m.b_id = e.entity_id)),
        -- (c) relationship disagreements between shared entities, named via A's entities.
        (SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'src', esrc.name, 'dst', edst.name, 'rel_type', ed.rel_type, 'present_in', ed.present_in
                 ) ORDER BY esrc.name, edst.name, ed.rel_type), '[]'::jsonb)
           FROM edge_disagreements ed
           JOIN stewards.world_entities esrc ON esrc.entity_id = ed.src AND esrc.world_id = v_a
           JOIN stewards.world_entities edst ON edst.entity_id = ed.dst AND edst.world_id = v_a)
    INTO v_shared, v_only_a, v_only_b, v_edge_disagreements;

    v_counts := jsonb_build_object(
        'shared_divergent',     jsonb_array_length(v_shared),
        'same_kind_count',      (SELECT count(*) FROM jsonb_array_elements(v_shared) x WHERE (x->>'same_kind')::boolean),
        'divergent_kind_count', (SELECT count(*) FROM jsonb_array_elements(v_shared) x WHERE NOT (x->>'same_kind')::boolean),
        'only_in_a',            jsonb_array_length(v_only_a),
        'only_in_b',            jsonb_array_length(v_only_b),
        'edge_disagreements',   jsonb_array_length(v_edge_disagreements)
    );

    RETURN jsonb_build_object(
        'ok', true,
        'world_a', p_world_a,
        'world_b', p_world_b,
        'shared_divergent', v_shared,
        'only_in_a', v_only_a,
        'only_in_b', v_only_b,
        'edge_disagreements', v_edge_disagreements,
        'counts', v_counts
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$fn$;
COMMENT ON FUNCTION stewards.seams_report(text, text) IS
'105: where two worlds (lenses) on the same territory diverge. shared_divergent = every entity whose name/alias matches across both worlds (normalized lower/trim), each with both sides'' kind+summary and a same_kind boolean; only_in_a/only_in_b = entities with no counterpart on the other side (the blind spots); edge_disagreements = relationships that exist between shared entities in one world but not the other. v1 is deterministic — no embedding distance.';

-- ---------------------------------------------------------------------
-- §2 — the tool wrapper + registration.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.seams_report_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $FN$
BEGIN
    RETURN stewards.seams_report(p_args->>'world_a', p_args->>'world_b');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
('seams_report',
 'Compare two worlds (lenses) built over the same or overlapping territory and report where they diverge: shared_divergent (entities whose name/alias matches across both worlds, each with both sides'' kind + summary and a same_kind flag), only_in_a/only_in_b (entities with no counterpart on the other side — the blind spots), and edge_disagreements (a relationship that exists between shared entities in one world but not the other). Read-only, deterministic (no embedding distance in v1).',
 '{"type":"object","required":["world_a","world_b"],"properties":{'
   '"world_a":{"type":"string","description":"slug of the first world (stewards.worlds.slug)"},'
   '"world_b":{"type":"string","description":"slug of the second world"}'
 '}}'::jsonb,
 '{"kind":"sql_fn","schema":"stewards","name":"seams_report_tool"}'::jsonb, 'read', true)
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, effect_class = EXCLUDED.effect_class, active = true;

-- Grants: the brief named chat explicitly ("so chat agents can call it").
-- Also granted to research + loremaster — both already read full world
-- graphs read-only (57/85's precedent: world_neighbors -> loremaster +
-- work-item-chat) — a read-effect analysis tool over data those two
-- families already see is not a new capability, just the same reach one
-- call further. Named here, not silently done.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'seams_report', 'allow', 'manual'),
  ('research',       'seams_report', 'allow', 'manual'),
  ('loremaster',     'seams_report', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- =====================================================================
-- End of 105-seams.sql
-- =====================================================================
-- ===== [was 106-schedule-visibility.sql] =====
-- =====================================================================
-- 106 — SCHEDULE VISIBILITY: a pause must be loud; staleness must alarm
-- =====================================================================
-- Found 2026-07-07 (feat/lightening, task #336): every scheduled pipeline
-- had been silent for 14 days and BOTH a UI walk and a steward diagnosis
-- read it as a dead scheduler. It wasn't — the LIVE fire() honors the
-- global kill switch (autonomy_paused, 22) and was returning 0 by design.
-- The deliberate pause was indistinguishable from death: no log line, no
-- UI state, /scheduled showing "(due now)" as if firing were imminent.
--
-- Two fixes here, plus one repo-truth repair:
--   §1 re-authors scheduled_pipelines_fire — porting the LIVE body (the
--      kill-switch clause 22 added, which 18's repo copy predates — the
--      port-from-highest-number trap, again) and adding ONE LOG line per
--      paused tick so pg logs always show WHY nothing fires.
--   §2 schedule_staleness_check(): a schedule past due by more than
--      2x its missed window while autonomy is NOT paused = something is
--      genuinely wrong → a deduped hinge_queue row (kind=schedule-stale)
--      surfacing in needs_attention. A dead scheduler can never again be
--      silent: paused → the log + UI banner say so; unpaused-and-stale →
--      the bell rings.
-- The UI half (banner + /scheduled state + GET /api/autonomy) ships in
-- the same branch (cmd/stewards-ui).
-- =====================================================================

-- ── §1 — fire(), re-authored from LIVE + the paused log line ─────────
CREATE OR REPLACE FUNCTION stewards.scheduled_pipelines_fire()
RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_row             stewards.scheduled_pipelines%ROWTYPE;
    v_child_slug      text;
    v_work_item_id    uuid;
    v_now             timestamptz := now();
    v_missed_cutoff   timestamptz;
    v_dispatched      int := 0;
    v_skipped_missed  int := 0;
    v_next_due        timestamptz;
BEGIN
    -- Global kill switch (22): when paused, fire no scheduled pipelines —
    -- but SAY SO, once per tick, so the pause is never mistaken for death.
    IF stewards.config_get_text('autonomy_paused', 'false') = 'true' THEN
        RAISE LOG 'scheduled_pipelines_fire: autonomy_paused=true — % enabled schedule(s) held',
            (SELECT count(*) FROM stewards.scheduled_pipelines WHERE enabled);
        RETURN 0;
    END IF;

    FOR v_row IN
        SELECT *
          FROM stewards.scheduled_pipelines
         WHERE enabled = true
           AND next_due_at IS NOT NULL
           AND next_due_at <= v_now
         ORDER BY next_due_at
         FOR UPDATE SKIP LOCKED
    LOOP
        -- D-PE4 missed-window: advance without dispatch after a long gap
        -- (prevents a thundering backlog after an unpause — deliberate).
        v_missed_cutoff := v_row.next_due_at + (v_row.missed_window_hours || ' hours')::interval;

        IF v_now > v_missed_cutoff THEN
            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET next_due_at = v_next_due, updated_at = v_now
             WHERE id = v_row.id;
            RAISE NOTICE 'scheduled_pipelines_fire: skipping missed run for % (due % older than % hours); advanced to %',
                v_row.slug, v_row.next_due_at, v_row.missed_window_hours, v_next_due;
            v_skipped_missed := v_skipped_missed + 1;
            CONTINUE;
        END IF;

        v_child_slug := v_row.slug || '--' ||
            to_char(v_row.next_due_at AT TIME ZONE 'UTC', 'YYYY-MM-DD-HH24MI');

        BEGIN
            v_work_item_id := stewards.work_item_create(
                p_pipeline_family => v_row.pipeline_family,
                p_input           => v_row.input_template,
                p_slug            => v_child_slug,
                p_actor           => 'scheduler',
                p_token_budget    => NULL,
                p_intent_id       => v_row.intent_id
            );
            PERFORM stewards.work_item_dispatch_stage(v_work_item_id);

            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET last_dispatched_at = v_now,
                   next_due_at        = v_next_due,
                   updated_at         = v_now
             WHERE id = v_row.id;

            RAISE NOTICE 'scheduled_pipelines_fire: dispatched %/% as work_item %; next_due_at=%',
                v_row.slug, v_child_slug, v_work_item_id, v_next_due;
            v_dispatched := v_dispatched + 1;

        EXCEPTION WHEN OTHERS THEN
            -- Per-row isolation (#330 discipline): one broken schedule must
            -- never stall the rest. Advance it and say so loudly.
            v_next_due := stewards.cron_next_after(v_row.cron_pattern, v_now);
            UPDATE stewards.scheduled_pipelines
               SET next_due_at = v_next_due, updated_at = v_now
             WHERE id = v_row.id;
            RAISE WARNING 'scheduled_pipelines_fire: dispatch FAILED for % (%); advanced next_due_at to %',
                v_row.slug, SQLERRM, v_next_due;
        END;
    END LOOP;

    -- Staleness sweep rides the same tick (no new caller to wire). Honest
    -- limitation: if fire() itself is never called (dead leader/watchman),
    -- this alarm dies with it — that failure mode is visible only by the
    -- ABSENCE of these ticks in pg logs; an external monitor is the deeper
    -- fix if it ever bites.
    BEGIN
        PERFORM stewards.schedule_staleness_check();
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'schedule_staleness_check failed: %', SQLERRM;
    END;

    RETURN v_dispatched;
END;
$func$;

COMMENT ON FUNCTION stewards.scheduled_pipelines_fire() IS
'106 re-authors 18/22: cron dispatcher for scheduled_pipelines. Honors the autonomy_paused kill switch LOUDLY (one LOG line per held tick). Per-row exception isolation. Port from HERE (highest number wins).';

-- ── §2 — the staleness alarm ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION stewards.schedule_staleness_check()
RETURNS int
LANGUAGE plpgsql AS $func$
DECLARE
    v_row   record;
    v_count int := 0;
BEGIN
    -- Paused = held on purpose; the banner + log own that story. The alarm
    -- exists for the OTHER case: autonomy is on and a schedule still isn't
    -- firing — a genuine fault (locked rows, broken cron_next_after, a
    -- wedged leader) that yesterday's machinery let sit silent for 14 days.
    IF stewards.config_get_text('autonomy_paused', 'false') = 'true' THEN
        RETURN 0;
    END IF;

    FOR v_row IN
        SELECT sp.slug, sp.next_due_at, sp.missed_window_hours
          FROM stewards.scheduled_pipelines sp
         WHERE sp.enabled
           AND sp.next_due_at IS NOT NULL
           AND sp.next_due_at < now() - (GREATEST(sp.missed_window_hours, 1) * 2 || ' hours')::interval
           -- dedup: one open alarm per schedule at a time
           AND NOT EXISTS (
               SELECT 1 FROM stewards.hinge_reviews h
                WHERE h.kind = 'schedule-stale'
                  AND h.subject = sp.slug
                  AND h.status = 'pending')
    LOOP
        PERFORM stewards.hinge_enqueue(
            'schedule-stale',
            v_row.slug,
            jsonb_build_object(
                'next_due_at', v_row.next_due_at,
                'overdue_hours', round(extract(epoch FROM (now() - v_row.next_due_at))/3600),
                'note', 'schedule is past due by more than 2x its missed window while autonomy is ON — the scheduler may be faulted'),
            'schedule_staleness_check');
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$func$;

COMMENT ON FUNCTION stewards.schedule_staleness_check() IS
'106: rings the hinge bell (kind=schedule-stale, deduped per slug) when an enabled schedule sits past due by >2x its missed window with autonomy ON. Paused holds are the banner''s job; this alarm is for genuine scheduler faults, which were silent for 14 days before it existed.';

-- =====================================================================
-- End of 106-schedule-visibility.sql
-- =====================================================================
