-- =====================================================================
-- smoke-104-105.sql — self-contained smoke for 104-observations.sql +
--   105-seams.sql. Seeds two tiny throwaway worlds + a handful of
--   observations, asserts, cleans up. Mirrors the verify-97-world-wiki-
--   bridge.sql convention (DO block, ASSERT, cleanup, final NOTICE) rather
--   than the tests/virgin-smoke.sql harness — do NOT edit virgin-smoke.sql.
--
-- Usage:
--   scripts/db.sh -f tests/smoke-104-105.sql
--   (or) docker exec -i <container> psql -U stewards -d stewards \
--       -v ON_ERROR_STOP=1 < tests/smoke-104-105.sql
-- =====================================================================

\set ON_ERROR_STOP on

DO $ok104105$
DECLARE
    v_doc_id      text;
    v_obs1        bigint;
    v_obs2        bigint;
    v_obs3        bigint;
    v_res         jsonb;
    v_report      jsonb;
    v_count       int;
BEGIN
    -- ── seed: two tiny worlds sharing exactly one entity NAME (different
    -- kinds — the shared_divergent case) plus one entity shared by name
    -- AND kind (Council — used to build the edge disagreement), plus one
    -- entity unique to each side (the blind spots). 3 entities each side. ──
    PERFORM stewards.world_upsert('smoke-104105-a', 'Smoke World A', 'fixture world A for smoke-104-105', NULL, false);
    PERFORM stewards.world_upsert('smoke-104105-b', 'Smoke World B', 'fixture world B for smoke-104-105', NULL, false);

    PERFORM stewards.world_entity_upsert('smoke-104105-a', 'character', 'Aria', 'A wandering knight.', '{}'::text[], '[]'::jsonb);
    PERFORM stewards.world_entity_upsert('smoke-104105-a', 'faction',   'Council', 'The ruling council.', '{}'::text[], '[]'::jsonb);
    PERFORM stewards.world_entity_upsert('smoke-104105-a', 'place',     'Forge', 'A place found only in A.', '{}'::text[], '[]'::jsonb);
    PERFORM stewards.world_edge_upsert('smoke-104105-a', 'Aria', 'Council', 'commands', 'fixture edge, world A only');

    PERFORM stewards.world_entity_upsert('smoke-104105-b', 'faction',   'Aria', 'Same name, DIFFERENT kind in B.', '{}'::text[], '[]'::jsonb);
    PERFORM stewards.world_entity_upsert('smoke-104105-b', 'faction',   'Council', 'The same ruling council, same kind.', '{}'::text[], '[]'::jsonb);
    PERFORM stewards.world_entity_upsert('smoke-104105-b', 'place',     'Harbor', 'A place found only in B.', '{}'::text[], '[]'::jsonb);
    -- deliberately NO Aria->Council edge in B: this is the edge disagreement.

    v_doc_id := stewards.import_doc('smoke-104105-doc', NULL, 'Smoke 104-105 fixture doc', 'Fixture doc body for smoke-104-105.', '{}'::jsonb, 'doc');

    -- ── §1 — observation_add: a grounded observation ──
    v_res := stewards.observation_add_tool(jsonb_build_object(
        'claim', 'Aria commands the Council in world A',
        'confidence', 'high',
        'fidelity', 'verbatim',
        'source_doc_id', v_doc_id,
        'source_ref', 'fixture line 1',
        'world_slug', 'smoke-104105-a',
        'entity_name', 'Aria',
        'tags', jsonb_build_array('smoke-104-105')
    ));
    ASSERT (v_res->>'ok')::boolean = true, format('OK 104: observation_add should succeed, got %s', v_res);
    v_obs1 := (v_res->>'id')::bigint;
    ASSERT v_obs1 IS NOT NULL, 'OK 104: observation_add should return an id';
    ASSERT (v_res->'observation'->>'world_slug') = 'smoke-104105-a', 'OK 104: returned observation should echo world_slug';
    ASSERT (v_res->'observation'->>'entity_name') = 'Aria', 'OK 104: returned observation should echo entity_name';

    -- a second, unrelated observation (no world/entity, just tagged)
    v_res := stewards.observation_add_tool(jsonb_build_object(
        'claim', 'In world B, Aria holds no command role',
        'confidence', 'medium',
        'fidelity', 'paraphrase',
        'world_slug', 'smoke-104105-b',
        'entity_name', 'Aria',
        'tags', jsonb_build_array('smoke-104-105')
    ));
    ASSERT (v_res->>'ok')::boolean = true, format('OK 104: second observation_add should succeed, got %s', v_res);
    v_obs2 := (v_res->>'id')::bigint;

    -- ── §2 — observation_counter: counter-evidence against obs1 ──
    v_res := stewards.observation_counter_tool(jsonb_build_object(
        'counters', v_obs1,
        'claim', 'Actually the Council commands Aria, not the reverse',
        'confidence', 'low',
        'fidelity', 'inferred',
        'tags', jsonb_build_array('smoke-104-105')
    ));
    ASSERT (v_res->>'ok')::boolean = true, format('OK 104: observation_counter should succeed, got %s', v_res);
    v_obs3 := (v_res->>'id')::bigint;
    ASSERT (SELECT counter_of FROM stewards.observations WHERE id = v_obs3) = v_obs1,
        'OK 104: the countering observation''s counter_of should point at obs1';

    -- observation_counter with an unknown target is rejected, not raised.
    v_res := stewards.observation_counter_tool(jsonb_build_object(
        'counters', 999999999,
        'claim', 'counters a nonexistent observation',
        'confidence', 'low'
    ));
    ASSERT (v_res->>'ok')::boolean = false, 'OK 104: observation_counter should reject an unknown counters target';

    -- ── §3 — confidence/fidelity CHECK violations rejected, at BOTH layers:
    -- the function's own validation (friendly, never raises) AND the raw
    -- table CHECK constraint itself (defense in depth — the function's
    -- validation is not the only thing standing between a bad row and the
    -- table). ──
    v_res := stewards.observation_add_tool(jsonb_build_object('claim', 'bad confidence', 'confidence', 'super-duper-sure'));
    ASSERT (v_res->>'ok')::boolean = false, 'OK 104: observation_add_tool should reject an invalid confidence value';

    v_res := stewards.observation_add_tool(jsonb_build_object('claim', 'bad fidelity', 'confidence', 'high', 'fidelity', 'made-up'));
    ASSERT (v_res->>'ok')::boolean = false, 'OK 104: observation_add_tool should reject an invalid fidelity value';

    BEGIN
        INSERT INTO stewards.observations (claim, confidence) VALUES ('raw insert, bad confidence', 'nonsense');
        RAISE EXCEPTION 'OK 104: expected a check_violation on bad confidence via raw INSERT but it succeeded';
    EXCEPTION WHEN check_violation THEN
        NULL; -- expected: the table's own CHECK constraint holds independent of the function layer
    END;

    BEGIN
        INSERT INTO stewards.observations (claim, confidence, fidelity) VALUES ('raw insert, bad fidelity', 'high', 'nonsense');
        RAISE EXCEPTION 'OK 104: expected a check_violation on bad fidelity via raw INSERT but it succeeded';
    EXCEPTION WHEN check_violation THEN
        NULL; -- expected
    END;

    -- ── §4 — observation_search: FTS + filters ──
    v_res := stewards.observation_search_tool(jsonb_build_object('world_slug', 'smoke-104105-a'));
    ASSERT (v_res->>'ok')::boolean = true, format('OK 104: observation_search by world_slug should succeed, got %s', v_res);
    ASSERT (v_res->>'count')::int = 1, format('OK 104: exactly 1 observation is grounded in world A, got %s', v_res->>'count');

    v_res := stewards.observation_search_tool(jsonb_build_object('confidence', 'high'));
    ASSERT (SELECT count(*) FROM jsonb_array_elements(v_res->'results') r WHERE (r->>'id')::bigint = v_obs1) = 1,
        'OK 104: confidence=high search should include obs1';

    v_res := stewards.observation_search_tool(jsonb_build_object('counter_of', v_obs1));
    ASSERT (v_res->>'count')::int = 1, format('OK 104: exactly 1 observation counters obs1, got %s', v_res->>'count');
    ASSERT (v_res->'results'->0->>'id')::bigint = v_obs3, 'OK 104: the counter_of=obs1 search should surface obs3';

    v_res := stewards.observation_search_tool(jsonb_build_object('query', 'Council'));
    ASSERT (v_res->>'count')::int >= 1, 'OK 104: FTS query "Council" should match at least the obs1/obs3 claims';

    v_res := stewards.observation_search_tool(jsonb_build_object('tags', jsonb_build_array('smoke-104-105')));
    ASSERT (v_res->>'count')::int = 3, format('OK 104: exactly 3 fixture observations carry the smoke-104-105 tag, got %s', v_res->>'count');

    -- ── §5 — seams_report: exact counts on the seeded divergence ──
    v_report := stewards.seams_report('smoke-104105-a', 'smoke-104105-b');
    ASSERT (v_report->>'ok')::boolean = true, format('OK 105: seams_report should succeed, got %s', v_report);

    v_count := jsonb_array_length(v_report->'shared_divergent');
    ASSERT v_count = 2, format('OK 105: expected 2 shared entities (Aria, Council), got %s: %s', v_count, v_report->'shared_divergent');

    ASSERT (v_report->'counts'->>'same_kind_count')::int = 1,
        format('OK 105: exactly 1 shared entity (Council) should have matching kind, got %s', v_report->'counts');
    ASSERT (v_report->'counts'->>'divergent_kind_count')::int = 1,
        format('OK 105: exactly 1 shared entity (Aria) should have a DIFFERENT kind, got %s', v_report->'counts');
    ASSERT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_report->'shared_divergent') s
         WHERE s->>'name' = 'Aria' AND (s->>'same_kind')::boolean = false
           AND s->'a'->>'kind' = 'character' AND s->'b'->>'kind' = 'faction'
    ), format('OK 105: Aria should be reported with same_kind=false, a.kind=character, b.kind=faction, got %s', v_report->'shared_divergent');
    ASSERT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_report->'shared_divergent') s
         WHERE s->>'name' = 'Council' AND (s->>'same_kind')::boolean = true
    ), 'OK 105: Council should be reported with same_kind=true';

    ASSERT jsonb_array_length(v_report->'only_in_a') = 1 AND (v_report->'only_in_a'->>0) = 'Forge',
        format('OK 105: only_in_a should be exactly ["Forge"], got %s', v_report->'only_in_a');
    ASSERT jsonb_array_length(v_report->'only_in_b') = 1 AND (v_report->'only_in_b'->>0) = 'Harbor',
        format('OK 105: only_in_b should be exactly ["Harbor"], got %s', v_report->'only_in_b');

    ASSERT jsonb_array_length(v_report->'edge_disagreements') = 1,
        format('OK 105: expected exactly 1 edge disagreement, got %s: %s', jsonb_array_length(v_report->'edge_disagreements'), v_report->'edge_disagreements');
    ASSERT EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_report->'edge_disagreements') e
         WHERE e->>'src' = 'Aria' AND e->>'dst' = 'Council' AND e->>'rel_type' = 'commands' AND e->>'present_in' = 'a'
    ), format('OK 105: expected the Aria-commands-Council edge, present_in=a, got %s', v_report->'edge_disagreements');

    ASSERT (v_report->'counts'->>'shared_divergent')::int = 2, 'OK 105: counts.shared_divergent should be 2';
    ASSERT (v_report->'counts'->>'only_in_a')::int = 1, 'OK 105: counts.only_in_a should be 1';
    ASSERT (v_report->'counts'->>'only_in_b')::int = 1, 'OK 105: counts.only_in_b should be 1';
    ASSERT (v_report->'counts'->>'edge_disagreements')::int = 1, 'OK 105: counts.edge_disagreements should be 1';

    -- tool wrapper round-trip (jsonb in/out, error-as-jsonb convention).
    ASSERT (stewards.seams_report_tool(jsonb_build_object('world_a', 'smoke-104105-a', 'world_b', 'smoke-104105-b')) ->> 'ok')::boolean = true,
        'OK 105: seams_report_tool should report ok=true for two real worlds';
    ASSERT (stewards.seams_report_tool(jsonb_build_object('world_a', 'smoke-104105-a', 'world_b', 'no-such-world')) ->> 'ok')::boolean = false,
        'OK 105: seams_report_tool should report ok=false (error-as-jsonb) for an unknown world slug';
    ASSERT (stewards.seams_report_tool(jsonb_build_object('world_a', 'smoke-104105-a', 'world_b', 'smoke-104105-a')) ->> 'ok')::boolean = false,
        'OK 105: seams_report_tool should reject comparing a world against itself';

    -- ── clean up: leave zero fixture residue. Observations are deleted
    -- explicitly (world_id/entity_id are ON DELETE SET NULL, not CASCADE,
    -- so deleting the worlds first would ORPHAN them, not remove them).
    -- Worlds CASCADE into world_entities/world_edges (54-loreworks.sql). ──
    DELETE FROM stewards.observations WHERE id IN (v_obs1, v_obs2, v_obs3);
    DELETE FROM stewards.worlds WHERE slug IN ('smoke-104105-a', 'smoke-104105-b');
    DELETE FROM stewards.docs WHERE slug = 'smoke-104105-doc';

    RAISE NOTICE 'OK 104-105: observation_add/observation_search/observation_counter round-trip (grounding, tags, FTS, counter-evidence chain), confidence+fidelity CHECK violations rejected at BOTH the function layer and the raw table constraint, and seams_report correctly finds 2 shared entities (1 same-kind, 1 divergent-kind), 1 blind spot per side, and 1 edge disagreement -- all fixture rows cleaned up';
END;
$ok104105$;

DO $t$ BEGIN RAISE NOTICE '== ALL smoke-104-105 ASSERTIONS PASSED =='; END; $t$;
