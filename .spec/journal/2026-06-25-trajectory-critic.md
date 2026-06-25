# 2026-06-25 — Trajectory critic: Glass-Box eval, proven live (and it found a real bug)

Michael: "lets work the trajectory critic/eval into our plans." It converged perfectly with
Loreworks — the same build serves his ask, the B edge-quality fix, AND a Friday presentation
beat. Shipped + proven live (chain 56, commit `13fde61`).

## What shipped (Google's SDLC "Glass Box")

- **`assemble_trajectory(session)`** — a run's ordered steps (tool choices, args, results/
  errors, final reply) as compact jsonb. The substrate always CAPTURED the trajectory
  (messages.tool_calls + tool results); now it can be read as one object.
- **`trajectory-critic` judge** (json_object) + **`critique_trajectory(session)`** — scores
  the PROCESS: tool_selection, param_correctness, error_handling, efficiency, grounding,
  role_adherence → {scores, issues, verdict}.
- **`world-critic`** (the Loreworks application = the B edge fix): `world_edge_list` +
  `world_edge_prune` tools + an agent that reads a world's edges, grounds each against the
  canon, and prunes misreads/backwards/invented edges.

## Proven live on the real Middle-earth world

**world-critic on `the-one-ring` (85 edges):** pruned 3 with a precise journal — *"Eriador
incorrectly placed inside Lake Evendim; Brandywine River shown flowing through Lake Evendim
instead of out of it."* Real geographic misreads, caught and removed (85→82).

**generic trajectory-critic on the build run `tor-build-1`:** verdict **FAIL**, efficiency
**0.1** — *"Repeated the entire batch of ~100 edge upserts verbatim in a subsequent step …
lacks dedup/progress tracking → severe redundancy."* The world it built looks great
(grounding 0.9); the TRAJECTORY revealed the world-build agent re-emits its whole batch —
exactly the failure output-eval misses. The Glass-Box critic found a genuine, actionable bug.

## Findings (honest)

1. **The critic found a real world-build bug:** the world-build agent (55) re-emits its
   entity/edge batch verbatim in a later step (wasteful; explains the lingering in_progress
   turn on builds). **Fix for B automation:** the world-build prompt must say "do not repeat
   upserts you've already made; you may world_edge_list/world_entity_search to check progress."
   A one-line prompt tweak to 55, batched into the next rebuild.
2. **world-critic is conservative on large edge sets** — it reviewed "38 edges" of 85 in one
   pass and left some debatable ones (e.g. `Dwarves home_of Shire`). Full coverage wants
   chunked review (paginate world_edge_list) or a higher token budget. Concept proven; tune
   for completeness.

## Presentation beat (F)

"We didn't just check the output — we built a Glass-Box judge over the agent's *trajectory*,
the way Google's SDLC papers prescribe. It scored our world-builder: the world was correct
and grounded, but the critic caught it doing redundant work the output never showed. The
substrate evaluates its own process." Ties to the paper's "the agent is the product; invest
in the substrate."

Tasks #269 done. Memory `project_loreworks`. Next: the 3D graph (C, the visual showpiece) +
fold the world-build redundancy fix + chunked edge-review into B automation.
