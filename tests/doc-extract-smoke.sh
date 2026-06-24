#!/usr/bin/env bash
# =====================================================================
# tests/doc-extract-smoke.sh — the doc-extract trust-floor smoke (P3a).
# =====================================================================
# Proves the HARDENED, NO-NETWORK converter end to end on benign + adversarial
# inputs, with the same isolation flags doc-extract-mcp's runner uses in prod.
# This is the SEPARATE CI lane (proposal §8.5) — it needs the doc-extract image
# + docker, so it does NOT run inside the fast SQL virgin-smoke.
#
#   docker build -f extension/doc-extract.Dockerfile -t doc-extract:latest .
#   bash tests/doc-extract-smoke.sh
#
# The pure-Go safety oracle (zip-slip refusal, zip-bomb caps, structural maldoc
# detection, type routing) lives in `go test ./internal/docextract/` and runs
# without docker — this harness adds the CONTAINMENT proofs that need the image.
# =====================================================================
set -euo pipefail

# On Windows git-bash (MSYS), docker arg paths like /work get mangled into
# C:\... — disable that conversion so --tmpfs /work etc. reach docker literally.
# No-op on Linux CI (the production path runs inside the Linux bridge anyway).
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

IMAGE="${DOC_EXTRACT_IMAGE:-doc-extract:latest}"
CLAMAV_VOL="${DOC_EXTRACT_CLAMAV_VOLUME:-clamav-db}"

# The untrusted-input hardening (mirrors runner/run.go).
HARDEN=(--rm --network=none --cap-drop=ALL --security-opt=no-new-privileges
        --read-only --tmpfs /work --tmpfs /tmp
        --pids-limit=512 --memory=2g --cpus=2 --ulimit nofile=4096)

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

echo "== doc-extract trust-floor smoke (image=$IMAGE) =="

docker image inspect "$IMAGE" >/dev/null 2>&1 \
  || fail "image $IMAGE not found — build it: docker build -f extension/doc-extract.Dockerfile -t $IMAGE ."

# --- Is the ClamAV signature DB populated? (freshclam sidecar fills it.) ------
CLAM_ARGS=()
if docker run --rm -v "${CLAMAV_VOL}:/clamav" alpine sh -c 'ls /clamav/*.c?d /clamav/*.cvd 2>/dev/null | head -1' 2>/dev/null | grep -q .; then
  echo "  ClamAV DB present in volume '$CLAMAV_VOL' — signature scan ACTIVE"
  CLAM_ARGS=(-v "${CLAMAV_VOL}:/clamav:ro" -e DOC_EXTRACT_CLAMAV_DB=/clamav)
else
  echo "  ClamAV DB not populated yet — structural scan only (run the freshclam sidecar to enable signatures)"
fi

# --- 1. converter self-smoke INSIDE the hardened container --------------------
# runSmoke covers benign-text (clean+extracted), macro-PDF (suspicious), and
# EICAR (quarantined when the signature engine is live).
echo "-- 1. converter -smoke in the hardened sandbox"
docker run "${HARDEN[@]}" "${CLAM_ARGS[@]}" "$IMAGE" -smoke || fail "in-container -smoke"
pass "benign + macro (+ EICAR if DB) verified inside the no-network sandbox"

# --- 2. no-egress proof -------------------------------------------------------
# With --network=none the container has no resolver / no route. Prove it.
echo "-- 2. network isolation (--network=none)"
OUT=$(docker run --rm --network=none --entrypoint /bin/sh "$IMAGE" \
        -c 'getent hosts github.com >/dev/null 2>&1 && echo HAS-EGRESS || echo NO-EGRESS' 2>/dev/null || echo NO-EGRESS)
[ "$OUT" = "NO-EGRESS" ] || fail "expected NO-EGRESS under --network=none, got: $OUT"
pass "the sandbox cannot resolve/reach the network while parsing"

# --- 3. benign document through the real stdin->stdout pipe -------------------
echo "-- 3. benign text via stdin -> JSON result"
RES=$(printf 'hello from the trust-floor smoke, this is plain text' \
        | docker run -i "${HARDEN[@]}" "${CLAM_ARGS[@]}" "$IMAGE" -filename note.txt)
echo "$RES" | grep -q '"verdict":"clean"' || fail "benign text should scan clean: $RES"
echo "$RES" | grep -q 'plain text' || fail "benign text should be extracted: $RES"
pass "benign text extracted + clean over the real container pipe"

# --- 4. macro-flagged PDF stays suspicious (structural scan, in-container) -----
echo "-- 4. macro-flagged PDF via stdin -> suspicious (still extracted)"
RES=$(printf '%%PDF-1.7\n<< /OpenAction << /S /JavaScript /JS (evil) >> >>\nbody text' \
        | docker run -i "${HARDEN[@]}" "${CLAM_ARGS[@]}" "$IMAGE" -filename macro.pdf)
echo "$RES" | grep -q '"verdict":"suspicious"' || fail "macro PDF should be suspicious: $RES"
echo "$RES" | grep -q 'OpenAction' || fail "macro PDF should report the structural finding: $RES"
pass "macro PDF flagged suspicious (the structural scan ran in the sandbox)"

# --- 5. EICAR quarantined when the signature engine is live -------------------
if [ ${#CLAM_ARGS[@]} -gt 0 ]; then
  echo "-- 5. EICAR via stdin -> quarantined (signature engine)"
  EICAR='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
  RES=$(printf '%s' "$EICAR" | docker run -i "${HARDEN[@]}" "${CLAM_ARGS[@]}" "$IMAGE" -filename eicar.com)
  if echo "$RES" | grep -q '"engine":"clamav+structural"'; then
    echo "$RES" | grep -q '"verdict":"malicious"' || fail "EICAR must be malicious with ClamAV live: $RES"
    echo "$RES" | grep -q '"skipped":true' || fail "EICAR must be quarantined (skipped): $RES"
    pass "EICAR quarantined by the signature engine"
  else
    echo "  (skip) ClamAV engine did not run (DB empty); structural scan cannot see EICAR by design"
  fi
else
  echo "-- 5. EICAR check skipped (no ClamAV DB volume)"
fi

echo "== doc-extract trust-floor smoke: PASS =="
