# Operations — upgrading, verifying, and running many instances

The one-page runbook. Design rationale: `.spec/proposals/upgrade-and-overlays.md`. Mechanism:
`scripts/migrate.sh`.

## The one rule
**Code is in the image. Data is in the `pgdata` volume. Config is code.** An upgrade rebuilds the
image; it never touches the volume. So you almost never back up / restore — see the matrix below.

## Do I need to back up the DB before upgrading?

| What changed | Steps | Backup/restore? |
|--------------|-------|-----------------|
| **Rust only** (e.g. a bgworker fix) | `build` → `up -d` (keep the volume) | **No** — the new `.so` loads on restart |
| **SQL chain** (function/table/seed) | `build` → `up -d` → `migrate.sh` | **No** — the chain is idempotent; data preserved, config refreshed from repo |
| **Destructive** (rename a populated column, retype) | dump that table → migrate → reload | **Yes** — rare; never do this as a silent `ALTER … DROP` |

If you're unsure, `migrate.sh status` tells you exactly which files would change before you apply
anything.

## Scenario 1 — you changed code on THIS machine
```bash
docker compose -p pg-ai-stewards-oss build pg                            # (or: build bridge / ui — whatever changed)
docker compose -p pg-ai-stewards-oss up -d --no-deps --force-recreate pg # recreate, KEEP the pgdata volume
STEWARDS_DSN=postgres://stewards:stewards@localhost:55434/stewards ./scripts/migrate.sh   # apply the SQL diff
# verify:
docker exec -i stewards-oss-pg psql -U stewards -d stewards -f /dev/stdin < tests/virgin-smoke.sql  # on a SCRATCH db (see note)
./tests/e2e-turn-loop.sh                                  # one real dispatch round-trips
```
**`--force-recreate` is not optional** — a plain `up -d` after `build` does NOT restart the
container just because the image the pg service's tag points at changed. Compose only recreates
when the resolved *service config* changes, not when the tag's underlying image bytes do; a rebuild
that reuses the same `image:` tag string looks config-identical to Compose. This bit the 2026-07-09
full-foreman deploy for real — caught only by reading the container's uptime — and is the exact
landmine `scripts/upgrade-dance.sh` (`docs/upgrade-dance.md`) encodes a hard `--force-recreate` for.
For a **pure Rust** change you can skip `migrate.sh` (no SQL changed). When in doubt, run it — on a
no-op change it just prints `=` for every file.

## Scenario 2 — you pulled updates FROM another machine
```bash
git pull
docker compose -p pg-ai-stewards-oss build               # rebuild whatever the diff touched
docker compose -p pg-ai-stewards-oss up -d
OVERLAY_DIR=overlays/$(hostname) STEWARDS_DSN=…:55434/stewards ./scripts/migrate.sh   # core diff + THIS box's overlays
```
Your DATA and your OVERLAYS are untouched; only the core chain diff applies. Run `migrate.sh status`
first if you want to see the diff before applying.

## Scenario 3 — first time adopting `migrate.sh` on an existing install
The ledger is empty, so the first `apply` auto-detects this and **adopts** (records current hashes
without re-applying — your running install already matches the image). After that, only genuine
changes apply. To force a one-time full re-apply instead (e.g. to pull live hand-edits back to the
repo definitions), delete the ledger rows first: `DELETE FROM stewards.schema_migrations;` then run
`apply`.

## Config is code — the drift killer
Seeds (agents, personas, models, pipelines, prompts, tool grants) are `ON CONFLICT DO UPDATE`, so a
migrate **refreshes them from the repo**. Therefore:
- **Change config in the SQL files / overlays and commit it** — never with a live `UPDATE` you intend
  to keep. A live edit survives until the next migrate, then reverts to the repo value.
- This is the feature that keeps your machines from drifting: every box converges on the committed
  definitions.
- (During debugging, live edits are fine — just fold the keeper ones into the chain/overlay before
  the next migrate, which is what committing them does.)

## Overlays (private content + per-machine config)
- Put machine/instance-private SQL in `overlays/<instance>/NN-*.sql` (a private repo or git-ignored).
- `migrate.sh` applies them after the core chain, same hash-tracked idempotent rule.
- `parity/overlay-replay.sh` proves a set of overlays applies cleanly on a virgin core — run it in CI
  for your private overlay repo.

## Verification gate (run after every upgrade)
- `tests/virgin-smoke.sql` — the chain installs clean on a **virgin** DB (use a scratch container, not
  your live volume). This is the clean-install oracle CI runs on every PR.
- `scripts/parity-check.sh` — live-vs-repo drift oracle (boots a scratch container from the SAME
  image as live, diffs `stewards.*` function/view/column/trigger bodies). (This line used to point at
  `parity/*` + `run-verify-suite.ps1` — neither exists in this repo; fixed 2026-07-10 while building
  `scripts/upgrade-dance.sh`, whose `scratch-proof` phase is the closest thing to what that ghost
  reference described: virgin-boot + smoke + a real `migrate.sh` round-trip on a throwaway container.)
- `tests/e2e-turn-loop.sh` — a real dispatch round-trips end to end.

## What a backup actually is, when you do want one
The data, not the schema: `pg_dump -U stewards --data-only --schema=stewards stewards > data.sql`
(or `pg_dumpall` for the whole cluster). Restore into a freshly-chained DB. You only need this for a
genuinely destructive migration or to move data between volumes — not for routine code upgrades.
