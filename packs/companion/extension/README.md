# stewards_companion — the companion pack as a real extension

Proof subject for D2A (#319): `forge.sql`+`companion.sql`+`steward-tools.sql`
packaged as a pure-SQL Postgres extension (no pgrx). The core stays pgrx;
packs stay SQL. Plan: `.spec/proposals/d2a-pack-extension-battle-plan.md`.

## What's here

- `stewards_companion.control` — `requires = 'pg_ai_stewards'`,
  `default_version = '0.3.0'`, `relocatable = false` (the pack creates its
  own `forge` + `companion` schemas). Its comment block is the ratified
  **DROP-survivors posture** (read it — it is the contract this pack keeps).
- `stewards_companion--0.1.0.sql` — forge + companion (reminders, bell,
  verbal approval).
- `stewards_companion--0.1.0--0.2.0.sql` — the upgrade delta: + steward-tools
  (forge_start, work_item_unstick, model_health, models_health_check).
- `stewards_companion--0.2.0.sql` — the 0.2.0 fresh install.
- `stewards_companion--0.2.0--0.3.0.sql` — the upgrade delta: work_item_unstick
  now RESETS the loop counters (route_on count_keys + failure_count +
  _route_hops) so a cap-parked item can actually make progress (defect 3). Same
  tool set, one CREATE OR REPLACE (steward-unstick-reset.sql).
- `stewards_companion--0.3.0.sql` — a fresh install lands here directly.

Each `--X.sql` is **verbatim pack SQL + a delimited PACKAGING footer**
(`-- ===== PACKAGING (extension-only) =====` … `-- ===== END PACKAGING =====`)
that adds only the two things a loose-SQL apply cannot: `pg_extension_config_dump`
(so user data survives pg_dump/restore) and `companion.companion_uninstall()`
(the documented uninstall step). `verify-verbatim.sh` strips the footer before
its byte-for-byte compare — the pack SQL itself is never edited.

## Install (as an extension)

```sql
CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE;   -- the core, first
CREATE EXTENSION stewards_companion;                     -- fresh -> 0.3.0
-- or pin an earlier release and upgrade forward:
--   CREATE EXTENSION stewards_companion VERSION '0.1.0';
--   ALTER EXTENSION stewards_companion UPDATE TO '0.2.0';
--   ALTER EXTENSION stewards_companion UPDATE TO '0.3.0';
```

The server must have the pack files in its extension sharedir
(`/usr/share/postgresql/18/extension/` in the shipped image).

## Ship in the image

The Dockerfile ships the pack files into that sharedir. Because the pack lives
at `packs/companion/extension/` — **outside** `extension/`, this Dockerfile's
build context — the ship recipe stages them into the context first:

```sh
cp packs/companion/extension/stewards_companion.control \
   packs/companion/extension/stewards_companion--*.sql  extension/
docker build -t stewards-oss-pg:with-companion extension/
rm extension/stewards_companion.control extension/stewards_companion--*.sql
```

A plain `docker build extension/` with no staging is a **complete no-op** for
the pack (guarded bracket-glob COPY + a guard file) — core builds are
unaffected. See the `# ---- D2A` block in `extension/Dockerfile`.

## Uninstall — three lines

1. `SELECT companion.companion_uninstall();` — shrinks the Arc-C write
   allowlist back and deactivates this pack's `tool_defs` rows (never deletes).
2. `DROP EXTENSION stewards_companion;` — succeeds if no tools were forged;
   **refuses while forged tools exist** (a feature — it protects operator work).
3. `DROP EXTENSION stewards_companion CASCADE;` — the explicit, eyes-open
   choice to destroy the forged functions too. Kept regardless: the forge
   pipeline row, the companion intent row, and the deactivated `tool_defs`.

## Oracle

`./test-extension.sh [core-image]` boots one scratch container and drives all
stages to green: virgin 0.1.0 install → 0.1.0 smoke (+ steward-tools absent) →
`ALTER … UPDATE 0.2.0` smoke → `ALTER … UPDATE 0.3.0` + unstick-reset smoke (a
cap-parked item's loop counters clear) → fresh 0.3.0 → dump/restore survival →
uninstall posture (DROP refuses → uninstall → CASCADE → exact survivors) →
catalog parity (loose-SQL vs extension) → Dockerfile ship-path. Scratch resets
make it grindable; the LIVE stack is never touched.

`./verify-verbatim.sh` is the blind byte-check: every `--X.sql` is its pack
sources concatenated, plus only the guard line, the source-header lines, and
the delimited PACKAGING footer.
