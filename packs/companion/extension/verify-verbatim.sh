#!/usr/bin/env bash
# packs/companion/extension/verify-verbatim.sh — the BLIND CHECK
# (constitution #2: SQL content moves VERBATIM, byte-identical
# concatenation only). This is how the foreman verifies the scaffold
# worker without reading the generated files: it makes no assumption
# about HOW the shipped --X.sql files were built. For each one it:
#   1. confirms the required psql-guard line is present, exactly,
#      as line 1;
#   2. strips that guard line, the delimited PACKAGING footer (the
#      extension-only pg_extension_config_dump + companion_uninstall block,
#      between `-- ===== PACKAGING (extension-only) =====` and
#      `-- ===== END PACKAGING =====` — the AMENDED verbatim principle,
#      D2A constitution #3), and every allowed
#      `-- >>> from packs/companion/<name>.sql` header line, wherever
#      they occur;
#   3. diffs what remains against a straight concatenation of the
#      declared source packs/*.sql files, in the declared order, with
#      NO separators — i.e. exactly what a byte-identical concatenation
#      must equal;
#   4. separately confirms a header line exists for every declared
#      source (stripping is lenient about WHERE headers are, this
#      catches a silently-omitted one).
#
# The comparison runs in Python, not grep/sed/awk: this repo's pack SQL
# has mixed line endings (forge.sql is CRLF on disk; companion.sql and
# steward-tools.sql are LF — see git history/.gitattributes drift), and
# on this Git-Bash/MSYS toolchain grep -v, sed, AND awk all silently
# normalize CRLF -> LF on any line they pass through, which would make
# "byte-identical" untestable with those tools (confirmed empirically
# while building this script — every one of them dropped 100% of the CR
# bytes). Python's binary-mode read + bytes.split(b"\n") preserves
# exactly the bytes that were there. Exit 0 only if every file passes
# every check.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # packs/companion/extension
PACK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"                     # packs/companion

python3 - "$SCRIPT_DIR" "$PACK_DIR" <<'PYEOF'
import sys
import difflib
import pathlib

script_dir = pathlib.Path(sys.argv[1])
pack_dir = pathlib.Path(sys.argv[2])

# The psql guard differs by script kind: full install scripts point at
# CREATE EXTENSION, the update script at ALTER EXTENSION ... UPDATE (the
# convention: the guard names the command that legitimately loads THIS file).
CREATE_GUARD = b'\\echo Use "CREATE EXTENSION stewards_companion" to load this file. \\quit\n'
ALTER_GUARD  = b'\\echo Use "ALTER EXTENSION stewards_companion UPDATE" to load this file. \\quit\n'

# The PACKAGING footer (extension-only statements: pg_extension_config_dump
# + companion_uninstall) is delimited by these markers and stripped whole
# before the byte-compare — the AMENDED verbatim principle (D2A constitution
# #3): extension scripts = verbatim pack SQL + a clearly-delimited footer.
FOOTER_START = b"-- ===== PACKAGING (extension-only) ====="
FOOTER_END   = b"-- ===== END PACKAGING ====="

def header(name):
    return ("-- >>> from packs/companion/%s" % name).encode("utf-8")

CHECKS = [
    ("stewards_companion--0.1.0.sql", ["forge.sql", "companion.sql"], CREATE_GUARD),
    ("stewards_companion--0.1.0--0.2.0.sql", ["steward-tools.sql"], ALTER_GUARD),
    ("stewards_companion--0.2.0.sql", ["forge.sql", "companion.sql", "steward-tools.sql"], CREATE_GUARD),
]

fail = False

for target, sources, guard in CHECKS:
    actual_path = script_dir / target
    if not actual_path.exists():
        print("FAIL: %s does not exist" % target)
        fail = True
        continue
    raw = actual_path.read_bytes()

    # 1. the guard line must be present, exactly, as line 1.
    first_nl = raw.find(b"\n")
    first_line = raw[: first_nl + 1] if first_nl != -1 else raw
    if first_line != guard:
        print("FAIL: %s -- line 1 is not the expected psql guard" % target)
        print("  got:      %r" % first_line)
        print("  expected: %r" % guard)
        fail = True
        rest = raw[first_nl + 1 :] if first_nl != -1 else b""
    else:
        rest = raw[len(guard):]

    # 1b. strip the PACKAGING footer whole (marker line through EOF). The
    #     newline that PRECEDES the start marker belongs to the last source's
    #     verbatim content, so keep it; drop everything from the marker on.
    fidx = rest.find(b"\n" + FOOTER_START)
    if fidx != -1:
        footer_region = rest[fidx + 1:]
        if FOOTER_END not in footer_region:
            print("FAIL: %s -- PACKAGING footer has a start marker but no END marker" % target)
            fail = True
        rest = rest[: fidx + 1]
    else:
        # A footer is expected on every shipped script; its absence is a bug
        # (constitution #3 requires the config_dump + companion_uninstall).
        print("FAIL: %s -- missing the PACKAGING footer (expected %r)" % (target, FOOTER_START))
        fail = True

    # 2. every declared source must have its header line present, literally.
    for src in sources:
        if header(src) not in raw:
            print("FAIL: %s -- missing header line for %s" % (target, src))
            fail = True

    # 3. strip every header line, wherever it occurs (whole line only).
    #    Split on b"\n" ONLY (never treat b"\r\n" as the separator) so any
    #    b"\r" that belongs to the surrounding source content is preserved
    #    on every kept line -- it is never touched, only used (stripped
    #    off a COPY) to test whether a line IS a header line.
    lines = rest.split(b"\n")
    header_set = {header(src) for src in sources}
    stripped_lines = [ln for ln in lines if ln.rstrip(b"\r") not in header_set]
    stripped = b"\n".join(stripped_lines)

    # 4. raw concatenation of the declared sources, byte for byte, no
    #    separators -- this is what "verbatim" means.
    expected = b"".join((pack_dir / src).read_bytes() for src in sources)

    if stripped != expected:
        print("FAIL: %s -- content (after stripping guard/header lines) is not" % target)
        print("  byte-identical to the concatenation of: %s" % ", ".join(sources))
        a = expected.decode("utf-8", "replace").splitlines(keepends=True)
        b = stripped.decode("utf-8", "replace").splitlines(keepends=True)
        diff_lines = list(difflib.unified_diff(a, b, "expected", "actual"))
        for line in diff_lines[:40]:
            print("  " + line.rstrip("\n"))
        if len(diff_lines) > 40:
            print("  ... (%d more diff lines)" % (len(diff_lines) - 40))
        fail = True
    else:
        print("OK: %s -- verbatim against %s" % (target, ", ".join(sources)))

print("")
if fail:
    print("VERBATIM CHECK FAILED -- see FAIL lines above.")
    sys.exit(1)
else:
    print("VERBATIM OK: all extension SQL files are byte-identical concatenations")
    print("of their pack sources (guard + header lines + the delimited PACKAGING")
    print("footer are the only additions).")
    sys.exit(0)
PYEOF
exit $?
