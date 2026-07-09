#!/usr/bin/env bash
# packs/companion/extension/test-extension.sh — the D2A oracle
# (.spec/proposals/d2a-pack-extension-battle-plan.md, "The oracle").
#
# Boots a scratch postgres from the SAME image the repo already builds
# for the core extension, drops the stewards_companion extension files
# into its sharedir, and drives the six oracle stages. Only stage 1 is
# implemented (confidently, against the scratch-container pattern in
# scripts/parity-check.sh and tests/README.md's virgin-boot recipe).
# Stages 2-6 need judgment calls the battle plan reserves for the window
# (mechanics #3-#5) — each is a clearly-marked stub naming the assertion
# it will run, per constitution #4 (courier, not editor).
#
# Exit 0 = every IMPLEMENTED stage passed (stubs do not count either way).
# Exit 1 = an implemented stage failed.
#
# Usage: packs/companion/extension/test-extension.sh [image]
#   image defaults to stewards-oss-pg:pg18 — the image name
#   scripts/parity-check.sh and tests/README.md's `docker build -t
#   stewards-oss-pg:test extension/` recipe both produce.
set -uo pipefail

IMAGE=${1:-stewards-oss-pg:pg18}
SCRATCH=stewards-companion-scratch
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hardcoded, not probed via `pg_config --sharedir`: extension/Dockerfile's
# own stage-2 comment documents the pgrx package output lands at exactly
# this path, and the runtime image (pgvector/pgvector:pg18) is not
# guaranteed to ship pg_config at all (that binary usually lives only in
# -dev/build images). See knowledge/docs/.../d2a-task-319 war-game notes,
# which hit this exact gotcha first.
#
# Double leading slash defeats Git-Bash/MSYS path mangling of in-container
# paths passed to `docker cp`/`docker exec` (same trick as scripts/db.sh's
# documented gotcha #2: `-f /tmp/x` -> `C:/Users/.../tmp/x`); Linux
# collapses `//usr/...` to `/usr/...` so the container side is unaffected.
EXTDIR="//usr/share/postgresql/18/extension"

fail=0
die() { echo "FAIL: $*"; fail=1; }

cleanup() { docker rm -f "$SCRATCH" >/dev/null 2>&1; }
trap cleanup EXIT
docker rm -f "$SCRATCH" >/dev/null 2>&1

# =====================================================================
# stage 1 (IMPLEMENTED): virgin pg + core extension ->
#   CREATE EXTENSION stewards_companion VERSION '0.1.0'
# =====================================================================
echo "== stage 1: virgin install at 0.1.0 =="

docker run -d --name "$SCRATCH" \
  -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=scratch -e POSTGRES_DB=stewards \
  "$IMAGE" postgres -c shared_preload_libraries=pg_ai_stewards >/dev/null \
  || { die "docker run $IMAGE"; echo "test-extension.sh: FAILED"; exit 1; }

ready=0
for _ in $(seq 1 30); do
  docker exec "$SCRATCH" pg_isready -U stewards -d stewards >/dev/null 2>&1 && { ready=1; break; }
  sleep 2
done
if [ "$ready" -ne 1 ]; then
  die "scratch postgres never became ready (30x2s)"
  echo "test-extension.sh: FAILED"
  exit 1
fi

if ! docker cp "$SCRIPT_DIR/stewards_companion.control" "$SCRATCH:$EXTDIR/stewards_companion.control"; then
  die "docker cp stewards_companion.control"
fi
if ! docker cp "$SCRIPT_DIR/stewards_companion--0.1.0.sql" "$SCRATCH:$EXTDIR/stewards_companion--0.1.0.sql"; then
  die "docker cp stewards_companion--0.1.0.sql"
fi
if ! docker cp "$SCRIPT_DIR/stewards_companion--0.1.0--0.2.0.sql" "$SCRATCH:$EXTDIR/stewards_companion--0.1.0--0.2.0.sql"; then
  die "docker cp stewards_companion--0.1.0--0.2.0.sql"
fi
if ! docker cp "$SCRIPT_DIR/stewards_companion--0.2.0.sql" "$SCRATCH:$EXTDIR/stewards_companion--0.2.0.sql"; then
  die "docker cp stewards_companion--0.2.0.sql"
fi

if [ "$fail" -eq 0 ]; then
  docker exec "$SCRATCH" psql -U stewards -d stewards -v ON_ERROR_STOP=1 \
    -c "CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE;" \
    -c "CREATE EXTENSION stewards_companion VERSION '0.1.0';" \
    || die "CREATE EXTENSION stewards_companion VERSION '0.1.0' errored"
fi

if [ "$fail" -eq 0 ]; then
  v=$(docker exec "$SCRATCH" psql -U stewards -d stewards -tAc \
    "SELECT extversion FROM pg_extension WHERE extname='stewards_companion';" | tr -d '\r\n ')
  if [ "$v" != "0.1.0" ]; then
    die "extversion is '$v', expected 0.1.0"
  else
    echo "OK: stage 1 — stewards_companion 0.1.0 installed on virgin pg"
  fi
