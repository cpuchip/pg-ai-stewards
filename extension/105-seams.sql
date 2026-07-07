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
