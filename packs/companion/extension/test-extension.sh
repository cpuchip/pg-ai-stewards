#!/usr/bin/env bash
# packs/companion/extension/test-extension.sh — the D2A oracle
# (.spec/proposals/d2a-pack-extension-battle-plan.md, "The oracle").
#
# Boots ONE scratch postgres from an existing core image, drops the
# stewards_companion extension files into its sharedir (least-invasive path —
# no rebuild), and drives the full oracle to GREEN on scratch:
#
#   stage 1  virgin pg + core ext + CREATE EXTENSION stewards_companion '0.1.0'
#   stage 2  0.1.0 smoke (forge happy+refusals via smoke.sql; reminders;
#            bell; approve guard) + ASSERT steward-tools ABSENT at 0.1.0
#   stage 3  ALTER EXTENSION UPDATE TO '0.2.0' + steward-tools smoke
#            (present; model_health shape; unstick refusal; forge rate guard)
#   stage 4  fresh 2nd DB straight to 0.2.0 (default_version) + same smoke
#   stage 5  pg_dump/restore -> a reminders row AND a forged_tools row survive
#   stage 6  uninstall posture: forged tool present -> DROP refuses ->
#            companion_uninstall() (allowlist shrinks, tool_defs deactivate)
#            -> DROP still refuses -> DROP CASCADE succeeds -> survivors EXACT
#   stage 7  catalog parity: loose-SQL path vs extension path, diff catalogs
#   stage 8  ship path: the Dockerfile guarded-COPY lands the pack in an image
#
# Exit 0 = every stage passed. Exit 1 = a stage failed (loud, via ASSERT).
#
# Usage: packs/companion/extension/test-extension.sh [core-image]
#   core-image defaults to stewards-oss-pg:v31test (any image built from
#   `extension/` works — it carries the core pg_ai_stewards extension the
#   pack `requires`). All work happens in a scratch container named with the
#   d2a suffix; the LIVE stack is never touched (D2A constitution #1-2).
set -uo pipefail

IMAGE=${1:-stewards-oss-pg:v31test}
SCRATCH=stewards-companion-scratch-d2a
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"      # packs/companion

# Hardcoded, not probed via `pg_config --sharedir`: the runtime image
# (pgvector/pgvector:pg18) ships extensions here and does not guarantee
# pg_config. Double leading slash defeats Git-Bash/MSYS path mangling of the
# in-container path handed to docker cp; Linux collapses `//usr` to `/usr`.
EXTDIR="//usr/share/postgresql/18/extension"

fail=0
die() { echo "FAIL: $*"; fail=1; }

cleanup() { docker rm -f "$SCRATCH" >/dev/null 2>&1; docker rmi d2a-shippath-test >/dev/null 2>&1; }
trap cleanup EXIT
docker rm -f "$SCRATCH" >/dev/null 2>&1

# --- helpers -----------------------------------------------------------------
# scalar DB SQL -> prints the single-value result (CR stripped).
scalar() { docker exec "$SCRATCH" psql -U stewards -d "$1" -tAc "$2" 2>/dev/null | tr -d '\r'; }

# sql_assert DB LABEL  (SQL on stdin, ON_ERROR_STOP=1; plpgsql ASSERT fails loud)
sql_assert() {
  local db="$1" label="$2" sql out
  sql=$(cat)
  if out=$(printf '%s' "$sql" | docker exec -i "$SCRATCH" psql -U stewards -d "$db" -v ON_ERROR_STOP=1 -q 2>&1); then
    echo "OK: $label"
  else
    die "$label"; printf '%s\n' "$out" | tail -20
  fi
}

# expect_drop_refuse DB LABEL -- plain DROP EXTENSION must fail on the forged-tool dependency
expect_drop_refuse() {
  local out
  out=$(docker exec "$SCRATCH" psql -U stewards -d "$1" -v ON_ERROR_STOP=1 \
        -c "DROP EXTENSION stewards_companion;" 2>&1)
  if [ $? -ne 0 ] && printf '%s' "$out" | grep -q "depends on schema forge"; then
    echo "OK: $2"
  else
    die "$2 -- plain DROP EXTENSION did NOT refuse as expected"; printf '%s\n' "$out" | tail -6
  fi
}

