#!/usr/bin/env bash
# examples/case-file-demo/demo.sh — the deterministic spine of the case-file
# digester, end to end, against a RUNNING stack. Boots nothing itself.
#
# What it proves (with assertions, unpiped exit codes):
#   1. drop-ingest the 4 synthetic files (file_drop_ingest — the same path
#      the drop watcher takes; zero models)
#   2. case_add + case_normalize_floor — sections split, typed fact floor
#      extracted (the appeal deadline lands as a real DATE column)
#   3. the operator plays the normalize stage's two judgment writes by hand
#      (deadline promotion + the missing-document expectation) so the whole
#      spine runs without any model configured
#   4. citation_check via the bridge (mcp_proxy) against the PLANTED
#      contradiction -> MISMATCH (finding #1), recorded to the ledger;
#      then the INVERSE: fix the policy text -> CLEAN; restore the plant ->
#      MISMATCH again. CATCH / CLEAN / CATCH — the load-bearing oracle,
#      proven in both directions. (Skipped with a loud note if no bridge.)
#   5. case_assemble + case_file_publish — the case file lands as a doc;
#      we assert the timeline (with the deadline), the checklist (gap
#      first), the findings, and section anchors are all in the body.
#
# Prerequisites: the compose stack up (pg at minimum; bridge for step 4),
# and examples/case-file-digester.sql applied. Run from anywhere:
#   examples/case-file-demo/demo.sh
# Point it elsewhere (e.g. a scratch container) with:
#   PSQL="docker exec -i my-scratch psql -U stewards -d stewards" examples/case-file-demo/demo.sh
#
# The LLM stages (normalize/sanity/letter judgment) are exercised by the
# real pipeline (work_item_create on family 'case-file') — see README.md.
# This script is the zero-model floor beneath them.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

PSQL=${PSQL:-docker compose exec -T pg psql -U stewards -d stewards}
CASE=smith-appeal
QUOTE='Pre-authorization is required for all outpatient procedures.'

say()  { printf '\n== %s ==\n' "$*"; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# q "SQL" -> tuples-only result on stdout; dies on SQL error.
q() {
  local out rc
  out=$(printf '%s' "$1" | $PSQL -v ON_ERROR_STOP=1 -tA 2>&1); rc=$?
  [ $rc -eq 0 ] || die "psql: $out"
  printf '%s' "$out"
}

# ---------------------------------------------------------------- preflight
say "preflight"
[ "$(q "SELECT to_regclass('stewards.case_shelf') IS NOT NULL")" = "t" ] \
  || die "stewards.case_shelf missing — apply examples/case-file-digester.sql first"

# demo reset (idempotent re-runs): reopen the case, clear its citation
# ledger and any stale demo drafts. Data-only; touches nothing but the demo case.
q "DELETE FROM stewards.case_citations WHERE case_slug = '$CASE';
   UPDATE stewards.case_shelf SET status='building', done_at=NULL WHERE slug='$CASE';
   DELETE FROM stewards.doc_drafts WHERE session_id = 'demo-manual';" >/dev/null

# ------------------------------------------------------------- 1. ingest
say "1. drop-ingest the 4 synthetic files (file_drop_ingest, zero models)"
for f in denial-letter policy claim-history supporting-note; do
  # dollar-quoted content, bytes passed via cat (no shell re-encoding)
  status=$( { printf "SELECT stewards.file_drop_ingest('%s/%s.md', \$dropbody\$" "$CASE" "$f"
              cat "$HERE/$f.md"
              printf "\$dropbody\$, '%s')->>'status';\n" "$CASE"
            } | $PSQL -v ON_ERROR_STOP=1 -tA ) || die "ingest $f"
  case "$status" in
    ingested|skipped_unchanged) printf '  %-16s %s\n' "$f" "$status" ;;
    *) die "ingest $f: unexpected status '$status'" ;;
  esac
done
[ "$(q "SELECT count(*) FROM stewards.docs WHERE project_association='$CASE'")" = "4" ] \
  || die "expected 4 docs tagged project=$CASE"

# ------------------------------------------------- 2. shelf + deterministic floor
say "2. case_add + case_normalize_floor (split + typed fact floor)"
q "SELECT stewards.case_add('$CASE', 'A. Sample — claim CF-88214 (synthetic demo)')" >/dev/null
q "UPDATE stewards.case_shelf SET status='building' WHERE slug='$CASE'" >/dev/null
floor=$(q "SELECT stewards.case_normalize_floor('$CASE')")
echo "  $floor"
[ "$(printf '%s' "$floor" | grep -c '"ok": *true')" = "1" ] || die "case_normalize_floor not ok"

say "the typed rows themselves (this is the not-vibes proof)"
q "SELECT d.slug || '  [' || count(s.*) || ' sections]'
     FROM stewards.docs d LEFT JOIN stewards.doc_sections s ON s.doc_id=d.id
    WHERE d.project_association='$CASE' GROUP BY d.slug ORDER BY d.slug" | sed 's/^/  /'
