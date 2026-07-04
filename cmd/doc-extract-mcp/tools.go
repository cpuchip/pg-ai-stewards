// MCP tool surface for doc-extract-mcp. One tool, `doc_extract`, drives the
// whole capability: read an attachment's bytes -> spawn the hardened sandbox ->
// write back safe subject material. It is deterministic (no LLM in the loop)
// and DB-aware so the bytes never leave the server.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/cpuchip/pg-ai-stewards/cmd/doc-extract-mcp/runner"
	"github.com/cpuchip/pg-ai-stewards/internal/docextract"
	"github.com/cpuchip/pg-ai-stewards/internal/wikiassets"
)

// --- corpus import tuning (env-configurable, generic OSS) ---

// defaultChunkChars: a pooled doc bigger than this is split into ~chunk-sized
// parts so doc_search returns focused passages and a world-build agent can
// actually read them — a single giant doc makes the agent flail (it pulls the
// whole body and burns its budget searching). Override: DOC_IMPORT_CHUNK_CHARS.
const defaultChunkChars = 12000

func importChunkChars() int {
	if v := os.Getenv("DOC_IMPORT_CHUNK_CHARS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1000 {
			return n
		}
	}
	return defaultChunkChars
}

func envMB(key string) int64 {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return int64(n) << 20
		}
	}
	return 0
}

// archiveCaps is DefaultArchiveCaps with optional env overrides so an operator
// with a large TRUSTED corpus (e.g. a multi-hundred-MB doc folder) can raise the
// ceilings: DOC_EXTRACT_MAX_TOTAL_MB / DOC_EXTRACT_MAX_ENTRY_MB / DOC_EXTRACT_MAX_ENTRIES.
func archiveCaps() docextract.ArchiveCaps {
	caps := docextract.DefaultArchiveCaps()
	if v := envMB("DOC_EXTRACT_MAX_TOTAL_MB"); v > 0 {
		caps.MaxTotalUncompressed = v
	}
	if v := envMB("DOC_EXTRACT_MAX_ENTRY_MB"); v > 0 {
		caps.MaxEntrySize = v
	}
	if s := os.Getenv("DOC_EXTRACT_MAX_ENTRIES"); s != "" {
		if n, err := strconv.Atoi(s); err == nil && n > 0 {
			caps.MaxEntries = n
		}
	}
	return caps
}

// chunkText splits s into ~size-rune pieces, preferring to break on a newline in
// the back half of each window so chunks end at line boundaries (cleaner for FTS
// and reading). Returns [s] unchanged when it already fits.
func chunkText(s string, size int) []string {
	r := []rune(s)
	if len(r) <= size {
		return []string{s}
	}
	var out []string
	for i := 0; i < len(r); {
		end := i + size
		if end >= len(r) {
			out = append(out, string(r[i:]))
			break
		}
		cut := end
		for j := end; j > i+size/2; j-- {
			if r[j] == '\n' {
				cut = j + 1
				break
			}
		}
		out = append(out, string(r[i:cut]))
		i = cut
	}
	return out
}

func registerDocExtractTools(srv *mcp.Server, run *runner.Runner, pool *pgxpool.Pool) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_extract",
		Description: "Turn an attached document (PDF / Office / HTML / text / archive) into safe, " +
			"readable subject material. Pass the attachment_id from a chat upload. The bytes are parsed " +
			"inside a hardened, no-network sandbox (a malicious file can't escape); only extracted text " +
			"(always) and — when render=true — page images cross back. The extracted text is written to " +
			"the attachment so it appears in the conversation; for an archive, every member is unpacked " +
			"(under bomb/slip caps), scanned, and surfaced as a folder tree. Returns a summary incl. the " +
			"security scan verdict. Call this once per document attachment before reasoning over it.",
	}, makeDocExtract(run, pool))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "doc_import_corpus",
		Description: "IMPORT an attached archive/folder (or a single document) into the searchable docs " +
			"pool as a project corpus — 'drop a folder of PM/UX/CX/marketing docs, get a searchable " +
			"project'. Each member is extracted in the hardened sandbox (scan + text), then pooled as a " +
			"doc tagged with the given project so doc_search finds it. Pass attachment_id + a corpus_name " +
			"(and optionally project). Malicious/empty members are skipped. Returns how many were imported.",
	}, makeDocImportCorpus(run, pool))

	mcp.AddTool(srv, &mcp.Tool{
		Name: "assets_backfill",
		Description: "Re-extract WIKI ASSETS (embedded picture XObjects — maps, character art, item cards, " +
			"tables) from an ALREADY-INGESTED PDF, without re-importing it. Pass `doc` as either a " +
			"chat_attachments id (the original PDF) or a stewards.docs slug/id it was pooled into via " +
			"doc_import_corpus (resolved back to its source attachment). Runs the same hardened sandbox as " +
			"doc_extract, but budgeted for a deliberate one-shot sweep (minutes, not seconds) since this is " +
			"not an inline request the user is waiting on. Assets are saved as chat attachments (servable " +
			"immediately) and linked into stewards.wiki_assets when the PDF is pooled and that table exists. " +
			"Use this to give Michael's existing TTRPG rulebooks browsable art without a re-import.",
	}, makeAssetsBackfill(run, pool))
}

