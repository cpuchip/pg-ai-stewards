package docextract

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"

	htmltomarkdown "github.com/JohannesKaufmann/html-to-markdown/v2"
	readability "github.com/go-shiori/go-readability"
	"github.com/tsawler/tabula"
)

// tabulaExts are the document types tabula extracts to markdown (the in-tree,
// pure-Go, full-office path reused from fetch-md-mcp ES.5.s2).
var tabulaExts = map[string]bool{
	".pdf": true, ".docx": true, ".xlsx": true,
	".pptx": true, ".odt": true, ".epub": true,
}

var textExts = map[string]bool{
	".txt": true, ".md": true, ".markdown": true, ".csv": true,
	".json": true, ".yaml": true, ".yml": true, ".log": true,
	".go": true, ".py": true, ".js": true, ".ts": true, ".rs": true,
	".sql": true, ".sh": true, ".toml": true, ".ini": true, ".rtf": true,
}

var imageExts = map[string]bool{
	".png": true, ".jpg": true, ".jpeg": true, ".gif": true,
	".webp": true, ".bmp": true, ".tiff": true, ".tif": true,
}

// detectDocType classifies the bytes by magic + filename extension. It returns
// a coarse doc_type (for the Result) and the file extension tabula/poppler key
// off (always lowercased, leading dot).
func detectDocType(data []byte, filename string) (docType, ext string) {
	ext = strings.ToLower(filepath.Ext(path.Base(strings.ReplaceAll(filename, "\\", "/"))))

	switch {
	case bytes.HasPrefix(data, magicPDF):
		return "pdf", ".pdf"
	case bytes.HasPrefix(data, magicOLE):
		return "legacy-office", ext // doc/xls/ppt — tabula won't read; treated as unknown text below
	case bytes.HasPrefix(data, magicZIP):
		// OOXML / odt / epub share the zip magic — disambiguate by extension.
		if tabulaExts[ext] {
			return strings.TrimPrefix(ext, "."), ext
		}
		return "zip", ext
	}
	switch {
	case imageExts[ext]:
		return "image", ext
	case ext == ".html" || ext == ".htm" || ext == ".xhtml":
		return "html", ext
	case isLikelyHTML(data):
		return "html", ".html"
	case tabulaExts[ext]:
		return strings.TrimPrefix(ext, "."), ext
	case textExts[ext]:
		return "text", ext
	case isLikelyText(data):
		return "text", ".txt"
	}
	return "unknown", ext
}

// ExtractFile runs the full per-file pipeline on one document's bytes: scan
// (layer 1) -> quarantine if malicious -> else extract text (always) + pixels
// (if requested + renderable). Member failures are captured in FileResult,
// never panic.
func ExtractFile(ctx context.Context, data []byte, name string, opts Options) FileResult {
	docType, ext := detectDocType(data, name)
	fr := FileResult{Path: name, DocType: docType, MimeType: mimeForExt(ext, docType)}

	// Layer 1 — scan first, on the raw bytes.
	fr.Scan = Scan(ctx, data, name, opts.ClamAVDB)
	if fr.Scan.Verdict == VerdictMalicious {
		// Quarantine: do NOT parse a known-malicious file for content.
		fr.Skipped = true
		fr.Error = "quarantined: " + fr.Scan.Signature
		return fr
	}

	// Text — always, for any readable doc (layers 3+4 make this safe even when
	// the scan flagged macros: tabula reads structure, it never runs VBA).
	if text, err := extractText(data, docType, ext); err != nil {
		fr.Error = err.Error()
	} else {
		fr.Text = text
		fr.WordCount = len(strings.Fields(text))
	}

	// Pixels — the additive overlay. The router (proposal §3): render when
	// FORCED, or AUTO for a short doc (page count <= MaxPages) so a short PDF
	// yields both text + pixels while a long report stays text-only.
	if shouldRenderPixels(ctx, data, docType, opts) {
		if pages, err := renderPages(ctx, data, docType, opts); err != nil {
			// A render failure is non-fatal — the text already crossed the
			// boundary. Record it as a note, don't clobber a text error.
			if fr.Error == "" {
				fr.Error = "render: " + err.Error()
			}
		} else {
			fr.Pages = pages
		}
	}
	return fr
}

// extractText turns document bytes into markdown. PDF/office/epub go through
// tabula (pure Go); HTML through readability + html-to-markdown (the in-tree
// path); plain text passes through. Images and unknown/legacy-OLE yield no
// text (the model gets pixels, or nothing).
func extractText(data []byte, docType, ext string) (string, error) {
	switch {
	case docType == "image":
		return "", nil // images carry no text; the pixel path handles them
	case docType == "html":
		return htmlToMarkdown(data)
	case docType == "text":
		return string(data), nil
	case tabulaExts["."+strings.TrimPrefix(ext, ".")] || tabulaExts[ext] || docType == "pdf":
		return tabulaExtract(data, normalizeTabulaExt(docType, ext))
	case docType == "legacy-office":
		return "", fmt.Errorf("legacy OLE office format (doc/xls/ppt) is not supported for text; convert to a modern format or render to pixels")
	default:
		// Last resort: if it scans as mostly text, return it.
		if isLikelyText(data) {
			return string(data), nil
		}
		return "", fmt.Errorf("no text extractor for doc_type %q", docType)
	}
}

