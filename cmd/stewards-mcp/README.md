# stewards-mcp

MCP (Model Context Protocol) sidecar for the pg-ai-stewards substrate. Connects to Postgres via pgxpool and exposes substrate tools to MCP clients (Claude Code, etc.) over stdio.

## Phase 3e.1 — initial tool surface

Two read-only tools over the substrate's studies corpus:

| Tool | Wraps | Purpose |
|------|-------|---------|
| `doc_search` | `stewards.doc_search(query, kinds[], limit)` | FTS over slugs+titles+bodies, returns `{slug, kind, title, snippet, rank}` per hit |
| `doc_get` | `stewards.doc_get(slug, include_body, line_offset, line_count, max_chars)` | Read a study by slug with line-range pagination |

Future phases (3e.2-3e.5) add stewards_brain, stewards_work_item, gospel_passthrough, and outbound MCP-client capability for consuming external MCP servers like gospel-engine-v2.

## Seed memory (S1)

A client that sees tool *names* only has no signal that the corpus might already hold an answer, so it answers from its own head and never calls `doc_search` — "an amnesia it didn't know it had." The seed kills that: at startup the server derives a compact overview of what the corpus holds (doc counts by kind, knowledge pools with their most-recent doc titles as semantic hooks, active intents, recent activity) and injects it through **both** channels that reach the client LLM:

1. the MCP `instructions` field (returned at `initialize` — lands in the client's system prompt), and
2. the `doc_search` tool description (`CURRENT MEMORY OVERVIEW: …` — the universal fallback, since every tool-calling client loads tool descriptions even when it ignores server instructions).

The overview lists concept **descriptions**, not filenames — a pool with a description shows it (`ai — AI research + experiments to try`), because a semantic hook ignites the "memory might know this" instinct where a bare slug does not. The body is capped at 3000 chars with a "use doc_search to explore further" tail.

Freshness: the long-lived stdio server builds the seed once at startup (the `instructions` channel freezes per session by protocol regardless). The HTTP surface (`--http-addr`) rebuilds its server per MCP session, so it re-derives the seed on every connection — freshness with zero invalidation logic.

**Config:** on by default. Set `STEWARDS_SEED_MEMORY=false` (or `0`/`no`/`off`) to disable — both channels no-op, restoring the pre-seed behavior (a clean A/B toggle). A seed fetch failure degrades to the same no-overview behavior rather than blocking the `initialize` handshake.

Ported (pattern, not code) from understory's `packages/server/src/mcp/seed.ts`; design source `.spec/proposals/understory-steals.md` §S1.

## Build

The module is registered in the workspace `go.work` at the repo root. Build with:

```bash
cd projects/pg-ai-stewards/cmd/stewards-mcp
go build -o ../../bin/stewards-mcp.exe .
```

## Configure Claude Code

Add to `.mcp.json` at the repo root (gitignored — local config only):

```json
{
  "mcpServers": {
    "pg-ai-stewards": {
      "type": "stdio",
      "command": "C:/path/to/workspace/projects/pg-ai-stewards/bin/stewards-mcp.exe",
      "env": {
        "STEWARDS_DSN": "postgres://stewards:stewards@localhost:55433/stewards?sslmode=disable",
        "STEWARDS_SEED_MEMORY": "true"
      }
    }
  }
}
```

Restart the Claude Code session — `.mcp.json` is read at session startup. After restart, `mcp__pg-ai-stewards__doc_search` and `mcp__pg-ai-stewards__doc_get` should appear in the deferred-tools list.

## Manual smoke test

Without restarting Claude Code, you can test the protocol by piping JSON-RPC messages through stdin:

```bash
{
  echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"smoke","version":"0.1"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"doc_search","arguments":{"query":"faith hope charity","limit":3}}}'
  sleep 2
} | ./bin/stewards-mcp.exe 2>/dev/null
```

Expected: two newline-delimited JSON-RPC responses on stdout, the second containing the FTS hits in `result.structuredContent.results`.

## Troubleshooting

- **Server starts but no tools appear in Claude Code:** restart the session — `.mcp.json` is only read at startup.
- **"connection refused" in stderr logs:** verify the docker container is up (`docker ps`) and Postgres is reachable on port 55433.
- **JSON-RPC errors / corrupted output:** make sure no Go code in the project writes to stdout. The server pins logging to stderr; transitive deps doing `fmt.Println` would corrupt the protocol stream.
- **First-run approval dialog:** project-scoped MCP servers prompt for approval. Accept once to whitelist; clear with `claude mcp reset-project-choices` to test approval flow again.

## Implementation notes

- **Go module:** standalone `go.mod` (matching the stewards-cli pattern). Registered in workspace `go.work`.
- **SDK:** [`github.com/modelcontextprotocol/go-sdk` v1.6.0](https://github.com/modelcontextprotocol/go-sdk) — official Anthropic+Google SDK. Released 2026-05-08.
- **Transport:** stdio with newline-delimited JSON-RPC. SDK handles framing.
- **Logging:** stderr only. The `log.SetOutput(os.Stderr)` in main.go is critical.
- **Connection:** single pgxpool, opened at startup, closed on graceful shutdown.

See `.github/skills/mcp-server-go/SKILL.md` for protocol patterns and gotchas. See `projects/pg-ai-stewards/docs/3e-mcp-findings.md` for the build-out journal.
