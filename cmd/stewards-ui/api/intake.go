// intake endpoints.
//
// POST /api/intake — thin wrapper over the substrate's
// stewards.route_intake() (99-route-intake.sql, raw-to-wiki): drop a video,
// a website, a file, or a piece of text and have it auto-sorted into the
// right world/wiki/project (or propose a new one, gated for Michael's
// approval). File drops reuse the EXISTING /api/chat/attach upload path —
// the UI uploads first, then passes the returned attachment id as ref.
// See .spec/proposals/ingestion-crawler-and-raw-to-wiki.md Part 2.
//
// GET /api/intake/drops + GET /api/intake/summary — the read surface over
// stewards.file_drops (v28, the ingest-by-drop provenance ledger). Until
// these existed the ledger had ZERO UI: a binary drop that failed on a
// stock install (doc-extract overlay absent → exit 125) landed as a
// status='error' row nobody could see without psql (war-game 2026-07-07,
// SKEPTIC attack #1; SYNTHESIS: "no failure without a face"). Backs the
// Library → Intake tab and the Dashboard intake chip. Read-only.

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

func (d *Deps) registerIntake(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/intake", d.intakeHandler)
	mux.HandleFunc("GET /api/intake/drops", d.intakeDropsHandler)
	mux.HandleFunc("GET /api/intake/summary", d.intakeSummaryHandler)
}

type intakeReq struct {
	Kind        string `json:"kind"` // url | file | video | text
	Ref         string `json:"ref"`  // the url, a chat_attachments id (as text), or a doc slug
	Instruction string `json:"instruction,omitempty"`
}

type intakeResp struct {
	WorkItemID string `json:"work_item_id"`
}

var validIntakeKinds = map[string]bool{"url": true, "file": true, "video": true, "text": true}

func (d *Deps) intakeHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	var req intakeReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "decode body: "+err.Error())
		return
	}
	req.Kind = strings.ToLower(strings.TrimSpace(req.Kind))
	req.Ref = strings.TrimSpace(req.Ref)
	if !validIntakeKinds[req.Kind] {
		writeErr(w, http.StatusBadRequest, "kind must be one of url|file|video|text")
		return
	}
	if req.Ref == "" {
		writeErr(w, http.StatusBadRequest, "ref is required (a url, an attachment id, or a doc slug)")
		return
	}

	var instructionArg any = nil
	if strings.TrimSpace(req.Instruction) != "" {
		instructionArg = req.Instruction
	}

	var newID string
	err := d.Pool.QueryRow(ctx,
		`SELECT stewards.route_intake($1, $2, $3)::text`,
		req.Kind, req.Ref, instructionArg,
	).Scan(&newID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "route_intake: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, intakeResp{WorkItemID: newID})
}

// =====================================================================
// file_drops read surface — the drop ledger's face.
// =====================================================================

type fileDropRow struct {
	ID          int64      `json:"id"`
	Path        string     `json:"path"`
	ProjectHint string     `json:"project_hint,omitempty"`
	RoutedTo    string     `json:"routed_to,omitempty"`
	Status      string     `json:"status"` // ingested | skipped_unchanged | error
	Error       string     `json:"error,omitempty"`
	SizeBytes   int64      `json:"size_bytes"`
	FirstSeenAt *time.Time `json:"first_seen_at,omitempty"`
	IngestedAt  *time.Time `json:"ingested_at,omitempty"`
}

type intakeDropsResp struct {
	Items      []fileDropRow `json:"items"`
	Total      int           `json:"total"`
	ErrorCount int           `json:"error_count"`
}

var validDropStatuses = map[string]bool{
	"ingested": true, "skipped_unchanged": true, "error": true,
}

// GET /api/intake/drops?status=&limit=&offset= — the drop ledger, newest
// first. Mirrors the Studies list pattern (count + page). status filters
// to one of the three ledger states; error_count always reports the
// unfiltered error total so the tab can badge it regardless of filter.
func (d *Deps) intakeDropsHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	q := r.URL.Query()
	status := strings.TrimSpace(q.Get("status"))
	if status != "" && !validDropStatuses[status] {
		writeErr(w, http.StatusBadRequest, "status must be one of ingested|skipped_unchanged|error")
		return
	}
	limit := atoiDefault(q.Get("limit"), 100, 1, 500)
	offset := atoiDefault(q.Get("offset"), 0, 0, 1_000_000)

	resp := intakeDropsResp{Items: []fileDropRow{}}

	// Counts first — total honors the filter; error_count never does.
	countQ := `SELECT count(*),
	                  (SELECT count(*) FROM stewards.file_drops WHERE status = 'error')
	             FROM stewards.file_drops`
	countArgs := []any{}
	if status != "" {
		countQ += ` WHERE status = $1`
		countArgs = append(countArgs, status)
	}
	if err := d.Pool.QueryRow(ctx, countQ, countArgs...).Scan(&resp.Total, &resp.ErrorCount); err != nil {
		writeErr(w, http.StatusInternalServerError, "count: "+err.Error())
		return
	}

	sel := `SELECT id, path,
	               coalesce(project_hint, ''),
	               coalesce(routed_to, ''),
	               status,
	               coalesce(error, ''),
	               coalesce(size_bytes, 0),
	               first_seen_at, ingested_at
	          FROM stewards.file_drops`
	args := []any{}
	if status != "" {
		sel += ` WHERE status = $1`
		args = append(args, status)
	}
	args = append(args, limit)
	limitPh := itoa(len(args))
	args = append(args, offset)
	offsetPh := itoa(len(args))
	sel += ` ORDER BY first_seen_at DESC, id DESC LIMIT $` + limitPh + ` OFFSET $` + offsetPh

	rows, err := d.Pool.Query(ctx, sel, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "list: "+err.Error())
		return
	}
	defer rows.Close()
	for rows.Next() {
		var fd fileDropRow
		if err := rows.Scan(&fd.ID, &fd.Path, &fd.ProjectHint, &fd.RoutedTo,
			&fd.Status, &fd.Error, &fd.SizeBytes,
			&fd.FirstSeenAt, &fd.IngestedAt); err == nil {
			resp.Items = append(resp.Items, fd)
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

type intakeSummaryResp struct {
	DropsToday int        `json:"drops_today"`
	ErrorCount int        `json:"error_count"`
	Total      int        `json:"total"`
	LastDropAt *time.Time `json:"last_drop_at,omitempty"`
}

// GET /api/intake/summary — the Dashboard chip's one cheap read: drops
// first seen today, current error rows (all-time — an error row stays
// 'error' until the file is re-sighted, so old errors are still live
// failures), and the last drop time.
func (d *Deps) intakeSummaryHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	var s intakeSummaryResp
	if err := d.Pool.QueryRow(ctx,
		`SELECT count(*) FILTER (WHERE first_seen_at >= date_trunc('day', now())),
		        count(*) FILTER (WHERE status = 'error'),
		        count(*),
		        max(first_seen_at)
		   FROM stewards.file_drops`,
	).Scan(&s.DropsToday, &s.ErrorCount, &s.Total, &s.LastDropAt); err != nil {
		writeErr(w, http.StatusInternalServerError, "summary: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s)
}
