#!/usr/bin/env bash
# db.sh — safe psql access to the live stewards DB from Git Bash on Windows.
#
# Kills the four footguns that bit repeatedly on 2026-07-04:
#   1. `docker exec` without -i silently ignoring stdin (exit 0, nothing ran)
#   2. MSYS mangling in-container paths (-f /tmp/x -> C:/Users/.../tmp/x)
#   3. cp1252 re-encoding of piped SQL (em-dash -> 0x97 -> "invalid byte sequence")
#   4. exit codes lost behind grep/tail filters
#
# Usage:
#   scripts/db.sh -c "SELECT ..."          # one statement, tuples-only
#   scripts/db.sh -f path/to/file.sql      # run a HOST file (docker cp'd in, bytes intact)
#   echo "SELECT 1" | scripts/db.sh        # stdin (utf-8 passed as bytes)
# Env: DB_CONTAINER (default stewards-oss-pg), DB_USER/DB_NAME (default stewards)
set -uo pipefail
C=${DB_CONTAINER:-stewards-oss-pg}
U=${DB_USER:-stewards}
D=${DB_NAME:-stewards}
PSQL=(docker exec -i "$C" psql -U "$U" -d "$D" -v ON_ERROR_STOP=1)

case "${1:-}" in
  -c)
    shift
    printf '%s' "$1" | "${PSQL[@]}" -tA
    ;;
  -f)
    shift
    src=$1
    [ -r "$src" ] || { echo "db.sh: cannot read $src" >&2; exit 2; }
    base=$(basename "$src")
    docker cp "$src" "$C:/tmp/dbsh-$base" || exit 2
    # double slash defeats MSYS path conversion for the in-container path
    docker exec "$C" psql -U "$U" -d "$D" -v ON_ERROR_STOP=1 -f "//tmp/dbsh-$base"
    rc=$?
    docker exec "$C" rm -f "/tmp/dbsh-$base" 2>/dev/null
    exit $rc
    ;;
  "")
    "${PSQL[@]}" -tA
    ;;
  *)
    echo "db.sh: usage: db.sh -c 'SQL' | db.sh -f file.sql | <stdin>" >&2
    exit 2
    ;;
esac
