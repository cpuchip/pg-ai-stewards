package main

// 98-crawler Part C: the Go half of the fixture proof. Serves the static
// fixture site (tests/fixtures/crawl-site — index -> a relevant link
// chain, an irrelevant page, a robots-disallowed path, an offsite link)
// and drives the REAL tool handlers through it in enforce_robots mode:
// robots honored, links categorized (the crawl_enqueue feed), markdown
// extracted (the crawl_save feed). The SQL half (frontier machinery:
// budgets/dedup/domain wall) is proven by the OK 98 block in
// tests/virgin-smoke.sql — together they are the deterministic oracle
// for a capability that is NOT grindable live (real crawls hit real
// sites; this fixture is the resettable sandbox).

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixtureSiteServer(t *testing.T) *httptest.Server {
	t.Helper()
	dir := filepath.Join("..", "..", "tests", "fixtures", "crawl-site")
	if _, err := os.Stat(filepath.Join(dir, "index.html")); err != nil {
		t.Fatalf("fixture site missing at %s: %v", dir, err)
	}
	return httptest.NewServer(http.FileServer(http.Dir(dir)))
}

func TestCrawlFixtureSite(t *testing.T) {
	srv := fixtureSiteServer(t)
	defer srv.Close()
	cfg, _ := testGateFor(srv)

	fetch := makeFetchURL(cfg)
	links := makeExtractLinks(cfg)

	// 1. The root fetch works politely and yields real markdown.
	res, out, err := fetch(context.Background(), nil, fetchURLInput{
		URL: srv.URL + "/index.html", EnforceRobots: true, RateMS: minRateMS,
	})
	if err != nil || (res != nil && res.IsError) {
		t.Fatalf("index fetch failed: res=%v err=%v", res, err)
	}
	if !strings.Contains(out.Markdown, "Emberwold") {
		t.Errorf("index markdown lost the article content: %q", out.Markdown)
	}
	t.Logf("transcript: fetched %s (%d bytes markdown, title %q)",
		out.URL, len(out.Markdown), out.Title)

	// 2. extract_links categorizes the frontier feed: internal pages to
	// enqueue, the offsite link the SQL domain wall will reject.
	lres, lout, err := links(context.Background(), nil, extractLinksInput{
		URL: srv.URL + "/index.html", EnforceRobots: true, RateMS: minRateMS,
	})
	if err != nil || (lres != nil && lres.IsError) {
		t.Fatalf("extract_links failed: res=%v err=%v", lres, err)
	}
	wantInternal := []string{"/relevant1.html", "/irrelevant.html", "/secret/hidden.html"}
	for _, want := range wantInternal {
		found := false
		for _, l := range lout.Internal {
			if strings.HasSuffix(l.URL, want) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("internal link %s not extracted (got %v)", want, lout.Internal)
		}
	}
	offsiteSeen := false
	for _, l := range lout.External {
		if strings.Contains(l.URL, "offsite.invalid") {
			offsiteSeen = true
		}
	}
	if !offsiteSeen {
		t.Errorf("offsite link not categorized external (got %v)", lout.External)
	}
	t.Logf("transcript: extract_links -> %d internal, %d external (offsite.invalid present)",
		len(lout.Internal), len(lout.External))

	// 3. The robots-disallowed page is BLOCKED on the enforce path — and
	// the fixture page itself says so if this ever regresses.
	res, out, err = fetch(context.Background(), nil, fetchURLInput{
		URL: srv.URL + "/secret/hidden.html", EnforceRobots: true, RateMS: minRateMS,
	})
	if err != nil {
		t.Fatalf("handler error: %v", err)
	}
	if res == nil || !res.IsError {
		t.Fatalf("robots-disallowed fixture page was fetched; politeness floor broken (markdown: %q)", out.Markdown)
	}
	t.Logf("transcript: /secret/hidden.html blocked by robots (structured error, crawl_save disposition=blocked)")

	// 4. The relevant chain fetches cleanly — the content crawl_save
	// would byte-account into docs. (Readability lifts the h1 into
	// Title, so assert on body text, not the heading.)
	for p, marker := range map[string]string{
		"/relevant1.html": "Origin",
		"/relevant2.html": "Calling",
	} {
		res, out, err = fetch(context.Background(), nil, fetchURLInput{
			URL: srv.URL + p, EnforceRobots: true, RateMS: minRateMS,
		})
		if err != nil || (res != nil && res.IsError) {
			t.Fatalf("%s fetch failed: res=%v err=%v", p, res, err)
		}
		if !strings.Contains(out.Markdown, marker) {
			t.Errorf("%s markdown lost the rules content (want %q): %q", p, marker, out.Markdown)
		}
		t.Logf("transcript: fetched %s (%d bytes markdown)", p, len(out.Markdown))
	}
}
