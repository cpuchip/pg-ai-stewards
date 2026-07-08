// Arc C — remote MCP over HTTP. Lets OTHER agents (Claude Code, Codex, …) point
// at the substrate's tools over the network, instead of only an in-box stdio
// `claude mcp add`. The security model IS the feature:
//
//   - Mostly READ-ONLY tool profile (doc_* + inspection + model catalog) — never
//     a2a_submit/spawn/coder tools. A remote caller can browse + search our
//     knowledge and, since 90's write-back addendum (ratified 1B, 2026-07-03),
//     BUILD AND POOL A DOCUMENT + LEAVE A NOTE via the narrow set below — still
//     never mutate anything else or spawn work.
//   - Bearer-token auth (constant-time compare). No token + non-loopback bind is
//     refused loudly; localhost dev may run tokenless.
//   - Local-bound first (the ratified posture): default to 127.0.0.1; flip to the
//     mesh once proven.
//
// The narrow write set (90): doc_create / doc_append_section / doc_patch /
// doc_read / doc_finalize / doc_current (the "doc create/update" verbs 34
// already built, newly wired to an MCP surface — see doc_write.go's header)
// plus a2a_note / a2a_note_clear (the "leave a work-item note" verb, split out
// of the full a2a surface — see registerA2ANoteTools in a2a.go). Deliberately
// ABSENT: a2a_submit/a2a_claim/a2a_receipt/a2a_register/a2a_inbox/a2a_answer/
// a2a_needs_input, spawn_subagent, harness_run itself, every coder_* tool —
// the wall is that they are simply not registered on this server, not a
// prompt asking the caller to behave.
//
// Transport: the go-sdk's StreamableHTTPHandler (one POST endpoint at /mcp).
package main

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"log"
	"net"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// wiSessionRe is the ONLY caller-declared session shape X-Stewards-Session may
// set (#333): the substrate's own per-stage dispatch sessions,
// wi--<uuid8>--<stage>. Everything else falls back to the anonymous arc-c-*
// namespace, so a caller can scope itself to a work item but never impersonate
// a chat/persona/stewdio session (those use different prefixes by design).
var wiSessionRe = regexp.MustCompile(`^wi--[0-9a-fA-F]{8}--[A-Za-z0-9._-]{1,64}$`)

func runHTTP(ctx context.Context, pool *pgxpool.Pool, addr string) error {
	token := strings.TrimSpace(os.Getenv("STEWARDS_MCP_HTTP_TOKEN"))
	if token == "" && !isLoopback(addr) {
		// Refuse to expose an unauthenticated surface beyond localhost.
		return errNoTokenOffLoopback{addr}
	}
	if token == "" {
		log.Printf("WARNING: no STEWARDS_MCP_HTTP_TOKEN — the HTTP MCP surface is UNAUTHENTICATED (localhost only).")
	}

	// Each MCP session gets a fresh server. getServer runs once per NEW MCP
	// session (the go-sdk reuses the returned server for the rest of that
	// session — see streamable.go's "OK for getServer to return the same
	// server multiple times" / the sessInfo==nil branch), so a fresh random
	// sessionID minted here is stable for one caller's whole connection —
	// e.g. one harness dispatch's entire lifetime — and private to it. That
	// gives doc_create/append/patch/finalize (doc_write.go) a natural,
	// per-dispatch draft namespace with zero cross-dispatch bleed, no new
	// plumbing required.
	getServer := func(r *http.Request) *mcp.Server {
		s := mcp.NewServer(&mcp.Implementation{
			Name:    "pg-ai-stewards (remote, read-mostly)",
			Version: version,
		}, nil)
		// #333 session propagation: a loom-dispatched stage's claude session
		// may DECLARE its substrate dispatch session via X-Stewards-Session
		// (bgworker → OpenAI `user` field → loom injects the header into the
		// per-session MCP config). Trusting it sits BEHIND the bearer token,
		// and only the wi--<uuid8>--<stage> shape is honored — so a token-
		// holding caller can scope its drafts to the work item it serves,
		// which is what restores doc→work-item provenance at finalize when
		// the draft CREATOR is a loom stage. Anything else keeps the anonymous
		// per-connection arc-c-* namespace (the handle-as-capability default).
		session := "arc-c-" + newHTTPSessionID()
		if h := strings.TrimSpace(r.Header.Get("X-Stewards-Session")); wiSessionRe.MatchString(h) {
			session = h
		}
		registerDocTools(s, pool)        // doc_search / doc_get / doc_similar / doc_citations
		registerInspectionTools(s, pool) // read-only work-item / corpus inspection
		registerModelTools(s, pool)      // list_models / list_connectors — read-only catalog views (90: list_models is in the harness hinge's ratified read set)
		registerDocWriteTools(s, pool, session)
		registerA2ANoteTools(s, pool) // a2a_note / a2a_note_clear ONLY — never a2a_submit/claim/receipt/etc.
		registerSubstrateToolDispatch(s, pool, session) // dynamic sql_fn catalog (#346): read freely, writes per allowlist
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
	log.Printf("remote MCP (read: doc_*/inspection/models; narrow write: doc build/finalize + a2a_note) on http://%s/mcp (auth=%v)", addr, token != "")
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

// newHTTPSessionID mints a short random hex id for one Arc C MCP connection —
// used only to scope doc_write.go's draft namespace per-caller (not a
// security boundary; the security boundary is which tools are registered at
// all, per this file's header).
func newHTTPSessionID() string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand failing is exceptional; fall back to a fixed
		// (still-private-enough, single-process) value rather than panic.
		return "fallback"
	}
	return hex.EncodeToString(b[:])
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
