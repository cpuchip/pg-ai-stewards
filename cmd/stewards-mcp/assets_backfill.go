// `stewards-mcp assets-backfill --doc <id>` — the CLI verb for the wiki-
// assets capability (extension/96-wiki-assets.sql). Re-extracts wiki assets
// (embedded PDF picture XObjects — maps, character art, item cards, tables)
// from an ALREADY-INGESTED document via the SAME hardened doc-extract
// sandbox `doc_extract` uses, so a TTRPG rulebook imported before this
// capability existed gets its assets without a re-import. The actual
// extraction + persistence logic lives in internal/wikiassets (shared with
// the `assets_backfill` MCP tool on doc-extract-mcp, so there is exactly one
// implementation behind both entry points — see that package's doc comment).
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/cpuchip/pg-ai-stewards/cmd/doc-extract-mcp/runner"
	"github.com/cpuchip/pg-ai-stewards/internal/wikiassets"
)

func runAssetsBackfill(args []string) error {
	fs := flag.NewFlagSet("assets-backfill", flag.ContinueOnError)
	doc := fs.String("doc", "", "a chat_attachments id (the original PDF) OR a stewards.docs slug/id it was pooled into via doc_import_corpus (required)")
	dsnFlag := fs.String("dsn", "", "Postgres DSN (default: $STEWARDS_DSN, then localhost compose port 55433)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *doc == "" {
		return fmt.Errorf("assets-backfill: --doc is required (a chat_attachments id or a docs slug/id)")
	}

	dsn := *dsnFlag
	if dsn == "" {
		dsn = os.Getenv("STEWARDS_DSN")
	}
	if dsn == "" {
		dsn = "postgres://stewards:stewards@localhost:55433/stewards?sslmode=disable"
	}

	ctx := context.Background()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		return fmt.Errorf("pgxpool.New: %w", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf("pool.Ping: %w", err)
	}

	run := runner.New()
	res, err := wikiassets.Backfill(ctx, pool, run, *doc)
	if err != nil {
		return fmt.Errorf("assets-backfill %q: %w", *doc, err)
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(res)
}
