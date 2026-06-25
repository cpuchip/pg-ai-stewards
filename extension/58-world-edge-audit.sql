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
