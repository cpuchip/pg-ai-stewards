// Arc C — remote MCP over HTTP. Lets OTHER agents (Claude Code, Codex, …) point
// at the substrate's tools over the network, instead of only an in-box stdio
// `claude mcp add`. The security model IS the feature:
//
//   - READ-ONLY tool profile only (doc_* + inspection) — never the write/spawn/
//     coder tools the stdio surface carries. A remote caller can browse + search
//     our knowledge, not mutate it or spawn work.
//   - Bearer-token auth (constant-time compare). No token + non-loopback bind is
//     refused loudly; localhost dev may run tokenless.
//   - Local-bound first (the ratified posture): default to 127.0.0.1; flip to the
//     mesh once proven. Coder/write tools never join this profile without an
//     explicit, separate decision.
//
// Transport: the go-sdk's StreamableHTTPHandler (one POST endpoint at /mcp).
package main

import (
	"context"
	"crypto/subtle"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func runHTTP(ctx context.Context, pool *pgxpool.Pool, addr string) error {
	token := strings.TrimSpace(os.Getenv("STEWARDS_MCP_HTTP_TOKEN"))
	if token == "" && !isLoopback(addr) {
		// Refuse to expose an unauthenticated surface beyond localhost.
		return errNoTokenOffLoopback{addr}
	}
	if token == "" {
		log.Printf("WARNING: no STEWARDS_MCP_HTTP_TOKEN — the HTTP MCP surface is UNAUTHENTICATED (localhost only).")
	}

	// Each MCP session gets a fresh server carrying ONLY the read-only profile.
	getServer := func(_ *http.Request) *mcp.Server {
		s := mcp.NewServer(&mcp.Implementation{
			Name:    "pg-ai-stewards (remote, read-only)",
			Version: version,
		}, nil)
		registerDocTools(s, pool)        // doc_search / doc_get / doc_similar / doc_citations
		registerInspectionTools(s, pool) // read-only work-item / corpus inspection
		registerModelTools(s, pool)      // list_models / list_connectors — read-only catalog views (90: list_models is in the harness hinge's ratified read set)
		return s
	}
	handler := mcp.NewStreamableHTTPHandler(getServer, nil)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte("ok"))
	})
	mux.Handle("/mcp", bearerAuth(token, handler))

	httpSrv := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		sctx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		_ = httpSrv.Shutdown(sctx)
	}()
	log.Printf("remote MCP (read-only: doc_*, inspection) on http://%s/mcp (auth=%v)", addr, token != "")
	if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	log.Printf("remote MCP server stopped cleanly")
	return nil
}

// bearerAuth gates the handler on a bearer token (constant-time). Empty token =
// pass-through (only reached on a loopback bind; see runHTTP).
//
// Host normalization (90, token mode only): the go-sdk's StreamableHTTPHandler
// carries DNS-rebinding protection — a loopback listener 403s any request
// whose Host header is non-loopback. That is exactly what a docker-walled
// harness (loom-claude) sends: it reaches this loopback surface via
// host.docker.internal, so its Host is "host.docker.internal:<port>" and the
// SDK rejects the hinge with "Forbidden: invalid Host header" (live-diagnosed
// 2026-07-03). Rebinding protection exists to stop a browser whose DNS was
// rebound — a caller that CANNOT present a custom Authorization header. Once
// the constant-time bearer check has passed, Host is not load-bearing, so we
// normalize it and let the SDK's check see loopback. Tokenless (dev) mode
// keeps the SDK protection untouched.
func bearerAuth(token string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if token != "" {
			got := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
			if subtle.ConstantTimeCompare([]byte(got), []byte(token)) != 1 {
				http.Error(w, "unauthorized", http.StatusUnauthorized)
				return
			}
			r.Host = "127.0.0.1"
		}
		next.ServeHTTP(w, r)
	})
}

// isLoopback reports whether addr binds only the loopback interface.
func isLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	host = strings.TrimSpace(host)
	if host == "" {
		return false // ":8092" binds all interfaces
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

type errNoTokenOffLoopback struct{ addr string }

func (e errNoTokenOffLoopback) Error() string {
	return "refusing to serve an UNAUTHENTICATED MCP surface on a non-loopback addr (" + e.addr +
		"): set STEWARDS_MCP_HTTP_TOKEN or bind 127.0.0.1"
}
