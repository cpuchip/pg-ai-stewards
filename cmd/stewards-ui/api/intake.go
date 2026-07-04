// intake endpoint — POST /api/intake. Thin wrapper over the substrate's
// stewards.route_intake() (99-route-intake.sql, raw-to-wiki): drop a video,
// a website, a file, or a piece of text and have it auto-sorted into the
// right world/wiki/project (or propose a new one, gated for Michael's
// approval). File drops reuse the EXISTING /api/chat/attach upload path —
// the UI uploads first, then passes the returned attachment id as ref.
//
// See .spec/proposals/ingestion-crawler-and-raw-to-wiki.md Part 2.

package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"
)

func (d *Deps) registerIntake(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/intake", d.intakeHandler)
}

type intakeReq struct {
	Kind        string `json:"kind"` // url | file | video | text
	Ref         string `json:"ref"`  // the url, a chat_attachments id (as text), or a doc slug
	Instruction string `json:"instruction,omitempty"`
}

type intakeResp struct {
	WorkItemID string `json:"work_item_id"`
}

var validIntakeKinds = map[string]bool{"url": true, "file": true, "video": true, "text": true}

func (d *Deps) intakeHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	var req intakeReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "decode body: "+err.Error())
		return
	}
	req.Kind = strings.ToLower(strings.TrimSpace(req.Kind))
	req.Ref = strings.TrimSpace(req.Ref)
	if !validIntakeKinds[req.Kind] {
		writeErr(w, http.StatusBadRequest, "kind must be one of url|file|video|text")
		return
	}
	if req.Ref == "" {
		writeErr(w, http.StatusBadRequest, "ref is required (a url, an attachment id, or a doc slug)")
		return
	}

	var instructionArg any = nil
	if strings.TrimSpace(req.Instruction) != "" {
		instructionArg = req.Instruction
	}

	var newID string
	err := d.Pool.QueryRow(ctx,
		`SELECT stewards.route_intake($1, $2, $3)::text`,
		req.Kind, req.Ref, instructionArg,
	).Scan(&newID)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "route_intake: "+err.Error())
		return
	}

	writeJSON(w, http.StatusOK, intakeResp{WorkItemID: newID})
}