type docExtractInput struct {
	AttachmentID int64 `json:"attachment_id" jsonschema:"The chat_attachments id of the uploaded document"`
	Render       bool  `json:"render,omitempty" jsonschema:"Also render page images (pixel overlay) for the vision model — costs a vision call per page (PDF only in v1)"`
	MaxPages     int   `json:"max_pages,omitempty" jsonschema:"Cap rendered pages when render=true (0 = default 10)"`
}

type docExtractOutput struct {
	AttachmentID   int64    `json:"attachment_id"`
	Mode           string   `json:"mode"` // file | archive
	DocType        string   `json:"doc_type,omitempty"`
	ExtractedChars int      `json:"extracted_chars"`
	ExtractedText  string   `json:"extracted_text,omitempty"` // the text, returned in-turn (capped) so the agent reads it now
	ScanVerdict    string   `json:"scan_verdict"`
	ScanFindings   []string `json:"scan_findings,omitempty"`
	Quarantined    bool     `json:"quarantined,omitempty"`
	PageImageIDs   []int64  `json:"page_image_ids,omitempty"`
	// Wiki-assets overlay (embedded PDF picture XObjects — distinct from the
	// whole-page renders above): WikiAssetImageIDs are the chat_attachments
	// ids (servable immediately at /api/chat/attachment/<id>); WikiAssetsLinked
	// counts how many were ALSO linked into stewards.wiki_assets (only
	// possible once the source PDF is pooled via doc_import_corpus AND WIKI-
	// CORE's table exists — see WikiAssetsNote when it's fewer than len(ids)).
	WikiAssetImageIDs []int64 `json:"wiki_asset_image_ids,omitempty"`
	WikiAssetsLinked  int     `json:"wiki_assets_linked,omitempty"`
	WikiAssetsNote    string  `json:"wiki_assets_note,omitempty"`
	Members           int     `json:"members,omitempty"`
	RepoKind          string  `json:"repo_kind,omitempty"`   // archive only: code | docs | mixed (RC-2 routing hint)
	RepoReason        string  `json:"repo_reason,omitempty"` // why (e.g. "has a build manifest (go.mod)")
	Summary           string  `json:"summary"`
}

// toolTextCap bounds the text returned in the tool RESULT (the full text is
// always persisted to chat_attachments.extracted_text and injected on later
// turns; this just keeps a huge doc from blowing the immediate tool result).
const toolTextCap = 24000

// bulkExtractTimeoutSecs is the converter + container deadline for the slow doc
// tools — a big archive's per-member extract+scan legitimately runs minutes. It
// sits UNDER the bridge daemon's --slow-call-timeout (600s) so the converter
// reports a clean timeout instead of the bridge killing the call. RC-3.
const bulkExtractTimeoutSecs = 540

func makeDocExtract(run *runner.Runner, pool *pgxpool.Pool) func(context.Context, *mcp.CallToolRequest, docExtractInput) (*mcp.CallToolResult, docExtractOutput, error) {
	return func(ctx context.Context, _ *mcp.CallToolRequest, in docExtractInput) (*mcp.CallToolResult, docExtractOutput, error) {
		out, err := extractAttachment(ctx, pool, run, in)
		if err != nil {
			return errResult("%v", err), docExtractOutput{}, nil
		}
		return nil, out, nil
	}
}

