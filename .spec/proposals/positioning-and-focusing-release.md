# Positioning + the focusing release

> Anchor doc from the 2026-06-24 "Knowledge Engine direction" exploration
> (7-agent workflow: UI audit · capability map · strategy review · competitive
> scan → branding · streamline · red-team). This is the durable record of the
> verdict, the brand frame Michael ratified, and the scope line that keeps the
> next release a *focusing* pass rather than more accretion.

## Verdict (what the exploration found)

- **The engine is genuinely ONE thing at the architecture layer.** Research,
  present, build, lore, and self-learn share real bone: one work-item/pipeline/
  queue spine; doc-build reuses the coder sandbox; personas reuse the same
  docs/graph pool real-world knowledge uses; self-learning composes the same
  gates + Hinge + corpus. Behavior is data. Focus was **not** lost here.
- **Focus WAS lost on the axis the vision names** — install, everyday use, the
  clean-surface/power-tucked split, and a *robust* self-learning loop all got
  near-zero investment while capability breadth got daily-use accretion (the
  "four Rounds in one day" tell). *The builder has been building for the builder.*
- **The rebrand is the reward, not the first task.** The red-team's hard truth,
  kept: renaming is the fun work; the unglamorous on-ramp (legibility, hardening,
  positioning) is the only thing between "an engine I built for me" and "a
  product someone else can adopt."

## Brand frame (ratified by Michael)

**Stewdio — a studio for your worlds. An open knowledge engine that gathers,
builds, and remembers.**

- **Stewdio** = the app/cockpit and the current mark. **Provisional, held loosely**
  (Michael, 2026-06-24): the "stewards' studio / *stew-dio*" pun may stop landing as
  **Worlds** becomes the organizing frame — revisit the name when the Worlds arc lands.
  Keep Stewdio for now (the UI literally lives at `/stewdio`, so it's honest today).
  It's ownable, on-theme, and encodes the covenant/stewardship differentiator. Either
  way, do **not** rename to "Knowledge Engine": Wolfram has owned
  "computational knowledge engine" since 2009 (SEO + the definition), USPTO treats
  the bare term as descriptive/unregistrable, and it's diluted (USI, Starmind,
  Accrete). "knowledge engine" is the **descriptor line**, never the mark.
- **Worlds** = the organizing noun (Michael's reconciliation, stronger than the
  pure "Loreworks" pitch). A *world* is anything with a corpus you gather and
  relate — **real** (a business knowledge base, a research topic, a book, an
  AI-video digest pool) or **invented** (a D&D campaign, a fiction setting). Every
  world runs the SAME machinery: gather → digest → fact-find → relate (graph) →
  present (reports/dossiers) → engage (the personas who live there). This is what
  makes the serious business *generally applicable* — the dossier-builder and the
  dungeon master are the same pipeline pointed at different canon. "Business can
  be fun" becomes the architecture, not a hope.

## The differentiator to lead with

Not "it does five things." The category-of-one axis where every competitor is weak
(Onyx owns connectors, Khoj autonomy, Cursor build, NotebookLM present, Perplexity
cited research — none own this):

- **One Postgres brain.** Vector + relational + graph in one SQL statement; one
  backup, one PITR, one replication target. "Your agent's entire brain is queryable
  with one SELECT and recovers to a point in time."
- **Every action is a row** → provenance, version history, and cost are nearly free
  (Claude's Artifact-versioning and Perplexity's citation-chips are bolt-ons here;
  for us they fall out of the schema). Click any sentence → its corpus row; any
  artifact → its edit history; any cost → the exact model call.
- **Covenant / intent / trust as queryable governance** — not guardrails bolted on,
  a relational contract that's inspectable state. (Translate the religious
  vocabulary to plain operator terms in public: intent = standing goal, covenant =
  rules of engagement, trust ladder = earned autonomy, spend cap = hard budget.)
