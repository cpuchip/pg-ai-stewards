# Loreworks — build, explore, and inhabit a World from its source lore

**Status:** RATIFIED in council with Michael 2026-06-25 (innovation week). Build A–E overnight;
F+G follow. **Engine → public OSS core; all TTRPG/world content → local-private, never pushed.**
**Discipline:** granular commits ("git it king" — walk anything back), dave-rule / ammon /
stuffy-in-the-loop / ben-test honesty about what actually landed.

## The one-sentence pitch

Drop a pile of source lore (a TTRPG rulebook, your own writing, a wiki) → the substrate **builds a
World**: a searchable canon, an extracted entity/relationship **knowledge graph**, and **personas you
can chat with** that are grounded in that world. Explore it in a 3D graph, search it by meaning, or
role-play inside it.

## Why now / why it's a flagship

- The substrate already digests sources into pools, runs grounded personas, and dispatches local
  models for free/private. Loreworks is those primitives **composed into a product**: source → world.
- Michael bought ~6.3 GB of TTRPG (18 publishers) — a perfect, vivid, *legally-his* corpus to prove
  "any world." Pilot trio spans the genre space: **My Little Pony** (whimsy) · **Star Trek Adventures**
  (sci-fi) · one **dark-fantasy** (Free League / Pelgrane — Symbaroum / Dragonbane / 13th Age).
- It needs the **hybrid-search primitive** (A) we were already going to build — so A pays for itself
  twice (better chat retrieval everywhere *and* the lore-search leg).

## Architecture — a World has four parts (all generic core)

```
            ┌────────── World (world_id, name, slug, summary, intent/private flag) ──────────┐
 Canon  ──► │  source corpus: docs/pools (e.g. ttrpg-mlp), hybrid-searchable via embed_query  │
 Entities ─►│  world_entities: (world, kind, name, aliases, summary, source_refs, embedding)  │  kinds:
            │                                                                                  │  character/
 Graph  ──► │  world_edges: (world, src_entity, dst_entity, rel_type, evidence)               │  place/faction/
            │                                                                                  │  item/event/
 Inhabit ─► │  personas bound to the world's canon (lore-grounded chat / role-play) [G]        │  lore/concept
            └──────────────────────────────────────────────────────────────────────────────────┘
```

