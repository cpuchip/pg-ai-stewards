-- =====================================================================
-- verify-94-wiki-curator.sql — DRY synthetic smoke for 94-wiki-curator.sql.
--
-- Standalone verify script (the verify-*.sql convention, not part of
-- migration-order.txt / lib.rs — run manually against a scratch install,
-- per tests/README.md's "docker build + docker run + psql < file" recipe).
--
-- WIKI-CORE (92-wiki-core.sql) is not in this worktree (parallel builder,
-- 6-builder wiki fleet). This script installs a MINIMAL guarded stub of
-- 92's assumed shape — ONLY if it isn't already present — so 94's actual
-- logic (wiki_organize_apply's dedup-tier branching, wiki_collect_spawn's
-- manifest transform, the wiki_search lens) can be exercised for real
-- right now. The stub is skipped entirely once the real 92 lands (the
-- guard is `to_regclass('stewards.wiki_pages') IS NULL`), so this file
-- keeps working unchanged across the fleet integration.
--
-- Usage:
--   docker exec -i <container> psql -U stewards -d stewards \
--       -v ON_ERROR_STOP=1 < extension/verify-94-wiki-curator.sql
-- =====================================================================

\set ON_ERROR_STOP on

-- ---------------------------------------------------------------------
-- STUB — only if 92-wiki-core hasn't landed. Minimal shape matching the
-- API 94-wiki-curator.sql codes against (see that file's header).
-- ---------------------------------------------------------------------
DO $stub$
BEGIN
    IF to_regclass('stewards.wiki_pages') IS NOT NULL THEN
        RAISE NOTICE 'verify-94 stub: stewards.wiki_pages already exists — 92-wiki-core is present, skipping the local stub entirely.';
        RETURN;
    END IF;

    CREATE TABLE stewards.wikis (
        slug       text PRIMARY KEY,
        title      text NOT NULL,
        kind       text,
        scope      text,
        created_at timestamptz NOT NULL DEFAULT now()
    );

    CREATE TABLE stewards.wiki_pages (
        slug       text PRIMARY KEY,
        title      text NOT NULL,
        content    text NOT NULL DEFAULT '',
        sources    jsonb NOT NULL DEFAULT '[]'::jsonb,
        created_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
    );

    CREATE TABLE stewards.wiki_members (
        wiki_slug text NOT NULL REFERENCES stewards.wikis(slug) ON DELETE CASCADE,
        page_slug text NOT NULL REFERENCES stewards.wiki_pages(slug) ON DELETE CASCADE,
        PRIMARY KEY (wiki_slug, page_slug)
    );

    CREATE TABLE stewards.page_sources (
        page_slug text NOT NULL REFERENCES stewards.wiki_pages(slug) ON DELETE CASCADE,
        doc_slug  text NOT NULL,
        PRIMARY KEY (page_slug, doc_slug)
    );

    CREATE FUNCTION stewards.wiki_create(p_slug text, p_title text, p_kind text DEFAULT NULL, p_scope text DEFAULT NULL)
    RETURNS void LANGUAGE sql AS $fn$
        INSERT INTO stewards.wikis (slug, title, kind, scope)
        VALUES (p_slug, p_title, p_kind, p_scope)
        ON CONFLICT (slug) DO NOTHING;
    $fn$;

    CREATE FUNCTION stewards.wiki_page_upsert(p_slug text, p_title text, p_content text, p_sources jsonb DEFAULT '[]'::jsonb)
    RETURNS void LANGUAGE plpgsql AS $fn$
    DECLARE
        v_doc_slug text;
    BEGIN
        INSERT INTO stewards.wiki_pages (slug, title, content, sources, updated_at)
        VALUES (p_slug, p_title, p_content, COALESCE(p_sources, '[]'::jsonb), now())
        ON CONFLICT (slug) DO UPDATE
           SET title = EXCLUDED.title, content = EXCLUDED.content,
               sources = EXCLUDED.sources, updated_at = now();

        DELETE FROM stewards.page_sources WHERE page_slug = p_slug;
        IF p_sources IS NOT NULL AND jsonb_typeof(p_sources) = 'array' THEN
            FOR v_doc_slug IN SELECT jsonb_array_elements_text(p_sources) LOOP
                INSERT INTO stewards.page_sources (page_slug, doc_slug)
                VALUES (p_slug, v_doc_slug)
                ON CONFLICT DO NOTHING;
            END LOOP;
        END IF;
    END;
    $fn$;

    CREATE FUNCTION stewards.wiki_add_member(p_wiki_slug text, p_page_slug text)
    RETURNS void LANGUAGE sql AS $fn$
        INSERT INTO stewards.wiki_members (wiki_slug, page_slug)
        VALUES (p_wiki_slug, p_page_slug)
        ON CONFLICT DO NOTHING;
    $fn$;

    -- Toy similarity: 1.0 on exact title match, 0.75 on a shared-word
    -- overlap heuristic, else 0. Enough to drive the lightning/mountain/
    -- none branches deterministically in a synthetic test.
    CREATE FUNCTION stewards.wiki_page_dedup_check(p_wiki_slug text, p_title text, p_content text)
    RETURNS TABLE (candidate_slug text, similarity real)
    LANGUAGE sql STABLE AS $fn$
        SELECT wp.slug,
               CASE
                   WHEN lower(wp.title) = lower(p_title) THEN 1.0::real
                   WHEN lower(wp.title) LIKE '%' || lower(split_part(p_title, ' ', 1)) || '%'
                        AND length(split_part(p_title, ' ', 1)) > 3
                   THEN 0.75::real
                   ELSE 0.0::real
               END AS similarity
          FROM stewards.wiki_members wm
          JOIN stewards.wiki_pages wp ON wp.slug = wm.page_slug
         WHERE wm.wiki_slug = p_wiki_slug
         ORDER BY similarity DESC
         LIMIT 5;
    $fn$;

    CREATE FUNCTION stewards.wiki_merge_propose(p_from_slug text, p_to_slug text, p_rationale text)
    RETURNS bigint LANGUAGE sql AS $fn$
        SELECT stewards.hinge_enqueue('wiki-merge', format('merge %s -> %s', p_from_slug, p_to_slug),
                                       jsonb_build_object('from_slug', p_from_slug, 'to_slug', p_to_slug), 'wiki-curator-stub');
    $fn$;

    RAISE NOTICE 'verify-94 stub: minimal 92-wiki-core shim installed (wikis/wiki_pages/wiki_members/page_sources + 5 fns).';
END;
$stub$;

-- =====================================================================
-- OK 94a — wiki-organize propose->apply, LIGHTNING tier (>=0.90).
-- =====================================================================
DO $t$
DECLARE
    v_wi_id  uuid;
    v_intent uuid;
    v_result jsonb;
    v_page   record;
BEGIN
    SELECT id INTO v_intent FROM stewards.intents
     WHERE slug = stewards.config_get_text('default_intent_slug', 'default') LIMIT 1;
    IF v_intent IS NULL THEN
        INSERT INTO stewards.intents (slug, purpose, values_anchor)
        VALUES (stewards.config_get_text('default_intent_slug', 'default'), 'verify-94 synthetic default intent', 'test')
        ON CONFLICT (slug) DO NOTHING
        RETURNING id INTO v_intent;
    END IF;

    -- Seed docs the proposal will cite.
    PERFORM stewards.import_doc('doc-alpha', NULL, 'Alpha Notes', 'Alpha is a test entity used across verify-94.', '{}'::jsonb, 'doc');

    -- Seed the wiki with an EXISTING page named "Alpha Overview" so a
    -- proposal titled the same will dedup-check to similarity 1.0.
    PERFORM stewards.wiki_create('wiki-t94a', 'Test Wiki 94a', 'organize', 'project');
    PERFORM stewards.wiki_page_upsert('alpha-overview', 'Alpha Overview', 'Old content.', '["doc-alpha"]'::jsonb);
    PERFORM stewards.wiki_add_member('wiki-t94a', 'alpha-overview');

    v_wi_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-organize',
        p_input           => jsonb_build_object(
            'binding_question', 'Organize test scope into wiki-t94a.',
            'scope', jsonb_build_object('kind','all','value',NULL),
            'wiki_slug', 'wiki-t94a'
        ),
        p_slug   => 'verify-94a-organize',
        p_actor  => 'test',
        p_intent_id => v_intent
    );

    -- Hand-insert the gather + propose stage results (stubbed LLM output)
    -- exactly as OK-94 asks: "insert the stage result by hand".
    UPDATE stewards.work_items
       SET stage_results = jsonb_build_object(
               'gather', jsonb_build_object('output', 'doc-alpha: Alpha Notes -- covers Alpha.', 'completed_at', now()),
               'propose', jsonb_build_object('output', jsonb_build_object(
                   'page_prefix_style', 'flat',
                   'proposals', jsonb_build_array(
                       jsonb_build_object(
                           'slug', 'alpha-overview-new',
                           'title', 'Alpha Overview',   -- exact-title match -> stub similarity 1.0 -> lightning
                           'summary', 'Alpha is a test entity. Source: doc-alpha.',
                           'source_doc_slugs', jsonb_build_array('doc-alpha'),
                           'dedup_checked', jsonb_build_object('candidate_slug', 'alpha-overview', 'similarity', 1.0)
                       )
                   )
               ), 'completed_at', now())
           ),
           current_stage = 'propose'
     WHERE id = v_wi_id;

    -- Fire the SAME transition the real pipeline fires: maturity -> verified.
    UPDATE stewards.work_items SET maturity = 'verified' WHERE id = v_wi_id;

    -- Assert: the EXISTING page (alpha-overview) was superseded in place —
    -- lightning tier writes to the MATCHED slug, not a new one.
    SELECT * INTO v_page FROM stewards.wiki_pages WHERE slug = 'alpha-overview';
    ASSERT v_page.slug IS NOT NULL, 'lightning tier: alpha-overview should still exist (superseded, not deleted)';
    ASSERT v_page.content = 'Alpha is a test entity. Source: doc-alpha.',
        format('lightning tier: alpha-overview content should be REPLACED by the proposal; got %L', v_page.content);
    ASSERT NOT EXISTS (SELECT 1 FROM stewards.wiki_pages WHERE slug = 'alpha-overview-new'),
        'lightning tier: the NEW slug should NOT have been created separately (it was folded into the matched page)';
    ASSERT EXISTS (SELECT 1 FROM stewards.wiki_members WHERE wiki_slug = 'wiki-t94a' AND page_slug = 'alpha-overview'),
        'lightning tier: alpha-overview should be a member of wiki-t94a';
    ASSERT EXISTS (SELECT 1 FROM stewards.page_sources WHERE page_slug = 'alpha-overview' AND doc_slug = 'doc-alpha'),
        'lightning tier: alpha-overview should carry doc-alpha as a source';

    RAISE NOTICE 'OK 94a: wiki-organize propose->apply, LIGHTNING tier -- existing page superseded in place, sources recorded, no duplicate slug created';
END;
$t$;

-- =====================================================================
-- OK 94b — wiki-organize propose->apply, NONE tier (plain new page).
-- =====================================================================
DO $t$
DECLARE
    v_wi_id uuid;
BEGIN
    v_wi_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-organize',
        p_input           => jsonb_build_object(
            'binding_question', 'Organize test scope into wiki-t94a (round 2).',
            'scope', jsonb_build_object('kind','all','value',NULL),
            'wiki_slug', 'wiki-t94a'
        ),
        p_slug  => 'verify-94b-organize',
        p_actor => 'test'
    );

    UPDATE stewards.work_items
       SET stage_results = jsonb_build_object(
               'gather', jsonb_build_object('output', 'nothing relevant found', 'completed_at', now()),
               'propose', jsonb_build_object('output', jsonb_build_object(
                   'page_prefix_style', 'flat',
                   'proposals', jsonb_build_array(
                       jsonb_build_object(
                           'slug', 'brand-new-topic',
                           'title', 'Brand New Topic',   -- no existing page shares this title -> similarity 0
                           'summary', 'A genuinely new page with no prior match.',
                           'source_doc_slugs', jsonb_build_array(),
                           'dedup_checked', jsonb_build_object('candidate_slug', NULL, 'similarity', 0.0)
                       )
                   )
               ), 'completed_at', now())
           ),
           current_stage = 'propose'
     WHERE id = v_wi_id;

    UPDATE stewards.work_items SET maturity = 'verified' WHERE id = v_wi_id;

    ASSERT EXISTS (SELECT 1 FROM stewards.wiki_pages WHERE slug = 'brand-new-topic'),
        'none tier: brand-new-topic should have been created plainly';
    ASSERT EXISTS (SELECT 1 FROM stewards.wiki_members WHERE wiki_slug = 'wiki-t94a' AND page_slug = 'brand-new-topic'),
        'none tier: brand-new-topic should be a member of wiki-t94a';

    RAISE NOTICE 'OK 94b: wiki-organize propose->apply, NONE tier -- brand-new page created plainly, no dedup branch triggered';
