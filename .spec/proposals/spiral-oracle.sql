-- spiral-oracle.sql — the deterministic gauge for the "uplifting-local-models" arc.
-- Build-the-oracle-first: measure the spiral before building the cure, so every
-- intervention (route-to-gemma, BINEVAL, the watcher, the rest) is scored against a
-- real before/after on real ledger data. Read-only; no behavior change.
--
-- A "hard spiral" = the over-gather-never-commit loop: the model hammered a few tools
-- many times and never produced a committed (non-tool) answer. Validated against the
-- real ledger 2026-06-29 (the world-build/tor-build loops at 60-364 calls/tool are the
-- extreme cases; the repetition discriminator filters legit tool-only stages out).
--
-- Thresholds are the two tunable lines below. Applied to dev now; chain-file
-- registration (79-*, lib.rs + Dockerfile COPY + virgin-smoke assert) is the PR that
-- formalizes it once the arc is ratified.

-- Per-session spiral predicate (also the seed for a future watcher trigger).
CREATE OR REPLACE FUNCTION stewards.session_spiraled(
  p_session       text,
  p_min_calls     int DEFAULT 15,   -- tunable: a real loop calls a lot
  p_min_per_tool  numeric DEFAULT 4 -- tunable: hammering few tools, not diverse use
) RETURNS boolean AS $$
  WITH asst AS (
    SELECT tool_calls,
           -- coalesce to false: a committed answer stores tool_calls=NULL, and
           -- jsonb_typeof(NULL)='array' is NULL → NOT is_tool would be NULL (uncounted).
           coalesce(jsonb_typeof(tool_calls)='array' AND jsonb_array_length(tool_calls)>0, false) AS is_tool
    FROM stewards.messages WHERE role='assistant' AND session_id = p_session
  ),
  calls AS (SELECT (jsonb_array_elements(tool_calls)->'function'->>'name') AS tool FROM asst WHERE is_tool)
  SELECT (SELECT count(*) FROM calls) >= p_min_calls
     AND (SELECT count(*) FROM calls)::numeric
         / nullif((SELECT count(DISTINCT tool) FROM calls),0) >= p_min_per_tool
     AND (SELECT count(*) FILTER (WHERE NOT is_tool) FROM asst) = 0;
$$ LANGUAGE sql STABLE;

-- Per-model baseline report: the standing gauge. Re-run after every intervention.
CREATE OR REPLACE FUNCTION stewards.spiral_report(
  p_min_sessions  int DEFAULT 10,
  p_min_calls     int DEFAULT 15,
  p_min_per_tool  numeric DEFAULT 4
) RETURNS TABLE(model text, sessions bigint, hard_spirals bigint, spiral_pct numeric) AS $$
  WITH asst AS (
    SELECT session_id, coalesce(model,'?') AS model, tool_calls,
           coalesce(jsonb_typeof(tool_calls)='array' AND jsonb_array_length(tool_calls)>0, false) AS is_tool
    FROM stewards.messages WHERE role='assistant'
  ),
  calls AS (SELECT session_id, (jsonb_array_elements(tool_calls)->'function'->>'name') AS tool FROM asst WHERE is_tool),
  call_stats AS (SELECT session_id, count(*) AS total_calls, count(DISTINCT tool) AS distinct_tools FROM calls GROUP BY session_id),
  per AS (
    SELECT a.session_id,
           mode() WITHIN GROUP (ORDER BY a.model) AS model,
           count(*) FILTER (WHERE a.is_tool) AS tool_turns,
           count(*) FILTER (WHERE NOT a.is_tool) AS answer_turns
    FROM asst a GROUP BY a.session_id
  ),
  j AS (
    SELECT p.model,
           (c.total_calls >= p_min_calls
            AND c.total_calls::numeric/nullif(c.distinct_tools,0) >= p_min_per_tool
            AND p.answer_turns = 0) AS hard_spiral
    FROM per p LEFT JOIN call_stats c USING(session_id)
    WHERE p.tool_turns >= 1
  )
  SELECT model, count(*), count(*) FILTER (WHERE hard_spiral),
         round(100.0*count(*) FILTER (WHERE hard_spiral)/count(*), 1)
  FROM j GROUP BY model HAVING count(*) >= p_min_sessions
  ORDER BY count(*) FILTER (WHERE hard_spiral) DESC;
$$ LANGUAGE sql STABLE;
