#!/usr/bin/env bash
# bgworker-survives.sh <image>: a SQL error the leader's ticks catch must not end a dispatcher.
#
# Starts the image with the bgworker loaded, creates the extension, and then:
#   1. drops stewards.batch_poll_list, which the batch cycle calls every 30 s, and watches two
#      cycles: dispatcher #0 must keep its pid, the error must be logged, and the log must show no
#      "unexpected state STARTED" and no dispatcher exit;
#   2. drops stewards.batch_open, which the cycle checks before anything else, and expects the
#      "batch SQL not installed" line, again with no exit.
# Before the fix (v66 at 36d595b) step 1 fails: the caught error left its transaction open and
# dispatcher #0 exited every 5.5 s. Takes about two minutes; no provider calls.
set -euo pipefail
IMAGE=${1:?usage: tests/bgworker-survives.sh <image>}
NAME=stewards-bgw-survives-$$
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*"; docker rm -f "$NAME" >/dev/null 2>&1 || true; exit 1; }
q() { docker exec "$NAME" psql -U stewards -d stewards -qAtc "$1"; }
leader_pid() { q "select pid from pg_stat_activity where backend_type = 'pg_ai_stewards dispatcher #0'"; }

docker run -d --name "$NAME" -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=test -e POSTGRES_DB=stewards \
  -e STEWARDS_DATABASE=stewards "$IMAGE" postgres -c shared_preload_libraries=pg_ai_stewards >/dev/null
for _ in $(seq 60); do docker exec "$NAME" pg_isready -U stewards -d stewards >/dev/null 2>&1 && break; sleep 2; done
sleep 3
docker exec -i "$NAME" psql -U stewards -d stewards -v ON_ERROR_STOP=1 -q < "$ROOT/extension/init/00-bootstrap-roles.sql" >/dev/null
q "CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE" >/dev/null
sleep 40   # let the leader run a batch cycle against the installed SQL

pid0=$(leader_pid); [ -n "$pid0" ] || fail "no dispatcher #0 after CREATE EXTENSION"
mark=$(date -u +%Y-%m-%dT%H:%M:%SZ)
q "DROP FUNCTION stewards.batch_poll_list(int)"
sleep 70
log=$(docker logs --since "$mark" "$NAME" 2>&1)
pid1=$(leader_pid)
grep -q "batch poll list: postgres error" <<<"$log" || fail "the dropped function's error was not logged"
grep -q "unexpected state STARTED" <<<"$log" && fail "a caught error left its transaction open (unexpected state STARTED)"
grep -q "exited with exit code" <<<"$log" && fail "a dispatcher exited after a caught error"
[ "$pid1" = "$pid0" ] || fail "dispatcher #0 restarted (pid $pid0 -> ${pid1:-none})"
echo "ok 1: a caught SQL error in the batch cycle is logged and dispatcher #0 keeps pid $pid0 across two cycles"

mark=$(date -u +%Y-%m-%dT%H:%M:%SZ)
q "DROP FUNCTION stewards.batch_open(text, int)"
sleep 40
log=$(docker logs --since "$mark" "$NAME" 2>&1)
grep -q "batch cycle skipped: batch SQL not installed" <<<"$log" || fail "missing batch SQL was not reported"
grep -q "batch poll list: postgres error" <<<"$log" && fail "the cycle ran past the missing batch_open"
grep -q "exited with exit code" <<<"$log" && fail "a dispatcher exited while the batch SQL was missing"
[ "$(leader_pid)" = "$pid0" ] || fail "dispatcher #0 restarted while the batch SQL was missing"
echo "ok 2: with the batch SQL missing the cycle says so once and skips; dispatcher #0 still pid $pid0"

docker rm -f "$NAME" >/dev/null
echo "PASS bgworker-survives ($IMAGE)"
