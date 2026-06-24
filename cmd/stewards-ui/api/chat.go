// chat endpoints — Stewdio's "chat with a work item" panel.
//
//	POST /api/chat/send      — append a user turn + dispatch it (substrate
//	                           dispatch_chat_turn → bgworker tool loop, local model).
//	GET  /api/chat/stream    — SSE relay: tails stewards.messages for a session,
//	                           emitting each new row (user/assistant/tool) as a
//	                           `data:` frame. The substrate brokers the model call
//	                           through the DB, so this is a DB-poll relay (not a
//	                           provider token stream) — cost/trust accounting stays
//	                           intact. See .spec/proposals/stewards-studio.md (P1).

package api

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func (d *Deps) registerChat(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/chat/send", d.chatSendHandler)
	mux.HandleFunc("GET /api/chat/stream", d.chatStreamHandler)
	mux.HandleFunc("GET /api/chat/sessions", d.chatSessionsHandler)        // Stewdio P4: multi-session history
	mux.HandleFunc("GET /api/chat/sessions/all", d.chatSessionsAllHandler) // Sessions panel: EVERY chat session + its target
	mux.HandleFunc("POST /api/chat/attach", d.chatAttachHandler)           // rich-docs P2: upload media to a chat
	mux.HandleFunc("GET /api/chat/attachment/{id}", d.chatAttachmentHandler) // rich-docs P2: serve the bytes (inline render)
	mux.HandleFunc("GET /api/chat/projects", d.chatProjectsHandler)        // rich-docs P3d: the empty-chat lens picker
	mux.HandleFunc("GET /api/chat/export", d.chatExportHandler)            // Arc A: export a session transcript (md/json)
	mux.HandleFunc("POST /api/chat/stop", d.chatStopHandler)              // Arc A: cancel a session's not-yet-started chat turn(s)
}

// maxAttachmentBytes caps an uploaded file. Images fit comfortably; the :8090
// router caps at 256MB, but the chat compose carries the base64 inline so we
// keep attachments modest.
const maxAttachmentBytes = 25 << 20 // 25 MB

// session ids are derived from a target ref; keep them to a safe charset.
var sessionSafe = regexp.MustCompile(`[^a-zA-Z0-9_-]+`)

type chatSendReq struct {
	SessionID     string  `json:"session_id,omitempty"` // explicit session (a "new chat" picks a fresh one)
	TargetRef     string  `json:"target_ref,omitempty"` // the doc slug / work_item id the chat is grounded in
	Message       string  `json:"message"`
	Model         string  `json:"model,omitempty"`         // role alias / model id; default 'reason' (→ local rig via overlay)
	AttachmentIDs []int64 `json:"attachment_ids,omitempty"` // rich-docs P2: chat_attachments to inject as subject material
}

type chatSendResp struct {
	SessionID   string `json:"session_id"`
	WorkQueueID int64  `json:"work_queue_id"`
}

// chatSessionFor derives a deterministic session id from a target ref, so
// reopening the same work item resumes its conversation.
func chatSessionFor(targetRef string) string {
	base := strings.TrimSpace(targetRef)
	if base == "" {
		base = "adhoc"
	}
	sid := "stewdio-" + strings.Trim(sessionSafe.ReplaceAllString(base, "-"), "-")
	if len(sid) > 60 {
		sid = sid[:60]
	}
	return sid
}

