# Proposal: the book digester — read a book the way we read scripture

**Status:** DRAFT (design, for ratification). A concrete instance of the
[study pipeline](study-pipeline.md), on a slow cadence, with a *whole book* as
the corpus. Build after ratification; runs on the OSS (a model provider key is
the only prerequisite).

## The pitch

The substrate picks a public-domain or freely-available book — starting with the
classics — and **digests it the way we do a scripture study**: read it in passes,
pull out the core argument and the passages worth keeping, wrestle with it, and
end with *what's worth learning and what we could do with it*. Not a book report
— a study. One book unfolds over days, not one turn.

It's the third member of a **digester family**, all built on the study pipeline,
differing only in their corpus + cadence:

| Digester | Corpus | Cadence |
|----------|--------|---------|
| study pipeline | a binding question + ad-hoc sources | on demand |
| **book** (this) | one whole book | slow — over days |
| playlist (#4) | new videos on a YT playlist | a few times a day |
| self-improvement (#6) | a subject the agent *chooses* | hourly |

Designing this one well makes #4 and #6 mostly a matter of swapping the source.

## The hard part: a book doesn't fit in context

A classic is 100K–500K+ tokens — far past any context window. The substrate
already has the answer: the **corpus + engram machinery** (15a/15b) was built for
exactly this — chunk a large text, digest each chunk, and synthesize across them
(map-reduce). So the book digester is a map-reduce over a book:

1. **fetch** the book's plain text (Project Gutenberg / Standard Ebooks via
   `fetch_url` — the M2 tool). Cache it in the corpus.
2. **chunk** by chapter/section into corpus rows (the existing indexer).
3. **digest each chunk (map)** — per-section: a tight summary + the key passages
   (verbatim, with location), via the doer model.
4. **synthesize (reduce)** — the book's argument, structure, themes, and the
   author's moves, from the chunk digests.
5. **critique / null-case** — a *different* model reads the synthesis against the
   chunk digests: what did it flatten? where is the synthesis unfaithful to the
   text? what's the strongest objection to the book's argument? (the D&C 88:122
   council-critic + Moroni 10:4 inverse pattern).
6. **recommendations** — "what's worth learning here, and what could *we* do with
   it" — the actionable turn Michael wants.

## Stage graph

```
pick → fetch → chunk → [digest-section]* (map) → synthesize → critique → recommend
```

- **pick** — choose the next book from a reading queue (a small table of
  {source_url, title, status}) seeded with classics; or, later, the agent picks
  by interest (the #6 seam). Output: the book to read.
- **fetch / chunk** — tools-on; `fetch_url` the text, index into corpus. One-time
  per book.
- **digest-section** — tools-off, doer model (**kimi-k2.6**); map over sections.
  Idempotent + resumable: each turn digests the next N undigested sections, so a
  long book advances a little each scheduled tick.
- **synthesize / critique / recommend** — fire once all sections are digested.
  Critic = **qwen3.7-plus** (not qwen3.7-max — ~2× the cost for the critical pass).

## Cadence — slow and resumable

Unlike ai-news-7am (a fresh run each fire), the book digester **advances a
long-running job**: a scheduled daily tick digests the next few sections of the
*current* book; when the book is fully digested, it synthesizes + critiques +
recommends, marks the book done, and picks the next. This wants a small bit of
state (current book + section cursor) — a `book_progress` row — and a scheduled
pipeline that resumes rather than restarts. (The scheduler (18) fires it; the
resume logic is the new part.)

## Output

A **study doc** (the digest + synthesis + recommendations) written to the corpus
via `import_doc`, plus a short "what we could do with this" summary. Optionally
posted to a chat room (like the schedules) or a brain entry, so it surfaces.

## Book sources

- **Project Gutenberg** (gutenberg.org) — ~70K public-domain books, plain-text
  downloads + a catalog. Primary source.
- **Standard Ebooks** — cleaner-formatted public-domain classics; nicer text.
- The reading queue ships seeded with a starter shelf of classics; the operator
  edits it. (For the OSS, this is an example overlay, not core — book choices are
  operator data.)

## Reuses vs. new

- **Reuses:** study-pipeline pattern, corpus/engram map-reduce (15a/15b),
  scheduler (18), `fetch_url` (M2), the council-critic, `import_doc`.
- **New:** the `book_progress` resume state + the section-cursor "advance the
  current book" scheduled logic; the reading queue; the Gutenberg fetch/chunk
  glue.

## Where it runs + the one prerequisite
On the OSS (new work goes there per the cutover plan). The only thing it needs to
actually run is a **model provider** — drop an opencode key (or any provider)
into the OSS `.env` and the doer/critic dispatch. **Recommendation for the first
run: a short classic** (a Meditations / an essay, not War and Peace) so the whole
loop completes fast and we *see* it work before tuning cadence.

## Open questions (for ratification)
- **Reading queue:** ship a starter shelf, or start empty + a `book_add(url)` tool?
- **Resume granularity:** sections per tick (2? 5?) + tick cadence (daily? hourly?).
- **Output home:** corpus doc only, or also a chat-room post / brain entry?
- **Pick-by-interest (the #6 seam):** wire the agent's own choice now, or keep a
  human-curated queue until #6?
- **First book** to prove the loop.
