# Tests

## `virgin-smoke.sql` — the authoritative virgin-boot test

Installs the extension on a fresh Postgres and asserts the clean-room
invariants of the authored chain (`extension/00-config.sql` → `19-models.sql`).
It uses plpgsql `ASSERT`, so any regression makes `psql` exit non-zero — the
test fails loudly rather than printing a wrong value.

What it proves:

1. **Dependency surface** — `vector` only. `pgcrypto` and AGE are neither
   required nor present (sha256 / `gen_random_uuid` are built-in; the graph is
   relational).
2. **The `doc_*` rename is complete** — zero `study_*` functions, tables, or
   `study_id` columns; `stewards.docs` exists.
3. **Every authored subsystem (00→19) has a representative object**, and the
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

```sh
docker build -t stewards-oss-pg:test extension/
docker run -d --name stewards-test \
  -e POSTGRES_USER=stewards -e POSTGRES_PASSWORD=test -e POSTGRES_DB=stewards \
  stewards-oss-pg:test -c shared_preload_libraries=pg_ai_stewards
# wait a second for readiness, then:
docker exec -i stewards-test psql -U stewards -d stewards -v ON_ERROR_STOP=1 < tests/virgin-smoke.sql
docker rm -f stewards-test
```

## CI

`.github/workflows/ci.yml` runs exactly this smoke on every push to `main` and
every pull request (the `extension` job), alongside `go build` + `go vet` (the
`go` job). The Go test suites (`*_test.go` under `cmd/`) are run locally; wiring
the ones that need a database into CI is a follow-up.