func (d *Deps) chatSendHandler(w http.ResponseWriter, r *http.Request) {
	// dispatch_chat_turn enqueues synchronously, but it composes the system prompt
	// + tool schemas (and seeds grounding on the first turn) inline — that can take
	// several seconds for a tools-on agent, so give it real headroom. The reply
	// itself streams back over /api/chat/stream; this is just the enqueue.
	ctx, cancel := context.WithTimeout(r.Context(), 45*time.Second)
	defer cancel()

	var req chatSendReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "decode body: "+err.Error())
		return
	}
	if strings.TrimSpace(req.Message) == "" {
		writeErr(w, http.StatusBadRequest, "message is required")
		return
	}
	model := req.Model
	if model == "" {
		model = "reason" // a role alias → the local rig in a work instance (overlay)
	}
	sid := req.SessionID
	if sid == "" {
		sid = chatSessionFor(req.TargetRef)
	}

	// grounding is seeded only on the first turn (dispatch_chat_turn checks for an
	// empty session); harmless to pass every turn. NULL when there's no target.
	// A "project:<name>" ref is the empty-chat lens (P3d): ground in a corpus
	// rather than one work item — doc_search scopes the conversation to it.
	var grounding *string
	if ref := strings.TrimSpace(req.TargetRef); ref != "" {
		var g string
		if ref == "all" {
			g = "(Context: you are grounded in the ENTIRE knowledge pool — every work item and document across all " +
				"projects. Use doc_search broadly to find anything relevant; cite the docs you draw from. Attached " +
				"documents are injected as subject material — call doc_extract on any not-yet-read attachment.)"
		} else if proj, ok := strings.CutPrefix(ref, "project:"); ok {
			g = fmt.Sprintf("(Context: you are grounded in the project/corpus %q. Use doc_search to find and quote "+
				"its documents. Attached documents are injected as subject material — call doc_extract on any "+
				"not-yet-read attachment, and doc_import_corpus to fold an uploaded archive/folder into this project.)", proj)
		} else {
			g = fmt.Sprintf("(Context: you are discussing the work item / study doc identified by %q. "+
				"Use your retrieval tools — doc_get, doc_search, investigate_session — to ground every answer in it.)", ref)
		}
		grounding = &g
	}

	// rich-docs P2: when the turn carries attachments, the substrate assembles
	// them into the multimodal content array (chat_attachment_parts, session-
	// scoped, base64 built server-side) and dispatch_chat_turn auto-selects the
	// `vision` alias. No attachments → NULL → the text-only path (unchanged).
	var wqID int64
	if err := d.Pool.QueryRow(ctx,
		`SELECT stewards.dispatch_chat_turn($1, $2, 'work-item-chat', $3, $4,
		          CASE WHEN $5::bigint[] IS NULL OR cardinality($5::bigint[]) = 0 THEN NULL
		               ELSE stewards.chat_attachment_parts($5::bigint[], $1) END)`,
		sid, req.Message, model, grounding, req.AttachmentIDs,
	).Scan(&wqID); err != nil {
		log.Printf("api: chat dispatch (session=%s, model=%s, attachments=%d): %v", sid, model, len(req.AttachmentIDs), err)
		writeErr(w, http.StatusInternalServerError, "dispatch: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, chatSendResp{SessionID: sid, WorkQueueID: wqID})
}

type chatStreamMsg struct {
	ID           int64    `json:"id"`
	Role         string   `json:"role"`
	Content      string   `json:"content"`
	FinishReason string   `json:"finish_reason,omitempty"`
	ToolCalls    int      `json:"tool_calls"`
	Tools        []string `json:"tools,omitempty"`  // tool names called this turn → provenance chips (P4)
	Images       []string `json:"images,omitempty"` // rich-docs P2: image_url data URLs on a multimodal turn → render inline
	CreatedAt    string   `json:"created_at,omitempty"`
}

// chatStreamHandler tails a chat session's messages over SSE. It replays from
// `after` (0 = whole transcript) then keeps emitting new rows as the bgworker
// lands them. The connection lives until the client disconnects.
func (d *Deps) chatStreamHandler(w http.ResponseWriter, r *http.Request) {
	sid := r.URL.Query().Get("session_id")
	if sid == "" {
		writeErr(w, http.StatusBadRequest, "session_id required")
		return
	}
	after, _ := strconv.ParseInt(r.URL.Query().Get("after"), 10, 64)

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no") // defeat any reverse-proxy buffering
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	ctx := r.Context()
	last := after
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	emit := func() bool { // returns false on a fatal context error
		rows, err := d.Pool.Query(ctx,
			`SELECT id, role, coalesce(content,''), coalesce(finish_reason,''),
			        CASE WHEN jsonb_typeof(tool_calls)='array' THEN jsonb_array_length(tool_calls) ELSE 0 END,
			        CASE WHEN jsonb_typeof(tool_calls)='array'
			             THEN ARRAY(SELECT e->'function'->>'name'
			                          FROM jsonb_array_elements(tool_calls) e
			                         WHERE e->'function'->>'name' IS NOT NULL)
			             ELSE ARRAY[]::text[] END,
			        CASE WHEN jsonb_typeof(content_parts)='array'
			             THEN ARRAY(SELECT p->'image_url'->>'url'
			                          FROM jsonb_array_elements(content_parts) p
			                         WHERE p->>'type'='image_url' AND p->'image_url'->>'url' IS NOT NULL)
			             ELSE ARRAY[]::text[] END,
			        to_char(created_at,'HH24:MI:SS')
			   FROM stewards.messages
			  WHERE session_id=$1 AND id > $2
			  ORDER BY id`, sid, last)
		if err != nil {
			return ctx.Err() == nil // transient query error → keep trying; ctx-cancel → stop
		}
		defer rows.Close()
		for rows.Next() {
			var m chatStreamMsg
			if rows.Scan(&m.ID, &m.Role, &m.Content, &m.FinishReason, &m.ToolCalls, &m.Tools, &m.Images, &m.CreatedAt) == nil {
				last = m.ID
				if b, e := json.Marshal(m); e == nil {
					fmt.Fprintf(w, "data: %s\n\n", b)
				}
			}
		}
		flusher.Flush()
		return true
	}

	if !emit() { // initial drain (replay)
		return
	}
	beat := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if !emit() {
				return
			}
			beat++
			if beat%20 == 0 { // ~10s heartbeat comment keeps the connection warm
				fmt.Fprint(w, ": ping\n\n")
				flusher.Flush()
			}
		}
	}
}

