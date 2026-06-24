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
	mux.HandleFunc("POST /api/chat/attach", d.chatAttachHandler)           // rich-docs P2: upload media to a chat
	mux.HandleFunc("GET /api/chat/attachment/{id}", d.chatAttachmentHandler) // rich-docs P2: serve the bytes (inline render)
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
	var grounding *string
	if strings.TrimSpace(req.TargetRef) != "" {
		g := fmt.Sprintf("(Context: you are discussing the work item / study doc identified by %q. "+
			"Use your retrieval tools — doc_get, doc_search, investigate_session — to ground every answer in it.)", req.TargetRef)
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

	var mimeType string
	var data []byte
	if err := d.Pool.QueryRow(ctx,
		`SELECT coalesce(mime_type,'application/octet-stream'), bytes
		   FROM stewards.chat_attachments WHERE id = $1`, id,
	).Scan(&mimeType, &data); err != nil {
		writeErr(w, http.StatusNotFound, "attachment not found")
		return
	}
	w.Header().Set("Content-Type", mimeType)
	w.Header().Set("Cache-Control", "private, max-age=3600")
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
