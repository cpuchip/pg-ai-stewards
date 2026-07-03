// otel-smoke: the real-path proof driver for the OTel exporter (miss D of
// the 2026-07-03 audit). Mirrors the harness-smoke / coder-mcp --smoke
// discipline (main.go): the exact fetch -> span-build -> OTLP-POST code the
// background poller (otel_export.go) runs, invoked directly from the shell
// so a fix -- or an operator's new collector -- can be verified without
// waiting on a poll cycle.
//
// Deliberately does NOT touch stewards.config (no checkpoint read/write):
// this is a read-plus-network-POST tool, safe to run read-only against a
// shared database. runOtelExporter (the real background loop) owns
// checkpointing; this command only ever re-reads and re-sends the same
// window of history, which is safe given the exporter's deterministic
// trace/span ids (otel_otlp.go).
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func runOtelSmoke(args []string) error {
	fs := flag.NewFlagSet("otel-smoke", flag.ContinueOnError)
	dsn := fs.String("dsn", "",
		"Postgres DSN (default: $STEWARDS_DSN, then localhost compose port 55433)")
	endpoint := fs.String("endpoint", os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"),
		"OTLP/HTTP base endpoint, e.g. http://127.0.0.1:4318 (default: $OTEL_EXPORTER_OTLP_ENDPOINT)")
	since := fs.Duration("since", 24*time.Hour,
		"how far back to look for completed/failed/cancelled work_items")
	limit := fs.Int("limit", 5, "max work_items to export")
	if err := fs.Parse(args); err != nil {
		return err
	}

	if *dsn == "" {
		*dsn = os.Getenv("STEWARDS_DSN")
	}
	if *dsn == "" {
		*dsn = "postgres://stewards:stewards@localhost:55433/stewards?sslmode=disable"
	}
	ep := strings.TrimRight(strings.TrimSpace(*endpoint), "/")
	if ep == "" {
		return fmt.Errorf("no OTLP endpoint: pass --endpoint or set OTEL_EXPORTER_OTLP_ENDPOINT")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pool, err := pgxpool.New(ctx, *dsn)
	if err != nil {
		return fmt.Errorf("pgxpool.New: %w", err)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		return fmt.Errorf("pool.Ping: %w", err)
	}

	exp := &otelExporter{
		pool:        pool,
		client:      &http.Client{Timeout: 15 * time.Second},
		endpoint:    ep,
		serviceName: otelDefaultService,
		headers:     parseOtelHeaders(os.Getenv("OTEL_EXPORTER_OTLP_HEADERS")),
	}

	items, err := exp.fetchWorkItems(ctx, time.Now().UTC().Add(-*since), *limit)
	if err != nil {
		return fmt.Errorf("fetch work_items: %w", err)
	}
	if len(items) == 0 {
		fmt.Printf("otel-smoke: no completed/failed/cancelled work_items in the last %s\n", *since)
		return nil
	}
	fmt.Printf("otel-smoke: found %d work_item(s):\n", len(items))
	for _, it := range items {
		fmt.Printf("  %s  pipeline=%-22s status=%-10s sessions=%d\n",
			it.ID, it.PipelineFamily, it.Status, len(it.SessionIDs))
	}

	spans, _, err := exp.buildSpans(ctx, items)
	if err != nil {
		return fmt.Errorf("build spans: %w", err)
	}
	fmt.Printf("otel-smoke: built %d span(s), POSTing to %s/v1/traces ...\n", len(spans), exp.endpoint)

	if err := otlpPost(ctx, exp.client, exp.endpoint, exp.headers, exp.buildRequest(spans)); err != nil {
		return fmt.Errorf("POST: %w", err)
	}
	fmt.Printf("otel-smoke: export OK (%d span(s) across %d work_item(s)); checkpoint NOT touched -- this is a read-only proof tool\n",
		len(spans), len(items))
	return nil
}
