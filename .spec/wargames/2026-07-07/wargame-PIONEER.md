# Prior-Art War-Game: Is pg-ai-stewards' "customer knowledge engine" pioneering?

Research sweep conducted 2026-07-06. Question posed: Michael built pg-ai-stewards
(corpus → LLM-extracted entity graph "world" → 3D viz + auto-generated wiki +
graph-grounded chat) for personal/lore use. He's scoping a pitch for a workplace
"customer knowledge engine" — same pattern applied to internal company knowledge
about customers, framed as serving Boyd's OODA **Orient** step, with the specific
twist of surfacing SEAMS (where sales/support/product understand the same
customer differently) rather than just merging everything into one blended view.

Status: research complete — five parallel research passes plus a direct fetch
on the New Stack article. Verdict below; detailed evidence in sections 1-6.

---

## VERDICT

**(a) Corpus → lore/world extraction (LLM reads unstructured text, builds a
typed entity/relationship graph):** **ADJACENT-EXISTS, trending CROWDED.**
Microsoft GraphRAG (2024) and its descendants (LightRAG, nano-graphrag) proved
the extraction pipeline is standard practice. It is now shipping as a
product feature in named, funded, dated competitors: **Enterpret 2.0**
(2025-10-27, "Customer Knowledge Graph" from support tickets/calls/reviews)
and **Glean's Enterprise Graph** (Fall 2025, auto-infers people/projects/
customers/products from unstructured org documents). Nearest neighbor:
**Enterpret** for the customer-specific case, **Microsoft GraphRAG** for the
general technique. Do not pitch the extraction step as the novelty.

**(b) Seam-finding between team understandings (surfacing, not resolving,
where Sales/Support/Product disagree about the same customer):** **PIONEER.**
Every product surveyed across enterprise search (Glean, Rovo, Notion AI, Work
IQ), enterprise KM (Guru), CDPs (Segment, Amperity, Salesforce Data Cloud),
VoC (Medallia, Qualtrics, Chattermill), and feedback intelligence (Enterpret)
is architecturally committed to the *opposite* move — merge, dedupe,
survivorship rules, "single source of truth," "same verified truth
everywhere." The nearest neighbor is a niche of AI-support-KB "conflict
detection" (Fini, Alhena) that flags document-pair contradictions — but even
there the goal is resolution and cleanup, never durable exposure of *whose*
model a belief belongs to. No product found treats inter-team divergence as
the valuable, persistent output. This is the one genuinely open finding of
the entire sweep.

**(c) The Boyd/OODA "Orient" framing (explicit positioning as
orientation-maintenance software):** **PIONEER at the branding layer, with two
named neighbors at the capability layer.** Almost no one has built a
mainstream product that explicitly claims to serve Boyd's Orient step — the
lone exception is the obscure, single-author **Mitopia** (Mike Prince). The
lineage that owns "Orient" conceptually (Chet Richards / *Certain to Win* /
the Boyd-DNI community) treats orientation as tacit human/cultural judgment
that resists automation, and never built tooling. Nearest capability
neighbors: **Palantir Foundry's Ontology** (architecture — org as a shared
model humans act on) and **Cognitive Edge's SenseMaker** (value prop —
surfacing how the same situation is interpreted differently across many
people, via self-signified narratives). Neither is Boyd-branded; both are
worth naming in the pitch as "closest, and here's why we're different."

**(d) Agent-governed knowledge freshness (keeping the extracted graph current
as new documents arrive without full, expensive rebuilds):** **ADJACENT-EXISTS,
CROWDED as an open problem.** This is a loudly acknowledged, actively-worked
pain point, not unclaimed territory: microsoft/graphrag issue #741 (opened
2024-07) documents Microsoft's own incremental-indexing design (append,
selective community re-summarization, drift thresholds); GraphRAG 1.0 shipped
diff-based incremental indexing; LightRAG markets incremental updates with no
full community-restructuring cost as its headline advantage. The generalizable
lesson: the expensive part isn't re-extracting entities (caching handles that)
— it's the community/summary layer recomputing on drift. An architecture that
leans on wiki+graph as primary surfaces (rather than GraphRAG-style community
summaries) is structurally cheaper to keep fresh — which favors Michael's
"worlds" pattern, but the *problem itself*, and the fact that it's expensive,
is well-trodden ground Michael should cite rather than claim to have
discovered.

### Three things worth stealing from prior art

1. **SenseMaker's "the average matters less" design principle** (Cognitive
   Edge/Dave Snowden) — build the divergence-surfacing UI to actively resist
   collapsing into a mean/majority view. Concretely: don't ship a single
   "customer health score" per account; ship a distribution/landscape view
   where clusters of differing team narratives are the primary visual object,
   the way SenseMaker's "narrative landscapes" work. This is a direct,
   battle-tested UI pattern for the one feature nobody else has.

