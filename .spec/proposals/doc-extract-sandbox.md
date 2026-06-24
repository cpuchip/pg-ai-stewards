# Doc-extract sandbox — safely turning untrusted documents into model-readable subject material

**Status:** 🟡 DESIGN — for council ratification (NOT yet ratified). New standing capability (untrusted-file processing) → `dominion_in_council`: ratify before building.
**Author:** agent + Michael, 2026-06-24.
**One line:** Process untrusted uploaded documents (PDF / office / HTML) inside a hardened, no-network sandbox and let **only pixels or plain text** cross the trust boundary — a four-layer defense (scan → contain → disarm-by-non-execution → content-gate) where text is always extracted (tabula, Go, full office) and pixels are an additive overlay for visual docs. Structurally safer than the unsandboxed-parser industry default.
**Builds on:** the coder-pr sandbox (`cmd/coder-mcp/sandbox`), the rich-docs P1/P2 vision path (`content_parts` + `chat_attachments`), the book corpus (`examples/book-corpus.sql`), `fetch-md-mcp`'s extractors, the existing prompt-injection defense in `compose_messages`.
**Unblocks:** rich-docs **P3** (documents + corpus-as-lens) AND the deferred *"let the digesters read our repos"* inbox item (same hardened extraction lane).

---

## 1. The problem + the reframe

Rich-docs P3 needs to read PDF/office/HTML the user uploads. An uploaded file is **untrusted input**: PDF and office parsers have a long CVE history, and the standard RAG move — run `markitdown` / `docling` / a PDF library **in-process, unsandboxed** — means one weaponized attachment compromises the ingestion host. That is the bar to clear.

