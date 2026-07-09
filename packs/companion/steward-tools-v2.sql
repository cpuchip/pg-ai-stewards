-- =====================================================================
-- packs/companion/steward-tools-v2.sql — the Jarvis wave
-- =====================================================================
-- Ratified by Michael (2026-07-09 "Jarvis list"): forge_start only ever
-- starts the forge pipeline; steward-tools.sql's first wave gave the
-- companion diagnosis + recovery verbs but never a way to start REAL work
-- by voice, nor a way to have a doc read aloud without dumping the whole
-- body into a TTS engine. This wave adds both. Apply AFTER steward-tools.sql.
--
-- The trust shape, stated plainly:
--   task_start   write_local  allowlisted — the generalization of
--                forge_start to ANY registered pipeline family. NOT safe
--                by construction the way forge is (most pipelines run to
--                completion with no bell in between — code-pr auto-advances
--                straight to an opened draft PR). The safety net here is
--                the VERBAL GATE stated in the tool description: the seat
--                must confirm the pipeline family and the wish wording
--                aloud and hear an explicit yes before ever calling this.
--                Refuses unknown families (lists the real ones), rate-
--                limited 5/hour across every family (a single voice
--                session cannot fire off an unbounded run of pipelines).
--   doc_brief    read         free — a doc's shape + a paragraph-bounded
--                excerpt, sized for a spoken summary rather than a full
--                verbatim read.

-- ── task_start: start ANY pipeline family by voice, verbally gated ──────
CREATE OR REPLACE FUNCTION companion.task_start(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_family   text := btrim(coalesce(p_args->>'pipeline_family',''));
    v_wish     text := btrim(coalesce(p_args->>'assignment',''));
    v_slug     text := nullif(btrim(coalesce(p_args->>'slug','')), '');
    v_families text;
    v_recent   int;
    v_wi       uuid;
    v_wq       bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM stewards.pipelines WHERE family = v_family) THEN
        SELECT string_agg(family, ', ' ORDER BY family) INTO v_families FROM stewards.pipelines;
        RETURN jsonb_build_object('error',
            'pipeline_family "' || v_family || '" is not a known pipeline — valid families: ' ||
            coalesce(v_families, '(none registered)'));
    END IF;
    IF length(v_wish) < 10 THEN
        RETURN jsonb_build_object('error','assignment required — describe the work in a sentence or three');
    END IF;
    IF length(v_wish) > 4000 THEN
        RETURN jsonb_build_object('error','assignment too long (4000 chars max)');
    END IF;
    IF v_slug IS NOT NULL AND EXISTS (SELECT 1 FROM stewards.work_items WHERE slug = v_slug) THEN
        RETURN jsonb_build_object('error','slug "' || v_slug || '" is already in use — pick another or leave it out');
    END IF;

    -- Rate limit: 5/hour across EVERY voice-started work item, any pipeline
    -- family. forge_start could scope its count by pipeline_family='forge'
    -- alone; task_start spans every family, so the count keys off a marker
    -- this function stamps into input (the only reliable "started by voice"
    -- signal — work_items carries no created-via column).
    SELECT count(*) INTO v_recent FROM stewards.work_items
     WHERE input->>'_started_via' = 'companion.task_start'
       AND created_at > now() - interval '1 hour';
    IF v_recent >= 5 THEN
        RETURN jsonb_build_object('error','voice task-start rate limit: 5 per hour — plenty already queued this hour');
    END IF;

    -- Most pipelines' first-stage template reads {{input.binding_question}}
    -- (code-pr, code-write, code-deploy, research, wiki, …); forge alone
    -- reads {{input.assignment}}. Stamp both so either convention resolves
    -- without task_start needing to know each family's template shape. A
    -- pipeline needing MORE than one text field (code-pr's repo/sandbox,
    -- say) will still hard-fail at the stage that needs it — visible via
    -- work_item_show, same as any other missing-field failure.
    v_wi := stewards.work_item_create(v_family,
              jsonb_build_object('assignment', v_wish, 'binding_question', v_wish,
                                  '_started_via', 'companion.task_start'),
              v_slug, coalesce(p_args->>'_session_id','companion'), NULL,
              (SELECT id FROM stewards.intents WHERE slug='companion'));
    v_wq := stewards.work_item_dispatch_stage_safe(v_wi, NULL, false);
    RETURN jsonb_build_object('ok', true, 'work_item_id', v_wi, 'pipeline_family', v_family,
        'dispatched', v_wq IS NOT NULL,
        'note', 'started on the ' || v_family || ' pipeline. Track it with work_item_show; nothing beyond this stage runs without whatever bell that pipeline itself declares.');
END;
$fn$;
COMMENT ON FUNCTION companion.task_start(jsonb) IS
'companion pack: start any registered pipeline family from a spoken wish — the generalization of forge_start. Refuses unknown families (lists the real ones) and over-length wishes; rate-limited 5/hour across every family. NOT safe by construction like forge — most pipelines run to completion with no further approval bell. VERBAL GATE (procedural, stated for the calling seat): confirm the pipeline family AND the wish wording aloud and hear an explicit yes before calling.';

