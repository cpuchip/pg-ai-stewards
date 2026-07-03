# Working-Graph build spec (#298, ratified 2026-07-02) — snapshot-versioned, branch-scoped

**Status: BUILD SPEC (drafted 2026-07-03 overnight, Michael's "all 5 worth doing" green light).
The design was ratified in `branch-aware-world-graph.md`; this is the concrete build order.
Each phase lands separately with its own oracle; the whole arc is NOT one night.**

## What this is for (one paragraph)

269 repos, years of life, a permanent soup of branches, hundreds of devs each on their own
branch. The world-graph must **show / diff / navigate / walk the cross-service relationships
as-of any ref**, live — a *working* tool for "what does MY branch change?", not a planning
snapshot. Identity model: **snapshot-as-first-class** (a graph_snapshot per repo+ref+commit;
entities/edges belong to snapshots; ONE stable world identity underneath). Jagged edge: a
logical ref view = per-repo (ref-or-default) snapshot set.

## Current state (what we build on)

- `stewards.worlds` (project-scoped slugs) · `world_entities` · `world_edges` ·
  `cross_world_edges` — ONE live graph per world; re-import mutates in place.
- `import_lodestar_graph(project, jsonb)` lands lodestar output; lodestar already emits
  `WorldMeta{RepoOrigin, Ref}` (+ file_path on nodes) since the #22 ref-capture foundation.
- The Cosmos/World UI reads the live tables directly; `max_nodes` cap + lite tier (huge-world
  fix) already in.
- The Loremaster/lore_* chat tools walk `world_edges` within one world.

## Phase A — the snapshot spine (schema + import re-point)

New chain file `86-graph-snapshots.sql` (or next free number at build time):

```sql
CREATE TABLE stewards.graph_snapshots (
    snapshot_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    world_id      bigint NOT NULL REFERENCES stewards.worlds(world_id) ON DELETE CASCADE,
    ref           text   NOT NULL,              -- branch/tag as named by the importer
    commit_sha    text,                         -- exact commit (lodestar gitmeta)
    imported_at   timestamptz NOT NULL DEFAULT now(),
    is_default    boolean NOT NULL DEFAULT false, -- this ref is the repo's default (main/master/release)
    stats         jsonb  NOT NULL DEFAULT '{}'::jsonb  -- {nodes, edges, cross_edges} for cheap UI
);
CREATE UNIQUE INDEX ON stewards.graph_snapshots (world_id, ref, coalesce(commit_sha,''));
CREATE INDEX ON stewards.graph_snapshots (world_id, ref, imported_at DESC);
```

- `world_entities` + `world_edges` + `cross_world_edges` gain `snapshot_id bigint NULL
  REFERENCES graph_snapshots` (NULL = pre-snapshot legacy rows = treated as the default
  snapshot; a backfill migration step creates one `legacy` snapshot per code-world and
  adopts existing rows, so NOTHING breaks on upgrade — the virgin gate proves both paths).
- **Import re-point:** `import_lodestar_graph` (a) resolves/creates the world by stable
  slug (unchanged — identity is the world), (b) creates a graph_snapshot from the emitted
  RepoOrigin/Ref/commit, (c) lands entities/edges tagged with that snapshot_id, (d) marks
  `is_default` when the ref equals the repo's default branch (importer passes it; lodestar
  gitmeta can emit `default_branch` — small lodestar addition, file an issue), (e) PRUNES:
  keep last N snapshots per (world, ref) (config `snapshots_keep_per_ref`, default 3) +
  never prune is_default's latest. Re-import of the same (world, ref, sha) is idempotent
  (replace).
- Cross-edge resolution runs WITHIN a snapshot set: importer resolves cross_world_edges
  among the snapshots in the same import batch + the latest default snapshots of other
  worlds (the jagged edge, applied at import).

**Oracle A:** virgin 00→86 green; legacy adoption proven (import pre-86 fixture → migrate →
rows adopted, UI unchanged); import same repo at 2 refs → 2 snapshots, distinct
entity/edge sets, world count unchanged; prune keeps N.

## Phase B — the ref view (the jagged-edge resolver)

