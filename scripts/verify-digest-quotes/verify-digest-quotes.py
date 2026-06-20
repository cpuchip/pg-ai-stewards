#!/usr/bin/env python3
"""verify-digest-quotes — a quote oracle for the autonomous digesters (v1).

Born 2026-06-20 from the autonomous-doc review: the book/video digesters put
quotation marks around source text with NO verification. A local model reading a
book and quoting it can confabulate — a fabricated quote is "a lie that looks
like truth" (covenant: read_before_quoting). This is the deterministic detector:
for each quoted span in a digest, check that the span actually appears in the
SOURCE the work item read (the Gutenberg full text for a book; the stored
transcript for a video). Build-the-oracle-first — the same move the Webster walk
should have made (scripts/verify-quotes).

  OK     — the quote is verbatim-enough in the source (substring or fuzzy >= THRESH)
  FLAG   — the quote is NOT in the source (likely confabulated or heavily paraphrased
           inside quotation marks)
  SKIP   — no source available to check against (book has no source_url, or a video
           has no stored transcript) — reported, not failed

Only the QUOTED spans are checked. Non-quoted factual claims (chapter names,
dates, "Maxwell cited it six times") are a separate, judgment-layer problem — the
critique stage's job, not this oracle's.

Source of truth is the LIVE substrate DB (read-only) via `docker exec psql`, plus
Project Gutenberg for book full text (cached under .cache/, gitignored).

Usage:
  python verify-digest-quotes.py book-the-iliad           # one doc by slug
  python verify-digest-quotes.py --all-books              # every project=books doc
  python verify-digest-quotes.py --all-videos             # every yt-* doc
  python verify-digest-quotes.py --all                    # books + videos
Options:
  --container NAME   (default: stewards-oss-pg)
  --min-len N        minimum quote length to check, post-normalize (default 24)
  --threshold R      fuzzy match ratio to accept (default 0.82)
  --verbose          show OK quotes too
Exit: 0 if no FLAG, else 1.
"""
import sys, os, re, subprocess, urllib.request
from difflib import SequenceMatcher

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
CONTAINER = "stewards-oss-pg"
MIN_LEN = 24
THRESHOLD = 0.82
VERBOSE = False
UA = "pg-ai-stewards-verify-digest-quotes/1.0 (quote audit)"


def db(sql):
    """Run read-only SQL in the substrate container, return stdout (tab-separated, -tA)."""
    out = subprocess.run(
        ["docker", "exec", "-i", CONTAINER, "psql", "-U", "stewards", "-d", "stewards", "-tAc", sql],
        capture_output=True, text=True, encoding="utf-8",
    )
    if out.returncode != 0:
        sys.stderr.write(f"db error: {out.stderr}\n")
        sys.exit(2)
    return out.stdout


def norm(s):
    s = (s or "").lower().replace("’", "'").replace("‘", "'")
    s = s.replace("“", '"').replace("”", '"').replace("—", "-").replace("–", "-")
    s = re.sub(r"[^a-z0-9 ]+", " ", s)
    return re.sub(r"\s+", " ", s).strip()


def extract_quotes(body):
    """Pull double-quoted spans (straight or curly), normalized, deduped, long enough."""
    spans = re.findall(r'"([^"]{1,600})"', body) + re.findall(r"“([^”]{1,600})”", body)
    out, seen = [], set()
    for raw in spans:
        n = norm(raw)
        if len(n) < MIN_LEN:
            continue
        if n in seen:
            continue
        seen.add(n)
        out.append((raw.strip(), n))
    return out


def fuzzy_in(needle, haystack):
    """Best contiguous-match ratio of needle within haystack (windowed)."""
    if needle in haystack:
        return 1.0
    best, n = 0.0, len(needle)
    # slide a window ~the needle length across the haystack; coarse step for speed
    step = max(1, n // 4)
    for i in range(0, max(1, len(haystack) - n), step):
        r = SequenceMatcher(None, needle, haystack[i:i + n + 20]).ratio()
        if r > best:
            best = r
            if best >= 0.99:
                break
    return best


def verify(quote_norm, source_norm):
    """An elided quote ('a ... b') passes only if every fragment is present in order."""
    frags = [f.strip() for f in re.split(r"\s+\.\.\.\s+|\s+…\s+", quote_norm) if len(f.strip()) >= 10]
    if len(frags) > 1:
        pos, ok = 0, True
        for f in frags:
            idx = source_norm.find(f, pos)
            if idx < 0:
                ok = False
                break
            pos = idx + len(f)
        return (1.0 if ok else fuzzy_in(quote_norm, source_norm))
    return fuzzy_in(quote_norm, source_norm)


def gutenberg_text(source_url):
    """Resolve a gutenberg.org/ebooks/<id> URL to plain text; cache locally."""
    m = re.search(r"/ebooks/(\d+)", source_url) or re.search(r"/(\d+)(?:[/.]|$)", source_url)
    if not m:
        return None
    gid = m.group(1)
    os.makedirs(CACHE, exist_ok=True)
    cached = os.path.join(CACHE, f"gutenberg-{gid}.txt")
    if os.path.exists(cached):
        return open(cached, encoding="utf-8", errors="ignore").read()
    for url in (f"https://www.gutenberg.org/cache/epub/{gid}/pg{gid}.txt",
                f"https://www.gutenberg.org/files/{gid}/{gid}-0.txt",
                f"https://www.gutenberg.org/files/{gid}/{gid}.txt"):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            txt = urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "ignore")
            if len(txt) > 1000:
                open(cached, "w", encoding="utf-8").write(txt)
                return txt
        except Exception:
            continue
    return None


