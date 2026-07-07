# Tests

## `virgin-smoke.sql` — the authoritative virgin-boot test

Installs the extension on a fresh Postgres and asserts the clean-room
invariants of the authored chain (`extension/00-config.sql` → `86-sticky-agent-family.sql`).
It uses plpgsql `ASSERT`, so any regression makes `psql` exit non-zero — the
test fails loudly rather than printing a wrong value.

What it proves (representative, not exhaustive — the file gains one `OK N`
block per accreted subsystem, currently through `OK 88`):

1. **Dependency surface** — `vector` only. `pgcrypto` and AGE are neither
   required nor present (sha256 / `gen_random_uuid` are built-in; the graph is
   relational).
2. **The `doc_*` rename is complete** — zero `study_*` functions, tables, or
   `study_id` columns; `stewards.docs` exists.
3. **Every authored subsystem (00→86) has a representative object**, and the
   dispatch FINAL (`work_item_dispatch_stage`) carries all four accreted layers
   (resolution + capability substitution + spend-cap gate + per-call max_tokens).
4. **No operator / personal seeds leaked into core** — the configured-at-runtime
   registries (`scheduled_pipelines`, `model_capability`, `model_pricing`) are
   empty, there are no workspace persona families, and no personal intent slugs.
   Operator seeds live in the downstream workspace overlay.
5. **The functional spine runs end to end** — seed a default intent, create a
   work_item, dispatch it; the dispatch substitutes an unusable model for the
   usable catalog default and logs the swap with a reason.

## Run it locally

Before building the image, check that `extension/Dockerfile`'s generated SQL
COPY block still matches `extension/src/lib.rs` — run this **UNPIPED** so its
exit code isn't swallowed (the forgotten-COPY failure class this closes):

```sh
extension/gen-copy-manifest.sh --check
```

Exit 0 means the block is current. Non-zero means a chain file was
added/removed in `lib.rs` without regenerating — run
`extension/gen-copy-manifest.sh` (no flags) to fix it, then re-check.

```sh
docker build -t stewards-oss-pg:test extension/
docker run -d --name stewards-test \
  -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=test -e POSTGRES_DB=stewards \
  stewards-oss-pg:test -c shared_preload_libraries=pg_ai_stewards
# wait a second for readiness, then:
docker exec -i stewards-test psql -U stewards -d stewards -v ON_ERROR_STOP=1 < tests/virgin-smoke.sql
docker rm -f stewards-test
```

## `e2e-turn-loop.sh` — the running-turn invariants

virgin-smoke asserts schema/seeds; `verify-*` asserts single functions. Neither
runs a **turn**, so a class of bugs sails through — they only appear when dispatch
→ tool-rounds → verify → consult actually executes (the on_one_shot clobber that
left turns at `maturity=raw`; a prompt that dumped the same answer to every
question; the consult that read the prior turn's reply). `e2e-turn-loop.sh` is that
missing layer: against a running stack it dispatches a real persona turn and
asserts (1) it auto-verifies + is non-empty, (2) a different question yields a
different answer, (3) a consult re-ask produces a NEW tracked reply.

```sh
tests/e2e-turn-loop.sh [pg_container] [pipeline_family]   # defaults: stewards-oss-pg persona-turn
```

Makes real LLM calls (~1–2 min, small cost) — run on demand, **not** in
every-commit CI. Exit 0 = invariants hold. (The persona-host's Go consult-ordering
fix is additionally covered by the `cmd/persona-host` go tests.)

## `fixtures/crawl-site/` — the purpose-crawler's sandbox

A tiny static site (7 pages + `robots.txt`) for the 98-crawler oracle: an
index linking a relevant chain (`relevant1 → relevant2 → deep3 → deep4`), an
irrelevant merch page, a robots-disallowed path (`/secret/`), and an offsite
link. Real crawls are NOT grindable (they hit live sites); this fixture is
the resettable sandbox that is. Two halves consume it:

- **Go** — `cmd/fetch-md-mcp`'s `TestCrawlFixtureSite` serves it via httptest
  and drives the real tool handlers in `enforce_robots` mode (robots block,
  link categorization, markdown extraction, redirect-hop re-check).
- **SQL** — virgin-smoke's `OK 98` block proves the frontier machinery's
  structural floor (page/byte/depth budgets, domain wall, dedup) against the
  same shapes, pure SQL, no network.

## CI

`.github/workflows/ci.yml` runs exactly this smoke on every push to `main` and
every pull request (the `extension` job), alongside `go build` + `go vet` (the
`go` job). The Go test suites (`*_test.go` under `cmd/`) are run locally; wiring
the ones that need a database into CI is a follow-up.