// normalizeTabulaExt resolves the temp-file extension tabula auto-detects from.
func normalizeTabulaExt(docType, ext string) string {
	if tabulaExts[ext] {
		return ext
	}
	if docType == "pdf" {
		return ".pdf"
	}
	if d := "." + docType; tabulaExts[d] {
		return d
	}
	return ext
}

// tabulaExtract writes the bytes to a temp file (tabula's API is path-based)
// with the detected extension so tabula auto-detects the format, then extracts.
func tabulaExtract(data []byte, ext string) (string, error) {
	if ext == "" {
		ext = ".pdf"
	}
	tmp, err := os.CreateTemp("", "docextract-*"+ext)
	if err != nil {
		return "", fmt.Errorf("temp file: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return "", fmt.Errorf("write temp: %w", err)
	}
	tmp.Close()
	out, _, err := tabula.Open(tmp.Name()).ToMarkdown()
	if err != nil {
		return "", fmt.Errorf("tabula extract %s: %w", ext, err)
	}
	return out, nil
}

// htmlToMarkdown extracts the main article (readability) then converts to
// markdown — the same pipeline fetch-md-mcp uses for fetched pages.
func htmlToMarkdown(data []byte) (string, error) {
	article, err := readability.FromReader(bytes.NewReader(data), nil)
	if err != nil {
		// Fall back to converting the whole document if readability bails.
		md, cerr := htmltomarkdown.ConvertString(string(data))
		if cerr != nil {
			return "", fmt.Errorf("readability: %w (html→md fallback: %v)", err, cerr)
		}
		return md, nil
	}
	md, err := htmltomarkdown.ConvertString(article.Content)
	if err != nil {
		return "", fmt.Errorf("html→markdown: %w", err)
	}
	if strings.TrimSpace(article.Title) != "" {
		md = "# " + strings.TrimSpace(article.Title) + "\n\n" + md
	}
	return md, nil
}

// renderPages rasterizes a document to per-page PNGs via poppler's pdftoppm
// (PDF only in v1 — office→pixels needs libreoffice, a later tier). Returns an
// error when poppler is absent (dev host) so the caller degrades to text-only.
func renderPages(ctx context.Context, data []byte, docType string, opts Options) ([]PageImage, error) {
	if docType != "pdf" {
		return nil, fmt.Errorf("pixel rendering supports PDF only in v1 (got %q); office→pixels is a later libreoffice tier", docType)
	}
	if _, err := exec.LookPath("pdftoppm"); err != nil {
		return nil, fmt.Errorf("pdftoppm (poppler) not found: %w", err)
	}
	maxPages := opts.MaxPages
	if maxPages <= 0 {
		maxPages = defaultMaxPages
	}
	dpi := opts.RenderDPI
	if dpi <= 0 {
		dpi = defaultRenderDPI
	}

	dir, err := os.MkdirTemp("", "docextract-render-*")
	if err != nil {
		return nil, fmt.Errorf("temp dir: %w", err)
	}
	defer os.RemoveAll(dir)
	inPath := filepath.Join(dir, "in.pdf")
	if err := os.WriteFile(inPath, data, 0o600); err != nil {
		return nil, fmt.Errorf("write pdf: %w", err)
	}
	prefix := filepath.Join(dir, "page")
	cmd := exec.CommandContext(ctx, "pdftoppm",
		"-png", "-r", fmt.Sprintf("%d", dpi),
		"-f", "1", "-l", fmt.Sprintf("%d", maxPages),
		inPath, prefix)
	if out, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("pdftoppm: %w\n%s", err, string(out))
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read render dir: %w", err)
	}
	var names []string
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "page") && strings.HasSuffix(e.Name(), ".png") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names) // page-1.png, page-2.png … (poppler zero-pads as needed)
	pages := make([]PageImage, 0, len(names))
	for i, n := range names {
		b, rerr := os.ReadFile(filepath.Join(dir, n))
		if rerr != nil {
			continue
		}
		pages = append(pages, PageImage{Page: i + 1, PNGBase64: base64.StdEncoding.EncodeToString(b)})
	}
	return pages, nil
}

