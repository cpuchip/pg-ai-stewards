// doc-extract-mcp is the bridge-side MCP server for the doc-extract capability
// (rich-docs P3). It exposes the `doc_extract` tool: given a chat_attachments
// id, it reads the stored bytes, spawns the hardened no-network sandbox to turn
// them into safe subject material (text always + page pixels on request), and
// writes the result back to the DB — extracted_text on the document, page
// images as child attachments. The bytes never round-trip through the model.
//
// Like coder-mcp it shells `docker` against the host daemon (the bridge mounts
// the socket via docker-compose.doc-extract.yaml). It connects to Postgres via
// STEWARDS_DSN (inherited from the bridge) to read/write chat_attachments.
//
// Critical discipline (.github/skills/mcp-server-go): all logging to stderr;
// stdout is reserved for JSON-RPC.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/cpuchip/pg-ai-stewards/cmd/doc-extract-mcp/runner"
)

const version = "0.1.0"

func main() {
	smoke := flag.Bool("smoke", false, "Spawn the doc-extract sandbox on a benign input, assert it extracts, and exit.")
	flag.Parse()

	log.SetOutput(os.Stderr)
	log.SetPrefix("doc-extract-mcp: ")
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	if *smoke {
		if err := runSmoke(); err != nil {
			log.Fatalf("smoke FAILED: %v", err)
		}
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	dsn := os.Getenv("STEWARDS_DSN")
	if dsn == "" {
		log.Fatalf("STEWARDS_DSN is required (the bridge sets it; doc-extract-mcp reads/writes chat_attachments)")
	}
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		log.Fatalf("pgxpool.New: %v", err)
	}
	defer pool.Close()

	run := runner.New()
	srv := mcp.NewServer(&mcp.Implementation{Name: "doc-extract-mcp", Version: version}, nil)
	registerDocExtractTools(srv, run, pool)

	log.Printf("server starting on stdio (mcp protocol); image=%s clamav_vol=%s", run.Image, run.ClamAVVol)
	if err := srv.Run(ctx, &mcp.StdioTransport{}); err != nil {
		log.Fatalf("server.Run: %v", err)
	}
	log.Printf("server stopped cleanly")
}

// runSmoke proves the bridge -> sandbox -> result path on a benign input.
// Requires the doc-extract image to be built + the docker socket reachable.
func runSmoke() error {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	r := runner.New()
	fmt.Printf("doc-extract-mcp smoke: spawning %s (network=none, read-only)…\n", r.Image)
	res, stderr, err := r.Extract(ctx, []byte("hello from the doc-extract-mcp smoke"),
		runner.ExtractArgs{Filename: "note.txt"})
	if err != nil {
		return fmt.Errorf("%w", err)
	}
	if len(res.Files) != 1 || res.Files[0].WordCount == 0 || res.Files[0].Skipped {
		return fmt.Errorf("benign extraction failed: %+v (stderr: %s)", res, stderr)
	}
	fmt.Printf("doc-extract-mcp smoke: PASS (words=%d, verdict=%s, engine=%s)\n",
		res.Files[0].WordCount, res.Files[0].Scan.Verdict, res.Files[0].Scan.Engine)
	return nil
}
