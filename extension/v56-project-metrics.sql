-- =====================================================================
-- v56 — project metrics: a queryable home for the nightly metabolic feed
-- =====================================================================
-- Dark-factory item 2 phase-2e. The fleet board rendered per-project git
-- activity (w/m/q commit counts) from live git on every render — never
-- stored. The metabolic feed needs a home for that reading so the board and
-- the substrate agree without re-deriving each time.
--
-- Foreman ruling 2026-08-11 (#885): a jsonb `metrics` column on
-- stewards.projects — NOT fact_edges. Reasoning, kept: a nightly rolling
-- metric is an instrument READING, not knowledge; routing ~150 facts/night
-- through the bi-temporal assertion store would expire+insert forever and
-- pollute the recall surface the store exists to serve. And git itself IS
-- the metric's history (re-derivable for any date), so storing history
-- duplicates it. Hence a single current-reading column, overwritten each
-- sweep — the metric's provenance is git, its history is git.
--
-- Rider (1): every reading carries its own `as_of` and `source` INSIDE the
-- blob — a reading without its timestamp is the aging-caveat trap. The
-- metabolic feed writes e.g.
--   {"w":110,"m":260,"q":1727,"as_of":"2026-08-11T20:00:00Z","source":"git"}
-- Nothing reads metrics until the feed writes it (additive, nullable).
--
-- stewards.projects is extension-managed (measured), so this is a proper
-- chain migration with virgin-smoke coverage; the schema diff routes to the
-- outside review seat (codex).
-- =====================================================================

ALTER TABLE stewards.projects
    ADD COLUMN IF NOT EXISTS metrics jsonb;

-- Envelope guard (codex schema review 2026-08-11): the as_of + source
-- invariants must be enforced at the SCHEMA, not merely by the writer and a
-- positive round-trip test. LIGHT — NULL, or a JSON object carrying a
-- nonempty string `as_of` and a nonempty string `source`. w/m/q stay
-- UNCONSTRAINED so the reading shape can evolve. Idempotent add (DO guard,
-- since ADD CONSTRAINT has no IF NOT EXISTS and this hand-applies to live once).
DO $v56c$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'projects_metrics_envelope'
                      AND conrelid = 'stewards.projects'::regclass) THEN
        -- coalesce forces a non-NULL comparison: a MISSING key makes
        -- jsonb_typeof(...) NULL, and a CHECK passes on NULL (the classic
        -- NULL-in-CHECK trap — caught red by the OK 124 missing-as_of case).
        -- Every leg must resolve to an explicit true/false.
        ALTER TABLE stewards.projects ADD CONSTRAINT projects_metrics_envelope CHECK (
            metrics IS NULL OR (
                jsonb_typeof(metrics) = 'object'
                AND coalesce(jsonb_typeof(metrics -> 'as_of'),  '') = 'string'
                AND length(coalesce(metrics ->> 'as_of',  '')) > 0
                AND coalesce(jsonb_typeof(metrics -> 'source'), '') = 'string'
                AND length(coalesce(metrics ->> 'source', '')) > 0
            )
        );
    END IF;
END
$v56c$;

COMMENT ON COLUMN stewards.projects.metrics IS
'v56: current metabolic reading for the project (nightly git w/m/q sweep). A single CURRENT reading, overwritten each sweep — NOT history (git is the history, re-derivable for any date; routing a rolling metric through fact_edges would pollute the recall store). Every reading carries as_of + a VERSIONED source (e.g. git-activity-v1 — re-derivation depends on the counting/window algorithm) inside the blob; the projects_metrics_envelope CHECK enforces both are nonempty strings (w/m/q left unconstrained/evolvable). Nullable/additive — nothing reads it until the feed writes it.';
