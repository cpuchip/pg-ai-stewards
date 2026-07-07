-- ===== [was 54-loreworks.sql] =====
-- =====================================================================
-- 54-loreworks.sql — the Loreworks engine: build a World from source lore
-- =====================================================================
-- A World is a named canon (a source corpus) plus an extracted
-- entity/relationship knowledge graph. The CANON lives in the existing
-- docs/pools (project-tagged, hybrid-searchable via embed_query). This file
-- adds the entity + graph layer and the functions a world-build pipeline calls.
--
-- Generic OSS core: no game/world content here — only the machinery. Private
-- worlds (e.g. purchased TTRPG lore) set is_private and stay local.
--
-- Graph is RELATIONAL (the AGE-replacement decision): world_edges is a typed
-- adjacency table, indexed both directions, no graph extension.
-- =====================================================================

-- ---------------------------------------------------------------------
-- worlds — a named canon built from source lore
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.worlds (
    world_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug        text UNIQUE NOT NULL,
    name        text NOT NULL,
    summary     text,
    project     text,                              -- canon corpus project tag (e.g. 'ttrpg-the-one-ring')
    is_private  boolean NOT NULL DEFAULT false,    -- file_private-class: local-only, never to a train-on-data provider
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.worlds IS
  'A World: a named canon (source corpus = project) + an extracted entity/edge knowledge graph.';

-- ---------------------------------------------------------------------
-- world_entities — characters / places / factions / items / events / lore
-- extracted from the canon
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.world_entities (
    entity_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    world_id    bigint NOT NULL REFERENCES stewards.worlds(world_id) ON DELETE CASCADE,
    kind        text NOT NULL,                     -- character|place|faction|item|event|lore|concept
    name        text NOT NULL,
    aliases     text[] NOT NULL DEFAULT '{}',
    summary     text,
    source_refs jsonb NOT NULL DEFAULT '[]'::jsonb, -- [{doc, chunk, quote}] provenance into the canon
    embedding   vector(768),                       -- nomic; populated for semantic entity search (optional)
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (world_id, kind, name)
);
CREATE INDEX IF NOT EXISTS world_entities_world_idx ON stewards.world_entities(world_id);
CREATE INDEX IF NOT EXISTS world_entities_kind_idx  ON stewards.world_entities(world_id, kind);
COMMENT ON TABLE stewards.world_entities IS
  'Entities extracted from a World''s canon, deduped on (world, kind, name); source_refs cite the canon.';

-- ---------------------------------------------------------------------
-- world_edges — typed relationships (the relational knowledge graph)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.world_edges (
    edge_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    world_id    bigint NOT NULL REFERENCES stewards.worlds(world_id) ON DELETE CASCADE,
    src_entity  bigint NOT NULL REFERENCES stewards.world_entities(entity_id) ON DELETE CASCADE,
    dst_entity  bigint NOT NULL REFERENCES stewards.world_entities(entity_id) ON DELETE CASCADE,
    rel_type    text NOT NULL,                     -- e.g. ally_of|member_of|located_in|parent_of|rules|created
    evidence    text,
    metadata    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (world_id, src_entity, dst_entity, rel_type)
);
CREATE INDEX IF NOT EXISTS world_edges_world_idx ON stewards.world_edges(world_id);
CREATE INDEX IF NOT EXISTS world_edges_src_idx   ON stewards.world_edges(src_entity);
CREATE INDEX IF NOT EXISTS world_edges_dst_idx   ON stewards.world_edges(dst_entity);
COMMENT ON TABLE stewards.world_edges IS
  'Typed directed relationships between world_entities — the relational lore graph (no AGE).';

-- ---------------------------------------------------------------------
-- world_upsert — register / update a World
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_upsert(
    p_slug text,
    p_name text,
    p_summary text DEFAULT NULL,
    p_project text DEFAULT NULL,
    p_is_private boolean DEFAULT false
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
    INSERT INTO stewards.worlds (slug, name, summary, project, is_private)
    VALUES (p_slug, p_name, p_summary, p_project, p_is_private)
    ON CONFLICT (slug) DO UPDATE
        SET name = EXCLUDED.name,
            summary = COALESCE(EXCLUDED.summary, stewards.worlds.summary),
            project = COALESCE(EXCLUDED.project, stewards.worlds.project),
            is_private = EXCLUDED.is_private,
            updated_at = now()
    RETURNING world_id INTO v_id;
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- world_entity_upsert — assert one entity (deduped, merges aliases + refs)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_entity_upsert(
    p_world_slug text,
    p_kind text,
    p_name text,
    p_summary text DEFAULT NULL,
    p_aliases text[] DEFAULT '{}',
    p_source_refs jsonb DEFAULT '[]'::jsonb
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_world bigint; v_id bigint;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN
        RAISE EXCEPTION 'world_entity_upsert: unknown world slug %', p_world_slug;
    END IF;
    INSERT INTO stewards.world_entities (world_id, kind, name, summary, aliases, source_refs)
    VALUES (v_world, p_kind, p_name, p_summary, COALESCE(p_aliases, '{}'), COALESCE(p_source_refs, '[]'::jsonb))
    ON CONFLICT (world_id, kind, name) DO UPDATE
        SET summary = COALESCE(EXCLUDED.summary, stewards.world_entities.summary),
            -- union aliases, dedup
            aliases = ARRAY(SELECT DISTINCT unnest(stewards.world_entities.aliases || EXCLUDED.aliases)),
            -- append new source_refs
            source_refs = stewards.world_entities.source_refs || EXCLUDED.source_refs
    RETURNING entity_id INTO v_id;
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- world_edge_upsert — assert one typed relationship by entity NAME.
-- Auto-creates a missing endpoint as kind='concept' so a digester can
-- assert edges without pre-declaring every entity.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_edge_upsert(
    p_world_slug text,
    p_src_name text,
    p_dst_name text,
    p_rel_type text,
    p_evidence text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE v_world bigint; v_src bigint; v_dst bigint; v_id bigint;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN
        RAISE EXCEPTION 'world_edge_upsert: unknown world slug %', p_world_slug;
    END IF;
    -- resolve (or create) both endpoints within this world; match name OR alias
    SELECT entity_id INTO v_src FROM stewards.world_entities
        WHERE world_id = v_world AND (name = p_src_name OR p_src_name = ANY(aliases)) LIMIT 1;
    IF v_src IS NULL THEN
        v_src := stewards.world_entity_upsert(p_world_slug, 'concept', p_src_name);
    END IF;
    SELECT entity_id INTO v_dst FROM stewards.world_entities
        WHERE world_id = v_world AND (name = p_dst_name OR p_dst_name = ANY(aliases)) LIMIT 1;
    IF v_dst IS NULL THEN
        v_dst := stewards.world_entity_upsert(p_world_slug, 'concept', p_dst_name);
    END IF;
    INSERT INTO stewards.world_edges (world_id, src_entity, dst_entity, rel_type, evidence)
    VALUES (v_world, v_src, v_dst, p_rel_type, p_evidence)
    ON CONFLICT (world_id, src_entity, dst_entity, rel_type) DO UPDATE
        SET evidence = COALESCE(EXCLUDED.evidence, stewards.world_edges.evidence)
    RETURNING edge_id INTO v_id;
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- world_show — a World's summary + counts (for the cockpit + world chat)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_show(p_slug text)
RETURNS TABLE (slug text, name text, summary text, project text, is_private boolean,
               entity_count bigint, edge_count bigint, kinds jsonb)
LANGUAGE sql STABLE AS $$
    SELECT w.slug, w.name, w.summary, w.project, w.is_private,
           (SELECT count(*) FROM stewards.world_entities e WHERE e.world_id = w.world_id),
           (SELECT count(*) FROM stewards.world_edges    g WHERE g.world_id = w.world_id),
           COALESCE((SELECT jsonb_object_agg(kind, n) FROM (
               SELECT kind, count(*) n FROM stewards.world_entities e
               WHERE e.world_id = w.world_id GROUP BY kind) k), '{}'::jsonb)
    FROM stewards.worlds w WHERE w.slug = p_slug;
$$;

-- ---------------------------------------------------------------------
-- world_graph — the entity/edge graph as JSON, for the 3D viz
--   { nodes: [{id, kind, name, summary}], links: [{source, target, rel}] }
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_graph(p_slug text)
RETURNS jsonb
LANGUAGE sql STABLE AS $$
    WITH w AS (SELECT world_id FROM stewards.worlds WHERE slug = p_slug)
    SELECT jsonb_build_object(
        'nodes', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                    'id', e.entity_id, 'kind', e.kind, 'name', e.name, 'summary', e.summary))
                  FROM stewards.world_entities e WHERE e.world_id = (SELECT world_id FROM w)), '[]'::jsonb),
        'links', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                    'source', g.src_entity, 'target', g.dst_entity, 'rel', g.rel_type))
                  FROM stewards.world_edges g WHERE g.world_id = (SELECT world_id FROM w)), '[]'::jsonb)
    );
$$;

-- ---------------------------------------------------------------------
-- world_entity_search — lexical entity locator within a World (name /
-- alias / summary). The hybrid (semantic) leg is added in C, where
-- embed_query supplies the vec rank over world_entities.embedding.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_entity_search(
    p_world_slug text,
    p_query text,
    p_limit int DEFAULT 12
) RETURNS TABLE (entity_id bigint, kind text, name text, summary text, score real)
LANGUAGE sql STABLE AS $$
    WITH w AS (SELECT world_id FROM stewards.worlds WHERE slug = p_world_slug)
    SELECT e.entity_id, e.kind, e.name, e.summary,
           (CASE WHEN lower(e.name) = lower(p_query) THEN 1.0
                 WHEN p_query = ANY(e.aliases) THEN 0.9
                 WHEN e.name ILIKE '%'||p_query||'%' THEN 0.6
                 WHEN e.summary ILIKE '%'||p_query||'%' THEN 0.3
                 ELSE 0.1 END)::real AS score
    FROM stewards.world_entities e
    WHERE e.world_id = (SELECT world_id FROM w)
      AND (e.name ILIKE '%'||p_query||'%'
           OR e.summary ILIKE '%'||p_query||'%'
           OR p_query = ANY(e.aliases))
    ORDER BY score DESC, e.name
    LIMIT GREATEST(p_limit, 1);
$$;
-- ===== [was 55-loreworks-build.sql] =====
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

Your task names a world_slug and the canon it is built from. Work in passes:

0. LOAD THE CANON IF ASKED. If your task says to import an attachment (gives an attachment_id and a
   project name), call doc_import_corpus(attachment_id, corpus_name, project) EXACTLY ONCE first —
   that extracts + chunks the uploaded source into the searchable project. Wait for it to finish, then
   build from that project. If the task instead names an existing project or pastes the canon inline,
   skip this step.
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
  ('world-build', 'doc_import_corpus',   'allow', 'manual'),  -- load an uploaded source into its project, then build
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
-- ===== [was 56-trajectory-critic.sql] =====
-- =====================================================================
-- 56-trajectory-critic.sql — Glass-Box trajectory evaluation + the
-- Loreworks edge-grounding critic
-- =====================================================================
-- Google's SDLC papers split agent eval into OUTPUT ("Black Box") vs
-- TRAJECTORY ("Glass Box" — every step: tool choice, params, error-state
-- recognition, redundant loops, grounding, role adherence). The substrate
-- already CAPTURES the full trajectory (messages.tool_calls + tool results);
-- it lacked a judge OVER it. This adds:
--   (1) assemble_trajectory(session) — the trajectory as compact jsonb
--   (2) a generic 'trajectory-critic' judge + critique_trajectory()
--   (3) the Loreworks application — a 'world-critic' that grounds a world's
--       edges against its canon and PRUNES misreads (the B edge-quality fix).
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — assemble_trajectory: a run's steps as compact jsonb (Glass Box)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.assemble_trajectory(p_session_id text)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH steps AS (
    SELECT m.id, m.role, m.finish_reason,
           left(coalesce(m.content, ''), 600) AS content,
           CASE WHEN jsonb_typeof(m.tool_calls) = 'array' THEN (
             SELECT jsonb_agg(jsonb_build_object(
                      'tool', tc->'function'->>'name',
                      'args', left(coalesce(tc->'function'->>'arguments',''), 400)))
             FROM jsonb_array_elements(m.tool_calls) tc
           ) ELSE NULL END AS calls
    FROM stewards.messages m
    WHERE m.session_id = p_session_id
    ORDER BY m.id
  )
  SELECT jsonb_build_object(
    'session_id', p_session_id,
    'message_count', (SELECT count(*) FROM steps),
    'tool_call_count', (SELECT coalesce(sum(jsonb_array_length(coalesce(calls, '[]'::jsonb))), 0) FROM steps),
    'steps', coalesce((SELECT jsonb_agg(jsonb_build_object(
        'id', id, 'role', role, 'finish', finish_reason,
        'content', content, 'tool_calls', calls) ORDER BY id) FROM steps), '[]'::jsonb)
  );
