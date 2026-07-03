-- =====================================================================
-- 85-world-chat.sql — cross-world lore neighbors + "Chat with this world".
-- =====================================================================
-- 57 gave the loremaster lore_neighbors_tool, but it walks world_edges
-- WITHIN one world (g.world_id = v_world) — it CANNOT cross the seam that
-- 82's cross_world_edges carries (market-taxonomy ↔ CKE service entities,
-- producer ↔ consumer HTTP/gRPC links). So "what services does this market
-- pain touch?" was unanswerable from the graph: the answer lives on the
-- cross-world edge lore_neighbors never looks at.
--
-- This adds world_neighbors_tool — the cross-world SUPERSET of
-- lore_neighbors. It mirrors 57's recursive-CTE idiom (BFS, depth cap, alias
-- match, path cycle-guard) but its edge frontier is world_edges (intra, pinned
-- to the origin world) UNION cross_world_edges (the boundary hops), so a named
-- entity surfaces both its in-world relations AND the entities it links to in
-- OTHER worlds — carrying the other entity's world slug so the caller sees it
-- crossed. lore_neighbors_tool is LEFT UNTOUCHED (the intra-world tool still
-- works exactly as before); this is a new, additive tool.
--
-- It also grants the read-only lore tools to the cockpit chat agent
-- (work-item-chat) so the "Chat with this world" button's session — whose
-- FOLLOW-UP turns the UI dispatches as work-item-chat, not loremaster (the
-- chatSendHandler hardcodes the family) — can still call world_neighbors and
-- friends. All read-only, grounded, cite-first; the loremaster stays read-only.
--
-- Idempotent (CREATE OR REPLACE / ON CONFLICT); virgin-safe. Requires 82
-- (cross_world_edges) + 57 (loremaster + the lore tools it re-authors) + 84
-- (chain tail / effect_class column). See tests/virgin-smoke.sql OK 85.
-- =====================================================================

-- ---------------------------------------------------------------------
-- §1 — world_neighbors_tool: BFS over intra-world edges AND cross-world edges
-- ---------------------------------------------------------------------
-- Args: {world_slug, name, depth (default 1, cap 2), cross (default true)}.
-- Bounding the cross-world walk (avoid the explosion): the edge frontier is
--   (a) world_edges of the ORIGIN world only  (g.world_id = v_world), and
--   (b) cross_world_edges globally            (only when cross = true).
-- Because the intra leg is PINNED to the origin world, once a cross hop lands
-- in another world the walk can only leave that world via ANOTHER cross edge —
-- it never fans out into a foreign world's entire internal call graph (a
-- lodestar-imported service can be thousands of nodes). Depth is capped at 2
-- and the path array is a cycle guard, so the frontier stays small and
-- grounded: every returned row corresponds to a real edge actually traversed.
CREATE OR REPLACE FUNCTION stewards.world_neighbors_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE v_slug  text    := p_args->>'world_slug';
        v_name  text    := p_args->>'name';
        v_depth int     := least(coalesce((p_args->>'depth')::int, 1), 2);
        v_cross boolean  := coalesce((p_args->>'cross')::boolean, true);
        v_world bigint; v_eid bigint; v_out jsonb;
BEGIN
    IF v_slug IS NULL OR v_name IS NULL THEN
        RETURN jsonb_build_object('error','world_slug and name required');
    END IF;
    SELECT world_id INTO v_world FROM stewards.worlds WHERE slug = v_slug;
    IF v_world IS NULL THEN RETURN jsonb_build_object('ok',true,'found',false); END IF;
    -- alias match, exactly as lore_neighbors_tool resolves the anchor entity.
    SELECT entity_id INTO v_eid FROM stewards.world_entities
     WHERE world_id = v_world AND (name = v_name OR v_name = ANY(aliases)) LIMIT 1;
    IF v_eid IS NULL THEN RETURN jsonb_build_object('ok',true,'found',false); END IF;

    WITH RECURSIVE
    -- the undirected edge frontier: origin-world edges + (opt) cross-world edges.
    -- `crossed` marks which rows came from a cross_world_edge (the cross-service link).
    edges(a, b, rel, crossed) AS (
        SELECT g.src_entity, g.dst_entity, g.rel_type, false
          FROM stewards.world_edges g
         WHERE g.world_id = v_world
        UNION ALL
        SELECT c.src_entity, c.dst_entity, c.rel_type, true
          FROM stewards.cross_world_edges c
         WHERE v_cross
    ),
    -- BFS from the anchor; carry the LAST edge (rel + direction + crossed) used
    -- to reach each node so the caller sees HOW it connects, not just THAT it does.
    walk(eid, depth, path, rel, dir, crossed) AS (
        SELECT v_eid, 0, ARRAY[v_eid], NULL::text, NULL::text, false
        UNION ALL
        SELECT CASE WHEN e.a = w.eid THEN e.b ELSE e.a END,
               w.depth + 1,
               w.path || CASE WHEN e.a = w.eid THEN e.b ELSE e.a END,
               e.rel,
               CASE WHEN e.a = w.eid THEN 'out' ELSE 'in' END,
               e.crossed
          FROM walk w
          JOIN edges e ON (e.a = w.eid OR e.b = w.eid)
         WHERE w.depth < v_depth
           AND NOT (CASE WHEN e.a = w.eid THEN e.b ELSE e.a END = ANY(w.path))
    )
    SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object(
              'name', e.name, 'kind', e.kind, 'depth', w.depth,
              'rel', w.rel, 'dir', w.dir, 'world', wo.slug, 'crossed', w.crossed)), '[]'::jsonb)
      INTO v_out
      FROM walk w
      JOIN stewards.world_entities e ON e.entity_id = w.eid
      JOIN stewards.worlds wo        ON wo.world_id = e.world_id
     WHERE w.depth > 0;

    RETURN jsonb_build_object('ok',true,'found',true,'of',v_name,
                              'world',v_slug,'cross',v_cross,'neighbors',v_out);
