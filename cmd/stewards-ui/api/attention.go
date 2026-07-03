// Unified "Needs your answer" surface — /api/attention/*.
//
// Every human-blocking item in the substrate used to live behind its own
// surface: the Hinge queue (39), the tool-effect gate's tool-confirm reviews
// (84, the original "Needs you" tray), a paused pipeline stage (04
// awaiting_review), an A2A blocking question (69). 89-attention.sql's
// needs_attention view unions the real pending sets into one shape; these
// endpoints are thin passthroughs, exactly like the A2A and Hinge surfaces —
// attention_answer itself routes to whichever resolver a kind already has
// (tool_confirm_verdict / hinge_record_verdict / a2a_answer /
// work_item_dispatch_stage / ask_record_answer), so this file has no
// kind-specific branching of its own.
package api

import "net/http"

func (d *Deps) registerAttention(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/attention/list", d.attentionListHandler)
	mux.HandleFunc("GET /api/attention/count", d.attentionCountHandler)
	mux.HandleFunc("POST /api/attention/answer", d.attentionAnswerHandler)
}

// GET /api/attention/list — every item needing Michael's answer, oldest first.
func (d *Deps) attentionListHandler(w http.ResponseWriter, r *http.Request) {
	limit := r.URL.Query().Get("limit")
	if limit == "" {
		limit = "100"
	}
	d.a2aQuery(w, r, `SELECT stewards.needs_attention_list($1::int)`, limit)
}

// GET /api/attention/count — the cheap badge count: {"count": N}.
func (d *Deps) attentionCountHandler(w http.ResponseWriter, r *http.Request) {
	d.a2aQuery(w, r, `SELECT stewards.attention_count()`)
}

// POST /api/attention/answer — {"kind": "...", "id": "...", "answer": "..."}.
// kind + id come straight off a needs_attention row (source_kind/source_id);
// answer is either one of that row's options (a quick-reply button) or
// free text (options was null). attention_answer resolves the right verb.
func (d *Deps) attentionAnswerHandler(w http.ResponseWriter, r *http.Request) {
	m, err := decodeBody(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	kind := str(m, "kind")
	id := str(m, "id")
	if kind == nil || id == nil {
		writeErr(w, http.StatusBadRequest, "kind and id are required")
		return
	}
	d.a2aQuery(w, r, `SELECT stewards.attention_answer($1, $2, $3)`, kind, id, str(m, "answer"))
}
