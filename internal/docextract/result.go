// Package docextract turns untrusted documents into model-readable subject
// material — plain markdown text (always) and, optionally, rendered page
// pixels — under a four-layer defense (scan -> contain -> disarm-by-non-
// execution -> content-gate). See .spec/proposals/doc-extract-sandbox.md.
//
// This package is the deterministic CONVERTER core. It is pure Go for the
// parts that matter for safety (the structural scan, the archive caps, the
// path-safety checks) so they are exhaustively unit-testable WITHOUT Docker —
// the oracle floor. The only non-Go dependencies are external binaries the
// converter shells out to inside the hardened container: `clamscan` (the
// ClamAV signature engine) and `pdftoppm` (poppler, PDF -> pixels). When
// those binaries or their data are absent (e.g. on a dev host running the
// unit tests), the code degrades gracefully — text extraction (tabula, pure
// Go) and the structural scan still run.
//
// The converter binary (cmd/doc-extract) runs INSIDE the sandbox; the MCP
// server (cmd/doc-extract-mcp) runs on the bridge and spawns the sandbox,
// feeds it the bytes, and reads this Result back from stdout.
package docextract

// Result is the JSON the converter emits on stdout for one extract run.
// A single document produces Mode="file" with one FileResult; an archive
// produces Mode="archive" with one FileResult per member (a folder tree).
type Result struct {
	Mode     string       `json:"mode"`               // "file" | "archive"
	Files    []FileResult `json:"files"`              // one per document / archive member
	Warnings []string     `json:"warnings,omitempty"` // run-level notes (e.g. caps hit, engine degraded)
}

// FileResult is the extraction outcome for a single document (or one archive
// member). Text is always populated for a readable doc; Pages is the additive
// pixel overlay (rendered only when requested and the doc is renderable).
type FileResult struct {
	Path      string      `json:"path"`                  // member path within an archive, or the filename
	MimeType  string      `json:"mime_type,omitempty"`   // best-effort content type
	DocType   string      `json:"doc_type,omitempty"`    // pdf|docx|xlsx|pptx|odt|epub|html|text|image|archive|unknown
	Text      string      `json:"text,omitempty"`        // extracted markdown (the always-on path)
	WordCount int         `json:"word_count,omitempty"`  // words in Text
	Pages     []PageImage `json:"pages,omitempty"`       // rendered page bitmaps (the pixel overlay)
	Scan      ScanResult  `json:"scan"`                  // the four-layer defense, layer 1
	Skipped   bool        `json:"skipped,omitempty"`     // quarantined (malicious) — bytes never parsed for content
	Error     string      `json:"error,omitempty"`       // extraction error (member failures don't abort the run)
}

// PageImage is one rendered page as a base64 PNG — a dumb RGB bitmap that
// carries nothing executable forward (the Dangerzone pixel round-trip).
type PageImage struct {
	Page      int    `json:"page"`       // 1-based page number
	PNGBase64 string `json:"png_base64"` // PNG bytes, base64 (no MIME line-wrapping)
}

// Scan verdicts. Policy (proposal §5): malicious -> quarantine (do NOT extract
// content); suspicious -> flag to the user but still extract (safe — layer 3
// never executes the payload); clean -> extract.
const (
	VerdictClean      = "clean"
	VerdictSuspicious = "suspicious"
	VerdictMalicious  = "malicious"
)

// ScanResult is layer 1 of the defense: a signature scan (ClamAV) plus a
// pure-Go structural maldoc check. Two independent detectors (defense in
// depth, the ratified scanner combo (c)); the structural half is technique-
// based so it does not rot when the ClamAV DB is briefly stale.
type ScanResult struct {
	Verdict   string   `json:"verdict"`             // clean | suspicious | malicious
	Signature string   `json:"signature,omitempty"` // ClamAV signature name (when malicious by signature)
	Findings  []string `json:"findings,omitempty"`  // structural findings (e.g. "pdf:/OpenAction", "ooxml:vbaProject.bin")
	Engine    string   `json:"engine"`              // which detectors actually ran (e.g. "clamav+structural", "structural-only")
}