// extractAttachment is the deterministic core (callable from the MCP tool and
// the `-attachment` debug path): read bytes -> spawn the hardened sandbox ->
// write extracted_text + page images back -> return a summary + the text.
func extractAttachment(ctx context.Context, pool *pgxpool.Pool, run *runner.Runner, in docExtractInput) (docExtractOutput, error) {
	if in.AttachmentID <= 0 {
		return docExtractOutput{}, fmt.Errorf("attachment_id is required")
	}
	// Read the stored bytes (server-side — never through the model).
	var (
		sessionID, filename, mime string
		data                      []byte
		alreadyText               *string
	)
	if err := pool.QueryRow(ctx,
		`SELECT session_id, filename, coalesce(mime_type,''), bytes, extracted_text
		   FROM stewards.chat_attachments WHERE id = $1`, in.AttachmentID,
	).Scan(&sessionID, &filename, &mime, &data, &alreadyText); err != nil {
		return docExtractOutput{}, fmt.Errorf("attachment %d not found: %w", in.AttachmentID, err)
	}
	if len(data) == 0 {
		return docExtractOutput{}, fmt.Errorf("attachment %d has no bytes", in.AttachmentID)
	}

	// Spawn the hardened sandbox. AutoRender on = the router default (render a
	// short doc's pixels; long docs stay text-only); Render forces all pages.
	res, stderr, err := run.Extract(ctx, data, runner.ExtractArgs{
		Filename: filename, Render: in.Render, AutoRender: true, MaxPages: in.MaxPages,
		Caps: archiveCaps(), TimeoutSecs: bulkExtractTimeoutSecs,
	})
	if err != nil {
		return docExtractOutput{}, fmt.Errorf("extraction failed: %w", err)
	}
	_ = stderr // converter logs to stderr; not surfaced unless we error

	out := docExtractOutput{AttachmentID: in.AttachmentID, Mode: res.Mode}

	switch res.Mode {
	case "file":
		fr := firstFile(res)
		out.DocType = fr.DocType
		out.ScanVerdict = fr.Scan.Verdict
		out.ScanFindings = fr.Scan.Findings
		text := fr.Text
		if fr.Skipped { // quarantined (malicious)
			out.Quarantined = true
			text = fmt.Sprintf("[QUARANTINED — this file was flagged as malicious by the security scan (%s) and was NOT parsed. %s]",
				nonEmpty(fr.Scan.Signature, "signature match"), fr.Error)
		}
		if err := writeExtracted(ctx, pool, in.AttachmentID, text, fr.Scan); err != nil {
			return docExtractOutput{}, fmt.Errorf("write extracted: %w", err)
		}
		out.ExtractedChars = len(text)
		out.ExtractedText = capText(text)
		// Pixel overlay -> child image attachments under this document.
		if len(fr.Pages) > 0 {
			ids, perr := writePageImages(ctx, pool, in.AttachmentID, sessionID, filename, fr.Pages)
			if perr != nil {
				return docExtractOutput{}, fmt.Errorf("write page images: %w", perr)
			}
			out.PageImageIDs = ids
		}
		// Wiki-assets overlay -> embedded picture XObjects, individually
		// addressable (distinct from the whole-page overlay above). Persisted
		// through the SAME chat_attachments storage convention regardless of
		// whether this PDF is pooled into stewards.docs yet; the wiki_assets
		// LINK is best-effort (skipped + noted when not pooled, or when
		// WIKI-CORE's table isn't live on this database yet).
		if len(fr.Images) > 0 {
			docID, pooled, derr := wikiassets.ResolveDocID(ctx, pool, in.AttachmentID)
			if derr != nil {
				return docExtractOutput{}, fmt.Errorf("resolve wiki doc id: %w", derr)
			}
			assets, aerr := wikiassets.PersistImages(ctx, pool, sessionID, filename, in.AttachmentID, docID, fr.Images)
			if aerr != nil {
				return docExtractOutput{}, fmt.Errorf("persist wiki assets: %w", aerr)
			}
			for _, a := range assets {
				out.WikiAssetImageIDs = append(out.WikiAssetImageIDs, a.AttachmentID)
				if a.AssetID != 0 {
					out.WikiAssetsLinked++
				}
			}
			if !pooled {
				out.WikiAssetsNote = "not yet pooled into stewards.docs — assets saved as attachments but not linked into wiki_assets; run doc_import_corpus, then re-extract (or assets-backfill), to link them"
			} else if out.WikiAssetsLinked < len(assets) {
				out.WikiAssetsNote = "wiki_assets table not available on this database yet (WIKI-CORE migration pending) — assets saved as attachments only"
			}
		}
		out.Summary = fileSummary(filename, fr, len(out.PageImageIDs))
		if len(out.WikiAssetImageIDs) > 0 {
			out.Summary += fmt.Sprintf(" %d embedded picture(s) extracted as wiki asset(s) (%d linked into wiki_assets).", len(out.WikiAssetImageIDs), out.WikiAssetsLinked)
		}

	case "archive":
		manifest, verdict, findings := archiveManifest(filename, res)
		out.Members = len(res.Files)
		out.ScanVerdict = verdict
		out.ScanFindings = findings
		scan := docextract.ScanResult{Verdict: verdict, Findings: findings, Engine: "clamav+structural"}
		if err := writeExtracted(ctx, pool, in.AttachmentID, manifest, scan); err != nil {
			return docExtractOutput{}, fmt.Errorf("write archive manifest: %w", err)
		}
		out.ExtractedChars = len(manifest)
		out.ExtractedText = capText(manifest)
		// RC-2 routing hint: is this a CODE repo or a DOCUMENT corpus? Code is
		// better EXPLORED in a sandbox (read it where it lives) than embedded
		// file-by-file; docs belong in the searchable pool.
		paths := make([]string, 0, len(res.Files))
		for _, fr := range res.Files {
			paths = append(paths, fr.Path)
		}
		out.RepoKind, out.RepoReason = docextract.Classify(paths)
		out.Summary = fmt.Sprintf("archive %q: %d member(s) unpacked + scanned (verdict %s). Surfaced as a folder tree in the conversation; use doc_import_corpus to persist it as a searchable project.",
			filename, len(res.Files), verdict)
		if out.RepoKind == "code" {
			out.Summary += fmt.Sprintf(" ⚙ This looks like a CODE repo (%s) — for code, EXPLORING it read-only in a sandbox beats embedding every file. Call research_codebase with attachment_id=%d (+ a question) to explore THIS dropped repo directly — no URL needed; doc_import_corpus would only make it keyword-searchable.", out.RepoReason, in.AttachmentID)
		}

	default:
		return docExtractOutput{}, fmt.Errorf("unexpected converter mode %q", res.Mode)
	}

	return out, nil
}

