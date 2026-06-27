# Multi-tenancy & Single-User — pg-ai-stewards

**Status:** proposed (2026-06-27), for council. A foundation spec — the technical pattern choice
is being refined by a parallel industry-standard-Postgres-multi-tenancy research pass; this spec
is written from the codebase-grounded review (`.spec/notes/2026-06-27-agentic-findings-vs-substrate-review.md`).
**Authors:** Michael (vision) + Claude (design).
**One line:** make pg-ai-stewards *multi-tenant-capable* — owned-by-default, shareable-by-grant —
**without ever making the single-user operator pay for it.**

---

## 0. The non-negotiable, stated first

**Single-user is and stays fully first-class.** The substrate today is one operator's (Michael's),
and the solo case must remain: zero setup, zero ceremony, no auth dance, no policy to write. The
design rule for every phase below:

> **One tenant is the default. The *second* tenant is the feature.**

Concretely: a fresh install has exactly **one account** (auto-created, the operator). Every row is
owned by it. RLS, when added, resolves to "everything belongs to me" and is effectively transparent
— the solo operator never sees it. If any phase below would add friction to the single-user
experience, that phase is wrong and gets redesigned. Multi-tenancy is **additive and opt-in**, the
same way the OSS-core / operator-overlay split already works.

---

## 1. The vision (Michael's), and its hard boundary

pg-ai-stewards provides a lot of **autonomy**. The next horizon: let that autonomy be **shared** —
resources a tenant owns can be made available to **authorized users**, not just walled off. The
motivating use case Michael named: **code understanding as a World** (the Loreworks engine applied
to repos) — a repo imported as a World (with sub-worlds for modules/packages), where **not everyone
has access to every repo.** Sharing is selective and owner-granted.

**The hard boundary — what this spec is NOT.** Full **enterprise federated-org permissions** — SSO /
external IdP, per-team-per-repo ACL federation, nested org RBAC, SCIM, group inheritance — is
**explicitly out of scope and deferred.** Michael: *"in an org that has federated permissions…
that's ugly really ugly. I am not prepared to handle that yet. I'm just one dude with an AI."* The
near-term model is **owner + simple per-resource grants to named users** — tractable for one person.
The endgame is named so we don't accidentally build toward it; the near-term is deliberately small.

---

## 2. The tenancy model — owned-by-default + shareable-by-grant

