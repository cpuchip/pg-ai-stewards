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

## Round 2 — fix-and-retest + the Gemini investigation (same day)

Michael: "fix up those issues and run the tests again" + later "we gotta fix
Gemini — work doesn't want us using qwen on that machine."

**Hardening (51-rich-chat-hardening.sql):**
- **Artifact-exists gate** — a BEFORE-UPDATE trigger flips a doc-build that
  completes without exporting an artifact to `failed`. Caught the worst failure
  mode live (an empty gemini run posing as "completed"). (Bug caught during apply:
  the column is `pipeline_family`, not `pipeline` — a broken trigger briefly on
  the hot work_items table, fixed immediately.)
- **chat → brainstorm** (`start_brainstorm` grant) — one message spawned 6
  techniques, all completed with real output.
- **chat → /generate delegation** — the chat said "I can't emit a PDF" instead of
  spawning doc-build; a prompt clause fixed it (proven: now calls start_task →
  doc-build → the full chat→generate→download chain closed on qwen).
- Also: stronger deliver-note handoff + per-format generation recipes (cut the
  reportlab fix-loops; work-corpus ~270s vs ~583s). freshclam AV sidecar running.

**The Gemini fix (bgworker.rs) — three layered OpenAI-compat divergences, peeled
back one e2e run at a time (each fix exposed the next):**
1. `finish_reason="stop"` *with* a complete tool_calls array (OpenAI sends
   "tool_calls"). The loop only continued on =="tool_calls" → skipped execution.
   Fix: key off the presence of tool_calls; only "length" = don't-dispatch.
2. streaming tool_call deltas with **no `index`** → two calls merged into one
   malformed name ("coder_sandbox_startdoc_get"). Fix: fall back to the per-call
   `id`.
3. Gemini-3.x **`thought_signature`** (tool_calls[].extra_content) must round-trip
   or the next turn 400s. We dropped it. Fix: capture + replay it (compose_messages
   sends m.tool_calls verbatim, so it round-trips).
   **Result: gemini-3.1-pro drives doc-build end-to-end (6 tool-turns, real PDF).
   qwen unchanged (regression-checked: still completes).** This was load-bearing —
   the work rig can't run qwen, so Gemini had to work.

**Method note:** the doc-build e2e was the oracle that surfaced every one of
these — none were visible to virgin-smoke (SQL-only) or unit tests. Tool-first +
verify-under-real-conditions earned its keep three times in one session.

**Bring-up doc:** `docs/rich-chat-and-artifacts.md` — feature summary + a full
fresh-rig runbook (images, Gemini provider, role-alias repoint, doc-extract
overlay, refresh-tools, verify) so the work copy can soak everything in.

## Round 3 — cockpit panels + cards + image gen (Michael's batch, same day)

Michael's batch: a Sessions view + windowing manager, a Models/usage panel, all 4
fast-follows, the hardening quick wins, and "generate images too." Sequenced
(his pick) gemini-image-first; shipped 4 of 6 slices, each proven live + pushed:

1. **Sessions panel + windowing** (`ebd9835`) — `GET /api/chat/sessions/all` lists
   EVERY chat (target parsed from the stored "(Context:…)" turn, titles batch-
   resolved); click reopens the exact session (store.openChat → ChatPanel watchers,
   honoringRequest guard). "▦ panels" launcher opens/reopens any pane. Closes the
   "can't get back to a session" gap. Proven: launcher → Sessions tab → click →
   chat loads its messages.
2. **Models & usage panel** (`be54cbf`) — `GET /api/models/aliases` + /api/activity:
   Running-now (N sessions/model + tokens), role aliases→members (preferred/usable),
   24h tokens+cost. Proven (reason→qwen3.6-35b-a3b…; gemini members on a gemini rig).
3. **Rich artifact cards** (`b43d1b1`) — attachment links in replies render as
   icon/filename/size/⬇ cards (?meta=1 + ?download=1 on the serve handler). Proven:
   "📕 executive_brief_counterpoint.pdf · 3 KB".
4. **generate_image** (`b4e77bd`) — Gemini Nano Banana (gemini-2.5-flash-image,
   responseModalities=IMAGE) → chat_attachment(kind=image); core stewards-mcp tool,
   OFF the read-only remote profile, granted chat+dev. Proven: real 853KB PNG
   generated + stored + served. Chat grounding now carries the agent's own session
   id so session-scoped tools attach to the right conversation.

**Gotchas:** dockview addPanel inactive-until-tab-focused (playwright must click the
tab to read content); `npm run build` overwrites dist/ → `git checkout -- dist/`
before commit; the IIFE form of playwright-cli `eval` errors (use single-expression
evals / text locators).

**Carried (teed up for a fresh pass):**
- **Alias-failover hardening** — auto-shed a 503'd model so alias dispatch fails
  over. The work_queue error row carries the provider but NOT the model, so the
  shed must live in the bgworker (Rust, hot dispatch path) where the resolved model
  is known → a pg rebuild + careful e2e. doc-build already dispatches via the
  `reason` ALIAS (which fails over to usable members); the gap is immediate shed of
  a transiently-503'd member. Best done with fresh context — hot path.
- **Chat polish:** @-mentions + Arc D subset-select (Arc D subset needs a new
  grounding mode for a chosen set, backend) + clickable source pills (needs tool-
  result surfacing in the SSE stream).
- **generate_image session-routing** — relies on the agent passing the real
  session_id (grounding nudge helps; stronger models comply better).
- **Rich artifact cards** also-surface artifacts that land silently in a chat
  session (chat→/generate spawns doc-build; the export lands without a reply link).

## Carry-forward (non-blocking, dave-rule deferrals)

- Arc A extras: @-mentions, clickable source pills, rich artifact cards.
- Arc B: the full chat→/generate→doc-build→download e2e through a live model
  (the pieces are each proven; the model-driven orchestration is the demo step) +
  Gemini `generate_image` tool (key works, not yet wired) + faithful-layout
  office→pixels (libreoffice) tier.
- Arc C: multi-token minting (llama-hub store) + mesh exposure when wanted.
- Arc D: multi-select a specific subset + saved collections.