func capText(s string) string {
	if len(s) <= toolTextCap {
		return s
	}
	return s[:toolTextCap] + "\n\n[…truncated in this tool result; the full text is attached to the document]"
}

// --- doc_import_corpus: archive/folder -> searchable project pool ---

type docImportInput struct {
	AttachmentID int64  `json:"attachment_id" jsonschema:"The chat_attachments id of the uploaded archive/folder (or a single document)"`
	CorpusName   string `json:"corpus_name" jsonschema:"A short name for this folder/corpus (used to slug the pooled docs)"`
	Project      string `json:"project,omitempty" jsonschema:"Project tag so doc_search can scope to this corpus (project_association)"`
}

type docImportOutput struct {
	Corpus      string   `json:"corpus"`
	Project     string   `json:"project,omitempty"`
	Members     int      `json:"members"`
	Imported    int      `json:"imported"`
	Skipped     int      `json:"skipped"`
	Slugs       []string `json:"slugs,omitempty"`
	ScanVerdict string   `json:"scan_verdict"`
	Summary     string   `json:"summary"`
}

func makeDocImportCorpus(run *runner.Runner, pool *pgxpool.Pool) func(context.Context, *mcp.CallToolRequest, docImportInput) (*mcp.CallToolResult, docImportOutput, error) {
	return func(ctx context.Context, _ *mcp.CallToolRequest, in docImportInput) (*mcp.CallToolResult, docImportOutput, error) {
		out, err := importCorpusFn(ctx, pool, run, in)
		if err != nil {
			return errResult("%v", err), docImportOutput{}, nil
		}
		return nil, out, nil
	}
}

