// wiki.go — the human dig-in surface over WIKI-CORE's (92) schema: a reader
// (page list + page view), a wiki-scoped live graph, and a per-page local
// (Obsidian-style) neighborhood graph.
//
// ★ Contract note (2026-07-04, schema-drift fix): 92 landed as
// extension/92-wiki.sql and the REAL schema differs from the fleet-brief
// sketch this file was originally coded against. The guessed shape
// (wikis(wiki_id, name), wiki_pages(page_id, wiki_id, ...), page_sources.doc)
// 500'd every endpoint with `column ... does not exist`. The queries below
// now target the schema that actually shipped (verified against both
// extension/92-wiki.sql AND the live DB's information_schema):
//
//	stewards.wikis(id, slug, title, kind, scope, created_at)
//	stewards.wiki_pages(id, slug, title, content, status, superseded_by,
//	                    superseded_at, embedding, ..., created_at, updated_at)
//	                    -- status CHECK: 'draft' | 'live' | 'superseded'
//	                    -- NOTE: NO wiki_id column. A page's wiki membership is
//	                    -- MANY-TO-MANY via wiki_members, not a direct FK.
//	stewards.wiki_members(wiki_id, page_id, added_by, added_at)
//	                    -- the join table: wiki_id -> wikis.id, page_id -> wiki_pages.id
//	stewards.page_links(id, from_page, to_slug, kind, created_at)
//	                    -- from_page = wiki_pages.id (the FK the link comes FROM);
//	                    -- to_slug is a bare TEXT slug, not an FK, because the
//	                    -- target may not exist yet (a "red link").
//	stewards.page_sources(id, page_id, doc_id, chunk_ref, asset_id, kind, note, created_at)
//	                    -- page_id -> wiki_pages.id; the source doc is doc_id (text).
//
// The JSON response contracts to the frontend (WikiBrief.name, WikiPageDetail,
// the graph node/edge shapes in api.ts) are UNCHANGED — the real column names
// are aliased in SQL (title AS name, etc.) so no frontend type had to move.
//
// Every handler still gates on wikiSchemaAvailable() FIRST and returns a
// clean `{"available": false}` when the wiki schema hasn't landed in the DB
// this binary is pointed at — never a 500.
package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

func (d *Deps) registerWiki(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/wiki/wikis", d.wikiWikisHandler)
	mux.HandleFunc("GET /api/wiki/pages", d.wikiPagesHandler)
	mux.HandleFunc("GET /api/wiki/page", d.wikiPageHandler)
	mux.HandleFunc("GET /api/wiki/graph", d.wikiGraphHandler)
	mux.HandleFunc("GET /api/wiki/local-graph", d.wikiLocalGraphHandler)
	mux.HandleFunc("POST /api/wiki/page/stub", d.wikiCreateStubHandler)
}

// wikiSchemaAvailable — see the file header. Cheap (`to_regclass` is a
// catalog lookup, no table scan) so it's fine to call once per request.
func (d *Deps) wikiSchemaAvailable(ctx context.Context) bool {
	var reg *string
	if err := d.Pool.QueryRow(ctx, `SELECT to_regclass('stewards.wiki_pages')::text`).Scan(&reg); err != nil {
		return false
	}
	return reg != nil
}

type wikiBrief struct {
	Slug      string `json:"slug"`
	Name      string `json:"name"`
	PageCount int64  `json:"page_count"`
}

func (d *Deps) wikiWikisHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	if !d.wikiSchemaAvailable(ctx) {
		writeJSON(w, http.StatusOK, map[string]any{"available": false, "items": []wikiBrief{}})
		return
	}
	rows, err := d.Pool.Query(ctx, `
		SELECT w.slug, coalesce(w.title, w.slug) AS name,
		       (SELECT count(*) FROM stewards.wiki_members m WHERE m.wiki_id = w.id) AS page_count
		  FROM stewards.wikis w
		 ORDER BY w.slug`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	out := []wikiBrief{}
	for rows.Next() {
		var x wikiBrief
		if err := rows.Scan(&x.Slug, &x.Name, &x.PageCount); err == nil {
			out = append(out, x)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"available": true, "items": out})
}

