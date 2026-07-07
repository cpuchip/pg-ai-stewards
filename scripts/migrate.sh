#!/usr/bin/env bash
# =====================================================================
# migrate.sh — bring an existing pg-ai-stewards DB up to the image's code.
# =====================================================================
# Code lives in the IMAGE (Rust .so + the NN-*.sql chain). DATA lives in the
# `pgdata` VOLUME. This applies only the chain DIFF since the last run, so a
# rebuild + restart never needs a backup/restore for the common cases:
#
#   git pull  →  docker compose build  →  docker compose up -d  →  migrate.sh  →  verify
#
# Idempotent by construction: functions are CREATE OR REPLACE, tables are
# IF NOT EXISTS (rows preserved), seeds are ON CONFLICT DO UPDATE (config
# refreshed FROM the repo — so config-as-code, no cross-machine drift).
#
# Design: .spec/proposals/upgrade-and-overlays.md   Runbook: docs/operations.md
#
# THE RUNTIME CONTRACT (2026-07-03, audit-synthesis-2026-07.md §IV):
# this is the ONE blessed runner (stewards-cli's old `migrate` subcommand is
# retired — see cmd/stewards-cli/migrate.go). Overlay apply order used to be
# a plain `ls | sort -V` — cosmetic-looking, but wrong: `cut3-restore-core-
# finals.sql` documents "runs LAST (manifest tail) so core finals win," and
# `sort -V` sorts "cut3-" near the FRONT (alphabetically before "pe5-"/"r6-"),
# which is the exact ordering that let a stale overlay silently REVERT a core
# final (the r6/pe5/cut3 saga). Fix: when OVERLAY_DIR contains a
# `migration-manifest.txt`, that file is now the apply-order CONTRACT, not
# just a CI-parity artifact:
#   - manifest-listed file missing on disk  → hard error (nothing applies)
#   - file on disk NOT in the manifest      → hard error naming it, so the
#     manifest stays authoritative (escape hatch: --allow-unlisted appends
#     unlisted files in sort -V order AFTER the manifest)
#   - no manifest present                   → unchanged: sort -V (manifest-
#     less overlay dirs, e.g. a brand-new private overlay repo, still work)
# A file whose first ~10 lines carry `-- requires-core: <range>` is checked
# against stewards.assert_core_compat(range) immediately before it applies;
# a failing check aborts that file AND the run (loud, not a silent skip).
# And `parity/overlay-clobber-check.sh`, if found next to OVERLAY_DIR, runs
# as a pre-apply gate by default (--skip-clobber-check opts out) — the same
# "does an overlay revert a core final" question, asked BEFORE you apply
# instead of only in CI.
#
# Usage:
#   STEWARDS_DSN=postgres://stewards:stewards@localhost:5432/stewards \
#     ./scripts/migrate.sh [apply|adopt|status] [--allow-unlisted] [--skip-clobber-check]
#   OVERLAY_DIR=overlays/<instance> ./scripts/migrate.sh        # also apply this machine's overlays
#
# Modes:
#   apply  (default) — apply every chain/overlay file whose sha256 differs from the ledger
#   adopt            — record current hashes WITHOUT applying (claim an existing install as up-to-date)
#   status           — show which files differ from the ledger (dry run, no writes)
#
# Flags:
#   --allow-unlisted     an overlay .sql file not in migration-manifest.txt is normally a hard
#                        error (the manifest stays the contract); this appends such files, in
#                        sort -V order, AFTER the manifest instead. Escape hatch, not the default.
#   --skip-clobber-check skip the parity/overlay-clobber-check.sh pre-apply gate. The gate only
#                        runs when that script exists next to OVERLAY_DIR and MODE=apply.
# =====================================================================
set -euo pipefail

DSN="${STEWARDS_DSN:-postgres://stewards:stewards@localhost:5432/stewards}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/extension/src/lib.rs"
OVERLAY_DIR="${OVERLAY_DIR:-}"

MODE="apply"
ALLOW_UNLISTED=0
SKIP_CLOBBER_CHECK=0
for arg in "$@"; do
  case "$arg" in
    apply|adopt|status) MODE="$arg" ;;
    --allow-unlisted) ALLOW_UNLISTED=1 ;;
    --skip-clobber-check) SKIP_CLOBBER_CHECK=1 ;;
    *) echo "migrate.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

pg() { psql "$DSN" -v ON_ERROR_STOP=1 "$@"; }
q()  { pg -tAqc "$1"; }

[ -f "$LIB" ] || { echo "FATAL: $LIB not found (run from the repo, or set REPO)"; exit 2; }

# The authoritative CORE chain order = the extension_sql_file! sequence in lib.rs.
# The char class starts [A-Za-z0-9] (not just [0-9]) so the consolidated volume
# names (v00-foundations.sql …, feat/lightening) parse alongside any legacy
# NN-*.sql names. Anchored on `../…​.sql`, which only appears in the macro paths.
mapfile -t CHAIN < <(grep -oE '\.\./[A-Za-z0-9][A-Za-z0-9_.-]*\.sql' "$LIB" | sed "s#\.\./#$REPO/extension/#")
[ "${#CHAIN[@]}" -gt 0 ] || { echo "FATAL: no chain files parsed from lib.rs"; exit 2; }

