# KEEP Brief — The Database IS the Product

War-game panel, KEEP advocate. Every claim below was verified against source in
`projects/pg-ai-stewards-oss` this session (file:line cited). Where the honest answer
is "not built yet" or "cut it," I say so — that is part of the mandate.

---

## 0. The frame the opposing brief will try to blur

"Markdown + Claude Code + cron" and the substrate are not two implementations of one
thing. Files hold **prose**; the substrate holds **prose plus physics** — locks, caps,
gates, triggers, and a ledger. The opposing brief will show you that the prose ports.
It does. The physics does not. And the asymmetry is absolute: `pending_file_writes` /
`enqueue_work_item_file` (10-sabbath-atonement.sql) already materialize rows→files
today — a markdown mirror is a `SELECT`. The reverse direction is a data-entry project
with permanent loss: you cannot recover `cost_micro`, a gate verdict, or a
`FOR UPDATE SKIP LOCKED` claim from a paragraph.

The July 3 audit (`.spec/proposals/audit-synthesis-2026-07.md`) already adjudicated
this once, with Michael ratifying item by item: "The substrate depth is the moat, and
it is real — not flattery" (§ one-line verdict), and §VIII — the question Michael
reserved for the top-level hand — concluded **cognition *state* in the DB is the whole
moat; cognition *execution* was the part to loosen** (harness executor, ratified 1B).
The pivot being war-gamed now would dismantle the layer the audit found load-bearing
while keeping the layer it found optional. That is exactly backwards.

---

## 1. The irreplaceable list

Each entry: the capability, where it lives (verified), and the concrete failure story
if it's replaced by files+CC+cron.

### 1.1 Refuse-before-spend caps — the wall a 3am loop cannot cross
`provider_spend_caps` (06-cost.sql:466) is enforced, not advisory:
`provider_cap_exceeded()` is checked at chat **enqueue** (19-models.sql:647), coder
dispatch (20-coder.sql:589), multimodal **send-time** (47-multimodal.sql:225–231),
fanout lens dispatch (14-fanout-brainstorm.sql:1010), and — the subtle one — alias
resolution and failover **route around** capped providers (31-model-aliases.sql:159,
32-alias-failover.sql:115). `virgin-smoke.sql:4203–4216` asserts the cap trips and
releases on refill. 88-credentials.sql adds daily-cadence budgets with no reset job.

**Failure story:** an unattended cron agent hits a malformed tool response at 3am and
enters a retry loop. In files-world the budget is a sentence in CLAUDE.md — a
suggestion the model may not load, may not weigh, and cannot be *stopped* by. By
morning the prepaid balance is gone. Here the loop's fourth attempt gets a refusal
from the dispatch gate — the model never even gets asked. A cap that lives in the
model's context is a hope; a cap in the dispatch path is a wall. (This is not
hypothetical: the whole poison-pill saga was survivable *because* spend caps stopped
the runaway rather than the balance stopping it.)

### 1.2 Concurrent multi-agent writes — correctness by construction
`FOR UPDATE SKIP LOCKED` at every claim site: work-queue claim
(05-mcp-bridge.sql:222), steward tick (07-steward.sql:346), scheduler leader election
(18-scheduler.sql:299–309, explicitly "keeps multiple leader candidates" safe),
dispatch surfaces (15b:1776), reflect (22:293). Council votes and trust mutations take
row locks (12-council.sql:413,455; 11-trust.sql:194,303).

**Failure story:** two digest agents (or two of Michael's parallel terminals — his
actual work style) finish against the same memory file within a minute. Last-write-
wins silently eats one study. Nobody notices until the citation that "should be in
memory" isn't, weeks later. With rows, double-claim is *impossible by construction*,
not by convention. Cron overlap — the classic "job ran long, next tick started
anyway" — becomes double-dispatch and double-spend in files-world; here SKIP LOCKED
makes the second claimant simply find nothing to claim.

