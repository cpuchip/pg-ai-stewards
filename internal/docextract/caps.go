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

	// MaxImages caps how many embedded picture XObjects (pdfimages -png) are
	// extracted per document, AFTER the junk filter. 0 = a small built-in
	// default. Unlike page rendering, embedded-image extraction is NOT gated
	// by AutoRender/RenderPages — it always runs for a PDF (alongside text +
	// page-PNG), the way text always runs; this cap (+ the wall-clock budget
	// below) is what keeps a heavily-illustrated rulebook bounded instead of
	// gating the whole feature behind a flag.
	MaxImages int

	// ImageBudgetSecs overrides the wall-clock budget for the embedded-image
	// phase (0 = defaultImageBudgetSecs, tuned for an interactive upload). A
	// deliberate one-shot backfill run (assets-backfill) can afford a much
	// larger budget to sweep more of a heavily-illustrated document in one
	// pass; an inline chat doc_extract call should stay snappy.
	ImageBudgetSecs int
}

// defaultMaxPages is the built-in pixel-overlay page cap when Options.MaxPages
// is unset — enough for a short doc, bounded for a long one (the router in
// P3d decides whether to render at all based on page count).
const defaultMaxPages = 10

// defaultRenderDPI balances legibility against PNG size for a vision model.
const defaultRenderDPI = 150

// --- embedded-image (wiki-assets) extraction tuning ---
//
// Every threshold below was set against a REAL 94-page TTRPG rulebook (the
// Cosmere RPG beta preview), not a synthetic fixture. `pdfimages -list`
// reported 272 image XObjects; 123 were `smask` alpha-channel companions
// (not standalone content), and ONE repeated full-bleed background object
// (2593×3376) recurred on 90 of the 94 pages — the object-repeat dedup alone
// discards 216 of 272 rows (79%) before a single pixel is decoded. A naive
// `pdfimages -png` blind extraction of all 272 images took OVER 8 minutes
// (re-encoding photographic JPEG-source pages as lossless PNG is expensive);
// a single targeted page (`-f N -l N`) with real content took ~12s. Hence the
// two-stage design: filter on `pdfimages -list` METADATA first (free — no
// pixel decode), THEN extract PNGs only for surviving candidate pages, under
// a wall-clock budget so a pathological/heavily-illustrated PDF degrades to
// "partial, capped" instead of blocking the whole doc-extract run.

// defaultMaxImages caps the number of embedded images PERSISTED per document
// (post-filter). Deliberately modest: these become individually browsable
// wiki assets, not an image dump — a rulebook's real illustrations (as
// opposed to page furniture) tend to number in the dozens, not hundreds.
const defaultMaxImages = 40

// defaultImageBudgetSecs bounds the WALL-CLOCK time spent on the embedded-
// image phase specifically (separate from the overall extraction timeout),
// so a heavily-illustrated PDF can't starve the (more important) text
// extraction of its share of the run's time budget. When the budget is hit,
// already-extracted images are kept and a warning names how many pages were
// skipped — partial results beat none (the same philosophy as a render
// failure never clobbering already-extracted text).
const defaultImageBudgetSecs = 60

// minImageDim: an embedded image narrower or shorter than this (in EITHER
// dimension) is treated as a UI glyph / bullet / rule / small icon, not
// wiki-worthy art. Empirically, the real content in the reference rulebook
// was never smaller than ~360px in its narrow dimension; 100px gives headroom
// without letting through obvious chrome.
const minImageDim = 100

// maxObjectRepeats: a PDF image XObject (identified by its `object` id in
// `pdfimages -list`) that recurs on MORE than this many distinct pages is
// page furniture — a repeating background, border frame, or running-header
// logo — not per-page content. Threshold 2 keeps a genuinely-reused SMALL
// icon (e.g. a rules-callout glyph used twice) while dropping anything that
// functions as a template element. The reference rulebook's background
// object recurred on 90 of 94 pages; a section-banner object recurred 3
// times — both are furniture, not assets.
const maxObjectRepeats = 2

// nearWhiteChannel / nearWhiteFraction: the "blank / decorative" pixel-level
// safety net (applied AFTER decode, on top of the metadata-only filters
// above). A sampled pixel is "near-white" when every channel is >= this
// value; an image where at least this FRACTION of sampled pixels are
// near-white (or all cluster within a small tolerance of one flat color —
// isFlatOrBlank checks both) is decoration (a blank cell, a divider bar, a
// solid-color rule), not content.
const nearWhiteChannel = 250
const nearWhiteFraction = 0.97

// flatColorTolerance: per-channel tolerance (0-255) for the "single flat
// color" half of the blank/decoration check.
const flatColorTolerance = 6
