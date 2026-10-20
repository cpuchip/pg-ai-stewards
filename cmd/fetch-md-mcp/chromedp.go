// Phase 2 (2026-05-09) — JS-rendering path via chromedp. Used when a
// tool's `js: true` param is set. Launches headless Chromium (system
// `chromium` binary on alpine; `chrome`/`chromium` on host), renders
// the page, returns the rendered DOM HTML for downstream readability +
// markdown conversion.
//
// Resource shape: each call spawns its own browser allocator + tab.
// Higher latency than persistent-browser, but isolation is cleaner
// and simpler to reason about. Switch to a shared allocator if a
// multi-fetch batch becomes the hot path.

package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/chromedp/cdproto/emulation"
	"github.com/chromedp/chromedp"
)

// remoteChromeTimeout bounds a remote render when the caller set no deadline, so a
// browser that accepts the connection and never answers is an error, not a hang.
const remoteChromeTimeout = 60 * time.Second

// chromeURLFlag registers -chrome-url on fs. Its default is $FETCH_MD_CHROME_URL,
// read once at startup; the flag, when given, wins.
func chromeURLFlag(fs *flag.FlagSet) *string {
	return fs.String("chrome-url", os.Getenv("FETCH_MD_CHROME_URL"),
		"DevTools endpoint of a running headless Chromium for js:true renders (default $FETCH_MD_CHROME_URL; empty = launch a local one)")
}

// newAllocator chooses where js:true renders. With no ChromeURL it is the local
// launch, exactly as before. With one it attaches to that running browser and asks
// for a fresh browser context per fetch, so no cookies or storage carry over;
// cancelling the returned context closes the tab and that browser context.
func newAllocator(ctx context.Context, cfg *fetchConfig) (context.Context, context.CancelFunc, []chromedp.ContextOption, bool) {
	if cfg.ChromeURL == "" {
		alloc, cancel := chromedp.NewExecAllocator(ctx,
			append(chromedp.DefaultExecAllocatorOptions[:],
				chromedp.Flag("headless", true),
				chromedp.Flag("disable-gpu", true),
				chromedp.Flag("no-sandbox", true),
				chromedp.UserAgent(cfg.UserAgent),
			)...)
		return alloc, cancel, nil, false
	}
	alloc, cancel := chromedp.NewRemoteAllocator(ctx, cfg.ChromeURL)
	return alloc, cancel, []chromedp.ContextOption{chromedp.WithNewBrowserContext()}, true
}

// fetchURLJS renders `target` in headless Chromium and returns the
// rendered HTML. waitMS is the post-load settle (default 500ms) to
// catch SPA hydration. Honors ctx deadline.
func fetchURLJS(ctx context.Context, cfg *fetchConfig, target string, waitMS int) (string, string, error) {
	if waitMS <= 0 {
		waitMS = 500
	}

	if _, ok := ctx.Deadline(); !ok && cfg.ChromeURL != "" {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, remoteChromeTimeout)
		defer cancel()
	}
	allocCtx, allocCancel, tabOpts, remote := newAllocator(ctx, cfg)
	defer allocCancel()

	tabCtx, tabCancel := chromedp.NewContext(allocCtx, tabOpts...)
	defer tabCancel()

	var (
		html     string
		finalURL string
	)
	actions := []chromedp.Action{
		chromedp.Navigate(target),
		chromedp.Sleep(time.Duration(waitMS) * time.Millisecond),
		chromedp.OuterHTML("html", &html, chromedp.ByQuery),
		chromedp.Location(&finalURL),
	}
	if remote {
		// a remote browser has its own user agent; ours goes with every fetch
		actions = append([]chromedp.Action{emulation.SetUserAgentOverride(cfg.UserAgent)}, actions...)
	}
	err := chromedp.Run(tabCtx, actions...)
	if err != nil {
		return "", target, fmt.Errorf("chromedp.Run: %w", err)
	}
	return html, finalURL, nil
}
