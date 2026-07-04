// Package wikiassets is the bridge-side persistence + backfill logic for the
// wiki-assets capability (the 6-builder wiki fleet, 2026-07-03 — Michael's
// ask: "any source we give it with images, web pages, pdfs (like our ttrpg
// rule books) could pull all those out and make them usable in the wiki").
//
// It sits between internal/docextract (the sandboxed converter core, which
// now also extracts embedded PDF picture XObjects — see extract.go's
// extractEmbeddedImages) and stewards.wiki_assets (a table owned by
// WIKI-CORE, 92-wiki.sql — NOT created by this package).
//
// Shared by two callers so the logic lives in exactly one place:
//   - cmd/doc-extract-mcp (the doc_extract MCP tool, for a live upload)
//   - cmd/stewards-mcp (the `assets-backfill` CLI verb, for an
//     ALREADY-INGESTED document that predates this capability)
//
// STORAGE CONVENTION (matches 48-chat-attachments / generate_image exactly —
// no new storage mechanism, and matches 92-wiki.sql's REAL wiki_assets shape,
// not the storage_path sketch this package assumed before main's fleet
// merge): an asset's bytes live in stewards.chat_attachments (kind='image',
// parent_id = the source document's attachment, the same pattern doc-
// extract-mcp already uses for rendered page images). wiki_assets links to
// that row via source_attachment_id (bigint) rather than duplicating bytes
// into wiki_assets.bytes; the servable URL is always
// '/api/chat/attachment/<source_attachment_id>' — the ui/bridge already
// serves this with no new auth surface (cmd/stewards-ui/api/chat.go:
// chatAttachmentHandler). wiki_assets.doc_id is text (matches
// stewards.docs.id, itself text — NOT uuid).
package wikiassets

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/cpuchip/pg-ai-stewards/internal/docextract"
)

// undefinedTable is Postgres SQLSTATE 42P01 — "relation does not exist". Used
// to detect a wiki_assets INSERT running BEFORE WIKI-CORE's migration has
// landed, so this package degrades gracefully (images still persist as chat
// attachments; only the wiki_assets linkage is skipped) instead of failing
// the whole extraction.
const undefinedTable = "42P01"

// isUndefinedTable reports whether err is Postgres' "relation does not
// exist" — the expected, graceful failure mode while WIKI-CORE's
// wiki_assets migration hasn't been applied to this database yet.
func isUndefinedTable(err error) bool {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.Code == undefinedTable
	}
	return false
}

// PersistedImage is one embedded image after it has been written to durable
// storage — the chat_attachments id it now lives at (for immediate serving)
// plus, when wiki_assets was reachable, the wiki asset id it was linked to.
type PersistedImage struct {
	AttachmentID  int64
	AssetID       int64 // wiki_assets.id (bigserial); 0 if wiki_assets wasn't reachable or no doc_id resolved
	Page          int
	Width, Height int
	ServeURL      string // /api/chat/attachment/<id> — the convention every caller should embed
}

