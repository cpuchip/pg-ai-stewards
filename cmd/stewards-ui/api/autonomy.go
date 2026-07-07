// autonomy endpoint — a lightweight, DB-only read of the substrate's global
// kill switch (stewards.config.autonomy_paused). rig.go already reads this
// value (autonomyPaused helper) to back the local-rig pause/resume controls,
// but that state was only visible buried inside the Dashboard's "Local rig"
// card, gated behind a round-trip to llama-chip. Ratified 2026-07-07 (war-game
// PAUSED-visibility ask): any page — Dashboard, /scheduled, Stewdio — should be
// able to show a prominent "autonomy is paused" banner from one cheap call
// that never depends on llama-chip being reachable.

package api

import (
	"context"
	"net/http"
	"time"
)

func (d *Deps) registerAutonomy(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/autonomy", d.autonomyHandler)
}

func (d *Deps) autonomyHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	writeJSON(w, http.StatusOK, map[string]any{"paused": d.autonomyPaused(ctx)})
}
