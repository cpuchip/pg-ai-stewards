# pg-ai-stewards — full audit synthesis (2026-07-03)

Status: **synthesis / recommendations** — Michael's to ratify item by item. Nothing below is built except the two fixes marked ✅ (landed this session).

Michael commissioned a five-lens audit after walking the two hinge PRs to main: (1) Rust/pgrx + SQL quality, (2) architecture drift vs our own framework, (3) usability/functionality vs Omnigent and Google's new-SDLC bar, (4) the "soulless docs" problem, (5) installation and extension ergonomics. Two web-research strands fed it: the Postgres extension-packaging state of the art, and the declarative-config / first-run-wizard state of the art. This document stacks all seven into one ordered plan.

## The one-line verdict

The substrate depth is the moat, and it is real — not flattery. The two genuine gaps are the meta-harness wrapper we don't have and the first-run on-ramp a stranger can't cross. The two craft debts are the overlay packaging (a hand-rolled reimplementation of something Postgres gives natively) and the styleless generated docs. Everything ranks off that sentence.

---

## I. Where we are genuinely ahead (keep these, and start marketing them)

Verified against source this session, stood against Omnigent, Google's whitepaper, LangGraph/LangSmith, Temporal/DBOS, and OpenHands.

1. **Glass-box trajectory eval.** Google's whitepaper puts trajectory eval at the center of "agent quality" and says most platforms score only final outputs. We score the execution *trace* against a rubric, and `79-bineval` solved the failure mode where a weak model skips the decomposition by making the rubric questions the *required args of a tool*. Omnigent has zero eval in core. This is a true lead.
2. **Self-improvement with an eval-gaming guard.** `59-self-improvement` proposes additive prompt clauses from trajectory critiques; the gate is deterministic and judges/critics are escalate-only. No competitor ships a self-improving loop at all. "An optimizer can never edit what grades it" is an original safety property.
3. **Governance as accountable rows.** The Hinge enforces D&C-121 bounds *in SQL* — `hinge_record_verdict` cannot exceed its granted kinds; cutover / new-capability / spend-increase are permanently human. On Google's exact phrase "guardrails as external tamper-proof governance, not prompt," we are the strongest instance in any repo read.
4. **SQL-native audit + PITR.** Every act of cognition — composition, context-shedding, gate verdicts, council votes, cost — is a queryable row, and one backup recovers the whole brain to a moment in time. The deepest audit surface in the set.
5. **Durable execution without bolting on Temporal.** The turn is a row; every round recomposes from the DB; reapers heal orphans. We reached Temporal/DBOS-class durability natively while the industry spent 2026 rediscovering it needs a product for exactly this. We do not market it.
6. **Vector + relational + graph + code-graph in one `SELECT`.** `83-code-graph` (the lodestar port) sits beside the knowledge graph and world graph. Google flags graph-native code understanding as a Tier-3 maturity feature; we shipped it.

## II. Where we have drifted or gone astray (Rust/SQL + architecture)

Two of these are already fixed this session.

- **✅ A1 — `target_table` SQL-injection seam (FIXED, `ea051a2`).** A PUBLIC-enqueueable embed payload interpolated `target_table` into identifier position at worker privilege. Closed with a static allowlist of the five tables that carry an `embedded_at` column, validated at parse time before any HTTP. Verified on the real path: injection non-executing across three live enqueues (`config` and `pg_authid` intact). *Follow-up (M):* extract the allowlist to a testable helper + a plain `#[test]` — the grindable unit oracle that makes this regression-proof rather than live-worker-flaky.
- **✅ proposal status-line drift (FIXED, `06b2c32`).** The hinge-ladder proposal still read "Do NOT build" after 84 shipped. Reconciled to "RATIFIED (Phase 1)."
- **M1 — pin the final form of multiply-authored functions in `virgin-smoke`.** Functions re-authored across up to five files (`CREATE OR REPLACE`) rely on later-file-wins topo order that no runtime tool enforces (see IV). The smoke test should assert the *final* body, not just existence.
- **Version drift, four ways + a dead `pg_test` at 0.1.0.** `default_version` = 0.3.0, `OSS_VERSION` = `unreleased`, plus stragglers. Reconcile to one real semver and delete the dead test.
- **House rule: `SECURITY DEFINER` → pin `search_path`.** Adopt as a lint, not a one-off — a definer function without a pinned path is a latent privilege seam of the same family as A1.
- **Cache the `reqwest` client.** We build a new client per call; reuse it (connection pooling, lower latency).
- **Confirm the compose-override docker-socket-mount default.** The rich-chat runbook's own ⚠ warns that recreating the bridge with fewer `-f` flags silently drops the mounted socket and doc-build then fails with "Cannot connect to the Docker daemon." A default that fails safe beats a documented footgun.