// importCorpusFn is the deterministic core (MCP tool + the -import-corpus debug
// path): extract every member of an archive/folder and pool each as a
// searchable doc tagged with the project.
func importCorpusFn(ctx context.Context, pool *pgxpool.Pool, run *runner.Runner, in docImportInput) (docImportOutput, error) {
	if in.AttachmentID <= 0 || strings.TrimSpace(in.CorpusName) == "" {
		return docImportOutput{}, fmt.Errorf("attachment_id and corpus_name are required")
	}
	var (
		filename string
		data     []byte
	)
	if err := pool.QueryRow(ctx,
		`SELECT filename, bytes FROM stewards.chat_attachments WHERE id = $1`, in.AttachmentID,
	).Scan(&filename, &data); err != nil {
		return docImportOutput{}, fmt.Errorf("attachment %d not found: %w", in.AttachmentID, err)
	}
	if len(data) == 0 {
		return docImportOutput{}, fmt.Errorf("attachment %d has no bytes", in.AttachmentID)
	}

	// Extract all members (text only — a corpus is searchable text, no pixels).
	// The bulk timeout (RC-3) lets a big document corpus finish instead of dying
	// at the old ~120s cliff.
	res, _, err := run.Extract(ctx, data, runner.ExtractArgs{
		Filename: filename, Caps: archiveCaps(), TimeoutSecs: bulkExtractTimeoutSecs,
	})
	if err != nil {
		return docImportOutput{}, fmt.Errorf("extraction failed: %w", err)
	}

	out := docImportOutput{Corpus: in.CorpusName, Project: strings.TrimSpace(in.Project), ScanVerdict: docextract.VerdictClean}
	out.Members = len(res.Files)
	corpusSlug := slugify(in.CorpusName)
	chunkChars := importChunkChars()
	for _, fr := range res.Files {
		out.ScanVerdict = worseVerdict(out.ScanVerdict, fr.Scan.Verdict)
		if fr.Skipped || strings.TrimSpace(fr.Text) == "" {
			out.Skipped++
			continue
		}
		baseSlug := corpusSlug + "-" + slugify(fr.Path)
		// Chunk a large member so doc_search returns focused passages (a single
		// giant doc makes the world-build agent flail). Small members stay one doc.
		parts := chunkText(fr.Text, chunkChars)
		for pi, ptext := range parts {
			slug := baseSlug
			title := in.CorpusName + ": " + fr.Path
			fm := map[string]any{
				"corpus":       in.CorpusName,
				"source_path":  fr.Path,
				"scan":         fr.Scan.Verdict,
				"imported_via": "doc-extract",
				// O3 forward-population: stamp the originating object so the pooled doc
				// (and anything built from it — a world entity, a digest) can open the
				// EXACT source it came from. att:<id> resolves in the object viewer.
				"source_object": fmt.Sprintf("att:%d", in.AttachmentID),
			}
			if len(parts) > 1 {
				slug = fmt.Sprintf("%s-%03d", baseSlug, pi+1)
				title = fmt.Sprintf("%s: %s (part %d/%d)", in.CorpusName, fr.Path, pi+1, len(parts))
				fm["part"] = pi + 1
				fm["parts"] = len(parts)
			}
			fmJSON, _ := json.Marshal(fm)
			// Pool the chunk as a searchable doc (FTS + the graph), then tag it
			// with the project so doc_search can scope to this corpus.
			if _, e := pool.Exec(ctx,
				`SELECT stewards.import_doc($1, $2, $3, $4, $5::jsonb, 'doc')`,
				slug, fr.Path, title, ptext, string(fmJSON)); e != nil {
				return docImportOutput{}, fmt.Errorf("import_doc(%s): %w", slug, e)
			}
			if out.Project != "" {
				_, _ = pool.Exec(ctx,
					`UPDATE stewards.docs SET project_association = $2 WHERE slug = $1`, slug, out.Project)
			}
			out.Imported++
			if len(out.Slugs) < 50 {
				out.Slugs = append(out.Slugs, slug)
			}
		}
	}
	projTag := ""
	if out.Project != "" {
		projTag = " tagged project=" + out.Project
	}
	out.Summary = fmt.Sprintf("imported %d doc(s) from %d member(s) of %q into the docs pool as corpus %q%s (scan %s); large members were chunked for focused search. Search them with doc_search.",
		out.Imported, out.Members, filename, in.CorpusName, projTag, out.ScanVerdict)
	return out, nil
}

