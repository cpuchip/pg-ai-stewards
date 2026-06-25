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