abort() { echo ""; echo "test-extension.sh: FAILED (see FAIL lines above)."; exit 1; }

# =====================================================================
# stage 1: virgin pg + core extension -> CREATE EXTENSION '0.1.0'
# =====================================================================
echo "== stage 1: virgin install at 0.1.0 =="
docker run -d --name "$SCRATCH" \
  -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=scratch -e POSTGRES_DB=stewards \
  "$IMAGE" postgres -c shared_preload_libraries=pg_ai_stewards >/dev/null \
  || { die "docker run $IMAGE"; abort; }

ready=0
for _ in $(seq 1 30); do
  docker exec "$SCRATCH" pg_isready -U stewards -d stewards >/dev/null 2>&1 && { ready=1; break; }
  sleep 2
done
[ "$ready" -eq 1 ] || { die "scratch postgres never became ready (30x2s)"; abort; }

for f in stewards_companion.control stewards_companion--0.1.0.sql \
         stewards_companion--0.1.0--0.2.0.sql stewards_companion--0.2.0.sql; do
  docker cp "$SCRIPT_DIR/$f" "$SCRATCH:$EXTDIR/$f" >/dev/null || die "docker cp $f"
done
[ "$fail" -eq 0 ] || abort

docker exec "$SCRATCH" psql -U stewards -d stewards -v ON_ERROR_STOP=1 -q \
  -c "CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE;" \
  -c "CREATE EXTENSION stewards_companion VERSION '0.1.0';" >/dev/null \
  || { die "CREATE EXTENSION stewards_companion VERSION '0.1.0'"; abort; }

v=$(scalar stewards "SELECT extversion FROM pg_extension WHERE extname='stewards_companion';")
[ "$v" = "0.1.0" ] && echo "OK: stage 1 — stewards_companion 0.1.0 on virgin pg" || { die "extversion '$v' != 0.1.0"; abort; }

# =====================================================================
# stage 2: 0.1.0 smoke (forge + reminders + bell) & steward-tools ABSENT
# =====================================================================
echo "== stage 2: 0.1.0 smoke =="
if docker exec -i "$SCRATCH" psql -U stewards -d stewards -v ON_ERROR_STOP=1 -q \
     < "$PACK_DIR/smoke.sql" >/dev/null 2>&1; then
  echo "OK: stage 2 — forge smoke.sql (happy + inverse + seatbelts)"
else
  die "stage 2 — forge smoke.sql"
fi

sql_assert stewards "stage 2 — reminders/bell/approve + 0.1.0 tool set" <<'SQL'
DO $s2$
DECLARE v jsonb; v_id bigint;
BEGIN
  v := companion.reminder_set(jsonb_build_object('message','drink water','minutes_from_now',30));
  ASSERT (v->>'ok')::boolean, format('reminder_set: %s', v);
  v_id := (v->>'id')::bigint;
  ASSERT (companion.reminder_list('{}'::jsonb)->>'count')::int >= 1, 'reminder_list shows pending';
  ASSERT (companion.reminder_cancel(jsonb_build_object('id', v_id))->>'ok')::boolean, 'reminder_cancel';
  ASSERT companion.reminder_set(jsonb_build_object('message',''))          ? 'error', 'empty message errors';
  ASSERT companion.reminder_set(jsonb_build_object('message','x'))->>'error' LIKE '%minutes_from_now%', 'missing time errors';
  ASSERT companion.reminder_set(jsonb_build_object('message','x','minutes_from_now',-1)) ? 'error', 'negative minutes errors';
  v := companion.companion_bell('{}'::jsonb);
  ASSERT (v ? 'count') AND jsonb_typeof(v->'items')='array', 'companion_bell shape';
  ASSERT companion.companion_approve(jsonb_build_object('work_item_id','00000000-0000-0000-0000-000000000000')) ? 'error', 'approve of missing item errors';
  -- 0.1.0 tool set present ...
  ASSERT (SELECT count(*) FROM stewards.tool_defs
           WHERE name IN ('forge_register','reminder_set','reminder_list','reminder_cancel','companion_bell','companion_approve')
             AND active) = 6, '0.1.0 six tools active';
  -- ... and steward-tools ABSENT at 0.1.0
  ASSERT NOT EXISTS (SELECT 1 FROM stewards.tool_defs
           WHERE name IN ('forge_start','work_item_unstick','model_health','models_health_check')), 'steward-tools tool_defs ABSENT at 0.1.0';
  ASSERT to_regprocedure('companion.forge_start(jsonb)') IS NULL, 'companion.forge_start fn ABSENT at 0.1.0';
  RAISE NOTICE 'stage 2 passed';