$$;
COMMENT ON FUNCTION stewards.assemble_trajectory(text) IS
  '56: a run''s ordered steps (tool choices, args, results, final reply) as compact jsonb — the Glass-Box surface.';

-- ---------------------------------------------------------------------
-- §2 — the generic Glass-Box trajectory critic (judge) + dispatcher
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, response_format, steps)
VALUES (
  'trajectory-critic', '*',
  'Glass-Box evaluator: scores an agent run''s TRAJECTORY (the process, not just the final output) against a quality rubric.',
  'primary',
  $P$You are a Glass-Box trajectory evaluator (from Google's agent-quality framework). You are given the full TRAJECTORY of ONE agent run — its ordered steps: the tools it chose, the arguments it passed, the results or errors it got back, and its final reply. Judge the PROCESS, not just the output.

A fluent final answer that skipped its verification steps is a MORE dangerous failure than one with a visible error. Score what actually happened.

Score each 0.0–1.0:
- tool_selection — did it choose the right tools for the task?
- param_correctness — were the tool arguments well-formed and appropriate?
- error_handling — did it RECOGNIZE error / empty results (an {"error":...}, a 404, "no rows") and adapt, rather than proceed as if they succeeded?
- efficiency — did it avoid redundant calls, loops, and wasted steps?
- grounding — are its outputs supported by what it actually retrieved or was given (no fabrication)?
- role_adherence — did it stay within its role and tool grants?

Return ONLY this JSON (no prose):
{"scores":{"tool_selection":0.0,"param_correctness":0.0,"error_handling":0.0,"efficiency":0.0,"grounding":0.0,"role_adherence":0.0},"issues":["short, specific"],"verdict":"pass|warn|fail","summary":"one line"}$P$,
  0.2, '{"type":"json_object"}'::jsonb, 1
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description, prompt = EXCLUDED.prompt,
      response_format = EXCLUDED.response_format, steps = EXCLUDED.steps, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('trajectory-critic', '*', 'deny', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- Assemble a run's trajectory and dispatch the critic over it; the verdict
-- (json) lands as the critic's reply in the returned critic session.
CREATE OR REPLACE FUNCTION stewards.critique_trajectory(p_session_id text, p_critic_session text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE v_traj jsonb; v_sess text; v_id bigint;
BEGIN
    v_traj := stewards.assemble_trajectory(p_session_id);
    v_sess := coalesce(p_critic_session, 'trajcritic--' || p_session_id);
    v_id := stewards.dispatch_chat_turn(
        v_sess,
        'Evaluate the trajectory of this agent run and return the rubric JSON:' || E'\n\n' || jsonb_pretty(v_traj),
        'trajectory-critic');
    RETURN v_id;
END $$;

-- ---------------------------------------------------------------------
-- §3 — Loreworks edge-grounding: list + prune tools
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_edge_list_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_slug text := p_args ->> 'world_slug'; v_world bigint; v_edges jsonb;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = v_slug;
    IF v_world IS NULL THEN RETURN jsonb_build_object('error', 'unknown world: ' || coalesce(v_slug, '')); END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
              'edge_id', e.edge_id, 'src', s.name, 'rel', e.rel_type, 'dst', d.name, 'evidence', e.evidence)
            ORDER BY e.edge_id), '[]'::jsonb)
      INTO v_edges
      FROM stewards.world_edges e
      JOIN stewards.world_entities s ON s.entity_id = e.src_entity
      JOIN stewards.world_entities d ON d.entity_id = e.dst_entity
     WHERE e.world_id = v_world;
    RETURN jsonb_build_object('ok', true, 'count', jsonb_array_length(v_edges), 'edges', v_edges);
END $fn$;

CREATE OR REPLACE FUNCTION stewards.world_edge_prune(p_world_slug text, p_edge_ids bigint[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_world bigint; v_n int;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN RAISE EXCEPTION 'world_edge_prune: unknown world %', p_world_slug; END IF;
    DELETE FROM stewards.world_edges WHERE world_id = v_world AND edge_id = ANY(p_edge_ids);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

CREATE OR REPLACE FUNCTION stewards.world_edge_prune_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_slug text := p_args ->> 'world_slug'; v_ids bigint[]; v_n int;
BEGIN
    IF v_slug IS NULL OR v_slug = '' THEN RETURN jsonb_build_object('error', 'world_slug required'); END IF;
    IF jsonb_typeof(p_args -> 'edge_ids') = 'array' THEN
        SELECT array_agg(value::bigint) INTO v_ids FROM jsonb_array_elements_text(p_args -> 'edge_ids') value;
    END IF;
    IF v_ids IS NULL OR array_length(v_ids, 1) IS NULL THEN
        RETURN jsonb_build_object('error', 'edge_ids (array of edge_id) required');
    END IF;
    v_n := stewards.world_edge_prune(v_slug, v_ids);
    RETURN jsonb_build_object('ok', true, 'pruned', v_n);
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', SQLERRM);
END $fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_edge_list',
  'List the relationships you have recorded in a world, each with its edge_id, so you can review them for grounding. Returns [{edge_id, src, rel, dst, evidence}].',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"}},"required":["world_slug"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_edge_list_tool"}'::jsonb, true ),
( 'world_edge_prune',
  'Delete edges that are NOT grounded in the canon — misreads, backwards directions, or invented relationships. Pass the edge_ids to remove. Use this after reviewing world_edge_list against the source text.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"edge_ids":{"type":"array","items":{"type":"integer"}}},"required":["world_slug","edge_ids"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_edge_prune_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
      execute_target = EXCLUDED.execute_target, active = true;

-- ---------------------------------------------------------------------
-- §4 — the world-critic: grounds a world's edges against its canon
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES (
  'world-critic', '*',
  'Grounds a built world''s relationships against its source canon — prunes misreads, backwards directions, and invented edges (the Glass-Box critic applied to world-build).',
  'primary',
  $P$You are the grounding critic for a built World. The world-build agent extracted entities and relationships from a source canon; your job is to catch where it got the RELATIONSHIPS wrong.

Your task names the world_slug. The canon (or how to find it via doc_search) is given to you.

1. Call world_edge_list to see every relationship with its edge_id, source, verb, target, and evidence.
2. For each edge, ask: is this relationship actually SUPPORTED by the canon, and is its DIRECTION right?
   Common errors to catch:
   - misreads — e.g. "Dwarves home_of Shire" when the text only said dwarven traders PASS THROUGH the Shire;
   - backwards direction — e.g. a person "ruled_by" a town (a place does not rule a person);
   - invented edges with no support in the canon.
   Verb directions you should expect: located_in (a place is inside a larger place), home_of (a place is the home of a people/character — so src=place, dst=people is acceptable; flag the inverse only if clearly wrong), flows_through (a river through a region), ruled_by (a place/people ruled by a ruler), near/borders (two places), member_of, ally_of, enemy_of, wields, created, parent_of.
3. Collect the edge_ids that are ungrounded or wrong and remove them in ONE world_edge_prune call. Keep the well-grounded ones.

Be conservative: prune only edges you are confident are wrong or unsupported. Your final reply is a one-line journal: how many edges you reviewed, how many you pruned, and why.$P$,
  0.2, 40
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description, prompt = EXCLUDED.prompt,
      temperature = EXCLUDED.temperature, steps = EXCLUDED.steps, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('world-critic', '*',                   'deny',  'manual'),
  ('world-critic', 'world_edge_list',     'allow', 'manual'),
  ('world-critic', 'world_edge_prune',    'allow', 'manual'),
  ('world-critic', 'world_show',          'allow', 'manual'),
  ('world-critic', 'world_entity_search', 'allow', 'manual'),
  ('world-critic', 'doc_search',          'allow', 'manual'),
  ('world-critic', 'doc_get',             'allow', 'manual'),
  ('world-critic', 'book_search',         'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;
-- ===== [was 57-loreworks-chat.sql] =====
-- =====================================================================
-- 57-loreworks-chat.sql — Loreworks C/G: hybrid lore search + the
-- LOREMASTER (chat with a world) + lore auto-injection for world rooms
-- =====================================================================
-- The 54 engine left world_entities.embedding waiting and the comment
-- promised the semantic leg "in C". This file delivers it: a fused
-- lexical+semantic entity search (the embed_query vector leg), the read-only
-- LOREMASTER agent + its lore tools, and lore_inject for grounding a persona
-- in a world room (G). The canon lives in the docs pool; this is the graph leg.
--
-- Embeddings use the configured embed provider/model (stewards.config
-- 'embed_provider'/'embed_model'); on a deployment with no embed provider the
-- semantic leg is simply empty and search degrades to the lexical leg.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — populate world_entities.embedding (name + summary) via embed_query
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_entity_embed(p_world_slug text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_world bigint; v_provider text; v_model text; v_n int := 0; r record;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN RAISE EXCEPTION 'world_entity_embed: unknown world %', p_world_slug; END IF;
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    FOR r IN SELECT entity_id, name, coalesce(summary,'') AS summary
               FROM stewards.world_entities
              WHERE world_id = v_world AND embedding IS NULL LOOP
        BEGIN
            UPDATE stewards.world_entities
               SET embedding = stewards.embed_query(r.name || '. ' || r.summary, v_provider, v_model, 768)::vector(768)
             WHERE entity_id = r.entity_id;
            v_n := v_n + 1;
        EXCEPTION WHEN OTHERS THEN
            -- a down embed server / no provider: leave NULL, keep going
            EXIT;
        END;
    END LOOP;
    RETURN v_n;
END $$;
COMMENT ON FUNCTION stewards.world_entity_embed(text) IS
  '57: backfill world_entities.embedding (name+summary) for a world via embed_query; the semantic leg of hybrid lore search.';

CREATE OR REPLACE FUNCTION stewards.world_entity_embed_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_slug text := p_args ->> 'world_slug'; v_n int;
BEGIN
    IF v_slug IS NULL OR v_slug = '' THEN RETURN jsonb_build_object('error','world_slug required'); END IF;
    v_n := stewards.world_entity_embed(v_slug);
    RETURN jsonb_build_object('ok', true, 'embedded', v_n);
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', SQLERRM);
END $fn$;

-- ---------------------------------------------------------------------
-- §2 — world_entity_hybrid: fused lexical + semantic entity search
--   lexical leg = world_entity_search (name/alias/summary ILIKE)
--   semantic leg = cosine over the populated embeddings (one embed round-trip)
-- The semantic leg fires when the word was never typed; the lexical leg
-- keeps exact-name precision. NULL-embedding entities just don't appear in sem.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_entity_hybrid(
    p_world_slug text, p_query text, p_limit int DEFAULT 12)
RETURNS TABLE (entity_id bigint, kind text, name text, summary text, score real)
LANGUAGE plpgsql STABLE AS $$
DECLARE v_world bigint; v_provider text; v_model text; v_vec vector(768);
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN RETURN; END IF;
    v_provider := stewards.config_get_text('embed_provider', NULL);
    v_model    := stewards.config_get_text('embed_model', NULL);
    BEGIN
        v_vec := stewards.embed_query(p_query, v_provider, v_model, 768)::vector(768);
    EXCEPTION WHEN OTHERS THEN
        v_vec := NULL;   -- no embed provider / down: lexical-only
    END;

    RETURN QUERY
    WITH lex AS (
        SELECT s.entity_id, s.score AS lex
          FROM stewards.world_entity_search(p_world_slug, p_query, p_limit * 3) s
    ),
    sem AS (
        SELECT e.entity_id, (1 - (e.embedding <=> v_vec))::real AS sem
          FROM stewards.world_entities e
         WHERE e.world_id = v_world AND v_vec IS NOT NULL AND e.embedding IS NOT NULL
         ORDER BY e.embedding <=> v_vec
         LIMIT p_limit * 3
    ),
    fused AS (
        SELECT coalesce(lex.entity_id, sem.entity_id) AS eid,
               (0.45 * coalesce(lex.lex, 0) + 0.55 * coalesce(sem.sem, 0))::real AS score
          FROM lex FULL JOIN sem ON lex.entity_id = sem.entity_id
    )
    SELECT e.entity_id, e.kind, e.name, e.summary, f.score
      FROM fused f JOIN stewards.world_entities e ON e.entity_id = f.eid
     ORDER BY f.score DESC, e.name
     LIMIT GREATEST(p_limit, 1);
END $$;
COMMENT ON FUNCTION stewards.world_entity_hybrid(text,text,int) IS
  '57: fused lexical(world_entity_search) + semantic(embed_query cosine) entity search — the meaning leg the 54 comment promised.';

-- ---------------------------------------------------------------------
-- §3 — the LOREMASTER tools (read-only, grounded, cite)
-- ---------------------------------------------------------------------
-- lore_search: hybrid entity search with source_refs (cite the canon)
CREATE OR REPLACE FUNCTION stewards.lore_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_slug text := p_args->>'world_slug'; v_q text := p_args->>'query';
        v_lim int := coalesce((p_args->>'limit')::int, 10); v_hits jsonb;
BEGIN
    IF v_slug IS NULL OR v_q IS NULL THEN RETURN jsonb_build_object('error','world_slug and query required'); END IF;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
              'kind', h.kind, 'name', h.name, 'summary', h.summary,
              'source_refs', (SELECT e.source_refs FROM stewards.world_entities e WHERE e.entity_id=h.entity_id))
            ORDER BY h.score DESC), '[]'::jsonb)
      INTO v_hits
      FROM stewards.world_entity_hybrid(v_slug, v_q, v_lim) h;
    RETURN jsonb_build_object('ok', true, 'hits', v_hits);
END $fn$;

-- lore_entity: one entity + its 1-hop neighborhood (the graph walk text RAG can't do)
CREATE OR REPLACE FUNCTION stewards.lore_entity_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_slug text := p_args->>'world_slug'; v_name text := p_args->>'name';
        v_world bigint; v_eid bigint; v_ent jsonb; v_edges jsonb;
BEGIN
    IF v_slug IS NULL OR v_name IS NULL THEN RETURN jsonb_build_object('error','world_slug and name required'); END IF;
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug=v_slug;
    IF v_world IS NULL THEN RETURN jsonb_build_object('error','unknown world'); END IF;
    SELECT entity_id INTO v_eid FROM stewards.world_entities
     WHERE world_id=v_world AND (name=v_name OR v_name=ANY(aliases)) LIMIT 1;
    IF v_eid IS NULL THEN RETURN jsonb_build_object('ok',true,'found',false,'name',v_name); END IF;
    SELECT jsonb_build_object('kind',kind,'name',name,'aliases',aliases,'summary',summary,'source_refs',source_refs)
      INTO v_ent FROM stewards.world_entities WHERE entity_id=v_eid;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
              'rel', g.rel_type, 'dir', CASE WHEN g.src_entity=v_eid THEN 'out' ELSE 'in' END,
              'other', o.name, 'evidence', g.evidence)), '[]'::jsonb)
      INTO v_edges FROM stewards.world_edges g
      JOIN stewards.world_entities o ON o.entity_id = CASE WHEN g.src_entity=v_eid THEN g.dst_entity ELSE g.src_entity END
     WHERE g.src_entity=v_eid OR g.dst_entity=v_eid;
    RETURN jsonb_build_object('ok',true,'found',true,'entity',v_ent,'connections',v_edges);
