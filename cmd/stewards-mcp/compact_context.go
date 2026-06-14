// compact_context — M5 commissioned context curation.
//
// The proactive complement to pressure-shedding (which is the automatic
// floor). When an agent's own context grows past usefulness, it calls
// compact_context: a fresh TOOLS-OFF compactor judges the caller's foldable
// surface and returns a {mute,compress,pin} verdict; the substrate applies
// it to the caller's session and writes a reversible [COMPACTED] marker.
// Judges-not-executors: the compactor counsels, the substrate acts.
//
// Mid-turn by construction (like spawn_subagent): this handler blocks while
// the compactor runs, so when the tool call returns the mutes are already
// applied and the caller's next turn recomposes lighter.
//
// Council-ratified 2026-06-14 (M5). The compactor model is the tunable knob
// (the compact-context pipeline's curate stage); see 21-compact-context.sql.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type CompactContextInput struct {
	// _session_id is injected by the substrate (the caller's session), the
	// same hook the context tools use. The agent never passes it.
	SessionID string `json:"_session_id,omitempty" jsonschema:"injected by the substrate; the caller's session"`
	Focus     string `json:"focus,omitempty" jsonschema:"optional steer for the compactor, e.g. 'keep everything about the migration plan'"`
}

type CompactContextOutput struct {
	Muted            int    `json:"muted"`
	Compressed       int    `json:"compressed"`
	Pinned           int    `json:"pinned"`
	WindowTokens     int64  `json:"window_tokens"`
	CuratedTokens    int64  `json:"curated_tokens"`
	CompactorWorkItem string `json:"compactor_work_item"`
}

const (
	// Stay under the bridge's per-call timeout (default 120s) so a slow
	// compactor fails gracefully here rather than as an opaque bridge kill.
	// A deepseek-v4-flash judge over a condensed surface is normally ~10-30s.
	compactMaxWaitSeconds  = 110
	compactPollIntervalSec = 3
	compactCostCapMicro    = 150_000 // $0.15 ceiling
)

func registerCompactContextTool(srv *mcp.Server, pool *pgxpool.Pool) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "compact_context",
		Description: "Commission a fresh compactor to curate YOUR current context so you can continue lighter. " +
			"A separate cheap judge reviews your foldable messages and marks the spent ones for muting/compression " +
			"(keeping the precious, pinning what you'll cite) — fully reversible with context_expand. " +
			"Use when your context-pressure line suggests it (past ~50% of window) or your working memory is " +
			"clogged with spent tool output. You get back a summary of what was curated; your next turn recomposes lighter. " +
			"Nothing is deleted.",
	}, makeCompactContext(pool))
}