END $s2$;
SQL

# =====================================================================
# stage 3: ALTER EXTENSION UPDATE TO '0.2.0' + steward-tools smoke
# =====================================================================
echo "== stage 3: upgrade 0.1.0 -> 0.2.0 =="
docker exec "$SCRATCH" psql -U stewards -d stewards -v ON_ERROR_STOP=1 -q \
  -c "ALTER EXTENSION stewards_companion UPDATE TO '0.2.0';" >/dev/null \
  || die "stage 3 — ALTER EXTENSION UPDATE TO 0.2.0"
v=$(scalar stewards "SELECT extversion FROM pg_extension WHERE extname='stewards_companion';")
[ "$v" = "0.2.0" ] && echo "OK: stage 3 — extversion now 0.2.0" || die "stage 3 — extversion '$v' != 0.2.0"

# reusable 0.2.0 smoke (also used by stage 4). $1 label suffix informational.
smoke_020() {
  sql_assert "$1" "stage $2 — 0.2.0 smoke (tools present, model_health, unstick refusal, rate guard)" <<'SQL'
DO $s3$
DECLARE v jsonb; v_wi uuid; v_have int;
BEGIN
  ASSERT (SELECT count(*) FROM stewards.tool_defs
           WHERE name IN ('forge_start','work_item_unstick','model_health','models_health_check')
             AND active) = 4, 'four steward-tools active at 0.2.0';
  v := companion.model_health('{}'::jsonb);
  ASSERT (v ? 'generated_at') AND jsonb_typeof(v->'models')='array', 'model_health {generated_at, models:[...]}';
  -- unstick refuses a pending (non-failed/awaiting_review) item
  v_wi := stewards.work_item_create('forge', jsonb_build_object('assignment','unstick refusal fixture wish'),
             NULL, 'd2a', NULL, (SELECT id FROM stewards.intents WHERE slug='companion'));
  ASSERT (SELECT status FROM stewards.work_items WHERE id=v_wi) NOT IN ('failed','awaiting_review'), 'fixture item is pending';
  v := companion.work_item_unstick(jsonb_build_object('work_item_id', v_wi::text));
  ASSERT v->>'error' LIKE '%unstick only touches failed or awaiting_review%', format('unstick must refuse: %s', v);
  -- forge_start rate guard: ensure >=5 forge items in the window, then it trips
  SELECT count(*) INTO v_have FROM stewards.work_items
    WHERE pipeline_family='forge' AND created_at > now()-interval '1 hour';
  IF v_have < 5 THEN
    PERFORM companion.forge_start(jsonb_build_object('assignment','rate filler wish number '||g))
      FROM generate_series(1, 5 - v_have) g;
  END IF;
  v := companion.forge_start(jsonb_build_object('assignment','the wish that must be rate-limited now'));
  ASSERT (v ? 'error') AND v->>'error' LIKE '%rate limit%', format('forge_start rate guard must trip: %s', v);
  RAISE NOTICE 'stage % 0.2.0 smoke passed', 'X';
END $s3$;
SQL
}
smoke_020 stewards 3

# =====================================================================
# stage 4: fresh 2nd DB straight to 0.2.0 (default_version)
# =====================================================================
echo "== stage 4: fresh DB straight to 0.2.0 =="
docker exec "$SCRATCH" psql -U stewards -d stewards -q -c "CREATE DATABASE stewards2;" >/dev/null 2>&1 || die "stage 4 — CREATE DATABASE stewards2"
docker exec "$SCRATCH" psql -U stewards -d stewards2 -v ON_ERROR_STOP=1 -q \
  -c "CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE;" \
  -c "CREATE EXTENSION stewards_companion;" >/dev/null \
  || die "stage 4 — CREATE EXTENSION stewards_companion (no version)"
