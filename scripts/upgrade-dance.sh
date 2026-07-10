#!/usr/bin/env bash
# =====================================================================
# scripts/upgrade-dance.sh — the proven-by-hand upgrade dance, scripted.
# =====================================================================
# SHIPWRIGHT P1 (.spec/proposals/shipwright-self-bootstrap.md): "prove the
# dance, scripted — encode wave-2's by-hand deploy as scripts/upgrade-
# dance.sh with per-step oracles; I run it as the hands, from VS Code, on
# the next real upgrade. Zero new capability — same actor, same sanction,
# now deterministic." The by-hand dance it encodes is recorded in
# .spec/journal/2026-07-09-full-foreman-night-and-wave2-deploy.md, workspace
# repo (scripture-study), section "The deploy":
#
#   docker build -> --force-recreate (plain `up -d` DECLINED — same image
#   tag, no restart; caught by reading the container uptime) -> migrate.sh
#   applied via a host psql shim (no host psql on this box) -> version +
#   health probes.
#
# THE WALL THIS SCRIPT RESPECTS: the substrate cannot upgrade itself from
# inside (it runs IN the pg container). Every phase here runs from OUTSIDE,
# on the host, against the host Docker daemon — see docs/upgrade-dance.md
# for why `--isolate` / a coder sandbox is the wrong place to run this.
#
# THE ONE RULE THAT MUST NEVER BREAK: this script must be safe to run
# `preflight`, `build`, `scratch-proof`, and `gate` at 3am with nobody
# watching, against a live production stack, and touch NOTHING on that
# stack beyond read-only inspection. Only `apply` and `rollback` write to
# the live container, and both refuse outright without a human's typed
# word. If you are editing this file and a change makes any of the first
# four phases capable of a live write, that change is wrong.
#
# Phases:
#   preflight      fetch + resolve target sha; READ-ONLY capture of the
#                  live container's current image id / uptime / schema
#                  marker (docker inspect + a SELECT-only probe — no
#                  writes, ever, in this phase).
#   build          git-archive the target sha to an isolated export dir
#                  (never the working tree — a dirty/mid-edit checkout
#                  must not silently leak into the image) and docker build
#                  it as a DISTINCT tag (stewards-oss-pg:shipwright-<sha>),
#                  never overwriting the live tag (stewards-oss-pg:pg18).
#   scratch-proof  boot a throwaway, unpublished-port container from that
#                  image, run tests/virgin-smoke.sql (CI's own recipe),
#                  then run migrate.sh THROUGH THE VENDORED SHIM twice —
#                  once to prove the ledger-empty adopt bootstrap, once
#                  after deliberately dropping one ledger row to force a
#                  REAL `-f`-file apply through the shim's docker-cp path
#                  (the adopt path alone never exercises -f — see
#                  pgshim/psql's header and this file's scratch_proof()).
#                  Always tears the scratch container down, success or
#                  fail (trap).
#   gate           print the sanction summary (target sha, a READ-ONLY
#                  migrate.sh `status` diff against the LIVE ledger, and
#                  the exact rollback recipe) and ALWAYS exit nonzero. This
#                  phase does not accept a flag that changes that — it is
#                  structurally a preview, full stop. To proceed, run
#                  `apply` directly.
#   apply          ONLY with --sanctioned AND a --confirm phrase that must
#                  match byte-for-byte (it's echoed by `gate` — copy it,
#                  don't retype it). Stages a backup tag from the CURRENT
#                  live image FIRST, promotes the built image to the live
#                  tag, `docker compose up -d --force-recreate pg`,
#                  migrate.sh, health/version probes, and a receipt with
#                  before/after markers.
#   rollback       ONLY with --sanctioned AND --confirm; retags the most
#                  recent (or --backup-tag-named) backup back onto the live
#                  tag and force-recreates.
#
# Usage:
#   scripts/upgrade-dance.sh preflight [--sha SHA] [--remote R] [--branch B]
#   scripts/upgrade-dance.sh build
#   scripts/upgrade-dance.sh scratch-proof
#   scripts/upgrade-dance.sh gate
#   scripts/upgrade-dance.sh apply --sanctioned --confirm "PHRASE"
#   scripts/upgrade-dance.sh rollback --sanctioned --confirm "PHRASE" [--backup-tag TAG]
#
# Env:
#   LIVE_CONTAINER   the live pg container name (default: stewards-oss-pg)
#   REMOTE/BRANCH    what to fetch + resolve target sha from (default: origin/main)
#   STEWARDS_DSN     used only for its user/dbname when going through the
#                     shim; matters for real when a host psql is present.
#     (default: postgres://stewards:stewards@localhost:55434/stewards)
# =====================================================================
# shellcheck disable=SC2153
# (file-wide: TARGET_SHA/SHORT_SHA/BUILD_TAG/LIVE_*_PRE are assigned by a
# dynamic `source "$file"` in require_state() — preflight.env/build.env,
# written earlier in this same run — not typos of the lowercase locals
# that produced them. shellcheck can't see through the indirection.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$REPO/scratch/shipwright"   # scratch/ is already gitignored — no tracked state.

