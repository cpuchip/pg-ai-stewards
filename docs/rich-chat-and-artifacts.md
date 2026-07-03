# Bringing the substrate up on a fresh rig (+ what rich chat / artifacts added)

The operational companion to the rich-chat/artifacts work — **what it added** and
**exactly how to bring the whole stack up on a new machine** so you can pull,
build, and soak it in one pass. This is the canonical fresh-rig / work-box guide.

If you only read one thing: the stack comes up with `docker compose up`, but the
showpiece capabilities (generate documents, reason over uploads) need their
**overlays**, and the two sandbox capabilities need a host **docker socket** that
the overlays mount into the bridge. **Bring it up — and recreate it — with the
overlay `-f` flags, every time** (see the callout in step 4). On a work box that
can't run a local model, register **Vertex Gemini (no-train)** as the provider.

---

## What's new (since the doc-extract / rich-docs P3·P4 base)

- **doc-build (the showpiece).** Ask for a document and the substrate *builds* it:
  a dev agent writes a generator script in the coder sandbox (stocked with
  python-docx/pptx, openpyxl, reportlab, Pillow + pandoc + wkhtmltopdf), runs it,
  self-corrects, and exports a real **downloadable** pdf/xlsx/pptx/docx/zip via
  `coder_export_artifact`. Pipeline `doc-build` (`extension/50-doc-build.sql`),
  spawnable from chat (`/generate`).
- **Artifact-exists gate** (`51`) — a doc-build that completes without exporting a
  file is flipped to `failed`, never a false "success."
- **Dispatcher-owned session_id** (`52`) — `generate_image` attaches to the chat
  it runs in even when the model fumbles the session id (the dispatcher overrides
  it). `coder_export_artifact` is deliberately *excluded* — it routes its export
  to the spawning chat via the pipeline template, on purpose.
- **The Stewdio cockpit** (`/stewdio`): chat-with-a-work-item, a **Sessions** panel
  that groups chats hierarchically under their project/work-item/doc (collapsible),
  **live work-item cards** that walk a spawned pipeline plan→build→deliver in chat,
  a **Models & usage** panel, **rich artifact cards** (downloads render as cards),
  a grounding picker that defaults to the open doc, VS-Code-style **edge collapse
  rails**, and `generate_image` (Gemini Nano Banana).
- **Brainstorm + delegation from chat** — "brainstorm ways to…" runs a real
  brainstorm; "generate a PDF of…" delegates to `doc-build`.
- **Chat across everything** — the empty-chat lens picker has "✸ Everything (whole
  pool)" and per-project corpora.
- **Native Vertex Gemini (no-train)** — a `google_sa` provider auth mode mints a
  service-account OAuth token in the bridge, so Gemini drives the agentic tool
  loop directly (no proxy) on the work-confidential, no-train path.
- **In-loop retry/backoff** — a transient `429/503` mid-tool-loop is retried with
  backoff instead of failing the stage (tunable `STEWARDS_HTTP_RETRY_MAX` /
  `STEWARDS_HTTP_RETRY_BASE_MS`).

Authored chain is now **00→86**; `tests/virgin-smoke.sql` asserts through **OK 88**.

---

## Bringing it up on a fresh rig

Everything runs from the repo root. `STEWARDS_PG_CONTAINER`/container names assume
the compose project `pg-ai-stewards-oss` (containers `stewards-oss-pg` etc.).

### 1. Build the images
The Postgres image bakes the **whole authored chain (00→86)** — a fresh clone +
build gets the gate, doc-build, everything. The two sandbox runtimes are separate
images you build once.

```bash
docker compose build                 # pg (chain 00→86) + bridge + ui + persona-host
docker build -f extension/coder-runtime.Dockerfile -t coder-runtime:latest extension   # doc-build sandbox (doc toolchain)
docker build -f extension/doc-extract.Dockerfile   -t doc-extract:latest   .           # doc-extract sandbox (upload handling)
```

### 2. Configure `.env` — the provider
Copy `.env.example` → `.env`. For a work box that **can't run a local model**,
choose ONE Gemini path:

**A. Vertex service account — NO-TRAIN, work-confidential (recommended for work).**
A paid Vertex SA does not train on your data and authenticates with a rotating
OAuth token (minted in the bridge by `gcp_sa.rs` — the SA key never enters env).
Set the provider + drop the SA json on the host:

