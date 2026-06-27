// A2A / Open Engine MCP tools — the substrate turned outward.
//
// These expose the 69-a2a-engine.sql verbs over MCP so any agent that
// speaks MCP (my Claude Code session, agy, the personas) can hand work
// to / claim work from the engine. The human stops being the hallway:
// my session writes a task, agy claims+works+receipts it, I see it done
// — zero copy-paste, the work_item is the whole conversation.
//
// Each tool is a thin passthrough to a SQL function returning jsonb
// (single source of truth for the lifecycle, also proven by
// tests/virgin-smoke.sql). The mirror-write to .mind/sessions/ (gated by
// A2A_MIRROR_DIR) is the file fallback ratified in the spec: best-effort,
// never load-bearing for correctness — only availability when the
// substrate is down.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// A2AResult is the shared output shape: the verb's jsonb, passed through.
type A2AResult struct {
	Result json.RawMessage `json:"result"`
}

// callA2A runs a SQL function returning jsonb and returns it both as the
// structured result and as readable text content.
func callA2A(ctx context.Context, pool *pgxpool.Pool, sql string, args ...any) (*mcp.CallToolResult, A2AResult, error) {
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	var raw json.RawMessage
	if err := pool.QueryRow(cctx, sql, args...).Scan(&raw); err != nil {
		return toolError("a2a: %v", err), A2AResult{}, nil
	}
	return &mcp.CallToolResult{
		Content: []mcp.Content{&mcp.TextContent{Text: string(raw)}},
	}, A2AResult{Result: raw}, nil
}

