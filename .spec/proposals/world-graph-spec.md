# World-Graph: Projects, Worlds, and the Cross-Service Code Graph

**Status:** DRAFT — for council / ratification
**Date:** 2026-06-30
**Author:** Claude (pg-ai-stewards lane), at Michael's direction
**Supersedes/completes:** `loreworks-cross-project.md` follow-on ② (cross-world reference edges)
**Grounded in:** the live schema (`worlds`, `projects`, `world_entities`, `world_edges`) + three source-grounded tool evaluations (graphify MIT, logiclens MIT, glia + GitNexus PolyForm-NC) + the multi-tenancy proposal §5.

---

## 1. What this is

Today a **World** (Loreworks) is a flat graph of entities + intra-world edges with embeddings and RRF search. It cannot (a) be organized into a hierarchy, nor (b) link to another World. This spec adds both, and in doing so turns the world-graph into a **cross-service code graph**: a microservices platform becomes a tree of projects-and-worlds whose services link to each other across HTTP / gRPC / pub-sub / GraphQL / shared-schema boundaries — queryable as one graph.

The motivating picture Michael drew:

```
platform           (project, root)
├── auth           (world)
├── user           (world)
├── account        (world)
└── eco            (sub-project)
    ├── devices    (world)
    └── 3rd-party  (world)
apps               (project, sibling of platform)
├── ios            (world)
└── android        (world)
```

…where **any entity in any world can link to any entity in any other world** — `ios` calls `auth`'s login endpoint; `devices` publishes a topic `account` consumes — and the **picker is a tree** so all of it is easy to find.

---

## 2. The model — two concepts, not one

Michael asked the right question: *"projects, or worlds that can contain worlds?"* The answer is **two concepts with different jobs**, because they have genuinely different responsibilities:

| | **Project** | **World** |
|---|---|---|
| role | namespace · access boundary · picker grouping · repo/system root | the entity-graph itself |
| holds | sub-projects + worlds | entities + intra-world edges + embeddings |
| hierarchy | **yes — n-level tree** (`parent`) | leaf (belongs to one project) |
| analogy | the folder | the graph inside the folder |

A **project is the recursive container; a world is the leaf graph.** We do *not* make worlds recursively contain worlds — projects already provide the nesting, and conflating the two would muddy "does this world hold entities or just children, and do edges cross into it?" (Escape hatch: if a single world ever needs internal sub-structure — e.g. `auth` → `oauth` / `sessions` — we can add `worlds.parent_world_id` later without disturbing this model. Not needed for any case on the table.)

Cross-boundary links are **between entities** (each entity lives in a world; each world lives in a project). So one edge mechanism — `cross_world_edges` — carries *every* cross-boundary link, whether it crosses a world boundary, a project boundary, or both. There is no separate cross-project-edge concept; an edge from `ios`'s client to `auth`'s endpoint simply happens to span two projects.

---

## 3. Schema (the additions)

The live tables (verified 2026-06-30):
- `projects(slug PK, name, description, root_directory, archived, …)` — flat, no hierarchy. Holds intent-projects (work-corpus, ai, books).
- `worlds(world_id PK, slug, name, summary, project text, is_private, metadata, …)` — `project` is a loose text label (star-trek, cosmere), a *separate* namespace from `projects`.
- `world_entities(entity_id, world_id, kind, name, aliases, summary, source_refs, embedding, metadata)`.
- `world_edges(edge_id, world_id, src_entity, dst_entity, rel_type, evidence, metadata)` — both endpoints pinned to one `world_id`.

### 3.1 Projects become hierarchical (D1)

```sql
ALTER TABLE stewards.projects
  ADD COLUMN parent_slug text REFERENCES stewards.projects(slug) ON DELETE SET NULL;
-- NULL parent = a root project. n-level depth via the self-reference.
CREATE INDEX ON stewards.projects(parent_slug);
-- guard against cycles (a project cannot be its own ancestor) — enforced in upsert_project().
```

`root_directory` already exists and is exactly right: a project = a repo / monorepo / system root.

### 3.2 Worlds belong to a project (D1, cont.)