def book_source(slug):
    bookslug = slug[len("book-"):]
    url = db(f"SELECT coalesce(source_url,'') FROM stewards.book_shelf WHERE slug = '{bookslug}'").strip()
    if not url:
        return None
    return gutenberg_text(url)


def video_source(slug):
    vid = slug[len("yt-"):]
    txt = db(
        "SELECT string_agg(text, ' ' ORDER BY start_seconds) "
        f"FROM stewards.yt_transcript_segments WHERE video_id = '{vid}'"
    ).strip()
    return txt or None


def audit(slug):
    body = db(f"SELECT body FROM stewards.docs WHERE slug = '{slug}'")
    if not body.strip():
        print(f"  ?? {slug}: no such doc")
        return None
    quotes = extract_quotes(body)
    if not quotes:
        if VERBOSE:
            print(f"  -- {slug}: no quotes to check")
        return (slug, 0, 0, 0)  # checked, flagged, skipped
    source = book_source(slug) if slug.startswith("book-") else video_source(slug) if slug.startswith("yt-") else None
    if not source:
        print(f"  SKIP {slug}: no source to verify against ({len(quotes)} quotes unchecked)")
        return (slug, 0, 0, len(quotes))
    src_n = norm(source)
    flagged = 0
    print(f"  {slug}: {len(quotes)} quotes")
    for raw, qn in quotes:
        r = verify(qn, src_n)
        if r >= THRESHOLD:
            if VERBOSE:
                print(f"      OK   ({r:.2f}) {raw[:70]}")
        else:
            flagged += 1
            print(f"      FLAG ({r:.2f}) {raw[:90]}")
    return (slug, len(quotes), flagged, 0)


def main():
    global CONTAINER, MIN_LEN, THRESHOLD, VERBOSE
    args = sys.argv[1:]
    slugs, i = [], 0
    mode = None
    while i < len(args):
        a = args[i]
        if a == "--container": CONTAINER = args[i + 1]; i += 2; continue
        if a == "--min-len": MIN_LEN = int(args[i + 1]); i += 2; continue
        if a == "--threshold": THRESHOLD = float(args[i + 1]); i += 2; continue
        if a == "--verbose": VERBOSE = True; i += 1; continue
        if a in ("--all-books", "--all-videos", "--all"): mode = a; i += 1; continue
        slugs.append(a); i += 1
    if mode == "--all-books" or mode == "--all":
        slugs += [s for s in db("SELECT slug FROM stewards.docs WHERE slug LIKE 'book-%' ORDER BY slug").split() if s]
    if mode == "--all-videos" or mode == "--all":
        slugs += [s for s in db("SELECT slug FROM stewards.docs WHERE slug LIKE 'yt-%' ORDER BY slug").split() if s]
    if not slugs:
        print(__doc__)
        sys.exit(0)

    print(f"verify-digest-quotes — {len(slugs)} doc(s), threshold={THRESHOLD}, min-len={MIN_LEN}\n")
    tot_q = tot_f = tot_s = 0
    flagged_docs = []
    for slug in slugs:
        res = audit(slug)
        if res:
            _, q, f, s = res
            tot_q += q; tot_f += f; tot_s += s
            if f:
                flagged_docs.append((slug, f))
    print(f"\n== {tot_q} quotes checked · {tot_f} FLAGGED · {tot_s} unchecked (no source) ==")
    if flagged_docs:
        print("FLAGGED docs:")
        for slug, f in flagged_docs:
            print(f"  {slug}: {f}")
    sys.exit(1 if tot_f else 0)


if __name__ == "__main__":
    main()
