# verify-digest-quotes — a quote oracle for the autonomous digesters

The book and video digester pipelines put **quotation marks** around source text.
A local model reading a book and quoting it can confabulate — and a fabricated
quote is "a lie that looks like truth" (the covenant's `read_before_quoting`).
This is the deterministic detector that catches it: for every quoted span in a
digest, check the span actually appears in the **source** the work item read.

This is the *oracle-first* move: the same deterministic check the Webster
study-walk should have built before the manual pass (see the workspace
`scripts/verify-quotes`). Detector first, judgment second.

## What it checks (and doesn't)

- **Checks:** every double-quoted span (straight `"…"` or curly `“…”`) ≥ `min-len`
  chars against the source, verbatim (substring) or fuzzy ≥ `threshold`. Elided
  quotes (`"a … b"`) pass only if every fragment is present, in order.
- **Sources:** `book-<slug>` → the Project Gutenberg full text resolved from
  `book_shelf.source_url` (cached under `.cache/`, gitignored). `yt-<id>` → the
  stored transcript in `stewards.yt_transcript_segments`.
- **Does NOT check** non-quoted factual claims — chapter names, dates, "cited it
  six times". Those are the critique stage's judgment job, not this oracle's. (The
  one exception: if the model wraps a fabricated *name* in quotes — e.g. a made-up
  chapter title — the oracle catches it, because it's quoted.)

## Verdicts

| | meaning |
|---|---|
| `OK`   | the quote is in the source (substring or fuzzy ≥ threshold) |
| `FLAG` | the quote is NOT in the source — confabulated, or paraphrased-inside-quotes (the rule is *verbatim or don't use quotation marks*) |
| `SKIP` | no source to check against (book has no `source_url`; video has no stored transcript) — reported, never failed |

## Usage

```bash
# one doc
python verify-digest-quotes.py book-the-iliad --verbose

# the whole corpus
python verify-digest-quotes.py --all          # books + videos
python verify-digest-quotes.py --all-books
python verify-digest-quotes.py --all-videos
```

Options: `--container <name>` (default `stewards-oss-pg`), `--min-len N`
(default 24), `--threshold R` (default 0.82), `--verbose` (show OK quotes too).
Exit `0` if no FLAG, else `1`. Reads the live DB **read-only** via `docker exec psql`.

## Where this fits — the publish gate

Digests always pool to the DB; they materialize to the repo (`study/books/…`,
`study/yt/…`) only when the operator runs the materializer (the `/workspace` mount
is read-only by default). **This oracle is the pre-materialize gate**: run it
before letting a digest reach the repo. A `FLAG` means either fix the digest
(re-run the critique stage to requote verbatim or drop the quotation marks) or
hold it out of the repo.

Tuning note: `FLAG` includes paraphrased-in-quotes, not only outright fabrication
— that's deliberate (the standard is verbatim). Raise `--threshold` toward 1.0 for
strict verbatim-only; lower it to surface only gross confabulation. Precision over
recall: keep it trustworthy so the adjudicator keeps trusting it.

## Roadmap

- **Self-check in the loop:** the critique stage already has the source paged into
  its session (the build stage's `fetch_url` result). A future `verify_quotes`
  substrate tool could let the critic check its own quotes via `result_search`
  before `book_publish_draft` — moving the gate left, into the run.
- **Non-quoted claims** (chapter names, counts, dates) remain a judgment-layer
  problem; the critique stage owns it.
