# Proposal: the study pipeline — answer a binding question across any corpus, with rigor

**Status:** DRAFT (design only). Build is a fast follow-on **after the parity
cutover** — it sits on primitives that already ship, so it is mostly assembly +
one new critic stage.

## The pitch

Give the substrate a *binding question* and a *corpus* — and get back a cited,
critically-reviewed answer produced by the same discipline a careful human
researcher uses: gather sources, outline, draft, **hunt for the null case**,
revise, finalize, review. The corpus can be anything the operator can point a
tool at: web pages, a folder of markdown, YouTube transcripts, meeting/call
transcripts, a wiki, a codebase. The pipeline does not care what the sources
*are* — only that some granted tool can fetch them.

This is the substrate's flagship demonstration of its own reason to exist:
**covenant + intent + verification applied to knowledge work**, not prompt
garnish. It generalizes the phased "study agent" workflow (gather → outline →
draft → critical analysis → revise → final → review) into a reusable pipeline
that runs on arbitrary subject matter.

Worked example (the generic test):

> *"What are the chemical interactions of acids and bases, and how does that
> relate to batteries?"*

A naive answer conflates acid–base chemistry (proton transfer) with the redox
(electron transfer) that actually stores energy in a battery. The **null-case
stage exists to catch exactly that**: a critic that asks "is the stated
mechanism actually the source of the effect?" and forces the draft to
distinguish the electrolyte/medium from the energy mechanism before it ships.
That is the difference between a plausible answer and a correct one.

## What already ships (reused, not built)

The substrate core already has every primitive this needs:

| Need | Existing primitive |
|------|--------------------|
| Multi-stage work with gates | `work_items` + `pipelines` + `pipeline_stage_maturity` (08-gates) |
| Gather from the web | `web_search` tool_def → `web_search_exa` (M2) |
| Gather from local docs / a folder | `fs-read` MCP (`fs_list`/`fs_read`/`fs_search`), core |
| Gather from any other source | bring-your-own MCP (yt transcripts, a wiki, call-notes) registered in `mcp_servers` |
| Deep multi-step research | `deep_research` tool + the research-write / planning pipelines (13) |
| Parallel angles | fan-out + 12-lens brainstorm (14) |
| Critic / null-case review | the council pattern — a *separate critic agent* reviewing each stage (the D&C 88:122 "council beats gift-matching" finding) + the inverse-hypothesis discipline (Moroni 10:4 / Agans rule 9) |
| Citation expansion | the generic resolver (`resolve_ref` + `STEWARDS_RESOLVER_URL`) — fetch the canonical content behind a cited URI |
| Cost control on reasoning stages | `tools_disabled=true` on JSON-output stages (7× cheaper, per the gate-eval lesson) |

## What is new (the actual build)

1. A `study` (working name) **pipeline template** wiring the stages below.
2. A **critic/null-case stage** as a first-class pipeline stage — not just a
   self-audit prompt, but a separate critic agent with a verdict that loops the
   draft back or advances it. This is the one genuinely new piece.
3. A small **`scratch` convention** for the gathered corpus (engrams already
   give us context compaction; the gather stage writes its sources as corpus
   rows the later stages read).

## The stage graph

```
frame → gather → outline → draft → critique → [revise → critique]* → final → review
```

| Stage | Tools | Output | Gate |
|-------|-------|--------|------|
| **frame** | off | Restate the binding question precisely. Name what a *complete* answer must cover, and the **disconfirming question** (what would prove this wrong?). Identify which granted tools/corpus to use. | — |
| **gather** | **on** | Run searches/fetches; collect sources into the scratch corpus with provenance (url/path + retrieved text). Breadth over depth. | — |
| **outline** | off | Structure the answer from the gathered corpus only. Flag gaps where the corpus is thin (→ may loop back to gather). | maturity |
| **draft** | off | Full draft. Every non-obvious claim cites a gathered source. | maturity |
| **critique** | off (a *different* model than the drafter) | Hunt the null case: unsupported claims, the inverse hypothesis, citations that don't actually support the claim, conflated mechanisms. Verdict: `revise <reasons>` or `passes`. | **gate** |
| **revise** | off | Address every critique point. Loop back to `critique`. Capped (e.g. 2 rounds) so it terminates. | — |
| **final** | off | The answer, with citations resolved (via `resolve_ref`) where the corpus had only references. | maturity |
| **review** | off / human | Final gate: answers the binding question? claims cited? null case addressed? The human is the Hinge here for anything consequential. | **gate** |

Design notes:
- **The critic is a separate agent/model**, per the council finding — a strong
  doer drafting + a critic reviewing at each gate beats per-stage gift-matching.
- **Gather is the only tools-on stage.** Everything downstream reasons over the
  gathered corpus, which keeps cost down and makes the answer *auditable*: you
  can see exactly which sources the conclusion rests on.
- **Corpus-agnostic by construction.** Swap the gather tools and the same
  pipeline answers questions over a codebase, a transcript set, or the web. The
  acids-batteries example uses `web_search`; a "what did we decide about X
  across these 40 call transcripts?" run uses an imported-transcripts MCP.

## Worked example walk (acids/bases → batteries)

1. **frame** — Cover: acid–base reactions (proton transfer, neutralization,
   pH), battery electrochemistry (redox, electrolyte, half-cells). Disconfirming
   question: *is the acid–base interaction the energy source, or just the
   medium?*
2. **gather** — `web_search` for acid–base chemistry and for battery
   electrochemistry; fetch 3–5 sources into the corpus.
3. **outline / draft** — explain both; connect them via the electrolyte.
4. **critique** — "The draft implies acid–base neutralization stores the
   energy. It does not — energy storage is redox (electron transfer); the acid
   in a lead-acid cell is the electrolyte that carries ions, and it *does*
   participate in the half-reactions, but the mechanism is redox, not
   neutralization. Distinguish these or the answer is wrong." → `revise`.
5. **revise → critique** — draft now separates medium from mechanism. → `passes`.
6. **final / review** — cited answer that gets the chemistry right.

## Open questions (for the build session)

- **Stage names / pipeline family** — `study`? `research`? (avoid colliding with
  the existing `research-write` pipeline; this is the corpus-binding superset).
- **Scratch corpus shape** — reuse the engram/corpus tables, or a lighter
  per-work-item scratch store?
- **Citation resolution in `final`** — auto-resolve all cited URIs via
  `resolve_ref`, or only on demand?
- **Human-in-the-loop** — is `review` always a human gate, or auto-pass for
  low-stakes runs with human escalation only on a failed self-check?
- **Provider defaults** — drafter vs critic model defaults ship generic; the
  operator sets real models in an overlay.

## Sequencing

Build **after the parity cutover** (Michael, 2026-06-13: "a quick follow on once
we're done with parity"). The cutover frees the substrate to consume the OSS
core + overlays cleanly; this pipeline then ships as a core template (generic)
with the operator supplying gather tools + models via overlay.