LIVE_CONTAINER="${LIVE_CONTAINER:-stewards-oss-pg}"
LIVE_TAG="stewards-oss-pg:pg18"        # the tag docker-compose.yaml's pg service references.
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
STEWARDS_DSN="${STEWARDS_DSN:-postgres://stewards:stewards@localhost:55434/stewards}"

SHA_OVERRIDE=""
SANCTIONED=0
CONFIRM=""
BACKUP_TAG_OVERRIDE=""

usage() {
  sed -n '1,70p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
  exit 1
}

log()  { echo "[upgrade-dance] $*"; }
fail() { echo "[upgrade-dance] FATAL: $*" >&2; exit 2; }

psql_bin() {
  # Prefer a real host psql when present (a loom seat on a box that HAS
  # one should just use it); fall back to the vendored shim otherwise —
  # the exact gap the 2026-07-09 deploy hit with no host psql available.
  if command -v psql >/dev/null 2>&1; then
    echo "psql"
  else
    echo "$SCRIPT_DIR/pgshim/psql"
  fi
}

# ── state passing between phases (each phase writes its own file; later
#    phases source everything up to and including their prerequisite) ──
require_state() {
  local file="$STATE_DIR/$1.env"
  [ -f "$file" ] || fail "missing $file — run '$1' first."
  # shellcheck source=/dev/null
  source "$file"
}

# =====================================================================
# preflight — READ-ONLY. fetch, resolve target sha, capture live markers.
# =====================================================================
preflight() {
  mkdir -p "$STATE_DIR"
  log "== preflight =="

  git -C "$REPO" fetch "$REMOTE" "$BRANCH" --quiet
  local target_sha
  if [ -n "$SHA_OVERRIDE" ]; then
    target_sha="$(git -C "$REPO" rev-parse "$SHA_OVERRIDE")"
  else
    target_sha="$(git -C "$REPO" rev-parse "$REMOTE/$BRANCH")"
  fi
  local short_sha="${target_sha:0:12}"
  log "target sha:  $target_sha ($short_sha)"

  local live_image_id="unknown" live_started_at="unknown" live_status="absent"
  if docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1; then
    live_image_id="$(docker inspect "$LIVE_CONTAINER" --format '{{.Image}}')"
    live_started_at="$(docker inspect "$LIVE_CONTAINER" --format '{{.State.StartedAt}}')"
    live_status="$(docker inspect "$LIVE_CONTAINER" --format '{{.State.Status}}')"
  fi
  log "live container: $LIVE_CONTAINER  status=$live_status  image=$live_image_id"
  log "live started at: $live_started_at"

  # Version marker — a SELECT only (see docs/upgrade-dance.md's "reads
  # only" note). Tolerate failure (e.g. live not up yet) without aborting
  # preflight; the marker is diagnostic, not a gate condition.
  local live_marker="unreadable"
  if [ "$live_status" = "running" ]; then
    live_marker="$(DB_CONTAINER="$LIVE_CONTAINER" "$(psql_bin)" "$STEWARDS_DSN" -tAc \
      "SELECT count(*)||' applied, latest='||coalesce(max(name),'none') FROM stewards.schema_migrations" \
      2>/dev/null || echo "unreadable")"
  fi
  log "live schema_migrations marker: $live_marker"

  cat > "$STATE_DIR/preflight.env" <<EOF
TARGET_SHA=$target_sha
SHORT_SHA=$short_sha
LIVE_IMAGE_ID_PRE=$live_image_id
LIVE_STARTED_AT_PRE=$live_started_at
LIVE_STATUS_PRE=$live_status
LIVE_MARKER_PRE="$live_marker"
PREFLIGHT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  log "preflight recorded -> $STATE_DIR/preflight.env (nothing written to $LIVE_CONTAINER)"
}

