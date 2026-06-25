# 2026-06-25 — Loreworks night: the engine (A + E), built and proven LIVE

Innovation week. Michael said "I want big," ratified the whole Loreworks arc (A–G) in
council, then went to bed: "work for a few hours while I'm asleep." This is the engine
half — built, verified, and proven live doing the actual magic.

## What Loreworks is

Drop source lore (a TTRPG rulebook, your own world, a wiki) → the substrate BUILDS a
World: a meaning-searchable canon, an extracted entity/relationship knowledge graph, and
personas you can chat with grounded in that world. Ratified: engine → public OSS core,
all TTRPG/world content → local-private. Pilot worlds: My Little Pony, Star Trek
Adventures, The One Ring. Spec: `.spec/proposals/loreworks.md`.

## Shipped tonight (all proven, live, pushed — granular per "git it king")

**A — `stewards.embed_query()`** (`5db54d8`, ext 0.2.0→0.3.0). The enabler the substrate
lacked: synchronous query-time embedding from SQL → unblocks hybrid full-text+semantic
(RRF) search over any embedded table. Refactored `embed_one()` out of the async `embed()`
path (shared core); `#[pg_extern] embed_query(text, provider?, model?, dimensions?=768)
-> real[]`, resolves the provider in-backend (inherited PROVIDER_REGISTRY, else from_env).
**Inverse-hypothesis proven against live nomic:** "notification fatigue" ↔ "alert
overload" (zero shared tokens) cosine **0.33** vs unrelated **0.64** — the semantic leg
catches exactly what a token search misses. From the branch `feat/sql-embed-query-hybrid`.

**E1 — the engine** (`32fc9e9`, `54-loreworks.sql`). `worlds`, `world_entities` (deduped,
aliases, source_refs cite the canon, optional embedding), `world_edges` (typed directed
graph — relational, no AGE). Functions: world_upsert / entity_upsert (merges aliases+refs)
/ edge_upsert (by name; auto-creates a missing endpoint as concept) / world_show /
world_graph (nodes+links JSON for the 3D viz) / world_entity_search. virgin-smoke OK 44.

**E2 — the world-build agent** (`ca29c7a`, `55-loreworks-build.sql`). Two sql_fn tools the
model calls (world_entity_upsert kind-validated + world_edge_upsert by-name) + world_show/
world_entity_search read tools + the `world-build` agent family (deny * + allow the world
tools + doc_search/book_search; steps 60; prompt = survey canon → extract grounded
entities/edges in passes → short journal). virgin-smoke OK 45. Chain 00→55 green.

## The capstone — a real world built live

Dispatched the world-build agent (`dispatch_chat_turn`, 'world-build', local 'reason'
alias) on a synthetic 4-sentence canon. In **~15 seconds, $0**, it produced a **10-entity /
10-edge** graph, every entity correctly kinded and **every edge grounded in the source**
(Aldric created Sunblade / parent_of Mira; Mira rules Aethelgard; Bram serves Mira, wields
Sunblade, guards Coldgate; Vex leads Shadow Cult; Shadow Cult enemy_of Mira — no
hallucination). The agent's journal named the spine of the world correctly. The whole
Loreworks thesis — source lore → structured explorable world — works end-to-end, live.
(Demo artifact `lore-smoke` left in the dev pg for Michael to world_show/world_graph.)

## Honest notes (ben-test)

- Entity **summaries came back empty** — the model prioritized names + structure over the
  1-2-sentence summaries the prompt asked for. A prompt-tuning nit (emphasize summaries, or
  a second enrich pass); the structure (the hard part) is flawless.
- One rel_type was the phrase "rules from" (a space) — the tools accept any verb; a
  snake_case normalizer is a nicety, not a need.
- `embed_query('text')` with no model falls back to provider.default_model (qwen, a chat
  model) — callers pass the embed model explicitly today; a config `embed_model` read is a
  small follow-up Rust pass.
- The full multi-stage SCHEDULED pipeline (read→extract→summarize with maturity/stage_models)
  was deferred — E2 ships the irreducible tools+agent so a world builds in one dispatch; the
  pipeline layers on top.

## Carry-forward (the rest of A–G, sequenced + wired)

- **B — TTRPG import** (watched, not unattended): the pilot rulebooks are big (MLP 151MB,
  Trek 38MB, One Ring 31MB). Import each via doc_import_corpus → `ttrpg-<game>` + local
  nomic embeddings → world_upsert → dispatch world-build. Heavy on the embed server; do it
  watched. This turns the synthetic proof into the real, vivid demo worlds.
- **C — Loremaster + lore lens + 3D graph** (`3d-force-graph` over world_graph) + the
  hybrid (embed_query) vec-leg on world_entity_search.
- **D — hardening:** lane null-byte fixed; #251 binary-sanitize + dead-model prune remain.
- **F — the walkthrough video:** advance-scout DONE (`loreworks-F-prep.md` — hyperframes-as-
  MCP setup + local voice-clone plan + a draft 6-min script). Assemble after B/C land.
- **G — world chat rooms in Stewdio** (ai-chattermax-style; personas grounded via hybrid
  search over the world canon).

Tasks #262/#263 done; #264-268 sequenced. Memory: `project_loreworks`.