# Ensure the extension + ledger exist (no-op if already present).
q "CREATE EXTENSION IF NOT EXISTS vector;"           >/dev/null
q "CREATE EXTENSION IF NOT EXISTS pg_ai_stewards;"   >/dev/null

ledger_match() { [ "$(q "SELECT 1 FROM stewards.schema_migrations WHERE name=\$\$$1\$\$ AND sha256=\$\$$2\$\$")" = "1" ]; }
ledger_record() {
  q "INSERT INTO stewards.schema_migrations(name,sha256,applied_at,notes)
     VALUES(\$\$$1\$\$,\$\$$2\$\$,now(),\$\$$3\$\$)
     ON CONFLICT (name) DO UPDATE SET sha256=EXCLUDED.sha256, applied_at=now(), notes=EXCLUDED.notes;" >/dev/null
}

# First-run safety: extension present but ledger empty = an existing CREATE-EXTENSION install
# adopting migrate for the first time. ADOPT (record, don't re-apply) so we don't needlessly
# refresh seeds on a DB that already matches the image.
if [ "$MODE" = apply ] && [ "$(q 'SELECT count(*) FROM stewards.schema_migrations')" = "0" ]; then
  echo "ledger empty + extension installed → ADOPT (record current hashes; no re-apply)"
  MODE=adopt
fi

# requires-core header: the first `-- requires-core: <range>` in a file's first
# 10 lines, else empty (headerless files are unconstrained).
requires_core_header() {
  head -n 10 "$1" 2>/dev/null \
    | grep -m1 -oE -- '--[[:space:]]*requires-core:[[:space:]]*.+' \
    | sed -E 's/^--[[:space:]]*requires-core:[[:space:]]*//'
}

# Runs ONLY when a file is about to genuinely apply (see apply_one's `apply)` arm).
# Aborts that file AND the whole run on failure — the point of the header is a
# loud, pre-apply stop, not a warning a busy operator can scroll past.
check_requires_core() {
  local n="$1" range="$2" out rc
  set +e
  out="$(pg -tAc "SELECT stewards.assert_core_compat(\$\$${range}\$\$);" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    echo "FATAL: $n declares '-- requires-core: $range' — the installed core fails the check:"
    echo "$out" | sed 's/^/    /'
    return 1
  fi
  return 0
}

apply_one() {
  local f="$1" tag="$2" range="${3:-}" n s
  [ -f "$f" ] || { echo "  ! missing: $f"; return; }
  n="$(basename "$f")"; s="$(sha256sum "$f" | cut -d' ' -f1)"
  if ledger_match "$n" "$s"; then [ "$MODE" = status ] || echo "  = $n"; return; fi
  case "$MODE" in
    status) echo "  ~ $n (DIFFERS — would apply)";;
    adopt)  echo "  adopt $n"; ledger_record "$n" "$s" "$tag adopt";;
    apply)
      if [ -n "$range" ]; then
        check_requires_core "$n" "$range" || exit 3
      fi
      echo "  + $n (applying)"; pg -f "$f" >/dev/null; ledger_record "$n" "$s" "$tag";;
  esac
}

# ── consolidation adopt (feat/lightening) ──────────────────────────────────
# The 109-file chain (00-config.sql … 107-lifeless-core.sql) was consolidated
# into ~28 themed VOLUME files (v00-foundations.sql …). An existing install's
# ledger recorded the OLD file names; the volumes are NEW names, so the plain
# apply loop below would re-apply every volume (idempotent, but it needlessly
# refreshes seeds/config). This pre-pass instead ADOPTS a volume — records its
# hash without applying — when every original file it absorbed is already in
# the ledger by name (i.e. the old chain that produced this volume's content
# is already installed). extension/consolidation-map.txt is the volume→files
# map (generated by the consolidation move, verified byte-exact by
# extension/verify-consolidation.py). A fresh CREATE-EXTENSION install has an
# empty ledger and is handled by the ADOPT flip above, so this is a no-op
# there; a partially-migrated old install simply falls through to apply_one
# (safe: CREATE OR REPLACE). Old-name ledger rows are left in place (harmless —
# the chain loop never revisits a name not in lib.rs).
CONSOL_MAP="$REPO/extension/consolidation-map.txt"
adopt_consolidated_volumes() {
  [ -f "$CONSOL_MAP" ] || return 0
  local line vol olds o all f s
  while IFS= read -r line; do
    case "$line" in \#*|"") continue;; esac
    vol="${line%%:*}"; vol="${vol//[[:space:]]/}"
    olds="${line#*:}"
    # already recorded by name? the chain loop's hash check owns it from here.
    [ "$(q "SELECT 1 FROM stewards.schema_migrations WHERE name=\$\$$vol\$\$")" = "1" ] && continue
    all=1
    for o in $olds; do
      [ "$(q "SELECT 1 FROM stewards.schema_migrations WHERE name=\$\$$o\$\$")" = "1" ] || { all=0; break; }
    done
    [ "$all" -eq 1 ] || continue
    f="$REPO/extension/$vol"
    [ -f "$f" ] || { echo "  ! consolidation-map lists $vol but it is missing on disk"; continue; }
    s="$(sha256sum "$f" | cut -d' ' -f1)"
    case "$MODE" in
      status) echo "  ~ $vol (would ADOPT — its old chain files are in the ledger)";;
      *)      echo "  adopt(consolidated) $vol"; ledger_record "$vol" "$s" "core consolidation-adopt";;
    esac
  done < "$CONSOL_MAP"
}