# =====================================================================
# build — export the target sha in isolation, docker build a DISTINCT tag.
# =====================================================================
build() {
  require_state preflight
  log "== build (target $SHORT_SHA) =="

  local export_dir="$STATE_DIR/src-$SHORT_SHA"
  rm -rf "$export_dir"
  mkdir -p "$export_dir"
  git -C "$REPO" archive "$TARGET_SHA" | tar -x -C "$export_dir"

  log "drift gate: extension/gen-copy-manifest.sh --check (unpiped, on the exported tree)"
  bash "$export_dir/extension/gen-copy-manifest.sh" --check

  local build_tag="stewards-oss-pg:shipwright-$SHORT_SHA"
  log "docker build -> $build_tag  (never touches $LIVE_TAG — that retag happens only in apply)"
  docker build -t "$build_tag" "$export_dir/extension"

  cat > "$STATE_DIR/build.env" <<EOF
BUILD_TAG=$build_tag
BUILD_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  log "built: $build_tag"
}

# =====================================================================
# scratch-proof — the grindable half. Virgin boot + smoke + shim proof.
# =====================================================================
scratch_proof() {
  require_state preflight
  require_state build
  log "== scratch-proof =="

  local scratch="stewards-scratchpw-$SHORT_SHA"
  docker rm -f "$scratch" >/dev/null 2>&1 || true

  cleanup_scratch() { docker rm -f "$scratch" >/dev/null 2>&1 || true; }
  trap cleanup_scratch EXIT

  # No -p host port publish: every read/write against this container goes
  # through `docker exec`, never TCP, so it can't collide with the live
  # stack's port 55434 even if run concurrently.
  docker run -d --name "$scratch" \
    -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=scratchpw -e POSTGRES_DB=stewards \
    "$BUILD_TAG" postgres -c shared_preload_libraries=pg_ai_stewards >/dev/null

  local ok=""
  for _ in $(seq 1 60); do
    docker exec "$scratch" pg_isready -U stewards -d stewards >/dev/null 2>&1 && { ok=1; break; }
    sleep 1
  done
  [ -n "$ok" ] || { docker logs "$scratch" || true; fail "scratch postgres never became ready"; }
  log "scratch ready: $scratch"

  log "-- tests/virgin-smoke.sql (CI's exact recipe; plpgsql ASSERT, nonzero on any regression) --"
  docker exec -i "$scratch" psql -U stewards -d stewards -v ON_ERROR_STOP=1 < "$REPO/tests/virgin-smoke.sql"
  log "virgin-smoke: PASS"

  local scratch_dsn="postgres://stewards:scratchpw@localhost:5432/stewards"

  log "-- migrate.sh via the vendored shim, pass 1: ledger-empty ADOPT bootstrap --"
  DB_CONTAINER="$scratch" PATH="$SCRIPT_DIR/pgshim:$PATH" STEWARDS_DSN="$scratch_dsn" \
    "$REPO/scripts/migrate.sh"

  log "-- migrate.sh status: must be idempotent (zero diffs right after adopt) --"
  local status_out
  status_out="$(DB_CONTAINER="$scratch" PATH="$SCRIPT_DIR/pgshim:$PATH" STEWARDS_DSN="$scratch_dsn" \
    "$REPO/scripts/migrate.sh" status)"
  echo "$status_out"
  echo "$status_out" | grep -q '~ ' && fail "migrate.sh status reports diffs immediately after adopt — chain is not idempotent"
  log "post-adopt idempotency: PASS"

  # The adopt path above NEVER calls `pg -f` (see migrate.sh's apply_one:
  # the `adopt)` case only records a hash, it doesn't apply the file) — so
  # it proves the shim's -c/-tAc/-tAqc path but NOT its -f docker-cp path,
  # which is the actual MSYS footgun this shim exists to dodge. Force one
  # real -f apply by dropping a single ledger row (simulates "this file's
  # entry is stale/missing" — the real-world case `apply` exists for) and
  # re-running in (non-empty-ledger, so no auto-adopt-flip) apply mode.
  log "-- forcing a REAL -f chain-file apply through the shim (drop one ledger row) --"
  local probe_file
  probe_file="$(DB_CONTAINER="$scratch" "$(psql_bin)" "$scratch_dsn" -tAc \
    "SELECT name FROM stewards.schema_migrations WHERE name LIKE 'v%.sql' ORDER BY name LIMIT 1")"
  [ -n "$probe_file" ] || fail "could not pick a chain file to probe-drop from the ledger"
  log "probe file: $probe_file"
  DB_CONTAINER="$scratch" "$(psql_bin)" "$scratch_dsn" -v ON_ERROR_STOP=1 -c \
    "DELETE FROM stewards.schema_migrations WHERE name = '$probe_file';" >/dev/null

  local reapply_out
  reapply_out="$(DB_CONTAINER="$scratch" PATH="$SCRIPT_DIR/pgshim:$PATH" STEWARDS_DSN="$scratch_dsn" \
    "$REPO/scripts/migrate.sh" apply)"
  echo "$reapply_out"
  echo "$reapply_out" | grep -Fq "+ $probe_file (applying)" \
    || fail "expected migrate.sh to genuinely re-apply $probe_file via -f through the shim; it did not"
  log "shim -f (docker cp + double-slash exec) round-trip: PASS ($probe_file genuinely re-applied)"

  local status_out2
  status_out2="$(DB_CONTAINER="$scratch" PATH="$SCRIPT_DIR/pgshim:$PATH" STEWARDS_DSN="$scratch_dsn" \
    "$REPO/scripts/migrate.sh" status)"
  echo "$status_out2" | grep -q '~ ' && fail "migrate.sh status still reports diffs after the forced re-apply"
  log "post-reapply idempotency: PASS"

  trap - EXIT
  cleanup_scratch
  log "scratch-proof: PASS, teardown clean ($scratch removed)"
  : > "$STATE_DIR/scratch-proof.ok"
}

