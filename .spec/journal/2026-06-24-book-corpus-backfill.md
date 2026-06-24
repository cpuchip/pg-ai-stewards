# 2026-06-24 — backfilled the book SOURCE corpus for the whole library

Michael: "back port all of those books! so we have them in our db." The Stewdio
P3 book corpus (`examples/book-corpus.sql`) only ever persisted On Liberty — every
other digested book had a study doc but no `book_text`/`book_chunks`, so a chat
about Don Quixote or The Republic could ground on the digest but couldn't quote
the actual book. This backfills the source text so `book_search` works library-wide.

## Mechanism (no model, no re-digest)

`book_persist_corpus(slug, title, author, url, full_text)` takes the text
directly — so a backfill just needs each book's source. I fetched each from its
authoritative source (the `book_shelf` catalog has URLs) and loaded the body
server-side via `pg_read_file` (the text never rides a shell arg). For gutenberg.org
every book maps cleanly to the canonical plain text `/cache/epub/<id>/pg<id>.txt`
(landing pages, `-h.htm`, and `/files` all resolve by id) — pristine text, which a
verbatim-quote corpus needs. PG license boilerplate trimmed between the START/END
markers; every fetch title-verified so a wrong id can't land under a slug.

## Result: 52 books / 23,628 chunks / 34 MB

- **Pass 1** — 44 gutenberg.org books via pg<id>.txt (Don Quixote 1590 chunks,
  Brothers Karamazov 1339, Wealth of Nations 1654, Republic, Leviathan, Critique
  of Pure Reason, Iliad, Aeneid, …).
- **Pass 2/3** — 8 more: meditations, the-art-of-war, the-prince, walden,
  as-a-man-thinketh, the-enchiridion (explicit Gutenberg ids) + rhetoric
  (classics.mit `.txt`); the-prince needed a retry (Gutenberg throttled ~50 rapid
  fetches).

Proven: The Republic → `found_verbatim: True` for "justice is the interest of the
stronger" + 14 located passages (Thrasymachus, chunks 398–401); The Prince exact
line True; and the quote-guard correctly returns `found_verbatim: False` for a
paraphrase while still retrieving the real passage.

## Intentionally NOT ingested (12 — reported, not bulk-fetched)

- In copyright: the-myth-of-sisyphus (Camus), the-denial-of-death (Becker),
  the-art-of-unix-programming + the-cathedral-and-the-bazaar (ESR),
  letters-from-a-stoic (common translation), a-room-of-one-s-own (region-varying).
- Duplicate: tao-te-ching (we have the-tao-teh-king).
- Not a source book: the-critique-of-pure-reason-revised-digest (our own re-digest).
- No clean source: self-reliance (no standalone PD text), the-book-of-five-rings
  (HTML-only), non-euclidean-geometry + science-and-hypothesis (Gutenberg editions
  are PDF/HTML-only with no text path).

## Reusable tool — `examples/backfill-book-corpus.py`

Idempotent (skips books that already have a corpus), driven by `book_shelf`,
with the gutenberg auto-resolve + the verified OVERRIDE map + the documented SKIP
map. **The corpus lives in the DB (gitignored data), so the work rig will need to
run this once** to populate its own `book_text`/`book_chunks` — that's why it's
committed. `STEWARDS_PG_CONTAINER` overrides the container name.

## Carry

The 12 skipped books (esp. the 2 niche Gutenberg-HTML/PDF titles) could ride the
doc-extract sandbox (HTML/PDF → text) if we want them later; the copyrighted ones
are a deliberate decision, not a fetch.
