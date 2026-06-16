#!/usr/bin/env bash
# e2e-turn-loop.sh — exercise a REAL persona turn end-to-end against a running
# stack and assert the invariants that virgin-smoke + verify-* cannot see.
#
# WHY (2026-06-16): a run of bugs sailed through smoke + verify because they
# only appear when a turn actually RUNS — they live in the dispatch -> tool-round
# -> verify -> consult loop, not in schema or single-function checks:
#   - the on_one_shot clobber left persona turns at maturity=raw (the host timed
#     out -> personas went silent);
#   - a prompt dumped the same canned summary for every question;
#   - the consult read the prior turn's reply (one behind).
# smoke = "does the object exist"; verify = "does this fn do X alone"; neither
# runs a turn. This is that missing layer.
#
# It makes REAL LLM calls (~1-2 min, small $) — run it on demand, not in
# every-commit CI. Exit 0 = all invariants hold; non-zero = a regression.
#
# Usage:  tests/e2e-turn-loop.sh [pg_container] [pipeline_family]
#   pg_container    default: stewards-oss-pg
#   pipeline_family default: persona-turn  (a tool persona like persona-turn-tools
#                            exercises the multi-work_queue consult path too)
set -euo pipefail

PG="${1:-stewards-oss-pg}"
PIPELINE="${2:-persona-turn}"
Q1="${E2E_Q1:-You are a terse harbor pilot. In one sentence, what is the safest heading out of a fogbank?}"
Q2="${E2E_Q2:-Different question: you are a terse harbor pilot. In one sentence, when should a ship drop anchor in a storm?}"

q() { docker exec -i -e PGUSER=stewards -e PGDATABASE=stewards "$PG" psql -tA "$@"; }
fail() { echo "  [FAIL] $1"; exit 1; }
ok()   { echo "  [ok]   $1"; }

echo "== e2e-turn-loop on $PG (pipeline=$PIPELINE) =="

# Resolve an intent to attach the turn to (any seeded one).
INTENT=$(q -c "SELECT id FROM stewards.intents ORDER BY (slug='default') DESC, slug LIMIT 1;")
[ -n "$INTENT" ] || fail "no intent seeded to attach a turn to"

SLUG="e2e-$(date +%s)"

# --- 1. turn-zero: dispatch -> completes -> AUTO-VERIFIES (catches the clobber) ---
q -c "DO \$\$ DECLARE v uuid; BEGIN
  v := stewards.work_item_create('$PIPELINE', jsonb_build_object('binding_question', \$Q\$${Q1}\$Q\$), '${SLUG}-a', 'e2e', NULL, '${INTENT}'::uuid);
  PERFORM stewards.work_item_dispatch_stage(v);
END \$\$;" >/dev/null
for i in $(seq 1 30); do
  st=$(q -c "SELECT status FROM stewards.work_items WHERE slug='${SLUG}-a';")
  case "$st" in completed|failed) break;; esac; sleep 5
done
[ "$st" = "completed" ] || fail "turn-zero did not complete (status=$st)"
MAT=$(q -c "SELECT maturity FROM stewards.work_items WHERE slug='${SLUG}-a';")
[ "$MAT" = "verified" ] || fail "turn-zero completed but maturity=$MAT (not verified) — the on_one_shot auto-verify is broken; the host would time out"
ANS_A=$(q -c "SELECT COALESCE(stage_results->'turn'->>'output','') FROM stewards.work_items WHERE slug='${SLUG}-a';")
[ -n "$ANS_A" ] || fail "turn-zero verified but produced no output"
ok "turn-zero completed + auto-verified + non-empty"

# --- 2. a DIFFERENT question -> a DIFFERENT answer (catches the canned-dump) ---
q -c "DO \$\$ DECLARE v uuid; BEGIN
  v := stewards.work_item_create('$PIPELINE', jsonb_build_object('binding_question', \$Q\$${Q2}\$Q\$), '${SLUG}-b', 'e2e', NULL, '${INTENT}'::uuid);
  PERFORM stewards.work_item_dispatch_stage(v);
END \$\$;" >/dev/null
for i in $(seq 1 30); do
  st=$(q -c "SELECT status FROM stewards.work_items WHERE slug='${SLUG}-b';")
  case "$st" in completed|failed) break;; esac; sleep 5
done
[ "$st" = "completed" ] || fail "second turn did not complete (status=$st)"
ANS_B=$(q -c "SELECT COALESCE(stage_results->'turn'->>'output','') FROM stewards.work_items WHERE slug='${SLUG}-b';")
[ -n "$ANS_B" ] || fail "second turn produced no output"
[ "$ANS_A" != "$ANS_B" ] || fail "different questions produced IDENTICAL answers — the persona is dumping a canned reply, not answering"
ok "different questions -> different answers"

# --- 3. consult re-ask on the turn-zero session -> a NEW tracked reply ---
SESS=$(q -c "SELECT session_ids[1] FROM stewards.work_items WHERE slug='${SLUG}-a';")
if [ -n "$SESS" ]; then
  BASE=$(q -c "SELECT COALESCE(max(id),0) FROM stewards.messages WHERE session_id='${SESS}' AND role='assistant';")
  q -c "SELECT stewards.consult_subagent_dispatch('${SESS}', \$Q\$${Q2}\$Q\$);" >/dev/null
  NEWID=0
  for i in $(seq 1 30); do
    NEWID=$(q -c "SELECT COALESCE(max(id),0) FROM stewards.messages WHERE session_id='${SESS}' AND role='assistant' AND COALESCE(content,'')<>'' AND id > ${BASE};")
    [ "${NEWID:-0}" -gt 0 ] && break; sleep 5
  done
  [ "${NEWID:-0}" -gt 0 ] || fail "consult produced no NEW assistant message (id>${BASE}) — the turn-N path is stuck or reading the prior reply"
  ok "consult re-ask produced a new tracked reply (msg id=${NEWID} > baseline ${BASE})"
else
  echo "  [skip] no session on turn-zero (pipeline has no session surface); consult check skipped"
fi

# cleanup the e2e dispatches
q -c "DELETE FROM stewards.work_items WHERE slug LIKE '${SLUG}-%';" >/dev/null
echo "== e2e-turn-loop PASS: turn runs, auto-verifies, answers track the question =="
