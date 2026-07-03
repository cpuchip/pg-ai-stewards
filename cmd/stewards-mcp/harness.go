// harness_run — the Phase-1 harness executor (loom integration, ratified
// 2026-07-03). Dispatches a stage's task to a FULL Claude Code harness as a
// subprocess (`loom run`), the tier above the substrate's native loop for
// hard, multi-file, corpus-grounded work. The native loop stays fully capable;
// this is a tier, not a replacement.
//
// The two walls, handed per dispatch (the presiding covenant made operational):
//   - filesystem: --isolate — claude runs in a docker sandbox (loom-claude,
//     non-root `node`) and sees ONLY the bind-mounted workdir (/work) + the
//     read-only credentials + the mounted claude-home. --isolate is what makes
//     --skip-permissions (headless) safe.
//   - capability: --allowed-tools scoped to the RATIFIED READ-ONLY set, and —
//     when the operator wires the hinge (STEWARDS_HARNESS_MCP_URL) — an
//     --mcp-config pointing at the substrate's Arc C HTTP surface, which
//     structurally carries ONLY the read profile (doc_* / inspection /
//     model-catalog). a2a_submit / spawn_subagent / doc writes / coder_* are
//     not on that surface at all: the wall is the server, not the model's
//     politeness.
//
// Phase 1 is PULL-only and read-mostly per .spec/proposals/loom-integration.md:
// no write-back into the substrate, no default routing — both are
// dominion_in_council gates. The Reply's session_id is the durable resume
// handle; every dispatch is ledgered on stewards.harness_runs (90) the way
// coder_export_artifact ledgers its artifacts on chat_attachments.
//
// Deployment note (Phase 1): harness_run execs the `loom` binary, which execs
// `docker run` with HOST paths — so this tool works where stewards-mcp runs
// with loom + docker + a claude subscription available (the host). The
// containerized bridge image does not carry loom yet; a dispatch routed there
// errors clearly instead of half-working. Shipping loom in the bridge image is
// a deploy follow-up, not a Phase-1 requirement.
//
// Operator env (all optional):
//   STEWARDS_LOOM_BIN              — loom binary (default: `loom` on PATH)
//   STEWARDS_HARNESS_CLAUDE_HOME   — host dir mounted as the container's
//                                    ~/.claude (default: <user home>/.stewards/
//                                    harness-claude-home, created on demand);
//                                    holds the persisted session state (what
//                                    makes resume+isolate work). Deliberately
//                                    NOT the user's real ~/.claude: real-path
//                                    testing (2026-07-03) showed a mounted real
//                                    home carries MCP approval/OAuth state that
//                                    makes headless claude refuse --mcp-config
//                                    HTTP servers with "requires authentication";
//                                    a dedicated home connects cleanly. Auth is
//                                    unaffected — loom layers the user's
//                                    .credentials.json read-only regardless.
//   STEWARDS_HARNESS_MCP_URL       — the substrate MCP HTTP endpoint AS SEEN
//                                    FROM THE CONTAINER (e.g.
//                                    http://host.docker.internal:8092/mcp).
//                                    Empty = no hinge: pure workdir-in/text-out.
//   STEWARDS_HARNESS_MCP_TOKEN     — bearer token for that endpoint. Written
//                                    ONLY into the generated mcp-config file
//                                    inside claude-home; never logged.
//   STEWARDS_HARNESS_ALLOWED_TOOLS — full override of the --allowed-tools list.

package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The ratified read-only substrate toolset (council 2026-06-30). EXPLICITLY
// NOT here: a2a_submit, spawn_subagent, start_task, doc writes/imports,
// coder_*. The Arc C HTTP profile doesn't carry those either — the allowlist
// and the server surface agree.
var harnessSubstrateReadTools = []string{
	"mcp__pg-ai-stewards__doc_search",
	"mcp__pg-ai-stewards__doc_get",
	"mcp__pg-ai-stewards__doc_similar",
	"mcp__pg-ai-stewards__doc_citations",
	"mcp__pg-ai-stewards__work_item_show",
	"mcp__pg-ai-stewards__work_item_list",
	"mcp__pg-ai-stewards__list_models",
}

// Claude Code's own read tools — the workdir is the corpus; reading it is the
// whole point. No Bash (it writes), no Write/Edit (read-mostly Phase 1).
var harnessClaudeReadTools = []string{"Read", "Glob", "Grep"}