// slugify lowercases + dash-collapses to a docs.slug-safe token.
func slugify(s string) string {
	var b strings.Builder
	prevDash := false
	for _, r := range strings.ToLower(s) {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'):
			b.WriteRune(r)
			prevDash = false
		default:
			if !prevDash {
				b.WriteByte('-')
				prevDash = true
			}
		}
	}
	out := strings.Trim(b.String(), "-")
	if out == "" {
		out = "item"
	}
	if len(out) > 80 {
		out = strings.Trim(out[:80], "-")
	}
	return out
}

// writeExtracted records the extracted text + scan verdict on the attachment.
func writeExtracted(ctx context.Context, pool *pgxpool.Pool, id int64, text string, scan docextract.ScanResult) error {
	findings := strings.Join(scan.Findings, ",")
	_, err := pool.Exec(ctx,
		`UPDATE stewards.chat_attachments
		    SET extracted_text = $2,
		        scan_verdict   = $3,
		        scan_findings  = NULLIF($4,'')
		  WHERE id = $1`,
		id, text, scan.Verdict, findings)
	return err
}

// writePageImages inserts the rendered page bitmaps as child image attachments
// (parent_id = the document) so chat_attachment_parts can include them as the
// pixel overlay alongside the document's text.
func writePageImages(ctx context.Context, pool *pgxpool.Pool, parentID int64, sessionID, filename string, pages []docextract.PageImage) ([]int64, error) {
	base := filename
	if i := strings.LastIndexByte(base, '.'); i > 0 {
		base = base[:i]
	}
	var ids []int64
	for _, p := range pages {
		png, derr := base64.StdEncoding.DecodeString(p.PNGBase64)
		if derr != nil {
			continue
		}
		var id int64
		if err := pool.QueryRow(ctx,
			`INSERT INTO stewards.chat_attachments
			    (session_id, filename, mime_type, kind, bytes, byte_size, parent_id)
			 VALUES ($1, $2, 'image/png', 'image', $3, $4, $5) RETURNING id`,
			sessionID, fmt.Sprintf("%s-p%d.png", base, p.Page), png, len(png), parentID,
		).Scan(&id); err != nil {
			return ids, err
		}
		ids = append(ids, id)
	}
	return ids, nil
}

// archiveManifest renders the unpacked archive as a folder-tree markdown the
// chat can "work with", and returns the worst member verdict + all findings.
func archiveManifest(filename string, res docextract.Result) (manifest, verdict string, findings []string) {
	var b strings.Builder
	fmt.Fprintf(&b, "# Archive: %s (%d member%s)\n\n", filename, len(res.Files), plural(len(res.Files)))
	if len(res.Warnings) > 0 {
		fmt.Fprintf(&b, "> ⚠ %s\n\n", strings.Join(res.Warnings, "; "))
	}
	verdict = docextract.VerdictClean
	seen := map[string]bool{}
	for _, fr := range res.Files {
		v := fr.Scan.Verdict
		verdict = worseVerdict(verdict, v)
		for _, f := range fr.Scan.Findings {
			if !seen[f] {
				seen[f] = true
				findings = append(findings, f)
			}
		}
		status := v
		if fr.Skipped {
			status += " (skipped)"
		}
		fmt.Fprintf(&b, "## %s  — %s, %s\n\n", fr.Path, nonEmpty(fr.DocType, "unknown"), status)
		if fr.Skipped {
			fmt.Fprintf(&b, "_%s_\n\n", fr.Error)
			continue
		}
		if strings.TrimSpace(fr.Text) != "" {
			b.WriteString(fr.Text)
			b.WriteString("\n\n")
		} else if fr.Error != "" {
			fmt.Fprintf(&b, "_(no text: %s)_\n\n", fr.Error)
		}
	}
	return b.String(), verdict, findings
}

