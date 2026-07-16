-- =====================================================================
-- v37-verdict-regex-markdown.sql — code-pr verdict regexes must tolerate
-- markdown emphasis on the reviewer's verdict line.
-- =====================================================================
-- Incident (work_item 5633b0e3-bcee-4501-9f7b-7b54c6f92a96, slug
-- coder-proof-4, original run 2026-06-13): the review critic returned a
-- PASSING verdict but wrote it as "**REVIEW: passes**" (markdown bold).
-- The route_on rule seeded by v09 (was 42-route-on) uses
--   unless => (^|\n)\s*REVIEW:\s*passes
-- `\s*` cannot consume the leading `**`, so the passes-verdict did NOT
-- match, the `unless` fired, and a CORRECT, COMPLETE change was looped back
-- to `implement` until the revise cap (2) parked it awaiting_review.
--
-- Verified live before this migration:
--   SELECT '**REVIEW: passes**' ~* '(^|\n)\s*REVIEW:\s*passes';  -- => false
--   SELECT 'REVIEW: passes'     ~* '(^|\n)\s*REVIEW:\s*passes';  -- => true
-- plan_review carries the identical flaw for `PLAN: approved` — same bug,
-- same fix, sibling stage.
--
-- Fix (data-only, idempotent): widen the LEADING character class of both
-- code-pr verdict regexes to allow markdown emphasis / list / heading /
-- quote / backtick markers and whitespace before the verdict word. Still
-- anchored to a line start (^|\n) and still requires the exact verdict
-- token, so mid-sentence prose like "the earlier REVIEW: passes note" does
-- NOT match. Verified across the matrix {bold, heading, quote, list,
-- backtick, leading-ws} => match; {mid-sentence prose, REVIEW: revise} =>
-- no match.
--
-- No schema change, no function change — only the two `unless` strings in
-- the existing `code-pr` pipeline row. jsonb_set touches just the regex and
-- preserves every other route_on key (goto/feedback_key/count_key/max/…).
-- Re-running yields the same state.
--
-- requires = create_v36_keeper_constitution.
-- =====================================================================

UPDATE stewards.pipelines p SET stages = (
    SELECT jsonb_agg(
        CASE
            WHEN elem->>'name' = 'review' THEN
                jsonb_set(elem, '{route_on,0,unless}',
                    to_jsonb('(^|\n)[-*_#>`[:space:]]*REVIEW:[[:space:]]*passes'::text))
            WHEN elem->>'name' = 'plan_review' THEN
                jsonb_set(elem, '{route_on,0,unless}',
                    to_jsonb('(^|\n)[-*_#>`[:space:]]*PLAN:[[:space:]]*approved'::text))
            ELSE elem
        END ORDER BY ord)
    FROM jsonb_array_elements(p.stages) WITH ORDINALITY AS t(elem, ord))
WHERE p.family = 'code-pr'
  AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(p.stages) e
       WHERE e->>'name' IN ('review', 'plan_review')
         AND e->'route_on'->0 ? 'unless');

-- =====================================================================
-- End of v37-verdict-regex-markdown.sql
-- =====================================================================