END $fn$;

-- lore_neighbors: BFS to depth<=2 over the relational graph ("who serves the king?")
CREATE OR REPLACE FUNCTION stewards.lore_neighbors_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_slug text := p_args->>'world_slug'; v_name text := p_args->>'name';
        v_depth int := least(coalesce((p_args->>'depth')::int,2),2);
        v_world bigint; v_eid bigint; v_out jsonb;
BEGIN
    IF v_slug IS NULL OR v_name IS NULL THEN RETURN jsonb_build_object('error','world_slug and name required'); END IF;
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug=v_slug;
    SELECT entity_id INTO v_eid FROM stewards.world_entities
     WHERE world_id=v_world AND (name=v_name OR v_name=ANY(aliases)) LIMIT 1;
    IF v_eid IS NULL THEN RETURN jsonb_build_object('ok',true,'found',false); END IF;
    WITH RECURSIVE walk(eid, depth, path) AS (
        SELECT v_eid, 0, ARRAY[v_eid]
        UNION ALL
        SELECT CASE WHEN g.src_entity=w.eid THEN g.dst_entity ELSE g.src_entity END, w.depth+1,
               w.path || CASE WHEN g.src_entity=w.eid THEN g.dst_entity ELSE g.src_entity END
          FROM walk w
          JOIN stewards.world_edges g ON (g.src_entity=w.eid OR g.dst_entity=w.eid) AND g.world_id=v_world
         WHERE w.depth < v_depth
           AND NOT (CASE WHEN g.src_entity=w.eid THEN g.dst_entity ELSE g.src_entity END = ANY(w.path))
    )
    SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object('name',e.name,'kind',e.kind,'depth',w.depth)), '[]'::jsonb)
      INTO v_out FROM walk w JOIN stewards.world_entities e ON e.entity_id=w.eid WHERE w.depth>0;
    RETURN jsonb_build_object('ok',true,'found',true,'of',v_name,'neighbors',v_out);
END $fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'lore_search',
  'Search a world''s entities by MEANING (not just exact words) — returns matching characters/places/factions/items with their summary and source_refs so you can cite the canon. Use this first to find what the question is about.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"query":{"type":"string"},"limit":{"type":"integer"}},"required":["world_slug","query"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"lore_search_tool"}'::jsonb, true ),
( 'lore_entity',
  'Read ONE entity in full — its summary, aliases, source_refs, AND its connections (who/what it relates to, with the relationship verb and direction). Use this to answer "tell me about X" and "what is X connected to".',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"name":{"type":"string"}},"required":["world_slug","name"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"lore_entity_tool"}'::jsonb, true ),
