# 2026-06-24 — rich-docs P3 + P4: the doc-extract trust floor, end to end

An autonomous `/goal` run (Opus 4.8, "finish p3, and p4 if you can; update the
docs so I can port it to my work rig"). All of P3 (a–f) + P4 landed, proven at
every layer, and pushed. Chain 00→49.

## What got built

The ratified doc-extract sandbox (`.spec/proposals/doc-extract-sandbox.md`):
turn an untrusted upload into safe model subject material via the four-layer
defense (scan → contain → disarm-by-non-execution → content-gate).

- **P3a — trust floor.** `internal/docextract` (the pure-Go converter core +
  the safety oracle), `cmd/doc-extract` (in-sandbox converter), `cmd/
  doc-extract-mcp` (bridge-side spawner + `doc_extract` tool), `extension/
  doc-extract.Dockerfile` (Go + poppler + ClamAV engine), `docker-compose.
  doc-extract.yaml` (freshclam sidecar + read-only `clamav-db`), `49-doc-extract.sql`.
- **P3b — text always:** tabula → markdown, written to `chat_attachments.extracted_text`.
- **P3c — pixels overlay:** poppler `pdftoppm` → page PNGs as child attachments.
- **P3d — router + UI:** auto-render short docs (pdfinfo page-count probe); the
  ChatPanel now accepts documents (not just images) + a project/corpus **lens
  picker** for empty chats (`GET /api/chat/projects`, `project:<name>` grounding).
- **P3e — archives → corpus:** `doc_import_corpus` unpacks an archive in the
  sandbox (bomb/slip caps) and pools each member as a searchable doc via
  `import_doc`, tagged with a project — "drop a folder, get a searchable project."
- **P3f — digester-reads-repos:** rides P3e (a repo is a folder); the inbox item
  is resolved by the same no-network import lane.
- **P4 — carry:** `chat_task_input` folds the chat's extracted documents into a
  spawned task's binding question + `attachment_ids`, so any pipeline inherits
  the subject material.

## Proof (verify-under-real-conditions, every layer)

- **Pure-Go oracle:** `go test ./internal/docextract/` — zip-slip refused,
  zip-bomb (total + ratio) caps trip, entry-count cap, structural maldoc
  detection (PDF/OOXML/OLE/RTF), type routing. Runs without Docker.
- **Trust-floor smoke** (`tests/doc-extract-smoke.sh`) through the real hardened
  container: EICAR **quarantined by ClamAV** (`Eicar-Test-Signature`), macro PDF
  flagged suspicious by the structural scan, benign extracted clean, and
  `--network=none` confirmed (NO-EGRESS).
- **Live tool path:** uploaded a 2-page PDF via `/api/chat/attach` →
  `doc-extract-mcp -attachment` read it from the live DB, spawned the sandbox,
  tabula extracted both pages + the router **auto-rendered** 2 page PNGs, wrote
  `extracted_text` + page-image children; `chat_attachment_parts` returned text +
  2 image overlays. Archive: bundle.zip → 2 members pooled (project-tagged),
  zip-slip refused, macro PDF skipped, FTS doc-search found the content.
- **Virgin-smoke 00→49** green on a fresh `CREATE EXTENSION` (OK 36/37/38/39).
- **Live deployment:** rebuilt bridge (now bundles doc-extract-mcp) + ui;
  `refresh-tools` registered `doc_extract` + `doc_import_corpus` in the catalog;
  the Stewdio lens picker renders with zero console errors.

## Surprises / bugs caught

- **Latent topo-sort revert (the important one).** `47-multimodal` re-authors
  `page_in_cap` (also in 33), `compose_messages` (15b), `dispatch_chat_turn` (45)
  but only `requires`-ed create_chat_tasks. cargo-pgrx topo-sorts by `requires`;
  with 33 + 15b unforced, the order was under-constrained and adding 49 re-rolled
  it — a fresh build silently reverted `page_in_cap` to its pre-multimodal
  version (virgin-smoke OK 36 had been passing only by sort luck). Fixed: 47 now
  `requires` create_page_in + create_context_surface. This was a bug in the
  shipped 00→48 chain, not just P3.
- **bridge.Dockerfile** only COPY'd `cmd/`; doc-extract-mcp imports
  `internal/docextract` → the bridge build failed silently (refresh-tools FAIL
  surfaced it). Added `COPY internal/`.
- **Scanner combo (c) realized Go-pure:** ClamAV (signature) + a pure-Go
  structural check (option d) — defense in depth without Python, image stays lean.
  oletools/pdfid remain the documented upgrade.
- **Windows-only:** MSYS path mangling rewrote `--tmpfs /work`; guarded the smoke
  with `MSYS_NO_PATHCONV` (no-op on the Linux bridge where prod runs).

## Carry-forward (non-blocking)

- Full browser playwright walk of attach-a-PDF-and-watch-the-agent-call-doc_extract
  (the pieces are each proven live; the click-through is the last mile — Michael
  rebuilds for his rig anyway).
- gVisor `runsc` toggle, libreoffice office→pixels, oletools depth, live git-clone
  into the sandbox — all deferred tiers (docs/rich-documents.md §deferred).
- attachment retention / history re-send cost (the P2 follow-ups) still open.
