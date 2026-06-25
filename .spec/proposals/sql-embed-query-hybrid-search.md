# Proposal: SQL-callable query embedding + hybrid (RRF) search

**Status:** proposal / implementation spec (branch `feat/sql-embed-query-hybrid`)
**Scope of THIS PR:** one mainline primitive — `stewards.embed_query(...)` — plus a small refactor
of the embed core. Everything overlay-specific stays out of mainline (notes at the end).

## Why

We want chat retrieval to do **hybrid full-text + semantic ranked search** so the model stops
missing relevant rows that a keyword query phrased a little differently. The proven technique is
**Reciprocal Rank Fusion (RRF)** — run each retriever independently, fuse by *rank position* so
incompatible score scales (ts_rank vs cosine) never have to be normalized:

```
RRF(d) = 1/(k + rank_kw(d)) + 1/(k + rank_vec(d))     # k = 60 (Cormack et al. 2009)
```

Reference: the RRF formulation from Cormack, Clarke & Büttcher (2009); a working Go implementation of this exact fusion exists as prior art.

**The blocker:** the substrate has **no query-time embedding**. `doc_search` and `pool_search` are
FTS (`websearch_to_tsquery`); `doc_similar` uses *precomputed* doc→doc cosine edges. Nothing can embed
an arbitrary chat query at search time, so a semantic leg is impossible from SQL today. That gap is
generic — it blocks hybrid search for docs, engrams, and any downstream embedded table. Closing it is
the mainline contribution; the per-table RRF fusion is then trivial SQL that lives wherever the table does.

## What to build (mainline)

### 1. Refactor the embed core — `extension/src/bgworker.rs`
`fn embed(provider_name, payload) -> Result<WorkOutcome, String>` (currently ~line 1608) does:
provider lookup → POST `{base_url}/embeddings` `{model, input:text}` → parse `data[0].embedding` →
dimension check → write the vector to `target_table/target_id` (the async work-queue path).

Extract the HTTP+parse core into a reusable, side-effect-free helper:

```rust
/// Embed one text and return the raw vector. No DB write, no target_table/id.
fn embed_one(provider: &Provider, text: &str, model: &str, expected_dim: i32)
    -> Result<Vec<f32>, String>
```

