package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// TestFetchURLJSRemote renders a page whose content only JavaScript writes, in a
// running headless Chromium at $FETCH_MD_TEST_CHROME_URL (skipped when unset), and
// checks that a cookie set by one fetch is not seen by the next (each fetch has its
// own browser context) and that the user agent is ours. The page server must be
// reachable from the browser: $FETCH_MD_TEST_PAGE_HOST names this host as the
// browser sees it (default 127.0.0.1).
func TestFetchURLJSRemote(t *testing.T) {
	chrome := os.Getenv("FETCH_MD_TEST_CHROME_URL")
	if chrome == "" {
		t.Skip("FETCH_MD_TEST_CHROME_URL not set")
	}
	host := os.Getenv("FETCH_MD_TEST_PAGE_HOST")
	if host == "" {
		host = "127.0.0.1"
	}
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen := "none"
		if c, err := r.Cookie("visited"); err == nil {
			seen = c.Value
		}
		http.SetCookie(w, &http.Cookie{Name: "visited", Value: "yes", Path: "/"})
		fmt.Fprintf(w, `<html><body><div id="out"></div><script>
document.getElementById("out").textContent = "rendered-by-js cookie=%s ua=" + navigator.userAgent;
</script></body></html>`, seen)
	}))
	srv.Listener.Close()
	l, err := netListen()
	if err != nil {
		t.Fatal(err)
	}
	srv.Listener = l
	srv.Start()
	defer srv.Close()
	port := srv.Listener.Addr().String()[strings.LastIndex(srv.Listener.Addr().String(), ":")+1:]
	page := fmt.Sprintf("http://%s:%s/", host, port)

	cfg := &fetchConfig{UserAgent: "fetch-md-test-agent/1", ChromeURL: chrome}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	for i := 0; i < 2; i++ {
		html, _, err := fetchURLJS(ctx, cfg, page, 300)
		if err != nil {
			t.Fatalf("fetch %d: %v", i, err)
		}
		if !strings.Contains(html, "rendered-by-js cookie=none") {
			t.Fatalf("fetch %d: want the JS-written text with no cookie carried over, got %.300q", i, html)
		}
		if !strings.Contains(html, "ua=fetch-md-test-agent/1") {
			t.Fatalf("fetch %d: want our user agent, got %.300q", i, html)
		}
	}
}