// shouldRenderPixels is the router decision for the pixel overlay. PDF only in
// v1. RenderPages forces it; otherwise AutoRender renders only a SHORT doc
// (page count <= MaxPages) so a long report stays text-only (proposal §3). If
// the page count can't be probed (no pdfinfo on a dev host), auto-render is
// skipped — text already crossed the boundary.
func shouldRenderPixels(ctx context.Context, data []byte, docType string, opts Options) bool {
	if docType != "pdf" {
		return false
	}
	if opts.RenderPages {
		return true // forced ("render all")
	}
	if !opts.AutoRender {
		return false
	}
	max := opts.MaxPages
	if max <= 0 {
		max = defaultMaxPages
	}
	n := pdfPageCount(ctx, data)
	return n > 0 && n <= max
}

// pdfPageCount probes a PDF's page count via poppler's pdfinfo. Returns -1 when
// pdfinfo is unavailable or the count can't be parsed (auto-render then skips).
func pdfPageCount(ctx context.Context, data []byte) int {
	if _, err := exec.LookPath("pdfinfo"); err != nil {
		return -1
	}
	tmp, err := os.CreateTemp("", "docextract-info-*.pdf")
	if err != nil {
		return -1
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return -1
	}
	tmp.Close()
	out, err := exec.CommandContext(ctx, "pdfinfo", tmp.Name()).Output()
	if err != nil {
		return -1
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "Pages:") {
			var n int
			if _, err := fmt.Sscanf(strings.TrimSpace(strings.TrimPrefix(line, "Pages:")), "%d", &n); err == nil {
				return n
			}
		}
	}
	return -1
}

// Run is the top-level entry: it decides between the single-file pipeline and
// the archive pipeline (unpack -> per-member ExtractFile), honoring the
// nested-archive policy. This is what cmd/doc-extract calls with the stdin bytes.
func Run(ctx context.Context, data []byte, opts Options) (Result, error) {
	if opts.Caps.MaxTotalUncompressed == 0 {
		opts.Caps = DefaultArchiveCaps()
	}
	if IsArchive(ctx, data, opts.Filename) {
		return runArchive(ctx, data, opts)
	}
	fr := ExtractFile(ctx, data, baseName(opts.Filename), opts)
	return Result{Mode: "file", Files: []FileResult{fr}}, nil
}

func runArchive(ctx context.Context, data []byte, opts Options) (Result, error) {
	members, warnings, err := unpackArchive(ctx, data, opts.Filename, opts.Caps)
	res := Result{Mode: "archive", Warnings: warnings}
	if err != nil {
		// A hard bomb/cap breach: surface the breach AND whatever we safely got.
		res.Warnings = append(res.Warnings, "archive unpack halted: "+err.Error())
	}
	for _, m := range members {
		// Nested-archive policy: by default surface a contained archive as a
		// file (do NOT auto-recurse — a zip-in-zip evades per-member scanning).
		if !opts.Caps.RecurseNested && IsArchive(ctx, m.data, m.name) {
			res.Files = append(res.Files, FileResult{
				Path:    m.name,
				DocType: "archive",
				Scan:    Scan(ctx, m.data, m.name, opts.ClamAVDB),
				Skipped: true,
				Error:   "nested archive surfaced as a file (not auto-unpacked); upload it separately to extract",
			})
			continue
		}
		res.Files = append(res.Files, ExtractFile(ctx, m.data, m.name, opts))
	}
	return res, nil
}

func baseName(filename string) string {
	b := path.Base(strings.ReplaceAll(filename, "\\", "/"))
	if b == "" || b == "." || b == "/" {
		return "attachment"
	}
	return b
}

// isLikelyText reports whether the bytes look like UTF-8/ASCII text (no NUL,
// mostly printable) — a cheap heuristic for the "treat unknown as text" path.
func isLikelyText(data []byte) bool {
	n := len(data)
	if n == 0 {
		return false
	}
	if n > 8192 {
		n = 8192
	}
	sample := data[:n]
	if bytes.IndexByte(sample, 0x00) >= 0 {
		return false // NUL byte → binary
	}
	nonPrintable := 0
	for _, b := range sample {
		if b < 0x09 || (b > 0x0D && b < 0x20) {
			nonPrintable++
		}
	}
	return nonPrintable*100/len(sample) < 5 // <5% control chars
}

func isLikelyHTML(data []byte) bool {
	low := bytes.ToLower(data[:min(len(data), 1024)])
	return bytes.Contains(low, []byte("<!doctype html")) || bytes.Contains(low, []byte("<html"))
}

func mimeForExt(ext, docType string) string {
	switch docType {
	case "pdf":
		return "application/pdf"
	case "html":
		return "text/html"
	case "text":
		return "text/plain"
	case "image":
		switch ext {
		case ".png":
			return "image/png"
		case ".jpg", ".jpeg":
			return "image/jpeg"
		case ".gif":
			return "image/gif"
		case ".webp":
			return "image/webp"
		}
		return "image/" + strings.TrimPrefix(ext, ".")
	case "docx":
		return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
	case "xlsx":
		return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
	case "pptx":
		return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
	}
	return "application/octet-stream"
}