### 1.3 The tool-effect gate + quarantine + needs_attention — structure between intent and effect
`tool_confirm_gate` (84-tool-effect-gate.sql:242) withholds dangerous tool calls into
`hinge_reviews`; `escalation_ladder` (84:172) defines who may approve;
`work_items.quarantined_at/quarantine_reason` (04-work-items.sql:149–150) pulls a
misbehaving item out of circulation, and quarantine triggers the atonement
lessons-from-failure dispatch (10:atonement_enabled). `needs_attention`
(89-attention.sql) unions all five human-blocking surfaces (gate, ask, hinge,
a2a_question, awaiting_review) into one queue with one router — each resolution still
enforced by its own verb's bounds ("84's escalate-always wall, 39's D&C 121 wall").

**Failure story:** a files+CC agent mid-run decides the right move is
`git push --force` or a bulk delete. Everything between its intent and the effect is
prompt text. Here the call is *withheld as a row* pending a verdict, the withholding
is itself audited, and the human sees one "needs your answer" queue instead of five
scattered surfaces. Governance-as-rows is the audit's §I.3: on Google's own phrase
"guardrails as external tamper-proof governance, not prompt," this repo is "the
strongest instance in any repo read."

### 1.4 Provenance stamped by trigger, not by discipline
`doc_finalize_tool` stamps `docs.work_item_id` at finalize (34-doc-builder.sql:227,
comment at :249 — the tie survives even when a loom/arc-c critic finalizes under a
*different session*). `war_game_capture()` (102-war-game.sql:136–247) fires as a
trigger the moment a pooled war-game doc lands, validates a deterministic floor (≥1
move with countermove, ≥1 abort condition, 102:172–182), stamps `work_items.war_game`,
and releases the waiting mission; failures log LOUD to steward_actions
(`war_game_parse_failed` / `war_game_invalid`). A second alarm trigger (102:263–278)
catches the unstamped-doc edge.

**Failure story:** in files-world provenance is frontmatter every author must
remember. One forgotten `work_item: ` field and the doc→work tie is gone — and it is
gone *forever*, because prose does not contain it. The war-game floor is the sharper
loss: a trigger that **rejects a governance artifact that doesn't meet its contract at
the moment of creation** has no files equivalent at all. A linter can nag; it cannot
refuse the write and hold the mission undispatched. (This very panel is running under
that trigger. The mechanism being war-gamed is the mechanism running the war-game.)

### 1.5 The audit ledger — the part that maps to what Qodo KEPT
`steward_actions` (07-steward.sql:40) — append-only, "the Account step of
Watch→Diagnose→Act→Account." `cost_events` with read-time `classify_error`
(06:539–595). `model_substitutions` (15a-context-engrams.sql:188) — "log of every chat
dispatch where the requested_model differs from the pipeline-declared stage model...
so humans can audit" silent swaps. Plus hinge verdicts, council votes, trust deltas,
lessons, stage_results trajectories, A2A receipts. And PITR: one Postgres backup
restores the entire brain — memory, verdicts, costs, in-flight work — to a moment in
time (audit §I.4: "the deepest audit surface in the set").

**Failure story:** "Which model actually wrote this study, what did it cost, and was
the declared model silently substituted?" Files+CC+cron has no answer — the session
transcript is gone, and it was never structured. Six months into the enterprise
conversation (or a serious self-improvement loop, which *requires* trajectory data),
this history cannot be backfilled. It either was recorded at the moment of action or
it does not exist. The audit trail IS the system.