v=$(scalar stewards2 "SELECT extversion FROM pg_extension WHERE extname='stewards_companion';")
[ "$v" = "0.2.0" ] && echo "OK: stage 4 — fresh install lands at default_version 0.2.0" || die "stage 4 — extversion '$v' != 0.2.0"
smoke_020 stewards2 4

# =====================================================================
# stage 5: pg_dump/restore -> reminders row + forged_tools row survive
# =====================================================================
echo "== stage 5: dump/restore survival (config_dump) =="
# seed a durable forged tool (persists into stage 6) + a reminder, on `stewards`
sql_assert stewards "stage 5 — seed forged tool + reminder" <<'SQL'
DO $s5$
DECLARE v jsonb;
BEGIN
  ASSERT (companion.reminder_set(jsonb_build_object('message','survive the dump','minutes_from_now',180))->>'ok')::boolean, 'seed reminder';
  v := forge.forge_register(jsonb_build_object(
        'tool_name','d2a_survivor','description','durable forged fixture',
        'sql','CREATE OR REPLACE FUNCTION forge.d2a_survivor(p_args jsonb) RETURNS jsonb LANGUAGE sql AS $f$ SELECT jsonb_build_object(''ok'',true,''echo'',p_args->''x'') $f$',
        'args_schema','{"type":"object"}'::jsonb, 'test_args','{"x":1}'::jsonb, 'plan_excerpt','d2a survivor'));
  ASSERT (v->>'ok')::boolean, format('forge d2a_survivor: %s', v);
END $s5$;
SQL
docker exec "$SCRATCH" bash -c "pg_dump -U stewards -Fc stewards > //tmp/d2a.dump" 2>/dev/null || die "stage 5 — pg_dump"
docker exec "$SCRATCH" psql -U stewards -d stewards -q -c "CREATE DATABASE stewards_restore;" >/dev/null 2>&1 || die "stage 5 — CREATE DATABASE stewards_restore"
docker exec "$SCRATCH" bash -c "pg_restore -U stewards -d stewards_restore //tmp/d2a.dump" >/dev/null 2>&1 || die "stage 5 — pg_restore (non-fatal warnings ok)"
sql_assert stewards_restore "stage 5 — reminders + forged_tools rows survived dump/restore" <<'SQL'
DO $s5b$
BEGIN
  ASSERT (SELECT extversion FROM pg_extension WHERE extname='stewards_companion')='0.2.0', 'ext restored at 0.2.0';
  ASSERT (SELECT count(*) FROM companion.reminders WHERE message='survive the dump')=1, 'reminders row survived (config_dump)';
  ASSERT (SELECT count(*) FROM forge.forged_tools WHERE tool_name='d2a_survivor')=1, 'forged_tools row survived (config_dump)';
  RAISE NOTICE 'stage 5 passed';
END $s5b$;
SQL

# =====================================================================
# stage 6: uninstall posture — the ratified survivors, made executable
# =====================================================================
echo "== stage 6: uninstall posture (survivors EXACT) =="
# (a) with a forged tool present, plain DROP must REFUSE
expect_drop_refuse stewards "stage 6a — plain DROP refuses while forged tool exists (a feature)"
# (b) companion_uninstall(): allowlist shrinks, tool_defs deactivate, forged tool untouched
sql_assert stewards "stage 6b — companion_uninstall() shrinks allowlist + deactivates pack tool_defs" <<'SQL'
DO $s6a$
DECLARE v jsonb;
BEGIN
  v := companion.companion_uninstall();
  ASSERT (v->>'ok')::boolean, 'uninstall ok';
  ASSERT v->'allowlist_after' = '[]'::jsonb, format('allowlist shrunk to []: %s', v->'allowlist_after');
  ASSERT (v->>'tool_defs_deactivated')::int = 10, format('10 tool_defs deactivated: %s', v->>'tool_defs_deactivated');
  ASSERT stewards.config_get('arc_c_dynamic_write_allowlist') = '[]'::jsonb, 'config allowlist row shrunk';
  ASSERT (SELECT count(*) FROM stewards.tool_defs
           WHERE name IN ('forge_register','reminder_set','reminder_list','reminder_cancel','companion_bell','companion_approve',
                          'forge_start','work_item_unstick','model_health','models_health_check')
             AND active) = 0, 'all 10 pack tool_defs deactivated (not deleted)';
  ASSERT (SELECT active FROM stewards.tool_defs WHERE name='d2a_survivor'), 'forged tool row stays active (operator data)';