- **Local-first sovereignty** (llama-chip federation) — runs on your own GPUs, data
  never leaves.

## Focusing release — scope line (NO new verbs)

**IN — make what EXISTS legible + adoptable under the worlds frame:**

1. **README + positioning rewrite.** Stewdio as the front door; the worlds story;
   lead with the differentiator above; kill "pre-release / extraction in progress."
2. **"One surface, two depths" streamline** (see the S1–S10 sequence below): the
   single persisted **Developer toggle** (clean everyday Browse│Read│Chat, power
   ducked away, zero capability loss), the **intent-named launcher**
   (Research/Generate/Digest/Build/Reflect from `pipelines.value.description`,
   already on the wire), merge the two session surfaces and the three model/metric
   views, disambiguate the two "＋ New" buttons, collapse the ~20-item nav into a
   Developer menu.
3. **Easy add of API keys + models (Michael, 2026-06-24 — "definitely need").**
   Today a provider is hand-wired via `STEWARDS_PROVIDER_*` env and the model
   catalog is a SQL seed; the ModelsPanel is read-only. Make adding a provider key
   and picking models a first-class **in-app** step (add key → probe → pick models →
   assign roles), with an opinionated default provider so a fresh install reaches a
   working model without env archaeology. This is the heart of "easy to install/
   adopt" and the prerequisite for the self-learning demo below.
4. **One bulletproof self-learning demo** — rides on (3)'s default provider: a
   digester/reflect-steward pass a stranger finishes in ~15 min, and a UI glimpse of
   what it learned (the RTE flag-rate gradient / proposed-skill diff). The headline
   leg can't stay the weakest.
5. **Tufte pass on metrics** — one reusable `<SparkMetrics>` (sparklines +
   cost-bar small-multiples) replacing the raw 24h table and collapsing the
   ModelsPanel / Dashboard / /models three-way redundancy. Behind the Developer
   menu.

**NEXT ARC — "Worlds" (named here so it does NOT leak into the focusing release):**

- The **world/canon model** in the extension. Today a "project" lens (all / AI /
  Books / Work-corpus) is a proto-world; make it first-class with a real-vs-invented
  mode. Net-new substrate — not a re-skin.
- A **good 3D knowledge graph.** The current `/graph` is bad and disconnected from
  the cockpit; the typed-edge vocabulary (38) + HippoRAG `graph_recall` (41) are
  the substrate to render well. Own effort.
- **Personas live in the Stewdio chat** — role-play with a world's voices,
  ai-chattermax-style. The "make it come alive" headline and the Loreworks payoff.

## Streamline sequence (reference — from the workflow)

S1 (S) disambiguate the two "＋ New" + rename left panel "Work items"→"Library" ·
S2 (S) add the missing `vision` model-role option · S3 (M) persisted store slice
(`dev`, `brandTitle`, persist chatModel+lens) · S4 (M) **the Developer toggle** +
`v-if` guards on the four in-cockpit dev surfaces (raw input JSON, `s.model` col,
provenance chips + 🔧 rows, model-role select) · S5 (M) **intent-named launcher**
(render `.description`, group by Research/Generate/Digest/Build/Reflect) · S6 (M)
merge the two session surfaces into the 💬 sidebar (this/everything toggle) ·
S7 (M) branding hook (`brandTitle` replaces hardcoded "stewards-ui") · S8 (L)
collapse the ~20-item nav into a Developer dropdown, Stewdio as home · S9 (L)
Tufte `<SparkMetrics>` · S10 (M) named layout presets (Read/Build/Monitor).

## Source

Workflow `wf_3d44035b-af3` (knowledge-engine-direction), 2026-06-24. Full survey
+ synthesis structured outputs captured in that run. Live first-hand check: the
nav carries ~20 items; `doc_search` is FTS-only and returns 0 on a natural-language
query (semantic `doc_similar` is a separate tool — a blend is a small, high-payoff
fix for the "knowledge engine" promise).