// containerClaudeDir is where the loom-claude image homes claude (non-root
// `node` user, per the 2026-07-01 fix). --mcp-config paths are container
// paths, so the generated config must live inside the mounted claude-home.
const containerClaudeDir = "/home/node/.claude"

// harnessMCPConfigName is the file harness_run generates inside claude-home
// when the hinge is wired. Deterministic name + content: an idempotent write.
const harnessMCPConfigName = "stewards-harness-mcp.json"

const (
	harnessDefaultTimeoutSeconds = 600
	harnessMaxTimeoutSeconds     = 3600
	harnessMinTimeoutSeconds     = 30
	harnessStderrTailBytes       = 4000
)

type HarnessRunInput struct {
	Prompt         string `json:"prompt" jsonschema:"the task for the harness — the full prompt Claude Code receives (the workdir is its corpus; the prompt is the task)"`
	Workdir        string `json:"workdir,omitempty" jsonschema:"optional HOST directory bind-mounted as the harness's working dir (/work) — the code/context it reads with its own tools. Default: an empty scratch dir."`
	Backend        string `json:"backend,omitempty" jsonschema:"loom backend (default claude)"`
	TimeoutSeconds int    `json:"timeout_seconds,omitempty" jsonschema:"wall-clock cap for the whole dispatch (default 600, max 3600)"`
	// session_id is injected by the dispatcher (52's inject_session, extended
	// to harness_run in 90) — the substrate session the run is ledgered under.
	// The dispatcher is the oracle, not the model.
	SessionID string `json:"session_id,omitempty" jsonschema:"injected by the substrate dispatcher; the caller's session (do not pass)"`
}

type HarnessRunOutput struct {
	Text             string  `json:"text"`
	HarnessSessionID string  `json:"harness_session_id"`
	CostUSD          float64 `json:"cost_usd"`
	Turns            int     `json:"turns"`
	Backend          string  `json:"backend"`
	LedgerID         int64   `json:"ledger_id,omitempty"`
	WorkItemID       string  `json:"work_item_id,omitempty"`
}

// loomReply mirrors loom's one-line --json Reply on stdout:
// {"backend":"claude","text":"…","session_id":"…","cost_usd":0.06,"turns":1}
// (`error` present only on failure.)
type loomReply struct {
	Backend   string  `json:"backend"`
	Text      string  `json:"text"`
	SessionID string  `json:"session_id"`
	CostUSD   float64 `json:"cost_usd"`
	Turns     int     `json:"turns"`
	Error     string  `json:"error,omitempty"`
}

func registerHarnessTools(srv *mcp.Server, pool *pgxpool.Pool) {
	mcp.AddTool(srv, &mcp.Tool{
		Name: "harness_run",
		Description: "Dispatch a task to a FULL Claude Code harness (via loom) running isolated in a docker sandbox — " +
			"the tier above the native loop for hard, multi-file work grounded in a real directory. " +
			"The harness reads the mounted workdir with its own tools (Read/Glob/Grep) and, where the operator wired the hinge, " +
			"consults the substrate's READ-ONLY doc/work-item surface. Phase 1 is read-mostly: it cannot write to the substrate, " +
			"submit a2a work, or spawn anything. Returns the harness's answer + its session_id (the durable resume handle, " +
			"ledgered on stewards.harness_runs) + cost. EXPENSIVE — one call is a whole agent run; " +
			"use the native loop for cheap/bulk work.",
	}, makeHarnessRun(pool))
}

