package docextract

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"image"
	_ "image/jpeg" // pdfimages can also emit JPEG for a source-JPEG XObject when NOT forced to -png; decode support kept for robustness
	_ "image/png"  // image.Decode dispatches by sniffed format; -png output needs this registered
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

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
	if text, err := extractText(ctx, data, docType, ext); err != nil {
		fr.Error = err.Error()
	} else {
		// Strip per-page purchase watermarks (e.g. DriveThruRPG / Renegade stamp
		// the buyer's name + order number on every page) so the buyer's PII does
		// not pollute the corpus or get mistaken for a recurring entity.
		fr.Text = stripPurchaseWatermarks(text)
		fr.WordCount = len(strings.Fields(fr.Text))
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

	// Embedded images — the wiki-assets overlay. UNLIKE the page-pixel
	// overlay above, this is NOT gated by Render/AutoRender: it always runs
	// for a PDF (same posture as text), because a rulebook's individual
	// illustrations are wiki-worthy on their own, independent of whether the
	// caller wants full-page screenshots too. Junk-filtered + budget-capped
	// (caps.go) so it degrades gracefully instead of blocking the doc.
	if docType == "pdf" {
		// NOTE: extractEmbeddedImages can return BOTH a populated slice AND a
		// non-nil error (the budget-exceeded case is partial success, not
		// failure — see its doc comment). fr.Images must be set REGARDLESS of
		// err, or a budget-capped run silently loses every image it already
		// extracted. (Caught by running this against a real 94-page rulebook:
		// the debug trace showed 9 images decoded clean, but the JSON result
		// still reported zero — this exact err!=nil-discards-imgs bug.)
		imgs, err := extractEmbeddedImages(ctx, data, opts)
		fr.Images = imgs
		if err != nil && fr.Error == "" {
			fr.Error = "images: " + err.Error()
		}
	}
	return fr
}

