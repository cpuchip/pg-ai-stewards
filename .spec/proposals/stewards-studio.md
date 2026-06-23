# Stewdio — the work-item cockpit

**Status:** ✅ RATIFIED in council with Michael, 2026-06-23 (`dominion_in_council` satisfied). Execution-ready.
**Author:** agent + Michael, 2026-06-23.
**One line:** A VS Code-like cockpit ("Stewdio") in `stewards-ui` where you browse work items by project, open an artifact, and **chat with the work item** — grounded in its doc, its source corpus, and the agent sessions that built it — *and* kick off new pipelines (book study / video digest / a private work task) with live progress.

**Ratified decisions (council 2026-06-23):** (1) name **Stewdio**, route `/stewdio`, generic in OSS core · (3) **local model** for the chat · (4) **SSE from P1** (the DB-poll relay, not deferred) · (5) **Pinia** store (agent's judgment, Michael-endorsed) · (6) book-corpus gap = its own phase **P3**, not a P1 blocker · (7) order P0 shell → **P1 chat-with-a-work-item** → P2/P3/P4 · (8) **persistent chat sessions** (not work-item-per-turn).

---

## 1. The reframe: you're chatting with a work item

A finished artifact (a book study, a video digest, a research doc) is the **output of a work item**. Its doc body, the source corpus it was digested from, and the agent sessions that produced it are all **facets of that one work item**. So the unit of interaction is not "chat with a document" — it's **chat with a work item**, which can answer from any of its facets:

- *"Where does the book actually say this?"* → the **source corpus** facet.
- *"Why did you conclude the wu-wei tension?"* → the **building-sessions** facet.
- *"Summarize section 3."* → the **doc** facet.

This generalizes cleanly: any work item (book, video, research, a private task pipeline) is chattable the same way, and a *running* work item's stages are its live progress.

## 2. What the research found

- **Borrow `dockview-vue` for the shell.** [Dockview](https://dockview.dev) is a zero-dependency, MIT, VS-Code-style docking layout manager with first-class **Vue 3 bindings** — tabs, groups, split/grid views, a `Paneview` that *is* VS Code's collapsible sidebar, layout serialization. It drops into our existing Vue 3 + Vite stack without a rewrite. This is the one real "borrow."
- **Don't adopt a chat app wholesale.** LibreChat / Open WebUI / LobeChat are excellent but are their own stacks/DBs and only know "chat with an LLM" — none model our work_items / pipelines / sessions / docs. Mine them for UX patterns; build the chat panel in our app.
- **The agent-cockpit patterns match the substrate's grain.** The field converged (Cursor 3, Devin Desktop, GitHub Mission Control, Claude Code) on **editor/manager surface separation** (a scannable work-item browser *outside* the deep-dive chat) and **"plan surface = progress stream"** (the plan *becomes* the execution log, each step lighting up as the agent works). Our **pipeline stages are exactly that plan** — a work item's `stages` are the checklist, and `stage_results` membership lights them up as it runs.

## 3. Architecture — three zones

A new lazy-loaded route `/stewdio` (`Stewdio.vue`), full-bleed, built on `dockview-vue`:

```
┌─ Stewdio ───────────────────────────────────────────────────────┐
│ LEFT (Paneview)          │ CENTER (tabbed editor group)    │ RIGHT (chat) │
│ ── project filter ▼      │  [book-self-reliance] [wi 38a3…]│  model ▼     │
│ work items, by project   │                                 │  ┌─────────┐ │
│  ▸ books                 │  ARTIFACT view (doc) or         │  │ session │ │
│    • Self-Reliance  ✓    │  PLAN/PROGRESS view (stages     │  │ history │ │
│    • A Modest Prop. ⟳    │  lighting up for a running WI)  │  └─────────┘ │
│  ▸ videos                │                                 │  messages…   │
│  ▸ research              │                                 │              │
│  [+ New work ▾]          │                                 │  [ send ]    │
└──────────────────────────┴─────────────────────────────────┴──────────────┘
```

- **Left** — project-filtered work-item / doc browser (the *manager surface*). Reuses existing APIs, **zero new backend**: `GET /api/work-items/list?project_association=&status=&pipeline=`, `GET /api/projects/list`, `GET /api/studies/list?kind=`. Status glyphs from `work_items.status`.
- **Center** — tabbed viewer. A finished work item → its **doc** (`GET /api/studies/get?slug=`, render markdown as `StudyDetail.vue` already does). A running work item → its **plan/progress** (the stage checklist; reuse the maturity-ladder sub-component from `WorkItemDetail.vue`).
- **Right** — the **multi-session, model-switchable chat** (the *editor/deep-dive surface*): talks to the selected work item, keeps history, switches models (`GET /api/models/list`), and can **kick off a new pipeline** with live progress inline.

## 4. Two new backend capabilities (generic, OSS core)

### 4a. Chat with a work item — the `work-item-chat` agent + pipeline

A **1-stage tools-on pipeline** on a **new restricted agent family**, run on a **local model**. Grounding comes from (i) the work item's intent block auto-injected by `compose_system_prompt` (`09-intents-covenants.sql:257`), and (ii) retrieval tools scoped via `tool_groups`.

```sql
-- new restricted family (mirrors the subagent-doc-investigate grant shape, 15b:1883/2032)
INSERT INTO stewards.agents (family, model_match, description, mode, prompt, temperature)
VALUES ('work-item-chat','*',
  'Conversational agent: answers grounded ONLY in a work item''s doc + corpus + sessions, via retrieval tools.',
  'primary',
  $P$You answer the user's questions about a work item, grounded ONLY in what you retrieve.
Before answering: doc_get the doc, doc_search/doc_similar for related corpus, investigate_session
for the building turns, and (when a source corpus exists) search it. Quote or cite; never invent.
If the material is silent, say so plainly. You are in a chat — concise, and invite the next question.$P$,
  0.3)
ON CONFLICT (family,model_match) DO UPDATE SET prompt=EXCLUDED.prompt, active=true;

-- deny over default-allow → exactly the retrieval toolset (doc_* is broadcast-granted already, 04:1170)
INSERT INTO stewards.agent_tool_perms (agent_family, tool_pattern, action, source) VALUES
  ('work-item-chat','fetch_url','deny','manual'),
  ('work-item-chat','web_search*','deny','manual'),
  ('work-item-chat','fs_*','deny','manual'),
  ('work-item-chat','spawn_subagent','deny','manual'),
  ('work-item-chat','deep_research','deny','manual')
ON CONFLICT (agent_family,tool_pattern) DO UPDATE SET action=EXCLUDED.action;

-- 1-stage tools-on pipeline (book-curate shape, examples/book-digester.sql:420); model = LOCAL via role alias
INSERT INTO stewards.pipelines (family, description, stages, promote_to_doc, metadata)
VALUES ('work-item-chat',
  'Answer a question grounded in a work item''s doc + corpus + sessions, locally.',
  jsonb_build_array(jsonb_build_object(
    'name','answer','next',NULL,'agent_family','work-item-chat','model','reason',
    'auto_advance',true,'tools_disabled',false,
    'tool_groups',jsonb_build_array('substrate-read'),
    'input_template', E'The user asks:\n{{input.user_input}}\n\nWork item under discussion: {{input.target_ref}}\n'
      || E'Retrieve before answering (doc_get / doc_search / investigate_session); cite slugs.')),
  false, jsonb_build_object('shape','chat'))
ON CONFLICT (family) DO UPDATE SET stages=EXCLUDED.stages;
```

**Local routing** is free: `model='reason'` resolves through `model_aliases`, and the workspace overlay (`overlays/role-aliases.sql`) puts the local rig members at priority 0, so a work instance routes the whole chat to its own GPUs (no-train, private, $0). Public OSS defaults `reason` to a paid provider at priority 5; a work instance overrides via the overlay (or a `file_private` intent, or per-instance `model_override`).

**Resolving a doc → its work item → its sessions** (the resolver the chat backend runs, confirmed grounded):
1. `doc_get(slug)` → read `frontmatter`.
2. **Path B (promotion):** `frontmatter->>'work_item_id'` is the full uuid → use directly (`04-work-items.sql:1262`).
   **Path A (doc-construction):** `prefix := split_part(frontmatter->>'session','--',2)` → `SELECT id FROM work_items WHERE left(id::text,8)=prefix` (`34-doc-builder.sql:188`).
3. The building sessions = `work_items.session_ids` (text[]); the literal turns = `messages WHERE session_id = ANY(session_ids)`.

**Turn dispatch = persistent chat session (RATIFIED, decision #8).** One chat `session` per (work-item conversation), id e.g. `chat--<workitem-uuid8>--<n>` or a stable per-conversation id; each user turn = a `kind='chat'` `work_queue` dispatch against that session with the `work-item-chat` agent + the target work item's grounding in the system prompt, replies appending to the session's `messages`. This matches how substrate chat actually works, avoids a work_item row per message, and gives natural multi-turn history. It needs a **small new dispatch helper** — `work_item_dispatch_stage` is work-item-bound, so we add a lean `dispatch_chat_turn(session_id, agent_family, model_alias, grounding jsonb, user_input)` that builds the body via `dry_run_chat` (reusing the tool-scope + model-alias resolution) and enqueues the `kind='chat'` row. The reply + full transcript live in `stewards.messages` for the chat session; the SSE relay (below) streams them to the panel. Cost/trust accounting is preserved because the bgworker still does the dispatch.

### 4b. Kick off a pipeline from chat + live progress

Reuse the existing dispatch path verbatim (`new_work.go:39` → `work_item_create` + `work_item_dispatch_stage`):

```
POST /api/work-items/create { pipeline:"book-digest"|"playlist-digest"|<task>, input:{…}, intent_id, dispatch:true }
  → { id, work_queue_id, dispatched:true }
```

After the single kick-off the work item walks itself (the `handle_work_item_chat_completion` trigger auto-advances + auto-dispatches, `04-work-items.sql:673`). **Plan = progress** is rendered from two reads:
- the **plan** = `pipelines.stages` (ordered);
- the **progress** = the work item's `current_stage` + `status` + `stage_results` (a stage name present in `stage_results` ⇒ done; `== current_stage` ⇒ active; else pending).

Poll `GET /api/work-items/get?id=` on an interval (the existing `WorkItemDetail`/`Sessions` idiom) until terminal (`completed`/`failed`/`cancelled`) or `awaiting_review`.

## 5. Frontend integration — and the constraints that shape it

- **`dockview-vue`** — `npm install` + **commit `package-lock.json`** (Docker stage-1 `npm ci` hard-fails otherwise); import a dockview **dark theme** stylesheet (Tailwind v4 won't style it automatically); **lazy-load inside `Stewdio.vue`** so it stays out of the main bundle (precedent: cytoscape/markdown-it are single-view deps).
- **State: add Pinia (RATIFIED #5).** The cockpit is the first view needing shared cross-panel reactive state (selected work item, open tabs, active chat session, model choice). The app has no store today; we add **Pinia** (register in `main.ts`) with one `useStewdioStore` — clean, devtools-friendly, and it earns its keep here even though the rest of the app stays on local refs.
- **Full-bleed layout.** `App.vue` is a single hardcoded header/main/footer column with padding. Special-case on `route.name === 'stewdio'` to escape the `<main class="p-6">` chrome.
- **SSE from P1 (RATIFIED #4) — a DB-poll relay.** There is **no SSE/WebSocket precedent** in `stewards-ui` today (every "live" feature is interval polling), so this is net-new infra — but it's bounded. The substrate brokers chat through the DB (bgworker dispatches; replies land in `stewards.messages`), so the relay is **not** provider token-streaming (which would bypass cost/trust accounting); it's a server endpoint `GET /api/chat/stream?session_id=` that holds the connection, polls `messages WHERE session_id=$1 AND id > lastSeen` on a tight interval (~300–500ms), and flushes each new row as an SSE `data:` frame via `http.Flusher` until the turn completes or `r.Context().Done()`. The panel consumes it with `new EventSource(...)`. **P1 verification gate:** confirm Vite's dev proxy passes SSE through un-buffered (a known gotcha), and that the Go server (no `WriteTimeout` set in `main.go`) doesn't kill the long-lived response. (The llama-chip loader UI already ships an SSE streaming chat — a working same-shop pattern to mirror.)
- **`go:embed` stub.** A bare local `go build` embeds the committed stub `index.html`; always `npm run build` first (or build via `extension/ui.Dockerfile`). Adding a view doesn't change this.
- **API + route ceremony is light:** a new `api/chat.go` with `func (d *Deps) registerChat(mux)` + one line in `api.Register`; a lazy import + one route in `router.ts`; a nav link in `App.vue`. New endpoints stay thin wrappers over `stewards.*` SQL functions (the `new_work.go` pattern) so cost/trust/gate accounting is preserved.

## 6. Design finding — the book source-corpus gap (a prerequisite for one layer)

The "chat with the source corpus" facet is **not uniform across digesters today**:

- **YouTube: works now.** `yt_transcripts` / `yt_transcript_segments` (keyed by `video_id`) are durable, and the published doc's frontmatter carries `video_id` → a clean join to the segments. The corpus facet is live.
- **Books: the link is missing.** The book text is fetched at build time, lives only transiently in that run's `messages`, and is discarded; the finished `book-<slug>` doc keeps only `book_slug/title/author` in frontmatter — no URL, no corpus id, no chunk rows. So a book-study chat can ground on the **doc** + **sessions** + **citations** today, but **not on the book's own passages**.

**Resolution (phased):** to give books the same corpus facet as video, add a persisted book corpus mirroring the YT pattern — a `book_text` / `book_chunks` table keyed by `book_slug` (embedded for semantic search) + a durable frontmatter backlink — and a backfill/ongoing-persist step in the book digester. This is its own phase (P3 below); P1/P2 ship the doc+sessions+citations facets (which work for *all* digesters now), and video gets the corpus facet immediately.

## 7. Privacy

- **Local model** for the chat (role alias → local rig in a work instance; or a `file_private` intent forces no-train members).
- **The private wall** (`sessions.private`, `27-context-search.sql`) is enforced *only* inside `context_search(scope=descendants)` — not by `expand_message` / `investigate_session` / `work_item_show`. So the sessions facet should be scoped to **the target work item's own `session_ids`** (its own sessions — no wall question), and any *descendant/sub-agent* reach must go through `context_search` run as a building session so the wall is honored. A `file_private` work item's chat stays local end to end.

## 8. Where it lands

- **OSS core (public, generic, no client names):** `Stewdio.vue` + `dockview-vue` + the `work-item-chat` agent/pipeline + the (optional) chat SSE relay — all in `cmd/stewards-ui` and an `examples/work-item-chat.sql` (or a core subsystem file). Demo on a book study + a video digest.
- **Work instance (private overlay):** the local role-alias routing already exists in the overlay; the book-corpus backfill + any task-specific pipelines stay private. Michael pulls the OSS feature into his work instance; the overlay supplies local routing.

## 9. Phases

- **P0 — dockview-vue shell.** Add the dep (+lockfile), `Stewdio.vue` with the 3-zone dockview layout (left browser / center placeholder / right placeholder), full-bleed route, nav link. Oracle: builds, renders, panels resize; existing routes unaffected.
- **P1 — chat with a work item (doc + sessions + citations).** The `work-item-chat` agent family + tool grants + the `dispatch_chat_turn` helper; `POST /api/chat/send` + the `GET /api/chat/stream` **SSE relay**; right-panel chat wired to the selected work item; left browser + center artifact view live. **Demo: open a book study, ask "why did you conclude X" → grounded answer streamed from the building sessions; "summarize section 3" → from the doc.** Verify against the substrate (work instance, local model). This is the thin slice to feel first.
- **P2 — kick off pipelines from chat + live progress.** Chat can launch `book-digest`/`playlist-digest`/a task pipeline; center panel shows plan=progress (stages lighting up) by polling. Demo: kick off a book study from chat, watch stages advance.
- **P3 — book source corpus.** `book_text`/`book_chunks` + backlink + backfill, so the book-study chat grounds on actual passages (video already has this). Demo: "where does the book say this?" returns a real quote with location.
- **P4 — polish.** Model-switcher per session; layout serialization (dockview `toJSON`/`fromJSON` to localStorage); multi-session chat history sidebar; per-message provenance chips (which facet a claim came from). (SSE moved to P1 per decision #4.)

## 10. Decisions — ✅ RATIFIED (council 2026-06-23)

1. **Name + scope:** **Stewdio**, route `/stewdio`, generic in OSS core. ✅
2. **`dockview-vue`** as the layout dep. ✅
3. **Local model** for the chat (role alias → rig). ✅ — the public-OSS example defaults `reason` to a paid provider at pri 5; a work instance routes local via the existing overlay.
4. **SSE from P1** (the DB-poll relay), not polling-first. ✅
5. **Pinia** store (agent's judgment, Michael-endorsed). ✅
6. **Book-corpus gap = phase P3**, not a P1 blocker — P1/P2 ship the universally-available facets (doc + sessions + citations; video gets corpus in P1). ✅
7. **Order:** P0 shell → **P1 chat-with-a-work-item** → P2/P3/P4. ✅
8. **Persistent chat sessions** (not work-item-per-turn); add a lean `dispatch_chat_turn` helper. ✅