**`world-build` pipeline** (reuses the proven doc-construction loop + A's hybrid search):
`read canon → extract (model emits world_entity/world_edge tool-calls, deduped) → graph → summarize`.
Empty-source halt + quote-gate inherited. Local models, file_private for private worlds.

**Surfaces in Stewdio:**
- **Lore lens / Loremaster** (C): hybrid-search a world's canon from chat; a read-only persona that
  cites passages (librarian pattern, over the world corpus).
- **3D knowledge graph**: `3d-force-graph` (three.js) of entities+edges; click a node → its lore +
  sources; filter by kind.
- **World rooms** (G): ai-chattermax-style room where the world's personas talk — role-play or
  "work-play" (interrogate the lore in character).

**Core vs private:** tables, `world-build` pipeline, `embed_query`/hybrid search, the 3D graph, the
room machinery = **generic OSS core**. The TTRPG worlds, their entities, embeddings = **local-private**,
intent `file_private` like work-corpus — never pushed, never sent to a train-on-data cloud provider.

## The chunks (A–G)

### A — SQL-embed + hybrid (RRF) search  *(branch `feat/sql-embed-query-hybrid`, ratified)*
The enabler. Build `stewards.embed_query(text, provider?, model?, dimensions?)` `#[pg_extern]`:
- Refactor `bgworker.rs::embed()` (~1608) → extract a side-effect-free `embed_one(provider, text,
  model, expected_dim) -> Result<Vec<f32>, String>` (HTTP+parse+dim-check; reuse `send_with_retry`
  #243 + the 120s blocking client). `embed()` keeps its work-queue write, now calling `embed_one`.
- `embed_query` resolves the provider in the **backend** process (PROVIDER_REGISTRY OnceLock is empty
  there) via `ProviderRegistry::from_env()` (memoized in its own OnceLock); default provider/model from
  a `stewards.config` row (`embed_provider`/`embed_model`/`embed_dimensions`), not hard-coded.
- Version bump `0.2.0 → 0.3.0` (`pg_ai_stewards.control`) + the chain file that registers the function
  (new `extension/54-embed-query.sql` or fold into the next number) + Dockerfile COPY + lib.rs.
- **Oracle (inverse hypothesis):** a row whose meaning a synonym query expresses with NO shared tokens
  ("notification fatigue" vs "alert overload"): FTS+trigram MISS, embed_query+cosine CATCH, remove the
  vec leg → miss returns. Then the opt-in 3-leg RRF (kw ⊕ trigram ⊕ vec, k=60) as a helper —
  **additive, does NOT change default `doc_search` behavior** (a new hybrid path; wholesale doc_search
  swap is a later reviewed change).

### B — TTRPG corpus → local private Worlds  *(pilot: MLP + Star Trek Adventures + 1 dark-fantasy)*
Bucket `external_context/ttrpg/<publisher>/<game>` (gitignored, outside the repo). Per game: extract
(doc-extract sandbox, RC-3 cliff already raised) → `doc_import_corpus(project='ttrpg-<game>')` → local
nomic embeddings → register a World over it. Fan-out by game (plan → import → verify). Pilot 3 first
(serial-probe-then-scale), then the rest as time allows.

### C — Loremaster + lore lens + 3D graph
Read-only `loremaster` persona (deny `*` + allow doc/pool/world search + `embed_query` hybrid) granted
to world chats; a `lore:<world>` grounding lens in Stewdio; the `3d-force-graph` panel.

### D — Hardening (independent, fan-out)
#251 (sanitize binary tool-results before the jsonb write — bites PDF/zip extraction directly) · the
`.mind/sessions/pg-ai-stewards.md` null-byte repair · prune dead opencode free-tier alias members.

### E — Loreworks engine (the world-build machinery above)
`world_entities` / `world_edges` / `worlds` core tables + `world-build` pipeline + extraction tool-defs
(`world_entity_upsert`, `world_edge_upsert`, deduped) + a `world_show`/`world_graph` read surface.

### F — `projects/private/loreworks-walkthrough` (the innovation-week presentation)
A private repo presenting the week: architecture, design, flows, live examples (the 3 worlds). Rendered
to a **~6-min video via the `hyperframes` MCP** (`external_context/hyperframes` — set up as an MCP first).
**Narration:** I write the script; **TTS voice-clone of Michael** from `books/creators-playbook/
EP_87_87-soul-bleeding-dystopias/episode.mp3` (his voice ≈ first 35 s; ffmpeg-snip the sample) on a
**local GPU**. Prior art: Spin/Kokoro (Kokoro = synth, not clone → a clone-capable engine, e.g. XTTS-v2
/ F5-TTS, scoped in F).

### G — Persona chat rooms in Stewdio (role-play / work-play with a world)
Bring the ai-chattermax room experience into Stewdio: a world room hosting the world's personas
(grounded via A's hybrid search over the world canon), reusing persona-host + `dispatch_chat_turn`.

## Build waves (parallelism)

1. **A** (mine + adversarial-QA workflow) — unblocks the lore-search leg + better retrieval everywhere.
2. once A lands: **B** corpus import (workflow fan-out) ‖ **E** world tables+pipeline (mine) ‖ **D**
   hardening (workflow) ‖ **F**-research (workflow: scope hyperframes + voice-clone, draft the script).
3. **C** loremaster+lens+3D graph ‖ **G** world rooms (ride A+E).
4. **F** assemble the walkthrough + render the video.

**Honest expectation by morning (ben-test):** A proven, B pilot imported, E model+pipeline built, D
done, C/G first cuts, F scaffolded + scripted + voice-sample prepped. Not all of A–G fully polished —
granular commits make every step walk-back-able.

## References
- A spec (full): `git show origin/feat/sql-embed-query-hybrid:.spec/proposals/sql-embed-query-hybrid-search.md`
- doc-construction loop (reuse): `extension/34-doc-builder.sql`, `35-research-doc-construction.sql`
- persona-host + dispatch_chat_turn (G): `extension/17-personas.sql`, `45-work-item-chat.sql`
- relational edges pattern (graph): the AGE-replacement decision (memory `project_pg_ai_stewards_oss`)