q "SELECT df.fact_kind || '  ' || coalesce(df.value_date::text, df.value_numeric::text)
          || '  <- \"' || df.raw_text || '\"  [' || d.slug || coalesce('#'||df.section_ref,'') || ']'
     FROM stewards.doc_facts df JOIN stewards.docs d ON d.id=df.doc_id
    WHERE d.project_association='$CASE' ORDER BY df.fact_kind, df.value_date, df.value_numeric" | sed 's/^/  /'
[ "$(q "SELECT count(*) FROM stewards.doc_facts df JOIN stewards.docs d ON d.id=df.doc_id
         WHERE d.project_association='$CASE' AND df.value_date='2026-07-15'")" -ge 1 ] \
  || die "the appeal deadline 2026-07-15 did not land as a typed date"

# ------------------------- 3. the two judgment writes, played by hand
say "3. deadline promotion + evidence expectations (the normalize stage's writes)"
ok=$(q "SELECT stewards.doc_fact_add(jsonb_build_object(
     'doc_slug','$CASE-denial-letter','fact_kind','deadline',
     'raw_text','Your appeal must be received no later than July 15, 2026.',
     'value_date','2026-07-15',
     'section_ref',(SELECT s.section_ref FROM stewards.doc_sections s
                      JOIN stewards.docs d ON d.id=s.doc_id
                     WHERE d.slug='$CASE-denial-letter' AND s.heading ILIKE '%appeal rights%' LIMIT 1),
     'extracted_by','demo.sh (playing the normalize stage)'))->>'ok'")
[ "$ok" = "true" ] || die "doc_fact_add (deadline promotion) failed"
for item in "Physician letter of medical necessity|missing|" \
            "Denial letter|have|$CASE-denial-letter" \
            "Policy excerpt|have|$CASE-policy" \
            "Claim history summary|have|$CASE-claim-history"; do
  IFS='|' read -r name st sat <<<"$item"
  ok=$(q "SELECT stewards.evidence_set(jsonb_build_object(
       'scope_kind','project','scope_id','$CASE','item','$name','status','$st'
       $( [ -n "$sat" ] && printf ",'satisfied_by_doc_slug','%s'" "$sat" )))->>'ok'")
  [ "$ok" = "true" ] || die "evidence_set '$name' failed"
done
echo "  recorded: 1 deadline promotion, 4 evidence expectations (1 MISSING)"

# --------------------------------- 4. the sanity oracle, inverse-proven
# citation_check is a Go tool on the pg-ai-stewards MCP surface; a pipeline
# stage reaches it through the bridge (mcp_proxy). We drive the same path.
check_citation() {  # $1=quote -> echoes the structuredContent jsonb; empty on bridge-unavailable
  local id i st
  id=$(q "SELECT stewards.mcp_proxy_enqueue('pg-ai-stewards','citation_check',
            jsonb_build_object('quote', \$q\$$1\$q\$, 'doc', '$CASE-policy', 'heading', '4.2(b)'), NULL)")
  [ -n "$id" ] || { echo ""; return; }
  for i in $(seq 1 30); do
    st=$(q "SELECT status FROM stewards.work_queue WHERE id=$id")
    [ "$st" = "done" ] && { q "SELECT result->'structuredContent' FROM stewards.work_queue WHERE id=$id"; return; }
    [ "$st" = "error" ] && die "citation_check bridge error: $(q "SELECT error FROM stewards.work_queue WHERE id=$id")"
    sleep 1
  done
  echo ""
}

say "4. citation_check vs. the planted contradiction (CATCH / CLEAN / CATCH)"
sc=$(check_citation "$QUOTE")
if [ -z "$sc" ]; then
  cat <<'EOF'
  ! bridge not reachable (mcp_proxy_enqueue returned NULL or timed out).
  ! The inverse proof needs the bridge service up:  docker compose up -d bridge
  ! then:  docker compose exec bridge stewards-mcp bridge refresh-tools
  ! (or call the citation_check tool from any MCP client on stewards-mcp).
  ! Skipping steps 4a-4c — the case file will honestly show "no citation checks recorded".