Formalize the existing `worlds.project` text as a real FK to `projects(slug)`:

```sql
-- backfill: every distinct worlds.project value gets a projects row if missing
INSERT INTO stewards.projects(slug, name)
  SELECT DISTINCT project, project FROM stewards.worlds
  WHERE project IS NOT NULL
  ON CONFLICT (slug) DO NOTHING;
ALTER TABLE stewards.worlds
  ADD CONSTRAINT worlds_project_fk FOREIGN KEY (project) REFERENCES stewards.projects(slug);
```

This **unifies the two namespaces**: intent-projects (work-corpus) and world-groupings (star-trek) become one hierarchical project tree. A project can now hold intents *and* worlds *and* sub-projects. (This is the part that touches the existing intent system — flagged as council decision D1.)

### 3.3 Cross-world edges (D2 — already approved)

```sql
CREATE TABLE stewards.cross_world_edges (
    edge_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    src_entity   bigint NOT NULL REFERENCES stewards.world_entities(entity_id) ON DELETE CASCADE,
    dst_entity   bigint NOT NULL REFERENCES stewards.world_entities(entity_id) ON DELETE CASCADE,
    rel_type     text   NOT NULL,   -- http_calls | grpc_calls | publishes_to | consumes_from | shares_schema | shares_table | reads_config | depends_on
    contract_key text,              -- the normalized key that matched producer↔consumer
    protocol     text,              -- http | grpc | pubsub | graphql | schema | db | config | package
    confidence   real,              -- EXTRACTED 1.0 / INFERRED 0.55–0.95 / AMBIGUOUS (flagged)
    evidence     text,
    metadata     jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (src_entity, dst_entity, rel_type)
);
CREATE INDEX ON stewards.cross_world_edges(src_entity);
CREATE INDEX ON stewards.cross_world_edges(dst_entity);
CREATE INDEX ON stewards.cross_world_edges(contract_key);
```

The endpoints reference `world_entities` directly (not a world) — the world (and thus project) of each end is reachable through `world_entities.world_id`. This is the design glia (`MergedGraph.cross_edges`) and GitNexus (`bridge.lbug`) both arrived at independently: cross edges stored separately from intra-world edges, each confidence-graded.

### 3.4 Contracts as first-class nodes (D3)

Rather than a direct producer↔consumer edge (N×M when one route has many callers), model the **contract as a deduped entity** and link both sides to it:

```
auth.LoginEndpoint  --produces-->  Contract[http_endpoint "POST /login"]  <--consumes--  ios.LoginClient
                                                                          <--consumes--  android.LoginClient
```

The contract lives in a per-project **`contracts` world** (kind = `http_endpoint | grpc_method | topic | graphql_op | schema | data_entity | config_key | package`, name = the normalized key). **stewards' existing `(world_id, kind, name)` dedup on `world_entity_upsert` IS the producer/consumer matcher, for free** — two services emitting the same normalized contract key collide on insert. `produces`/`consumes` are `cross_world_edges`. "Who consumes `POST /login`?" becomes a 1-hop query, and fan-out is natural.

---

## 4. The cross-service resolver layer (the new capability)

The single most important finding from studying graphify / logiclens / glia / GitNexus: **cross-service linking is a deterministic key-normalization + hash join, not fuzzy link discovery.** Per protocol, extract a *producer* side and a *consumer* side (with totally different language extractors), have both emit a **structured canonical key string**, then `GROUP BY` the key.

The hard part is normalizing the key — and **it is deterministic, which makes it an oracle** (`/api/users/123` + GET → `GET /users/{id}`; `:id`/`{id}`/`${id}` → `{}`, method upper-cased, known API prefixes stripped). This is logiclens's `apiPath.ts` / glia's `normalise_http_path`, both verbatim-portable from the MIT one.

The resolvers that matter for microservices (producer / consumer / match key):

