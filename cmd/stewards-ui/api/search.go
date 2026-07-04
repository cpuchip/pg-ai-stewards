// Search endpoint — "give the human the models' search." Michael's own
// words at the top of the mission: agents already search the substrate by
// hybrid RRF and graph traversal; there was no human-facing surface doing
// the same. One query, three ranked views over the same underlying corpus
// (stewards.docs): Hybrid (RRF-fused + the 93 recall boost), Keyword (the
// bare FTS leg, for comparison), and Graph (1-hop SIMILAR_TO neighbors of
// the top hybrid hit). All three are read via functions that already exist
// for agents (71/72/93's hybrid family + doc_similar) — this is a UI on top
// of the exact same retrieval agents use, not a parallel implementation.
//
// The Hybrid pane calls stewards.doc_search_recall (not the bare
// doc_search_hybrid): a human reading a search result IS a "use," the same
// signal 93 wires up for agent tool calls via doc_search_tool. The Keyword
// pane is deliberately the raw/diagnostic FTS view and does not bump usage.
// The Graph pane is a derived view (neighbors of something already counted)
// and doesn't bump either.
//
// NOTE ON SCOPE: this searches stewards.docs only (the doc-chunk corpus).
// world_entity_hybrid (a separate per-world corpus, stewards.world_entities)
// is NOT folded in here — a real next increment, but a different retrieval
// shape (needs a world_slug) that didn't fit this pass. Named, not silent.

package api

import (
	"context"
	"net/http"
	"strings"
	"time"
)

func (d *Deps) registerSearch(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/search", d.searchHandler)
}

type globalSearchHit struct {
	Slug    string  `json:"slug"`
	Kind    string  `json:"kind,omitempty"`
	Title   string  `json:"title,omitempty"`
	Snippet string  `json:"snippet,omitempty"` // may carry <b>...</b> highlight markers from ts_headline
	Score   float64 `json:"score,omitempty"`
}

type graphSearchHit struct {
	Slug  string  `json:"slug"`
	Title string  `json:"title,omitempty"`
	Score float64 `json:"score,omitempty"`
}

type globalSearchResp struct {
	Query   string            `json:"query"`
	Hybrid  []globalSearchHit `json:"hybrid"`
	Keyword []globalSearchHit `json:"keyword"`
	Graph   []graphSearchHit  `json:"graph"`
	GraphOf string            `json:"graph_of,omitempty"` // the slug the Graph pane expanded from
}

func (d *Deps) searchHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	query := strings.TrimSpace(r.URL.Query().Get("q"))
	if query == "" {
		writeErr(w, http.StatusBadRequest, "q query param required")
		return
	}
	limit := atoiDefault(r.URL.Query().Get("limit"), 10, 1, 50)

	resp := globalSearchResp{Query: query, Hybrid: []globalSearchHit{}, Keyword: []globalSearchHit{}, Graph: []graphSearchHit{}}

	// Hybrid — via doc_search_recall (93): a surfaced hit bumps
	// last_used_at/use_count exactly like an agent's doc_search tool call
	// would. Same fused RRF + recall-boost ranking agents see.
	hrows, err := d.Pool.Query(ctx,
		`SELECT slug, kind, title, snippet, rank::float8
		   FROM stewards.doc_search_recall($1, ARRAY[]::text[], $2, false)`,
		query, limit,
	)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "hybrid search: "+err.Error())
		return
	}
	for hrows.Next() {
		var h globalSearchHit
		if err := hrows.Scan(&h.Slug, &h.Kind, &h.Title, &h.Snippet, &h.Score); err == nil {
			resp.Hybrid = append(resp.Hybrid, h)
		}
	}
	hrows.Close()

	// Keyword — the bare FTS leg (stewards.doc_search), no recall bump: a
	// deliberately raw view alongside the fused ranking, for comparison.
	krows, err := d.Pool.Query(ctx,
		`SELECT slug, kind, title, snippet, rank::float8
		   FROM stewards.doc_search($1, ARRAY[]::text[], $2)`,
		query, limit,
	)
	if err == nil {
		for krows.Next() {
			var h globalSearchHit
			if err := krows.Scan(&h.Slug, &h.Kind, &h.Title, &h.Snippet, &h.Score); err == nil {
				resp.Keyword = append(resp.Keyword, h)
			}
		}
		krows.Close()
	}

	// Graph — 1-hop doc_similar neighbors of the TOP hybrid hit. Read-only,
	// no bump (a derived view of something already counted above). Requires
	// stewards.refresh_doc_similarity to have run for the source doc; an
	// empty pane here usually means that hasn't happened yet, not a bug.
	if len(resp.Hybrid) > 0 {
		top := resp.Hybrid[0].Slug
		resp.GraphOf = top
		grows, err := d.Pool.Query(ctx,
			`SELECT slug, title, score FROM stewards.doc_similar($1, $2)`,
			top, limit,
		)
		if err == nil {
			for grows.Next() {
				var g graphSearchHit
				if err := grows.Scan(&g.Slug, &g.Title, &g.Score); err == nil {
					resp.Graph = append(resp.Graph, g)
				}
			}
			grows.Close()
		}
	}

	writeJSON(w, http.StatusOK, resp)
}