# =====================================================================
# gate — print the sanction summary. ALWAYS exits nonzero. No escape flag.
# =====================================================================
gate() {
  require_state preflight
  require_state build
  [ -f "$STATE_DIR/scratch-proof.ok" ] || log "NOTE: scratch-proof has not been run for $SHORT_SHA — recommended before sanctioning."
  echo
  echo "=================== SHIPWRIGHT SANCTION SUMMARY ==================="
  echo "target sha:         $TARGET_SHA"
  echo "build tag:          $BUILD_TAG"
  echo "live container:     $LIVE_CONTAINER"
  echo "live image (pre):   $LIVE_IMAGE_ID_PRE"
  echo "live started (pre): $LIVE_STARTED_AT_PRE"
  echo "live status (pre):  $LIVE_STATUS_PRE"
  echo "live marker (pre):  $LIVE_MARKER_PRE"
  echo
  echo "-- migrations that would apply (READ-ONLY probe against LIVE) --"
  echo "   migrate.sh 'status' mode makes zero writes (see scripts/migrate.sh's"
  echo "   status) case — it only echoes; ledger_record/pg -f never run)."
  if [ "$LIVE_STATUS_PRE" = "running" ]; then
    DB_CONTAINER="$LIVE_CONTAINER" PATH="$SCRIPT_DIR/pgshim:$PATH" STEWARDS_DSN="$STEWARDS_DSN" \
      "$REPO/scripts/migrate.sh" status || true
  else
    echo "   ($LIVE_CONTAINER is not running — nothing to diff)"
  fi
  echo
  # Docker tag names can't contain ':' — strip the "sha256:" digest prefix
  # BEFORE slicing a short id, or the preview (and a copy-pasted `docker
  # tag` command) breaks on the embedded colon.
  local live_id_short backup_tag
  live_id_short="${LIVE_IMAGE_ID_PRE#sha256:}"
  live_id_short="${live_id_short:0:12}"
  backup_tag="stewards-oss-pg:backup-$(date -u +%Y%m%dT%H%M%SZ)-${live_id_short}"
  echo "-- rollback recipe (staged by 'apply' BEFORE it recreates, not after) --"
  echo "   1. backup:  docker tag $LIVE_IMAGE_ID_PRE $backup_tag"
  echo "   2. promote: docker tag $BUILD_TAG $LIVE_TAG"
  echo "   3. recreate: docker compose -f docker-compose.yaml up -d --force-recreate pg"
  echo "   revert (any time after): scripts/upgrade-dance.sh rollback --sanctioned --confirm '...'"
  echo "     (apply's receipt names the exact backup tag it created — use that one, not this preview name)"
  echo
  local confirm_phrase="UPGRADE $LIVE_CONTAINER TO $SHORT_SHA"
  echo "GATE: this is a preview. Nothing above wrote to $LIVE_CONTAINER beyond the"
  echo "read-only status probe. To proceed, run exactly (copy this line — the"
  echo "phrase must match byte-for-byte):"
  echo
  echo "  scripts/upgrade-dance.sh apply --sanctioned --confirm \"$confirm_phrase\""
  echo "====================================================================="
  exit 2
}

