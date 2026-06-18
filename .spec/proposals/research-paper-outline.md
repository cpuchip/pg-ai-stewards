# pg-ai-stewards — research paper outline (working draft)

**Status:** working draft, 2026-06-17. Genre decision + framing fork are Michael's
(see §6). Client/operator specifics stay out of any public draft — case-study
references are generic ("a private business-analysis intent").

---

## 1. Thesis (the contribution statement)

> A relational database can host a **complete, governed, autonomous multi-agent
> runtime** — the dispatch loop, context management, governance, and an
> autonomous intent-pursuit loop all live as relational state and functions
> inside Postgres. Doing so yields **transactional agent state** and **in-situ
> governance** that external-orchestrator stacks (logic in app code, DB as a
> store) structurally lack. We demonstrate the design and report on months of
> unattended autonomous operation.

This is a **systems / experience paper**, not a benchmark-beating method paper.
The contribution is an architecture + a governance pattern + an operational
account, not a new model or a SOTA result. Naming the genre honestly is how the
work avoids the "neat system, no evidence" dismissal.

Scale at time of writing (one operator install): 355 in-DB functions, 90 tables,
48 pipelines, 227 work-items (151 completed), 82 compounding pool docs, 18
verified autonomous reflect-steward cycles, 201 messages carrying extracted
engrams.

## 2. Contributions (ranked by defensibility)

1. **The database *is* the agent runtime ("the DB thinks").** Dispatch,
   tool-permission gates, model resolution + failover, context compaction, and
   the autonomous loop are SQL/PL-pgSQL functions and triggers, not an external
   Python orchestrator over a passive store. Properties this buys: one source of
   truth for memory + dispatch + policy; agent-state mutations are transactional
   with the work they describe; no orchestrator-vs-store drift. **External
   validation:** Databricks' *Omnigent* (2026) independently arrived at the same
   control plane (Postgres store, per-event ALLOW/DENY/ASK gates, cross-vendor
   review, agents-author-agents) — which says the control plane is the shape of
   the problem, while their "orchestrate harness CLIs in Python" design sharpens
   our "the brain is *in* the DB" differentiation.

2. **Graduated, self-accounting autonomy (the governance composition).** A
   bilateral covenant → council-gated capability grants → a watch over delegated
   work → a *deterministic* guard that auto-pauses an autonomous loop on runaway
   (spend / in-flight / failure-streak / backlog), narrow-auto-resumes when the
   breach self-clears, and **accounts** for the force it used. Plus "judges, not
   executors" (surface judgment, let the substrate act) and a recursive presiding
   chain (an agent presides over its sub-agents under the same terms it is
   presided under). Agent governance/safety is hot and under-formalized, so this
   is arguably the *most* novel single idea — a concrete, implementable
   human-AI-delegation pattern that is more principled than a bare cost cap.

3. **The reflect-steward (the worked example).** An autonomous back-office loop
   that pursues an operator intent on a schedule: gather public sources →
   synthesize → propose work → verify → publish to a compounding, deduplicated,
   surveyed knowledge pool. The case study that makes the architecture concrete.

## 3. The memory system — what we have, and what we'd improve from

**What we have (position as adequate plumbing, not a contribution):** a context
engine with extracted *engrams* (structured summaries with provenance pointers
back to raw messages), graduated rendering under token pressure, a judge-compiled
brief for oversized tool output, working-tag fold/expand, and a reversible
`compact_context` verdict. Vector search (pgvector) + a relational graph
(`CITES`, `SIMILAR_TO`) under it.

**The line that is ahead of us — and the honest place to improve from — is the
"organize-then-retrieve" memory work**, exemplified by the *Homer* paper
(Structured AI Memory). Its thesis: agent memory fails because it is an
unorganized pile retrieved by cosine similarity, which ignores causality and
scales linearly in tokens. Instead:

- **Organize-then-retrieve**: experiences are structured into a hierarchy
  (file-system-like tree) *before* retrieval, with summaries that keep
  recoverable provenance links to ground truth.
- **Retrieval as navigation, not similarity**: a small model walks the tree with
  discrete commands rather than a global vector scan — logarithmic, not linear;
  reported ~22% of baseline token usage.
- **Contrastive failure analysis (the engine of improvement)**: when structured
  memory and raw history disagree on an outcome, an LLM explains the *delta* in
  natural language and rewrites the memory-organization rules — "textual gradient
  descent."

**Two concrete adoptions for our engine** (and they slot into what we already
have, rather than replacing it):
- **Contrastive failure logging.** When a retrieval leads to a wrong answer, log
  the raw chunk and the structured summary that was retrieved, feed the delta to
  a judge, and emit a one-line rule update for how engrams are written or refiled.
  Our engine extracts but never *learns from a bad retrieval*; this is the gap.
- **Typed causal edges.** Beyond `SIMILAR_TO` / `CITES`, add `CAUSED_BY` /
  `DEPENDS_ON` / `REFINES` so retrieval can follow causal paths, not just
  similarity neighborhoods — a hierarchical/causal layer *beside* the vector
  store, not instead of it.

