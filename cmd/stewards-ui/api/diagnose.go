// diagnose — the Stewdio "🩺 Diagnose" troubleshooter (ease-of-life E).
//
//	POST /api/chat/diagnose {session_id?, work_item_id?}
//
// When something's wrong (a stalled/errored chat, a build that said "done" but
// produced no file, a runaway), Diagnose: (1) GATHERS facts deterministically —
// rig health (the local llama-chip rig), the session/build trouble, provider
// usability; (2) AUTO-EXECUTES the SAFE fixes (cancel duplicate in-flight builds,
// cycle a genuinely-wedged slot) — ratified scope; (3) has the STRONGEST model
// NARRATE what happened + what it did + recommend the judgment calls (retry a
// build, switch to a paid provider) as RECOMMEND-ONLY.
//
// Safety (presiding covenant): the LLM is NOT in the execution path — it only
// narrates over facts + already-taken actions, so it cannot hallucinate a
// destructive action. The action set is a fixed allowlist. No silent cloud spend
// (a paid-provider switch is recommend-only). Single-shot: it can't recurse/spawn.
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// (llamaChipURL / rigGet / rigPost / rigClient live in rig.go — reused here.)

// diagnoseModel — the model that NARRATES the diagnosis. v1 uses the best LOCAL
// model the UI can reach directly on the rig (free, reliable, doesn't loop);
// cloud-strongest via the substrate is a noted follow-up. Override with env.
func diagnoseModel() string {
	if m := os.Getenv("STEWARDS_DIAGNOSE_MODEL"); m != "" {
		return m
	}
	return "gemma-4-26b-a4b"
}

type diagnoseReq struct {
	SessionID  string `json:"session_id,omitempty"`
	WorkItemID string `json:"work_item_id,omitempty"`
}

type diagnoseResp struct {
	Diagnosis       string   `json:"diagnosis"`
	ActionsTaken    []string `json:"actions_taken"`
	Recommendations []string `json:"recommendations"`
	Facts           []string `json:"facts"` // the raw signals, for the Details view
}

func (d *Deps) registerDiagnose(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/chat/diagnose", d.diagnoseHandler)
}

func (d *Deps) diagnoseHandler(w http.ResponseWriter, r *http.Request) {
	var req diagnoseReq
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "decode: "+err.Error())
		return
	}
	if strings.TrimSpace(req.SessionID) == "" && strings.TrimSpace(req.WorkItemID) == "" {
		writeErr(w, http.StatusBadRequest, "session_id or work_item_id required")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()

	out := diagnoseResp{ActionsTaken: []string{}, Recommendations: []string{}, Facts: []string{}}

	// ── 1. GATHER ───────────────────────────────────────────────────────
	rig := d.gatherRig(ctx)
	out.Facts = append(out.Facts, rig.facts...)
	sess := d.gatherSession(ctx, req.SessionID, req.WorkItemID)
	out.Facts = append(out.Facts, sess.facts...)

	// ── 2. AUTO-EXECUTE the SAFE fixes (deterministic; LLM not involved) ──
	// 2a. duplicate in-flight builds → cancel all but the oldest of each group.
	if req.SessionID != "" && sess.dupGroups > 0 {
		n := d.cancelDuplicateBuilds(ctx, req.SessionID)
		if n > 0 {
			out.ActionsTaken = append(out.ActionsTaken,
				fmt.Sprintf("Cancelled %d duplicate in-flight build(s) (kept the most-advanced of each).", n))
		}
	}
	// 2b. a genuinely-wedged slot (state != healthy) → cycle it. NEVER on mere
	// saturation (high util alone = busy, not wedged).
	for _, s := range rig.stuckSlots {
		if d.cycleSlot(ctx, s) {
			out.ActionsTaken = append(out.ActionsTaken,
				fmt.Sprintf("Cycled the wedged rig slot %q (state was %q).", s.Name, s.State))
		} else {
			out.Recommendations = append(out.Recommendations,
				fmt.Sprintf("Rig slot %q looks wedged (state %q) but I couldn't cycle it — try reloading it from the rig UI.", s.Name, s.State))
		}
	}

	// ── 3. RECOMMEND-ONLY (judgment / spend) ─────────────────────────────
	for _, f := range sess.failedBuilds {
		out.Recommendations = append(out.Recommendations,
			fmt.Sprintf("Build %q failed — use ↻ Retry on its card (or ⤴ Retry stronger).", f))
	}
	for _, f := range sess.deliveredNothing {
		out.Recommendations = append(out.Recommendations,
			fmt.Sprintf("Build %q completed but produced no file (deliver couldn't reach the built doc) — retry it.", f))
	}
	if len(rig.downProviders) > 0 {
		out.Recommendations = append(out.Recommendations,
			"A provider looks down ("+strings.Join(rig.downProviders, ", ")+") — pick a healthy model from the chat's model switch.")
	}
	if rig.saturated {
		out.Recommendations = append(out.Recommendations,
			"The rig is saturated (high GPU utilization) — it's busy, not wedged; let the queue drain or reduce concurrent load.")
	}

	// ── 4. NARRATE on the strongest reachable model (best-effort) ─────────
	out.Diagnosis = d.narrateDiagnosis(ctx, out.Facts, out.ActionsTaken, out.Recommendations)

	writeJSON(w, http.StatusOK, out)
}

