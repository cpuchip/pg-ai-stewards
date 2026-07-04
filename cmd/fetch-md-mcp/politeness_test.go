package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 98-crawler politeness floor: robots.txt honored, per-domain rate limit
// spaced, robots cache hit. All against httptest — no live sites.

func testGateFor(srv *httptest.Server) (*fetchConfig, *politeGate) {
	client := srv.Client()
	gate := newPoliteGate(client, defaultUserAgent)
	return &fetchConfig{
		HTTPClient: client,
		UserAgent:  defaultUserAgent,
		Gate:       gate,
	}, gate
}

// robotsSite serves a robots.txt plus trivial pages, counting robots hits.
func robotsSite(t *testing.T, robots string, robotsHits *atomic.Int32) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/robots.txt", func(w http.ResponseWriter, r *http.Request) {
		robotsHits.Add(1)
		_, _ = w.Write([]byte(robots))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("<html><body><p>hello from " + r.URL.Path + "</p></body></html>"))
	})
	return httptest.NewServer(mux)
}

func TestRobotsDisallowedBlocked(t *testing.T) {
	var hits atomic.Int32
	srv := robotsSite(t, "User-agent: *\nDisallow: /secret/\n", &hits)
	defer srv.Close()
	_, gate := testGateFor(srv)

	if err := gate.Check(context.Background(), srv.URL+"/open/page.html", minRateMS); err != nil {
		t.Fatalf("allowed path blocked: %v", err)
	}
	err := gate.Check(context.Background(), srv.URL+"/secret/hidden.html", minRateMS)
	if err == nil {
		t.Fatal("disallowed path was not blocked")
	}
	if !strings.Contains(err.Error(), "robots.txt disallows") {
		t.Errorf("blocked error should be structured and name robots.txt; got %v", err)
	}
	if !strings.Contains(err.Error(), "/secret/") {
		t.Errorf("blocked error should name the matched rule; got %v", err)
	}
}

// The wiring test: fetch_url itself (the real tool handler) refuses a
// robots-disallowed URL when enforce_robots=true, and still fetches it
// when enforcement is off (the interactive default is unchanged).
func TestFetchURLHonorsEnforceRobots(t *testing.T) {
	var hits atomic.Int32
	srv := robotsSite(t, "User-agent: *\nDisallow: /secret/\n", &hits)
	defer srv.Close()
	cfg, _ := testGateFor(srv)
	handler := makeFetchURL(cfg)

	res, _, err := handler(context.Background(), nil, fetchURLInput{
		URL: srv.URL + "/secret/hidden.html", EnforceRobots: true, RateMS: minRateMS,
	})
	if err != nil {
		t.Fatalf("handler error: %v", err)
	}
	if res == nil || !res.IsError {
		t.Fatal("enforce_robots=true on a disallowed URL must return a tool error")
	}

	res, out, err := handler(context.Background(), nil, fetchURLInput{
		URL: srv.URL + "/secret/hidden.html", // enforcement OFF: default behavior
	})
	if err != nil || res != nil {
		t.Fatalf("default (no enforcement) fetch should succeed: res=%v err=%v", res, err)
	}
	if out.Markdown == "" {
		t.Error("default fetch returned no content")
	}
}

func TestRateLimitSpacing(t *testing.T) {
	var hits atomic.Int32
	srv := robotsSite(t, "User-agent: *\nDisallow:\n", &hits)
	defer srv.Close()
	_, gate := testGateFor(srv)

	// 3 permits at the 500ms floor. The first call also pays a robots
	// fetch slot, so total spacing is >= 3 intervals from the ledger's
	// perspective; measure just the page permits: >= 2 intervals apart.
	start := time.Now()
	for i := 0; i < 3; i++ {
		if err := gate.Check(context.Background(), srv.URL+"/p.html", minRateMS); err != nil {
			t.Fatalf("check %d: %v", i, err)
		}
	}
	elapsed := time.Since(start)
	if elapsed < 900*time.Millisecond {
		t.Errorf("3 rate-limited permits completed in %v; want >= ~1s of enforced spacing", elapsed)
	}
}

func TestRateFloorClamped(t *testing.T) {
	if got := effectiveInterval(1); got != minRateMS*time.Millisecond {
		t.Errorf("rate_ms=1 must clamp UP to the %dms floor; got %v", minRateMS, got)
	}
	if got := effectiveInterval(0); got != defaultRateMS*time.Millisecond {
		t.Errorf("rate_ms=0 must default to %dms; got %v", defaultRateMS, got)
	}
	if got := effectiveInterval(5000); got != 5*time.Second {
		t.Errorf("rate_ms above the floor is honored as-is; got %v", got)
	}
}

