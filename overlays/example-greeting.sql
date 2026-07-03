-- =====================================================================
-- example-greeting.sql — a TEMPLATE overlay, not a live one.
-- =====================================================================
-- This file is NOT applied by anything as-is: it sits directly under
-- overlays/ (no instance directory, no numeric prefix), and migrate.sh
-- only looks inside `$OVERLAY_DIR` (e.g. overlays/<instance>/NN-*.sql).
--
-- To actually use it: copy it into your own instance overlay with a
-- numeric prefix, e.g.
--
--   mkdir -p overlays/$(hostname)
--   cp overlays/example-greeting.sql overlays/$(hostname)/05-example-greeting.sql
--   OVERLAY_DIR=overlays/$(hostname) STEWARDS_DSN=... ./scripts/migrate.sh
--
-- It demonstrates the two idempotency patterns from overlays/README.md
-- side by side: a seed row you own after install (DO NOTHING), and a
-- function that's always safe to re-author (CREATE OR REPLACE).
-- =====================================================================

-- ── Pattern 1: a config seed the OPERATOR owns after install ─────────
-- ON CONFLICT DO NOTHING — this is a DEFAULT. Once installed, if you
-- (or an agent, via stewards.config_set) change 'example.greeting.name',
-- re-running this same file on a later migrate must NOT stomp your
-- change back to 'friend'. That's what DO NOTHING buys you here.
INSERT INTO stewards.config (key, value, description)
VALUES (
    'example.greeting.name',
    '"friend"'::jsonb,
    'Who stewards.example_greeting() addresses by default (overlay-owned; edit freely — upgrades will not revert it).'
)
ON CONFLICT (key) DO NOTHING;

-- ── Pattern 2: a function — always CREATE OR REPLACE ──────────────────
-- Functions are never destructive to re-author, so this is the one
-- pattern that's always just "the plain right way to write it" rather
-- than a choice between two conflict actions.
--
-- A harmless, obviously-example function: reads the config seeded above
-- and returns a greeting. Nothing here touches core tables, core
-- functions, or anything an agent dispatch depends on — it's a template
-- to delete once you've written your own first overlay function.
CREATE OR REPLACE FUNCTION stewards.example_greeting()
RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT 'Hello, ' || stewards.config_get_text('example.greeting.name', 'friend') || '! '
        || 'This came from an overlay, not core — delete overlays/<instance>/NN-example-greeting.sql '
        || 'once you have written your own.';
$$;

COMMENT ON FUNCTION stewards.example_greeting() IS
'Template overlay function (see overlays/example-greeting.sql) — safe to drop.';

-- ── Verifying your own copy applied ───────────────────────────────────
-- After migrate.sh runs this (from your instance directory, with a real
-- number prefix), you should be able to run:
--
--   SELECT stewards.example_greeting();
--   -- "Hello, friend! This came from an overlay, not core — delete ..."
--
-- and, if you changed the config first:
--
--   SELECT stewards.config_set('example.greeting.name', '"Michael"'::jsonb);
--   SELECT stewards.example_greeting();
--   -- "Hello, Michael! ..."
--
-- Re-running migrate.sh after that must NOT revert the name back to
-- "friend" — that's the DO NOTHING contract this file exists to model.
