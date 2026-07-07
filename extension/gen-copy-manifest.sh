#!/usr/bin/env bash
# extension/gen-copy-manifest.sh
#
# Generates the Dockerfile's SQL COPY block from the one authoritative
# source of truth: the extension_sql_file!("../NN-*.sql", ...) macro calls
# in extension/src/lib.rs. Kills the forgotten-COPY failure class — the
# Dockerfile used to hand-enumerate every chain file in a giant multi-line
# COPY, and forgetting to add a new line there was a builder COMPILE error
# (extension_sql_file! reads the file at build time via include_str!) whose
# non-zero exit a piped `docker compose build | tail` silently swallowed,
# leaving a stale image running for a week before tests/virgin-smoke.sql
# caught it (see the 102-war-game.sql incident, 2026-07-06). Runs on the
# HOST (dev machine) and in CI — same script, same output, both places.
#
# Usage:
#   extension/gen-copy-manifest.sh            regenerate extension/sql-manifest.dockerfile
#                                              AND rewrite the marked block in Dockerfile.
#                                              Run this after adding/removing a chain file.
#   extension/gen-copy-manifest.sh --check    exit 1 if the Dockerfile's generated block
#                                              would differ from what lib.rs demands (no
#                                              writes). Run this — UNPIPED — before
#                                              `docker compose build` and in CI. See the
#                                              build instructions at the top of
#                                              tests/README.md.
#
# Also invoked automatically by `stewards-cli update` (cmd/stewards-cli/update.go,
# step "gen-copy-manifest --check") as a pre-build drift gate.
#
# What it does:
#   1. Parses every extension_sql_file!("../<file>", ...) path out of
#      src/lib.rs — the ONLY authoritative list. lib.rs decides what's
#      compiled into the extension; the Dockerfile's only job is to ship
#      those bytes into the build context.
#   2. Verifies every referenced file exists on disk. A macro pointing at a
#      file that isn't there is a real bug (or a stale rename) — exit 1,
#      name it, don't paper over it.
#   3. Emits the sorted (`sort -V`, numeric-aware: 9 < 10 < 15a < 15b < 16 <
#      ... < 99 < 100) COPY block to extension/sql-manifest.dockerfile — a
#      readable, standalone, generated artifact for humans/diffing. Docker
#      itself can't `COPY` the contents of another file's instructions in,
#      so this file is documentation/diff-fodder, not something the
#      Dockerfile references directly.
#   4. Rewrites ONLY the region of extension/Dockerfile between
#        # ===== GENERATED SQL COPY BLOCK (gen-copy-manifest.sh) =====
#        # ===== END GENERATED =====
#      with the same COPY lines, one file per line — the same
#      collision-avoidance discipline the last several parallel-landing
#      chain files (100-106) already used ad hoc is now the rule, generated,
#      for every file. Everything outside the two markers is preserved
#      byte-for-byte, including comments and the two build stages.
#
# Bootstrap note: the markers must already exist (as an empty pair) in
# Dockerfile before the first run. This is a one-time hand edit; the script
# refuses to guess where a hand-written COPY region starts/ends.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_RS="$SCRIPT_DIR/src/lib.rs"
DOCKERFILE="$SCRIPT_DIR/Dockerfile"
MANIFEST="$SCRIPT_DIR/sql-manifest.dockerfile"
START_MARKER="# ===== GENERATED SQL COPY BLOCK (gen-copy-manifest.sh) ====="
END_MARKER="# ===== END GENERATED ====="

CHECK=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    *) echo "gen-copy-manifest.sh: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[ -f "$LIB_RS" ] || { echo "FATAL: $LIB_RS not found" >&2; exit 2; }
[ -f "$DOCKERFILE" ] || { echo "FATAL: $DOCKERFILE not found" >&2; exit 2; }

TMP_NEW="$(mktemp)"
TMP_DIFF="$(mktemp)"
cleanup() { rm -f "$TMP_NEW" "$TMP_DIFF"; }
trap cleanup EXIT

