// world.go — Loreworks knowledge-graph endpoints backing the Stewdio 3D World
// panel. world_graph(slug) returns the {nodes,links} JSONB directly; we pass it
// through. include_refs=1 enriches nodes with source_refs + degree for the
// click-detail drawer (one round-trip for the demo). A thin /node endpoint
// serves one entity's full detail (typed edges + provenance) for lazy loads.

package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

func (d *Deps) registerWorld(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/world/list", d.worldListHandler)
	mux.HandleFunc("GET /api/world/graph", d.worldGraphHandler)
	mux.HandleFunc("GET /api/world/node", d.worldNodeHandler)
	mux.HandleFunc("GET /api/world/cosmos", d.worldCosmosHandler)     // cross-service view: worlds + cross_world_edges + galaxies
	mux.HandleFunc("GET /api/world/projects", d.worldProjectsHandler) // selectable canon projects (formal + corpus tags)
	mux.HandleFunc("POST /api/world/build", d.worldBuildHandler)      // self-serve "Build a World"
}

// worldBuildReq — kick off a world build from the UI. A canon source is required,
// one of: an uploaded file (multipart `file`, imported into `project`), an existing
// `project` (the agent doc_searches it), or inline `canon` text. The same form
// EXPANDS an existing world/project: pick its name + project and upload more — the
// import adds docs and world_*_upsert merges (idempotent), so the graph grows.
type worldBuildReq struct {
	Name              string   `json:"name"`
	Slug              string   `json:"slug,omitempty"`
	Project           string   `json:"project,omitempty"`
	ReferenceProjects []string `json:"reference_projects,omitempty"` // other buckets to read + cross-link
	Canon             string   `json:"canon,omitempty"`
	Instructions      string   `json:"instructions,omitempty"`
}

type worldBuildResp struct {
	Slug      string `json:"slug"`
	SessionID string `json:"session_id"`
}

// worldSlugify — name → a stable lowercase slug (reuses sessionSafe from chat.go).
func worldSlugify(s string) string {
	return strings.Trim(sessionSafe.ReplaceAllString(strings.ToLower(strings.TrimSpace(s)), "-"), "-")
}

func nz(s, def string) string {
	if strings.TrimSpace(s) == "" {
		return def
	}
	return s
}