Not "walls between mutually-distrusting strangers" (that's the enterprise endgame). The model is:

- **Account** = the tenant / ownership boundary. One operator = one account = many `intents`. (The
  review found `intent_id` is the natural per-project boundary but sits below ownership; an
  **`account_id` above intent** is the tenant key. One account owns many intents/projects/worlds.)
- **Owned by default.** Every resource (sessions, messages, engrams, docs, worlds, edges, work_items)
  belongs to exactly one account. A tenant sees its own rows, full stop.
- **Shareable by grant.** A `resource_grant` lets an owner expose a specific resource (a World, a
  doc corpus, an intent) to a specific **user** at a specific **access level** (read / contribute).
  Access = `owner OR has-a-grant`. This is the A2A scope-wall idea (the D&C 121 wall) made into rows.
- **Shared global corpus + my private rows.** Some catalog is legitimately global (the tool catalog,
  the model capability table, core agents) — readable by all tenants. A tenant's *data* is private.
  A **secure view** composes "the shared corpus + only my own private rows" in one query surface.

So three visibility classes per row: **private-to-account** (default), **shared-via-grant** (opt-in,
per-user, per-resource), **global** (catalog, by design). Single-user collapses this to "it's all
mine."

---

## 3. Where we are (from the grounded review)

- **Tenant isolation today: NONE.** No RLS, no tenant column, no secure views (grep-confirmed).
  `sessions.private` (`27`) is search-*visibility* (a raw `SELECT` bypasses it); `intents.file_private`
  (`29`) is filesystem path routing. Neither is access control.
- **Single-tenant-flat.** `intent_id` is on only **3 of ~60 tables** (`work_items`, `councils`,
  `scheduled_pipelines`); everything else is global or joins through `work_items`. `intents` has no
  owner column.
- **The AGE-drop left the door open (and it was the right call).** `01-graph.sql:6-7` justifies
  dropping Apache AGE precisely because plain `nodes`/`edges` tables give "the full Postgres toolbox
  (indexes, **RLS**, partitioning)." You cannot `CREATE POLICY` on AGE's opaque `ag_catalog` storage;
  you *can* on a plain table. So the foundation is RLS-ready — just not realized.
- **Four blockers** the build must solve: (1) the bgworker connects as **superuser** (bypasses RLS
  even under FORCE) → needs a dedicated non-superuser run-as role; (2) ~10 row-bearing tables need
  the key + backfill, `intents` needs an owner; (3) some globals are global *by design* → selective
  RLS; (4) **no identity rides the dispatch session** — and worse, a regression: `a2a_claim(claimer=…)`
  takes identity **from the payload** (self-asserted), the opposite of identity-at-transport.

## 4. The technical approach (research-confirmed)

**The Postgres-multi-tenancy research pass (`.spec/notes/2026-06-27-postgres-multitenancy-research.md`,
web-cited) confirmed model (a): shared schema + `owner_id` column + RLS with FORCE + a non-superuser
dispatch role + owner-OR-grant policies via a `SECURITY DEFINER` membership fn + `security_invoker`
secure views.** It wins because the *sharing* predicate (`owner OR grant`) is relational — only RLS
expresses it natively (schemas/separate-DBs can't); the runtime is one database by design; single-user
collapses to a no-op; and we already dropped AGE *to get* RLS. (Schema-per-tenant is the documented
runner-up, the right pivot only if a future need demands per-tenant `pg_dump`/`DROP SCHEMA` — deferred
escape hatch, not built.) The research doc carries the copy-paste DDL templates.

**★ The single highest-leverage line is not a policy — it's the bgworker's connection role.** A pgrx
bgworker connecting as the bootstrap **superuser silently voids every policy** (superusers bypass RLS
even under FORCE). So the order is non-obvious: the **non-superuser role + the leak-detector oracle
land FIRST**, before any column or policy — everything else is inert until the worker is non-super.
**One relief specific to us:** the classic RLS-+-PgBouncer pooling leak does **not** hit the bgworker
(it owns its SPI transactions); it only touches the external MCP/HTTP edge.

0. **The non-superuser dispatch role + the oracle (FIRST).** `CREATE ROLE stewards_app NOLOGIN
   NOSUPERUSER NOBYPASSRLS`; the bgworker connects as it (`BackgroundWorkerInitializeConnection(…,
   "stewards_app", …)`), belt-and-suspenders `SET LOCAL ROLE stewards_app` per work txn. Ship the
   **RLS-leak detector** alongside: a smoke that connects as `stewards_app`, sets `app.principal=B`,
   asserts **zero** of A's rows + the inverse (no context → only the solo owner's). Build-the-oracle-first.
1. **The tenant key.** Add `account_id` (uuid, FK to a new `stewards.accounts`) to the row-bearing
   tables, backfilled from the owning `work_item`/`intent`. `intents` gets `account_id`. A virgin
   install seeds exactly one account; everything defaults to it.
2. **Identity-at-transport (the Google steal, and it fixes the A2A regression).** A dedicated
   **non-superuser app role** the bgworker + bridge connect as; at dispatch, `SET LOCAL
   app.current_account = <work_item.account_id>` inside the transaction. **Identity rides the
   session/connection, never the tool args.** (The pooling landmine — `SET LOCAL` + transaction-mode
   PgBouncer — is a known gotcha the research pass is detailing; the bgworker's long-lived SPI
   connection needs the set-inside-the-tx discipline.)
3. **RLS on tenant tables.** `ENABLE` + `FORCE ROW LEVEL SECURITY`, `USING (account_id =
   current_setting('app.current_account', true)::uuid)`. Catalog tables stay open or behind a
   "shared OR owned" policy.
4. **Owner-OR-grant policy for shareables.** `resource_grant(account_id owner, grantee_user_id,
   resource_kind, resource_id, access)`; the policy becomes `owner = me OR EXISTS (a grant to me)`.
5. **Parameterized secure views** (`security_invoker`/`security_barrier`) for shared-but-scoped reads
   (`doc_search`, `context_search`, the graph walks, world reads) → "global corpus + my private rows
   + my granted rows" in one surface. Fold the `sessions.private` wall into a real policy.
6. **RLS-aware SPI path.** Audit the dispatcher / gates / cost rollups; legitimate cross-tenant work
   (watchman, steward, global cost accounting) gets explicit, audited `SECURITY DEFINER` carve-outs —
   not blanket superuser.
7. **Users + light auth (only as far as sharing needs).** A `users` table + the simplest credential
   that lets "share World X with user U" mean something. **NOT** an IdP. The A2A external-agent token
   model (the llama-chip hub) is the reference for the lightest possible auth. Where a "user" is
   another *agent*, this rides the A2A scope walls.

**Single-user degenerate case (the whole point):** one account, one (implicit) user, every row owned
by it, the RLS predicate always true, no grants needed, no login. The solo operator never configures
any of this.

## 5. Code-as-a-World (the motivating use case)

Repos imported as **Loreworks Worlds** — code understanding as a navigable graph (the existing
`research_codebase` + the world-graph engine, `54`–`58`). A repo = a World; sub-worlds = modules /
packages / services. Each World is a **shareable resource**: owned by an account, granted to specific
users (read / contribute). "Not everyone has access to every repo" = a World the grantee has no grant
on is invisible (an RLS policy on `worlds`/`world_entities`/`world_edges` keyed on the grant). This is
the first real exercise of the sharing model, and it's genuinely useful on its own (a queryable code
knowledge graph). It rides Phases 2–3 below.

