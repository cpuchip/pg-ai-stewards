# Proposal: FLEET-GLASS (#367) + S4 trace-replay

**Status:** DRAFT (executes in a coming session) · **Date:** 2026-07-14 · headline arc
**Pairs with:** the Activity endpoint (`/api/activity`), the Stewdio cockpit
(`cmd/stewards-ui`), the A2A engine (v13), the World/Cosmos graph views.

## Binding problem

**An agent you can't see is an agent you can't improve.** The engine dispatches
seats, spends tokens, walks tools, and advances stages — but the operator has no
single live surface that shows the *fleet* working, and no way to replay *how* one
work item reached its answer. FLEET-GLASS makes the fleet legible; **S4** replays a
work item's tool/retrieval walk over a graph so a run can be inspected step by step.

The glass **observes**. It does not steer (no dispatch/cancel/pause buttons in v1).

## What already exists (the data-source map)

Most of the seats/spend glass is present; only the trace-replay half needs new
recording. Schema lives in `extension/src/schema.rs` + numbered SQL volumes.

| Glass element | Source (have) | Notes |
|---|---|---|
| Active work + stage + model + spend | `work_items` + `cost_events`, via `GET /api/activity` (`active`) | already rendered by `ModelsPanel.vue` (dev-only "Activity" pane) |
| Live dispatch pulse | `cost_events` (last N), `/api/activity` (`recent`) | per-call provider/model/tokens/$ |
| Per-stage progress | `work_items.stage_results` jsonb + `pipelines.stages` template | JSONB blob, not rows; keyed by stage name |
| Spend rollups | `cost_events`, `cost_buckets`, `upstream_micro_dollars` | real gateway $ where the provider reports it |
| Non-LLM tool/sandbox activity | `work_queue` (kind `mcp_proxy`), `/api/activity` (`tools`) | container runs (extract/coder/scan) |
| Seats (registry) | `a2a_agents` — agent_id, kind, lane, capabilities, scope, last_seen | **no list/aggregation endpoint yet** |
| Graph to replay over | `/api/world/cosmos` (services) · `world_graph(slug)` (one world) | both wrong grain for a per-item tool walk (see S4) |

**Missing — the S4 prerequisite:** there is **no per-tool-call trace row** at the
granularity S4 needs (`seq, tool, summary, paths[], write`). The `tool_calls` table
exists but is **dormant/empty** and lacks `seq`/`paths`/`write`; live per-call data is
only OpenAI-native `messages.tool_calls` JSONB (no paths, no write flag); `receipt.go`
reconstructs *reads* only ("what was fetched, not necessarily used"). So S4 opens with
a **recording migration** before any replay UI can be honest.

## S4 reference pattern (understory, read directly)

`core/src/agent/trace.ts`: `TraceStep {seq, tool, summary, paths[], write?}`;
`QueryTrace {kind: query|mutation|chat, input, steps[], notation}`; traces persisted
as telemetry with the rule **"never fail the run over a trace."**
`web/src/components/GraphView.tsx`: replay = visited concepts drawn as **numbered
bowed hops** (perpendicular offset, alternating), a **0–100 scrubber** mapped onto the
hop chain, **play/pause** auto-sweep, **visited-node rings** that light as the scrubber
reaches each, **write calls flagged**, path colored by kind, off-path nodes dimmed.

## Stages (each ships value; every stage has an oracle)

**Stage 1 — Fleet glass (seats · spend · stage), read-only, existing data.**
Elevate the fleet view to a first-class cockpit panel: active work items with a stage
progress indicator (from `stage_results` vs the `pipelines.stages` template), seats
(from `a2a_agents` + who is assigned), the live dispatch pulse, and spend. Backend gap:
one small `GET /api/fleet` that aggregates the seat registry with active work_items
(no new tables). Frontend assembles over `/api/activity` + `/api/fleet`.
*Oracle (house rule — build the oracle first):* a **golden-fixture** JSON (abstract:
`seat-alpha` on `pipeline-x/item-1`, 2 seats, one idle) renders deterministic rows; a
Go table-test asserts `/api/fleet` shape and that **zero rows degrade cleanly** (empty
fleet, unreachable rig). No live $ figure asserted — fixtures only.

