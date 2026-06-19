# Proposal: page-in large tool results (retrieval, not inlining)

Status: DRAFT — dominion_in_council (new standing capability: new tools + a result store).
Date: 2026-06-18. Author: Claude (with Michael, from the FlexLLama local-inference session).

## Problem

A tool-using stage (gather, research, digest) accumulates tool results in the conversation,
and the bgworker re-sends the growing array each round. A single round of web gather —
system prompt + brief-so-far + a few fresh `fetch_url`/`doc_get` results — has an **irreducible
working set of ~35–65k tokens**, because the fetched pages are inlined *raw*. On a model whose
window is smaller than that, the request 400s in one round (`gemma@32k: 37,601 > 32,768`), and
no amount of folding helps: you can't fold the very results you're actively reasoning over.

The window-aware budget fix (15a `effective_budget` Layer 2.5, 2026-06-18) addresses the
*folding* side — it keeps the budget under the real window with a 30% reserve, so the existing
graduated compaction and the judge-brief intercept fire at the right threshold. **This proposal
is the other half: the *retrieval* side — stop inlining the big thing at all.**

## What already exists (build on, don't duplicate)

- **judge-brief intercept** (`15a`/ES.3): a tool result over `effective_budget × 0.25` is
  summarized by a cheap judge into `{urls, dates, names, quotes}`. Lossy, automatic, not
  model-chosen.
- **`context_search`** (`27`): grep over the agent's own (incl. folded) context.
- **`expand_message`**: read a specific folded/compressed message in full.
- **`fs_read`** with `offset`/`limit`: paging already works for *files*.
- **`summarize_url` / `summarize_doc`**: summarize a URL/doc into a brief.
- **engrams + `re_extract_engrams`**: tool-result summarization under pressure.

So ~70% of the machinery is here. The gap: a big `fetch_url`/`doc` result is still **inlined raw**
on the round it arrives, and the model can't *choose* which spans to pull.

## Idea: store-and-page

When a tool result exceeds a threshold (e.g. `effective_budget × 0.5` — now window-relative after
the budget fix), don't inline it. Instead:
1. **Store** the full result as a blob/doc with an id (reuse `messages_raw_overflow` or the doc pool).
2. **Return to the model** a compact stand-in: a short summary + metadata (title, byte/line/section
   count) + a **handle**.
3. Give the model **read-slice tools** to pull spans on demand:
   - `result_read(handle, offset, limit)` — read a line/char range (like `fs_read`).
   - `result_search(handle, query)` — grep within the stored result, return matching spans.
   The model pulls only what it needs into the working window.

This is model-chosen retrieval (better than lossy auto-summary): the agent decides what matters,
the rest stays out of the window.

## Why it's worth it (beyond local models)

- **Makes small/fast models viable for big gather** — nemotron-4B (1M ctx, 204 tok/s) could gather
  if it never has to hold a 40k page; it pages in spans.
- **Cuts cost on PAID providers** — today a multi-round gather ships ~200k+ cumulative raw tokens to
  kimi/etc. Store-and-page sends summaries + chosen spans → large token (cost) reduction.
- **Composes with the window-aware budget** (`effective_budget` Layer 2.5): the threshold is the
  same window-relative number; folding handles the torso, paging handles the fresh giant.

## Phasing

- **P0**: threshold-store + summary+handle for `fetch_url`/`fetch_urls`/`doc_get` results; the two
  read-slice tools; wire the threshold to `effective_budget × 0.5`. Grant to `research`/`dev`.
- **P1**: generalize to all tool results; auto-tune threshold; let the judge-brief intercept emit a
  handle (so its summary is re-expandable to spans, not just `expand_message` of the whole).
- **P2**: a shared result store with TTL + dedup (a fetched URL paged once is reusable across rounds
  and across work-items in the same intent).

## Open questions (council)

- Storage home: reuse `messages_raw_overflow` (already holds dropped raw) vs a dedicated `tool_blobs`.
- Threshold default (0.5 of budget) and whether per-tool overrides are needed.
- Does the model reliably *use* read-slice tools? (Telemetry says agent-driven context tools see ~0
  adoption — #136. The tool primers / strong stage instructions may be needed, OR keep the
  auto-summary as the floor and treat paging as an opt-in power tool.)
- dominion_in_council: new standing tools + a store = a new capability; ratify before building.

## Relation to the session's findings

This closes the loop opened by the local-inference work: gemma@128k handles gather because its
window holds a round; small windows 400. The durable fix is **don't put the big thing in the
window** — page it. Pairs with `effective_budget` Layer 2.5 (the budget fix, shipped) and the
strict-template `compose_messages` fix (`258eaea`). Findings:
`projects/pg-ai-stewards-workspace/research/local-inference-flexllama.md`.
