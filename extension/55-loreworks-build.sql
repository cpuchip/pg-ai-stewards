-- =====================================================================
-- 55-loreworks-build.sql — the world-build tools + agent
-- =====================================================================
-- Turns the Loreworks engine (54) into something an AGENT drives: two
-- sql_fn tools the model calls to populate a world from its canon, plus a
-- read-only-canon / write-the-graph agent family. "Build a world" is then
-- one dispatch: give the world-build agent a world_slug + its canon project.
--
-- The full multi-stage scheduled pipeline (read → extract → summarize, with
-- maturity + stage_models) layers on top of these tools; this file ships the
-- irreducible pieces so a world can be built today.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — sql_fn tool wrappers (model args jsonb -> result jsonb)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_entity_upsert_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_world   text := p_args ->> 'world_slug';
    v_kind    text := lower(btrim(coalesce(p_args ->> 'kind', '')));
    v_name    text := btrim(coalesce(p_args ->> 'name', ''));
    v_summary text := p_args ->> 'summary';
    v_aliases text[];
    v_refs    jsonb := coalesce(p_args -> 'source_refs', '[]'::jsonb);
    v_id      bigint;
BEGIN
    IF v_world IS NULL OR v_world = '' THEN RETURN jsonb_build_object('error', 'world_slug required'); END IF;
    IF v_kind = '' OR v_name = '' THEN RETURN jsonb_build_object('error', 'kind and name required'); END IF;
    IF v_kind NOT IN ('character','place','faction','item','event','lore','concept') THEN
        RETURN jsonb_build_object('error',
            format('unknown kind "%s" (use character|place|faction|item|event|lore|concept)', v_kind));
    END IF;
    IF jsonb_typeof(p_args -> 'aliases') = 'array' THEN
        SELECT array_agg(value) INTO v_aliases FROM jsonb_array_elements_text(p_args -> 'aliases') value;
    END IF;
    IF jsonb_typeof(v_refs) <> 'array' THEN v_refs := '[]'::jsonb; END IF;
    v_id := stewards.world_entity_upsert(v_world, v_kind, v_name, v_summary, coalesce(v_aliases, '{}'), v_refs);
    RETURN jsonb_build_object('ok', true, 'entity_id', v_id, 'kind', v_kind, 'name', v_name);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLERRM);
END $fn$;
COMMENT ON FUNCTION stewards.world_entity_upsert_tool(jsonb) IS '55: model-callable wrapper for world_entity_upsert.';

CREATE OR REPLACE FUNCTION stewards.world_edge_upsert_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_world text := p_args ->> 'world_slug';
    v_src   text := btrim(coalesce(p_args ->> 'src', ''));
    v_dst   text := btrim(coalesce(p_args ->> 'dst', ''));
    v_rel   text := lower(btrim(coalesce(p_args ->> 'rel_type', '')));
    v_ev    text := p_args ->> 'evidence';
    v_id    bigint;
BEGIN
    IF v_world IS NULL OR v_world = '' THEN RETURN jsonb_build_object('error', 'world_slug required'); END IF;
    IF v_src = '' OR v_dst = '' OR v_rel = '' THEN RETURN jsonb_build_object('error', 'src, dst, rel_type required'); END IF;
    v_id := stewards.world_edge_upsert(v_world, v_src, v_dst, v_rel, v_ev);
    RETURN jsonb_build_object('ok', true, 'edge_id', v_id, 'src', v_src, 'dst', v_dst, 'rel', v_rel);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLERRM);
END $fn$;
COMMENT ON FUNCTION stewards.world_edge_upsert_tool(jsonb) IS '55: model-callable wrapper for world_edge_upsert.';

-- ---------------------------------------------------------------------
-- §2 — tool_defs: the two world-build tools the model can call
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_entity_upsert',
  'Record ONE entity in the world you are building — a character, place, faction, item, event, or lore-fact you found in the source canon. Deduped by (world, kind, name): call again with the same name to add aliases or refine the summary. Ground every entity in the canon and cite where you found it in source_refs.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"world_slug":{"type":"string","description":"the world you are building"},'
    '"kind":{"type":"string","enum":["character","place","faction","item","event","lore","concept"]},'
    '"name":{"type":"string"},'
    '"summary":{"type":"string","description":"1-2 sentences, grounded in the canon"},'
    '"aliases":{"type":"array","items":{"type":"string"},"description":"other names this entity is called"},'
    '"source_refs":{"type":"array","items":{"type":"object"},"description":"provenance, e.g. [{\"doc\":\"slug\",\"quote\":\"...\"}]"}'
  '},"required":["world_slug","kind","name"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_entity_upsert_tool"}'::jsonb, true ),