// ── chat sessions — the conversation history sidebar (Stewdio P4). ──
// A target can have several conversations: the deterministic base session
// (stewdio-<ref>) plus "new chat" sessions (base + "-" + a short suffix).
// List them all for a target_ref, newest activity first, with a preview.
type chatSessionRow struct {
	SessionID string `json:"session_id"`
	Preview   string `json:"preview,omitempty"`
	LastAt    string `json:"last_at,omitempty"`
	MsgCount  int    `json:"msg_count"`
	IsDefault bool   `json:"is_default"`
}

type chatSessionsResp struct {
	DefaultSession string           `json:"default_session"`
	Sessions       []chatSessionRow `json:"sessions"`
}

func (d *Deps) chatSessionsHandler(w http.ResponseWriter, r *http.Request) {
	ref := strings.TrimSpace(r.URL.Query().Get("target_ref"))
	if ref == "" {
		writeErr(w, http.StatusBadRequest, "target_ref required")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 8*time.Second)
	defer cancel()

	base := chatSessionFor(ref)
	rows, err := d.Pool.Query(ctx,
		`SELECT s.id,
		        coalesce((SELECT m.content FROM stewards.messages m
		                   WHERE m.session_id = s.id AND m.role='user'
		                     AND m.content NOT LIKE '(Context:%'
		                   ORDER BY m.id LIMIT 1), ''),
		        coalesce(to_char((SELECT max(m.created_at) FROM stewards.messages m WHERE m.session_id=s.id),
		                         'YYYY-MM-DD HH24:MI'), ''),
		        (SELECT count(*)::int FROM stewards.messages m WHERE m.session_id=s.id)
		   FROM stewards.sessions s
		  WHERE s.kind='chat' AND (s.id = $1 OR s.id LIKE $1 || '-%')
		  ORDER BY (SELECT max(m.created_at) FROM stewards.messages m WHERE m.session_id=s.id) DESC NULLS LAST, s.id`,
		base)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "sessions: "+err.Error())
		return
	}
	defer rows.Close()
	out := chatSessionsResp{DefaultSession: base, Sessions: []chatSessionRow{}}
	for rows.Next() {
		var s chatSessionRow
		if rows.Scan(&s.SessionID, &s.Preview, &s.LastAt, &s.MsgCount) == nil {
			s.IsDefault = s.SessionID == base
			if len(s.Preview) > 80 {
				s.Preview = s.Preview[:80]
			}
			out.Sessions = append(out.Sessions, s)
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// chatAllSessionRow — a global chat session for the cockpit's Sessions panel.
type chatAllSessionRow struct {
	SessionID  string `json:"session_id"`
	Preview    string `json:"preview,omitempty"`
	LastAt     string `json:"last_at,omitempty"`
	MsgCount   int    `json:"msg_count"`
	TargetRef  string `json:"target_ref,omitempty"`  // work_item id / doc slug / "project:x" / "all"
	TargetKind string `json:"target_kind,omitempty"` // work_item | doc | project | all | unknown
	Title      string `json:"title,omitempty"`       // resolved work-item slug / doc title / friendly label
}

// regexes that recover the grounding target from the stored "(Context: …)" turn
// (the shapes chatSendHandler writes). UUID test → work_item vs doc.
var (
	ctxRefRe     = regexp.MustCompile(`identified by "([^"]+)"`)
	ctxProjectRe = regexp.MustCompile(`project/corpus "([^"]+)"`)
	uuidRe       = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)
)

// GET /api/chat/sessions/all — EVERY Stewdio chat session, newest first, so the
// cockpit can list them and reopen any. Closes the gap: a chat started on a work
// item you've since navigated away from was otherwise unreachable.
func (d *Deps) chatSessionsAllHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	rows, err := d.Pool.Query(ctx,
		`SELECT s.id,
		        coalesce((SELECT m.content FROM stewards.messages m
		                   WHERE m.session_id=s.id AND m.role='user' AND m.content NOT LIKE '(Context:%'
		                   ORDER BY m.id LIMIT 1), ''),
		        coalesce(to_char((SELECT max(m.created_at) FROM stewards.messages m WHERE m.session_id=s.id),
		                         'YYYY-MM-DD HH24:MI'), ''),
		        (SELECT count(*)::int FROM stewards.messages m WHERE m.session_id=s.id),
		        coalesce((SELECT m.content FROM stewards.messages m
		                   WHERE m.session_id=s.id AND m.content LIKE '(Context:%'
		                   ORDER BY m.id LIMIT 1), '')
		   FROM stewards.sessions s
		  WHERE s.kind='chat' AND s.id LIKE 'stewdio-%'
		  ORDER BY (SELECT max(m.created_at) FROM stewards.messages m WHERE m.session_id=s.id) DESC NULLS LAST
		  LIMIT 200`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "sessions: "+err.Error())
		return
	}
	defer rows.Close()
	out := []chatAllSessionRow{}
	var wiIDs, docSlugs []string
	for rows.Next() {
		var s chatAllSessionRow
		var ctxLine string
		if rows.Scan(&s.SessionID, &s.Preview, &s.LastAt, &s.MsgCount, &ctxLine) != nil {
			continue
		}
		if len(s.Preview) > 120 {
			s.Preview = s.Preview[:120]
		}
		// derive the grounding target from the stored context turn.
		switch {
		case strings.Contains(ctxLine, "ENTIRE knowledge pool"):
			s.TargetRef, s.TargetKind, s.Title = "all", "all", "✸ Everything"
		case ctxProjectRe.MatchString(ctxLine):
			name := ctxProjectRe.FindStringSubmatch(ctxLine)[1]
			s.TargetRef, s.TargetKind, s.Title = "project:"+name, "project", name
		case ctxRefRe.MatchString(ctxLine):
			ref := ctxRefRe.FindStringSubmatch(ctxLine)[1]
			s.TargetRef = ref
			if uuidRe.MatchString(ref) {
				s.TargetKind = "work_item"
				wiIDs = append(wiIDs, ref)
			} else {
				s.TargetKind = "doc"
				docSlugs = append(docSlugs, ref)
			}
		default:
			s.TargetKind = "unknown"
		}
		out = append(out, s)
	}
	// batch-resolve friendly titles for work items + docs.
	titles := map[string]string{}
	if len(wiIDs) > 0 {
		if r2, e := d.Pool.Query(ctx, `SELECT id::text, slug FROM stewards.work_items WHERE id = ANY($1::uuid[])`, wiIDs); e == nil {
			for r2.Next() {
				var id, slug string
				if r2.Scan(&id, &slug) == nil {
					titles[id] = slug
				}
			}
			r2.Close()
		}
	}
	if len(docSlugs) > 0 {
		if r2, e := d.Pool.Query(ctx, `SELECT slug, coalesce(title, slug) FROM stewards.docs WHERE slug = ANY($1)`, docSlugs); e == nil {
			for r2.Next() {
				var slug, title string
				if r2.Scan(&slug, &title) == nil {
					titles[slug] = title
				}
			}
			r2.Close()
		}
	}
	for i := range out {
		if t, ok := titles[out[i].TargetRef]; ok && t != "" {
			out[i].Title = t
		} else if out[i].Title == "" {
			out[i].Title = out[i].TargetRef
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"sessions": out})
}

