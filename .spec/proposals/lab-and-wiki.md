# The Lab and the Wiki — pg-ai-stewards as experiment instrument + auto-organizing memory

**Status: PROPOSAL (drafted 2026-07-03 overnight from Michael's 5am vision; council/ratify
before build).** Two product directions, one substrate.

> "We have built the perfect physics experiment lab, and as an experimental physicist I
> totally approve — and maybe we need to make pg-ai-stewards easier for that. And easier
> for you and others to info dump — and it auto-organize all of that — llm wiki." — Michael

## Part 1 — THE LAB: experiments as a first-class surface

**What already makes it a lab** (the accidental instrument): every dispatch is a tracked,
saved, repeatable row — sessions, tool calls, costs, BINEVAL verdicts, spiral metrics.
The qwen-sampling A/B, the REST A/B, the BINEVAL gemma-inversion — all ran here, and the
raw trajectories are still queryable months later. What's missing is the *ergonomics*:
each experiment was hand-rolled SQL + hand-diffed results.

**The first-class shape** (new chain file, `stewards.experiments`):
- `experiment(name, hypothesis, variants jsonb, n_per_variant, metrics text[])` — declare
  once: variants = config deltas (model alias, sampling params, prompt id, ladder rung…),
  metrics = existing measurables (cost, rounds, tool_calls, calls_per_tool, committed,
  spiraled, bineval_grounding…).
- `experiment_run(id)` — the scheduler dispatches n×variants as tagged work items
  (`experiment_id`+`variant` on the session row). Randomized interleave (not blocked runs)
  so rig drift doesn't confound.
- `experiment_report(id)` — per-variant metric table + deltas; honest n; no p-value
  theater at n=4, just the numbers + spread.
- Stewdio: an Experiments panel — declare / run / watch fills / compare (the report as a
  table + tufte-style sparklines). "Re-run" = one click; "clone with a tweak" = the loop.
- **First registered experiments:** (a) the **Fable-hinge A/B** — same pending hinge-review
  fixtures judged by rung-top=Fable vs rung-top=Opus vs claude-p-sonnet; metrics =
  agreement with Michael's own verdicts (gold set from past reviews), escalation rate,
  cost. Rides the escalation_ladder table. (b) **Opposed-mandate panels vs N-same-prompt**
  — the entropy-collapse claim from the Sanderson digest, tested on our own panel_redline:
  3 identical reviewers vs prove/disprove/find-the-third; metric = distinct-finding count +
  verified-finding count. This one directly answers "am I doing enough diversity locally?"

**Why this fits:** grindable + oracled (sandboxed dispatches, deterministic metrics) —
exactly where autonomy compounds. The lab makes the substrate self-improving with
EVIDENCE instead of vibes, and it's the "physics experiment" surface Michael already
loves, minus the hand-rolling.

## Part 2 — THE WIKI: info-dump → auto-organize (Karpathy-style)

**The itch:** dumping knowledge in (a link, a PDF, a shower thought, a meeting note)
should cost NOTHING at write time — no filing decision — and the substrate should
auto-organize it into a browsable, linked, growing wiki. Today ingestion exists
(doc_import_corpus, digesters, attachments) but organization is corpus/tag-shaped, not
wiki-shaped; the world-graph organizes ENTITIES, not NOTES.

**The shape (build on what exists, don't invent a second brain — we already validated
this against the OpenBrain video: we HAVE the layers; this is the missing front door):**
- `dump(anything)` — one tool + one Stewdio drop zone + (later) an email/phone share
  target. No required metadata. Lands in an inbox pool.
- A **curator digester** (existing digester machinery) sweeps the inbox: extracts
  entities/claims, links to existing docs + world entities (embed + RRF — exists),
  creates/updates **wiki pages** = living docs per topic (doc-construction diffs — exists),
  files provenance (source_refs — exists), and maintains a `See also` graph (world_edges
  on a `wiki` world).
- **Page identity is the hard part** (same lesson as world dedup): pages key on a
  canonical topic slug; the curator PROPOSES merges/splits via the hinge queue rather
  than silently renaming (lightning-bolt changes auto-apply; mountain moves get review).
- Browsing: the docs panel already renders docs with links (O2); add a wiki lens (topic
  tree + backlinks + recently-touched). The 3D world view gives the constellation for free.
- **The Karpathy property** — the wiki is REGENERABLE: pages are derived views over the
  immutable dump+provenance layer, so a better curator model later can re-derive better
  pages without losing anything. Dumps are the ledger; pages are the working memory.

**CKE resonance (Michael's seam-analysis vision):** this is the same motion as the work
data — pour everything in, let the substrate organize, ask snapshot questions, pull
beautiful views of the seams. The wiki is the personal/home instance of the CKE pattern;
building it here dogfoods the work story.

## Sequencing recommendation

Lab first (smaller, rides existing metrics + the new ladder; two experiments already
queued that answer live questions). Wiki second (bigger; the curator + page-identity
work deserves its own arc; the dump tool alone could ship early as a cheap win).

## Open questions for Michael
1. Lab metrics v1: is the set above enough, or add latency/tokens-per-commit?
2. Wiki scope v1: personal/home only, or design day-one for the work CKE twin?
3. Does `dump` accept voice memos day one (whisper path exists via yt tooling)?
