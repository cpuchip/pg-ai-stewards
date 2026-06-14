# 2026-06-14 — M5: compact_context, councilled and built same session

**Session:** pg-ai-stewards lane, the M5 brake of the parity roadmap. Michael
chose "convene the M5 council now," then — when I misread the DB's UTC stamps
as "past midnight" and counseled waiting — corrected me: "it's only 8:41pm CDT,
I still got time!" So we built it.

## The council (dominion_in_council satisfied)

`compact_context` is net-new, so a council was required before building. Four
parked questions, all ratified with my recommendations:
1. **Mid-turn** (the tool call blocks; the caller's next turn recomposes lighter).
2. **A fixed cheap model, TUNABLE** — Michael: "fast with large 1M context …
   run experiments to find a good compactor counselor." → the model is the
   curate stage's knob (default deepseek-v4-flash).
3. **Sees the foldable surface** (id + handle + size + gist).
4. **Agent-initiated + a ≥threshold pressure-line nudge** (persuasion, not
   compulsion; auto-firing stays pressure-shedding's floor).

Grounding before building earned its keep twice: I caught that
`render_judge_brief_surface` is *per-message*, not a whole-session view (so the
session surface is the `context_pressure` foldable list), and confirmed
`context_expand` is the reversible unmute (the "safe by construction" claim holds).

## The design sharpened in the building — judges-not-executors

The intended design had the compactor *call* context tools to mute the parent's
messages. But `_session_id` is injected as the *caller's* session, so a compactor
running in its own session would resolve handles against itself, not the parent.
The fix made the design **better**: the compactor is a **tools-off judge** that
returns a JSON verdict `{mute,compress,pin}` by message-id; the *substrate*
(`compact_context_apply`) applies it to the parent session. Cheaper (no tool
round-trips), safer, and the correct pattern — the compactor counsels, the
substrate acts. The presiding covenant, recursive.

## What shipped (OSS `a8d5cc5`)

- `extension/21-compact-context.sql` — `compact_context_surface` (what the
  compactor sees), `compact_context_apply` (mute/compress/pin by msgid, only
  ids that belong to the session; honest curated-footprint metric; [COMPACTED]
  accounting marker), the pressure-line nudge, the tools-off `compactor` agent
  (JSON verdict), the single-stage `compact-context` pipeline, deny-all-heavy
  grants, the `compact_context` tool_def.
- `cmd/stewards-mcp/compact_context.go` — the mcp_proxy handler: reads the
  injected `_session_id`, renders the surface, **inherits the caller's
  work_item intent** (the core ships no default intent — the compactor is a
  child of the caller's work), spawns + polls the compactor like spawn_subagent,
  applies the verdict. `extractJSONObject` tolerates a model that wraps it.
- Wired into `lib.rs` (create_compact_context requires create_coder),
  `Dockerfile` COPY, `main.go` registration.

## The proof (e2e on the OSS stack)

A 14-message session — a MySQL→Postgres migration plan clogged with spent grep
dumps + a schema dump + a precious cutover decision. The agent calls
`compact_context`; the deepseek-v4-flash compactor returns:
> `compress [1106, 1107]` — "1105 is the assistant's own survey/plan, keep
> as-is; 1106 (grep dump) and 1107 (schema dump) are bulky tool outputs whose
> substance is captured in their gists, compress to traces."

The substrate applies it: `compressed=2`, a reversible `[COMPACTED]` marker.
25 seconds, $0 (free-tier). Real judgment — it protected the plan and the
decision, compressed only the spent dumps.

## Four bugs, all my plumbing (the design held)

1. **agent ON CONFLICT** was `(family)`; the PK is `(family, model_match)`.
2. **spawn needs an intent** — core ships none; inherit the caller's work_item.
3. **stale live model** — I'd changed the pipeline model in the file but not
   re-applied it, so the first run used "openai" → 401.
4. **poll terminal state** — a 1-stage tools-off pipeline ends at
   `status=completed` without reaching `maturity=verified`, so my handler polled
   past completion into the bridge's 120s call-timeout. Fixed to treat
   `completed` as terminal and cap the wait at 110s (under the bridge timeout,
   so a slow compactor fails gracefully here, not as an opaque bridge kill).

## Honest about the relief

Token relief is **governed by the existing pressure-rendering tiers** — muted/
compressed messages fold to tombstones only when the window is *under pressure*.
Below a tier, nothing folds yet. So the metric reports the **curated footprint**
(foldable tokens marked for relief), not a fictional immediate delta. The
mechanism (mute/compress under pressure) is production-proven; compact_context
correctly feeds it with judgment instead of leaving it purely automatic.

## Follow-ups
- A `tests/virgin-smoke.sql` assertion (compact_context exists, compactor ships
  tools-off, nudge fires past threshold). The pgrx extension image builds with
  21 (`stewards-oss-pg:pg18` built clean), and CI gates the full chain.
- Tune the compactor model (Michael's experiments) via the curate stage.
- The mid-turn relief is via the synchronous-block path (like spawn_subagent),
  not the async `waiting_for_tools` fan-out — simpler and sufficient.
