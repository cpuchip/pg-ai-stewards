# pg-ai-stewards: Codebase-Grounded Review vs. the Agentic Findings (2026-06-27)

*An Opus review against the actual authored chain (`00-config.sql` → `70-hinge-decouple.sql`),
`src/{bgworker,tools,lib,schema}.rs`, and the docs. Verdicts cite `file:function`. Trust is in
the code — not the digest's outside-in framing, nor the (partly stale) docs. Companion to
`study/yt/google-cloud-agentic-playlist-digest.md`.*

**Headline:** strong where the findings say the hard part is (the loop, state, governance, the
eval-gaming guard, a real trajectory critic); genuinely weak in ~5 places the digest under-counts.
The source documents are themselves partly stale: `external_context/google-new-sdlc/NOTES.md`
claims "a grep found no trajectory/tool-trace evaluator" — **false** (`56-trajectory-critic.sql`
exists; that inbox action item was completed). The playlist digest's "failure-clustering
primitives are in 18" conflates the *cron scheduler* with actual *clustering* (not built), and
frames our allow-by-default grant model as "deny-by-default."

## Ground-truth highlights (full table below)

**HAVE (strong):** bounded-iteration cap as config (`67:chat_post_internal` + `agents.steps`);
rubric-seeded judge as agent rows fired post-completion (`56`/`64`); **evaluator/optimizer
decoupling = the eval-gaming guard, enforced in SQL 3 ways** (`59:prompt_improvement_gate` —
judge-target escalate-only + family blocklist + apply-time recheck; `64:should_auto_critique`
"don't grade the graders"); parameterized tools (`tool_defs`); collaborative-planning state
(maturity ladder + `awaiting_review`).

**GAP / PARTIAL (the real work):**
- **Identity-at-transport: PARTIAL** — `_session_id` injected from the dispatch payload
  (`tools.rs:exec_sql_fn_tool`), but **no end-user identity exists anywhere**. ★ Regression: A2A
  participant identity (`a2a_claim(claimer=…)`) is **self-asserted in the payload** — the opposite
  of the principle.
- **Progressive-disclosure TOOL catalog: GAP** — `26:compose_tools` ships every granted tool's
  full `args_schema` every turn; `37:compose_tools_scoped` narrows *count* per pipeline stage only.
  Skills solved this (`24:render_skills_block`); tools didn't. **The 159-tool gather grant is only
  partially mitigated.**
- **Hybrid RRF retrieval: PARTIAL** — generic surface is split (`04:doc_search` FTS-only;
  `15a:search_engrams_by_vector` vector-only). Fusion exists only for Loreworks
  (`57:world_entity_hybrid`) and is **weighted-linear `0.45·lex+0.55·sem`, not RRF** despite
  `lib.rs:756` calling it "RRF."
- **Memory consolidation: GAP** — engrams append-only (`15a:apply_map_reduce_parent_engrams` is
  pure concat); `41-memory-tend` only grows edges.
- **Per-tool observability: GAP** — `schema.rs` has a `tool_calls` table that is **never
  INSERTed** (empty shell); **no `latency_ms` captured anywhere**. Cheapest fix; bottleneck for
  the whole eval flywheel.
- **Failure-clustering: GAP** — `59:agent_failure_patterns` is deterministic `group by
  agent_family+verdict`; verdicts carry no embedding.
- **Tiered cascade dispatch: GAP** — `19:work_item_dispatch_stage` does capability *substitution*,
  not cheap-classifier-first cost routing.
- **Risk-tiered Hinge: PARTIAL** — `39:hinge_record_verdict` gates by `kind` string, not a graded
  1–5 risk tier.

## The REAL gaps, ranked (highest-leverage first)

1. **Multi-tenancy / RLS / parameterized secure views — entirely absent** (grep-confirmed). Michael's
   stated goal + the companion talk's sharpest steal + a clean named primitive. See §Multi-tenancy.
2. **Progressive disclosure of TOOL schemas** — the *logged* 159-tool pathology that wedged the
   local model. Biggest token-cost win; precondition for scaling grants.
3. **Generic hybrid RRF retrieval for docs/engrams** — build one fused `doc_search_hybrid` (RRF over
   `ts_rank` + `embed_query` cosine) + auto-chain a graph-expand hop.
4. **Memory consolidation/dedup** — engrams append-only fights the upstream context engine.
5. **Per-tool observability (latency + per-invocation trace)** — `tool_calls` exists but is never
   written. Cheapest item; substrate of #21/#22/#24.
6. **Failure-clustering** (embed traces → cluster → triage the bucket) — the `18` cron archetype is
   ready to host it; add an embedding column to `trajectory_verdicts`.
7. **Tiered cascade dispatch** (cheap-model-first) — deterministic SQL pre-filter before full dispatch.
8. **Risk-tiered Hinge + named risk-assessor stage** — a graded score vs the current `kind` string.

## Where pg-ai-stewards is genuinely AHEAD (grounded)

1. The autonomy loop is in the DB — `19:work_item_dispatch_stage` (4-layer resolution + capability
   substitution + spend-cap gate) + `bgworker.rs` `FOR UPDATE SKIP LOCKED`. Google names AlloyDB
   "the grounding layer beneath the LLM" — the passive role this inverts.
2. State outlives the process by construction (every turn is rows; recomposed each round).
3. The eval-gaming guard is **mechanized in SQL**, not aspirational (`59`, 3-layer). Google *stated*
   the principle; the substrate *enforces* it.
4. Governance is queryable rows, not a network appliance (the Hinge `39`, the maturity gate `08`,
   spend caps that **refuse before they spend** `19:provider_cap_exceeded`).