( 'lore_neighbors',
  'Walk the relationship graph from an entity (up to 2 hops) — for "who serves the king?", "who else is in the Fellowship?", relationship questions text search can''t answer.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"name":{"type":"string"},"depth":{"type":"integer"}},"required":["world_slug","name"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"lore_neighbors_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE
  SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
      execute_target=EXCLUDED.execute_target, active=true;

-- ---------------------------------------------------------------------
-- §4 — the LOREMASTER agent (read-only, hybrid-search, cite)
-- ---------------------------------------------------------------------
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES (
  'loremaster', '*',
  'Read-only guide to ONE world''s canon — answers grounded in the world''s entity graph + source passages, never from training memory.',
  'primary',
  $PROMPT$You are the LOREMASTER of one world. You answer questions about its canon, and ONLY from what you retrieve — never from training memory, never from general knowledge about similar-sounding worlds.

Your task names the world_slug. To answer:
- lore_search (world_slug, query) — find the entities a question is about. It searches by MEANING, so the right thing surfaces even when the asker doesn't use its exact name. Each hit carries source_refs.
- lore_entity (world_slug, name) — read one entity in full and see what it's connected to (the relationship verbs + directions).
- lore_neighbors (world_slug, name) — walk relationships for "who serves X / who else is in Y".
- doc_get / book_search — pull the actual source passage behind a source_ref when you want to quote it.

Ground every claim in what you retrieved. Cite the entity by name and, when you quote, the source. If the canon is silent on something, say so plainly — do not invent lore, names, or relationships. You are read-only: you describe the world, you never change it. Be concise and answer the question asked.$PROMPT$,
  0.3, 14
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description=EXCLUDED.description, prompt=EXCLUDED.prompt,
      temperature=EXCLUDED.temperature, steps=EXCLUDED.steps, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('loremaster', '*',                   'deny',  'manual'),
  ('loremaster', 'lore_search',         'allow', 'manual'),
  ('loremaster', 'lore_entity',         'allow', 'manual'),
  ('loremaster', 'lore_neighbors',      'allow', 'manual'),
  ('loremaster', 'world_show',          'allow', 'manual'),
  ('loremaster', 'doc_search',          'allow', 'manual'),
  ('loremaster', 'doc_get',             'allow', 'manual'),
  ('loremaster', 'book_search',         'allow', 'manual'),
  ('loremaster', 'read_corpus_parents', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- world-build also gets the embed tool so a fresh build populates embeddings.
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_entity_embed',
  'Embed this world''s entities (name + summary) so they become semantically searchable. Call once after you have recorded the entities.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"}},"required":["world_slug"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_entity_embed_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE
  SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
      execute_target=EXCLUDED.execute_target, active=true;
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('world-build', 'world_entity_embed', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- ---------------------------------------------------------------------
-- §5 — lore_inject (G): a pre-formatted lore block for a world room turn.
-- Called by the persona-host (not the model) to ground a persona each turn.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.lore_inject(p_world_slug text, p_scan_text text, p_limit int DEFAULT 6)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE v_name text; v_block text; r record;
BEGIN
    SELECT name INTO v_name FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_name IS NULL THEN RETURN ''; END IF;
    v_block := 'RELEVANT WORLD LORE (from the canon of ' || v_name || '):' || E'\n';
    FOR r IN SELECT h.name, h.kind, h.summary FROM stewards.world_entity_hybrid(p_world_slug, p_scan_text, p_limit) h LOOP
        v_block := v_block || '- ' || r.name || ' (' || r.kind || '): ' || coalesce(r.summary,'') || E'\n';
    END LOOP;
    v_block := v_block || '(Treat this as established truth about the world. Do not contradict it. If asked about something not here, say you do not know rather than invent.)';
    RETURN v_block;
END $$;
COMMENT ON FUNCTION stewards.lore_inject(text,text,int) IS
  '57 (G): a deterministic, model-free lore block (hybrid-retrieved) for the persona-host to splice into a world-room turn — zero extra model calls per turn.';
-- ===== [was 58-world-edge-audit.sql] =====
-- =====================================================================
-- 58-world-edge-audit.sql — the deterministic floor under the world-critic
-- =====================================================================
-- The world-critic (56) is an LLM grounding pass; it was conservative on a
-- large edge set and missed some structural misreads. This adds the
-- build-the-oracle-first floor: a lore relation vocabulary with kind-typed
-- endpoints, and a SQL audit that flags — with perfect recall, no model —
-- the checkable errors: unknown verb, endpoint-kind violations (the
-- "Dwarves home_of Shire" case), and missing evidence. The critic calls it
-- FIRST, so the LLM is reserved for "does the canon actually support this."
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — world_rel_kinds: the lore verb vocabulary (kind-typed, with inverses)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.world_rel_kinds (
    rel_type    text PRIMARY KEY CHECK (rel_type = lower(rel_type)),
    rel_group   text NOT NULL CHECK (rel_group IN ('spatial','social','kinship','possession','origin','agency')),
    gloss       text NOT NULL,                  -- how to read src --rel--> dst
    src_kinds   text[] NOT NULL DEFAULT '{}',   -- valid src entity kinds ('{}' = any)
    dst_kinds   text[] NOT NULL DEFAULT '{}',   -- valid dst entity kinds ('{}' = any)
    inverse     text,                           -- the verb of the reverse reading
    created_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.world_rel_kinds IS
  '58: lore relation vocabulary — verbs with kind-typed endpoints + inverses, so a misread direction (Dwarves home_of Shire) is structurally detectable.';

INSERT INTO stewards.world_rel_kinds (rel_type, rel_group, gloss, src_kinds, dst_kinds, inverse) VALUES
  ('located_in',     'spatial',   'src is physically located within dst',          '{}',                       '{place}',                    'contains'),
  ('contains',       'spatial',   'src physically contains dst',                   '{place}',                  '{}',                         'located_in'),
  ('home_of',        'spatial',   'dst is the home/dwelling place of src',         '{place}',                  '{character,faction}',        'dwells_in'),
  ('dwells_in',      'spatial',   'src makes their home in dst',                   '{character,faction}',      '{place}',                    'home_of'),
  ('travels_through','spatial',   'src passes through dst (does NOT live there)',  '{character,faction}',      '{place}',                    'traversed_by'),
  ('flows_through',  'spatial',   'a river/road src runs through dst',             '{place,item}',             '{place}',                    NULL),
  ('near',           'spatial',   'src is near dst',                               '{place}',                  '{place}',                    'near'),
  ('borders',        'spatial',   'src shares a border with dst',                  '{place}',                  '{place}',                    'borders'),
  ('member_of',      'social',    'src belongs to faction dst',                    '{character}',              '{faction}',                  'has_member'),
  ('ally_of',        'social',    'src is allied with dst',                        '{}',                       '{}',                         'ally_of'),
  ('enemy_of',       'social',    'src opposes dst',                               '{}',                       '{}',                         'enemy_of'),
  ('serves',         'social',    'src is in service to dst',                      '{character,faction}',      '{character,faction}',        'served_by'),
  ('rules',          'agency',    'src holds authority over dst',                  '{character,faction}',      '{place,faction}',            'ruled_by'),
  ('ruled_by',       'agency',    'src is ruled by dst',                           '{place,faction}',          '{character,faction}',        'rules'),
  ('leads',          'agency',    'src leads dst',                                 '{character}',              '{faction}',                  'led_by'),
  ('guards',         'agency',    'src guards/defends dst',                        '{character,faction}',      '{place,item}',               'guarded_by'),
  ('parent_of',      'kinship',   'src is the parent of dst',                      '{character}',              '{character}',                'child_of'),
  ('child_of',       'kinship',   'src is the child of dst',                       '{character}',              '{character}',                'parent_of'),
  ('descended_from', 'kinship',   'src descends from dst',                         '{character,faction}',      '{character,faction}',        'ancestor_of'),
  ('created',        'origin',    'src made/founded dst',                          '{character,faction}',      '{item,place,faction}',       'created_by'),
  ('wields',         'possession','src bears/uses item dst',                       '{character}',              '{item}',                     'wielded_by'),
  ('heir_of',        'kinship',   'src is the rightful heir to dst',               '{character}',              '{place,faction,character}',  'has_heir')
ON CONFLICT (rel_type) DO UPDATE SET rel_group=EXCLUDED.rel_group, gloss=EXCLUDED.gloss,
  src_kinds=EXCLUDED.src_kinds, dst_kinds=EXCLUDED.dst_kinds, inverse=EXCLUDED.inverse;

CREATE OR REPLACE FUNCTION stewards.world_vocabulary_tool(p_args jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'rel_type', rel_type, 'group', rel_group, 'gloss', gloss,
        'src_kinds', src_kinds, 'dst_kinds', dst_kinds, 'inverse', inverse
    ) ORDER BY rel_group, rel_type), '[]'::jsonb) FROM stewards.world_rel_kinds;
$fn$;

-- ---------------------------------------------------------------------
-- §2 — world_edge_audit: the deterministic structural detector
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.world_edge_audit(p_world_slug text)
RETURNS jsonb LANGUAGE sql STABLE AS $fn$
    WITH w AS (SELECT world_id FROM stewards.worlds WHERE slug = p_world_slug),
    e AS (
      SELECT g.edge_id, g.rel_type, g.evidence,
             se.name AS src_name, se.kind AS src_kind,
             de.name AS dst_name, de.kind AS dst_kind,
             rk.rel_type IS NOT NULL AS verb_known,
             rk.src_kinds, rk.dst_kinds, rk.inverse
        FROM stewards.world_edges g
        JOIN stewards.world_entities se ON se.entity_id = g.src_entity
        JOIN stewards.world_entities de ON de.entity_id = g.dst_entity
        LEFT JOIN stewards.world_rel_kinds rk ON rk.rel_type = g.rel_type
       WHERE g.world_id = (SELECT world_id FROM w)
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
        'edge_id',  edge_id,
        'reading',  src_name || ' --' || rel_type || '--> ' || dst_name,
        'inverse_hint', CASE WHEN inverse IS NOT NULL THEN dst_name||' --'||inverse||'--> '||src_name ELSE NULL END,
        'evidence', evidence,
        'flags', (
          ARRAY[]::text[]
          || CASE WHEN NOT verb_known THEN ARRAY['unknown_verb'] ELSE '{}' END
          || CASE WHEN verb_known AND array_length(src_kinds,1) IS NOT NULL
                       AND NOT (src_kind = ANY(src_kinds))
                  THEN ARRAY['src_kind_violation'] ELSE '{}' END
          || CASE WHEN verb_known AND array_length(dst_kinds,1) IS NOT NULL
                       AND NOT (dst_kind = ANY(dst_kinds))
                  THEN ARRAY['dst_kind_violation'] ELSE '{}' END
          || CASE WHEN coalesce(btrim(evidence),'')='' THEN ARRAY['no_evidence'] ELSE '{}' END
        )
    ) ORDER BY edge_id) FILTER (WHERE
        NOT verb_known
        OR (array_length(src_kinds,1) IS NOT NULL AND NOT (src_kind = ANY(src_kinds)))
        OR (array_length(dst_kinds,1) IS NOT NULL AND NOT (dst_kind = ANY(dst_kinds)))
        OR coalesce(btrim(evidence),'')=''
    ), '[]'::jsonb)
    FROM e;
$fn$;
COMMENT ON FUNCTION stewards.world_edge_audit(text) IS
  '58: deterministic structural audit of a world''s edges — flags unknown verbs, endpoint-kind violations (the reversed/misread-direction catch), and missing evidence. Perfect recall, no model. Returns only flagged edges.';

CREATE OR REPLACE FUNCTION stewards.world_edge_audit_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_slug text := p_args ->> 'world_slug'; v_flagged jsonb;
BEGIN
    IF v_slug IS NULL OR v_slug='' THEN RETURN jsonb_build_object('error','world_slug required'); END IF;
    v_flagged := stewards.world_edge_audit(v_slug);
    RETURN jsonb_build_object('ok', true, 'flagged_count', jsonb_array_length(v_flagged), 'flagged', v_flagged);
END $fn$;

-- ---------------------------------------------------------------------
-- §3 — tool_defs + grant the audit + vocabulary to the world-critic
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_edge_audit',
  'Run the deterministic structural audit FIRST. Returns only the edges with flags: unknown_verb (verb not in the lore vocabulary), src_kind_violation / dst_kind_violation (the verb does not fit these entity kinds — e.g. "Dwarves home_of Shire": home_of expects a PLACE as source, so this is the classic reversed/misread edge), no_evidence. Each flagged edge includes an inverse_hint showing the reversed reading. The flags tell you WHERE to look; the canon decides.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"}},"required":["world_slug"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_edge_audit_tool"}'::jsonb, true ),
