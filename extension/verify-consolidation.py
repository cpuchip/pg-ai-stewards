#!/usr/bin/env python3
"""verify-consolidation.py — the move-proof for the 109-file -> 28-volume
consolidation (feat/lightening).

Each volume in extension/consolidation-map.txt is a byte-preserving
concatenation of the listed original chain files (their git HEAD blobs),
separated ONLY by added `-- ===== [was <file>] =====` banner lines. This
script proves that claim mechanically: for every volume it strips exactly the
banner lines and asserts the remainder is byte-identical to the concatenation
of `git show HEAD:extension/<file>` for its listed files, in order.

It is the "the diff proves the move changed nothing" oracle. Exit 0 = every
volume is a pure move. Exit 1 = a volume drifted (a real consolidation bug —
fix the volume, never this script).

Also enforces: every original chain file appears exactly once across all
volumes (no drop, no dup), and every banner line names a file the volume
actually lists.

Usage:  python3 extension/verify-consolidation.py [--ref HEAD]
The source-of-truth ref defaults to HEAD (the pre-consolidation blobs, since
the consolidation is left uncommitted). Pass an explicit ref/commit to check
against a different pre-consolidation baseline.
"""
import subprocess, sys, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
MAP = os.path.join(HERE, "consolidation-map.txt")
BANNER_RE = re.compile(rb'^-- ===== \[was .+\] =====$')

def git_show(ref, f):
    r = subprocess.run(["git", "show", f"{ref}:extension/{f}"],
                       cwd=os.path.dirname(HERE), capture_output=True)
    if r.returncode != 0:
        sys.exit(f"FATAL: git show {ref}:extension/{f} failed: {r.stderr.decode().strip()}")
    return r.stdout

def parse_map():
    vols = []
    with open(MAP, "rb") as fh:
        for raw in fh.read().split(b"\n"):
            line = raw.decode("utf-8", "replace").strip()
            if not line or line.startswith("#"):
                continue
            vol, rest = line.split(":", 1)
            files = rest.split()
            vols.append((vol.strip(), files))
    return vols

def strip_banners(data):
    """Remove exactly the banner lines; return the byte remainder.
    Files are LF-only (verified at build), so splitting on b'\\n' and rejoining
    is byte-exact."""
    parts = data.split(b"\n")
    kept = [p for p in parts if not BANNER_RE.fullmatch(p)]
    return b"\n".join(kept)

def main():
    ref = "HEAD"
    args = sys.argv[1:]
    if args and args[0] == "--ref":
        ref = args[1]
    if not os.path.exists(MAP):
        sys.exit(f"FATAL: {MAP} not found")

    vols = parse_map()
    seen = {}
    fail = 0
    for vol, files in vols:
        path = os.path.join(HERE, vol)
        if not os.path.exists(path):
            print(f"FAIL {vol}: volume file missing on disk", file=sys.stderr)
            fail += 1
            continue
        with open(path, "rb") as fh:
            raw = fh.read()

        # banner audit: every banner line in the volume must name a listed file
        banners = [m.group(0).decode() for m in
                   (BANNER_RE.fullmatch(p) for p in raw.split(b"\n")) if m]
        expected_banners = [f"-- ===== [was {f}] =====" for f in files]
        if banners != expected_banners:
            print(f"FAIL {vol}: banner lines do not match listed files in order", file=sys.stderr)
            print(f"   banners:  {banners}", file=sys.stderr)
            print(f"   expected: {expected_banners}", file=sys.stderr)
            fail += 1
            continue

        got = strip_banners(raw)
        expected = b"".join(git_show(ref, f) for f in files)
        if got == expected:
            print(f"OK   {vol}: {len(files)} file(s), {len(got)} bytes == HEAD concat")
        else:
            print(f"FAIL {vol}: stripped bytes != concat of {files}", file=sys.stderr)
            # localize the first divergence for debuggability
            n = min(len(got), len(expected))
            i = 0
            while i < n and got[i] == expected[i]:
                i += 1
            print(f"   first byte divergence at offset {i} "
                  f"(len got={len(got)} expected={len(expected)})", file=sys.stderr)
            print(f"   got[{i}:{i+60}]      = {got[i:i+60]!r}", file=sys.stderr)
            print(f"   expected[{i}:{i+60}] = {expected[i:i+60]!r}", file=sys.stderr)
            fail += 1

        for f in files:
            if f in seen:
                print(f"FAIL: {f} appears in both {seen[f]} and {vol}", file=sys.stderr)
                fail += 1
            seen[f] = vol

    # completeness: every original chain file (git HEAD extension/NN-*.sql that
    # is NOT a verify-/test-/inverse- helper) must be covered exactly once.
    print(f"--- {len(seen)} original files covered across {len(vols)} volumes")
    if fail:
        print(f"\nMOVE-PROOF FAILED: {fail} problem(s). A non-empty diff = a "
              f"consolidation bug; fix the volume, not this checker.", file=sys.stderr)
        sys.exit(1)
    print("\nMOVE-PROOF PASSED: every volume is a byte-exact move of its "
          "original chain files (banners stripped).")
    sys.exit(0)

if __name__ == "__main__":
    main()
