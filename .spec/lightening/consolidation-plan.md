# Chain consolidation plan — 102+ files → ~28 (feat/lightening)

**The shepherd's design doc for the riskiest lightening move.** Ratified direction: the file count is packaging debt; consolidation must change ZERO semantics. The B4/B5 pattern (13-16 → consolidated, 2026-06) is the precedent and the method.

## Why this is safe to do at all

The chain's semantics live in the DAG of `extension_sql_file!` registrations, not in file names. Every object is CREATE OR REPLACE / IF NOT EXISTS / ON CONFLICT — the chain is idempotent by construction. Consolidation = concatenating files in DAG order into themed volumes, preserving every statement byte-for-byte (headers become section banners), then re-registering ~28 volumes in the same order. The virgin-smoke output (every OK block) is the equivalence oracle: same assertions green before and after = same schema and seeds.

## Target volumes (draft — final grouping may shift ±3 at execution)

| # | Volume | Absorbs (today's files) |
|---|--------|--------------------------|
| 00 | core-config | 00, 01, 02 (config, graph, workstreams) |
| 01 | watchman | 03, 23, 28 (watchman, reflect-watchman, guard-autoresume) |
| 02 | work-items | 04, 09 (work items, intents/covenants) |
| 03 | dispatch | 05-08, 10-12 (queue/dispatch internals as they exist) |
| 04 | research-pipelines | 13, 22 (research + reflect-steward) |
| 05 | fanout | 14 (brainstorm zoo → PACK; fanout core stays) |
| 06 | context-engine | 15a, 15b |
| 07 | subagents | 16 |
| 08 | personas | 17, 45, 46 (personas + work-item chat + chat tasks) |
| 09 | scheduler | 18, 100, 106 (scheduler + schedule-chat + visibility) |
| 10 | models | 19, 31, 32, 68 (models, failover twins folded, fallback-hardening) — MODEL-AGNOSTIC strip applies here (Builder C's audit drives it) |
| 11 | coder | 20 |
| 12 | compact | 21 |
| 13 | doc-builder | 34, 50 (doc tools + doc-build) |
| 14 | hinge | 39 |
| 15 | rte-tend | 40, 41 |
| 16 | worlds | 54-57, 62, 82, 85, 97 (loreworks core: worlds, chat, orientation, world-graph, world-chat, wiki-bridge) |
| 17 | eval | 56, 59, 79, 80 (critic, self-improve, bineval, rest) |
| 18 | spiral+gates | 81, 84 (+ escalation ladder) |
| 19 | search | 72, 76, 93 (RRF, engram-search, recall) |
| 20 | credentials | 88 |
| 21 | attention | 89 |
| 22 | harness | 90 |
| 23 | compat | 91 |
| 24 | wiki | 92, 94, 95, 96 |
| 25 | war-game | 102, 103 (W1 + W2 aborts) |
| 26 | knowledge | 104, 105 (observations + seams) |
| 27 | packs-seams | pack registration scaffolding (D2A mechanism) |
| PACKS | — | 14-zoo lenses, 83 code-graph, 98 crawler, 99 route-intake, 87/101 lab, yt/frames overlays, TTRPG extras |

## Execution discipline (non-negotiable)

1. **Byte-preserving concatenation first, editing never** — the consolidation commit contains ONLY moves; any semantic change (model-agnostic strip, pack extraction) is its OWN commit before or after, so the diff proves the move changed nothing.
2. **Order = the current lib.rs DAG topological order.** Generate the order FROM lib.rs, don't hand-derive.
3. **Generated build manifest**: a `extension/gen-manifest.sh` (or build.rs) emits the Dockerfile COPY list + verifies every `extension_sql_file!` path exists — the forgotten-COPY class dies.
4. **Oracle**: virgin-smoke green on the consolidated image (same OK blocks; the smoke's own file references updated in the same commit); parity-check vs a pre-consolidation live is EXPECTED CLEAN because objects are identical — a parity diff = a consolidation bug, full stop.
5. **migrate.sh adopt**: existing installs see new file names; the adopt ledger re-adopts by content-idempotency (CREATE OR REPLACE). Verify `migrate.sh apply` is a no-op against a live built from the old chain.
6. **Do it LAST in the branch** — after 103-106 + model-agnostic strip land, so it consolidates the final content once.

## Who executes

An opus-tier builder agent with this doc as its brief + the smoke as its oracle, shepherded by the session lead. Estimated one focused pass + one fix round.