( 'world_vocabulary',
  'List the valid lore relation verbs with their direction semantics (src/dst entity kinds) and inverses. Use this to pick the right verb when correcting an edge, or to understand a kind-violation flag.',
  '{"type":"object","additionalProperties":false,"properties":{}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_vocabulary_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE
  SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
      execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('world-critic', 'world_edge_audit', 'allow', 'manual'),
  ('world-critic', 'world_vocabulary', 'allow', 'manual'),
  -- world-build reads the vocabulary at build time so it picks the right verb/direction
  ('world-build',  'world_vocabulary', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- Re-author the world-critic prompt to lead with the deterministic audit.
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES (
  'world-critic', '*',
  'Grounds a built world''s relationships against its source canon — leads with the deterministic world_edge_audit, then checks flagged edges against the canon and PRUNES misreads/backwards/invented edges.',
  'primary',
  $P$You are the grounding critic for a built World. The world-build agent turned a source canon into an entity/relationship graph. Some edges are right; some are misreadings. Keep the graph honest.

Your task names the world_slug. The canon (or how to find it via doc_search) is given to you.

1. Call world_edge_audit FIRST. It deterministically returns the edges with structural flags:
   - unknown_verb — the verb is not in the lore vocabulary (call world_vocabulary to see valid verbs + directions).
   - src_kind_violation / dst_kind_violation — the verb does not fit these entity kinds. THIS IS THE CLASSIC MISREAD: "Dwarves home_of Shire" trips src_kind_violation because home_of expects a PLACE as source. Each flagged edge includes an inverse_hint showing the reversed reading.
   - no_evidence — asserted with no supporting quote.
   These flags tell you WHERE to look. They are not verdicts — the canon is.
2. Also scan a sample of UNFLAGGED edges (the audit only catches structural errors, not every semantic misread).
3. For each suspect edge, check it against the canon: does the text actually support THIS relationship, in THIS direction? If the canon says the Dwarves PASS THROUGH the Shire, "home_of" is wrong. If you cannot find canon support, the edge is ungrounded.
4. Collect the edge_ids that are ungrounded, backwards, or use a clearly wrong verb, and remove them in ONE world_edge_prune call. Keep the well-grounded ones. Be conservative — prune only what you are confident is wrong.

Your final reply is a one-line journal: edges audited, flagged, pruned, and the single most important misreading you caught.$P$,
  0.2, 50
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description=EXCLUDED.description, prompt=EXCLUDED.prompt,
      temperature=EXCLUDED.temperature, steps=EXCLUDED.steps, active=true;
-- ===== [was 59-self-improvement.sql] =====
-- =====================================================================
-- 59-self-improvement.sql — the substrate improves its own agents (gated)
-- =====================================================================
-- The trajectory critic (56) finds bad work. This closes the loop: recurring
-- failures → a SCOPED prompt-clause proposal → a DETERMINISTIC GATE → in-bounds
-- auto-apply (trailed + reversible), out-of-bounds escalate to the human →
-- the critic re-scores. dominion_in_council, ratified 2026-06-25.
--
-- SAFETY INVARIANT (the eval-gaming guard): the system may NEVER auto-modify
-- what GRADES or GATES it — any judge (response_format set), any critic, the
-- stewards/Hinge, or the improver itself. Those are escalate-to-human only.
-- Auto-applied clauses are ADDITIVE GUIDANCE only — never permission, constraint,
-- or guard changes (regex-blocked). The gate is re-checked at apply time.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — store the critic's verdicts (harvested from the trajectory-critic)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.trajectory_verdicts (
    id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    target_session text NOT NULL,           -- the run that was judged
    agent_family   text,                    -- the family that ran it
    scores         jsonb,
    issues         jsonb,
    verdict        text,                     -- the critic's verdict word
    created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS trajectory_verdicts_family_idx
    ON stewards.trajectory_verdicts(agent_family, created_at DESC);

-- harvest: when a trajectory-critic chat completes, parse its JSON verdict.
-- critique_trajectory (56) uses session 'trajcritic--<target>'.
CREATE OR REPLACE FUNCTION stewards.harvest_trajectory_verdict() RETURNS trigger
LANGUAGE plpgsql AS $fn$
DECLARE v_content text; v_json jsonb; v_target text; v_family text;
BEGIN
    IF NEW.status='done' AND OLD.status<>'done' AND NEW.kind='chat'
       AND NEW.payload->>'agent_family'='trajectory-critic' THEN
        v_target := regexp_replace(NEW.payload->>'session_id', '^trajcrit(ic)?--', '');
        SELECT content INTO v_content FROM stewards.messages
         WHERE session_id = NEW.payload->>'session_id' AND role='assistant'
           AND coalesce(content,'')<>'' ORDER BY id DESC LIMIT 1;
        BEGIN v_json := v_content::jsonb; EXCEPTION WHEN others THEN v_json := NULL; END;
        IF v_json IS NOT NULL THEN
            SELECT payload->>'agent_family' INTO v_family FROM stewards.work_queue
             WHERE payload->>'session_id'=v_target AND kind='chat' ORDER BY id LIMIT 1;
            INSERT INTO stewards.trajectory_verdicts(target_session, agent_family, scores, issues, verdict)
            VALUES (v_target, v_family, v_json->'scores', v_json->'issues', v_json->>'verdict');
        END IF;
    END IF;
    RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS work_queue_harvest_trajectory ON stewards.work_queue;
CREATE TRIGGER work_queue_harvest_trajectory
    AFTER UPDATE OF status ON stewards.work_queue
    FOR EACH ROW EXECUTE FUNCTION stewards.harvest_trajectory_verdict();

-- ---------------------------------------------------------------------
-- §2 — the proposal ledger (trail + rollback)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS stewards.prompt_improvements (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_family    text NOT NULL,
    clause          text NOT NULL,
    rationale       text,
    source_verdicts bigint[] NOT NULL DEFAULT '{}',
    status          text NOT NULL DEFAULT 'proposed',  -- proposed|approved|applied|escalated|reverted|rejected
    gate_reason     text,
    prior_prompt    text,                               -- for rollback
    created_at      timestamptz NOT NULL DEFAULT now(),
    applied_at      timestamptz
);
CREATE INDEX IF NOT EXISTS prompt_improvements_status_idx
    ON stewards.prompt_improvements(status, created_at DESC);

-- ---------------------------------------------------------------------
-- §3 — THE GATE (the deterministic safety floor)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.prompt_improvement_gate(p_family text, p_clause text)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE v_agent stewards.agents%ROWTYPE; v_cap int := 600;
BEGIN
    SELECT * INTO v_agent FROM stewards.agents WHERE family = p_family AND active LIMIT 1;
    IF v_agent.family IS NULL THEN
        RETURN jsonb_build_object('disposition','escalate','reason','unknown agent family: '||coalesce(p_family,'(null)'));
    END IF;
    -- (1) EVAL-GAMING GUARD: never auto-modify what grades or gates the system.
    IF v_agent.response_format IS NOT NULL THEN
        RETURN jsonb_build_object('disposition','escalate','reason','target is a JUDGE (response_format set) — grading agents are escalate-only');
    END IF;
    IF p_family = ANY (ARRAY[
        'trajectory-critic','world-critic','agent-improver','prompt-critic','judge-brief',
        'compactor','engram-extractor','watchman-consolidator','reflect-steward','hinge','steward']) THEN
        RETURN jsonb_build_object('disposition','escalate','reason','target is a critic / gate / steward — escalate-only (gate integrity)');
    END IF;
    -- (2) base-prompt / self-edit-capable agents escalate
    IF coalesce(v_agent.allow_self_base_prompt, false) THEN
        RETURN jsonb_build_object('disposition','escalate','reason','target is self-base-prompt-capable — escalate-only');
    END IF;
    -- (3) the clause must be SHORT, ADDITIVE GUIDANCE — not a constraint/permission/guard change
    IF char_length(coalesce(p_clause,'')) = 0 THEN
        RETURN jsonb_build_object('disposition','escalate','reason','empty clause');
    END IF;
    IF char_length(p_clause) > v_cap THEN
        RETURN jsonb_build_object('disposition','escalate','reason',format('clause too long (%s > %s chars) — large changes escalate', char_length(p_clause), v_cap));
    END IF;
    -- Red-flag WORDS (Postgres word boundary is \y, NOT \b — \b is backspace):
    IF p_clause ~* '\y(ignore|disregard|override|bypass|jailbreak|unrestricted|allow|deny|grant|permission|autonomy)\y'
       -- Red-flag PHRASES (grounding/verification bypass, permission/capability, self/base/destructive):
       OR p_clause ~* '(tool_perm|any tool|all tools|self.?prompt|base prompt|system prompt|spend.?cap|delete from|drop table|truncate table|do not (verify|check|cite|ground|stop|validate|refuse)|skip (the )?(verification|check|grounding|validation)|always (allow|approve|say|pass)|without (limit|restriction|approval|verif|check|grounding)|use your (own )?(memory|training|knowledge)|from (your )?(memory|training)|trust your (memory|judgment|training)|grounding rules)' THEN
        RETURN jsonb_build_object('disposition','escalate','reason','clause contains permission/constraint/guard/grounding-bypass/destructive language — escalate (auto-apply is additive guidance only)');
    END IF;
    RETURN jsonb_build_object('disposition','auto_apply','reason','scoped additive guidance to a worker agent (within bounds)');
END $$;
COMMENT ON FUNCTION stewards.prompt_improvement_gate(text,text) IS
  '59: the deterministic safety floor for self-improvement. auto_apply ONLY a short additive-guidance clause to a non-judge/non-critic/non-gate worker agent; everything else escalates. The eval-gaming guard.';

-- ---------------------------------------------------------------------
-- §4 — apply (trailed) + revert (rollback)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.apply_prompt_improvement(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_imp_rec stewards.prompt_improvements%ROWTYPE;
BEGIN
    SELECT * INTO v_imp_rec FROM stewards.prompt_improvements WHERE id = p_id;
    IF v_imp_rec.id IS NULL THEN RETURN jsonb_build_object('error','no such improvement '||p_id); END IF;
    -- DEFENSE IN DEPTH: re-run the gate at apply time; refuse if not in-bounds.
    IF (stewards.prompt_improvement_gate(v_imp_rec.agent_family, v_imp_rec.clause)->>'disposition') <> 'auto_apply' THEN
        UPDATE stewards.prompt_improvements SET status='escalated',
            gate_reason='apply-time gate refused (out-of-bounds)' WHERE id=p_id;
        RETURN jsonb_build_object('error','apply refused: out-of-bounds at apply time','id',p_id);
    END IF;
    UPDATE stewards.agents
       SET prompt = prompt || E'\n\n[auto-improved '||to_char(now(),'YYYY-MM-DD')||', from trajectory critique]: '||v_imp_rec.clause
     WHERE family = v_imp_rec.agent_family AND active;
    UPDATE stewards.prompt_improvements SET status='applied', applied_at=now() WHERE id=p_id;
    RETURN jsonb_build_object('ok',true,'id',p_id,'agent_family',v_imp_rec.agent_family,'applied',true);
END $$;

CREATE OR REPLACE FUNCTION stewards.revert_prompt_improvement(p_id bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_imp_rec stewards.prompt_improvements%ROWTYPE;
BEGIN
    SELECT * INTO v_imp_rec FROM stewards.prompt_improvements WHERE id = p_id;
    IF v_imp_rec.id IS NULL OR v_imp_rec.prior_prompt IS NULL THEN
        RETURN jsonb_build_object('error','no such improvement or no prior prompt to restore');
    END IF;
    UPDATE stewards.agents SET prompt = v_imp_rec.prior_prompt
     WHERE family = v_imp_rec.agent_family AND active;
    UPDATE stewards.prompt_improvements SET status='reverted' WHERE id=p_id;
    RETURN jsonb_build_object('ok',true,'id',p_id,'reverted',true);
END $$;

-- ---------------------------------------------------------------------
-- §5 — propose: gate, then auto-apply or escalate
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.propose_prompt_improvement(
    p_family text, p_clause text, p_rationale text DEFAULT NULL, p_source_verdicts bigint[] DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE v_gate jsonb; v_disp text; v_id bigint; v_prior text; v_applied jsonb;
BEGIN
    v_gate := stewards.prompt_improvement_gate(p_family, p_clause);
    v_disp := v_gate->>'disposition';
    SELECT prompt INTO v_prior FROM stewards.agents WHERE family=p_family AND active LIMIT 1;
    INSERT INTO stewards.prompt_improvements(agent_family, clause, rationale, source_verdicts, status, gate_reason, prior_prompt)
    VALUES (p_family, p_clause, p_rationale, coalesce(p_source_verdicts,'{}'),
            CASE WHEN v_disp='auto_apply' THEN 'approved' ELSE 'escalated' END,
            v_gate->>'reason', v_prior)
    RETURNING id INTO v_id;
    IF v_disp = 'auto_apply' THEN
        v_applied := stewards.apply_prompt_improvement(v_id);
        RETURN jsonb_build_object('ok',true,'id',v_id,'disposition','auto_apply',
            'applied',(v_applied->>'ok')='true','reason',v_gate->>'reason');
    END IF;
    RETURN jsonb_build_object('ok',true,'id',v_id,'disposition','escalate','applied',false,
        'reason',v_gate->>'reason','note','escalated to the human — review stewards.prompt_improvements WHERE status=''escalated''');
END $$;

-- model-callable wrapper (the agent-improver calls this)
CREATE OR REPLACE FUNCTION stewards.propose_prompt_improvement_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_family text := p_args->>'agent_family'; v_clause text := p_args->>'clause';
        v_rat text := p_args->>'rationale'; v_vs bigint[];
BEGIN
    IF v_family IS NULL OR v_clause IS NULL THEN RETURN jsonb_build_object('error','agent_family and clause required'); END IF;
    IF jsonb_typeof(p_args->'source_verdicts')='array' THEN
        SELECT array_agg(value::bigint) INTO v_vs FROM jsonb_array_elements_text(p_args->'source_verdicts') value;
    END IF;
    RETURN stewards.propose_prompt_improvement(v_family, v_clause, v_rat, coalesce(v_vs,'{}'));
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('error', SQLERRM);
END $fn$;

-- ---------------------------------------------------------------------
-- §6 — agent_failure_patterns: recurring, thresholded failures
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.agent_failure_patterns(p_min_count int DEFAULT 3, p_window interval DEFAULT '14 days')
RETURNS TABLE (agent_family text, bad_runs bigint, verdicts jsonb, sample_issues jsonb, sample_verdict_ids bigint[])
LANGUAGE sql STABLE AS $$
    SELECT v.agent_family,
           count(*) AS bad_runs,
           jsonb_object_agg(v.verdict, 1) FILTER (WHERE v.verdict IS NOT NULL) AS verdicts,
           to_jsonb((array_agg(v.issues ORDER BY v.created_at DESC))[1:3]) AS sample_issues,
           (array_agg(v.id ORDER BY v.created_at DESC))[1:10] AS sample_verdict_ids
      FROM stewards.trajectory_verdicts v
     WHERE v.agent_family IS NOT NULL
       AND v.created_at > now() - p_window
       AND v.verdict IN ('flawed','unsound','fail','warn')
     GROUP BY v.agent_family
    HAVING count(*) >= p_min_count;
$$;

-- ---------------------------------------------------------------------
-- §7 — the agent-improver (proposes ONE scoped clause per pattern)
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'propose_prompt_improvement',
  'Propose ONE short, additive guidance clause to append to an agent''s prompt, to fix a recurring failure the trajectory critic found. It is GATED: a scoped guidance clause to a worker agent auto-applies; anything touching a judge/critic/gate, a base prompt, a permission/constraint, or anything long, escalates to the human. Pass agent_family, the clause (additive guidance only), a rationale, and the source_verdicts that justify it.',
  '{"type":"object","additionalProperties":false,"properties":{"agent_family":{"type":"string"},"clause":{"type":"string"},"rationale":{"type":"string"},"source_verdicts":{"type":"array","items":{"type":"integer"}}},"required":["agent_family","clause","rationale"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"propose_prompt_improvement_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
  execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature, steps)
VALUES (
  'agent-improver', '*',
  'Reads a recurring failure pattern (from trajectory critiques) for ONE agent family and proposes a single scoped, additive guidance clause to fix it — gated, never freeform.',
  'primary',
  $P$You improve the substrate's own agents. You are given a recurring FAILURE PATTERN for one agent family: how many bad runs, the critic's verdicts, and sample issues. Propose ONE fix.

Your fix is a SINGLE short clause of ADDITIVE GUIDANCE to append to that agent's prompt — a concrete instruction that would prevent the recurring failure. For example, if the critic keeps flagging "re-emitted the whole batch", the clause is "Record each item once; never re-issue calls you have already made." If it keeps flagging "proceeded past a tool error", the clause is "If a tool returns an error, stop and adjust — do not continue as if it succeeded."

Rules:
- Propose ONE clause, grounded in the SPECIFIC failures you were shown. Cite the source_verdicts.
- ADDITIVE GUIDANCE ONLY. Never propose to remove a constraint, change a permission, weaken a check, or touch a base/system prompt — the gate will reject those and they only waste the proposal.
- Keep it short and concrete (one or two sentences).
- Call propose_prompt_improvement once with {agent_family, clause, rationale, source_verdicts}. It tells you whether it auto-applied (in-bounds) or escalated to the human (out-of-bounds).
- Your final reply is a one-line note: what you proposed and whether it applied or escalated.$P$,
  0.3, 6
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description=EXCLUDED.description, prompt=EXCLUDED.prompt, temperature=EXCLUDED.temperature,
      steps=EXCLUDED.steps, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('agent-improver', '*',                          'deny',  'manual'),
  ('agent-improver', 'propose_prompt_improvement', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- ---------------------------------------------------------------------
-- §8 — the tick: critique recent runs, then improve recurring patterns
-- ---------------------------------------------------------------------
-- Dispatches the agent-improver for each actionable failure pattern. Gated by
-- the global autonomy pause (reuses reflect_status' autonomy_paused).
CREATE OR REPLACE FUNCTION stewards.self_improve_tick(p_min_count int DEFAULT 3)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r record; v_dispatched int := 0; v_paused boolean;
BEGIN
    SELECT coalesce((stewards.config_get_text('autonomy_paused','false'))::boolean, false) INTO v_paused;
    IF v_paused THEN RETURN jsonb_build_object('ok',true,'paused',true,'dispatched',0); END IF;
    FOR r IN SELECT * FROM stewards.agent_failure_patterns(p_min_count) LOOP
        -- skip families the gate would always escalate (don't waste improver runs)
        CONTINUE WHEN (stewards.prompt_improvement_gate(r.agent_family, 'probe additive guidance')->>'disposition') <> 'auto_apply';
        -- skip if a recent open proposal already targets this family
        CONTINUE WHEN EXISTS (SELECT 1 FROM stewards.prompt_improvements
                               WHERE agent_family=r.agent_family AND status IN ('proposed','approved','applied')
                                 AND created_at > now() - interval '7 days');
        PERFORM stewards.dispatch_chat_turn(
            'agent-improve--'||r.agent_family||'--'||to_char(now(),'YYYYMMDDHH24MI'),
            'Recurring failure pattern for agent family "'||r.agent_family||'": '||r.bad_runs||' bad runs. '||
            'Verdicts: '||coalesce(r.verdicts::text,'{}')||'. Sample issues: '||coalesce(r.sample_issues::text,'[]')||'. '||
            'Source verdict ids: '||coalesce(r.sample_verdict_ids::text,'{}')||'. Propose one scoped additive guidance clause to fix it.',
            'agent-improver');
        v_dispatched := v_dispatched + 1;
    END LOOP;
    RETURN jsonb_build_object('ok',true,'paused',false,'dispatched',v_dispatched);
END $$;
COMMENT ON FUNCTION stewards.self_improve_tick(int) IS
  '59: the self-improvement tick — for each recurring failure pattern, dispatch the agent-improver to propose a gated fix. Honors autonomy_paused; skips always-escalate families and recently-proposed ones.';
-- ===== [was 60-chat-model-pin.sql] =====
-- =====================================================================
-- 60-chat-model-pin.sql — let a Stewdio chat turn pin an EXPLICIT
-- (provider, model) instead of resolving a role alias.
-- =====================================================================
-- Stewdio's chat normally dispatches via dispatch_chat_turn, which resolves a
-- role ALIAS ('reason' → the operator's local rig) to (provider, model). That's
-- right for the default, but the UX asks for "let a stronger model take over":
-- the user picks a specific model (often a cloud one) for a retry/escalation.
--
-- dispatch_chat_turn can't express that — it only takes an alias, and a bare
-- model id falls back to catalog_default_provider() (the WRONG provider for,
-- say, a Gemini model). chat_enqueue already takes (model, provider) explicitly;
-- this is the thin entrypoint that reuses it, mirroring dispatch_chat_turn's
-- session-ensure + first-turn grounding so a pinned turn behaves identically
-- except for the model that answers.
--
-- TEXT turns only (the escalation case). A media turn keeps using
-- dispatch_chat_turn (vision auto-select) — pinning a vision model is a future
-- need, not this one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.dispatch_chat_pinned(
    p_session_id   text,
    p_user_input   text,
    p_agent_family text,
    p_model        text,
    p_provider     text,
    p_grounding    text DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql AS $FN$
DECLARE
    v_have int;
BEGIN
    IF p_model IS NULL OR btrim(p_model) = '' OR p_provider IS NULL OR btrim(p_provider) = '' THEN
        RAISE EXCEPTION 'dispatch_chat_pinned requires explicit model + provider (got model=%, provider=%)',
            p_model, p_provider;
    END IF;

    -- ensure the persistent chat session exists (kind='chat') — same as dispatch_chat_turn.
    INSERT INTO stewards.sessions (id, label, kind)
    VALUES (p_session_id, 'stewdio chat ' || left(p_session_id, 40), 'chat')
    ON CONFLICT (id) DO NOTHING;

    -- first-turn grounding (only when the session is empty), same shape as dispatch_chat_turn.
    SELECT count(*) INTO v_have FROM stewards.messages WHERE session_id = p_session_id;
    IF v_have = 0 AND p_grounding IS NOT NULL AND length(btrim(p_grounding)) > 0 THEN
        INSERT INTO stewards.messages (session_id, role, content)
        VALUES (p_session_id, 'user', p_grounding);
    END IF;

    -- append the user turn + enqueue against the EXPLICIT (provider, model).
    RETURN stewards.chat_enqueue(p_agent_family, p_model, p_session_id, p_user_input, p_provider);
END
$FN$;

COMMENT ON FUNCTION stewards.dispatch_chat_pinned(text, text, text, text, text, text) IS
'60: enqueue one chat turn pinned to an EXPLICIT (provider, model) — the "let a stronger model take over" escalation path for Stewdio. Mirrors dispatch_chat_turn (session-ensure + first-turn grounding) but skips alias resolution and reuses chat_enqueue(provider) directly. Text turns only; media keeps the dispatch_chat_turn vision path. Marker-free kind=chat → bgworker tool loop → reply in messages.';

-- =====================================================================
-- End of 60-chat-model-pin.sql
-- =====================================================================
-- ===== [was 61-world-build-worklist.sql] =====
-- =====================================================================
-- 61-world-build-worklist.sql — make world-build METHODICAL (the scratch file)
-- =====================================================================
-- Why: the world-build agent (55) drove itself with doc_search "in passes
-- until you decide the structure is captured." That is an UNBOUNDED search
-- with no done-signal and no externalized worklist — so the model free-
-- searches until it falls off the edge. Observed on BOTH a weak local model
-- (qwen3.6-35b-a3b: 60 turns, 235 doc_search calls, ZERO entities) AND a
-- strong cloud model (Gemini, same shape: lots of searching, no done-marker).
-- A strong model failing identically is the tell: this is a HARNESS gap, not
-- a model gap (harness > intelligence).
--
-- The fix is the study scratch-file rule applied to extraction: give the agent
-- a persisted WORKLIST it drains, and a deterministic DONE-SIGNAL. We turn the
-- build from "search semantically until you feel done" into "WALK the canon
-- chunk-by-chunk until every chunk has been seen." Properties:
--   • bounded + terminating — each walk call strictly advances coverage;
--   • a real done-signal — complete:true means every source chunk was shown;
--   • resumable — coverage persists per (world, doc), so a huge corpus finishes
--     across multiple build runs, each guaranteed to make progress (the BoM-walk
--     committed-progress pattern). A reset clears it for a fresh rebuild.
-- Quality of each chunk's extraction is still judged separately by the
-- world-critic (58); this file owns COVERAGE, not correctness.
--
-- requires create_chat_model_pin (60). Generic core.
-- =====================================================================

-- ── §1 — the coverage worklist (one row per source chunk per world) ──
CREATE TABLE IF NOT EXISTS stewards.world_build_coverage (
    world_slug      text        NOT NULL,
    doc_slug        text        NOT NULL,
    status          text        NOT NULL DEFAULT 'pending',   -- pending | done
    entities_found  int,                                       -- optional, set by mark
    served_at       timestamptz,
    done_at         timestamptz,
    PRIMARY KEY (world_slug, doc_slug)
);
CREATE INDEX IF NOT EXISTS world_build_coverage_pending_idx
    ON stewards.world_build_coverage (world_slug) WHERE status = 'pending';

COMMENT ON TABLE stewards.world_build_coverage IS
'61: the world-build scratch file — one row per source chunk per world, drained by world_build_walk. Persists across build runs (resumable, BoM-walk style); status=done means the chunk was shown to the builder. Coverage, not correctness (the world-critic judges quality).';

-- ── §2 — the projects a world is built from (primary + referenced) ──
CREATE OR REPLACE FUNCTION stewards.world_build_projects(p_world text)
RETURNS text[] LANGUAGE sql STABLE AS $fn$
    SELECT array_remove(
        array_cat(
            ARRAY[w.project],
            COALESCE(
                (SELECT array_agg(value) FROM jsonb_array_elements_text(w.metadata -> 'reference_projects') value),
                '{}'
            )
        ), NULL)
    FROM stewards.worlds w WHERE w.slug = p_world;
$fn$;
COMMENT ON FUNCTION stewards.world_build_projects(text) IS
'61: the project buckets a world draws canon from — primary worlds.project + metadata.reference_projects. The walk seeds its worklist from the docs in these.';

-- ── §3 — world_build_walk: the driver. Seed → serve next batch → done-signal ──
-- One call: (1) seeds coverage from the world's project docs if empty; (2) serves
-- up to `batch` still-pending chunks (full body), marking them done (shown);
-- (3) returns progress + complete:true once nothing is pending. The agent loops
-- this and extracts from each returned batch — it CANNOT loop forever (pending
-- strictly decreases) and it has an unambiguous finish line.
CREATE OR REPLACE FUNCTION stewards.world_build_walk_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_world   text := p_args ->> 'world_slug';
    v_batch   int  := greatest(1, least(8, coalesce((p_args ->> 'batch')::int, 4)));
    v_reset   bool := coalesce((p_args ->> 'reset')::bool, false);
    v_projects text[];
    v_total   int;
    v_done    int;
    v_pending int;
    v_chunks  jsonb;
BEGIN
    IF v_world IS NULL OR v_world = '' THEN
        RETURN jsonb_build_object('error', 'world_slug required');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM stewards.worlds WHERE slug = v_world) THEN
        RETURN jsonb_build_object('error', 'no such world: ' || v_world);
    END IF;

    v_projects := stewards.world_build_projects(v_world);
    IF v_projects IS NULL OR array_length(v_projects, 1) IS NULL THEN
        -- No project corpus (e.g. a world built from inline/pasted canon). The
        -- walk does not apply; the agent extracts from the canon in its task.
        RETURN jsonb_build_object('ok', true, 'complete', true, 'chunks', '[]'::jsonb,
            'note', 'this world has no project corpus to walk — extract from the canon given in your task (and doc_search if a project is named there)',
            'progress', jsonb_build_object('total', 0, 'done', 0, 'pending', 0));
    END IF;

    IF v_reset THEN
        DELETE FROM stewards.world_build_coverage WHERE world_slug = v_world;
    END IF;

    -- Seed the worklist from every chunk in the world's project bucket(s).
    INSERT INTO stewards.world_build_coverage (world_slug, doc_slug, status)
    SELECT v_world, d.slug, 'pending'
      FROM stewards.docs d
     WHERE d.project_association = ANY (v_projects)
    ON CONFLICT (world_slug, doc_slug) DO NOTHING;

    -- A reset call is a pure operation: reseed and report, serve NOTHING (so the
    -- caller can clear coverage then start the walk from the top on the next call).
    IF v_reset THEN
        SELECT count(*) INTO v_total FROM stewards.world_build_coverage WHERE world_slug = v_world;
        RETURN jsonb_build_object('ok', true, 'reset', true, 'complete', false, 'chunks', '[]'::jsonb,
            'progress', jsonb_build_object('total', v_total, 'done', 0, 'pending', v_total),
            'note', format('coverage cleared and reseeded with %s chunks — call world_build_walk again (no reset) to begin the walk.', v_total));
    END IF;

    -- Serve the next batch of pending chunks (full body) and mark them done
    -- (= shown to the builder). Optimistic + crash-safe: no half-served state to
    -- reconcile, and pending strictly decreases so the loop always terminates.
    WITH nxt AS (
        SELECT c.doc_slug
          FROM stewards.world_build_coverage c
         WHERE c.world_slug = v_world AND c.status = 'pending'
         ORDER BY c.doc_slug
         LIMIT v_batch
         FOR UPDATE SKIP LOCKED
    ), served AS (
        UPDATE stewards.world_build_coverage c
           SET status = 'done', served_at = now(), done_at = now()
          FROM nxt WHERE c.world_slug = v_world AND c.doc_slug = nxt.doc_slug
        RETURNING c.doc_slug
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('doc', d.slug, 'body', d.body) ORDER BY d.slug), '[]'::jsonb)
      INTO v_chunks
      FROM served s JOIN stewards.docs d ON d.slug = s.doc_slug;

    SELECT count(*), count(*) FILTER (WHERE status = 'done')
      INTO v_total, v_done
      FROM stewards.world_build_coverage WHERE world_slug = v_world;
    v_pending := v_total - v_done;

    RETURN jsonb_build_object(
        'ok', true,
        'complete', (jsonb_array_length(v_chunks) = 0 AND v_pending = 0),
        'chunks', v_chunks,
        'progress', jsonb_build_object('total', v_total, 'done', v_done, 'pending', v_pending),
        'note', CASE WHEN jsonb_array_length(v_chunks) = 0 AND v_pending = 0
                     THEN 'COMPLETE — every source chunk has been shown. Stop walking; do a final relationship pass with world_edge_upsert, then write your journal.'
                     ELSE format('extract EVERY entity + relationship in these %s chunk(s), then call world_build_walk again. %s of %s chunks read.',
                                 jsonb_array_length(v_chunks), v_done, v_total) END
    );
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', SQLERRM);
END $fn$;
COMMENT ON FUNCTION stewards.world_build_walk_tool(jsonb) IS
'61: the world-build driver — seeds a per-world coverage worklist from its project chunks and serves the next batch (marking them shown), returning progress + complete:true when none remain. Turns an unbounded search into a bounded, resumable, deterministic walk (the scratch-file / done-signal fix for the over-search-never-commit failure).';

-- ── §4 — register the tool + grant it to the world-build agent ──────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_build_walk',
  'WALK the canon chunk-by-chunk — your worklist and done-signal. Each call records the previous batch as read and returns the NEXT batch of source chunks (full text) plus progress {done, pending, total}. Extract EVERY entity and relationship in each returned batch, then call again. Keep going until it returns complete:true — that means every chunk has been shown and you are DONE walking. This is your primary loop; doc_search is only for enriching the relationship pass afterwards. (batch defaults to 4; pass reset:true to start the coverage over for a fresh rebuild.)',
  '{"type":"object","additionalProperties":false,"properties":{'
    '"world_slug":{"type":"string","description":"the world you are building"},'
    '"batch":{"type":"integer","description":"how many chunks to take this call (1-8, default 4)"},'
    '"reset":{"type":"boolean","description":"clear coverage and walk the corpus from the start (fresh rebuild)"}'
  '},"required":["world_slug"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_build_walk_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE
  SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
      execute_target = EXCLUDED.execute_target, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('world-build', 'world_build_walk', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- ── §5 — re-author the world-build agent: WALK, don't free-search ───
-- The build loop is now the deterministic walk. doc_search is demoted from
-- "the driver" to "an enrichment tool for the relationship pass." The COMMIT
-- discipline (a count:0 search means move on, never re-search) is baked in —
-- the permanent version of the steering that rescued the Cosmere build, and the
-- same fix family as the work-item-chat COMMIT clause (45).
UPDATE stewards.agents SET
  steps = 120,
  prompt = $PROMPT$You are BUILDING a World — turning a pile of source lore into a structured, explorable knowledge graph.

Your task names a world_slug and the canon it is built from. You build by WALKING the canon
chunk-by-chunk (your worklist), NOT by free-searching until you feel done — that loops forever.

0. LOAD THE CANON IF ASKED. If your task says to import an attachment (gives an attachment_id and a
   project name), call doc_import_corpus(attachment_id, corpus_name, project) EXACTLY ONCE first —
   that extracts + chunks the uploaded source into the searchable project. Wait for it to finish.
   If the task instead names an existing project or pastes the canon inline, skip this step.

1. WALK THE CANON — this is your main loop and your done-signal:
   a. Call world_build_walk(world_slug) to get the next batch of source chunks (full text) and your
      progress {done, pending, total}.
   b. Read those chunks and extract EVERYTHING the canon describes in them: call world_entity_upsert
      for each character | place | faction | item | event | lore | concept (a 1-2 sentence summary IN
      THE CANON'S OWN TERMS, any aliases, and source_refs pointing at the chunk you found it in), and
      world_edge_upsert for the relationships you can already see within the batch.
   c. Call world_build_walk AGAIN — it records the batch you just read and serves the next one.
   d. Repeat until world_build_walk returns complete:true. THAT is your done-signal: every source
      chunk has been shown. Do not keep walking after complete:true.

2. RELATIONSHIP PASS (after the walk is complete). Connect entities across the whole world with
   world_edge_upsert — who serves whom, what is located where, who rules, who opposes whom. A missing
   endpoint is auto-created, so assert the relationship and move on. Here, and ONLY here, use doc_search
   or world_entity_search to confirm a link or recall an entity's exact name.
   USE THE RIGHT VERB AND DIRECTION (a reversed edge is a lie about the world):
   - located_in: a place inside a larger place (Bree located_in Bree-land).
   - dwells_in: a people/character whose home is a place (Hobbits dwells_in the Shire).
   - home_of: ONLY a place that is the home of a people/character (the Shire home_of Hobbits) — the
     REVERSE of dwells_in. Do not use home_of for a place-in-a-place.
   - flows_through, rules/ruled_by, member_of, ally_of, enemy_of, guards, parent_of, child_of,
     created, wields, heir_of, near, borders. When unsure, call world_vocabulary.

Rules of the watch:
- GROUND EVERYTHING. Only record what the canon supports. Do not invent lore, names, or relationships
  from general knowledge — if it isn't in this canon, it isn't in this world.
- COMMIT, don't loop. A doc_search that returns count:0 means that content is NOT in this canon — move
  on, NEVER re-issue the same empty search. Extracting from a chunk you have beats searching for one
  you wish existed. The walk, not search, tells you when you are done.
- De-duplicate: the same character under two names is ONE entity with aliases, not two. The tools are
  idempotent — never re-issue an upsert you already made.
- Prefer a few well-grounded, well-connected entities over a sprawl of thin ones.

Your final chat reply is a SHORT journal: how many entities and edges you built, the spine of the
world, and what a deeper pass should chase next. It is not the world itself — the world lives in the
graph you wrote with the tools.$PROMPT$
WHERE family = 'world-build' AND model_match = '*';

-- =====================================================================
-- End of 61-world-build-worklist.sql
-- =====================================================================
-- ===== [was 62-orientation.sql] =====
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

-- ── §3 — the engine's baseline ORIENTATION skills ───────────────────
-- The core already ships two baseline skills (source-verification, reference-
-- linking, seeded in schema.rs). These join them: the two disciplines every
-- gathering agent benefits from, ported from the workspace's most battle-tested
-- orientation (study/ai/harness/lending-the-substrate-our-orientation.md).
-- Ratified 2026-06-26 (core-baseline, "no operator left orientation-poor").
INSERT INTO stewards.skills (family, model_match, description, body, active) VALUES
( 'orient-first', '*',
  'Orient before you act — one quick scan before building/extracting/researching over a corpus: what already exists (don''t duplicate), what the real intent is (the literal task is the floor), and what you''d wish you''d checked (the tension/blind spot). The council moment (Abraham 4:26), as a standing habit.',
  $BODY$# Orient before you act — the council moment

Before you build, extract, research, or answer over a corpus, take ONE moment to ORIENT — the
way a council takes counsel before acting. It is three quick questions, not a phase:

1. **What already exists?** Survey before you add. Has this entity / answer / document already
   been produced? Search the project, world, or corpus for prior work so you EXTEND it rather
   than duplicate it. If you have a survey or coverage tool, call it FIRST.

2. **What is the real intent?** The literal task is the floor; the goal is the target. Name what
   success looks like and who it is for before you start producing — so when the instructions run
   out, you still know where you are going.

3. **What would I wish I'd checked?** Scan for the tension, the blind spot, the adjacent thing the
   asker assumed you would handle. Surface it rather than only building toward the obvious answer.

One scan, then act. Orienting first is not slower — it stops the duplicate, the wrong-target
build, and the blind spot before any of them costs a whole run.
$BODY$, true ),
( 'bounded-gather', '*',
  'Methodical gathering — how to search/extract over a large or open-ended source WITHOUT looping: commit when you have enough, treat an empty search as "absent", walk a finite set instead of re-deriving what is left, and stop on a fact not a feeling. For any agent gathering, surveying, or extracting broadly.',
  $BODY$# Methodical gathering — don't search until you fall off the edge

You are gathering over a large or open-ended source. The failure to avoid: searching feels like
progress, so you keep searching when you should be producing — and burn your whole tool budget
looping, often with nothing to show. Four rules:

1. **COMMIT.** The moment what you have retrieved answers the question, STOP searching and produce.
   Verify at most once. Producing from what you hold beats one more search.

2. **EMPTY MEANS ABSENT.** A search that returns nothing means that content is not in this source —
   move on. NEVER re-issue the same search reworded; that rephrase-and-retry is exactly the loop
   that wastes the run.

3. **KNOW YOUR FRONTIER.** If you can enumerate what you must cover — every chunk, every doc, every
   item — work THROUGH that list and track what is done, rather than re-deriving "what's left" from
   memory each turn. When the list is empty, you are finished. (If a tool gives you a coverage walk,
   use it: it is your worklist and your done-signal.)

4. **A DONE-SIGNAL IS A FACT, NOT A FEELING.** "I think I've searched enough" is not done. "I have
   answered the question" / "0 items remain" is done.

If you notice you have searched several times with little new, that IS the signal: stop and write
your result with what you have.
$BODY$, true )
ON CONFLICT (family, model_match) DO UPDATE
  SET description = EXCLUDED.description, body = EXCLUDED.body, active = true;

-- ── §4 — baseline autoload wiring: the corpus-builders carry orientation ──
-- orient-first → every agent that builds/extracts over a corpus; bounded-gather →
-- the open-ended searchers (world-build already has the WALK, so orient-first only).
-- Operators extend or override this with their own skill_autoload rows.
INSERT INTO stewards.skill_autoload (agent_family, skill_family, note) VALUES
  ('world-build',              'orient-first',   'survey existing entities before extracting (the walk already bounds coverage)'),
  ('research',                 'orient-first',   'survey existing studies before researching'),
  ('research',                 'bounded-gather', 'open-ended search — commit, do not loop'),
  ('subagent-doc-investigate', 'orient-first',   NULL),
  ('subagent-doc-investigate', 'bounded-gather', NULL),
  ('subagent-docs-audit',      'orient-first',   NULL),
  ('subagent-docs-audit',      'bounded-gather', 'audits a set — walk it, do not free-search'),
  ('loremaster',               'orient-first',   NULL),
  ('compactor',                'bounded-gather', NULL)
ON CONFLICT (agent_family, skill_family) DO UPDATE SET note = EXCLUDED.note;

-- =====================================================================
-- End of 62-orientation.sql
-- =====================================================================
-- ===== [was 63-orient-survey.sql] =====
-- =====================================================================
-- 63-orient-survey.sql — the universal orient move: "what already exists here?"
-- =====================================================================
-- Phase 2 of lending the substrate our orientation. Phase 1 gave every corpus-
-- builder the orient-first DISPOSITION (the skill) — and the watch showed agents
-- acting on it ("I'll start by orienting…") using whatever survey they had
-- (world-build called world_show; the chat called doc_search). This gives them
-- the MECHANISM uniformly: orient_survey generalizes the reflect-steward's
-- intent_work_survey (22, intent-scoped, planner-only) to ANY agent, keyed on a
-- PROJECT — what docs, worlds, and work already exist for it, so the builder
-- EXTENDS rather than rebuilds. The council moment (Abraham 4:26) as a tool, for
-- everyone, not just the planner.
--
-- requires create_orientation (62). Generic core.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.orient_survey_tool(p_args jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $FN$
DECLARE
    v_sess    text := p_args->>'_session_id';
    v_project text := nullif(btrim(coalesce(p_args->>'project','')), '');
BEGIN
    -- resolve the project: explicit arg, else this session's work_item.
    IF v_project IS NULL THEN
        SELECT project_association INTO v_project
          FROM stewards.work_items
         WHERE v_sess = ANY(session_ids) AND project_association IS NOT NULL
         ORDER BY id DESC LIMIT 1;
    END IF;
    IF v_project IS NULL THEN
        RETURN '{"error":"no project to orient on — pass {\"project\":\"<name>\"} (or call this from a project-scoped work item)"}';
    END IF;

    RETURN jsonb_build_object(
        'project', v_project,
        'doc_count', (SELECT count(*) FROM stewards.docs WHERE project_association = v_project),
        'recent_docs', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'slug', slug, 'title', title,
                       'gist', left(regexp_replace(coalesce(body,''), '\s+', ' ', 'g'), 160)
                     ) ORDER BY updated_at DESC), '[]'::jsonb)
              FROM (SELECT slug, title, body, updated_at FROM stewards.docs
                     WHERE project_association = v_project ORDER BY updated_at DESC LIMIT 10) d),
        'existing_worlds', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'slug', w.slug, 'name', w.name,
                       'entities', (SELECT count(*) FROM stewards.world_entities e WHERE e.world_id = w.world_id),
                       'edges', (SELECT count(*) FROM stewards.world_edges g WHERE g.world_id = w.world_id))), '[]'::jsonb)
              FROM stewards.worlds w WHERE w.project = v_project),
        'recent_work', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                       'slug', slug, 'pipeline', pipeline_family, 'status', status) ORDER BY created_at DESC), '[]'::jsonb)
              FROM (SELECT slug, pipeline_family, status, created_at FROM stewards.work_items
                     WHERE project_association = v_project ORDER BY created_at DESC LIMIT 10) wi),
        'note', 'ORIENT — this is what already exists for this project. EXTEND it; do not rebuild or duplicate what is already here. If a world or doc already covers what you were asked to make, deepen that line rather than starting over (cite its slug). This is your council moment (Abraham 4:26 — take counsel before acting).'
    )::text;
