// Command stewards-mcp is the MCP (Model Context Protocol) sidecar for
// the pg-ai-stewards substrate. It connects to Postgres via pgxpool and
// exposes substrate tools to MCP clients (Claude Code, etc.) over stdio.
//
// Phase 3e.1 (2026-05-08): initial version exposes two read-only tools
// over the studies corpus:
//   - doc_search — full-text + kinds-filter search (wraps stewards.doc_search)
//   - doc_get    — read a study by slug with line-range pagination (wraps stewards.doc_get)
//
// Future phases will add stewards_brain, stewards_work_item, gospel_passthrough,
// and outbound MCP-client capability for consuming gospel-engine-v2.
//
// Critical discipline (per .github/skills/mcp-server-go/SKILL.md):
//   - All logging MUST go to stderr. Stdout is reserved for the JSON-RPC
//     protocol stream — any stray println there corrupts the wire.
//   - The MCP SDK handles the initialize handshake, capability negotiation,
//     newline-delimited JSON-RPC framing, and notification ordering.
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// Version reported in the initialize handshake's serverInfo.
const version = "0.1.0"

func main() {
	// CRITICAL: pin the default logger to stderr. Anything to stdout
	// (including library logs we don't control) corrupts the protocol
	// stream. We override the package-level default so transitive deps
	// that call log.Print* land on stderr.
	log.SetOutput(os.Stderr)
	log.SetPrefix("stewards-mcp: ")
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	// Subcommand dispatch. The default mode (no subcommand) is the MCP
	// stdio server for inbound tool calls (Phase 3e.1+). The `bridge`
	// subcommand puts us in outbound MCP-client mode (Phase 3e.2.a) —
	// connecting to external MCP servers and populating the substrate's
	// mcp_tool_cache.
	if len(os.Args) > 1 && os.Args[1] == "bridge" {
		if err := runBridge(os.Args[2:]); err != nil {
			log.Fatalf("bridge: %v", err)
		}
		return
	}

	// `harness-smoke` — the real-path proof driver for harness_run (90): the
	// exact dispatch + ledger code the MCP tool runs, from the shell. Mirrors
	// coder-mcp's --smoke discipline.
	if len(os.Args) > 1 && os.Args[1] == "harness-smoke" {
		if err := runHarnessSmoke(os.Args[2:]); err != nil {
			log.Fatalf("harness-smoke: %v", err)
		}
		return
	}

	// `harness-home-init` — seed STEWARDS_HARNESS_CLAUDE_HOME with a
	// CLAUDE.md + settings.json (harness_home_init.go). Idempotent; run it
	// once per box (or after a fresh claude-home wipe).
	if len(os.Args) > 1 && os.Args[1] == "harness-home-init" {
		if err := runHarnessHomeInit(os.Args[2:]); err != nil {
			log.Fatalf("harness-home-init: %v", err)
		}
		return
	}

	// `otel-smoke` -- the real-path proof driver for the OTel exporter (miss
	// D): the exact fetch + span-build + OTLP-POST code otel_export.go's
	// background poller runs, invoked directly so a collector/endpoint can
	// be verified without waiting on the 10s poll tick. Read-only against
	// the substrate (no checkpoint write) -- see otel_smoke.go + docs/otel.md.
	if len(os.Args) > 1 && os.Args[1] == "otel-smoke" {
		if err := runOtelSmoke(os.Args[2:]); err != nil {
			log.Fatalf("otel-smoke: %v", err)
		}
		return
	}

	// `assets-backfill --doc <id>` — the wiki-assets CLI verb (extension/93-
	// wiki-assets.sql): re-extract embedded PDF picture XObjects from an
	// ALREADY-INGESTED document via the hardened doc-extract sandbox, so a
	// rulebook imported before this capability existed gets its assets
	// without a re-import. See assets_backfill.go + internal/wikiassets.
	if len(os.Args) > 1 && os.Args[1] == "assets-backfill" {
		if err := runAssetsBackfill(os.Args[2:]); err != nil {
			log.Fatalf("assets-backfill: %v", err)
		}
		return
	}

	// CLI flags. DSN can also come from STEWARDS_DSN env var (same as
	// stewards-cli) so the .mcp.json config can stay terse.
	var dsn string
	flag.StringVar(&dsn, "dsn", "",
		"Postgres DSN (default: $STEWARDS_DSN, then localhost compose port 55433)")
	var httpAddr string
	flag.StringVar(&httpAddr, "http-addr", os.Getenv("STEWARDS_MCP_HTTP_ADDR"),
		"Arc C: serve a READ-ONLY MCP surface over HTTP at this addr (e.g. 127.0.0.1:8092) for remote agents (Claude Code / Codex) instead of stdio. Token via STEWARDS_MCP_HTTP_TOKEN. Bind localhost-only unless you know what you're doing.")
	flag.Parse()

	if dsn == "" {
		dsn = os.Getenv("STEWARDS_DSN")
	}
	if dsn == "" {
		dsn = "postgres://stewards:stewards@localhost:55433/stewards?sslmode=disable"
	}

	// Root context cancelled on SIGINT/SIGTERM so the server shuts down
	// cleanly when Claude Code closes the stdio pipe.
	ctx, stop := signal.NotifyContext(context.Background(),
		os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Open the pool. ParseConfig + NewWithConfig would let us tune
	// MaxConns etc., but the default (4 * NumCPU) is fine for a
	// read-mostly tool surface.
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		log.Fatalf("pgxpool.New: %v", err)
	}
	defer pool.Close()

	// Quick connectivity check before declaring ready. Fail-fast on
	// startup is friendlier than the first tool call returning a cryptic
	// connection error.
	if err := pool.Ping(ctx); err != nil {
		log.Fatalf("pool.Ping: %v", err)
	}
	log.Printf("connected to substrate (dsn=%s)", redactDSN(dsn))

	// Arc C: remote MCP over HTTP — a READ-ONLY surface for other agents,
	// token-authed, bound where you say (default localhost). Distinct from the
	// stdio surface below (which carries the full write/spawn toolset for the
	// in-box bridge). See runHTTP in http.go.
	if httpAddr != "" {
		if err := runHTTP(ctx, pool, httpAddr); err != nil {
			log.Fatalf("http server: %v", err)
		}
		return
	}

	// Build the MCP server. Capabilities are auto-declared by the SDK
	// based on what tools/resources/prompts we register.
	srv := mcp.NewServer(&mcp.Implementation{
		Name:    "pg-ai-stewards",
		Version: version,
	}, nil)

	// Register tools. Each handler closes over the pool so it can run
	// queries; the pool is already context-aware and goroutine-safe.
	registerDocTools(srv, pool)
	registerDocWriteTools(srv, pool, "stdio-main") // doc_create/append/patch/read/finalize/current (90) — one stable draft namespace for this long-lived stdio process
	registerInspectionTools(srv, pool)
	registerEscalationTools(srv, pool)
	registerExpandTools(srv, pool)
	registerSpawnSubagentTools(srv, pool)
	registerConsultSubagentTools(srv, pool)
	registerHeavyweightTools(srv, pool)
	registerCompactContextTool(srv, pool)
	registerBrainstormTools(srv, pool)
	registerModelTools(srv, pool)
	registerRedlineTools(srv, pool)
	registerImageTools(srv, pool)   // generate_image (Gemini Nano Banana → chat attachment); NOT on the read-only HTTP profile
	registerA2ATools(srv, pool)     // A2A / Open Engine — hand work to / claim work from other agents
	registerHarnessTools(srv, pool) // harness_run (90) — loom Phase-1 dispatch; NOT on the read-only HTTP profile

	log.Printf("server starting on stdio (mcp protocol)")
	if err := srv.Run(ctx, &mcp.StdioTransport{}); err != nil {
		// Run returns nil on graceful shutdown (ctx cancellation), so
		// any non-nil err here is a real failure.
		log.Fatalf("server.Run: %v", err)
	}
	log.Printf("server stopped cleanly")
}

// redactDSN strips the password component from a Postgres URL so we can
// log the connection target without leaking the secret. Best-effort —
// if the DSN isn't a URL form (e.g. key=value pair list), returns it
// unchanged.
func redactDSN(dsn string) string {
	// postgres://user:password@host:port/db?args
	at := -1
	for i := len(dsn) - 1; i >= 0; i-- {
		if dsn[i] == '@' {
			at = i
			break
		}
	}
	if at < 0 {
		return dsn
	}
	colon := -1
	for i := at - 1; i >= 0; i-- {
		if dsn[i] == ':' {
			colon = i
			break
		}
		if dsn[i] == '/' {
			break // hit scheme://, no password component
		}
	}
	if colon < 0 {
		return dsn
	}
	return dsn[:colon+1] + "***" + dsn[at:]
}
