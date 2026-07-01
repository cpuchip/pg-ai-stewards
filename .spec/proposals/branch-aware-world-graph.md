# Branch-aware world-graph (#298) — design + one decision to make

**★ REFRAMED (Michael, 2026-07-01) — branch-awareness is CORE, and it's a WORKING tool.**
My "snapshot analysis / defer the machinery" read was wrong. The real target: **269 repos
live for years–decades, a permanent soup of branches, hundreds of devs each on their own
branch (= their current task).** The tool must **show / diff / navigate / walk** the
cross-service relationships *as-of any ref*, live, so a dev gets their current task done —
"the difference between a planning tool and a working tool." So `graph_diff` + ref-scoping
+ ref-navigation are **the point, not deferrable.**

**★ The scale flips the identity model.** `ref-in-slug` (`project/world@ref`, my earlier
rec) was sized for "compare 2 refs"; at hundreds of coexisting branches it explodes world
rows — WRONG at this scale. The right model is **snapshot-as-first-class**: an indexed
`graph_snapshot(project, ref, commit_sha, imported_at)` per (repo, ref/commit); entities +
edges + cross_world_edges belong to a snapshot; ONE stable service identity underneath.
Then: **show** = latest snapshot for (repo, branch) · **diff** = set-compare two snapshot
ids · **freshness** = a new snapshot on push (re-index, not mutate) · **navigate** = query
scoped to a ref. This is how versioned code-graph tools model it, and it's the only shape
that makes all four cheap.

**★ The real deliverable surface is bigger than the Stewdio UI.** "provide tools to enable
devs to walk these relationships" = an **MCP/API a dev's IDE or agent calls**, scoped to
their branch ("what calls this endpoint on my branch? what does my branch change?"), plus
a ref selector + diff mode on the Cosmos/World views.

**★ The jagged edge (Michael, 2026-07-01) — a core ref-resolution semantic.** Not every
repo has every branch: a feature branch often touches only a few of the 269 repos. So "the
graph as-of ref R" is assembled **per repo, with fallback**: use repo's snapshot for R if it
exists, else fall back to that repo's DEFAULT (main / master / release — whatever the repo's
default is). A logical ref view is therefore a *set* of per-repo (ref-or-default) snapshots,
not a single global ref. This is load-bearing for `graph_diff` too (diffing `feature/x`
against `main` = compare the jagged R-view to the all-defaults view). The snapshot model must
record each repo's default branch so the fallback is deterministic.

