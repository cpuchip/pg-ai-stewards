-- =====================================================================
-- 35-research-doc-construction.sql — recast research-summary + research-write
-- onto agentic doc-construction (R2b/R2c of the local-learnings rollout).
-- =====================================================================
-- 13-research-pipelines.sql defines these as one-shot pipelines whose synthesize
-- stage EMITS the whole digest/piece as its generation (then review verifies the
-- text). On a small local model that one-shot generation trips the reaper, hogs
-- the slot, and 500s on grammar — the same failures the playlist + book digesters
-- hit. This file re-shapes both so the model BUILDS the artifact via doc_* tool-
-- call diffs and its chat reply is a journal (agentic-doc-construction.md):
--
--   research-summary:  gather -> build -> critique
--   research-write:    context_gather -> gather -> build -> critique
--
-- It swaps synthesize->build (doc_* construction, no publish) and review->critique
-- (doc_current -> doc_read -> doc_patch -> doc_finalize), preserving the well-tuned
-- gather / context_gather stages (only their `next` + model role are touched). The
-- pipeline pools its doc via doc_finalize (which falls back to the work item's
-- project, since a research digest has no static project like a book), so
-- auto_materialize is OFF + metadata.pools_via_tool is set (08-gates skips the
-- auto-pool arm — else the critique journal would be pooled as the digest).
--
-- Stages name ROLES (ingest/reason/critic); the alias router picks the best
-- available member (local-first via the workspace overlay; public default via
-- examples/models.sql). Idempotent: the swaps match both the old (synthesize/
-- review) and new (build/critique) stage names. Requires 13 + 34 (doc tools).
-- =====================================================================

-- ── shared stage builders (build = doc_* construct; critique = patch + finalize)
DO $recast$
DECLARE
    v_summary_build    jsonb;
    v_summary_critique jsonb;
    v_write_build      jsonb;
    v_write_critique   jsonb;
BEGIN

-- research-summary BUILD (daily digest, from the items brief)
v_summary_build := jsonb_build_object(
    'name','build','next','critique','model','reason','agent_family','research',
    'auto_advance',true,'tools_disabled',false,
    'input_template',
      'Binding question: {{input.binding_question}}' || E'\n\n' ||
      'You are the BUILD stage. BUILD the daily digest as a document using your doc tools — do NOT write the digest as your reply.' || E'\n\n' ||
      'Items brief from the gather stage:' || E'\n\n' ||
      '{{stage_results.gather.output}}' || E'\n\n' ||
      'Steps:' || E'\n' ||
      '1. Call doc_create with a short title derived from the binding question (no project — it inherits the work item''s intent).' || E'\n' ||
      '2. Build the digest with doc_append_section (one call each, small). A 24-hour scan, ~300-700 words total — not a deep dive. Every claim gets an inline [Title](URL) link; paraphrase by default. Sections (adapt to what the day produced):' || E'\n' ||
      '   - "Headlines" — the 1-3 most important items, one short paragraph each.' || E'\n' ||
      '   - "Notable" — second-tier items, one line each with a link.' || E'\n' ||
      '   - "Skeptical takes" — credible dissenting voices, if any.' || E'\n' ||
      '   - "Carry-forward" — what to watch tomorrow; any deep-research candidates.' || E'\n' ||
      '   If the day was slow, say so honestly — a three-line digest beats manufactured importance.' || E'\n' ||
      '3. Call doc_read to review; fix weak spots with doc_patch. Do NOT finalize — the critique stage does.' || E'\n' ||
      '4. Reply with a short JOURNAL (1-3 sentences) + the draft handle. Do NOT paste the digest.' );

