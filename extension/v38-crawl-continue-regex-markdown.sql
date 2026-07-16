-- =====================================================================
-- v38-crawl-continue-regex-markdown.sql — the crawl pipeline's step-loop
-- "CRAWL: continue" signal must tolerate markdown emphasis on the verdict
-- line. Same vulnerability class as v37 / PR #47, sibling pipeline.
-- =====================================================================
-- The crawl pipeline (v21) loops its single `step` stage via route_on:
--   route_on[0].when = (^|\n)\s*CRAWL:\s*continue   -> goto step (loop back)
-- `\s*` cannot consume a leading markdown marker, so a model that ends its
-- turn with "**CRAWL: continue**" (bold), "> CRAWL: continue" (quote), or a
-- list / heading / backtick marker does NOT match the continue rule. The only
-- sibling rule is the empty-output self-heal (route_on[1], ^\s*$), which a
-- non-empty bold line also fails — so NO rule matches, the step falls through
-- to a normal advance, and because `step.next` is NULL the crawl STOPS
-- prematurely even though the model asked to continue. No crawl failure has
-- been OBSERVED yet; this is the preventive sibling of the v37 fix.
--
-- Verified live (read-only) before this migration:
--   SELECT '**CRAWL: continue**' ~* '(^|\n)\s*CRAWL:\s*continue';  -- => false
--   SELECT 'CRAWL: continue'     ~* '(^|\n)\s*CRAWL:\s*continue';  -- => true
-- and the widened pattern across {bold, quote, list, heading, backtick,
-- leading-ws, multiline} => match; {mid-sentence prose, CRAWL: done} => no
-- match.
--
-- Fix (data-only, idempotent): widen the LEADING character class of the crawl
-- step's route_on[0].when exactly the way v37 widened the code-pr verdict
-- regexes — allow markdown emphasis / list / heading / quote / backtick
-- markers and whitespace before the CRAWL token, still anchored to a line
-- start (^|\n) and still requiring the exact `CRAWL: continue` token, so
-- mid-sentence prose like "the earlier CRAWL: continue note" does NOT match.
-- The sibling empty-output rule (route_on[1], ^\s*$) is deliberately left
-- untouched. jsonb_set touches only the one regex string; every other
-- route_on key (goto/feedback_key/count_key/max/on_max_*) is preserved.
-- Re-running yields the same state.
--
-- requires = create_v37_verdict_regex_markdown.
-- =====================================================================

UPDATE stewards.pipelines p SET stages = (
    SELECT jsonb_agg(
        CASE
            WHEN elem->>'name' = 'step' THEN
                jsonb_set(elem, '{route_on,0,when}',
                    to_jsonb('(^|\n)[-*_#>`[:space:]]*CRAWL:[[:space:]]*continue'::text))
            ELSE elem
        END ORDER BY ord)
    FROM jsonb_array_elements(p.stages) WITH ORDINALITY AS t(elem, ord))
WHERE p.family = 'crawl'
  AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(p.stages) e
       WHERE e->>'name' = 'step'
         AND e->'route_on'->0 ? 'when');

-- =====================================================================
-- End of v38-crawl-continue-regex-markdown.sql
-- =====================================================================