# =====================================================================
# apply — ONLY with --sanctioned + matching --confirm. Live write phase.
# =====================================================================
apply_upgrade() {
  require_state preflight
  require_state build
  [ "$SANCTIONED" -eq 1 ] || fail "apply requires --sanctioned"
  local expected="UPGRADE $LIVE_CONTAINER TO $SHORT_SHA"
  [ "$CONFIRM" = "$expected" ] || fail "confirm phrase did not match. expected exactly: $expected"

  log "== apply (SANCTIONED) =="
  log "re-verifying live state fresh (stale-plan guard) before touching anything"
  docker inspect "$LIVE_CONTAINER" >/dev/null 2>&1 || fail "$LIVE_CONTAINER not found — refusing to apply against nothing"
  local live_image_now
  live_image_now="$(docker inspect "$LIVE_CONTAINER" --format '{{.Image}}')"
  if [ "$live_image_now" != "$LIVE_IMAGE_ID_PRE" ]; then
    fail "live image changed since preflight ($LIVE_IMAGE_ID_PRE -> $live_image_now) — someone else touched $LIVE_CONTAINER. Re-run preflight and gate before applying."
  fi

  local live_id_short backup_tag
  live_id_short="${live_image_now#sha256:}"
  live_id_short="${live_id_short:0:12}"
  backup_tag="stewards-oss-pg:backup-$(date -u +%Y%m%dT%H%M%SZ)-${live_id_short}"
  log "staging rollback BEFORE recreate: $backup_tag"
  docker tag "$live_image_now" "$backup_tag"

  log "promoting $BUILD_TAG -> $LIVE_TAG"
  docker tag "$BUILD_TAG" "$LIVE_TAG"

  log "docker compose up -d --force-recreate pg  (plain 'up -d' does NOT recreate on image change alone — 2026-07-09 landmine)"
  ( cd "$REPO" && docker compose -f docker-compose.yaml up -d --force-recreate pg )

  local ok=""
  for _ in $(seq 1 60); do
    docker exec "$LIVE_CONTAINER" pg_isready -U stewards -d stewards >/dev/null 2>&1 && { ok=1; break; }
    sleep 1
  done
  [ -n "$ok" ] || fail "$LIVE_CONTAINER did not become ready after recreate — check docker logs $LIVE_CONTAINER, then consider rollback"

  log "migrate.sh against live"
  DB_CONTAINER="$LIVE_CONTAINER" PATH="$SCRIPT_DIR/pgshim:$PATH" STEWARDS_DSN="$STEWARDS_DSN" \
    "$REPO/scripts/migrate.sh"

  local live_image_post live_started_post live_marker_post
  live_image_post="$(docker inspect "$LIVE_CONTAINER" --format '{{.Image}}')"
  live_started_post="$(docker inspect "$LIVE_CONTAINER" --format '{{.State.StartedAt}}')"
  live_marker_post="$(DB_CONTAINER="$LIVE_CONTAINER" "$(psql_bin)" "$STEWARDS_DSN" -tAc \
    "SELECT count(*)||' applied, latest='||coalesce(max(name),'none') FROM stewards.schema_migrations" 2>/dev/null || echo "unreadable")"

  local receipt
  receipt="$STATE_DIR/receipt-$SHORT_SHA-$(date -u +%Y%m%dT%H%M%SZ).txt"
  {
    echo "SHIPWRIGHT apply receipt"
    echo "target sha:      $TARGET_SHA"
    echo "backup tag:      $backup_tag"
    echo "--- before ---"
    echo "image:           $LIVE_IMAGE_ID_PRE"
    echo "started:         $LIVE_STARTED_AT_PRE"
    echo "marker:          $LIVE_MARKER_PRE"
    echo "--- after ---"
    echo "image:           $live_image_post"
    echo "started:         $live_started_post"
    echo "marker:          $live_marker_post"
    echo "--- inverse hypothesis ---"
    if [ "$live_image_post" = "$LIVE_IMAGE_ID_PRE" ]; then
      echo "WARNING: image id UNCHANGED — the recreate may not have taken."
    else
      echo "image id changed: PASS"
    fi
    if [ "$live_started_post" = "$LIVE_STARTED_AT_PRE" ]; then
      echo "WARNING: start time UNCHANGED — the container was not actually recreated."
    else
      echo "start time changed: PASS"
    fi
  } | tee "$receipt"
  log "receipt written: $receipt"
  log "rollback if needed: scripts/upgrade-dance.sh rollback --sanctioned --backup-tag $backup_tag --confirm \"ROLLBACK $LIVE_CONTAINER TO $backup_tag\""
}