| resolver | producer | consumer | key | shape |
|---|---|---|---|---|
| **HTTP** | route def | client call (axios/fetch/requests) | `METHOD /path/{param}` | directional |
| **gRPC** | `.proto` service.method | generated stub call | `package.Service/Method` (pkg-agnostic fallback) | directional |
| **pub-sub** | publish (Kafka/NATS/Redis) | subscribe/consumer | lowercased topic name | directional |
| **GraphQL** | resolver | client op | operation name (ci) | directional |
| **shared-schema/DTO** | exported type | imported type | type name | symmetric `shares_schema` |
| **shared-DB** | table/collection def | other repo's def | `flavor:name` (`sql:users`≠`nosql:User`) | symmetric `shares_table` |
| **config/env** | env def (k8s/.env) | `process.env.X` read | var NAME | symmetric `reads_config` |
| **package** | published name | manifest dep | `ecosystem:name` | symmetric `depends_on` |

Directional resolvers emit producer→contract→consumer. Symmetric ones emit an undirected `shares_*` edge only when a key bucket spans ≥2 distinct worlds (glia's `repos.len()>=2` guard).

---

## 5. The intra-repo extractor (feeding the worlds)

A deterministic, **LLM-free** tree-sitter pass over a cloned repo, emitting code entities/edges through the existing `world_entity_upsert` / `world_edge_upsert`. Today world-build uses an *LLM* agent — right for lore/prose, wrong for code (slow, costly, non-deterministic, and the chief spiral source: world-build was the 47%-spiral outlier). The AST pass is "build the oracle first" applied to code: free, parallel, perfect-recall.

- **Entity kinds** (extend the enum): `file | module | class | function | method | interface | endpoint | rpc_service | topic | schema | config_key | data_entity | package`.
- **Edge rel_types**: `contains | calls | imports | inherits | implements`.
- **Build option:** (a) shell out to **graphify** (MIT, Python) inside the existing `research_codebase` sandbox clone lane and feed its node/edge output to `world_*_upsert` — fastest, zero new parser code; (b) Go `tree-sitter` bindings in the bridge for a native extractor — more work, no Python in the sandbox. **Recommend (a) for the spike, (b) only if shelling proves a bottleneck.**

---

## 6. The picker (hierarchical, n-level)

A recursive CTE over `projects.parent_slug` yields the tree; worlds hang as leaves under their `project`:

```sql
WITH RECURSIVE tree AS (
  SELECT slug, name, parent_slug, 1 AS depth, slug::text AS path
    FROM stewards.projects WHERE parent_slug IS NULL AND NOT archived
  UNION ALL
  SELECT p.slug, p.name, p.parent_slug, t.depth+1, t.path||' / '||p.slug
    FROM stewards.projects p JOIN tree t ON p.parent_slug = t.slug
)
SELECT t.depth, t.path, w.slug AS world, w.name
  FROM tree t LEFT JOIN stewards.worlds w ON w.project = t.slug
ORDER BY t.path, w.slug;
```

The Stewdio project/world picker and the 3D world-graph both render this tree (collapsible). RLS (below) prunes it to what the viewer may see.

---

## 7. Query & traversal

The existing recursive-CTE BFS (`lore_neighbors_tool`, `57-loreworks-chat.sql:163`) extends by **unioning the cross-edge source and dropping the single-world filter at cross hops**:

```sql
-- inside the BFS recursion, edges come from:
world_edges (g.world_id = v_world)                       -- intra-world (cheap, scoped)
UNION ALL
cross_world_edges (no world filter)                       -- cross-world / cross-service
```

Producer→contract→consumer is a 2-hop walk; impact analysis is the reverse-adjacency direction, gradeable by `confidence`. Entity ranking stays the proven `world_entity_hybrid` RRF (lexical + `embed_query` cosine, k=60, `71-hybrid-rrf.sql`) — so "find the auth logic across all my services" works *with* embeddings, which none of the surveyed tools have.

---

## 8. RLS / grants (multi-tenancy)

Grants attach to a **project subtree**: a grant on `platform` makes `platform` + all descendant projects (`eco`) + all their worlds visible. A `cross_world_edge` is visible **iff the viewer can see both endpoints' worlds** — a clean RLS predicate, and a capability none of the surveyed single-user tools have (they're all `~/.graphify`-style local files). This rides the FORCE-RLS model in the multi-tenancy proposal; single-user installs see everything (the default), so this adds nothing for the solo case until grants are turned on.