# ---- 1. Parse the authoritative list out of lib.rs ----
mapfile -t FILES < <(grep -oE '"\.\./[A-Za-z0-9_.-]+\.sql"' "$LIB_RS" | tr -d '"' | sed 's#^\.\./##')
[ "${#FILES[@]}" -gt 0 ] || { echo "FATAL: no extension_sql_file! paths parsed from $LIB_RS" >&2; exit 2; }

# ---- 2. Every referenced file must exist on disk ----
MISSING=()
for f in "${FILES[@]}"; do
  [ -f "$SCRIPT_DIR/$f" ] || MISSING+=("$f")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "FATAL: extension_sql_file! in lib.rs references file(s) that do not exist on disk:" >&2
  for f in "${MISSING[@]}"; do echo "    $f" >&2; done
  exit 1
fi

# ---- 3. Sorted (numeric-aware) COPY block ----
mapfile -t SORTED < <(printf '%s\n' "${FILES[@]}" | sort -V)

# In --check mode, build the manifest at a temp path so --check truly makes
# NO writes — otherwise a stale state would silently update sql-manifest.dockerfile
# while leaving Dockerfile stale, and a later `git add -A` could commit the two
# out of agreement.
if [ "$CHECK" -eq 1 ]; then
  MANIFEST="$(mktemp)"
  trap 'cleanup; rm -f "$MANIFEST"' EXIT
fi

{
  echo "# extension/sql-manifest.dockerfile — GENERATED by gen-copy-manifest.sh."
  echo "# DO NOT EDIT BY HAND. Source of truth: extension_sql_file! calls in src/lib.rs."
  echo "#"
  echo "# This is a readable standalone artifact (for humans/diffing) — Docker can't"
  echo "# COPY the contents of another file's instructions in, so the SAME block is"
  echo "# also written into extension/Dockerfile between the GENERATED markers; that"
  echo "# copy is what the build actually reads."
  for f in "${SORTED[@]}"; do
    echo "COPY $f ./"
  done
} > "$MANIFEST"

# ---- 4. Rewrite (or check) the marked region of the Dockerfile ----
if ! grep -qF "$START_MARKER" "$DOCKERFILE" || ! grep -qF "$END_MARKER" "$DOCKERFILE"; then
  echo "FATAL: $DOCKERFILE is missing the GENERATED marker pair:" >&2
  echo "    $START_MARKER" >&2
  echo "    $END_MARKER" >&2
  echo "Add them once, by hand (empty block between them), then re-run." >&2
  exit 2
fi

awk -v start="$START_MARKER" -v end="$END_MARKER" -v manifest="$MANIFEST" '
  $0 == start { print; in_block=1
    while ((getline line < manifest) > 0) { if (line !~ /^#/) print line }
    close(manifest)
    next
  }
  $0 == end   { in_block=0; print; next }
  in_block    { next }
  { print }
' "$DOCKERFILE" > "$TMP_NEW"

if [ "$CHECK" -eq 1 ]; then
  if diff -u "$DOCKERFILE" "$TMP_NEW" > "$TMP_DIFF" 2>&1; then
    echo "gen-copy-manifest.sh --check: Dockerfile COPY block is up to date (${#SORTED[@]} files)."
    exit 0
  else
    echo "gen-copy-manifest.sh --check: Dockerfile COPY block is STALE. Diff:" >&2
    cat "$TMP_DIFF" >&2
    echo "" >&2
    echo "Run extension/gen-copy-manifest.sh (no flags) to regenerate, then commit both" >&2
    echo "extension/Dockerfile and extension/sql-manifest.dockerfile." >&2
    exit 1
  fi
fi

mv "$TMP_NEW" "$DOCKERFILE"
echo "gen-copy-manifest.sh: regenerated $MANIFEST and $DOCKERFILE (${#SORTED[@]} files)."
