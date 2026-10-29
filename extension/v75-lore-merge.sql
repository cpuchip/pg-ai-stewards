-- =====================================================================
-- v75: one thing, one entity: merging duplicate entities in a world.
-- =====================================================================
-- world_entities is UNIQUE (world_id, kind, name), so one name written under several kinds (an idea, an event,
-- an object) becomes several nodes. A lookup by name met them in no fixed order (LIMIT 1 with no ORDER BY), so a
-- relationship asserted later landed on whichever twin came first. Ported from stuffleupagus st-44 (2026-10-29),
-- where its persona folded six sets of duplicates on the live path the hour the tool shipped. No schema change:
-- the UNIQUE key stays as it is (changing it is a migration of its own).
--
--   world_entity_lookup(world, name)      the entity a name means, the same one every time: exact name, then an
--                                         alias, then the one with the most relationships, then the oldest.
--                                         world_edge_upsert, lore_entity and lore_neighbors resolve through it.
--   world_entity_merge(slug, keep, from[]) folds entities into one: their relationships move to it (a repeat of
--                                         one it has, or one to itself, is dropped), their names and aliases
--                                         become its aliases, their source_refs join its own, and metadata.merged
--                                         records what was folded (kind, name, summary). Its embedding is
--                                         cleared for the next world_entity_embed.
--   world_entity_merge_tool / lore_merge  the same by name: name (+ kind when several share it) is kept; from
--                                         (+ from_kind) is folded in, or every namesake when from is left out;
--                                         the result names any namesakes still there.
--   world_entity_delete(slug, name, kind) removes one entity and its relationships; refuses a name several
--                                         entities share unless kind says which. Tool: lore_forget.
--   world_entity_namesakes(slug)          the names more than one entity carries, with kinds and edge counts.
--   lore_entity                           now lists the kinds of an entity's namesakes, when it has any.
--
-- The two tools are registered INACTIVE: a tool active by default is offered to every family without a '*'
-- deny row (tool_permission's default), which would change those agents' tool lists, and their prompts, on
-- upgrade. An instance turns them on with UPDATE stewards.tool_defs SET active = true WHERE name IN (...).
-- Oracle: virgin-smoke OK 142. Idempotent.
-- =====================================================================

CREATE OR REPLACE FUNCTION stewards.world_entity_lookup(p_world bigint, p_name text)
RETURNS bigint LANGUAGE sql STABLE AS $$
    SELECT e.entity_id
      FROM stewards.world_entities e
     WHERE e.world_id = p_world AND (e.name = p_name OR p_name = ANY (e.aliases))
     ORDER BY (e.name = p_name) DESC,
              (SELECT count(*) FROM stewards.world_edges g WHERE g.src_entity = e.entity_id OR g.dst_entity = e.entity_id) DESC,
              e.entity_id
     LIMIT 1
$$;

COMMENT ON FUNCTION stewards.world_entity_lookup(bigint, text) IS
'v75: the entity a name means in a world, the same one every time: exact name over alias, then most relationships, then oldest. NULL when none.';

CREATE OR REPLACE FUNCTION stewards.world_entity_merge(
    p_world_slug text,
    p_keep       bigint,
    p_from       bigint[],
    p_summary    text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_world bigint;
    v_keep  stewards.world_entities;
    v_ids   bigint[];
    v_gone  jsonb;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN
        RAISE EXCEPTION 'world_entity_merge: unknown world slug %', p_world_slug;
    END IF;
    SELECT * INTO v_keep FROM stewards.world_entities WHERE entity_id = p_keep AND world_id = v_world;
    IF v_keep.entity_id IS NULL THEN
        RAISE EXCEPTION 'world_entity_merge: entity % is not in world %', p_keep, p_world_slug;
    END IF;
    SELECT array_agg(entity_id ORDER BY entity_id),
           jsonb_agg(jsonb_build_object('kind', kind, 'name', name, 'summary', left(summary, 400)) ORDER BY entity_id)
      INTO v_ids, v_gone
      FROM stewards.world_entities
     WHERE world_id = v_world AND entity_id = ANY (p_from) AND entity_id <> p_keep;
    IF v_ids IS NULL THEN
        RAISE EXCEPTION 'world_entity_merge: nothing to fold into % in world %', p_keep, p_world_slug;
    END IF;
    -- their relationships, pointed at the kept one; a repeat of one it has, or one to itself, is dropped
    INSERT INTO stewards.world_edges (world_id, src_entity, dst_entity, rel_type, evidence, metadata, created_at)
    SELECT world_id,
           CASE WHEN src_entity = ANY (v_ids) THEN p_keep ELSE src_entity END,
           CASE WHEN dst_entity = ANY (v_ids) THEN p_keep ELSE dst_entity END,
           rel_type, evidence, metadata, created_at
      FROM stewards.world_edges
     WHERE world_id = v_world AND (src_entity = ANY (v_ids) OR dst_entity = ANY (v_ids))
       AND (CASE WHEN src_entity = ANY (v_ids) THEN p_keep ELSE src_entity END)
           <> (CASE WHEN dst_entity = ANY (v_ids) THEN p_keep ELSE dst_entity END)
    ON CONFLICT DO NOTHING;
    UPDATE stewards.world_entities k SET
        aliases = ARRAY(SELECT DISTINCT a FROM unnest(k.aliases || ARRAY(
                      SELECT x FROM stewards.world_entities d, unnest(d.aliases || d.name) x
                       WHERE d.entity_id = ANY (v_ids))) a
                   WHERE a IS NOT NULL AND a <> k.name ORDER BY a),
        source_refs = k.source_refs || coalesce((SELECT jsonb_agg(r ORDER BY d.entity_id) FROM stewards.world_entities d,
                         jsonb_array_elements(d.source_refs) r WHERE d.entity_id = ANY (v_ids)), '[]'::jsonb),
        summary = coalesce(nullif(btrim(p_summary), ''), k.summary),
        metadata = k.metadata || jsonb_build_object('merged', coalesce(k.metadata -> 'merged', '[]'::jsonb) || v_gone),
        embedding = NULL
     WHERE k.entity_id = p_keep;
    DELETE FROM stewards.world_entities WHERE entity_id = ANY (v_ids);   -- their old relationships go with them
    RETURN jsonb_build_object('kept', v_keep.name, 'kind', v_keep.kind, 'entity_id', p_keep, 'folded_in', v_gone,
        'relationships', (SELECT count(*) FROM stewards.world_edges WHERE src_entity = p_keep OR dst_entity = p_keep));
END $$;

COMMENT ON FUNCTION stewards.world_entity_merge(text, bigint, bigint[], text) IS
'v75: fold entities (p_from) into one (p_keep) in a world: relationships moved (repeats and self-links dropped), names and aliases kept as aliases, source_refs joined, metadata.merged records what was folded, summary replaced only when p_summary is given. Raises on an unknown world, a keep outside it, or nothing to fold.';

CREATE OR REPLACE FUNCTION stewards.world_entity_namesakes(p_world_slug text)
RETURNS TABLE (name text, kinds jsonb)
LANGUAGE sql STABLE AS $$
    SELECT min(e.name), jsonb_agg(jsonb_build_object('kind', e.kind, 'name', e.name, 'relationships',
               (SELECT count(*) FROM stewards.world_edges g WHERE g.src_entity = e.entity_id OR g.dst_entity = e.entity_id))
               ORDER BY e.entity_id)
      FROM stewards.world_entities e JOIN stewards.worlds w USING (world_id)
     WHERE w.slug = p_world_slug
     GROUP BY lower(e.name)
    HAVING count(*) > 1
     ORDER BY 1
$$;

COMMENT ON FUNCTION stewards.world_entity_namesakes(text) IS
'v75: the names (any case) more than one entity in a world carries, each with its kinds, spellings and relationship counts.';

CREATE OR REPLACE FUNCTION stewards.world_entity_delete(p_world_slug text, p_name text, p_kind text DEFAULT NULL)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    v_world bigint;
    v_n     int;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world IS NULL THEN
        RAISE EXCEPTION 'world_entity_delete: unknown world slug %', p_world_slug;
    END IF;
    IF p_kind IS NULL AND (SELECT count(*) FROM stewards.world_entities WHERE world_id = v_world AND name = p_name) > 1 THEN
        RAISE EXCEPTION 'world_entity_delete: several entities are named "%" in %: say which with a kind, or merge them',
            p_name, p_world_slug;
    END IF;
    DELETE FROM stewards.world_entities                  -- its relationships go with it (ON DELETE CASCADE)
     WHERE world_id = v_world AND name = p_name AND (p_kind IS NULL OR kind = p_kind);
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END $$;

COMMENT ON FUNCTION stewards.world_entity_delete(text, text, text) IS
'v75: remove one entity by name (and kind) with its relationships; raises when several share the name and no kind is given. Returns the rows removed (0 when none).';

-- the two by name, for an agent
CREATE OR REPLACE FUNCTION stewards.world_entity_merge_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_slug  text := p_args ->> 'world_slug';
    v_name  text := btrim(coalesce(p_args ->> 'name', ''));
    v_kind  text := nullif(btrim(p_args ->> 'kind'), '');
    v_from  text := coalesce(nullif(btrim(p_args ->> 'from'), ''), btrim(coalesce(p_args ->> 'name', '')));
    v_fkind text := nullif(btrim(p_args ->> 'from_kind'), '');
    v_world bigint;
    v_keep  stewards.world_entities;
    v_n     int;
    v_ids   bigint[];
    v_out   jsonb;
    v_left  jsonb;
BEGIN
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = v_slug;
    IF v_world IS NULL THEN RETURN jsonb_build_object('error', 'unknown world'); END IF;
    IF v_name = '' THEN RETURN jsonb_build_object('error', 'name (the entity to keep) is required'); END IF;
    SELECT count(*) INTO v_n FROM stewards.world_entities
     WHERE world_id = v_world AND lower(name) = lower(v_name) AND (v_kind IS NULL OR kind = v_kind);
    IF v_n = 0 THEN RETURN jsonb_build_object('error', format('no entity named "%s"%s', v_name, coalesce(' of kind ' || v_kind, ''))); END IF;
    IF v_n > 1 THEN
        RETURN jsonb_build_object('error', format('several entities are named "%s": say which to keep with kind', v_name),
            'namesakes', (SELECT kinds FROM stewards.world_entity_namesakes(v_slug) WHERE lower(name) = lower(v_name)));
    END IF;
    SELECT * INTO v_keep FROM stewards.world_entities
     WHERE world_id = v_world AND lower(name) = lower(v_name) AND (v_kind IS NULL OR kind = v_kind);
    SELECT array_agg(entity_id) INTO v_ids FROM stewards.world_entities
     WHERE world_id = v_world AND lower(name) = lower(v_from) AND (v_fkind IS NULL OR kind = v_fkind)
       AND entity_id <> v_keep.entity_id;
    IF v_ids IS NULL THEN
        RETURN jsonb_build_object('error', format('nothing to fold in: no other entity named "%s"%s', v_from,
                                                  coalesce(' of kind ' || v_fkind, '')));
    END IF;
    v_out := stewards.world_entity_merge(v_slug, v_keep.entity_id, v_ids, p_args ->> 'summary');
    SELECT jsonb_agg(kind ORDER BY entity_id) INTO v_left FROM stewards.world_entities
     WHERE world_id = v_world AND lower(name) = lower(v_keep.name) AND entity_id <> v_keep.entity_id;
    RETURN v_out || jsonb_build_object('ok', true, 'still_here', v_left);
END $fn$;

CREATE OR REPLACE FUNCTION stewards.world_entity_delete_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_n int;
BEGIN
    IF p_args ->> 'world_slug' IS NULL OR p_args ->> 'name' IS NULL THEN
        RETURN jsonb_build_object('error', 'world_slug and name required');
    END IF;
    BEGIN
        v_n := stewards.world_entity_delete(p_args ->> 'world_slug', p_args ->> 'name', nullif(btrim(p_args ->> 'kind'), ''));
    EXCEPTION WHEN raise_exception THEN
        RETURN jsonb_build_object('error', SQLERRM);
    END;
    RETURN jsonb_build_object('ok', true, 'removed', v_n);
END $fn$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'lore_merge',
  'Fold duplicate entities in a world into one, when one thing has ended up as several (the same name under different kinds, or two names for one thing). name (and kind, when several share the name) is the one to keep; from is the name to fold into it, and when left out every other entity with the kept one''s name is folded in. Their relationships move to the kept one, their names become its aliases, and their summaries come back in folded_in; summary replaces the kept one''s. still_here names any namesakes left.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"name":{"type":"string"},"kind":{"type":"string"},"from":{"type":"string"},"from_kind":{"type":"string"},"summary":{"type":"string"}},"required":["world_slug","name"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_entity_merge_tool"}'::jsonb, false ),
( 'lore_forget',
  'Remove one entity (and its relationships) from a world, when it is wrong or no longer worth keeping. kind says which, when several share the name.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"name":{"type":"string"},"kind":{"type":"string"}},"required":["world_slug","name"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_entity_delete_tool"}'::jsonb, false )
ON CONFLICT (name) DO NOTHING;   -- an instance that already defines a tool of that name keeps its own

-- the readers and the edge writer resolve a name through world_entity_lookup: v11's bodies, the lookup swapped in
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
    -- resolve (or create) both endpoints within this world; match name OR alias (v75: the same one every time)
    v_src := stewards.world_entity_lookup(v_world, p_src_name);
    IF v_src IS NULL THEN
        v_src := stewards.world_entity_upsert(p_world_slug, 'concept', p_src_name);
    END IF;
    v_dst := stewards.world_entity_lookup(v_world, p_dst_name);
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

CREATE OR REPLACE FUNCTION stewards.lore_entity_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_slug text := p_args->>'world_slug'; v_name text := p_args->>'name';
        v_world bigint; v_eid bigint; v_ent jsonb; v_edges jsonb;
BEGIN
    IF v_slug IS NULL OR v_name IS NULL THEN RETURN jsonb_build_object('error','world_slug and name required'); END IF;
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug=v_slug;
    IF v_world IS NULL THEN RETURN jsonb_build_object('error','unknown world'); END IF;
    v_eid := stewards.world_entity_lookup(v_world, v_name);
    IF v_eid IS NULL THEN RETURN jsonb_build_object('ok',true,'found',false,'name',v_name); END IF;
    SELECT jsonb_build_object('kind',kind,'name',name,'aliases',aliases,'summary',summary,'source_refs',source_refs)
      INTO v_ent FROM stewards.world_entities WHERE entity_id=v_eid;
    SELECT coalesce(jsonb_agg(jsonb_build_object(
              'rel', g.rel_type, 'dir', CASE WHEN g.src_entity=v_eid THEN 'out' ELSE 'in' END,
              'other', o.name, 'evidence', g.evidence)), '[]'::jsonb)
      INTO v_edges FROM stewards.world_edges g
      JOIN stewards.world_entities o ON o.entity_id = CASE WHEN g.src_entity=v_eid THEN g.dst_entity ELSE g.src_entity END
     WHERE g.src_entity=v_eid OR g.dst_entity=v_eid;
    -- v75: say so when other entities share the name (lore_merge folds them)
    IF (SELECT count(*) FROM stewards.world_entities WHERE world_id=v_world AND lower(name)=lower(v_name)) > 1 THEN
        v_ent := v_ent || jsonb_build_object('namesakes', (SELECT jsonb_agg(kind ORDER BY entity_id)
                   FROM stewards.world_entities WHERE world_id=v_world AND lower(name)=lower(v_name) AND entity_id<>v_eid));
    END IF;
    RETURN jsonb_build_object('ok',true,'found',true,'entity',v_ent,'connections',v_edges);
END $fn$;

CREATE OR REPLACE FUNCTION stewards.lore_neighbors_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_slug text := p_args->>'world_slug'; v_name text := p_args->>'name';
        v_depth int := least(coalesce((p_args->>'depth')::int,2),2);
        v_world bigint; v_eid bigint; v_out jsonb;
BEGIN
    IF v_slug IS NULL OR v_name IS NULL THEN RETURN jsonb_build_object('error','world_slug and name required'); END IF;
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug=v_slug;
    v_eid := stewards.world_entity_lookup(v_world, v_name);
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
