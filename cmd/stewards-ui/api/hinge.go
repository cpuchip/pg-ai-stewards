// Hinge tool-effect gate HTTP surface — /api/hinge/*.
//
// The Stewdio "Needs you" tray. When the tool-effect gate (84) withholds a
// dangerous tool call, it lands in the 39-hinge queue as kind='tool-confirm'.
// These endpoints let Michael see the pending drafted calls and approve or
// decline them; approval executes the STORED call verbatim
// (tool_confirm_verdict → tool_confirm_apply). Thin passthroughs to the SQL
// verbs, like the A2A surface. Phase 1 is local (the UI binds localhost); the
// reviewer identity is 'michael' — the only authority that can approve a
// tool-confirm (it is escalate-always, so the claude -p reviewer's approve
// escalates instead of sticking).
package api

import "net/http"

func (d *Deps) registerHinge(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/hinge/tool-confirms", d.hingeToolConfirmsHandler)
	mux.HandleFunc("POST /api/hinge/verdict", d.hingeVerdictHandler)
}

// GET /api/hinge/tool-confirms — the pending/escalated tool-confirm worklist.
func (d *Deps) hingeToolConfirmsHandler(w http.ResponseWriter, r *http.Request) {
	limit := r.URL.Query().Get("limit")
	if limit == "" {
		limit = "50"
	}
	d.a2aQuery(w, r, `SELECT stewards.tool_confirm_pending($1::int)`, limit)
}

// POST /api/hinge/verdict — approve or decline a withheld tool call.
// Body: {"id": <bigint>, "decision": "approve"|"decline", "reason": "..."}.
// On approve this records Michael's verdict AND executes the stored call.
func (d *Deps) hingeVerdictHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	id, ok := m["id"]
	if !ok || id == nil {
		writeErr(w, http.StatusBadRequest, "id is required")
		return
	}
	decision, _ := m["decision"].(string)
	if decision != "approve" && decision != "decline" {
		writeErr(w, http.StatusBadRequest, "decision must be 'approve' or 'decline'")
		return
	}
	d.a2aQuery(w, r,
		`SELECT stewards.tool_confirm_verdict($1::bigint, $2, $3, 'michael')`,
		id, decision, str(m, "reason"))
}