// ── chat attachments — upload media as injectable subject material (P2). ──
// A multipart upload (field "file") + a session (session_id or target_ref,
// resolved the same way as /chat/send so the attachment's session matches the
// dispatch). Stored in stewards.chat_attachments (bytea); the next /chat/send
// references the returned id(s) and the substrate assembles the content_parts.

type chatAttachResp struct {
	ID        int64  `json:"id"`
	SessionID string `json:"session_id"`
	Filename  string `json:"filename"`
	MimeType  string `json:"mime_type"`
	Kind      string `json:"kind"`
	ByteSize  int    `json:"byte_size"`
	URL       string `json:"url"` // GET this to render the bytes inline
}

func (d *Deps) chatAttachHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	if err := r.ParseMultipartForm(maxAttachmentBytes); err != nil {
		writeErr(w, http.StatusBadRequest, "parse multipart: "+err.Error())
		return
	}
	file, hdr, err := r.FormFile("file")
	if err != nil {
		writeErr(w, http.StatusBadRequest, "missing file field: "+err.Error())
		return
	}
	defer file.Close()

	// resolve the session id the same way /chat/send does, so the attachment
	// lands under the session the turn will dispatch with.
	sid := strings.TrimSpace(r.FormValue("session_id"))
	if sid == "" {
		sid = chatSessionFor(r.FormValue("target_ref"))
	}

	data, err := io.ReadAll(io.LimitReader(file, maxAttachmentBytes+1))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "read file: "+err.Error())
		return
	}
	if len(data) > maxAttachmentBytes {
		writeErr(w, http.StatusRequestEntityTooLarge,
			fmt.Sprintf("file exceeds the %d MB limit", maxAttachmentBytes>>20))
		return
	}

	// mime: trust the multipart header, else sniff. kind: image -> vision; else
	// document (inert until P3 extraction populates extracted_text).
	mimeType := hdr.Header.Get("Content-Type")
	if mimeType == "" || mimeType == "application/octet-stream" {
		mimeType = http.DetectContentType(data)
	}
	kind := "document"
	if strings.HasPrefix(mimeType, "image/") {
		kind = "image"
	}
	filename := hdr.Filename
	if filename == "" {
		filename = "attachment"
	}

	var resp chatAttachResp
	if err := d.Pool.QueryRow(ctx,
		`INSERT INTO stewards.chat_attachments (session_id, filename, mime_type, kind, bytes, byte_size)
		 VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
		sid, filename, mimeType, kind, data, len(data),
	).Scan(&resp.ID); err != nil {
		log.Printf("api: chat attach (session=%s): %v", sid, err)
		writeErr(w, http.StatusInternalServerError, "store attachment: "+err.Error())
		return
	}
	resp.SessionID = sid
	resp.Filename = filename
	resp.MimeType = mimeType
	resp.Kind = kind
	resp.ByteSize = len(data)
	resp.URL = fmt.Sprintf("/api/chat/attachment/%d", resp.ID)
	writeJSON(w, http.StatusOK, resp)
}

// chatAttachmentHandler serves an attachment's bytes (so the UI renders an
// uploaded image inline). Read-only; the bytes are the durable original.
func (d *Deps) chatAttachmentHandler(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad attachment id")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	// ?meta=1 → JSON metadata only (no bytes) — the chat's artifact cards fetch
	// this to render filename / type / size without pulling the whole file.
	if r.URL.Query().Get("meta") == "1" {
		var fn, mime, kind string
		var size int64
		if err := d.Pool.QueryRow(ctx,
			`SELECT coalesce(filename,''), coalesce(mime_type,'application/octet-stream'),
			        coalesce(kind,''), coalesce(byte_size, octet_length(bytes), 0)
			   FROM stewards.chat_attachments WHERE id = $1`, id,
		).Scan(&fn, &mime, &kind, &size); err != nil {
			writeErr(w, http.StatusNotFound, "attachment not found")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"id": id, "filename": fn, "mime_type": mime, "kind": kind, "byte_size": size,
		})
		return
	}

	var mimeType, filename string
	var data []byte
	if err := d.Pool.QueryRow(ctx,
		`SELECT coalesce(mime_type,'application/octet-stream'), coalesce(filename,''), bytes
		   FROM stewards.chat_attachments WHERE id = $1`, id,
	).Scan(&mimeType, &filename, &data); err != nil {
		writeErr(w, http.StatusNotFound, "attachment not found")
		return
	}
	w.Header().Set("Content-Type", mimeType)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	// ?download=1 → force a save dialog with the real filename (artifact card ⬇).
	if r.URL.Query().Get("download") == "1" && filename != "" {
		w.Header().Set("Content-Disposition", "attachment; filename=\""+strings.ReplaceAll(filename, "\"", "")+"\"")
	}
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

// ── chat projects — the empty-chat lens picker (rich-docs P3d). ──
// A chat with no work-item target can instead be grounded in a PROJECT/corpus:
// the user picks a lens here, the chat dispatches with target_ref="project:<n>",
// and doc_search scopes the conversation to that project's pooled docs. The
// lens options are the distinct project_associations across the docs pool +
// work items + intent slugs.
type chatProject struct {
	Name     string `json:"name"`
	DocCount int    `json:"doc_count"`
}
type chatProjectsResp struct {
	Projects []chatProject `json:"projects"`
}

func (d *Deps) chatProjectsHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 6*time.Second)
	defer cancel()

	rows, err := d.Pool.Query(ctx, `
		WITH proj AS (
		    SELECT project_association AS name, count(*)::int AS docs
		      FROM stewards.docs
		     WHERE nullif(btrim(project_association), '') IS NOT NULL
		     GROUP BY project_association
		    UNION
		    SELECT project_association, 0
		      FROM stewards.work_items
		     WHERE nullif(btrim(project_association), '') IS NOT NULL
		    UNION
		    SELECT slug, 0 FROM stewards.intents
		)
		SELECT name, max(docs) AS docs
		  FROM proj
		 GROUP BY name
		 ORDER BY max(docs) DESC, name`)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "projects: "+err.Error())
		return
	}
	defer rows.Close()
	out := chatProjectsResp{Projects: []chatProject{}}
	for rows.Next() {
		var p chatProject
		if rows.Scan(&p.Name, &p.DocCount) == nil && strings.TrimSpace(p.Name) != "" {
			out.Projects = append(out.Projects, p)
		}
	}
	writeJSON(w, http.StatusOK, out)
}

// ── chat stop — cancel a session's pending chat turn(s) (Arc A). ──
// POST /api/chat/stop {session_id}. Cancels work_queue rows that the bgworker
// has not yet claimed (status='pending'); an already-in-progress turn completes
// (the bgworker doesn't poll a cancel flag mid provider call), but the UI stops
// waiting. Honest + easily-extended to a real mid-flight cancel later.
func (d *Deps) chatStopHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SessionID string `json:"session_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.SessionID) == "" {
		writeErr(w, http.StatusBadRequest, "session_id required")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 6*time.Second)
	defer cancel()
	tag, err := d.Pool.Exec(ctx,
		`UPDATE stewards.work_queue
		    SET status='error', error='cancelled by user', done_at=now()
		  WHERE kind='chat' AND status='pending' AND payload->>'session_id' = $1`,
		req.SessionID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "stop: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"cancelled": tag.RowsAffected()})
}

