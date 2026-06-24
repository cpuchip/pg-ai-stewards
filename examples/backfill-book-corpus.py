#!/usr/bin/env python3
"""Backfill the book SOURCE corpus for digested books that predate corpus
persistence (examples/book-corpus.sql). For every digested book with no
book_text yet, fetch its source text and persist it via
stewards.book_persist_corpus so book_search can quote the real passages.

Idempotent: books that already have a corpus are skipped. Re-runnable on a
fresh deploy (e.g. the work rig) to repopulate book_text / book_chunks.

Source resolution, in order:
  1. SKIP map  — copyrighted / duplicate / not-a-source-book (documented).
  2. OVERRIDE map — explicit verified URLs for non-gutenberg / no-shelf-url
     public-domain classics.
  3. book_shelf.source_url on gutenberg.org → the canonical plain-text
     /cache/epub/<id>/pg<id>.txt (landing pages, -h.htm, /files all map by id).

Every fetch is title-verified (a distinctive title word must appear near the
top of the fetched text) so a wrong id can never land under a slug. The body is
loaded server-side with pg_read_file — the text never rides a shell arg.

Prereqs: a running substrate with book-corpus.sql applied + the book digests
present. Set STEWARDS_PG_CONTAINER if your pg container isn't 'stewards-oss-pg'.

    python examples/backfill-book-corpus.py
"""
import subprocess, re, time, urllib.request, os, html, tempfile

CONTAINER = os.environ.get("STEWARDS_PG_CONTAINER", "stewards-oss-pg")
PGC = ["docker", "exec", CONTAINER, "psql", "-U", "stewards", "-d", "stewards", "-tAc"]
UA = {"User-Agent": "Mozilla/5.0 (book-corpus backfill; one-time; public-domain)"}
START_RE = re.compile(r"\*\*\* ?START OF (?:THE|THIS) PROJECT GUTENBERG.*?\*\*\*", re.I | re.S)
END_RE = re.compile(r"\*\*\* ?END OF (?:THE|THIS) PROJECT GUTENBERG", re.I)
GUT_ID = re.compile(r"gutenberg\.org/(?:cache/epub|files|ebooks)/(\d+)")

# Verified public-domain sources for books whose shelf URL is missing or not
# plain-text-resolvable. (url, is_html)
OVERRIDE = {
    "meditations":       ("https://www.gutenberg.org/cache/epub/2680/pg2680.txt", False),
    "the-art-of-war":    ("https://www.gutenberg.org/cache/epub/132/pg132.txt", False),
    "the-prince":        ("https://www.gutenberg.org/cache/epub/1232/pg1232.txt", False),
    "walden":            ("https://www.gutenberg.org/cache/epub/205/pg205.txt", False),
    "as-a-man-thinketh": ("https://www.gutenberg.org/cache/epub/4507/pg4507.txt", False),
    "the-enchiridion":   ("https://www.gutenberg.org/cache/epub/45109/pg45109.txt", False),
    "rhetoric":          ("https://classics.mit.edu/Aristotle/rhetoric.mb.txt", False),
}

# Intentionally not auto-ingested. In-copyright works, a duplicate, our own
# re-digest, and two niche titles whose only Gutenberg edition is HTML/PDF with
# a broken text path — left for a deliberate decision, not a bulk fetch.
SKIP = {
    "the-myth-of-sisyphus": "in copyright (Camus)",
    "the-denial-of-death": "in copyright (Becker)",
    "a-room-of-one-s-own": "copyright status varies by region",
    "the-art-of-unix-programming": "copyright (ESR); multi-page HTML",
    "the-cathedral-and-the-bazaar": "copyright (ESR); HTML",
    "letters-from-a-stoic": "common translation is in copyright",
    "tao-te-ching": "duplicate of the-tao-teh-king (already persisted)",
    "self-reliance": "no clean standalone public-domain text URL confirmed",
    "the-book-of-five-rings": "HTML-only edition; needs an HTML pass",
    "the-critique-of-pure-reason-revised-digest": "our own re-digest, not a source book",
    "non-euclidean-geometry": "Gutenberg edition is PDF-only / no text path",
    "science-and-hypothesis": "Gutenberg edition is HTML-only / no text path",
}

def psql(sql):
    return subprocess.run(PGC + [sql], capture_output=True, text=True)

def fetch(url):
    for attempt in (1, 2, 3):
        try:
            return urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=120).read().decode("utf-8", "replace")
        except Exception:
            if attempt == 3:
                return None
            time.sleep(4)