// --- helpers ---

func firstFile(res docextract.Result) docextract.FileResult {
	if len(res.Files) > 0 {
		return res.Files[0]
	}
	return docextract.FileResult{Scan: docextract.ScanResult{Verdict: docextract.VerdictClean, Engine: "none"}, Error: "no file in result"}
}

func fileSummary(filename string, fr docextract.FileResult, nPages int) string {
	if fr.Skipped {
		return fmt.Sprintf("%q QUARANTINED by the security scan (%s) — not parsed.", filename, nonEmpty(fr.Scan.Signature, "malicious"))
	}
	s := fmt.Sprintf("%q (%s): extracted %d words of text, scan %s",
		filename, fr.DocType, fr.WordCount, fr.Scan.Verdict)
	if len(fr.Scan.Findings) > 0 {
		s += fmt.Sprintf(" [flagged: %s — still safe to read; extraction never executes the file]", strings.Join(fr.Scan.Findings, ", "))
	}
	if nPages > 0 {
		s += fmt.Sprintf("; rendered %d page image(s)", nPages)
	}
	return s + "."
}

// worseVerdict returns the more severe of two verdicts (clean < suspicious < malicious).
func worseVerdict(a, b string) string {
	rank := map[string]int{docextract.VerdictClean: 0, docextract.VerdictSuspicious: 1, docextract.VerdictMalicious: 2}
	if rank[b] > rank[a] {
		return b
	}
	return a
}

func nonEmpty(s, fallback string) string {
	if strings.TrimSpace(s) == "" {
		return fallback
	}
	return s
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}

func errResult(format string, a ...any) *mcp.CallToolResult {
	return &mcp.CallToolResult{
		IsError: true,
		Content: []mcp.Content{&mcp.TextContent{Text: fmt.Sprintf(format, a...)}},
	}
}

// --- assets_backfill: re-extract wiki assets from an already-ingested PDF ---

type assetsBackfillInput struct {
	Doc string `json:"doc" jsonschema:"a chat_attachments id (the original PDF) OR a stewards.docs slug/id it was pooled into via doc_import_corpus"`
}

type assetsBackfillOutput struct {
	AttachmentID   int64    `json:"attachment_id"`
	Filename       string   `json:"filename"`
	DocID          string   `json:"doc_id,omitempty"`
	CandidatePages int      `json:"candidate_pages"`
	Extracted      int      `json:"extracted"`
	AttachmentIDs  []int64  `json:"asset_attachment_ids,omitempty"`
	ServeURLs      []string `json:"serve_urls,omitempty"`
	Linked         int      `json:"wiki_assets_linked"`
	Note           string   `json:"note,omitempty"`
	Summary        string   `json:"summary"`
}

func makeAssetsBackfill(run *runner.Runner, pool *pgxpool.Pool) func(context.Context, *mcp.CallToolRequest, assetsBackfillInput) (*mcp.CallToolResult, assetsBackfillOutput, error) {
	return func(ctx context.Context, _ *mcp.CallToolRequest, in assetsBackfillInput) (*mcp.CallToolResult, assetsBackfillOutput, error) {
		res, err := wikiassets.Backfill(ctx, pool, run, in.Doc)
		if err != nil {
			return errResult("assets_backfill: %v", err), assetsBackfillOutput{}, nil
		}
		out := assetsBackfillOutput{
			AttachmentID: res.AttachmentID, Filename: res.Filename, DocID: res.DocID,
			CandidatePages: res.CandidatePages, Extracted: res.Extracted, Note: res.Note,
		}
		for _, a := range res.Assets {
			out.AttachmentIDs = append(out.AttachmentIDs, a.AttachmentID)
			out.ServeURLs = append(out.ServeURLs, a.ServeURL)
			if a.AssetID != 0 {
				out.Linked++
			}
		}
		out.Summary = fmt.Sprintf("%q: extracted %d embedded image(s) across %d candidate page(s) (%d linked into wiki_assets).",
			res.Filename, out.Extracted, out.CandidatePages, out.Linked)
		if out.Note != "" {
			out.Summary += " " + out.Note
		}
		return nil, out, nil
	}
}
