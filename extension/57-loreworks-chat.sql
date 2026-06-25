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
