// world.go — Loreworks knowledge-graph endpoints backing the Stewdio 3D World
// panel. world_graph(slug) returns the {nodes,links} JSONB directly; we pass it
// through. include_refs=1 enriches nodes with source_refs + degree for the
// click-detail drawer (one round-trip for the demo). A thin /node endpoint
// serves one entity's full detail (typed edges + provenance) for lazy loads.

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

func (d *Deps) registerWorld(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/world/list", d.worldListHandler)
	mux.HandleFunc("GET /api/world/graph", d.worldGraphHandler)
	mux.HandleFunc("GET /api/world/node", d.worldNodeHandler)
}

func (d *Deps) worldListHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	rows, err := d.Pool.Query(ctx,
		`SELECT w.slug, w.name, coalesce(w.summary,''), w.is_private,
		        (SELECT count(*) FROM stewards.world_entities e WHERE e.world_id = w.world_id) AS entity_count,
		        (SELECT count(*) FROM stewards.world_edges    g WHERE g.world_id = w.world_id) AS edge_count
		   FROM stewards.worlds w
		  ORDER BY w.updated_at DESC NULLS LAST`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	type worldRow struct {
		Slug        string `json:"slug"`
		Name        string `json:"name"`
		Summary     string `json:"summary"`
		IsPrivate   bool   `json:"is_private"`
		EntityCount int64  `json:"entity_count"`
		EdgeCount   int64  `json:"edge_count"`
	}
	out := []worldRow{}
	for rows.Next() {
		var x worldRow
		if err := rows.Scan(&x.Slug, &x.Name, &x.Summary, &x.IsPrivate, &x.EntityCount, &x.EdgeCount); err == nil {
			out = append(out, x)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out})
}

func (d *Deps) worldGraphHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	slug := r.URL.Query().Get("slug")
	if slug == "" {
		writeErr(w, http.StatusBadRequest, "slug required")
		return
	}
	var raw []byte
	if err := d.Pool.QueryRow(ctx, `SELECT stewards.world_graph($1)`, slug).Scan(&raw); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if len(raw) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"nodes": []any{}, "links": []any{}})
		return
	}
	if r.URL.Query().Get("include_refs") != "1" {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_, _ = w.Write(raw)
		return
	}

	// Enriched: merge source_refs + aliases + a degree count onto each node so
	// the click-detail has provenance + "N connections" in one round-trip.
	var g struct {
		Nodes []json.RawMessage `json:"nodes"`
		Links []json.RawMessage `json:"links"`
	}
	if err := json.Unmarshal(raw, &g); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	refRows, err := d.Pool.Query(ctx,
		`SELECT e.entity_id, e.source_refs, e.aliases
		   FROM stewards.world_entities e
		   JOIN stewards.worlds w ON w.world_id = e.world_id
		  WHERE w.slug = $1`, slug)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer refRows.Close()
	type refRow struct {
		Refs    json.RawMessage
		Aliases []string
	}
	refByID := map[int64]refRow{}
	for refRows.Next() {
		var id int64
		var rr refRow
		if err := refRows.Scan(&id, &rr.Refs, &rr.Aliases); err == nil {
			refByID[id] = rr
		}
	}
	deg := map[int64]int{}
	for _, lr := range g.Links {
		var ll struct {
			Source int64 `json:"source"`
			Target int64 `json:"target"`
		}
		if json.Unmarshal(lr, &ll) == nil {
			deg[ll.Source]++
			deg[ll.Target]++
		}
	}
	enriched := make([]json.RawMessage, 0, len(g.Nodes))
	for _, nr := range g.Nodes {
		var m map[string]any
		if json.Unmarshal(nr, &m) != nil {
			enriched = append(enriched, nr)
			continue
		}
		var id int64
		if v, ok := m["id"].(float64); ok {
			id = int64(v)
		}
		if rr, ok := refByID[id]; ok {
			if len(rr.Refs) > 0 {
				m["source_refs"] = json.RawMessage(rr.Refs)
			}
			if len(rr.Aliases) > 0 {
				m["aliases"] = rr.Aliases
			}
		}
		m["degree"] = deg[id]
		b, _ := json.Marshal(m)
		enriched = append(enriched, b)
	}
	writeJSON(w, http.StatusOK, map[string]any{"nodes": enriched, "links": g.Links})
}

// worldNodeHandler — one entity's full detail (typed edges + provenance).
func (d *Deps) worldNodeHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	slug := r.URL.Query().Get("slug")
	id := atoiDefault(r.URL.Query().Get("id"), 0, 0, 1<<31)
	if slug == "" || id == 0 {
		writeErr(w, http.StatusBadRequest, "slug and id required")
		return
	}
	var raw []byte
	err := d.Pool.QueryRow(ctx,
		`SELECT jsonb_build_object(
		    'id', e.entity_id, 'kind', e.kind, 'name', e.name, 'summary', e.summary,
		    'aliases', e.aliases, 'source_refs', e.source_refs,
		    'edges', COALESCE((SELECT jsonb_agg(jsonb_build_object(
		        'rel', g.rel_type,
		        'dir', CASE WHEN g.src_entity = e.entity_id THEN 'out' ELSE 'in' END,
		        'other_id', CASE WHEN g.src_entity = e.entity_id THEN g.dst_entity ELSE g.src_entity END,
		        'other_name', o.name, 'evidence', g.evidence))
		      FROM stewards.world_edges g
		      JOIN stewards.world_entities o
		        ON o.entity_id = CASE WHEN g.src_entity = e.entity_id THEN g.dst_entity ELSE g.src_entity END
		     WHERE g.src_entity = e.entity_id OR g.dst_entity = e.entity_id), '[]'::jsonb))
		   FROM stewards.world_entities e
		   JOIN stewards.worlds w ON w.world_id = e.world_id
		  WHERE w.slug = $1 AND e.entity_id = $2`, slug, id).Scan(&raw)
	if err != nil {
		writeErr(w, http.StatusNotFound, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(raw)
}
