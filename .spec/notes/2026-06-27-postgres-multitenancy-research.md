# Industry-Standard Multi-Tenancy in PostgreSQL — Guide for pg-ai-stewards (2026)

*Opus research pass, web-verified against the Postgres 18 docs + AWS/Supabase/Citus/PgBouncer/
PlanetScale. Feeds `.spec/proposals/multi-tenancy-and-single-user.md`. Sources at the bottom.*

## The framing decision this system forces

pg-ai-stewards is not a SaaS app behind a pooler — it is an **in-database runtime**: a pgrx
bgworker holds long-lived SPI connections and IS the database's primary actor. That changes the
standard advice two ways:
- The classic **"RLS + PgBouncer transaction-pool leak"** landmine **does NOT hit the bgworker's
  own queries** (no pooler in front of its SPI connection). It hits only the external MCP/HTTP edge.
- The **"connect as a non-superuser app role"** rule is the single most important and most easily
  violated rule here: a pgrx bgworker connects as whatever role you hand
  `BackgroundWorkerInitializeConnection`, and the path of least resistance is the bootstrap
  superuser — which **silently voids every policy you write** (superusers + `BYPASSRLS` always
  bypass RLS, even under FORCE).

And the requirement is **owned-by-default + shared-by-grant**, so the access predicate is
`owner OR grant` — a *relational* predicate, which **only RLS expresses natively** (schemas and
separate databases can't). This is also why dropping AGE for relational `nodes`/`edges` was right:
you can't put an RLS policy on an AGE graph.

## The three models (scored for THIS system)

| Property | (a) Shared schema + tenant col + RLS | (b) Schema-per-tenant | (c) DB-per-tenant |
|---|---|---|---|
| Sharing across tenants | **Trivial — a row in a grants table** | Painful (cross-schema GRANTs) | Awful (dblink/FDW) |
| Ops / migration | **Lowest — migrate one schema once** | High (replay DDL × N) | Highest |
| Pooling cost | One pool + `SET LOCAL` | `search_path` per tenant | N pools (RAM blows up) |
| Fit for an in-DB agent runtime | **Native** (graph/memory cross-ref in one table set) | Fragments the cross-tenant graph | **Breaks the architecture** (runtime is ONE db) |
| Single-user collapse | **Clean — policy is a no-op pass** | A schema indirection for nothing | A whole DB for one person |

**Recommendation: model (a)** — shared schema, `owner_id` column, RLS with **FORCE**, a dedicated
non-superuser **`stewards_app`** role for the bgworker, owner-OR-grant policies via a
**`SECURITY DEFINER` membership function**, and **`security_invoker` secure views**. Wins because:
(1) the sharing requirement is relational and only RLS expresses it natively; (2) the runtime is
one database by design; (3) single-user collapses to nothing; (4) you already dropped AGE *to get*
RLS — this is the cash-in.

**Schema-per-tenant is the documented runner-up**, and the right pivot *only if* a future need
demands per-tenant `pg_dump`/`DROP SCHEMA` lifecycle or per-tenant schema drift (neither in scope).
Note it as a deferred escape hatch; don't build it.

**Honest steelman (PlanetScale):** RLS is per-row overhead you must keep optimized; policies live
in the DB so you must version them as DDL; RLS stops a tenant from *seeing* data but not from
*running* the query → it's **defense-in-depth, not your only authz** (the edge still verifies
identity + rate-limits). With FORCE + a non-super role + indexed predicates, bounded and worth it.