```bash
STEWARDS_PROVIDER_GOOGLE_VERTEX_KIND=openai
STEWARDS_PROVIDER_GOOGLE_VERTEX_BASE_URL=https://aiplatform.googleapis.com/v1/projects/<PROJECT>/locations/global/endpoints/openapi
STEWARDS_PROVIDER_GOOGLE_VERTEX_AUTH=google_sa
STEWARDS_PROVIDER_GOOGLE_VERTEX_CREDENTIALS_FILE=/secrets/gemini-sa.json
STEWARDS_PROVIDER_GOOGLE_VERTEX_DEFAULT_MODEL=google/gemini-3.1-pro-preview
GEMINI_SA_FILE=/host/path/to/gemini-sa.json     # mounted read-only into pg by the gemini-vertex overlay
```
Model ids carry the **`google/`** publisher prefix. The provider name is
`google_vertex`.

**B. AI-Studio key — TRAINS on your data (public material only).**
```bash
STEWARDS_PROVIDER_GOOGLE_GEMINI_BASE_URL=https://generativelanguage.googleapis.com/v1beta/openai
STEWARDS_PROVIDER_GOOGLE_GEMINI_API_KEY=<your key>
```
> ⚠ An AI-Studio free key **trains on your data** — fine for public content, *not*
> for anything confidential. Use path A for work-confidential material.

(Full provider guide: [`docs/wiring-up-models.md`](wiring-up-models.md).)

### 3. Point the role aliases at your provider
Pipelines and chat dispatch by **role** (`reason`, `ingest`, `critic`, `vision`),
not a concrete model. The public defaults point at opencode; seed your provider's
members at **priority 0** so they win (lower = preferred). For Vertex (path A):

```sql
INSERT INTO stewards.model_aliases (alias, provider, provider_model, priority, notes) VALUES
  ('reason', 'google_vertex', 'google/gemini-3.1-pro-preview', 0, 'work rig: strong doer'),
  ('ingest', 'google_vertex', 'google/gemini-3.5-flash',       0, 'work rig: big-context doer'),
  ('critic', 'google_vertex', 'google/gemini-3.1-pro-preview', 0, 'work rig: reviewer'),
  ('vision', 'google_vertex', 'google/gemini-3.1-pro-preview', 0, 'work rig: vision (image turns)')
ON CONFLICT (alias, provider, provider_model) DO NOTHING;
```
(For path B use provider `google_gemini` and bare model ids, e.g. `gemini-3.5-flash`.)

### 4. Bring the stack up — WITH the overlays
A plain `docker compose up -d` gives the core + chat. For **doc-build**,
**doc-extract** (uploads + ClamAV), and the **Vertex SA** key mount, bring it up
with their overlays:

```bash
docker compose \
  -f docker-compose.yaml \
  -f docker-compose.coder.yaml \
  -f docker-compose.doc-extract.yaml \
  -f docker-compose.gemini-vertex.yaml \
  up -d
```

> **⚠ The overlay flags are load-bearing — and they matter on RECREATE too.** The
> coder + doc-extract overlays mount the host `/var/run/docker.sock` into the
> bridge so the sandbox tools can spawn sibling containers. If you later recreate
> a service with fewer `-f` flags (e.g. `docker compose up -d --force-recreate
> bridge` after a rebuild), the bridge **silently loses the socket** and
> doc-build/doc-extract fail with `Cannot connect to the Docker daemon`.
>
> The socket is **host-root-equivalent** (read `SECURITY.md`), so it is
> deliberately **not** in the base `docker-compose.yaml` — a stranger's first
> `docker compose up` must not silently grant that trust. Once *you've* decided
> to opt in, though, "remember the same `-f` flags forever" is a standing trap.
> Fix it once, durably: set `COMPOSE_FILE` in your `.env` (see
> `.env.example`) to the exact set of files you want —
> ```bash
> COMPOSE_FILE=docker-compose.yaml:docker-compose.coder.yaml:docker-compose.doc-extract.yaml:docker-compose.gemini-vertex.yaml
> ```
> — and every subsequent `docker compose up -d` / `--force-recreate`, with
> **zero `-f` flags**, includes exactly those files. The overlay can no longer
> be dropped by a forgotten flag, because there's no flag left to forget. (A
> shell alias works too if you'd rather keep `.env` free of compose config:
> `alias stew='docker compose -f docker-compose.yaml -f docker-compose.coder.yaml -f docker-compose.doc-extract.yaml -f docker-compose.gemini-vertex.yaml'`.)
> If compose complains about a duplicate `/var/run/docker.sock` mount, comment
> out the socket line in ONE of the coder / doc-extract overlays (either
> provides it). doc-build does not need `coder-worktrees`; only `code-pr`
> (repo cloning) does.

