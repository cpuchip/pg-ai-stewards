// The Lab surface — /api/lab/*. Experiments (declare-once A/B rows) + the
// standing golden-case regression suite (87-lab.sql). Thin passthroughs to
// jsonb-returning SQL verbs, same shape as a2a.go/hinge.go — the SQL owns
// the shape, the Go handler just wires the HTTP verb + params through.

package api

import "net/http"

func (d *Deps) registerLab(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/lab/experiments", d.labExperimentsHandler)
	mux.HandleFunc("GET /api/lab/regression-runs", d.labRegressionRunsHandler)
	mux.HandleFunc("GET /api/lab/regression-runs/detail", d.labRegressionRunDetailHandler)
	mux.HandleFunc("POST /api/lab/regression-run", d.labRegressionRunNowHandler)
}

// GET /api/lab/experiments — every experiment + its run_count.
func (d *Deps) labExperimentsHandler(w http.ResponseWriter, r *http.Request) {
	d.a2aQuery(w, r, `SELECT stewards.lab_experiments_list()`)
}

// GET /api/lab/regression-runs?limit=20 — the most recent N runs (rollup).
func (d *Deps) labRegressionRunsHandler(w http.ResponseWriter, r *http.Request) {
	limit := r.URL.Query().Get("limit")
	if limit == "" {
		limit = "20"
	}
	d.a2aQuery(w, r, `SELECT stewards.lab_regression_runs_list($1::int)`, limit)
}

// GET /api/lab/regression-runs/detail?run_id=... — per-case results for one
// run, for the failure-detail expansion.
func (d *Deps) labRegressionRunDetailHandler(w http.ResponseWriter, r *http.Request) {
	runID := r.URL.Query().Get("run_id")
	if runID == "" {
		writeErr(w, http.StatusBadRequest, "run_id query param is required")
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.lab_regression_run_detail($1)`, runID)
}

// POST /api/lab/regression-run — the "Run regression now" button. Fires the
// whole golden-case suite synchronously and returns the summary; a failure
// also lands in the hinge queue (kind=lab-regression-failure) and the
// lab_regression_failures view, independent of this response.
func (d *Deps) labRegressionRunNowHandler(w http.ResponseWriter, r *http.Request) {
	d.a2aQuery(w, r, `SELECT stewards.lab_regression_run()`)
}
