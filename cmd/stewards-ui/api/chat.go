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
}

// session ids are derived from a target ref; keep them to a safe charset.
var sessionSafe = regexp.MustCompile(`[^a-zA-Z0-9_-]+`)

type chatSendReq struct {
	SessionID string `json:"session_id,omitempty"` // explicit session (a "new chat" picks a fresh one)
	TargetRef string `json:"target_ref,omitempty"` // the doc slug / work_item id the chat is grounded in
	Message   string `json:"message"`
	Model     string `json:"model,omitempty"` // role alias / model id; default 'reason' (→ local rig via overlay)
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
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
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

	var wqID int64
	if err := d.Pool.QueryRow(ctx,
		`SELECT stewards.dispatch_chat_turn($1, $2, 'work-item-chat', $3, $4)`,
		sid, req.Message, model, grounding,
	).Scan(&wqID); err != nil {
		log.Printf("api: chat dispatch (session=%s, model=%s): %v", sid, model, err)
		writeErr(w, http.StatusInternalServerError, "dispatch: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, chatSendResp{SessionID: sid, WorkQueueID: wqID})
}

type chatStreamMsg struct {
	ID           int64  `json:"id"`
	Role         string `json:"role"`
	Content      string `json:"content"`
	FinishReason string `json:"finish_reason,omitempty"`
	ToolCalls    int    `json:"tool_calls"`
	CreatedAt    string `json:"created_at,omitempty"`
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
			if rows.Scan(&m.ID, &m.Role, &m.Content, &m.FinishReason, &m.ToolCalls, &m.CreatedAt) == nil {
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
