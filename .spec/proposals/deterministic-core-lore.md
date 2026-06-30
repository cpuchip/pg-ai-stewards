# Deterministic-Core Lore — a world model (statecharts), Stately Sketch, and the view stack for pg-ai-stewards world-graphing

**For:** the pg-ai-stewards session (world-graphing / Loreworks). **From:** general-workspace, 2026-06-30.
**Status:** research → ready to integrate. **Sources:** David Khourshid (XState/Stately) talk *"Goodbye slop; welcome determinism"* ([uMvTAF280so](https://www.youtube.com/watch?v=uMvTAF280so), AG Grid 2026-06-26, transcript at `yt/ag-grid/uMvTAF280so/`); Stately **Sketch** cloned at `external_context/stately-sketch` (MIT); the current-lore scout (file:line below).

---

## 0. TL;DR — the one idea

The lore engine today is a **static knowledge graph**: entities + typed directed edges (`stewards.world_entities`/`world_edges`), a `3d-force-graph` view, and a read-only LOREMASTER chat. It has the **agentic shell** (LLM world-build + LOREMASTER) but **zero deterministic core** — no entity *state*, no *events*, no *transitions*, no way for the world to *advance* (scout §5). That is *exactly* the gap Khourshid's talk names: **slop is a system without an explicit model.**

The upgrade: add a **world MODEL** — model lore entities (characters, factions, quests, locations) as **statecharts** (explicit state + typed events + transition guards). The world advances by **applying validated transitions** (the deterministic core); the LLM stays at the **edges** (proposing events the engine validates, voicing personas grounded in their *current state*, narrating transitions). Then give it the **view stack**: keep the 3D graph for "inhabit," add **Vue Flow** for editable statechart/quest flows, **Cytoscape** for analysis, **Mermaid** for LLM-sketched diagrams, and borrow **Stately Sketch's** statechart layout + *simulator* for a deterministic world-replay stepper.

> Khourshid: *"Write programs that call LLMs, not LLMs that call programs. Move non-determinism to the edges, determinism to the core."* A lore world is the textbook case — a system that should be **reproducible and canon-consistent**, with creativity at the edges.

---

## 1. The talk, distilled

- **Slop = code without a reliable model** ([t511](https://www.youtube.com/watch?v=uMvTAF280so&t=511)): can't fully explain it, edge cases unclear, no domain boundaries, invariants implicit, can't inspect states, behavior scattered. The "slot-machine / slop-machine" — re-prompt until it *looks* right ([t574](https://www.youtube.com/watch?v=uMvTAF280so&t=574)).
- **Root cause = unstructured delegation** ([t424](https://www.youtube.com/watch?v=uMvTAF280so&t=424)): throwing judgment + structure + taste over the wall to agents.
- **A model** = an explicit representation of how the system *should behave* ([t732](https://www.youtube.com/watch?v=uMvTAF280so&t=732)); intent + execution, structured, can hold natural language, and the app maps *directly* to it. State machines express it as **given/when/then → states, events, transitions → a graph** ([t755](https://www.youtube.com/watch?v=uMvTAF280so&t=755)). (Not the only modeling tool — also BPMN, flowcharts, DDD for data.)
- **Why agents skip models** ([t816](https://www.youtube.com/watch?v=uMvTAF280so&t=816)): agents are obedient but lack agency — "build a feature" → straight to code (the noisy source of truth). Give them the model and they work *within* it. *"The model is for your agents so they stop producing slop"* ([t1784](https://www.youtube.com/watch?v=uMvTAF280so&t=1784)).
- **Deterministic core / agentic shell** ([t1196](https://www.youtube.com/watch?v=uMvTAF280so&t=1196)): invert "LLMs that call programs" → "programs that call LLMs." Determinism at the core; LLMs at the nodes/edges for the fuzzy parts.
- **Modeling is not ceremony when it replaces confusion** ([t1290](https://www.youtube.com/watch?v=uMvTAF280so&t=1290)): model only the *confusing* parts; AI helps you build the model.
- **The canonical demo** ([t1464](https://www.youtube.com/watch?v=uMvTAF280so&t=1464)): an email agent as an XState statechart — `requirements → draft → iterate → send`. The deterministic guards make it **impossible to send without an approved draft, impossible to draft without requirements satisfied**. The LLM does only the fuzzy bits (is the draft missing anything? write it). *"This while loop is exactly how you'd build your own cursor."*

---

## 2. Why this is the lore frame (the mapping)

A lore **world** is a system with **entities + relationships + state + events**. The current engine models the first two and *none* of the last two. Khourshid's frame maps 1:1:

| talk concept | lore equivalent |
|---|---|
| explicit model | the **world model**: entities-as-statecharts |
| states | a character's `alive/dead`, loyalty, mood; a faction's stance; a quest's `open/active/climax/resolved` |
| events + guards | `betrays`, `dies`, `allies_with`, `completes_objective` — with guards |
| deterministic core | a Go/SQL engine that **validates + applies** transitions and records the event log |
| LLM at the edges | loremaster *proposes* events; persona *voices* current state; narration *describes* transitions |
| "impossible to send without approval" | **"impossible for a dead character to speak," "impossible to resolve a quest without its climax-guard"** |

**Why it matters for lore specifically:** the current "world advances by LLM" path (or doesn't advance at all) is the canon-drift trap — a persona invents a fact that contradicts canon; a re-run of world-build produces a different world. A deterministic core makes the world **reproducible** (replay the event log → identical state) and **consistent** (a persona answers from its *current modeled state*, not a fresh hallucination). The model becomes the **shared language** between you, the loremaster, and every NPC persona.

---

## 3. The current pg-ai-stewards stack (what we're improving — grounded)

| layer | where | notes |
|---|---|---|
| **data model** | `extension/54-loreworks.sql:19-73` | Postgres-native (NOT Neo4j/AGE — deliberate, for RLS+ACID). `worlds`, `world_entities` {kind, name, aliases, summary, **source_refs jsonb**, embedding, metadata; 6 kinds + concept fallback}, `world_edges` {src, dst, **rel_type**, evidence, metadata} — typed directed adjacency. Idempotent upserts auto-create concept endpoints (`55-loreworks-build.sql:55-158`). Every entity is **source-grounded** (quote/doc/chunk/object locator). |
| **3D view** | `cmd/stewards-ui/frontend/src/views/stewdio/WorldGraphPanel.vue` | **`3d-force-graph`** (Three.js force-directed), **Vue 3**. Nodes colored by kind + sized by degree; edges colored by rel_type; SpriteText labels; provenance detail drawer. Data via `/api/world/graph` → `stewards.world_graph(slug)` (`54-loreworks.sql:188-200`). |
| **chat** | `extension/57-loreworks-chat.sql:19-146` | a **single read-only LOREMASTER per world** (tools: `lore_search`/`lore_entity`/`lore_neighbors`; hybrid lexical+semantic via `embed_query`). **No per-entity NPCs, no persona state, no multi-turn voice** (a `cmd/persona-host/` exists but isn't wired to lore). |
| **flow/state views** | — | **none for lore.** A `assemble_trajectory()` exists for ML-judge eval (not viz); work-items show stage *cards*, not a graph. No state machine, DAG, or timeline. |
| **world advancement** | — | **entirely missing** (scout §5). Static snapshot: build populates, LOREMASTER reads, nothing mutates. No events, no state, no progression, no event log, no branching/alternate worlds. |

**The gaps the scout found** (these are the integration targets): no entity **state**; no **temporal** dimension; no **symmetric** relationships / **edge attributes** (strength/confidence); no graph **analytics** (centrality/community) or **rel-type filtering**; no **timeline/quest/flow** view; no **node/edge editor** (all writes are agent-mediated); single LOREMASTER, no **multi-NPC** voicing; **no world-advance mechanism at all.**

---

## 4. The proposed deterministic core (the model layer)

Concrete, Postgres-native (keeps the RLS+ACID design — don't add a graph DB):

**4a. Schema (additive, on top of `54-loreworks.sql`):**
- `world_entities` gains a **`statechart jsonb`** (an XState-v5-serializable machine def: states, events, transitions, guards) and a **`state jsonb`** (the *current* value + context). Most entities can start with a trivial 1-state machine; only the confusing ones (quests, key characters, factions) get rich charts. *(Khourshid: model only the confusing parts.)*
- new `world_events` — the **deterministic event log**: {world_id, entity_id, type, payload jsonb, caused_by (source_ref / agent / player), occurred_at, story_time}. This is the missing **temporal dimension** *and* the replay tape.
- (optional) `world_edges` gains `valid_from/valid_to story_time` + `confidence` + a `symmetric bool` — fixing the no-temporal / no-edge-attribute gaps.

**4b. The engine (Go/SQL — the deterministic core):**
- `world_event_apply(world, entity, event, payload)` — look up the entity's statechart + current state, **check the guard**, compute the next state via the XState transition semantics (reimplement the subset in Go/SQL, or call a tiny embedded JS via the existing model runner), **append to `world_events`**, update `state`. Returns accept/reject + the new state. *This is the "impossible to send without approval" guarantee.*
- `world_replay(world, until_story_time)` — fold the event log from the initial states → deterministic world state at any point (reproducibility + "alternate worlds" = replay a forked event log).

**4c. The LLM at the edges (unchanged philosophy, new boundary):**
- **world-build / loremaster PROPOSE events** (`world_event_apply` validates — a rejected event is canon-drift caught at the gate).
- **personas voice current state** — extend LOREMASTER (or wire `persona-host`) so "what does Aragorn think?" routes to an entity persona seeded with that entity's *modeled state + 1-hop neighborhood*, not a free hallucination.
- **narration generates from transitions** — the model says *what* happened (deterministic); the LLM says it *beautifully* (fuzzy edge).

---

## 5. What to adopt from Stately Sketch (cloned, MIT)

`external_context/stately-sketch` — React 19 + XState 5, MIT, small (1.1M). Modular cores worth borrowing (concepts; stewdio is Vue, so adapt — don't drop the React components in):

1. **`@statelyai/graph` (MIT, standalone)** — the statechart→positioned-graph **layout** lib sketch uses (not React Flow). *Verify it's framework-agnostic* — it computes node positions, so the output should be renderable from Vue / fed to Cytoscape even though sketch renders it in React.
2. **The simulator** (`src/components/SimulationPanel.tsx` + `src/lib/machine.ts`, `useTick.ts`) — steps transitions, guards, *delayed events*. Adapt into a **world-replay stepper**: scrub the `world_events` tape, step a quest, preview a transition before applying it. This is the single most lore-valuable borrow.
3. **Multi-format I/O** (XState code / JSON / YAML / **Mermaid**, via CodeMirror langs) — the **serialization bridge**. **Mermaid is the LLM-friendly format**: the loremaster emits a `stateDiagram-v2`, it renders directly; the human edits; it round-trips to the JSONB statechart. XState v5 defs are JSON-serializable → store charts as JSONB.

License note: Sketch + `@statelyai/graph` are MIT — adapt freely.

---

## 6. The view stack (the "other chat/flow/graph views")

Grounded in the reality that **stewdio is Vue** — so the React-first tools become Vue equivalents. The governing principle (from the React-Flow-vs-Cytoscape landscape): **edit and explore are different jobs; use different views over the *same* model.**

| view | library | job | fixes which gap |
|---|---|---|---|
| **inhabit (3D)** | **`3d-force-graph`** (keep — it's good) | immersive world graph | — (already solid) |
| **edit (flows/statecharts)** | **Vue Flow `@vue-flow/core`** (MIT — the Vue port of React Flow; *use this, not React Flow, because stewdio is Vue*) | editable quest/character statecharts + a **node/edge editor** (direct CRUD) | no flow view, no editor |
| **analyze** | **Cytoscape.js** (MIT, framework-agnostic) | centrality, **community detection** (factions as subgraphs), **rel-type filtering**, fcose layout, large graphs | no analytics, no rel filters, scaling |
| **LLM-sketch** | **Mermaid** (MIT) | the loremaster emits state/flow/timeline diagrams, rendered live | LLM ↔ model bridge |
| **statechart + sim** | **`@statelyai/graph`** + the sketch simulator pattern | per-entity statechart + the replay stepper | no state view, no simulation |
| **timeline** | a simple custom view over `world_events` (or vis-timeline, MIT) | narrative/causality by story_time | no temporal/timeline view |

Don't force one library to do every job: **3d-force-graph to inhabit, Vue Flow to edit, Cytoscape to analyze, Mermaid for LLM sketches** — all reading the one world model. Chat stays, but the upgrade is **grounding each persona in its entity's modeled state**.

---

## 7. The concrete first step (model only the confusing parts)

Per Khourshid's closing advice ([t1651](https://www.youtube.com/watch?v=uMvTAF280so&t=1651)) — *"pick one confusing workflow and model it explicitly"* — the smallest deterministic-core slice:

1. Pick **one quest** (or one character arc) in an existing world.
2. Add a `statechart jsonb` + `state jsonb` to that entity; write its chart (or have the loremaster emit it as **Mermaid** → convert).
3. Implement `world_event_apply` for just that chart + an append to a new `world_events` table.
4. Render it with `@statelyai/graph` (or Mermaid) in a stewdio panel; wire the **sketch-style simulator** to step it.
5. Have the LOREMASTER **propose** an event and watch the engine accept/reject it against the guard.

That proves the loop end-to-end on one entity before generalizing to the whole world. (Inverse-hypothesis it: try an *illegal* transition and confirm the engine rejects it — the "impossible to send without approval" guarantee, lore-edition.)

---

## 8. Build-vs-borrow / licenses

All MIT, all adaptable: Stately Sketch, `@statelyai/graph`, Vue Flow (`@vue-flow/core`), Cytoscape.js, Mermaid, `3d-force-graph`. Keep the Postgres-native graph (no Neo4j/AGE). The *engine* (transition validation, replay) is ours to write in Go/SQL; the *views* are borrowed Vue/JS libs over our model; the LLM stays at the edges.

**One-line for the council:** the lore world wants a deterministic core (entities-as-statecharts + an event log + a validating engine) so the world is reproducible and canon-consistent, with the LLM creative at the edges — and a small Vue view-stack (Vue Flow + Cytoscape + Mermaid + the kept 3D graph + a sketch-style simulator) to edit, explore, and replay it.
