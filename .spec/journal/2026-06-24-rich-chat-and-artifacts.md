# 2026-06-24 — rich chat + artifacts: Arcs A, B, D, C (plan → council → ratify → build)

Morning-after the rich-docs P3/P4 run: Michael asked a sweep of "what can we make
now?" questions (drag-drop, 7z, UI polish, multi-item chat, session/doc export,
hyperlinks, remote MCP, document generation, Gemini images). We turned it into a
ratified plan and an autonomous /goal build of all four arcs.

## The cycle

Answered each question against the real code (verified, didn't guess), wrote the
spec `.spec/proposals/rich-chat-and-artifacts.md`, surfaced the council decisions
(B + C are new standing capabilities → dominion_in_council). Michael ratified all
four — and reframed Arc B better than my recommendation: not one-shot generation
but **the coder sandbox equipped with doc libraries, model-in-the-loop, so you
chat about the document while it builds** (templates/branding, zip corpus exports).
Then: "finish a, b, d, c — push through, dave-rule, commit + test at checkpoints."

## What shipped (order A→B→D→C; commits 5236bbf→…)

- **Arc A — chat polish.** Drag-and-drop onto the chat; internal/external links
  in replies + the doc viewer (useDocLinks); session export + doc download
  (`/api/chat/export`, `/api/studies/export`); stop button (`/api/chat/stop`
  cancels the queued turn); hover message-actions (copy/retry/⊕task); a
  keyboard-navigable slash palette (/task /generate /extract /import /export).
  Deferred (additive, dave-rule): @-mentions, clickable source pills (needs
  tool-result surfacing), rich artifact cards (ride Arc B).
- **Arc B — doc-build (the showpiece).** coder-runtime gains a document toolchain
  (python-docx/pptx, openpyxl, reportlab, Pillow, markdown + pandoc + wkhtmltopdf);
  `coder_export_artifact` (coder-mcp + a DB pool) reads a generated file out of
  the sandbox → chat_attachments bytea → a download URL; `50-doc-build.sql` = the
  doc-build pipeline (plan→build→deliver), spawnable from chat via start_task /
  /generate; `chat_task_input` seeds a stable sandbox id. Delivery rides Arc A's
  clickable links.
- **Arc D — chat across everything.** The lens picker gains "✸ Everything (whole
  pool)" → `target_ref=all` → doc_search across all work items + docs.
- **Arc C — remote MCP.** `stewards-mcp -http-addr` serves a READ-ONLY surface
  (doc_* + inspection) over HTTP at /mcp with bearer-token auth, local-bound
  first. Others point Claude Code / Codex at the substrate's knowledge.

## Proof (verify-under-real-conditions)

- Arc A/D: vue-tsc + vite green; live ui — 0 console errors, the "Everything"
  lens renders, the 📎 accepts docs + zip/7z.
- Arc B: coder-runtime generated a real xlsx + **pdf (%PDF- confirmed)** + docx
  live; the generate→store→serve→download chain returned a **valid xlsx** (9
  members, [Content_Types].xml); virgin-smoke OK 40 (pipeline + grant);
  `refresh-tools` shows `coder_export_artifact` in the catalog (17 coder tools).
- Arc C: **live** — 401 without/with a wrong token; the right token handshakes;
  `tools/list` returns only doc_*/inspection/work_item read tools (zero write/
  coder/spawn); non-loopback-without-token is refused.
- Substrate: **virgin-smoke 00→50 GREEN** (OK 39 + OK 40); go build/vet across
  the module; all rebuilt images (pg/bridge/ui/coder-runtime) green.

## Gotchas

- `bridge.Dockerfile` already gained `COPY internal/` in the P3 run — coder-mcp's
  new DB import was fine.
- psql `-tAc` INSERT…RETURNING also prints the "INSERT 0 1" tag → capture the id
  with `head -1 | tr -dc '0-9'` (a polluted id broke a curl test).
- Windows curl couldn't reach 127.0.0.1:8081 (http=000) — used python urllib
  (which works) for the download proof. The MCP HTTP proof used curl fine on 8092.

## Carry-forward (non-blocking, dave-rule deferrals)

- Arc A extras: @-mentions, clickable source pills, rich artifact cards.
- Arc B: the full chat→/generate→doc-build→download e2e through a live model
  (the pieces are each proven; the model-driven orchestration is the demo step) +
  Gemini `generate_image` tool (key works, not yet wired) + faithful-layout
  office→pixels (libreoffice) tier.
- Arc C: multi-token minting (llama-hub store) + mesh exposure when wanted.
- Arc D: multi-select a specific subset + saved collections.