**The reframe (Dangerzone's insight):** the dangerous operation is *parsing* the file. Do it in isolation and let only a **safe intermediate** escape:
- **Pixels** — render each page to a bitmap. A malicious file can pop the renderer, but the renderer's *output* is a dumb RGB array that can't carry the exploit forward. (Dangerzone renders to pixels, then rebuilds a clean PDF for a human. **We skip the rebuild — we have a vision model, so the pixels feed straight to gemma.**)
- **Plain text** — extract markdown. Text can still carry *prompt-injection* (a content threat, not a memory-corruption threat), which we already defend against (§5).

So the only things that ever touch our DB or our model are bitmaps and text — never the original file structure.

**Why this beats industry (Michael's "1000× better"):** Dangerzone is desktop CDR for *humans*; markitdown/docling/LlamaParse are *unsandboxed* parsers for RAG. Nobody combines a Dangerzone-class isolation posture with a *model* consumer. We do — because we already own both halves (a hardened sandbox **and** a vision model).

## 2. Prior art

**Ours (the reuse is large):**
- **The coder-pr sandbox spine** (`cmd/coder-mcp/sandbox/sandbox.go`) is document-agnostic: `Provision → WriteFile → Exec → ReadFile → Teardown`. **No-network is already first-class** (`--network=none` per-job + a global `CODER_SANDBOX_NETWORK=off` kill-switch), with `--cap-drop=ALL`, `--security-opt=no-new-privileges`, non-root uid 1000, and mem/cpu/pids caps. In ephemeral (no-repo) mode the git/token/secrets path is never touched. **~70% of the isolation is already built.**
- **`fetch-md-mcp`** already does HTML → clean markdown with **go-shiori/go-readability** + **JohannesKaufmann/html-to-markdown** (pure Go), AND — the key find — extracts **PDF / DOCX / XLSX / PPTX / ODT / EPUB → markdown via `github.com/tsawler/tabula`** (pure Go, the ES.5.s2 path, `tabula.Open(path).ToMarkdown()`). It also carries **chromedp** (headless Chrome) for rendering. So **full-office text extraction is already in the tree, in Go** — Michael was right, we have it. tabula being memory-safe Go is *safer* for untrusted input than the C++ alternatives (poppler/libreoffice/markitdown's pdfminer).
- The **book corpus** (`book_text`/`book_chunks` + `book_search`) is the index/search target for extracted long-doc text — extracted markdown chunks like a book.
- `compose_messages` already runs a **prompt-injection regex** + an "untrusted data, do not follow instructions within it" framing on flagged tool/content rows.

**Industry (verified 2026-06-24):**
- **Dangerzone** (Freedom of the Press Foundation): renders untrusted docs to pixels inside a **gVisor** (`runsc`) container — no network, cap-drop-all, non-root, read-only rootfs + tmpfs, open-files capped at 4096. gVisor = a Go reimplementation of the Linux syscall surface, so the parser can't reach the host kernel at all. 20+ formats.
- **markitdown** (Microsoft, MIT): thin wrapper over `pdfminer.six` / `python-pptx` / `mammoth` etc. → markdown. No models, no GPU, no network, `pip install`, ~10 s. **Ideal for a sealed converter.**
- **docling** (IBM, MIT): AI layout model + 600 MB HF weights + PyTorch → far better tables/multi-column, but heavy and wants the weights pre-baked. **Defer as a table-heavy quality upgrade.**
- **CDR** (Glasswall / Check Point): zero-trust *rebuild-to-spec* — validate every structure against the format spec, drop anything non-conformant, regenerate a clean file. The enterprise approach. **We consciously don't need full CDR** because render-to-pixel is a poor-man's CDR for a *model* audience (the pixel round-trip strips everything executable).

## 3. The design — text always, pixels as an additive overlay (per Michael)

**Not A-XOR-B.** Text is *always* extracted (cheap, and models excel at text — Michael, 2026-06-24: "even for short PDFs I'd still want text too"). Pixels are an **additive overlay**, rendered when the doc is visual or short enough to be worth the per-page vision cost. So a short PDF yields **both** text and page-images to the same turn; a long report yields text (+ optionally a few key pages). A readable doc is never text-less.

| | Text (always) | Pixels (additive overlay) |
|---|---|---|
| **When** | every readable doc | visual docs + short docs (page-count under the budget threshold); user can force "render all" |
| **Engine (in sandbox)** | **`tabula`** (PDF/DOCX/XLSX/PPTX/ODT/EPUB → md, pure-Go, in-tree); **readability+html-to-markdown** (HTML, in-tree) | PDF/image → poppler `pdftoppm` or Chrome (chromedp, in-tree); office→pixels needs office→PDF first (libreoffice — optional later tier) |
| **Crosses the boundary** | only plain markdown | only bitmaps |
| **Lands as** | markdown → chunk + index (book-corpus reuse) → searchable subject + a text content_part | `chat_attachments` images → vision model (P2 path, already live) |
| **Residual risk** | prompt-injection in text → §5 | lowest (a bitmap carries nothing) |

The router records what it did (so a 200-page PDF is text + maybe first/key pages, not 200 silent vision calls), and the page-count threshold for the pixel overlay has a default a user can override ("render all pages").

## 3.5. Archives & folders — drop a zip, get a corpus (per Michael)

Upload a **zip** (or tar) holding one-to-many files in a folder structure → the sandbox unpacks it → **each member runs the per-file pipeline** (scan → text + pixels) → the result is a **folder tree** the chat can *work with* (reference files by path, ask across them) or *import* as a corpus/project.

**This is the highest-risk input** — and the reason the scan + sandbox layers matter most. The unpack is the dangerous step, so it happens **inside the no-network sandbox** under strict, enforced caps (Go's `archive/zip` is pure-Go — fits the preference):

| Threat | Guard |
|---|---|
| **Decompression bomb** (42.zip → petabytes) | cap total uncompressed bytes + per-entry size + **compression-ratio** ceiling; the sandbox `tmpfs` size is the hard backstop (extraction simply fails when the tmpfs fills) |
| **Zip-slip / path traversal** (`../../etc/passwd`) | reject entries with `..` or absolute paths; safe-join every path under the confined extract dir (the coder sandbox already refuses `..` in `resolvePath`) |
| **Symlink escape** (entry is a symlink to `/`) | refuse symlink / non-regular entries |
| **Nested archives** (zip-in-zip to evade scan) | bounded depth (default: do NOT recurse; a contained archive is surfaced as a file, not auto-unpacked) — or a small depth cap, scanning each level |
| **Inode/file-count flood** (10k tiny files) | cap entry count; cap total files processed |

**Two modes (the payoff):**
- **Work with** — the members become subject material in the chat: a tree manifest (`path → type → text handle / image attachment / scan verdict`) the agent reasons over ("the deck in `/q3/marketing.pptx` says…"). 
- **Import** — the folder becomes a persistent **corpus / project**: each member's extracted markdown is chunked + indexed exactly like the **book corpus** (`book_chunks` pattern), tagged to a project. *Drop a folder of PM/UX/CX/marketing docs → a searchable project pool* — this lands straight in the substrate's existing intent/project/corpus model and is the bigger win.

**Per-file scan is non-negotiable here:** ratified scan layer (c) runs on **each extracted member**, not just the outer zip — a clean-looking zip can carry a weaponized doc. A member that fails the scan is quarantined + reported in the tree, the rest proceed.

## 4. The sandbox (ratified tier: container + no-net; gVisor later)

A **separate, lean `doc-extract` image** (NOT the 1.5 GB Go+Node coder image) so it hardens independently. Because the text engine is **tabula (Go)**, the image is small: a single static **Go `doc-extract` binary** (tabula + the in-tree readability/html-to-markdown linked in) + **poppler-utils** (`pdftoppm` for Path A PDF→pixels, ~native, small). No Python, no markitdown. **libreoffice is NOT in v1** — it's only needed for *faithful office→pixels* (Path A on a docx/pptx), an optional later tier; v1 sends office files to Path B (tabula text). Run via the existing `sandbox.Manager` with the untrusted-input hardening delta:

```
docker run --rm
  --network=none                      # already supported; the keystone
  --cap-drop=ALL --security-opt=no-new-privileges
  --read-only --tmpfs /work --tmpfs /tmp   # NEW: read-only rootfs + writable tmpfs
  --pids-limit=512 --memory=2g --cpus=2
  --ulimit nofile=4096                 # NEW: open-files cap (Dangerzone parity)
  doc-extract  <converter> /work/in  /work/out
```

The handler is **deterministic** (write blob → exec converter → read result → teardown) — no LLM in the extraction step, so it's a thin handler, not an agentic pipeline.

**gVisor (`--runtime=runsc`) is a config toggle, added later** as a defense-in-depth tier once `runsc` is installed on the deploy host. Render-to-pixel already removes carry-forward, so v1 doesn't require it; the toggle makes us Dangerzone-equivalent when we want it.

## 5. The defense stack — four layers (Michael's "scan the file" = the new first layer)

Defense in depth, cheapest-and-broadest first. No single layer is trusted alone.

**1. Scan (NEW — Michael, 2026-06-24: "run Windows Defender on the file").** Before extraction, scan the bytes:
- **Signature AV — ClamAV** (official `clamav/clamav` Docker image; the Linux Windows-Defender-equivalent). **Air-gapped:** the scan engine runs `--network=none` against a signature DB on a **read-only shared volume** that a separate networked `freshclam` sidecar keeps fresh (the documented pattern). Catches *known* malware/maldocs/macros.
- **Structural maldoc analysis** (sharper than generic AV for *this* threat, and catches zero-days AV misses): `pdfid`/`pdf-parser` (Didier Stevens — `/OpenAction`, `/Launch`, `/JS`, `/EmbeddedFile`, `/ObjStm`…) + `oletools` (`olevba`/`mraptor` — VBA macros, DDE, embedded OLE). Combined off-the-shelf tools (`office-scan`, `MADFA`) emit one risk-score verdict per file.
- **Policy:** known-malware → reject + report. Suspicious (macros/JS/launch) → flag to the user + still extract (safe — see layer 3). The scanner itself parses untrusted bytes (ClamAV has had CVEs), so it **runs inside the same no-network sandbox** — its own parsing is contained too.
- **Honest scope:** AV is signature-based (misses zero-days); structural analysis can false-positive on legit macros. So this layer is *early-reject + transparency*, NOT the safety guarantee — that's layer 2.

**2. Contain (the actual guarantee).** Parsing happens only inside the no-network, cap-dropped, read-only sandbox (§4). A zero-day the scanner misses still can't escape.

**3. Disarm by non-execution.** Extraction **does not run the payload** — `tabula` reads document structure (it does not execute VBA); poppler rasterizes (it does not run PDF JS). Only pixels or plain markdown cross out. A macro-laden docx is safe to *text-extract* because the macro never runs.

**4. Content-gate (text only).** A model can't spot a malformed-file exploit in raw bytes, so the model gate goes on the **extracted text**: the existing `compose_messages` prompt-injection regex + "untrusted data" framing (built), plus an optional **tools-off `is_safe` triage** (our judges' shape — structured output, no tools) flagging overt instruction-to-the-model before the text becomes subject material. Pixels need no content gate (a bitmap carries no instructions).

**The Go-purity tension (for council):** ClamAV is C, oletools/pdfid are Python — the one place "Go-only, keep it light" and best-of-breed detection diverge. Options: (a) ClamAV only (signature AV, sidecar + shared DB); (b) structural only (oletools/pdfid/YARA, Python in the sandbox); (c) both (defense-in-depth); (d) a minimal **Go** structural check we write (magic-bytes + a keyword/zip-entry scan for `/JS`,`/OpenAction`,`vbaProject.bin`) — lighter, Go-pure, less complete. Recommendation: **(c) for the air-gapped sandbox** (ClamAV engine in-image + DB-via-volume; oletools/pdfid for the maldoc verdict) — it's the "1000× better than industry" layer and runs sealed; revisit (d) if image weight bites.

## 6. Reuse ledger

| Piece | Status |
|---|---|
| Sandbox lifecycle, no-network, kill-switch, cap-drop, resource caps, reaper | **built** (`cmd/coder-mcp/sandbox`) |
| HTML → markdown (readability + html-to-markdown) | **built** (`cmd/fetch-md-mcp`) |
| **PDF/DOCX/XLSX/PPTX/ODT/EPUB → markdown (tabula, pure-Go, full office)** | **built** (`cmd/fetch-md-mcp` ES.5.s2) |
| Chrome renderer (chromedp) | **built** (dependency present) |
| `chat_attachments` (image lands as subject) + vision path | **built** (P1/P2) |
| book corpus (chunk + index + search extracted text) | **built** (`examples/book-corpus.sql`) |
| prompt-injection defense | **built** (`compose_messages`) |
| `doc-extract` image (Go binary w/ tabula + poppler `pdftoppm` + ClamAV engine; NO libreoffice in v1) | **new** |
| read-only rootfs + tmpfs + nofile cap in `Provision` | **new** (localized in `sandbox.go`) |
| the router (text always + pixels overlay) + a thin deterministic extract handler | **new** |
| **scan layer** — ClamAV (engine in-image + DB-via-shared-volume + networked `freshclam` sidecar) + structural maldoc check (oletools/pdfid) | **new** |
| `is_safe` tools-off triage on extracted text | **new** (reuses judge shape) |
| gVisor `--runtime=runsc` toggle | **later** (deferred until NOCIX confirms `runsc`) |

## 7. Phasing (proposed, post-ratification)

- **P3a — the sandbox + the image + the hardening delta + the scan layer.** A deterministic `doc-extract` handler proven on a benign doc + a **malicious-doc smoke** (an EICAR-style / macro-laden sample: ClamAV flags it, the parser dies *inside* the sandbox, nothing escapes, no-network confirmed). The scan layer (ClamAV + structural check) lands here — it's the trust floor everything else sits on.
- **P3b — text always (the workhorse).** PDF/office → **tabula** → markdown; HTML → in-tree readability path; chunk + index like the book corpus; the `is_safe` gate. (Smoke tabula on a messy pptx + a multi-column report first — confirm the quality floor.)
- **P3c — pixels overlay.** doc → page PNGs (poppler) → `chat_attachments` → vision, added alongside the text. Reuses P2 end-to-end.
- **P3d — the router** (text always + pixels overlay by page-count threshold, force-render override) + the empty-chat corpus/project lens picker (the rich-docs P3 UI).
- **P3e — archives & folders (§3.5).** Safe-unpack in the sandbox (the caps table) → per-member scan + extract → a folder-tree result → "work with" (subject) and "import" (folder → corpus/project, book-chunks reuse). Proven on a benign multi-file zip + a **zip-bomb / zip-slip smoke** (both refused, nothing escapes).
- **P3f — fold in the digester-reads-repos lane** (the same no-network extract sandbox reads a read-only repo checkout for the "cross-reference our corpus" stage — a repo is just a folder, so it rides P3e's tree-extract).

## 8. Decisions to ratify

1. **Isolation tier v1 = container + no-net** (reuse the coder spine + read-only/tmpfs/nofile delta). **gVisor `runsc` is SKIPPED for now** — revisit once Michael confirms `runsc` installs on KC NOCIX + the work VM (he has root on both). *(Michael, 2026-06-24: "skip visor until I can confirm.")*
2. **Text always + pixels overlay** — text is extracted for every readable doc (cheap, models excel at it), pixels added for visual/short docs (page-count threshold, user can force-render). NOT pixels-XOR-text. *(Michael, 2026-06-24: "even for short PDFs I'd still want text too… I want images too.")*
2b. **Scan layer = (c) BOTH — RATIFIED** *(Michael, 2026-06-24: "lets go c combo!")*: **ClamAV** (sealed: engine in-image + DB-via-volume + networked freshclam sidecar) **+ a structural maldoc check** (oletools/pdfid). Scans **every file** (incl. each member extracted from an archive — §3.5). Early-reject known-bad + flag macros/JS to the user; sits on top of the sandbox, runs sealed itself. The Python (oletools/pdfid) runs only inside the sealed sandbox — never touches our Go code or the host — so the Go-purity preference holds at our surface. A Go-only minimal check (option d in §5) remains the fallback if image weight bites.
2c. **Archive / folder upload — RATIFIED in scope** (§3.5) *(Michael, 2026-06-24: "drop a zip with 1 or many files/folder structure to work with or import")*: a zip (or tar) unpacks in the sandbox under strict caps, each member runs the per-file pipeline (scan → text + pixels), and the result is a folder tree the chat can work with OR import as a corpus/project.
3. **Engines = Go-first, full office, already in-tree:** **`tabula`** (pure-Go) for PDF/DOCX/XLSX/PPTX/ODT/EPUB → markdown (Path B), in-tree readability+html-to-markdown for HTML, **poppler `pdftoppm`** for PDF→pixels (Path A). **No markitdown, no Python.** libreoffice only for the optional *faithful office→pixels* upgrade tier. Docling deferred as a table-heavy upgrade. *(Michael, 2026-06-24: "Go only to keep it light" + "full office support" — tabula satisfies both; he'd used it before via fetch-md.)*
4. **`is_safe` gate on extracted text, not bytes** — layered on the existing injection regex; pixels ungated.
5. **A separate lean `doc-extract` image** (Go binary + poppler), not the coder image.
6. **One lane serves both** rich-docs P3 and the digester-reads-repos item.

## 9. Open questions for council

**Resolved 2026-06-24** (folded into §8): image weight (Go binary + poppler — light, no libreoffice/Python in v1); Python-vs-Go (tabula, Go); gVisor (skip until NOCIX confirms `runsc`).

Still open:
- **tabula quality bar:** it's a pure-Go extractor — clean-enough markdown text for full office, but its table/multi-column fidelity won't match docling. For "searchable subject text" that's fine; if a table-heavy CX/marketing deck needs faithful layout, **Path A (render→pixels→vision) covers it** (the model reads the rendered page). So between tabula-text and render-pixels we cover content + layout — but worth a real-doc smoke (a messy pptx, a multi-column report) to confirm tabula's floor before committing it as the sole text engine. docling/markitdown stays the named upgrade.
- **Faithful office→pixels:** v1 renders only PDF/image to pixels (poppler). A docx/pptx as *pixels* needs office→PDF first (libreoffice, ~600 MB) — worth it later for marketing decks where layout IS the content, or does tabula-text + a "convert to PDF yourself" note suffice for v1?
- **Per-doc cost ceiling:** Path A on a long doc is many vision calls — the router's page-count threshold (>N pages → force Path B) needs a default.
- **Retention:** extracted text + page PNGs are derived artifacts — keep on `chat_attachments` (durable, carries into spawned work) or treat as ephemeral cache? Ties to the P2 attachment-retention follow-up.
- **Archive caps (defaults to set, §3.5):** max total uncompressed size (e.g. 200 MB?), max entry count (e.g. 1000?), compression-ratio ceiling, max files actually extracted/processed, and the nested-archive policy (recommend: do NOT auto-recurse — surface a contained archive as a file). These are the zip-bomb guardrails; pick conservative defaults, make them config.
- **Import target:** when a folder is "imported," does it create a new project, attach to the selected project, or land as a session-scoped corpus? (Ties to the empty-chat lens picker in P3d.)