---

## 9. Build vs borrow (honest)

- **Own** the Postgres store + query — unambiguous. Every surveyed tool bolts on a *foreign* graph engine (Kuzu, LadybugDB, Neo4j, NetworkX, rkyv) that fights our deliberate Postgres-native "AGE-replacement" decision and the FORCE-RLS model that *depends* on Postgres. The cross-world-edge schema + traversal is a few hundred lines of SQL on machinery we already have (`world_entity_upsert` dedup, `lore_neighbors` BFS, `world_entity_hybrid` RRF).
- **Port the MIT code** — graphify (intra-repo AST extraction + `symbol_resolution.py`) and logiclens (the canonical-key normalizers `apiPath.ts`/`event.ts`/`path.ts` + the per-protocol resolver tiers). Both MIT → copyable.
- **Learn the taxonomy** from glia (13 resolvers, `normalise_http_path`) and GitNexus (`group/` bridge, fixpoint type resolution) — both **PolyForm Noncommercial → design-study only, no code.** The two research agents already extracted what we need.

Net: own the database, port the parsers/normalizers, learn the resolver set. Rolling our own is justified *because the store is the hard part and we already own the best one.*

---

## 10. The first spike (oracle-first, ~1 table + ~150 lines SQL)

HTTP, two toy services → one traversable cross-world edge:
1. `svc-a` exposes `GET /users/{id}`; `svc-b` calls `axios.get('/users/123')`.
2. Build each into a world under a `demo` project (shell to graphify, or hand-author the two entities for the spike). `svc-a` → entity `http_endpoint "GET /users/{id}"`; `svc-b` → a client entity whose URL normalizes (`123`→`{id}`, upper method) to the same key.
3. `resolve_cross_service(project)`: GROUP producers+consumers by `contract_key` → upsert the deduped contract entity → write two `cross_world_edges` (`produces`, `consumes`).
4. Prove traversal: a recursive CTE over `world_edges UNION cross_world_edges` returns `svc-b`'s client **starting from `svc-a`'s route — crossing the world (and project) boundary in one query.**
5. **The oracle** (build-the-oracle-first): the path-normalizer is deterministic, so the spike's test *is* the detector — assert `/users/123`+GET and `/users/{id}`+GET collide on `GET /users/{id}` → exactly one cross edge; remove the templating → confirm they stop matching (inverse hypothesis). That deterministic normalizer is the floor that makes fanning out the other seven resolvers safe.

If it traverses green, everything after is **more resolvers (each an MIT port), not new architecture.**

---

## 11. Council decisions (what needs your ratification)

- **D1 — Unify + nest projects.** Add `projects.parent_slug` (n-level) and FK `worlds.project → projects.slug`, backfilling the existing flat world labels into real project rows. This merges intent-projects and world-groupings into one hierarchy — the one change that touches the existing intent system. *Recommend: yes.*
- **D2 — `cross_world_edges` table.** (Already approved.) Separate cross-edge store, confidence-graded. *Confirmed.*
- **D3 — Contracts as first-class deduped nodes** (produces/consumes), not direct producer↔consumer edges — reuses the existing `(world,kind,name)` dedup as the matcher and makes fan-out / "who consumes X" a 1-hop query. *Recommend: yes.*
- **D4 — Two concepts (project = hierarchy, world = leaf), not recursive worlds.** *Recommend: yes; `worlds.parent_world_id` held as a future escape hatch, unbuilt.*
- **D5 — Code entity/edge kinds + the LLM-free tree-sitter extractor** replacing the LLM world-build for *code* worlds (lore worlds keep the LLM builder). *Recommend: yes — it also removes the 47%-spiral world-build path.*