def strip_html(h):
    h = re.sub(r"(?is)<(script|style|head)[^>]*>.*?</\1>", " ", h)
    h = re.sub(r"(?i)<br\s*/?>", "\n", h)
    h = re.sub(r"(?i)</p>", "\n\n", h)
    h = re.sub(r"<[^>]+>", " ", h)
    h = html.unescape(h)
    h = re.sub(r"[ \t]+", " ", h)
    return re.sub(r"\n\s*\n\s*\n+", "\n\n", h).strip()

def title_words(title):
    return [w for w in re.findall(r"[A-Za-z]{4,}", (title or "").lower())]

def persist(slug, url, body):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as f:
        f.write(body); host = f.name
    cp = subprocess.run(["docker", "cp", host, f"{CONTAINER}:/tmp/bk_{slug}.txt"], capture_output=True, text=True)
    os.remove(host)
    if cp.returncode != 0:
        return None, "cp:" + cp.stderr.strip()
    r = psql(f"SELECT stewards.book_persist_corpus('{slug}', s.title, s.author, '{url}', "
             f"pg_read_file('/tmp/bk_{slug}.txt')) FROM stewards.book_shelf s WHERE s.slug='{slug}';")
    subprocess.run(["docker", "exec", CONTAINER, "rm", "-f", f"/tmp/bk_{slug}.txt"], capture_output=True)
    c = r.stdout.strip()
    if not c.isdigit():
        return None, "persist:" + r.stderr.strip()[:120]
    psql(f"UPDATE stewards.book_shelf SET source_url='{url}' WHERE slug='{slug}' AND coalesce(source_url,'')='';")
    psql(f"UPDATE stewards.docs SET frontmatter = frontmatter || jsonb_build_object('has_corpus', true, 'source_url', '{url}') WHERE slug='book-{slug}';")
    return int(c), None

def main():
    rows = psql(
        "SELECT s.slug||'\t'||coalesce(s.source_url,'')||'\t'||coalesce(s.title,'') "
        "FROM stewards.book_shelf s JOIN stewards.docs d ON d.slug='book-'||s.slug "
        "LEFT JOIN stewards.book_text t ON t.book_slug=s.slug "
        "WHERE t.book_slug IS NULL ORDER BY s.slug;").stdout.strip()
    rows = [r for r in rows.split("\n") if r.strip()]
    print(f"{len(rows)} digested books without a corpus\n")
    ok, skipped, fails = [], [], []
    for row in rows:
        slug, shelf_url, title = (row.split("\t") + ["", ""])[:3]
        if slug in SKIP:
            skipped.append((slug, SKIP[slug])); print(f"SKIP {slug}: {SKIP[slug]}"); continue
        if slug in OVERRIDE:
            url, is_html = OVERRIDE[slug]
        else:
            m = GUT_ID.search(shelf_url)
            if not m:
                fails.append((slug, "no source")); print(f"NO-SOURCE {slug}: {shelf_url or '(no url)'}"); continue
            url, is_html = f"https://www.gutenberg.org/cache/epub/{m.group(1)}/pg{m.group(1)}.txt", False
        data = fetch(url)
        if data is None:
            fails.append((slug, f"fetch {url}")); print(f"FETCH-FAIL {slug}: {url}"); continue
        if is_html:
            body = strip_html(data)
        else:
            s, e = START_RE.search(data), END_RE.search(data)
            body = (data[s.end():e.start()] if (s and e) else data).strip()
        words = title_words(title)
        if words and not any(w in body[:8000].lower() for w in words):
            fails.append((slug, "title-verify")); print(f"VERIFY-FAIL {slug}: none of {words} near top of {url}"); continue
        if len(body) < 2000:
            fails.append((slug, f"too-short:{len(body)}")); print(f"TOO-SHORT {slug}"); continue
        chunks, err = persist(slug, url, body)
        if err:
            fails.append((slug, err)); print(f"PERSIST-FAIL {slug}: {err}"); continue
        ok.append(slug); print(f"OK {slug}: {len(body)} chars -> {chunks} chunks")
        time.sleep(0.6)
    print(f"\n=== persisted {len(ok)} · skipped {len(skipped)} · failed {len(fails)} ===")
    for s, why in fails:
        print(f"  FAIL {s}: {why}")

if __name__ == "__main__":
    main()