## RLS facts that bite (PG 18 docs)
- `ENABLE` = default-deny if no policy; **`FORCE` makes even the table owner subject** (needed —
  the substrate's tables are owned by the app). Superuser/`BYPASSRLS` bypass *regardless*.
- `USING` (which rows are visible: SELECT/UPDATE/DELETE) vs `WITH CHECK` (which rows may be written:
  INSERT/UPDATE). `USING`-only is copied to `WITH CHECK` implicitly → write per-command policies.
- **PERMISSIVE** policies OR together (default); **RESTRICTIVE** policies AND together — use a
  restrictive policy for a hard floor no permissive policy can widen (a kill-switch).
- `current_setting('app.principal', true)` — the `true` (missing_ok) returns NULL when unset
  (so single-user with no `SET` doesn't throw). It's STABLE → planner evaluates once.
- **`security_invoker` views are PG 15+.** Before 15 every view ran SECURITY DEFINER (view-owner
  rights → silently bypassed base-table RLS). For a secure view use
  `WITH (security_invoker = true, security_barrier = true)`.

## The pooling landmine (edge-only here)
Transaction-pooled connections carry session `SET` to the next borrower; custom GUCs aren't
`GUC_REPORT` so **PgBouncer cannot track `app.principal`**. Fix: **`SET LOCAL` inside an explicit
transaction, always** (auto-resets at COMMIT, safe on a recycled backend). The bgworker SPI path is
naturally safe (it owns its transactions); only the external Go/MCP edge behind a pooler needs care.

## Owned + shared-by-grant (the copy-paste DDL)

```sql
-- The acting identity, resolved once per query, with the zero-ceremony solo fallback.
CREATE FUNCTION app.current_principal() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT COALESCE(NULLIF(current_setting('app.principal', true), '')::uuid,
                  app.solo_principal());   -- the bootstrap owner when no context is set
$$;

CREATE TABLE app.resource_grants (
  resource_kind text NOT NULL,             -- 'world','corpus','doc','repo',…
  resource_id   uuid NOT NULL,
  grantee_id    uuid NOT NULL REFERENCES app.principals(id),
  capability    text NOT NULL CHECK (capability IN ('read','write','admin')),
  granted_by    uuid NOT NULL, granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (resource_kind, resource_id, grantee_id, capability)
);
CREATE INDEX ON app.resource_grants (grantee_id, resource_kind, resource_id);

-- Membership as SECURITY DEFINER so reading grants does NOT re-trigger RLS (breaks recursion).
CREATE FUNCTION app.has_grant(p_kind text, p_resource uuid, p_cap text) RETURNS boolean
  LANGUAGE sql STABLE SECURITY DEFINER SET search_path = app, pg_temp AS $$
  SELECT EXISTS (SELECT 1 FROM app.resource_grants g
    WHERE g.resource_kind=p_kind AND g.resource_id=p_resource
      AND g.grantee_id=app.current_principal()
      AND g.capability IN (p_cap,'admin'));      -- admin implies the lesser cap
$$;

-- owner-OR-grant on a shareable table (e.g. worlds):
ALTER TABLE app.worlds ENABLE ROW LEVEL SECURITY;  ALTER TABLE app.worlds FORCE ROW LEVEL SECURITY;
CREATE POLICY worlds_read   ON app.worlds FOR SELECT
  USING (owner_id=app.current_principal() OR visibility='public' OR app.has_grant('world',id,'read'));
CREATE POLICY worlds_insert ON app.worlds FOR INSERT
  WITH CHECK (owner_id=app.current_principal());           -- you may only create rows you own
CREATE POLICY worlds_update ON app.worlds FOR UPDATE
  USING      (owner_id=app.current_principal() OR app.has_grant('world',id,'write'))
  WITH CHECK (owner_id=app.current_principal() OR app.has_grant('world',id,'write'));
CREATE POLICY worlds_delete ON app.worlds FOR DELETE
  USING (owner_id=app.current_principal() OR app.has_grant('world',id,'admin'));

-- secure "parameterized" view (PG15+): only-my-stuff, base-table RLS of the CALLER applies
CREATE VIEW app.my_worlds WITH (security_invoker=true, security_barrier=true) AS
  SELECT id, name, visibility FROM app.worlds;
```

For a shared World's subgraph, **don't grant per-edge** — let edges inherit visibility from their
World (`app.has_grant('world', world_id, 'read')`), so sharing one World shares its whole subgraph
atomically.

## THE most important line (land this first)

```sql
CREATE ROLE stewards_app NOLOGIN NOSUPERUSER NOBYPASSRLS;   -- bgworker connects AS this
-- pgrx: BackgroundWorkerInitializeConnection("stewards_db", "stewards_app", 0)  -- NOT bootstrap superuser
--   belt-and-suspenders if the login role can't change:  SET LOCAL ROLE stewards_app;  per work txn
```
Everything else (policies, grants, views) is **inert until the worker is non-superuser**. Cross-tenant
work (reaper, global seeds, cost rollups) gets explicit audited `SECURITY DEFINER` carve-outs —
not blanket superuser.

## The SET LOCAL dispatch idiom (the only dispatch primitive)
```sql
BEGIN;
  SET LOCAL ROLE stewards_app;                       -- if not already that login role
  SET LOCAL app.principal = <work_item.owner_id>;    -- TRUSTED, from the record — never from tool args
  PERFORM app.run_agent_turn(<work_item>);
COMMIT;   -- principal + role auto-reset; safe even on a recycled pooled backend
```
Identity rides the connection/session, **never the query arguments.** (At the external edge: the Go
bridge verifies the caller, then `SET LOCAL app.principal` from the verified identity — Supabase's
`request.jwt.claims` pattern.)

## Single-user collapse (zero ceremony)
- The edge **never sets `app.principal`** in solo mode → `current_principal()` falls through to
  `solo_principal()` (the one bootstrap owner).
- Every row's `owner_id` defaults to that principal → `owner_id = current_principal()` is **always
  true** → RLS evaluates, passes, gets out of the way. No grants, no context-setting, no overhead.
- **Fails CLOSED:** a missing context falls back to *the single owner*, never to "all tenants."
- **Additive promise:** when a 2nd principal + a grant first appear, change exactly TWO things —
  the edge starts `SET LOCAL app.principal` from verified identity, and you insert `resource_grants`
  rows. No table reshape, no policy rewrite, no migration.

**Migration:** add `owner_id NOT NULL DEFAULT app.current_principal()`, backfill to
`solo_principal()`, then `ENABLE`+`FORCE`+policies — as authored chain DDL, with a virgin-smoke
assertion that `relrowsecurity AND relforcerowsecurity` hold on every tenant table. **Do NOT
conflate `intent_id` (workstream scoping) with `owner_id` (principal ownership)** — different
questions, keep both. The 3 tables that already carry `intent_id` get `owner_id` alongside.

## Build the oracle first
A smoke test that connects **as `stewards_app`**, sets `app.principal` to principal B, and asserts
it sees **zero** of principal A's rows — and the inverse, that with **no context** set it sees only
the solo owner's. That detector is what makes the whole RLS layer safe to evolve (inverse hypothesis:
drop the policy → confirm the leak returns).

## Top 6 gotchas (ranked)
1. **Superuser/BYPASSRLS bypass — the bgworker trap.** Connect as `stewards_app`; test RLS as a
   non-super role, never as yourself.
2. **Pooling + `SET` leaks context** — `SET LOCAL` inside an explicit txn, always (edge-only here).
3. **`ENABLE` without `FORCE`, or `USING` without `WITH CHECK`** — always FORCE; explicit per-command.
4. **Unindexed grant lookups + per-row predicate functions** — index `owner_id` + `resource_grants`;
   push membership into a STABLE SECURITY DEFINER fn; keep the hot `owner_id=` arm a bare comparison.
5. **RLS-bypass surfaces** — pre-15 views (set `security_invoker`), your own SECURITY DEFINER fns,
   **materialized views** (data escapes RLS — filter at refresh), FK/global-UNIQUE covert channels
   (scope uniqueness to `(owner_id, key)`).
6. **Recursive RLS + trusting identity from the payload** — break recursion with the SECURITY DEFINER
   lookup; derive `app.principal` from the trusted record/JWT, never agent-produced args.

## Sources (verified)
Postgres 18 docs (Row Security Policies; CREATE VIEW); PG feature matrix (security_invoker = PG15);
Mydbops (pre-15 SECURITY DEFINER views); Bytebase (RLS footguns); AWS Database Blog (tenant_id+RLS
reference); PgBouncer features + Citus (track_extra_parameters / GUC_REPORT); PlanetScale (RLS
steelman); Supabase RAG-with-Permissions (jwt.claims, SECURITY DEFINER membership); ClickHouse
(2026 model-selection consensus); pganalyze / Daniel Imfeld (SET LOCAL + pooler in practice).