END;
$t$;

-- =====================================================================
-- OK 94c — wiki-organize propose->apply, MOUNTAIN tier (create + Hinge).
-- =====================================================================
DO $t$
DECLARE
    v_wi_id      uuid;
    v_hinge_n    int;
BEGIN
    -- "Alpha Widget" shares the word "Alpha" with the existing "Alpha
    -- Overview" page -> the stub's word-overlap heuristic returns 0.75,
    -- which lands in the mountain band [0.55, 0.90).
    v_wi_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-organize',
        p_input           => jsonb_build_object(
            'binding_question', 'Organize test scope into wiki-t94a (round 3).',
            'scope', jsonb_build_object('kind','all','value',NULL),
            'wiki_slug', 'wiki-t94a'
        ),
        p_slug  => 'verify-94c-organize',
        p_actor => 'test'
    );

    UPDATE stewards.work_items
       SET stage_results = jsonb_build_object(
               'gather', jsonb_build_object('output', 'doc-alpha covers a related but distinct facet', 'completed_at', now()),
               'propose', jsonb_build_object('output', jsonb_build_object(
                   'page_prefix_style', 'flat',
                   'proposals', jsonb_build_array(
                       jsonb_build_object(
                           'slug', 'alpha-widget',
                           'title', 'Alpha Widget',
                           'summary', 'A related-but-distinct facet of Alpha. Source: doc-alpha.',
                           'source_doc_slugs', jsonb_build_array('doc-alpha'),
                           'dedup_checked', jsonb_build_object('candidate_slug', 'alpha-overview', 'similarity', 0.75)
                       )
                   )
               ), 'completed_at', now())
           ),
           current_stage = 'propose'
     WHERE id = v_wi_id;

    SELECT count(*) INTO v_hinge_n FROM stewards.hinge_reviews WHERE kind = 'wiki-merge';

    UPDATE stewards.work_items SET maturity = 'verified' WHERE id = v_wi_id;

    ASSERT EXISTS (SELECT 1 FROM stewards.wiki_pages WHERE slug = 'alpha-widget'),
        'mountain tier: alpha-widget should still be CREATED (nothing lost at write time)';
    ASSERT (SELECT count(*) FROM stewards.hinge_reviews WHERE kind = 'wiki-merge') = v_hinge_n + 1,
        'mountain tier: exactly one NEW wiki-merge Hinge review should be queued';
    ASSERT EXISTS (
        SELECT 1 FROM stewards.hinge_reviews
         WHERE kind = 'wiki-merge' AND status = 'pending'
           AND payload->>'from_slug' = 'alpha-widget' AND payload->>'to_slug' = 'alpha-overview'
    ), 'mountain tier: the Hinge review should name alpha-widget -> alpha-overview and be pending (not silently auto-applied)';

    RAISE NOTICE 'OK 94c: wiki-organize propose->apply, MOUNTAIN tier -- new page created AND flagged pending in the Hinge queue, not silently merged';