-- research-summary CRITIQUE (review the draft, then doc_finalize)
v_summary_critique := jsonb_build_object(
    'name','critique','next',NULL,'model','critic','agent_family','research',
    'auto_advance',true,'tools_disabled',false,
    'input_template',
      'Binding question: {{input.binding_question}}' || E'\n\n' ||
      'You are the CRITIQUE stage — the final review before the digest is pooled. The build stage built a draft for this run.' || E'\n\n' ||
      'Work ONLY from the draft. Your tools are doc_current, doc_read, doc_patch, doc_append_section, doc_finalize. Do NOT fetch_url or web_search — you are reviewing the draft, not re-gathering. Converge to finalize.' || E'\n\n' ||
      'Steps:' || E'\n' ||
      '1. doc_current to get the handle, then doc_read it once.' || E'\n' ||
      '2. Check: every claim has an inline link; recency (items within ~24-48h or framed as still-trending); no rhetorical inflation (framing no hotter than the source); honest emptiness if the day was slow. Fix problems with doc_patch (a few targeted edits, not a rewrite).' || E'\n' ||
      '3. Call doc_finalize with the handle to pool the digest.' || E'\n' ||
      '4. Reply with a short JOURNAL (1-3 sentences): what you fixed and that you pooled it. Do NOT paste the digest.' );

-- research-write BUILD (deep piece, from prior context + sources brief)
v_write_build := jsonb_build_object(
    'name','build','next','critique','model','reason','agent_family','research',
    'auto_advance',true,'tools_disabled',false,
    'input_template',
      'Binding question: {{input.binding_question}}' || E'\n\n' ||
      'You are the BUILD stage. BUILD the research piece as a document using your doc tools — do NOT write the piece as your reply.' || E'\n\n' ||
      'Prior context (context_gather stage):' || E'\n' || '{{stage_results.context_gather.output}}' || E'\n\n' ||
      'Sources brief (gather stage):' || E'\n' || '{{stage_results.gather.output}}' || E'\n\n' ||
      'Steps:' || E'\n' ||
      '1. Call doc_create with a title derived from the binding question (no project — it inherits the work item''s intent).' || E'\n' ||
      '2. Build the piece with doc_append_section (one call each). Draw on the sources brief; do NOT introduce new sources. Every non-trivial claim cites its source inline [Title](URL); say so where a claim is your synthesis across sources. Quote verbatim only when the source text is in front of you. Suggested sections (adapt to the binding question): "Headlines" (3-5 findings that answer it), "Notable", "Skeptical takes", "Open questions". 800-2500 words by depth; resist padding; honest uncertainty over fabrication.' || E'\n' ||
      '3. Call doc_read to review; fix weak or uncited claims with doc_patch. Do NOT finalize — the critique stage does.' || E'\n' ||
      '4. Reply with a short JOURNAL (1-3 sentences) + the draft handle. Do NOT paste the piece.' );

-- research-write CRITIQUE
v_write_critique := jsonb_build_object(
    'name','critique','next',NULL,'model','critic','agent_family','research',
    'auto_advance',true,'tools_disabled',false,
    'input_template',
      'Binding question: {{input.binding_question}}' || E'\n\n' ||
      'You are the CRITIQUE stage — the final review before the piece is pooled. The build stage built a draft for this run.' || E'\n\n' ||
      'Work ONLY from the draft. Tools: doc_current, doc_read, doc_patch, doc_append_section, doc_finalize. Do NOT fetch_url or web_search — review the draft, do not re-research. Converge to finalize.' || E'\n\n' ||
      'Steps:' || E'\n' ||
      '1. doc_current to get the handle, then doc_read it once.' || E'\n' ||
      '2. Check against the binding question: every factual claim has a citation; citations are credible; the piece actually answers what was asked; honest uncertainty where the sources are thin (no fabricated certainty). Fix with doc_patch; where a claim is unverifiable from the draft, flag it in the text rather than inventing support.' || E'\n' ||
      '3. Call doc_finalize with the handle to pool the piece.' || E'\n' ||
      '4. Reply with a short JOURNAL (1-3 sentences): what you fixed and that you pooled it. Do NOT paste the piece.' );

