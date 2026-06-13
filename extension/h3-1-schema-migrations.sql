-- =====================================================================
-- Batch H.3.1 — schema migrations for planning pipeline family
--
-- (The docs-generalization half of this migration — tags/source_type/
--  project_association columns + nullable file_path — was absorbed into
--  the create_docs table definition at the 2026-06-12 consolidation.
--  What remains is the work_items half.)
--
--   work_items columns for H.3 planning + D-H7 origin
--   (RATIFIED in parent batch-h-pipeline-expansion proposal):
--   - origin text DEFAULT 'human'
--       values: human|scheduled|watchman|steward|council|agent_planning
--       (the H.3 planning pipeline inserts proposed work_items
--        with origin='agent_planning' so the UI can badge them)
--   - project_association text
--       freeform; identifies which project the work belongs to.
--       Future UI surface: a "known projects" view aggregates
--       distinct values.
--   - parent_work_item_id uuid REFERENCES work_items(id)
--       for proposed work_items: points back at the planning
--       run that proposed them. ON DELETE SET NULL so deleting
--       the planning run doesn't cascade.
-- =====================================================================

-- ---------------------------------------------------------------------
-- work_items: origin + project_association + parent_work_item_id
-- ---------------------------------------------------------------------

ALTER TABLE stewards.work_items
    ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'human',
    ADD COLUMN IF NOT EXISTS project_association text,
    ADD COLUMN IF NOT EXISTS parent_work_item_id uuid;

-- Add the self-FK separately so the ADD COLUMN IF NOT EXISTS above is
-- idempotent on re-run. The FK can be created only once; we guard with
-- a constraint-name check.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'work_items_parent_work_item_fk'
    ) THEN
        ALTER TABLE stewards.work_items
            ADD CONSTRAINT work_items_parent_work_item_fk
            FOREIGN KEY (parent_work_item_id)
            REFERENCES stewards.work_items(id)
            ON DELETE SET NULL;
    END IF;
END $$;

-- origin CHECK constraint: known values only. agent_planning is the
-- new value contributed by this batch.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'work_items_origin_check'
    ) THEN
        ALTER TABLE stewards.work_items
            ADD CONSTRAINT work_items_origin_check
            CHECK (origin = ANY (ARRAY[
                'human', 'scheduled', 'watchman', 'steward',
                'council', 'agent_planning'
            ]));
    END IF;
END $$;

-- Indexes for the new columns. parent_work_item_id needs an index for
-- the future "show me everything this planning run produced" query.
CREATE INDEX IF NOT EXISTS work_items_origin_idx
    ON stewards.work_items(origin);
CREATE INDEX IF NOT EXISTS work_items_project_association_idx
    ON stewards.work_items(project_association)
    WHERE project_association IS NOT NULL;
CREATE INDEX IF NOT EXISTS work_items_parent_work_item_idx
    ON stewards.work_items(parent_work_item_id)
    WHERE parent_work_item_id IS NOT NULL;

-- Sanity check.
SELECT 'work_items new columns:' AS check_name,
       count(*) FILTER (WHERE origin = 'human') AS as_human,
       count(*) FILTER (WHERE origin != 'human') AS as_other,
       count(*) AS total
  FROM stewards.work_items;
