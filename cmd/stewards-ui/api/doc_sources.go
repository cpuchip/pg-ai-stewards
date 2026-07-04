// doc_sources.go — "show the wiki the agent pulled" (Michael, WIKI-GRAPH
// mission): a doc/study's PULLED SOURCES rendered as a mini-wiki, plus a
// blind-spot diff against the full corpus scope. Backs a "Sources pulled"
// tab on ArtifactPanel (Stewdio) and StudyDetail (/studies/:slug).
//
// ★ Contract note (2026-07-03), same caveat as wiki.go: `stewards.doc_pull_sources
// (doc uuid)` and `stewards.doc_blind_spots(doc uuid, scope jsonb)` are owned by
// WIKI-CORE (92), a parallel builder that had not landed in this checkout as of
// this file's writing (no such functions found in extension/*.sql). Both handlers
// gate on availability and decode generically (scanRowsGeneric, wiki.go) since
// this agent has not seen the real result-set shape — only that doc_blind_spots
// "returns coverage rows + coverage_pct". Once 92 lands, if the coverage_pct
// extraction heuristic below (best row-level match) is wrong, it's a local fix.
package api

import (
	"context"
	"net/http"
	"strings"
	"time"
)

func (d *Deps) registerDocSources(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/doc/pull-sources", d.docPullSourcesHandler)
	mux.HandleFunc("GET /api/doc/blind-spots", d.docBlindSpotsHandler)
}

func (d *Deps) docPullSourcesFnAvailable(ctx context.Context) bool {
	var reg *string
	if err := d.Pool.QueryRow(ctx,
		`SELECT to_regprocedure('stewards.doc_pull_sources(uuid)')::text`).Scan(&reg); err != nil {
		return false
	}
	return reg != nil
}

func (d *Deps) docBlindSpotsFnAvailable(ctx context.Context) bool {
	var reg *string
	if err := d.Pool.QueryRow(ctx,
		`SELECT to_regprocedure('stewards.doc_blind_spots(uuid,jsonb)')::text`).Scan(&reg); err != nil {
		return false
	}
	return reg != nil
}

// resolveDocID — docs.id is a text column holding a generated UUID string
// (extension/src/schema.rs: `id text PRIMARY KEY DEFAULT gen_random_uuid()::text`),
// so callers may hand us either the slug or the id itself; either resolves here.
func (d *Deps) resolveDocID(ctx context.Context, ref string) (string, error) {
	var id string
	err := d.Pool.QueryRow(ctx,
		`SELECT id FROM stewards.docs WHERE slug = $1 OR id = $1 LIMIT 1`, ref).Scan(&id)
	return id, err
}

// GET /api/doc/pull-sources?doc=<slug-or-id>
func (d *Deps) docPullSourcesHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	ref := strings.TrimSpace(r.URL.Query().Get("doc"))
	if ref == "" {
		writeErr(w, http.StatusBadRequest, "doc query param required (slug or doc id)")
		return
	}
	if !d.docPullSourcesFnAvailable(ctx) {
		writeJSON(w, http.StatusOK, map[string]any{"available": false, "sources": []map[string]any{}})
		return
	}
	docID, err := d.resolveDocID(ctx, ref)
	if err != nil {
		writeErr(w, http.StatusNotFound, "doc not found: "+err.Error())
		return
	}
	rows, err := d.Pool.Query(ctx, `SELECT * FROM stewards.doc_pull_sources($1::uuid)`, docID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "doc_pull_sources: "+err.Error())
		return
	}
	defer rows.Close()
	out, err := scanRowsGeneric(rows)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "doc_pull_sources scan: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"available": true, "sources": out})
}

// GET /api/doc/blind-spots?doc=<slug-or-id>&scope=<json>
func (d *Deps) docBlindSpotsHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	ref := strings.TrimSpace(r.URL.Query().Get("doc"))
	if ref == "" {
		writeErr(w, http.StatusBadRequest, "doc query param required (slug or doc id)")
		return
	}
	if !d.docBlindSpotsFnAvailable(ctx) {
		writeJSON(w, http.StatusOK, map[string]any{"available": false, "rows": []map[string]any{}})
		return
	}
	docID, err := d.resolveDocID(ctx, ref)
	if err != nil {
		writeErr(w, http.StatusNotFound, "doc not found: "+err.Error())
		return
	}
	scope := strings.TrimSpace(r.URL.Query().Get("scope"))
	if scope == "" {
		scope = "{}"
	}
	rows, err := d.Pool.Query(ctx, `SELECT * FROM stewards.doc_blind_spots($1::uuid, $2::jsonb)`, docID, scope)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "doc_blind_spots: "+err.Error())
		return
	}
	defer rows.Close()
	out, err := scanRowsGeneric(rows)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "doc_blind_spots scan: "+err.Error())
		return
	}
	// coverage_pct — a best-effort single number for the banner. If every row
	// carries the same value under a `coverage_pct` key (the natural shape for
	// "a summary number repeated on each coverage row"), surface it once at the
	// top level; otherwise leave it absent and let the UI show per-row detail.
	var coveragePct any
	if len(out) > 0 {
		if v, ok := out[0]["coverage_pct"]; ok {
			coveragePct = v
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"available": true, "rows": out, "coverage_pct": coveragePct,
	})
}