fi

# =====================================================================
# stage 2 (STUB): smoke.sql subset for 0.1.0
# =====================================================================
echo "== stage 2: 0.1.0 smoke (forge happy+refusals, reminders, bell) =="
echo "TODO(window): run the 0.1.0-relevant subset of packs/companion/smoke.sql"
echo "  (forge_register happy path + its refusal cases: bad tool_name, missing"
echo "  sql, multi-statement smuggle, failing test call; reminder_set/list/cancel"
echo "  incl. the minutes_from_now/at validation errors; companion_bell;"
echo "  companion_approve's awaiting_review-only guard) against \$SCRATCH via"
echo "  ON_ERROR_STOP=1 psql, asserting non-error / expected {\"error\":...} shapes."
echo "  ALSO ASSERT ABSENCE at 0.1.0: forge_start, work_item_unstick, model_health,"
echo "  models_health_check must not be registered tool_defs rows yet (they are"
echo "  steward-tools.sql's, which lands at 0.2.0)."

# =====================================================================
# stage 3 (STUB): ALTER EXTENSION stewards_companion UPDATE TO '0.2.0'
# =====================================================================
echo "== stage 3: upgrade 0.1.0 -> 0.2.0 =="
echo "TODO(window): docker exec psql -v ON_ERROR_STOP=1 -c"
echo "  \"ALTER EXTENSION stewards_companion UPDATE TO '0.2.0';\" against the SAME"
echo "  \$SCRATCH database from stage 1/2 (proves the DELTA applies over live 0.1.0"
echo "  state, not a fresh install). Then ASSERT: extversion = 0.2.0;"
echo "  work_item_unstick refuses a running/pending work item (only failed/"
echo "  awaiting_review allowed); model_health returns the {generated_at,"
echo "  models:[...]} shape; forge_start's 5-wishes/hour rate guard trips on a"
echo "  6th forge work_item created within the window."

# =====================================================================
# stage 4 (STUB): fresh second DB, straight CREATE EXTENSION -> 0.2.0
# =====================================================================
echo "== stage 4: fresh DB straight to 0.2.0 (default_version) =="
echo "TODO(window): CREATE DATABASE stewards2 in \$SCRATCH; CREATE EXTENSION"
echo "  IF NOT EXISTS pg_ai_stewards CASCADE; CREATE EXTENSION stewards_companion;"
echo "  (no VERSION clause — proves default_version='0.2.0' in the control file"
echo "  lands a fresh install at 0.2.0 directly, not via the 0.1.0->0.2.0 delta)."
echo "  ASSERT extversion = 0.2.0 and re-run the stage 3 smoke subset there too."

# =====================================================================
# stage 5 (STUB): pg_dump/restore -> companion.reminders row survives
# =====================================================================
echo "== stage 5: dump/restore config_dump proof =="
echo "TODO(window): reminder_set a row, pg_dump -Fc the stage-1/2/3 database,"
echo "  restore into a THIRD scratch database (pg_restore, extension pre-created"
echo "  via CREATE EXTENSION so pg_restore only replays data), ASSERT the"
echo "  reminders row is present with the same id/message. NOTE: this requires"
echo "  a pg_extension_config_dump('companion.reminders', '') call, which does"
echo "  NOT currently exist anywhere in forge.sql/companion.sql/steward-tools.sql"
echo "  — battle plan mechanic #3's last bullet flags this as unbuilt. Decide"
echo "  (and add) before this stage can pass; also decide whether"
echo "  forge.forged_tools needs the same treatment (it is operator data too,"
echo "  per uninstall.sql's existing posture on the loose-SQL path)."

# =====================================================================
# stage 6 (STUB): DROP EXTENSION -> assert the documented survivors EXACTLY
# =====================================================================
echo "== stage 6: DROP EXTENSION survivor assertion =="
echo "TODO(window): DROP EXTENSION stewards_companion; on the stage 1/2/3"
echo "  database. ASSERT the object/row set left behind matches EXACTLY the"
echo "  posture recorded in stewards_companion.control's DROP-survivors"
echo "  comment block (mechanic #3) — nothing more, nothing less. This stage"
echo "  cannot be written until that posture is decided (see the control"
echo "  file's TODO(window) — tool_defs rows, forge.forged_tools, the"
echo "  companion intent + forge pipeline row, and the"
echo "  arc_c_dynamic_write_allowlist shrink are all open)."

echo ""
if [ "$fail" -ne 0 ]; then
  echo "test-extension.sh: FAILED (see FAIL lines above)."
  exit 1
fi
echo "test-extension.sh: stage 1 OK. Stages 2-6 are stubs awaiting window"
echo "decisions (see TODO(window) lines above) — this is NOT a green oracle yet."
exit 0
