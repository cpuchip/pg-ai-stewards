-- =====================================================================
-- 94-wiki-curator.sql — the wiki-curator pipelines (info-dump -> auto-
-- organize; entities -> a fanned-out per-entity wiki).
-- =====================================================================
-- Michael's 5am vision (.spec/proposals/lab-and-wiki.md Part 2): dumping
-- knowledge in should cost NOTHING at write time; the substrate organizes
-- it. Two shapes, both LLM-wiki-flavored (study/yt/hQvwMj7IJe4-fable-
-- karpathy-llm-wiki.md names the flat-vs-nested heuristic and why page-
-- identity governance matters — not present in this worktree at authoring
-- time; the heuristic is applied directly from the mission brief below).
--
--   (a) wiki-organize — an existing source-doc set becomes wiki pages.
--       gather -> propose -> apply. apply is DETERMINISTIC (mirrors
--       apply_agent_proposal's shape, 13-research-pipelines): lightning-
--       tier dedup (similarity >= 0.90) auto-supersedes in place; mountain-
--       tier creates the new page AND queues a human merge review via the
--       Hinge (39-hinge) rather than silently multiplying near-duplicates.
--
--   (b) wiki-collect — "go fetch all the ponies in Equestria, then fan out
--       to their cutie marks / powers, then run research against that
--       subset." plan (LLM: entities + shared facet template) -> fan-out
--       (the EXISTING spawn_children machinery, 14-fanout-brainstorm,
--       reused byte-for-byte — not redefined) -> aggregate (the existing
--       generic aggregate-children pipeline, bridged into a real wiki page
--       by an additive trigger below).
--
-- ★ INTEGRATION POINT — WIKI-CORE (92-wiki-core.sql) is NOT present in this
-- worktree (parallel builder, 6-builder wiki fleet). WIKI-CORE owns:
--
--   TABLES   stewards.wikis        (slug PK, title, kind, scope, ...)
--            stewards.wiki_pages   (slug PK, title, content, ...)
--            stewards.wiki_members (wiki_slug, page_slug)
--            stewards.page_sources (page_slug, doc_slug, ...)
--
--   FUNCTIONS  wiki_create(p_slug, p_title, p_kind, p_scope)
--              wiki_page_upsert(p_slug, p_title, p_content, p_sources jsonb)
--              wiki_add_member(p_wiki_slug, p_page_slug)
--              wiki_page_dedup_check(p_wiki_slug, p_title, p_content)
--                RETURNS TABLE(candidate_slug text, similarity real)
--              wiki_merge_propose(p_from_slug, p_to_slug, p_rationale)
--
-- Every call into these (below) is a plain function call inside a plpgsql
-- body — Postgres does not validate a referenced object's existence until
-- the statement actually EXECUTES, so this file CREATEs cleanly against a
-- 00-91-only chain (verified: `docker build` + a scratch install below
-- succeed with 92 absent) and will start WORKING the moment 92 lands,
-- with zero changes to this file. This is the same forward-ref discipline
-- 08-gates.sql already relies on for its 10/13/14 callees (see that
-- file's header). Call sites that assume a specific 92 return SHAPE are
-- marked "-- INTEGRATION POINT" so a signature mismatch is easy to find.
--
-- What IS mine to own outright (not 92's): the wiki-as-lens seam
-- (wiki_search — restricts a search to one wiki's member pages' source
-- docs) and the glue that makes wiki-collect's fan-out land as a real
-- wiki page without touching core (08-gates.sql, 14-fanout-brainstorm.sql)
-- at all:
--
--   * spawn_children (14) is reused UNMODIFIED. Its trigger path
--     (on_maturity_verified, 08) only fires it for pipeline_family=
--     'decompose-fanout' — hardcoded, and rightly so (it is not this
--     file's place to make that dispatcher generic for every future
--     fan-out consumer). So wiki_collect_spawn() below does what
--     start_brainstorm (14) already does for the brainstorm lenses:
--     write a decompose-shaped manifest directly onto stage_results.
--     decompose.output and call stewards.spawn_children(...) directly.
--     spawn_children itself has NO pipeline_family gate — only the
--     TRIGGER does — so this is a legitimate, unmodified reuse of the
--     exact same public entry point start_brainstorm uses.
--   * The aggregator spawn_children creates is ALWAYS pipeline_family=
--     'aggregate-children' (hardcoded in spawn_children) running the
--     generic fanout-aggregate agent, which has no idea wiki_page_upsert
--     exists. Rather than fork spawn_children or re-author the shared
--     'aggregate-children' pipeline (both would ripple across every OTHER
--     fan-out consumer in the fleet/codebase), wiki_collect_aggregate_
--     bridge() is a NEW, narrowly-scoped additive trigger (same pattern
--     25-corpus.sql already uses for work_items_fill_project: a SEPARATE
--     trigger object, not a re-author of an existing one) that recognizes
--     ITS OWN aggregator runs (file_destination matches wikis/<slug>/
--     index.md, a path only wiki_collect_spawn ever sets) and turns the
--     generic markdown output into a real wiki_page + membership.
--
-- Bounded per 16-subagents "as-is": the width/depth caps already enforced
-- by trigger_enforce_subagent_depth are NOT reimplemented here. wiki-
-- collect's fan-out parent gets its OWN per-pipeline override row (the
-- exact mechanism decompose-fanout already uses — 'subagent_max_children.
-- <pipeline_family>' — just a new DATA row, not a new mechanism), sized
-- for a ~24-entity worklist + 1 aggregator slot. wiki_collect_spawn()
-- reads the EFFECTIVE cap at spawn time (not a hardcoded 24) and reports
-- any entities beyond it as "overflow" on the wiki's index page rather
-- than raising past the trigger's hard stop.
-- requires create_core_compat (91) — installs at the tail of the core
-- chain. When 92-wiki-core lands, this file's `requires` in src/lib.rs
-- should move to depend on it directly (currently points at 91 because
-- 92/93 are not in this worktree — flagged for the fleet integration).
-- =====================================================================

-- ---------------------------------------------------------------------
-- SECTION 0 — config knobs.
-- ---------------------------------------------------------------------
INSERT INTO stewards.config (key, value, description) VALUES
  ('wiki_dedup_mountain_floor', '0.55',
   'wiki-organize/wiki-collect dedup tier floor: similarity in [floor, 0.90) is "mountain" (create + flag for human merge review via the Hinge); below floor is a plain new page; >=0.90 is "lightning" (auto-supersede the matched page).'),
  ('subagent_max_children.wiki-collect', '25',
   'wiki-collect fans out to at most ~24 entities + 1 aggregator (25 total children under the parent). Same knob decompose-fanout already uses (16-subagents); this is a new DATA row for a new pipeline, not a new mechanism.')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, description = EXCLUDED.description;

-- =====================================================================
-- SECTION 1 — the wiki-as-lens seam (mine to own; the ONE new tool
-- this file introduces, alongside the two pipeline-entry-point tools).
--
-- The research pipelines already reach for a corpus/project lens via
-- pool_search_tool (72-hybrid-rrf-everywhere): it derives a project from
-- the caller's session -> work_item.project_association, then scopes to
-- stewards.project_neighbors(project). The chat UI's "empty-chat lens
-- picker" (rich-docs P3d, cmd/stewards-ui/api/chat.go) is the same idea
-- one layer up: a "project:<name>" TargetRef grounds a whole conversation
-- in a corpus via a prompt instruction that tells the agent to doc_search
-- within it.
--
-- wiki_search is the SAME shape, scoped to a wiki instead of a project:
-- restrict to the doc_slugs that are page_sources of a wiki's member
-- pages. This is additive — it does NOT touch pool_search_tool/
-- doc_search_tool (owned by 71/72, shared by every other pipeline in the
-- fleet); it is a wholly new, narrow function + tool_def + tool_group.
-- =====================================================================

-- ── wiki_scope_doc_slugs — the doc set a wiki's gather stage may see.
-- INTEGRATION POINT: assumes wiki_members(wiki_slug, page_slug) and
-- page_sources(page_slug, doc_slug) — see the header. Degrades to an
-- empty set (not an error) via the caller's exception guard until 92 lands.
CREATE OR REPLACE FUNCTION stewards.wiki_scope_doc_slugs(p_wiki_slug text)
RETURNS TABLE (doc_slug text)
LANGUAGE sql STABLE AS $fn$
    SELECT DISTINCT ps.doc_slug
      FROM stewards.wiki_members wm
      JOIN stewards.page_sources ps ON ps.page_slug = wm.page_slug
     WHERE wm.wiki_slug = p_wiki_slug;
$fn$;
COMMENT ON FUNCTION stewards.wiki_scope_doc_slugs(text) IS
'94-wiki-curator: the doc slugs in scope for a wiki lens — every doc that is a page_source of one of the wiki''s member pages. INTEGRATION POINT: assumes 92-wiki-core''s wiki_members/page_sources shape.';

-- ── wiki_search — doc_search's FTS shape, restricted to one wiki's scope.
CREATE OR REPLACE FUNCTION stewards.wiki_search(
    p_wiki_slug text,
    p_query     text,
    p_limit     int DEFAULT 10
) RETURNS TABLE (slug text, kind text, title text, snippet text, rank real)
LANGUAGE sql STABLE AS $fn$
    SELECT d.slug, d.kind, d.title,
           ts_headline('english', coalesce(d.body, ''), q,
                       'MaxWords=20, MinWords=10, ShortWord=3') AS snippet,
           ts_rank(d.body_tsv, q) AS rank
      FROM stewards.docs d,
           websearch_to_tsquery('english', p_query) q
     WHERE d.body_tsv @@ q
       AND d.slug IN (SELECT doc_slug FROM stewards.wiki_scope_doc_slugs(p_wiki_slug))
     ORDER BY rank DESC
     LIMIT greatest(p_limit, 1);
$fn$;
COMMENT ON FUNCTION stewards.wiki_search(text, text, int) IS
'94-wiki-curator: the wiki lens — FTS over stewards.docs restricted to doc_slugs sourced by wiki_slug''s member pages. The wiki-scoped sibling of doc_search/pool_search (project lens).';

CREATE OR REPLACE FUNCTION stewards.wiki_search_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $FN$
DECLARE
    v_sess      text := p_args->>'_session_id';
    v_wiki_slug text;
    v_query     text := p_args->>'query';
    v_limit     int  := COALESCE(NULLIF(p_args->>'limit','')::int, 10);
    v_rows      jsonb;
BEGIN
    IF v_query IS NULL OR btrim(v_query) = '' THEN
        RETURN '{"error":"query required"}'::jsonb;
    END IF;

    -- Session-derived wiki scope first (mirrors pool_search_tool's project
    -- resolution), explicit arg as the fallback for direct/tool callers.
    SELECT w.input->>'wiki_slug' INTO v_wiki_slug
      FROM stewards.work_items w WHERE v_sess = ANY(w.session_ids) ORDER BY w.id DESC LIMIT 1;
    IF v_wiki_slug IS NULL THEN v_wiki_slug := p_args->>'wiki_slug'; END IF;
    IF v_wiki_slug IS NULL OR btrim(v_wiki_slug) = '' THEN
        RETURN '{"error":"wiki_slug required (no session-scoped wiki and none passed explicitly)"}'::jsonb;
    END IF;

    BEGIN
        SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_rows
          FROM stewards.wiki_search(v_wiki_slug, v_query, v_limit) t;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'wiki_search_tool: query failed (likely 92-wiki-core not yet installed): %', SQLERRM;
        RETURN jsonb_build_object('error', 'wiki search unavailable', 'detail', SQLERRM);
    END;

    RETURN jsonb_build_object('wiki_slug', v_wiki_slug, 'results', v_rows);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'wiki_search',
  'Search restricted to ONE wiki''s scope: only docs that are sources of that wiki''s member pages. The wiki-scoped sibling of doc_search/pool_search — use this when your stage''s scope names a wiki (scope.kind=''wiki'') instead of a project. Args: query (required), wiki_slug (optional if your session is already scoped to one wiki), limit.',
  '{"type":"object","required":["query"],"properties":{"query":{"type":"string"},"wiki_slug":{"type":"string"},"limit":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_search_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

-- ── wiki-tools group — bundles the wiki_search lens (mine) with the
-- wiki-core verb names (92's, referenced by pattern only — an unmatched
-- pattern in a tool_group just contributes nothing, per resolve_tool_scope's
-- fail-open contract, 37-tool-groups).
INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('wiki-tools', 'the wiki surface: search a wiki''s scope, create/upsert pages, add members, dedup-check, propose merges',
     ARRAY['wiki_search','wiki_create','wiki_page_upsert','wiki_add_member','wiki_page_dedup_check','wiki_merge_propose'])
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, tool_patterns=EXCLUDED.tool_patterns;

-- =====================================================================
-- SECTION 2 — agents. Deny-by-default holds (schema.rs agent_tool_perms):
-- each family below gets EXACTLY the tools its stage needs, nothing more.
-- =====================================================================

-- ── wiki-curator — the reading/reasoning/proposing persona. Used by
-- wiki-organize's gather+propose stages and wiki-collect's plan stage.
-- Never writes a page itself (apply/spawn are deterministic SQL below);
-- it reads, searches, and — for propose — is REQUIRED to call
-- wiki_page_dedup_check before finalizing any page proposal.
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES (
  'wiki-curator', '*',
  'Reads a source-doc set (or an entity/facet question) and organizes it: proposes wiki pages with provenance, checks for duplicates before proposing, and names the page-space shape (flat vs nested). Never writes a page directly — a deterministic apply step does that.',
  'primary',
  $PROMPT$You are the Wiki Curator. You turn scattered source material into a clean, browsable wiki, and you turn broad questions ("go fetch all the X, then look at their Y") into a scoped worklist someone else can research in parallel.

Principles:
- Provenance-first. Every page section traces to a source you actually read this session. Quote text VERBATIM only when you have the source in front of you; paraphrase otherwise — "X reports that..." is honest, an unverified direct quote is not. No unsourced claims.
- Concise over exhaustive. A tight page that gets read beats a sprawling one that doesn't. Merge closely related material into ONE page rather than one page per source if they cover the same topic.
- Dedup before you propose. Call wiki_page_dedup_check on every candidate page before finalizing it — a near-duplicate should supersede or flag for merge, not multiply silently.
- Flat when uniform, nested when heterogeneous. If the material is all one kind of thing, use a flat slug space. If it's a genuine mix of categories, prefix slugs by category so the wiki reads as sections, not one flat pile. Match the page-space shape to the material's actual structure; don't force a convention that isn't there.

You are one stage in a multi-stage pipeline. Do your stage's job, follow its output format and tool budget exactly, and hand off cleanly — do not perform the NEXT stage's job (you may search and reason; you do not upsert pages yourself unless your specific stage instructions say so).$PROMPT$,
  0.4
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, prompt = EXCLUDED.prompt, temperature = EXCLUDED.temperature, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator', 'fs_read',               'allow'),
  ('wiki-curator', 'fs_list',               'allow'),
  ('wiki-curator', 'fs_search',             'allow'),
  ('wiki-curator', 'doc_search',            'allow'),
  ('wiki-curator', 'doc_get',               'allow'),
  ('wiki-curator', 'doc_similar',           'allow'),
  ('wiki-curator', 'pool_search',           'allow'),
  ('wiki-curator', 'wiki_search',           'allow'),
  ('wiki-curator', 'wiki_page_dedup_check', 'allow'),
  ('wiki-curator', 'work_item_list',        'allow'),
  ('wiki-curator', 'work_item_show',        'allow'),
  -- discovery: plan needs to actually find the entity set for "go fetch
  -- all the X" style questions.
  ('wiki-curator', 'web_search_exa',        'allow'),
  ('wiki-curator', 'fetch_url',             'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- ── wiki-curator-entity — the leaf researcher-writer. One child per
-- entity in wiki-collect's fan-out. Does its own research AND its own
-- writing; does not re-delegate (subagent-leaf discipline, 16-subagents).
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES (
  'wiki-curator-entity', '*',
  'Researches ONE entity from a wiki-collect worklist and writes ONE page for it. A leaf worker in a fan-out — does not re-delegate.',
  'primary',
  $PROMPT$You are a Wiki Curator researching ONE entity to add to a wiki. You are a leaf worker in a fan-out: sibling workers are each researching a different entity from the same worklist, in parallel.

Your job, in order:
1. Research your assigned entity with your tools (web_search_exa, fetch_url, doc_search, pool_search, wiki_search).
2. Before writing, call wiki_page_dedup_check to see if this entity already has a page in this wiki.
   - similarity >= 0.90: this is the SAME entity already documented. Read the existing page and UPDATE it with anything new you found (still via wiki_page_upsert, same slug) rather than creating a duplicate.
   - otherwise: proceed to create a new page.
3. Call wiki_page_upsert(slug, title, content, sources). Content is PROVENANCE-FIRST — every claim traces to a source you actually read this session. Quote VERBATIM only when the source text is in front of you; paraphrase otherwise ("X reports that..." is honest, an unverified direct quote is not). Concise over exhaustive. If your search turns up nothing credible, say so plainly in the page rather than inventing detail.
4. Call wiki_add_member(wiki_slug, slug) so the page joins the wiki.

You do not re-delegate — do your own research and writing directly. End your turn once wiki_page_upsert and wiki_add_member have both succeeded; your final message is one line confirming what you wrote and its slug.$PROMPT$,
  0.5
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, prompt = EXCLUDED.prompt, temperature = EXCLUDED.temperature, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator-entity', 'web_search_exa',        'allow'),
  ('wiki-curator-entity', 'fetch_url',             'allow'),
  ('wiki-curator-entity', 'doc_search',            'allow'),
  ('wiki-curator-entity', 'doc_get',                'allow'),
  ('wiki-curator-entity', 'pool_search',           'allow'),
  ('wiki-curator-entity', 'wiki_search',           'allow'),
  ('wiki-curator-entity', 'wiki_page_dedup_check', 'allow'),
  ('wiki-curator-entity', 'wiki_page_upsert',      'allow'),
  ('wiki-curator-entity', 'wiki_add_member',       'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- SECTION 3 — wiki-organize pipeline: gather -> propose -> (apply,
-- deterministic, fires on propose's maturity->verified via the additive
-- trigger below — NOT a pipeline stage; mirrors apply_agent_proposal's
-- shape, 13-research-pipelines).
--
-- input shape: {"scope": {"kind": "project"|"wiki"|"all", "value": text
-- or null}, "wiki_slug": text}. scope is the LENS the gather stage reads
-- FROM; wiki_slug is the DESTINATION wiki pages get organized INTO (often
-- the same wiki as scope.value when re-organizing a wiki's own docs, but
-- may differ — e.g. organizing a project's docs into a brand-new wiki).
-- =====================================================================
DO $seed$
DECLARE
    v_gather_template  text;
    v_propose_template text;
    v_stages           jsonb;
BEGIN

v_gather_template :=
$T$Scope: {{input.scope}}
Destination wiki: {{input.wiki_slug}}

## YOUR TASK — gather the source doc set for this scope

Gather the FULL set of source documents in scope so the next stage (propose) can decide how to organize them into wiki pages.

- If scope.kind = "wiki": call wiki_search (wiki_slug = scope.value) to list every doc that's already a source for that wiki's member pages, PLUS doc_search/pool_search for anything newly relevant that isn't in the wiki yet.
- If scope.kind = "project": use pool_search (already scoped to your project neighborhood by the session).
- If scope.kind = "all": use doc_search broadly.

For each doc kept, record: slug, kind, title, one-line summary of what it covers.

## HARD CONSTRAINTS

- Maximum 5 rounds of tool calls.
- Output budget ~2KB — list slugs + summaries, don't transcribe bodies.
- End-of-turn: your final message is the doc-set briefing in markdown, then STOP.

If the scope turns up nothing, say so explicitly — the propose stage will know there's nothing to organize yet.$T$;

v_propose_template :=
$T$Scope: {{input.scope}}
Destination wiki: {{input.wiki_slug}}

## SOURCE DOC SET (from gather stage)

{{stage_results.gather.output}}

## YOUR TASK — propose wiki pages

Organize the source docs above into a set of wiki page proposals. For EACH proposed page:

1. Decide its slug + title + a concise, provenance-first summary (every claim traces to a doc_slug above; quote VERBATIM only when you have the source text in front of you this session — paraphrase otherwise; NO unsourced claims).
2. Call wiki_page_dedup_check(wiki_slug, title, summary) BEFORE finalizing the proposal. This call is REQUIRED for every single proposal, not optional — record what it returned (candidate_slug + similarity) in the proposal's dedup_checked field even when it finds nothing (similarity 0 / candidate_slug null IS a result).
3. Decide flat-vs-nested for the WHOLE proposal set: if the doc set is UNIFORM (all one kind of thing), use a flat slug space; if HETEROGENEOUS (several distinct categories), prefix slugs by category/ so the wiki reads as sections, not one flat pile.

## OUTPUT — JSON ONLY, no prose, no fences

```json
{
  "page_prefix_style": "flat" | "nested",
  "proposals": [
    {
      "slug": "kebab-case, category-prefixed if nested",
      "title": "...",
      "summary": "the page body -- concise, provenance-first markdown",
      "source_doc_slugs": ["..."],
      "dedup_checked": {"candidate_slug": null-or-a-slug, "similarity": 0.0}
    }
  ]
}
```

## HARD CONSTRAINTS

- Concise pages over exhaustive ones — merge closely related docs into ONE page rather than one page per doc if they cover the same topic.
- Every proposal MUST show a wiki_page_dedup_check call result.
- Output ONLY the JSON object.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object(
        'name', 'gather', 'next', 'propose',
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'wiki-curator', 'auto_advance', true,
        'tools_disabled', false, 'tool_groups', jsonb_build_array('substrate-read','wiki-tools'),
        'input_template', v_gather_template
    ),
    jsonb_build_object(
        'name', 'propose', 'next', NULL,
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'wiki-curator', 'auto_advance', true,
        'tools_disabled', false, 'tool_groups', jsonb_build_array('wiki-tools'),
        'input_template', v_propose_template
    )
);

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'wiki-organize',
    'Info-dump -> auto-organize. gather pulls the source doc set for a scope (project/wiki/all lens); propose organizes it into page proposals + REQUIRED dedup_check calls; apply (deterministic, fires on propose''s maturity->verified via an additive trigger, NOT a pipeline stage) writes pages: lightning tier (similarity>=0.90) auto-supersedes, mountain tier creates + queues a human merge review via the Hinge, no match creates plainly. No file artifact -- the wiki pages ARE the artifact.',
    v_stages,
    false,  -- sabbath_enabled: mechanical dedup+apply, not a creative artifact
    false,  -- atonement_enabled
    NULL,   -- file_destination_template: no file; pages land in wiki_pages
    NULL,
    '["raw","researched","verified"]'::jsonb,
    false   -- auto_materialize_on_verified: apply writes pages directly, no file
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
    file_destination_template = EXCLUDED.file_destination_template,
    file_content_jsonpath = EXCLUDED.file_content_jsonpath,
    maturity_ladder = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('wiki-organize', 'gather',  'researched', 'Source doc set gathered; ready for organizing.'),
    ('wiki-organize', 'propose', 'verified',   'Proposals + dedup_check results complete; fires wiki_organize_apply (deterministic).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('wiki-organize', 'gather',  'kimi-k2.6', 'Doc-set gather; tools enabled (wiki-tools + substrate-read).'),
    ('wiki-organize', 'propose', 'kimi-k2.6', 'Page proposals + required dedup_check calls; tools enabled (wiki-tools).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

END $seed$;

-- ---------------------------------------------------------------------
-- wiki_organize_apply — the deterministic apply. Fires on wiki-organize's
-- propose stage reaching maturity=verified (additive trigger below).
-- Mirrors apply_agent_proposal's role (13-research-pipelines): the LLM
-- proposes structured JSON; a DETERMINISTIC function decides the branch.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.wiki_organize_apply(p_work_item_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_wiki_slug      text;
    v_proposals_raw  jsonb;
    v_proposals      jsonb;
    v_prop           jsonb;
    v_slug           text;
    v_title          text;
    v_content        text;
    v_sources        jsonb;
    v_dedup_slug     text;
    v_dedup_sim      real;
    v_tier           text;
    v_mountain_floor real;
    v_n_created      int := 0;
    v_n_superseded   int := 0;
    v_n_flagged      int := 0;
    v_n_skipped      int := 0;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'wiki_organize_apply: work_item % not found', p_work_item_id;
    END IF;

    v_wiki_slug := COALESCE(NULLIF(v_wi.input ->> 'wiki_slug', ''), v_wi.slug);
    v_mountain_floor := COALESCE(stewards.config_get_text('wiki_dedup_mountain_floor', NULL)::real, 0.55);

    v_proposals_raw := v_wi.stage_results -> 'propose' -> 'output';
    IF v_proposals_raw IS NULL THEN
        RAISE EXCEPTION 'wiki_organize_apply: no propose output on work_item %', p_work_item_id;
    END IF;
    IF jsonb_typeof(v_proposals_raw) = 'string' THEN
        BEGIN
            v_proposals_raw := (v_proposals_raw #>> '{}')::jsonb;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'wiki_organize_apply: propose output is not valid JSON: %', SQLERRM;
        END;
    END IF;

    IF jsonb_typeof(v_proposals_raw) = 'object' AND v_proposals_raw ? 'proposals' THEN
        v_proposals := v_proposals_raw -> 'proposals';
    ELSE
        v_proposals := v_proposals_raw;
    END IF;

    IF v_proposals IS NULL OR jsonb_typeof(v_proposals) <> 'array' THEN
        RAISE EXCEPTION 'wiki_organize_apply: propose output has no proposals array';
    END IF;

    -- Ensure the destination wiki exists (wiki_create is idempotent per
    -- the mission's description of it).
    BEGIN
        PERFORM stewards.wiki_create(v_wiki_slug, initcap(replace(v_wiki_slug, '-', ' ')), 'organize', 'project');
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'wiki_organize_apply: wiki_create failed (likely 92-wiki-core not yet installed): %', SQLERRM;
    END;

    FOR v_prop IN SELECT * FROM jsonb_array_elements(v_proposals) LOOP
        v_slug    := v_prop ->> 'slug';
        v_title   := v_prop ->> 'title';
        v_content := v_prop ->> 'summary';
        v_sources := COALESCE(v_prop -> 'source_doc_slugs', '[]'::jsonb);

        IF v_slug IS NULL OR v_title IS NULL OR v_content IS NULL THEN
            RAISE NOTICE 'wiki_organize_apply: skipping malformed proposal (missing slug/title/summary): %', v_prop;
            v_n_skipped := v_n_skipped + 1;
            CONTINUE;
        END IF;

        v_dedup_slug := NULL;
        v_dedup_sim  := NULL;
        BEGIN
            -- Server-side safety net: re-run dedup_check even though propose
            -- was REQUIRED to call it — the LLM's echoed dedup_checked field
            -- is advisory; this authoritative branch decision is the real gate.
            -- INTEGRATION POINT: assumes wiki_page_dedup_check RETURNS TABLE
            -- (candidate_slug text, similarity real), best match first.
            SELECT candidate_slug, similarity INTO v_dedup_slug, v_dedup_sim
              FROM stewards.wiki_page_dedup_check(v_wiki_slug, v_title, v_content)
             ORDER BY similarity DESC LIMIT 1;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'wiki_organize_apply: wiki_page_dedup_check failed for % (likely 92-wiki-core not yet installed): %', v_slug, SQLERRM;
        END;

        v_tier := CASE
            WHEN v_dedup_sim IS NULL THEN 'none'
            WHEN v_dedup_sim >= 0.90 THEN 'lightning'
            WHEN v_dedup_sim >= v_mountain_floor THEN 'mountain'
            ELSE 'none'
        END;

        BEGIN
            IF v_tier = 'lightning' THEN
                -- Auto-supersede: write into the MATCHED existing slug, not a
                -- new one -- >=0.90 means "this is the same page."
                PERFORM stewards.wiki_page_upsert(COALESCE(v_dedup_slug, v_slug), v_title, v_content, v_sources);
                PERFORM stewards.wiki_add_member(v_wiki_slug, COALESCE(v_dedup_slug, v_slug));
                v_n_superseded := v_n_superseded + 1;
            ELSIF v_tier = 'mountain' THEN
                -- Create the new page (nothing is lost / blocked at write
                -- time -- Michael's stated design goal) AND flag it for a
                -- human merge review rather than silently growing a
                -- near-duplicate unchecked.
                PERFORM stewards.wiki_page_upsert(v_slug, v_title, v_content, v_sources);
                PERFORM stewards.wiki_add_member(v_wiki_slug, v_slug);
                PERFORM stewards.wiki_merge_propose(v_slug, v_dedup_slug,
                    format('wiki-organize proposed "%s" (similarity %.2f to existing "%s"); both now exist -- review whether they should merge.',
                           v_title, v_dedup_sim, v_dedup_slug));
                v_n_flagged := v_n_flagged + 1;
            ELSE
                PERFORM stewards.wiki_page_upsert(v_slug, v_title, v_content, v_sources);
                PERFORM stewards.wiki_add_member(v_wiki_slug, v_slug);
                v_n_created := v_n_created + 1;
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'wiki_organize_apply: apply failed for % (tier=%, likely 92-wiki-core not yet installed): %', v_slug, v_tier, SQLERRM;
        END;
    END LOOP;

    RETURN jsonb_build_object(
        'wiki_slug', v_wiki_slug,
        'created', v_n_created,
        'superseded', v_n_superseded,
        'flagged_for_merge_review', v_n_flagged,
        'skipped_malformed', v_n_skipped
    );
END;
$fn$;

COMMENT ON FUNCTION stewards.wiki_organize_apply(uuid) IS
'94-wiki-curator: deterministic apply for the wiki-organize pipeline (mirrors apply_agent_proposal''s shape). Reads propose''s JSON proposals; per proposal, server-side re-runs wiki_page_dedup_check as the authoritative branch decision: lightning (>=0.90) supersedes in place, mountain ([floor,0.90)) creates + queues a Hinge merge review, none creates plainly. Fired by the additive trigger work_items_wiki_organize_apply, not a pipeline stage.';

-- ── the additive trigger — a SEPARATE trigger object from on_maturity_
-- verified (08-gates), scoped tightly to pipeline_family='wiki-organize'.
-- Precedent: 25-corpus.sql's work_items_fill_project does the same thing
-- (a new trigger rather than a re-author of a shared core function).
CREATE OR REPLACE FUNCTION stewards.wiki_organize_apply_trigger()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.pipeline_family = 'wiki-organize' THEN
        BEGIN
            PERFORM stewards.wiki_organize_apply(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'wiki_organize_apply_trigger: apply failed for work_item=%: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS work_items_wiki_organize_apply ON stewards.work_items;
CREATE TRIGGER work_items_wiki_organize_apply
    AFTER UPDATE OF maturity ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.maturity = 'verified' AND OLD.maturity IS DISTINCT FROM 'verified')
    EXECUTE FUNCTION stewards.wiki_organize_apply_trigger();

-- ── wiki_organize_start — the entry point (mirrors start_brainstorm's
-- role: the one call that kicks off a run). Registered as a tool so a
-- human or another agent can invoke it conversationally.
CREATE OR REPLACE FUNCTION stewards.wiki_organize_start(
    p_scope                jsonb,
    p_wiki_slug            text,
    p_actor                text DEFAULT 'human',
    p_project_association  text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_slug text;
    v_id   uuid;
BEGIN
    IF p_wiki_slug IS NULL OR btrim(p_wiki_slug) = '' THEN
        RAISE EXCEPTION 'wiki_organize_start: wiki_slug is required';
    END IF;
    v_slug := 'wiki-organize-' || p_wiki_slug || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS');

    v_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-organize',
        p_input           => jsonb_build_object(
            'binding_question', format('Organize the %s scope into wiki pages for "%s".',
                                        COALESCE(p_scope, '{"kind":"all"}'::jsonb), p_wiki_slug),
            'scope', COALESCE(p_scope, '{"kind":"all","value":null}'::jsonb),
            'wiki_slug', p_wiki_slug
        ),
        p_slug   => v_slug,
        p_actor  => COALESCE(p_actor, 'human')
    );
    UPDATE stewards.work_items
       SET project_association = p_project_association
     WHERE id = v_id;

    PERFORM stewards.work_item_dispatch_stage(v_id, NULL);
    RETURN v_id;
END;
$fn$;
COMMENT ON FUNCTION stewards.wiki_organize_start(jsonb, text, text, text) IS
'94-wiki-curator: entry point for wiki-organize (mirrors start_brainstorm''s role). scope = {"kind":"project"|"wiki"|"all","value":text-or-null} -- the lens the gather stage reads from. wiki_slug = the destination wiki pages get organized into.';

CREATE OR REPLACE FUNCTION stewards.wiki_organize_start_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_id uuid;
BEGIN
    v_id := stewards.wiki_organize_start(
        COALESCE(p_args->'scope', '{"kind":"all","value":null}'::jsonb),
        p_args->>'wiki_slug',
        COALESCE(p_args->>'actor', 'human'),
        p_args->>'project_association'
    );
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_id::text);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'wiki_organize_start',
  'Start a wiki-organize run: an existing source-doc set becomes wiki pages. Args: scope ({"kind":"project"|"wiki"|"all","value":text}), wiki_slug (the destination wiki), project_association (optional). Runs in the background; pages land via the deterministic apply step once propose completes.',
  '{"type":"object","required":["wiki_slug"],"properties":{"scope":{"type":"object"},"wiki_slug":{"type":"string"},"project_association":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_organize_start_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator', 'wiki_organize_start', 'allow'),
  ('research',     'wiki_organize_start', 'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- SECTION 4 — wiki-collect-entity: the leaf pipeline. One child per
-- entity, spawned by spawn_children (reused unmodified, see header).
-- Single stage; produces_maturity=verified directly (mirrors agent-
-- proposal's single-stage 'validate' shape, 13-research-pipelines).
-- =====================================================================
DO $seed$
DECLARE
    v_research_template text;
BEGIN

v_research_template :=
$T$Binding question: {{input.binding_question}}

You are researching ONE entity for the wiki: **{{input.entity_name}}**.

## YOUR TASK

1. Research this entity using your search tools (web_search_exa, fetch_url, doc_search, pool_search, wiki_search).
2. Call wiki_page_dedup_check first to see if this entity already has a page in this wiki.
   - similarity >= 0.90: same entity already documented -- read the existing page and UPDATE it (still via wiki_page_upsert, same slug) with anything new, rather than duplicating.
   - otherwise: proceed to create a new page.
3. Call wiki_page_upsert(slug, title, content, sources):
   - slug: kebab-case. If this wiki uses a nested/section slug space ({{input.page_prefix_style}}), prefix accordingly.
   - content: PROVENANCE-FIRST -- every claim traces to a source you actually read this session. Quote VERBATIM only when you have the source in front of you; paraphrase otherwise ("X reports that..." is honest; an unverified direct quote is not). Concise over exhaustive.
   - sources: the doc/URL references you drew from.
4. Call wiki_add_member(wiki_slug, slug) so the page joins this wiki.

## HARD CONSTRAINTS

- Maximum 6 rounds of tool calls.
- End your turn once wiki_page_upsert + wiki_add_member have both succeeded. Your final message: one line confirming what you wrote and its slug.

If your search turns up nothing credible on this entity, say so plainly in the page ("no credible source found for X") rather than inventing detail.$T$;

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified
)
VALUES (
    'wiki-collect-entity',
    'The leaf pipeline for wiki-collect''s fan-out: one child per entity. Researches ONE entity and writes ONE wiki page (wiki_page_upsert + wiki_add_member), dedup-checked first. No file artifact -- the wiki page IS the artifact.',
    jsonb_build_array(
        jsonb_build_object(
            'name', 'research', 'next', NULL,
            'model', 'kimi-k2.6', 'provider', 'opencode_go',
            'agent_family', 'wiki-curator-entity', 'auto_advance', true,
            'tools_disabled', false, 'tool_groups', jsonb_build_array('web-research','wiki-tools'),
            'input_template', v_research_template
        )
    ),
    false, false, NULL, NULL,
    '["raw","verified"]'::jsonb,
    false
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
    file_destination_template = EXCLUDED.file_destination_template,
    file_content_jsonpath = EXCLUDED.file_content_jsonpath,
    maturity_ladder = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    updated_at = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('wiki-collect-entity', 'research', 'verified', 'Single stage; page written + joined to the wiki.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('wiki-collect-entity', 'research', 'kimi-k2.6', 'One-entity research + write; tools enabled (web-research + wiki-tools).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

END $seed$;

-- =====================================================================
-- SECTION 5 — wiki-collect: plan -> fan-out (spawn_children, reused
-- unmodified) -> aggregate (the generic aggregate-children pipeline,
-- bridged into a real wiki page by an additive trigger).
--
-- input shape: {"question": text, "scope": {...same shape as wiki-
-- organize's...}, "wiki_slug": text}.
-- =====================================================================
DO $seed$
DECLARE
    v_plan_template text;
BEGIN

v_plan_template :=
$T$Question: {{input.question}}
Scope: {{input.scope}}
Wiki: {{input.wiki_slug}}

## YOUR TASK -- decompose into an entity/facet worklist

The question names or implies a SET of entities (e.g. "ponies in Equestria") and one or more FACETS to research per entity (e.g. "what cutie mark, what power it grants, evidence it's been used/saved/shared"). Your job:

1. Identify the entity set -- search if you need to (web_search_exa, fetch_url, doc_search, pool_search; wiki_search restricted to {{input.wiki_slug}}'s existing members if scope.kind="wiki" -- check what's already covered so you don't re-propose it).
2. Name the shared facet template every entity's research should cover.
3. Decide the page-space shape for the resulting wiki: flat (uniform entity kind) or nested (heterogeneous categories).

## OUTPUT -- JSON ONLY, no prose, no fences

```json
{
  "rationale": "1-3 sentences",
  "facet_template": "one sentence describing what every entity's page should cover",
  "entities": ["Entity Name 1", "Entity Name 2"],
  "page_prefix_style": "flat" | "nested"
}
```

## HARD CONSTRAINTS

- entities: as many as genuinely exist in the domain, up to a soft target of 24 -- if there are more, list the 24 most notable and note the rest don't fit in the rationale (the substrate enforces the real cap and reports any further overflow on the wiki's index page).
- Maximum 5 rounds of tool calls.
- Output ONLY the JSON object.$T$;

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified, metadata
)
VALUES (
    'wiki-collect',
    'Info-collect: "go fetch all the X, then look at their Y." plan (LLM: entity/facet worklist) -> fan-out (spawn_children, reused unmodified from 14-fanout-brainstorm -- wiki_collect_spawn writes the decompose-shaped manifest onto THIS work_item then calls spawn_children directly) -> aggregate (the generic aggregate-children pipeline, bridged into a real wiki index page by an additive trigger). Bounded per 16-subagents'' delegation limits (subagent_max_children.wiki-collect, seeded above).',
    jsonb_build_array(
        jsonb_build_object(
            'name', 'plan', 'next', NULL,
            'model', 'kimi-k2.6', 'provider', 'opencode_go',
            'agent_family', 'wiki-curator', 'auto_advance', true,
            'tools_disabled', false, 'tool_groups', jsonb_build_array('web-research','substrate-read','wiki-tools'),
            'input_template', v_plan_template
        )
    ),
    false, false, NULL, NULL,
    '["raw","verified"]'::jsonb,
    false,
    jsonb_build_object('shape', 'wiki-fanout')
)
ON CONFLICT (family) DO UPDATE SET
    description = EXCLUDED.description, stages = EXCLUDED.stages,
    sabbath_enabled = EXCLUDED.sabbath_enabled, atonement_enabled = EXCLUDED.atonement_enabled,
    file_destination_template = EXCLUDED.file_destination_template,
    file_content_jsonpath = EXCLUDED.file_content_jsonpath,
    maturity_ladder = EXCLUDED.maturity_ladder,
    auto_materialize_on_verified = EXCLUDED.auto_materialize_on_verified,
    metadata = EXCLUDED.metadata,
    updated_at = now();

INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('wiki-collect', 'plan', 'verified', 'Entity/facet worklist complete; fires wiki_collect_spawn (deterministic manifest + spawn_children).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('wiki-collect', 'plan', 'kimi-k2.6', 'Entity/facet decomposition; tools enabled (web-research + substrate-read + wiki-tools).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

END $seed$;

-- ---------------------------------------------------------------------
-- wiki_collect_spawn — transforms plan's entity/facet JSON into the
-- EXACT decompose-shaped manifest spawn_children (14-fanout-brainstorm)
-- expects, writes it onto THIS work_item (stage_results.decompose.output
-- -- spawn_children keys strictly on that path regardless of the work_
-- item's own pipeline_family), then calls spawn_children directly. This
-- is the same move start_brainstorm (14) makes for the brainstorm lenses,
-- minus the LLM call being free-form here instead of a fixed lens list.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.wiki_collect_spawn(p_work_item_id uuid)
RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi             stewards.work_items%ROWTYPE;
    v_plan_raw       jsonb;
    v_plan           jsonb;
    v_entities       jsonb;
    v_facet_template text;
    v_prefix_style   text;
    v_wiki_slug      text;
    v_cap            int;
    v_n_entities     int;
    v_n_kept         int;
    v_n_overflow     int;
    v_children       jsonb := '[]'::jsonb;
    v_entity         text;
    v_entity_slug    text;
    v_idx            int;
    v_dest           text;
    v_manifest       jsonb;
    v_spawned        int;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'wiki_collect_spawn: work_item % not found', p_work_item_id;
    END IF;

    v_wiki_slug := COALESCE(NULLIF(v_wi.input ->> 'wiki_slug', ''), v_wi.slug);

    v_plan_raw := v_wi.stage_results -> 'plan' -> 'output';
    IF v_plan_raw IS NULL THEN
        RAISE EXCEPTION 'wiki_collect_spawn: no plan output on work_item %', p_work_item_id;
    END IF;
    IF jsonb_typeof(v_plan_raw) = 'string' THEN
        BEGIN
            v_plan := (v_plan_raw #>> '{}')::jsonb;
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'wiki_collect_spawn: plan output is not valid JSON: %', SQLERRM;
        END;
    ELSE
        v_plan := v_plan_raw;
    END IF;

    v_entities       := v_plan -> 'entities';
    v_facet_template := COALESCE(v_plan ->> 'facet_template', 'general research on this entity');
    v_prefix_style   := COALESCE(v_plan ->> 'page_prefix_style', 'flat');

    IF v_entities IS NULL OR jsonb_typeof(v_entities) <> 'array' OR jsonb_array_length(v_entities) = 0 THEN
        RAISE EXCEPTION 'wiki_collect_spawn: plan.entities is missing or empty';
    END IF;

    v_n_entities := jsonb_array_length(v_entities);

    -- Bounded per 16-subagents "as-is": read the EFFECTIVE cap at spawn
    -- time (the config row seeded above, or the global default), reserve
    -- 1 slot for the aggregator spawn_children always creates.
    v_cap := GREATEST(0, COALESCE(
        (SELECT value::int FROM stewards.config WHERE key = 'subagent_max_children.wiki-collect'),
        (SELECT value::int FROM stewards.config WHERE key = 'subagent_max_children'),
        8) - 1);
    v_n_kept     := LEAST(v_n_entities, v_cap);
    v_n_overflow := GREATEST(0, v_n_entities - v_n_kept);

    FOR v_idx IN 0 .. v_n_kept - 1 LOOP
        v_entity := v_entities ->> v_idx;
        EXIT WHEN v_entity IS NULL;
        v_entity_slug := trim(both '-' from regexp_replace(lower(btrim(v_entity)), '[^a-z0-9]+', '-', 'g'));
        IF v_prefix_style = 'nested' THEN
            v_entity_slug := v_wiki_slug || '/' || v_entity_slug;
        END IF;

        v_children := v_children || jsonb_build_object(
            'slug', COALESCE(v_wi.slug, p_work_item_id::text) || '-' || (v_idx + 1)::text,
            'pipeline_family', 'wiki-collect-entity',
            'binding_question', format('Research %s for the wiki "%s". Facets to cover: %s',
                                        v_entity, v_wiki_slug, v_facet_template),
            'input_extra', jsonb_build_object(
                'wiki_slug', v_wiki_slug,
                'entity_name', v_entity,
                'entity_slug', v_entity_slug,
                'page_prefix_style', v_prefix_style
            )
        );
    END LOOP;

    v_dest := 'wikis/' || v_wiki_slug || '/index.md';

    v_manifest := jsonb_build_object(
        'rationale', format('wiki-collect: %s entities decomposed (%s kept, %s overflow)',
                             v_n_entities, v_n_kept, v_n_overflow),
        'children', v_children,
        'aggregate', jsonb_build_object(
            'destination', v_dest,
            'synthesis', false,
            'overflow_count', v_n_overflow
        )
    );

    -- Write the decompose-shaped manifest onto THIS work_item so
    -- spawn_children (14-fanout-brainstorm, unmodified) can read it --
    -- it keys strictly on stage_results.decompose.output, regardless of
    -- this work_item's own pipeline_family (only the TRIGGER gates on
    -- pipeline_family='decompose-fanout'; spawn_children itself does not).
    UPDATE stewards.work_items
       SET stage_results = stage_results || jsonb_build_object('decompose', jsonb_build_object('output', v_manifest))
     WHERE id = p_work_item_id;

    v_spawned := stewards.spawn_children(p_work_item_id);

    RAISE NOTICE 'wiki_collect_spawn: work_item=% wiki=% entities=% kept=% overflow=% spawned=%',
        p_work_item_id, v_wiki_slug, v_n_entities, v_n_kept, v_n_overflow, v_spawned;

    RETURN v_spawned;
END;
$fn$;

COMMENT ON FUNCTION stewards.wiki_collect_spawn(uuid) IS
'94-wiki-curator: transforms wiki-collect''s plan output (entities + facet_template + page_prefix_style) into the decompose-shaped manifest spawn_children (14-fanout-brainstorm) expects, writes it onto stage_results.decompose.output, then calls spawn_children directly -- reusing it UNMODIFIED. Caps the entity list to the effective subagent_max_children.wiki-collect (config, seeded above) minus 1 (the aggregator slot); overflow is reported via the aggregate manifest and surfaces on the wiki index page (wiki_collect_aggregate_bridge).';

-- ── the additive trigger — scoped to pipeline_family='wiki-collect'.
CREATE OR REPLACE FUNCTION stewards.wiki_collect_spawn_trigger()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.pipeline_family = 'wiki-collect' THEN
        BEGIN
            PERFORM stewards.wiki_collect_spawn(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'wiki_collect_spawn_trigger: spawn failed for work_item=%: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS work_items_wiki_collect_spawn ON stewards.work_items;
CREATE TRIGGER work_items_wiki_collect_spawn
    AFTER UPDATE OF maturity ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.maturity = 'verified' AND OLD.maturity IS DISTINCT FROM 'verified')
    EXECUTE FUNCTION stewards.wiki_collect_spawn_trigger();

-- ---------------------------------------------------------------------
-- wiki_collect_aggregate_bridge — the generic aggregate-children pipeline
-- (spawn_children hardcodes it for EVERY fan-out consumer) writes plain
-- markdown to a file_destination. This bridge recognizes ITS OWN
-- aggregator runs (file_destination matches wikis/<slug>/index.md, a
-- path only wiki_collect_spawn ever sets) and turns that markdown into a
-- real wiki index page, appending the overflow/gaps note that spawn_
-- children's manifest handling doesn't forward on its own (it only reads
-- destination + synthesis off the aggregate object, so overflow_count is
-- pulled back from the PARENT's stored manifest here).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION stewards.wiki_collect_aggregate_bridge()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_wiki_slug  text;
    v_index_slug text;
    v_content    text;
    v_overflow   int;
BEGIN
    IF NEW.pipeline_family <> 'aggregate-children'
       OR NEW.file_destination IS NULL
       OR NEW.file_destination !~ '^wikis/[a-z0-9-]+/index\.md$' THEN
        RETURN NEW;
    END IF;

    v_wiki_slug := substring(NEW.file_destination FROM 'wikis/([a-z0-9-]+)/index\.md');
    v_content   := NEW.stage_results -> 'aggregate' ->> 'output';
    IF v_content IS NULL OR btrim(v_content) = '' THEN
        RAISE NOTICE 'wiki_collect_aggregate_bridge: no aggregate output for work_item=%', NEW.id;
        RETURN NEW;
    END IF;

    IF NEW.parent_work_item_id IS NOT NULL THEN
        SELECT (stage_results -> 'decompose' -> 'output' -> 'aggregate' ->> 'overflow_count')::int
          INTO v_overflow
          FROM stewards.work_items WHERE id = NEW.parent_work_item_id;
    END IF;
    IF COALESCE(v_overflow, 0) > 0 THEN
        v_content := v_content || E'\n\n## Gaps found\n\n' ||
            format('%s additional entities were identified but not researched this pass (worklist cap). Re-run wiki-collect on this wiki to cover them.', v_overflow);
    END IF;

    v_index_slug := v_wiki_slug || '-index';
    BEGIN
        PERFORM stewards.wiki_create(v_wiki_slug, initcap(replace(v_wiki_slug, '-', ' ')), 'collect', 'project');
        PERFORM stewards.wiki_page_upsert(v_index_slug, initcap(replace(v_wiki_slug, '-', ' ')) || ' -- Index', v_content, '[]'::jsonb);
        PERFORM stewards.wiki_add_member(v_wiki_slug, v_index_slug);
        RAISE NOTICE 'wiki_collect_aggregate_bridge: wiki=% index_page=% work_item=%', v_wiki_slug, v_index_slug, NEW.id;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'wiki_collect_aggregate_bridge: wiki_* call failed for wiki=% (likely 92-wiki-core not yet installed): %', v_wiki_slug, SQLERRM;
    END;

    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS work_items_wiki_collect_aggregate_bridge ON stewards.work_items;
CREATE TRIGGER work_items_wiki_collect_aggregate_bridge
    AFTER UPDATE OF maturity ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.maturity = 'verified' AND OLD.maturity IS DISTINCT FROM 'verified')
    EXECUTE FUNCTION stewards.wiki_collect_aggregate_bridge();

-- ── wiki_collect_start — the entry point.
CREATE OR REPLACE FUNCTION stewards.wiki_collect_start(
    p_question             text,
    p_scope                jsonb DEFAULT NULL,
    p_wiki_slug            text  DEFAULT NULL,
    p_actor                text  DEFAULT 'human',
    p_project_association  text  DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_wiki_slug text;
    v_slug      text;
    v_id        uuid;
BEGIN
    IF p_question IS NULL OR btrim(p_question) = '' THEN
        RAISE EXCEPTION 'wiki_collect_start: question is required';
    END IF;
    v_wiki_slug := COALESCE(NULLIF(p_wiki_slug, ''),
        trim(both '-' from regexp_replace(lower(btrim(p_question)), '[^a-z0-9]+', '-', 'g')));
    v_slug := 'wiki-collect-' || v_wiki_slug || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS');

    v_id := stewards.work_item_create(
        p_pipeline_family => 'wiki-collect',
        p_input           => jsonb_build_object(
            'binding_question', p_question,
            'question', p_question,
            'scope', COALESCE(p_scope, '{"kind":"all","value":null}'::jsonb),
            'wiki_slug', v_wiki_slug
        ),
        p_slug   => v_slug,
        p_actor  => COALESCE(p_actor, 'human')
    );
    UPDATE stewards.work_items
       SET project_association = p_project_association
     WHERE id = v_id;

    PERFORM stewards.work_item_dispatch_stage(v_id, NULL);
    RETURN v_id;
END;
$fn$;
COMMENT ON FUNCTION stewards.wiki_collect_start(text, jsonb, text, text, text) IS
'94-wiki-curator: entry point for wiki-collect (mirrors start_brainstorm''s role). wiki_slug defaults to a slugified question if not given.';

CREATE OR REPLACE FUNCTION stewards.wiki_collect_start_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE
    v_id uuid;
BEGIN
    v_id := stewards.wiki_collect_start(
        p_args->>'question',
        p_args->'scope',
        p_args->>'wiki_slug',
        COALESCE(p_args->>'actor', 'human'),
        p_args->>'project_association'
    );
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_id::text);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'wiki_collect_start',
  'Start a wiki-collect run: "go fetch all the X, then research their Y" -- decomposes into an entity worklist, fans out one researcher per entity (~24 max), builds a wiki index page. Args: question (required), scope ({"kind":"project"|"wiki"|"all","value":text}), wiki_slug (defaults to a slugified question), project_association.',
  '{"type":"object","required":["question"],"properties":{"question":{"type":"string"},"scope":{"type":"object"},"wiki_slug":{"type":"string"},"project_association":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"wiki_collect_start_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description=EXCLUDED.description, args_schema=EXCLUDED.args_schema,
    execute_target=EXCLUDED.execute_target, active=true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('wiki-curator', 'wiki_collect_start', 'allow'),
  ('research',     'wiki_collect_start', 'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- End of 94-wiki-curator.sql
-- =====================================================================