Architecture adherence is otherwise good: everything-is-a-row holds, deny-by-default grants hold, the virgin-gate discipline holds. We have not drifted from the framework — we have accreted two packaging debts (§IV) the framework never specified.

## III. Phase-2 miss list (usability/functionality vs the 2026 bar)

`what we have → phase-2/3 target → effort / value`. Full matrix in the Omnigent report; the load-bearing rows:

| Gap | Today (phase 1) | Phase-2/3 | Effort · Value |
|---|---|---|---|
| **A · Golden-set eval on a schedule** ("the Lab") | BINEVAL, spiral oracle, scheduler, per-task criteria | `experiments` table + golden cases + scheduled regression + Stewdio panel + drift alarms | M · **very high** |
| **B · Harness executor kind** | `execute_target` = sql_fn / http / mcp_proxy + own coder sandbox | add `harness` so a stage dispatches to claude-code / codex / cursor-in-a-sandbox as a runtime | M-H · **very high** |
| **C · Composable stateful policy layer** | tool-effect gate (3 classes) + spend caps + grants + Hinge | ALLOW/ASK/DENY, multi-kind handlers, per-user cost, risk-score, PII, routing-as-policy, live-manageable | M · high |
| **D · OTel export** ✅ | everything-is-a-row + Stewdio | ~~emit OTLP spans per turn/tool-call from rows that already exist~~ BUILT: `cmd/stewards-mcp/otel_export.go` + `docs/otel.md` (2026-07-03 build day) | S · high |
| **E · Multi-tenancy / RBAC** | single-tenant; owner-grants spec proposed | owner + per-resource grants + RLS-transparent-for-solo + per-tenant budgets | H · high |
| **F · HITL approval UX** | Hinge, tool-effect gate, Stewdio cards, ladder Phase 1 | ladder Phases 2-3: `ask_up` consult + ask-cards + notify, degrade card→tray→push | M · high |
| G · workflow versioning · H · double-texting · I · sandbox-provider pluggability · J · versioned-prompt rollout · K · tested DR drill | (various) | (various) | below the line this month |

Not a miss: cron scheduling already exists (`18-scheduler`), and a semver'd API policy is thin across the *whole* field, so it is not a pg-ai-stewards-specific hole.

## IV. Installation & extension — "we do overlays, is that the best?"

Answer: the overlay *content* is right and the overlay *packaging* is a hand-rolled reimplementation of native Postgres extension versioning. Both research strands and the field audit converge on it independently.

**The stranger's first run is the headline finding.** There are two first runs and the README conflates them. Path A (`docker compose up`) works and is clean — *but the stack that comes up cannot think.* With no provider wired there is no model, and nothing in the boot output says "you have a brain with no thoughts." Path B (an agent actually answers) is a 30-60-minute gauntlet dominated by a cold Rust build and *hand-writing two SQL seeds* (`model_capability`/`model_pricing`, then `model_aliases`). For a stranger who does not write SQL it is effectively blocked. That is exactly what `positioning-and-focusing-release.md` already named: "the builder has been building for the builder."

**The one real correctness landmine.** The correct overlay apply-order lives in `migration-manifest.txt`, which is consumed *only by the CI parity harness*. The actual runners order differently — `migrate.sh` uses `ls | sort -V`, `stewards-cli migrate` uses `sort.Strings` and points at the *old monorepo path*. `cut3-restore-core-finals.sql` documents "runs LAST so core finals win," yet `sort -V` places `cut3-` near the front, ahead of the `pe5`/`r6` clobbers it exists to repair. The order that makes the overlays correct is enforced by no deploy tool. The whole `r6`/`pe5`/`cut3` saga *is* this failure mode.

**Recommendation — a two-track shape, stop conflating the two problems:**

