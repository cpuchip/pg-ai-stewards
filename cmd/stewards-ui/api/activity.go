// Model Activity endpoint — GET /api/activity
//
// Read-only introspection across ALL inference providers (not just the
// local rig): which model is doing which work right now, and the token
// counts behind each dispatch. The operator's "what's the brain doing,
// and on which model/GPU?" glance.
//
// Three SQL pieces + one best-effort rig probe, all queried in parallel:
//   - active:      in_progress work_items, each tagged with the model/
//                  provider of its most-recent cost_event and its summed
//                  token + spend totals.
//   - recent:      the last ~25 cost_events (newest first) as a dispatch
//                  pulse — the per-call record across every provider.
//   - by_provider: cost_events in the last 24h grouped by provider+model,
//                  busiest (by total tokens) first.
//   - gpu_by_model: best-effort model->GPU map from the local rig
//                  (llama-chip). Empty when the rig is unreachable — the
//                  feature never fails on the rig probe.
//
// SELECT-only. Never writes. Mirrors the goroutine-fanout style of
// dashboard.go and the rig HTTP client of rig.go.

package api

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
)

type activityResponse struct {
	Active      []activeWork      `json:"active"`
	Recent      []recentDispatch  `json:"recent"`
	ByProvider  []providerRollup  `json:"by_provider"`
	Tools       []toolActivity    `json:"tools"` // non-LLM: doc-extract / coder sandbox / scan calls
	GPUByModel  map[string]string `json:"gpu_by_model"`
	GeneratedAt string            `json:"generated_at"`
}

// toolActivity is one non-LLM tool dispatch — a doc-extract run (ClamAV scan +
// unpack, in its own container), a coder sandbox op, etc. The "what's the box
// doing that ISN'T a model call" view: each mcp_proxy work_queue row spawns a
// container/tool, so this is the sandbox/scan pulse alongside the model stream.
type toolActivity struct {
	Tool   string     `json:"tool"`
	Server string     `json:"server"`
	Status string     `json:"status"` // pending | in_progress | done | error (work_queue status)
	Error  string     `json:"error,omitempty"`
	At     *time.Time `json:"at,omitempty"`
	RunMs  int64      `json:"run_ms,omitempty"` // claimed→done (or →now if running)
}

