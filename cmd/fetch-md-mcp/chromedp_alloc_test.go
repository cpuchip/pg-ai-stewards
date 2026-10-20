package main

import (
	"context"
	"flag"
	"strings"
	"testing"
	"time"
)

// TestChromeURLFlag: the default comes from $FETCH_MD_CHROME_URL; the flag, when given, wins; neither is empty.
func TestChromeURLFlag(t *testing.T) {
	t.Setenv("FETCH_MD_CHROME_URL", "http://from-env:9222")
	fs := flag.NewFlagSet("t", flag.ContinueOnError)
	v := chromeURLFlag(fs)
	if err := fs.Parse(nil); err != nil || *v != "http://from-env:9222" {
		t.Fatalf("env default: got %q, %v", *v, err)
	}
	fs = flag.NewFlagSet("t", flag.ContinueOnError)
	v = chromeURLFlag(fs)
	if err := fs.Parse([]string{"-chrome-url", "http://from-flag:9222"}); err != nil || *v != "http://from-flag:9222" {
		t.Fatalf("flag wins: got %q, %v", *v, err)
	}
	t.Setenv("FETCH_MD_CHROME_URL", "")
	fs = flag.NewFlagSet("t", flag.ContinueOnError)
	v = chromeURLFlag(fs)
	if err := fs.Parse(nil); err != nil || *v != "" {
		t.Fatalf("unset: got %q, %v", *v, err)
	}
}

// TestNewAllocatorChooses: no URL is the local launch with no tab options (today's path); a URL is the remote
// allocator with one tab option, a fresh browser context per fetch.
func TestNewAllocatorChooses(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	_, c1, opts, remote := newAllocator(ctx, &fetchConfig{UserAgent: "ua"})
	defer c1()
	if remote || len(opts) != 0 {
		t.Fatalf("no URL: remote=%v opts=%d, want the local launch and no options", remote, len(opts))
	}
	_, c2, opts2, remote2 := newAllocator(ctx, &fetchConfig{UserAgent: "ua", ChromeURL: "ws://127.0.0.1:1/devtools/browser/x"})
	defer c2()
	if !remote2 || len(opts2) != 1 {
		t.Fatalf("URL: remote=%v opts=%d, want the remote allocator and one option", remote2, len(opts2))
	}
}

// TestRemoteUnreachableErrors: a browser that is not there comes back as an error, quickly, not a hang.
func TestRemoteUnreachableErrors(t *testing.T) {
	start := time.Now()
	_, _, err := fetchURLJS(context.Background(), &fetchConfig{UserAgent: "ua", ChromeURL: "ws://127.0.0.1:1/devtools/browser/x"},
		"http://example.invalid/", 100)
	if err == nil {
		t.Fatal("want an error from an unreachable browser")
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("took %v, want a prompt error", d)
	}
	if !strings.Contains(err.Error(), "chromedp.Run") {
		t.Fatalf("want fetch-md's ordinary error wrapping, got %v", err)
	}
}