- **Track 1 · first-run + keys/models: an in-app setup wizard (#256).** The app-platform tier has converged on wizard + encrypted in-app credential store — n8n, OpenHands, Dify, and (in OSS) Airflow's Fernet-encrypted UI connections. Build add-key → probe → pick models → assign roles, writing dials to `stewards.config` and secrets to a new **encrypted `stewards.credentials`** table keyed by one master env var. Ship an opinionated default provider (opencode-zen free) so an empty install reaches a working turn with **zero SQL**. Steal two details verbatim: *test-on-save* (validate the key when saved) and *never echo the key back* (expose only an `…_is_set` boolean).
- **Track 2 · deep customization: versioned packs with a compatibility contract.** Keep the SQL-as-content; repackage it. End state: a pack *is* a Postgres extension that `requires` the core, so install / upgrade (`ALTER EXTENSION … UPDATE`) / uninstall (`DROP EXTENSION`) / compat become native operations that compose with the virgin-gate. First step (backend-only, days): give `OSS_VERSION` teeth, add a `-- requires-core: >=X <Y` header + a `stewards.assert_core_compat()` guard (native `requires` carries no version range — this guard is needed under *every* packaging path), and collapse to one runner that obeys `migration-manifest.txt` when present. That single change closes the `cut3` landmine without editing a single overlay.

**Near-free the same week:** set `OSS_VERSION` to a real value; fix the stale chain numbers in `rich-chat-and-artifacts.md` and the `virgin-smoke.sql` header (both say the wrong range — it is 00→86 today); drop a README + one worked example overlay into the empty `overlays/` dir so a stranger has something to copy.

## V. Soulless docs → theming (Tufte / UX / style)

The generated docs have the data and lack the craft. The fix is the Karpathy-regenerable split we already believe in: **content** is immutable markdown + frontmatter, **presentation** is a render-time-derived view, and the theme is applied at render, not baked into the content. The `tufte-claude-skill` is already installed. Theme both surfaces — the docs pg-ai-stewards *ships* and the docs/programs it *generates* — so the style is a property of the renderer every artifact inherits, not a thing an author remembers. Scope: P1, ~2-4 days.

## VI. Book-2 carryover — what building this taught us

Worth inheriting in the next substrate/book:

- **Oracle-first, then judgment.** The virgin-gate, the clobber-check, `verify-quotes` — the deterministic detector written *before* the horizontal walk is what makes autonomy safe. Build the oracle first.
- **The manifest must be the runtime contract, not just the CI harness.** The `cut3` landmine is the lesson: a proof that runs in a different order than the deploy is not a proof.
- **Everything-is-a-row is the moat, not the schema tax.** Durability, audit, PITR, and glass-box eval all fell out of it for free. The field paid Temporal/LangSmith prices for less.
- **Deny-by-default grants + accountable-in-SQL bounds** beat prompt-level guardrails on both safety and legibility.

## VII. Ranked master recommendations (the stack-it-up)

Ordered by "moves 'best metaharness' most," with the autonomy tag for each.

1. **Build the Lab (miss A).** *First, because it grades everything after it.* Drafted, grindable, oracled — the sweet spot. Converts BINEVAL + spiral oracle + scheduler into the continuous-eval flywheel Google names as the line between a demo and a production system. → *surface-first spec exists (`lab-and-wiki`); build is oracled execution once ratified.*
2. **Harness executor kind (miss B, steal #1 from Omnigent).** The literal path to "metaharness" — a `harness` `execute_target` running claude-code/codex via **loom** inside the existing sandbox. Once it exists the Lab can A/B *harnesses* the way it A/Bs models. → *new standing capability with write-back = `dominion_in_council`; prove one dispatch first.*
3. **Escalation-ladder Phases 2-3 (miss F).** `ask_up` model-tier consult (bins-1-2 safe) + Stewdio ask-cards + notify, degrade card→tray→push. Closes the widest UX gap vs Omnigent. → *ratified in principle; `ask_up` is act-safe, Phase 4 autopilot stays council.*
4. **OTel export (miss D, steal #7). ✅ BUILT (2026-07-03 build day, wave 2).** Smallest effort, real adoption value — emit OTLP spans from rows that already exist. Landed as a poll-based bridge exporter (`cmd/stewards-mcp/otel_export.go` + `otel_otlp.go`, hand-rolled OTLP/HTTP JSON — the official Go SDK only speaks protobuf over HTTP, so this avoids that whole dependency tree), an `otel-smoke` proof subcommand, and an opt-in `docker-compose.otel.yaml` collector overlay. Verified against a real `otel/opentelemetry-collector` on live data: a multi-stage trace with tool-call spans, a failed work_item's Error status propagating root→stage, and the zero-session edge case. See `docs/otel.md`. → *act-safe, oracled.*
5. **Composable policy layer (miss C, steals #2-4, #9).** Generalize the tool-effect gate into ALLOW/ASK/DENY with per-user cost, risk-score, PII, and the cost-*downgrade*-gate refinement (block only the expensive models, don't quarantine the work item). → *surface-first; it is the substrate for step 6.*
6. **Multi-tenancy Phase 1 (miss E).** Owner + per-resource grants + RLS-transparent-for-solo + per-tenant budgets, built on step 5. → *`dominion_in_council`; sequence last.*

**One sequencing tension worth your call (2 vs 5).** The order above leads with the harness executor because it is the literal "meta." A second pass argued the reverse — land the composable policy layer *first* so the wrapped harnesses are *born governed* (every new claude-code/codex executor runs through ALLOW/ASK/DENY from its first dispatch, rather than being retrofitted). Both are defensible: harness-first proves the meta-unlock soonest; policy-first means no ungoverned executor ever exists. My lean is policy-first if you intend the harness executor to be a *default route* (born-governed matters most when it's load-bearing), harness-first if the first dispatch is a bounded one-off proof. Either way the two are adjacent — this is a swap of steps 2 and 5, not a reshuffle of the spine.

Interleaved, off the ranked spine but cheap and worth doing:

- **Track 1 setup wizard (§IV)** — the single largest first-run win; already ratified in `positioning-and-focusing-release` as "the heart of easy to adopt." Rides parallel to 1-3.
- **Track 2 compat contract (§IV)** — backend-only, days, closes the `cut3` correctness class.
- **Doc theming (§V)** — P1, ~2-4 days.
- **The Rust/SQL fixes (§II)** — M1 pin, version reconcile, `search_path` lint, reqwest cache, compose-socket default. Act-safe execution; do them as a batch.
- **A1 grindable unit oracle (§II)** — the follow-up that regression-proofs the fix already landed.

## VIII. The reserved question — was keeping the AI inside the DB the right choice?

Michael reserved this one for my hand, not a subagent. Now that loom and llama-chip exist and do things the in-DB substrate does not, does that second-guess the dream?

No — and the audit is what makes me confident rather than loyal, because it forces apart two things "keep the AI in the DB" always quietly bundled.

The first is **cognition state** in the DB: the turn as a row, the engrams, the graduated context-shedding, the gate verdicts, the council votes, the cost ledger, PITR. Every single item on the "genuinely ahead" list in §I is this layer, and nothing else. Omnigent persists to SQL too but wraps *other people's* runtimes, so it cannot reach in and make the whole cognition inspectable. loom cannot give you this — loom is stateless dispatch, hands with no memory. llama-chip is the model tier, a faster engine, not a brain. The field spent all of 2026 rediscovering that production agents need durable execution and glass-box eval, and paid Temporal and LangSmith for worse versions of what being-in-the-DB handed you for free. Keeping cognition state in Postgres was not merely right — it is the specific thing that makes pg-ai-stewards not a commodity.

The second is **cognition execution** in the DB: the bgworker dispatching raw chat-completions itself, running its own coder sandbox. This is the part loom and llama-chip actually press on, and here the honest answer is that the purist version — where the DB is also the executor for everything — was the part to loosen, and the audit already names the loosening. The "harness executor kind" (recommendation #2) makes loom a first-class `execute_target`. The substrate keeps owning the state, the governance, the audit, the eval; it *dispatches* the execution to claude-code or codex through loom, or to a local llama-chip model, whenever that runtime is better for the stage. loom becomes the substrate's hands, not its replacement — which is exactly what the general-workspace lane has been saying: loom is the top tier *over* the substrate's local coder loop, not a competitor to it.

So the dream was right about the load-bearing half and slightly too literal about the other. The DB was never really "where the AI runs." It is where the AI remembers, decides, and is held accountable — and those three are the whole moat. loom and llama-chip don't threaten that; they plug in underneath it as the executor tier, and the harness-executor-kind is the seam that lets them. Keeping the AI in the DB is more defensible today than the day you chose it, because the rest of the field walked a year in the other direction and arrived at the parts you already had.