2. **GraphRAG's hierarchical community-summary layer (Leiden + map-reduce
   global search).** Michael's per-entity wiki pages answer "who/what is this
   node," but they don't naturally answer portfolio-level sensemaking
   questions ("what pattern cuts across our top 20 accounts?"). That's
   GraphRAG's actual innovation and it's a proven technique worth borrowing
   for a "themes across all customers" view, layered on top of (not instead
   of) the wiki.

3. **LightRAG's / GraphRAG 1.0's incremental-update discipline** (place new
   entities into existing communities without full Leiden recompute; only
   re-summarize what actually changed; explicit drift thresholds before a full
   rebuild) — steal the *design discipline*, not necessarily the algorithm:
   decide up front which parts of a "world" cheaply update per-document
   (entity pages) versus which parts are expensive and should be recomputed on
   a schedule/threshold (cross-account theme summaries, community structure).
   Naming this tradeoff explicitly in the pitch preempts the "how do you keep
   this from going stale" objection before it's asked.

### The 1-2 claims Michael can honestly make as novel

1. **"We surface where your teams disagree about a customer instead of
   merging their views into one profile."** This is the one claim with zero
   found prior art across enterprise search, enterprise KM, CDPs, VoC, and
   feedback-intelligence tooling — all of which are built, by explicit design
   philosophy (Palantir's "rule of three," CDP survivorship rules, Guru's
   "same verified truth everywhere"), to do the opposite. It is also the
   hardest sell, because a decade of "single source of truth" marketing has
   trained buyers to want unification — so the pitch needs to make the case
   for *why divergence is signal*, not assume it's obviously wanted.

2. **"We built this as a general-purpose personal knowledge substrate first
   ('worlds' for lore/fandom), and the customer-knowledge engine is one
   instantiation of an already-working four-surface pattern (auto-wiki + 3D
   graph + grounded chat, all from LLM-extracted entities) — not a
   feedback-analytics product with a graph bolted on."** No competitor
   (Enterpret, Glean, GraphRAG-family tools) ships all four surfaces together;
   they each ship one or two. Framed honestly, this is a claim about the
   *shape and maturity of the underlying substrate*, not about inventing
   entity extraction — which the research shows is real, working, and already
   proven on an unrelated domain before being pointed at customers.

---

## 1. Microsoft GraphRAG + descendants (corpus → entity graph pattern)

