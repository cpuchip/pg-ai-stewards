# Proposal: a generic "empty-source halt" for digester-shaped pipelines

**Status:** draft for council · **Date:** 2026-06-16 · for Michael
**Motivation:** Michael — "generalize the notion of a digester so this won't happen again."

## The problem (twice now)

A **digester** is a pipeline whose first stage pulls work from a *source that can be
empty* — a reading shelf (book-digest), a watched playlist (playlist-digest), a
research queue, an inbox, an RSS feed. When the source is empty, the read stage is
told (by prompt) to emit a sentinel and "stop" — but **an LLM can't stop the
pipeline**; `auto_advance` runs the remaining stages anyway. Consequences seen live:

- **book-digest:** no structural guard → ran digest/critique/recommend on `SHELF
  EMPTY` and **pooled 17 junk "null-case report" docs** + ~178k wasted input tokens
  (spun hourly for ~17h).
- **playlist-digest:** threaded the sentinel through the prompts (so publish refused
  → no pool junk) but **still ran all four stages** on `NOTHING NEW`/`NO PLAYLISTS`.

We fixed each with a per-pipeline `BEFORE-UPDATE` trigger (`book_digest_skip_empty_shelf`,
`playlist_digest_skip_empty`). That's duplication, and the *next* digester will repeat
the mistake. It should be a property of the pipeline, declared once.

## The generalization

**A pipeline declares its empty-source sentinels; one generic core guard enforces them.**

1. **Declare** — in the pipeline's `metadata`:
   ```json
   "halt_on": { "stage": "read", "outputs": ["SHELF EMPTY"] }
   ```
   (playlist: `{"stage":"read","outputs":["NO PLAYLISTS","NOTHING NEW"]}`.)
2. **Enforce** — ONE generic `BEFORE-UPDATE OF stage_results` trigger on `work_items`:
   read the pipeline's `metadata->'halt_on'`; if the named stage's trimmed output is in
   `outputs`, set `NEW.status='cancelled'` + a reason. No downstream dispatch; maturity
   never reaches verified (no pool). Reversible (re-queue the source).
3. **Migrate** — set `halt_on` on book-digest + playlist-digest; retire the two
   per-pipeline triggers. New digesters just set `halt_on` (one line) — the bug can't
   recur.

This lives in **core** (it's a cross-pipeline mechanism on `work_items`, like the
maturity/one-shot triggers), so every operator's digesters inherit it; the sentinel
values stay per-pipeline data.

## Why a sentinel (not "empty output" detection)
A stage legitimately can produce short output; "empty" is ambiguous. An explicit
declared sentinel the read prompt emits ("reply EXACTLY `SHELF EMPTY`") is
unambiguous and already how the digesters are written — we're just making the
substrate honor it instead of trusting the LLM to self-halt.

## Guardrails
- **Opt-in** — no `halt_on` = no behavior change (every non-digester pipeline unaffected).
- **Reversible** — cancel is recoverable; re-queue the source and the next scheduled
  run proceeds normally.
- **One stage, exact match** — match only the declared stage's trimmed output against
  the declared list (no fuzzy/substring), so a real digest that *mentions* the
  sentinel isn't killed.

## Phasing
- **P0** — the generic guard (core) + `halt_on` metadata convention; migrate
  book/playlist; retire the two specific triggers; virgin-smoke: a pipeline with
  `halt_on` cancels when its stage emits the sentinel, and one without is untouched.
- **P1** — a tiny `digester` helper/example template so a new digester is "declare a
  `*_next` source tool + `halt_on` + 4 stages" with the guard for free.

Until ratified/built, the two per-pipeline triggers (book + playlist) hold the line.
