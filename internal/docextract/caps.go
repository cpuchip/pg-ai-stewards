package docextract

// ArchiveCaps are the load-bearing guardrails for unpacking an untrusted
// archive (proposal §3.5). 7z's very high compression ratio makes
// decompression bombs nastier, so the ratio + size ceilings matter. These
// are conservative defaults; the converter exposes them as flags so the
// operator can tune them.
type ArchiveCaps struct {
	MaxTotalUncompressed int64 // total bytes written across all members (default 200 MB)
	MaxEntrySize         int64 // largest single member, uncompressed (default 50 MB)
	MaxEntries           int   // number of members processed (default 1000)
	MaxRatio             int   // uncompressed/compressed ceiling — the bomb guard (default 200)
	RecurseNested        bool  // recurse into a contained archive? default false — surface it as a file
}

// DefaultArchiveCaps returns the ratified conservative defaults (§9 open
// questions, resolved here): 200 MB total / 50 MB per entry / 1000 entries /
// 200:1 ratio / do NOT auto-recurse nested archives.
func DefaultArchiveCaps() ArchiveCaps {
	return ArchiveCaps{
		MaxTotalUncompressed: 200 << 20,
		MaxEntrySize:         50 << 20,
		MaxEntries:           1000,
		MaxRatio:             200,
		RecurseNested:        false,
	}
}

// Options controls one extract run (a single file or an archive of files).
type Options struct {
	// Filename is the original name (used for type detection by extension when
	// magic bytes are ambiguous — docx/xlsx/pptx all share the zip magic).
	Filename string

	// RenderPages FORCES the pixel overlay (poppler pdftoppm) regardless of
	// length — "render all pages" up to MaxPages. Off by default.
	RenderPages bool

	// AutoRender is the router default (proposal §3): render the pixel overlay
	// for a SHORT doc (page count <= MaxPages) but not a long one — text always,
	// pixels for visual/short docs. Set by the doc_extract tool so a short PDF
	// yields both text and page images while a 200-page report stays text-only.
	AutoRender bool

	// MaxPages caps how many pages get rendered to pixels (the per-doc cost
	// ceiling, §9). 0 = a small built-in default. Text is never capped.
	MaxPages int

	// DPI for page rendering (poppler). 0 = a sane default (150).
	RenderDPI int

	// ClamAVDB is the path to the ClamAV signature database directory (mounted
	// read-only in the sandbox). Empty disables the signature scan (the
	// structural scan still runs — engine "structural-only").
	ClamAVDB string

	// Caps bound archive unpacking. Zero value uses DefaultArchiveCaps.
	Caps ArchiveCaps
}

// defaultMaxPages is the built-in pixel-overlay page cap when Options.MaxPages
// is unset — enough for a short doc, bounded for a long one (the router in
// P3d decides whether to render at all based on page count).
const defaultMaxPages = 10

// defaultRenderDPI balances legibility against PNG size for a vision model.
const defaultRenderDPI = 150