echo "== migrate ($MODE) → ${DSN%%\?*}"
if [ "$MODE" = apply ] || [ "$MODE" = status ]; then
  echo "== consolidation adopt (old-chain ledger → volumes) =="
  adopt_consolidated_volumes
fi
echo "== core chain (${#CHAIN[@]} files) =="
for f in "${CHAIN[@]}"; do apply_one "$f" core; done

if [ -n "$OVERLAY_DIR" ]; then
  if [ -d "$OVERLAY_DIR" ]; then
    MANIFEST="$OVERLAY_DIR/migration-manifest.txt"

    if [ -f "$MANIFEST" ]; then
      echo "== overlays ($OVERLAY_DIR, manifest-ordered: $MANIFEST) =="

      # ── the clobber gate — a pre-apply question, not just CI's ────────
      if [ "$MODE" = apply ] && [ "$SKIP_CLOBBER_CHECK" -eq 0 ]; then
        WS_ROOT="$(cd "$OVERLAY_DIR/.." && pwd)"
        CLOBBER_CHECK="$WS_ROOT/parity/overlay-clobber-check.sh"
        if [ -x "$CLOBBER_CHECK" ] || [ -f "$CLOBBER_CHECK" ]; then
          echo "== clobber gate: $CLOBBER_CHECK =="
          if ! ( cd "$WS_ROOT" && bash "$CLOBBER_CHECK" "${CLOBBER_CHECK_IMAGE:-stewards-oss-pg:test}" ); then
            echo "FATAL: overlay-clobber-check failed — an overlay reverts a core final."
            echo "       Fix the overlay (see overlays/README.md), or re-run with --skip-clobber-check"
            echo "       if you have already reviewed this and intend to proceed anyway."
            exit 1
          fi
        else
          echo "== clobber gate: no parity/overlay-clobber-check.sh next to $OVERLAY_DIR — skipping =="
        fi
      elif [ "$SKIP_CLOBBER_CHECK" -eq 1 ]; then
        echo "== clobber gate: SKIPPED (--skip-clobber-check) =="
      fi

      # ── the manifest IS the apply-order contract ───────────────────────
      declare -A IN_MANIFEST=()
      MANIFEST_FILES=()
      while IFS= read -r name; do
        case "$name" in \#*|"") continue;; esac
        MANIFEST_FILES+=("$name")
        IN_MANIFEST["$name"]=1
      done < "$MANIFEST"

      for name in "${MANIFEST_FILES[@]}"; do
        [ -f "$OVERLAY_DIR/$name" ] || { echo "FATAL: manifest lists '$name' but it is missing on disk ($OVERLAY_DIR/$name)"; exit 2; }
      done

      UNLISTED=()
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        n="$(basename "$f")"
        [ -n "${IN_MANIFEST[$n]:-}" ] && continue
        UNLISTED+=("$n")
      done < <(ls "$OVERLAY_DIR"/*.sql 2>/dev/null | sort -V)

      if [ "${#UNLISTED[@]}" -gt 0 ]; then
        if [ "$ALLOW_UNLISTED" -eq 1 ]; then
          echo "  ! ${#UNLISTED[@]} file(s) on disk not in the manifest — appending (sort -V, --allow-unlisted):"
          for n in "${UNLISTED[@]}"; do echo "      + $n"; done
        else
          echo "FATAL: ${#UNLISTED[@]} file(s) on disk are NOT in $MANIFEST (the manifest is the apply-order contract):"
          for n in "${UNLISTED[@]}"; do echo "    $n"; done
          echo "Add them to the manifest in their intended position, or pass --allow-unlisted to append"
          echo "them (sort -V) after it as an escape hatch."
          exit 2
        fi
      fi

      for name in "${MANIFEST_FILES[@]}"; do
        f="$OVERLAY_DIR/$name"
        apply_one "$f" overlay "$(requires_core_header "$f")"
      done
      if [ "$ALLOW_UNLISTED" -eq 1 ]; then
        for name in "${UNLISTED[@]}"; do
          f="$OVERLAY_DIR/$name"
          apply_one "$f" overlay "$(requires_core_header "$f")"
        done
      fi
    else
      echo "== overlays ($OVERLAY_DIR, no manifest — sort -V fallback, unchanged behavior) =="
      while IFS= read -r f; do
        apply_one "$f" overlay "$(requires_core_header "$f")"
      done < <(ls "$OVERLAY_DIR"/*.sql 2>/dev/null | sort -V)
    fi
  else
    echo "  ! OVERLAY_DIR not found: $OVERLAY_DIR"
  fi
fi

echo "== migrate $MODE complete =="
