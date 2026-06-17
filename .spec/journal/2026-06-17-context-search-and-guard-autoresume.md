# 2026-06-17 — context_search, the guard's release half, and two tunings

A fast idea→built day on the OSS substrate (the one live stack). Four things shipped,
all live + pushed + pg18 rebaked, each virgin-smoke + clobber green.

## 1. Model rotation (OSS `73f7c81`, ws `51534d9`; price fix `62f9a27`/`82ce3aa`)
Michael: "rotate those models up… max is the priciest on opencode." Rotated the cheap
workhorse `qwen3.6-plus`→`qwen3.7-plus` across every dispatch path (25 pipeline stages,
15 stage_models, 6 brainstorm metadata, 3 gate-fn hardcodes, 5 escalation rules) + moved
`prompt-critic` off `qwen3.7-max`. **Caught:** qwen3.7-plus had no `model_pricing` row →
the spend guard would've gone blind to the workhorse; priced it. Michael then flagged
it's "much cheaper, like half" — pulled the real opencode rate ($0.40/$1.60 vs
qwen3.6-plus's $0.50/$3.00) and corrected it. So the rotation also cut cost.

## 2. Book-curate cadence 6h→2h (OSS `62f9a27`)
Michael's math: book-digest eats ~1 book/hour, a 6h curator adding 3 supplies ~0.5/hour →
the shelf drains. 2h supplies ~1.5/hour and a STOCKED run is a cheap no-add call.

## 3. context_search P0 — grep over an agent's own durable context (OSS `de52a24`)
Michael's idea: a model's window is lossy, but our `messages` are durable rows — hand the
agent the Ctrl-F it structurally can't do over its own history. `27-context-search.sql`:
`context_search(pattern, scope, include_folded, limit)` over `session` (own) + `descendants`
(the watch, via `work_items.parent_work_item_id` + `session_ids`); curated (verbatim+pinned)
by default, `include_folded` recovers muted/compressed to re-open; snippet + `[ctx:handle]`
results that round-trip `expand_message`. Plus `context_session_private(on)` — a manual wall
(sessions.private) that **beats the watch** (a private child is invisible even to its
parent; absolute, D&C 121) — the security primitive for sensitive/local-model work.

Council refinements all landed: curated-default + include_folded recovery; the scope ladder
as the walls; private-by-default upward (P1); the private wall; "this is what you SAID, not
that it's true" (provenance ≠ truth — still verify external claims at the source). `context_*`
name → compose_tools already surfaces it (no gating change); sql_fn → no refresh-tools.
**`self`** (all my historical sessions) folded to P1 — `sessions` carry no agent identity,
so it needs a session→agent map. Tool descriptions written to TEACH (Michael's adoption
point: models weren't trained on these tools; if adoption is low, teach them — captured a
P1 per-tool-group usage primer + usage telemetry in the proposal).

## 4. The guard's narrow auto-resume (OSS `c1dc09f`)
The watchman guard (23) proved itself tonight — it auto-paused autonomy when 24h spend hit
the $10 cap, exactly as designed. Michael bumped the cap to $12 + resumed, then had the
better idea: **the guard should release its own brake** once the breach self-clears, so a
human doesn't have to babysit the resume. Ratified "narrow resume."

`28-guard-autoresume.sql`: `reflect_guard_autoresume_tick()` on the same heartbeat. It lifts
a pause ONLY when all hold — the pause was guard-set (`reflect_pause_source='guard:<breach>'`,
the new marker; a human `reflect_pause` records 'manual' and stays manual), the breach was
**self-clearing** (spend / in_flight — a failure-streak or proposal-backlog pause stays for a
human, since those don't heal with time), no breach is currently active, and the metric is
back under 75% of its cap (a deadband so it can't flap). Every auto-resume logs to
`reflect_guard_log` (`action=auto_resumed`) — the watch accounts for *releasing* the brake,
not just applying it. This completes the loop the guard only half-had.

The covenant nuance, named and kept: the guard was built "never auto-resumes; a human lifts
it" (D&C 121 — account for emergency force). Auto-resume relaxes that *only* for the cases
that provably recover on their own; the "human lifts the emergency stop" principle holds
exactly where judgment is needed (human pause, failures, backlog).

## Carry-forward
- **context_search P1:** `self` scope (+ a session→agent identity map); `ancestors`
  (private-by-default) + per-message private; the `sensitive` intent/agent flag (one switch
  → local dispatch + private). **P2:** unify context_search + pool_search + engrams into one
  recall surface + the global tier.
- **The per-tool-group usage primer** (cross-cutting: skills/productivity/context) — its own
  small proposal; pairs with #136 (does agent-driven context mgmt earn its keep) — now we can
  query real `context_search` usage to decide if the primer is needed.
- **Spend cap** is at $12 (Michael's bump); with auto-resume live the cap is less load-bearing
  (the window self-heals either way) — revert to $10 anytime, his call.
- Reflect-steward kept hitting the cap today (heavy autonomous load); auto-resume should make
  these guard pauses transient from here.
