# 2026-06-25 — Loreworks C: hybrid lore search + the loremaster, proven live

Ultracode, toward Friday. Built C (the "chat with your world" + search-by-meaning
experience) from the design fan-out's spec, while a dev agent builds the 3D graph panel
in parallel. Shipped (`57-loreworks-chat.sql`) + proven live on the real Middle-earth world.

## What shipped (57)

- **`world_entity_hybrid(world, query, limit)`** — the semantic leg the 54 engine promised:
  fuses the lexical leg (`world_entity_search`) with a cosine leg (`embed_query` over the
  entity embeddings). Degrades to lexical when no embed provider is configured.
- **`world_entity_embed(world)`** — backfill entity embeddings (name + summary) via embed_query;
  granted to `world-build` so a fresh build self-embeds.
- **`lore_search` / `lore_entity` (1-hop neighborhood) / `lore_neighbors` (BFS ≤2)** tools.
- **the read-only `loremaster` agent** — deny * + the lore tools + canon read; cites, never invents.
- **`lore_inject(world, scan_text)`** — a deterministic, model-free lore block for a world-room
  turn (G's auto-injection; zero extra model calls).
- Backend `world.go` (`/api/world/{list,graph,node}`) was committed earlier (`2c0d452`) for the panel.

## Proven live (the two demo beats)

**Beat 4 — search by meaning.** Embedded the-one-ring's 69 entities (nomic, local), then queried
`"an abandoned ruined city beside a lake"` — **zero shared words** with any entity — and the top hit
was **Annúminas** (0.39), the ruined Númenórean capital on the shore of Lake Evendim, followed by
Tharbad, Lake Evendim, the Western Tower. The meaning leg finds what the words never named.

**Beat 6 — chat with your world.** Dispatched the loremaster (local) on "What is the Brandywine, and
what lies along it?" — it made **5 lore-tool calls** and answered with a grounded map: the Baranduin
flowing from Lake Evendim across the North Moors to Eryn Vorn, dividing the Eastfarthing from Buckland
and the Old Forest, bordering Minhiriath. Every detail traces to the gazetteer it was built from —
no hallucination.

## State

The full Loreworks EXPERIENCE is now proven end-to-end on the dev stack: drop lore → world-build
(E2) → search by meaning (C) → chat with the world (loremaster) → the Glass-Box critic keeps edges
honest (56). The 3D knowledge-graph panel (the visual showpiece) is building in a parallel dev agent.
Embed config on dev: `embed_provider=lm_studio`, `embed_model=text-embedding-nomic-embed-text-v1.5`.

## Next (toward Friday)

- 3D graph panel (dev agent, in flight) — verify it renders the-one-ring.
- B: build the other two worlds (MLP + Star Trek) with text+vision + the critic.
- G: persona-host wiring (the lore_inject primitive is built; the Go splice in turnloop.go remains).
- F: assemble the walkthrough video (script written; hyperframes MCP + voice-clone the his-hands setup).
- Fold in the deterministic `world_edge_audit` (design doc §c.2) for fuller edge-grounding.

Chain 00→57 green (virgin-smoke OK 47). Task #265 (C) substantially done — the 3D graph is the
remaining piece. Memory `project_loreworks`.
