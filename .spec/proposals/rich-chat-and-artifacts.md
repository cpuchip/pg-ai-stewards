# Rich chat + artifacts — UX polish, document generation, remote MCP, multi-item chat

**Status:** ✅ **RATIFIED in council 2026-06-24** (`dominion_in_council` satisfied for B + C).
All four arcs approved; order **A → B → D → C**.
**Author:** agent + Michael.

**Ratified decisions:**
1. **Arc A = EVERYTHING** — drag-drop + internal hyperlinks + session export + doc
   download, PLUS the full nabbed set: stop button, hover message-actions, clickable
   source pills, slash-command palette, `@`-mentions, **artifact cards** in the bubble.
2. **Arc B = coder-sandbox generation, MODEL-IN-THE-LOOP (NOT one-shot)** — Michael's
   reframe: equip the existing coder sandbox with document tools/libraries (xlsx via
   excelize, pdf via maroto, docx/pptx, image-gen) PLUS scripting → infinite document
   output, **including zip deliverables for large corpus exports**. The user can **chat
   about the document while it builds** (iterative, like code-pr). Supports **templates
   / branding** to follow. **Requires good progress indication in the chat UI** (ties to
   Arc A artifact cards + the plan=progress panel). This supersedes the §4 "(a) in-process"
   recommendation — the sandbox + scripts + provided libs is the chosen engine.
3. **Arc C = build it, LOCAL-BOUND FIRST** — token auth + a read-only default tool
   profile, bound to localhost for now; flip to the mesh once proven. Coder/write tools
   never remote unless explicitly minted. StreamableHTTP transport.
4. **Arc D** — multi-select + "chat across all"; saved collections optional/later.
**Builds on:** Stewdio (the cockpit), rich-docs P1–P4 (doc-extract, the read side),
coder-pr (the sandbox + write spine), the llama-hub (token-auth pattern).

---

## 1. The four arcs

| Arc | One line | Council? |
|---|---|---|
| **A — chat UX polish** | drag-drop, internal hyperlinks, session export, doc download + the best-chat-UI patterns worth nabbing | No (UI polish on an existing surface, within dominion) |
| **B — document generator** | the read↔write twin of doc-extract: a work item / chat / corpus → real **PDF / xlsx / pptx / docx** (+ Gemini images) | **Yes** — new capability (the substrate emits files) |
| **C — remote MCP** | an HTTP/SSE MCP endpoint + token auth so *other people's* agents (Claude Code, Codex) point at the substrate's tools | **Yes** — new capability + a real network attack surface |
| **D — multi / all-item chat** | chat grounded across several work items, or the whole corpus, not just one | Light (a chat-grounding extension) |

## 2. What we're nabbing from the best chat UIs (research 2026-06-24)

The field has converged (Claude, ChatGPT, Cursor, opencode, v0, Raycast). The
patterns worth taking — and which we already have:

| Pattern | Have? | Arc |
|---|---|---|
| 3-zone layout (history rail / capped stream / slide-in artifact panel) | ✅ dockview | — |
| **Stop button from token 1** (cancel a running turn) | ❌ | A |
| **Message actions on hover** (copy, regenerate, branch, "start task from this") | ❌ | A |
| **Slash-command palette** (`/extract`, `/generate`, `/import`, `/task`) | ❌ | A |
| **Artifact cards in the bubble** → open in the right panel (doc/generated file) | ⚠️ panel exists, no cards | A/B |
| **Source pills / clickable citations** (provenance chips → click to open the doc) | ⚠️ chips, not clickable | A |
| **`@`-mention references** in the composer (`@work-item`, `@doc`) | ❌ | A/D |
| **Pair every answer with a concrete action** (Open / Download / Insert) | ❌ | A/B |
| Layout-reservation streaming (code fence / table commits structure early) | ⚠️ MarkdownIt | A (cheap) |

Restraint is the lesson: keep the message stream clean, power one click away. We
keep our Vue+dockview shell (CopilotKit is React + opinionated toward a sidebar
in someone else's app — we'd fight it); we borrow the *patterns*, not a framework.

## 3. Arc A — chat UX polish (no council; within dominion)

1. **Drag-and-drop** onto the chat panel → same `staged` pipeline as 📎 (a
   `dragover`/`drop` handler; ~15 lines). Documents + images + archives.
2. **Internal hyperlinks** in the chat AND the doc viewer: rewrite `[[slug]]` /
   doc-slug / `work_item:<id>` links to in-app navigation (select that doc/item
   in the cockpit) instead of dead text. External URLs already linkify; open in a
   new tab. A small MarkdownIt renderer rule + a click handler that routes
   through the Pinia store.
3. **Session export** — `GET /api/chat/export?session_id=&format=md|json` →
   download the transcript. A "⬇ export" affordance on the 💬 sidebar.
4. **Doc download** — `GET /api/docs/export?slug=&format=md` (md now; pdf/docx
   ride Arc B) + a download button in the ArtifactPanel.
5. **Nabbed patterns** (pick the set in §6): stop button, message actions,
   slash palette, artifact cards, clickable source pills, `@`-mentions.

All additive, type-checked + playwright-smoked, no new standing capability.

## 4. Arc B — document generator (dominion_in_council)

The inverse of doc-extract: take a work item's doc / a chat / a corpus and emit a
**real artifact** a human hands off — PDF, xlsx, pptx, docx — optionally with
Gemini-generated images. "We can read whatever PM/UX/CX throws at us" ↔ "we can
hand them back something polished."

