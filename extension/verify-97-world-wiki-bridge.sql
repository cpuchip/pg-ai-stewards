-- =====================================================================
-- verify-97-world-wiki-bridge.sql — DRY synthetic smoke for
-- 97-world-wiki-bridge.sql (the world->wiki bridge).
--
-- Standalone verify script (the verify-*.sql convention, not part of
-- migration-order.txt / lib.rs — run manually against a scratch install,
-- per tests/README.md's "docker build + docker run + psql < file" recipe
-- and the verify-94-wiki-curator.sql precedent this file mirrors).
--
-- WHY THIS IS STANDALONE AND NOT EMBEDDED IN 97-world-wiki-bridge.sql
-- ITSELF (the mission brief's literal ask was an embedded DO block):
-- empirically, embedding this exact fixture-seed/assert/cleanup block
-- inside 97-world-wiki-bridge.sql (so it ran as part of CREATE EXTENSION)
-- reproducibly broke an UNRELATED statement later in the same generated
-- script — schema.rs's plain `CREATE FUNCTION stewards.
-- brain_search_text_tool` started failing with "already exists" because
-- 75-wire-brain-hybrid.sql's `CREATE OR REPLACE FUNCTION` of the same
-- name got scheduled to run FIRST in that build. Bisection proved the
-- bridge's own SQL (world_to_wiki, world_wiki_refresh_due,
-- world_to_wiki_tool, the tool_def + grants) installs cleanly via CREATE
-- EXTENSION with NO smoke block present, every time; re-adding this exact
-- DO block's statement count back into that same file reliably
-- reproduced the unrelated dupe, in both a cached and a --no-cache
-- rebuild. That points at a pre-existing latent ordering fragility in
-- the base chain (schema.rs's plain CREATE FUNCTION for
-- brain_search_text_tool has no `requires` edge pinning it before 75's
-- redefinition) — not a defect in this bridge's logic, which is exactly
-- what running THIS file proves: every assertion below passes when the
-- bridge's functions are exercised as a standalone `\i` against an
-- already-CREATE-EXTENSION'd database. Flagged for the fleet integrator /
-- Michael in 97-world-wiki-bridge.sql's own header; not silently patched
-- by touching schema.rs or 75 from here.
--
-- Usage:
--   docker exec -i <container> psql -U stewards -d stewards \
--       -v ON_ERROR_STOP=1 < extension/verify-97-world-wiki-bridge.sql
-- =====================================================================

\set ON_ERROR_STOP on

DO $ok97$
DECLARE
    v_world_id    bigint;
    v_doc_id      text;
    v_wiki_slug   text;
    v_page1_slug  text := 'wwb-test-world--character--aria-stormwind';
    v_page2_slug  text := 'wwb-test-world--faction--the-storm-wardens';
    v_page1       stewards.wiki_pages%ROWTYPE;
    v_page2       stewards.wiki_pages%ROWTYPE;
    v_rev_before  int;
    v_rev_after   int;
BEGIN
    -- ── seed: a tiny fixture world (2 entities + 1 edge + source_refs) ──
    PERFORM stewards.world_upsert('wwb-test-world', 'WWB Test World', 'a fixture world for OK 97', NULL, false);
    SELECT world_id INTO v_world_id FROM stewards.worlds WHERE slug = 'wwb-test-world';

    v_doc_id := stewards.import_doc('wwb-test-doc', NULL, 'WWB Test Doc', 'Fixture doc body for OK 97.', '{}'::jsonb, 'doc');

    PERFORM stewards.world_entity_upsert('wwb-test-world', 'character', 'Aria Stormwind',
        'A wandering knight.', ARRAY['Aria'],
        jsonb_build_array(jsonb_build_object('doc', 'wwb-test-doc', 'chunk', 'intro', 'quote', 'Aria rides at dawn.')));
    PERFORM stewards.world_entity_upsert('wwb-test-world', 'faction', 'The Storm Wardens',
        'A militant order.', '{}'::text[], '[]'::jsonb);
    PERFORM stewards.world_edge_upsert('wwb-test-world', 'Aria Stormwind', 'The Storm Wardens', 'member_of', 'stated in the intro');

    -- ── run the projection ──
    v_wiki_slug := stewards.world_to_wiki('wwb-test-world');
    ASSERT v_wiki_slug = 'world-wwb-test-world',
        format('OK 97: expected wiki slug world-wwb-test-world, got %s', v_wiki_slug);
    ASSERT EXISTS (SELECT 1 FROM stewards.wikis WHERE slug = v_wiki_slug AND kind = 'world'),
        'OK 97: the wiki should exist with kind=world';
    ASSERT (SELECT count(*) FROM stewards.wiki_members wm JOIN stewards.wikis w ON w.id = wm.wiki_id
             WHERE w.slug = v_wiki_slug) = 2,
        'OK 97: exactly 2 pages should be members of the world wiki';

    SELECT * INTO v_page1 FROM stewards.wiki_pages WHERE slug = v_page1_slug;
    ASSERT v_page1.slug IS NOT NULL, 'OK 97: the Aria Stormwind page should exist';
    ASSERT v_page1.content LIKE '%## Relations%' AND v_page1.content LIKE '%member_of%' AND v_page1.content LIKE '%Storm Wardens%',
        'OK 97: Aria''s page should carry a Relations section naming the member_of edge to the Storm Wardens';
    ASSERT v_page1.content LIKE '%## Sources%' AND v_page1.content LIKE '%wwb-test-doc%',
        'OK 97: Aria''s page should carry a Sources section citing wwb-test-doc';
    ASSERT EXISTS (SELECT 1 FROM stewards.page_links pl
                    WHERE pl.from_page = v_page1.id AND pl.to_slug = v_page2_slug AND pl.kind = 'member_of'),
        'OK 97: page_links should carry the member_of edge from Aria''s page to the Storm Wardens'' page';
    ASSERT EXISTS (SELECT 1 FROM stewards.page_sources ps WHERE ps.page_id = v_page1.id AND ps.doc_id = v_doc_id),
        'OK 97: Aria''s page should file wwb-test-doc as a RESOLVED source (doc_id filled)';

    -- ── idempotent re-run: same page id, revision count bumps sanely ──
    SELECT count(*) INTO v_rev_before FROM stewards.wiki_page_revisions WHERE page_id = v_page1.id;
    v_wiki_slug := stewards.world_to_wiki('wwb-test-world');
    SELECT * INTO v_page2 FROM stewards.wiki_pages WHERE slug = v_page1_slug;
    ASSERT v_page2.id = v_page1.id, 'OK 97: re-run must resolve to the SAME page id (slug is stable identity)';
    SELECT count(*) INTO v_rev_after FROM stewards.wiki_page_revisions WHERE page_id = v_page1.id;
    ASSERT v_rev_after = v_rev_before + 1,
        format('OK 97: an identical re-run should bump the revision count by exactly 1 (wiki_page_upsert''s own per-call semantics, 92 -- was %s, now %s)', v_rev_before, v_rev_after);

    -- ── entity update -> page revision bumps AND new content lands ──
    PERFORM stewards.world_entity_upsert('wwb-test-world', 'character', 'Aria Stormwind',
        'A wandering knight who broke her oath.', '{}'::text[], '[]'::jsonb);
    PERFORM stewards.world_to_wiki('wwb-test-world');
    SELECT * INTO v_page2 FROM stewards.wiki_pages WHERE slug = v_page1_slug;
    ASSERT v_page2.content LIKE '%broke her oath%',
        'OK 97: an entity summary update should land in the re-projected page content';
    SELECT count(*) INTO v_rev_after FROM stewards.wiki_page_revisions WHERE page_id = v_page1.id;
    ASSERT v_rev_after = v_rev_before + 2,
        'OK 97: the entity-update re-projection should have appended one further revision';

    -- ── removed entity -> its page is SUPERSEDED, not deleted ──
    DELETE FROM stewards.world_entities WHERE world_id = v_world_id AND name = 'The Storm Wardens';
    PERFORM stewards.world_to_wiki('wwb-test-world');
    ASSERT EXISTS (SELECT 1 FROM stewards.wiki_pages WHERE slug = v_page2_slug AND status = 'superseded'),
        'OK 97: removing an entity should supersede (not delete) its wiki page on the next projection';

    -- ── world_wiki_refresh_due: flags this world after a post-projection
    -- entity was added (the honest new-row-only detection, see header).
    -- NOTE: now() is frozen at transaction START in Postgres, so within
    -- this ONE enclosing transaction every plain `DEFAULT now()` timestamp
    -- (world_to_wiki's last_projected_at stamp AND world_entities.created_at)
    -- is identical -- a real production gap between separate statements
    -- would show this naturally, but a same-transaction smoke test cannot.
    -- clock_timestamp() (wall-clock, advances mid-transaction) forces the
    -- fixture row's created_at genuinely later so this assertion actually
    -- exercises the ">" comparison instead of "not observable here".
    PERFORM stewards.world_entity_upsert('wwb-test-world', 'item', 'Signal Banner', NULL, '{}'::text[], '[]'::jsonb);
    UPDATE stewards.world_entities SET created_at = clock_timestamp()
     WHERE world_id = v_world_id AND kind = 'item' AND name = 'Signal Banner';
    ASSERT EXISTS (SELECT 1 FROM stewards.world_wiki_refresh_due() WHERE world_slug = 'wwb-test-world'),
        'OK 97: world_wiki_refresh_due should list wwb-test-world once a NEW entity postdates its last projection';

    -- ── tool wrapper: jsonb in/out, error-as-jsonb (94's convention) ──
    ASSERT (stewards.world_to_wiki_tool(jsonb_build_object('world_slug', 'wwb-test-world')) ->> 'ok')::boolean = true,
        'OK 97: world_to_wiki_tool should report ok=true for a real world';
    ASSERT (stewards.world_to_wiki_tool('{}'::jsonb) ->> 'ok')::boolean = false,
        'OK 97: world_to_wiki_tool should report ok=false (error-as-jsonb) when world_slug is missing';

    -- ── clean up: leave zero fixture residue (CASCADEs handle the rest:
    -- wiki_pages -> wiki_page_revisions/wiki_members/page_sources/
    -- page_links(from_page); wikis -> any remaining wiki_members;
    -- worlds -> world_entities/world_edges; docs -> doc_versions) ──
    DELETE FROM stewards.wiki_pages WHERE slug LIKE 'wwb-test-world--%';
    DELETE FROM stewards.wikis WHERE slug = 'world-wwb-test-world';
    DELETE FROM stewards.worlds WHERE slug = 'wwb-test-world';
    DELETE FROM stewards.docs WHERE slug = 'wwb-test-doc';

    RAISE NOTICE 'OK 97: world->wiki bridge -- wiki materialized (kind=world), 2 pages, a Relations-section wikilink backed by a real page_links row for the member_of edge, Sources filed with doc_id resolved, an identical re-run resolves to the SAME page id with a sane +1 revision bump, an entity-summary update lands new content and a further +1 revision, removing an entity supersedes (never deletes) its page, world_wiki_refresh_due flags a world with a post-projection new entity, and world_to_wiki_tool round-trips jsonb ok/error-as-jsonb -- all fixture rows cleaned up';
END;
$ok97$;

DO $t$ BEGIN RAISE NOTICE '== ALL verify-97-world-wiki-bridge ASSERTIONS PASSED =='; END; $t$;