// ── gather: rig health ────────────────────────────────────────────────
type rigSlot struct {
	Name     string `json:"name"`
	Model    string `json:"model"`
	State    string `json:"state"`
	GPUs     []int  `json:"gpus"`
	CtxSize  int    `json:"ctx_size"`
	Parallel int    `json:"parallel"`
	KVCache  string `json:"kv_cache"`
}
type rigFindings struct {
	facts         []string
	stuckSlots    []rigSlot
	saturated     bool
	downProviders []string
}

func (d *Deps) gatherRig(ctx context.Context) rigFindings {
	out := rigFindings{}
	// slots (state) from /api/status
	var status struct {
		Slots []rigSlot `json:"slots"`
	}
	if err := rigGetJSON(ctx, llamaChipURL()+"/api/status", &status); err != nil {
		out.facts = append(out.facts, "Rig /api/status unreachable: "+err.Error())
	} else {
		for _, s := range status.Slots {
			if s.State != "healthy" && s.State != "" {
				out.stuckSlots = append(out.stuckSlots, s)
				out.facts = append(out.facts, fmt.Sprintf("Rig slot %q is in state %q (not healthy).", s.Name, s.State))
			}
		}
	}
	// GPU utilization from /api/pool (saturation, NOT a wedge)
	var pool struct {
		Nodes []struct {
			GPUs []struct {
				Index int `json:"index"`
				Util  int `json:"util"`
			} `json:"gpus"`
		} `json:"nodes"`
	}
	if err := rigGetJSON(ctx, llamaChipURL()+"/api/pool", &pool); err == nil && len(pool.Nodes) > 0 {
		for _, g := range pool.Nodes[0].GPUs {
			if g.Util >= 90 {
				out.saturated = true
				out.facts = append(out.facts, fmt.Sprintf("GPU %d at %d%% utilization (busy/saturated).", g.Index, g.Util))
			}
		}
	}
	// providers that are genuinely down = NO usable model at all (a provider with
	// some unusable + some usable models is fine, not "down").
	rows, err := d.Pool.Query(ctx,
		`SELECT provider FROM stewards.model_capability
		  GROUP BY provider HAVING bool_and(coalesce(usable,false) = false)`)
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var p string
			if rows.Scan(&p) == nil {
				out.downProviders = append(out.downProviders, p)
			}
		}
	}
	return out
}

// ── gather: session / work-item trouble ───────────────────────────────
type sessFindings struct {
	facts            []string
	dupGroups        int
	failedBuilds     []string
	deliveredNothing []string
}

func (d *Deps) gatherSession(ctx context.Context, sid, wid string) sessFindings {
	out := sessFindings{}
	if sid != "" {
		// duplicate in-flight builds (same binding_question, >1)
		_ = d.Pool.QueryRow(ctx,
			`SELECT count(*) FROM (
			   SELECT input->>'binding_question' q, count(*) c
			     FROM stewards.work_items
			    WHERE input->>'spawned_from_chat'=$1 AND status IN ('pending','in_progress','running')
			    GROUP BY 1 HAVING count(*) > 1) g`, sid).Scan(&out.dupGroups)
		var inflight int
		_ = d.Pool.QueryRow(ctx,
			`SELECT count(*) FROM stewards.work_items
			  WHERE input->>'spawned_from_chat'=$1 AND status IN ('pending','in_progress','running')`, sid).Scan(&inflight)
		if inflight > 0 {
			out.facts = append(out.facts, fmt.Sprintf("%d in-flight build(s) spawned from this chat%s.",
				inflight, map[bool]string{true: fmt.Sprintf(", in %d duplicate group(s)", out.dupGroups), false: ""}[out.dupGroups > 0]))
		}
		// failed builds + completed-but-no-artifact (the Star Trek case)
		rows, err := d.Pool.Query(ctx,
			`SELECT coalesce(slug, left(id::text,8)), status,
			        (SELECT count(*) FROM stewards.chat_attachments a
			          WHERE a.session_id LIKE 'wi--'||left(wi.id::text,8)||'--%' AND a.kind IN ('document','image'))
			   FROM stewards.work_items wi
			  WHERE input->>'spawned_from_chat'=$1 AND status IN ('failed','completed')
			  ORDER BY created_at DESC LIMIT 20`, sid)
		if err == nil {
			defer rows.Close()
			for rows.Next() {
				var label, st string
				var arts int
				if rows.Scan(&label, &st, &arts) != nil {
					continue
				}
				if st == "failed" {
					out.failedBuilds = append(out.failedBuilds, label)
					out.facts = append(out.facts, fmt.Sprintf("Build %q FAILED.", label))
				} else if st == "completed" && arts == 0 {
					out.deliveredNothing = append(out.deliveredNothing, label)
					out.facts = append(out.facts, fmt.Sprintf("Build %q is 'completed' but produced 0 files.", label))
				}
			}
		}
	}
	if wid != "" {
		var st, stage, errMsg string
		var arts int
		if err := d.Pool.QueryRow(ctx,
			`SELECT status, coalesce(current_stage,''), coalesce(error,last_failure_reason,''),
			        (SELECT count(*) FROM stewards.chat_attachments a
			          WHERE a.session_id LIKE 'wi--'||left($1::uuid::text,8)||'--%' AND a.kind IN ('document','image'))
			   FROM stewards.work_items WHERE id=$1::uuid`, wid).Scan(&st, &stage, &errMsg, &arts); err == nil {
			out.facts = append(out.facts, fmt.Sprintf("Work item is status=%s stage=%s, %d file(s) produced.", st, stage, arts))
			if errMsg != "" {
				out.facts = append(out.facts, "Last error: "+errMsg)
			}
			if st == "failed" {
				out.failedBuilds = append(out.failedBuilds, wid[:8])
			} else if st == "completed" && arts == 0 {
				out.deliveredNothing = append(out.deliveredNothing, wid[:8])
			}
		}
	}
	return out
}

