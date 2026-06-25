// Objects — the content registry's read surface (O1: "bring the content back").
//
// The substrate already stores source media as durable bytes in
// stewards.chat_attachments (bytea): uploaded images + documents, and a PDF's
// rendered page images (parent_id → the source document). Those bytes are served
// by /api/chat/attachment/{id}, but until now they were reachable only from the
// chat that uploaded them. These endpoints make them BROWSABLE — a media library
// the cockpit can list and open — without moving any bytes.
//
//   GET /api/object/list?kind=&limit=   top-level stored media (images + documents)
//   GET /api/object/pages?att=<id>      a document's rendered page images (PDF flip)
//
// Docs (studies / digests / books / videos) are already browsable via
// /api/studies/list, so this covers the other half of the registry: the binary
// objects. No new SQL — plain reads over the existing tables.
package api

import (
	"context"
	"net/http"
	"strconv"
	"time"
)

func (d *Deps) registerObjects(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/object/list", d.objectListHandler)
	mux.HandleFunc("GET /api/object/pages", d.objectPagesHandler)
}

type objectBrief struct {
	ID        int64      `json:"id"`
	Locator   string     `json:"locator"` // att:<id> — the stable handle
	Kind      string     `json:"kind"`    // image | document
	Filename  string     `json:"filename"`
	Mime      string     `json:"mime"`
	ByteSize  int64      `json:"byte_size"`
	Session   string     `json:"session_id,omitempty"`
	Pages     int        `json:"pages"` // rendered page images (documents); 0 otherwise
	URL       string     `json:"url"`   // GET to render/download the bytes
	CreatedAt *time.Time `json:"created_at,omitempty"`
}

type objectListResp struct {
	Items []objectBrief `json:"items"`
}

// objectListHandler — top-level stored media (parent_id IS NULL, so page images
// ride their parent and don't clutter the list). Newest first.
func (d *Deps) objectListHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	q := r.URL.Query()
	kind := q.Get("kind") // optional: image | document
	limit := atoiDefault(q.Get("limit"), 200, 1, 1000)

	resp := objectListResp{Items: []objectBrief{}}
	sql := `SELECT a.id, coalesce(a.kind,'document'),
	               coalesce(a.filename,'attachment'),
	               coalesce(a.mime_type,'application/octet-stream'),
	               coalesce(a.byte_size, octet_length(a.bytes), 0),
	               coalesce(a.session_id,''),
	               (SELECT count(*) FROM stewards.chat_attachments c
	                 WHERE c.parent_id = a.id AND c.kind='image'),
	               a.created_at
	          FROM stewards.chat_attachments a
	         WHERE a.parent_id IS NULL`
	args := []any{}
	if kind != "" {
		sql += ` AND a.kind = $1 ORDER BY a.id DESC LIMIT $2`
		args = append(args, kind, limit)
	} else {
		sql += ` ORDER BY a.id DESC LIMIT $1`
		args = append(args, limit)
	}

	rows, err := d.Pool.Query(ctx, sql, args...)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "object list: "+err.Error())
		return
	}
	defer rows.Close()
	for rows.Next() {
		var o objectBrief
		if err := rows.Scan(&o.ID, &o.Kind, &o.Filename, &o.Mime, &o.ByteSize,
			&o.Session, &o.Pages, &o.CreatedAt); err == nil {
			o.Locator = "att:" + strconv.FormatInt(o.ID, 10)
			o.URL = "/api/chat/attachment/" + strconv.FormatInt(o.ID, 10)
			resp.Items = append(resp.Items, o)
		}
	}
	writeJSON(w, http.StatusOK, resp)
}

type objectPage struct {
	ID   int64  `json:"id"`
	Mime string `json:"mime"`
	URL  string `json:"url"`
}

type objectPagesResp struct {
	Pages []objectPage `json:"pages"`
}

// objectPagesHandler — the rendered page images of a document attachment, in
// order, so the viewer can flip through a PDF's pages (P3c stored these as child
// image attachments with parent_id = the document).
func (d *Deps) objectPagesHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	att, err := strconv.ParseInt(r.URL.Query().Get("att"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad att id")
		return
	}
	resp := objectPagesResp{Pages: []objectPage{}}
	rows, err := d.Pool.Query(ctx,
		`SELECT id, coalesce(mime_type,'image/png')
		   FROM stewards.chat_attachments
		  WHERE parent_id = $1 AND kind='image'
		  ORDER BY id`, att)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "object pages: "+err.Error())
		return
	}
	defer rows.Close()
	for rows.Next() {
		var p objectPage
		if err := rows.Scan(&p.ID, &p.Mime); err == nil {
			p.URL = "/api/chat/attachment/" + strconv.FormatInt(p.ID, 10)
			resp.Pages = append(resp.Pages, p)
		}
	}
	writeJSON(w, http.StatusOK, resp)
}