END $s6a$;
SQL
# (c) plain DROP STILL refuses (forged tool still present)
expect_drop_refuse stewards "stage 6c — plain DROP still refuses (forged tool still present)"
# (d) DROP EXTENSION CASCADE succeeds (the explicit destroy-forged-work choice)
docker exec "$SCRATCH" psql -U stewards -d stewards -v ON_ERROR_STOP=1 -q \
  -c "DROP EXTENSION stewards_companion CASCADE;" >/dev/null 2>&1 \
  && echo "OK: stage 6d — DROP EXTENSION CASCADE succeeds" || die "stage 6d — DROP EXTENSION CASCADE"
# (e) survivors EXACTLY per posture
sql_assert stewards "stage 6e — survivors EXACT (schemas gone; pipeline+intent kept; tool_defs kept-inactive)" <<'SQL'
DO $s6b$
BEGIN
  ASSERT (SELECT count(*) FROM pg_namespace WHERE nspname IN ('forge','companion'))=0, 'forge+companion schemas dropped (reminders table with them)';
  ASSERT (SELECT count(*) FROM stewards.pipelines WHERE family='forge')=1, 'forge pipeline row KEPT (ledger history)';
  ASSERT (SELECT count(*) FROM stewards.intents WHERE slug='companion')=1, 'companion intent row KEPT';
  ASSERT (SELECT count(*) FROM stewards.tool_defs
           WHERE name IN ('forge_register','reminder_set','reminder_list','reminder_cancel','companion_bell','companion_approve',
                          'forge_start','work_item_unstick','model_health','models_health_check'))=10, '10 pack tool_defs rows KEPT';
  ASSERT (SELECT bool_and(NOT active) FROM stewards.tool_defs
           WHERE name IN ('forge_register','reminder_set','reminder_list','reminder_cancel','companion_bell','companion_approve',
                          'forge_start','work_item_unstick','model_health','models_health_check')), 'all kept pack tool_defs are inactive';
  RAISE NOTICE 'stage 6 passed';
END $s6b$;
SQL

# =====================================================================
# stage 7: catalog parity — loose-SQL path vs extension path
# =====================================================================
echo "== stage 7: catalog parity (loose SQL vs extension) =="
docker exec "$SCRATCH" psql -U stewards -d stewards -q -c "CREATE DATABASE loose;" >/dev/null 2>&1 || die "stage 7 — CREATE DATABASE loose"
docker exec "$SCRATCH" psql -U stewards -d loose -v ON_ERROR_STOP=1 -q \
  -c "CREATE EXTENSION IF NOT EXISTS pg_ai_stewards CASCADE;" >/dev/null || die "stage 7 — core ext on loose"
for f in forge.sql companion.sql steward-tools.sql; do
  docker exec -i "$SCRATCH" psql -U stewards -d loose -v ON_ERROR_STOP=1 -q < "$PACK_DIR/$f" >/dev/null 2>&1 \
    || die "stage 7 — loose apply $f"
done
# Object catalog (functions + table columns) in forge/companion schemas.
# Parity is modulo (1) extension MEMBERSHIP itself and (2) the packaging-only
# companion_uninstall() helper the extension footer adds (absent from loose).
CATALOG_SQL="
SELECT 'FN  '||n.nspname||'.'||p.proname||'('||pg_get_function_arguments(p.oid)||') -> '||pg_get_function_result(p.oid)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname IN ('forge','companion') AND p.proname <> 'companion_uninstall'
UNION ALL
SELECT 'COL '||n.nspname||'.'||c.relname||'.'||a.attname||' '||format_type(a.atttypid,a.atttypmod)
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  JOIN pg_attribute a ON a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped
 WHERE n.nspname IN ('forge','companion') AND c.relkind='r'
 ORDER BY 1;"
