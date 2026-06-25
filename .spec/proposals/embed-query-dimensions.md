# Proposal: `embed_query` should request its dimension, not just validate it

**Status:** proposal / implementation spec
**Scope:** mainline (substrate). Make `stewards.embed_query(text, provider, model, dimensions)` actually
honor `dimensions` for Matryoshka (MRL) embedding models, so one model can serve multiple vector sizes.

## Why
`embed_query` takes a `dimensions` argument (default 768) and its doc-comment invites callers to "pass
1536" for a larger model. The implication is that the dimension is *requested*. It is not.

`bgworker.rs::embed_one` builds the embeddings request as:

```rust
let body = serde_json::json!({ "model": model, "input": text });
```

— no dimension field — and then uses `expected_dim` **only to validate the response length**:

```rust
if arr.len() as i32 != expected_dim {
    return Err(format!("embedding dimension mismatch: got {}, expected {}", arr.len(), expected_dim));
}
```

So the provider returns its **default** output dimension and `dimensions` merely has to match it. For a
fixed-size model (e.g. nomic-embed-text-v1.5 → always 768) this is invisible. For an **MRL model**
(Google `gemini-embedding`, OpenAI `text-embedding-3-*`), the default output is the *full* width
(1536/3072), and the truncated size is obtained only by **asking** for it via the standard OpenAI
`dimensions` request field (which Vertex's OpenAI-compat surface maps to `output_dimensionality`).
Result: `embed_query(text, p, m, 768)` against such a model returns the full vector and throws
`embedding dimension mismatch: got 3072, expected 768`. The argument that was supposed to *select* the
size instead *rejects* the result.

This blocks the legitimate, common pattern of using ONE embedding model at TWO sizes — e.g. a small
vector for a lightweight entity/index layer and a larger vector for a high-recall document corpus.

## Current state
- `embed_query(text, provider DEFAULT NULL, model DEFAULT NULL, dimensions DEFAULT 768)` → `embed_query_impl`
  → `embed_one(provider, text, model, dims)` (`lib.rs`).
- `embed_one` posts `{model, input}` to `{base_url}/embeddings`, reads `data[0].embedding`, and validates
  `len == dims` (`bgworker.rs`).
- The async embed path (`embed`, used by the bgworker for corpus embedding) flows through the same
  `embed_one`, so it inherits the same limitation.

## Step 0 — INVESTIGATE FIRST (decides A vs B per provider)
For each embedding provider in play, confirm whether its OpenAI-compat `/embeddings` endpoint honors a
`dimensions` field. Test with the real endpoint + auth:

```
POST {base_url}/embeddings
{ "model": "<mrl-model>", "input": "test", "dimensions": 768 }
```
Inspect `len(data[0].embedding)`. If it returns 768 → Design A works for that provider. If it ignores the
field and returns the full width → that provider needs Design B (or doesn't support truncation at all).
Don't assume — OpenAI documents `dimensions` for `text-embedding-3-*`; Vertex's compat layer should map it
to `output_dimensionality`, but verify against the live API.

## Design A — send `dimensions` on the OpenAI-compat request (smallest change)
In `embed_one`, include the field when a positive dimension is requested:

```rust
let mut body = serde_json::json!({ "model": model, "input": text });
if expected_dim > 0 {
    body["dimensions"] = serde_json::json!(expected_dim);
}
```

Keep the existing length check as a **safety net**: if a provider silently ignores the field and returns
the wrong size, the call still errors loudly rather than writing a mis-sized vector. Providers that don't
support truncation are simply called at their native size (request that size, get it back, check passes).

Optional refinement: a per-provider capability flag (`supports_output_dim`) so the field is only sent
where Step 0 confirmed support — avoids sending an unknown field to servers that reject (rather than
ignore) extras. Default to sending when `>0`; gate only if a real provider rejects it.

## Design B — native embed endpoint for providers without compat-`dimensions` (fallback)
If a provider's OpenAI-compat surface can't truncate but its native API can (Google's
`embedContent` with `EmbedContentConfig(output_dimensionality=…)`), add a provider-native embed branch
for that case — mirror the auth the provider already uses (e.g. SA bearer for a Vertex-style provider).
Only needed for providers where Step 0 shows A fails; everything else stays on the compat path.

## Tests (inverse hypothesis)
Start from the failure: with an MRL model configured, `SELECT array_length(stewards.embed_query('x',
NULL, NULL, 768), 1)` today either errors (`mismatch: got 3072, expected 768`) or only succeeds at the
model's single default. Apply the fix → the same call returns a 768-length vector AND
`embed_query('x', NULL, NULL, 1536)` returns 1536 from the *same* model. Revert → the 768 call fails
again. That round-trip confirms the request field (not a coincidental default) is what selected the size.
Regression: a fixed-size provider (nomic@768) still returns 768 and still passes the length check.

## Boundary
- MAINLINE (this PR): `embed_one` requests the dimension; length check retained as a safety net; optional
  per-provider capability gate.
- NON-GOAL: changing stored column widths or any caller's chosen dimension — purely makes the existing
  `dimensions` argument do what its name and doc-comment already promise.