This is a **new standing capability** (the presiding extension's `dominion_in_council`), so nothing here is built until you ratify. Once ratified, the spike (§10) is the first, oracle-gated step.

---

## 12. Open questions / risks

- **Migration of `worlds.project`** — the existing values (star-trek, cosmere) become root projects; confirm that's desired vs. parking them under a `lore` root.
- **Extractor language coverage** — graphify covers ~25 languages; the cross-service resolvers need per-framework producer/consumer extractors (Express/FastAPI/Spring/gRPC/Kafka…). Start with the stack Michael's platform actually uses; add frameworks as needed (each is a small, testable unit — fan-out shape).
- **Contract-key false positives** — `/health`, `/ping`, generic topic names cause N×M noise; port glia/GitNexus's noise-filter list.
- **Re-extraction cost** — incremental (graphify's sha256 + `build_merge`) keeps re-indexing cheap, but cross-service resolution re-runs per project on change; scope it to changed worlds.

---

## 13. Cosmology addendum (the nomenclature + the gravity layer)

**Origin (2026-06-30):** Michael's friend offered a cosmological frame for the hierarchy, and it maps almost exactly onto the ratified model while surfacing three real capabilities (not just names). The motivating pain is concrete: their work platform is **269 repos** — a "ball-of-mud distributed monolith" that *looks like a black hole.* The whole point of deep-loring code is to give an AI harness (and a human) the tools to **see all of it without overwhelming either's context.** This addendum is the picture the build aims at.

### 13.1 Nomenclature — the cosmic ladder names the depths (no structural change)

| cosmic | model | what it is |
|---|---|---|
| **universe** | a root project | an org / a coherent body of work |
| **galaxy** | sub-project | a platform |
| **star system** | sub-project | a sub-system — a cluster of related services |
| **world** | a world | a service / repo / bounded context (holds code) |
| **moon** | entity | a module / file / function inside the service |
| **multiverse** | the forest of disconnected components | universes with no edges between them (*yet*) |

The `projects.parent_slug` n-level tree IS the ladder; the names are a UX/picker label (an optional `projects.metadata->>'cosmic_level'` or just rendered by depth). Worlds still don't nest (D4); a star-system *project* contains world *services*; a world contains moon *entities*. Same graph, intuitive zoom.

### 13.2 Three capabilities (the part that isn't decoration) — staged AFTER the extractor

Gravity is meaningless on an empty graph, so all three land once D5 (the extractor) has populated `cross_world_edges` from real repos.

- **D6 — Gravity (a relatedness metric).** The pull between two worlds = the *weighted* count of `cross_world_edges` between them, weighted by `rel_type`: a `shares_table` is heavy gravity (tight coupling), a single `http_calls` is light. A world's **mass** = its total inbound+outbound weight — a high-mass world is a hub everything orbits. Implementable as a SQL view over `cross_world_edges` + a `rel_type → weight` config map.
- **D7 — The black-hole diagnostic (modularity).** Community detection over the gravity graph yields a **modularity score**: a healthy galaxy has clear clusters with sparse inter-cluster links; a ball-of-mud has everything uniformly bound — *a black hole* (you can't extract one service without the whole thing collapsing inward). The tool puts a number on "this is a black hole," names the gravitationally-central worlds (the singularity), and flags the heaviest cross-edges (the accretion disk) as the first decoupling targets.
- **D8 — Gravity-ranked context render (the navigation — the *purpose*).** "See everything without overwhelming context" = *orbit, don't ingest.* From a starting world, pull in only the gravitationally-nearest entities up to a token budget — the graphify token-budgeted subgraph render, but ranked by **mass** instead of degree, and zoomable by cosmic level (universe → moon). This is the substrate's own context DNA (tool shelf / `compact_context` / page-in) applied to code: a harness flies *through* the 269-repo black hole instead of loading it.

**Multiverse / latent gravity.** Disconnected components = separate universes (a `connected_components` pass over the cross-edge graph). "Things that aren't related but could be" = **latent-edge suggestions** — name-similar contracts across universes that aren't yet linked (a candidate bridge to confirm or dismiss).

### 13.3 Ratification (D6–D8)

A new conceptual + capability layer → `dominion_in_council`. D6–D8 build *on top of* the D1–D5 foundation (now merged) and the extractor, in that order: **extractor populates → gravity measures → modularity diagnoses → the render navigates.** The cosmology is the north star; the extractor is the engine that fills the sky. *Recommend: ratify the nomenclature now (free, clarifying); build D6–D8 once the extractor lands real code worlds to weigh.*

