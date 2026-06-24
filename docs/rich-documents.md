# Rich documents in chat — attach a PDF/Office/zip, reason over it safely

This is the architecture + port guide for the **doc-extract** capability: how the
substrate turns an untrusted uploaded document into safe, model-readable subject
material, and how to wire it up on a new host. It is the companion to
[Anatomy of a Turn](anatomy-of-a-turn.md) and
[Wiring up MCP servers](wiring-up-mcp-servers.md).

Design rationale + the council decisions are in
[`.spec/proposals/doc-extract-sandbox.md`](../.spec/proposals/doc-extract-sandbox.md)
and `.spec/proposals/rich-docs-in-chat.md`.

## What it does

Attach a file to a Stewdio chat — an image, a PDF, an Office doc (docx/xlsx/
pptx/odt/epub), HTML/text, or a **zipped folder** — and it becomes subject
material the chat can reason over:

- **Images** go straight to a vision model (P1/P2).
- **Documents** are parsed in a hardened, no-network sandbox; only **plain text**
  (always) and **page pixels** (an additive overlay for short/visual docs) cross
  back. The text is injected into the conversation; the page images feed the
  vision model.
- **Archives/folders** are unpacked (under bomb/slip caps), every member scanned
  + extracted, and surfaced as a folder tree — or **imported** as a searchable
  project corpus (`doc_import_corpus`).
- **Spawned work** (`start_task`) inherits the chat's extracted documents as
  subject material.

The point: a malicious upload can't compromise the host. We do what Dangerzone
does for humans (render to pixels) but for a *model* — and because the text path
never executes the file, a macro-laden docx is safe to read.

## The four-layer defense

No single layer is trusted alone (proposal §5):

1. **Scan** (before any extraction): **ClamAV** signature scan (known malware) +
   a pure-Go **structural maldoc** check (PDF `/OpenAction`/`/JS`/`/Launch`,
   OOXML `vbaProject.bin` macros, legacy OLE, RTF object-update, HTML script).
   Policy: *malicious* → quarantine (never parsed); *suspicious* → flag but still
   extract (safe — layer 3); *clean* → extract. This is early-reject +
   transparency, **not** the guarantee.
2. **Contain** (the guarantee): parsing happens only inside a `--network=none`,
   `--read-only`-rootfs, cap-dropped, resource-capped container. A zero-day the
   scanner misses still can't escape or phone home.
3. **Disarm by non-execution**: extraction reads structure, it never runs the
   payload — `tabula` does not execute VBA; `pdftoppm` does not run PDF JS. Only
   pixels or plain text leave.
4. **Content-gate**: the extracted text rides the existing `compose_messages`
   prompt-injection framing; the scan verdict is surfaced to the model. Pixels
   need no gate (a bitmap carries no instructions).

## How it's put together

```
 Stewdio UI (ChatPanel.vue)
   │  📎 upload (image | pdf | office | html | txt | zip/7z/tar…)
   ▼
 stewards-ui  POST /api/chat/attach  ──►  stewards.chat_attachments (bytea, kind=document)
   │
   │  chat turn (the agent, grounded in a work item OR a project lens)
   ▼
 dispatch_chat_turn ──► bgworker tool loop ──► agent calls  doc_extract(attachment_id)
                                                   │  (MCP tool, deny-by-default; granted to work-item-chat)
                                                   ▼
                              BRIDGE: doc-extract-mcp  (cmd/doc-extract-mcp)
                                 1. reads chat_attachments.bytes  (server-side; bytes never touch the model)
                                 2. docker run --network=none --read-only --tmpfs … doc-extract:latest
                                       │   (the converter — cmd/doc-extract + internal/docextract)
                                       │   scan (clamscan + structural) → tabula text → poppler pixels
                                       ▼   JSON Result on stdout
                                 3. writes extracted_text + scan_verdict back; inserts page images (parent_id)
                                       │
                                       ▼
                 chat_attachment_parts(ids, session) assembles the 47 content_parts array:
                    document text part  +  page-image overlay  (image_url)  →  the vision/text model
```

The converter (`doc-extract`) runs **inside** the sandbox; the MCP server
(`doc-extract-mcp`) runs **on the bridge** and spawns it — the same docker-socket
trust model as the coder (the bridge holds the socket; the extract container has
none and no network).

### Components

