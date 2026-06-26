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
# Usage:
#   STEWARDS_DSN=postgres://stewards:stewards@localhost:5432/stewards ./scripts/migrate.sh [apply|adopt|status]
#   OVERLAY_DIR=overlays/<instance> ./scripts/migrate.sh        # also apply this machine's overlays
#
# Modes:
#   apply  (default) — apply every chain/overlay file whose sha256 differs from the ledger
#   adopt            — record current hashes WITHOUT applying (claim an existing install as up-to-date)
#   status           — show which files differ from the ledger (dry run, no writes)
# =====================================================================
set -euo pipefail

DSN="${STEWARDS_DSN:-postgres://stewards:stewards@localhost:5432/stewards}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO/extension/src/lib.rs"
OVERLAY_DIR="${OVERLAY_DIR:-}"
MODE="${1:-apply}"

pg() { psql "$DSN" -v ON_ERROR_STOP=1 "$@"; }
q()  { pg -tAqc "$1"; }

[ -f "$LIB" ] || { echo "FATAL: $LIB not found (run from the repo, or set REPO)"; exit 2; }

# The authoritative chain order = the extension_sql_file! sequence in lib.rs.
mapfile -t CHAIN < <(grep -oE '\.\./[0-9][A-Za-z0-9_-]*\.sql' "$LIB" | sed "s#\.\./#$REPO/extension/#")
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

apply_one() {
  local f="$1" tag="$2" n s
  [ -f "$f" ] || { echo "  ! missing: $f"; return; }
  n="$(basename "$f")"; s="$(sha256sum "$f" | cut -d' ' -f1)"
  if ledger_match "$n" "$s"; then [ "$MODE" = status ] || echo "  = $n"; return; fi
  case "$MODE" in
    status) echo "  ~ $n (DIFFERS — would apply)";;
    adopt)  echo "  adopt $n"; ledger_record "$n" "$s" "$tag adopt";;
    apply)  echo "  + $n (applying)"; pg -f "$f" >/dev/null; ledger_record "$n" "$s" "$tag";;
  esac
}

echo "== migrate ($MODE) → ${DSN%%\?*}"
echo "== core chain (${#CHAIN[@]} files) =="
for f in "${CHAIN[@]}"; do apply_one "$f" core; done

if [ -n "$OVERLAY_DIR" ]; then
  if [ -d "$OVERLAY_DIR" ]; then
    echo "== overlays ($OVERLAY_DIR) =="
    while IFS= read -r f; do apply_one "$f" "overlay"; done < <(ls "$OVERLAY_DIR"/*.sql 2>/dev/null | sort -V)
  else
    echo "  ! OVERLAY_DIR not found: $OVERLAY_DIR"
  fi
fi

echo "== migrate $MODE complete =="