cat_loose=$(docker exec "$SCRATCH" psql -U stewards -d loose     -tAc "$CATALOG_SQL" 2>/dev/null | tr -d '\r')
cat_ext=$(docker exec   "$SCRATCH" psql -U stewards -d stewards2 -tAc "$CATALOG_SQL" 2>/dev/null | tr -d '\r')
if [ "$cat_loose" = "$cat_ext" ] && [ -n "$cat_ext" ]; then
  n=$(printf '%s\n' "$cat_ext" | grep -c .)
  echo "OK: stage 7 — catalog PARITY ($n objects identical; modulo membership + companion_uninstall)"
  # sanity: the one expected delta really is only companion_uninstall
  u_loose=$(scalar loose    "SELECT count(*) FROM pg_proc WHERE proname='companion_uninstall';")
  u_ext=$(scalar   stewards2 "SELECT count(*) FROM pg_proc WHERE proname='companion_uninstall';")
  [ "$u_loose" = "0" ] && [ "$u_ext" = "1" ] \
    && echo "OK: stage 7 — companion_uninstall is the ONLY function the extension adds (loose=0, ext=1)" \
    || die "stage 7 — companion_uninstall parity delta unexpected (loose=$u_loose ext=$u_ext)"
else
  die "stage 7 — catalog MISMATCH between loose-SQL and extension paths"
  diff <(printf '%s\n' "$cat_loose") <(printf '%s\n' "$cat_ext") | head -30
fi

# =====================================================================
# stage 8: ship path — the Dockerfile guarded-COPY lands the pack files
# =====================================================================
echo "== stage 8: ship path (Dockerfile guarded COPY) =="
DOCKERFILE="$(cd "$PACK_DIR/../.." && pwd)/extension/Dockerfile"
if grep -q "companion-pack/stewards_companion" "$DOCKERFILE" \
   && grep -q "stewards_companion--\*.sq\[l\]" "$DOCKERFILE"; then
  echo "OK: stage 8 — pack COPY+RUN lines present in extension/Dockerfile"
else
  die "stage 8 — extension/Dockerfile missing the pack ship lines"
fi
# Prove the idiom on the REAL base image: FROM $IMAGE + the same guarded
# COPY+RUN, with pack files staged, then assert they land in the sharedir.
SHIPCTX="$(mktemp -d)"
cp "$SCRIPT_DIR"/stewards_companion.control "$SCRIPT_DIR"/stewards_companion--*.sql "$SHIPCTX/" 2>/dev/null
# guard file guaranteed to exist in this tiny context:
echo "guard" > "$SHIPCTX/guard.txt"
cat > "$SHIPCTX/Dockerfile" <<DOCKER
FROM $IMAGE
COPY guard.txt stewards_companion.contro[l] stewards_companion--*.sq[l] /tmp/companion-pack/
RUN if ls /tmp/companion-pack/stewards_companion* >/dev/null 2>&1; then \
        cp /tmp/companion-pack/stewards_companion* /usr/share/postgresql/18/extension/; \
    fi; rm -rf /tmp/companion-pack
DOCKER
if docker build -t d2a-shippath-test "$SHIPCTX" >/dev/null 2>&1; then
  landed=$(docker run --rm --entrypoint sh d2a-shippath-test -c "ls /usr/share/postgresql/18/extension/stewards_companion* 2>/dev/null | wc -l" | tr -d '\r ')
  [ "$landed" = "4" ] \
    && echo "OK: stage 8 — staged build ships all 4 pack files into the image sharedir" \
    || die "stage 8 — expected 4 pack files in image sharedir, found $landed"
else
  die "stage 8 — ship-path proof image build failed"
fi
rm -rf "$SHIPCTX"

# =====================================================================
echo ""
if [ "$fail" -ne 0 ]; then
  echo "test-extension.sh: FAILED (see FAIL lines above)."
  exit 1
fi
echo "test-extension.sh: ALL STAGES GREEN — stewards_companion is a real,"
echo "installable, upgradable, dump-safe, cleanly-uninstallable extension."
exit 0
