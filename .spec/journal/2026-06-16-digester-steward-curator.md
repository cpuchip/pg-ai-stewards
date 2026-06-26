# 2026-06-16 — The digester-steward: a presiding curator for the book line

**Shipped:** OSS `38f6c6d` (pushed) — `examples/book-digester.sql` gains a curator.
**Ratified:** same session, council ("lets council, I want this change. I think we
enable by default here. I have a spend cap set in opencode go… but you're right to
always push back on spend!").
**Proposal:** `.spec/proposals/digester-steward.md`.

## What this closes

The gap I'd named earlier in the day: only **the operator's lead intent** had a
presiding back-office steward (the reflect-steward — survey → propose → pool, gated
by approval + the watchman guard). The other lines — book-study, video-study, ai-news
— were dumb cron: they *consume* an operator-fed queue and stop. Nothing decided what
to add, nothing noticed the queue went dry, nothing extended the intent. That's why
the book shelf emptied and book-digest spun 17 empty runs (~178k wasted tokens) before
the structural empty-shelf guard.

This session had already given the book/ai lines the other two legs — the **pool**
(corpus decouple, #178) and the **front-desk persona** (Computer/librarian reading the
pool). The **back-office steward was the missing leg.** P0 brings it to book-study.

## The curator (the reflect-steward, generalized to a queue)

A scheduled, single-tools-on `curate` stage (research agent, kimi-k2.6) that presides
over the reading shelf the way the reflect-steward presides over its proposal queue:

- **STEP 1 runway** — `book_shelf_status()` (new fn+tool: queued/reading/done counts +
  titles). If `queued >= book_curate_runway_threshold` (3) → reply `SHELF STOCKED` and
  stop. *Feed only when low; never over-fill* — Michael's "add based on what's in the
  pipeline" made mechanical.
- **STEP 2 survey** (the council moment) — `intent_work_survey` + the shelf's queued/done
  titles; never re-propose a book already queued/reading/done.
- **STEP 3 pick + verify** — choose intent-aligned, non-duplicate books; **verify a real
  fetchable full-text URL** (web_search / fetch) *before* `book_add`. A phantom source
  wastes a whole digest run, so findability is a hard gate, not a nicety.
- **STEP 4 dry shelf** — if it can't name good next books, `start_brainstorm` on the
  intent, then turn the strongest idea into a verified pick. The loop never idles or
  junk-spins; it reaches for the next thing (Ammon).

Plus: the `book-curate` pipeline, the `book-curate-cron` schedule (every 6h, **enabled
by default**), config dials (`book_curate_runway_threshold=3`, `book_curate_max_adds=5`),
and research grants for `book_shelf_status` + `start_brainstorm`. Enabled-by-default is
safe because it's capped by the watchman guard (in-flight / spend / failures / proposals)
**and** the operator's opencode-go flat-rate spend cap — and a book/video curator is
low-stakes (public text, no pool junk: the curator produces no doc, only queue side-effects).

## Proven e2e on live (both branches)

- **Feed path** (shelf at 0 queued / 1 reading, below threshold): the curator surveyed,
  reasoned explicitly about coverage gaps ("the null case to the Stoic/Transcendentalist
  works already digested"), and added **3 genuinely non-duplicate, intent-aligned books** —
  Aristotle's *Nicomachean Ethics*, Hume's *Enquiry Concerning Human Understanding*, Bacon's
  *Novum Organum* (ethics / epistemology / scientific method). I confirmed the curator's
  findability claim rather than trusting its self-report: all three Gutenberg URLs return
  **HTTP 200** (inverse-hypothesis on the verification gate itself).
- **Restraint path** (after the feed, queued=3 ≥ threshold): a fresh run returned
  `SHELF STOCKED`, added nothing, shelf unchanged. The "don't over-fill" guard holds —
  arguably the more important half (a curator that over-fills is worse than one that
  doesn't run).

## Two snags, both instructive

1. **`INSERT has more target columns than expressions`** — the `tool_defs` INSERT named
   5 columns `(name, description, args_schema, execute_target, active)` but gave 4 values.
   It halted *after* the CREATE FUNCTIONs (partial landing: `fn=true, tool=false`), which
   pinned it to the first INSERT. Fixed by supplying `active = true`. Lesson re-confirmed:
   when a multi-statement apply partial-lands, the failure is the statement right after the
   last success — don't re-run the whole file (it would re-seed `book_shelf`); apply the
   isolated, idempotent block.
2. **Moonshot AI down (kimi-k2.6)** — both first dispatches failed with Cloudflare 521/522
   ("Provider returned error", `provider_name: Moonshot AI`). Not a curator bug — it reached
   the LLM dispatch; the upstream was down. opencode-go itself was healthy (glm/qwen/minimax
   routes probed fine hours earlier), so I proved the **logic** by overriding *the e2e work
   item only* to `qwen3.6-plus` (another opencode-go route → ~$0 marginal on the flat-rate
   sub). Production stays on kimi-k2.6; transient Moonshot outages retry next tick (low
   stakes — no pool junk). The override never touched the pipeline or schedule.

## Carry-forward (ratified P1/P2, not started)

- **P1 — generalize the curator** to video-study (`playlist_add`) and ai-news; one curator
  per digester intent. The curate stage is intent-parameterizable; mostly seeds + a per-intent
  schedule.
- **P1 — the generic `digester-empty-source-halt`** (`.spec/proposals/digester-empty-source-halt.md`):
  a pipeline declares `metadata.halt_on={stage,outputs}`; ONE core BEFORE-UPDATE guard
  retires the two per-pipeline triggers (book + playlist) so the next digester inherits the
  empty-source guard in one line. dominion_in_council (core change).
- **Cadence** — book-digest runs hourly, the curator every 6h. The curator now keeps ~4 in
  runway, so the digester won't starve, but consider slowing book-digest to match (it
  currently outpaces the curator's top-up rate).
- **Open council item (inbox)** — "let the digesters READ our repos" (cross-reference-our-corpus
  stage). Adjacent: a corpus-reading curator could pick books/videos that fill gaps in what
  we've *already studied*, not just the intent in the abstract.

## The shape that's now whole

One presiding pattern over every intent loop: a **pool** (compounding knowledge), a
**front-desk persona** (answers from the pool), and a **back-office steward** (keeps it fed,
carries it forward). The reflect-steward was the first instance; the curator is the second.
Same shape — survey, propose, dedup, carry — pointed at a different queue.