### 5. Register the sandbox + image tools
The MCP tool catalog is a grant table; after the bridge is up, refresh it so
`coder_export_artifact`, `doc_extract`, `generate_image`, etc. are callable:

```bash
docker exec stewards-oss-bridge stewards-mcp bridge refresh-tools
```

### 6. Backfill the book corpus (so chats can quote the library)
The book studies ship as docs, but their SOURCE text (for `book_search` verbatim
quoting) is gitignored DB data — empty on a fresh deploy. Repopulate it:

```bash
STEWARDS_PG_CONTAINER=stewards-oss-pg python examples/backfill-book-corpus.py
```
Idempotent; fetches each public-domain source and persists `book_text`/`book_chunks`.

### 7. Verify
```bash
# the authored chain is sound on a virgin boot (00→86, through OK 88):
docker exec -i stewards-oss-pg psql -U stewards -d stewards -v ON_ERROR_STOP=1 < tests/virgin-smoke.sql

# providers loaded (the startup log shows auth=google_sa for Vertex, no key material):
docker logs stewards-oss-pg 2>&1 | grep "stewards:   provider"

# the UI cockpit:
open http://127.0.0.1:8081/stewdio        # (or your PG_PORT-adjacent UI port)

# remote MCP (read-only) for other agents:
STEWARDS_MCP_HTTP_TOKEN=<token> docker exec -e STEWARDS_MCP_HTTP_TOKEN stewards-oss-bridge \
  stewards-mcp -http-addr 0.0.0.0:8092      # then `claude mcp add stewards --transport http http://HOST:8092/mcp`
```

---

## Using it
- **Generate a document:** `/generate` (or "generate a one-page PDF brief of …").
  The chat spawns `doc-build`; the cockpit shows a live card walking
  plan→build→deliver; the file comes back as a download card in the conversation.
- **Brainstorm:** "brainstorm ways to …" → six-hats / SCAMPER / TRIZ / …
- **Reason over an upload:** drag a PDF/Office doc/zip onto the chat → extracted in
  the no-network sandbox → subject material.
- **Quote a book:** ask about a digested book; `book_search` returns verbatim
  passages from the backfilled corpus (and refuses paraphrases).
- **Sessions:** the Sessions panel groups every chat under its project; reopen any.
- **Collapse a column:** the `❮` / `❯` edge rails collapse the leftmost / rightmost
  panel (dock Sessions on the left and the left rail collapses it).

---

## Known rough edges
- **Vertex preview-model 429s.** `gemini-3.1-pro-preview` is a low-RPM preview and
  can `429 Resource exhausted` mid-run; the in-loop retry/backoff absorbs transient
  blips, and a higher-RPM model (`gemini-3.5-flash`) completes more reliably. The
  `reason` *alias* (with fallback members) is more robust than a pinned
  `model_override` (which skips alias-failover; a hard 503 fails the run).
- **coder_read of a generated binary can wedge the loop** (known, fix pending): a
  tool result containing a null byte fails the bridge's jsonb result-write
  (SQLSTATE 22P05) and the tool_dispatch hangs until the reaper. Avoid asking the
  agent to `coder_read` a generated binary; export it directly. (Tracked.)
- **Speed (local model):** doc-build is several minutes/doc and slower when runs
  are concurrent (one rig serializes them) — run one at a time.
- **Gemini multi-step tool loop** is fixed (the bgworker handles
  `finish_reason="stop"`-with-tool_calls, missing streaming `index`, and the
  Gemini-3.x `thought_signature` round-trip) — make sure the work rig has that
  commit (it's in the chain you're cloning).
