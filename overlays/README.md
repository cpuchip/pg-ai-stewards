# Overlays — your content and per-machine config on top of core

This directory ships **empty** in the OSS repo on purpose. Core (`extension/*.sql`,
chain `00→86`) is the substrate: generic, domain-free, the same on every install.
An overlay is where *your* content lives — operator seeds, machine-specific config,
personas, downstream data — applied on top of core, never mixed into it.

Design rationale: [`.spec/proposals/upgrade-and-overlays.md`](../.spec/proposals/upgrade-and-overlays.md).
Runbook: [`docs/operations.md`](../docs/operations.md). Mechanism: [`scripts/migrate.sh`](../scripts/migrate.sh).

## What goes in an overlay

Anything you don't want upstream to see or own:

- Per-machine config (`stewards.config` dials tuned for *this* box).
- Your own agents / personas / pipelines / prompts, or overrides of core's.
- Provider-specific seeds (`model_capability`, `model_pricing`, `model_aliases`).
- Domain content — the corpus, project seeds, intent definitions — for whatever
  you're building on the substrate.
- Anything from the "clean-room" list `tests/virgin-smoke.sql` asserts core does
  **not** ship (workspace personas, personal intent slugs, non-generic MCP
  servers) — that's exactly the material that belongs here instead.

## Layout convention

```
overlays/
  <instance>/            # one directory per machine/deployment (hostname is a
    00-config.sql         # reasonable default — `$(hostname)`)
    01-agents.sql
    10-corpus-seed.sql
    ...
```

Each file is a plain `.sql` script, numbered like the core chain (`NN-name.sql`).
The instance directory can live in this OSS repo (if the content is fine to be
public), or — more commonly — in a **separate private repo** you keep off to the
side and point `OVERLAY_DIR` at. Either way the shape is identical; only whether
it's version-controlled here or elsewhere changes.

## Ordering

`migrate.sh` applies the core chain first (always, in `extension_sql_file!`
order — the authoritative order, read straight out of `extension/src/lib.rs`),
then your overlay directory, **sorted `sort -V`** (version sort: `01-`, `02-`,
… `10-`, not lexical `1-`, `10-`, `2-`). So:

- Prefix every overlay file with a two-digit (or wider, if you have >99) number.
- An overlay file can safely assume every core object exists — it always runs
  *after* core.
- An overlay file CANNOT assume another overlay file ran first except by its own
  number — order within your own directory is exactly the numeric sort, nothing
  smarter. If file `05` depends on something file `03` creates, name it `05`
  and `03` accordingly (not `03b`/`04a` — those don't sort the way you'd hope).
- Overlays never reorder or reinterpret core. If you need a core object changed,
  that's a core PR, not an overlay `CREATE OR REPLACE` — an overlay silently
  redefining a core function is exactly the kind of drift the chain's
  "later-file-wins" discipline exists to make visible, not invisible.

## Idempotency rules (non-negotiable)

`migrate.sh` re-runs on every upgrade and tracks each file by **sha256** in
`stewards.schema_migrations` — a file only re-applies when its hash changes, but
when it *does* re-apply (or applies for the first time on a new box), it must be
safe to run against a database that may already have some of its objects. Three
patterns cover everything:

1. **Functions → `CREATE OR REPLACE FUNCTION`.** Always. A function is not
   destructive to re-author.
2. **Tables / columns / indexes → `IF NOT EXISTS`.** `CREATE TABLE IF NOT EXISTS`,
   `ADD COLUMN IF NOT EXISTS`. Never `DROP` then recreate — that's how a live
   migrate eats your data.
3. **Seed rows → `INSERT ... ON CONFLICT` — but pick the RIGHT conflict action:**
   - **`DO NOTHING`** for anything the *operator* might hand-edit afterward
     (most `stewards.config` dials). The seed is a default; once you've changed
     it, upgrades must never silently revert your change back.
   - **`DO UPDATE`** for anything that should stay **config-as-code** — refreshed
     from the repo on every migrate so machines converge instead of drifting
     (agents, prompts, pipeline definitions, tool grants). See "Config is code"
     in `docs/operations.md`. If you want a value to be yours forever, use
     `DO NOTHING`; if you want the file to be the source of truth forever, use
     `DO UPDATE` and edit the file (never a live `UPDATE`) when you want it to
     change.

Getting this backwards is the usual overlay bug: a `DO NOTHING` seed you keep
hand-editing live (your edits vanish on the next matching-hash no-op, or worse,
survive by accident and drift from what's committed), or a `DO UPDATE` seed you
meant to be a one-time default (which stomps a deliberate live customization on
the next migrate).

## Verifying an overlay

- `STEWARDS_DSN=... OVERLAY_DIR=overlays/$(hostname) ./scripts/migrate.sh status`
  — dry run, shows what would apply, no writes.
- `parity/overlay-replay.sh` proves a set of overlays applies cleanly on a
  **virgin** core (fresh chain, then your overlay directory) — run this in CI
  for your own overlay repo the way core's CI runs `tests/virgin-smoke.sql`.
- Core's own clean-room guard (`tests/virgin-smoke.sql` §4) asserts your content
  is *absent* from core — the inverse of what your overlay's own test should
  assert (that your content *is* present after your overlay applies).

## The one worked example

[`example-greeting.sql`](example-greeting.sql) in this directory is a template,
not a live overlay — copy it into your own `overlays/<instance>/` (renamed with
a number, e.g. `overlays/myhost/05-example-greeting.sql`) to start from something
that already runs. It seeds one config row (`DO NOTHING` — operator-owned after
install) and defines one harmless function, fully commented to show both
idempotency patterns side by side.
