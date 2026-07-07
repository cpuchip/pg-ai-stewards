# Files as Interface, DB as Engine — the lightening verdict

**Status:** ★ RATIFIED 2026-07-07 (Michael), with amendments:
0. **Decision ask #3 ANSWERED 2026-07-07 morning** (missed in the sleepy bedtime round): **BOTH files-interface increments — ingest-by-drop AND the projection tree** ("both! let's do 1 and 2"). Michael also placed the lineage: the projection tree "may have even predated pg-ai-stewards" — confirmed, it's in the FOUNDING 2026-05-02 research verdict (".mind/ markdown files… become *projections* of canonical rows, not the canonical store") and the autonomous-materializer proposal (2026-05-22) ratified the bridge-goroutine mechanics it reuses. Build branch: `feat/files-interface` (v28 + bridge drop-watcher + projector).
1. Four-layer ruling — **ratified as-is**.
2. Core/pack list — **ratified with the loreworks inversion confirmed: "loreworks is the point, everything else supports it."** Worlds/seams are core; brainstorm-zoo, crawler, yt/frames, code-graph, TTRPG extras, lab → packs.
3. **NEW FOUNDING PRINCIPLE — the substrate ships MODEL-AGNOSTIC:** *"default is no models, it's just a db that's lifeless. you give it models to bring it to life."* Core seeds NO providers and NO model defaults; the wizard is the front door for whatever a deployer has (a Claude Code license via loom, Vertex, Azure, AWS, raw keys, local). Any model preference is deployment config, never core schema. (Locally: lean sonnet-5/haiku-4.5/opus-4.8 via loom + opencode-go/local — that's an OVERLAY choice.)
4. Observations store + seams report — **green-lit**.
5. UI 29→~12 — **go**; post before/after and march; dev-menu hiding acceptable for marginal views.
Build branch: `feat/lightening`.
**Panel:** RIP (Fable, steelman the file-based pivot) · KEEP (Fable, defend the database — with receipts) · OPERATOR (Sonnet, walked all 24 routes) · PIONEER (Sonnet, prior-art sweep) · plus an enterprise war-gamer whose artifact lives outside this repo. Full briefs: `.spec/wargames/2026-07-07/`.
**Prompted by:** the owner's honest weight report — "so many rough edges, poor UI still, broken paths, 102 sql files... painful updates between systems... helpful but heavy. Part of me just thinks I need to go file based."

## The verdict, in one breath

**Keep the ledger, admit the caches, project the prose, cut the packaging debt.** Opposed mandates converged: RIP's strongest concession is that the decisions ledger is "the one thing agents can't rediscover"; KEEP's strongest concession is that the heaviness is real and it's packaging, not architecture. The pivot-to-files, executed literally, would keep the regenerable caches and delete the unrediscoverable ledger — Qodo's lesson applied backwards.

## The four-layer ruling

| Layer | Ruling | Why |
|---|---|---|
| **Ledger & governance** (work items, steward_actions, cost_events, model_substitutions, hinge verdicts, lessons, provenance triggers, spend caps, gates, locks) | **ROWS, forever** | "Files hold prose; the substrate holds prose plus physics." Caps refuse *before* spend; triggers stamp provenance without discipline; locks survive concurrency. None survives projection to markdown, and none can be backfilled from prose later. |
| **Indexes & caches** (embeddings, RRF, code-graph, community summaries) | **ADMITTED CACHES** — regenerable, never defended as product | Qodo's removed layer. Embeddings were already re-backfilled 1585/1585 once; treat every index as rebuildable and be ruthless about which earn their infra. |
| **Prose & authoring** (wikis, briefs, memory exports, study docs) | **FILES** — projected FROM rows, authored IN files, ingested BY trigger | Rows→markdown is SELECT-cheap and already half-built (`world_to_wiki` re-projection, pending_file_writes). Claude Code greps, edits, PRs files; ingest stamps provenance on the way back in. The markdown-convergence trend (Karpathy/Google/Tan, each for different problems) is the interface layer, not the engine. |
| **Engine** (pipelines, scheduler, workflow) | **KEEP but stop expanding** — the engine is commoditizing (ADK Go 2.0 ships durable graph workflows + HITL free) | Differentiation was never the engine. New orchestration ambitions should compose commodity engines rather than grow ours. |

## What actually gets cut / consolidated (the "heavy" fix, ~2 weeks not a rewrite)

1. **Chain consolidation:** 102 files → ~25-30 by re-running the proven B5 pattern on 20→102. The file count is packaging, not architecture — but it is *felt* architecture, and the Dockerfile's enumerated COPY lines (which silently shipped a stale image this week) die with it.
2. **Generated build manifest:** the COPY list and lib.rs registrations generated from the chain, not hand-maintained. A new chain file that isn't in the image becomes a build error with a name.
3. **One update verb:** `stewards-cli update` = pull → build (unpiped!) → ALTER EXTENSION UPDATE → smoke → parity. The cross-machine pain collapses into one command with one exit code.
4. **Packs:** loreworks, crawler, yt-frames, brainstorm-lens-zoo, code-graph → opt-in packs (the D2A pack mechanism is the vehicle). Core = ledger + governance + doc/wiki + worlds-lite + chat.
5. **UI 29 → ~12 views:** merge the six governance viewers into one Ledger page; kill or fix the dead routes the OPERATOR walk found (below). UI truth must equal feature truth — three "completed" features were dead/hidden/broken until a human walked them this week.
6. **Files-interface increments:** nightly wiki/brief projection to a `knowledge/` tree (greppable, PR-able); an ingest-by-drop directory whose trigger stamps provenance; MEMORY.md-style exports for harness sessions.

## The operator's polish backlog (top findings, full table in wargame-OPERATOR.md)

1. **Scheduler dead 14 days** — every cron frozen at 2026-06-23 01:00, zero log lines, no alarm (filed; fix must add per-row isolation + a staleness alarm so this class can never be silent again).
2. `/covenants` broken (raw "no rows in result set").
3. 6 of 16 MCP connectors down (`fork/exec: no such file`) + one pointing at a predecessor binary name.
4. `/studies` and `/work-items` silently cap at 100/24 rows with no pagination while claiming full totals.
5. "Full report" links append literal `.md` and 404.
6. `/projects` counts wrong for 6 of 10 projects (`project_association` never set at ingestion).
7. Corrupted search snippet on top hybrid result.
8. Stuck work item blocking the needs-attention queue with "diagnosis: unknown."
9. Session-detail timeout on reused session slugs.
10. Stale ERROR banners persist after successful retries.
Plus: the bulk data-in path exists only via the chat 📎 (multi-file+archives) while the obvious `/new` page is single-file — the day-one story is undocumented, and the day-30 staleness story currently ends at a dead scheduler.

## The freshness principle (from the same panel)

Data-in and keep-fresh are the product's spine, not chores: **ingest-by-drop + incremental re-extraction (LightRAG-style: only re-summarize what changed) + staleness sentinels that FLAG (never silently fix) + the scheduler alarm above.** A knowledge engine whose freshness machinery can die silently for 14 days is a junk drawer with extra steps — this week proved it on our own instance.

## Positioning (sanitized; the panel's prior-art verdict)

- Corpus→entity-graph extraction: **crowded** (GraphRAG lineage, commercial equivalents). Freshness: **crowded pain-point**. Boyd/orientation framing: **pioneering as branding**, with real but differently-labeled capability neighbors.
- **Seam-finding — surfacing where two teams' understandings of the same subject diverge, as a first-class product output — has no located prior art.** Every neighbor merges-and-dedupes toward a single source of truth by design. If this project claims one novel thing, it is that: *disagreement between team lenses is a finding, not a defect to merge away.* The per-team worlds + cross-world edges machinery is the substrate feature that makes the claim buildable.
- Steal list: SenseMaker's narrative-landscape UI; GraphRAG's community-summary layer; LightRAG's incremental updates.

## Decision asks (Michael)

1. Ratify the four-layer ruling as the standing architecture principle (supersedes "everything is a row" as a *slogan*; the ledger stays rows, the slogan gains a second half: "…and every row can be read as a file").
2. Green-light the 2-week lightening batch (items 1-5) as the next arc after the scheduler fix.
3. Pick the first files-interface increment (projection tree vs ingest-drop — the drop directory is the better demo of the freshness principle).