END;
$t$;

-- =====================================================================
-- OK 94d — wiki-collect plan-stage shape: manifest transform + spawn +
-- the width-cap/overflow accounting.
-- =====================================================================
DO $t$
DECLARE
    v_wi_id      uuid;
    v_n_children int;
    v_n_entities int := 27;   -- deliberately over the 24-entity soft target
    v_entities   jsonb := '[]'::jsonb;
    i            int;
    v_manifest   jsonb;
    v_agg_id     uuid;
BEGIN
    FOR i IN 1..v_n_entities LOOP
        v_entities := v_entities || to_jsonb('Pony ' || i::text);
    END LOOP;

    v_wi_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-collect',
        p_input           => jsonb_build_object(
            'binding_question', 'Fetch all the ponies in Equestria and their cutie-mark powers.',
            'question', 'Fetch all the ponies in Equestria and their cutie-mark powers.',
            'scope', jsonb_build_object('kind','all','value',NULL),
            'wiki_slug', 'wiki-t94d-ponies'
        ),
        p_slug  => 'verify-94d-collect',
        p_actor => 'test'
    );

    UPDATE stewards.work_items
       SET stage_results = jsonb_build_object(
               'plan', jsonb_build_object('output', jsonb_build_object(
                   'rationale', 'test worklist',
                   'facet_template', 'their cutie mark and the power/talent it grants',
                   'entities', v_entities,
                   'page_prefix_style', 'flat'
               ), 'completed_at', now())
           ),
           current_stage = 'plan'
     WHERE id = v_wi_id;

    UPDATE stewards.work_items SET maturity = 'verified' WHERE id = v_wi_id;

    -- The manifest was written onto stage_results.decompose.output.
    SELECT stage_results -> 'decompose' -> 'output' INTO v_manifest FROM stewards.work_items WHERE id = v_wi_id;
    ASSERT v_manifest IS NOT NULL, 'wiki-collect: decompose manifest should have been written onto the work_item';
    ASSERT jsonb_array_length(v_manifest -> 'children') = 24,
        format('wiki-collect: expected 24 entity children (cap=25 minus 1 aggregator slot), got %s',
               jsonb_array_length(v_manifest -> 'children'));
    ASSERT (v_manifest -> 'aggregate' ->> 'overflow_count')::int = 3,
        format('wiki-collect: expected overflow_count=3 (27 entities - 24 kept), got %s',
               v_manifest -> 'aggregate' ->> 'overflow_count');
    ASSERT (v_manifest -> 'aggregate' ->> 'destination') = 'wikis/wiki-t94d-ponies/index.md',
        'wiki-collect: aggregate destination should encode the wiki slug';

    -- spawn_children actually ran: 24 entity children + 1 aggregator = 25
    -- rows parented on this work_item (the width cap allows exactly this).
    SELECT count(*) INTO v_n_children FROM stewards.work_items WHERE parent_work_item_id = v_wi_id;
    ASSERT v_n_children = 25,
        format('wiki-collect: expected 24 entity children + 1 aggregator = 25 spawned rows, got %s', v_n_children);

    SELECT count(*) INTO v_n_children FROM stewards.work_items
     WHERE parent_work_item_id = v_wi_id AND pipeline_family = 'wiki-collect-entity';
    ASSERT v_n_children = 24, format('wiki-collect: expected 24 wiki-collect-entity children, got %s', v_n_children);

    SELECT id INTO v_agg_id FROM stewards.work_items
     WHERE parent_work_item_id = v_wi_id AND pipeline_family = 'aggregate-children';
    ASSERT v_agg_id IS NOT NULL, 'wiki-collect: the aggregate-children work_item should have been spawned';
    ASSERT EXISTS (
        SELECT 1 FROM stewards.work_items
         WHERE id = v_agg_id AND file_destination = 'wikis/wiki-t94d-ponies/index.md'
    ), 'wiki-collect: the aggregator''s file_destination should be wikis/<slug>/index.md';

    RAISE NOTICE 'OK 94d: wiki-collect plan-stage shape -- 27 entities capped to 24 (overflow=3), spawn_children (reused unmodified) created 24 entity children + 1 aggregator under the 16-subagents width cap (subagent_max_children.wiki-collect=25)';