## 6. Phases (single-user first, multi-tenant additive)

- **P0 — The non-super role + the oracle + the tenant key (additive, zero behavior change).** First
  the `stewards_app` (NOSUPERUSER/NOBYPASSRLS) role + the bgworker connecting as it + the RLS-leak
  detector smoke (the safety floor — inert but proven). Then `stewards.accounts` (seed one),
  `account_id` columns + backfill to `solo_principal()`. **Keep `intent_id` (workstream scoping)
  distinct from `owner_id`/`account_id` (principal ownership)** — different questions; the 3 tables
  with `intent_id` get the owner key alongside. After P0 the solo install behaves *identically* —
  we've only added a key and a role. *Oracle: virgin-smoke proves the worker is non-super, one
  account, all rows owned, runtime unchanged.*
- **P1 — Identity-at-transport + RLS isolation.** `SET LOCAL app.current_account` at dispatch; `FORCE`
  RLS on the tenant tables; secure views; the SPI carve-outs. *Oracle: virgin-smoke RLS assertion —
  tenant A cannot read B's sessions/messages/edges/docs; drop the policy, confirm the leak returns
  (inverse hypothesis). Single-user smoke unchanged.*
- **P2 — Owned + shareable-by-grant.** `resource_grant` + the owner-OR-grant policies + a light
  `users` table. *Oracle: owner shares World X with user U → U sees X and nothing else of the owner's.*
- **P3 — Code-as-a-World.** Repos → Worlds/sub-worlds via the grant model; the queryable code graph.
- **DEFERRED (named, not built):** enterprise federated-org RBAC / SSO / external IdP / per-team
  ACL federation. The horizon, not the road.

## 7. Council questions for Michael

1. **Tenant boundary granularity** — is the tenant the **account** (one operator, many intents/worlds),
   or finer? (Rec: account-above-intent. Single-user = one account.)
2. **"User" definition for sharing** — a human with a light credential, an A2A agent under a scope, or
   both? (Rec: both, reusing the A2A token/scope model; no IdP.)
3. **Scope confirmation** — agree the federated-org endgame is *out*, near-term = owner + per-resource
   grants? (Rec: yes — protect the "one dude with an AI" budget.)
4. **P0 timing** — land the additive tenant-key foundation now (no behavior change), or wait for the
   research pass + a full P1 design first? (Rec: research first — RLS is a one-way door; get the
   pattern right before adding columns.)

## 8. Provenance
- The codebase-grounded review: `.spec/notes/2026-06-27-agentic-findings-vs-substrate-review.md`
  (the gap, the 4 blockers, the AGE-door, the A2A identity regression).
- The Google "identity-at-transport / parameterized secure views" steal:
  `study/yt/google-cloud-agentic-playlist-digest.md` (#1 + C-1) — the directly-relevant primitive.
- The Loreworks world engine (`54`–`58`) — the code-as-World substrate.
- The A2A scope-wall / token model (`69-a2a-engine.sql`, the llama-chip hub) — the lightest auth.
- The Postgres-multi-tenancy research (web-cited): `.spec/notes/2026-06-27-postgres-multitenancy-research.md`
  — confirmed model (a), the bgworker-role-first ordering, the DDL templates, the single-user collapse,
  the top-6 gotchas (superuser-bypass + pooling first).