END $FN$;
COMMENT ON FUNCTION stewards.orient_survey_tool(jsonb) IS
'63: the universal orient survey — "what already exists for this project?" (docs + worlds + work). Generalizes intent_work_survey (22) from intent→project so any corpus-builder can orient before acting, not just the reflect-steward.';

-- ── register + grant to the corpus-builders (the agents that carry orient-first) ──
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active)
VALUES (
  'orient_survey',
  'Orient before you build: returns what ALREADY EXISTS for a project — how many docs, the recent ones with a gist, any worlds built over it (with entity/edge counts), and recent work items. Call this FIRST when you are building/extracting/researching over a project, so you extend what is there instead of duplicating it. Pass {"project":"<name>"} or call from a project-scoped work item. Your council moment.',
  '{"type":"object","additionalProperties":false,"properties":{"project":{"type":"string","description":"the project/corpus to orient on (optional if your work item is project-scoped)"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"orient_survey_tool"}'::jsonb, true)
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('world-build',              'orient_survey', 'allow', 'manual'),
  ('research',                 'orient_survey', 'allow', 'manual'),
  ('subagent-doc-investigate', 'orient_survey', 'allow', 'manual'),
  ('subagent-docs-audit',      'orient_survey', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- =====================================================================
-- End of 63-orient-survey.sql
-- =====================================================================
-- ===== [was 64-auto-critique.sql] =====
-- =====================================================================
-- 64-auto-critique.sql — make trajectory verification STANDING
-- =====================================================================
-- Phase 3 of lending the substrate our orientation: the VERIFY half. Google's
-- SDLC: both output AND trajectory eval are necessary, and the skipped one hides
-- the MORE dangerous failures (a fluent answer that never ran its verification,
-- a 404 read as success, a loop that never converged). The substrate built the
-- trajectory critic (56) and the verdict→self-improvement loop (59) — but nothing
-- FIRES it; critique_trajectory was call-on-demand. So the Glass-Box half sat
-- dormant, exactly like the orientation shelf did (62).
--
-- This adds the missing FRONT: when a WORKER run finishes, automatically critique
-- its trajectory. The verdict lands via the existing harvest trigger (59) →
-- trajectory_verdicts → the self-improvement loop. The loop closes itself; this
-- is the one trigger that makes it standing. No bgworker change (a trigger
-- enqueues the critic chat the existing bgworker already drains).
--
-- COST-SAFE: default OFF (a config gate, like autonomy_paused) — an LLM critique
-- per worker run is real spend; the operator opts in, and the reflect-watchman
-- spend guard (23) still caps it. GATE INTEGRITY: never critiques a grader/steward
-- (no recursion, and we do not grade the graders) — the same exclusion the
-- eval-gaming gate (59) uses.
--
-- requires create_orient_survey (63). Generic core.
-- =====================================================================

-- ── config: the gate (default OFF) + which agent families to critique ──
SELECT stewards.config_set('auto_critique_on_complete', 'false'::jsonb,
    'When true, a WORKER run finishing automatically dispatches the trajectory-critic (56) over its trajectory; the verdict lands via the harvest trigger (59) and feeds the self-improvement loop. Default false — an LLM critique per run is real spend. Turn on per substrate when you want the Glass-Box verification half standing.');
SELECT stewards.config_set('auto_critique_families', '"research,dev,world-build"'::jsonb,
    'Comma-separated agent-family globs whose runs get auto-critiqued when auto_critique_on_complete is on (group_applies semantics). The worker families; never the graders/stewards (those are hard-excluded for gate integrity).');

-- ── the decision: a deterministic predicate (so it is testable without a live dispatch) ──
CREATE OR REPLACE FUNCTION stewards.should_auto_critique(p_session text, p_family text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_fin text; v_tools int;
BEGIN
    -- the gate
    IF coalesce((stewards.config_get('auto_critique_on_complete','false'::jsonb))::text::boolean, false) IS NOT TRUE THEN
        RETURN false;
    END IF;
    IF p_session IS NULL OR p_family IS NULL THEN RETURN false; END IF;
    -- only the configured worker families…
    IF NOT stewards.group_applies(stewards.config_get_text('auto_critique_families', ''), p_family) THEN
        RETURN false;
    END IF;
    -- …and NEVER a grader / gate / steward (no recursion; do not grade the graders)
    IF p_family IN ('trajectory-critic','world-critic','prompt-critic','judge-brief','agent-improver',
                    'compactor','engram-extractor','watchman-consolidator','reflect-steward','hinge','steward') THEN
        RETURN false;
    END IF;
    -- fire once, at the run's COMMITTED end, and only if there is a real trajectory to judge
    SELECT finish_reason INTO v_fin FROM stewards.messages
     WHERE session_id = p_session AND role = 'assistant' ORDER BY id DESC LIMIT 1;
    IF v_fin IS DISTINCT FROM 'stop' THEN RETURN false; END IF;
    SELECT (stewards.assemble_trajectory(p_session) ->> 'tool_call_count')::int INTO v_tools;
    IF coalesce(v_tools, 0) = 0 THEN RETURN false; END IF;  -- no tools → no interesting Glass-Box surface
    -- not already judged
    IF EXISTS (SELECT 1 FROM stewards.trajectory_verdicts WHERE target_session = p_session) THEN
        RETURN false;
    END IF;
    RETURN true;
END $fn$;
COMMENT ON FUNCTION stewards.should_auto_critique(text, text) IS
'64: the standing-critique predicate — config-gated, worker-families-only, graders-excluded, fires once at a run''s committed end (finish_reason=stop) when it used tools and has no verdict yet. Deterministic so the gate is testable without a live dispatch.';

-- ── the trigger: a worker run finishing → critique its trajectory ──
CREATE OR REPLACE FUNCTION stewards.auto_critique_on_complete_fn() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.status = 'done' AND OLD.status <> 'done' AND NEW.kind = 'chat'
       AND stewards.should_auto_critique(NEW.payload ->> 'session_id', NEW.payload ->> 'agent_family') THEN
        PERFORM stewards.critique_trajectory(NEW.payload ->> 'session_id');
    END IF;
    RETURN NEW;
END $fn$;
DROP TRIGGER IF EXISTS work_queue_auto_critique ON stewards.work_queue;
CREATE TRIGGER work_queue_auto_critique
    AFTER UPDATE OF status ON stewards.work_queue
    FOR EACH ROW EXECUTE FUNCTION stewards.auto_critique_on_complete_fn();
COMMENT ON FUNCTION stewards.auto_critique_on_complete_fn() IS
'64: standing Glass-Box verification — when a worker chat run finishes (and should_auto_critique passes), dispatch the trajectory-critic over it. The verdict is harvested by 59 into trajectory_verdicts and feeds the self-improvement loop. Default off; graders excluded (no recursion).';

-- =====================================================================
-- End of 64-auto-critique.sql
-- =====================================================================