func TestRobotsCacheHit(t *testing.T) {
	var hits atomic.Int32
	srv := robotsSite(t, "User-agent: *\nDisallow: /secret/\n", &hits)
	defer srv.Close()
	_, gate := testGateFor(srv)

	for i := 0; i < 3; i++ {
		if err := gate.Check(context.Background(), srv.URL+"/a.html", minRateMS); err != nil {
			t.Fatalf("check %d: %v", i, err)
		}
	}
	if n := hits.Load(); n != 1 {
		t.Errorf("robots.txt fetched %d times for 3 same-host checks; want 1 (cache hit)", n)
	}

	// Expire the entry: the next check re-fetches.
	gate.mu.Lock()
	for _, e := range gate.robots {
		e.expires = time.Now().Add(-time.Minute)
	}
	gate.mu.Unlock()
	if err := gate.Check(context.Background(), srv.URL+"/b.html", minRateMS); err != nil {
		t.Fatalf("post-expiry check: %v", err)
	}
	if n := hits.Load(); n != 2 {
		t.Errorf("expired robots entry not re-fetched: %d hits, want 2", n)
	}
}

func TestRobotsSpecificGroupWins(t *testing.T) {
	// A group naming our product token overrides the * group entirely.
	robots := "User-agent: fetch-md-mcp\nDisallow: /a/\n\nUser-agent: *\nDisallow: /b/\n"
	var hits atomic.Int32
	srv := robotsSite(t, robots, &hits)
	defer srv.Close()
	_, gate := testGateFor(srv)

	if err := gate.Check(context.Background(), srv.URL+"/a/x", minRateMS); err == nil {
		t.Error("specific-group Disallow /a/ must block us")
	}
	if err := gate.Check(context.Background(), srv.URL+"/b/x", minRateMS); err != nil {
		t.Errorf("* group is ignored when a specific group matches; /b/ should be allowed: %v", err)
	}
}

func TestRobots5xxFailsClosed(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/robots.txt", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "boom", http.StatusInternalServerError)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	_, gate := testGateFor(srv)

	err := gate.Check(context.Background(), srv.URL+"/anything", minRateMS)
	if err == nil || !strings.Contains(err.Error(), "failing closed") {
		t.Errorf("5xx robots.txt must fail closed; got %v", err)
	}
}

func TestRobots404AllowsAll(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/robots.txt" {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write([]byte("<html><body>ok</body></html>"))
	}))
	defer srv.Close()
	_, gate := testGateFor(srv)

	if err := gate.Check(context.Background(), srv.URL+"/deep/page", minRateMS); err != nil {
		t.Errorf("404 robots.txt means no restrictions; got %v", err)
	}
}

func TestMatchRobotsPattern(t *testing.T) {
	cases := []struct {
		pattern, path string
		want          bool
	}{
		{"/secret/", "/secret/hidden.html", true},
		{"/secret/", "/open/secret/", false},
		{"/", "/anything", true},
		{"/*.pdf", "/docs/file.pdf", true},
		{"/*.pdf", "/docs/file.pdfx", true}, // no anchor: prefix-ish match
		{"/*.pdf$", "/docs/file.pdf", true},
		{"/*.pdf$", "/docs/file.pdfx", false},
		{"/a*b", "/aXXb", true},
		{"/a*b", "/aXX", false},
		{"/end$", "/end", true},
		{"/end$", "/ending", false},
	}
	for _, c := range cases {
		if got := matchRobotsPattern(c.pattern, c.path); got != c.want {
			t.Errorf("matchRobotsPattern(%q, %q) = %v, want %v", c.pattern, c.path, got, c.want)
		}
	}
}

func TestRobotsVerdictLongestMatchAllowWinsTie(t *testing.T) {
	rules := parseRobots(
		"User-agent: *\nDisallow: /shop/\nAllow: /shop/rules\n", "fetch-md-mcp")
	if ok, _ := robotsVerdict(rules, "/shop/cart"); ok {
		t.Error("/shop/cart should be disallowed")
	}
	if ok, _ := robotsVerdict(rules, "/shop/rules.html"); !ok {
		t.Error("/shop/rules.html should be allowed (longer Allow rule wins)")
	}
}
