# Proposal: native Vertex embeddings (`embedContent`) — retire the OpenAI-shim for embeddings

**Status:** proposal / implementation spec
**Scope:** mainline (substrate). Give `embed_query` / the async `embed` path a way to embed via Vertex's
**native `embedContent`** endpoint when the provider is a Google-SA provider, because Vertex's
OpenAI-compat `/embeddings` endpoint does not serve embeddings. Sibling to
`native-vertex-grounding.md` — both move a Vertex-native capability the OpenAI-compat layer doesn't
expose into the core, and together they let the separate proxy daemon retire entirely.

## Why (the evidence)
`embed_one` (`bgworker.rs`) calls `{base_url}/embeddings` (OpenAI-compat). Against a Vertex
`google_vertex` provider (`AUTH=google_sa`, base `…/endpoints/openapi`) this returns **HTTP 500
INTERNAL for every request** — verified directly with a minted SA token against
`…/openapi/embeddings`, across multiple model ids (`gemini-embedding-001`, `text-embedding-005`,
`gemini-embedding-2`) and **with and without** the `dimensions` field. So:

- It is **not** the model id and **not** the `dimensions` field (the `embed-query-dimensions` change is
  exonerated). The Vertex **OpenAI-compat `/embeddings` endpoint simply does not serve embeddings** in
  this configuration — it is chat-completions-only.
- The **native** path works: Vertex `embedContent` (via the genai SDK) embeds
  `gemini-embedding-2 @ output_dimensionality=1536` fine — it is how the corpus was embedded, and a
  downstream overlay proxy now bridges it successfully (see "Current bridge" below).

So a Google-SA deployment currently has **no in-substrate embedding path**: async corpus `embed` and the
synchronous `embed_query` both dead-end at the 500. That blocks SQL-side semantic / hybrid search on any
Vertex-SA deployment.

## Current bridge (overlay, to be retired by this)
A local proxy (the same daemon that bridges grounded chat) gained a `/v1/embeddings` route that calls
the genai SDK's `embed_content(model, contents, EmbedContentConfig(output_dimensionality=…,
task_type=…))` and returns an OpenAI-compat `{data:[{embedding:[…]}]}`. Pointing `embed_provider` at that
proxy makes `embed_query` work end-to-end (validated: query-side `RETRIEVAL_QUERY` embeddings retrieve
the right documents by meaning with zero shared keywords). This proposal moves that capability
**in-substrate** so the proxy is no longer required.

## Step 0 — confirm the native request/response shape
Native Vertex embeddings (reuse the SA bearer `Provider::bearer_token()` already minted in
`providers.rs` via `gcp_sa.rs`):
```
POST https://{LOC}-aiplatform.googleapis.com/v1/projects/{PROJ}/locations/{LOC}/publishers/google/models/{model}:predict
Authorization: Bearer <SA OAuth>
{ "instances": [ { "task_type": "RETRIEVAL_QUERY", "content": "<text>" } ],
  "parameters": { "outputDimensionality": <dims> } }
```
(Or the genai REST `:embedContent` form.) Response → `predictions[0].embeddings.values` (a float array).
Verify the exact field path against the live API for the chosen model before coding — the genai SDK
returns `resp.embeddings[0].values`; the raw `:predict` shape nests under `predictions[]`.

## Design — a native embeddings branch in `embed_one`
The auth seam already exists: `Provider.auth = AuthMode::GoogleSa{credentials_file}` and
`bearer_token()`. Branch on it:
1. In `embed_one`, when `provider.auth` is `GoogleSa` (or a new explicit `embed_kind`/capability),
   build the **native** `:predict`/`:embedContent` request against the Vertex model endpoint instead of
   `{base_url}/embeddings`, mint the SA bearer (existing path), POST, and parse
   `predictions[0].embeddings.values`.
2. Pass `outputDimensionality = expected_dim` (the `dimensions` arg — same intent as the OpenAI-compat
   `dimensions` field from `embed-query-dimensions`, just the native parameter name). Keep the
   length-check safety net.
3. `task_type`: embeddings are asymmetric. `embed_query` is the QUERY side → `RETRIEVAL_QUERY`; the async
   corpus `embed` path → `RETRIEVAL_DOCUMENT`. Thread a task-type through (default QUERY for
   `embed_query`, DOCUMENT for bulk `embed`), or add an optional arg. This materially improves retrieval
   sharpness (validated overlay-side).
4. Provider URL: derive the publisher-model endpoint from the project/location the SA + base_url already
   encode, or add a small `embed_base`/model-template provider field. Keep OpenAI-compat embeddings as
   the default for non-SA providers (nomic, OpenAI, etc.) — they work and need no change.

## Boundary
- MAINLINE (this PR): a native Vertex `embedContent` branch in `embed_one`, SA-bearer reuse,
  `outputDimensionality` + `task_type`, length-check retained. Non-SA providers unchanged.
- OVERLAY (downstream, after this lands): point `embed_provider` at the native `google_vertex` provider;
  drop the proxy's `/embeddings` route. Combined with native grounding, the proxy daemon retires fully.

## Tests (inverse hypothesis)
Start from the failure: with the proxy stopped and `embed_provider=google_vertex`, `embed_query('x',
NULL, NULL, 1536)` errors today (OpenAI-compat 500). Apply → the same call returns a 1536-vector via
native `embedContent`, AND a SQL cosine search over a corpus embedded the same way retrieves by meaning
(a no-shared-keyword paraphrase surfaces the right rows). Revert → the 500 returns. A non-SA provider
(nomic@768) still embeds via the OpenAI-compat path unchanged.

## Related
- `embed-query-dimensions.md` (merged, #2) — makes `dimensions` requested; the native param here is
  `outputDimensionality`, same intent.
- `native-vertex-grounding.md` — the sibling capability; landing both retires the proxy daemon entirely.