// extractText turns document bytes into markdown. PDF/office/epub go through
// tabula (pure Go); HTML through readability + html-to-markdown (the in-tree
// path); plain text passes through. Images and unknown/legacy-OLE yield no
// text (the model gets pixels, or nothing).
func extractText(ctx context.Context, data []byte, docType, ext string) (string, error) {
	switch {
	case docType == "image":
		return "", nil // images carry no text; the pixel path handles them
	case docType == "html":
		return htmlToMarkdown(data)
	case docType == "text":
		return string(data), nil
	case docType == "pdf":
		return pdfText(ctx, data)
	case tabulaExts["."+strings.TrimPrefix(ext, ".")] || tabulaExts[ext]:
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

// pdfFallbackMinWords is the floor below which tabula's PDF output is treated as
// "tabula couldn't parse this PDF" and we fall back to poppler's pdftotext. A
// real page carries hundreds of words; a near-empty result is a parse failure.
const pdfFallbackMinWords = 50

// pdfText extracts a PDF's text. tabula (pure Go) is tried first — it renders
// tables as markdown — but it silently yields nothing on a range of real-world
// PDFs (e.g. the MLP rulebook: tabula→0 words, poppler→141k). So when tabula
// errors or returns too little, fall back to poppler's pdftotext, which parses
// a far wider range. Whichever yields more text wins.
func pdfText(ctx context.Context, data []byte) (string, error) {
	md, terr := tabulaExtract(data, ".pdf")
	mdWords := len(strings.Fields(md))
	if terr == nil && mdWords >= pdfFallbackMinWords {
		return md, nil
	}
	txt, perr := popplerText(ctx, data)
	if perr == nil && len(strings.Fields(txt)) > mdWords {
		return txt, nil
	}
	if terr != nil {
		if perr != nil {
			return "", fmt.Errorf("pdf text: tabula: %v; poppler: %v", terr, perr)
		}
		return txt, nil // tabula errored; poppler's output (even if short) stands
	}
	return md, nil // tabula's output stands (poppler unavailable or not richer)
}

// popplerText shells poppler's pdftotext (present in the sandbox image alongside
// pdftoppm). UTF-8, no page-break form-feeds — just the text.
func popplerText(ctx context.Context, data []byte) (string, error) {
	if _, err := exec.LookPath("pdftotext"); err != nil {
		return "", fmt.Errorf("pdftotext (poppler) not found: %w", err)
	}
	tmp, err := os.CreateTemp("", "docextract-pdftext-*.pdf")
	if err != nil {
		return "", fmt.Errorf("temp file: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return "", fmt.Errorf("write temp: %w", err)
	}
	tmp.Close()
	out, err := exec.CommandContext(ctx, "pdftotext", "-enc", "UTF-8", "-nopgbrk", "-q", tmp.Name(), "-").Output()
	if err != nil {
		return "", fmt.Errorf("pdftotext: %w", err)
	}
	return string(out), nil
}

// purchaseWatermarkLine matches a per-page purchase/DRM watermark line — the
// shape storefronts (DriveThruRPG, Renegade, itch) stamp on every page:
// "<buyer name> (Order #1234567)". Precision over recall: only a whole line
// that ENDS in "(order #<digits>)" is stripped, so real prose is never touched.
var purchaseWatermarkLine = regexp.MustCompile(`(?im)^[ \t]*.{0,80}\(\s*order\s*#?\s*\d+\s*\)[ \t\r]*$`)

// collapseBlankRuns squeezes 3+ consecutive blank lines (left behind after a
// strip) down to a single blank line.
var collapseBlankRuns = regexp.MustCompile(`\n[ \t]*\n([ \t]*\n)+`)

// stripPurchaseWatermarks removes per-page buyer-PII watermark lines from
// extracted text so they neither pollute the corpus nor get mistaken for a
// recurring entity by a downstream world/digest builder.
func stripPurchaseWatermarks(text string) string {
	if text == "" {
		return text
	}
	cleaned := purchaseWatermarkLine.ReplaceAllString(text, "")
	return collapseBlankRuns.ReplaceAllString(cleaned, "\n\n")
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

// --- embedded images (wiki-assets overlay): pdfimages -list -> filter -> pdfimages -png ---

// imgListRow is one parsed row of `pdfimages -list` — the per-image metadata
// poppler reports WITHOUT decoding a single pixel (fast, always safe to run
// first). Columns (whitespace-separated, stable across poppler versions):
// page num type width height color comp bpc enc interp object ID x-ppi y-ppi size ratio.
type imgListRow struct {
	Page, Num, Width, Height int
	Type                     string // "image" | "smask" | "stencil" | ...
	Object                   string // the PDF object id — poppler's own de-dup key for a reused XObject

	// LocalIndex is this row's 0-based position AMONG its page's rows in
	// -list order. LOAD-BEARING, not cosmetic: `pdfimages -list` numbers Num
	// globally across the WHOLE document, but `pdfimages -p -f N -l N`
	// (targeting one page) renumbers its output files starting from 0 for
	// THAT PAGE ONLY (verified against a real 94-page PDF: -list reported
	// page 8's 4th image as global num=24, but `-f 8 -l 8` wrote it as
	// "img-008-002.png" — local index 2, not 24). Matching extracted
	// filenames against candidates MUST use LocalIndex, not Num, or nothing
	// ever matches and every image is silently dropped.
	LocalIndex int
}

// pdfImageListRe matches a data row of `pdfimages -list` (a leading page
// number distinguishes it from the header/dashes/stray-warning lines poppler
// also writes). strings.Fields on a matching line then splits cleanly since
// no field itself contains whitespace.
var pdfImageListRe = regexp.MustCompile(`^\s*\d+\s+\d+\s+\S+`)

// pdfImageList shells poppler's `pdfimages -list` against a PDF already on
// disk — metadata only, no pixel decode, so it is cheap to always run first
// and use to decide WHICH pages are worth the expensive -png pass.
func pdfImageList(ctx context.Context, path string) ([]imgListRow, error) {
	if _, err := exec.LookPath("pdfimages"); err != nil {
		return nil, fmt.Errorf("pdfimages (poppler) not found: %w", err)
	}
	out, err := exec.CommandContext(ctx, "pdfimages", "-list", path).Output()
	if err != nil {
		// pdfimages can exit non-zero on a merely-malformed PDF that still has
		// SOME readable image directory; stdout may still carry rows. Only
		// bail if there's truly nothing to parse.
		if len(out) == 0 {
			return nil, fmt.Errorf("pdfimages -list: %w", err)
		}
	}
	return parseImageList(string(out)), nil
}

// parseImageList is the pure parsing core of pdfImageList — split out so it
// is testable with a captured `pdfimages -list` transcript, no poppler
// binary required. Assigns LocalIndex per page as it goes (see the field doc
// on imgListRow for why this differs from the parsed Num column).
func parseImageList(out string) []imgListRow {
	var rows []imgListRow
	perPage := map[int]int{} // page -> next LocalIndex (counts EVERY row for that page, filtered or not)
	for _, line := range strings.Split(out, "\n") {
		if !pdfImageListRe.MatchString(line) {
			continue // header / dashes / a stray "Syntax Warning: ..." line
		}
		f := strings.Fields(line)
		if len(f) < 11 {
			continue
		}
		page, e1 := strconv.Atoi(f[0])
		num, e2 := strconv.Atoi(f[1])
		w, e3 := strconv.Atoi(f[3])
		h, e4 := strconv.Atoi(f[4])
		if e1 != nil || e2 != nil || e3 != nil || e4 != nil {
			continue
		}
		local := perPage[page]
		perPage[page] = local + 1
		rows = append(rows, imgListRow{Page: page, Num: num, Type: f[2], Width: w, Height: h, Object: f[10], LocalIndex: local})
	}
	return rows
}

// filterImageCandidates applies the metadata-only junk filter (caps.go
// thresholds) to a raw `pdfimages -list` dump — pure and testable without
// poppler. Drops: non-"image" rows (smask/stencil alpha companions — not
// standalone content), anything under minImageDim in either dimension, and
// any object id reused on more than maxObjectRepeats distinct pages (page
// furniture: a repeating background/border/logo). Caps the survivors to
// maxImages (page order), which also bounds how many pages the caller must
// run the expensive -png pass against.
func filterImageCandidates(rows []imgListRow, maxImages int) []imgListRow {
	if maxImages <= 0 {
		maxImages = defaultMaxImages
	}
	// distinct pages per object, across the WHOLE doc (not just "image" rows —
	// a background's smask companion shares the same object and should count
	// toward "this object is reused", even though the smask row itself is
	// separately dropped for being a smask).
	pagesByObject := map[string]map[int]bool{}
	for _, r := range rows {
		if r.Object == "" {
			continue
		}
		if pagesByObject[r.Object] == nil {
			pagesByObject[r.Object] = map[int]bool{}
		}
		pagesByObject[r.Object][r.Page] = true
	}
	var out []imgListRow
	for _, r := range rows {
		if r.Type != "image" {
			continue // smask / stencil mask: an alpha companion, not standalone content
		}
		if r.Width < minImageDim || r.Height < minImageDim {
			continue // too small to be wiki-worthy art (an icon/bullet/rule)
		}
		if r.Object != "" && len(pagesByObject[r.Object]) > maxObjectRepeats {
			continue // page furniture: this exact XObject recurs across many pages
		}
		out = append(out, r)
		if len(out) >= maxImages {
			break
		}
	}
	return out
}

// pdfImageFileRe recovers (page, num) from a pdfimages -p output filename —
// e.g. "img-001-000.png" -> page=1, num=0 — independent of poppler's exact
// zero-padding width (which scales with the SOURCE document's page/image
// counts, not the -f/-l range requested).
var pdfImageFileRe = regexp.MustCompile(`-(\d+)-(\d+)\.(png|jpg|jpeg)$`)

// extractEmbeddedImages runs the two-stage embedded-image pass: `pdfimages
// -list` (free) to find candidates, filterImageCandidates to junk-filter
// them, then a per-PAGE `pdfimages -png -p` targeted at only the surviving
// pages (poppler has no per-object extraction — page range is the finest
// selector it offers), under a wall-clock budget so a heavily-illustrated PDF
// degrades to "partial, capped" rather than blocking the whole document.
func extractEmbeddedImages(ctx context.Context, data []byte, opts Options) ([]EmbeddedImage, error) {
	if _, err := exec.LookPath("pdfimages"); err != nil {
		return nil, fmt.Errorf("pdfimages (poppler) not found: %w", err)
	}
	tmp, err := os.CreateTemp("", "docextract-images-*.pdf")
	if err != nil {
		return nil, fmt.Errorf("temp file: %w", err)
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return nil, fmt.Errorf("write temp: %w", err)
	}
	tmp.Close()

	rows, err := pdfImageList(ctx, tmp.Name())
	if err != nil {
		return nil, err
	}
	candidates := filterImageCandidates(rows, opts.MaxImages)
	if len(candidates) == 0 {
		return nil, nil
	}
	// keyed on (page, LOCAL index) — the identity `pdfimages -p -f N -l N`
	// actually uses in its output filenames (see imgListRow.LocalIndex).
	want := map[[2]int]bool{}
	globalNum := map[[2]int]int{} // (page,localIndex) -> the document-wide Num, for a stable EmbeddedImage.Index
	pageSet := map[int]bool{}
	for _, c := range candidates {
		key := [2]int{c.Page, c.LocalIndex}
		want[key] = true
		globalNum[key] = c.Num
		pageSet[c.Page] = true
	}
	pages := make([]int, 0, len(pageSet))
	for p := range pageSet {
		pages = append(pages, p)
	}
	sort.Ints(pages)

	dir, err := os.MkdirTemp("", "docextract-embimg-*")
	if err != nil {
		return nil, fmt.Errorf("temp dir: %w", err)
	}
	defer os.RemoveAll(dir)
	prefix := filepath.Join(dir, "img")

	budgetSecs := opts.ImageBudgetSecs
	if budgetSecs <= 0 {
		budgetSecs = defaultImageBudgetSecs
	}
	budget := time.Duration(budgetSecs) * time.Second
	start := time.Now()
	var skippedPages int
	for _, p := range pages {
		if time.Since(start) > budget {
			skippedPages = len(pages) - indexOfInt(pages, p)
			break
		}
		cmd := exec.CommandContext(ctx, "pdfimages", "-png", "-p", "-f", strconv.Itoa(p), "-l", strconv.Itoa(p), tmp.Name(), prefix)
		_ = cmd.Run() // a single page's extraction failing shouldn't abort the others; we just won't find its files below
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read image dir: %w", err)
	}
	var out []EmbeddedImage
	for _, e := range entries {
		m := pdfImageFileRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		page, _ := strconv.Atoi(m[1])
		local, _ := strconv.Atoi(m[2]) // this IS a local-per-page index (see imgListRow.LocalIndex) — NOT the -list global num
		key := [2]int{page, local}
		if !want[key] {
			continue // pdfimages -p extracts EVERY image on the page; keep only our surviving candidates
		}
		b, rerr := os.ReadFile(filepath.Join(dir, e.Name()))
		if rerr != nil {
			continue
		}
		w, h, blank := decodedImageStats(b)
		if w < minImageDim || h < minImageDim {
			continue // belt-and-suspenders vs. the -list estimate
		}
		if blank {
			continue // pixel-level safety net: a flat/near-white "image" that slipped the metadata filter
		}
		out = append(out, EmbeddedImage{Page: page, Index: globalNum[key], Width: w, Height: h, PNGBase64: base64.StdEncoding.EncodeToString(b)})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Page != out[j].Page {
			return out[i].Page < out[j].Page
		}
		return out[i].Index < out[j].Index
	})
	if skippedPages > 0 {
		return out, fmt.Errorf("image extraction budget (%ds) reached — %d of %d candidate page(s) not processed", budgetSecs, skippedPages, len(pages))
	}
	return out, nil
}

// indexOfInt returns the index of v in s (used only to size the "skipped"
// count when the budget trips mid-loop).
func indexOfInt(s []int, v int) int {
	for i, x := range s {
		if x == v {
			return i
		}
	}
	return len(s)
}

// decodedImageStats decodes a PNG/JPEG byte slice and reports its real pixel
// dimensions plus whether it is "blank" (flat-color or near-white) — the
// pixel-level half of the junk filter, run AFTER metadata filtering as a
// safety net (e.g. a genuinely full-size but blank table cell background).
func decodedImageStats(b []byte) (w, h int, blank bool) {
	img, _, err := image.Decode(bytes.NewReader(b))
	if err != nil {
		return 0, 0, false // can't assess -> don't second-guess the metadata filter
	}
	bounds := img.Bounds()
	w, h = bounds.Dx(), bounds.Dy()
	return w, h, isFlatOrBlank(img)
}

// isFlatOrBlank subsamples a decimated grid of pixels (bounded cost
// regardless of image size) and reports true when the image is effectively
// decoration: either overwhelmingly near-white, or clustered within
// flatColorTolerance of one dominant color (a solid divider bar, a blank
// table cell). nearWhiteFraction of samples must agree for either case.
func isFlatOrBlank(img image.Image) bool {
	b := img.Bounds()
	const gridN = 24 // ~24x24 samples regardless of source resolution
	stepX := max(1, b.Dx()/gridN)
	stepY := max(1, b.Dy()/gridN)
	var total, nearWhite, nearFlat int
	var r0, g0, b0 int32
	first := true
	for y := b.Min.Y; y < b.Max.Y; y += stepY {
		for x := b.Min.X; x < b.Max.X; x += stepX {
			cr, cg, cb, _ := img.At(x, y).RGBA()
			r8, g8, b8 := int32(cr>>8), int32(cg>>8), int32(cb>>8)
			total++
			if r8 >= nearWhiteChannel && g8 >= nearWhiteChannel && b8 >= nearWhiteChannel {
				nearWhite++
			}
			if first {
				r0, g0, b0 = r8, g8, b8
				first = false
			}
			if abs32(r8-r0) <= flatColorTolerance && abs32(g8-g0) <= flatColorTolerance && abs32(b8-b0) <= flatColorTolerance {
				nearFlat++
			}
		}
	}
	if total == 0 {
		return false
	}
	frac := func(n int) float64 { return float64(n) / float64(total) }
	return frac(nearWhite) >= nearWhiteFraction || frac(nearFlat) >= nearWhiteFraction
}

func abs32(v int32) int32 {
	if v < 0 {
		return -v
	}
	return v
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
