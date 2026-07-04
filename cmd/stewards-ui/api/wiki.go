// wiki.go — the human dig-in surface over WIKI-CORE's (92) schema: a reader
// (page list + page view), a wiki-scoped live graph, and a per-page local
// (Obsidian-style) neighborhood graph.
//
// ★ Contract note (2026-07-03): 92 is a PARALLEL, not-yet-landed builder in
// this same fleet run. As of this file's writing there is no
// `extension/92-*.sql`, no `CREATE TABLE stewards.wiki_pages` anywhere in
// this checkout. This file is written AGAINST 92's contract as specified by
// the fleet brief, not against a schema this agent has seen:
//
//	stewards.wikis(wiki_id, slug, name, ...)
//	stewards.wiki_members(wiki_id, ...)
//	stewards.wiki_pages(page_id, wiki_id, slug, title, content, status,
//	                     superseded_by, created_at, updated_at)
//	stewards.page_links(from_page, to_slug, kind)   -- from_page = wiki_pages.page_id
//	                                                 -- (the FK the link comes FROM);
//	                                                 -- to_slug is a bare TEXT slug, not
//	                                                 -- an FK, because the target may not
//	                                                 -- exist yet (a "red link").
//	stewards.page_sources(page_id, doc, chunk, quote, object)
//	                                                 -- mirrors world_entities.source_refs'
//	                                                 -- shape (doc/chunk/quote/object) since
//	                                                 -- that's this codebase's one other
//	                                                 -- "footnote to a real doc/asset" surface.
//
// wiki_id/page_id follow this codebase's own naming convention
// (world.go: world_id, entity_id) rather than a bare `id`.
//
// Every handler below gates on wikiSchemaAvailable() FIRST and returns a
// clean `{"available": false}` when 92 hasn't landed in the DB this binary is
// pointed at — never a 500. Once 92 lands, if any of the column-name guesses
// above are wrong, the fix is local to this file (the SQL text), not the
// contract or the frontend (which only reads `available` + the typed JSON
// shape, both stable regardless of the underlying column names).
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
		SELECT w.slug, coalesce(w.name, w.slug),
		       (SELECT count(*) FROM stewards.wiki_pages p WHERE p.wiki_id = w.wiki_id) AS page_count
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

	sql := `SELECT p.slug, p.title, p.status, p.updated_at
	          FROM stewards.wiki_pages p
	          JOIN stewards.wikis w ON w.wiki_id = p.wiki_id
	         WHERE ($1 = '' OR w.slug = $1)
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
	err := d.Pool.QueryRow(ctx, `
		SELECT p.slug, w.slug, p.title, p.content, p.status, p.superseded_by, p.updated_at
		  FROM stewards.wiki_pages p
		  JOIN stewards.wikis w ON w.wiki_id = p.wiki_id
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
		  JOIN stewards.wiki_pages sp ON sp.page_id = pl.from_page
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
		  JOIN stewards.wiki_pages sp ON sp.page_id = pl.from_page
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
		  JOIN stewards.wiki_pages sp ON sp.page_id = ps.page_id
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
		  JOIN stewards.wikis w ON w.wiki_id = p.wiki_id
		 WHERE $1 = '' OR w.slug = $1`, wiki)
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
		  JOIN stewards.wiki_pages sp ON sp.page_id = pl.from_page
		  JOIN stewards.wikis w ON w.wiki_id = sp.wiki_id
		 WHERE $1 = '' OR w.slug = $1`, wiki)
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
			SELECT sp.slug, ps.doc
			  FROM stewards.page_sources ps
			  JOIN stewards.wiki_pages sp ON sp.page_id = ps.page_id
			  JOIN stewards.wikis w ON w.wiki_id = sp.wiki_id
			 WHERE ($1 = '' OR w.slug = $1) AND ps.doc IS NOT NULL AND ps.doc <> ''`, wiki)
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
			  JOIN stewards.wiki_pages sp ON sp.page_id = pl.from_page
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
// status='stub' row so the link resolves and the curator (92's digester) has
// somewhere to fill content in later. Idempotent-ish: if the slug already
// exists this just returns it (no error), since two clicks on the same red
// link shouldn't fight.
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
	if _, err := d.Pool.Exec(ctx, `
		INSERT INTO stewards.wiki_pages (wiki_id, slug, title, content, status)
		SELECT w.wiki_id, $2, $3, '', 'stub'
		  FROM stewards.wikis w WHERE w.slug = $1
		ON CONFLICT (slug) DO NOTHING`, wiki, slug, title,
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
