#!/usr/bin/env bash
# parity-check.sh — live↔repo drift oracle for the extension SQL chain.
#
# Boots a scratch postgres from the SAME image as live, runs a virgin
# CREATE EXTENSION (= the repo-truth end state of the whole chain), then
# diffs stewards.* function bodies (md5 of prosrc), views, columns, and
# triggers against the live container. Anything the virgin chain produces
# that live doesn't match is drift.
#
# Born 2026-07-04: the arXiv crawl's route_on rules silently never fired —
# live's work_item_advance was an OLD-substrate body dragged in by the
# OSS-cut-era overlay apply. This check found 11 drifted/missing functions
# in one pass (incl. compose_messages missing the send-time spend-cap gate).
#
# KNOWN, DELIBERATE exceptions (the workspace overlay re-authors these on
# live with gospel-flavored bodies; their source lives outside this repo
# until D2A packages the overlay as a proper extension):
#   doc_citations_resolved(text)
#   refresh_doc_refs(text)
#   import_doc(text,text,text,text,jsonb,text)
# Live-only functions (book_*, playlist_*, yt_*, parse_gospel_links, ...)
# are overlay-owned and expected; this script only reports scratch->live
# gaps, so they don't appear.
#
# Usage: scripts/parity-check.sh [live-container] [image]
set -u
LIVE=${1:-stewards-oss-pg}
IMAGE=${2:-stewards-oss-pg:pg18}
SCRATCH=stewards-parity-scratch
HELD_FILE=$(mktemp)
cat > "$HELD_FILE" <<'HELDEOF'
doc_citations_resolved(text)
import_doc(text,text,text,text,jsonb,text)
refresh_doc_refs(text)
HELDEOF
VEC_NOISE='halfvec|sparsevec|vector|hnsw|ivfflat|hamming|jaccard|l1_distance|l2_|inner_product|cosine_distance|binary_quantize|subvector|avg\(|sum\('

cleanup() { docker rm -f $SCRATCH >/dev/null 2>&1; rm -f "$HELD_FILE"; }
trap cleanup EXIT
docker rm -f $SCRATCH >/dev/null 2>&1

docker run -d --name $SCRATCH -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=scratch \
  -e POSTGRES_DB=stewards "$IMAGE" postgres -c shared_preload_libraries=pg_ai_stewards >/dev/null || exit 2
for i in $(seq 1 30); do
  docker exec $SCRATCH pg_isready -U stewards -d stewards >/dev/null 2>&1 && break; sleep 2
done
docker exec $SCRATCH psql -U stewards -d stewards \
  -c "CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE" >/dev/null 2>&1 || { echo "FAIL: virgin CREATE EXTENSION"; exit 2; }

fail=0
QF="SELECT p.oid::regprocedure||' '||md5(p.prosrc) FROM pg_proc p WHERE p.pronamespace='stewards'::regnamespace ORDER BY 1"
QV="SELECT viewname||' '||md5(definition) FROM pg_views WHERE schemaname='stewards' ORDER BY 1"
QC="SELECT table_name||'.'||column_name||' '||data_type FROM information_schema.columns WHERE table_schema='stewards' ORDER BY 1"
QT="SELECT event_object_table||'.'||trigger_name FROM information_schema.triggers WHERE trigger_schema='stewards' GROUP BY 1 ORDER BY 1"
for pair in "functions|$QF" "views|$QV" "columns|$QC" "triggers|$QT"; do
  label=${pair%%|*}; q=${pair#*|}
  docker exec $SCRATCH psql -U stewards -d stewards -tAc "$q" | sort > /tmp/parity_scratch.$$
  docker exec "$LIVE"  psql -U stewards -d stewards -tAc "$q" | sort > /tmp/parity_live.$$
  [ -r "$HELD_FILE" ] || { echo "FAIL: held-exceptions file vanished"; exit 2; }
  drift=$(comm -23 /tmp/parity_scratch.$$ /tmp/parity_live.$$ | awk '{print $1}' \
          | sed 's/^stewards\.//' | grep -Ev "$VEC_NOISE" | grep -vFx -f "$HELD_FILE")
  if [ -n "$drift" ]; then
    echo "DRIFT ($label): live is missing / stale vs repo-truth virgin chain:"
    echo "$drift" | sed 's/^/  /'
    fail=1
  fi
  rm -f /tmp/parity_scratch.$$ /tmp/parity_live.$$
done

if [ $fail -eq 0 ]; then
  echo "PARITY OK: live matches the virgin chain (held overlay re-authors excepted)."
else
  echo ""
  echo "Fix: port repo-truth bodies from a scratch (pg_get_functiondef) — see"
  echo ".spec/journal/ 2026-07-04 drift entry. Do NOT bulk re-apply chain files"
  echo "to live: seed ON CONFLICT DO UPDATE rows can clobber live data."
fi
exit $fail
