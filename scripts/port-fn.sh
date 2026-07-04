#!/usr/bin/env bash
# port-fn.sh — port ONE function's current source-file definition to the live DB.
#
# The safe middle path between "single-file apply" (clobbers later re-authors)
# and "changed-file -> end-of-chain" (slow; seed ON CONFLICT rows can clobber
# live data): extract exactly one CREATE OR REPLACE FUNCTION block from a chain
# file and apply just that. ONLY safe when no LATER chain file re-authors the
# same function — check with:  grep -l "FUNCTION stewards.<name>" extension/*.sql
# Run scripts/parity-check.sh afterward; it stays the drift oracle.
#
# Usage: scripts/port-fn.sh extension/14-fanout-brainstorm.sql spawn_children
set -uo pipefail
FILE=${1:?usage: port-fn.sh <chain-file> <function-name>}
FN=${2:?usage: port-fn.sh <chain-file> <function-name>}
C=${DB_CONTAINER:-stewards-oss-pg}

TMP=$(python - "$FILE" "$FN" <<'EOF'
import io, re, sys, tempfile, os
path, fn = sys.argv[1], sys.argv[2]
s = io.open(path, encoding='utf-8').read()
# match through the closing dollar-quote tag + semicolon, any tag name
m = re.search(
    r'(CREATE OR REPLACE FUNCTION stewards\.' + re.escape(fn) +
    r'\s*\(.*?\$([A-Za-z_]*)\$.*?\$\2\$;)', s, re.S)
if not m:
    sys.exit(f"port-fn: {fn} not found in {path}")
fd, out = tempfile.mkstemp(suffix='.sql')
with io.open(fd, 'w', encoding='utf-8', newline='\n') as f:
    f.write(m.group(1))
print(out)
EOF
) || exit 2

docker cp "$TMP" "$C:/tmp/port-fn.sql" || exit 2
docker exec "$C" psql -U "${DB_USER:-stewards}" -d "${DB_NAME:-stewards}" \
    -v ON_ERROR_STOP=1 -f "//tmp/port-fn.sql"
rc=$?
docker exec "$C" rm -f /tmp/port-fn.sql 2>/dev/null
rm -f "$TMP"
[ $rc -eq 0 ] && echo "port-fn: stewards.$FN ported from $FILE (run scripts/parity-check.sh to confirm)"
exit $rc