func makeHarnessRun(pool *pgxpool.Pool) func(
	ctx context.Context, req *mcp.CallToolRequest, in HarnessRunInput,
) (*mcp.CallToolResult, HarnessRunOutput, error) {
	return func(
		ctx context.Context, req *mcp.CallToolRequest, in HarnessRunInput,
	) (*mcp.CallToolResult, HarnessRunOutput, error) {
		if strings.TrimSpace(in.Prompt) == "" {
			return toolError("harness_run: 'prompt' is required"), HarnessRunOutput{}, nil
		}

		reply, warn, err := runHarness(ctx, &in)
		if err != nil {
			// Infrastructure failure (loom missing, docker down, timeout with
			// no reply). Ledger the attempt so the failure is visible on the
			// same surface as the successes, then surface it as a tool error.
			persistHarnessRun(pool, in, loomReply{Error: err.Error()}, "error")
			return toolError("harness_run: %v", err), HarnessRunOutput{}, nil
		}
		if reply.Error != "" {
			persistHarnessRun(pool, in, reply, "error")
			return toolError("harness_run: harness reported: %s", reply.Error), HarnessRunOutput{}, nil
		}

		ledgerID, workItem := persistHarnessRun(pool, in, reply, "done")

		out := HarnessRunOutput{
			Text:             reply.Text,
			HarnessSessionID: reply.SessionID,
			CostUSD:          reply.CostUSD,
			Turns:            reply.Turns,
			Backend:          reply.Backend,
			LedgerID:         ledgerID,
			WorkItemID:       workItem,
		}

		header := fmt.Sprintf("[harness_run complete — backend=%s session=%s cost=$%.4f turns=%d",
			reply.Backend, reply.SessionID, reply.CostUSD, reply.Turns)
		if ledgerID > 0 {
			header += fmt.Sprintf(" ledger=%d", ledgerID)
		}
		header += "]"
		body := header + "\n\n" + reply.Text
		if warn != "" {
			body += "\n\n⚠️ " + warn
		}
		return &mcp.CallToolResult{
			Content: []mcp.Content{&mcp.TextContent{Text: body}},
		}, out, nil
	}
}