-- ── doc_brief: a doc's shape + a spoken-sized excerpt ───────────────────
CREATE OR REPLACE FUNCTION companion.doc_brief(p_args jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
    v_slug    text := nullif(btrim(coalesce(p_args->>'slug','')), '');
    v_id      text := nullif(btrim(coalesce(p_args->>'id','')), '');
    v_key     text := coalesce(v_slug, v_id);
    v_doc     stewards.docs%ROWTYPE;
    v_window  text;
    v_cut     text;
    v_brief   text;
    v_words   int;
    v_nearest jsonb;
BEGIN
    IF v_key IS NULL THEN
        RETURN jsonb_build_object('error','slug or id required');
    END IF;

    IF v_id IS NOT NULL THEN
        SELECT * INTO v_doc FROM stewards.docs WHERE id = v_id;
    ELSE
        SELECT * INTO v_doc FROM stewards.docs WHERE slug = v_slug;
    END IF;

    IF v_doc.id IS NULL THEN
        -- ILIKE nearest-slug fallback (no pg_trgm in this codebase — a
        -- deliberate boundary, extension/v02-governance.sql:4977 /
        -- v22-route-intake.sql:79 — so this stays substring matching, not
        -- a similarity score).
        SELECT coalesce(jsonb_agg(s.slug ORDER BY s.slug), '[]'::jsonb) INTO v_nearest
          FROM (
              SELECT slug FROM stewards.docs
               WHERE slug ILIKE '%' || v_key || '%' OR title ILIKE '%' || v_key || '%'
               ORDER BY slug LIMIT 3
          ) s;
        RETURN jsonb_build_object('error', 'no doc found for "' || v_key || '"',
            'nearest_slugs', v_nearest);
    END IF;

    IF char_length(v_doc.body) <= 1200 THEN
        v_brief := v_doc.body;
    ELSE
        v_window := left(v_doc.body, 1200);
        -- Break at the last paragraph boundary in the window so a spoken
        -- brief never stops mid-sentence; fall back to the last line break,
        -- then the last word boundary, before giving up and cutting flat.
        v_cut := substring(v_window from '^(.*\n\s*\n)');
        IF v_cut IS NULL THEN v_cut := substring(v_window from '^(.*\n)'); END IF;
        IF v_cut IS NULL THEN v_cut := substring(v_window from '^(.*\s)'); END IF;
        -- btrim(text) with no explicit characters only strips SPACE, not
        -- newlines/tabs — a captured "...word\n\n" would keep its trailing
        -- blank line verbatim. regexp_replace with \s+ actually reaches
        -- every whitespace class.
        v_brief := regexp_replace(coalesce(v_cut, v_window), '^\s+|\s+$', '', 'g') || E' …';
    END IF;

    v_words := CASE WHEN btrim(coalesce(v_doc.body,'')) = '' THEN 0
                     ELSE array_length(regexp_split_to_array(btrim(v_doc.body), '\s+'), 1) END;

    RETURN jsonb_build_object(
        'title', v_doc.title, 'kind', v_doc.kind, 'updated_at', v_doc.updated_at,
        'word_count', v_words, 'brief', v_brief);
END;
$fn$;
COMMENT ON FUNCTION companion.doc_brief(jsonb) IS
'companion pack: a doc''s shape (title, kind, updated_at, word_count) plus its body trimmed to ~1200 chars at a paragraph boundary — sized for a spoken summary, never the whole doc verbatim. Args: slug or id. Miss returns the 3 nearest slugs by ILIKE (no pg_trgm in this codebase).';

-- ── register the tools ──────────────────────────────────────────────────
INSERT INTO stewards.tool_defs (name, description, args_schema, execute_target, effect_class, active) VALUES
( 'task_start',
  'Start ANY registered pipeline by voice — name the pipeline_family and describe the work. Confirms the family exists (refusal lists the real ones) and rate-limits to 5/hour across every family. VERBAL GATE: first confirm the pipeline family and the wish wording aloud, then call this ONLY after an explicit yes — most pipelines run straight through once started, unlike the bell-gated forge.',
  '{"type":"object","required":["pipeline_family","assignment"],"properties":{"pipeline_family":{"type":"string","description":"an existing stewards.pipelines family, e.g. research, code-write, wiki-crawl"},"assignment":{"type":"string","description":"the work, a sentence or three"},"slug":{"type":"string","description":"optional unique slug for the work item"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"task_start"}'::jsonb, 'write_local', true ),
( 'doc_brief',
  'Get a doc''s shape and a spoken-sized brief (title, kind, updated_at, word_count, and the body trimmed to ~1200 chars at a paragraph break) by slug or id. A miss returns the 3 nearest slugs.',
  '{"type":"object","properties":{"slug":{"type":"string"},"id":{"type":"string"}}}'::jsonb,
  '{"kind":"sql_fn","schema":"companion","name":"doc_brief"}'::jsonb, 'read', true )
ON CONFLICT (name) DO UPDATE SET
    description = EXCLUDED.description, args_schema = EXCLUDED.args_schema,
    execute_target = EXCLUDED.execute_target, effect_class = EXCLUDED.effect_class, active = true;

-- ── widen the Arc-C dynamic-write allowlist, deliberately ────────────────
-- task_start is the one addition here: doc_brief is read-class (free on
-- the Arc-C surface already). task_start writes a work_item + dispatches a
-- stage, gated procedurally by the verbal-confirm requirement in its own
-- description rather than by construction — widened anyway because that is
-- exactly the "converse about work and get it started" verb the companion
-- was ratified for, same posture as forge_start/work_item_unstick before it.
SELECT stewards.config_set('arc_c_dynamic_write_allowlist',
        '["reminder_set","reminder_cancel","companion_approve","forge_start","work_item_unstick","models_health_check","task_start"]'::jsonb,
        'companion pack: write-class sql_fn tools dispatchable via substrate_tool from harness seats (Arc-C). Widened 2026-07-09 (Jarvis wave): task_start, the forge_start generalization to any pipeline family (verbal-gate procedural, not bell-gated).');
