// A2A / Open Engine HTTP surface — /api/a2a/*.
//
// The MCP tools (cmd/stewards-mcp/a2a.go) let MCP-speaking agents (my
// Claude Code session, the personas) drive the engine. This is the plain
// REST mirror so a NON-MCP agent (agy over curl, a future external A2A
// client) can participate too — the spec's "MCP + minimal /api/a2a".
// Every handler is a thin passthrough to a 69-a2a-engine.sql verb
// returning jsonb. Phase 1 is local/my-agents (the UI binds localhost);
// token auth + scope walls are the Phase-2 standard wrapper.

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"time"
)

func (d *Deps) registerA2A(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/a2a/register", d.a2aRegisterHandler)
	mux.HandleFunc("GET /api/a2a/inbox", d.a2aInboxHandler)
	mux.HandleFunc("POST /api/a2a/submit", d.a2aSubmitHandler)
	mux.HandleFunc("POST /api/a2a/claim", d.a2aClaimHandler)
	mux.HandleFunc("POST /api/a2a/needs-input", d.a2aNeedsInputHandler)
	mux.HandleFunc("POST /api/a2a/answer", d.a2aAnswerHandler)
	mux.HandleFunc("POST /api/a2a/receipt", d.a2aReceiptHandler)
	mux.HandleFunc("POST /api/a2a/note", d.a2aNoteHandler)
	mux.HandleFunc("POST /api/a2a/note-clear", d.a2aNoteClearHandler)
}

// a2aQuery runs a verb returning jsonb and writes it straight through.
func (d *Deps) a2aQuery(w http.ResponseWriter, r *http.Request, sql string, args ...any) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	var raw json.RawMessage
	if err := d.Pool.QueryRow(ctx, sql, args...).Scan(&raw); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

// decodeBody reads a JSON request body into a map; empty body → empty map.
func decodeBody(r *http.Request) (map[string]any, error) {
	m := map[string]any{}
	if r.Body == nil {
		return m, nil
	}
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(&m); err != nil && err.Error() != "EOF" {
		return nil, err
	}
	return m, nil
}

// str pulls a string field (empty → SQL NULL).
func str(m map[string]any, k string) any {
	if v, ok := m[k].(string); ok && v != "" {
		return v
	}
	return nil
}

// jsonbField re-marshals a nested object/array field for a ::jsonb cast
// (nil when absent so the verb coalesces to its default).
func jsonbField(m map[string]any, k string) any {
	v, ok := m[k]
	if !ok || v == nil {
		return nil
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil
	}
	return b
}

func (d *Deps) a2aRegisterHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.a2a_register($1,$2,$3,$4,$5::jsonb,$6,$7,$8::jsonb)`,
		str(m, "agent_id"), str(m, "display_name"), str(m, "kind"), str(m, "lane"),
		jsonbField(m, "capabilities"), str(m, "delivery"), str(m, "endpoint"), jsonbField(m, "scope"))
}

func (d *Deps) a2aInboxHandler(w http.ResponseWriter, r *http.Request) {
	agent := r.URL.Query().Get("agent_id")
	if agent == "" {
		writeErr(w, http.StatusBadRequest, "agent_id query param is required")
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.a2a_inbox($1)`, agent)
}

func (d *Deps) a2aSubmitHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.a2a_submit($1,$2,$3::jsonb,$4,$5,$6,$7)`,
		str(m, "assignee"), str(m, "title"), jsonbField(m, "spec"),
		str(m, "owner"), str(m, "project"), str(m, "slug"), str(m, "intent"))
}

func (d *Deps) a2aClaimHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.a2a_claim($1::uuid,$2)`, str(m, "work_item_id"), str(m, "claimer"))
}

func (d *Deps) a2aNeedsInputHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.a2a_needs_input($1::uuid,$2)`, str(m, "work_item_id"), str(m, "question"))
}

func (d *Deps) a2aAnswerHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.a2a_answer($1::uuid,$2)`, str(m, "work_item_id"), str(m, "answer"))
}

func (d *Deps) a2aReceiptHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.a2a_receipt($1::uuid,$2,$3::jsonb)`,
		str(m, "work_item_id"), str(m, "summary"), jsonbField(m, "artifact"))
}

func (d *Deps) a2aNoteHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.a2a_note($1,$2,$3,$4)`,
		str(m, "recipient"), str(m, "body"), str(m, "sender"), str(m, "work_item_id"))
}

func (d *Deps) a2aNoteClearHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if id, ok := m["note_id"]; ok && id != nil {
		d.a2aQuery(w, r, `SELECT stewards.a2a_note_clear($1,$2::bigint)`, str(m, "recipient"), id)
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.a2a_note_clear($1,NULL)`, str(m, "recipient"))
}