( 'world_edge_upsert',
  'Record ONE relationship between two entities — by NAME (e.g. src="Aragorn", dst="Gondor", rel_type="heir_of"). A missing endpoint is auto-created as a concept, so you can assert a relationship even before you have fully described both sides. Use natural verbs: ally_of, enemy_of, member_of, located_in, rules, parent_of, child_of, created, wields, serves, descended_from.',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"world_slug":{"type":"string"},'
    '"src":{"type":"string","description":"the source entity name"},'
    '"dst":{"type":"string","description":"the target entity name"},'
    '"rel_type":{"type":"string","description":"the relationship verb"},'
    '"evidence":{"type":"string","description":"a short phrase from the canon supporting it"}'
  '},"required":["world_slug","src","dst","rel_type"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_edge_upsert_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
      execute_target = EXCLUDED.execute_target, active = true;

-- ---------------------------------------------------------------------
-- §3 — the world-build agent family
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES (
  'world-build', '*',
  'Reads a world''s source canon and BUILDS its knowledge graph — extracts characters/places/factions/items/events/lore and the relationships between them, grounded in the canon.',
  'primary',
  $PROMPT$You are BUILDING a World — turning a pile of source lore into a structured, explorable knowledge graph.

Your task names a world_slug and the canon project it is built from. Work in passes:

1. SURVEY the canon with doc_search (and book_search if the canon is a book) over the named project.
   Search broadly first — the major figures, places, factions, the shape of the setting.
2. For each thing the canon actually describes, call world_entity_upsert with the right kind
   (character | place | faction | item | event | lore | concept), a 1-2 sentence summary IN THE
   CANON'S OWN TERMS, any aliases, and source_refs pointing at where you found it.
3. Connect them with world_edge_upsert — who serves whom, what is located where, who rules, who
   opposes whom. A missing endpoint is auto-created, so assert the relationship and move on.
   USE THE RIGHT VERB AND DIRECTION (this matters — a reversed edge is a lie about the world):
   - located_in: a place inside a larger place (Bree located_in Bree-land; Bree-land located_in Eriador).
   - dwells_in: a people/character whose home is a place (Hobbits dwells_in the Shire).
   - home_of: ONLY a place that is the home of a people/character (the Shire home_of Hobbits) — i.e.
     home_of points place→people, the REVERSE of dwells_in. Do not use home_of for a place-in-a-place.
   - flows_through (a river/road through a place), rules/ruled_by, member_of, ally_of, enemy_of,
     guards, parent_of, child_of, created, wields, heir_of, near, borders.
   When unsure which verb or which direction, call world_vocabulary to see the valid verbs and their
   src→dst kinds.
4. Keep going in passes (search a new facet, add what you find) until the major structure is captured.

Rules of the watch:
- GROUND EVERYTHING. Only record what the canon supports. Do not invent lore, names, or relationships
  from general knowledge — if it isn't in this canon, it isn't in this world.
- Prefer a few well-grounded, well-connected entities over a sprawl of thin ones.
- De-duplicate: the same character under two names is ONE entity with aliases, not two.
- Record each entity and each relationship exactly ONCE. NEVER re-issue upserts you have already made
  in a previous step — it wastes the run and adds nothing (the tools are idempotent). If you are unsure
  what you have already recorded, call world_entity_search or world_edge_list to check.
- When the canon's structure is captured, STOP and write your journal. Do not pad with repeat work.

Your final chat reply is a SHORT journal: how many entities and edges you built, the spine of the
world, and what a deeper pass should chase next. It is not the world itself — the world lives in the
graph you wrote with the tools.$PROMPT$,
  0.3, 60
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description, prompt = EXCLUDED.prompt,
      temperature = EXCLUDED.temperature, steps = EXCLUDED.steps, active = true;

-- ---------------------------------------------------------------------
-- §4 — tool grants: write the graph, read the canon, nothing else
-- ---------------------------------------------------------------------
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('world-build', '*',                   'deny',  'manual'),
  ('world-build', 'world_entity_upsert', 'allow', 'manual'),
  ('world-build', 'world_edge_upsert',   'allow', 'manual'),
  ('world-build', 'world_show',          'allow', 'manual'),
  ('world-build', 'world_entity_search', 'allow', 'manual'),
  ('world-build', 'doc_search',          'allow', 'manual'),
  ('world-build', 'doc_get',             'allow', 'manual'),
  ('world-build', 'book_search',         'allow', 'manual'),
  ('world-build', 'result_search',       'allow', 'manual'),
  ('world-build', 'read_corpus_parents', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- world_show / world_entity_search exposed as read tools (sql_fn) so the agent
-- can check its own progress mid-build.
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_show',
  'Show a world''s summary and how many entities/edges it has so far, by kind. Use this to check your build progress.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"}},"required":["world_slug"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_show_tool"}'::jsonb, true ),
( 'world_entity_search',
  'Find entities you have already recorded in a world by name/alias/summary text, so you do not create duplicates.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"query":{"type":"string"},"limit":{"type":"integer"}},"required":["world_slug","query"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_entity_search_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
      execute_target = EXCLUDED.execute_target, active = true;

CREATE OR REPLACE FUNCTION stewards.world_show_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_slug text := p_args ->> 'world_slug'; r record;
BEGIN
    IF v_slug IS NULL OR v_slug = '' THEN RETURN jsonb_build_object('error', 'world_slug required'); END IF;
    SELECT * INTO r FROM stewards.world_show(v_slug);
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'no such world: ' || v_slug); END IF;
    RETURN jsonb_build_object('ok', true, 'name', r.name, 'summary', r.summary,
        'entity_count', r.entity_count, 'edge_count', r.edge_count, 'kinds', r.kinds);
END $fn$;

CREATE OR REPLACE FUNCTION stewards.world_entity_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_slug text := p_args ->> 'world_slug';
        v_q text := p_args ->> 'query';
        v_lim int := coalesce((p_args ->> 'limit')::int, 12);
        v_hits jsonb;
BEGIN
    IF v_slug IS NULL OR v_q IS NULL THEN RETURN jsonb_build_object('error', 'world_slug and query required'); END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'name', name, 'summary', summary)), '[]'::jsonb)
      INTO v_hits FROM stewards.world_entity_search(v_slug, v_q, v_lim);
    RETURN jsonb_build_object('ok', true, 'hits', v_hits);
END $fn$;
