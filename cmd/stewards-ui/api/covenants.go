// covenants endpoint — single active read. Phase 5d (C.7).
// Backs Stewards-UI /covenants route. Read-only; YAML is canonical
// (D-C2) so create/edit happens in .spec/covenant.yaml + git commit.

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

func (d *Deps) registerCovenants(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/covenants/active", d.covenantsActiveHandler)
	mux.HandleFunc("GET /api/covenants/list", d.covenantsListHandler)
}

type covenantRow struct {
	ID                string          `json:"id"`
	Scope             string          `json:"scope"`
	HumanCommitsTo    json.RawMessage `json:"human_commits_to"`
	AgentCommitsTo    json.RawMessage `json:"agent_commits_to"`
	WhenBroken        string          `json:"when_broken,omitempty"`
	Recovery          string          `json:"recovery,omitempty"`
	CouncilMoment     string          `json:"council_moment,omitempty"`
	TeachingExtension json.RawMessage `json:"teaching_extension,omitempty"`
	ActivatedAt       *time.Time      `json:"activated_at,omitempty"`
	DeactivatedAt     *time.Time      `json:"deactivated_at,omitempty"`
	RatifiedBy        string          `json:"ratified_by"`
	SourceFile        string          `json:"source_file,omitempty"`
}

func (d *Deps) covenantsActiveHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	scope := r.URL.Query().Get("scope")
	if scope == "" {
		scope = "global"
	}

	var (
		c            covenantRow
		teachingNull bool
	)
	err := d.Pool.QueryRow(ctx, `
		SELECT id::text, scope, human_commits_to, agent_commits_to,
		       coalesce(when_broken, ''), coalesce(recovery, ''),
		       coalesce(council_moment, ''),
		       teaching_extension IS NULL,
		       coalesce(teaching_extension, '{}'::jsonb),
		       activated_at, deactivated_at, ratified_by,
		       coalesce(source_file, '')
		  FROM stewards.covenants
		 WHERE scope = $1 AND deactivated_at IS NULL
		 ORDER BY activated_at DESC
		 LIMIT 1`,
		scope,
	).Scan(&c.ID, &c.Scope, &c.HumanCommitsTo, &c.AgentCommitsTo,
		&c.WhenBroken, &c.Recovery, &c.CouncilMoment,
		&teachingNull, &c.TeachingExtension,
		&c.ActivatedAt, &c.DeactivatedAt, &c.RatifiedBy, &c.SourceFile)
	if err != nil {
		// No active covenant for this scope is a normal state (a fresh
		// database before .spec/covenant.yaml has been seeded, or a scope
		// that was never ratified) — a 404 carrying a raw pgx error string
		// ("no rows in result set") read as a broken page (war-game
		// 2026-07-07, finding #2). 200 + null lets the UI render a clean
		// empty state instead of an error banner.
		writeJSON(w, http.StatusOK, nil)
		return
	}
	if teachingNull {
		c.TeachingExtension = nil
	}
	writeJSON(w, http.StatusOK, c)
}

type covenantsListResp struct {
	Items []covenantRow `json:"items"`
	Total int           `json:"total"`
}

func (d *Deps) covenantsListHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	resp := covenantsListResp{Items: []covenantRow{}}
	rows, err := d.Pool.Query(ctx, `
		SELECT id::text, scope, human_commits_to, agent_commits_to,
		       coalesce(when_broken, ''), coalesce(recovery, ''),
		       coalesce(council_moment, ''),
		       teaching_extension IS NULL,
		       coalesce(teaching_extension, '{}'::jsonb),
		       activated_at, deactivated_at, ratified_by,
		       coalesce(source_file, '')
		  FROM stewards.covenants
		  ORDER BY activated_at DESC
	`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	for rows.Next() {
		var c covenantRow
		var teachingNull bool
		if err := rows.Scan(&c.ID, &c.Scope, &c.HumanCommitsTo, &c.AgentCommitsTo,
			&c.WhenBroken, &c.Recovery, &c.CouncilMoment,
			&teachingNull, &c.TeachingExtension,
			&c.ActivatedAt, &c.DeactivatedAt, &c.RatifiedBy, &c.SourceFile); err == nil {
			if teachingNull {
				c.TeachingExtension = nil
			}
			resp.Items = append(resp.Items, c)
		}
	}
	resp.Total = len(resp.Items)
	writeJSON(w, http.StatusOK, resp)
}
