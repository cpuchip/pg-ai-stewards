-- =====================================================================
-- 99-route-intake.sql — raw-to-wiki: the auto-magic router
-- (.spec/proposals/ingestion-crawler-and-raw-to-wiki.md Part 2)
-- =====================================================================
-- Michael's own words: "push over a video, a website, a file, and its
-- auto sorted into a world. if one doesnt exist itd create one by theme.
-- the auto magic approach... but it would also be useful to give
-- directions with the file. like this is an AI video, review it for new
-- information that can benefit us and file those things away."
--
-- ONE intake entry point (route_intake), an optional instruction. The new
-- piece is a ROUTER: classify (what is this) -> match (does an existing
-- world/wiki/project already fit, or should a new one be proposed) ->
-- disposition (deterministic: file into a match, or park a mountain-tier
-- Hinge review for a new scope) -> dispatch (deterministic: hand off to
-- the pipeline that actually does the extraction).
--
-- Shape, end to end:
--
--   route_intake(kind, ref, instruction)
--     -> work_item on pipeline 'route-intake'
--        stage classify (LLM, no tools): category / theme / purpose
--        stage match    (LLM + tools):   scope_candidates + doc_search/
--                        pool_search -> {matched, scope} OR {proposed_scope}
--        -- match reaching maturity=verified fires the additive trigger
--        -- below (NOT a third pipeline stage — same shape as 94's
--        -- wiki_organize_apply_trigger / apply_agent_proposal):
--     -> route_intake_disposition (deterministic)
--        matched      -> route_intake_dispatch immediately (act-and-report,
--                         no gate — filing into an EXISTING scope is
--                         execution, not a new standing capability)
--        not matched  -> hinge_enqueue('new-scope', ...) (MOUNTAIN tier —
--                         creating a new world/wiki namespace entry is
--                         Michael's call, same reasoning as 92's wiki-merge)
--     -> (on Michael's approval) route_intake_new_scope_apply_trigger
--        creates the world (stewards.worlds) or wiki (wiki_create), then
--        calls route_intake_dispatch with the freshly-created scope —
--        self-terminating, verbatim pattern from 92's wiki_merge_apply_trigger.
--     -> route_intake_dispatch (deterministic) — routes by kind:
--        url   -> stewards.crawl_start (98, sibling fleet builder CRAWLER —
--                 NOT present in this worktree; guarded by to_regprocedure,
--                 degrades honestly, exactly like WIKI-GRAPH's to_regclass
--                 guard in cmd/stewards-ui/api/wiki.go)
--        video -> stewards.playlist_add (examples/playlist-digester.sql —
--                 an OPERATOR OVERLAY, not core; also guarded. Chosen over
--                 work_item_create('playlist-digest', ...) after reading the
--                 real pipeline: its 'digest' stage pulls its OWN next video
--                 via playlist_next()/playlist_watch, ignoring arbitrary
--                 work_item input — playlist_add is the actual, correct,
--                 already-working entry point for "watch this one video")
--        file  -> world-shaped (scope.kind='world'): HONEST NO-OP. world-build
--                 has NO SQL entry point anywhere in this codebase (verified:
--                 it is dispatched via a raw chat turn from
--                 cmd/stewards-ui/api/world.go, not stewards.pipelines) — a
--                 deterministic SQL function cannot reach it. Documented,
--                 not faked.
--                 otherwise: stewards.wiki_organize_start (94, real + core) —
--                 the doc itself still needs an agent-driven doc_import_corpus
--                 (49 §5, bridge-side) before wiki-organize's gather stage
--                 finds anything; the returned note says so.
--        text  -> stewards.wiki_organize_start (94), same as file/non-world.
--
-- SIBLING CONTRACTS (parallel fleet builders, neither present in this
-- worktree — guarded, never assumed):
--   BRIDGE   stewards.world_to_wiki(p_world_slug text) returns text   (97)
--   CRAWLER  stewards.crawl_start(p_url text, p_purpose text,
--                                 p_config jsonb) returns uuid        (98)
--
-- requires create_wiki_assets (96) — the last entry in the chain as
-- authored (00-96 real; 97/98 are parallel-worktree siblings not yet
-- merged). Reuses: hinge_enqueue/hinge_reviews (39), work_item_create/
-- work_item_dispatch_stage (04), tool_groups (37), wiki_create/wiki_pages
-- (92), wiki_organize_start (94), stewards.worlds (54).
-- =====================================================================

-- =====================================================================
-- §1 — scope_candidates: cheap FTS-ranked search over worlds/wikis/
-- projects by name+description. No pg_trgm (keeps the vector-only
-- invariant already named in 13-research-pipelines.sql's
-- binding_question_overlap) — plain to_tsvector/websearch_to_tsquery,
-- computed inline since none of the three tables carry a stored
-- tsvector column (this is a cold, occasional lookup, not a hot path).
-- Only rows that actually match (tsvector @@ tsquery) come back, so
-- "nothing fits" is a real, honest empty set — the match stage's cue to
-- propose a new scope rather than force-fitting a zero-relevance
-- candidate. Filtering on the BOOLEAN @@ match (not "rank > 0") matters:
-- ts_rank has a well-known epsilon quirk (verified live) where a
-- multi-lexeme ANDed tsquery with ZERO real matches against a document
-- still returns a tiny nonzero rank (~1e-20, not exactly 0) — "rank > 0"
-- would silently leak false candidates into a genuinely-no-match theme.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.scope_candidates(p_theme text, p_limit int DEFAULT 8)
RETURNS TABLE (kind text, slug text, title text, description text, rank real)
LANGUAGE sql STABLE AS $fn$
    WITH q AS (
        SELECT plainto_tsquery('english', coalesce(p_theme, '')) AS tsq
    ),
    cand AS (
        SELECT 'world'::text AS kind, w.slug, w.name AS title, w.summary AS description,
               to_tsvector('english', coalesce(w.name, '') || ' ' || coalesce(w.summary, '')) AS tsv
          FROM stewards.worlds w
        UNION ALL
        SELECT 'wiki'::text, wi.slug, wi.title, NULL::text,
               to_tsvector('english', coalesce(wi.title, ''))
          FROM stewards.wikis wi
        UNION ALL
        SELECT 'project'::text, p.slug, p.name, p.description,
               to_tsvector('english', coalesce(p.name, '') || ' ' || coalesce(p.description, ''))
          FROM stewards.projects p
         WHERE NOT p.archived
    )
    SELECT cand.kind, cand.slug, cand.title, cand.description, ts_rank(cand.tsv, q.tsq) AS rank
      FROM cand, q
     WHERE q.tsq IS NOT NULL AND cand.tsv @@ q.tsq
     ORDER BY rank DESC
     LIMIT greatest(p_limit, 1);
$fn$;
COMMENT ON FUNCTION stewards.scope_candidates(text, int) IS
'99: cheap FTS scope search — worlds/wikis/(non-archived) projects, name+description, plainto_tsquery computed inline (no pg_trgm, no new tsvector column). Matches filtered by the tsvector @@ tsquery BOOLEAN operator (not "rank > 0" — ts_rank has a verified epsilon quirk that leaks a tiny nonzero rank for a multi-lexeme ANDed tsquery with zero real matches), so an empty result is an honest "nothing fits", not a guess. Used by the route-intake match stage before proposing a brand-new scope.';

-- ── the 94-addendum tool convention: jsonb in/out, error-as-jsonb, never
-- RAISE to the dispatch loop (wiki_search_tool's shape, 94-wiki-curator.sql).
CREATE OR REPLACE FUNCTION stewards.scope_candidates_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $FN$
DECLARE
    v_theme text := p_args ->> 'theme';
    v_limit int  := coalesce(nullif(p_args ->> 'limit', '')::int, 8);
    v_rows  jsonb;
BEGIN
    IF v_theme IS NULL OR btrim(v_theme) = '' THEN
        RETURN '{"error":"theme required"}'::jsonb;
    END IF;
    SELECT coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) INTO v_rows
      FROM stewards.scope_candidates(v_theme, v_limit) t;
    RETURN jsonb_build_object('theme', v_theme, 'candidates', v_rows);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('error', 'scope_candidates failed', 'detail', SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'scope_candidates',
  'Search existing worlds/wikis/projects by name+description for a scope that fits a theme (FTS-ranked; empty result = nothing fits). Call this BEFORE proposing a brand-new world or wiki — an existing scope should win when it genuinely fits. Args: theme (required, a one-line topic), limit.',
  '{"type":"object","required":["theme"],"properties":{"theme":{"type":"string"},"limit":{"type":"integer"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"scope_candidates_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

INSERT INTO stewards.tool_groups (name, description, tool_patterns) VALUES
  ('intake-tools', 'the route-intake surface: search existing scopes by theme', ARRAY['scope_candidates'])
ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description, tool_patterns = EXCLUDED.tool_patterns;

-- =====================================================================
-- §2 — the intake agent family: classify + match. Read-only, never files
-- anything itself (deterministic disposition/dispatch do that) — same
-- discipline as 94's wiki-curator ("never writes a page directly").
-- =====================================================================
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES (
  'intake', '*',
  'Classifies a dropped artifact (url/file/video/text) and finds or proposes the world/wiki/project scope it belongs to. classify names category/theme/purpose (no tools); match searches existing scopes and decides matched-or-propose. Never files anything itself — a deterministic disposition step does that.',
  'primary',
  $PROMPT$You are the Intake Router. Something was dropped -- a URL, a file, a video, or a piece of text -- and your job is to figure out what it is and where it belongs, NOT to read or extract its content yourself (a downstream pipeline does the actual extraction once you have decided the destination).

Two jobs, one per stage:
- classify: name the category, a one-line theme, and the extraction purpose (restate the human's instruction if one was given; infer a sensible purpose from the kind + reference if not -- that is the auto-magic case).
- match: search existing scopes (scope_candidates on the theme, plus doc_search/pool_search if useful) for a genuine fit. Prefer an EXISTING scope over inventing a new one -- only propose a new world/wiki when nothing existing is a real match. A new "world" is for lore/fiction material with entities and relationships worth graphing; everything else that needs a new home gets a "wiki".

You are one stage in a multi-stage pipeline. Do your stage's job, follow its output format exactly, and stop -- the next stage (or a deterministic apply step) does the rest.$PROMPT$,
  0.3
)
ON CONFLICT (family, model_match) DO UPDATE
   SET description = EXCLUDED.description, prompt = EXCLUDED.prompt, temperature = EXCLUDED.temperature, active = true;

INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action) VALUES
  ('intake', 'doc_search',       'allow'),
  ('intake', 'doc_get',          'allow'),
  ('intake', 'pool_search',      'allow'),
  ('intake', 'scope_candidates', 'allow'),
  ('intake', 'route_intake',     'allow')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- work-item-chat (the Stewdio cockpit chat agent) gets route_intake +
-- scope_candidates too, so a human chatting can drop something directly —
-- same grant shape as 49's doc_extract/doc_import_corpus grant to
-- work-item-chat. source='manual' so a future frontmatter reimport of
-- work-item-chat's own config can't silently wipe this grant (49's convention).
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat', 'route_intake',     'allow', 'manual'),
  ('work-item-chat', 'scope_candidates', 'allow', 'manual')
ON CONFLICT (agent_family, tool_pattern) DO UPDATE SET action = EXCLUDED.action;

-- =====================================================================
-- §3 — the route-intake pipeline: classify -> match. disposition/dispatch
-- are deterministic (below), fired by an additive trigger on match's
-- maturity->verified transition (mirrors 94's wiki_organize_apply_trigger
-- shape exactly) — NOT a third pipeline stage.
-- =====================================================================
DO $seed$
DECLARE
    v_classify_template text;
    v_match_template    text;
    v_stages            jsonb;
BEGIN

v_classify_template :=
$T$Kind: {{input.kind}}
Reference: {{input.ref}}
Instruction (if any): {{input.instruction}}

## YOUR TASK -- classify this intake

Decide:
1. category -- exactly one of: lore/fiction | technical/ai | reference | news | personal
2. theme -- a ONE-LINE theme/topic summary (used downstream to search for a matching scope)
3. purpose -- the extraction purpose. If an instruction was given above, RESTATE it as a purpose (a directive for what to pull out and file away). If no instruction was given, INFER a sensible purpose from the kind + reference alone (auto-magic mode) -- you do not have the actual content yet, so keep this general ("capture the substantive claims and file them under their real topic").

## OUTPUT -- JSON ONLY, no prose, no fences

```json
{"category": "...", "theme": "...", "purpose": "..."}
```

## HARD CONSTRAINTS

- You have NO tools this stage -- reason from the kind/reference/instruction alone. The reference itself is not fetched until a downstream pipeline dispatches.
- Output ONLY the JSON object.$T$;

v_match_template :=
$T$Kind: {{input.kind}}
Reference: {{input.ref}}
Instruction (if any): {{input.instruction}}

## CLASSIFICATION (from the classify stage)

{{stage_results.classify.output}}

## YOUR TASK -- find or propose the destination SCOPE

Call scope_candidates with the theme from the classification above -- it searches existing worlds/wikis/projects by name+description. Also use doc_search/pool_search if it helps you judge whether a candidate is a genuine fit.

Decide ONE of:
  (a) MATCHED -- an existing world/wiki/project genuinely fits this material. Report it as scope={"kind":"world"|"wiki"|"project","slug":"...","title":"..."}.
  (b) NOT MATCHED -- nothing existing fits. Propose a NEW scope named from the material's theme: proposed_scope={"kind":"world"|"wiki","slug":"kebab-case-slug","title":"...","rationale":"one sentence why this deserves its own scope"}. kind="world" ONLY when the classification's category is lore/fiction (an entity graph makes sense); everything else that needs a new home gets kind="wiki".

## OUTPUT -- JSON ONLY, no prose, no fences

```json
{"matched": true, "scope": {"kind": "...", "slug": "...", "title": "..."}, "proposed_scope": null, "purpose": "carry the purpose forward, refined if scope_candidates taught you something"}
```

(or, when nothing matched: "matched": false, "scope": null, "proposed_scope": {...})

## HARD CONSTRAINTS

- Call scope_candidates AT LEAST ONCE before deciding.
- Maximum 4 rounds of tool calls.
- Output ONLY the JSON object.$T$;

v_stages := jsonb_build_array(
    jsonb_build_object(
        'name', 'classify', 'next', 'match',
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'intake', 'auto_advance', true,
        'tools_disabled', true,
        'input_template', v_classify_template
    ),
    jsonb_build_object(
        'name', 'match', 'next', NULL,
        'model', 'kimi-k2.6', 'provider', 'opencode_go',
        'agent_family', 'intake', 'auto_advance', true,
        'tools_disabled', false, 'tool_groups', jsonb_build_array('substrate-read', 'intake-tools'),
        'input_template', v_match_template
    )
);

INSERT INTO stewards.pipelines (
    family, description, stages,
    sabbath_enabled, atonement_enabled,
    file_destination_template, file_content_jsonpath,
    maturity_ladder, auto_materialize_on_verified, metadata
)
VALUES (
    'route-intake',
    'raw-to-wiki, the auto-magic router. classify (category/theme/purpose) -> match (scope_candidates + doc_search/pool_search: an existing world/wiki/project, or propose a new one). disposition (deterministic, fires on match''s maturity->verified via an additive trigger, NOT a pipeline stage): a matched scope files immediately (act-and-report, no gate); an unmatched one lands a mountain-tier new-scope Hinge review. Approval creates the world/wiki and dispatches. dispatch (deterministic) routes by kind: url->crawl_start (98, guarded), video->playlist_add (yt overlay, guarded), file/text->wiki_organize_start (94, real). No file artifact -- the routing decision + its side effects ARE the artifact.',
    v_stages,
    false,  -- sabbath_enabled: mechanical routing, not a creative artifact
    false,  -- atonement_enabled
    NULL, NULL,
    '["raw","researched","verified"]'::jsonb,
    false,  -- auto_materialize_on_verified: no file; the dispatch side effects are the outcome
    jsonb_build_object('shape', 'route-intake')
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
    ('route-intake', 'classify', 'researched', 'Category/theme/purpose decided.'),
    ('route-intake', 'match',    'verified',   'Matched-or-proposed scope decided; fires route_intake_disposition (deterministic).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('route-intake', 'classify', 'kimi-k2.6', 'Category/theme/purpose; no tools.'),
    ('route-intake', 'match',    'kimi-k2.6', 'Scope search + decide; tools enabled (substrate-read + intake-tools).')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;

END $seed$;

-- =====================================================================
-- §4 — private helper: a stage's stage_results...output may be a
-- JSON-encoded STRING (a fenced/escaped LLM reply) or already an object;
-- unwrap either shape safely. Underscore-prefixed per the 91/92 convention
-- (see 92's _wiki_safe_jsonb). Used by disposition (match output) and its
-- purpose fallback (classify output).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards._route_intake_output_json(p_raw jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $fn$
BEGIN
    IF p_raw IS NULL THEN RETURN NULL; END IF;
    IF jsonb_typeof(p_raw) = 'string' THEN
        RETURN (p_raw #>> '{}')::jsonb;
    END IF;
    RETURN p_raw;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$fn$;
COMMENT ON FUNCTION stewards._route_intake_output_json(jsonb) IS
'99: private helper (underscore prefix, 91/92 convention) -- a stage''s stage_results...output may be a JSON-encoded STRING or already an object; unwrap either shape safely, NULL on malformed input, so one bad LLM reply never aborts disposition.';

-- =====================================================================
-- §5 — route_intake_dispatch: deterministic. Routes by the work_item's
-- input.kind to the pipeline/function that actually performs the intake.
-- Called both by disposition (matched-scope path, immediate) and by the
-- new-scope Hinge approval trigger (after the scope is created). Every
-- sibling call is guarded (to_regprocedure) and wrapped so a missing
-- dependency degrades to an honest note, never an exception that would
-- abort the caller's transaction (same discipline as 94's
-- wiki_organize_apply BEGIN/EXCEPTION-per-branch).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.route_intake_dispatch(
    p_work_item_id uuid,
    p_scope        jsonb,
    p_purpose      text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_kind        text;
    v_ref         text;
    v_purpose     text;
    v_scope_kind  text := p_scope ->> 'kind';
    v_scope_slug  text := p_scope ->> 'slug';
    v_added_slug  text;
    v_result      jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'route_intake_dispatch: work_item % not found', p_work_item_id;
    END IF;

    IF p_scope IS NULL OR v_scope_slug IS NULL OR v_scope_kind IS NULL THEN
        RETURN jsonb_build_object('dispatched', false, 'note', 'route_intake_dispatch: scope missing kind/slug');
    END IF;

    v_kind    := v_wi.input ->> 'kind';
    v_ref     := v_wi.input ->> 'ref';
    v_purpose := coalesce(nullif(p_purpose, ''), nullif(v_wi.input ->> 'instruction', ''),
                           'file this into ' || v_scope_slug);

    IF v_scope_kind = 'world' AND v_kind IN ('file', 'text') THEN
        -- world-build has NO SQL entry point anywhere in this codebase — it
        -- is dispatched via a raw chat turn (cmd/stewards-ui/api/world.go),
        -- not stewards.pipelines/work_item_create. Honest, not faked.
        v_result := jsonb_build_object('dispatched', false,
            'note', format('world-shaped %s intake: world-build has no SQL entry point in this build (dispatched via a chat turn, cmd/stewards-ui/api/world.go) — ref=%s queued for manual routing into world "%s"',
                            v_kind, v_ref, v_scope_slug));

    ELSIF v_kind = 'url' THEN
        IF to_regprocedure('stewards.crawl_start(text,text,jsonb,text,boolean)') IS NULL THEN
            v_result := jsonb_build_object('dispatched', false,
                'note', 'crawler (crawl_start, 98) is not installed in this build — url queued but not crawled');
        ELSE
            BEGIN
                PERFORM stewards.crawl_start(v_ref, v_purpose, jsonb_build_object('target_scope', p_scope));
                v_result := jsonb_build_object('dispatched', true, 'target', 'crawl_start', 'scope', p_scope);
            EXCEPTION WHEN OTHERS THEN
                v_result := jsonb_build_object('dispatched', false, 'note', 'crawl_start failed: ' || SQLERRM);
            END;
        END IF;

    ELSIF v_kind = 'video' THEN
        -- playlist_add (examples/playlist-digester.sql), NOT
        -- work_item_create('playlist-digest', ...) — the real digest stage
        -- pulls its OWN next video via playlist_next()/playlist_watch and
        -- would silently ignore an ad hoc work_item input.
        IF to_regprocedure('stewards.playlist_add(text,text,int)') IS NULL THEN
            v_result := jsonb_build_object('dispatched', false,
                'note', 'the yt digest overlay (examples/playlist-digester.sql, playlist_add) is not installed in this build — video queued but not digested');
        ELSE
            BEGIN
                v_added_slug := stewards.playlist_add(left(coalesce(v_purpose, 'route-intake video'), 200), v_ref, 100);
                v_result := jsonb_build_object('dispatched', true, 'target', 'playlist_add',
                    'playlist_slug', v_added_slug, 'scope', p_scope);
            EXCEPTION WHEN OTHERS THEN
                v_result := jsonb_build_object('dispatched', false, 'note', 'playlist_add failed: ' || SQLERRM);
            END;
        END IF;

    ELSIF v_kind IN ('file', 'text') THEN
        -- wiki_organize_start (94, real + core). The destination wiki gets
        -- the SAME slug as the matched/created scope; wiki_organize_apply
        -- (94) creates it if it doesn't exist yet (wiki_create is
        -- idempotent). The single doc/attachment still needs an
        -- agent-driven read (doc_import_corpus for a file, or it's already
        -- a pooled doc for 'text') before gather finds anything — noted.
        BEGIN
            PERFORM stewards.wiki_organize_start(
                jsonb_build_object('kind', 'project', 'value', coalesce(v_wi.project_association, v_scope_slug)),
                v_scope_slug, 'route-intake', NULL);
            v_result := jsonb_build_object('dispatched', true, 'target', 'wiki-organize', 'scope', p_scope,
                'note', CASE WHEN v_kind = 'file'
                             THEN format('ref=%s still needs an agent-driven doc_import_corpus into a project before wiki-organize''s gather stage finds anything', v_ref)
                             ELSE NULL END);
        EXCEPTION WHEN OTHERS THEN
            v_result := jsonb_build_object('dispatched', false, 'note', 'wiki_organize_start failed: ' || SQLERRM);
        END;

    ELSE
        v_result := jsonb_build_object('dispatched', false, 'note', 'unknown kind ' || coalesce(v_kind, '<null>'));
    END IF;

    RETURN v_result;
END;
$fn$;
COMMENT ON FUNCTION stewards.route_intake_dispatch(uuid, jsonb, text) IS
'99: deterministic dispatch by input.kind — url->crawl_start (98, guarded), video->playlist_add (yt overlay, guarded), file/text->wiki_organize_start (94, real; file additionally degrades honestly when scope.kind=world, since world-build has no SQL entry point). Every sibling call is to_regprocedure-guarded and exception-wrapped so a missing dependency returns an honest note, never an aborted transaction. Called by route_intake_disposition (matched path) and route_intake_new_scope_apply_trigger (after a new scope is created).';

-- =====================================================================
-- §6 — route_intake_disposition: deterministic. Reads the match stage's
-- JSON output; a matched scope files immediately (act-and-report); an
-- unmatched one parks a mountain-tier Hinge review. Mirrors
-- wiki_organize_apply's shape (94): the LLM proposes structured JSON, a
-- deterministic function decides the branch.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.route_intake_disposition(p_work_item_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_wi          stewards.work_items%ROWTYPE;
    v_match       jsonb;
    v_classify    jsonb;
    v_matched     boolean;
    v_scope       jsonb;
    v_proposed    jsonb;
    v_purpose     text;
    v_hid         bigint;
    v_dispatch    jsonb;
BEGIN
    SELECT * INTO v_wi FROM stewards.work_items WHERE id = p_work_item_id;
    IF v_wi.id IS NULL THEN
        RAISE EXCEPTION 'route_intake_disposition: work_item % not found', p_work_item_id;
    END IF;

    v_match := stewards._route_intake_output_json(v_wi.stage_results -> 'match' -> 'output');
    IF v_match IS NULL THEN
        RAISE EXCEPTION 'route_intake_disposition: no (valid) match output on work_item %', p_work_item_id;
    END IF;

    v_classify := stewards._route_intake_output_json(v_wi.stage_results -> 'classify' -> 'output');
    v_matched  := coalesce((v_match ->> 'matched')::boolean, false);
    v_scope    := v_match -> 'scope';
    v_proposed := v_match -> 'proposed_scope';
    v_purpose  := coalesce(nullif(v_match ->> 'purpose', ''), nullif(v_wi.input ->> 'instruction', ''),
                            v_classify ->> 'purpose');

    IF v_matched AND v_scope IS NOT NULL AND jsonb_typeof(v_scope) = 'object' THEN
        -- act-and-report: filing into an EXISTING scope is execution, not a
        -- new standing capability — no gate (stuffy-in-the-loop bins 1-2).
        v_dispatch := stewards.route_intake_dispatch(p_work_item_id, v_scope, v_purpose);
        RETURN jsonb_build_object('disposition', 'filed', 'scope', v_scope, 'dispatch', v_dispatch);
    END IF;

    IF v_proposed IS NULL OR jsonb_typeof(v_proposed) <> 'object' THEN
        RAISE EXCEPTION 'route_intake_disposition: match output has neither a matched scope nor a proposed_scope — %', v_match;
    END IF;

    -- mountain tier — a NEW world/wiki namespace entry is Michael's call
    -- (same reasoning as 92's wiki_merge_propose). hinge_escalate_always_kinds
    -- is appended below (§8) so this NEVER auto-approves regardless of
    -- future hinge_auto_approve_kinds grants, defense-in-depth exactly like
    -- wiki-merge.
    v_hid := stewards.hinge_enqueue(
        'new-scope',
        format('route-intake proposes a new %s scope: %s', v_proposed ->> 'kind', v_proposed ->> 'title'),
        jsonb_build_object(
            'work_item_id', p_work_item_id::text,
            'proposed_scope', v_proposed,
            'kind', v_wi.input ->> 'kind',
            'ref', v_wi.input ->> 'ref',
            'purpose', v_purpose
        ),
        'route_intake_disposition'
    );
    RETURN jsonb_build_object('disposition', 'proposed', 'proposed_scope', v_proposed, 'hinge_review_id', v_hid);
END;
$fn$;
COMMENT ON FUNCTION stewards.route_intake_disposition(uuid) IS
'99: deterministic disposition for route-intake — reads match''s JSON output; a matched scope dispatches immediately (act-and-report, no gate); an unmatched one parks a kind=new-scope Hinge review (mountain tier — Michael approves new scope creation). Fired by the additive trigger work_items_route_intake_disposition, not a pipeline stage — mirrors wiki_organize_apply''s shape (94).';

-- ── the additive trigger — a SEPARATE trigger object, scoped tightly to
-- pipeline_family='route-intake'. Precedent: 25-corpus.sql's
-- work_items_fill_project, reused again by 94's work_items_wiki_organize_apply.
CREATE OR REPLACE FUNCTION stewards.route_intake_disposition_trigger()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    IF NEW.pipeline_family = 'route-intake' THEN
        BEGIN
            PERFORM stewards.route_intake_disposition(NEW.id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'route_intake_disposition_trigger: disposition failed for work_item=%: %', NEW.id, SQLERRM;
        END;
    END IF;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS work_items_route_intake_disposition ON stewards.work_items;
CREATE TRIGGER work_items_route_intake_disposition
    AFTER UPDATE OF maturity ON stewards.work_items
    FOR EACH ROW
    WHEN (NEW.maturity = 'verified' AND OLD.maturity IS DISTINCT FROM 'verified')
    EXECUTE FUNCTION stewards.route_intake_disposition_trigger();

-- =====================================================================
-- §7 — the new-scope Hinge approval trigger. Fires the moment a
-- kind='new-scope' review's status flips to 'approved' (Michael's own
-- approval — the escalate-always wall in §8 only binds the claude-hinge
-- reviewer, never Michael, per hinge_record_verdict's v_michael bypass).
-- Creates the world or wiki, then dispatches. Self-terminating (sets
-- status='applied', which no longer matches the WHEN clause) — pattern
-- reused verbatim from wiki_merge_apply_trigger (92) /
-- memory_apply_approved_link (41).
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.route_intake_new_scope_apply_trigger()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_proposed     jsonb := NEW.payload -> 'proposed_scope';
    v_work_item_id uuid;
    v_scope_kind   text := v_proposed ->> 'kind';
    v_slug         text := v_proposed ->> 'slug';
    v_title        text := coalesce(nullif(v_proposed ->> 'title', ''), initcap(replace(coalesce(v_slug, ''), '-', ' ')));
    v_summary      text := coalesce(nullif(v_proposed ->> 'rationale', ''),
                                     'auto-proposed by route-intake from ' || coalesce(NEW.payload ->> 'ref', 'an unspecified source'));
    v_scope        jsonb;
    v_purpose      text := NEW.payload ->> 'purpose';
    v_dispatch     jsonb;
BEGIN
    BEGIN
        v_work_item_id := (NEW.payload ->> 'work_item_id')::uuid;
    EXCEPTION WHEN OTHERS THEN
        v_work_item_id := NULL;
    END;

    IF v_slug IS NULL OR btrim(v_slug) = '' OR v_scope_kind IS NULL THEN
        UPDATE stewards.hinge_reviews
           SET payload = payload || jsonb_build_object('apply_error', 'new-scope apply: proposed_scope missing kind/slug')
         WHERE id = NEW.id;
        RETURN NEW;  -- leave status='approved' (not 'applied') so the gap stays visible
    END IF;

    IF v_scope_kind = 'world' THEN
        BEGIN
            INSERT INTO stewards.worlds (slug, name, summary)
            VALUES (v_slug, v_title, v_summary)
            ON CONFLICT (slug) DO UPDATE SET name = EXCLUDED.name, summary = EXCLUDED.summary;
        EXCEPTION WHEN OTHERS THEN
            UPDATE stewards.hinge_reviews
               SET payload = payload || jsonb_build_object('apply_error', 'world create failed: ' || SQLERRM)
             WHERE id = NEW.id;
            RETURN NEW;
        END;
        -- best-effort: give the new world a readable wiki face (97, the
        -- BRIDGE sibling builder — may not exist in this build; guarded,
        -- degrades honestly, never blocks the world's creation).
        IF to_regprocedure('stewards.world_to_wiki(text)') IS NOT NULL THEN
            BEGIN
                PERFORM stewards.world_to_wiki(v_slug);
            EXCEPTION WHEN OTHERS THEN
                RAISE NOTICE 'route_intake_new_scope_apply_trigger: world_to_wiki failed for %: %', v_slug, SQLERRM;
            END;
        ELSE
            RAISE NOTICE 'route_intake_new_scope_apply_trigger: world_to_wiki (97) not installed — world % created without a wiki face', v_slug;
        END IF;
        v_scope := jsonb_build_object('kind', 'world', 'slug', v_slug, 'title', v_title);
    ELSE
        BEGIN
            PERFORM stewards.wiki_create(v_slug, v_title, 'collection', '{}'::jsonb);
        EXCEPTION WHEN OTHERS THEN
            UPDATE stewards.hinge_reviews
               SET payload = payload || jsonb_build_object('apply_error', 'wiki create failed: ' || SQLERRM)
             WHERE id = NEW.id;
            RETURN NEW;
        END;
        v_scope := jsonb_build_object('kind', 'wiki', 'slug', v_slug, 'title', v_title);
    END IF;

    IF v_work_item_id IS NOT NULL THEN
        BEGIN
            v_dispatch := stewards.route_intake_dispatch(v_work_item_id, v_scope, v_purpose);
        EXCEPTION WHEN OTHERS THEN
            v_dispatch := jsonb_build_object('dispatched', false, 'note', 'dispatch after scope creation failed: ' || SQLERRM);
        END;
        UPDATE stewards.hinge_reviews
           SET payload = payload || jsonb_build_object('created_scope', v_scope, 'dispatch', v_dispatch)
         WHERE id = NEW.id;
    END IF;

    UPDATE stewards.hinge_reviews SET status = 'applied', applied_at = now() WHERE id = NEW.id;
    RETURN NEW;
END;
$fn$;

DROP TRIGGER IF EXISTS hinge_apply_new_scope ON stewards.hinge_reviews;
CREATE TRIGGER hinge_apply_new_scope
AFTER UPDATE OF status ON stewards.hinge_reviews
FOR EACH ROW WHEN (NEW.kind = 'new-scope' AND NEW.status = 'approved')
EXECUTE FUNCTION stewards.route_intake_new_scope_apply_trigger();

COMMENT ON FUNCTION stewards.route_intake_new_scope_apply_trigger() IS
'99: fires on hinge_reviews status -> approved for kind=new-scope. Creates the world (stewards.worlds, best-effort world_to_wiki/97 if installed) or wiki (wiki_create), then calls route_intake_dispatch with the fresh scope. Self-terminating (marks the review applied) — verbatim pattern from wiki_merge_apply_trigger (92).';

-- =====================================================================
-- §8 — new-scope ALWAYS escalates to Michael regardless of the
-- claude-hinge reviewer's verdict — same defense-in-depth append as
-- 92's wiki-merge and 84's tool-confirm (idempotent).
-- =====================================================================
UPDATE stewards.config
   SET value = value || '["new-scope"]'::jsonb
 WHERE key = 'hinge_escalate_always_kinds'
   AND NOT (value ? 'new-scope');

-- =====================================================================
-- §9 — route_intake: the entry point. Mirrors wiki_organize_start's role
-- (94) — the one call that kicks a run off, registered as a tool so a
-- human or another agent can invoke it conversationally.
-- =====================================================================
CREATE OR REPLACE FUNCTION stewards.route_intake(
    p_kind        text,
    p_ref         text,
    p_instruction text DEFAULT NULL
) RETURNS uuid LANGUAGE plpgsql AS $fn$
DECLARE
    v_kind text := lower(btrim(coalesce(p_kind, '')));
    v_ref  text := btrim(coalesce(p_ref, ''));
    v_slug text;
    v_id   uuid;
BEGIN
    IF v_kind NOT IN ('url', 'file', 'video', 'text') THEN
        RAISE EXCEPTION 'route_intake: kind must be one of url|file|video|text, got %', p_kind;
    END IF;
    IF v_ref = '' THEN
        RAISE EXCEPTION 'route_intake: ref is required (a url, an attachment id, or a doc slug)';
    END IF;

    v_slug := 'route-intake-' || v_kind || '-' || to_char(now() AT TIME ZONE 'UTC', 'YYYYMMDD-HH24MISS-MS');

    v_id := stewards.work_item_create(
        p_pipeline_family => 'route-intake',
        p_input           => jsonb_build_object(
            'binding_question', format('Classify and route this %s (%s)%s.',
                v_kind, left(v_ref, 200),
                CASE WHEN coalesce(p_instruction, '') <> '' THEN ' — instruction: ' || p_instruction
                     ELSE ' — auto-magic (no instruction given)' END),
            'kind', v_kind,
            'ref', v_ref,
            'instruction', nullif(btrim(coalesce(p_instruction, '')), '')
        ),
        p_slug  => v_slug,
        p_actor => 'human'
    );

    PERFORM stewards.work_item_dispatch_stage(v_id);
    RETURN v_id;
END;
$fn$;
COMMENT ON FUNCTION stewards.route_intake(text, text, text) IS
'99: raw-to-wiki entry point. kind: url|file|video|text; ref: the url, a chat_attachments id (as text), or a doc slug; instruction: optional purpose-filter ("this is an AI video, review it for new information that can benefit us"). Creates + dispatches a route-intake work_item; classify->match run, then the deterministic disposition/dispatch trigger chain files it into an existing scope or parks a mountain-tier new-scope Hinge review.';

CREATE OR REPLACE FUNCTION stewards.route_intake_tool(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $FN$
DECLARE v_id uuid;
BEGIN
    IF coalesce(btrim(p_args ->> 'kind'), '') = '' OR coalesce(btrim(p_args ->> 'ref'), '') = '' THEN
        RETURN '{"error":"kind and ref required"}'::jsonb;
    END IF;
    v_id := stewards.route_intake(p_args ->> 'kind', p_args ->> 'ref', p_args ->> 'instruction');
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_id::text);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'error', SQLERRM);
END;
$FN$;

INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, active) VALUES
( 'route_intake',
  'Drop a video, a website, a file, or a piece of text and have it auto-sorted into the right world/wiki/project (creating a new one by theme if nothing fits — gated for Michael''s approval). Args: kind (url|file|video|text, required), ref (the url, a chat_attachments id as text, or a doc slug, required), instruction (optional — e.g. "this is an AI video, review it for new information that can benefit us and file those things away"; becomes the extraction purpose).',
  '{"type":"object","required":["kind","ref"],"properties":{"kind":{"type":"string","enum":["url","file","video","text"]},"ref":{"type":"string"},"instruction":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"stewards","name":"route_intake_tool"}'::jsonb, true )
ON CONFLICT (name) DO UPDATE SET description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, active = true;

-- =====================================================================
-- End of 99-route-intake.sql
-- =====================================================================
