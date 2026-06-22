// rig endpoints — control + state for the local inference rig (llama-chip).
//
// Lets the operator free the GPUs for other work (games), bring the brain
// back, and pause/resume autonomy from the substrate UI — without a terminal.
// The UI backend reaches llama-chip over host.docker.internal:8090 (the same
// path the substrate's flexllama provider uses), so the browser needs no CORS.

package api

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"time"
)

func (d *Deps) registerRig(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/rig/state", d.rigStateHandler)
	mux.HandleFunc("POST /api/rig/autonomy", d.rigAutonomyHandler)
	mux.HandleFunc("POST /api/rig/brain-on", d.rigBrainOnHandler)
	mux.HandleFunc("POST /api/rig/brain-off", d.rigBrainOffHandler)
}

var rigClient = &http.Client{Timeout: 8 * time.Second}

func llamaChipURL() string {
	if u := os.Getenv("LLAMACHIP_URL"); u != "" {
		return u
	}
	return "http://host.docker.internal:8090"
}

func rigGet(ctx context.Context, path string) (map[string]any, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, llamaChipURL()+path, nil)
	resp, err := rigClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var out map[string]any
	_ = json.Unmarshal(b, &out)
	return out, nil
}

func rigPost(ctx context.Context, path string, body any) error {
	var buf []byte
	if body != nil {
		buf, _ = json.Marshal(body)
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, llamaChipURL()+path, bytes.NewReader(buf))
	req.Header.Set("Content-Type", "application/json")
	resp, err := rigClient.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

func (d *Deps) autonomyPaused(ctx context.Context) bool {
	var paused bool
	_ = d.Pool.QueryRow(ctx,
		`SELECT coalesce((SELECT value::text='true' FROM stewards.config WHERE key='autonomy_paused'), false)`,
	).Scan(&paused)
	return paused
}

func (d *Deps) setAutonomyPaused(ctx context.Context, paused bool) error {
	v := "false"
	if paused {
		v = "true"
	}
	_, err := d.Pool.Exec(ctx,
		`UPDATE stewards.config SET value=$1::jsonb WHERE key='autonomy_paused'`, v)
	return err
}

type rigStateResp struct {
	AutonomyPaused bool   `json:"autonomy_paused"`
	LlamaChipUp    bool   `json:"llamachip_up"`
	Models         []any  `json:"models"`
	GPUs           []any  `json:"gpus"`
	Note           string `json:"note,omitempty"`
}

// rigStateHandler reports autonomy state + whether llama-chip is up, which
// models are loaded, and live GPU usage.
func (d *Deps) rigStateHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 9*time.Second)
	defer cancel()
	resp := rigStateResp{Models: []any{}, GPUs: []any{}}
	resp.AutonomyPaused = d.autonomyPaused(ctx)
	if st, err := rigGet(ctx, "/api/status"); err == nil && st != nil {
		resp.LlamaChipUp = true
		if slots, ok := st["slots"].([]any); ok {
			resp.Models = slots
		}
	} else {
		resp.Note = "llama-chip not reachable at " + llamaChipURL()
	}
	if g, err := rigGet(ctx, "/api/gpu"); err == nil && g != nil {
		if gpus, ok := g["gpus"].([]any); ok {
			resp.GPUs = gpus
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

// rigAutonomyHandler pauses/resumes autonomy only (leaves models as-is).
func (d *Deps) rigAutonomyHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	var body struct {
		Paused bool `json:"paused"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	if err := d.setAutonomyPaused(ctx, body.Paused); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"autonomy_paused": body.Paused})
}

// rigBrainOnHandler loads the dance profile and resumes autonomy.
func (d *Deps) rigBrainOnHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	if err := rigPost(ctx, "/api/profile", map[string]string{"name": "dance"}); err != nil {
		writeErr(w, http.StatusBadGateway, "llama-chip unreachable (start it first): "+err.Error())
		return
	}
	_ = d.setAutonomyPaused(ctx, false)
	writeJSON(w, http.StatusOK, map[string]any{"status": "brain-on", "autonomy_paused": false})
}

// rigBrainOffHandler pauses autonomy then unloads all models (frees the GPUs).
func (d *Deps) rigBrainOffHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	// Pause first so nothing dispatches into a half-unloaded rig.
	if err := d.setAutonomyPaused(ctx, true); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if err := rigPost(ctx, "/api/unload-all", nil); err != nil {
		writeErr(w, http.StatusBadGateway, "autonomy paused, but llama-chip unload failed: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "brain-off", "autonomy_paused": true})
}