// PersistImages writes extracted embedded images through the EXISTING
// attachment storage convention (chat_attachments, kind='image', parented to
// the source document — the same shape writePageImages already uses for
// rendered pages) and, when a doc_id can be resolved, links each one into
// stewards.wiki_assets (kind='image', page_no where known). Best-effort on
// the wiki_assets half: a database that doesn't have that table yet (WIKI-
// CORE's migration not applied) still gets working, servable chat
// attachments — the wiki linkage is simply skipped and noted.
//
// docID is the stewards.docs.id (a UUID stored as text) this image
// illustrates, or "" if unresolved (ResolveDocID below finds it from the
// source attachment's pooled corpus membership). parentAttachmentID is the
// original PDF's chat_attachments row; sessionID should match its
// session_id so the image can also ride chat_attachment_parts if that
// session is ever revisited (the existing page-image convention).
func PersistImages(
	ctx context.Context,
	pool *pgxpool.Pool,
	sessionID, filenameBase string,
	parentAttachmentID int64,
	docID string,
	images []docextract.EmbeddedImage,
) ([]PersistedImage, error) {
	if len(images) == 0 {
		return nil, nil
	}
	base := filenameBase
	if i := strings.LastIndexByte(base, '.'); i > 0 {
		base = base[:i]
	}
	var out []PersistedImage
	var wikiAssetsUnavailable bool
	for _, img := range images {
		png, derr := base64.StdEncoding.DecodeString(img.PNGBase64)
		if derr != nil {
			continue // corrupt base64 shouldn't abort the rest of the batch
		}
		var attID int64
		fn := fmt.Sprintf("%s-p%d-i%d.png", base, img.Page, img.Index)
		if err := pool.QueryRow(ctx,
			`INSERT INTO stewards.chat_attachments
			    (session_id, filename, mime_type, kind, bytes, byte_size, parent_id)
			 VALUES ($1, $2, 'image/png', 'image', $3, $4, $5)
			 RETURNING id`,
			sessionID, fn, png, len(png), parentAttachmentID,
		).Scan(&attID); err != nil {
			return out, fmt.Errorf("persist embedded image (page %d, idx %d): %w", img.Page, img.Index, err)
		}
		pi := PersistedImage{
			AttachmentID: attID, Page: img.Page, Width: img.Width, Height: img.Height,
			ServeURL: fmt.Sprintf("/api/chat/attachment/%d", attID),
		}
		if docID != "" && !wikiAssetsUnavailable {
			var assetID int64
			// doc_id is text (matches stewards.docs.id); source_attachment_id
			// links to the chat_attachments row just written above instead of
			// duplicating bytes into wiki_assets.bytes (92-wiki.sql's REAL
			// convention — see this package's header).
			err := pool.QueryRow(ctx,
				`INSERT INTO stewards.wiki_assets (doc_id, kind, source_attachment_id, mime_type, byte_size, page_no)
				 VALUES ($1, 'image', $2, 'image/png', $3, $4)
				 RETURNING id`,
				docID, attID, len(png), img.Page,
			).Scan(&assetID)
			switch {
			case err == nil:
				pi.AssetID = assetID
			case isUndefinedTable(err):
				// WIKI-CORE's table isn't live yet on this database — degrade
				// gracefully for the REST of this batch too (no point retrying
				// per-image); the chat attachment above still serves fine.
				wikiAssetsUnavailable = true
			default:
				return out, fmt.Errorf("link wiki_asset (attachment %d): %w", attID, err)
			}
		}
		out = append(out, pi)
	}
	return out, nil
}

// ResolveDocID finds the stewards.docs row a chat_attachments PDF was pooled
// into (via doc_import_corpus's `source_object: att:<id>` frontmatter stamp
// — see cmd/doc-extract-mcp/tools.go importCorpusFn). A document imported as
// a multi-chunk corpus has MANY docs rows; this returns the FIRST chunk
// (lowest slug — chunk slugs are zero-padded, e.g. "-001", "-002", … so
// lexical order IS chunk order) as the single canonical anchor a wiki asset
// links to. Returns ("", false, nil) when the attachment hasn't been pooled
// yet (doc_import_corpus not yet run on it) — not an error, just "not linkable yet".
func ResolveDocID(ctx context.Context, pool *pgxpool.Pool, attachmentID int64) (string, bool, error) {
	var docID string
	err := pool.QueryRow(ctx,
		`SELECT id FROM stewards.docs
		  WHERE frontmatter->>'source_object' = $1
		  ORDER BY slug ASC LIMIT 1`,
		fmt.Sprintf("att:%d", attachmentID),
	).Scan(&docID)
	if err != nil {
		if strings.Contains(err.Error(), "no rows") {
			return "", false, nil
		}
		return "", false, fmt.Errorf("resolve doc for attachment %d: %w", attachmentID, err)
	}
	return docID, true, nil
}
