package wikiassets

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"path"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/cpuchip/pg-ai-stewards/cmd/doc-extract-mcp/runner"
	"github.com/cpuchip/pg-ai-stewards/internal/docextract"
)

// maxWebImageBytes caps a downloaded web image before it ever reaches the
// sandbox — a cheap pre-filter against a pathological/hostile response
// (a "png" that's actually a gigabyte of junk) on top of the sandbox's own
// resource limits (runner.Runner's --memory/--pids-limit).
const maxWebImageBytes = 32 << 20 // 32 MB — generous for real web art, not for abuse

// DownloadAndPersistWebImage is the web-page half of the wiki-assets
// capability (extension/96-wiki-assets.sql, task 1's "web-page ingestion"
// leg). fetch_url/fetch_urls (cmd/fetch-md-mcp) DISCOVER <img> URLs but never
// download bytes — no DB, no sandbox there. This function is the download
// step, and it deliberately does NOT trust the bytes just because they
// carried an image/* content-type: it pipes them through the SAME hardened,
// --network=none doc-extract sandbox (runner.Runner) that scans every PDF
// upload (clamav + structural), before ever writing them to durable storage.
// A malicious/quarantined response is refused, not persisted.
//
// docID (a stewards.docs id, or "" if the source page isn't pooled yet) is
// used the same way PersistImages uses it — best-effort wiki_assets linkage,
// gracefully skipped if the table isn't live yet. sessionID scopes the
// resulting chat_attachments row (so it can ride chat_attachment_parts like
// any other image if that session is ever revisited); pass whatever session
// the ingestion caller is working in (e.g. the wiki dump/curator's own).
func DownloadAndPersistWebImage(
	ctx context.Context,
	pool *pgxpool.Pool,
	run *runner.Runner,
	httpClient *http.Client,
	imageURL string,
	sessionID string,
	docID string,
) (PersistedImage, error) {
	imageURL = strings.TrimSpace(imageURL)
	if imageURL == "" {
		return PersistedImage{}, fmt.Errorf("imageURL is required")
	}
	if httpClient == nil {
		httpClient = http.DefaultClient
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, imageURL, nil)
	if err != nil {
		return PersistedImage{}, fmt.Errorf("build request: %w", err)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return PersistedImage{}, fmt.Errorf("download %s: %w", imageURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return PersistedImage{}, fmt.Errorf("download %s: HTTP %d", imageURL, resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxWebImageBytes+1))
	if err != nil {
		return PersistedImage{}, fmt.Errorf("read %s: %w", imageURL, err)
	}
	if len(data) == 0 {
		return PersistedImage{}, fmt.Errorf("%s returned no bytes", imageURL)
	}
	if len(data) > maxWebImageBytes {
		return PersistedImage{}, fmt.Errorf("%s exceeds the %d MB web-image cap", imageURL, maxWebImageBytes>>20)
	}

	filename := path.Base(imageURL)
	if i := strings.IndexAny(filename, "?#"); i >= 0 {
		filename = filename[:i]
	}
	if filename == "" || filename == "." || filename == "/" {
		filename = "web-image"
	}

	// THE TRUST FLOOR: the same sandbox every PDF upload gets — --network=none,
	// clamav + structural scan — before this URL's bytes are treated as safe.
	extractRes, _, err := run.Extract(ctx, data, runner.ExtractArgs{Filename: filename})
	if err != nil {
		return PersistedImage{}, fmt.Errorf("sandbox scan of %s failed: %w", imageURL, err)
	}
	if len(extractRes.Files) == 0 {
		return PersistedImage{}, fmt.Errorf("sandbox scan of %s returned no result", imageURL)
	}
	fr := extractRes.Files[0]
	if fr.Scan.Verdict == docextract.VerdictMalicious || fr.Skipped {
		return PersistedImage{}, fmt.Errorf("refused: %s was flagged malicious by the security scan (%s)", imageURL, fr.Scan.Signature)
	}

	var attID int64
	if err := pool.QueryRow(ctx,
		`INSERT INTO stewards.chat_attachments
		    (session_id, filename, mime_type, kind, bytes, byte_size, scan_verdict, scan_findings)
		 VALUES ($1, $2, $3, 'image', $4, $5, $6, NULLIF($7,''))
		 RETURNING id`,
		sessionID, filename, fr.MimeType, data, len(data), fr.Scan.Verdict, strings.Join(fr.Scan.Findings, ","),
	).Scan(&attID); err != nil {
		return PersistedImage{}, fmt.Errorf("persist web image: %w", err)
	}

	pi := PersistedImage{
		AttachmentID: attID,
		ServeURL:     fmt.Sprintf("/api/chat/attachment/%d", attID),
	}
	if docID != "" {
		var assetID int64
		err := pool.QueryRow(ctx,
			`INSERT INTO stewards.wiki_assets (doc_id, kind, source_attachment_id, mime_type, byte_size)
			 VALUES ($1, 'image', $2, $3, $4)
			 RETURNING id`,
			docID, attID, fr.MimeType, len(data),
		).Scan(&assetID)
		switch {
		case err == nil:
			pi.AssetID = assetID
		case isUndefinedTable(err):
			// WIKI-CORE's table not live yet — the attachment above still serves.
		default:
			return pi, fmt.Errorf("link wiki_asset for web image %s: %w", imageURL, err)
		}
	}
	return pi, nil
}