# =====================================================================
# rollback — ONLY with --sanctioned + matching --confirm.
# =====================================================================
rollback() {
  [ "$SANCTIONED" -eq 1 ] || fail "rollback requires --sanctioned"
  local backup_tag="$BACKUP_TAG_OVERRIDE"
  if [ -z "$backup_tag" ]; then
    backup_tag="$(docker images "stewards-oss-pg" --format '{{.Repository}}:{{.Tag}}' | grep '^stewards-oss-pg:backup-' | sort -r | head -1)"
  fi
  [ -n "$backup_tag" ] || fail "no backup tag found — pass --backup-tag explicitly"
  local expected="ROLLBACK $LIVE_CONTAINER TO $backup_tag"
  [ "$CONFIRM" = "$expected" ] || fail "confirm phrase did not match. expected exactly: $expected"

  log "== rollback (SANCTIONED): $backup_tag -> $LIVE_TAG =="
  docker tag "$backup_tag" "$LIVE_TAG"
  ( cd "$REPO" && docker compose -f docker-compose.yaml up -d --force-recreate pg )
  log "rollback issued. Verify with: docker inspect $LIVE_CONTAINER --format '{{.Image}} {{.State.StartedAt}}'"
}

# =====================================================================
# arg parsing
# =====================================================================
[ $# -ge 1 ] || usage
CMD="$1"; shift
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) SHA_OVERRIDE="$2"; shift 2 ;;
    --remote) REMOTE="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --sanctioned) SANCTIONED=1; shift ;;
    --confirm) CONFIRM="$2"; shift 2 ;;
    --backup-tag) BACKUP_TAG_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$CMD" in
  preflight) preflight ;;
  build) build ;;
  scratch-proof) scratch_proof ;;
  gate) gate ;;
  apply) apply_upgrade ;;
  rollback) rollback ;;
  *) usage ;;
esac
