-- =====================================================================
-- 25-corpus.sql — intent→project mapping so every loop compounds a pool
-- =====================================================================
-- The reflect-steward (work-corpus) compounds: its verified findings publish to the
-- searchable docs pool, deduped + surveyed + read back scoped to a project.
-- The digest loops (book-study, video-study, general-research) reach
-- maturity=verified but their work_items are NOT project-tagged — work_item_create
-- only defaults project_association = intent slug when a project with THAT slug
-- exists, and the digest intents (book-study, video-study, general-research) don't
-- name a project (the projects are `books`, `ai`). So they never pooled (08's
-- pool-publish is now decoupled from file-materialize but gates on
-- project_association).
--
-- This file adds the generic machinery that lets an operator map an intent to a
-- project: a mapping table + an ADDITIVE BEFORE-INSERT trigger that fills
-- project_association when NULL. Additive = no core function re-author (clobber-
-- check-safe). The map is EMPTY in core (a virgin install is a no-op); the
-- operator overlay seeds the rows (book-study→books, video-study→ai, …) and the
-- project_neighborhood cross-pollination.
--
-- Generic core: machinery + an empty map. requires create_skills (24) — installs
-- at the tail (no function re-authors; just a new table + trigger).
-- =====================================================================

-- ── the map: intent slug → the project its verified work should be tagged to ──
CREATE TABLE IF NOT EXISTS stewards.intent_project_map (
    intent_slug          text PRIMARY KEY,
    project_association   text NOT NULL,     -- a stewards.projects(slug); checked at fill time
    created_at           timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE stewards.intent_project_map IS
'Operator map: a work_item under intent <intent_slug> with no project gets tagged to <project_association> (if that project exists). Lets the digest loops (book-study→books, video-study→ai, general-research→ai) feed a compounding pool the same way the reflect-steward does. Empty in core; seeded by the operator overlay.';

-- ── the additive trigger: fill project_association from the map when NULL ─────
-- BEFORE INSERT, only when project_association is NULL and the mapped project
-- actually exists (work_items.project_association FKs stewards.projects(slug) with
-- ON DELETE RESTRICT — setting a non-existent slug would abort the insert, so we
-- guard exactly as compose's tagging does). No-op when the map is empty.
CREATE OR REPLACE FUNCTION stewards.fill_project_association()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_intent_slug text;
    v_project     text;
BEGIN
    IF NEW.project_association IS NOT NULL OR NEW.intent_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT slug INTO v_intent_slug FROM stewards.intents WHERE id = NEW.intent_id;
    IF v_intent_slug IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT m.project_association INTO v_project
      FROM stewards.intent_project_map m WHERE m.intent_slug = v_intent_slug;
    IF v_project IS NOT NULL
       AND EXISTS (SELECT 1 FROM stewards.projects WHERE slug = v_project) THEN
        NEW.project_association := v_project;
    END IF;
    RETURN NEW;
END;
$fn$;
COMMENT ON FUNCTION stewards.fill_project_association() IS
'BEFORE-INSERT on work_items: when project_association is NULL, fill it from intent_project_map (if the mapped project exists). Additive — does not re-author work_item_create; only fills a gap, so existing project tags and the work_item_create default both win over it.';

DROP TRIGGER IF EXISTS work_items_fill_project ON stewards.work_items;
CREATE TRIGGER work_items_fill_project
    BEFORE INSERT ON stewards.work_items
    FOR EACH ROW
    EXECUTE FUNCTION stewards.fill_project_association();

-- =====================================================================
-- End of 25-corpus.sql
-- =====================================================================