// worldBuildHandler — register the world (private by default) and dispatch the
// world-build agent over the chosen canon. Accepts a multipart upload (a PDF /
// Office doc / zip / folder) which it stores + has the agent import into the
// project, OR a JSON body naming an existing project / pasted canon. Returns the
// world slug + the chat session the build runs in, so the UI opens it and watches
// the graph fill in.
func (d *Deps) worldBuildHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	var (
		req       worldBuildReq
		fileBytes []byte
		fileName  string
		fileMime  string
	)
	if strings.HasPrefix(r.Header.Get("Content-Type"), "multipart/form-data") {
		if err := r.ParseMultipartForm(maxAttachmentBytes); err != nil {
			writeErr(w, http.StatusBadRequest, "parse upload: "+err.Error())
			return
		}
		req.Name = r.FormValue("name")
		req.Slug = r.FormValue("slug")
		req.Project = r.FormValue("project")
		req.Canon = r.FormValue("canon")
		req.Instructions = r.FormValue("instructions")
		if rp := strings.TrimSpace(r.FormValue("reference_projects")); rp != "" {
			for _, p := range strings.Split(rp, ",") {
				if p = strings.TrimSpace(p); p != "" {
					req.ReferenceProjects = append(req.ReferenceProjects, p)
				}
			}
		}
		if f, hdr, err := r.FormFile("file"); err == nil {
			defer f.Close()
			b, e := io.ReadAll(f)
			if e != nil {
				writeErr(w, http.StatusBadRequest, "read upload: "+e.Error())
				return
			}
			fileBytes = b
			fileName = hdr.Filename
			fileMime = nz(hdr.Header.Get("Content-Type"), "application/octet-stream")
		}
	} else if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad request body")
		return
	}

	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		writeErr(w, http.StatusBadRequest, "name required")
		return
	}
	slug := worldSlugify(req.Slug)
	if slug == "" {
		slug = worldSlugify(req.Name)
	}
	if slug == "" {
		writeErr(w, http.StatusBadRequest, "could not derive a slug from the name")
		return
	}

	proj := strings.TrimSpace(req.Project)
	canonText := strings.TrimSpace(req.Canon)
	instr := strings.TrimSpace(req.Instructions)

	// An upload stores the file as an attachment; the agent imports it into the
	// project (default = the world slug, so a new world gets its own project).
	var attID int64
	if len(fileBytes) > 0 {
		if proj == "" {
			proj = slug
		}
		if err := d.Pool.QueryRow(ctx,
			`INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, bytes, byte_size)
			 VALUES ($1, $2, $3, 'document', $4, $5) RETURNING id`,
			"world-build-"+slug, nz(fileName, "upload"), fileMime, fileBytes, len(fileBytes),
		).Scan(&attID); err != nil {
			writeErr(w, http.StatusInternalServerError, "store upload: "+err.Error())
			return
		}
	}

	// referenced projects — other buckets to ALSO read + cross-link, deduped, minus the primary.
	seenRef := map[string]bool{}
	var refs []string
	for _, rp := range req.ReferenceProjects {
		rp = strings.TrimSpace(rp)
		if rp != "" && rp != proj && !seenRef[rp] {
			seenRef[rp] = true
			refs = append(refs, rp)
		}
	}
	refsClause := ""
	if len(refs) > 0 {
		refsClause = fmt.Sprintf(" This world ALSO spans these connected projects — doc_search EACH of "+
			"them too and fold them into the SAME graph: %s. A shared entity is ONE node (merge it); a "+
			"relationship that spans two projects is exactly the cross-project link to capture. Ground "+
			"every cross-link in the canon.", strings.Join(refs, ", "))
	}

	// the canon clause — how the agent finds (or loads) the primary source material.
	var canon string
	switch {
	case attID > 0:
		canon = fmt.Sprintf("Your primary canon is an uploaded source. FIRST call doc_import_corpus(attachment_id=%d, "+
			"corpus_name=%q, project=%q) EXACTLY ONCE to load + chunk it into project %q, then build from "+
			"that project with doc_search.", attID, req.Name, proj, proj)
	case proj != "":
		canon = fmt.Sprintf("The primary canon lives in the project %q — WALK it chunk-by-chunk with world_build_walk (your worklist + done-signal), extracting as you go, until it returns complete:true. Use doc_search only to enrich the relationship pass afterwards.", proj)
	case canonText != "":
		canon = "Primary canon (the full source to extract from):\n" + canonText
	case len(refs) > 0:
		canon = "" // referenced projects are the only source
	default:
		writeErr(w, http.StatusBadRequest, "provide a canon source: upload a file, name a project, paste canon, or reference projects")
		return
	}
	canon += refsClause

	// register the world — private by default (purchased/world content stays local).
	// Idempotent: re-running for an existing slug merges (expand-a-world).
	var summaryArg any
	if instr != "" {
		summaryArg = instr
	}
	var projArg any
	if proj != "" {
		projArg = proj
	}
	if _, err := d.Pool.Exec(ctx,
		`SELECT stewards.world_upsert($1, $2, $3, $4, true)`,
		slug, req.Name, summaryArg, projArg,
	); err != nil {
		writeErr(w, http.StatusInternalServerError, "world_upsert: "+err.Error())
		return
	}

	// record the referenced projects on the world (for the graph's per-project toggle).
	if len(refs) > 0 {
		refsJSON, _ := json.Marshal(refs)
		if _, err := d.Pool.Exec(ctx,
			`UPDATE stewards.worlds SET metadata = coalesce(metadata,'{}'::jsonb) || jsonb_build_object('reference_projects', $2::jsonb) WHERE slug = $1`,
			slug, string(refsJSON),
		); err != nil {
			writeErr(w, http.StatusInternalServerError, "store reference projects: "+err.Error())
			return
		}
	}

	prompt := fmt.Sprintf(
		"Build the world '%s' (%s). %s%s Extract every entity (character, place, faction, "+
			"item, event, lore) and the relationships between them that the canon actually "+
			"describes, recording each with world_entity_upsert / world_edge_upsert and "+
			"grounding it in source_refs. Do not invent anything the canon does not state.",
		slug, req.Name, canon, instructionsClause(instr))
	grounding := fmt.Sprintf("You are building the world '%s' (%s). %s", slug, req.Name, canon)
	session := fmt.Sprintf("world-build-%s-%d", slug, time.Now().Unix())

	if _, err := d.Pool.Exec(ctx,
		`SELECT stewards.dispatch_chat_turn($1, $2, $3, $4, $5)`,
		session, prompt, "world-build", "reason", grounding,
	); err != nil {
		writeErr(w, http.StatusInternalServerError, "dispatch world-build: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, worldBuildResp{Slug: slug, SessionID: session})
}

// worldProjectsHandler — the projects a canon can live in: the formal projects
// table UNION the corpus tags actually on docs (so an imported corpus like
// `star-trek` is selectable, not just formal projects). Doc count per project.
func (d *Deps) worldProjectsHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	rows, err := d.Pool.Query(ctx, `
		SELECT name, max(doc_count) AS doc_count FROM (
		    SELECT slug AS name, 0 AS doc_count FROM stewards.projects WHERE NOT archived
		    UNION ALL
		    SELECT project_association AS name, count(*) AS doc_count
		      FROM stewards.docs WHERE project_association IS NOT NULL AND project_association <> ''
		      GROUP BY project_association
		) u
		GROUP BY name ORDER BY doc_count DESC, name`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	defer rows.Close()
	type proj struct {
		Name     string `json:"name"`
		DocCount int64  `json:"doc_count"`
	}
	out := []proj{}
	for rows.Next() {
		var p proj
		if err := rows.Scan(&p.Name, &p.DocCount); err == nil {
			out = append(out, p)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": out})
}

func instructionsClause(instr string) string {
	if instr == "" {
		return ""
	}
	return " Extra direction: " + instr + "."
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
	// max_nodes caps a HUGE world to its top-N entities by degree (a
	// lodestar-imported platform world can carry 10k+ file/function entities —
	// rendering them all as one scene saturates the browser's shared GPU process
	// and freezes every window on the machine). 0 = uncapped. The response carries
	// total_nodes/total_edges + truncated so the UI can say what it's showing.
	maxNodes := atoiDefault(r.URL.Query().Get("max_nodes"), 0, 0, 1<<20)
	var raw []byte
	if err := d.Pool.QueryRow(ctx, `SELECT stewards.world_graph($1)`, slug).Scan(&raw); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	if len(raw) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"nodes": []any{}, "links": []any{}})
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
	totalNodes, totalEdges := len(g.Nodes), len(g.Links)
	truncated := maxNodes > 0 && totalNodes > maxNodes
	if truncated {
		g.Nodes, g.Links = topNByDegree(g.Nodes, g.Links, maxNodes)
	}
	if r.URL.Query().Get("include_refs") != "1" {
		writeJSON(w, http.StatusOK, map[string]any{
			"nodes": g.Nodes, "links": g.Links,
			"total_nodes": totalNodes, "total_edges": totalEdges, "truncated": truncated,
		})
		return
	}
	// Scope enrichment to the nodes we're actually returning — on a truncated huge
	// world, scanning ALL of its entities (and LATERAL-joining their source_refs)
	// is exactly the kind of work the cap exists to avoid.
	keepIDs := nodeIDs(g.Nodes)
	refRows, err := d.Pool.Query(ctx,
		`SELECT e.entity_id, e.source_refs, e.aliases
		   FROM stewards.world_entities e
		   JOIN stewards.worlds w ON w.world_id = e.world_id
		  WHERE w.slug = $1 AND e.entity_id = ANY($2)`, slug, keepIDs)
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
	// per-node project provenance (which bucket(s) each entity's source docs are
	// tagged with) — drives the graph's per-project show/hide toggle + badges.
	projByID := map[int64][]string{}
	if prows, perr := d.Pool.Query(ctx,
		`SELECT e.entity_id,
		        array_agg(DISTINCT d.project_association) FILTER (WHERE d.project_association IS NOT NULL AND d.project_association <> '')
		   FROM stewards.world_entities e
		   JOIN stewards.worlds w ON w.world_id = e.world_id
		   LEFT JOIN LATERAL jsonb_array_elements(e.source_refs) sr ON true
		   LEFT JOIN stewards.docs d ON d.slug = sr->>'doc'
		  WHERE w.slug = $1 AND e.entity_id = ANY($2)
		  GROUP BY e.entity_id`, slug, keepIDs); perr == nil {
		defer prows.Close()
		for prows.Next() {
			var id int64
			var ps []string
			if err := prows.Scan(&id, &ps); err == nil && len(ps) > 0 {
				projByID[id] = ps
			}
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
		if ps, ok := projByID[id]; ok {
			m["projects"] = ps
		}
		m["degree"] = deg[id]
		b, _ := json.Marshal(m)
		enriched = append(enriched, b)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"nodes": enriched, "links": g.Links,
		"total_nodes": totalNodes, "total_edges": totalEdges, "truncated": truncated,
	})
}

// nodeIDs pulls the entity ids out of raw graph nodes (for scoping enrichment).
func nodeIDs(nodes []json.RawMessage) []int64 {
	ids := make([]int64, 0, len(nodes))
	for _, nr := range nodes {
		var n struct {
			ID int64 `json:"id"`
		}
		if json.Unmarshal(nr, &n) == nil && n.ID != 0 {
			ids = append(ids, n.ID)
		}
	}
	return ids
}

// topNByDegree keeps the max most-connected nodes and the links BETWEEN them —
// the same "orbit the mass, don't ingest everything" move as the gravity render.
// Degree ranking (not insertion order) keeps the hubs that give a huge world its
// shape; ties break by original order so the cut is deterministic.
func topNByDegree(nodes, links []json.RawMessage, max int) ([]json.RawMessage, []json.RawMessage) {
	type end struct {
		Source int64 `json:"source"`
		Target int64 `json:"target"`
	}
	ends := make([]end, len(links))
	deg := map[int64]int{}
	for i, lr := range links {
		if json.Unmarshal(lr, &ends[i]) == nil {
			deg[ends[i].Source]++
			deg[ends[i].Target]++
		}
	}
	type ranked struct {
		idx int
		id  int64
		d   int
	}
	rank := make([]ranked, 0, len(nodes))
	for i, nr := range nodes {
		var n struct {
			ID int64 `json:"id"`
		}
		if json.Unmarshal(nr, &n) != nil {
			continue
		}
		rank = append(rank, ranked{idx: i, id: n.ID, d: deg[n.ID]})
	}
	sort.SliceStable(rank, func(a, b int) bool { return rank[a].d > rank[b].d })
	if max > len(rank) {
		max = len(rank)
	}
	keep := make(map[int64]bool, max)
	sel := append([]ranked(nil), rank[:max]...)
	// restore original node order so the payload (and force layout seed) is stable
	sort.Slice(sel, func(a, b int) bool { return sel[a].idx < sel[b].idx })
	outN := make([]json.RawMessage, 0, max)
	for _, s := range sel {
		keep[s.id] = true
		outN = append(outN, nodes[s.idx])
	}
	outL := make([]json.RawMessage, 0, len(links))
	for i, lr := range links {
		if keep[ends[i].Source] && keep[ends[i].Target] {
			outL = append(outL, lr)
		}
	}
	return outN, outL
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
	// metadata carries #301 item-1 detail (method/path/file_path/repo_origin for
	// code entities); world_ref is the world's extraction ref (#298). We surface
	// them on the detail path only (not on every graph node) so the drawer is rich
	// without bloating the whole-graph payload.
	var raw []byte
	err := d.Pool.QueryRow(ctx,
		`SELECT jsonb_build_object(
		    'id', e.entity_id, 'kind', e.kind, 'name', e.name, 'summary', e.summary,
		    'aliases', e.aliases, 'source_refs', e.source_refs,
		    'metadata', e.metadata, 'world_ref', w.metadata->>'ref',
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

	// #301 item 5: build a "↗ source" link server-side (the normalizer is a
	// unit-tested Go helper — see world_source.go) from the entity's repo_origin +
	// file_path and the world's ref. Absent provenance → no source_url (the UI just
	// omits the link). world_ref was only needed to build it, so drop it after.
	var m map[string]any
	if json.Unmarshal(raw, &m) == nil {
		var origin, filePath string
		if meta, ok := m["metadata"].(map[string]any); ok {
			origin, _ = meta["repo_origin"].(string)
			filePath, _ = meta["file_path"].(string)
		}
		ref, _ := m["world_ref"].(string)
		if u := repoBlobURL(origin, ref, filePath); u != "" {
			m["source_url"] = u
		}
		delete(m, "world_ref")
		if b, mErr := json.Marshal(m); mErr == nil {
			raw = b
		}
	}

	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_, _ = w.Write(raw)
}