**Engine options (the fork):**
- **(a) In-process Go libs** — `xuri/excelize` (xlsx, excellent), `unidoc/unioffice`
  or `nguyenthenguyen/docx` (docx/pptx), `johnfercher/maroto` or `go-pdf/fpdf`
  (pdf), pandoc-free. Fast, no sandbox; but adds deps + the generator runs
  bridge-side (trusted — it's OUR structured input, not untrusted bytes).
- **(b) The coder sandbox** — the model writes a small script that emits the file
  inside the existing hardened sandbox. Maximally flexible (any format/library),
  reuses the spine, slower, model-in-the-loop.
- **(c) A dedicated `doc-build` image** — the symmetric twin of doc-extract.
  Cleanest conceptually, heaviest to stand up.

**Recommendation:** **(a) for the structured formats** (a `doc-build-mcp` /
bridge handler: `doc_render(slug|session, format)` → md→pdf via maroto, tables→
xlsx via excelize, a docx/pptx template filler) — deterministic, fast, the input
is our own trusted markdown/data so no sandbox needed. Fall back to **(b)** for
"generate me a bespoke spreadsheet/deck" where the shape is open-ended. Defer (c).

**Gemini images:** a `generate_image(prompt)` tool (the key already works — First
Orbit used Nano-Banana) → returns an image that lands as a `chat_attachments`
row / embeds in a generated doc. Privacy: paid Gemini is private-safe; gate
`file_private` to local-only or skip images for private intents.

**Output:** files land as a downloadable artifact (`/api/docs/export?...&format=pdf`)
+ an artifact card in the chat. Optionally written to the workspace (off by
default, like the materializer).

## 5. Arc C — remote MCP (dominion_in_council; SECURITY is the spine)

Today pg-ai-stewards is a **stdio** MCP server — an agent on the *same box* can
`claude mcp add` it. To let *others'* agents (Claude Code, Codex, elsewhere)
point at it, we expose an **HTTP MCP endpoint**. The go-sdk v1.6.1 ships
`StreamableHTTPHandler` + `SSEHandler` (verified) — so this is a transport wrap,
not a rewrite.

**This is a real attack surface** — the substrate's tool surface includes coder
+ doc-extract (host-adjacent) and write tools. So the security model IS the
proposal:

- **Token auth** (the llama-hub pattern: minted bearer tokens, sha256 at rest,
  admin revoke/list). No token → no access. Non-loopback requires a token.
- **Tool profiles per token** — a token grants a *named tool profile*, default
  **read-only** (doc_search/doc_get/doc_similar/work_item_show/list/
  investigate_*). **Coder, doc-extract, and write tools are NEVER in a remote
  profile unless explicitly minted** — and even then, behind a loud opt-in.
- **Transport:** `StreamableHTTPHandler` (modern, single endpoint) as primary;
  `SSEHandler` for older clients if needed.
- **Where:** local-bound by default; over the **NetBird mesh** for trusted peers
  (the substrate's "bridge to disparate systems" role) — **not** the public
  internet. A `cmd/stewards-mcp-http` (or a flag on the bridge) + a compose
  overlay, mirroring the hub.
- **Accounting:** every remote call is logged (who/token/tool/cost) — the same
  cost/trust ledger the in-process tools use.

This is the "others point their agents at it" capability — and it's exactly where
`preside_under_121` + `dominion_in_council` bite: a new standing network surface
exposing the substrate's dominion. Ratify the scope explicitly.

## 6. Arc D — multi / all-item chat

The project lens (P3d) already chats across a *corpus*. Arc D adds:
- **Multi-select** work items/docs in the browser → a chat grounded in that *set*
  (grounding lists the members; doc_search/investigate scoped to them).
- **"Chat across everything"** — a top-level chat grounded in the whole pool
  (the existing global doc_search, framed).
- Optional: a saved **collection** (a named set of items) as a reusable lens.

Mostly grounding + a UI selection model; rides the existing `dispatch_chat_turn`
+ `target_ref` machinery (`set:<ids>` or `all`).

## 7. Decisions to ratify

1. **Arc A pattern set** — which of {stop button, message actions, slash palette,
   artifact cards, clickable source pills, @-mentions} to build now vs defer.
2. **Arc B engine** — (a) in-process Go libs [rec], (b) coder sandbox, (c)
   dedicated doc-build image. And formats for v1 (rec: **md + pdf + xlsx** first;
   docx/pptx next).
3. **Arc B images** — wire `generate_image` (Gemini) now or defer.
4. **Arc C scope + exposure** — read-only default profile [rec]; transport
   (StreamableHTTP [rec]); exposure (local + mesh, NOT public [rec]); is remote
   MCP wanted *now* or is local-stdio enough for the near term?
5. **Arc D shape** — multi-select + "all" [rec], + saved collections (now/defer).
6. **Order** — rec: **A → B → D → C** (polish first for immediate feel; doc-gen
   is the big value; multi-item is small; remote-MCP last since it's the most
   security-sensitive and benefits from the rest being stable).

## 8. Council moment — tensions + blind spots

- **Arc C is the one to slow down on.** A remote tool surface over the network is
  the highest-consequence item here; the read-only-default + token + mesh-not-
  public posture is non-negotiable. Coder/doc-extract remote = host risk.
- **Arc B trust:** doc-GEN input is OUR structured markdown/data (trusted), so it
  does NOT need the doc-extract sandbox — but if a generator ever takes
  *untrusted* templates, it inherits the doc-extract posture.
- **Scope creep:** all four at once is a lot. A → B is the high-value core; C + D
  can follow once A/B settle. Recommend gating C behind "do you actually need
  remote agents now, or is this future-proofing?"
- **CopilotKit:** correctly set aside (React; opinionated). Borrow patterns only.
- **Privacy:** Gemini images + remote MCP both touch the train-on-data / private
  boundary — keep `file_private` local and never expose private docs over a
  remote token.
