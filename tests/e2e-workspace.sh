#!/usr/bin/env bash
# tests/e2e-workspace.sh — the v30 db-projected-workspace LIVE-LOOP proof.
#
# virgin-smoke's OK 110 proves the SQL surface by SIMULATING the bridge's
# two loops. This script proves the REAL loops against a scratch stack:
# an isolated network, a throwaway pg (the freshly built extension image)
# and a throwaway bridge, with a scratch knowledge dir bind-mounted in.
#
#   1. seed a fixture project doc + `workspace_create` it
#   2. the bridge's PROJECTOR lands _workspaces/<ws>/<slug>.md on the host
#      (NOTIFY-driven — within seconds, hourly tick as fallback)
#   3. a REAL file edit on the host (append a line)
#   4. within one 30s watcher poll the ROW updates: new body, an archived
#      doc_versions revision, changed_by = workspace:<ws>:file-edit, a
#      frontmatter workspace_writeback stamp
#   5. the reverse direction: a row-side UPDATE re-projects into the file
#   6. P2: the host-built stewards-cli emits a runnable `loom run
#      --workdir <dir>` line for a second workspace (loom is NOT
#      dispatched here — the live seat is the session lead's integration
#      proof)
#
# NEVER touches live stewards-oss-* containers: every name is
# stewards-ws-e2e-*, the network is isolated, and teardown is trapped.
#
# Usage:
#   tests/e2e-workspace.sh [pg-image] [bridge-image]
# Defaults: stewards-ws-pg:v30test  stewards-ws-bridge:v30test
# (build them first:
#   docker build -t stewards-ws-pg:v30test extension/
#   docker build -t stewards-ws-bridge:v30test -f extension/bridge.Dockerfile .)
#
# Exit 0 = the whole loop holds. Any failure exits non-zero with the step.
set -euo pipefail

PG_IMAGE="${1:-stewards-ws-pg:v30test}"
BRIDGE_IMAGE="${2:-stewards-ws-bridge:v30test}"

NET=stewards-ws-e2e-net
PG=stewards-ws-e2e-pg
BRIDGE=stewards-ws-e2e-bridge
PG_HOST_PORT=55499

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

fail() { echo "E2E FAIL: $*" >&2; exit 1; }
say()  { echo "e2e-workspace: $*"; }

# psql into the scratch pg (never the live stack).
sql() {
  docker exec -e PGPASSWORD=test "$PG" psql -U stewards -d stewards -v ON_ERROR_STOP=1 -qtAX -c "$1"
}