### 1.6 Live control flow — anti-thrash a crontab cannot express
`route_on` (42-route-on.sql) — data-driven conditional/loop-back routing with per-rule
`count_key/max` loop guards and a global 50-hop ceiling backstopping "a misconfigured
infinite loop." The watchman scheduler fires on pressure > cron > idle with
budget-at-enqueue and surface-once-and-stop anti-loop discipline (03-watchman.sql
header — structural, not prompted). `kind_circuit_breaker` (15a) breaks per-kind crash
loops. **Honesty flag:** W2 — materializing war-game `aborts[]` into a live
`work_item_abort_conditions` table — is *designed, not built* (102:11–12: "until then
it is context + audit surface"). The KEEP case doesn't need to overclaim it; route_on,
the hop ceiling, and the breaker are live today.

**Failure story:** cron's entire control vocabulary is "run at time T." A failing
pipeline re-runs forever at the same cadence; a review→implement loop-back doesn't
exist at all; "stop after 3 loops and escalate with the reviewer's feedback attached"
(route_on's `feedback_key`) is unwritable. You'd rebuild a workflow engine in bash —
which is how the industry got Temporal. Audit §I.5: "we reached Temporal/DBOS-class
durability natively while the industry spent 2026 rediscovering it needs a product for
exactly this."

### 1.7 Hybrid RRF recall in the store
71-hybrid-rrf.sql: canonical Reciprocal Rank Fusion (k=60, rank-position fusion, FULL
JOIN of legs) over docs/entities/brain — with graceful degrade to lexical-only when no
embed provider exists. 72/73/75/76 wire it everywhere.

**Failure story:** grep is not semantic. A files agent either re-reads the whole
corpus each session (token cost, and Michael's corpus outgrew that long ago) or misses
the connection recall can't name. The cheap/local models the pipelines deliberately run
(judge-local-routing, 36) are exactly the models that need retrieval to be good.
**Honesty flag:** embeddings are the *regenerable* layer (the engram backfill proved
1585/1585 recoverable from rows) — see the Qodo section for why that's a point FOR
rows, not against them.

### 1.8 The enterprise option — honestly stated
RLS multi-tenancy is **not built** (verified: no `ROW LEVEL SECURITY` anywhere in
extension/; ratified 3C — "tenancy when a second human is real"). The honest KEEP
claim is smaller and still decisive: on Postgres, tenancy/RBAC/RLS are *native
options* a weekend of council can turn on; the audit sequenced them (miss E, after the
policy layer). Files+CC+cron does not have a worse enterprise path — it has none.

---

## 2. The AMPUTATION list — an honest defender's cuts

The moat is the governance/ledger core. Defending everything defends nothing. Cuts,
specific:

1. **The brainstorm lens zoo → a pack, pruned.** 14-fanout-brainstorm seeds 14 agents
   (counted: 14 `INSERT INTO stewards.agents`); 12 are brainstorm lenses (SCAMPER, Six
   Hats, Crazy 8s, Reverse, Mind Map, Brainwriting, + 6 more expansions). That is
   prompt-pack *content* riding in core architecture. Keep **fanout** (the parallel
   primitive earns its keep); move brainstorm to a versioned pack (the ratified 2A
   pack-as-extension shape), prune to the 4 original lenses, and let `cost_events`
   usage data justify reseeding the rest. If a lens has never been dispatched, it's
   dead weight with a prompt attached.
2. **Loreworks → pack #2.** 54, 55, 57, 58, 61, 85, 97 (+82-world-graph if it goes) —
   a creative *product* living inside a governance substrate. It was a great proof of
   the engine; it is not the engine. Second pack after the workspace overlay pack.
3. **83-code-graph — admit it's an index.** The truest Qodo analog in the schema:
   derived from repos, re-extractable by lodestar on demand, zero unrediscoverable
   content. Keep the capability, demote the posture: lazy-build/pack, not core.
4. **Peripheral integrations → packs:** 78-yt-slide-frames, 98-crawler,
   53-explore-repos. Each is a connector, not substrate.
5. **UI long tail — the actual source of "rough edges."** 29 top-level views
   (verified). Delete `Placeholder.vue`; `Brainstorm.vue` goes with cut #1; merge
   Intents / Covenants / Trust / Lessons / Sabbath / Councils+CouncilDetail into ONE
   Governance/Ledger view; pick ONE document reading surface (WikiReader) and retire
   Studies/StudyDetail as separate pages. Target ~12 views centered on Stewdio,
   Dashboard, WorkItems, Attention, Wizard, Search, Graph/Wiki.
6. **Consolidate the failover twins.** 32-alias-failover and
   68-model-fallback-hardening overlap; fold at the next authoring leg.
   91-core-compat is a shim to retire when packs land.
7. **Dead harness files out of extension/:** migration-order.txt itself says the
   verify-4a/4b/4c / test-gate-e2e files are "the historical per-migration harness,
   kept for reference" — virgin-smoke is authoritative. Move to tests/ or delete;
   they inflate the felt file count for zero function.
8. **What I refuse to cut, stated for the record:** sabbath/atonement flags. One file,
   default-off columns, and atonement's `lessons` ledger is squarely in Qodo's
   kept-layer class (adjudicated failure lessons are not rediscoverable). It is also
   the covenant made executable — the soul of the thing at near-zero carry cost.

Net effect: core drops from 102 numbered files to roughly 75 *before* any
consolidation, and the parts cut are precisely the parts files-advocates point at when
they say "over-built."

---

## 3. Kill the "heavy" feeling WITHOUT the pivot

The heaviness is real and it is **packaging, not architecture**. Every pain has a
named, mostly-ratified fix:

1. **File count is an authoring-history artifact.** The chain was consolidated once
   already: B5 folded the entire historical migration chain into authored subsystem
   files 00–19 (03-watchman.sql's header documents the fold: "Functions and views
   appear once, in their final form"; migration-order.txt: "applied by CREATE
   EXTENSION, NOT this manifest"). Run the same play as a "cut 4" leg on 20–102 →
   ~25–30 subsystem files. Precedented, mechanical, oracle-guarded (virgin-smoke +
   parity harness).
2. **Generate the Dockerfile COPY list.** The per-file hand-appended COPY lines
   (extension/Dockerfile:93–106 — each new SQL file needs a Dockerfile edit) are the
   single most gratuitous paper cut. A build script globbing the manifest kills it in
   an afternoon.
3. **One runner, manifest as runtime contract.** Audit §IV's landmine (three
   different orderings; `sort -V` puts cut3 in the wrong place) — already
   ratified in shape. Collapse migrate.sh / stewards-cli onto migration-manifest.txt.
4. **Single-command cross-machine update:** `stewards-cli update` = pull image →
   `ALTER EXTENSION pg_ai_stewards UPDATE` (Track 2's compat guard:
   `assert_core_compat()`) → run virgin-smoke parity. Cross-machine pain is a missing
   command, not a wrong architecture.
5. **The first-run wall is already falling.** 88-credentials.sql (verified, landed):
   encrypted AES-256-GCM credential store, test-on-save, never-echo, DB providers
   live *without rebuild or restart*, daily budgets with no reset job — plus
   `ProvidersWizard.vue` in the UI. The audit's "single largest first-run wall" was
   env archaeology + hand-written SQL seeds; that wall now has a door. Finish the
   wizard, ship the opinionated default provider, and a stranger reaches a working
   turn with zero SQL.
6. **UI consolidation** (amputation #5) is where "rough edges" actually lives — it's
   a week of deletion, not a platform pivot.

---

## 4. FILES AS INTERFACE, DB AS ENGINE — the hybrid, designed honestly

This is the actual answer, and the substrate is already halfway there **in both
directions**:

- **Rows→files exists:** `pending_file_writes` + `enqueue_work_item_file` +
  `file_destination_template` (10-sabbath-atonement.sql) + pg_notify on insert.
  Studies already materialize to the workspace.
- **Files→rows exists:** doc-extract, corpus import, the digesters.

Design the seam deliberately:

1. **The projected working set.** A standing projection job materializes chosen
   row-sets to a git-tracked directory: wiki pages, work-item briefs, and a
   CLAUDE.md-style **memory export** (nightly `MEMORY.md` generated from engrams +
   lessons + open threads). Every projected file carries a generated-from header with
   slug + row provenance. Claude Code greps it, diffs it, PRs against it — files are
   the *interface tier* it is best at.
2. **Author-in-files, ingest-by-trigger.** Michael writes markdown where markdown is
   the right authoring surface; a watcher imports on save, provenance stamped
   (source=file, sha256 — the machinery in 15a's overflow tables already fingerprints
   content). The DB stays merge authority because it is the tier that *has*
   transactions.
3. **The division of labor:** interactive humans and Claude Code live on the file
   projection; pipelines, gates, caps, and ledgers live on rows. Doc slugs = file
   paths is the join key.
4. **What must never move to the file tier:** the dispatch gate, the locks, the
   ledgers, the triggers. Those are engine, and prose cannot hold them.

This dissolves the actual complaint — heaviness is an *interface* feeling — without
surrendering a single engine property. The mirror is a SELECT; the engine is not
recoverable from the mirror.

---

## 5. The Qodo lesson, engaged straight

Qodo removed their RAG codebase index and kept PR-decision history — "what agents
can't rediscover." Map it onto the substrate:

- **Their KEPT layer ↦ our ledgers:** steward_actions, hinge_reviews, lessons,
  cost_events, model_substitutions, council votes/resolutions, trust deltas,
  stage_results trajectories, war_game blocks, A2A receipts. Adjudicated decisions and
  events — unrediscoverable from any snapshot. This is the *majority of the
  governance schema*, and it is exactly what the file-pivot would destroy.
- **Their REMOVED layer ↦ our derived indexes:** embedding columns, corpus chunks,
  83-code-graph, the crawler cache. All regenerable from rows (the engram backfill
  proved it: 1585/1585).

Does the mapping argue for slimming rather than defending all of it? **Yes — and I've
slimmed accordingly** (amputation #3, #4; classification discipline: label every table
`ledger` or `derived` and let derived layers be rebuilt, not defended). But note the
two disanalogies before the opposing brief overplays the card: Qodo's index shadowed
an artifact that lives *outside* their store (the repo — an agent can always re-read
it); our search runs over artifacts that live *inside* the store, where "just re-grep
it" has no semantic equivalent and the cheap local models doing pipeline work need
retrieval quality most. And Qodo removed an *index*, not their decision ledger — their
lesson, read honestly, is: **keep the rows, be ruthless about the caches.** The
file-pivot proposal does the opposite: it keeps the caches' content (prose) and
deletes the ledger. Qodo argues for the substrate.

---

## 6. Closing argument

The proposal on the table is to dismantle a governance engine because its packaging is
heavy — to trade refuse-before-spend caps for a budget sentence in CLAUDE.md, SKIP
LOCKED claims for last-write-wins, trigger-stamped provenance for frontmatter
discipline, an append-only account of every steward decision for vanished session
transcripts, and point-in-time recovery of an entire mind for `git log` over prose.
Every one of those trades loses the property the July 3 audit — commissioned by
Michael, ratified item by item — identified as the moat, at the exact moment the field
is paying Temporal, LangSmith, and now ADK-Go prices to rebuild what everything-is-a-
row already hands this system for free (durable graph workflows *as a library* still
leaves governance, audit, and recovery as exercises for the caller). The heaviness is
real, and it is packaging: consolidate the chain as B5 already proved we can, generate
the COPY list, make the manifest the one runner, finish the wizard that 88-credentials
already landed, amputate the lens zoo and loreworks into packs, and project the rows
into the markdown mirror Claude Code loves — a mirror we can regenerate with a SELECT,
from rows that could never be regenerated from the mirror. Fix the felt weight in two
weeks of packaging work, or spend the same two weeks burning down the only layer of
this system nobody else has. The database is not where the product lives; the database
is the product.
