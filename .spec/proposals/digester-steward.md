# Proposal: a presiding steward over the digester loops (feed the queue, never spin empty)

**Status:** draft for council · **Date:** 2026-06-16 · for Michael
**Motivation:** Michael — "do we have an ammon-style steward presiding over the
digester loops? One that only adds to the input queue based on what's in the
pipeline + at the end, and when empty idea-generates / brainstorms to further the
intent. Affects books, work-corpus, and ai-video."
**Pairs with:** reflect-steward.md (the work-corpus back-office), corpus-treatment (the
pools), Computer/analyst (the front-desks), digester-empty-source-halt (the guard).

## The gap (confirmed live)

Only **work-corpus** has a presiding steward — the `planning`/reflect loop
(`work-corpus-reflect`) that surveys → proposes → pools → carries the intent, gated by
approval + the watchman guard. The other lines are **dumb cron**:

| Intent | Loop | Queue | Who feeds it | Presiding? |
|---|---|---|---|---|
| work-corpus | planning (reflect-steward) | proposals | the steward itself | **yes** |
| book-study | book-digest (cron) | `book_shelf` | operator / seed only | no |
| video-study | playlist-digest (cron) | `playlist_watch` | operator / seed only | no |
| (ai-news / science) | research-* (cron) | — | the cron prompt | no |

So the digesters **consume** an operator-fed queue and stop. Nothing decides what
to add, nothing notices the queue is dry, nothing extends the intent. That is why
the shelf emptied and book-digest spun 17 empty runs — no steward was watching.

This session gave books/ai-video the other two legs (the **pool** via corpus
treatment; the **front-desk** via Computer). The **back-office steward is the
missing leg** — the same one work-corpus already has, generalized.

## The idea: a digester-curator steward (presiding, Ammon)

A scheduled, planning-style run **per digester intent** that presides over its
queue (D&C 121 — it watches what it set in motion; Ammon — it doesn't beg off when
the queue's empty, it finds the next work):

1. **Survey first (the council moment).** Read the pool + the queue + the ledger:
   what have we digested, what's queued, what does the intent want next?
   (`intent_work_survey` already returns proposed/in-flight/done + `existing_studies`.)
2. **Feed only as needed.** If the queue has runway, do little (don't over-fill). If
   it's low/empty, propose N new, **dedup-checked** sources (books / videos / topics)
   that further the intent, and add them to the queue (`book_add` / `playlist_add` /
   the source tool). "Add based on what's in the pipeline and at the end."
3. **On empty → idea-generate / brainstorm.** When it can't name concrete next
   sources, call `start_brainstorm` on the intent to discover what would further it,
   then turn the best into queue items. The loop never goes idle or junk-spins; it
   reaches for the next thing.

This is the reflect-steward **generalized**: work-corpus's steward proposes *research
work_items*; a digester-curator proposes *queue additions*. Same shape — survey,
propose, dedup, carry — pointed at a different queue.

## Reuse map (most of it exists)
- **The engine** — the reflect-steward (planning pipeline + schedule + the
  capacity-gated drain + the watchman guard). Generalize it to the book/video intents.
- **The council moment** — `intent_work_survey` (now with `existing_studies`).
- **Dedup** — `intent_source_ledger` + `binding_question_overlap` (the near-dup gate).
- **Idea-gen** — `start_brainstorm` (the 12-lens brainstorm).
- **The queues + add tools** — `book_shelf`/`book_add`, `playlist_watch`/`playlist_add`.
- **The empty guard** — `digester-empty-source-halt` (so a momentarily-empty queue is
  cheap, not junk).
**New bits:** the curator run (survey → decide additions → `*_add`), the
empty→brainstorm path, and a steward schedule per digester intent.

## The autonomy question (for council)
A steward that **auto-adds** work to a queue is autonomous work-creation + spend —
the gated-autonomy line. Options, mirroring work-corpus:
- **Gated** (safest): the curator *proposes* queue additions; you approve → they're
  added (rides the existing approval queue + drain).
- **Capped-autonomous**: it adds freely but the watchman guard's caps (in-flight,
  spend, proposals) brake a runaway; book/video digesting is low-stakes (public text).
- **Lean:** gated for the first soak (prove the picks are good), then relax to
  capped-autonomous per intent once trusted — exactly how work-corpus went.
The watchman guard already covers all of them; the kill switch + per-intent pause apply.

## Phasing
- **P0** — one digester-curator (start with **book-study**): a scheduled survey→decide
  →`book_add` run, gated (proposes shelf additions); empty→`start_brainstorm`. Prove it
  keeps the shelf fed with non-dup, intent-aligned books and never spins.
- **P1** — generalize to video-study (`playlist_add`) + ai-news; one curator per intent.
- **P2** — relax gating to capped-autonomous per intent once the picks are trusted;
  tune cadence (curate only when the queue dips below a runway threshold).

This is the unification you saw: one presiding pattern over **all** the intent loops —
each with a pool (have), a front-desk persona (have), and now a back-office steward
that keeps it fed and carries it forward (this).