5. The papers' flagged gap is already filled (`56` + `59`); `NOTES.md` is stale saying otherwise.
6. A2A is in the DB as transactions (`69`; `claim` = `work_item_escalation_claim` generalized).
7. Delegation is bounded structurally (depth/width/grant + spend caps + `reflect_guard` + `67`
   force-final).
8. A within-operator confidentiality primitive exists (`27:sessions.private` — the wall beats the
   watch; `29` private routing) — not RLS, but the instinct is present.

## Multi-tenancy assessment

**(a) Tenant isolation today: NONE.** Grep returns zero `row level security` / `CREATE POLICY` /
`tenant` / `org_id` / `owner_id` / `current_setting('app.*')` / `SET ROLE`. `sessions.private` (`27`)
is a **search-visibility** wall enforced in app-SQL (a raw `SELECT * FROM messages` bypasses it);
`intents.file_private` (`29`) is **filesystem path routing**. Neither is access control.

**(b) The natural boundary is `intent_id` — but it touches almost nothing.** Only **3 of ~60
tables** carry it (`work_items`, `councils`, `scheduled_pipelines`). Everything else is global or
joins through `work_items` (`intents` itself has no owner column; `sessions`, `messages`,
`nodes`/`edges`, `worlds`/`world_*`, `agents`/`tool_defs`/`agent_tool_perms`, `cost_events`,
`docs`/`engram_embeddings` are flat). **The data model is single-tenant-flat.**

**(c) Would RLS fit? Structurally yes; four blockers.** The schema was built *with RLS in mind* —
`01-graph.sql:6-7` justifies dropping AGE precisely because plain tables give "the full Postgres
toolbox (indexes, **RLS**, partitioning)." Blockers: **(1)** the bgworker connects as the bootstrap
**superuser** (`bgworker.rs:connect_worker_to_spi(…, None)`) — superusers *bypass* RLS even under
FORCE; needs a dedicated non-superuser run-as role. **(2)** ~10 row-bearing tables need a key +
backfill; `intents` needs an owner. **(3)** Some globals are global *by design* (`tool_defs`,
`agents`, `model_capability`) — RLS must be selective. **(4)** No identity rides the dispatch session.

**(d) Did relational-edges-over-AGE enable it? Latently yes, not realized.** You cannot
`CREATE POLICY` on AGE's opaque `ag_catalog` graph storage; you *can* on a plain `stewards.edges`
table. The choice **removed the blocker AGE imposed** — but `edges` carries no `intent_id` and has
no policy. "The door is RLS-able," not "we walked through it."

**(e) Concrete path** (the Google "identity-at-transport + parameterized secure views" steal is
exactly the missing piece):
1. **Add the tenant key** — `intent_id` (or a coarser `account_id` *above* intent, since one
   operator owns many intents) on the row-bearing tables, backfilled from the owning `work_item`;
   give `intents` an `account_id`.
2. **Identity-at-transport** — a dedicated non-superuser app role; bgworker + bridge connect as it;
   at dispatch `SET LOCAL app.current_intent = <work_item.intent_id>`. Identity rides the session,
   not the query — directly fixing the `_session_id`-only / A2A-payload-identity gap.
3. **RLS on tenant tables** — `ENABLE` + `FORCE ROW LEVEL SECURITY`,
   `USING (intent_id = current_setting('app.current_intent', true)::uuid)`; catalog tables stay open
   or behind a "shared OR owned" policy.
4. **Parameterized secure views** (`security_barrier`/`security_invoker`) for shared-but-scoped reads
   (`doc_search`, `context_search`, the graph walks); fold the `sessions.private` wall into a real
   policy.
5. **RLS-aware SPI path** — audit dispatcher/gate/cost rollups; legitimate cross-tenant work
   (watchman, steward, global cost) gets an explicit audited `SECURITY DEFINER` carve-out.
6. **Verify with the oracle** — a virgin-smoke assertion that tenant A can't read B's
   `sessions`/`messages`/`edges`/`docs`; drop the policy, confirm the leak returns (inverse hypothesis).

*Scope honesty: ~10 columns + backfill + a new dispatch-role model + an RLS-aware SPI path — a real
build, not a config flip. The relational-edges groundwork means only step 3 is "ready."*

## Docs updated (docs-only; no judge/gate/dispatch logic touched)
- `README.md` — added the omitted Documentation rows (`loreworks.md`, `operations.md`, `delegation-limits.md`).
- `docs/anatomy-of-a-turn.md` — fixed "~220 SQL migrations" → "consolidated authored chain
  (`00-config` → `70-hinge-decouple`)"; noted the auto-fire-marker set has grown; added a new
  **"Beyond the turn"** section pointing to the 9 post-cut subsystems (gates `08`, council/sabbath
  `12`/`10`, Hinge `39`/`70`, A2A `69`, rigor `65`–`67`, trajectory critic + self-improvement
  `56`/`59`, model capability/probe/alias/failover `19`/`31`/`32`/`68`, Loreworks `54`–`58`,
  memory-tend/page-in `41`/`33`).
- `docs/delegation-limits.md` — added a note distinguishing parent→child spawn from the A2A
  peer-handoff surface (`69`).
- Verified current (no change): `wiring-up-models.md` (alias/failover/auto-probe all documented),
  `operations.md`, `loreworks.md`, `rich-*`, `personas-and-chattermax.md`.

## Source-doc corrections to fold back
- `external_context/google-new-sdlc/NOTES.md` is stale where it says the trajectory evaluator
  "doesn't exist yet" (it's `56`).
- The playlist digest over-claims "failure-clustering primitives are in 18" (18 is the *scheduler*;
  clustering is unbuilt) and mislabels the allow-by-default grant model as "deny-by-default."
