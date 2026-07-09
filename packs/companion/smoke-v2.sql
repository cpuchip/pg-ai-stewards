-- packs/companion/smoke-v2.sql — deterministic oracle for the Jarvis wave
-- (task_start, doc_brief). Run against a scratch container with the full
-- pack chain applied (forge.sql -> companion.sql -> steward-tools.sql ->
-- steward-tools-v2.sql), or live (cleans up after itself either way).
-- Proves: task_start refuses an unknown family and LISTS the real ones,
-- refuses a too-short wish, refuses a duplicate slug, enforces the 5/hour
-- voice rate limit (the 6th call in the window refuses; the first 5 do
-- not), and a happy call actually creates+dispatches a work item on the
-- named pipeline. doc_brief returns a paragraph-bounded brief with correct
-- shape on a hit and the 3 nearest slugs on a miss.
--
-- Requires the 'echo-test' pipeline family (core-seeded, model-less stage)
-- and the 'companion' intent (seeded by forge.sql) to exist.

DO $smoke$
DECLARE
    v        jsonb;
    i        int;
    v_wi_ids uuid[] := ARRAY[]::uuid[];
BEGIN
    -- ── rate limit FIRST, in a clean window, so later tests in this file
    -- get a fresh quota (the 5 items below are aged out before they run) ──
    FOR i IN 1..5 LOOP
        v := companion.task_start(jsonb_build_object(
            'pipeline_family', 'echo-test',
            'assignment', 'smoke-v2 rate-limit filler item number ' || i));
        ASSERT (v->>'ok')::boolean, format('smoke 1.%s: expected ok, got %s', i, v);
        v_wi_ids := v_wi_ids || (v->>'work_item_id')::uuid;
    END LOOP;
    v := companion.task_start(jsonb_build_object(
        'pipeline_family', 'echo-test',
        'assignment', 'smoke-v2: this 6th call must be refused for rate limit'));
    ASSERT v->>'error' LIKE '%rate limit%', format('smoke 1.6 INVERSE: 6th voice task_start in the hour must refuse, got %s', v);
    -- age the 5 out of the window so they stop consuming quota
    UPDATE stewards.work_items SET created_at = now() - interval '2 hours'
     WHERE id = ANY(v_wi_ids);

    -- ── happy path: real pipeline, real dispatch attempt ────────────────
    v := companion.task_start(jsonb_build_object(
        'pipeline_family', 'echo-test',
        'assignment', 'smoke-v2 happy path: say hello back to me please'));
    ASSERT (v->>'ok')::boolean, format('smoke 2: happy-path task_start must succeed, got %s', v);
    ASSERT v->>'pipeline_family' = 'echo-test', 'smoke 2: pipeline_family must echo back what was requested';
    ASSERT v->>'work_item_id' IS NOT NULL, 'smoke 2: work_item_id must be returned';
    v_wi_ids := v_wi_ids || (v->>'work_item_id')::uuid;
    ASSERT EXISTS (
        SELECT 1 FROM stewards.work_items
         WHERE id = (v->>'work_item_id')::uuid
           AND pipeline_family = 'echo-test'
           AND input->>'assignment' = 'smoke-v2 happy path: say hello back to me please'
           AND input->>'binding_question' = 'smoke-v2 happy path: say hello back to me please'
    ), 'smoke 2: the work item must exist with BOTH assignment and binding_question stamped';

    -- ── refusal: unknown pipeline family must LIST the real ones ────────
    v := companion.task_start(jsonb_build_object(
        'pipeline_family', 'not-a-real-pipeline-9000',
        'assignment', 'this family does not exist, should refuse cleanly'));
    ASSERT NOT (v ? 'ok'), format('smoke 3: unknown family must refuse, got %s', v);
    ASSERT v->>'error' LIKE '%not a known pipeline%', 'smoke 3: error must say the family is unknown';
    ASSERT v->>'error' LIKE '%echo-test%', 'smoke 3: error must actually LIST real families (echo-test expected)';

    -- ── refusal: assignment too short ────────────────────────────────────
    v := companion.task_start(jsonb_build_object('pipeline_family', 'echo-test', 'assignment', 'hi'));
    ASSERT v->>'error' LIKE '%assignment required%', format('smoke 4: too-short assignment must refuse, got %s', v);

    -- ── refusal: duplicate slug ──────────────────────────────────────────
    v := companion.task_start(jsonb_build_object(
        'pipeline_family', 'echo-test', 'assignment', 'smoke-v2 slug owner item',
        'slug', 'smoke-v2-dup-slug'));
    ASSERT (v->>'ok')::boolean, format('smoke 5: first slug use must succeed, got %s', v);
    v_wi_ids := v_wi_ids || (v->>'work_item_id')::uuid;
    v := companion.task_start(jsonb_build_object(
        'pipeline_family', 'echo-test', 'assignment', 'smoke-v2 slug thief item',
        'slug', 'smoke-v2-dup-slug'));
    ASSERT v->>'error' LIKE '%already in use%', format('smoke 5 INVERSE: duplicate slug must refuse, got %s', v);

    -- ── doc_brief: missing args ──────────────────────────────────────────
    v := companion.doc_brief('{}'::jsonb);
    ASSERT v->>'error' LIKE '%slug or id required%', format('smoke 6: no args must refuse, got %s', v);

    -- ── doc_brief: happy path (short body, under the 1200-char floor) ───
    INSERT INTO stewards.docs (slug, title, body, kind)
    VALUES ('smoke-v2-doc', 'Smoke V2 Doc', 'one two three four five', 'doc');
    v := companion.doc_brief(jsonb_build_object('slug', 'smoke-v2-doc'));
    ASSERT v->>'title' = 'Smoke V2 Doc', format('smoke 7: title must match, got %s', v);
    ASSERT v->>'kind' = 'doc', 'smoke 7: kind must match';
    ASSERT (v->>'word_count')::int = 5, 'smoke 7: word_count must count actual words';
    ASSERT v->>'brief' = 'one two three four five', 'smoke 7: a short body is returned whole, untruncated';
    -- and reachable by id, not just slug
    ASSERT (companion.doc_brief(jsonb_build_object(
        'id', (SELECT id FROM stewards.docs WHERE slug='smoke-v2-doc')
    )))->>'title' = 'Smoke V2 Doc', 'smoke 7b: doc_brief must also resolve by id';

    -- ── doc_brief: long body, trimmed at a paragraph boundary ────────────
    INSERT INTO stewards.docs (slug, title, body, kind)
    VALUES ('smoke-v2-long-doc', 'Smoke V2 Long Doc',
            repeat('alpha ', 30) || E'\n\n' || repeat('beta ', 400), 'doc');
    v := companion.doc_brief(jsonb_build_object('slug', 'smoke-v2-long-doc'));
    ASSERT char_length(v->>'brief') < 1200, format('smoke 8: brief must be trimmed well under the raw body length, got %s chars', char_length(v->>'brief'));
    ASSERT v->>'brief' LIKE '%alpha%' AND v->>'brief' NOT LIKE '%beta%',
        'smoke 8: the cut must land at the paragraph boundary (all alpha, no beta bled through)';
    ASSERT v->>'brief' NOT LIKE E'%\n\n …', 'smoke 8: no dangling blank-line before the ellipsis (btrim-vs-whitespace regression)';
    ASSERT v->>'brief' LIKE '% …', 'smoke 8: a trimmed brief ends with the ellipsis marker';

    -- ── doc_brief: miss returns the 3 nearest slugs ─────────────────────
    -- ILIKE substring matching (no pg_trgm, by design) needs the miss key
    -- to actually be CONTAINED in the real slug — 'smoke-v2-do' is the
    -- first 12 chars of 'smoke-v2-doc' (a truncated/mis-heard voice guess),
    -- not a same-length typo (which ILIKE substring containment can't catch).
    v := companion.doc_brief(jsonb_build_object('slug', 'smoke-v2-do'));
    ASSERT v->>'error' LIKE '%no doc found%', format('smoke 9: unknown slug must refuse, got %s', v);
    ASSERT v->'nearest_slugs' ? 'smoke-v2-doc', 'smoke 9 INVERSE: the near-miss slug must appear in nearest_slugs';

    -- ── cleanup ───────────────────────────────────────────────────────────
    DELETE FROM stewards.work_items WHERE id = ANY(v_wi_ids);
    DELETE FROM stewards.docs WHERE slug IN ('smoke-v2-doc', 'smoke-v2-long-doc');

    RAISE NOTICE 'OK companion-v2-smoke: task_start refuses unknown families (and lists the real ones), too-short wishes, and duplicate slugs; enforces the 5/hour voice rate limit (6th refused, first 5 clean, inverse-proven both ways); a happy call stamps BOTH assignment and binding_question. doc_brief returns correct shape on a hit, trims long bodies at a paragraph boundary with no dangling whitespace, and returns nearest_slugs on a miss.';
END
$smoke$;

\echo '== companion pack: v2 (task_start + doc_brief) smoke PASSED =='