**Stage 2 — Trace recording (the S4 foundation) · own migration volume.**
Add per-tool-call trace rows at `TraceStep` granularity (`seq, tool, summary, paths[],
write`) scoped to a work item — either by waking + widening the dormant `tool_calls`
table (add the three columns) or a purpose-built `work_item_trace` table (open Q 5).
Recording obeys understory's rule: **a trace write must never abort a dispatch.**
Expose `GET /api/work-items/{slug}/trace` returning the `QueryTrace` shape.
*Oracle:* virgin-smoke — a dispatched fixture work item writes **N ordered rows**;
a known write-tool row has `write=true`; `paths[]` is populated for a read tool;
killing the trace insert leaves the dispatch **green** (telemetry-never-fails-run).

**Stage 3 — S4 replay overlay.**
Port the understory replay into a Vue overlay on the chosen graph view (open Q 3):
numbered bowed hops, scrubber, play/pause, visited-node rings, **write hops in amber**,
off-path dimming, the compact one-line notation strip. Reads Stage-2 traces; a run
picker lists a work item's recorded walks.
*Oracle:* a fixture `QueryTrace` (3 steps, 1 write) drives the overlay to draw 2 hops,
light 3 rings in order, and paint the write hop amber — asserted headless via the
component's derived state (hop count, ring-reached indices, per-hop color), not a
pixel diff.

## ui-craft companion note

The panel must respect the cockpit's existing visual system, not invent a new one —
the private **ui-craft** skill (feel-words→knobs lexicon, tokens, and the `ui-lint`
oracle) governs this repo's UI. Reuse the established dark surface, the zinc scale, and
the palette already in `ModelsPanel.vue`/`CosmosPanel.vue` (emerald=live, amber=in-
flight/write, rose=error, sky=info). Run `ui-lint` before ship; report which knobs were
turned. Density is high by design (an ops surface) — keep it calm, not cluttered.

## Non-goals (v1)

- **No auto-router** — parked (standing-autonomous-loop class; council word required).
- **No write actions from the glass** — v1 observes; dispatch/cancel/pause is later.
- **No advanced mode** — the "diffs + mid-thoughts + jump-in" framing (#367 note) is v2.
- **No live push required** — adaptive poll is acceptable for v1 (open Q 1).
- **No new tables in Stage 1** — recording tables are Stage 2 only.

## Open questions for Michael

1. **Live update:** WebSocket push vs adaptive poll? (Existing panes poll 2.5s live /
   8s idle — cheap and proven. Lean: keep poll for v1, note push as a later lever.)
2. **Live spend:** does the seats panel show per-dispatch **$** live, or tokens live
   with $ on the 24h rollup / hover? (Live $ is available but noisy.)
3. **Which graph does S4 replay over?** Cosmos (3D services) is the wrong grain;
   a per-work-item **doc/path-touch subgraph** is the closest analog to understory's
   concept graph and matches the trace's `paths[]`. Lean: build the subgraph.
4. **Panel placement:** a new first-class "Fleet" pane, or promote the dev-only
   "Activity" pane to the everyday surface? (Binding problem argues first-class.)
5. **Recording target:** wake the dormant `tool_calls` table (+3 columns) vs a new
   `work_item_trace` table; and record **all** dispatches or opt-in per pipeline
   (volume/cost)?
6. **"Seat" definition:** A2A registered agents (`a2a_agents`), role-alias pool members
   (reason/critic/ingest/vision), or foreman pool seats? (Lean: active dispatches
   grouped by the agent/model doing them — closest to `a2a_agents` + active work_items.)

## Creation-cycle note

Intent traces to the binding problem (see the fleet). Stewardship: the arc executes in
`cmd/stewards-ui` + one migration volume; the Hinge merges. Line-upon-line: Stage 1
stands alone (glass on existing data); Stage 2 is inert recording; Stage 3 needs both.
Atonement: recording is telemetry (never fails a run); the glass is read-only (nothing
to roll back). Consecration: the visibility surface that later widening arcs (e.g.
incident sources, the warm-resident seat) are gated on.


## Ratification (2026-07-14, Michael)

All six leans RATIFIED as v1 ("we'll try that then modify if we need
more/different"): adaptive poll · tokens live with $ on hover/rollup ·
per-work-item path-touch subgraph for S4 replay · first-class Fleet pane ·
wake the dormant tool_calls table (+seq/paths/write) · seats = active
dispatches grouped by agent/model. The arc is fully unblocked for the build
session.