-- ── research-summary: swap synthesize->build, review->critique; gather->ingest+next=build
UPDATE stewards.pipelines p SET stages = (
    SELECT jsonb_agg(
        CASE
            WHEN e->>'name' = 'gather'                  THEN (e - 'provider') || jsonb_build_object('model','ingest','next','build')
            WHEN e->>'name' IN ('synthesize','build')   THEN v_summary_build
            WHEN e->>'name' IN ('review','critique')    THEN v_summary_critique
            ELSE e
        END ORDER BY ord)
    FROM jsonb_array_elements(p.stages) WITH ORDINALITY t(e, ord))
WHERE p.family = 'research-summary';

-- ── research-write: swap synthesize->build, review->critique; context_gather/gather->ingest, gather.next=build
UPDATE stewards.pipelines p SET stages = (
    SELECT jsonb_agg(
        CASE
            WHEN e->>'name' = 'context_gather'          THEN (e - 'provider') || jsonb_build_object('model','ingest')
            WHEN e->>'name' = 'gather'                  THEN (e - 'provider') || jsonb_build_object('model','ingest','next','build')
            WHEN e->>'name' IN ('synthesize','build')   THEN v_write_build
            WHEN e->>'name' IN ('review','critique')    THEN v_write_critique
            ELSE e
        END ORDER BY ord)
    FROM jsonb_array_elements(p.stages) WITH ORDINALITY t(e, ord))
WHERE p.family = 'research-write';

END $recast$;

-- ── pipeline-level: pool via the finalize tool, not the auto-materialize arm.
-- doc_finalize pools the doc (project-tagged from the work item) during critique;
-- the final stage output is a journal, so turn auto_materialize OFF and declare
-- pools_via_tool so on_maturity_verified does NOT auto-pool the journal (08-gates).
UPDATE stewards.pipelines
   SET auto_materialize_on_verified = false,
       file_destination_template    = NULL,
       file_content_jsonpath        = NULL,
       metadata = COALESCE(metadata, '{}'::jsonb) || jsonb_build_object('pools_via_tool', true),
       updated_at = now()
 WHERE family IN ('research-summary', 'research-write');

-- ── stage_models + maturity: rename synthesize->build, review->critique (cosmetic;
--    main dispatch reads the stages jsonb, but keep these consistent).
DELETE FROM stewards.stage_models
 WHERE pipeline_family IN ('research-summary','research-write') AND stage_name IN ('synthesize','review');
INSERT INTO stewards.stage_models (pipeline_family, stage_name, default_model, notes) VALUES
    ('research-summary','build',    'reason', 'Build the digest as a doc via doc_* (no publish); tools on. Local reason alias.'),
    ('research-summary','critique', 'critic', 'Review the draft + doc_finalize; tools on, no re-research. Local critic alias.'),
    ('research-write',  'build',    'reason', 'Build the piece as a doc via doc_* (no publish); tools on. Local reason alias.'),
    ('research-write',  'critique', 'critic', 'Review the draft + doc_finalize; tools on, no re-research. Local critic alias.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    default_model = EXCLUDED.default_model, notes = EXCLUDED.notes;
-- gather/context_gather move to the ingest role too
UPDATE stewards.stage_models SET default_model='ingest'
 WHERE pipeline_family IN ('research-summary','research-write') AND stage_name IN ('gather','context_gather');

DELETE FROM stewards.pipeline_stage_maturity
 WHERE pipeline_family IN ('research-summary','research-write') AND stage_name IN ('synthesize','review');
INSERT INTO stewards.pipeline_stage_maturity (pipeline_family, stage_name, produces_maturity, notes) VALUES
    ('research-summary','build',    'planned',  'Draft built; ready for the critique pass.'),
    ('research-summary','critique', 'verified', 'Reviewed + pooled via doc_finalize.'),
    ('research-write',  'build',    'planned',  'Draft built; ready for the critique pass.'),
    ('research-write',  'critique', 'verified', 'Reviewed + pooled via doc_finalize.')
ON CONFLICT (pipeline_family, stage_name) DO UPDATE SET
    produces_maturity = EXCLUDED.produces_maturity, notes = EXCLUDED.notes;

-- =====================================================================
-- End of 35-research-doc-construction.sql
-- =====================================================================