// runHarness builds + execs the canonical loom dispatch and parses the Reply.
// Returns (reply, warning, error) — warning carries non-fatal notes (e.g. a
// ledger insert that failed) the caller appends to the result text.
func runHarness(ctx context.Context, in *HarnessRunInput) (loomReply, string, error) {
	backend := strings.TrimSpace(in.Backend)
	if backend == "" {
		backend = "claude"
	}
	timeout := in.TimeoutSeconds
	if timeout <= 0 {
		timeout = harnessDefaultTimeoutSeconds
	}
	if timeout > harnessMaxTimeoutSeconds {
		timeout = harnessMaxTimeoutSeconds
	}
	if timeout < harnessMinTimeoutSeconds {
		timeout = harnessMinTimeoutSeconds
	}

	warn := ""

	// The workdir is the corpus. When the caller gives none, mount an empty
	// scratch dir — NEVER this process's cwd (that would leak whatever the
	// bridge happens to run in through the filesystem wall).
	workdir := strings.TrimSpace(in.Workdir)
	if workdir == "" {
		scratch, err := os.MkdirTemp("", "harness-run-")
		if err != nil {
			return loomReply{}, "", fmt.Errorf("create scratch workdir: %w", err)
		}
		workdir = scratch
		warn = "no workdir given — the harness ran against an empty scratch dir"
	} else if fi, err := os.Stat(workdir); err != nil || !fi.IsDir() {
		return loomReply{}, "", fmt.Errorf("workdir %q is not a readable directory on this host", workdir)
	}

	// The claude-home is a DEDICATED persistent dir, not the user's real
	// ~/.claude (see the header: a real home's MCP approval state breaks the
	// headless hinge; and the harness's session state — the resume handle's
	// other half — belongs to the substrate, not mixed into the user's own).
	claudeHome := strings.TrimSpace(os.Getenv("STEWARDS_HARNESS_CLAUDE_HOME"))
	if claudeHome == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return loomReply{}, "", fmt.Errorf("resolve claude-home: %w (set STEWARDS_HARNESS_CLAUDE_HOME)", err)
		}
		claudeHome = filepath.Join(home, ".stewards", "harness-claude-home")
	}
	if err := os.MkdirAll(claudeHome, 0o700); err != nil {
		return loomReply{}, "", fmt.Errorf("create claude-home %q: %w (set STEWARDS_HARNESS_CLAUDE_HOME)", claudeHome, err)
	}

	allowed := strings.TrimSpace(os.Getenv("STEWARDS_HARNESS_ALLOWED_TOOLS"))
	mcpURL := strings.TrimSpace(os.Getenv("STEWARDS_HARNESS_MCP_URL"))

	args := []string{"run",
		"--agent", backend,
		"--isolate",
		"--skip-permissions",
		"--json",
		"--dir", workdir,
		"--claude-home", claudeHome,
	}

	if mcpURL != "" {
		// The hinge: generate the mcp-config INSIDE claude-home so the
		// container path resolves, pointing at the Arc C read-only HTTP
		// surface. The token (if any) goes only into this file — the same
		// posture as the mounted .credentials.json — never into argv or logs.
		cfg := map[string]any{
			"mcpServers": map[string]any{
				"pg-ai-stewards": harnessMCPServerEntry(mcpURL),
			},
		}
		raw, err := json.MarshalIndent(cfg, "", "  ")
		if err != nil {
			return loomReply{}, "", fmt.Errorf("encode mcp config: %w", err)
		}
		if err := os.WriteFile(filepath.Join(claudeHome, harnessMCPConfigName), raw, 0o600); err != nil {
			return loomReply{}, "", fmt.Errorf("write mcp config into claude-home: %w", err)
		}
		args = append(args, "--mcp-config", containerClaudeDir+"/"+harnessMCPConfigName)
	}

	if allowed == "" {
		tools := append([]string{}, harnessClaudeReadTools...)
		if mcpURL != "" {
			tools = append(tools, harnessSubstrateReadTools...)
		}
		allowed = strings.Join(tools, ",")
	}
	args = append(args, "--allowed-tools", allowed)

	// The prompt is one argv arg — loom re-joins its positional args, so a
	// multiline prompt survives intact.
	args = append(args, in.Prompt)

	loomBin := strings.TrimSpace(os.Getenv("STEWARDS_LOOM_BIN"))
	if loomBin == "" {
		loomBin = "loom"
	}
	if _, err := exec.LookPath(loomBin); err != nil {
		return loomReply{}, "", fmt.Errorf(
			"loom binary %q not found — set STEWARDS_LOOM_BIN or install loom on PATH "+
				"(Phase 1 runs harness_run where loom + docker + claude auth live; the bridge image does not carry loom yet)",
			loomBin)
	}

	tctx, cancel := context.WithTimeout(ctx, time.Duration(timeout)*time.Second)
	defer cancel()

	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(tctx, loomBin, args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	log.Printf("harness_run: dispatching via %s (backend=%s workdir=%s hinge=%v timeout=%ds)",
		loomBin, backend, workdir, mcpURL != "", timeout)
	start := time.Now()
	runErr := cmd.Run()
	elapsed := time.Since(start).Round(time.Second)

	reply, ok := parseLoomReply(stdout.Bytes())
	if !ok {
		tail := stderrTail(stderr.Bytes())
		if tctx.Err() == context.DeadlineExceeded {
			// NOTE: killing loom abandons its `docker run` child; the --rm
			// container exits when its stdin pipe collapses, but a stuck one
			// is visible via `docker ps` (image loom-claude). Known Phase-1 seam.
			return loomReply{}, "", fmt.Errorf("timed out after %ds with no reply (stderr tail: %s)", timeout, tail)
		}
		if runErr != nil {
			return loomReply{}, "", fmt.Errorf("loom exited: %v (stderr tail: %s)", runErr, tail)
		}
		return loomReply{}, "", fmt.Errorf("no --json Reply found on loom stdout (stderr tail: %s)", tail)
	}
	log.Printf("harness_run: reply in %s (session=%s cost=$%.4f turns=%d err=%q)",
		elapsed, reply.SessionID, reply.CostUSD, reply.Turns, reply.Error)
	return reply, warn, nil
}

// harnessMCPServerEntry builds the claude --mcp-config server stanza for the
// hinge. Bearer auth (when configured) rides an Authorization header — the
// Arc C surface's constant-time check on the other end.
func harnessMCPServerEntry(url string) map[string]any {
	entry := map[string]any{"type": "http", "url": url}
	if token := strings.TrimSpace(os.Getenv("STEWARDS_HARNESS_MCP_TOKEN")); token != "" {
		entry["headers"] = map[string]string{"Authorization": "Bearer " + token}
	}
	return entry
}

// parseLoomReply scans stdout for the (last) parseable one-line JSON Reply.
// loom emits exactly one, but scanning defensively costs nothing and survives
// a stray banner from a wrapper shell.
func parseLoomReply(out []byte) (loomReply, bool) {
	var reply loomReply
	found := false
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 1024*1024), 16*1024*1024) // replies carry whole answers
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 || line[0] != '{' {
			continue
		}
		var r loomReply
		if err := json.Unmarshal(line, &r); err != nil {
			continue
		}
		if r.SessionID != "" || r.Text != "" || r.Error != "" {
			reply, found = r, true
		}
	}
	return reply, found
}

