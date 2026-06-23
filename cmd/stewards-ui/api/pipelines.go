// pipelines endpoints — Batch G.4.4.
// Surfaces stewards.pipelines for the NewWork form's dynamic dropdown
// + file_destination_template prefill.

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

func (d *Deps) registerPipelines(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/pipelines/list", d.pipelinesListHandler)
	mux.HandleFunc("GET /api/pipelines/get", d.pipelinesGetHandler)
}

// pipelineStage is one entry in a pipeline's ordered plan (Stewdio P2 renders
// these as the plan=progress checklist against a work item's stage_results).
type pipelineStage struct {
	Name        string `json:"name"`
	Next        string `json:"next,omitempty"`
	AgentFamily string `json:"agent_family,omitempty"`
	Model       string `json:"model,omitempty"`
}

type pipelineDetail struct {
	Family      string          `json:"family"`
	Description string          `json:"description"`
	Stages      []pipelineStage `json:"stages"`
}

// GET /api/pipelines/get?family=X — the pipeline's ordered stages (the "plan").
func (d *Deps) pipelinesGetHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	fam := r.URL.Query().Get("family")
	if fam == "" {
		writeErr(w, http.StatusBadRequest, "family query param required")
		return
	}
	var desc string
	var stagesJSON []byte
	if err := d.Pool.QueryRow(ctx,
		`SELECT coalesce(description, ''), stages FROM stewards.pipelines WHERE family = $1`, fam,
	).Scan(&desc, &stagesJSON); err != nil {
		writeErr(w, http.StatusNotFound, "pipeline not found: "+err.Error())
		return
	}
	resp := pipelineDetail{Family: fam, Description: desc, Stages: []pipelineStage{}}
	_ = json.Unmarshal(stagesJSON, &resp.Stages) // stages is a jsonb array in declared order
	writeJSON(w, http.StatusOK, resp)
}

type pipelineRow struct {
	Family                  string `json:"family"`
	Description             string `json:"description"`
	SabbathEnabled          bool   `json:"sabbath_enabled"`
	AtonementEnabled        bool   `json:"atonement_enabled"`
	FileDestinationTemplate string `json:"file_destination_template,omitempty"`
	FileContentJsonpath     string `json:"file_content_jsonpath,omitempty"`
}

type pipelinesListResp struct {
	Items []pipelineRow `json:"items"`
	Total int           `json:"total"`
}

func (d *Deps) pipelinesListHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	rows, err := d.Pool.Query(ctx, `
		SELECT family, coalesce(description, ''),
		       coalesce(sabbath_enabled, false),
		       coalesce(atonement_enabled, false),
		       coalesce(file_destination_template, ''),
		       coalesce(file_content_jsonpath, '')
		  FROM stewards.pipelines
		  ORDER BY family`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()

	resp := pipelinesListResp{Items: []pipelineRow{}}
	for rows.Next() {
		var p pipelineRow
		if err := rows.Scan(&p.Family, &p.Description,
			&p.SabbathEnabled, &p.AtonementEnabled,
			&p.FileDestinationTemplate, &p.FileContentJsonpath); err == nil {
			resp.Items = append(resp.Items, p)
		}
	}
	resp.Total = len(resp.Items)
	writeJSON(w, http.StatusOK, resp)
}
