// MCP tool surface for doc-extract-mcp. One tool, `doc_extract`, drives the
// whole capability: read an attachment's bytes -> spawn the hardened sandbox ->
// write back safe subject material. It is deterministic (no LLM in the loop)
// and DB-aware so the bytes never leave the server.
package main

import (
	"context"
	"encoding/base64"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/cpuchip/pg-ai-stewards/cmd/doc-extract-mcp/runner"
	"github.com/cpuchip/pg-ai-stewards/internal/docextract"
)

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
}

type docExtractInput struct {
	AttachmentID int64 `json:"attachment_id" jsonschema:"The chat_attachments id of the uploaded document"`
	Render       bool  `json:"render,omitempty" jsonschema:"Also render page images (pixel overlay) for the vision model — costs a vision call per page (PDF only in v1)"`
	MaxPages     int   `json:"max_pages,omitempty" jsonschema:"Cap rendered pages when render=true (0 = default 10)"`
}

type docExtractOutput struct {
	AttachmentID   int64    `json:"attachment_id"`
	Mode           string   `json:"mode"`              // file | archive
	DocType        string   `json:"doc_type,omitempty"`
	ExtractedChars int      `json:"extracted_chars"`
	ScanVerdict    string   `json:"scan_verdict"`
	ScanFindings   []string `json:"scan_findings,omitempty"`
	Quarantined    bool     `json:"quarantined,omitempty"`
	PageImageIDs   []int64  `json:"page_image_ids,omitempty"`
	Members        int      `json:"members,omitempty"`
	Summary        string   `json:"summary"`
}

func makeDocExtract(run *runner.Runner, pool *pgxpool.Pool) func(context.Context, *mcp.CallToolRequest, docExtractInput) (*mcp.CallToolResult, docExtractOutput, error) {
	return func(ctx context.Context, _ *mcp.CallToolRequest, in docExtractInput) (*mcp.CallToolResult, docExtractOutput, error) {
		if in.AttachmentID <= 0 {
			return errResult("attachment_id is required"), docExtractOutput{}, nil
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
			return errResult("attachment %d not found: %v", in.AttachmentID, err), docExtractOutput{}, nil
		}
		if len(data) == 0 {
			return errResult("attachment %d has no bytes", in.AttachmentID), docExtractOutput{}, nil
		}

		// Spawn the hardened sandbox.
		res, stderr, err := run.Extract(ctx, data, runner.ExtractArgs{
			Filename: filename, Render: in.Render, MaxPages: in.MaxPages,
			Caps: docextract.DefaultArchiveCaps(),
		})
		if err != nil {
			return errResult("extraction failed: %v", err), docExtractOutput{}, nil
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
				return errResult("write extracted: %v", err), docExtractOutput{}, nil
			}
			out.ExtractedChars = len(text)
			// Pixel overlay -> child image attachments under this document.
			if len(fr.Pages) > 0 {
				ids, perr := writePageImages(ctx, pool, in.AttachmentID, sessionID, filename, fr.Pages)
				if perr != nil {
					return errResult("write page images: %v", perr), docExtractOutput{}, nil
				}
				out.PageImageIDs = ids
			}
			out.Summary = fileSummary(filename, fr, len(out.PageImageIDs))

		case "archive":
			manifest, verdict, findings := archiveManifest(filename, res)
			out.Members = len(res.Files)
			out.ScanVerdict = verdict
			out.ScanFindings = findings
			scan := docextract.ScanResult{Verdict: verdict, Findings: findings, Engine: "clamav+structural"}
			if err := writeExtracted(ctx, pool, in.AttachmentID, manifest, scan); err != nil {
				return errResult("write archive manifest: %v", err), docExtractOutput{}, nil
			}
			out.ExtractedChars = len(manifest)
			out.Summary = fmt.Sprintf("archive %q: %d member(s) unpacked + scanned (verdict %s). Surfaced as a folder tree in the conversation; use doc_import_corpus to persist it as a searchable project.",
				filename, len(res.Files), verdict)

		default:
			return errResult("unexpected converter mode %q", res.Mode), docExtractOutput{}, nil
		}

		return nil, out, nil
	}
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