type wikiPageBrief struct {
	Slug      string     `json:"slug"`
	Title     string     `json:"title"`
	Status    string     `json:"status"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
}

// GET /api/wiki/pages?wiki=<slug>&status=<status>
func (d *Deps) wikiPagesHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	if !d.wikiSchemaAvailable(ctx) {
		writeJSON(w, http.StatusOK, map[string]any{"available": false, "items": []wikiPageBrief{}})
		return
	}
	q := r.URL.Query()
	wiki := strings.TrimSpace(q.Get("wiki"))
	status := strings.TrimSpace(q.Get("status"))

	// wiki membership is many-to-many (wiki_members), so filter by EXISTS
	// rather than an inner join — an empty wiki filter returns every page
	// exactly once (no duplicate rows for a page that belongs to >1 wiki).
	sql := `SELECT p.slug, p.title, p.status, p.updated_at
	          FROM stewards.wiki_pages p
	         WHERE ($1 = '' OR EXISTS (
	                  SELECT 1 FROM stewards.wiki_members m
	                    JOIN stewards.wikis w ON w.id = m.wiki_id
	                   WHERE m.page_id = p.id AND w.slug = $1))
	           AND ($2 = '' OR p.status = $2)
	         ORDER BY p.updated_at DESC NULLS LAST`
	rows, err := d.Pool.Query(ctx, sql, wiki, status)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	out := []wikiPageBrief{}
	for rows.Next() {
		var x wikiPageBrief
		if err := rows.Scan(&x.Slug, &x.Title, &x.Status, &x.UpdatedAt); err == nil {
			out = append(out, x)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"available": true, "items": out})
}

type wikiPageLinkOut struct {
	ToSlug string `json:"to_slug"`
	Kind   string `json:"kind,omitempty"`
	Exists bool   `json:"exists"`
	Title  string `json:"title,omitempty"`
}

type wikiBacklinkOut struct {
	FromSlug string `json:"from_slug"`
	Title    string `json:"title,omitempty"`
	Kind     string `json:"kind,omitempty"`
}

type wikiPageDetail struct {
	Slug         string            `json:"slug"`
	Wiki         string            `json:"wiki"`
	Title        string            `json:"title"`
	Content      string            `json:"content"`
	Status       string            `json:"status"`
	SupersededBy string            `json:"superseded_by,omitempty"`
	UpdatedAt    *time.Time        `json:"updated_at,omitempty"`
	Outbound     []wikiPageLinkOut `json:"outbound"`
	Backlinks    []wikiBacklinkOut `json:"backlinks"`
	Sources      []map[string]any  `json:"sources"`
}

// GET /api/wiki/page?slug=<page-slug>
func (d *Deps) wikiPageHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	slug := strings.TrimSpace(r.URL.Query().Get("slug"))
	if slug == "" {
		writeErr(w, http.StatusBadRequest, "slug query param required")
		return
	}
	if !d.wikiSchemaAvailable(ctx) {
		writeJSON(w, http.StatusOK, map[string]any{"available": false})
		return
	}

	var p wikiPageDetail
	var superseded *string
	// A page can belong to several wikis (many-to-many); surface one stable
	// wiki slug for the header. superseded_by is a wiki_pages.id (uuid) — the
	// frontend routes on it as a SLUG, so resolve it to the target's slug here.
	err := d.Pool.QueryRow(ctx, `
		SELECT p.slug,
		       coalesce((SELECT w.slug
		                   FROM stewards.wiki_members m
		                   JOIN stewards.wikis w ON w.id = m.wiki_id
		                  WHERE m.page_id = p.id
		                  ORDER BY w.slug LIMIT 1), '') AS wiki,
		       p.title, p.content, p.status,
		       (SELECT sb.slug FROM stewards.wiki_pages sb WHERE sb.id = p.superseded_by) AS superseded_by_slug,
		       p.updated_at
		  FROM stewards.wiki_pages p
		 WHERE p.slug = $1`, slug,
	).Scan(&p.Slug, &p.Wiki, &p.Title, &p.Content, &p.Status, &superseded, &p.UpdatedAt)
	if err != nil {
		writeErr(w, http.StatusNotFound, "page not found: "+err.Error())
		return
	}
	if superseded != nil {
		p.SupersededBy = *superseded
	}

	p.Outbound = []wikiPageLinkOut{}
	orows, err := d.Pool.Query(ctx, `
		SELECT pl.to_slug, coalesce(pl.kind, ''), tp.title
		  FROM stewards.page_links pl
		  JOIN stewards.wiki_pages sp ON sp.id = pl.from_page
		  LEFT JOIN stewards.wiki_pages tp ON tp.slug = pl.to_slug
		 WHERE sp.slug = $1`, slug)
	if err == nil {
		defer orows.Close()
		for orows.Next() {
			var l wikiPageLinkOut
			var title *string
			if err := orows.Scan(&l.ToSlug, &l.Kind, &title); err == nil {
				l.Exists = title != nil
				if title != nil {
					l.Title = *title
				}
				p.Outbound = append(p.Outbound, l)
			}
		}
	}

	p.Backlinks = []wikiBacklinkOut{}
	brows, err := d.Pool.Query(ctx, `
		SELECT sp.slug, sp.title, coalesce(pl.kind, '')
		  FROM stewards.page_links pl
		  JOIN stewards.wiki_pages sp ON sp.id = pl.from_page
		 WHERE pl.to_slug = $1`, slug)
	if err == nil {
		defer brows.Close()
		for brows.Next() {
			var b wikiBacklinkOut
			if err := brows.Scan(&b.FromSlug, &b.Title, &b.Kind); err == nil {
				p.Backlinks = append(p.Backlinks, b)
			}
		}
	}

	// page_sources — the footer: "click through to the real doc/asset". Best-effort:
	// scanned generically (see scanRowsGeneric) since the exact column set beyond
	// page_id is a guess (doc/chunk/quote/object, mirroring world_entities.source_refs).
	p.Sources = []map[string]any{}
	srows, err := d.Pool.Query(ctx, `
		SELECT ps.*
		  FROM stewards.page_sources ps
		  JOIN stewards.wiki_pages sp ON sp.id = ps.page_id
		 WHERE sp.slug = $1`, slug)
	if err == nil {
		defer srows.Close()
		if sc, serr := scanRowsGeneric(srows); serr == nil {
			p.Sources = sc
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{"available": true, "page": p})
}

type wikiGraphNode struct {
	ID     string `json:"id"` // = slug
	Label  string `json:"label"`
	Status string `json:"status,omitempty"`
	Exists bool   `json:"exists"` // false = a red link with no page row
	IsDoc  bool   `json:"is_doc,omitempty"`
}
type wikiGraphEdge struct {
	Source string `json:"source"`
	Target string `json:"target"`
	Kind   string `json:"kind,omitempty"`
}
type wikiGraphResp struct {
	Available bool            `json:"available"`
	Nodes     []wikiGraphNode `json:"nodes"`
	Edges     []wikiGraphEdge `json:"edges"`
}

// GET /api/wiki/graph?wiki=<slug>&include_docs=1 — the whole wiki-scoped
// graph: nodes = pages (+ red-link stubs for to_slug targets with no page
// row), edges = page_links. include_docs=1 additionally pulls in each page's
// page_sources.doc as a dimmer "source doc" node (per the mission's "optional
// source docs as dimmer nodes").
func (d *Deps) wikiGraphHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	resp := wikiGraphResp{Nodes: []wikiGraphNode{}, Edges: []wikiGraphEdge{}}
	if !d.wikiSchemaAvailable(ctx) {
		writeJSON(w, http.StatusOK, resp)
		return
	}
	resp.Available = true
	wiki := strings.TrimSpace(r.URL.Query().Get("wiki"))
	includeDocs := r.URL.Query().Get("include_docs") == "1"

	seen := map[string]bool{}
	rows, err := d.Pool.Query(ctx, `
		SELECT p.slug, p.title, p.status
		  FROM stewards.wiki_pages p
		 WHERE $1 = '' OR EXISTS (
		         SELECT 1 FROM stewards.wiki_members m
		           JOIN stewards.wikis w ON w.id = m.wiki_id
		          WHERE m.page_id = p.id AND w.slug = $1)`, wiki)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	for rows.Next() {
		var n wikiGraphNode
		if err := rows.Scan(&n.ID, &n.Label, &n.Status); err == nil {
			n.Exists = true
			resp.Nodes = append(resp.Nodes, n)
			seen[n.ID] = true
		}
	}
	rows.Close()

	erows, err := d.Pool.Query(ctx, `
		SELECT sp.slug, pl.to_slug, coalesce(pl.kind, '')
		  FROM stewards.page_links pl
		  JOIN stewards.wiki_pages sp ON sp.id = pl.from_page
		 WHERE $1 = '' OR EXISTS (
		         SELECT 1 FROM stewards.wiki_members m
		           JOIN stewards.wikis w ON w.id = m.wiki_id
		          WHERE m.page_id = sp.id AND w.slug = $1)`, wiki)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	for erows.Next() {
		var e wikiGraphEdge
		if err := erows.Scan(&e.Source, &e.Target, &e.Kind); err == nil {
			resp.Edges = append(resp.Edges, e)
			if !seen[e.Target] {
				// a red link: the target slug has no page row (yet).
				resp.Nodes = append(resp.Nodes, wikiGraphNode{ID: e.Target, Label: e.Target, Exists: false})
				seen[e.Target] = true
			}
		}
	}
	erows.Close()

	if includeDocs {
		drows, err := d.Pool.Query(ctx, `
			SELECT sp.slug, ps.doc_id
			  FROM stewards.page_sources ps
			  JOIN stewards.wiki_pages sp ON sp.id = ps.page_id
			 WHERE ps.doc_id IS NOT NULL AND ps.doc_id <> ''
			   AND ($1 = '' OR EXISTS (
			         SELECT 1 FROM stewards.wiki_members m
			           JOIN stewards.wikis w ON w.id = m.wiki_id
			          WHERE m.page_id = sp.id AND w.slug = $1))`, wiki)
		if err == nil {
			for drows.Next() {
				var pageSlug, doc string
				if err := drows.Scan(&pageSlug, &doc); err == nil {
					docNodeID := "doc:" + doc
					if !seen[docNodeID] {
						resp.Nodes = append(resp.Nodes, wikiGraphNode{ID: docNodeID, Label: doc, Exists: true, IsDoc: true})
						seen[docNodeID] = true
					}
					resp.Edges = append(resp.Edges, wikiGraphEdge{Source: pageSlug, Target: docNodeID, Kind: "source"})
				}
			}
			drows.Close()
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

// GET /api/wiki/local-graph?slug=<page-slug>&hops=1|2 — the Obsidian-style
// per-page neighborhood: the page itself, everything within N hops (via
// page_links in EITHER direction), and the edges between exactly those nodes.
func (d *Deps) wikiLocalGraphHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	resp := wikiGraphResp{Nodes: []wikiGraphNode{}, Edges: []wikiGraphEdge{}}
	slug := strings.TrimSpace(r.URL.Query().Get("slug"))
	if slug == "" {
		writeErr(w, http.StatusBadRequest, "slug query param required")
		return
	}
	if !d.wikiSchemaAvailable(ctx) {
		writeJSON(w, http.StatusOK, resp)
		return
	}
	resp.Available = true
	hops := atoiDefault(r.URL.Query().Get("hops"), 2, 1, 2)

	frontier := map[string]bool{slug: true}
	all := map[string]bool{slug: true}
	type edgeKey struct{ from, to, kind string }
	edgeSeen := map[edgeKey]bool{}

	for i := 0; i < hops; i++ {
		if len(frontier) == 0 {
			break
		}
		keys := make([]string, 0, len(frontier))
		for k := range frontier {
			keys = append(keys, k)
		}
		rows, err := d.Pool.Query(ctx, `
			SELECT sp.slug, pl.to_slug, coalesce(pl.kind, '')
			  FROM stewards.page_links pl
			  JOIN stewards.wiki_pages sp ON sp.id = pl.from_page
			 WHERE sp.slug = ANY($1) OR pl.to_slug = ANY($1)`, keys)
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		next := map[string]bool{}
		for rows.Next() {
			var from, to, kind string
			if err := rows.Scan(&from, &to, &kind); err != nil {
				continue
			}
			ek := edgeKey{from, to, kind}
			if !edgeSeen[ek] {
				edgeSeen[ek] = true
				resp.Edges = append(resp.Edges, wikiGraphEdge{Source: from, Target: to, Kind: kind})
			}
			for _, s := range []string{from, to} {
				if !all[s] {
					next[s] = true
				}
			}
		}
		rows.Close()
		for k := range next {
			all[k] = true
		}
		frontier = next
	}

	if len(all) > 0 {
		keys := make([]string, 0, len(all))
		for k := range all {
			keys = append(keys, k)
		}
		nrows, err := d.Pool.Query(ctx, `
			SELECT slug, title, status FROM stewards.wiki_pages WHERE slug = ANY($1)`, keys)
		if err == nil {
			existing := map[string]bool{}
			for nrows.Next() {
				var n wikiGraphNode
				if err := nrows.Scan(&n.ID, &n.Label, &n.Status); err == nil {
					n.Exists = true
					resp.Nodes = append(resp.Nodes, n)
					existing[n.ID] = true
				}
			}
			nrows.Close()
			for k := range all {
				if !existing[k] {
					resp.Nodes = append(resp.Nodes, wikiGraphNode{ID: k, Label: k, Exists: false})
				}
			}
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

type wikiCreateStubReq struct {
	Slug string `json:"slug"`
	Wiki string `json:"wiki,omitempty"`
}
type wikiCreateStubResp struct {
	Slug string `json:"slug"`
}

// POST /api/wiki/page/stub — the red-link "create page?" action: a minimal
// status='draft' row (92's real status for "being built, not yet citable" —
// there is no 'stub' status in the schema) so the link resolves and the
// curator (92's digester) has somewhere to fill content in later. Idempotent:
// if the slug already exists this just re-attaches it to the wiki and returns
// it (no error), since two clicks on the same red link shouldn't fight.
func (d *Deps) wikiCreateStubHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()
	if !d.wikiSchemaAvailable(ctx) {
		writeErr(w, http.StatusServiceUnavailable, "wiki schema not available yet")
		return
	}
	var req wikiCreateStubReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad request body")
		return
	}
	slug := strings.TrimSpace(req.Slug)
	if slug == "" {
		writeErr(w, http.StatusBadRequest, "slug required")
		return
	}
	wiki := strings.TrimSpace(req.Wiki)
	if wiki == "" {
		// default to the first (any) wiki — a brand-new deployment likely has one.
		if err := d.Pool.QueryRow(ctx, `SELECT slug FROM stewards.wikis ORDER BY slug LIMIT 1`).Scan(&wiki); err != nil {
			writeErr(w, http.StatusBadRequest, "no wiki to create the page in — pass wiki=<slug>")
			return
		}
	}
	title := strings.ReplaceAll(slug, "-", " ")
	// Real schema: wiki_pages has NO wiki_id column, and status is CHECK-
	// constrained to ('draft','live','superseded') — 'stub' is not valid.
	// A red-link stub maps to status='draft' (92's own meaning: "being built,
	// not yet a citable page"). Membership is the separate wiki_members join.
	// One CTE so it's atomic and idempotent: upsert-by-slug (DO UPDATE no-op so
	// RETURNING always yields the id even when the page already exists), then
	// attach it to the named wiki.
	if _, err := d.Pool.Exec(ctx, `
		WITH target_wiki AS (
		    SELECT id FROM stewards.wikis WHERE slug = $1
		),
		upserted AS (
		    INSERT INTO stewards.wiki_pages (slug, title, content, status)
		    VALUES ($2, $3, '', 'draft')
		    ON CONFLICT (slug) DO UPDATE SET title = stewards.wiki_pages.title
		    RETURNING id
		)
		INSERT INTO stewards.wiki_members (wiki_id, page_id, added_by)
		SELECT tw.id, u.id, 'wiki_ui_stub'
		  FROM target_wiki tw CROSS JOIN upserted u
		ON CONFLICT (wiki_id, page_id) DO NOTHING`, wiki, slug, title,
	); err != nil {
		writeErr(w, http.StatusInternalServerError, "create stub: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, wikiCreateStubResp{Slug: slug})
}

// scanRowsGeneric decodes an arbitrary pgx result set into []map[string]any,
// keyed by column name. Used for surfaces this agent codes against a
// contract it hasn't seen the real column list for (page_sources,
// doc_pull_sources, doc_blind_spots) — generic decoding means a wrong guess
// about an OPTIONAL column doesn't break the whole response, only that one
// key is silently absent. Does NOT close rows — callers own that (matches
// every other query in this package).
func scanRowsGeneric(rows pgx.Rows) ([]map[string]any, error) {
	fds := rows.FieldDescriptions()
	out := []map[string]any{}
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			return nil, err
		}
		m := make(map[string]any, len(fds))
		for i, fd := range fds {
			if i < len(vals) {
				m[fd.Name] = vals[i]
			}
		}
		out = append(out, m)
	}
	return out, rows.Err()
}