`embed()` keeps its work-queue behavior but now calls `embed_one()` for the HTTP+parse step. Reuse the
existing `send_with_retry` (#243 backoff) and the 120s blocking client inside `embed_one`.

### 2. Provider resolution without the bgworker registry (the one gotcha)
`PROVIDER_REGISTRY` is a per-process `OnceLock` set at bgworker boot (`bgworker.rs:57`, via
`ProviderRegistry::from_env()` at `providers.rs:77`). A `#[pg_extern]` runs in a **backend** process
where that OnceLock is empty — so do **not** assume the registry is populated.

Resolution: env vars are available in the backend process too, so call
`ProviderRegistry::from_env()` on demand (cheap — it just parses `*_BASE_URL/_KIND/_AUTH/...` env
vars). Optionally memoize per backend in its own `OnceLock`. `Provider::bearer_token()`
(`providers.rs:50`) mints the Vertex SA JWT from the mounted creds file and works in any process —
no change needed.

### 3. The pg_extern — `stewards.embed_query(...)`
```rust
#[pg_extern]
fn embed_query(
    text: &str,
    provider: default!(Option<&str>, "NULL"),   // NULL → a configured default embed provider
    model: default!(Option<&str>, "NULL"),       // NULL → provider.default_model
    dimensions: default!(i32, 1536),
) -> Vec<f32>                                     // caller casts ::vector
```
- Resolve provider (arg, else the configured embedding provider — see note below), model (arg, else
  `provider.default_model`), then `embed_one(...)`. Return `Vec<f32>` (pgrx → `float4[]`/`float8[]`;
  SQL caller casts `::vector`). Returning a `pgvector`-typed value directly is fine too if the
  extension already depends on a Rust pgvector binding; the `float[]→::vector` cast keeps the
  dependency surface smaller.
- Errors via `Result`/`error!` so a bad provider/timeout surfaces to the caller.
- **Document the latency**: this blocks the backend for the embedding round-trip (~100–500ms, up to
  120s on a cold local model). Acceptable for interactive search; not for bulk (bulk keeps the async
  work-queue path). Consider a short statement_timeout-friendly default and a hard cap.
- **Default embed provider:** pick the provider whose `KIND`/model is the embedding one (today the
  embed path uses gemini-embedding-2 @1536 on the Vertex provider, or nomic on a local provider).
  Expose it as a setting (e.g. `stewards.embed_provider` GUC or a one-row config) rather than
  hard-coding, so deployments differ cleanly.

### 4. Versioning
- Bump `default_version` in `extension/pg_ai_stewards.control` (`0.2.0` → `0.3.0`) and add the
  upgrade SQL pgrx generates for the new function. Existing volumes need `ALTER EXTENSION
  pg_ai_stewards UPDATE;` (or a re-init) — call this out in the PR description (the same
  volume-doesn't-auto-pick-up-new-migrations caveat from prior re-inits).

### 5. Tests (inverse hypothesis — don't ship on "it compiled")
- Unit: `embed_one` against a stubbed `/embeddings` endpoint (shape + dim mismatch path).
- Integration: pick a row whose meaning a pure-synonym query expresses with **no shared tokens**
  (e.g. an observation about "notification fatigue" vs the query "alert overload"). Confirm FTS +
  trigram **miss** it; `embed_query` + a cosine leg **catch** it; then remove the vector leg and
  confirm the miss returns. That closes the loop — the semantic leg is provably what fixed it.

## How the hybrid search then composes (example — NOT in this PR)

With `embed_query`, a 3-leg RRF is pure SQL over any embedded table:

```sql
WITH
 kw  AS (SELECT id, row_number() OVER (ORDER BY ts_rank(fts, websearch_to_tsquery($1)) DESC) r
           FROM t WHERE fts @@ websearch_to_tsquery($1) LIMIT 30),
 trg AS (SELECT id, row_number() OVER (ORDER BY word_similarity($1, body) DESC) r
           FROM t WHERE word_similarity($1, body) > 0.1 LIMIT 30),
 vec AS (SELECT id, row_number() OVER (ORDER BY embedding <=> stewards.embed_query($1)::vector) r
           FROM t ORDER BY embedding <=> stewards.embed_query($1)::vector LIMIT 30)
SELECT id, coalesce(1.0/(60+kw.r),0)+coalesce(1.0/(60+trg.r),0)+coalesce(1.0/(60+vec.r),0) AS rrf
FROM kw FULL JOIN trg USING(id) FULL JOIN vec USING(id)
ORDER BY rrf DESC LIMIT $2;
```
(Call `embed_query($1)` once in a CTE, not twice, in the real query.)

A natural follow-up mainline change: extend `doc_search`/`pool_search` to this 3-leg RRF so every
docs-pool consumer gets semantic recall.

## Boundary — what is mainline vs overlay
- **MAINLINE (this PR):** `stewards.embed_query()` + the `embed_one` refactor + version bump + the
  default-embed-provider setting. Generic, reusable, no deployment-specific identifiers.
- **OVERLAY (downstream, NOT this PR):** any overlay-specific RRF function and tool wiring over a
  downstream embedded table. A prototype overlay already has the lexical 2-leg RRF (keyword ⊕
  trigram); it will gain the `vec` leg the moment `embed_query` exists.

## References
- RRF: Cormack, Clarke & Büttcher (2009), "Reciprocal Rank Fusion outperforms Condorcet and individual rank learning methods"; a working Go implementation of this fusion exists as prior art.
- embed core to refactor: `extension/src/bgworker.rs` (`fn embed`, ~1608; `embed_one` target)
- provider env-parse + SA bearer: `extension/src/providers.rs` (`ProviderRegistry::from_env` :77,
  `Provider::bearer_token` :50, `AuthMode` :27)
- a working vector-search shape (caller supplies the embedding): a downstream overlay's
  `search_observations(q_embedding vector(1536), ...)` — `embedding <=> q_embedding` cosine.