END $fn$;
COMMENT ON FUNCTION stewards.world_neighbors_tool(jsonb) IS
  '85: cross-world superset of lore_neighbors — BFS over world_edges (intra, origin-world-pinned) AND cross_world_edges (the 82 service seam), so a market/taxonomy entity surfaces the CKE service entities it links to (and vice versa). Each neighbor carries its world slug + crossed flag. Read-only.';

-- ---------------------------------------------------------------------
-- §2 — register the tool (kind sql_fn), read-effect so it never gates.
-- ---------------------------------------------------------------------
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
( 'world_neighbors',
  'Walk relationships for an entity, INCLUDING cross-service links to OTHER worlds — answers "what services does this market pain touch?", "what depends on X across the codebase?", any question that spans the market↔code (or project↔project) boundary that lore_neighbors (single-world) cannot. Args: world_slug, name, depth (1-2), cross (default true; set false for single-world only). Each neighbor reports its world + whether the link crossed a boundary.',
  '{"type":"object","additionalProperties":false,"properties":{"world_slug":{"type":"string"},"name":{"type":"string"},"depth":{"type":"integer"},"cross":{"type":"boolean"}},"required":["world_slug","name"]}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_neighbors_tool"}'::jsonb, 'read', true )
ON CONFLICT (name) DO UPDATE
  SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
      execute_target=EXCLUDED.execute_target, effect_class=EXCLUDED.effect_class, active=true;

-- ---------------------------------------------------------------------
-- §3 — grants.
-- ---------------------------------------------------------------------
-- (a) the loremaster gets world_neighbors (its cross-world reach). Read-only.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('loremaster', 'world_neighbors', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- (b) the cockpit chat agent (work-item-chat) gets the read-only lore tools too.
-- WHY: the "Chat with this world" button opens a session whose FIRST turn is a
-- real loremaster dispatch, but the cockpit's chatSendHandler hardcodes
-- agent_family='work-item-chat' for every FOLLOW-UP turn — so without this grant
-- a second question ("and what services does that touch?") would land on an agent
-- that lacks world_neighbors. Granting the read-only lore tools to the cockpit
-- chat lets follow-ups stay capable (the world grounding lives in session history).
-- All read-only, grounded, cite-first — consistent with work-item-chat's existing
-- read-only retrieval surface (doc_search/doc_get/investigate_session).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'lore_search',     'allow', 'manual'),
  ('work-item-chat', 'lore_entity',     'allow', 'manual'),
  ('work-item-chat', 'lore_neighbors',  'allow', 'manual'),
  ('work-item-chat', 'world_neighbors', 'allow', 'manual'),
  ('work-item-chat', 'world_show',      'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action=EXCLUDED.action, source=EXCLUDED.source;

-- ---------------------------------------------------------------------
-- §4 — re-author the loremaster prompt to name world_neighbors (57 owns the
-- base row; this file sorts after 57 via requires, so this UPDATE wins).
-- Same INSERT…ON CONFLICT DO UPDATE idiom 57 uses; the ONLY change from 57 is
-- the added world_neighbors line in the tool list. Keeps the loremaster read-only.
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
- lore_neighbors (world_slug, name) — walk relationships WITHIN this world for "who serves X / who else is in Y".
- world_neighbors (world_slug, name, cross) — like lore_neighbors, but ALSO follows CROSS-SERVICE links into OTHER worlds. Use it for "what services does this market pain touch?", "what depends on X?", and any question that may span the market↔code or project↔project boundary. Each neighbor reports its world.
- doc_get / book_search — pull the actual source passage behind a source_ref when you want to quote it.

Ground every claim in what you retrieved. Cite the entity by name and, when you quote, the source. If the canon is silent on something, say so plainly — do not invent lore, names, or relationships. You are read-only: you describe the world, you never change it. Be concise and answer the question asked.$PROMPT$,
  0.3, 14
)
ON CONFLICT (family, model_match) DO UPDATE
  SET description=EXCLUDED.description, prompt=EXCLUDED.prompt,
      temperature=EXCLUDED.temperature, steps=EXCLUDED.steps, active=true;

-- =====================================================================
-- End of 85-world-chat.sql
-- =====================================================================
