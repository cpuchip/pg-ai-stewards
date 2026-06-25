# 2026-06-25 — Loreworks B: the empirical TTRPG probe (a real Middle-earth world)

Michael, awake and emphatic: "take this bull by the horns … you can manage the embed
server … the pages have more than text, use vision … do a few pages at a time and see
what issues it uncovers, then automate the other 2." This is that probe — and it built a
real world.

## What ran

The One Ring core rules (248pp). Rendered + extracted with the doc-extract image's poppler
(host has none). Found the gazetteer (pp. 181-230 by place-name density). Extracted +
watermark-filtered pp. 181-188 (~25KB clean text) and dispatched the **world-build agent**
on it (local 'reason' alias, qwen3.6-35b). Result, in ~3-4 min, $0, fully local:

**World `the-one-ring`: 69 entities + 85 edges** (44 places / 14 factions / 8 characters).
Every entity grounded real Tolkien — Bree-land, Annúminas, Barrow-downs, Lake Evendim, the
Brandywine, the Misty Mountains, Chetwood, Staddle, the Bree-wardens, named NPCs. Live in
the dev pg (world_show / world_graph 'the-one-ring').

## Issues the probe uncovered (the point of doing a few pages first)

1. **DRM watermark** — "Michael Stufflebeam (Order #…)" is stamped on EVERY page →
   pollutes text/embeddings/entities. Filtered with `grep -v` here; **the import path needs
   a watermark stripper** (configurable per-source, or a heuristic: a line repeated on
   every page = watermark).
2. **Text extraction mangles stylized layout** — letter-spaced headers ("L E A D WRIT E R"),
   soft-hyphens. Body text is clean; **stylized headers, sidebars, maps, and art are where
   VISION wins** — the model reading the rendered page parses what pdftotext can't. Text +
   vision is genuinely complementary, not redundant (Michael's instinct, confirmed).
3. **Front matter** — pp. 1-8 are title/credits/legal. Target the gazetteer, skip the front.
4. **Edge quality needs a tuning pass (the real one).** Entities are excellent; relationships
   are ~75% right but: the `home_of` verb is applied inconsistently (inhabitant→place,
   inverting its natural direction), and there are genuine **misreads** (`Dwarves home_of
   Shire` — the text said dwarven traders *pass through*; `Cole Pickthorn ruled_by Bree` —
   backwards). Fix: (a) a **rel_type vocabulary with defined direction** — the substrate
   ALREADY has `graph_vocabulary` (19 verbs/4 groups from the edge-verb work); world-build
   should reuse/extend it and the world_edge_upsert tool should validate against it; (b) a
   **grounding critique pass** (a second agent re-checks each edge against the source, drops
   misreads — the same build-the-oracle / critic pattern the digesters use).
5. **Dense chunks front-load entities, then edges** — at ~25KB the agent did 66 entities
   before any edges (looked like "0 edges" mid-run; 85 edges landed on continuation).
   Smaller chunks (a few pages) keep entities+edges interleaved and fit the step budget.

## The automation plan (for the other 2 books + The One Ring at full scale)

A **world-build pipeline** (the deferred E2 scheduled pipeline) that, per source:
ingest (doc_extract → text + page pixels, **watermark-stripped**) → chunk into a few pages
→ per chunk: **world-build (text + vision page-images via content_parts → the vision alias)**
→ **edge-critique** (ground-check edges vs source, drop misreads, normalize verbs vs
graph_vocabulary) → embed entities (embed_query/nomic) for semantic lore search (C). Run it
on MLP + Star Trek Adventures + The One Ring (full 248pp), file_private, local GPUs (the
point of owning them — use them). Watch the first, automate the rest.

## Vision: wiring (understood, not yet built)

Render works (poppler in doc-extract). The path: page PNGs → chat_attachments (session) →
`chat_attachment_parts` builds image_url data-URL parts → `dispatch_chat_turn(p_content_parts)`
auto-routes to the **vision alias** (`flexllama/gemma-4-26b-a4b`, supports_vision=true). The
open question to settle in the build: does gemma tool-call (world_entity_upsert) reliably
WHILE doing vision? — test on a map page (TOR_Player_Map_of_Eriador.pdf is pure-vision lore).

## Prior art to mine (Michael's pointers, located)

`external_context/SillyTavern/` + `external_context/sillytavern-DeepLore/` — lorebooks /
world-info / character cards / group roleplay = directly the C (lore lens) + G (world chat
rooms) experience. `external_context/google-new-sdlc/NOTES.md` — the **trajectory critic**
(Glass Box eval) is a high-leverage substrate add (banked, separate from Loreworks).
ai-chattermax + dnd-tools = the room/persona/dice machinery for G.

Demo artifacts in dev pg: worlds `the-one-ring` (real, 69/85) + `lore-smoke` (synthetic,
10/10). Task #264 in progress (probe done; automation + vision next). Memory `project_loreworks`.
