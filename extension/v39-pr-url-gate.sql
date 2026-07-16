-- =====================================================================
-- v39-pr-url-gate.sql — the code-pr `pr` stage must not COMPLETE without a
-- PR (the ground-truth half of defect 4).
-- =====================================================================
-- Live evidence (coder-proof debugging, 2026): the pr stage marked its work
-- `completed` with no PR. Two shapes seen on the real path:
--   - minimax-m2.5 ended its turn at dangling tool_calls -> stage completed,
--     no branch, no PR.
--   - glm-5.2 ended awaiting a push gate -> stage completed, branch pushed
--     later, PR never opened.
-- The pr stage (v06) has next=null and NO route_on, so on turn-end it always
-- falls through to a normal advance and the item reports `verified` / done —
-- a lie: "a reviewable DRAFT PR" that does not exist.
--
-- The implement stage is honest because a green build+test is ground truth.
-- The pr stage's ground truth is a PR URL. This adds the missing gate using
-- the same data-driven route_on machinery v09 already uses for review/plan:
--   UNLESS the stage output contains a github PR URL, loop back to `pr`
--   (bounded, cap 2), then PARK awaiting_review honestly. When a PR URL IS
--   present the rule does not fire -> normal advance -> honest completion.
--
-- This is the honest-PARKING half ONLY. It deliberately does NOT build
-- gate-continuation (resuming the suspended agent turn after an approved push
-- gate) — that is an architecture choice for the human. The parking rule
-- alone makes the "completed with no PR" lie impossible: the stage can no
-- longer reach verified/done without a PR URL in its output.
--
-- The bounded loop-back is a self-heal, not merely a park: a fresh pr re-run
-- re-does commit/push/open_pr. If a PR was already opened but its URL was not
-- echoed, `gh pr create` refuses the duplicate and prints the EXISTING PR URL
-- in its error — which then matches the `unless` and completes honestly, so
-- no duplicate PR is created (verified live: the pattern matches the URL
-- inside gh's "already exists" message).
--
-- URL PRESENCE, not URL RESOLVE: route_on matches a regex against the stage
-- output; the schema has no HTTP fetch. This asserts a well-formed PR URL is
-- present, not that it 200s — the honest limit of route_on, and it already
-- kills both observed lies (which had no URL at all). Verified live
-- (read-only): the pattern matches github.com/<owner>/<repo>/pull/<n> and
-- does NOT match a bare /pulls list page, PR-less prose, or empty output.
--
-- Data-only, idempotent: jsonb_set writes the route_on array onto the `pr`
-- stage (create_missing=true); every other stage and field is preserved. The
-- WHERE guard skips the write once the rule is present, so a re-run is a true
-- no-op and never clobbers a later-added rule.
--
-- requires = create_v38_crawl_continue_regex_markdown.
-- =====================================================================

UPDATE stewards.pipelines p SET stages = (
    SELECT jsonb_agg(
        CASE
            WHEN elem->>'name' = 'pr' THEN
                jsonb_set(elem, '{route_on}', jsonb_build_array(
                    jsonb_build_object(
                        'unless',        'github\.com/[^[:space:]]+/pull/[0-9]+',
                        'goto',          'pr',
                        'count_key',     '_pr_url_retry',
                        'max',           2,
                        'on_max_status', 'awaiting_review',
                        'on_max_reason', 'pr stage ended without opening a PR (no github.com/.../pull/<n> URL in its output) after the retry cap — the branch may be pushed but no pull request exists; a human opens/verifies the PR (the Hinge).')
                ), true)
            ELSE elem
        END ORDER BY ord)
    FROM jsonb_array_elements(p.stages) WITH ORDINALITY AS t(elem, ord))
WHERE p.family = 'code-pr'
  AND EXISTS (
      SELECT 1 FROM jsonb_array_elements(p.stages) e WHERE e->>'name' = 'pr')
  AND NOT EXISTS (
      SELECT 1 FROM jsonb_array_elements(p.stages) e
       WHERE e->>'name' = 'pr'
         AND e->'route_on' @> '[{"count_key":"_pr_url_retry"}]'::jsonb);

-- =====================================================================
-- End of v39-pr-url-gate.sql
-- =====================================================================