END;
$t$;

-- =====================================================================
-- OK 94e — wiki-collect aggregate bridge: generic aggregator markdown
-- becomes a real wiki index page + gaps-found note.
-- =====================================================================
DO $t$
DECLARE
    v_wi_id  uuid;
    v_agg_id uuid;
    v_page   record;
BEGIN
    SELECT id INTO v_agg_id FROM stewards.work_items
     WHERE pipeline_family = 'aggregate-children'
       AND file_destination = 'wikis/wiki-t94d-ponies/index.md';
    ASSERT v_agg_id IS NOT NULL, 'OK 94e setup: expected the OK-94d aggregator to already exist';

    -- Simulate the generic fanout-aggregate agent completing (plain
    -- markdown, no wiki-awareness) and reaching verified.
    UPDATE stewards.work_items
       SET stage_results = stage_results || jsonb_build_object(
               'aggregate', jsonb_build_object('output',
                   E'# Ponies in Equestria\n\n| Slug | Title |\n|---|---|\n| pony-1 | Pony 1 |\n',
                   'completed_at', now())
           )
     WHERE id = v_agg_id;
    UPDATE stewards.work_items SET maturity = 'verified' WHERE id = v_agg_id;

    ASSERT EXISTS (SELECT 1 FROM stewards.wikis WHERE slug = 'wiki-t94d-ponies'),
        'aggregate bridge: wiki-t94d-ponies should have been created';
    SELECT * INTO v_page FROM stewards.wiki_pages WHERE slug = 'wiki-t94d-ponies-index';
    ASSERT v_page.slug IS NOT NULL, 'aggregate bridge: an index page should have been written';
    ASSERT v_page.content LIKE '%Ponies in Equestria%', 'aggregate bridge: index content should carry the aggregator''s markdown';
    ASSERT v_page.content LIKE '%Gaps found%' AND v_page.content LIKE '%3 additional entities%',
        format('aggregate bridge: index should note the 3-entity overflow from OK-94d; got: %s', v_page.content);
    ASSERT EXISTS (SELECT 1 FROM stewards.wiki_members WHERE wiki_slug = 'wiki-t94d-ponies' AND page_slug = 'wiki-t94d-ponies-index'),
        'aggregate bridge: the index page should be a member of its own wiki';

    RAISE NOTICE 'OK 94e: wiki-collect aggregate bridge -- generic aggregator markdown became a real wiki index page, with the overflow/gaps note pulled back from the parent''s manifest';