func makeCompactContext(pool *pgxpool.Pool) func(
	ctx context.Context, req *mcp.CallToolRequest, in CompactContextInput,
) (*mcp.CallToolResult, CompactContextOutput, error) {
	return func(
		ctx context.Context, req *mcp.CallToolRequest, in CompactContextInput,
	) (*mcp.CallToolResult, CompactContextOutput, error) {
		if in.SessionID == "" {
			return toolError("compact_context: no session context (internal: _session_id missing)"),
				CompactContextOutput{}, nil
		}

		// 1. Render the foldable surface for the caller's session.
		var surface string
		if err := pool.QueryRow(ctx,
			`SELECT stewards.compact_context_surface($1)`, in.SessionID,
		).Scan(&surface); err != nil {
			return toolError("compact_context surface: %v", err), CompactContextOutput{}, nil
		}
		if strings.HasPrefix(strings.TrimSpace(surface), "(no foldable") {
			return &mcp.CallToolResult{
				Content: []mcp.Content{&mcp.TextContent{
					Text: "compact_context: nothing foldable to curate in this window yet."}},
			}, CompactContextOutput{}, nil
		}

		// 2. Build the compactor's binding: the surface (+ optional focus).
		binding := surface
		if in.Focus != "" {
			binding = "STEER: " + in.Focus + "\n\n" + surface
		}
		binding += "\n\nReturn ONLY the JSON verdict: " +
			`{"mute":[<ids>],"compress":[<ids>],"pin":[<ids>],"reasoning":"<one line>"}`

		// 3. Spawn the compact-context subagent and block until it is done.
		// Pass the caller's work_item (if it is inside one) so the compactor
		// inherits its intent — the compactor is a child of that work, not a
		// new intent-bearing task. A real agent always runs inside a work_item;
		// for an infra session with none, spawn falls back to the configured
		// default_intent_slug.
		var parentWI *string
		_ = pool.QueryRow(ctx,
			`SELECT id::text FROM stewards.work_items WHERE $1 = ANY(session_ids) ORDER BY created_at DESC LIMIT 1`,
			in.SessionID,
		).Scan(&parentWI)

		var childID string
		if err := pool.QueryRow(ctx,
			`SELECT stewards.spawn_subagent_create('compact-context', $1, $2::uuid, $3, NULL, NULL, 'subagent')::text`,
			binding, parentWI, compactCostCapMicro,
		).Scan(&childID); err != nil {
			return toolError("compact_context spawn: %v", err), CompactContextOutput{}, nil
		}

		deadline := time.Now().Add(time.Duration(compactMaxWaitSeconds) * time.Second)
		var status, maturity string
		for {
			if err := pool.QueryRow(ctx,
				`SELECT status, maturity FROM stewards.work_items WHERE id = $1::uuid`, childID,
			).Scan(&status, &maturity); err != nil {
				return toolError("compact_context poll: %v (child=%s)", err, childID),
					CompactContextOutput{}, nil
			}
			// The compact-context pipeline is a single tools-off stage: it
			// reaches status=completed without advancing maturity to verified,
			// so 'completed' is terminal here too.
			if status == "completed" || maturity == "verified" ||
				status == "failed" || status == "cancelled" {
				break
			}
			if time.Now().After(deadline) {
				return toolError("compact_context: compactor %s timed out after %ds (status=%s).",
					childID, compactMaxWaitSeconds, status), CompactContextOutput{}, nil
			}
			select {
			case <-ctx.Done():
				return toolError("compact_context: cancelled while waiting on compactor %s", childID),
					CompactContextOutput{}, nil
			case <-time.After(time.Duration(compactPollIntervalSec) * time.Second):
			}
		}

		// 4. Read the compactor's verdict (its last assistant message).
		var verdictRaw string
		_ = pool.QueryRow(ctx, `
			SELECT coalesce(m.content, '')
			  FROM stewards.work_items wi
			  JOIN stewards.messages m ON m.session_id = ANY(wi.session_ids)
			 WHERE wi.id = $1::uuid AND m.role = 'assistant' AND coalesce(m.content,'') <> ''
			 ORDER BY m.created_at DESC, m.id DESC LIMIT 1`, childID,
		).Scan(&verdictRaw)

		verdict := extractJSONObject(verdictRaw)
		if verdict == "" || !json.Valid([]byte(verdict)) {
			return toolError("compact_context: compactor (%s) returned no parseable verdict (status=%s). "+
				"Nothing applied. Raw: %.200s", childID, status, verdictRaw), CompactContextOutput{}, nil
		}

		// 5. Apply the verdict to the caller's session (the substrate acts).
		var summaryRaw []byte
		if err := pool.QueryRow(ctx,
			`SELECT stewards.compact_context_apply($1, $2::jsonb)`, in.SessionID, verdict,
		).Scan(&summaryRaw); err != nil {
			return toolError("compact_context apply: %v", err), CompactContextOutput{}, nil
		}

		var out CompactContextOutput
		_ = json.Unmarshal(summaryRaw, &out)
		out.CompactorWorkItem = childID

		body := fmt.Sprintf(
			"[compact_context] curated your %d-token window: muted %d, compressed %d, pinned %d "+
				"(~%d foldable tokens marked for relief). They render as tombstones once this window is "+
				"under pressure; your next turn recomposes lighter. Reversible — context_expand any handle.",
			out.WindowTokens, out.Muted, out.Compressed, out.Pinned, out.CuratedTokens)

		return &mcp.CallToolResult{
			Content: []mcp.Content{&mcp.TextContent{Text: body}},
		}, out, nil
	}
}

// extractJSONObject returns the first balanced {...} block in s, so a model
// that wraps its verdict in prose or a code fence still parses. Returns ""
// if no balanced object is found.
func extractJSONObject(s string) string {
	start := strings.IndexByte(s, '{')
	if start < 0 {
		return ""
	}
	depth := 0
	inStr := false
	esc := false
	for i := start; i < len(s); i++ {
		c := s[i]
		if inStr {
			switch {
			case esc:
				esc = false
			case c == '\\':
				esc = true
			case c == '"':
				inStr = false
			}
			continue
		}
		switch c {
		case '"':
			inStr = true
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return s[start : i+1]
			}
		}
	}
	return ""
}