// ── chat export — get a conversation OUT of the substrate (Arc A). ──
// GET /api/chat/export?session_id=&format=md|json → a downloadable transcript.
// md = a readable conversation; json = the raw rows (id/role/content/tools/created).
func (d *Deps) chatExportHandler(w http.ResponseWriter, r *http.Request) {
	sid := strings.TrimSpace(r.URL.Query().Get("session_id"))
	if sid == "" {
		writeErr(w, http.StatusBadRequest, "session_id required")
		return
	}
	format := r.URL.Query().Get("format")
	if format == "" {
		format = "md"
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	rows, err := d.Pool.Query(ctx,
		`SELECT id, role, coalesce(content,''), coalesce(to_char(created_at,'YYYY-MM-DD HH24:MI:SS'),'')
		   FROM stewards.messages
		  WHERE session_id=$1 AND coalesce(content,'') <> '' AND content NOT LIKE '(Context:%'
		  ORDER BY id`, sid)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "export: "+err.Error())
		return
	}
	defer rows.Close()
	type turn struct {
		ID      int64  `json:"id"`
		Role    string `json:"role"`
		Content string `json:"content"`
		At      string `json:"at,omitempty"`
	}
	var turns []turn
	for rows.Next() {
		var t turn
		if rows.Scan(&t.ID, &t.Role, &t.Content, &t.At) == nil {
			turns = append(turns, t)
		}
	}
	safe := sessionSafe.ReplaceAllString(sid, "-")
	if format == "json" {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"%s.json\"", safe))
		_ = json.NewEncoder(w).Encode(map[string]any{"session_id": sid, "turns": turns})
		return
	}
	var b strings.Builder
	fmt.Fprintf(&b, "# Conversation: %s\n\n", sid)
	for _, t := range turns {
		who := t.Role
		switch t.Role {
		case "user":
			who = "You"
		case "assistant":
			who = "Stewards"
		}
		fmt.Fprintf(&b, "## %s%s\n\n%s\n\n", who, func() string {
			if t.At != "" {
				return " · " + t.At
			}
			return ""
		}(), t.Content)
	}
	w.Header().Set("Content-Type", "text/markdown; charset=utf-8")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=\"%s.md\"", safe))
	_, _ = w.Write([]byte(b.String()))
}