func stderrTail(b []byte) string {
	if len(b) > harnessStderrTailBytes {
		b = b[len(b)-harnessStderrTailBytes:]
	}
	return strings.TrimSpace(string(b))
}

// persistHarnessRun ledgers the dispatch on stewards.harness_runs (90) — the
// coder-artifact pattern: keyed to the dispatch session, work item resolved
// best-effort via stewards.session_work_item(). The loom session_id stored
// here is THE durable resume handle (resume needs the same claude-home).
// Best-effort by design: the dispatch already ran and cost real money — a
// ledger failure must not eat the answer. It logs loud instead.
func persistHarnessRun(pool *pgxpool.Pool, in HarnessRunInput, reply loomReply, status string) (int64, string) {
	if pool == nil {
		return 0, ""
	}
	backend := strings.TrimSpace(in.Backend)
	if backend == "" {
		backend = "claude"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var id int64
	var workItem string
	err := pool.QueryRow(ctx, `
		INSERT INTO stewards.harness_runs
		    (session_id, work_item_id, backend, workdir, prompt,
		     harness_session_id, cost_usd, turns, status, error)
		VALUES ($1, stewards.session_work_item($1), $2, $3, $4, $5, $6, $7, $8, nullif($9,''))
		RETURNING id, coalesce(work_item_id::text, '')`,
		nullableString(strings.TrimSpace(in.SessionID)), backend,
		nullableString(strings.TrimSpace(in.Workdir)), in.Prompt,
		nullableString(reply.SessionID), reply.CostUSD, reply.Turns, status, reply.Error,
	).Scan(&id, &workItem)
	if err != nil {
		log.Printf("harness_run: LEDGER WRITE FAILED (run NOT recorded; session=%s cost=$%.4f): %v",
			reply.SessionID, reply.CostUSD, err)
		return 0, ""
	}
	return id, workItem
}

// runHarnessSmoke is the `stewards-mcp harness-smoke` subcommand — the
// real-path proof driver (coder-mcp's --smoke pattern). It runs the EXACT
// same dispatch + ledger code the MCP tool uses, printing the Reply to
// stdout. Stdout discipline doesn't apply: this mode owns its stdout.
func runHarnessSmoke(args []string) error {
	fs := flag.NewFlagSet("harness-smoke", flag.ContinueOnError)
	prompt := fs.String("prompt", "", "the task for the harness (required)")
	workdir := fs.String("workdir", "", "host dir mounted as the harness's working dir")
	session := fs.String("session", "harness-smoke", "substrate session id to ledger the run under")
	dsnFlag := fs.String("dsn", "", "Postgres DSN for the ledger (default $STEWARDS_DSN; empty = no ledger)")
	timeout := fs.Int("timeout", harnessDefaultTimeoutSeconds, "dispatch timeout in seconds")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *prompt == "" {
		return fmt.Errorf("harness-smoke: -prompt is required")
	}

	var pool *pgxpool.Pool
	dsn := *dsnFlag
	if dsn == "" {
		dsn = os.Getenv("STEWARDS_DSN")
	}
	if dsn != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		p, err := pgxpool.New(ctx, dsn)
		if err == nil {
			err = p.Ping(ctx)
		}
		cancel()
		if err != nil {
			return fmt.Errorf("harness-smoke: connect %s: %w", redactDSN(dsn), err)
		}
		pool = p
		defer p.Close()
	} else {
		log.Printf("harness-smoke: no DSN — dispatching WITHOUT the ledger")
	}

	in := HarnessRunInput{
		Prompt:         *prompt,
		Workdir:        *workdir,
		TimeoutSeconds: *timeout,
		SessionID:      *session,
	}
	reply, warn, err := runHarness(context.Background(), &in)
	if err != nil {
		persistHarnessRun(pool, in, loomReply{Error: err.Error()}, "error")
		return fmt.Errorf("harness-smoke: %w", err)
	}
	status := "done"
	if reply.Error != "" {
		status = "error"
	}
	ledgerID, workItem := persistHarnessRun(pool, in, reply, status)

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(map[string]any{
		"reply":     reply,
		"ledger_id": ledgerID,
		"work_item": workItem,
		"warning":   warn,
	})
}