// ── auto-fix: cancel duplicate in-flight builds (keep the oldest per group) ──
func (d *Deps) cancelDuplicateBuilds(ctx context.Context, sid string) int {
	// cancel all-but-oldest of each duplicate group, + their stage dispatch rows.
	tag, err := d.Pool.Exec(ctx, `
		WITH dups AS (
		  SELECT id, row_number() OVER (PARTITION BY input->>'binding_question' ORDER BY created_at) rn
		    FROM stewards.work_items
		   WHERE input->>'spawned_from_chat'=$1 AND status IN ('pending','in_progress','running'))
		UPDATE stewards.work_items SET status='cancelled',
		       error=coalesce(nullif(error,''),'diagnose: duplicate in-flight build')
		 WHERE id IN (SELECT id FROM dups WHERE rn > 1)`, sid)
	if err != nil {
		log.Printf("diagnose: cancel dup builds (%s): %v", sid, err)
		return 0
	}
	// kill the cancelled builds' in-flight stage dispatches (keyed on wi--<id>--stage).
	_, _ = d.Pool.Exec(ctx, `
		UPDATE stewards.work_queue q SET status='error', error='diagnose: duplicate build cancelled', done_at=now()
		 WHERE q.status IN ('pending','in_progress','waiting_for_tools')
		   AND q.payload->>'session_id' LIKE 'wi--%'
		   AND EXISTS (SELECT 1 FROM stewards.work_items wi
		               WHERE left(wi.id::text,8)=split_part(q.payload->>'session_id','--',2)
		                 AND wi.input->>'spawned_from_chat'=$1 AND wi.status='cancelled')`, sid)
	return int(tag.RowsAffected())
}

// ── auto-fix: cycle a wedged rig slot (unload + reload with the same params) ──
func (d *Deps) cycleSlot(ctx context.Context, s rigSlot) bool {
	if err := rigPost(ctx, "/api/unload", map[string]any{"name": s.Name}); err != nil {
		return false
	}
	time.Sleep(2 * time.Second)
	body := map[string]any{"model": s.Model, "alias": s.Name, "gpus": s.GPUs, "ctx_size": s.CtxSize}
	if s.Parallel > 0 {
		body["parallel"] = s.Parallel
	}
	if s.KVCache != "" {
		body["kv_cache"] = s.KVCache
	}
	return rigPost(ctx, "/api/load", body) == nil
}

// ── narrate: one call on the strongest reachable model (best-effort) ──
func (d *Deps) narrateDiagnosis(ctx context.Context, facts, actions, recs []string) string {
	bullet := func(label string, xs []string) string {
		if len(xs) == 0 {
			return label + ": none\n"
		}
		return label + ":\n- " + strings.Join(xs, "\n- ") + "\n"
	}
	brief := "You are the diagnostician for an AI work substrate. Below are FACTS gathered about a\n" +
		"problem, the SAFE ACTIONS already taken automatically, and RECOMMENDATIONS. Write a short,\n" +
		"plain diagnosis (2-4 sentences) for the operator: what went wrong, what was already fixed, and\n" +
		"what they should do next. Do not invent facts beyond what's given. Be direct.\n\n" +
		bullet("FACTS", facts) + bullet("ACTIONS ALREADY TAKEN", actions) + bullet("RECOMMENDATIONS", recs)
	body := map[string]any{
		"model":       diagnoseModel(),
		"messages":    []map[string]string{{"role": "user", "content": brief}},
		"temperature": 0.2,
		"max_tokens":  2500,
		"stream":      false,
	}
	b, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, llamaChipURL()+"/v1/chat/completions", bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "" // UI falls back to the structured actions/recommendations
	}
	defer resp.Body.Close()
	var out struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if json.NewDecoder(resp.Body).Decode(&out) != nil || len(out.Choices) == 0 {
		return ""
	}
	return strings.TrimSpace(out.Choices[0].Message.Content)
}

// ── rig HTTP helpers ──
func rigGetJSON(ctx context.Context, url string, v any) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	resp, err := rigClient.Do(req) // 8s timeout — gather fails fast if the rig is down
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("status %d", resp.StatusCode)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}