cleanup() {
  say "teardown (scratch containers + network + tmp dir)"
  docker rm -f "$BRIDGE" >/dev/null 2>&1 || true
  docker rm -f "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  [ -n "${KNOW_DIR:-}" ] && rm -rf "$KNOW_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------
# 0 — scratch knowledge dir + isolated network
# ---------------------------------------------------------------------
KNOW_DIR="$(mktemp -d -t stewards-ws-e2e-XXXXXX)"
# Docker Desktop on Windows wants a Windows-style host path; MSYS bash
# must not re-mangle the container side (db.sh's lesson).
HOST_KNOW="$(cygpath -m "$KNOW_DIR" 2>/dev/null || echo "$KNOW_DIR")"
say "scratch knowledge dir: $KNOW_DIR"

docker network create "$NET" >/dev/null

# ---------------------------------------------------------------------
# 1 — throwaway pg from the freshly built extension image
# ---------------------------------------------------------------------
say "starting scratch pg ($PG_IMAGE)"
MSYS_NO_PATHCONV=1 docker run -d --name "$PG" --network "$NET" \
  -p "127.0.0.1:${PG_HOST_PORT}:5432" \
  -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=test -e POSTGRES_DB=stewards \
  "$PG_IMAGE" -c shared_preload_libraries=pg_ai_stewards >/dev/null

# The image ships the extension FILES but not an initdb script — the
# compose stack mounts extension/init/ for that. A scratch container
# installs explicitly, exactly like tests/virgin-smoke.sql's first line.
say "waiting for pg to accept connections"
for i in $(seq 1 60); do
  if docker exec "$PG" pg_isready -U stewards -d stewards >/dev/null 2>&1; then
    break
  fi
  [ "$i" = 60 ] && fail "pg never became ready"
  sleep 2
done
say "installing the extension (CREATE EXTENSION ... CASCADE)"
for i in $(seq 1 10); do
  if sql "CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE" >/dev/null 2>&1; then
    break
  fi
  [ "$i" = 10 ] && fail "CREATE EXTENSION pg_ai_stewards failed"
  sleep 3
done
[ "$(sql "SELECT to_regclass('stewards.knowledge_workspaces') IS NOT NULL")" = "t" ] \
  || fail "v30 chain missing after CREATE EXTENSION"
say "pg is up; v30 chain installed"

# ---------------------------------------------------------------------
# 2 — throwaway bridge with the scratch knowledge dir mounted
# ---------------------------------------------------------------------
say "starting scratch bridge ($BRIDGE_IMAGE)"
MSYS_NO_PATHCONV=1 docker run -d --name "$BRIDGE" --network "$NET" \
  -e STEWARDS_DSN="postgres://stewards:test@${PG}:5432/stewards?sslmode=disable" \
  -v "${HOST_KNOW}:/knowledge" \
  "$BRIDGE_IMAGE" >/dev/null

# ---------------------------------------------------------------------
# 3 — fixture doc + workspace_create -> the projector lands the file
# ---------------------------------------------------------------------
sql "INSERT INTO stewards.docs (slug, title, body, kind, project_association)
     VALUES ('e2e-ws-doc', 'E2E Workspace Doc', E'# E2E Workspace Doc\n\nSeed body.\n', 'doc', 'e2e-proj')" >/dev/null
CREATE_RES="$(sql "SELECT stewards.workspace_create('e2e-ws', 'project', 'e2e-proj', 'e2e-script')")"
echo "$CREATE_RES" | grep -q '"ok": *true' || fail "workspace_create refused: $CREATE_RES"
say "workspace registered: $CREATE_RES"

WS_FILE="$KNOW_DIR/_workspaces/e2e-ws/e2e-ws-doc.md"
say "waiting for the projector to land $WS_FILE (NOTIFY-driven; up to 90s)"
for i in $(seq 1 45); do
  [ -f "$WS_FILE" ] && break
  [ "$i" = 45 ] && { docker logs "$BRIDGE" | tail -20 >&2; fail "projected workspace file never appeared"; }
  sleep 2
done
grep -q 'workspace: "e2e-ws"' "$WS_FILE" || fail "projected file lacks workspace identity frontmatter"
grep -q "Seed body." "$WS_FILE" || fail "projected file lacks the row body"
say "projection landed with identity frontmatter"

# ---------------------------------------------------------------------
# 4 — a REAL host-side file edit -> the row updates within one poll
# ---------------------------------------------------------------------
say "editing the file on the host (append a line)"
printf 'A line added on the host.\n' >> "$WS_FILE"

say "waiting for the write-back (30s watcher poll + margin; up to 75s)"
for i in $(seq 1 25); do
  if [ "$(sql "SELECT body LIKE '%A line added on the host.%' FROM stewards.docs WHERE slug = 'e2e-ws-doc'")" = "t" ]; then
    break
  fi
  [ "$i" = 25 ] && { docker logs "$BRIDGE" | tail -30 >&2; fail "file edit never landed in the row"; }
  sleep 3
done
say "row updated from the file edit"

# revision + provenance
[ "$(sql "SELECT count(*) >= 1 FROM stewards.doc_versions dv JOIN stewards.docs d ON d.id = dv.doc_id WHERE d.slug = 'e2e-ws-doc'")" = "t" ] \
  || fail "no doc_versions revision archived by the write-back"
CHANGED_BY="$(sql "SELECT dv.changed_by FROM stewards.doc_versions dv JOIN stewards.docs d ON d.id = dv.doc_id WHERE d.slug = 'e2e-ws-doc' ORDER BY dv.id DESC LIMIT 1")"
[ "$CHANGED_BY" = "workspace:e2e-ws:file-edit" ] || fail "revision changed_by = '$CHANGED_BY' (wanted workspace:e2e-ws:file-edit)"
[ "$(sql "SELECT frontmatter->'workspace_writeback'->>'workspace' FROM stewards.docs WHERE slug = 'e2e-ws-doc'")" = "e2e-ws" ] \
  || fail "frontmatter workspace_writeback stamp missing"
say "revision archived with provenance (changed_by=$CHANGED_BY)"

# ---------------------------------------------------------------------
# 5 — the reverse direction: row-side change re-projects into the file
# ---------------------------------------------------------------------
sql "UPDATE stewards.docs SET body = body || E'\nRow-side addendum.\n' WHERE slug = 'e2e-ws-doc'" >/dev/null
sql "SELECT stewards.knowledge_project_now()" >/dev/null
say "waiting for the row-side change to re-project into the file (up to 60s)"
for i in $(seq 1 30); do
  if grep -q "Row-side addendum." "$WS_FILE" 2>/dev/null; then break; fi
  [ "$i" = 30 ] && { docker logs "$BRIDGE" | tail -30 >&2; fail "row-side change never re-projected into the file"; }
  sleep 2
done
say "row-side change landed in the file — the loop is closed both ways"

# ---------------------------------------------------------------------
# 6 — P2: the CLI emits a runnable loom line (loom NOT dispatched here)
# ---------------------------------------------------------------------
say "building stewards-cli on the host for the P2 print-proof"
CLI_BIN="$KNOW_DIR/stewards-cli-e2e"
(cd "$REPO_ROOT" && go build -o "$CLI_BIN" ./cmd/stewards-cli) || fail "host go build of stewards-cli failed"

CLI_OUT="$(STEWARDS_DSN="postgres://stewards:test@localhost:${PG_HOST_PORT}/stewards?sslmode=disable" \
           KNOWLEDGE_DIR="$KNOW_DIR" \
           "$CLI_BIN" workspace create e2e-ws2 --scope project:e2e-proj --for-loom --wait 45)" \
  || fail "stewards-cli workspace create failed"
echo "$CLI_OUT"
echo "$CLI_OUT" | grep -q "loom run --workdir" || fail "CLI did not emit the loom run line"
echo "$CLI_OUT" | grep -q "_workspaces" || fail "CLI did not print the workspace host dir"
[ -d "$KNOW_DIR/_workspaces/e2e-ws2" ] || fail "e2e-ws2 dir never projected (bridge running, --wait 45)"

LIST_OUT="$(STEWARDS_DSN="postgres://stewards:test@localhost:${PG_HOST_PORT}/stewards?sslmode=disable" \
            "$CLI_BIN" workspace list)" || fail "stewards-cli workspace list failed"
echo "$LIST_OUT"
echo "$LIST_OUT" | grep -q "e2e-ws2" || fail "workspace list does not show e2e-ws2"

say "ALL E2E ASSERTIONS PASSED — file->row within one poll (revision + provenance), row->file on NOTIFY, CLI emits the loom seat line"