// nz maps an empty string to a SQL NULL (so optional args stay absent
// rather than becoming the empty string, which several verbs validate).
func nz(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// nzJSON maps an empty/null RawMessage to a SQL NULL (the verb coalesces
// to '{}'); otherwise passes the bytes for a ::jsonb cast.
func nzJSON(r json.RawMessage) any {
	t := strings.TrimSpace(string(r))
	if t == "" || t == "null" {
		return nil
	}
	return []byte(r)
}

func registerA2ATools(srv *mcp.Server, pool *pgxpool.Pool) {
	// ── a2a_register ──────────────────────────────────────────────────
	mcp.AddTool(srv, &mcp.Tool{
		Name: "a2a_register",
		Description: "Register or refresh yourself (or another agent) in the A2A engine so you can hand and receive work. " +
			"agent_id is your durable identity — use your session lane (e.g. \"lane:pg-ai-stewards\"). Idempotent; bumps last_seen.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in A2ARegisterInput) (*mcp.CallToolResult, A2AResult, error) {
		return callA2A(ctx, pool,
			`SELECT stewards.a2a_register($1,$2,$3,$4,$5::jsonb,$6,$7,$8::jsonb)`,
			in.AgentID, nz(in.DisplayName), nz(in.Kind), nz(in.Lane),
			nzJSON(in.Capabilities), nz(in.Delivery), nz(in.Endpoint), nzJSON(in.Scope))
	})

	// ── a2a_submit ────────────────────────────────────────────────────
	mcp.AddTool(srv, &mcp.Tool{
		Name: "a2a_submit",
		Description: "Hand a task to another agent through the engine. Creates an assigned work_item that waits for the " +
			"assignee to claim, work, and receipt it — no copy-paste, the work_item is the whole conversation. Provide a " +
			"self-contained ticket: a clear title, and a `spec` object with outcome, sources, context, allowed_actions, " +
			"stop_condition, definition_of_done. Set `owner` to your agent_id so the worker can ask you questions and send the receipt.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in A2ASubmitInput) (*mcp.CallToolResult, A2AResult, error) {
		res, out, _ := callA2A(ctx, pool,
			`SELECT stewards.a2a_submit($1,$2,$3::jsonb,$4,$5,$6,$7)`,
			in.Assignee, in.Title, nzJSON(in.Spec), nz(in.Owner), nz(in.Project), nz(in.Slug), nz(in.Intent))
		mirrorTodo(in.Assignee, in.Title, in.Owner, out.Result)
		return res, out, nil
	})

	// ── a2a_inbox ─────────────────────────────────────────────────────
	mcp.AddTool(srv, &mcp.Tool{
		Name: "a2a_inbox",
		Description: "Read your engine inbox: NOTES (async messages to you) and TODOS (open work assigned to you, with any " +
			"blocking question). Pull-delivery — call this on engagement. Clear notes (a2a_note_clear) after acting so the 📬 goes away.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in A2AAgentInput) (*mcp.CallToolResult, A2AResult, error) {
		return callA2A(ctx, pool, `SELECT stewards.a2a_inbox($1)`, in.AgentID)
	})

	// ── a2a_claim ─────────────────────────────────────────────────────
	mcp.AddTool(srv, &mcp.Tool{
		Name: "a2a_claim",
		Description: "Atomically claim a queued task assigned to you (queued → in_progress) so you own it. Returns the full " +
			"ticket/spec you need. Only one agent can claim a task; if someone already has it you get claimed=false — move on.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in A2AClaimInput) (*mcp.CallToolResult, A2AResult, error) {
		return callA2A(ctx, pool, `SELECT stewards.a2a_claim($1::uuid,$2)`, in.WorkItemID, in.Claimer)
	})

	// ── a2a_needs_input ───────────────────────────────────────────────
	mcp.AddTool(srv, &mcp.Tool{
		Name: "a2a_needs_input",
		Description: "Block a task you're working on with the EXACT question you need answered. The owner gets the question in " +
			"their inbox and answers it (a2a_answer); the answer lands in yours and you resume. One precise blocking question, not a vague status.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in A2ANeedsInputInput) (*mcp.CallToolResult, A2AResult, error) {
		return callA2A(ctx, pool, `SELECT stewards.a2a_needs_input($1::uuid,$2)`, in.WorkItemID, in.Question)
	})

	// ── a2a_answer ────────────────────────────────────────────────────
	mcp.AddTool(srv, &mcp.Tool{
		Name: "a2a_answer",
		Description: "Answer a task one of your assigned agents blocked with a question (it appeared in your inbox as a " +
			"question-note). Clears the block and notifies the worker so it can resume.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in A2AAnswerInput) (*mcp.CallToolResult, A2AResult, error) {
		return callA2A(ctx, pool, `SELECT stewards.a2a_answer($1::uuid,$2)`, in.WorkItemID, in.Answer)
	})

	// ── a2a_receipt ───────────────────────────────────────────────────
	mcp.AddTool(srv, &mcp.Tool{
		Name: "a2a_receipt",
		Description: "Finish a task you claimed: post a short summary of what you did plus the artifact (doc slug, URL, files, " +
			"output) as proof, and mark it done. The owner gets the receipt in their inbox. This is the accounting that frees the " +
			"human from carrying state between agents.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in A2AReceiptInput) (*mcp.CallToolResult, A2AResult, error) {
		res, out, _ := callA2A(ctx, pool,
			`SELECT stewards.a2a_receipt($1::uuid,$2,$3::jsonb)`,
			in.WorkItemID, in.Summary, nzJSON(in.Artifact))
		mirrorReceipt(out.Result, in.Summary)
		return res, out, nil
	})

	// ── a2a_note ──────────────────────────────────────────────────────
	mcp.AddTool(srv, &mcp.Tool{
		Name: "a2a_note",
		Description: "Leave an async note in another agent's inbox (\"here's something for you when you get to it\"). The " +
			"substrate version of the .mind/sessions inbox. Pull-delivery: they see it on next engagement. Use a2a_submit instead " +
			"when you want a tracked task with a receipt.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in A2ANoteInput) (*mcp.CallToolResult, A2AResult, error) {
		res, out, _ := callA2A(ctx, pool,
			`SELECT stewards.a2a_note($1,$2,$3,$4)`,
			in.Recipient, in.Body, nz(in.Sender), nz(in.WorkItemID))
		mirrorNote(in.Recipient, in.Sender, in.Body)
		return res, out, nil
	})

	// ── a2a_note_clear ────────────────────────────────────────────────
	mcp.AddTool(srv, &mcp.Tool{
		Name: "a2a_note_clear",
		Description: "Mark your notes acted (clears the 📬). Omit note_id to clear all unacted notes after you've acted on your inbox.",
	}, func(ctx context.Context, req *mcp.CallToolRequest, in A2ANoteClearInput) (*mcp.CallToolResult, A2AResult, error) {
		if in.NoteID > 0 {
			return callA2A(ctx, pool, `SELECT stewards.a2a_note_clear($1,$2)`, in.Recipient, in.NoteID)
		}
		return callA2A(ctx, pool, `SELECT stewards.a2a_note_clear($1,NULL)`, in.Recipient)
	})
}

// =====================================================================
// Tool inputs
// =====================================================================

type A2ARegisterInput struct {
	AgentID      string          `json:"agent_id" jsonschema:"your durable identity; a session lane like 'lane:pg-ai-stewards'"`
	DisplayName  string          `json:"display_name,omitempty" jsonschema:"human-readable name"`
	Kind         string          `json:"kind,omitempty" jsonschema:"session | daemon | persona | external (default session)"`
	Lane         string          `json:"lane,omitempty" jsonschema:"the .mind/sessions lane this session inhabits"`
	Capabilities json.RawMessage `json:"capabilities,omitempty" jsonschema:"JSON array of skills you offer"`
	Delivery     string          `json:"delivery,omitempty" jsonschema:"pull | heartbeat | webhook (default pull)"`
	Endpoint     string          `json:"endpoint,omitempty" jsonschema:"webhook/external callback URL"`
	Scope        json.RawMessage `json:"scope,omitempty" jsonschema:"JSON object: the projects/intents/tools you may touch"`
}

type A2ASubmitInput struct {
	Assignee string          `json:"assignee" jsonschema:"registered agent_id to assign the task to"`
	Title    string          `json:"title" jsonschema:"one-line outcome the ticket asks for"`
	Spec     json.RawMessage `json:"spec,omitempty" jsonschema:"the 7-part ticket: {outcome, sources, context, allowed_actions, stop_condition, definition_of_done}"`
	Owner    string          `json:"owner,omitempty" jsonschema:"your agent_id (so the worker can ask you questions and send the receipt)"`
	Project  string          `json:"project,omitempty" jsonschema:"optional project slug to associate"`
	Slug     string          `json:"slug,omitempty" jsonschema:"optional human-readable slug"`
	Intent   string          `json:"intent,omitempty" jsonschema:"optional intent slug; defaults to the configured default intent"`
}

type A2AAgentInput struct {
	AgentID string `json:"agent_id" jsonschema:"your registered agent_id (a lane for Claude sessions)"`
}

type A2AClaimInput struct {
	WorkItemID string `json:"work_item_id" jsonschema:"the task's work_item_id (from a2a_inbox todos)"`
	Claimer    string `json:"claimer" jsonschema:"your agent_id"`
}

type A2ANeedsInputInput struct {
	WorkItemID string `json:"work_item_id"`
	Question   string `json:"question" jsonschema:"the exact, specific question blocking progress"`
}

type A2AAnswerInput struct {
	WorkItemID string `json:"work_item_id"`
	Answer     string `json:"answer"`
}

type A2AReceiptInput struct {
	WorkItemID string          `json:"work_item_id"`
	Summary    string          `json:"summary" jsonschema:"what you did, in a sentence or two"`
	Artifact   json.RawMessage `json:"artifact,omitempty" jsonschema:"the proof: {doc_slug, url, files, output, ...}"`
}

type A2ANoteInput struct {
	Recipient  string `json:"recipient" jsonschema:"the agent_id to leave the note for"`
	Body       string `json:"body"`
	Sender     string `json:"sender,omitempty" jsonschema:"your agent_id"`
	WorkItemID string `json:"work_item_id,omitempty" jsonschema:"optional task this note relates to"`
}

type A2ANoteClearInput struct {
	Recipient string `json:"recipient" jsonschema:"your agent_id"`
	NoteID    int64  `json:"note_id,omitempty" jsonschema:"a specific note to clear; omit to clear all unacted"`
}

// =====================================================================
// File-fallback mirror (ratified §4.6). Best-effort, never fatal: the
// substrate is the source of truth; these files keep the .mind/sessions
// path warm so a substrate-down agent still reads the last-known state.
// Enabled only when A2A_MIRROR_DIR points at a .mind/sessions directory.
// =====================================================================

func a2aMirrorDir() string { return os.Getenv("A2A_MIRROR_DIR") }

// laneFile turns an agent_id into a safe filename stem (':' is illegal on
// Windows/NTFS; lanes use it).
func laneFile(agentID string) string {
	return strings.NewReplacer(":", "-", "/", "-", "\\", "-").Replace(agentID)
}

func appendMirror(subdir, recipient, line string) {
	dir := a2aMirrorDir()
	if dir == "" {
		return
	}
	target := filepath.Join(dir, subdir)
	if err := os.MkdirAll(target, 0o755); err != nil {
		log.Printf("a2a mirror: mkdir %s: %v (non-fatal)", target, err)
		return
	}
	path := filepath.Join(target, laneFile(recipient)+".md")
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("a2a mirror: open %s: %v (non-fatal)", path, err)
		return
	}
	defer f.Close()
	stamp := time.Now().UTC().Format("2006-01-02 15:04")
	if _, err := fmt.Fprintf(f, "- [%s] %s\n", stamp, line); err != nil {
		log.Printf("a2a mirror: write %s: %v (non-fatal)", path, err)
	}
}

func mirrorTodo(assignee, title, owner string, _ json.RawMessage) {
	from := owner
	if from == "" {
		from = "(unknown)"
	}
	appendMirror("todos", assignee, fmt.Sprintf("TODO from %s: %s", from, title))
}

func mirrorNote(recipient, sender, body string) {
	from := sender
	if from == "" {
		from = "(unknown)"
	}
	appendMirror("inbox", recipient, fmt.Sprintf("note from %s: %s", from, oneLine(body)))
}

// mirrorReceipt writes the receipt to the owner's inbox file, if we can
// learn the owner from the verb's result.
func mirrorReceipt(result json.RawMessage, summary string) {
	if a2aMirrorDir() == "" {
		return
	}
	var r struct {
		ReceiptTo  string `json:"receipt_to"`
		ResolvedBy string `json:"resolved_by"`
	}
	if err := json.Unmarshal(result, &r); err != nil || r.ReceiptTo == "" {
		return
	}
	appendMirror("inbox", r.ReceiptTo, fmt.Sprintf("RECEIPT from %s: %s", r.ResolvedBy, oneLine(summary)))
}

func oneLine(s string) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}
