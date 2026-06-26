# Proposal: safe upgrades + the overlay model (stop fearing the rebuild)

**Status:** draft / design (Michael, 2026-06-25). Pairs with `docs/operations.md` (the runbook)
and `scripts/migrate.sh` (the implementation).

## The pain
Running pg-ai-stewards on several machines (work box, home, the OSS dev instance), each = the
public CORE plus private OVERLAYS, has made three things scary or fuzzy:
1. **"Do I have to back up + restore the DB when I change Rust and rebuild?"** (Belief on the work
   box: yes. Reality: almost never — see below.)
2. **No clean "apply the new code's SQL to an existing DB" step.** The `CREATE EXTENSION` init only
   runs on a *fresh* volume (`docker-entrypoint-initdb.d` fires only when `pgdata` is empty). After
   that, SQL changes are applied by hand (surgical `UPDATE`s — fragile, and the source of drift
   *between* machines) or by nuking the volume and reloading (heavy).
3. **Overlay drift across instances.** No single mechanism keeps "core + this machine's overlays"
   reproducible, so machines diverge.

## The mental model — three independent layers
| Layer | Lives in | Rebuilt on upgrade? | Per-machine? |
|-------|----------|---------------------|--------------|
| **CORE** — Rust `.so` + the 00→NN chain | the **pg image** | yes (that's the upgrade) | no — identical via git |
| **DATA** — every `stewards.*` table's rows | the **`pgdata` volume** | **never** | yes |
| **OVERLAYS** — private SQL on top (content seeds, model catalog, personas, machine config) | `overlays/<instance>/NN-*.sql` | re-applied idempotently | yes |

An upgrade should only touch the CORE. DATA and OVERLAYS ride through untouched. Today there's no
step that enforces that cleanly — that's the whole gap.

## Do you need backup/restore on a rebuild? (the direct answer)
Code and data are in different places, so usually **no**:
- **Pure Rust change** (e.g. a bgworker loop fix), no SQL-visible signature change → rebuild the
  image, `up -d` keeping the volume, restart loads the new `.so`. **No backup/restore.**
- **SQL chain change** (new/changed function or table) → re-apply the chain. It is idempotent
  (`CREATE OR REPLACE` / `IF NOT EXISTS` / `ON CONFLICT` — 900+ such statements, **zero destructive
  migrations**). Data tables use `IF NOT EXISTS` (rows preserved); config seeds use `ON CONFLICT DO
  UPDATE` (refreshed *from the repo* — which is correct: config is code, it should track git).
  **No backup/restore.**
- **Truly destructive** (rename a populated column, change a type) → dump that table, migrate, reload.
  Rare, and the consolidated chain deliberately avoids these. This is the *only* dump/restore case.

Why the work box believes otherwise: with no migrate-in-place step, "nuke + fresh-chain + restore"
is the cautious default. It works, but it isn't required.

## The proposal — `migrate` on start
A single idempotent step, run on every container start (a wrapper before postgres serves, or a
one-shot `migrate` sidecar), that brings whatever DB exists up to the image's code:

1. **No extension yet** (fresh volume) → `CREATE EXTENSION pg_ai_stewards` (the baked chain). Record
   every chain file's sha256 in `stewards.schema_migrations`. (Today's first-boot path, now ledgered.)
2. **Extension present, ledger empty** (an existing CREATE-EXTENSION install adopting migrate for the
   first time) → **ADOPT**: record current file hashes WITHOUT re-applying, since the installed
   version already matches the image. (Avoids a needless full re-apply that would refresh seeds.)
3. **Extension present, ledger populated** → walk `extension/migration-order.txt` in order; for each
   file, if its sha256 differs from the ledger (or it's new), `psql -f` it (idempotent) and upsert the
   ledger. Unchanged files are skipped. This applies *exactly the diff* since last upgrade.
4. **Overlays** → after the core, apply `overlays/<instance>/*.sql` in order by the same
   hash-vs-ledger rule. (Generalizes today's `parity/overlay-replay.sh`, which already proves overlays
   apply cleanly on a virgin core.)

Result — the upgrade flow becomes, on every machine:
```
git pull  →  docker compose build  →  docker compose up -d  →  (migrate runs)  →  verify
```
No backup/restore, no hand-patching, no drift. The same command sequence on every box.

### Why this is safe (the idempotency contract)
- Functions: `CREATE OR REPLACE` — body replaced, never dropped.
- Tables: `CREATE TABLE IF NOT EXISTS` — rows preserved.
- Seeds (agents/personas/models/pipelines): `INSERT … ON CONFLICT DO UPDATE` — **config refreshed
  from the repo**. Operator config changes therefore belong in the SQL files / overlays (committed),
  **not** in live `UPDATE`s — otherwise a re-apply reverts them. (This is a feature: it forces
  config-as-code and kills cross-machine drift. The live prompt/grant edits made during debugging are
  the anti-pattern; they must be folded into the chain/overlay to survive a migrate — which is exactly
  what committing them does.)
- Hard rule for chain authors: **no destructive migration in the chain.** A genuine destructive
  change is a dump → transform → reload, done deliberately and documented, never a silent `ALTER … DROP`.

## Verification (wire in what already exists)
Every upgrade ends with a verification gate, not a vibe:
- `tests/virgin-smoke.sql` — the chain installs clean on a virgin DB (clean-install proof).
- `scripts/.../run-verify-suite.ps1` + `parity/*` — live-vs-repo parity + overlays-on-virgin-core.
- `tests/e2e-turn-loop.sh` — one real dispatch round-trips.
CI already runs virgin-smoke + go build/vet on every PR; the runbook adds the local post-upgrade pass.

## Multi-instance + overlays
- One **CORE** image, pinned by git commit, identical everywhere.
- Each machine keeps `overlays/<instance>/` (git-ignored or a private repo) + its own `pgdata`.
- "Sync from another machine" = `git pull` the core; local overlays + data stay put; `migrate`
  reconciles. No machine ever hand-edits the other's live DB.

## Rollout (low-risk, staged)
1. Land `scripts/migrate.sh` + `docs/operations.md` — usable **manually** immediately (the safe
   command sequence), no change to the running stack.
2. Prove it: run `migrate` against the dev instance, confirm ADOPT + a no-op second run + a real
   one-file change applying.
3. Only then (optional) wire `migrate` into the pg service start (entrypoint wrapper or one-shot
   sidecar) so it's automatic.

## Relationship to the chat-loop runaway
This is the deploy-side twin of the same discipline the chat loop needs: **bound the work and make
the safe path the easy path.** A cost-runaway recursive agent and a scary multi-step rebuild are both
"no enforced ceiling / no clean default" problems. Landing migrate makes the eventual bgworker
force-final fix (and any Rust change) a non-event to deploy — `git pull && build && up`.