EOF
else
  echo "  4a CATCH — verdict: $sc"
  [ "$(printf '%s' "$sc" | grep -c '"verified": *false')" = "1" ] \
    || die "inverse proof: the planted contradiction was NOT caught (expected verified=false)"

  # record the honest verdict in the ledger (what the sanity stage does)
  ok=$(q "SELECT stewards.case_citation_record(jsonb_build_object(
       'case_slug','$CASE',
       'claim_quote', \$q\$$QUOTE\$q\$,
       'cited_doc','$CASE-policy',
       'source_doc','$CASE-denial-letter',
       'verified', (\$sc\$$sc\$sc\$::jsonb->>'verified')::boolean,
       'cited_section_ref', coalesce(\$sc\$$sc\$sc\$::jsonb->'found_at'->>'section_ref',
                                     \$sc\$$sc\$sc\$::jsonb->>'nearest_section_ref'),
       'nearest_excerpt', \$sc\$$sc\$sc\$::jsonb->>'nearest_excerpt',
       'overlap_chars', nullif(\$sc\$$sc\$sc\$::jsonb->>'overlap_chars','')::int,
       'note', \$sc\$$sc\$sc\$::jsonb->>'note'))->>'ok'")
  [ "$ok" = "true" ] || die "case_citation_record failed"
  echo "  4a recorded to the case_citations ledger (finding #1)"

  # 4b INVERSE, clean half: ingest a FIXED policy (in-memory sed; the repo
  # file is untouched), re-split, re-check -> must verify.
  { printf "SELECT stewards.file_drop_ingest('%s/policy.md', \$dropbody\$" "$CASE"
    sed 's/required only for elective, non-emergency outpatient procedures/required for all outpatient procedures/' "$HERE/policy.md"
    printf "\$dropbody\$, '%s')->>'status';\n" "$CASE"
  } | $PSQL -v ON_ERROR_STOP=1 -tA >/dev/null || die "fixed-policy ingest"
  q "SELECT stewards.doc_split_sections(stewards._doc_id_resolve('$CASE-policy'))->>'ok'" >/dev/null
  sc2=$(check_citation "$QUOTE")
  [ "$(printf '%s' "$sc2" | grep -c '"verified": *true')" = "1" ] \
    || die "inverse proof: after fixing the policy the quote should VERIFY (got: $sc2)"
  echo "  4b CLEAN — with the contradiction removed, verified=true"

  # 4c restore the plant (the demo SHIPS with it — it is the point).
  # import_doc directly: the drop ledger already knows the original sha,
  # so a re-drop would dedup-skip; this is the explicit restore.
  { printf "SELECT stewards.import_doc('%s-policy', '%s/policy.md',
              'Example Mutual Assurance — Member Policy (Synthetic Excerpt)', \$dropbody\$" "$CASE" "$CASE"
    cat "$HERE/policy.md"
    printf "\$dropbody\$, jsonb_build_object('origin','file-drop','drop_path','%s/policy.md','restored_by','demo.sh'), 'doc');\n" "$CASE"
  } | $PSQL -v ON_ERROR_STOP=1 -tA >/dev/null || die "policy restore"
  q "UPDATE stewards.docs SET project_association='$CASE', source_type='file-drop'
      WHERE slug='$CASE-policy'" >/dev/null
  q "SELECT stewards.doc_split_sections(stewards._doc_id_resolve('$CASE-policy'))->>'ok'" >/dev/null
  sc3=$(check_citation "$QUOTE")
  [ "$(printf '%s' "$sc3" | grep -c '"verified": *false')" = "1" ] \
    || die "inverse proof: after restoring the plant the mismatch should return (got: $sc3)"
  echo "  4c CATCH — plant restored, mismatch returns. Oracle proven both directions."
fi

# ------------------------------------------ 5. assemble + publish + assert
say "5. case_assemble + case_file_publish (server-side renders; zero models)"
handle=$(q "SELECT stewards.case_assemble_tool(jsonb_build_object('session','demo-manual','case_slug','$CASE'))->>'handle'")
[ -n "$handle" ] || die "case_assemble returned no handle"
echo "  draft handle: $handle"
q "SELECT stewards.case_file_publish_tool(jsonb_build_object('session','demo-manual','handle','$handle'))->>'doc_slug'" >/dev/null

body=$(q "SELECT body FROM stewards.docs WHERE slug='case-file-$CASE'")
# unconditional: the spine guarantees these with zero models and no bridge
for must in '## Findings' '## Fact timeline' '2026-07-15' '(DEADLINE)' \
            'MISSING' 'Physician letter of medical necessity' \
            '## Denial map' '#s1.3'; do
  case "$body" in
    *"$must"*) printf '  ok: body contains %s\n' "$must" ;;
    *)         die "published case file missing: $must" ;;
  esac
done
# bridge-dependent: the recorded mismatch surfaces as finding #1
if [ -n "${sc:-}" ]; then
  case "$body" in
    *'Finding #1'*) echo '  ok: body surfaces the planted contradiction as Finding #1' ;;
    *)              die 'published case file missing: Finding #1 (the recorded mismatch)' ;;
  esac
fi

say "the case file (first 60 lines)"
printf '%s\n' "$body" | head -60 | sed 's/^/  | /'

say "gate proof"
echo "  No send capability exists anywhere in this pipeline. Verify it yourself:"
echo "    grep -ri 'case_.*send\\|appeal_send' extension/*.sql examples/*.sql cmd/stewards-mcp/*.go"
echo "  (expect zero results — an absent capability cannot be jailbroken)"

say "DONE — deterministic spine green. For the full pipeline (LLM stages), see README.md"