**Original GraphRAG.** Edge, Trinh, Cheng, Bradley, Chao, Mody, Truitt, Metropolitansky,
Ness, Larson (Microsoft Research), "From Local to Global: A Graph RAG Approach to
Query-Focused Summarization," arXiv:2404.16130 (April 2024;
https://arxiv.org/abs/2404.16130). Open-sourced via Microsoft Research blog,
2024-07-02 (https://www.microsoft.com/en-us/research/blog/graphrag-new-tool-for-complex-data-discovery-now-on-github/;
repo https://github.com/microsoft/graphrag). Pipeline: chunk documents → LLM
extracts entities + typed relationships per chunk → merge duplicates → LLM
writes a summary per node/edge → hierarchical **Leiden** community detection →
LLM writes a report-style summary per community at each level → query-time
**map-reduce global search** (each relevant community summary answers
independently, then combines) or entity-anchored **local search**.

The front half — corpus → chunk → LLM-extracted typed entity/relationship
graph — is essentially identical to the "worlds" pipeline. The back half
diverges hard: GraphRAG's deliverable is **community summaries feeding a Q&A
pipeline** — a retrieval backend, not a product. It ships no browsable
per-entity wiki and no visualization. GraphRAG is optimized for "answer a hard
global sensemaking question"; Michael's worlds are optimized for "explore and
inhabit the knowledge."

**LazyGraphRAG** — Microsoft Research blog, 2024-11-25
(https://www.microsoft.com/en-us/research/blog/lazygraphrag-setting-a-new-standard-for-quality-and-cost/).
Solved original GraphRAG's brutal upfront indexing cost (widely cited at tens
of thousands of dollars per corpus, since every node/edge/community gets an
LLM summary before a single query is asked) by deferring almost all LLM work
to query time: index-time uses cheap NLP noun-phrase extraction instead of LLM
extraction (no pre-summarization, no upfront embeddings — index cost ≈ plain
vector RAG, ~0.1% of full GraphRAG); query-time blends best-first and
breadth-first search with an LLM relevance-test budget, summarizing only the
chunks that survive. Claimed >700× lower query cost than GraphRAG global
search at comparable quality. Since folded into Microsoft Discovery (agentic
science platform) and Azure Local (public preview, June 2025). Relevance: this
is the industry's clearest admission that eager graph-building is expensive —
but Michael's wiki + 3D surfaces *require* the materialized graph to persist,
so full laziness is the wrong tradeoff for his use case (the graph is the
deliverable, not a means to an answer). Worth citing in the pitch precisely to
show the cost tradeoff was considered and consciously rejected.

**Named descendants/variants:**
- **LightRAG** (Guo, Xia, Yu, Ao, Huang, HKU Data Intelligence Lab, arXiv:2410.05779,
  Oct 2024; https://lightrag.github.io/). Dual-level retrieval (entity detail +
  thematic) and a built-in **incremental update algorithm** that adds new data
  with minimal API calls and no full community re-restructuring.
- **nano-graphrag** — minimal (~1,100-line) reimplementation that became the
  de facto research baseline (LightRAG itself descends from it).
- **Neo4j GraphRAG, deepset/Haystack GraphRAG, FalkorDB** — graph-DB vendors'
  GraphRAG integrations; still backends, not products.
- **GraphRAG Workbench** (Christopher Lyon, https://github.com/ChristopherLyon/graphrag-workbench,
  covered by BrightCoding 2026-06-30) — the closest single artifact to
  Michael's front-of-house: renders an interactive **3D** knowledge graph
  (Next.js + React Three Fiber/Three.js) with community-colored boundaries,
  centrality-based node sizing, live search, PDF drag-and-drop ingestion, and
  a **grounded chat** interface. Graph + 3D + chat — but no wiki, and a small
  (~4-commit) project.
- **GraphRAG Visualizer** (noworneverev, https://github.com/noworneverev/graphrag-visualizer) —
  2D/3D exploration of GraphRAG artifacts, local-only; visualization only, no
  chat, no wiki.
- **LLM Wiki** (nashsu, https://github.com/nashsu/llm_wiki, https://llm-wiki.app/) —
  **not** GraphRAG lineage, but the closest artifact to Michael's *wiki*
  surface: ingests documents and incrementally builds a persistent,
  self-maintaining, Wikipedia-style knowledge base — one entity/concept page
  per file, `[[wikilinks]]` cross-linking, index/overview/log pages, plus a
  knowledge-graph visualization with link-topology clustering. Explicitly
  positioned against "retrieve-and-answer-from-scratch RAG" — the wiki itself
  is the durable deliverable.

**No single artifact does graph + wiki + 3D + chat together** — Workbench has
graph+3D+chat, LLM Wiki has graph+wiki, and they're different lineages. That
four-surface integration is genuinely Michael's.

**Freshness / staleness — a loudly acknowledged pain point.** microsoft/graphrag
issue #741, "Incremental indexing (adding new content)" (opened 2024-07;
https://github.com/microsoft/graphrag/issues/741): Microsoft's response was a
`graphrag.append` command that tries to place new entities into *existing*
communities rather than re-running Leiden, and **only re-summarizes communities
whose membership changed** — with configurable drift thresholds before a full
recompute. Explicitly out of scope initially: document deletion, manual graph
edits, delta-query tagging. Community discussions (#511, #1313) confirm the
core tension: caching skips re-extracting existing docs, but new nodes/edges
still force graph reconstruction, which cascades into community
recomputation/re-summarization — the genuinely expensive part. GraphRAG 1.0
(https://www.microsoft.com/en-us/research/blog/moving-to-graphrag-1-0-streamlining-ergonomics-for-developers-and-users/)
shipped incremental indexing that diffs against new content. LightRAG markets
its incremental algorithm explicitly against this cost. **Lesson for Michael:**
the expensive part isn't entity re-extraction, it's the community/summary
layer recomputing on drift — an architecture leaning on wiki+graph as primary
surfaces (like LLM Wiki) is cheaper to keep fresh than one leaning on
GraphRAG-style community summaries.

**Applied to internal customer data.** Microsoft's own Azure AI Foundry blog
pitches combined RAG for financial-services CRM/risk: standard RAG for
transaction history, Graph RAG for relationships among customers/accounts/
transactions
(https://techcommunity.microsoft.com/blog/azure-ai-foundry-blog/unlocking-insights-graphrag--standard-rag-in-financial-services/4253311).
Lettria and other vendor write-ups cite customer-support use (pulling
subscription history + usage + prior tickets; one case claims 40% faster
resolution). An academic case study (arXiv:2509.14267, 2025) combines
e-commerce domain graphs with support-archive retrieval. The Customer 360
graph-database category (Neo4j, PuppyGraph, Salesforce Data 360, Precisely
Spectrum Context Graph) is squarely adjacent — **but every one of these states
its goal as collapsing team perspectives into "a single source of truth" so
teams stop debating whose data is right.** That is the exact inverse of
Michael's thesis. No prior art was found doing multi-perspective /
conflicting-view / per-team-lens customer graphs — this appears to be
genuinely open ground.

**Verdict on this thread:** extraction backbone (corpus→graph) is solved and
Microsoft-blessed — ADJACENT-EXISTS, lean on it as de-risking. The four-surface
integrated product (graph+wiki+3D+chat) is unbuilt in any one place — closer to
PIONEER at the product layer. The divergence-preserving thesis has zero found
prior art in this GraphRAG/Customer-360 space.

---

## 2. Enterprise knowledge/search products — does ANY do cross-team seam-finding?

**One-line verdict:** No. Every product below is architecturally committed to
the opposite move — collapsing multiple sources into one authoritative
answer/profile (merge, dedupe, survivorship, "verified truth," "single source
of truth"). The closest prior art is a small "conflict-detection" sub-category
in AI *support* knowledge bases (Fini, Alhena) — but even there, conflict is a
document-pair defect to clean up, never a durable signal that teams hold
divergent mental models.

- **Glean** — its Knowledge Graph connects people↔content↔interactions for
  permission-aware relevance ranking and expertise discovery (100+ connectors,
  mirrors source-app permissions in real time). Some account-level entity
  awareness exists (e.g., filter by `account:"Acme Corporation"`), but it's a
  relevance-and-permissions graph, not a per-customer semantic model that
  reasons about what each team believes. Glean's own writing treats
  contradictory sources as a *quality problem to curate away*: "the risk of AI
  hallucinations increases if the AI finds conflicting documents"
  (https://www.glean.com/blog/context-engineering-ai-the-foundation-of-reliable-high-performing-models).
  No seam-finding.

- **Microsoft Work IQ** (real, verified — announced Ignite 2025-11-18, APIs GA
  ~2026-06-16, alongside Fabric IQ and Foundry IQ) is purely aggregative:
  "unifying data with analytics," "single API," "unifies and centralizes
  access to knowledge" (https://cloudwars.com/ai/microsoft-debuts-work-iq-fabric-iq-and-foundry-iq-a-unified-intelligence-layer-for-the-ai-powered-enterprise/).
  Zero discussion of surfacing conflicting/divergent understanding anywhere in
  the announcement material. **Viva Topics** — Microsoft's earlier
  auto-generated-topic-page product, the closest Microsoft precedent to
  Michael's auto-wiki — was retired (feature investment stopped 2024-02-22,
  full retirement 2025-02-22); it only ever aggregated/summarized per topic,
  never surfaced inter-team disagreement, and Microsoft walked away from it in
  favor of folding knowledge into Copilot.

- **Atlassian Rovo + Teamwork Graph** (GA 2024, ~150B connections) breaks silos
  via a unified graph across Jira/Confluence/Loom/Slack; explicit goal is
  **alignment/consistency** ("engineers and stakeholders always see the same
  information"). Third-party best-practice guidance says Rovo *depends on you
  removing conflicts first*: "if your Confluence spaces are a mess of...
  conflicting information, Rovo will struggle" (k15t.com) — conflict is a
  precondition to eliminate, not an output.

- **Notion AI** Enterprise Search/Q&A "synthesizes concepts" across sources
  into one concise answer. Per a competitor comparison (Fini Labs, vendor
  claim, directionally consistent with Notion's own framing): "Notion AI
  blends conflicting sources without flagging." Synthesis actively hides the
  seam by design.

- **Guru** is the closest of the big names, but still not it. Its newer
  marketing claims AI "detects redundant and conflicting content across
  sources **and reconciles it**," "propagates fixes everywhere — giving every
  tool **the same verified truth**" (https://www.getguru.com/solutions/km-automation).
  Read the verbs: reconcile, propagate, same-truth-everywhere. Guru detects
  conflict in order to eliminate it, not to keep it visible — its actual
  mechanism is SME verification/freshness (expert re-confirms a card on a
  schedule; stale unverified cards auto-archive), not "Sales and Support hold
  contradictory models of Acme."

- **CDPs / Customer-360** (Segment, Amperity, Bloomreach, Tealium, Salesforce
  Data Cloud) are the strongest counter-example: identity resolution explicitly
  applies **survivorship rules** — "prioritizing the most recent data, the most
  frequently occurring value, or the most reliable source" — to pick one
  winning value when sources disagree, then discards the disagreement.
  Salesforce Data Cloud's "unified profile ≠ golden record" framing is the one
  partial nuance: it preserves per-source **lineage** ("isn't mastering or
  overwriting your data... allowing you to trace insights back to their
  source") rather than silently overwriting
  (https://admin.salesforce.com/blog/2025/rethinking-golden-record-advantages-of-data-cloud-unified-profile).
  But this is field-level provenance/audit (which system said the billing
  address was X), not qualitative narrative seam-finding across prose
  documents — a different layer entirely from Michael's target.

**The real prior art, off the original list:** a niche of **AI customer-support
knowledge-base tools** — **Fini** (usefini.com) and **Alhena** — explicitly
ship "conflict detection": Fini's reasoning layer "compares claims across
sources, flags conflicts to a human reviewer, and refuses to answer until the
contradiction is resolved," producing a "conflict report listing every article
pair that disagrees." This is the closest anyone comes to proactively
detecting contradiction rather than blending it — **but** the goal is
resolution (deprecate the wrong article, converge to one truth), the unit is
document-pairs, and **no vendor attributes conflict to a team** (Sales vs.
Support vs. PM) or treats divergence itself as the valuable, persistent output.
There is academic research on the adjacent problem ("Are you with me? A
Framework for Detecting Mental Model Discrepancies in Task-Based Team
Dialogues," arXiv:2605.03149; org-psych work on "Divergent Mental Models as a
Trigger of Team Adaptation") — so the concept is a studied research problem,
just not a shipped customer-knowledge feature.

**Verdict on this thread:** cross-team seam-finding — surfacing (not
resolving) where two teams' understanding of the same customer conflicts — was
not found anywhere in the enterprise-knowledge-tool market. This is
Michael's cleanest and most defensible differentiator.

---

## 3. Palantir Foundry's Ontology — the strongest prior art for org-as-entity-graph?

**Bottom line:** Palantir decisively owns the general idea of "the org modeled
as an entity/object graph." But Foundry's Ontology is **top-down,
schema-first, and structured-data-driven**; its graph view is a
**user-assembled 2D canvas**, not an auto-rendered 3D viz; its per-entity pages
are **human-configured Workshop views**, not an auto-generated prose wiki; and
its governing philosophy is explicitly **single-canonical-truth** — the
opposite of seam-finding.

**What the Ontology is:** object types (schema for an entity/event), properties,
link types (schema for relationships — function like dataset joins), action
types (bundles of edits + side effects — the "kinetic," write-back half),
functions (incl. LLM-driven), interfaces (polymorphism). Palantir frames it as
semantic (objects/properties/links) + kinetic (actions/functions/dynamic
security), calling the whole thing "the digital twin of an organization."
(https://www.palantir.com/docs/foundry/ontology/overview,
https://www.palantir.com/docs/foundry/architecture-center/ontology-system)

**Top-down, not bottom-up — this is the crux, and it's unambiguous.** A human
(data engineer/domain expert) defines object/link types in the low-code
"Ontology Manager" (or via TypeScript/Python SDK), then maps existing
*structured* datasets into that predefined schema. An independent developer
walkthrough confirms: "The process is entirely schema-first: humans design the
structure... then data engineers map existing datasets into this predefined
ontology framework" (Jimmy Wang, Medium:
https://medium.com/@jimmywanggenai/palantir-foundry-ontology-3a83714bc9a7).
Object *instances* populate automatically from data; object *types* (the
graph's shape) are always human-authored. That is the exact inversion of
GraphRAG / Michael's worlds, where an LLM discovers both the taxonomy and the
instances from raw prose.

**LLM-driven extraction from unstructured text — still mostly roadmap as of
Feb 2026.** Palantir's dated Foundry announcement
(https://www.palantir.com/docs/foundry/announcements/2026-02, 2026-02) lists
"Entity extraction from documents" — pulling identifiers, values, dates,
"custom domain concepts" directly from documents to populate Ontology objects
— as **in development, not yet available**, and even then it populates
*human-predefined* object types rather than discovering the schema. AIP Logic
(the LLM-function builder) already connects unstructured input to the
Ontology, but again into a pre-existing schema; the dominant AIP paradigm is
"Ontology-Augmented Generation" — the human-built ontology feeds context to
the LLM, the reverse of the LLM building the ontology.

**No auto 3D graph, no auto-generated wiki.** Foundry's graph-visualization
surface, **Vertex**, is a 2D canvas users manually assemble node-by-node via
"Search Around" — not an automatic whole-graph render. A Palantir community
thread ("True Knowledge Graph Capabilities," community.palantir.com) has a
user reporting that building a KG required two Ontology objects
(Entity+Relationship) plus custom LLM parsing, and that in Vertex the result
"felt very crude... not a real KG." Default Object Views auto-generate per
object type, but they're templated property dumps — rich per-entity pages are
manually configured in Workshop, not auto-written prose.

**Single canonical truth is doctrine, not an accident.** Palantir's own
"Ontology design best practices" state the goal outright: "a single canonical
representation for each concept... with a single canonical workflow for each
operation on that concept," and its "rule of three" treats near-duplicate
team-specific object types (the worked example is literally `Sales Customer` /
`Support Customer` / `Billing Customer`) as a "maintenance burden" to be
**consolidated into one `Customer`** — different team needs handled by
security scoping/filtering over the *one* model, never by modeling the
divergence itself. "How different teams understand the same customer
differently" is not a Foundry gap; it is a defect Palantir's own methodology
prescribes refactoring away.

**Verdict on this thread:** Palantir owns "org as ontology" generally, and
goes far beyond Michael on the *kinetic/write-back* axis (functions, actions,
running the business on the graph) — any pitch should concede that fully.
But on the specific combination Michael cares about — bottom-up LLM schema
discovery from unstructured corpus + auto-wiki + auto 3D graph + multi-team
seam-finding — Foundry does none of the four, and the fourth it explicitly
rejects by design philosophy. (Note: the truer prior art for axis #1 alone,
bottom-up extraction, is GraphRAG/the KG-from-documents lineage — see §1 — not
Palantir. Michael's distinctive claim is the whole stack together, not any one
piece.)

---

## 4. Customer-understanding practice — CDPs, VoC, JTBD, research repos

**Closest existing category: B2B customer-feedback intelligence — and the
single closest product is Enterpret.** This is the most important single
finding of the whole sweep and updates the picture from §1–3: the extraction
mechanism (LLM reads unstructured customer-facing text → linked entity graph)
is *commoditizing*, not novel by itself. Two live, dated products prove it:

- **Enterpret 2.0** (announced 2025-10-27) ships a **"Customer Knowledge
  Graph"** that "connects every signal to the right customer, account, and
  product, even mapping it to revenue impact," plus an **Adaptive Taxonomy**
  (auto-classifies feedback with no manual tagging, evolves with the
  product's own language), **Wisdom** (an AI insights engine over millions of
  feedback records), AI agents that monitor sentiment and escalate, and an
  **MCP server** so you can chat over the graph from Claude/Cursor — plus a
  roadmapped Knowledge Graph *visualization* layer.
  (https://www.enterpret.com/blog/enterpret-2-the-foundation-for-customer-intelligence,
  https://www.businesswire.com/news/home/20251027487140/en/). It ingests
  exactly the cross-team unstructured sources Michael names (tickets, calls,
  reviews, posts) and does LLM/ML entity extraction into a linked graph tied
  to accounts and revenue — that is the extraction+graph+chat core of
  Michael's idea, already shipping.
- **Glean's Enterprise Graph** (launched Fall 2025 — this refines/updates the
  Glean read in §2, which focused on the permission/relevance graph; this is a
  separate, newer capability) "builds these graphs entirely using machine
  learning... automatically inferring entities" — people, projects,
  **customers**, products — from unstructured org documents across 100+
  connectors, then serves chat over it
  (https://www.glean.com/product/enterprise-graph,
  https://www.glean.com/press/glean-introduces-third-generation-ai-assistant-new-enterprise-graph-to-enable-the-superintelligent-enterprise).

So "LLM reads unstructured documents and builds a linked, chattable entity
graph" is not novel in 2026 — it is becoming a category, with named, funded,
shipping competitors. **Neither Enterpret nor Glean's Enterprise Graph builds
an auto-generated wiki**, and neither surfaces cross-team divergence (both are
pitched as "one connected source of truth").

**The rest of the landscape, surveyed for comparison:**

- **CDPs (Segment, Amperity, mParticle/Rokt, Tealium)** model **structured,
  behavioral** customer data — identity-resolved profiles, event streams,
  traits, ML-scored propensity/churn/LTV. No qualitative "who is this customer
  really" narrative layer. The one narrative-adjacent feature is ephemeral
  agent-assist call summaries (Segment Flex CustomerAI); Segment's 2025 "Linked
  Profiles" (B2B Edition, launched at SIGNAL 2025-05-14/15) builds a graph of
  relationships across accounts/products/households, but via **structured
  join-key linking**, not LLM extraction from unstructured documents.
- **VoC platforms (Medallia, Qualtrics XM, InMoment)** stay at
  survey/sentiment/text-analytics; none builds a wiki or per-account entity
  graph. (The category is consolidating, not innovating: InMoment folded into
  Press Ganey Forsta, Qualtrics announced acquiring Forsta, Medallia changed
  ownership April 2026.) Newer B2B feedback-intelligence tools — **Chattermill**
  (Lyra AI driver-attribution), **Unwrap.ai** ($12M Series A, Jan 2025,
  zero-shot feedback auto-tagging) — do theme/driver extraction, not
  per-account knowledge graphs.
- **JTBD** is a practice, not a tool category — no shipped "living JTBD
  knowledge base" with entity extraction exists; JTBD lives as a framework
  inside roadmap tools (Aha!, ProductPlan) or standalone template/course
  products (Strategyn, JTBD Research App). Effectively empty ground.
- **User research repositories (Dovetail, Marvin, Condens, Aurelius)** are the
  closest in *spirit* but stop at researcher-controlled tagging + semantic
  search/Q&A. Dovetail is the frontier ("Dovetail Magic": AI Chat & Search, AI
  Analysis, beta AI Agents/Docs/Dashboards) with strong evidence-traceability
  (every AI theme links to source quote/video) — but its own marketing states
  themes are researcher-validated/merged, i.e., AI-assisted tagging, not
  automatic entity/relationship graph construction, and no auto-wiki.
  (EnjoyHQ's current ownership/status could not be cleanly verified this
  session — flagged, not asserted.)

**Divergence between teams remains genuinely unoccupied here too.** Every
vendor across CDPs, VoC, and research repos sells unification ("single source
of truth," "unified profile," even Enterpret's own pitch is "one connected
source of truth"). The RevOps/alignment literature *names* the underlying pain
— a Mural GTM Alignment study found 85% of teams report ongoing misalignment
even while 85% feel confident (https://www.mural.co/blog/gtm-alignment-gap-research-study)
— but the prescription is always "put everyone on one platform to eliminate
the gap," never "model the gap as data and show it."

**Verdict on this thread:** the extraction+graph+chat core is commoditizing
(Enterpret, Glean Enterprise Graph are live proof) — that part of the pitch
should not be sold as novel. The auto-wiki surface is a real but modest
product-surface gap. The divergence lens — rendering disagreement instead of
merging it — is the one claim in this entire category with no found
competitor, anywhere, because it runs directly against the "single source of
truth" premise the whole market is built on.

---

## 5. Boyd/OODA in business KM literature + Weick/Cynefin adjacent framings

**Bottom line:** the **branding** — software explicitly built to serve Boyd's
"Orient" step — is nearly uncontested naming space. The **underlying
capability**, though, has two strong neighbors: **Palantir** (nearest to the
*architecture*, and it literally crossed from an intelligence
common-operating-picture into enterprise — see §3) and **Cognitive Edge's
SenseMaker** (nearest to the specific *value prop* of surfacing multiple
people's differing narratives about the same situation).

**Has anyone built a named "Orient step" tool?** Almost no one. The lone
explicit claim is **Mitopia® (Mike Prince, MitoSystems)** — fetched directly —
arguing the Orient step must be automated in software: "without automating
this step within a system, it will be difficult if not impossible for human
beings to keep up with ongoing events... Current generation information
systems and design techniques fail to adequately address even the integration
step required to 'orient'" (https://mitosystems.com/boyds-ooda-loop/). Niche,
single-author, little market presence — but proof the thesis has been written
down before. **OODAx** (launched ~2024-11-01) is a growth-consultancy named
after the loop, not a software tool. Everything else found (Visual Paradigm,
RTI Connext, TechTarget/Creately/Miro explainers) is either a diagramming
template or generic "OODA-loop-as-metaphor" content, not orientation software.

**Chet Richards / *Certain to Win* / the Boyd (DNI) lineage — deliberately
resists the software framing.** Richards' book (*Certain to Win: The Strategy
of John Boyd, Applied to Business*) is the founding text translating Boyd to
corporations (Toyota, Southwest, Dell, GE, Disney cases). In a direct
interview (oodaloop.com, fetched), Richards frames orientation as human and
cultural, not automatable: a leader's job is "to try to get everybody's mental
models to make better predictions" — almost verbatim Michael's "shared
orientation" thesis, but planted in human leadership (*Fingerspitzengefühl*,
*Einheit*, *Auftragstaktik*), not software. The Boyd Conference / DNI community
(d-n-i.net) is a strategy-theory community; no KM tooling emerged from it.
This is double-edged for the pitch: it legitimizes "shared orientation" as
real, serious work, but the people who own the term would likely object that
software can't do it — Michael's answer has to be the same one Mitopia makes
(data volume now exceeds what humans can hold unaided; the tool scaffolds
orientation, it doesn't replace it).

**Weick's sensemaking — theory, not tools.** No software emerged directly from
Weick's lineage (*Sensemaking in Organizations*, 1995; the seven properties).
Newer tools loosely borrow the *label* ("sensemaking") without the lineage:
Google Jigsaw's Sensemaking Tools (Gemini-based conversation summarization),
Go Vocal's Sensemaking (citizen-input analysis for local government), SAGE3
(collaborative spatial reasoning). None traces to Weick specifically.

**Cynefin / Dave Snowden's SenseMaker — the closest real "seam-finding" prior
art found in this entire sweep.** SenseMaker is a mature, real product:
respondents tell short self-signified "micro-narratives," then interpret their
*own* story against a designed "signification framework" (triads/dyads),
aggregating into quantitative data while stories carry qualitative context.
Snowden calls it "the world's first distributed ethnography tool," grounded in
anthropology/neuroscience/complexity theory. Crucially, its explicit design
goal is divergence, not consensus: "SenseMaker was designed to go beyond the
average or typical experience and purposefully consider unusual trends;
uncovering differing perspectives and views is encouraged, the average matters
less" (tonyquinlan.com). It visualizes clusters/outliers/"narrative
landscapes" showing how the same situation is interpreted differently by
different people — functionally the same seam Michael wants to surface.
**The differentiator:** SenseMaker is a *survey/self-signification
instrument* — humans tag their own stories against a pre-built framework.
Michael's engine is *extraction-first*: an LLM reads artifacts people already
produced (tickets, notes, docs) with no survey step, plus 3D viz, auto-wiki,
and graph-grounded chat. Same goal (surface divergent understanding of a
shared situation), different mechanism and no survey friction.

**Common Operational Picture (COP)** — military C2/battle-management
vocabulary ("what I see, you see") that has crossed into commercial situational
awareness (Coolfire, Hexagon, Esri ArcGIS, Leidos; even Power BI gets framed
this way). Conceptually adjacent to "shared orientation," but overwhelmingly
spatial/GIS/real-time-feed — a dashboard of the present, not an entity graph of
understanding. Weaker as direct prior art than SenseMaker or Palantir, but
useful adjacent vocabulary ("common picture") if Michael wants a phrase a
skeptical exec will recognize.

**Verdict on this thread:** the Orient-step *branding* is close to open ground
(only Mitopia claims it, and obscurely). The *capability* has two named
neighbors worth citing by name in the pitch: Palantir (architecture) and
SenseMaker (value prop) — and Michael's engine sits in neither one's lineage,
combining LLM extraction with both.

---

## 6. The New Stack article: "Karpathy, Google and Garry Tan agree Markdown is the answer, but they're not solving the same problem"

Source: Janakiram MSV, *The New Stack*, published 2026-07-06.
https://thenewstack.io/markdown-agent-memory-moat/

**The actual argument.** Three separate parties converged on the same surface
form — a folder of Markdown files, versioned in git — for three different
problems, and the article's thesis is that the *convergence on format* is
masking a *divergence in purpose*. The real "moat" claim: as models commoditize,
the durable competitive asset shifts from "which model do you use" to "which
Markdown corpus your team/agent has accumulated" — because that corpus is
portable across clouds, models, and frameworks, while a proprietary vector DB
or vendor-locked knowledge index is not.

The three parties, per the article:

1. **Andrej Karpathy — "LLM Wiki"** (GitHub gist, published April 2026:
   https://gist.github.com/karpathy/442a6bf555914893e9891c11519de94f). A personal
   knowledge-base pattern: an agent keeps what it knows as linked Markdown files
   it can read and rewrite, on the premise that an LLM doesn't get bored
   maintaining cross-references and can touch fifteen files in one pass — a
   problem a human curator would tire of. This is solving **personal agent
   memory / a personal second brain**, one user, one corpus, low stakes if a
   cross-reference goes stale.

2. **Google — Open Knowledge Format (OKF)**, announced by Google Cloud
   2026-06-12 (https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing/,
   also covered by MarkTechPost 2026-06-16). OKF v0.1 formalizes the LLM-wiki
   pattern into a *spec*: a directory of Markdown files with YAML frontmatter
   (only required field: `type`), two reserved filenames (`index.md` for a
   listing, `log.md` for change history), and ordinary markdown links between
   files — making the directory a **graph**, not a flat list. Google ships an
   enrichment agent that walks a BigQuery dataset, drafts an OKF concept
   document per table/view, then runs a second LLM pass that crawls
   authoritative docs and enriches each concept with citations, schemas, and
   join paths. This is solving **enterprise data-catalog context for agents** —
   many users, structured/tabular source data, the goal is agents not
   re-deriving the same schema knowledge over and over.

3. **Garry Tan — gstack** (https://github.com/garrytan/gstack), an MIT-licensed
   pack of 23 opinionated Claude Code skills (CEO, Designer, Eng Manager,
   Release Manager, Doc Engineer, QA, etc.), each a Markdown file with no
   runtime — "just prose that runs across ten different coding agents." Tan's
   own memory component inside gstack is **GBrain**: a persistent knowledge
   base the skill registers as a federated source (`gbrain sources add`,
   `gbrain sync --strategy code`), writing search guidance into the project's
   CLAUDE.md so the agent prefers `gbrain search` / `code-def` / `code-refs`
   over grep. This is solving **summoning a simulated engineering team from a
   terminal** — role/process knowledge, not customer or data knowledge.

**Why this matters for the war-game question.** The article is direct evidence
that "Markdown-as-linked-graph-of-files" is *already* a converged-upon,
multi-party pattern in mid-2026 — Karpathy for personal memory, Google for
enterprise data catalogs, Tan for team-role simulation. None of the three is
about **customers**, and none of the three does **LLM entity/relationship
extraction from unstructured narrative text** the way pg-ai-stewards' "worlds"
pipeline does — OKF's enrichment agent drafts *concept docs per known schema
object* (a table, a view), it does not extract a graph of *entities and
relationships* from free-text documents the way GraphRAG-style extraction does.
The pattern most structurally close to "worlds" (files-as-a-graph, `index.md`
as an auto-generated wiki front page) is OKF — but OKF's population step is
schema-enrichment, not entity-graph extraction from prose, and none of the
three surfaces disagreement between authors/teams.

---
