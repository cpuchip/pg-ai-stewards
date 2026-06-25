# Proposal: native Vertex Google-Search grounding (retire the OpenAI-shim proxy)

**Status:** proposal / implementation spec
**Scope:** add Google Search grounding to the native `google_vertex` provider path, so grounded
web search works without the separate OpenAI-compat proxy daemon. Mainline (substrate) feature; the
downstream consumer's switch-over is overlay.

## Why
The native Vertex provider (OpenAI-compat endpoint + service-account OAuth, already merged) handles
auth — which was the proxy's *original* reason to exist (the substrate dials providers as OpenAI
endpoints with a static key; Vertex uses rotating OAuth, so a shim bridged it). That job is now done
natively. The proxy's **only** remaining role is **Google Search grounding**: it calls the genai SDK
with `Tool(google_search=GoogleSearch())`, which the OpenAI-compat surface doesn't expose. One
consumer (a web-research gatherer, model id suffixed `-search`) routes through it. Retiring the proxy
removes a separate always-on daemon, a second auth surface, and a single point of failure — and lets
grounding source URLs come back through the native path.

## Current state
- `google_vertex` provider: `KIND=openai`, base `…/openapi`, `AUTH=google_sa` → native chat, NO grounding.
- proxy (`google_gemini` provider → a local genai-SDK shim): the ONLY grounded path. Enables grounding
  via `GenerateContentConfig(tools=[Tool(google_search=GoogleSearch())])` and extracts
  `grounding_metadata.grounding_chunks[].web.{uri,title}` as a Sources block (so citations survive).
- No model alias routes to the proxy; only the gatherer's hardcoded `<model>-search` id does.

## Step 0 — INVESTIGATE FIRST (decides A vs B)
Does the Vertex **OpenAI-compat** endpoint (`…/openapi/chat/completions`) accept a Google Search tool?
Test with an SA bearer:
```
POST …/openapi/chat/completions
{ "model":"google/gemini-3.5-flash", "messages":[{"role":"user","content":"latest home-security market news"}],
  "extra_body": { "tools": [ { "google_search": {} } ] } }      # or "googleSearchRetrieval"
```
Inspect the response for grounding/citation metadata. (Vertex's OpenAI layer has been gaining
tool/grounding support; verify against the current API rather than assuming.)

## Design A — grounding rides the OpenAI-compat path (if Step 0 succeeds)
Smallest change. The substrate gains a way to request grounding on a `google_vertex` call and to
surface the citations:
1. A request convention the dispatch understands — reuse the proxy's `<model>-search` suffix, OR a
   per-stage/provider `grounded` flag. On grounded calls, inject the search tool into the request body.
2. On the response, extract the grounding citations (uri+title) and append a `Sources:` block to the
   returned content (mirror the proxy's `_sources_block`) so downstream URL-scraping still works.
   Touch points: `bgworker.rs` chat dispatch (request build + response shaping), `providers.rs`
   (capability/flag).

## Design B — a native generateContent grounded path (if Step 0 fails)
The OpenAI-compat surface can't do it, so call Gemini's native endpoint for grounded requests:
```
POST https://{LOCATION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{LOCATION}/publishers/google/models/{model}:generateContent
Authorization: Bearer <SA OAuth token>     # reuse Provider::bearer_token() (gcp_sa.rs)
{ "contents":[…], "tools":[ { "googleSearch": {} } ] }
```
Parse `candidates[0].content.parts[].text` for the answer and
`candidates[0].groundingMetadata.groundingChunks[].web.{uri,title}` for citations; assemble an
OpenAI-compat response (content + appended `Sources:` block). This is exactly what the proxy does,
moved in-substrate. Gate it on the `-search` suffix so only grounded calls take this branch; everything
else stays on the OpenAI-compat path. Reuses the existing SA token mint — no new auth.

## Source URLs (ties to the provenance fix already shipped overlay-side)
Either design must surface `groundingMetadata.groundingChunks[].web.uri` (+ `.web.title`) — Gemini
returns `…/grounding-api-redirect/…` redirect URLs + the publisher name. Emit them as a markdown
`Sources:` block in the content so any consumer's `https?://` scrape captures them. (Reference behavior:
the proxy's `_sources_block` / `_grounding_from_response`.)

## Retire the proxy (overlay, after the above lands — NOT this PR)
Point the gatherer at the native grounded model (`google_vertex`, `<model>-search`), drop the
`google_gemini` provider + the proxy daemon. Verify the gatherer's web docs still populate `sources[]`
natively. (A separate crawl in this deployment already gathers via a keyless web-search MCP and never used the proxy.)

## Boundary
- MAINLINE (this PR): native Google-Search grounding on the `google_vertex` path + citation surfacing.
- OVERLAY (downstream): switching a gatherer off the proxy; deleting the proxy + its provider.

## Tests (inverse hypothesis)
With the proxy STOPPED: a grounded native call returns a synthesized answer AND source URLs; a
downstream gatherer's web docs populate `sources[]`. Start from the failure (proxy off → today, no
native grounding → empty) → apply → confirm grounded + sourced → confirms the native path is what fixed it.
