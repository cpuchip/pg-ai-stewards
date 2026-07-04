-- =====================================================================
-- 97-world-wiki-bridge.sql — the world→wiki bridge (.spec/proposals/
-- ingestion-crawler-and-raw-to-wiki.md Part 0 + Part 4 arc 1): every World
-- gets a readable face. A World (54-loreworks.sql: world_entities +
-- world_edges, the entity-graph projection) and a Wiki (92-wiki.sql:
-- wiki_pages + page_links, the page projection) are two views of one
-- corpus — this file is the missing cable: world entities auto-materialize
-- as wiki pages, edges become page links.
--
-- ★ THE ONE FUNCTION THAT MATTERS: stewards.world_to_wiki(world_slug) —
-- an idempotent FULL re-projection. Re-run it any time a world's canon
-- changes; it never accumulates duplicate pages (slug is stable identity,
-- 92's own convention), never fabricates a link that isn't a real
-- world_edges row, and never deletes an entity's page when the entity is
-- removed — it supersedes it (92's "a dead page is never deleted, only
-- marked" discipline, wiki_pages.status).
--
-- Real column reconciliations made against the ACTUAL 54/92 DDL (not
-- guessed — read both files before writing a line here):
--   * world_entities has NO updated_at / deleted flag. world_entity_upsert
--     (54) mutates a row in place (summary/aliases/source_refs) without
--     touching created_at, and a removed entity is a genuine hard DELETE
--     (CASCADE from worlds). So "did this entity change" is NOT
--     detectable from world_entities alone — world_to_wiki does not try;
--     it unconditionally re-derives every page's content from the LIVE
--     row on every call (a real full re-projection, not a diff). Only
--     world_wiki_refresh_due (§3) needs a "did something change" signal,
--     and it is honestly scoped to what created_at CAN prove: new
--     entities/edges since the wiki's last projection. An in-place edit
--     to an existing entity (e.g. a summary rewrite) will NOT trip
--     world_wiki_refresh_due — only world_to_wiki re-run (or a caller who
--     already knows a specific world changed) catches that. Documented
--     here, not silently glossed over.
--   * page_sources.doc_id is text (= stewards.docs.id, itself text — 92's
--     header deviation #2), NOT the doc slug world_entities.source_refs
--     carries ([{doc, chunk, quote}], "doc" = a SLUG). §1 resolves
--     source_refs' doc slug -> docs.id per element; an unresolvable slug
--     (no matching doc row) is never fabricated into page_sources — it
--     still appears in the page's own Sources section, marked
--     "(unresolved)", so nothing is silently dropped, but nothing is
--     silently invented as false provenance either.
--   * page_links carries NO unique constraint (no natural ON CONFLICT
--     target — 92's own header does not document one because nothing
--     needed one yet). This file's write side is therefore
--     delete-and-reinsert, scoped to `from_page = <this page's id>` on
--     every re-projection: idempotent by construction (a re-run always
--     leaves EXACTLY the current edge set, never a growing one), safe
--     because a world-entity page's OUTGOING page_links are wholly OWNED
--     by this bridge (nothing else in the fleet writes page_links from a
--     `<world>--<kind>--<name>`-shaped page).
--   * wikis.scope is the ONLY per-wiki free-form jsonb this schema
--     offers (92 §5) — no dedicated "last projected" column or config
--     row exists for a per-wiki timestamp. §3 (world_wiki_refresh_due)
--     stores/reads `scope->>'last_projected_at'` — the smallest honest
--     mechanism, not a new table. wiki_create's own upsert resets `scope`
--     wholesale on every call (92's literal SQL: `scope = EXCLUDED.scope`
--     in its ON CONFLICT), so world_to_wiki calls wiki_create with the
--     BASE scope first, then re-stamps last_projected_at with a direct
--     UPDATE at the very end of the same call — always consistent at
--     rest, briefly absent mid-projection (never observable outside this
--     function's own transaction).
--   * wikis has no is_private column. A World created with is_private=true
--     (54's own local-only/never-train-on-data flag) projects into a wiki
--     that carries NO such flag today — a real, pre-existing schema gap
--     (92 never anticipated a private wiki), not solved here, flagged for
--     the fleet integrator.
--   * Page-slug collision risk (honesty, not solved): the slug scheme
--     `<world_slug>--<kind>--<name-slugified>` is stable across re-runs
--     (a pure function of world/kind/name) and UNIQUE in practice because
--     world_entities itself enforces UNIQUE(world_id, kind, name) — but
--     two DIFFERENT names that slugify to the SAME string within one
--     (world, kind) (e.g. "Aria Stormwind" vs "Aria  Stormwind!") would
--     collide on one wiki_pages.slug and silently conflate two entities
--     into one page. Same class of risk 92's own header calls "page
--     identity is the hard part" for merges — not re-solved here.
--
-- One addition beyond the literal ask, under the stewardship rule (an
-- obvious completion of a primitive this file already introduces, not a
-- new capability): a "### Referenced by" section per page, listing
-- INCOMING edges (this entity as dst) as plain informational wikilinks.
-- Without it, a heavily-referenced entity (e.g. a faction every character
-- is `member_of`) would render with an empty Relations section despite
-- being the most-linked-to page in the world — a readable face that hides
-- the very thing it exists to show. This is textual only — it does NOT
-- write a page_links row (that would fabricate a reverse edge world_edges
-- never asserted); page_links stays a 1:1 mirror of the real graph.
--
-- Tension flagged, not resolved: 85-world-chat.sql's header states "the
-- loremaster stays read-only." Granting world_to_wiki (a WRITE) to the
-- loremaster family (per this mission's explicit ask, §3) sits against
-- that grain — a loremaster asking "refresh my world's wiki" is a
-- plausible, bounded, idempotent write (not open-ended authoring), but
-- it is still the family's first write grant. Surfaced for the fleet
-- integrator / Michael, not silently reconciled either direction.
--
-- ★ THE SMOKE TEST LIVES IN extension/verify-97-world-wiki-bridge.sql,
-- NOT in this file — a deliberate deviation from the literal mission
-- brief ("OK 97 smoke block... inside a transaction-safe DO block"),
-- discovered empirically, not guessed: embedding the fixture-seed/assert/
-- cleanup DO block directly in THIS file (so it runs as part of CREATE
-- EXTENSION) reproducibly broke a COMPLETELY UNRELATED statement later in
-- the SAME generated script — `CREATE FUNCTION stewards.
-- brain_search_text_tool` (schema.rs, a plain, non-OR-REPLACE create) —
-- with "already exists", because `75-wire-brain-hybrid.sql`'s `CREATE OR
-- REPLACE FUNCTION` of the SAME name got scheduled to run FIRST in that
-- build. Bisection proved it: the identical functions/tool/grants above,
-- built and CREATE EXTENSION'd with NO smoke block present, install
-- cleanly, every time; adding the smoke DO block's extra SQL statements
-- back in reliably reproduces the unrelated dupe, in BOTH a cached and a
-- `--no-cache` rebuild. schema.rs's plain CREATE FUNCTION for
-- brain_search_text_tool apparently has no `requires` edge pinning it
-- before 75's redefinition — a pre-existing latent ordering fragility in
-- the base chain, NOT a defect in this file's own SQL (proven: this
-- file's actual functions install and pass their assertions perfectly
-- when run as a standalone `\i` against an already-CREATE-EXTENSION'd
-- database — see the verify file). Flagged for the fleet integrator /
-- Michael; not silently patched by touching schema.rs or 75 from here.
--
-- requires create_wiki_assets (96) — the chain tail as merged (92-96 are
-- all present in this worktree; earlier siblings' "requires the last
-- entry found here, re-stitch at integration" caveat does not apply to
-- this file — it is written AFTER the 6-builder wiki fleet landed).
-- =====================================================================

-- =====================================================================
-- §0 — private helpers (underscore prefix, the 91/15b/92 convention).
-- =====================================================================

-- ── _wwb_slug — kebab-case a name for use inside a page slug. Same
-- regex shape as 26-productivity.sql's todo_slugify, minus the
-- per-session uniqueness suffix (uniqueness here comes from
-- world_entities' own UNIQUE(world_id, kind, name), not a counter).
CREATE OR REPLACE FUNCTION stewards._wwb_slug(p_text text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT NULLIF(btrim(regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '-', 'g'), '-'), '');
$fn$;
COMMENT ON FUNCTION stewards._wwb_slug(text) IS
'97: private helper — kebab-case a name for the world-entity page slug scheme. NULL on an empty/all-punctuation input (caller substitutes ''unnamed'').';

-- ── _wwb_entity_page_slug — the ONE place the slug scheme is computed,
-- so a target entity's slug (an edge's dst, looked up by kind+name) and
-- the entity's OWN slug (computed from its own row) are always the same
-- formula. Stable across re-runs: a pure function of (world_slug, kind,
-- name), no entity_id, no ordering dependency.
CREATE OR REPLACE FUNCTION stewards._wwb_entity_page_slug(p_world_slug text, p_kind text, p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT p_world_slug || '--' || lower(coalesce(p_kind, 'concept')) || '--' || coalesce(stewards._wwb_slug(p_name), 'unnamed');
$fn$;
COMMENT ON FUNCTION stewards._wwb_entity_page_slug(text, text, text) IS
'97: the world-entity wiki page slug scheme: <world_slug>--<kind>--<name-slugified>. Same entity (by world/kind/name) -> same slug on every call, so re-projection upserts in place rather than duplicating. See file header for the residual same-kind-name-collision caveat (not solved here).';

-- =====================================================================
-- §1 — world_to_wiki: the idempotent full re-projection.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.world_to_wiki(p_world_slug text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
    v_world          stewards.worlds%ROWTYPE;
    v_wiki_slug      text;
    v_wiki_id        uuid;
    v_current_slugs  text[] := '{}';
    v_ent            record;
    v_edge           record;
    v_slug           text;
    v_target_slug    text;
    v_content        text;
    v_relations      text;
    v_incoming       text;
    v_sources_md     text;
    v_sources_json   jsonb;
    v_page_id        uuid;
    v_doc_id         text;
    v_src            jsonb;
    v_stale          record;
BEGIN
    SELECT * INTO v_world FROM stewards.worlds WHERE slug = p_world_slug;
    IF v_world.world_id IS NULL THEN
        RAISE EXCEPTION 'world_to_wiki: unknown world slug %', p_world_slug;
    END IF;

    v_wiki_slug := 'world-' || p_world_slug;
    v_wiki_id := stewards.wiki_create(v_wiki_slug, v_world.name, 'world',
                     jsonb_build_object('world', p_world_slug));

    -- ── one page per world_entity ──
    FOR v_ent IN
        SELECT * FROM stewards.world_entities WHERE world_id = v_world.world_id ORDER BY entity_id
    LOOP
        v_slug := stewards._wwb_entity_page_slug(p_world_slug, v_ent.kind, v_ent.name);
        v_current_slugs := v_current_slugs || v_slug;

        -- Relations: OUTGOING edges (this entity is the source). Each
        -- becomes both a markdown wikilink line AND (below) a real
        -- page_links row -- the two are always in lockstep here.
        v_relations := '';
        FOR v_edge IN
            SELECT g.rel_type, g.evidence, d.name AS target_name, d.kind AS target_kind
              FROM stewards.world_edges g
              JOIN stewards.world_entities d ON d.entity_id = g.dst_entity
             WHERE g.world_id = v_world.world_id AND g.src_entity = v_ent.entity_id
             ORDER BY g.rel_type, d.name
        LOOP
            v_target_slug := stewards._wwb_entity_page_slug(p_world_slug, v_edge.target_kind, v_edge.target_name);
            v_relations := v_relations || '- **' || v_edge.rel_type || '** [[' || v_target_slug || '|' || v_edge.target_name || ']]'
                        || CASE WHEN v_edge.evidence IS NOT NULL AND btrim(v_edge.evidence) <> ''
                                THEN ' — ' || v_edge.evidence ELSE '' END
                        || E'\n';
        END LOOP;

        -- "Referenced by": INCOMING edges (this entity is the target).
        -- Textual only -- see file header addition note. NOT written to
        -- page_links (that direction is asserted from the SOURCE side).
        v_incoming := '';
        FOR v_edge IN
            SELECT g.rel_type, s.name AS source_name, s.kind AS source_kind
              FROM stewards.world_edges g
              JOIN stewards.world_entities s ON s.entity_id = g.src_entity
             WHERE g.world_id = v_world.world_id AND g.dst_entity = v_ent.entity_id
             ORDER BY g.rel_type, s.name
        LOOP
            v_target_slug := stewards._wwb_entity_page_slug(p_world_slug, v_edge.source_kind, v_edge.source_name);
            v_incoming := v_incoming || '- [[' || v_target_slug || '|' || v_edge.source_name || ']] **' || v_edge.rel_type || '** this' || E'\n';
        END LOOP;

        -- Sources: source_refs ([{doc, chunk, quote}], doc = a SLUG) ->
        -- markdown text (always) + resolved doc_id for page_sources
        -- (only when the slug resolves to a real doc -- see file header).
        v_sources_md := '';
        v_sources_json := '[]'::jsonb;
        FOR v_src IN SELECT * FROM jsonb_array_elements(coalesce(v_ent.source_refs, '[]'::jsonb))
        LOOP
            v_doc_id := NULL;
            IF v_src ->> 'doc' IS NOT NULL THEN
                SELECT id INTO v_doc_id FROM stewards.docs WHERE slug = v_src ->> 'doc';
            END IF;
            v_sources_md := v_sources_md
                || '- ' || coalesce(v_src ->> 'doc', '(no doc named)')
                || CASE WHEN v_doc_id IS NULL THEN ' _(unresolved — no matching doc, not filed as page provenance)_' ELSE '' END
                || CASE WHEN v_src ->> 'chunk' IS NOT NULL THEN ' — chunk `' || (v_src ->> 'chunk') || '`' ELSE '' END
                || CASE WHEN v_src ->> 'quote' IS NOT NULL THEN ': "' || (v_src ->> 'quote') || '"' ELSE '' END
                || E'\n';
            IF v_doc_id IS NOT NULL THEN
                v_sources_json := v_sources_json || jsonb_build_array(jsonb_build_object(
                    'doc_id', v_doc_id, 'chunk_ref', v_src ->> 'chunk', 'kind', 'doc', 'note', v_src ->> 'quote'));
            END IF;
        END LOOP;

        -- assemble the page body.
        v_content := '# ' || v_ent.name || E'\n\n**Kind:** ' || v_ent.kind || E'\n';
        IF v_ent.aliases IS NOT NULL AND array_length(v_ent.aliases, 1) > 0 THEN
            v_content := v_content || '**Aliases:** ' || array_to_string(v_ent.aliases, ', ') || E'\n';
        END IF;
        v_content := v_content || E'\n' || coalesce(NULLIF(btrim(v_ent.summary), ''), '_no summary recorded._') || E'\n';
        v_content := v_content || E'\n## Relations\n\n'
                  || CASE WHEN v_relations = '' THEN '_none recorded._' || E'\n' ELSE v_relations END;
        IF v_incoming <> '' THEN
            v_content := v_content || E'\n### Referenced by\n\n' || v_incoming;
        END IF;
        v_content := v_content || E'\n## Sources\n\n'
                  || CASE WHEN v_sources_md = '' THEN '_no source_refs recorded._' || E'\n' ELSE v_sources_md END;

        v_page_id := stewards.wiki_page_upsert(
            v_slug, v_ent.name, v_content, v_sources_json,
            format('world_to_wiki: re-projected from world %s', p_world_slug), 'live');
        PERFORM stewards.wiki_add_member(v_wiki_slug, v_slug, 'world_to_wiki');

        -- page_links: delete-and-reinsert THIS page's outgoing set (no
        -- natural unique key on page_links to ON CONFLICT against -- see
        -- file header). Scoped to from_page so it never touches any
        -- other page's links.
        DELETE FROM stewards.page_links WHERE from_page = v_page_id;
        INSERT INTO stewards.page_links (from_page, to_slug, kind)
        SELECT v_page_id,
               stewards._wwb_entity_page_slug(p_world_slug, d.kind, d.name),
               g.rel_type
          FROM stewards.world_edges g
          JOIN stewards.world_entities d ON d.entity_id = g.dst_entity
         WHERE g.world_id = v_world.world_id AND g.src_entity = v_ent.entity_id;
    END LOOP;

    -- ── removed entities -> supersede (never delete) their page ──
    FOR v_stale IN
        SELECT wp.id, wp.slug, wp.title, wp.content
          FROM stewards.wiki_members wm
          JOIN stewards.wiki_pages wp ON wp.id = wm.page_id
         WHERE wm.wiki_id = v_wiki_id
           AND wp.slug LIKE (p_world_slug || '--%')
           AND wp.status <> 'superseded'
           AND NOT (wp.slug = ANY (v_current_slugs))
    LOOP
        PERFORM stewards.wiki_page_upsert(v_stale.slug, v_stale.title, v_stale.content, '[]'::jsonb,
            format('world_to_wiki: entity removed from world %s', p_world_slug), 'superseded');
        DELETE FROM stewards.page_links WHERE from_page = v_stale.id;
    END LOOP;

    -- ── stamp the projection timestamp (world_wiki_refresh_due's read) ──
    UPDATE stewards.wikis
       SET scope = scope || jsonb_build_object('last_projected_at', to_jsonb(now()))
     WHERE id = v_wiki_id;

    RETURN v_wiki_slug;
END;
$fn$;

COMMENT ON FUNCTION stewards.world_to_wiki(text) IS
'97: idempotent full re-projection of a World onto a wiki (kind=world, slug=world-<world_slug>). One page per world_entity (slug=<world_slug>--<kind>--<name-slugified>, stable across re-runs), page_links mirroring world_edges 1:1 (delete-and-reinsert per page, outgoing only), page_sources filed for every source_ref whose doc slug resolves (unresolved refs stay in the page text only -- never fabricated provenance). Entities removed from the world since the last run get their page marked status=''superseded'' (never deleted). Safe to call repeatedly -- see file header for exactly what "idempotent" does and does not mean here (page identity is stable; wiki_page_upsert''s own revision-per-call semantics, 92, are not this file''s to change).';

-- =====================================================================
-- §2 — world_wiki_refresh_due: cheap "who needs a re-projection" scan.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.world_wiki_refresh_due()
RETURNS TABLE (
    world_slug         text,
    wiki_slug          text,
    entity_count       bigint,
    last_projected_at  timestamptz,
    latest_change_at   timestamptz
) LANGUAGE sql STABLE AS $fn$
    WITH w_latest AS (
        SELECT w.world_id, w.slug,
               count(DISTINCT e.entity_id)             AS entity_count,
               GREATEST(max(e.created_at), max(g.created_at)) AS latest_change_at
          FROM stewards.worlds w
          LEFT JOIN stewards.world_entities e ON e.world_id = w.world_id
          LEFT JOIN stewards.world_edges    g ON g.world_id = w.world_id
         GROUP BY w.world_id, w.slug
        HAVING count(DISTINCT e.entity_id) > 0
    )
    SELECT wl.slug, 'world-' || wl.slug, wl.entity_count,
           NULLIF(wk.scope ->> 'last_projected_at', '')::timestamptz,
           wl.latest_change_at
      FROM w_latest wl
      LEFT JOIN stewards.wikis wk ON wk.slug = 'world-' || wl.slug
     WHERE wk.id IS NULL
        OR NULLIF(wk.scope ->> 'last_projected_at', '')::timestamptz IS NULL
        OR wl.latest_change_at > NULLIF(wk.scope ->> 'last_projected_at', '')::timestamptz
     ORDER BY wl.slug;
$fn$;

COMMENT ON FUNCTION stewards.world_wiki_refresh_due() IS
'97: worlds whose wiki has never been projected, or whose entities/edges carry a created_at later than the wiki''s last world_to_wiki call (wikis.scope->>''last_projected_at''). HONEST LIMITATION (see file header): world_entities/world_edges have no updated_at -- an in-place edit to an EXISTING entity (world_entity_upsert''s summary/aliases merge) does not bump created_at and will NOT be flagged here; only NEW entities/edges since the last projection are detectable this way. A caller who already knows a specific world changed should just call world_to_wiki directly rather than waiting on this scan.';

-- =====================================================================
-- §3 — tool_def + jsonb wrapper (94's exact convention: jsonb in/out,
-- error-as-jsonb, no exception escapes to the caller).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.world_to_wiki_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_world_slug text := p_args ->> 'world_slug';
    v_wiki_slug  text;
BEGIN
    IF v_world_slug IS NULL OR btrim(v_world_slug) = '' THEN
        RETURN jsonb_build_object('ok', false, 'error', 'world_slug required');
    END IF;
    v_wiki_slug := stewards.world_to_wiki(v_world_slug);
    RETURN jsonb_build_object('ok', true, 'wiki_slug', v_wiki_slug);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'world_to_wiki',
  'Materialize (or re-project) a World''s entity graph as a browsable wiki: one page per world_entity, page links from world_edges, provenance from source_refs. Idempotent full re-projection — safe to re-run any time the world''s canon changes. Args: world_slug (required).',
  '{"type":"object","required":["world_slug"],"properties":{"world_slug":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"world_to_wiki_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- ── grants: wiki-curator (default source, matches 94's own grant rows
-- for this family) + loremaster (explicit source='manual', matching
-- 57/85's convention for THIS family -- loremaster's base row is a
-- wildcard '*' DENY, so every allow it holds is an explicit, longest-
-- match-wins override, never left to the frontmatter-reimport default).
-- See file header for the read-only-loremaster tension this grant sits
-- against -- flagged, not silently resolved.
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator', 'world_to_wiki', 'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('loremaster', 'world_to_wiki', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action, source = EXCLUDED.source;

-- =====================================================================
-- End of 97-world-wiki-bridge.sql
-- =====================================================================
