// models endpoint — list of provider+model pairs the substrate knows
// about, with prices and provider-default flag. Used by:
//   - Brainstorm.vue per-lens model override <datalist> autocompletion
//   - Models.vue dedicated catalog browse view
// Pulls from model_pricing (the authoritative cost table) and joins
// providers_loaded() to mark which model is each provider's default.

package api

import (
	"context"
	"net/http"
	"strconv"
	"time"
)

func (d *Deps) registerModels(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/models", d.modelsHandler)
	mux.HandleFunc("GET /api/models/aliases", d.modelAliasesHandler)   // role aliases → provider/model members
	mux.HandleFunc("GET /api/models/probe-status", d.probeStatusHandler) // inline probe verdict (poll after /api/models/probe)
}

type probeStatusResp struct {
	QueueStatus  string  `json:"queue_status"`            // work_queue status: pending|in_progress|waiting_for_tools|done|error ("" if no id given)
	QueueError   string  `json:"queue_error,omitempty"`   // dispatch error when the probe row failed
	Usable       *bool   `json:"usable,omitempty"`        // model_capability verdict (nil = never probed)
	ProbeDetail  string  `json:"probe_detail,omitempty"`  // the verdict note or error
	ProbedVia    string  `json:"probed_via,omitempty"`    // seed | manual | auto-probe
	LastProbedAt *string `json:"last_probed_at,omitempty"`
	Done         bool    `json:"done"` // queue row reached a terminal state — stop polling
}

// GET /api/models/probe-status?provider=&model=&work_queue_id=
// The read side of the probe button: the queue row's live status (so the UI can
// show "probing…") plus the model_capability verdict the terminal-transition
// trigger writes on done/error (so the UI can show ✓ usable / ✗ with the
// reason) — inline, no hunting for the catalog row below.
func (d *Deps) probeStatusHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	provider := r.URL.Query().Get("provider")
	model := r.URL.Query().Get("model")
	if provider == "" || model == "" {
		writeErr(w, http.StatusBadRequest, "provider and model are required")
		return
	}
	workID, _ := strconv.ParseInt(r.URL.Query().Get("work_queue_id"), 10, 64)

	resp := probeStatusResp{}

	if workID > 0 {
		var status string
		var qErr *string
		if err := d.Pool.QueryRow(ctx,
			`SELECT status, error FROM stewards.work_queue WHERE id = $1`,
			workID).Scan(&status, &qErr); err == nil {
			resp.QueueStatus = status
			if qErr != nil {
				resp.QueueError = *qErr
			}
			resp.Done = status == "done" || status == "error"
		}
	}

	// The verdict the probe records (usable + detail). Absent until the first
	// probe of this (provider, model) lands.
	var usable *bool
	var detail, via *string
	var lastProbed *time.Time
	if err := d.Pool.QueryRow(ctx,
		`SELECT usable, probe_detail, probed_via, last_probed_at
		   FROM stewards.model_capability
		  WHERE provider = $1 AND model = $2`,
		provider, model).Scan(&usable, &detail, &via, &lastProbed); err == nil {
		resp.Usable = usable
		if detail != nil {
			resp.ProbeDetail = *detail
		}
		if via != nil {
			resp.ProbedVia = *via
		}
		if lastProbed != nil {
			s := lastProbed.UTC().Format(time.RFC3339)
			resp.LastProbedAt = &s
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

type aliasRow struct {
	Alias    string `json:"alias"`
	Provider string `json:"provider"`
	Model    string `json:"model"`
	Priority int    `json:"priority"`
	Usable   *bool  `json:"usable,omitempty"`
	Enabled  bool   `json:"enabled"`
	IsLocal  bool   `json:"is_local"`
	Notes    string `json:"notes,omitempty"`
}

// GET /api/models/aliases — the role aliases (reason / ingest / critic / vision /
// …) and the provider+model members each resolves to, lowest-priority first
// (the preferred member). usable comes from model_capability's last probe;
// enabled (95) is the operator's own on/off switch for this member — the one
// pick_alias_member actually skips on. is_local flags lm_studio/flexllama
// (the same localProviders convention activity.go uses) so the cockpit can
// group/badge local members and drive the "rest all local models" action.
// Backs the Stewdio Models panel + the Roles section on the Models view.
func (d *Deps) modelAliasesHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	rows, err := d.Pool.Query(ctx, `
		SELECT a.alias, a.provider, a.provider_model, a.priority, coalesce(a.notes,''), c.usable, a.enabled
		  FROM stewards.model_aliases a
		  LEFT JOIN stewards.model_capability c
		    ON c.provider = a.provider AND c.model = a.provider_model
		 ORDER BY a.alias, a.priority, a.provider`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	out := []aliasRow{}
	for rows.Next() {
		var a aliasRow
		if rows.Scan(&a.Alias, &a.Provider, &a.Model, &a.Priority, &a.Notes, &a.Usable, &a.Enabled) == nil {
			a.IsLocal = localProviders[a.Provider]
			out = append(out, a)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"aliases": out})
}

type modelRow struct {
	Provider             string `json:"provider"`
	Model                string `json:"model"`
	InputMicroPerMtok    int64  `json:"input_micro_per_mtok"`
	OutputMicroPerMtok   int64  `json:"output_micro_per_mtok"`
	CacheWriteMicroPerMtok *int64 `json:"cache_write_micro_per_mtok,omitempty"`
	CacheReadMicroPerMtok  *int64 `json:"cache_read_micro_per_mtok,omitempty"`
	IsProviderDefault    bool   `json:"is_provider_default"`
	Notes                string `json:"notes,omitempty"`
}

type modelsResp struct {
	Items []modelRow `json:"items"`
	Total int        `json:"total"`
}

func (d *Deps) modelsHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	// LEFT JOIN providers_loaded so a model without a matching live
	// provider still appears (catalog rows can outlive provider state).
	// Latest pricing only — model_pricing PK is (provider, model,
	// effective_at) so DISTINCT ON pulls the most recent row per pair.
	rows, err := d.Pool.Query(ctx, `
		SELECT DISTINCT ON (mp.provider, mp.model)
		       mp.provider, mp.model,
		       mp.input_micro_per_mtok, mp.output_micro_per_mtok,
		       mp.cache_write_micro_per_mtok, mp.cache_read_micro_per_mtok,
		       (pl.default_model IS NOT NULL
		         AND pl.default_model = mp.model) AS is_provider_default,
		       COALESCE(mp.notes, '')
		  FROM stewards.model_pricing mp
		  LEFT JOIN stewards.providers_loaded() pl
		    ON pl.name = mp.provider
		 ORDER BY mp.provider, mp.model, mp.effective_at DESC`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()

	resp := modelsResp{Items: []modelRow{}}
	for rows.Next() {
		var m modelRow
		if err := rows.Scan(&m.Provider, &m.Model,
			&m.InputMicroPerMtok, &m.OutputMicroPerMtok,
			&m.CacheWriteMicroPerMtok, &m.CacheReadMicroPerMtok,
			&m.IsProviderDefault, &m.Notes); err == nil {
			resp.Items = append(resp.Items, m)
		}
	}
	resp.Total = len(resp.Items)
	writeJSON(w, http.StatusOK, resp)
}
