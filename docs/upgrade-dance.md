# The upgrade dance, scripted

`scripts/upgrade-dance.sh` is SHIPWRIGHT P1
(`.spec/proposals/shipwright-self-bootstrap.md`): the by-hand deploy dance
proven on 2026-07-09 (workspace journal:
`.spec/journal/2026-07-09-full-foreman-night-and-wave2-deploy.md`, section
"The deploy"), encoded as a deterministic script with per-step oracles.

**Zero new capability.** The actor is the same (a human, or a loom seat a
human is driving), the sanction is the same (Michael's word, typed, before
any live write), the mechanics are the same (build → scratch-verify →
force-recreate → migrate → probe). What changes is that the dance no longer
lives only in one operator's hands and a journal entry — it's a script
anyone can run, review, and shellcheck.

See `docs/operations.md` for the by-hand runbook this script automates the
riskiest half of. `docs/operations.md` covers Rust-only / pure-config
changes too (no `migrate.sh` needed); this script is specifically for the
`pg` service (extension image + SQL chain), the one piece that carries real
migration risk.

## The five phases

```
scripts/upgrade-dance.sh preflight [--sha SHA] [--remote R] [--branch B]
scripts/upgrade-dance.sh build
scripts/upgrade-dance.sh scratch-proof
scripts/upgrade-dance.sh gate
scripts/upgrade-dance.sh apply --sanctioned --confirm "PHRASE"
scripts/upgrade-dance.sh rollback --sanctioned --confirm "PHRASE" [--backup-tag TAG]
```

Run them **in order**, from the repo root (or anywhere — the script locates
itself). Each phase writes a small state file under `scratch/shipwright/`
(already gitignored) that the next phase reads, so you don't have to carry
shas around by hand.

