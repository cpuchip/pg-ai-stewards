# Where we live now — synthesis (2026-07-07, post PR #31 + #32)

**Panel:** MAPPER / SKEPTIC / DEMO-PATH (three sonnet seats, opposed mandates, receipts
required from merged main). **Mirror:** Nate B Jones's nine-primitive paperwork skeleton
(`yt/ai-news-strategy-daily-nate-b-jones/U4TmrlWEY4M`) — a reflective surface, not the
measuring stick. **The measuring stick:** Michael's own June weight report — *"so many
rough edges, poor UI still, broken paths, 102 sql files... painful updates between
systems... part of me just thinks I need to go file based."*

## The June complaints, re-scored

| Complaint (June) | Verdict today | Evidence |
|---|---|---|
| "102 sql files" | **DEAD** | 28 themed volumes, byte-proven move; generated COPY manifest; CI drift gate |
| "Painful updates between systems" | **MOSTLY DEAD** | `stewards-cli update` (one verb, unpiped exits); migrate consolidation-adopt (28 adopts/0 applies); parity-check green on live. The work-box pull is the remaining proof. |
| "Poor UI still" | **WOUNDED, NOT DEAD** | 24→10 nav + operator fix batch landed. But the receipt-as-UX gap stands (gate substance ≫ gate presentation), and WorkItemDetail is operator-shaped, not reviewer-shaped. |
| "Rough edges / broken paths" | **THE CLASS SURVIVES** | Sharpest finding of the panel: `file_drops` — born *yesterday* — has zero UI surface, and a stock-install binary drop dead-ends invisibly (doc-extract server enabled by default, docker socket opt-in → exit 125 → error lands in a table no screen shows; README overpromises). We fix instances; the class regenerates with each feature. |
| "Part of me thinks I need to go file based" | **CHANNELED** | Layer 3 is real: drop-with-provenance in, projection tree out. The temptation now has a lawful outlet. The remaining weight (cold cargo-pgrx build + 4 services) is unmoved — and it is the deliberate price of the ledger, per the four-layer verdict. D2A packs are the next weight cut. |
| "Are we pioneers?" | **UNCHANGED: yes, on seams** | Nothing in this panel challenged the seam-finding claim. The mirror *independently confirms* our commodity bets (structure-over-vectors, clean-data→cheap-models, gate-with-receipt, primitives flywheel) — which is evidence those are table stakes to build ON, not differentiation to build FOR. |

## Against the mirror, for calibration

MAPPER: **6/9 primitives HAVE, 2 PARTIAL (chunk, export), 1 MISSING (normalize)**; both
meta-principles present — with "zero models required" as a founding constraint going
deeper than the mirror's version. DEMO-PATH narrowed the distance to the mirror's
build-2 (folder → inspectable case file) to **three small builds, ~3.5–4 sessions**,
everything else templated reuse. SKEPTIC sustained six attacks, rejected one honestly
(the extraction sandbox is real engineering — the gap is packaging/defaults/typed
output, not vaporware).

## The three genuinely new findings

1. **NORMALIZE is the missing primitive** (all three seats converged independently).
   No typed extraction anywhere in 28 volumes — dates, amounts, deadlines — and
   *missing-documents-as-first-class* has zero representation. Small build, high
   leverage, and it feeds CKE directly: seams over typed facts beat seams over prose.
   The entity vocabulary is lore-shaped (character|place|faction...), not ledger-shaped.
2. **The receipt screen.** The gate's substance (work items, steward_actions, cost
   events, hinge verdicts) exceeds the mirror's; its presentation doesn't exist. One
   ui-craft increment: a human-shaped per-work-item panel — *what was read, what
   changed, what needs you* — distilled from rows we already keep.
3. **The 2026-05-15 chunking trade deserves a narrow exception.** Dropping
   deterministic leaf-chunking for engram extraction was right for prose corpora; the
   paperwork workload (retrieve-by-section, cite-by-address) wasn't in view. Structural
   chunking for document-shaped sources is the exception the decision anticipated, not
   a reversal. (Chunk-level addressability already exists twice: `page_sources.chunk_ref`,
   `world_entities.source_refs` — the shape is waiting.)

## The systemic lesson (bigger than any finding)

The rough-edges class regenerates because **feature-truth outruns UI-truth by default**:
a new table ships, its failure states land in rows, no surface shows them, the README
speaks in the future perfect. The instance fixes (June's operator batch, the PAUSED
banner) don't kill the class. Candidate systemic fix, for council: **"no new
user-facing state without a surface; no failure without a face"** as definition-of-done
— every user-visible failure state must map to needs_attention, a banner, or a screen,
and the claim in README must match a walkable path. Possibly enforceable as an oracle
(route-walk lint over new tables/status columns).

## Recommended next moves (for Michael's ordering)

- **Honesty patch (small, now):** `file_drops` errors → needs_attention; README caveat
  on binary drops pending the doc-extract overlay; consider seeding the doc-extract
  server disabled-by-default with a wizard toggle (the lifeless-core posture applied to
  capability honesty).
- **Normalize + receipt screen (one wave):** the two findings every seat hit. Typed
  extraction shape + missing-docs object; the per-work-item receipt panel.
- **Case-file digester (one wave, after):** DEMO-PATH's plan — `examples/case-file-digester.sql`
  mirroring the book digester, facts rendered server-side from typed rows, LLM authors
  only the letter, text-vs-text sanity oracle (inverse-proven with a planted
  contradiction). For Michael's *personal* one-off: the Claude-Code-skill-first path is
  honestly lighter; the substrate version is for the repeatable/CKE-shaped workload.
- **D2A packs:** still the next structural weight cut; unchanged by this panel.

## Verdict

Closer — materially, not rhetorically. The packaging half of the June report is dead or
dying; the capability surface covers ~¾ of the mirror's skeleton with the missing
quarter small and named; the file-based temptation has been given a lawful body instead
of an argument. What survives is one missing primitive (normalize), one presentation
debt (the receipt), and one *class* of failure (silent seams between features and their
surfaces) that needs a systemic answer rather than another fix batch. The weight that
remains is the weight we chose — the ledger, the gate, the physics — and this panel
found no reason to regret the choice, only sharper knowledge of what it costs.
