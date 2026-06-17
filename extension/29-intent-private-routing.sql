-- =====================================================================
-- 29-intent-private-routing.sql — a private intent routes its materialized
-- file drops under private/<intent>/ instead of the shared public dirs.
-- =====================================================================
-- The reflect-steward / research / planning pipelines materialize via SHARED
-- per-pipeline templates (planning -> plans/<slug>, research-write ->
-- research/<slug>) into the RW /workspace mount. The folder is the same for
-- every intent — only the slug differs — so a client-sensitive intent's drops
-- land in the public workspace tree alongside everyone else's.
--
-- This makes "private" a first-class property of an INTENT: mark it, and every
-- file it materializes is prefixed `private/<intent_slug>/...`. The operator's
-- /workspace already gitignores /private/, so private intents never leak.
--
-- ONE trigger catches every stamping site (on_maturity_verified's render-UPDATE,
-- 13-research's enqueue UPDATE, 14-fanout's child INSERTs) because they all set
-- work_items.file_destination, and enqueue_work_item_file re-reads that column.
--
-- Generic core (the mechanism). The per-intent flag is operator data: an operator
-- marks which of THEIR intents are private in an overlay. requires
-- create_guard_autoresume (28).
-- =====================================================================

ALTER TABLE stewards.intents ADD COLUMN IF NOT EXISTS file_private boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN stewards.intents.file_private IS
'When true, every file this intent materializes is routed under private/<intent_slug>/ instead of the shared public pipeline dirs (plans/, research/, ...). For client-sensitive intents whose drops must not enter the public workspace tree (which gitignores /private/). Set per-operator in an overlay.';

CREATE OR REPLACE FUNCTION stewards.work_item_private_file_route()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_slug text; v_priv boolean;
BEGIN
    -- nothing to route, or already routed (idempotent), or no intent to check.
    IF NEW.file_destination IS NULL OR NEW.file_destination = '' THEN RETURN NEW; END IF;
    IF NEW.file_destination LIKE 'private/%' THEN RETURN NEW; END IF;
    IF NEW.intent_id IS NULL THEN RETURN NEW; END IF;

    SELECT slug, file_private INTO v_slug, v_priv
      FROM stewards.intents WHERE id = NEW.intent_id;
    IF COALESCE(v_priv, false) THEN
        NEW.file_destination := 'private/' || v_slug || '/' || NEW.file_destination;
    END IF;
    RETURN NEW;
END $$;
COMMENT ON FUNCTION stewards.work_item_private_file_route() IS
'BEFORE INSERT/UPDATE OF file_destination on work_items: if the work_item''s intent is file_private, prefix the destination with private/<intent_slug>/ (idempotent; skips already-private paths). Single choke point — enqueue_work_item_file re-reads file_destination, so the prefix flows to the materialized file.';

DROP TRIGGER IF EXISTS work_items_private_file_route ON stewards.work_items;
CREATE TRIGGER work_items_private_file_route
    BEFORE INSERT OR UPDATE OF file_destination ON stewards.work_items
    FOR EACH ROW EXECUTE FUNCTION stewards.work_item_private_file_route();

-- =====================================================================
-- End of 29-intent-private-routing.sql
-- =====================================================================
