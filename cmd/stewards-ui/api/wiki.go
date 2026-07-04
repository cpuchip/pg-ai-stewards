// Wiki endpoints — the "add to wiki" collection action on search results
// (.spec/proposals/lab-and-wiki.md, Part 2). Thin wrappers over WIKI-CORE's
// (extension/92) SQL surface: wiki_create(slug,title,kind,scope),
// wiki_add_member(wiki_slug,page_slug), wiki_page_upsert(slug,title,content,
// sources).
//
// ***** INTEGRATION NOTE — read before touching this file *****
// This was built in a worktree WITHOUT 92 (a parallel WIKI-CORE build). The
// three functions above do not exist yet where this file was authored, so
// none of it has been run against a real wiki backend — it is coded against
// the CONTRACT given for this mission, not verified against 92's actual
// bodies. Two integration points are marked below; re-check both against
// 92's real signatures/return types once it lands, before trusting this in
// production:
//
//   INTEGRATION POINT #1 (wikiListHandler) — assumes a queryable
//     `stewards.wikis` table with (slug, title, kind) columns, inferred from
//     wiki_create's own arg list (there is no read/list function in the
//     given contract). Degrades to an empty list + a note instead of a hard
//     error so the UI picker still works (as "new collection only") before
//     92 lands or if the real read surface differs.
//
//   INTEGRATION POINT #2 (wikiAddHandler) — assumes wiki_page_upsert's
//     return value is NOT relied upon (called via Exec, not QueryRow): the
//     page's slug is taken to be the exact p_slug we pass in (the search
//     result's own doc slug), not whatever the function returns. If 92's
//     wiki_page_upsert mints a DIFFERENT slug than the one it's given,
//     wiki_add_member below needs that return value plumbed through instead.
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"
)

func (d *Deps) registerWiki(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/wiki/list", d.wikiListHandler)
	mux.HandleFunc("POST /api/wiki/add", d.wikiAddHandler)
}

type wikiBrief struct {
	Slug  string `json:"slug"`
	Title string `json:"title,omitempty"`
	Kind  string `json:"kind,omitempty"`
}

type wikiListResp struct {
	Items []wikiBrief `json:"items"`
	Note  string      `json:"note,omitempty"`
}

// GET /api/wiki/list — the picker's "existing wikis" source.
func (d *Deps) wikiListHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	resp := wikiListResp{Items: []wikiBrief{}}

	// INTEGRATION POINT #1 — see file header. Degrade gracefully (empty +
	// note) rather than 500 if 92 hasn't landed or the table name differs.
	rows, err := d.Pool.Query(ctx, `SELECT slug, title, kind FROM stewards.wikis ORDER BY title`)
	if err != nil {
		resp.Note = "wiki backend not available yet (pending extension/92) — you can still create a new collection"
		writeJSON(w, http.StatusOK, resp)
		return
	}
	defer rows.Close()
	for rows.Next() {
		var wb wikiBrief
		if err := rows.Scan(&wb.Slug, &wb.Title, &wb.Kind); err == nil {
			resp.Items = append(resp.Items, wb)
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

type newWikiReq struct {
	Slug  string `json:"slug"`
	Title string `json:"title"`
	Kind  string `json:"kind,omitempty"`  // e.g. "personal" — operator-defined, mirrors docs.kind's open taxonomy
	Scope string `json:"scope,omitempty"` // raw jsonb text; "" -> "{}"
}

type wikiAddReq struct {
	WikiSlug    string      `json:"wiki_slug,omitempty"` // add to an existing wiki...
	NewWiki     *newWikiReq `json:"new_wiki,omitempty"`  // ...or create one inline first
	ResultSlug  string      `json:"result_slug"`
	ResultTitle string      `json:"result_title"`
	ResultKind  string      `json:"result_kind,omitempty"`
}

type wikiAddResp struct {
	OK       bool   `json:"ok"`
	WikiSlug string `json:"wiki_slug"`
	PageSlug string `json:"page_slug"`
	Note     string `json:"note,omitempty"`
}

// POST /api/wiki/add — the search result row's "+ wiki" action. Either adds
// to an existing wiki (wiki_slug) or creates one inline first (new_wiki).
// Every current search hit is a raw stewards.docs row (kind doc/study/
// proposal/...), not yet a first-class wiki PAGE, so a stub page is upserted
// first via wiki_page_upsert before wiki_add_member links it in — unless
// result_kind already says it IS a wiki page (once 92 gives that a real
// kind value), in which case the result's own slug is used directly.
func (d *Deps) wikiAddHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()

	var req wikiAddReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid request body: "+err.Error())
		return
	}
	req.ResultSlug = strings.TrimSpace(req.ResultSlug)
	if req.ResultSlug == "" {
		writeErr(w, http.StatusBadRequest, "result_slug required")
		return
	}

	wikiSlug := strings.TrimSpace(req.WikiSlug)
	if req.NewWiki != nil {
		nw := req.NewWiki
		if strings.TrimSpace(nw.Slug) == "" || strings.TrimSpace(nw.Title) == "" {
			writeErr(w, http.StatusBadRequest, "new_wiki.slug and new_wiki.title required")
			return
		}
		kind := nw.Kind
		if kind == "" {
			kind = "personal"
		}
		scope := nw.Scope
		if scope == "" {
			scope = "{}"
		}
		if _, err := d.Pool.Exec(ctx,
			`SELECT stewards.wiki_create($1, $2, $3, $4::jsonb)`,
			nw.Slug, nw.Title, kind, scope,
		); err != nil {
			writeErr(w, http.StatusInternalServerError, "wiki_create (pending extension/92): "+err.Error())
			return
		}
		wikiSlug = nw.Slug
	}
	if wikiSlug == "" {
		writeErr(w, http.StatusBadRequest, "wiki_slug or new_wiki required")
		return
	}

	// A stub page for a raw doc/study result, source-linked back to the
	// viewer (the /studies/:slug route already renders any stewards.docs
	// row — docs and studies share the one table). See INTEGRATION POINT #2:
	// the page's slug is taken to be req.ResultSlug regardless of what
	// wiki_page_upsert returns.
	pageSlug := req.ResultSlug
	if req.ResultKind != "wiki_page" {
		title := req.ResultTitle
		if title == "" {
			title = req.ResultSlug
		}
		content := fmt.Sprintf(
			"_Stub page created from a search hit — expand this as the wiki curator (or you) sees fit._\n\nSource: [%s](/studies/%s)\n",
			title, req.ResultSlug,
		)
		sourcesJSON, _ := json.Marshal([]string{req.ResultSlug})
		if _, err := d.Pool.Exec(ctx,
			`SELECT stewards.wiki_page_upsert($1, $2, $3, $4::jsonb)`,
			req.ResultSlug, title, content, string(sourcesJSON),
		); err != nil {
			writeErr(w, http.StatusInternalServerError, "wiki_page_upsert (pending extension/92): "+err.Error())
			return
		}
	}

	if _, err := d.Pool.Exec(ctx,
		`SELECT stewards.wiki_add_member($1, $2)`,
		wikiSlug, pageSlug,
	); err != nil {
		writeErr(w, http.StatusInternalServerError, "wiki_add_member (pending extension/92): "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, wikiAddResp{OK: true, WikiSlug: wikiSlug, PageSlug: pageSlug})
}