**★ North star (Michael's dream, recorded 2026-07-01): walk the code in VR.** The end state
isn't a 2D graph — it's *spatial*: each service a place, each external reference / function
call a doorway with a "walk-out space" around it you can move through and see what it
connects to. The cosmology metaphor (universe → galaxy → world → moon; orbit-don't-ingest)
is literally that navigation. We already own a deterministic 3D engine (first-orbit). This
working-graph is the universe; that engine is how you eventually fly it. Design toward a
spatial, ref-scoped, walkable code-navigation experience — the graph + the diff + the
walk-tools are the substrate under it.

**Status:** foundation (ref + repo_origin + `file_path` capture) shipped (PR #22 + lodestar
`16799c8`) = a stepping stone. The full arc — **re-architect the world-graph as
snapshot-versioned + graph_diff + ref-scoped queries + the dev-facing walk-tools + a
freshness/re-index pipeline** — needs a proper design pass at this scale before building
(the snapshot model is a real migration of world_entities/world_edges/cross_world_edges).
The `route`/`file_path` naming stands. Everything below is the original small-scale design,
superseded by the snapshot model above. Ratified *scope* (prior
session): "BOTH `project@ref` quick scoping AND `graph_diff(ref_a, ref_b)`, capturing
repo-origin + ref at import (also unblocks #301 source links)." This note is the
*how*, plus one genuine fork that building it uncovered.

## What building it revealed (why this is a note, not a merged PR)

Two facts surfaced while grounding the implementation against the real code + a real
lodestar graph (train-ticket, 45 worlds):

1. **lodestar emits no repo-origin and no git ref per world.** A node is
   `{id, world, kind, name, metadata}`. The only repo signal is the *file path* baked
   into the node id after `::` (e.g. `ts-user-service::src/main/java/user/controller/UserController.java`).
   There is no git remote URL and no ref. So "capture repo-origin + ref" needs one of:
   the **caller passes them** to `import_lodestar_graph`, or **lodestar emits them**
   (read `git remote get-url origin` + the checked-out ref per world during extraction).

2. **Coexisting refs require ref in the world *identity*, not just metadata.**
   `world_upsert` dedups on `slug` (UNIQUE). Import the same service at two refs and the
   second overwrites the first unless the ref is part of the slug (`project/world@ref`)
   or a new `(project, world, ref)` unique key. **`graph_diff` cannot exist without two
   coexisting graphs** — so the diff feature *forces* the identity change. And that
   identity change ripples into the **Cosmos view just shipped (#300)**: its queries
   would mix refs unless every world query becomes ref-aware.

Net: the task splits cleanly into a **low-regret additive foundation** (safe to build on
a nod) and **one architecture fork** (should not be decided unilaterally because it
reshapes world identity + the shipped cosmos view, and its value depends on your
workflow).

## The one decision — how does a ref become part of a world?

| | **A. ref-in-slug** (`project/world@ref`; bare = HEAD) | **B. ref column** (`worlds.ref`, unique `(slug_base, ref)`) |
|---|---|---|
| Schema change | none (slug string convention) | column + unique-index migration on `worlds` (+ maybe `world_entities`) |
| Backward compat | perfect — bare slug = today's HEAD graph | needs default `ref='HEAD'` backfill |
| Query ripple | parse ref from slug, or read `metadata.ref` | every world query joins/filters on `ref` |
| Cosmos view (#300) | filter worlds to the chosen ref (default HEAD → unchanged) | same, via the column |
| Cleanliness | slug carries semantics (a little hacky) | explicit, but touches the hot path everywhere |

**Recommendation: A (ref-in-slug), default ref = HEAD → no suffix.** It's zero-migration,
backward-compatible (every existing world stays the HEAD graph), and the cosmos/world
handlers gain a single `ref` filter that defaults to HEAD (so #300 is unchanged until you
opt into a ref). `metadata.ref` + `metadata.base_world` are stamped so nothing has to
parse slugs.

**The prior-question worth your input:** is the real use *snapshot analysis* (digest the
269 repos once, see platforms, re-implement) or *continuous ref-diffing* (watch a repo
across branches over time)? If it's snapshot — which is what "digest all of work's repos
and re-platform" sounds like — then **`project@ref` scoping and source-links are the
value, and `graph_diff` is speculative.** That would reorder the build below.

## Build order (each leg independently shippable + oracle-gated)

1. **Foundation — capture at import (additive, no identity change, ready to build on your nod).**
   `import_lodestar_graph(p_project, p_graph, p_ref default 'HEAD', p_repo_origins default '{}')`
   stamps `world.metadata.{ref, repo_origin}` and `entity.metadata.{repo_origin, path}`
   (path parsed from the node-id `::` suffix). Slug unchanged. Oracle: assert the stamps
   land. **This alone unblocks #301 source-links** *once a repo_origin is available* —
   which needs leg 2.
2. **lodestar emits repo-origin + ref per world** (`git remote get-url origin`, current
   ref) into the graph JSON, so the caller doesn't hand-maintain `p_repo_origins`. Small
   lodestar change; the public repo I steward.
3. **Identity — ref-in-slug (model A)** + a `ref` filter on the world/cosmos handlers
   (default HEAD). This is the fork above; hold until decided.
4. **`graph_diff(p_project, ref_a, ref_b)`** → `{added_worlds, removed_worlds,
   added_entities, removed_entities, added_edges, removed_edges}` by matching base_world
   across the two ref families. Depends on leg 3. Oracle: import ref_a, import a mutated
   ref_b, assert the delta. *Skip if the answer to the prior-question is "snapshot."*
5. **UI** — a ref picker on the World/Cosmos panel + a diff view (two-ref compare). Rides
   on legs 3–4; a #300-style subagent build.

## My proposed default (if you just want me to proceed)

Build **legs 1 + 2** now (capture + emit — pure additive, unblocks source-links, low
regret), and **hold legs 3–5** for a one-line ratify on model A + the snapshot-vs-diff
question. That ships the concrete value this session and keeps the identity change (which
touches the cosmos view you just got) a deliberate choice, not a silent one.