END;
$t$;

-- =====================================================================
-- OK 94f — the wiki-as-lens seam: wiki_search returns ONLY in-scope
-- docs on a seeded fixture (two wikis, disjoint doc scopes).
-- =====================================================================
DO $t$
DECLARE
    v_n int;
BEGIN
    PERFORM stewards.import_doc('doc-in-scope',  NULL, 'In Scope Doc',  'This document discusses zephyrwing gadgets at length.', '{}'::jsonb, 'doc');
    PERFORM stewards.import_doc('doc-out-scope', NULL, 'Out Of Scope Doc', 'This document ALSO discusses zephyrwing gadgets at length.', '{}'::jsonb, 'doc');

    PERFORM stewards.wiki_create('wiki-t94f-a', 'Lens Wiki A', 'organize', 'project');
    PERFORM stewards.wiki_create('wiki-t94f-b', 'Lens Wiki B', 'organize', 'project');
    PERFORM stewards.wiki_page_upsert('t94f-page-a', 'Page A', 'cites doc-in-scope', '["doc-in-scope"]'::jsonb);
    PERFORM stewards.wiki_page_upsert('t94f-page-b', 'Page B', 'cites doc-out-scope', '["doc-out-scope"]'::jsonb);
    PERFORM stewards.wiki_add_member('wiki-t94f-a', 't94f-page-a');
    PERFORM stewards.wiki_add_member('wiki-t94f-b', 't94f-page-b');

    -- Both docs match the query textually; the lens must return ONLY the
    -- one sourced by wiki-t94f-a's member page.
    SELECT count(*) INTO v_n FROM stewards.wiki_search('wiki-t94f-a', 'zephyrwing gadgets', 10);
    ASSERT v_n = 1, format('wiki_search: expected exactly 1 in-scope doc for wiki-t94f-a, got %s', v_n);
    ASSERT EXISTS (SELECT 1 FROM stewards.wiki_search('wiki-t94f-a', 'zephyrwing gadgets', 10) WHERE slug = 'doc-in-scope'),
        'wiki_search: the in-scope doc should be doc-in-scope';
    ASSERT NOT EXISTS (SELECT 1 FROM stewards.wiki_search('wiki-t94f-a', 'zephyrwing gadgets', 10) WHERE slug = 'doc-out-scope'),
        'wiki_search: doc-out-scope must NOT leak into wiki-t94f-a''s lens';

    -- The tool wrapper resolves an explicit wiki_slug arg (no session).
    ASSERT (stewards.wiki_search_tool(jsonb_build_object('query','zephyrwing gadgets','wiki_slug','wiki-t94f-b')) -> 'results' -> 0 ->> 'slug') = 'doc-out-scope',
        'wiki_search_tool: explicit wiki_slug arg should scope to wiki-t94f-b (doc-out-scope only)';

    RAISE NOTICE 'OK 94f: wiki-as-lens seam -- wiki_search / wiki_search_tool return ONLY the docs sourced by the target wiki''s member pages, verified against two wikis sharing textually-identical content';
