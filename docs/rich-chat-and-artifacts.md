# Rich chat + artifacts — and bringing it up on a fresh rig

This is the operational companion to
[`.spec/proposals/rich-chat-and-artifacts.md`](../.spec/proposals/rich-chat-and-artifacts.md).
It covers **what the rich-chat work added** and **exactly how to bring it up on
a new machine** — so you can pull, build, and soak in everything in one pass.

If you only read one thing: the stack comes up with `docker compose up`, but the
two showpiece capabilities (generate documents, reason over uploads) each need an
**overlay** + a **runtime image** + a **model that can drive multi-step tools**.
That last requirement is the current catch on a Gemini-only box — see
[Known rough edges](#known-rough-edges).

---

## What's new

Four arcs, all on top of the rich-docs (P3/P4) doc-extract work:

- **Arc A — chat polish.** Drag-drop a file onto the chat; links in replies + the
  doc viewer navigate (internal `doc:slug` / `wi:id`) or open (external); ⬇ exports
  a conversation (`/api/chat/export`) or a doc (`/api/studies/export`); ■ stops a
  running turn; hover a message for copy / retry / ⊕-task; type **`/`** for a
  command palette (`/task /generate /extract /import /export`).
- **Arc B — doc-build (the showpiece).** Ask for a document and the substrate
  *builds* it: a dev agent writes a generator script in the coder sandbox (now
  stocked with python-docx/pptx, openpyxl, reportlab, Pillow + pandoc +
  wkhtmltopdf), runs it, self-corrects, and exports a real **downloadable**
  pdf/xlsx/pptx/docx/zip via `coder_export_artifact`. Pipeline `doc-build`
  (`extension/50-doc-build.sql`), spawnable from chat.
- **Arc C — remote MCP.** `stewards-mcp -http-addr 127.0.0.1:8092` serves a
  **read-only** tool surface (`doc_*` + inspection) over HTTP at `/mcp` with
  bearer-token auth — point Claude Code / Codex at the substrate's knowledge.
  Local-bound first; non-loopback bind without a token is refused.
- **Arc D — chat across everything.** The empty-chat lens picker gains
  "✸ Everything (whole pool)" → search across every work item + doc.

Plus two hardening fixes from running it end-to-end (`extension/51-rich-chat-hardening.sql`):

- **Artifact-exists gate** — a doc-build that completes without exporting a file
  is flipped to `failed` (not a false "success").
- **chat → brainstorm** and **chat → /generate delegation** — the chat can now
  kick a real brainstorm (`start_brainstorm`, 12 techniques) and, asked to
  "generate a PDF," delegates to `doc-build` instead of apologizing it can't emit
  files.

Authored chain is now **00→51**; `tests/virgin-smoke.sql` asserts through OK 41.

---

## Bringing it up on a fresh rig

### 0. Prereqs
Docker + Docker Compose, and a clone of this repo. Everything below runs from the
repo root.

### 1. Build the images
The Postgres image bakes the **whole authored chain (00→51)** — a fresh clone +
build gets the gate, doc-build, everything. The two sandbox runtimes are separate
images you build once.

```bash
docker compose build                 # pg (chain 00→51) + bridge + ui + persona-host
docker build -f extension/coder-runtime.Dockerfile -t coder-runtime:latest extension   # doc-build sandbox (doc toolchain)
docker build -f extension/doc-extract.Dockerfile   -t doc-extract:latest   .           # doc-extract sandbox (upload handling)
```

### 2. Configure `.env`
Copy `.env.example` → `.env`. The key choice for a work box that **can't run a
local model**: register **Gemini** as the provider.

```bash
STEWARDS_PROVIDER_GOOGLE_GEMINI_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
STEWARDS_PROVIDER_GOOGLE_GEMINI_API_KEY=<your key>
```

> **Privacy:** an AI-Studio free key **trains on your data** — fine for public
> material, *not* for anything confidential. For work-confidential content use a
> **paid / Vertex** Gemini key (no-train), or don't route that content to Gemini.

### 3. Point the role aliases at Gemini
Pipelines and the chat dispatch by **role** (`reason`, `ingest`, `critic`,
`vision`), not a concrete model. The public defaults point at opencode; on a
Gemini-only rig, seed Gemini members at **priority 0** so they win (lower =
preferred). See [`examples/models.sql`](../examples/models.sql) for the model
catalog seed, then:

```sql
INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, notes) VALUES
  ('reason', 'google_gemini', 'gemini-3-pro-preview',  0, 'work rig: strong doer'),
  ('ingest', 'google_gemini', 'gemini-3.5-flash',      0, 'work rig: big-context doer'),
  ('critic', 'google_gemini', 'gemini-3-pro-preview',  0, 'work rig: reviewer'),
  ('vision', 'google_gemini', 'gemini-3-pro-preview',  0, 'work rig: vision (image turns)')
ON CONFLICT (alias, provider, provider_model) DO NOTHING;
```
(Full guide: [`docs/wiring-up-models.md`](wiring-up-models.md).)

### 4. Bring the stack up — with the overlay that enables docs
A plain `docker compose up -d` gives you the core + chat. To get **doc-build**
*and* **doc-extract** (uploads) *and* the **ClamAV auto-refresh**, bring it up with
the doc-extract overlay — it provides the docker socket (once) and the freshclam
sidecar, and the coder runtime rides the same socket:

```bash
docker compose -f docker-compose.yaml -f docker-compose.doc-extract.yaml up -d
```

> The docker socket is **host-root-equivalent** — read `SECURITY.md` and prefer a
> box you trust with that. If you also want repo-mode coder (`code-pr`, which
> clones), add `-f docker-compose.coder.yaml` for the `coder-worktrees` volume,
> but then delete the duplicate `bridge.volumes` socket line from one overlay
> (compose errors on a duplicate mount target). doc-build itself does **not** need
> coder-worktrees.

### 5. Register the sandbox tools
The MCP tool catalog is a grant table; after the bridge is up with new servers,
refresh it so `coder_export_artifact`, `doc_extract`, etc. are callable:

```bash
docker exec stewards-oss-bridge stewards-mcp bridge refresh-tools
```

### 6. Verify
```bash
# the authored chain is sound on a virgin boot (00→51, OK 41):
docker exec -i stewards-oss-pg psql -U stewards -d stewards -v ON_ERROR_STOP=1 < tests/virgin-smoke.sql

# the UI cockpit:
open http://127.0.0.1:8081/stewdio        # (or your PG_PORT-adjacent UI port)

# remote MCP (read-only) for other agents:
STEWARDS_MCP_HTTP_TOKEN=<token> docker exec -e STEWARDS_MCP_HTTP_TOKEN stewards-oss-bridge \
  stewards-mcp -http-addr 0.0.0.0:8092      # then `claude mcp add stewards --transport http http://HOST:8092/mcp`
```

---

## Using it
- **Generate a document:** in chat, type `/generate` (or just "generate a one-page
  PDF brief of …"). The chat spawns `doc-build`; watch the plan→build→deliver
  stages in the cockpit; the finished file comes back as a download link in the
  conversation.
- **Brainstorm:** "brainstorm ways to …" → the chat runs a brainstorm (six-hats /
  SCAMPER / TRIZ / …).
- **Reason over an upload:** drag a PDF/Office doc/zip onto the chat; it's
  extracted in the no-network sandbox and becomes subject material.
- **Chat across everything:** open a chat with no work item selected → pick
  "✸ Everything" or a project lens.
- **Export:** ⬇ on a conversation or a doc.

---

## Known rough edges

- **✅ Gemini's multi-step tool loop works** (was broken; fixed in the bgworker —
  three layered Gemini OpenAI-compat divergences: `finish_reason="stop"` with
  tool_calls, streaming tool_calls with no `index`, and the Gemini-3.x
  `thought_signature` that must round-trip). **gemini-3.1-pro drives doc-build
  end-to-end** (plan→build→deliver, real PDF). qwen's path is unchanged. Make sure
  the work rig has this commit. Note: `gemini-3-flash-preview` currently 503s
  ("high demand") — prefer **`gemini-3.1-pro-preview`** (strong, drives the loop)
  or `gemini-3.5-flash`.
- **A raw `model_override` skips alias-failover** — a 503 on a pinned model hard-
  fails the run. Prefer a role alias (with fallback members) over a concrete id.
- **Speed (local model):** doc-build is 4–10 min/doc on a local model and slower
  when runs are concurrent (one rig serializes them) — run one at a time.
- **Rich artifact cards** are deferred — generated docs come back as a download
  link, not yet an inline card.