| Piece | Where | What |
|---|---|---|
| `internal/docextract` | Go library | The deterministic converter core — structural scan, archive safe-unpack (zip-slip/bomb/symlink/count caps), tabula text, poppler pixels. **Pure-Go safety oracle:** `go test ./internal/docextract/` runs without Docker. |
| `cmd/doc-extract` | binary, in the image | Reads bytes on stdin → emits a JSON `Result` on stdout. `ENTRYPOINT` of `doc-extract:latest`. `-smoke` self-tests. |
| `cmd/doc-extract-mcp` | binary, on the bridge | The `doc_extract` + `doc_import_corpus` MCP tools. Reads/writes `chat_attachments` (pgx); spawns the hardened container (`runner/run.go` = the hardening delta). |
| `extension/doc-extract.Dockerfile` | image | Lean: Go converter + `poppler-utils` (`pdftoppm`) + ClamAV `clamscan`. The ~300 MB signature DB is NOT baked in — it rides a volume. No Python, no libreoffice. |
| `docker-compose.doc-extract.yaml` | compose overlay | `clamav-freshclam` sidecar (keeps the signature DB fresh) + the read-only `clamav-db` volume + the docker socket on the bridge. |
| `extension/49-doc-extract.sql` | SQL chain | `chat_attachments` gains `parent_id`/`scan_verdict`/`scan_findings`; `chat_attachment_parts` re-authored for the pixel overlay + a `doc_extract` nudge; the doc-extract MCP server registration + grants; `chat_task_input` (P4 carry). |

### The router (text always, pixels for short docs)

`doc_extract` extracts text for every readable doc. Page pixels are an **additive
overlay**: rendered when the doc is FORCED (`render=true`) or AUTO — a short PDF
(page count ≤ `max_pages`, default 10, probed via `pdfinfo`). A long report stays
text-only so it isn't 200 vision calls. The page count threshold is a config knob.

## Wiring it up (port to a new host)

The substrate + doc-extract run **locally** (dev box / work laptop / work VM),
not on a remote control-plane host. Steps on the target host:

```sh
# 1. Build the converter image (build context = repo root):
docker build -f extension/doc-extract.Dockerfile -t doc-extract:latest .

# 2. The bridge image already bundles doc-extract-mcp (extension/bridge.Dockerfile
#    builds it; it COPYs cmd/ + internal/). Rebuild it if you haven't:
docker compose build bridge

# 3. Bring the stack up. The capability needs the docker socket on the bridge
#    (host-root-equivalent — read SECURITY.md). Use the doc-extract overlay:
docker compose -f docker-compose.yaml -f docker-compose.doc-extract.yaml up -d
#    ⚠ If you ALSO run the coder overlay, both mount /var/run/docker.sock — pick
#    ONE overlay to provide the socket (docker errors on a duplicate mount).

# 4. Populate the ClamAV signature DB once (the freshclam sidecar then keeps it
#    fresh — startup + ~twice daily). One-shot seed:
docker run --rm -v clamav-db:/var/lib/clamav --entrypoint freshclam \
    clamav/clamav:latest --datadir=/var/lib/clamav

# 5. Teach the bridge the new tools (grant ≠ catalog):
docker exec <bridge-container> stewards-mcp bridge refresh-tools
#    → doc-extract should report: doc_extract, doc_import_corpus
```

Verify:

```sh
# the trust-floor smoke (benign + macro + EICAR + no-egress), through the real container:
bash tests/doc-extract-smoke.sh

# the pure-Go safety oracle (zip-slip / zip-bomb caps / structural scan):
GOWORK=off go test ./internal/docextract/

# the substrate surface (virgin chain 00→49):
#   build extension/Dockerfile, CREATE EXTENSION, psql -f tests/virgin-smoke.sql
```

### Config knobs (env on the bridge)

| Env | Default | Meaning |
|---|---|---|
| `DOC_EXTRACT_IMAGE` | `doc-extract:latest` | The converter image to spawn. |
| `DOC_EXTRACT_CLAMAV_VOLUME` | `clamav-db` | The signature-DB volume (mounted read-only at `/clamav`). Set empty to disable the signature scan (structural still runs). |

Archive caps (max total uncompressed 200 MB / per-entry 50 MB / 1000 entries /
200:1 ratio / no nested recursion) are `doc-extract` flags with conservative
defaults; tune in `runner/run.go` or pass through.

### Privacy

`file_private` content routes vision to the **local** model (the `vision`
alias → a local no-train model). The scan stays **air-gapped** (the container has
no network; the freshclam sidecar is the only thing that goes online, and never
while a hostile file is being parsed). Paid Vertex/Gemini is private-safe (no
train-on-data); never route private data to a train-on-data provider.

### Deferred / future

- **gVisor (`--runtime=runsc`)** — a defense-in-depth tier (Dangerzone parity).
  Skipped until a host confirms `runsc`; render-to-pixel already removes
  carry-forward, so v1 doesn't require it. It's a one-line toggle in
  `runner/run.go` when wanted.
- **libreoffice office→pixels** — v1 renders only PDF to pixels; a docx/pptx as
  pixels needs office→PDF first (libreoffice, ~600 MB). Tabula text + "convert to
  PDF for faithful layout" covers v1.
- **oletools/pdfid** — the structural check is pure-Go (option d). Add Python
  oletools/pdfid in the image for deeper maldoc analysis if the Go check proves
  too coarse.
- **Live repo checkout** — `doc_import_corpus` imports any folder; for "the
  digesters read our repos", zip a repo and import it (a repo is a folder). A
  read-only `git clone` step into the sandbox (like code-pr) is the future
  enhancement.
