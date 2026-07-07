// Raw model test-chat — the Models-page "does this model actually answer?"
// panel. Unlike Stewdio's agentic chat (tools, skills, agent family, work-item
// spawning), this is a bare send/receive: pick any (provider, model), send a
// prompt, get the completion back. It enqueues a work_queue kind='chat' row
// DIRECTLY (mirroring enqueue_model_probe's shape) with tools_disabled=true and
// no tools in the body, so it exercises the REAL dispatcher — and therefore the
// wizard-configured provider auth, including the Vertex service-account JSON
// path — without any of the agent loop. The assistant reply lands in
// stewards.messages by session_id; the poll endpoint tails it. No '_probe' key,
// so the model-probe verdict trigger never fires (this never touches
// model_capability).
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func (d *Deps) registerModelTestChat(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/models/test-chat/send", d.modelTestChatSendHandler)
	mux.HandleFunc("GET /api/models/test-chat/poll", d.modelTestChatPollHandler)
}

// Session ids are operator-facing keys; keep them to a safe charset.
var testChatSessionSanitize = regexp.MustCompile(`[^a-z0-9_-]+`)

type testChatSendReq struct {
	Provider  string `json:"provider"`
	Model     string `json:"model"`
	SessionID string `json:"session_id"` // "" → server mints one for a new conversation
	Prompt    string `json:"prompt"`
	System    string `json:"system"` // optional system preamble (applied on the first turn)
}

type testChatSendResp struct {
	SessionID     string `json:"session_id"`
	WorkQueueID   int64  `json:"work_queue_id"`
	UserMessageID int64  `json:"user_message_id"` // poll cursor: the assistant reply lands at a higher id
}

// POST /api/models/test-chat/send {provider, model, session_id?, prompt, system?}
// Appends the user turn to a (possibly new) session and enqueues a raw, no-tools
// completion pinned to (provider, model). Returns the session id + the message
// id to poll after.
func (d *Deps) modelTestChatSendHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	var req testChatSendReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad json: "+err.Error())
		return
	}
	req.Provider = strings.TrimSpace(req.Provider)
	req.Model = strings.TrimSpace(req.Model)
	req.Prompt = strings.TrimSpace(req.Prompt)
	if req.Provider == "" || req.Model == "" || req.Prompt == "" {
		writeErr(w, http.StatusBadRequest, "provider, model, and prompt are required")
		return
	}

	// Reuse the caller's session for a continuing conversation, else mint a
	// fresh one. The 'modeltest-' prefix keeps these out of the Stewdio session
	// lists and off the doc/work-item triggers.
	sessionID := strings.TrimSpace(req.SessionID)
	if sessionID == "" {
		raw := fmt.Sprintf("modeltest-%s-%s-%d", req.Provider, req.Model, time.Now().UnixNano())
		sessionID = testChatSessionSanitize.ReplaceAllString(strings.ToLower(raw), "-")
	}
	if len(sessionID) > 190 {
		sessionID = sessionID[:190]
	}

	// The session must exist before a message can reference it (messages.session_id FK).
	if _, err := d.Pool.Exec(ctx,
		`INSERT INTO stewards.sessions (id, label, kind)
		 VALUES ($1, $2, 'chat') ON CONFLICT (id) DO NOTHING`,
		sessionID, "model test-chat "+req.Provider+"/"+req.Model); err != nil {
		writeErr(w, http.StatusInternalServerError, "ensure session: "+err.Error())
		return
	}

	// Build the wire history from prior turns (user/assistant only — a raw chat
	// has no tool rows), prepend an optional first-turn system preamble, then
	// append this user turn.
	msgs := make([]map[string]any, 0, 8)
	rows, err := d.Pool.Query(ctx,
		`SELECT role, content FROM stewards.messages
		  WHERE session_id = $1 AND role IN ('user','assistant')
		  ORDER BY id`, sessionID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "read history: "+err.Error())
		return
	}
	hadHistory := false
	for rows.Next() {
		var role, content string
		if rows.Scan(&role, &content) == nil {
			msgs = append(msgs, map[string]any{"role": role, "content": content})
			hadHistory = true
		}
	}
	rows.Close()
	if req.System != "" && !hadHistory {
		msgs = append([]map[string]any{{"role": "system", "content": req.System}}, msgs...)
	}
	msgs = append(msgs, map[string]any{"role": "user", "content": req.Prompt})

	// Persist the user turn (built msgs first, so it isn't double-counted) — it
	// becomes history for the next send and survives a page reload.
	var userMsgID int64
	if err := d.Pool.QueryRow(ctx,
		`INSERT INTO stewards.messages (session_id, role, content, model)
		 VALUES ($1, 'user', $2, $3) RETURNING id`,
		sessionID, req.Prompt, req.Model).Scan(&userMsgID); err != nil {
		writeErr(w, http.StatusInternalServerError, "persist user turn: "+err.Error())
		return
	}

	// The raw-completion payload: like enqueue_model_probe's direct work_queue
	// insert, but tools_disabled=true and NO tools/tool_choice — a bare
	// send/receive. No '_probe' key (keeps the verdict trigger out).
	payload := map[string]any{
		"session_id":      sessionID,
		"agent_family":    "model-test",
		"requested_model": req.Model,
		"tools_disabled":  true,
		"body": map[string]any{
			"model":      req.Model,
			"max_tokens": 1024,
			"messages":   msgs,
		},
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "marshal payload: "+err.Error())
		return
	}

	var workID int64
	if err := d.Pool.QueryRow(ctx,
		`INSERT INTO stewards.work_queue (kind, provider, payload)
		 VALUES ('chat', $1, $2::jsonb) RETURNING id`,
		req.Provider, payloadJSON).Scan(&workID); err != nil {
		writeErr(w, http.StatusInternalServerError, "enqueue: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, testChatSendResp{
		SessionID:     sessionID,
		WorkQueueID:   workID,
		UserMessageID: userMsgID,
	})
}