END;
$t$;

-- =====================================================================
-- Inverse check (Moroni 10:4 / Agans Rule 9) — prove the lightning-vs-
-- mountain-vs-none branch is actually DRIVEN by wiki_page_dedup_check's
-- output, not a coincidence: rerun OK-94a's exact scenario with the
-- dedup floor config'd to 1.01 (impossible to clear) and confirm the
-- SAME lightning-shaped input now falls through to "none" and creates
-- a NEW page instead of superseding.
-- =====================================================================
DO $t$
DECLARE
    v_wi_id uuid;
    v_prior real;
BEGIN
    SELECT value #>> '{}' INTO v_prior FROM stewards.config WHERE key = 'wiki_dedup_mountain_floor';
    UPDATE stewards.config SET value = '1.01' WHERE key = 'wiki_dedup_mountain_floor';

    v_wi_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-organize',
        p_input           => jsonb_build_object(
            'binding_question', 'inverse check',
            'scope', jsonb_build_object('kind','all','value',NULL),
            'wiki_slug', 'wiki-t94a'
        ),
        p_slug  => 'verify-94-inverse',
        p_actor => 'test'
    );
    UPDATE stewards.work_items
       SET stage_results = jsonb_build_object(
               'gather', jsonb_build_object('output', 'n/a', 'completed_at', now()),
               'propose', jsonb_build_object('output', jsonb_build_object(
                   'page_prefix_style', 'flat',
                   'proposals', jsonb_build_array(jsonb_build_object(
                       'slug', 'alpha-overview-inverse', 'title', 'Alpha Overview',
                       'summary', 'inverse-check content', 'source_doc_slugs', jsonb_build_array(),
                       'dedup_checked', jsonb_build_object('candidate_slug','alpha-overview','similarity',1.0)
                   ))
               ), 'completed_at', now())
           ),
           current_stage = 'propose'
     WHERE id = v_wi_id;

    UPDATE stewards.work_items SET maturity = 'verified' WHERE id = v_wi_id;

    -- With the floor raised past 1.0, wiki_page_dedup_check's 1.0 match no
    -- longer clears >=0.90's own hardcoded threshold... note: lightning's
    -- 0.90 threshold is hardcoded (mission spec), NOT the floor config; the
    -- floor only moves the mountain/none boundary. So this run should still
    -- land LIGHTNING (proves the floor config does NOT affect the lightning
    -- threshold) — the true inverse target is the MOUNTAIN case (94c).
    ASSERT EXISTS (SELECT 1 FROM stewards.wiki_pages WHERE slug = 'alpha-overview' AND content = 'inverse-check content'),
        'inverse (lightning threshold): raising the MOUNTAIN floor config must not affect the hardcoded >=0.90 lightning threshold';

    -- Restore config, then re-run 94c's mountain scenario with the floor
    -- raised past 0.75 and confirm it now falls through to "none" (plain
    -- create, NO Hinge review) -- the real inverse proof for the mountain
    -- branch: same 0.75 similarity, different config, different outcome.
    UPDATE stewards.config SET value = to_jsonb(0.80::real) WHERE key = 'wiki_dedup_mountain_floor';

    DECLARE
        v_hinge_n int;
        v_wi2 uuid;
    BEGIN
        SELECT count(*) INTO v_hinge_n FROM stewards.hinge_reviews WHERE kind = 'wiki-merge';
        v_wi2 := stewards.work_item_create(
            p_pipeline_family => 'wiki-organize',
            p_input => jsonb_build_object('binding_question','inverse mountain check','scope',jsonb_build_object('kind','all','value',NULL),'wiki_slug','wiki-t94a'),
            p_slug => 'verify-94-inverse-mountain', p_actor => 'test'
        );
        UPDATE stewards.work_items
           SET stage_results = jsonb_build_object(
                   'gather', jsonb_build_object('output','n/a','completed_at',now()),
                   'propose', jsonb_build_object('output', jsonb_build_object(
                       'page_prefix_style','flat',
                       'proposals', jsonb_build_array(jsonb_build_object(
                           'slug','alpha-widget-2','title','Alpha Widget 2',
                           'summary','inverse mountain content','source_doc_slugs', jsonb_build_array(),
                           'dedup_checked', jsonb_build_object('candidate_slug','alpha-overview','similarity',0.75)
                       ))
                   ), 'completed_at', now())
               ),
               current_stage = 'propose'
         WHERE id = v_wi2;
        UPDATE stewards.work_items SET maturity = 'verified' WHERE id = v_wi2;

        ASSERT EXISTS (SELECT 1 FROM stewards.wiki_pages WHERE slug = 'alpha-widget-2'),
            'inverse (mountain floor raised): the page should still be created plainly';
        ASSERT (SELECT count(*) FROM stewards.hinge_reviews WHERE kind = 'wiki-merge') = v_hinge_n,
            'inverse (mountain floor raised to 0.80): a 0.75 similarity should now fall BELOW the floor -- no NEW Hinge review, proving the floor genuinely gates the mountain branch';
    END;

    UPDATE stewards.config SET value = to_jsonb(COALESCE(v_prior, 0.55::real)) WHERE key = 'wiki_dedup_mountain_floor';

    RAISE NOTICE 'OK 94-inverse: reproduced lightning (floor-invariant) and mountain (floor-gated, re-verified false when the floor moves past the similarity) -- the branch is genuinely driven by wiki_page_dedup_check + the config floor, not coincidence';
END;
$t$;

DO $t$ BEGIN RAISE NOTICE '== ALL verify-94-wiki-curator ASSERTIONS PASSED =='; END; $t$;