```sql
-- The heart: resolve a LOGICAL ref across the whole project.
-- For each world: the latest snapshot AT p_ref if one exists, else the latest
-- default snapshot (main/master/release — whatever that repo's default is).
CREATE FUNCTION stewards.ref_view(p_project text, p_ref text)
RETURNS TABLE (world_id bigint, snapshot_id bigint, ref_used text, fell_back boolean);
```

- All graph-reading API paths (`world_graph`, cosmos, node detail) gain an optional
  `p_ref` — when present they select entities/edges via `ref_view` instead of "the live
  rows". Default (no ref) = the default-branch view, which after Phase A is identical to
  today's behavior.
- **Oracle B:** two-repo fixture where repo1 has branch `feat-x` and repo2 doesn't →
  `ref_view(project,'feat-x')` returns repo1@feat-x + repo2@default with `fell_back=true`;
  cosmos rendered at the ref differs exactly by repo1's branch delta.

## Phase C — graph_diff

```sql
CREATE FUNCTION stewards.graph_diff(p_project text, p_ref_a text, p_ref_b text)
RETURNS jsonb;  -- {added_nodes[], removed_nodes[], added_edges[], removed_edges[],
                --  added_cross[], removed_cross[], per_world:{...counts}}
```
Set-compare of the two ref_views keyed on the stable node identity (world + kind + name —
the same key the (world,kind,name) matcher already uses) and edge identity
(src,dst,rel / protocol+contract_key for cross). Deterministic; pure SQL.
- UI: a "diff mode" on Cosmos/World — pick ref A/B, render additions green / removals red
  (dim the unchanged). Ship the API + a minimal UI first; the beautiful diff view can
  iterate.
- **Oracle C:** fixture branch adds one endpoint + one cross edge → diff reports exactly
  those; diff(a,a) = empty; inverse: diff(b,a) mirrors added↔removed.

## Phase D — the dev-facing walk surface (MCP/API)

The real deliverable: **a dev's agent/IDE asks questions scoped to their branch.**
New MCP tools (HTTP-MCP, read-only, project+ref scoped):
- `graph_whats_changed(project, ref)` → graph_diff vs default, summarized.
- `graph_who_calls(project, ref, world, name)` → inbound edges (within-world + cross)
  resolved at the ref view.
- `graph_walk(project, ref, world, name, depth<=3, direction)` → BFS over world_edges +
  cross_world_edges at the ref view (this is ALSO the cross-world lore_neighbors ask —
  one implementation serves chat + IDE).
- `graph_snapshot_info(project, ref)` → per-world freshness (ref_used, fell_back,
  imported_at, commit) — "how stale is what I'm looking at".
All read-only → safe autonomous surface; grants via the normal tool-perm rows.
- **Oracle D:** each tool against the two-ref fixture; who_calls at feat-x sees the new
  caller, at default doesn't.

## Phase E — freshness (re-index on push)

Out-of-band (not the extension): the workchip runner re-runs lodestar per repo on a
schedule / on push-webhook, imports with (repo, branch, sha). The substrate side is DONE
by A (idempotent snapshot import + prune). Deliverable here = a small runner script +
runbook doc for the work machine (their side already validates repos; this makes it a
loop). Freshness surfaces via graph_snapshot_info + a staleness badge in the UI ref
picker.

## Sequencing + the honest costs

A → B → C → D can land one PR each (A is the invasive one — schema + import + legacy
adoption; do it first and alone). E is workchip-side. The lite-render + max_nodes work
composes unchanged (caps apply to whatever view the ref resolves). RLS (multi-tenancy)
stays orthogonal: snapshot rows inherit the world's project scoping.

Risks: (1) table bloat — snapshots multiply rows; prune policy + stats jsonb keep the UI
cheap; measure at workchip scale (88k-node worlds × N refs) before widening keep-N.
(2) cross-edge identity across snapshots — resolve at import within the batch + latest
defaults; do NOT try to lazily re-resolve at read time (that's the O(n²) trap).
(3) UI ref picker sprawl — refs are many; picker = search + recent + default, not a
dropdown of hundreds.