type testChatMsg struct {
	ID      int64  `json:"id"`
	Role    string `json:"role"`
	Content string `json:"content"`
}

type testChatPollResp struct {
	Status   string        `json:"status"`             // work_queue status: pending|in_progress|waiting_for_tools|done|error
	Error    string        `json:"error,omitempty"`    // the dispatch error when status='error'
	Messages []testChatMsg `json:"messages"`           // new messages after ?since (the assistant reply lands here)
	Done     bool          `json:"done"`               // status in (done,error) — stop polling
}

// GET /api/models/test-chat/poll?session_id=&since=&work_queue_id=
// Returns messages newer than ?since for the session plus the work_queue row's
// status/error, so the panel can show a spinner then the reply (or the failure).
func (d *Deps) modelTestChatPollHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	sessionID := strings.TrimSpace(r.URL.Query().Get("session_id"))
	if sessionID == "" {
		writeErr(w, http.StatusBadRequest, "session_id is required")
		return
	}
	since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
	workID, _ := strconv.ParseInt(r.URL.Query().Get("work_queue_id"), 10, 64)

	resp := testChatPollResp{Messages: []testChatMsg{}}

	// New messages since the cursor — the assistant reply (and any subsequent
	// turns) land here once the bgworker completes the dispatch.
	rows, err := d.Pool.Query(ctx,
		`SELECT id, role, content FROM stewards.messages
		  WHERE session_id = $1 AND id > $2
		  ORDER BY id`, sessionID, since)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	for rows.Next() {
		var m testChatMsg
		if rows.Scan(&m.ID, &m.Role, &m.Content) == nil {
			resp.Messages = append(resp.Messages, m)
		}
	}
	rows.Close()

	// Work-queue status — drives the spinner and surfaces a dispatch failure
	// (bad key, provider down, cap hit) instead of an endless "thinking".
	if workID > 0 {
		var status string
		var qErr *string
		if err := d.Pool.QueryRow(ctx,
			`SELECT status, error FROM stewards.work_queue WHERE id = $1`,
			workID).Scan(&status, &qErr); err == nil {
			resp.Status = status
			if qErr != nil {
				resp.Error = *qErr
			}
			resp.Done = status == "done" || status == "error"
		}
	}

	writeJSON(w, http.StatusOK, resp)
}