Honest counterpoint to carry in the paper: hierarchical navigation is brittle
exactly where vector RAG is robust (fuzzy, cross-domain queries), and contrastive
analysis is computationally circular (the LLM diagnoses the failures of the same
reasoning it is augmenting). So the claim is "add a causal/organized layer," not
"similarity is wrong."

## 4. Related work (the map to position against)

- **Orchestration frameworks** — LangGraph, AutoGen, CrewAI, the Claude Agent
  SDK / OpenAI Agents SDK: logic in application code, DB as a store. Contrast =
  our inversion (logic in the DB).
- **Meta-harness / control plane** — Databricks *Omnigent*: the closest prior
  art and the strongest external validation; same control plane, opposite arrow
  (it dispatches harness CLIs; we dispatch models and the DB holds the loop).
- **Agent memory** — Homer / Structured AI Memory (§3), MemGPT-style paged
  context, generative-agents memory streams, vector-RAG memory. We improve from,
  and cite, the organize-then-retrieve line.
- **Agent governance / safety** — policy-as-code engines (CEL-style gates), tool
  permissioning, cost governance. Contrast = our covenant + self-accounting guard
  + council-gated capability grants (graduated trust, not static policy).
- **Postgres-as-platform** — pgvector, in-database ML, stored-procedure logic,
  pgEdge's query-side MCP. Contrast = a full *agent OS* in the DB, not a query
  surface bolted on.

## 5. Evaluation plan (the gap that decides credibility)

The #1 hole today is the absence of comparison/ablation. A credible draft needs:
1. **DB-resident vs. external-orchestrator** on the same task — measure state
   consistency under failure (kill mid-run; does agent state stay coherent?),
   lines-of-glue, and latency.
2. **Guard ablation** — run the autonomous loop with the deterministic guard
   off vs. on under an induced runaway; show the spend/in-flight blowup it
   prevents. We already have inverse-hypothesis proofs; reframe them as the
   experiment.
3. **Reflect-steward operational curves** — cost per cycle, dedup rate (proposals
   gated as near-duplicates), and the pool-compounding curve over N cycles.
4. **Context-engine token study** — retrieval token cost flat-vector vs. the
   proposed organized/causal layer (the §3 adoptions), against the Homer ~22%
   north star.

Caveat to state plainly: n = 1 operator intent for the autonomous case study.

## 6. The framing fork (Michael's call)

The soul of the project is the covenant, and it is gospel-derived (D&C 121,
Abraham 4, Mosiah). The sharp irony: the governance idea is both the **most
novel** contribution and the **most entangled** with framing a secular venue
would want abstracted. Two paths:
- **Secular systems paper** — abstract the mechanism (graduated autonomy,
  self-accounting guards, council-gated grants), cite the source pattern as
  motivation in one honest paragraph. Broadest reach; strips the soul.
- **Keep the framing** — narrower reception (workshop / self-published /
  cpuchip.net + arXiv as-is), but true, and a natural technical companion to
  *Beyond the Prompt* and the Working-with-AI guide.

The Omnigent convergence is the lead either way. The mechanism can be written to
read legibly in secular terms while staying honest about its source.

## 7. Governance roadmap feeding the paper (the live design threads)

Two near-term steps would *strengthen contribution #2 by being real*, not just
described — and both are about the steward presiding over the **content** of its
own work:

- **Triage / grooming.** Today the steward only *adds* proposals (with a dedup
  gate + a council survey before proposing); it never prunes, ranks, or retires
  its existing backlog, so the queue climbs to the guard cap. A groom step each
  cycle would (a) auto-retire clearly superseded / substance-duplicate pending
  items — the same judgment as the creation-time dedup gate, applied to the
  standing queue, which is safe for the steward to own — and (b) rank the rest by
  value and surface the top few, rather than auto-declining on-substance work.
  This is the concrete form of "the steward should evaluate what's waiting and
  make those judgments."
- **End-of-pipeline self-approval gate (proposed; dominion_in_council).** Let the
  steward *autonomously approve* a **narrow, bounded class** of its own
  completed-and-verified work at the end of the pipeline, instead of every item
  waiting on the human Hinge. The safe boundary is the load-bearing design: the
  steward may self-approve only work that **reads public sources and publishes to
  the internal pool** (no real spend beyond the capped budget, no outward
  publication, no tool-grant growth, no private-data egress); everything that
  spends, publishes outward, or grows capability **stays the human's gate**. The
  deterministic watchman guard remains the floor under it. This is a genuine
  expansion of standing autonomy, so it needs a council moment before building —
  but it is exactly the "graduated trust, earned and bounded" pattern the paper
  argues for, and shipping it turns a described contribution into a demonstrated
  one.

Both connect directly to §2.2: the paper's governance claim is most credible if
the steward visibly presides over its own queue and exercises a *bounded* slice
of autonomy with the guard as the floor and the human as the Hinge on everything
that matters.

---

**Next step (cheap, before committing to full prose):** this outline + the §5
measurements are the hour-long test of whether the paper has legs. Run the four
measurements on the live substrate, decide the §6 framing, then write.
