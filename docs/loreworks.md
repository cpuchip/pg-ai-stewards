# Loreworks — build, explore, and inhabit a World from its source lore

Loreworks turns a pile of source lore (a TTRPG rulebook, your own writing, a wiki, a
codebase) into a **World**: a meaning-searchable canon, an extracted entity/relationship
**knowledge graph**, and **personas you can chat with**, all on your own GPUs, all private.
Built on the pg-ai-stewards substrate; the engine is generic OSS core, the worlds are local
content.

> Status: engine + experience proven live (2026-06-25). Chain `54`→`59`, virgin-smoke OK
> 44→49. Demo world `the-one-ring` (69 entities / ~80 edges) built live from a real rulebook.

## What a World is

```
World (worlds: slug, name, summary, project, is_private)
 ├─ Canon     — the source corpus (docs/pools, project-tagged), hybrid-searchable
 ├─ Entities  — world_entities: character|place|faction|item|event|lore|concept
 │              (deduped on (world,kind,name); aliases; source_refs cite the canon; embedding)
 ├─ Graph     — world_edges: typed directed relationships (relational, no AGE)
 └─ Inhabitants — the loremaster + personas grounded in the canon
```

## The chain (what each migration adds)

| File | Adds |
|---|---|
| `54-loreworks.sql` | the engine: `worlds`/`world_entities`/`world_edges` + `world_upsert`/`world_entity_upsert`/`world_edge_upsert` (auto-creates a missing endpoint) + `world_show`/`world_graph` (nodes+links JSON) + `world_entity_search` (lexical) |
| `55-loreworks-build.sql` | the **world-build agent** + `world_entity_upsert`/`world_edge_upsert` sql_fn tools (verb-direction guidance: `located_in` place-in-place, `dwells_in` people-in-place, `home_of` place→people) |
| `56-trajectory-critic.sql` | Glass-Box eval: `assemble_trajectory` + the `trajectory-critic` judge + `critique_trajectory`; and the `world-critic` (`world_edge_list`/`world_edge_prune`) |
| `57-loreworks-chat.sql` | **the semantic leg**: `world_entity_hybrid` (lexical ⊕ embed_query cosine) + `world_entity_embed` + `lore_search`/`lore_entity`/`lore_neighbors` + the **loremaster** agent + `lore_inject` (for world rooms) |
| `58-world-edge-audit.sql` | `world_rel_kinds` (kind-typed lore verb vocabulary) + **`world_edge_audit`** (deterministic structural flags: unknown_verb / src|dst_kind_violation / no_evidence) |
| `59-self-improvement.sql` | **the substrate fixes its own agents, gated** (see below) |

Plus the Stewdio UI: `cmd/stewards-ui/api/world.go` (`/api/world/{list,graph,node}`) +
`WorldGraphPanel.vue` (the 3D knowledge graph, `3d-force-graph`).

## Build a world

```sql
-- 1. register the world over a canon project (file_private = local-only)
SELECT stewards.world_upsert('the-one-ring','The One Ring (Middle-earth)',
       'Gazetteer of Eriador…','ttrpg-the-one-ring', true);
-- 2. dispatch the world-build agent on the canon (text and/or vision page-images)
SELECT stewards.dispatch_chat_turn('tor-build-1',
       'Build the world ''the-one-ring''. Canon: <text or doc_search the project>. Extract
        entities + relationships.', 'world-build');
-- 3. embed the entities for semantic search
SELECT stewards.world_entity_embed('the-one-ring');
-- 4. ground-check the edges (deterministic audit + the LLM critic)
SELECT stewards.world_edge_audit('the-one-ring');             -- structural flags
SELECT stewards.dispatch_chat_turn('tor-critic-1',
       'Ground the edges of ''the-one-ring'' against its canon: <canon>', 'world-critic');
```

## Explore a world

- **3D graph** — Stewdio `World` panel → pick the world. Color by kind, click a node for its
  summary + typed connections + the source passage it was pulled from.
- **Search by meaning** — `SELECT * FROM stewards.world_entity_hybrid('the-one-ring','an
  abandoned ruined city beside a lake', 6)` → Annúminas (the semantic leg finds what the words
  never named).
- **Chat with the world** — dispatch the `loremaster` (or, in Stewdio, a `world:<slug>` lens);
  it answers grounded in the entity graph + canon, with citations, never from training memory.

## The self-improvement loop (gated)

The substrate evaluates its own process and mends its own agents:

```
trajectory-critic verdicts → agent_failure_patterns (recurring, thresholded)
  → agent-improver proposes ONE scoped guidance clause
  → prompt_improvement_gate (deterministic)
       in-bounds  → apply_prompt_improvement (trailed in prompt_improvements, reversible)
       out-of-bounds → escalate to the human
  → the critic re-scores
```

**Safety invariant (the eval-gaming guard):** the gate NEVER auto-modifies what grades or
gates the system — any judge (`response_format` set), any critic, the stewards/Hinge, or the
improver itself escalate. Auto-applied clauses are **additive guidance only** (permission /
constraint / grounding-bypass / destructive language is regex-blocked; ≤600 chars); the gate
is re-checked at apply time. `self_improve_tick()` drives it and honors `autonomy_paused`.
Everything is trailed (`prompt_improvements`, with `prior_prompt`) and reversible
(`revert_prompt_improvement`). The gate was adversarially red-teamed (11 attacks; all
dangerous clauses escalate) before auto-apply was trusted.

## Configuration (the embed provider)

Hybrid search + entity embedding use the configured embed provider/model:

```sql
INSERT INTO stewards.config(key,value) VALUES
  ('embed_provider','"lm_studio"'::jsonb),
  ('embed_model','"text-embedding-nomic-embed-text-v1.5"'::jsonb)
ON CONFLICT (key) DO UPDATE SET value=EXCLUDED.value;
```

With no embed provider configured, search degrades cleanly to the lexical leg.

## Port / bring-up (work rig)

1. Build the pg image (`docker build -t … extension/`) — the chain 00→59 installs on
   `CREATE EXTENSION`; virgin-smoke (`tests/virgin-smoke.sql`) proves it (OK 1→49).
2. Build/recreate the `ui` service (the `World` panel ships in it; `npm i` already pinned
   `3d-force-graph`/`three`/`three-spritetext`).
3. Set the embed config (above). Privacy: keep purchased/world content `file_private`; embed
   locally (nomic); never send to a train-on-data provider.
4. The committed `cmd/stewards-ui/frontend/dist/index.html` is a STUB — the `ui` Docker stage
   builds the real SPA. A local `npm run build` overwrites the stub; `git checkout` it back
   before committing (only `index.html` is tracked; built assets are gitignored).

## Files

- `extension/54..59-*.sql` (the chain) · `tests/virgin-smoke.sql` (OK 44→49)
- `cmd/stewards-ui/api/world.go` · `cmd/stewards-ui/frontend/src/views/stewdio/WorldGraphPanel.vue`
- `.spec/proposals/loreworks.md` (spec) · `.spec/proposals/loreworks-presentation-plan.md`
  (design + Friday script) · `.spec/journal/2026-06-25-*` (the build journals)
