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

## Roll order when the bgworker calls new SQL
A release can change both halves at once: Rust that calls a SQL function, and the chain file that
defines it. Between the container restart and `migrate.sh`, one half is new and the other old, so
pick the order by what the SQL contains:

- **plpgsql or sql functions, tables, triggers only:** apply the SQL first (`migrate.sh` from the new
  checkout against the running old container), then recreate the container on the new image. The
  old binary never calls the new functions, so nothing changes until the new binary starts.
- **New C functions (a new `#[pg_extern]`):** recreate on the new image first, then apply the SQL. A
  `CREATE FUNCTION` that binds a C symbol fails against the old `.so`.

In both orders the binary has to tolerate the other half missing: a worker that finds its SQL absent
logs that once and skips, and a SQL error a worker catches must never end a dispatcher.
`tests/bgworker-survives.sh <image>` checks both for the batch cycle.

v66 (batch dispatch) is the first release this applies to. Its SQL is plpgsql only, so on a running
instance apply it first. Its batch cycle also checks that `stewards.batch_open` exists before it
runs, so the reverse order is safe as well. On 2026-10-10 the reverse order, on a build that had
neither that check nor the transaction fix, ended dispatcher #0 twice in the seconds between the
image starting and the migration landing.

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
- `tests/bgworker-survives.sh <image>`: a SQL error the leader catches does not end a dispatcher,
  and missing batch SQL is skipped (a scratch container with the bgworker loaded; no provider calls).

## What a backup actually is, when you do want one
You only need one for a genuinely destructive migration or to move data between volumes; a routine
code upgrade re-applies the chain and keeps the volume. Take a physical copy of the running server:

```
docker exec <pg-container> pg_basebackup -U stewards -D - -Ft -X fetch | gzip > stewards-base.tar.gz
```

That is the data directory as one tar, with the WAL it needs (`-X fetch`), `backup_label` and
`backup_manifest`.

**Why not pg_dump.** pg_dump leaves out the data of every table an extension owns unless the extension
registers it with `pg_extension_config_dump`, and pg_ai_stewards registers none. A data-only dump of a
working instance (129 extension-owned tables in `stewards`, 2,767 rows in `work_items`) came out as 8 KB
holding a single `COPY`. `pg_dumpall` runs pg_dump per database and has the same gap. (The companion
pack registers its own tables, so its rows do survive a dump.)

Restore into a new volume with the same image, or one with the same Postgres major:

```
docker volume create stewards-restore
docker run --rm -v stewards-restore:/var/lib/postgresql -v "$PWD":/b:ro <image> bash -c '
  mkdir -p "$PGDATA" && cd "$PGDATA" && tar -xzf /b/stewards-base.tar.gz &&
  chown -R postgres:postgres /var/lib/postgresql && chmod 700 "$PGDATA"'
docker run -d --name stewards-restore -v stewards-restore:/var/lib/postgresql <image>
```

In the PG 18 images the volume mounts at `/var/lib/postgresql` and `PGDATA` is
`/var/lib/postgresql/18/docker`. On first start the server replays the bundled WAL and logs "consistent
recovery state reached". To put the copy into use, point the compose service's volume at it, or copy
it over the original volume while the service is stopped. Checked on 2026-10-10: a 247 MB backup of a
working instance restored this way and came up with its data (2,697 work items, 15,863 world entities).

Registering the core tables with `pg_extension_config_dump` would make pg_dump carry them too, but the
chain seeds configuration rows into some of those tables, and a dump restored into a freshly chained
database would insert those rows a second time. That needs the list of seeded rows and a per-table
filter first; until then, back up physically.