| Phase | Reads/writes | What it proves |
|---|---|---|
| `preflight` | Reads only. `git fetch` + resolve target sha; `docker inspect` on the live container (image id, uptime, status); a `SELECT`-only version marker. | You know exactly what you're about to build, and exactly what live currently is, before anything else runs. |
| `build` | Writes a new, DISTINCT image tag (`stewards-oss-pg:shipwright-<sha>`) — never `stewards-oss-pg:pg18` (the live tag). | The target sha's `extension/` tree, exported in isolation via `git archive` (never your possibly-dirty working tree), builds cleanly. Runs the `gen-copy-manifest.sh --check` drift gate first. |
| `scratch-proof` | Boots a throwaway, unpublished-port container; always torn down (success or failure, via `trap`). | The **grindable half**: `tests/virgin-smoke.sql` (CI's own recipe) passes, AND `migrate.sh` — run THROUGH the vendored shim — genuinely applies (not just adopts) at least one real chain file, proving the actual mechanism `apply` will use in production. |
| `gate` | Read-only `migrate.sh status` probe against live. **Always exits nonzero.** No flag changes that — it is structurally a preview. | You get the full sanction summary (target sha, what would apply, the exact rollback recipe) before anything is at stake. |
| `apply` | **The only phase that writes to the live container.** Requires `--sanctioned` AND a `--confirm` phrase copied byte-for-byte from `gate`'s output. | Stages a backup tag from the CURRENT live image FIRST (before anything else), promotes the built image, `--force-recreate`s, migrates, probes, writes a receipt. |
| `rollback` | Also requires `--sanctioned` + `--confirm`. | Retags the most recent (or a named) backup back onto the live tag and force-recreates. |

## The sanction covenant

`apply` never runs without the human's word — literally: it refuses to do
anything (`exit 1`, no docker command issued) unless both `--sanctioned` is
present AND `--confirm` matches an exact phrase computed from the live
container name and target sha (e.g.
`UPGRADE stewards-oss-pg TO f79d5adda311`). That phrase is only printed by
`gate` — there is no way to construct it without having run the preview
first, and no way to reuse an old confirmation against a new target sha (the
sha is baked into the phrase). `apply` also re-verifies the live image id
fresh, immediately before touching anything, and refuses if it drifted
since `preflight` (someone else touched the container — stop and re-plan).

This mirrors the SHIPWRIGHT proposal's grindability argument directly:
build + scratch-verify is grindable and oracled, so it's automated hard,
retried freely, and safe to run unattended at 3am against a live production
stack — the first four phases touch that stack with nothing but reads. The
live recreate is a one-shot state change; no amount of tooling makes it
grindable, so it stays exactly where the covenant puts it — on Michael's
typed word, every time, no pre-delegated class of "safe" upgrades (see the
proposal's council item #3 — deliberately left "no" for now).

## Running it from a loom seat in this workspace

This script is meant to be run **directly on the host**, by whatever is
sitting in the terminal — Michael by hand, or a loom-hosted Claude Code /
opus seat driving the same terminal (`STEWARDS_LOOM_URL` /
`docker-compose.override.yaml`'s harness wiring; see `.mind/ports.md` and
the compose override's comments). No special invocation is needed beyond
what's documented above.

**Why `--isolate` (a coder sandbox / hardened worktree container) is the
wrong place to run this:** the whole point of the dance is that it drives
the HOST's Docker daemon — `docker build`, `docker inspect`, `docker
compose up --force-recreate` against the actual live container. A coder
sandbox is deliberately walled off from the host daemon (see
`docker-compose.override.yaml`'s own comment: "the docker socket is
host-root-equivalent... anything that can reach it can control the host").
That wall is exactly the one the SHIPWRIGHT proposal names as the reason
the substrate can't upgrade itself from inside: "a system cannot hold the
ladder it is standing on." Running `upgrade-dance.sh` inside an isolated
sandbox would either fail outright (no docker socket) or, if someone
deliberately punched a hole for it, defeat the entire safety argument this
script exists to formalize — the host body, driving the host daemon, is
the point, not an implementation detail to route around.

## The vendored psql shim (`scripts/pgshim/psql`)

`migrate.sh` calls the real `psql "$DSN" ...` by name. A Windows/Git-Bash
dev box (or a loom seat's role home on one) frequently has Docker but no
native `psql` client — the exact gap the 2026-07-09 deploy hit. Put
`scripts/pgshim` first on `PATH` and `migrate.sh` runs unmodified, proxied
transparently into the container via `docker exec`. `upgrade-dance.sh`
does this automatically for every phase that needs it (falling back to a
real host `psql` when one is present).

The shim's header comment carries the full MSYS-path-mangling story and a
named, deliberate deviation from this project's SHIPWRIGHT P1 brief — read
it before touching the file. Short version: Git Bash silently rewrites a
POSIX-looking path into a Windows path before handing it to a native binary
like `docker.exe`, which is correct for a HOST-side argument and wrong for
a CONTAINER-side one. The brief described the fix as `MSYS_NO_PATHCONV=1`
on both `docker cp` and `docker exec` (with `cygpath -m` for the host
side); testing that head-to-head against `scripts/db.sh`'s already-proven
double-slash trick (2026-07-10, against a throwaway alpine container) found
**both work**, but `db.sh`'s actual committed technique needs neither
`MSYS_NO_PATHCONV` nor `cygpath` — `docker cp`'s container-side destination
argument isn't mangled on this machine; only a later bare `-f /tmp/x`
argument is. The shim follows `db.sh`'s simpler, already-proven code.

## Evidence this was actually run, not just written

See the SHIPWRIGHT P1 PR body for the full transcript: `preflight` →
`build` → `scratch-proof` ran for real against a genuine target sha,
`scratch-proof` proved both the ledger-empty adopt bootstrap AND a forced
real file re-apply through the shim's `docker cp` path, `gate` printed the
summary and exited nonzero, and `docker inspect` on the live container
before and after shows byte-identical image id and start timestamp
throughout every read-only phase.
