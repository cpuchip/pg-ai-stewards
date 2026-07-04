package wikiassets

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/cpuchip/pg-ai-stewards/cmd/doc-extract-mcp/runner"
	"github.com/cpuchip/pg-ai-stewards/internal/docextract"
)

// backfillImageBudgetSecs is generous relative to the interactive default
// (60s, caps.go) — a backfill run is a deliberate one-shot sweep Michael
// asked for, not a request a user is waiting on inline, so it can afford to
// spend real minutes getting more of a heavily-illustrated rulebook's art in
// one pass. Still well under the bridge's bulk-call ceiling (540s, RC-3).
const backfillImageBudgetSecs = 240

// BackfillResult summarizes one assets-backfill run.
type BackfillResult struct {
	AttachmentID   int64
	Filename       string
	DocID          string // "" if the source PDF isn't pooled into stewards.docs yet
	CandidatePages int    // distinct pages with a surviving (post-filter) image
	Extracted      int    // images actually decoded + persisted
	Assets         []PersistedImage
	Note           string // e.g. "wiki_assets not yet available" or a partial-budget notice
}

// ResolveSourceAttachment turns a `--doc <ref>` argument into the underlying
// chat_attachments row that holds the ORIGINAL PDF bytes doc-extract needs.
// ref may be:
//   - a bare chat_attachments id (e.g. "98") — the PDF attachment directly;
//   - a stewards.docs slug or id (e.g. a doc_import_corpus chunk like
//     "cosmere-rpg-...-001") — resolved via that doc's `source_object:
//     att:<id>` frontmatter stamp back to the originating attachment.
func ResolveSourceAttachment(ctx context.Context, pool *pgxpool.Pool, ref string) (attachmentID int64, sessionID, filename string, err error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return 0, "", "", fmt.Errorf("a --doc reference is required")
	}
	if n, perr := strconv.ParseInt(ref, 10, 64); perr == nil {
		attachmentID = n
	} else {
		var sourceObj string
		qerr := pool.QueryRow(ctx,
			`SELECT frontmatter->>'source_object' FROM stewards.docs WHERE slug = $1 OR id = $1`,
			ref,
		).Scan(&sourceObj)
		if qerr != nil {
			return 0, "", "", fmt.Errorf("doc %q not found: %w", ref, qerr)
		}
		id, ok := strings.CutPrefix(sourceObj, "att:")
		if !ok || id == "" {
			return 0, "", "", fmt.Errorf("doc %q has no source_object (not imported via doc_import_corpus — nothing to re-extract from)", ref)
		}
		attachmentID, err = strconv.ParseInt(id, 10, 64)
		if err != nil {
			return 0, "", "", fmt.Errorf("doc %q source_object %q is not a valid attachment reference: %w", ref, sourceObj, err)
		}
	}

	if err := pool.QueryRow(ctx,
		`SELECT session_id, filename FROM stewards.chat_attachments WHERE id = $1 AND bytes IS NOT NULL`,
		attachmentID,
	).Scan(&sessionID, &filename); err != nil {
		return 0, "", "", fmt.Errorf("attachment %d not found (or has no stored bytes): %w", attachmentID, err)
	}
	return attachmentID, sessionID, filename, nil
}

// Backfill re-extracts wiki assets from an ALREADY-INGESTED PDF's original
// attachment via the SAME hardened sandbox doc_extract uses — so a rulebook
// imported before this capability existed gets its assets without a re-import.
// Text is re-extracted too (ExtractFile always runs it) but discarded here;
// the point of this verb is the images overlay specifically.
func Backfill(ctx context.Context, pool *pgxpool.Pool, run *runner.Runner, docRef string) (BackfillResult, error) {
	attachmentID, sessionID, filename, err := ResolveSourceAttachment(ctx, pool, docRef)
	if err != nil {
		return BackfillResult{}, err
	}
	res := BackfillResult{AttachmentID: attachmentID, Filename: filename}

	var data []byte
	if err := pool.QueryRow(ctx,
		`SELECT bytes FROM stewards.chat_attachments WHERE id = $1`, attachmentID,
	).Scan(&data); err != nil {
		return res, fmt.Errorf("read attachment %d bytes: %w", attachmentID, err)
	}

	extractRes, _, err := run.Extract(ctx, data, runner.ExtractArgs{
		Filename: filename, AutoRender: false, // page-pixel overlay not needed for an assets-only sweep
		Caps: docextract.DefaultArchiveCaps(), TimeoutSecs: backfillImageBudgetSecs + 60,
		ImageBudgetSecs: backfillImageBudgetSecs,
	})
	if err != nil {
		return res, fmt.Errorf("sandbox extraction failed: %w", err)
	}
	if extractRes.Mode != "file" || len(extractRes.Files) == 0 {
		return res, fmt.Errorf("expected a single-file extraction result for a PDF backfill, got mode=%q files=%d", extractRes.Mode, len(extractRes.Files))
	}
	fr := extractRes.Files[0]

	pages := map[int]bool{}
	for _, im := range fr.Images {
		pages[im.Page] = true
	}
	res.CandidatePages = len(pages)

	docID, ok, derr := ResolveDocID(ctx, pool, attachmentID)
	if derr != nil {
		return res, derr
	}
	if ok {
		res.DocID = docID
	} else {
		res.Note = "source PDF is not yet pooled into stewards.docs (doc_import_corpus not run) — assets persisted as chat attachments but NOT linked into wiki_assets; re-run assets-backfill after importing to backfill the links"
	}

	persisted, perr := PersistImages(ctx, pool, sessionID, filename, attachmentID, res.DocID, fr.Images)
	res.Assets = persisted
	res.Extracted = len(persisted)
	if perr != nil {
		return res, perr
	}
	if fr.Error != "" {
		if res.Note != "" {
			res.Note += "; "
		}
		res.Note += "extractor note: " + fr.Error
	}
	return res, nil
}