// activeWork is one in_progress work_item, enriched with the model/
// provider of its latest dispatch and its lifetime token + spend totals.
type activeWork struct {
	Slug      string     `json:"slug"`
	Pipeline  string     `json:"pipeline"`
	Stage     string     `json:"stage"`
	Intent    string     `json:"intent"`
	Model     string     `json:"model"`
	Provider  string     `json:"provider"`
	Tokens    int64      `json:"tokens"`
	MicroUSD  int64      `json:"micro_usd"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
	GPU       string     `json:"gpu,omitempty"`
	Local     bool       `json:"local"`
}

// recentDispatch is one cost_event — the per-call record across providers.
type recentDispatch struct {
	Provider  string     `json:"provider"`
	Model     string     `json:"model"`
	Pipeline  string     `json:"pipeline"`
	Slug      string     `json:"slug"`
	Session   string     `json:"session,omitempty"` // the chat/build session, when not a work-item
	Label     string     `json:"label"`             // human "what was this call for"
	InTokens  int64      `json:"in_tokens"`
	OutTokens int64      `json:"out_tokens"`
	MicroUSD  int64      `json:"micro_usd"`
	At        *time.Time `json:"at,omitempty"`
}

// dispatchLabel turns a cost_event's work-item slug / session id into a short
// human "what was this call for" — so the activity feed reads as work, not just
// a model name. Work-item slug wins; otherwise the session id is decoded by its
// prefix (the dispatcher's deterministic naming).
func dispatchLabel(pipeline, slug, session string) string {
	if slug != "" {
		if pipeline != "" {
			return pipeline + " · " + slug
		}
		return slug
	}
	s := strings.TrimSpace(session)
	if s == "" {
		return "—"
	}
	switch {
	case strings.HasPrefix(s, "world-build-"):
		return "🌍 world build: " + strings.TrimPrefix(s, "world-build-")
	case strings.HasPrefix(s, "stewdio-"):
		return "💬 chat: " + strings.TrimPrefix(s, "stewdio-")
	case strings.HasPrefix(s, "watchman-"):
		return "👁 watchman"
	default:
		return s
	}
}

// providerRollup is a 24h provider+model usage summary.
type providerRollup struct {
	Provider  string `json:"provider"`
	Model     string `json:"model"`
	Calls     int64  `json:"calls"`
	InTokens  int64  `json:"in_tokens"`
	OutTokens int64  `json:"out_tokens"`
	MicroUSD  int64  `json:"micro_usd"`
}

// localProviders are the GPU-backed providers on this box. Used to mark
// active rows local=true and to drive the GPU badge.
var localProviders = map[string]bool{
	"flexllama": true,
	"lm_studio": true,
}

func (d *Deps) registerActivity(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/activity", d.activityHandler)
}

func (d *Deps) activityHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()

	resp := activityResponse{
		Active:      []activeWork{},
		Recent:      []recentDispatch{},
		ByProvider:  []providerRollup{},
		Tools:       []toolActivity{},
		GPUByModel:  map[string]string{},
		GeneratedAt: time.Now().Format(time.RFC3339),
	}

	var wg sync.WaitGroup
	wg.Add(5)

	// active — in_progress work_items, latest dispatch model/provider +
	// summed tokens/spend across each item's cost_events.
	go func() {
		defer wg.Done()
		rows, err := d.Pool.Query(ctx,
			`SELECT wi.slug,
			        wi.pipeline_family,
			        wi.current_stage,
			        coalesce(i.slug, '')                                   AS intent,
			        coalesce((SELECT ce.model    FROM stewards.cost_events ce
			                   WHERE ce.work_item_id = wi.id
			                   ORDER BY ce.at DESC LIMIT 1), '')           AS model,
			        coalesce((SELECT ce.provider FROM stewards.cost_events ce
			                   WHERE ce.work_item_id = wi.id
			                   ORDER BY ce.at DESC LIMIT 1), '')           AS provider,
			        coalesce((SELECT sum(ce.input_tokens + ce.output_tokens)
			                    FROM stewards.cost_events ce
			                   WHERE ce.work_item_id = wi.id), 0)          AS tokens,
			        coalesce((SELECT sum(ce.micro_dollars)
			                    FROM stewards.cost_events ce
			                   WHERE ce.work_item_id = wi.id), 0)          AS micro_usd,
			        wi.updated_at
			   FROM stewards.work_items wi
			   LEFT JOIN stewards.intents i ON i.id = wi.intent_id
			  WHERE wi.status = 'in_progress'
			  ORDER BY wi.updated_at DESC NULLS LAST
			  LIMIT 50`,
		)
		if err != nil {
			return
		}
		defer rows.Close()
		for rows.Next() {
			var a activeWork
			if err := rows.Scan(&a.Slug, &a.Pipeline, &a.Stage, &a.Intent,
				&a.Model, &a.Provider, &a.Tokens, &a.MicroUSD, &a.UpdatedAt); err == nil {
				a.Local = localProviders[a.Provider]
				resp.Active = append(resp.Active, a)
			}
		}
	}()

	// recent — last ~25 cost_events, newest first, joined to their
	// work_item for pipeline + slug context.
	go func() {
		defer wg.Done()
		rows, err := d.Pool.Query(ctx,
			`SELECT ce.provider,
			        ce.model,
			        coalesce(wi.pipeline_family, '') AS pipeline,
			        coalesce(wi.slug, '')            AS slug,
			        coalesce(ce.session_id, '')      AS session,
			        coalesce(ce.input_tokens, 0),
			        coalesce(ce.output_tokens, 0),
			        coalesce(ce.micro_dollars, 0),
			        ce.at
			   FROM stewards.cost_events ce
			   LEFT JOIN stewards.work_items wi ON wi.id = ce.work_item_id
			  ORDER BY ce.at DESC
			  LIMIT 25`,
		)
		if err != nil {
			return
		}
		defer rows.Close()
		for rows.Next() {
			var rd recentDispatch
			if err := rows.Scan(&rd.Provider, &rd.Model, &rd.Pipeline, &rd.Slug, &rd.Session,
				&rd.InTokens, &rd.OutTokens, &rd.MicroUSD, &rd.At); err == nil {
				rd.Label = dispatchLabel(rd.Pipeline, rd.Slug, rd.Session)
				resp.Recent = append(resp.Recent, rd)
			}
		}
	}()

	// by_provider — 24h usage grouped by provider+model, busiest first.
	go func() {
		defer wg.Done()
		rows, err := d.Pool.Query(ctx,
			`SELECT provider,
			        model,
			        count(*)                          AS calls,
			        coalesce(sum(input_tokens), 0)    AS in_tokens,
			        coalesce(sum(output_tokens), 0)   AS out_tokens,
			        coalesce(sum(micro_dollars), 0)   AS micro_usd
			   FROM stewards.cost_events
			  WHERE at > now() - interval '24 hours'
			  GROUP BY provider, model
			  ORDER BY (coalesce(sum(input_tokens), 0) + coalesce(sum(output_tokens), 0)) DESC
			  LIMIT 50`,
		)
		if err != nil {
			return
		}
		defer rows.Close()
		for rows.Next() {
			var p providerRollup
			if err := rows.Scan(&p.Provider, &p.Model, &p.Calls,
				&p.InTokens, &p.OutTokens, &p.MicroUSD); err == nil {
				resp.ByProvider = append(resp.ByProvider, p)
			}
		}
	}()

	// tools — recent NON-LLM tool dispatches (mcp_proxy work_queue rows): each
	// is a doc-extract run (ClamAV scan + unpack in its own container), a coder
	// sandbox op, etc. The "what's the box doing that isn't a model call" pulse —
	// in_progress rows are live containers; an errored row shows e.g. a doc-extract
	// timeout, which would otherwise look like a silent stall.
	go func() {
		defer wg.Done()
		rows, err := d.Pool.Query(ctx,
			`SELECT coalesce(payload->>'tool',''),
			        coalesce(payload->>'server',''),
			        status,
			        coalesce(error,''),
			        coalesce(done_at, claimed_at, created_at),
			        CASE WHEN claimed_at IS NOT NULL
			             THEN (extract(epoch FROM coalesce(done_at, now()) - claimed_at) * 1000)::bigint
			             ELSE 0 END
			   FROM stewards.work_queue
			  WHERE kind = 'mcp_proxy'
			  ORDER BY coalesce(done_at, claimed_at, created_at) DESC
			  LIMIT 20`,
		)
		if err != nil {
			return
		}
		defer rows.Close()
		for rows.Next() {
			var t toolActivity
			if err := rows.Scan(&t.Tool, &t.Server, &t.Status, &t.Error, &t.At, &t.RunMs); err == nil {
				if t.Tool == "" {
					t.Tool = "tool"
				}
				resp.Tools = append(resp.Tools, t)
			}
		}
	}()

	// gpu_by_model — best-effort from the local rig. Never errors the
	// endpoint; an unreachable rig just yields an empty map.
	go func() {
		defer wg.Done()
		resp.GPUByModel = d.rigGPUByModel(ctx)
	}()

	wg.Wait()

	// Fill GPU badges on active rows now that both the active list and the
	// rig map are populated.
	for i := range resp.Active {
		if gpu, ok := resp.GPUByModel[resp.Active[i].Model]; ok {
			resp.Active[i].GPU = gpu
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

// rigGPUByModel reads the local rig state (the same /api/status the rig
// view proxies) and builds a model-name -> "GPU<n>" map. The rig reports
// loaded "slots", each with a `name` (the model alias the substrate
// dispatches to, e.g. "qwen3.6-35b-a3b") and a `gpus` array of device
// indices. Best-effort: any shape surprise or unreachable rig returns an
// empty map rather than failing the activity endpoint.
func (d *Deps) rigGPUByModel(ctx context.Context) map[string]string {
	out := map[string]string{}
	st, err := rigGet(ctx, "/api/status")
	if err != nil || st == nil {
		return out
	}
	slots, ok := st["slots"].([]any)
	if !ok {
		return out
	}
	for _, s := range slots {
		slot, ok := s.(map[string]any)
		if !ok {
			continue
		}
		name, _ := slot["name"].(string)
		if name == "" {
			continue
		}
		gpus, ok := slot["gpus"].([]any)
		if !ok || len(gpus) == 0 {
			continue
		}
		// JSON numbers decode to float64. Use the first GPU index as the
		// badge; multi-GPU slots are rare and the first is representative.
		idx, ok := gpus[0].(float64)
		if !ok {
			continue
		}
		out[name] = fmt.Sprintf("GPU%d", int(idx))
	}
	return out
}
